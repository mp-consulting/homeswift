import Foundation

/// A CoAP message (RFC 7252, section 3) as it travels in one UDP datagram: the 4-byte header, the token, the options in
/// delta encoding and the payload after the `0xFF` marker. No transport, retransmission or block transfer: devices
/// that speak CoAP on a LAN (Shelly's CoIoT, which multicasts status as non-confirmable messages) need the codec only.
public struct CoAPMessage: Sendable, Equatable {
    public enum MessageType: UInt8, Sendable {
        case confirmable = 0
        case nonConfirmable = 1
        case acknowledgement = 2
        case reset = 3
    }

    /// One option: its number and its raw value.
    public struct Option: Sendable, Equatable {
        public var number: Int
        public var value: [UInt8]

        public init(number: Int, value: [UInt8]) {
            self.number = number
            self.value = value
        }

        /// The value as an unsigned integer, big endian (RFC 7252's `uint` format); nil beyond 8 bytes.
        public var unsignedValue: UInt64? {
            guard value.count <= 8 else { return nil }
            return value.reduce(0) { $0 << 8 | UInt64($1) }
        }

        /// The value as UTF-8 text.
        public var stringValue: String? { String(bytes: value, encoding: .utf8) }
    }

    /// The option numbers RFC 7252 names that devices commonly use.
    public enum OptionNumber {
        public static let uriHost = 3
        public static let uriPort = 7
        public static let uriPath = 11
        public static let contentFormat = 12
        public static let uriQuery = 15
    }

    public var type: MessageType
    /// The code as one byte: class × 32 + detail (`0.01` GET is 1, `2.05` Content is 69).
    public var code: UInt8
    public var messageID: UInt16
    public var token: [UInt8]
    /// In the order they were sent; `encoded()` sorts them by number, as the format requires.
    public var options: [Option]
    public var payload: [UInt8]

    public init(type: MessageType, code: UInt8, messageID: UInt16, token: [UInt8] = [], options: [Option] = [], payload: [UInt8] = []) {
        self.type = type
        self.code = code
        self.messageID = messageID
        self.token = token
        self.options = options
        self.payload = payload
    }

    /// The code's class and detail, as `2.05` is written.
    public var codeClass: UInt8 { code >> 5 }
    public var codeDetail: UInt8 { code & 0x1F }

    /// The values of every option with this number, in order.
    public func options(_ number: Int) -> [Option] { options.filter { $0.number == number } }

    /// The first option with this number.
    public func option(_ number: Int) -> Option? { options.first { $0.number == number } }

    /// The Uri-Path segments.
    public var uriPath: [String] { options(OptionNumber.uriPath).compactMap(\.stringValue) }

    /// Parses a datagram. Throws for a version other than 1, a token longer than 8 bytes, a truncated message, the
    /// reserved nibble 15 in an option header, or a payload marker with no payload after it.
    public init(bytes: some Collection<UInt8>) throws(CoAPError) {
        let bytes = Array(bytes)
        guard bytes.count >= 4 else { throw .truncated }
        guard bytes[0] >> 6 == 1 else { throw .unsupportedVersion(Int(bytes[0] >> 6)) }
        type = MessageType(rawValue: (bytes[0] >> 4) & 0x3)!
        let tokenLength = Int(bytes[0] & 0xF)
        guard tokenLength <= 8 else { throw .invalidTokenLength(tokenLength) }
        code = bytes[1]
        messageID = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        var index = 4
        guard bytes.count >= index + tokenLength else { throw .truncated }
        token = Array(bytes[index..<index + tokenLength])
        index += tokenLength
        options = []
        payload = []
        var number = 0
        while index < bytes.count {
            let header = bytes[index]
            index += 1
            if header == 0xFF {
                guard index < bytes.count else { throw .emptyPayload }
                payload = Array(bytes[index...])
                return
            }
            func extended(_ nibble: UInt8) throws(CoAPError) -> Int {
                switch nibble {
                case 0...12:
                    return Int(nibble)
                case 13:
                    guard index < bytes.count else { throw .truncated }
                    defer { index += 1 }
                    return Int(bytes[index]) + 13
                case 14:
                    guard index + 1 < bytes.count else { throw .truncated }
                    defer { index += 2 }
                    return (Int(bytes[index]) << 8 | Int(bytes[index + 1])) + 269
                default:
                    throw .invalidOption
                }
            }
            // The delta's extension bytes come before the length's.
            let delta = try extended(header >> 4)
            let length = try extended(header & 0xF)
            number += delta
            guard index + length <= bytes.count else { throw .truncated }
            options.append(Option(number: number, value: Array(bytes[index..<index + length])))
            index += length
        }
    }

    /// The datagram: the options sorted by number (stable, so repeated ones keep their order), the payload marker only
    /// before a payload.
    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = [1 << 6 | type.rawValue << 4 | UInt8(min(token.count, 8)), code, UInt8(messageID >> 8), UInt8(messageID & 0xFF)]
        bytes += token.prefix(8)
        var previous = 0
        let sorted = options.enumerated().sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }.map(\.element)
        for option in sorted {
            func split(_ value: Int) -> (nibble: UInt8, extra: [UInt8]) {
                switch value {
                case ..<13: (UInt8(value), [])
                case ..<269: (13, [UInt8(value - 13)])
                default: (14, [UInt8((value - 269) >> 8), UInt8((value - 269) & 0xFF)])
                }
            }
            let delta = split(option.number - previous)
            let length = split(option.value.count)
            bytes.append(delta.nibble << 4 | length.nibble)
            bytes += delta.extra + length.extra + option.value
            previous = option.number
        }
        if !payload.isEmpty {
            bytes.append(0xFF)
            bytes += payload
        }
        return bytes
    }
}

public enum CoAPError: Error, Equatable, Sendable, CustomStringConvertible {
    case truncated
    case unsupportedVersion(Int)
    case invalidTokenLength(Int)
    case invalidOption
    case emptyPayload

    public var description: String {
        switch self {
        case .truncated: "the CoAP message is truncated"
        case .unsupportedVersion(let version): "CoAP version \(version) is not supported"
        case .invalidTokenLength(let length): "a CoAP token of \(length) bytes is invalid"
        case .invalidOption: "a CoAP option header is invalid"
        case .emptyPayload: "a CoAP payload marker is followed by nothing"
        }
    }
}
