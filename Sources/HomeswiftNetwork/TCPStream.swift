import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A byte pipe to a device: what it sends arrives in `incoming` as it comes (frames split or run together, as TCP
/// delivers them), which ends when the connection closes. Plugins speak their protocol over it; tests give them one in
/// memory.
public protocol ByteStream: Sendable {
    var incoming: AsyncThrowingStream<[UInt8], any Error> { get }
    func send(_ bytes: [UInt8]) async throws
    func close() async
}

/// A plain TCP connection (`TCP_NODELAY` set) on NIO, the same on Linux.
public final class TCPStream: ByteStream {
    public let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let channel: any Channel

    private init(channel: any Channel, incoming: AsyncThrowingStream<[UInt8], any Error>) {
        self.channel = channel
        self.incoming = incoming
    }

    /// Connects, or throws `HTTPClientError.cannotConnect` (refused, unreachable, timed out).
    public static func connect(host: String, port: Int, timeout: Duration, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> TCPStream {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(TimeAmount(timeout))
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Forwarder(continuation: continuation))
                }
            }
        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            continuation.onTermination = { _ in channel.close(promise: nil) }
            return TCPStream(channel: channel, incoming: stream)
        } catch {
            continuation.finish()
            throw HTTPClientError.cannotConnect(host: host, port: port, code: nil, reason: String(describing: error))
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    }

    public func close() async {
        try? await channel.close()
    }

    private final class Forwarder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation

        init(continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation) {
            self.continuation = continuation
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            continuation.yield(Array(unwrapInboundIn(data).readableBytesView))
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            continuation.finish(throwing: error)
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }
    }
}
