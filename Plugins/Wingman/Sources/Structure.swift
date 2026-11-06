import Foundation
import Homeswift
import HomeswiftPlugin

/// Apple Home's rooms, scenes and automations as a Wingman that serves them (`/info`'s "structure" feature) last gave
/// them, kept by its `Link`: read with the homes, again at a "scenes" or "automations" event and after each edit.
/// docs/apple-home-design.md has the design.
struct Structure: Sendable {
    struct Home: Sendable {
        var id: String
        var name: String
        var editable: Bool
        var rooms: [WingmanAPI.Room]
        var defaultRoom: WingmanAPI.Room? = nil
        var zones: [WingmanAPI.Zone] = []
        var serviceGroups: [WingmanAPI.ServiceGroup] = []
    }

    /// An accessory of the homes, mirrored or not: what an action names it by.
    struct Device: Sendable {
        var name: String
        var room: String?
        var home: String
        /// Its writable characteristics' HomeKit ids, by type.
        var writable: [HAPUUID: String]
        var serialNumber: String? = nil
        /// Where it is, if it is one of Homeswift's own.
        var homeswift: Homeswift? = nil
        /// Its room's id, nil in the Default Room (a Wingman with "home-link").
        var roomID: String? = nil
        /// Its services' HomeKit ids, the one doing its main thing first: what a service group holds.
        var services: [String] = []
    }

    /// Where one of Homeswift's own accessories is in the homes.
    enum Homeswift: Sendable, Equatable {
        /// Behind the Homeswift bridge with this Serial Number (its HAP device ID).
        case bridge(String)
        /// Published on its own (a television, a camera): not behind a bridge.
        case own
        /// Behind a bridge that says it is Homeswift's (its manufacturer or model) that Wingman does not name: an
        /// older Wingman, or one of another Homeswift.
        case unnamedBridge
    }

    /// Whether Wingman's owner lets bridges edit now.
    var allowed: Bool
    /// Whether Wingman gives rooms, zones and groups by id and edits them ("home-link"): it can be the Home Link.
    var servesHomeLink = false
    /// The home Homeswift's bridge is in: the Home (GLOSSARY.md), whose rooms are Homeswift's.
    var bridgeHome: String?
    var homes: [Home]
    var devices: [String: Device]
    /// The accessories Homeswift mirrors, by HomeKit id.
    var mirrored: Set<String>
    var scenes: [WingmanAPI.Scene] = []
    var automations: [WingmanAPI.Automation] = []

    /// `bridges` are the Serial Numbers of Homeswift's bridges (`PluginContext.homeswiftBridgeSerialNumbers`), `own` those of
    /// the accessories Homeswift publishes on their own servers.
    init(allowed: Bool, homes: [WingmanAPI.Home], mirrored: Set<String>, bridges: Set<String> = [], own: Set<String> = [], homeLink: Bool = false) {
        self.allowed = allowed
        self.mirrored = mirrored
        servesHomeLink = homeLink
        self.homes = homes.compactMap { home in
            home.id.map {
                Home(id: $0, name: home.name, editable: home.editable == true, rooms: home.rooms ?? [], defaultRoom: home.defaultRoom,
                     zones: home.zones ?? [], serviceGroups: home.serviceGroups ?? [])
            }
        }
        bridgeHome = Self.bridgeHome(of: homes, bridges: bridges)
        // The accessories of the homes that are Homeswift's bridges, by HomeKit id: their Serial Number is their device ID.
        var homeswiftBridges: [String: String] = [:]
        for accessory in homes.flatMap(\.accessories) {
            if let serial = accessory.serialNumber?.uppercased(), bridges.contains(serial) { homeswiftBridges[accessory.id] = serial }
        }
        var devices: [String: Device] = [:]
        for home in homes {
            guard let homeID = home.id else { continue }
            for accessory in home.accessories {
                var writable: [HAPUUID: String] = [:]
                for service in accessory.services {
                    for item in service.characteristics where item.properties.contains("write") {
                        if let id = item.id, writable[HAPUUID(item.type)] == nil { writable[HAPUUID(item.type)] = id }
                    }
                }
                let homeswift: Homeswift?
                if mirrored.contains(accessory.id) {
                    homeswift = nil
                } else if let bridge = accessory.bridge {
                    if let id = bridge.id, let serial = homeswiftBridges[id] {
                        homeswift = .bridge(serial)
                    } else if bridge.id == nil, bridge.manufacturer == "Homeswift" || bridge.model == "Homeswift" {
                        homeswift = .unnamedBridge
                    } else {
                        homeswift = nil
                    }
                } else {
                    homeswift = accessory.serialNumber.map(own.contains) == true ? .own : nil
                }
                let information = ServiceType.accessoryInformation.uuid
                let main = accessory.services.filter { HAPUUID($0.type) != information }.sorted { ($0.primary == true ? 0 : 1) < ($1.primary == true ? 0 : 1) }
                devices[accessory.id] = Device(
                    name: accessory.name, room: accessory.room, home: homeID, writable: writable, serialNumber: accessory.serialNumber,
                    homeswift: homeswift, roomID: accessory.roomID, services: main.compactMap(\.id))
            }
        }
        self.devices = devices
    }

