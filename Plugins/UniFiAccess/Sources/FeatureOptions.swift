import Foundation

/// One feature option of a category: `Hub.DPS` is the option `DPS` of the category `Hub`. An option with a
/// `defaultValue` is value-centric (`Enable.Hub.LockDelayInterval.5`).
struct FeatureOptionEntry: Sendable, Equatable {
    var name: String
    var `default`: Bool
    var defaultValue: Double?
    var description: String
    /// Options of a group show under their group's option in the settings page.
    var group: String?
    /// The settings page shows the option only for devices with one of these capabilities.
    var hasCapability: [String]?
    /// The settings page shows the option only for these models (`display_model`).
    var modelKey: [String]?

    init(
        _ name: String, default: Bool, defaultValue: Double? = nil, description: String, group: String? = nil, hasCapability: [String]? = nil,
        modelKey: [String]? = nil
    ) {
        self.name = name
        self.default = `default`
        self.defaultValue = defaultValue
        self.description = description
        self.group = group
        self.hasCapability = hasCapability
        self.modelKey = modelKey
    }
}

struct FeatureCategory: Sendable, Equatable {
    var name: String
    var description: String
    var hasCapability: [String]?
    var modelKey: [String]?
}

/// Where an option's state comes from.
enum FeatureOptionScope: String, Sendable {
    case device, controller, global, none
}

/// The value of a value-centric option: `nil` in the TypeScript (`disabled`) when the option is off or not
/// value-centric, `undefined` (`enabledWithoutValue`) when it is on at an explicit scope with no value.
enum FeatureValue: Sendable, Equatable {
    case disabled
    case enabledWithoutValue
    case value(String)

    var string: String? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// A number read from a value-centric option, with the same three outcomes; a value that is not a number is
/// `enabledWithoutValue`, as `parseInt` giving NaN was.
enum FeatureNumber: Sendable, Equatable {
    case disabled
    case enabledWithoutValue
    case number(Double)

    /// The number, or nil for both other cases (`?? default` in the TypeScript).
    var value: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

/// The hierarchical feature options of `homebridge-plugin-utils`, rule for rule, so the `options` array users
/// have in config.json means the same here.
///
/// An entry is `Enable.<option>` or `Disable.<option>`, optionally followed by a scope id (a device or a
/// controller) and, for value-centric options, a value: `Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5`. A device
/// entry beats a controller entry beats a global one; the first of conflicting entries wins; matching ignores case.
struct FeatureOptions: Sendable {
    private(set) var categories: [FeatureCategory]
    private(set) var options: [String: [FeatureOptionEntry]]
    private(set) var configuredOptions: [String]
    /// Recognises scope ids, so `Enable.Option.X` with an id for X scopes the option to X instead of reading X as
    /// a global value.
    private let isIdentifier: (@Sendable (String) -> Bool)?
    /// For options nobody defined.
    var defaultReturnValue = false

    private var defaults: [String: Bool] = [:]
    private var valueOptions: [String: Double?] = [:]
    private(set) var groups: [String: [String]] = [:]
    private var lookup: [String: (enabled: Bool, value: String?)] = [:]

    init(categories: [FeatureCategory], options: [String: [FeatureOptionEntry]], configured: [String] = [], isIdentifier: (@Sendable (String) -> Bool)? = nil) {
        self.categories = categories
        self.options = options
        configuredOptions = configured
        self.isIdentifier = isIdentifier
        generateDefaults()
    }

    mutating func setConfigured(_ configured: [String]) {
        configuredOptions = configured
        generateDefaults()
    }

    // MARK: Queries

    /// Whether the option is on, from the device up to the global scope, else its default.
    func test(_ option: String, device: String? = nil, controller: String? = nil) -> Bool {
        resolve(option, device: device, controller: controller).enabled
    }

    func scope(_ option: String, device: String? = nil, controller: String? = nil) -> FeatureOptionScope {
        resolve(option, device: device, controller: controller).scope
    }

    func value(_ option: String, device: String? = nil, controller: String? = nil) -> FeatureValue {
        guard isValue(option) else { return .disabled }
        let resolved = resolve(option, device: device, controller: controller)
        guard resolved.enabled else { return .disabled }
        if let value = resolved.value, !value.isEmpty { return .value(value) }
        if resolved.scope == .none {
            guard let registered = valueOptions[option.lowercased()], let number = registered else { return .disabled }
            return .value(Self.javaScriptString(number))
        }
        return .enabledWithoutValue
    }

    func integer(_ option: String, device: String? = nil, controller: String? = nil) -> FeatureNumber {
        numeric(value(option, device: device, controller: controller), Self.parseInt)
    }

    func float(_ option: String, device: String? = nil, controller: String? = nil) -> FeatureNumber {
        numeric(value(option, device: device, controller: controller), Self.parseFloat)
    }

    func defaultValue(_ option: String) -> Bool {
        defaults[option.lowercased()] ?? defaultReturnValue
    }

    func exists(_ option: String, id: String? = nil) -> Bool {
        lookup[option.lowercased() + (id.map { "." + $0.lowercased() } ?? "")] != nil
    }

    func isScopeDevice(_ option: String, device: String) -> Bool { exists(option, id: device) }
    func isScopeGlobal(_ option: String) -> Bool { exists(option) }

    func isValue(_ option: String) -> Bool {
        !option.isEmpty && valueOptions.keys.contains(option.lowercased())
    }

    /// The Bootstrap colour the Homebridge settings page gave each scope.
    func color(_ option: String, device: String? = nil, controller: String? = nil) -> String {
        switch scope(option, device: device, controller: controller) {
        case .device: "text-info"
        case .controller: "text-success"
        case .global: device != nil ? "text-warning" : "text-info"
        case .none: ""
        }
    }

