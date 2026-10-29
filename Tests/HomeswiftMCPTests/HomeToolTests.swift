import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftMCP

/// Answers every request with `status` and keeps them.
final class RecordingSender: HTTPSending, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [HomeswiftNetwork.HTTPRequest] = []
    var status = 200

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        lock.withLock { kept.append(request) }
        return HomeswiftNetwork.HTTPResponse(status: status)
    }

    var requests: [HomeswiftNetwork.HTTPRequest] { lock.withLock { kept } }
}

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// Within a millisecond of Node's answer (its sin and cos may differ in the last bit).
private func close(_ date: Date?, _ seconds: Double) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince1970 - seconds) <= 0.0011
}

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

@Suite(.timeLimit(.minutes(1)))
struct LayoutToolTests {
    @Test func roomsFilterTheAccessories() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        // Before any room, a room filter says there are none.
        let none = try await client.tool("list_accessories", ["room": "Office"])
        #expect(none["isError"] == true)
        #expect(none["content"]?[0]?["text"]?.stringValue?.contains("none yet") == true)

        let set = try await client.tool("set_accessory_layout", ["accessories": [
            ["id": "Devices:lamp", "room": "Office", "name": "Reading light", "favourite": true],
            ["id": "Devices:lock", "room": "Hall", "hidden": true],
        ]])
        #expect(set["isError"] != true)
        let layout = try #require(set["structuredContent"])
        #expect(layout["rooms"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Office", "Hall"])
        #expect(layout["rooms"]?[0]?["accessories"]?[0]?["displayName"] == "Reading light")

        // Case aside, the room picks the lamp only; the JSON carries the layout.
        let office = try await client.tool("list_accessories", ["room": "office"])
        let accessories = office["structuredContent"]?["accessories"]?.arrayValue ?? []
        #expect(accessories.map { $0["id"]?.stringValue } == ["Devices:lamp"])
        #expect(accessories.first?["room"] == "Office")
        #expect(accessories.first?["favourite"] == true)
        let unknown = try await client.tool("list_accessories", ["room": "Attic"])
        #expect(unknown["content"]?[0]?["text"]?.stringValue?.contains("Rooms: Office, Hall") == true)

        // set_accessories takes the room filter too.
        let dry = try await client.tool("set_accessories", ["filter": ["room": "Office"], "characteristic": "On", "value": true, "dryRun": true])
        #expect(dry["structuredContent"]?["wouldChange"] == 1)

