import Crypto
import Foundation
import HomeswiftNetwork

/// Pairing with a TV, as the Philips TV Remote app does it: `pair/request` makes the TV show a PIN, then
/// `pair/grant` with the PIN signed under a key shared by every official app. The device id and auth key the
/// TV hands out are the `username` and `password` of the configuration.
enum JointSpacePairing {
    /// The HMAC-SHA1 key of the official apps, shared by every JointSpace client (pylips, the Homebridge plugin).
    static let sharedKey = Data(base64Encoded: "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==")!
    static let timeout: Duration = .seconds(15)

    struct Device: Codable, Sendable, Equatable {
        var device_name: String
        var device_os = "Android"
        var app_name = "Homeswift"
        var type = "native"
        var app_id: String
        var id: String

        init(name: String, id: String = randomID()) {
            device_name = name
            app_id = "app.homeswift.philips.\(id)"
            self.id = id
        }

        static func randomID() -> String {
            (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
    }

    /// What `pair/request` produced: enough for the grant, and the certificate the TV showed.
    struct Session: Sendable, Equatable {
        var ip: String
        var device: Device
        var authKey: String
        var timestamp: Int
        var certificateFingerprint: String?
        var startedAt: Date = Date()
    }

    /// The configuration keys of a paired TV.
    struct Credentials: Sendable, Equatable {
        var username: String
        var password: String
        var certFingerprint: String?
    }

    /// Asks the TV to show a PIN. The TV must be on.
    static func request(ip: String, deviceName: String, transport: any HTTPSending) async throws -> Session {
        struct Body: Encodable {
            struct Access: Encodable { var scope = ["read", "write", "control"] }
            var access = Access()
            var device: Device
        }
        struct Answer: Decodable {
            var auth_key: String?
            var timestamp: Int?
            var error_id: String?
            var error_text: String?
        }
        let device = Device(name: String(deviceName.prefix(64)))
        let response = try await post(ip: ip, path: "pair/request", body: Body(device: device), transport: transport, authorization: nil)
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: response.body)
        } catch {
            throw JointSpaceError.invalidResponse("pair/request: \(error)")
        }
        guard let authKey = answer.auth_key, let timestamp = answer.timestamp else {
            throw JointSpaceError.invalidResponse("pair/request: \(answer.error_id ?? "no auth key") \(answer.error_text ?? "")")
        }
        return Session(ip: ip, device: device, authKey: authKey, timestamp: timestamp, certificateFingerprint: response.certificateFingerprint)
    }

    /// Completes the pairing with the PIN the TV shows. The connection is held to the certificate seen at
    /// the request when there was one.
    static func grant(_ session: Session, pin: String, transport: any HTTPSending) async throws -> Credentials {
        struct Body: Encodable {
            struct Auth: Encodable {
                var auth_appId = "1"
                var auth_timestamp: Int
                var auth_signature: String
                var pin: String
            }
            var auth: Auth
            var device: Device
        }
        struct Answer: Decodable {
            var error_id: String?
            var error_text: String?
        }
        let body = Body(auth: .init(auth_timestamp: session.timestamp, auth_signature: signature(timestamp: session.timestamp, pin: pin), pin: pin), device: session.device)
        var digest = DigestAuthentication(username: session.device.id, password: session.authKey)
        var response = try await post(ip: session.ip, path: "pair/grant", body: body, transport: transport, authorization: nil)
        if response.status == 401, let challenge = response.header("WWW-Authenticate"), digest.accept(challenge: challenge) {
            response = try await post(ip: session.ip, path: "pair/grant", body: body, transport: transport, authorization: digest.authorization(method: "POST", uri: "/\(JointSpace.version)/pair/grant"))
        }
        guard response.status != 401 else { throw JointSpaceError.unauthorized }
        guard response.isSuccess else { throw JointSpaceError.httpStatus(response.status) }
        if let answer = try? JSONDecoder().decode(Answer.self, from: response.body), let error = answer.error_id, error != "SUCCESS" {
            throw JointSpaceError.invalidResponse("pair/grant: \(error) \(answer.error_text ?? "")")
        }
        return Credentials(username: session.device.id, password: session.authKey, certFingerprint: session.certificateFingerprint ?? response.certificateFingerprint)
    }

    /// HMAC-SHA1 of the timestamp and PIN under the shared key, base64.
    static func signature(timestamp: Int, pin: String) -> String {
        var hmac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: sharedKey))
        hmac.update(data: Data("\(timestamp)\(pin)".utf8))
        return Data(hmac.finalize()).base64EncodedString()
    }

    private static func post(ip: String, path: String, body: some Encodable, transport: any HTTPSending, authorization: String?) async throws -> HTTPResponse {
        guard let url = URL(string: "https://\(ip):\(JointSpace.securePort)/\(JointSpace.version)/\(path)") else { throw JointSpaceError.unreachable("bad URL for \(ip)") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var request = HTTPRequest(method: "POST", url: url, body: try encoder.encode(body), timeout: timeout)
        request.setHeader("Content-Type", "application/json")
        if let authorization { request.setHeader("Authorization", authorization) }
        do {
            return try await transport.send(request)
        } catch let error as HTTPClientError {
            if case .certificateMismatch(let expected, let observed) = error { throw JointSpaceError.certificateMismatch(expected: expected, observed: observed) }
            throw JointSpaceError.unreachable(error.description)
        } catch {
            throw JointSpaceError.unreachable("\(error)")
        }
    }
}
