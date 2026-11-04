import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import Logging

// The IMOU Open Platform (docs/clean-room/Imou.md, section 3): every call a signed JSON POST to
// `https://<host>/openapi/<method>`, an access token in its params, answered with `result.code` "0" or an error code.

/// The cloud's regions and their hosts (section 3.1).
enum ImouRegion: String, CaseIterable, Sendable {
    case sg, eu, na, cn

    var host: String {
        switch self {
        case .sg: "openapi-sg.easy4ip.com"
        case .eu: "openapi-fk.easy4ip.com"
        case .na: "openapi-or.easy4ip.com"
        case .cn: "openapi.lechange.cn"
        }
    }

    var label: String {
        switch self {
        case .sg: "Asia Pacific (Singapore)"
        case .eu: "Europe (Frankfurt)"
        case .na: "North America (Oregon)"
        case .cn: "China"
        }
    }
}

/// What a call to the cloud, or a camera, answered instead of what was asked.
enum ImouError: Error, CustomStringConvertible, Equatable {
    /// `result.code` other than "0", with its message.
    case api(code: String, message: String)
    /// No answer, or a 5xx: try again later.
    case unreachable(String)
    case http(Int)
    case malformed(String)
    /// The day's call budget is spent (section 7.2): polling waits for the next day.
    case overBudget

    var description: String {
        switch self {
        case .api(let code, let message):
            switch code {
            case "SN1001": "\(code): the cloud refused the signature: check the App Secret and the system clock"
            case "FL1001": "\(code): the account's device licences are used up (5 on a free developer account): use a second account, or share the camera to one"
            default: "\(code): \(message)"
            }
        case .unreachable(let reason): "the IMOU cloud did not answer: \(reason)"
        case .http(let status): "the IMOU cloud answered HTTP \(status)"
        case .malformed(let reason): "the IMOU cloud's answer was not understood: \(reason)"
        case .overBudget: "the day's budget of cloud calls is spent"
        }
    }

    var code: String? {
        if case .api(let code, _) = self { return code }
        return nil
    }

    /// The App Id or App Secret was refused (section 3.5): the account Needs Authorization.
    var isAuthRefused: Bool { ["SN1001", "SN1004", "OP1008"].contains(code ?? "") }

    /// Codes a sleeping device answers, which one retry after a wait may get past (section 7.4).
    var isDormant: Bool { ["DV1030", "DV1007", "DV1026"].contains(code ?? "") }
}

/// The calls made today (UTC), against the account's limit of 20,000 a day (section 7.2).
struct ImouUsage: Sendable, Equatable {
    static let warnAbove = 15_000
    static let slowDownAbove = 18_000
    static let stopAt = 19_500

    private(set) var day = 0
    private(set) var calls = 0

    static func day(of date: Date) -> Int { Int(date.timeIntervalSince1970 / 86_400) }

    /// Counts one call; true when it crossed `slowDownAbove`.
    mutating func record(at date: Date) -> Bool {
        let today = Self.day(of: date)
        if today != day {
            day = today
            calls = 0
        }
        calls += 1
        return calls == Self.slowDownAbove + 1
    }

    func callsToday(at date: Date) -> Int { Self.day(of: date) == day ? calls : 0 }
}

