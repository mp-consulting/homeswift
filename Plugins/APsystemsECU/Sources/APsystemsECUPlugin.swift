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
    /// The ECUs' services, by ECU id.
    var ecuServices: [String: ECUServices] = [:]
    /// The inverters' services, by UID.
    var inverterServices: [String: InverterServices] = [:]
    /// The last reading of every inverter an ECU reported, by UID, for the page and Setup.
    var inverterReadings: [String: InverterReading] = [:]
    /// Whether the poll runs (an instance without ECUs starts nothing).
    var isPolling = false
    /// Type codes and models already logged as unknown, logged once.
    var loggedOddities: Set<String> = []

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
        self.ecus = ecus
        self.order = order
    }

    // MARK: Configuration

    /// The `ecus` entries with an address, trimmed, the port defaulted.
    static func entries(_ configuration: Configuration) -> [(key: String, host: String, port: Int, name: String?)] {
        (configuration.ecus ?? []).compactMap { entry in
            guard let host = entry.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
            let port = (1...65535).contains(entry.port ?? ECUProtocol.port) ? entry.port ?? ECUProtocol.port : ECUProtocol.port
            let name = entry.name?.trimmingCharacters(in: .whitespaces)
            return (Self.key(host: host, port: port), host, port, name?.isEmpty == false ? name : nil)
        }
    }

    static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

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
            logger.info("No ECU configured: add its address in the plugin's settings (ecus)")
            return
        }
        isPolling = true
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
        if ecuServices[deviceID] != nil || ecus.values.contains(where: { $0.ecuID == deviceID }) { return Self.ecuKind }
        if inverterReadings[deviceID] != nil || inverterServices[deviceID] != nil { return Self.inverterKind }
        return nil
    }

    /// `ecus[].name` moved into the ECU's Accessory Settings once the plugin knows the ECU's id at that address.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var ids: [String: String] = [:]
        for runtime in ecus.values { if let id = runtime.ecuID { ids[Self.key(host: runtime.host, port: runtime.port)] = id } }
        return Self.canonical(block, ecuIDs: ids)
    }

    static func canonical(_ block: JSONValue, ecuIDs: [String: String]) -> JSONValue {
        guard var fields = block.objectValue, let list = fields["ecus"]?.arrayValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        var changed = false
        let moved: [JSONValue] = list.map { item in
            guard var entry = item.objectValue, let name = entry["name"]?.stringValue,
                  let host = entry["host"]?.stringValue?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return item }
            let port = entry["port"]?.saturatingIntValue ?? ECUProtocol.port
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
