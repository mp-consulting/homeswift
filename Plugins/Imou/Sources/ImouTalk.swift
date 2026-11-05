import Foundation
import HomeswiftFFmpeg
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

// Two-way talk from HomeKit to a camera on the LAN (docs/clean-room/ImouTalk.md): each Talk of return audio
// (HomeswiftFFmpeg's ReturnAudioReceiver) goes to the camera's speaker through Dahua's `postAudio` CGI, a POST whose body
// never ends, or, on firmware without it, through the ONVIF RTSP backchannel of its stream. Experimental, off unless the
// camera's `twoWayAudio` setting turns it on: neither path was tried on an IMOU device (see README.md).

/// Opens a raw TCP connection: TCPStream, or a fake camera in tests.
typealias TalkConnector = @Sendable (_ host: String, _ port: Int, _ timeout: Duration) async throws -> any ByteStream

/// Whether a camera talks (an Accessory Setting): `auto` asks the camera, `on` forces it, `off` (the default) never.
enum TalkMode: String, Sendable {
    case auto, on, off
}

/// What `postAudio` sends: G.711 A-law (the default), µ-law, or AAC in ADTS.
enum TalkCodec: String, Sendable {
    case g711A = "G.711A"
    case g711Mu = "G.711Mu"
    case aac = "AAC"

    var contentType: String { "Audio/" + rawValue }
    /// The PCM asked of the receiver: 8 kHz for G.711, 16 kHz for AAC (section 5).
    var format: ReturnAudioFormat { ReturnAudioFormat(sampleRate: self == .aac ? 16000 : 8000) }
}

/// How a Talk reaches the camera: `auto` tries `postAudio` and falls back to the backchannel.
enum TalkMethod: String, Sendable {
    case auto, http, rtsp
}

/// One piece of encoded audio, as it is written: 1024 bytes of G.711 (128 ms), or one ADTS frame.
struct TalkPiece: Sendable, Equatable {
    var bytes: [UInt8]
    /// Its samples, at its codec's clock.
    var samples: Int
    var sampleRate: Int
    var duration: Duration { .microseconds(Int64(samples) * 1_000_000 / Int64(max(sampleRate, 1))) }
}

/// The backchannel's audio track in a `DESCRIBE` answer (section 4.2).
struct Backchannel: Sendable, Equatable {
    enum Codec: Sendable, Equatable {
        case pcma, pcmu
        case aac(clock: Int)
    }

    var codec: Codec
    var payloadType: Int
    var control: String

    /// The `m=audio` section marked `a=sendonly`, PCMA first, then PCMU, then AAC; nil without one.
    static func parse(sdp: String) -> Backchannel? {
        var sections: [[String]] = []
        for line in sdp.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("m=") { sections.append([line]) } else if !sections.isEmpty { sections[sections.count - 1].append(line) }
        }
        var found: [Backchannel] = []
        for section in sections where section[0].hasPrefix("m=audio") && section.contains("a=sendonly") {
            let types = section[0].split(separator: " ").dropFirst(3).compactMap { Int($0) }
            guard let control = section.first(where: { $0.hasPrefix("a=control:") })?.dropFirst("a=control:".count) else { continue }
            var maps: [Int: String] = [:]
            for line in section where line.hasPrefix("a=rtpmap:") {
                let parts = line.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
                if parts.count == 2, let type = Int(parts[0]) { maps[type] = String(parts[1]) }
            }
            for type in types {
                let map = (maps[type] ?? (type == 8 ? "PCMA/8000" : type == 0 ? "PCMU/8000" : "")).uppercased()
                let codec: Codec?
                if map.hasPrefix("PCMA/") { codec = .pcma } else if map.hasPrefix("PCMU/") { codec = .pcmu } else if map.hasPrefix("MPEG4-GENERIC/") {
                    codec = .aac(clock: Int(map.split(separator: "/").dropFirst().first ?? "") ?? 16000)
                } else { codec = nil }
                if let codec { found.append(Backchannel(codec: codec, payloadType: type, control: String(control))) }
            }
        }
        func rank(_ channel: Backchannel) -> Int {
            switch channel.codec {
            case .pcma: 0
            case .pcmu: 1
            case .aac: 2
            }
        }
        return found.min { rank($0) < rank($1) }
    }

    /// The track's address: an absolute control, or one relative to the base with a `/` between them.
    func trackURL(base: String) -> String {
        if control.lowercased().hasPrefix("rtsp://") { return control }
        if control == "*" { return base }
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/" + control
    }
}

