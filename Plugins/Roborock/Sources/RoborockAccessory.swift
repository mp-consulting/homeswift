import Foundation
import Homeswift
import HomeswiftPlugin

/// What a robot's services do when HomeKit writes them; the plugin answers.
struct VacuumActions: Sendable {
    var setActive: @Sendable (_ duid: String, _ active: Bool) async -> Void
    var setDockWash: @Sendable (_ duid: String, _ on: Bool) async throws -> Void
    var runScene: @Sendable (_ sceneID: Int) async -> Void
    /// `set_custom_mode` with a suction code (RoborockModes.md section 1.3).
    var setSuction: @Sendable (_ duid: String, _ code: Int) async throws -> Void = { _, _ in }
    /// `set_water_box_custom_mode` with a water code (section 2.3).
    var setWater: @Sendable (_ duid: String, _ code: Int) async throws -> Void = { _, _ in }
    /// `find_me` (section 5).
    var findMe: @Sendable (_ duid: String) async throws -> Void = { _ in }
}

/// One robot in HomeKit (section 6): a Fan v2 that cleans, its battery, the dock's mop wash, its scenes and its brushes
/// and filter. It keeps the live status the robot reported (section 5.6) and sets only what changed. The plugin actor
/// owns it.
final class VacuumAccessory {
    let duid: String
    let accessoryID: String
    private(set) var device: RoborockHome.Device
    private(set) var model: String?
    private(set) var accessory: Accessory
    private(set) var fan: Service
    private(set) var battery: Service
    private(set) var dockWash: Service?
    private(set) var mop: Service?
    /// The suction levels the Fan's speed runs through, fixed when the accessory is built.
    private(set) var suctionLevels: [RoborockMode] = []
    private(set) var sceneSwitches: [Int: Service] = [:]
    private(set) var consumables: [String: Service] = [:]
    /// The scenes of the device, by id, and their names.
    private(set) var scenes: [Int: String] = [:]
    private var live: [String: (value: Double, at: ContinuousClock.Instant)] = [:]
    var connectedLocally = false
    var language: String
    let liveAge: Duration
    let switchReset: Duration
    let actions: VacuumActions

    init(device: RoborockHome.Device, model: String?, language: String, timings: RoborockTimings, actions: VacuumActions, accessoryID: String) {
        duid = device.duid
        self.device = device
        self.model = model
        self.language = language
        liveAge = timings.liveStatusAge
        switchReset = timings.sceneSwitchReset
        self.actions = actions
        self.accessoryID = accessoryID
        battery = Service(.battery)
        fan = Service(.fanv2)
        accessory = Accessory(id: accessoryID, name: device.name, services: [])
    }

    static let defaultName = "Roborock Vacuum"

    var name: String { device.name.isEmpty ? Self.defaultName : device.name }

    var features: RoborockFeatures { RoborockFeatures(featureSet: device.isShared ? nil : device.featureSet) }

    /// The suction, water and routes the robot offers.
    var cleanModes: RoborockCleanModes {
        RoborockCleanModes(model: model, featureSet: device.isShared ? nil : device.featureSet, newFeatureSet: device.newFeatureSet)
    }

    /// The Fan's Rotation Speed for a suction code: level n of N is n/N of 100 (nil for a mode that is no level).
    static func speed(fanPower: Int, levels: [RoborockMode]) -> Double? {
        guard let index = levels.firstIndex(where: { $0.code == fanPower }) else { return nil }
        // On the minStep grid (100 / N), unrounded: six levels are 16.67 % apart.
        return Double(index + 1) * 100 / Double(levels.count)
    }

    /// The suction level nearest a Rotation Speed (nil at 0, which turns the fan off instead).
    static func fanPower(speed: Double, levels: [RoborockMode]) -> Int? {
        guard speed > 0, !levels.isEmpty else { return nil }
        // A value between two levels takes the higher one; one a hair above a level (16.6667 for 16.666…) is that level.
        let position = speed * Double(levels.count) / 100
        let index = min(levels.count - 1, max(0, Int((position - 1e-3).rounded(.up)) - 1))
        return levels[index].code
    }

    /// The dock washes the mop: its featureSet bit, or a live `dock_type` that washes.
    var hasDockWash: Bool { features.dockWashesMop || (!device.isShared && RoborockFeatures.dockWashes(dockType: liveValue("dock_type"))) }

    // MARK: Status

    /// A field's value: the live one while fresh, else the home data's.
    func value(_ field: String, home: RoborockHome?) -> Double? {
        if let live = liveValue(field) { return live }
        return home?.snapshot(field, of: device)
    }

    private func liveValue(_ field: String) -> Double? {
        guard let entry = live[field], ContinuousClock.now - entry.at < liveAge else { return nil }
        return entry.value
    }

