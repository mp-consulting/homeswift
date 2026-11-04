import Crypto
import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftNetwork

/// docs/clean-room/FCMReceiver.md's vectors (section 10).
private func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

private let androidID: UInt64 = 4_573_291_051_937_427_291
private let securityToken: UInt64 = 11_930_123_874_651_234_567

private let receiverKeys = WebPushDecryption.Keys(
    privateKey: try! P256.KeyAgreement.PrivateKey(rawRepresentation: hex("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721")),
    authSecret: hex("000102030405060708090a0b0c0d0e0f"))
private let appData = [
    "crypto-key": "dh=BBzL6RwHX8f08DO_okjbj8zTVl3pS7-xLzxZ_0bCcb-DzkAUxogR-aIaH9ssDmET4G23ypO3QE543HzNXKiaTKk",
    "encryption": "salt=EBESExQVFhcYGRobHB0eHw",
]
private let plaintext = #"{"data":{"event":"motion","id":"42"},"from":"123456789012","priority":"high","fcmMessageId":"0:1700000000000000%abcdef"}"#
private let caseA = """
    de0a2c8c99c9bb44f3cf176169ebb7e5520b1328236e2cb0abe06a0c4ea39b8a382b175836cae27a072c438800125a51a8dd5a260fb2915d00
    a8bc06455345b48a7c4bb036c51c576268bed8c697c2236bf6e2b8aa22c7a6aa77f2868dbf5a24a44629342ce7bb68cfa9068d29f3fe716d90
    f056f9cb67214ff16fb8f6231058721f41965e610a32747e
    """
private let dataFrame = """
    08c00312034944311a0c3132333435363738393031322a126f72672e6368726f6d69756d2e6c696e75783a680a0a63727970746f2d6b657912
    5a64683d42427a4c365277485838663038444f5f6f6b6a626a387a54566c337053372d784c7a785a5f30624363622d447a6b4155786f67522d
    61496148397373446d45543447323379704f335145353433487a4e584b6961544b6b3a290a0a656e6372797074696f6e121b73616c743d4542
    4553457851564668635947526f624842306548773a440a0773756274797065123977703a72656365697665722e707573682e636f6d23303030
    30303030302d303030302d343030302d383030302d3030303030303030303030304a23303a3137303030303030303030303030303225373033
    31623265366639666437656364880100900180d095ffbc31aa018a01de0a2c8c99c9bb44f3cf176169ebb7e5520b1328236e2cb0abe06a0c4e
    a39b8a382b175836cae27a072c438800125a51a8dd5a260fb2915d00a8bc06455345b48a7c4bb036c51c576268bed8c697c2236bf6e2b8aa22
    c7a6aa77f2868dbf5a24a44629342ce7bb68cfa9068d29f3fe716d90f056f9cb67214ff16fb8f6231058721f41965e610a32747e
    """

