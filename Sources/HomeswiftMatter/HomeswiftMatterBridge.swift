import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Logging
import Matter

/// The Matter bridge: every accessory the plugins publish (that the `HomeswiftMatter` block bridges) as a Matter
/// bridged device, both ways. A value a plugin sets is reported to the Matter controllers; a Matter command writes the
/// characteristic as Apple Home would, so plugins see no difference. Started by the CLI, like the web UI.
public actor HomeswiftMatterBridge: MatterControl {
    public nonisolated let configuration: MatterConfiguration
    public nonisolated let node: MatterNode
    private let bridge: MatterBridge
    private let host: PluginHost
    private let logger: Logger
    private let resyncInterval: Duration
    /// The bridged accessories, by accessory id.
    private var devices: [String: Bridged] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var observation: Observation?

    private struct Bridged {
        let device: BridgedDevice
        let accessory: Accessory
        let mappings: [ServiceMapping]
        /// The services' iids and types: when they change, the device is made again.
        let shape: [String]
        var name: String
    }

    /// The node's state lives in `storageDirectory` (its fabrics and keys, owner-only files). `transport` and
    /// `advertiser` default to UDP on the configured port and the built-in mDNS responder; tests pass memory ones.
    public init(configuration: MatterConfiguration, host: PluginHost, storageDirectory: URL, transport: (any MatterTransport)? = nil,
                advertise: Bool = true, resyncInterval: Duration = .seconds(10), logger: Logger = Logger(label: "homeswift.matter")) async throws {
        self.configuration = configuration
        self.host = host
        self.logger = logger
        self.resyncInterval = resyncInterval
        let storage = try FileStorage(directory: storageDirectory)
        var nodeConfiguration = NodeConfiguration(
            information: NodeInformation(vendorName: "Homeswift", productName: "Homeswift Bridge", nodeLabel: "Homeswift",
                                         softwareVersionString: PluginHost.version),
            port: configuration.port)
        // The window stays open until the bridge is commissioned, as a HAP bridge stays pairable.
        nodeConfiguration.initialWindowTimeout = nil
        node = try await MatterNode(configuration: nodeConfiguration, storage: storage, transport: transport,
                                    advertiser: advertise ? MDNSAdvertiser(logger: logger) : nil, logger: logger)
        bridge = try await MatterBridge(node: node)
    }

    /// Bridges the accessories there are now, starts the node, then follows the plugins' changes.
    public func start() async throws {
        await sync()
        try await node.start()
        let (changes, continuation) = AsyncStream<(Accessory, Characteristic, HAPValue)>.makeStream()
        // One stream keeps the changes in order (a press after the state it follows).
        observation = host.observeChanges { accessory, characteristic, value in continuation.yield((accessory, characteristic, value)) }
        tasks.append(Task { [weak self] in
            for await (accessory, characteristic, value) in changes { await self?.changed(accessory, characteristic, value) }
        })
        let interval = resyncInterval
        tasks.append(Task { [weak self] in
            // HAPServer does not say when accessories come and go: look again now and then.
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.sync()
            }
        })
        logger.info("Matter bridge on port \(configuration.port): \(devices.count) accessories bridged")
    }

    public func stop() async {
        observation?.cancel()
        observation = nil
        for task in tasks { task.cancel() }
        tasks = []
        await node.stop()
    }

    /// The onboarding payload: the QR code's text and the manual pairing code. Shown to people, never logged.
    public nonisolated var setupPayload: SetupPayload { node.setupPayload }

    public var isCommissioned: Bool { get async { await node.isCommissioned } }

    // MARK: - Accessories

    /// Adds the accessories that appeared, removes those that left, makes again those whose services changed.
    func sync() async {
        var seen = Set<String>()
        let platforms = host.platforms
        for bridgeEntry in host.bridges {
            for accessory in bridgeEntry.server.accessories where accessory.id != "bridge" && accessory.mirroredFrom == nil {
                let platform = platforms.first { $0.bridge === bridgeEntry && $0.accessoryIDs.contains(accessory.id) }
                let names = [platform?.platform, platform?.name, accessory.id, accessory.name].compactMap { $0 }
                guard configuration.bridges(names) else { continue }
                let mappings = accessory.services.compactMap { ServiceMapping($0, exposeSecurity: configuration.exposeSecurity) }
                guard !mappings.isEmpty else { continue }
                seen.insert(accessory.id)
                let shape = mappings.map { "\($0.service.iid):\($0.service.type.uuid)" }
                if let known = devices[accessory.id] {
                    if known.accessory === accessory, known.shape == shape {
                        if known.name != accessory.name {
                            await known.device.setName(accessory.name)
                            devices[accessory.id]?.name = accessory.name
                        }
                        continue
                    }
                    await remove(accessory.id)
                }
                await add(accessory, mappings: mappings, shape: shape)
            }
        }
        for id in devices.keys where !seen.contains(id) { await remove(id) }
    }

    private func add(_ accessory: Accessory, mappings: [ServiceMapping], shape: [String]) async {
        let information = accessory.information
        let info = BridgedDeviceInfo(
            id: Self.deviceID(accessory.id), name: accessory.name,
            vendorName: information[.manufacturer]?.value.stringValue?.nonEmpty, productName: information[.model]?.value.stringValue?.nonEmpty,
            serialNumber: information[.serialNumber]?.value.stringValue?.nonEmpty)
        let logger = logger
        let parts = mappings.map { mapping in
            DevicePart(mapping.kind) { command in
                if case .identify(let seconds) = command {
                    if seconds > 0 { try await information[.identify]?.write(.bool(true)) }
                    return
                }
                for (characteristic, value) in mapping.writes(for: command) {
                    do {
                        try await characteristic.write(value)
                    } catch {
                        logger.warning("Matter: \(accessory.name) refused \(characteristic.type.name): \(error)")
                        throw error
                    }
                }
            }
        }
        let battery = accessory.services.contains { $0.type.uuid == ServiceType.battery.uuid && $0[.batteryLevel] != nil }
        do {
            let device = try await bridge.add(info, parts: parts, battery: battery)
            devices[accessory.id] = Bridged(device: device, accessory: accessory, mappings: mappings, shape: shape, name: accessory.name)
            for (index, mapping) in mappings.enumerated() {
                for state in mapping.states() { await device.update(state, part: index) }
            }
            if let level = batteryLevel(accessory) { await device.update(.battery(percent: level)) }
            await device.setReachable(!accessory.isUnavailable)
        } catch {
            logger.error("Matter: could not bridge \(accessory.name): \(error)")
        }
    }

    private func remove(_ id: String) async {
        guard devices.removeValue(forKey: id) != nil else { return }
        try? await bridge.remove(Self.deviceID(id))
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
        guard let index = bridged.mappings.firstIndex(where: { $0.service.characteristics.contains { $0 === characteristic } }) else { return }
        if type == CharacteristicType.programmableSwitchEvent.uuid {
            if let press = ServiceMapping.press(value) { await device.press(press, part: index) }
            return
        }
        for state in bridged.mappings[index].states(changed: type) { await device.update(state, part: index) }
    }

    private func batteryLevel(_ accessory: Accessory) -> UInt8? {
        accessory[.battery]?[.batteryLevel]?.value.doubleValue.map { UInt8(min(max($0, 0), 100).rounded()) }
    }

    /// Bridged Device Basic Information's UniqueID holds 32 characters, and accessory ids are often longer: the first
    /// 32 hex digits of the id's SHA-256, the same at every start, so each device keeps its endpoint.
    static func deviceID(_ accessoryID: String) -> String {
        SHA256.hash(data: Data(accessoryID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// The accessory ids bridged now, for tests and the status.
    var bridgedIDs: [String] { devices.keys.sorted() }

    /// The device of an accessory, for tests.
    func device(for accessoryID: String) -> BridgedDevice? { devices[accessoryID]?.device }

    // MARK: - MatterControl

    public func statusJSON(includePairing: Bool) async -> JSONValue {
        let window = await node.commissioning.windowStatus
        var status: [String: JSONValue] = [
            "port": .number(Double(configuration.port)),
            "commissioned": .bool(await node.isCommissioned),
            "commissioningWindow": .string(window == .closed ? "closed" : window == .basic ? "open" : "open for another administrator"),
            "fabrics": .array(await node.fabrics.all.map { fabric in
                [
                    "index": .number(Double(fabric.index)), "label": .string(fabric.label),
                    "vendorId": .string(String(format: "0x%04X", fabric.vendorID)), "fabricId": .string(String(format: "%016llX", fabric.fabricID)),
                ]
            }),
            "devices": .array(devices.values.sorted { $0.name < $1.name }.map { bridged in
                ["name": .string(bridged.name), "id": .string(bridged.accessory.id), "endpoint": .number(Double(bridged.device.endpoint)),
                 "types": .array(bridged.mappings.map { .string("\($0.role)") })]
            }),
        ]
        if includePairing, window == .basic {
            status["pairing"] = ["qrCode": .string(setupPayload.qrCode), "manualCode": .string(setupPayload.manualCode)]
        }
        return .object(status)
    }

    public func qrCodePayload() async -> String? {
        await node.commissioning.windowStatus == .basic ? setupPayload.qrCode : nil
    }

    public func openCommissioningWindow(minutes: Int) async throws -> JSONValue {
        let minutes = min(max(minutes, 3), 15)
        await node.openCommissioningWindow(timeout: .seconds(minutes * 60))
        logger.info("Matter commissioning window opened for \(minutes) minutes")
        return ["open": true, "minutes": .number(Double(minutes)),
                "note": "Add the bridge in the other ecosystem's app with the QR code or pairing code the web UI shows."]
    }

    public func removeFabric(index: Int) async throws -> JSONValue {
        guard let fabric = UInt8(exactly: index), await node.fabrics.fabric(fabric) != nil else {
            throw CatalogError("No Matter fabric \(index): get_matter_status lists them")
        }
        try await node.removeFabric(fabric)
        logger.info("Matter fabric \(index) removed")
        return ["removed": .number(Double(index)), "note": "That ecosystem no longer has the bridge; add it again with the pairing code."]
    }
}
