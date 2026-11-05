import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// What the plugin knows of a host from its start-up batch (4.1) and abilities (4.5).
struct ReolinkHostInfo: Sendable, Equatable {
    var type = ""
    var name = ""
    var model = ""
    var serial = ""
    var hardware = ""
    var firmware = ""
    var channelNum = 1
    var mac: String?
    var uid: String?
    var rtspPort = 554
    var rtmpPort = 1935
    var mediaPort: Int?
    /// nil when `GetUser` did not answer.
    var isAdmin: Bool?
    var hostAbilities: [String: Int] = [:]
    var channelAbilities: [[String: Int]] = []
    var channels: [ReolinkChannelStatus] = []
    /// Whether `GetChannelstatus` answered.
    var hasChannelStatus = false

    /// The device types with channels of their own (lowercase).
    static let multiChannelTypes: Set<String> = ["nvr", "wifi_nvr", "homehub"]

    var isMultiChannel: Bool { Self.multiChannelTypes.contains(type.lowercased()) }
    /// Whether recording settings go by `GetRecV20`/`SetRecV20` (D.3).
    var usesRecV20: Bool { hostAbility("scheduleVersion") >= 1 }
    var isHub: Bool { type.uppercased() == "HOMEHUB" }

    /// The host id of 6.1: the P2P UID when known, else the MAC (lowercase, colon-separated).
    var hostID: String? {
        if let uid, !uid.isEmpty { return uid }
        return mac.map { $0.lowercased().replacingOccurrences(of: "-", with: ":") }
    }

    func hostAbility(_ name: String) -> Int { hostAbilities[name] ?? 0 }

    /// A channel's ability (`abilityChn[ch]`, `abilityChn[0]` beyond the array).
    func ability(_ name: String, channel: Int) -> Int { reportedAbility(name, channel: channel) ?? 0 }

    /// A channel's ability as reported; nil when the device does not list it (some count an absent one as supported).
    func reportedAbility(_ name: String, channel: Int) -> Int? {
        let list = channel < channelAbilities.count ? channelAbilities[channel] : channelAbilities.first
        return list?[name]
    }

    /// The channels to publish: those online (all of `channelNum` without a channel status), other brands on an NVR left out.
    var onlineChannels: [ReolinkChannelStatus] {
        if !hasChannelStatus || !isMultiChannel {
            if isMultiChannel { return (0..<max(1, channelNum)).map { ReolinkChannelStatus(channel: $0, online: true) } }
            return [channels.first { $0.channel == 0 } ?? ReolinkChannelStatus(channel: 0, online: true)]
        }
        return channels.filter { $0.online && !$0.isForeign }
    }

    // MARK: Parsing

    mutating func apply(_ reply: ReolinkReply) {
        guard reply.ok, let value = reply.value else { return }
        switch reply.cmd {
        case "GetDevInfo":
            let info = value["DevInfo"]
            type = info?["exactType"]?.stringValue?.nonEmptyText ?? info?["type"]?.stringValue ?? type
            name = info?["name"]?.stringValue ?? name
            model = info?["model"]?.stringValue ?? model
            serial = info?["serial"]?.stringValue ?? serial
            hardware = info?["hardVer"]?.stringValue ?? hardware
            firmware = info?["firmVer"]?.stringValue ?? firmware
            channelNum = info?["channelNum"]?.saturatingIntValue(in: 1...128) ?? channelNum
        case "GetChannelstatus":
            hasChannelStatus = true
            channels = Self.channelStatus(value)
        case "GetLocalLink":
            mac = value["LocalLink"]?["mac"]?.stringValue?.nonEmptyText
        case "GetNetPort":
            let port = value["NetPort"]
            rtspPort = port?["rtspPort"]?.saturatingIntValue(in: 1...65535) ?? rtspPort
            rtmpPort = port?["rtmpPort"]?.saturatingIntValue(in: 1...65535) ?? rtmpPort
            mediaPort = port?["mediaPort"]?.saturatingIntValue(in: 1...65535)
        case "GetP2p":
            uid = value["P2p"]?["uid"]?.stringValue?.nonEmptyText
        case "GetAbility":
            let ability = value["Ability"]
            hostAbilities = Self.abilities(ability)
            channelAbilities = (ability?["abilityChn"]?.arrayValue ?? []).map { Self.abilities($0) }
        default:
            break
        }
    }

    mutating func applyUsers(_ reply: ReolinkReply, username: String) {
        guard reply.ok, let users = reply.value?["User"]?.arrayValue else { return }
        if let user = users.first(where: { $0["userName"]?.stringValue == username }) {
            isAdmin = user["level"]?.stringValue == "admin"
        }
    }

