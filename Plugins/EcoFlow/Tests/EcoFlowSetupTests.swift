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
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the keys"); return }
        #expect(prompt.fields.map(\.key) == ["accessKey", "secretKey", "region"])
        #expect(prompt.fields.prefix(2).allSatisfy { $0.kind == .secret })
        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .account, answers: ["accessKey": "wrong", "secretKey": "s"])) }
        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .account, answers: ["accessKey": "a", "secretKey": "s", "region": "asia"])) }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["accessKey": "new-access", "secretKey": "new-secret", "region": "EU"])) else {
            Issue.record("expected done"); return
        }
        #expect(tried.withLockedValue { $0 } == ["wrong -", "new-access eu"])
        #expect(outcome.credentials == ["accessKey": "new-access", "secretKey": "new-secret"])
        #expect(outcome.settings == ["accessKey": .null, "secretKey": .null, "region": "eu"])

        // Kept in the vault, they take the place of the block's.
        let context = try #require(host.context(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name))
        try context.saveCredentials(outcome.credentials ?? .null)
        let configuration = EcoFlowPlugin.withStoredKeys(try JSONDecoder().decode(EcoFlowPlugin.Configuration.self, from: Data(#"{"accessKey":"old-access","secretKey":"old-secret"}"#.utf8)), context)
        #expect(configuration.accessKey == "new-access" && configuration.secretKey == "new-secret")
        await host.stop()
    }
}
