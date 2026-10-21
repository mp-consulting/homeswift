import Foundation
import Homeswift
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers

/// A Homeswift plugin. Each `platform` block in config.json becomes one instance.
///
/// The runtime decodes the block into `Configuration`, creates the plugin with a `PluginContext`, and
/// calls `start()` once the bridge is listening. Add accessories through the context whenever a device is
/// known; adding one whose `id` is already on the bridge (restored from the cache, or added earlier by the
/// same plugin) replaces it and keeps its aid and iids, so HomeKit keeps its rooms, scenes and automations.
///
/// ```swift
/// actor MyPlugin: HomeswiftPlugin {
///     struct Configuration: Decodable, Sendable { var host: String }
///     static let platform = "MyDevices"
///     static let name = "My Devices"
///     let configuration: Configuration
///     let context: PluginContext
///
///     init(configuration: Configuration, context: PluginContext) {
///         self.configuration = configuration
///         self.context = context
///     }
///
///     func start() async throws {
///         let lamp = Accessory(id: "MyDevices:serial-1", name: "Lamp", category: .lightbulb, services: [...])
///         try context.add(lamp)
///     }
/// }
/// ```
public protocol HomeswiftPlugin: Sendable {
    /// The plugin's settings, decoded from its block in config.json with `JSONDecoder`. Unknown keys are
    /// ignored, so the block's `platform`, `name` and `_bridge` keys need no properties.
    associatedtype Configuration: Decodable & Sendable

    /// The value of the block's `platform` key, e.g. `"ElgatoKeyLights"`. A plugin ported from Homebridge
    /// keeps its platform name so users can paste their blocks.
    static var platform: String { get }

    /// Shown by `homeswift plugins`, e.g. `"Elgato Key Lights"`. Defaults to `platform`.
    static var name: String { get }

    /// The plugin's `config.schema.json` as text (key order kept), for the settings form of the web UI and
    /// the Assistant's config copilot. `Scripts/embed-assets.swift plugin` generates it from the file.
    /// Defaults to nil: no form, only the raw block.
    static var configurationSchemaJSON: String? { get }

    /// Creates the instance. Throw for settings the plugin cannot work with; the runtime logs the error
    /// and leaves this block out, the other plugins keep running.
    init(configuration: Configuration, context: PluginContext) async throws

    /// Called once the bridge is listening. Discover devices and add accessories; long-running work
    /// (discovery, polling) goes in tasks the plugin owns and cancels in `stop()`. Throwing logs the error
    /// and leaves the plugin stopped.
    func start() async throws

    /// Called at shutdown: cancel tasks and close connections. The runtime saves the accessory cache
    /// afterwards. Defaults to doing nothing.
    func stop() async
}

extension HomeswiftPlugin {
    public static var name: String { platform }
    public static var configurationSchemaJSON: String? { nil }
    public func stop() async {}
}

/// Errors the runtime reports to a plugin.
public enum PluginError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Another plugin on the same bridge already added an accessory with this `id`. Prefix ids with the
    /// platform name (`"ElgatoKeyLights:<serial>"`) so serial numbers of different brands cannot clash.
    case accessoryIDInUse(id: String, by: String)
    /// `remove(id:)` for an accessory the plugin never added.
    case unknownAccessory(id: String)

    public var description: String {
        switch self {
        case .accessoryIDInUse(let id, let by): "accessory id \"\(id)\" is already used by \(by)"
        case .unknownAccessory(let id): "no accessory with id \"\(id)\""
        }
    }
}

/// What a plugin instance gets from the runtime: a logger, a directory for its own files, and the bridge
/// it adds accessories to.
public final class PluginContext: @unchecked Sendable {
    /// The block's `platform`.
    public let platform: String
    /// The block's `name`, or the platform when the block has none. Logs and files are named after it.
    public let name: String
    /// Log through this: lines carry the instance name, and `homeswift -D` turns on debug output.
    public let logger: Logger
    /// A directory for the plugin's own files (tokens, device caches), created on first use. Its contents
    /// are the plugin's; the runtime keeps the accessory cache elsewhere.
    public var storageDirectory: URL {
        // Owner-only: plugins keep tokens here.
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return storageURL
    }

    /// The Assistant, when config.json has a `HomeswiftAiKit` block: explain an error, answer a question,
    /// write a configuration block. nil otherwise, so plugins must work without it. Requests carry the
    /// plugin's name so answers can refer to it; inputs are redacted before they reach the provider.
    public var assistant: (any Assistant)? {
        assistantBox.withLockedValue { $0 }?.withContext("The requests come from the Homeswift plugin \"\(name)\" (platform \(platform)).")
    }

    let key: String
    let bridge: PluginHost.Bridge
    let cache: AccessoryCache
    private let storageURL: URL
    private let assistantBox: NIOLockedValueBox<AssistantService?>
    // Mutable state is behind the lock; the class is otherwise immutable.
    private let list = NIOLockedValueBox<[Accessory]>([])

    init(
        platform: String, name: String, key: String, logger: Logger, bridge: PluginHost.Bridge, cache: AccessoryCache, storageURL: URL,
        assistant: NIOLockedValueBox<AssistantService?>
    ) {
        self.platform = platform
        self.name = name
        self.key = key
        self.logger = logger
        self.bridge = bridge
        self.cache = cache
        self.storageURL = storageURL
        assistantBox = assistant
    }

    /// The accessories this instance has on the bridge, including those restored from the cache at
    /// launch that the plugin has not replaced yet.
    public var accessories: [Accessory] { list.withLockedValue { $0 } }

    public func accessory(id: String) -> Accessory? {
        list.withLockedValue { $0.first { $0.id == id } }
    }

    /// Adds an accessory to the bridge, or replaces the one with the same `id`. HomeKit sees the change
    /// through the configuration number; the aid and iids stay, so rooms and automations survive.
    public func add(_ accessory: Accessory) throws {
        try bridge.claim(accessory.id, for: key, name: name)
        try bridge.server.add(accessory)
        list.withLockedValue { list in
            if let index = list.firstIndex(where: { $0.id == accessory.id }) {
                list[index] = accessory
            } else {
                list.append(accessory)
            }
        }
        saveCache()
    }

    /// Removes an accessory from the bridge. HomeKit drops it from its rooms.
    public func remove(_ accessory: Accessory) throws {
        try remove(id: accessory.id)
    }

    public func remove(id: String) throws {
        guard let accessory = self.accessory(id: id) else { throw PluginError.unknownAccessory(id: id) }
        try bridge.server.remove(accessory)
        bridge.release(id)
        list.withLockedValue { $0.removeAll { $0.id == id } }
        saveCache()
    }

    /// Puts the cached accessories back on the bridge before the plugin starts.
    func restoreCache() {
        for accessory in cache.load(logger: logger) {
            do {
                try bridge.claim(accessory.id, for: key, name: name)
                try bridge.server.add(accessory)
                list.withLockedValue { $0.append(accessory) }
                logger.info("Restored accessory from cache", metadata: ["accessory": "\(accessory.name)"])
            } catch {
                logger.warning("Could not restore cached accessory", metadata: ["accessory": "\(accessory.name)", "error": "\(error)"])
            }
        }
    }

    func saveCache() {
        do {
            try cache.save(accessories)
        } catch {
            logger.warning("Could not save the accessory cache", metadata: ["path": "\(cache.url.path)", "error": "\(error)"])
        }
    }
}