    static func abilities(_ json: JSONValue?) -> [String: Int] {
        var result: [String: Int] = [:]
        for (key, value) in json?.objectValue ?? [:] {
            if let ver = value["ver"]?.saturatingIntValue { result[key] = ver }
        }
        return result
    }

    /// `GetChannelstatus`'s channels; a UID two channels share gets `_<channel>` appended.
    static func channelStatus(_ value: JSONValue) -> [ReolinkChannelStatus] {
        var list = (value["status"]?.arrayValue ?? []).compactMap { item -> ReolinkChannelStatus? in
            guard let channel = item["channel"]?.saturatingIntValue(in: 0...255) else { return nil }
            let name = item["name"]?.stringValue.flatMap { ["0", "1", ""].contains($0) ? nil : $0 }
            return ReolinkChannelStatus(
                channel: channel, online: item["online"]?.saturatingIntValue == 1, name: name, model: item["typeInfo"]?.stringValue?.nonEmptyText,
                uid: item["uid"]?.stringValue?.nonEmptyText, asleep: item["sleep"]?.saturatingIntValue == 1)
        }
        var counts: [String: Int] = [:]
        for item in list { if let uid = item.uid { counts[uid, default: 0] += 1 } }
        for index in list.indices where counts[list[index].uid ?? ""] ?? 0 > 1 {
            list[index].uid = "\(list[index].uid!)_\(list[index].channel)"
        }
        return list
    }
}

struct ReolinkChannelStatus: Sendable, Equatable {
    var channel: Int
    var online: Bool
    var name: String?
    var model: String?
    var uid: String?
    var asleep = false

    /// Another brand's camera on an NVR (named `NVT` or `IPCAM`, model `IPC`): left out.
    var isForeign: Bool { (name == "NVT" || name == "IPCAM") && model == "IPC" }
}

/// A stream's encoding, from `GetEnc`.
struct ReolinkStream: Sendable, Equatable {
    var codec: String
    var width: Int
    var height: Int
    var fps: Int
    /// `GetRtspUrl`'s URL, without credentials.
    var rtspURL: String?
}

/// What a channel is and does (4.2, 4.5), and its live state.
struct ReolinkChannel: Sendable, Equatable {
    var channel: Int
    var name: String
    var model: String
    var firmware: String
    var hardware: String
    var uid: String?
    var main = ReolinkStream(codec: "h264", width: 2560, height: 1440, fps: 25)
    var sub = ReolinkStream(codec: "h264", width: 640, height: 360, fps: 15)
    var motion = false
    var aiTypes: Set<String> = []
    var doorbell = false
    var floodlight = false
    var irLights = false
    var siren = false
    var battery = false
    var hasGetEvents = false
    /// Pan, tilt, zoom, presets and patrols; nil without PTZ (`ptzType` 0).
    var ptz: ReolinkPTZ?
    /// Whether the channel has privacy mode: a `cmd_id` 574 reply said where it is (addendum C).
    var privacy = false
    /// Whether the floodlight takes a colour temperature (Baichuan `ledCtrl` bit 17).
    var floodlightColour = false
    /// The floodlight modes the camera offers, by `ReolinkFloodlight.modes` name.
    var floodlightModes: [String] = []
    /// The Reolink Chimes paired to a doorbell (`GetDingDongList`), by id.
    var chimes: [ReolinkPTZ.Entry] = []
    /// Whether the device records the channel on its own storage by a schedule it can switch (`GetRec`/`GetRecV20`).
    var recording = false
    var state = ReolinkChannelState()

    /// The device's AI type names and the HomeKit sensors' subtypes (6.3).
    static let aiSensors: [(type: String, subtype: String, title: String)] = [
        ("people", "person", "Person"), ("vehicle", "vehicle", "Vehicle"), ("dog_cat", "pet", "Pet"), ("face", "face", "Face"), ("package", "package", "Package"),
    ]
}

struct ReolinkChannelState: Sendable, Equatable {
    var online = true
    var asleep = false
    var motion = false
    var ai: [String: Bool] = [:]
    var visitor = false
    var floodlightOn: Bool?
    var floodlightBrightness: Int?
    var irOn: Bool?
    var sirenPlaying: Bool?
    var batteryPercent: Int?
    var charging: Bool?
    /// Whether a PTZ patrol runs (Baichuan `cmd_id` 64), once asked.
    var patrolling: Bool?
    /// Privacy mode: the camera's streams and HTTP API off.
    var privacy: Bool?
    /// The floodlight's colour temperature in mireds, from `GetWhiteLed`'s `ColorTemp`.
    var floodlightMireds: Int?
    /// The floodlight's mode, in HTTP's numbering (`ReolinkFloodlight.modes`).
    var floodlightMode: Int?
    /// Whether the device records the channel (its schedule on, and a camera's own master switch).
    var recordingOn: Bool?
}

