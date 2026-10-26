import Foundation
import Homeswift
import HomeswiftAI

/// A Homebridge config.json read into Homeswift's shape. What the bridge's plugins declare is kept, a secret
/// is sealed (see `SecretBox`), and the rest is reported as dropped with the reason. Nothing is written here:
/// `check` says what a save would do, `merge` builds the config a save writes.
///
/// Messages are codes with arguments, not sentences, so the web UI words them in its own languages.
/// The blocks the runtime runs itself (the web UI, the Assistant), not plugins. The catalog and the import share it.
public enum RuntimePlatforms {
    public static let all: Set<String> = [AIConfiguration.platform, "HomeswiftUI"]
}

public enum HomebridgeImport {
    public static let maxBytes = 1_048_576

    /// Homebridge platform names Homeswift runs under another name.
    static let renamedPlatforms = ["HomebridgeAiKit": AIConfiguration.platform]
    /// The bridge settings Homeswift reads; anything else in the bridge block is dropped.
    static let bridgeKeys: Set<String> = ["name", "username", "port", "pin", "advertiser", "bind"]
    /// The child bridge settings (`_bridge`) Homeswift reads.
    static let childBridgeKeys: Set<String> = ["name", "username", "port", "pin", "manufacturer", "model", "firmwareRevision"]

    public enum Outcome: String, Codable, Sendable { case imported, encrypted, dropped }

    /// A code and its arguments, for the web UI to word.
    public struct Message: Codable, Sendable, Equatable {
        public var code: String
        public var args: [String: String]

        public init(_ code: String, _ args: [String: String] = [:]) {
            self.code = code
            self.args = args
        }
    }

    /// One setting the review lists. `value` is shown for a plain setting, nil for a sealed one; `count` is the
    /// size of a list or an object; `note` says why a setting was dropped or paused.
    public struct Item: Codable, Sendable, Equatable {
        public var group: String
        public var path: String
        public var outcome: Outcome
        public var value: String?
        public var count: Int?
        public var note: Message?
    }

    public struct Syntax: Codable, Sendable, Equatable {
        public var line: Int
        public var column: Int
        /// `unexpectedEnd`, `other`: the kind of mistake, for the UI's hint.
        public var hint: String
        /// The parser's own words, for the technical detail.
        public var detail: String
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var platforms: Int
        public var dropped: Int
        public var encrypted: Int
    }

    public struct Report: Codable, Sendable, Equatable {
        public var valid: Bool
        public var syntax: Syntax?
        public var problems: [Message]
        public var warnings: [Message]
        public var summary: Summary
        public var items: [Item]
    }

    /// The report, and the settings a save adds to config.json (`bridge` when it applies, `platforms`), or nil
    /// when the file is not valid.
    public struct Result: Sendable {
        public var report: Report
        public var additions: JSONValue?
    }

    /// Reads `data` against the platforms `registry` runs. `existing` is the config the save would add to; `seal`
    /// seals each secret (the check passes none: it only describes). Throws only when sealing fails.
    public static func check(_ data: Data, registry: PluginRegistry, existing: JSONValue? = nil, seal: ((String) throws -> String)? = nil) throws -> Result {
        var converter = Converter(platforms: supportedPlatforms(registry), seal: seal)
        return try converter.run(data, existing: existing)
    }

    /// `existing` with the additions merged in: the platforms appended, the bridge set when the additions have one.
    public static func merge(_ existing: JSONValue, additions: JSONValue) -> JSONValue {
        guard var root = existing.objectValue, let added = additions.objectValue else { return existing }
        let platforms = (root["platforms"]?.arrayValue ?? []) + (added["platforms"]?.arrayValue ?? [])
        root["platforms"] = .array(platforms)
        if let bridge = added["bridge"] { root["bridge"] = bridge }
        return .object(root)
    }

    static func supportedPlatforms(_ registry: PluginRegistry) -> [String: Supported] {
        var supported: [String: Supported] = [:]
        for entry in registry.entries {
            supported[entry.platform] = Supported(schema: entry.configurationSchemaJSON.flatMap { try? JSONValue(string: $0) }.flatMap(schemaRoot))
        }
        supported[AIConfiguration.platform] = Supported(schema: (try? JSONValue(string: AIConfiguration.schemaJSON)).flatMap(schemaRoot))
        return supported
    }

    /// The settings object of a plugin's schema: the root's `properties`, or those under its `schema` wrapper.
    static func schemaRoot(_ root: JSONValue) -> JSONValue? {
        if root["properties"]?.objectValue != nil { return root }
        if let wrapped = root["schema"], wrapped["properties"]?.objectValue != nil { return wrapped }
        return nil
    }

