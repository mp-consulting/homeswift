import Foundation
import HomeswiftNetwork

/// An ICE candidate as SDP carries it (RFC 8839 section 5.1):
/// `candidate:<foundation> <component> <transport> <priority> <address> <port> typ <type> [raddr <a> rport <p>] …`.
public struct ICECandidate: Sendable, Equatable {
    public enum Kind: String, Sendable { case host, srflx, prflx, relay }

    public var foundation: String
    public var component: Int
    public var transport: String
    public var priority: UInt32
    public var address: String
    public var port: Int
    public var kind: Kind
    public var relatedAddress: String?
    public var relatedPort: Int?

    public init(
        foundation: String, component: Int = 1, transport: String = "udp", priority: UInt32, address: String, port: Int, kind: Kind,
        relatedAddress: String? = nil, relatedPort: Int? = nil
    ) {
        self.foundation = foundation
        self.component = component
        self.transport = transport
        self.priority = priority
        self.address = address
        self.port = port
        self.kind = kind
        self.relatedAddress = relatedAddress
        self.relatedPort = relatedPort
    }

    /// RFC 8445 section 5.1.2.1: (2^24 × type preference) + (2^8 × local preference) + (256 − component).
    public static func priority(kind: Kind, localPreference: UInt32 = 65535, component: Int = 1) -> UInt32 {
        let typePreference: UInt32 = switch kind {
        case .host: 126
        case .prflx: 110
        case .srflx: 100
        case .relay: 0
        }
        return typePreference << 24 | (localPreference & 0xffff) << 8 | UInt32(256 - component)
    }

    /// Reads the attribute's value, with or without `a=` and `candidate:`; nil for what is not a UDP or TCP candidate.
    public init?(sdp text: String) {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("a=") { line.removeFirst(2) }
        if line.hasPrefix("candidate:") { line.removeFirst("candidate:".count) }
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 8, parts[6] == "typ", let component = Int(parts[1]), let priority = UInt32(parts[3]),
              let port = Int(parts[5]), let kind = Kind(rawValue: parts[7]) else { return nil }
        self.init(foundation: parts[0], component: component, transport: parts[2].lowercased(), priority: priority, address: parts[4], port: port, kind: kind)
        var index = 8
        while index + 1 < parts.count {
            switch parts[index] {
            case "raddr": relatedAddress = parts[index + 1]
            case "rport": relatedPort = Int(parts[index + 1])
            default: break
            }
            index += 2
        }
    }

    /// The attribute's value (without `a=`).
    public var sdp: String {
        var text = "candidate:\(foundation) \(component) \(transport) \(priority) \(address) \(port) typ \(kind.rawValue)"
        if let relatedAddress, let relatedPort { text += " raddr \(relatedAddress) rport \(relatedPort)" }
        return text
    }
}

/// The ICE credentials of one side of a session.
public struct ICECredentials: Sendable, Equatable {
    public var ufrag: String
    public var password: String

    public init(ufrag: String, password: String) {
        self.ufrag = ufrag
        self.password = password
    }

    /// Random credentials of the lengths RFC 8839 asks (4 and 22 characters at least) from its ice-char set.
    public static func random() -> ICECredentials {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        func text(_ count: Int) -> String { String((0..<count).map { _ in characters.randomElement()! }) }
        return ICECredentials(ufrag: text(8), password: text(24))
    }
}

