import Foundation
import NIOCore
import NIOPosix

/// A UDP socket on NIO for LAN protocols (discovery probes, device status broadcasts, Wake-on-LAN): bound to a
/// port, optionally in a multicast group, with the datagrams it receives as a stream. A failed send (the network
/// unreachable after a Wi-Fi drop) fails that send only; the socket stays open.
public final class UDPSocket: Sendable {
    /// A datagram with its sender's address and port.
    public struct Datagram: Sendable, Equatable {
        public var data: Data
        public var address: String
        public var port: Int

        public init(data: Data, address: String, port: Int) {
            self.data = data
            self.address = address
            self.port = port
        }
    }

    /// What arrives, with the sender's IP address. Ends when the socket closes. Empty (and ended) for a socket bound
    /// with `senderPorts`, whose datagrams arrive in `datagramsWithPorts`.
    public let datagrams: AsyncStream<(data: Data, address: String)>
    /// What arrives with the sender's address and port, for a socket bound with `senderPorts` (a reply's source port
    /// is where to answer, behind port forwarding); empty otherwise. Ends when the socket closes.
    public let datagramsWithPorts: AsyncStream<Datagram>
    private let channel: any Channel

    private init(channel: any Channel, datagrams: AsyncStream<(data: Data, address: String)>, datagramsWithPorts: AsyncStream<Datagram>) {
        self.channel = channel
        self.datagrams = datagrams
        self.datagramsWithPorts = datagramsWithPorts
    }

    /// Binds a socket. `reuseAddress` lets another process (or bridge) bind the same port, `broadcast` allows sends
    /// to broadcast addresses, `multicastGroup` joins that IPv4 group. `bufferSize` datagrams wait at most for a
    /// reader; older ones are dropped beyond. `senderPorts` hands them over in `datagramsWithPorts` instead of `datagrams`.
    public static func bind(
        host: String = "0.0.0.0", port: Int = 0, reuseAddress: Bool = false, broadcast: Bool = false, multicastGroup: String? = nil,
        bufferSize: Int = 256, senderPorts: Bool = false, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> UDPSocket {
        let (stream, plain) = AsyncStream<(data: Data, address: String)>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        let (withPorts, ported) = AsyncStream<Datagram>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        // The stream not used ends at once; what the handler yields to it is dropped.
        if senderPorts { plain.finish() } else { ported.finish() }
        let inbound = Inbound(plain: plain, ported: ported, senderPorts: senderPorts)
        var bootstrap = DatagramBootstrap(group: group)
        if reuseAddress { bootstrap = bootstrap.channelOption(.socketOption(.so_reuseaddr), value: 1) }
        if broadcast { bootstrap = bootstrap.channelOption(.socketOption(.so_broadcast), value: 1) }
        let channel: any Channel
        do {
            channel = try await bootstrap
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(inbound) }
                }
                .bind(host: host, port: port).get()
        } catch {
            inbound.finish()
            throw error
        }
        channel.closeFuture.whenComplete { _ in inbound.finish() }
        if let multicastGroup {
            do {
                guard let multicast = channel as? any MulticastChannel else { throw ChannelError.operationUnsupported }
                try await multicast.joinGroup(try SocketAddress(ipAddress: multicastGroup, port: 0)).get()
            } catch {
                try? await channel.close()
                throw error
            }
        }
        return UDPSocket(channel: channel, datagrams: stream, datagramsWithPorts: withPorts)
    }

    /// The port the socket is bound to (the one the system chose for port 0).
    public var localPort: Int? { channel.localAddress?.port }

    public func send(_ data: Data, to host: String, port: Int) async throws {
        try await send(data, to: SocketAddress(ipAddress: host, port: port))
    }

    public func send(_ data: Data, to address: SocketAddress) async throws {
        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: ByteBuffer(bytes: data))).get()
    }

    public func close() async {
        try? await channel.close()
    }

    private final class Inbound: ChannelInboundHandler, Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        let plain: AsyncStream<(data: Data, address: String)>.Continuation
        let ported: AsyncStream<Datagram>.Continuation
        let senderPorts: Bool

        init(plain: AsyncStream<(data: Data, address: String)>.Continuation, ported: AsyncStream<Datagram>.Continuation, senderPorts: Bool) {
            self.plain = plain
            self.ported = ported
            self.senderPorts = senderPorts
        }

        func finish() {
            plain.finish()
            ported.finish()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            let bytes = Data(envelope.data.readableBytesView), address = envelope.remoteAddress.ipAddress ?? ""
            if senderPorts {
                ported.yield(Datagram(data: bytes, address: address, port: envelope.remoteAddress.port ?? 0))
            } else {
                plain.yield((bytes, address))
            }
        }

        // An ICMP error for an earlier send (nobody at that address) must not close the socket.
        func errorCaught(context: ChannelHandlerContext, error: any Error) {}
    }
}

/// An IPv4 network of one of this machine's interfaces.
public struct IPv4Network: Sendable, Hashable {
    /// The interface's address and netmask, as numbers (`192.168.1.10` is `0xC0A8010A`).
    public var address: UInt32
    public var netmask: UInt32

    public init(address: UInt32, netmask: UInt32) {
        self.address = address
        self.netmask = netmask
    }

    /// The directed broadcast address (`192.168.1.255` on `192.168.1.0/24`).
    public var broadcast: UInt32 { address | ~netmask }
    public var isLoopback: Bool { address >> 24 == 127 }

    public func contains(_ ip: UInt32) -> Bool { address & netmask == ip & netmask }

    /// A dotted IPv4 address as a number; nil for anything else (a host name, IPv6).
    public static func parse(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    public static func dotted(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }
}

/// The IPv4 networks of this machine's interfaces, loopback included, in the system's order.
public func localIPv4Networks() -> [IPv4Network] {
    NetworkInterfaces.ipv4().map { IPv4Network(address: $0.address, netmask: $0.netmask) }
}