    struct Supported {
        var schema: JSONValue?
    }

    /// The name a Homebridge package and a platform name share: `homebridge-unifi-protect` and `UniFi Protect`.
    static func normalized(_ name: String) -> String {
        var text = name.lowercased()
        if text.hasPrefix("homebridge-") { text.removeFirst("homebridge-".count) }
        return String(text.filter { $0.isLetter || $0.isNumber })
    }

    struct Converter {
        let platforms: [String: Supported]
        let seal: ((String) throws -> String)?
        var report = Report(valid: false, syntax: nil, problems: [], warnings: [], summary: Summary(platforms: 0, dropped: 0, encrypted: 0), items: [])
        var kept: [JSONValue] = []
        /// The normalized Homebridge platform names read, for the disabled-plugins check.
        var seenPlatforms: Set<String> = []

        init(platforms: [String: Supported], seal: ((String) throws -> String)?) {
            self.platforms = platforms
            self.seal = seal
        }

        mutating func run(_ data: Data, existing: JSONValue?) throws -> Result {
            guard data.count <= HomebridgeImport.maxBytes else {
                report.problems.append(Message("tooLarge", ["kilobytes": String(data.count / 1024)]))
                return finish(additions: nil)
            }
            let root: JSONValue
            do {
                root = try JSONValue(data: data)
            } catch JSONValueError.invalid(let reason, let offset) {
                report.syntax = syntax(data, offset: offset, detail: reason)
                return finish(additions: nil)
            } catch {
                report.syntax = Syntax(line: 1, column: 1, hint: "other", detail: "\(error)")
                return finish(additions: nil)
            }
            guard let top = root.objectValue else {
                report.problems.append(Message("notObject"))
                return finish(additions: nil)
            }
            // Revealing opens every string that starts with the prefix, anywhere in the config, so a plain value that
            // carries it could never open and would stop the bridge at startup. Refused, whatever its key.
            if SecretBox.holdsSealed(root) {
                report.problems.append(Message("sealedLookingValue"))
            }

            var additions: [String: JSONValue] = [:]
            if let bridge = top["bridge"] {
                if let object = bridge.objectValue {
                    additions["bridge"] = try convertBridge(object)
                } else {
                    report.problems.append(Message("bridgeNotObject"))
                }
            }
            if let accessories = top["accessories"]?.arrayValue, !accessories.isEmpty {
                report.warnings.append(Message("accessoriesSkipped", ["count": String(accessories.count)]))
            }
            var disabled: [String] = []
            if let list = top["disabledPlugins"] {
                if let names = list.arrayValue {
                    disabled = names.compactMap(\.stringValue)
                } else {
                    report.problems.append(Message("disabledPluginsNotList"))
                }
            }
            if let list = top["platforms"] {
                if let blocks = list.arrayValue {
                    for (index, block) in blocks.enumerated() {
                        try convertPlatform(block, index: index, disabled: disabled)
                    }
                } else {
                    report.problems.append(Message("platformsNotList"))
                }
            }
            for name in disabled where !seenPlatforms.contains(HomebridgeImport.normalized(name)) {
                report.warnings.append(Message("disabledMatchesNothing", ["name": name]))
            }
            additions["platforms"] = .array(kept)
            return finishChecked(additions: additions, existing: existing)
        }

        /// Checks the additions against the existing config: duplicates, the bridge rule, and the whole result
        /// decoded the way the runtime decodes it.
        mutating func finishChecked(additions: [String: JSONValue], existing: JSONValue?) -> Result {
            let allExisting = existing?["platforms"]?.arrayValue ?? []
            // The runtime's own blocks (the web UI, the Assistant) are not plugins: they do not count for the bridge rule.
            let hasPlugins = allExisting.contains { block in
                !RuntimePlatforms.all.contains(block["platform"]?.stringValue ?? "")
            }
            let taken = Set(allExisting.compactMap(Self.identity))
            var seen = taken
            for block in kept {
                guard let identity = Self.identity(block) else { continue }
                if seen.contains(identity) {
                    report.problems.append(Message("duplicatePlatform", ["name": identity.name]))
                }
                seen.insert(identity)
            }
            var additions = additions
            if hasPlugins, additions["bridge"] != nil {
                additions["bridge"] = nil
                report.warnings.append(Message("bridgeKeptExisting"))
            }
            if kept.isEmpty, additions["bridge"] == nil {
                report.problems.append(Message("nothingToImport"))
            }
            // A sealed run (seal set) validates nothing: a sealed PIN would fail the setup-code check. The check run did.
            if report.problems.isEmpty, seal == nil {
                validate(additions, existing: existing)
            }
            return finish(additions: additions)
        }

