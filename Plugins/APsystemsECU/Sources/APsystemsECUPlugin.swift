import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// APsystems solar microinverters, read from their ECU gateway (ECU-C, ECU-R, ECU-R-Pro, ECU-B) over its local protocol
/// on TCP port 8899: the system's production as a Light Sensor (lux = W) with Eve's power and energy, and each inverter
/// as a Light Sensor (its power) and a Temperature Sensor. The production, and an ECU-C's CT clamps, go to the Status
/// page's Energy section. Read only: the plugin never writes to the ECU.
///
/// There is no Homebridge plugin for the ECU; the platform name and options are this plugin's own. Written from the
/// clean-room specification in docs/clean-room/APsystemsECU.md (README.md, "Clean-room implementation").
public actor APsystemsECUPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public struct ECU: Decodable, Sendable, Equatable {
            /// IPv4 address or host name.
            public var host: String?
            /// 8899 by default.
            public var port: Int?
            /// The ECU's name until its Accessory Settings have one (`canonicalSettings` moves it there).
            public var name: String?
        }

        public var name: String?
        public var ecus: [ECU]?
        /// Seconds between polls: 300 by default, 60 to 3600.
        public var pollInterval: Int?
        /// Connection attempts per request, 1 to 10 (2 by default).
        public var connectRetries: Int?
        /// An accessory for each inverter (true by default).
        public var inverters: Bool?
        /// An ECU-C's CT clamps over HTTP (true by default).
        public var meter: Bool?
    }

    /// What the plugin uses to reach the ECUs; tests swap them for fakes and shorten the timings.
    struct Dependencies: Sendable {
        /// nil: TCP, with the configured retries.
        var exchange: (any ECUExchanging)?
        var meter: any ECUMeterReading = ECUMeterClient()
        /// Multiplies every delay of the plugin (polls, retries): 0.001 in tests.
        var timeScale: Double = 1
    }

    public static let platform = "APsystemsECU"
    public static let name = "APsystems ECU"
    public static let icon: String? = "sun"
    public static let summary: String? = "Solar production from an APsystems ECU on the local network"
    public static let accountAuthorization = AuthorizationMethod.none

    static let defaultPollInterval = 300
    static let pollIntervalRange = 60...3600
    static let defaultConnectRetries = 2
    /// The longest a failing ECU or a night waits between polls, unless the interval is longer.
    static let slowInterval = 900
    /// Polls that fail in a row before the plugin asks less often.
    static let failuresBeforeBackoff = 3
    /// Device Kinds.
    static let ecuKind = "ecu"
    static let inverterKind = "inverter"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    var logger: Logger { context.logger }

    /// Each configured ECU, by `host:port`, in the order of `ecus`.
    var ecus: [String: ECURuntime]
    var order: [String]
    /// The ECUs' production services, by ECU id.
    var solarServices: [String: Service] = [:]
    /// The inverters' services, by UID.
    var inverterServices: [String: InverterServices] = [:]
    /// The last reading of every inverter an ECU reported, by UID, for the page and Setup.
    var inverterReadings: [String: InverterReading] = [:]
    /// The ECUs (by `host:port`) a request is talking to now, and those waiting for them (`exclusively`).
    var busy: Set<String> = []
    var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Type codes and models already logged as unknown, logged once.
    var loggedOddities: Set<String> = []
    /// The ECUs and inverters (by id) the bridge refused: tried again at each poll, logged once until one goes on it.
    var refusedAccessories: Set<String> = []

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        var ecus: [String: ECURuntime] = [:]
        var order: [String] = []
        for entry in Self.entries(configuration) where ecus[entry.key] == nil {
            ecus[entry.key] = ECURuntime(host: entry.host, port: entry.port, configuredName: entry.name)
            order.append(entry.key)
        }
        // The ECUs added by address: their Accessory Settings give where they answer. One at an address of `ecus` too is
        // read once, under its ECU id.
        for added in Self.addedECUs(context) {
            if var listed = ecus[added.key] {
                listed.addedID = added.ecuID
                ecus[added.key] = listed
                continue
            }
            ecus[added.key] = ECURuntime(host: added.host, port: added.port, configuredName: nil, addedID: added.ecuID)
            order.append(added.key)
        }
        self.ecus = ecus
        self.order = order
    }

    // MARK: Configuration

    /// The `ecus` entries with an address, trimmed, the port defaulted.
    static func entries(_ configuration: Configuration) -> [(key: String, host: String, port: Int, name: String?)] {
        (configuration.ecus ?? []).compactMap { entry in
            guard let host = entry.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
            let port = port(entry.port)
            let name = entry.name?.trimmingCharacters(in: .whitespaces)
            return (Self.key(host: host, port: port), host, port, name?.isEmpty == false ? name : nil)
        }
    }

    /// The ECUs whose Accessory Settings give a `host` (Add by address), Excluded ones left out, by ECU id.
    static func addedECUs(_ context: PluginContext) -> [(key: String, host: String, port: Int, ecuID: String)] {
        context.allAccessorySettings.sorted { $0.key < $1.key }.compactMap { ecuID, settings in
            guard !settings.excluded, let entry = settings.decode(Configuration.ECU.self),
                  let host = entry.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
            let port = port(entry.port)
            return (Self.key(host: host, port: port), host, port, ecuID)
        }
    }

    static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    /// A configured port, 8899 when it is missing or out of range.
    static func port(_ port: Int?) -> Int { port.flatMap { (1...65535).contains($0) ? $0 : nil } ?? ECUProtocol.port }

    /// An ECU's name until its Accessory Settings have one: the configured one, else its model and ECU id.
    static func defaultName(ecuID: String, configured: String?) -> String { configured ?? "\(ECUProtocol.ecuModel(ecuID)) \(ecuID)" }

    static func inverterName(_ uid: String) -> String { "Inverter \(uid)" }

    var pollSeconds: Int {
        min(max(configuration.pollInterval ?? Self.defaultPollInterval, Self.pollIntervalRange.lowerBound), Self.pollIntervalRange.upperBound)
    }

    var connectRetries: Int { min(max(configuration.connectRetries ?? Self.defaultConnectRetries, 1), 10) }

    func scaled(seconds: Int) -> Duration { .milliseconds(Int64((Double(seconds) * 1000 * dependencies.timeScale).rounded())) }

    var exchanger: any ECUExchanging {
        dependencies.exchange ?? ECUClient(retries: connectRetries, retryDelay: scaled(seconds: 2))
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    // MARK: Lifecycle

    public func start() async throws {
        // Not configured: nothing runs.
        guard !order.isEmpty else {
            logger.info("No ECU configured: add one by its address in the Add accessories page")
            return
        }
        tasks.add { [weak self] in await self?.run() }
    }

    public func stop() async {
        tasks.cancelAll()
    }

    /// Polls each ECU when it is due, one at a time (the ECUs take one client at a time), then sleeps until the next.
    func run() async {
        while !Task.isCancelled {
            let now = ContinuousClock.now
            for key in order where (ecus[key]?.nextPoll ?? now) <= now {
                if Task.isCancelled { return }
                await poll(key)
            }
            guard let next = ecus.values.map(\.nextPoll).min() else { return }
            do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
        }
    }

    // MARK: Accessory ids and Setup

    /// The Device Kind of an ECU or an inverter.
    public func deviceKind(of deviceID: String) async -> String? {
        if ecus.values.contains(where: { $0.ecuID == deviceID }) { return Self.ecuKind }
        if inverterReadings[deviceID] != nil { return Self.inverterKind }
        return nil
    }

    /// `ecus[].name` moved into the ECU's Accessory Settings once the plugin knows the ECU's id at that address.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        Self.canonical(block, ecuIDs: ecus.compactMapValues(\.ecuID))
    }

    static func canonical(_ block: JSONValue, ecuIDs: [String: String]) -> JSONValue {
        guard var fields = block.objectValue, let list = fields["ecus"]?.arrayValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        var changed = false
        let moved: [JSONValue] = list.map { item in
            guard var entry = item.objectValue, let name = entry["name"]?.stringValue,
                  let host = entry["host"]?.stringValue?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return item }
            let port = port(entry["port"]?.saturatingIntValue)
            guard let id = ecuIDs[key(host: host, port: port)] else { return item }
            var settings = entries[id]?.objectValue ?? [:]
            if settings["name"] == nil, !name.trimmingCharacters(in: .whitespaces).isEmpty { settings["name"] = .string(name) }
            if !settings.isEmpty { entries[id] = .object(settings) }
            entry.removeValue(forKey: "name")
            changed = true
            return .object(entry)
        }
        guard changed else { return block }
        fields["ecus"] = .array(moved)
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }
}
