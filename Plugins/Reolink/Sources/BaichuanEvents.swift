import Foundation

/// What a Baichuan push says (5.3.3, 5.4.1). Channels are 0-based.
enum ReolinkPush: Sendable, Equatable {
    /// An `AlarmEvent`: with a `status`, motion (`MD`, or `other` among the AI types: a battery camera's PIR), the
    /// doorbell's visitor and tamper; with an `AItype`, the AI types detected now.
    case alarm(channel: Int, motion: Bool?, visitor: Bool?, aiDetected: Set<String>?)
    /// `cmd_id` 145: a battery camera asleep (`standby`) or awake.
    case sleep(channel: Int, asleep: Bool)
    /// `cmd_id` 291: a floodlight turned on or off.
    case floodlight(channel: Int, on: Bool)
    /// `cmd_id` 547: a siren playing or not.
    case siren(channel: Int, playing: Bool)
    /// `DayNightEvent`: informational.
    case dayNight(channel: Int, mode: String)
}

enum BaichuanEvents {
    /// The AI types the plugin knows; others are logged once.
    static let knownAITypes: Set<String> = ["people", "vehicle", "dog_cat", "face", "package", "other", "none"]

    /// The pushes of a message's XML. `unknown` collects tags and AI types the parser does not use, for a debug line.
    static func parse(command: UInt32, xml: String, unknown: inout Set<String>) -> [ReolinkPush] {
        guard !xml.isEmpty, let root = try? BXParser.parse(xml) else { return [] }
        switch command {
        case 33:
            return alarms(root, unknown: &unknown)
        case 145:
            return root.all("ChannelInfo").compactMap { info in
                guard let channel = info.value("channelId").flatMap(Int.init), let state = info.value("loginState") else { return nil }
                return .sleep(channel: channel, asleep: state == "standby")
            }
        case 291:
            // The list's element names are not known from the sources (Gaps): any element with `channel` and `status`.
            return ([root] + root.descendants).compactMap { element in
                guard let channel = element.value("channel").flatMap(Int.init), let status = element.value("status").flatMap(Int.init) else { return nil }
                return .floodlight(channel: channel, on: status == 1)
            }
        case 547:
            return root.all("SirenStatus").compactMap { element in
                guard let channel = element.value("channel").flatMap(Int.init), let status = element.value("status").flatMap(Int.init) else { return nil }
                return .siren(channel: channel, playing: status == 1)
            }
        default:
            return []
        }
    }

    /// root → every child → every grandchild, whatever the list is called (reolink-aio does not check it).
    private static func alarms(_ root: BXElement, unknown: inout Set<String>) -> [ReolinkPush] {
        var pushes: [ReolinkPush] = []
        for list in root.children {
            for event in list.children {
                guard let channel = event.value("channelId").flatMap(Int.init) else { continue }
                switch event.name {
                case "AlarmEvent":
                    let types = event.value("AItype").map { text in
                        Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    }
                    for type in types ?? [] where !knownAITypes.contains(type) { unknown.insert("AI type \(type)") }
                    var motion: Bool?
                    var visitor: Bool?
                    if let status = event.value("status") {
                        motion = status.contains("MD") || (types?.contains("other") ?? false)
                        visitor = status.contains("visitor")
                    }
                    pushes.append(.alarm(channel: channel, motion: motion, visitor: visitor, aiDetected: types))
                case "DayNightEvent":
                    pushes.append(.dayNight(channel: channel, mode: event.value("mode") ?? ""))
                default:
                    unknown.insert("event \(event.name)")
                }
            }
        }
        return pushes
    }
}
