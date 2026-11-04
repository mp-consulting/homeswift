import Foundation
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
    var rtspEnabled = true
    var mediaPort: Int?
    /// nil when `GetUser` did not answer.
    var isAdmin: Bool?
    var hostAbilities: [String: Int] = [:]
    var channelAbilities: [[String: Int]] = []
    var channels: [ReolinkChannelStatus] = []
    /// Whether `GetChannelstatus` answered.
    var hasChannelStatus = false

    var isMultiChannel: Bool { ["NVR", "WIFI_NVR", "HOMEHUB"].contains(type.uppercased()) }
    var isHub: Bool { type.uppercased() == "HOMEHUB" }

    /// The host id of 6.1: the P2P UID when known, else the MAC (lowercase, colon-separated).
    var hostID: String? {
        if let uid, !uid.isEmpty { return uid }
        return mac.map { $0.lowercased().replacingOccurrences(of: "-", with: ":") }
    }

    func hostAbility(_ name: String) -> Int { hostAbilities[name] ?? 0 }

    /// A channel's ability (`abilityChn[ch]`, `abilityChn[0]` beyond the array).
    func ability(_ name: String, channel: Int) -> Int {
        let list = channel < channelAbilities.count ? channelAbilities[channel] : channelAbilities.first
        return list?[name] ?? 0
    }

    /// The channels to publish: those online (all of `channelNum` without a channel status), other brands on an NVR left out.
    var onlineChannels: [ReolinkChannelStatus] {
        if !hasChannelStatus || !isMultiChannel {
            if isMultiChannel { return (0..<max(1, channelNum)).map { ReolinkChannelStatus(channel: $0, online: true) } }
            return [channels.first { $0.channel == 0 } ?? ReolinkChannelStatus(channel: 0, online: true)]
        }
        return channels.filter { status in
            guard status.online else { return false }
            let foreignName = status.name == "NVT" || status.name == "IPCAM"
            return !(foreignName && status.model == "IPC")
        }
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
            rtspEnabled = (port?["rtspEnable"]?.saturatingIntValue ?? 1) != 0
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
    var floodlightBrightness = true
    var irLights = false
    var siren = false
    var battery = false
    var hasGetEvents = false
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
    static func rtspEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func channelDigits(_ channel: Int) -> String { String(format: "%02d", channel + 1) }

    /// RTSP: `GetRtspUrl`'s URL with the credentials inserted when the host's RTSP ability is 3 or more, else
    /// `<codec>Preview_<CC>_<stream>`.
    static func rtsp(host: String, port: Int, username: String, password: String, channel: Int, sub: Bool, codec: String, reported: String?, rtspVersion: Int) -> String {
        let credentials = "\(rtspEncoded(username)):\(rtspEncoded(password))@"
        if rtspVersion >= 3, let reported, reported.hasPrefix("rtsp://") {
            return "rtsp://" + credentials + reported.dropFirst("rtsp://".count)
        }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "rtsp://\(credentials)\(address):\(port)/\(codec)Preview_\(channelDigits(channel))_\(sub ? "sub" : "main")"
    }

    static func rtmp(host: String, port: Int, username: String, password: String, channel: Int, sub: Bool) -> String {
        let stream = sub ? "sub" : "main"
        return "rtmp://\(host):\(port)/bcs/channel\(channel)_\(stream).bcs?channel=\(channel)&stream=\(sub ? 1 : 0)&user=\(username)&password=\(password)"
    }

    static func flv(https: Bool, host: String, apiPort: Int, rtmpPort: Int, username: String, password: String, channel: Int, sub: Bool) -> String {
        "\(https ? "https" : "http")://\(host):\(apiPort)/flv?port=\(rtmpPort)&app=bcs&stream=channel\(channel)_\(sub ? "sub" : "main").bcs&user=\(username)&password=\(password)"
    }

    /// A URL for the log: credentials in the authority and `password=`/`token=` values masked.
    static func masked(_ url: String) -> String {
        var result = url.replacing(#/([a-zA-Z][a-zA-Z0-9+.\-]*:\/\/)[^\/?#\s@]*@/#) { $0.output.1 + "<credentials>@" }
        result = result.replacing(#/(password|token|user)=[^&\s]*/#) { "\($0.output.1)=<\($0.output.1)>" }
        return result
    }
}
