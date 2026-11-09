import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

// The settings writers (docs/adr/0002-schema-declares-every-setting.md, 0003-room-and-visibility-in-accessory-settings.md):
// one for an accessory's Accessory Settings, one for a plugin instance's Plugin Settings, both checked against what the
// plugin's config.schema.json declares, and `get_settings`/`update_settings` over them (the web UI's
// `/api/settings/…` routes call the same).
//
// An accessory's settings live in its block's `_accessories`: its Core Accessory Settings under its key (its Device Id, or
// for a device's other accessories its Accessory Id without the platform), and Excluded, Parts and its Plugin Accessory
// Settings under its device's Device Id, which is the same key unless the plugin names the device of an accessory
// itself (`HomeswiftPlugin.deviceID(ofAccessory:)`). Room and Hidden that `accessory-layout.json` kept, and a block's
// `_hiddenFromHomeKit`, are read as long as they are there and move into `_accessories` on the next write.

extension HomeswiftCatalog {
    // MARK: Declarations

    /// A platform's config.schema.json, the runtime's own blocks' included.
    func schemaFile(for platform: String) -> JSONValue? {
        guard let text = blockSchemas[platform] ?? host.registry.entry(for: platform)?.configurationSchemaJSON else { return nil }
        return try? JSONValue(string: text)
    }

    /// The Plugin Accessory Settings a platform declares: its schema's `accessorySchema.properties`.
    func accessoryFields(for platform: String) -> [String: JSONValue] {
        schemaFile(for: platform)?["accessorySchema"]?["properties"]?.objectValue ?? [:]
    }

    /// The Core Accessory Settings, as JSON Schema.
    static let coreAccessoryFields: [String: JSONValue] = [
        "name": ["type": "string", "maxLength": .number(Double(AccessoryNaming.maxLength)), "description": "Its Name, on the bridge's pages and in Apple Home alike; cleared, the name its plugin gives it"],
        "room": ["type": "string", "maxLength": .number(Double(AccessoryLayout.maxName)), "description": "Its Room; empty for none (a mirrored accessory then leaves the room its controller suggests); cleared, the suggested room or none"],
        "hidden": ["type": "boolean", "description": "Hidden: in Apple Home, but off the web UI's wall"],
        "notInHome": ["type": "boolean", "description": "Not in Home: on the bridge and the wall, but left out of Apple Home, which loses its room, scenes and automations"],
        "excluded": ["type": "boolean", "description": "Excluded: its plugin does not make the device into an accessory at all; the plugin reloads"],
        "separateFunctions": ["type": "boolean", "description": "Separate Functions: each thing it does (a light, a sensor) an accessory of its own in Apple Home, with its own Name, Room and Group; it keeps its main Function. Apple Home's scenes and automations on the separated Functions need redoing, both ways"],
        "parts": ["type": "object", "additionalProperties": ["type": "boolean"], "description": "The Parts of the device included (true) or left out (false), by the plugin's part id; the plugin reloads"],
        "energyRoles": ["type": "object", "additionalProperties": ["type": ["string", "null"], "enum": ["solar", "home", "grid", "battery", "none", .null]],
                        "description": "The Energy Role of each of its Meters in the Home Energy, by the Meter's key (get_settings' meters): solar, home, grid, battery, or none for a single device's use; null gives back its plugin's suggestion"],
        "controls": ["type": "array", "items": ["type": "object"],
                     "description": "A Remote's Controls, what each gesture of its Buttons and Wheels does (list_remotes says its parts and their gestures): {part, gesture: press|double|long|hold|turn, action: toggle|on|off|scene|stop|dim|step, targets: [light or shutter ids], power: [switch or outlet ids], scene, direction: alternate|up|down, step: 1-25, reversed, powerDelay: 1-30}; the Remotes page edits them"],
        "naturalLight": ["type": "boolean",
                         "description": "Natural Light: a light that can have it comes back as it was, in the white for the time of day, when its power comes on; false once it has one of its device's own Power On (set_power_on sets both)"],
    ]

