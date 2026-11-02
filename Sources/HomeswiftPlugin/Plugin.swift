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

    /// The web UI's icon for the plugin (its Plugins page card, its node on the graph): a name from the web UI's
    /// icons in `Sources/HomeswiftUI/Web/common.js`, its brand's logo (`"logo-elgato"`) where one is there, else what
    /// it controls (`"bulb"`, `"thermo"`). A new logo goes into common.js's `logos`. Defaults to nil: a plug.
    static var icon: String? { get }

    /// What the plugin brings, in one short line under its name in the web UI's list of plugins to add: the devices
    /// and what it does with them ("Lights, scenes, effects and sensors from a Hue Bridge"), not the brand again. In
    /// English; the web UI's catalogs translate it (`TranslationTests` checks). Defaults to nil: no line.
    static var summary: String? { get }

    /// The plugin's `config.schema.json` as text (key order kept), for the settings form of the web UI and
    /// the Assistant's config copilot. `Scripts/embed-assets.swift plugin` generates it from the file.
    /// Defaults to nil: no form, only the raw block.
    static var configurationSchemaJSON: String? { get }

    /// The plugin's own web pages, served by the web UI at `/plugins/<platform>/`; `index.html` opens from
    /// the Plugins page. Keep them in the plugin's `Web/` directory and embed them with
    /// `Scripts/embed-assets.swift web Plugins/<Name>/Web Plugins/<Name>/Sources/WebFiles.swift <Type>`.
    /// Defaults to none. `docs/ui.md` describes what a page can do.
    static var webFiles: [String: WebFile] { get }

    /// What the Assistant may do with an instance, from the web UI's chat or an MCP client: routes of
    /// `handleWebRequest` described for a model (find devices, check an address, pair). Defaults to none.
    static var assistantActions: [AssistantAction] { get }

    /// What the Assistant should know about the plugin's devices and services to explain their errors: what
    /// the error messages mean, quotas, ports, the usual fixes. It goes with every request the plugin's pages and
    /// its `context.assistant` make, so keep it to a paragraph or two, and never ask for secrets in it. Defaults to nil.
    static var assistantBackground: String? { get }

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

    /// The live video of one of the plugin's cameras for the web UI's camera cards: fMP4 for Media Source
    /// Extensions, its initialization segment first (`CameraLiveFeed`). The UI asks when a card comes into view
    /// and cancels the feed when it leaves; share the camera's source with HomeKit's own streams where it can, and
    /// prefer a low-bandwidth channel. Defaults to nil: the card shows the camera's snapshots instead, from its
    /// `CameraController`.
    func liveFeed(accessoryID: String) async throws -> CameraLiveFeed?

    /// The scenes the plugin's hub keeps, for Homeswift to list with its own (`PluginScene`). Asked each time they
    /// are listed, so answer from what the plugin already knows rather than asking the hub. Defaults to none.
    func scenes() async -> [PluginScene]

    /// Recalls one of `scenes()` by its `PluginScene.id`. Defaults to throwing.
    func recallScene(id: String) async throws

    /// Plays an effect on those of these accessories the plugin can animate the way its brand's app does (a Hue
    /// light's fire effect, a Govee light's library scene); answers the ids it plays. Homeswift plays the others
    /// itself, and puts every light back when the scene stops. Defaults to none.
    func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String>

    /// Stops what `animate` started on these accessories; Homeswift then puts their values back. Defaults to nothing.
    func stopAnimation(accessoryIDs: [String]) async

    /// Where a new scene of exactly these lights would be kept on the plugin's hub (a Hue room or zone, an IKEA hub),
    /// to offer "Save to …"; nil when the hub cannot keep it (a light it does not have). Defaults to nil.
    func sceneTarget(accessoryIDs: [String]) async -> String?

    /// Makes a scene on the hub with these lights' states; answers its `PluginScene.id`. Defaults to throwing.
    func createScene(name: String, lights: [PluginSceneLight]) async throws -> String

    /// Renames a scene of the hub (`name`) and replaces its lights' states (`lights`), either or both: what its
    /// `PluginScene.capabilities` allow (`rename`, `update`). Defaults to throwing.
    func updateScene(id: String, name: String?, lights: [PluginSceneLight]?) async throws

    /// Removes a scene from the hub (`delete` capability). Homeswift asks the person first. Defaults to throwing.
    func deleteScene(id: String) async throws

    /// The rooms the plugin's hub or cloud keeps (`PluginRoom`), for Homeswift to rename the one named like a room
    /// renamed in Homeswift, when `syncRoomNames` is on. Asked only then, so it may ask the hub. Defaults to none.
    func rooms() async -> [PluginRoom]

    /// Renames one of `rooms()` by its `PluginRoom.id` on the hub. Defaults to throwing.
    func renameRoom(id: String, name: String) async throws

    /// What the instance's account asks before the plugin may use it (Setup, `Setup.swift`): a cloud's login, a
    /// developer portal's keys. Defaults to `.none`: no account, or one whose settings the form takes as they are.
    static var accountAuthorization: AuthorizationMethod { get }

    /// The devices the plugin can find now, set up or not (GLOSSARY.md, "Discovered Device"): on the network, in the
    /// account, at the addresses its settings name. It may run on an instance that was not started, created only to set
    /// up; it should answer within a few seconds. Defaults to none.
    func discover() async throws -> [DiscoveredDevice]

    /// Answers one step of the Authorization of the account (`accountAuthorization`) or of a device (its
    /// `DiscoveredDevice.authorization`). It may run on an instance that was not started, and on another instance than
    /// the step before: keep what the next step needs in `SetupStep.ask`'s state. Throw `SetupError` for an answer that
    /// did not work. Defaults to done, with nothing to keep.
    func authorize(_ request: SetupRequest) async throws -> SetupStep

    /// Whether the account is Authorized, for a plugin that keeps what its Authorization gave itself (tokens it refreshes
    /// in its own vault entries). Defaults to nil: the bridge looks for the account's credentials (`context.credentials()`).
    func accountAuthorized() async -> Bool?

    /// The Device Id of an accessory whose id, after `<platform>:`, is not the Device Id or the Device Id followed by `:` or
    /// `.` (eWeLink's channels, `<deviceID>SW<n>`), so Excluded reaches it. Defaults to nil: those two forms only.
    static func deviceID(ofAccessory suffix: String) -> String?

    /// The automations the plugin's hub keeps (`PluginAutomation`), such as Apple Home's through Wingman. Defaults to
    /// none.
    func automations() async -> [PluginAutomation]

    /// Changes an automation on the hub: what its `PluginAutomation.capabilities` allow. Defaults to throwing.
    func updateAutomation(id: String, change: PluginAutomationChange) async throws

    /// Removes an automation from the hub (`delete` capability). Defaults to throwing.
    func deleteAutomation(id: String) async throws
}

