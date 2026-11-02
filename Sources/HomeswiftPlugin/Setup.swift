import Foundation
import HomeswiftAI

// Setup (GLOSSARY.md, "Setup"): a plugin finds its devices (`discover`), says what each one asks before the bridge
// may talk to it (an `AuthorizationMethod`), and answers the steps of that Authorization (`authorize`). The bridge
// holds each Setup in progress (a Setup Session), keeps what an Authorization gives in the vault, and writes the
// settings it brings, so the web UI and MCP clients set up every plugin's devices the same way.

/// The kinds of Authorization the bridge knows how to ask a person or an agent for.
public enum AuthorizationMethod: String, Sendable, Codable, CaseIterable {
    /// The plugin reaches the device as it is.
    case none
    /// A button on the device or its hub, pressed within a while (a Hue Bridge's link button).
    case buttonPress
    /// A code the device shows or sends (a TV's PIN).
    case deviceCode
    /// An account's email or user name and password, perhaps followed by a one-time code.
    case accountLogin
    /// A page the person opens in a browser to sign in, whose address they paste back when it redirects.
    case browserRedirect
    /// Keys from a developer portal.
    case apiKey
}

/// A device a plugin has found (GLOSSARY.md, "Discovered Device").
public struct DiscoveredDevice: Sendable, Codable, Equatable {
    /// The plugin's identifier for it (GLOSSARY.md, "Device Id"): `<platform>:<deviceID>` is its accessory's id.
    public var deviceID: String
    public var name: String
    public var model: String?
    /// Where it answers, when it has an address of its own: `192.168.1.20`, `hue.local:443`.
    public var address: String?
    /// What it asks before the bridge may talk to it.
    public var authorization: AuthorizationMethod
    /// The plugin talks to it already: Authorized, or needing none, and not Excluded.
    public var isSetUp: Bool
    /// Excluded by its Accessory Settings; the bridge sets it.
    public var isExcluded = false
    /// Left out by one of the plugin's own settings (a Homebridge-shaped exclude list), not by its Accessory Settings: the
    /// person includes it again there.
    public var excludedBySettings: Bool
    /// Whether it answered when last asked: false for one set up that the plugin cannot reach now (a console asleep, a
    /// hub unplugged), which Setup shows as not responding rather than set up.
    public var isReachable = true
    /// What it brings that a person can leave out on its own (GLOSSARY.md, "Part"): a gate's side door, a door's
    /// position sensor, a doorbell. Its Accessory Settings' `parts` keep the choice.
    public var parts: [DevicePart] = []

    public init(
        deviceID: String, name: String, model: String? = nil, address: String? = nil, authorization: AuthorizationMethod = .none, isSetUp: Bool = false,
        excludedBySettings: Bool = false
    ) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.address = address
        self.authorization = authorization
        self.isSetUp = isSetUp
        self.excludedBySettings = excludedBySettings
    }
}

/// A part of a device (GLOSSARY.md, "Part"): an accessory or a service it brings, which a person can leave out while
/// keeping the device. `id` is the plugin's (`SideDoor`, `DPS`); `icon` one of the web UI's (`lock`, `sensor`, `bell`).
public struct DevicePart: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var icon: String?
    public var included: Bool

    public init(_ id: String, name: String, icon: String? = nil, included: Bool) {
        self.id = id
        self.name = name
        self.icon = icon
        self.included = included
    }
}

extension DiscoveredDevice {
    /// Where it stands, as the Add accessories page and MCP clients show it.
    public enum Status: String, Sendable {
        case setUp, notResponding, needsAuthorization, discovered, excluded
    }

    public var status: Status {
        isExcluded || excludedBySettings ? .excluded : isSetUp ? (isReachable ? .setUp : .notResponding) : authorization == .none ? .discovered : .needsAuthorization
    }
}

/// What a plugin finds, and whether its account is Authorized.
public struct Discovery: Sendable {
    public var devices: [DiscoveredDevice]
    public var accountAuthorized: Bool
}

