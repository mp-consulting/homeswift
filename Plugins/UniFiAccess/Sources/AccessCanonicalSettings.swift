import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"; docs/adr/0001-canonical-accessory-settings.md): the feature options of a
// Homebridge block (`Enable.Hub.DPS.<id>`, `Disable.Device.<id>`…) are Accessory Settings and Plugin Settings here.
//
// - A controller is a device by its MAC (AccessSetup.swift): its address, MQTT and TLS settings are its Plugin Accessory
//   Settings and its login is in the vault, so a `controllers` entry of a running controller moves there.
// - An option scoped to a device is that device's setting: `Disable.Device.<id>` is Excluded, a Part (`Hub.DPS`,
//   `Hub.SideDoor`…) its `parts`, the others a Plugin Accessory Setting (`Hub.LockDelayInterval` is `lockDelayInterval`).
// - An option without a scope is the Plugin Setting of the same key, the plugin-wide default of the accessory field
//   (`x-default`) or of the Part.
// - An option scoped to a controller, between the two, has no setting of its own: it becomes the setting of each of the
//   controller's devices it applies to (a `Controller.*` option the controller's own).
//
// The runtime reads them back as feature options (`settingOptions`) before the block's own `options`, so the first of
// conflicting entries, which wins, is the canonical one; what `canonicalSettings` cannot read stays in `options`.
extension UniFiAccessPlugin {
    /// A feature option as a setting.
    struct OptionSetting: Sendable, Equatable {
        /// `Hub.DPS`.
        var option: String
        /// Its key in Plugin Settings and Accessory Settings: `dps`.
        var key: String
        /// The Device Kinds its accessory field is for; nil for a Part, which has no accessory field (`parts` keeps it).
        var kinds: [String]?
        /// The Part's id in Accessory Settings' `parts` (`DevicePart`).
        var part: String?
        /// A number (seconds, minutes) rather than a switch.
        var isNumber = false
    }

    static let controllerKind = "controller"
    static let hubKind = "hub"
    static let readerKind = "reader"

    /// The 35 feature options other than `Device` (which is Excluded), in the catalog's order.
    static let optionSettings: [OptionSetting] = {
        let devices = [hubKind, readerKind]
        let hub = [hubKind]
        let controller = [controllerKind]
        return [
            OptionSetting(option: "Device.SyncName", key: "syncName", kinds: devices),
            OptionSetting(option: "Controller.DelayDeviceRemoval", key: "delayDeviceRemoval", kinds: controller, isNumber: true),
            OptionSetting(option: "Controller.Publish.Telemetry", key: "publishTelemetry", kinds: controller),
            OptionSetting(option: "Hub.Door.UseLock", key: "useLock", kinds: hub),
            OptionSetting(option: "Hub.Door.UseGarageOpener", key: "useGarageOpener", kinds: hub),
            OptionSetting(option: "Hub.GateDirectionDuration", key: "gateDirectionDuration", kinds: hub, isNumber: true),
            OptionSetting(option: "Hub.LockDelayInterval", key: "lockDelayInterval", kinds: hub, isNumber: true),
            OptionSetting(option: "Hub.Lock.Trigger", key: "lockTrigger", kinds: hub),
            OptionSetting(option: "Hub.Doorbell", key: "doorbell", part: "Doorbell"),
            OptionSetting(option: "Hub.Doorbell.Trigger", key: "doorbellTrigger", kinds: devices),
            OptionSetting(option: "Hub.Doorbell.SeparateAccessory", key: "doorbellSeparateAccessory", kinds: devices),
            OptionSetting(option: "Hub.Sensors.SeparateAccessory", key: "sensorsSeparateAccessory", kinds: hub),
            OptionSetting(option: "Hub.DPS", key: "dps", part: "DPS"),
            OptionSetting(option: "Hub.REL", key: "rel", part: "REL"),
            OptionSetting(option: "Hub.REN", key: "ren", part: "REN"),
            OptionSetting(option: "Hub.REX", key: "rex", part: "REX"),
            OptionSetting(option: "Hub.SideDoor", key: "sideDoor", part: "SideDoor"),
            OptionSetting(option: "Hub.SideDoor.DPS", key: "sideDoorDps", part: "SideDoor.DPS"),
            OptionSetting(option: "Hub.SideDoor.SeparateAccessory", key: "sideDoorSeparateAccessory", kinds: hub),
            OptionSetting(option: "Hub.SideDoor.Lock.Trigger", key: "sideDoorLockTrigger", kinds: hub),
            OptionSetting(option: "AccessMethod.SeparateAccessory", key: "accessMethodsSeparateAccessory", kinds: devices),
            OptionSetting(option: "AccessMethod.Face", key: "accessMethodFace", kinds: devices),
            OptionSetting(option: "AccessMethod.Hand", key: "accessMethodHand", kinds: devices),
            OptionSetting(option: "AccessMethod.Mobile", key: "accessMethodMobile", kinds: devices),
            OptionSetting(option: "AccessMethod.NFC", key: "accessMethodNfc", kinds: devices),
            OptionSetting(option: "AccessMethod.PIN", key: "accessMethodPin", kinds: devices),
            OptionSetting(option: "AccessMethod.QR", key: "accessMethodQr", kinds: devices),
            OptionSetting(option: "AccessMethod.TouchPass", key: "accessMethodTouchPass", kinds: devices),
            OptionSetting(option: "Log.Doorbell", key: "logDoorbell", kinds: devices),
            OptionSetting(option: "Log.DPS", key: "logDps", kinds: hub),
            OptionSetting(option: "Log.REL", key: "logRel", kinds: hub),
            OptionSetting(option: "Log.REN", key: "logRen", kinds: hub),
            OptionSetting(option: "Log.REX", key: "logRex", kinds: hub),
            OptionSetting(option: "Log.Lock", key: "logLock", kinds: hub),
        ]
    }()