    func home(_ id: String) -> Home? { homes.first { $0.id == id } }

    /// The id of the home whose accessories include the bridge with one of these Serial Numbers (Homeswift's).
    static func bridgeHome(of homes: [WingmanAPI.Home], bridges: Set<String>) -> String? {
        homes.first { home in home.accessories.contains { $0.serialNumber.map { bridges.contains($0.uppercased()) } == true } }?.id
    }

    // MARK: The Home Link

    /// The Home as Homeswift's Home Link gives it: the bridge's home, with Homeswift's ids for the accessories it has.
    /// nil when this Wingman cannot be the Home Link, or sees no home with the bridge in it.
    func homeSnapshot(in context: PluginContext) -> HomeSnapshot? {
        guard servesHomeLink, let id = bridgeHome, let home = home(id) else { return nil }
        var placements: [String: String?] = [:]
        var byService: [String: String] = [:]
        for (deviceID, device) in devices.sorted(by: { $0.key < $1.key }) where device.home == id {
            guard let accessoryID = homeswiftID(of: deviceID, in: context) else { continue }
            placements[accessoryID] = .some(device.roomID)
            for service in device.services { byService[service] = accessoryID }
        }
        let groups = home.serviceGroups.map { group in
            var seen: Set<String> = []
            let members = group.services.compactMap { byService[$0] }.filter { seen.insert($0).inserted }
            return HomeSnapshot.Group(id: group.id, name: group.name, members: members)
        }
        return HomeSnapshot(
            homeID: home.id, homeName: home.name, rooms: home.rooms.map { HomeSnapshot.Room(id: $0.id, name: $0.name) },
            zones: home.zones.compactMap { zone in zone.id.map { HomeSnapshot.Zone(id: $0, name: zone.name, rooms: zone.roomIDs ?? []) } },
            groups: groups, placements: placements)
    }

    /// The HomeKit id of the service a group holds for one of Homeswift's accessories: the one doing its main thing.
    func groupService(of accessoryID: String, in context: PluginContext) -> String? {
        homeKitID(of: accessoryID, place: context.publishedPlace(ofAccessory: accessoryID)).flatMap { devices[$0]?.services.first }
    }

