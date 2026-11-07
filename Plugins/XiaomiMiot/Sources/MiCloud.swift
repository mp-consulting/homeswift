import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// The Xiaomi cloud (docs/clean-room/XiaomiMiot.md section 4), for signing in and listing the account's devices only
// (15.2): the QR code login, the password login with an email code, and the RC4-signed API. Nothing here is logged but
// paths and outcomes: the bodies carry tokens.

/// RC4 (12.11), with the first `drop` keystream bytes discarded.
struct RC4 {
    private var state: [UInt8]
    private var i = 0
    private var j = 0

    init(key: [UInt8], drop: Int = 0) {
        var state = [UInt8](0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(state[i]) + Int(key[i % key.count])) & 0xFF
            state.swapAt(i, j)
        }
        self.state = state
        if drop > 0 { _ = apply([UInt8](repeating: 0, count: drop)) }
    }

    mutating func apply(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        for byte in input {
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            output.append(byte ^ state[(Int(state[i]) + Int(state[j])) & 0xFF])
        }
        return output
    }
}

/// The signed API's arithmetic (4.7, 12.7, 12.8).
enum MiCloudSigning {
    /// 8 random bytes, then the minutes since the epoch as 4 big-endian bytes; base64 of the 12.
    static func nonce(random: [UInt8], milliseconds: Int64) -> String {
        let minutes = UInt32(truncatingIfNeeded: milliseconds / 60_000)
        let bytes = random + [UInt8(minutes >> 24), UInt8(minutes >> 16 & 0xFF), UInt8(minutes >> 8 & 0xFF), UInt8(minutes & 0xFF)]
        return Data(bytes).base64EncodedString()
    }

    /// base64(SHA-256(ssecurity ‖ nonce)), both decoded from base64.
    static func signedNonce(ssecurity: String, nonce: String) -> String? {
        guard let secret = Data(base64Encoded: ssecurity), let nonceBytes = Data(base64Encoded: nonce) else { return nil }
        return Data(SHA256.hash(data: secret + nonceBytes)).base64EncodedString()
    }

    /// The URL's text after the first `com`, `/app/` made `/`.
    static func path(of url: String) -> String {
        guard let range = url.range(of: "com") else { return url }
        return String(url[range.upperBound...]).replacingOccurrences(of: "/app/", with: "/")
    }

    /// base64(SHA-1(`POST&<path>&k=v…&<signed nonce>`)), the parameters in their key order.
    static func hash(path: String, parameters: [(String, String)], signedNonce: String) -> String {
        let text = (["POST", path] + parameters.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" } + [signedNonce]).joined(separator: "&")
        return Data(Insecure.SHA1.hash(data: Data(text.utf8))).base64EncodedString()
    }

    /// RC4 keyed with the decoded signed nonce, 1024 bytes dropped.
    static func cipher(signedNonce: String) -> RC4? {
        guard let key = Data(base64Encoded: signedNonce) else { return nil }
        return RC4(key: [UInt8](key), drop: 1024)
    }

    static func encrypt(_ text: String, signedNonce: String) -> String? {
        guard var rc4 = cipher(signedNonce: signedNonce) else { return nil }
        return Data(rc4.apply([UInt8](text.utf8))).base64EncodedString()
    }

    static func decrypt(_ base64: String, signedNonce: String) -> Data? {
        guard var rc4 = cipher(signedNonce: signedNonce), let bytes = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Data(rc4.apply([UInt8](bytes)))
    }

    /// The form fields of a signed request: `data`, `rc4_hash__`, `signature`, `ssecurity`, `_nonce`.
    static func fields(url: String, data: String, ssecurity: String, nonce: String) -> (fields: [(String, String)], signedNonce: String)? {
        guard let signedNonce = signedNonce(ssecurity: ssecurity, nonce: nonce) else { return nil }
        let path = path(of: url)
        let hash = hash(path: path, parameters: [("data", data)], signedNonce: signedNonce)
        guard let encryptedData = encrypt(data, signedNonce: signedNonce), let encryptedHash = encrypt(hash, signedNonce: signedNonce) else { return nil }
        let signature = Self.hash(path: path, parameters: [("data", encryptedData), ("rc4_hash__", encryptedHash)], signedNonce: signedNonce)
        return ([("data", encryptedData), ("rc4_hash__", encryptedHash), ("signature", signature), ("ssecurity", ssecurity), ("_nonce", nonce)], signedNonce)
    }

    /// The legacy unsigned form's signature (4.7, `unencryptedRequests`): base64 of HMAC-SHA-256 keyed with the decoded
    /// signed nonce over `<path>&<signed nonce>&<nonce>&data=<data>`. Homeswift does not send that form; kept for its
    /// vector (12.9).
    static func legacySignature(path: String, signedNonce: String, nonce: String, data: String) -> String? {
        guard let key = Data(base64Encoded: signedNonce) else { return nil }
        let text = "\(path)&\(signedNonce)&\(nonce)&data=\(data)"
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))).base64EncodedString()
    }

    /// The password as the account wants it: uppercase hex MD5 of its UTF-8 (12.10).
    static func passwordHash(_ password: String) -> String {
        Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
    }
}