    /// Records a status: every number in it, schema ids translated.
    func record(_ fields: [String: JSONValue]) {
        let now = ContinuousClock.now
        for (key, value) in fields {
            guard let number = value.doubleValue ?? value.boolValue.map({ $0 ? 1 : 0 }), number.isFinite else { continue }
            live[RoborockMessages.schemaFields[key] ?? key] = (number, now)
        }
    }

    func updateDevice(_ device: RoborockHome.Device, model: String?) {
        self.device = device
        self.model = model
    }

    // MARK: Shape

    /// The services this robot should have now: dock wash, scenes, consumables.
    struct Shape: Equatable {
        var dockWash: Bool
        var mop: Bool = false
        var scenes: [Int: String]
        var consumables: Set<String>
    }

    var shape: Shape { Shape(dockWash: dockWash != nil, mop: mop != nil, scenes: scenes, consumables: Set(consumables.keys)) }

    func desiredShape(home: RoborockHome?, sceneList: [RoborockScene]) -> Shape {
        var sceneNames = scenes
        let listed = sceneList.filter { $0.belongs(to: duid) }
        let listedIDs = Set(listed.map(\.id))
        // A scene no longer listed goes; one disabled but still listed keeps its switch, as the Homebridge plugin does.
        sceneNames = sceneNames.filter { listedIDs.contains($0.key) }
        for scene in listed where scene.enabled || sceneNames[scene.id] != nil { sceneNames[scene.id] = scene.name }
        var fields = Set(consumables.keys)
        for kind in RoborockConsumables.all where value(kind.field, home: home) != nil { fields.insert(kind.field) }
        return Shape(dockWash: hasDockWash, mop: cleanModes.hasWaterBox, scenes: sceneNames, consumables: fields)
    }

