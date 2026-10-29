import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import HomeswiftNetwork

/// A server that answers with a head at once, then its body in `pieces`, one every 30 ms, then ends the response, or
/// holds the connection open (`holdOpen`) until the client closes it, which it records.
final class StreamingServer: Sendable {
    let channel: any Channel
    let closedByClient = NIOLockedValueBox(false)
    let seenPath = NIOLockedValueBox<String?>(nil)
    var port: Int { channel.localAddress!.port! }

    init(tls: Bool = false, status: Int = 200, pieces: [String], holdOpen: Bool = false) async throws {
        let context: NIOSSLContext?
        if tls {
            let certificate = try NIOSSLCertificate(bytes: Array(TestCertificate.certificatePEM.utf8), format: .pem)
            let key = try NIOSSLPrivateKey(bytes: Array(TestCertificate.keyPEM.utf8), format: .pem)
            context = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)))
        } else {
            context = nil
        }
        let closed = closedByClient, path = seenPath
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context)) }
                    // No pipelining assistance: it stops reading while a response is unfinished, so the server would
                    // never see the client close a stream it holds open.
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(Handler(status: status, pieces: pieces, holdOpen: holdOpen, closed: closed, path: path))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() async { try? await channel.close().get() }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let status: Int, pieces: [String], holdOpen: Bool
        let closed: NIOLockedValueBox<Bool>
        let path: NIOLockedValueBox<String?>
        var answering = false

        init(status: Int, pieces: [String], holdOpen: Bool, closed: NIOLockedValueBox<Bool>, path: NIOLockedValueBox<String?>) {
            (self.status, self.pieces, self.holdOpen, self.closed, self.path) = (status, pieces, holdOpen, closed, path)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): path.withLockedValue { $0 = head.uri }
            case .body: break
            case .end:
                answering = true
                var head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status))
                head.headers.add(name: "Content-Type", value: "text/event-stream")
                context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
                send(context: context, index: 0)
            }
        }

        private func send(context: ChannelHandlerContext, index: Int) {
            guard index < pieces.count else {
                if !holdOpen {
                    answering = false
                    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                    context.close(promise: nil)
                }
                return
            }
            let piece = pieces[index]
            let loop = context.eventLoop
            let bound = NIOLoopBound(context, eventLoop: loop)
            let handler = NIOLoopBound(self, eventLoop: loop)
            loop.scheduleTask(in: .milliseconds(30)) {
                let context = bound.value
                guard context.channel.isActive else { return }
                context.writeAndFlush(handler.value.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: piece)))), promise: nil)
                handler.value.send(context: context, index: index + 1)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            if answering { closed.withLockedValue { $0 = true } }
            context.fireChannelInactive()
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HTTPStreamingTests {
    @Test func handsBackTheHeadThenTheBodyAsItComes() async throws {
        let server = try await StreamingServer(pieces: ["data: one\n\n", "data: tw", "o\n\n"])
        defer { Task { await server.stop() } }
        let response = try await HTTPClient().stream(HTTPRequest(method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)/events")!))
        #expect(response.status == 200 && response.isSuccess)
        #expect(response.header("content-type") == "text/event-stream")
        var text = ""
        for try await chunk in response.body { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text == "data: one\n\ndata: two\n\n")
        #expect(server.seenPath.withLockedValue { $0 } == "/events")
    }

    @Test func readsServerSentEventsSplitAcrossPieces() async throws {
        let server = try await StreamingServer(pieces: [": hi\n\n", "id: 1\r\nevent: update\r\ndata: [{\"a\":", "1}]\r\n\r\n", "data: x\ndata: y\n\n"])
        defer { Task { await server.stop() } }
        let response = try await HTTPClient().stream(HTTPRequest(method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)/")!))
        var events: [ServerSentEvent] = []
        for try await event in response.events { events.append(event) }
        #expect(events == [ServerSentEvent(event: "update", data: #"[{"a":1}]"#, id: "1"), ServerSentEvent(data: "x\ny", id: "1")])
    }

    @Test func stoppingTheStreamClosesTheConnection() async throws {
        let server = try await StreamingServer(pieces: ["data: first\n\n"], holdOpen: true)
        defer { Task { await server.stop() } }
        // The loop in a function of its own, so its iterator is surely released before the wait (Swift may keep a
        // local until the end of its scope).
        func readFirst() async throws -> String? {
            let response = try await HTTPClient().stream(HTTPRequest(method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)/")!))
            for try await event in response.events { return event.data }
            return nil
        }
        #expect(try await readFirst() == "first")
        try await eventually(.seconds(5), "the server should see the connection close") { server.closedByClient.withLockedValue { $0 } }
    }

    @Test func pinsTheCertificateAndRefusesAnother() async throws {
        let server = try await StreamingServer(tls: true, pieces: ["data: secure\n\n"])
        defer { Task { await server.stop() } }
        let url = URL(string: "https://127.0.0.1:\(server.port)/")!
        let response = try await HTTPClient(tls: .any).stream(HTTPRequest(method: "GET", url: url))
        #expect(response.certificateFingerprint == TestCertificate.fingerprint)
        for try await _ in response.body {}
        await #expect(throws: HTTPClientError.self) {
            _ = try await HTTPClient(tls: .pinned(String(repeating: "ab", count: 32))).stream(HTTPRequest(method: "GET", url: url))
        }
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        let server = try await TestServer(tls: false, behaviour: .silent)
        defer { Task { await server.stop() } }
        await #expect(throws: HTTPClientError.timeout) {
            _ = try await HTTPClient().stream(HTTPRequest(method: "GET", url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: .milliseconds(300)))
        }
    }
}

@Suite struct ServerSentEventTests {
    @Test func followsTheStandardsParsingRules() {
        var parser = ServerSentEvents()
        // A comment, a field without a colon, one space dropped after the colon (not two), an unknown field, a lone CR.
        let text = ": keep-alive\nevent: a\ndata\ndata:  two spaces\nretry: 10\r\rdata:no space\n\n"
        let events = parser.feed(Array(text.utf8))
        #expect(events == [ServerSentEvent(event: "a", data: "\n two spaces"), ServerSentEvent(data: "no space")])
    }

    @Test func dropsAnEventWithoutDataAndKeepsTheLastID() {
        var parser = ServerSentEvents()
        #expect(parser.feed(Array("id: 7\nevent: ping\n\n".utf8)).isEmpty)
        #expect(parser.feed(Array("data: after\n\n".utf8)) == [ServerSentEvent(data: "after", id: "7")])
    }

    @Test func aCRLFSplitBetweenChunksIsOneLineEnd() {
        var parser = ServerSentEvents()
        #expect(parser.feed(Array("data: a\r".utf8)).isEmpty)
        #expect(parser.feed(Array("\n\r\n".utf8)) == [ServerSentEvent(data: "a")])
    }
}
