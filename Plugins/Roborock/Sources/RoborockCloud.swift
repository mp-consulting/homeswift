import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// The Roborock cloud (section 2): the login API (region, signature, email code, login) and the Hawk-signed API (home
// data, scenes). Plain HTTP through `HTTPSending`, so tests answer with canned replies.

/// The cloud session the login gives (its `data` object): secret as a whole. Kept as it came, so nothing is lost.
struct RoborockSession: Codable, Sendable, Equatable {
    var raw: JSONValue

    init(_ raw: JSONValue) { self.raw = raw }

    var token: String? { raw["token"]?.stringValue?.nonEmptyValue }
    var u: String { raw["rriot"]?["u"]?.stringValue ?? "" }
    var s: String { raw["rriot"]?["s"]?.stringValue ?? "" }
    var h: String { raw["rriot"]?["h"]?.stringValue ?? "" }
    var k: String { raw["rriot"]?["k"]?.stringValue ?? "" }
    /// The signed API's base (`rriot.r.a`).
    var apiBase: String? { raw["rriot"]?["r"]?["a"]?.stringValue }
    /// The MQTT broker (`rriot.r.m`).
    var broker: String? { raw["rriot"]?["r"]?["m"]?.stringValue }

    /// A token and an `rriot` object.
    var isValid: Bool { token != nil && raw["rriot"]?.objectValue != nil }

    init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        // The Homebridge plugin's `roborock.UserData`: {"val": "<the session as a JSON string>", "ack": true}.
        if let text = value["val"]?.stringValue, let parsed = try? JSONValue(string: text) {
            raw = parsed
        } else {
            raw = value
        }
    }

    func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }

    /// A Homebridge `encryptedToken` (section 2.9): Base64 of `{"iv","tag","data"}`, AES-256-GCM under the 32-byte
    /// `roborock.token.key`. nil when anything does not fit.
    static func decrypt(encryptedToken: String, key: Data) -> RoborockSession? {
        guard key.count == 32, let outer = Data(base64Encoded: encryptedToken), let envelope = try? JSONValue(data: outer),
            let iv = envelope["iv"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), iv.count == 12,
            let tag = envelope["tag"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), tag.count == 16,
            let data = envelope["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
            let nonce = try? AES.GCM.Nonce(data: iv), let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: data, tag: tag),
            let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)), let json = try? JSONValue(data: plain)
        else { return nil }
        let session = RoborockSession(json)
        return session.isValid ? session : nil
    }
}

enum RoborockCloudError: Error, CustomStringConvertible, Equatable {
    /// An HTTP status outside 2xx, with the `Date` header the clock check reads.
    case http(status: Int, date: String?)
    /// An answer whose `code` is not 200.
    case api(code: Int?, message: String)
    case badResponse(String)

    var description: String {
        switch self {
        case .http(let status, _): "HTTP \(status)"
        case .api(let code, let message): "Roborock answered \(code.map(String.init) ?? "an error")\(message.isEmpty ? "" : ": \(message)")"
        case .badResponse(let what): "unexpected answer: \(what)"
        }
    }

    /// No answer, or a server error: worth trying again later.
    var isRetryable: Bool {
        if case .http(let status, _) = self { return status >= 500 }
        return false
    }
}

/// The login API on the region's host.
struct RoborockLoginAPI: Sendable {
    static let regionHosts = ["usiot.roborock.com", "euiot.roborock.com", "cniot.roborock.com", "ruiot.roborock.com"]
    static let defaultHost = "usiot.roborock.com"
    static let appVersion = "4.54.02"

    let transport: any HTTPSending
    /// The host, without scheme or slashes.
    let host: String
    let email: String
    let clientID: String
    let language: String
    var timeout: Duration = .seconds(20)

    /// A configured `baseURL` as a host: scheme, path and trailing slashes off.
    static func normalizedHost(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        return text.lowercased()
    }

    /// The region's country when discovery gave none.
    static func fallbackCountry(host: String) -> (country: String, code: String) {
        let host = host.lowercased()
        if host.contains("euiot") { return ("DE", "49") }
        if host.contains("usiot") { return ("US", "1") }
        if host.contains("cniot") { return ("CN", "86") }
        if host.contains("api.roborock.com") { return ("SG", "65") }
        return ("US", "1")
    }

    struct Region: Sendable, Equatable {
        var host: String
        var country: String?
        var countryCode: String?
    }

