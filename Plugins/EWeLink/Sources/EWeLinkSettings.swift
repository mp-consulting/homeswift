import Foundation
import Homeswift
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the block's options (`countryCode`, `mode`, logging,
// `offlineAsOff`, the queue…) and two lists of things the person makes rather than devices the account has: `groups`
// (virtual devices of `deviceIds`) and `bridgeSensors` (an RF Bridge's sub-devices, by full device id). Each device's
// Accessory Settings sit in `_accessories` by its eWeLink device id (its Device Id; a channel or an RF sub-device,
// `<id>SW<n>`, is its device's): Excluded, and its Plugin Accessory Settings, which the schema's `accessorySchema`
// declares by Device Kind (its `DeviceCategory`: `single`, `multi`, `thermostat`, `light`, `fan`, `sensor`, `rf_bridge`,
// and the others, which have none). The account (`username`, `password`) is in the vault. The Homebridge plugin's seven
// typed lists and `ignoredDevices` still load, read under `_accessories` (`withAccessorySettings`); `canonicalSettings`
// moves them.
extension EWeLinkPlugin {
    /// The typed lists, in the order a device's settings are taken from them when two hold the same key.
    static let deviceLists = ["singleDevices", "multiDevices", "thDevices", "lightDevices", "fanDevices", "sensorDevices", "rfDevices"]

    /// The list each category reads (`Configuration.showAs(_:category:)`): its settings come first.
    static let listOfCategory: [DeviceCategory: String] = [
        .singleSwitch: "singleDevices", .multiSwitch: "multiDevices", .thermostat: "thDevices", .light: "lightDevices",
        .fan: "fanDevices", .sensor: "sensorDevices", .rfBridge: "rfDevices",
    ]

    /// The keys of an entry the plugin reads, besides `deviceId`, with what they are; the Homebridge plugin's others
    /// (`label`, `ignoreDevice`, `ipAddress`, `overrideLogging`…) never had an effect and go.
    static let booleanKeys: Set<String> = [
        "disableDeviceLogging", "isInched", "disableTimer", "inchChannels", "showHeatCool", "hideSwitch", "hideLight", "hideTemp", "hideHumidity",
    ]
    static let numberKeys: Set<String> = [
        "operationTime", "operationTimeDown", "offset", "offsetFactor", "inUsePowerThreshold", "lowBattThreshold", "tempOffset", "humidityOffset",
        "humidityOffsetFactor", "minTarget", "maxTarget", "targetTempThreshold", "brightnessStep", "adaptiveLightingShift", "lowBattery",
    ]
    static let stringKeys: Set<String> = ["showAs", "deviceModel", "tempSource", "sensorType", "type", "hideChannels"]
    /// An RF Bridge's learned sub-devices' settings (`RFSubdevice`).
    static let subdeviceKeys: Set<String> = ["index", "label", "showAs", "resetTime", "operationTime", "operationTimeDown"]

    // MARK: Device Kinds

    /// A device's Device Kind: its category's name (`single`, `multi`, `rf_bridge`…).
    public func deviceKind(of deviceID: String) async -> String? {
        let id = DeviceLimits.parentDeviceID(deviceID)
        if let category = await knownCategories()[id] { return category.rawValue }
        if let raw = context.jsonFile("devices.json", as: EWeLinkPlatform.DeviceCacheFile.self).load()?.devices
            .first(where: { $0["deviceid"]?.stringValue == id })?.objectValue {
            return DeviceCategory.resolve(EWeLinkDevice(raw: raw)).rawValue
        }
        return nil
    }

    /// The categories of the devices the running platform has, by device id.
    @EWeLinkActor
    func knownCategories() -> [String: DeviceCategory] {
        (holder.platform?.registry.devices ?? [:]).mapValues { DeviceCategory.resolve($0.device) }
    }

    // MARK: Reading

