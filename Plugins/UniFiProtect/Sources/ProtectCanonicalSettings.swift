import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"; docs/adr/0001-canonical-accessory-settings.md): the feature options of a
// Homebridge block (`Enable.Motion.Duration.<MAC>.30`, `Disable.Device.<MAC>`…) are Accessory Settings and Plugin
// Settings here, one setting per option of the catalog (`optionSettings`, made from FeatureOptionCatalog.swift: a key
// named after the option, the Device Kinds its models are).
//
// - A controller is a device by its NVR's MAC, of the Device Kind `nvr` (ProtectSetup.swift): its address, MQTT, TLS,
//   playlist and doorbell message settings are its Plugin Accessory Settings, its login and playlist token in the vault,
//   so a `controllers` entry of a running controller moves there, its `cameraOverrides` into each third-party camera's
//   settings (`thirdPartyCamera`), an ONVIF password into that camera's credentials.
// - An option scoped to a device is that device's setting: `Disable.Device.<MAC>` Excluded, a Part (`parts`) its
//   `parts`, the others a Plugin Accessory Setting.
// - An option without a scope is the Plugin Setting of the same key, the plugin-wide default (`x-default`).
// - An option scoped to a controller (its MAC, or its address as Homebridge's page wrote it) becomes the setting of each
//   of the controller's devices it applies to (an NVR's option the controller's own).
//
// The runtime reads the settings back as feature options before the block's own `options` (`settingOptions`), so the
// canonical ones win; what `canonicalSettings` cannot read (an option turned off that takes a value, an option of a
// device the controller does not have now) stays in `options`.
extension UniFiProtectPlugin {
    /// A feature option as a setting.
    struct OptionSetting: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case toggle, number, text }

        /// `Motion.Duration`.
        var option: String
        /// Its key in Plugin Settings and Accessory Settings: `motionDuration`.
        var key: String
        /// The Device Kinds its accessory field is for; empty for a Part, which `parts` keeps.
        var kinds: [String]
        var kind: Kind
        var isPart: Bool { Self.parts.contains(option) }

        /// The options Add accessories offers as Parts (`UniFiProtectPlugin.parts(of:category:test:)`).
        static let parts: Set<String> = [
            "Doorbell.PackageCamera.Flashlight", "Doorbell.Mute", "Doorbell.PhysicalChime", "Doorbell.AuthSensor", "Motion.OccupancySensor", "Motion.Switch",
            "Device.StatusLed.Switch", "Device.NightVision.Dimmer", "Video.HKSV.Recording.Switch",
        ]
    }

    static let nvrKind = "nvr"
    static let cameraKind = "camera"
    static let thirdPartyCameraKind = "thirdPartyCamera"
    /// Every Device Kind: the NVR and each category of ProtectNVR.deviceCategories, a third-party camera apart.
    static let deviceKinds = [cameraKind, thirdPartyCameraKind, "chime", "light", "sensor", "viewer", nvrKind]

    /// The Device Kind of one of a bootstrap's devices.
    static func kind(category: String, device: JSONValue) -> String {
        category == cameraKind && device.bool("isThirdPartyCamera") ? thirdPartyCameraKind : category
    }

    /// `Audio.Filter.Noise.FftNr` as `audioFilterNoiseFftNr`; `Doorbell.Messages` as `doorbellMessagesEnabled`, as a
    /// controller's `doorbellMessages` are its message presets.
    static func settingKey(_ option: String) -> String {
        if option == "Doorbell.Messages" { return "doorbellMessagesEnabled" }
        let words = option.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = words.first else { return option }
        return first.prefix(1).lowercased() + first.dropFirst() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// The 78 options other than `Device` (which is Excluded), in the catalog's order: each one's Device Kinds are its
    /// models' (its category's when it names none), a camera's without the third-party cameras the option is not for.
    static let optionSettings: [OptionSetting] = FeatureOptionCatalog.categories.flatMap { category -> [OptionSetting] in
        (FeatureOptionCatalog.options[category.name] ?? []).compactMap { entry -> OptionSetting? in
            let option = FeatureOptions.expand(category.name, entry.name)
            guard option != "Device" else { return nil }
            let models = entry.modelKey ?? category.modelKey
            let notThirdParty = (entry.isNotProperty ?? []).contains("isThirdPartyCamera") || (category.isNotProperty ?? []).contains("isThirdPartyCamera")
            var kinds: [String] = []
            for model in models {
                switch model {
                case "all": kinds += deviceKinds
                case cameraKind: kinds += notThirdParty ? [cameraKind] : [cameraKind, thirdPartyCameraKind]
                default: kinds.append(model)
                }
            }
            var unique: [String] = []
            for kind in kinds where !unique.contains(kind) { unique.append(kind) }
            let kind: OptionSetting.Kind = switch entry.defaultValue {
            case .number: .number
            case .text: .text
            case nil: .toggle
            }
            var setting = OptionSetting(option: option, key: settingKey(option), kinds: unique, kind: kind)
            if setting.isPart { setting.kinds = [] }
            return setting
        }
    }

    /// A controller's Plugin Accessory Settings, besides the options: what a `controllers` entry held but its login,
    /// its name (its Name), its playlist token (in the vault) and its camera overrides (each camera's).
    static let controllerKeys = ["address", "doorbellMessages", "mqttTopic", "mqttUrl", "mqttVerifyTls", "overrideAddress", "playlistAddress", "verifyTls"]
    /// A third-party camera's, from a camera override: its ONVIF password goes in its credentials.
    static let cameraOverrideKeys = ["rtspUrl", "snapshotUrl", "onvifPort", "onvifUsername", "onvifServicePath"]

    /// What the vault keeps for a third-party camera: the ONVIF password the page used to keep in its override.
    struct CameraCredentials: Codable, Sendable, Equatable {
        var onvifPassword: String
    }

    public func deviceKind(of deviceID: String) async -> String? {
        let id = deviceID.uppercased()
        for nvr in controllers {
            let state = await nvr.setupState()
            if state.mac.uppercased() == id { return Self.nvrKind }
            if let device = Self.devices(of: state.bootstrap).first(where: { $0.id == id }) { return device.kind }
        }
        return context.accessorySettings(for: deviceID).plugin["address"] != nil ? Self.nvrKind : nil
    }

    /// A bootstrap's adopted devices, by MAC, with their Device Kinds; nil without a bootstrap.
    static func devices(of bootstrap: JSONValue?) -> [(id: String, kind: String)] {
        guard let bootstrap else { return [] }
        return ProtectNVR.deviceCategories.flatMap { category in
            bootstrap.array(category + "s").filter { $0.bool("isAdopted") && !$0.bool("isAdoptedByOther") }.compactMap { device in
                device.string("mac")?.nonEmpty.map { (id: normalizedMAC($0), kind: kind(category: category, device: device)) }
            }
        }
    }

    // MARK: Settings as feature options

    /// The feature options the canonical settings stand for: each device's own (by its MAC), then the Plugin Settings.
    /// Excluded and Parts are `exclusions` and `partChoices`.
    static func settingOptions(plugin: [String: JSONValue], accessories: [String: AccessorySettings]) -> [String] {
        func option(_ setting: OptionSetting, _ value: JSONValue, scope: String?) -> String? {
            let suffix = scope.map { ".\($0)" } ?? ""
            switch setting.kind {
            case .toggle:
                guard let on = value.boolValue else { return nil }
                return "\(on ? "Enable" : "Disable").\(setting.option)\(suffix)"
            case .number:
                guard let number = value.doubleValue, number.isFinite else { return nil }
                return "Enable.\(setting.option)\(suffix).\(jsNumber(number))"
            case .text:
                guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !text.contains(".") else { return nil }
                return "Enable.\(setting.option)\(suffix).\(text)"
            }
        }
        var options: [String] = []
        for (deviceID, settings) in accessories.sorted(by: { $0.key < $1.key }) where isMAC(deviceID) {
            for setting in optionSettings where !setting.isPart {
                if let value = settings.plugin[setting.key], let entry = option(setting, value, scope: deviceID) { options.append(entry) }
            }
        }
        for setting in optionSettings {
            if let value = plugin[setting.key], let entry = option(setting, value, scope: nil) { options.append(entry) }
        }
        return options
    }

    /// A MAC as Protect writes it: twelve hexadecimal digits.
    static func isMAC(_ text: String) -> Bool { text.count == 12 && text.allSatisfy(\.isHexDigit) }

    // MARK: The canonical shape

    /// What the running instance knows of a controller: its NVR's MAC, its address and its devices with their Device
    /// Kinds (nil before its first bootstrap).
    struct KnownController: Sendable {
        var mac: String
        var address: String
        var devices: [(id: String, kind: String)]?
    }

    /// The block in its canonical shape, from what the running controllers know: each `controllers` entry of a running
    /// controller moved into its Accessory Settings (its login and playlist token, and its cameras' ONVIF passwords, into
    /// the vault once the block is written without them), and the feature options it can read into Accessory Settings
    /// and Plugin Settings.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        var known: [KnownController] = []
        var logins: Set<String> = []
        for nvr in controllers {
            let state = await nvr.setupState()
            let mac = Self.normalizedMAC(state.mac)
            guard Self.isMAC(mac) else { continue }
            known.append(KnownController(mac: mac, address: state.address, devices: state.bootstrap.map { Self.devices(of: $0) }))
            logins.insert(mac)
        }
        // Each controller's login (the block's resolved one, or the vault's) and playlist token, kept in the vault for
        // its MAC; each moved camera override's ONVIF password, for the camera.
        let context = context
        for entry in controllerEntries() {
            guard let controller = known.first(where: { $0.address.trimmingCharacters(in: .whitespaces).lowercased() == entry.address.trimmingCharacters(in: .whitespaces).lowercased() }) else {
                continue
            }
            let saved = context.credentials(for: controller.mac, as: ControllerLogin.self)
            let login = ControllerLogin(username: entry.username, password: entry.password, playlistToken: saved?.playlistToken ?? entry.playlistToken?.nonEmpty)
            if login != saved { await context.whenSettingsWritten { try context.saveCredentials(login, for: controller.mac) } }
            for override in entry.cameraOverrides {
                let camera = Self.normalizedMAC(override.mac)
                guard Self.isMAC(camera), let password = override.onvifPassword?.nonEmpty, context.credentials(for: camera) == nil else { continue }
                await context.whenSettingsWritten { try context.saveCredentials(CameraCredentials(onvifPassword: password), for: camera) }
            }
        }
        return Self.canonical(block, controllers: known, logins: logins)
    }

    /// `controllers`: the running controllers; `logins`: the MACs whose login the vault keeps (or will once the block is
    /// written).
    static func canonical(_ block: JSONValue, controllers: [KnownController], logins: Set<String>) -> JSONValue {
        guard var fields = block.objectValue else { return block }
        var entries = fields["_accessories"]?.objectValue ?? [:]
        func normalized(_ address: String) -> String { address.trimmingCharacters(in: .whitespaces).lowercased() }

        // A `controllers` entry of a running controller whose login the vault keeps: its Accessory Settings, and its camera
        // overrides each camera's.
        if let list = fields["controllers"]?.arrayValue {
            var left: [JSONValue] = []
            for item in list {
                guard let entry = item.objectValue, let address = entry["address"]?.stringValue.map(normalized),
                      let controller = controllers.first(where: { normalized($0.address) == address }), logins.contains(controller.mac) else {
                    left.append(item)
                    continue
                }
                var own = entries[controller.mac]?.objectValue ?? [:]
                for key in controllerKeys where own[key] == nil {
                    if let value = entry[key], !value.isNull, value != .array([]) { own[key] = value }
                }
                if own["name"] == nil, let name = entry["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty { own["name"] = .string(name) }
                entries[controller.mac] = .object(own)
                for override in entry["cameraOverrides"]?.arrayValue ?? [] {
                    guard let mac = override["mac"]?.stringValue.map(normalizedMAC), isMAC(mac) else { continue }
                    var camera = entries[mac]?.objectValue ?? [:]
                    for key in cameraOverrideKeys where camera[key] == nil {
                        if let value = override[key], !value.isNull, value != "" { camera[key] = value }
                    }
                    if !camera.isEmpty { entries[mac] = .object(camera) }
                }
            }
            if left.isEmpty { fields.removeValue(forKey: "controllers") } else { fields["controllers"] = .array(left) }
        }

        // The feature options.
        let options = fields["options"]?.arrayValue ?? []
        var controllerScopes: [String: String] = [:]
        for controller in controllers {
            controllerScopes[controller.mac] = controller.mac
            controllerScopes[normalized(controller.address)] = controller.mac
        }
        for (id, entry) in entries where entry["address"] != nil && isMAC(id.uppercased()) {
            controllerScopes[id.uppercased()] = id.uppercased()
            if let address = entry["address"]?.stringValue { controllerScopes[normalized(address)] = controllerScopes[normalized(address)] ?? id.uppercased() }
        }
        let addresses = controllerScopes.keys.filter { $0.contains(".") }
        var claimed: Set<String> = []
        var left: [JSONValue] = []
        var later: [(parsed: ParsedOption, value: JSONValue, raw: JSONValue)] = []
        let globallyOff = options.contains { $0.stringValue.flatMap { parse($0, addresses: addresses) }.map { $0.option == "Device" && $0.scope == nil && !$0.enabled } == true }
        // The controllers a Device option leaves out (the first for its scope is the one that applies), wherever it is in
        // the list: a device turned back on under one of them says what no setting does, before or after it.
        var firstDevice: [String: Bool] = [:]
        for raw in options {
            guard var parsed = raw.stringValue.flatMap({ parse($0, addresses: addresses) }), parsed.option == "Device", let scope = parsed.scope else { continue }
            if let mac = controllerScopes[scope.lowercased()] ?? controllerScopes[scope] { parsed.scope = mac }
            if let scope = parsed.scope, firstDevice[scope] == nil { firstDevice[scope] = parsed.enabled }
        }
        let controllerOff = Set(controllerScopes.values).contains { entries[$0]?["excluded"]?.boolValue == true || firstDevice[$0] == false }

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

        for raw in options {
            guard let text = raw.stringValue, var parsed = parse(text, addresses: addresses) else { left.append(raw); continue }
            // A controller's address as its MAC.
            if let scope = parsed.scope, let mac = controllerScopes[scope.lowercased()] ?? controllerScopes[scope] { parsed.scope = mac }
            guard claimed.insert("\(parsed.option.lowercased())|\(parsed.scope ?? "")").inserted else { continue }
            if parsed.option == "Device" {
                guard let scope = parsed.scope else { left.append(raw); continue }
                if !parsed.enabled {
                    set("excluded", true, on: scope)
                } else if globallyOff || controllerOff {
                    // Turns on one device of those a broader option leaves out: no setting says that.
                    left.append(raw)
                }
                continue
            }
            guard let setting = optionSettings.first(where: { $0.option.lowercased() == parsed.option.lowercased() }), let value = value(of: parsed, setting: setting) else {
                left.append(raw)
                continue
            }
            guard let scope = parsed.scope else {
                if fields[setting.key] == nil { fields[setting.key] = value }
                continue
            }
            if Set(controllerScopes.values).contains(scope) {
                if setting.kinds.contains(nvrKind) {
                    set(setting.key, value, on: scope)
                } else {
                    later.append((parsed, value, raw))
                }
                continue
            }
            // A device a controller has now: one it does not may not be of the setting's kind.
            guard let kind = controllers.lazy.compactMap({ $0.devices?.first { $0.id == scope }?.kind }).first else {
                left.append(raw)
                continue
            }
            if setting.isPart, let on = value.boolValue {
                setPart(setting.option, on, on: scope)
            } else if setting.kinds.contains(kind) {
                set(setting.key, value, on: scope)
            } else {
                left.append(raw)
            }
        }

        // An option of a controller's devices scoped to the controller: each of its devices it applies to, unless the device
        // has an option of its own for it.
        for (parsed, value, raw) in later {
            guard let scope = parsed.scope, let setting = optionSettings.first(where: { $0.option.lowercased() == parsed.option.lowercased() }),
                  let devices = controllers.first(where: { $0.mac == scope })?.devices else {
                left.append(raw)
                continue
            }
            for device in devices where !claimed.contains("\(parsed.option.lowercased())|\(device.id)") {
                if setting.isPart {
                    if let on = value.boolValue, entries[device.id]?["parts"]?[setting.option] == nil { setPart(setting.option, on, on: device.id) }
                } else if setting.kinds.contains(device.kind) {
                    set(setting.key, value, on: device.id)
                }
            }
        }

        if left.isEmpty { fields.removeValue(forKey: "options") } else { fields["options"] = .array(left) }
        if !entries.isEmpty { fields["_accessories"] = .object(entries) }
        return .object(fields)
    }

    /// The setting an option stands for; nil for an option turned off that takes a value (the plugin then does without
    /// it, which no setting says) or a value that is not of the option's kind.
    static func value(of parsed: ParsedOption, setting: OptionSetting) -> JSONValue? {
        switch setting.kind {
        case .toggle:
            return parsed.value == nil ? .bool(parsed.enabled) : nil
        case .number:
            guard parsed.enabled, let text = parsed.value, let number = Double(text), number.isFinite else { return nil }
            return .number(number)
        case .text:
            guard parsed.enabled, let text = parsed.value, !text.isEmpty else { return nil }
            return .string(text)
        }
    }

    /// One entry of `options`: on or off, the option (as the catalog spells it), its scope (a MAC, upper case, or a
    /// controller's address) and its value.
    struct ParsedOption: Sendable, Equatable {
        var enabled: Bool
        var option: String
        var scope: String?
        var value: String?
    }

    /// Every option of the catalog by name, `Device` included.
    static let optionNames: [String] = FeatureOptionCatalog.categories.flatMap { category in
        (FeatureOptionCatalog.options[category.name] ?? []).map { FeatureOptions.expand(category.name, $0.name) }
    }

    /// `Enable.Motion.Duration.F4E2C6000001.30` read; `addresses` are the controllers' addresses (lower case), which a
    /// scope may be. nil for an entry of another form.
    static func parse(_ raw: String, addresses: [String] = []) -> ParsedOption? {
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let action = raw[..<dot].lowercased()
        guard action == "enable" || action == "disable" else { return nil }
        let tail = String(raw[raw.index(after: dot)...])
        let lower = tail.lowercased()
        guard let name = optionNames.filter({ lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + ".") }).max(by: { $0.count < $1.count }) else { return nil }
        var parsed = ParsedOption(enabled: action == "enable", option: name)
        let rest = String(tail.dropFirst(name.count + 1))
        guard tail.count > name.count else { return parsed }
        func split(_ text: String) -> (String, String?) {
            guard let dot = text.firstIndex(of: ".") else { return (text, nil) }
            return (String(text[..<dot]), String(text[text.index(after: dot)...]))
        }
        if let address = addresses.sorted(by: { $0.count > $1.count }).first(where: { rest.lowercased() == $0 || rest.lowercased().hasPrefix($0 + ".") }) {
            parsed.scope = address
            parsed.value = rest.count > address.count ? String(rest.dropFirst(address.count + 1)) : nil
        } else {
            let (first, remainder) = split(rest)
            if isMAC(first) {
                parsed.scope = first.uppercased()
                parsed.value = remainder
            } else {
                parsed.value = rest
            }
        }
        if parsed.value?.isEmpty == true || (!parsed.enabled && parsed.value != nil) { return nil }
        return parsed
    }
}
