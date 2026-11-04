import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// TP-Link Kasa plugs, switches, dimmers, power strips and bulbs on the local network: found by a UDP broadcast on port
/// 9999 every `pollingInterval` (which is also the state poll), controlled over TCP 9999 (or UDP) with the Kasa "Smart
/// Home" protocol, energy read every `emeterPollingInterval`. No cloud, no account.
///
/// A block of `homebridge-tplink-smarthome` loads unchanged; written from the functional spec in
/// docs/clean-room/TPLinkSmarthome.md. Each device (or each outlet of a strip) is an accessory whose Device Id is its
/// `deviceId` (an outlet's full child id). See README.md in this directory.
public actor TPLinkSmarthomePlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        /// A host that also gets the discovery packet directly, for networks where broadcasts do not reach it.
        public struct Host: Decodable, Sendable, Equatable {
            public var host: String
            /// The port of the discovery packet only; a number or a numeric string (the Homebridge schema said string).
            public var port: Int?

            enum CodingKeys: String, CodingKey { case host, port }

            public init(host: String, port: Int? = nil) {
                self.host = host
                self.port = port
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                host = try container.decode(String.self, forKey: .host)
                if let number = try? container.decodeIfPresent(Int.self, forKey: .port) {
                    port = number
                } else if let text = try? container.decodeIfPresent(String.self, forKey: .port), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
                        throw DecodingError.dataCorruptedError(forKey: .port, in: container, debugDescription: "port must be a number")
                    }
                    port = number
                } else {
                    port = nil
                }
            }
        }

        public var name: String?
        /// The Eve energy characteristics on devices that meter; `true` by default.
        public var addCustomCharacteristics: Bool?
        /// Seconds between energy readings; 20 by default, 0 or less reads only when HomeKit asks.
        public var emeterPollingInterval: Int?
        /// Watts above which Outlet In Use is on; 0 by default.
        public var inUseThreshold: Double?
        /// Models shown as a Switch (a substring of the model); `["HS200", "HS210"]` by default.
        public var switchModels: [String]?
        /// The local port discovery binds; 0 lets the system choose.
        public var discoveryPort: Int?
        /// Where the discovery packet goes; `255.255.255.255` by default.
        public var broadcast: String?
        /// Seconds between discovery rounds, the state poll; 10 by default.
        public var pollingInterval: Int?
        /// `plug`, `bulb`; both by default, none filters nothing.
        public var deviceTypes: [String]?
        /// Allow-list of MAC patterns (`*`, `?`).
        public var macAddresses: [String]?
        /// Deny-list of MAC patterns.
        public var excludeMacAddresses: [String]?
        public var devices: [Host]?
        /// Seconds a command may take; 15 by default, 0 waits as long as the connection lasts.
        public var timeout: Int?
        /// `tcp` (the default) or `udp`, for commands; discovery is always UDP.
        public var transport: String?
        /// Milliseconds HomeKit's writes are gathered for; 100 by default.
        public var waitTimeUpdate: Int?
        /// Commands go to the port a device's discovery reply came from (a `devices` entry's `port`), not 9999.
        public var devicesUseDiscoveryPort: Bool?
    }

    /// What the plugin uses to reach devices; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any KasaTransport = KasaNetworkTransport()
        var bindDiscovery: @Sendable (_ port: Int) async throws -> any KasaDiscoverySocket = { port in
            try await UDPSocket.bind(port: port, reuseAddress: port != 0, broadcast: true)
        }
        /// Seconds become this (tests run the rounds in milliseconds).
        var second: Duration = .seconds(1)
        var identifyStep: Duration = .milliseconds(500)
        /// How long Setup's discovery listens on an instance that is not running.
        var discoveryWindow: Duration = .seconds(2)
    }

    public static let platform = "TplinkSmarthome"
    public static let name = "TP-Link Kasa"
    public static let icon: String? = "outlet"
    public static let summary: String? = "Kasa plugs, switches, power strips and bulbs on the local network"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    static let devicePort = 9999
    static let defaultPollingInterval = 10
    /// A round every second at most: 0 would broadcast without pause.
    static let minimumPollingInterval = 1
    static let defaultEnergyInterval = 20
    static let defaultSwitchModels = ["HS200", "HS210"]
    static let discoveryPayload = KasaRequest.sysinfo.json
    /// Rounds without a reply before a device shows No Response.
    static let offlineRounds = 3

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    let link: KasaLink
    let filter: KasaMACFilter
    private let tasks = TaskBag()
    private var logger: Logger { context.logger }

    /// The accessories, by Device Id.
    private(set) var units: [String: KasaUnit] = [:]
    /// Each light's Adaptive Lighting, kept here: the lightbulb holds it weakly.
    private(set) var adaptiveLighting: [String: AdaptiveLightingController] = [:]
    private var histories: [String: EveHistory] = [:]
    /// Every device a reply named, the ones left out included, for Setup.
    private(set) var seen: [String: DiscoveredDevice] = [:]
    private var lastSeenRound: [String: Int] = [:]
    private var offline: Set<String> = []
    /// Devices being added: a second reply meanwhile (the broadcast's and a `devices` entry's) does not add them again.
    private var adding: Set<String> = []
    private(set) var round = 0
    private(set) var isDiscovering = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        let timeout = configuration.timeout ?? 15
        link = KasaLink(
            transport: dependencies.transport, queues: KasaHostQueues(), udp: configuration.transport?.lowercased() == "udp",
            timeout: timeout > 0 ? dependencies.second * timeout : nil)
        filter = KasaMACFilter(allow: configuration.macAddresses, deny: configuration.excludeMacAddresses)
    }

    var pollingInterval: Duration { dependencies.second * max(configuration.pollingInterval ?? Self.defaultPollingInterval, Self.minimumPollingInterval) }
    var energyInterval: Duration? {
        let seconds = configuration.emeterPollingInterval ?? Self.defaultEnergyInterval
        return seconds > 0 ? dependencies.second * seconds : nil
    }
    var switchModels: [String] { configuration.switchModels ?? Self.defaultSwitchModels }
    var deviceTypes: Set<String> { Set((configuration.deviceTypes ?? ["bulb", "plug"]).map { $0.lowercased() }) }
    var window: Duration { .milliseconds(max(configuration.waitTimeUpdate ?? 100, 0)) }

    public func start() async throws {
        if let broadcast = configuration.broadcast, IPv4Network.parse(broadcast) == nil {
            logger.error("broadcast must be an IPv4 address, not \(broadcast): using 255.255.255.255")
        }
        tasks.add { [weak self] in await self?.runDiscovery() }
        if let interval = energyInterval {
            tasks.add { [weak self] in
                while !Task.isCancelled {
                    await self?.pollEnergy()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        // Let go, not disabled: a running schedule stays saved and resumes at the next start.
        adaptiveLighting.removeAll()
        histories.removeAll()
    }

    // MARK: Discovery

    var broadcastAddress: String {
        configuration.broadcast.flatMap { IPv4Network.parse($0) != nil ? $0 : nil } ?? "255.255.255.255"
    }

    /// Binds the discovery socket (again after a failure, with a growing pause), hears the replies and sends a round
    /// every `pollingInterval`.
    private func runDiscovery() async {
        let backoff = Backoff(initial: .seconds(2), maximum: .seconds(60), jitter: .proportional(0.2))
        var attempt = 0
        while !Task.isCancelled {
            let socket: any KasaDiscoverySocket
            do {
                socket = try await dependencies.bindDiscovery(configuration.discoveryPort ?? 0)
            } catch {
                if attempt == 0 { logger.error("Could not open the discovery socket on port \(configuration.discoveryPort ?? 0): \(error)") }
                try? await Task.sleep(for: backoff.delay(attempt: attempt))
                attempt += 1
                continue
            }
            attempt = 0
            isDiscovering = true
            logger.info("Looking for Kasa devices", metadata: ["broadcast": "\(broadcastAddress)"])
            let interval = pollingInterval
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await datagram in socket.datagrams {
                        await self?.handle(datagram.data, from: datagram.address)
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        await self?.sendRound(on: socket)
                        try? await Task.sleep(for: interval)
                    }
                }
                // The socket closed (or the plugin stopped): open another.
                await group.next()
                group.cancelAll()
            }
            isDiscovering = false
            await socket.close()
        }
    }

    /// A round (section 5.4): the devices silent for 3 rounds show No Response, then the packet goes to the broadcast
    /// address and to each of `devices`.
    func sendRound(on socket: any KasaDiscoverySocket) async {
        markOffline()
        let payload = Data(KasaCipher.encrypt(Self.discoveryPayload))
        do {
            try await socket.send(payload, to: broadcastAddress, port: Self.devicePort)
        } catch {
            if round == 0 { logger.error("Could not send the discovery broadcast to \(broadcastAddress): \(error)") }
        }
        for device in configuration.devices ?? [] {
            do {
                try await socket.send(payload, to: device.host, port: device.port ?? Self.devicePort)
            } catch {
                logger.debug("Could not send the discovery packet to \(device.host): \(error)")
            }
        }
        round += 1
    }

    private func markOffline() {
        for (id, seenRound) in lastSeenRound where !offline.contains(id) && round - seenRound >= Self.offlineRounds {
            offline.insert(id)
            seen[id]?.isReachable = false
            context.accessory(id: KasaAccessory.accessoryID(id))?.isUnavailable = true
            logger.info("Device offline", metadata: ["device": "\(seen[id]?.name ?? id)", "id": "\(id)"])
        }
    }

    /// A discovery reply (section 5.4): checked, filtered, then each device or outlet created or updated.
    func handle(_ data: Data, from address: String) async {
        guard let (sysinfo, targets, rejection) = remember(data, from: address) else { return }
        if let rejection {
            logger.debug("Filtered out", metadata: ["alias": "\(sysinfo.alias)", "id": "\(sysinfo.deviceID)", "mac": "\(sysinfo.mac)", "reason": "\(rejection)"])
            return
        }
        let port = commandPort(for: address)
        let presentation = KasaPresentation.of(sysinfo, switchModels: switchModels)
        for target in targets {
            lastSeenRound[target.id] = round
            if offline.remove(target.id) != nil {
                context.accessory(id: KasaAccessory.accessoryID(target.id))?.isUnavailable = false
                logger.info("Device online again", metadata: ["device": "\(target.name)"])
            }
            if let unit = units[target.id] {
                await unit.update(sysinfo, host: address, port: port)
                continue
            }
            // An Excluded device is not polled (the runtime would not add it anyway); one being added is not added twice.
            guard !context.isExcluded(target.id), adding.insert(target.id).inserted else { continue }
            logger.info(
                "Device first online",
                metadata: ["alias": "\(target.name)", "kind": "\(sysinfo.kind.rawValue)", "id": "\(target.id)", "host": "\(address)", "port": "\(port)"])
            await add(id: target.id, childID: target.childID, presentation: presentation, sysinfo: sysinfo, host: address, port: port)
            adding.remove(target.id)
        }
    }

    /// A reply's devices (each outlet of a strip, else the device), listed for Setup with why the MAC lists leave them
    /// out; nil for a reply that is not a device's or of a type `deviceTypes` leaves out.
    @discardableResult
    private func remember(_ data: Data, from address: String) -> (KasaSysinfo, [(id: String, childID: String?, name: String)], String?)? {
        guard let sysinfo = KasaSysinfo.discoveryReply(data) else {
            logger.debug("Invalid discovery reply", metadata: ["from": "\(address)"])
            return nil
        }
        let types = deviceTypes
        guard types.isEmpty || types.contains(sysinfo.kind.rawValue) else {
            logger.debug("Filtered out by deviceTypes", metadata: ["alias": "\(sysinfo.alias)", "kind": "\(sysinfo.kind.rawValue)"])
            return nil
        }
        guard !sysinfo.deviceID.isEmpty else {
            logger.error("A device at \(address) answered without a device id")
            return nil
        }
        let rejection = filter.rejection(of: sysinfo.mac)
        let kind = KasaPresentation.of(sysinfo, switchModels: switchModels).deviceKind
        let targets: [(id: String, childID: String?, name: String)] = sysinfo.children.map { children in
            children.map { ($0.id, $0.id, $0.alias) }
        } ?? [(sysinfo.deviceID, nil, sysinfo.alias)]
        for target in targets {
            var device = DiscoveredDevice(
                deviceID: target.id, name: target.name, model: sysinfo.model, address: address, isSetUp: rejection == nil,
                excludedBySettings: rejection != nil, kind: kind)
            device.isReachable = !offline.contains(target.id) || rejection != nil
            seen[target.id] = device
        }
        return (sysinfo, targets, rejection)
    }

    /// 9999, or with `devicesUseDiscoveryPort` the port of the `devices` entry at that address.
    private func commandPort(for address: String) -> Int {
        guard configuration.devicesUseDiscoveryPort == true else { return Self.devicePort }
        return configuration.devices?.first { $0.host == address }?.port ?? Self.devicePort
    }

    private func add(id: String, childID: String?, presentation: KasaPresentation, sysinfo: KasaSysinfo, host: String, port: Int) async {
        let options = KasaUnit.Options(
            inUseThreshold: inUseThreshold(for: id), window: window, identifyStep: dependencies.identifyStep,
            settling: max(dependencies.second * 3, pollingInterval / 2))
        let unit = KasaUnit(id: id, childID: childID, presentation: presentation, sysinfo: sysinfo, host: host, port: port, link: link, options: options, logger: logger)
        let built = await KasaAccessory.make(
            unit: unit,
            options: .init(addCustomCharacteristics: configuration.addCustomCharacteristics ?? true, historyDirectory: context.storageDirectory, refreshEnergyOnRead: energyInterval == nil))
        var lighting: AdaptiveLightingController?
        if let lightbulb = built.lightbulb {
            lighting = context.adaptiveLighting(for: lightbulb, accessoryID: built.accessory.id)
        }
        await unit.attach(built.services, adaptiveLighting: lighting, history: built.history)
        do {
            try context.add(built.accessory)
        } catch {
            logger.error("Could not add \(built.accessory.name) to the bridge: \(error)")
            return
        }
        units[id] = unit
        adaptiveLighting[id] = lighting
        histories[id] = built.history
        logger.info("Added accessory", metadata: ["alias": "\(built.accessory.name)", "kind": "\(presentation.rawValue)", "id": "\(id)"])
        if sysinfo.supportsEnergy, energyInterval != nil { Task { await unit.refreshEnergy() } }
    }

    // MARK: Energy

    /// One reading of each metering accessory: hosts in parallel, a strip's outlets one after another.
    func pollEnergy() async {
        var byHost: [String: [KasaUnit]] = [:]
        for unit in units.values where await unit.supportsEnergy {
            byHost[await unit.host, default: []].append(unit)
        }
        await withTaskGroup(of: Void.self) { group in
            for units in byHost.values {
                group.addTask {
                    for unit in units { await unit.refreshEnergy() }
                }
            }
        }
    }

    // MARK: Setup

    /// The devices replies named: a running instance answers from what it heard; one made only for Setup listens for
    /// `discoveryWindow` after one round.
    public func discover() async throws -> [DiscoveredDevice] {
        if !isDiscovering {
            let socket = try await dependencies.bindDiscovery(0)
            let listening = Task { [weak self] in
                for await datagram in socket.datagrams { await self?.remember(datagram.data, from: datagram.address) }
            }
            await sendRound(on: socket)
            try? await Task.sleep(for: dependencies.discoveryWindow)
            listening.cancel()
            await socket.close()
        }
        return seen.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    // MARK: Settings

    // The Plugin Settings are the Homebridge plugin's keys as they are; the MAC lists are patterns, not Device Ids, so
    // they stay where they are (`canonicalSettings` is the default, the block unchanged). Accessory Settings are the
    // Core ones only.
    public func deviceKind(of deviceID: String) async -> String? {
        units[deviceID]?.presentation.deviceKind ?? seen[deviceID]?.kind
    }
}
