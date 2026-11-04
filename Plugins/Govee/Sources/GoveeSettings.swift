import Foundation
import Homeswift
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the block's options (the connections and their
// intervals, `ignoreMatter`, logging, `colourSafeMode`, `homebridgeStoragePath`); each device's Accessory Settings sit in
// `_accessories` by its Govee device id (its Device Id, `AA:BB:…`): its Name, Excluded, and its Plugin Accessory Settings,
// which the schema's `accessorySchema` declares by Device Kind (`showAs`, a light's scenes and slots, a sensor's battery
// threshold, a kettle's modes…). The account (`username`, `password`, `code`) is Setup's, in the vault. The Homebridge
// plugin's twelve `…Devices` lists and its account keys still load, read under `_accessories` (`deviceSettings`) and the
// vault's login (`accountLogin`); `canonicalSettings` moves them.
extension GoveePlugin {
    /// A device's Device Kind: the `…Devices` list its model's entry goes in, without `Devices` (`light`, `switch`,
    /// `thermo`, `leak`, `fan`, `heater`, `humidifier`, `dehumidifier`, `purifier`, `diffuser`, `kettle`, `iceMaker`).
    static func kind(of list: DeviceConfigKey) -> String {
        String(list.rawValue.dropLast("Devices".count))
    }

    static func kind(ofModel model: String?) -> String { kind(of: DeviceConfigKey(model: model)) }

    /// From the model the running instance or its last discovery knows, else the list a Homebridge entry is in.
    public func deviceKind(of deviceID: String) async -> String? {
        let id = Govee.parseDeviceId(deviceID)
        if let model = devices[id]?.model { return Self.kind(ofModel: model) }
        if let entry = (discovered.isEmpty ? discoveredFile.load() ?? [] : discovered).first(where: { $0["deviceId"]?.stringValue == id }),
           let model = entry["model"]?.stringValue {
            return Self.kind(ofModel: model)
        }
        if let model = context.accessory(id: "\(Self.platform):\(id)")?.information[.model]?.value.stringValue { return Self.kind(ofModel: model) }
        return deviceSettings[id]?.list.map(Self.kind(of:))
    }

    /// The block in its canonical shape (`canonical`), the account's keys moved into the vault's login once the block is
    /// written (`whenSettingsWritten`): `username` and `password` (and `code` once the vault has a token) go. A block that
    /// names another user than the vault's, without its password, keeps its keys.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let canonical = Self.canonical(block)
        guard var fields = canonical.objectValue, fields["username"] != nil || fields["password"] != nil || fields["code"] != nil else { return canonical }
        // The block may only name a secret (a `vault:` reference, a sealed copy): the running configuration has it resolved.
        let stored = CredentialStore.stored(context)
        var login = stored
        if let username = configuration.username, let password = configuration.password, fields["password"] != nil {
            let same = stored?.username == username
            login = StoredLogin(username: username, password: password, credentials: same ? stored?.credentials : nil, iot: same ? stored?.iot : nil)
        }
        guard let login, login.password != nil, configuration.username.map({ $0 == login.username }) ?? true else { return canonical }
        if login != stored {
            let context = context
            await context.whenSettingsWritten { try context.saveCredentials(login) }
        }
        fields.removeValue(forKey: "username")
        fields.removeValue(forKey: "password")
        if login.credentials != nil { fields.removeValue(forKey: "code") }
        return .object(fields)
    }

    /// The Plugin Accessory Settings read as booleans and as integers, as the devices read them (`truthy`, `parseInt`):
    /// a Homebridge entry's strings and numbers are written as such.
    static let booleanKeys: Set<String> = [
        "awsBrightnessNoScale", "lanScenes", "showExtraSwitch", "hideLight", "tempReporting",
        "hideModeGreenTea", "hideModeOolongTea", "hideModeCoffee", "hideModeBlackTea", "showCustomMode1", "showCustomMode2",
    ]
    static let integerKeys: Set<String> = ["adaptiveLightingShift", "brightnessStep", "lowBattThreshold"]

    /// The block with the twelve `…Devices` lists moved into `_accessories` by device id (`Govee.parseDeviceId`, as the
    /// plugin reads them): `label` as the Name, `ignoreDevice` as Excluded, every other key of the entry as it is (the
    /// booleans and integers above typed). A device in two lists takes the later one's entry, as the plugin did. What
    /// `_accessories` has already stays; an entry without a device id stays in its list.
    static func canonical(_ block: JSONValue) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var legacy: [String: [String: JSONValue]] = [:]
        var order: [String] = []
        for list in DeviceConfigKey.allCases {
            guard let entries = fields[list.rawValue]?.arrayValue else { continue }
            var left: [JSONValue] = []
            for item in entries {
                guard let device = item.objectValue, let raw = device["deviceId"].flatMap(Configuration.string),
                      case let id = Govee.parseDeviceId(raw), !id.isEmpty else {
                    left.append(item)
                    continue
                }
                var entry: [String: JSONValue] = [:]
                for (key, value) in device where !["deviceId", "label", "ignoreDevice"].contains(key) && !value.isNull {
                    if booleanKeys.contains(key) {
                        entry[key] = .bool(Configuration.truthy(value))
                    } else if integerKeys.contains(key) {
                        if let number = Configuration.integer(value), number != 0 || key != "lowBattThreshold" { entry[key] = .number(Double(number)) }
                    } else {
                        entry[key] = value
                    }
                }
                if let label = device["label"].flatMap(Configuration.string)?.trimmingCharacters(in: .whitespaces), !label.isEmpty { entry["name"] = .string(label) }
                if Configuration.truthy(device["ignoreDevice"]) { entry["excluded"] = true }
                if legacy[id] == nil { order.append(id) }
                legacy[id] = entry
            }
            if left.isEmpty { fields.removeValue(forKey: list.rawValue) } else { fields[list.rawValue] = .array(left) }
        }
        guard !order.isEmpty else { return .object(fields) }
        var accessories = fields["_accessories"]?.objectValue ?? [:]
        for id in order {
            var entry = accessories[id]?.objectValue ?? [:]
            for (key, value) in legacy[id] ?? [:] where entry[key] == nil { entry[key] = value }
            if !entry.isEmpty { accessories[id] = .object(entry) }
        }
        if !accessories.isEmpty { fields["_accessories"] = .object(accessories) }
        return .object(fields)
    }
}
