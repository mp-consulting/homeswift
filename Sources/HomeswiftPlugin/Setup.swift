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

    public init(deviceID: String, name: String, model: String? = nil, address: String? = nil, authorization: AuthorizationMethod = .none, isSetUp: Bool = false) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.address = address
        self.authorization = authorization
        self.isSetUp = isSetUp
    }
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
    }

    public var key: String
    /// For people: "PIN shown on the TV".
    public var label: String
    public var kind: Kind
    public var optional: Bool

    public init(_ key: String, label: String, kind: Kind = .text, optional: Bool = false) {
        self.key = key
        self.label = label
        self.kind = kind
        self.optional = optional
    }
}

/// What a step of Setup asks: a message, the answers it wants, a page to open, or a wait.
public struct SetupPrompt: Sendable, Codable, Equatable {
    /// For people, one or two sentences: "Press the link button on the Hue Bridge."
    public var message: String
    public var fields: [SetupField]
    /// A Browser Redirect's page to open.
    public var url: String?
    /// A Button Press: how long the device waits for it, in seconds. The step is sent again, with no answers, every
    /// `retryAfter` seconds until the plugin is done or the time is up.
    public var waitSeconds: Int?
    public var retryAfter: Int?

    public init(message: String, fields: [SetupField] = [], url: String? = nil, waitSeconds: Int? = nil, retryAfter: Int? = nil) {
        self.message = message
        self.fields = fields
        self.url = url
        self.waitSeconds = waitSeconds
        self.retryAfter = retryAfter
    }
}

/// What an Authorization gives the bridge once it is done.
public struct SetupOutcome: Sendable {
    /// What the plugin needs to talk to the device or the account (a token, a key, a password): the bridge seals it in
    /// the vault, in the instance's namespace, and hands it back with `PluginContext.credentials`. Never in config.json.
    public var credentials: JSONValue?
    /// Settings that are not secret, merged into the plugin's block for an account (a hub's host), or into the device's
    /// Accessory Settings for a device.
    public var settings: [String: JSONValue]

    public init(credentials: JSONValue? = nil, settings: [String: JSONValue] = [:]) {
        self.credentials = credentials
        self.settings = settings
    }
}

/// A plugin's answer to a step of Setup.
public enum SetupStep: Sendable {
    /// Asks the person (or the agent) for more. `state` comes back with the next request, so the plugin keeps nothing
    /// between steps: a reload of the plugin, or a new instance, takes the Setup on from there.
    case ask(SetupPrompt, state: JSONValue = .null)
    case done(SetupOutcome)
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
