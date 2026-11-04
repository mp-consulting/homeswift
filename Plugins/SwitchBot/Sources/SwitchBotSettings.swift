import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are `options`' rates, retries, hostname, webhook URL and
// logging, and 5.x's request budget; the token and secret are the account's credentials, in the vault
// (SwitchBotSetup.swift). Each device's options sit in `_accessories` by its Device Id, 4.x's seed
// `<deviceId>-<deviceType>` (`<deviceId>-<remoteType>` for a remote), its name as the Core `name`. A Homebridge block's
// `options.devices`, `options.irdevices` (or 5.x's `devices`) still load, and `canonicalSettings` moves them: a device
// the list leaves out becomes Excluded, as the list exposed only the devices it named.
extension SwitchBotPlugin {
    public func deviceKind(of deviceID: String) async -> String? {
        guard let entry = entries[deviceID] else { return nil }
        return entry.info.isRemote ? "remote" : Family(deviceType: entry.info.type)?.kind
    }

    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var block = block
        if var fields = block.objectValue, fields["credentials"] != nil || fields["openApiToken"] != nil || fields["openApiSecret"] != nil {
            let stored = context.credentials(as: AccountKeys.self)
            if stored == nil {
                // The block may name the secret only (a `vault:` reference, a sealed copy): the running configuration has it.
                guard let token = configuration.token, let secret = configuration.secret else { return Self.canonical(block, list: latest) }
                let context = context, keys = AccountKeys(token: token, secret: secret)
                await context.whenSettingsWritten { try context.saveCredentials(keys) }
            }
            for key in ["credentials", "openApiToken", "openApiSecret"] { fields.removeValue(forKey: key) }
            block = .object(fields)
        }
        return Self.canonical(block, list: latest)
    }

    /// The device keys `_accessories` takes, as `accessorySchema` declares them.
    static let deviceKeys: Set<String> = [
        "configDeviceType", "connectionType", "refreshRate", "updateRate", "pushRate", "webhook", "offline",
        "external", "firmware", "logging", "disableCaching", "type", "mode", "doublePress", "pushRatePress", "allowPush", "hide_temperature",
        "hide_humidity", "hide_co2", "convertUnitTo", "hide_lightsensor", "set_minLux", "set_maxLux", "hide_motionsensor", "hide_contactsensor",
        "activate_latchbutton", "hide_leak", "dry", "set_min", "set_max", "set_minStep", "setOpenMode", "setCloseMode", "silentModeSwitch",
        "disable_group", "mapping", "adaptiveLightingShift",
    ]
    static let remoteKeys: Set<String> = [
        "configRemoteType", "connectionType", "external", "firmware", "logging", "customize", "customOn", "customOff", "commandType",
        "disablePushOn", "disablePushOff", "disablePushDetail", "type", "rotation_speed", "swing_mode", "set_minStep", "set_min", "set_max",
        "stateless", "hide_automode", "set_max_heat", "set_min_heat", "set_max_cool", "set_min_cool", "meterType", "meterId",
    ]
    /// Spellings read as another key.
    static let renamed = ["set_minlux": "set_minLux", "set_maxlux": "set_maxLux", "botDisplay": "type"]

    /// The block with its device lists moved into `_accessories` (`list`: the cloud's devices, which give each its
    /// type; without it the lists stay). An entry's keys the schema does not declare (Bluetooth's, MQTT's) stay in the
    /// list under its `deviceId`.
    static func canonical(_ block: JSONValue, list: DeviceList?) -> JSONValue {
        guard var fields = block.objectValue, let list else { return block }
        var options = fields["options"]?.objectValue ?? [:]
        var entries = AccessoryEntries(fields)
        var changed = false
        func move(_ items: [JSONValue], remote: Bool) -> [JSONValue] {
            let cloud = remote ? list.remotes : list.devices
            let typeKey = remote ? "remoteType" : "deviceType"
            var listed = Set<String>()
            var left: [JSONValue] = []
            for item in items {
                guard let entry = item.objectValue, let id = DeviceOptions(entry).deviceID else { left.append(item); continue }
                let raw = cloud.first { $0["deviceId"]?.stringValue.map(normalizedID) == normalizedID(id) }
                guard let type = raw?[typeKey]?.stringValue ?? DeviceOptions(entry).string(remote ? "configRemoteType" : "configDeviceType") else {
                    left.append(item)
                    continue
                }
                let deviceID = "\(id)-\(type)"
                if let raw, let cloudID = raw["deviceId"]?.stringValue { listed.insert(normalizedID(cloudID)) }
                var rest: [String: JSONValue] = [:]
                for (key, value) in entry where !value.isNull {
                    let key = renamed[key] ?? key
                    switch key {
                    case "deviceId": continue
                    case "configDeviceName": if let name = value.stringValue, !name.isEmpty { entries.setIfAbsent("name", .string(name), on: deviceID) }
                    case "room": entries.setIfAbsent("room", value, on: deviceID)
                    case "hide_device": if DeviceOptions(entry).flag("hide_device") { entries.exclude(deviceID) }
                    case "enabled": if value.boolValue == false { entries.exclude(deviceID) }
                    case "type": entries.setIfAbsent("type", value.stringValue.map { .string($0.lowercased()) } ?? value, on: deviceID)
                    case _ where (remote ? remoteKeys : deviceKeys).contains(key): entries.setIfAbsent(key, value, on: deviceID)
                    default: rest[key] = value
                    }
                }
                if !rest.isEmpty {
                    rest["deviceId"] = .string(id)
                    left.append(.object(rest))
                }
                // An entry left with only its undeclared keys keeps the device listed.
                if entries.entries[deviceID] == nil { entries.setIfAbsent("excluded", false, on: deviceID) }
            }
            // The list exposed only the devices it named: the others are Excluded.
            for raw in cloud {
                guard let cloudID = raw["deviceId"]?.stringValue, let type = raw[typeKey]?.stringValue, !listed.contains(normalizedID(cloudID)) else { continue }
                let deviceID = "\(cloudID)-\(type)"
                if entries.entries[deviceID] == nil { entries.exclude(deviceID) }
            }
            changed = true
            return left
        }
        if let items = options["devices"]?.arrayValue, !items.isEmpty {
            let left = move(items, remote: false)
            if left.isEmpty { options.removeValue(forKey: "devices") } else { options["devices"] = .array(left) }
        } else if let items = fields["devices"]?.arrayValue, !items.isEmpty {
            let left = move(items, remote: false)
            if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        }
        if let items = options["irdevices"]?.arrayValue, !items.isEmpty {
            let left = move(items, remote: true)
            if left.isEmpty { options.removeValue(forKey: "irdevices") } else { options["irdevices"] = .array(left) }
        }
        guard changed else { return .object(fields) }
        if fields["options"] != nil || !options.isEmpty { fields["options"] = .object(options) }
        entries.write(into: &fields)
        return .object(fields)
    }
}
