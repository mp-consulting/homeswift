import Foundation
import Homeswift
import HomeswiftAI
import Testing

@testable import HomeswiftUI

/// Rooms, scenes and notifications through the web UI's API.
@Suite(.timeLimit(.minutes(1)))
struct HomeTests {
    @Test func roomsHiddenAccessoriesAndQuickControls() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        let saved = try await browser.put("/api/rooms", ["accessories": ["Lamps:lamp": ["room": "Desk", "favourite": true, "name": "Reading light"], "Lamps:lock": ["hidden": true]]])
        #expect(saved.status == 200)
        #expect(saved.json?["rooms"]?[0]?["name"] == "Desk")
        let accessories = try #require(try await browser.get("/api/accessories").json?.arrayValue)
        let lamp = try #require(accessories.first { $0["id"] == "Lamps:lamp" })
        #expect(lamp["room"] == "Desk")
        #expect(lamp["favourite"] == true)
        #expect(lamp["displayName"] == "Reading light")
        #expect(accessories.first { $0["id"] == "Lamps:lock" }?["hidden"] == true)

        // A bad change says why; an unknown accessory is refused.
        #expect(try await browser.put("/api/rooms", ["accessories": ["Lamps:nothing": ["room": "Desk"]]]).status == 400)
        #expect(try await browser.put("/api/rooms", ["accessories": ["Lamps:lamp": ["room": .string(String(repeating: "x", count: 65))]]]).status == 400)
        // Without the Assistant there is nothing to suggest.
        #expect(try await browser.post("/api/layout/suggest", [:]).status == 404)
    }

    @Test func scenesRunAndAskBeforeALock() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        let created = try await browser.post("/api/scenes", [
            "name": "Night", "actions": [["id": "Lamps:lamp", "characteristic": "Brightness", "value": 5], ["id": "Lamps:lock", "characteristic": "Lock Target State", "value": 1]],
            "triggers": [["type": "time", "at": "23:00", "days": [0, 1, 2, 3, 4, 5, 6]], ["type": "sun", "event": "sunset", "offsetMinutes": -15]],
        ])
        #expect(created.status == 201)
        let scene = try #require(created.json)
        let id = try #require(scene["id"]?.stringValue)
        #expect(scene["security"] == true)
        #expect(scene["triggers"]?[0]?["days"] == nil)   // every day reads as no days
        #expect(scene["actions"]?[1]?["security"] == true)

        // The page must say the person agreed to the lock.
        let unconfirmed = try await browser.post("/api/scenes/\(id)/run", [:])
        #expect(unconfirmed.status == 409)
        #expect(!environment.writes.withLockedValue { $0 }.contains { $0.0 == "lock" })
        let run = try await browser.post("/api/scenes/\(id)/run", ["confirmSecurity": true])
        #expect(run.status == 200)
        #expect(run.json?["ok"] == true)
        let writes = environment.writes.withLockedValue { $0 }
        #expect(writes.contains { $0.0 == "brightness" && $0.1 == .int(5) })
        #expect(writes.contains { $0.0 == "lock" && $0.1 == .int(1) })

        // A location gives the next sunrise and sunset.
        let located = try await browser.put("/api/scenes/location", ["lat": 48.8566, "lon": 2.3522, "name": "Paris"])
        #expect(located.status == 200)
        #expect(located.json?["nextSunset"]?.stringValue != nil)
        #expect(try await browser.put("/api/scenes/location", ["lat": 200, "lon": 0]).status == 400)

        let changed = try await browser.put("/api/scenes/\(id)", ["name": "Late night", "actions": [["id": "Lamps:lamp", "characteristic": "On", "value": false]]])
        #expect(changed.json?["name"] == "Late night")
        #expect(changed.json?["triggers"]?.arrayValue?.count == 2)   // kept when left out
        #expect(try await browser.send("DELETE", "/api/scenes/\(id)").status == 200)
        #expect(try await browser.post("/api/scenes/\(id)/run", [:]).status == 404)
        #expect(try await browser.get("/api/scenes").json?["scenes"]?.arrayValue?.isEmpty == true)
    }

    /// Moods: the collection, one set once, one playing until stopped, a calm one saved as a scene; who may do what.
    @Test func moodsPlayStopAndSaveAsScenes() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.put("/api/rooms", ["accessories": ["Lamps:lamp": ["room": "Desk"], "Lamps:strip": ["room": "Desk"]]]).status == 200)

        let moods = try #require(try await browser.get("/api/moods").json)
        #expect(moods["moods"]?.arrayValue?.isEmpty == false)
        #expect(moods["assistant"] == false)
        #expect(moods["moods"]?[0]?["swatch"]?.arrayValue?.isEmpty == false)

        let focus = try await browser.post("/api/moods/start", ["mood": "focus", "room": "Desk"])
        #expect(focus.status == 200)
        #expect(focus.json?["ok"] == true)
        #expect(environment.writes.withLockedValue { $0 }.contains { $0.0 == "brightness" && $0.1 == .int(100) })

        let police = try await browser.post("/api/moods/start", ["mood": "police", "room": "Desk", "durationSeconds": 60])
        let run = try #require(police.json?["run"]?["id"]?.stringValue)
        #expect(try await browser.get("/api/moods").json?["running"]?[0]?["id"]?.stringValue == run)
        #expect(try await browser.post("/api/moods/stop", ["run": .string(run)]).json?["stopped"]?.arrayValue?.count == 1)
        #expect(try await browser.get("/api/moods").json?["running"]?.arrayValue?.isEmpty == true)

        let saved = try await browser.post("/api/moods/save", ["mood": "relax", "room": "Desk", "name": "Evening"])
        #expect(saved.status == 201)
        #expect(try await browser.get("/api/scenes").json?["scenes"]?[0]?["name"] == "Evening")
        #expect(try await browser.post("/api/moods/save", ["mood": "disco", "room": "Desk", "name": "Party"]).status == 400)
        // Without the Assistant a description has nobody to write it.
        #expect(try await browser.post("/api/moods/start", ["description": "a jazz bar", "room": "Desk"]).status == 404)

        #expect(UIServer.requiredScope(.GET, ["moods"]) == .read)
        #expect(UIServer.requiredScope(.POST, ["moods", "start"]) == .control)
        #expect(UIServer.requiredScope(.POST, ["moods", "stop"]) == .control)
        #expect(UIServer.requiredScope(.POST, ["moods", "save"]) == .admin)
    }

    @Test func notificationSettingsHideTheirSecrets() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        let initial = try #require(try await browser.get("/api/notifications").json)
        #expect(initial["events"]?.arrayValue?.contains { $0["name"] == "dailyDigest" && $0["enabled"] == false } == true)
        let saved = try await browser.put("/api/notifications", ["channels": ["telegram": ["enabled": true, "botToken": "123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ", "chatId": "-1001234"]]])
        #expect(saved.status == 200)
        #expect(saved.json?["channels"]?["telegram"]?["botToken"] == "********")
        #expect(!saved.body.contains("ABCDEFGHIJ"))
        #expect(try await browser.put("/api/notifications", ["channels": ["webhook": ["url": "ftp://nope"]]]).status == 400)

        let push = try #require(try await browser.get("/api/notifications/push").json)
        #expect(push["publicKey"]?.stringValue?.count == 87)
        #expect(try await browser.post("/api/notifications/push/subscribe", ["endpoint": "https://push.example.com/x", "keys": ["p256dh": "short", "auth": "short"]]).status == 400)

        // The service worker is served from the root, as a script.
        let worker = try await browser.get("/sw.js")
        #expect(worker.status == 200)
        #expect(worker.headers["content-type"]?.hasPrefix("text/javascript") == true)
    }
}
