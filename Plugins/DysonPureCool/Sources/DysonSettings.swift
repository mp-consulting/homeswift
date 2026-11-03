import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the block's options (`countryCode`, `pollingInterval`,
// `discoveryTimeout`) and the plugin-wide `enable*` switches; each device's Accessory Settings sit in `_accessories` by
// its serial number (its Device Id): its Name, Excluded, its product type, address and firmware (Setup's), and its own
// switches, named as the plugin-wide ones they default to (`enableTemperature`…, `x-default`), where the Homebridge
// plugin's per-device keys were mostly their inverse (`isTemperatureIgnored`). Its local MQTT credential is in the vault
// under its serial. The Homebridge plugin's `devices` list still loads, read where `_accessories` says nothing;
// `canonicalSettings` moves it, its credentials into the vault.
extension DysonPureCoolPlugin {
    /// A device's Device Kind from its product type: `heater` (Hot+Cool), `humidifier` (Humidify+Cool), `purifier` for the
    /// others.
    static func kind(ofProductType productType: String?) -> String? {
        guard let productType = productType?.nonEmpty else { return nil }
        let features = DeviceCatalog.features(productType)
        return features.heating ? "heater" : features.humidifier ? "humidifier" : "purifier"
    }

    /// From the device the instance runs, else its Accessory Settings' or Homebridge entry's product type.
    public func deviceKind(of deviceID: String) async -> String? {
        if let device = managed[deviceID]?.device { return Self.kind(ofProductType: device.productType) }
        if let productType = context.accessorySettings(for: deviceID).plugin["productType"]?.stringValue?.nonEmpty { return Self.kind(ofProductType: productType) }
        return Self.kind(ofProductType: configuration.devices?.first { $0.serial?.trimmingCharacters(in: .whitespaces) == deviceID }?.productType)
    }

    /// A device's switches as Accessory Settings and the Homebridge keys they were: `inverse` when the Homebridge key
    /// said the opposite (`isTemperatureIgnored` is `enableTemperature` off).
    static var switches: [(setting: String, homebridge: WritableKeyPath<Configuration.Device, Bool?>, key: String, inverse: Bool)] { [
        ("enableTemperature", \.isTemperatureIgnored, "isTemperatureIgnored", true),
        ("enableHumidity", \.isHumidityIgnored, "isHumidityIgnored", true),
        ("enableAirQuality", \.isAirQualityIgnored, "isAirQualityIgnored", true),
        ("enableHeater", \.isHeatingDisabled, "isHeatingDisabled", true),
        ("enableHumidifier", \.isHumidifierDisabled, "isHumidifierDisabled", true),
        ("enableFilterStatus", \.isFilterStatusDisabled, "isFilterStatusDisabled", true),
        ("enableNightMode", \.isNightModeEnabled, "isNightModeEnabled", false),
        ("enableJetFocus", \.isJetFocusEnabled, "isJetFocusEnabled", false),
        ("enableContinuousMonitoring", \.isContinuousMonitoringEnabled, "isContinuousMonitoringEnabled", false),
    ] }

    /// The Accessory Settings that keep their Homebridge name.
    static let sameKeys = [
        "productType", "ipAddress", "firmwareVersion", "temperatureOffset", "humidityOffset", "useFahrenheit", "heatingServiceType", "fullRangeHumidity",
        "enableAutoModeWhenActivating", "enableOscillationWhenActivating", "enableNightModeWhenActivating",
    ]

    /// The Plugin Accessory Settings, as `accessorySchema` declares them.
    static var accessoryKeys: Set<String> { Set(sameKeys + switches.map(\.setting)) }

    /// A device's Accessory Settings as an entry of the Homebridge `devices`: the switches as the Homebridge keys.
    static func entry(fromAccessorySettings settings: [String: JSONValue]) -> Configuration.Device {
        var fields: [String: JSONValue] = [:]
        for key in sameKeys { if let value = settings[key], !value.isNull { fields[key] = value } }
        for item in switches {
            guard let value = settings[item.setting], !value.isNull else { continue }
            // The entry decodes leniently: a boolean written as a string reads too.
            guard let on = (try? JSONValue.object(["value": value]).decode(SwitchValue.self))?.value else { continue }
            fields[item.key] = .bool(item.inverse ? !on : on)
        }
        return (try? JSONValue.object(fields).decode(Configuration.Device.self)) ?? Configuration.Device()
    }

    /// One switch's value, read as leniently as the block's.
    private struct SwitchValue: Decodable {
        var value: Bool?
        init(from decoder: any Decoder) throws {
            value = try decoder.container(keyedBy: Key.self).lenientBool(.value)
        }
        enum Key: String, CodingKey { case value }
    }