        // Rename and remove rooms; the file is the owner's alone.
        _ = try await client.tool("set_accessory_layout", ["renameRoom": ["from": "office", "to": "Study"], "removeRooms": ["Hall"]])
        let after = environment.catalog.home.layout.value
        #expect(after.rooms == ["Study"])
        #expect(after.accessories["Devices:lamp"]?.room == "Study")
        #expect(after.accessories["Devices:lock"]?.room == nil)
        #expect(after.accessories["Devices:lock"]?.hidden == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: environment.directory.appendingPathComponent("accessory-layout.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // A read-only token sees the layout but cannot change it.
        let reader = DirectClient(server: environment.server, scope: .read)
        try await reader.initialize()
        #expect(try await reader.tool("get_accessory_layout")["isError"] != true)
        #expect(try await reader.tool("set_accessory_layout", ["rooms": ["X"]])["isError"] == true)
    }

    @Test func groupsDriveThePrimaryServiceOnly() {
        // A Hue light: its lightbulb is primary; its effect switch and gradient point are not what a group drives.
        let hue = Accessory(id: "hue", name: "Strip", category: .lightbulb, services: [
            Service(.lightbulb, name: "Strip", optional: [.brightness, .hue], isPrimary: true),
            Service(.switch, name: "Candle", subtype: "effect:candle"), Service(.lightbulb, name: "Point", subtype: "point:0"),
        ])
        #expect(HomeswiftCatalog.groupTargets(hue).map(\.type.name).sorted() == ["Brightness", "Hue", "On"])
        // Two lightbulbs and no primary one: which would a group drive? Neither.
        let twin = Accessory(id: "twin", name: "Twin", category: .lightbulb, services: [Service(.lightbulb, subtype: "a"), Service(.lightbulb, subtype: "b")])
        #expect(HomeswiftCatalog.groupTargets(twin).isEmpty)
        #expect(HomeswiftCatalog.canGroup([hue, Accessory(id: "plug", name: "Plug", category: .outlet, services: [Service(.outlet)])]))
        #expect(!HomeswiftCatalog.canGroup([hue, twin]))
    }

    @Test func wallIsArrangedRoomByRoom() async throws {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [{ "platform": "Devices", "name": "Devices", "colourBulbs": 3 }]
            }
            """)
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        // Every change to the rooms or the wall is told to whoever follows them (the web UI's event stream).
        let changes = NIOLockedValueBox(0)
        let observation = environment.catalog.home.observeLayout { changes.withLockedValue { $0 += 1 } }
        defer { observation.cancel() }
        _ = try await client.tool("set_accessory_layout", ["accessories": [
            ["id": "Devices:lamp", "room": "Office"], ["id": "Devices:bulb1", "room": "Office"], ["id": "Devices:bulb2", "room": "Office"],
            ["id": "Devices:bulb3", "room": "Hall"], ["id": "Devices:lock", "room": "Hall"],
        ]])
        func sections(_ result: JSONValue) -> [String: [String]] {
            Dictionary(uniqueKeysWithValues: (result["structuredContent"]?["sections"]?.arrayValue ?? []).map { section in
                (section["name"]?.stringValue ?? "", section["accessories"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? [])
            })
        }

        // One room's ids sort that room; the other keeps its order (by plugin and name until one is chosen).
        let sorted = try await client.tool("set_wall_layout", ["grouping": "room", "order": ["Devices:bulb2", "Devices:lamp", "Devices:bulb1"]])
        #expect(sorted["isError"] != true)
        #expect(changes.withLockedValue { $0 } == 2)
        #expect(sorted["structuredContent"]?["grouping"] == "room")
        #expect(sections(sorted) == ["Office": ["Devices:bulb2", "Devices:lamp", "Devices:bulb1"], "Hall": ["Devices:bulb3", "Devices:lock"]])
        _ = try await client.tool("set_wall_layout", ["order": ["Devices:lock", "Devices:bulb3"]])
        #expect(sections(try await client.tool("get_wall_layout")) == ["Office": ["Devices:bulb2", "Devices:lamp", "Devices:bulb1"], "Hall": ["Devices:lock", "Devices:bulb3"]])

        // Sizes by accessory and by kind; the page reads the same file.
        let sized = try await client.tool("set_wall_layout", ["sizes": ["Devices:lamp": "large", "Devices:lock": "small"], "defaults": ["light": "medium"]])
        #expect(sized["structuredContent"]?["defaults"]?["light"] == "medium")
        #expect(sized["structuredContent"]?["sections"]?[0]?["accessories"]?[1]?["size"] == "large")
        let cleared = try await client.tool("set_wall_layout", ["sizes": ["Devices:lock": .null]])
        #expect(cleared["isError"] != true, "\(cleared)")
        let wall = environment.catalog.home.wall.load()
        #expect(wall["sizes"] == ["Devices:lamp": "large"])
        #expect(wall["grouping"] == "room")
        // The Hall's two swapped their places: the Office's are where they were.
        #expect(wall["order"] == ["Devices:bulb2", "Devices:lamp", "Devices:lock", "Devices:bulb1", "Devices:bulb3"])

        // What the wall cannot take is refused, and nothing changes.
        #expect(try await client.tool("set_wall_layout", ["order": ["Devices:nothing"]])["isError"] == true)
        #expect(try await client.tool("set_wall_layout", ["sizes": ["Devices:lamp": "huge"]])["isError"] == true)
        #expect(try await client.tool("set_wall_layout", ["defaults": ["spaceship": "small"]])["isError"] == true)
        #expect(environment.catalog.home.wall.load() == wall)

        // Lights that go together become one widget, where the first of them was.
        let grouped = try await client.tool("set_wall_layout", ["groups": [["name": "Office lights", "members": ["Devices:lamp", "Devices:bulb1"]]]])
        #expect(grouped["isError"] != true, "\(grouped)")
        let office = try #require(grouped["structuredContent"]?["sections"]?[0]?["accessories"]?.arrayValue)
        #expect(office.count == 2)
        #expect(office[0]["id"] == "Devices:bulb2")
        #expect(office[1]["name"] == "Office lights")
        #expect(office[1]["members"] == ["Devices:lamp", "Devices:bulb1"])
        let groupID = try #require(office[1]["id"]?.stringValue)
        #expect(groupID.hasPrefix("group:"))
        #expect(office[0]["groupable"] == true)

        // Joining another group leaves the first, which is dissolved with one member left; a lock never joins.
        let lockGroup = try await client.tool("set_wall_layout", ["groups": [["name": "Lock and lamp", "members": ["Devices:lock", "Devices:bulb2"]]]])
        #expect(lockGroup["isError"] == true, "\(lockGroup)")
        let moved = try await client.tool("set_wall_layout", ["groups": [["name": "Bulbs", "members": ["Devices:bulb1", "Devices:bulb2", "Devices:bulb3"]]]])
        let groups = environment.catalog.home.wall.load()["groups"]?.arrayValue ?? []
        #expect(groups.map { $0["name"] } == ["Bulbs"])
        #expect(environment.catalog.home.wall.load()["order"]?.arrayValue?.contains(.string(groupID)) == false)
        let bulbs = try #require(groups.first?["id"]?.stringValue)
        #expect(moved["structuredContent"]?["sections"]?[0]?["accessories"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == [bulbs, "Devices:lamp"])
        // A group is renamed by its id, and dissolved.
        _ = try await client.tool("set_wall_layout", ["groups": [["id": .string(bulbs), "name": "All bulbs", "members": ["Devices:bulb1", "Devices:bulb2", "Devices:bulb3"]]]])
        #expect(environment.catalog.home.wall.load()["groups"]?[0]?["name"] == "All bulbs")
        _ = try await client.tool("set_wall_layout", ["ungroup": [.string(bulbs)]])
        #expect(environment.catalog.home.wall.load()["groups"] == [])

        let reader = DirectClient(server: environment.server, scope: .read)
        try await reader.initialize()
        #expect(try await reader.tool("get_wall_layout")["isError"] != true)
        #expect(try await reader.tool("set_wall_layout", ["grouping": "none"])["isError"] == true)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SceneToolTests {
    @Test func stoppingSceneRestoresLightBaselineAcrossRepeatedRuns() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let scene = try catalog.createScene(["name": "Undo light", "actions": [
            ["id": "Devices:lamp", "characteristic": "On", "value": true],
            ["id": "Devices:lamp", "characteristic": "Brightness", "value": 80],
        ]])
        let id = try #require(scene["id"]?.stringValue)
        let lamp = try #require(catalog.find(id: "Devices:lamp"))
        let brightness = try catalog.characteristic(in: lamp, service: nil, characteristic: "Brightness")
        let on = try catalog.characteristic(in: lamp, service: nil, characteristic: "On")
        let before = on.value
        _ = try await catalog.runScene(id)
        _ = try await catalog.runScene(id)
        #expect(brightness.value == .int(80))
        #expect(catalog.scenesJSON()["scenes"]?[0]?["stoppable"] == true)
        #expect(try await catalog.stopScene(id)["ok"] == true)
        #expect(brightness.value == .int(40))
        #expect(on.value == before)
        #expect(catalog.scenesJSON()["scenes"]?[0]?["stoppable"] == false)
    }

    @Test func stoppingSceneKeepsSecurityConfirmationAndLaterChanges() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let lock = try #require(catalog.find(id: "Devices:lock"))
        let target = try catalog.characteristic(in: lock, service: nil, characteristic: "Lock Target State")
        target.value = .int(1)
        let scene = try catalog.createScene(["name": "Undo lock", "actions": [
            ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 0],
        ]])
        let id = try #require(scene["id"]?.stringValue)
        _ = try await catalog.runScene(id, allowSecurity: true)
        await #expect(throws: (any Error).self) { try await catalog.stopScene(id) }
        #expect(target.value == .int(0))
        #expect(HomeState(directory: environment.directory).sceneUndo.value[id]?.actions.first?.value == 1)
        _ = try await catalog.stopScene(id, allowSecurity: true)
        #expect(target.value == .int(1))
        _ = try await catalog.runScene(id, allowSecurity: true)
        target.value = .int(1) // A later manual change must survive Stop.
        let writes = environment.written.count
        _ = try await catalog.stopScene(id, allowSecurity: true)
        #expect(environment.written.count == writes)
    }

    @Test(arguments: [false, true]) func unsuccessfulRerunKeepsPriorUndo(fails: Bool) async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let lock = try #require(catalog.find(id: "Devices:lock"))
        let target = try catalog.characteristic(in: lock, service: nil, characteristic: "Lock Target State")
        target.value = .int(1)
        let scene = try catalog.createScene(["name": "Restore after rerun", "actions": [
            ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 0],
        ]])
        let id = try #require(scene["id"]?.stringValue)
        _ = try await catalog.runScene(id, allowSecurity: true)
        if fails { target.onWrite { _ in throw CatalogError("offline") } }
        _ = try await catalog.runScene(id, trigger: .schedule, allowSecurity: fails)
        #expect(catalog.home.sceneUndo.value[id]?.actions.first?.value == 1)
        await #expect(throws: (any Error).self) { try await catalog.stopScene(id) }
        target.onWrite(nil)
        _ = try await catalog.stopScene(id, allowSecurity: true)
        #expect(target.value == .int(1))
    }

    @Test func failedLightWriteKeepsExistingMoodOwnership() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let lamp = try #require(catalog.find(id: "Devices:lamp"))
        let light = try #require(HomeswiftCatalog.lights(of: [lamp]).first)
        let mood = Mood(id: "test-held", name: "Existing mood", steps: [MoodStep([light.color], seconds: 1)])
        let run = catalog.hold(mood, on: [light], snapshots: [light.key: light.snapshot()], by: "test", room: nil)
        let brightness = try catalog.characteristic(in: lamp, service: nil, characteristic: "Brightness")
        brightness.onWrite { _ in throw CatalogError("offline") }
        let scene = try catalog.createScene(["name": "Failed scene", "actions": [
            ["id": "Devices:lamp", "characteristic": "Brightness", "value": 80],
        ]])
        let id = try #require(scene["id"]?.stringValue)
        #expect(try await catalog.runScene(id)["ok"] == false)
        #expect(catalog.home.runningMoods.withLockedValue { $0[run.id] === run && $0.count == 1 })
        #expect(run.snapshots.withLockedValue { $0[light.key] != nil })
        #expect(catalog.scenesJSON()["scenes"]?[0]?["stoppable"] == false)
        brightness.onWrite(nil)
        _ = try await catalog.stopMoods(id: run.id)
    }

    @Test func savesRunsAndKeepsLocksForAPerson() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        // save_scene captures the lamp's On and Brightness; never the lock's target.
        let dry = try await client.tool("save_scene", ["name": "Evening", "ids": ["Devices:lamp", "Devices:lock"], "characteristics": ["On", "Brightness", "Lock Target State"], "dryRun": true])
        let actions = dry["structuredContent"]?["actions"]?.arrayValue ?? []
        #expect(Set(actions.compactMap { $0["characteristic"]?.stringValue }) == ["On", "Brightness"])
        #expect(dry["structuredContent"]?["skipped"]?[0]?["id"] == "Devices:lock")
        let saved = try await client.tool("save_scene", ["name": "Evening", "ids": ["Devices:lamp"], "characteristics": ["On", "Brightness"]])
        let id = try #require(saved["structuredContent"]?["created"]?["id"]?.stringValue)

        // Change it to 70 % and on, then run it.
        _ = try environment.catalog.updateScene(id: id, ["name": "Evening", "actions": [
            ["id": "Devices:lamp", "characteristic": "On", "value": true], ["id": "Devices:lamp", "characteristic": "Brightness", "value": 70],
        ]])
        let run = try await client.tool("run_scene", ["scene": "evening"])
        #expect(run["structuredContent"]?["ok"] == true)
        #expect(environment.written.contains { $0.0 == "lamp.brightness" && $0.1 == .int(70) })
        #expect(environment.catalog.home.scenes.value.scenes.first?.lastRun?.ok == true)
        #expect(environment.auditEntries.contains { $0["tool"] == "run_scene" && $0["ok"] == true })

        // A scene with the door: run_scene refuses it; an automation skips the door; a person who confirmed runs it.
        let door = try environment.catalog.createScene(["name": "Leave", "actions": [
            ["id": "Devices:lamp", "characteristic": "On", "value": false], ["id": "Devices:lock", "characteristic": "Lock Target State", "value": 1],
        ]])
        let doorID = try #require(door["id"]?.stringValue)
        #expect(door["security"] == true)
        let refused = try await client.tool("run_scene", ["scene": "Leave"])
        #expect(refused["isError"] == true)
        #expect(refused["content"]?[0]?["text"]?.stringValue?.contains("set_security_accessory") == true)
        #expect(!environment.written.contains { $0.0 == "lock.target" })

        let automatic = try await environment.catalog.runScene(doorID, trigger: .schedule)
        #expect(automatic["note"]?.stringValue?.contains("security") == true)
        #expect(!environment.written.contains { $0.0 == "lock.target" })
        #expect(environment.written.contains { $0.0 == "lamp.on" && $0.1 == .bool(false) })

        _ = try await environment.catalog.runScene(doorID, trigger: .manual, allowSecurity: true)
        #expect(environment.written.contains { $0.0 == "lock.target" && $0.1 == .int(1) })

        // list_scenes says which needs a person.
        let list = try await client.tool("list_scenes")
        let scenes = list["structuredContent"]?["scenes"]?.arrayValue ?? []
        #expect(scenes.first { $0["name"] == "Leave" }?["security"] == true)
        #expect(scenes.first { $0["name"] == "Evening" }?["security"] == false)
    }

    @Test func conditionsHoldAnAutomaticRunBack() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let scene = try environment.catalog.createScene(["name": "Only when on", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 10]],
            "conditions": [["type": "characteristic", "id": "Devices:lamp", "characteristic": "On", "operator": "eq", "value": true]]])
        let id = try #require(scene["id"]?.stringValue)
        let skipped = try await environment.catalog.runScene(id, trigger: .schedule)
        #expect(skipped["skipped"]?.stringValue?.contains("On is false") == true)
        #expect(environment.catalog.home.scenes.value.scenes.first?.lastSkipped != nil)
        // By hand, the conditions do not count.
        _ = try await environment.catalog.runScene(id, trigger: .manual)
        #expect(environment.written.contains { $0.0 == "lamp.brightness" && $0.1 == .int(10) })
    }

    @Test func aCharacteristicChangeRunsAScene() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let catalog = environment.catalog
        catalog.startHome(restarted: true)
        defer { Task { await catalog.stopHome(restarting: true); await environment.stop() } }
        _ = try catalog.createScene(["name": "Bright when on", "actions": [["id": "Devices:lamp", "characteristic": "Brightness", "value": 100]],
            "triggers": [["type": "characteristic", "id": "Devices:lamp", "characteristic": "On", "operator": "eq", "value": true]]])
        let lamp = try #require(catalog.find(id: "Devices:lamp"))
        _ = try await catalog.write(lamp, service: nil, characteristic: "On", value: true, allowSecurity: false)
        #expect(await eventually { environment.written.contains { $0.0 == "lamp.brightness" && $0.1 == .int(100) } })
    }

    @Test func refusesBadScenes() throws {
        let environment = try MCPTestEnvironment()
        #expect(throws: CatalogError.self) { try environment.catalog.createScene(["name": "", "actions": [["id": "a", "characteristic": "On", "value": true]]]) }
        #expect(throws: CatalogError.self) { try environment.catalog.createScene(["name": "No actions", "actions": []]) }
        #expect(throws: CatalogError.self) {
            try environment.catalog.createScene(["name": "Bad time", "actions": [["id": "a", "characteristic": "On", "value": true]], "triggers": [["type": "time", "at": "25:00"]]])
        }
        #expect(throws: CatalogError.self) {
            try environment.catalog.createScene(["name": "Bad cron", "actions": [["id": "a", "characteristic": "On", "value": true]], "triggers": [["type": "cron", "cron": "61 * * * *"]]])
        }
        #expect(throws: CatalogError.self) {
            try environment.catalog.createScene(["name": "Bad offset", "actions": [["id": "a", "characteristic": "On", "value": true]], "triggers": [["type": "sun", "event": "sunset", "offsetMinutes": 900]]])
        }
        #expect(throws: CatalogError.self) { try environment.catalog.setSceneLocation(["lat": 95, "lon": 0]) }
    }
}

@Suite struct SceneTimeTests {
    /// The values Glass UI's solar.ts gives, run in Node for these places and days.
    @Test func sunTimesMatchGlassUI() {
        let paris = Solar.times(on: utc("2024-06-21T12:00:00Z"), latitude: 48.8566, longitude: 2.3522)
        #expect(close(paris.sunrise, 1718941618.783))
        #expect(close(paris.sunset, 1718999868.637))
        let sydney = Solar.times(on: utc("2024-12-21T03:00:00Z"), latitude: -33.8688, longitude: 151.2093)
        #expect(close(sydney.sunrise, 1734720054.728))
        #expect(close(sydney.sunset, 1734771924.717))
        let sanFrancisco = Solar.times(on: utc("2026-03-10T20:00:00Z"), latitude: 37.7749, longitude: -122.4194)
        #expect(close(sanFrancisco.sunrise, 1773152901.115))
        #expect(close(sanFrancisco.sunset, 1773195105.92))
        // Polar night in Tromsø.
        let tromso = Solar.times(on: utc("2024-12-21T12:00:00Z"), latitude: 69.6492, longitude: 18.9553)
        #expect(tromso.sunrise == nil && tromso.sunset == nil)
        // The next sunset after noon is that evening's.
        #expect(close(Solar.next(.sunset, latitude: 48.8566, longitude: 2.3522, after: utc("2024-06-21T12:00:00Z")), 1718999868.637))
    }

    @Test func timedTriggersRunOnTheirMinute() {
        let paris = calendar("Europe/Paris")
        let location = SceneLocation(lat: 48.8566, lon: 2.3522, name: nil)
        // Friday 21 June 2024, 07:30 in Paris.
        let friday = utc("2024-06-21T05:30:00Z")
        var time = SceneTrigger(type: "time")
        time.at = "07:30"
        #expect(SceneRules.due(time, at: friday, location: nil, calendar: paris))
        time.days = [0, 6]
        #expect(!SceneRules.due(time, at: friday, location: nil, calendar: paris))
        time.days = [5]
        #expect(SceneRules.due(time, at: friday, location: nil, calendar: paris))
        time.enabled = false
        #expect(!SceneRules.due(time, at: friday, location: nil, calendar: paris))

        var sun = SceneTrigger(type: "sun")
        sun.event = .sunrise
        #expect(SceneRules.due(sun, at: utc("2024-06-21T03:46:10Z"), location: location, calendar: paris))
        #expect(!SceneRules.due(sun, at: utc("2024-06-21T03:47:10Z"), location: location, calendar: paris))
        #expect(!SceneRules.due(sun, at: utc("2024-06-21T03:46:10Z"), location: nil, calendar: paris))
        sun.offsetMinutes = 30
        #expect(SceneRules.due(sun, at: utc("2024-06-21T04:16:30Z"), location: location, calendar: paris))
        // Sunset plus four hours falls after midnight; it belongs to the evening before.
        sun.event = .sunset
        sun.offsetMinutes = 240
        sun.days = [5]
        #expect(SceneRules.due(sun, at: utc("2024-06-21T23:57:30Z"), location: location, calendar: paris))

        var cron = SceneTrigger(type: "cron")
        cron.cron = "30 7 * * 1-5"
        #expect(SceneRules.due(cron, at: friday, location: nil, calendar: paris))
        cron.cron = "0 30 7 * * 0,6"
        #expect(!SceneRules.due(cron, at: friday, location: nil, calendar: paris))
    }

    @Test func readsCronLikeCron() throws {
        let utcCalendar = calendar("UTC")
        let every15 = try #require(try? CronSchedule("*/15 * * * *"))
        #expect(every15.matches(utc("2026-01-05T10:45:00Z"), calendar: utcCalendar))
        #expect(!every15.matches(utc("2026-01-05T10:44:00Z"), calendar: utcCalendar))
        // Day of month or day of week, both restricted: either.
        let firstOrMonday = try #require(try? CronSchedule("0 9 1 * 1"))
        #expect(firstOrMonday.matches(utc("2026-01-05T09:00:00Z"), calendar: utcCalendar))   // a Monday
        #expect(firstOrMonday.matches(utc("2026-01-01T09:00:00Z"), calendar: utcCalendar))   // the 1st, a Thursday
        #expect(!firstOrMonday.matches(utc("2026-01-06T09:00:00Z"), calendar: utcCalendar))
        // Sunday is 0 or 7.
        #expect(try #require(try? CronSchedule("0 9 * * 7")).matches(utc("2026-01-04T09:00:00Z"), calendar: utcCalendar))
        for bad in ["", "* * * *", "60 * * * *", "* 24 * * *", "*/0 * * * *", "a * * * *", "5-1 * * * *"] { #expect((try? CronSchedule(bad)) == nil, "\(bad)") }
        // Months and days are the Gregorian calendar's, whatever the system's calendar is.
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = TimeZone(identifier: "UTC")!
        let newYear = try #require(try? CronSchedule("0 9 1 1 *"))
        #expect(newYear.matches(utc("2026-01-01T09:00:00Z"), calendar: hebrew))
        #expect(newYear.next(after: utc("2025-12-31T12:00:00Z"), calendar: hebrew) == utc("2026-01-01T09:00:00Z"))
    }

    @Test func comparesAndFiresAsGlassUI() {
        var trigger = SceneTrigger(type: "characteristic")
        trigger.operator = "gt"
        trigger.value = 20
        #expect(SceneRules.fires(trigger, previous: 18, next: 21))
        #expect(!SceneRules.fires(trigger, previous: 21, next: 22))    // it already matched
        #expect(SceneRules.fires(trigger, previous: nil, next: 21))
        trigger.operator = "changes"
        #expect(!SceneRules.fires(trigger, previous: nil, next: 1))      // nothing to compare with yet
        #expect(!SceneRules.fires(trigger, previous: true, next: 1))     // the same value, as HAP sends it
        #expect(SceneRules.fires(trigger, previous: false, next: true))
        #expect(SceneRules.compare("on", "eq", "on"))
        #expect(!SceneRules.compare("on", "gt", "off"))

        let paris = calendar("Europe/Paris")
        let night = SceneCondition(type: "time", after: "22:00", before: "06:00")
        #expect(SceneRules.inWindow(night, now: utc("2024-06-21T21:30:00Z"), location: nil, calendar: paris) == true)    // 23:30
        #expect(SceneRules.inWindow(night, now: utc("2024-06-21T10:00:00Z"), location: nil, calendar: paris) == false)
        let evening = SceneCondition(type: "time", after: "sunset", before: "23:59")
        #expect(SceneRules.inWindow(evening, now: utc("2024-06-21T20:30:00Z"), location: nil, calendar: paris) == nil)
        #expect(SceneRules.inWindow(evening, now: utc("2024-06-21T20:30:00Z"), location: SceneLocation(lat: 48.8566, lon: 2.3522), calendar: paris) == true)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct NotificationTests {
    @Test func keepsSecretsAndSendsToEachChannel() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let sender = RecordingSender()
        let catalog = environment.catalog
        catalog.home.http = sender

        // A channel turned on must be complete; a bad token is refused.
        #expect(throws: CatalogError.self) { try catalog.updateNotificationSettings(["channels": ["ntfy": ["enabled": true, "topic": ""]]]) }
        #expect(throws: CatalogError.self) { try catalog.updateNotificationSettings(["channels": ["telegram": ["botToken": "nope"]]]) }
        let settings = try catalog.updateNotificationSettings([
            "channels": [
                "webhook": ["enabled": true, "url": "https://hooks.example.com/abc-secret-path"],
                "ntfy": ["enabled": true, "server": "https://ntfy.example.com/", "topic": "homeswift-test", "token": "tk_secret123"],
            ],
            "events": ["dailyDigest": true, "pluginError": false],
        ])
        #expect(settings["channels"]?["webhook"]?["url"] == "********")
        #expect(settings["channels"]?["ntfy"]?["token"] == "********")
        #expect(settings["channels"]?["ntfy"]?["topic"] == "homeswift-test")
        #expect(settings["events"]?.arrayValue?.first { $0["name"] == "pluginError" }?["enabled"] == false)
        // The placeholder sent back keeps the secret; the file is the owner's alone.
        _ = try catalog.updateNotificationSettings(["channels": ["ntfy": ["token": "********"]]])
        #expect(catalog.home.notifications.value.channels.ntfy.token == "tk_secret123")
        let attributes = try FileManager.default.attributesOfItem(atPath: environment.directory.appendingPathComponent("notifications.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        // send_test_notification goes to both, through the MCP server.
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let test = try await client.tool("send_test_notification")
        #expect(test["structuredContent"]?["results"]?.arrayValue?.count == 2)
        let requests = sender.requests
        let ntfy = try #require(requests.first { $0.url.host == "ntfy.example.com" })
        #expect(ntfy.url.path == "/homeswift-test")
        #expect(ntfy.header("Authorization") == "Bearer tk_secret123")
        #expect(ntfy.header("Title") == "Test Bridge: Test notification")
        let hook = try #require(requests.first { $0.url.host == "hooks.example.com" })
        let body = try JSONValue(data: hook.body ?? Data())
        #expect(body["event"] == "test")
        #expect(body["instance"] == "Test Bridge")

        // A failure says which channel, without its secrets.
        sender.status = 500
        let failed = try await catalog.sendTestNotification(channel: .webhook)
        #expect(failed["results"]?[0]?["error"] == "HTTP 500")
        sender.status = 200

        // The limits: one notification per event and subject per 15 minutes; an event turned off sends nothing.
        let first = await catalog.notify(.accessoryOffline, title: "Lamp", message: "gone", subject: "lamp")
        let again = await catalog.notify(.accessoryOffline, title: "Lamp", message: "gone", subject: "lamp")
        #expect(first?.count == 2)
        #expect(again == nil)
        #expect(await catalog.notify(.pluginError, title: "x", message: "y") == nil)
        // A successful backup waits to be turned on; a failed one goes.
        #expect(await catalog.notify(.backupSucceeded, title: "Backup", message: "saved") == nil)
        #expect(await catalog.notify(.backupFailed, title: "Backup", message: "failed")?.count == 2)
        // At most 5 tests a minute.
        for _ in 0..<3 { _ = try await catalog.sendTestNotification() }
        await #expect(throws: CatalogError.self) { try await catalog.sendTestNotification() }
    }

    @Test func pushesToSubscribedBrowsers() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let sender = RecordingSender()
        let catalog = environment.catalog
        catalog.home.http = sender
        let publicKey = try catalog.webPushPublicKey()
        #expect(WebPush.data(base64url: publicKey)?.count == 65)
        #expect(try catalog.webPushPublicKey() == publicKey)

        let browser = P256.KeyAgreement.PrivateKey()
        let auth = Data((0..<16).map { UInt8($0) })
        let endpoint = "https://fcm.googleapis.com/fcm/send/abc"
        let keys: JSONValue = ["p256dh": .string(WebPush.base64url(browser.publicKey.x963Representation)), "auth": .string(WebPush.base64url(auth))]
        #expect(throws: CatalogError.self) { try catalog.subscribeToPush(["endpoint": "http://fcm.googleapis.com/x", "keys": keys], username: "me") }
        // The bridge posts to the endpoint: never to a host of the user's choosing.
        for elsewhere in ["https://192.168.1.10/x", "https://router.local/x", "https://fcm.googleapis.com.evil.example/x", "https://fcm.googleapis.com:8443/x"] {
            #expect(throws: CatalogError.self, "\(elsewhere)") { try catalog.subscribeToPush(["endpoint": .string(elsewhere), "keys": keys], username: "me") }
        }
        let subscription = try catalog.subscribeToPush([
            "endpoint": .string(endpoint), "keys": ["p256dh": .string(WebPush.base64url(browser.publicKey.x963Representation)), "auth": .string(WebPush.base64url(auth))], "label": "Safari on macOS",
        ], username: "me")
        #expect(subscription["label"] == "Safari on macOS")
        _ = try catalog.updateNotificationSettings(["channels": ["browser": ["enabled": true]]])

        let result = try await catalog.sendTestNotification(channel: .browser)
        #expect(result["results"]?[0]?["ok"] == true)
        let request = try #require(sender.requests.first)
        #expect(request.url.absoluteString == endpoint)
        #expect(request.header("Content-Encoding") == "aes128gcm")
        let authorization = try #require(request.header("Authorization"))
        #expect(authorization.hasPrefix("vapid t=") && authorization.hasSuffix(", k=\(publicKey)"))

        // The browser can read it: decrypt with its key, as RFC 8291 says.
        let record = try #require(request.body)
        let salt = record.prefix(16)
        let keyLength = Int(record[record.startIndex + 20])
        let serverPublic = record.subdata(in: record.startIndex + 21..<record.startIndex + 21 + keyLength)
        let shared = try browser.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: serverPublic))
        let info = Data("WebPush: info\0".utf8) + browser.publicKey.x963Representation + serverPublic
        let ikm = shared.withUnsafeBytes { HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data($0)), salt: auth, info: info, outputByteCount: 32) }
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12).withUnsafeBytes { Data($0) }
        let sealed = record.suffix(from: record.startIndex + 21 + keyLength)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plain = try AES.GCM.open(box, using: cek)
        #expect(plain.last == 2)
        let payload = try JSONValue(data: plain.dropLast())
        #expect(payload["title"] == "Test Bridge: Test notification")
        #expect(payload["path"] == "/notifications")

        // A push service that forgot the subscription: it goes.
        sender.status = 410
        _ = try await catalog.sendTestNotification(channel: .browser)
        #expect(catalog.home.notifications.value.subscriptions.isEmpty)

        // One user fills at most five of the twenty places.
        for index in 0..<5 {
            _ = try catalog.subscribeToPush(["endpoint": .string("https://web.push.apple.com/\(index)"), "keys": keys], username: "me")
        }
        #expect(throws: CatalogError.self) { try catalog.subscribeToPush(["endpoint": "https://web.push.apple.com/6", "keys": keys], username: "me") }
        _ = try catalog.subscribeToPush(["endpoint": "https://updates.push.services.mozilla.com/wpush/v2/x", "keys": keys], username: "other")
    }

    @Test func notificationsOpenPagesOnTheBridgeOnly() {
        #expect(WebPush.localPath("/notifications") == "/notifications")
        #expect(WebPush.localPath("/logs/homeswift?since=24h") == "/logs/homeswift?since=24h")
        for elsewhere in [nil, "", "//evil.example", "/\\evil.example", "https://evil.example", "notifications", "/a\nb"] {
            #expect(WebPush.localPath(elsewhere) == "/", "\(String(describing: elsewhere))")
        }
    }

    /// Glass UI's encryptPayload (Node's crypto) with these keys and salt gives this record.
    @Test func encryptsAsGlassUI() throws {
        let server = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let salt = Data([0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00])
        let record = try WebPush.encrypt(Data(#"{"title":"Homeswift: Test","body":"It works"}"#.utf8),
            p256dh: "BAIX5hfwtkQ5KCePlpmeaaI6TywVK99tbN9m5bgCgtTtGUp968uXcS0t2jyoWqh2Wlb0X8dYWZZS8ol8ZTBuV5Q", auth: "ABEiM0RVZneImaq7zN3u_w", salt: salt, serverKey: server)
        #expect(record.base64EncodedString() == "Dw4NDAsKCQgHBgUEAwIBAAAAEABBBNZak5d8qj0bCBhS/1ennkZfFmBXcwS66tUF3TpIWJzzUBheiVNy32Ih6joTdVfkc/3bZ1XwW9UHw8Uz/OnJEoUInpuPCBqZTwp+j8eElFM38saToi0mR+G5/9QN9keBwv/VuSUASV+j7azlGWDamfX2Fb19bIPmofaWhIim0Q==")
    }

    @Test func signsVAPIDWithTheKeys() throws {
        let keys = WebPush.Keys.generate()
        #expect(keys.isValid)
        let header = try WebPush.authorization(endpoint: URL(string: "https://web.push.apple.com/abc")!, keys: keys, subject: "mailto:me@example.com", now: Date(timeIntervalSince1970: 1_000_000))
        let token = String(header.dropFirst("vapid t=".count).prefix { $0 != "," })
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let claims = try JSONValue(data: try #require(WebPush.data(base64url: parts[1])))
        #expect(claims["aud"] == "https://web.push.apple.com")
        #expect(claims["exp"] == .number(1_000_000 + 43_200))
        let publicKey = try P256.Signing.PublicKey(x963Representation: try #require(WebPush.data(base64url: keys.publicKey)))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(WebPush.data(base64url: parts[2])))
        #expect(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }
}
