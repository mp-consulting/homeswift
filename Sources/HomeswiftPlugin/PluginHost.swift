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
/// | `ai-usage.json` | The Assistant's usage per day, month, model and user, for its budgets |
public final class PluginHost: @unchecked Sendable {
    public static let version = "0.3.0"

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

    /// One HAP server: the main bridge, the child bridge of one platform block, or the standalone server of
    /// an external accessory (`isExternal`: one accessory, published by the platform instance `owner`).
    public final class Bridge: @unchecked Sendable {
        public let server: HAPServer
        public let isChild: Bool
        public let isExternal: Bool
        /// The platform instance that published this external accessory.
        public let owner: String?
        let ownerKey: String?
        private let storedName: String
        // Accessory ids on this bridge and the platform instance that owns each.
        private let owners = NIOLockedValueBox<[String: (key: String, name: String)]>([:])
        /// When it started, how often it was restarted, whether someone stopped it (`ChildBridges.swift`).
        let lifecycle = NIOLockedValueBox(Lifecycle())

        struct Lifecycle {
            var startedAt: Date?
            var restarts = 0
            var stoppedManually = false
        }

        init(name: String, server: HAPServer, isChild: Bool, isExternal: Bool = false, owner: String? = nil, ownerKey: String? = nil) {
            storedName = name
            self.server = server
            self.isChild = isChild
            self.isExternal = isExternal
            self.owner = owner
            self.ownerKey = ownerKey
        }

        /// The bridge's name, or the external accessory's.
        public var name: String { isExternal ? server.primary.name : storedName }

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
        /// Its block has `_paused`: the plugin does not run, its accessories answer No Response.
        public var paused = false
    }

    /// What `apply(_:)` did with a new configuration, by platform instance name.
    public struct ReloadReport: Sendable, Equatable {
        public var reloaded: [String] = []
        public var started: [String] = []
        public var stopped: [String] = []
        /// The runtime's own blocks that changed and that the host does not run itself (the web UI): whoever
        /// runs their servers restarts them. The Assistant's block is applied here.
        public var systemBlocksChanged: [String] = []
        /// Why a restart of the process is still needed: the main bridge's identity, port or setup code.
        public var needsRestart: [String] = []
    }

    final class Instance: @unchecked Sendable {
        let entry: PluginRegistry.Entry
        let block: HomeswiftConfiguration.Platform
        let context: PluginContext
        let plugin = NIOLockedValueBox<(any HomeswiftPlugin)?>(nil)
        /// Why its plugin did not start, the last time it was launched.
        let failure = NIOLockedValueBox<String?>(nil)

        init(entry: PluginRegistry.Entry, block: HomeswiftConfiguration.Platform, context: PluginContext) {
            self.entry = entry
            self.block = block
            self.context = context
        }
    }

    /// The configuration as last applied.
    public var configuration: HomeswiftConfiguration { configurationBox.withLockedValue { $0 } }
    public let storageDirectory: URL
    /// The plugins this host knows, whether or not config.json uses them.
    public let registry: PluginRegistry
    /// The main bridge first, then the child bridges in configuration order, then the external accessories
    /// in the order they were published.
    public var bridges: [Bridge] { bridgeList.withLockedValue { $0 } }
    private let bridgeList: NIOLockedValueBox<[Bridge]>
    let externals: ExternalAccessories
    public var mainBridge: Bridge { bridges[0] }
    public var platforms: [PlatformInstance] {
        instances.map {
            PlatformInstance(
                name: $0.context.name, platform: $0.context.platform, pluginName: $0.entry.name, bridge: $0.context.bridge,
                accessoryIDs: $0.context.accessories.map(\.id), paused: $0.block.paused)
        }
    }

    /// The Assistant of the `HomeswiftAiKit` block, when there is one that works.
    public var assistant: AssistantService? { assistantBox.withLockedValue { $0 } }
    /// The `HomeswiftAiKit` block as read, whether or not its provider could be set up.
    public var aiConfiguration: AIConfiguration? { aiConfigurationBox.withLockedValue { $0 } }
    private let aiConfigurationBox: NIOLockedValueBox<AIConfiguration?>

