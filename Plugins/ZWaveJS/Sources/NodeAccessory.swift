import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// Writes one value of the node (`node.set_value`) through the server's connection of the moment.
typealias ValueWriter = @Sendable (ValueID, JSONValue) async throws -> Void

/// What a node's accessory is built from: rebuilt only when it changes.
struct NodeShape: Equatable, Sendable {
    var name: String
    var showAs: SwitchShape?
    var values: Set<ValueID>
}

/// How a Binary Switch shows in HomeKit (the `showAs` Accessory Setting).
enum SwitchShape: String, Sendable {
    case `switch`, outlet, lightbulb
}

/// The accessory of one node: its services, built from the command classes it has, and what each value it reads
/// changes on them.
final class NodeAccessory: Sendable {
    typealias Updater = @Sendable (JSONValue) -> Void

    let accessory: Accessory
    let shape: NodeShape
    /// Its Device Kind: `light`, `cover`, `switch`, `lock`, `thermostat`, `sensor` or `button`.
    let kind: String
    /// What a value's update changes, by value id.
    private let updaters: [ValueID: [Updater]]
    /// What a value notification (Central Scene's key presses) sends, by value id.
    private let notifiers: [ValueID: Updater]
    fileprivate init(accessory: Accessory, shape: NodeShape, kind: String, updaters: [ValueID: [Updater]], notifiers: [ValueID: Updater]) {
        self.accessory = accessory
        self.shape = shape
        self.kind = kind
        self.updaters = updaters
        self.notifiers = notifiers
    }

    /// A value changed on the node (the state dump's values and `value updated`).
    func update(_ id: ValueID, _ value: JSONValue) {
        for updater in updaters[id] ?? [] { updater(value) }
    }

    /// A stateless value came (`value notification`): a key pressed.
    func notify(_ id: ValueID, _ value: JSONValue) {
        if let notifier = notifiers[id] { notifier(value) } else { update(id, value) }
    }

    /// Dead nodes, and every node while the server is away, answer No Response.
    func setUnavailable(_ unavailable: Bool) {
        if accessory.isUnavailable != unavailable { accessory.isUnavailable = unavailable }
    }
}

// MARK: Building

/// What one accessory is made of while it is built.
struct NodeBuilder {
    let node: ZNode
    let deviceID: String
    let name: String
    let shape: NodeShape
    var showAs: SwitchShape? { shape.showAs }
    let write: ValueWriter
    /// Declares the Meter of a service before the accessory is added (`PluginContext.meter(of:)`).
    let meter: (Service) -> PluginMeter
    /// Delays a slider's or a colour's writes so only the last of a drag goes out.
    let coalesce: LatestCallGuard

    private var services: [Service] = []
    private var updaters: [ValueID: [NodeAccessory.Updater]] = [:]
    private var notifiers: [ValueID: NodeAccessory.Updater] = [:]
    /// The value ids a function took, so another does not show them twice.
    private var claimed: Set<ValueID> = []

    init(node: ZNode, deviceID: String, name: String, shape: NodeShape, write: @escaping ValueWriter,
         meter: @escaping (Service) -> PluginMeter, coalesce: LatestCallGuard) {
        self.node = node
        self.deviceID = deviceID
        self.name = name
        self.shape = shape
        self.write = write
        self.meter = meter
        self.coalesce = coalesce
        primaryTypes = Self.primaryTypes(of: node)
    }

    /// The services that may be the primary one: the node's actuators when it has some, else its sensors and buttons.
    private let primaryTypes: Set<HAPUUID>

    static func primaryTypes(of node: ZNode) -> Set<HAPUUID> {
        let actuators: [ServiceType] = [.lightbulb, .windowCovering, .outlet, .switch, .lockMechanism, .thermostat]
        let hasActuator = node.values.keys.contains {
            [CommandClass.binarySwitch, CommandClass.multilevelSwitch, CommandClass.doorLock, CommandClass.thermostatMode, CommandClass.thermostatSetpoint]
                .contains($0.commandClass)
        }
        if hasActuator { return Set(actuators.map(\.uuid)) }
        return Set(SensorKind.allCases.map(\.type.uuid) + [ServiceType.temperatureSensor, .humiditySensor, .lightSensor, .statelessProgrammableSwitch].map(\.uuid))
    }

