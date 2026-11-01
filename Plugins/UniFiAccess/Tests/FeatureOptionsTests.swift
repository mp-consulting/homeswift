import Foundation
import Testing

@testable import HomeswiftUniFiAccess

/// `lib-featureoptions.test.ts`, case for case.
@Suite struct FeatureOptionsTests {
    static let categories = [FeatureCategory(name: "Device", description: "Device feature options."), FeatureCategory(name: "Hub", description: "Hub feature options.")]
    static let options: [String: [FeatureOptionEntry]] = [
        "Device": [
            FeatureOptionEntry("", default: true, description: "Make this device available in HomeKit."),
            FeatureOptionEntry("SyncName", default: false, description: "Sync names."),
        ],
        "Hub": [
            FeatureOptionEntry("DPS", default: true, description: "Door position sensor."),
            FeatureOptionEntry("LockDelayInterval", default: false, defaultValue: 5, description: "Lock delay, in minutes."),
            FeatureOptionEntry("GateDuration", default: true, defaultValue: 2.5, description: "Gate duration, in seconds."),
        ],
    ]
    static let device = "AABBCCDDEEFF"
    static let controller = "001122334455"
    static let isMAC: @Sendable (String) -> Bool = { $0.count == 12 && $0.allSatisfy(\.isHexDigit) }

    func make(_ configured: [String] = [], isIdentifier: (@Sendable (String) -> Bool)? = nil) -> FeatureOptions {
        FeatureOptions(categories: Self.categories, options: Self.options, configured: configured, isIdentifier: isIdentifier)
    }

    @Test func defaults() {
        let options = make()
        #expect(options.test("Device"))
        #expect(!options.test("Device.SyncName"))
        #expect(!options.test("Not.An.Option"))
    }

    @Test func scopes() {
        let options = make(["Disable.Hub.DPS", "Enable.Hub.DPS.\(Self.controller)", "Disable.Hub.DPS.\(Self.device)"])
        #expect(!options.test("Hub.DPS"))
        #expect(options.test("Hub.DPS", device: "OTHERDEVICE", controller: Self.controller))
        #expect(!options.test("Hub.DPS", device: Self.device, controller: Self.controller))
        #expect(options.scope("Hub.DPS", device: Self.device, controller: Self.controller) == .device)
        #expect(options.scope("Hub.DPS", device: "OTHERDEVICE", controller: Self.controller) == .controller)
        #expect(options.scope("Hub.DPS", device: "OTHERDEVICE", controller: "OTHERCONTROLLER") == .global)
        #expect(options.scope("Device.SyncName", device: Self.device, controller: Self.controller) == FeatureOptionScope.none)
    }

    @Test func caseInsensitive() {
        let options = make(["disable.hub.dps.aabbccddeeff"])
        #expect(!options.test("Hub.DPS", device: Self.device))
        #expect(!options.test("HUB.DPS", device: Self.device.lowercased()))
    }

    @Test func firstEntryWins() {
        #expect(make(["Enable.Device.SyncName", "Disable.Device.SyncName"]).test("Device.SyncName"))
    }

    @Test func malformedEntries() {
        let options = make(["Toggle.Device.SyncName", "garbage", ""])
        #expect(!options.test("Device.SyncName"))
        #expect(options.configuredOptions == ["Toggle.Device.SyncName", "garbage", ""])
    }

    @Test func values() {
        #expect(make(["Enable.Hub.DPS"]).value("Hub.DPS") == .disabled)
        #expect(make().value("Hub.GateDuration") == .value("2.5"))
        #expect(make().float("Hub.GateDuration") == .number(2.5))
        #expect(make().value("Hub.LockDelayInterval") == .disabled)
        #expect(make().integer("Hub.LockDelayInterval") == .disabled)
        #expect(make(["Disable.Hub.GateDuration"]).value("Hub.GateDuration") == .disabled)

        let scoped = make(["Enable.Hub.LockDelayInterval.\(Self.device).10", "Enable.Hub.LockDelayInterval.3", "Enable.Hub.GateDuration.\(Self.device).Fast"])
        #expect(scoped.integer("Hub.LockDelayInterval", device: Self.device, controller: Self.controller) == .number(10))
        #expect(scoped.integer("Hub.LockDelayInterval", device: "OTHERDEVICE", controller: Self.controller) == .number(3))
        #expect(scoped.value("Hub.GateDuration", device: Self.device) == .value("Fast"))

        #expect(make(["Enable.Hub.LockDelayInterval"]).value("Hub.LockDelayInterval") == .enabledWithoutValue)
        #expect(make(["Enable.Hub.LockDelayInterval"]).integer("Hub.LockDelayInterval") == .enabledWithoutValue)
    }