    var instances: [Instance] { instanceList.withLockedValue { $0 } }
    let options: Options
    let logger: Logger
    private let configurationBox: NIOLockedValueBox<HomeswiftConfiguration>
    private let instanceList = NIOLockedValueBox<[Instance]>([])
    private let assistantBox = NIOLockedValueBox<AssistantService?>(nil)
    // Characteristic changes of every server the host runs, for the web UI and the MCP server.
    private let changes: ChangeFeed
    // How long requests and handlers take on every server, for the Status page's charts.
    private let timings: TimingFeed
    // The tail of the reloads, so two quick saves apply one after the other.
    let reloadTail = NIOLockedValueBox<Task<Void, Never>?>(nil)

    /// Prepares the bridges and the plugins' contexts and restores the accessory caches. Nothing listens
    /// until `start()`.
    public init(configuration: HomeswiftConfiguration, registry: PluginRegistry, storageDirectory: URL, options: Options = Options()) throws {
        configurationBox = NIOLockedValueBox(configuration)
        self.storageDirectory = storageDirectory
        self.registry = registry
        self.options = options
        logger = options.logger

        let main = try Self.makeBridge(configuration.bridge, storageName: "homeswift", isChild: false, storageDirectory: storageDirectory, options: options)
        let bridgeList = NIOLockedValueBox([main])
        self.bridgeList = bridgeList
        let mainServer = main.server
        let changes = ChangeFeed()
        self.changes = changes
        changes.follow(mainServer)
        let timings = TimingFeed()
        self.timings = timings
        timings.follow(main)
        externals = ExternalAccessories(bridges: bridgeList, storageDirectory: storageDirectory, options: options, setupCode: { mainServer.setupCode }) { bridge in
            changes.follow(bridge.server)
            timings.follow(bridge)
        }

        if configuration.accessoryBlockCount > 0 {
            logger.warning("config.json has \(configuration.accessoryBlockCount) \"accessories\" block(s); Homeswift only runs platforms, they are ignored")
        }

        // The Assistant's block is the runtime's, not a plugin's. A bad one never stops the bridge.
        let ai = Self.loadAIConfiguration(configuration, logger: logger)
        aiConfigurationBox = NIOLockedValueBox(ai)
        assistantBox.withLockedValue { $0 = Self.makeAssistant(ai, storageDirectory: storageDirectory, logger: logger) }

        var instances: [Instance] = []
        for block in configuration.platforms where !options.systemPlatforms.contains(block.platform) {
            if configuration.disabledPlugins.contains(block.platform) {
                logger.info("Skipping disabled platform", metadata: ["platform": "\(block.platform)", "name": "\(block.name)"])
                continue
            }
            guard let entry = entry(for: block) else { continue }
            let instance = try makeInstance(block, entry: entry, taken: Set(instances.map(\.context.key)))
            if instance.context.bridge.isChild { appendBridge(instance.context.bridge) }
            instances.append(instance)
        }
        instanceList.withLockedValue { $0 = instances }
        for instance in instances { instance.context.restoreCache() }
    }

    /// Starts the bridges, then creates and starts every plugin. Returns once each plugin's `start()` has
    /// returned; a plugin that throws is logged and left out.
    public func start() async throws {
        for bridge in bridges {
            try await bridge.server.start()
            bridge.lifecycle.withLockedValue { $0.startedAt = Date() }
        }
        // From here on an external accessory a plugin publishes starts its server at once.
        externals.markRunning()
        await withTaskGroup(of: Void.self) { group in
            for instance in instances {
                group.addTask { await self.launch(instance) }
            }
        }
    }

