import Foundation
import Homeswift
import HomeswiftPlugin

/// A washer's or dryer's state (`washerDryer`, or `washer` for WASH_TOWER_2).
struct WasherDryerStatus {
    nonisolated static let notRunning = ["COOLDOWN", "POWEROFF", "POWERFAIL", "INITIAL", "PAUSE", "AUDIBLE_DIAGNOSIS", "FIRMWARE", "COURSE_DOWNLOAD", "ERROR", "END"]
    nonisolated static let tclMaintenanceThreshold = 30.0

    let reader: StatusReader
    let deviceModel: DeviceModel

    init(data: [String: JSONValue], deviceModel: DeviceModel) {
        reader = StatusReader(data: data)
        self.deviceModel = deviceModel
    }

    var state: String { reader.string("state") }
    var isPowerOn: Bool { !["POWEROFF", "POWERFAIL"].contains(state) }
    var isRunning: Bool { isPowerOn && !Self.notRunning.contains(state) }
    var isError: Bool { state == "ERROR" }
    var isRemoteStartEnable: Bool { reader.string("remoteStart") == deviceModel.lookupMonitorName("remoteStart", "@CP_ON_EN_W") }

    var isDoorLocked: Bool {
        guard let locked = deviceModel.lookupMonitorName("doorLock", "@CP_ON_EN_W") else { return reader.string("doorLock") == "DOORLOCK_ON" }
        return reader.string("doorLock") == locked
    }

    var remainDuration: Double {
        isRunning ? reader.int("remainTimeHour") * 3600 + reader.int("remainTimeMinute") * 60 : 0
    }

    var tclCount: Double { min(reader.int("TCLCount"), Self.tclMaintenanceThreshold) }
}

/// A washer, dryer or WashTower: a Valve that is active while a program runs (remaining time, fault on
/// error), the door lock, a Program Finished occupancy sensor for automations, and the Tub Clean Coach.
/// Programs cannot be started from HomeKit.
class WasherDryer: BaseDevice {
    nonisolated static let finishedSensorDuration: Duration = .seconds(600)

    var isRunning = false
    var serviceWasherDryer: Service!
    var serviceEventFinished: Service?
    var serviceDoorLock: Service?
    var serviceTubCleanMaintenance: Service?
    /// The last merged state, to see a program reach END.
    var lastState: String?
    private let finishedTimer = Timeout()

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let name = device.name
        let valve = addService(.valve, name: name, subtype: name, optional: [
            CharacteristicType.remainingDuration.props(max: 86_400), .statusFault,
        ])
        valve.characteristic(.active).onSet { [weak self] value in try await self?.setActive(value) }
        valve.set(.active, 0)
        valve.set(.valveType, 3)
        valve.set(.inUse, 0)
        valve.set(.remainingDuration, 0)
        serviceWasherDryer = valve

