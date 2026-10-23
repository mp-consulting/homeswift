import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftUniFiProtect

/// The binary protocols: zlib, the realtime events packets (unifi-events.test.ts, protect-api-units.test.ts)
/// and the livestream packets (livestream-protocol.test.ts).
@Suite struct ProtocolTests {
    static let action: JSONValue = ["action": "update", "id": "evt1", "modelKey": "camera", "newUpdateId": "update1"]
    static let data: JSONValue = ["isMotionDetected": true, "name": "Front Door"]
    /// zlib.compress of the two JSON documents above, as the controller deflates them.
    static let actionDeflated = Data(base64Encoded: "eJyrVkpMLsnMz1OyUiotSEksSVXSUcpMAfJSy0oMgezc/JTUHO/USqBIcmJualEiUCwvtTwUrNYzBa7NUKkWAJxMGIQ=")!
    static let dataDeflated = Data(base64Encoded: "eJyrVsos9s0vyczPc0ktSU0uSU1RsiopKk3VUcpLzE1VslJyK8rPK1Fwyc8vUqoFAHm+D/c=")!

    static func frame(_ type: UInt8, _ payload: Data, deflated: Bool, format: UInt8 = 1) -> Data {
        let size = UInt32(payload.count)
        return Data([type, format, deflated ? 1 : 0, 0, UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]) + payload
    }

    @Test func inflatesZlib() throws {
        let fox = Data(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200).utf8)
        let dynamic = Data(base64Encoded: "eNrtyssRgjAUAMBWXgVUkwZAg38D0ahQvbTBzJ530znH3C6HWwy1fJ8xll9c22N6RfnkGu+N7/26xLGcukiyLMuyLMuyLMuyLMuyLMuyLMuyLMuyLMuyvM/8B4ZBny0=")!
        #expect(try Inflate.zlib(dynamic, maximumSize: 1 << 20) == fox)
        let stored = Data(base64Encoded: "eAEBDADz/2hlbGxvIHN0b3JlZB7VBMY=")!
        #expect(try Inflate.zlib(stored, maximumSize: 100) == Data("hello stored".utf8))
        let lorem = Data(base64Encoded: "eNolj8luxCAQRH+l5XNpZDYv+YZcc4pyIAaNWjLgMRBFivLvaWdO9Favip9hL2dMw8vwer3ER+2JQpEpVW7kU2ygreQatxZbP8kHPrhunO8Ud5ZljUEEFLnXVAK1mA4Rc944cOi5UW+0+0/BU2xPdKTk79mT3/nR/Y3eGsXMSdiU+Cq+pPUJ9OhcKZfazh4ofsdz4+Ybl0x9333aypN8HXHly+kfyYccU/QSPEmm8vyAWLXbgGHn2oaX9xEKGgYWDhNmLFihZKigNJSBslAOaoKaoRaoFXqEFo2GNtAW2kFP0DP0Ar3CjDAKRpAGxsI4mAlmhllgVtgRVsFqWHG0sA52gp1hF9gVboRTcBrOwEkgBzfBzXAL3Prx+wdVknzf")!
        let decoded = try JSONValue(data: Inflate.zlib(lorem, maximumSize: 1 << 20))
        #expect(decoded.array("list").count == 60)
        #expect(decoded.string("lorem")?.hasPrefix("Lorem ipsum") == true)
        // 1000 bytes inflate: allowed at the cap, refused below it.
        let cap = Data(base64Encoded: "eJxLTBwFo2AUDHcAAPnYevg=")!
        #expect(try Inflate.zlib(cap, maximumSize: 1000).count == 1000)
        #expect(throws: Inflate.Failure.tooLarge(999)) { try Inflate.zlib(cap, maximumSize: 999) }
        #expect(throws: Inflate.Failure.self) { try Inflate.zlib(Data([0xDE, 0xAD, 0xBE, 0xEF]), maximumSize: 100) }
        var corrupt = [UInt8](stored)
        corrupt[corrupt.count - 1] ^= 0xFF
        #expect(throws: Inflate.Failure.checksumMismatch) { try Inflate.zlib(Data(corrupt), maximumSize: 100) }
    }

    @Test func decodesEventPackets() throws {
        let deflated = Self.frame(1, Self.actionDeflated, deflated: true) + Self.frame(2, Self.dataDeflated, deflated: true)
        let packet = try ProtectEventPacket.decode(deflated)
        #expect(packet.header == Self.action && packet.payload == Self.data)
        #expect(packet.action == "update" && packet.id == "evt1" && packet.modelKey == "camera")
        let plain = ProtectEventPacket.encode(header: Self.action, payload: Self.data)
        #expect(try ProtectEventPacket.decode(plain) == packet)
        // A string payload and raw bytes.
        let text = try ProtectEventPacket.decode(Self.frame(1, Self.action.encoded(), deflated: false) + Self.frame(2, Data("hello".utf8), deflated: false, format: 2))
        #expect(text.payload == "hello")
    }

    @Test func rejectsBrokenPackets() {
        #expect(throws: ProtectEventPacket.DecodeError.lengthMismatch) { try ProtectEventPacket.decode(Data([1, 2, 3])) }
        var packet = [UInt8](ProtectEventPacket.encode(header: Self.action, payload: Self.data))
        packet[7] &+= 5
        #expect(throws: ProtectEventPacket.DecodeError.self) { try ProtectEventPacket.decode(Data(packet)) }
        let garbage = Self.frame(1, Data([0xDE, 0xAD, 0xBE, 0xEF]), deflated: true)
        #expect(throws: ProtectEventPacket.DecodeError.self) { try ProtectEventPacket.decode(garbage + Self.frame(2, Data([0xDE, 0xAD, 0xBE, 0xEF]), deflated: true)) }
        #expect(throws: ProtectEventPacket.DecodeError.unknownPayloadFormat(9)) {
            try ProtectEventPacket.decode(Self.frame(1, Self.action.encoded(), deflated: false) + Self.frame(2, Data("x".utf8), deflated: false, format: 9))
        }
    }

    // MARK: Livestream

    static func livePacket(_ type: UInt8, _ payload: Data = Data()) -> Data {
        Data([type, UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)]) + payload
    }

    @Test func assemblesSegments() throws {
        var parser = ProtectLivestreamParser()
        let moof1 = Data(repeating: 1, count: 16), moof2 = Data(repeating: 2, count: 8), mdat = Data(repeating: 3, count: 32)
        let video = Data(repeating: 4, count: 12), audio = Data(repeating: 5, count: 6)
        let message = Self.livePacket(249) + Self.livePacket(251, moof1) + Self.livePacket(251, moof2) + Self.livePacket(254, mdat) + Self.livePacket(252, video)
            + Self.livePacket(253, audio) + Self.livePacket(255)
        let outputs = try parser.feed(message)
        #expect(outputs == [.segment(moof1 + moof2 + mdat + video + audio, moof: moof1 + moof2, mdat: mdat)])
    }

    @Test func reassemblesSplitPackets() throws {
        var parser = ProtectLivestreamParser()
        let initPayload = Data(repeating: 0xAB, count: 30)
        let packetA = Self.livePacket(250, initPayload), packetB = Self.livePacket(248, Data("avc1.640028,mp4a.40.2".utf8))
        #expect(try parser.feed(packetA.prefix(2)).isEmpty)
        #expect(try parser.feed(packetA.subdata(in: 2..<20)).isEmpty)
        #expect(try parser.feed(packetA.subdata(in: 20..<packetA.count) + packetB.prefix(3)) == [.initSegment(initPayload)])
        #expect(try parser.feed(packetB.subdata(in: 3..<packetB.count)) == [.codec("avc1.640028,mp4a.40.2")])
    }

    @Test func timestampsAndBadHeaders() throws {
        var parser = ProtectLivestreamParser()
        var payload = Data()
        for value in [UInt64(90000), 180000] { payload += withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        #expect(try parser.feed(Self.livePacket(247, payload)) == [.timestamps([90000, 180000])])
        #expect(throws: ProtectLivestreamParser.InvalidHeader(header: 42)) { try parser.feed(Self.livePacket(42, Data("garbage".utf8))) }
    }
}

