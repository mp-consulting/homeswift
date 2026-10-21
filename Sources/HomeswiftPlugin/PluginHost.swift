import Foundation
import Homeswift
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers

/// Runs the plugins of a configuration on one HAP bridge, plus a child bridge for every block with `_bridge`.
///
/// Files under `storageDirectory` (`homeswift -U`, `~/.homeswift` by default):
///
/// | File | What it is |
/// |---|---|
/// | `homeswift.json` | The main bridge's HAP state: identity, pairings, aids and iids |
/// | `child-bridges/<platform>-<name>.json` | The same for each child bridge |
/// | `accessories/<platform>-<name>.json` | The accessory cache of each platform instance |
/// | `plugins/<platform>-<name>/` | Each plugin's own files |
public final class PluginHost: @unchecked Sendable {
    public static let version = "0.2.0"

    public struct Options: Sendable {
        /// Advertise the bridges over Bonjour. Turn off in tests.
        public var advertise: Bool
        public var logger: Logger
        /// The HAP state storage of a bridge, by file name (`homeswift`, `child-bridges/<key>`). Defaults
        /// to a JSON file under `storageDirectory`; tests pass `MemoryStorage`.
        public var makeStorage: (@Sendable (_ name: String) -> any HAPStorage)?
        /// Platform names the runtime itself handles (the Assistant, the web UI): no plugin, no warning.
        public var systemPlatforms: Set<String> = [AIConfiguration.platform]

        public init(advertise: Bool = true, logger: Logger = Logger(label: "homeswift"), makeStorage: (@Sendable (_ name: String) -> any HAPStorage)? = nil) {
            self.advertise = advertise
            self.logger = logger
            self.makeStorage = makeStorage
        }
    }

    /// One HAP server: the main bridge, or the child bridge of one platform block.
    public final class Bridge: @unchecked Sendable {
        public let name: String
        public let server: HAPServer
        public let isChild: Bool
        // Accessory ids on this bridge and the platform instance that owns each.
        private let owners = NIOLockedValueBox<[String: (key: String, name: String)]>([:])

        init(name: String, server: HAPServer, isChild: Bool) {
            self.name = name
            self.server = server
            self.isChild = isChild
        }

        func claim(_ id: String, for key: String, name: String) throws {
            try owners.withLockedValue { owners in
                if let owner = owners[id], owner.key != key {
                    throw PluginError.accessoryIDInUse(id: id, by: owner.name)
                }
                owners[id] = (key, name)
            }
        }

        func release(_ id: String) {
            owners.withLockedValue { $0[id] = nil }
        }
    }

    /// A platform block the host runs.
    public struct PlatformInstance: Sendable {
        public let name: String
        public let platform: String
        public let pluginName: String
        public let bridge: Bridge
        /// The ids of the accessories this instance has on its bridge right now.
        public let accessoryIDs: [String]
    }

    final class Instance: @unchecked Sendable {
        let entry: PluginRegistry.Entry
        let block: HomeswiftConfiguration.Platform
        let context: PluginContext
        let plugin = NIOLockedValueBox<(any HomeswiftPlugin)?>(nil)

        init(entry: PluginRegistry.Entry, block: HomeswiftConfiguration.Platform, context: PluginContext) {
            self.entry = entry
            self.block = block
            self.context = context
        }
    }

    public let configuration: HomeswiftConfiguration
    public let storageDirectory: URL
    /// The plugins this host knows, whether or not config.json uses them.
    public let registry: PluginRegistry
    /// The main bridge first, then the child bridges in configuration order.
    public let bridges: [Bridge]
    public var mainBridge: Bridge { bridges[0] }
    public var platforms: [PlatformInstance] {
        instances.map {
            PlatformInstance(
                name: $0.context.name, platform: $0.context.platform, pluginName: $0.entry.name, bridge: $0.context.bridge,
                accessoryIDs: $0.context.accessories.map(\.id))
        }
    }

    /// The Assistant of the `HomeswiftAiKit` block, when there is one that works.
    public var assistant: AssistantService? { assistantBox.withLockedValue { $0 } }
    /// The `HomeswiftAiKit` block as read, whether or not its provider could be set up.
    public let aiConfiguration: AIConfiguration?

    let instances: [Instance]
    let options: Options
    let logger: Logger
    private let assistantBox = NIOLockedValueBox<AssistantService?>(nil)

