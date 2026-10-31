import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftLGThinQ

/// Setup: the account's Browser Redirect (or Account Login), its refresh token into the vault, and the account's
/// appliances with the block's allow list.
@Suite(.timeLimit(.minutes(1)))
struct SetupTests {
    func context(_ host: PluginHost) throws -> PluginContext {
        try #require(host.context(platform: LGThinQPlugin.platform, name: "LG ThinQ"))
    }

    /// The region first when the block has none, then LG's page and the address it ended on; the token LG accepts goes in
    /// the vault and the block's `refresh_token` goes.
    @Test func signsInThroughLGsPage() async throws {
        let environment = LGTestEnvironment()
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)
        guard case .ask(let region, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the region"); return }
        #expect(region.fields.map(\.key) == ["country", "language"])
        await #expect(throws: SetupError("The country has two letters, such as US or FR")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["country": "France", "language": "fr-FR"]))
        }
        guard case .ask(let page, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: ["country": "fr", "language": "fr-FR"])) else {
            Issue.record("expected LG's page"); return
        }
        #expect(page.fields.map(\.key) == ["callbackUrl"] && page.fields.first?.kind == .url && page.fields.first?.optional == false)
        #expect(page.url.flatMap(URLComponents.init(string:))?.host == "us.m.lgaccount.com")
        #expect(state["region"] == ["country": "FR", "language": "fr-FR"])
        await #expect(throws: SetupError("The redirected URL is not valid: try again, or use an LG account.")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["callbackUrl": "https://x.test/login/iabClose?user_id=a"], state: state))
        }
        guard case .done(let outcome) = try await plugin.authorize(
            SetupRequest(target: .account, answers: ["callbackUrl": "https://x.test/login/iabClose?refresh_token=direct"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["refreshToken": "direct"])
        #expect(outcome.settings == ["country": "FR", "language": "fr-FR", "refresh_token": .null])
    }

    /// `auth_mode: account` signs in with the account's email and password.
    @Test func signsInWithTheAccount() async throws {
        let environment = LGTestEnvironment()
        environment.lg.override("lgemembers.com") { request in
            let url = request.url.absoluteString
            if url.contains("signInAct") {
                return request.bodyText.contains("userPw=\(Auth.sha512Hex("good"))")
                    ? FakeLG.json(["account": ["loginSessionID": "s", "userID": "u", "userIDType": "LGE"]])
                    : FakeLG.json(["error": ["code": "MS.001.02", "message": "Wrong password"]])
            }
            if url.contains("signInComplete") { return FakeLG.json(["code": "SUCCESS"]) }
            if url.contains("/oauth") { return FakeLG.json(["redirect_uri": "lgaccount.lgsmartthinq:/?code=c"]) }
            return FakeLG.json([:])
        }
        environment.lg.override("lgeapi.com/oauth") { _ in FakeLG.json(["access_token": "a", "refresh_token": "the-refresh-token", "expires_in": 3600]) }
        let host = try await environment.start(settings: ["auth_mode": "account", "country": "US", "language": "en-US"])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        guard case .ask(let prompt, let state) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the account"); return }
        #expect(prompt.fields.map(\.key) == ["username", "password"] && prompt.fields[1].kind == .secret)
        await #expect(throws: SetupError("Wrong password")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "me@example.com", "password": "bad"], state: state))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "me@example.com", "password": "good"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["refreshToken": "the-refresh-token"])
        #expect(outcome.settings == ["username": "me@example.com", "refresh_token": .null])
    }

    /// The vault's refresh token is the one the plugin signs in with, over the block's.
    @Test func theVaultsTokenIsPreferred() async throws {
        let environment = LGTestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await environment.plugin?.configuration.refresh_token == "refresh-1")
        try context(host).saveCredentials(["refreshToken": "vault-token"])
        await host.relaunch(platform: LGThinQPlugin.platform, name: "LG ThinQ")
        #expect(await environment.plugin?.configuration.refresh_token == "vault-token")
        #expect(await environment.plugin?.accountAuthorized() == true)
        #expect(await eventually { environment.lg.requests.contains { $0.bodyText.contains("vault-token") || $0.url.absoluteString.contains("vault-token") } })
    }

    /// The account's supported appliances; those the allow list leaves out, and ThinQ v1 ones without `thinq1`, are
    /// excluded by their settings. An Excluded appliance gets no accessory.
    @Test func discoversTheAccountsAppliances() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "online": true], model: [:])
        environment.lg.add(device: ["deviceId": .string(ovenID), "deviceType": 301, "alias": "Oven", "online": false], model: [:])
        environment.lg.add(device: ["deviceId": .string(hoodID), "deviceType": 304, "alias": "Old hood", "platformType": "thinq1"], model: [:])
        environment.lg.add(device: ["deviceId": .string(washerID), "deviceType": 203, "alias": "Second styler", "online": true], model: [:])
        environment.lg.add(device: ["deviceId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "deviceType": 701, "alias": "TV"], model: [:])
        var block = LGTestEnvironment.defaultSettings
        block["devices"] = [["id": stylerID], ["id": hoodID], ["id": washerID]]
        block["_accessories"] = [washerID: ["excluded": true]]
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        #expect(await environment.accessory(host, id: stylerID) != nil)
        #expect(host.bridges.allSatisfy { !$0.server.accessories.contains { $0.id == "LGThinQ:\(washerID)" } })

        let found = try await #require(environment.plugin).discover()
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Styler", "Oven", "Old hood", "Second styler"])
        #expect(byName["Styler"]?.deviceID == stylerID && byName["Styler"]?.excludedBySettings == false && byName["Styler"]?.authorization == AuthorizationMethod.none)
        #expect(byName["Oven"]?.excludedBySettings == true && byName["Old hood"]?.excludedBySettings == true)

        // A plugin made only for Setup signs in for the question.
        let discovered = try await host.discoverDevices(platform: LGThinQPlugin.platform, name: "Draft", block: [
            "platform": "LGThinQ", "name": "Draft", "refresh_token": "refresh-1", "country": "US", "language": "en-US",
        ])
        #expect(discovered.count == 4)
    }
}
