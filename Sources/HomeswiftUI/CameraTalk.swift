import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

// The microphone button of a camera's live view: what the browser hears, sent to the camera's speaker.
//
// - `GET /api/cameras/<accessory id>/talk?sampleRate=16000` upgraded to a WebSocket (CameraTalkSocket.swift) is a Talk
//   for as long as the socket is open: binary messages carry the audio, as below without base64. The page uses it
//   when it can; a proxy that does not pass WebSockets leaves it the requests below.
// - `POST /api/cameras/<accessory id>/talk` starts a Talk: `{"talk": "<id>", "sampleRate": 16000}`, the rate the browser
//   sends, the camera's (`HomeswiftPlugin.talkFormat`). One Talk per camera at a time: 409 while someone else talks.
// - `POST /api/cameras/<accessory id>/talk/<id>` carries the audio: `{"seq": n, "pcm": "<base64>"}`, signed 16-bit
//   little-endian mono at that rate, a tenth of a second or so per request, sent one after the other; `{"end": true}`
//   ends the Talk. A Talk the plugin gave up on answers its reason (502), one that ended 410.
//
// A browser cannot stream a request body over HTTP/1.1, so without the WebSocket the audio goes up in short requests.
// A Talk ends `idleTimeout` after its last audio (a closed tab, a lost network), and after `maximum`. Starting is
// audited; the audio is not.

/// The Talks under way from the web UI, one per camera.
final class CameraTalks: Sendable {
    /// Silence from the browser that ends a Talk.
    static let idleTimeout: Duration = .seconds(3)
    /// The longest Talk.
    static let maximum: Duration = .seconds(600)
    /// The most audio one request carries: a second.
    static let maxChunk: Duration = .seconds(1)
    /// How often the watchdog looks.
    static let watchEvery: Duration = .milliseconds(500)

    /// One Talk: the frames the plugin reads, cut from what the browser sends.
    final class Session: Sendable {
        let id: String
        let accessoryID: String
        let username: String
        let format: ReturnAudioFormat
        let started = ContinuousClock.now
        private let continuation: AsyncStream<PCMFrame>.Continuation
        private struct State {
            var framer: PCMFramer
            var offset = 0
            var lastSeq = -1
            var lastHeard = ContinuousClock.now
            var ended = false
            var failure: String?
            var endHandlers: [@Sendable (String?) -> Void] = []
        }
        private let state: NIOLockedValueBox<State>

        init(id: String, accessoryID: String, username: String, format: ReturnAudioFormat, continuation: AsyncStream<PCMFrame>.Continuation) {
            self.id = id
            self.accessoryID = accessoryID
            self.username = username
            self.format = format
            self.continuation = continuation
            state = NIOLockedValueBox(State(framer: PCMFramer(samplesPerFrame: format.samplesPerFrame)))
        }

        var isEnded: Bool { state.withLockedValue { $0.ended } }
        var failure: String? { state.withLockedValue { $0.failure } }
        var lastHeard: ContinuousClock.Instant { state.withLockedValue { $0.lastHeard } }
        /// The most audio one message may carry: `CameraTalks.maxChunk`.
        var maxChunkBytes: Int { format.sampleRate * 2 * Int(CameraTalks.maxChunk / .seconds(1)) }

        /// Runs `handler` with the plugin's reason, if it gave up, once the Talk ends; at once if it has.
        func whenEnded(_ handler: @escaping @Sendable (String?) -> Void) {
            let ended: String?? = state.withLockedValue { state in
                guard state.ended else { state.endHandlers.append(handler); return .none }
                return .some(state.failure)
            }
            if case .some(let failure) = ended { handler(failure) }
        }

        /// Cuts a request's PCM into frames for the plugin; a request older than one already taken is dropped.
        func push(seq: Int, pcm: Data) {
            let frames: [PCMFrame] = state.withLockedValue { state in
                guard !state.ended, seq > state.lastSeq else { return [] }
                state.lastSeq = seq
                state.lastHeard = .now
                return state.framer.push(pcm).map { samples in
                    defer { state.offset += samples.count }
                    return PCMFrame(samples: samples, offset: state.offset)
                }
            }
            for frame in frames { continuation.yield(frame) }
        }

        /// Ends the Talk: the partial frame padded, then the frames finish. Once.
        func end(failure: String? = nil) {
            let last: (frame: PCMFrame?, handlers: [@Sendable (String?) -> Void])? = state.withLockedValue { state in
                guard !state.ended else { return nil }
                state.ended = true
                state.failure = failure
                defer { state.endHandlers = [] }
                return (state.framer.flush().map { PCMFrame(samples: $0, offset: state.offset) }, state.endHandlers)
            }
            guard let last else { return }
            if let frame = last.frame { continuation.yield(frame) }
            continuation.finish()
            for handler in last.handlers { handler(failure) }
        }

    }

    private let sessions = NIOLockedValueBox<[String: Session]>([:])

    /// The Talk under way on a camera.
    func session(_ accessoryID: String) -> Session? { sessions.withLockedValue { $0[accessoryID] } }