    /// Builds the accessory for a shape, keeping the values (and the names a person gave the switches) of the one
    /// before. Answers the new accessory, to add.
    func build(_ shape: Shape) -> Accessory {
        let old = accessory
        let battery = Service(.battery, optional: [.batteryLevel, .chargingState])
        var linked = [battery]
        var dockWash: Service?
        if shape.dockWash {
            let service = Self.switchService(subtype: "dock-wash", name: RoborockStrings.dockWashName(language), old: old)
            let duid = duid, actions = actions
            service.characteristic(.on).onWrite { value in try await actions.setDockWash(duid, value.boolValue ?? false) }
            dockWash = service
            linked.append(service)
        }
        var mop: Service?
        if shape.mop {
            // On mops with the robot's default water; off vacuums only (RoborockModes.md section 2.3).
            let service = Self.switchService(subtype: "mop", name: RoborockStrings.mopName(language), old: old)
            let duid = duid, actions = actions, water = cleanModes.defaultWater
            service.characteristic(.on).onWrite { value in try await actions.setWater(duid, value.boolValue == true ? water : 200) }
            mop = service
            linked.append(service)
        }
        var sceneSwitches: [Int: Service] = [:]
        for (id, name) in shape.scenes.sorted(by: { $0.key < $1.key }) {
            let service = Self.switchService(subtype: "scene-\(id)", name: name, old: old)
            let on = service.characteristic(.on)
            on.value = false
            let actions = actions, reset = switchReset
            _ = on.onRead { .bool(false) }
            on.onWrite { [weak on] value in
                guard value.boolValue == true else { return }
                Task { await actions.runScene(id) }
                Task {
                    try? await Task.sleep(for: reset)
                    on?.value = false
                }
            }
            sceneSwitches[id] = service
            linked.append(service)
        }
        var consumables: [String: Service] = [:]
        for kind in RoborockConsumables.all where shape.consumables.contains(kind.field) {
            let label = RoborockStrings.consumableName(kind.field, language)
            let service = Service(.filterMaintenance, name: label, subtype: kind.subtype, optional: [.filterLifeLevel, .configuredName])
            if let previous = old.service(.filterMaintenance, subtype: kind.subtype) { service.takeValues(from: previous) }
            Self.rename(service, to: label, previous: old.service(.filterMaintenance, subtype: kind.subtype))
            consumables[kind.field] = service
            linked.append(service)
        }
        let levels = cleanModes.suctionLevels
        suctionLevels = levels
        var extra = [Characteristic(.statusFault), Characteristic(.statusActive)]
        if !levels.isEmpty {
            extra.append(Characteristic(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 100 / Double(levels.count))))
        }
        let fan = Service(.fanv2, name: name, extra: extra, linked: linked, isPrimary: true)
        // A Robotic Vacuum Cleaner over Matter, its battery the Battery beside it.
        fan.standsFor = .cleaningRobot
        let duid = duid, actions = actions
        fan.characteristic(.active).onWrite { value in await actions.setActive(duid, value.intValue == 1) }
        if !levels.isEmpty {
            fan.characteristic(.rotationSpeed).onWrite { value in
                guard let code = Self.fanPower(speed: value.doubleValue ?? 0, levels: levels) else { return }
                try await actions.setSuction(duid, code)
            }
        }
        if let previous = old.service(.fanv2) { fan.takeValues(from: previous) }
        if let previous = old.service(.battery) { battery.takeValues(from: previous) }
        let accessory = Accessory(
            id: accessoryID, name: name, manufacturer: "Roborock", model: model ?? "Unknown", serialNumber: device.serialNumber?.nonEmptyValue ?? "Unknown",
            firmwareRevision: device.firmware?.nonEmptyValue ?? "Unknown", category: .other,
            services: [fan, battery] + linked.dropFirst(), onIdentify: { try await actions.findMe(duid) })
        self.accessory = accessory
        self.fan = fan
        self.battery = battery
        self.dockWash = dockWash
        self.mop = mop
        self.sceneSwitches = sceneSwitches
        self.consumables = consumables
        self.scenes = shape.scenes
        return accessory
    }

    /// A switch with its default name, renamed by the naming rule (section 6.6).
    private static func switchService(subtype: String, name: String, old: Accessory) -> Service {
        let service = Service(.switch, name: name, subtype: subtype, optional: [.configuredName])
        let previous = old.service(.switch, subtype: subtype)
        if let previous { service.takeValues(from: previous) }
        rename(service, to: name, previous: previous)
        return service
    }

    /// Name is always the default; Configured Name follows it unless a person renamed the service (it differs from the
    /// Name it had).
    private static func rename(_ service: Service, to name: String, previous: Service?) {
        service.characteristic(.name).value = .string(name)
        let configured = previous?[.configuredName]?.value.stringValue ?? ""
        let previousName = previous?[.name]?.value.stringValue ?? ""
        if configured.isEmpty || configured == previousName { service.characteristic(.configuredName).value = .string(name) }
    }

    // MARK: Showing the state

    /// Shows every field it knows (a home-data refresh, section 6.7).
    func showAll(home: RoborockHome?, online: Bool?) {
        show(fields: nil, home: home)
        fan.characteristic(.statusActive).value = .bool(connectedLocally || online != false)
        accessory.information.characteristic(.firmwareRevision).value = .string(device.firmware?.nonEmptyValue ?? "Unknown")
    }

    /// Shows what a device update carries (`fields`, the keys it has), or everything known (nil).
    func show(fields: Set<String>?, home: RoborockHome?) {
        func has(_ field: String) -> Bool { fields?.contains(field) ?? true }
        let state = value("state", home: home).map { Int($0) }
        if has("state"), let state {
            set(fan, .active, .int(RoborockStates.isCleaning(state) ? 1 : 0))
            if let dockWash { set(dockWash, .on, .bool(RoborockStates.mopWashing.contains(state))) }
        }
        if has("in_cleaning"), let inCleaning = value("in_cleaning", home: home) { set(fan, .active, .int(inCleaning != 0 ? 1 : 0)) }
        if has("fan_power"), let power = value("fan_power", home: home),
           let speed = Self.speed(fanPower: Int(power), levels: suctionLevels) {
            set(fan, .rotationSpeed, .double(speed))
        }
        if has("water_box_mode"), let mop, let water = value("water_box_mode", home: home) { set(mop, .on, .bool(water != 200)) }
        if has("error_code") || fields == nil, let error = value("error_code", home: home) { set(fan, .statusFault, .int(error != 0 ? 1 : 0)) }
        if has("battery"), let level = value("battery", home: home) {
            let clamped = Int(saturating: level, in: 0...100) ?? 0
            set(battery, .batteryLevel, .int(clamped))
            set(battery, .statusLowBattery, .int(clamped < 20 ? 1 : 0))
        }
        if has("charge_status") || (fields?.contains("state") ?? false), let charge = value("charge_status", home: home) {
            let charging = charge != 0 || (state == RoborockStates.charging && !features.offPeakCharging)
            set(battery, .chargingState, .int(charging ? 1 : 0))
        }
        for kind in RoborockConsumables.all where has(kind.field) {
            guard let service = consumables[kind.field], let life = value(kind.field, home: home) else { continue }
            let level = min(100, max(0, life))
            set(service, .filterLifeLevel, .double(level))
            set(service, .filterChangeIndication, .int(level <= 5 ? 1 : 0))
        }
    }

    private func set(_ service: Service, _ type: CharacteristicType, _ value: HAPValue) {
        guard let characteristic = service[type], characteristic.value != value else { return }
        characteristic.value = value
    }
}
