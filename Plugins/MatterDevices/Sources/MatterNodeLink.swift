import Foundation
import Homeswift
import HomeswiftPlugin
import HomeswiftNetwork
import Logging
import Matter

/// One commissioned node: finds it by its operational name, opens a CASE session, reads what it is and keeps a
/// subscription to what its accessories show (Core §8.5), opening it again when the node stops reporting. A sleepy
/// device (a battery remote) answers only when it polls its parent; the message layer retransmits for it from its idle
/// interval (Core §4.12.8).
actor MatterNodeLink {
    enum Status: String, Sendable {
        case connecting, connected, unreachable
    }

    /// What the link reports to its plugin, on the link's task, one after the other.
    struct Handlers: Sendable {
        /// The node's structure, once read; answers the attributes to subscribe to and whether to take its Switch events.
        var structure: @Sendable (NodeStructure) async -> (attributes: [ConcreteAttribute], events: Bool)
        /// A report: the priming one first (its events happened before: they are not acted on), then each change.
        var report: @Sendable (_ attributes: [AttributeReport], _ events: [EventRecord], _ priming: Bool) async -> Void
        var status: @Sendable (Status, _ error: String?) async -> Void
        /// Where it answered, kept for when DNS-SD does not say.
        var address: @Sendable (NodeAddress) async -> Void
    }

    struct Timing: Sendable {
        var lookup: Duration = .seconds(10)
        var establish: Duration = .seconds(60)
        var firstRetry: Duration = .seconds(5)
        var longestRetry: Duration = .seconds(120)
        /// How long past its max interval a silent subscription is given before it is opened again.
        var grace: Duration = .seconds(30)
        var maxInterval: UInt16 = 60
    }

    /// How a link reaches a node: its discovery, where an address goes on the message layer, and the timings.
    struct Network: Sendable {
        var discovery: any MatterDiscovery
        var peer: @Sendable (NodeAddress) throws -> PeerAddress
        var timing: Timing
        /// The Thread network's prefix when the host has no route to an address (`HostRoutes`).
        var missingRoute: @Sendable (String) -> String? = { _ in nil }
    }

    let deviceID: String
    let nodeID: NodeID
    let commissioner: Commissioner
    let network: Network
    let handlers: Handlers
    let logger: Logger
    var timing: Timing { network.timing }

    private(set) var status: Status = .connecting
    private(set) var lastError: String?
    private(set) var address: NodeAddress?
    private(set) var connectedSince: Date?
    private var session: UInt16?
    /// One past the last event delivered: a new subscription starts there (Core §10.6.6).
    private var eventMin: UInt64?
    private var lastHeard = ContinuousClock.now
    private var task: Task<Void, Never>?
    /// Set to open the session and subscription again now (an address change, a person's Reconnect).
    private var wake: CheckedContinuation<Void, Never>?
    private var reconnectRequested = false
    private var subscriptionID: UInt32?
    /// Attempts that failed in a row since the link was last connected.
    private var failures = 0

    init(deviceID: String, nodeID: NodeID, commissioner: Commissioner, network: Network, address: NodeAddress?, handlers: Handlers, logger: Logger) {
        self.deviceID = deviceID
        self.nodeID = nodeID
        self.commissioner = commissioner
        self.network = network
        self.address = address
        self.handlers = handlers
        self.logger = logger
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        cancelWake()
    }

    /// How it stands, for the page, in one call.
    var snapshot: (status: Status, error: String?, address: NodeAddress?, since: Date?) { (status, lastError, address, connectedSince) }

    /// Opens the session again now, as when the node stopped answering.
    func reconnect() async {
        reconnectRequested = true
        session = nil
        cancelWake()
        await endSubscription()
    }

    // MARK: - The connection

    private func run() async {
        while !Task.isCancelled {
            do {
                try await connectAndFollow()
            } catch is CancellationError {
                return
            } catch where reconnectRequested {
                // A reconnect asked for: open the session again at once, without counting a failure.
                reconnectRequested = false
                continue
            } catch {
                failures += 1
                lastError = Self.describe(error)
                // A Thread device the host has no route to: the host's routes to blame, as Setup says.
                if let address, let prefix = network.missingRoute(address.host) {
                    lastError = "this host has no route to its Thread network (\(prefix)): add one through a Thread border router (the plugin's README, Network)"
                }
                session = nil
                connectedSince = nil
                // One failed attempt may be a sleepy device between polls: say it does not answer from the second.
                let next: Status = failures >= 2 ? .unreachable : .connecting
                if status != next || failures == 2 {
                    status = next
                    await handlers.status(next, lastError)
                }
                logger.info("Matter node \(deviceID) did not answer: \(lastError ?? "")", metadata: ["attempt": "\(failures)"])
            }
            guard !Task.isCancelled else { return }
            await pause(retryDelay(failures))
        }
    }

    /// The wait before trying again: doubling from the first retry to the longest, with a little jitter.
    func retryDelay(_ failures: Int) -> Duration {
        guard failures > 0 else { return .zero }
        return Backoff(initial: timing.firstRetry, maximum: timing.longestRetry, jitter: .proportional(0.1)).delay(attempt: failures - 1)
    }

    /// Sleeps, or wakes early for a reconnect.
    private func pause(_ duration: Duration) async {
        guard duration > .zero else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: duration) }
            group.addTask { await self.waitForWake() }
            await group.next()
            group.cancelAll()
            self.cancelWake()
        }
    }

    private func waitForWake() async {
        await withCheckedContinuation { continuation in
            if Task.isCancelled { continuation.resume(); return }
            wake?.resume()
            wake = continuation
        }
    }

    private func cancelWake() {
        wake?.resume()
        wake = nil
    }

    private func connectAndFollow() async throws {
        let (reached, session) = try await Self.openSession(nodeID: nodeID, commissioner: commissioner, network: network, known: address)
        if reached != address { await handlers.address(reached) }
        address = reached
        self.session = session
        lastHeard = .now

        let (structureReports, _) = try await commissioner.client.read(NodeStructure.paths, session: session)
        let structure = NodeStructure(reports: structureReports)
        let (attributes, events) = await handlers.structure(structure)
        // Something to keep the subscription alive and reported on, for a node with nothing Homeswift shows.
        let paths = attributes.isEmpty
            ? [AttributePath(endpoint: 0, cluster: BasicInformationCluster.id, attribute: BasicInformationCluster.Attribute.softwareVersionString)]
            : attributes.map(\.path)
        // Urgent (EventPathIB's IsUrgent, Core §10.6.8): a press is reported at once, not at the subscription's minimum interval.
        let eventPaths = events ? [EventPath(cluster: SwitchCluster.id, isUrgent: true)] : []
        // KeepSubscriptions false: the node drops this controller's earlier subscriptions (a run before a restart) rather
        // than keep reporting to ids nobody follows (Core §8.5.2.3).
        let (id, maxInterval, reports) = try await commissioner.client.subscribe(
            paths, events: eventPaths, eventMin: eventMin, minInterval: 0, maxInterval: max(timing.maxInterval, 1), keepSubscriptions: false,
            session: session)
        subscriptionID = id
        defer { Task { [client = commissioner.client] in await client.cancelSubscription(id) } }

        // Connected once the priming report is in and handled: from then on what the node reports is acted on, so
        // whatever waits for the link (a remote's next press) is not taken for the priming report's past.
        try await follow(reports, maxInterval: maxInterval) { [weak self] in
            await self?.connected(at: reached.description, maxInterval: maxInterval)
        }
    }

    private func connected(at address: String, maxInterval: UInt16) async {
        status = .connected
        failures = 0
        // A reconnect asked for while this session was being opened is done: it is not the next failure's.
        reconnectRequested = false
        lastError = nil
        connectedSince = Date()
        await handlers.status(.connected, nil)
        logger.info("Matter node \(deviceID) connected", metadata: ["address": "\(address)", "maxInterval": "\(maxInterval)"])
    }

    /// Reads the subscription's reports until it goes silent for longer than the node promised (its max interval and
    /// a grace), or the link is asked to reconnect: either ends the subscription, which ends its stream.
    private func follow(_ reports: AsyncStream<InteractionClient.SubscriptionReport>, maxInterval: UInt16,
                        primed: () async -> Void) async throws {
        // A subscriber SHALL end a subscription that sent no report within its max interval (Core §8.5); as
        // connectedhomeip does, the time the node's own retransmissions take to deliver a report is added.
        let deadline = Duration.seconds(Int(maxInterval)) + max(timing.grace, Self.deliveryTime(address?.parameters ?? .default))
        let check = min(Duration.seconds(5), deadline / 4)
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: check)
                guard let self, !Task.isCancelled else { return }
                if await self.isSilent(for: deadline) {
                    await self.endSubscription()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        var priming = true
        for await report in reports {
            lastHeard = .now
            let records = report.events.compactMap { if case .data(let record) = $0 { record } else { nil } }
            if let last = records.map(\.number).max(), last < .max { eventMin = max(eventMin ?? 0, last + 1) }
            await handlers.report(report.attributes, records, priming)
            if priming { await primed() }
            priming = false
        }
        if Task.isCancelled { throw CancellationError() }
        throw MatterLinkError(reconnectRequested ? "reconnecting" : "no report for \(deadline)")
    }

    /// How long MRP takes, at most, to get a message to a peer with these intervals (Core §4.12.2.1): every
    /// transmission's backoff from its idle interval, with the margin, the backoff and the most jitter.
    static func deliveryTime(_ parameters: SessionParameters) -> Duration {
        let reliability = ReliabilityParameters()
        let factors = (0..<reliability.maxTransmissions).map { attempt in
            reliability.backoffMargin * pow(reliability.backoffBase, Double(max(0, attempt - reliability.backoffThreshold))) * (1 + reliability.backoffJitter)
        }
        return parameters.idleInterval * factors.reduce(0, +)
    }

    private func isSilent(for deadline: Duration) -> Bool { ContinuousClock.now - lastHeard > deadline }

    /// Ends the subscription the link follows: its stream finishes, and the link opens a new one.
    private func endSubscription() async {
        guard let id = subscriptionID else { return }
        subscriptionID = nil
        await commissioner.client.cancelSubscription(id)
    }

    // MARK: - Commands

    /// Invokes a command over the open session; No Response (`serviceCommunicationFailure`) while there is none or the
    /// node refuses it.
    func invoke(endpoint: EndpointNumber, cluster: ClusterID, command: CommandID, fields: [TLVElement]) async throws {
        guard let session else { throw HAPStatusError(.serviceCommunicationFailure) }
        let result: InvokeResult
        do {
            result = try await commissioner.client.invoke(CommandPath(endpoint: endpoint, cluster: cluster, command: command),
                                                          fields: .structure(fields), session: session)
        } catch {
            logger.warning("Matter node \(deviceID) did not take a command: \(Self.describe(error))")
            // The session may be gone (the node restarted): open it again rather than wait for the subscription to lapse.
            await reconnect()
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        if case .status(let status) = result, status.status != .success {
            logger.warning("Matter node \(deviceID) refused a command", metadata: ["status": "\(status.status)"])
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    /// Reads attributes over the open session: each one's value, a path the node refused or does not have left out.
    func read(_ paths: [AttributePath]) async throws -> [ConcreteAttribute: TLVValue] {
        guard let session else { throw MatterLinkError("not connected") }
        let (reports, _) = try await commissioner.client.read(paths, session: session)
        var values: [ConcreteAttribute: TLVValue] = [:]
        for case let .data(path, _, value) in reports {
            guard let endpoint = path.endpoint, let cluster = path.cluster, let attribute = path.attribute else { continue }
            values[ConcreteAttribute(endpoint, cluster, attribute)] = value
        }
        return values
    }

    /// Writes attributes over the open session; throws with the first one the node refused.
    func write(_ values: [(AttributePath, TLVValue)]) async throws {
        guard let session else { throw MatterLinkError("not connected") }
        let refused = try await commissioner.client.write(values, session: session).first { $0.1.status != .success }
        if let (path, status) = refused { throw MatterLinkError("refused \(path): \(status.status)") }
    }

    /// Opens a CASE session with a node of the commissioner's fabric: where DNS-SD says it is now (its operational
    /// instance, Core §4.3.2.1), else where it answered last; with its record's MRP intervals for a sleepy device.
    static func openSession(nodeID: NodeID, commissioner: Commissioner, network: Network, known: NodeAddress?) async throws -> (NodeAddress, UInt16) {
        let instance = OperationalInstanceName.make(compressedFabricID: commissioner.compressedFabricID, nodeID: nodeID)
        guard let address = await network.discovery.operational(instance: instance, timeout: network.timing.lookup) ?? known else {
            throw MatterLinkError("not found on the network (\(instance))")
        }
        let peer = try network.peer(address)
        let timeout = network.timing.establish
        let session = try await withTimeout(timeout, error: { MatterLinkError("no CASE session within \(timeout)") }) {
            try await CASE.establish(with: peer, peerNodeID: nodeID, identity: await commissioner.identity, layer: commissioner.layer,
                                     peerParameters: address.parameters)
        }
        return (address, session.localSessionID)
    }

    /// Removes this controller's fabric from the node: it forgets Homeswift and keeps every other controller.
    static func removeFabric(nodeID: NodeID, commissioner: Commissioner, network: Network, known: NodeAddress?) async throws {
        let (_, session) = try await openSession(nodeID: nodeID, commissioner: commissioner, network: network, known: known)
        try await withTimeout(network.timing.establish) { try await commissioner.removeFabric(session: session) }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as MatterLinkError: error.description
        case let error as TimeoutError: error.description
        case ExchangeError.notAcknowledged: "it did not acknowledge"
        case ExchangeError.timeout: "it did not answer in time"
        default: String(describing: error)
        }
    }
}

struct MatterLinkError: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) { self.description = description }
}
