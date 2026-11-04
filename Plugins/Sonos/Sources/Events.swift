import Foundation

/// The bodies the players send: UPnP property sets, their `LastChange` state, and DIDL-Lite metadata.
enum Events {
    /// The properties of an `e:propertyset`, by name, their text as it is (escaped XML still to parse, for some).
    static func properties(_ body: Data) throws -> [String: String] {
        let root = try XML.parse(String(decoding: body, as: UTF8.self))
        var properties: [String: String] = [:]
        for property in root.children("property") {
            for value in property.children { properties[value.localName] = value.text }
        }
        return properties
    }

    /// The state variables of a `LastChange` (`Event/InstanceID val="0"/<Variable val="…">`), by name; a variable with a
    /// `channel` other than `Master` under `<name>:<channel>` (`Volume:LF`). Empty for an empty or absent LastChange.
    static func lastChange(_ text: String?) throws -> [String: String] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let event = try XML.parse(text)
        guard let instance = event.first("InstanceID") else { return [:] }
        var variables: [String: String] = [:]
        for variable in instance.children {
            let channel = variable.attribute("channel")
            let key = channel == nil || channel == "Master" ? variable.localName : "\(variable.localName):\(channel!)"
            variables[key] = variable.attribute("val") ?? ""
        }
        return variables
    }

    /// A signed integer: `-1` too (the Homebridge plugin read only digits).
    static func int(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return Int(text)
    }
}

/// The one `item` (or `container`) of a DIDL-Lite document.
struct DIDLItem: Sendable, Equatable {
    var id = ""
    var parentID = ""
    var restricted = ""
    var title: String?
    var upnpClass: String?
    var streamContent: String?
    var streamInfo: String?
    var res: String?
    var description: String?
    /// The DIDL of what a favourite plays, still escaped once.
    var resMD: String?
    var desc: String?
    var albumArtURIs: [String] = []

    init(_ element: XElement) {
        id = element.attribute("id") ?? ""
        parentID = element.attribute("parentID") ?? ""
        restricted = element.attribute("restricted") ?? ""
        title = element.value("title")
        upnpClass = element.value("class")
        streamContent = element.value("streamContent")
        streamInfo = element.value("streamInfo")
        res = element.value("res")
        description = element.value("description")
        resMD = element.value("resMD")
        desc = element.value("desc")
        albumArtURIs = element.children("albumArtURI").map(\.text)
    }

    /// The item of a DIDL-Lite document; nil for an empty or unreadable one.
    static func parse(_ text: String?) -> DIDLItem? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let root = try? XML.parse(text) else { return nil }
        return (root.first("item") ?? root.first("container")).map(DIDLItem.init)
    }

    /// Every item and container of a DIDL-Lite document, in order.
    static func parseAll(_ text: String?) -> [DIDLItem] {
        guard let text, !text.isEmpty, let root = try? XML.parse(text) else { return [] }
        return root.children.filter { $0.localName == "item" || $0.localName == "container" }.map(DIDLItem.init)
    }

    /// A DIDL-Lite document of this item as Sonos takes it back (for a favourite or an alarm's program): its id, parent
    /// and restriction, title, class, art, the description given and its `desc`. Not escaped as a whole.
    func rebuilt(description: String? = nil, albumArtURIs: [String]? = nil) -> String {
        var body = "<dc:title>\(XML.escape(title ?? ""))</dc:title><upnp:class>\(XML.escape(upnpClass ?? ""))</upnp:class>"
        for art in albumArtURIs ?? self.albumArtURIs { body += "<upnp:albumArtURI>\(XML.escape(art))</upnp:albumArtURI>" }
        if let description = description ?? self.description, !description.isEmpty { body += "<r:description>\(XML.escape(description))</r:description>" }
        body += #"<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\#(XML.escape(desc ?? ""))</desc>"#
        return #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">"#
            + #"<item id="\#(XML.escape(id))" parentID="\#(XML.escape(parentID))" restricted="\#(XML.escape(restricted))">\#(body)</item></DIDL-Lite>"#
    }
}

