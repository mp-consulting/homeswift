import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftEWeLink

/// Setup: the account's login, its password into the vault, and the account's devices with `ignoredDevices`.
@Suite(.timeLimit(.minutes(1)))
struct SetupTests {
    let environment = EWeLinkTestEnvironment()

    func context(_ host: PluginHost) throws -> PluginContext {
        try #require(host.context(platform: EWeLinkPlugin.platform, name: "eWeLink"))
    }

    /// The account, checked with a login before it is kept: the password goes in the vault and leaves the block, the
    /// session where the plugin keeps it.
    @Test func signsInToTheAccount() async throws {
        let host = try environment.host(settings: [:])
        try await host.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the account"); return }
        #expect(prompt.fields.map(\.key) == ["username", "password", "countryCode"] && prompt.fields[1].kind == .secret && prompt.fields[2].optional)
        // The country is picked from a list, each answering its calling code, each in the region eWeLink assigns it.
        let countries = prompt.fields[2].options
        #expect(prompt.fields[2].kind == .choice && countries.first { $0.country == "GB" }?.value == "+44" && countries.count == EWeLinkCloud.callingCodes.count)
        for (country, code) in EWeLinkCloud.callingCodes {
            #expect(EWeLinkCloud.Region.allCases.contains { $0.countryCodes.contains(code) }, "\(country): +\(code) has no region")
        }
        await #expect(throws: SetupError("The country calling code is a number such as +1 or +44")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "a@b.c", "password": "good", "countryCode": "UK"]))
        }
        // Refused, and refused again with the password read as base64.
        environment.cloud.update { $0.loginAnswers = [["error": 10001, "msg": "wrong"], ["error": 10001, "msg": "wrong"]] }
        await #expect(throws: SetupError("wrong [10001]")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "a@b.c", "password": "bad"]))
        }
        guard case .done(let outcome) = try await plugin.authorize(
            SetupRequest(target: .account, answers: ["username": "a@b.c", "password": "good", "countryCode": "44"])) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["password": "good"])
        #expect(outcome.settings == ["username": "a@b.c", "password": .null, "countryCode": "+44"])
        #expect(TokenStorage(context: try context(host)).load()?.accessToken == "access-token-1")
    }

    /// The vault's password is the one the plugin logs in with, over the block's.
    @Test func theVaultsPasswordIsPreferred() async throws {
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1)])
        defer { Task { await host.stop() } }
        #expect(environment.cloud.state.withLockedValue { $0.loginBodies }.last?.contains("\"password\":\"secret\"") == true)
        try context(host).saveCredentials(["password": "vault-pass"])
        await host.relaunch(platform: EWeLinkPlugin.platform, name: "eWeLink")
        await environment.plugin?.settle()
        #expect(environment.cloud.state.withLockedValue { $0.loginBodies }.last?.contains("\"password\":\"vault-pass\"") == true)
        #expect(await environment.plugin?.accountAuthorized() == true)
    }

    /// The account's devices and groups, by device id; one in `ignoredDevices` is excluded by its settings. An
    /// Excluded device gets no accessory.
    @Test func discoversTheAccountsDevices() async throws {
        let host = try await environment.start(
            devices: [device("1000aaaaaa", uiid: 1, name: "Lamp"), device("1000bbbbbb", uiid: 1, name: "Fan"), device("1000cccccc", uiid: 1, name: "Heater")],
            groups: [["id": "group-1", "name": "Downstairs", "params": ["switch": "off"]]],
            settings: ["ignoredDevices": ["1000bbbbbb"], "_accessories": ["1000cccccc": ["excluded": true]]])
        defer { Task { await host.stop() } }
        #expect(environment.accessory(host, "1000aaaaaa") != nil)
        #expect(environment.accessory(host, "1000bbbbbb") == nil)
        #expect(environment.accessory(host, "1000cccccc") == nil)

        let found = try await #require(environment.plugin).discover()
        #expect(found.map(\.deviceID) == ["1000aaaaaa", "1000bbbbbb", "1000cccccc", "group-1"])
        #expect(found.map(\.excludedBySettings) == [false, true, false, false])
        #expect(EWeLinkPlugin.deviceID(ofAccessory: "1000ccccccSW1") == "1000cccccc" && EWeLinkPlugin.deviceID(ofAccessory: "1000cccccc") == nil)
        #expect(found.allSatisfy { $0.isSetUp && $0.authorization == AuthorizationMethod.none })
        #expect(found.last?.name == "Downstairs" && found.last?.model == "Group")

        // A plugin made only for Setup logs in for the question.
        var block: [String: JSONValue] = ["platform": "eWeLink", "name": "Draft"]
        for (key, value) in EWeLinkTestEnvironment.account { block[key] = .string("\(value)") }
        let discovered = try await host.discover(platform: EWeLinkPlugin.platform, name: "Draft", block: .object(block)).devices
        #expect(discovered.count == 4)
    }
}
