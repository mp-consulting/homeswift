import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Z-Wave devices from zwave-js-server, the WebSocket server Z-Wave JS UI and Home Assistant's Z-Wave JS add-on run
/// (port 3000 by default). The plugin brings in the nodes already on the Z-Wave network; including and excluding nodes
/// stays in Z-Wave JS UI. Written from zwave-js-server's protocol documentation, not ported from another plugin.
///
/// A server is a device of its own (Device Kind `server`, Device Id its home id) whose Accessory Settings give its
/// `host` and `port`: found over mDNS (`_zwave-js-server._tcp`) and set up, or added by its address. Each node is an
/// accessory `ZWaveJS:<homeId>-<nodeId>`, its services made from its command classes (NodeAccessory.swift). Values
/// come from `start_listening`'s state and its `value updated` events; writes are `node.set_value`; a dead node, and every
/// node while its server is away, answers No Response.
public actor ZWaveJSPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
    }

    /// A server's Accessory Settings: where it answers.
    struct ServerSettings: Decodable, Sendable {
        var host: String?
        var port: Int?
    }

    /// A node's Plugin Accessory Settings.
    struct NodeSettings: Decodable, Sendable {
        /// How a Binary Switch shows: `switch`, `outlet` or `lightbulb`.
        var showAs: String?
    }

    /// What the plugin uses to reach the servers; tests swap them for fakes and shorten the delays.
    struct Dependencies: Sendable {
        var connect: @Sendable (URL) async throws -> any WebSocketConnection = { url in
            try await WebSocket.connect(to: url, options: WebSocket.Options(timeout: .seconds(10), heartbeat: .seconds(30)))
        }
        var browse: @Sendable (Duration, Logger) async -> [ServerAnnouncement] = ZWaveDiscovery.browse
        /// How long an instance made for Setup browses mDNS.
        var setupDiscoveryWindow: Duration = .seconds(3)
        /// The longest a command waits for its result.
        var requestTimeout: Duration = .seconds(30)
        /// Between reconnections.
        var backoff = Backoff(initial: .seconds(2), maximum: .seconds(60), jitter: .proportional(0.2))
        /// How long a slider's writes wait for the next one before going out.
        var coalesceDelay: Duration = .milliseconds(150)
    }

    public static let platform = "ZWaveJS"
    public static let name = "Z-Wave JS"
    public static let icon: String? = "bridge"
    public static let summary: String? = "Z-Wave lights, switches, sensors, locks and thermostats from Z-Wave JS"

    /// zwave-js-server's default port.
    static let defaultPort = 3000
    /// Device Kinds.
    static let serverKind = "server"

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    let coalesce: LatestCallGuard
    var logger: Logger { context.logger }

    /// One server set up, by home id.
    struct Server {
        var host: String
        var port: Int
        var client: ZWaveClient?
        /// Its nodes as last reported, by node id; the controller's own node left out.
        var nodes: [Int: ZNode] = [:]
        var failures = 0
    }

    var servers: [String: Server] = [:]
    /// Each node's accessory, by Device Id.
    var accessories: [String: NodeAccessory] = [:]
    /// What each accessory was built from (its values' ids, its shape, its name), to rebuild only when it changed.
    var signatures: [String: String] = [:]

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        coalesce = LatestCallGuard(delay: dependencies.coalesceDelay)
        for server in Self.configuredServers(context) {
            servers[server.homeID] = Server(host: server.host, port: server.port)
        }
    }

    // MARK: Ids and settings

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }
    static func deviceID(homeID: String, nodeID: Int) -> String { "\(homeID)-\(nodeID)" }

    /// The servers whose Accessory Settings give a `host`, Excluded ones left out, by home id.
    static func configuredServers(_ context: PluginContext) -> [(homeID: String, host: String, port: Int)] {
        context.allAccessorySettings.sorted { $0.key < $1.key }.compactMap { homeID, settings in
            guard !settings.excluded, !homeID.contains("-"), let server = settings.decode(ServerSettings.self),
                  let host = server.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
            return (homeID, host, port(server.port))
        }
    }

    static func port(_ port: Int?) -> Int { port.flatMap { (1...65535).contains($0) ? $0 : nil } ?? defaultPort }

    /// `ws://host:port`, an IPv6 host in brackets.
    static func url(host: String, port: Int) -> URL? {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "ws://\(bracketed):\(port)")
    }

    static func address(host: String, port: Int) -> String { hostHeader(host: host, port: port, defaultPort: 0) }

    func showAs(_ deviceID: String) -> SwitchShape? {
        context.accessorySettings(for: deviceID).decode(NodeSettings.self)?.showAs.flatMap(SwitchShape.init(rawValue:))
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard !servers.isEmpty else {
            logger.info("No zwave-js-server set up: add one in the Add accessories page, found on the network or by its address")
            return
        }
        for homeID in servers.keys.sorted() {
            tasks.add { [weak self] in await self?.run(homeID) }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        for server in servers.values { await server.client?.close() }
    }

    /// Keeps one server connected: connects, reads the state, follows the events, and reconnects after a while when the
    /// connection drops. An outage is logged once.
    func run(_ homeID: String) async {
        while !Task.isCancelled {
            guard let server = servers[homeID], let url = Self.url(host: server.host, port: server.port) else { return }
            let address = Self.address(host: server.host, port: server.port)
            do {
                let socket = try await dependencies.connect(url)
                let client = ZWaveClient(socket: socket, timeout: dependencies.requestTimeout)
                let reader = Task { await client.run() }
                do {
                    let (version, state) = try await client.open(expectedHomeID: homeID)
                    if (servers[homeID]?.failures ?? 0) > 0 { logger.info("Reconnected to zwave-js-server at \(address)") }
                    servers[homeID]?.failures = 0
                    servers[homeID]?.client = client
                    logger.info("Connected to zwave-js-server \(version.serverVersion ?? "?") (driver \(version.driverVersion ?? "?")) at \(address), home id \(homeID)")
                    await apply(state: state, homeID: homeID)
                    for await event in client.events {
                        await handle(event: event, homeID: homeID)
                    }
                    if !Task.isCancelled { logger.warning("Lost the connection to zwave-js-server at \(address)") }
                } catch {
                    await client.close()
                    reader.cancel()
                    throw error
                }
                await client.close()
                reader.cancel()
            } catch is CancellationError {
                return
            } catch {
                if (servers[homeID]?.failures ?? 0) == 0 { logger.warning("Cannot reach zwave-js-server at \(address): \(error)") }
            }
            guard !Task.isCancelled else { return }
            servers[homeID]?.client = nil
            setServerUnavailable(homeID)
            let failures = servers[homeID]?.failures ?? 0
            servers[homeID]?.failures = failures + 1
            try? await Task.sleep(for: dependencies.backoff.delay(attempt: failures))
        }
    }

    /// Every node of a server answers No Response while it is away.
    func setServerUnavailable(_ homeID: String) {
        for (deviceID, accessory) in accessories where deviceID.hasPrefix("\(homeID)-") { accessory.setUnavailable(true) }
        // Those the cache brought back before the server ever answered.
        let prefix = Self.accessoryID(deviceID: "\(homeID)-")
        for accessory in context.accessories where accessory.id.hasPrefix(prefix) && !accessory.isUnavailable {
            accessory.isUnavailable = true
        }
    }

    // MARK: State and events

    /// The state dump: each node becomes an accessory (or keeps its own), and the accessories of nodes no longer on the
    /// network leave the bridge.
    func apply(state: JSONValue, homeID: String) async {
        var nodes: [Int: ZNode] = [:]
        for item in state["nodes"]?.arrayValue ?? [] {
            guard let node = ZNode(item), !node.isControllerNode else { continue }
            nodes[node.nodeID] = node
        }
        servers[homeID]?.nodes = nodes
        var kept: Set<String> = []
        for node in nodes.values.sorted(by: { $0.nodeID < $1.nodeID }) {
            let deviceID = Self.deviceID(homeID: homeID, nodeID: node.nodeID)
            if publish(node, homeID: homeID) { kept.insert(deviceID) }
        }
        // This server's accessories the bridge still has, from the cache or a node since removed.
        let prefix = Self.accessoryID(deviceID: "\(homeID)-")
        for accessory in context.accessories where accessory.id.hasPrefix(prefix) {
            let deviceID = String(accessory.id.dropFirst(Self.platform.count + 1))
            guard !kept.contains(deviceID) else { continue }
            await forget(deviceID)
        }
        logger.info("\(kept.count) Z-Wave nodes on the network \(homeID)")
    }

    /// Adds (or keeps) a node's accessory, its values shown; false when it has none (Excluded, nothing to show).
    @discardableResult
    func publish(_ node: ZNode, homeID: String) -> Bool {
        let deviceID = Self.deviceID(homeID: homeID, nodeID: node.nodeID)
        guard !context.isExcluded(deviceID) else { return false }
        let shape = showAs(deviceID)
        let signature = ([node.displayName, shape?.rawValue ?? "", node.isCover ? "cover" : ""]
            + node.values.keys.map { "\($0.commandClass)/\($0.endpoint)/\($0.propertyText)/\($0.propertyKeyText ?? "")" }.sorted()).joined(separator: "|")
        if let existing = accessories[deviceID], signatures[deviceID] == signature {
            for value in node.values.values { if let current = value.value { existing.update(value.id, current) } }
            existing.setUnavailable(node.isDead)
            return true
        }
        let nodeID = node.nodeID
        let write: ValueWriter = { [weak self] id, value in
            guard let self else { throw ZWaveError.closed }
            try await self.setValue(homeID: homeID, nodeID: nodeID, id, value)
        }
        let accessoryID = Self.accessoryID(deviceID: deviceID)
        let context = self.context, name = node.displayName
        var builder = NodeBuilder(
            node: node, deviceID: deviceID, name: name, showAs: shape, write: write,
            meter: { service in context.meter(of: service, accessoryID: accessoryID, device: name) }, coalesce: coalesce)
        guard let built = builder.build() else {
            logger.debug("Node \(nodeID) (\(name)) has nothing HomeKit shows")
            return false
        }
        do {
            try context.add(built.accessory)
        } catch {
            logger.error("Could not add \(name): \(error)")
            return false
        }
        accessories[deviceID] = built
        signatures[deviceID] = signature
        return true
    }

    /// A node no longer on the network: its accessory leaves the bridge.
    func forget(_ deviceID: String) async {
        accessories[deviceID] = nil
        signatures[deviceID] = nil
        do {
            try await context.remove(id: Self.accessoryID(deviceID: deviceID))
        } catch {
            logger.warning("Could not remove the accessory of \(deviceID): \(error)")
        }
    }

    /// One event from the server.
    func handle(event: JSONValue, homeID: String) async {
        let source = event["source"]?.stringValue, name = event["event"]?.stringValue ?? ""
        if source == "controller" {
            await handleController(name, event, homeID: homeID)
            return
        }
        guard source == "node", let nodeID = event["nodeId"]?.intValue else { return }
        let deviceID = Self.deviceID(homeID: homeID, nodeID: nodeID)
        let args = event["args"] ?? .null
        switch name {
        case "value updated", "value added":
            guard let id = ValueID(args) else { return }
            let value = args["newValue"]?.nonNull
            if var node = servers[homeID]?.nodes[nodeID] {
                if var known = node.values[id] {
                    known.value = value
                    node.values[id] = known
                } else {
                    node.values[id] = ZValue(id: id, value: value, metadata: args["metadata"] ?? .null)
                }
                servers[homeID]?.nodes[nodeID] = node
            }
            if let value { accessories[deviceID]?.update(id, value) }
        case "value notification":
            guard let id = ValueID(args), let value = args["value"]?.nonNull else { return }
            accessories[deviceID]?.notify(id, value)
        case "dead", "alive":
            let dead = name == "dead"
            servers[homeID]?.nodes[nodeID]?.status = dead ? .dead : .alive
            accessories[deviceID]?.setUnavailable(dead)
            logger.info("\(accessories[deviceID]?.accessory.information.characteristic(.name).value.stringValue ?? "Node \(nodeID)") is \(dead ? "dead" : "alive again")")
        case "ready", "interview completed":
            // A node that finished its interview: its values are all known now. Older schemas send no `nodeState`: the
            // node as `node added` and the value events left it.
            let reported = event["nodeState"].flatMap(ZNode.init)
            guard var node = reported ?? servers[homeID]?.nodes[nodeID], !node.isControllerNode else { return }
            node.ready = true
            servers[homeID]?.nodes[nodeID] = node
            publish(node, homeID: homeID)
        default:
            break
        }
    }

    func handleController(_ name: String, _ event: JSONValue, homeID: String) async {
        switch name {
        case "node added":
            guard let state = event["node"], let node = ZNode(state), !node.isControllerNode else { return }
            servers[homeID]?.nodes[node.nodeID] = node
            logger.info("Node \(node.nodeID) joined the Z-Wave network \(homeID)")
            // An included node is interviewed first: its accessory comes with `ready`.
            if node.ready { publish(node, homeID: homeID) }
        case "node removed":
            guard let nodeID = event["node"]?["nodeId"]?.intValue ?? event["nodeId"]?.intValue else { return }
            servers[homeID]?.nodes[nodeID] = nil
            logger.info("Node \(nodeID) left the Z-Wave network \(homeID)")
            await forget(Self.deviceID(homeID: homeID, nodeID: nodeID))
        default:
            break
        }
    }

    /// `node.set_value` on the server's open connection.
    func setValue(homeID: String, nodeID: Int, _ id: ValueID, _ value: JSONValue) async throws {
        guard let client = servers[homeID]?.client else { throw ZWaveError.closed }
        do {
            try await client.setValue(nodeID: nodeID, id, value)
        } catch {
            logger.warning("Could not set \(id.propertyText) of node \(nodeID): \(error)")
            throw error
        }
    }

    // MARK: Settings

    public func deviceKind(of deviceID: String) async -> String? {
        if !deviceID.contains("-") || deviceID.hasPrefix("address:") { return Self.serverKind }
        return accessories[deviceID]?.kind
    }
}
