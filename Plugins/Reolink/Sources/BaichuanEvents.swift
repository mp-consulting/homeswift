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
    /// `cmd_id` 623: privacy mode on or off (addendum C).
    case privacy(channel: Int, on: Bool)
    /// `DayNightEvent`: informational.
    case dayNight(channel: Int, mode: String)
    /// `cmd_id` 252 (`BatteryList`) or a 253 reply: a battery camera's battery (ReolinkBattery.md 8).
    case battery(channel: Int, report: ReolinkBatteryReport)
}

/// A `BatteryInfo` element (ReolinkBattery.md 8).
struct ReolinkBatteryReport: Sendable, Equatable, Codable {
    var percent: Int?
    /// `charging`, `chargeComplete` or `none` (discharging); anything else counts as discharging.
    var chargeStatus: String
    var adapter: String?
    var lowPower: Bool
    /// `powerSupplyStatus` `normal`: on wired power (newer firmware).
    var wiredPower: Bool

    init(percent: Int?, chargeStatus: String = "none", adapter: String? = nil, lowPower: Bool = false, wiredPower: Bool = false) {
        self.percent = percent
        self.chargeStatus = chargeStatus
        self.adapter = adapter
        self.lowPower = lowPower
        self.wiredPower = wiredPower
    }

    init?(_ element: BXElement) {
        let percent = element.value("batteryPercent").flatMap(Int.init).map { min(100, max(0, $0)) }
        let status = element.value("chargeStatus") ?? "none"
        guard percent != nil || element.value("chargeStatus") != nil else { return nil }
        self.init(percent: percent, chargeStatus: status, adapter: element.value("adapterStatus"), lowPower: element.value("lowPower") == "1",
                  wiredPower: element.value("powerSupplyStatus") == "normal")
    }

    /// HomeKit's Charging State: only `charging` (`chargeComplete` is not).
    var charging: Bool { chargeStatus == "charging" }
    /// Status Low Battery: `lowPower`, or a level under 20.
    var isLow: Bool { lowPower || (percent.map { $0 < 20 } ?? false) }

    /// The `BatteryInfo` elements of an XML text, by channel.
    static func reports(_ root: BXElement) -> [(channel: Int, report: ReolinkBatteryReport)] {
        let elements = root.name == "BatteryInfo" ? [root] : root.all("BatteryInfo")
        return elements.compactMap { element in
            guard let report = ReolinkBatteryReport(element) else { return nil }
            return (element.value("channelId").flatMap(Int.init) ?? 0, report)
        }
    }
}

enum BaichuanEvents {
    /// The AI types the plugin knows; others are logged once.
    static let knownAITypes: Set<String> = ["people", "vehicle", "dog_cat", "face", "package", "other", "none"]

    /// The commands `parse` reads pushes from (33 also turns push events active); others are not decrypted.
    static let pushCommands: Set<UInt32> = [33, 145, 291, 623, 252, 253, 547]

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
        case 623:
            // `status` elements, or the root itself, each with `sleep` and a `channelId` (absent: 0).
            let statuses = root.all("status")
            return (statuses.isEmpty ? [root] : statuses).compactMap { element in
                guard let sleep = element.value("sleep").flatMap(Int.init) else { return nil }
                return .privacy(channel: element.value("channelId").flatMap(Int.init) ?? 0, on: sleep == 1)
            }
        case 252, 253:
            return ReolinkBatteryReport.reports(root).map { .battery(channel: $0.channel, report: $0.report) }
        case 547:
            return root.all("SirenStatus").compactMap { element in
                guard let channel = element.value("channel").flatMap(Int.init), let status = element.value("status").flatMap(Int.init) else { return nil }
                return .siren(channel: channel, playing: status == 1)
            }
        default:
            return []
        }
    }

    /// `cmd_id` 199's abilities by channel: every `item` of the support lists, wherever they sit, its `chnID` and its
    /// other children (their integer text); a `subItem` (a lens) is left out.
    static func abilities(_ root: BXElement) -> [Int: [String: Int]] {
        var result: [Int: [String: Int]] = [:]
        for item in root.all("item") {
            guard let channel = item.value("chnID").flatMap(Int.init) else { continue }
            for ability in item.children where ability.name != "chnID" && ability.name != "subItem" {
                if let version = Int(ability.text.trimmingCharacters(in: .whitespacesAndNewlines)) { result[channel, default: [:]][ability.name] = version }
            }
        }
        return result
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
