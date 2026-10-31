import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiAccess

@Suite struct AccessSetupTests {
    let environment = AccessTestEnvironment()
    let controllerMAC = "001122334455"

    func context(_ host: PluginHost) throws -> PluginContext {
        try #require(host.context(platform: UniFiAccessPlugin.platform, name: UniFiAccessPlugin.name))
    }

    /// The running controller and its hubs, set up or left out by `Disable.Device`, and a console on the network that
    /// is not, which needs a login.
    @Test func discoversControllersHubsAndConsoles() async throws {
        environment.discovered = [
            DiscoveredConsole(ip: "10.0.0.1", mac: "00:11:22:33:44:55", name: "UDM"), DiscoveredConsole(ip: "10.0.0.9", mac: "aa:bb:cc:00:00:09", name: "UDM SE", modelLong: "UniFi Dream Machine SE"),
        ]
        let host = try await environment.start(devices: [uah(), ugt()], options: ["Disable.Device.112233445566"], expecting: 1)
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(UniFiAccessPlugin.accountAuthorization == .none)
        let found = try await plugin.discover()
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.deviceID, $0) })
        let controller = try #require(byID[controllerMAC])
        #expect(controller.authorization == .accountLogin && controller.isSetUp && controller.address == "10.0.0.1")
        #expect(byID["AABBCCDDEEFF"]?.isSetUp == true && byID["AABBCCDDEEFF"]?.authorization == AuthorizationMethod.none)
        #expect(byID["112233445566"].map { !$0.isSetUp && $0.excludedBySettings } == true)
        let console = try #require(byID["AABBCC000009"])
        #expect(!console.isSetUp && console.authorization == .accountLogin && console.address == "10.0.0.9" && console.model == "UniFi Dream Machine SE")
        #expect(found.count == 4)
    }

    /// A console's login: asked, refused with an error the person answers again, then kept for the controller's MAC with
    /// its address.
    @Test func signsInToAConsole() async throws {
        let host = try environment.host(settings: [:])
        try await host.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let console = DiscoveredDevice(deviceID: "address:10.0.0.1", name: "UDM", address: "10.0.0.1", authorization: .accountLogin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(console))) else { Issue.record("expected the login"); return }
        #expect(prompt.fields.map(\.key) == ["username", "password"] && prompt.fields[1].kind == .secret)

        environment.controller.override("/api/auth/login") { _ in HTTPResponse(status: 401, body: Data("{}".utf8)) }
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .device(console), answers: ["username": "homeswift", "password": "wrong"]))
        }
        environment.controller.removeOverride("/api/auth/login")
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(console), answers: ["username": "homeswift", "password": "secret"])) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.deviceID == controllerMAC)
        #expect(outcome.credentials == ["username": "homeswift", "password": "secret"])
        #expect(outcome.settings == ["address": "10.0.0.1"])
        // A hub needs nothing.
        guard case .done(let hub) = try await plugin.authorize(SetupRequest(target: .device(DiscoveredDevice(deviceID: "AABBCCDDEEFF", name: "Hub")))) else {
            Issue.record("expected done"); return
        }
        #expect(hub.credentials == nil && hub.settings.isEmpty)
    }

    /// What the bridge writes once a controller is set up runs it, without `controllers`; an Excluded hub stays out, and
    /// a login Setup kept replaces the block's for the same address.
    @Test func runsTheControllersSetUpThroughSetup() async throws {
        environment.controller.setDevices([uah(), ugt()])
        let host = try environment.host(settings: ["_accessories": [controllerMAC: ["address": "10.0.0.1"], "AABBCCDDEEFF": ["excluded": true]]])
        try context(host).saveCredentials(["username": "homeswift", "password": "kept"], for: controllerMAC)
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { accessory(host, gateID) != nil })
        #expect(accessory(host, hubID) == nil)
        #expect(environment.controller.requests(matching: "/api/auth/login").first?.body.contains("kept") == true)

        let block = try environment.host(settings: ["_accessories": [controllerMAC: ["address": "10.0.0.1"]]])
        let legacy = UniFiAccessPlugin.Configuration(controllers: [.init(address: "10.0.0.1", username: "homeswift", password: "secret", name: "Office")])
        let plugin = UniFiAccessPlugin(configuration: legacy, context: try context(block), dependencies: environment.dependencies)
        let entries = await plugin.controllerEntries()
        #expect(entries.count == 1 && entries.first?.password == "kept" && entries.first?.name == "Office")
    }
}
