import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDaikinCloud

/// The Onecta cloud in memory: the devices it lists, the writes it takes, the tokens it hands out.
final class FakeCloud: @unchecked Sendable {
    let devices: NIOLockedValueBox<[JSONValue]>
    let gets = NIOLockedValueBox(0)
    let writes = NIOLockedValueBox<[(path: String, body: JSONValue?)]>([])
    /// What the device list answers instead, once.
    let failure = NIOLockedValueBox<HTTPResponse?>(nil)
    let quota = NIOLockedValueBox<Int?>(nil)
    lazy var http = FakeHTTP { [unowned self] request, _ in try await self.answer(request) }

    init(devices: [JSONValue]) {
        self.devices = NIOLockedValueBox(devices)
    }

    func answer(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        if url.hasPrefix("https://api.onecta.daikineurope.com/v1/gateway-devices") {
            if request.method == "GET" {
                gets.withLockedValue { $0 += 1 }
                if let failure = failure.withLockedValue({ value -> HTTPResponse? in defer { value = nil }; return value }) { return failure }
                var headers: [(name: String, value: String)] = []
                if let quota = quota.withLockedValue({ $0 }) { headers = [("x-ratelimit-remaining-day", String(quota)), ("x-ratelimit-limit-day", "200")] }
                return .json(.array(devices.withLockedValue { $0 }), headers: headers)
            }
            writes.withLockedValue { $0.append((request.url.path, request.bodyJSON)) }
            return .text("", status: 204)
        }
        if url.hasPrefix(DeveloperPortalOAuth.tokenEndpoint.absoluteString) {
            switch request.form["grant_type"] {
            case "authorization_code" where ["good-code", "mobile-code"].contains(request.form["code"] ?? ""):
                return .json(["access_token": "dev-access", "refresh_token": "dev-refresh", "token_type": "Bearer", "expires_in": 3600])
            case "authorization_code":
                return .json(["error": "invalid_grant", "error_description": "Bad code"], status: 400)
            case "refresh_token":
                return .json(["access_token": "refreshed", "token_type": "Bearer", "expires_in": 3600])
            default:
                return .text("", status: 400)
            }
        }
        if url.hasPrefix(DeveloperPortalOAuth.revokeEndpoint.absoluteString) { return .text("", status: 200) }
        if url.contains("/authorize/continue") { return HTTPResponse(status: 302, headers: [("location", "daikinunified://login?code=mobile-code")]) }
        if url.contains("/oidc/op/v1.0/") { return HTTPResponse(status: 302, headers: [("location", "https://id.daikin.eu/?context=ctx&mode=login")]) }
        if url.contains("accounts.webSdkBootstrap") { return .json([:], headers: [("set-cookie", "gig=1; Path=/")]) }
        if url.contains("accounts.login") {
            return request.form["password"] == "right" ? .json(["errorCode": 0, "sessionInfo": ["login_token": "lt"]]) : .json(["errorCode": 403042, "errorMessage": "Invalid LoginID"])
        }
        return .text("Unexpected \(url)", status: 500)
    }
}

/// A host with one DaikinCloud block whose plugin talks to the fake cloud.
final class DaikinEnvironment: @unchecked Sendable {
    let directory = temporaryDirectory()
    let cloud: FakeCloud
    let sockets: FakeSockets?
    let log = LogRecorder()
    private let plugins = NIOLockedValueBox<[DaikinCloudPlugin]>([])
    private let storageBox = NIOLockedValueBox<URL?>(nil)
    var timing = DaikinSession.Timing()
    var tokens: (AuthMode, TokenSet)?

    init(devices: [JSONValue] = [Fixture.json("dx4Airco"), Fixture.json("althermaHeatPump")], sockets: FakeSockets? = nil) {
        cloud = FakeCloud(devices: devices)
        self.sockets = sockets
    }

    var plugin: DaikinCloudPlugin? { plugins.withLockedValue { $0.last } }

    static let validToken = TokenSet(access_token: "token", refresh_token: "refresh", token_type: "Bearer", expires_in: 3600, expires_at: Date().timeIntervalSince1970 + 3600)

