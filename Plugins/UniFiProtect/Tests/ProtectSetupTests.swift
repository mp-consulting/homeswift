import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

@Suite struct ProtectSetupTests {
    static let console = UbiquitiDiscovery.Console(firmware: "4.1.13", ip: "192.168.1.9", mac: "aa:bb:cc:00:00:09", model: "UNVR", modelLong: "UniFi Network Video Recorder", name: "Shed NVR")
    static let configured = UbiquitiDiscovery.Console(firmware: "4.1.13", ip: "192.168.1.1", mac: "00:11:22:33:44:55", model: "UNVR", modelLong: "UniFi Network Video Recorder", name: "Home NVR")

    func context(_ host: PluginHost) throws -> PluginContext {
        try #require(host.context(platform: UniFiProtectPlugin.platform, name: UniFiProtectPlugin.name))
    }

    /// The running controller and its devices, one left out by `Disable.Device`, and a console on the network that is
    /// not set up, which needs a login.
    @Test func discoversControllersDevicesAndConsoles() async throws {
        let environment = ProtectTestEnvironment(discovered: [Self.configured, Self.console])
        let host = try await environment.start(options: ["Disable.Device.\(Fixtures.lightMAC)"])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(UniFiProtectPlugin.accountAuthorization == .none)
        let found = try await plugin.discover()
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.deviceID, $0) })
        let nvr = try #require(byID[Fixtures.nvrMAC])
        #expect(nvr.authorization == .accountLogin && nvr.isSetUp && nvr.address == "192.168.1.1")
        #expect(byID[Fixtures.sensorMAC]?.isSetUp == true && byID[Fixtures.sensorMAC]?.authorization == AuthorizationMethod.none)
        #expect(byID[Fixtures.lightMAC].map { !$0.isSetUp && $0.excludedBySettings } == true)
        let console = try #require(byID["AABBCC000009"])
        #expect(!console.isSetUp && console.authorization == .accountLogin && console.address == "192.168.1.9")
        #expect(!found.contains { $0.address == "192.168.1.1" && $0.deviceID != Fixtures.nvrMAC })
    }

    /// A camera lists what it can add or leave out as parts, as the device supports them; a part switched on Add
    /// accessories is that camera's option.
    @Test func aCamerasPartsFollowItsAccessorySettings() async throws {
        let environment = ProtectTestEnvironment()
        var settings = ProtectTestEnvironment.block()
        settings["_accessories"] = [Fixtures.cameraMAC: ["parts": ["Motion.OccupancySensor": true]]]
        let host = try environment.host(settings: settings)
        try await host.start()
        defer { Task { await host.stop() } }
        _ = await eventually { environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.sensorMAC)) != nil }
        let plugin = try #require(environment.plugin)
        let camera = try #require(try await plugin.discover().first { $0.deviceID == Fixtures.cameraMAC })
        let parts = Dictionary(uniqueKeysWithValues: camera.parts.map { ($0.id, $0) })
        #expect(parts["Motion.OccupancySensor"]?.included == true)
        #expect(parts["Motion.Switch"]?.included == false && parts["Motion.Switch"]?.name == "Motion detection switch")
        #expect(UniFiProtectPlugin.partChoices(try context(host)) == ["Enable.Motion.OccupancySensor.\(Fixtures.cameraMAC)"])
    }

    /// A console's login: asked, refused with an error the person answers again, then kept for the NVR's MAC with its
    /// address.
    @Test func signsInToAConsole() async throws {
        let environment = ProtectTestEnvironment()
        let host = try environment.host(settings: [:])
        try await host.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let console = DiscoveredDevice(deviceID: "address:192.168.1.1", name: "Home NVR", address: "192.168.1.1", authorization: .accountLogin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(console))) else { Issue.record("expected the login"); return }
        #expect(prompt.fields.map(\.key) == ["username", "password"] && prompt.fields[1].kind == .secret)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .device(console), answers: ["username": "homeswift", "password": "wrong"]))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(console), answers: ["username": "homeswift", "password": "secret"])) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.deviceID == Fixtures.nvrMAC)
        #expect(outcome.credentials == ["username": "homeswift", "password": "secret"])
        #expect(outcome.settings == ["address": "192.168.1.1"])
    }

    /// What the bridge writes once a controller is set up runs it, without `controllers`; an Excluded device stays out,
    /// and a login Setup kept replaces the block's for the same address.
    @Test func runsTheControllersSetUpThroughSetup() async throws {
        let environment = ProtectTestEnvironment()
        let host = try environment.host(settings: [
            "_accessories": [Fixtures.nvrMAC: ["address": "192.168.1.1"], Fixtures.lightMAC: ["excluded": true]],
        ])
        try context(host).saveCredentials(["username": "homeswift", "password": "secret"], for: Fixtures.nvrMAC)
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.sensorMAC)) != nil })
        #expect(environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.lightMAC)) == nil)

        var block = ProtectTestEnvironment.block()
        block["_accessories"] = [Fixtures.nvrMAC: ["address": "192.168.1.1"]]
        let other = try environment.host(settings: block)
        try context(other).saveCredentials(["username": "homeswift", "password": "kept"], for: Fixtures.nvrMAC)
        let configuration = try JSONDecoder().decode(UniFiProtectPlugin.Configuration.self, from: JSONSerialization.data(withJSONObject: block))
        let plugin = UniFiProtectPlugin(configuration: configuration, context: try context(other))
        let entries = await plugin.controllerEntries()
        #expect(entries.count == 1 && entries.first?.password == "kept" && entries.first?.mqttUrl == "mqtt://broker.local")
    }
}
