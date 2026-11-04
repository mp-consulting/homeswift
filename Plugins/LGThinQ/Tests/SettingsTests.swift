import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftLGThinQ

/// Settings: a Homebridge block's `devices` allow list and its sign-in move into `_accessories` and the vault; a pasted
/// Homebridge block still loads, the canonical one too, with the same accessories.
@Suite(.timeLimit(.minutes(1)))
struct SettingsTests {
    static let known = [
        KnownDevice(id: acID, name: "Living Room", type: "AC", supported: true),
        KnownDevice(id: washerID, name: "Washer", type: "WASHER", supported: true),
        KnownDevice(id: stylerID, name: "Styler", type: "STYLER", supported: true),
        KnownDevice(id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", name: "TV", type: "TV", supported: false),
    ]

    /// Each entry's options move under its id, typed; its `name` becomes the Name where it is not LG's own; every
    /// appliance the list left out is Excluded; what `_accessories` has stays.
    @Test func theDevicesListMovesIntoAccessorySettings() throws {
        let block = try JSONValue(any: [
            "platform": "LGThinQ", "name": "LG ThinQ", "country": "US", "language": "en-US",
            "devices": [
                ["id": acID, "name": "Bedroom AC", "type": "AC", "serial_number": "SN-1", "ac_mode": "cooling", "ac_fan_control": "true",
                 "ac_energy_save": false, "ac_buttons": [["name": "Dry", "op_mode": "1"], ["name": "", "op_mode": 2]], "unknown": 1],
                ["id": washerID, "name": "Washer", "type": "WASHER", "washer_trigger": 1],
                ["name": "No id"],
            ],
            "_accessories": [washerID: ["washer_trigger": false]],
        ] as [String: Any])
        let canonical = LGThinQPlugin.canonical(block, devices: Self.known)
        #expect(canonical == (try JSONValue(any: [
            "platform": "LGThinQ", "name": "LG ThinQ", "country": "US", "language": "en-US",
            "_accessories": [
                acID: ["name": "Bedroom AC", "serial_number": "SN-1", "ac_mode": "COOLING", "ac_fan_control": true, "ac_energy_save": false,
                       "ac_buttons": [["name": "Dry", "op_mode": 1]]],
                washerID: ["washer_trigger": false],
                stylerID: ["excluded": true],
            ],
        ] as [String: Any])))
        // Canonical already: unchanged.
        #expect(LGThinQPlugin.canonical(canonical, devices: Self.known) == canonical)
        // Without the account's appliances the allow list cannot be read: it stays. An empty one ran them all: it goes.
        #expect(LGThinQPlugin.canonical(block, devices: nil) == block)
        let empty = try JSONValue(any: ["platform": "LGThinQ", "devices": [Any]()] as [String: Any])
        #expect(LGThinQPlugin.canonical(empty, devices: nil) == ["platform": "LGThinQ"])
    }

    /// The running instance answers the canonical block from the appliances LG listed, the refresh token moved into the
    /// vault, and each appliance's Device Kind.
    @Test func theRunningInstanceWritesTheCanonicalBlock() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "online": true], model: [:])
        environment.lg.add(device: ["deviceId": .string(ovenID), "deviceType": 301, "alias": "Oven", "online": true], model: [:])
        var settings = LGTestEnvironment.defaultSettings
        settings["username"] = "me@example.com"
        settings["devices"] = [["id": stylerID, "name": "Styler", "type": "STYLER", "serial_number": "SN-9"]]
        let host = try await environment.start(settings: settings)
        defer { Task { await host.stop() } }
        #expect(await environment.accessory(host, id: stylerID) != nil)
        let context = try #require(host.context(platform: LGThinQPlugin.platform, name: "LG ThinQ"))
        #expect(context.credentials() == nil)

        let block = try JSONValue(any: settings.merging(["platform": "LGThinQ", "name": "LG ThinQ"]) { $1 })
        let canonical = await host.canonicalSettings(platform: LGThinQPlugin.platform, name: "LG ThinQ", block: block)
        #expect(canonical == (try JSONValue(any: [
            "platform": "LGThinQ", "name": "LG ThinQ", "country": "US", "language": "en-US",
            "_accessories": [stylerID: ["serial_number": "SN-9"], ovenID: ["excluded": true]],
        ] as [String: Any])))
        // Outside a settings write the vault gets the sign-in at once.
        #expect(context.credentials() == ["refreshToken": "refresh-1", "username": "me@example.com"])
        #expect(await host.deviceKind(platform: LGThinQPlugin.platform, name: "LG ThinQ", deviceID: ovenID) == "OVEN")
        #expect(await host.deviceKind(platform: LGThinQPlugin.platform, name: "LG ThinQ", deviceID: stylerID) == "STYLER")
    }

    /// A block that signs in with a password keeps it until it has signed in: then the refresh token it got goes in the
    /// vault and the block's sign-in goes.
    @Test func aPasswordLeavesTheBlockOnceItSignedIn() async throws {
        let environment = LGTestEnvironment()
        environment.lg.override("lgemembers.com") { request in
            let url = request.url.absoluteString
            if url.contains("signInAct") { return FakeLG.json(["account": ["loginSessionID": "s", "userID": "u", "userIDType": "LGE"]]) }
            if url.contains("signInComplete") { return FakeLG.json(["code": "SUCCESS"]) }
            if url.contains("/oauth") { return FakeLG.json(["redirect_uri": "lgaccount.lgsmartthinq:/?code=c"]) }
            return FakeLG.json([:], cookies: ["JSESSIONID=x"])
        }
        environment.lg.override("us.lgeapi.com/oauth") { _ in FakeLG.json(["access_token": "from-code", "refresh_token": "refresh-new", "expires_in": 3600]) }
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "online": true], model: [:])
        let settings: [String: Any] = ["auth_mode": "account", "username": "me@example.com", "password": "secret", "country": "US", "language": "en-US"]
        let host = try await environment.start(settings: settings)
        defer { Task { await host.stop() } }
        #expect(await environment.accessory(host, id: stylerID) != nil)
        let block = try JSONValue(any: settings.merging(["platform": "LGThinQ", "name": "LG ThinQ"]) { $1 })
        let canonical = await host.canonicalSettings(platform: LGThinQPlugin.platform, name: "LG ThinQ", block: block)
        #expect(canonical == ["platform": "LGThinQ", "name": "LG ThinQ", "auth_mode": "account", "country": "US", "language": "en-US"])
        let context = try #require(host.context(platform: LGThinQPlugin.platform, name: "LG ThinQ"))
        #expect(context.credentials() == ["refreshToken": "refresh-new", "username": "me@example.com"])
    }

    /// The canonical block runs the same appliances, with the same accessories and aids, as the Homebridge one it came
    /// from; an appliance's Accessory Settings overrule its Homebridge entry's options.
    @Test func theCanonicalBlockKeepsTheAccessories() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "online": true], model: [:])
        environment.lg.add(device: ["deviceId": .string(ovenID), "deviceType": 203, "alias": "Second styler", "online": true], model: [:])
        var legacy = LGTestEnvironment.defaultSettings
        legacy["devices"] = [["id": stylerID, "serial_number": "OLD"]]
        legacy["_accessories"] = [stylerID: ["serial_number": "NEW"]]
        let first = try await environment.start(settings: legacy)
        let accessory = try #require(await environment.accessory(first, id: stylerID))
        #expect(accessory.information[.serialNumber]?.value == "NEW")
        let aid = accessory.aid
        #expect(!first.mainBridge.server.accessories.contains { $0.id == "LGThinQ:\(ovenID)" })
        let block = try JSONValue(any: legacy.merging(["platform": "LGThinQ", "name": "LG ThinQ"]) { $1 })
        let canonical = await first.canonicalSettings(platform: LGThinQPlugin.platform, name: "LG ThinQ", block: block)
        await first.stop()

        var settings = try #require(try JSONSerialization.jsonObject(with: canonical.encoded()) as? [String: Any])
        settings.removeValue(forKey: "platform")
        settings.removeValue(forKey: "name")
        let second = try await environment.start(settings: settings)
        defer { Task { await second.stop() } }
        let again = try #require(await environment.accessory(second, id: stylerID))
        #expect(again.aid == aid && again.information[.serialNumber]?.value == "NEW")
        #expect(!second.mainBridge.server.accessories.contains { $0.id == "LGThinQ:\(ovenID)" })
    }
}
