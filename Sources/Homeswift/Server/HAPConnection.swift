import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// One controller's TCP connection.
///
/// Everything that arrives (bytes from the socket, events to push) goes through one queue that a
/// single task drains, so requests, responses and events stay in order and the session counters
/// never race. Only the controller identity and subscriptions are read from other threads.
final class HAPConnection: @unchecked Sendable {
    enum Work {
        case data(ByteBuffer)
        case event(HTTPResponse)
    }

    /// What to do after a response has gone out.
    enum After {
        case none
        case startSession(SecureSession)
        case closeControllers(Set<String>?)
    }

    struct Shared {
        var controllerID: String?
        var isAdmin = false
        var subscriptions: Set<CharacteristicKey> = []
        var closeHandlers: [@Sendable () -> Void] = []
        var closed = false
    }

    final class InboundHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<Work>.Continuation

        init(continuation: AsyncStream<Work>.Continuation) { self.continuation = continuation }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            continuation.yield(.data(unwrapInboundIn(data)))
        }

        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }

    let channel: any Channel
    let server: HAPServer
    let shared = NIOLockedValueBox(Shared())
    let inboundHandler: InboundHandler
    private let stream: AsyncStream<Work>
    private let continuation: AsyncStream<Work>.Continuation

    // Only touched by the task in `run()`.
    private var raw = Data()
    private var plain = Data()
    private(set) var session: SecureSession?
    var pairSetup: PairSetupState?
    var pairVerify: PairVerifyState?
    var timedWrite: (pid: UInt64, expires: ContinuousClock.Instant)?

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var controllerID: String? { shared.withLockedValue { $0.controllerID } }
    var isAdmin: Bool { shared.withLockedValue { $0.isAdmin } }
    var isVerified: Bool { session != nil }

    init(channel: any Channel, server: HAPServer) {
        self.channel = channel
        self.server = server
        (stream, continuation) = AsyncStream.makeStream(of: Work.self)
        inboundHandler = InboundHandler(continuation: continuation)
    }

    func run() async {
        server.logger.debug("Connection opened", metadata: ["remote": "\(channel.remoteAddress.map { "\($0)" } ?? "?")"])
        for await work in stream {
            switch work {
            case .data(let buffer):
                raw.append(contentsOf: buffer.readableBytesView)
                await processInbound()
            case .event(let response):
                guard session != nil else { continue }
                write(response.serialized(protocol: "EVENT/1.0"))
            }
        }
        server.unregister(self)
        let handlers = shared.withLockedValue { shared in
            shared.closed = true
            defer { shared.closeHandlers = [] }
            return shared.closeHandlers
        }
        for handler in handlers { handler() }
        server.logger.debug("Connection closed", metadata: ["controller": "\(controllerID ?? "-")"])
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Runs `handler` once the connection has closed (at once when it already has): camera streams and data
    /// streams end with the controller connection that set them up.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let closed = shared.withLockedValue { shared in
            if !shared.closed { shared.closeHandlers.append(handler) }
            return shared.closed
        }
        if closed { handler() }
    }

    /// What handlers may know of this connection while they serve one of its requests.
    var requestContext: HAPRequestContext {
        HAPRequestContext(
            connectionID: id, controllerID: controllerID,
            localAddress: Self.plainAddress(channel.localAddress?.ipAddress), remoteAddress: Self.plainAddress(channel.remoteAddress?.ipAddress),
            sharedSecret: session?.sharedSecret, connection: self)
    }

    /// An IPv4 client of the dual-stack socket shows as `::ffff:a.b.c.d`; streams want the IPv4 address.
    static func plainAddress(_ address: String?) -> String? {
        guard let address else { return nil }
        if address.lowercased().hasPrefix("::ffff:"), address.contains(".") { return String(address.dropFirst(7)) }
        return address
    }

    func sendEvent(_ response: HTTPResponse) {
        continuation.yield(.event(response))
    }

    func isSubscribed(to key: CharacteristicKey) -> Bool {
        shared.withLockedValue { $0.subscriptions.contains(key) }
    }

    func setSubscribed(_ subscribed: Bool, to key: CharacteristicKey) {
        shared.withLockedValue {
            if subscribed { $0.subscriptions.insert(key) } else { $0.subscriptions.remove(key) }
        }
    }

    func setController(_ identifier: String, isAdmin: Bool) {
        shared.withLockedValue {
            $0.controllerID = identifier
            $0.isAdmin = isAdmin
        }
    }

    private func processInbound() async {
        do {
            try drainRaw()
            while let request = try HTTPRequest.parse(&plain) {
                let (response, after) = await handle(request)
                write(response.serialized())
                switch after {
                case .none:
                    break
                case .startSession(let newSession):
                    session = newSession
                    // Anything already buffered after the verify request is encrypted.
                    raw = plain + raw
                    plain = Data()
                    try drainRaw()
                case .closeControllers(let controllers):
                    server.closeConnections(controllers: controllers)
                }
            }
        } catch {
            server.logger.debug("Dropping connection", metadata: ["error": "\(error)"])
            close()
        }
    }

    private func drainRaw() throws {
        if session != nil {
            plain.append(try session!.decrypt(&raw))
        } else {
            plain.append(raw)
            raw = Data()
        }
    }

    private func write(_ data: Data) {
        do {
            let out = session != nil ? try session!.encrypt(data) : data
            channel.writeAndFlush(ByteBuffer(bytes: out), promise: nil)
        } catch {
            close()
        }
    }

    private func handle(_ request: HTTPRequest) async -> (HTTPResponse, After) {
        server.logger.trace("Request", metadata: [
            "method": "\(request.method)", "target": "\(request.target)",
            "body": "\(request.path.hasPrefix("/pair") ? "<\(request.body.count) bytes>" : String(decoding: request.body, as: UTF8.self))",
        ])
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"):
            return (handlePairSetup(request.body), .none)
        case ("POST", "/pair-verify"):
            return handlePairVerify(request.body)
        case ("POST", "/identify"):
            return (await handleIdentify(), .none)
        default:
            break
        }

        guard isVerified else {
            return (.hapStatus(470, .insufficientPrivileges), .none)
        }

        switch (request.method, request.path) {
        case ("POST", "/pairings"):
            return handlePairings(request.body)
        case ("GET", "/accessories"):
            return (.json(200, server.database(includeValues: true)), .none)
        case ("GET", "/characteristics"):
            return (await handleRead(request.query), .none)
        case ("PUT", "/characteristics"):
            return (await handleWrite(request.body), .none)
        case ("PUT", "/prepare"):
            return (handlePrepare(request.body), .none)
        case (_, "/resource"):
            return (await handleResource(request), .none)
        default:
            return (HTTPResponse(status: 404), .none)
        }
    }
}
