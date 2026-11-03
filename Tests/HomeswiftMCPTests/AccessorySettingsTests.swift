import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

private let accept: JSONValue = ["action": "accept", "content": ["confirm": true]]

/// Accessory Settings and Plugin Settings through `get_settings` and `update_settings` (Settings.swift): the Core
/// Accessory Settings in the block's `_accessories`, the live ones applied without reloading the plugin, the legacy
/// places read and migrated, the plugin's declarations checked (docs/adr/0002, 0003).
@Suite(.timeLimit(.minutes(1)))
struct AccessorySettingsTests {
    /// The devices plugin's schema: a Plugin Setting that is a plugin-wide default, and three Plugin Accessory Settings,
    /// one only for cameras.
    static let schema = """
        {
          "pluginAlias": "Devices",
          "schema": { "type": "object", "properties": {
            "name": { "type": "string" }, "token": { "type": "password" }, "mirroredBulb": { "type": "boolean" },
            "pollingRate": { "type": "integer", "minimum": 250 }, "defaultFade": { "type": "integer" }
          } },
          "accessorySchema": { "properties": {
            "offset": { "type": "number", "minimum": -5, "maximum": 5, "title": "Offset", "description": "Added to the reading" },
            "fade": { "type": "integer", "minimum": 0, "x-default": "defaultFade", "title": "Fade", "description": "How long it fades" },
            "motionSeconds": { "type": "integer", "x-kinds": ["camera"], "title": "Motion", "description": "How long motion lasts" }
          } }
        }
        """

    static func config(_ extra: String = "") -> String {
        """
        {
          "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:59", "pin": "031-45-154", "port": 0 },
          "platforms": [
            { "platform": "Devices", "name": "Devices", "mirroredBulb": true, "token": "secret-token", "defaultFade": 400\(extra) },
            { "platform": "Ghost", "name": "Nobody" },
            { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": false, "token": "mcp-token" } } }
          ]
        }
        """
    }

    func config(_ environment: MCPTestEnvironment) throws -> JSONValue { try JSONValue(data: Data(contentsOf: environment.configURL)) }
    func block(_ environment: MCPTestEnvironment) throws -> JSONValue? { try config(environment)["platforms"]?[0] }

    func environment(_ extra: String = "") async throws -> MCPTestEnvironment {
        let environment = try MCPTestEnvironment(config: Self.config(extra), schema: Self.schema)
        try await environment.start()
        return environment
    }

    func update(_ environment: MCPTestEnvironment, _ id: String, _ settings: [String: JSONValue]) async throws -> JSONValue {
        try await environment.catalog.updateAccessorySettings([(id, settings)], who: "test")
    }

    // MARK: Name