    /// The HomeKit id of a Homeswift accessory in these homes: a mirror by its id, one of Homeswift's own by where it is
    /// published (`place`): its Serial Number behind that bridge, or among the accessories on their own. Never a home's
    /// own accessory of the same serial number, such as the light a hub also brings to Apple Home.
    func homeKitID(of accessoryID: String, place: PluginContext.PublishedPlace?) -> String? {
        if let id = Self.homeKitID(accessoryID), devices[id] != nil { return id }
        guard let place else { return nil }
        let wanted: Homeswift = place.bridge.map(Homeswift.bridge) ?? .own
        var matches = devices.filter { $0.value.homeswift == wanted && $0.value.serialNumber == place.serialNumber }.map(\.key)
        // A Wingman that does not name bridges: the bridges that say they are Homeswift's, as before.
        if matches.isEmpty, place.bridge != nil {
            matches = devices.filter { $0.value.homeswift == .unnamedBridge && $0.value.serialNumber == place.serialNumber }.map(\.key)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Homeswift's id of an accessory in these homes: a mirror's, or one of Homeswift's own (by where `context` publishes
    /// it); nil for one Homeswift does not have.
    func homeswiftID(of id: String, in context: PluginContext) -> String? {
        if mirrored.contains(id) { return Self.homeswiftID(id) }
        guard let device = devices[id], let serialNumber = device.serialNumber, let homeswift = device.homeswift else { return nil }
        switch homeswift {
        case .bridge(let bridge): return context.publishedAccessoryID(at: .init(bridge: bridge, serialNumber: serialNumber))
        case .own: return context.publishedAccessoryID(at: .init(bridge: nil, serialNumber: serialNumber))
        case .unnamedBridge: return context.publishedAccessoryID(serialNumber: serialNumber)
        }
    }

    /// Whether an edit of this home would go through: the owner allows it and this Mac's user administers the home.
    func editable(home id: String) -> Bool { allowed && home(id)?.editable == true }

    // MARK: Names

    static func homeswiftID(_ accessory: String) -> String { "\(WingmanPlugin.platform):\(accessory)" }

    static func homeKitID(_ accessoryID: String) -> String? {
        let prefix = "\(WingmanPlugin.platform):"
        return accessoryID.hasPrefix(prefix) ? String(accessoryID.dropFirst(prefix.count)) : nil
    }

    /// Homeswift's name for a characteristic type, or its UUID when Homeswift does not know it.
    static func characteristicName(_ type: String?) -> String {
        guard let type else { return "" }
        return CharacteristicType.known(uuid: HAPUUID(type))?.name ?? type
    }

    // MARK: Scenes

    func pluginScene(_ scene: WingmanAPI.Scene) -> PluginScene {
        let accessories = Self.unique(scene.actions.map(\.accessory))
        let rooms = Set(accessories.compactMap { devices[$0]?.room })
        var capabilities: Set<PluginScene.Capability> = [.recall]
        if editable(home: scene.home) {
            if scene.builtIn != true { capabilities.formUnion([.rename, .delete]) }
            if (scene.unsupported ?? 0) == 0 { capabilities.insert(.update) }
        }
        return PluginScene(
            id: scene.id, name: scene.name, room: rooms.count == 1 ? rooms.first : nil,
            accessoryIDs: accessories.filter(mirrored.contains).map(Self.homeswiftID), colours: Self.colours(scene.actions),
            capabilities: capabilities)
    }

    /// The lights' colours, up to five: from Hue and Saturation, else Color Temperature.
    static func colours(_ actions: [WingmanAPI.Action]) -> [String] {
        var colours: [String] = []
        for accessory in unique(actions.map(\.accessory)) {
            var hue: Double?, saturation: Double?, mireds: Double?
            for action in actions where action.accessory == accessory {
                switch action.type.map(HAPUUID.init) {
                case CharacteristicType.hue.uuid: hue = action.value.doubleValue
                case CharacteristicType.saturation.uuid: saturation = action.value.doubleValue
                case CharacteristicType.colorTemperature.uuid: mireds = action.value.doubleValue
                default: break
                }
            }
            if let hue, let saturation {
                colours.append(hex(hue: hue, saturation: saturation))
            } else if let mireds {
                let colour = ColorUtils.colorTemperatureToHueAndSaturation(mireds)
                colours.append(hex(hue: colour.hue, saturation: colour.saturation))
            }
        }
        return Array(colours.prefix(5))
    }

    /// `#rrggbb` of a hue (0 to 360) and saturation (0 to 100) at full brightness.
    static func hex(hue: Double, saturation: Double) -> String {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation, 0), 100) / 100
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (1, x, 0)
        case 1: (x, 1, 0)
        case 2: (0, 1, x)
        case 3: (0, x, 1)
        case 4: (x, 0, 1)
        default: (1, 0, x)
        }
        func byte(_ value: Double) -> String {
            let text = String(Int(((1 - s) + s * value) * 255).clamped(0, 255), radix: 16)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + byte(r) + byte(g) + byte(b)
    }

