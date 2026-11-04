import Crypto
import Foundation
import HomeswiftAI
import HomeswiftNetwork
import NIOConcurrencyHelpers
import _CryptoExtras

@testable import HomeswiftTapo

/// Tapo devices in memory, answering HTTP the way the spec describes: KLAP, or securePassthrough for `.passthrough`.
/// Each device is keyed by its host.
final class FakeTapoNetwork: HTTPSending, Sendable {
    enum Mode: Sendable { case klap, passthrough }

    struct Device: Sendable {
        var mode: Mode = .klap
        var credentials = TapoCredentials(username: "user@example.com", password: "password123")
        var info: [String: JSONValue] = ["device_on": false, "hw_id": "0123456789ABCDEF0123456789ABCDEF", "fw_ver": "1.2.1 Build 20200616 Rel. 31218"]
        var energyUsage: JSONValue = ["today_runtime": 120, "month_runtime": 3000, "today_energy": 250, "month_energy": 6000, "current_power": 15300]
        var deviceUsage: JSONValue = ["time_usage": ["today": 120], "power_usage": ["today": 18]]
        var reachable = true
        /// The next requests answered 403, as when the session expired.
        var expireNext = 0
        /// The next requests answered with `error_code` -1501.
        var refuseNext = 0
        /// What handshake1 answers instead of a handshake, when set.
        var handshake1Status: Int?
        /// The next `set_device_info` answers this `error_code`.
        var setError: Int?
        /// Answers `error_code` with a leading zero, as some firmware does.
        var malformedErrorCodes = false
        // Session state.
        var remoteSeed = Data((16..<32).map(UInt8.init))
        var localSeed: Data?
        var klap: KLAP.Session?
        var cipher: SecurePassthrough.Cipher?
        var token: String?
        // What it was asked.
        var handshakes = 0
        var methods: [String] = []
        var sets: [JSONValue] = []
    }

    let devices = NIOLockedValueBox<[String: Device]>([:])

    init(_ devices: [String: Device] = ["192.168.1.21": Device()]) {
        self.devices.withLockedValue { $0 = devices }
    }

    func device(_ host: String = "192.168.1.21") -> Device { devices.withLockedValue { $0[host] ?? Device() } }

    func update(_ host: String = "192.168.1.21", _ change: (inout Device) -> Void) {
        devices.withLockedValue { change(&$0[host, default: Device()]) }
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let host = request.url.host ?? ""
        return try devices.withLockedValue { devices in
            guard var device = devices[host], device.reachable else {
                throw HTTPClientError.cannotConnect(host: host, port: 80, code: 61, reason: "connection refused")
            }
            defer { devices[host] = device }
            return try Self.answer(request, device: &device)
        }
    }

    private static func authHash(_ device: Device) -> Data {
        KLAP.authHash(username: device.credentials.username, password: device.credentials.password)
    }

