import Crypto
import Foundation

/// HomeKit Data Stream framing (HAP-NodeJS's DataStreamConnection): a frame is a type byte (1), a 24-bit
/// big-endian payload length, the ChaCha20-Poly1305 ciphertext and its 16-byte tag; the four header bytes are
/// the additional data and each direction counts its frames for the nonce. The payload is a header length byte,
/// the header dictionary and the message dictionary, both HDS-encoded.
enum HDSFrame {
    static let maxPayloadLength = 0b1111_1111_1111_1111_1111

    /// The two keys of a session, from the HAP connection's shared secret and both salts.
    static func keys(sharedSecret: Data, controllerKeySalt: Data, accessoryKeySalt: Data) -> (accessoryToController: SymmetricKey, controllerToAccessory: SymmetricKey) {
        let salt = controllerKeySalt + accessoryKeySalt
        return (
            HAPCrypto.hkdf(sharedSecret, salt: salt, info: "HDS-Read-Encryption-Key"),
            HAPCrypto.hkdf(sharedSecret, salt: salt, info: "HDS-Write-Encryption-Key")
        )
    }

    /// One frame as read from the socket, still encrypted.
    struct Sealed: Equatable {
        var header: Data
        var ciphertext: Data
        var tag: Data
    }

    enum FrameError: Error { case payloadTooLong }

    /// The payload length in the header of the frame at `start`, whose four bytes `buffer` holds.
    static func payloadLength(_ buffer: Data, at start: Int) -> Int {
        Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
    }

    /// Takes every complete frame off the front of `buffer`; frames of another type are skipped.
    static func split(_ buffer: inout Data) throws -> [Sealed] {
        var frames: [Sealed] = []
        var start = buffer.startIndex
        while buffer.endIndex - start >= 4 {
            let type = buffer[start]
            let length = payloadLength(buffer, at: start)
            guard length <= maxPayloadLength else { throw FrameError.payloadTooLong }
            guard buffer.endIndex - start - 4 >= length + 16 else { break }
            let payload = start + 4
            if type == 1 {
                frames.append(Sealed(
                    header: Data(buffer[start..<payload]), ciphertext: Data(buffer[payload..<payload + length]),
                    tag: Data(buffer[payload + length..<payload + length + 16])))
            }
            start = payload + length + 16
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        return frames
    }

    static func open(_ frame: Sealed, key: SymmetricKey, counter: UInt64) throws -> Data {
        try HAPCrypto.open(frame.ciphertext + frame.tag, key: key, nonce: HAPCrypto.nonce(counter: counter), aad: frame.header)
    }

    static func seal(payload: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        guard payload.count <= maxPayloadLength else { throw FrameError.payloadTooLong }
        let header = Data([1, UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)])
        return header + (try HAPCrypto.seal(payload, key: key, nonce: HAPCrypto.nonce(counter: counter), aad: header))
    }

    /// The plaintext payload of a message.
    static func payload(header: HDSDictionary, message: HDSDictionary) -> Data {
        let headerData = HDSWriter.encode(header)
        var payload = Data([UInt8(truncatingIfNeeded: headerData.count)])
        payload.append(headerData)
        payload.append(HDSWriter.encode(message))
        return payload
    }

    /// A decoded message.
    struct Message: Equatable {
        enum Kind: Equatable {
            case event
            case request(id: Int64)
            case response(id: Int64, status: Int64)
        }

        var kind: Kind
        var `protocol`: String
        var topic: String
        var message: HDSDictionary
    }

    /// Decodes a payload; nil when it is not a valid message (HAP-NodeJS drops those).
    static func message(from payload: Data) -> Message? {
        guard let headerLength = payload.first.map(Int.init), payload.count >= 1 + headerLength else { return nil }
        let headerData = payload.subdata(in: payload.startIndex + 1..<payload.startIndex + 1 + headerLength)
        let messageData = payload.subdata(in: payload.startIndex + 1 + headerLength..<payload.endIndex)
        guard case .dictionary(let header)? = try? HDSReader.decode(headerData),
            case .dictionary(let message)? = try? HDSReader.decode(messageData)
        else { return nil }
        let proto = header["protocol"]?.stringValue ?? ""
        if let event = header["event"]?.stringValue {
            return Message(kind: .event, protocol: proto, topic: event, message: message)
        } else if let request = header["request"]?.stringValue {
            return Message(kind: .request(id: header["id"]?.intValue ?? 0), protocol: proto, topic: request, message: message)
        } else if let response = header["response"]?.stringValue {
            return Message(
                kind: .response(id: header["id"]?.intValue ?? 0, status: header["status"]?.intValue ?? 0), protocol: proto, topic: response,
                message: message)
        }
        return nil
    }
}

/// HDS status codes (`HDSStatus`).
enum HDSStatus: Int64 {
    case success = 0
    case outOfMemory = 1
    case timeout = 2
    case headerError = 3
    case payloadError = 4
    case missingProtocol = 5
    case protocolSpecificError = 6
}
