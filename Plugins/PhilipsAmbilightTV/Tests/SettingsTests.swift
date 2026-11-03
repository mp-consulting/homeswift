import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftNetwork
@testable import HomeswiftPhilipsAmbilightTV

/// Settings: a Homebridge block's paired TVs move from `devices` into `_accessories` by MAC, their keys into the vault;
/// TVs to pair by address stay in `devices`. Both shapes run the TV with the same accessory and the same HAP server.
@Suite(.timeLimit(.minutes(1)))
struct SettingsTests {
    let environment = PhilipsTestEnvironment()

    static func json(_ value: [String: Any]) throws -> JSONValue { try JSONValue(any: value) }

    /// A paired entry's options go under its MAC, uppercase as its accessory's id, its `name` as the Name, its keys
    /// answered for the vault; an entry with only an address goes into the paired TV Setup found there; TVs to pair,
    /// MACs that are not ones and keys that cannot be read stay. What `_accessories` has stays.
    @Test func thePairedTVsMoveIntoAccessorySettings() throws {
        var unreadable = livingRoom
        unreadable["mac"] = "11:22:33:44:55:66"
        unreadable["password"] = "vault:elsewhere"
        let block = try Self.json([
            "platform": "PhilipsAmbilightTV", "name": "Philips TVs",
            "devices": [
                livingRoom,
                ["name": "Kitchen TV", "ip": "192.168.1.40", "pollingInterval": 2000],
                ["name": "To pair", "ip": "192.168.1.50"],
                ["name": "Bad", "mac": "nope", "ip": "192.168.1.60", "username": "u", "password": "p"],
                unreadable,
            ],
            "_accessories": [
                "AA:BB:CC:DD:EE:FF": ["wakeOnLanEnabled": true],
                "0A:0B:0C:0D:0E:0F": ["name": "Kitchen TV", "ip": "192.168.1.40"],
            ],
        ])
        let (canonical, keys) = PhilipsAmbilightTVPlugin.canonical(block, hasKeys: { $0 == "0A:0B:0C:0D:0E:0F" }) { _, written in
            PhilipsAmbilightTVPlugin.isReference(written.password) ? nil : written
        }
        let living = try #require(canonical["_accessories"]?["AA:BB:CC:DD:EE:FF"]?.objectValue)
        #expect(living["name"] == "Living Room TV" && living["ip"] == "192.168.1.20" && living["pollingInterval"] == 1000)
        // What was there stays.
        #expect(living["wakeOnLanEnabled"] == true)
        let buttons = try JSONValue(any: livingRoom["customButtons"]!), sources = try JSONValue(any: livingRoom["sources"]!)
        #expect(living["customButtons"] == buttons && living["sources"] == sources)
        #expect(living["username"] == nil && living["password"] == nil && living["certFingerprint"] == nil && living["mac"] == nil)
        #expect(canonical["_accessories"]?["0A:0B:0C:0D:0E:0F"] == ["name": "Kitchen TV", "ip": "192.168.1.40", "pollingInterval": 2000])
        #expect(keys == ["AA:BB:CC:DD:EE:FF": PhilipsAmbilightTVPlugin.TVCredentials(username: "user1", password: "secret", certFingerprint: FakeTV.fingerprint)])
        #expect(canonical["devices"]?.arrayValue?.map { $0["name"] } == ["To pair", "Bad", "Living Room TV"])
        // Canonical already: nothing more moves.
        let again = PhilipsAmbilightTVPlugin.canonical(canonical, hasKeys: { $0 == "0A:0B:0C:0D:0E:0F" || $0 == "AA:BB:CC:DD:EE:FF" }) { _, _ in nil }
        #expect(again.block == canonical && again.keys.isEmpty)
    }

