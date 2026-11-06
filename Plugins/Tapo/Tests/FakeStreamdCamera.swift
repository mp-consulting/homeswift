import Crypto
import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers
import _CryptoExtras

@testable import HomeswiftTapo

/// A Tapo battery camera's Streamd server in memory (docs/clean-room/TapoCamera.md): the Digest challenge with
/// `encrypt_type="3"`, the login with the SHA-256 (or, when `acceptsOnlyMD5`, the MD5) of `password`, the `Key-Exchange`,
/// the preview reply, then encrypted `video/mp2t` parts until the test ends the session.
final class FakeStreamdCamera: Sendable {
    struct State {
        var password = "ExamplePassw0rd!"
        var acceptsOnlyMD5 = false
        /// The error code of the preview reply.
        var previewError = 0
        /// What the camera does after the reply: send `parts` parts of TS, then stay silent or close.
        var parts = 3
        var closeAfterParts = false
        /// After the parts, one more this often until the session closes: a camera that stays awake while watched.
        var keepStreaming: Duration?
        var connections = 0
        var logins = 0
        var previews: [String] = []
        var open: [FakeStreamdConnection] = []
    }

    let state = NIOLockedValueBox(State())
    static let realm = "streamd-example"
    static let keyNonce = "9a4cf1e07b2d4e8f8c1b3a5d6e7f9012"

    /// One 188-byte TS packet, numbered so a test can tell parts apart.
    static func packet(_ n: UInt8) -> Data { Data([0x47, 0x1F, 0xFF, 0x10, n]) + Data(repeating: 0xFF, count: 183) }

    var connect: StreamdClient.Connect {
        { [self] _, _, _ in
            let connection = FakeStreamdConnection(camera: self)
            state.withLockedValue { state in
                state.connections += 1
                state.open.append(connection)
            }
            return connection
        }
    }

    var connections: Int { state.withLockedValue { $0.connections } }
    var logins: Int { state.withLockedValue { $0.logins } }
    var previews: [String] { state.withLockedValue { $0.previews } }
    var openConnections: Int { state.withLockedValue { $0.open.filter { !$0.isClosed }.count } }

    /// Sends one more media part on every open session.
    func sendPart(_ n: UInt8) {
        for connection in state.withLockedValue({ $0.open }) where !connection.isClosed { connection.sendMedia(Self.packet(n)) }
    }

    /// Closes every open session, as standby does.
    func standby() {
        for connection in state.withLockedValue({ $0.open }) { connection.serverClose() }
    }
}

final class FakeStreamdConnection: ByteStream, @unchecked Sendable {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let camera: FakeStreamdCamera
    private struct Inner {
        var received: [UInt8] = []
        var stage = 0
        var digestNonce = "6f1c2a9e3b7d4c58"
        var hash: String?
        var closed = false
    }
    private let inner = NIOLockedValueBox(Inner())

    init(camera: FakeStreamdCamera) {
        self.camera = camera
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
    }

    var isClosed: Bool { inner.withLockedValue { $0.closed } }

    func send(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw StreamdError.closed }
        let text = inner.withLockedValue { inner -> String in
            inner.received += bytes
            return String(decoding: inner.received, as: UTF8.self)
        }
        let stage = inner.withLockedValue { $0.stage }
        switch stage {
        case 0 where text.hasSuffix("\r\n\r\n"):
            inner.withLockedValue { inner in
                inner.received = []
                inner.stage = 1
            }
            // A 401 whose body runs into the next status line, as some cameras answer.
            reply("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"\(FakeStreamdCamera.realm)\",nonce=\"6f1c2a9e3b7d4c58\",qop=\"auth\",opaque=\"64943214\",algorithm=\"MD5\",encrypt_type=\"3\"\r\n\r\nHTTP ERROR 401")
        case 1 where text.hasSuffix("\r\n\r\n"):
            inner.withLockedValue { inner in
                inner.received = []
            }
            let state = camera.state.withLockedValue { $0 }
            let authorization = text.components(separatedBy: "\r\n").first { $0.hasPrefix("Authorization: ") }.map { String($0.dropFirst(15)) } ?? ""
            let fields = Streamd.fields(authorization)
            let accepted = state.acceptsOnlyMD5 ? [false] : [true, false]
            let hash = accepted.map { Streamd.passwordHash(state.password, sha256: $0) }.first { hash in
                let ha1 = Streamd.md5Hex("admin:\(FakeStreamdCamera.realm):\(hash)")
                let ha2 = Streamd.md5Hex("POST:/stream")
                let expected = Streamd.md5Hex("\(ha1):6f1c2a9e3b7d4c58:\(fields["nc"] ?? ""):\(fields["cnonce"] ?? ""):auth:\(ha2)")
                return fields["response"] == expected && fields["username"] == "admin" && fields["opaque"] == "64943214"
            }
            guard let hash else {
                reply("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"\(FakeStreamdCamera.realm)\",nonce=\"7a\",opaque=\"64943214\",encrypt_type=\"3\"\r\n\r\n")
                return
            }
            camera.state.withLockedValue { $0.logins += 1 }
            inner.withLockedValue { inner in
                inner.hash = hash
                inner.stage = 2
            }
            reply("HTTP/1.0 200 OK\r\nContent-Type: multipart/mixed;boundary=--device-stream-boundary--\r\nKey-Exchange: username=\"admin\" nonce=\"\(FakeStreamdCamera.keyNonce)\"\r\n\r\n")
        case 2:
            guard let start = text.range(of: "\r\n\r\n"), text.hasSuffix("}\r\n") else { return }
            let json = String(text[start.upperBound...].dropLast(1))  // "\r\n" is one Character
            inner.withLockedValue { inner in
                inner.received = []
                inner.stage = 3
            }
            let state = camera.state.withLockedValue { state -> FakeStreamdCamera.State in
                state.previews.append(json)
                return state
            }
            sendPart(contentType: "application/json", Data(#"{"type":"response","seq":1,"params":{"error_code":\#(state.previewError),"session_id":"7"}}"#.utf8))
            guard state.previewError == 0 else { return }
            for n in 0..<state.parts { sendMedia(FakeStreamdCamera.packet(UInt8(n))) }
            if state.closeAfterParts { serverClose() }
            if let interval = state.keepStreaming {
                Task { [weak self] in
                    while let self, !self.inner.withLockedValue({ $0.closed }) {
                        self.sendMedia(FakeStreamdCamera.packet(0))
                        try? await Task.sleep(for: interval)
                    }
                }
            }
        default:
            break
        }
    }

    private func reply(_ text: String) { continuation.yield(Array(text.utf8)) }

    func sendMedia(_ data: Data) { sendPart(contentType: "video/mp2t", data) }

    private func sendPart(contentType: String, _ plaintext: Data) {
        guard let hash = inner.withLockedValue({ $0.hash }), let keys = Streamd.Keys(keyExchange: "username=\"admin\" nonce=\"\(FakeStreamdCamera.keyNonce)\"", passwordHash: hash),
              let body = try? keys.encrypt(plaintext) else { return }
        var part = Array("----device-stream-boundary--\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nX-If-Encrypt: 1\r\nX-Session-Id: 7\r\n\r\n".utf8)
        part += body
        part += Array("\r\n".utf8)
        // Split in two, as TCP may deliver it.
        let middle = part.count / 2
        continuation.yield(Array(part[..<middle]))
        continuation.yield(Array(part[middle...]))
    }

    func serverClose() {
        inner.withLockedValue { $0.closed = true }
        continuation.finish()
    }

    func close() async { serverClose() }
}