    /// The Device Kinds a field is for (`x-kinds`); nil for every kind.
    static func kinds(of field: JSONValue) -> [String]? {
        field["x-kinds"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// `field` for a device of the Device Kind `kind`: the choices of its `oneOf`/`anyOf` that name other kinds (`x-kinds`
    /// on a choice, as Govee's `showAs` lists a switch's types beside a light's) left out, through its objects' properties,
    /// its maps' values and its lists' items.
    static func forKind(_ field: JSONValue, kind: String) -> JSONValue {
        guard var object = field.objectValue else { return field }
        for keyword in ["oneOf", "anyOf"] {
            guard let choices = object[keyword]?.arrayValue else { continue }
            object[keyword] = .array(choices.filter { choice in kinds(of: choice).map { $0.contains(kind) } ?? true }.map { forKind($0, kind: kind) })
        }
        if let properties = object["properties"]?.objectValue { object["properties"] = .object(properties.mapValues { forKind($0, kind: kind) }) }
        for key in ["items", "additionalProperties"] where object[key]?.objectValue != nil { object[key] = forKind(object[key]!, kind: kind) }
        return .object(object)
    }

    /// `field` offering `choices` (`HomeswiftPlugin.accessorySettingChoices`): its own, or its items' for a list, as a
    /// `oneOf` of titled values, which the editor shows as a menu or checkboxes.
    static func withChoices(_ field: JSONValue, _ choices: [SetupOption]) -> JSONValue {
        guard var object = field.objectValue else { return field }
        let oneOf = JSONValue.array(choices.map { choice in
            // The title as it is (an accessory's name), the detail words the web UI's catalogs translate: "title · detail".
            var option: [String: JSONValue] = ["enum": [.string(choice.value)], "title": .string(choice.label), "x-catalog": true]
            if let detail = choice.detail { option["x-detail"] = .string(detail) }
            return .object(option)
        })
        if object["type"] == "array" {
            var items = object["items"]?.objectValue ?? ["type": "string"]
            items["oneOf"] = oneOf
            object["items"] = .object(items)
        } else {
            object["oneOf"] = oneOf
        }
        return .object(object)
    }

    /// A field as `JSONSchema` checks it: Homebridge's keys made standard, the `x-` ones left out.
    static func checkable(_ field: JSONValue) -> JSONValue {
        guard var object = field.objectValue else { return field }
        for key in object.keys where key.hasPrefix("x-") { object.removeValue(forKey: key) }
        return JSONGeneration.normalizePluginSchema(.object(object), forChecking: true)
    }

    /// What is wrong with a schema's `accessorySchema`: a field that is not an object, `x-kinds` that is not a list of
    /// names, `x-default` that names no Plugin Setting of the schema, a field named like a Core Accessory Setting.
    public static func accessorySchemaProblems(_ file: JSONValue) -> [String] {
        guard let section = file["accessorySchema"] else { return [] }
        guard let properties = section["properties"]?.objectValue else { return ["accessorySchema must have properties"] }
        let pluginSettings = (file["schema"]?["properties"] ?? file["schema"])?.objectValue ?? [:]
        var problems: [String] = []
        for (key, field) in properties.sorted(by: { $0.key < $1.key }) {
            guard field.objectValue != nil else { problems.append("accessorySchema.\(key) must be an object"); continue }
            if AccessorySettings.coreKeys.contains(key) || key.hasPrefix("_") { problems.append("accessorySchema.\(key) is a Core Accessory Setting or a runtime key") }
            if let kinds = field["x-kinds"], kinds.arrayValue?.allSatisfy({ $0.stringValue?.isEmpty == false }) != true {
                problems.append("accessorySchema.\(key).x-kinds must be a list of Device Kinds")
            }
            if let fallback = field["x-default"] {
                if let setting = fallback.stringValue {
                    if pluginSettings[setting] == nil { problems.append("accessorySchema.\(key).x-default names \(setting), which the schema does not declare") }
                } else {
                    problems.append("accessorySchema.\(key).x-default must name a Plugin Setting")
                }
            }
        }
        return problems
    }

    /// What is wrong with one `_accessories` entry: Core Accessory Settings by type, declared Plugin Accessory Settings
    /// against their schemas. With `before`, only what changed from it is checked. `strict` (the settings writers) also
    /// refuses a key the plugin does not declare, and one declared for other Device Kinds than `kind`.
    static func settingsProblems(
        _ entry: [String: JSONValue], fields: [String: JSONValue], kind: String?, strict: Bool, before: [String: JSONValue]? = nil
    ) -> [JSONSchema.Problem] {
        var problems: [JSONSchema.Problem] = []
        for (key, value) in entry.sorted(by: { $0.key < $1.key }) where before?[key] != value {
            let at: [JSONSchema.PathComponent] = [.key(key)]
            switch key {
            case "name":
                if value.stringValue == nil { problems.append(.init(path: at, message: "must be a name")) }
            case "room":
                if let room = value.stringValue {
                    if room.trimmingCharacters(in: .whitespacesAndNewlines).count > AccessoryLayout.maxName {
                        problems.append(.init(path: at, message: "must be at most \(AccessoryLayout.maxName) characters"))
                    }
                } else {
                    problems.append(.init(path: at, message: "must be a room's name"))
                }
            case _ where flagKeys.contains(key):
                if value.boolValue == nil { problems.append(.init(path: at, message: "must be true or false")) }
            case "parts":
                if value.objectValue?.values.allSatisfy({ $0.boolValue != nil }) != true {
                    problems.append(.init(path: at, message: "must be an object of true or false by part"))
                }
            case "energyRoles":
                if value.objectValue?.values.allSatisfy({ $0.isNull || $0.stringValue.map(AccessorySettings.energyRoleChoices.contains) == true }) != true {
                    problems.append(.init(path: at, message: "must be an object of solar, home, grid, battery or none by Meter"))
                }
            case "naturalLight":
                if value.boolValue == nil { problems.append(.init(path: at, message: "must be true or false")) }
            case "controls":
                if let controls = RemoteControl.list(from: value) {
                    if let problem = RemoteControl.problem(in: controls) { problems.append(.init(path: at, message: problem)) }
                } else {
                    problems.append(.init(path: at, message: "must be a list of Controls: {part, gesture, action, targets, power, scene, direction, step, reversed, powerDelay}"))
                }
            default:
                guard let field = fields[key] else {
                    if strict { problems.append(.init(path: at, message: "is not an Accessory Setting the plugin declares (its schema's accessorySchema)")) }
                    continue
                }
                if strict, field["readOnly"]?.boolValue == true {
                    problems.append(.init(path: at, message: "is set when the accessory is added and cannot change"))
                    continue
                }
                if strict, let kind, let kinds = kinds(of: field), !kinds.contains(kind) {
                    problems.append(.init(path: at, message: "is not an Accessory Setting of a \(kind) (only of \(kinds.joined(separator: ", ")))"))
                    continue
                }
                // A choice declared for other kinds is not one for this device.
                problems += JSONSchema.problems(value, against: checkable(strict && kind != nil ? forKind(field, kind: kind!) : field), path: at)
            }
        }
        return problems
    }

    // MARK: Which accessory, where

    /// Where an accessory's settings are: its block, its key and its device's.
    struct SettingsTarget {
        var accessoryID: String
        var platform: String
        /// The block's name.
        var instance: String
        /// Its Core Accessory Settings' key in `_accessories`.
        var key: String
        /// The Device Id: Excluded, Parts and the Plugin Accessory Settings.
        var deviceKey: String
        /// The accessory, when it is on the bridge now.
        var located: Located?

        var isMirrored: Bool { located?.accessory.mirroredFrom != nil }
        var displayName: String { located?.accessory.name ?? accessoryID }
    }

    /// The accessory `accessoryID`: one on the bridge by its plugin instance; one that is not (an Excluded device, a
    /// paused one's) by its platform, `<platform>:<deviceID>`, in the one block of that platform, the one whose settings
    /// have it, or `instance`.
    func settingsTarget(_ accessoryID: String, instance: String? = nil, platforms: [JSONValue]) throws -> SettingsTarget {
        var platform: String
        var name: String?
        let found = find(id: accessoryID)
        if let found {
            guard let owner = found.platform else { throw CatalogError("\(found.accessory.name) belongs to no plugin block: it has no Accessory Settings") }
            platform = owner.platform
            name = owner.name
        } else {
            guard let colon = accessoryID.firstIndex(of: ":"), colon != accessoryID.startIndex else {
                throw CatalogError("No accessory with id \(accessoryID)", notFound: true)
            }
            platform = String(accessoryID[..<colon])
            let key = AccessoryNaming.deviceID(of: accessoryID, platform: platform)
            var blocks = platforms.filter { $0["platform"]?.stringValue == platform }
            if let instance { blocks = blocks.filter { ($0["name"]?.stringValue ?? platform) == instance } }
            if blocks.count > 1 {
                let having = blocks.filter { $0["_accessories"]?[key] != nil }
                if having.count == 1 { blocks = having }
            }
            guard !blocks.isEmpty else { throw CatalogError("No accessory with id \(accessoryID)", notFound: true) }
            guard blocks.count == 1 else { throw CatalogError("\(blocks.count) blocks have platform \(platform): give the plugin instance's name") }
            name = blocks[0]["name"]?.stringValue ?? platform
        }
        if let instance, let name, instance != name { throw CatalogError("\(accessoryID) belongs to \(name), not \(instance)") }
        let key = AccessoryNaming.deviceID(of: accessoryID, platform: platform)
        let deviceKey = host.registry.entry(for: platform)?.deviceIDOfAccessory?(key) ?? key
        return SettingsTarget(accessoryID: accessoryID, platform: platform, instance: name ?? platform, key: key, deviceKey: deviceKey, located: found)
    }

    /// The Device Kind of the target's device: what its running instance says, else what its last discovery gave.
    func deviceKind(of target: SettingsTarget) async -> String? {
        if let kind = await host.deviceKind(platform: target.platform, name: target.instance, deviceID: target.deviceKey) { return kind }
        return setupSessions.device(target.deviceKey, of: "\(target.platform)/\(target.instance)")?.kind
    }

    /// The index of the target's block.
    static func blockIndex(of target: SettingsTarget, in platforms: [JSONValue]) -> Int? {
        platforms.firstIndex { $0["platform"]?.stringValue == target.platform && ($0["name"]?.stringValue ?? target.platform) == target.instance }
    }

    /// The accessory's settings as they stand in `block`: its Core Accessory Settings from its key, Excluded, Parts and
    /// its Plugin Accessory Settings from its device's, the legacy values (the layout's room, Hidden and display name, the
    /// block's `_hiddenFromHomeKit`) where the block has none.
    func storedSettings(_ target: SettingsTarget, block: JSONValue) -> [String: JSONValue] {
        let entries = block["_accessories"]?.objectValue ?? [:]
        let own = entries[target.key]?.objectValue ?? [:]
        let device = entries[target.deviceKey]?.objectValue ?? [:]
        var settings = device.filter { !AccessorySettings.liveKeys.contains($0.key) }
        for key in AccessorySettings.liveKeys { settings[key] = own[key] }
        let legacy = home.layout.value.accessories[target.accessoryID]
        if settings["room"] == nil, let room = legacy?.room { settings["room"] = .string(room) }
        if settings["hidden"] == nil, legacy?.hidden == true { settings["hidden"] = true }
        if settings["name"] == nil, let name = legacy?.name { settings["name"] = .string(name) }
        if settings["notInHome"] == nil, (block["_hiddenFromHomeKit"]?.arrayValue ?? []).contains(.string(target.accessoryID)) { settings["notInHome"] = true }
        return settings
    }

    // MARK: Reading

    /// `get_settings` for an accessory: where its settings are, its Device Kind, the current values (`settings`) and what
    /// each field is (`fields`: the Core Accessory Settings and the plugin's own for this kind, each with its schema, and
    /// `default` `{setting, value}` when a Plugin Setting gives it a plugin-wide default).
    public func accessorySettingsJSON(accessoryID: String, instance: String? = nil) async throws -> JSONValue {
        let root = try readConfig()
        let platforms = AccessoryAdoption.platformBlocks(of: root)
        let target = try settingsTarget(accessoryID, instance: instance, platforms: platforms)
        guard let index = Self.blockIndex(of: target, in: platforms) else { throw CatalogError("No block \(target.instance) of \(target.platform)", notFound: true) }
        let block = platforms[index]
        let kind = await deviceKind(of: target)
        var fields: [String: JSONValue] = Self.coreAccessoryFields.mapValues { ["core": true, "schema": $0] }
        if target.isMirrored, var name = fields["name"]?.objectValue {
            name["readOnly"] = true
            fields["name"] = .object(name)
        }
        let stored = block["_accessories"]?[target.deviceKey]?.objectValue ?? [:]
        for (key, field) in accessoryFields(for: target.platform) {
            if let kind, let kinds = Self.kinds(of: field), !kinds.contains(kind) { continue }
            if kind == nil, Self.kinds(of: field) != nil, !(stored[key].map { !$0.isNull } ?? false) { continue }
            // Its choices for this device's kind only (`x-kinds` on a choice), or those the plugin gives for this device.
            var schema = kind.map { Self.forKind(field, kind: $0) } ?? field
            if let choices = await host.accessorySettingChoices(platform: target.platform, name: target.instance, key: key, deviceID: target.deviceKey) {
                schema = Self.withChoices(schema, choices)
            }
            var entry: [String: JSONValue] = ["core": false, "schema": schema]
            if let setting = field["x-default"]?.stringValue {
                entry["default"] = ["setting": .string(setting), "value": block[setting] ?? .null]
            }
            fields[key] = .object(entry)
        }
        var answer: [String: JSONValue] = [
            "accessory": .string(target.accessoryID), "platform": .string(target.platform), "instance": .string(target.instance),
            "key": .string(target.key), "deviceID": .string(target.deviceKey), "kind": kind.map(JSONValue.string) ?? .null,
            "onBridge": .bool(target.located != nil), "settings": .object(storedSettings(target, block: block)), "fields": .object(fields),
        ]
        if let located = target.located { answer["name"] = .string(located.accessory.name) }
        // A plugin that makes its devices rather than finds them (a Helper): forgetting one deletes it for good.
        if let added = host.registry.entry(for: target.platform)?.newDevices, added.isMade, let label = added.label { answer["addLabel"] = .string(label) }
        if let source = target.located?.accessory.mirroredFrom { answer["mirroredFrom"] = .string(source) }
        // Separate Functions: offered for an accessory doing several things; a separated Function names its accessory.
        if let located = target.located {
            let own = located.device
            if located.isSeparatedFunction {
                answer["functionOf"] = ["id": .string(own.id), "name": .string(own.name)]
            } else if let groups = Separation.groups(of: own) {
                answer["functions"] = .array(groups.map { group in .string(Separation.name(of: group[0], in: own)) })
            }
        }
        if answer["functions"] == nil, (answer["settings"]?["separateFunctions"]).map({ $0.isNull }) ?? true {
            fields.removeValue(forKey: "separateFunctions")
            answer["fields"] = .object(fields)
        }
        // Controls only for a Remote (one that has some saved keeps the field, to clear them); the Remotes page edits them.
        if target.located?.accessory.isRemote != true, (answer["settings"]?["controls"]).map({ $0.isNull }) ?? true {
            fields.removeValue(forKey: "controls")
            answer["fields"] = .object(fields)
        }
        // Natural Light is the light's Power On, which set_power_on and the light's sheet set with the device's own.
        if fields.removeValue(forKey: "naturalLight") != nil { answer["fields"] = .object(fields) }
        // Its Meters, for `energyRoles`: each one's key, its own name on a device with several, and its plugin's suggestion.
        // The electricity Meters: gas and water have no Energy Role.
        let meters = (metrics?.meters.meters(of: target.accessoryID) ?? []).filter { metrics?.meters.kind(of: $0) == .electricity }
        // Energy Roles only for an accessory with Meters (one that has a role saved keeps the field, to clear it).
        if meters.isEmpty, (answer["settings"]?["energyRoles"]).map({ $0.isNull }) ?? true { fields.removeValue(forKey: "energyRoles"); answer["fields"] = .object(fields) }
        if !meters.isEmpty {
            answer["meters"] = .array(meters.map { id in
                var meter: [String: JSONValue] = ["key": .string(id.meter), "suggestedRole": metrics?.suggestedRole(of: id).map { .string($0.rawValue) } ?? .null]
                if meters.count > 1, let located = target.located { meter["label"] = .string(Self.meterLabel(id, of: located.accessory)) }
                return .object(meter)
            })
        }
        return .object(answer)
    }

    /// `get_settings` for a plugin instance: its Plugin Settings (the block without `platform` and the runtime's `_`
    /// keys; secrets as they are, for the caller to redact) and its schema's `schema` and `accessorySchema`.
    public func pluginSettingsJSON(platform: String, instance: String? = nil) throws -> JSONValue {
        let platforms = try AccessoryAdoption.platformBlocks(of: readConfig())
        let block = try Self.uniqueBlock(platform: platform, instance: instance, in: platforms).block
        let settings = (block.objectValue ?? [:]).filter { $0.key != "platform" && !$0.key.hasPrefix("_") }
        let file = schemaFile(for: platform)
        return [
            "platform": .string(platform), "instance": .string(block["name"]?.stringValue ?? platform), "settings": .object(settings),
            "schema": file?["schema"] ?? .null, "accessorySchema": file?["accessorySchema"] ?? .null,
        ]
    }

    static func uniqueBlock(platform: String, instance: String?, in platforms: [JSONValue]) throws -> (index: Int, block: JSONValue) {
        let matching = platforms.indices.filter { platforms[$0]["platform"]?.stringValue == platform && (instance == nil || (platforms[$0]["name"]?.stringValue ?? platform) == instance) }
        guard matching.count <= 1 else { throw CatalogError("\(matching.count) blocks have platform \(platform): give the plugin instance's name") }
        guard let index = matching.first else { throw CatalogError("No block \(instance ?? platform) of \(platform)", notFound: true) }
        return (index, platforms[index])
    }

    // MARK: Writing

    /// `patch` merged into `base`, as `update_settings` merges: objects key by key, a null clearing a key, anything else
    /// replacing what was there. nil when nothing is left.
    static func merged(_ base: JSONValue?, _ patch: JSONValue) -> JSONValue? {
        if patch.isNull { return nil }
        guard let changes = patch.objectValue, let current = base?.objectValue else { return patch }
        var result = current
        for (key, value) in changes {
            if let next = merged(result[key], value) { result[key] = next } else { result.removeValue(forKey: key) }
        }
        return .object(result)
    }

    /// The block as a settings write writes it: in its canonical shape, by its running instance
    /// (`HomeswiftPlugin.canonicalSettings`), and its `_hiddenFromHomeKit` moved into `_accessories`. What the plugin asked
    /// to do once it is written joins `effects`, which the writer runs just before writing (never on a dry run).
    func canonicalBlock(_ block: JSONValue, effects: SettingsWrite.Effects) async -> [String: JSONValue] {
        guard let platform = block["platform"]?.stringValue else { return block.objectValue ?? [:] }
        let (canonical, whenWritten) = await host.canonicalSettings(platform: platform, name: block["name"]?.stringValue ?? platform, block: block)
        // The plugin keeps its block: same platform and name.
        let kept = canonical["platform"] == block["platform"] && canonical["name"] == block["name"] && canonical.objectValue != nil
        if kept { effects.append(contentsOf: whenWritten) }
        var object = (kept ? canonical : block).objectValue ?? [:]
        Self.migrateHiddenFromHomeKit(&object, platform: platform)
        return object
    }

    /// What a settings write does to one block, as its plugin reads it (`HomeswiftConfiguration.pluginJSON`: the live
    /// Accessory Settings left out). A write that changes what some plugin reads keeps a backup of config.json, which is
    /// what a person restores after a change of Plugin Settings, an Exclude, Parts or the first canonical shape of a
    /// block in Homebridge's shape; one that changes only live settings (a Name, a room, Hidden, Not in Home: a Home app
    /// rename, a move Apple Home made) keeps none, so those never push the restorable ones out of the last 20. A block whose
    /// plugin would read only its canonical shape anew keeps its plugin running (`PluginHost.CanonicalMove`).
    struct BlockWrite {
        let platform: String
        let name: String
        /// What its plugin reads changes.
        let changesPlugin: Bool
        /// Only because the block was put in its canonical shape: what the write itself changes is live settings.
        let canonicalOnly: Bool

        init(original: JSONValue, canonical: JSONValue, written: JSONValue) {
            platform = written["platform"]?.stringValue ?? ""
            name = written["name"]?.stringValue ?? platform
            let before = HomeswiftConfiguration.pluginJSON(of: original), shaped = HomeswiftConfiguration.pluginJSON(of: canonical)
            let after = HomeswiftConfiguration.pluginJSON(of: written)
            changesPlugin = before == nil || after == nil || before != after
            canonicalOnly = changesPlugin && after != nil && shaped == after
        }
    }

    /// `applyConfig`'s `backup` and `canonicalMoves` for a write of `blocks`.
    static func backupAndMoves(_ blocks: [BlockWrite]) -> (backup: Bool, moves: [(platform: String, name: String)]) {
        (blocks.contains(where: \.changesPlugin), blocks.filter(\.canonicalOnly).map { ($0.platform, $0.name) })
    }

    /// What a settings write answers of `applyConfig`'s answer: what reloaded or restarts, the note and the backup.
    static let appliedKeys: Set<String> = ["dryRun", "reloaded", "started", "stopped", "restarting", "restartNeeded", "note", "backup"]

    /// `applied`'s `appliedKeys` copied into `answer`.
    static func copyApplied(_ applied: JSONValue, into answer: inout [String: JSONValue]) {
        for (key, value) in applied.objectValue ?? [:] where appliedKeys.contains(key) { answer[key] = value }
    }

    /// The flags of the Core Accessory Settings, whose default (false) the canonical shape leaves out.
    static let flagKeys: Set<String> = ["hidden", "notInHome", "excluded", "separateFunctions"]

    /// Runs a settings writer again when config.json changed between its read and its write (`ConfigChanged`, from
    /// `writeConfig(expecting:)`): a concurrent save (a Home app rename, a hub's move, another page) is read again and
    /// kept, rather than written over.
    func retryingWhenConfigChanges<T>(_ write: () async throws -> T) async throws -> T {
        var attempts = 1
        while true {
            do {
                return try await write()
            } catch is ConfigChanged where attempts < 5 {
                attempts += 1
            }
        }
    }

    /// Moves a block's `_hiddenFromHomeKit` (accessory ids) into its `_accessories` as Not in Home; ids of another form
    /// stay in the list.
    static func migrateHiddenFromHomeKit(_ block: inout [String: JSONValue], platform: String) {
        guard let ids = block["_hiddenFromHomeKit"]?.arrayValue else { return }
        var entries = block["_accessories"]?.objectValue ?? [:]
        var left: [JSONValue] = []
        for value in ids {
            guard let id = value.stringValue, id.hasPrefix("\(platform):"), id.count > platform.count + 1 else { left.append(value); continue }
            let key = AccessoryNaming.deviceID(of: id, platform: platform)
            var entry = entries[key]?.objectValue ?? [:]
            entry["notInHome"] = true
            entries[key] = .object(entry)
        }
        if entries.isEmpty { block.removeValue(forKey: "_accessories") } else { block["_accessories"] = .object(entries) }
        if left.isEmpty { block.removeValue(forKey: "_hiddenFromHomeKit") } else { block["_hiddenFromHomeKit"] = .array(left) }
    }

    /// Writes Accessory Settings: each change's `settings` (Core and Plugin Accessory Settings) merged into its
    /// accessory's (`merged`: a null clears a key), checked first (`settingsProblems`, strict), all in one write of
    /// config.json. Each block written is first put in its plugin's canonical shape and has its `_hiddenFromHomeKit` moved
    /// into `_accessories`; each accessory's legacy room and Hidden move from the layout into its settings, and its legacy
    /// display name goes when its Name is set. A new room is added to the layout's rooms. Name, room, Hidden and Not in
    /// Home apply live; Excluded, Parts and the plugin's own settings reload the plugin. An accessory moved to a Room, or
    /// to none, moves in Apple Home too, through the Home Link (`fromHome` for a move Apple Home made), and a new
    /// Room is made there: at once while the link is up, as a Pending Change while it is down, refused while it may not
    /// edit. A mirrored accessory's Name is read-only. A write that changes only live settings keeps no backup of config.json (`BlockWrite`), and
    /// the block's canonical shape alone reloads nothing. Answers each accessory's settings and the keys that changed,
    /// and what the write reloaded.
    @discardableResult
    public func updateAccessorySettings(
        _ changes: [(accessoryID: String, settings: [String: JSONValue])], instance: String? = nil, dryRun: Bool = false, fromHome: Bool = false,
        by writer: ConfigWriter = .person, who: String = "web UI"
    ) async throws -> JSONValue {
        guard !changes.isEmpty else { throw CatalogError("No accessory to change") }
        // A Remote's Controls drive lights, shutters and Power Switches only, never a security control.
        for change in changes {
            if let problem = remoteTargetsProblem(in: RemoteControl.list(from: change.settings["controls"]) ?? []) { throw CatalogError(problem) }
        }
        if !fromHome, !dryRun, changes.contains(where: { $0.settings["room"] != nil && isInHome($0.accessoryID) != false }),
           let refusal = await homeLinkRefusal() {
            throw CatalogError(refusal)
        }
        return try await retryingWhenConfigChanges {
            try await writeAccessorySettings(changes, instance: instance, dryRun: dryRun, fromHome: fromHome, by: writer, who: who)
        }
    }

    private func writeAccessorySettings(
        _ changes: [(accessoryID: String, settings: [String: JSONValue])], instance: String?, dryRun: Bool, fromHome: Bool, by writer: ConfigWriter, who: String
    ) async throws -> JSONValue {
        let current = try readConfig()
        var root = current.objectValue ?? [:]
        var platforms = AccessoryAdoption.platformBlocks(of: current)
        let layout = home.layout.value
        var newRooms: [String] = []
        var planned: [(target: SettingsTarget, settings: [String: JSONValue])] = []
        var problems: [ConfigSchemaError.Problem] = []
        // Each platform's declarations, read once for the whole write.
        var fieldsByPlatform: [String: [String: JSONValue]] = [:]
        for (accessoryID, settings) in changes {
            let target = try settingsTarget(accessoryID, instance: instance, platforms: platforms)
            guard let index = Self.blockIndex(of: target, in: platforms) else { throw CatalogError("No block \(target.instance) of \(target.platform)", notFound: true) }
            var clean = settings
            for key in settings.keys where key.hasPrefix("_") { throw CatalogError("\(key) is the runtime's, not an Accessory Setting") }
            if let name = settings["name"], !name.isNull {
                guard !target.isMirrored else {
                    throw CatalogError("\(target.displayName) comes from \(target.located?.accessory.mirroredFrom ?? "another controller"): its Name is read-only, rename it there")
                }
                if let text = name.stringValue { clean["name"] = AccessoryNaming.cleaned(text).map(JSONValue.string) ?? .null }
            }
            if settings["separateFunctions"]?.boolValue == true {
                guard !target.isMirrored else {
                    throw CatalogError("\(target.displayName) comes from \(target.located?.accessory.mirroredFrom ?? "another controller"): it is published there, not by the bridge")
                }
                guard let own = target.located?.device, Separation.groups(of: own) != nil else {
                    throw CatalogError("\(target.displayName) has nothing to separate: it does one thing, or what it does stays together (a camera, a doorbell, a television)")
                }
            }
            if let located = target.located, located.isSeparatedFunction,
               let other = settings.keys.first(where: { !AccessorySettings.liveKeys.contains($0) || $0 == "separateFunctions" }) {
                throw CatalogError("\(target.displayName) is a Function of \(located.device.name): set \(other) on \(located.device.name)")
            }
            if target.isMirrored, settings["notInHome"]?.boolValue == true {
                throw CatalogError("\(target.displayName) comes from \(target.located?.accessory.mirroredFrom ?? "another controller"): HomeKit has it there")
            }
            if let room = settings["room"], let text = room.stringValue {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count <= AccessoryLayout.maxName else { throw CatalogError("A room's name must be 1 to \(AccessoryLayout.maxName) characters") }
                if trimmed.isEmpty {
                    clean["room"] = ""
                } else if let existing = layout.room(named: trimmed) ?? newRooms.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    clean["room"] = .string(existing)
                } else {
                    clean["room"] = .string(trimmed)
                    newRooms.append(trimmed)
                }
            }
            let checked = clean.filter { !$0.value.isNull }
            let fields = fieldsByPlatform[target.platform] ?? accessoryFields(for: target.platform)
            fieldsByPlatform[target.platform] = fields
            // The Device Kind only decides the plugin's own fields (`x-kinds`): asked of the plugin only for them.
            let kind = checked.keys.contains { !AccessorySettings.coreKeys.contains($0) } ? await deviceKind(of: target) : nil
            for found in Self.settingsProblems(checked, fields: fields, kind: kind, strict: true) {
                problems.append(.init(platform: target.platform, path: [.key("platforms"), .index(index), .key("_accessories"), .key(target.key)] + found.path, message: found.message))
            }
            planned.append((target, clean))
        }
        if !problems.isEmpty { throw ConfigSchemaError(problems: problems) }
        guard layout.rooms.count + newRooms.count <= AccessoryLayout.maxRooms else { throw CatalogError("At most \(AccessoryLayout.maxRooms) rooms") }

        // The blocks, each put in its canonical shape once, then every change merged in.
        var canonical: Set<Int> = []
        var shaped: [Int: JSONValue] = [:]
        var before: [String: [String: JSONValue]] = [:]
        let effects = SettingsWrite.Effects()
        for (target, settings) in planned {
            guard let index = Self.blockIndex(of: target, in: platforms) else { continue }
            if canonical.insert(index).inserted {
                platforms[index] = .object(await canonicalBlock(platforms[index], effects: effects))
                shaped[index] = platforms[index]
            }
            before[target.accessoryID] = before[target.accessoryID] ?? storedSettings(target, block: platforms[index])
            var block = platforms[index].objectValue ?? [:]
            var entries = block["_accessories"]?.objectValue ?? [:]
            var own = entries[target.key]?.objectValue ?? [:]
            // The layout's legacy room and Hidden move here; its display name goes once a Name is set.
            let legacy = layout.accessories[target.accessoryID]
            if own["room"] == nil, settings["room"] == nil, let room = legacy?.room { own["room"] = .string(room) }
            if own["hidden"] == nil, settings["hidden"] == nil, legacy?.hidden == true { own["hidden"] = true }
            entries[target.key] = .object(own)
            for (key, value) in settings {
                let entryKey = AccessorySettings.liveKeys.contains(key) ? target.key : target.deviceKey
                var entry = entries[entryKey]?.objectValue ?? [:]
                let next = Self.merged(entry[key], value)
                // false is the default of the flags: the canonical shape leaves it out.
                if let next, next != .bool(false) || !Self.flagKeys.contains(key) {
                    entry[key] = next
                } else {
                    entry.removeValue(forKey: key)
                }
                if key == "parts" || key == "energyRoles", entry[key]?.objectValue?.isEmpty == true { entry.removeValue(forKey: key) }
                entries[entryKey] = .object(entry)
            }
            entries = entries.filter { $0.value.objectValue?.isEmpty != true }
            if entries.isEmpty { block.removeValue(forKey: "_accessories") } else { block["_accessories"] = .object(entries) }
            platforms[index] = .object(block)
        }
        root["platforms"] = .array(AccessoryAdoption.keepingEdited(platforms, of: current))
        let next = JSONValue.object(root)

        var results: [JSONValue] = []
        var moves: [HomeLinkFile.PendingChange] = []
        var seen: Set<String> = []
        for (target, _) in planned where seen.insert(target.accessoryID).inserted {
            guard let index = Self.blockIndex(of: target, in: platforms) else { continue }
            let after = storedSettings(target, block: platforms[index])
            let old = before[target.accessoryID] ?? [:]
            let changedKeys = Set(old.keys).union(after.keys).filter { old[$0] != after[$0] }.sorted()
            results.append(["accessory": .string(target.accessoryID), "settings": .object(after), "changed": .array(changedKeys.map(JSONValue.string))])
            // Moved to a Room it was not in, or to none: Apple Home follows.
            let room = after["room"]?.stringValue ?? ""
            if !fromHome, changedKeys.contains("room"), !Self.sameRoomName(target.located?.room ?? "", room) {
                moves.append(.moveAccessory(accessory: target.accessoryID, room: room))
            }
        }
        var answer: [String: JSONValue] = ["accessories": .array(results)]
        if dryRun {
            // Checked as the write would be, nothing written.
            let checked = try await applyConfig(next, dryRun: true, current: current, checkSchemas: true, by: writer)
            answer["dryRun"] = true
            answer["changes"] = checked["changes"] ?? []
            return .object(answer)
        }
        if next != current {
            let originals = current["platforms"]?.arrayValue ?? []
            let blocks = shaped.keys.sorted().compactMap { index in
                originals.indices.contains(index) ? BlockWrite(original: originals[index], canonical: shaped[index]!, written: platforms[index]) : nil
            }
            let (backup, moves) = Self.backupAndMoves(blocks)
            let applied = try await applyConfig(
                next, dryRun: false, current: current, checkSchemas: true, expecting: current, by: writer, backup: backup, canonicalMoves: moves, beforeWrite: effects.run)
            Self.copyApplied(applied, into: &answer)
        } else {
            answer["note"] = "Nothing changed."
            answer["reloaded"] = []
        }
        let ids = Set(planned.map(\.target.accessoryID))
        let touchedNames = Set(planned.filter { $0.settings["name"] != nil }.map(\.target.accessoryID))
        let legacyLeft = ids.contains { id in
            guard let entry = layout.accessories[id] else { return false }
            return entry.room != nil || entry.hidden != nil || (entry.name != nil && touchedNames.contains(id))
        }
        if !newRooms.isEmpty || legacyLeft {
            try home.layout.update { layout in
                for room in newRooms where layout.room(named: room) == nil { layout.rooms.append(room) }
                for id in ids {
                    guard var entry = layout.accessories[id] else { continue }
                    entry.room = nil
                    entry.hidden = nil
                    if touchedNames.contains(id) { entry.name = nil }
                    layout.accessories[id] = entry.isEmpty ? nil : entry
                }
            }
        }
        // The pages that show rooms and the wall follow (the web UI's event stream).
        let liveChanged = results.contains { result in
            (result["changed"]?.arrayValue ?? []).contains { $0.stringValue.map(AccessorySettings.liveKeys.contains) == true }
        }
        if !newRooms.isEmpty || legacyLeft || (liveChanged && next != current) { home.layoutChanged() }
        if !fromHome { await recordForHome(newRooms.map { .createRoom(name: $0) } + moves, into: &answer) }
        return .object(answer)
    }


    /// Writes Plugin Settings: `settings` merged into the block (`merged`: a null clears a key), the runtime's `_` keys and
    /// `platform` out of reach, each key one the plugin's schema declares (a null may clear one it does not), the block put
    /// in its canonical shape first and the result checked against the schema. A secret's placeholder or handle keeps the
    /// stored secret. The plugin reloads.
    public func updatePluginSettings(
        platform: String, instance: String? = nil, settings: [String: JSONValue], dryRun: Bool = false, by writer: ConfigWriter = .person
    ) async throws -> JSONValue {
        let refused = settings.keys.filter { $0 == "platform" || $0.hasPrefix("_") }.sorted()
        guard refused.isEmpty else {
            throw CatalogError("Not a Plugin Setting: \(refused.joined(separator: ", ")) (Accessory Settings go through the accessory, the runtime's keys through their own tools)")
        }
        if let declared = (schemaFile(for: platform)?["schema"]).flatMap({ $0["properties"] ?? $0 })?.objectValue {
            let unknown = settings.filter { declared[$0.key] == nil && !$0.value.isNull }.keys.sorted()
            guard unknown.isEmpty else { throw CatalogError("Not a setting \(platform)'s schema declares: \(unknown.joined(separator: ", "))") }
        }
        return try await retryingWhenConfigChanges {
            try await writePluginSettings(platform: platform, instance: instance, settings: settings, dryRun: dryRun, by: writer)
        }
    }

    private func writePluginSettings(platform: String, instance: String?, settings: [String: JSONValue], dryRun: Bool, by writer: ConfigWriter) async throws -> JSONValue {
        let current = try readConfig()
        var root = current.objectValue ?? [:]
        var platforms = AccessoryAdoption.platformBlocks(of: current)
        let (index, found) = try Self.uniqueBlock(platform: platform, instance: instance, in: platforms)
        let effects = SettingsWrite.Effects()
        var block = await canonicalBlock(found, effects: effects)
        let shaped = JSONValue.object(block)
        for (key, value) in settings {
            if let next = Self.merged(block[key], value) { block[key] = next } else { block.removeValue(forKey: key) }
        }
        platforms[index] = .object(block)
        root["platforms"] = .array(AccessoryAdoption.keepingEdited(platforms, of: current))
        let next = JSONValue.object(root)
        let name = block["name"]?.stringValue ?? platform
        let before = (found.objectValue ?? [:]).filter { $0.key != "platform" && !$0.key.hasPrefix("_") }
        let after = block.filter { $0.key != "platform" && !$0.key.hasPrefix("_") }
        var answer: [String: JSONValue] = [
            "platform": .string(platform), "instance": .string(name),
            "changed": .array(Self.changedKeys(from: .object(before), to: .object(after)).filter { $0 != "(root)" }.map(JSONValue.string)),
        ]
        guard next != current else {
            answer["note"] = "Nothing changed."
            answer["reloaded"] = []
            return .object(answer)
        }
        let (backup, moves) = Self.backupAndMoves([BlockWrite(original: found, canonical: shaped, written: .object(block))])
        let applied = try await applyConfig(
            next, dryRun: dryRun, current: current, checkSchemas: true, expecting: current, by: writer, backup: backup, canonicalMoves: moves, beforeWrite: effects.run)
        Self.copyApplied(applied, into: &answer)
        return .object(answer)
    }

    // MARK: Confirmations

    /// Whether an accessory's settings change asks the user first: one that takes it out of Apple Home or out of the bridge
    /// (Excluded, Not in Home), or changes its Parts, which drops services with their automations. A Name, a room, Hidden,
    /// an Include and the plugin's own Accessory Settings apply without asking: they are undone as easily as they are made.
    static func accessoryChangeAsks(_ settings: JSONValue) -> Bool {
        guard let settings = settings.objectValue else { return false }
        return settings["excluded"] == .bool(true) || settings["notInHome"] == .bool(true) || settings["parts"] != nil
    }

    /// `update_settings`' confirmation (`MCPTool.confirmsWhen`): an accessory's change by `accessoryChangeAsks`, every
    /// change of Plugin Settings (a host, a device list, a secret: what `patch_config` writes, and the plugin reloads).
    @Sendable static func settingsChangeAsks(_ arguments: JSONValue) -> Bool {
        if let many = arguments["accessories"]?.objectValue { return many.values.contains(where: accessoryChangeAsks) }
        // The Location: no device changes and nothing restarts.
        if arguments["bridge"]?.boolValue == true { return false }
        guard let settings = arguments["settings"] else { return false }
        if arguments["accessory"]?.stringValue != nil { return accessoryChangeAsks(settings) }
        return settings.objectValue?.isEmpty == false
    }

    // MARK: Forget

    /// Whether `key` of a block's `_accessories` belongs to the device `deviceID`: its own entry, or one of its other
    /// accessories' (`<deviceID>:<more>`, `<deviceID>.<more>`).
    static func isKey(_ key: String, of deviceID: String) -> Bool {
        key == deviceID || key.hasPrefix("\(deviceID):") || key.hasPrefix("\(deviceID).")
    }

    /// Forget (GLOSSARY.md): drops a device's Authorization (its credentials in the vault) and its Accessory Settings
    /// (every `_accessories` entry of the device, its other accessories' included, and what the layout kept of their room,
    /// Hidden and name), so it is only a Discovered Device again if its plugin still finds it. The block is put in its
    /// canonical shape first, as the other writers do; the plugin reloads without it. The Arrangement (its place on the
    /// wall, Quick Controls) stays. Answers the keys dropped, whether credentials were, and what the write reloaded.
    public func forgetDevice(accessoryID: String, instance: String? = nil, dryRun: Bool = false, by writer: ConfigWriter = .person) async throws -> JSONValue {
        // The credentials go before the write, once: a write tried again (`ConfigChanged`) still says they went.
        var credentialsGone = false
        return try await retryingWhenConfigChanges {
            try await forget(accessoryID: accessoryID, instance: instance, dryRun: dryRun, by: writer, credentialsGone: &credentialsGone)
        }
    }

    private func forget(accessoryID: String, instance: String?, dryRun: Bool, by writer: ConfigWriter, credentialsGone: inout Bool) async throws -> JSONValue {
        let current = try readConfig()
        var root = current.objectValue ?? [:]
        var platforms = AccessoryAdoption.platformBlocks(of: current)
        let target = try settingsTarget(accessoryID, instance: instance, platforms: platforms)
        guard let index = Self.blockIndex(of: target, in: platforms) else { throw CatalogError("No block \(target.instance) of \(target.platform)", notFound: true) }
        let effects = SettingsWrite.Effects()
        var block = await canonicalBlock(platforms[index], effects: effects)
        var entries = block["_accessories"]?.objectValue ?? [:]
        let dropped = entries.keys.filter { Self.isKey($0, of: target.deviceKey) || $0 == target.key }.sorted()
        for key in dropped { entries.removeValue(forKey: key) }
        if entries.isEmpty { block.removeValue(forKey: "_accessories") } else { block["_accessories"] = .object(entries) }
        platforms[index] = .object(block)
        root["platforms"] = .array(AccessoryAdoption.keepingEdited(platforms, of: current))
        let next = JSONValue.object(root)
        // Its accessories' ids, for what the layout kept of their settings.
        let prefix = "\(target.platform):"
        let legacy = home.layout.value.accessories.filter { id, entry in
            id.hasPrefix(prefix) && Self.isKey(String(id.dropFirst(prefix.count)), of: target.deviceKey) && (entry.room != nil || entry.hidden != nil || entry.name != nil)
        }.keys
        let context = host.context(platform: target.platform, name: target.instance)
        let hadCredentials = credentialsGone || context?.haveCredentials([target.deviceKey]).isEmpty == false
        let hadHistory = metrics?.meters.hasHistory(accessory: target.accessoryID) ?? false
        var answer: [String: JSONValue] = [
            "accessory": .string(target.accessoryID), "platform": .string(target.platform), "instance": .string(target.instance),
            "deviceID": .string(target.deviceKey), "settingsDropped": .array(dropped.map(JSONValue.string)), "credentialsDropped": .bool(hadCredentials),
            "historyDropped": .bool(hadHistory),
        ]
        guard dropped.isEmpty == false || hadCredentials || hadHistory || !legacy.isEmpty else {
            answer["note"] = .string("Nothing to forget: \(target.displayName) has no Authorization, Accessory Settings or energy history.")
            answer["reloaded"] = []
            if dryRun { answer["dryRun"] = true }
            return .object(answer)
        }
        // Checked as it will be written before anything goes: the credentials cannot come back.
        let checked = try await applyConfig(next, dryRun: true, current: current, checkSchemas: true, by: writer)
        if dryRun {
            answer["dryRun"] = true
            answer["changes"] = checked["changes"] ?? []
            return .object(answer)
        }
        // The credentials first, so the plugin the write reloads starts without them.
        if hadCredentials, !credentialsGone {
            context?.removeCredentials(for: target.deviceKey)
            credentialsGone = true
        }
        // Always a backup: what Forget drops comes back only by restoring one (its credentials do not).
        if next != current {
            let applied = try await applyConfig(next, dryRun: false, current: current, checkSchemas: true, expecting: current, by: writer, beforeWrite: effects.run)
            Self.copyApplied(applied, into: &answer)
        }
        // Its Meters' history goes with it (docs/adr/0004-meters-and-consumption-history.md).
        if hadHistory { metrics?.meters.forget(accessory: target.accessoryID) }
        // Its plugin reloads without it, even when what it reads did not change (a device with live settings only).
        let restarted = ((answer["reloaded"]?.arrayValue ?? []) + (answer["started"]?.arrayValue ?? [])).contains(.string(target.instance))
        if !restarted {
            await host.relaunch(platform: target.platform, name: target.instance)
            answer["reloaded"] = .array((answer["reloaded"]?.arrayValue ?? []) + [.string(target.instance)])
        }
        if !legacy.isEmpty {
            try home.layout.update { layout in
                for id in legacy {
                    guard var entry = layout.accessories[id] else { continue }
                    entry.room = nil
                    entry.hidden = nil
                    entry.name = nil
                    layout.accessories[id] = entry.isEmpty ? nil : entry
                }
            }
        }
        home.layoutChanged()
        logger.info("Forgot a device", metadata: ["platform": "\(target.platform)", "name": "\(target.instance)", "device": "\(target.deviceKey)"])
        return .object(answer)
    }

    // MARK: Tools

    /// `get_settings`' answer with the MCP tokens of a block's `mcp` redacted (`redactingMCPTokens`): a session handle
    /// for one, passed under another plugin's secret-named key, would write the token where that plugin sends it.
    static func redactingMCPTokens(inSettings answer: JSONValue) -> JSONValue {
        guard var object = answer.objectValue, var settings = object["settings"]?.objectValue, let mcp = settings["mcp"] else { return answer }
        settings["mcp"] = Redaction.redactSecrets(mcp)
        object["settings"] = .object(settings)
        return .object(object)
    }

    /// A settings tool's `plugin`: its platform and instance name.
    @Sendable static func pluginArgument(_ call: ToolCall) -> (platform: String, name: String?)? {
        guard let platform = call.arguments["plugin"]?["platform"]?.stringValue else { return nil }
        return (platform, call.arguments["plugin"]?["name"]?.stringValue)
    }

    var settingsTools: [MCPTool] {
        let catalog = self
        let address: [String: JSONValue] = [
            "accessory": ["type": "string", "description": "An Accessory Id (list_accessories' id, or discover_devices' accessoryID for a device not on the bridge)"],
            "plugin": ["type": "object", "required": ["platform"], "additionalProperties": false, "properties": [
                "platform": ["type": "string", "description": "The plugin's platform, as list_plugins gives it"],
                "name": ["type": "string", "description": "The plugin instance's (block's) name, when the platform has several"],
            ], "description": "A plugin instance: its Plugin Settings; with accessory, the instance the accessory belongs to"],
        ]
        let plugin = Self.pluginArgument
        // get_settings and update_settings also reach the Bridge Settings that change without a restart; forget_device does not.
        let settingsAddress = address.merging(["bridge": ["type": "boolean", "description": "true for the Bridge Settings that change without a restart: location, the Location (where the home is, for sunrise, sunset and the weather); not with accessory or plugin"]]) { $1 }
        return [
            MCPTool(
                name: "get_settings", title: "Read settings",
                description: "The settings of an accessory (accessory: its Accessory Id) or of a plugin instance (plugin), with what each is. "
                    + "For an accessory: settings, its current Accessory Settings (Core: name, room, hidden, notInHome, excluded, parts, energyRoles; and the plugin's own), meters (each Meter's key, label and suggestedRole, for energyRoles), "
                    + "and fields, each with its JSON schema, core true or false, and default {setting, value} when a Plugin Setting gives it a plugin-wide default "
                    + "that the accessory's own value overrules; kind is its Device Kind, which decides the plugin's fields. "
                    + "For a plugin: settings, its Plugin Settings (secrets as __SECRET_…__ handles), its schema and accessorySchema. "
                    + "For the bridge (bridge: true): settings.location, the Location ({latitude, longitude, name} or null), with the next sunrise and sunset there. "
                    + "Change them with update_settings.",
                inputSchema: ["type": "object", "properties": .object(settingsAddress)],
                // config.json's values, as get_config: hidden from a user who is not an administrator (`administratorOnly`).
                scope: .read, idempotent: true
            ) { call in
                let answer: JSONValue
                if call.arguments["bridge"]?.boolValue == true {
                    guard call.optionalString("accessory") == nil, plugin(call) == nil else { return .error("Pass bridge, accessory or plugin, not several") }
                    answer = Self.bridgeLiveSettingsJSON(catalog.locationJSON())
                } else if let id = call.optionalString("accessory") {
                    answer = try await catalog.accessorySettingsJSON(accessoryID: id, instance: plugin(call)?.name)
                } else if let plugin = plugin(call) {
                    answer = try catalog.pluginSettingsJSON(platform: plugin.platform, instance: plugin.name)
                } else {
                    return .error("Pass accessory or plugin")
                }
                // Names and values came from devices and config.json: data, never instructions. MCP tokens (the
                // HomeswiftAiKit block's `mcp`) stay redacted, as get_config has them: a handle could be passed on.
                let shown = call.session.vault.conceal(Self.redactingMCPTokens(inSettings: answer))
                return ToolResult(text: "<untrusted-data source=\"settings\">\n\(shown.text(pretty: true))\n</untrusted-data>", structured: shown)
            },
            MCPTool(
                name: "update_settings", title: "Change settings",
                description: "Changes the settings of an accessory (accessory) or of a plugin instance (plugin): settings is merged into them, objects key by key, "
                    + "and a null clears a key (the default again). Every key must be one get_settings lists. "
                    + "An accessory's name (in Apple Home too), room (a new name adds the room; \"\" for none), hidden (off the web UI's wall) and notInHome (out of Apple Home, "
                    + "which loses its room, scenes and automations) apply at once; excluded, parts and the plugin's own settings reload the plugin, as Plugin Settings do. "
                    + "A mirrored accessory's name is read-only. Once the bridge is linked to Apple Home (get_home_link), an accessory moved to a room, or to none, moves in Apple Home too "
                    + "(appleHomeRefused lists what it refused); separateFunctions makes each thing it does an accessory of its own there, so it can be grouped. "
                    + "accessories, an object of settings by Accessory Id, changes several accessories in one write. Answers each accessory's settings and the keys that changed, "
                    + "and what reloaded. With bridge: true, settings.location sets the Location ({latitude, longitude, name}; null forgets it): scenes' sunrise and sunset "
                    + "and plugins such as Weather use it, with no restart. The bridge's name, port and setup code are update_bridge_settings'. dryRun previews.",
                inputSchema: ["type": "object", "properties": .object(settingsAddress.merging([
                    "settings": ["type": "object", "description": "The settings to change, by key; null clears one"],
                    "accessories": ["type": "object", "maxProperties": 500, "additionalProperties": ["type": "object"], "description": "Settings by Accessory Id, for several accessories at once"],
                ]) { $1 })],
                scope: .admin, supportsDryRun: true, confirmsWhen: Self.settingsChangeAsks
            ) { call in
                let who = "MCP \(call.session.clientInfo?.name ?? "client")"
                if let many = call.arguments["accessories"]?.objectValue {
                    let changes = try many.sorted { $0.key < $1.key }.map { id, value -> (accessoryID: String, settings: [String: JSONValue]) in
                        guard let settings = value.objectValue else { throw JSONRPCError.invalidParams("the settings of \(id) must be an object") }
                        return (id, settings)
                    }
                    return .json(try await catalog.updateAccessorySettings(changes, instance: plugin(call)?.name, dryRun: call.isDryRun, by: .client, who: who))
                }
                guard let settings = call.arguments["settings"]?.objectValue else { throw JSONRPCError.invalidParams("settings must be an object") }
                if call.arguments["bridge"]?.boolValue == true {
                    guard call.optionalString("accessory") == nil, plugin(call) == nil else { return .error("Pass bridge, accessory or plugin, not several") }
                    return .json(try await catalog.updateBridgeLiveSettings(settings, dryRun: call.isDryRun, by: .client))
                }
                if let id = call.optionalString("accessory") {
                    return .json(try await catalog.updateAccessorySettings([(id, settings)], instance: plugin(call)?.name, dryRun: call.isDryRun, by: .client, who: who))
                }
                guard let plugin = plugin(call) else { return .error("Pass accessory or plugin") }
                return .json(try await catalog.updatePluginSettings(platform: plugin.platform, instance: plugin.name, settings: settings, dryRun: call.isDryRun, by: .client))
            },
            MCPTool(
                name: "forget_device", title: "Forget a device",
                description: "Forgets a device (accessory: its Accessory Id; plugin, its instance when the platform has several): drops its Authorization "
                    + "(the credentials Setup kept in the vault) and all its Accessory Settings (Name, room, Hidden, Not in Home, Excluded, Parts and the plugin's own, "
                    + "its other accessories' too). Its plugin reloads without it: it leaves Apple Home with its room, scenes and automations, and is only a "
                    + "Discovered Device again if the plugin still finds it (start_setup sets it up anew). To keep it but leave it out, exclude it with update_settings instead. "
                    + "dryRun previews.",
                inputSchema: ["type": "object", "required": ["accessory"], "properties": .object(address)],
                scope: .admin, destructive: true, supportsDryRun: true
            ) { call in
                .json(try await catalog.forgetDevice(accessoryID: try call.string("accessory"), instance: plugin(call)?.name, dryRun: call.isDryRun, by: .client))
            },
        ]
    }
}