    /// Stops the plugins, saves the accessory caches, and stops the bridges.
    public func stop() async {
        _ = await reloadTail.withLockedValue({ $0 })?.value
        for instance in instances {
            await stopPlugin(instance)
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

    /// The live feed of a camera, from the plugin instance whose accessory it is (`HomeswiftPlugin.liveFeed`). nil
    /// when no running instance has the accessory or its plugin has no feed for it.
    public func liveFeed(accessoryID: String) async throws -> CameraLiveFeed? {
        guard let instance = instances.first(where: { $0.context.accessories.contains { $0.id == accessoryID } }),
              let plugin = instance.plugin.withLockedValue({ $0 }) else { return nil }
        return try await plugin.liveFeed(accessoryID: accessoryID)
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

    /// Calls `observer` with every characteristic change on any server the host runs, those it adds later
    /// included (a child bridge, a television published after start), until the observation is cancelled.
    public func observeChanges(_ observer: @escaping HAPServer.ChangeObserver) -> Observation {
        changes.add(observer)
    }

    /// Calls `observer` with how long each request and handler took on any server the host runs, with that
    /// server's bridge, until the observation is cancelled.
    public func observeTimings(_ observer: @escaping @Sendable (Bridge, HAPServer.Timing) -> Void) -> Observation {
        timings.add(observer)
    }

    /// Applies a new configuration without a restart, the way a save in the web UI or over MCP should take
    /// effect: a changed platform block gets a fresh plugin on the same context (its accessories, aids, iids
    /// and pairings stay, and the plugin's `start()` drops what left the block), a new block starts, a
    /// removed one stops and leaves HomeKit, child bridges start and stop with their blocks, and the Assistant
    /// swaps. The runtime's other blocks (the web UI) are listed for whoever runs their servers; the bridge
    /// block, which only a restart changes, is listed as such.
    @discardableResult
    public func apply(_ next: HomeswiftConfiguration) async -> ReloadReport {
        let task = reloadTail.withLockedValue { tail -> Task<ReloadReport, Never> in
            let previous = tail
            let task = Task { () -> ReloadReport in
                _ = await previous?.value
                return await self.reload(to: next)
            }
            tail = Task { _ = await task.value }
            return task
        }
        return await task.value
    }

    private func reload(to next: HomeswiftConfiguration) async -> ReloadReport {
        var report = ReloadReport()
        let previous = configurationBox.withLockedValue { previous in
            defer { previous = next }
            return previous
        }
        if next.bridge != previous.bridge { report.needsRestart.append("the bridge block changed") }
        for platform in options.systemPlatforms.sorted() {
            let before = previous.platforms.filter { $0.platform == platform }.map(\.json)
            guard before != next.platforms.filter({ $0.platform == platform }).map(\.json) else { continue }
            if platform == AIConfiguration.platform {
                // The Assistant swaps in place: plugins read it through the shared box on every use.
                let ai = Self.loadAIConfiguration(next, logger: logger)
                aiConfigurationBox.withLockedValue { $0 = ai }
                assistantBox.withLockedValue { $0 = Self.makeAssistant(ai, storageDirectory: storageDirectory, logger: logger) }
            }
            report.systemBlocksChanged.append(platform)
        }
        let wanted = next.platforms.filter { !options.systemPlatforms.contains($0.platform) && !next.disabledPlugins.contains($0.platform) }
        let isSame = { (a: HomeswiftConfiguration.Platform, b: HomeswiftConfiguration.Platform) in a.platform == b.platform && a.name == b.name }

        for instance in instances where !wanted.contains(where: { isSame($0, instance.block) }) {
            await remove(instance)
            instance.context.logger.info("Stopped: the block left the configuration")
            report.stopped.append(instance.context.name)
        }

        for block in wanted {
            if let old = instances.first(where: { isSame($0.block, block) }) {
                guard old.block.json != block.json else { continue }
                if old.block.childBridge == block.childBridge {
                    // A fresh plugin on the same context: same accessories, aids, iids and pairings.
                    await stopPlugin(old)
                    let fresh = Instance(entry: old.entry, block: block, context: old.context)
                    instanceList.withLockedValue { list in
                        if let index = list.firstIndex(where: { $0 === old }) { list[index] = fresh }
                    }
                    await launch(fresh, as: "Reloaded")
                } else {
                    // On or off a child bridge, or a child bridge with other settings: the instance moves.
                    await remove(old)
                    await add(block, entry: old.entry, as: "Reloaded")
                }
                report.reloaded.append(block.name)
            } else {
                guard let entry = entry(for: block) else { continue }
                await add(block, entry: entry)
                report.started.append(block.name)
            }
        }
        logApplied(report)
        return report
    }

    /// One line per applied configuration, so the log shows what a save did without a restart.
    private func logApplied(_ report: ReloadReport) {
        let names = { (list: [String]) in list.isEmpty ? "-" : list.joined(separator: ", ") }
        let changed = !(report.reloaded.isEmpty && report.started.isEmpty && report.stopped.isEmpty && report.systemBlocksChanged.isEmpty)
        if !changed, report.needsRestart.isEmpty {
            logger.info("Configuration applied live: nothing changed for the running plugins")
            return
        }
        var metadata: Logger.Metadata = [
            "reloaded": "\(names(report.reloaded))", "started": "\(names(report.started))", "stopped": "\(names(report.stopped))",
        ]
        if !report.systemBlocksChanged.isEmpty { metadata["runtime"] = "\(names(report.systemBlocksChanged))" }
        if !report.needsRestart.isEmpty { metadata["needsRestart"] = "\(names(report.needsRestart))" }
        logger.info("Configuration applied live", metadata: metadata)
    }

    /// Stops an instance and takes its accessories out of HomeKit; its child bridge, if it had one, stops.
    private func remove(_ instance: Instance) async {
        await stopPlugin(instance)
        await instance.context.detach()
        instanceList.withLockedValue { $0.removeAll { $0 === instance } }
        let bridge = instance.context.bridge
        if bridge.isChild {
            bridgeList.withLockedValue { $0.removeAll { $0 === bridge } }
            await bridge.server.stop()
        }
    }

    /// Creates an instance for a block, on a new child bridge when it asks for one, restores its cache and
    /// starts its plugin; servers start at once when the host runs.
    private func add(_ block: HomeswiftConfiguration.Platform, entry: PluginRegistry.Entry, as verb: String = "Started") async {
        let instance: Instance
        do {
            instance = try makeInstance(block, entry: entry, taken: Set(instances.map(\.context.key)))
            if instance.context.bridge.isChild {
                if externals.isRunning {
                    try await instance.context.bridge.server.start()
                    instance.context.bridge.lifecycle.withLockedValue { $0.startedAt = Date() }
                }
                appendBridge(instance.context.bridge)
            }
        } catch {
            logger.error("Could not start the child bridge of \"\(block.name)\": \(error)")
            return
        }
        let context = instance.context
        for server in context.restoreCache() where externals.isRunning {
            do { try await server.start() } catch { context.logger.warning("Could not start a restored accessory: \(error)") }
        }
        instanceList.withLockedValue { $0.append(instance) }
        await launch(instance, as: verb)
    }

    /// The Assistant of a `HomeswiftAiKit` block; nil when it is off or its provider cannot be set up.
    /// The Assistant of the HomeswiftAiKit block; its usage, and so its budget, is kept in `ai-usage.json` across launches.
    private static func makeAssistant(_ ai: AIConfiguration?, storageDirectory: URL, logger: Logger) -> AssistantService? {
        guard let ai, ai.enabled else { return nil }
        guard ai.hasProviderSettings else {
            logger.info("Assistant off: the HomeswiftAiKit block names no provider")
            return nil
        }
        do {
            let store = FileUsageStore(url: storageDirectory.appendingPathComponent(UsageTracker.fileName), write: OwnerOnlyFile.write)
            let service = try AssistantService(configuration: ai, usageStore: store, logger: logger)
            logger.info("Assistant ready", metadata: ["provider": "\(service.providerName)", "model": "\(service.model)"])
            return service
        } catch {
            logger.error("Assistant unavailable: \(error)")
            return nil
        }
    }

    func stopPlugin(_ instance: Instance) async {
        if let plugin = instance.plugin.withLockedValue({ $0 }) {
            await plugin.stop()
        }
        instance.plugin.withLockedValue { $0 = nil }
        instance.context.saveCache()
    }

    /// The plugin for a block; nil, with a line in the log, when no plugin compiled in provides its platform.
    private func entry(for block: HomeswiftConfiguration.Platform) -> PluginRegistry.Entry? {
        guard let entry = registry.entry(for: block.platform) else {
            logger.warning("No plugin for platform \"\(block.platform)\"; the block \"\(block.name)\" is ignored (homeswift plugins lists the available ones)")
            return nil
        }
        return entry
    }

    /// What runs a block: a key no other instance has, its bridge (a new child bridge when it asks for one, which
    /// the caller adds with `appendBridge`) and its context. The caller restores its cache and launches it.
    private func makeInstance(_ block: HomeswiftConfiguration.Platform, entry: PluginRegistry.Entry, taken: Set<String>) throws -> Instance {
        let key = Self.uniqueKey(for: block, taken: taken)
        var bridge = mainBridge
        if let child = block.childBridge {
            bridge = try Self.makeBridge(child.bridge(named: block.name), storageName: "child-bridges/\(key)", isChild: true, storageDirectory: storageDirectory, options: options)
        }
        let context = Self.makeContext(block: block, key: key, bridge: bridge, storageDirectory: storageDirectory, logLevel: logger.logLevel, assistant: assistantBox, externals: externals, assistantBackground: entry.assistantBackground)
        return Instance(entry: entry, block: block, context: context)
    }

    /// Lists a new bridge and follows its changes and timings.
    private func appendBridge(_ bridge: Bridge) {
        bridgeList.withLockedValue { $0.append(bridge) }
        changes.follow(bridge.server)
        timings.follow(bridge)
    }

    private static func uniqueKey(for block: HomeswiftConfiguration.Platform, taken: Set<String>) -> String {
        let base = slug("\(block.platform)-\(block.name)")
        var key = base
        var suffix = 2
        while taken.contains(key) {
            key = base + "-\(suffix)"
            suffix += 1
        }
        return key
    }

    private static func makeContext(
        block: HomeswiftConfiguration.Platform, key: String, bridge: Bridge, storageDirectory: URL, logLevel: Logger.Level,
        assistant: NIOLockedValueBox<AssistantService?>, externals: ExternalAccessories, assistantBackground: String?
    ) -> PluginContext {
        var pluginLogger = Logger(label: block.name)
        pluginLogger.logLevel = logLevel
        return PluginContext(
            platform: block.platform, name: block.name, key: key, logger: pluginLogger, bridge: bridge,
            cache: AccessoryCache(url: storageDirectory.appendingPathComponent("accessories").appendingPathComponent("\(key).json")),
            storageURL: storageDirectory.appendingPathComponent("plugins").appendingPathComponent(key),
            assistant: assistant, externals: externals, assistantBackground: assistantBackground)
    }

    func launch(_ instance: Instance, as verb: String = "Started") async {
        let context = instance.context
        instance.failure.withLockedValue { $0 = nil }
        // A child bridge someone stopped: its plugins wait for start_child_bridge.
        if context.bridge.lifecycle.withLockedValue({ $0.stoppedManually }) { return }
        // A paused block: no plugin, so nothing reaches the devices; its accessories stay in HomeKit, answering
        // No Response, and come back as they were when it resumes.
        let paused = instance.block.paused
        for accessory in context.accessories where accessory.isUnavailable != paused { accessory.isUnavailable = paused }
        if paused {
            context.logger.info("Paused: the plugin does not run, and its accessories show No Response until it resumes")
            return
        }
        do {
            let plugin = try await instance.entry.make(instance.block.json, context)
            instance.plugin.withLockedValue { $0 = plugin }
            try await plugin.start()
            context.logger.info("\(verb)", metadata: ["plugin": "\(instance.entry.name)", "bridge": "\(context.bridge.name)"])
        } catch let error as DecodingError {
            instance.failure.withLockedValue { $0 = "invalid configuration: \(Self.describe(error))" }
            context.logger.error("Invalid configuration for platform \"\(context.platform)\": \(Self.describe(error))")
        } catch {
            instance.failure.withLockedValue { $0 = "\(error)" }
            context.logger.error("Plugin failed to start: \(error)")
        }
    }

    private static func makeBridge(
        _ settings: HomeswiftConfiguration.Bridge, storageName: String, isChild: Bool, storageDirectory: URL, options: Options
    ) throws -> Bridge {
        var serverLogger = Logger(label: settings.name)
        serverLogger.logLevel = options.logger.logLevel
        var serverOptions = HAPServer.Options(port: settings.port, advertise: options.advertise, logger: serverLogger)
        if let pin = settings.pin {
            guard let code = SetupCode(pin) else { throw ConfigurationError.invalidSetupCode(pin) }
            serverOptions.setupCode = code
        }
        if let username = settings.username {
            guard HomeswiftConfiguration.isDeviceID(username) else { throw ConfigurationError.invalidUsername(username) }
            serverOptions.deviceID = username.uppercased()
        }
        let accessory = Accessory(
            id: "bridge", name: settings.name, manufacturer: settings.manufacturer ?? "Homeswift", model: settings.model ?? "Homeswift",
            serialNumber: settings.username?.uppercased(), firmwareRevision: settings.firmwareRevision ?? version, category: .bridge, services: [])
        let storage = options.makeStorage?(storageName)
            ?? FileStorage(url: storageDirectory.appendingPathComponent("\(storageName).json"))
        let server = try HAPServer(bridge: accessory, accessories: [], storage: storage, options: serverOptions)
        accessory.information.characteristic(.serialNumber).value = .string(server.deviceID)
        return Bridge(name: settings.name, server: server, isChild: isChild)
    }

    /// The first `HomeswiftAiKit` block, decoded; a malformed one is logged and ignored.
    static func loadAIConfiguration(_ configuration: HomeswiftConfiguration, logger: Logger) -> AIConfiguration? {
        do {
            guard let block = try configuration.block(for: AIConfiguration.platform) else { return nil }
            return try AIConfiguration(block: block)
        } catch {
            logger.error("Assistant unavailable: \(error)")
            return nil
        }
    }

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
