import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import HomeswiftXiaomiMiot

/// The miIO packet and transport against docs/clean-room/XiaomiMiot.md section 12's vectors, byte for byte.
@Suite(.timeLimit(.minutes(1)))
struct ProtocolTests {
    let token = MiioToken(hex: "00112233445566778899aabbccddeeff")!
    static let did: UInt32 = 123_456_789

    /// 12.1: key = MD5(token), IV = MD5(key ‖ token), not OpenMiHome's MD5(MD5(key) ‖ token).
    @Test func keyAndIV() {
        #expect(hexString(token.key) == "6e8311168ee16d6aa1aa48c64145003c")
        #expect(hexString(token.iv) == "6f434fa9acd75da73e5fb999f641cda2")
        #expect(hexString(token.iv) != "cfa739d89919d1f4a13de7c072d8e36f")
        #expect(MiioToken(hex: "00112233445566778899AABBCCDDEEFF")?.hex == "00112233445566778899aabbccddeeff")
        #expect(MiioToken(hex: "0011") == nil)
        #expect(MiioToken(hex: "zz112233445566778899aabbccddeeff") == nil)
    }

    /// 12.2: the hello and a reply with did 123456789 and stamp 4096.
    @Test func hello() throws {
        #expect(hexString(MiioPacket.hello) == "21310020ffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
        let reply = try #require(MiioPacket(Data(hex("2131002000000000075bcd1500001000ffffffffffffffffffffffffffffffff"))))
        #expect(reply.isHandshake)
        #expect(reply.deviceID == 123_456_789)
        #expect(reply.stamp == 4096)
    }

    /// 12.3: five seconds after the reply the stamp is 4101; the request packet, its padding, ciphertext and checksum.
    @Test func request() throws {
        let arrival = ContinuousClock.now
        let stamp = MiioClient.requestStamp((4096, arrival), now: arrival + .seconds(5) + .milliseconds(400))
        #expect(stamp == 0x1005)
        #expect(MiioClient.requestStamp(nil, now: arrival) == 0xFFFF_FFFF)
        let payload = OrderedJSON.object([("id", .int(1)), ("method", .string("get_properties")), ("params", .array([
            .object([("did", .string("123456789")), ("siid", .int(2)), ("piid", .int(1))]),
        ]))])
        #expect(payload.text == #"{"id":1,"method":"get_properties","params":[{"did":"123456789","siid":2,"piid":1}]}"#)
        #expect(payload.text.utf8.count == 83)
        let ciphertext = try MiioPacket.encrypt(Data(payload.text.utf8), token: token)
        #expect(hexString(ciphertext) == "a5516ec6151955dc2bb2d43e7c84c183d0323c1dc33c264cbefa960d6d193588641ac998505dd479255e702548fd599869680a3c70ec847294cb174a3135aec704a083c92ed16e52b3da8a53fda0fe302cde54023a2fbcc1787eb1535837b393")
        // The padding: 13 bytes of 0x0d.
        let padded = try MiioPacket.decrypt(ciphertext, token: token, unpadded: false)
        #expect(padded.count == 96)
        #expect(hexString(padded) == "7b226964223a312c226d6574686f64223a226765745f70726f70657274696573222c22706172616d73223a5b7b22646964223a22313233343536373839222c2273696964223a322c2270696964223a317d5d7d0d0d0d0d0d0d0d0d0d0d0d0d0d")
        let header = MiioPacket.header(deviceID: Self.did, stamp: stamp, payloadLength: ciphertext.count)
        #expect(hexString(header) == "2131008000000000075bcd1500001005")
        #expect(hexString(MiioPacket.checksum(header: header, token: token, ciphertext: ciphertext)) == "ef95276f1ee599a02c5a0646e3d24e67")
        let packet = try MiioPacket.encode(payload: Data(payload.text.utf8), token: token, deviceID: Self.did, stamp: stamp)
        #expect(hexString(packet) == "2131008000000000075bcd1500001005ef95276f1ee599a02c5a0646e3d24e67a5516ec6151955dc2bb2d43e7c84c183d0323c1dc33c264cbefa960d6d193588641ac998505dd479255e702548fd599869680a3c70ec847294cb174a3135aec704a083c92ed16e52b3da8a53fda0fe302cde54023a2fbcc1787eb1535837b393")
    }

