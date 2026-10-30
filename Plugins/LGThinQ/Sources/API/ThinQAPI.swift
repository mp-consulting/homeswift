import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The ThinQ REST API: the gateway, the session (signed in with a refresh token or an account), the homes and
/// their devices, ThinQ v2 commands and ThinQ v1 monitoring. Requests that fail resolve to `{}` and are logged,
/// as the Homebridge plugin does, so a flaky cloud degrades instead of stopping the plugin; an expired token is
/// refreshed once (one refresh for a burst of requests), new terms are accepted, and LG's rate limit pauses
/// requests for a minute, doubling up to half an hour.
@ThinQActor
final class ThinQAPI {
    let country: String
    let language: String
    let client: RequestClient
    var logger: Logger

    private(set) var gatewayInfo: Gateway?
    private(set) var session = Session(accessToken: "", refreshToken: "", expiresAt: 0)
    private(set) var auth: Auth?
    private(set) var jsessionID: String?
    private(set) var userNumber: String?
    private(set) var clientID: String?
    private var homes: [JSONValue]?
    private var username: String?
    private var password: String?
    private var refreshing: Task<Void, any Error>?
    private var rateLimitedUntil: ContinuousClock.Instant?
    private var rateLimitBackoff: Duration = .zero

    init(country: String, language: String, client: RequestClient, logger: Logger) {
        self.country = country
        self.language = language
        self.client = client
        self.logger = logger
    }

