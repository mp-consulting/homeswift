import Foundation

/// A zone player as the household's `ZoneGroupTopology` event describes it, with what the plugin derives from it: its
/// role in a stereo pair or a home theatre, its channel, its zone's and group's names.
struct TopologyPlayer: Sendable, Equatable {
    enum Role: String, Sendable { case master, slave, satellite }

    struct Battery: Sendable, Equatable {
        var level: Int
        var charging: Bool
    }

    var id: String
    var address: String?
    var zoneName: String
    var bootSeq: Int?
    var invisible = false
    var airPlay = false
    /// In a `ChannelMapSet`: a stereo pair, perhaps with a sub.
    var stereoPair = false
    var homeTheatre = false
    var battery: Battery?
    var role = Role.master
    /// The master's id (its own for a master).
    var zone: String
    /// `L`, `R`, `Sub`, `LS`, `RS`, …; empty for a home theatre's master; nil outside a map set.
    var channel: String?
    var slaves: [String] = []
    var satellites: [String] = []
    /// `Living Room (LS+RS+Sub)`, `Bedroom (L+R)`, or the zone name.
    var zoneDisplayName: String
    /// The group's coordinator.
    var zoneGroup: String = ""
    var groupName = ""
    var groupShortName = ""

    /// The zone name, with ` (<channel>)` for a non-empty channel.
    var zonePlayerName: String { channel.flatMap { $0.isEmpty ? nil : "\(zoneName) (\($0))" } ?? zoneName }
    /// The zone name, with ` <channel>`: the accessory's first name.
    var accessoryName: String { channel.flatMap { $0.isEmpty ? nil : "\(zoneName) \($0)" } ?? zoneName }
}

/// A household's `ZoneGroupState`, decoded.
struct Topology: Sendable, Equatable {
    var players: [String: TopologyPlayer] = [:]
    /// Zone name, then master id; each master followed by its slaves and satellites.
    var order: [String] = []
    var vanished: [String] = []
    /// `MuseHouseholdId` up to its first `.` (S2).
    var household: String?

    /// Decodes a ZoneGroupTopology NOTIFY body.
    init(event body: Data) throws {
        let properties = try Events.properties(body)
        try self.init(zoneGroupState: properties["ZoneGroupState"] ?? "", museHouseholdID: properties["MuseHouseholdId"])
    }

    init(zoneGroupState: String, museHouseholdID: String? = nil) throws {
        household = museHouseholdID.flatMap { $0.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) }.flatMap { $0.isEmpty ? nil : $0 }
        let roots = try XML.parseFragment(zoneGroupState)
        let groups = roots.flatMap { $0.all("ZoneGroup") }
        vanished = roots.flatMap { $0.all("VanishedDevices") }.flatMap { $0.children("Device") }.compactMap { $0.attribute("UUID") }
        for group in groups {
            let coordinator = group.attribute("Coordinator") ?? ""
            var members: [TopologyPlayer] = []
            for member in group.children("ZoneGroupMember") {
                members.append(Self.player(member))
                members.append(contentsOf: member.children("Satellite").map(Self.player))
            }
            let masters = members.filter { $0.role == .master && !$0.invisible }
            let coordinatorName = members.first { $0.id == coordinator }?.zoneName ?? masters.first?.zoneName ?? ""
            let others = masters.filter { $0.id != coordinator }.map(\.zoneName).sorted()
            for var player in members {
                player.zoneGroup = coordinator
                player.groupName = ([coordinatorName] + others).joined(separator: " + ")
                player.groupShortName = others.isEmpty ? coordinatorName : "\(coordinatorName) + \(others.count)"
                players[player.id] = player
            }
        }
        // Slaves and satellites take their master's zone display name; the master lists them.
        for (id, player) in players where player.role != .master {
            guard let master = players[player.zone] else { continue }
            players[id]?.zoneDisplayName = master.zoneDisplayName
            if player.role == .slave, !master.slaves.contains(id) { players[player.zone]?.slaves.append(id) }
            if player.role == .satellite, !master.satellites.contains(id) { players[player.zone]?.satellites.append(id) }
        }
        let masters = players.values.filter { $0.role == .master }.sorted { ($0.zoneName, $0.id) < ($1.zoneName, $1.id) }
        for master in masters {
            order.append(master.id)
            let current = players[master.id] ?? master
            order.append(contentsOf: current.slaves.sorted())
            order.append(contentsOf: current.satellites.sorted())
        }
        // Players whose master is not listed still come last, so none is lost.
        order.append(contentsOf: players.keys.filter { !order.contains($0) }.sorted())
    }

    private static func player(_ element: XElement) -> TopologyPlayer {
        let id = element.attribute("UUID") ?? ""
        let zoneName = element.attribute("ZoneName") ?? ""
        var player = TopologyPlayer(id: id, zoneName: zoneName, zone: id, zoneDisplayName: zoneName)
        player.address = element.attribute("Location").flatMap { URL(string: $0)?.host }
        player.bootSeq = element.attribute("BootSeq").flatMap { Int($0) }
        player.invisible = element.attribute("Invisible") == "1"
        player.airPlay = element.attribute("AirPlayEnabled") == "1"
        player.battery = element.attribute("MoreInfo").flatMap(battery)
        let homeTheatre = element.attribute("HTSatChanMapSet")
        let stereo = element.attribute("ChannelMapSet")
        player.homeTheatre = homeTheatre != nil
        player.stereoPair = stereo != nil
        guard let set = homeTheatre ?? stereo else { return player }
        let entries = set.split(separator: ";").map { entry -> (id: String, label: String) in
            let parts = entry.split(separator: ":", maxSplits: 1)
            return (String(parts.first ?? ""), label(parts.count > 1 ? String(parts[1]) : ""))
        }
        guard let position = entries.firstIndex(where: { $0.id == id }), let master = entries.first?.id else { return player }
        // The labels sorted, then given to the ids by position, as the Homebridge plugin does (its LED subtypes come
        // from it): a satellite's label is not necessarily its own channel.
        let labels = entries.map(\.label).sorted()
        player.zone = master
        player.role = position == 0 ? .master : homeTheatre != nil ? .satellite : .slave
        player.channel = labels[position]
        let shown = homeTheatre != nil ? Array(labels.dropFirst()) : labels
        var joined = shown.joined(separator: "+")
        joined = joined.replacingOccurrences(of: "+Sub+Sub", with: "+Subx2")
        if !joined.isEmpty { player.zoneDisplayName = "\(zoneName) (\(joined))" }
        return player
    }

    /// A channel code's label: `LF,LF` → `L`, `SW` → `Sub`, `LR,RR` → `LS+RS`; an unknown code as it is.
    static func label(_ channels: String) -> String {
        switch channels {
        case "LF,LF": "L"
        case "RF,RF": "R"
        case "SW,SW", "SW": "Sub"
        case "LF,RF": ""
        case "LR", "LR,LTR": "LS"
        case "RR", "RR,RTR": "RS"
        case "LR,RR": "LS+RS"
        default: channels
        }
    }

    /// `RawBattPct:87,BattPct:85,BattChg:NOT_CHARGING,BattTmp:31` → 85 %, not charging.
    static func battery(_ moreInfo: String) -> TopologyPlayer.Battery? {
        var fields: [String: String] = [:]
        for pair in moreInfo.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let level = fields["BattPct"].flatMap({ Int($0) }), let charging = fields["BattChg"] else { return nil }
        return TopologyPlayer.Battery(level: min(max(level, 0), 100), charging: charging == "CHARGING")
    }
}
