import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Sends one command's JSON to a device and answers its decrypted response; tests use a fake.
protocol KasaTransport: Sendable {
    /// `timeout` nil waits as long as the connection lasts (the `timeout: 0` of config.json).
    func send(_ json: String, host: String, port: Int, udp: Bool, timeout: Duration?) async throws -> String
}

/// The socket discovery broadcasts on and hears the replies on; tests use a fake.
protocol KasaDiscoverySocket: Sendable {
    var datagrams: AsyncStream<(data: Data, address: String)> { get }
    func send(_ data: Data, to host: String, port: Int) async throws
    func close() async
}

extension UDPSocket: KasaDiscoverySocket {}

struct KasaTimeout: Error, CustomStringConvertible {
    var transport: String
    var timeout: Duration
    var description: String { "\(transport) timeout after \(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000) ms" }
}

struct KasaConnectionClosed: Error, CustomStringConvertible {
    var description: String { "the device closed the connection before it answered" }
}

/// TCP (one connection per command, the response read across its segments) and UDP (one datagram each way), on NIO.
struct KasaNetworkTransport: KasaTransport {
    var group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton

    /// A UDP reply that is lost never comes: it is waited for this long when the block sets no timeout.
    static let udpTimeout = Duration.seconds(15)

    func send(_ json: String, host: String, port: Int, udp: Bool, timeout: Duration?) async throws -> String {
        let timeout = timeout ?? (udp ? Self.udpTimeout : nil)
        let operation: @Sendable () async throws -> String
        if udp {
            operation = { try await self.sendUDP(json, host: host, port: port) }
        } else {
            operation = { try await self.sendTCP(json, host: host, port: port, timeout: timeout) }
        }
        guard let timeout else { return try await operation() }
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let response = first else { throw KasaTimeout(transport: udp ? "UDP" : "TCP", timeout: timeout) }
            return response
        }
    }

    private func sendTCP(_ json: String, host: String, port: Int, timeout: Duration?) async throws -> String {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self)
        var bootstrap = ClientBootstrap(group: group)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Collector(continuation: continuation)) }
            }
        if let timeout { bootstrap = bootstrap.connectTimeout(TimeAmount(timeout)) }
        let channel = try await bootstrap.connect(host: host, port: port).get()
        // Cancelled (the timeout) or done: the connection goes.
        return try await withTaskCancellationHandler {
            defer { channel.close(promise: nil) }
            try await channel.writeAndFlush(ByteBuffer(bytes: KasaCipher.frame(json))).get()
            var reader = KasaFrameReader()
            for try await segment in stream {
                if let response = try reader.add(segment) { return response }
            }
            throw KasaConnectionClosed()
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    private func sendUDP(_ json: String, host: String, port: Int) async throws -> String {
        let socket = try await UDPSocket.bind(group: group)
        return try await withTaskCancellationHandler {
            defer { Task { await socket.close() } }
            try await socket.send(Data(KasaCipher.encrypt(json)), to: host, port: port)
            for await datagram in socket.datagrams {
                return String(decoding: KasaCipher.decrypt(datagram.data), as: UTF8.self)
            }
            throw KasaConnectionClosed()
        } onCancel: {
            Task { await socket.close() }
        }
    }

    /// Hands each segment over, and the close as the end.
    private final class Collector: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation

        init(continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation) { self.continuation = continuation }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            continuation.yield(Array(unwrapInboundIn(data).readableBytesView))
        }

        func channelInactive(context: ChannelHandlerContext) {
            continuation.finish()
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            continuation.finish(throwing: error)
            context.close(promise: nil)
        }
    }
}

/// One command at a time to each host, in the order they came: a strip's outlets share their device.
actor KasaHostQueues {
    private var tails: [String: Task<Void, Never>] = [:]

    func run(host: String, _ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        let previous = tails[host]
        let task = Task<String, any Error> {
            await previous?.value
            return try await operation()
        }
        let tail = Task<Void, Never> { _ = try? await task.value }
        tails[host] = tail
        defer { if tails[host] == tail { tails[host] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
