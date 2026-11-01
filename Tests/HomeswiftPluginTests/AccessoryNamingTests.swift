import Foundation
import Homeswift
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftPlugin

/// Names given in a block's `_accessories`: put on the accessories' Name and Configured Name without reloading the
/// plugin, their aids and iids kept, and the plugin's names back when they go.
@Suite(.timeLimit(.minutes(1)))
struct AccessoryNamingTests {
    let environment = TestEnvironment()

    func configuration(_ accessories: String?) throws -> HomeswiftConfiguration {
        let settings = accessories.map { #", "_accessories": \#($0)"# } ?? ""
        return try HomeswiftConfiguration.decode(Data(#"""
            { "bridge": { "port": 0 }, "platforms": [
              { "platform": "Recording", "name": "Lamps", "lamps": ["lamp-1", "lamp-2"]\#(settings) }
            ] }
            """#.utf8))
    }

    @Test func cleansNamesAndReadsDeviceIDs() throws {
        #expect(AccessoryNaming.cleaned("  Desk \n  Lamp ") == "Desk Lamp")
        #expect(AccessoryNaming.cleaned(" \t") == nil)
        #expect(AccessoryNaming.cleaned(String(repeating: "a", count: 80))?.count == 64)
        #expect(AccessoryNaming.deviceID(of: "ElgatoKeyLights:3C:6A:9D:12:34:56", platform: "ElgatoKeyLights") == "3C:6A:9D:12:34:56")
        #expect(AccessoryNaming.deviceID(of: "lamp", platform: "ElgatoKeyLights") == "lamp")

        // The names leave the plugin's JSON; its other settings stay in it.
        let block = try #require(try configuration(#"{ "lamp-1": { "name": " Desk ", "offset": 2 }, "lamp-2": { "name": "Shelf" } }"#).platforms.first)
        #expect(block.accessoryNames == ["lamp-1": "Desk", "lamp-2": "Shelf"])
        let json = try #require(try JSONSerialization.jsonObject(with: block.json) as? [String: Any])
        #expect((json["_accessories"] as? [String: [String: Int]]) == ["lamp-1": ["offset": 2]])
        #expect(throws: ConfigurationError.self) { try configuration(#"{ "lamp-1": "Desk" }"#) }
        #expect(throws: ConfigurationError.self) { try configuration(#"{ "lamp-1": { "name": 3 } }"#) }
    }

    @Test func renamesWithoutReloadingThePluginAndKeepsTheIids() async throws {
        let host = try PluginHost(configuration: try configuration(#"{ "lamp-1": { "name": "Desk" } }"#), registry: environment.registry,
                                  storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        let server = host.mainBridge.server
        let lamp = try #require(server.accessories.first { $0.id == "Recording:lamp-1" })
        let lightbulb = try #require(lamp[.lightbulb])
        // Added before the accessory reached the server: Configured Name has its iid from the start.
        #expect(lamp.name == "Desk")
        #expect(lightbulb[.name]?.value == .string("Desk"))
        #expect(lightbulb[.configuredName]?.value == .string("Desk"))
        #expect(host.pluginName(of: "Recording:lamp-1") == "lamp-1")
        let other = try #require(server.accessories.first { $0.id == "Recording:lamp-2" })
        #expect(other.name == "lamp-2" && other[.lightbulb]?[.configuredName] == nil)
        let iids = lamp.services.flatMap(\.characteristics).map(\.iid)

        let report = await host.apply(try configuration(#"{ "lamp-1": { "name": "Reading Lamp" }, "lamp-2": { "name": "Shelf" } }"#))
        #expect(report == PluginHost.ReloadReport())
        #expect(environment.createdPlugins.count == 1)
        #expect(lamp.name == "Reading Lamp" && lightbulb[.configuredName]?.value == .string("Reading Lamp"))
        #expect(lamp.services.flatMap(\.characteristics).map(\.iid) == iids)
        // lamp-2 gets a Configured Name now, on its running accessory: it goes on the server again, with its aid.
        let shelf = try #require(other[.lightbulb]?[.configuredName])
        #expect(other.name == "Shelf" && shelf.value == .string("Shelf"))
        #expect(shelf.iid > 0 && shelf.aid == other.aid)

        // No name: the plugin's come back; the Configured Name added stays, with the plugin's name.
        _ = await host.apply(try configuration(nil))
        #expect(lamp.name == "lamp-1" && lightbulb[.name]?.value == .string("lamp-1"))
        #expect(lightbulb[.configuredName]?.value == .string("lamp-1"))
        #expect(host.pluginName(of: "Recording:lamp-1") == nil)
        await host.stop()
    }

    /// A fresh accessory from the plugin (it reloaded, or a device came back) is renamed as it is added.
    @Test func renamesAccessoriesThePluginAddsAgain() async throws {
        let host = try PluginHost(configuration: try configuration(#"{ "lamp-3": { "name": "Hall" } }"#), registry: environment.registry,
                                  storageDirectory: environment.directory, options: environment.options)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.first)
        try await plugin.addLamp(id: "lamp-3")
        let hall = try #require(host.mainBridge.server.accessories.first { $0.id == "Recording:lamp-3" })
        #expect(hall.name == "Hall" && hall[.lightbulb]?[.configuredName]?.value == .string("Hall"))
        await host.stop()
    }

    /// A controller's write of Configured Name (the Home app's rename) reaches the host's handler; the runtime's own
    /// changes and a write of the same name do not.
    @Test func handsTheHomeAppsRenamesToTheHost() async throws {
        let host = try PluginHost(configuration: try configuration(#"{ "lamp-1": { "name": "Desk" } }"#), registry: environment.registry,
                                  storageDirectory: environment.directory, options: environment.options)
        let renames = NIOLockedValueBox<[String]>([])
        host.handleRenames { id, name in renames.withLockedValue { $0.append("\(id)=\(name)") } }
        try await host.start()
        let configuredName = try #require(host.mainBridge.server.accessories.first { $0.id == "Recording:lamp-1" }?[.lightbulb]?[.configuredName])
        try await configuredName.write(.string("Desk"))
        try await configuredName.write(.string("  Study  Lamp "))
        _ = await host.apply(try configuration(#"{ "lamp-1": { "name": "Bedside" } }"#))
        #expect(await eventually { renames.withLockedValue { $0 } == ["Recording:lamp-1=Study Lamp"] })
        #expect(configuredName.value == .string("Bedside"))
        await host.stop()
    }
}

/// A ceiling, not a wait: it returns as soon as the condition holds.
private func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
