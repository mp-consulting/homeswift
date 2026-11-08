import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The EcoFlow devices on your account (STREAM, RIVER, DELTA, RAPID, PowerOcean…; EcoFlowModel lists them): each one is
/// a Battery on its own accessory, with its state of charge and whether it is charging. The power the devices report is
/// watts that HomeKit has no characteristic for, so it is shown on the plugin's page instead.
///
/// The plugin reads the developer API (https://developer.ecoflow.com, with its access key and secret key) and the
/// EcoFlow app's own sign-in (with the account's email and password), as the route setting says; each device comes
/// from one of them. See README.md in this directory.
public actor EcoFlowPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            public var id: String
            /// Overrides the name the device reports.
            public var name: String?
        }

        public var name: String?
        /// `both` (the default): every API with its settings, each device from the one that reports it, the developer
        /// API first. `developer`: the developer API alone. `app`: the EcoFlow app's sign-in alone.
        public var route: String?
        /// The EcoFlow account email, for the app route.
        public var email: String?
        /// The EcoFlow account password, for the app route: in the vault (Setup); a block's still works, moved there by
        /// `canonicalSettings`.
        public var password: String?
        /// The developer access key, likewise in the vault.
        public var accessKey: String?
        /// The developer secret key, likewise in the vault.
        public var secretKey: String?
        /// `us` or `eu`: the region the developer account was created in. `us` by default.
        public var region: String?
        /// Whether the EcoFlow cloud's energy history (each hour's solar and home use since the system was set up) goes
        /// into the Status page's month and year views. Needs the app's email and password; true by default.
        public var importHistory: Bool?
        /// Seconds between reads of the developer API; 30 at least, 60 by default. The app's stream is read every few
        /// seconds whatever this is.
        public var pollingInterval: Int?
        /// Serial numbers with names, read first by the app's route; `canonicalSettings` moves the names into each device's
        /// Accessory Settings.
        public var devices: [Device]?
    }

    /// What the plugin uses to reach its devices; tests swap it for a fake.
    struct Dependencies: Sendable {
        var api: (any EcoFlowAPI)?
        /// The developer API for keys Setup is given, to check them before they are kept; tests answer for the cloud.
        var developerAPI: @Sendable (_ accessKey: String, _ secretKey: String, _ region: String?) -> any EcoFlowAPI = { accessKey, secretKey, region in
            EcoFlowCloud(accessKey: accessKey, secretKey: secretKey, baseURL: region?.lowercased() == "eu" ? EcoFlowCloud.euBaseURL : EcoFlowCloud.usBaseURL, transport: HTTPClient())
        }
        /// The EcoFlow app's sign-in for an email and password Setup is given, to check them before they are kept.
        var appSignIn: @Sendable (_ email: String, _ password: String) async throws -> Void = { email, password in
            let app = EcoFlowAppAPI(email: email, password: password, serials: [], transport: HTTPClient(), mqtt: { MQTTClient($0) })
            do {
                try await app.checkSignIn()
            } catch {
                await app.stop()
                throw error
            }
            await app.stop()
        }
        /// The cloud's energy history, with the app's sign-in; nil without it or with `importHistory` false.
        var history: EcoFlowHistory? = nil
    }

    /// How far the energy history was imported, in the plugin's storage.
    struct HistoryState: Codable, Equatable {
        /// When the last whole import ended: the next one starts `historyOverlap` before it. Nil while a full import
        /// (the first, or one made again) has not finished.
        var importedThrough: Date?
        /// The history's first hour (absent from files of the first version).
        var from: Date?
        /// `historyVersion` once the history goes in through the STREAM's Meters. A file without it (the first version)
        /// had the home's flows in the archive under the plugin's own key, which the first import of this version
        /// drops, once: the two would be added to one another.
        var version: Int?
        /// The STREAM whose Meters hold the history, as it was resolved: kept, so a later run that would choose
        /// another (the devices reported in another order) does not put the same hours on two systems' Meters.
        var serial: String?
        /// A full import under way: the month it goes on from, saved as each month is done.
        var resumeFrom: Date?
        /// Whether the system's battery and grid charts answer: true once they did, false once they were refused and
        /// the import went on without them; nil while not known.
        var twoWay: Bool?
        /// How many imports running found those charts refused while they might still answer.
        var refusals: Int?
    }

    /// The import under way: what its months found, as they arrive.
    struct HistoryPass {
        var state: HistoryState
        let full: Bool
        /// The first month whose battery and grid charts were refused while they might answer: progress is saved up to
        /// it, so the next import reads it again.
        var stoppedAt: Date?
        var answered = false
        var refused = false
    }

    /// Between two imports of the history's last days; and the days each one takes again (the cloud fills hours in late).
    static let historyInterval: Duration = .seconds(6 * 3600)
    /// After a failed import, the next attempt: the cloud's failures pass.
    static let historyRetry: Duration = .seconds(600)
    static let historyOverlap: TimeInterval = 2 * 86_400
    static let historyFile = "energy-history.json"
    /// The energy history's version: 2 on the STREAM's Meters.
    static let historyVersion = 2
    /// The imports in a row that may find the battery and grid charts refused before the history goes on without them
    /// (a system without those pages is refused every time).
    static let historyRefusals = 3
    /// The Energy Roles of a STREAM's Meters, each with the key it is declared under (the role's name).
    static let historyRoles: [EnergyRole] = [.solar, .home, .grid, .battery]
    /// The order of the devices on the plugin's page, by serial number, as it was last dragged into.
    static let orderFile = "order.json"
    /// At most this many serial numbers are kept: an account has a handful of devices.
    static let maximumOrdered = 200

    /// A device's services on its accessory.
    struct DeviceServices {
        let battery: Service
    }

    public static let platform = "EcoFlow"

    public static let icon: String? = "logo-ecoflow"
    public static let summary: String? = "Power stations and home batteries: charge, and their power live"
    public static let name = "EcoFlow"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let defaultPollingInterval = 60
    static let minimumPollingInterval = 30

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    /// Each device's services, by device id.
    private var devices: [String: DeviceServices] = [:]
    /// The devices as the last read reported them, for the plugin's page.
    private(set) var latest: [EcoFlowDevice] = []
    /// The page's order, each serial number's place, read from `orderFile` once and kept as it is saved.
    private var orderPlaces: [String: Int]?
    /// Each device's `recorded` series, with the name and route they were made for.
    private var recordedSeries: [String: (name: String, route: EcoFlowModel.Route, keys: [String: Recorded])] = [:]
    /// The energy history's import under way.
    private var historyPass: HistoryPass?
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context,
                  dependencies: Self.dependencies(
                    for: Self.withStoredKeys(configuration, context), serials: Self.configuredSerials(configuration, context).map(\.id),
                    clientSuffix: Self.clientSuffix(context)))
    }

    /// The devices config.json names, with their names: a Homebridge block's `devices`, then the devices with Accessory
    /// Settings (where `canonicalSettings` moves them); an Excluded one is left out.
    static func configuredSerials(_ configuration: Configuration, _ context: PluginContext) -> [(id: String, name: String?)] {
        var devices = (configuration.devices ?? []).map { (id: $0.id, name: $0.name) }
        for (id, settings) in context.allAccessorySettings.sorted(by: { $0.key < $1.key })
        where !devices.contains(where: { $0.id == id }) && EcoFlowModel.model(serial: id) != nil {
            devices.append((id: id, name: settings.name))
        }
        return devices.filter { !context.isExcluded($0.id) }
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    /// The route's APIs whose settings are present, read together: the developer API (access key and secret key) and
    /// the EcoFlow app (email and password). No api while none is set.
    /// This bridge's part of the developer MQTT client id (EcoFlowDeveloperStream.clientID): made once, then kept in the
    /// plugin's storage, so it is the same at every connection.
    static let clientFile = "mqtt-client.json"
    static func clientSuffix(_ context: PluginContext) -> String {
        let file = context.jsonFile(clientFile, as: String.self)
        if let kept = file.load(), !kept.isEmpty { return kept }
        let suffix = Secrets.hex(Secrets.randomBytes(4))
        try? file.save(suffix)
        return suffix
    }

    /// `serials`: the devices the app's route subscribes to before those the account lists (`configuredSerials`), a
    /// Homebridge block's `devices` by default.
    static func dependencies(for configuration: Configuration, serials: [String]? = nil, clientSuffix: String = "") -> Dependencies {
        let route = Route(configuration.route)
        var apis: [any EcoFlowAPI] = []
        // The developer API first: a device both APIs report is read from it.
        if let (accessKey, secretKey) = developerKeys(configuration) {
            let baseURL = configuration.region?.lowercased() == "eu" ? EcoFlowCloud.euBaseURL : EcoFlowCloud.usBaseURL
            var cloud = EcoFlowCloud(accessKey: accessKey, secretKey: secretKey, baseURL: baseURL, transport: HTTPClient())
            cloud.stream = EcoFlowDeveloperStream(cloud: cloud, clientSuffix: clientSuffix, mqtt: { MQTTClient($0) })
            apis.append(cloud)
        }
        if route != .developer, let email = configuration.email, !email.isEmpty,
           let password = configuration.password, !password.isEmpty {
            apis.append(EcoFlowAppAPI(
                email: email, password: password, serials: serials ?? (configuration.devices ?? []).map(\.id), transport: HTTPClient(),
                mqtt: { MQTTClient($0) }))
        }
        var history: EcoFlowHistory?
        if route != .developer, configuration.importHistory != false, let email = configuration.email, !email.isEmpty,
           let password = configuration.password, !password.isEmpty {
            history = EcoFlowHistory(email: email, password: password, transport: HTTPClient())
        }
        switch apis.count {
        case 0: return Dependencies(api: nil, history: history)
        case 1: return Dependencies(api: apis[0], history: history)
        default:
            // The developer API keeps its polling interval while the app's stream is read every few seconds.
            let interval = Duration.seconds(developerInterval(configuration))
            return Dependencies(api: EcoFlowAll(apis: apis, intervals: [0: interval]), history: history)
        }
    }

    /// The app's stream is already open, so its latest readings are taken every few seconds (realtime). The developer
    /// API makes a request per device, so it keeps `pollingInterval`: alone, that is the poll; with the app's stream,
    /// the poll is the stream's, and the developer API answers from its last read in between (EcoFlowAll).
    var pollingInterval: Duration {
        if dependencies.api is EcoFlowCloud {
            return .seconds(Self.developerInterval(configuration))
        }
        return Self.streamInterval
    }

    /// Seconds between reads of the developer API.
    static func developerInterval(_ configuration: Configuration) -> Int {
        max(configuration.pollingInterval ?? defaultPollingInterval, minimumPollingInterval)
    }

    static let streamInterval: Duration = .seconds(3)

    /// The developer keys, when the route reads the developer API and both are set.
    static func developerKeys(_ configuration: Configuration) -> (accessKey: String, secretKey: String)? {
        guard Route(configuration.route) != .app, let accessKey = configuration.accessKey, !accessKey.isEmpty,
              let secretKey = configuration.secretKey, !secretKey.isEmpty else { return nil }
        return (accessKey, secretKey)
    }

    /// The name the configuration gives the device, else the one it reports.
    private func displayName(_ device: EcoFlowDevice) -> String {
        configuration.devices?.first { $0.id == device.id }?.name ?? device.name
    }

    /// Which APIs the plugin reads; anything else than `developer` or `app` reads both.
    enum Route: Equatable {
        case both, developer, app

        init(_ setting: String?) {
            switch setting?.lowercased() {
            case "developer": self = .developer
            case "app": self = .app
            default: self = .both
            }
        }
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    public func start() async throws {
        guard dependencies.api != nil else {
            switch Route(configuration.route) {
            case .developer: logger.error("route developer needs accessKey and secretKey: create them at developer.ecoflow.com")
            case .app: logger.error("route app needs email and password")
            case .both: logger.error("Set the developer keys (accessKey and secretKey, from developer.ecoflow.com) or the EcoFlow app's email and password")
            }
            return
        }
        let interval = pollingInterval
        tasks.add { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
        if let history = dependencies.history {
            // What earlier runs imported, on the Status page from the start.
            if let state = context.jsonFile(Self.historyFile, as: HistoryState.self).load() {
                context.reportEnergyImport(EnergyImportProgress(state: .done, from: state.from, through: state.importedThrough))
            }
            tasks.add { [weak self] in await self?.importHistoryLoop(history) }
        }
    }

    /// The EcoFlow cloud's energy history into the bridge's long-term archive (the history is a STREAM's home's):
    /// everything since the system was set up on the first run, then the last days again every `historyInterval`.
    private func importHistoryLoop(_ history: EcoFlowHistory) async {
        while !Task.isCancelled {
            let imported = await importHistory(history, serial: historySerial(remembered: context.jsonFile(Self.historyFile, as: HistoryState.self).load()?.serial))
            // The answers whose shape changed, and a chart the cloud stopped answering: each logged once.
            for change in await history.schemas.drain() { logger.warning("\(change)") }
            try? await Task.sleep(for: imported ? Self.historyInterval : Self.historyRetry)
        }
    }

    /// The STREAM whose home's history is imported, the same from one run to the next: one the configuration's
    /// `devices` names, else the one an earlier import used (`remembered`), else the first by serial number of those
    /// that reported, then of those with Accessory Settings; an Excluded one never. Nil leaves the choice to the app's
    /// device list, so no device has to report, nor be listed, for the import to run.
    func historySerial(remembered: String?) -> String? {
        let context = context
        let stream = { (id: String) in EcoFlowModel.model(serial: id)?.kind == .stream && !context.isExcluded(id) }
        if let named = (configuration.devices ?? []).map(\.id).first(where: stream) { return named }
        if let remembered, stream(remembered) { return remembered }
        return latest.map(\.id).filter(stream).sorted().first
            ?? Self.configuredSerials(configuration, context).map(\.id).filter(stream).sorted().first
    }

    /// One import: from where the last one stopped (`historyOverlap` before it), or from the start. Each month goes onto
    /// the STREAM's Meters as it arrives, with its progress; the Status page shows both. `serial` is the STREAM asked
    /// for (`historySerial(remembered:)`), nil for the app's device list's. Returns whether it succeeded.
    @discardableResult
    func importHistory(_ history: EcoFlowHistory, serial: String?, now: Date = Date()) async -> Bool {
        let file = context.jsonFile(Self.historyFile, as: HistoryState.self)
        let previous = file.load()
        var state = previous ?? HistoryState()
        let context = context
        // A history of the first version went in as the home's flows: dropped, once (the Meters' hours would be added
        // to it), and read again from the start, since it went back further than a top-up reaches. A file that is gone
        // may have been of either version: dropping what is not there costs nothing.
        if state.version != Self.historyVersion {
            context.forgetImportedEnergy()
            if previous != nil {
                logger.info("The energy history is imported through the STREAM's meters now: reading it again from the EcoFlow cloud, from the start")
            }
            state = HistoryState(version: Self.historyVersion)
            try? file.save(state)
        }
        do {
            let serial = try await history.serial(serial, excluding: { context.isExcluded($0) })
            if let old = state.serial, old != serial {
                // Another STREAM's Meters from now on: what the old one's hold would be counted beside the same hours.
                for role in Self.historyRoles { context.forgetImportedHours(ofMeter: role.rawValue, deviceID: old) }
                logger.info("The energy history is now imported onto STREAM \(serial)'s meters, not \(old)'s: reading it again from the start")
                state = HistoryState(version: Self.historyVersion)
            }
            if state.serial != serial {
                state.serial = serial
                try? file.save(state)
            }
            let full = state.importedThrough == nil
            let since = state.importedThrough.map { $0.addingTimeInterval(-Self.historyOverlap) } ?? state.resumeFrom
            historyPass = HistoryPass(state: state, full: full)
            defer { historyPass = nil }
            let hours = try await history.hours(serial: serial, since: since, now: now) { [weak self] month in
                await self?.importHistoryMonth(month, file: file)
            }
            guard let pass = historyPass else { return false }
            state = pass.state
            if pass.answered { state.twoWay = true }
            if let stopped = pass.stoppedAt {
                // Months without the battery and the grid: not done. A full import goes on from that month; a top-up
                // keeps where the last whole one ended, and reads the same days again.
                state.refusals = (state.refusals ?? 0) + 1
                if full { state.resumeFrom = stopped }
                try? file.save(state)
                let message = "the EcoFlow cloud refused the battery and grid history charts from \(Timestamp.iso8601(stopped).prefix(7)) on: reading them again later"
                context.reportEnergyImport(EnergyImportProgress(state: .failed, from: state.from, through: state.importedThrough, message: message))
                logger.warning("Could not import the whole energy history, trying again in 10 minutes: \(message)")
                return false
            }
            // Refused, and no longer asked again: the system has no such pages, or they are gone. Answered since, it
            // is asked again.
            if pass.refused { state.twoWay = false }
            state.refusals = nil
            state.resumeFrom = nil
            state.importedThrough = now
            if state.from == nil { state.from = hours.first?.start }
            try? file.save(state)
            context.reportEnergyImport(EnergyImportProgress(state: .done, from: state.from, through: now))
            if full, let first = hours.first?.start {
                logger.info("Imported \(hours.count) hours of energy history (solar, home use, and the battery and grid where the cloud has them) from the EcoFlow cloud, since \(Timestamp.iso8601(first).prefix(10))")
            } else {
                logger.debug("Imported \(hours.count) hours of energy history from the EcoFlow cloud")
            }
            return true
        } catch EcoFlowHistory.Failure.noStream {
            // No STREAM on the account: nothing to import, and nothing failed. Looked at again at the usual interval;
            // what the first version imported was dropped once, above, and is not again.
            logger.debug("No energy history to import: the EcoFlow account has no STREAM")
            return true
        } catch {
            context.reportEnergyImport(EnergyImportProgress(state: .failed, from: state.from, through: state.importedThrough, message: "\(error)"))
            logger.warning("Could not import the energy history from the EcoFlow cloud, trying again in 10 minutes: \(error)")
            return false
        }
    }

    /// A month of the history: each Energy Role's figures onto the STREAM's Meter of that role (`EnergyRole.meterHour`),
    /// so the Consumption by device card has the cloud's past too. The runtime puts a Meter's hours in the Home Energy
    /// itself, so the home's flows are not imported beside them. A full import saves where it is after each month, so
    /// one that fails goes on from there.
    private func importHistoryMonth(_ month: EcoFlowHistory.Month, file: JSONFile<HistoryState>) {
        guard var pass = historyPass else { return }
        defer { historyPass = pass }
        if month.done > 0 {
            for role in Self.historyRoles {
                let rows = month.hours.compactMap(role.meterHour(of:))
                guard !rows.isEmpty else { continue }
                // Named by its serial number: the name only counts for the power a device reports, which declares the
                // Meter with its own.
                context.meter(role.rawValue, deviceID: month.serial, device: month.serial, suggestedRole: role).importHours(rows)
            }
            if month.twoWay { pass.answered = true } else { pass.refused = true }
            // Charts that answered (before, or earlier in this import) and are refused now may answer again: a few
            // imports try them, then the history goes on without them.
            let mayAnswer = (pass.state.twoWay != false || pass.answered) && (pass.state.refusals ?? 0) < Self.historyRefusals
            if !month.twoWay, mayAnswer, pass.stoppedAt == nil { pass.stoppedAt = month.start }
            if pass.state.from == nil, let first = month.hours.first?.start { pass.state.from = first }
            if pass.full, pass.stoppedAt == nil, let next = month.next {
                pass.state.resumeFrom = next
                try? file.save(pass.state)
            }
        }
        context.reportEnergyImport(EnergyImportProgress(state: .running, done: month.done, total: month.total, from: pass.state.from ?? month.hours.first?.start,
                                                        through: month.hours.last?.start ?? pass.state.importedThrough))
    }

    public func stop() async {
        tasks.cancelAll()
        await dependencies.api?.stop()
    }

    /// The endpoints whose answers changed shape since the last refresh, logged once per change.
    private func logSchemaChanges(_ api: any EcoFlowAPI) async {
        for change in await api.schemaChanges() { logger.warning("\(change)") }
    }

    /// Adds an accessory for each new device and shows the values of the others.
    func refresh() async {
        guard let api = dependencies.api else { return }
        let reported: [EcoFlowDevice]
        do {
            // An Excluded device is neither recorded nor added: the runtime would refuse its accessory.
            reported = try await api.devices().filter { !context.isExcluded($0.id) }
        } catch {
            logger.warning("Could not read the devices: \(error)")
            await logSchemaChanges(api)
            return
        }
        await logSchemaChanges(api)
        latest = reported
        // The history: each online device's readings, for the Status page's graphs (a minute keeps their range).
        for device in reported where device.online {
            for (key, value) in device.series {
                switch recorded(device, key) {
                // A home system's flow is a Meter, in `EnergyRole`'s signs as EcoFlow reports them.
                case let .meter(meter): meter.record(watts: value)
                case let .series(series, tag): context.recordValue(value, series: series, energy: tag)
                }
            }
            if device.state.knowsBatteryLevel, case let .series(series, tag) = recorded(device, "level") {
                context.recordValue(Double(device.state.battery.batteryLevel), series: series, energy: tag)
            }
        }
        for device in reported {
            if let services = devices[device.id] {
                Self.show(device.state, on: services)
                continue
            }
            // A device whose level is not known yet (offline since the plugin started, a STREAM on the developer API's
            // REST quota alone) waits: a new accessory would show 0 %, where a cached one keeps its last level. The
            // plugin's page shows it meanwhile.
            guard device.state.knowsBatteryLevel else { continue }
            do {
                try add(device)
            } catch {
                logger.error("Could not add \(device.name): \(error)")
            }
        }
        // TODO: once a device is known to be gone, `context.removeAccessories(keeping:)` drops its accessory.
    }

    /// Where a reading goes: a Meter (a home system's flow, with its Energy Role) or a plain series (a station's port,
    /// the battery's level).
    enum Recorded {
        case meter(PluginMeter)
        case series(RecordedSeries, EnergyTag?)
    }

    /// A reading's Meter or series, made once: a refresh records some thirty readings every few seconds. A device's
    /// are made again when its name or route changes (the tags carry the name). A Meter keeps the series name the
    /// reading had before it was one, so the Status page's history carries on.
    private func recorded(_ device: EcoFlowDevice, _ key: String) -> Recorded {
        if let known = recordedSeries[device.id], known.name == device.name, known.route == device.route, let recorded = known.keys[key] {
            return recorded
        }
        if recordedSeries[device.id]?.name != device.name || recordedSeries[device.id]?.route != device.route {
            recordedSeries[device.id] = (device.name, device.route, [:])
        }
        let recorded: Recorded
        if key == "level" {
            recorded = .series(context.series("\(device.id):\(key)"), EnergyTag(role: .batteryLevel, device: device.name))
        } else if let tag = device.energyTag(key) {
            recorded = .meter(context.meter(key, deviceID: device.id, device: device.name, suggestedRole: tag.role, shared: tag.shared))
        } else {
            recorded = .series(context.series("\(device.id):\(key)"), nil)
        }
        recordedSeries[device.id]?.keys[key] = recorded
        return recorded
    }

    /// The plugin's page: `GET power` answers the devices' power flows, in watts, with the battery's state, in the
    /// page's order; `POST order` keeps a new order (`ids`, the serial numbers from first to last).
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "power"): return power()
        case ("POST", "order"):
            guard let ids = request.body["ids"]?.arrayValue?.compactMap(\.stringValue), ids.count <= Self.maximumOrdered else {
                return .error(400, "ids must list the devices' serial numbers")
            }
            try context.jsonFile(Self.orderFile, as: [String].self).save(ids)
            orderPlaces = Self.places(ids)
            return PluginWebResponse(.object(["ids": .array(ids.map { .string($0) })]))
        default: return .error(404, "EcoFlow has no web API at \(request.path)")
        }
    }

    /// The devices in the page's order: the ones it placed first, then the others as they were reported.
    func ordered(_ devices: [EcoFlowDevice]) -> [EcoFlowDevice] {
        if orderPlaces == nil { orderPlaces = Self.places(context.jsonFile(Self.orderFile, as: [String].self).load() ?? []) }
        let place = orderPlaces ?? [:]
        // The devices it has not placed come after the last place, as reported.
        let after = (place.values.max() ?? -1) + 1
        return devices.enumerated().sorted { a, b in
            (place[a.element.id] ?? after + a.offset, a.offset) < (place[b.element.id] ?? after + b.offset, b.offset)
        }.map(\.element)
    }

    /// Each serial number's place in an order, the first one kept when it appears twice.
    static func places(_ order: [String]) -> [String: Int] {
        Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
    }

    private func power() -> PluginWebResponse {
        let devices: [JSONValue] = ordered(latest).map { device in
            let power = device.state.power
            return .object([
                "id": .string(device.id),
                "name": .string(displayName(device)),
                "online": .bool(device.online),
                "source": .string(device.source.rawValue),
                "batteryLevel": device.state.knowsBatteryLevel ? .number(Double(device.state.battery.batteryLevel)) : .null,
                "charging": .bool(device.state.battery.chargingState == 1),
                // Minutes to full while charging, to empty otherwise, as the device estimates them.
                "minutesRemaining": device.state.minutesRemaining.map { .number($0.rounded()) } ?? .null,
                "solar": .number(power.solar),
                "home": .number(power.home),
                "grid": .number(power.grid),
                "battery": .number(power.battery),
                "panels": .array(device.panels.map { .number($0) }),
                "kind": .string(device.kind.rawValue),
                "model": device.model.map { .string($0.name) } ?? .null,
                // A model mapped from open-source projects, not yet checked on a real device on this route.
                "tested": .bool(device.tested),
                // The keys of the readings the page graphs, so it asks for their history and no other.
                "series": .array(device.series.map(\.key).filter { !$0.hasPrefix("pv") }.map { .string($0) }),
                "input": .number(power.input),
                "output": .number(power.output),
                "acIn": .number(power.acIn),
                "acOut": .number(power.acOut),
                "usbA": .number(power.usbA),
                "usbC": .number(power.usbC),
                "ac": .number(power.ac),
                "ac1": .number(power.ac1),
                "ac2": .number(power.ac2),
            ])
        }
        // The configured devices with no readings yet: the page shows a placeholder for each while they arrive (the
        // app's stream reports a few seconds after the developer API).
        let reported = Set(latest.map(\.id))
        let waiting: [JSONValue] = Self.configuredSerials(configuration, context).filter { !reported.contains($0.id) }.map { device in
            .object(["id": .string(device.id), "name": device.name.map { .string($0) } ?? .null,
                     "model": EcoFlowModel.model(serial: device.id).map { .string($0.name) } ?? .null])
        }
        return PluginWebResponse(.object(["devices": .array(devices), "waiting": .array(waiting)]))
    }

    /// Sets each characteristic from the device's state; HomeKit hears of the values that changed.
    static func show(_ state: EcoFlowState, on services: DeviceServices) {
        // Without the level, the level and the low flag keep what they were rather than show 0 %.
        if state.knowsBatteryLevel {
            services.battery.characteristic(.statusLowBattery).value = .int(state.battery.statusLowBattery)
            services.battery.characteristic(.batteryLevel).value = .int(state.battery.batteryLevel)
        }
        services.battery.characteristic(.chargingState).value = .int(state.battery.chargingState)
    }

    private func add(_ device: EcoFlowDevice) throws {
        let name = displayName(device)
        let battery = Service(.battery, name: name, optional: [.batteryLevel, .chargingState], isPrimary: true)
        let services = DeviceServices(battery: battery)
        Self.show(device.state, on: services)
        try context.add(Accessory(
            id: Self.accessoryID(deviceID: device.id), name: name, manufacturer: "EcoFlow", model: device.model?.name ?? device.name,
            serialNumber: device.id, category: .other, services: [battery]))
        devices[device.id] = services
    }
}
