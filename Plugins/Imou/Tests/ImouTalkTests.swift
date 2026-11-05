import Foundation
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftImou

// docs/clean-room/ImouTalk.md: section 9's vectors, `postAudio` and the RTSP backchannel against a fake camera in memory,
// and the Speaker a camera gets only when it talks.

/// One connection to the fake camera: what the plugin sends, each `send` on its own, and what the camera answers.
final class FakeTalkConnection: ByteStream, Sendable {
    let port: Int
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let onSend: @Sendable (FakeTalkConnection, [UInt8]) -> Void
    let sends = NIOLockedValueBox<[[UInt8]]>([])
    let closed = NIOLockedValueBox(false)

    init(port: Int, onSend: @escaping @Sendable (FakeTalkConnection, [UInt8]) -> Void) {
        self.port = port
        self.onSend = onSend
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !closed.withLockedValue({ $0 }) else { throw HTTPClientError.connectionClosed }
        sends.withLockedValue { $0.append(bytes) }
        onSend(self, bytes)
    }

    func answer(_ text: String) { continuation.yield(Array(text.utf8)) }
    func answer(_ bytes: [UInt8]) { continuation.yield(bytes) }

    func close() async {
        closed.withLockedValue { $0 = true }
        continuation.finish()
    }

    var allSends: [[UInt8]] { sends.withLockedValue { $0 } }
    var isClosed: Bool { closed.withLockedValue { $0 } }
}

/// The camera's `postAudio` and RTSP server in memory.
final class FakeTalkCamera: Sendable {
    enum HTTPMode: Sendable { case accept, unauthorizedOnce, notFound, refused }

    struct State {
        var connections: [FakeTalkConnection] = []
        var http = HTTPMode.accept
        var rtspSDP = backchannelSDP
        var rtspRefused = false
    }

    static let backchannelSDP = """
        v=0\r
        o=- 2251938198 2251938198 IN IP4 0.0.0.0\r
        s=Media Server\r
        c=IN IP4 0.0.0.0\r
        t=0 0\r
        a=control:*\r
        m=video 0 RTP/AVP 96\r
        a=control:trackID=0\r
        a=rtpmap:96 H264/90000\r
        a=recvonly\r
        m=audio 0 RTP/AVP 8\r
        a=control:trackID=1\r
        a=rtpmap:8 PCMA/8000\r
        a=recvonly\r
        m=audio 0 RTP/AVP 8\r
        a=control:trackID=5\r
        a=rtpmap:8 PCMA/8000\r
        a=sendonly\r

        """

    let state = NIOLockedValueBox(State())
    let camera: FakeCamera
    let rtspNonce = "9c8bbb2a1bd1d3b4b8a3f1b4ad2e2d01"

    init(camera: FakeCamera) { self.camera = camera }

    var connections: [FakeTalkConnection] { state.withLockedValue { $0.connections } }
    func connections(port: Int) -> [FakeTalkConnection] { connections.filter { $0.port == port } }

    var connector: TalkConnector {
        { [self] _, port, _ in
            let (mode, refused) = state.withLockedValue { ($0.http, $0.rtspRefused) }
            if port == 554 ? refused : mode == .refused { throw HTTPClientError.cannotConnect(host: "camera", port: port, code: 61, reason: "refused") }
            let connection = FakeTalkConnection(port: port) { [weak self] connection, bytes in self?.received(bytes, on: connection) }
            state.withLockedValue { $0.connections.append(connection) }
            return connection
        }
    }