    func host(_ settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        let cloud = cloud, sockets = sockets, timing = timing, tokens = tokens
        registry.register(platform: DaikinCloudPlugin.platform, name: DaikinCloudPlugin.name, webFiles: DaikinCloudPlugin.webFiles) { json, context in
            self.storageBox.withLockedValue { $0 = context.storageDirectory }
            if let (mode, set) = tokens { try TokenFile.save(set, to: context.storageDirectory.appendingPathComponent(mode.tokenFileName)) }
            var dependencies = DaikinCloudPlugin.Dependencies()
            dependencies.transport = { _ in cloud.http }
            dependencies.webSocket = sockets?.connect
            dependencies.addresses = { ["192.168.1.20", "10.0.0.2"] }
            dependencies.sessionTiming = timing
            dependencies.apiDependencies.sleep = { _ in }
            dependencies.logger = self.log.logger
            let plugin = DaikinCloudPlugin(configuration: try JSONDecoder().decode(DaikinCloudPlugin.Configuration.self, from: json), context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: DaikinCloudPlugin.platform, name: "Daikin Cloud", settings: settings)
        let options = PluginHost.Options(advertise: false, logger: log.logger) { _ in MemoryStorage() }
        return try PluginHost(configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]), registry: registry, storageDirectory: directory, options: options)
    }

    func start(_ settings: [String: Any]) async throws -> PluginHost {
        let host = try host(settings)
        try await host.start()
        await plugin?.settle()
        return host
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue = .null) async throws -> PluginWebResponse {
        try await plugin!.handleWebRequest(PluginWebRequest(method: method, path: path, query: query, body: body, user: "admin"))
    }

    var storage: URL { storageBox.withLockedValue { $0! } }
}

var developerBlock: [String: Any] {
    [
        "authMode": "developer_portal", "clientId": "client", "clientSecret": "secret", "callbackServerExternalAddress": "127.0.0.1", "callbackServerPort": 8582,
    ]
}
let dx4ID = "DaikinCloud:ca043bde-8db6-488b-a69e-f43949a24020"

