import Foundation
import Homeswift
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers
@_exported import enum HomeswiftAI.JSONValue

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

    /// The plugin's own web pages, served by the web UI at `/plugins/<platform>/`; `index.html` opens from
    /// the Plugins page. Keep them in the plugin's `Web/` directory and embed them with
    /// `Scripts/embed-assets.swift web Plugins/<Name>/Web Plugins/<Name>/Sources/WebFiles.swift <Type>`.
    /// Defaults to none. `docs/ui.md` describes what a page can do.
    static var webFiles: [String: WebFile] { get }

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

    /// Answers a request from the plugin's own pages (`homeswift.request()` in their script), which the
    /// web UI sends to `/api/plugins/<platform>/<name>/<path>` for a signed-in user. Defaults to 404.
    func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse
}

extension HomeswiftPlugin {
    public static var name: String { platform }
    public static var configurationSchemaJSON: String? { nil }
    public static var webFiles: [String: WebFile] { [:] }
    public func stop() async {}
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse { .error(404, "\(Self.name) has no web API") }
}

/// A file of a web page: the UI's own, or a plugin's.
public struct WebFile: Sendable, Equatable {
    public let contentType: String
    public let body: String

    public init(contentType: String, body: String) {
        self.contentType = contentType
        self.body = body
    }
}

/// A request from a plugin's web page to the instance that serves it.
public struct PluginWebRequest: Sendable {
    /// GET, POST, PUT or DELETE.
    public let method: String
    /// What follows `/api/plugins/<platform>/<name>/`, without a leading slash.
    public let path: String
    public let query: [String: String]
    /// The JSON body, or `.null`.
    public let body: JSONValue
    /// The signed-in user.
    public let user: String

    public init(method: String, path: String, query: [String: String] = [:], body: JSONValue = .null, user: String) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.user = user
    }
}

/// A plugin's answer to its page: JSON and a status.
public struct PluginWebResponse: Sendable, Equatable {
    public var status: Int
    public var json: JSONValue

    public init(_ json: JSONValue, status: Int = 200) {
        self.json = json
        self.status = status
    }

    public static func error(_ status: Int, _ message: String) -> PluginWebResponse {
        PluginWebResponse(["error": .string(message)], status: status)
    }
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
    let externals: ExternalAccessories
    private let storageURL: URL
    private let assistantBox: NIOLockedValueBox<AssistantService?>
    // Mutable state is behind the lock; the class is otherwise immutable.
    private let list = NIOLockedValueBox<Entries>(Entries())

    private struct Entries {
        var accessories: [Accessory] = []
        /// The ids published as external accessories.
        var external: Set<String> = []

        mutating func put(_ accessory: Accessory) {
            if let index = accessories.firstIndex(where: { $0.id == accessory.id }) {
                accessories[index] = accessory
            } else {
                accessories.append(accessory)
            }
        }
    }

    init(
        platform: String, name: String, key: String, logger: Logger, bridge: PluginHost.Bridge, cache: AccessoryCache, storageURL: URL,
        assistant: NIOLockedValueBox<AssistantService?>, externals: ExternalAccessories
    ) {
        self.platform = platform
        self.name = name
        self.key = key
        self.logger = logger
        self.bridge = bridge
        self.cache = cache
        self.storageURL = storageURL
        assistantBox = assistant
        self.externals = externals
    }

    /// The accessories this instance has on the bridge or published on their own, including those
    /// restored from the cache at launch that the plugin has not replaced yet.
    public var accessories: [Accessory] { list.withLockedValue { $0.accessories } }

    public func accessory(id: String) -> Accessory? {
        list.withLockedValue { $0.accessories.first { $0.id == id } }
    }

    /// Whether the accessory with this id is published on its own server rather than on the bridge.
    public func isExternal(id: String) -> Bool { list.withLockedValue { $0.external.contains(id) } }

    /// Adds an accessory to the bridge, or replaces the one with the same `id`. HomeKit sees the change
    /// through the configuration number; the aid and iids stay, so rooms and automations survive.
    public func add(_ accessory: Accessory) throws {
        try bridge.claim(accessory.id, for: key, name: name)
        if isExternal(id: accessory.id) {
            // Moving from its own server to the bridge: the old server stops in the background.
            let externals = externals, id = accessory.id, key = key
            Task { await externals.unpublish(id: id, key: key) }
            _ = list.withLockedValue { $0.external.remove(accessory.id) }
        }
        try bridge.server.add(accessory)
        list.withLockedValue { $0.put(accessory) }
        saveCache()
    }

    /// Publishes an accessory on a HAP server of its own instead of the bridge, as Homebridge publishes
    /// external accessories: HomeKit wants televisions (one per bridge at most) and cameras this way. The
    /// server has its own identity and pairing, listed with the bridges (`PluginHost.bridges`), and the
    /// main bridge's setup code; the user adds it in the Home app like a second bridge. Publishing an id
    /// again replaces the accessory under the same identity, so a television whose inputs changed keeps
    /// its pairing. The id must still be unique on the bridge.
    public func publishExternal(_ accessory: Accessory) async throws {
        try bridge.claim(accessory.id, for: key, name: name)
        if self.accessory(id: accessory.id) != nil, !isExternal(id: accessory.id) {
            try bridge.server.remove(accessory)
        }
        let (published, isNew) = try externals.publish(accessory, key: key, owner: name)
        list.withLockedValue { entries in
            entries.put(accessory)
            entries.external.insert(accessory.id)
        }
        saveCache()
        if isNew, externals.isRunning {
            try await published.server.start()
        }
    }

    /// Removes an accessory from the bridge, or stops the server of an external one. HomeKit drops it
    /// from its rooms.
    public func remove(_ accessory: Accessory) async throws {
        try await remove(id: accessory.id)
    }

    public func remove(id: String) async throws {
        guard let accessory = self.accessory(id: id) else { throw PluginError.unknownAccessory(id: id) }
        if isExternal(id: id) {
            await externals.unpublish(id: id, key: key)
        } else {
            try bridge.server.remove(accessory)
        }
        bridge.release(id)
        list.withLockedValue { entries in
            entries.accessories.removeAll { $0.id == id }
            entries.external.remove(id)
        }
        saveCache()
    }

    /// Puts the cached accessories back on the bridge, or on their own servers, before the plugin starts.
    func restoreCache() {
        for (accessory, external) in cache.load(logger: logger) {
            do {
                try bridge.claim(accessory.id, for: key, name: name)
                if external {
                    _ = try externals.publish(accessory, key: key, owner: name)
                } else {
                    try bridge.server.add(accessory)
                }
                list.withLockedValue { entries in
                    entries.accessories.append(accessory)
                    if external { entries.external.insert(accessory.id) }
                }
                logger.info("Restored accessory from cache", metadata: ["accessory": "\(accessory.name)", "external": "\(external)"])
            } catch {
                logger.warning("Could not restore cached accessory", metadata: ["accessory": "\(accessory.name)", "error": "\(error)"])
            }
        }
    }

    func saveCache() {
        do {
            let (accessories, external) = list.withLockedValue { ($0.accessories, $0.external) }
            try cache.save(accessories, external: external)
        } catch {
            logger.warning("Could not save the accessory cache", metadata: ["path": "\(cache.url.path)", "error": "\(error)"])
        }
    }
}