/// One answer a step of Setup asks for.
public struct SetupField: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// Plain text: a user name, an address.
        case text
        /// Never shown back or logged, never a tool argument: a password, a key.
        case secret
        /// A short code a device or a message gave: a PIN, a one-time code.
        case code
        /// The address a browser was sent to after signing in.
        case url
        /// One of `options`, by its value: how to sign in, a region.
        case choice
    }

    public var key: String
    /// For people: "PIN shown on the TV".
    public var label: String
    public var kind: Kind
    public var optional: Bool
    /// A choice's options.
    public var options: [SetupOption]
    /// The answer chosen or typed already, when there is one (the block's): a choice's option shown as picked.
    public var value: String?

    public init(_ key: String, label: String, kind: Kind = .text, optional: Bool = false, options: [SetupOption] = [], value: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.optional = optional
        self.options = options
        self.value = value
    }

    /// A choice between `options`, `value` picked to begin with.
    public static func choice(_ key: String, label: String, options: [SetupOption], value: String? = nil, optional: Bool = false) -> SetupField {
        SetupField(key, label: label, kind: .choice, optional: optional, options: options, value: value)
    }
}

/// One option of a choice: its value, what it is called and, for people, what it means. In English, as prompts are.
/// An option that is a country or a language carries its code, which the web UI names in the reader's language.
public struct SetupOption: Sendable, Codable, Equatable {
    public var value: String
    public var label: String
    public var detail: String?
    /// The ISO 3166 country the option is (`GB`).
    public var country: String?
    /// The language tag the option is (`fr-FR`).
    public var language: String?

    public init(_ value: String, label: String, detail: String? = nil, country: String? = nil, language: String? = nil) {
        self.value = value
        self.label = label
        self.detail = detail
        self.country = country
        self.language = language
    }

    /// Countries by their ISO 3166 codes (every country when nil), each answering `value(code)`: the code itself, or
    /// what the plugin sends for it (a calling code). Labelled in English, sorted by name.
    public static func countries(_ codes: [String]? = nil, value: (String) -> String = { $0 }) -> [SetupOption] {
        let english = Locale(identifier: "en_US")
        // Countries and territories: not the European Union or the United Nations (no region holds them), nor the
        // codes for unknown or pseudo regions.
        let all = codes ?? Locale.Region.isoRegions.filter { $0.containingRegion != nil }.map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) && !["QO", "XA", "XB", "ZZ"].contains($0) }
        return all.compactMap { code in
            guard let name = english.localizedString(forRegionCode: code), name != code else { return nil }
            return SetupOption(value(code), label: name, country: code)
        }.sorted { $0.label < $1.label }
    }

    /// Languages as a language and a country (`fr-FR`), the tags the system knows, labelled in English.
    public static func languages() -> [SetupOption] {
        let english = Locale(identifier: "en_US")
        let tags = Set(Locale.availableIdentifiers.compactMap { identifier -> String? in
            let parts = identifier.split(separator: "_")
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, parts[1].allSatisfy(\.isUppercase) else { return nil }
            return "\(parts[0])-\(parts[1])"
        })
        return tags.compactMap { tag in
            english.localizedString(forIdentifier: tag.replacingOccurrences(of: "-", with: "_")).map { SetupOption(tag, label: $0, language: tag) }
        }.sorted { $0.label < $1.label }
    }
}

/// What a step of Setup asks: a message, the answers it wants, a page to open, or a wait.
public struct SetupPrompt: Sendable, Codable, Equatable {
    /// For people, one or two sentences: "Press the link button on the Hue Bridge." In English, translated by the web UI's
    /// catalogs; what changes from one Setup to the next (a certificate's start) goes in `values`, as `{name}` here.
    public var message: String
    /// The values of `message`'s `{name}` placeholders.
    public var values: [String: String]
    public var fields: [SetupField]
    /// A Browser Redirect's page to open.
    public var url: String?
    /// A Button Press: how long the device waits for it, in seconds. The step is sent again, with no answers, every
    /// `retryAfter` seconds until the plugin is done or the time is up.
    public var waitSeconds: Int?
    public var retryAfter: Int?

    public init(message: String, values: [String: String] = [:], fields: [SetupField] = [], url: String? = nil, waitSeconds: Int? = nil, retryAfter: Int? = nil) {
        self.message = message
        self.values = values
        self.fields = fields
        self.url = url
        self.waitSeconds = waitSeconds
        self.retryAfter = retryAfter
    }

