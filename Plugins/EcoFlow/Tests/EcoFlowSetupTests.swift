import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftEcoFlow

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowSetupTests {
    struct Checked: EcoFlowAPI {
        let refuse: Bool
        func devices() async throws -> [EcoFlowDevice] {
            if refuse { throw URLError(.userAuthenticationRequired) }
            return [EcoFlowDevice(id: "BK11", name: "STREAM Ultra", online: true)]
        }
        func schemaChanges() async -> [String] { [] }
    }

    /// The keys are asked for, refused keys are asked again, and kept ones move out of the block into the vault.
    @Test func checksTheKeysBeforeKeepingThem() async throws {
        let environment = TestEnvironment()
        let tried = NIOLockedValueBox<[String]>([])
        let host = try await environment.start(settings: ["accessKey": "old-access", "secretKey": "old-secret"]) { access, _, region in
            tried.withLockedValue { $0.append("\(access) \(region ?? "-")") }
            return Checked(refuse: access == "wrong")
        }
        let plugin = try #require(environment.plugin)
        guard case .ask(let method, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the route"); return }
        #expect(method.fields.first?.options.map(\.value) == ["both", "developer", "app"] && method.fields.first?.value == "both")
        guard case .ask(let prompt, let chosen) = try await plugin.authorize(SetupRequest(target: .account, answers: ["route": "developer"])) else {
            Issue.record("expected the keys"); return
        }
        #expect(prompt.fields.map(\.key) == ["accessKey", "secretKey", "region"])
        #expect(prompt.fields.prefix(2).allSatisfy { $0.kind == .secret } && prompt.fields[2].kind == .choice)
        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .account, answers: ["accessKey": "wrong", "secretKey": "s"], state: chosen)) }
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["accessKey": "a", "secretKey": "s", "region": "asia"], state: chosen))
        }
        guard case .done(let outcome) = try await plugin.authorize(
            SetupRequest(target: .account, answers: ["accessKey": "new-access", "secretKey": "new-secret", "region": "EU"], state: chosen)) else {
            Issue.record("expected done"); return
        }
        #expect(tried.withLockedValue { $0 } == ["wrong -", "new-access eu"])
        #expect(outcome.credentials == ["accessKey": "new-access", "secretKey": "new-secret"])
        #expect(outcome.settings == ["route": "developer", "accessKey": .null, "secretKey": .null, "region": "eu"])

        // Kept in the vault, they take the place of the block's.
        let context = try #require(host.context(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name))
        try context.saveCredentials(outcome.credentials ?? .null)
        let configuration = EcoFlowPlugin.withStoredKeys(try JSONDecoder().decode(EcoFlowPlugin.Configuration.self, from: Data(#"{"accessKey":"old-access","secretKey":"old-secret"}"#.utf8)), context)
        #expect(configuration.accessKey == "new-access" && configuration.secretKey == "new-secret")
        await host.stop()
    }

    /// The app's route: its email and password, checked with a sign-in, the email kept as a setting and the password in
    /// the vault; no keys asked.
    @Test func checksTheAppsSignInBeforeKeepingIt() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: ["route": "app"], appSignIn: { _, password in
            guard password == "good" else { throw URLError(.userAuthenticationRequired) }
        })
        let plugin = try #require(environment.plugin)
        guard case .ask(let method, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the route"); return }
        #expect(method.fields.first?.value == "app")
        guard case .ask(let prompt, let chosen) = try await plugin.authorize(SetupRequest(target: .account, answers: ["route": "app"])) else {
            Issue.record("expected the app"); return
        }
        #expect(prompt.fields.map(\.key) == ["email", "password"] && prompt.fields[1].kind == .secret)
        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "me@example.com", "password": "bad"], state: chosen)) }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "me@example.com", "password": "good"], state: chosen)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["password": "good"])
        #expect(outcome.settings == ["route": "app", "email": "me@example.com", "password": .null])
        await host.stop()
    }

    /// Both routes: the keys, then the app's sign-in, each checked; the keys wait in the state between the two.
    @Test func bothRoutesAskTheKeysThenTheApp() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(developerAPI: { _, _, _ in Checked(refuse: false) }, appSignIn: { _, _ in })
        let plugin = try #require(environment.plugin)
        guard case .ask(_, let keysState) = try await plugin.authorize(SetupRequest(target: .account, answers: ["route": "both"])) else { Issue.record("expected the keys"); return }
        guard case .ask(let app, let appState) = try await plugin.authorize(SetupRequest(target: .account, answers: ["accessKey": "a", "secretKey": "s"], state: keysState)) else {
            Issue.record("expected the app"); return
        }
        #expect(app.fields.map(\.key) == ["email", "password"])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "me@example.com", "password": "pw"], state: appState)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["accessKey": "a", "secretKey": "s", "password": "pw"])
        #expect(outcome.settings == ["route": "both", "email": "me@example.com", "password": .null, "accessKey": .null, "secretKey": .null])
        await host.stop()
    }

    /// The block's keys and password move into the vault once the block is written without them, the vault's own
    /// winning; `devices` become each device's Name. A pasted block still runs with its own.
    @Test func canonicalSettingsMovesTheSecretsAndTheNames() async throws {
        let environment = TestEnvironment()
        let settings: [String: Any] = [
            "route": "both", "email": "me@example.com", "password": "pw", "accessKey": "a", "secretKey": "s",
            "devices": [["id": "BK11", "name": "Garage"], ["id": "R651"]],
        ]
        let host = try await environment.start(settings: settings, developerAPI: { _, _, _ in Checked(refuse: false) }, appSignIn: { _, _ in })
        let block = try JSONValue(any: settings.merging(["platform": "EcoFlow", "name": "EcoFlow"]) { $1 })
        let (canonical, whenWritten) = await host.canonicalSettings(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name, block: block)
        #expect(canonical == (try JSONValue(any: [
            "platform": "EcoFlow", "name": "EcoFlow", "route": "both", "email": "me@example.com",
            "_accessories": ["BK11": ["name": "Garage"]],
        ] as [String: Any])))
        let context = try #require(host.context(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name))
        #expect(context.credentials() == nil)
        try await whenWritten.run()
        #expect(context.credentials(as: EcoFlowPlugin.AccountCredentials.self) == .init(accessKey: "a", secretKey: "s", password: "pw"))
        let restored = EcoFlowPlugin.withStoredKeys(try JSONDecoder().decode(EcoFlowPlugin.Configuration.self, from: Data(#"{"email":"me@example.com"}"#.utf8)), context)
        #expect(restored.password == "pw" && restored.accessKey == "a" && restored.secretKey == "s")
        // Without the vault, the block keeps them.
        let kept = EcoFlowPlugin.canonical(block, vaultHasKeys: false, vaultHasPassword: false)
        #expect(kept["password"] == "pw" && kept["accessKey"] == "a")
        await host.stop()
    }

    /// Each device is of its model's Device Kind.
    @Test func devicesHaveTheirKinds() async throws {
        let environment = TestEnvironment()
        await environment.api.add(EcoFlowDevice(id: "R651ZEB5XF000000", name: "RIVER 3", online: true, model: EcoFlowModel.model(serial: "R651ZEB5XF000000")))
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { (try? await plugin.discover().count) ?? 0 >= 1 })
        let devices = try await plugin.discover()
        #expect(devices.first { $0.deviceID == "R651ZEB5XF000000" }?.kind == "portable")
        #expect(await plugin.deviceKind(of: "R651ZEB5XF000000") == "portable")
        #expect(await plugin.deviceKind(of: "BK11ZEB5XF000000") == "stream")
        await host.stop()
    }

    /// The schema keeps no secret and no list of devices.
    @Test func theSchemaDeclaresNoSecrets() throws {
        let schema = try JSONValue(string: try #require(EcoFlowPlugin.configurationSchemaJSON))
        for key in ["password", "accessKey", "secretKey", "devices"] { #expect(schema["schema"]?["properties"]?[key] == nil, "\(key)") }
    }
}
