import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import _CryptoExtras

/// The Dyson cloud, used once from the settings page to fetch each device's local MQTT credential, the way
/// the Dyson Android app signs in:
///
/// 0. `GET /v1/provisioningservice/application/Android/version` (unlocks the client's IP for the next calls),
/// 1. `POST /v3/userregistration/email/userstatus?country=` (the account must be ACTIVE),
/// 2. `POST /v3/userregistration/email/auth?country=&culture=` (emails a code, answers a challenge id),
/// 3. `POST /v3/userregistration/email/verify?country=` with the password and the code (answers a token),
/// 4. `GET /v2/provisioningservice/manifest` with the token: the devices and their encrypted credentials.
struct DysonCloud: Sendable {
    static let baseURL = "https://appapi.cp.dyson.com"
    static let timeout: Duration = .seconds(15)

    /// The key and IV every Dyson app decrypts `LocalCredentials` with (AES-256-CBC, PKCS#7).
    static let credentialKey = Data((1...32).map { UInt8($0) })
    static let credentialIV = Data(repeating: 0, count: 16)

    let transport: any HTTPSending
    let logger: Logger

    /// A failure with the HTTP status the settings page reports, as the Homebridge UI server's `RequestError`.
    struct Failure: Error, CustomStringConvertible, Equatable {
        var status: Int
        var message: String
        var description: String { message }
    }

    /// What step 2 answers: a challenge for the emailed code, or (for accounts without it) a token.
    enum Challenge: Equatable {
        case code(challengeID: String)
        case token(String)
    }

    struct CloudDevice: Sendable, Equatable {
        var serial: String
        var name: String?
        var productType: String
        var version: String
        var autoUpdate: Bool
        var newVersionAvailable: Bool
        /// Decrypted; empty when the cloud gave none or it did not decrypt.
        var localCredentials: String
    }

    // MARK: The sign-in

    /// Steps 0 to 2.
    func requestCode(email: String, countryCode: String) async throws -> Challenge {
        logger.info("Dyson cloud sign-in", metadata: ["country": "\(countryCode)"])
        _ = try await request("/v1/provisioningservice/application/Android/version")
        // country and culture go in the query, as the Android app sends them: as headers they are ignored and
        // the challenge is minted under the wrong market.
        let country = URLEncoding.uriComponent(countryCode)
        let culture = URLEncoding.uriComponent("en-\(countryCode)")
        let status = try await request("/v3/userregistration/email/userstatus?country=\(country)", method: "POST", body: ["email": .string(email)])
        guard status?["accountStatus"]?.stringValue == "ACTIVE" else { throw Failure(status: 401, message: "Account not active or not found") }
        let auth = try await request("/v3/userregistration/email/auth?country=\(country)&culture=\(culture)", method: "POST", body: ["email": .string(email)])
        if let challenge = auth?["challengeId"]?.stringValue, !challenge.isEmpty {
            logger.info("Dyson cloud: verification code sent")
            return .code(challengeID: challenge)
        }
        if let token = auth?["token"]?.stringValue, !token.isEmpty {
            logger.info("Dyson cloud: signed in without a code")
            return .token(token)
        }
        throw Failure(status: 500, message: "Unexpected response from Dyson")
    }

    /// Step 3. The password goes in plain text, as the Dyson API wants it.
    func verify(email: String, password: String, challengeID: String, code: String, countryCode: String) async throws -> String {
        let response = try await request(
            "/v3/userregistration/email/verify?country=\(URLEncoding.uriComponent(countryCode))", method: "POST",
            body: ["email": .string(email), "password": .string(password), "challengeId": .string(challengeID), "otpCode": .string(code)])
        guard let token = response?["token"]?.stringValue, !token.isEmpty else { throw Failure(status: 500, message: "Unexpected response from Dyson") }
        return token
    }

    /// Step 4. Answers both the v2 field names (`Serial`, `LocalCredentials`) and the v3 ones (`serialNumber`,
    /// `connectedConfiguration.mqtt.localBrokerCredentials`).
    func devices(token: String) async throws -> [CloudDevice] {
        let manifest: JSONValue?
        do {
            manifest = try await request("/v2/provisioningservice/manifest", headers: [("Authorization", "Bearer \(token)")])
        } catch let failure as Failure where failure.status == 401 || failure.status == 403 {
            throw Failure(status: 401, message: "Session expired")
        }
        let entries = manifest?.arrayValue ?? []
        logger.info("Dyson cloud: \(entries.count) device(s)")
        return entries.compactMap(parseDevice)
    }

    func parseDevice(_ entry: JSONValue) -> CloudDevice? {
        guard let serial = (entry["Serial"] ?? entry["serialNumber"])?.stringValue,
              let productType = (entry["ProductType"] ?? entry["type"])?.stringValue else { return nil }
        let name = [entry["Name"], entry["name"], entry["productName"]].lazy.compactMap { $0?.stringValue }.first { !$0.isEmpty }
        let raw = entry["LocalCredentials"]?.stringValue?.nonEmpty
            ?? entry["connectedConfiguration"]?["mqtt"]?["localBrokerCredentials"]?.stringValue ?? ""
        return CloudDevice(
            serial: serial, name: name, productType: productType, version: entry["Version"]?.stringValue ?? "",
            autoUpdate: entry["AutoUpdate"]?.boolValue ?? entry["connectedConfiguration"]?["firmware"]?["autoUpdate"]?.boolValue ?? false,
            newVersionAvailable: entry["NewVersionAvailable"]?.boolValue ?? false,
            localCredentials: raw.isEmpty ? "" : decryptCredentials(raw))
    }

