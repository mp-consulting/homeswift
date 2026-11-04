import Foundation
import HomeswiftNetwork

/// What goes wrong talking to a device, in words a person can act on. None carries a key, a password or a handshake
/// message; a device's own text (a handshake failure's explanation) is cut short and stripped of control characters.
enum ESPHomeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A plaintext connection got a Noise frame: the device has `api: encryption:`.
    case requiresEncryption
    /// An encrypted connection got a plaintext frame: the device has no encryption.
    case usesPlaintext
    case invalidMarker(UInt8)
    case malformedFrame(String)
    /// `encryptionKey` does not decode to 32 bytes; only its length is told.
    case malformedKey(length: Int)
    case unknownNoiseProtocol(UInt8)
    /// The device announced another MAC than the one this device was set up with.
    case wrongDevice(expected: String, found: String)
    /// The device refused the handshake with "Handshake MAC failure".
    case invalidEncryptionKey
    case handshakeFailed(String)
    /// A frame that did not decrypt after the handshake.
    case encryptionError
    case invalidPassword
    /// The device (firmware before 2026.1) asks for an API password and none is configured.
    case passwordRequired
    case incompatibleAPI(major: UInt32)
    case timedOut(String)
    /// The device closed the connection, or nothing came for the liveness timeout.
    case connectionLost
    /// The device asked to disconnect (it is rebooting).
    case disconnectedByDevice

    var description: String {
        switch self {
        case .requiresEncryption: "the device requires encryption: set its encryption key (encryptionKey)"
        case .usesPlaintext: "the device uses plaintext: remove the encryption key, or enable encryption on the device"
        case .invalidMarker(let byte): "the device sent an invalid marker byte (\(byte))"
        case .malformedFrame(let reason): "the device sent a malformed frame (\(reason))"
        case .malformedKey(let length): "the encryption key is malformed: it must be the base64 of 32 bytes (it decodes to \(length))"
        case .unknownNoiseProtocol(let byte): "the device chose an unknown encryption protocol (\(byte))"
        case .wrongDevice(let expected, let found): "another device answered (\(found), expected \(expected))"
        case .invalidEncryptionKey: "the device rejected the encryption key"
        case .handshakeFailed(let reason): "the encryption handshake failed (\(reason))"
        case .encryptionError: "a message from the device did not decrypt"
        case .invalidPassword: "the device rejected the API password"
        case .passwordRequired: "the device asks for its API password (password)"
        case .incompatibleAPI(let major): "the device's API version \(major) is not supported"
        case .timedOut(let step): "the device did not answer (\(step))"
        case .connectionLost: "the connection was lost"
        case .disconnectedByDevice: "the device disconnected"
        }
    }

    /// Errors only a change of configuration fixes: retrying would fail the same way.
    var needsConfiguration: Bool {
        switch self {
        case .invalidPassword, .passwordRequired, .invalidEncryptionKey, .malformedKey: true
        default: false
        }
    }
}

/// One message of the native API: its type id and its protobuf body.
struct ESPHomeFrame: Equatable, Sendable {
    var type: Int
    var body: [UInt8]
}

/// Bytes as they arrive, read from a start index so a long stream does not copy what it has read.
struct ByteQueue {
    private var bytes: [UInt8] = []
    private var start = 0

    var count: Int { bytes.count - start }
    var isEmpty: Bool { count == 0 }

    mutating func append(_ more: [UInt8]) {
        if start > 4096, start * 2 > bytes.count {
            bytes.removeFirst(start)
            start = 0
        }
        bytes += more
    }

    subscript(offset: Int) -> UInt8 { bytes[start + offset] }

    func peek(_ range: Range<Int>) -> [UInt8] { Array(bytes[(start + range.lowerBound)..<(start + range.upperBound)]) }

    mutating func consume(_ count: Int) {
        start += count
        if start == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            start = 0
        }
    }
}

/// The plaintext framing: `0x00`, varint(body length), varint(type), body.
struct PlaintextFramer {
    /// A varint longer than this many bytes is refused, as the reference client does.
    static let maximumVarintBytes = 4
    static let maximumLength = 65535

    private var queue = ByteQueue()

    static func encode(_ frame: ESPHomeFrame) -> [UInt8] {
        [0x00] + Protobuf.varint(UInt64(frame.body.count)) + Protobuf.varint(UInt64(frame.type)) + frame.body
    }

    mutating func append(_ bytes: [UInt8]) { queue.append(bytes) }

    /// The next complete frame; nil until enough bytes came. Throws for a stream that cannot be plaintext.
    mutating func next() throws -> ESPHomeFrame? {
        guard !queue.isEmpty else { return nil }
        switch queue[0] {
        case 0x00: break
        case 0x01: throw ESPHomeError.requiresEncryption
        case let byte: throw ESPHomeError.invalidMarker(byte)
        }
        var offset = 1
        guard let length = try varint(&offset), let type = try varint(&offset) else { return nil }
        guard length <= UInt64(Self.maximumLength) else { throw ESPHomeError.malformedFrame("length \(length)") }
        guard queue.count - offset >= Int(length) else { return nil }
        let body = queue.peek(offset..<(offset + Int(length)))
        queue.consume(offset + Int(length))
        return ESPHomeFrame(type: Int(type), body: body)
    }

