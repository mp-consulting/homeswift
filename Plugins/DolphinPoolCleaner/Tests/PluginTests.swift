import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftDolphinPoolCleaner

/// A host with one Dolphin platform block whose plugin talks to fake clouds: one per sign-in, as the
/// Homebridge plugin's integration tests have it.
final class DolphinTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-dolphin-tests-\(UUID().uuidString)")
    let server = FakeCloudServer()
    let log = LogRecorder()
    private let state = NIOLockedValueBox<(clouds: [FakeCloud], settings: [AccountSettings], plugins: [DolphinPoolCleanerPlugin])>(([], [], []))
    /// Makes the cloud of each sign-in; the index counts from 0.
    let nextCloud = NIOLockedValueBox<@Sendable (Int) -> FakeCloud>({ _ in FakeCloud() })
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])
    /// The plugin's delays; set before `start`.
    let timing = NIOLockedValueBox(DolphinTiming.fast)

    var clouds: [FakeCloud] { state.withLockedValue { $0.clouds } }
    var settings: [AccountSettings] { state.withLockedValue { $0.settings } }
    var plugin: DolphinPoolCleanerPlugin? { state.withLockedValue { $0.plugins.last } }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: DolphinPoolCleanerPlugin.platform, name: DolphinPoolCleanerPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(DolphinPoolCleanerPlugin.Configuration.self, from: json)
            var dependencies = DolphinPoolCleanerPlugin.Dependencies()
            dependencies.transport = self.server
            dependencies.mqtt = FakeBroker().factory
            dependencies.timing = self.timing.withLockedValue { $0 }
            dependencies.logger = self.log.logger
            dependencies.makeCloud = { settings, _ in
                self.state.withLockedValue { state in
                    let cloud = self.nextCloud.withLockedValue { $0 }(state.clouds.count)
                    state.clouds.append(cloud)
                    state.settings.append(settings)
                    return cloud
                }
            }
            let plugin = DolphinPoolCleanerPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.state.withLockedValue { $0.plugins.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: DolphinPoolCleanerPlugin.platform, name: "Dolphin Pool Cleaner", settings: settings)
        let options = PluginHost.Options(advertise: false, logger: log.logger) { name in
            self.storages.withLockedValue { storages in
                if let storage = storages[name] { return storage }
                let storage = MemoryStorage()
                storages[name] = storage
                return storage
            }
        }
        return try PluginHost(configuration: HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]), registry: registry, storageDirectory: directory, options: options)
    }

    /// Starts the host and waits for the first discovery.
    func start(settings: [String: Any] = validSettings) async throws -> PluginHost {
        let host = try host(settings: settings)
        try await host.start()
        await plugin?.settle()
        return host
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue = .null) async throws -> PluginWebResponse {
        let plugin = try #require(plugin)
        return try await plugin.handleWebRequest(PluginWebRequest(method: method, path: path, query: query, body: body, user: "admin"))
    }
}

var validSettings: [String: Any] { ["refreshToken": "refresh-token", "pollingInterval": 60] }
let robotID = "DolphinPoolCleaner:E3086OFG2M"