    @Test func loneSegment() {
        // Without a recogniser, a lone segment is a global value.
        #expect(make(["Enable.Hub.LockDelayInterval.\(Self.device)"]).value("Hub.LockDelayInterval", device: "OTHERDEVICE") == .value(Self.device))

        // With one, it is a device scope.
        let options = make(["Enable.Hub.LockDelayInterval.\(Self.device)", "Enable.Hub.GateDuration.4"], isIdentifier: Self.isMAC)
        #expect(options.test("Hub.LockDelayInterval", device: Self.device))
        #expect(options.value("Hub.LockDelayInterval", device: Self.device) == .enabledWithoutValue)
        #expect(!options.test("Hub.LockDelayInterval", device: "OTHERDEVICE"))
        #expect(options.value("Hub.LockDelayInterval", device: "OTHERDEVICE") == .disabled)
        #expect(options.float("Hub.GateDuration", device: Self.device) == .number(4))
    }

    @Test func nonNumbers() {
        #expect(make(["Enable.Hub.LockDelayInterval.soon"]).integer("Hub.LockDelayInterval") == .enabledWithoutValue)
        #expect(make(["Enable.Hub.GateDuration.fast"]).float("Hub.GateDuration") == .enabledWithoutValue)
    }

    @Test func scopeHelpers() {
        let options = make(["Enable.Device.SyncName", "Disable.Hub.DPS.\(Self.device)"])
        #expect(options.isScopeGlobal("Device.SyncName"))
        #expect(!options.isScopeGlobal("Hub.DPS"))
        #expect(options.isScopeDevice("Hub.DPS", device: Self.device))
        #expect(!options.exists("Hub.DPS", id: "OTHERDEVICE"))

        let colors = make(["Enable.Device.SyncName", "Enable.Hub.DPS.\(Self.controller)", "Disable.Hub.DPS.\(Self.device)"])
        #expect(colors.color("Hub.DPS", device: Self.device, controller: Self.controller) == "text-info")
        #expect(colors.color("Hub.DPS", device: "OTHERDEVICE", controller: Self.controller) == "text-success")
        #expect(colors.color("Device.SyncName", device: Self.device) == "text-warning")
        #expect(colors.color("Device.SyncName") == "text-info")
        #expect(colors.color("Hub.LockDelayInterval") == "")
    }

    @Test func metadata() {
        var options = make()
        #expect(options.expandOption("Hub", "DPS") == "Hub.DPS")
        #expect(options.expandOption("Device", "") == "Device")
        #expect(options.expandOption("", "DPS") == "")
        #expect(options.isValue("Hub.LockDelayInterval"))
        #expect(options.isValue("hub.gateduration"))
        #expect(!options.isValue("Hub.DPS"))
        #expect(!options.isValue(""))
        options.setConfigured(["Enable.Device.SyncName"])
        #expect(options.test("Device.SyncName"))
    }

    @Test func decimals() {
        #expect(make(["Enable.Hub.GateDuration.3.5"]).float("Hub.GateDuration") == .number(3.5))
        #expect(make(["Enable.Hub.GateDuration.3.5"]).float("Hub.GateDuration", device: Self.device, controller: Self.controller) == .number(3.5))
        let deviceDecimal = make(["Enable.Hub.GateDuration.\(Self.device).7.25"])
        #expect(deviceDecimal.float("Hub.GateDuration", device: Self.device) == .number(7.25))
        #expect(deviceDecimal.float("Hub.GateDuration") == .number(2.5))
        let controllerInteger = make(["Enable.Hub.GateDuration.\(Self.controller).4"])
        #expect(controllerInteger.float("Hub.GateDuration", device: Self.device, controller: Self.controller) == .number(4))
        #expect(controllerInteger.float("Hub.GateDuration") == .number(2.5))
        #expect(make(["Enable.Hub.GateDuration.3.5"], isIdentifier: Self.isMAC).float("Hub.GateDuration") == .number(3.5))
    }