extension HomeswiftPlugin {
    public static var name: String { platform }
    public static var icon: String? { nil }
    public static var summary: String? { nil }
    public static var configurationSchemaJSON: String? { nil }
    public static var webFiles: [String: WebFile] { [:] }
    public static var assistantActions: [AssistantAction] { [] }
    public static var assistantBackground: String? { nil }
    public func stop() async {}
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse { .error(404, "\(Self.name) has no web API") }
    public func liveFeed(accessoryID: String) async throws -> CameraLiveFeed? { nil }
    public static var accountAuthorization: AuthorizationMethod { .none }
    public func discover() async throws -> [DiscoveredDevice] { [] }
    public func authorize(_ request: SetupRequest) async throws -> SetupStep { .done(SetupOutcome()) }
    public func accountAuthorized() async -> Bool? { nil }
    public static func deviceID(ofAccessory suffix: String) -> String? { nil }
}

/// One route of a plugin's `handleWebRequest` that the Assistant may call, as the tool
/// `<platform>_<name>`. The arguments go in the query of a `GET`, and in the JSON body otherwise, except
/// those named in `queryKeys`. The answer goes to the model with its secrets as handles it can pass on but
/// not read, so a pairing's password reaches config.json without the provider seeing it.
///
/// ```swift
/// AssistantAction(name: "probe", title: "Check an address", description: "Asks the light at host:port who it is.",
///                 method: "GET", path: "probe", access: .read,
///                 inputSchema: ["type": "object", "required": ["host"], "properties": ["host": ["type": "string"]]])
/// ```
public struct AssistantAction: Sendable {
    /// Who may call it: an MCP token's scope; `configure` needs admin.
    public enum Access: String, Sendable {
        case read, control, configure
    }

