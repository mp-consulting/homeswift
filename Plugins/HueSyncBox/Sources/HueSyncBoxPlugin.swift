import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The Philips Hue Play HDMI Sync Box in HomeKit: a Lightbulb (or a Switch) that starts and stops syncing, a power
/// switch, and up to four televisions whose inputs are its HDMI inputs, its modes, its intensities and the Hue Bridge's
/// entertainment areas. The box is reached over HTTPS on the LAN, its certificate checked against Philips's root, with a
/// token its button gives (Setup).
///
/// The configuration is homebridge-philips-hue-sync-box's (`PhilipsHueSyncBoxPlatform`, one block per box), so a
/// Homebridge block works unchanged. Written from docs/clean-room/HueSyncBox.md; see README.md in this directory.
public actor HueSyncBoxPlugin: HomeswiftPlugin {
    /// The block, read from the keys the Homebridge plugin has (section 2).
    public struct Configuration: Decodable, Sendable {
        /// The whole block, for the televisions' options read by name.
        let block: JSONValue

        public init(from decoder: any Decoder) throws {
            block = try JSONValue(from: decoder)
        }

        init(_ block: JSONValue) { self.block = block }

        func string(_ key: String) -> String? {
            guard let text = block[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return text
        }

        func bool(_ key: String) -> Bool? { block[key]?.boolValue }

        public var name: String? { string("name") }
        public var syncBoxIpAddress: String? { string("syncBoxIpAddress") }
        /// A secret-named key: the runtime seals it and hands the plugin its value. Setup keeps its token in the vault instead.
        var syncBoxApiAccessToken: String? { string("syncBoxApiAccessToken") }
        /// What Setup writes, so the box's certificate can be checked for its name from the first request on.
        public var syncBoxUniqueId: String? { string("syncBoxUniqueId") }
        public var uuidSeed: String { block["uuidSeed"]?.stringValue ?? "" }
        public var baseAccessory: String { string("baseAccessory")?.lowercased() ?? "lightbulb" }
        public var updateIntervalInSeconds: Int? { block["updateIntervalInSeconds"]?.intValue }

        var mapping: SyncBoxMapping {
            SyncBoxMapping(onMode: string("defaultOnMode"), offMode: string("defaultOffMode"), treatPassthroughAsOffForTV: bool("treatPassthroughAsOffForTv") ?? false)
        }

        /// The accessories the options turn on, in section 1's order.
        var kinds: [SyncBoxKind] {
            var kinds: [SyncBoxKind] = []
            switch baseAccessory {
            case "switch": kinds.append(.switch)
            case "none": break
            default: kinds.append(.lightbulb)
            }
            if bool("powerSwitchAccessory") == true { kinds.append(.power) }
            for kind in SyncBoxKind.televisions where bool(kind.optionPrefix ?? "") == true { kinds.append(kind) }
            return kinds
        }
    }

    /// What Setup keeps in the vault (`plugin.<instance>.account`): the token and the registration it belongs to.
    struct Registration: Codable, Sendable, Equatable {
        var accessToken: String
        var registrationId: String?
    }

    /// What the plugin uses to reach the box; tests swap them for fakes and shorter timings.
    struct Dependencies: Sendable {
        var transport: @Sendable (HTTPClient.TLS) -> any HTTPSending = { HTTPClient(tls: $0, maximumBodySize: SyncBoxClient.maximumBodySize) }
        var browse: @Sendable (Logger) -> AsyncStream<SyncBoxDiscovery.Box> = SyncBoxDiscovery.browse
        var discoveryWindow: Duration = .seconds(3)
        /// Multiplies every delay: the poll, the retries, the back-off, the brightness guard.
        var timeScale: Double = 1
        /// How long a slider rests before its brightness is sent: 300 ms times `timeScale` when nil.
        var sliderRest: Duration?
    }

    public static let platform = "PhilipsHueSyncBoxPlatform"
    public static let name = "Philips Hue Sync Box"
    public static let icon: String? = "logo-hue"
    public static let summary: String? = "An HDMI Sync Box's syncing, modes, inputs and entertainment areas"

    static let defaultInterval = 5
    static let minimumInterval = 1
    /// A larger `updateIntervalInSeconds` is read as this: an hour, a sleep that cannot overflow.
    static let maximumInterval = 3_600
    /// Failed polls in a row before the accessories show No Response.
    static let failuresBeforeUnreachable = 3

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let mapping: SyncBoxMapping
    private let tasks = TaskBag()
    private let brightnessGuard = LatestCallGuard(delay: .zero)
    /// How long a slider rests before its brightness is sent.
    private let sliderRest: Duration
    var logger: Logger { context.logger }

    private var client: SyncBoxClient?
    /// The last state read, nil before the first.
    private(set) var state: SyncBoxState?
    /// The box's `uniqueId` once a state told it, when the block did not have it.
    private(set) var learnedUniqueID: String?
    private var accessories: [SyncBoxKind: SyncBoxAccessory] = [:]
    private var failures = 0
    private var polling = false
    private var pollAgain = false
    private var writes: AsyncStream<SyncBoxWrite>.Continuation?
    private var reportedModes: Set<String> = []

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        mapping = configuration.mapping
        sliderRest = dependencies.sliderRest ?? .milliseconds(300) * dependencies.timeScale
    }

    var interval: Duration {
        .seconds(min(max(configuration.updateIntervalInSeconds ?? Self.defaultInterval, Self.minimumInterval), Self.maximumInterval)) * dependencies.timeScale
    }

    /// The back-off between failed reads: from the poll's interval up to five minutes.
    var backoff: Backoff {
        Backoff(initial: interval, maximum: max(interval, .seconds(300) * dependencies.timeScale), jitter: .none)
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    func deviceID(_ kind: SyncBoxKind) -> String { kind.deviceID(seed: configuration.uuidSeed) }

    /// The token: the block's (a Homebridge block), else the one Setup kept.
    var token: String? {
        configuration.syncBoxApiAccessToken ?? context.credentials(as: Registration.self)?.accessToken.nonEmpty
    }

    public func accountAuthorized() async -> Bool? { token != nil }

    // MARK: Running

    public func start() async throws {
        // Not set up: nothing runs, no task, no socket.
        guard let address = configuration.syncBoxIpAddress, let token else {
            if configuration.syncBoxIpAddress != nil || configuration.syncBoxApiAccessToken != nil {
                logger.warning("Missing required configuration parameters: add the Sync Box from Add accessories, which presses its button for a token")
            }
            return
        }
        if configuration.bool("apiServerEnabled") == true {
            logger.warning("apiServerEnabled is not supported: the web UI and the MCP server control the Sync Box instead")
        }
        guard let client = makeClient(address: address, token: token, uniqueID: configuration.syncBoxUniqueId) else {
            logger.error("syncBoxIpAddress is not an address: \(address)")
            return
        }
        self.client = client
        let (stream, continuation) = AsyncStream.makeStream(of: SyncBoxWrite.self, bufferingPolicy: .bufferingNewest(16))
        writes = continuation
        // Writes go one after the other, in the order HomeKit made them.
        tasks.add { [weak self] in
            for await write in stream { await self?.perform(write) }
        }
        tasks.add { [weak self] in await self?.run() }
    }

    public func stop() async {
        writes?.finish()
        writes = nil
        tasks.cancelAll()
    }

    private func makeClient(address: String, token: String, uniqueID: String?) -> SyncBoxClient? {
        SyncBoxClient(
            address: address, token: token, transport: dependencies.transport(SyncBoxCertificate.tls(uniqueID: uniqueID)),
            timing: SyncBoxClient.Timing.standard.scaled(dependencies.timeScale), logger: logger)
    }

    /// The first state, tried again with back-off until the box answers (the cached accessories stay meanwhile), then the
    /// accessories and the poll.
    private func run() async {
        var attempt = 0
        while !Task.isCancelled, accessories.isEmpty {
            guard let client else { return }
            do {
                let state = try await client.state()
                await setUp(state)
                break
            } catch is CancellationError {
                return
            } catch {
                if attempt == 0 {
                    logger.error("Could not get state from sync box on initialization: \(Self.describe(error)). Trying again until it answers.")
                }
                noteRefusal(error)
                attempt += 1
                // The accessories the cache kept show No Response until the box answers.
                if attempt == Self.failuresBeforeUnreachable { setUnreachable(true) }
                do { try await Task.sleep(for: backoff.delay(attempt: attempt - 1)) } catch { return }
            }
        }
        // Every accessory Excluded (or none turned on): nothing to show, nothing to ask the box.
        guard !accessories.isEmpty else { return }
        while !Task.isCancelled {
            let delay = failures == 0 ? interval : backoff.delay(attempt: failures - 1)
            do { try await Task.sleep(for: delay) } catch { return }
            await poll()
        }
    }

    /// One read of the state, shown on the accessories; a read asked for while one runs makes one more after it, not two.
    func poll() async {
        guard client != nil else { return }
        if polling {
            pollAgain = true
            return
        }
        polling = true
        defer { polling = false }
        repeat {
            pollAgain = false
            await pollOnce()
        } while pollAgain && !Task.isCancelled
    }

    private func pollOnce() async {
        guard let client else { return }
        do {
            let state = try await client.state()
            if failures > 0 {
                logger.info("The Sync Box answers again")
                setUnreachable(false)
            }
            failures = 0
            context.accountAccepted()
            apply(state)
        } catch is CancellationError {
            return
        } catch {
            failures += 1
            noteRefusal(error)
            // Once per outage, not once per poll.
            if failures == 1 { logger.warning("Failed to get state from Sync Box: \(Self.describe(error))") }
            if failures == Self.failuresBeforeUnreachable { setUnreachable(true) }
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? SyncBoxError, error.isUnauthorized { return "the Sync Box refused the access token: set it up again from Add accessories" }
        return "\(error)"
    }

    /// The accessories built; before the first state, the bridged ones the cache kept (the televisions are published
    /// once built).
    private func setUnreachable(_ unreachable: Bool) {
        let shown = accessories.isEmpty
            ? configuration.kinds.compactMap { context.accessory(id: Self.accessoryID(deviceID: deviceID($0))) } : accessories.values.map(\.accessory)
        for accessory in shown { accessory.isUnreachable = unreachable }
    }

    /// A token the box refused: the account Needs Authorization, and Add accessories offers to pair again.
    private func noteRefusal(_ error: any Error) {
        if let error = error as? SyncBoxError, error.isUnauthorized { context.accountRefused("the Sync Box refused the access token") }
    }

    /// Builds the accessories of the options from the first state, publishes them, and drops the cached ones no option
    /// makes any more (section 6.1).
    private func setUp(_ state: SyncBoxState) async {
        if configuration.syncBoxUniqueId == nil, !state.uniqueID.isEmpty {
            // From now on the box's certificate must name it.
            learnedUniqueID = state.uniqueID
            if let address = configuration.syncBoxIpAddress, let token, let client = makeClient(address: address, token: token, uniqueID: state.uniqueID) {
                self.client = client
            }
        }
        var keep: Set<String> = []
        for kind in configuration.kinds where !context.isExcluded(deviceID(kind)) {
            let id = Self.accessoryID(deviceID: deviceID(kind))
            let options = televisionOptions(kind)
            let built = SyncBoxAccessory(kind: kind, id: id, state: state, options: options, plugin: self)
            do {
                if kind.isTelevision {
                    try await context.publishExternal(built.accessory)
                } else {
                    try context.add(built.accessory)
                }
                accessories[kind] = built
                keep.insert(id)
            } catch {
                logger.error("Could not add \(built.accessory.name): \(error)")
            }
        }
        await context.removeAccessories(keeping: keep, message: "Removing existing accessory from cache")
        setUnreachable(false)
        context.accountAccepted()
        self.state = nil
        apply(state)
    }

    /// A television's icon and Lightbulb: its Accessory Settings, else the block's Homebridge keys.
    func televisionOptions(_ kind: SyncBoxKind) -> SyncBoxAccessory.Options {
        guard let prefix = kind.optionPrefix else { return .init() }
        let settings = context.accessorySettings(for: deviceID(kind)).plugin
        let type = settings["accessoryType"]?.stringValue ?? configuration.string("\(prefix)Type") ?? "tv"
        let lightbulb = settings["lightbulb"]?.boolValue ?? configuration.bool("\(prefix)Lightbulb") ?? false
        return .init(type: type, lightbulb: lightbulb, name: configuration.string("\(prefix)ConfiguredName"))
    }

    /// Shows a state on every accessory; the same state again changes nothing.
    func apply(_ state: SyncBoxState) {
        guard state != self.state else { return }
        self.state = state
        for (kind, accessory) in accessories {
            accessory.show(state, mapping: mapping)
            if kind == .modeTV, kind.activeIdentifier(in: state) == nil, reportedModes.insert(state.mode).inserted {
                logger.error("Unknown mode for Mode TV: \(state.mode)")
            }
        }
    }

    // MARK: Writes

    /// Queues a request: HomeKit's write has its answer at once, the box gets it in turn (section 6.4).
    func send(_ write: SyncBoxWrite?) {
        guard let write else { return }
        writes?.yield(write)
    }

    /// A slider's write, sent once the slider rests.
    func sendBrightness(_ value: Int, key: String) {
        // Claimed now, in the order the writes came: the tasks need not start in that order, and the last to start
        // is not always the last write.
        let isLatest = brightnessGuard.claim(key)
        let rest = sliderRest
        tasks.add { [weak self] in
            do { try await Task.sleep(for: rest) } catch { return }
            guard isLatest() else { return }
            await self?.send(.brightness(SyncBoxMapping.boxBrightness(value)))
        }
    }

    func setOn(_ on: Bool) { send(mapping.write(on: on, state: state)) }

    func setPower(_ on: Bool) { send(.mode(on ? "passthrough" : "powersave")) }

    func select(_ identifier: Int, on kind: SyncBoxKind) {
        guard let write = kind.write(identifier: identifier, state: state) else {
            if kind == .hdmiTV { logger.warning("Ignoring out-of-range HDMI input identifier: \(identifier)") }
            return
        }
        send(write)
    }

    func remoteKey(_ key: Int) {
        guard let state else { return }
        send(mapping.remoteKey(key, state: state))
    }

    /// Sends one request, then reads the state at once so the switches and inputs that follow from it show (section 6.4).
    private func perform(_ write: SyncBoxWrite) async {
        guard let client else { return }
        do {
            switch write {
            case .execution(let body):
                try await client.setExecution(body)
            case .area(let id, let name):
                logger.debug("Switch entertainment area to \(name)")
                try await client.setGroup(id)
            }
        } catch is CancellationError {
            return
        } catch {
            switch write {
            case .execution: logger.error("Error updating execution: \(Self.describe(error))")
            case .area(_, let name): logger.error("Failed to switch entertainment area to \(name): \(Self.describe(error))")
            }
            return
        }
        await poll()
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