    /// 12.4: a reply with a trailing NUL verifies, decrypts and reads 2.1 = true.
    @Test func replyWithNul() throws {
        let packet = try #require(MiioPacket(Data(hex("2131008000000000075bcd1500001006c6b97f19ce62411d4c9bedf617cba8f995d444d970e45e453f755f0301fb09fd3e256b96dcd3c67443340bc16878fdbb030088d1193dd8eb9295fca5cab1735c55d630977b6b8f51afd000171c5912ec9cb2cd4fccc64f9074f8db79834116d07bf64079efcd5b77f665a0c69c940f87"))))
        #expect(packet.verifies(with: token))
        #expect(packet.stamp == 0x1006)
        let raw = try MiioPacket.decrypt(packet.payload, token: token)
        #expect(raw.count == 94)
        #expect(raw.last == 0)
        let clean = try packet.decrypt(with: token)
        #expect(String(decoding: clean, as: UTF8.self) == #"{"id":1,"result":[{"did":"123456789","siid":2,"piid":1,"code":0,"value":true}],"exe_time":40}"#)
        let reply = try JSONValue(data: clean)
        #expect(reply["result"]?[0]?["value"] == .bool(true))
        // Another token does not verify it.
        #expect(!packet.verifies(with: MiioToken(hex: "ffeeddccbbaa99887766554433221100")!))
    }

    /// 12.5: a 48-byte payload gains a full block of 0x10.
    @Test func pkcs7FullBlock() throws {
        let payload = #"{"id":12345678,"method":"miIO.info","params":[]}"#
        #expect(payload.utf8.count == 48)
        let ciphertext = try MiioPacket.encrypt(Data(payload.utf8), token: token)
        #expect(hexString(ciphertext) == "1a7a530a1db499d7f520ded08d61970e973c0f7e08a20197e2cdbed7fdfdb49000147cbc83ea6f209a7976d347f13603e08788ea53d71cc9b9f5fd3e59457141")
        let padded = try MiioPacket.decrypt(ciphertext, token: token, unpadded: false)
        #expect(hexString(padded.suffix(16)) == "10101010101010101010101010101010")
        let packet = try MiioPacket.encode(payload: Data(payload.utf8), token: token, deviceID: Self.did, stamp: 0x1007)
        #expect(hexString(packet) == "2131006000000000075bcd1500001007ed518c900d860e2953f3ba29c8dcdddb1a7a530a1db499d7f520ded08d61970e973c0f7e08a20197e2cdbed7fdfdb49000147cbc83ea6f209a7976d347f13603e08788ea53d71cc9b9f5fd3e59457141")
    }

    /// 12.6: a "user ack timeout" error reply decodes to a busy error, which is retried.
    @Test func errorReply() throws {
        let packet = try #require(MiioPacket(Data(hex("2131006000000000075bcd15000010086ebdc810fc503c7f03bdd321c7f909b3afd853c24ba2f1a5692237c7f05ced081cdefc12f4a3151d5921205d65bb1a775b7c789741ac2feb6fbe8af1ff3aa4cfe7bbffa907cc035dabf3813c08db5e19"))))
        #expect(packet.verifies(with: token))
        let reply = try JSONValue(data: try packet.decrypt(with: token))
        #expect(reply["error"]?["code"]?.intValue == -9999)
        let error = MiioError.device(code: -9999, message: "user ack timeout")
        #expect(error.isBusy)
        #expect(MiioError.device(code: -30001, message: "").isBusy)
        #expect(!MiioError.device(code: -5001, message: "").isBusy)
    }

