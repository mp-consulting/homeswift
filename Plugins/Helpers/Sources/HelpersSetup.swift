import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (docs/plugins.md, "Setup"): a Helper has no device to find. Add a Helper… (Add by address's Setup, `.newDevice`)
// asks its rule, then its sources and values, and ends with the Helper's Accessory Settings under a new Device Id; its
// settings sheet edits them later, the sources offered by `accessorySettingChoices`. The prompts are English, with
// their French, Spanish and Portuguese in the web UI's catalogs.
extension HelpersPlugin {
    public func discover() async throws -> [DiscoveredDevice] {
        context.allAccessorySettings.sorted { $0.key < $1.key }.compactMap { deviceID, settings in
            guard let kind = settings.plugin["rule"]?.stringValue.flatMap(HelperRule.Kind.init(rawValue:)) else { return nil }
            var device = DiscoveredDevice(deviceID: deviceID, name: settings.name ?? "Helper", model: "\(kind.title) Helper", isSetUp: true, kind: kind.rawValue)
            device.isReachable = isReachable(deviceID) ?? true
            return device
        }
    }

    /// Its Device Kind is its rule: each kind has its own settings.
    public func deviceKind(of deviceID: String) async -> String? {
        context.accessorySettings(for: deviceID).plugin["rule"]?.stringValue
    }

    public func accessorySettingChoices(_ key: String, deviceID: String) async -> [SetupOption]? {
        let settings = context.accessorySettings(for: deviceID).plugin
        guard let kind = settings["rule"]?.stringValue.flatMap(HelperRule.Kind.init(rawValue:)) else { return nil }
        let own = Self.accessoryID(deviceID: deviceID)
        let accessories = context.hostAccessories
        switch (key, kind) {
        case ("source", .threshold):
            return Self.withCurrent(settings[key], accessories.sourceCandidates(except: own) { $0.isReading }.map(\.option))
        case ("source", .stays):
            return Self.withCurrent(settings[key], accessories.sourceCandidates(except: own) { $0.hasStates }.map(\.option))
        case ("sources", .combine):
            guard let measure = settings["measure"]?.stringValue.flatMap(Measure.init(rawValue:)) else { return nil }
            var options = accessories.sourceCandidates(except: own) { $0.measure == measure }.map(\.option)
            for value in settings[key]?.arrayValue ?? [] { options = Self.withCurrent(value, options) }
            return options
        case ("state", .stays):
            guard let source = settings["source"]?.stringValue.flatMap(SourceRef.init),
                  let type = accessories.sourceCandidates { _ in true }.first(where: { $0.ref == source })?.type,
                  let states = SourceStates.states(of: type) else { return nil }
            return states.map { SetupOption(String($0.value), label: $0.label) }
        default:
            return nil
        }
    }

    /// The options with the value set now added when it is not one of them (its accessory gone): it stays shown, and picked.
    static func withCurrent(_ value: JSONValue?, _ options: [SetupOption]) -> [SetupOption] {
        guard let text = value?.stringValue, !options.contains(where: { $0.value == text }) else { return options }
        return options + [SetupOption(text, label: "Missing: \(text)")]
    }

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.isNewDevice else { return .done(SetupOutcome()) }
        // What the steps before answered, and this one's answers on top.
        var known = request.state.objectValue ?? [:]
        for (key, _) in request.answers {
            let values = request.answers(key)
            if key == "sources" { known[key] = .array(values.map(JSONValue.string)) } else if let value = request.answer(key) { known[key] = .string(value) }
        }
        let accessories = context.hostAccessories
        let ask = { (prompt: SetupPrompt) in SetupStep.ask(prompt, state: .object(known)) }

        guard let kind = known["rule"]?.stringValue.flatMap(HelperRule.Kind.init(rawValue:)) else {
            return .ask(SetupPrompt(message: "What should the Helper do?", fields: [
                .choice("rule", label: "Kind of Helper", options: HelperRule.Kind.allCases.map { SetupOption($0.rawValue, label: $0.title, detail: $0.detail) }),
            ]))
        }
        switch kind {
        case .threshold:
            let candidates = accessories.sourceCandidates { $0.isReading }
            guard !candidates.isEmpty else { throw SetupError("No accessory has a reading to watch yet") }
            guard known["source"] != nil else {
                return ask(SetupPrompt(message: "Pick the reading to watch, and where the Helper turns on and off.", fields: [
                    .choice("source", label: "Reading to watch", options: candidates.map(\.option)),
                    .choice("direction", label: "Turns on", options: [
                        SetupOption("above", label: "Above the on value"), SetupOption("below", label: "Below the on value"),
                    ], value: "above"),
                    SetupField("on", label: "On value"),
                    SetupField("off", label: "Off value (leave empty for the on value)", optional: true),
                    SetupField("name", label: "Name"),
                ]))
            }
            let source = try Self.source(known["source"], among: candidates)
            guard let on = known["on"]?.stringValue.flatMap(HelperRule.number) else { throw SetupError("Enter a number for the on value") }
            let off: Double
            if let text = known["off"]?.stringValue {
                guard let value = HelperRule.number(text) else { throw SetupError("Enter a number for the off value") }
                off = value
            } else {
                off = on
            }
            let above = known["direction"]?.stringValue != "below"
            do { try HelperRule.checkHysteresis(above: above, on: on, off: off) } catch {
                throw SetupError(above ? "The off value must be at most the on value" : "The off value must be at least the on value")
            }
            return try done(kind, name: known, settings: [
                "source": .string(source.description), "direction": .string(above ? "above" : "below"), "on": .number(on), "off": .number(off),
            ])

        case .combine:
            guard let measure = known["measure"]?.stringValue.flatMap(Measure.init(rawValue:)) else {
                let offered = Measure.allCases.filter { measure in !accessories.sourceCandidates { $0.measure == measure }.isEmpty }
                guard !offered.isEmpty else { throw SetupError("No accessory has a temperature, humidity, light level or power to combine yet") }
                return ask(SetupPrompt(message: "What should the Helper combine?", fields: [
                    .choice("measure", label: "Measure", options: offered.map { SetupOption($0.rawValue, label: $0.title) }),
                ]))
            }
            let candidates = accessories.sourceCandidates { $0.measure == measure }
            guard known["sources"] != nil else {
                return ask(SetupPrompt(message: "Pick the sensors to combine, and how.", fields: [
                    .choices("sources", label: "Sensors", options: candidates.map(\.option)),
                    .choice("function", label: "Show", options: Function.allCases.map { SetupOption($0.rawValue, label: $0.title) }, value: Function.average.rawValue),
                    SetupField("name", label: "Name"),
                ]))
            }
            let sources = try (known["sources"]?.arrayValue ?? []).map { try Self.source($0, among: candidates) }
            guard !sources.isEmpty else { throw SetupError("Pick at least one sensor") }
            let function = known["function"]?.stringValue.flatMap(Function.init(rawValue:)) ?? .average
            return try done(kind, name: known, settings: [
                "measure": .string(measure.rawValue), "function": .string(function.rawValue), "sources": .array(sources.map { .string($0.description) }),
            ])

        case .stays:
            let candidates = accessories.sourceCandidates { $0.hasStates }
            guard !candidates.isEmpty else { throw SetupError("No accessory has a state to wait on yet") }
            guard known["source"] != nil else {
                return ask(SetupPrompt(message: "Pick what to wait on.", fields: [.choice("source", label: "Accessory", options: candidates.map(\.option))]))
            }
            let candidate = try Self.candidate(known["source"], among: candidates)
            let states = SourceStates.states(of: candidate.type) ?? []
            guard known["state"] != nil else {
                return ask(SetupPrompt(message: "The Helper turns on once {source} has stayed in this state for as long as you say.", values: ["source": candidate.label], fields: [
                    .choice("state", label: "State", options: states.map { SetupOption(String($0.value), label: $0.label) }, value: states.first.map { String($0.value) }),
                    SetupField("minutes", label: "For longer than (minutes)"),
                    SetupField("name", label: "Name"),
                ]))
            }
            guard let state = known["state"]?.stringValue.flatMap(Int.init), states.contains(where: { $0.value == state }) else { throw SetupError("Pick a state") }
            guard let minutes = known["minutes"]?.stringValue.flatMap(HelperRule.number), minutes >= 0, minutes <= 10_080 else {
                throw SetupError("Enter the minutes as a number from 0 to 10080 (a week)")
            }
            return try done(kind, name: known, settings: [
                "source": .string(candidate.ref.description), "state": .string(String(state)), "minutes": .number(minutes),
            ])
        }
    }

    /// The end of a Helper's Setup: its rule and settings under a new Device Id, with its Name.
    private func done(_ kind: HelperRule.Kind, name known: [String: JSONValue], settings: [String: JSONValue]) throws -> SetupStep {
        guard let name = known["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw SetupError("Give the Helper a name") }
        let taken = Set(context.allAccessorySettings.keys)
        var deviceID = dependencies.newID()
        while taken.contains(deviceID) { deviceID = dependencies.newID() }
        var all = settings
        all["rule"] = .string(kind.rawValue)
        all["name"] = .string(String(name.prefix(AccessoryNaming.maxLength)))
        return .done(SetupOutcome(settings: all, deviceID: deviceID))
    }

    /// The source picked, which must be one of those offered.
    static func source(_ value: JSONValue?, among candidates: [SourceCandidate]) throws -> SourceRef {
        try candidate(value, among: candidates).ref
    }

    static func candidate(_ value: JSONValue?, among candidates: [SourceCandidate]) throws -> SourceCandidate {
        guard let ref = value?.stringValue.flatMap(SourceRef.init), let found = candidates.first(where: { $0.ref == ref }) else {
            throw SetupError("Pick one of the accessories listed")
        }
        return found
    }
}