    /// The characteristics a scene light sets.
    static let lightTypes: [HAPUUID] = [
        CharacteristicType.on.uuid, CharacteristicType.brightness.uuid, CharacteristicType.hue.uuid,
        CharacteristicType.saturation.uuid, CharacteristicType.colorTemperature.uuid,
    ]

    /// A scene's lights as actions: On, and when on its Brightness and its colour (Hue and Saturation) or white (Color
    /// Temperature), each a characteristic the light has. A light the homes do not have is refused.
    func actions(for lights: [PluginSceneLight]) throws -> [WingmanAPI.Action] {
        var actions: [WingmanAPI.Action] = []
        for light in lights {
            guard let id = Self.homeKitID(light.accessoryID), let device = devices[id] else {
                throw PluginSceneError("\(light.accessoryID) is not an Apple Home accessory")
            }
            func add(_ type: CharacteristicType, _ value: JSONValue) {
                if let characteristic = device.writable[type.uuid] { actions.append(.init(accessory: id, characteristic: characteristic, value: value)) }
            }
            add(.on, .bool(light.on))
            guard light.on else { continue }
            if let brightness = light.brightness { add(.brightness, .number(brightness.rounded())) }
            if light.hasColour, let hue = light.hue, let saturation = light.saturation {
                add(.hue, .number(hue))
                add(.saturation, .number(saturation))
            } else if let mireds = light.colorTemperature {
                add(.colorTemperature, .number(Double(mireds)))
            }
        }
        return actions
    }

    /// The scene's actions with these lights' replaced: its other actions (a plug, a blind) stay.
    func replacingLights(_ lights: [PluginSceneLight], in scene: WingmanAPI.Scene) throws -> [WingmanAPI.Action] {
        let replaced = Set(lights.compactMap { Self.homeKitID($0.accessoryID) })
        let lightCharacteristics = Set(replaced.flatMap { id in Self.lightTypes.compactMap { devices[id]?.writable[$0] } })
        let kept = scene.actions.filter { !(replaced.contains($0.accessory) && lightCharacteristics.contains($0.characteristic)) }
        return kept.map(\.sent) + (try actions(for: lights))
    }

    /// The home every one of these lights is in, when they share one.
    func home(of accessoryIDs: [String]) -> Home? {
        let homes = Set(accessoryIDs.map { Self.homeKitID($0).flatMap { devices[$0]?.home } })
        guard homes.count == 1, let id = homes.first ?? nil else { return nil }
        return home(id)
    }

    // MARK: Automations

    func pluginAutomation(_ automation: WingmanAPI.Automation, place: String?) -> PluginAutomation {
        let triggers: [PluginAutomationTrigger] = switch automation.trigger.kind {
        case "time": automation.trigger.time.map { [.time(Self.time($0))] } ?? [.other("time")]
        default: (automation.trigger.events ?? []).map(Self.trigger)
        }
        var mentioned = (automation.trigger.events ?? []).compactMap(\.accessory) + (automation.endEvents ?? []).compactMap(\.accessory)
        mentioned += (automation.conditions ?? []).compactMap(\.accessory) + (automation.actions ?? []).map(\.accessory)
        var names: [String: String] = [:]
        for id in mentioned { if let device = devices[id] { names[Self.homeswiftID(id)] = device.name } }
        var capabilities: Set<PluginAutomation.Capability> = []
        if editable(home: automation.home) {
            capabilities = [.enable, .rename, .scenes, .delete]
            if triggers.count == 1, case .time = triggers[0] { capabilities.insert(.time) }
            if (automation.unsupported ?? 0) == 0 { capabilities.insert(.actions) }
        }
        return PluginAutomation(
            id: automation.id, name: automation.name, enabled: automation.enabled, place: place, triggers: triggers,
            endTriggers: (automation.endEvents ?? []).map(Self.trigger), conditions: (automation.conditions ?? []).map(Self.condition),
            sceneIDs: automation.scenes ?? [], actions: (automation.actions ?? []).map(Self.action), names: names,
            lastRun: automation.lastFired.flatMap { ISO8601DateFormatter().date(from: $0) }, capabilities: capabilities)
    }