    private static func answer(_ request: HomeswiftNetwork.HTTPRequest, device: inout Device) throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let body = request.body ?? Data()
        switch (device.mode, path) {
        case (_, "/app/handshake1") where device.handshake1Status != nil:
            return HTTPResponse(status: device.handshake1Status ?? 500)
        case (.klap, "/app/handshake1"):
            device.handshakes += 1
            device.klap = nil
            device.localSeed = body
            let hash = KLAP.serverHash(localSeed: body, remoteSeed: device.remoteSeed, authHash: authHash(device))
            return HTTPResponse(status: 200, headers: [("Set-Cookie", "TP_SESSIONID=ABCDEF0123;TIMEOUT=86400")], body: device.remoteSeed + hash)
        case (.klap, "/app/handshake2"):
            guard request.header("Cookie") == "TP_SESSIONID=ABCDEF0123", let local = device.localSeed,
                  body == KLAP.clientHash(localSeed: local, remoteSeed: device.remoteSeed, authHash: authHash(device)) else { return HTTPResponse(status: 403) }
            device.klap = KLAP.Session(localSeed: local, remoteSeed: device.remoteSeed, authHash: authHash(device))
            return HTTPResponse(status: 200)
        case (.klap, "/app/request"):
            if device.expireNext > 0 {
                device.expireNext -= 1
                device.klap = nil
                return HTTPResponse(status: 403)
            }
            guard let session = device.klap, let query = request.url.query, query.hasPrefix("seq="), let sequence = Int32(query.dropFirst(4)) else {
                return HTTPResponse(status: 403)
            }
            let ciphertext = body.dropFirst(32)
            guard KLAP.sha256(session.signatureKey + sequence.bigEndianBytes + ciphertext) == body.prefix(32) else { return HTTPResponse(status: 403) }
            let plaintext = try session.decrypt(body, sequence: sequence)
            var reply = handle(try JSONValue(data: plaintext), device: &device)
            if device.refuseNext > 0 {
                device.refuseNext -= 1
                reply = JSONValue.object(["error_code": -1501]).encoded()
            }
            let encrypted = try AES._CBC.encrypt(reply, using: session.key, iv: AES._CBC.IV(ivBytes: session.iv(sequence: sequence)))
            return HTTPResponse(status: 200, body: KLAP.sha256(session.signatureKey + sequence.bigEndianBytes + encrypted) + encrypted)
        case (.passthrough, "/app"):
            let envelope = try JSONValue(data: body)
            if envelope["method"] == "handshake" {
                device.handshakes += 1
                let publicKey = try _RSA.Encryption.PublicKey(unsafePEMRepresentation: envelope["params"]?["key"]?.stringValue ?? "")
                let cipher = SecurePassthrough.Cipher(key: Data((0..<16).map(UInt8.init)), iv: Data((16..<32).map(UInt8.init)))
                device.cipher = cipher
                device.token = nil
                let key = try publicKey.encrypt(cipher.key + cipher.iv, padding: ._WEAK_AND_INSECURE_PKCS_V1_5).base64EncodedString()
                return json(["error_code": 0, "result": ["key": .string(key)]], cookie: "TP_SESSIONID=LEGACY")
            }
            guard envelope["method"] == "securePassthrough", let cipher = device.cipher, request.header("Cookie") == "TP_SESSIONID=LEGACY",
                  let encrypted = envelope["params"]?["request"]?.stringValue else { return json(["error_code": -1002]) }
            let inner = try JSONValue(data: try cipher.decrypt(encrypted))
            let reply: Data
            if inner["method"] == "login_device" {
                let expected = SecurePassthrough.loginParameters(username: device.credentials.username, password: device.credentials.password)
                if inner["params"]?["username"]?.stringValue == expected["username"], inner["params"]?["password"]?.stringValue == expected["password"] {
                    device.token = "TOKEN123"
                    reply = JSONValue.object(["error_code": 0, "result": ["token": "TOKEN123"]]).encoded()
                } else {
                    reply = JSONValue.object(["error_code": -1501]).encoded()
                }
            } else {
                guard request.url.query == "token=\(device.token ?? "-")" else { return json(["error_code": 9999]) }
                reply = handle(inner, device: &device)
            }
            return json(["error_code": 0, "result": ["response": .string(try cipher.encrypt(reply))]])
        case (.passthrough, _):
            return HTTPResponse(status: 404)
        case (.klap, "/app"):
            return json(["error_code": 1003])
        default:
            return HTTPResponse(status: 404)
        }
    }

    private static func json(_ value: JSONValue, cookie: String? = nil) -> HomeswiftNetwork.HTTPResponse {
        HTTPResponse(status: 200, headers: cookie.map { [("Set-Cookie", "\($0);TIMEOUT=1440")] } ?? [], body: value.encoded())
    }

    /// A method's answer, as the plaintext JSON.
    private static func handle(_ request: JSONValue, device: inout Device) -> Data {
        let method = request["method"]?.stringValue ?? ""
        device.methods.append(method)
        let answer: JSONValue
        switch method {
        case "get_device_info": answer = ["error_code": 0, "result": .object(device.info)]
        case "get_energy_usage": answer = ["error_code": 0, "result": device.energyUsage]
        case "get_device_usage": answer = ["error_code": 0, "result": device.deviceUsage]
        case "set_device_info":
            device.sets.append(request)
            if let code = device.setError {
                device.setError = nil
                answer = ["error_code": .number(Double(code))]
            } else {
                for (key, value) in request["params"]?.objectValue ?? [:] { device.info[key] = value }
                answer = ["error_code": 0]
            }
        default: answer = ["error_code": -1002]
        }
        if device.malformedErrorCodes, let code = answer["error_code"]?.intValue, code == 0 {
            return Data(answer.text().replacingOccurrences(of: "\"error_code\":0", with: "\"error_code\":00").utf8)
        }
        return answer.encoded()
    }
}
