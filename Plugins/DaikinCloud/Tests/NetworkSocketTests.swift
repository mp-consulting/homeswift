import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing

@testable import HomeswiftDaikinCloud

/// A WebSocket server like Onecta's on port 0: it takes the upgrade with the bearer token, pushes a
/// characteristic update, answers pings, and drops the connection on "drop".
final class OnectaSocketServer: Sendable {
    let channel: any Channel
    let authorizations = NIOLockedValueBox<[String]>([])
    var port: Int { channel.localAddress!.port! }

    init(push: String) async throws {
        let authorizations = authorizations
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in
                        authorizations.withLockedValue { $0.append(head.headers.first(name: "Authorization") ?? "") }
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(PushHandler(push: push)) }
                    })
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    func stop() async { try? await channel.close().get() }

    private final class PushHandler: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame
        let push: String
        init(push: String) { self.push = push }

        func handlerAdded(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: push))), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            var payload = frame.unmaskedData
            switch frame.opcode {
            case .ping: context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: payload)), promise: nil)
            case .text where payload.readString(length: payload.readableBytes) == "drop": context.close(promise: nil)
            case .connectionClose:
                // The channel, which is Sendable, closes once the reply is out; the context stays on its event loop.
                let channel = context.channel
                context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))).whenComplete { _ in channel.close(promise: nil) }
            default: break
            }
        }
    }
}

/// The client on `HomeswiftNetwork.WebSocket`, against a real server: the bearer token, a push, pings
/// answered, and a drop without a close frame.
@Suite(.timeLimit(.minutes(1)))
struct NetworkSocketTests {
    @Test func drivesTheReconnectingClient() async throws {
        let push = #"{"event":"gateway:managementpoint:characteristic","embeddedId":"climateControl","gatewayDeviceId":"dev-1","data":{"name":"onOffMode","value":"off"}}"#
        let server = try await OnectaSocketServer(push: push)
        let events = NIOLockedValueBox<[DaikinWebSocket.Event]>([])
        let opened = NIOLockedValueBox<[any WebSocketConnection]>([])
        let url = URL(string: "ws://127.0.0.1:\(server.port)/")!
        var timing = DaikinWebSocket.Timing()
        timing.pingInterval = .milliseconds(50)
        timing.pongTimeout = .seconds(2)
        // The real connection, to the test server instead of Onecta's.
        let client = DaikinWebSocket(oauth: FakeOAuth(), connect: { _, options in
            let socket = try await DaikinWebSocket.connect(url, options)
            opened.withLockedValue { $0.append(socket) }
            return socket
        }, timing: timing) { event in events.withLockedValue { $0.append(event) } }
        await client.connect()
        #expect(server.authorizations.withLockedValue { $0 } == ["Bearer valid-token"])
        #expect(await eventually { events.withLockedValue { $0 }.contains { if case .deviceUpdate(let update) = $0 { update.deviceID == "dev-1" } else { false } } })
        // Pings are answered: still the one connection after a few.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await client.isConnected)
        #expect(opened.withLockedValue { $0.count } == 1)
        // A drop without a close frame is a 1006, and the client comes back.
        try await opened.withLockedValue { $0[0] }.send(text: "drop")
        #expect(await eventually { events.withLockedValue { $0 }.contains(.disconnected(code: 1006, reason: "the connection dropped", reconnecting: true)) })
        #expect(await eventually { opened.withLockedValue { $0.count } == 2 })
        await client.disconnect()
        await server.stop()
    }
}