/// A livestream session over a fake controller and WebSocket.
@Suite(.timeLimit(.minutes(1))) struct LivestreamSessionTests {
    func makeAPI(_ controller: FakeController, _ sockets: FakeWebSocketConnector, scale: Double = 0.01) async -> ProtectAPI {
        let api = ProtectAPI(log: ProtectLog(logger: testLogger), options: .init(transport: controller, webSockets: sockets.factory, timeScale: scale, connectsEvents: false))
        _ = await api.login(address: "192.168.1.1", username: "homeswift", password: "secret")
        return api
    }

    final class Recorder: @unchecked Sendable {
        let events = NIOLockedValueBox<[String]>([])
        let segments = NIOLockedValueBox<[Data]>([])

        func record(_ event: ProtectLivestream.Event) {
            switch event {
            case .close: events.withLockedValue { $0.append("close") }
            case .codec(let codec): events.withLockedValue { $0.append("codec:" + codec) }
            case .initSegment: events.withLockedValue { $0.append("init") }
            case .segment(let data): segments.withLockedValue { $0.append(data) }
            default: break
            }
        }

        var count: (String) -> Int { { name in self.events.withLockedValue { $0.filter { $0 == name }.count } } }
    }

    @Test func requestsTheEndpointAndDeliversSegments() async throws {
        let controller = FakeController(), sockets = FakeWebSocketConnector()
        let api = await makeAPI(controller, sockets)
        let livestream = ProtectLivestream(api: api, log: ProtectLog(logger: testLogger))
        let recorder = Recorder()
        livestream.observe { recorder.record($0) }
        #expect(await livestream.start(cameraID: "cam123", channel: 1, options: .init(emitTimestamps: true, segmentLength: 50)))
        let request = try #require(controller.requests("/proxy/protect/api/ws/livestream").first)
        let query = URLComponents(string: "https://x/?" + (request.query ?? ""))?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        #expect(value("camera") == "cam123" && value("channel") == "1" && value("chunkSize") == "4096" && value("fragmentDurationMillis") == "100")
        #expect(value("lens") == "0" && value("requestId") == "cam123-1" && value("type") == "fmp4" && value("rebaseTimestampsToZero") == "true")
        #expect(value("extendedVideoMetadata") == "")
        let socket = try #require(sockets.last)
        // The controller's URL, on the address we use.
        #expect(socket.url?.host == "192.168.1.1")
        let pending = Task { try await livestream.getInitSegment() }
        socket.push(ProtocolTests.livePacket(250, Data("ftypmoov".utf8)))
        #expect(try await pending.value == Data("ftypmoov".utf8))
        #expect(try await livestream.getInitSegment() == Data("ftypmoov".utf8))
        socket.push(ProtocolTests.livePacket(249) + ProtocolTests.livePacket(251, Data([1])) + ProtocolTests.livePacket(254, Data([2])) + ProtocolTests.livePacket(255))
        #expect(await eventually { recorder.segments.withLockedValue { $0 } == [Data([1, 2])] })
        livestream.stop()
        livestream.stop()
        #expect(recorder.count("close") == 1)
        #expect(await eventually { socket.isClosed })
    }

    @Test func failsWithoutAnEndpoint() async {
        let controller = FakeController(), sockets = FakeWebSocketConnector()
        let api = await makeAPI(controller, sockets)
        controller.update { $0.failEverything = 500 }
        let logs = LogCapture()
        let livestream = ProtectLivestream(api: api, log: ProtectLog(logger: logs.logger))
        #expect(await !livestream.start(cameraID: "cam123", channel: 1))
        #expect(logs.contains("unable to retrieve the livestream websocket API endpoint"))
        await #expect(throws: ProtectLivestream.LivestreamError.noSession) { try await livestream.getInitSegment() }
    }

    @Test func closesOnceWhateverEndsIt() async throws {
        let controller = FakeController(), sockets = FakeWebSocketConnector()
        let api = await makeAPI(controller, sockets)
        let logs = LogCapture()
        let livestream = ProtectLivestream(api: api, log: ProtectLog(logger: logs.logger))
        let recorder = Recorder()
        livestream.observe { recorder.record($0) }

        // A server close fails a pending init segment request.
        #expect(await livestream.start(cameraID: "cam", channel: 0))
        let pending = Task { try await livestream.getInitSegment() }
        try await Task.sleep(for: .milliseconds(50))
        try #require(sockets.last).serverClose()
        await #expect(throws: ProtectLivestream.LivestreamError.aborted) { try await pending.value }
        #expect(await eventually { recorder.count("close") == 1 })

        // An invalid header tears the session down.
        #expect(await livestream.start(cameraID: "cam", channel: 0))
        try #require(sockets.last).push(ProtocolTests.livePacket(42, Data("garbage".utf8)))
        #expect(await eventually { recorder.count("close") == 2 })
        #expect(logs.contains("Invalid header found while decoding the livestream: 42"))

        // The heartbeat closes a silent session (10 s, scaled).
        #expect(await livestream.start(cameraID: "cam", channel: 0))
        #expect(await eventually { recorder.count("close") == 3 })
        #expect(logs.contains("the livestream API is not responding."))
    }

    @Test func streamMode() async throws {
        let controller = FakeController(), sockets = FakeWebSocketConnector()
        let api = await makeAPI(controller, sockets)
        let livestream = ProtectLivestream(api: api, log: ProtectLog(logger: testLogger))
        let recorder = Recorder()
        livestream.observe { recorder.record($0) }
        #expect(await livestream.start(cameraID: "cam", channel: 0, options: .init(useStream: true)))
        let stream = try #require(livestream.stream)
        let socket = try #require(sockets.last)
        socket.push(ProtocolTests.livePacket(248, Data("avc1,mp4a".utf8)) + ProtocolTests.livePacket(250, Data("init".utf8)) + ProtocolTests.livePacket(249)
            + ProtocolTests.livePacket(251, Data([7])) + ProtocolTests.livePacket(254, Data([8])) + ProtocolTests.livePacket(255))
        var chunks: [Data] = []
        for await chunk in stream {
            chunks.append(chunk)
            if chunks.count == 2 { break }
        }
        #expect(chunks == [Data("init".utf8), Data([7, 8])])
        #expect(recorder.count("init") == 0 && recorder.count("codec:avc1,mp4a") == 0)
        #expect(livestream.codec == "avc1,mp4a")
        livestream.stop()
    }
}
