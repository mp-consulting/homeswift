import Foundation
import HomeswiftAI
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the block's `options` (the project, its endpoint, the
// app's account name, `homeWhitelist`, `deviceOverrides` for products and `global`, `debug`); the Access Secret and the
// app's password are the account's credentials, in the vault (TuyaSetup.swift). Each device and scene is a Discovered
// Device by its Tuya id, whose Plugin Accessory Settings are its override: `category`, `unbridged`, `adaptiveLighting` and
// `schema`. A Homebridge block's `deviceOverrides` entry for a device (by its id or uuid) moves into `_accessories` under
// its id; those for a product or `global` stay. A block's `accessKey` and `password` still load, and move into the vault.
extension TuyaPlugin {
    /// The Device Kind of a device, for the settings its editor shows.
    static func kind(of device: TuyaDevice) -> String {
        if device.isScene { return "scene" }
        if device.remote != nil { return "remote" }
        switch device.category {
        case let category where TuyaAccessoryBuilder.lightCategories.contains(category): return "light"
        case "tgq", "tgkg", "bzyd": return "light"
        case "dlq", "kg", "tdq", "qjdcz", "szjqr", "cz", "pc", "wkcz", "cjkg", "wxkg": return "switch"
        case "kt", "ktkzq", "qtwk", "qn", "kj", "xxj", "wk", "wkf", "jsq", "cs", "fs", "fsd", "fskg", "yyj": return "climate"
        case "ckmkzq", "cl", "clkg", "mc": return "cover"
        case "ms", "jtmspro", "mal": return "security"
        case "sp", "wxml": return "camera"
        default: return "sensor"
        }
    }

    public func deviceKind(of deviceID: String) async -> String? {
        runtimes[deviceID].map { Self.kind(of: $0.device) }
    }

    /// The block in its canonical shape: its secrets moved into the vault (the running configuration's, kept there once
    /// the block is written without them; the vault's own win), and the overrides of known devices in `_accessories`.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        let stored = context.credentials(as: TuyaAccountCredentials.self)
        var kept = stored ?? TuyaAccountCredentials()
        let options = block["options"]
        if (kept.accessKey ?? "").isEmpty, options?["accessKey"] != nil, let key = configuration.options?.accessKey, !key.isEmpty { kept.accessKey = key }
        if (kept.password ?? "").isEmpty, options?["password"] != nil, let password = configuration.options?.password, !password.isEmpty {
            kept.password = password
        }
        if kept != (stored ?? TuyaAccountCredentials()) {
            let context = context, credentials = kept
            await context.whenSettingsWritten { try context.saveCredentials(credentials) }
        }
        var known: [String: String] = [:]
        for runtime in runtimes.values {
            known[runtime.device.id] = runtime.device.id
            if !runtime.device.uuid.isEmpty { known[runtime.device.uuid] = runtime.device.id }
        }
        return Self.canonical(block, vaultHasKey: !(kept.accessKey ?? "").isEmpty, vaultHasPassword: !(kept.password ?? "").isEmpty, devices: known)
    }

    /// The keys of an override that are a device's Plugin Accessory Settings.
    static let overrideKeys = ["category", "unbridged", "adaptiveLighting", "schema"]

    /// `devices`: the device id of each id or uuid a `deviceOverrides` entry may name.
    static func canonical(_ block: JSONValue, vaultHasKey: Bool, vaultHasPassword: Bool, devices: [String: String]) -> JSONValue {
        guard var fields = block.objectValue, var options = fields["options"]?.objectValue else { return block }
        if vaultHasKey { options.removeValue(forKey: "accessKey") }
        if vaultHasPassword { options.removeValue(forKey: "password") }
        if let overrides = options["deviceOverrides"]?.arrayValue {
            var entries = AccessoryEntries(fields)
            var left: [JSONValue] = []
            for item in overrides {
                guard let id = item["id"]?.stringValue, let deviceID = devices[id], let values = item.objectValue else {
                    left.append(item)
                    continue
                }
                for key in overrideKeys {
                    if let value = values[key], !value.isNull { entries.setIfAbsent(key, value, on: deviceID) }
                }
            }
            if left.isEmpty { options.removeValue(forKey: "deviceOverrides") } else { options["deviceOverrides"] = .array(left) }
            entries.write(into: &fields)
        }
        fields["options"] = .object(options)
        return .object(fields)
    }
}
