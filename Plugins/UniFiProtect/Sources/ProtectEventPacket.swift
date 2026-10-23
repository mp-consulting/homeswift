import Foundation
import HomeswiftPlugin

/// A packet of the realtime update events API (`/proxy/protect/ws/updates`).
///
/// Each WebSocket message carries two frames, an action frame and a data frame, each an eight-byte header
/// and a payload:
///
/// | Byte | Meaning |
/// |---|---|
/// | 0 | Frame type: 1 action, 2 data |
/// | 1 | Payload format: 1 JSON, 2 UTF-8 string, 3 raw bytes |
/// | 2 | 1 when the payload is zlib-deflated |
/// | 3 | Always 0 |
/// | 4–7 | Payload size, big-endian |
///
/// The action frame is JSON with `action` (`add`, `update`, `remove`), `id`, `modelKey` and `newUpdateId`;
/// the data frame is, for updates of devices, a subset of the device's bootstrap JSON.
struct ProtectEventPacket: Sendable, Equatable {
    var header: JSONValue
    var payload: JSONValue

    /// What a data frame can carry besides JSON is kept as a string (UTF-8) or base64 (raw bytes).
    var action: String { header.string("action") ?? "" }
    var id: String { header.string("id") ?? "" }
    var modelKey: String { header.string("modelKey") ?? "" }

    static let headerSize = 8
    /// Largest size a deflated frame may inflate to; event payloads are small JSON documents.
    static let maximumInflatedSize = 16 * 1024 * 1024

    enum DecodeError: Error, CustomStringConvertible, Equatable {
        case lengthMismatch
        case inflate(String)
        case unexpectedFrame
        case invalidJSON
        case unknownPayloadFormat(Int)

        var description: String {
            switch self {
            case .lengthMismatch: "Packet length doesn't match header information"
            case .inflate(let reason): "could not be decompressed: \(reason)"
            case .unexpectedFrame: "unexpected frame type"
            case .invalidJSON: "invalid JSON"
            case .unknownPayloadFormat(let format): "unknown payload format \(format)"
            }
        }
    }

    /// Decodes a packet; throws with the reason the Homebridge plugin logged.
    static func decode(_ packet: Data) throws -> ProtectEventPacket {
        let bytes = [UInt8](packet)
        guard bytes.count >= headerSize else { throw DecodeError.lengthMismatch }
        let dataOffset = Int(readUInt32(bytes, at: 4)) + headerSize
        guard dataOffset + headerSize <= bytes.count, bytes.count == dataOffset + headerSize + Int(readUInt32(bytes, at: dataOffset + 4)) else {
            throw DecodeError.lengthMismatch
        }
        let action = try decodeFrame(Array(bytes[0..<dataOffset]), expected: 1)
        let data = try decodeFrame(Array(bytes[dataOffset...]), expected: 2)
        return ProtectEventPacket(header: action, payload: data)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func decodeFrame(_ frame: [UInt8], expected type: UInt8) throws -> JSONValue {
        guard frame.count >= headerSize, frame[0] == type else { throw DecodeError.unexpectedFrame }
        let format = Int(frame[1])
        var payload = Data(frame[headerSize...])
        if frame[2] != 0 {
            do {
                payload = try Inflate.zlib(payload, maximumSize: maximumInflatedSize)
            } catch let error as Inflate.Failure {
                if case .tooLarge = error { throw DecodeError.inflate("decompressed size exceeds \(maximumInflatedSize) bytes") }
                throw DecodeError.inflate(error.description)
            }
        }
        if type == 1 {
            guard format == 1, let json = try? JSONValue(data: payload) else { throw DecodeError.invalidJSON }
            return json
        }
        switch format {
        case 1:
            guard let json = try? JSONValue(data: payload) else { throw DecodeError.invalidJSON }
            return json
        case 2: return .string(String(decoding: payload, as: UTF8.self))
        case 3: return .string(payload.base64EncodedString())
        default: throw DecodeError.unknownPayloadFormat(format)
        }
    }

    /// Encodes a packet the way the controller does, for tests and tools.
    static func encode(header: JSONValue, payload: JSONValue, deflate: (Data) -> Data? = { _ in nil }) -> Data {
        func frame(_ type: UInt8, _ value: JSONValue) -> Data {
            var body = value.encoded()
            var deflated: UInt8 = 0
            if let compressed = deflate(body) {
                body = compressed
                deflated = 1
            }
            var data = Data([type, 1, deflated, 0])
            let size = UInt32(body.count)
            data.append(contentsOf: [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
            data.append(body)
            return data
        }
        return frame(1, header) + frame(2, payload)
    }
}
