import Foundation

/// A feature option of the catalog: its name within its category, its default, and, for value-centric
/// options, a default value. The `has…` and `isNotProperty` lists say which devices the web page offers it
/// for; they do not change how an option resolves.
struct FeatureOptionEntry: Sendable, Equatable {
    enum Value: Sendable, Equatable {
        case number(Double)
        case text(String)

        var text: String {
            switch self {
            case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
            case .text(let value): value
            }
        }
    }

    var name: String
    var `default`: Bool
    var defaultValue: Value? = nil
    var description: String
    var group: String? = nil
    var inputSize: Int? = nil
    var hasAccessFeature: [String]? = nil
    var hasCameraFeature: [String]? = nil
    var hasFeature: [String]? = nil
    var hasLightProperty: [String]? = nil
    var hasProperty: [String]? = nil
    var hasSensorProperty: [String]? = nil
    var hasSmartObjectType: [String]? = nil
    var isNotProperty: [String]? = nil
    var modelKey: [String]? = nil
}

/// A category of feature options (`Audio`, `Video.HKSV`, ...).
struct FeatureCategoryEntry: Sendable, Equatable {
    var name: String
    var description: String
    var modelKey: [String] = []
    var hasSensorFeature: [String]? = nil
    var isNotProperty: [String]? = nil
}

/// Where an option was found when it resolved.
enum FeatureOptionScope: String, Sendable {
    case device, controller, global, none
}

/// The hierarchical feature options of `homebridge-plugin-utils` (featureoptions.ts), entry for entry.
///
/// The configuration lists entries such as `Enable.Motion.SmartDetect`, `Disable.Device.F4E2C6000001` or
/// `Enable.Motion.Duration.F4E2C6000001.30`: an action, the option, optionally a scope id (a device MAC or a
/// controller id), and for value-centric options a value. A device entry beats a controller entry, which
/// beats a global one; the first entry wins when one is listed twice; names and ids compare case-insensitively.
struct FeatureOptions: Sendable {
    private struct ConfigEntry: Sendable {
        var enabled: Bool
        var value: String?
    }

    private struct Resolved {
        var enabled: Bool
        var value: String?
        var scope: FeatureOptionScope
    }

    let categories: [FeatureCategoryEntry]
    let options: [String: [FeatureOptionEntry]]
    let configuredOptions: [String]
    /// Returned for options the catalog does not know.
    var defaultReturnValue = false
    /// Option names (expanded) by group (`Video.Crop` → its offsets and sizes).
    private(set) var groups: [String: [String]] = [:]
    private var defaults: [String: Bool] = [:]
    private var valueOptions: [String: FeatureOptionEntry.Value] = [:]
    private var lookup: [String: ConfigEntry] = [:]
    private let isIdentifier: (@Sendable (String) -> Bool)?
    /// Scope ids that contain dots (a controller's address, which the settings page writes): a value after
    /// one of them is read as the value.
    private let dottedIdentifiers: [String]

    init(categories: [FeatureCategoryEntry], options: [String: [FeatureOptionEntry]], configuredOptions: [String] = [], isIdentifier: (@Sendable (String) -> Bool)? = nil,
         dottedIdentifiers: [String] = []) {
        self.categories = categories
        self.options = options
        self.configuredOptions = configuredOptions
        self.isIdentifier = isIdentifier
        self.dottedIdentifiers = dottedIdentifiers.map { $0.lowercased() }.filter { $0.contains(".") }.sorted { $0.count > $1.count }
        generateDefaults()
    }

    /// The fully qualified option: `Category.Option`, or `Category` for the category's own option.
    static func expand(_ category: String, _ option: String) -> String {
        guard !category.isEmpty else { return "" }
        return option.isEmpty ? category : "\(category).\(option)"
    }

    func defaultValue(_ option: String) -> Bool {
        defaults[option.lowercased()] ?? defaultReturnValue
    }

    /// Whether the option is listed explicitly, for the id when there is one.
    func exists(_ option: String, id: String? = nil) -> Bool {
        lookup[option.lowercased() + (id.map { "." + $0.lowercased() } ?? "")] != nil
    }

    func isScopeDevice(_ option: String, device: String) -> Bool { exists(option, id: device) }
    func isScopeGlobal(_ option: String) -> Bool { exists(option) }

    func isValue(_ option: String) -> Bool {
        guard !option.isEmpty else { return false }
        return valueOptions.keys.contains(option.lowercased())
    }