    /// The configuration with each device's Plugin Accessory Settings (its `_accessories` entry) in every typed list's
    /// entry for it, over a Homebridge entry's keys: the accessories read them as they read the lists.
    static func withAccessorySettings(_ configuration: Configuration, _ settings: [String: AccessorySettings]) -> Configuration {
        var configuration = configuration
        for (deviceID, accessory) in settings.sorted(by: { $0.key < $1.key }) where !accessory.plugin.isEmpty {
            configuration.singleDevices = merged(configuration.singleDevices, deviceID, accessory.plugin)
            configuration.multiDevices = merged(configuration.multiDevices, deviceID, accessory.plugin)
            configuration.thDevices = merged(configuration.thDevices, deviceID, accessory.plugin)
            configuration.lightDevices = merged(configuration.lightDevices, deviceID, accessory.plugin)
            configuration.fanDevices = merged(configuration.fanDevices, deviceID, accessory.plugin)
            configuration.sensorDevices = merged(configuration.sensorDevices, deviceID, accessory.plugin)
            configuration.rfDevices = merged(configuration.rfDevices, deviceID, accessory.plugin)
        }
        return configuration
    }

    private static func merged<Entry: Codable & DeviceEntry>(_ list: [Entry]?, _ deviceID: String, _ own: [String: JSONValue]) -> [Entry]? {
        var entries = list ?? []
        let index = entries.firstIndex { $0.deviceId == deviceID }
        var fields = index.flatMap { (try? JSONValue(encoding: entries[$0]))?.objectValue } ?? [:]
        fields.merge(own) { $1 }
        fields["deviceId"] = .string(deviceID)
        guard let entry = try? JSONValue.object(fields).decode(Entry.self) else { return list }
        if let index { entries[index] = entry } else { entries.append(entry) }
        return entries
    }

    /// Whether a device's state changes stay out of the log: its own `disableDeviceLogging`, else the plugin's.
    static func deviceLoggingDisabled(_ configuration: Configuration, _ deviceID: String) -> Bool {
        let id = DeviceLimits.parentDeviceID(deviceID)
        // A list rather than one chain of `??`: Linux's type checker gives up on the chain.
        let entries: [Bool?] = [
            configuration.single(id)?.disableDeviceLogging, configuration.multi(id)?.disableDeviceLogging, configuration.thermostat(id)?.disableDeviceLogging,
            configuration.light(id)?.disableDeviceLogging, configuration.fan(id)?.disableDeviceLogging, configuration.sensor(id)?.disableDeviceLogging,
            configuration.rf(id)?.disableDeviceLogging,
        ]
        return entries.lazy.compactMap { $0 }.first ?? configuration.disableDeviceLogging ?? false
    }

    // MARK: The canonical shape