/// What an AVTransport event changes of a zone's Sonos service; nil leaves a value as it is (events are partial).
struct TransportUpdate: Sendable, Equatable {
    var on: Bool?
    var track: String?
    /// XML-escaped, as the favourites' URIs are kept.
    var uri: String?
    var actions: [String]?
    var validPlayModes: [String]?
    var repeatMode: Int?
    var shuffle: Bool?
    var crossfade: Bool?
    var sleepTimerChanged = false
    /// The track is the TV input.
    var isTVTrack = false
    /// The TV input carries a signal; false for every other track.
    var tvSignal = false
    /// A track URI scheme the plugin does not know, for a warning.
    var unknownScheme: String?

    static let trackLimit = 64

    init(_ variables: [String: String]) {
        if let state = variables["TransportState"] { on = state == "PLAYING" || state == "TRANSITIONING" }
        if let mode = variables["CurrentPlayMode"], let (repeatMode, shuffle) = PlayMode.decode(mode) {
            self.repeatMode = repeatMode
            self.shuffle = shuffle
        }
        if let crossfade = variables["CurrentCrossfadeMode"] { self.crossfade = crossfade == "1" }
        if let modes = variables["CurrentValidPlayModes"] { validPlayModes = modes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let actions = variables["CurrentTransportActions"] { self.actions = actions.components(separatedBy: ", ").filter { !$0.isEmpty } }
        sleepTimerChanged = variables["SleepTimerGeneration"] != nil

        let metadata = DIDLItem.parse(variables["CurrentTrackMetaData"])
        let enqueued = DIDLItem.parse(variables["EnqueuedTransportURIMetaData"])
        let title = metadata?.title.map(XML.decodeHTMLEntities)
        let streamContent = metadata?.streamContent.map(XML.decodeHTMLEntities)
        var track: String?
        var uri: String?
        if let trackURI = variables["CurrentTrackURI"], !trackURI.isEmpty {
            let scheme = trackURI.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            switch scheme {
            case "x-rincon-buzzer":
                track = "Sonos Chime"
                uri = trackURI
            case "x-sonos-vli", "x-sonosapi-vli":
                track = title
                uri = String(trackURI.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            case "x-rincon-stream":
                track = title
                uri = trackURI
            case "x-sonos-htastream":
                track = "TV"
                uri = trackURI
                isTVTrack = true
                tvSignal = (metadata?.streamInfo).map { $0 != "0" } ?? false
            case "aac", "x-sonosapi-stream", "x-rincon-mp3radio":
                track = streamContent?.isEmpty == false ? streamContent : enqueued?.title.map(XML.decodeHTMLEntities)
            case "hls-radio":
                track = Self.hlsTrack(streamContent) ?? enqueued?.title.map(XML.decodeHTMLEntities)
            case "x-file-cifs", "x-sonos-http", "http", "https", "x-sonos-spotify", "x-sonosprog-http", "x-sonosapi-rtrecent":
                track = title
            case "x-sonosapi-hls", "x-sonosapi-hls-static", "x-rincon":
                break
            default:
                unknownScheme = scheme
                track = title ?? ""
            }
        }
        if let enqueuedURI = variables["EnqueuedTransportURI"], !enqueuedURI.isEmpty { uri = enqueuedURI }
        if actions?.count == 1 { track = "" }
        if track == "ZPSTR_CONNECTING" || track == "ZPSTR_BUFFERING" { track = nil }
        self.track = track.map { Self.truncated($0, toBytes: Self.trackLimit) }
        self.uri = uri.map(XML.escape)
    }

    /// `TYPE=SNG|TITLE <t>|ARTIST <a>|ALBUM…` → `<a> - <t>`, or `<t>` without an artist.
    static func hlsTrack(_ content: String?) -> String? {
        guard let content, content.hasPrefix("TYPE=SNG|TITLE "),
              let artistRange = content.range(of: "|ARTIST "), let albumRange = content.range(of: "|ALBUM", range: artistRange.upperBound..<content.endIndex)
        else { return nil }
        let title = String(content[content.index(content.startIndex, offsetBy: 15)..<artistRange.lowerBound])
        let artist = String(content[artistRange.upperBound..<albumRange.lowerBound])
        return artist.isEmpty ? title : "\(artist) - \(title)"
    }

    /// At most `limit` bytes of UTF-8, cut on a character.
    static func truncated(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + character.utf8.count <= limit else { break }
            result.append(character)
        }
        return result
    }
}

/// Sonos's play modes as (repeat, shuffle): repeat 0 off, 1 one, 2 all.
enum PlayMode {
    static func decode(_ mode: String) -> (Int, Bool)? {
        switch mode {
        case "NORMAL": (0, false)
        case "REPEAT_ONE": (1, false)
        case "REPEAT_ALL": (2, false)
        case "SHUFFLE_NOREPEAT": (0, true)
        case "SHUFFLE_REPEAT_ONE": (1, true)
        case "SHUFFLE": (2, true)
        default: nil
        }
    }

