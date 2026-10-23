import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// A byte pipe to a broker: TCP, TLS or WebSocket. `incoming` ends when the connection closes.
protocol MQTTByteTransport: Sendable {
    var incoming: AsyncThrowingStream<[UInt8], any Error> { get }
    func send(_ bytes: [UInt8]) async throws
    func close() async
}

/// MQTT over TCP, with TLS when `tls` is set.
final class MQTTSocketTransport: MQTTByteTransport {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let channel: any Channel
    private let mismatch: NIOLockedValueBox<(any Error)?>

    private init(channel: any Channel, incoming: AsyncThrowingStream<[UInt8], any Error>, mismatch: NIOLockedValueBox<(any Error)?>) {
        self.channel = channel
        self.incoming = incoming
        self.mismatch = mismatch
    }

    static func connect(host: String, port: Int, tls: TLSOptions?, timeout: Duration, group: any EventLoopGroup) async throws -> MQTTSocketTransport {
        let context = try tls?.makeContext()
        let observed = NIOLockedValueBox<String?>(nil)
        let mismatch = NIOLockedValueBox<(any Error)?>(nil)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(TimeAmount(timeout))
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls, let context {
                        try channel.pipeline.syncOperations.addHandler(tls.makeHandler(context: context, host: host, observed: observed, mismatch: mismatch))
                    }
                    try channel.pipeline.syncOperations.addHandler(ByteForwarder(continuation: continuation, mismatch: mismatch))
                }
            }
        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            continuation.onTermination = { _ in channel.close(promise: nil) }
            return MQTTSocketTransport(channel: channel, incoming: stream, mismatch: mismatch)
        } catch {
            continuation.finish()
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            let (code, reason) = connectionFailure(error)
            throw HTTPClientError.cannotConnect(host: host, port: port, code: code, reason: reason)
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        do {
            try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
        } catch {
            if let mismatch = mismatch.withLockedValue({ $0 }) { throw mismatch }
            throw MQTTError.connectionLost
        }
    }

    func close() async {
        try? await channel.close()
    }

    private final class ByteForwarder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
        let mismatch: NIOLockedValueBox<(any Error)?>

        init(continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation, mismatch: NIOLockedValueBox<(any Error)?>) {
            self.continuation = continuation
            self.mismatch = mismatch
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            continuation.yield(Array(buffer.readableBytesView))
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            continuation.finish(throwing: mismatch.withLockedValue { $0 } ?? error)
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }
    }
}

/// MQTT over a WebSocket (`mqtt` subprotocol, binary messages).
final class MQTTWebSocketTransport: MQTTByteTransport {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let socket: any WebSocketConnection

    init(socket: any WebSocketConnection) {
        self.socket = socket
        let messages = socket.messages
        incoming = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in messages { continuation.yield(Array(message.data)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        do {
            try await socket.send(.binary(Data(bytes)))
        } catch {
            throw MQTTError.connectionLost
        }
    }

    func close() async {
        await socket.close(code: 1000, reason: "")
    }
}