/// Recording on the device's own storage (addendum D.3): `GetRecV20` with `scheduleVersion`, `GetRec` before it.
enum ReolinkRecording {
    static func readCommand(v20: Bool, channel: Int) -> ReolinkCommand {
        ReolinkCommand(cmd: v20 ? "GetRecV20" : "GetRec", action: 1, param: ["channel": .number(Double(channel))])
    }

    /// Whether `value.Rec` says it records; nil when it has no flag. A camera on its own (not `multiChannel`) also
    /// needs V20's master `enable`.
    static func isOn(_ value: JSONValue?, v20: Bool, multiChannel: Bool) -> Bool? {
        guard let rec = value?["Rec"] else { return nil }
        if v20 {
            guard let schedule = rec["scheduleEnable"]?.saturatingIntValue else { return nil }
            return schedule == 1 && (multiChannel || rec["enable"]?.saturatingIntValue != 0)
        }
        return rec["schedule"]?["enable"]?.saturatingIntValue.map { $0 == 1 }
    }

    /// The `Rec` object sent back whole with its flag changed (and, turning a camera on, its master switch).
    static func changed(_ rec: JSONValue, on: Bool, v20: Bool, multiChannel: Bool) -> JSONValue? {
        guard var fields = rec.objectValue else { return nil }
        if v20 {
            fields["scheduleEnable"] = .number(on ? 1 : 0)
            if on, !multiChannel, fields["enable"]?.saturatingIntValue == 0 { fields["enable"] = 1 }
        } else {
            guard var schedule = fields["schedule"]?.objectValue else { return nil }
            schedule["enable"] = .number(on ? 1 : 0)
            fields["schedule"] = .object(schedule)
        }
        return .object(fields)
    }
}

/// Reolink Chime, the wireless chime of a doorbell (addendum D.2).
enum ReolinkChime {
    /// The tones `DingDongOpt` plays, by `musicId`.
    static let tones = ["citybird", "originaltune", "pianokey", "loop", "attraction", "hophop", "goodday", "operetta", "moonlight", "waybackhome"]

    /// `GetDingDongList`'s paired chimes.
    static func paired(_ value: JSONValue?) -> [ReolinkPTZ.Entry] {
        (value?["DingDongList"]?["pairedlist"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["deviceId"]?.saturatingIntValue else { return nil }
            return ReolinkPTZ.Entry(id: id, name: item["deviceName"]?.stringValue?.nonEmptyText ?? "Chime \(id)")
        }.sorted { $0.id < $1.id }
    }
}

/// The floodlight's colour temperature and modes (addendum D.1).
enum ReolinkFloodlight {
    /// The modes by the name Accessory Settings give them, with HTTP's `mode` numbers (`SetWhiteLed`).
    static let modes: [(name: String, number: Int)] = [("off", 0), ("auto", 1), ("night", 2), ("schedule", 3), ("autoAdaptive", 4), ("adaptive", 5)]

    static func modeNumber(_ name: String) -> Int? { modes.first { $0.name == name }?.number }

    /// The device's colour temperature (0 is 6000 K, 100 is 3000 K) in kelvin.
    static func kelvin(_ value: Int) -> Int { 6000 - 30 * min(100, max(0, value)) }

    /// A kelvin value in the device's scale; nil outside 3000 to 6000 K.
    static func value(kelvin: Int) -> Int? {
        guard (3000...6000).contains(kelvin) else { return nil }
        return Int((Double(6000 - kelvin) / 30).rounded())
    }

    static func mireds(kelvin: Int) -> Int { Int((1_000_000 / Double(max(1, kelvin))).rounded()) }
    static func kelvin(mireds: Int) -> Int { Int((1_000_000 / Double(max(1, mireds))).rounded()) }

    /// HomeKit's Color Temperature range for 3000 to 6000 K.
    static let miredRange = 167...333

