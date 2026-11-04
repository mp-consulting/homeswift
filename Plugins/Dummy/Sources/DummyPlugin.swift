import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOSSL

/// Dummy accessories: switches, lights, locks, doors, sensors, thermostats and more that exist only in HomeKit, to
/// drive automations. They keep their state across restarts and can turn themselves on and off on a schedule, at
/// sunrise or sunset, after a delay, within a time limit, when other dummies change, on a line of the bridge's log or
/// when a host comes and goes, and through webhooks.
///
/// The configuration is the one of homebridge-dummy (`HomebridgeDummy`), so a Homebridge block works unchanged; the
/// spec it was written from is docs/clean-room/Dummy.md. Each accessory's id is `HomebridgeDummy:` followed by its `id`
/// or, without one, `<type>:<name without whitespace>`, the identity the Homebridge plugin derives. See README.md.
public actor DummyPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// The accessories, read leniently: an entry with a problem is logged and left out, not the whole block.
        public var accessories: [JSONValue]?
        public var verbose: JSONValue?
        public var webhookConfig: JSONValue?
        /// Deprecated: `webhookConfig.port`.
        public var webhookPort: JSONValue?
    }

    struct Dependencies: Sendable {
        var engine = DummyEngine.Dependencies()
        var http: any HTTPSending = HTTPClient()
        /// The bridge's log, for LOG conditions; the host's when nil.
        var logs: LogBuffer?
        /// The webhook server's port when not configured; tests pass 0.
        var defaultWebhookPort = 63743
    }

    public static let platform = "HomebridgeDummy"
    public static let name = "Dummy Accessories"
    public static let icon: String? = "switch"
    public static let summary: String? = "Switches, sensors and more that exist only in HomeKit, for automations"
    static let manufacturer = "Homebridge Dummy"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    private(set) var engine: DummyEngine?
    private(set) var webhookServer: WebhookServer?
    private var logObservation: Observation?
    private var logLines: AsyncStream<String>.Continuation?
    private(set) var accessories: [AccessoryConfig] = []
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    var isVerbose: Bool { configuration.verbose?.boolValue == true }

    /// The block's accessories as the Homebridge plugin reads them, the first of an identifier kept.
    func readAccessories() -> [AccessoryConfig] {
        let context = context
        let reader = ConfigReader(logger: logger, credentials: { context.credentials(for: $0) })
        var seen = Set<String>()
        var list: [AccessoryConfig] = []
        for entry in configuration.accessories ?? [] {
            guard let config = reader.accessory(entry) else { continue }
            guard seen.insert(config.identifier).inserted else {
                logger.warning("\(config.name) has the same identifier as another accessory (\(config.identifier)); it is left out")
                continue
            }
            list.append(config)
        }
        return list
    }

    public func start() async throws {
        let configs = readAccessories().filter { !context.isExcluded($0.deviceID) }
        accessories = configs
        var engineDependencies = dependencies.engine
        if engineDependencies.notifier == nil { engineDependencies.notifier = PushNotifier(http: dependencies.http) }
        let engine = DummyEngine(
            logger: logger, verbose: isVerbose, storeFile: context.jsonFile("HomebridgeDummy.json", as: [String: [String: JSONValue]].self),
            tasks: tasks, dependencies: engineDependencies)
        self.engine = engine
        let builder = DummyAccessoryBuilder(engine: engine, storage: context.storageDirectory, logger: logger)
        var entries: [(AccessoryConfig, DeviceServices)] = []
        var keep = Set<String>()
        var groups: [(name: String, members: [(AccessoryConfig, DeviceServices)])] = []
        for config in configs {
            let services = builder.services(for: config, grouped: config.groupName != nil)
            entries.append((config, services))
            if let group = config.groupName {
                if let index = groups.firstIndex(where: { ConfigReader.stripWhitespace($0.name) == ConfigReader.stripWhitespace(group) }) {
                    groups[index].members.append((config, services))
                } else {
                    groups.append((group, [(config, services)]))
                }
                continue
            }
            let accessory = builder.accessory(for: config, services: services)
            do {
                try add(accessory, name: config.name, matter: config.isMatter)
                keep.insert(accessory.id)
            } catch {
                logger.error("Could not add \(config.name): \(error)")
            }
        }
        for group in groups {
            let accessory = builder.group(name: group.name, members: group.members)
            do {
                try add(accessory, name: group.name, matter: false)
                keep.insert(accessory.id)
            } catch {
                logger.error("Could not add the group \(group.name): \(error)")
            }
        }
        _ = await context.removeAccessories(keeping: keep, message: "Removing HomeKit accessory")
        await engine.start(entries)
        if await engine.registerLogPatterns() {
            if let logs = dependencies.logs ?? context.logs {
                let label = context.logger.label
                // One consumer, in order; a burst beyond the buffer drops its oldest lines.
                let (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1000))
                logObservation = logs.observe { line in
                    // Its own lines are left out, so a pattern cannot trigger itself in a loop.
                    guard line.label != label else { return }
                    continuation.yield(line.text)
                }
                tasks.add {
                    for await text in lines { await engine.logLine(text) }
                }
                logLines = continuation
            } else {
                logger.error("Log conditions need the bridge's log, which is not available")
            }
        }
        if await engine.registerWebhooks() { await startWebhookServer(engine) }
    }

    public func stop() async {
        logObservation?.cancel()
        logObservation = nil
        logLines?.finish()
        logLines = nil
        await engine?.stop()
        await webhookServer?.stop()
        webhookServer = nil
        tasks.cancelAll()
    }

    /// Adds it, saying so the first time (a cached accessory comes back without a word unless `verbose`).
    private func add(_ accessory: Accessory, name: String, matter: Bool) throws {
        let kind = matter ? "Matter" : "HomeKit"
        if context.accessory(id: accessory.id) == nil {
            logger.info("Adding new \(kind) accessory: \(name)")
        } else if isVerbose {
            logger.info("Restoring cached \(kind) accessory: \(name)")
        }
        try context.add(accessory)
    }

    // MARK: Webhooks

    func startWebhookServer(_ engine: DummyEngine) async {
        let options = configuration.webhookConfig ?? .object([:])
        var port = dependencies.defaultWebhookPort
        if let value = options["port"] ?? configuration.webhookPort {
            if let number = value.intValue, (0...65535).contains(number) { port = number } else { logger.error("webhookConfig.port must be a port number; \(port) is used") }
        }
        for key in ["key", "cert", "pfx", "passphrase", "token"] where options[key] != nil && options[key]?.stringValue == nil {
            logger.error("webhookConfig.\(key) must be text; it is ignored")
        }
        var tls: NIOSSLContext?
        if options["disableSSL"]?.boolValue != true, let key = options["key"]?.stringValue, let cert = options["cert"]?.stringValue {
            do {
                tls = try WebhookServer.tlsContext(keyPath: key, certificatePath: cert)
            } catch {
                logger.error("The webhook server failed to load SSL credentials (\(error)); it uses http")
            }
        } else if options["disableSSL"]?.boolValue != true, options["pfx"]?.stringValue != nil {
            logger.warning("webhookConfig.pfx is not supported: give the key and the certificate as PEM files (key, cert)")
        }
        let host = options["bindAddress"]?.stringValue ?? "0.0.0.0"
        let token = options["token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? context.credentials()?["webhookToken"]?.stringValue
        if token == nil, !WebhookServer.isLoopback(host) {
            logger.warning("The webhook server listens on \(host) without a token: anyone who reaches port \(port) can change these accessories. Set webhookConfig.token, or bindAddress to 127.0.0.1")
        }
        let server = WebhookServer(logger: logger)
        do {
            try await server.start(host: host, port: port, tls: tls, token: token, handler: { parameters in
                await engine.webhook(parameters)
            })
            webhookServer = server
        } catch {
            logger.error("The webhook server cannot listen on \(host):\(port): \(error)")
        }
    }

    // MARK: Setup

    /// Each configured accessory is a device of Setup with nothing to authorize; its Device Id is its `id`, or
    /// `<type>:<name without whitespace>` without one.
    public func discover() async throws -> [DiscoveredDevice] {
        let configs = readAccessories()
        return configs.map { config in
            DiscoveredDevice(
                deviceID: config.deviceID, name: context.accessorySettings(for: config.deviceID).name ?? config.name, model: config.type.rawValue,
                isSetUp: true, kind: config.type.rawValue)
        }
    }

    /// The block with the deprecated keys the Homebridge plugin's settings page rewrites in their current form
    /// (spec 13), and the Matter accessories kept out of the Home app (their Accessory Settings' `notInHome`).
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        // Secrets the block holds go to the vault once the block is written; the block is answered as if they had. A
        // value the block holds sealed or as a reference is the opened one the instance runs with, when it has it.
        let context = context
        func plain(_ written: JSONValue?, running: JSONValue?) -> String? {
            guard let text = written?.stringValue, !text.isEmpty else { return nil }
            let opened = ["enc:", "vault:", "env:", "file:"].contains { text.hasPrefix($0) }
            return opened ? running?.stringValue.flatMap { $0.isEmpty ? nil : $0 } : text
        }
        var moves: [(String?, JSONValue)] = []
        var moved = SecretMoves()
        if let token = plain(block["webhookConfig"]?["token"], running: configuration.webhookConfig?["token"]) {
            var account = context.credentials()?.objectValue ?? [:]
            account["webhookToken"] = .string(token)
            moves.append((nil, .object(account)))
            moved.webhook = true
        }
        let running = Dictionary(
            (configuration.accessories ?? []).compactMap { entry in Self.deviceID(of: entry).map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
        for entry in block["accessories"]?.arrayValue ?? [] {
            guard let notification = entry["notification"], let deviceID = Self.deviceID(of: entry) else { continue }
            let opened = running[deviceID]?["notification"]
            var device = context.credentials(for: deviceID)?.objectValue ?? [:]
            let before = device
            let token = plain(notification["token"], running: opened?["token"])
            if let token { device["notificationToken"] = .string(token) }
            if notification["api"]?.stringValue == "PUSHOVER", let id = plain(notification["id"], running: opened?["id"]) { device["notificationID"] = .string(id) }
            // Only what made it to the vault leaves the block.
            if notification["token"] == nil || token != nil { moved.devices.insert(deviceID) }
            if device != before { moves.append((deviceID, .object(device))) }
        }
        if !moves.isEmpty {
            let pending = moves
            await context.whenSettingsWritten { for (deviceID, credentials) in pending { try context.saveCredentials(credentials, for: deviceID) } }
        }
        return Self.canonical(block, moving: moved)
    }

    /// The secrets that go from the block to the vault: the webhook token, and the notifications of these Device Ids.
    struct SecretMoves {
        var webhook = false
        var devices: Set<String> = []
    }

    /// An entry's Device Id: its `id`, or `<type>:<name without whitespace>`.
    static func deviceID(of entry: JSONValue) -> String? {
        if let id = entry["id"]?.stringValue { return id }
        guard let name = entry["name"]?.stringValue, let type = entry["type"]?.stringValue else { return nil }
        return "\(type):\(ConfigReader.stripWhitespace(name))"
    }

    /// `moving`: the secrets that leave the block for the vault (the notifications' tokens, Pushover's application token).
    static func canonical(_ block: JSONValue, moving: SecretMoves = SecretMoves()) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        if moving.webhook, var webhook = fields["webhookConfig"]?.objectValue, webhook.removeValue(forKey: "token") != nil {
            fields["webhookConfig"] = .object(webhook)
        }
        if let port = fields["webhookPort"] {
            var webhook = fields["webhookConfig"]?.objectValue ?? [:]
            if webhook["port"] == nil { webhook["port"] = port }
            fields["webhookConfig"] = .object(webhook)
            fields.removeValue(forKey: "webhookPort")
        }
        var settings = fields["_accessories"]?.objectValue ?? [:]
        if let list = fields["accessories"]?.arrayValue {
            fields["accessories"] = .array(list.map { entry in
                guard var item = entry.objectValue else { return entry }
                if let on = item.removeValue(forKey: "defaultOn"), item["defaultState"] == nil { item["defaultState"] = .string(on.boolValue == true ? "on" : "off") }
                if let misspelt = item.removeValue(forKey: "enableWebook"), item["enableWebhook"] == nil { item["enableWebhook"] = misspelt }
                if item.removeValue(forKey: "defaultBrightness") != nil, item["isDimmer"] == nil { item["isDimmer"] = true }
                if var sensor = item["sensor"]?.objectValue, let timer = sensor.removeValue(forKey: "timerControlled") {
                    if sensor["behavior"] == nil { sensor["behavior"] = .string(timer.boolValue == true ? "TIMER" : "MIRROR") }
                    item["sensor"] = .object(sensor)
                }
                if let fade = item["fadeOut"], fade.boolValue != nil {
                    if fade.boolValue == true, let reset = item["autoReset"], reset["type"]?.stringValue == "TIMEOUT", let time = reset["time"], let units = reset["units"] {
                        item["fadeOut"] = .object(["type": "FIXED", "time": time, "units": units])
                        item.removeValue(forKey: "autoReset")
                    } else {
                        item.removeValue(forKey: "fadeOut")
                    }
                }
                if var conditions = item["conditions"]?.objectValue, let operands = conditions["operands"]?.arrayValue {
                    conditions["operands"] = .array(operands.map { operand in
                        guard var fields = operand.objectValue else { return operand }
                        if let interval = fields.removeValue(forKey: "pingInterval"), fields["checkInterval"] == nil { fields["checkInterval"] = interval }
                        if let units = fields.removeValue(forKey: "pingUnits"), fields["checkUnits"] == nil { fields["checkUnits"] = units }
                        return .object(fields)
                    })
                    item["conditions"] = .object(conditions)
                }
                if let deviceID = Self.deviceID(of: .object(item)), moving.devices.contains(deviceID), var notification = item["notification"]?.objectValue {
                    notification.removeValue(forKey: "token")
                    if notification["api"]?.stringValue == "PUSHOVER" { notification.removeValue(forKey: "id") }
                    item["notification"] = .object(notification)
                }
                if item["protocol"]?.stringValue == "Matter", let deviceID = Self.deviceID(of: .object(item)) {
                    var entry = settings[deviceID]?.objectValue ?? [:]
                    if entry["notInHome"] == nil {
                        entry["notInHome"] = true
                        settings[deviceID] = .object(entry)
                    }
                }
                return .object(item)
            })
        }
        if !settings.isEmpty { fields["_accessories"] = .object(settings) }
        return .object(fields)
    }
}