        /// `text` sealed. A check run (no seal) keeps the text as it is.
        func sealText(_ text: String) throws -> String {
            guard let seal else { return text }
            return try seal(text)
        }

        /// A bridge PIN, sealed and listed as encrypted.
        mutating func sealedPIN(_ text: String, path: String, group: String) throws -> JSONValue {
            report.items.append(Item(group: group, path: path, outcome: .encrypted, value: nil, count: nil, note: nil))
            return .string(try sealText(text))
        }

        mutating func validate(_ additions: [String: JSONValue], existing: JSONValue?) {
            let candidate = HomebridgeImport.merge(existing ?? .object([:]), additions: .object(additions))
            do {
                try HomeswiftConfiguration.decode(candidate.encoded()).validate()
            } catch {
                report.problems.append(Message("invalidConfig", ["detail": "\(error)"]))
            }
        }

        mutating func finish(additions: [String: JSONValue]?) -> Result {
            report.valid = report.problems.isEmpty && report.syntax == nil
            report.summary.platforms = kept.count
            report.summary.dropped = report.items.filter { $0.outcome == .dropped }.count
            report.summary.encrypted = report.items.filter { $0.outcome == .encrypted }.count
            return Result(report: report, additions: report.valid ? additions.map { .object($0) } : nil)
        }

        /// A runtime block exists once, whatever its name, so its name is not part of its identity.
        static func identity(_ block: JSONValue) -> Identity? {
            guard let platform = block["platform"]?.stringValue else { return nil }
            let name = RuntimePlatforms.all.contains(platform) ? platform : block["name"]?.stringValue ?? platform
            return Identity(platform: platform, name: name)
        }

        struct Identity: Hashable {
            var platform: String
            var name: String
        }

        // MARK: Bridge

        mutating func convertBridge(_ object: [String: JSONValue]) throws -> JSONValue {
            var out: [String: JSONValue] = [:]
            for key in object.keys.sorted() {
                let value = object[key] ?? .null
                guard HomebridgeImport.bridgeKeys.contains(key) else {
                    report.items.append(Item(group: "Bridge", path: key, outcome: .dropped, value: nil, count: nil, note: Message("notUsed")))
                    continue
                }
                if key == "pin", let text = value.stringValue {
                    out[key] = try sealedPIN(text, path: key, group: "Bridge")
                    continue
                }
                out[key] = value
                if let text = value.stringValue {
                    report.items.append(Item(group: "Bridge", path: key, outcome: .imported, value: text, count: nil, note: nil))
                } else if let number = value.doubleValue {
                    report.items.append(Item(group: "Bridge", path: key, outcome: .imported, value: String(Int(number)), count: nil, note: nil))
                }
            }
            return .object(out)
        }

        // MARK: Platforms

        mutating func convertPlatform(_ block: JSONValue, index: Int, disabled: [String]) throws {
            guard let object = block.objectValue else {
                report.problems.append(Message("platformNotObject", ["index": String(index)]))
                return
            }
            guard let platform = object["platform"]?.stringValue, !platform.isEmpty else {
                report.problems.append(Message("platformNameMissing", ["index": String(index)]))
                return
            }
            seenPlatforms.insert(HomebridgeImport.normalized(platform))
            let name = object["name"]?.stringValue ?? platform
            if platform == "config" {
                report.items.append(Item(group: name, path: "platform", outcome: .dropped, value: platform, count: nil, note: Message("webUI")))
                return
            }
            let canonical = HomebridgeImport.renamedPlatforms[platform] ?? platform
            guard let supported = platforms[canonical] else {
                report.items.append(Item(group: name, path: "platform", outcome: .dropped, value: platform, count: nil, note: Message("unsupportedPlatform", ["platform": platform])))
                return
            }

            var block: [String: JSONValue] = ["platform": .string(canonical), "name": .string(name)]
            let paused = disabled.contains { HomebridgeImport.normalized($0) == HomebridgeImport.normalized(platform) }
            if paused {
                block["_paused"] = .bool(true)
                report.items.append(Item(group: name, path: "_paused", outcome: .imported, value: "true", count: nil, note: Message("paused")))
            }
            let properties = supported.schema?["properties"]?.objectValue
            for key in object.keys.sorted() where key != "platform" && key != "name" {
                let value = object[key] ?? .null
                switch key {
                case "_bridge":
                    if let child = value.objectValue {
                        block["_bridge"] = try convertChild(child, group: name)
                    }
                case "platforms":
                    report.items.append(Item(group: name, path: key, outcome: .dropped, value: nil, count: nil, note: Message("nestedConfig")))
                default:
                    if let properties, properties[key] == nil {
                        report.items.append(Item(group: name, path: key, outcome: .dropped, value: nil, count: nil, note: Message("notSetting", ["platform": platform])))
                        continue
                    }
                    if let kept = try record(value, key: key, path: key, group: name, schema: properties?[key], depth: 0) {
                        block[key] = kept
                    }
                }
            }
            kept.append(.object(block))
        }

