import Foundation
import HomeswiftPlugin

/// The Kasa "Smart Home" protocol on port 9999 (docs/clean-room/TPLinkSmarthome.md, section 5): JSON obfuscated with an
/// autokey XOR cipher whose first key is 171, a 4-byte big-endian length before it over TCP, nothing over UDP.
enum KasaCipher {
    static let initialKey: UInt8 = 171

    /// Each ciphertext byte is the key of the next.
    static func encrypt(_ plaintext: some Sequence<UInt8>) -> [UInt8] {
        var key = initialKey
        return plaintext.map { byte in
            key = byte ^ key
            return key
        }
    }

    static func encrypt(_ text: String) -> [UInt8] { encrypt(Array(text.utf8)) }

    /// The key of each byte is the ciphertext byte before it.
    static func decrypt(_ ciphertext: some Sequence<UInt8>) -> [UInt8] {
        var key = initialKey
        return ciphertext.map { byte in
            defer { key = byte }
            return byte ^ key
        }
    }

    /// A TCP frame: the ciphertext's length, unsigned big-endian, then the ciphertext.
    static func frame(_ text: String) -> [UInt8] {
        let ciphertext = encrypt(text)
        let length = UInt32(ciphertext.count)
        return [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + ciphertext
    }
}

/// Gathers a TCP response as its segments arrive: complete once the length its first 4 bytes give is there.
struct KasaFrameReader {
    /// A device would not send more; a length beyond is a stream that is not this protocol.
    static let maximumLength = 1 << 20

    private(set) var buffer: [UInt8] = []

    enum Failure: Error, CustomStringConvertible {
        case tooLong(Int)
        var description: String {
            switch self {
            case .tooLong(let length): "the device announced a response of \(length) bytes"
            }
        }
    }

    /// Adds a segment; the decrypted response once the frame is complete.
    mutating func add(_ bytes: some Sequence<UInt8>) throws -> String? {
        buffer.append(contentsOf: bytes)
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
        guard length <= Self.maximumLength else { throw Failure.tooLong(length) }
        guard buffer.count - 4 >= length else { return nil }
        return String(decoding: KasaCipher.decrypt(buffer[4...]), as: UTF8.self)
    }
}

/// A command: one module's method with its parameters, and the outlet of a strip it is for.
struct KasaRequest: Sendable, Equatable {
    enum Parameter: Sendable, Equatable {
        case int(Int)
        case string(String)
    }

    var module: String
    var method: String
    /// In the order they are written.
    var ordered: [Pair] = []
    /// The full child id of a strip's outlet: the command carries `context.child_ids`.
    var childID: String?

    struct Pair: Sendable, Equatable {
        var key: String
        var value: Parameter
    }

    init(module: String, method: String, _ parameters: [(String, Parameter)] = [], childID: String? = nil) {
        self.module = module
        self.method = method
        self.ordered = parameters.map { Pair(key: $0.0, value: $0.1) }
        self.childID = childID
    }

    static let sysinfo = KasaRequest(module: "system", method: "get_sysinfo")

    /// `{"module":{"method":{…}}}`, then `"context":{"child_ids":[…]}` for an outlet: no whitespace, keys in order.
    var json: String {
        var text = "{\(Self.quoted(module)):{\(Self.quoted(method)):{"
        text += ordered.map { pair in
            switch pair.value {
            case .int(let value): "\(Self.quoted(pair.key)):\(value)"
            case .string(let value): "\(Self.quoted(pair.key)):\(Self.quoted(value))"
            }
        }.joined(separator: ",")
        text += "}}"
        if let childID { text += ",\"context\":{\"child_ids\":[\(Self.quoted(childID))]}" }
        return text + "}"
    }

    static func quoted(_ string: String) -> String {
        var bytes: [UInt8] = []
        JSONValue.appendQuoted(string, to: &bytes)
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A command the device refused or answered with something else.
struct KasaResponseError: Error, CustomStringConvertible, Equatable {
    var message: String
    /// The device's `err_code`, when it gave one.
    var code: Int?
    var description: String { message }
}

extension KasaRequest {
    /// The method's object in the response, checked: `err_code` present and 0.
    func result(of response: String) throws -> JSONValue {
        guard let json = try? JSONValue(string: response) else {
            throw KasaResponseError(message: "the device answered \(module).\(method) with something that is not JSON")
        }
        guard let result = json[module]?[method], result.objectValue != nil else {
            // A module the device does not have answers at the module's level.
            let code = json[module]?["err_code"]?.intValue
            let detail = code.map { " (error \($0))" } ?? ""
            throw KasaResponseError(message: "the device did not answer \(module).\(method)\(detail)", code: code)
        }
        guard let code = result["err_code"]?.intValue else {
            throw KasaResponseError(message: "the device answered \(module).\(method) without an error code")
        }
        guard code == 0 else {
            let message = result["err_msg"]?.stringValue.map { ": \($0)" } ?? ""
            throw KasaResponseError(message: "the device refused \(module).\(method) (error \(code)\(message))", code: code)
        }
        return result
    }
}