    /// Asks each region's host for the account's (section 2.2). A host that is not Roborock's ends the search.
    static func discoverRegion(email: String, transport: any HTTPSending) async -> Region? {
        for host in regionHosts {
            let query = URLEncoding.query([("email", email), ("needtwostepauth", "false")])
            guard let url = URL(string: "https://\(host)/api/v1/getUrlByEmail?\(query)"),
                let response = try? await transport.send(HTTPRequest(method: "POST", url: url, timeout: .seconds(10))),
                let json = try? JSONValue(data: response.body), json["code"]?.intValue == 200,
                let address = json["data"]?["url"]?.stringValue, !address.isEmpty
            else { continue }
            let found = normalizedHost(address)
            guard found == "roborock.com" || found.hasSuffix(".roborock.com") else { return nil }
            func text(_ value: JSONValue?) -> String? {
                if let string = value?.stringValue { return string.isEmpty ? nil : string }
                return value?.intValue.map(String.init)
            }
            return Region(host: found, country: text(json["data"]?["country"]), countryCode: text(json["data"]?["countrycode"]))
        }
        return nil
    }

    private func request(_ method: String, _ path: String, form: [(String, String)]? = nil, headers: [(String, String)] = []) async throws -> JSONValue {
        guard let url = URL(string: "https://\(host)/\(path)") else { throw RoborockCloudError.badResponse("bad URL") }
        var request = HTTPRequest(method: method, url: url, timeout: timeout)
        request.setHeader("header_clientid", RoborockAuth.clientIDHeader(email: email, clientID: clientID))
        request.setHeader("header_clientlang", language)
        request.setHeader("header_appversion", Self.appVersion)
        request.setHeader("header_phonemodel", "Pixel 7")
        request.setHeader("header_phonesystem", "Android")
        for (name, value) in headers { request.setHeader(name, value) }
        if let form {
            request.setHeader("Content-Type", "application/x-www-form-urlencoded")
            request.body = Data(URLEncoding.form(form).utf8)
        }
        let response = try await transport.send(request)
        let json = (try? JSONValue(data: response.body)) ?? .string(String(decoding: response.body, as: UTF8.self))
        guard response.isSuccess else {
            // The login endpoints answer their errors with a body worth reading.
            if json.objectValue != nil, path.contains("/login/") { return json }
            throw RoborockCloudError.http(status: response.status, date: response.header("Date"))
        }
        return json
    }

    /// The pair (`k`, `s`) every login is signed with.
    func signature() async throws -> (k: String, s: String) {
        let s = RoborockAuth.signatureNonce()
        let json = try await request("POST", "api/v3/key/sign?s=\(URLEncoding.uriComponent(s))")
        guard let k = json["data"]?["k"]?.stringValue, !k.isEmpty else { throw RoborockCloudError.badResponse("Failed to obtain login signature") }
        return (k, s)
    }

    /// The latest user agreement's version: 14.0 when it cannot be read.
    func agreementVersion(country: String) async -> (major: Int, minor: Int) {
        guard let json = try? await request("GET", "api/v3/app/agreement/latest?country=\(URLEncoding.uriComponent(country))", headers: [("header_clientlang", "en")]),
            json["code"]?.intValue == 200, let major = json["data"]?["majorVersion"]?.intValue, let minor = json["data"]?["minorVersion"]?.intValue
        else { return (14, 0) }
        return (major, minor)
    }

    func sendEmailCode() async throws {
        let json = try await request("POST", "api/v4/email/code/send", form: [("type", "login"), ("email", email), ("platform", "")])
        guard json["code"]?.intValue == 200 else {
            throw RoborockCloudError.api(code: json["code"]?.intValue, message: json["msg"]?.stringValue ?? "")
        }
    }

    enum LoginResult: Sendable, Equatable {
        case success(RoborockSession)
        case twoFactorRequired
        case failed(code: Int?, message: String)
    }

    static func loginResult(_ json: JSONValue) -> LoginResult {
        let code = json["code"]?.intValue
        if code == 200, let data = json["data"], data.objectValue != nil { return .success(RoborockSession(data)) }
        if code == 2031 { return .twoFactorRequired }
        return .failed(code: code, message: json["msg"]?.stringValue ?? "")
    }

    func login(code: String, country: String, countryCode: String, signature: (k: String, s: String)) async throws -> LoginResult {
        let version = await agreementVersion(country: country)
        let json = try await request("POST", "api/v4/auth/email/login/code", form: [
            ("country", country), ("countryCode", countryCode), ("email", email), ("code", code),
            ("majorVersion", String(version.major)), ("minorVersion", String(version.minor)),
        ], headers: [("x-mercy-k", signature.k), ("x-mercy-ks", signature.s)])
        return Self.loginResult(json)
    }

