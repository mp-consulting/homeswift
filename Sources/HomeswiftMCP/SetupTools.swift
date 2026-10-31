import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// One Setup in progress (GLOSSARY.md, "Setup Session"): which instance and which device, the prompt it is at and
/// what the plugin kept for the next step. Held in memory for `SetupSessions.lifetime` after its last step: a PIN or a
/// one-time code would not outlive it, and a restart starts over.
public struct SetupSession: Sendable {
    public let id: String
    public let platform: String
    public let name: String
    /// The block of an instance not saved yet, which the Setup adds once it is done.
    public let draft: JSONValue?
    public let target: SetupRequest.Target
    public let method: AuthorizationMethod
    public var prompt: SetupPrompt
    var state: JSONValue
    var expires: Date

    public var deviceID: String? {
        if case .device(let device) = target { return device.deviceID }
        return nil
    }
}

/// The Setup Sessions of a bridge, shared by the web UI and the MCP sessions, and the devices each instance's last
/// discovery found, which a Setup starts from.
public final class SetupSessions: Sendable {
    static let lifetime: TimeInterval = 600
    private let sessions = NIOLockedValueBox<[String: SetupSession]>([:])
    private let discovered = NIOLockedValueBox<[String: (devices: [DiscoveredDevice], at: Date)]>([:])

    public init() {}

    func put(_ session: SetupSession) {
        var session = session
        session.expires = Date().addingTimeInterval(Self.lifetime)
        sessions.withLockedValue { all in
            all = all.filter { $0.value.expires > Date() }
            all[session.id] = session
        }
    }

    public func session(_ id: String) -> SetupSession? {
        sessions.withLockedValue { $0[id] }.flatMap { $0.expires > Date() ? $0 : nil }
    }

    @discardableResult
    func remove(_ id: String) -> Bool { sessions.withLockedValue { $0.removeValue(forKey: id) } != nil }

    func remember(_ devices: [DiscoveredDevice], for instance: String) {
        discovered.withLockedValue { $0[instance] = (devices, Date()) }
    }

    /// What the instance's discovery found within the lifetime of a session.
    func device(_ deviceID: String, of instance: String) -> DiscoveredDevice? {
        discovered.withLockedValue { $0[instance] }.flatMap { $0.at.addingTimeInterval(Self.lifetime) > Date() ? $0.devices.first { $0.deviceID == deviceID } : nil }
    }
}

