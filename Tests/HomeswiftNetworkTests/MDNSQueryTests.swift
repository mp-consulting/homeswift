import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import HomeswiftNetwork

@Suite(.timeLimit(.minutes(1)))
struct MDNSQueryTests {
    /// A response as a Dyson device sends it: a PTR to its instance, then SRV and A records, names compressed.
    static func response(id: UInt16 = 0) -> [UInt8] {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x84, 0x00, 0, 1, 0, 1, 0, 0, 0, 2]
        // Question at 12: _dyson_mqtt._tcp.local PTR IN.
        packet += [11] + Array("_dyson_mqtt".utf8) + [4] + Array("_tcp".utf8) + [5] + Array("local".utf8) + [0, 0, 12, 0, 1]
        // Answer: the question's name (pointer to 12) PTR -> "455_ABC-AB-12345678" + pointer to 12.
        let instance: [UInt8] = [19] + Array("455_ABC-AB-12345678".utf8) + [0xC0, 12]
        packet += [0xC0, 12, 0, 12, 0, 1, 0, 0, 0, 120, 0, UInt8(instance.count)]
        let instanceOffset = packet.count
        packet += instance
        // Additional: the instance (pointer) SRV 0 0 1883 -> "dyson.local" (pointer to "local" at 12 + 12 + 5).
        let target: [UInt8] = [5] + Array("dyson".utf8) + [0xC0, 12 + 12 + 5]
        packet += [0xC0, UInt8(instanceOffset), 0, 33, 0, 1, 0, 0, 0, 120, 0, UInt8(6 + target.count), 0, 0, 0, 0, 0x07, 0x5B] + target
        // Additional: an A record for the target, with no usable address in this test.
        packet += [0xC0, UInt8(packet.count - target.count), 0, 1, 0, 1, 0, 0, 0, 120, 0, 4, 0, 0, 0, 0]
        return packet
    }

    @Test func encodesAQuery() {
        #expect(MDNSQuery.encodeQuery(name: "_dyson_mqtt._tcp.local", type: .ptr) == [
            0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 11, 95, 100, 121, 115, 111, 110, 95, 109, 113, 116, 116, 4, 95, 116, 99, 112, 5, 108, 111, 99, 97,
            108, 0, 0, 12, 0, 1,
        ])
    }

    @Test func readsTheNamesOfAResponse() {
        #expect(MDNSQuery.responseNames(Self.response()) == [
            "_dyson_mqtt._tcp.local", "455_ABC-AB-12345678._dyson_mqtt._tcp.local", "dyson.local",
        ])
        // A query, a truncated packet and a pointer loop are not responses.
        #expect(MDNSQuery.responseNames(MDNSQuery.encodeQuery(name: "a.local", type: .ptr)) == nil)
        #expect(MDNSQuery.responseNames(Array(Self.response().prefix(40))) == nil)
        var offset = 0
        #expect(MDNSQuery.readName([0xC0, 0], at: &offset) == nil)
    }

    @Test func collectsAnswersWithTheirSender() async throws {
        // A responder on loopback in place of the multicast group: it answers each query to its sender's port.
        let responder = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Responder()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { responder.close(promise: nil) }
        let port = try #require(responder.localAddress?.port)
        let responses = try await MDNSQuery.query("_dyson_mqtt._tcp.local", duration: .milliseconds(500), host: "127.0.0.1", port: port)
        let first = try #require(responses.first)
        #expect(first.sender == "127.0.0.1")
        #expect(first.names.contains("455_ABC-AB-12345678._dyson_mqtt._tcp.local"))
    }

    private final class Responder: ChannelInboundHandler, Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            guard envelope.data.readableBytes > 12 else { return }
            let reply = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: ByteBuffer(bytes: MDNSQueryTests.response()))
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        }
    }
}
