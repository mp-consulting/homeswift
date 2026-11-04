import Crypto
import Foundation
import Testing

@testable import HomeswiftNetwork

private func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

struct ProtobufTests {
    @Test func varints() {
        // ESPHome's native API spec vectors.
        let vectors: [(UInt64, [UInt8])] = [
            (0, [0x00]), (42, [0x2a]), (127, [0x7f]), (128, [0x80, 0x01]), (300, [0xac, 0x02]), (65536, [0x80, 0x80, 0x04]), (149, [0x95, 0x01]),
        ]
        for (value, bytes) in vectors {
            #expect(Protobuf.varint(value) == bytes)
            var index = 0
            #expect(bytes.withUnsafeBytes { Protobuf.readVarint($0, &index) } == value)
            #expect(index == bytes.count)
        }
        var index = 0
        #expect([UInt8]([0x80, 0x80]).withUnsafeBytes { Protobuf.readVarint($0, &index) } == nil)
    }

    @Test func writesAndReadsFields() throws {
        var writer = ProtobufWriter()
        writer.fixed32(1, 0x1234_5678)
        writer.bool(2, true)
        writer.bool(3, false)
        writer.float(4, 0.5)
        writer.string(5, "Rainbow")
        writer.int32(6, -1)
        writer.uint32(7, 0)
        // The switch command of the spec's vectors: key, then state.
        #expect(Array(writer.bytes.prefix(7)) == [0x0d, 0x78, 0x56, 0x34, 0x12, 0x10, 0x01])
        let message = try #require(ProtobufMessage(writer.bytes))
        #expect(message.fixed32(1) == 0x1234_5678)
        #expect(message.bool(2))
        #expect(!message.has(3))
        #expect(message.float(4) == 0.5)
        #expect(message.string(5) == "Rainbow")
        #expect(message.int32(6) == -1)
        #expect(message.uint32(7) == 0)
        #expect(writer.bytes.count == 7 + 5 + 9 + 11)
    }

    @Test func repeatedFieldsPackedOrNot() throws {
        var writer = ProtobufWriter()
        writer.string(11, "None")
        writer.string(11, "Rainbow")
        writer.bytes(12, [0x23, 0x0b])
        writer.varint(12, 1)
        let message = try #require(ProtobufMessage(writer.bytes))
        #expect(message.strings(11) == ["None", "Rainbow"])
        #expect(message.enumerations(12) == [35, 11, 1])
    }

    @Test func skipsUnknownWireTypesAndRefusesTruncated() {
        // A fixed64 field (number 9) is skipped by the typed readers.
        let message = ProtobufMessage([0x49] + [UInt8](repeating: 1, count: 8) + [0x10, 0x01])
        #expect(message?.bool(2) == true)
        #expect(ProtobufMessage([0x0a, 0x05, 0x41]) == nil)
        #expect(ProtobufMessage([0x0b]) == nil)
        #expect(ProtobufMessage([]) != nil)
    }
}

struct NoiseTests {
    /// The NNpsk0 vector of the cacophony suite (github.com/haskell-cryptography/cacophony, vectors/cacophony.txt):
    /// two handshake messages with payloads, then four transport messages, alternating from the initiator.
    @Test func cacophonyVector() throws {
        let prologue = hex("4a6f686e2047616c74")
        let psk = hex("54686973206973206d7920417573747269616e20706572737065637469766521")
        let initiatorKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"))
        let responderKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"))
        let messages: [(payload: String, ciphertext: String)] = [
            ("4c756477696720766f6e204d69736573",
             "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c794479b962b8aff8485742ac32f905ba45369e2465fb59e138a93d67a0d1266b6a54"),
            ("4d757272617920526f746862617264",
             "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843d6062704d5a9c422a8e834423f8c1feada7e8d0d910a1a2cd030fb584221e3"),
            ("462e20412e20486179656b", "e632c3763d7669067383433197a3baddf146e9e70ad4b4e9e59e0f"),
            ("4361726c204d656e676572", "64c6bee32ea91c8474bb4c21d7a700109ad45af77b29764ba5eb1e"),
            ("4a65616e2d426170746973746520536179", "e2fa0bed0603b62d3ccac2ecabbf3fe33f3e86514909b323361626266cb2471cc8"),
            ("457567656e2042f6686d20766f6e2042617765726b", "0c01dc9cec1fe4ddd692e8dd32188aa351088dc91183639a53b57aa4692b5ebdef8b8ca111"),
        ]
        var initiator = try NoiseHandshake(role: .initiator, prologue: prologue, psk: psk, ephemeral: initiatorKey)
        var responder = try NoiseHandshake(role: .responder, prologue: prologue, psk: psk, ephemeral: responderKey)

        let first = try initiator.writeMessage(payload: hex(messages[0].payload))
        #expect(first == hex(messages[0].ciphertext))
        #expect(try responder.readMessage(first) == hex(messages[0].payload))
        let second = try responder.writeMessage(payload: hex(messages[1].payload))
        #expect(second == hex(messages[1].ciphertext))
        #expect(try initiator.readMessage(second) == hex(messages[1].payload))
        #expect(initiator.isComplete && responder.isComplete)
        #expect(initiator.handshakeHash == hex("f4d03dc34495c95729ea6de9e1b59004b59733102488b3e24bc441e0be208eaf"))
        #expect(responder.handshakeHash == initiator.handshakeHash)

        var (initiatorSend, initiatorReceive) = try initiator.split()
        var (responderSend, responderReceive) = try responder.split()
        for (index, message) in messages.enumerated().dropFirst(2) {
            if index % 2 == 0 {
                let sealed = try initiatorSend.encrypt(hex(message.payload))
                #expect(sealed == hex(message.ciphertext))
                #expect(try responderReceive.decrypt(sealed) == hex(message.payload))
            } else {
                let sealed = try responderSend.encrypt(hex(message.payload))
                #expect(sealed == hex(message.ciphertext))
                #expect(try initiatorReceive.decrypt(sealed) == hex(message.payload))
            }
        }
    }

    @Test func wrongKeyFailsTheHandshake() throws {
        let prologue = Array("NoiseAPIInit".utf8) + [0, 0]
        var initiator = try NoiseHandshake(role: .initiator, prologue: prologue, psk: [UInt8](repeating: 1, count: 32))
        var responder = try NoiseHandshake(role: .responder, prologue: prologue, psk: [UInt8](repeating: 2, count: 32))
        let first = try initiator.writeMessage()
        #expect(first.count == 48)
        #expect(throws: NoiseError.decryptionFailed) { try responder.readMessage(first) }
        #expect(throws: NoiseError.invalidKey) { try NoiseHandshake(role: .initiator, prologue: [], psk: [1, 2, 3]) }
        #expect(throws: NoiseError.outOfOrder) { try initiator.split() }
    }

    @Test func nonceLayout() {
        #expect(NoiseCipherState.nonceBytes(0) == [UInt8](repeating: 0, count: 12))
        #expect(NoiseCipherState.nonceBytes(1) == [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func tamperedTransportMessageIsRefused() throws {
        var send = NoiseCipherState(key: [UInt8](repeating: 7, count: 32))
        var receive = NoiseCipherState(key: [UInt8](repeating: 7, count: 32))
        var sealed = try send.encrypt([0, 7, 0, 0])
        #expect(sealed.count == 20)
        sealed[0] ^= 1
        #expect(throws: NoiseError.decryptionFailed) { try receive.decrypt(sealed) }
        #expect(receive.nonce == 0)
    }
}