        // Only ThinQ2 reports the door lock.
        let root = stateRoot
        if config.flag("washer_door_lock"), device.platform == PlatformType.thinq2, root?["doorLock"] != nil {
            let lock = addService(.lockMechanism, name: "\(name) - Door", subtype: "Door", optional: [
                CharacteristicType.lockCurrentState.props(min: 0, max: 3).valid([0, 1]),
            ])
            lock.set(.lockCurrentState, 0)
            lock.characteristic(.lockTargetState).onSet { [weak self] value in try await self?.setActive(value) }
            lock.set(.lockTargetState, 0)
            serviceDoorLock = lock
        }
        if config.flag("washer_trigger") {
            serviceEventFinished = addService(.occupancySensor, name: "Program Finished")
            serviceEventFinished?.set(.occupancyDetected, 0)
        }
        if config.flag("washer_tub_clean") {
            // The Homebridge plugin adds a Programmable Switch Event to this sensor too.
            serviceTubCleanMaintenance = addService(.occupancySensor, name: "Tub Clean Coach", optional: [CharacteristicType.programmableSwitchEvent.valid([0])])
            serviceTubCleanMaintenance?.set(.occupancyDetected, 0)
        }
        lastState = root != nil ? status.state.nonEmpty : nil
    }

    /// Where the state sits in the snapshot.
    var stateRootKey: String { DeviceRegistry.snapshotKey(device.type) ?? "washerDryer" }
    var stateRoot: [String: JSONValue]? { device.snapshot[stateRootKey]?.objectValue }
    var status: WasherDryerStatus { WasherDryerStatus(data: statusData(stateRootKey), deviceModel: device.deviceModel) }

    /// Not controllable: back to the real state, once the write has stored the value HomeKit sent.
    func setActive(_ value: HAPValue) async throws {
        after(.milliseconds(100)) { [weak self] in
            guard let self else { return }
            updateAccessoryCharacteristic(device)
        }
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let status = status
        serviceWasherDryer.set(.active, status.isRunning ? 1 : 0)
        serviceWasherDryer.set(.inUse, status.isRunning ? 1 : 0)
        serviceWasherDryer.set(.remainingDuration, status.remainDuration)
        serviceWasherDryer.set(.statusFault, status.isError ? 1 : 0)
        if config.flag("washer_door_lock"), let lock = serviceDoorLock {
            lock.set(.lockCurrentState, status.isDoorLocked ? 1 : 0)
            lock.set(.lockTargetState, status.isDoorLocked ? 1 : 0)
        }
    }

    override func update(_ snapshot: [String: JSONValue]) {
        super.update(snapshot)
        guard let delta = snapshot[stateRootKey]?.objectValue else { return }
        // The merged state, since MQTT deltas can carry only `state`.
        let status = status
        let state = status.state
        let previous = lastState
        if !state.isEmpty { lastState = state }

        if config.flag("washer_trigger"), let sensor = serviceEventFinished {
            // A program is done: a running state turned END or COOLDOWN.
            let enteredEnd = ["END", "COOLDOWN"].contains(state) && previous != nil && previous != state && !WasherDryerStatus.notRunning.contains(previous!)
            if enteredEnd || (isRunning && !status.isRunning) {
                sensor.set(.occupancyDetected, 1)
                isRunning = false
                finishedTimer.schedule(after: Self.finishedSensorDuration) { [weak sensor] in sensor?.set(.occupancyDetected, 0) }
            }
            if status.isRunning, !isRunning {
                sensor.set(.occupancyDetected, 0)
                isRunning = true
            }
        }
        if delta["TCLCount"] != nil, let tubClean = serviceTubCleanMaintenance {
            tubClean.set(.occupancyDetected, status.tclCount >= WasherDryerStatus.tclMaintenanceThreshold ? 1 : 0)
        }
    }

    override func destroy() {
        finishedTimer.cancel()
        super.destroy()
    }
}

/// The newer WashTower (type 223), whose washer reports under `washer`.
final class WasherDryer2: WasherDryer {
    override var stateRootKey: String { "washer" }
}

/// A styler: a Valve on while powered, in use while a program runs. Not controllable.
final class Styler: BaseDevice {
    nonisolated static let notRunning = ["POWEROFF", "INITIAL", "PAUSE", "COMPLETE", "ERROR", "DIAGNOSIS", "RESERVED", "SLEEP", "FOTA"]

    var serviceStyler: Service!

    struct Status {
        let reader: StatusReader
        let deviceModel: DeviceModel
        var isPowerOn: Bool { !["POWEROFF", "POWERFAIL"].contains(reader.string("state")) }
        var isRemoteStartOn: Bool { reader.string("remoteStart") == deviceModel.lookupMonitorName("remoteStart", "@CP_ON_EN_W") }
        var isRunning: Bool { isPowerOn && !Styler.notRunning.contains(reader.string("state")) }
        var isError: Bool { reader.string("state") == "ERROR" }
        var remainDuration: Double { isRunning ? reader.int("remainTimeHour") * 3600 + reader.int("remainTimeMinute") * 60 : 0 }
    }

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let styler = addService(.valve, name: device.name, optional: [CharacteristicType.remainingDuration.props(max: 86_400), .statusFault])
        styler.characteristic(.active).onSet { [weak self] value in await self?.setActive(value) }
        styler.set(.active, 0)
        styler.set(.valveType, 0)
        styler.set(.inUse, 0)
        serviceStyler = styler
    }

    var status: Status { Status(reader: StatusReader(data: statusData("styler")), deviceModel: device.deviceModel) }

    /// Not controllable: back to the real state.
    func setActive(_ value: HAPValue) async {
        after(.milliseconds(100)) { [weak self] in
            guard let self else { return }
            serviceStyler.set(.active, status.isPowerOn ? 1 : 0)
        }
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let status = status
        serviceStyler.set(.active, status.isPowerOn ? 1 : 0)
        serviceStyler.set(.inUse, status.isRunning ? 1 : 0)
        serviceStyler.set(.remainingDuration, status.remainDuration)
        serviceStyler.set(.statusFault, status.isError ? 1 : 0)
    }
}