    /// The node's accessory, or nil when none of its values maps to a service.
    mutating func build() -> NodeAccessory? {
        let endpoints = node.endpoints
        let multiChannel = endpoints.filter { $0 > 0 }.count > 1
        func label(_ endpoint: Int) -> String { multiChannel && endpoint > 0 ? "\(name) \(endpoint)" : name }
        // Actuators first, so a thermostat takes its air temperature (perhaps the root endpoint's) before the sensors.
        for endpoint in endpoints {
            let main = buildActuator(endpoint: endpoint, label: label(endpoint))
            buildThermostat(endpoint: endpoint, label: label(endpoint))
            buildMeters(endpoint: endpoint, on: main, label: label(endpoint))
        }
        for endpoint in endpoints {
            let label = label(endpoint)
            buildNotificationSensors(endpoint: endpoint, label: label)
            buildBinarySensors(endpoint: endpoint, label: label)
            buildMultilevelSensors(endpoint: endpoint, label: label)
        }
        buildCentralScene()
        guard !services.isEmpty else { return nil }
        buildBattery()

        let primary = services.first(where: \.isPrimary)
        let ordered = primary.map { primary in [primary] + services.filter { $0 !== primary } } ?? services
        let (kind, category) = node.isEntryControl ? ("lock", .doorLock) : Self.kind(of: primary?.type)
        let accessory = Accessory(
            id: ZWaveJSPlugin.accessoryID(deviceID: deviceID), name: name, manufacturer: node.manufacturer ?? "Z-Wave",
            model: node.label ?? node.productDescription ?? "Z-Wave device", serialNumber: node.serialNumber ?? deviceID,
            firmwareRevision: node.firmwareVersion ?? "1.0.0", category: category, services: ordered)
        let built = NodeAccessory(accessory: accessory, shape: shape, kind: kind, updaters: updaters, notifiers: notifiers)
        for value in node.values.values {
            if let current = value.value { built.update(value.id, current) }
        }
        built.setUnavailable(node.isDead)
        return built
    }

    static func kind(of type: ServiceType?) -> (String, AccessoryCategory) {
        switch type?.uuid {
        case ServiceType.lightbulb.uuid: ("light", .lightbulb)
        case ServiceType.windowCovering.uuid: ("cover", .windowCovering)
        case ServiceType.outlet.uuid: ("switch", .outlet)
        case ServiceType.switch.uuid: ("switch", .switch)
        case ServiceType.lockMechanism.uuid: ("lock", .doorLock)
        case ServiceType.thermostat.uuid: ("thermostat", .thermostat)
        case ServiceType.statelessProgrammableSwitch.uuid: ("button", .programmableSwitch)
        default: ("sensor", .sensor)
        }
    }

    // MARK: Helpers

    private mutating func on(_ id: ValueID, _ updater: @escaping NodeAccessory.Updater) {
        updaters[id, default: []].append(updater)
        claimed.insert(id)
    }

    private mutating func add(_ service: Service) {
        services.append(service)
    }

    /// A service, primary when it is the first that may be.
    private mutating func make(_ type: ServiceType, name: String? = nil, subtype: String, optional: [CharacteristicType] = [], extra: [Characteristic] = []) -> Service {
        let primary = !services.contains(where: \.isPrimary) && primaryTypes.contains(type.uuid)
        return Service(type, name: name, subtype: subtype, optional: optional, extra: extra, isPrimary: primary)
    }

    /// A write that throws HomeKit's communication failure when the server refuses it or is away.
    private func writer(_ id: ValueID) -> @Sendable (JSONValue) async throws -> Void {
        let write = self.write
        return { value in
            do {
                try await write(id, value)
            } catch {
                throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
            }
        }
    }

    // MARK: Switches, lights, covers, locks

    /// The endpoint's actuator, the service its Meter goes on when it has one.
    private mutating func buildActuator(endpoint: Int, label: String) -> Service? {
        let subtype = String(endpoint)
        // A lock first: an endpoint that also has a switch is still its lock, written only through Lock Target State.
        if let mode = node.value(CommandClass.doorLock, endpoint: endpoint, property: "currentMode") {
            return buildLock(mode, subtype: subtype, label: label)
        }
        if let level = node.value(CommandClass.multilevelSwitch, endpoint: endpoint, property: "currentValue") {
            return node.isCover ? buildCover(level, subtype: subtype, label: label) : buildDimmer(level, endpoint: endpoint, subtype: subtype, label: label)
        }
        if let state = node.value(CommandClass.binarySwitch, endpoint: endpoint, property: "currentValue") {
            return buildBinarySwitch(state, endpoint: endpoint, subtype: subtype, label: label)
        }
        return nil
    }