extension HomeswiftCatalog {
    /// What the plugin of a block finds now, each device with where it stands: `setUp`, `needsAuthorization`, `discovered`
    /// (needs nothing, the plugin publishes it) or `excluded`. `block` is a block not saved yet.
    public func discoverDevices(platform: String, name: String?, block: JSONValue? = nil) async throws -> JSONValue {
        let name = name ?? platform
        let devices = try await host.discoverDevices(platform: platform, name: name, block: block)
        setupSessions.remember(devices, for: "\(platform)/\(name)")
        let saved = (try? readConfig())?["platforms"]?.arrayValue?.first { $0["platform"]?.stringValue == platform && ($0["name"]?.stringValue ?? platform) == name }
        let settings = AccessorySettings.all(in: block ?? saved ?? .null)
        let context = host.context(platform: platform, name: name)
        let accessories = Dictionary(context?.accessories.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        return [
            "platform": .string(platform), "name": .string(name),
            "accountAuthorization": .string(host.registry.entry(for: platform)?.accountAuthorization.rawValue ?? "none"),
            "accountSetUp": .bool(context?.haveCredentials([nil]).isEmpty == false),
            "devices": .array(devices.map { device in
                let status = settings[device.deviceID]?.excluded == true || device.excludedBySettings ? "excluded"
                    : device.isSetUp ? "setUp" : device.authorization == .none ? "discovered" : "needsAuthorization"
                var json: [String: JSONValue] = [
                    "deviceID": .string(device.deviceID), "accessoryID": .string("\(platform):\(device.deviceID)"), "name": .string(device.name),
                    "authorization": .string(device.authorization.rawValue), "status": .string(status),
                ]
                if let model = device.model { json["model"] = .string(model) }
                if device.excludedBySettings { json["excludedBySettings"] = true }
                // What kind of accessory it is on the bridge, for its glyph.
                if let accessory = accessories["\(platform):\(device.deviceID)"] { json["category"] = .string("\(accessory.category)") }
                if let address = device.address { json["address"] = .string(address) }
                return .object(json)
            }),
        ]
    }

    /// Starts the Setup of the instance's account (no `deviceID`) or of one of the devices its last discovery found, and
    /// runs its first step. `block` is the block of an instance not saved yet, which the Setup adds when done.
    public func startSetup(platform: String, name: String?, deviceID: String?, block: JSONValue? = nil, by writer: ConfigWriter = .person) async throws -> JSONValue {
        let name = name ?? platform
        guard let entry = host.registry.entry(for: platform) else { throw CatalogError("No plugin for platform \(platform)") }
        let target: SetupRequest.Target
        let method: AuthorizationMethod
        if let deviceID {
            var device = setupSessions.device(deviceID, of: "\(platform)/\(name)")
            if device == nil {
                _ = try await discoverDevices(platform: platform, name: name, block: block)
                device = setupSessions.device(deviceID, of: "\(platform)/\(name)")
            }
            guard let device else { throw CatalogError("\(entry.name) did not find the device \(deviceID); discover_devices lists those it finds") }
            target = .device(device)
            method = device.authorization
        } else {
            target = .account
            method = entry.accountAuthorization
        }
        let session = SetupSession(
            id: Secrets.randomToken(), platform: platform, name: name, draft: block, target: target, method: method,
            prompt: SetupPrompt(message: ""), state: .null, expires: Date())
        return try await step(session, answers: [:], first: true)
    }

    /// Answers the prompt of a Setup Session and runs its next step. A secret field takes a `vault:` reference from an
    /// MCP client, never the secret itself.
    public func continueSetup(_ id: String, answers: [String: JSONValue], by writer: ConfigWriter = .person) async throws -> JSONValue {
        guard let session = setupSessions.session(id) else { throw CatalogError("No Setup in progress with id \(id): it ended or expired; start_setup starts it again") }
        var texts: [String: String] = [:]
        for field in session.prompt.fields {
            guard let value = answers[field.key], let text = value.stringValue ?? (value.isNull ? nil : value.text()), !text.isEmpty else {
                guard field.optional || session.prompt.waitSeconds != nil else { return asking(session, error: "\(field.label) is missing") }
                continue
            }
            if field.kind == .secret, let reference = SecretReference(text) {
                if writer == .client, case .vault = reference {} else if writer == .client {
                    return asking(session, error: "\(field.label): only a vault: reference is accepted here")
                }
                do {
                    texts[field.key] = try SecretResolver(storage: storageDirectory).resolve(reference)
                } catch {
                    return asking(session, error: "\(field.label): \(reference) does not resolve")
                }
            } else if field.kind == .secret, writer == .client {
                return asking(session, error: "\(field.label) is a secret: pass a vault: reference (the person adds the entry on the Vault page), or finish this step in the web UI")
            } else {
                texts[field.key] = text
            }
        }
        return try await step(session, answers: texts, first: false)
    }

    /// Excludes a device of the block (GLOSSARY.md, "Excluded"), or includes it again, in its Accessory Settings: the plugin
    /// reloads and the runtime takes its accessories off the bridge, or lets the plugin add them.
    public func setExcluded(platform: String, name: String?, deviceID: String, excluded: Bool) async throws -> JSONValue {
        try await editBlock(platform: platform, name: name, create: false, dryRun: false, checkSchemas: false) { block in
            Self.editAccessorySettings(&block, deviceID: deviceID) { $0.excluded = excluded }
        }
    }

    /// Changes one device's Accessory Settings in a block's `_accessories`; a device left with none, and a block left with
    /// no device, lose their entry.
    static func editAccessorySettings(_ block: inout [String: JSONValue], deviceID: String, _ edit: (inout AccessorySettings) -> Void) {
        var all = block["_accessories"]?.objectValue ?? [:]
        var settings = AccessorySettings(json: all[deviceID] ?? [:])
        edit(&settings)
        // Removed, not set to nil: JSONValue takes the nil literal as JSON null.
        if settings.json.objectValue?.isEmpty == true { all.removeValue(forKey: deviceID) } else { all[deviceID] = settings.json }
        if all.isEmpty { block.removeValue(forKey: "_accessories") } else { block["_accessories"] = .object(all) }
    }

    @discardableResult
    public func cancelSetup(_ id: String) -> Bool { setupSessions.remove(id) }

    /// Runs one step of the plugin's Authorization: a prompt keeps the session, done saves what it gave and ends it.
    private func step(_ session: SetupSession, answers: [String: String], first: Bool) async throws -> JSONValue {
        let request = SetupRequest(target: session.target, answers: answers, state: session.state)
        let deviceID = session.deviceID
        let step: SetupStep
        do {
            step = try await host.withSetupPlugin(platform: session.platform, name: session.name, block: session.draft) { plugin, context in
                let step = try await plugin.authorize(request)
                if case .done(let outcome) = step, let credentials = outcome.credentials {
                    try context.saveCredentials(credentials, for: deviceID)
                }
                return step
            }
        } catch {
            let message = error is SetupError ? "\(error)" : Redaction.redactText("\(error)")
            if first { throw CatalogError(message) }
            return asking(session, error: message)
        }
        switch step {
        case .ask(let prompt, let state):
            var next = session
            next.prompt = prompt
            next.state = state
            setupSessions.put(next)
            return asking(next, error: nil)
        case .done(let outcome):
            setupSessions.remove(session.id)
            return try await finish(session, outcome: outcome)
        }
    }

    /// Writes what a finished Setup brings (the draft block, the account's settings, the device's Accessory Settings)
    /// and starts the plugin afresh when the write did not, so it uses the credentials now in the vault.
    private func finish(_ session: SetupSession, outcome: SetupOutcome) async throws -> JSONValue {
        let deviceID = session.deviceID
        var applied: JSONValue?
        if session.draft != nil || !outcome.settings.isEmpty {
            applied = try await editBlock(platform: session.platform, name: session.name, dryRun: false, checkSchemas: false) { block in
                for (key, value) in session.draft?.objectValue ?? [:] where key != "_accessories" { block[key] = value }
                if let deviceID {
                    Self.editAccessorySettings(&block, deviceID: deviceID) { settings in
                        settings = AccessorySettings(json: .object((settings.json.objectValue ?? [:]).merging(outcome.settings) { $1 }))
                    }
                } else {
                    block.merge(outcome.settings) { $1 }
                }
            }
        }
        let names = ((applied?["reloaded"]?.arrayValue ?? []) + (applied?["started"]?.arrayValue ?? [])).compactMap(\.stringValue)
        if !names.contains(session.name) { await host.relaunch(platform: session.platform, name: session.name) }
        logger.info("Setup done", metadata: ["platform": "\(session.platform)", "name": "\(session.name)", "device": "\(deviceID ?? "account")"])
        var answer: [String: JSONValue] = ["status": "done", "platform": .string(session.platform), "name": .string(session.name)]
        if let deviceID {
            answer["deviceID"] = .string(deviceID)
            answer["accessoryID"] = .string("\(session.platform):\(deviceID)")
        }
        return .object(answer)
    }

    private func asking(_ session: SetupSession, error: String?) -> JSONValue {
        var answer: [String: JSONValue] = [
            "status": "asking", "session": .string(session.id), "platform": .string(session.platform), "name": .string(session.name),
            "method": .string(session.method.rawValue), "prompt": (try? JSONValue(data: JSONEncoder().encode(session.prompt))) ?? .null,
        ]
        if let deviceID = session.deviceID { answer["deviceID"] = .string(deviceID) }
        if let error { answer["error"] = .string(error) }
        return .object(answer)
    }

    /// A Setup's answer for a model: what the devices and the plugin said (names, prompts, errors) is data, never instructions.
    static func untrusted(_ answer: JSONValue) -> ToolResult {
        let platform = answer["platform"]?.stringValue ?? "plugin"
        return ToolResult(text: "<untrusted-data source=\"\(platform)\">\n\(answer.text(pretty: true))\n</untrusted-data>", structured: answer)
    }

    var setupTools: [MCPTool] {
        let catalog = self
        let instance: [String: JSONValue] = [
            "platform": ["type": "string", "description": "The plugin's platform, as list_plugins gives it"],
            "name": ["type": "string", "description": "The block's name, when the platform has several"],
        ]
        return [
            MCPTool(
                name: "discover_devices", title: "Find devices",
                description: "Asks a plugin which devices it finds now (on the network, in its account, at the addresses its settings name), each with "
                    + "its deviceID, its accessoryID, the Authorization it needs (none, buttonPress, deviceCode, accountLogin, browserRedirect, apiKey) and its "
                    + "status: setUp, needsAuthorization (start_setup with its deviceID), discovered (the plugin publishes it by itself) or excluded "
                    + "(excludedBySettings: by the plugin's own settings, which get_plugin_config_schema describes). "
                    + "accountAuthorization says what the plugin's account needs (start_setup without a deviceID).",
                inputSchema: ["type": "object", "required": ["platform"], "properties": .object(instance)],
                scope: .admin, readOnly: true
            ) { call in
                Self.untrusted(try await catalog.discoverDevices(platform: try call.string("platform"), name: call.optionalString("name")))
            },
            MCPTool(
                name: "start_setup", title: "Set up a device",
                description: "Starts the Setup of a device discover_devices found (deviceID), or of the plugin's account (no deviceID), and answers its first "
                    + "prompt: a message for the person, the fields to answer with continue_setup, a page to open (browserRedirect) or a wait (buttonPress: "
                    + "tell the person to press the button, then call continue_setup every retryAfter seconds). status done means it is set up.",
                inputSchema: ["type": "object", "required": ["platform"], "properties": .object(instance.merging(["deviceID": ["type": "string"]]) { $1 })],
                scope: .admin
            ) { call in
                Self.untrusted(try await catalog.startSetup(platform: try call.string("platform"), name: call.optionalString("name"), deviceID: call.optionalString("deviceID"), by: .client))
            },
            MCPTool(
                name: "continue_setup", title: "Answer a Setup step",
                description: "Answers the prompt of a Setup in progress with its fields' values by key (a PIN, a one-time code, a redirect address). A field "
                    + "of kind secret (a password, a key) takes only a vault: reference, never the secret: ask the person to add it on the Vault page, or to "
                    + "finish in the web UI. Answers the next prompt (with error when an answer did not work), or status done.",
                inputSchema: ["type": "object", "required": ["session"], "properties": ["session": ["type": "string"], "answers": ["type": "object"]]],
                scope: .admin
            ) { call in
                Self.untrusted(try await catalog.continueSetup(try call.string("session"), answers: call.arguments["answers"]?.objectValue ?? [:], by: .client))
            },
            MCPTool(
                name: "cancel_setup", title: "Cancel a Setup",
                description: "Ends a Setup in progress without saving anything.",
                inputSchema: ["type": "object", "required": ["session"], "properties": ["session": ["type": "string"]]],
                scope: .admin, idempotent: true
            ) { call in
                catalog.cancelSetup(try call.string("session")) ? .text("Cancelled") : .text("No Setup in progress with that id")
            },
        ]
    }
}
