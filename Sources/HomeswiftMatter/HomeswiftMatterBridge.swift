import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Logging
import Matter
import NIOConcurrencyHelpers

/// The Matter bridge: every accessory the plugins publish (that the `HomeswiftMatter` block bridges) as a Matter
/// bridged device, both ways (or a single HAP server's, `ServerAccessories`). An accessory in the block's `devices` is a
/// Matter device of its own instead: a node with its own port and pairing code, which a controller adds by itself. A
/// value a plugin sets is reported to the Matter controllers; a Matter command writes the characteristic as Apple Home
/// would, so plugins see no difference. Started by the CLI, like the web UI.
public actor HomeswiftMatterBridge: MatterControl {
    public private(set) var configuration: MatterConfiguration
    public nonisolated let node: MatterNode
    private let bridge: MatterBridge
    private let source: any MatterAccessorySource
    private let storage: any MatterStorage
    private let deviceStorage: @Sendable (_ accessoryID: String) -> any MatterStorage
    private let deviceTransport: (@Sendable (_ accessoryID: String) async -> any MatterTransport)?
    private let advertise: Bool
    private let reliability: ReliabilityParameters
    /// The port of each accessory that is a device of its own, kept so controllers find it where it was.
    private var ports: [String: Int] = [:]
    private let logger: Logger
    /// The bridged accessories, by accessory id.
    private var devices: [String: Bridged] = [:]
    private var tasks: [Task<Void, Never>] = []
    /// Cleaning robots a controller paused: their switch only says off, so they are reported paused, not stopped, until
    /// they start or stop again, and Resume is accepted (RVC Operational State allows it only while paused).
    private var pausedRobots: Set<String> = []
    /// The look at the accessories under way: the next one waits for it, so two never add the same device.
    private var syncing: Task<Void, Never>?
    private var observations: [Observation] = []
    private let changed = NIOLockedValueBox<(@Sendable (_ device: String?) -> Void)?>(nil)

    private struct Bridged {
        let device: BridgedDevice
        let accessory: Accessory
        let mappings: [ServiceMapping]
        /// The part of each mapped characteristic, by its identity: a change finds its part without a search.
        let parts: [ObjectIdentifier: Int]
        /// The node of an accessory that is a device of its own; nil on the bridge.
        let own: MatterNode?
        var name: String

        init(device: BridgedDevice, accessory: Accessory, mappings: [ServiceMapping], own: MatterNode? = nil) {
            self.device = device
            self.own = own
            self.accessory = accessory
            self.mappings = mappings
            name = accessory.name
            var parts: [ObjectIdentifier: Int] = [:]
            for (index, mapping) in mappings.enumerated() {
                for characteristic in mapping.service.characteristics { parts[ObjectIdentifier(characteristic)] = index }
            }
            self.parts = parts
        }

        /// The services, the roles Matter has them in, and where the device is: when they change, it is made again.
        var shape: Shape { Shape(mappings, own: own != nil) }
    }

    struct Shape: Equatable {
        struct Part: Equatable {
            let iid: Int
            let type: HAPUUID
            let role: ServiceMapping.Role
        }
        let parts: [Part]
        let own: Bool

        init(_ mappings: [ServiceMapping], own: Bool) {
            parts = mappings.map { Part(iid: $0.service.iid, type: $0.service.type.uuid, role: $0.role) }
            self.own = own
        }
    }

    /// The node's state (its fabrics and keys) lives in `storage`: `MatterFileStorage` under `matter/`, or memory in
    /// tests; an accessory that is a device of its own keeps its node's in `deviceStorage(id)`. `transport` and the
    /// advertiser default to UDP on the configured port and the built-in mDNS responder; tests pass memory ones
    /// (`deviceTransport` for the accessories' own nodes), and MRP timings scaled down (`reliability`).
    public init(configuration: MatterConfiguration, source: any MatterAccessorySource, storage: any MatterStorage,
                deviceStorage: @escaping @Sendable (_ accessoryID: String) -> any MatterStorage,
                transport: (any MatterTransport)? = nil, deviceTransport: (@Sendable (_ accessoryID: String) async -> any MatterTransport)? = nil,
                advertise: Bool = true, reliability: ReliabilityParameters = .init(),
                logger: Logger = Logger(label: "homeswift.matter")) async throws {
        self.configuration = configuration
        self.source = source
        self.storage = storage
        self.deviceStorage = deviceStorage
        self.deviceTransport = deviceTransport
        self.advertise = advertise
        self.reliability = reliability
        self.logger = logger
        node = try await Self.makeNode(
            NodeInformation(vendorName: "Homeswift", productName: "Homeswift Bridge", nodeLabel: "Homeswift", softwareVersionString: PluginHost.version),
            port: configuration.port, deviceType: DeviceTypes.aggregator.id, storage: storage, transport: transport,
            tcp: configuration.tcp, advertise: advertise, reliability: reliability, logger: logger)
        bridge = try await MatterBridge(node: node)
        await watch(node, device: nil)
    }

    /// Calls `observer` (one: the CLI passes changes on to the catalog, whose pages follow them) when a node is added to
    /// an ecosystem or removed from one, or opens or closes its commissioning window: with the accessory's id for a
    /// device of its own, nil for the bridge.
    public nonisolated func onChange(_ observer: @escaping @Sendable (_ device: String?) -> Void) {
        changed.withLockedValue { $0 = observer }
    }

    private nonisolated func watch(_ node: MatterNode, device: String?) async {
        let notify: @Sendable () -> Void = { [changed] in changed.withLockedValue { $0 }?(device) }
        await node.fabrics.onChange { _ in notify() }
        await node.commissioning.onWindowChange { _, _ in notify() }
    }

    /// A node of the bridge's or of an accessory's: its window stays open until it is commissioned, as a HAP bridge
    /// stays pairable.
    private static func makeNode(_ information: NodeInformation, port: Int, deviceType: UInt32, storage: any MatterStorage,
                                 transport: (any MatterTransport)?, tcp: Bool, advertise: Bool,
                                 reliability: ReliabilityParameters, logger: Logger) async throws -> MatterNode {
        var nodeConfiguration = NodeConfiguration(information: information, port: port, deviceType: deviceType)
        nodeConfiguration.initialWindowTimeout = nil
        nodeConfiguration.reliability = reliability
        nodeConfiguration.tcp = tcp
        return try await MatterNode(configuration: nodeConfiguration, storage: storage, transport: transport,
                                    advertiser: advertise ? MDNSAdvertiser(logger: logger) : nil, logger: logger)
    }

    /// Takes a configuration that keeps the nodes' setup (the same port, TCP and bridge): which accessories are bridged
    /// or devices of their own changes in place, and the controllers keep their sessions. False when it needs a restart.
    public func apply(_ next: MatterConfiguration) async -> Bool {
        guard next.port == configuration.port, next.tcp == configuration.tcp, next.bridge == configuration.bridge else { return false }
        configuration = next
        await sync()
        return true
    }

    /// Follows the plugins' changes, bridges the accessories there are now, then starts the node. Following comes
    /// first, so nothing a plugin does meanwhile is missed.
    public func start() async throws {
        let (changes, continuation) = AsyncStream<(Accessory, Characteristic, HAPValue)>.makeStream()
        // One stream keeps the changes in order (a press after the state it follows).
        observations.append(source.observeChanges { accessory, characteristic, value in continuation.yield((accessory, characteristic, value)) })
        tasks.append(Task { [weak self] in
            for await (accessory, characteristic, value) in changes { await self?.changed(accessory, characteristic, value) }
        })
        // Accessories coming and going: a burst (a plugin adding its devices at launch) makes one look, not one each.
        let (structure, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations.append(source.observeStructure { signal.yield() })
        tasks.append(Task { [weak self] in
            for await _ in structure { await self?.sync() }
        })
        if let data = await storage.value(for: Self.portsKey), let saved = try? JSONDecoder().decode([String: Int].self, from: Data(data)) {
            ports = saved
        }
        await sync()
        let own = devices.values.filter { $0.own != nil }.count
        if configuration.bridge {
            try await node.start()
            logger.info("Matter bridge on port \(configuration.port): \(devices.count - own) accessories bridged, \(own) devices of their own")
        } else {
            logger.info("Matter: \(own) devices of their own, no bridge")
        }
    }

    static let portsKey = "homeswift.devicePorts"

    public func stop() async {
        for observation in observations { observation.cancel() }
        observations = []
        for task in tasks { task.cancel() }
        tasks = []
        let nodes = [node] + devices.values.compactMap(\.own)
        await withTaskGroup(of: Void.self) { group in
            for node in nodes { group.addTask { await node.stop() } }
        }
    }

    /// The onboarding payload: the QR code's text and the manual pairing code. Shown to people, never logged.
    public nonisolated var setupPayload: SetupPayload { node.setupPayload }

    public var isCommissioned: Bool { get async { await node.isCommissioned } }

    // MARK: - Accessories

    /// Adds the accessories that appeared, removes those that left, makes again those whose services changed. One at a
    /// time: a change of settings and a plugin's new accessories may ask together.
    func sync() async {
        let previous = syncing
        let next = Task {
            await previous?.value
            await self.syncNow()
        }
        syncing = next
        await next.value
    }

    /// Whether an accessory has anything Matter can show, with locks only when `exposeSecurity` is on.
    public static func maps(_ accessory: Accessory, exposeSecurity: Bool) -> Bool {
        accessory.mirroredFrom == nil && accessory.services.contains { ServiceMapping($0, exposeSecurity: exposeSecurity) != nil }
    }

    private func syncNow() async {
        var seen = Set<String>()
        let ownIDs = Set(configuration.devices)
        for (accessory, names) in source.matterAccessories where accessory.id != "bridge" && accessory.mirroredFrom == nil {
            // A device of its own is one because it was asked for by id; the bridge takes what its patterns match.
            let own = ownIDs.contains(accessory.id)
            guard own || (configuration.bridge && configuration.bridges(names)) else { continue }
            let mappings = accessory.services.compactMap { ServiceMapping($0, exposeSecurity: configuration.exposeSecurity) }
            guard !mappings.isEmpty else { continue }
            seen.insert(accessory.id)
            if let known = devices[accessory.id] {
                if known.shape == Shape(mappings, own: own) {
                    if known.name != accessory.name { await known.device.setName(accessory.name) }
                    if known.accessory !== accessory {
                        // A plugin replaced the accessory with one of the same shape (its cached one, once it
                        // reached the device): the device stays, on the new object's values.
                        devices[accessory.id] = Bridged(device: known.device, accessory: accessory, mappings: mappings, own: known.own)
                        await report(accessory, mappings: mappings, on: known.device)
                    } else {
                        devices[accessory.id]?.name = accessory.name
                    }
                    continue
                }
                await remove(accessory.id)
            }
            await add(accessory, mappings: mappings, own: own)
        }
        for id in devices.keys where !seen.contains(id) { await remove(id) }
    }

    private func add(_ accessory: Accessory, mappings: [ServiceMapping], own: Bool) async {
        let information = accessory.information
        let info = BridgedDeviceInfo(
            id: accessory.id, name: accessory.name,
            vendorName: information[.manufacturer]?.value.stringValue?.nonEmpty, productName: information[.model]?.value.stringValue?.nonEmpty,
            serialNumber: information[.serialNumber]?.value.stringValue?.nonEmpty)
        // Commands go through the actor to the accessory bridged now, which a plugin may have replaced since.
        let id = accessory.id
        let parts = mappings.indices.map { index in
            DevicePart(mappings[index].kind) { [weak self] command in try await self?.perform(command, on: id, part: index) }
        }
        let battery = accessory.services.contains { $0.type.uuid == ServiceType.battery.uuid && $0[.batteryLevel] != nil }
        do {
            if own {
                // A port another program holds makes the start fail: the next free one is tried, a few times.
                var refused: Set<Int> = []
                while true {
                    let port = try await port(for: accessory.id, avoiding: refused)
                    // Its manufacturer, model and serial number, and its name as the label.
                    let ownNode = try await Self.makeNode(
                        NodeInformation(vendorName: info.vendorName ?? "Homeswift", productName: info.productName ?? accessory.name, nodeLabel: accessory.name,
                                        softwareVersionString: PluginHost.version, serialNumber: info.serialNumber ?? "", uniqueID: info.uniqueID),
                        port: port, deviceType: mappings[0].kind.deviceTypes.first?.id ?? DeviceTypes.onOffPlugInUnit.id,
                        storage: deviceStorage(accessory.id), transport: await deviceTransport?(accessory.id), tcp: configuration.tcp,
                        advertise: advertise, reliability: reliability, logger: logger)
                    let device = try await ownNode.addDevice(info, parts: parts, battery: battery)
                    // Watched before it starts, so the window it opens reaches the pages too.
                    await watch(ownNode, device: accessory.id)
                    do {
                        try await ownNode.start()
                    } catch where refused.count < 4 {
                        await ownNode.stop()
                        refused.insert(port)
                        logger.warning("Matter: port \(port) is taken, trying another for \(accessory.name)")
                        continue
                    }
                    devices[accessory.id] = Bridged(device: device, accessory: accessory, mappings: mappings, own: ownNode)
                    await report(accessory, mappings: mappings, on: device)
                    logger.info("Matter: \(accessory.name) is a device of its own on port \(port)")
                    return
                }
            }
            let device = try await bridge.add(info, parts: parts, battery: battery)
            devices[accessory.id] = Bridged(device: device, accessory: accessory, mappings: mappings)
            await report(accessory, mappings: mappings, on: device)
        } catch {
            logger.error("Matter: could not bridge \(accessory.name): \(error)")
        }
    }

    /// Reports every state of an accessory: when it is bridged, and when a plugin replaced it.
    private func report(_ accessory: Accessory, mappings: [ServiceMapping], on device: BridgedDevice) async {
        for (index, mapping) in mappings.enumerated() {
            for state in mapping.states() { await device.update(robotState(state, id: accessory.id), part: index) }
        }
        if let level = batteryLevel(accessory) { await device.update(.battery(percent: level)) }
        await device.setReachable(!accessory.isUnavailable)
    }

    /// A Matter controller's command: the characteristic writes Apple Home would make.
    private func perform(_ command: DeviceCommand, on id: String, part: Int) async throws {
        guard let bridged = devices[id], bridged.mappings.indices.contains(part) else { throw HAPStatusError(.resourceDoesNotExist) }
        if case .identify(let seconds) = command {
            if seconds > 0 { try await bridged.accessory.information[.identify]?.write(.bool(true)) }
            return
        }
        for (characteristic, value) in bridged.mappings[part].writes(for: command) {
            do {
                try await characteristic.write(value)
            } catch {
                logger.warning("Matter: \(bridged.name) refused \(characteristic.type.name): \(error)")
                throw error
            }
        }
        guard bridged.mappings[part].role == .cleaningRobot else { return }
        switch command {
        case .pauseCleaning:
            pausedRobots.insert(id)
            await bridged.device.update(.robot(.paused), part: part)
        case .startCleaning, .resumeCleaning, .stopCleaning, .returnToDock:
            pausedRobots.remove(id)
        default:
            break
        }
    }

    /// A cleaning robot's state, paused rather than stopped while a controller's pause holds.
    private func robotState(_ state: DeviceState, id: String) -> DeviceState {
        guard case .robot(let robot) = state else { return state }
        if robot != .stopped { pausedRobots.remove(id) }
        return robot == .stopped && pausedRobots.contains(id) ? .robot(.paused) : state
    }

    /// The accessory's port: the one it had (unless refused), else the first one after the bridge's that no other
    /// accessory has.
    private func port(for id: String, avoiding refused: Set<Int>) async throws -> Int {
        if let known = ports[id], !refused.contains(known) { return known }
        let taken = Set(ports.filter { $0.key != id }.values).union(refused)
        guard let free = (configuration.port + 1...65535).first(where: { !taken.contains($0) }) else { throw BridgeError.endpointsExhausted }
        ports[id] = free
        try await savePorts()
        return free
    }

    private func savePorts() async throws {
        try await storage.setValue(Array(try JSONEncoder().encode(ports)), for: Self.portsKey)
    }

    private func remove(_ id: String) async {
        guard let removed = devices.removeValue(forKey: id) else { return }
        if let own = removed.own {
            await own.stop()
            // Taken off Matter: its port is free again. Its node's state stays, should it come back.
            if !configuration.devices.contains(id), ports.removeValue(forKey: id) != nil { try? await savePorts() }
        } else {
            try? await bridge.remove(id)
        }
    }

    /// A plugin changed a value: report it on the device's part that has the characteristic.
    private func changed(_ accessory: Accessory, _ characteristic: Characteristic, _ value: HAPValue) async {
        guard let bridged = devices[accessory.id], bridged.accessory === accessory else { return }
        let device = bridged.device
        await device.setReachable(!accessory.isUnavailable)
        let type = characteristic.type.uuid
        if type == CharacteristicType.batteryLevel.uuid, let level = batteryLevel(accessory) {
            await device.update(.battery(percent: level))
            return
        }
        guard let index = bridged.parts[ObjectIdentifier(characteristic)] else { return }
        if type == CharacteristicType.programmableSwitchEvent.uuid {
            if let press = ServiceMapping.press(value) { await device.press(press, part: index) }
            return
        }
        for state in bridged.mappings[index].states(changed: type) { await device.update(robotState(state, id: accessory.id), part: index) }
    }

    private func batteryLevel(_ accessory: Accessory) -> UInt8? {
        accessory[.battery]?[.batteryLevel]?.value.doubleValue.map { UInt8(min(max($0, 0), 100).rounded()) }
    }

    /// The accessory ids bridged now, for tests and the status.
    var bridgedIDs: [String] { devices.keys.sorted() }

    /// The device of an accessory, for tests.
    func device(for accessoryID: String) -> BridgedDevice? { devices[accessoryID]?.device }

    // MARK: - MatterControl

    public func statusJSON(includePairing: Bool) async -> JSONValue {
        var status = await Self.nodeStatus(node, includePairing: includePairing && configuration.bridge)
        status["bridge"] = .bool(configuration.bridge)
        status["port"] = .number(Double(configuration.port))
        var bridged: [JSONValue] = [], own: [JSONValue] = []
        for device in devices.values.sorted(by: { $0.name < $1.name }) {
            var entry: [String: JSONValue] = ["name": .string(device.name), "id": .string(device.accessory.id),
                                              "types": .array(device.mappings.map { .string("\($0.role)") })]
            if let node = device.own {
                entry.merge(await Self.nodeStatus(node, includePairing: includePairing)) { $1 }
                entry["port"] = ports[device.accessory.id].map { .number(Double($0)) }
                own.append(.object(entry))
            } else {
                entry["endpoint"] = .number(Double(device.device.endpoint))
                bridged.append(.object(entry))
            }
        }
        status["devices"] = .array(bridged)
        status["ownDevices"] = .array(own)
        return .object(status)
    }

    /// The QR code's text of the bridge or of a device of its own, while its window is open. Shown, never logged.
    public func qrCode(device: String?) async -> String? {
        guard let (node, _) = try? node(for: device), await node.commissioning.windowStatus == .basic else { return nil }
        return node.setupPayload.qrCode
    }

    /// The pairing codes of the nodes whose window is open, for a banner on standard output (never the log).
    public func pairingLines() async -> String {
        var lines: [String] = []
        let nodes = (configuration.bridge ? [("Matter bridge", node, configuration.port)] : [])
            + devices.values.sorted { $0.name < $1.name }.compactMap { device in device.own.map { (device.name, $0, ports[device.accessory.id] ?? 0) } }
        for (name, node, port) in nodes {
            guard await node.commissioning.windowStatus == .basic else {
                lines.append("Matter:     \(name), port \(port), commissioned")
                continue
            }
            lines.append("Matter:     \(name), port \(port)\n            Pairing code: \(node.setupPayload.manualCode)   QR code: \(node.setupPayload.qrCode)")
        }
        return lines.map { $0 + "\n" }.joined()
    }

    /// A node's commissioning state and fabrics, and its pairing codes while its window is open.
    private static func nodeStatus(_ node: MatterNode, includePairing: Bool) async -> [String: JSONValue] {
        let window = await node.commissioning.windowStatus
        let fabrics = await node.fabrics.all
        let windowText = switch window {
        case .closed: "closed"
        case .basic: "open"
        case .enhanced: "open for another administrator"
        }
        var status: [String: JSONValue] = [
            "commissioned": .bool(!fabrics.isEmpty),
            "commissioningWindow": .string(windowText),
            "fabrics": .array(fabrics.map { fabric in
                [
                    "index": .number(Double(fabric.index)), "label": .string(fabric.label),
                    "vendorId": .string(String(format: "0x%04X", fabric.vendorID)), "fabricId": .string(String(format: "%016llX", fabric.fabricID)),
                ]
            }),
        ]
        if includePairing, window == .basic {
            status["pairing"] = ["qrCode": .string(node.setupPayload.qrCode), "manualCode": .string(node.setupPayload.manualCode)]
        }
        return status
    }

    /// The bridge's node, or the node of the accessory `device` that is a Matter device of its own, with its name.
    private func node(for device: String?) throws -> (MatterNode, String) {
        guard let device else {
            guard configuration.bridge else { throw CatalogError("The Matter bridge is off: give the device") }
            return (node, "the bridge")
        }
        guard let bridged = devices[device], let own = bridged.own else {
            throw CatalogError("No Matter device of its own \(device): get_matter_status lists them")
        }
        return (own, bridged.name)
    }

    public func openCommissioningWindow(minutes: Int, device: String?) async throws -> JSONValue {
        let (target, name) = try node(for: device)
        let minutes = min(max(minutes, 3), 15)
        await target.openCommissioningWindow(timeout: .seconds(minutes * 60))
        logger.info("Matter commissioning window of \(name) opened for \(minutes) minutes")
        return ["open": true, "minutes": .number(Double(minutes)),
                "note": "Add it in the other ecosystem's app with the QR code or pairing code the web UI shows."]
    }

    public func removeFabric(index: Int, device: String?) async throws -> JSONValue {
        let (target, name) = try node(for: device)
        guard let fabric = UInt8(exactly: index), await target.fabrics.fabric(fabric) != nil else {
            throw CatalogError("No Matter fabric \(index): get_matter_status lists them")
        }
        try await target.removeFabric(fabric)
        logger.info("Matter fabric \(index) of \(name) removed")
        return ["removed": .number(Double(index)), "note": "That ecosystem no longer has it; add it again with the pairing code."]
    }
}

