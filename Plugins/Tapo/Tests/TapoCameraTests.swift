import Crypto
import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin
import Testing
import _CryptoExtras

@testable import HomeswiftTapo

private func hexData(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

/// The vectors of docs/clean-room/TapoCamera.md, 13.
struct StreamdProtocolTests {
    let challenge = #"Digest realm="streamd-example",nonce="6f1c2a9e3b7d4c58",qop="auth",opaque="64943214",algorithm="MD5",encrypt_type="3""#
    let keyExchange = #"username="admin" nonce="9a4cf1e07b2d4e8f8c1b3a5d6e7f9012""#

    @Test func passwordHashes() {
        #expect(Streamd.passwordHash("ExamplePassw0rd!", sha256: false) == "FD344607B3AAFF7BB5FE20B9B04149FD")
        #expect(Streamd.passwordHash("ExamplePassw0rd!", sha256: true) == "D23E8AD06AA8C81F7A6FC25A66922E4CFE2D3BDF6AC227C166F1EEC354E41767")
    }

    @Test func theDigestAnswer() throws {
        let fields = Streamd.fields(challenge)
        #expect(fields["realm"] == "streamd-example")
        #expect(Streamd.wantsSHA256(fields))
        let cnonce = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978"
        let sha = try #require(Streamd.authorization(challenge: fields, passwordHash: Streamd.passwordHash("ExamplePassw0rd!", sha256: true), cnonce: cnonce))
        #expect(sha == #"Digest username="admin",realm="streamd-example",uri="/stream",algorithm=MD5,nonce="6f1c2a9e3b7d4c58",nc=00000001,cnonce="0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978",qop=auth,response="28d0f773c39507f9a39a85b35a787131",opaque="64943214""#)
        let md5 = try #require(Streamd.authorization(challenge: fields, passwordHash: Streamd.passwordHash("ExamplePassw0rd!", sha256: false), cnonce: cnonce))
        #expect(md5.contains(#"response="e2d6cb92cbd626e614ee6abb47edd69e""#))
        #expect(!Streamd.wantsSHA256(Streamd.fields(#"Digest realm="r",nonce="n""#)))
    }

    @Test func keysAndParts() throws {
        let sha = try #require(Streamd.Keys(keyExchange: keyExchange, passwordHash: Streamd.passwordHash("ExamplePassw0rd!", sha256: true)))
        #expect(sha.key.withUnsafeBytes { Data($0) } == hexData("cb561b8390a544fe465ab7f1cd96f345"))
        #expect(sha.iv == hexData("87e9a7a3ab9e1e20c4284584bb837aba"))
        let md5 = try #require(Streamd.Keys(keyExchange: keyExchange, passwordHash: Streamd.passwordHash("ExamplePassw0rd!", sha256: false)))
        #expect(md5.key.withUnsafeBytes { Data($0) } == hexData("1e915847bc98909257f226225706d105"))
        let none = try #require(Streamd.Keys(keyExchange: #"username="none" nonce="9a4cf1e07b2d4e8f8c1b3a5d6e7f9012""#, passwordHash: "x"))
        #expect(none.key.withUnsafeBytes { Data($0) } == hexData("f1809011b25f53fe6d0a4be7261a111d"))
        #expect(none.iv == hexData("b810f22e6696c0303595c0f6ee1c2c10"))

        let preview = Streamd.previewRequest(channel: 0, resolution: .hd)
        #expect(preview == #"{"params":{"preview":{"audio":["default"],"channels":[0],"resolutions":["HD"]},"method":"get"},"seq":1,"type":"request"}"#)
        #expect(try sha.encrypt(Data(preview.utf8)) == hexData("503a7c0a4ad9b8e9866a1ee497099e4ea19b050dad2507dc7b9001be9a3fcaa63161b79ab580571fc6d474f158e9284010312aaec772e6d7422850871e0d58c508ff03e768b9b92281f1012f7cb02f6c2f67e83a4ab8ab2885288b3e0cebbce6d57ff860ff0bf225ee482a89941f9b1cd3043fa77439487f0d21bfccbb9c850d"))
        let reply = hexData("3f7fe8b54ca9c8d4fc5ac24e74a37500f8dd8ae81188e8bde8f829be6fe899d281db2da727fe8d8e2e198cf0215ab5f13e1965742fa7cfe8b3621a4fbe119660d1b3b9e3adc93ff3e87123ebf7044d0a")
        #expect(String(decoding: try sha.decrypt(reply), as: UTF8.self) == #"{"type":"response","seq":1,"params":{"error_code":0,"session_id":"7"}}"#)
        // Each part starts from the same IV: the media part decrypts on its own.
        let media = hexData("ffdc4eefa544ecdfbd272cf5066bea5716a99d2ce8a5d39db520a6c77bf9ed2f680e9c77664d7eb3f1ea17726e1a5dad8bb837ae8de28a982a2e852e463e1f214d0c9a51eba833a0236857f1b1c4d0f541db88c60072c86a98fdf8972ebdcd8cb3ad505a2ca2c7b641d8485ec81d9a62752c1ece9fbe963914df43d94d782edb6a5dcec75040286a95bad0e943c8c0f57a7847d41c9b291eb27128258742b4d1e326292e7511438899b5c4e3a5e670ec2b5481ea4b93e39a21c8aff1d62bdfbb")
        #expect(try sha.decrypt(media) == Data([0x47, 0x1F, 0xFF, 0x10]) + Data(repeating: 0xFF, count: 184))
        // Chained from the reply's last block instead, it does not.
        let chained = try? AES._CBC.decrypt(media, using: sha.key, iv: AES._CBC.IV(ivBytes: reply.suffix(16)))
        #expect(chained != Data([0x47, 0x1F, 0xFF, 0x10]) + Data(repeating: 0xFF, count: 184))
        #expect(throws: StreamdError.self) { try sha.decrypt(Data(repeating: 0, count: 15)) }
    }

    @Test func headsAndPartsAcrossChunks() throws {
        var buffer = StreamdBuffer()
        buffer.append(Array("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"r\"\r\n\r\nHTTP ERROR 401HTTP/1.0 200 OK\r\nKey-Exch".utf8))
        let first = try #require(try buffer.readHead())
        #expect(first.status == 401)
        #expect(first.headers["www-authenticate"] == "Digest realm=\"r\"")
        #expect(try buffer.readHead() == nil)
        buffer.append(Array("ange: nonce=\"n\"\r\n\r\n".utf8))
        let second = try #require(try buffer.readHead())
        #expect(second.status == 200)
        #expect(second.headers["key-exchange"] == "nonce=\"n\"")

        let body = Array(repeating: UInt8(7), count: 40)
        let part = Array("junk----device-stream-boundary--\r\nContent-Type: video/mp2t\r\nContent-Length: 40\r\nX-If-Encrypt: 0\r\n\r\n".utf8) + body + Array("\r\n".utf8)
        for byte in part.prefix(part.count - 10) {
            buffer.append([byte])
            #expect(try buffer.readPart(boundary: Streamd.deviceBoundary) == nil)
        }
        buffer.append(Array(part.suffix(10)))
        let read = try #require(try buffer.readPart(boundary: Streamd.deviceBoundary))
        #expect(read.contentType == "video/mp2t")
        #expect(read.body == Data(body))
        #expect(!read.isEncrypted)
    }

    @Test func theFinishedNotificationAndBoundary() {
        #expect(StreamdClient.isFinished(Data(#"{"type":"notification","params":{"event_type":"stream_status","status":"finished"}}"#.utf8)))
        #expect(!StreamdClient.isFinished(Data(#"{"type":"response","params":{}}"#.utf8)))
        #expect(StreamdClient.boundary(of: "multipart/mixed;boundary=--device-stream-boundary--") == "--device-stream-boundary--")
        #expect(StreamdClient.boundary(of: "multipart/mixed; boundary=\"abc\"") == "abc")
    }

    @Test func lenses() {
        #expect(TapoLens.lenses(kind: .dualLens, resolution: .hd).map(\.videoIndex) == [0, 1])
        #expect(TapoLens.lenses(kind: .dualLens, resolution: .vga).count == 1)
        #expect(TapoLens.lenses(kind: .single, resolution: .hd).count == 1)
        #expect(TapoCameraKind(type: " DualLensCamera ") == .dualLens)
        #expect(TapoCameraKind(type: "Camera") == .single)
        #expect(TapoCameraKind(type: "Plug") == nil)
    }

    @Test func ffmpegReadsTheLensFromStandardInput() {
        let arguments = TapoCameraStreamer.snapshotArguments(videoIndex: 1)
        #expect(arguments.contains("pipe:0"))
        #expect(arguments.firstIndex(of: "0:v:1") != nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StreamdClientTests {
    let camera = FakeStreamdCamera()

    func client(password: String = "ExamplePassw0rd!", silence: Duration = .seconds(10)) -> StreamdClient {
        StreamdClient(host: "192.0.2.5", password: { password }, connect: camera.connect, handshakeTimeout: .seconds(5), silenceTimeout: silence, logger: testLogger)
    }

    @Test func signsInWithTheSHA256AndStreams() async throws {
        let session = try await client().open(resolution: .hd)
        #expect(session.sessionID == "7")
        var received: [Data] = []
        for try await data in session.stream {
            received.append(data)
            if received.count == 3 { break }
        }
        #expect(received == (0..<3).map { FakeStreamdCamera.packet(UInt8($0)) })
        #expect(camera.previews == [Streamd.previewRequest(channel: 0, resolution: .hd)])
        #expect(camera.connections == 1)
        await session.close()
    }

    @Test func fallsBackToTheMD5OnANewConnection() async throws {
        camera.state.withLockedValue { $0.acceptsOnlyMD5 = true }
        let session = try await client().open(resolution: .vga)
        #expect(camera.connections == 2)
        #expect(camera.logins == 1)
        #expect(camera.previews.first?.contains(#""resolutions":["VGA"]"#) == true)
        await session.close()
    }

    @Test func aWrongPasswordStopsAfterBothHashes() async throws {
        await #expect(throws: StreamdError.invalidCredentials) { try await client(password: "wrong").open(resolution: .hd) }
        #expect(camera.connections == 2)
        #expect(camera.openConnections == 0)
    }

    @Test func aBusyCameraSaysSo() async throws {
        camera.state.withLockedValue { $0.previewError = -52407 }
        await #expect(throws: StreamdError.busy(-52407)) { try await client().open(resolution: .hd) }
    }

    @Test func silenceEndsTheSession() async throws {
        let session = try await client(silence: .milliseconds(200)).open(resolution: .hd)
        await #expect(throws: StreamdError.silent) {
            for try await _ in session.stream {}
        }
        #expect(await eventually { camera.openConnections == 0 })
    }

    @Test func aClosedConnectionEndsTheSession() async throws {
        camera.state.withLockedValue { $0.closeAfterParts = true }
        let session = try await client().open(resolution: .hd)
        var count = 0
        await #expect(throws: StreamdError.closed) {
            for try await _ in session.stream { count += 1 }
        }
        #expect(count == 3)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TapoCameraFeedTests {
    let camera = FakeStreamdCamera()

    func feed(budget: Int = 5) -> TapoCameraFeed {
        let client = StreamdClient(host: "192.0.2.5", password: { "ExamplePassw0rd!" }, connect: camera.connect, handshakeTimeout: .seconds(5),
                                   silenceTimeout: .seconds(10), logger: testLogger)
        var timing = TapoCameraFeed.Timing()
        timing.linger = .milliseconds(50)
        timing.retryDelay = .milliseconds(20)
        timing.reconnectBudget = budget
        return TapoCameraFeed(name: "Garden", client: client, resolution: .hd, timing: timing, logger: testLogger)
    }

    @Test func theCameraIsLeftAloneUntilSomeoneWatches() async throws {
        let feed = feed()
        try await Task.sleep(for: .milliseconds(100))
        #expect(camera.connections == 0)
        let first = await feed.join()
        let second = await feed.join()
        var iterator = first.stream.makeAsyncIterator()
        var other = second.stream.makeAsyncIterator()
        #expect(await iterator.next() == FakeStreamdCamera.packet(0))
        #expect(await other.next() == FakeStreamdCamera.packet(0))
        // Both lenses' viewers share one session.
        #expect(camera.connections == 1)
        await feed.leave(first.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(camera.openConnections == 1)
        await feed.leave(second.id)
        #expect(await eventually { camera.openConnections == 0 })
        #expect(await feed.isConnected == false)
    }

    @Test func aViewerBackWithinTheLingerKeepsTheSession() async throws {
        let feed = feed()
        let first = await feed.join()
        var iterator = first.stream.makeAsyncIterator()
        _ = await iterator.next()
        await feed.leave(first.id)
        let again = await feed.join()
        try await Task.sleep(for: .milliseconds(150))
        #expect(camera.connections == 1)
        await feed.leave(again.id)
    }

    @Test func standbyReconnectsQuietlyWhileWatched() async throws {
        let feed = feed()
        let viewer = await feed.join()
        var iterator = viewer.stream.makeAsyncIterator()
        for _ in 0..<3 { _ = await iterator.next() }
        camera.standby()
        // A new session: its first packet again.
        #expect(await iterator.next() == FakeStreamdCamera.packet(0))
        #expect(camera.connections == 2)
        await feed.stop()
        #expect(await eventually { camera.openConnections == 0 })
    }

    @Test func theFeedGivesUpAfterItsBudget() async throws {
        camera.state.withLockedValue {
            $0.closeAfterParts = true
            $0.parts = 1
        }
        let feed = feed(budget: 2)
        let viewer = await feed.join()
        var count = 0
        for await _ in viewer.stream { count += 1 }
        #expect(camera.connections == 3)
        #expect(count == 3)
        #expect(await feed.isConnected == false)
    }

    @Test func aWrongPasswordIsNotRetried() async throws {
        camera.state.withLockedValue { $0.password = "other" }
        let feed = feed()
        let viewer = await feed.join()
        for await _ in viewer.stream {}
        #expect(camera.connections == 2)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TapoCameraPluginTests {
    let environment = TestEnvironment()

    @Test func aDualLensCameraIsTwoCamerasAndNoConnection() async throws {
        let camera = FakeStreamdCamera()
        let host = try await environment.start(
            devices: [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera"]], connect: camera.connect)
        let ids = ["TapoP100:192.168.1.40Garden", "TapoP100:192.168.1.40Garden:tele"]
        #expect(await eventually { Set(host.bridges.flatMap { $0.server.accessories.map(\.id) }).isSuperset(of: ids) })
        let tele = try #require(host.bridges.flatMap(\.server.accessories).first { $0.id == ids[1] })
        #expect(tele.name == "Garden Tele")
        #expect(tele.category == .ipCamera)
        try await Task.sleep(for: .milliseconds(100))
        #expect(camera.connections == 0)
        // A snapshot never wakes the camera: without a live view yet, there is none.
        let plugin = try #require(environment.plugin)
        let streamer = try #require(await plugin.cameraRuntimes.values.first?.cameras.first?.streamer)
        await #expect(throws: HAPStatusError.self) {
            try await streamer.handleSnapshotRequest(SnapshotRequest(height: 360, width: 640))
        }
        #expect(camera.connections == 0)
        await host.stop()
    }

    @Test func vgaShowsOneCamera() async throws {
        let camera = FakeStreamdCamera()
        let host = try await environment.start(
            devices: [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera", "resolution": "VGA"]], connect: camera.connect)
        #expect(await eventually { host.bridges.flatMap(\.server.accessories).contains { $0.id == "TapoP100:192.168.1.40Garden" } })
        #expect(!host.bridges.flatMap(\.server.accessories).contains { $0.id.hasSuffix(":tele") })
        await host.stop()
    }
}