    static func time(_ time: WingmanAPI.Time) -> PluginAutomationTime {
        PluginAutomationTime(
            hour: time.hour, minute: time.minute, solarEvent: time.significant.flatMap(PluginAutomationTime.SolarEvent.init(rawValue:)),
            offsetMinutes: time.offsetMinutes ?? 0, weekdays: time.weekdays ?? [])
    }

    static func time(_ time: PluginAutomationTime) -> WingmanAPI.Time {
        WingmanAPI.Time(
            hour: time.solarEvent == nil ? time.hour : nil, minute: time.solarEvent == nil ? time.minute : nil, significant: time.solarEvent?.rawValue,
            offsetMinutes: time.solarEvent == nil ? nil : time.offsetMinutes, weekdays: time.weekdays.isEmpty ? nil : time.weekdays)
    }

    static func trigger(_ event: WingmanAPI.TriggerEvent) -> PluginAutomationTrigger {
        switch event.kind {
        case "characteristic", "threshold":
            guard let accessory = event.accessory else { return .other(event.text ?? event.kind) }
            return .accessory(accessoryID: homeswiftID(accessory), characteristic: characteristicName(event.type), value: event.value,
                              minimum: event.min, maximum: event.max)
        case "presence": return .presence(who: event.who ?? "anyone", arriving: event.arriving ?? true)
        case "duration": return event.seconds.map { .duration(seconds: $0) } ?? .other(event.text ?? "duration")
        case "time": return event.time.map { .time(time($0)) } ?? .other(event.text ?? "time")
        default: return .other(event.text ?? event.kind)
        }
    }

    static func condition(_ condition: WingmanAPI.Condition) -> PluginAutomationCondition {
        switch condition.kind {
        case "time": return .time(after: condition.after.map(time), before: condition.before.map(time))
        case "characteristic":
            guard let accessory = condition.accessory, let value = condition.value else { return .other(condition.text ?? condition.kind) }
            return .accessory(accessoryID: homeswiftID(accessory), characteristic: characteristicName(condition.type),
                              comparison: condition.comparison ?? "==", value: value)
        case "presence": return .presence(who: condition.who ?? "anyone", home: condition.home ?? true)
        default: return .other(condition.text ?? condition.kind)
        }
    }

    static func action(_ action: WingmanAPI.Action) -> PluginAutomationAction {
        PluginAutomationAction(accessoryID: homeswiftID(action.accessory), characteristic: characteristicName(action.type), value: action.value)
    }