        mutating func convertChild(_ object: [String: JSONValue], group: String) throws -> JSONValue {
            var out: [String: JSONValue] = [:]
            for key in object.keys.sorted() {
                let value = object[key] ?? .null
                guard HomebridgeImport.childBridgeKeys.contains(key) else {
                    report.items.append(Item(group: group, path: "bridge.\(key)", outcome: .dropped, value: nil, count: nil, note: Message("notUsed")))
                    continue
                }
                if key == "pin", let text = value.stringValue {
                    out[key] = try sealedPIN(text, path: "bridge.pin", group: group)
                    continue
                }
                out[key] = value
            }
            return .object(out)
        }

        /// The value kept under `path`, its secrets sealed. `schema` is the node of the plugin's schema the value
        /// is checked against (nil: no schema, so every key is kept). Only top-level plain values are listed one
        /// by one; a list or an object is listed once with its size, and its secrets each on their own line.
        mutating func record(_ value: JSONValue, key: String, path: String, group: String, schema: JSONValue?, depth: Int, underSecret: Bool = false) throws -> JSONValue? {
            let secret = schema?["x-schema-form"]?["type"]?.stringValue == "password"
            // A password-type field, a secret name, or anything under one: sealed, and its children are too.
            let sealedHere = underSecret || secret || Redaction.isSecretKey(key)
            switch value {
            case .string(let text):
                if !text.isEmpty, sealedHere || Redaction.isCredentialURL(text) {
                    report.items.append(Item(group: group, path: path, outcome: .encrypted, value: nil, count: nil, note: nil))
                    return .string(try sealText(text))
                }
                if depth == 0 {
                    report.items.append(Item(group: group, path: path, outcome: .imported, value: String(text.prefix(80)), count: nil, note: nil))
                }
                return value
            case .number, .bool:
                // A number cannot be sealed as text and read back as a number, so a numeric secret is left out.
                if sealedHere {
                    report.items.append(Item(group: group, path: path, outcome: .dropped, value: nil, count: nil, note: Message("numericSecret")))
                    return nil
                }
                if depth == 0 {
                    report.items.append(Item(group: group, path: path, outcome: .imported, value: value.text(), count: nil, note: nil))
                }
                return value
            case .array(let elements):
                if depth == 0 {
                    report.items.append(Item(group: group, path: path, outcome: .imported, value: nil, count: elements.count, note: nil))
                }
                let itemSchema = schema?["items"]
                var out: [JSONValue] = []
                for (index, element) in elements.enumerated() {
                    if let kept = try record(element, key: key, path: "\(path)[\(index)]", group: group, schema: itemSchema, depth: depth + 1, underSecret: underSecret) {
                        out.append(kept)
                    }
                }
                return .array(out)
            case .object(let object):
                if depth == 0 {
                    report.items.append(Item(group: group, path: path, outcome: .imported, value: nil, count: object.count, note: nil))
                }
                let properties = schema?["properties"]?.objectValue
                var out: [String: JSONValue] = [:]
                for child in object.keys.sorted() {
                    let childValue = object[child] ?? .null
                    if let properties, properties[child] == nil {
                        report.items.append(Item(group: group, path: "\(path).\(child)", outcome: .dropped, value: nil, count: nil, note: Message("notSetting", ["platform": group])))
                        continue
                    }
                    if let kept = try record(childValue, key: child, path: "\(path).\(child)", group: group, schema: properties?[child], depth: depth + 1, underSecret: sealedHere) {
                        out[child] = kept
                    }
                }
                return .object(out)
            case .null:
                return value
            }
        }

        func syntax(_ data: Data, offset: Int, detail: String) -> Syntax {
            let upTo = Array(data.prefix(max(0, min(offset, data.count))))
            let line = upTo.filter { $0 == 0x0A }.count + 1
            let lineStart = upTo.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            let column = upTo.count - lineStart + 1
            return Syntax(line: line, column: column, hint: offset >= data.count ? "unexpectedEnd" : "other", detail: detail)
        }
    }
}