struct FCMProtocolTests {
    @Test func checkinRequests() {
        #expect(FCMProtocol.checkinRequest(chromeVersion: "63.0.3234.0", style: .minimal) == hex("221560036a110802120b36332e302e333233342e3018017003b00100"))
        #expect(FCMProtocol.checkinRequest(androidID: androidID, securityToken: securityToken, chromeVersion: "63.0.3234.0", style: .minimal)
            == hex("10dbdecfe9b3ffe5bb3f221560036a110802120b36332e302e333233342e301801690761fe9a745090a57003b00100"))
        #expect(FCMProtocol.checkinRequest(chromeVersion: "94.0.4606.51", style: .chrome(timeZone: "Europe/Prague")) == hex(
            "1a002220100032003a004200480060036a120802120c39342e302e343630362e353118012a00320038004200620d4575726f70652f5072616775657003a00100aa0100b00100"))
    }

    @Test func checkinResponseKeepsUnsignedValues() throws {
        let parsed = try #require(FCMProtocol.checkinResponse(hex("08011880d095ffbc31395bef333dfb97773f410761fe9a745090a55a027631")))
        #expect(String(parsed.androidID) == "4573291051937427291")
        #expect(String(parsed.securityToken) == "11930123874651234567")
    }

    @Test func gcmRegisterBody() {
        let body = FCMReceiver.gcmRegisterBody(
            appID: "wp:receiver.push.com#00000000-0000-4000-8000-000000000000", androidID: String(androidID), sender: FCMReceiver.defaultSenderKey)
        #expect(body == "app=org.chromium.linux&X-subtype=wp%3Areceiver.push.com%2300000000-0000-4000-8000-000000000000&device=4573291051937427291&sender=BDOU99-h67HcA6JeFXHbSNMu7e2yNNu3RzoMj8TM4W88jITfq7ZmPvIM1Iv-4_l2LxQcYwhqby2xGpWwzjfAnG4")
        #expect(WebPushDecryption.base64URLDecode(FCMReceiver.defaultSenderKey) == hex(
            "043394f7dfa1ebb1dc03a25e1571db48d32eededb234dbb7473a0c8fc4cce16f3c8c84dfabb6663ef20cd48bfee3f9762f141c63086a6f2db11a95b0ce37c09c6e"))
    }

    @Test func loginFrame() {
        let frame = FCMProtocol.loginFrame(
            androidID: String(androidID), securityToken: String(securityToken), chromeVersion: "94.0.4606.51",
            persistentIDs: ["0:1700000000000001%7031b2e6f9fd7ecd"], heartbeatIntervalMilliseconds: 300_000)
        #expect(frame == hex("""
            2902c6010a136368726f6d652d39342e302e343630362e3531120f6d63732e616e64726f69642e636f6d1a1334353733323931303531393337
            3432373239312213343537333239313035313933373432373239312a1431313933303132333837343635313233343536373218616e64726f69
            642d33663737393766623364333365663562420b0a066e65775f76631201315223303a31373030303030303030303030303031253730333162
            326536663966643765636460006a080a00100118e0a7127001800102880101
            """))
    }

    @Test func heartbeats() {
        #expect(FCMProtocol.heartbeat(.heartbeatPing, lastStreamIDReceived: nil) == hex("0000"))
        #expect(FCMProtocol.heartbeat(.heartbeatPing, lastStreamIDReceived: 5) == hex("00021005"))
        #expect(FCMProtocol.heartbeat(.heartbeatAck, lastStreamIDReceived: 5) == hex("01021005"))
    }

    @Test func parserReadsTheLoginResponseAndClose() throws {
        var parser = MCSFrameParser()
        let messages = try parser.feed(hex("2903220a136368726f6d652d39342e302e343630362e353112002801300140fbd095ffbc31") + hex("0400"))
        #expect(messages.map(\.tag) == [.loginResponse, .close])
        #expect(ProtobufMessage(messages[0].body)?.string(1) == "chrome-94.0.4606.51")
        #expect(messages[1].body.isEmpty)
    }

    @Test func parserWaitsForSplitMessages() throws {
        var parser = MCSFrameParser()
        let bytes = [UInt8(41)] + hex(dataFrame)
        var messages: [(tag: FCMProtocol.Tag, body: [UInt8])] = []
        for byte in bytes { messages += try parser.feed([byte]) }
        #expect(messages.count == 1)
        let message = try #require(FCMProtocol.DataMessage(messages[0].body))
        #expect(message.persistentID == "0:1700000000000002%7031b2e6f9fd7ecd")
        #expect(message.appData["crypto-key"] == appData["crypto-key"])
        #expect(message.rawData == hex(caseA))
    }

    @Test func parserRefusesAnUnknownVersionOrTag() {
        var version = MCSFrameParser()
        #expect(throws: MCSFrameParser.ParseError.unsupportedVersion(40)) { try version.feed([40, 3, 0]) }
        var tag = MCSFrameParser()
        #expect(throws: MCSFrameParser.ParseError.unknownTag(5)) { try tag.feed([41, 5, 0]) }
    }
}

struct WebPushDecryptionTests {
    @Test func storedKeysDecode() {
        #expect(WebPushDecryption.base64URLDecode("ya-p2EW6dRZrXCFXZ7HWk05Qw9s26JsSe4piKxIPZyE") == hex("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"))
        #expect(WebPushDecryption.base64URLEncode(receiverKeys.publicKey) == "BGD-1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p-2eQP-EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk")
        #expect(WebPushDecryption.base64URLEncode(receiverKeys.authSecret) == "AAECAwQFBgcICQoLDA0ODw")
    }

    @Test func derivation() throws {
        let sender = try #require(WebPushDecryption.base64URLDecode("BBzL6RwHX8f08DO_okjbj8zTVl3pS7-xLzxZ_0bCcb-DzkAUxogR-aIaH9ssDmET4G23ypO3QE543HzNXKiaTKk"))
        let keys = try WebPushDecryption.contentKeys(senderPublicKey: sender, salt: hex("101112131415161718191a1b1c1d1e1f"), keys: receiverKeys)
        #expect(keys.key == hex("c23b40dfaa417e0821c1dfa9d117dac4"))
        #expect(keys.nonce == hex("c57bc42da5d2e8b43699d6a3"))
    }

    @Test func oneRecord() throws {
        #expect(try WebPushDecryption.decrypt(hex(caseA), appData: appData, keys: receiverKeys) == Array(plaintext.utf8))
    }

    @Test func padding() throws {
        let caseB = """
            de0957aefdd3ed41b0810d6136e6f0ee504c477e6c3b7ab4abfa214f02e8d38a6b6d01503683fc7a1c720e8350471542a0cc5f210ab19c5207
            a1b714584317eac1634bb02dce57193922ed9dc6dc89692fb9ad93ac3cf9a2be61da85cacc1c36a4552e3e2de0bb68cfa9068d29f3fe716d85
            a104bfce602409e920af3e37ea3e755abcaaceb6d4fc6c31e9c673
            """
        #expect(try WebPushDecryption.decrypt(hex(caseB), appData: appData, keys: receiverKeys) == Array(plaintext.utf8))
    }

    @Test func severalRecords() throws {
        let caseC = """
            de0a2c8c99c9bb44f3cf176169ebb7e5520b1328236e2cb0abe06a0c4ea39b8aafcfe0adbf572f9f8fc845cf9e48a4cfacb79407181b98bed8
            bb0f7e4908e843db0e4a8951bec507fa192946dc92e36e64750867da1e1aa32ef52b81de6e42971d82d07eb9eee3eda6e2cf8c5ddb3ea730b6
            5b5e9dad12084fd17457db42ceec0f36644375e7ecfaf60a51d9e1097ac3e30c102d5a362610a934ae957ea1b8accbdec4add44628d7e3e3db
            520530a6bad98d6e4eceae9c4d1dcbe6e6b58c270aa174aa565bf378211bae6043328c474c1529
            """
        #expect(try WebPushDecryption.decrypt(hex(caseC), appData: appData, keys: receiverKeys, recordSize: 32) == Array(plaintext.utf8))
    }

    @Test func aFlippedByteFailsAuthentication() {
        var tampered = hex(caseA)
        tampered[10] ^= 1
        #expect(throws: WebPushDecryption.DecryptionError.authenticationFailed) {
            try WebPushDecryption.decrypt(tampered, appData: appData, keys: receiverKeys)
        }
    }

    @Test func fidShape() {
        for _ in 0..<20 {
            let fid = FCMReceiver.generateFID()
            #expect(fid.count == 22)
            #expect("cdef".contains(fid.first!))
        }
    }
}

/// The MCS server in memory: the test pushes what it sends.
final class FakeFCMConnection: FCMConnection {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let sentBox = NIOLockedValueBox<[[UInt8]]>([])

    init() {
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
    }

    var sent: [[UInt8]] { sentBox.withLockedValue { $0 } }
    func send(_ bytes: [UInt8]) async throws { sentBox.withLockedValue { $0.append(bytes) } }
    func close() async { continuation.finish() }
    func receive(_ bytes: [UInt8]) { continuation.yield(bytes) }
}

/// Google's registration endpoints, canned.
struct FakeGoogle: HTTPSending {
    let requests = NIOLockedValueBox<[String]>([])

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        requests.withLockedValue { $0.append(url) }
        if url.hasSuffix("/checkin") { return HTTPResponse(status: 200, body: Data(hex("08011880d095ffbc31395bef333dfb97773f410761fe9a745090a55a027631"))) }
        if url.hasSuffix("/register3") { return HTTPResponse(status: 200, body: Data("token=gcm-token".utf8)) }
        if url.hasSuffix("/installations") {
            return HTTPResponse(status: 200, body: Data(#"{"fid":"fid-1","refreshToken":"rt","authToken":{"token":"fis","expiresIn":"604800s"}}"#.utf8))
        }
        if url.hasSuffix("/registrations") { return HTTPResponse(status: 200, body: Data(#"{"token":"fcm-token"}"#.utf8)) }
        return HTTPResponse(status: 404)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct FCMReceiverTests {
    static func credentials() -> FCMCredentials {
        FCMCredentials(
            keys: .init(privateKey: "ya-p2EW6dRZrXCFXZ7HWk05Qw9s26JsSe4piKxIPZyE",
                        publicKey: "BGD-1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p-2eQP-EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk", authSecret: "AAECAwQFBgcICQoLDA0ODw"),
            gcm: .init(androidId: String(androidID), securityToken: String(securityToken), appId: "wp:receiver.push.com#x", token: "gcm"),
            fcm: .init(token: "fcm-token", installation: .init(fid: "f", refreshToken: "r", token: "t",
                                                               createdAt: Date().timeIntervalSince1970 * 1000, expiresIn: 604_800_000)),
            config: .init(bundleId: "receiver.push.com", projectId: "project", vapidKey: ""))
    }

    @Test func registersWhenItHasNoCredentials() async throws {
        let google = FakeGoogle()
        let connection = FakeFCMConnection()
        let receiver = FCMReceiver(configuration: .init(apiKey: "key", projectID: "project", appID: "app"), http: google) { connection }
        await receiver.start()
        var iterator = receiver.events.makeAsyncIterator()
        guard case .credentialsChanged(let credentials) = await iterator.next() else { Issue.record("no credentials"); return }
        #expect(credentials.fcm.token == "fcm-token")
        #expect(credentials.gcm.androidId == "4573291051937427291")
        #expect(credentials.gcm.token == "gcm-token")
        #expect(credentials.fcm.installation.expiresIn == 604_800_000)
        #expect(google.requests.withLockedValue { $0 }.count == 4)
        await receiver.stop()
    }

    @Test func deliversDecryptedMessagesOnce() async throws {
        let connection = FakeFCMConnection()
        let receiver = FCMReceiver(
            configuration: .init(apiKey: "key", projectID: "project", appID: "app"), credentials: Self.credentials(), http: FakeGoogle()) { connection }
        await receiver.start()
        var iterator = receiver.events.makeAsyncIterator()
        try await eventually { !connection.sent.isEmpty }
        #expect(connection.sent[0].first == 41)
        connection.receive(hex("2903220a136368726f6d652d39342e302e343630362e353112002801300140fbd095ffbc31"))
        guard case .ready = await iterator.next() else { Issue.record("not ready"); return }
        // Split inside the length, then the same message again: one event.
        let frame = hex(dataFrame)
        connection.receive(Array(frame.prefix(2)))
        connection.receive(Array(frame.dropFirst(2)))
        connection.receive(frame)
        connection.receive(hex("0000"))
        guard case .message(let message) = await iterator.next() else { Issue.record("no message"); return }
        #expect(message.persistentID == "0:1700000000000002%7031b2e6f9fd7ecd")
        #expect(message.data == ["event": "motion", "id": "42"])
        // The server's ping is answered with an ack carrying the stream id.
        try await eventually { connection.sent.contains { $0.first == 1 } }
        await receiver.stop()
    }

    @Test func aConnectionThatAnswersNoPingIsDropped() async throws {
        var configuration = FCMReceiver.Configuration(apiKey: "key", projectID: "project", appID: "app")
        configuration.heartbeatInterval = .milliseconds(100)
        var timing = FCMReceiver.Timing()
        timing.reconnect = .milliseconds(10)
        let connections = NIOLockedValueBox<[FakeFCMConnection]>([])
        let receiver = FCMReceiver(configuration: configuration, credentials: Self.credentials(), http: FakeGoogle(), timing: timing) {
            let connection = FakeFCMConnection()
            connections.withLockedValue { $0.append(connection) }
            return connection
        }
        await receiver.start()
        var iterator = receiver.events.makeAsyncIterator()
        try await eventually { !connections.withLockedValue { $0 }.isEmpty }
        let first = connections.withLockedValue { $0[0] }
        first.receive(hex("2903220a136368726f6d652d39342e302e343630362e353112002801300140fbd095ffbc31"))
        guard case .ready = await iterator.next() else { Issue.record("not ready"); return }
        // Pings go out but nothing comes back: the receiver gives up on the connection and opens another.
        guard case .disconnected = await iterator.next() else { Issue.record("not dropped"); return }
        #expect(first.sent.contains { $0.first == 0 })
        try await eventually { connections.withLockedValue { $0 }.count >= 2 }
        await receiver.stop()
    }
}