    /// Prepares the bridges and the plugins' contexts and restores the accessory caches. Nothing listens
    /// until `start()`.
    public init(configuration: HomeswiftConfiguration, registry: PluginRegistry, storageDirectory: URL, options: Options = Options()) throws {
        self.configuration = configuration
        self.storageDirectory = storageDirectory
        self.registry = registry
        self.options = options
        logger = options.logger

        let bridgeConfiguration = configuration.bridge
        let main = try Self.makeBridge(
            name: bridgeConfiguration.name, username: bridgeConfiguration.username, pin: bridgeConfiguration.pin,
            port: bridgeConfiguration.port, manufacturer: bridgeConfiguration.manufacturer, model: bridgeConfiguration.model,
            firmwareRevision: bridgeConfiguration.firmwareRevision, storageName: "homeswift", isChild: false,
            storageDirectory: storageDirectory, options: options)
        var bridges = [main]
        var instances: [Instance] = []
        var keys = Set<String>()

        if configuration.accessoryBlockCount > 0 {
            logger.warning("config.json has \(configuration.accessoryBlockCount) \"accessories\" block(s); Homeswift only runs platforms, they are ignored")
        }

        // The Assistant's block is the runtime's, not a plugin's. A bad one never stops the bridge.
        aiConfiguration = Self.loadAIConfiguration(configuration, logger: logger)
        if let aiConfiguration, aiConfiguration.enabled, !aiConfiguration.hasProviderSettings {
            logger.info("Assistant off: the HomeswiftAiKit block names no provider")
        } else if let aiConfiguration, aiConfiguration.enabled {
            do {
                let service = try AssistantService(configuration: aiConfiguration, logger: logger)
                assistantBox.withLockedValue { $0 = service }
                logger.info("Assistant ready", metadata: ["provider": "\(service.providerName)", "model": "\(service.model)"])
            } catch {
                logger.error("Assistant unavailable: \(error)")
            }
        }

        for block in configuration.platforms where !options.systemPlatforms.contains(block.platform) {
            if configuration.disabledPlugins.contains(block.platform) {
                logger.info("Skipping disabled platform", metadata: ["platform": "\(block.platform)", "name": "\(block.name)"])
                continue
            }
            guard let entry = registry.entry(for: block.platform) else {
                logger.warning("No plugin for platform \"\(block.platform)\"; the block \"\(block.name)\" is ignored (homeswift plugins lists the available ones)")
                continue
            }
            var key = Self.slug("\(block.platform)-\(block.name)")
            var suffix = 2
            while keys.contains(key) {
                key = Self.slug("\(block.platform)-\(block.name)") + "-\(suffix)"
                suffix += 1
            }
            keys.insert(key)

            let bridge: Bridge
            if let child = block.childBridge {
                bridge = try Self.makeBridge(
                    name: child.name ?? block.name, username: child.username, pin: child.pin, port: child.port,
                    manufacturer: child.manufacturer, model: child.model, firmwareRevision: child.firmwareRevision,
                    storageName: "child-bridges/\(key)", isChild: true, storageDirectory: storageDirectory, options: options)
                bridges.append(bridge)
            } else {
                bridge = main
            }

            var pluginLogger = Logger(label: block.name)
            pluginLogger.logLevel = logger.logLevel
            let context = PluginContext(
                platform: block.platform, name: block.name, key: key, logger: pluginLogger, bridge: bridge,
                cache: AccessoryCache(url: storageDirectory.appendingPathComponent("accessories").appendingPathComponent("\(key).json")),
                storageURL: storageDirectory.appendingPathComponent("plugins").appendingPathComponent(key),
                assistant: assistantBox)
            context.restoreCache()
            instances.append(Instance(entry: entry, block: block, context: context))
        }

        self.bridges = bridges
        self.instances = instances
    }

    /// Starts the bridges, then creates and starts every plugin. Returns once each plugin's `start()` has
    /// returned; a plugin that throws is logged and left out.
    public func start() async throws {
        for bridge in bridges {
            try await bridge.server.start()
        }
        await withTaskGroup(of: Void.self) { group in
            for instance in instances {
                group.addTask { await self.launch(instance) }
            }
        }
    }

