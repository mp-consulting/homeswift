import Foundation
import HomeswiftAI
import Testing

@testable import HomeswiftUI

@Suite struct SetupRouteTests {
    /// Setup writes config.json and the vault: an administrator's, whatever the route.
    @Test func setupNeedsAnAdministrator() {
        for route in [["setup", "discover"], ["setup", "start"], ["setup", "exclude"], ["setup", "abc"], ["setup", "abc", "cancel"]] {
            #expect(UIServer.requiredScope(.POST, route) == .admin, "\(route)")
        }
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
        #expect(try await browser.post("/api/setup/discover", [:]).status == 400)
        let missing = try await browser.post("/api/setup/start", ["platform": "Lamps", "name": "Lamps", "deviceID": "nowhere"])
        #expect(missing.status == 400)
        #expect(missing.json?["error"]?.stringValue?.contains("did not find") == true)
        #expect(try await browser.post("/api/setup/unknown-session", ["answers": [:]]).status == 400)
        #expect(try await browser.post("/api/setup/unknown-session/cancel", [:]).json?["cancelled"] == false)

        #expect(try await browser.post("/api/setup/exclude", ["platform": "Lamps", "name": "Lamps", "deviceID": "lamp", "excluded": true]).status == 200)
        let config = try JSONValue(data: Data(contentsOf: environment.configURL))
        let block = config["platforms"]?.arrayValue?.first { $0["platform"] == "Lamps" }
        #expect(block?["_accessories"] == ["lamp": ["excluded": true]])
        let include = try await browser.post("/api/setup/exclude", ["platform": "Lamps", "name": "Lamps", "deviceID": "lamp", "excluded": false])
        #expect(include.status == 200, "\(include.body)")
        let again = try JSONValue(data: Data(contentsOf: environment.configURL))
        #expect(again["platforms"]?.arrayValue?.first { $0["platform"] == "Lamps" }?["_accessories"] == nil)
    }
}