/// A range hood: the vent as a Fan (its levels as the speed) and the lamp as a dimmable light.
class RangeHood: BaseDevice {
    var serviceHood: Service!
    var serviceLight: Service!

    struct Status {
        let reader: StatusReader
        let deviceModel: DeviceModel
        var isVentOn: Bool { reader.string("ventSet") == deviceModel.lookupMonitorName("VentSet", "@CP_ENABLE_W") }
        var isLampOn: Bool { reader.string("lampSet") == deviceModel.lookupMonitorName("LampSet", "@CP_ENABLE_W") }
        var ventLevel: Double { reader.int("ventLevel") }
        var lampLevel: Double { reader.int("lampLevel") }
    }

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let model = device.deviceModel
        var speed = CharacteristicType.rotationSpeed
        if case .range(let min, let max, let step)? = model.value("VentLevel") { speed = speed.props(min: min, max: max, step: step) }
        let hood = addService(.fan, name: device.name, optional: [speed])
        hood.characteristic(.on).onSet { [weak self] value in try await self?.setHoodActive(value) }
        hood.characteristic(.rotationSpeed).onSet { [weak self] value in try await self?.setHoodRotationSpeed(value) }
        serviceHood = hood

        var brightness = CharacteristicType.brightness
        if case .range(let min, let max, let step)? = model.value("LampLevel") { brightness = brightness.props(min: min, max: max, step: step) }
        let light = addService(.lightbulb, name: "\(device.name) - Light", subtype: "Light", optional: [brightness])
        light.characteristic(.on).onSet { [weak self] value in try await self?.setLightActive(value) }
        light.characteristic(.brightness).onSet { [weak self] value in try await self?.setLightBrightness(value) }
        serviceLight = light
    }

    var status: Status { Status(reader: StatusReader(data: statusData("hoodState")), deviceModel: device.deviceModel) }

    func setHoodActive(_ value: HAPValue) async throws {
        try await setHoodRotationSpeed(.int(value.boolValue == true ? 1 : 0))
    }

    func setHoodRotationSpeed(_ value: HAPValue) async throws {
        try await sendHoodControl(["ventLevel": Self.json(value)], label: "hood rotation speed")
    }

    func setLightActive(_ value: HAPValue) async throws {
        try await setLightBrightness(.int(value.boolValue == true ? 1 : 0))
    }

    func setLightBrightness(_ value: HAPValue) async throws {
        try await sendHoodControl(["lampLevel": Self.json(value)], label: "light brightness")
    }

    nonisolated static func json(_ value: HAPValue) -> JSONValue {
        switch value {
        case .bool(let bool): .bool(bool)
        case .int(let int): .number(Double(int))
        case .double(let double): .number(double)
        case .string(let string): .string(string)
        case .null: .null
        }
    }

    /// A `hoodState` command, which must be accepted.
    func sendHoodControl(_ values: [String: JSONValue], label: String) async throws {
        try await sendAccepted(Self.dataSetList(["hoodState": .object(values)]),
            failed: { logger.error("Failed to set \(label): \($0)") },
            refused: { logger.warning("[\(device.name)] Device did not accept \(label)") })
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let status = status
        serviceHood.set(.on, status.isVentOn)
        serviceHood.set(.rotationSpeed, status.ventLevel)
        serviceLight.set(.on, status.isLampOn)
        serviceLight.set(.brightness, status.lampLevel)
    }
}