    /// Multilevel Switch levels are 0 to 99 (99 is full), 255 turns on at the last level.
    static func percent(level: Double) -> Int { level >= 99 ? 100 : Int(saturating: (level * 100 / 99).rounded(), in: 0...100) ?? 0 }
    static func level(percent: Int) -> Int { min(99, max(0, Int((Double(percent) * 99 / 100).rounded()))) }

    private mutating func buildDimmer(_ level: ZValue, endpoint: Int, subtype: String, label: String) -> Service {
        let colors = colorComponents(endpoint: endpoint)
        let hasColor = colors.contains { [2, 3, 4].contains($0.key) }
        let service = make(.lightbulb, name: label, subtype: subtype, optional: [.brightness] + (hasColor ? [.hue, .saturation] : []))
        let target = writer(level.id.with(property: "targetValue"))
        let power = service.characteristic(.on), brightness = service.characteristic(.brightness)
        power.onWrite(changesOnly: true) { value in
            // On restores the last level; Off is 0.
            try await target(.number(value.boolValue == true ? 255 : 0))
        }
        let guardian = coalesce, key = "\(deviceID):\(endpoint):level"
        brightness.onWrite { value in
            guard let percent = value.intValue, await guardian(key) else { return }
            try await target(.number(Double(Self.level(percent: percent))))
        }
        on(level.id) { value in
            guard let level = value.numberValue else { return }
            power.value = .bool(level > 0)
            if level > 0 { brightness.value = .int(Self.percent(level: level)) }
        }
        if hasColor { buildColor(service, colors: colors, endpoint: endpoint) }
        add(service)
        return service
    }

    /// Color Switch's current components by their ids (0 warm white, 1 cold white, 2 red, 3 green, 4 blue).
    private func colorComponents(endpoint: Int) -> [Int: ZValue] {
        var components: [Int: ZValue] = [:]
        for value in node.values(CommandClass.colorSwitch, endpoint: endpoint) where value.id.propertyText == "currentColor" {
            if let key = value.id.propertyKey?.intValue { components[key] = value }
        }
        return components
    }

    private mutating func buildColor(_ service: Service, colors: [Int: ZValue], endpoint: Int) {
        let hue = service.characteristic(.hue), saturation = service.characteristic(.saturation)
        let rgb = NIOLockedValueBox<[Int: Double]>([2: 255, 3: 255, 4: 255])
        let show: @Sendable () -> Void = {
            let (h, s) = ColorMath.hueSaturation(red: rgb.withLockedValue { $0[2] ?? 0 }, green: rgb.withLockedValue { $0[3] ?? 0 }, blue: rgb.withLockedValue { $0[4] ?? 0 })
            if let h { hue.value = .double(h) }
            saturation.value = .double(s)
        }
        for (key, value) in colors where [2, 3, 4].contains(key) {
            on(value.id) { json in
                guard let component = json.numberValue else { return }
                rgb.withLockedValue { $0[key] = component }
                show()
            }
        }
        // The whole colour as one object, which zwave-js reports beside the components.
        if let whole = node.value(CommandClass.colorSwitch, endpoint: endpoint, property: "currentColor") {
            on(whole.id) { json in
                let names = [2: "red", 3: "green", 4: "blue"]
                rgb.withLockedValue { rgb in
                    for (key, name) in names { if let component = json[name]?.numberValue { rgb[key] = component } }
                }
                show()
            }
        }
        let whites = colors.keys.filter { $0 == 0 || $0 == 1 }
        let target = writer(ValueID(commandClass: CommandClass.colorSwitch, endpoint: endpoint, property: "targetColor"))
        let guardian = coalesce, key = "\(deviceID):\(endpoint):color"
        let send: @Sendable () async throws -> Void = {
            guard await guardian(key) else { return }
            let (red, green, blue) = ColorMath.rgb(hue: hue.value.doubleValue ?? 0, saturation: saturation.value.doubleValue ?? 0)
            var color: [String: JSONValue] = ["red": .number(Double(red)), "green": .number(Double(green)), "blue": .number(Double(blue))]
            if whites.contains(0) { color["warmWhite"] = .number(0) }
            if whites.contains(1) { color["coldWhite"] = .number(0) }
            try await target(.object(color))
        }
        // A write's handler runs before the characteristic keeps the value: each keeps it first, so the colour sent
        // has both halves of a write that sets the two.
        hue.onWrite { value in
            hue.value = value
            try await send()
        }
        saturation.onWrite { value in
            saturation.value = value
            try await send()
        }
    }

