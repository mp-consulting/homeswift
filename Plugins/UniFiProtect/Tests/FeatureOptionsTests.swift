import Foundation
import Testing

@testable import HomeswiftUniFiProtect

/// featureoptions.test.ts and protect-options.test.ts of the Homebridge plugin.
@Suite struct FeatureOptionsTests {
    static let controller = "001122334455"
    static let device = "AABBCC112233"
    static let otherDevice = "FFEEDDCCBBAA"

    static let configured = [
        "Disable.Device",
        "Enable.Device.AABBCC112233",
        "Enable.Video.HKSV.Recording.Switch.001122334455",
        "Disable.Video.HKSV.Recording.Switch.AABBCC112233",
        "Enable.Log.Motion",
        "Disable.Log.Motion.001122334455",
        "Enable.Log.Motion.AABBCC112233",
        "Enable.Motion.Duration.42",
        "Enable.Motion.Duration.AABBCC112233.7",
        "Enable.Motion.OccupancySensor.Duration.abc",
        "Disable.Video.Transcode.Bitrate",
        "Enable.Doorbell.PhysicalChime.Duration.Digital.001122334455.2500",
        "Enable.Audio.Filter.Noise.FftNr.AABBCC112233.18",
        "Enable.Audio.Filter.Noise.FftNr.FFEEDDCCBBAA.loud",
    ]

    static func options(_ configured: [String] = FeatureOptionsTests.configured, isIdentifier: (@Sendable (String) -> Bool)? = nil) -> FeatureOptions {
        FeatureOptions(categories: FeatureOptionCatalog.categories, options: FeatureOptionCatalog.options, configuredOptions: configured, isIdentifier: isIdentifier)
    }

    @Test func defaults() {
        var options = Self.options([])
        #expect(options.test("Device"))
        #expect(!options.test("Device.SyncName"))
        #expect(options.defaultValue("Device") && !options.defaultValue("Device.SyncName"))
        #expect(!options.test("Not.A.Real.Option"))
        options.defaultReturnValue = true
        #expect(options.test("Not.A.Real.Option"))
        #expect(options.scope("Device", device: Self.device, controller: Self.controller) == .none)
        #expect(options.color("Device", device: Self.device, controller: Self.controller) == "")
        #expect(options.value("Motion.Duration") == .value("10"))
        #expect(options.getInteger("Motion.Duration", device: Self.device, controller: Self.controller) == .number(10))
        #expect(options.getFloat("Audio.Filter.Noise.FftNr") == .number(14))
        // Disabled by default: no value until enabled.
        #expect(options.value("Motion.SmartDetect.ObjectSensors.LicensePlate") == .disabled)
        #expect(options.getInteger("Nvr.Service.Playlist") == .disabled)
        #expect(!options.isValue("Device") && !options.isValue(""))
        #expect(options.value("Device") == .disabled)
    }

    @Test func scopePrecedence() {
        let options = Self.options()
        #expect(!options.test("Device"))
        #expect(!options.test("Device", device: Self.otherDevice, controller: Self.controller))
        #expect(options.test("Device", device: Self.device, controller: Self.controller))
        #expect(options.test("Video.HKSV.Recording.Switch", device: Self.otherDevice, controller: Self.controller))
        #expect(!options.test("Video.HKSV.Recording.Switch", device: Self.device, controller: Self.controller))
        #expect(options.test("Log.Motion"))
        #expect(options.test("Log.Motion", device: Self.otherDevice))
        #expect(!options.test("Log.Motion", device: Self.otherDevice, controller: Self.controller))
        #expect(options.test("Log.Motion", device: Self.device, controller: Self.controller))
        #expect(!options.test("Video.HKSV.Recording.Switch", device: Self.otherDevice))
        #expect(options.scope("Device", device: Self.device, controller: Self.controller) == .device)
        #expect(options.scope("Device", device: Self.otherDevice, controller: Self.controller) == .global)
        #expect(options.scope("Video.HKSV.Recording.Switch", device: Self.otherDevice, controller: Self.controller) == .controller)
        #expect(options.scope("Video.HKSV.Recording.Switch", device: Self.device, controller: Self.controller) == .device)
        #expect(options.scope("Device.SyncName", device: Self.device, controller: Self.controller) == .none)
        #expect(options.color("Device", device: Self.device, controller: Self.controller) == "text-info")
        #expect(options.color("Video.HKSV.Recording.Switch", device: Self.otherDevice, controller: Self.controller) == "text-success")
        #expect(options.color("Device", device: Self.otherDevice) == "text-warning")
        #expect(options.color("Device") == "text-info")
        #expect(options.isScopeGlobal("Device") && !options.isScopeGlobal("Device.SyncName"))
        #expect(options.isScopeDevice("Device", device: Self.device) && !options.isScopeDevice("Device", device: Self.otherDevice))
        #expect(Self.options(["Enable.Device.SyncName", "Disable.Device.SyncName"]).test("Device.SyncName"))
        let malformed = Self.options(["Toggle.Device.SyncName", "Enable"])
        #expect(!malformed.test("Device.SyncName") && malformed.scope("Device.SyncName") == .none)
    }