@Suite(.timeLimit(.minutes(1)))
struct ConfigurationTests {
    @Test func decodesAFullBlock() throws {
        let json = """
            {
              "platform": "DolphinPoolCleaner",
              "name": "Dolphin Pool Cleaner",
              "email": "owner@example.com",
              "password": "secret",
              "refreshToken": "eyJjdHkiOiJKV1Qi",
              "iotRegion": "eu-west-1",
              "pollingInterval": "120",
              "devices": [
                {
                  "serialNumber": "E3086OFG2M",
                  "name": "Pool Robot",
                  "deviceType": 62,
                  "robotImageUrl": "https://example.com/m400.png",
                  "cleaningMode": "regular",
                  "enableTemperature": "false",
                  "enableFilterStatus": true
                }
              ],
              "_bridge": { "username": "0E:1A:2B:3C:4D:5F" }
            }
            """
        let configuration = try JSONDecoder().decode(DolphinPoolCleanerPlugin.Configuration.self, from: Data(json.utf8))
        #expect(configuration.name == "Dolphin Pool Cleaner")
        #expect(configuration.email == "owner@example.com")
        #expect(configuration.password == "secret")
        #expect(configuration.refreshToken == "eyJjdHkiOiJKV1Qi")
        #expect(configuration.iotRegion == "eu-west-1")
        #expect(configuration.pollingInterval == 120)
        #expect(configuration.effectivePollingInterval == 120)
        let device = try #require(configuration.devices?.first)
        #expect(device.serialNumber == "E3086OFG2M")
        #expect(device.name == "Pool Robot")
        #expect(device.deviceType == 62)
        #expect(device.robotImageUrl == "https://example.com/m400.png")
        #expect(device.cleaningMode == "regular")
        #expect(device.enableTemperature == false)
        #expect(device.enableFilterStatus == true)
        #expect(configuration.hasCredentials)
    }

    @Test func minimalBlocks() throws {
        let empty = try JSONDecoder().decode(DolphinPoolCleanerPlugin.Configuration.self, from: Data(#"{"platform":"DolphinPoolCleaner"}"#.utf8))
        #expect(!empty.hasCredentials)
        #expect(empty.effectivePollingInterval == 60)
        let emailOnly = try JSONDecoder().decode(DolphinPoolCleanerPlugin.Configuration.self, from: Data(#"{"email":"a@b.c","pollingInterval":5,"devices":[{"serialNumber":12345678}]}"#.utf8))
        #expect(!emailOnly.hasCredentials)
        #expect(emailOnly.effectivePollingInterval == 30)
        #expect(emailOnly.devices?.first?.serialNumber == "12345678")
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(DolphinPoolCleanerPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/DolphinPoolCleaner DolphinPoolCleanerPlugin")
        let schema = try JSONValue(string: try #require(DolphinPoolCleanerPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "DolphinPoolCleaner")
        #expect(schema["schema"]?["properties"]?["pollingInterval"]?["minimum"] == 30)
    }

    @Test func webFilesAreCurrent() throws {
        let web = Self.root.appendingPathComponent("Web")
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) where !name.hasPrefix(".") {
            let file = try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)
            #expect(DolphinPoolCleanerPlugin.webFiles[name]?.body == file,
                "run: swift Scripts/embed-assets.swift web Plugins/DolphinPoolCleaner/Web Plugins/DolphinPoolCleaner/Sources/WebFiles.swift DolphinPoolCleanerPlugin (\(name))")
        }
        #expect(DolphinPoolCleanerPlugin.webFiles["index.html"]?.contentType == "text/html; charset=utf-8")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PluginTests {
    let environment = DolphinTestEnvironment()

    // MARK: Configuration

    @Test func refusesToStartWithoutAnAccount() async throws {
        let host = try await environment.start(settings: ["email": "owner@example.com"])
        #expect(environment.log.contains(.error, "Missing required configuration: refreshToken or email/password"))
        #expect(environment.clouds.isEmpty)
        // The page still answers, so it can sign in.
        let answer = try await environment.request("GET", "robots")
        #expect(answer.json["status"] == "notConfigured")
        await host.stop()
    }

    @Test func emailAndPasswordAreEnough() async throws {
        let host = try await environment.start(settings: ["email": "owner@example.com", "password": "secret"])
        #expect(environment.settings == [AccountSettings(email: "owner@example.com", password: "secret", refreshToken: nil, iotRegion: nil)])
        await host.stop()
    }

    @Test func pollingIntervalIsClampedToTheMinimum() async throws {
        let host = try await environment.start(settings: ["refreshToken": "refresh-token", "pollingInterval": 5])
        #expect(environment.log.contains(.debug, "Starting polling for Pool Bot every 30s"))
        await host.stop()
    }

    @Test func pollingIntervalStaysWithinATimersRange() async throws {
        let host = try await environment.start(settings: ["refreshToken": "refresh-token", "pollingInterval": 1e300])
        #expect(environment.log.contains(.debug, "Starting polling for Pool Bot every 2147483s"))
        await host.stop()
    }

    // MARK: Discovery

    @Test func registersTheRobotAndStartsIt() async throws {
        let host = try await environment.start()
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == robotID })
        #expect(accessory.name == "Pool Bot")
        #expect(accessory.service(.switch) != nil)
        #expect(accessory.service(.filterMaintenance) != nil)
        // The catalog has no temperature sensor for the M400/M600.
        #expect(accessory.service(.temperatureSensor) == nil)
        #expect(environment.clouds.first?.count("shadow E3086OFG2M") == 1)
        #expect(environment.log.contains(.info, "Adding new accessory: Pool Bot"))
        #expect(environment.log.contains(.info, "Found robot: Pool Bot (S/N: E3086OFG2M)"))
        #expect(environment.log.contains(.info, "Discovered 1 robot(s)"))
        let robots = try await environment.request("GET", "robots")
        #expect(robots.json["status"] == "ready")
        #expect(robots.json["robots"]?[0]?["serialNumber"] == "E3086OFG2M")
        #expect(robots.json["robots"]?[0]?["isCleaning"] == false)
        await host.stop()
    }

    @Test func configuredNameAndSensors() async throws {
        let host = try await environment.start(settings: [
            "refreshToken": "refresh-token",
            "devices": [["serialNumber": "E3086OFG2M", "name": "Backyard Pool", "enableFilterStatus": false]],
        ])
        #expect(environment.log.contains(.info, "Device created: Backyard Pool"))
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == robotID })
        #expect(accessory.service(.switch)?.characteristic(.configuredName).value == .string("Backyard Pool"))
        #expect(accessory.service(.filterMaintenance) == nil)
        await host.stop()
    }