    /// What `ledCtrl` (nil when Baichuan gave none) and the HTTP abilities say the floodlight offers.
    static func offeredModes(ledCtrl: Int?, flSchedule: Bool, flKeepOn: Bool, autoBrightness: Bool) -> [String] {
        func bit(_ n: Int) -> Bool { (ledCtrl ?? 0) & (1 << n) != 0 }
        let auto = ledCtrl.map { $0 & (1 << 6) == 0 } ?? true
        let adaptive = bit(14) || autoBrightness
        var offered = ["off"]
        if auto { offered.append("auto") }
        if bit(4) || flKeepOn { offered.append("night") }
        if bit(5) || flSchedule { offered.append("schedule") }
        if adaptive, auto || bit(13) { offered.append("autoAdaptive") }
        if adaptive { offered.append("adaptive") }
        return offered
    }
}

/// A channel's pan, tilt and zoom (addendum B): what `ptzType` allows, and the presets, patrols, guard and zoom range
/// of the start-up batch.
struct ReolinkPTZ: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var id: Int
        var name: String
    }

    var pan = false
    var tilt = false
    var zoom = false
    var speed = false
    /// The enabled presets, by id.
    var presets: [Entry] = []
    /// The enabled patrols, by id; the first is the one the Patrol switch runs.
    var patrols: [Entry] = []
    /// Whether `GetPtzGuard` answered: the camera has a home position.
    var hasGuard = false
    var zoomRange: ClosedRange<Int>?
    var focusRange: ClosedRange<Int>?

    /// The moves of `PtzCtrl` the Assistant names, with the `op` each sends. `ZoomInc` zooms in, as reolink-aio has it
    /// (the HTTP guide says the opposite; the addendum's recommendation, B.2).
    static let moves: [String: String] = [
        "left": "Left", "right": "Right", "up": "Up", "down": "Down", "leftUp": "LeftUp", "leftDown": "LeftDown", "rightUp": "RightUp",
        "rightDown": "RightDown", "zoomIn": "ZoomInc", "zoomOut": "ZoomDec", "stop": "Stop",
    ]

    /// What `ptzType` allows (B.1); speed also needs `supportPtzSpeed`, an absent one counting as supported. nil for 0.
    static func capabilities(ptzType: Int, speedAbility: Int?) -> ReolinkPTZ? {
        guard ptzType > 0 else { return nil }
        var ptz = ReolinkPTZ()
        ptz.zoom = [1, 2, 5].contains(ptzType)
        ptz.tilt = [2, 3, 5, 6].contains(ptzType)
        ptz.pan = [2, 3, 5, 6, 7].contains(ptzType)
        ptz.speed = [2, 3].contains(ptzType) && (speedAbility ?? 1) > 0
        return ptz
    }

    /// Whether the camera makes a move of `moves`.
    func allows(_ move: String) -> Bool {
        switch move {
        case "stop": pan || tilt || zoom
        case "left", "right": pan
        case "up", "down": tilt
        case "leftUp", "leftDown", "rightUp", "rightDown": pan && tilt
        case "zoomIn", "zoomOut": zoom
        default: false
        }
    }

    /// `GetPtzPreset`'s or `GetPtzPatrol`'s enabled entries (`enable` 1), by id; an unnamed one is called `<fallback> <id>`.
    static func entries(_ list: JSONValue?, fallback: String) -> [Entry] {
        (list?.arrayValue ?? []).compactMap { item -> Entry? in
            guard item["enable"]?.saturatingIntValue == 1, let id = item["id"]?.saturatingIntValue(in: 0...255) else { return nil }
            let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyText ?? "\(fallback) \(id)"
            return Entry(id: id, name: name)
        }.sorted { $0.id < $1.id }
    }

    /// A `min`/`max` pair of `GetZoomFocus`'s range.
    static func range(_ json: JSONValue?) -> ClosedRange<Int>? {
        guard let low = json?["min"]?.saturatingIntValue, let high = json?["max"]?.saturatingIntValue, low <= high else { return nil }
        return low...high
    }
}

/// Reading the channel batch's items (4.2) into a channel.
enum ReolinkParse {
    struct Flag: Sendable, Equatable {
        var state: Bool
        var supported: Bool
        init(_ state: Bool, _ supported: Bool) {
            self.state = state
            self.supported = supported
        }
    }

    /// `GetEvents`: motion, AI types and visitor, with what each supports. nil when the item is for another channel.
    struct Events: Sendable, Equatable {
        var motion: Flag?
        var ai: [String: Flag] = [:]
        var visitor: Flag?

    }

    static func flag(_ json: JSONValue?) -> Flag? {
        guard let json else { return nil }
        if let number = json.saturatingIntValue { return Flag(number == 1, true) }
        guard json.objectValue != nil else { return nil }
        return Flag(json["alarm_state"]?.saturatingIntValue == 1, (json["support"]?.saturatingIntValue ?? 1) == 1)
    }