    @Test func caseInsensitive() {
        let options = Self.options()
        #expect(options.test("Device", device: Self.device.lowercased(), controller: Self.controller))
        #expect(options.test("Video.HKSV.Recording.Switch", device: Self.otherDevice.lowercased(), controller: Self.controller.lowercased()))
        #expect(options.getInteger("Motion.Duration", device: Self.device.lowercased()) == .number(7))
        #expect(options.test("device", device: Self.device))
        #expect(!options.test("VIDEO.HKSV.RECORDING.SWITCH", device: Self.device, controller: Self.controller))
        #expect(options.getInteger("motion.duration") == .number(42))
        #expect(Self.options(["eNaBlE.device.syncname.aabbcc112233"]).test("Device.SyncName", device: Self.device))
    }

    @Test func values() {
        let options = Self.options()
        #expect(options.value("Motion.Duration") == .value("42"))
        #expect(options.getInteger("Motion.Duration", device: Self.otherDevice, controller: Self.controller) == .number(42))
        #expect(options.value("Motion.Duration", device: Self.device, controller: Self.controller) == .value("7"))
        #expect(options.getInteger("Doorbell.PhysicalChime.Duration.Digital", device: Self.otherDevice, controller: Self.controller) == .number(2500))
        #expect(options.scope("Doorbell.PhysicalChime.Duration.Digital", device: Self.otherDevice, controller: Self.controller) == .controller)
        #expect(options.getFloat("Audio.Filter.Noise.FftNr", device: Self.device) == .number(18))
        #expect(options.value("Motion.OccupancySensor.Duration") == .value("abc"))
        #expect(options.getInteger("Motion.OccupancySensor.Duration") == .invalid)
        #expect(options.getFloat("Audio.Filter.Noise.FftNr", device: Self.otherDevice) == .invalid)
        #expect(options.value("Video.Transcode.Bitrate") == .disabled)
        #expect(options.getInteger("Video.Transcode.Bitrate") == .disabled)
        let enabledOnly = Self.options(["Enable.Motion.OccupancySensor.Duration"])
        #expect(enabledOnly.value("Motion.OccupancySensor.Duration") == .enabledWithoutValue)
        #expect(enabledOnly.getInteger("Motion.OccupancySensor.Duration") == .invalid)
        #expect(Self.options(["Enable.Motion.Duration.42"]).getInteger("Motion.OccupancySensor.Duration") == .number(300))
        #expect(Self.options(["Enable.Motion.SmartDetect.ObjectSensors.LicensePlate.AbC123"]).value("Motion.SmartDetect.ObjectSensors.LicensePlate") == .value("AbC123"))
    }

    @Test func catalogBookkeeping() {
        let options = Self.options()
        #expect(FeatureOptions.expand("Device", "") == "Device")
        #expect(FeatureOptions.expand("Device", "SyncName") == "Device.SyncName")
        #expect(FeatureOptions.expand("", "SyncName") == "")
        #expect(options.groups["Audio.Filter.Noise"] == ["Audio.Filter.Noise.FftNr", "Audio.Filter.Noise.HighPass", "Audio.Filter.Noise.LowPass"])
        #expect(options.groups["Video.Crop"] == ["Video.Crop.X", "Video.Crop.Y", "Video.Crop.Width", "Video.Crop.Height"])
        #expect(options.isValue("Motion.Duration") && !options.isValue("Video.HKSV.Recording.Switch"))
    }