    private mutating func buildCover(_ level: ZValue, subtype: String, label: String) -> Service {
        let service = make(.windowCovering, name: label, subtype: subtype)
        let current = service.characteristic(.currentPosition), targetPosition = service.characteristic(.targetPosition)
        service.characteristic(.positionState).value = .int(2)
        let target = writer(level.id.with(property: "targetValue"))
        let guardian = coalesce, key = "\(deviceID):\(subtype):cover"
        targetPosition.onWrite { value in
            guard let percent = value.intValue, await guardian(key) else { return }
            try await target(.number(Double(Self.level(percent: percent))))
        }
        on(level.id) { value in
            guard let level = value.numberValue, (0...99).contains(level) else { return }
            current.value = .int(Self.percent(level: level))
        }
        if let targetValue = node.value(CommandClass.multilevelSwitch, endpoint: level.id.endpoint, property: "targetValue") {
            on(targetValue.id) { value in
                guard let level = value.numberValue, (0...99).contains(level) else { return }
                targetPosition.value = .int(Self.percent(level: level))
            }
        }
        add(service)
        return service
    }

    private mutating func buildBinarySwitch(_ state: ZValue, endpoint: Int, subtype: String, label: String) -> Service {
        let metered = !node.values(CommandClass.meter, endpoint: endpoint).isEmpty || !node.values(CommandClass.meter, endpoint: 0).isEmpty
        // An Entry Control node's switch (a door strike, a gate) opens a door: a switch whatever `showAs` says, guarded
        // by the bridge's security rules as a lock is.
        let switchShape: SwitchShape = node.isEntryControl ? .switch : showAs ?? (metered ? .outlet : .switch)
        let type: ServiceType = switch switchShape {
        case .switch: .switch
        case .outlet: .outlet
        case .lightbulb: .lightbulb
        }
        let service = make(type, name: label, subtype: subtype, optional: switchShape == .outlet ? [.outletInUse] : [])
        let power = service.characteristic(.on)
        if switchShape == .outlet { service.characteristic(.outletInUse).value = .bool(true) }
        let target = writer(state.id.with(property: "targetValue"))
        power.onWrite(changesOnly: true) { value in try await target(.bool(value.boolValue == true)) }
        if node.isEntryControl { power.securityControl() }
        on(state.id) { value in
            if let state = value.boolValue { power.value = .bool(state) }
        }
        add(service)
        return service
    }

    /// Door Lock modes: 255 secured, 254 unknown, the others unsecured (with or without a timeout, inside or outside).
    static func lockState(mode: Int) -> Int { mode == 255 ? 1 : mode == 254 ? 3 : 0 }

    private mutating func buildLock(_ mode: ZValue, subtype: String, label: String) -> Service {
        let service = make(.lockMechanism, name: label, subtype: subtype)
        let current = service.characteristic(.lockCurrentState), targetState = service.characteristic(.lockTargetState)
        // Lock Target State is a security control: the bridge's own surfaces ask before they write it.
        let target = writer(mode.id.with(property: "targetMode"))
        targetState.onWrite { value in try await target(.number(value.intValue == 1 ? 255 : 0)) }
        on(mode.id) { value in
            guard let mode = value.intValue else { return }
            let state = Self.lockState(mode: mode)
            current.value = .int(state)
            if state != 3 { targetState.value = .int(state) }
        }
        add(service)
        return service
    }

    // MARK: Thermostat

    /// Thermostat Mode's modes HomeKit has: Off, Heat, Cool and Auto keep their numbers.
    static let homeKitModes: Set<Int> = [0, 1, 2, 3]