    /// Homeswift's action as Wingman's: the accessory by HomeKit id, the characteristic by its id there, found by type
    /// name or UUID among the accessory's writable ones.
    func resolve(_ action: PluginAutomationAction) throws -> WingmanAPI.Action {
        guard let id = Self.homeKitID(action.accessoryID), let device = devices[id] else {
            throw PluginAutomationError("\(action.accessoryID) is not an Apple Home accessory")
        }
        let match = device.writable.first { type, _ in
            HAPUUID(action.characteristic) == type || CharacteristicType.known(uuid: type)?.name == action.characteristic
        }
        guard let characteristic = match?.value else {
            throw PluginAutomationError("\(device.name) has no \(action.characteristic) to set")
        }
        return WingmanAPI.Action(accessory: id, characteristic: characteristic, value: action.value)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

extension WingmanAPI.Action {
    /// As sent back to Wingman: without the type, which Wingman knows.
    var sent: WingmanAPI.Action { WingmanAPI.Action(accessory: accessory, characteristic: characteristic, value: value) }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

// MARK: The hooks

extension WingmanPlugin {
    /// The links whose Wingman serves the structure, each with what it gave last, by Wingman id.
    private func structures() async -> [(link: Link, structure: Structure)] {
        var found: [(link: Link, structure: Structure)] = []
        for id in links.keys.sorted() {
            guard let link = links[id], let structure = await link.structure else { continue }
            found.append((link, structure))
        }
        return found
    }

    /// Whether the plugin mirrors this home's accessories: the homes `homes` names when it names some, else the Home (the
    /// bridge's), else every home while Apple Home has not added the bridge to one.
    nonisolated func includesHome(_ name: String) -> Bool {
        if let homes = configuration.homes, !homes.isEmpty { return homes.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        let bridgeHomes = bridgeHomes.withLockedValue { $0 }
        return bridgeHomes.isEmpty || bridgeHomes.contains(name)
    }

    /// Where a home is, for display: its name, and the Wingman's when several are paired.
    private func place(_ home: Structure.Home, link: Link) async -> String {
        links.count > 1 ? "\(home.name) (\(await link.name))" : home.name
    }

    /// The link that has `id` among what `has` finds, with what it gave.
    private func owner(_ has: (Structure) -> Bool) async -> (link: Link, structure: Structure)? {
        await structures().first { has($0.structure) }
    }

    // The Home Link

    /// The link that is the Home Link: of those whose Wingman serves it and sees the bridge's home, the first connected
    /// one by Wingman id, so another takes over when it goes down.
    private func homeLinkOwner() async -> (link: Link, structure: Structure, home: Structure.Home)? {
        for (link, structure) in await structures() where structure.servesHomeLink {
            guard await link.isConnected, let id = structure.bridgeHome, let home = structure.home(id) else { continue }
            return (link, structure, home)
        }
        return nil
    }

    public func homeLinkState() async -> HomeLinkState? {
        guard !links.isEmpty else { return .down("No Homeswift Wingman is paired: pair one on Add accessories") }
        guard let (_, structure, home) = await homeLinkOwner() else {
            let all = await structures()
            if all.isEmpty { return .down("Homeswift Wingman is not reachable") }
            if !all.contains(where: { $0.structure.servesHomeLink }) {
                return .down("Update Homeswift Wingman: this one cannot keep rooms in step with Apple Home")
            }
            return .down("Apple Home has not added this bridge to a home that Homeswift Wingman sees")
        }
        guard structure.allowed else { return .readOnly("turn on Let bridges edit rooms, scenes and automations in Homeswift Wingman's settings") }
        guard home.editable else { return .readOnly("the Mac running Homeswift Wingman is signed in to an account that does not administer \(home.name)") }
        return .up
    }

    public func homeSnapshot() async -> HomeSnapshot? {
        await homeLinkOwner()?.structure.homeSnapshot(in: context)
    }

    public func applyHomeChange(_ change: HomeChange) async throws -> String? {
        guard let (link, structure, home) = await homeLinkOwner() else { throw HomeChangeError(.unreachable, "Homeswift Wingman is not reachable") }
        func accessory(_ id: String) throws -> String {
            guard let found = structure.homeKitID(of: id, place: context.publishedPlace(ofAccessory: id)), structure.devices[found]?.home == home.id else {
                throw HomeChangeError(.notFound, "\(id) is not in \(home.name)")
            }
            return found
        }
        func services(_ ids: [String]) throws -> [JSONValue] {
            try ids.map { id in
                guard let service = structure.groupService(of: id, in: context) else { throw HomeChangeError(.notFound, "\(id) is not in \(home.name)") }
                return .string(service)
            }
        }
        let strings = { (ids: [String]) in JSONValue.array(ids.map(JSONValue.string)) }
        switch change {
        case .createRoom(let name):
            return try await link.homeEdit("rooms/create", ["name": .string(name), "home": .string(home.id)], created: "room")
        case .renameRoom(let id, let name):
            return try await link.homeEdit("rooms/rename", ["room": .string(id), "name": .string(name)])
        case .deleteRoom(let id):
            return try await link.homeEdit("rooms/delete", ["room": .string(id)])
        case .moveAccessory(let accessoryID, let roomID):
            let id = try accessory(accessoryID)
            return try await link.homeEdit("accessories/room", ["accessory": .string(id), "roomID": roomID.map(JSONValue.string) ?? .null], moved: (id, roomID))
        case .createZone(let name):
            return try await link.homeEdit("zones/create", ["name": .string(name), "home": .string(home.id)], created: "zone")
        case .renameZone(let id, let name):
            return try await link.homeEdit("zones/rename", ["zone": .string(id), "name": .string(name)])
        case .deleteZone(let id):
            return try await link.homeEdit("zones/delete", ["zone": .string(id)])
        case .setZoneRooms(let id, let add, let remove):
            return try await link.homeEdit("zones/rooms", ["zone": .string(id), "add": strings(add), "remove": strings(remove)])
        case .createGroup(let name, let members):
            return try await link.homeEdit("groups/create", ["name": .string(name), "services": .array(try services(members)), "home": .string(home.id)], created: "group")
        case .renameGroup(let id, let name):
            return try await link.homeEdit("groups/rename", ["group": .string(id), "name": .string(name)])
        case .deleteGroup(let id):
            return try await link.homeEdit("groups/delete", ["group": .string(id)])
        case .setGroupMembers(let id, let add, let remove):
            return try await link.homeEdit("groups/services", ["group": .string(id), "add": .array(try services(add)), "remove": .array(try services(remove))])
        }
    }

    // Scenes

    public func scenes() async -> [PluginScene] {
        var scenes: [PluginScene] = []
        var seen: Set<String> = []
        for (_, structure) in await structures() {
            for scene in structure.scenes where seen.insert(scene.id).inserted {
                guard let home = structure.home(scene.home), includesHome(home.name) else { continue }
                scenes.append(structure.pluginScene(scene))
            }
        }
        return scenes
    }

    private func scene(_ id: String) async throws -> (link: Link, structure: Structure, scene: WingmanAPI.Scene) {
        guard let (link, structure) = await owner({ $0.scenes.contains { $0.id == id } }),
              let scene = structure.scenes.first(where: { $0.id == id }) else {
            throw PluginSceneError("Apple Home has no scene \(id)")
        }
        return (link, structure, scene)
    }

    public func recallScene(id: String) async throws {
        try await scene(id).link.edit("scenes/run", ["scene": .string(id)])
    }

    public func updateScene(id: String, name: String?, lights: [PluginSceneLight]?) async throws {
        let (link, structure, scene) = try await scene(id)
        let capabilities = structure.pluginScene(scene).capabilities
        if let name, name != scene.name {
            guard capabilities.contains(.rename) else { throw PluginSceneError("\(scene.name) cannot be renamed from Homeswift") }
            try await link.edit("scenes/rename", ["scene": .string(id), "name": .string(name)], reload: .scenes)
        }
        if let lights {
            guard capabilities.contains(.update) else {
                throw PluginSceneError("\(scene.name) has actions Homeswift cannot show: change it in the Home app")
            }
            let actions = try structure.replacingLights(lights, in: scene)
            try await link.edit("scenes/actions", ["scene": .string(id), "actions": try JSONValue(encoding: actions)], reload: .scenes)
        }
    }

    public func deleteScene(id: String) async throws {
        let (link, structure, scene) = try await scene(id)
        guard structure.pluginScene(scene).capabilities.contains(.delete) else { throw PluginSceneError("\(scene.name) cannot be removed from Homeswift") }
        try await link.edit("scenes/delete", ["scene": .string(id)], reload: .scenes)
    }

    public func sceneTarget(accessoryIDs: [String]) async -> String? {
        guard let (_, structure) = await owner({ $0.home(of: accessoryIDs) != nil }),
              let home = structure.home(of: accessoryIDs), structure.editable(home: home.id), includesHome(home.name) else { return nil }
        return "\(home.name) in Apple Home"
    }

    public func createScene(name: String, lights: [PluginSceneLight]) async throws -> String {
        let ids = lights.map(\.accessoryID)
        guard let (link, structure) = await owner({ $0.home(of: ids) != nil }), let home = structure.home(of: ids) else {
            throw PluginSceneError("These lights are not all in one Apple Home home")
        }
        let actions = try structure.actions(for: lights)
        let answer = try await link.edit("scenes/create", ["home": .string(home.id), "name": .string(name), "actions": try JSONValue(encoding: actions)], reload: .scenes)
        guard let id = answer["id"]?.stringValue else { throw WingmanError.invalidResponse("no id for the new scene") }
        return id
    }

    // Automations

    public func automations() async -> [PluginAutomation] {
        var automations: [PluginAutomation] = []
        var seen: Set<String> = []
        for (link, structure) in await structures() {
            for automation in structure.automations where seen.insert(automation.id).inserted {
                guard let home = structure.home(automation.home), includesHome(home.name) else { continue }
                automations.append(structure.pluginAutomation(automation, place: await place(home, link: link)))
            }
        }
        return automations
    }

    private func automation(_ id: String) async throws -> (link: Link, structure: Structure, automation: PluginAutomation) {
        guard let (link, structure) = await owner({ $0.automations.contains { $0.id == id } }),
              let automation = structure.automations.first(where: { $0.id == id }) else {
            throw PluginAutomationError("Apple Home has no automation \(id)")
        }
        return (link, structure, structure.pluginAutomation(automation, place: nil))
    }

    /// Each part of the change through its own endpoint, in turn; the first refusal stops the rest.
    public func updateAutomation(id: String, change: PluginAutomationChange) async throws {
        let (link, structure, automation) = try await automation(id)
        func require(_ capability: PluginAutomation.Capability, _ what: String) throws {
            guard automation.capabilities.contains(capability) else {
                throw PluginAutomationError("\(automation.name): \(what) cannot be changed from Homeswift")
            }
        }
        let target: JSONValue = .string(id)
        if let enabled = change.enabled, enabled != automation.enabled {
            try require(.enable, "whether it is on")
            try await link.edit("automations/enable", ["automation": target, "enabled": .bool(enabled)], reload: .automations)
        }
        if let name = change.name, name != automation.name {
            try require(.rename, "its name")
            try await link.edit("automations/rename", ["automation": target, "name": .string(name)], reload: .automations)
        }
        if let time = change.time {
            try require(.time, "its time")
            try await link.edit("automations/time", ["automation": target, "time": try JSONValue(encoding: Structure.time(time))], reload: .automations)
        }
        if let sceneIDs = change.sceneIDs {
            try require(.scenes, "what it runs")
            let known = Set(structure.scenes.map(\.id))
            if let unknown = sceneIDs.first(where: { !known.contains($0) }) { throw PluginAutomationError("Apple Home has no scene \(unknown)") }
            try await link.edit("automations/scenes", ["automation": target, "scenes": .array(sceneIDs.map(JSONValue.string))], reload: .automations)
        }
        if let actions = change.actions {
            try require(.actions, "its actions")
            let resolved = try actions.map(structure.resolve)
            try await link.edit("automations/actions", ["automation": target, "actions": try JSONValue(encoding: resolved)], reload: .automations)
        }
    }

    public func deleteAutomation(id: String) async throws {
        let (link, _, automation) = try await automation(id)
        guard automation.capabilities.contains(.delete) else { throw PluginAutomationError("\(automation.name) cannot be removed from Homeswift") }
        try await link.edit("automations/delete", ["automation": .string(id)], reload: .automations)
    }
}