    @Test func goneRobotsLeave() async throws {
        let host = try await environment.start()
        environment.nextCloud.withLockedValue { $0 = { _ in
            let cloud = FakeCloud()
            cloud.configure { $0.robots = [RobotInfo(serialNumber: "NEWROBOT1", name: "New Bot", model: "Dolphin S", deviceType: 60)] }
            return cloud
        } }
        await environment.plugin?.discoverDevices()
        #expect(host.mainBridge.server.accessories.contains { $0.id == "DolphinPoolCleaner:NEWROBOT1" })
        #expect(!host.mainBridge.server.accessories.contains { $0.id == robotID })
        // "Removing stale accessory: Pool Bot" goes to the context's logger (`PluginContext.removeAccessories`), which tests do not record.
        #expect(environment.clouds.first?.isDisconnected == true)
        await host.stop()
    }

    @Test func rediscoveryReplacesTheAccessory() async throws {
        let host = try await environment.start()
        let aid = try #require(host.mainBridge.server.accessories.first { $0.id == robotID }?.aid)
        await environment.plugin?.discoverDevices()
        #expect(environment.log.contains(.info, "Restoring existing accessory: Pool Bot"))
        #expect(host.mainBridge.server.accessories.first { $0.id == robotID }?.aid == aid)
        await host.stop()
    }

    // MARK: Retries