    /// The block in its canonical shape (`canonical`, with the categories of the devices the instance knows), the
    /// account's `username` and `password` moved into the vault once the block is written (`whenSettingsWritten`).
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        guard var fields = Self.canonical(block, categories: await knownCategories()).objectValue else { return block }
        // The block may only name the password (a `vault:` reference, a sealed copy): the running configuration has it
        // resolved, the vault's when Setup kept one.
        let held = context.credentials(as: StoredPassword.self)
        guard let username = configuration.username, let password = configuration.password, fields["username"] != nil || fields["password"] != nil else {
            return .object(fields)
        }
        let login = StoredPassword(password: password, username: username)
        if login != held {
            let context = context
            await context.whenSettingsWritten { try context.saveCredentials(login) }
        }
        fields.removeValue(forKey: "username")
        fields.removeValue(forKey: "password")
        return .object(fields)
    }

    /// The block with the seven typed lists moved into `_accessories` by device id: each entry's keys the plugin reads
    /// (`booleanKeys`, `numberKeys`, `stringKeys`, an RF Bridge's `subdevices`) typed as the plugin reads them, its
    /// others dropped; a device in two lists takes its category's list first (`categories`), else the lists' order.
    /// `ignoredDevices` becomes Excluded devices; an id of a channel or a sub-device (`<id>SW<n>`), which never matched,
    /// stays in it. What `_accessories` has already stays; an entry without a device id stays in its list.
    static func canonical(_ block: JSONValue, categories: [String: DeviceCategory] = [:]) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var legacy: [String: [String: [String: JSONValue]]] = [:]   // device id → list → its keys
        for list in deviceLists {
            guard let entries = fields[list]?.arrayValue else { continue }
            var left: [JSONValue] = []
            for item in entries {
                guard let entry = item.objectValue, let id = entry["deviceId"]?.jsString?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                    left.append(item)
                    continue
                }
                legacy[id, default: [:]][list] = typed(entry)
            }
            if left.isEmpty { fields.removeValue(forKey: list) } else { fields[list] = .array(left) }
        }
        var accessories = fields["_accessories"]?.objectValue ?? [:]
        for (id, byList) in legacy.sorted(by: { $0.key < $1.key }) {
            let first = categories[id].flatMap { listOfCategory[$0] }
            let order = (first.map { [$0] } ?? []) + deviceLists.filter { $0 != first }
            var entry = accessories[id]?.objectValue ?? [:]
            for list in order {
                for (key, value) in byList[list] ?? [:] where entry[key] == nil { entry[key] = value }
            }
            if !entry.isEmpty { accessories[id] = .object(entry) }
        }
        if let ignored = fields["ignoredDevices"]?.arrayValue {
            var left: [JSONValue] = []
            for value in ignored {
                guard let id = value.jsString?.trimmingCharacters(in: .whitespaces), !id.isEmpty, DeviceLimits.parentDeviceID(id) == id else {
                    left.append(value)
                    continue
                }
                var entry = accessories[id]?.objectValue ?? [:]
                if entry["excluded"] == nil { entry["excluded"] = true }
                accessories[id] = .object(entry)
            }
            if left.isEmpty { fields.removeValue(forKey: "ignoredDevices") } else { fields["ignoredDevices"] = .array(left) }
        }
        if !accessories.isEmpty { fields["_accessories"] = .object(accessories) }
        return .object(fields)
    }

    /// An entry's keys the plugin reads, as it reads them (`AnyKey`'s lenient values): a value it would not read goes.
    static func typed(_ entry: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in entry {
            if booleanKeys.contains(key) {
                if let flag = lenientBool(value) { out[key] = .bool(flag) }
            } else if numberKeys.contains(key) {
                if let number = lenientNumber(value) { out[key] = .number(number) }
            } else if stringKeys.contains(key) {
                if let text = value.jsString { out[key] = .string(text) }
            } else if key == "subdevices", let items = value.arrayValue {
                let kept = items.compactMap { item -> JSONValue? in
                    guard let fields = item.objectValue else { return nil }
                    var sub: [String: JSONValue] = [:]
                    for (key, value) in fields where subdeviceKeys.contains(key) {
                        if ["index", "resetTime", "operationTime", "operationTimeDown"].contains(key) {
                            if let number = lenientNumber(value) { sub[key] = .number(number) }
                        } else if let text = value.jsString {
                            sub[key] = .string(text)
                        }
                    }
                    return sub.isEmpty ? nil : .object(sub)
                }
                if !kept.isEmpty { out[key] = .array(kept) }
            }
        }
        return out
    }

    static func lenientBool(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let flag): flag
        case .string(let text): text == "true" ? true : text == "false" ? false : nil
        case .number(let number): number != 0
        default: nil
        }
    }

    static func lenientNumber(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number): number
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}

/// A typed list's entry, by its device id.
protocol DeviceEntry {
    var deviceId: String { get }
}

extension EWeLinkPlugin.Configuration.SingleDevice: DeviceEntry {}
extension EWeLinkPlugin.Configuration.MultiDevice: DeviceEntry {}
extension EWeLinkPlugin.Configuration.ThermostatDevice: DeviceEntry {}
extension EWeLinkPlugin.Configuration.LightDevice: DeviceEntry {}
extension EWeLinkPlugin.Configuration.FanDevice: DeviceEntry {}
extension EWeLinkPlugin.Configuration.SensorDevice: DeviceEntry {}
extension EWeLinkPlugin.Configuration.RFDevice: DeviceEntry {}