    private mutating func buildThermostat(endpoint: Int, label: String) {
        let mode = node.value(CommandClass.thermostatMode, endpoint: endpoint, property: "mode")
        let setpoints = node.values(CommandClass.thermostatSetpoint, endpoint: endpoint).filter { $0.id.propertyText == "setpoint" }
        let heating = setpoints.first { $0.id.propertyKey?.intValue == 1 }, cooling = setpoints.first { $0.id.propertyKey?.intValue == 2 }
        guard mode != nil || heating != nil || cooling != nil else { return }
        let supported = mode.map { Self.homeKitModes.intersection($0.states.keys).sorted() } ?? []
        let modes = supported.isEmpty ? (cooling != nil && heating == nil ? [0, 2] : [0, 1]) : supported
        let fahrenheit = (heating ?? cooling)?.unit == "°F"
        let service = make(.thermostat, name: label, subtype: "\(endpoint):thermostat", optional: [
            .targetHeatingCoolingState.with(minValue: Double(modes.min() ?? 0), maxValue: Double(modes.max() ?? 3), validValues: modes),
            .targetTemperature.with(minValue: 5, maxValue: 35, minStep: 0.5),
            .currentTemperature.with(minValue: -50, maxValue: 100),
        ])
        let targetMode = service.characteristic(.targetHeatingCoolingState), currentMode = service.characteristic(.currentHeatingCoolingState)
        let targetTemperature = service.characteristic(.targetTemperature), currentTemperature = service.characteristic(.currentTemperature)
        service.characteristic(.temperatureDisplayUnits).value = .int(fahrenheit ? 1 : 0)
        targetMode.value = .int(modes.first ?? 0)
        let hasOperatingState = node.value(CommandClass.thermostatOperatingState, endpoint: endpoint, property: "state") != nil
        // The setpoint shown and written: cooling's in Cool, heating's otherwise (cooling's when there is no heating).
        let celsiusSetpoints = NIOLockedValueBox<[Int: Double]>([:])
        let shownKey: @Sendable () -> Int = {
            let mode = targetMode.value.intValue ?? 1
            if mode == 2, cooling != nil { return 2 }
            return heating != nil ? 1 : 2
        }
        let showSetpoint: @Sendable () -> Void = {
            guard let celsius = celsiusSetpoints.withLockedValue({ $0[shownKey()] }) else { return }
            targetTemperature.value = .double(min(35, max(5, (celsius * 2).rounded() / 2)))
        }
        if let mode {
            let target = writer(mode.id)
            targetMode.onWrite { value in
                guard let mode = value.intValue else { return }
                try await target(.number(Double(mode)))
                // Kept before the handler returns, so the setpoint shown is the new mode's at once.
                targetMode.value = .int(mode)
                showSetpoint()
            }
            on(mode.id) { value in
                guard let mode = value.intValue else { return }
                if Self.homeKitModes.contains(mode) { targetMode.value = .int(mode) }
                if !hasOperatingState { currentMode.value = .int(mode == 1 ? 1 : mode == 2 ? 2 : 0) }
                showSetpoint()
            }
        }
        for setpoint in [heating, cooling].compactMap({ $0 }) {
            guard let key = setpoint.id.propertyKey?.intValue else { continue }
            on(setpoint.id) { value in
                guard let reading = value.numberValue else { return }
                celsiusSetpoints.withLockedValue { $0[key] = setpoint.celsius(reading) }
                showSetpoint()
            }
        }
        let heatingTarget = heating.map { (writer($0.id), $0) }, coolingTarget = cooling.map { (writer($0.id), $0) }
        let guardian = coalesce, key = "\(deviceID):\(endpoint):setpoint"
        targetTemperature.onWrite { value in
            guard let celsius = value.doubleValue, await guardian(key) else { return }
            let cool = shownKey() == 2
            guard let (target, setpoint) = cool ? coolingTarget : heatingTarget else { return }
            try await target(.number(setpoint.reading(celsius: celsius)))
            celsiusSetpoints.withLockedValue { $0[cool ? 2 : 1] = celsius }
        }
        if let operating = node.value(CommandClass.thermostatOperatingState, endpoint: endpoint, property: "state") {
            on(operating.id) { value in
                guard let state = value.intValue else { return }
                // 1 Heating, 2 Cooling; the fan-only and pending states are neither.
                currentMode.value = .int(state == 1 ? 1 : state == 2 ? 2 : 0)
            }
        }
        // The room's temperature: the endpoint's air temperature, else the device's.
        if let air = node.value(CommandClass.multilevelSensor, endpoint: endpoint, property: "Air temperature")
            ?? node.value(CommandClass.multilevelSensor, endpoint: 0, property: "Air temperature") {
            on(air.id) { value in
                guard let reading = value.numberValue else { return }
                currentTemperature.value = .double(min(100, max(-50, air.celsius(reading))))
            }
        }
        add(service)
    }

