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

    /// The app's route: its email and password, checked with a sign-in, are kept as settings (sealed); no keys asked.
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
        #expect(outcome.credentials == nil)
        #expect(outcome.settings == ["route": "app", "email": "me@example.com", "password": "good"])
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
        #expect(outcome.credentials == ["accessKey": "a", "secretKey": "s"])
        #expect(outcome.settings == ["route": "both", "email": "me@example.com", "password": "pw", "accessKey": .null, "secretKey": .null])
        await host.stop()
    }
}
