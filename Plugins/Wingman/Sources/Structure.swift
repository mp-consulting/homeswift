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
    }

    /// An accessory of the homes, mirrored or not: what an action names it by.
    struct Device: Sendable {
        var name: String
        var room: String?
        var home: String
        /// Its writable characteristics' HomeKit ids, by type.
        var writable: [HAPUUID: String]
    }

    /// Whether Wingman's owner lets bridges edit now.
    var allowed: Bool
    var homes: [Home]
    var devices: [String: Device]
    /// The accessories Homeswift mirrors, by HomeKit id.
    var mirrored: Set<String>
    var scenes: [WingmanAPI.Scene] = []
    var automations: [WingmanAPI.Automation] = []

    init(allowed: Bool, homes: [WingmanAPI.Home], mirrored: Set<String>) {
        self.allowed = allowed
        self.mirrored = mirrored
        self.homes = homes.compactMap { home in
            home.id.map { Home(id: $0, name: home.name, editable: home.editable == true, rooms: home.rooms ?? []) }
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
                devices[accessory.id] = Device(name: accessory.name, room: accessory.room, home: homeID, writable: writable)
            }
        }
        self.devices = devices
    }

    func home(_ id: String) -> Home? { homes.first { $0.id == id } }

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

    private nonisolated func includesHome(_ name: String) -> Bool {
        guard let homes = configuration.homes, !homes.isEmpty else { return true }
        return homes.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Where a home is, for display: its name, and the Wingman's when several are paired.
    private func place(_ home: Structure.Home, link: Link) async -> String {
        links.count > 1 ? "\(home.name) (\(await link.name))" : home.name
    }

    /// The link that has `id` among what `has` finds, with what it gave.
    private func owner(_ has: (Structure) -> Bool) async -> (link: Link, structure: Structure)? {
        await structures().first { has($0.structure) }
    }

    // Rooms

    public func rooms() async -> [PluginRoom] {
        var rooms: [PluginRoom] = []
        var seen: Set<String> = []
        for (link, structure) in await structures() {
            for home in structure.homes where includesHome(home.name) {
                let place = await place(home, link: link)
                for room in home.rooms where seen.insert(room.id).inserted {
                    rooms.append(PluginRoom(id: room.id, name: room.name, place: place))
                }
            }
        }
        return rooms
    }

    public func renameRoom(id: String, name: String) async throws {
        guard let (link, _) = await owner({ $0.homes.contains { $0.rooms.contains { $0.id == id } } }) else {
            throw PluginRoomError("Apple Home has no room \(id)")
        }
        try await link.edit("rooms/rename", ["room": .string(id), "name": .string(name)])
        await link.renamedRoom(id, to: name)
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
