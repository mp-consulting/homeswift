import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOSSL

/// Virtual accessories driven by HTTP: sensors, switches, push buttons, doorbells, lights, thermostats, outlets,
/// security systems, garage doors, stateless switches, window coverings, locks, fans, CO2 sensors and valves listed in
/// the block. One HTTP (or HTTPS) server on the LAN takes webhooks that set their states or read them back, and a
/// HomeKit write can call a URL the entry gives.
///
/// The configuration is the one of homebridge-http-webhooks, so a Homebridge block works unchanged; the plugin was
/// written from a functional specification (docs/clean-room/HTTPWebhooks.md), not from that plugin's code. See
/// README.md in this directory.
public actor HTTPWebhooksPlugin: HomeswiftPlugin {
    /// What the plugin uses outside itself; tests swap them.
    struct Dependencies: Sendable {
        var client: @Sendable (_ rejectUnauthorized: Bool) -> any HTTPSending = OutgoingCaller.live
        /// Overrides `webhook_port` (tests listen on port 0).
        var port: Int?
        var timing = KindEnvironment.Timing()
    }

    public static let platform = "HttpWebHooks"
    public static let name = "HTTP Webhooks"
    public static let icon: String? = "link"
    public static let summary: String? = "Virtual sensors, switches and locks driven by webhooks"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    /// The Manufacturer of every accessory, as the Homebridge plugin gives it.
    static let manufacturer = "HttpWebHooksPlatform"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private let server: WebhookServer
    /// The accessories, in the block's order.
    private(set) var accessories: [any WebhookAccessory] = []
    private var store: StateStore?
    /// What the server answers, once started; tests ask it directly.
    private(set) var router: WebhookRouter?
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        server = WebhookServer(logger: context.logger)
    }

    /// The id of an accessory: Homebridge's seed for a static platform's accessory, `HttpWebHooks:<name>`, so the Device Id
    /// is the entry's name.
    static func accessoryID(name: String) -> String { "\(platform):\(name)" }

    /// The port the server listens on, once started.
    var port: Int? { server.port }

    public func start() async throws {
        let store = StateStore(values: context.persistedDictionary("http-webhooks-state.json", of: JSONValue.self))
        self.store = store
        let environment = KindEnvironment(
            store: store, caller: OutgoingCaller(client: dependencies.client, logger: logger), logger: logger, tasks: tasks, timing: dependencies.timing)
        accessories = Self.build(configuration, environment: environment, logger: logger)
        var routes: [String: any WebhookAccessory] = [:]
        for accessory in accessories where !context.isExcluded(accessory.name) {
            do {
                try context.add(accessory.accessory)
            } catch {
                logger.error("Could not add \(accessory.name): \(error)")
                continue
            }
            if routes[accessory.id] == nil { routes[accessory.id] = accessory }
        }
        await context.removeAccessories(keeping: Set(accessories.map(\.accessory.id)))

        let credentials = credentials
        if credentials == nil {
            logger.warning("No user name and password for the webhooks (Setup, or http_auth_user and http_auth_pass): anyone on the network can call them")
        }
        let router = WebhookRouter(accessories: routes, credentials: credentials, cors: configuration.enableCORS, logger: logger)
        self.router = router
        var tls: NIOSSLContext?
        if configuration.https {
            let (context, generated) = try WebhookCertificate.context(
                keyFile: configuration.httpsKeyFile, certificateFile: configuration.httpsCertificateFile,
                secrets: self.context.secretFile(WebhookCertificate.fileName, as: WebhookCertificate.Stored.self))
            tls = context
            if configuration.httpsKeyFile == nil || configuration.httpsCertificateFile == nil {
                logger.info(generated ? "Generated a new self-signed certificate for HTTPS" : "Using the automatic self-signed certificate for HTTPS")
            }
        }
        let host = configuration.host
        let port = dependencies.port ?? configuration.port
        do {
            try await server.start(host: host, port: port, tls: tls) { method, uri, authorization in
                router.respond(method: method, uri: uri, authorization: authorization)
            }
        } catch {
            logger.error("Cannot start the webhook server on \(host):\(port): \(error)")
            throw error
        }
        logger.info("Started \(tls == nil ? "HTTP" : "HTTPS") webhook server on port \(server.port ?? port), host \(host)")
    }

    public func stop() async {
        tasks.cancelAll()
        await server.stop()
        try? store?.flush()
    }

    /// What a kind's entry becomes: its accessory, or nil (a sensor of an unknown `type`).
    typealias Make = @Sendable (_ id: String, _ name: String, _ entry: Entry, _ environment: KindEnvironment) -> (any WebhookAccessory)?

    /// The lists of the block, in the order the Homebridge plugin creates their accessories (the first accessory of an
    /// `id` gets its webhooks), with what Setup calls each and what makes it.
    static let kindTable: [(list: String, label: String, make: Make)] = [
        ("sensors", "Sensor", { id, name, entry, environment in
            entry.string("type").flatMap(SensorAccessory.Kind.init(rawValue:)).map {
                SensorAccessory(id: id, name: name, kind: $0, entry: entry, environment: environment)
            }
        }),
        ("switches", "Switch", { SwitchAccessory(id: $0, name: $1, outlet: false, entry: $2, environment: $3) }),
        ("pushbuttons", "Push button", { PushButtonAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("doorbells", "Doorbell", { DoorbellAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("lights", "Light", { LightAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("thermostats", "Thermostat", { ThermostatAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("outlets", "Outlet", { SwitchAccessory(id: $0, name: $1, outlet: true, entry: $2, environment: $3) }),
        ("security", "Security system", { SecurityAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("garagedooropeners", "Garage door", { GarageDoorAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("windowcoverings", "Window covering", { WindowCoveringAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("statelessswitches", "Stateless switch", { StatelessSwitchAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("lockmechanisms", "Lock", { LockAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("fanv2s", "Fan", { FanAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("co2sensors", "Carbon dioxide sensor", { CarbonDioxideAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
        ("valves", "Valve", { ValveAccessory(id: $0, name: $1, entry: $2, environment: $3) }),
    ]

    static var kinds: [String] { kindTable.map(\.list) }

    /// An entry that makes an accessory, with what Setup calls it.
    struct ValidEntry {
        let id: String
        let name: String
        let entry: Entry
        let model: String
        let make: Make
    }

    /// The block's entries that make accessories, in the block's order. An entry without an `id` or a `name`, a sensor
    /// of an unknown `type`, and a second entry of the same name (Homebridge would give both the same identity) are left
    /// out, logged when `logger` is given.
    static func validEntries(_ configuration: Configuration, logger: Logger?) -> [ValidEntry] {
        var valid: [ValidEntry] = []
        var names: Set<String> = []
        for (list, label, make) in kindTable {
            for entry in configuration.entries(list) {
                guard let id = entry.id, !id.isEmpty, let name = entry.name else {
                    logger?.error("An entry of \(list) has no id or no name: leaving it out")
                    continue
                }
                var model = label
                if list == "sensors" {
                    guard let kind = entry.string("type").flatMap(SensorAccessory.Kind.init(rawValue:)) else {
                        let known = SensorAccessory.Kind.allCases.map(\.rawValue).joined(separator: ", ")
                        logger?.error("\(name): sensor type \"\(entry.string("type") ?? "")\" is not one of \(known): leaving it out")
                        continue
                    }
                    model = kind.label
                }
                guard names.insert(name).inserted else {
                    logger?.error("\(name) (\(list)): another entry has this name, and the name is the accessory's identity: leaving it out")
                    continue
                }
                valid.append(ValidEntry(id: id, name: name, entry: entry, model: model, make: make))
            }
        }
        return valid
    }

    /// Every valid entry of the block as an accessory, in the block's order.
    static func build(_ configuration: Configuration, environment: KindEnvironment, logger: Logger) -> [any WebhookAccessory] {
        validEntries(configuration, logger: logger).compactMap { $0.make($0.id, $0.name, $0.entry, environment) }
    }
}