    static func encode(repeatMode: Int, shuffle: Bool) -> String {
        switch (repeatMode, shuffle) {
        case (1, false): "REPEAT_ONE"
        case (2, false): "REPEAT_ALL"
        case (0, true): "SHUFFLE_NOREPEAT"
        case (1, true): "SHUFFLE_REPEAT_ONE"
        case (2, true): "SHUFFLE"
        default: "NORMAL"
        }
    }
}

/// A Sonos alarm (`ListAlarms`' `CurrentAlarmList`), kept whole: `UpdateAlarm` writes it back with only Enabled changed.
struct Alarm: Sendable, Equatable {
    var id: String
    var startTime: String
    var duration: String
    var recurrence: String
    var enabled: Bool
    var roomUUID: String
    var programURI: String
    var programMetaData: String
    var playMode: String
    var volume: String
    var includeLinkedZones: String

    static func list(_ text: String?) throws -> [Alarm] {
        guard let text, !text.isEmpty else { return [] }
        return try XML.parse(text).all("Alarm").compactMap { element in
            guard let id = element.attribute("ID") else { return nil }
            return Alarm(
                id: id, startTime: element.attribute("StartTime") ?? "", duration: element.attribute("Duration") ?? "",
                recurrence: element.attribute("Recurrence") ?? "", enabled: element.attribute("Enabled") == "1",
                roomUUID: element.attribute("RoomUUID") ?? "", programURI: element.attribute("ProgramURI") ?? "",
                programMetaData: element.attribute("ProgramMetaData") ?? "", playMode: element.attribute("PlayMode") ?? "",
                volume: element.attribute("Volume") ?? "", includeLinkedZones: element.attribute("IncludeLinkedZones") ?? "")
        }
    }

    /// `Sonos Chime`, the program's title, or `unknown`.
    var track: String {
        if programURI == "x-rincon-buzzer:0" { return "Sonos Chime" }
        if let title = DIDLItem.parse(programMetaData)?.title, !title.isEmpty { return TransportUpdate.truncated(title, toBytes: TransportUpdate.trackLimit) }
        return "unknown"
    }

    /// `UpdateAlarm`'s arguments, with `enabled`.
    func updateArguments(enabled: Bool) -> [(String, String)] {
        let metadata = DIDLItem.parse(programMetaData).map { XML.escape($0.rebuilt()) } ?? ""
        return [
            ("ID", id), ("StartLocalTime", startTime), ("Duration", duration), ("Recurrence", recurrence), ("Enabled", enabled ? "1" : "0"),
            ("RoomUUID", roomUUID), ("ProgramURI", XML.escape(programURI)), ("ProgramMetaData", metadata), ("PlayMode", playMode),
            ("Volume", volume), ("IncludeLinkedZones", includeLinkedZones),
        ]
    }
}

/// A Sonos favourite (`Browse FV:2`).
struct Favourite: Sendable, Equatable {
    var title: String
    /// XML-escaped.
    var uri: String
    /// What it plays is a container (a playlist, an album): played through the queue.
    var isContainer: Bool
    /// The rebuilt DIDL, XML-escaped for a SOAP body; empty without metadata.
    var metadata: String

    /// The favourites of a `Browse` Result, in Sonos's order; a title seen twice keeps its first place and its last
    /// value, as the Homebridge plugin's map by title does.
    static func list(_ result: String?) -> [Favourite] {
        var favourites: [Favourite] = []
        var index: [String: Int] = [:]
        for item in DIDLItem.parseAll(result) {
            guard let title = item.title, let res = item.res else { continue }
            let played = DIDLItem.parse(item.resMD)
            let favourite = Favourite(
                title: title, uri: XML.escape(res), isContainer: played?.upnpClass?.hasPrefix("object.container.") == true,
                metadata: played.map { XML.escape($0.rebuilt(description: item.description, albumArtURIs: item.albumArtURIs)) } ?? "")
            if let position = index[title] {
                favourites[position] = favourite
            } else {
                index[title] = favourites.count
                favourites.append(favourite)
            }
        }
        return favourites
    }
}