    // MARK: Meters

    /// Electric Meter values (Meter type 1): kWh (scale 0) and W (scale 2), consumed or, rate type 2, produced. They go
    /// on the endpoint's actuator as Eve's Total and Current Consumption, or on a service of their own, and the service's
    /// Meter is declared so the Energy section counts it.
    private mutating func buildMeters(endpoint: Int, on actuator: Service?, label: String) {
        let electric = node.values(CommandClass.meter, endpoint: endpoint).filter {
            $0.id.propertyText == "value" && ($0.metadata["ccSpecific"]?["meterType"]?.intValue ?? 1) == 1
        }
        func reading(scale: Int, produced: Bool) -> ZValue? {
            electric.first {
                let specific = $0.metadata["ccSpecific"]
                return specific?["scale"]?.intValue == scale && ((specific?["rateType"]?.intValue ?? 1) == 2) == produced
            }
        }
        let consumed = reading(scale: 0, produced: false), power = reading(scale: 2, produced: false), returned = reading(scale: 0, produced: true)
        guard consumed != nil || power != nil || returned != nil else { return }
        let service: Service
        if let actuator {
            service = actuator
        } else {
            service = Service(ZWaveTypes.energyService, name: label, subtype: "\(endpoint):meter")
            add(service)
        }
        let meter = self.meter(service)
        let inUse = service.type.uuid == ServiceType.outlet.uuid ? service.characteristic(.outletInUse) : nil
        // A counter's reading in kWh: a counter is never negative.
        let kilowattHours: @Sendable (JSONValue) -> Double? = { value in value.numberValue.flatMap { $0 >= 0 ? $0 : nil } }
        if let power {
            let characteristic = service.characteristic(adding: EveCharacteristic.currentConsumption)
            on(power.id) { value in
                guard let watts = value.numberValue else { return }
                characteristic.value = .double(max(0, watts))
                inUse?.value = .bool(watts > 0.5)
                meter.record(watts: watts)
            }
        }
        if let consumed {
            let characteristic = service.characteristic(adding: EveCharacteristic.totalConsumption)
            on(consumed.id) { value in
                guard let reading = kilowattHours(value) else { return }
                characteristic.value = .double(reading)
                meter.record(counter: reading * 1000)
            }
        }
        if let returned {
            on(returned.id) { value in
                guard let reading = kilowattHours(value) else { return }
                meter.record(counter: reading * 1000, direction: .returned)
            }
        }
    }

    // MARK: Sensors

    enum SensorKind: String, CaseIterable {
        case motion, contact, leak, smoke, carbonMonoxide

        var type: ServiceType {
            switch self {
            case .motion: .motionSensor
            case .contact: .contactSensor
            case .leak: .leakSensor
            case .smoke: .smokeSensor
            case .carbonMonoxide: .carbonMonoxideSensor
            }
        }

        var characteristic: CharacteristicType {
            switch self {
            case .motion: .motionDetected
            case .contact: .contactSensorState
            case .leak: .leakDetected
            case .smoke: .smokeDetected
            case .carbonMonoxide: .carbonMonoxideDetected
            }
        }

        var suffix: String {
            switch self {
            case .motion: "Motion"
            case .contact: "Contact"
            case .leak: "Leak"
            case .smoke: "Smoke"
            case .carbonMonoxide: "Carbon Monoxide"
            }
        }

        /// The characteristic's value: a contact sensor's 1 is open (not detected).
        func value(detected: Bool) -> HAPValue {
            self == .motion ? .bool(detected) : .int(detected ? 1 : 0)
        }
    }

    /// The sensors already made, by endpoint and kind: Notification's win over Binary Sensor's.
    private var sensors: Set<String> = []

    private mutating func sensor(_ kind: SensorKind, endpoint: Int, label: String, values: [ZValue], detected: @escaping @Sendable (JSONValue) -> Bool?) {
        let key = "\(endpoint):\(kind.rawValue)"
        guard !values.isEmpty, !sensors.contains(key) else { return }
        sensors.insert(key)
        let service = make(kind.type, name: "\(label) \(kind.suffix)", subtype: key)
        let characteristic = service.characteristic(kind.characteristic)
        for value in values {
            on(value.id) { json in
                guard let detected = detected(json) else { return }
                characteristic.value = kind.value(detected: detected)
            }
        }
        add(service)
    }