    /// The `apPasswordHash` inside `LocalCredentials`: base64, AES-256-CBC under the apps' fixed key, JSON.
    /// Empty when it does not decrypt (the credential then has to be typed in).
    func decryptCredentials(_ encrypted: String) -> String {
        do {
            return try Self.decrypt(encrypted)
        } catch {
            logger.warning("Failed to decrypt device credentials: \(error)")
            return ""
        }
    }

    static func decrypt(_ encrypted: String) throws -> String {
        guard let data = Data(base64Encoded: encrypted.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters) else {
            throw Failure(status: 500, message: "credentials are not base64")
        }
        let plain = try AES._CBC.decrypt(data, using: SymmetricKey(data: credentialKey), iv: AES._CBC.IV(ivBytes: credentialIV))
        guard let hash = try JSONValue(data: plain)["apPasswordHash"]?.stringValue else {
            throw Failure(status: 500, message: "no apPasswordHash in the credentials")
        }
        return hash
    }

    /// The inverse of `decrypt`, for tests.
    static func encrypt(apPasswordHash: String) throws -> String {
        let json = JSONValue.object(["apPasswordHash": .string(apPasswordHash)]).encoded()
        return try AES._CBC.encrypt(json, using: SymmetricKey(data: credentialKey), iv: AES._CBC.IV(ivBytes: credentialIV)).base64EncodedString()
    }

    // MARK: HTTP

    /// Sends a request with the Android app's headers. Answers the JSON body, or nil for an empty one. The body
    /// is never logged: it carries tokens, challenge ids and device credentials.
    func request(_ endpoint: String, method: String = "GET", body: JSONValue? = nil, headers: [(String, String)] = []) async throws -> JSONValue? {
        guard let url = URL(string: Self.baseURL + endpoint) else { throw Failure(status: 500, message: "Network error: bad URL") }
        var request = HTTPRequest(method: method, url: url, timeout: Self.timeout)
        request.setHeader("Content-Type", "application/json")
        request.setHeader("User-Agent", "android client")
        request.setHeader("Accept", "application/json")
        for (name, value) in headers { request.setHeader(name, value) }
        if let body { request.body = body.encoded() }
        logger.info("\(method) \(endpoint.split(separator: "?").first.map(String.init) ?? endpoint)")
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HTTPClientError {
            if case .timeout = error { throw Failure(status: 408, message: "Request timed out") }
            throw Failure(status: 500, message: "Network error: \(error)")
        } catch {
            throw Failure(status: 500, message: "Network error: \(error)")
        }
        logger.info("Response status: \(response.status) (\(response.body.count) bytes)")
        // A refusal without a body is still a refusal (Homebridge read it as an empty success: no devices).
        if response.status == 401 || response.status == 403, String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure(status: response.status, message: "HTTP \(response.status)")
        }
        guard !response.body.isEmpty, !String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let json: JSONValue
        do {
            json = try JSONValue(data: response.body)
        } catch {
            throw Failure(status: 500, message: "Invalid response from Dyson API")
        }
        let message = json["Message"]?.stringValue
        if let message, message.contains("Unable to authenticate") { throw Failure(status: 401, message: message) }
        guard response.isSuccess else { throw Failure(status: response.status, message: message ?? "HTTP \(response.status)") }
        return json
    }
}

/// Input checks of the settings page's requests, as the Homebridge UI server's.
enum CloudInput {
    static func email(_ value: JSONValue?) throws -> String {
        guard let email = value?.stringValue, email.count <= 254,
              email.firstMatch(of: /^[^\s@]+@[^\s@]+\.[^\s@]+$/) != nil else { throw DysonCloud.Failure(status: 400, message: "A valid email address is required") }
        return email
    }

    static func password(_ value: JSONValue?) throws -> String {
        guard let password = value?.stringValue, !password.isEmpty else { throw DysonCloud.Failure(status: 400, message: "Password is required") }
        return password
    }

    static func code(_ value: JSONValue?) throws -> String {
        guard let code = value?.stringValue, code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw DysonCloud.Failure(status: 400, message: "Verification code must be 6 digits")
        }
        return code
    }

    static func countryCode(_ value: JSONValue?) throws -> String {
        let code = (value?.stringValue ?? (value == nil || value == .null ? "US" : "")).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw DysonCloud.Failure(status: 400, message: "Country code must be a 2-letter ISO code")
        }
        return code
    }

    /// An optional IPv4 address: empty means "find it over mDNS".
    static func optionalIPAddress(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let ip = value.stringValue else { throw DysonCloud.Failure(status: 400, message: "ipAddress must be a valid IPv4 address") }
        if ip.isEmpty { return nil }
        guard Discovery.isIPv4(ip) else { throw DysonCloud.Failure(status: 400, message: "ipAddress must be a valid IPv4 address") }
        return ip
    }
}