    func setRefreshToken(_ token: String) throws {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw ThinQError.invalid("Invalid refreshToken: refreshToken must be a non-empty string.") }
        session = Session(accessToken: "", refreshToken: token, expiresAt: 0)
    }

    func setUsernamePassword(_ username: String, _ password: String) {
        self.username = username
        self.password = password
    }

    /// Whether LG is rate-limiting the account; non-essential work can wait.
    var isRateLimited: Bool { rateLimitedUntil.map { ContinuousClock.now < $0 } ?? false }

    private func markRateLimited() {
        rateLimitBackoff = rateLimitBackoff == .zero ? ThinQConstants.rateLimitBase : min(rateLimitBackoff * 2, ThinQConstants.rateLimitMax)
        rateLimitedUntil = ContinuousClock.now + rateLimitBackoff
        logger.warning("LG ThinQ API rate limit hit (HTTP 429 / 9012). Pausing requests for \(rateLimitBackoff.components.seconds)s so the throttle can clear. If this keeps happening, increase the refresh interval or reduce other ThinQ integrations.")
    }

    private func clearRateLimit() {
        if rateLimitBackoff != .zero { logger.info("LG ThinQ API rate limit cleared; resuming normal requests.") }
        rateLimitBackoff = .zero
        rateLimitedUntil = nil
    }

    func gateway() async throws -> Gateway {
        if let gatewayInfo { return gatewayInfo }
        let answer = try await client.get(ThinQConstants.gatewayURL, headers: defaultHeaders).data
        let gateway = Gateway(answer["result"] ?? .null)
        gatewayInfo = gateway
        return gateway
    }

    /// Signs in (or refreshes the token) and fetches what requests carry: the v1 session, the user number,
    /// the client id.
    func ready() async throws {
        let gateway = try await gateway()
        if auth == nil { auth = Auth(gateway: gateway, client: client, logger: logger) }
        guard let auth else { return }
        if !session.hasToken, let username, let password, !username.isEmpty, !password.isEmpty {
            session = try await auth.login(username: username, password: password)
            try await refreshNewToken(session)
        }
        if !session.hasValidToken, !session.refreshToken.isEmpty {
            try await refreshNewToken(session)
        }
        if jsessionID == nil { jsessionID = await auth.jsessionID(accessToken: session.accessToken) }
        if userNumber == nil { userNumber = try await auth.userNumber(accessToken: session.accessToken) }
        if clientID == nil {
            let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
            clientID = Secrets.hex(SHA256.hash(data: Data("\(userNumber ?? "undefined")\(milliseconds)".utf8)))
        }
    }

    /// One refresh at a time: concurrent callers that all saw an expired token wait for the same one.
    func refreshNewToken(_ current: Session? = nil) async throws {
        if let refreshing { return try await refreshing.value }
        let task = Task { @ThinQActor in
            guard let auth = self.auth else { throw ThinQError.token("not signed in") }
            self.session = try await auth.refreshNewToken(current ?? self.session)
            self.jsessionID = await auth.jsessionID(accessToken: self.session.accessToken)
        }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    // MARK: Requests

    func getRequest(_ uri: String) async -> JSONValue {
        await request("GET", uri)
    }

    /// `quiet` logs failures at debug level, for background calls that may legitimately fail.
    func postRequest(_ uri: String, _ data: JSONValue, quiet: Bool = false) async -> JSONValue {
        await request("POST", uri, data, quiet: quiet)
    }

    private func request(_ method: String, _ uri: String, _ data: JSONValue? = nil, retry: Bool = false, quiet: Bool = false) async -> JSONValue {
        if isRateLimited {
            logger.debug("Skipping request during rate-limit cooldown: \(uri)")
            return [:]
        }
        // A request that left with a token another request has replaced since retries without a refresh.
        let usedToken = session.accessToken
        do {
            let gateway = try await gateway()
            let headers = !gateway.thinq1URI.isEmpty && uri.hasPrefix(gateway.thinq1URL) ? monitorHeaders : defaultHeaders
            let url = Self.resolve(uri, against: gateway.thinq2URL)
            let response = if method == "GET" {
                try await client.get(url, headers: headers)
            } else {
                try await client.post(url, json: data ?? [:], headers: headers)
            }
            clearRateLimit()
            return response.data
        } catch let error as ThinQError {
            switch error {
            case .tokenExpired where !retry:
                do {
                    if session.accessToken == usedToken { try await refreshNewToken() }
                } catch {
                    logger.error("refresh new token error: \(error)")
                    return [:]
                }
                return await request(method, uri, data, retry: true, quiet: quiet)
            case .manualProcessNeeded(let message):
                logger.warning("Handling new term agreement... If you keep getting this message, \(message)")
                do {
                    try await auth?.handleNewTerm(accessToken: session.accessToken)
                    logger.warning("LG new term agreement is accepted.")
                } catch {
                    logger.error("\(error)")
                }
                return retry ? [:] : await request(method, uri, data, retry: true, quiet: quiet)
            case .http(let status, let body):
                if status == 429 || body["resultCode"].map({ JS.string($0) }) == "9012" {
                    markRateLimited()
                    return [:]
                }
                log(quiet, "request error: HTTP \(status) \(logExcerpt(body.stringValue ?? body.text(), limit: 500) ?? "") \(data.flatMap { logExcerpt($0.text(), limit: 500) } ?? "")")
            case .notConnected:
                break
            default:
                log(quiet, "request error: \(error)")
            }
            return [:]
        } catch {
            log(quiet, "request error: \(error)")
            return [:]
        }
    }

    private func log(_ quiet: Bool, _ message: String) {
        if quiet { logger.debug("\(message)") } else { logger.error("\(message)") }
    }

    /// `new URL(uri, base)`: absolute URIs as they are, relative ones under the ThinQ v2 base.
    nonisolated static func resolve(_ uri: String, against base: String) -> String {
        if let url = URL(string: uri), url.scheme != nil { return uri }
        return URL(string: uri, relativeTo: URL(string: base))?.absoluteString ?? base + uri
    }

    var monitorHeaders: [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = [("Accept", "application/json"), ("x-thinq-application-key", "wideq"), ("x-thinq-security-key", "nuts_securitykey")]
        headers.append(("x-thinq-token", session.accessToken))
        if let jsessionID { headers.append(("x-thinq-jsessionId", jsessionID)) }
        return headers
    }

    var defaultHeaders: [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = [
            ("x-api-key", ThinQConstants.apiKey), ("x-thinq-app-ver", "3.6.1200"), ("x-thinq-app-type", "NUTS"), ("x-thinq-app-level", "PRD"),
            ("x-thinq-app-os", "ANDROID"), ("x-thinq-app-logintype", "LGE"), ("x-service-code", "SVC202"), ("x-country-code", country),
            ("x-language-code", language), ("x-service-phase", "OP"), ("x-origin", "app-native"), ("x-model-name", "samsung/SM-G930L"),
            ("x-os-version", "AOS/7.1.2"), ("x-app-version", "LG ThinQ/3.6.12110"), ("x-message-id", Auth.randomString(22)), ("user-agent", "okhttp/3.14.9"),
        ]
        if session.hasToken { headers.append(("x-emp-token", session.accessToken)) }
        if let userNumber { headers.append(("x-user-no", userNumber)) }
        headers.append(("x-client-id", clientID ?? ThinQConstants.apiClientID))
        return headers
    }

    // MARK: Devices

    /// Every device of every home. A failed or rate-limited request leaves its home out.
    func listDevices() async -> [JSONValue] {
        await deviceListing().devices
    }

    /// Every device of every home, and whether LG answered for the home list and each home: a failed or
    /// rate-limited request leaves its home out and the listing incomplete.
    func deviceListing() async -> (devices: [JSONValue], complete: Bool) {
        let homes = await listHomes()
        var complete = self.homes != nil
        var devices: [JSONValue] = []
        for home in homes {
            let answer = await getRequest("service/homes/" + JS.string(home["homeId"]))
            guard let result = answer["result"]?.objectValue else {
                complete = false
                continue
            }
            devices += result["devices"]?.arrayValue ?? []
        }
        return (devices, complete)
    }

    /// The homes, cached once a request answered them.
    func listHomes() async -> [JSONValue] {
        if homes == nil, let items = await getRequest("service/homes")["result"]?["item"]?.arrayValue {
            homes = items
        }
        return homes ?? []
    }

    /// A ThinQ v2 command: `Set` or `Operation`, under a control key and path.
    func sendCommand(to deviceID: String, values: [String: JSONValue], command: String, ctrlKey: String = "basicCtrl", ctrlPath: String = "control-sync", quiet: Bool = false) async throws -> JSONValue {
        guard !deviceID.trimmingCharacters(in: .whitespaces).isEmpty else { throw ThinQError.invalid("Invalid device_id: must be a non-empty string.") }
        guard ["Set", "Operation"].contains(command) else { throw ThinQError.invalid("Invalid command: must be \"Set\" or \"Operation\".") }
        var body = values
        body["ctrlKey"] = .string(ctrlKey)
        body["command"] = .string(command)
        return await postRequest("service/devices/\(deviceID)/\(ctrlPath)", .object(body), quiet: quiet)
    }

    /// Starts or stops ThinQ v1 monitoring of a device.
    func sendMonitorCommand(deviceID: String, cmdOpt: String, workID: String) async throws -> JSONValue {
        guard !deviceID.isEmpty else { throw ThinQError.invalid("Invalid deviceId: must be a non-empty string.") }
        return await thinq1PostRequest("rti/rtiMon", ["cmd": "Mon", "cmdOpt": .string(cmdOpt), "deviceId": .string(deviceID), "workId": .string(workID)])
    }

    /// The latest ThinQ v1 monitoring data, nil when there is none yet.
    func monitorResult(deviceID: String, workID: String) async throws -> Data? {
        let data = await thinq1PostRequest("rti/rtiResult", ["workList": [["deviceId": .string(deviceID), "workId": .string(workID)]]])
        guard let workList = data["workList"], workList.objectValue != nil, let code = workList["returnCode"] else { return nil }
        guard JS.string(code) == "0000" else { throw ThinQError.monitor(data.text()) }
        guard let returnData = workList["returnData"] else { return nil }
        return Self.decodeBase64(JS.string(returnData))
    }

    /// `Buffer.from(text, 'base64')`: lenient, as Node is. Characters outside the alphabet (line breaks,
    /// spaces) are skipped, the URL-safe `-` and `_` are accepted, decoding ends at the first `=`, and missing
    /// padding is fine. A strict decoder fails on such data and the device would read as online with nothing.
    nonisolated static func decodeBase64(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in text.utf8 {
            let value: UInt32
            switch character {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(character - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(character - UInt8(ascii: "a")) + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(character - UInt8(ascii: "0")) + 52
            case UInt8(ascii: "+"), UInt8(ascii: "-"): value = 62
            case UInt8(ascii: "/"), UInt8(ascii: "_"): value = 63
            case UInt8(ascii: "="): return Data(bytes)
            default: continue
            }
            buffer = (buffer << 6 | value) & 0xFFFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return Data(bytes)
    }

    func thinq1PostRequest(_ endpoint: String, _ data: JSONValue) async -> JSONValue {
        guard let gateway = try? await gateway() else { return [:] }
        return await postRequest(gateway.thinq1URL + endpoint, ["lgedmRoot": data])["lgedmRoot"] ?? [:]
    }

    /// GET through the shared pipeline without the API's headers (the model JSON on LG's CDN). The URL comes
    /// from LG's device list: only HTTP(S), never a `file:` URL URLSession would read from the disk.
    func download(_ url: String) async throws -> JSONValue {
        guard let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ThinQError.invalid("Invalid model URL")
        }
        return try await client.get(url).data
    }
}