    @Test func javaScriptNumbers() {
        #expect(FeatureOptions.parseInt("12abc") == 12)
        #expect(FeatureOptions.parseInt(" -3") == -3)
        #expect(FeatureOptions.parseInt("3.9") == 3)
        #expect(FeatureOptions.parseInt("abc") == nil)
        #expect(FeatureOptions.parseFloat("2.5x") == 2.5)
        #expect(FeatureOptions.parseFloat("0x10") == 0)
        #expect(FeatureOptions.javaScriptString(60) == "60")
        #expect(FeatureOptions.javaScriptString(2.5) == "2.5")
    }

    /// The plugin's own options: names, defaults and values users have in config.json.
    @Test func pluginOptions() {
        let options = AccessOptions.make([])
        #expect(options.test("Device"))
        #expect(options.test("Device.SyncName"))
        #expect(options.integer("Controller.DelayDeviceRemoval") == .number(60))
        #expect(options.integer("Hub.GateDirectionDuration") == .disabled)
        #expect(options.integer("Hub.LockDelayInterval") == .disabled)
        #expect(!options.test("Hub.Lock.Trigger"))
        #expect(options.test("Hub.DPS") && options.test("Hub.REL") && options.test("Hub.REN") && options.test("Hub.REX"))
        #expect(options.test("Hub.SideDoor") && options.test("Hub.SideDoor.DPS") && !options.test("Hub.SideDoor.Lock.Trigger"))
        #expect(options.test("AccessMethod.Face") && !options.test("AccessMethod.SeparateAccessory"))
        #expect(!options.test("Controller.Publish.Telemetry"))
        #expect(options.groups["Hub.Doorbell"] == ["Hub.Doorbell.SeparateAccessory"])
        #expect(options.groups["Hub.SideDoor"] == ["Hub.SideDoor.DPS", "Hub.SideDoor.SeparateAccessory", "Hub.SideDoor.Lock.Trigger"])

        // Device ids (a MAC, with a port for a door of an Enterprise hub) scope; numbers are values.
        let scoped = AccessOptions.make(["Enable.Hub.LockDelayInterval.AABBCCDDEEFF", "Enable.Hub.LockDelayInterval.AABBCCDDEEFF-PORT1.10", "Disable.Controller.DelayDeviceRemoval"])
        #expect(scoped.integer("Hub.LockDelayInterval", device: "AABBCCDDEEFF") == .enabledWithoutValue)
        #expect(scoped.integer("Hub.LockDelayInterval", device: "aabbccddeeff-port1") == .number(10))
        #expect(scoped.integer("Hub.LockDelayInterval", device: "OTHER") == .disabled)
        #expect(scoped.integer("Controller.DelayDeviceRemoval") == .disabled)
    }

    @Test func pluginOptionsJSON() throws {
        let json = AccessOptions.json
        let categories = try #require(json["categories"]?.arrayValue)
        #expect(categories.compactMap { $0["name"]?.stringValue } == ["Device", "Controller", "Hub", "AccessMethod", "Log"])
        #expect(categories[1]["modelKey"] == ["controller"])
        let hub = try #require(json["options"]?["Hub"]?.arrayValue)
        let gate = try #require(hub.first { $0["name"] == "GateDirectionDuration" })
        #expect(gate["defaultValue"] == 90)
        #expect(gate["modelKey"] == ["UA Gate"])
        #expect(hub.first { $0["name"] == "Door.UseGarageOpener" }?["modelKey"] == ["UA Hub Door Mini", "UA Ultra", "UA Hub"])
        #expect(hub.first { $0["name"] == "Sensors.SeparateAccessory" }?["modelKey"] == ["UA Hub Door Mini", "UA Ultra", "UA Hub", "UA Hub Enterprise", "UA Gate"])
        #expect(json["options"]?["AccessMethod"]?[3]?["hasCapability"] == ["mobile_unlock_ver2", "support_mobile_unlock"])
    }
}