    private func varint(_ offset: inout Int) throws -> UInt64? {
        var result: UInt64 = 0
        for index in 0..<Self.maximumVarintBytes {
            guard offset < queue.count else { return nil }
            let byte = queue[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << (7 * UInt64(index))
            if byte & 0x80 == 0 { return result }
        }
        throw ESPHomeError.malformedFrame("varint longer than \(Self.maximumVarintBytes) bytes")
    }
}

/// The Noise framing: `0x01`, a 2-byte big-endian length, the payload.
struct NoiseFramer {
    private var queue = ByteQueue()

    static func encode(_ payload: [UInt8]) -> [UInt8] {
        [0x01, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)] + payload
    }

    mutating func append(_ bytes: [UInt8]) { queue.append(bytes) }

    mutating func next() throws -> [UInt8]? {
        guard !queue.isEmpty else { return nil }
        switch queue[0] {
        case 0x01: break
        case 0x00: throw ESPHomeError.usesPlaintext
        case let byte: throw ESPHomeError.invalidMarker(byte)
        }
        guard queue.count >= 3 else { return nil }
        let length = Int(queue[1]) << 8 | Int(queue[2])
        guard queue.count >= 3 + length else { return nil }
        let payload = queue.peek(3..<(3 + length))
        queue.consume(3 + length)
        return payload
    }
}

/// The Noise handshake and transport of the native API (`Noise_NNpsk0_25519_ChaChaPoly_SHA256`, prologue
/// `NoiseAPIInit\0\0`): the client's hello and first message, the device's hello (protocol, name, MAC), its answer,
/// then each message encrypted as `type (2 bytes) · length (2 bytes) · body`.
enum ESPHomeNoise {
    static let prologue: [UInt8] = Array("NoiseAPIInit".utf8) + [0, 0]
    static let handshakeMACFailure = "Handshake MAC failure"

    /// The 32 bytes of a key as ESPHome writes it (`api: encryption: key:`), base64; characters outside the alphabet
    /// (spaces, line breaks) are ignored.
    static func psk(fromBase64 text: String) throws -> [UInt8] {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let cleaned = String(text.filter { alphabet.contains($0) })
        guard let data = Data(base64Encoded: cleaned) else { throw ESPHomeError.malformedKey(length: 0) }
        guard data.count == 32 else { throw ESPHomeError.malformedKey(length: data.count) }
        return Array(data)
    }

    /// The device's hello: protocol byte, then (newer firmware) its name and its MAC, each ended by a zero byte.
    struct ServerHello: Equatable {
        var name: String?
        var mac: String?

        init(_ body: [UInt8]) throws {
            guard let chosen = body.first else { throw ESPHomeError.handshakeFailed("empty hello") }
            guard chosen == 0x01 else { throw ESPHomeError.unknownNoiseProtocol(chosen) }
            let parts = body.dropFirst().split(separator: 0, omittingEmptySubsequences: false)
            name = parts.first.flatMap { $0.isEmpty ? nil : Sanitized.text(String(decoding: $0, as: UTF8.self), limit: 31) }
            mac = parts.dropFirst().first.flatMap { $0.isEmpty ? nil : Sanitized.text(String(decoding: $0, as: UTF8.self), limit: 17) }
        }
    }

    /// The device's answer to the first message: its own message, or why it refused.
    static func handshakeResult(_ body: [UInt8]) throws -> [UInt8] {
        guard let status = body.first else { throw ESPHomeError.handshakeFailed("empty answer") }
        guard status == 0 else {
            let reason = String(decoding: body.dropFirst(), as: UTF8.self)
            if reason == handshakeMACFailure { throw ESPHomeError.invalidEncryptionKey }
            throw ESPHomeError.handshakeFailed(Sanitized.text(reason, limit: 64))
        }
        return Array(body.dropFirst())
    }

    static func plaintext(_ frame: ESPHomeFrame) -> [UInt8] {
        [UInt8(frame.type >> 8 & 0xff), UInt8(frame.type & 0xff), UInt8(frame.body.count >> 8 & 0xff), UInt8(frame.body.count & 0xff)] + frame.body
    }

    /// A decrypted message; the inner length is not trusted, the body is what follows the four bytes.
    static func frame(_ plaintext: [UInt8]) throws -> ESPHomeFrame {
        guard plaintext.count >= 4 else { throw ESPHomeError.malformedFrame("short encrypted message") }
        return ESPHomeFrame(type: Int(plaintext[0]) << 8 | Int(plaintext[1]), body: Array(plaintext.dropFirst(4)))
    }
}

/// Text a device sent, safe for a log line or a page: control characters dropped, cut to a length.
enum Sanitized {
    static func text(_ text: String, limit: Int = 120) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit).map(Character.init))
    }
}
