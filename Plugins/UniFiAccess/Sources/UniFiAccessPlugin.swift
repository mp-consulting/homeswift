import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// UniFi Access in HomeKit, after `@mp-consulting/homebridge-unifi-access`: every hub and reader of one or more
/// controllers, found automatically and followed in real time. A hub's door is a lock (a UA Gate's a garage door
/// opener, its side door a second lock), its terminal inputs contact sensors, its doorbell a doorbell; readers get
/// a switch per access method. Feature options (`Enable.Hub.DPS.<MAC>`…) tailor it per controller and device, and
/// MQTT carries the events and lock commands. See README.md.
public actor UniFiAccessPlugin: HomeswiftPlugin {
    public static let platform = "UniFi Access"
    public static let icon: String? = "logo-ubiquiti"
    public static let summary: String? = "Door locks, hubs and readers, followed in real time"
    public static let name = "UniFi Access"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    /// What the plugin uses to reach controllers and brokers; tests swap them for fakes.
    struct Dependencies: Sendable {
        var http: AccessAPI.HTTPFactory = { HTTPClient(tls: $0) }
        var events: AccessAPI.EventsConnector = { try await WebSocket.connect(to: $0, options: $1) }
        var mqtt: AccessMQTT.Connector = { MQTTClient($0) }
        var discover: @Sendable (Logger) async -> [DiscoveredConsole] = { await UbiquitiDiscovery.discover(logger: $0) }
        var checkStatus: @Sendable (String) async -> Bool = { await UbiquitiDiscovery.isOnline(address: $0) }
        var apiTiming = AccessAPI.Timing()
        var hubTiming = AccessHub.Timing()
        var controllerRetryInterval = AccessSettings.controllerRetryInterval
        var controllerRefreshInterval = AccessSettings.controllerRefreshInterval
        /// Instead of the context's logger; tests read the log through it.
        var logger: Logger?
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    /// The block's `options`, after a `Disable.Device.<id>` for each Excluded device (the first of conflicting entries wins).
    let options: FeatureOptions
    /// The block's `options` alone: what Setup shows as excluded by the plugin's own settings.
    let configuredOptions: FeatureOptions
    /// The context's, with `debugAll` promoting debug lines to info.
    let logger: Logger
    private(set) var controllers: [AccessController] = []
    private let pins: TLSPinStore
    private let owners: AccessoryOwners

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        options = AccessOptions.make(Self.exclusions(context) + configuration.options)
        configuredOptions = AccessOptions.make(configuration.options)
        let logger = dependencies.logger ?? context.logger
        self.logger = configuration.debugAll ? DebugAllLogHandler.promoting(logger) : logger
        pins = TLSPinStore(url: context.storageDirectory.appendingPathComponent(AccessSettings.tlsPinFile), logger: self.logger)
        owners = context.persistedDictionary(AccessSettings.ownersFile)
    }

    public func start() async throws {
        guard !controllerEntries().isEmpty else {
            logger.info("No UniFi Access controllers have been configured.")
            return
        }
        logger.debug("Debug logging on. Expect a lot of data.")
        let shared = AccessController.Shared(context: context, logger: logger, options: options, ringDelay: configuration.ringDelay, pins: pins, owners: owners, dependencies: dependencies)
        for entry in controllerEntries() {
            guard let address = entry.address?.trimmingCharacters(in: .whitespaces), !address.isEmpty else {
                logger.info("No host or IP address has been configured.")
                continue
            }
            guard let username = entry.username, !username.isEmpty, let password = entry.password, !password.isEmpty else {
                logger.info("No UniFi Access login credentials have been configured.")
                continue
            }
            let settings = AccessController.Settings(
                address: address, username: username, password: password, name: entry.name?.isEmpty == false ? entry.name : nil, mqttUrl: entry.mqttUrl,
                mqttTopic: entry.mqttTopic?.isEmpty == false ? entry.mqttTopic! : AccessSettings.mqttTopic, mqttVerifyTls: entry.mqttVerifyTls != false,
                verifyTls: entry.verifyTls == true)
            let controller = AccessController(settings: settings, shared: shared)
            controllers.append(controller)
            await controller.start()
        }
    }

    public func stop() async {
        for controller in controllers { await controller.stop() }
        do { try owners.flush() } catch { logger.warning("Could not save \(owners.url.lastPathComponent): \(error)") }
        logger.debug("Stopped")
    }

    // MARK: The web page

    /// The Homebridge plugin's settings server: `POST devices` logs in to a controller and lists what it has
    /// (the controller first, then its hubs and readers with the id feature options use); `GET options` the
    /// feature options; `GET discover` finds UniFi consoles on the network; `POST status` checks that a
    /// controller answers. `GET controllers` adds what the running instance sees. `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "options"):
            return PluginWebResponse(AccessOptions.json)
        case ("POST", "devices"):
            return await devices(request.body)
        case ("GET", "discover"), ("POST", "discover"):
            let found = await dependencies.discover(logger)
            return PluginWebResponse(["devices": .array(found.map(\.json))])
        case ("POST", "status"):
            guard let address = request.body["address"]?.stringValue, AccessSettings.isValidAddress(address) else { return PluginWebResponse(["online": false]) }
            return PluginWebResponse(["online": .bool(await dependencies.checkStatus(address.trimmingCharacters(in: .whitespaces)))])
        case ("GET", "controllers"):
            var list: [JSONValue] = []
            for controller in controllers { list.append(await controller.snapshot()) }
            return PluginWebResponse(["controllers": .array(list)])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    /// Logs in with the page's details and bootstraps, without events (`read`).
    private func devices(_ body: JSONValue) async -> PluginWebResponse {
        guard let address = body["address"]?.stringValue?.trimmingCharacters(in: .whitespaces), AccessSettings.isValidAddress(address) else {
            return PluginWebResponse(["devices": [], "error": "Invalid controller address. Please provide a valid network address."])
        }
        let read = await read(address: address, username: body["username"]?.stringValue ?? "", password: body["password"]?.stringValue ?? "",
                              verifyTLS: body["verifyTls"]?.boolValue == true)
        let controller: AccessControllerInfo?, found: [AccessDevice]
        switch read {
        case .read(let info, let devices): (controller, found) = (info, devices)
        case .failed(let message): return PluginWebResponse(["devices": [], "error": .string(message)])
        }
        let devices = found.filter(\.isManaged).sorted { lhs, rhs in
            let key = { (device: AccessDevice) in [device.alias, device.name, device.model].compactMap { $0 }.first { !$0.isEmpty }?.lowercased() ?? "" }
            return key(lhs) < key(rhs)
        }
        var list: [JSONValue] = [controller.map { .object($0.json) } ?? .null]
        for device in devices {
            var json = device.json
            json["featureId"] = .string(device.identifier)
            list.append(.object(json))
        }
        return PluginWebResponse(["devices": .array(list)])
    }

    /// What a login and a bootstrap without events read of a controller, or the error the API logged.
    enum ControllerRead: Sendable {
        case read(AccessControllerInfo?, [AccessDevice])
        case failed(String)
    }

    /// Logs in to a controller and bootstraps, without events: the page's device list, and Setup's check of a login and
    /// its discovery. The pins are the plugin's, so the page, Setup and the plugin trust the same certificate whichever
    /// connects first.
    func read(address: String, username: String, password: String, verifyTLS: Bool) async -> ControllerRead {
        // The page shows the API's last error, as the Homebridge page did.
        let collector = ErrorCollector()
        let pins = pins
        let trust = HTTPClient.TrustOnFirstUse(pinned: verifyTLS ? nil : pins.pin(for: address)) { pins.set($0, for: address) }
        let api = AccessAPI(
            logger: collector.logger(forwardingTo: logger), http: dependencies.http, events: nil, verifyTLS: verifyTLS, trust: trust, timing: dependencies.apiTiming)
        defer { Task { await api.close() } }
        guard await api.login(address: address, username: username, password: password), await api.getBootstrap() else {
            return .failed(collector.last ?? "Check your address and credentials.")
        }
        return .read(await api.controller, await api.devices ?? [])
    }
}