    static func events(_ reply: ReolinkReply, channel: Int) -> Events? {
        guard reply.ok, let value = reply.value else { return nil }
        if let reported = value["channel"]?.saturatingIntValue, reported != channel { return nil }
        var events = Events()
        events.motion = flag(value["md"])
        for (type, item) in value["ai"]?.objectValue ?? [:] where item.arrayValue == nil {
            if let parsed = flag(item) { events.ai[type] = parsed }
        }
        events.visitor = flag(value["visitor"])
        return events
    }

    /// `GetAiState`, new form (`{alarm_state, support}`) or old (a bare integer: supported).
    static func aiState(_ reply: ReolinkReply, channel: Int) -> [String: Flag]? {
        guard reply.ok, let value = reply.value?.objectValue else { return nil }
        if let reported = value["channel"]?.saturatingIntValue, reported != channel { return nil }
        var result: [String: Flag] = [:]
        for (key, item) in value where key != "channel" {
            if let parsed = flag(item) { result[key] = parsed }
        }
        return result
    }

    static func stream(_ json: JSONValue?, fallback: ReolinkStream) -> ReolinkStream {
        guard let json else { return fallback }
        var stream = fallback
        if let codec = json["vType"]?.stringValue?.lowercased(), ["h264", "h265"].contains(codec) { stream.codec = codec }
        stream.width = json["width"]?.saturatingIntValue(in: 16...16384) ?? stream.width
        stream.height = json["height"]?.saturatingIntValue(in: 16...16384) ?? stream.height
        stream.fps = json["frameRate"]?.saturatingIntValue(in: 1...120) ?? stream.fps
        return stream
    }

    /// HAP wants digits and dots: `v3.0.0.59_20080734` → `3.0.0.59`.
    static func firmware(_ text: String) -> String {
        var version = text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
        version = String(version.prefix { $0.isNumber || $0 == "." })
        while version.hasSuffix(".") { version.removeLast() }
        return version.isEmpty ? "1.0.0" : version
    }
}

extension String {
    var nonEmptyText: String? { isEmpty ? nil : self }
}

/// Stream URLs (4.6).
enum ReolinkStreamURL {
    /// The password percent-encoded with no safe characters, for RTSP.
    static func rtspEncoded(_ text: String) -> String { URLEncoding.rfc3986(text) }

    static func channelDigits(_ channel: Int) -> String { String(format: "%02d", channel + 1) }

    /// RTSP: `GetRtspUrl`'s path (and port) when the host's RTSP ability is 3 or more, else `<codec>Preview_<CC>_<stream>`.
    /// The credentials only ever go to the configured host: the address the device reports is not used, so a device
    /// cannot send them elsewhere.
    static func rtsp(host: String, port: Int, username: String, password: String, channel: Int, sub: Bool, codec: String, reported: String?, rtspVersion: Int) -> String {
        let credentials = "\(rtspEncoded(username)):\(rtspEncoded(password))@"
        let address = bracketed(host)
        if rtspVersion >= 3, let reported, let target = reportedTarget(reported) {
            return "rtsp://\(credentials)\(address):\(target.port ?? port)\(target.path)"
        }
        return "rtsp://\(credentials)\(address):\(port)/\(codec)Preview_\(channelDigits(channel))_\(sub ? "sub" : "main")"
    }

    /// An IPv6 address in brackets, for a URL's authority.
    static func bracketed(_ host: String) -> String { host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host }

    /// The port and the path with its query of an `rtsp://` URL without credentials; nil for anything else, a URL with
    /// spaces, control or non-ASCII characters, or a path of more than 512 bytes.
    static func reportedTarget(_ url: String) -> (port: Int?, path: String)? {
        guard url.utf8.count <= 1024, url.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }), let components = URLComponents(string: url), components.scheme?.lowercased() == "rtsp",
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        guard path.hasPrefix("/"), path.count > 1, path.utf8.count <= 512 else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        return (components.port, path)
    }

    static func rtmp(host: String, port: Int, username: String, password: String, channel: Int, sub: Bool) -> String {
        let stream = sub ? "sub" : "main"
        return "rtmp://\(bracketed(host)):\(port)/bcs/channel\(channel)_\(stream).bcs?channel=\(channel)&stream=\(sub ? 1 : 0)"
            + "&user=\(rtspEncoded(username))&password=\(rtspEncoded(password))"
    }

    static func flv(https: Bool, host: String, apiPort: Int, rtmpPort: Int, username: String, password: String, channel: Int, sub: Bool) -> String {
        "\(https ? "https" : "http")://\(bracketed(host)):\(apiPort)/flv?port=\(rtmpPort)&app=bcs&stream=channel\(channel)_\(sub ? "sub" : "main").bcs"
            + "&user=\(rtspEncoded(username))&password=\(rtspEncoded(password))"
    }
}