    @Test func renamesInTheBlockAndKeepsTheNameAcrossARestart() async throws {
        let environment = try await environment()
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        // A name the web UI showed instead goes once the Name is set: there is one name now.
        try environment.catalog.home.layout.update { $0.accessories["Devices:lamp"] = AccessoryLayout.Entry(name: "Old Display Name") }

        let result = try await client.tool("update_settings", ["accessory": "Devices:lamp", "settings": ["name": "  Reading   Lamp "]], answer: accept)
        #expect(result["isError"] != true)
        #expect(result["structuredContent"]?["accessories"]?[0]?["changed"] == ["name"])
        #expect(result["structuredContent"]?["reloaded"] == [])
        #expect(try block(environment)?["_accessories"] == ["lamp": ["name": "Reading Lamp"]])
        let lamp = try #require(environment.catalog.find(id: "Devices:lamp")).accessory
        #expect(lamp.name == "Reading Lamp")
        #expect(lamp[.lightbulb]?[.configuredName]?.value == .string("Reading Lamp"))
        #expect(environment.catalog.home.layout.value.accessories["Devices:lamp"] == nil)
        #expect(environment.auditEntries.contains { $0["tool"] == "update_settings" })

        // Another controller's accessory has its Name there.
        let mirrored = try await client.tool("update_settings", ["accessory": "Devices:mirrored", "settings": ["name": "Ceiling"]], answer: accept)
        #expect(mirrored["isError"] == true)
        await environment.stop()

        // The next run reads the name from its block.
        let saved = try #require(try block(environment)?["_accessories"])
        let restarted = try MCPTestEnvironment(config: Self.config(#", "_accessories": \#(saved.text())"#), schema: Self.schema)
        try await restarted.start()
        let again = try #require(restarted.catalog.find(id: "Devices:lamp")).accessory
        #expect(again.name == "Reading Lamp" && again[.lightbulb]?[.configuredName]?.value == .string("Reading Lamp"))

        // Cleared: the plugin's name again, and the block as it was.
        _ = try await update(restarted, "Devices:lamp", ["name": nil])
        #expect(try block(restarted)?["_accessories"] == nil)
        #expect(again.name == "Desk Lamp" && again[.lightbulb]?[.configuredName]?.value == .string("Desk Lamp"))
        await restarted.stop()
    }

    /// The Home app renames an accessory by writing its Configured Name: kept as its Name in config.json.
    @Test func keepsARenameFromTheHomeApp() async throws {
        let environment = try await environment()
        let lock = try #require(environment.catalog.find(id: "Devices:lock")).accessory
        _ = try await update(environment, "Devices:lock", ["name": "Back Door"])
        let configuredName = try #require(lock[.lockMechanism]?[.configuredName])

        try await configuredName.write(.string("Garden Door"))
        #expect(await eventually { (try? block(environment)?["_accessories"]?["lock"]?["name"]) == "Garden Door" })
        #expect(await eventually { lock.name == "Garden Door" })
        await environment.stop()
    }

    // MARK: Live settings

    /// Name, room, Hidden and Not in Home never reach the plugin: changing them reloads nothing, and the accessory stays
    /// the same object. Excluded and the plugin's own settings reload it.
    @Test func liveSettingsDoNotReloadThePlugin() async throws {
        let environment = try await environment()
        let before = try #require(environment.catalog.find(id: "Devices:lamp")).accessory
        let live = try await update(environment, "Devices:lamp", ["room": "Office", "hidden": true, "notInHome": true, "name": "Desk"])
        #expect(live["reloaded"] == [])
        #expect(try block(environment)?["_accessories"]?["lamp"] == ["name": "Desk", "room": "Office", "hidden": true, "notInHome": true])
        let found = try #require(environment.catalog.find(id: "Devices:lamp"))
        #expect(found.accessory === before)
        #expect(found.room == "Office" && found.layout?.hidden == true)
        #expect(found.bridge.server.isHiddenFromHomeKit("Devices:lamp"))
        #expect(environment.catalog.layoutJSON()["rooms"]?[0]?["name"] == "Office")
        #expect(environment.catalog.home.layout.value.rooms == ["Office"])
        #expect(environment.catalog.located(matching: HomeswiftCatalog.AccessoryFilter(["room": "office"])).map(\.accessory.id) == ["Devices:lamp"])

        // false is the default: left out.
        _ = try await update(environment, "Devices:lamp", ["hidden": false, "notInHome": false])
        #expect(try block(environment)?["_accessories"]?["lamp"] == ["name": "Desk", "room": "Office"])
        #expect(await eventually { !(environment.catalog.find(id: "Devices:lamp")?.bridge.server.isHiddenFromHomeKit("Devices:lamp") ?? true) })

        let reloading = try await update(environment, "Devices:lamp", ["offset": 1.5])
        #expect(reloading["reloaded"] == ["Devices"])
        #expect(try block(environment)?["_accessories"]?["lamp"]?["offset"] == 1.5)
        #expect(await eventually { environment.catalog.find(id: "Devices:lamp")?.accessory !== before })
        await environment.stop()
    }

    /// Room, Hidden and a display name in accessory-layout.json are read while the settings have none, and room and Hidden
    /// move into the settings on the accessory's next write; the display name goes once a Name is set.
    @Test func readsTheLegacyLayoutAndMigratesOnWrite() async throws {
        let environment = try await environment()
        try environment.catalog.home.layout.update { layout in
            layout.rooms = ["Office"]
            layout.accessories["Devices:lamp"] = AccessoryLayout.Entry(room: "Office", hidden: true, name: "Old Lamp", favourite: true)
        }
        let found = try #require(environment.catalog.find(id: "Devices:lamp"))
        #expect(found.room == "Office" && found.layout?.hidden == true && found.layout?.name == "Old Lamp")
        let read = try await environment.catalog.accessorySettingsJSON(accessoryID: "Devices:lamp")
        #expect(read["settings"] == ["room": "Office", "hidden": true, "name": "Old Lamp"])

        _ = try await update(environment, "Devices:lamp", ["notInHome": true])
        #expect(try block(environment)?["_accessories"]?["lamp"] == ["room": "Office", "hidden": true, "notInHome": true])
        #expect(environment.catalog.home.layout.value.accessories["Devices:lamp"] == AccessoryLayout.Entry(name: "Old Lamp", favourite: true))
        #expect(environment.catalog.find(id: "Devices:lamp")?.room == "Office")

        _ = try await update(environment, "Devices:lamp", ["name": "Desk"])
        #expect(environment.catalog.home.layout.value.accessories["Devices:lamp"] == AccessoryLayout.Entry(favourite: true))
        #expect(environment.catalog.find(id: "Devices:lamp")?.layout?.name == nil)
        await environment.stop()
    }

    /// A block's `_hiddenFromHomeKit` keeps applying, and moves into `_accessories` as Not in Home with the block's next
    /// settings write.
    @Test func migratesHiddenFromHomeKit() async throws {
        let environment = try await environment(#", "_hiddenFromHomeKit": ["Devices:lock"]"#)
        let lock = try #require(environment.catalog.find(id: "Devices:lock"))
        #expect(lock.bridge.server.isHiddenFromHomeKit("Devices:lock"))
        #expect(try await environment.catalog.accessorySettingsJSON(accessoryID: "Devices:lock")["settings"]?["notInHome"] == true)

        let answer = try await update(environment, "Devices:lamp", ["room": "Hall"])
        #expect(answer["reloaded"] == [])
        let written = try #require(try block(environment))
        #expect(written["_hiddenFromHomeKit"] == nil)
        #expect(written["_accessories"] == ["lock": ["notInHome": true], "lamp": ["room": "Hall"]])
        #expect(lock.bridge.server.isHiddenFromHomeKit("Devices:lock"))
        await environment.stop()
    }

    /// Each settings write puts the block in its plugin's canonical shape first (`canonicalSettings`).
    @Test func writesTheCanonicalShape() async throws {
        let environment = try await environment(#", "legacyExcluded": ["lock"]"#)
        _ = try await update(environment, "Devices:lamp", ["room": "Hall"])
        let written = try #require(try block(environment))
        #expect(written["legacyExcluded"] == nil)
        #expect(written["_accessories"]?["lock"] == ["excluded": true])
        #expect(await eventually { environment.catalog.find(id: "Devices:lock") == nil })
        await environment.stop()
    }

    // MARK: Rooms

    /// Renaming a room renames it in every accessory's settings, across blocks; removing it takes them out of it.
    @Test func roomRenameRewritesSettings() async throws {
        let environment = try await environment()
        _ = try await environment.catalog.updateAccessorySettings([("Devices:lamp", ["room": "Office"]), ("Ghost:thing", ["room": "office"])], who: "test")
        #expect(try config(environment)["platforms"]?[1]?["_accessories"] == ["thing": ["room": "Office"]])

        _ = try await environment.catalog.updateLayout(["renameRoom": ["from": "Office", "to": "Study"]], by: "test")
        #expect(try block(environment)?["_accessories"]?["lamp"]?["room"] == "Study")
        #expect(try config(environment)["platforms"]?[1]?["_accessories"]?["thing"]?["room"] == "Study")
        #expect(environment.catalog.find(id: "Devices:lamp")?.room == "Study")

        _ = try await environment.catalog.updateLayout(["removeRooms": ["study"]], by: "test")
        #expect(try block(environment)?["_accessories"] == nil)
        #expect(try config(environment)["platforms"]?[1]?["_accessories"] == nil)
        #expect(environment.catalog.find(id: "Devices:lamp")?.room == nil)

        // The Arrangement keeps only favourites per accessory.
        let refused = await #expect(throws: CatalogError.self) { try await environment.catalog.updateLayout(["accessories": ["Devices:lamp": ["room": "Hall"]]], by: "test") }
        #expect(refused?.message.contains("update_settings") == true)
        _ = try await environment.catalog.updateLayout(["accessories": ["Devices:lamp": ["favourite": true]]], by: "test")
        #expect(environment.catalog.find(id: "Devices:lamp")?.layout?.favourite == true)
        await environment.stop()
    }

    /// Room Sync is a Bridge Setting: read from the layout's old place while the bridge block says nothing, written to
    /// the bridge block, and applied without a restart.
    @Test func roomSyncIsABridgeSettingWithoutRestart() async throws {
        let environment = try await environment()
        try environment.catalog.home.layout.update { $0.syncRoomNames = true }
        #expect(environment.catalog.roomSync)

        _ = try await environment.catalog.updateLayout(["syncRoomNames": false], by: "test")
        #expect(!environment.catalog.roomSync)
        #expect(environment.catalog.home.layout.value.syncRoomNames == nil)
        let on = try await environment.catalog.updateLayout(["syncRoomNames": true], by: "test")
        #expect(on["syncRoomNames"] == true)
        #expect(try config(environment)["bridge"]?["roomSync"] == true)
        #expect(environment.catalog.host.configuration.roomSync == true)
        #expect(environment.catalog.restartNeeded.withLockedValue { $0 } == false)

        let report = await environment.host.apply(try HomeswiftConfiguration.decode(Data(Self.config().replacingOccurrences(of: #""port": 0 }"#, with: #""port": 0, "roomSync": false }"#).utf8)))
        #expect(report.needsRestart.isEmpty)
        await environment.stop()
    }

    /// A mirrored accessory (Wingman's): its Name is read-only, it cannot leave Apple Home here, and moving it moves it on
    /// its hub whether Room Sync is on or not.
    @Test func mirroredAccessoryRules() async throws {
        let environment = try await environment()
        #expect(!environment.catalog.roomSync)
        await #expect(throws: CatalogError.self) { try await update(environment, "Devices:mirrored", ["name": "Ceiling"]) }
        await #expect(throws: CatalogError.self) { try await update(environment, "Devices:mirrored", ["notInHome": true]) }
        let moved = try await update(environment, "Devices:mirrored", ["room": "Kitchen"])
        #expect(moved["hubMoves"] == [["hub": "Devices:Devices", "name": "Devices", "accessory": "Devices:mirrored", "room": "Kitchen", "moved": true]])
        #expect(environment.hubMoves.withLockedValue { $0 }["Devices:mirrored"] == "Kitchen")
        // The lamp is not mirrored: with Room Sync off it moves in Homeswift only.
        #expect(try await update(environment, "Devices:lamp", ["room": "Kitchen"])["hubMoves"] == nil)
        let read = try await environment.catalog.accessorySettingsJSON(accessoryID: "Devices:mirrored")
        #expect(read["fields"]?["name"]?["readOnly"] == true && read["mirroredFrom"] == "Apple Home")
        await environment.stop()
    }

    // MARK: Declarations

    /// The writers check every key: Core Accessory Settings by type, the plugin's own against `accessorySchema`, a key it
    /// does not declare or one for another Device Kind refused. A raw write lets an undeclared key through (an older
    /// block still saves) but checks what is declared.
    @Test func checksAccessorySettingsAgainstTheSchema() async throws {
        let environment = try await environment()
        let catalog = environment.catalog
        func problems(_ body: () async throws -> JSONValue) async -> [String] {
            do {
                _ = try await body()
                return []
            } catch let error as ConfigSchemaError {
                return error.problems.map(\.text)
            } catch {
                return ["\(error)"]
            }
        }
        #expect(await problems { try await update(environment, "Devices:lamp", ["offset": 9]) } == ["_accessories.lamp.offset must be <= 5"])
        #expect(await problems { try await update(environment, "Devices:lamp", ["colour": "red"]) } == ["_accessories.lamp.colour is not an Accessory Setting the plugin declares (its schema's accessorySchema)"])
        #expect(await problems { try await update(environment, "Devices:lamp", ["motionSeconds": 30]) } == ["_accessories.lamp.motionSeconds is not an Accessory Setting of a light (only of camera)"])
        #expect(await problems { try await update(environment, "Devices:lamp", ["hidden": "yes"]) } == ["_accessories.lamp.hidden must be true or false"])
        #expect(await problems { try await update(environment, "Devices:lamp", ["parts": ["Night": 1]]) } == ["_accessories.lamp.parts must be an object of true or false by part"])
        #expect(await problems { try await update(environment, "Devices:lamp", ["fade": 200]) }.isEmpty)

        let raw = { (entry: JSONValue) in { try await catalog.editBlock(platform: "Devices", name: "Devices", dryRun: false) { $0["_accessories"] = ["lamp": entry] } } }
        #expect(await problems(raw(["legacyKey": 1, "fade": 200])).isEmpty)
        #expect(await problems(raw(["legacyKey": 1, "fade": -1])) == ["_accessories.lamp.fade must be >= 0"])
        #expect(await problems(raw(["excluded": "no"])) == ["_accessories.lamp.excluded must be true or false"])
        // Skipped only when asked.
        _ = try await catalog.editBlock(platform: "Devices", name: "Devices", dryRun: false, checkSchemas: false) { $0["_accessories"] = ["lamp": ["fade": -1]] }

        // The declaration itself.
        #expect(HomeswiftCatalog.accessorySchemaProblems(try JSONValue(string: Self.schema)).isEmpty)
        let bad: JSONValue = ["schema": ["properties": ["a": ["type": "integer"]]], "accessorySchema": ["properties": [
            "room": ["type": "string"], "x": ["type": "integer", "x-kinds": "camera", "x-default": "nothing"],
        ]]]
        #expect(HomeswiftCatalog.accessorySchemaProblems(bad) == [
            "accessorySchema.room is a Core Accessory Setting or a runtime key",
            "accessorySchema.x.x-kinds must be a list of Device Kinds", "accessorySchema.x.x-default names nothing, which the schema does not declare",
        ])
        await environment.stop()
    }

    /// Every plugin's schema declares its Plugin Accessory Settings well.
    @Test func everyPluginsAccessorySchemaIsWellFormed() throws {
        let plugins = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Plugins")
        for name in try FileManager.default.contentsOfDirectory(atPath: plugins.path) {
            let file = plugins.appendingPathComponent(name).appendingPathComponent("config.schema.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            #expect(HomeswiftCatalog.accessorySchemaProblems(try JSONValue(data: data)) == [], "\(name)")
        }
    }

    /// `get_settings` answers the values and the fields for the device's kind, each with its plugin-wide default.
    @Test func getSettingsAnswersFieldsForTheKind() async throws {
        let environment = try await environment()
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        _ = try await update(environment, "Devices:lamp", ["offset": 1, "room": "Office"])
        let answer = try #require(try await client.tool("get_settings", ["accessory": "Devices:lamp"])["structuredContent"])
        #expect(answer["kind"] == "light" && answer["platform"] == "Devices" && answer["instance"] == "Devices" && answer["key"] == "lamp")
        #expect(answer["settings"] == ["offset": 1, "room": "Office"])
        let fields = try #require(answer["fields"]?.objectValue)
        #expect(Set(fields.keys) == ["name", "room", "hidden", "notInHome", "excluded", "parts", "offset", "fade"])
        #expect(fields["room"]?["core"] == true && fields["offset"]?["core"] == false)
        #expect(fields["fade"]?["default"] == ["setting": "defaultFade", "value": 400])

        // A device not on the bridge, by its Accessory Id.
        _ = try await update(environment, "Devices:lock", ["excluded": true])
        #expect(await eventually { environment.catalog.find(id: "Devices:lock") == nil })
        let excluded = try await environment.catalog.accessorySettingsJSON(accessoryID: "Devices:lock")
        #expect(excluded["settings"] == ["excluded": true] && excluded["onBridge"] == false)
        _ = try await update(environment, "Devices:lock", ["excluded": false])
        #expect(await eventually { environment.catalog.find(id: "Devices:lock") != nil })
        #expect(try block(environment)?["_accessories"]?["lock"] == nil)
        await environment.stop()
    }

    /// Plugin Settings: read with secrets as handles, merged on write (null clears), checked, the runtime's keys and
    /// undeclared ones refused.
    @Test func pluginSettings() async throws {
        let environment = try await environment()
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let read = try #require(try await client.tool("get_settings", ["plugin": ["platform": "Devices"]])["structuredContent"])
        #expect(read["settings"]?["defaultFade"] == 400)
        #expect(read["settings"]?["token"]?.stringValue?.hasPrefix("__SECRET_") == true)
        #expect(read["accessorySchema"]?["properties"]?["offset"] != nil && read["settings"]?["_accessories"] == nil)

        let token = try #require(read["settings"]?["token"])
        let changed = try await client.tool("update_settings", ["plugin": ["platform": "Devices"], "settings": ["pollingRate": 500, "defaultFade": nil, "token": token]], answer: accept)
        #expect(changed["isError"] != true)
        #expect(changed["structuredContent"]?["changed"] == ["defaultFade", "pollingRate"])
        #expect(changed["structuredContent"]?["reloaded"] == ["Devices"])
        let written = try #require(try block(environment))
        #expect(written["pollingRate"] == 500 && written["defaultFade"] == nil)
        // The handle became the secret again: the running block has it, opened.
        let running = try #require(environment.host.configuration.platforms.first { $0.platform == "Devices" })
        #expect(try JSONValue(data: running.json)["token"] == "secret-token")

        let refused = try await client.tool("update_settings", ["plugin": ["platform": "Devices"], "settings": ["pollingRate": 1]], answer: accept)
        #expect(refused["isError"] == true)
        await #expect(throws: CatalogError.self) { try await environment.catalog.updatePluginSettings(platform: "Devices", settings: ["_paused": true]) }
        await #expect(throws: CatalogError.self) { try await environment.catalog.updatePluginSettings(platform: "Devices", settings: ["colour": "red"]) }
        await environment.stop()
    }

    /// The tools the settings tools replace are gone.
    @Test func theOldToolsAreGone() async throws {
        let environment = try await environment()
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let names = Set(try await client.call("tools/list")["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        #expect(names.isDisjoint(with: ["rename_accessory", "set_homekit_visibility", "set_device_excluded", "set_device_part", "put_list_entry"]))
        #expect(names.isSuperset(of: ["get_settings", "update_settings", "set_accessory_layout", "patch_config", "update_config", "get_config", "restore_config"]))
        await environment.stop()
    }
}
