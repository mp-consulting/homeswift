import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftDysonPureCool

/// Setup: the account's sign-in, its devices' credentials from the cloud into the vault, and the devices set up that way
/// beside the block's `devices`.
@Suite(.timeLimit(.minutes(1)))
struct SetupTests {
    func context(_ host: PluginHost) throws -> PluginContext {
        try #require(host.context(platform: DysonPureCoolPlugin.platform, name: "Dyson"))
    }

    /// The email and the country, then the password with the emailed code: the challenge is in the Setup's state, the
    /// password never is; the token is the account's credential.
    @Test func signsInToTheAccount() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        guard case .ask(let first, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the email"); return }
        #expect(first.fields.map(\.key) == ["email", "countryCode"] && first.fields[1].optional)
        await #expect(throws: SetupError("A valid email address is required")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "bad"]))
        }
        guard case .ask(let second, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "user@example.com", "countryCode": "gb"])) else {
            Issue.record("expected the code"); return
        }
        #expect(second.fields.map(\.key) == ["password", "code"] && second.fields[0].kind == .secret)
        #expect(state == ["email": "user@example.com", "countryCode": "GB", "challengeId": "challenge-1"])
        #expect(environment.cloud.requests.last?.url.query == "country=GB&culture=en-GB")
        // A mistyped code: the Setup stays where it was.
        await #expect(throws: SetupError("Invalid verification code")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["password": "secret", "code": "000000"], state: state))
        }
        await #expect(throws: SetupError("Verification code must be 6 digits")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["password": "secret", "code": "12"], state: state))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["password": "secret", "code": "123456"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["token": "token-1"])
        #expect(outcome.settings == ["countryCode": "GB"])
    }

    /// With the account's token, the account's supported devices are found, and setting one up reads its credential.
    /// A token Dyson turns down makes the device ask for the sign-in.
    @Test func setsUpTheAccountsDevices() async throws {
        let environment = DysonTestEnvironment()
        let credentials = try DysonCloud.encrypt(apPasswordHash: "local-hash")
        environment.cloud.set(manifest: [
            ["serialNumber": .string(serial), "name": "Living Room", "type": "438", "connectedConfiguration": ["mqtt": ["localBrokerCredentials": .string(credentials)]]],
            ["serialNumber": "UNKNOWN-1", "name": "Something", "type": "999"],
        ])
        let host = try await environment.start(settings: [:])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(try await plugin.discover().isEmpty)
        try context(host).saveCredentials(["token": "token-1"])
        let found = try await plugin.discover()
        #expect(found == [DiscoveredDevice(deviceID: serial, name: "Living Room", model: DeviceCatalog.modelName("438"), authorization: .accountLogin)])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(found[0]))) else { Issue.record("expected done"); return }
        #expect(outcome.credentials == ["localCredentials": "local-hash"])
        #expect(outcome.settings == ["productType": "438", "name": "Living Room"])
        await #expect(throws: SetupError("The Dyson account has no device with the serial number NOPE")) {
            _ = try await plugin.authorize(SetupRequest(target: .device(DiscoveredDevice(deviceID: "NOPE", name: "Nope", authorization: .accountLogin))))
        }

        environment.cloud.expire(token: "token-1")
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(found[0]))) else { Issue.record("expected the sign-in"); return }
        #expect(prompt.fields.map(\.key) == ["email", "countryCode"])
    }

    /// A device with Accessory Settings and a credential in the vault runs like one of `devices`, under its serial.
    @Test func runsADeviceSetUpThroughSetup() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: ["_accessories": [serial: ["productType": "438", "ipAddress": "192.168.1.50", "name": "Bedroom"]]])
        defer { Task { await host.stop() } }
        // No credential yet: nothing to run.
        #expect(host.mainBridge.server.accessories.first { $0.id == accessoryID } == nil)
        try context(host).saveCredentials(["localCredentials": "vault-secret"], for: serial)
        await host.relaunch(platform: DysonPureCoolPlugin.platform, name: "Dyson")
        await environment.plugin?.settle()
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(accessory.name == "Bedroom")
        #expect(environment.dyson.connects.last?.password == "vault-secret")
        let found = try await #require(environment.plugin).discover()
        #expect(found.map(\.deviceID) == [serial] && found.first?.isSetUp == true && found.first?.address == "192.168.1.50")
    }

    /// A device of `devices` takes the vault's credential over its `localCredentials`.
    @Test func theVaultsCredentialIsPreferredOverTheBlocks() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: ["devices": [deviceBlock()]])
        defer { Task { await host.stop() } }
        #expect(environment.dyson.connects.last?.password == "secret")
        try context(host).saveCredentials(["localCredentials": "vault-secret"], for: serial)
        await host.relaunch(platform: DysonPureCoolPlugin.platform, name: "Dyson")
        await environment.plugin?.settle()
        #expect(environment.dyson.connects.last?.password == "vault-secret")
    }

    /// An Excluded device is never connected.
    @Test func anExcludedDeviceIsLeftAlone() async throws {
        let environment = DysonTestEnvironment()
        let host = try await environment.start(settings: ["devices": [deviceBlock()], "_accessories": [serial: ["excluded": true]]])
        defer { Task { await host.stop() } }
        #expect(host.mainBridge.server.accessories.first { $0.id == accessoryID } == nil)
        #expect(environment.dyson.connects.isEmpty)
    }
}
