import Foundation
import HomeswiftAI
import Testing

@testable import HomeswiftUI

@Suite struct SetupRouteTests {
    /// Setup writes config.json and the vault: an administrator's, whatever the route.
    @Test func setupNeedsAnAdministrator() {
        for route in [["setup", "discover"], ["setup", "start"], ["setup", "abc"], ["setup", "abc", "cancel"]] {
            #expect(UIServer.requiredScope(.POST, route) == .admin, "\(route)")
        }
        // So are settings, read or written.
        #expect(UIServer.requiredScope(.GET, ["settings", "accessories", "Lamps:lamp"]) == .admin)
        #expect(UIServer.requiredScope(.PATCH, ["settings", "plugins", "Lamps", "Lamps"]) == .admin)
    }

    /// Add by address through the routes: offered by a plugin that takes it (Elgato's lights), refused by one that does
    /// not, its first prompt the address, an answer that is not one asked again, and cancelled.
    @Test func addsADeviceByAddressThroughTheRoutes() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        let plugins = try await browser.get("/api/plugins").json?["plugins"]?.arrayValue ?? []
        #expect(plugins.first { $0["platform"] == "ElgatoKeyLights" }?["addByAddress"] == true)
        #expect(plugins.first { $0["platform"] == "Lamps" }?["addByAddress"] == false)
        let refused = try await browser.post("/api/setup/start", ["platform": "Lamps", "name": "Lamps", "addByAddress": true])
        #expect(refused.status == 400 && refused.json?["error"]?.stringValue?.contains("cannot add a device by its address") == true)

        let first = try await browser.post("/api/setup/start", ["platform": "ElgatoKeyLights", "name": "Elgato Key Lights", "addByAddress": true])
        #expect(first.status == 200, "\(first.body)")
        #expect(first.json?["addByAddress"] == true && first.json?["prompt"]?["fields"]?[0]?["key"] == "host")
        let session = try #require(first.json?["session"]?.stringValue)
        let wrong = try await browser.post("/api/setup/\(session)", ["answers": ["host": "not a host"]])
        #expect(wrong.json?["status"] == "asking" && wrong.json?["error"] == "not a host is not an IP address or a host name")
        #expect(try await browser.post("/api/setup/\(session)/cancel", [:]).json?["cancelled"] == true)
    }

    /// Discovery, a device it did not find, and Exclude writing the device's Accessory Settings.
    @Test func discoversAndExcludesThroughTheRoutes() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        let found = try await browser.post("/api/setup/discover", ["platform": "Lamps", "name": "Lamps"])
        #expect(found.status == 200)
        #expect(found.json?["devices"] == [])
        #expect(found.json?["accountAuthorization"] == "none")
        #expect(found.json?["accountSetUp"] == true)
        // No account: nothing to set up, and the Plugins page shows it running.
        #expect(found.json?["accountState"] == "none" && found.json?["needsAuthorization"] == false)
        let lamps = try await browser.get("/api/plugins").json?["platforms"]?.arrayValue?.first { $0["platform"] == "Lamps" }
        #expect(lamps?["accountState"] == "none" && lamps?["needsAuthorization"] == false && lamps?["noneResponding"] == false)
        #expect(try await browser.post("/api/setup/discover", [:]).status == 400)
        let missing = try await browser.post("/api/setup/start", ["platform": "Lamps", "name": "Lamps", "deviceID": "nowhere"])
        #expect(missing.status == 400)
        #expect(missing.json?["error"]?.stringValue?.contains("did not find") == true)
        #expect(try await browser.post("/api/setup/unknown-session", ["answers": [:]]).status == 400)
        #expect(try await browser.post("/api/setup/unknown-session/cancel", [:]).json?["cancelled"] == false)

        // Exclude is an Accessory Setting: the device's, by its Accessory Id.
        #expect(try await browser.patch("/api/settings/accessories/Lamps:lamp", ["excluded": true]).status == 200)
        let config = try JSONValue(data: Data(contentsOf: environment.configURL))
        let block = config["platforms"]?.arrayValue?.first { $0["platform"] == "Lamps" }
        #expect(block?["_accessories"] == ["lamp": ["excluded": true]])
        let read = try await browser.get("/api/settings/accessories/Lamps:lamp")
        #expect(read.json?["settings"] == ["excluded": true] && read.json?["fields"]?["excluded"]?["core"] == true)
        let include = try await browser.patch("/api/settings/accessories/Lamps:lamp", ["excluded": nil])
        #expect(include.status == 200, "\(include.body)")
        let again = try JSONValue(data: Data(contentsOf: environment.configURL))
        #expect(again["platforms"]?.arrayValue?.first { $0["platform"] == "Lamps" }?["_accessories"] == nil)

        // The routes the settings replace are gone.
        #expect(try await browser.post("/api/setup/exclude", ["platform": "Lamps", "name": "Lamps", "deviceID": "lamp", "excluded": true]).status == 400)
        #expect(try await browser.put("/api/accessories/Lamps:lamp/name", ["name": "Desk"]).status == 404)
        #expect(try await browser.put("/api/accessories/Lamps:lamp/homekit", ["visible": false]).status == 404)

        // Plugin Settings: secrets as the placeholder, a write checked and merged.
        let plugin = try await browser.get("/api/settings/plugins/Lamps/Lamps")
        #expect(plugin.status == 200 && plugin.json?["platform"] == "Lamps")
        #expect(try await browser.patch("/api/settings/plugins/Lamps/Lamps", ["_paused": true]).status == 400)
        #expect(try await browser.patch("/api/settings/plugins/Lamps/Nowhere", [:]).status == 404)
    }
}