    /// The message with its values in place, as a model or a log reads it.
    public var text: String {
        values.reduce(message) { text, value in text.replacingOccurrences(of: "{\(value.key)}", with: value.value) }
    }
}

/// What an Authorization gives the bridge once it is done.
public struct SetupOutcome: Sendable {
    /// What the plugin needs to talk to the device or the account (a token, a key, a password): the bridge seals it in
    /// the vault, in the instance's namespace, and hands it back with `PluginContext.credentials`. Never in config.json.
    public var credentials: JSONValue?
    /// Settings that are not secret, merged into the plugin's block for an account (a hub's host), or into the device's
    /// Accessory Settings for a device. A null takes the key out of the block: a key the credentials now hold.
    public var settings: [String: JSONValue]
    /// The device's Device Id when the Authorization is what tells it (a TV's MAC, read once paired): the credentials and
    /// the settings go under it rather than under the one discovery gave.
    public var deviceID: String?

    public init(credentials: JSONValue? = nil, settings: [String: JSONValue] = [:], deviceID: String? = nil) {
        self.credentials = credentials
        self.settings = settings
        self.deviceID = deviceID
    }

    /// With the plugin's own credentials type, encoded.
    public init(encoding credentials: some Encodable, settings: [String: JSONValue] = [:], deviceID: String? = nil) throws {
        let json = try JSONValue(encoding: credentials)
        self.init(credentials: json, settings: settings, deviceID: deviceID)
    }
}

/// A plugin's answer to a step of Setup.
public enum SetupStep: Sendable {
    /// Asks the person (or the agent) for more. `state` comes back with the next request, so the plugin keeps nothing
    /// between steps: a reload of the plugin, or a new instance, takes the Setup on from there.
    case ask(SetupPrompt, state: JSONValue = .null)
    case done(SetupOutcome)

    /// The step with a choice made at the start kept: in the state of the steps that follow, and in the settings once
    /// done (how to sign in, chosen first, is the block's from then on).
    public func keeping(_ key: String, _ value: JSONValue) -> SetupStep {
        switch self {
        case .ask(let prompt, let state):
            var kept = state.objectValue ?? [:]
            kept[key] = value
            return .ask(prompt, state: .object(kept))
        case .done(var outcome):
            outcome.settings[key] = value
            return .done(outcome)
        }
    }
}

/// A step of Setup the bridge hands a plugin.
public struct SetupRequest: Sendable {
    public enum Target: Sendable, Equatable {
        /// The plugin instance's account.
        case account
        case device(DiscoveredDevice)
    }

    public let target: Target
    /// The answers to the last prompt's fields, by key; empty on the first step and on a Button Press's retries.
    public let answers: [String: String]
    /// What the last step kept (`SetupStep.ask`'s state); `.null` on the first step.
    public let state: JSONValue

    public init(target: Target, answers: [String: String] = [:], state: JSONValue = .null) {
        self.target = target
        self.answers = answers
        self.state = state
    }

    /// The first step: nothing asked yet.
    public var isFirst: Bool { state.isNull && answers.isEmpty }

    /// An answer, trimmed; nil when missing or empty.
    public func answer(_ key: String) -> String? {
        guard let text = answers[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A choice made at the start, kept by `SetupStep.keeping`, or this step's answer to it; one of `values` only.
    public func choice(_ key: String, among values: [String]) -> String? {
        guard let chosen = state[key]?.stringValue ?? answer(key), values.contains(chosen) else { return nil }
        return chosen
    }

    /// A secret answer (a password, a key) as typed: never trimmed, only nil when missing or empty.
    public func secret(_ key: String) -> String? {
        guard let text = answers[key], !text.isEmpty else { return nil }
        return text
    }

    /// Throws for a device step, for a plugin whose devices come with its account.
    public func requireAccount(_ reason: String = "Its devices come with the account: they need no setup of their own") throws {
        guard target == .account else { throw SetupError(reason) }
    }

    /// The device this step is for; throws for an account step.
    public func device() throws -> DiscoveredDevice {
        guard case .device(let device) = target else { throw SetupError("This step is for a device") }
        return device
    }
}

/// A step that did not work, for people: the Setup stays where it was, so they can answer again.
public struct SetupError: Error, CustomStringConvertible, Sendable, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
