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

    /// The lists of the block, in the order the Homebridge plugin creates their accessories: the first accessory of an
    /// `id` gets its webhooks.
    static let kinds = [
        "sensors", "switches", "pushbuttons", "doorbells", "lights", "thermostats", "outlets", "security", "garagedooropeners", "windowcoverings",
        "statelessswitches", "lockmechanisms", "fanv2s", "co2sensors", "valves",
    ]

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
        for accessory in accessories where !context.isExcluded(Self.deviceID(of: accessory)) {
            do {
                try context.add(accessory.accessory)
            } catch {
                logger.error("Could not add \(accessory.accessory.information.characteristic(.name).value.stringValue ?? accessory.id): \(error)")
                continue
            }
            if routes[accessory.id] == nil { routes[accessory.id] = accessory }
        }
        await context.removeAccessories(keeping: Set(accessories.map(\.accessory.id)))

        let credentials = configuration.credentials
        if credentials == nil {
            logger.warning("No http_auth_user and http_auth_pass: anyone on the network can call the webhooks")
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

    /// The Device Id of an accessory: its id after `HttpWebHooks:`, the entry's name.
    static func deviceID(of accessory: any WebhookAccessory) -> String {
        String(accessory.accessory.id.dropFirst(platform.count + 1))
    }

    /// Every entry of the block as an accessory, in the block's order. An entry without an `id` or a `name`, a sensor of
    /// an unknown `type`, and a second entry of the same name (Homebridge would give both the same identity) are left
    /// out, with an error in the log.
    static func build(_ configuration: Configuration, environment: KindEnvironment, logger: Logger) -> [any WebhookAccessory] {
        var built: [any WebhookAccessory] = []
        var names: Set<String> = []
        for list in kinds {
            for entry in configuration.entries(list) {
                guard let id = entry.id, !id.isEmpty, let name = entry.name else {
                    logger.error("An entry of \(list) has no id or no name: leaving it out")
                    continue
                }
                guard names.insert(name).inserted else {
                    logger.error("\(name) (\(list)): another entry has this name, and the name is the accessory's identity: leaving it out")
                    continue
                }
                let accessory: (any WebhookAccessory)? = switch list {
                case "sensors":
                    if let kind = entry.string("type").flatMap(SensorAccessory.Kind.init(rawValue:)) {
                        SensorAccessory(id: id, name: name, kind: kind, entry: entry, environment: environment)
                    } else {
                        nil
                    }
                case "switches": SwitchAccessory(id: id, name: name, outlet: false, entry: entry, environment: environment)
                case "outlets": SwitchAccessory(id: id, name: name, outlet: true, entry: entry, environment: environment)
                case "pushbuttons": PushButtonAccessory(id: id, name: name, entry: entry, environment: environment)
                case "doorbells": DoorbellAccessory(id: id, name: name, entry: entry, environment: environment)
                case "lights": LightAccessory(id: id, name: name, entry: entry, environment: environment)
                case "thermostats": ThermostatAccessory(id: id, name: name, entry: entry, environment: environment)
                case "security": SecurityAccessory(id: id, name: name, entry: entry, environment: environment)
                case "garagedooropeners": GarageDoorAccessory(id: id, name: name, entry: entry, environment: environment)
                case "windowcoverings": WindowCoveringAccessory(id: id, name: name, entry: entry, environment: environment)
                case "statelessswitches": StatelessSwitchAccessory(id: id, name: name, entry: entry, environment: environment)
                case "lockmechanisms": LockAccessory(id: id, name: name, entry: entry, environment: environment)
                case "fanv2s": FanAccessory(id: id, name: name, entry: entry, environment: environment)
                case "co2sensors": CarbonDioxideAccessory(id: id, name: name, entry: entry, environment: environment)
                case "valves": ValveAccessory(id: id, name: name, entry: entry, environment: environment)
                default: nil
                }
                guard let accessory else {
                    names.remove(name)
                    logger.error("\(name): sensor type \"\(entry.string("type") ?? "")\" is not one of \(SensorAccessory.Kind.allCases.map(\.rawValue).joined(separator: ", ")): leaving it out")
                    continue
                }
                built.append(accessory)
            }
        }
        return built
    }

    // MARK: Setup

    /// The entries of the block, each a device set up already: nothing to authorize, as the accessories are virtual.
    /// A new one is added to the block's lists.
    public func discover() async throws -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        var names: Set<String> = []
        for list in Self.kinds {
            for entry in configuration.entries(list) {
                guard let id = entry.id, !id.isEmpty, let name = entry.name, names.insert(name).inserted else { continue }
                let model = list == "sensors" ? entry.string("type").flatMap(SensorAccessory.Kind.init(rawValue:))?.label : Self.label(of: list)
                guard let model else { continue }
                let shown = context.accessorySettings(for: name).name ?? name
                devices.append(DiscoveredDevice(deviceID: name, name: shown, model: model, address: "accessoryId=\(id)", isSetUp: true))
            }
        }
        return devices
    }

    static func label(of list: String) -> String? {
        [
            "switches": "Switch", "pushbuttons": "Push button", "doorbells": "Doorbell", "lights": "Light", "thermostats": "Thermostat",
            "outlets": "Outlet", "security": "Security system", "garagedooropeners": "Garage door", "windowcoverings": "Window covering",
            "statelessswitches": "Stateless switch", "lockmechanisms": "Lock", "fanv2s": "Fan", "co2sensors": "Carbon dioxide sensor", "valves": "Valve",
        ][list]
    }
}