    /// The running instance answers the canonical block and keeps the keys in the vault once it is written; the canonical
    /// block then runs the TV with the same accessory id, HAP server and options, its keys from the vault.
    @Test func theCanonicalBlockKeepsTheTelevision() async throws {
        let first = try await environment.start(settings: ["devices": [livingRoom]])
        #expect(await eventually { first.bridges.count == 2 })
        let server = first.bridges[1].server
        #expect(server.primary.id == tvID)
        let deviceID = server.deviceID
        #expect(server.primary.service(.motionSensor, subtype: "state-sensor-mute") != nil)
        #expect(await first.deviceKind(platform: PhilipsAmbilightTVPlugin.platform, name: "Philips TVs", deviceID: "AA:BB:CC:DD:EE:FF") == "tv")

        let block = try Self.json(["platform": "PhilipsAmbilightTV", "name": "Philips TVs", "devices": [livingRoom]])
        let canonical = await first.canonicalSettings(platform: PhilipsAmbilightTVPlugin.platform, name: "Philips TVs", block: block)
        #expect(canonical["devices"] == nil && canonical["_accessories"]?["AA:BB:CC:DD:EE:FF"]?["stateSensors"] == ["power", "ambilight", "mute"])
        let context = try #require(first.context(platform: PhilipsAmbilightTVPlugin.platform, name: "Philips TVs"))
        #expect(context.credentials(for: "AA:BB:CC:DD:EE:FF") == ["username": "user1", "password": "secret", "certFingerprint": .string(FakeTV.fingerprint)])
        await first.stop()

        var settings = try #require(try JSONSerialization.jsonObject(with: canonical.encoded()) as? [String: Any])
        settings.removeValue(forKey: "platform")
        settings.removeValue(forKey: "name")
        let second = try await environment.start(settings: settings)
        defer { Task { await second.stop() } }
        #expect(await eventually { second.bridges.count == 2 })
        let again = second.bridges[1].server
        #expect(again.primary.id == tvID && again.deviceID == deviceID)
        #expect(again.primary.service(.motionSensor, subtype: "state-sensor-mute") != nil)
        let running = try #require(environment.plugin)
        let devices = await running.configuredDevices()
        #expect(devices.count == 1 && devices.first?.password == "secret" && devices.first?.pollingInterval == 1000 && devices.first?.name == "Living Room TV")
        #expect(try await running.discover().first { $0.deviceID == "AA:BB:CC:DD:EE:FF" }.map { $0.isSetUp && $0.kind == "tv" } == true)
    }

    /// A TV's Accessory Settings overrule its Homebridge entry's options.
    @Test func aTVsAccessorySettingsOverruleItsEntry() async throws {
        let host = try await environment.start(settings: ["devices": [livingRoom], "_accessories": ["AA:BB:CC:DD:EE:FF": ["stateSensors": ["power"], "pollingInterval": 2000]]])
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let devices = await plugin.configuredDevices()
        #expect(devices.first?.stateSensors == ["power"] && devices.first?.pollingInterval == 2000 && devices.first?.ambilightHueSwitch == true)
    }

    /// The schema declares a TV's settings, and of the Plugin Settings only the TVs to find by address; the page and the
    /// schema are embedded as they are.
    @Test func theSchemaDeclaresTheAccessorySettings() throws {
        let schema = try JSONValue(string: try #require(PhilipsAmbilightTVPlugin.configurationSchemaJSON))
        let fields = try #require(schema["accessorySchema"]?["properties"]?.objectValue)
        #expect(Set(fields.keys) == Set(PhilipsAmbilightTVPlugin.accessoryKeys))
        let properties = try #require(schema["schema"]?["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["name", "devices"])
        #expect(Set(properties["devices"]?["items"]?["properties"]?.objectValue?.keys.map { $0 } ?? []) == ["name", "ip", "mac"])

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(PhilipsAmbilightTVPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
                "run: swift Scripts/embed-assets.swift plugin Plugins/PhilipsAmbilightTV PhilipsAmbilightTVPlugin")
        let web = root.appendingPathComponent("Web")
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) where !name.hasPrefix(".") {
            let page = try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)
            #expect(PhilipsAmbilightTVPlugin.webFiles[name]?.body == page,
                    "run: swift Scripts/embed-assets.swift web Plugins/PhilipsAmbilightTV/Web Plugins/PhilipsAmbilightTV/Sources/WebFiles.swift PhilipsAmbilightTVPlugin (\(name))")
        }
        // The page writes no settings.
        let script = try #require(PhilipsAmbilightTVPlugin.webFiles["app.js"]?.body)
        #expect(!script.contains("updateBlock") && !script.contains("readBlock") && !script.contains("PATCH"))
    }
}