/// An account session (3.6), as homebridge-miot's `cachedSession` file has it.
struct MiSession: Sendable, Equatable {
    var ssecurity: String
    var userID: String
    var cUserID: String?
    var serviceToken: String
    var passToken: String?
    /// Milliseconds since the epoch.
    var timestamp: Double
    var loggedInAt: String?
    var loginMethod: String
    var agentID: String
    var clientID: String
    var country: String?

    init(ssecurity: String, userID: String, cUserID: String?, serviceToken: String, passToken: String?, loginMethod: String, identity: MiCloud.Identity,
         country: String?, now: Date) {
        self.ssecurity = ssecurity
        self.userID = userID
        self.cUserID = cUserID
        self.serviceToken = serviceToken
        self.passToken = passToken
        timestamp = (now.timeIntervalSince1970 * 1000).rounded()
        loggedInAt = ISO8601DateFormatter().string(from: now)
        self.loginMethod = loginMethod
        agentID = identity.agentID
        clientID = identity.clientID
        self.country = country
    }

    /// From the file or the vault; userId may be a number.
    init?(json: JSONValue) {
        guard let ssecurity = json["ssecurity"]?.stringValue, let serviceToken = json["serviceToken"]?.stringValue,
              let userID = json["userId"].flatMap({ $0.stringValue ?? $0.intValue.map(String.init) }) else { return nil }
        self.ssecurity = ssecurity
        self.serviceToken = serviceToken
        self.userID = userID
        cUserID = json["cUserId"]?.stringValue
        passToken = json["passToken"]?.stringValue
        timestamp = json["timestamp"]?.doubleValue ?? 0
        loggedInAt = json["loggedInAt"]?.stringValue
        loginMethod = json["loginMethod"]?.stringValue ?? "unknown"
        agentID = json["agentId"]?.stringValue ?? MiCloud.Identity.random().agentID
        clientID = json["clientId"]?.stringValue ?? MiCloud.Identity.random().clientID
        country = json["country"]?.stringValue
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = [
            "ssecurity": .string(ssecurity), "userId": .string(userID), "serviceToken": .string(serviceToken), "timestamp": .number(timestamp),
            "loginMethod": .string(loginMethod), "agentId": .string(agentID), "clientId": .string(clientID),
        ]
        if let cUserID { fields["cUserId"] = .string(cUserID) }
        if let passToken { fields["passToken"] = .string(passToken) }
        if let loggedInAt { fields["loggedInAt"] = .string(loggedInAt) }
        if let country { fields["country"] = .string(country) }
        return .object(fields)
    }

    var identity: MiCloud.Identity { MiCloud.Identity(agentID: agentID, clientID: clientID) }
}