@Suite(.timeLimit(.minutes(1)))
struct PluginTests {
    @Test func waitsForCredentials() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(["authMode": "mobile_app"])
        defer { Task { await host.stop() } }
        #expect(host.mainBridge.server.accessories.count == 1)
        #expect(environment.log.contains("Mobile App mode expects the config keys \"daikinEmail\" and \"daikinPassword\"."))
        let status = try await environment.request("GET", "auth/status")
        #expect(status.json["authenticated"] == false)
        #expect(environment.cloud.gets.withLockedValue { $0 } == 0)
    }

    @Test func notAuthenticatedYet() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        #expect(host.mainBridge.server.accessories.count == 1)
        #expect(environment.log.contains("[Auth] Not authenticated."))
        #expect(environment.log.contains("--------------- End Daikin info for debugging reasons"))
    }

    @Test func putsTheDevicesInHomeKit() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        let host = try await environment.start(developerBlock.merging(["showPowerfulMode": true]) { $1 })
        defer { Task { await host.stop() } }
        let accessories = host.mainBridge.server.accessories.dropFirst()
        #expect(accessories.map(\.id) == [dx4ID, "DaikinCloud:10b029e7-484c-4519-b22e-c14be4b7a71c"])
        let dx4 = try #require(accessories.first)
        #expect(dx4.name == "Zolder")
        #expect(dx4.information[.manufacturer]?.value == "Daikin")
        #expect(dx4.information[.model]?.value == "BRP069C4x")
        #expect(dx4.information[.serialNumber]?.value == "0000000002410756")
        #expect(dx4.information[.firmwareRevision]?.value == "1.12.51")
        #expect(dx4.category == .airConditioner)
        #expect(dx4.service(.heaterCooler) != nil)
        #expect(dx4.service(.switch, subtype: "climateControl:powerful_mode") != nil)
        let altherma = try #require(accessories.last)
        #expect(altherma.name == "Altherma")
        #expect(altherma.service(.thermostat, subtype: "hot_water_tank") != nil)
        #expect(altherma.service(.switch, subtype: "domesticHotWaterTank:powerful_mode") != nil)
        #expect(environment.log.contains("[Platform] Device found with id: ca043bde-8db6-488b-a69e-f43949a24020"))
        #expect(environment.log.contains("[Platform]     capabilities: powerful, econo, streamer"))
        // A write from HomeKit reaches the cloud.
        try await dx4.service(.heaterCooler)?.characteristic(.active).write(0)
        #expect(environment.cloud.writes.withLockedValue { $0.map(\.path) } == ["/v1/gateway-devices/ca043bde-8db6-488b-a69e-f43949a24020/management-points/climateControl/characteristics/onOffMode"])
        #expect(environment.cloud.writes.withLockedValue { $0.last?.body } == ["value": "off"])
        // The page lists them from the instance, without a call.
        let gets = environment.cloud.gets.withLockedValue { $0 }
        let list = try await environment.request("GET", "devices/list", query: ["mode": "developer_portal"])
        #expect(list.json["success"] == true)
        #expect(list.json["cached"] == true)
        #expect(list.json["devices"]?[0]?["name"] == "Zolder")
        #expect(list.json["devices"]?[0]?["model"] == "BRP069C4x")
        #expect(list.json["devices"]?[0]?["roomTemp"] == "25°C")
        #expect(list.json["devices"]?[0]?["features"] == ["Power", "Temperature", "Mode", "Fan", "Sensors"])
        #expect(list.json["devices"]?[1]?["type"] == "Hot Water Tank" || list.json["devices"]?[1]?["type"] == "Climate Control")
        #expect(environment.cloud.gets.withLockedValue { $0 } == gets)
        // Refresh asks the cloud, then the next five minutes reuse it.
        _ = try await environment.request("GET", "devices/list", query: ["mode": "developer_portal", "refresh": "1"])
        let cached = try await environment.request("GET", "devices/list", query: ["mode": "developer_portal"])
        #expect(cached.json["cached"] == true)
        #expect(environment.cloud.gets.withLockedValue { $0 } == gets + 1)
        let status = try await environment.request("GET", "auth/status")
        #expect(status.json["authenticated"] == true)
        #expect(status.json["authMode"] == "developer_portal")
        #expect(status.json["session"]?["running"] == true)
        #expect(status.json["session"]?["devices"] == 2)
    }

    @Test func excludedDevicesLeave() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        let first = try await environment.start(developerBlock)
        #expect(first.mainBridge.server.accessories.count == 3)
        await first.stop()
        let second = try await environment.start(developerBlock.merging(["excludedDevicesByDeviceId": ["ca043bde-8db6-488b-a69e-f43949a24020"]]) { $1 })
        defer { Task { await second.stop() } }
        #expect(await eventually { second.mainBridge.server.accessories.count == 2 })
        #expect(!second.mainBridge.server.accessories.contains { $0.id == dx4ID })
        #expect(environment.log.contains("is excluded, don't add accessory"))
    }

    @Test func invalidGrantRemovesTheTokenFile() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, TokenSet(access_token: "old", refresh_token: "dead", token_type: "Bearer", expires_at: 1))
        environment.cloud.http.set { request, _ in
            request.url.absoluteString.hasPrefix(DeveloperPortalOAuth.tokenEndpoint.absoluteString)
                ? .json(["error": "invalid_grant", "error_description": "expired"], status: 400) : .json([])
        }
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        #expect(environment.log.contains("TokenSet is invalid, removing TokenSet file"))
        #expect(!FileManager.default.fileExists(atPath: environment.storage.appendingPathComponent(".daikin-controller-cloud-tokenset").path))
        #expect(host.mainBridge.server.accessories.count == 1)
    }

    /// Seen live: once the saved token had expired, the page's connection test sent it as it was and failed. It goes
    /// through the running instance's token client, which refreshes first.
    @Test func theConnectionTestRefreshesAnExpiredToken() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, TokenSet(access_token: "old", refresh_token: "r", token_type: "Bearer", expires_at: 1))
        let cloud = environment.cloud
        environment.cloud.http.set { request, _ in
            let url = request.url.absoluteString
            if url.hasPrefix(DeveloperPortalOAuth.tokenEndpoint.absoluteString) {
                return .json(["access_token": "refreshed", "token_type": "Bearer", "expires_in": 3600])
            }
            if request.header("Authorization") == "Bearer old" { return .json(["message": "Unauthorized"], status: 401) }
            return try await cloud.answer(request)
        }
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        #expect(await eventually { host.mainBridge.server.accessories.count > 1 })
        // The file says expired, as it does on disk until the instance's next call refreshes it.
        try TokenFile.save(TokenSet(access_token: "old", refresh_token: "r", token_type: "Bearer", expires_at: 1),
                       to: environment.storage.appendingPathComponent(".daikin-controller-cloud-tokenset"))
        let test = try await environment.request("POST", "auth/test")
        #expect(test.json["success"] == true)
    }

    @Test func mobileAppLogsInByItself() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(["authMode": "mobile_app", "daikinEmail": "me@example.com", "daikinPassword": "right"])
        defer { Task { await host.stop() } }
        #expect(environment.log.contains("[Auth] Authentication successful!"))
        #expect(host.mainBridge.server.accessories.count == 3)
        #expect(TokenFile.load(environment.storage.appendingPathComponent(".daikin-mobile-tokenset"))?.access_token == "dev-access")
        // Without a WebSocket client, it polls.
        #expect(environment.log.contains("[WebSocket] No WebSocket client: polling only"))
    }

    @Test func recordsTheQuota() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        environment.timing.rateLimitWriteInterval = .milliseconds(10)
        environment.cloud.quota.withLockedValue { $0 = 10 }
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.log.contains("Rate limit almost reached, you only have 10 calls left today") })
        let file = environment.storage.appendingPathComponent(".daikin-rate-limit.json")
        #expect(await eventually { FileManager.default.fileExists(atPath: file.path) })
        let saved = try JSONValue(data: Data(contentsOf: file))
        #expect(saved["remainingDay"] == 10)
        #expect(saved["limitDay"] == 200)
        #expect(saved["mode"] == "developer_portal")
        let answer = try await environment.request("GET", "rate-limit")
        #expect(answer.json["success"] == true)
        #expect(answer.json["rateLimit"] == ["limitDay": 200, "remainingDay": 10])
        #expect(answer.json["mode"] == "developer_portal")
        #expect(answer.json["ageMs"]?.doubleValue != nil)
        // A low quota stretches polling to an hour.
        #expect(await environment.plugin!.session!.currentPollInterval == .seconds(3600))
    }

    @Test func pollsAndBacksOff() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        environment.timing.pollInterval = .milliseconds(80)
        environment.timing.forceUpdateDelay = .milliseconds(40)
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        let session = try #require(await environment.plugin?.session)
        let start = environment.cloud.gets.withLockedValue { $0 }
        #expect(await eventually { environment.cloud.gets.withLockedValue { $0 } >= start + 2 })
        // A change made in the Onecta app reaches HomeKit on the next poll.
        environment.cloud.devices.withLockedValue { devices in
            devices[0] = Fixture.json("dx4Airco", managementPoint: "climateControl") { $0["onOffMode"] = ["value": "off"] }
        }
        let dx4 = try #require(host.mainBridge.server.accessories.first { $0.id == dx4ID })
        #expect(await eventually { dx4.service(.heaterCooler)?.characteristic(.active).value == 0 })
        // Failures back off.
        environment.cloud.failure.withLockedValue { $0 = .text("Gateway", status: 502) }
        #expect(await eventually { await session.consecutiveFailures == 1 })
        #expect(await session.currentPollInterval == .milliseconds(160))
        #expect(await eventually { await session.consecutiveFailures == 0 })
        #expect(environment.log.contains("[API Syncing] Failed to update devices data: Bad Gateway (502)"))
        #expect(DaikinSession.pollInterval(configured: .seconds(900), webSocketConnected: false, consecutiveFailures: 10, remainingDay: nil) == .seconds(3600))
        #expect(DaikinSession.pollInterval(configured: .seconds(900), webSocketConnected: true, consecutiveFailures: 0, remainingDay: nil) == .seconds(3600))
        #expect(DaikinSession.pollInterval(configured: .seconds(7200), webSocketConnected: true, consecutiveFailures: 0, remainingDay: nil) == .seconds(7200))
        #expect(DaikinSession.pollInterval(configured: .seconds(900), webSocketConnected: false, consecutiveFailures: 1, remainingDay: nil) == .seconds(1800))
        #expect(DaikinSession.pollInterval(configured: .seconds(900), webSocketConnected: false, consecutiveFailures: 0, remainingDay: 0) == .seconds(3600))
        #expect(DaikinSession.pollInterval(configured: .seconds(900), webSocketConnected: false, consecutiveFailures: 0, remainingDay: 500) == .seconds(900))
    }

    @Test func aWriteForcesOneDebouncedPoll() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        environment.timing.pollInterval = .seconds(3600)
        environment.timing.forceUpdateDelay = .milliseconds(150)
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        let dx4 = try #require(host.mainBridge.server.accessories.first { $0.id == dx4ID })
        let before = environment.cloud.gets.withLockedValue { $0 }
        try await dx4.service(.heaterCooler)?.characteristic(.active).write(0)
        try await dx4.service(.heaterCooler)?.characteristic(.targetHeaterCoolerState).write(2)
        try await Task.sleep(for: .milliseconds(60))
        #expect(environment.cloud.gets.withLockedValue { $0 } == before)
        #expect(await eventually { environment.cloud.gets.withLockedValue { $0 } == before + 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(environment.cloud.gets.withLockedValue { $0 } == before + 1)
    }

    @Test func webSocketPushesAndStretchesPolling() async throws {
        let sockets = FakeSockets()
        let environment = DaikinEnvironment(sockets: sockets)
        environment.tokens = (.mobileApp, DaikinEnvironment.validToken)
        environment.timing.pollInterval = .milliseconds(100)
        environment.timing.webSocketSafetyPoll = .seconds(3600)
        let host = try await environment.start(["authMode": "mobile_app", "daikinEmail": "me@example.com", "daikinPassword": "right"])
        defer { Task { await host.stop() } }
        let session = try #require(await environment.plugin?.session)
        #expect(await eventually { await session.webSocketConnected })
        #expect(await session.currentPollInterval == .seconds(3600))
        let socket = try #require(sockets.last)
        socket.receive(text: #"{"event":"gateway:managementpoint:characteristic","embeddedId":"climateControl","gatewayDeviceId":"ca043bde-8db6-488b-a69e-f43949a24020","data":{"name":"onOffMode","value":"off"}}"#)
        let dx4 = try #require(host.mainBridge.server.accessories.first { $0.id == dx4ID })
        #expect(await eventually { dx4.service(.heaterCooler)?.characteristic(.active).value == 0 })
        // While pushes flow, a write does not poll.
        let gets = environment.cloud.gets.withLockedValue { $0 }
        try await dx4.service(.heaterCooler)?.characteristic(.active).write(1)
        #expect(await eventually { environment.log.contains("WebSocket connected, skipping forced update") })
        // A drop goes back to the configured interval, and the reconnection catches up.
        socket.drop()
        #expect(await eventually { sockets.count == 2 })
        #expect(await eventually { environment.cloud.gets.withLockedValue { $0 } > gets })
        #expect(environment.log.contains("[WebSocket] Connected - receiving real-time updates"))
    }

    // MARK: The page

    @Test func pageRoutes() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        let info = try await environment.request("GET", "server/info")
        #expect(info.json["primaryIp"] == "192.168.1.20")
        #expect(info.json["ipAddresses"] == ["192.168.1.20", "10.0.0.2"])
        let valid = try await environment.request("POST", "config/validate", body: ["clientId": "a", "clientSecret": "b", "callbackServerExternalAddress": "192.168.1.20", "callbackServerPort": "8582"])
        #expect(valid.json["valid"] == true)
        let invalid = try await environment.request("POST", "config/validate", body: ["clientId": "a", "callbackServerExternalAddress": "localhost"])
        #expect(invalid.json["errors"] == ["Client Secret is required for Developer Portal mode", "Callback address cannot be localhost. Use your external IP or domain."])
        #expect(try await environment.request("GET", "rate-limit").json["noData"] == true)
        #expect(try await environment.request("POST", "auth/test").json["message"] == "Not authenticated. Please authenticate first.")
        #expect(try await environment.request("GET", "devices/list").json["message"] == "Not authenticated. Please authenticate first.")
        #expect(try await environment.request("POST", "auth/revoke", body: [:]).json["message"] == "No tokens to revoke")
        #expect(try await environment.request("GET", "nope").status == 404)
        // Starting needs the credentials and refuses a loopback bind for a LAN address.
        #expect(try await environment.request("POST", "auth/start", body: ["clientId": "a"]).json["error"] == "Client ID and Client Secret are required")
        let loopback = try await environment.request("POST", "auth/start", body: [
            "clientId": "a", "clientSecret": "b", "callbackServerExternalAddress": "192.168.1.20", "oidcCallbackServerBindAddr": "127.0.0.1",
        ])
        #expect(loopback.status == 400)
        #expect(loopback.json["error"]?.stringValue?.contains("Daikin's redirect could never reach it") == true)
    }

    @Test func mobileLoginFromThePage() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(["authMode": "mobile_app", "daikinEmail": "me@example.com"])
        defer { Task { await host.stop() } }
        #expect(try await environment.request("POST", "auth/mobile-test", body: ["email": "me@example.com"]).json["message"] == "Email and password are required")
        let wrong = try await environment.request("POST", "auth/mobile-test", body: ["email": "me@example.com", "password": "wrong"])
        #expect(wrong.json["success"] == false)
        #expect(wrong.json["message"] == "Login failed (403042): Invalid LoginID")
        let right = try await environment.request("POST", "auth/mobile-test", body: ["email": "me@example.com", "password": "right"])
        #expect(right.json["success"] == true)
        #expect(right.json["deviceCount"] == 2)
        let status = try await environment.request("GET", "auth/status")
        #expect(status.json["authMode"] == "mobile_app")
        #expect(status.json["isExpired"] == false)
        let test = try await environment.request("POST", "auth/test")
        #expect(test.json["message"] == "Connection successful! Found 2 device(s).")
        // Revoking deletes both token files.
        #expect(try await environment.request("POST", "auth/revoke", body: [:]).json["success"] == true)
        #expect(TokenFile.load(environment.storage.appendingPathComponent(".daikin-mobile-tokenset")) == nil)
        #expect(try await environment.request("GET", "auth/status").json["authenticated"] == false)
    }

    @Test func developerPortalLoginThroughTheCallbackServer() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        let port = Int.random(in: 40000...60000)
        let started = try await environment.request("POST", "auth/start", body: [
            "clientId": "client", "clientSecret": "secret", "callbackServerExternalAddress": "127.0.0.1", "callbackServerPort": .string(String(port)),
            "oidcCallbackServerBindAddr": "127.0.0.1",
        ])
        #expect(started.json["callbackServerRunning"] == true)
        #expect(started.json["redirectUri"] == .string("https://127.0.0.1:\(port)"))
        let authURL = try #require(started.json["authUrl"]?.stringValue)
        let state = try #require(URLQuery.parameter("state", in: authURL))
        #expect(URLQuery.parameter("client_id", in: authURL) == "client")
        #expect(try await environment.request("GET", "auth/poll").json["pending"] == true)

        let browser = HTTPClient(tls: .any)
        // Not our state: refused, and the login carries on.
        let stranger = try await browser.send(HTTPRequest(url: URL(string: "https://127.0.0.1:\(port)/?code=x&state=other")!))
        #expect(stranger.status == 400)
        #expect(try await environment.request("GET", "auth/poll").json["pending"] == true)
        // Daikin's redirect.
        let redirect = try await browser.send(HTTPRequest(url: URL(string: "https://127.0.0.1:\(port)/?code=good-code&state=\(state)")!))
        #expect(redirect.status == 200)
        #expect(redirect.text.contains("Authentication successful!"))
        let poll = try await environment.request("GET", "auth/poll")
        #expect(poll.json["success"] == true)
        #expect(TokenFile.load(environment.storage.appendingPathComponent(".daikin-controller-cloud-tokenset"))?.access_token == "dev-access")
        // The instance connects without a restart.
        #expect(await eventually { host.mainBridge.server.accessories.count == 3 })
    }

    @Test func pastedCallbackURL() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        #expect(try await environment.request("POST", "auth/callback", body: ["callbackUrl": "https://127.0.0.1:8582/?code=good-code&state=s"]).json["error"]
            == "No pending authorization. Please start the auth flow again.")
        let port = Int.random(in: 40000...60000)
        let started = try await environment.request("POST", "auth/start", body: [
            "clientId": "client", "clientSecret": "secret", "callbackServerExternalAddress": "127.0.0.1", "callbackServerPort": .number(Double(port)),
        ])
        let state = try #require(URLQuery.parameter("state", in: started.json["authUrl"]?.stringValue ?? ""))
        #expect(try await environment.request("POST", "auth/callback", body: ["callbackUrl": .string("https://127.0.0.1:\(port)/?code=good-code&state=wrong")]).json["error"]
            == "Invalid or missing state parameter. Please paste the full callback URL or start again.")
        #expect(try await environment.request("POST", "auth/callback", body: ["callbackUrl": .string("https://127.0.0.1:\(port)/?code=bad&state=\(state)")]).json["error"]
            == "Token exchange failed: Authorization code exchange failed: invalid_grant - Bad code (HTTP 400)")
        let done = try await environment.request("POST", "auth/callback", body: ["callbackUrl": .string("https://127.0.0.1:\(port)/?code=good-code&state=\(state)")])
        #expect(done.json["success"] == true)
        #expect(try await environment.request("POST", "auth/stop-server", body: [:]).json["success"] == true)
    }

    /// Two requests with the pending state at once (a browser retry, the URL pasted as well): one exchange.
    @Test func theSameCallbackTwiceExchangesTheCodeOnce() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        let port = Int.random(in: 40000...60000)
        let started = try await environment.request("POST", "auth/start", body: [
            "clientId": "client", "clientSecret": "secret", "callbackServerExternalAddress": "127.0.0.1", "callbackServerPort": .number(Double(port)),
            "oidcCallbackServerBindAddr": "127.0.0.1",
        ])
        let state = try #require(URLQuery.parameter("state", in: started.json["authUrl"]?.stringValue ?? ""))
        let cloud = environment.cloud
        let release = Signal()
        let exchanges = NIOLockedValueBox(0)
        cloud.http.set { request, _ in
            if request.url == DeveloperPortalOAuth.tokenEndpoint {
                exchanges.withLockedValue { $0 += 1 }
                await release.wait()
            }
            return try await cloud.answer(request)
        }
        let url = JSONValue.string("https://127.0.0.1:\(port)/?code=good-code&state=\(state)")
        let pasted = Task { try await environment.request("POST", "auth/callback", body: ["callbackUrl": url]) }
        #expect(await eventually { exchanges.withLockedValue { $0 } == 1 })
        // The redirect arriving meanwhile is refused, without a second exchange.
        let redirect = await environment.plugin!.callbackRequest("/?code=good-code&state=\(state)")
        #expect(redirect.status == 400)
        let again = try await environment.request("POST", "auth/callback", body: ["callbackUrl": url])
        #expect(again.json["error"] == "No pending authorization. Please start the auth flow again.")
        release.fire()
        #expect(try await pasted.value.json["success"] == true)
        #expect(exchanges.withLockedValue { $0 } == 1)
    }

    /// A failed exchange keeps the login pending for a paste, unless the page cancelled it meanwhile.
    @Test func aCancelledLoginStaysCancelled() async throws {
        let environment = DaikinEnvironment()
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }
        let started = try await environment.request("POST", "auth/start", body: [
            "clientId": "client", "clientSecret": "secret", "callbackServerExternalAddress": "127.0.0.1",
            "callbackServerPort": .number(Double(Int.random(in: 40000...60000))), "oidcCallbackServerBindAddr": "127.0.0.1",
        ])
        let state = try #require(URLQuery.parameter("state", in: started.json["authUrl"]?.stringValue ?? ""))
        let cloud = environment.cloud
        let release = Signal()
        let exchanges = NIOLockedValueBox(0)
        cloud.http.set { request, _ in
            if request.url == DeveloperPortalOAuth.tokenEndpoint {
                exchanges.withLockedValue { $0 += 1 }
                await release.wait()
            }
            return try await cloud.answer(request)
        }
        let failing = Task { await environment.plugin!.callbackRequest("/?code=bad&state=\(state)") }
        #expect(await eventually { exchanges.withLockedValue { $0 } == 1 })
        #expect(try await environment.request("POST", "auth/stop-server", body: [:]).json["success"] == true)
        release.fire()
        _ = await failing.value
        #expect(await environment.plugin!.pendingAuth == nil)
    }

    @Test func callbackPorts() throws {
        #expect(try DaikinCloudPlugin.callbackPort(nil) == 8582)
        #expect(try DaikinCloudPlugin.callbackPort(8600) == 8600)
        #expect(try DaikinCloudPlugin.callbackPort("8600 ") == 8600)
        #expect(try DaikinCloudPlugin.callbackPort("8600abc") == 8600)
        #expect(try DaikinCloudPlugin.callbackPort("abc") == 8582)
        #expect(try DaikinCloudPlugin.callbackPort(0) == 8582)
        #expect(try DaikinCloudPlugin.callbackPort("½") == 8582)
        // A port no socket can have would trap in the bind: refused instead.
        #expect(throws: DaikinError("Callback Server Port must be between 1 and 65535")) { try DaikinCloudPlugin.callbackPort("99999") }
        #expect(throws: DaikinError.self) { try DaikinCloudPlugin.callbackPort("99999999999999999999999") }
    }

}
