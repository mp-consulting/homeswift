import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The plugin's timings, shortened by the tests (docs/clean-room/V2CTrydan.md, 5).
struct TrydanTiming: Sendable {
    /// The shortest polling interval taken; `pollingInterval` below it is raised to it.
    var minimumPollingInterval: Duration = .seconds(5)
    /// Seconds, as `pollingInterval` and `timeout` count, so the tests can shrink them.
    var second: Duration = .seconds(1)
    /// After three failed polls: 30 s, 60 s, 120 s, 240 s, then every 300 s, never shorter than the interval.
    var backoff = Backoff(initial: .seconds(30), maximum: .seconds(300))
    /// The second re-read after a write: the charger may apply some (`Paused`) with a delay.
    var settle: Duration = .seconds(2)
    /// Rotation Speed writes wait this long for a later one.
    var coalescing: Duration = .milliseconds(500)
    /// How often the keywords `/RealTimeData` leaves out are asked again through `/read`.
    var fallbackInterval: Duration = .seconds(3600)
    /// After a failed `/read`, when to try again.
    var fallbackRetry: Duration = .seconds(60)
}

/// One charger: its client, its last report, its services once on the bridge, and its polling's state. Writes from
/// HomeKit capture it, not the plugin.
actor TrydanCharger {
    let host: String
    let client: TrydanClient
    let interval: Duration
    let timing: TrydanTiming
    let logger: Logger
    let context: PluginContext
    let tasks: TaskBag
    /// The Device Id the accessory is under, once known (the configuration's, or the first report's).
    private(set) var deviceID: String?
    private(set) var name: String
    private(set) var settings: ChargerSettings
    private(set) var report: TrydanReport?
    private(set) var services: TrydanServices?
    /// What `/read` gave for the keywords `/RealTimeData` lacks, and those the firmware does not know.
    private(set) var extras: [String: Double] = [:]
    private(set) var unsupported: Set<String> = []
    private var nextFallbackRead: ContinuousClock.Instant?
    private(set) var failures = 0
    private(set) var isReachable = true
    private var retryAfter: Duration?
    private var reading = false
    private var rereadWanted = false
    /// Writes the charger took, so a read sent before one is not shown over it.
    private var writes = 0
    /// When the Light LED's brightness was last written, so an On of the same request does not override it.
    private var lastBrightnessWrite: ContinuousClock.Instant?
    private var warnedStates: Set<Int> = []
    private var repairedFirmware: Set<String> = []
    private var identityNoted = false
    /// The Light LED's last level above 0, for an On without a brightness.
    private var lastLightLevel = 100
    /// The Logo LED reported a level above 1 once: it takes 0 to 100 rather than V2C's 0 and 1.
    private var logoDimmable = false
    private var lastLogoLevel = 100
    private let coalesce: LatestCallGuard
    private var series: [String: RecordedSeries] = [:]
    /// The lifetime energy and the installation settings sent, from `charger-<Device Id>.json`; loaded once the Device Id
    /// is known.
    private(set) var memory: ChargerMemory?
    /// An installation write in flight, and when a failed one may be tried again, by keyword.
    private var installing = false
    private var installRetry: [String: ContinuousClock.Instant] = [:]

    init(
        host: String, deviceID: String?, name: String, settings: ChargerSettings, transport: any HTTPSending, interval: Duration, timeout: Duration,
        timing: TrydanTiming, context: PluginContext, tasks: TaskBag
    ) {
        self.host = host
        self.deviceID = deviceID
        self.name = name
        self.settings = settings
        self.interval = interval
        self.timing = timing
        self.logger = context.logger
        self.context = context
        self.tasks = tasks
        client = TrydanClient(host: host, transport: transport, timeout: timeout, logger: context.logger)
        coalesce = LatestCallGuard(delay: timing.coalescing)
    }

    var isOnBridge: Bool { services != nil }

    // MARK: Reading

    /// Reads `/RealTimeData` (and the keywords it lacks, when due) and shows it; nil when the read failed, or was skipped
    /// because another is in flight, which sees the same values.
    @discardableResult
    func refresh() async -> TrydanReport? {
        guard !reading else {
            // A write asks for a read while one is in flight: that one may predate the write, so another follows it.
            rereadWanted = true
            return nil
        }
        reading = true
        defer { reading = false }
        var report: TrydanReport?
        // At most a few rounds: each is one more write during the read before.
        for _ in 0..<3 {
            rereadWanted = false
            report = await readOnce()
            guard rereadWanted else { break }
        }
        return report
    }

    /// One read; an answer that a write overtook while it was on its way is not shown.
    private func readOnce() async -> TrydanReport? {
        let generation = writes
        do {
            let parsed = try await client.realTimeData()
            try await readFallbacks(missingFrom: parsed.object)
            let report = try TrydanReport(parsed.object, extras: extras)
            guard writes == generation else {
                rereadWanted = true
                return nil
            }
            if parsed.repaired, repairedFirmware.insert(report.firmwareVersion ?? "").inserted {
                logger.warning("Repaired the malformed JSON of \(name)", metadata: ["host": "\(host)", "firmware": "\(report.firmwareVersion ?? "unknown")"])
            }
            succeeded(report)
            return report
        } catch {
            failed(error)
            return nil
        }
    }

    /// `/read` for the optional keywords the object lacks (3.3): at the first poll, then hourly; a 404 is remembered.
    private func readFallbacks(missingFrom object: [String: JSONValue]) async throws {
        let now = ContinuousClock.now
        if let next = nextFallbackRead, now < next { return }
        let missing = TrydanReport.fallbackKeys.filter { object[$0] == nil && !unsupported.contains($0) }
        nextFallbackRead = now + timing.fallbackInterval
        for key in missing {
            do {
                extras[key] = try await client.read(key)
            } catch TrydanError.unsupported {
                unsupported.insert(key)
                extras[key] = nil
                logger.debug("The firmware of \(name) has no \(key)")
            } catch {
                // Kept as last read; tried again soon. These keywords are optional: the poll goes on.
                nextFallbackRead = now + timing.fallbackRetry
                logger.debug("Could not read \(key) from \(name): \(error)")
                return
            }
        }
    }

    private func succeeded(_ report: TrydanReport) {
        let previous = self.report
        self.report = report
        failures = 0
        retryAfter = nil
        if !isReachable {
            isReachable = true
            services?.accessory.isUnavailable = false
            logger.info("\(name) is responding again", metadata: ["host": "\(host)"])
        }
        if report.chargeState == nil, warnedStates.insert(report.rawChargeState).inserted {
            logger.warning("\(name) reports an unknown charge state \(report.rawChargeState): shown as connected, not charging")
        }
        if report.isFault, previous?.isFault != true {
            logger.warning("\(name) reports a fault", metadata: ["chargeState": "\(report.rawChargeState)"])
        }
        if let previous {
            if report.isCharging, !previous.isCharging {
                logger.info("\(name) started charging")
            } else if previous.isCharging, !report.isCharging {
                logger.info("\(name) stopped charging", metadata: [
                    "energy": "\(String(format: "%.2f", previous.chargeEnergy)) kWh", "duration": "\(previous.chargeTime) s",
                ])
            }
        }
        if let level = report.lightLED, level > 0 { lastLightLevel = min(level, 100) }
        if let level = report.logoLED, level > 1 {
            logoDimmable = true
            lastLogoLevel = min(level, 100)
        }
        noteIdentity(report)
        let lifetime = accumulate(report)
        services?.show(report, lifetimeEnergy: lifetime)
        record(report, lifetimeEnergy: lifetime)
        if !installing, !installationWrites(report).isEmpty {
            installing = true
            tasks.add { [weak self] in await self?.applyInstallation() }
        }
    }

    // MARK: What is kept across restarts

    /// The memory of the charger's Device Id, read once.
    private func loadedMemory() -> ChargerMemory? {
        guard let deviceID else { return nil }
        if let memory { return memory }
        let loaded = ChargerMemory.file(context, deviceID: deviceID).load() ?? ChargerMemory()
        memory = loaded
        return loaded
    }

    private func save(_ updated: ChargerMemory) {
        guard let deviceID, updated != memory else { return }
        memory = updated
        do {
            try ChargerMemory.file(context, deviceID: deviceID).save(updated)
        } catch {
            logger.warning("Could not keep what \(name) delivered: \(error)")
        }
    }

    /// The session's energy added to the lifetime total, kept; nil before the Device Id is known.
    private func accumulate(_ report: TrydanReport) -> Double? {
        guard var updated = loadedMemory() else { return nil }
        updated.energy.add(sessionEnergy: report.chargeEnergy)
        save(updated)
        return updated.energy.total
    }

    // MARK: Installation settings

    /// The installation keywords the Accessory Settings ask for that the charger does not report and were not sent
    /// already (a value is sent once per change of the settings) nor failed a moment ago.
    func installationWrites(_ report: TrydanReport) -> [(keyword: String, value: Int)] {
        guard let memory = loadedMemory() else { return [] }
        let now = ContinuousClock.now
        return settings.installation.filter { write in
            guard memory.sent[write.keyword] != write.value, installRetry[write.keyword].map({ now >= $0 }) ?? true else { return false }
            guard let current = Self.reported(write.keyword, in: report) else { return false }
            return current != write.value
        }
    }

    /// The value of an installation keyword the report holds; nil when the charger has not reported it.
    static func reported(_ keyword: String, in report: TrydanReport) -> Int? {
        switch keyword {
        case "ChargeMode": report.chargeMode
        default: nil
        }
    }

    /// Sends what `installationWrites` lists, one at a time, remembering each value the charger took.
    func applyInstallation() async {
        defer { installing = false }
        guard let report else { return }
        for write in installationWrites(report) {
            do {
                try await set(write.keyword, write.value)
                installRetry[write.keyword] = nil
                if var updated = memory {
                    updated.sent[write.keyword] = write.value
                    save(updated)
                }
                logger.info("Set \(write.keyword) of \(name) to \(write.value), as its settings ask")
            } catch {
                installRetry[write.keyword] = .now + timing.fallbackRetry
            }
        }
    }

    private func failed(_ error: any Error) {
        failures += 1
        if case TrydanError.rateLimited(let delay) = error { retryAfter = delay }
        if failures == 3, isReachable {
            isReachable = false
            services?.accessory.isUnavailable = true
            logger.warning("\(name) is not responding, will keep retrying: \(error)", metadata: ["host": "\(host)"])
        } else {
            logger.debug("Could not read \(name): \(error)", metadata: ["host": "\(host)", "failures": "\(failures)"])
        }
    }

    /// A later `ID` on a charger keyed otherwise: noted once, never re-keyed (rooms and automations would go).
    private func noteIdentity(_ report: TrydanReport) {
        guard !identityNoted, let deviceID, let reported = report.id.flatMap(TrydanIdentity.deviceID), reported != deviceID else { return }
        identityNoted = true
        if deviceID.hasPrefix("HOST-") {
            logger.info("\(name) now reports its ID \(reported); it stays keyed by its address (\(deviceID)) to keep its rooms and automations")
        } else {
            logger.warning("The charger at \(host) reports the ID \(reported), not \(deviceID): is another charger at this address?")
        }
    }

    /// When to poll next: the interval, or longer after three failures, or what a 429 asked.
    func nextDelay() -> Duration {
        if let retryAfter { return retryAfter }
        guard failures >= 3 else { return interval }
        // 30 s, 60 s, 120 s, then the maximum (5.3).
        let attempt = failures - 3
        return max(interval, attempt >= 3 ? timing.backoff.maximum : timing.backoff.delay(attempt: attempt))
    }

    // MARK: Energy

    /// `ChargePower` untagged (the car's draw is part of the home's use), `HousePower` and `FVPower` as the settings tag
    /// them, `BatteryPower` untagged (docs/clean-room/V2CTrydan.md, 4.4).
    static func energyReadings(_ report: TrydanReport, settings: ChargerSettings, device: String) -> [(key: String, watts: Double, tag: EnergyTag?)] {
        var readings: [(key: String, watts: Double, tag: EnergyTag?)] = [("charge", report.chargePower, nil)]
        let houseRole: EnergyRole? =
            switch settings.houseEnergyRole ?? .none {
            case .none: nil
            case .home: .home
            case .grid: .grid
            }
        readings.append(("house", report.housePower, houseRole.map { EnergyTag(role: $0, device: device, shared: meterShared) }))
        readings.append(("solar", report.fvPower, settings.solarEnergy == true ? EnergyTag(role: .solar, device: device, shared: meterShared) : nil))
        if let battery = report.batteryPower { readings.append(("battery", battery, nil)) }
        return readings
    }

    /// Several chargers of one installation read the same meter: its figures count once.
    static let meterShared = "v2c-meter"

    private func record(_ report: TrydanReport, lifetimeEnergy: Double?) {
        guard let deviceID else { return }
        var readings = Self.energyReadings(report, settings: settings, device: name)
        // kWh, untagged: the charge power is already in the history.
        readings.append(("session", report.chargeEnergy, nil))
        if let lifetimeEnergy { readings.append(("energy", lifetimeEnergy, nil)) }
        for reading in readings {
            guard let watts = reading.watts.finite else { continue }
            let recorded: RecordedSeries
            if let known = series[reading.key] {
                recorded = known
            } else {
                recorded = context.series("\(deviceID):\(reading.key)")
                series[reading.key] = recorded
            }
            context.recordValue(watts, series: recorded, energy: reading.tag)
        }
    }

    // MARK: The accessory

    /// Puts the charger on the bridge under `deviceID`, or builds it again when its shape changed (the maximum current, the
    /// LEDs reported). `cached` gives its last values back.
    func attach(deviceID: String, name: String, settings: ChargerSettings, cached: Accessory?) throws -> Bool {
        let shape = services?.shape ?? cached.map(TrydanShape.init(cached:)) ?? TrydanShape()
        let wanted = report.map(shape.updated(with:)) ?? shape
        guard services == nil || services?.shape != wanted || self.deviceID != deviceID else { return false }
        self.deviceID = deviceID
        self.name = name
        self.settings = settings
        let built = TrydanServices.make(
            id: "\(V2CTrydanPlugin.platform):\(deviceID)", deviceID: deviceID, name: name, firmware: report?.firmwareVersion, settings: settings,
            shape: wanted, cached: services?.accessory ?? cached
        ) { [weak self] command in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            try await self.perform(command)
        }
        // The first reports came before the Device Id was known: counted now (counting one twice adds nothing).
        if let report { built.show(report, lifetimeEnergy: accumulate(report)) }
        built.accessory.isUnavailable = !isReachable
        try context.add(built.accessory)
        services = built
        return true
    }

    /// Whether the shape the last report asks for is not the accessory's.
    var needsRebuild: Bool {
        guard let services, let report else { return false }
        return services.shape.updated(with: report) != services.shape
    }

    // MARK: Writing

    /// What a HomeKit write becomes (docs/clean-room/V2CTrydan.md, 4.3).
    func perform(_ command: TrydanCommand) async throws {
        switch command {
        case .allowCharging(let allowed):
            try await set("Paused", allowed ? 0 : 1)
        case .current(let amperes):
            guard amperes >= 1 else {
                // The slider at the bottom: a value still waiting from the same drag is dropped.
                _ = coalesce.claim("intensity")
                try await set("Paused", 1)
                return
            }
            // A drag of the slider: only its last value goes.
            guard await coalesce("intensity") else { return }
            let range = report?.intensityRange ?? 6...32
            let value = Int(saturating: amperes.rounded(), in: range) ?? range.lowerBound
            try await set("Intensity", value)
        case .lock(let locked):
            try await set("Locked", locked ? 1 : 0)
        case .timer(let on):
            try await set("Timer", on ? 1 : 0)
        case .dynamic(let on):
            try await set("Dynamic", on ? 1 : 0)
        case .pauseDynamic(let on):
            try await set("PauseDynamic", on ? 1 : 0)
        case .lightLED(let on):
            guard on else {
                _ = coalesce.claim("lightLED")
                try await set("LightLED", 0)
                return
            }
            // HomeKit sends On with a Brightness in one request, in no set order: a brightness wins.
            let asked = ContinuousClock.now
            try? await Task.sleep(for: timing.coalescing)
            // A brightness of the same request may have started before this On, or finished just before it ran.
            if let lastBrightnessWrite, lastBrightnessWrite >= asked - timing.coalescing * 2 { return }
            try await set("LightLED", lastLightLevel)
        case .lightLEDBrightness(let level):
            lastBrightnessWrite = .now
            defer { lastBrightnessWrite = .now }
            guard await coalesce("lightLED") else { return }
            try await set("LightLED", min(max(level, 0), 100))
        case .logoLED(let on):
            try await set("LogoLED", on ? (logoDimmable ? lastLogoLevel : 1) : 0)
        case .mode(let mode, let on):
            guard on else {
                // A radio: the mode in force cannot be turned off, only another one on.
                if report?.dynamicPowerMode == mode.rawValue { _ = services?.modes[mode]?.characteristic(.on).revert(to: .bool(true), after: .milliseconds(100)) }
                return
            }
            try await set("DynamicPowerMode", mode.rawValue)
        }
    }

    /// Checks a value as the charger's table allows it (3.4), refused without a request when it does not fit.
    func validate(_ keyword: String, _ value: Int) throws(TrydanError) {
        let allowed: String?
        switch keyword {
        case "Paused", "Locked", "Timer", "Dynamic", "PauseDynamic":
            allowed = (0...1).contains(value) ? nil : "0 or 1"
        case "Intensity":
            allowed = (6...32).contains(value) ? nil : "6 to 32"
        case "DynamicPowerMode":
            allowed = (0...5).contains(value) ? nil : "0 to 5"
        case "ChargeMode":
            allowed = (0...2).contains(value) ? nil : "0, 1 or 2"
        case "LightLED", "LogoLED":
            allowed = (0...100).contains(value) ? nil : "0 to 100"
        default:
            allowed = "a keyword the plugin writes"
        }
        if let allowed { throw .outOfRange(keyword: keyword, value: value, allowed: allowed) }
    }

    /// Validates and sends one keyword; on `OK`, shows it at once and reads the charger again now and after `settle`.
    func set(_ keyword: String, _ value: Int) async throws {
        do {
            try validate(keyword, value)
        } catch {
            logger.error("Not sending \(keyword)=\(value) to \(name): \(error)")
            throw HAPStatusError(.invalidValueInRequest, reason: error.description)
        }
        do {
            try await client.write(keyword, value)
            writes += 1
        } catch {
            logger.warning("\(name) did not take \(keyword)=\(value): \(error)", metadata: ["host": "\(host)"])
            throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
        }
        if var report {
            Self.apply(keyword, value, to: &report)
            self.report = report
            services?.show(report, lifetimeEnergy: memory?.energy.total)
        }
        let settle = timing.settle
        tasks.add { [weak self] in
            await self?.refresh()
            try? await Task.sleep(for: settle)
            await self?.refresh()
        }
    }

    /// The report once the charger took `keyword=value`, before it says so.
    static func apply(_ keyword: String, _ value: Int, to report: inout TrydanReport) {
        switch keyword {
        case "Paused": report.paused = value
        case "Locked": report.locked = value
        case "Timer": report.timer = value
        case "Dynamic": report.dynamic = value
        case "PauseDynamic": report.pauseDynamic = value
        case "Intensity": report.intensity = value
        case "DynamicPowerMode": report.dynamicPowerMode = value
        case "ChargeMode": report.chargeMode = value
        case "LightLED": report.lightLED = value
        case "LogoLED": report.logoLED = value
        default: break
        }
    }

    /// The charger for the page and the Assistant.
    func snapshot() -> JSONValue {
        var fields: [String: JSONValue] = [
            "host": .string(host), "name": .string(name), "reachable": .bool(isReachable), "onBridge": .bool(services != nil),
        ]
        if let deviceID { fields["deviceID"] = .string(deviceID) }
        if let report {
            fields["chargeState"] = .number(Double(report.rawChargeState))
            fields["connected"] = .bool(report.isConnected)
            fields["charging"] = .bool(report.isCharging)
            fields["paused"] = .bool(report.paused == 1)
            fields["locked"] = .bool(report.locked == 1)
            fields["chargePower"] = .number(report.chargePower)
            fields["sessionEnergy"] = .number(report.chargeEnergy)
            if let total = memory?.energy.total { fields["lifetimeEnergy"] = .number((total * 100).rounded() / 100) }
            fields["intensity"] = .number(Double(report.intensity))
            fields["minIntensity"] = .number(Double(report.minIntensity))
            fields["maxIntensity"] = .number(Double(report.maxIntensity))
            fields["housePower"] = .number(report.housePower)
            fields["solarPower"] = .number(report.fvPower)
            fields["meterStatus"] = .string(SlaveError.name(report.slaveError))
            fields["dynamicPowerMode"] = .string(DynamicPowerMode(rawValue: report.dynamicPowerMode)?.name ?? "\(report.dynamicPowerMode)")
            if let firmware = report.firmwareVersion { fields["firmware"] = .string(firmware) }
        }
        return .object(fields)
    }
}