    /// A controller's Plugin Accessory Settings, besides the options: what a `controllers` entry held but its login.
    static let controllerKeys = ["address", "mqttUrl", "mqttTopic", "mqttVerifyTls", "verifyTls"]

    /// The Device Kind of a hub or a reader of a controller.
    static func kind(of device: AccessDevice) -> String {
        device.has(capability: "is_hub") ? hubKind : readerKind
    }

    public func deviceKind(of deviceID: String) async -> String? {
        let id = deviceID.uppercased()
        for controller in controllers {
            if await controller.id == id { return Self.controllerKind }
            if let device = await controller.api.devices?.first(where: { $0.identifier.uppercased() == id }) { return Self.kind(of: device) }
        }
        return context.accessorySettings(for: deviceID).plugin["address"] != nil ? Self.controllerKind : nil
    }

    // MARK: Settings as feature options

    /// The feature options the canonical settings stand for, for the engine: each device's own (by its Device Id), then
    /// the Plugin Settings (no scope). Excluded and Parts are `exclusions` and `partChoices`.
    static func settingOptions(plugin: [String: JSONValue], accessories: [String: AccessorySettings]) -> [String] {
        func option(_ setting: OptionSetting, _ value: JSONValue, scope: String?) -> String? {
            let suffix = scope.map { ".\($0)" } ?? ""
            if setting.isNumber {
                guard let number = value.intValue, number >= 0 else { return nil }
                return "Enable.\(setting.option)\(suffix).\(number)"
            }
            guard let on = value.boolValue else { return nil }
            return "\(on ? "Enable" : "Disable").\(setting.option)\(suffix)"
        }
        var options: [String] = []
        for (deviceID, settings) in accessories.sorted(by: { $0.key < $1.key }) where AccessSettings.isAccessIdentifier(deviceID) {
            for setting in optionSettings where setting.kinds != nil {
                if let value = settings.plugin[setting.key], let entry = option(setting, value, scope: deviceID) { options.append(entry) }
            }
        }
        for setting in optionSettings {
            if let value = plugin[setting.key], let entry = option(setting, value, scope: nil) { options.append(entry) }
        }
        return options
    }

    // MARK: The canonical shape

    /// What the running instance knows of a controller: its MAC, its address and its devices with their Device Kinds
    /// (nil before its first bootstrap).
    struct KnownController: Sendable {
        var mac: String
        var address: String
        var devices: [(id: String, kind: String)]?
    }