/// An RTP packet in an RTSP interleaved frame (section 4.2, step 5): `$`, the channel, the length, then the packet
/// (version 2, marker set).
func interleavedRTP(channel: UInt8, payloadType: Int, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: [UInt8]) -> [UInt8] {
    let length = 12 + payload.count
    var frame: [UInt8] = [0x24, channel, UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
    frame += [0x80, 0x80 | UInt8(payloadType & 0x7F), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
    frame += [UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF)]
    frame += [UInt8(ssrc >> 24), UInt8(ssrc >> 16 & 0xFF), UInt8(ssrc >> 8 & 0xFF), UInt8(ssrc & 0xFF)]
    return frame + payload
}

/// RTSP answers from a byte stream that may carry interleaved frames, which are skipped.
struct RTSPResponseReader: Sendable {
    struct Response: Sendable, Equatable {
        var status: Int
        var headers: [(String, String)]
        var body: [UInt8]

        func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

        static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
        }
    }

    static let maximum = 64 * 1024
    private var buffer: [UInt8] = []

    mutating func push(_ bytes: [UInt8]) -> [Response] {
        buffer += bytes
        var responses: [Response] = []
        while !buffer.isEmpty {
            if buffer[0] == 0x24 {
                guard buffer.count >= 4 else { break }
                let length = Int(buffer[2]) << 8 | Int(buffer[3])
                guard buffer.count >= 4 + length else { break }
                buffer.removeFirst(4 + length)
                continue
            }
            guard let end = Self.find([0x0D, 0x0A, 0x0D, 0x0A], in: buffer) else {
                if buffer.count > Self.maximum { buffer = [] }
                break
            }
            let head = String(decoding: buffer[..<end], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [(String, String)] = []
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers.append((line[..<colon].trimmingCharacters(in: .whitespaces), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
            let length = headers.first { $0.0.lowercased() == "content-length" }.flatMap { Int($0.1) }.map { min(max($0, 0), Self.maximum) } ?? 0
            guard buffer.count >= end + 4 + length else { break }
            let status = head.first.flatMap { line in line.split(separator: " ").dropFirst().first.flatMap { Int($0) } } ?? 0
            responses.append(Response(status: status, headers: headers, body: Array(buffer[(end + 4)..<(end + 4 + length)])))
            buffer.removeFirst(end + 4 + length)
        }
        return responses
    }

    static func find(_ needle: [UInt8], in bytes: [UInt8]) -> Int? {
        needle.isEmpty ? nil : bytes.firstRange(of: needle)?.lowerBound
    }
}

enum TalkError: Error, CustomStringConvertible, Equatable {
    /// The method is not there on this camera: the other one is used from the next Talk.
    case unavailable(String)
    /// Another client talks, or the camera allows only one.
    case busy
    case wrongPassword
    case failed(String)

    var description: String {
        switch self {
        case .unavailable(let reason): "not available on this camera (\(reason))"
        case .busy: "the camera's speaker is busy (another app is talking?)"
        case .wrongPassword: "the camera refused the user name and safety code"
        case .failed(let reason): reason
        }
    }
}

/// One camera's talk: a Talk at a time, by the method that works (section 6).
actor ImouTalk {
    struct Settings: Sendable {
        var host: String
        var httpPort: Int
        var rtspPort: Int
        /// The audio channel, 1-based.
        var channel: Int
        var codec: TalkCodec
        var method: TalkMethod
        /// Every backchannel packet with timestamp 0 (section 4.2, step 5), for a camera that plays nothing otherwise.
        var zeroTimestamps: Bool
    }

    /// The writes of `postAudio` and the backchannel's RTP payloads: 128 ms of G.711.
    static let pieceSize = 1024
    /// More pieces than this waiting means the camera reads slower than real time: the oldest go.
    static let queuedPieces = 3
    static let connectTimeout: Duration = .seconds(5)
    static let writeTimeout: Duration = .seconds(2)
    static let responseTimeout: Duration = .seconds(5)
    /// How long a Talk waits for the previous one to close.
    static let closingWait: Duration = .seconds(1)
    /// Audio still playing on the camera at the end: what was written in the last 300 ms, plus 200 ms.
    static let tailWindow: Duration = .milliseconds(300)
    static let tailMargin: Duration = .milliseconds(200)

    nonisolated let settings: Settings
    private let client: DahuaClient
    private let connect: TalkConnector
    private let ffmpeg: RTSPCameraFFmpeg?
    private let name: String
    private let log: Logger
    private let scale: Double

    private var httpUnavailable = false
    private var rtspUnavailable = false
    private var tail: Task<Void, Never>?
    private var warned: Set<String> = []

    init(settings: Settings, client: DahuaClient, connect: @escaping TalkConnector, ffmpeg: RTSPCameraFFmpeg?, name: String, log: Logger, scale: Double = 1) {
        self.settings = settings
        self.client = client
        self.connect = connect
        self.ffmpeg = ffmpeg
        self.name = name
        self.log = log
        self.scale = scale
    }

    nonisolated static let postTarget = "/cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel="

    /// The request target of `postAudio` for an audio channel.
    nonisolated static func postURI(channel: Int) -> String { postTarget + "\(channel)" }

    /// The head of `postAudio` (section 3.1), exactly.
    nonisolated static func postHead(host: String, port: Int, channel: Int, authorization: String?, codec: TalkCodec) -> String {
        var lines = ["POST \(postURI(channel: channel)) HTTP/1.1", "Host: \(hostHeader(host: host, port: port, defaultPort: 80))"]
        if let authorization { lines.append("Authorization: \(authorization)") }
        lines += ["Content-Type: \(codec.contentType)", "Content-Length: 9999999", "Connection: close"]
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// The backchannel's address: the main stream in Dahua's ONVIF session handling, without credentials (section 4.1).
    nonisolated static func backchannelURL(host: String, port: Int, channel: Int) -> String {
        "rtsp://\(hostHeader(host: host, port: port, defaultPort: -1))/cam/realmonitor?channel=\(channel)&subtype=0&unicast=true&proto=Onvif"
    }

    static let requireBackchannel = "www.onvif.org/ver20/backchannel"

    func duration(_ value: Duration) -> Duration { value * scale }

    /// The handler of the receiver: Talks one after another, a new one waiting at most a second for the last to close.
    func handle(_ talk: Talk) async {
        let previous = tail
        let closingWait = duration(Self.closingWait)
        let task = Task {
            if let previous {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await previous.value }
                    group.addTask { try? await Task.sleep(for: closingWait) }
                    await group.next()
                    group.cancelAll()
                }
            }
            await self.run(talk)
        }
        tail = task
        await task.value
    }

    /// Whether a method is known not to work, for tests.
    var unavailable: (http: Bool, rtsp: Bool) { (httpUnavailable, rtspUnavailable) }

    private func run(_ talk: Talk) async {
        let useHTTP: Bool
        switch settings.method {
        case .http: useHTTP = true
        case .rtsp: useHTTP = false
        case .auto: useHTTP = !httpUnavailable
        }
        if !useHTTP, settings.method == .auto, rtspUnavailable { return }
        let started = ContinuousClock.now
        let label = useHTTP ? "HTTP, \(settings.codec.rawValue)" : "RTSP"
        log.info("\(name): Talk started (\(label)).")
        do {
            if useHTTP { try await postAudio(talk) } else { try await backchannel(talk) }
            log.info("\(name): Talk ended (\(String(format: "%.1f", (ContinuousClock.now - started) / .seconds(1))) s).")
        } catch let error as TalkError {
            switch error {
            case .unavailable:
                if useHTTP { httpUnavailable = true } else { rtspUnavailable = true }
                warnOnce(useHTTP ? "http" : "rtsp", "\(name): two-way audio over \(useHTTP ? "HTTP" : "RTSP") is \(error)\(useHTTP && settings.method == .auto ? "; trying the RTSP backchannel next time" : "").")
            case .busy: warnOnce("busy", "\(name): \(error).")
            case .wrongPassword, .failed: log.warning("\(name): two-way audio failed: \(error).")
            }
        } catch {
            log.warning("\(name): two-way audio failed: \(error).")
        }
    }

    private func warnOnce(_ key: String, _ message: String) {
        guard warned.insert(key).inserted else { return }
        log.warning("\(message)")
    }

    // MARK: Audio

    /// The Talk's frames as the pieces written to the camera, at most three waiting (section 3.3). `rate` is the clock of
    /// what is written: G.711's 8 kHz, or the AAC track's, FFmpeg resampling the Talk's PCM to it (a receiver made for G.711
    /// gives 8 kHz, one for AAC 16 kHz, whatever track the backchannel offers).
    func pieces(_ talk: Talk, codec: TalkCodec, rate: Int) -> (AsyncStream<TalkPiece>, Task<Void, Never>) {
        let (pieces, continuation) = AsyncStream.makeStream(of: TalkPiece.self, bufferingPolicy: .bufferingNewest(Self.queuedPieces))
        let volume = talk.volume
        let inputRate = talk.format.sampleRate
        let ffmpeg = ffmpeg
        let task = Task {
            defer { continuation.finish() }
            switch codec {
            case .g711A, .g711Mu:
                var buffer: [UInt8] = []
                for await frame in talk.frames {
                    var samples = PCMVolume.scale(frame.samples, volume: volume)
                    if inputRate != 8000 { samples = Self.halve(samples) }
                    buffer += codec == .g711A ? G711.aLaw(samples) : G711.muLaw(samples)
                    while buffer.count >= Self.pieceSize {
                        continuation.yield(TalkPiece(bytes: Array(buffer.prefix(Self.pieceSize)), samples: Self.pieceSize, sampleRate: 8000))
                        buffer.removeFirst(Self.pieceSize)
                    }
                }
                if !buffer.isEmpty { continuation.yield(TalkPiece(bytes: buffer, samples: buffer.count, sampleRate: 8000)) }
            case .aac:
                guard let ffmpeg, let encoder = AACTalkEncoder(ffmpeg: ffmpeg, sampleRate: inputRate, outputRate: rate) else { return }
                let writer = Task {
                    for await frame in talk.frames {
                        do { try await encoder.write(PCMVolume.scale(frame.samples, volume: volume)) } catch { break }
                    }
                    encoder.finish()
                }
                await withTaskCancellationHandler {
                    for await frame in encoder.frames { continuation.yield(TalkPiece(bytes: frame, samples: 1024, sampleRate: rate)) }
                } onCancel: {
                    writer.cancel()
                    encoder.stop()
                }
                writer.cancel()
            }
        }
        return (pieces, task)
    }

    /// 16 kHz to 8 kHz: each pair of samples averaged.
    static func halve(_ samples: [Int16]) -> [Int16] {
        stride(from: 0, to: samples.count - 1, by: 2).map { Int16((Int(samples[$0]) + Int(samples[$0 + 1])) / 2) }
    }

    /// Sends `bytes` within the write timeout; a camera that does not read ends the Talk.
    private func write(_ stream: any ByteStream, _ bytes: [UInt8]) async throws {
        let timeout = duration(Self.writeTimeout)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await stream.send(bytes)
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            let written = try await group.next() ?? false
            group.cancelAll()
            if !written { throw TalkError.failed("the camera stopped reading the audio") }
        }
    }

    /// The audio still to play on the camera once the last piece is written (section 3.4).
    private func tailWait(_ written: [(at: ContinuousClock.Instant, duration: Duration)]) -> Duration {
        let window = duration(Self.tailWindow)
        let now = ContinuousClock.now
        let recent = written.filter { now - $0.at <= window }.reduce(Duration.zero) { $0 + $1.duration }
        return min(recent * scale, window) + duration(Self.tailMargin)
    }

    // MARK: postAudio (section 3)

    /// What the camera answered on the `postAudio` connection, read alongside the writes.
    private final class Answer: Sendable {
        struct State {
            var bytes: [UInt8] = []
            var status: Int?
            var challenge: String?
            var closed = false
        }

        let state = NIOLockedValueBox(State())

        func push(_ bytes: [UInt8]) {
            state.withLockedValue { state in
                guard state.status == nil else { return }
                state.bytes += bytes.prefix(8192 - state.bytes.count)
                guard let end = RTSPResponseReader.find([0x0D, 0x0A, 0x0D, 0x0A], in: state.bytes) ?? (state.bytes.count >= 8192 ? state.bytes.count : nil) else { return }
                let lines = String(decoding: state.bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n")
                state.status = lines.first.flatMap { $0.split(separator: " ").dropFirst().first.flatMap { Int($0) } } ?? 0
                let challenges = lines.dropFirst().filter { $0.lowercased().hasPrefix("www-authenticate:") }.map {
                    String($0.dropFirst("www-authenticate:".count)).trimmingCharacters(in: .whitespaces)
                }
                state.challenge = challenges.first { $0.lowercased().hasPrefix("digest") } ?? challenges.first
            }
        }

        func close() { state.withLockedValue { $0.closed = true } }
        var current: State { state.withLockedValue { $0 } }
    }

    private func postAudio(_ talk: Talk) async throws {
        let (pieces, producer) = pieces(talk, codec: settings.codec, rate: settings.codec.format.sampleRate)
        defer { producer.cancel() }
        var iterator = pieces.makeAsyncIterator()
        // The connection opens with the Talk, so that the camera's answer to the head (a 401) can come before the audio.
        var first: TalkPiece?
        var retried = false
        while true {
            let stream = try await open(port: settings.httpPort)
            let answer = Answer()
            let reader = Task {
                do { for try await bytes in stream.incoming { answer.push(bytes) } } catch {}
                answer.close()
            }
            let uri = Self.postURI(channel: settings.channel)
            let authorization = await client.postAuthorization(uri: uri)
            do {
                try await write(stream, Array(Self.postHead(host: settings.host, port: settings.httpPort, channel: settings.channel,
                                                            authorization: authorization, codec: settings.codec).utf8))
                var written: [(at: ContinuousClock.Instant, duration: Duration)] = []
                var piece = first
                if piece == nil { piece = await iterator.next() }
                first = nil
                while let current = piece {
                    let state = answer.current
                    if let status = state.status, status != 200 {
                        // The first piece goes out before the camera's answer to the head can come: a 401 then still means the
                        // head, and is retried with the new challenge (a 128 ms piece lost at most).
                        if status == 401, written.count <= 1, !retried, let challenge = state.challenge, await client.accept(challenge: challenge) {
                            throw Retry(piece: current)
                        }
                        throw Self.error(status: status, beforeAudio: written.count <= 1)
                    }
                    if state.closed { throw written.count < 2 ? TalkError.busy : TalkError.failed("the camera closed the connection") }
                    try await write(stream, current.bytes)
                    written.append((.now, current.duration))
                    written.removeAll { ContinuousClock.now - $0.at > duration(Self.tailWindow) * 4 }
                    piece = await iterator.next()
                }
                try await Task.sleep(for: tailWait(written))
                reader.cancel()
                await stream.close()
                if let status = answer.current.status, status != 200 { throw Self.error(status: status, beforeAudio: false) }
                return
            } catch let retry as Retry {
                reader.cancel()
                await stream.close()
                retried = true
                first = retry.piece
            } catch {
                reader.cancel()
                await stream.close()
                throw error
            }
        }
    }

    private struct Retry: Error {
        var piece: TalkPiece
    }

    static func error(status: Int, beforeAudio: Bool) -> TalkError {
        if status == 401 { return .wrongPassword }
        if status == 503 { return .busy }
        if beforeAudio, [400, 404, 501].contains(status) { return .unavailable("HTTP \(status)") }
        return .failed("the camera answered HTTP \(status)")
    }

    private func open(port: Int) async throws -> any ByteStream {
        do {
            return try await connect(settings.host, port, duration(Self.connectTimeout))
        } catch let error as HTTPClientError {
            if case .cannotConnect(_, _, let code, _) = error, code == 61 || code == 111 { throw TalkError.unavailable("connection refused") }
            throw TalkError.failed("\(error)")
        }
    }

    // MARK: The RTSP backchannel (section 4)

    /// An RTSP session's sequence and credentials: a 401 answered once with Digest, or Basic on old firmware that never
    /// offers Digest.
    private final class RTSPState: Sendable {
        struct Values {
            var digest: DigestAuthentication
            var basic: String
            var useBasic = false
            var digestOffered = false
            var sequence = 0
            var session: String?
        }

        let values: NIOLockedValueBox<Values>

        init(digest: DigestAuthentication, basic: String) {
            values = NIOLockedValueBox(Values(digest: digest, basic: basic))
        }

        func head(_ method: String, _ url: String, _ headers: [(String, String)]) -> [UInt8] {
            values.withLockedValue { values in
                values.sequence += 1
                var lines = ["\(method) \(url) RTSP/1.0", "CSeq: \(values.sequence)"]
                if values.useBasic {
                    lines.append("Authorization: \(values.basic)")
                } else if let authorization = values.digest.authorization(method: method, uri: url) {
                    lines.append("Authorization: \(authorization)")
                }
                if let session = values.session { lines.append("Session: \(session)") }
                lines += headers.map { "\($0.0): \($0.1)" }
                return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            }
        }

        /// Takes a 401's challenges (one `WWW-Authenticate` each): Digest whenever one is offered, Basic only on a camera
        /// that has offered no Digest in this session, so the password is never sent in the clear to one that can do better.
        /// False when there is nothing to answer.
        func accept(_ challenges: [String]) -> Bool {
            values.withLockedValue { values in
                if let digest = challenges.first(where: { $0.lowercased().hasPrefix("digest") }) {
                    values.digestOffered = true
                    values.useBasic = false
                    return values.digest.accept(challenge: digest)
                }
                guard !values.digestOffered, challenges.contains(where: { $0.lowercased().hasPrefix("basic") }) else { return false }
                values.useBasic = true
                return true
            }
        }

        func set(session: String?) { values.withLockedValue { $0.session = session } }
    }

    /// The answers on an RTSP connection, in order, interleaved frames skipped; nil once the connection ended.
    private final class Responses: Sendable {
        private struct State {
            var pending: [RTSPResponseReader.Response] = []
            var waiter: CheckedContinuation<RTSPResponseReader.Response?, Never>?
            var finished = false
        }

        private let state = NIOLockedValueBox(State())

        func push(_ response: RTSPResponseReader.Response) {
            state.withLockedValue { state -> CheckedContinuation<RTSPResponseReader.Response?, Never>? in
                guard let waiter = state.waiter else {
                    state.pending.append(response)
                    return nil
                }
                state.waiter = nil
                return waiter
            }?.resume(returning: response)
        }

        func finish() {
            state.withLockedValue { state -> CheckedContinuation<RTSPResponseReader.Response?, Never>? in
                state.finished = true
                defer { state.waiter = nil }
                return state.waiter
            }?.resume(returning: nil)
        }

        func next() async -> RTSPResponseReader.Response? {
            await withCheckedContinuation { continuation in
                let ready = state.withLockedValue { state -> RTSPResponseReader.Response?? in
                    if !state.pending.isEmpty { return .some(state.pending.removeFirst()) }
                    if state.finished { return .some(nil) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    private nonisolated static func responses(_ stream: any ByteStream) -> (Responses, Task<Void, Never>) {
        let responses = Responses()
        let reader = Task {
            var parser = RTSPResponseReader()
            do {
                for try await bytes in stream.incoming { for response in parser.push(bytes) { responses.push(response) } }
            } catch {}
            responses.finish()
        }
        return (responses, reader)
    }

    /// Sends a request and waits for its answer within the response timeout (a camera that does not answer has its
    /// connection closed); a 401 is answered once.
    private func request(_ stream: any ByteStream, _ state: RTSPState, _ responses: Responses, _ method: String, _ url: String,
                         _ headers: [(String, String)] = []) async throws -> RTSPResponseReader.Response {
        var answered = false
        while true {
            try await write(stream, state.head(method, url, headers))
            let timeout = duration(Self.responseTimeout)
            let timer = Task {
                try await Task.sleep(for: timeout)
                await stream.close()
            }
            let response = await responses.next()
            timer.cancel()
            guard let response else { throw TalkError.failed("the camera did not answer RTSP \(method)") }
            guard response.status == 401 else { return response }
            let challenges = response.headers.filter { $0.0.lowercased() == "www-authenticate" }.map(\.1)
            guard !answered, state.accept(challenges) else { throw TalkError.wrongPassword }
            answered = true
        }
    }

    /// Whether the camera's stream has a backchannel track: `DESCRIBE` with the backchannel `Require` (section 2, step 3).
    func probeBackchannel() async -> Bool {
        guard let stream = try? await open(port: settings.rtspPort) else { return false }
        let state = RTSPState(digest: await client.rtspDigest(), basic: await client.basicAuthorization())
        let (responses, reader) = Self.responses(stream)
        let url = Self.backchannelURL(host: settings.host, port: settings.rtspPort, channel: settings.channel)
        let response = try? await request(stream, state, responses, "DESCRIBE", url, [("Accept", "application/sdp"), ("Require", Self.requireBackchannel)])
        reader.cancel()
        await stream.close()
        guard let response, response.status == 200 else { return false }
        return Backchannel.parse(sdp: String(decoding: response.body, as: UTF8.self)) != nil
    }

    private func backchannel(_ talk: Talk) async throws {
        let stream = try await open(port: settings.rtspPort)
        let state = RTSPState(digest: await client.rtspDigest(), basic: await client.basicAuthorization())
        let (responses, reader) = Self.responses(stream)
        var keepAlive: Task<Void, Never>?
        defer {
            keepAlive?.cancel()
            reader.cancel()
        }
        do {
            var base = Self.backchannelURL(host: settings.host, port: settings.rtspPort, channel: settings.channel)
            let url = base
            let described = try await request(stream, state, responses, "DESCRIBE", url, [("Accept", "application/sdp"), ("Require", Self.requireBackchannel)])
            if described.status == 551 { throw TalkError.unavailable("no backchannel") }
            guard described.status == 200 else { throw TalkError.failed("the camera answered RTSP \(described.status) to DESCRIBE") }
            if let contentBase = described.header("Content-Base"), !contentBase.isEmpty { base = contentBase }
            guard let track = Backchannel.parse(sdp: String(decoding: described.body, as: UTF8.self)) else { throw TalkError.unavailable("no backchannel track") }
            let setup = try await request(stream, state, responses, "SETUP", track.trackURL(base: base),
                                          [("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1"), ("Require", Self.requireBackchannel)])
            if setup.status == 454 { throw TalkError.failed("the camera ended the RTSP session") }
            guard setup.status == 200 else { throw TalkError.busy }
            let sessionHeader = setup.header("Session") ?? ""
            let parts = sessionHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            state.set(session: parts.first)
            let timeout = parts.dropFirst().first { $0.lowercased().hasPrefix("timeout=") }.flatMap { Int($0.dropFirst("timeout=".count)) } ?? 60
            let channel = Self.interleavedChannel(setup.header("Transport")) ?? 0
            let played = try await request(stream, state, responses, "PLAY", url)
            guard played.status == 200 else { throw TalkError.failed("the camera answered RTSP \(played.status) to PLAY") }
            let interval = duration(.seconds(max(timeout, 2))) / 2
            keepAlive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    try? await self.write(stream, state.head("GET_PARAMETER", url, []))
                }
            }
            let codec: TalkCodec
            let rate: Int
            switch track.codec {
            case .pcma: (codec, rate) = (.g711A, 8000)
            case .pcmu: (codec, rate) = (.g711Mu, 8000)
            case .aac(let clock): (codec, rate) = (.aac, (8000...96000).contains(clock) ? clock : 16000)
            }
            let (pieces, producer) = pieces(talk, codec: codec, rate: rate)
            defer { producer.cancel() }
            let ssrc = UInt32.random(in: 0...UInt32.max)
            var sequence: UInt16 = 0
            var timestamp: UInt32 = 0
            var written: [(at: ContinuousClock.Instant, duration: Duration)] = []
            for await piece in pieces {
                let payload: [UInt8]
                if codec == .aac {
                    let unit = Array(ADTSFrameSplitter.payload(of: piece.bytes))
                    payload = [0x00, 0x10, UInt8(unit.count >> 5 & 0xFF), UInt8(unit.count << 3 & 0xF8)] + unit
                } else {
                    payload = piece.bytes
                }
                try await write(stream, interleavedRTP(channel: channel, payloadType: track.payloadType, sequence: sequence,
                                                            timestamp: settings.zeroTimestamps ? 0 : timestamp, ssrc: ssrc, payload: payload))
                written.append((.now, piece.duration))
                written.removeAll { ContinuousClock.now - $0.at > duration(Self.tailWindow) * 4 }
                sequence &+= 1
                timestamp &+= UInt32(piece.samples)
            }
            try await Task.sleep(for: tailWait(written))
            keepAlive?.cancel()
            try? await write(stream, state.head("TEARDOWN", url, []))
            await stream.close()
        } catch {
            await stream.close()
            throw error
        }
    }

    /// The first channel of an answered `Transport`'s `interleaved=`.
    static func interleavedChannel(_ transport: String?) -> UInt8? {
        guard let transport, let range = transport.range(of: "interleaved=") else { return nil }
        return UInt8(transport[range.upperBound...].prefix { $0.isNumber })
    }
}