    /// Notification CC's states (zwave-js names each notification type's variables): motion (Home Security 7 and 8), the
    /// door (Access Control's Door state: 22 open, 23 closed, 5632 and 5633 open, tilted or not), water, smoke and CO
    /// (any state but idle).
    private mutating func buildNotificationSensors(endpoint: Int, label: String) {
        let values = node.values(CommandClass.notification, endpoint: endpoint)
        func named(_ type: String, _ variables: [String]) -> [ZValue] {
            for variable in variables {
                let found = values.filter { $0.id.propertyText == type && $0.id.propertyKeyText == variable }
                if !found.isEmpty { return found }
            }
            return []
        }
        sensor(.motion, endpoint: endpoint, label: label, values: named("Home Security", ["Motion sensor status"])) { json in
            json.intValue.map { $0 == 7 || $0 == 8 }
        }
        sensor(.contact, endpoint: endpoint, label: label, values: named("Access Control", ["Door state (simple)", "Door state"])) { json in
            json.intValue.flatMap { $0 == 23 ? false : [22, 5632, 5633].contains($0) ? true : nil }
        }
        let idle: @Sendable (JSONValue) -> Bool? = { json in json.intValue.map { $0 != 0 } }
        sensor(.leak, endpoint: endpoint, label: label, values: named("Water Alarm", ["Sensor status"]), detected: idle)
        sensor(.smoke, endpoint: endpoint, label: label, values: named("Smoke Alarm", ["Sensor status"]), detected: idle)
        sensor(.carbonMonoxide, endpoint: endpoint, label: label, values: named("CO Alarm", ["Sensor status"]), detected: idle)
    }

    /// Binary Sensor's types by the property zwave-js gives each (the type's name); `Any` and `General Purpose` say
    /// nothing of what they sense and are left out.
    private mutating func buildBinarySensors(endpoint: Int, label: String) {
        let values = node.values(CommandClass.binarySensor, endpoint: endpoint)
        let kinds: [(SensorKind, [String])] = [
            (.motion, ["Motion"]), (.contact, ["Door/Window", "Tilt"]), (.leak, ["Water"]), (.smoke, ["Smoke"]), (.carbonMonoxide, ["CO"]),
        ]
        for (kind, properties) in kinds {
            let found = values.filter { properties.contains($0.id.propertyText) }.prefix(1)
            sensor(kind, endpoint: endpoint, label: label, values: Array(found)) { $0.boolValue }
        }
    }

    /// Multilevel Sensor's air temperature, humidity and illuminance (in lux), unless the thermostat took the temperature.
    private mutating func buildMultilevelSensors(endpoint: Int, label: String) {
        if let air = node.value(CommandClass.multilevelSensor, endpoint: endpoint, property: "Air temperature"), !claimed.contains(air.id) {
            let service = make(.temperatureSensor, name: "\(label) Temperature", subtype: "\(endpoint):temperature",
                                  optional: [.currentTemperature.with(minValue: -100, maxValue: 100)])
            let characteristic = service.characteristic(.currentTemperature)
            on(air.id) { value in
                guard let reading = value.numberValue else { return }
                characteristic.value = .double(min(100, max(-100, air.celsius(reading))))
            }
            add(service)
        }
        if let humidity = node.value(CommandClass.multilevelSensor, endpoint: endpoint, property: "Humidity"), humidity.unit != "g/m³" {
            let service = make(.humiditySensor, name: "\(label) Humidity", subtype: "\(endpoint):humidity")
            let characteristic = service.characteristic(.currentRelativeHumidity)
            on(humidity.id) { value in
                guard let reading = value.numberValue else { return }
                characteristic.value = .double(min(100, max(0, reading)))
            }
            add(service)
        }
        if let light = node.value(CommandClass.multilevelSensor, endpoint: endpoint, property: "Illuminance"), light.unit?.lowercased() == "lux" {
            let service = make(.lightSensor, name: "\(label) Light", subtype: "\(endpoint):light")
            let characteristic = service.characteristic(.currentAmbientLightLevel)
            on(light.id) { value in
                guard let reading = value.numberValue else { return }
                characteristic.value = .double(min(100_000, max(0.0001, reading)))
            }
            add(service)
        }
    }