    /// `Hub` and `DPS` as `Hub.DPS`; the unnamed option of a category is the category itself.
    func expandOption(_ category: String, _ option: String) -> String {
        guard !category.isEmpty else { return "" }
        return option.isEmpty ? category : "\(category).\(option)"
    }

    // MARK: Index

    private func resolve(_ option: String, device: String?, controller: String?) -> (enabled: Bool, value: String?, scope: FeatureOptionScope) {
        let normalized = option.lowercased()
        if let device, let entry = lookup[normalized + "." + device.lowercased()] { return (entry.enabled, entry.value, .device) }
        if let controller, let entry = lookup[normalized + "." + controller.lowercased()] { return (entry.enabled, entry.value, .controller) }
        if let entry = lookup[normalized] { return (entry.enabled, entry.value, .global) }
        return (defaultValue(option), nil, .none)
    }

    private func numeric(_ value: FeatureValue, _ convert: (String) -> Double?) -> FeatureNumber {
        switch value {
        case .disabled: .disabled
        case .enabledWithoutValue: .enabledWithoutValue
        case .value(let string): convert(string).map(FeatureNumber.number) ?? .enabledWithoutValue
        }
    }

    private func looksLikeIdentifier(_ segment: String) -> Bool {
        if let isIdentifier { return isIdentifier(segment) }
        // A short run of digits is a number, not an id: ids are MAC addresses or longer hexadecimal strings.
        return !(1...11).contains(segment.count) || !segment.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private mutating func generateDefaults() {
        defaults = [:]
        groups = [:]
        valueOptions = [:]
        for category in categories {
            guard let entries = options[category.name] else { continue }
            for option in entries {
                let entry = expandOption(category.name, option.name)
                defaults[entry.lowercased()] = option.default
                if option.defaultValue != nil || Self.valueCentric.contains(entry.lowercased()) {
                    valueOptions[entry.lowercased()] = option.defaultValue
                }
                if let group = option.group {
                    groups[category.name + (group.isEmpty ? "" : ".\(group)"), default: []].append(entry)
                }
            }
        }
        buildIndex()
    }

    /// Options the TypeScript declared with a `defaultValue` key of `undefined`; none in this plugin.
    private static let valueCentric: Set<String> = []

    /// `^-?\d+\.\d+$`: a decimal value such as `12.5`.
    static func isDecimal(_ string: String) -> Bool {
        var rest = Substring(string)
        if rest.first == "-" { rest = rest.dropFirst() }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private mutating func buildIndex() {
        lookup = [:]
        // Longest first, so a more specific name wins over one that is its prefix.
        let valueNames = valueOptions.keys.sorted { $0.count > $1.count }
        for raw in configuredOptions {
            guard let dot = raw.firstIndex(of: ".") else { continue }
            let action = raw[..<dot].lowercased()
            guard action == "enable" || action == "disable" else { continue }
            let enabled = action == "enable"
            let tailOriginal = String(raw[raw.index(after: dot)...])
            let tail = tailOriginal.lowercased()
            if lookup[tail] == nil { lookup[tail] = (enabled, nil) }
            guard enabled else { continue }

            for name in valueNames {
                guard tail.hasPrefix(name) else { continue }
                let remainder = tail.dropFirst(name.count)
                if remainder.isEmpty { break }
                guard remainder.hasPrefix(".") else { continue }
                let extra = String(remainder.dropFirst())
                let extraOriginal = String(tailOriginal.dropFirst(name.count + 1))
                let separator = extra.firstIndex(of: ".")

                if separator != nil, Self.isDecimal(extraOriginal), !looksLikeIdentifier(String(extraOriginal.prefix { $0 != "." })) {
                    // A decimal such as 12.5 whose integer part cannot be an id: a global value.
                    if lookup[name] == nil { lookup[name] = (true, extraOriginal) }
                    break
                }
                if let separator {
                    // An id, then the value.
                    let id = String(extra[..<separator])
                    let offset = extra.distance(from: extra.startIndex, to: separator)
                    let valueOriginal = String(extraOriginal.dropFirst(offset + 1))
                    if !valueOriginal.contains(".") || Self.isDecimal(valueOriginal) {
                        let key = name + "." + id
                        if lookup[key] == nil { lookup[key] = (true, valueOriginal) }
                    }
                } else if lookup[name] == nil, !(isIdentifier?(extraOriginal) ?? false) {
                    // One segment: a global value, unless it is recognisably an id (the scoped key above covers that).
                    lookup[name] = (true, extraOriginal)
                }
                break
            }
        }
    }

    // MARK: JavaScript number parsing

    /// `parseInt(string, 10)`: leading whitespace and sign, then as many digits as there are.
    static func parseInt(_ string: String) -> Double? {
        var characters = Substring(string.drop { $0.isWhitespace })
        var sign = 1.0
        if let first = characters.first, first == "-" || first == "+" {
            sign = first == "-" ? -1 : 1
            characters = characters.dropFirst()
        }
        let digits = characters.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return sign * value
    }

    /// `parseFloat`: the longest prefix that is a decimal number.
    static func parseFloat(_ string: String) -> Double? {
        let trimmed = Substring(string.drop { $0.isWhitespace })
        var best: Double?
        var end = trimmed.startIndex
        while end < trimmed.endIndex {
            end = trimmed.index(after: end)
            let candidate = trimmed[..<end]
            if let value = Double(candidate), !candidate.lowercased().contains("n"), !candidate.contains("x") { best = value }
        }
        return best
    }

    /// `Number.prototype.toString` for the defaults: `60`, `2.5`.
    static func javaScriptString(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e21 { return String(Int64(number)) }
        return String(number)
    }
}