    /// Starts a Talk on a camera, the plugin playing it on a task of its own (`play`); refuses while someone else talks
    /// on it. The same user starting again (a second tab) ends their own first.
    func start(accessoryID: String, id: String, username: String, format: ReturnAudioFormat, volume: Int,
               play: @escaping @Sendable (Talk) async throws -> Void) -> Result<Session, ReplyError> {
        let (frames, continuation) = AsyncStream.makeStream(of: PCMFrame.self, bufferingPolicy: .bufferingNewest(Int(Self.maxChunk / format.frameDuration) * 4))
        let session = Session(id: id, accessoryID: accessoryID, username: username, format: format, continuation: continuation)
        let previous: Session?? = sessions.withLockedValue { sessions in
            if let other = sessions[accessoryID], !other.isEnded {
                guard other.username == username else { return .none }
                sessions[accessoryID] = session
                return .some(other)
            }
            sessions[accessoryID] = session
            return .some(nil)
        }
        guard case .some(let replaced) = previous else {
            let other = self.session(accessoryID)?.username ?? "someone"
            return .failure(ReplyError(409, "\(other) is talking on this camera"))
        }
        replaced?.end()
        let talk = Talk(sessionID: id, format: format, frames: frames, volume: volume)
        Task {
            do {
                try await play(talk)
                session.end()
            } catch {
                session.end(failure: "\(error)")
            }
        }
        // Ends the Talk once the browser falls silent or it runs too long; the plugin's task ends with its frames. An
        // ended Talk stays until the camera's next, so the browser's next request learns why it ended.
        Task {
            while !session.isEnded {
                try? await Task.sleep(for: Self.watchEvery)
                let now = ContinuousClock.now
                if now - session.lastHeard > Self.idleTimeout || now - session.started > Self.maximum { session.end() }
            }
        }
        return .success(session)
    }
}

extension UIServer {
    /// Starts the web UI's microphone on a camera, over requests.
    func startTalk(_ id: String, _ body: JSONValue, username: String) async -> Reply {
        guard let talkID = body["talk"]?.stringValue, Self.isTalkID(talkID) else { return .error(400, "give talk, an id of 8 to 64 letters, digits and dashes") }
        switch await beginTalk(id, talkID: talkID, sampleRate: body["sampleRate"]?.saturatingIntValue, username: username) {
        case .failure(let refusal): return .error(refusal.status, refusal.message)
        case .success(let session): return .json(["talk": .string(talkID), "sampleRate": .number(Double(session.format.sampleRate))])
        }
    }

    /// Starts a Talk, over requests or a WebSocket: the camera must be reachable and have a speaker, and `sampleRate`,
    /// the rate the browser resampled to, must be the camera's (anything else would play too fast or too slow).
    func beginTalk(_ id: String, talkID: String, sampleRate: Int?, username: String) async -> Result<CameraTalks.Session, ReplyError> {
        let camera: CameraController, name: String
        switch reachableCamera(id) {
        case .success(let found): (camera, name) = found
        case .failure(let refusal): return .failure(refusal)
        }
        guard let format = await catalog.host.talkFormat(accessoryID: id) else { return .failure(ReplyError(404, "\(name) has no speaker the bridge can play on")) }
        if let sampleRate, sampleRate != format.sampleRate {
            return .failure(ReplyError(409, "\(name) takes \(format.sampleRate) Hz; ask its controls again"))
        }
        let volume = camera.speakerService?[.volume]?.value.intValue ?? 100
        let host = catalog.host, logger = logger
        let started = cameraTalks.start(accessoryID: id, id: talkID, username: username, format: format, volume: volume) { talk in
            do {
                try await host.talk(accessoryID: id, talk)
                logger.debug("Web UI user \(username) stopped talking on \(name)")
            } catch {
                logger.warning("Talking on \(name) stopped", metadata: ["user": "\(username)", "error": "\(error)"])
                throw error
            }
        }
        if case .success = started { logger.info("Web UI user \(username) is talking on \(name)") }
        return started
    }

    /// Audio for a Talk, or its end.
    func talkAudio(_ id: String, _ talkID: String, _ body: JSONValue, username: String) -> Reply {
        guard let session = cameraTalks.session(id), session.id == talkID, session.username == username else {
            return .error(410, "this talk has ended")
        }
        if let failure = session.failure { return .error(502, failure) }
        if session.isEnded { return .error(410, "this talk has ended") }
        if body["end"]?.boolValue == true {
            session.end()
            return .json(JSONValue.object([:]))
        }
        guard let seq = body["seq"]?.saturatingIntValue, let text = body["pcm"]?.stringValue, let pcm = Data(base64Encoded: text) else {
            return .error(400, "give seq and pcm, base64 signed 16-bit little-endian mono")
        }
        guard pcm.count <= session.maxChunkBytes else { return .error(413, "at most a second of audio per request") }
        session.push(seq: seq, pcm: pcm)
        return .json(JSONValue.object([:]))
    }

    /// A Talk's id, from the browser: it lands in a path and the log.
    static func isTalkID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