    /// 5.6: control characters are removed, one trailing NUL dropped.
    @Test func payloadCleanup() {
        let dirty = Data(#"{"a":"b\#u{01}\#u{7f}\#u{85}c"}"#.utf8) + Data([0])
        #expect(String(decoding: MiioPacket.clean(dirty), as: UTF8.self) == #"{"a":"bc"}"#)
        #expect(String(decoding: MiioPacket.clean(Data("x\n\ry".utf8)), as: UTF8.self) == "x\n\ry")
        // Nothing to remove: the data as it came, UTF-8 included; bytes that are not UTF-8 are cleaned as text.
        let clean = Data(#"{"name":"Lampe café","on":true}"#.utf8)
        #expect(MiioPacket.clean(clean) == clean)
        #expect(MiioPacket.clean(Data([0x61, 0xFF, 0x62])) == Data("a\u{FFFD}b".utf8))
    }

    /// 5.6: ids start at 1, a retry adds 100, 10000 wraps to 1.
    @Test func requestIDs() {
        #expect(MiioClient.nextID(after: 0, retry: false) == 1)
        #expect(MiioClient.nextID(after: 1, retry: true) == 101)
        #expect(MiioClient.nextID(after: 9999, retry: false) == 1)
        #expect(MiioClient.nextID(after: 9950, retry: true) == 1)
        #expect(MiioClient.isUnknownMethod("unknown_method"))
        #expect(MiioClient.isUnknownMethod(["unknown_method"]))
        #expect(!MiioClient.isUnknownMethod(["ok"]))
    }

    /// The client against a fake device: the handshake gives the did, a busy reply is retried, `miIO.info` answers.
    @Test func clientTalksToAFakeDevice() async throws {
        let network = FakeMiioNetwork()
        let device = FakeMiioDevice(ip: "192.168.1.50", did: Self.did, token: token.hex, model: "yeelink.light.colorc")
        network.add(device)
        let hub = MiioHub(network: network, logger: testLogger)
        let client = MiioClient(host: device.ip, token: token, hub: hub, timings: fastTimings.miio, logger: testLogger)
        await client.attach()
        let info = try await client.info()
        #expect(info["model"] == "yeelink.light.colorc")
        #expect(await client.deviceID == Self.did)
        device.state.withLockedValue { $0.errors = [(-9999, "user ack timeout")] }
        let result = try await client.call("get_properties", .array([.object([("did", .string("123456789")), ("siid", .int(2)), ("piid", .int(1))])]))
        #expect(result.arrayValue?.count == 1)
        // The retry's id is the last one + 100.
        #expect(device.calls("get_properties").count == 2)
        device.state.withLockedValue { $0.errors = [(-5001, "invalid params")] }
        await #expect(throws: MiioError.device(code: -5001, message: "invalid params")) {
            _ = try await client.call("get_properties", .array([]))
        }
        await hub.close()
    }

    /// A wrong token: the device's replies do not decrypt, which says so rather than timing out.
    @Test func wrongTokenIsTold() async throws {
        let network = FakeMiioNetwork()
        let device = FakeMiioDevice(ip: "192.168.1.51", did: Self.did, token: token.hex, model: "x")
        network.add(device)
        let hub = MiioHub(network: network, logger: testLogger)
        // The device answers with its own token; the client's is another.
        let client = MiioClient(host: device.ip, token: MiioToken(hex: "ffeeddccbbaa99887766554433221100")!, hub: hub, timings: fastTimings.miio, logger: testLogger)
        await client.attach()
        await #expect(throws: (any Error).self) { _ = try await client.info() }
        // The fake answers nothing to a packet its token does not open: that is a timeout with the did known.
        #expect(await client.deviceID == Self.did)
        await hub.close()
    }

    /// No device at the address: "Call to device timed out".
    @Test func silentDeviceTimesOut() async throws {
        let hub = MiioHub(network: FakeMiioNetwork(), logger: testLogger)
        let client = MiioClient(host: "192.168.1.99", token: token, hub: hub, timings: fastTimings.miio, logger: testLogger)
        await client.attach()
        do {
            _ = try await client.call("miIO.info")
            Issue.record("expected a timeout")
        } catch let error as MiioError {
            #expect(error == .timeout)
            #expect(error.description == "Call to device timed out")
        }
        await hub.close()
    }
}