/// Keeps the last error an API logged, for the settings page.
final class ErrorCollector: Sendable {
    private let message = NIOLockedValueBox<String?>(nil)

    var last: String? { message.withLockedValue { $0 } }

    func logger(forwardingTo base: Logger) -> Logger {
        var logger = Logger(label: base.label) { _ in CollectingHandler(collector: self, base: base) }
        logger.logLevel = .trace
        return logger
    }

    fileprivate func record(_ text: String) { message.withLockedValue { $0 = text } }

    private struct CollectingHandler: LogHandler {
        let collector: ErrorCollector
        let base: Logger
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            log(level: event.level, message: event.message, metadata: event.metadata, source: event.source, file: event.file, function: event.function, line: event.line)
        }

        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
            if level >= .error { collector.record("\(message)") }
            // The page's connection attempts are debug output in the bridge's log.
            base.log(level: .debug, message, metadata: metadata, source: source, file: file, function: function, line: line)
        }
    }
}

/// `debugAll`: the plugin's debug lines at the info level, so they show without `homeswift -D`, as the Homebridge
/// plugin's `debug()` does. Trace lines and the other levels pass through as they are.
struct DebugAllLogHandler: LogHandler {
    let base: Logger
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    static func promoting(_ base: Logger) -> Logger {
        var logger = Logger(label: base.label) { _ in DebugAllLogHandler(base: base) }
        logger.logLevel = min(base.logLevel, .debug)
        return logger
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        log(level: event.level, message: event.message, metadata: event.metadata, source: event.source, file: event.file, function: event.function, line: event.line)
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let merged = self.metadata.isEmpty ? metadata : self.metadata.merging(metadata ?? [:]) { $1 }
        base.log(level: level == .debug ? .info : level, message, metadata: merged, source: source, file: file, function: function, line: line)
    }
}
