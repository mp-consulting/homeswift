import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The behaviour of every Dummy accessory of one block: state, stored properties, timers, schedules, the limiter,
/// fades, simulations, the attached sensors and the condition engine (spec 6, 7). All of it runs on this actor; the
/// HomeKit handlers, the webhook server and the timers call in.
actor DummyEngine {
    struct Dependencies: Sendable {
        var scheduler: any DummyScheduler = SystemScheduler()
        var calendar: Calendar = .current
        var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
        var notifier: (any DummyNotifying)?
        var probe: any ReachabilityProbing = TCPReachabilityProbe()
    }

    let logger: Logger
    let verbose: Bool
    let dependencies: Dependencies
    let storeFile: JSONFile<[String: [String: JSONValue]]>?
    let tasks: TaskBag
    var scheduler: any DummyScheduler { dependencies.scheduler }
    var nowMilliseconds: Double { scheduler.now.timeIntervalSince1970 * 1000 }

    /// Stored properties by identifier (spec 6.1).
    var store: [String: [String: JSONValue]]
    var devices: [String: DummyDevice] = [:]
    var order: [String] = []

    /// The condition engine: the last state each accessory reported, who watches whom, reachability by host.
    var reported: [String: String] = [:]
    var watchers: [String: [String]] = [:]
    var reachability: [String: Bool] = [:]
    var pingTimers: [String: DummyTimer] = [:]
    var logPatterns: [(identifier: String, regex: NSRegularExpression?, literal: String)] = []
    var stopped = false

    init(logger: Logger, verbose: Bool, storeFile: JSONFile<[String: [String: JSONValue]]>?, tasks: TaskBag, dependencies: Dependencies) {
        self.logger = logger
        self.verbose = verbose
        self.storeFile = storeFile
        self.tasks = tasks
        self.dependencies = dependencies
        store = storeFile?.load() ?? [:]
    }

    // MARK: Logging

    func info(_ device: DummyDevice, _ message: String) {
        guard !device.config.disableLogging else { return }
        logger.info("\(message)")
    }

    func debug(_ message: String) {
        if verbose { logger.info("\(message)") } else { logger.debug("\(message)") }
    }

    // MARK: Stored properties

    func stored(_ identifier: String, _ key: String) -> JSONValue? { store[identifier]?[key] }

    func setStored(_ identifier: String, _ key: String, _ value: JSONValue?) {
        if let value {
            guard store[identifier]?[key] != value else { return }
            store[identifier, default: [:]][key] = value
        } else {
            guard store[identifier]?[key] != nil else { return }
            store[identifier]?.removeValue(forKey: key)
        }
        save()
    }

    func save() {
        guard let storeFile else { return }
        do { try storeFile.save(store) } catch { logger.error("Could not save the accessories' state: \(error)") }
    }

    // MARK: Lifecycle

    /// Puts the accessories in the engine and starts them: stored state, schedules, conditions (spec 5).
    func start(_ entries: [(AccessoryConfig, DeviceServices)]) {
        for (config, services) in entries {
            let device = DummyDevice(config: config, services: services)
            devices[config.identifier] = device
            order.append(config.identifier)
        }
        for identifier in order {
            guard let device = devices[identifier], let conditions = device.config.conditions else { continue }
            for operand in conditions.operands {
                if case .accessory(let id, _) = operand { watchers[id, default: []].append(identifier) }
            }
        }
        for identifier in order {
            guard let device = devices[identifier] else { continue }
            if !device.config.commandKeys.isEmpty {
                logger.warning("\(device.name): Homeswift runs no shell commands (\(device.config.commandKeys.joined(separator: ", "))); they are ignored")
            }
            restore(device)
            startRepeatingSchedules(device)
        }
        for identifier in order {
            guard let device = devices[identifier] else { continue }
            report(device)
            startPings(device)
        }
    }

    func stop() {
        stopped = true
        for device in devices.values {
            device.fadeTimer?.cancel()
            device.timeouts.values.forEach { $0.cancel() }
            device.repeating.values.forEach { $0.cancel() }
            device.limiterTimer?.cancel()
            device.sensorPulse?.cancel()
            device.simulationTimer?.cancel()
            device.services.history?.flush()
        }
        pingTimers.values.forEach { $0.cancel() }
        pingTimers = [:]
    }

    /// The stored state, put back through the normal path for stateful accessories (spec 6.2).
    func restore(_ device: DummyDevice) {
        let id = device.identifier
        device.resumable = Set(["Schedule", "AutoReset", "SyncSchedule", "Timer"].filter { stored(id, $0) != nil })
        if device.config.type == .lightbulb, let brightness = stored(id, "Brightness")?.doubleValue {
            device.brightness = Int(saturating: brightness, in: 0...100) ?? 100
        }
        restoreLimiter(device)
        setUpValve(device)
        let stateful = !device.config.resetOnRestart
        switch device.config.family {
        case .onOff, .lock, .position, .garage, .valve, .humidifier:
            if device.config.family == .humidifier, stateful {
                if let target = stored(id, "TargetRelativeHumidity")?.doubleValue { device.targetHumidity = target }
                if let current = stored(id, "CurrentRelativeHumidity")?.doubleValue {
                    device.currentHumidity = current
                    device.currentHumidityExplicit = true
                } else {
                    device.currentHumidity = device.targetHumidity
                }
            }
            publish(device)
            if stateful, let value = stored(id, device.primaryKey).flatMap(device.primary(fromStored:)) {
                setPrimary(device, value, source: .restore)
            }
        case .binarySensor:
            if stateful, let value = stored(id, device.primaryKey).flatMap(device.primary(fromStored:)) { device.primary = value }
            publish(device)
        case .valueSensor:
            let key = device.config.type == .temperatureSensor ? "CurrentTemperature" : "CurrentRelativeHumidity"
            if stateful, let value = stored(id, key)?.doubleValue { device.value = value }
            publish(device)
        case .thermostat:
            if stateful {
                if let mode = stored(id, "TargetHeatingCoolingState")?.intValue, device.config.validStates.contains(mode) { device.targetMode = mode }
                if let mode = stored(id, "CurrentHeatingCoolingState")?.intValue, (0...2).contains(mode) {
                    device.currentMode = mode
                    device.currentModeExplicit = true
                }
                if let value = stored(id, "TargetTemperature")?.doubleValue { device.targetTemperature = value }
                if let value = stored(id, "CurrentTemperature")?.doubleValue { device.currentTemperature = value }
            }
            publish(device)
        case .button:
            break
        }
    }

    // MARK: The main value and its bookkeeping (spec 7.1)

    func setPrimary(_ device: DummyDevice, _ value: Int, source: ChangeSource) {
        guard !stopped else { return }
        let old = device.primary
        device.primary = value
        device.hasBeenSet = true
        let changed = old != value
        if device.isTriggered {
            if device.config.autoReset?.isTimeout == true { startTimeout(device, .autoReset) }
            if changed, source != .restore { notify(device, trigger: true) }
            startLimiter(device)
            if device.config.fade != nil, device.config.family == .onOff, value == 1 { startFade(device) }
        } else {
            if device.config.schedule?.isTimeout == true { startTimeout(device, .schedule) }
            cancelTimeout(device, .autoReset, log: true)
            pauseLimiter(device)
            if changed, source != .restore { notify(device, trigger: false) }
            cancelFade(device)
        }
        publish(device)
        if changed {
            info(device, device.stateMessage)
            setStored(device.identifier, device.primaryKey, device.storedPrimary)
            recordHistory(device)
            if device.isOpen, device.config.family == .position || device.config.family == .garage { countOpening(device) }
            simulate(device, from: old)
        }
        updateSensor(device, source: source, changed: changed)
        if source != .restore { report(device) }
    }

    /// A schedule's or a condition's trigger: the non-default state, or a press for a button.
    func trigger(_ device: DummyDevice, source: ChangeSource) {
        switch device.config.family {
        case .button: press(device, 0)
        case .thermostat, .valueSensor: logger.error("\(device.name) cannot be triggered")
        default: setPrimary(device, device.triggeredPrimary, source: source)
        }
    }

    /// Back to the default state. An auto-reset or a limiter does nothing to an accessory at rest; conditions no
    /// longer met reset it even then (spec 7.6).
    func reset(_ device: DummyDevice, source: ChangeSource) {
        switch device.config.family {
        case .button, .thermostat, .valueSensor: return
        default: break
        }
        if source != .conditionReset, !device.isTriggered { return }
        setPrimary(device, device.defaultPrimary, source: source)
    }

    /// A button press (spec 7.12).
    func press(_ device: DummyDevice, _ value: Int) {
        let words = ["single", "double", "long"]
        info(device, "\(device.name) was \(words[min(max(value, 0), 2)]) pressed")
        notify(device, trigger: true)
        notify(device, trigger: false)
        if device.config.schedule?.isTimeout == true { startTimeout(device, .schedule) }
        device.services.primary[.programmableSwitchEvent]?.sendEvent(.int(value))
    }

    // MARK: What HomeKit shows

    func publish(_ device: DummyDevice) {
        let service = device.services.primary
        switch device.config.family {
        case .onOff:
            service[.on]?.value = .bool(device.primary == 1)
            if device.config.isDimmer { service[.brightness]?.value = .int(device.fadeValue ?? device.brightness) }
        case .lock:
            service[.lockTargetState]?.value = .int(device.primary)
            service[.lockCurrentState]?.value = .int(device.primary)
        case .position:
            service[.targetPosition]?.value = .int(device.primary)
            if device.simulationTimer == nil { device.current = device.primary }
            service[.currentPosition]?.value = .int(device.current)
            service[.positionState]?.value = .int(2)
        case .garage:
            service[.targetDoorState]?.value = .int(device.primary)
            if device.simulationTimer == nil { device.current = device.primary }
            service[.currentDoorState]?.value = .int(device.current)
            service[.obstructionDetected]?.value = .bool(false)
        case .valve:
            service[.active]?.value = .int(device.primary)
            service[.inUse]?.value = .int(device.primary)
            service[.valveType]?.value = .int(device.config.valveType)
            service[.isConfigured]?.value = .int(1)
            if let duration = device.setDuration { service[.setDuration]?.value = .int(duration) }
            service[.remainingDuration]?.value = .int(remainingDuration(device))
        case .humidifier:
            service[.active]?.value = .int(device.primary)
            let target = device.config.dehumidifier ? 2 : 1
            service[.targetHumidifierDehumidifierState]?.value = .int(target)
            service[.currentHumidifierDehumidifierState]?.value = .int(device.primary == 0 ? 0 : (device.config.dehumidifier ? 3 : 2))
            service[device.config.dehumidifier ? .relativeHumidityDehumidifierThreshold : .relativeHumidityHumidifierThreshold]?.value = .double(device.targetHumidity)
            service[.currentRelativeHumidity]?.value = .double(device.currentHumidityExplicit ? device.currentHumidity : device.targetHumidity)
        case .thermostat:
            service[.temperatureDisplayUnits]?.value = .int(device.config.fahrenheit ? 1 : 0)
            service[.targetHeatingCoolingState]?.value = .int(device.targetMode)
            service[.currentHeatingCoolingState]?.value = .int(device.currentMode)
            service[.targetTemperature]?.value = .double(device.targetTemperature)
            service[.currentTemperature]?.value = .double(device.currentTemperature)
        case .valueSensor:
            service[device.config.type == .temperatureSensor ? .currentTemperature : .currentRelativeHumidity]?.value = .double(device.value)
        case .binarySensor:
            if let type = device.config.type.sensorCharacteristic {
                service[type]?.value = device.config.type == .motionSensor ? .bool(device.primary == 1) : .int(device.primary)
            }
        case .button:
            break
        }
    }

    // MARK: HomeKit's writes

    enum Write: Sendable {
        case on(Bool), brightness(Int), lock(Int), targetPosition(Int), targetDoor(Int), active(Int), threshold(Double)
        case targetMode(Int), targetTemperature(Double), setDuration(Int), resetTotal(Int)
    }

    /// Applies a write from HomeKit; answers the value the characteristic should show when it is not the one written
    /// (a position of 40 is 100: positions are binary).
    func write(_ identifier: String, _ write: Write) -> HAPValue? {
        guard let device = devices[identifier] else { return nil }
        switch write {
        case .on(let on): setPrimary(device, on ? 1 : 0, source: .homeKit)
        case .brightness(let value): setBrightness(device, value, source: .homeKit)
        case .lock(let value): setPrimary(device, value == 0 ? 0 : 1, source: .homeKit)
        case .targetPosition(let value):
            let position = value == 0 ? 0 : 100
            setPrimary(device, position, source: .homeKit)
            return position == value ? nil : .int(position)
        case .targetDoor(let value): setPrimary(device, value == 0 ? 0 : 1, source: .homeKit)
        case .active(let value): setPrimary(device, value == 0 ? 0 : 1, source: .homeKit)
        case .threshold(let value): setTargetHumidity(device, value, source: .homeKit)
        case .targetMode(let mode): setTargetMode(device, mode, source: .homeKit)
        case .targetTemperature(let celsius): setTargetTemperature(device, celsius, source: .homeKit)
        case .setDuration(let seconds):
            device.setDuration = seconds
            device.autoResetOverride = Double(seconds) * 1000
            setStored(identifier, "SetDuration", .number(Double(seconds)))
        case .resetTotal(let value):
            setStored(identifier, "TimesOpened", .number(0))
            setStored(identifier, "ResetTotal", .number(Double(value)))
            device.services.primary[EveCharacteristic.timesOpened]?.value = .int(0)
            device.services.sensor?[EveCharacteristic.timesOpened]?.value = .int(0)
            info(device, "\(device.name) open count has been reset")
        }
        return nil
    }

    func remainingDuration(_ identifier: String) -> Int {
        devices[identifier].map(remainingDuration) ?? 0
    }

    func remainingDuration(_ device: DummyDevice) -> Int {
        guard let expiry = device.expiries[.autoReset] else { return 0 }
        return max(0, Int(saturating: ((expiry - nowMilliseconds) / 1000).rounded()) ?? 0)
    }

    // MARK: Brightness and fades (spec 4.1, 7.4)

    func setBrightness(_ device: DummyDevice, _ value: Int, source: ChangeSource) {
        let value = min(max(value, 0), 100)
        let fading = device.fadeTimer != nil
        guard value != device.brightness || fading else { return }
        let changed = value != device.brightness
        device.brightness = value
        if changed {
            setStored(device.identifier, "Brightness", .number(Double(value)))
            info(device, "\(device.name) brightness is \(value)%")
        }
        if fading, device.isTriggered {
            if device.config.autoReset?.isTimeout == true { startTimeout(device, .autoReset) }
            startLimiter(device)
            startFade(device)
        }
        publish(device)
    }

    func startFade(_ device: DummyDevice) {
        guard let fade = device.config.fade else { return }
        device.fadeTimer?.cancel()
        device.fadeTimer = nil
        let start = device.brightness
        let total = fade.kind == .fixed ? fade.milliseconds : fade.milliseconds * Double(start)
        logger.info("\(device.name) fading out over \(TimeUnits.describe(milliseconds: total))")
        guard start > 0 else {
            device.fadeValue = nil
            setPrimary(device, device.defaultPrimary, source: .fade)
            return
        }
        device.fadeValue = start
        scheduleFadeStep(device, every: total / Double(start))
    }

    private func scheduleFadeStep(_ device: DummyDevice, every step: Double) {
        let id = device.identifier
        device.fadeTimer = scheduler.after(milliseconds: step) { [weak self] in await self?.fadeStep(id, every: step) }
    }

    func fadeStep(_ identifier: String, every step: Double) {
        guard let device = devices[identifier], let value = device.fadeValue, !stopped else { return }
        let next = value - 1
        if next <= 0 {
            device.fadeTimer = nil
            device.fadeValue = nil
            setPrimary(device, device.defaultPrimary, source: .fade)
            publish(device)
            return
        }
        device.fadeValue = next
        device.services.primary[.brightness]?.value = .int(next)
        scheduleFadeStep(device, every: step)
    }

    func cancelFade(_ device: DummyDevice) {
        device.fadeTimer?.cancel()
        device.fadeTimer = nil
        device.fadeValue = nil
    }

    // MARK: Timers (spec 7.2, 7.3)

    func duration(_ milliseconds: Double, random: Bool) -> Double {
        random ? (max(1, dependencies.random() * milliseconds)).rounded(.down) : milliseconds
    }

    /// Starts (again) a schedule's or an auto-reset's timeout; after a restart, its stored expiry is resumed once.
    func startTimeout(_ device: DummyDevice, _ slot: TimerSlot) {
        let config = slot == .schedule ? device.config.schedule : device.config.autoReset
        guard case .timeout(let configured, let random) = config?.kind else { return }
        device.timeouts[slot]?.cancel()
        let id = device.identifier
        var delay: Double
        let key = slot.storedKey
        var resumed: Double?
        if device.resumable.remove(key) != nil { resumed = stored(id, key)?.doubleValue }
        if resumed == nil, device.resumable.remove("Timer") != nil {
            resumed = stored(id, "Timer")?.doubleValue
            setStored(id, "Timer", nil)
        }
        if let expiry = resumed {
            let remaining = expiry - nowMilliseconds
            if remaining > 0 {
                info(device, "\(device.name) is resuming its \(slot.label) timer")
                delay = remaining
            } else {
                info(device, "\(device.name) \(slot.label) timer expired while restarting")
                delay = 100
            }
        } else {
            let base = slot == .autoReset ? (device.autoResetOverride ?? configured) : configured
            delay = duration(base, random: random)
            info(device, "\(device.name) will \(slot.verb) in \(TimeUnits.describe(milliseconds: delay))")
        }
        let expiry = nowMilliseconds + delay
        device.expiries[slot] = expiry
        setStored(id, key, .number(expiry))
        device.timeouts[slot] = scheduler.after(milliseconds: delay) { [weak self] in await self?.timeoutFired(id, slot) }
        if slot == .autoReset, device.config.family == .valve { publish(device) }
    }

    func cancelTimeout(_ device: DummyDevice, _ slot: TimerSlot, log: Bool) {
        guard let timer = device.timeouts.removeValue(forKey: slot) else { return }
        timer.cancel()
        device.expiries[slot] = nil
        setStored(device.identifier, slot.storedKey, nil)
        if log { info(device, "\(device.name) cancelled \(slot.label) timer") }
    }

    func timeoutFired(_ identifier: String, _ slot: TimerSlot) {
        guard let device = devices[identifier], !stopped else { return }
        device.timeouts[slot] = nil
        device.expiries[slot] = nil
        setStored(identifier, slot.storedKey, nil)
        if slot == .schedule { trigger(device, source: .schedule) } else { reset(device, source: .autoReset) }
    }

    /// Intervals, cron jobs and sun events start with the accessory and run whatever its state (spec 7.3).
    func startRepeatingSchedules(_ device: DummyDevice) {
        if let schedule = device.config.schedule, !schedule.isTimeout { armRepeating(device, .schedule, schedule, first: true) }
        if let autoReset = device.config.autoReset, !autoReset.isTimeout { armRepeating(device, .autoReset, autoReset, first: true) }
    }

    func armRepeating(_ device: DummyDevice, _ slot: TimerSlot, _ schedule: ScheduleConfig, first: Bool) {
        let id = device.identifier
        let now = scheduler.now
        var delay: Double
        switch schedule.kind {
        case .timeout: return
        case .interval(let ms, let random):
            delay = duration(ms, random: random)
            info(device, "\(device.name) will \(slot.verb) in \(TimeUnits.describe(milliseconds: delay))")
        case .cron(let expression):
            if first { info(device, "\(device.name) starting \(slot.label) cronjob") }
            guard let next = expression.next(after: now, calendar: dependencies.calendar) else { return }
            delay = next.timeIntervalSince(now) * 1000
        case .sun(let event, let offset, let latitude, let longitude):
            guard let next = SunTimes.next(event, offsetMinutes: offset, latitude: latitude, longitude: longitude, after: now) else {
                logger.warning("\(device.name): the sun does not reach its \(event.rawValue.lowercased()) position here today; trying again tomorrow")
                device.repeating[slot] = scheduler.after(milliseconds: 86_400_000) { [weak self] in await self?.rearm(id, slot) }
                return
            }
            let formatter = DateFormatter()
            formatter.calendar = dependencies.calendar
            formatter.timeZone = dependencies.calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            info(device, "\(device.name) will \(slot.verb) at \(formatter.string(from: next))")
            delay = next.timeIntervalSince(now) * 1000
        }
        device.repeating[slot] = scheduler.after(milliseconds: max(delay, 0)) { [weak self] in await self?.repeatingFired(id, slot) }
    }

    func rearm(_ identifier: String, _ slot: TimerSlot) {
        guard let device = devices[identifier], !stopped, let schedule = slot == .schedule ? device.config.schedule : device.config.autoReset else { return }
        armRepeating(device, slot, schedule, first: false)
    }

    func repeatingFired(_ identifier: String, _ slot: TimerSlot) {
        guard let device = devices[identifier], !stopped else { return }
        if slot == .schedule { trigger(device, source: .schedule) } else { reset(device, source: .autoReset) }
        rearm(identifier, slot)
    }

    // MARK: Limiter (spec 7.8)

    func restoreLimiter(_ device: DummyDevice) {
        guard let limiter = device.config.limiter else { return }
        let id = DummyIdentity.limiterIdentifier(accessory: device.identifier, limiter: limiter)
        device.limiterID = id
        guard !limiter.resetOnRestart else { return }
        var record = LimiterRecord(stored(id, "Limiter"))
        if record == nil { record = LimiterRecord(stored(limiter.legacyID ?? device.name, "Limiter")) }
        if var restored = record, let start = restored.startTimestamp {
            restored.timeRemaining = max(0, restored.timeRemaining - (nowMilliseconds - start))
            restored.startTimestamp = nil
            record = restored
        }
        device.limiter = record
        if let record { setStored(id, "Limiter", record.json) }
    }

    /// The end of the period that `now` is in, in local time.
    func periodEnd(_ period: LimiterConfig.Period, after now: Date) -> Date {
        let calendar = dependencies.calendar
        switch period {
        case .hour:
            return calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(3600)
        case .day:
            return calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(86_400)
        case .week:
            let today = calendar.startOfDay(for: now)
            let weekday = calendar.component(.weekday, from: today)
            let days = weekday == 1 ? 7 : 8 - weekday
            return calendar.date(byAdding: .day, value: days, to: today) ?? now.addingTimeInterval(7 * 86_400)
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.end ?? now.addingTimeInterval(31 * 86_400)
        }
    }

    func startLimiter(_ device: DummyDevice) {
        guard let limiter = device.config.limiter, let id = device.limiterID else { return }
        let now = nowMilliseconds
        var record: LimiterRecord
        if let existing = device.limiter, now < existing.resetTimestamp {
            record = existing
        } else {
            let end = periodEnd(limiter.period, after: scheduler.now).timeIntervalSince1970 * 1000
            var allowance = limiter.limitMilliseconds
            let left = end - now
            if allowance > left { allowance = limiter.limitMilliseconds + left }
            record = LimiterRecord(timeRemaining: allowance, resetTimestamp: end)
        }
        // Already running: the time it ran so far still counts.
        let used = record.startTimestamp.map { now - $0 } ?? 0
        if record.startTimestamp == nil, record.timeRemaining > 0 {
            info(device, "\(device.name) \(Self.remaining(record.timeRemaining))")
            record.startTimestamp = now
        }
        device.limiter = record
        setStored(id, "Limiter", record.json)
        device.limiterTimer?.cancel()
        let identifier = device.identifier
        device.limiterTimer = scheduler.after(milliseconds: max(record.timeRemaining - used, 100)) { [weak self] in
            await self?.limiterExpired(identifier)
        }
    }

    func pauseLimiter(_ device: DummyDevice) {
        device.limiterTimer?.cancel()
        device.limiterTimer = nil
        guard var record = device.limiter, let start = record.startTimestamp, let id = device.limiterID else { return }
        record.timeRemaining = max(0, record.timeRemaining - (nowMilliseconds - start))
        record.startTimestamp = nil
        device.limiter = record
        setStored(id, "Limiter", record.json)
        info(device, "\(device.name) \(Self.remaining(record.timeRemaining))")
    }

    func limiterExpired(_ identifier: String) {
        guard let device = devices[identifier], !stopped, let id = device.limiterID else { return }
        device.limiterTimer = nil
        if var record = device.limiter {
            record.timeRemaining = 0
            record.startTimestamp = nil
            device.limiter = record
            setStored(id, "Limiter", record.json)
        }
        info(device, "\(device.name) time limit has expired")
        reset(device, source: .limiter)
    }

    static func remaining(_ milliseconds: Double) -> String {
        func rounded(_ value: Double, _ unit: String) -> String {
            let count = Int(saturating: value.rounded()) ?? 0
            return "has \(count) \(unit)\(count == 1 ? "" : "s") remaining"
        }
        if milliseconds <= 0 { return "time limit has expired" }
        if milliseconds < 60_000 { return rounded(milliseconds / 1000, "second") }
        if milliseconds < 3_600_000 { return rounded(milliseconds / 60_000, "minute") }
        if milliseconds < 86_400_000 { return rounded(milliseconds / 3_600_000, "hour") }
        return "has more than a day remaining"
    }

    // MARK: Simulation (spec 7.7)

    func simulate(_ device: DummyDevice, from old: Int) {
        guard let simulation = device.config.simulation else { return }
        device.simulationTimer?.cancel()
        device.simulationTimer = nil
        let id = device.identifier
        let service = device.services.primary
        if device.config.family == .garage {
            device.current = device.primary == 1 ? 3 : 2
            service[.currentDoorState]?.value = .int(device.current)
            device.simulationTimer = scheduler.after(milliseconds: simulation.milliseconds) { [weak self] in await self?.simulationEnded(id) }
        } else {
            device.current = old
            service[.currentPosition]?.value = .int(old)
            device.simulationTimer = scheduler.after(milliseconds: simulation.milliseconds / 100) { [weak self] in await self?.simulationStep(id) }
        }
    }

    func simulationStep(_ identifier: String) {
        guard let device = devices[identifier], let simulation = device.config.simulation, !stopped else { return }
        device.current += device.primary > device.current ? 1 : -1
        device.services.primary[.currentPosition]?.value = .int(device.current)
        if device.current == device.primary {
            device.simulationTimer = nil
        } else {
            device.simulationTimer = scheduler.after(milliseconds: simulation.milliseconds / 100) { [weak self] in await self?.simulationStep(identifier) }
        }
    }

    func simulationEnded(_ identifier: String) {
        guard let device = devices[identifier], !stopped else { return }
        device.simulationTimer = nil
        device.current = device.primary
        device.services.primary[.currentDoorState]?.value = .int(device.current)
    }

    // MARK: Valve durations (spec 7.9)

    func setUpValve(_ device: DummyDevice) {
        guard device.config.type == .valve, let ms = device.config.autoReset?.timeoutMilliseconds else { return }
        if let stored = stored(device.identifier, "SetDuration")?.intValue {
            device.setDuration = stored
            return
        }
        var seconds = Int(saturating: (ms / 1000).rounded()) ?? 1
        if seconds < 1 {
            logger.warning("\(device.name) has an auto-reset shorter than 1 second; Set Duration shows 1 second")
            seconds = 1
        } else if seconds > 3600 {
            logger.warning("\(device.name) has an auto-reset longer than 3600 seconds; Set Duration shows 3600 seconds")
            seconds = 3600
        }
        device.setDuration = seconds
        setStored(device.identifier, "SetDuration", .number(Double(seconds)))
    }

    // MARK: Attached sensors (spec 7.5)

    func updateSensor(_ device: DummyDevice, source: ChangeSource, changed: Bool) {
        guard let sensor = device.config.sensor else { return }
        switch device.config.family {
        case .onOff, .lock, .position, .garage: break
        default: return
        }
        switch sensor.behavior {
        case .mirror:
            setSensor(device, device.isTriggered)
        case .timer:
            if device.isTriggered {
                device.sensorPulse?.cancel()
                device.sensorPulse = nil
                setSensor(device, false)
            } else if source.isReset, changed {
                setSensor(device, true)
                let id = device.identifier
                device.sensorPulse = scheduler.after(milliseconds: 1000) { [weak self] in await self?.sensorPulseEnded(id) }
            }
        }
    }

    func sensorPulseEnded(_ identifier: String) {
        guard let device = devices[identifier] else { return }
        device.sensorPulse = nil
        setSensor(device, false)
    }

    func setSensor(_ device: DummyDevice, _ active: Bool) {
        guard let sensor = device.config.sensor, let service = device.services.sensor, device.sensorActive != active else { return }
        device.sensorActive = active
        if let type = sensor.type.sensorCharacteristic {
            service[type]?.value = sensor.type == .motionSensor ? .bool(active) : .int(active ? 1 : 0)
        }
        let words = sensor.type.sensorWords
        info(device, "\(device.name) \(active ? words.on : words.off)")
        if device.config.enableHistory, sensor.type == .contactSensor || sensor.type == .motionSensor {
            addHistory(device, EveHistory.Entry(time: scheduler.now, status: active ? 1 : 0))
            if sensor.type == .contactSensor, active { countOpening(device) }
        }
    }

    // MARK: Eve history (spec 10)

    func recordHistory(_ device: DummyDevice) {
        guard device.config.enableHistory, device.services.history != nil else { return }
        let now = scheduler.now
        switch device.config.family {
        case .onOff:
            addHistory(device, EveHistory.Entry(time: now, status: Double(device.primary)))
        case .binarySensor where device.config.type == .contactSensor || device.config.type == .motionSensor:
            addHistory(device, EveHistory.Entry(time: now, status: Double(device.primary)))
            if device.config.type == .contactSensor, device.primary == 1 { countOpening(device) }
        default: break
        }
    }

    func addHistory(_ device: DummyDevice, _ entry: EveHistory.Entry) {
        guard let history = device.services.history else { return }
        history.add(entry)
        if verbose { debug("\(device.name) history entry at \(entry.time)") }
        switch history.kind {
        case .weather: return
        default: break
        }
        if let initial = history.initialTime {
            let value = max(0, entry.time - initial)
            setStored(device.identifier, "LastActivation", .number(Double(value)))
            device.services.primary[EveCharacteristic.lastActivation]?.value = .int(value)
        }
    }

    func countOpening(_ device: DummyDevice) {
        guard device.config.enableHistory else { return }
        let count = (stored(device.identifier, "TimesOpened")?.intValue ?? 0) + 1
        setStored(device.identifier, "TimesOpened", .number(Double(count)))
        device.services.primary[EveCharacteristic.timesOpened]?.value = .int(count)
        device.services.sensor?[EveCharacteristic.timesOpened]?.value = .int(count)
    }

    // MARK: Notifications (spec 11)

    func notify(_ device: DummyDevice, trigger: Bool) {
        guard let notification = device.config.notification, let notifier = dependencies.notifier else { return }
        guard let text = trigger ? notification.text : notification.resetText else { return }
        let title = trigger ? notification.title : notification.resetTitle
        let name = device.name
        let quiet = device.config.disableLogging
        let logger = logger
        tasks.add {
            do {
                if let problem = try await notifier.send(notification, title: title, text: text) {
                    logger.warning("\(name) is unable to send push notification – \(problem)")
                } else if !quiet {
                    logger.info("\(name) sent a push notification")
                }
            } catch {
                logger.error("\(name) could not send a push notification: \(error)")
            }
        }
    }
}