/// A device of the account's list (4.9).
struct CloudDevice: Sendable, Equatable {
    var did: String
    var token: String?
    var name: String?
    var model: String?
    var ip: String?
    var mac: String?
    var ssid: String?
    var isOnline: Bool?
    var firmware: String?
    var parentID: String?

    init?(json: JSONValue) {
        guard let did = json["did"].flatMap({ $0.stringValue ?? $0.intValue.map(String.init) }), !did.isEmpty else { return nil }
        self.did = did
        token = json["token"]?.stringValue?.nonEmpty
        name = json["name"]?.stringValue?.nonEmpty
        model = json["model"]?.stringValue?.nonEmpty
        ip = json["localip"]?.stringValue?.nonEmpty
        mac = json["mac"]?.stringValue?.nonEmpty
        ssid = json["ssid"]?.stringValue?.nonEmpty
        isOnline = json["isOnline"]?.boolValue
        firmware = json["extra"]?["fw_version"]?.stringValue?.nonEmpty
        parentID = json["parent_id"].flatMap { $0.stringValue ?? $0.intValue.map(String.init) }?.nonEmpty
    }

    /// Out of scope (section 10): BLE (`blt.`), sub-devices behind a gateway, devices without a LAN address or Wi-Fi.
    var isOutOfScope: Bool {
        did.hasPrefix("blt.") || did.hasPrefix("lumi.") || parentID != nil || ip == nil || ssid == nil
            || model.map { MiotSpec.isSkippedModel($0) } == true
    }

    /// The MAC as the Serial Number (uppercase hex, no separators).
    var serialNumber: String? {
        guard let mac else { return nil }
        let hex = mac.uppercased().filter(\.isHexDigit)
        return hex.count == 12 ? hex : nil
    }
}

/// The Xiaomi account: sign-in and the device list (section 4).
struct MiCloud: Sendable {
    static let accountHost = "https://account.xiaomi.com"
    static let sts = "https://sts.api.io.mi.com/sts"
    static let sdkVersion = "accountsdk-18.8.15"
    static let regions = ["cn", "de", "us", "ru", "tw", "sg", "in", "i2"]

    /// The client's identity (4.2), kept with the session.
    struct Identity: Sendable, Equatable, Codable {
        var agentID: String
        var clientID: String

        static func random() -> Identity {
            Identity(agentID: String((0..<13).map { _ in "ABCDE".randomElement()! }),
                     clientID: String((0..<6).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! }))
        }