    func scope(_ option: String, device: String? = nil, controller: String? = nil) -> FeatureOptionScope {
        resolve(option, device: device, controller: controller).scope
    }

    /// The Bootstrap colour class the Homebridge settings page used for a scope.
    func color(_ option: String, device: String? = nil, controller: String? = nil) -> String {
        switch scope(option, device: device, controller: controller) {
        case .device: "text-info"
        case .controller: "text-success"
        case .global: device != nil ? "text-warning" : "text-info"
        case .none: ""
        }
    }

    /// Whether the option is on for the device, under the controller.
    func test(_ option: String, device: String? = nil, controller: String? = nil) -> Bool {
        resolve(option, device: device, controller: controller).enabled
    }

    /// The same lookups with several ids for the controller, tried in order: the plugin uses the NVR's MAC,
    /// as the Homebridge plugin does, then the controller's address, which its settings page writes.
    func test(_ option: String, device: String?, controllers: [String]) -> Bool {
        resolve(option, device: device, controllers: controllers).enabled
    }

    func scope(_ option: String, device: String?, controllers: [String]) -> FeatureOptionScope {
        resolve(option, device: device, controllers: controllers).scope
    }

    func value(_ option: String, device: String?, controllers: [String]) -> OptionValue {
        value(option, resolved: resolve(option, device: device, controllers: controllers))
    }

    func getFloat(_ option: String, device: String?, controllers: [String]) -> NumberValue {
        parseNumber(value(option, device: device, controllers: controllers), integer: false)
    }

    func getInteger(_ option: String, device: String?, controllers: [String]) -> NumberValue {
        parseNumber(value(option, device: device, controllers: controllers), integer: true)
    }

    /// The value of a value-centric option. `.disabled` (nil in Homebridge) when the option is off,
    /// `.enabledWithoutValue` (undefined) when it is on at some scope without a value.
    enum OptionValue: Equatable, Sendable {
        case disabled
        case enabledWithoutValue
        case value(String)

        var string: String? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    func value(_ option: String, device: String? = nil, controller: String? = nil) -> OptionValue {
        value(option, resolved: resolve(option, device: device, controller: controller))
    }

    private func value(_ option: String, resolved: Resolved) -> OptionValue {
        guard isValue(option) else { return .disabled }
        guard resolved.enabled else { return .disabled }
        if let value = resolved.value, !value.isEmpty { return .value(value) }
        if resolved.scope == .none {
            guard let fallback = valueOptions[option.lowercased()] else { return .disabled }
            return .value(fallback.text)
        }
        return .enabledWithoutValue
    }

    /// The number of a value-centric option: `.disabled`, `.enabledWithoutValue` when it is on without a
    /// value or with one that is not a number, else the number.
    enum NumberValue: Equatable, Sendable {
        case disabled
        case invalid
        case number(Double)

        /// The value, or nil for both disabled and invalid (`?? default` in Homebridge).
        var orNil: Double? {
            if case .number(let value) = self { return value }
            return nil
        }
    }

    func getFloat(_ option: String, device: String? = nil, controller: String? = nil) -> NumberValue {
        parseNumber(value(option, device: device, controller: controller), integer: false)
    }

    func getInteger(_ option: String, device: String? = nil, controller: String? = nil) -> NumberValue {
        parseNumber(value(option, device: device, controller: controller), integer: true)
    }

    // MARK: Resolution

    private func resolve(_ option: String, device: String?, controller: String?) -> Resolved {
        resolve(option, device: device, controllers: controller.map { [$0] } ?? [])
    }

    private func resolve(_ option: String, device: String?, controllers: [String]) -> Resolved {
        let normalized = option.lowercased()
        if let device, let entry = lookup[normalized + "." + device.lowercased()] {
            return Resolved(enabled: entry.enabled, value: entry.value, scope: .device)
        }
        for controller in controllers {
            if let entry = lookup[normalized + "." + controller.lowercased()] {
                return Resolved(enabled: entry.enabled, value: entry.value, scope: .controller)
            }
        }
        if let entry = lookup[normalized] {
            return Resolved(enabled: entry.enabled, value: entry.value, scope: .global)
        }
        return Resolved(enabled: defaultValue(option), value: nil, scope: .none)
    }

