import Foundation
import Testing

@testable import Homeswift

struct TLV8Tests {
    @Test func roundTripsAndFragmentsLongValues() throws {
        let long = Data((0..<600).map { UInt8($0 % 251) })
        let tlv = TLV8([(.state, Data([1])), (.publicKey, long), (.salt, Data())])
        let encoded = tlv.encoded()
        // 600 bytes split as 255 + 255 + 90, each with its own two-byte header.
        #expect(encoded.count == 3 + (2 * 3 + 600) + 2)
        let decoded = try TLV8(decoding: encoded)
        #expect(decoded.byte(.state) == 1)
        #expect(decoded[.publicKey] == long)
        #expect(decoded[.salt] == Data())
    }

    @Test func splitsGroupsOnSeparators() throws {
        var tlv = TLV8()
        tlv.append(.identifier, Data("a".utf8))
        tlv.append(.separator, Data())
        tlv.append(.identifier, Data("b".utf8))
        let groups = try TLV8(decoding: tlv.encoded()).groups
        #expect(groups.map { $0[.identifier] } == [Data("a".utf8), Data("b".utf8)])
    }
}

struct SRPTests {
    /// Values produced by fast-srp-hap (the SRP used by HAP-NodeJS) with the same fixed inputs.
    @Test func matchesFastSRPHap() throws {
        let salt = Data(repeating: 7, count: 16)
        let server = SRP.Server(password: "031-45-154", salt: salt, privateKey: Data(repeating: 9, count: 32))
        let client = SRP.Client(privateKey: Data(repeating: 3, count: 32))
        #expect(server.publicKey.hex.hasPrefix("2c7ae7c3c58281a2"))
        #expect(client.publicKey.hex.hasPrefix("ba8925dbc3a76083"))

        let (clientKey, M1, expectedM2) = client.proof(salt: salt, serverPublicKey: server.publicKey, password: "031-45-154")
        #expect(M1.hex == "3cf8481972f7700660c8a3d560a0ad3e94b76e1bfd13ee1b72adaba34e45898b91eb45196141a47fbea44b7c11f20dc27d0776277abd3c04dfe99ba13c18c9eb")
        let result = try #require(server.verify(clientPublicKey: client.publicKey, clientProof: M1))
        #expect(result.sessionKey == clientKey)
        #expect(result.sessionKey.hex == "3ee0710903790f1d55fa5b7d10d2e6e5241a5e6d9a43cb6481f73b1bc8a9720c150f9ca17b9d7b7a868fd5de226bde0039a9a79d8c346987fb5e2451b06c26c4")
        #expect(result.proof == expectedM2)
        #expect(result.proof.hex == "921cb238e3f86d5973a4ca54d7247a8e9c79d233b402af0745b81a8720fef67639657f1d9bfb694d4c8dc28192087bfeea5607ea54bea9ea9e95e5ba1fea2b0b")
    }

    @Test func rejectsWrongCode() {
        let server = SRP.Server(password: "031-45-154")
        let client = SRP.Client()
        let (_, M1, _) = client.proof(salt: server.salt, serverPublicKey: server.publicKey, password: "031-45-155")
        #expect(server.verify(clientPublicKey: client.publicKey, clientProof: M1) == nil)
    }
}

struct SetupTests {
    @Test func validatesCodes() {
        #expect(SetupCode("031-45-154")?.rawValue == "031-45-154")
        #expect(SetupCode("03145154")?.rawValue == "031-45-154")
        #expect(SetupCode("005-21-956")?.description == "0052-1956")
        #expect(SetupCode("0052-1956")?.rawValue == "005-21-956")
        #expect(SetupCode("111-11-111") == nil)
        #expect(SetupCode("123-45-678") == nil)
        #expect(SetupCode("12-345-678x") == nil)
    }

    /// Same encoding as HAP-NodeJS's `Accessory.setupURI()`.
    @Test func buildsSetupURI() {
        #expect(makeSetupURI(code: SetupCode("031-45-154")!, category: .bridge, setupID: "ABCD") == "X-HM://0023ISYWYABCD")
    }

    @Test func shortensAppleUUIDs() {
        #expect(HAPUUID(0x25).shortForm == "25")
        #expect(HAPUUID("0000003E-0000-1000-8000-0026BB765291").shortForm == "3E")
        #expect(HAPUUID("D2B3E3C4-1111-2222-3333-444455556666").shortForm == "D2B3E3C4-1111-2222-3333-444455556666")
    }

    @Test func coercesValues() {
        #expect(CharacteristicType.on.coerce(.int(1)) == .bool(true))
        #expect(CharacteristicType.brightness.coerce(.double(42.4)) == .int(42))
        #expect(CharacteristicType.brightness.coerce(.int(101)) == nil)
        #expect(CharacteristicType.lockTargetState.coerce(.int(2)) == nil)
    }
}

struct SecureSessionTests {
    @Test func framesAcrossTheSizeLimit() throws {
        let secret = Data(repeating: 1, count: 32)
        var accessory = SecureSession(sharedSecret: secret, isAccessory: true)
        var controller = SecureSession(sharedSecret: secret, isAccessory: false)
        let message = Data((0..<2500).map { UInt8($0 % 256) })
        var wire = try accessory.encrypt(message)
        #expect(wire.count == 2500 + 3 * 18)
        // Deliver in two pieces to exercise partial frames.
        var partial = wire.prefix(1000)
        var received = try controller.decrypt(&partial)
        wire = partial + wire.dropFirst(1000)
        received += try controller.decrypt(&wire)
        #expect(received == message)
        #expect(wire.isEmpty)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