    // MARK: Battery and buttons

    private mutating func buildBattery() {
        let level = node.value(CommandClass.battery, endpoint: 0, property: "level")
        let low = node.value(CommandClass.battery, endpoint: 0, property: "isLow")
        guard level != nil || low != nil else { return }
        let service = Service(.battery, subtype: "battery", optional: [.batteryLevel, .chargingState])
        service.characteristic(.chargingState).value = .int(2)
        let levelCharacteristic = service.characteristic(.batteryLevel), lowCharacteristic = service.characteristic(.statusLowBattery)
        if let level {
            on(level.id) { value in
                guard let reading = value.numberValue else { return }
                levelCharacteristic.value = .int(Int(saturating: reading, in: 0...100) ?? 0)
                if low == nil { lowCharacteristic.value = .int(reading <= 15 ? 1 : 0) }
            }
        }
        if let low {
            on(low.id) { value in
                if let isLow = value.boolValue { lowCharacteristic.value = .int(isLow ? 1 : 0) }
            }
        }
        add(service)
    }

    /// Central Scene's key attributes as HomeKit's presses: Key Pressed 1 time is a single press, 2 times a double,
    /// Held Down a long press; Released and the other counts are not sent.
    static func pressEvent(_ attribute: Int) -> Int? {
        switch attribute {
        case 0: 0
        case 3: 1
        case 2: 2
        default: nil
        }
    }

    private mutating func buildCentralScene() {
        let scenes = node.values(CommandClass.centralScene).filter { $0.id.propertyText == "scene" && $0.id.propertyKey != nil }
        guard !scenes.isEmpty else { return }
        for (index, scene) in scenes.enumerated() {
            let number = scene.id.propertyKeyText.flatMap { Int($0) } ?? index + 1
            let attributes = scene.states.keys
            let supported = attributes.compactMap(Self.pressEvent).sorted()
            let events = supported.isEmpty ? [0, 1, 2] : supported
            let event = Characteristic(.programmableSwitchEvent.with(minValue: Double(events.min() ?? 0), maxValue: Double(events.max() ?? 2), validValues: events))
            let service = make(.statelessProgrammableSwitch, name: "\(name) Button \(number)", subtype: "scene:\(scene.id.endpoint):\(scene.id.propertyKeyText ?? String(number))",
                                  optional: [.serviceLabelIndex], extra: [event])
            service.characteristic(.serviceLabelIndex).value = .int(number)
            let characteristic = service.characteristic(.programmableSwitchEvent)
            notifiers[scene.id] = { value in
                guard let attribute = value.intValue, let press = Self.pressEvent(attribute), events.contains(press) else { return }
                characteristic.sendEvent(.int(press))
            }
            claimed.insert(scene.id)
            services.append(service)
        }
        let label = Service(.serviceLabel, subtype: "scenes")
        label.characteristic(.serviceLabelNamespace).value = .int(1)
        services.append(label)
    }
}

/// Types of the Eve app's the plugin uses beside `EveCharacteristic`'s.
enum ZWaveTypes {
    /// A service of Eve's that carries only a Meter's characteristics, for a meter with no switch.
    static let energyService = ServiceType(name: "EveEnergy", uuid: HAPUUID("00000001-0000-1777-8000-775D67EC4377"), required: [], optional: [.name])
}

/// Hue and saturation to and from RGB, for Color Switch's components.
enum ColorMath {
    /// Hue in degrees (nil for a grey) and saturation in percent.
    static func hueSaturation(red: Double, green: Double, blue: Double) -> (Double?, Double) {
        let r = red / 255, g = green / 255, b = blue / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let saturation = high == 0 ? 0 : delta / high * 100
        guard delta > 0 else { return (nil, saturation) }
        var hue: Double
        if high == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return ((hue * 10).rounded() / 10, (saturation * 10).rounded() / 10)
    }

    /// Full-value RGB from hue (degrees) and saturation (percent).
    static func rgb(hue: Double, saturation: Double) -> (Int, Int, Int) {
        let s = min(100, max(0, saturation)) / 100, h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = s, x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = 1 - chroma
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        func byte(_ value: Double) -> Int { Int(((value + m) * 255).rounded()) }
        return (byte(r), byte(g), byte(b))
    }
}