    @Test func retriesWithBackoffWhenTheCloudIsUnreachable() async throws {
        environment.nextCloud.withLockedValue { $0 = { index in
            let cloud = FakeCloud()
            if index == 0 { cloud.configure { $0.loginError = DolphinError.cognitoFailed("network down") } }
            return cloud
        } }
        let host = try await environment.start()
        #expect(environment.log.contains(.info, "Retrying discovery in"))
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == robotID } })
        #expect(environment.clouds.count == 2)
        #expect(environment.clouds[0].isDisconnected)
        await host.stop()
    }

    /// 150 ms, then 300 ms: the attempts' times are recorded and the gaps checked from below, which a slow runner cannot
    /// break (a sleep never ends early), where a check that no attempt came yet raced the next one.
    @Test func backsOffExponentially() async throws {
        let attempts = NIOLockedValueBox<[ContinuousClock.Instant]>([])
        environment.nextCloud.withLockedValue { $0 = { _ in
            attempts.withLockedValue { $0.append(.now) }
            let cloud = FakeCloud()
            cloud.configure { $0.loginError = DolphinError.cognitoFailed("network down") }
            return cloud
        } }
        let host = try await environment.start()
        #expect(await eventually { attempts.withLockedValue { $0.count } >= 3 })
        await host.stop()
        let times = attempts.withLockedValue { $0 }
        try #require(times.count >= 3)
        #expect(times[1] - times[0] >= .milliseconds(150))
        #expect(times[2] - times[1] >= .milliseconds(300))
    }

    @Test func rejectedCredentialsAreNotRetried() async throws {
        environment.nextCloud.withLockedValue { $0 = { _ in
            let cloud = FakeCloud()
            cloud.configure { $0.loginError = DolphinError.tokenExpired("Refresh token expired. Please re-authenticate through the plugin settings.") }
            return cloud
        } }
        let host = try await environment.start()
        try await Task.sleep(for: .milliseconds(400))
        #expect(environment.clouds.count == 1)
        #expect(environment.log.contains(.error, "Not retrying"))
        let robots = try await environment.request("GET", "robots")
        #expect(robots.json["status"] == "failed")
        #expect(robots.json["error"] == "Refresh token expired. Please re-authenticate through the plugin settings.")
        await host.stop()
    }

    // MARK: Shutdown

    @Test func stoppingClosesEverything() async throws {
        let host = try await environment.start(settings: ["refreshToken": "refresh-token"])
        let cloud = try #require(environment.clouds.first)
        await host.stop()
        #expect(cloud.isDisconnected)
        #expect(cloud.observerCount == 0)
        #expect(cloud.count("shadow") == 1)  // only the first read
    }

    /// A config change stops the plugin while it signs in: nothing may start after.
    @Test func stoppingDuringTheSignInStartsNothing() async throws {
        let cloud = FakeCloud()
        let gate = cloud.holdLogin()
        environment.nextCloud.withLockedValue { $0 = { _ in cloud } }
        let host = try environment.host(settings: validSettings)
        try await host.start()
        #expect(await eventually { gate.arrivals == 1 })
        await host.stop()
        gate.open()
        await environment.plugin?.settle()
        #expect(cloud.isDisconnected)
        #expect(cloud.count("shadow") == 0)
        #expect(cloud.observerCount == 0)
        #expect(await environment.plugin?.device(serialNumber: "E3086OFG2M") == nil)
        #expect(host.mainBridge.server.accessories.first { $0.id == robotID } == nil)
    }

    @Test func stoppingCancelsARetry() async throws {
        // A retry 400 ms away; one that a busy machine runs before the stop schedules the next further away.
        environment.timing.withLockedValue { $0.discoveryRetryBase = .milliseconds(400) }
        environment.nextCloud.withLockedValue { $0 = { _ in
            let cloud = FakeCloud()
            cloud.configure { $0.loginError = DolphinError.cognitoFailed("network down") }
            return cloud
        } }
        // Not `start()`, whose wait for the discovery can include the retry.
        let host = try environment.host(settings: validSettings)
        try await host.start()
        #expect(await eventually { environment.log.contains(.info, "Retrying discovery in") })
        await host.stop()
        // No attempt once stopped. A loaded runner can take the second before the stop returns, and the retry then
        // runs before it: what counts is that none comes after the plugin's own stop, which the host waits for at
        // most 10 s.
        #expect(await eventually { environment.log.contains(.debug, "Stopped") })
        let attempts = environment.clouds.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(environment.clouds.count == attempts)
    }

    // MARK: The switch end to end

    @Test func switchStartsTheRobot() async throws {
        let host = try await environment.start(settings: [
            "refreshToken": "refresh-token", "devices": [["serialNumber": "E3086OFG2M", "cleaningMode": "floor"]],
        ])
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == robotID })
        try await accessory.service(.switch)?.characteristic(.on).write(.bool(true))
        let cloud = try #require(environment.clouds.first)
        #expect(cloud.calls.contains("mode floor"))
        #expect(cloud.calls.contains("start E3086OFG2M"))
        await cloud.push(["version": 77, "state": ["reported": ["filterBagIndication": ["state": 90]]]])
        #expect(accessory.service(.filterMaintenance)?.characteristic(.filterChangeIndication).value == .int(1))
        await host.stop()
    }

    // MARK: Setup

    /// Setup: the email, then the code, with Cognito's session carried by the Setup rather than the plugin; the refresh
    /// token goes to the vault (the bridge saves the outcome's credentials), and the next launch signs in with it.
    @Test func setsUpTheAccountThroughSetup() async throws {
        environment.server.set("InitiateAuth", .init(body: ["ChallengeName": "CUSTOM_CHALLENGE", "Session": "cognito-session"]))
        environment.server.set("RespondToAuthChallenge", .init(body: ["AuthenticationResult": ["IdToken": "id-token", "RefreshToken": "new-refresh", "AccessToken": "access"]]))
        environment.server.set("/mobapi/serial-numbers/getRobotDetailsByRobotSN/", .init(body: [
            "Status": "1", "Data": ["PARTDES": "Dolphin M400", "originalUrlImage": "https://images.example.com/m400.png"],
        ]))
        environment.server.set("/m400.png", .init(body: "image", headers: [("Content-Type", "image/png")]))
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        guard case .ask(let first, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the email"); return }
        #expect(first.fields.map(\.key) == ["email"])
        guard case .ask(let code, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "owner@example.com"])) else {
            Issue.record("expected the code"); return
        }
        #expect(code.fields.map(\.key) == ["code"])
        #expect(code.message == "Enter the code sent to your email.")
        #expect(state["session"] == "cognito-session")
        let initiate = try #require(environment.server.requests(to: "InitiateAuth").first.flatMap(environment.server.json(of:)))
        #expect(initiate["AuthFlow"] == "CUSTOM_AUTH")
        #expect(initiate["AuthParameters"] == ["USERNAME": "owner@example.com"])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "123456"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["refreshToken": "new-refresh"])
        #expect(outcome.settings == ["email": "owner@example.com"])
        let respond = try #require(environment.server.requests(to: "RespondToAuthChallenge").first.flatMap(environment.server.json(of:)))
        #expect(respond["ChallengeName"] == "CUSTOM_CHALLENGE")
        #expect(respond["Session"] == "cognito-session")
        #expect(respond["ChallengeResponses"] == ["USERNAME": "owner@example.com", "ANSWER": "123456"])

        // The robot's picture, kept for the page.
        let image = try await environment.request("GET", "image", query: ["serial": "E3086OFG2M"])
        #expect(image.json["dataURL"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)

        let context = try #require(host.context(platform: DolphinPoolCleanerPlugin.platform, name: host.platforms.first?.name))
        try context.saveCredentials(outcome.credentials ?? .null)
        #expect(await environment.plugin?.storedRefreshToken == "new-refresh")
        await host.stop()
    }

    @Test func setupErrors() async throws {
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        func signIn(_ answers: [String: String] = ["email": "a@b.c"], state: JSONValue = .null) async throws -> SetupStep {
            try await plugin.authorize(SetupRequest(target: .account, answers: answers, state: state))
        }

        environment.server.cognitoError("InitiateAuth", type: "UserNotFoundException", message: "User does not exist.")
        await #expect(throws: SetupError("User not found. Please check your email address.")) { _ = try await signIn() }

        environment.server.set("InitiateAuth", .init(body: ["ChallengeName": "SMS_MFA", "Session": "s"]))
        guard case .ask(let prompt, let state) = try await signIn() else { Issue.record("expected the code"); return }
        #expect(prompt.message == "Enter the code sent to your phone.")
        await #expect(throws: SetupError("Enter the code")) { _ = try await signIn([:], state: state) }
        environment.server.cognitoError("RespondToAuthChallenge", type: "CodeMismatchException", message: "Invalid code.")
        await #expect(throws: SetupError("Invalid verification code")) { _ = try await signIn(["code": "1"], state: state) }
        let sms = try #require(environment.server.requests(to: "RespondToAuthChallenge").last.flatMap(environment.server.json(of:)))
        #expect(sms["ChallengeResponses"]?["SMS_MFA_CODE"] == "1")

        environment.server.set("InitiateAuth", .init(body: ["ChallengeName": "MFA_SETUP", "Session": "s"]))
        await #expect(throws: SetupError("Set up two-factor authentication in the MyDolphin app first")) { _ = try await signIn() }

        environment.server.set("InitiateAuth", .init(status: 503, body: [:]))
        await #expect(throws: SetupError("Cognito service error: HTTP 503")) { _ = try await signIn() }

        environment.server.set("InitiateAuth", .init(body: ["AuthenticationResult": ["IdToken": "id"]]))
        environment.server.set("/mobapi/user/authenticate-user/", .init(body: ["Status": "0", "Alert": "No robot on this account"]))
        await #expect(throws: SetupError("No robot on this account")) { _ = try await signIn() }

        environment.server.set("/mobapi/user/authenticate-user/", .init(status: 502, body: [:]))
        await #expect(throws: SetupError("Maytronics API error: HTTP 502")) { _ = try await signIn() }
        await host.stop()
    }

    /// The page reads; signing in is Setup's, so the Homebridge page's sign-in routes are gone.
    @Test func pageRoutes() async throws {
        let host = try await environment.start(settings: [:])
        #expect(try await environment.request("POST", "authenticate", body: ["email": "a@b.c"]).status == 404)
        #expect(try await environment.request("POST", "verify-otp", body: ["email": "a@b.c", "otpCode": "1"]).status == 404)
        #expect(try await environment.request("GET", "robots").json["status"] == "notConfigured")
        #expect(try await environment.request("GET", "image", query: ["serial": "NONE"]).json["dataURL"] == .null)
        #expect(try await environment.request("GET", "image").status == 400)
        #expect(try await environment.request("GET", "nothing").status == 404)
        await host.stop()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AssistantActionTests {
    let environment = DolphinTestEnvironment()

    @Test func actionsReachTheirRoutes() async throws {
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(DolphinPoolCleanerPlugin.assistantActions.map(\.name) == ["list_robots"])
        for action in DolphinPoolCleanerPlugin.assistantActions {
            #expect(action.access == .read)
            #expect(!action.confirm)
            let response = try await plugin.handleWebRequest(action.request(arguments: [:], user: "admin"))
            #expect(response.status == 200, "\(action.name)")
        }
        let action = try #require(DolphinPoolCleanerPlugin.assistantActions.first)
        let robots = try await plugin.handleWebRequest(action.request(arguments: [:], user: "admin"))
        #expect(robots.json["status"] == "ready")
        #expect(robots.json["robots"]?[0]?["serialNumber"] == "E3086OFG2M")
        await host.stop()
    }

    @Test func theRegistryCarriesThem() {
        var registry = PluginRegistry()
        registry.register(DolphinPoolCleanerPlugin.self)
        #expect(registry.entry(for: DolphinPoolCleanerPlugin.platform)?.assistantActions.map(\.name) == ["list_robots"])
        #expect(registry.entry(for: DolphinPoolCleanerPlugin.platform)?.assistantBackground == DolphinPoolCleanerPlugin.assistantBackground)
    }

    @Test func theBackgroundDescribesThePort() throws {
        let background = try #require(DolphinPoolCleanerPlugin.assistantBackground)
        #expect(!background.isEmpty)
        #expect(!background.contains("Homebridge"))
        // The messages it names are the ones the port gives.
        for message in ["Invalid email or password", "Verification code has expired. Please try again.",
                        "Set up two-factor authentication in the MyDolphin app first",
                        "Refresh token expired. Please re-authenticate through the plugin settings."] {
            #expect(background.contains(message))
        }
        #expect(SetupSignIn.errorMessages.allSatisfy { background.contains($0.message) })
    }
}
