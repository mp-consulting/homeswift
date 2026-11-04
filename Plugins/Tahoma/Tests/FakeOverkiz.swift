import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftTahoma

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// An Overkiz server in memory (docs/clean-room/Tahoma.md 4): a cloud with a session login, or a gateway's local API with
/// a token, answering the setup it holds and recording every request.
final class FakeOverkiz: HTTPSending, Sendable {
    struct Recorded: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: JSONValue?
        var form: [String: String]
        var path: String { url.path }
    }

    private struct State {
        var devices: JSONValue = []
        var scenarios: JSONValue = []
        var gateways: [String] = ["1234-5678-9012"]
        var events: [JSONValue] = []
        var requests: [Recorded] = []
        var password = "secret"
        var token = "0123456789abcdef0123"
        var loginStatus: Int?
        var nextExec = 0
        var listener = "a70f6d96-0000-4000-8000-0000000000bb"
        var sessionValid = true
        var mintedTokens: [String] = []
        var applyFailures: [Int] = []
        var countryCode = "GB"
        var accessTokens: Set<String> = []
        var refreshTokens: Set<String> = []
        var grants = 0
        var expiresIn: Double? = 900
        var developerMode = false
        var invalidGrantStatus = 200
    }

    private let state = NIOLockedValueBox(State())

    init(devices: JSONValue = FakeOverkiz.setupExcerpt) {
        state.withLockedValue { $0.devices = devices }
    }

    var requests: [Recorded] { state.withLockedValue { $0.requests } }
    func requests(_ suffix: String, method: String? = nil) -> [Recorded] {
        requests.filter { $0.path.hasSuffix(suffix) && (method == nil || $0.method == method) }
    }
    var applies: [Recorded] { requests.filter { $0.path.contains("/exec/apply") } }
    var mintedTokens: [String] { state.withLockedValue { $0.mintedTokens } }

    func setDevices(_ devices: JSONValue) { state.withLockedValue { $0.devices = devices } }
    func setScenarios(_ scenarios: JSONValue) { state.withLockedValue { $0.scenarios = scenarios } }
    func setGateways(_ gateways: [String]) { state.withLockedValue { $0.gateways = gateways } }
    func setPassword(_ password: String) { state.withLockedValue { $0.password = password } }
    func setLoginStatus(_ status: Int?) { state.withLockedValue { $0.loginStatus = status } }
    func expireSession() { state.withLockedValue { $0.sessionValid = false } }
    /// The next applies answer these statuses (400 is a full queue), then succeed.
    func failApplies(_ statuses: [Int]) { state.withLockedValue { $0.applyFailures = statuses } }
    func queue(_ events: [JSONValue]) { state.withLockedValue { $0.events += events } }
    /// Somfy forgets every access token it gave (they expired), keeping the refresh tokens.
    func expireAccessTokens() { state.withLockedValue { $0.accessTokens = [] } }
    func revokeRefreshTokens() { state.withLockedValue { $0.refreshTokens = [] } }
    func setExpiresIn(_ seconds: Double?) { state.withLockedValue { $0.expiresIn = seconds } }
    var developerMode: Bool { state.withLockedValue { $0.developerMode } }
    var tokenRequests: [Recorded] { requests.filter { $0.url.host == "accounts.somfy.com" } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        let form = request.body.map { URLEncoding.fields(String(decoding: $0, as: UTF8.self)) } ?? [:]
        var headers: [String: String] = [:]
        for header in request.headers { headers[header.name.lowercased()] = header.value }
        let recorded = Recorded(method: request.method, url: request.url, headers: headers, body: body, form: form)
        return state.withLockedValue { state in
            state.requests.append(recorded)
            return Self.answer(recorded, &state)
        }
    }

    private static func json(_ value: JSONValue, status: Int = 200, headers: [(name: String, value: String)] = []) -> HomeswiftNetwork.HTTPResponse {
        HomeswiftNetwork.HTTPResponse(status: status, headers: headers, body: value.encoded())
    }

    private static func answer(_ request: Recorded, _ state: inout State) -> HomeswiftNetwork.HTTPResponse {
        let path = request.path
        if request.url.host == "apis.groupe-atlantic.com" {
            if path == "/token" {
                guard request.form["password"] == state.password, request.form["username"]?.hasPrefix("GA-PRIVATEPERSON/") == true else {
                    return json(["error": "invalid_grant", "error_description": "Provided Authorization Grant is invalid."], status: 400)
                }
                return json(["access_token": "atlantic-access", "token_type": "Bearer"])
            }
            return HomeswiftNetwork.HTTPResponse(status: 200, body: Data("\"jwt-from-atlantic\"\n".utf8))
        }
        if request.url.host == "accounts.somfy.com" {
            guard path == "/oauth/oauth/v2/token/jwt", request.form["client_id"] == SomfyOAuth.clientID, request.form["client_secret"] == SomfyOAuth.clientSecret else {
                return json(["message": "error.invalid.client"], status: 400)
            }
            switch request.form["grant_type"] {
            case "password" where request.form["password"] == state.password:
                break
            case "refresh_token" where state.refreshTokens.contains(request.form["refresh_token"] ?? ""):
                state.refreshTokens.remove(request.form["refresh_token"] ?? "")
            default:
                return json(["message": "error.invalid.grant"], status: state.invalidGrantStatus)
            }
            state.grants += 1
            let access = "access-\(state.grants)", refresh = "refresh-\(state.grants)"
            state.accessTokens.insert(access)
            state.refreshTokens.insert(refresh)
            var answer: [String: JSONValue] = ["access_token": .string(access), "refresh_token": .string(refresh), "token_type": "bearer"]
            if let expiresIn = state.expiresIn { answer["expires_in"] = .number(expiresIn) }
            return json(.object(answer))
        }
        if path.hasSuffix("/login") {
            if let status = state.loginStatus { return json(["errorCode": "AUTHENTICATION_ERROR", "error": "Too many requests, try again later"], status: status) }
            let good = request.form["userPassword"] == state.password || request.form["jwt"] == "jwt-from-atlantic"
            guard good else { return json(["errorCode": "AUTHENTICATION_ERROR", "error": "Bad credentials"], status: 401) }
            state.sessionValid = true
            return json(["success": true], headers: [("Set-Cookie", "JSESSIONID=ABCDEF0123456789; Path=/enduser-mobile-web; Secure; HttpOnly")])
        }
        let local = path.contains("/enduser-mobile-web/1/")
        if local {
            guard request.headers["authorization"] == "Bearer \(state.token)" else {
                return json(["errorCode": "RESOURCE_ACCESS_DENIED", "error": "Not authenticated."], status: 401)
            }
        } else if let bearer = request.headers["authorization"] {
            if request.headers["cookie"] != nil {
                return json(["errorCode": "UNSPECIFIED_ERROR", "error": "Cannot use JSESSIONID and bearer token in same request"], status: 400)
            }
            guard bearer.hasPrefix("Bearer "), state.accessTokens.contains(String(bearer.dropFirst(7))) else {
                return json(["errorCode": "RESOURCE_ACCESS_DENIED", "error": "Not authenticated"], status: 401)
            }
        } else {
            guard state.sessionValid, request.headers["cookie"] == "JSESSIONID=ABCDEF0123456789" else {
                state.sessionValid = true
                return json(["errorCode": "RESOURCE_ACCESS_DENIED", "error": "Not authenticated"], status: 401)
            }
        }
        let api = path.components(separatedBy: "enduserAPI").last ?? path
        switch (request.method, api) {
        case ("GET", "/apiVersion"): return json(["protocolVersion": "2026.4.4-12"])
        case ("GET", "/setup/devices"): return json(state.devices)
        case ("GET", "/actionGroups"): return json(state.scenarios)
        case ("GET", "/setup/location"): return json(["countryCode": .string(state.countryCode)])
        case ("GET", "/setup/gateways"): return json(.array(state.gateways.map { ["gatewayId": .string($0)] }))
        case ("GET", let p) where p.hasSuffix("/developerMode"): return json(["active": .bool(state.developerMode)])
        case ("POST", let p) where p.hasSuffix("/developerMode"):
            state.developerMode = true
            return json(.null, status: 204)
        case ("POST", "/events/register"): return json(["id": .string(state.listener)])
        case ("POST", "/setup/devices/states/refresh"): return json(.null, status: 204)
        case ("GET", let p) where p.hasSuffix("/local/tokens/generate"):
            state.token = "minted-token-\(state.mintedTokens.count + 1)"
            state.mintedTokens.append(state.token)
            return json(["token": .string(state.token)])
        case ("POST", let p) where p.hasSuffix("/local/tokens"): return json(["requestId": "r1"])
        case ("POST", let p) where p.hasPrefix("/events/") && p.hasSuffix("/fetch"):
            guard p.contains(state.listener) else { return json(["errorCode": "UNSPECIFIED_ERROR", "error": "Invalid event listener id"], status: 400) }
            defer { state.events = [] }
            return json(.array(state.events))
        case ("POST", let p) where p.hasPrefix("/exec/apply"):
            if !state.applyFailures.isEmpty {
                let status = state.applyFailures.removeFirst()
                return json(["errorCode": "EXEC_QUEUE_FULL", "error": "Execution queue is full on gateway: #1234-5678-9012 (soft limit: 10)"], status: status)
            }
            state.nextExec += 1
            return json(["execId": .string("exec-\(state.nextExec)")])
        case ("POST", let p) where p.hasPrefix("/exec/"):
            state.nextExec += 1
            return json(["execId": .string("scene-exec-\(state.nextExec)")])
        case ("DELETE", let p) where p.hasPrefix("/exec/current/setup/"): return json(.null, status: 204)
        case ("POST", let p) where p.hasPrefix("/setup/devices/") && p.hasSuffix("/states/refresh"): return json(.null, status: 204)
        default: return json(["errorCode": "INVALID_API_CALL", "error": "No such resource"], status: 404)
        }
    }

    /// The setup excerpt of docs/clean-room/Tahoma.md 8.1.
    static let setupExcerpt = try! JSONValue(string: #"""
    [ { "oid": "0f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f", "deviceURL": "io://1234-5678-9012/7654321",
        "label": "Living room shutter", "controllableName": "io:RollerShutterGenericIOComponent",
        "available": true, "enabled": true,
        "definition": { "uiClass": "RollerShutter", "widgetName": "PositionableRollerShutter", "type": "ACTUATOR",
          "commands": [ { "commandName": "setClosure", "nparams": 1 }, { "commandName": "open", "nparams": 0 },
                        { "commandName": "close", "nparams": 0 }, { "commandName": "stop", "nparams": 0 },
                        { "commandName": "my", "nparams": 0 } ] },
        "states": [ { "name": "core:ClosureState", "type": 1, "value": 30 },
                    { "name": "core:TargetClosureState", "type": 1, "value": 30 },
                    { "name": "core:ManufacturerNameState", "type": 3, "value": "Somfy" } ] },
      { "oid": "1a2b3c4d-0000-4000-8000-000000000002", "deviceURL": "rts://1234-5678-9012/16712345",
        "label": "Kitchen blind", "controllableName": "rts:BlindRTSComponent",
        "definition": { "uiClass": "ExteriorScreen", "widgetName": "UpDownExteriorScreen",
          "commands": [ { "commandName": "open", "nparams": 1 }, { "commandName": "close", "nparams": 1 },
                        { "commandName": "my", "nparams": 1 }, { "commandName": "stop", "nparams": 1 } ] } },
      { "oid": "1a2b3c4d-0000-4000-8000-000000000003", "deviceURL": "io://1234-5678-9012/5551234#1",
        "label": "Bathroom heater", "controllableName": "io:AtlanticElectricalHeaterWithAdjustableTemperatureSetpointIOComponent",
        "definition": { "uiClass": "HeatingSystem", "widgetName": "AtlanticElectricalHeaterWithAdjustableTemperatureSetpoint",
          "commands": [ { "commandName": "setOperatingMode", "nparams": 1 }, { "commandName": "setTargetTemperature", "nparams": 1 },
                        { "commandName": "setDerogatedTargetTemperature", "nparams": 1 } ] },
        "states": [ { "name": "core:OperatingModeState", "type": 3, "value": "internal" },
                    { "name": "io:TargetHeatingLevelState", "type": 3, "value": "comfort" },
                    { "name": "io:EffectiveTemperatureSetpointState", "type": 2, "value": 20.5 },
                    { "name": "io:NativeFunctionalLevelState", "type": 3, "value": "Top" } ] },
      { "oid": "1a2b3c4d-0000-4000-8000-000000000004", "deviceURL": "io://1234-5678-9012/5551234#2",
        "label": "Bathroom heater temperature", "controllableName": "io:TemperatureIOSystemSensor",
        "definition": { "uiClass": "TemperatureSensor", "widgetName": "TemperatureSensor", "commands": [] },
        "states": [ { "name": "core:TemperatureState", "type": 2, "value": 293.65 } ] } ]
    """#)

    /// A device of the listing, for tests that need others.
    static func device(
        _ url: String, label: String, uiClass: String, widget: String, controllable: String = "io:SomeIOComponent", commands: [String] = [],
        states: [(String, Int, JSONValue)]? = nil
    ) -> JSONValue {
        var device: [String: JSONValue] = [
            "deviceURL": .string(url), "label": .string(label), "controllableName": .string(controllable), "available": true,
            "definition": ["uiClass": .string(uiClass), "widgetName": .string(widget), "commands": .array(commands.map { ["commandName": .string($0), "nparams": 1] })],
        ]
        if let states { device["states"] = .array(states.map { ["name": .string($0.0), "type": .number(Double($0.1)), "value": $0.2] }) }
        return .object(device)
    }
}

/// Gateways found on the network, for the local API's tests.
final class FakeGateways: Sendable {
    let announced: [GatewayAnnouncement]
    private let browses = NIOLockedValueBox(0)
    init(_ announced: [GatewayAnnouncement]) { self.announced = announced }
    var count: Int { browses.withLockedValue { $0 } }
    func browse() -> [GatewayAnnouncement] {
        browses.withLockedValue { $0 += 1 }
        return announced
    }
}

/// A host with one platform block whose plugin talks to `server`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Tahoma-tests-\(UUID().uuidString)")
    let server: FakeOverkiz
    let gateways: FakeGateways
    let timeScale: Double
    private let plugins = NIOLockedValueBox<[TahomaPlugin]>([])
    let localPins = NIOLockedValueBox<[String?]>([])

    init(server: FakeOverkiz = FakeOverkiz(), gateways: [GatewayAnnouncement] = [], timeScale: Double = 0.01) {
        self.server = server
        self.gateways = FakeGateways(gateways)
        self.timeScale = timeScale
    }

    var plugin: TahomaPlugin? { plugins.withLockedValue { $0.last } }

    var dependencies: TahomaPlugin.Dependencies {
        let server = server, gateways = gateways, pins = localPins
        return TahomaPlugin.Dependencies(
            cloudHTTP: server,
            localHTTP: { pin in
                pins.withLockedValue { $0.append(pin) }
                return server
            },
            browseGateways: { _ in gateways.browse() }, timeScale: timeScale, now: { Date() })
    }

    nonisolated(unsafe) static let account: [String: Any] = ["user": "user@example.com", "password": "secret", "preferLocalAPI": false, "pollingPeriod": 10]

    func start(settings: [String: Any] = TestEnvironment.account) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: TahomaPlugin.platform, name: TahomaPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(TahomaPlugin.Configuration.self, from: json)
            let plugin = TahomaPlugin(configuration: configuration, context: context, dependencies: self.dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: TahomaPlugin.platform, name: TahomaPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
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

extension PluginHost {
    func accessory(_ deviceID: String) -> Accessory? {
        mainBridge.server.accessories.first { $0.id == TahomaPlugin.accessoryID(deviceID: deviceID) }
    }
}

extension Characteristic {
    /// A write as HomeKit makes it: through the handler, then stored.
    func writeFromHomeKit(_ value: HAPValue) async throws {
        try await write(value)
    }
}