    func login(password: String, country: String, signature: (k: String, s: String)) async throws -> LoginResult {
        let version = await agreementVersion(country: country)
        let json = try await request("POST", "api/v4/auth/email/login/pwd", form: [
            ("email", email), ("password", try RoborockAuth.encryptPassword(password, k: signature.k)),
            ("majorVersion", String(version.major)), ("minorVersion", String(version.minor)),
        ], headers: [("x-mercy-k", signature.k), ("x-mercy-ks", signature.s)])
        return Self.loginResult(json)
    }

    enum HomeDetail: Sendable, Equatable {
        case home(Int)
        /// A numeric code other than 200: the token is refused.
        case rejected
        /// An answer without a home (not a rejection).
        case unknown
    }

    func homeDetail(token: String) async throws -> HomeDetail {
        guard let url = URL(string: "https://\(host)/api/v1/getHomeDetail") else { throw RoborockCloudError.badResponse("bad URL") }
        var request = HTTPRequest(method: "GET", url: url, timeout: timeout)
        request.setHeader("header_clientid", RoborockAuth.clientIDHeader(email: email, clientID: clientID))
        request.setHeader("header_clientlang", language)
        request.setHeader("Authorization", token)
        let response = try await transport.send(request)
        guard let json = try? JSONValue(data: response.body) else {
            if response.isSuccess { return .unknown }
            throw RoborockCloudError.http(status: response.status, date: response.header("Date"))
        }
        if let code = json["code"]?.intValue, code != 200 { return .rejected }
        if let id = json["data"]?["rrHomeId"]?.intValue { return .home(id) }
        if !response.isSuccess { throw RoborockCloudError.http(status: response.status, date: response.header("Date")) }
        return .unknown
    }
}

/// The Hawk-signed API on `rriot.r.a`.
struct RoborockHawkAPI: Sendable {
    let transport: any HTTPSending
    let session: RoborockSession
    var now: @Sendable () -> Date = { Date() }
    var timeout: Duration = .seconds(20)

    /// `result` of a signed request to `path` (relative to the base).
    func call(_ method: String, _ path: String) async throws -> JSONValue {
        guard let base = session.apiBase, let url = URL(string: base.hasSuffix("/") ? base + path : base + "/" + path) else {
            throw RoborockCloudError.badResponse("the session has no API address")
        }
        var request = HTTPRequest(method: method, url: url, timeout: timeout)
        let signedPath = url.path.isEmpty ? "/" : url.path
        request.setHeader("Authorization", RoborockAuth.hawk(
            u: session.u, s: session.s, h: session.h, path: signedPath, timestamp: Int(now().timeIntervalSince1970), nonce: RoborockAuth.hawkNonce()))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw RoborockCloudError.http(status: response.status, date: response.header("Date")) }
        guard let json = try? JSONValue(data: response.body) else { return .null }
        return json["result"] ?? .null
    }

    func homeData(homeID: Int, startup: Bool) async throws -> JSONValue {
        try await call("GET", startup ? "v2/user/homes/\(homeID)" : "user/homes/\(homeID)")
    }

    func scenes(homeID: Int) async throws -> [JSONValue] {
        try await call("GET", "user/scene/home/\(homeID)").arrayValue ?? []
    }

    func executeScene(_ id: Int) async throws {
        _ = try await call("POST", "user/scene/\(id)/execute")
    }

    /// A shared device's rooms, by id.
    func sharedRooms(duid: String) async throws -> [Int: String] {
        var rooms: [Int: String] = [:]
        for room in try await call("GET", "user/deviceshare/query/\(duid)/rooms").arrayValue ?? [] {
            if let id = (room["id"] ?? room["roomId"])?.intValue, let name = room["name"]?.stringValue { rooms[id] = name }
        }
        return rooms
    }

    /// The clock's offset from the server's `Date` header, in seconds, when it has one.
    static func skew(date: String?, now: Date) -> TimeInterval? {
        guard let date, let server = httpDate.withLock({ $0.date(from: date) }) else { return nil }
        return now.timeIntervalSince(server)
    }

    /// An HTTP `Date` header's format; DateFormatter is not thread-safe, hence the lock.
    private static let httpDate = HTTPDateBox()
}

/// A DateFormatter for HTTP dates behind a lock.
final class HTTPDateBox: NSLock, @unchecked Sendable {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func withLock<T>(_ body: (DateFormatter) -> T) -> T {
        lock()
        defer { unlock() }
        return body(formatter)
    }
}