    /// `parseInt`/`parseFloat` of JavaScript: the leading number of the text, if any.
    private func parseNumber(_ value: OptionValue, integer: Bool) -> NumberValue {
        switch value {
        case .disabled: return .disabled
        case .enabledWithoutValue: return .invalid
        case .value(let text):
            guard let number = Self.leadingNumber(text, integer: integer) else { return .invalid }
            return .number(number)
        }
    }

    static func leadingNumber(_ text: String, integer: Bool) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var end = trimmed.startIndex
        var seenDigit = false, seenDot = false
        for (offset, character) in trimmed.enumerated() {
            let index = trimmed.index(trimmed.startIndex, offsetBy: offset)
            if (character == "-" || character == "+"), offset == 0 {
                end = trimmed.index(after: index)
            } else if character.isASCII, character.isNumber {
                seenDigit = true
                end = trimmed.index(after: index)
            } else if character == ".", !integer, !seenDot {
                seenDot = true
                end = trimmed.index(after: index)
            } else {
                break
            }
        }
        guard seenDigit, let number = Double(trimmed[trimmed.startIndex..<end].trimmingCharacters(in: CharacterSet(charactersIn: "."))) else { return nil }
        return integer ? number.rounded(.towardZero) : number
    }

    private func looksLikeIdentifier(_ segment: String) -> Bool {
        if let isIdentifier { return isIdentifier(segment) }
        // A short run of digits is a number; device and controller ids are MACs or longer hex ids.
        return !(segment.count >= 1 && segment.count <= 11 && segment.allSatisfy { $0.isASCII && $0.isNumber })
    }

    private static func isDecimal(_ text: String) -> Bool {
        var body = Substring(text)
        if body.first == "-" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private mutating func generateDefaults() {
        for category in categories {
            guard let entries = options[category.name] else { continue }
            for option in entries {
                let expanded = Self.expand(category.name, option.name)
                defaults[expanded.lowercased()] = option.default
                if let defaultValue = option.defaultValue {
                    valueOptions[expanded.lowercased()] = defaultValue
                }
                if let group = option.group {
                    let expandedGroup = category.name + (group.isEmpty ? "" : "." + group)
                    groups[expandedGroup, default: []].append(expanded)
                }
            }
        }
        buildLookup()
    }

    private mutating func buildLookup() {
        let valueNames = valueOptions.keys.sorted { $0.count > $1.count }
        for raw in configuredOptions {
            guard let dot = raw.firstIndex(of: ".") else { continue }
            let action = raw[..<dot].lowercased()
            guard action == "enable" || action == "disable" else { continue }
            let enabled = action == "enable"
            let tailOriginal = String(raw[raw.index(after: dot)...])
            let tail = tailOriginal.lowercased()
            if lookup[tail] == nil { lookup[tail] = ConfigEntry(enabled: enabled) }
            guard enabled else { continue }
            for name in valueNames {
                guard tail.hasPrefix(name) else { continue }
                let remainder = tail.dropFirst(name.count)
                if remainder.isEmpty { break }
                guard remainder.first == "." else { continue }
                let extra = remainder.dropFirst()
                let extraOriginal = String(tailOriginal.dropFirst(name.count + 1))
                if let id = dottedIdentifiers.first(where: { extra.hasPrefix($0 + ".") }) {
                    let key = name + "." + id
                    if lookup[key] == nil { lookup[key] = ConfigEntry(enabled: true, value: String(extraOriginal.dropFirst(id.count + 1))) }
                    break
                }
                let separator = extra.firstIndex(of: ".")
                if let separator {
                    let firstSegment = String(extraOriginal.prefix(extra.distance(from: extra.startIndex, to: separator)))
                    if Self.isDecimal(extraOriginal), !looksLikeIdentifier(firstSegment) {
                        if lookup[name] == nil { lookup[name] = ConfigEntry(enabled: true, value: extraOriginal) }
                        break
                    }
                    let idLower = String(extra[..<separator])
                    let valueOriginal = String(extraOriginal.dropFirst(idLower.count + 1))
                    if !valueOriginal.contains(".") || Self.isDecimal(valueOriginal) {
                        let key = name + "." + idLower
                        if lookup[key] == nil { lookup[key] = ConfigEntry(enabled: true, value: valueOriginal) }
                    }
                } else if lookup[name] == nil, !(isIdentifier?(extraOriginal) ?? false) {
                    lookup[name] = ConfigEntry(enabled: true, value: extraOriginal)
                }
                break
            }
        }
    }
}
