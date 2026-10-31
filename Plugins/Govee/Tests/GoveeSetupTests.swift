import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftGovee

@Suite struct GoveeSetupTests {
    static let loginPath = "app2.govee.com/account/rest/account/v2/login"
    static let verificationPath = "app2.govee.com/account/rest/account/v1/verification"

    func context(_ host: PluginHost) throws -> PluginContext {
        try #require(host.context(platform: GoveePlugin.platform, name: GoveePlugin.name))
    }

    /// The email and password, then Govee's emailed code: a wrong password and a refused code are errors the person
    /// answers again; the login, the certificate and the password go to the vault, and the password leaves the block.
    @Test func signsInWithTheEmailedCode() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start([:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)

        guard case .ask(let first, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the sign-in"); return }
        #expect(first.fields.map(\.key) == ["username", "password"])
        #expect(first.fields[1].kind == .secret)

        environment.govee.answer(Self.loginPath, status: 400, ["message": "Incorrect password"])
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "user@example.com", "password": "wrong"]))
        }

        environment.govee.answer(Self.loginPath, ["status": 454, "message": "new device"])
        environment.govee.answer(Self.verificationPath, ["status": 200])
        let asked = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "user@example.com", "password": "pw"]))
        guard case .ask(let codePrompt, let state) = asked else { Issue.record("expected the code"); return }
        #expect(codePrompt.fields.map(\.key) == ["code"] && codePrompt.fields[0].kind == .code)
        #expect(environment.govee.requests(to: Self.verificationPath).count == 1)

        // Govee still answers 454 with a code: the code is wrong.
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "000000"], state: state))
        }

        environment.govee.answer(Self.loginPath, ["client": ["token": "token-2", "accountId": "acc", "topic": "account-topic"]])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "123456"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(environment.govee.requests(to: Self.loginPath).last?.body?["code"] == "123456")
        let login = try #require(outcome.credentials.flatMap { try? JSONDecoder().decode(StoredLogin.self, from: $0.encoded()) })
        #expect(login.username == "user@example.com" && login.password == "pw" && login.credentials?.token == "token-2" && login.iot?.isEmpty == false)
        #expect(outcome.settings == ["username": "user@example.com", "password": .null, "code": .null])

        // What the bridge then does: the vault's login is the account's, and a start uses it without logging in.
        try context(host).saveCredentials(try #require(outcome.credentials))
        #expect(await plugin.accountAuthorized() == true)
        let logins = environment.govee.requests(to: Self.loginPath).count
        let again = try await environment.start(["username": "user@example.com"])
        defer { Task { await again.stop() } }
        #expect(await environment.plugin?.started == true)
        #expect(environment.govee.requests(to: Self.loginPath).count == logins)
        #expect(environment.govee.requests(to: "app2.govee.com/device/rest/devices/v1/list").last?.headers.contains { $0 == ("Authorization", "Bearer token-2") } == true)
    }

    /// The password Setup kept signs in again when the kept token is refused.
    @Test func theVaultsPasswordRenewsARefusedToken() async throws {
        let environment = GoveeEnvironment()
        let setup = try environment.host(settings: [:])
        let stale = AccountCredentials(topic: "account-topic", token: "stale", accountId: "acc", endpoint: "aws.example", iotPass: "secret")
        try context(setup).saveCredentials(StoredLogin(username: "user@example.com", password: "kept-pw", credentials: stale, iot: legacyPKCS12))
        environment.govee.answer("app2.govee.com/device/rest/devices/v1/list", status: 401, [:])
        let host = try environment.host(settings: [:])
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.govee.requests(to: Self.loginPath).count == 1 })
        #expect(environment.govee.requests(to: Self.loginPath).first?.body?["password"] == "kept-pw")
    }

    /// The account's devices are set up; one found only on the LAN is not until it has Accessory Settings, which a
    /// device's Setup gives; `ignoreDevice` is an exclusion of the block's own.
    @Test func discoversTheAccountsAndTheLANsDevices() async throws {
        let environment = GoveeEnvironment()
        let host = try await environment.start(["username": "user@example.com", "password": "pw", "thermoDevices": [["deviceId": thermoID, "ignoreDevice": true]]])
        let plugin = try #require(environment.plugin)
        let found = try await plugin.discover()
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.deviceID, $0) })
        #expect(byID[lightID]?.isSetUp == true && byID[lightID]?.name == "Desk Light" && byID[lightID]?.address == "192.168.1.20")
        #expect(byID[thermoID]?.excludedBySettings == true && byID[thermoID]?.isSetUp == false)
        let lanOnly = "11:22:33:44:55:66:77:88"
        let lan = try #require(byID[lanOnly])
        #expect(!lan.isSetUp && lan.authorization == .none)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(lan))) else { Issue.record("expected done"); return }
        #expect(outcome.credentials == nil && outcome.settings["name"] == .string(lan.name))
        await host.stop()

        // The block the bridge then writes: the LAN device is published (a new environment: the fake LAN is closed).
        let next = GoveeEnvironment()
        let again = try await next.start([
            "username": "user@example.com", "password": "pw", "_accessories": [lanOnly: ["name": "Strip"], lightID: ["excluded": true]],
        ])
        defer { Task { await again.stop() } }
        #expect(again.accessory(lanOnly)?.name == "Strip")
        #expect(again.accessory(lightID) == nil)
        let rediscovered = try #require(await next.plugin?.discover())
        #expect(rediscovered.first { $0.deviceID == lanOnly }?.isSetUp == true)
        #expect(rediscovered.first { $0.deviceID == lightID }.map { !$0.isSetUp && !$0.excludedBySettings } == true)
    }
}
