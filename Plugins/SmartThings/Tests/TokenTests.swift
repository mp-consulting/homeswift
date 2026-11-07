import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftSmartThings

/// The sign-in's tokens (docs/clean-room/SmartThings.md, 3.5 to 3.10).
@Suite(.timeLimit(.minutes(1)))
struct TokenTests {
    /// The block's starting pair is expired: the plugin refreshes it, saves the new pair before it uses it, refreshes again
    /// with the rotated refresh token, and needs signing in once SmartThings refuses the chain.
    @Test func refreshRotatesTheTokensAndSavesThemBeforeUse() async throws {
        let environment = TestEnvironment(signedIn: false)
        let cloud = environment.cloud
        cloud.answer("POST", "/v1/oauth/token", ["access_token": "55555555-5555-4555-8555-555555555555", "refresh_token": "66666666-6666-4666-8666-666666666666",
                                                  "expires_in": 86399, "scope": "r:devices:* x:devices:*", "installed_app_id": "33333333-3333-4333-8333-333333333333"])
        cloud.answer("POST", "/v1/oauth/token", ["access_token": "77777777-7777-4777-8777-777777777777", "refresh_token": "88888888-8888-4888-8888-888888888888", "expires_in": 86399])
        cloud.answer("POST", "/v1/oauth/token", status: 400, ["error": "invalid_grant", "error_description": "Invalid refresh token"])
        // What the vault held when the new access token was first used.
        let heldAtFirstUse = NIOLockedValueBox<String?>(nil)
        cloud.onRequest { request in
            guard request.header("Authorization") == "Bearer 55555555-5555-4555-8555-555555555555", heldAtFirstUse.withLockedValue({ $0 }) == nil else { return }
            let held = environment.vaultTokens?.refresh_token ?? "none"
            heldAtFirstUse.withLockedValue { $0 = held }
        }
        var block = TestEnvironment.block
        block["oauth_access_token"] = "11111111-1111-4111-8111-111111111111"
        block["oauth_refresh_token"] = "22222222-2222-4222-8222-222222222222"
        block["oauth_expires_in"] = 0
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory(Fixture.lamp) != nil })

        let refresh = try #require(cloud.sent("POST", "/v1/oauth/token").first)
        #expect(refresh.form["grant_type"] == "refresh_token" && refresh.form["refresh_token"] == "22222222-2222-4222-8222-222222222222")
        #expect(refresh.form["client_id"] == "7a850484-0000-4000-8000-000000000001")
        #expect(refresh.authorization == "Basic " + Data("7a850484-0000-4000-8000-000000000001:3581f317-0000-4000-8000-000000000002".utf8).base64EncodedString())
        #expect(heldAtFirstUse.withLockedValue { $0 } == "66666666-6666-4666-8666-666666666666")
        #expect(cloud.sent("GET", "/v1/devices").allSatisfy { $0.authorization != "Bearer 11111111-1111-4111-8111-111111111111" })
        let stored = try #require(environment.vaultTokens)
        #expect(stored.installed_app_id == "33333333-3333-4333-8333-333333333333")
        #expect(stored.seeded_from_config_refresh_token_sha256 == StoredTokens.sha256("22222222-2222-4222-8222-222222222222"))
        #expect(stored.grantsSSE == false)

        // The second refresh sends the rotated refresh token.
        let plugin = try #require(environment.plugin)
        try await plugin.tokens.refresh()
        #expect(cloud.sent("POST", "/v1/oauth/token").last?.form["refresh_token"] == "66666666-6666-4666-8666-666666666666")
        #expect(environment.vaultTokens?.refresh_token == "88888888-8888-4888-8888-888888888888")

        // invalid_grant: the chain is dead, the account Needs Authorization.
        await #expect(throws: TokenStore.Failure.self) { try await plugin.tokens.refresh() }
        #expect(environment.context.accountRefusal != nil)
        #expect(await plugin.accountAuthorized() == false)
        // The accessories stay.
        #expect(host.accessory(Fixture.lamp) != nil)
    }

    @Test func aRefreshIsSharedByItsCallers() async throws {
        let calls = NIOLockedValueBox(0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-SmartThings-tokens-\(UUID().uuidString)")
        let file = SecretFile<StoredTokens>(vault: CredentialVault(storage: directory), entryName: "plugin.test.tokens", owner: "test")
        let store = TokenStore(file: file, refresh: { _ in
            calls.withLockedValue { $0 += 1 }
            try await Task.sleep(for: .milliseconds(20))
            return try #require(TokenResponse(["access_token": "new", "refresh_token": "next", "expires_in": 86399]))
        }, now: Date.init, logger: testLogger, onRefused: { _ in })
        try await store.seed(StoredTokens(accessToken: "old", refreshToken: "first", expiresIn: 60, now: Date()))
        // Expired (inside the 5-minute margin): every caller waits on one refresh.
        async let a = store.accessToken()
        async let b = store.accessToken()
        async let c = store.accessToken()
        let tokens = try await [a, b, c]
        #expect(tokens == ["new", "new", "new"])
        #expect(calls.withLockedValue { $0 } == 1)
        // A 401 on a token already replaced takes the new one without a request.
        #expect(try await store.refresh(replacing: "old").access_token == "new")
        #expect(calls.withLockedValue { $0 } == 1)
    }

    @Test func aPersonalAccessTokenIsUsedUntilRefused() async throws {
        let environment = TestEnvironment(signedIn: false)
        var block = TestEnvironment.block
        block.removeValue(forKey: "client_id")
        block.removeValue(forKey: "client_secret")
        block["AccessToken"] = "00000000-cccc-4000-8000-000000000005"
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        #expect(await eventually { host.accessory(Fixture.lamp) != nil })
        #expect(environment.cloud.sent("GET", "/v1/devices").first?.authorization == "Bearer 00000000-cccc-4000-8000-000000000005")
        #expect(environment.vaultTokens?.isPersonal == true)
        // A personal access token never opens the event stream.
        #expect(environment.cloud.sent("POST", "/v1/sse/subscriptions").isEmpty)
        // Its first 401 is a refusal: sign in with your own app.
        let plugin = try #require(environment.plugin)
        await #expect(throws: TokenStore.Failure.self) { try await plugin.tokens.refresh() }
        #expect(environment.context.accountRefusal != nil)
    }

    @Test func withoutTokensThePluginWaitsForSetup() async throws {
        let environment = TestEnvironment(signedIn: false)
        let host = try await environment.start(settings: ["name": "SmartThings"])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)
        #expect(try await plugin.discover().isEmpty)
        #expect(environment.cloud.sent.isEmpty)
    }

    /// Setup: the client and the sse choice, the authorize URL, the pasted address exchanged; the client to the vault.
    @Test func setupSignsInWithAPastedAddress() async throws {
        let environment = TestEnvironment(signedIn: false)
        environment.cloud.answer("POST", "/v1/oauth/token", Fixture.tokens)
        let host = try await environment.start(settings: ["name": "SmartThings"])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        guard case .ask(let first, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("no first step"); return }
        #expect(first.values["redirectURI"] == "https://192.0.2.10:8583/oauth/callback")
        let step = try await plugin.authorize(SetupRequest(target: .account, answers: [
            "client_id": "7a850484-0000-4000-8000-000000000001", "client_secret": "3581f317-0000-4000-8000-000000000002", "sse": "yes", "callbackServerPort": "48583",
        ]))
        guard case .ask(let prompt, let state) = step else { Issue.record("no sign-in step"); return }
        let url = try #require(prompt.url)
        #expect(url.hasPrefix("https://api.smartthings.com/v1/oauth/authorize?client_id=7a850484-0000-4000-8000-000000000001&response_type=code"))
        #expect(url.contains("scope=r%3Adevices%3A%2A%20x%3Adevices%3A%2A%20r%3Alocations%3A%2A%20r%3Ascenes%3A%2A%20x%3Ascenes%3A%2A%20sse"))
        let oauthState = try #require(state["oauthState"]?.stringValue)
        // A state not ours is refused.
        await #expect(throws: SetupError.self) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["callbackUrl": "https://httpbin.org/get?code=abc&state=nope"], state: state))
        }
        let done = try await plugin.authorize(SetupRequest(target: .account, answers: ["callbackUrl": "https://httpbin.org/get?code=abc&state=\(oauthState)"], state: state))
        guard case .done(let outcome) = done else { Issue.record("not done"); return }
        #expect(outcome.credentials?["client_id"] == "7a850484-0000-4000-8000-000000000001")
        #expect(outcome.settings["locationId"] == .string(Fixture.location))
        #expect(outcome.settings["client_secret"] == .null)
        let exchange = try #require(environment.cloud.sent("POST", "/v1/oauth/token").last)
        #expect(exchange.form["grant_type"] == "authorization_code" && exchange.form["code"] == "abc" && exchange.form["redirect_uri"] == "https://192.0.2.10:48583/oauth/callback")
        #expect(environment.vaultTokens?.refresh_token == "22222222-2222-4222-8222-222222222222")
        #expect(environment.vaultTokens?.grantsSSE == true)
    }
}
