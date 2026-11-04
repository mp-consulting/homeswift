import Foundation
import Testing

@testable import HomeswiftNetwork

@Suite struct CoAPTests {
    static func bytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    /// A Shelly CoIoT status: extended option deltas (14 and 13) and lengths, then the payload.
    @Test func parsesAShellyStatus() throws {
        let packet = Self.bytes(
            "501e0001b36369740173ed0bec09534853572d504d234134434631324634353637382332d243017e82002aff"
                + "7b2247223a5b5b302c313130312c315d2c5b302c343130312c32332e34355d2c5b302c343130332c313233345d2c"
                + "5b302c333130342c34312e325d2c5b302c323130312c305d5d7d")
        #expect(packet.count == 116)
        let message = try CoAPMessage(bytes: packet)
        #expect(message.type == .nonConfirmable)
        #expect(message.code == 30)
        #expect(message.codeClass == 0 && message.codeDetail == 30)
        #expect(message.messageID == 1)
        #expect(message.token.isEmpty)
        #expect(message.uriPath == ["cit", "s"])
        #expect(message.option(3332)?.stringValue == "SHSW-PM#A4CF12F45678#2")
        #expect(message.option(3412)?.unsignedValue == 382)
        #expect(message.option(3420)?.unsignedValue == 42)
        #expect(String(decoding: message.payload, as: UTF8.self).hasPrefix(#"{"G":[[0,1101,1]"#))
        #expect(message.encoded() == packet)
    }

    /// aioshelly's unicast `/cit/s` request, byte for byte.
    @Test func encodesARequest() {
        let request = CoAPMessage(type: .nonConfirmable, code: 1, messageID: 0x0A, options: [
            .init(number: 11, value: Array("cit".utf8)), .init(number: 11, value: Array("s".utf8)),
        ], payload: [0])
        #expect(request.encoded() == [0x50, 0x01, 0x00, 0x0A, 0xB3, 0x63, 0x69, 0x74, 0x01, 0x73, 0xFF, 0x00])
    }

    @Test func roundTripsLongOptions() throws {
        let message = CoAPMessage(type: .confirmable, code: 69, messageID: 7, token: [1, 2], options: [
            .init(number: 3420, value: [0, 1]), .init(number: 11, value: Array(repeating: 0x61, count: 300)), .init(number: 12, value: []),
        ], payload: Array("hello".utf8))
        let parsed = try CoAPMessage(bytes: message.encoded())
        #expect(parsed.options.map(\.number) == [11, 12, 3420])
        #expect(parsed.option(11)?.value.count == 300)
        #expect(parsed.token == [1, 2])
        #expect(parsed.payload == Array("hello".utf8))
    }

    @Test func rejectsMalformedMessages() {
        #expect(throws: CoAPError.truncated) { try CoAPMessage(bytes: [0x50, 0x1e]) }
        #expect(throws: CoAPError.unsupportedVersion(2)) { try CoAPMessage(bytes: [0x90, 0x1e, 0, 1]) }
        #expect(throws: CoAPError.invalidOption) { try CoAPMessage(bytes: [0x50, 0x1e, 0, 1, 0xF1, 0]) }
        #expect(throws: CoAPError.emptyPayload) { try CoAPMessage(bytes: [0x50, 0x1e, 0, 1, 0xFF]) }
        #expect(throws: CoAPError.truncated) { try CoAPMessage(bytes: [0x50, 0x1e, 0, 1, 0x03, 0x61]) }
    }
}
