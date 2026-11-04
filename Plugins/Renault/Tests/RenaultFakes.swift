import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftRenault

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// docs/clean-room/Renault.md's test vectors (8), invented VINs, ids and tokens.
enum Fixtures {
    static let vin = "VF1TEST0000000001"
    static let kamereon = "https://api-wired-prod-1-euw1.wrd-aws.com"
    static let gigya = "https://accounts.eu1.gigya.com"
    static let account = "acc-myr-1"
    static var vehiclePrefix: String { "/commerce/v1/accounts/\(account)/kamereon" }

    /// A JWT whose payload is `{"exp": <exp>}`.
    static func jwt(exp: Double) -> String {
        let payload = Data(#"{"exp":\#(Int(exp))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).c2lnbmF0dXJl"
    }

    static let persons = #"{"personId":"person-0001","accounts":[{"accountId":"acc-myr-1","accountType":"MYRENAULT","accountStatus":"ACTIVE"},{"accountId":"acc-sfdc-1","accountType":"SFDC","accountStatus":"ACTIVE"}]}"#

    static let vehicles = #"""
        {"accountId":"acc-myr-1","country":"FR","vehicleLinks":[{"brand":"RENAULT","vin":"VF1TEST0000000001","status":"ACTIVE","linkType":"OWNER",
          "vehicleDetails":{"vin":"VF1TEST0000000001","registrationNumber":"AA-00-AA","brand":{"label":"RENAULT"},
            "model":{"code":"R5E1VE","label":"RENAULT 5","group":"971"},"energy":{"code":"ELECX","label":"ELECTRICITY","group":"019"}}}]}
        """#

    static let battery = #"""
        {"data":{"id":"VF1TEST0000000001","attributes":{"timestamp":"2026-05-01T06:07:54Z","batteryLevel":73,"batteryAutonomy":261,
          "V2L_SystemStatusDisplay":0,"plugStatus":0,"chargingStatus":0.0,"chargingRemainingTime":3,
          "chargingRemainingTimeLastUpdateDateTime":"2026-04-30T16:16:10Z"}}}
        """#
    static let batteryPluggedIdle = #"{"data":{"id":"VF1TEST0000000001","attributes":{"batteryLevel":73,"plugStatus":1,"chargingStatus":0.0}}}"#
    static let batteryCharging = #"{"data":{"id":"VF1TEST0000000001","attributes":{"batteryLevel":74,"plugStatus":1,"chargingStatus":1.0}}}"#
    static let hvac = #"{"data":{"id":"VF1TEST0000000001","attributes":{"internalTemperature":15.0,"hvacStatus":"off","socThreshold":15.0,"lastUpdateTime":"2025-03-24T18:57:22Z"}}}"#
    static let hvacOn = #"{"data":{"id":"VF1TEST0000000001","attributes":{"internalTemperature":19.5,"hvacStatus":"on"}}}"#
    static let soc = #"{"lastEnergyUpdateTimestamp":"2025-04-18T06:51:09Z","socMin":20,"socTarget":80}"#
    static let settings = #"""
        {"lastSettingsUpdateTimestamp":"2025-04-24T12:17:12.247Z","delegatedActivated":false,"chargeModeRq":"SCHEDULED",
         "chargeTimeStart":"00:00","chargeDuration":9000,"preconditioningTemperature":20.0,
         "preconditioningHeatedStrgWheel":false,"preconditioningHeatedRightSeat":false,"preconditioningHeatedLeftSeat":false,
         "programs":[{"programActivationStatus":true,"programType":"CHARGE_AND_PRECONDITIONING","programDepartureTime":"02:00",
           "programActivationMonday":true,"programActivationTuesday":true,"programActivationWednesday":true,
           "programActivationThursday":true,"programActivationFriday":true,"programActivationSaturday":true,
           "programActivationSunday":true}]}
        """#
    static let quota = #"{"type":"FUNCTIONAL","messages":[{"code":"err.func.wired.overloaded","message":"You have reached your quota limit"}],"errors":[{"errorCode":"err.func.wired.overloaded","errorMessage":"You have reached your quota limit","errorType":"functional"}]}"#
    static let notSupported = #"{"errors":[{"errorCode":"err.tech.501","errorMessage":"{\"errors\":[{\"status\":\"501\",\"code\":\"error.internal\",\"detail\":\"This feature is not technically supported by this gateway\"}]}"}]}"#
    static let unauthorized = #"{"errors":[{"errorCode":"err.func.wired.unauthorized","errorMessage":"The access is unauthorized"}]}"#
    static let echo = #"{"data":{"type":"Echo","id":"guid","attributes":{}}}"#
}

/// One request the fake saw.
struct SeenRequest: Sendable {
    var method: String
    var host: String
    var path: String
    var query: [String: String]
    var form: [String: String]
    var body: JSONValue?
    var headers: [(name: String, value: String)]
    var at: ContinuousClock.Instant

    func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
    var isKamereon: Bool { host.contains("wrd-aws") }
}

/// The MyRenault cloud in memory: Gigya with its 2FA flow, Kamereon with canned answers by path.
final class FakeRenault: HTTPSending, Sendable {
    struct State {
        var requests: [SeenRequest] = []
        /// Kamereon answers by path below the vehicle prefix (or a whole path), status and body.
        var answers: [String: (Int, String)] = [:]
        var password = "secret"
        /// Accounts that ask for the e-mailed code until it is entered.
        var needsTwoFactor = false
        var finalized = false
        var emails = [("E-1", "d***@example.com")]
        var code = "123456"
        var loginToken = "LT-example-login-token"
        var deadTokens: Set<String> = []
        var jwtExp: Double = Date().timeIntervalSince1970 + 86400
        var jwtCount = 0
        var inFlight = 0
        var maxInFlight = 0
        /// Kamereon answers this to the next N requests.
        var unauthorizedNext = 0
    }

    let state = NIOLockedValueBox(State())

    init() {
        state.withLockedValue {
            $0.answers = [
                "/commerce/v1/persons/person-0001": (200, Fixtures.persons),
                "/commerce/v1/accounts/acc-myr-1/vehicles": (200, Fixtures.vehicles),
                "/commerce/v1/accounts/acc-sfdc-1/vehicles": (200, #"{"accountId":"acc-sfdc-1","vehicleLinks":[]}"#),
                "/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status": (200, Fixtures.battery),
                "/kca/car-adapter/v1/cars/\(Fixtures.vin)/hvac-status": (200, Fixtures.hvac),
                "/kcm/v1/vehicles/\(Fixtures.vin)/ev/soc-levels": (200, Fixtures.soc),
                "/kcm/v1/vehicles/\(Fixtures.vin)/ev/settings": (200, Fixtures.settings),
                "POST /kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/hvac-start": (200, Fixtures.echo),
                "POST /kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/horn-lights": (200, Fixtures.echo),
                "POST /kcm/v1/vehicles/\(Fixtures.vin)/ev/settings": (200, #"{"chargeModeRq":"ALWAYS","programs":[]}"#),
            ]
        }
    }

    func answer(_ path: String, _ status: Int = 200, _ body: String) { state.withLockedValue { $0.answers[path] = (status, body) } }
    var requests: [SeenRequest] { state.withLockedValue { $0.requests } }
    var kamereon: [SeenRequest] { requests.filter(\.isKamereon) }
    func kamereon(_ path: String, method: String = "GET") -> [SeenRequest] {
        kamereon.filter { $0.method == method && ($0.path == path || $0.path == Fixtures.vehiclePrefix + path) }
    }
    func gigya(_ name: String) -> [SeenRequest] { requests.filter { !$0.isKamereon && $0.path == "/\(name)" } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let bodyText = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let form = request.header("Content-Type") == "application/x-www-form-urlencoded" ? URLEncoding.fields(bodyText) : [:]
        let seen = SeenRequest(
            method: request.method, host: request.url.host ?? "", path: request.url.path, query: query, form: form,
            body: request.body.flatMap { try? JSONValue(data: $0) }, headers: request.headers, at: .now)
        state.withLockedValue {
            $0.requests.append(seen)
            $0.inFlight += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
        }
        defer { state.withLockedValue { $0.inFlight -= 1 } }
        if seen.isKamereon {
            // Long enough for a second request to overlap if anything sent two at once.
            try? await Task.sleep(for: .milliseconds(2))
            return kamereonAnswer(seen)
        }
        return gigyaAnswer(seen)
    }

    private func json(_ status: Int, _ text: String, headers: [(name: String, value: String)] = []) -> HomeswiftNetwork.HTTPResponse {
        HomeswiftNetwork.HTTPResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    private func kamereonAnswer(_ request: SeenRequest) -> HomeswiftNetwork.HTTPResponse {
        state.withLockedValue { state in
            if state.unauthorizedNext > 0 {
                state.unauthorizedNext -= 1
                return json(401, Fixtures.unauthorized)
            }
            let relative = request.path.hasPrefix(Fixtures.vehiclePrefix) ? String(request.path.dropFirst(Fixtures.vehiclePrefix.count)) : request.path
            let key = request.method == "GET" ? relative : "\(request.method) \(relative)"
            guard let (status, body) = state.answers[key] else {
                return json(404, #"{"errors":[{"errorCode":"err.func.wired.notFound","errorMessage":"not found"}]}"#)
            }
            return json(status, body)
        }
    }

    private func gigyaAnswer(_ request: SeenRequest) -> HomeswiftNetwork.HTTPResponse {
        state.withLockedValue { state in
            let cookies = request.header("Cookie") ?? ""
            switch request.path {
            case "/accounts.login":
                guard request.form["password"] == state.password else {
                    return json(403, #"{"errorCode":403042,"errorDetails":"invalid loginID or password","errorMessage":"Invalid LoginID","statusCode":403}"#)
                }
                if state.needsTwoFactor, !(state.finalized && cookies.contains("gmid=G1")) {
                    return json(403, #"{"errorCode":403101,"errorDetails":"Pending Two-Factor Authentication","statusCode":403,"regToken":"RT-example"}"#)
                }
                return json(200, #"{"callId":"c1","errorCode":0,"statusCode":200,"sessionInfo":{"cookieName":"glt_x","cookieValue":"\#(state.loginToken)"}}"#)
            case "/accounts.getAccountInfo":
                return json(200, #"{"errorCode":0,"data":{"personId":"person-0001","gigyaDataCenter":"eu1"}}"#)
            case "/accounts.getJWT":
                if state.deadTokens.contains(request.form["login_token"] ?? "") {
                    return json(403, #"{"errorCode":403005,"errorDetails":"Unauthorized user","statusCode":403}"#)
                }
                state.jwtCount += 1
                return json(200, #"{"errorCode":0,"id_token":"\#(Fixtures.jwt(exp: state.jwtExp))"}"#)
            case "/accounts.webSdkBootstrap":
                return json(200, #"{"errorCode":0}"#, headers: [("Set-Cookie", "gmid=G1; path=/; secure"), ("Set-Cookie", "ucid=U1; path=/"), ("Set-Cookie", "hasGmid=ver4")])
            case "/accounts.tfa.initTFA":
                guard request.query["regToken"] == "RT-example", request.query["gmid"] == "G1" else { return json(400, #"{"errorCode":400006}"#) }
                return json(200, #"{"errorCode":0,"gigyaAssertion":"GA-1"}"#)
            case "/accounts.tfa.email.getEmails":
                let list = state.emails.map { #"{"id":"\#($0.0)","obfuscated":"\#($0.1)"}"# }.joined(separator: ",")
                return json(200, #"{"errorCode":0,"emails":[\#(list)]}"#)
            case "/accounts.tfa.email.sendVerificationCode":
                return json(200, #"{"errorCode":0,"phvToken":"PHV-1"}"#)
            case "/accounts.tfa.email.completeVerification":
                guard request.query["code"] == state.code, request.query["phvToken"] == "PHV-1" else {
                    return json(400, #"{"errorCode":400006,"errorDetails":"Wrong verification code","statusCode":400}"#)
                }
                return json(200, #"{"errorCode":0,"providerAssertion":"PA-1"}"#)
            case "/accounts.tfa.finalizeTFA":
                guard request.query["providerAssertion"] == "PA-1", request.query["tempDevice"] == "false" else { return json(400, #"{"errorCode":400006}"#) }
                state.finalized = true
                return json(200, #"{"errorCode":0}"#)
            default:
                return json(404, #"{"errorCode":404000}"#)
            }
        }
    }
}

/// Short timings: an "hour" of `hour`, confirmations and holds in milliseconds.
func testTiming(hour: Duration = .seconds(3600)) -> RenaultTiming {
    var timing = RenaultTiming()
    timing.hour = hour
    timing.cooldown = .seconds(3600)
    timing.confirmations = [.milliseconds(100), .milliseconds(200)]
    timing.optimisticHold = .milliseconds(400)
    timing.momentary = .milliseconds(100)
    timing.requestTimeout = .seconds(5)
    timing.retry = .milliseconds(50)
    timing.retryMaximum = .milliseconds(200)
    return timing
}

/// A host with one Renault block whose plugin talks to `cloud`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Renault-tests-\(UUID().uuidString)")
    let cloud = FakeRenault()
    let timing: RenaultTiming
    private let plugins = NIOLockedValueBox<[RenaultPlugin]>([])

    init(timing: RenaultTiming = testTiming()) { self.timing = timing }

    var plugin: RenaultPlugin? { plugins.withLockedValue { $0.last } }

    func registry() -> PluginRegistry {
        var registry = PluginRegistry()
        registry.register(platform: RenaultPlugin.platform, name: RenaultPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(RenaultPlugin.Configuration.self, from: json)
            let plugin = RenaultPlugin(configuration: configuration, context: context, dependencies: .init(http: self.cloud, timing: self.timing))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        return registry
    }

    /// A block signed in by hand: the e-mail and password, the account chosen.
    nonisolated(unsafe) static let signedIn: [String: Any] = ["username": "driver@example.com", "password": "secret", "kamereonAccountId": "acc-myr-1", "locale": "fr_FR"]

    func start(settings: [String: Any] = TestEnvironment.signedIn) async throws -> PluginHost {
        let block = try HomeswiftConfiguration.Platform(platform: RenaultPlugin.platform, name: RenaultPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry(), storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
