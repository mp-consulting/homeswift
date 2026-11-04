import Foundation
import NIOCore
import NIOPosix

/// A plain TCP connection on NIO for devices with a binary protocol of their own (a robot vacuum's local port): the
/// bytes it receives as a stream, in the chunks they arrive in (framing is the caller's), and sends that wait for
/// the write. The stream ends when the connection closes, from either side.
public final class TCPSocket: Sendable {
    /// What arrives. Ends when the connection closes.
    public let received: AsyncStream<Data>
    private let channel: any Channel

    private init(channel: any Channel, received: AsyncStream<Data>) {
        self.channel = channel
        self.received = received
    }

    /// Connects within `timeout`. What arrives waits for the reader, which bounds its own buffer.
    public static func connect(
        host: String, port: Int, timeout: Duration = .seconds(10),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> TCPSocket {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(TimeAmount(timeout))
                .channelOption(.socketOption(.so_keepalive), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(Inbound(continuation: continuation))
                    }
                }
                .connect(host: host, port: port).get()
        } catch {
            continuation.finish()
            throw error
        }
        channel.closeFuture.whenComplete { _ in continuation.finish() }
        return TCPSocket(channel: channel, received: stream)
    }

    public var isOpen: Bool { channel.isActive }

    /// The peer's IP address.
    public var remoteAddress: String? { channel.remoteAddress?.ipAddress }

    public func send(_ data: Data) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
    }

    public func close() async {
        try? await channel.close()
    }

    private final class Inbound: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<Data>.Continuation

        init(continuation: AsyncStream<Data>.Continuation) { self.continuation = continuation }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            continuation.yield(Data(unwrapInboundIn(data).readableBytesView))
        }

        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }
}
