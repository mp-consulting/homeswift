import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import NIOCore
import NIOHTTP1
import NIOWebSocket

// The microphone button's WebSocket: `GET /api/cameras/<accessory id>/talk?sampleRate=16000` upgraded, a Talk for as
// long as the socket is open (CameraTalk.swift). The bridge's first message is text: `{"talk": "<id>", "sampleRate": n}`
// once the Talk started, or `{"error": "…", "status": n}` before it closes. Then each binary message from the page is
// signed 16-bit little-endian mono at that rate, at most a second of it; closing the socket ends the Talk. When the
// plugin gives up, the bridge sends `{"error": "…", "status": 502}` and closes.
//
// The upgrade is granted only to what the same request over the API could do: a host the UI answers to, a signed-in
// user's cookie from the page itself (a browser always sends `Origin` with a WebSocket), allowed to control accessories.
// Anything else is not upgraded and reaches the API's own route, which says why; the page then talks over requests.

extension UIServer {
    /// The upgrader the UI's pipeline offers.
    func talkSocketUpgrader() -> NIOWebSocketServerUpgrader {
        NIOWebSocketServerUpgrader(maxFrameSize: 1 << 16, automaticErrorHandling: true) { [self] channel, head in
            let allowed = talkSocketTarget(head) != nil
            return channel.eventLoop.makeSucceededFuture(allowed ? HTTPHeaders() : nil)
        } upgradePipelineHandler: { [self] channel, head in
            guard let target = talkSocketTarget(head) else { return channel.close() }
            let handler = TalkSocketHandler(server: self, accessoryID: target.accessoryID, caller: target.caller, sampleRate: target.sampleRate)
            return channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) }
        }
    }

    /// The camera and user of a Talk's WebSocket request, when the request may have one.
    func talkSocketTarget(_ head: HTTPRequestHead) -> (accessoryID: String, caller: Caller, sampleRate: Int?)? {
        guard head.method == .GET, let components = URLComponents(string: head.uri) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count == 4, parts[0] == "api", parts[1] == "cameras", parts[3] == "talk" else { return nil }
        var headers: [String: String] = [:]
        for (name, value) in head.headers { headers[name.lowercased()] = value }
        let request = Request(method: .GET, path: components.percentEncodedPath, headers: headers, body: Data(), remote: "")
        guard isAllowedHost(headers["host"]), headers["origin"] != nil, refuseCrossSite(request) == nil,
              let caller = caller(request, bearer: false), caller.token == nil,
              caller.scope >= Self.requiredScope(.POST, ["cameras", parts[2], "talk"]) else { return nil }
        let rate = components.queryItems?.first { $0.name == "sampleRate" }?.value.flatMap { Int($0) }
        return (parts[2], caller, rate)
    }
}

/// One Talk's WebSocket: starts the Talk once upgraded, hands each binary message to it, and ends it when either side
/// closes.
final class TalkSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: UIServer
    private let accessoryID: String
    private let caller: UIServer.Caller
    private let sampleRate: Int?
    // On the channel's event loop only.
    private var session: CameraTalks.Session?
    private var seq = 0
    private var closing = false
    private var context: ChannelHandlerContext?

    init(server: UIServer, accessoryID: String, caller: UIServer.Caller, sampleRate: Int?) {
        self.server = server
        self.accessoryID = accessoryID
        self.caller = caller
        self.sampleRate = sampleRate
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        let talkID = Secrets.randomToken()
        let loop = context.eventLoop
        Task { [self, server, accessoryID, caller, sampleRate] in
            let started = await server.beginTalk(accessoryID, talkID: talkID, sampleRate: sampleRate, username: caller.username)
            server.auditTalkSocket(accessoryID, caller: caller, started: started)
            loop.execute { self.began(started) }
        }
    }

    private func began(_ started: Result<CameraTalks.Session, ReplyError>) {
        switch started {
        case .failure(let refusal):
            close(["error": .string(Redaction.redactText(refusal.message)), "status": .number(Double(refusal.status))], code: .policyViolation)
        case .success(let session):
            // The socket closed while the Talk started: it ends at once.
            guard !closing else { session.end(); return }
            self.session = session
            send(["talk": .string(session.id), "sampleRate": .number(Double(session.format.sampleRate))])
            let loop = context?.eventLoop
            session.whenEnded { [self] failure in
                loop?.execute {
                    self.close(failure.map { ["error": .string(Redaction.redactText($0)), "status": 502] }, code: failure == nil ? .normalClosure : .unexpectedServerError)
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            var payload = frame.unmaskedData
            guard let session, let bytes = payload.readBytes(length: payload.readableBytes) else { return }
            guard bytes.count <= session.maxChunkBytes else {
                close(["error": "at most a second of audio per message", "status": 413], code: .messageTooLarge)
                return
            }
            session.push(seq: seq, pcm: Data(bytes))
            seq += 1
        case .connectionClose:
            session?.end()
            close(nil, code: .normalClosure)
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        default:
            // Text: the page has nothing to say but its audio. Pongs and continuations are let be.
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closing = true
        session?.end()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Nothing from the page for the UI's idle time: the Talk is over.
        if let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read {
            session?.end()
            close(nil, code: .goingAway)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func send(_ message: JSONValue) {
        guard let context, !closing else { return }
        let frame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(bytes: message.encoded()))
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    /// Says why, if there is something to say, then a close frame and the connection's end. Once.
    private func close(_ message: JSONValue?, code: WebSocketErrorCode) {
        guard let context, !closing else { return }
        if let message { send(message) }
        closing = true
        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

extension UIServer {
    /// A Talk started over a WebSocket is audited as one started over a request.
    func auditTalkSocket(_ accessoryID: String, caller: Caller, started: Result<CameraTalks.Session, ReplyError>) {
        let request = Request(method: .GET, path: "/api/cameras/\(accessoryID)/talk", headers: [:], body: Data(), remote: "")
        let reply: Reply = switch started {
        case .success: .json(JSONValue.object([:]))
        case .failure(let refusal): .error(refusal.status, refusal.message)
        }
        audit(["cameras", accessoryID, "talk"], request, caller: caller, reply: reply)
    }
}