    @Test func decimals() {
        let decimal = Self.options(["Enable.Audio.Filter.Noise.FftNr.12.5"])
        #expect(decimal.getFloat("Audio.Filter.Noise.FftNr") == .number(12.5))
        #expect(decimal.getFloat("Audio.Filter.Noise.FftNr", device: Self.device, controller: Self.controller) == .number(12.5))
        let scoped = Self.options(["Enable.Audio.Filter.Noise.FftNr.\(Self.device).7.25"])
        #expect(scoped.getFloat("Audio.Filter.Noise.FftNr", device: Self.device) == .number(7.25))
        #expect(scoped.getFloat("Audio.Filter.Noise.FftNr") == .number(14))
        let controller = Self.options(["Enable.Audio.Filter.Noise.FftNr.\(Self.controller).5"])
        #expect(controller.getFloat("Audio.Filter.Noise.FftNr", device: Self.device, controller: Self.controller) == .number(5))
        #expect(controller.getFloat("Audio.Filter.Noise.FftNr") == .number(14))
        let recognizer = Self.options(["Enable.Audio.Filter.Noise.FftNr.12.5"]) { $0 == "12" }
        #expect(recognizer.getFloat("Audio.Filter.Noise.FftNr", device: "12") == .number(5))
        #expect(recognizer.getFloat("Audio.Filter.Noise.FftNr") == .number(14))
    }

    /// The settings page writes controller options with the controller's address; the plugin reads both.
    @Test func controllerAddressScope() {
        let options = FeatureOptions(categories: FeatureOptionCatalog.categories, options: FeatureOptionCatalog.options,
                                     configuredOptions: ["Enable.Motion.Switch.192.168.1.1", "Enable.Motion.Duration.192.168.1.1.25"], dottedIdentifiers: ["192.168.1.1"])
        #expect(options.test("Motion.Switch", device: Self.device, controllers: [Self.controller, "192.168.1.1"]))
        #expect(!options.test("Motion.Switch", device: Self.device, controllers: [Self.controller]))
        #expect(options.getInteger("Motion.Duration", device: Self.device, controllers: [Self.controller, "192.168.1.1"]) == .number(25))
    }

    @Test func catalog() {
        let names = FeatureOptionCatalog.categories.map(\.name)
        #expect(Set(names).count == names.count)
        for name in ["Audio", "Device", "Doorbell", "Log", "Motion", "Nvr", "Video", "Video.HKSV"] { #expect(names.contains(name)) }
        for category in FeatureOptionCatalog.categories {
            #expect(!category.description.isEmpty)
            #expect(!category.modelKey.isEmpty && category.modelKey.allSatisfy { ["all", "camera", "light", "nvr", "sensor"].contains($0) })
            let entries = FeatureOptionCatalog.options[category.name] ?? []
            #expect(!entries.isEmpty)
            let entryNames = Set(entries.map(\.name))
            #expect(entryNames.count == entries.count)
            for entry in entries {
                #expect(!entry.description.isEmpty)
                if let group = entry.group { #expect(entryNames.contains(group)) }
                if let size = entry.inputSize { #expect(size > 0) }
            }
        }
        #expect(Set(FeatureOptionCatalog.options.keys) == Set(names))
        let qualified = FeatureOptionCatalog.options.flatMap { category, entries in entries.map { FeatureOptions.expand(category, $0.name) } }
        #expect(Set(qualified).count == qualified.count)
        #expect(qualified.count == 79)
        #expect(FeatureOptionCatalog.options["Device"]?.first { $0.name == "" }?.default == true)
        #expect(FeatureOptionCatalog.options["Motion"]?.first { $0.name == "Duration" }?.defaultValue == .number(10))
        #expect(FeatureOptionCatalog.options["Motion"]?.first { $0.name == "OccupancySensor.Duration" }?.defaultValue == .number(300))
        #expect(FeatureOptionCatalog.options["Video.HKSV"]?.contains { $0.name == "Recording.Switch" } == true)
        // The page's catalog keeps every key the Homebridge page read.
        let json = UniFiProtectPlugin.catalogJSON
        #expect(json.array("categories").count == names.count)
        #expect(json.at("options.Motion")?.arrayValue?.first { $0.string("name") == "SmartDetect.ObjectSensors.LicensePlate" }?.string("defaultValue") == "")
        #expect(json.at("options.Device")?.arrayValue?.first { $0.string("name") == "StatusLed.Switch" }?.strings("hasSensorProperty") == ["ledSettings"])
    }
}
