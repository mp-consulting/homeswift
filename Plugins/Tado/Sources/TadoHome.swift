import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// One tado home: its accessories, its poll and its writes (docs/clean-room/Tado.md, section 7).
///
/// Accessories are matched to zones by the zone's name exactly and to tado's zones by id, never by part of a name (the
/// Homebridge plugin matched by substring, so zone `Bath` also updated `Bathroom`). Writes take the zone's setting from
/// the last poll instead of asking tado for it first, and are not followed by a poll: each request counts against the
/// account's day.
actor TadoHome {
    struct Options: Sendable {
        var preferSiriTemperature = false
        var firmware = PluginHost.version
        /// The account's daily limit, shared by its homes.
        var dailyLimit = TadoBudget.defaultDailyLimit
        /// The 400 ms of the write buffer and the 500 ms of switches that turn themselves off; tests shorten them.
        var writeDelay: Duration = .milliseconds(400)
        var resetDelay: Duration = .milliseconds(500)
        /// Seconds, as a Duration: the delay switch's timer (tests shorten it).
        var delayUnit: Duration = .seconds(1)
    }

    let settings: HomeSettings
    let api: TadoAPI
    let context: PluginContext
    let options: Options
    let telegram: TelegramSender?
    private var logger: Logger { context.logger }
    private let tasks = TaskBag()
    private let writes: LatestCallGuard
    private let now: @Sendable () -> Date

    private(set) var homeID: Int?
    private(set) var unit: TemperatureUnit
    /// tado's zone ids by zone name.
    private var zoneIDs: [String: Int] = [:]
    /// Each active zone's services, by zone name.
    private(set) var zones: [String: ZoneServices] = [:]
    private var states: [Int: ZoneState] = [:]
    /// AIR_CONDITIONING zones' capabilities by zone id, kept for the process.
    private var capabilities: [Int: JSONValue] = [:]
    private var acModes: [String: String] = [:]
    private var acFanLevels: [String: String] = [:]
    private var openWindowEnabled: [Int: Bool] = [:]
    private var lastZoneList: Date?
    private var lastRunningTime: Date?
    private var writesInProgress = 0
    private(set) var accessoryIDs: Set<String> = []

    // The write buffer (section 7.2), by zone name.
    private struct Pending { var state: Int?; var temperature: Double?; var mode: Int? }
    private var pending: [String: Pending] = [:]
    private var lastTemperature: [String: Double] = [:]
    private var delayTasks: [String: Task<Void, Never>] = [:]

    // The home's other services.
    private var presence: [String: Service] = [:]
    private var anyone: Service?
    private var weather: Service?
    private var solar: Service?
    private var solarLast: (on: Bool, brightness: Int) = (false, 0)
    private var central: [String: Service] = [:]
    private var presenceLockService: Service?
    private var homeSwitch: Service?, awaySwitch: Service?
    private var childLocks: [String: Service] = [:]
    /// Values seen since start, for the changes Telegram hears of (not the first poll's).
    private var seen: Set<String> = []
    /// When each Eve accessory's counting started, by accessory id (Unix seconds).
    private let eveReference: PersistedDictionary<Int>
    private var failures = 0

    init(settings: HomeSettings, api: TadoAPI, context: PluginContext, options: Options, telegram: TelegramSender?, now: @escaping @Sendable () -> Date = Date.init) {
        self.settings = settings
        self.api = api
        self.context = context
        self.options = options
        self.telegram = telegram
        self.now = now
        writes = LatestCallGuard(delay: options.writeDelay)
        homeID = settings.id
        unit = settings.temperatureUnit ?? .celsius
        for zone in settings.zones { if let id = zone.id { zoneIDs[zone.name] = id } }
        eveReference = PersistedDictionary(url: context.storageDirectory.appendingPathComponent("tado-eve.json"))
    }

    // MARK: Accessories

    /// Adds the home's accessories (section 6.1), each with the values the cache kept.
    func addAccessories() {
        for warning in settings.warnings { logger.warning("\(warning): skipped") }
        var added: [Accessory] = []
        var names = Set<String>()
        func add(_ accessory: Accessory) {
            guard names.insert(accessory.name).inserted else {
                logger.warning("There is already an accessory named \(accessory.name): the second one is skipped")
                return
            }
            if let cached = context.accessory(id: accessory.id) { accessory.takeValues(from: cached) }
            added.append(accessory)
        }
        let firmware = options.firmware
        var windowSwitches: [Service] = []
        for zone in settings.activeZones {
            if zone.id == nil { logger.warning("Zone \(zone.name) has no id: it is looked up by its name") }
            var (services, accessories) = TadoAccessories.zone(zone, home: settings.name, unit: unit, firmware: firmware)
            if zone.openWindowSwitch {
                let service = Service(.switch, name: "\(zone.name) Window", subtype: "\(zone.name) Window")
                services.windowSwitch = service
                windowSwitches.append(service)
            }
            guard !context.isExcluded(services.deviceID) else { continue }
            accessories.forEach(add)
            zones[zone.name] = services
            bindZone(services)
        }
        let home = settings.name
        if !windowSwitches.isEmpty {
            add(TadoAccessories.accessory("\(home) Open Window", model: "zone-window-switch", category: .switch, firmware: firmware, services: windowSwitches))
            for (name, services) in zones {
                services.windowSwitch?.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
                    try await self?.setOpenWindow(zone: name, value.boolValue ?? false)
                }
            }
        }
        for user in settings.users {
            let name = "\(home) \(user.name)"
            let service = user.motion
                ? Service(.motionSensor, name: name, subtype: "presence-motion", extra: [Characteristic(.eveLastActivation, value: .int(0))], isPrimary: true)
                : Service(.occupancySensor, name: name, subtype: "presence-occupancy", isPrimary: true)
            presence[user.name] = service
            add(TadoAccessories.accessory(name, model: user.motion ? "presence-motion" : "presence-occupancy", category: .sensor, firmware: firmware, services: [service]))
        }
        if settings.anyone, !presence.isEmpty {
            let name = "\(home) Anyone"
            let service = settings.anyoneMotion
                ? Service(.motionSensor, name: name, subtype: "presence-motion", extra: [Characteristic(.eveLastActivation, value: .int(0))], isPrimary: true)
                : Service(.occupancySensor, name: name, subtype: "presence-occupancy", isPrimary: true)
            anyone = service
            add(TadoAccessories.accessory(name, model: settings.anyoneMotion ? "presence-motion" : "presence-occupancy", category: .sensor, firmware: firmware, services: [service]))
        }
        if settings.weatherTemperature {
            let service = Service(.temperatureSensor, name: "\(home) Weather", subtype: "weather-temperature",
                                  optional: [.currentTemperature.with(minValue: -100, maxValue: 100)], isPrimary: true)
            service.characteristic(.currentTemperature).value = .double(0)
            weather = service
            add(TadoAccessories.accessory("\(home) Weather", model: "Weather Temperature", category: .sensor, firmware: firmware, services: [service]))
        }
        if settings.solarIntensity {
            let name = "\(home) Solar Intensity"
            let service = settings.solarAsSensor
                ? Service(.lightSensor, name: name, subtype: "weather-lightsensor", isPrimary: true)
                : Service(.lightbulb, name: name, subtype: "weather-lightbulb", optional: [.brightness], isPrimary: true)
            solar = service
            if !settings.solarAsSensor {
                // Read only in effect: a write is put back to the last reading.
                for type in [CharacteristicType.on, .brightness] {
                    service.characteristic(type).onWrite { [weak self] _ in await self?.revertSolar() }
                }
            }
            add(TadoAccessories.accessory(name, model: "Solar Intensity", category: settings.solarAsSensor ? .sensor : .lightbulb, firmware: firmware, services: [service]))
        }
        if settings.centralSwitch, !centralZones.isEmpty {
            var services: [Service] = []
            let main = Service(.switch, name: "Central", subtype: "Central", extra: [
                Characteristic(.tadoModeAuto, value: .int(0)), Characteristic(.tadoModeManual, value: .int(0)), Characteristic(.tadoModeOff, value: .int(0)),
            ] + (settings.runningInformation ? [
                Characteristic(.tadoActivityDay, value: .double(0)), Characteristic(.tadoActivityMonth, value: .double(0)),
                Characteristic(.tadoActivityYear, value: .double(0)),
            ] : []), isPrimary: true)
            services.append(main)
            central["Central"] = main
            for (enabled, name, subtype) in [(settings.boostSwitch, "Boost", "CentralBoost"), (settings.sheduleSwitch, "Shedule", "CentralShedule"),
                                             (settings.turnoffSwitch, "Off", "CentralOff"), (settings.dummySwitch, "Dummy", "CentralDummy")] where enabled {
                let service = Service(.switch, name: name, subtype: subtype)
                services.append(service)
                central[name] = service
            }
            for (name, service) in central where name != "Dummy" {
                service.characteristic(.on).onWrite(changesOnly: false) { [weak self] value in
                    await self?.centralWrite(name, value.boolValue ?? false)
                }
            }
            add(TadoAccessories.accessory("\(home) Central Switch", model: "Central Switch", category: .switch, firmware: firmware, services: services))
        }
        if settings.presenceLock {
            let name = "\(home) Presence Lock"
            if settings.presenceLockAlarm {
                let service = Service(.securitySystem, name: name, subtype: "extra-plock", optional: [
                    .securitySystemCurrentState.with(validValues: [0, 1, 3]), .securitySystemTargetState.with(validValues: [0, 1, 3]),
                    .securitySystemAlarmType, .statusFault, .statusTampered,
                ], isPrimary: true)
                service.characteristic(.securitySystemTargetState).onWrite(changesOnly: false) { [weak self] value in
                    try await self?.setPresenceLock(target: value.intValue ?? 0)
                }
                presenceLockService = service
                add(TadoAccessories.accessory(name, model: "Presence Lock", category: .securitySystem, firmware: firmware, services: [service]))
            } else {
                let home = Service(.switch, name: "Home", subtype: "HomeSwitch", isPrimary: true)
                let away = Service(.switch, name: "Away", subtype: "AwaySwitch")
                for (service, presence) in [(home, "HOME"), (away, "AWAY")] {
                    service.characteristic(.on).securityControl().onWrite(changesOnly: false) { [weak self] value in
                        try await self?.setPresenceSwitch(presence, on: value.boolValue ?? false)
                    }
                }
                homeSwitch = home
                awaySwitch = away
                add(TadoAccessories.accessory(name, model: "Presence Lock", category: .switch, firmware: firmware, services: [home, away]))
            }
        }
        if !settings.childLocks.isEmpty {
            var services: [Service] = []
            for lock in settings.childLocks {
                let service = Service(.switch, name: lock.name, subtype: lock.serialNumber, isPrimary: services.isEmpty)
                service.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
                    try await self?.setChildLock(lock.serialNumber, value.boolValue ?? false)
                }
                services.append(service)
                childLocks[lock.serialNumber] = service
            }
            add(TadoAccessories.accessory("\(home) Child Lock", model: "extra-childswitch", category: .switch, firmware: firmware, services: services))
        }
        for accessory in added {
            do {
                try context.add(accessory)
                accessoryIDs.insert(accessory.id)
            } catch {
                logger.error("Could not add \(accessory.name): \(error)")
            }
        }
    }

    /// The zones the central switch drives: the active HEATING zones with an id (the Homebridge plugin took the inactive
    /// ones too).
    private var centralZones: [ZoneSettings] { settings.activeZones.filter { $0.type == .heating } }

    private func bindZone(_ services: ZoneServices) {
        let name = services.zone.name
        let primary = services.primary
        switch services.kind {
        case .thermostat:
            primary.characteristic(.targetHeatingCoolingState).onWrite(changesOnly: false) { [weak self] value in
                await self?.buffer(name, state: value.intValue ?? 0)
            }
            primary.characteristic(.targetTemperature).onWrite(changesOnly: false) { [weak self] value in
                await self?.buffer(name, temperature: value.doubleValue)
            }
            primary.characteristic(.temperatureDisplayUnits).onWrite { _ in }
        case .heaterCooler, .boiler, .airConditioner:
            primary.characteristic(.active).onWrite(changesOnly: false) { [weak self] value in
                await self?.buffer(name, state: value.intValue ?? 0)
            }
            primary.characteristic(.heatingThresholdTemperature).onWrite(changesOnly: false) { [weak self] value in
                await self?.buffer(name, temperature: value.doubleValue, threshold: 1)
            }
            if services.kind == .airConditioner {
                primary[.coolingThresholdTemperature]?.onWrite(changesOnly: false) { [weak self] value in
                    await self?.buffer(name, temperature: value.doubleValue, threshold: 2)
                }
                // A change of mode alone is sent too (the Homebridge plugin waited for the next Active or threshold write).
                primary.characteristic(.targetHeaterCoolerState).onWrite(changesOnly: true) { [weak self] value in
                    await self?.buffer(name, mode: value.intValue ?? 2)
                }
                primary[.rotationSpeed]?.onWrite(changesOnly: true) { [weak self] value in
                    await self?.setFanSpeed(zone: name, percent: value.doubleValue ?? 0)
                }
                for (service, mode) in [(services.fanSwitch, "FAN"), (services.drySwitch, "DRY")] {
                    service?.characteristic(.on).onWrite(changesOnly: false) { [weak self] value in
                        await self?.setACModeSwitch(zone: name, mode: mode, on: value.boolValue ?? false)
                    }
                }
            } else if services.kind == .heaterCooler {
                primary[.coolingThresholdTemperature]?.onWrite(changesOnly: false) { [weak self] value in
                    await self?.buffer(name, temperature: value.doubleValue, threshold: 1)
                }
            }
        case .switch:
            primary.characteristic(.on).onWrite(changesOnly: true) { [weak self] value in
                await self?.setHotWater(zone: name, on: value.boolValue ?? false)
            }
        case .faucet:
            primary.characteristic(.active).onWrite(changesOnly: true) { [weak self] value in
                let on = (value.intValue ?? 0) == 1
                primary.characteristic(.inUse).value = .int(on ? 1 : 0)
                await self?.setHotWater(zone: name, on: on)
            }
        }
        if let delay = primary[.tadoDelay] {
            delay.onWrite(changesOnly: true) { [weak self] value in
                await self?.delaySwitchChanged(zone: name, on: value.boolValue ?? false)
            }
            primary[.tadoDelayTimer]?.onWrite { _ in }
        }
        if let window = services.window {
            window[.eveResetTotal]?.onWrite { [weak self] _ in
                let since2001 = Int(Date().timeIntervalSinceReferenceDate)
                window[.eveResetTotal]?.value = .int(since2001)
                window[.eveTimesOpened]?.value = .int(0)
                _ = self
            }
        }
    }

    // MARK: Polling (sections 7.1, 7.6, 7.7)

    /// The requests a poll makes, and those made every 6 hours, a day: what the default interval is fitted to.
    var requestsPerPoll: Int {
        (settings.activeZones.isEmpty ? 0 : 1) + (settings.users.isEmpty ? 0 : 1) + (settings.weatherTemperature || settings.solarIntensity ? 1 : 0)
            + (settings.presenceLock ? 1 : 0) + (settings.childLocks.isEmpty ? 0 : 1)
    }

    var slowRequestsPerDay: Int {
        let perDay = Int(86400 / TadoBudget.slowInterval)
        return (settings.activeZones.isEmpty ? 0 : perDay) + (settings.centralSwitch && settings.runningInformation && !settings.hasCustomAPI ? 3 * perDay : 0)
    }

    /// Seconds between polls: the block's `polling`, else what fits a share of the account's day (`homesOnAccount`).
    func pollingInterval(homesOnAccount: Int) -> Int {
        if let polling = settings.polling { return polling }
        return TadoBudget.interval(requestsPerPoll: requestsPerPoll, slowRequestsPerDay: slowRequestsPerDay,
                                   dailyLimit: max(options.dailyLimit / max(homesOnAccount, 1), 1))
    }

    /// Polls until stopped, the first at once; each next one an interval after the last ended.
    func startPolling(homesOnAccount: Int, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        let interval = pollingInterval(homesOnAccount: homesOnAccount)
        let share = max(options.dailyLimit / max(homesOnAccount, 1), 1)
        let perDay = TadoBudget.requestsPerDay(requestsPerPoll: requestsPerPoll, slowRequestsPerDay: slowRequestsPerDay, interval: interval)
        if settings.polling != nil, perDay > TadoBudget.pollingBudget(dailyLimit: share, slowRequestsPerDay: 0) {
            logger.warning("Home \(settings.name) polls every \(interval) s: about \(perDay) tado° requests a day, more than the \(share) its account may make (dailyRequestLimit). Leave polling out to fit the day")
        } else {
            logger.info("Home \(settings.name) polls tado° every \(interval) s (\(perDay) requests a day of \(share))")
        }
        let backoff = Backoff(initial: .seconds(interval), factor: 2, maximum: .seconds(max(interval, 3600)))
        tasks.add { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let failed = await self.poll()
                let seconds = await self.nextInterval(base: interval)
                let delay = failed > 0 ? max(backoff.delay(attempt: failed - 1, random: 0.5), .seconds(seconds)) : .seconds(seconds)
                try? await sleep(delay)
            }
        }
    }

    /// The night's interval between 00:00 and 05:59, ±10 % with `addJitter`.
    private func nextInterval(base: Int) -> Int {
        var seconds = Double(base)
        if let night = settings.nightPolling, Calendar.current.component(.hour, from: now()) < 6 { seconds = Double(max(night, base, 30)) }
        if settings.addJitter { seconds *= Double.random(in: 0.9...1.1) }
        return Int(seconds.rounded())
    }

    func stop() {
        tasks.cancelAll()
        delayTasks.values.forEach { $0.cancel() }
        delayTasks.removeAll()
        try? eveReference.flush()
    }

    /// One poll; answers the consecutive failures so far (0 when it worked).
    @discardableResult
    func poll() async -> Int {
        do {
            let home = try await resolveHome()
            if !settings.activeZones.isEmpty { try await pollZones(home) }
            if !settings.users.isEmpty { try await pollPresence(home) }
            if settings.weatherTemperature || settings.solarIntensity { try await pollWeather(home) }
            if settings.centralSwitch, settings.runningInformation, !settings.hasCustomAPI, isDue(lastRunningTime) { try await pollRunningTime(home) }
            if settings.presenceLock { try await pollPresenceLock(home) }
            if !settings.childLocks.isEmpty { try await pollChildLocks(home) }
            if failures > 0 { logger.info("tado° answers home \(settings.name) again") }
            failures = 0
        } catch is CancellationError {
        } catch {
            if failures == 0 { logger.error("Could not update home \(settings.name): \(error)") } else { logger.debug("Still cannot update home \(settings.name): \(error)") }
            failures += 1
        }
        return failures
    }

    private func isDue(_ last: Date?) -> Bool { last.map { now().timeIntervalSince($0) >= TadoBudget.slowInterval } ?? true }

    /// The home's id (the account's first home, named as the block's, when the block has none) and its unit.
    private func resolveHome() async throws -> Int {
        if homeID == nil {
            let me = try await api.me()
            guard let first = me["homes"]?[0], let id = first["id"]?.saturatingIntValue, first["name"]?.stringValue == settings.name else {
                throw TadoError.noHome("The tado° account has no home named \(settings.name): set the home's id")
            }
            homeID = id
        }
        guard let homeID else { throw TadoError.noHome("No home id") }
        if settings.temperatureUnit == nil, !resolvedUnit {
            resolvedUnit = true
            if let unit = try await api.home(homeID)["temperatureUnit"]?.stringValue.flatMap(TemperatureUnit.init(rawValue:)) { self.unit = unit }
        }
        return homeID
    }
    private var resolvedUnit = false

    private func pollZones(_ home: Int) async throws {
        let missingID = settings.activeZones.contains { zoneIDs[$0.name] == nil }
        if missingID || isDue(lastZoneList) {
            readZoneList(try await api.zones(home))
            lastZoneList = now()
        }
        let states = ZoneState.all(try await api.zoneStates(home))
        for zone in settings.activeZones where zoneIDs[zone.name] != nil && states[zoneIDs[zone.name]!] == nil {
            logger.warning("tado° gave no state for zone \(zone.name)")
        }
        guard writesInProgress == 0 else { return }
        self.states = states
        for services in zones.values {
            guard let id = zoneIDs[services.zone.name], let state = states[id] else { continue }
            show(state, on: services, zoneID: id)
        }
        showCentralCounters()
    }

    /// `zones`: ids by name and type, batteries and open-window detection.
    private func readZoneList(_ list: JSONValue) {
        for item in list.arrayValue ?? [] {
            guard let id = item["id"]?.saturatingIntValue, let name = item["name"]?.stringValue else { continue }
            guard let zone = settings.zones.first(where: { $0.name == name && $0.type.rawValue == item["type"]?.stringValue }) else { continue }
            zoneIDs[zone.name] = id
            openWindowEnabled[id] = item["openWindowDetection"]?["enabled"]?.boolValue ?? false
            guard let services = zones[zone.name], zone.hasBattery else { continue }
            let devices = item["devices"]?.arrayValue ?? []
            let battery = devices.first { ($0["batteryState"]?.stringValue).map { $0 != "NORMAL" } ?? false }?["batteryState"]?.stringValue
                ?? devices.first { ($0["duties"]?.arrayValue ?? []).contains("ZONE_LEADER") }?["batteryState"]?.stringValue
                ?? devices.first?["batteryState"]?.stringValue
            guard let battery else { continue }
            for service in services.batteries {
                service.characteristic(.batteryLevel).value = .int(battery == "NORMAL" ? 100 : 10)
                // The Homebridge plugin never said the battery was low.
                service.characteristic(.statusLowBattery).value = .int(battery == "NORMAL" ? 0 : 1)
            }
        }
    }

    /// Shows a zone's state (section 7.6).
    func show(_ state: ZoneState, on services: ZoneServices, zoneID: Int) {
        let primary = services.primary
        let limits = services.limits
        func clamp(_ value: Double) -> Double { min(max(value, limits.min), limits.max) }
        if let humidity = state.humidity {
            primary[.currentRelativeHumidity]?.value = .double(min(max(humidity, 0), 100))
            services.humidity?.characteristic(.currentRelativeHumidity).value = .double(min(max(humidity, 0), 100))
        }
        if let current = state.current { services.temperature?.characteristic(.currentTemperature).value = .double(min(max(current, -100), 100)) }
        if let window = services.window { setWindow(window, open: state.windowOpen, zone: services.zone.name) }
        if let open = openWindowEnabled[zoneID] { services.windowSwitch?.characteristic(.on).value = .bool(open) }

        switch services.kind {
        case .thermostat, .heaterCooler:
            guard state.settingType == ZoneType.heating.rawValue, let current = state.current else { return }
            let target = state.power ? state.target : nil
            let active = state.power
            let currentState = active && target.map { current < $0 } == true ? 1 : 0
            let tempEqual = target.map { current.rounded() == $0.rounded() } ?? false
            if services.kind == .thermostat {
                primary.characteristic(.currentTemperature).value = .double(current)
                if let target { primary.characteristic(.targetTemperature).value = .double(clamp(target)) }
                primary.characteristic(.currentHeatingCoolingState).value = .int(currentState)
                primary.characteristic(.targetHeatingCoolingState).value = .int(active ? (state.onSchedule ? 3 : 1) : 0)
            } else {
                primary.characteristic(.active).value = .int(active ? 1 : 0)
                primary.characteristic(.currentTemperature).value = .double(current)
                if let target {
                    primary.characteristic(.heatingThresholdTemperature).value = .double(clamp(target))
                    primary[.coolingThresholdTemperature]?.value = .double(clamp(target))
                }
                let heating = !active ? 0 : (state.onSchedule || tempEqual ? 1 : (target.map { current < $0 } == true ? 2 : 1))
                primary.characteristic(.currentHeaterCoolerState).value = .int(heating)
                primary.characteristic(.targetHeaterCoolerState).value = .int(1)
            }
        case .boiler, .airConditioner:
            let isAC = services.kind == .airConditioner
            var currentState = 0, targetState = isAC ? 2 : 1
            if state.power {
                if isAC {
                    let mode = state.acMode ?? "COOL"
                    acModes[services.zone.name] = mode
                    let tempEqual = state.current.flatMap { current in state.target.map { abs(current - $0) < 0.5 } } ?? false
                    switch mode {
                    case "FAN", "DRY":
                        targetState = 2
                        currentState = 1
                    case "HEAT":
                        targetState = 1
                        currentState = tempEqual ? 1 : ((state.current ?? 0) < (state.target ?? 0) ? 2 : 1)
                    default:
                        targetState = 2
                        currentState = tempEqual ? 1 : ((state.current ?? 0) > (state.target ?? .infinity) ? 3 : 1)
                    }
                    services.fanSwitch?.characteristic(.on).value = .bool(mode == "FAN")
                    services.drySwitch?.characteristic(.on).value = .bool(mode == "DRY")
                } else {
                    currentState = state.onSchedule ? 1 : 2
                }
            } else {
                if isAC {
                    acModes[services.zone.name] = nil
                    services.fanSwitch?.characteristic(.on).value = false
                    services.drySwitch?.characteristic(.on).value = false
                }
            }
            primary.characteristic(.active).value = .int(state.power ? 1 : 0)
            primary.characteristic(.currentHeaterCoolerState).value = .int(currentState)
            primary.characteristic(.targetHeaterCoolerState).value = .int(targetState)
            if let current = state.current {
                primary.characteristic(.currentTemperature).value = .double(current)
            } else if !isAC, let target = state.target, primary.characteristic(.currentTemperature).value.doubleValue ?? 0 == 0 {
                primary.characteristic(.currentTemperature).value = .double(target)
            }
            if state.power, let target = state.target {
                primary.characteristic(.heatingThresholdTemperature).value = .double(clamp(target))
                if isAC { primary[.coolingThresholdTemperature]?.value = .double(min(max(target, 10), 35)) }
            }
            if isAC, services.zone.acFanSpeed, state.power, let level = state.fanLevel,
               let fan = TadoOverlay.fanLevels(capabilities[zoneID]?[state.acMode ?? "COOL"]), let index = fan.levels.firstIndex(of: level) {
                acFanLevels[services.zone.name] = level
                primary[.rotationSpeed]?.value = .double(TadoOverlay.percent(step: index, of: fan.levels.count))
            }
        case .switch:
            primary.characteristic(.on).value = .bool(state.power)
        case .faucet:
            primary.characteristic(.active).value = .int(state.power ? 1 : 0)
            primary.characteristic(.inUse).value = .int(state.power ? 1 : 0)
        }
    }

    /// Central switch counters over the active HEATING zones.
    private func showCentralCounters() {
        guard let main = central["Central"] else { return }
        var auto = 0, manual = 0, off = 0
        for zone in centralZones {
            guard let id = zoneIDs[zone.name], let state = states[id], state.settingType == ZoneType.heating.rawValue else { continue }
            if state.onSchedule { auto += 1 } else if !state.power { off += 1 } else if state.hasTermination { manual += 1 }
        }
        main[.tadoModeAuto]?.value = .int(auto)
        main[.tadoModeManual]?.value = .int(manual)
        main[.tadoModeOff]?.value = .int(off)
        main.characteristic(.on).value = .bool(manual != 0 || auto != 0)
    }

    private func setWindow(_ window: Service, open: Bool, zone: String) {
        let key = "window:\(zone)"
        let previous = window.characteristic(.contactSensorState).value.intValue == 1
        window.characteristic(.contactSensorState).value = .int(open ? 1 : 0)
        guard seen.contains(key) else {
            seen.insert(key)
            return
        }
        guard previous != open else { return }
        let elapsed = eveSeconds(accessory: "\(settings.name) \(zone) Window")
        if open {
            window[.eveTimesOpened]?.value = .int((window[.eveTimesOpened]?.value.intValue ?? 0) + 1)
            window[.eveLastActivation]?.value = .int(elapsed)
        }
        window[.eveClosedDuration]?.value = .int(elapsed)
        notify(open ? "openWindow.opened" : "openWindow.closed", accessory: "\(zone) Window")
    }

    /// Seconds since the accessory's Eve reference time, set the first time it needs one.
    private func eveSeconds(accessory: String) -> Int {
        let nowSeconds = Int(now().timeIntervalSince1970)
        var reference = nowSeconds
        _ = eveReference.update(accessory) { value in
            if let value { reference = value } else { value = nowSeconds }
        }
        return max(nowSeconds - reference, 0)
    }

    private func pollPresence(_ home: Int) async throws {
        let devices = try await api.mobileDevices(home).arrayValue ?? []
        var anyoneHome = false
        for device in devices {
            guard let name = device["name"]?.stringValue, let service = presence[name] else { continue }
            let atHome = device["location"]?["atHome"]?.boolValue ?? false
            anyoneHome = anyoneHome || atHome
            setPresence(service, atHome, key: "presence:\(name)", message: atHome ? "presence.user_in" : "presence.user_out", accessory: name)
        }
        if let anyone { setPresence(anyone, anyoneHome, key: "presence:anyone", message: anyoneHome ? "presence.anyone_in" : "presence.anyone_out", accessory: nil) }
    }

    private func setPresence(_ service: Service, _ detected: Bool, key: String, message: String, accessory: String?) {
        let previous: Bool
        if service.type == .motionSensor {
            previous = service.characteristic(.motionDetected).value.boolValue ?? false
            service.characteristic(.motionDetected).value = .bool(detected)
        } else {
            previous = service.characteristic(.occupancyDetected).value.intValue == 1
            service.characteristic(.occupancyDetected).value = .int(detected ? 1 : 0)
        }
        guard seen.contains(key) else {
            seen.insert(key)
            return
        }
        guard previous != detected else { return }
        if service.type == .motionSensor, let name = service[.name]?.value.stringValue {
            service[.eveLastActivation]?.value = .int(eveSeconds(accessory: name))
        }
        notify(message, accessory: accessory)
    }

    private func pollWeather(_ home: Int) async throws {
        let answer = try await api.weather(home)
        if let weather, let celsius = answer["outsideTemperature"]?["celsius"]?.doubleValue?.finite {
            weather.characteristic(.currentTemperature).value = .double(min(max(celsius, -100), 100))
        }
        if let solar, let percentage = answer["solarIntensity"]?["percentage"]?.doubleValue?.finite {
            if settings.solarAsSensor {
                solar.characteristic(.currentAmbientLightLevel).value = .double(percentage == 0 ? 0.0001 : min(percentage * 1000, 100000))
            } else {
                solarLast = (percentage != 0, Int(saturating: percentage.rounded(), in: 0...100) ?? 0)
                solar.characteristic(.on).value = .bool(solarLast.on)
                solar.characteristic(.brightness).value = .int(solarLast.brightness)
            }
        }
    }

    private func revertSolar() {
        guard let solar else { return }
        let last = solarLast
        _ = solar.characteristic(.on).revert(to: .bool(last.on), after: options.resetDelay)
        _ = solar.characteristic(.brightness).revert(to: .int(last.brightness), after: options.resetDelay)
    }

    private func pollRunningTime(_ home: Int) async throws {
        guard let main = central["Central"] else { return }
        lastRunningTime = now()
        let types: [CharacteristicType] = [.tadoActivityDay, .tadoActivityMonth, .tadoActivityYear]
        for (index, range) in TadoOverlay.runningTimeRanges(today: now()).enumerated() {
            if let seconds = try await api.runningTime(home, aggregate: range.aggregate, from: range.from, to: range.to) {
                main[types[index]]?.value = .double(TadoOverlay.rounded(min(seconds / 3600, 99999)))
            }
        }
    }

    private func pollPresenceLock(_ home: Int) async throws {
        let state = try await api.state(home)
        let value = state["presenceLocked"]?.boolValue != true ? 3 : (state["presence"]?.stringValue == "AWAY" ? 1 : 0)
        showPresenceLock(value)
    }

    private func showPresenceLock(_ value: Int) {
        presenceLockService?.characteristic(.securitySystemCurrentState).value = .int(value)
        presenceLockService?.characteristic(.securitySystemTargetState).value = .int(value)
        homeSwitch?.characteristic(.on).value = .bool(value == 0)
        awaySwitch?.characteristic(.on).value = .bool(value == 1)
    }

    private func pollChildLocks(_ home: Int) async throws {
        for device in try await api.devices(home).arrayValue ?? [] {
            guard let serial = device["serialNo"]?.stringValue, let service = childLocks[serial] else { continue }
            service.characteristic(.on).value = .bool(device["childLockEnabled"]?.boolValue ?? false)
        }
    }

    // MARK: Writes (sections 7.2 to 7.5)

    /// A Target Heating Cooling State, Active, threshold or Target Heater Cooler State write, sent once no other came in
    /// 400 ms; `threshold` 1 is the heating one, 2 the cooling one (an AC's mode follows it).
    func buffer(_ zone: String, state: Int? = nil, temperature: Double? = nil, mode: Int? = nil, threshold: Int? = nil) {
        var entry = pending[zone] ?? Pending()
        if let state { entry.state = state }
        if let temperature { entry.temperature = temperature }
        if let mode { entry.mode = mode }
        pending[zone] = entry
        let writes = writes
        tasks.add { [weak self] in
            guard await writes(zone) else { return }
            await self?.flush(zone)
        }
    }

    private enum Action: Equatable {
        case off, schedule, temperature(Double)
    }

    func flush(_ zone: String) async {
        guard let entry = pending.removeValue(forKey: zone), let services = zones[zone] else { return }
        if services.kind == .airConditioner { return await flushAC(services, entry) }
        let isBoiler = services.kind == .boiler
        var temperature = entry.temperature.flatMap(\.finite)
        if let value = temperature {
            let low = services.kind == .thermostat ? 5 : services.limits.min
            if isBoiler {
                temperature = min(max(value, services.limits.min), services.limits.max)
            } else if value < low, value != 5 {
                temperature = nil
            } else {
                temperature = TadoOverlay.rounded(value)
            }
        }
        if let temperature, !(options.preferSiriTemperature && temperature == 5) { lastTemperature[zone] = temperature }
        let last = lastTemperature[zone] ?? (isBoiler ? services.limits.min : 20)
        let custom = services.zone.mode == .custom && services.kind.isHeaterCooler
        let action: Action?
        if options.preferSiriTemperature, entry.state == 3, let temperature {
            action = temperature == 5 ? .schedule : .temperature(temperature)
        } else if entry.state == 0 {
            action = .off
        } else if entry.state == 3 {
            action = .schedule
        } else if let temperature {
            action = .temperature(temperature)
        } else if entry.state == 1 {
            // CUSTOM: turning on goes back to the schedule (the Homebridge plugin's buffer made a temperature of it first).
            action = custom ? .schedule : .temperature(last)
        } else {
            action = nil
        }
        guard let action else { return }
        // The delay switch holds back a change of state (back to the schedule) for its timer's seconds; off goes at once.
        if case .temperature = action {} else if !isBoiler, !services.zone.autoOffDelay, services.primary[.tadoDelay]?.value.boolValue == true,
                                                 let timer = services.primary[.tadoDelayTimer]?.value.intValue, timer > 0 {
            return await delayed(services, action, seconds: timer)
        }
        await send(services, action)
    }

    private func delayed(_ services: ZoneServices, _ action: Action, seconds: Int) async {
        let zone = services.zone.name
        delayTasks[zone]?.cancel()
        if action == .off {
            delayTasks[zone] = nil
            return await send(services, .off)
        }
        logger.info("\(services.deviceID): delay: wait \(seconds) seconds")
        let unit = options.delayUnit
        delayTasks[zone] = Task { [weak self] in
            do { try await Task.sleep(for: unit * seconds) } catch { return }
            await self?.delayFinished(services, action)
        }
    }

    private func delayFinished(_ services: ZoneServices, _ action: Action) async {
        logger.info("\(services.deviceID): delay timer finished, switching to \(action == .schedule ? "schedule" : "on")")
        delayTasks[services.zone.name] = nil
        await send(services, action)
    }

    private func delaySwitchChanged(zone: String, on: Bool) {
        guard let services = zones[zone], services.zone.autoOffDelay else { return }
        delayTasks[zone]?.cancel()
        delayTasks[zone] = nil
        guard on, let timer = services.primary[.tadoDelayTimer]?.value.intValue, timer > 0 else { return }
        let unit = options.delayUnit
        let delay = services.primary[.tadoDelay]
        delayTasks[zone] = Task { [weak self] in
            do { try await Task.sleep(for: unit * timer) } catch { return }
            await self?.logger.info("\(services.deviceID): timer expired, turning off delay switch")
            delay?.value = false
        }
    }

    /// Sends a heating or hot water zone's action.
    private func send(_ services: ZoneServices, _ action: Action) async {
        try? await writing(services.deviceID, label: { () -> String in
            switch action {
            case .off: "State: 0"
            case .schedule: "State: 3"
            case .temperature(let value): "Temperature: \(value)"
            }
        }()) { home, zoneID in
            let zone = services.zone
            switch action {
            case .schedule:
                try await self.api.clearOverlay(home, zone: zoneID)
                self.states[zoneID]?.onSchedule = true
            case .off:
                let custom = zone.mode == .custom && services.kind.isHeaterCooler
                let body = TadoOverlay.zone(type: zone.type, power: false, celsius: nil,
                                            termination: TadoOverlay.termination(mode: zone.mode, modeTimer: zone.modeTimer, forceManual: custom), current: self.states[zoneID]?.setting)
                try await self.api.setOverlay(home, zone: zoneID, body)
                self.states[zoneID]?.power = false
                self.states[zoneID]?.onSchedule = false
            case .temperature(let value):
                let celsius = zone.type == .hotWater ? min(max(value, services.limits.min), services.limits.max) : value
                let body = TadoOverlay.zone(type: zone.type, power: true, celsius: celsius,
                                            termination: TadoOverlay.termination(mode: zone.mode, modeTimer: zone.modeTimer), current: self.states[zoneID]?.setting)
                try await self.api.setOverlay(home, zone: zoneID, body)
                self.states[zoneID]?.power = true
                self.states[zoneID]?.target = celsius
                self.states[zoneID]?.onSchedule = false
            }
        }
    }

    private func setHotWater(zone: String, on: Bool) async {
        guard let services = zones[zone] else { return }
        try? await writing(services.deviceID, label: "On: \(on)") { home, zoneID in
            let settings = services.zone
            let body = TadoOverlay.zone(type: .hotWater, power: on, celsius: nil,
                                        termination: TadoOverlay.termination(mode: settings.mode, modeTimer: settings.modeTimer), current: self.states[zoneID]?.setting)
            try await self.api.setOverlay(home, zone: zoneID, body)
            self.states[zoneID]?.power = on
        }
    }

    private func flushAC(_ services: ZoneServices, _ entry: Pending) async {
        let primary = services.primary
        let active = entry.state ?? primary.characteristic(.active).value.intValue ?? 0
        if active == 0 {
            // A mode or a threshold changed while off waits for the next turn-on.
            guard entry.state == 0 else { return }
            return await sendAC(services, power: false, mode: nil, temperature: nil)
        }
        let targetState = entry.mode ?? primary.characteristic(.targetHeaterCoolerState).value.intValue ?? 2
        let mode = targetState == 1 ? "HEAT" : (targetState == 2 ? "COOL" : "AUTO")
        let threshold: CharacteristicType = mode == "HEAT" ? .heatingThresholdTemperature : .coolingThresholdTemperature
        let temperature = primary[threshold]?.value.doubleValue ?? entry.temperature
        await sendAC(services, power: true, mode: mode, temperature: temperature)
    }

    private func sendAC(_ services: ZoneServices, power: Bool, mode: String?, temperature: Double?, fanLevel: String? = nil) async {
        let zone = services.zone
        try? await writing(services.deviceID, label: power ? "Mode: \(mode ?? "")" : "State: 0") { home, zoneID in
            let capabilities = try? await self.capabilities(home: home, zone: zoneID)
            let level = zone.acFanSpeed ? (fanLevel ?? self.acFanLevels[zone.name]) : nil
            let body = TadoOverlay.airConditioner(power: power, mode: mode ?? "COOL", celsius: temperature, fanLevel: level, current: self.states[zoneID]?.setting,
                                                  capabilities: capabilities, timer: zone.mode == .timer ? zone.modeTimer : nil)
            try await self.api.setOverlay(home, zone: zoneID, body)
            if let setting = body["setting"] { self.states[zoneID]?.setting = setting }
            self.states[zoneID]?.power = power
            self.acModes[zone.name] = power ? mode : nil
            services.fanSwitch?.characteristic(.on).value = .bool(power && mode == "FAN")
            services.drySwitch?.characteristic(.on).value = .bool(power && mode == "DRY")
        }
    }

    private func capabilities(home: Int, zone: Int) async throws -> JSONValue {
        if let known = capabilities[zone] { return known }
        let answer = try await api.capabilities(home, zone: zone)
        capabilities[zone] = answer
        return answer
    }

    private func setFanSpeed(zone: String, percent: Double) async {
        guard percent > 0, let services = zones[zone], let home = homeID, let zoneID = zoneIDs[zone] else { return }
        let primary = services.primary
        let targetState = primary.characteristic(.targetHeaterCoolerState).value.intValue ?? 2
        let mode = acModes[zone] ?? (targetState == 1 ? "HEAT" : "COOL")
        guard let caps = try? await capabilities(home: home, zone: zoneID), let fan = TadoOverlay.fanLevels(caps[mode]) else {
            logger.warning("\(services.deviceID): tado° lists no fan speeds for mode \(mode)")
            return
        }
        let level = TadoOverlay.level(percent: percent, levels: fan.levels)
        acFanLevels[zone] = level
        if let index = fan.levels.firstIndex(of: level), let speed = primary[.rotationSpeed] {
            _ = speed.revert(to: .double(TadoOverlay.percent(step: index, of: fan.levels.count)), after: options.resetDelay)
        }
        guard primary.characteristic(.active).value.intValue == 1 || acModes[zone] != nil else { return }
        let threshold: CharacteristicType = targetState == 1 ? .heatingThresholdTemperature : .coolingThresholdTemperature
        await sendAC(services, power: true, mode: mode, temperature: primary[threshold]?.value.doubleValue, fanLevel: level)
    }

    private func setACModeSwitch(zone: String, mode: String, on: Bool) async {
        guard let services = zones[zone] else { return }
        guard on else { return await sendAC(services, power: false, mode: nil, temperature: nil) }
        if let home = homeID, let zoneID = zoneIDs[zone], let caps = try? await capabilities(home: home, zone: zoneID), caps.objectValue != nil, caps[mode] == nil {
            logger.warning("\(services.deviceID): the air conditioner has no \(mode) mode")
            let service = mode == "FAN" ? services.fanSwitch : services.drySwitch
            _ = service?.characteristic(.on).revert(to: false, after: options.resetDelay)
            return
        }
        await sendAC(services, power: true, mode: mode, temperature: nil)
    }

    private func setOpenWindow(zone: String, _ enabled: Bool) async throws {
        guard let services = zones[zone] else { return }
        try await writing(services.deviceID, label: "\(zone) Window: \(enabled)", throwing: true) { home, zoneID in
            try await self.api.setOpenWindow(home, zone: zoneID, enabled)
            self.openWindowEnabled[zoneID] = enabled
        }
    }

    private func setChildLock(_ serial: String, _ enabled: Bool) async throws {
        guard let home = homeID else { throw HAPStatusError(.serviceCommunicationFailure) }
        logger.info("\(settings.name) Child Lock: \(serial): \(enabled)")
        do {
            try await api.setChildLock(serial: serial, enabled)
        } catch {
            logger.error("\(settings.name) Child Lock: failed to set states: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        _ = home
    }

    private func setPresenceLock(target: Int) async throws {
        let presence = target == 1 ? "AWAY" : (target == 3 ? "AUTO" : "HOME")
        try await sendPresence(presence)
        presenceLockService?.characteristic(.securitySystemCurrentState).value = .int(target == 1 ? 1 : (target == 3 ? 3 : 0))
    }

    private func setPresenceSwitch(_ presence: String, on: Bool) async throws {
        try await sendPresence(on ? presence : "AUTO")
        homeSwitch?.characteristic(.on).value = .bool(on && presence == "HOME")
        awaySwitch?.characteristic(.on).value = .bool(on && presence == "AWAY")
    }

    private func sendPresence(_ presence: String) async throws {
        guard let home = homeID else { throw HAPStatusError(.serviceCommunicationFailure) }
        logger.info("\(settings.name) Presence Lock: \(presence)")
        do {
            try await api.setPresence(home, presence)
        } catch {
            logger.error("\(settings.name) Presence Lock: failed to set states: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    /// The central switch and its sub-switches (section 7.3), over the active HEATING zones.
    private func centralWrite(_ name: String, _ on: Bool) async {
        guard let home = homeID else { return }
        let targets = centralZones.compactMap { zone in zoneIDs[zone.name].map { (id: $0, type: zone.type, mode: zone.mode, modeTimer: zone.modeTimer) } }
        guard !targets.isEmpty else { return }
        enum Command { case schedule, boost, off }
        let command: Command
        switch (name, on) {
        case ("Central", true), ("Shedule", true): command = .schedule
        case ("Boost", true): command = .boost
        case ("Off", true), ("Central", false): command = .off
        default: return
        }
        writesInProgress += 1
        defer { writesInProgress -= 1 }
        logger.info("\(settings.name) Central Switch: \(name): \(on)")
        do {
            switch command {
            case .schedule: try await api.clearOverlays(home, rooms: targets.map(\.id))
            case .boost: try await api.setOverlays(home, TadoOverlay.central(targets, power: true, celsius: 25))
            case .off: try await api.setOverlays(home, TadoOverlay.central(targets, power: false, celsius: nil))
            }
        } catch {
            logger.error("\(settings.name) Central Switch: failed to set states: \(error)")
            return
        }
        for zone in centralZones {
            guard let services = zones[zone.name] else { continue }
            let primary = services.primary
            switch (command, services.kind) {
            case (.schedule, .thermostat): primary.characteristic(.targetHeatingCoolingState).value = .int(3)
            case (.schedule, _): primary[.active]?.value = .int(1)
            case (.boost, .thermostat):
                primary.characteristic(.currentHeatingCoolingState).value = .int(1)
                primary.characteristic(.targetHeatingCoolingState).value = .int(1)
                primary.characteristic(.targetTemperature).value = .double(services.limits.max)
            case (.boost, _):
                primary[.active]?.value = .int(1)
                primary[.heatingThresholdTemperature]?.value = .double(services.limits.max)
            case (.off, .thermostat):
                primary.characteristic(.currentHeatingCoolingState).value = .int(0)
                primary.characteristic(.targetHeatingCoolingState).value = .int(0)
            case (.off, _): primary[.active]?.value = .int(0)
            }
        }
        central["Central"]?.characteristic(.on).value = .bool(command != .off)
        if name != "Central" { _ = central[name]?.characteristic(.on).revert(to: false, after: options.resetDelay) }
    }

    /// Runs a write of a zone with its id: marks the home as writing (a poll then leaves the values alone), logs it, and
    /// logs a failure (HomeKit keeps the written value until the next poll, as with the Homebridge plugin) or, with
    /// `throwing`, answers it with No Response.
    private func writing(_ accessory: String, label: String, throwing: Bool = false, _ body: (Int, Int) async throws -> Void) async throws {
        let zone = zones.values.first { $0.deviceID == accessory }?.zone
        guard let home = homeID, let zoneName = zone?.name, let zoneID = zoneIDs[zoneName] else {
            logger.error("\(accessory): cannot find the tado° zone: no request sent")
            if throwing { throw HAPStatusError(.serviceCommunicationFailure) }
            return
        }
        writesInProgress += 1
        defer { writesInProgress -= 1 }
        logger.info("\(accessory): \(label)")
        do {
            try await body(home, zoneID)
        } catch {
            logger.error("\(accessory): failed to set states: \(error)")
            if throwing { throw HAPStatusError(.serviceCommunicationFailure) }
        }
    }

    private func notify(_ message: String, accessory: String?) {
        guard let telegram, let template = telegram.settings.messages[message] else { return }
        let text = TelegramSettings.fill(template, accessory: accessory, home: settings.name)
        tasks.add { await telegram.send(text) }
    }
}