        var userAgent: String { "Android-7.1.1-1.0.0-ONEPLUS A3010-136-\(agentID) APP/com.xiaomi.mihome APPV/10.5.201" }
    }

    enum CloudError: Error, CustomStringConvertible, Equatable {
        /// The session is refused (a signed request that fails, 4.6).
        case refused
        case failed(String)

        var description: String {
            switch self {
            case .refused: "the Xiaomi session was refused"
            case .failed(let reason): reason
            }
        }
    }

    let http: any HTTPSending
    let now: @Sendable () -> Date
    let random: @Sendable (Int) -> [UInt8]

    init(http: any HTTPSending, now: @escaping @Sendable () -> Date = Date.init,
         random: @escaping @Sendable (Int) -> [UInt8] = { count in (0..<count).map { _ in UInt8.random(in: 0...255) } }) {
        self.http = http
        self.now = now
        self.random = random
    }

    static func apiBase(country: String) -> String {
        country == "cn" ? "https://api.io.mi.com/app" : "https://\(country).api.io.mi.com/app"
    }

    var milliseconds: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded(.down)) }

    // MARK: Cookies

    /// Cookies by name.
    typealias Jar = [String: String]

    static func cookies(from response: HTTPResponse) -> Jar {
        var jar: Jar = [:]
        for header in response.headers where header.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            guard let pair = header.value.split(separator: ";").first, let equals = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { jar[name] = value }
        }
        return jar
    }

    static func cookieHeader(_ jar: Jar) -> String {
        jar.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// An account response: `&&&START&&&` and a JSONP wrapper taken off.
    static func accountJSON(_ data: Data) -> JSONValue? {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("&&&START&&&") { text.removeFirst("&&&START&&&".count) }
        if let open = text.firstIndex(of: "("), text.hasSuffix(")"), !text.hasPrefix("{"), !text.hasPrefix("[") {
            text = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        }
        return try? JSONValue(string: text)
    }

    private func request(_ url: String, method: String = "GET", identity: Identity, jar: Jar, form: [(String, String)]? = nil,
                         headers: [(String, String)] = [], timeout: Duration = .seconds(15)) async throws -> HTTPResponse {
        guard let address = URL(string: url) else { throw CloudError.failed("bad address") }
        var cookies = jar
        cookies["sdkVersion"] = Self.sdkVersion
        cookies["deviceId"] = identity.clientID
        var request = HTTPRequest(method: method, url: address, headers: [("User-Agent", identity.userAgent), ("Cookie", Self.cookieHeader(cookies))],
                                  body: form.map { Data(URLEncoding.form($0).utf8) }, timeout: timeout)
        if form != nil { request.setHeader("Content-Type", "application/x-www-form-urlencoded") }
        for (name, value) in headers { request.setHeader(name, value) }
        return try await http.send(request)
    }

    // MARK: QR code (4.3)

    struct QRLogin: Sendable, Equatable {
        var qr: String
        var longPoll: String
        var loginURL: String
        var timeout: Int
    }

    func startQR(identity: Identity) async throws -> QRLogin {
        let query = URLEncoding.query([
            ("_qrsize", "480"), ("qs", "?sid=xiaomiio&_json=true"), ("callback", Self.sts), ("_hasLogo", "false"), ("sid", "xiaomiio"),
            ("serviceParam", ""), ("_locale", "en_GB"), ("_dc", String(milliseconds)),
        ])
        let response = try await request("\(Self.accountHost)/longPolling/loginUrl?\(query)", identity: identity, jar: [:])
        guard response.isSuccess, let json = Self.accountJSON(response.body), let qr = json["qr"]?.stringValue, let longPoll = json["lp"]?.stringValue else {
            throw CloudError.failed("Xiaomi did not make a QR code (HTTP \(response.status))")
        }
        return QRLogin(qr: qr, longPoll: longPoll, loginURL: json["loginUrl"]?.stringValue ?? qr, timeout: json["timeout"]?.intValue ?? 120)
    }

    enum PollResult: Sendable, Equatable {
        case pending
        case scanned(MiSession)
    }

    /// One long poll of at most `timeout`: pending until the code is scanned and confirmed, then the session.
    func pollQR(_ longPoll: String, identity: Identity, country: String, timeout: Duration = .seconds(10)) async throws -> PollResult {
        let response: HTTPResponse
        do {
            response = try await request(longPoll, identity: identity, jar: [:], timeout: timeout)
        } catch HTTPClientError.timeout {
            return .pending
        }
        guard response.status == 200 else { throw CloudError.failed("the QR code login failed (HTTP \(response.status))") }
        guard let json = Self.accountJSON(response.body), let ssecurity = json["ssecurity"]?.stringValue,
              let userID = json["userId"].flatMap({ $0.stringValue ?? $0.intValue.map(String.init) }), let location = json["location"]?.stringValue else {
            return .pending
        }
        let cUserID = json["cUserId"]?.stringValue, passToken = json["passToken"]?.stringValue
        var jar: Jar = ["userId": userID]
        if let cUserID { jar["cUserId"] = cUserID }
        if let passToken { jar["passToken"] = passToken }
        let serviceToken = try await serviceToken(location: location, identity: identity, jar: jar)
        return .scanned(MiSession(ssecurity: ssecurity, userID: userID, cUserID: cUserID, serviceToken: serviceToken, passToken: passToken,
                                  loginMethod: "qr", identity: identity, country: country, now: now()))
    }

    /// `GET <location>`: the response's `serviceToken` cookie completes the session.
    private func serviceToken(location: String, identity: Identity, jar: Jar) async throws -> String {
        let response = try await request(location, identity: identity, jar: jar)
        guard let token = Self.cookies(from: response)["serviceToken"], !token.isEmpty else {
            throw CloudError.failed("Xiaomi did not give a service token (HTTP \(response.status))")
        }
        return token
    }

    // MARK: Password (4.4, 4.5)

    enum PasswordResult: Sendable {
        case signedIn(MiSession)
        /// A code by email: what verifying it needs.
        case twoFactor(TwoFactor)
    }

    struct TwoFactor: Sendable, Equatable {
        var jar: Jar
        var context: String
        var flag: Int
    }

    enum PasswordError: Error, Equatable {
        case captcha
        case wrongPassword
        /// The account sends its code by text message only (15.5).
        case phoneOnly
    }

    func passwordLogin(username: String, password: String, identity: Identity, country: String) async throws -> PasswordResult {
        var jar: Jar = ["userId": username]
        let first = try await request("\(Self.accountHost)/pass/serviceLogin?sid=xiaomiio&_json=true", identity: identity, jar: jar)
        jar.merge(Self.cookies(from: first)) { $1 }
        let start = Self.accountJSON(first.body)
        if start?["_sign"] == nil, let session = try await finish(start, method: "password", identity: identity, jar: jar, country: country) {
            return .signedIn(session)
        }
        let sign = start?["_sign"]?.stringValue ?? ""
        let response = try await request("\(Self.accountHost)/pass/serviceLoginAuth2", method: "POST", identity: identity, jar: jar, form: [
            ("hash", MiCloudSigning.passwordHash(password)), ("_json", "true"), ("sid", "xiaomiio"), ("callback", Self.sts),
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"), ("_sign", sign), ("user", username),
        ])
        jar.merge(Self.cookies(from: response)) { $1 }
        guard let json = Self.accountJSON(response.body) else { throw CloudError.failed("Xiaomi's sign-in answered HTTP \(response.status)") }
        if json["captchaUrl"]?.stringValue?.isEmpty == false { throw PasswordError.captcha }
        if let ssecurity = json["ssecurity"]?.stringValue, ssecurity.count > 4 {
            // `_sign` that is itself an address is followed instead (homebridge-miot).
            var fields = json.objectValue ?? [:]
            if sign.hasPrefix("http") { fields["location"] = .string(sign) }
            if let session = try await finish(.object(fields), method: "password", identity: identity, jar: jar, country: country) { return .signedIn(session) }
        }
        if let notification = json["notificationUrl"]?.stringValue, !notification.isEmpty {
            return .twoFactor(try await startTwoFactor(notification: notification, identity: identity, jar: jar))
        }
        throw PasswordError.wrongPassword
    }

    /// A body with `ssecurity`, `userId` and `location`: the service token from the location.
    private func finish(_ json: JSONValue?, method: String, identity: Identity, jar: Jar, country: String) async throws -> MiSession? {
        guard let json, let ssecurity = json["ssecurity"]?.stringValue, ssecurity.count > 4,
              let userID = json["userId"].flatMap({ $0.stringValue ?? $0.intValue.map(String.init) }), let location = json["location"]?.stringValue,
              !location.isEmpty else { return nil }
        var jar = jar
        jar["userId"] = userID
        let cUserID = json["cUserId"]?.stringValue, passToken = json["passToken"]?.stringValue
        if let cUserID { jar["cUserId"] = cUserID }
        if let passToken { jar["passToken"] = passToken }
        let token = try await serviceToken(location: location, identity: identity, jar: jar)
        return MiSession(ssecurity: ssecurity, userID: userID, cUserID: cUserID, serviceToken: token, passToken: passToken, loginMethod: method,
                         identity: identity, country: country, now: now())
    }

    /// Opens the two-factor page, finds the account's identities, and has the code sent by email.
    func startTwoFactor(notification: String, identity: Identity, jar: Jar) async throws -> TwoFactor {
        var jar = jar
        let page = try await request(notification, identity: identity, jar: jar)
        jar.merge(Self.cookies(from: page)) { $1 }
        guard let context = URLComponents(string: notification)?.queryItems?.first(where: { $0.name == "context" })?.value else {
            throw CloudError.failed("the two-factor page has no context")
        }
        let encoded = URLEncoding.rfc3986(context)
        let list = try await request("\(Self.accountHost)/identity/list?sid=xiaomiio&context=\(encoded)&_locale=en_US", identity: identity, jar: jar)
        let listCookies = Self.cookies(from: list)
        jar.merge(listCookies) { $1 }
        guard jar["identity_session"] != nil else { throw CloudError.failed("Xiaomi did not open the two-factor check") }
        let flag = Self.accountJSON(list.body)?["flag"]?.intValue ?? 4
        guard flag == 8 else { throw PasswordError.phoneOnly }
        let send = try await request(
            "\(Self.accountHost)/identity/auth/sendEmailTicket?_dc=\(milliseconds)&sid=xiaomiio&context=\(encoded)&mask=0&_locale=en_US",
            method: "POST", identity: identity, jar: jar, form: [("retry", "0"), ("icode", ""), ("_json", "true"), ("ick", jar["ick"] ?? "")])
        jar.merge(Self.cookies(from: send)) { $1 }
        if let code = Self.accountJSON(send.body)?["code"]?.intValue, code != 0 {
            throw CloudError.failed("Xiaomi did not send the code (code \(code))")
        }
        return TwoFactor(jar: jar, context: context, flag: flag)
    }

    enum VerifyError: Error, Equatable {
        case wrongCode(String?)
    }

    /// Verifies the emailed code and follows the chain to the service token (4.5 steps 4 and 5).
    func verifyTwoFactor(_ twoFactor: TwoFactor, code: String, identity: Identity, country: String) async throws -> MiSession {
        var jar = twoFactor.jar
        let encoded = URLEncoding.rfc3986(twoFactor.context)
        let verify = try await request(
            "\(Self.accountHost)/identity/auth/verifyEmail?_flag=8&_json=true&sid=xiaomiio&context=\(encoded)&mask=0&_locale=en_US",
            method: "POST", identity: identity, jar: jar,
            form: [("_flag", "8"), ("ticket", code), ("trust", "false"), ("_json", "true"), ("ick", jar["ick"] ?? "")],
            headers: [("Accept", "application/json"), ("x-requested-with", "XMLHttpRequest")])
        jar.merge(Self.cookies(from: verify)) { $1 }
        let json = Self.accountJSON(verify.body)
        var next = json?["location"]?.stringValue?.nonEmpty
        if json?["code"]?.intValue != 0, next == nil {
            throw VerifyError.wrongCode(json?["desc"]?.stringValue ?? json?["tips"]?.stringValue)
        }
        // The fallbacks when verify gives no location (the extractor's).
        if next == nil { next = verify.header("Location") }
        if next == nil {
            let body = String(decoding: verify.body, as: UTF8.self)
            if let range = body.range(of: #"https://account\.xiaomi\.com/identity/result/check[^"'\s<]*"#, options: .regularExpression) {
                next = String(body[range])
            }
        }
        if next == nil { next = "\(Self.accountHost)/identity/result/check?sid=xiaomiio&context=\(encoded)&_locale=en_US" }
        var ssecurity: String?
        var refetchedTips = false
        var hops = 0
        var location = next
        while let current = location, hops < 10 {
            hops += 1
            let response = try await request(current, identity: identity, jar: jar)
            jar.merge(Self.cookies(from: response)) { $1 }
            if let pragma = response.header("extension-pragma"), let fields = try? JSONValue(string: pragma), let found = fields["ssecurity"]?.stringValue {
                ssecurity = found
            }
            if let token = jar["serviceToken"], let ssecurity, let userID = jar["userId"] {
                return MiSession(ssecurity: ssecurity, userID: userID, cUserID: jar["cUserId"], serviceToken: token, passToken: jar["passToken"],
                                 loginMethod: "password_2fa", identity: identity, country: country, now: now())
            }
            if let redirect = response.header("Location"), !redirect.isEmpty {
                location = redirect.hasPrefix("http") ? redirect : Self.accountHost + redirect
            } else if response.status == 200, !refetchedTips, String(decoding: response.body, as: UTF8.self).contains("Xiaomi Account - Tips") {
                // The tips page: fetched once more.
                refetchedTips = true
            } else if let jsonLocation = Self.accountJSON(response.body)?["location"]?.stringValue?.nonEmpty {
                location = jsonLocation
            } else {
                location = nil
            }
        }
        throw CloudError.failed("Xiaomi's sign-in did not end with a session")
    }

    /// A QR session's refresh (4.6): `serviceLogin` with its `userId` and `passToken` may answer at once.
    func refresh(_ session: MiSession) async throws -> MiSession? {
        guard let passToken = session.passToken else { return nil }
        var jar: Jar = ["userId": session.userID, "passToken": passToken]
        if let cUserID = session.cUserID { jar["cUserId"] = cUserID }
        let response = try await request("\(Self.accountHost)/pass/serviceLogin?sid=xiaomiio&_json=true", identity: session.identity, jar: jar)
        jar.merge(Self.cookies(from: response)) { $1 }
        return try await finish(Self.accountJSON(response.body), method: session.loginMethod, identity: session.identity, jar: jar, country: session.country ?? "cn")
    }

    // MARK: The signed API (4.7, 4.8)

    func call(_ path: String, data: OrderedJSON, session: MiSession, country: String) async throws -> JSONValue {
        let url = Self.apiBase(country: country) + path
        let nonce = MiCloudSigning.nonce(random: random(8), milliseconds: milliseconds)
        guard let signed = MiCloudSigning.fields(url: url, data: data.text, ssecurity: session.ssecurity, nonce: nonce) else { throw CloudError.refused }
        guard let address = URL(string: url) else { throw CloudError.failed("bad address") }
        let cookies: Jar = [
            "sdkVersion": Self.sdkVersion, "deviceId": session.clientID, "userId": session.userID, "yetAnotherServiceToken": session.serviceToken,
            "serviceToken": session.serviceToken, "locale": "en", "channel": "MI_APP_STORE",
        ]
        let request = HTTPRequest(method: "POST", url: address, headers: [
            ("User-Agent", session.identity.userAgent), ("x-xiaomi-protocal-flag-cli", "PROTOCAL-HTTP2"), ("Content-Type", "application/x-www-form-urlencoded"),
            ("Accept-Encoding", "identity"), ("MIOT-ENCRYPT-ALGORITHM", "ENCRYPT-RC4"), ("Cookie", Self.cookieHeader(cookies)),
        ], body: Data(URLEncoding.form(signed.fields).utf8), timeout: .seconds(15))
        let response = try await http.send(request)
        guard response.isSuccess else { throw CloudError.refused }
        guard let plain = MiCloudSigning.decrypt(String(decoding: response.body, as: UTF8.self), signedNonce: signed.signedNonce),
              let json = try? JSONValue(data: plain) else { throw CloudError.refused }
        guard json["code"]?.intValue == 0 else { throw CloudError.failed(json["message"]?.stringValue ?? "code \(json["code"]?.text() ?? "?")") }
        return json["result"] ?? .null
    }

    /// The account's devices in a region (`/home/device_list`).
    func devices(session: MiSession, country: String) async throws -> [CloudDevice] {
        let data = OrderedJSON.object([("getVirtualModel", .value(false)), ("getHuamiDevices", .int(0))])
        let result = try await call("/home/device_list", data: data, session: session, country: country)
        return (result["list"]?.arrayValue ?? []).compactMap(CloudDevice.init(json:))
    }
}
