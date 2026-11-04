import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin

// The RPC bodies inside the frames (section 4.3) and what comes back (4.4, 4.5).

enum RoborockMessages {
    /// The schema ids a status broadcast carries, and the fields they stand for.
    static let schemaFields: [String: String] = [
        "120": "error_code", "121": "state", "122": "battery", "123": "fan_power", "124": "water_box_mode", "133": "charge_status",
    ]

    /// A request's plaintext: `{"dps":{"<P>":"<inner JSON>"},"t":ts}` for 1.0, A01 and L01, the inner object itself
    /// under `10000` (with `msgId`) for B01, whose `get_prop` is `prop.get`.
    static func requestBody(id: Int, method: String, params: JSONValue, protocolNumber: UInt16, timestamp: UInt32, version: RoborockVersion) -> Data {
        if version == .b01 {
            var method = method
            var params = params
            if method == "get_prop" {
                method = "prop.get"
                params = ["property": params]
            }
            let inner: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": params, "msgId": .string(String(id))]
            return JSONValue.object(["dps": ["10000": inner], "t": .number(Double(timestamp))]).encoded()
        }
        let inner: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": params]
        return JSONValue.object(["dps": .object([String(protocolNumber): .string(inner.text())]), "t": .number(Double(timestamp))]).encoded()
    }

    /// What a decrypted protocol-102 (or local protocol-4) payload says.
    enum Incoming: Equatable {
        /// An answer to request `id`.
        case response(id: Int, result: JSONValue)
        /// A status broadcast, its schema ids translated to field names.
        case status([String: JSONValue])
    }

    /// Reads `{"dps":{"102":"<JSON>"}}` (B01: `10001`, a string or an object; else the whole `dps`).
    static func incoming(_ payload: Data) -> Incoming? {
        guard let json = try? JSONValue(data: payload), let dps = json["dps"] else { return nil }
        var message = dps
        if let inner = dps["102"] ?? dps["10001"] {
            if let text = inner.stringValue {
                guard let parsed = try? JSONValue(string: text) else { return nil }
                message = parsed
            } else {
                message = inner
            }
        }
        if let id = message["id"]?.intValue ?? message["id"]?.stringValue.flatMap(Int.init) {
            if message["result"] == nil, let error = message["error"] { return .response(id: id, result: ["error": error]) }
            return .response(id: id, result: message["result"] ?? .null)
        }
        guard let object = message.objectValue else { return nil }
        var status: [String: JSONValue] = [:]
        for (key, value) in object {
            status[schemaFields[key] ?? key] = value
        }
        return .status(status)
    }

    /// An answer that is only `"ok"` or `["ok"]`.
    static func isOK(_ result: JSONValue) -> Bool {
        result.stringValue == "ok" || (result.arrayValue?.count == 1 && result[0]?.stringValue == "ok")
    }

    /// The first element of an array answer, or the answer, when it is an object.
    static func firstObject(_ result: JSONValue) -> [String: JSONValue]? {
        if let array = result.arrayValue { return array.first?.objectValue }
        return result.objectValue
    }
}

/// The request ids: shared by every device and both transports, from 1 to 9999 and round again. An id still waiting
/// for its answer is skipped, so no two requests in flight share one (the Homebridge plugin issues 0 twice at its wrap).
struct RequestIDs: Sendable {
    static let maximum = 9999
    private var next = 1

    mutating func take(skipping inFlight: (Int) -> Bool) -> Int {
        for _ in 0..<Self.maximum {
            let id = next
            next = next >= Self.maximum ? 1 : next + 1
            if !inFlight(id) { return id }
        }
        // Every id in flight: cannot happen with requests that time out after 10 seconds.
        return next
    }
}

/// The cloud's credentials and signatures (sections 2.3, 2.4, 2.6, 4.4).
enum RoborockAuth {
    /// `header_clientid`: Base64 of the MD5 of the email followed by the client id.
    static func clientIDHeader(email: String, clientID: String) -> String {
        RoborockCipher.md5(email + clientID).base64EncodedString()
    }

    /// The login signature's `s`: 12 random bytes in Base64, its first 16 characters, every `+` as `X`, `/` as `Y`.
    static func signatureNonce(_ random: [UInt8] = randomBytes(12)) -> String {
        String(Data(random).base64EncodedString().prefix(16)).replacingOccurrences(of: "+", with: "X").replacingOccurrences(of: "/", with: "Y")
    }

    /// The password as the login wants it: AES-128-ECB (PKCS#7) under `k` rotated left by 4 characters, Base64.
    static func encryptPassword(_ password: String, k: String) throws -> String {
        let key = String(k.dropFirst(4) + k.prefix(4))
        return try AESECB.encrypt(Data(password.utf8), key: Data(key.utf8)).base64EncodedString()
    }

    /// The Hawk nonce: 6 random bytes in Base64, its first 6 characters, the first `+` as `X` and the first `/` as `Y`.
    static func hawkNonce(_ random: [UInt8] = randomBytes(6)) -> String {
        var text = String(Data(random).base64EncodedString().prefix(6))
        if let range = text.range(of: "+") { text.replaceSubrange(range, with: "X") }
        if let range = text.range(of: "/") { text.replaceSubrange(range, with: "Y") }
        return text
    }

    /// The signed API's `Authorization` header for a path (without its query).
    static func hawk(u: String, s: String, h: String, path: String, timestamp: Int, nonce: String) -> String {
        let prestr = [u, s, nonce, String(timestamp), RoborockCipher.md5Hex(path), "", ""].joined(separator: ":")
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(prestr.utf8), using: SymmetricKey(data: Data(h.utf8)))).base64EncodedString()
        return #"Hawk id="\#(u)", s="\#(s)", ts="\#(timestamp)", nonce="\#(nonce)", mac="\#(mac)""#
    }

    /// The MQTT user name (also the client id), password and the secure requests' endpoint.
    struct MQTTCredentials: Sendable, Equatable {
        var username: String
        var password: String
        var endpoint: String

        init(u: String, s: String, k: String) {
            let user = Array(RoborockCipher.md5Hex("\(u):\(k)"))
            let pass = Array(RoborockCipher.md5Hex("\(s):\(k)"))
            username = String(user[2..<10])
            password = String(pass[16..<32])
            endpoint = Data(RoborockCipher.md5(k)[8..<14]).base64EncodedString()
        }
    }

    static func randomBytes(_ count: Int) -> [UInt8] { Array(Secrets.randomBytes(count)) }
}