    private func fields(_ header: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in header.dropFirst("Digest ".count).components(separatedBy: ", ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return fields
    }

    private func header(_ name: String, in lines: [String]) -> String? {
        lines.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    private func received(_ bytes: [UInt8], on connection: FakeTalkConnection) {
        if connection.port == 554 { rtsp(bytes, on: connection) } else { http(bytes, on: connection) }
    }

    /// The head of a POST: answered at once, as a camera that has read it.
    private func http(_ bytes: [UInt8], on connection: FakeTalkConnection) {
        guard connection.allSends.count == 1 else { return }
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let mode = state.withLockedValue { $0.http }
        let index = connections(port: 80).count
        switch mode {
        case .notFound:
            connection.answer("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        case .unauthorizedOnce where index == 1:
            connection.answer("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"Login to \(camera.serial)\",qop=\"auth\",nonce=\"fresh\",opaque=\"abcd\"\r\nContent-Length: 0\r\n\r\n")
        default:
            break
        }
    }

    /// Whether a POST's Digest answers for `nonce`.
    func validPost(_ head: String, nonce: String) -> Bool {
        let lines = head.components(separatedBy: "\r\n")
        guard let authorization = header("Authorization", in: lines) else { return false }
        let f = fields(authorization)
        let uri = "/cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1"
        let ha1 = md5("admin:Login to \(camera.serial):\(camera.password)"), ha2 = md5("POST:\(uri)")
        return f["uri"] == uri && f["nonce"] == nonce && f["response"] == md5("\(ha1):\(nonce):\(f["nc"] ?? ""):\(f["cnonce"] ?? ""):auth:\(ha2)")
    }

    private func rtsp(_ bytes: [UInt8], on connection: FakeTalkConnection) {
        guard bytes.first != 0x24 else { return }
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ").map(String.init)
        guard parts.count == 3 else { return }
        let (method, url) = (parts[0], parts[1])
        let cseq = header("CSeq", in: lines) ?? "0"
        func reply(_ status: String, _ headers: [String] = [], body: String = "") {
            let all = ["RTSP/1.0 \(status)", "CSeq: \(cseq)"] + headers + ["Content-Length: \(body.utf8.count)"]
            connection.answer(all.joined(separator: "\r\n") + "\r\n\r\n" + body)
        }
        guard let authorization = header("Authorization", in: lines) else {
            return reply("401 Unauthorized", ["WWW-Authenticate: Digest realm=\"Login to \(camera.serial)\", nonce=\"\(rtspNonce)\""])
        }
        let f = fields(authorization)
        let ha1 = md5("admin:Login to \(camera.serial):\(camera.password)")
        guard f["uri"] == url, f["response"] == md5("\(ha1):\(rtspNonce):\(md5("\(method):\(url)"))") else { return reply("401 Unauthorized") }
        switch method {
        case "DESCRIBE":
            guard header("Require", in: lines) == "www.onvif.org/ver20/backchannel" else { return reply("551 Option not supported") }
            reply("200 OK", ["Content-Type: application/sdp", "Content-Base: \(url)/"], body: state.withLockedValue { $0.rtspSDP })
        case "SETUP":
            reply("200 OK", ["Session: 12345678;timeout=60", "Transport: RTP/AVP/TCP;unicast;interleaved=2-3"])
        case "PLAY", "GET_PARAMETER", "TEARDOWN":
            reply("200 OK", ["Session: 12345678"])
        default:
            reply("405 Method Not Allowed")
        }
    }
}

/// A Talk the test feeds.
func makeTalk(rate: Int = 8000, volume: Int = 100) -> (Talk, AsyncStream<PCMFrame>.Continuation) {
    let (frames, continuation) = AsyncStream.makeStream(of: PCMFrame.self)
    return (Talk(sessionID: "session", format: ReturnAudioFormat(sampleRate: rate), frames: frames, volume: volume), continuation)
}

/// `count` frames of 20 ms at 8 kHz, a few milliseconds apart (the camera's pace is the stream's).
func feed(_ continuation: AsyncStream<PCMFrame>.Continuation, count: Int, sample: Int16 = 1000) async {
    for index in 0..<count {
        continuation.yield(PCMFrame(samples: Array(repeating: sample, count: 160), offset: index * 160))
        try? await Task.sleep(for: .milliseconds(1))
    }
    continuation.finish()
}

@Suite struct ImouTalkVectorTests {
    @Test func postDigestMatchesTheVector() throws {
        var digest = DigestAuthentication(username: "admin", password: "ABCD1234")
        let accepted = digest.accept(challenge: "Digest realm=\"Login to 2J0123456789ABC\", qop=\"auth\", nonce=\"000562fdY631973ef04f77a3ede7c1832ff48720ef95ad\"")
        #expect(accepted)
        let authorization = digest.authorization(method: "POST", uri: ImouTalk.postURI(channel: 1), cnonce: "0a4f113b")
        let header = try #require(authorization)
        #expect(header == "Digest username=\"admin\", realm=\"Login to 2J0123456789ABC\", nonce=\"000562fdY631973ef04f77a3ede7c1832ff48720ef95ad\", uri=\"/cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1\", response=\"d78deb64da2e419ab09192d3851f578a\", qop=auth, nc=00000001, cnonce=\"0a4f113b\"")
        #expect(ImouTalk.postHead(host: "192.168.1.40", port: 80, channel: 1, authorization: "Digest x", codec: .g711A) ==
            "POST /cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1 HTTP/1.1\r\nHost: 192.168.1.40\r\nAuthorization: Digest x\r\nContent-Type: Audio/G.711A\r\nContent-Length: 9999999\r\nConnection: close\r\n\r\n")
        #expect(ImouTalk.postHead(host: "cam", port: 8080, channel: 2, authorization: nil, codec: .g711Mu).contains("Host: cam:8080\r\nContent-Type: Audio/G.711Mu\r\n"))
    }

    @Test func rtspDigestMatchesTheVector() throws {
        var digest = DigestAuthentication(username: "admin", password: "ABCD1234")
        let accepted = digest.accept(challenge: "Digest realm=\"Login to 2J0123456789ABC\", nonce=\"9c8bbb2a1bd1d3b4b8a3f1b4ad2e2d01\"")
        #expect(accepted)
        let url = ImouTalk.backchannelURL(host: "192.168.1.40", port: 554, channel: 1)
        #expect(url == "rtsp://192.168.1.40:554/cam/realmonitor?channel=1&subtype=0&unicast=true&proto=Onvif")
        let authorization = digest.authorization(method: "DESCRIBE", uri: url)
        #expect(authorization?.contains("response=\"079b350a8538b869e1d1d5bbb22924ed\"") == true)
    }

    @Test func speakerProbeAnswers() {
        #expect(DahuaClient.audioOutputs("result=1\r\n") == 1)
        #expect(DahuaClient.audioOutputs("result=0\r\n") == 0)
        #expect(DahuaClient.audioOutputs("result=2") == 2)
        #expect(DahuaClient.audioOutputs("Error\r\nBad Request!\r\n") == nil)
    }

    @Test func backchannelSDP() {
        let track = Backchannel.parse(sdp: FakeTalkCamera.backchannelSDP)
        #expect(track == Backchannel(codec: .pcma, payloadType: 8, control: "trackID=5"))
        #expect(track?.trackURL(base: "rtsp://cam/x/") == "rtsp://cam/x/trackID=5")
        #expect(track?.trackURL(base: "rtsp://cam/x") == "rtsp://cam/x/trackID=5")
        #expect(Backchannel.parse(sdp: "m=audio 0 RTP/AVP 8\r\na=control:trackID=1\r\na=recvonly\r\n") == nil)
        let aac = "m=audio 0 RTP/AVP 97 0\r\na=control:rtsp://cam/t\r\na=rtpmap:97 MPEG4-GENERIC/16000/1\r\na=rtpmap:0 PCMU/8000\r\na=sendonly\r\n"
        #expect(Backchannel.parse(sdp: aac) == Backchannel(codec: .pcmu, payloadType: 0, control: "rtsp://cam/t"))
    }

    @Test func interleavedRTPMatchesTheVector() {
        let payload = [UInt8](repeating: 0xD5, count: 1024)
        let first = interleavedRTP(channel: 2, payloadType: 8, sequence: 0, timestamp: 0, ssrc: 0x1234_5678, payload: payload)
        #expect(Array(first.prefix(16)) == [0x24, 0x02, 0x04, 0x0C, 0x80, 0x88, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34, 0x56, 0x78])
        let second = interleavedRTP(channel: 2, payloadType: 8, sequence: 1, timestamp: 1024, ssrc: 0x1234_5678, payload: payload)
        #expect(Array(second[4..<16]) == [0x80, 0x88, 0x00, 0x01, 0x00, 0x00, 0x04, 0x00, 0x12, 0x34, 0x56, 0x78])
    }

    @Test func rtspAnswersSkipInterleavedFrames() {
        var reader = RTSPResponseReader()
        let bytes = Array("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 3\r\n\r\nabc".utf8) + [0x24, 0x01, 0x00, 0x02, 0xAA, 0xBB] + Array("RTSP/1.0 454 Session Not Found\r\n\r\n".utf8)
        let first = reader.push(Array(bytes.prefix(20)))
        let rest = reader.push(Array(bytes.dropFirst(20)))
        #expect(first.isEmpty)
        #expect(rest.map(\.status) == [200, 454] && rest[0].body == Array("abc".utf8) && rest[0].header("cseq") == "1")
    }
}

@Suite struct ImouTalkTests {
    struct Fixture {
        let camera: FakeCamera
        let talkCamera: FakeTalkCamera
        let talk: ImouTalk
        let log: LogCollector
    }

    func fixture(method: TalkMethod = .auto, codec: TalkCodec = .g711A) -> Fixture {
        let camera = FakeCamera()
        let talkCamera = FakeTalkCamera(camera: camera)
        let log = LogCollector()
        var logger = Logger(label: "talk") { _ in log }
        logger.logLevel = .trace
        let client = DahuaClient(host: "192.0.2.20", port: 80, username: "admin", password: camera.password, transport: camera)!
        let talk = ImouTalk(settings: .init(host: "192.0.2.20", httpPort: 80, rtspPort: 554, channel: 1, codec: codec, method: method, zeroTimestamps: false),
                            client: client, connect: talkCamera.connector, ffmpeg: nil, name: "Porch", log: logger, scale: 0.05)
        return Fixture(camera: camera, talkCamera: talkCamera, talk: talk, log: log)
    }

    @Test func postAudioSendsALawInPiecesOf1024() async throws {
        let f = fixture()
        let (talk, frames) = makeTalk()
        async let handled: Void = f.talk.handle(talk)
        await feed(frames, count: 100)
        await handled
        let connection = try #require(f.talkCamera.connections(port: 80).first)
        let sends = connection.allSends
        let head = String(decoding: sends[0], as: UTF8.self)
        #expect(head.hasPrefix("POST /cgi-bin/audio.cgi?action=postAudio&httptype=singlepart&channel=1 HTTP/1.1\r\nHost: 192.0.2.20\r\nAuthorization: Digest "))
        #expect(head.hasSuffix("\r\nContent-Type: Audio/G.711A\r\nContent-Length: 9999999\r\nConnection: close\r\n\r\n"))
        #expect(f.talkCamera.validPost(head, nonce: f.camera.nonce))
        // A 2-second Talk: 16,000 bytes of A-law in 15 writes of 1024 and one of 640 (section 9.6).
        #expect(sends.dropFirst().map(\.count) == Array(repeating: 1024, count: 15) + [640])
        #expect(sends.dropFirst().joined().allSatisfy { $0 == 0xFA })
        #expect(connection.isClosed)
        // The fresh challenge came from the cheap GET (section 3.2).
        #expect(f.camera.targets.contains(DahuaClient.audioOutputTarget))
        #expect(f.log.lines.withLockedValue { $0 }.contains { $0.hasPrefix("Porch: Talk started (HTTP, G.711A).") })
        #expect(!f.log.lines.withLockedValue { $0 }.contains { $0.contains(f.camera.password) || $0.contains("Digest") })
    }

    @Test func theVolumeScalesTheSamples() async throws {
        let f = fixture(codec: .g711Mu)
        let (talk, frames) = makeTalk(volume: 50)
        async let handled: Void = f.talk.handle(talk)
        await feed(frames, count: 7, sample: 2000)
        await handled
        let sends = try #require(f.talkCamera.connections(port: 80).first).allSends
        #expect(String(decoding: sends[0], as: UTF8.self).contains("Content-Type: Audio/G.711Mu"))
        #expect(sends.dropFirst().joined().allSatisfy { $0 == G711.muLaw(1000) })
    }

    @Test func a401BeforeTheBodyIsAnsweredOnANewConnection() async throws {
        let f = fixture()
        f.talkCamera.state.withLockedValue { $0.http = .unauthorizedOnce }
        let (talk, frames) = makeTalk()
        async let handled: Void = f.talk.handle(talk)
        // The camera's 401 arrives before the first piece is ready.
        #expect(await eventually { f.talkCamera.connections(port: 80).count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        await feed(frames, count: 20)
        await handled
        let connections = f.talkCamera.connections(port: 80)
        #expect(connections.count == 2)
        #expect(connections[0].allSends.count == 1)
        let retry = String(decoding: connections[1].allSends[0], as: UTF8.self)
        #expect(f.talkCamera.validPost(retry, nonce: "fresh"))
        #expect(connections[1].allSends.dropFirst().map(\.count).reduce(0, +) == 3200)
    }

    @Test func aCameraWithoutPostAudioFallsBackToTheBackchannel() async throws {
        let f = fixture()
        f.talkCamera.state.withLockedValue { $0.http = .notFound }
        let (first, firstFrames) = makeTalk()
        async let handled: Void = f.talk.handle(first)
        #expect(await eventually { f.talkCamera.connections(port: 80).count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        await feed(firstFrames, count: 20)
        await handled
        #expect(await f.talk.unavailable.http)
        #expect(f.log.lines.withLockedValue { $0 }.contains { $0.contains("trying the RTSP backchannel next time") })

        let (second, secondFrames) = makeTalk()
        async let again: Void = f.talk.handle(second)
        await feed(secondFrames, count: 20)
        await again
        let rtsp = try #require(f.talkCamera.connections(port: 554).first)
        let sends = rtsp.allSends
        let requests = sends.filter { $0.first != 0x24 }.map { String(decoding: $0, as: UTF8.self).components(separatedBy: " ")[0] }
        #expect(requests == ["DESCRIBE", "DESCRIBE", "SETUP", "PLAY", "TEARDOWN"])
        let setup = String(decoding: sends.first { String(decoding: $0, as: UTF8.self).hasPrefix("SETUP") } ?? [], as: UTF8.self)
        let url = ImouTalk.backchannelURL(host: "192.0.2.20", port: 554, channel: 1)
        #expect(setup.hasPrefix("SETUP \(url)/trackID=5 RTSP/1.0\r\n"))
        #expect(setup.contains("Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n") && setup.contains("Require: www.onvif.org/ver20/backchannel\r\n"))
        let play = String(decoding: sends.first { String(decoding: $0, as: UTF8.self).hasPrefix("PLAY") } ?? [], as: UTF8.self)
        #expect(play.contains("Session: 12345678\r\n"))
        // 3200 bytes of A-law: three packets of 1024 and one of 128, on the channel the camera answered, timestamps advancing.
        let packets = sends.filter { $0.first == 0x24 }
        #expect(packets.map { $0.count - 16 } == [1024, 1024, 1024, 128])
        #expect(packets.allSatisfy { $0[1] == 2 && $0[5] == 0x88 })
        #expect(packets.map { UInt32($0[8]) << 24 | UInt32($0[9]) << 16 | UInt32($0[10]) << 8 | UInt32($0[11]) } == [0, 1024, 2048, 3072])
        #expect(rtsp.isClosed)
    }

    @Test func aRefusedPostAudioIsUnavailable() async {
        let f = fixture(method: .http)
        f.talkCamera.state.withLockedValue { $0.http = .refused }
        let (talk, frames) = makeTalk()
        async let handled: Void = f.talk.handle(talk)
        await feed(frames, count: 10)
        await handled
        #expect(await f.talk.unavailable.http)
        #expect(f.talkCamera.connections.isEmpty)
    }

    @Test func probesTheBackchannel() async {
        let f = fixture()
        #expect(await f.talk.probeBackchannel())
        f.talkCamera.state.withLockedValue { $0.rtspSDP = "v=0\r\nm=video 0 RTP/AVP 96\r\na=control:trackID=0\r\n" }
        #expect(await !f.talk.probeBackchannel())
    }
}

@Suite struct ImouTwoWayAudioTests {
    static let id = ImouPlugin.accessoryID(deviceID: "TEST000CAM1", channel: "0")

    func speaker(_ twoWayAudio: String?, audioOutput: String?) async throws -> Bool {
        let environment = TestEnvironment()
        environment.camera.state.withLockedValue { $0.audioOutput = audioOutput }
        var device: [String: Any] = ["deviceId": "TEST000CAM1", "host": "192.0.2.20", "password": "L2A3B4C5"]
        if let twoWayAudio { device["twoWayAudio"] = twoWayAudio }
        let host = try await environment.start(["devices": [device]])
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.id) != nil })
        let accessory = try #require(environment.accessory(host, Self.id))
        return accessory.services.contains { $0.type.uuid == ServiceType.speaker.uuid }
    }

    @Test func offByDefault() async throws {
        #expect(try await !speaker(nil, audioOutput: "result=1\r\n"))
    }

    @Test func autoAsksTheCamera() async throws {
        #expect(try await speaker("auto", audioOutput: "result=1\r\n"))
        #expect(try await !speaker("auto", audioOutput: "result=0\r\n"))
    }

    @Test func onForcesIt() async throws {
        #expect(try await speaker("on", audioOutput: nil))
    }
}
