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
        /// The EcoFlow account password, for the app route. Stored in config.json, which only the bridge's owner can read.
        public var password: String?
        /// The developer access key.
        public var accessKey: String?
        /// The developer secret key. Stored in config.json, which only the bridge's owner can read.
        public var secretKey: String?
        /// `us` or `eu`: the region the developer account was created in. `us` by default.
        public var region: String?
        /// Whether the EcoFlow cloud's energy history (each hour's solar and home use since the system was set up) goes
        /// into the Status page's month and year views. Needs the app's email and password; true by default.
        public var importHistory: Bool?
        /// Seconds between reads of the developer API; 30 at least, 60 by default. The app's stream is read every few
        /// seconds whatever this is.
        public var pollingInterval: Int?
        public var devices: [Device]?
    }

    /// What the plugin uses to reach its devices; tests swap it for a fake.
    struct Dependencies: Sendable {
        var api: (any EcoFlowAPI)?
        /// The cloud's energy history, with the app's sign-in; nil without it or with `importHistory` false.
        var history: EcoFlowHistory? = nil
    }

    /// How far the energy history was imported, in the plugin's storage.
    struct HistoryState: Codable, Equatable {
        var importedThrough: Date
        /// The history's first hour (absent from files of the first version).
        var from: Date?
    }

    /// Between two imports of the history's last days; and the days each one takes again (the cloud fills hours in late).
    static let historyInterval: Duration = .seconds(6 * 3600)
    /// After a failed import, the next attempt: the cloud's failures pass.
    static let historyRetry: Duration = .seconds(600)
    static let historyOverlap: TimeInterval = 2 * 86_400
    static let historyFile = "energy-history.json"
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
    private var latest: [EcoFlowDevice] = []
    /// Each device's `recorded` series, with the name and route they were made for.
    private var recordedSeries: [String: (name: String, route: EcoFlowModel.Route, keys: [String: (series: RecordedSeries, tag: EnergyTag?)])] = [:]
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Self.dependencies(for: configuration))
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    /// The route's APIs whose settings are present, read together: the developer API (access key and secret key) and
    /// the EcoFlow app (email and password). No api while none is set.
    static func dependencies(for configuration: Configuration) -> Dependencies {
        let route = Route(configuration.route)
        var apis: [any EcoFlowAPI] = []
        // The developer API first: a device both APIs report is read from it.
        if let (accessKey, secretKey) = developerKeys(configuration) {
            let baseURL = configuration.region?.lowercased() == "eu" ? EcoFlowCloud.euBaseURL : EcoFlowCloud.usBaseURL
            var cloud = EcoFlowCloud(accessKey: accessKey, secretKey: secretKey, baseURL: baseURL, transport: HTTPClient())
            cloud.stream = EcoFlowDeveloperStream(cloud: cloud, mqtt: { MQTTClient($0) })
            apis.append(cloud)
        }
        if route != .developer, let email = configuration.email, !email.isEmpty,
           let password = configuration.password, !password.isEmpty {
            apis.append(EcoFlowAppAPI(
                email: email, password: password, serials: (configuration.devices ?? []).map(\.id), transport: HTTPClient(),
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
            let imported = await importHistory(history, serial: historySerial)
            try? await Task.sleep(for: imported ? Self.historyInterval : Self.historyRetry)
        }
    }

    /// The STREAM whose home's history is imported: one that reported, else one configured. Nil leaves the choice to
    /// the app's device list, so no device has to report, nor be listed, for the import to run.
    var historySerial: String? {
        latest.first { $0.kind == .stream }?.id
            ?? configuration.devices?.first { EcoFlowModel.model(serial: $0.id)?.kind == .stream }?.id
    }

    /// One import: from where the last one stopped (`historyOverlap` before it), or from the start. Each month goes into
    /// the archive as it arrives, with its progress; the Status page shows both. Returns whether it succeeded.
    @discardableResult
    func importHistory(_ history: EcoFlowHistory, serial: String?, now: Date = Date()) async -> Bool {
        let file = context.jsonFile(Self.historyFile, as: HistoryState.self)
        let previous = file.load()
        let context = context
        // The progress shows from the first month's report on: an account without a STREAM has no import to show.
        do {
            let hours = try await history.hours(serial: serial, since: previous.map { $0.importedThrough.addingTimeInterval(-Self.historyOverlap) }, now: now) { batch, done, total in
                if !batch.isEmpty { context.importEnergy(batch) }
                context.reportEnergyImport(EnergyImportProgress(state: .running, done: done, total: total, from: previous?.from ?? batch.first?.start,
                                                                through: batch.last?.start ?? previous?.importedThrough))
            }
            // The history's start: the first import's first hour, kept across top-ups.
            let from = previous?.from ?? hours.first?.start
            try? file.save(HistoryState(importedThrough: now, from: from))
            context.reportEnergyImport(EnergyImportProgress(state: .done, from: from, through: now))
            if previous == nil, let first = hours.first?.start {
                logger.info("Imported \(hours.count) hours of energy history (solar and home use) from the EcoFlow cloud, since \(Timestamp.iso8601(first).prefix(10))")
            } else {
                logger.debug("Imported \(hours.count) hours of energy history from the EcoFlow cloud")
            }
            return true
        } catch EcoFlowHistory.Failure.noStream {
            // No STREAM on the account: nothing to import, and nothing failed. Looked at again at the usual interval.
            logger.debug("No energy history to import: the EcoFlow account has no STREAM")
            return true
        } catch {
            context.reportEnergyImport(EnergyImportProgress(state: .failed, from: previous?.from, through: previous?.importedThrough, message: "\(error)"))
            logger.warning("Could not import the energy history from the EcoFlow cloud, trying again in 10 minutes: \(error)")
            return false
        }
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
            reported = try await api.devices()
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
                let recorded = recorded(device, key)
                context.recordValue(value, series: recorded.series, energy: recorded.tag)
            }
            if device.state.knowsBatteryLevel {
                let recorded = recorded(device, "level")
                context.recordValue(Double(device.state.battery.batteryLevel), series: recorded.series, energy: recorded.tag)
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

    /// A reading's series, named once, and its energy tag: a refresh records some thirty readings every few seconds.
    /// A device's are made again when its name or route changes (the tags carry the name).
    private func recorded(_ device: EcoFlowDevice, _ key: String) -> (series: RecordedSeries, tag: EnergyTag?) {
        if let known = recordedSeries[device.id], known.name == device.name, known.route == device.route, let recorded = known.keys[key] {
            return recorded
        }
        if recordedSeries[device.id]?.name != device.name || recordedSeries[device.id]?.route != device.route {
            recordedSeries[device.id] = (device.name, device.route, [:])
        }
        let tag = key == "level" ? EnergyTag(role: .batteryLevel, device: device.name) : device.energyTag(key)
        let recorded = (series: context.series("\(device.id):\(key)"), tag: tag)
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
            return PluginWebResponse(.object(["ids": .array(ids.map { .string($0) })]))
        default: return .error(404, "EcoFlow has no web API at \(request.path)")
        }
    }

    /// The devices in the page's order: the ones it placed first, then the others as they were reported.
    func ordered(_ devices: [EcoFlowDevice]) -> [EcoFlowDevice] {
        let order = context.jsonFile(Self.orderFile, as: [String].self).load() ?? []
        let place = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        return devices.enumerated().sorted { a, b in
            (place[a.element.id] ?? order.count + a.offset, a.offset) < (place[b.element.id] ?? order.count + b.offset, b.offset)
        }.map(\.element)
    }

    private func power() -> PluginWebResponse {
        let listed = Set((configuration.devices ?? []).map(\.id))
        let devices: [JSONValue] = ordered(latest).map { device in
            let power = device.state.power
            return .object([
                "id": .string(device.id),
                "name": .string(displayName(device)),
                // Whether the device has an entry in the configuration's `devices`: the page offers to add the others.
                "configured": .bool(listed.contains(device.id)),
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
        let waiting: [JSONValue] = (configuration.devices ?? []).filter { !reported.contains($0.id) }.map { device in
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
