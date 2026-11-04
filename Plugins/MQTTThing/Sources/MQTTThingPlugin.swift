import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Devices that speak MQTT, each described by hand as homebridge-mqttthing describes them: per characteristic, the topic
/// the device publishes its state on and the one the bridge sends commands to, and how values are written
/// (docs/clean-room/MQTTThing.md).
///
/// An accessory plugin: Homebridge's `{"accessory": "mqttthing", …}` blocks run here unchanged, from config.json's
/// `accessories` (`runsAccessoryBlocks`) or from the `accessories` list of a `mqttthing` platform block. The blocks that
/// name the same broker and credentials share one MQTT connection. A television goes on a HAP server of its own
/// (`context.publishExternal`). `apply` functions and codecs other than the built-in `json` are JavaScript, which
/// Homeswift does not run; README.md says what is left out.
public actor MQTTThingPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// Homebridge's accessory blocks, as they are.
        public var accessories: [JSONValue]?
    }

    struct Dependencies: Sendable {
        /// The connection to a broker; tests give a fake.
        var connect: @Sendable (BrokerSettings, _ name: String, Logger) throws -> any MQTTConnection = MQTTThingPlugin.realConnection
        var thing = Thing.Dependencies()
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60), jitter: .proportional(0.2))
    }

    public static let platform = "mqttthing"
    public static let name = "MQTT Thing"
    public static let icon: String? = "plugin"
    public static let summary: String? = "Devices that speak MQTT, described topic by topic"
    public static let runsAccessoryBlocks = true
    public static let accountAuthorization: AuthorizationMethod = .accountLogin
    /// Optional: each accessory comes from its block, and a broker may take anonymous clients or the block's own password.
    public static let accountRequirement = AccountRequirement.optional(adds: "Signs in to the MQTT broker for the accessories whose block has no password.")
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private var logger: Logger { context.logger }
    private var brokers: [BrokerSettings: Broker] = [:]
    private(set) var things: [String: Thing] = [:]
    /// The broker of each accessory, by id.
    private var brokerOf: [String: BrokerSettings] = [:]

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    /// The block's identity seed: `uuid_base`, else `name` (section 2.1).
    static func seed(_ config: Config) -> String { config.string("uuid_base").flatMap { $0.isEmpty ? nil : $0 } ?? config.name }
    static func accessoryID(_ config: Config) -> String { "\(platform):\(seed(config))" }

    var blocks: [Config] { (configuration.accessories ?? []).compactMap { $0.objectValue.map(Config.init) } }

    public func start() async throws {
        let credentials = context.credentials(as: AccountCredentials.self)?.brokers ?? [:]
        var ids: Set<String> = []
        for config in blocks {
            let id = Self.accessoryID(config)
            guard ids.insert(id).inserted else {
                logger.error("Two accessories are named \"\(Self.seed(config))\": give one a uuid_base; the second is left out")
                continue
            }
            if context.isExcluded(accessoryID: id) { continue }
            let settings = BrokerSettings(config, credentials: credentials, environment: dependencies.environment)
            let broker: Broker
            if let existing = brokers[settings] {
                broker = existing
            } else {
                do {
                    let connection = try dependencies.connect(settings, config.name, logger)
                    broker = Broker(settings: settings, connection: connection, logger: logger, backoff: dependencies.backoff)
                } catch {
                    logger.error("\(config.name): cannot set up MQTT (\(error)); the accessory has no services")
                    continue
                }
                brokers[settings] = broker
            }
            if config.flag("logMqtt") { logger.info("\(config.name): MQTT broker \(settings.displayURL)") }
            let thing = Thing(config: config, id: id, broker: broker, context: context, dependencies: dependencies.thing)
            guard let accessory = await thing.build() else {
                await thing.stop()
                continue
            }
            do {
                if config.type == "television" {
                    try await context.publishExternal(accessory)
                } else {
                    try context.add(accessory)
                }
                things[id] = thing
                brokerOf[id] = settings
            } catch {
                logger.error("\(config.name): \(error)")
                await thing.stop()
            }
        }
        let kept = Set(things.keys)
        await context.removeAccessories(keeping: kept)
        // Only the brokers an accessory uses connect; the others (their blocks made no accessory) are dropped.
        let used = Set(brokerOf.values)
        for (settings, broker) in brokers where !used.contains(settings) {
            await broker.stop()
            brokers.removeValue(forKey: settings)
        }
        for broker in brokers.values { await broker.start() }
        logger.info("Started \(things.count) accessories on \(brokers.count) MQTT broker connection(s)")
    }

    public func stop() async {
        for thing in things.values { await thing.stop() }
        things.removeAll()
        for broker in brokers.values { await broker.stop() }
        brokers.removeAll()
    }

    // MARK: Setup

    public func discover() async throws -> [DiscoveredDevice] {
        let credentials = context.credentials(as: AccountCredentials.self)?.brokers ?? [:]
        var devices: [DiscoveredDevice] = []
        for config in blocks {
            let settings = brokerOf[Self.accessoryID(config)] ?? BrokerSettings(config, credentials: credentials, environment: dependencies.environment)
            var device = DiscoveredDevice(
                deviceID: Self.seed(config), name: config.name, model: config.rawType, address: settings.displayURL, isSetUp: true)
            if let broker = brokers[settings] { device.isReachable = await broker.isConnected }
            devices.append(device)
        }
        return devices
    }

    /// Authorized unless a broker refused the user name and password.
    public func accountAuthorized() async -> Bool? {
        for broker in brokers.values where await broker.refused { return false }
        return true
    }

    /// The broker's user name and password, kept in the vault by URL: a block without its own `password` uses them.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Each MQTT accessory is set up in its block; the broker's sign-in is the account's")
        let urls = Array(Set(blocks.map { BrokerSettings($0, credentials: [:], environment: dependencies.environment).displayURL })).sorted()
        guard let password = request.secret("password"), !password.isEmpty else {
            let fields = [
                SetupField.choice("broker", label: "Broker", options: urls.map { SetupOption($0, label: $0) }, value: urls.first),
                SetupField("username", label: "User name", optional: true),
                SetupField("password", label: "Password", kind: .secret),
            ]
            return .ask(SetupPrompt(message: "The MQTT broker's user name and password", fields: fields))
        }
        guard let url = request.choice("broker", among: urls) ?? urls.first else { throw SetupError("No accessory names a broker yet") }
        var credentials = context.credentials(as: AccountCredentials.self) ?? AccountCredentials()
        let username = request.answer("username").flatMap { $0.isEmpty ? nil : $0 }
        credentials.brokers[url] = BrokerCredentials(username: username, password: password)
        return .done(try SetupOutcome(encoding: credentials))
    }

    // MARK: The real connection

    @Sendable static func realConnection(_ settings: BrokerSettings, name: String, logger: Logger) throws -> any MQTTConnection {
        guard let url = URL(string: settings.url) else { throw MQTTError.invalidURL(settings.displayURL) }
        let options = settings.options
        var configuration = try MQTTConfiguration(url: url, clientID: clientID(name, options: options), tls: try tls(options))
        if let username = settings.username { configuration.username = username }
        if let password = settings.password { configuration.password = password }
        configuration.keepAlive = .seconds(Int(options["keepalive"]?.doubleValue ?? 10))
        configuration.connectTimeout = .milliseconds(Int(options["connectTimeout"]?.doubleValue ?? 30000))
        let period = Int(options["reconnectPeriod"]?.doubleValue ?? 1000)
        configuration.reconnect = period > 0 ? MQTTConfiguration.Reconnect(delay: .milliseconds(period), maximumDelay: .seconds(60)) : nil
        configuration.cleanSession = options["clean"]?.boolValue ?? true
        if options["protocolVersion"]?.doubleValue == 5 { configuration.protocolVersion = .v5 }
        if options["protocolVersion"]?.doubleValue == 3 { configuration.protocolVersion = .v3_1 }
        if let will = options["will"], let topic = will["topic"]?.stringValue {
            configuration.will = MQTTMessage(
                topic: topic, string: will["payload"].map(JS.text) ?? "", qos: (will["qos"]?.doubleValue ?? 0) >= 1 ? .atLeastOnce : .atMostOnce,
                retain: will["retain"]?.boolValue ?? false)
        } else {
            configuration.will = MQTTMessage(topic: "WillMsg", string: "mqtt-thing [\(name)] has stopped")
        }
        return MQTTClient(configuration)
    }

    /// `mqttthing_` and the name in printable ASCII, then 8 random hex digits; `mqttOptions.clientId` when given.
    static func clientID(_ name: String, options: JSONValue) -> String {
        if let given = options["clientId"]?.stringValue, !given.isEmpty { return given }
        let printable = String(String.UnicodeScalarView(name.unicodeScalars.filter { (0x20...0x7F).contains($0.value) }))
        return "mqttthing_\(printable)_\(String(format: "%08x", UInt32.random(in: 0...UInt32.max)))"
    }

    /// The TLS of `mqttOptions`: `cafile`/`ca`, `certfile`/`cert` with `keyfile`/`key`; the server's certificate is
    /// checked unless `rejectUnauthorized` is false or `insecure` is true (the Homebridge plugin checks nothing by default).
    static func tls(_ options: JSONValue) throws -> TLSOptions {
        func pem(_ inline: String, _ file: String) throws -> String? {
            if let text = options[inline]?.stringValue, !text.isEmpty { return text }
            guard let path = options[file]?.stringValue, !path.isEmpty else { return nil }
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        var tls = TLSOptions()
        if options["rejectUnauthorized"] == .bool(false) || options["insecure"] == .bool(true) {
            tls.trust = .any
        } else if let ca = try pem("ca", "cafile") {
            tls.trust = .roots(pem: ca)
        }
        if let certificate = try pem("cert", "certfile"), let key = try pem("key", "keyfile") {
            tls.clientIdentity = .pem(certificate: certificate, privateKey: key)
        }
        return tls
    }
}