    public var name: String
    /// For people, while it runs: "Find TVs".
    public var title: String
    /// For the model: what it does, what it needs, what comes back and what to do with it.
    public var description: String
    public var method: String
    public var path: String
    public var access: Access
    /// A JSON Schema object for the arguments.
    public var inputSchema: JSONValue
    public var queryKeys: Set<String>
    /// The user confirms before it runs.
    public var confirm: Bool
    /// It may change lights (a scene recalled on the device's own hub): the bridge keeps how the lights it changed
    /// were, and `stop_scene` puts them back, as after any scene.
    public var changesLights: Bool

    public init(
        name: String, title: String, description: String, method: String = "GET", path: String, access: Access,
        inputSchema: JSONValue = ["type": "object", "properties": [:]], queryKeys: Set<String> = [], confirm: Bool = false, changesLights: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.method = method
        self.path = path
        self.access = access
        self.inputSchema = inputSchema
        self.queryKeys = queryKeys
        self.confirm = confirm
        self.changesLights = changesLights
    }

    /// The request for these arguments.
    public func request(arguments: JSONValue, user: String) -> PluginWebRequest {
        var query: [String: String] = [:]
        var body: [String: JSONValue] = [:]
        for (key, value) in arguments.objectValue ?? [:] {
            if method == "GET" || queryKeys.contains(key) {
                query[key] = value.stringValue ?? value.text()
            } else {
                body[key] = value
            }
        }
        return PluginWebRequest(method: method, path: path, query: query, body: body.isEmpty ? .null : .object(body), user: user)
    }
}

/// A file of a web page: the UI's own, or a plugin's.
public struct WebFile: Sendable, Equatable {
    public let contentType: String
    /// The text, or for a binary file (an icon) its bytes in base64.
    public let body: String
    public let isBase64: Bool

    public init(contentType: String, body: String) {
        self.contentType = contentType
        self.body = body
        isBase64 = false
    }

    /// A binary file, its bytes in base64.
    public init(contentType: String, base64: String) {
        self.contentType = contentType
        body = base64
        isBase64 = true
    }

