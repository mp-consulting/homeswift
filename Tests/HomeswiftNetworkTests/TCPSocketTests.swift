import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import HomeswiftNetwork

/// `TCPSocket` against an echo server on port 0.
struct TCPSocketTests {
    private final class Echo: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            if buffer.readableBytesView.first == UInt8(ascii: "q") {
                context.close(promise: nil)
            } else {
                context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
            }
        }
    }

    private static func echoServer() async throws -> any Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Echo()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    @Test func sendsAndReceivesUntilThePeerCloses() async throws {
        let server = try await Self.echoServer()
        let port = try #require(server.localAddress?.port)
        let socket = try await TCPSocket.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
        #expect(socket.remoteAddress == "127.0.0.1")
        try await socket.send(Data("hello".utf8))
        var received = Data()
        var iterator = socket.received.makeAsyncIterator()
        while received.count < 5, let chunk = await iterator.next() { received.append(chunk) }
        #expect(received == Data("hello".utf8))
        // The peer closes: the stream ends.
        try await socket.send(Data("q".utf8))
        while await iterator.next() != nil {}
        #expect(!socket.isOpen)
        try await server.close()
    }

    @Test func aRefusedConnectionThrows() async throws {
        // Port 1 on the loopback: nothing listens there. A port freed by closing a server could be taken by another test
        // running at the same time, and then the connection succeeds.
        await #expect(throws: (any Error).self) { try await TCPSocket.connect(host: "127.0.0.1", port: 1, timeout: .seconds(2)) }
    }
}
