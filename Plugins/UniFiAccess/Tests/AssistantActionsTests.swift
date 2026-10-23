import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftUniFiAccess

/// Every Assistant action reaches its route of `handleWebRequest` with the arguments a model would pass.
@Suite(.timeLimit(.minutes(1)))
struct AssistantActionsTests {
    let environment = AccessTestEnvironment()

    func call(_ plugin: UniFiAccessPlugin, _ name: String, _ arguments: JSONValue = [:]) async throws -> PluginWebResponse {
        let action = try #require(UniFiAccessPlugin.assistantActions.first { $0.name == name })
        return try await plugin.handleWebRequest(action.request(arguments: arguments, user: "admin"))
    }

    @Test func actionsReachTheirRoutes() async throws {
        environment.discovered = [DiscoveredConsole(ip: "10.0.0.1", mac: "aa:bb:cc:00:00:01", name: "udm", model: "UDMP")]
        let host = try await environment.start(devices: [uah(), ugt(), ultra()], doors: AccessHubTests.gateDoors)
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(Set(UniFiAccessPlugin.assistantActions.map(\.name)) == ["list_controllers", "list_options", "discover", "check_controller"])
        #expect(UniFiAccessPlugin.assistantActions.allSatisfy { $0.access == .read && !$0.confirm })

        let controllers = try await call(plugin, "list_controllers")
        #expect(controllers.status == 200)
        let devices = try #require(controllers.json["controllers"]?[0]?["devices"]?.arrayValue)
        let byId = Dictionary(uniqueKeysWithValues: devices.compactMap { device in device["id"]?.stringValue.map { ($0, device) } })
        // The UA Hub fixture: relay `lock` (not `off`) is unlocked, DPS `close` (not `on`) is open: what HomeKit shows (contact state 1).
        #expect(byId[hubID]?["locked"] == false)
        #expect(byId[hubID]?["door"] == "open")
        #expect(byId[hubID]?["door"]?.stringValue == ["closed", "open"][value(host, hubID, .contactSensor, "ContactSensor.DPS", .contactSensorState) ?? 9])
        #expect(byId[gateID]?["door"] == "closed")
        #expect(byId[gateID]?["sideDoorLocked"] == true)
        #expect(byId[gateID]?["sideDoor"] == "closed")
        #expect(byId[ultraID]?["accessMethods"]?["Face Unlock"] == true)
        #expect(byId[ultraID]?["accessMethods"]?["PIN"] == false)

        let options = try await call(plugin, "list_options")
        #expect(options.json["categories"]?.arrayValue?.isEmpty == false)

        let discover = try await call(plugin, "discover")
        #expect(discover.json["devices"]?[0]?["ip"] == "10.0.0.1")

        let online = try await call(plugin, "check_controller", ["address": "10.0.0.1"])
        #expect(online.json["online"] == true)
        let offline = try await call(plugin, "check_controller", ["address": "10.0.0.9"])
        #expect(offline.json["online"] == false)
    }
}
