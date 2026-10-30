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
    /// The bridged accessories, by accessory id.
    private var devices: [String: Bridged] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var observations: [Observation] = []

    private struct Bridged {
        let device: BridgedDevice
        let accessory: Accessory
        let mappings: [ServiceMapping]
        /// The part of each mapped characteristic, by its identity: a change finds its part without a search.
        let parts: [ObjectIdentifier: Int]
        var name: String

        init(device: BridgedDevice, accessory: Accessory, mappings: [ServiceMapping]) {
            self.device = device
            self.accessory = accessory
            self.mappings = mappings
            name = accessory.name
            var parts: [ObjectIdentifier: Int] = [:]
            for (index, mapping) in mappings.enumerated() {
                for characteristic in mapping.service.characteristics { parts[ObjectIdentifier(characteristic)] = index }
            }
            self.parts = parts
        }

        /// The services' iids and types: when they change, the device is made again.
        var shape: [String] { Self.shape(mappings) }
        static func shape(_ mappings: [ServiceMapping]) -> [String] { mappings.map { "\($0.service.iid):\($0.service.type.uuid)" } }
    }

    /// The node's state (its fabrics and keys) lives in `storage`: `MatterFileStorage` under `matter/`, or memory in
    /// tests. `transport` and the advertiser default to UDP on the configured port and the built-in mDNS responder;
    /// tests pass memory ones, and MRP timings scaled down (`reliability`).
    public init(configuration: MatterConfiguration, host: PluginHost, storage: any MatterStorage, transport: (any MatterTransport)? = nil,
                advertise: Bool = true, reliability: ReliabilityParameters = .init(),
                logger: Logger = Logger(label: "homeswift.matter")) async throws {
        self.configuration = configuration
        self.host = host
        self.logger = logger
        var nodeConfiguration = NodeConfiguration(
            information: NodeInformation(vendorName: "Homeswift", productName: "Homeswift Bridge", nodeLabel: "Homeswift",
                                         softwareVersionString: PluginHost.version),
            port: configuration.port)
        // The window stays open until the bridge is commissioned, as a HAP bridge stays pairable.
        nodeConfiguration.initialWindowTimeout = nil
        nodeConfiguration.reliability = reliability
        nodeConfiguration.tcp = configuration.tcp
        node = try await MatterNode(configuration: nodeConfiguration, storage: storage, transport: transport,
                                    advertiser: advertise ? MDNSAdvertiser(logger: logger) : nil, logger: logger)
        bridge = try await MatterBridge(node: node)
    }

    /// Follows the plugins' changes, bridges the accessories there are now, then starts the node. Following comes
    /// first, so nothing a plugin does meanwhile is missed.
    public func start() async throws {
        let (changes, continuation) = AsyncStream<(Accessory, Characteristic, HAPValue)>.makeStream()
        // One stream keeps the changes in order (a press after the state it follows).
        observations.append(host.observeChanges { accessory, characteristic, value in continuation.yield((accessory, characteristic, value)) })
        tasks.append(Task { [weak self] in
            for await (accessory, characteristic, value) in changes { await self?.changed(accessory, characteristic, value) }
        })
        // Accessories coming and going: a burst (a plugin adding its devices at launch) makes one look, not one each.
        let (structure, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations.append(host.observeStructure { signal.yield() })
        tasks.append(Task { [weak self] in
            for await _ in structure { await self?.sync() }
        })
        await sync()
        try await node.start()
        logger.info("Matter bridge on port \(configuration.port): \(devices.count) accessories bridged")
    }

    public func stop() async {
        for observation in observations { observation.cancel() }
        observations = []
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
        var owners: [ObjectIdentifier: [String: PluginHost.PlatformInstance]] = [:]
        for platform in host.platforms {
            for id in platform.accessoryIDs { owners[ObjectIdentifier(platform.bridge), default: [:]][id] = platform }
        }
        for bridgeEntry in host.bridges {
            for accessory in bridgeEntry.server.accessories where accessory.id != "bridge" && accessory.mirroredFrom == nil {
                let platform = owners[ObjectIdentifier(bridgeEntry)]?[accessory.id]
                let names = [platform?.platform, platform?.name, accessory.id, accessory.name].compactMap { $0 }
                guard configuration.bridges(names) else { continue }
                let mappings = accessory.services.compactMap { ServiceMapping($0, exposeSecurity: configuration.exposeSecurity) }
                guard !mappings.isEmpty else { continue }
                seen.insert(accessory.id)
                if let known = devices[accessory.id] {
                    if known.shape == Bridged.shape(mappings) {
                        if known.name != accessory.name { await known.device.setName(accessory.name) }
                        if known.accessory !== accessory {
                            // A plugin replaced the accessory with one of the same shape (its cached one, once it
                            // reached the device): the device stays, on the new object's values.
                            devices[accessory.id] = Bridged(device: known.device, accessory: accessory, mappings: mappings)
                            await report(accessory, mappings: mappings, on: known.device)
                        } else {
                            devices[accessory.id]?.name = accessory.name
                        }
                        continue
                    }
                    await remove(accessory.id)
                }
                await add(accessory, mappings: mappings)
            }
        }
        for id in devices.keys where !seen.contains(id) { await remove(id) }
    }

    private func add(_ accessory: Accessory, mappings: [ServiceMapping]) async {
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
            for state in mapping.states() { await device.update(state, part: index) }
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
    }

    private func remove(_ id: String) async {
        guard devices.removeValue(forKey: id) != nil else { return }
        try? await bridge.remove(id)
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
        for state in bridged.mappings[index].states(changed: type) { await device.update(state, part: index) }
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
        let window = await node.commissioning.windowStatus
        let fabrics = await node.fabrics.all
        let windowText = switch window {
        case .closed: "closed"
        case .basic: "open"
        case .enhanced: "open for another administrator"
        }
        var status: [String: JSONValue] = [
            "port": .number(Double(configuration.port)),
            "commissioned": .bool(!fabrics.isEmpty),
            "commissioningWindow": .string(windowText),
            "fabrics": .array(fabrics.map { fabric in
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
