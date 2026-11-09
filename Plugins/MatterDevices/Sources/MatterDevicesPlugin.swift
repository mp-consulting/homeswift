import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import Matter
import NIOCore

/// Matter devices Homeswift controls itself, as one more Matter controller of theirs (multi-admin, Core §5.5): a device
/// another app has (Apple Home, Google Home, the maker's app) opens a pairing window there, and Setup takes its pairing
/// code. Homeswift adds it to a fabric of its own, reaches it over CASE through DNS-SD (Thread devices through their
/// border router) and keeps a subscription to what HomeKit shows: lights, plugs, switches, contact, occupancy,
/// temperature and humidity sensors, batteries, and remotes' buttons. A remote's wheel can dim a light of the bridge.
///
/// No upstream: Homebridge has no Matter controller plugin; Home Assistant's Matter integration (python-matter-server)
/// is what people would otherwise run. README.md says what differs.
public actor MatterDevicesPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
    }

    /// What the plugin reaches the network with; tests give a memory network and a fake discovery.
    struct Dependencies: Sendable {
        var transport: @Sendable () async -> any MatterTransport = { UDPTransport(port: 0) }
        var discovery: any MatterDiscovery = BonjourMatterDiscovery()
        /// Where an address goes on the message layer: a datagram socket address (a memory network's in tests).
        var peer: @Sendable (NodeAddress) throws -> PeerAddress = { .socket(try SocketAddress(ipAddress: $0.host, port: $0.port)) }
        var timing = MatterNodeLink.Timing()
        /// Seconds Setup looks for a pairing window that matches a code.
        var windowSearch: Duration = .seconds(8)
        var reliability = ReliabilityParameters()
        /// The roots and keys device attestation is checked against: the Matter registry's.
        var trustStore = AttestationTrustStore.registry
    }

    public static let platform = "MatterDevices"
    public static let name = "Matter Devices"
    public static let icon: String? = "matter"
    public static let summary: String? = "Matter devices other apps already have, controlled by Homeswift too"
    public static let newDevices: NewDevices? = .made(label: "Add a Matter device…")
    /// A remote's dimming settings are read on each event: saving them leaves every node connected.
    public static let appliesAccessorySettingsLive = true

    let configuration: Configuration
    nonisolated let context: PluginContext
    let dependencies: Dependencies
    var logger: Logger { context.logger }

    private var layer: MessageLayer?
    private(set) var commissioner: Commissioner?
    /// The running nodes, by Device Id.
    private(set) var nodes: [String: RunningNode] = [:]
    private let tasks = TaskBag()

    /// A node the plugin follows: its link, and what its last structure made.
    struct RunningNode {
        var record: NodeRecord
        let link: MatterNodeLink
        var structure: NodeStructure?
        var plan = MatterAccessoryPlan()
        var channels: [WheelChannel] = []
        var gestures = WheelGestures()
        /// Its last events, oldest first.
        var events: [RecentEvent] = []
    }

    /// An event the page lists, newest first.
    struct RecentEvent: Sendable {
        var time: Date
        var endpoint: EndpointNumber
        var name: String
        var detail: String?
    }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// A node's Device Id: its node id on Homeswift's fabric, 16 uppercase hexadecimal digits.
    static func deviceID(nodeID: NodeID) -> String { String(format: "%016llX", nodeID) }

    var network: MatterNodeLink.Network {
        MatterNodeLink.Network(discovery: dependencies.discovery, peer: dependencies.peer, timing: dependencies.timing)
    }

    // MARK: - Storage

    /// The fabric's keys, in the vault: what makes Homeswift one of its nodes' controllers.
    var fabricFile: SecretFile<Commissioner.Snapshot> { context.secretFile("matter-fabric.json", as: Commissioner.Snapshot.self) }

    /// What the plugin keeps of a node outside the vault: who it is and where it last answered.
    struct NodeRecord: Codable, Sendable, Equatable {
        var nodeID: NodeID
        var name: String?
        var vendorName: String?
        var productName: String?
        var vendorID: UInt16?
        var productID: UInt16?
        var kind: String?
        var address: NodeAddress?
        var added: Date?
        /// A remote's wheel channels, as its structure last said: its settings while it reconnects.
        var channels: Int?
    }

    /// The node records, one file each so Setup and the running instance never write over each other's.
    func records() -> [String: NodeRecord] {
        let directory = context.storageDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var records: [String: NodeRecord] = [:]
        for name in names where name.hasPrefix("node-") && name.hasSuffix(".json") {
            let deviceID = String(name.dropFirst("node-".count).dropLast(".json".count))
            if let record = context.jsonFile(name, as: NodeRecord.self).load() { records[deviceID] = record }
        }
        return records
    }

    func recordFile(_ deviceID: String) -> JSONFile<NodeRecord> { context.jsonFile("node-\(deviceID).json", as: NodeRecord.self) }

    /// The credentials Setup keeps for a node: the node id, which says Homeswift added it.
    struct NodeCredentials: Codable, Sendable {
        var nodeID: String
    }

    // MARK: - Running

    public func start() async throws {
        let known = records()
        guard let snapshot = fabricFile.load() else {
            if !known.isEmpty { logger.warning("Matter node records without the fabric's keys in the vault: the nodes cannot be reached") }
            return
        }
        let layer = MessageLayer(transport: await dependencies.transport(), reliability: dependencies.reliability)
        let commissioner = try Commissioner(layer: layer, snapshot: snapshot)
        try await commissioner.start()
        self.layer = layer
        self.commissioner = commissioner

        for (deviceID, record) in known.sorted(by: { $0.key < $1.key }) {
            guard context.credentials(for: deviceID) != nil else {
                // Forgotten (its Authorization dropped): Homeswift leaves the device's fabric list, then forgets it.
                forgetNode(deviceID, record: record, commissioner: commissioner)
                continue
            }
            guard !context.isExcluded(deviceID) else { continue }
            follow(deviceID, record: record, commissioner: commissioner)
        }
        // Accessories of nodes no longer known go; those of known nodes stay cached until their node answers.
        let followed = Set(nodes.keys)
        let ids = Set(context.accessories.map(\.id).filter { id in followed.contains { context.isAccessory(id, of: $0) } })
        _ = await context.removeAccessories(keeping: ids, message: "Removing the accessory of a Matter device no longer added")
    }

    public func stop() async {
        tasks.cancelAll()
        // A hold under way stops with the plugin (a reload, Forget), not 60 steps later.
        for controller in channelDimmers.values { await controller.release() }
        channelDimmers = [:]
        writers = [:]
        for node in nodes.values { await node.link.stop() }
        nodes = [:]
        await layer?.stop()
        layer = nil
        commissioner = nil
    }

    private func follow(_ deviceID: String, record: NodeRecord, commissioner: Commissioner) {
        let handlers = MatterNodeLink.Handlers(
            structure: { [weak self] structure in await self?.structureRead(deviceID, structure) ?? ([], false) },
            report: { [weak self] attributes, events, priming in await self?.reported(deviceID, attributes: attributes, events: events, priming: priming) },
            status: { [weak self] status, error in await self?.statusChanged(deviceID, status, error: error) },
            address: { [weak self] address in await self?.addressChanged(deviceID, address) })
        let link = MatterNodeLink(deviceID: deviceID, nodeID: record.nodeID, commissioner: commissioner, network: network,
                                  address: record.address, handlers: handlers, logger: logger)
        nodes[deviceID] = RunningNode(record: record, link: link)
        Task { await link.start() }
    }

    private func forgetNode(_ deviceID: String, record: NodeRecord, commissioner: Commissioner) {
        let network = network, logger = logger, file = recordFile(deviceID)
        tasks.add {
            do {
                try await MatterNodeLink.removeFabric(nodeID: record.nodeID, commissioner: commissioner, network: network, known: record.address)
                logger.info("Matter device \(record.name ?? deviceID) forgotten: Homeswift left its controllers")
            } catch {
                logger.warning("Matter device \(record.name ?? deviceID) forgotten, but it did not answer: remove Homeswift from its controllers in the app that has it",
                               metadata: ["error": "\(MatterNodeLink.describe(error))"])
            }
            file.remove()
        }
    }

    // MARK: - What a link reports

    private func structureRead(_ deviceID: String, _ structure: NodeStructure) async -> (attributes: [ConcreteAttribute], events: Bool) {
        guard var node = nodes[deviceID] else { return ([], false) }
        let link = node.link
        // The device's own serial number when it gives one (CLAUDE.md), else its unique id, else its Device Id.
        let serial = [structure.serialNumber, structure.uniqueID].compactMap { $0 }.first { !$0.isEmpty } ?? deviceID
        let plan = MatterAccessories.plan(structure, accessoryID: Self.accessoryID(deviceID: deviceID), serialNumber: serial) { endpoint, cluster, command, fields in
            try await link.invoke(endpoint: endpoint, cluster: cluster, command: command, fields: fields)
        }
        node.structure = structure
        node.plan = plan
        node.channels = WheelChannel.channels(structure)
        var record = node.record
        record.name = structure.name
        record.vendorName = structure.vendorName
        record.productName = structure.productName
        record.vendorID = structure.vendorID
        record.productID = structure.productID
        record.kind = plan.deviceKind
        record.channels = node.channels.count
        if record != node.record {
            node.record = record
            try? recordFile(deviceID).save(record)
        }
        nodes[deviceID] = node
        for accessory in plan.accessories {
            if let cached = context.accessory(id: accessory.id) { accessory.takeValues(from: cached) }
            do { try context.add(accessory) } catch { logger.warning("Matter device \(structure.name): \(error)") }
        }
        // A bridged device the node no longer has goes; the other nodes' accessories stay.
        let built = Set(plan.accessories.map(\.id))
        for accessory in context.accessories where context.isAccessory(accessory.id, of: deviceID) && !built.contains(accessory.id) {
            try? await context.remove(accessory)
        }
        if plan.accessories.isEmpty { logger.info("Matter device \(structure.name) has nothing HomeKit shows yet (its clusters are not mapped)") }
        return (plan.attributes, !plan.buttons.isEmpty)
    }

    private func reported(_ deviceID: String, attributes: [AttributeReport], events: [EventRecord], priming: Bool) async {
        guard let plan = nodes[deviceID]?.plan else { return }
        for (key, value) in attributes.values { plan.updates[key]?(value) }
        // The priming report's events happened while Homeswift was away: listed, never pressed again.
        for record in events {
            nodes[deviceID]?.events.append(RecentEvent(time: Date(), endpoint: record.endpoint, name: Self.eventName(record), detail: Self.eventDetail(record)))
            guard !priming, record.cluster == SwitchCluster.id, let endpoint = nodes[deviceID]?.structure?.endpoint(record.endpoint) else { continue }
            let press = MatterAccessories.buttonEvent(record.event, data: record.data, endpoint: endpoint)
            if let press { plan.buttons[record.endpoint]?.characteristic(.programmableSwitchEvent).sendEvent(.int(press)) }
            guard let channel = nodes[deviceID]?.channels.first(where: { [$0.up, $0.down, $0.press].contains(record.endpoint) }) else { continue }
            // What its channels do: its Plugin Accessory Settings as they are now (`appliesAccessorySettingsLive`).
            let settings = DimmerSettings(context.accessorySettings(for: deviceID).plugin)
            dim(deviceID, channel: channel, settings: settings, record: record, press: press)
            if record.endpoint == channel.press {
                runScene(channel: channel, settings: settings, press: press)
                holdToDim(deviceID, channel: channel, settings: settings, event: record.event)
            }
        }
        if let count = nodes[deviceID]?.events.count, count > 40 { nodes[deviceID]?.events.removeFirst(count - 40) }
    }

    /// A channel button's double or long press, when the remote's settings give it a scene: the home's scene runs
    /// (`PluginContext.homeScenes`). The press still reaches HomeKit.
    private func runScene(channel: WheelChannel, settings dimmer: DimmerSettings, press: Int?) {
        let scene: String?
        switch press {
        case HAPConstants.ProgrammableSwitchEvent.doublePress: scene = dimmer.doubleScene[channel.number]
        case HAPConstants.ProgrammableSwitchEvent.longPress where dimmer.hold[channel.number] == nil: scene = dimmer.longScene[channel.number]
        default: scene = nil
        }
        guard let scene, let scenes = context.homeScenes else { return }
        let logger = logger
        tasks.add {
            do { try await scenes.run(scene) } catch { logger.warning("The remote's scene \(scene) did not run: \(error)") }
        }
    }

    /// A channel button held, when its channel's button dims when held: dims until it is let go.
    private func holdToDim(_ deviceID: String, channel: WheelChannel, settings: DimmerSettings, event: EventID) {
        guard let direction = settings.hold[channel.number], let controller = channelDimmer(deviceID, channel, settings) else { return }
        let step = settings.step
        switch event {
        case SwitchCluster.Event.longPress: tasks.add { await controller.hold(step: step, direction: direction) }
        case SwitchCluster.Event.longRelease: tasks.add { await controller.release() }
        default: break
        }
    }

    /// A wheel's turn or its button, on a channel that dims lights.
    private func dim(_ deviceID: String, channel: WheelChannel, settings: DimmerSettings, record: EventRecord, press: Int?) {
        guard settings.channel(channel.number) != nil,
              let action = nodes[deviceID]?.gestures.handle(record.event, data: record.data, endpoint: record.endpoint, channel: channel,
                                                            reversed: settings.reversed, press: press),
              let controller = channelDimmer(deviceID, channel, settings) else { return }
        let step = settings.step
        tasks.add { await controller.apply(action, step: step) }
    }

    /// Each remote channel's controller (its power state while it comes on), made again when its settings change.
    private var channelDimmers: [String: ChannelDimmer] = [:]

    /// A remote channel's controller, while its settings give it lights: made again when they change.
    private func channelDimmer(_ deviceID: String, _ channel: WheelChannel, _ settings: DimmerSettings) -> ChannelDimmer? {
        guard let targets = settings.channel(channel.number) else { return nil }
        let key = "\(deviceID)#\(channel.number)"
        if let controller = channelDimmers[key], controller.targets == targets { return controller }
        // Its settings changed: the old controller's hold, if any, stops; the lights no channel drives any more go.
        if let old = channelDimmers[key] { tasks.add { await old.release() } }
        let driven = Set(channelDimmers.filter { $0.key != key }.values.flatMap(\.targets.lights) + targets.lights)
        writers = writers.filter { driven.contains($0.key) }
        let context = context
        let controller = ChannelDimmer(targets: targets, writers: targets.lights.map(dimmer(for:))) { id in context.hostAccessory(id: id) }
        channelDimmers[key] = controller
        return controller
    }

    /// Each light's writer, shared by the channels that dim it.
    private var writers: [String: DimmerWriter] = [:]

    private func dimmer(for lightID: String) -> DimmerWriter {
        if let writer = writers[lightID] { return writer }
        let context = context
        let writer = DimmerWriter(lightID: lightID) { id in context.hostAccessory(id: id) }
        writers[lightID] = writer
        return writer
    }

    private func statusChanged(_ deviceID: String, _ status: MatterNodeLink.Status, error: String?) async {
        let unavailable = status == .unreachable
        for accessory in context.accessories where context.isAccessory(accessory.id, of: deviceID) {
            if accessory.isUnavailable != unavailable { accessory.isUnavailable = unavailable }
        }
        if unavailable { logger.warning("Matter device \(nodes[deviceID]?.record.name ?? deviceID) does not answer: \(error ?? "")") }
    }

    private func addressChanged(_ deviceID: String, _ address: NodeAddress) async {
        guard var node = nodes[deviceID], node.record.address != address else { return }
        node.record.address = address
        nodes[deviceID] = node
        try? recordFile(deviceID).save(node.record)
    }

    // MARK: - Names for the page

    static func eventName(_ record: EventRecord) -> String {
        guard record.cluster == SwitchCluster.id else { return String(format: "Event 0x%04X/0x%02X", record.cluster, record.event) }
        return switch record.event {
        case SwitchCluster.Event.initialPress: "Press"
        case SwitchCluster.Event.longPress: "Long press"
        case SwitchCluster.Event.shortRelease: "Release"
        case SwitchCluster.Event.longRelease: "Long release"
        case SwitchCluster.Event.multiPressOngoing: "Counting"
        case SwitchCluster.Event.multiPressComplete: "Presses"
        default: "Switch event \(record.event)"
        }
    }

    static func eventDetail(_ record: EventRecord) -> String? {
        guard record.cluster == SwitchCluster.id,
              [SwitchCluster.Event.multiPressOngoing, SwitchCluster.Event.multiPressComplete].contains(record.event),
              let count = record.data[1]?.uint else { return nil }
        return "\(count)"
    }

    // MARK: - Settings

    public func deviceKind(of deviceID: String) async -> String? {
        nodes[deviceID]?.record.kind ?? recordFile(deviceID).load()?.kind
    }

    /// A remote's dimming settings as it is made: lights and a power switch to choose per wheel channel it has (BILRESA's
    /// three), the step, the direction and the wait only with a wheel. nil until its structure was ever read: every field
    /// of its kind. The record keeps the channels from the last time (it reconnects after a restart).
    public func accessorySettingKeys(deviceID: String) async -> Set<String>? {
        guard let channels = (nodes[deviceID]?.record ?? recordFile(deviceID).load())?.channels else { return nil }
        return DimmerSettings.keys(channels: channels)
    }

    /// What a remote's channels drive, for the words of its settings: lights, shutters, or both.
    enum Drives { case lights, shutters, both }

    func drives(_ ids: [String]) -> Drives {
        var lights = false, shutters = false
        for id in ids {
            guard let accessory = context.hostAccessory(id: id) else { continue }
            if DimmerWriter.covering(in: accessory) != nil { shutters = true } else { lights = true }
        }
        return shutters ? (lights ? .both : .shutters) : .lights
    }

    /// The words of a remote's settings for what its channels drive (GLOSSARY: Plugin Accessory Settings): a shutter
    /// opens and closes where a light brightens and dims.
    public func accessorySettingWording(_ key: String, deviceID: String) async -> SettingWording? {
        let settings = DimmerSettings(context.accessorySettings(for: deviceID).plugin)
        switch DimmerSettings.parse(key) {
        case ("hold", let channel?)?:
            return switch drives(settings.lights[channel] ?? []) {
            case .lights: nil
            case .shutters: SettingWording(description: "What the channel's button does while held: runs the long press's scene, or moves the shutters until let go")
            case .both: SettingWording(description: "What the channel's button does while held: runs the long press's scene, or dims the lights and moves the shutters until let go")
            }
        case ("dimStep", nil)?, ("reverseWheel", nil)?:
            break
        default:
            return nil
        }
        switch (key, drives(settings.lights.values.flatMap { $0 })) {
        case ("dimStep", .shutters): return SettingWording(title: "Position per notch", description: "Percent of position one notch of the wheel moves the shutters")
        case ("dimStep", .both): return SettingWording(title: "Step per notch", description: "Percent one notch of the wheel moves a light's brightness or a shutter's position")
        case ("reverseWheel", .shutters): return SettingWording(description: "Turning the other way opens")
        case ("reverseWheel", .both): return SettingWording(description: "Turning the other way brightens and opens")
        default: return nil
        }
    }

    public func accessorySettingChoices(_ key: String, deviceID: String) async -> [SetupOption]? {
        guard case let (prefix, channel?)? = DimmerSettings.parse(key) else { return nil }
        let byName = { (a: Accessory, b: Accessory) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        switch prefix {
        case "hold":
            // Held, the button opens and closes a channel's shutters where it brightens and dims its lights.
            let words: (alternate: String, up: String, down: String) = switch drives(DimmerSettings(context.accessorySettings(for: deviceID).plugin).lights[channel] ?? []) {
            case .lights: ("Brightens, then dims, in turn", "Brightens", "Dims")
            case .shutters: ("Opens, then closes, in turn", "Opens", "Closes")
            case .both: ("Brightens and opens, then dims and closes, in turn", "Brightens and opens", "Dims and closes")
            }
            return [SetupOption("scene", label: "Runs the long press's scene", isWording: true), SetupOption("alternate", label: words.alternate, isWording: true),
                    SetupOption("up", label: words.up, isWording: true), SetupOption("down", label: words.down, isWording: true)]
        case "double", "long":
            // A press's scene: the home's, Homeswift's own and its hubs'.
            let scenes = await context.homeScenes?.list() ?? []
            return scenes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { SetupOption($0.id, label: $0.name, detail: $0.room, group: "Scenes") }
        case "power":
            // A channel's power: a switch or an outlet of the bridge, another plugin's (an eWeLink relay).
            let switches = context.hostAccessories.filter { accessory in
                !context.isAccessory(accessory.id, of: deviceID) && accessory.services.contains { $0.type == .switch || $0.type == .outlet }
            }.sorted(by: byName)
            return switches.map { accessory in
                SetupOption(accessory.id, label: accessory.name, group: accessory.services.contains { $0.type == .outlet } ? "Outlets" : "Switches")
            }
        case "light":
            // Lights to dim and shutters (window coverings) to move, whichever plugin has them.
            let lights = context.hostAccessories.filter { accessory in
                DimmerWriter.covering(in: accessory) != nil || accessory.services.contains { $0.type == .lightbulb }
            }.sorted(by: byName)
            return lights.map { accessory in
                let isBlind = DimmerWriter.covering(in: accessory) != nil
                let detail: String? = isBlind || accessory.services.contains { $0[.brightness] != nil } ? nil : "On and off only"
                return SetupOption(accessory.id, label: accessory.name, detail: detail, group: isBlind ? "Blinds" : "Lights")
            }
        default:
            return nil
        }
    }
}