    /// The block in its canonical shape, from what the running controllers know: each `controllers` entry of a running
    /// controller moved into its Accessory Settings (its login into the vault first, when the vault has none for it), and
    /// the feature options it can read moved into Accessory Settings and Plugin Settings.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var known: [KnownController] = []
        var logins: Set<String> = []
        let haveLogins = context.haveCredentials(await controllers.asyncMap { await $0.id })
        for controller in controllers {
            guard let mac = await controller.id else { continue }
            let devices = await controller.api.devices.map { list in
                list.filter { $0.isManaged && $0.isSupported && !$0.mac.isEmpty }.map { (id: $0.identifier.uppercased(), kind: Self.kind(of: $0)) }
            }
            known.append(KnownController(mac: mac, address: controller.settings.address, devices: devices))
            // The login the controller runs with (the block's resolved, or the vault's), kept in the vault for its MAC.
            if haveLogins.contains(mac) {
                logins.insert(mac)
            } else if (try? context.saveCredentials(ControllerLogin(username: controller.settings.username, password: controller.settings.password), for: mac)) != nil {
                logins.insert(mac)
            }
        }
        return Self.canonical(block, controllers: known, logins: logins)
    }

    /// `controllers`: the running controllers; `logins`: the MACs whose login the vault keeps.
    static func canonical(_ block: JSONValue, controllers: [KnownController], logins: Set<String>) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]

        // A `controllers` entry of a running controller whose login the vault keeps: its Accessory Settings.
        if let list = fields["controllers"]?.arrayValue {
            var left: [JSONValue] = []
            for item in list {
                guard let entry = item.objectValue, let address = entry["address"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(),
                      let controller = controllers.first(where: { $0.address.trimmingCharacters(in: .whitespaces).lowercased() == address }),
                      logins.contains(controller.mac) else {
                    left.append(item)
                    continue
                }
                var own = entries[controller.mac]?.objectValue ?? [:]
                for key in controllerKeys where own[key] == nil {
                    if let value = entry[key], !value.isNull { own[key] = value }
                }
                if own["name"] == nil, let name = entry["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty { own["name"] = .string(name) }
                entries[controller.mac] = .object(own)
            }
            if left.isEmpty { fields.removeValue(forKey: "controllers") } else { fields["controllers"] = .array(left) }
        }

        // The feature options.
        let options = (fields["options"]?.arrayValue ?? [])
        let controllerIDs = Set(controllers.map(\.mac)).union(entries.filter { $0.value["address"] != nil }.keys.map { $0.uppercased() })
        var claimed: Set<String> = []
        var left: [JSONValue] = []
        var later: [(parsed: ParsedOption, value: JSONValue, raw: JSONValue)] = []
        let globallyOff = options.contains { $0.stringValue.flatMap(parse).map { $0.option == "Device" && $0.scope == nil && !$0.enabled } == true }

        func claim(_ parsed: ParsedOption) -> Bool {
            claimed.insert("\(parsed.option.lowercased())|\(parsed.scope ?? "")").inserted
        }
        func set(_ key: String, _ value: JSONValue, on deviceID: String) {
            var entry = entries[deviceID]?.objectValue ?? [:]
            if entry[key] == nil { entry[key] = value }
            entries[deviceID] = .object(entry)
        }
        func setPart(_ part: String, _ on: Bool, on deviceID: String) {
            var entry = entries[deviceID]?.objectValue ?? [:]
            var parts = entry["parts"]?.objectValue ?? [:]
            if parts[part] == nil { parts[part] = .bool(on) }
            entry["parts"] = .object(parts)
            entries[deviceID] = .object(entry)
        }
        func has(_ key: String, on deviceID: String) -> Bool { entries[deviceID]?[key] != nil }

        for raw in options {
            guard let text = raw.stringValue, let parsed = parse(text) else { left.append(raw); continue }
            // A later entry for the same option and scope never applied: the first wins.
            guard claim(parsed) else { continue }
            if parsed.option == "Device" {
                guard let scope = parsed.scope else { left.append(raw); continue }
                if !parsed.enabled {
                    if entries[scope]?["excluded"] == nil { set("excluded", true, on: scope) }
                } else if globallyOff || controllerIDs.contains(where: { entries[$0]?["excluded"]?.boolValue == true }) {
                    // Turns on one device of those a broader option leaves out: no setting says that.
                    left.append(raw)
                }
                continue
            }
            guard let setting = optionSettings.first(where: { $0.option == parsed.option }), let value = value(of: parsed, setting: setting) else {
                left.append(raw)
                continue
            }
            guard let scope = parsed.scope else {
                // No scope: the Plugin Setting, unless the block has it already; `.null` is the option's own default.
                if fields[setting.key] == nil, !value.isNull { fields[setting.key] = value }
                continue
            }
            if controllerIDs.contains(scope) {
                if setting.kinds == [controllerKind] {
                    guard !value.isNull else { left.append(raw); continue }
                    set(setting.key, value, on: scope)
                } else {
                    later.append((parsed, value, raw))
                }
                continue
            }
            if setting.kinds == [controllerKind] || value.isNull {
                left.append(raw)
                continue
            }
            // A device a controller has now: one it does not, or a controller not known yet, may not be of the setting's kind.
            guard let kind = controllers.lazy.compactMap({ $0.devices?.first { $0.id == scope }?.kind }).first else {
                left.append(raw)
                continue
            }
            if let part = setting.part {
                guard kind == hubKind, let on = value.boolValue else { left.append(raw); continue }
                setPart(part, on, on: scope)
            } else if let kinds = setting.kinds, kinds.contains(kind) {
                if !has(setting.key, on: scope) { set(setting.key, value, on: scope) }
            } else {
                left.append(raw)
            }
        }

        // An option of a controller's devices scoped to the controller: each of its devices it applies to, unless the device
        // has an option of its own for it.
        for (parsed, value, raw) in later {
            guard let scope = parsed.scope, let setting = optionSettings.first(where: { $0.option == parsed.option }), !value.isNull,
                  let devices = controllers.first(where: { $0.mac == scope })?.devices else {
                left.append(raw)
                continue
            }
            for device in devices where !claimed.contains("\(parsed.option.lowercased())|\(device.id)") {
                if let part = setting.part {
                    if device.kind == hubKind, let on = value.boolValue, entries[device.id]?["parts"]?[part] == nil { setPart(part, on, on: device.id) }
                } else if setting.kinds?.contains(device.kind) == true {
                    set(setting.key, value, on: device.id)
                }
            }
        }

        if left.isEmpty { fields.removeValue(forKey: "options") } else { fields["options"] = .array(left) }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }

    /// The setting an option stands for: a switch, a number, or null for a number left at the option's own default
    /// (`Hub.LockDelayInterval` without a value), which no setting says at a device. nil for what cannot be read.
    static func value(of parsed: ParsedOption, setting: OptionSetting) -> JSONValue? {
        guard setting.isNumber else { return parsed.value == nil ? .bool(parsed.enabled) : nil }
        if parsed.enabled, let number = parsed.value { return number >= 0 ? .number(Double(number)) : nil }
        // Off, or on without a value: what the plugin then does (AccessController, AccessHub).
        switch setting.option {
        case "Controller.DelayDeviceRemoval": return .number(0)
        case "Hub.GateDirectionDuration": return .number(Double(AccessSettings.gateDirectionDuration))
        default: return .null
        }
    }

    /// One entry of `options`: on or off, the option (as the catalog spells it), its scope (a Device Id, upper case) and
    /// its value.
    struct ParsedOption: Sendable, Equatable {
        var enabled: Bool
        var option: String
        var scope: String?
        var value: Int?
    }

    /// Every option of the catalog by name, `Device` included.
    static let optionNames: [String] = AccessOptions.categories.flatMap { category in
        (AccessOptions.options[category.name] ?? []).map { $0.name.isEmpty ? category.name : "\(category.name).\($0.name)" }
    }

    /// `Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5` read; nil for an entry of another form (an unknown option, a value
    /// that is not a whole number, a scope that is not a Device Id).
    static func parse(_ raw: String) -> ParsedOption? {
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let action = raw[..<dot].lowercased()
        guard action == "enable" || action == "disable" else { return nil }
        let tail = String(raw[raw.index(after: dot)...])
        let lower = tail.lowercased()
        guard let name = optionNames.filter({ lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + ".") }).max(by: { $0.count < $1.count }) else { return nil }
        let rest = tail.dropFirst(name.count)
        let segments = rest.isEmpty ? [] : rest.dropFirst().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let enabled = action == "enable"
        let isNumber = optionSettings.first { $0.option == name }?.isNumber ?? false
        switch segments.count {
        case 0:
            return ParsedOption(enabled: enabled, option: name)
        case 1 where AccessSettings.isAccessIdentifier(segments[0]):
            return ParsedOption(enabled: enabled, option: name, scope: segments[0].uppercased())
        case 1 where isNumber && enabled:
            return Int(segments[0]).map { ParsedOption(enabled: true, option: name, value: $0) }
        case 2 where isNumber && enabled && AccessSettings.isAccessIdentifier(segments[0]):
            return Int(segments[1]).map { ParsedOption(enabled: true, option: name, scope: segments[0].uppercased(), value: $0) }
        default:
            return nil
        }
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}
