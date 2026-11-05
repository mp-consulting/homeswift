import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Renault, Dacia and Alpine cars from the MyRenault cloud (Gigya's sign-in, Renault's Kamereon API): the battery,
/// charging and plug, climate, the horn and lights, interior and exterior temperatures and, on cars that report them,
/// the doors. Which endpoints a car has depends on its model (`ModelEndpoints`).
///
/// There is no maintained Homebridge plugin: the block (platform `Renault`) is Homeswift's own. Written from the
/// functional specification in docs/clean-room/Renault.md (from renault-api and Home Assistant's `renault`
/// integration). See README.md in this directory.
///
/// Renault allows about 60 requests an hour per account, the MyRenault app's included: requests go one at a time, the
/// poll interval is computed from the budget (`pollInterval(pollers:hourly:budget:hour:)`), and a quota error pauses
/// everything for 15 minutes.
public actor RenaultPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// Picks the servers and keys; its last two letters are the country (`fr_FR`).
        public var locale: String?
        /// The MyRenault e-mail.
        public var username: String?
        /// The MyRenault password, for a block written by hand (Setup keeps it in the vault).
        public var password: String?
        public var kamereonAccountId: String?
        /// Only these VINs become accessories (moved into Excluded Accessory Settings by `canonicalSettings`).
        public var vins: [String]?
        /// The temperature a climate start asks for, 16 to 27 °C.
        public var climateTemperature: Double?
        public var maxCallsPerHour: Int?
        /// Seconds between rounds; never below the interval the budget gives.
        public var pollInterval: Int?
    }

    struct Dependencies: Sendable {
        var http: any HTTPSending = HTTPClient()
        var timing = RenaultTiming()
    }

    public static let platform = "Renault"
    public static let name = "Renault"
    public static let icon: String? = "battery"
    public static let summary: String? = "Renault, Dacia and Alpine cars: battery, charging, climate, horn and lights"

    static let vehicleKind = "vehicle"
    static let defaultMaxCalls = 60

    let configuration: Configuration
    nonisolated let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    var logger: Logger { context.logger }
    private(set) var session: RenaultSession?
    private(set) var vehicles: [String: RenaultVehicle] = [:]
    private var builtKeys: [String: Set<String>] = [:]
    private var accountID: String?
    private var lastList: ContinuousClock.Instant?
    private var failing = false
    private var loggedCooldown = false
    private var loggedOverride = false
    private var missingLogged: Set<String> = []
    private var savedList: [VehicleInfo]?
    /// The interval of the last round.
    private(set) var currentInterval: Duration?

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        sentSoc = context.persistedDictionary("renault-soc.json", of: SocLevels.self)
    }

    static func accessoryID(vin: String) -> String { "\(platform):\(vin)" }

    var locale: String { configuration.locale.flatMap { $0.isEmpty ? nil : $0 } ?? RenaultLocale.defaultLocale }
    var maxCalls: Int { configuration.maxCallsPerHour ?? Self.defaultMaxCalls }

    /// HA's interval (6.1): the polls' budget (the hour's less the actions' reserve) spread over every poller of every
    /// vehicle, the calls made once an hour (the vehicle list, the SoC levels) kept aside. One R5 (battery and HVAC, 2
    /// hourly) at 60 calls an hour reads every 3600 × 2 / (54 − 2) ≈ 138 s.
    static func pollInterval(pollers: Int, hourly: Int, budget: Int, hour: Duration) -> Duration {
        let spare = max(budget - hourly, 1)
        return hour * max(pollers, 1) / spare
    }

    public func start() async throws {
        tasks.add { [weak self] in await self?.run() }
    }

    public func stop() async {
        tasks.cancelAll()
    }

    // MARK: The account

    /// What the vault holds, with the block's e-mail and password for one written by hand; nil when nothing can sign in.
    nonisolated func storedCredentials() -> RenaultCredentials? {
        var credentials = context.credentials(as: RenaultCredentials.self) ?? RenaultCredentials()
        if credentials.username?.isEmpty != false { credentials.username = configuration.username }
        if credentials.password?.isEmpty != false, let password = configuration.password, !password.isEmpty { credentials.password = password }
        return credentials.canSignIn ? credentials : nil
    }

    private func run() async {
        guard let credentials = storedCredentials() else {
            logger.info("Renault is not set up: sign in to the MyRenault account through Add accessories")
            return
        }
        let context = context, logger = logger
        let session = makeSession(locale: locale, credentials: credentials) { renewed in
            do { try context.saveCredentials(renewed) } catch { logger.error("Could not store Renault's new sign-in in the vault: \(error)") }
        }
        self.session = session
        let backoff = Backoff(initial: dependencies.timing.retry, maximum: dependencies.timing.retryMaximum, jitter: .proportional(0.2))
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await refreshVehicles(session)
                failing = false
                break
            } catch let error as RenaultError where error.isRefusal {
                refuse(error)
                return
            } catch is CancellationError {
                return
            } catch {
                if !failing { logger.error("Could not reach Renault: \(error)") }
                failing = true
                attempt += 1
                await pause(backoff.delay(attempt: attempt - 1))
            }
        }
        while !Task.isCancelled {
            if await round(session) == false { return }
            await pause(currentInterval ?? dependencies.timing.hour)
        }
    }

    /// A session of the account with a budget of its own.
    func makeSession(locale: String, credentials: RenaultCredentials, onCredentialsChange: @escaping @Sendable (RenaultCredentials) -> Void) -> RenaultSession {
        let budget = RequestBudget(maxCallsPerHour: maxCalls, hour: dependencies.timing.hour, cooldown: dependencies.timing.cooldown)
        return RenaultSession(
            http: dependencies.http, locale: locale, credentials: credentials, budget: budget, timing: dependencies.timing, logger: logger,
            onCredentialsChange: onCredentialsChange)
    }

    /// The run task's sleep: `stop()` cancels the task, and the sleep with it.
    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// The account refused: Needs Authorization, and no more requests until Setup is done again.
    func refuse(_ error: RenaultError) {
        context.accountRefused(error.refusalReason)
    }

    /// Every car of the last list, excluded ones included: the one in memory, else the file.
    var knownVehicles: [VehicleInfo] {
        savedList ?? context.jsonFile(Self.vehiclesFile, as: [VehicleInfo].self).load() ?? []
    }

    static let vehiclesFile = "renault-vehicles.json"

    /// The block's `vins`, cleaned; empty for every car.
    var wantedVINs: Set<String> { Set(configuration.vins?.compactMap { VehicleInfo.cleanVIN($0) } ?? []) }

    /// The account (3.6) and its vehicles (3.7), every hour.
    private func refreshVehicles(_ session: RenaultSession) async throws {
        let accountID = try await chooseAccount(session)
        let listed: (vehicles: [VehicleInfo], missing: [String])
        do {
            let known = Dictionary(knownVehicles.map { ($0.vin, $0) }, uniquingKeysWith: { a, _ in a })
            listed = try await session.perform(.poll) { session in try await session.vehicles(accountID: accountID, known: known, .poll) }
        } catch RenaultError.kamereon(let error) where error.code == KamereonError.forbidden && configuration.kamereonAccountId != nil {
            let accounts = (try? await session.perform(.poll) { session in try await session.accounts(.poll) }) ?? []
            if !accounts.isEmpty, !accounts.contains(where: { $0.id == accountID }) {
                throw RenaultError.accountGone
            }
            throw RenaultError.kamereon(error)
        }
        lastList = .now
        for vin in listed.missing {
            if missingLogged.insert(vin).inserted {
                logger.warning("Renault has no details for \(maskedVIN(vin)) yet: it is left out")
            } else {
                logger.debug("Renault still has no details for \(maskedVIN(vin))")
            }
        }
        // An empty list is a server problem, not every car gone (3.7).
        guard !listed.vehicles.isEmpty else { return }
        if listed.vehicles != savedList {
            try? context.jsonFile(Self.vehiclesFile, as: [VehicleInfo].self).save(listed.vehicles)
            savedList = listed.vehicles
        }
        let wanted = wantedVINs
        var keep: Set<String> = []
        for info in listed.vehicles where !context.isExcluded(info.vin) && (wanted.isEmpty || wanted.contains(info.vin)) {
            keep.insert(Self.accessoryID(vin: info.vin))
            guard vehicles[info.vin] == nil else { continue }
            if !ModelEndpoints.isKnown(info.modelCode) {
                logger.warning("The model \(info.modelCode ?? "?") is not documented: using the default endpoints (hacf-fr/renault-api#1747)")
            }
            let store = droppedStore, lock = dropLock, sentSoc = sentSoc, context = context, vin = info.vin
            let settings = context.accessorySettings(for: info.vin)
            var options = RenaultVehicle.Options(climateTemperature: configuration.climateTemperature ?? 21, parts: settings.parts)
            options.socMinimum = settings.plugin["socMin"]?.saturatingIntValue
            options.socTarget = settings.plugin["socTarget"]?.saturatingIntValue
            let vehicle = RenaultVehicle(
                info: info, accountID: accountID, session: session, options: options,
                dropped: Self.dropped(in: store.load() ?? [:], for: info, forgetAfter: dependencies.timing.forgetDropped),
                timing: dependencies.timing, logger: logger, tasks: tasks,
                sentSoc: sentSoc[vin],
                record: { key, value in context.recordValue(value, series: "\(vin):\(key)") },
                onSocSent: { sent in sentSoc[vin] = sent }
            ) { vin, endpoint in
                lock.lock()
                defer { lock.unlock() }
                var all = store.load() ?? [:]
                var entry = all[vin].flatMap { $0.model == info.modelCode ? $0 : nil } ?? DroppedEndpoints(model: info.modelCode, endpoints: [:])
                entry.endpoints[endpoint.rawValue] = Date()
                all[vin] = entry
                try? store.save(all)
            }
            vehicles[info.vin] = vehicle
            logger.info("Found \(info.modelName ?? info.modelCode ?? "a vehicle") \(maskedVIN(info.vin))")
            await publish(vehicle)
        }
        for vin in vehicles.keys where !keep.contains(Self.accessoryID(vin: vin)) {
            vehicles.removeValue(forKey: vin)
            builtKeys.removeValue(forKey: vin)
        }
        _ = await context.removeAccessories(keeping: keep)
        for vehicle in vehicles.values {
            for endpoint in await vehicle.hourlyEndpoints() {
                if case .refused(let error) = await vehicle.read(endpoint, .poll) { throw error }
            }
            await vehicle.applySocLimits()
        }
    }

    private func chooseAccount(_ session: RenaultSession) async throws -> String {
        if let accountID { return accountID }
        if let configured = configuration.kamereonAccountId, !configured.isEmpty {
            accountID = configured
            return configured
        }
        let accounts = try await session.perform(.poll) { session in try await session.accounts(.poll) }
        guard let chosen = accounts.first(where: { $0.type == "MYRENAULT" }) ?? accounts.first else { throw RenaultError.missing("Kamereon account") }
        accountID = chosen.id
        return chosen.id
    }

    /// Adds the vehicle's accessory, or replaces it when its services changed (an endpoint dropped, a temperature seen).
    private func publish(_ vehicle: RenaultVehicle) async {
        let keys = await vehicle.serviceKeys()
        let vin = vehicle.info.vin
        guard builtKeys[vin] != keys else { return }
        let id = Self.accessoryID(vin: vin)
        let previous = context.accessory(id: id)
        guard let accessory = await vehicle.makeAccessory(id: id, firmware: PluginHost.version, previous: previous) else {
            if builtKeys[vin] == nil { logger.info("\(maskedVIN(vin)) has nothing HomeKit can show: it is left out") }
            builtKeys[vin] = keys
            return
        }
        do {
            try context.add(accessory)
            builtKeys[vin] = keys
        } catch {
            logger.error("Could not add \(maskedVIN(vin)): \(error)")
        }
    }

    // MARK: Polling (6.1 to 6.3)

    /// One read of every poller of every vehicle, then the interval for the next; false when the account refused.
    func round(_ session: RenaultSession) async -> Bool {
        if let lastList, ContinuousClock.now - lastList >= dependencies.timing.hour {
            do {
                try await refreshVehicles(session)
            } catch let error as RenaultError where error.isRefusal {
                refuse(error)
                return false
            } catch {
                logger.debug("Could not refresh the vehicle list: \(error)")
                self.lastList = .now
            }
        }
        var pollers = 0, hourly = 1, failures: [String] = [], reads = 0
        for vin in vehicles.keys.sorted() {
            guard let vehicle = vehicles[vin] else { continue }
            for endpoint in await vehicle.roundEndpoints() {
                switch await vehicle.read(endpoint, .poll) {
                case .read: reads += 1
                case .dropped, .skipped: break
                case .failed(let reason): failures.append("\(endpoint.rawValue): \(reason)")
                case .refused(let error):
                    refuse(error)
                    return false
                }
            }
            // After the reads: a dropped endpoint no longer counts.
            pollers += await vehicle.roundEndpoints().count
            hourly += await vehicle.hourlyEndpoints().count
            await publish(vehicle)
        }
        if await session.budget.isCoolingDown {
            if !loggedCooldown { logger.warning("Renault's quota is reached: polling pauses for 15 minutes") }
            loggedCooldown = true
        } else {
            loggedCooldown = false
        }
        if !failures.isEmpty, reads == 0 {
            if !failing { logger.warning("Could not read the vehicles: \(failures.joined(separator: "; "))") }
            failing = true
        } else if !failures.isEmpty {
            logger.debug("Some reads failed: \(failures.joined(separator: "; "))")
        } else if reads > 0 {
            if failing { logger.info("Renault answers again") }
            failing = false
        }
        let budget = await session.budget.pollBudget
        var interval = Self.pollInterval(pollers: pollers, hourly: hourly, budget: budget, hour: dependencies.timing.hour)
        if let override = configuration.pollInterval, override > 0 {
            let asked = Duration.seconds(override)
            if asked < interval, !loggedOverride {
                logger.warning("pollInterval \(override) s would spend more than Renault's hourly quota: polling every \(interval) instead")
                loggedOverride = true
            }
            interval = max(asked, interval)
        }
        currentInterval = interval
        for vehicle in vehicles.values { await vehicle.updateAvailability(limit: interval * 3) }
        return true
    }

    // MARK: Dropped endpoints, remembered (6.3)

    struct DroppedEndpoints: Codable, Sendable {
        var model: String?
        var endpoints: [String: Date]
    }

    /// The state-of-charge limits last sent to each car, by VIN (`renault-soc.json`): sent once per change of its
    /// Accessory Settings.
    nonisolated let sentSoc: PersistedDictionary<SocLevels>

    /// Vehicles drop endpoints from their own actors: one read-modify-write of the file at a time.
    nonisolated let dropLock = NSLock()

    nonisolated var droppedStore: JSONFile<[String: DroppedEndpoints]> {
        context.jsonFile("renault-endpoints.json", as: [String: DroppedEndpoints].self)
    }

    /// What this car did not have, forgotten when its model changed or after `forgetAfter`.
    static func dropped(in all: [String: DroppedEndpoints], for info: VehicleInfo, forgetAfter: Duration, now: Date = Date()) -> Set<Endpoint> {
        guard let entry = all[info.vin], entry.model == info.modelCode else { return [] }
        let limit = Double(forgetAfter.components.seconds)
        return Set(entry.endpoints.compactMap { key, date in now.timeIntervalSince(date) < limit ? Endpoint(rawValue: key) : nil })
    }
}