/// One ICE session for one component (RTP and RTCP multiplexed, no BUNDLE across media), full ICE as the controlling
/// agent, as a WebRTC client that sends the offer is (RFC 8445): it answers the peer's checks, checks each remote
/// candidate (trickled ones too) in priority order and nominates the first pair that succeeds (aggressive
/// nomination, USE-CANDIDATE on every check). Datagrams that are not STUN go to `received` once a pair is selected.
public actor ICEAgent {
    public struct Pair: Sendable, Hashable {
        public var host: String
        public var port: Int
    }

    public let local: ICECredentials
    public private(set) var remote: ICECredentials?
    public private(set) var selected: Pair?
    /// Media and DTLS from the selected pair (the bytes, in order).
    public nonisolated let received: AsyncStream<[UInt8]>
    private let receivedContinuation: AsyncStream<[UInt8]>.Continuation
    private let socket: UDPSocket
    private let tieBreaker: [UInt8]
    private var candidates: [ICECandidate] = []
    private var pending: [[UInt8]: Pair] = [:]
    /// Addresses that proved they hold the session's credentials (a check in either direction): their DTLS and media
    /// are taken before this side nominates, as the peer may start its handshake first.
    private var validated: Set<Pair> = []
    private var reader: Task<Void, Never>?
    private var checker: Task<Void, Never>?
    private var selectedWaiters: [CheckedContinuation<Pair?, Never>] = []
    let checkInterval: Duration
    let attempts: Int

    /// An agent on a socket the caller bound (port 0 for any) with `senderPorts: true`, so each datagram says where it
    /// came from: its host candidate is the socket's port on each address the caller lists.
    public init(socket: UDPSocket, credentials: ICECredentials = .random(), checkInterval: Duration = .milliseconds(50), attempts: Int = 100) {
        self.socket = socket
        local = credentials
        tieBreaker = (0..<8).map { _ in UInt8.random(in: 0...255) }
        self.checkInterval = checkInterval
        self.attempts = attempts
        (received, receivedContinuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    /// Host candidates for these addresses on the socket's port.
    public func hostCandidates(addresses: [String]) -> [ICECandidate] {
        guard let port = socket.localPort else { return [] }
        return addresses.enumerated().map { index, address in
            ICECandidate(foundation: String(index + 1), priority: ICECandidate.priority(kind: .host, localPreference: UInt32(65535 - index)),
                         address: address, port: port, kind: .host)
        }
    }

    /// Starts reading the socket and checking: call once the peer's credentials are known.
    public func start(remote credentials: ICECredentials) {
        remote = credentials
        guard reader == nil else { return }
        let stream = socket.datagramsWithPorts
        reader = Task { [weak self] in
            for await datagram in stream { await self?.handle(Array(datagram.data), from: Pair(host: datagram.address, port: datagram.port)) }
        }
        checker = Task { [weak self] in await self?.check() }
    }

    /// A remote candidate, from the answer or trickled; UDP only.
    public func add(remote candidate: ICECandidate) {
        guard candidate.transport == "udp", candidate.component == 1, !candidates.contains(candidate) else { return }
        candidates.append(candidate)
        candidates.sort { $0.priority > $1.priority }
    }

    /// The selected pair, once a check succeeded; nil when the agent stops first.
    public func waitForSelection() async -> Pair? {
        if let selected { return selected }
        return await withCheckedContinuation { selectedWaiters.append($0) }
    }

    /// Sends bytes (DTLS, SRTP, SRTCP) on the selected pair.
    public func send(_ bytes: [UInt8]) async throws {
        guard let selected else { throw ICEError.notConnected }
        try await socket.send(Data(bytes), to: selected.host, port: selected.port)
    }

    public func stop() async {
        reader?.cancel()
        checker?.cancel()
        receivedContinuation.finish()
        for waiter in selectedWaiters { waiter.resume(returning: nil) }
        selectedWaiters = []
        await socket.close()
    }

    // MARK: Checks

    private func check() async {
        for _ in 0..<attempts {
            guard selected == nil, !Task.isCancelled else { return }
            if let remote {
                for candidate in candidates {
                    await sendCheck(to: Pair(host: candidate.address, port: candidate.port), remote: remote)
                }
            }
            try? await Task.sleep(for: checkInterval)
        }
        if selected == nil {
            for waiter in selectedWaiters { waiter.resume(returning: nil) }
            selectedWaiters = []
        }
    }

    private func sendCheck(to pair: Pair, remote: ICECredentials) async {
        let message = STUNMessage(.bindingRequest, attributes: [
            .init(.username, Array("\(remote.ufrag):\(local.ufrag)".utf8)),
            .init(.priority, STUNMessage.be32(ICECandidate.priority(kind: .prflx))),
            .init(.iceControlling, tieBreaker),
            .init(.useCandidate, []),
        ])
        pending[message.transactionID] = pair
        try? await socket.send(Data(message.encode(integrityKey: Array(remote.password.utf8))), to: pair.host, port: pair.port)
    }

    private func handle(_ bytes: [UInt8], from source: Pair) async {
        guard STUNMessage.isSTUN(bytes) else {
            if selected == source || validated.contains(source) { receivedContinuation.yield(bytes) }
            return
        }
        guard STUNMessage.verifyFingerprint(bytes), let message = STUNMessage.decode(bytes) else { return }
        switch message.kind {
        case .bindingRequest?:
            // The peer's check: USERNAME is "<our ufrag>:<theirs>", signed with our password.
            guard let username = message.attribute(.username).map({ String(decoding: $0, as: UTF8.self) }),
                  username.hasPrefix(local.ufrag + ":"), STUNMessage.verifyIntegrity(bytes, key: Array(local.password.utf8)),
                  let mapped = STUNMessage.xorAddress(host: source.host, port: source.port, transactionID: message.transactionID) else { return }
            let response = STUNMessage(.bindingSuccess, transactionID: message.transactionID, attributes: [.init(.xorMappedAddress, mapped)])
            validated.insert(source)
            try? await socket.send(Data(response.encode(integrityKey: Array(local.password.utf8))), to: source.host, port: source.port)
            // A check from a candidate we did not know is a peer-reflexive one.
            if !candidates.contains(where: { $0.address == source.host && $0.port == source.port }) {
                add(remote: ICECandidate(foundation: "prflx", priority: ICECandidate.priority(kind: .prflx), address: source.host, port: source.port, kind: .prflx))
            }
        case .bindingSuccess?:
            guard let pair = pending.removeValue(forKey: message.transactionID), pair == source, let remote,
                  STUNMessage.verifyIntegrity(bytes, key: Array(remote.password.utf8)), selected == nil else { return }
            validated.insert(pair)
            selected = pair
            for waiter in selectedWaiters { waiter.resume(returning: pair) }
            selectedWaiters = []
        default:
            break
        }
    }
}

public enum ICEError: Error, Equatable {
    case notConnected
}