    /// The bytes as served.
    public var data: Data { isBase64 ? Data(base64Encoded: body) ?? Data() : Data(body.utf8) }
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
        assistantBox.withLockedValue { $0 }?.withContext(Self.assistantContext(name: name, platform: platform, background: assistantBackground))
    }

    /// Who is asking, and the plugin's `assistantBackground`: the Assistant's instructions for a plugin's requests.
    public static func assistantContext(name: String, platform: String, background: String?) -> String {
        let who = "The requests come from the Homeswift plugin \"\(name)\" (platform \(platform))."
        guard let background = background?.trimmingCharacters(in: .whitespacesAndNewlines), !background.isEmpty else { return who }
        return "\(who)\n\nBackground on the plugin:\n\(background)"
    }

    let key: String
    let bridge: PluginHost.Bridge
    let cache: AccessoryCache
    /// The names a person gave the accessories (`_accessories`), put on each one it adds.
    let naming: AccessoryNaming
    let externals: ExternalAccessories
    let storageURL: URL
    /// The bridge's storage directory (`homeswift -U`): where `vault.json` and `secrets.key` are (`secretFile`), and the
    /// core's files plugins share (scenes' pictures).
    let vaultStorage: URL
    private let assistantBox: NIOLockedValueBox<AssistantService?>
    private let assistantBackground: String?
    private let recordSink: @Sendable (String, Double, EnergyTag?) -> Void
    private let energyImportSink: @Sendable ([EnergyHourImport]) -> Void
    private let energyProgressSink: @Sendable (EnergyImportProgress) -> Void

    /// Records a reading for the Status page's history: a minute keeps the count, sum, lowest and highest of each
    /// series. The series is `plugin:<platform>:<series>`, so two plugins cannot collide. Cheap; call it per reading.
    /// `energy` puts the series in the Status page's Energy section: its role (solar, home, grid, battery power or
    /// level, in watts or percent, with the signs `EnergyRole` gives) and the device's name.
    public func recordValue(_ value: Double, series: String, energy: EnergyTag? = nil) {
        recordSink("plugin:\(platform):\(series)", value, energy)
    }

    /// A series named once, for a plugin that records many readings every few seconds: `recordValue(_:series:energy:)`
    /// with it skips naming the series again (`plugin:<platform>:<series>`).
    public func series(_ series: String) -> RecordedSeries {
        RecordedSeries(name: "plugin:\(platform):\(series)")
    }

    /// Records a reading of a series named with `series(_:)`.
    public func recordValue(_ value: Double, series: RecordedSeries, energy: EnergyTag? = nil) {
        recordSink(series.name, value, energy)
    }

    /// Hands the long-term energy history (the Status page's month and year views) hours the bridge did not record: a
    /// cloud's record of the days before it ran. Each hour replaces what this plugin imported for it before; an hour
    /// the bridge recorded itself keeps its own figures. Watt-hours; leave out (nil) what the history does not have.
    public func importEnergy(_ hours: [EnergyHourImport]) {
        energyImportSink(hours)
    }

    /// Says where an energy import stands, for the Status page's history: as it runs (`done` of `total`), when it is done
    /// (what it covers) and when it fails (why). The latest report is shown; a plugin that imports again reports again.
    public func reportEnergyImport(_ progress: EnergyImportProgress) {
        var progress = progress
        progress.source = key
        progress.name = name
        progress.updated = Date()
        energyProgressSink(progress)
    }
    /// The plugin's `deviceID(ofAccessory:)`.
    var ownDeviceID: (@Sendable (String) -> String?)? { ownDeviceIDBox.withLockedValue { $0 } }
    let ownDeviceIDBox = NIOLockedValueBox<(@Sendable (String) -> String?)?>(nil)
    /// The block's `_accessories` as the plugin was launched with it: Accessory Settings by Device Id.
    let accessorySettingsBox = NIOLockedValueBox<[String: AccessorySettings]>([:])
    // Mutable state is behind the lock; the class is otherwise immutable.
    private let list = NIOLockedValueBox<Entries>(Entries())
    /// A save of the cache is due: changes in a burst (a plugin adding its devices at launch) write it once.
    private let cacheSaveDue = NIOLockedValueBox(false)
    /// Saves the stores `persistedDictionary` made that are still alive: the runtime runs them when the plugin stops, so
    /// a restart within a store's autosave delay keeps its last change.
    let storeFlushes = NIOLockedValueBox<[(isAlive: @Sendable () -> Bool, flush: @Sendable () -> Void)]>([])
    /// Where the due saves run, one at a time.
    private let cacheQueue = DispatchQueue(label: "homeswift.accessory-cache", qos: .utility)

    /// How long changes wait for the next before the cache is written.
    static let cacheSaveDelay: DispatchTimeInterval = .milliseconds(250)

    private struct Entries {
        var accessories: [Accessory] = []
        /// The ids published as external accessories.
        var external: Set<String> = []
        /// The ids restored from the cache that the plugin has not added again (yet).
        var restoredOnly: Set<String> = []

        mutating func put(_ accessory: Accessory) {
            restoredOnly.remove(accessory.id)
            if let index = accessories.firstIndex(where: { $0.id == accessory.id }) {
                accessories[index] = accessory
            } else {
                accessories.append(accessory)
            }
        }
    }

    init(
        platform: String, name: String, key: String, logger: Logger, bridge: PluginHost.Bridge, cache: AccessoryCache, storageURL: URL,
        vaultStorage: URL, assistant: NIOLockedValueBox<AssistantService?>, externals: ExternalAccessories, assistantBackground: String? = nil,
        recordSink: @escaping @Sendable (String, Double, EnergyTag?) -> Void = { _, _, _ in },
        energyImportSink: @escaping @Sendable ([EnergyHourImport]) -> Void = { _ in },
        energyProgressSink: @escaping @Sendable (EnergyImportProgress) -> Void = { _ in }
    ) {
        self.energyProgressSink = energyProgressSink
        self.recordSink = recordSink
        self.energyImportSink = energyImportSink
        self.assistantBackground = assistantBackground
        self.platform = platform
        self.name = name
        self.key = key
        self.logger = logger
        self.bridge = bridge
        self.cache = cache
        naming = AccessoryNaming(platform: platform)
        self.storageURL = storageURL
        self.vaultStorage = vaultStorage
        assistantBox = assistant
        self.externals = externals
    }

    /// Every accessory on the host's servers (the bridges and the external accessories), set by `PluginHost`.
    var publishedAccessories: @Sendable () -> [Accessory] {
        get { publishedBox.withLockedValue { $0 } }
        set { publishedBox.withLockedValue { $0 = newValue } }
    }
    private let publishedBox = NIOLockedValueBox<@Sendable () -> [Accessory]>({ [] })

    /// Tells Homeswift a room of the plugin's hub was renamed there (in the Home app, through Wingman): with the
    /// layout's `syncRoomNames` on, Homeswift renames its room of the old name too, and the other hubs' (docs/ui.md,
    /// "Rooms on the hubs"). Say it only for a rename the hub made, not one Homeswift asked for with `renameRoom`.
    public func hubRoomRenamed(from: String, to: String) {
        hubRoomRenamedBox.withLockedValue { $0 }?(from, to)
    }

    /// Set by `PluginHost`.
    var onHubRoomRenamed: (@Sendable (_ from: String, _ to: String) -> Void)? {
        get { hubRoomRenamedBox.withLockedValue { $0 } }
        set { hubRoomRenamedBox.withLockedValue { $0 = newValue } }
    }
    private let hubRoomRenamedBox = NIOLockedValueBox<(@Sendable (_ from: String, _ to: String) -> Void)?>(nil)

    /// The serial numbers of every accessory Homeswift itself publishes to HomeKit, on any bridge or on its own, mirrored
    /// ones left out: a plugin that reads another controller's view of the home (Wingman reads the Home app's, which has
    /// Homeswift's accessories too) knows which are Homeswift's own.
    public var publishedSerialNumbers: Set<String> {
        Set(publishedAccessories().filter { $0.mirroredFrom == nil }.compactMap { $0.information[.serialNumber]?.value.stringValue })
    }

    /// The accessories this instance has on the bridge or published on their own, including those
    /// restored from the cache at launch that the plugin has not replaced yet.
    public var accessories: [Accessory] { list.withLockedValue { $0.accessories } }

    public func accessory(id: String) -> Accessory? {
        list.withLockedValue { $0.accessories.first { $0.id == id } }
    }

    /// Whether the accessory with this id is published on its own server rather than on the bridge.
    public func isExternal(id: String) -> Bool { list.withLockedValue { $0.external.contains(id) } }

    /// Whether the accessory with this id came from the cache and the plugin has not added it since: a device
    /// it has not reached yet, or one it no longer has.
    public func isRestoredOnly(id: String) -> Bool { list.withLockedValue { $0.restoredOnly.contains(id) } }

    /// Adds an accessory to the bridge, or replaces the one with the same `id`. HomeKit sees the change
    /// through the configuration number; the aid and iids stay, so rooms and automations survive.
    public func add(_ accessory: Accessory) throws {
        // An Excluded device is never an accessory, whether or not the plugin checked.
        if isExcluded(accessoryID: accessory.id) {
            logger.debug("Not adding \(accessory.name): its device is Excluded")
            return
        }
        try bridge.claim(accessory.id, for: key, name: name)
        // Every light with what Adaptive Lighting needs gets a controller (CONTRIBUTING.md); a mirrored one keeps its
        // controller's. Said at debug level, which a plugin's check on a throwaway bridge shows.
        if logger.logLevel <= .debug, accessory.mirroredFrom == nil,
           accessory.services.contains(where: { Self.canHaveAdaptiveLighting($0) && $0.adaptiveLighting == nil }) {
            logger.debug("\(accessory.name) has Brightness and Color Temperature but no Adaptive Lighting: give it an AdaptiveLightingController")
        }
        if isExternal(id: accessory.id) {
            // Moving from its own server to the bridge: the old server leaves the list now (a quick
            // `publishExternal` back makes a new one) and stops in the background.
            externals.unpublishInBackground(id: accessory.id, key: key)
            _ = list.withLockedValue { $0.external.remove(accessory.id) }
        }
        naming.apply(to: accessory)
        try bridge.server.add(accessory)
        list.withLockedValue { $0.put(accessory) }
        scheduleCacheSave()
    }

    /// A Lightbulb with Brightness and a writable Color Temperature: what Adaptive Lighting needs.
    public static func canHaveAdaptiveLighting(_ service: Service) -> Bool {
        service.type.uuid == ServiceType.lightbulb.uuid && service[.brightness] != nil
            && service[.colorTemperature]?.type.permissions.contains(.pairedWrite) == true
    }

    /// Publishes an accessory on a HAP server of its own instead of the bridge, as Homebridge publishes
    /// external accessories: HomeKit wants televisions (one per bridge at most) and cameras this way. The
    /// server has its own identity and pairing, listed with the bridges (`PluginHost.bridges`), and the
    /// main bridge's setup code; the user adds it in the Home app like a second bridge. Publishing an id
    /// again replaces the accessory under the same identity, so a television whose inputs changed keeps
    /// its pairing. The id must still be unique on the bridge.
    public func publishExternal(_ accessory: Accessory) async throws {
        if isExcluded(accessoryID: accessory.id) {
            logger.debug("Not publishing \(accessory.name): its device is Excluded")
            return
        }
        try bridge.claim(accessory.id, for: key, name: name)
        if self.accessory(id: accessory.id) != nil, !isExternal(id: accessory.id) {
            try bridge.server.remove(accessory)
        }
        naming.apply(to: accessory)
        let (published, isNew) = try externals.publish(accessory, key: key, owner: name)
        list.withLockedValue { entries in
            entries.put(accessory)
            entries.external.insert(accessory.id)
        }
        scheduleCacheSave()
        if isNew, externals.isRunning {
            await externals.stopped(id: accessory.id, key: key)
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
        naming.forget(id)
        list.withLockedValue { entries in
            entries.accessories.removeAll { $0.id == id }
            entries.external.remove(id)
            entries.restoredOnly.remove(id)
        }
        scheduleCacheSave()
    }

    /// Removes the accessories of this instance whose id is not in `ids` (devices gone from the account or the
    /// configuration), logging each one; a failure is logged and the others still go. Returns the ids removed.
    @discardableResult
    public func removeAccessories(keeping ids: Set<String>, message: String = "Removing stale accessory") async -> [String] {
        var removed: [String] = []
        for accessory in accessories where !ids.contains(accessory.id) {
            logger.info("\(message): \(accessory.name)")
            do {
                try await remove(id: accessory.id)
                removed.append(accessory.id)
            } catch {
                logger.warning("Could not remove \(accessory.name): \(error)")
            }
        }
        return removed
    }

    /// Puts the cached accessories back on the bridge, or on their own servers, before the plugin starts.
    /// Returns the servers it created for external accessories, which the host starts when it already runs.
    @discardableResult
    func restoreCache() -> [HAPServer] {
        var created: [HAPServer] = []
        let cached = cache.load(logger: logger)
        if let cached {
            // HAP-NodeJS's purgeUnidentifiedAccessoryData: the saved controller states of accessories the
            // instance no longer has (removed in an earlier run). A missing or unreadable cache purges nothing.
            do {
                try controllerStorage.purge(keeping: Set(cached.map(\.accessory.id)))
            } catch {
                logger.warning("Could not save a controller state", metadata: ["path": "\(controllerStorage.url.path)", "error": "\(error)"])
            }
        }
        for (accessory, external) in cached ?? [] {
            if isExcluded(accessoryID: accessory.id) { continue }
            do {
                try bridge.claim(accessory.id, for: key, name: name)
                naming.apply(to: accessory)
                if external {
                    let (published, isNew) = try externals.publish(accessory, key: key, owner: name)
                    if isNew { created.append(published.server) }
                } else {
                    try bridge.server.add(accessory)
                }
                list.withLockedValue { entries in
                    entries.accessories.append(accessory)
                    entries.restoredOnly.insert(accessory.id)
                    if external { entries.external.insert(accessory.id) }
                }
                logger.info("Restored accessory from cache", metadata: ["accessory": "\(accessory.name)", "external": "\(external)"])
            } catch {
                logger.warning("Could not restore cached accessory", metadata: ["accessory": "\(accessory.name)", "error": "\(error)"])
            }
        }
        return created
    }

    /// Takes every accessory of this instance off the bridge and stops its external servers, when its block
    /// leaves the configuration. The cache stays, as it would across a restart without the block.
    func detach() async {
        let (accessories, external) = list.withLockedValue { entries in
            defer { entries = Entries() }
            return (entries.accessories, entries.external)
        }
        for accessory in accessories {
            if external.contains(accessory.id) {
                await externals.unpublish(id: accessory.id, key: key)
            } else {
                do { try bridge.server.remove(accessory) } catch { logger.warning("Could not remove \(accessory.name): \(error)") }
            }
            bridge.release(accessory.id)
        }
    }

    /// Saves the cache shortly, with whatever else changes meanwhile: written whole each time, it made adding
    /// N accessories cost N² (a minute for 300). The aids and iids HomeKit depends on are the server's own state,
    /// saved as they are assigned; this cache only restores the accessories before the plugin starts.
    func scheduleCacheSave() {
        let first = cacheSaveDue.withLockedValue { due in
            defer { due = true }
            return !due
        }
        guard first else { return }
        cacheQueue.asyncAfter(deadline: .now() + Self.cacheSaveDelay) { [self] in
            // A save since then (the plugin stopped) took this one's place.
            guard cacheSaveDue.withLockedValue({ $0 }) else { return }
            writeCache()
        }
    }

    /// Puts the names of `_accessories` on the accessories it has now, or the plugin's back. One that gets a Configured
    /// Name goes on its server again, its aid and iids kept, so controllers see the new characteristic.
    func applyNames(_ names: [String: String]) {
        guard naming.setNames(names) else { return }
        for accessory in accessories where naming.apply(to: accessory) {
            do {
                if isExternal(id: accessory.id) {
                    try externals.bridge(id: accessory.id, key: key)?.server.replace(primary: accessory)
                } else {
                    try bridge.server.add(accessory)
                }
            } catch {
                logger.warning("Could not give \(accessory.name) its name in HomeKit: \(error)")
            }
        }
        scheduleCacheSave()
    }

    /// Saves the cache now, after a save under way; the runtime does when the plugin stops.
    func saveCache() {
        cacheQueue.sync { writeCache() }
    }

    /// Writes the changes the plugin's persisted dictionaries still hold.
    func flushStores() {
        for store in storeFlushes.withLockedValue({ $0 }) { store.flush() }
    }

    /// Writes a save still waiting for the end of its burst, so the file says what the plugin has now.
    func flushCache() {
        cacheQueue.sync { if cacheSaveDue.withLockedValue({ $0 }) { writeCache() } }
    }

    /// On `cacheQueue`.
    private func writeCache() {
        cacheSaveDue.withLockedValue { $0 = false }
        do {
            let (accessories, external) = list.withLockedValue { ($0.accessories, $0.external) }
            try cache.save(accessories, external: external)
        } catch {
            logger.warning("Could not save the accessory cache", metadata: ["path": "\(cache.url.path)", "error": "\(error)"])
        }
    }
}

/// A series of readings with its full name made once (`PluginContext.series(_:)`).
public struct RecordedSeries: Sendable, Hashable {
    let name: String
}
