import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOWebSocket

// The microphone button's WebSocket: `GET /api/cameras/<accessory id>/talk?sampleRate=16000` upgraded, a Talk for as
// long as the socket is open (CameraTalk.swift). The bridge's first message is text: `{"talk": "<id>", "sampleRate": n}`
// once the Talk started, or `{"error": "…", "status": n}` before it closes. Then each binary message from the page is
// signed 16-bit little-endian mono at that rate, at most a second of it; closing the socket ends the Talk. When the
// plugin gives up, the bridge sends `{"error": "…", "status": 502}` and closes.
//
// The upgrade is granted only to what the same request's POST could do (`authorize`): a host the UI answers to, a
// signed-in user's cookie from the page itself (a browser always sends `Origin` with a WebSocket), allowed to control
// accessories. Anything else is not upgraded and reaches the API as a GET, which says why; the page then talks over
// requests.

extension UIServer {
    /// What a Talk's WebSocket request was granted: its camera, user and rate.
    struct TalkSocketTarget: Sendable {
        var accessoryID: String
        var caller: Caller
        var sampleRate: Int?
    }

    /// The upgrader the UI's pipeline offers a connection.
    func talkSocketUpgrader() -> NIOWebSocketServerUpgrader {
        // What the upgrade request was granted, for the handler: the upgrader is the connection's own.
        let granted = NIOLockedValueBox<TalkSocketTarget?>(nil)
        return NIOWebSocketServerUpgrader(maxFrameSize: 1 << 16, automaticErrorHandling: true) { [self] channel, head in
            let target = talkSocketTarget(head, remote: channel.remoteAddress?.ipAddress ?? "?")
            granted.withLockedValue { $0 = target }
            return channel.eventLoop.makeSucceededFuture(target == nil ? nil : HTTPHeaders())
        } upgradePipelineHandler: { [self] channel, _ in
            guard let target = granted.withLockedValue({ $0 }) else { return channel.close() }
            let handler = TalkSocketHandler(server: self, accessoryID: target.accessoryID, caller: target.caller, sampleRate: target.sampleRate)
            return channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) }
        }
    }

    /// The camera and user of a Talk's WebSocket request, when the request may have one.
    func talkSocketTarget(_ head: HTTPRequestHead, remote: String) -> TalkSocketTarget? {
        let request = request(head, headers: Self.headers(of: head), body: Data(), remote: remote)
        guard request.method == .GET, isAllowedHost(request.headers["host"]), request.headers["origin"] != nil else { return nil }
        let parts = pathParts(request)
        guard parts.count == 4, parts[0] == "api", parts[1] == "cameras", parts[3] == "talk",
              case .allowed(let caller) = authorize(request, route: Array(parts.dropFirst()), as: .POST, bearer: false) else { return nil }
        return TalkSocketTarget(accessoryID: parts[2], caller: caller, sampleRate: request.query["sampleRate"].flatMap { Int($0) })
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
            loop.execute { self.began(started) }
            server.auditTalkSocket(accessoryID, caller: caller, sampleRate: sampleRate, started: started)
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
            guard let session else { return }
            let payload = frame.unmaskedData
            guard payload.readableBytes <= session.maxChunkBytes else {
                close(["error": "at most a second of audio per message", "status": 413], code: .messageTooLarge)
                return
            }
            session.push(payload.readableBytesView)
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
        // Nothing from the page for the UI's idle time (the Talk's own watchdog ends it sooner): a socket whose Talk never
        // started, or a page gone.
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
    /// A Talk started over a WebSocket is audited as one started over a request: its POST.
    func auditTalkSocket(_ accessoryID: String, caller: Caller, sampleRate: Int?, started: Result<CameraTalks.Session, ReplyError>) {
        let body = sampleRate.map { JSONValue.object(["sampleRate": .number(Double($0))]).encoded() } ?? Data()
        let request = Request(method: .POST, path: "/api/cameras/\(accessoryID)/talk", headers: [:], body: body, remote: "")
        let reply: Reply = switch started {
        case .success: .json(JSONValue.object([:]))
        case .failure(let refusal): .error(refusal.status, refusal.message)
        }
        audit(["cameras", accessoryID, "talk"], request, caller: caller, reply: reply)
    }
}