    /// Stops the plugins, saves the accessory caches, and stops the bridges.
    public func stop() async {
        for instance in instances {
            if let plugin = instance.plugin.withLockedValue({ $0 }) {
                await plugin.stop()
            }
            instance.context.saveCache()
        }
        for bridge in bridges {
            await bridge.server.stop()
        }
    }

    /// Hands a request from a plugin's web page to the instance it names. nil when no such instance runs.
    public func handleWebRequest(platform: String, name: String, _ request: PluginWebRequest) async throws -> PluginWebResponse? {
        guard let instance = instances.first(where: { $0.context.platform == platform && $0.context.name == name }),
              let plugin = instance.plugin.withLockedValue({ $0 }) else { return nil }
        return try await plugin.handleWebRequest(request)
    }

    /// Starts everything and keeps running until the task is cancelled.
    public func run() async throws {
        try await start()
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3600))
            }
        } catch {}
        await stop()
    }

    private func launch(_ instance: Instance) async {
        let context = instance.context
        do {
            let plugin = try await instance.entry.make(instance.block.json, context)
            instance.plugin.withLockedValue { $0 = plugin }
            try await plugin.start()
            context.logger.info("Started", metadata: ["plugin": "\(instance.entry.name)", "bridge": "\(context.bridge.name)"])
        } catch let error as DecodingError {
            context.logger.error("Invalid configuration for platform \"\(context.platform)\": \(Self.describe(error))")
        } catch {
            context.logger.error("Plugin failed to start: \(error)")
        }
    }

    private static func makeBridge(
        name: String, username: String?, pin: String?, port: Int?, manufacturer: String?, model: String?,
        firmwareRevision: String?, storageName: String, isChild: Bool, storageDirectory: URL, options: Options
    ) throws -> Bridge {
        var serverLogger = Logger(label: name)
        serverLogger.logLevel = options.logger.logLevel
        var serverOptions = HAPServer.Options(port: port, advertise: options.advertise, logger: serverLogger)
        if let pin {
            guard let code = SetupCode(pin) else { throw ConfigurationError.invalidSetupCode(pin) }
            serverOptions.setupCode = code
        }
        if let username {
            guard Self.isDeviceID(username) else { throw ConfigurationError.invalidUsername(username) }
            serverOptions.deviceID = username.uppercased()
        }
        let accessory = Accessory(
            id: "bridge", name: name, manufacturer: manufacturer ?? "Homeswift", model: model ?? "Homeswift",
            serialNumber: username?.uppercased(), firmwareRevision: firmwareRevision ?? version, category: .bridge,
            services: [Service(.protocolInformation, extra: [Characteristic(.version, value: "1.1.0")])])
        let storage = options.makeStorage?(storageName)
            ?? FileStorage(url: storageDirectory.appendingPathComponent("\(storageName).json"))
        let server = try HAPServer(bridge: accessory, accessories: [], storage: storage, options: serverOptions)
        accessory.information.characteristic(.serialNumber).value = .string(server.deviceID)
        return Bridge(name: name, server: server, isChild: isChild)
    }

    /// The first `HomeswiftAiKit` block, decoded; a malformed one is logged and ignored.
    static func loadAIConfiguration(_ configuration: HomeswiftConfiguration, logger: Logger) -> AIConfiguration? {
        guard let block = configuration.platforms.first(where: { $0.platform == AIConfiguration.platform }) else { return nil }
        do {
            return try AIConfiguration(block: try JSONValue(data: block.json))
        } catch {
            logger.error("Assistant unavailable: \(error)")
            return nil
        }
    }

    static func isDeviceID(_ string: String) -> Bool { HomeswiftConfiguration.isDeviceID(string) }

    /// A file-name-safe form of a platform instance name.
    static func slug(_ string: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in string.unicodeScalars {
            let keep = CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_"
            if keep {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return result.isEmpty ? "platform" : result
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [any CodingKey]) -> String {
            keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \"\(path(context.codingPath + [key]))\""
        case .typeMismatch(let type, let context): return "\"\(path(context.codingPath))\" must be \(type)"
        case .valueNotFound(let type, let context): return "\"\(path(context.codingPath))\" must be \(type), not null"
        case .dataCorrupted(let context): return context.codingPath.isEmpty ? context.debugDescription : "\"\(path(context.codingPath))\": \(context.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}
