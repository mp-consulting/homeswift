import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// HomeKit values the hub works with.
enum HK {
    static let lockUnsecured = 0
    static let lockSecured = 1
    static let doorOpen = 0
    static let doorClosed = 1
    static let doorOpening = 2
    static let doorClosing = 3
    static let contactDetected = 0
    static let contactNotDetected = 1
    static let singlePress = 0
}

/// One UniFi Access hub or reader in HomeKit (`AccessHub` and its modules): the door as a lock or a garage door
/// opener, a UA Gate's side door, the terminal inputs as contact sensors, the doorbell, access method switches,
/// automation triggers, and the MQTT topics of all of these.
///
/// The hub's state is here; HomeKit services mirror it. Events from the controller, writes from HomeKit and
/// MQTT, and timers all run on this actor.
actor AccessHub {
    /// What the hub gets from its controller.
    struct Environment: Sendable {
        var api: AccessAPI
        var mqtt: AccessMQTT?
        var options: FeatureOptions
        /// The controller's id in feature options (its MAC without separators).
        var controllerId: String?
        var ringDelay: Int
        var logger: Logger
        var timing: Timing
        var context: PluginContext
        /// Puts the hub's accessories in HomeKit and takes away the children it no longer has.
        var publish: @Sendable (_ accessories: [Accessory]) async -> Void
    }

    /// The hub's delays in units of `second`; tests shrink the unit.
    struct Timing: Sendable {
        var second: Duration = .seconds(1)
        var revert: Duration = AccessSettings.revertDelay

        var autoLock: Duration { second * 5 }
        var gateCooldown: Duration { second * 5 }
    }

    struct Hints: Sendable, Equatable {
        var syncName = true
        var hasSideDoor = false
        var wired: [SensorInput: Bool] = [:]
        var hasWiringSideDoorDps = false
        var separateAccessMethods = false
        var separateDoorbell = false
        var separateSensors = false
        var logDoorbell = true
        var logLock = true
        var log: [SensorInput: Bool] = [:]

        func hasWiring(_ input: SensorInput) -> Bool { wired[input] ?? false }
    }

    enum GateDirection: String, Sendable { case opening, open, closing }

    static let accessoryGroupAccessMethods = "AccessMethods"
    static let accessoryGroupDoorbell = "Doorbell"
    static let rexButtonModeKey = "rex_button_mode"

    /// The access methods of readers: capability, config key, label, feature option, switch subtype.
    struct AccessMethod: Sendable {
        var capabilities: [String]
        var key: String
        var configsApiKeys: [String]?
        var name: String
        var option: String
        var subtype: AccessReservedName
    }

    static let accessMethods: [AccessMethod] = [
        AccessMethod(capabilities: ["identity_face_unlock"], key: "face", name: "Face Unlock", option: "AccessMethod.Face", subtype: .accessMethodFace),
        AccessMethod(capabilities: ["hand_wave"], key: "wave", name: "Hand Wave", option: "AccessMethod.Hand", subtype: .accessMethodHand),
        AccessMethod(
            capabilities: ["mobile_unlock_ver2", "support_mobile_unlock"], key: "bt_button", configsApiKeys: ["bt", "bt_button", "bt_tap"], name: "Mobile",
            option: "AccessMethod.Mobile", subtype: .accessMethodMobile),
        AccessMethod(capabilities: ["nfc_card_easy_provision"], key: "nfc", name: "NFC", option: "AccessMethod.NFC", subtype: .accessMethodNFC),
        AccessMethod(capabilities: ["pin_code"], key: "pin_code", name: "PIN", option: "AccessMethod.PIN", subtype: .accessMethodPIN),
        AccessMethod(capabilities: ["qr_code"], key: "qr_code", name: "QR Code", option: "AccessMethod.QR", subtype: .accessMethodQR),
        AccessMethod(capabilities: ["support_apple_pass"], key: "apple_pass", name: "TouchPass", option: "AccessMethod.TouchPass", subtype: .accessMethodTouchPass),
    ]

    /// `UniFi Access:<identifier>`: the MAC, and the port of a door of a UA Hub Enterprise.
    nonisolated let id: String
    nonisolated let catalog: DeviceCatalogEntry
    let environment: Environment
    var logger: Logger { environment.logger }

    private(set) var uda: AccessDevice
    private(set) var hints = Hints()
    var controllerName: String
    /// `Controller Device [Model]: `, for the log.
    var prefix: String { "\(controllerName) \(AccessAPI.deviceName(uda)): " }

    // The states HomeKit sees. -1 until the services are configured.
    var dpsBacking = HK.contactDetected
    var lockBacking = HK.lockSecured
    var sideDpsBacking = HK.contactDetected
    var sideLockBacking = HK.lockSecured

    var gateDirection: GateDirection?
    var gateDirectionUntil = ContinuousClock.now
    var gateTransitionUntil = ContinuousClock.now
    var gateDirectionDuration: Duration
    private var gatePhaseTasks: [Task<Void, Never>] = []
    private var autoRelockTasks: [Bool: Task<Void, Never>] = [:]

    private(set) var doorbellRingRequestId: String?
    private var lastDoorbellRing: ContinuousClock.Instant?
    /// Minutes the relay stays unlocked after HomeKit unlocks it; nil for the controller's momentary unlock.
    private(set) var lockDelayInterval: Int?

    private(set) var mainDoorLocationId: String?
    private(set) var mainDoorName: String?
    private(set) var sideDoorLocationId: String?
    private(set) var sideDoorName: String?

    /// The accessory name HomeKit shows.
    var accessoryName: String
    /// The accessories and services built from the hints; rebuilt when they change.
    var built = Built()
    private var configured = false
    private var removed = false
    /// Counts the door and lock state changes events made, so the bootstrap's older states do not undo them.
    private var doorStateChanges = 0

    init(device: AccessDevice, controllerName: String, environment: Environment) {
        let accessoryId = "\(UniFiAccessPlugin.platform):\(device.identifier.uppercased())"
        uda = device
        catalog = DeviceCatalog.entry(device.deviceType) ?? DeviceCatalog.entries["UAH"]!
        id = accessoryId
        self.environment = environment
        self.controllerName = controllerName
        // Option values are any number a user typed: saturated, so `Hub.LockDelayInterval.1e300` is not a crash.
        let seconds = environment.options.integer("Hub.GateDirectionDuration", device: device.identifier, controller: environment.controllerId).value
            .flatMap { Int(saturating: $0, in: 0...AccessSettings.maximumOptionValue) }
        gateDirectionDuration = environment.timing.second * (seconds ?? AccessSettings.gateDirectionDuration)
        if let minutes = environment.options.integer("Hub.LockDelayInterval", device: device.identifier, controller: environment.controllerId).value, minutes >= 0 {
            lockDelayInterval = Int(saturating: minutes, in: 0...AccessSettings.maximumOptionValue)
        }
        // The name HomeKit already has, else the device's.
        accessoryName = environment.context.accessory(id: accessoryId)?.name ?? AccessSettings.sanitizeName(device.resolvedName)
    }

    // MARK: Feature options

    func hasFeature(_ option: String) -> Bool {
        environment.options.test(option, device: uda.identifier, controller: environment.controllerId)
    }

    func has(capability: String) -> Bool { uda.has(capability: capability) }

    var isOnline: Bool { uda.isFullyOnline }

    // MARK: Set-up

    /// Builds the accessories, publishes them, and starts following the hub (`configureDevice`).
    func configure() async {
        guard !configured else { return }
        configured = true
        configureHints()
        dpsBacking = hubDpsState()
        lockBacking = hubLockState()
        sideDpsBacking = hubDpsState(side: true)
        sideLockBacking = hubLockState(side: true)
        // Events are handled while this waits (publishing, the doors): their states are newer than the bootstrap's.
        let doorStates = doorStateChanges

        if catalog.usesLocationApi { await discoverDoorNames() }
        guard !removed else { return }
        logLockDelayInterval(mainDoorName ?? "door")
        if hints.hasSideDoor { logLockDelayInterval(sideDoorName ?? "side door") }
        updateName()

        await rebuild()
        // Removed (the plugin stopped) while publishing: no MQTT topics for a hub that is gone.
        guard !removed else { return }

        // The configured state, announced as the services come up.
        if has(capability: "is_hub") { lockChanged(side: false, value: hubLockState(), publish: false) }
        if hints.hasSideDoor { lockChanged(side: true, value: hubLockState(side: true), publish: false) }

        await configureMQTT()
        // Removed while subscribing: the topics cleanup did not see yet go too.
        guard !removed else { return await unsubscribeMQTT() }

        if catalog.usesLocationApi, let doors = await environment.api.doors, !doors.isEmpty {
            if doorStateChanges == doorStates { initializeDoors(from: doors) }
            if updateName() { await rebuild() }
        }
    }

    private func configureHints() {
        hints.syncName = hasFeature("Device.SyncName")
        if !hints.syncName { logger.info("\(prefix)Device name synchronization with HomeKit is disabled.") }
        hints.hasSideDoor = catalog.supportsSideDoor && hasFeature("Hub.SideDoor")
        for input in SensorInput.allCases {
            hints.wired[input] = catalog.has(input) && hasFeature("Hub.\(input.optionName)")
            hints.log[input] = hasFeature("Log.\(input.optionName)")
        }
        hints.hasWiringSideDoorDps = hints.hasSideDoor && hasFeature("Hub.SideDoor.DPS")
        hints.separateAccessMethods = hasFeature("AccessMethod.SeparateAccessory")
        hints.separateDoorbell = hasFeature("Hub.Doorbell.SeparateAccessory")
        hints.separateSensors = hasFeature("Hub.Sensors.SeparateAccessory")
        hints.logDoorbell = hasFeature("Log.Doorbell")
        hints.logLock = hasFeature("Log.Lock")
        if catalog.usesProxyMode { checkUltraInputs() }
    }

    /// UA Ultra has one input, DPS or REX as the hub is set: follow it.
    private func checkUltraInputs() {
        for input in [SensorInput.dps, .rex] {
            guard let mode = catalog.sensors[input]?.proxyMode else { continue }
            let enabled = proxyModeEnabled(mode)
            if hints.hasWiring(input), !enabled {
                hints.wired[input] = false
            } else if !hints.hasWiring(input), enabled, hasFeature("Hub.\(input.optionName)") {
                hints.wired[input] = true
            }
        }
    }

    private func proxyModeEnabled(_ mode: String) -> Bool {
        uda.extensions?.first?.targetConfig?.contains { $0.key == Self.rexButtonModeKey && AccessDevice.text($0.value) == mode } ?? false
    }

    private func logLockDelayInterval(_ door: String) {
        if let lockDelayInterval {
            logger.info("\(prefix)The \(door) lock relay will remain unlocked \(lockDelayInterval == 0 ? "indefinitely" : "for \(lockDelayInterval) minutes") after unlocking in HomeKit.")
        } else {
            logger.info("\(prefix)The \(door) lock relay will lock five seconds after unlocking in HomeKit.")
        }
    }

    /// The name to show: the door's or the device's alias when names are synchronised. True when it changed.
    @discardableResult
    func updateName() -> Bool {
        guard hints.syncName, let name = mainDoorName ?? uda.alias, !name.isEmpty else { return false }
        let cleaned = AccessSettings.sanitizeName(name)
        guard !cleaned.isEmpty, cleaned != accessoryName else { return false }
        accessoryName = cleaned
        return true
    }

    /// Stops timers and MQTT topics: the hub leaves HomeKit.
    func cleanup() async {
        removed = true
        clearGatePhaseTimers()
        for task in autoRelockTasks.values { task.cancel() }
        autoRelockTasks = [:]
        await unsubscribeMQTT()
    }

    private func unsubscribeMQTT() async {
        guard let mqtt = environment.mqtt, let topicId = mqttId else { return }
        for topic in ["doorbell/get", "dps/get", "lock/get", "lock/set", "sidedoor/lock/get", "sidedoor/lock/set", "sidedoor/dps/get"] {
            await mqtt.unsubscribe(topicId, topic)
        }
    }

    // MARK: Device state from configs

    /// Whether an input is wired: its proxy mode selected (UA Ultra), else all its wiring configs `on`.
    private func isWired(_ sensor: DeviceCatalogEntry.Sensor?) -> Bool {
        guard let sensor else { return false }
        if let mode = sensor.proxyMode { return proxyModeEnabled(mode) }
        guard let keys = sensor.wiringKeys else { return false }
        return uda.wiringActive(keys)
    }

    /// An input as a contact sensor state from the configs; not wired reads as closed.
    private func configuredState(_ sensor: DeviceCatalogEntry.Sensor?) -> Int {
        guard isWired(sensor), let key = sensor?.configKey else { return HK.contactDetected }
        return uda.config(key) == "on" ? HK.contactDetected : HK.contactNotDetected
    }

    func isWired(_ input: SensorInput) -> Bool { isWired(catalog.sensors[input]) }
    func isSideDoorDpsWired() -> Bool { isWired(catalog.sideDoor?.dps) }

    /// A terminal input as a contact sensor state.
    func hubInputState(_ input: SensorInput) -> Int { configuredState(catalog.sensors[input]) }

    func hubDpsState(side: Bool = false) -> Int { configuredState(side ? catalog.sideDoor?.dps : catalog.sensors[.dps]) }

    /// The relay: `off` is locked, anything else unlocked.
    func hubLockState(side: Bool = false) -> Int {
        guard let key = side ? catalog.sideDoor?.lockRelayConfigKey : catalog.lockRelayConfigKey else { return HK.lockSecured }
        return uda.config(key) == "off" ? HK.lockSecured : HK.lockUnsecured
    }

    static func lockState(_ value: String) -> Int { ["unlock", "unlocked"].contains(value) ? HK.lockUnsecured : HK.lockSecured }
    static func dpsState(_ value: String) -> Int { value == "open" ? HK.contactNotDetected : HK.contactDetected }
    static func isLocked(_ state: Int) -> Bool { state == HK.lockSecured }
    static func isClosed(_ state: Int) -> Bool { state == HK.contactDetected }

    // MARK: State, as HomeKit sees it

    /// The door position: the DPS contact sensor's value when there is one.
    var dpsState: Int {
        built.contact[.contactDPS].flatMap { $0.characteristic(.contactSensorState).value.intValue } ?? dpsBacking
    }

    /// The main door's position changed (`hkDpsState` setter): filters sensor bounce while the gate moves, and
    /// notices a gate closing early.
    func setDpsState(_ value: Int) {
        let closed = Self.isClosed(value)
        if let direction = gateDirection, ContinuousClock.now < gateDirectionUntil {
            if (direction == .opening && closed) || (direction == .closing && !closed) {
                logger.debug("\(prefix)Gate DPS bounce suppressed: \(closed ? "close" : "open") during \(direction.rawValue) phase.")
                return
            }
        }
        if catalog.usesLocationApi, closed, dpsBacking != value, gateDirection == .open || ContinuousClock.now >= gateDirectionUntil {
            logger.debug("\(prefix)Gate closing detected during \(gateDirection?.rawValue ?? "idle") phase — transitioning to Closing.")
            beginGateClosing()
        }
        dpsBacking = value
        doorStateChanges += 1
        built.contact[.contactDPS]?.characteristic(.contactSensorState).value = .int(value)
        dpsChanged(side: false, value: value)
        sensorChanged(.dps, value: value)
    }

    func setLockState(_ value: Int, side: Bool = false) {
        if side { sideLockBacking = value } else { lockBacking = value }
        doorStateChanges += 1
        lockChanged(side: side, value: value)
    }

    func inputState(_ input: SensorInput) -> Int {
        if input == .dps { return dpsState }
        return built.contact[input.reservedName].flatMap { $0.characteristic(.contactSensorState).value.intValue } ?? HK.contactNotDetected
    }

    func setInputState(_ input: SensorInput, _ value: Int) {
        if input == .dps { return setDpsState(value) }
        built.contact[input.reservedName]?.characteristic(.contactSensorState).value = .int(value)
        sensorChanged(input, value: value)
    }

    // MARK: Reactions (the hub's event bus)

    func lockChanged(side: Bool, value: Int, publish: Bool = true) {
        logger.debug("\(prefix)Event bus: lock:changed {\"isSideDoor\":\(side),\"value\":\(value)}.")
        let locked = Self.isLocked(value)
        let trigger = side ? AccessReservedName.lockDoorSideTrigger : .lockTrigger
        let serviceType = side ? DeviceCatalogEntry.DoorService.lock : doorServiceType
        var logIt = true
        if serviceType == .garageDoorOpener {
            if catalog.usesLocationApi {
                // A gate opened by a remote, a card or a button: animate it, unless a cycle runs already.
                if !side, !locked, ContinuousClock.now >= gateDirectionUntil {
                    if Self.isClosed(dpsBacking) { startGateCycle() } else { beginGateClosing() }
                }
                built.switches[trigger]?.characteristic(.on).value = .bool(!locked)
                logIt = false
            } else if let garage = built.garage {
                garage.characteristic(.targetDoorState).value = .int(locked ? HK.doorClosed : HK.doorOpen)
                garage.characteristic(.currentDoorState).value = .int(locked ? HK.doorClosed : HK.doorOpen)
            }
        } else if let lock = side ? built.sideLock : built.lock {
            lock.characteristic(.lockTargetState).value = .int(locked ? HK.lockSecured : HK.lockUnsecured)
            lock.characteristic(.lockCurrentState).value = .int(value)
        }
        if logIt {
            built.switches[trigger]?.characteristic(.on).value = .bool(!locked)
            if hints.logLock {
                if side {
                    logger.info("\(prefix)\(sideDoorName ?? "Side door") \(locked ? "locked" : "unlocked").")
                } else if catalog.usesLocationApi {
                    logger.info("\(prefix)\(mainDoorName ?? "Gate") \(locked ? "locked" : "unlocked").")
                } else {
                    logger.info("\(prefix)\(locked ? "Locked." : "Unlocked.")")
                }
            }
        }
        if publish { mqttPublish(side ? "sidedoor/lock" : "lock", locked ? "true" : "false") }
    }

    func dpsChanged(side: Bool, value: Int) {
        logger.debug("\(prefix)Event bus: dps:changed {\"isSideDoor\":\(side),\"value\":\(value)}.")
        if hints.log[.dps] ?? true {
            logger.info("\(prefix)\(side ? (sideDoorName ?? "Side door") : (mainDoorName ?? "Door")) position sensor \(Self.isClosed(value) ? "closed" : "open").")
        }
        mqttPublish(side ? "sidedoor/dps" : "dps", Self.isClosed(value) ? "false" : "true")
        if side {
            built.contact[.contactDPSSide]?.characteristic(.contactSensorState).value = .int(value)
            return
        }
        guard doorServiceType == .garageDoorOpener, catalog.usesLocationApi else { return }
        if gateDirection == .opening || gateDirection == .open {
            logger.debug("\(prefix)Gate DPS event ignored during \(gateDirection!.rawValue) phase.")
            return
        }
        guard let garage = built.garage else { return }
        if gateDirection == .closing {
            if value == HK.contactDetected {
                logger.debug("\(prefix)Gate DPS confirmed Closed — cycle complete, cooldown active.")
                clearGatePhaseTimers()
                // Closing stays on for a phase, so the sensor settling does not reopen the gate in HomeKit.
                gateDirectionUntil = .now + gatePhaseDuration
                garage.characteristic(.targetDoorState).value = .int(HK.doorClosed)
                garage.characteristic(.currentDoorState).value = .int(HK.doorClosed)
            }
            return
        }
        if !Self.isClosed(value) {
            logger.debug("\(prefix)Gate DPS open detected (no active cycle) — starting external gate cycle.")
            startGateCycle(external: true)
            return
        }
        logger.debug("\(prefix)Gate DPS update (no active cycle): Closed.")
        garage.characteristic(.targetDoorState).value = .int(HK.doorClosed)
        garage.characteristic(.currentDoorState).value = .int(HK.doorClosed)
    }

    func sensorChanged(_ input: SensorInput, value: Int) {
        logger.debug("\(prefix)Event bus: sensor:changed {\"input\":\"\(input.rawValue)\",\"value\":\(value)}.")
        // DPS has its own reaction.
        guard input != .dps, isWired(input) else { return }
        if hints.log[input] ?? true { logger.info("\(prefix)\(input.label) \(Self.isClosed(value) ? "closed" : "open").") }
        mqttPublish(input.topic, Self.isClosed(value) ? "false" : "true")
    }

    func deviceOnline(_ online: Bool) {
        for subtype in AccessReservedName.contactSensors {
            built.contact[subtype]?.characteristic(.statusActive).value = .bool(online)
        }
    }

    // MARK: The gate

    var gatePhaseDuration: Duration { gateDirectionDuration / 3 }

    func clearGatePhaseTimers() {
        for task in gatePhaseTasks { task.cancel() }
        gatePhaseTasks = []
    }

    /// Animates a gate cycle in three equal phases: opening, open, closing; the DPS confirms closed. A cycle
    /// started elsewhere (a remote) only animates opening and open, then waits for the DPS to see it close.
    func startGateCycle(external: Bool = false) {
        clearGatePhaseTimers()
        let phase = gatePhaseDuration
        gateDirection = .opening
        gateDirectionUntil = .now + gateDirectionDuration
        if external {
            logger.debug("\(prefix)External gate cycle started: Opening → Open (\(phase)) → waiting for DPS close.")
        } else {
            logger.debug("\(prefix)Gate cycle started: Opening → Open (\(phase)) → Closing (\(phase * 2)) → DPS confirms Closed (\(gateDirectionDuration) total).")
        }
        built.garage?.characteristic(.targetDoorState).value = .int(HK.doorOpen)
        built.garage?.characteristic(.currentDoorState).value = .int(HK.doorOpening)
        gatePhaseTasks.append(Task { [weak self] in
            try? await Task.sleep(for: phase)
            guard !Task.isCancelled else { return }
            await self?.gatePhaseOpen(external: external)
        })
        guard !external else { return }
        gatePhaseTasks.append(Task { [weak self] in
            try? await Task.sleep(for: phase * 2)
            guard !Task.isCancelled else { return }
            await self?.gatePhaseClosing()
        })
    }

    private func gatePhaseOpen(external: Bool) {
        gateDirection = .open
        logger.debug("\(prefix)\(external ? "External gate cycle phase: Open — waiting for DPS close." : "Gate cycle phase: Open.")")
        built.garage?.characteristic(.currentDoorState).value = .int(HK.doorOpen)
    }

    private func gatePhaseClosing() {
        logger.debug("\(prefix)Gate cycle phase: Closing.")
        beginGateClosing(clearTimers: false)
    }

    func beginGateClosing(clearTimers: Bool = true) {
        if clearTimers {
            clearGatePhaseTimers()
            gateDirectionUntil = .now + gatePhaseDuration
        }
        gateDirection = .closing
        built.garage?.characteristic(.targetDoorState).value = .int(HK.doorClosed)
        built.garage?.characteristic(.currentDoorState).value = .int(HK.doorClosing)
    }

    /// The garage door's current state: the gate's phase while a cycle runs, else the DPS (or the relay).
    func doorState() -> Int {
        guard catalog.usesLocationApi else { return Self.isLocked(lockBacking) ? HK.doorClosed : HK.doorOpen }
        if let gateDirection, ContinuousClock.now < gateDirectionUntil {
            switch gateDirection {
            case .opening: return HK.doorOpening
            case .open: return HK.doorOpen
            case .closing: return HK.doorClosing
            }
        }
        return Self.isClosed(dpsState) ? HK.doorClosed : HK.doorOpen
    }

    /// Unlocked now, locked again once the controller's momentary unlock is over: for doors whose relocking the
    /// controller does not report. A new unlock restarts the countdown.
    func scheduleAutoRelock(side: Bool) {
        autoRelockTasks[side]?.cancel()
        setLockState(HK.lockUnsecured, side: side)
        let delay = environment.timing.autoLock
        autoRelockTasks[side] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.autoRelock(side: side)
        }
    }

    private func autoRelock(side: Bool) {
        autoRelockTasks[side] = nil
        setLockState(HK.lockSecured, side: side)
    }

    // MARK: Commands

    /// Locks or unlocks a door (`hubDoorLockCommand`). False, logged, when it cannot.
    func doorLockCommand(locking: Bool, side: Bool = false) async -> Bool {
        let action = locking ? "lock" : "unlock"
        let doorName = side ? "side door" : (catalog.usesLocationApi ? "gate" : "door")
        // The relay relocks by itself unless a lock delay is set; a gate is motorised and closes on command.
        if lockDelayInterval == nil, locking, !catalog.usesLocationApi {
            logger.error("\(prefix)Unable to manually relock the \(doorName) when the lock relay is configured to the default settings.")
            return false
        }
        guard isOnline else {
            logger.error("\(prefix)Unable to \(action) the \(doorName). Device is offline.")
            return false
        }
        let api = environment.api
        if catalog.usesLocationApi {
            guard let door = side ? sideDoorLocationId : mainDoorLocationId else {
                logger.error("\(prefix)Unable to \(action) the \(side ? "side door" : "gate"). Door not found.")
                return false
            }
            // The location endpoint only unlocks (on a gate, toggles the motor): locking what is locked already
            // would open it. Done, without a command.
            if locking, isSecured(side: side) {
                logger.debug("\(prefix)The \(doorName) is already locked: not triggering it.")
                return true
            }
            let url = await api.endpoint("location") + "/\(door)/unlock"
            guard await api.retrieve(url, method: "PUT", body: Data("{}".utf8)) != nil else {
                logger.error("\(prefix)Unable to \(action) the \(doorName).")
                return false
            }
            // The controller sends no event for an unlock from HomeKit: show it, and the relock after it.
            if !locking { scheduleAutoRelock(side: side) }
            return true
        }
        // The lock delay as an unlock duration: none for the momentary unlock, 0 to lock, forever, or minutes.
        let duration: Double? = lockDelayInterval.map { delay in locking ? 0 : (delay == 0 ? .infinity : Double(delay)) }
        guard await api.unlock(uda, minutes: duration) else {
            logger.error("\(prefix)Unable to \(action).")
            return false
        }
        return true
    }

    /// A UA Gate door that a lock command has nothing to do for: the side door locked, the gate locked and
    /// closed (or closing). A gate that is open with its relay locked still closes on the command.
    func isSecured(side: Bool) -> Bool {
        if side { return Self.isLocked(sideLockBacking) }
        return Self.isLocked(lockBacking) && [HK.doorClosed, HK.doorClosing].contains(doorState())
    }

    /// Turns an access method on or off on the reader.
    func setAccessMethod(_ method: AccessMethod, on: Bool) async -> Bool {
        guard uda.config(method.key) != nil else { return false }
        let api = environment.api
        let path = catalog.usesConfigsApi ? "/configs?is_camera=true" : "/settings"
        let keys = catalog.usesConfigsApi ? (method.configsApiKeys ?? [method.key]) : [method.key]
        let payload: [[String: String]] = keys.map { ["key": $0, "tag": "open_door_mode", "value": on ? "yes" : "no"] }
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("[]".utf8)
        let url = await api.endpoint("device") + "/\(uda.uniqueId)\(path)"
        return await api.retrieve(url, method: "PUT", body: body) != nil
    }

    // MARK: Events from the controller

    /// The hub's device changed on the controller (`udaUpdates`): new configuration, online state, name.
    func updateDevice(_ device: AccessDevice) async {
        uda = device
        deviceOnline(isOnline)
        // The access methods as the controller has them now, which events missed while disconnected may not say
        // (Homebridge read them from the device on every get).
        for method in Self.accessMethods {
            guard let switchService = built.switches[method.subtype], let config = uda.config(method.key) else { continue }
            switchService.characteristic(.on).value = .bool(config == "yes")
        }
        guard hints.syncName else { return }
        let wanted = AccessSettings.sanitizeName(mainDoorName ?? uda.alias ?? "")
        if !wanted.isEmpty, wanted != accessoryName {
            logger.info("\(prefix)Name change detected. A restart of Homebridge may be needed in order to complete name synchronization with HomeKit.")
            await configureInfo()
        }
    }

    /// Names and accessory information (`configureInfo`): run at every refresh.
    func configureInfo() async {
        if updateName() {
            await rebuild()
        } else {
            refreshInformation()
        }
    }

    /// An event for this hub (`eventHandler`).
    func handle(_ packet: AccessEventPacket) async {
        guard !removed else { return }
        switch packet.event {
        case AccessEventType.deviceRemoteUnlock: handleRemoteUnlock(packet)
        case AccessEventType.deviceUpdate: await handleDeviceUpdate(packet)
        case AccessEventType.deviceUpdateV2: handleDeviceUpdateV2(packet)
        case AccessEventType.locationUpdate: await handleLocationUpdate(packet)
        case AccessEventType.doorbellRing: handleDoorbellRing(packet)
        case AccessEventType.doorbellCancel: handleDoorbellCancel(packet)
        default: break
        }
    }

    /// Whether a packet concerns this hub: its device, its doors, or a doorbell.
    func follows(_ packet: AccessEventPacket) -> Bool {
        if packet.event == AccessEventType.doorbellRing || packet.event == AccessEventType.doorbellCancel { return true }
        var ids: Set<String> = [uda.uniqueId]
        if catalog.usesLocationApi {
            if let mainDoorLocationId { ids.insert(mainDoorLocationId) }
            if let sideDoorLocationId { ids.insert(sideDoorLocationId) }
        }
        if ids.contains(packet.eventObjectId) { return true }
        if packet.event == AccessEventType.deviceUpdateV2, packet.metaObjectType == "device", let meta = packet.metaId, ids.contains(meta) { return true }
        return false
    }

    private func handleRemoteUnlock(_ packet: AccessEventPacket) {
        if catalog.usesLocationApi {
            let door = packet.eventObjectId
            let side = sideDoorLocationId != nil && door == sideDoorLocationId
            let main = mainDoorLocationId != nil && door == mainDoorLocationId
            guard side || main else { return }
            scheduleAutoRelock(side: side)
        } else {
            setLockState(HK.lockUnsecured)
        }
    }

    private func handleDeviceUpdate(_ packet: AccessEventPacket) async {
        if !catalog.skipsV1LockEvents, hubLockState() != lockBacking { setLockState(hubLockState()) }
        for input in SensorInput.allCases {
            let state = hubInputState(input)
            if hints.hasWiring(input), state != inputState(input) { setInputState(input, state) }
        }
        // The input mode of a UA Ultra: reconfigure only when it actually changed.
        if catalog.usesProxyMode, packet.data["extensions"]?[0]?["target_config"] != nil {
            let before = (hints.hasWiring(.dps), hints.hasWiring(.rex))
            checkUltraInputs()
            if before != (hints.hasWiring(.dps), hints.hasWiring(.rex)) {
                for input in [SensorInput.dps, .rex] where before.0 != hints.hasWiring(.dps) || before.1 != hints.hasWiring(.rex) {
                    let enabled = hints.hasWiring(input)
                    if built.contact[input.reservedName] != nil, !enabled { logger.info("\(prefix)Disabling the \(input.label.lowercased()).") }
                    if built.contact[input.reservedName] == nil, enabled { logger.info("\(prefix)Enabling the \(input.label.lowercased()).") }
                }
                await rebuild()
            }
        }
        if let online = packet.data["is_online"]?.boolValue { deviceOnline(online) }
    }

    private func handleDeviceUpdateV2(_ packet: AccessEventPacket) {
        if let methods = packet.data["access_method"]?.objectValue {
            for (key, value) in methods {
                guard let state = value.stringValue, state == "yes" || state == "no", let method = Self.accessMethods.first(where: { $0.key == key }) else { continue }
                built.switches[method.subtype]?.characteristic(.on).value = .bool(state == "yes")
            }
        }
        // A moving gate reports noise for both doors: wait for it to settle.
        guard let states = packet.data["location_states"]?.arrayValue, catalog.usesLocationApi, ContinuousClock.now >= gateTransitionUntil else { return }
        let extensions = uda.extensions
        if let mainId = extensions?.first(where: { $0.sourceId == DeviceCatalog.gateMainPortSourceId })?.targetValue ?? mainDoorLocationId,
            let state = states.first(where: { $0["location_id"]?.stringValue == mainId }) {
            updateDoor(from: state, side: false)
        }
        if hints.hasSideDoor, let sideId = extensions?.first(where: { $0.sourceId == DeviceCatalog.gateSidePortSourceId })?.targetValue ?? sideDoorLocationId,
            let state = states.first(where: { $0["location_id"]?.stringValue == sideId }) {
            updateDoor(from: state, side: true)
        }
    }

    private func handleLocationUpdate(_ packet: AccessEventPacket) async {
        guard catalog.usesLocationApi, let state = packet.data["state"], state.objectValue != nil, ContinuousClock.now >= gateTransitionUntil else { return }
        let location = packet.data["id"]?.stringValue
        let name = packet.data["name"]?.stringValue
        if location != nil, location == mainDoorLocationId {
            updateDoor(from: state, side: false)
            if let name, !name.isEmpty, mainDoorName != name {
                mainDoorName = name
                await configureInfo()
            }
        } else if location != nil, location == sideDoorLocationId, hints.hasSideDoor {
            updateDoor(from: state, side: true)
            if let name, !name.isEmpty, sideDoorName != name {
                sideDoorName = name
                if hints.syncName { await rebuild() }
            }
        }
    }

    private func updateDoor(from state: JSONValue, side: Bool) {
        let lock = Self.lockState(state["lock"]?.stringValue ?? "")
        let dps = Self.dpsState(state["dps"]?.stringValue ?? "")
        if side {
            if lock != sideLockBacking { setLockState(lock, side: true) }
            if dps != sideDpsBacking {
                sideDpsBacking = dps
                doorStateChanges += 1
                dpsChanged(side: true, value: dps)
            }
        } else {
            if lock != lockBacking { setLockState(lock) }
            if dps != dpsBacking { setDpsState(dps) }
        }
    }

    private func handleDoorbellRing(_ packet: AccessEventPacket) {
        guard packet.data["connected_uah_id"]?.stringValue == uda.uniqueId, has(capability: "door_bell") else { return }
        let request = packet.data["request_id"]?.stringValue ?? ""
        doorbellRingRequestId = request
        let delay = environment.timing.second * environment.ringDelay
        let now = ContinuousClock.now
        if environment.ringDelay > 0, let last = lastDoorbellRing, now - last < delay {
            logger.debug("\(prefix)Doorbell ring suppressed: within the configured ring delay of the previous ring.")
            return
        }
        lastDoorbellRing = now
        built.doorbell?.characteristic(.programmableSwitchEvent).sendEvent(.int(HK.singlePress))
        logger.debug("\(prefix)Event bus: doorbell:ring {\"requestId\":\"\(request)\"}.")
        built.switches[.doorbellTrigger]?.characteristic(.on).value = .bool(true)
        mqttPublish("doorbell", "true")
        if hints.logDoorbell { logger.info("\(prefix)Doorbell ring detected.") }
    }

    private func handleDoorbellCancel(_ packet: AccessEventPacket) {
        guard let request = doorbellRingRequestId, request == packet.data["remote_call_request_id"]?.stringValue else { return }
        doorbellRingRequestId = nil
        logger.debug("\(prefix)Event bus: doorbell:cancel {}.")
        built.switches[.doorbellTrigger]?.characteristic(.on).value = .bool(false)
        mqttPublish("doorbell", "false")
        if hints.logDoorbell { logger.info("\(prefix)Doorbell ring cancelled.") }
    }

    // MARK: UA Gate doors

    /// Finds the gate's main and side doors among the controller's doors (`discoverDoorNames`): by the port
    /// settings of the hub, then the doors bound to its MAC, then by name.
    func discoverDoorNames() async {
        let doors = await environment.api.doors ?? []
        let ports = uda.extensions?.filter { $0.extensionName == "port_setting" } ?? []
        logger.debug("\(prefix)Door discovery: \(doors.count) door(s) in API: \(doors.map { "\($0.uniqueId)=\($0.name)" }.joined(separator: ", "))")
        guard !doors.isEmpty else {
            logger.warning("\(prefix)No doors found in Access API. Door event handling may not work correctly.")
            return
        }
        let wiredIds = Set(ports.compactMap(\.targetValue).filter { !$0.isEmpty })
        let hubMAC = AccessSettings.normalizeMac(uda.mac)
        let wired = wiredIds.isEmpty ? [] : doors.filter { wiredIds.contains($0.uniqueId) }
        let byMAC = wired.isEmpty ? doors.filter { $0.deviceMACs.contains { AccessSettings.normalizeMac($0) == hubMAC } } : []
        let candidates = !wired.isEmpty ? wired : (!byMAC.isEmpty ? byMAC : doors)

        if hints.hasSideDoor {
            let sidePort = ports.first { $0.sourceId == DeviceCatalog.gateSidePortSourceId || $0.targetName == DeviceCatalog.gateSideDoorTargetName }
            if let target = sidePort?.targetValue, candidates.contains(where: { $0.uniqueId == target }) {
                sideDoorLocationId = target
            } else {
                sideDoorLocationId = candidates.first { Self.matches(Self.sideDoorPattern, $0.name) }?.uniqueId
            }
        }
        let mainCandidates = candidates.filter { $0.uniqueId != sideDoorLocationId }
        let mainPort = ports.first { $0.sourceId == DeviceCatalog.gateMainPortSourceId || $0.targetName == DeviceCatalog.gateMainDoorTargetName }
        if let target = mainPort?.targetValue, mainCandidates.contains(where: { $0.uniqueId == target }) {
            mainDoorLocationId = target
        } else if mainCandidates.count == 1 {
            mainDoorLocationId = mainCandidates[0].uniqueId
        } else if mainCandidates.count > 1 {
            let byName = mainCandidates.first { Self.matches(Self.mainDoorPattern, $0.name) && !Self.matches(Self.sideDoorPattern, $0.name) }
            let bound = uda.doorId
            let boundIsCandidate = bound != nil && mainCandidates.contains { $0.uniqueId == bound }
            mainDoorLocationId = byName?.uniqueId ?? (boundIsCandidate ? bound : mainCandidates[0].uniqueId)
        }
        if hints.hasSideDoor, sideDoorLocationId == nil, candidates.count == 2 {
            sideDoorLocationId = candidates.first { $0.uniqueId != mainDoorLocationId }?.uniqueId
        }
        mainDoorName = doors.first { $0.uniqueId == mainDoorLocationId }?.name
        sideDoorName = hints.hasSideDoor ? doors.first { $0.uniqueId == sideDoorLocationId }?.name : nil
        logger.info(
            "\(prefix)Discovered main door: \(mainDoorName ?? "(unnamed)") (id=\(mainDoorLocationId ?? "(none)"))\(hints.hasSideDoor ? ", side door: \(sideDoorName ?? "(unnamed)") (id=\(sideDoorLocationId ?? "(none)"))" : "")."
        )
    }

    /// Door names that suggest a side door or a main gate, in English and French.
    static let sideDoorPattern = ["portillon", "side", "pedestrian", "pieton", "wicket", "back", "secondary"]
    static let mainDoorPattern = ["portail", "main", "principal", "entry", "front", "gate"]

    static func matches(_ words: [String], _ name: String) -> Bool {
        let lowered = name.lowercased()
        return words.contains { lowered.contains($0) }
    }

    /// The doors' states from the bootstrap.
    func initializeDoors(from doors: [AccessDoor]) {
        if let main = mainDoorLocationId, let door = doors.first(where: { $0.uniqueId == main }) {
            dpsBacking = Self.dpsState(door.doorPositionStatus ?? "close")
            lockBacking = Self.lockState(door.doorLockRelayStatus ?? "lock")
        }
        if hints.hasSideDoor, let side = sideDoorLocationId, let door = doors.first(where: { $0.uniqueId == side }) {
            sideDpsBacking = Self.dpsState(door.doorPositionStatus ?? "close")
            sideLockBacking = Self.lockState(door.doorLockRelayStatus ?? "lock")
            built.contact[.contactDPSSide]?.characteristic(.contactSensorState).value = .int(sideDpsBacking)
        }
        // The services read these states (Homebridge's getters did).
        for (service, state) in [(built.lock, lockBacking), (built.sideLock, sideLockBacking)] {
            service?.characteristic(.lockCurrentState).value = .int(state)
            service?.characteristic(.lockTargetState).value = .int(Self.isLocked(state) ? HK.lockSecured : HK.lockUnsecured)
        }
        built.garage?.characteristic(.currentDoorState).value = .int(doorState())
    }

    // MARK: The settings page and the Assistant

    /// What the hub's doors and access methods are now, as HomeKit sees them: `locked`, `door` (`open`, `closed`,
    /// `opening`, `closing`) when there is a position sensor or a gate, a UA Gate's side door, a reader's methods.
    func stateJSON() -> [String: JSONValue] {
        var json: [String: JSONValue] = [:]
        if has(capability: "is_hub") {
            json["locked"] = .bool(Self.isLocked(lockBacking))
            if catalog.usesLocationApi || hints.hasWiring(.dps) {
                json["door"] = .string(["open", "closed", "opening", "closing"][doorPosition()])
            }
        }
        if hints.hasSideDoor {
            json["sideDoorLocked"] = .bool(Self.isLocked(sideLockBacking))
            if hints.hasWiringSideDoorDps { json["sideDoor"] = .string(Self.isClosed(sideDpsBacking) ? "closed" : "open") }
        }
        var methods: [String: JSONValue] = [:]
        for method in Self.accessMethods where built.switches[method.subtype] != nil {
            methods[method.name] = .bool(uda.config(method.key) == "yes")
        }
        if !methods.isEmpty { json["accessMethods"] = .object(methods) }
        return json
    }

    /// The door's position as a HomeKit door state: the gate's phase on a UA Gate, else the DPS.
    private func doorPosition() -> Int {
        catalog.usesLocationApi ? doorState() : (Self.isClosed(dpsState) ? HK.doorClosed : HK.doorOpen)
    }

    // MARK: MQTT

    /// The device's id in topics.
    var mqttId: String? { uda.identifier.isEmpty ? nil : uda.identifier }

    private func mqttPublish(_ topic: String, _ message: String) {
        guard let mqtt = environment.mqtt, let topicId = mqttId else { return }
        Task { await mqtt.publish(topicId, topic, message) }
    }

    static func mqttLock(_ state: Int) -> String {
        switch state {
        case HK.lockSecured: "true"
        case HK.lockUnsecured: "false"
        default: "unknown"
        }
    }

    static func mqttDps(_ state: Int) -> String {
        switch state {
        case HK.contactDetected: "false"
        case HK.contactNotDetected: "true"
        default: "unknown"
        }
    }

    private func configureMQTT() async {
        guard let mqtt = environment.mqtt, let topicId = mqttId else { return }
        let prefix = prefix
        if has(capability: "door_bell") {
            await mqtt.subscribeGet(topicId, "doorbell", type: "Doorbell ring", logPrefix: prefix) { [weak self] in
                await self?.doorbellRingRequestId != nil ? "true" : "false"
            }
        }
        guard has(capability: "is_hub") else { return }
        await mqtt.subscribeGet(topicId, "dps", type: "Door position sensor", logPrefix: prefix) { [weak self] in
            guard let self else { return "unknown" }
            return await self.isWired(.dps) ? Self.mqttDps(await self.dpsState) : "unknown"
        }
        await mqtt.subscribeGet(topicId, "lock", type: "Lock", logPrefix: prefix) { [weak self] in
            Self.mqttLock(await self?.lockBacking ?? -1)
        }
        await subscribeLockSet(mqtt, topicId, "lock", type: "Lock", side: false)
        guard hints.hasSideDoor else { return }
        await mqtt.subscribeGet(topicId, "sidedoor/lock", type: "Side Door Lock", logPrefix: prefix) { [weak self] in
            Self.mqttLock(await self?.sideLockBacking ?? -1)
        }
        await subscribeLockSet(mqtt, topicId, "sidedoor/lock", type: "Side Door Lock", side: true)
        await mqtt.subscribeGet(topicId, "sidedoor/dps", type: "Side door position sensor", logPrefix: prefix) { [weak self] in
            guard let self else { return "unknown" }
            return await self.isSideDoorDpsWired() ? Self.mqttDps(await self.sideDpsBacking) : "unknown"
        }
    }

    /// `true` locks, `false` unlocks.
    private func subscribeLockSet(_ mqtt: AccessMQTT, _ topicId: String, _ topic: String, type: String, side: Bool) async {
        let prefix = prefix
        let logger = logger
        await mqtt.subscribeSet(topicId, topic, type: type, logPrefix: prefix) { [weak self] value in
            guard value == "true" || value == "false" else {
                logger.error("\(prefix)MQTT: Unknown \(type.lowercased()) set message received: \(value).")
                return
            }
            _ = await self?.doorLockCommand(locking: value == "true", side: side)
        }
    }
}
