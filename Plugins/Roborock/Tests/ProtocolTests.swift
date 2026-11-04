import Crypto
import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftRoborock

/// The spec's test vectors (docs/clean-room/Roborock.md, section 11), byte for byte.
struct ProtocolTests {
    static func bytes(_ hex: String) -> Data {
        let clean = hex.filter { !$0.isWhitespace }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            data.append(UInt8(clean[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test func encodesTheTimestamp() {
        #expect(RoborockCipher.hex8(1_700_000_000) == "6553f100")
        #expect(RoborockCipher.encodeTimestamp(1_700_000_000) == "1030556f")
    }

    @Test func buildsTheVersion1CloudFrame() throws {
        let key = RoborockCipher.v1Key(localKey: "0123456789abcdef", timestamp: 1_700_000_000)
        #expect(RoborockCipher.hex(key) == "636322e9ad7f7117a110699a5f24b854")
        let body = RoborockMessages.requestBody(id: 1234, method: "get_status", params: [], protocolNumber: 101, timestamp: 1_700_000_000, version: .v1)
        #expect(String(decoding: body, as: UTF8.self) == #"{"dps":{"101":"{\"id\":1234,\"method\":\"get_status\",\"params\":[]}"},"t":1700000000}"#)
        var frame = RoborockFrame(version: .v1, seq: 1, random: 4711, timestamp: 1_700_000_000, protocolNumber: 101)
        frame.payload = try RoborockCipher.encrypt(body, frame: frame, localKey: "0123456789abcdef", nonces: nil)
        let expected = "312e3000000001000012676553f10000650060cd75d0cc7be588661f01a212fcb60d6b83c361cbb01cfac73f5d2ad6c7a0a2cc6d8ceb598d8c9ecca27be1612424a861e3412afa8e985f18be3593aefb78dfcb9d4f60bd55eecdfe9cb19f6d9db92c6fe72d9f5af7f916109a6e504183e2f012d5e82875"
        #expect(RoborockCipher.hex(frame.encoded()) == expected)

        let decoded = try RoborockFrame.decode(Self.bytes(expected))
        #expect(decoded == frame)
        #expect(try RoborockCipher.decrypt(decoded.payload, frame: decoded, localKey: "0123456789abcdef", nonces: nil) == body)
    }

    @Test func rejectsAFrameWithABadChecksum() {
        var data = Self.bytes("312e3000000001000012676553f10000650060cd75d0cc7be588661f01a212fcb60d6b83c361cbb01cfac73f5d2ad6c7a0a2cc6d8ceb598d8c9ecca27be1612424a861e3412afa8e985f18be3593aefb78dfcb9d4f60bd55eecdfe9cb19f6d9db92c6fe72d9f5af7f916109a6e504183e2f012d5e82875")
        data[data.count - 1] ^= 1
        #expect(throws: RoborockProtocolError.badChecksum) { try RoborockFrame.decode(data) }
        #expect(throws: RoborockProtocolError.unknownVersion) { try RoborockFrame.decode(Data("XYZ".utf8) + Data(count: 20)) }
    }

    @Test func buildsTheL01Hello() throws {
        let hello = RoborockFrame(version: .l01, seq: 1, random: 12345, timestamp: 1_700_000_000, protocolNumber: 0)
        #expect(RoborockCipher.hex(hello.encoded()) == "4c303100000001000030396553f1000000e51df5ce")
        #expect(RoborockCipher.hex(hello.lengthPrefixed()) == "00000015" + "4c303100000001000030396553f1000000e51df5ce")
        let decoded = try RoborockFrame.decode(hello.encoded())
        #expect(decoded.protocolNumber == 0 && decoded.random == 12345)
    }

    @Test func roundTripsL01WithTheHandshakeNonces() throws {
        let nonces = RoborockCipher.Nonces(connect: 12345, ack: 23456)
        var frame = RoborockFrame(version: .l01, seq: 7, random: 4718, timestamp: 1_700_000_000, protocolNumber: 4)
        let body = Data(#"{"dps":{"4":"{}"},"t":1700000000}"#.utf8)
        frame.payload = try RoborockCipher.encrypt(body, frame: frame, localKey: "0123456789abcdef", nonces: nonces)
        #expect(frame.payload.count == body.count + 16)
        #expect(try RoborockCipher.decrypt(frame.payload, frame: frame, localKey: "0123456789abcdef", nonces: nonces) == body)
        // The AAD carries both nonces: another ack nonce does not open it, and none at all cannot build it.
        #expect(throws: (any Error).self) { try RoborockCipher.decrypt(frame.payload, frame: frame, localKey: "0123456789abcdef", nonces: .init(connect: 12345, ack: 1)) }
        #expect(throws: RoborockProtocolError.missingNonces) { try RoborockCipher.encrypt(body, frame: frame, localKey: "0123456789abcdef", nonces: nil) }
    }

    @Test func roundTripsA01AndB01() throws {
        for version in [RoborockVersion.a01, .b01] {
            var frame = RoborockFrame(version: version, seq: 2, random: 0x1267, timestamp: 1_700_000_000, protocolNumber: 4)
            let body = Data("{\"dps\":{}}".utf8)
            frame.payload = try RoborockCipher.encrypt(body, frame: frame, localKey: "0123456789abcdef", nonces: nil)
            #expect(try RoborockCipher.decrypt(frame.payload, frame: frame, localKey: "0123456789abcdef", nonces: nil) == body)
        }
        #expect(RoborockVersion(bytes: [0x81, 0x53, 0x19]) == .b01)
        let b01 = RoborockMessages.requestBody(id: 5, method: "get_prop", params: ["get_status"], protocolNumber: 101, timestamp: 1, version: .b01)
        #expect(String(decoding: b01, as: UTF8.self) == #"{"dps":{"10000":{"id":5,"method":"prop.get","msgId":"5","params":{"property":["get_status"]}}},"t":1}"#)
    }

    @Test func derivesTheMQTTCredentials() {
        let credentials = RoborockAuth.MQTTCredentials(u: "u_example", s: "s_example", k: "k_example")
        #expect(credentials.username == "bb7e313c")
        #expect(credentials.password == "fc7fb84ae37f586d")
        #expect(credentials.endpoint == "fuqUBDD+")
    }

    @Test func signsWithHawk() {
        let header = RoborockAuth.hawk(u: "u_example", s: "s_example", h: "h_example", path: "/v2/user/homes/123456", timestamp: 1_700_000_000, nonce: "abcdef")
        #expect(RoborockCipher.md5Hex("/v2/user/homes/123456") == "9ecb378a3e28c3ddbcb2263794ef4743")
        #expect(header == #"Hawk id="u_example", s="s_example", ts="1700000000", nonce="abcdef", mac="xpdN3y4vrLL0IIvP8VFVgRWw4btPIDcmP42jAuaK54M=""#)
        // Only the first + and / are replaced in the Hawk nonce; every one in the login's.
        #expect(RoborockAuth.hawkNonce([0xFB, 0xEF, 0xBE, 0xFF, 0xFF, 0xFF]) == "X+++Y/")
        #expect(RoborockAuth.signatureNonce([UInt8](repeating: 0xFF, count: 12)) == "YYYYYYYYYYYYYYYY")
    }

    @Test func encryptsTheLoginHelpers() throws {
        #expect(try RoborockAuth.encryptPassword("hunter2", k: "ABCDEFGHIJKLMNOP") == "LvL/DG4BURyfwhsOQkg4Qw==")
        #expect(RoborockAuth.clientIDHeader(email: "user@example.com", clientID: "00000000-0000-0000-0000-000000000000") == "G+x9MCsEIMzp23ArH/Xywg==")
    }

    @Test func readsAUDPDiscoveryPacket() throws {
        let packet = Self.bytes("312e3000000001000200309376423da61d4e3028fa115101790414afeddf22f9f5ffbb7f1d34a334bd6a1210196e18a41dad9d99720190a83ce6c4f2aadf90")
        let payload = try #require(RoborockCipher.discoveryPayload(packet))
        let json = try JSONValue(data: payload)
        #expect(json["duid"] == "EXAMPLEDUID123")
        #expect(json["ip"] == "192.168.1.50")
        #expect(RoborockCipher.discoveryPayload(packet.prefix(20)) == nil)
    }

    @Test func splitsTheLocalStream() throws {
        var buffer = LengthPrefixedBuffer()
        let frame = RoborockFrame(version: .l01, seq: 1, random: 12345, timestamp: 1_700_000_000, protocolNumber: 0).lengthPrefixed()
        #expect(try buffer.append(frame.prefix(10)).isEmpty)
        #expect(try buffer.append(frame.dropFirst(10) + frame) == [frame.dropFirst(4), frame.dropFirst(4)].map { Data($0) })
        #expect(throws: LengthPrefixedBuffer.Failure.corrupt) { try buffer.append(Data([0x7F, 0xFF, 0xFF, 0xFF])) }
        #expect(buffer.buffer.isEmpty)
    }

    @Test func readsBroadcastsAndAnswers() throws {
        let broadcast = try #require(RoborockMessages.incoming(Data(#"{"dps":{"121":5,"122":87},"t":1700000000}"#.utf8)))
        #expect(broadcast == .status(["state": 5, "battery": 87]))
        let answer = try #require(RoborockMessages.incoming(Data(#"{"dps":{"102":"{\"id\":1234,\"result\":[{\"state\":8,\"battery\":100,\"charge_status\":1,\"error_code\":0,\"in_cleaning\":0}]}"},"t":1700000005}"#.utf8)))
        guard case .response(let id, let result) = answer else { Issue.record("not an answer"); return }
        #expect(id == 1234)
        #expect(RoborockMessages.firstObject(result)?["charge_status"] == 1)
        // An error answer keeps its error, which fails the request.
        let failure = RoborockMessages.incoming(Data(#"{"dps":{"102":"{\"id\":7,\"error\":{\"code\":-10007,\"message\":\"retry\"}}"}}"#.utf8))
        #expect(failure == .response(id: 7, result: ["error": ["code": -10007, "message": "retry"]]))
        #expect(RoborockRequestError.deviceError("retry").isTransient && !RoborockRequestError.refused("x").allowsCloudFallback)
    }

    @Test func requestIDsAreNeverReusedWhileInFlight() {
        var ids = RequestIDs()
        var seen: [Int] = []
        for _ in 0..<(RequestIDs.maximum + 2) { seen.append(ids.take { _ in false }) }
        #expect(seen.prefix(3) == [1, 2, 3])
        #expect(seen[RequestIDs.maximum - 1] == RequestIDs.maximum)
        // The wrap goes back to 1 once, never 0 and never twice in a row.
        #expect(seen[RequestIDs.maximum] == 1 && seen[RequestIDs.maximum + 1] == 2)
        #expect(!seen.contains(0))
        var busy = RequestIDs()
        #expect(busy.take { $0 == 1 } == 2)
    }

    @Test func computesTheConsumables() {
        let lives = RoborockConsumables.lives(["main_brush_work_time": 324000, "side_brush_work_time": 360000, "filter_work_time": 513000])
        #expect(lives == ["main_brush_life": 70, "side_brush_life": 50, "filter_life": 5])
        #expect(RoborockConsumables.life(workSeconds: 10 * 3600 * 1000, ratedHours: 150) == 0)
    }

    @Test func readsTheFeatureBits() {
        #expect(RoborockFeatures(featureSet: 137_438_953_472).dockWashesMop)
        #expect(!RoborockFeatures(featureSet: 2_234_201_184_108_543 & ~(1 << 37)).dockWashesMop)
        #expect(RoborockFeatures(featureSet: 1 << 45).offPeakCharging)
        #expect(RoborockHome.unsigned("2234201184108543") == 2_234_201_184_108_543)
        #expect(RoborockFeatures.dockWashes(dockType: 3) && !RoborockFeatures.dockWashes(dockType: 5))
    }

    @Test func decryptsAHomebridgeToken() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let plain = Sample.session.encoded()
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce)
        let envelope: JSONValue = ["iv": .string(Data(nonce).base64EncodedString()), "tag": .string(sealed.tag.base64EncodedString()), "data": .string(sealed.ciphertext.base64EncodedString())]
        let token = envelope.encoded().base64EncodedString()
        #expect(RoborockSession.decrypt(encryptedToken: token, key: key)?.u == "u_example")
        #expect(RoborockSession.decrypt(encryptedToken: token, key: Data(count: 32)) == nil)
        #expect(RoborockSession.decrypt(encryptedToken: "not base64", key: key) == nil)
    }

    @Test func readsTheHomebridgeSessionFile() throws {
        let file = JSONValue.object(["val": .string(Sample.session.text()), "ack": true]).encoded()
        let session = try JSONDecoder().decode(RoborockSession.self, from: file)
        #expect(session.isValid && session.k == "k_example" && session.broker == "ssl://mqtt-eu.roborock.com:8883")
    }

    @Test func readsTheClockSkew() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RoborockHawkAPI.skew(date: "Tue, 14 Nov 2023 22:11:20 GMT", now: now) == 120)
        #expect(RoborockHawkAPI.skew(date: nil, now: now) == nil)
    }
}
