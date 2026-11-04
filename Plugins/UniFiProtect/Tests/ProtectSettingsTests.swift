import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// The canonical shape (ProtectCanonicalSettings.swift): the catalog's options as Accessory Settings and Plugin Settings,
/// a running controller's `controllers` entry as its Accessory Settings with its login in the vault, its camera
/// overrides as each third-party camera's settings, and the Device Kinds.
@Suite(.timeLimit(.minutes(1)))
struct ProtectSettingsTests {
    static let nvr = Fixtures.nvrMAC
    static let known = [
        UniFiProtectPlugin.KnownController(
            mac: nvr, address: "192.168.1.1",
            devices: [(Fixtures.cameraMAC, "camera"), (Fixtures.sensorMAC, "sensor"), (Fixtures.lightMAC, "light"), ("F23E23931F5C", "thirdPartyCamera")]),
    ]

    /// Each kind of option goes where it belongs: a device's own, a Part, a Plugin Setting, a controller's (by its MAC or
    /// its address) expanded into its devices or kept by the NVR; what no setting says stays in `options`.
    @Test func optionsBecomeSettings() throws {
        let block = try JSONValue(any: [
            "platform": "UniFi Protect", "name": "UniFi Protect", "ringDelay": 2,
            "controllers": [[
                "address": "192.168.1.1", "username": "homeswift", "password": "secret", "name": "Home NVR", "mqttUrl": "mqtt://broker.local", "playlistToken": "tok",
                "doorbellMessages": [["message": "Hello", "duration": 30]],
                "cameraOverrides": [["mac": "f2:3e:23:93:1f:5c", "rtspUrl": "rtsp://cam/stream", "onvifPort": 2020, "onvifPassword": "pw"]],
            ]],
            "options": [
                "Disable.Device.\(Fixtures.cameraMAC)", "Enable.Motion.Duration.\(Fixtures.sensorMAC).30", "Enable.Motion.Switch.\(Fixtures.lightMAC)",
                "Enable.Video.Transcode.Bitrate.3000", "Disable.Video.HighResSnapshots", "Enable.Video.HighResSnapshots",
                "Enable.Log.Motion.192.168.1.1", "Enable.Nvr.SystemInfo.\(Self.nvr)", "Enable.Audio.Filter.Noise.FftNr.12.5",
                "Enable.Motion.SmartDetect.ObjectSensors.LicensePlate.\(Fixtures.cameraMAC).ABC123-XYZ9", "Disable.Video.Transcode.Bitrate.\(Fixtures.sensorMAC)",
                "Disable.Video.Transcode.HighLatency.Bitrate", "Enable.Motion.Duration.FFFFFFFFFFFF.5", "Enable.Nothing.Here",
            ],
        ] as [String: Any])
        let canonical = UniFiProtectPlugin.canonical(block, controllers: Self.known, logins: [Self.nvr])
        #expect(canonical == (try JSONValue(any: [
            "platform": "UniFi Protect", "name": "UniFi Protect", "ringDelay": 2,
            "videoTranscodeBitrate": 3000, "videoHighResSnapshots": false, "audioFilterNoiseFftNr": 12.5,
            "options": [
                "Disable.Video.Transcode.Bitrate.\(Fixtures.sensorMAC)", "Disable.Video.Transcode.HighLatency.Bitrate", "Enable.Motion.Duration.FFFFFFFFFFFF.5",
                "Enable.Nothing.Here",
            ],
            "_accessories": [
                Self.nvr: ["address": "192.168.1.1", "mqttUrl": "mqtt://broker.local", "doorbellMessages": [["message": "Hello", "duration": 30]], "name": "Home NVR",
                           "nvrSystemInfo": true],
                "F23E23931F5C": ["rtspUrl": "rtsp://cam/stream", "onvifPort": 2020],
                Fixtures.cameraMAC: ["excluded": true, "motionSmartDetectObjectSensorsLicensePlate": "ABC123-XYZ9", "logMotion": true],
                Fixtures.sensorMAC: ["motionDuration": 30, "logMotion": true],
                Fixtures.lightMAC: ["parts": ["Motion.Switch": true], "logMotion": true],
            ],
        ] as [String: Any])))
        // Without the controller, its entry and what is scoped to its devices stay.
        let alone = UniFiProtectPlugin.canonical(block, controllers: [], logins: [])
        #expect(alone["controllers"] == block["controllers"])
        #expect(alone["options"]?.arrayValue?.contains(.string("Enable.Motion.Duration.\(Fixtures.sensorMAC).30")) == true)
        // A fixed point.
        #expect(UniFiProtectPlugin.canonical(canonical, controllers: Self.known, logins: [Self.nvr]) == canonical)
    }

    /// The settings read as the options they stand for, before the block's own.
    @Test func settingsAreReadAsOptions() {
        let options = UniFiProtectPlugin.settingOptions(
            plugin: ["motionDuration": 20, "videoHighResSnapshots": false, "ringDelay": 3],
            accessories: [Fixtures.sensorMAC: AccessorySettings(plugin: ["motionDuration": 5, "audioFilterNoiseFftNr": 12.5])])
        #expect(options.contains("Enable.Motion.Duration.\(Fixtures.sensorMAC).5") && options.contains("Enable.Audio.Filter.Noise.FftNr.\(Fixtures.sensorMAC).12.5"))
        #expect(options.contains("Enable.Motion.Duration.20") && options.contains("Disable.Video.HighResSnapshots"))
        let engine = FeatureOptions(categories: FeatureOptionCatalog.categories, options: FeatureOptionCatalog.options, configuredOptions: options + ["Enable.Motion.Duration.\(Fixtures.sensorMAC).9"])
        #expect(engine.getInteger("Motion.Duration", device: Fixtures.sensorMAC) == .number(5))
        #expect(engine.getInteger("Motion.Duration", device: Fixtures.cameraMAC) == .number(20))
    }

    /// A block of canonical settings runs as the options did: a device's own setting, a Part, and a third-party camera's
    /// URLs from its Accessory Settings.
    @Test func canonicalSettingsRun() async throws {
        let environment = ProtectTestEnvironment()
        var settings = ProtectTestEnvironment.block()
        settings["motionTrigger"] = true
        settings["_accessories"] = [Fixtures.sensorMAC: ["parts": ["Motion.Switch": true]], Fixtures.lightMAC: ["motionTrigger": false]]
        let host = try environment.host(settings: settings)
        try await host.start()
        defer { Task { await host.stop() } }
        let sensorID = ProtectPlatform.accessoryID(Fixtures.sensorMAC)
        #expect(await eventually { environment.accessory(host, sensorID) != nil && environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.lightMAC)) != nil })
        let sensor = try #require(environment.accessory(host, sensorID))
        #expect(sensor.service(.switch, ProtectReservedNames.switchMotionTrigger) != nil)
        #expect(sensor.service(.switch, ProtectReservedNames.switchMotionSensor) != nil)
        #expect(environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.lightMAC))?.service(.switch, ProtectReservedNames.switchMotionTrigger) == nil)
    }

    /// The running instance moves its controller into its Accessory Settings, its login, playlist token and a camera's
    /// ONVIF password into the vault once the block is written.
    @Test func theRunningInstanceMovesTheController() async throws {
        let environment = ProtectTestEnvironment()
        let override: [String: Any] = ["mac": "AA:BB:CC:00:00:01", "rtspUrl": "rtsp://cam/stream", "onvifPassword": "pw"]
        let host = try await environment.start(options: ["Enable.Motion.Switch.\(Self.nvr)"], extra: ["playlistToken": "tok", "cameraOverrides": [override]])
        defer { Task { await host.stop() } }
        var block = ProtectTestEnvironment.block(options: ["Enable.Motion.Switch.\(Self.nvr)"], extra: ["playlistToken": "tok", "cameraOverrides": [override]])
        block["platform"] = "UniFi Protect"
        let (canonical, whenWritten) = await host.canonicalSettings(platform: UniFiProtectPlugin.platform, name: "UniFi Protect", block: try JSONValue(any: block))
        #expect(canonical["controllers"] == nil && canonical["options"] == nil)
        #expect(canonical["_accessories"]?[Self.nvr]?["address"] == "192.168.1.1")
        #expect(canonical["_accessories"]?["AABBCC000001"]?["rtspUrl"] == "rtsp://cam/stream")
        #expect(canonical["_accessories"]?[Fixtures.sensorMAC]?["parts"]?["Motion.Switch"] == true)
        let context = try #require(host.context(platform: UniFiProtectPlugin.platform, name: "UniFi Protect"))
        #expect(context.credentials(for: Self.nvr) == nil)
        try await whenWritten.run()
        #expect(context.credentials(for: Self.nvr, as: UniFiProtectPlugin.ControllerLogin.self) == .init(username: "homeswift", password: "secret", playlistToken: "tok"))
        #expect(context.credentials(for: "AABBCC000001", as: UniFiProtectPlugin.CameraCredentials.self) == .init(onvifPassword: "pw"))
    }

    /// Every device has its Device Kind, in discovery and from the running instance; a third-party camera its own.
    @Test func devicesHaveTheirKinds() async throws {
        let fake = FakeController(bootstrap: Fixtures.bootstrap(cameras: [Fixtures.camera(), CameraStreamingTests.thirdPartyCamera()]))
        let environment = ProtectTestEnvironment(controller: fake)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let kinds = Dictionary(try await plugin.discover().map { ($0.deviceID, $0.kind) }, uniquingKeysWith: { first, _ in first })
        #expect(kinds[Self.nvr] == "nvr" && kinds[Fixtures.cameraMAC] == "camera" && kinds["F23E23931F5C"] == "thirdPartyCamera")
        #expect(kinds[Fixtures.sensorMAC] == "sensor" && kinds[Fixtures.lightMAC] == "light")
        #expect(await plugin.deviceKind(of: Self.nvr) == "nvr")
        #expect(await plugin.deviceKind(of: Fixtures.sensorMAC.lowercased()) == "sensor")
        #expect(await plugin.deviceKind(of: "FFFFFFFFFFFF") == nil)
    }

    /// The schema declares each setting of the catalog: a Plugin Setting of its kind, and an accessory field of its Device
    /// Kinds whose default it is, but the Parts; and a controller's and a third-party camera's own, no secret among them.
    @Test func theSchemaMatchesTheCatalog() throws {
        let schema = try JSONValue(string: try #require(UniFiProtectPlugin.configurationSchemaJSON))
        let plugin = try #require(schema["schema"]?["properties"]?.objectValue)
        let fields = try #require(schema["accessorySchema"]?["properties"]?.objectValue)
        #expect(UniFiProtectPlugin.optionSettings.count == UniFiProtectPlugin.optionNames.count - 1)
        #expect(Set(UniFiProtectPlugin.optionSettings.map(\.key)).count == UniFiProtectPlugin.optionSettings.count)
        for setting in UniFiProtectPlugin.optionSettings {
            let declared = try #require(plugin[setting.key], "\(setting.key) is not a Plugin Setting")
            let type: JSONValue = switch setting.kind {
            case .toggle: "boolean"
            case .number: "number"
            case .text: "string"
            }
            #expect(declared["type"] == type, "\(setting.key)")
            // Words a person reads, not the feature option (Motion.OccupancySensor.Person), which the form finds by its key.
            let title = declared["title"]?.stringValue ?? ""
            #expect(!title.isEmpty && (!setting.option.contains(".") || title != setting.option), "\(setting.key)'s title is \(title)")
            if setting.isPart {
                #expect(fields[setting.key] == nil, "\(setting.key) is a Part")
            } else {
                let field = try #require(fields[setting.key], "\(setting.key) has no accessory field")
                #expect(field["x-kinds"] == JSONValue.array(setting.kinds.map(JSONValue.string)), "\(setting.key)")
                #expect(field["x-default"] == JSONValue.string(setting.key))
            }
        }
        #expect(Set(UniFiProtectPlugin.controllerKeys).isSubset(of: Set(fields.filter { $0.value["x-kinds"] == ["nvr"] }.keys)))
        #expect(Set(UniFiProtectPlugin.cameraOverrideKeys) == Set(fields.filter { $0.value["x-kinds"] == ["thirdPartyCamera"] }.keys))
        let controller = try #require(plugin["controllers"]?["items"]?["properties"]?.objectValue)
        for secret in ["password", "username", "playlistToken", "cameraOverrides"] { #expect(controller[secret] == nil, "\(secret)") }
    }
}