    /// A Homebridge entry's settings as Accessory Settings, typed: the inverse keys as their switches; its Name, serial
    /// and credentials are not among them, and `isHeatingSafetyIgnored`, which nothing read, goes.
    static func accessorySettings(of entry: Configuration.Device) -> [String: JSONValue] {
        var settings: [String: JSONValue] = [:]
        func text(_ key: String, _ value: String?) { if let value = value?.trimmingCharacters(in: .whitespaces).nonEmpty { settings[key] = .string(value) } }
        func number(_ key: String, _ value: Double?) { if let value { settings[key] = .number(value) } }
        func bool(_ key: String, _ value: Bool?) { if let value { settings[key] = .bool(value) } }
        text("productType", entry.productType)
        text("ipAddress", entry.ipAddress)
        text("firmwareVersion", entry.firmwareVersion)
        number("temperatureOffset", entry.temperatureOffset)
        number("humidityOffset", entry.humidityOffset)
        bool("useFahrenheit", entry.useFahrenheit)
        text("heatingServiceType", entry.heatingServiceType)
        bool("fullRangeHumidity", entry.fullRangeHumidity)
        bool("enableAutoModeWhenActivating", entry.enableAutoModeWhenActivating)
        bool("enableOscillationWhenActivating", entry.enableOscillationWhenActivating)
        bool("enableNightModeWhenActivating", entry.enableNightModeWhenActivating)
        for item in switches {
            if let value = entry[keyPath: item.homebridge] { settings[item.setting] = .bool(item.inverse ? !value : value) }
        }
        return settings
    }

    /// `entry` with `top`'s settings over it, key by key.
    static func overlay(_ top: Configuration.Device, on entry: Configuration.Device) -> Configuration.Device {
        var merged = entry
        merged.productType = top.productType ?? merged.productType
        merged.ipAddress = top.ipAddress ?? merged.ipAddress
        merged.firmwareVersion = top.firmwareVersion ?? merged.firmwareVersion
        merged.temperatureOffset = top.temperatureOffset ?? merged.temperatureOffset
        merged.humidityOffset = top.humidityOffset ?? merged.humidityOffset
        merged.useFahrenheit = top.useFahrenheit ?? merged.useFahrenheit
        merged.heatingServiceType = top.heatingServiceType ?? merged.heatingServiceType
        merged.fullRangeHumidity = top.fullRangeHumidity ?? merged.fullRangeHumidity
        merged.enableAutoModeWhenActivating = top.enableAutoModeWhenActivating ?? merged.enableAutoModeWhenActivating
        merged.enableOscillationWhenActivating = top.enableOscillationWhenActivating ?? merged.enableOscillationWhenActivating
        merged.enableNightModeWhenActivating = top.enableNightModeWhenActivating ?? merged.enableNightModeWhenActivating
        for item in switches { merged[keyPath: item.homebridge] = top[keyPath: item.homebridge] ?? merged[keyPath: item.homebridge] }
        return merged
    }

    /// The block in its canonical shape (`canonical`), each moved entry's credential kept in the vault under its serial
    /// once the block is written (`whenSettingsWritten`), where the vault has none of its own.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        // The block may only name a credential (a `vault:` reference, a sealed copy): the running configuration has it
        // resolved.
        let resolved = Dictionary((configuration.devices ?? []).compactMap { entry -> (String, String)? in
            guard let serial = entry.serial?.trimmingCharacters(in: .whitespaces).nonEmpty,
                  let credential = (entry.credentials?.nonEmpty ?? entry.localCredentials?.nonEmpty) else { return nil }
            return (serial, credential)
        }) { first, _ in first }
        let (canonical, credentials) = Self.canonical(block, hasCredential: { self.storedLocalCredentials(serial: $0) != nil }) { serial, written in
            resolved[serial] ?? (Self.isReference(written) ? nil : written)
        }
        if !credentials.isEmpty {
            let context = context
            await context.whenSettingsWritten {
                for (serial, credential) in credentials.sorted(by: { $0.key < $1.key }) {
                    try context.saveCredentials(DeviceCredentials(localCredentials: credential), for: serial)
                }
            }
        }
        return canonical
    }

    /// A value the runtime resolves rather than a secret itself.
    static func isReference(_ value: String) -> Bool {
        ["vault:", "enc:", "env:", "file:"].contains { value.hasPrefix($0) }
    }

    /// The block with `devices` moved into `_accessories` by serial: `name` as the Name, the settings typed
    /// (`accessorySettings(of:)`), the credential (`localCredentials`, or `credentials`, its older name) answered to be
    /// kept in the vault, as `credential` reads it, where `hasCredential` says the vault has none. What `_accessories` has
    /// already stays. An entry without a serial, or whose credential `credential` cannot read, stays in `devices`.
    static func canonical(
        _ block: JSONValue, hasCredential: (String) -> Bool, credential: (_ serial: String, _ written: String) -> String?
    ) -> (block: JSONValue, credentials: [String: String]) {
        guard var fields = block.objectValue, let list = fields["devices"]?.arrayValue else { return (block, [:]) }
        var accessories = fields["_accessories"]?.objectValue ?? [:]
        var left: [JSONValue] = []
        var credentials: [String: String] = [:]
        for item in list {
            guard item.objectValue != nil, let entry = try? item.decode(Configuration.Device.self),
                  let serial = entry.serial?.trimmingCharacters(in: .whitespaces).nonEmpty else {
                left.append(item)
                continue
            }
            if let written = entry.credentials?.nonEmpty ?? entry.localCredentials?.nonEmpty, !hasCredential(serial) {
                guard let secret = credential(serial, written) else {
                    left.append(item)
                    continue
                }
                credentials[serial] = secret
            }
            var settings = accessories[serial]?.objectValue ?? [:]
            for (key, value) in accessorySettings(of: entry) where settings[key] == nil { settings[key] = value }
            if let name = entry.name?.trimmingCharacters(in: .whitespaces).nonEmpty, settings["name"] == nil { settings["name"] = .string(name) }
            accessories[serial] = .object(settings)
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        if !accessories.isEmpty { fields["_accessories"] = .object(accessories) }
        return (.object(fields), credentials)
    }
}