/// The signed client of one developer app (App Id and App Secret).
actor ImouCloud {
    /// What a call needs from the world; tests fix the clock and the nonces.
    struct Environment: Sendable {
        var transport: any HTTPSending
        var now: @Sendable () -> Date = { Date() }
        /// A fresh nonce per request: 32 random bytes, URL-safe Base64 without padding (section 3.2).
        var nonce: @Sendable () -> String = { Secrets.randomToken() }
        var requestID: @Sendable () -> String = { UUID().uuidString.lowercased() }
    }

    /// A token is fetched again when less than this is left of it (section 3.4).
    static let refreshMargin: TimeInterval = 300

    let appID: String
    private let appSecret: String
    private let environment: Environment
    private let logger: Logger
    /// `https://<host>[:port]/openapi`; a `currentDomain` moves it (section 3.1).
    private(set) var base: URL
    private var token: (value: String, expires: Date)?
    private var fetching: Task<String, any Error>?
    private(set) var usage = ImouUsage()

    init(appID: String, appSecret: String, region: ImouRegion, apiURL: String?, environment: Environment, logger: Logger) {
        self.appID = appID
        self.appSecret = appSecret
        self.environment = environment
        self.logger = logger
        base = Self.baseURL(region: region, apiURL: apiURL)
    }

    /// The region's host, or `apiUrl`: a host name (`openapi-fk.easy4ip.com`) or a whole base URL
    /// (`https://openapi.easy4ip.com/openapi`).
    static func baseURL(region: ImouRegion, apiURL: String?) -> URL {
        let fallback = URL(string: "https://\(region.host)/openapi")!
        guard let text = apiURL?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return fallback }
        if text.contains("://") {
            let trimmed = text.hasSuffix("/") ? String(text.dropLast()) : text
            guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http", url.host != nil else { return fallback }
            return url
        }
        return URL(string: "https://\(text)/openapi") ?? fallback
    }

    /// `sign`: the lowercase hex MD5 of `time:<time>,nonce:<nonce>,appSecret:<appSecret>` (section 3.2).
    static func sign(time: Int, nonce: String, appSecret: String) -> String {
        Secrets.hex(Insecure.MD5.hash(data: Data("time:\(time),nonce:\(nonce),appSecret:\(appSecret)".utf8)))
    }

    /// A request's body: `system` (signed), `params` with the token (except for `accessToken`) and `id`.
    static func body(appID: String, appSecret: String, params: [String: JSONValue], token: String?, time: Int, nonce: String, id: String) -> JSONValue {
        var params = params
        if let token { params["token"] = .string(token) }
        return [
            "system": [
                "ver": "1.0", "sign": .string(sign(time: time, nonce: nonce, appSecret: appSecret)), "appId": .string(appID),
                "time": .number(Double(time)), "nonce": .string(nonce),
            ],
            "params": .object(params),
            "id": .string(id),
        ]
    }

    func callsToday() -> Int { usage.callsToday(at: environment.now()) }

    /// Over the soft limit: polling slows down.
    func isOverBudget() -> Bool { callsToday() > ImouUsage.slowDownAbove }

    /// A method's `data` (`{}` when the answer has none). A `TK1002` fetches the token again, once, and retries once.
    func call(_ method: String, _ params: [String: JSONValue] = [:], polling: Bool = false) async throws -> JSONValue {
        if polling, callsToday() >= ImouUsage.stopAt { throw ImouError.overBudget }
        let used = try await currentToken()
        do {
            return try await send(method, params, token: used)
        } catch let error as ImouError where error.code == "TK1002" {
            if token?.value == used { token = nil }
            let fresh = try await currentToken()
            return try await send(method, params, token: fresh)
        }
    }

    /// Checks the App Id and App Secret: a token fetched now.
    func verify() async throws {
        token = nil
        _ = try await currentToken()
    }

    private func currentToken() async throws -> String {
        if let token, token.expires.timeIntervalSince(environment.now()) > Self.refreshMargin { return token.value }
        if let fetching { return try await fetching.value }
        let task = Task { try await self.fetchToken() }
        fetching = task
        defer { fetching = nil }
        return try await task.value
    }

    private func fetchToken() async throws -> String {
        let data = try await send("accessToken", [:], token: nil)
        guard let value = data["accessToken"]?.stringValue, !value.isEmpty else { throw ImouError.malformed("no access token") }
        let seconds = data["expireTime"]?.doubleValue ?? data["expireTime"]?.stringValue.flatMap(Double.init) ?? 3600
        token = (value, environment.now().addingTimeInterval(seconds.finite ?? 3600))
        if let domain = data["currentDomain"]?.stringValue, let moved = Self.redirect(base, to: domain), moved != base {
            base = moved
            logger.info("The IMOU cloud moved this account to \(moved.host ?? "another host")")
        }
        return value
    }

    /// The base URL on the host and port of a `currentDomain` (`https://openapi-fk.easy4ip.com:443`), scheme added when it has
    /// none.
    static func redirect(_ base: URL, to domain: String) -> URL? {
        let text = domain.contains("://") ? domain : "https://\(domain)"
        guard let parsed = URL(string: text), let host = parsed.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = parsed.port
        components.path = base.path.isEmpty ? "/openapi" : base.path
        return components.url
    }

    private func send(_ method: String, _ params: [String: JSONValue], token: String?) async throws -> JSONValue {
        let now = environment.now()
        if usage.record(at: now) {
            logger.warning("More than \(ImouUsage.slowDownAbove) IMOU cloud calls today (the limit is 20,000): polling slows down until midnight UTC")
        }
        let time = Int(now.timeIntervalSince1970.rounded())
        let body = Self.body(appID: appID, appSecret: appSecret, params: params, token: token, time: time, nonce: environment.nonce(), id: environment.requestID())
        let request = HomeswiftNetwork.HTTPRequest(method: "POST", url: base.appendingPathComponent(method), headers: [("Content-Type", "application/json")],
                                  body: body.encoded(), timeout: .seconds(30))
        let response: HomeswiftNetwork.HTTPResponse
        do {
            response = try await environment.transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ImouError.unreachable("\(error)")
        }
        if response.status >= 500 { throw ImouError.unreachable("HTTP \(response.status)") }
        guard response.status == 200 else { throw ImouError.http(response.status) }
        guard let json = try? JSONValue(data: response.body), let result = json["result"] else { throw ImouError.malformed("no result") }
        let code = result["code"]?.stringValue ?? result["code"]?.intValue.map(String.init)
        guard let code else { throw ImouError.malformed("no result code") }
        logger.trace("IMOU \(method): \(code)")
        guard code == "0" else { throw ImouError.api(code: code, message: String((result["msg"]?.stringValue ?? "").prefix(200))) }
        return result["data"]?.nonNull ?? [:]
    }
}
