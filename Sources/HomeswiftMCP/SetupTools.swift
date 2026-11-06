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

    /// The Device Id what a finished step gives goes under: none for the account, the one the outcome names, else the
    /// discovered device's. Add by address has none until the plugin names it.
    func deviceID(of outcome: SetupOutcome) -> String? {
        target == .account ? nil : outcome.deviceID ?? deviceID
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
        let found = try await host.discover(platform: platform, name: name, block: block)
        setupSessions.remember(found.devices, for: "\(platform)/\(name)")
        let accessories = Dictionary(host.context(platform: platform, name: name)?.accessories.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let entry = host.registry.entry(for: platform)
        let method = entry?.accountAuthorization ?? AuthorizationMethod.none
        let requirement = entry?.accountRequirement ?? .required
        return [
            "platform": .string(platform), "name": .string(name),
            "accountAuthorization": .string(method.rawValue),
            // An instance without an account has nothing to set up for it.
            "accountSetUp": .bool(found.accountState == .none || found.accountState == .setUp),
            "accountState": .string(found.accountState.rawValue), "accountRequired": .bool(requirement.isRequired),
            "accountAdds": requirement.adds.map(JSONValue.string) ?? .null, "needsAuthorization": .bool(found.accountState.needsAuthorization(requirement)),
            "addByAddress": .bool(entry?.addsDevicesByAddress ?? false),
            "devices": .array(found.devices.map { device in
                let accessoryID = "\(platform):\(device.deviceID)"
                var json: [String: JSONValue] = [
                    "deviceID": .string(device.deviceID), "accessoryID": .string(accessoryID), "name": .string(device.name),
                    "authorization": .string(device.authorization.rawValue), "status": .string(device.status.rawValue),
                ]
                if let model = device.model { json["model"] = .string(model) }
                if let kind = device.kind { json["kind"] = .string(kind) }
                if device.excludedBySettings { json["excludedBySettings"] = true }
                if !device.parts.isEmpty { json["parts"] = (try? JSONValue(encoding: device.parts)) ?? [] }
                // What kind of accessory it is on the bridge, for its glyph.
                if let accessory = accessories[accessoryID] { json["category"] = .string("\(accessory.category)") }
                if let address = device.address { json["address"] = .string(address) }
                return .object(json)
            }),
        ]
    }

    /// Starts the Setup of the instance's account (no `deviceID`), of one of the devices its last discovery found, or Add
    /// by address (`addByAddress`, a device the person names, for a plugin whose `addsDevicesByAddress`), and runs its
    /// first step. `block` is the block of an instance not saved yet, which the Setup adds when done.
    public func startSetup(platform: String, name: String?, deviceID: String?, addByAddress: Bool = false, block: JSONValue? = nil) async throws -> JSONValue {
        let name = name ?? platform
        guard let entry = host.registry.entry(for: platform) else { throw CatalogError("No plugin for platform \(platform)") }
        let target: SetupRequest.Target
        let method: AuthorizationMethod
        if addByAddress {
            guard deviceID == nil else { throw CatalogError("Pass a deviceID or addByAddress, not both") }
            guard entry.addsDevicesByAddress else { throw CatalogError("\(entry.name) cannot add a device by its address: discover_devices lists those it finds") }
            target = .newDevice
            method = .none
        } else if let deviceID {
            var device = setupSessions.device(deviceID, of: "\(platform)/\(name)")
            if device == nil {
                let found = try await host.discover(platform: platform, name: name, block: block).devices
                setupSessions.remember(found, for: "\(platform)/\(name)")
                device = found.first { $0.deviceID == deviceID }
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
        guard let session = setupSessions.session(id) else { throw CatalogError("No Setup in progress with id \(id): it ended or expired, start it again") }
        var texts: [String: String] = [:]
        // What was answered, secrets left out: a step asked again shows it, to correct rather than type again.
        let answered = answers.compactMapValues { $0.stringValue }
        let asking = { (error: String) in self.asking(session, error: error, answers: answered) }
        for field in session.prompt.fields {
            guard let value = answers[field.key], let text = value.stringValue ?? (value.isNull ? nil : value.text()), !text.isEmpty else {
                guard field.optional || session.prompt.waitSeconds != nil else { return asking("\(field.label) is missing") }
                continue
            }
            if field.kind == .secret, let reference = SecretReference(text) {
                // A client names the bridge's own secrets only: env: and file: read what is on its machine.
                if writer == .client, !reference.isVault {
                    return asking("\(field.label): only a vault: reference is accepted here")
                }
                do {
                    texts[field.key] = try SecretResolver(storage: storageDirectory).resolve(reference)
                } catch {
                    return asking("\(field.label): \(reference) does not resolve")
                }
            } else if field.kind == .secret, writer == .client {
                return asking("\(field.label) is a secret: pass a vault: reference (the person adds the entry on the Vault page), or finish this step in the web UI")
            } else {
                texts[field.key] = text
            }
        }
        return try await step(session, answers: texts, first: false)
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

    /// Where a Setup in progress stands, its prompt as it was last answered: for the web UI to take over a Setup the
    /// Assistant started, at a step that asks for a secret, a sign-in page or a button press.
    public func setupState(_ id: String) throws -> JSONValue {
        guard let session = setupSessions.session(id) else { throw CatalogError("No Setup in progress with id \(id): it ended or expired, start it again") }
        return asking(session, error: nil)
    }

    /// Whether a Setup's answer is one the person finishes on the page rather than in a conversation: done is not, a prompt
    /// with a secret field, a sign-in page or a wait (a button to press) is.
    public static func needsThePage(_ answer: JSONValue) -> Bool {
        guard answer["status"] == "asking", let prompt = answer["prompt"] else { return false }
        let secret = prompt["fields"]?.arrayValue?.contains { $0["kind"] == "secret" } == true
        return secret || prompt["url"]?.stringValue != nil || prompt["waitSeconds"]?.intValue != nil
    }

    /// Runs one step of the plugin's Authorization: a prompt keeps the session, done saves what it gave and ends it.
    private func step(_ session: SetupSession, answers: [String: String], first: Bool) async throws -> JSONValue {
        let request = SetupRequest(target: session.target, answers: answers, state: session.state)
        let step: SetupStep
        do {
            step = try await host.withSetupPlugin(platform: session.platform, name: session.name, block: session.draft) { plugin, context in
                let step = try await plugin.authorize(request)
                if case .done(let outcome) = step {
                    // Add by address ends on the device the plugin reached: without it, nothing is saved.
                    if session.target == .newDevice, outcome.deviceID?.isEmpty != false {
                        throw SetupError("\(session.platform) did not say which device it reached")
                    }
                    if let credentials = outcome.credentials { try context.saveCredentials(credentials, for: session.deviceID(of: outcome)) }
                }
                return step
            }
        } catch {
            // The plugin's own words go as they are (start_setup wraps them as untrusted data), anything else masked.
            if first { throw error is SetupError ? error : CatalogError(Redaction.redactText("\(error)")) }
            return asking(session, error: error is SetupError ? "\(error)" : Redaction.redactText("\(error)"), answers: answers)
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
    /// and starts the plugin afresh when the write did not, so it uses the credentials now in the vault. A device added
    /// by address is included: named by the person, it is no longer Excluded.
    private func finish(_ session: SetupSession, outcome: SetupOutcome) async throws -> JSONValue {
        let deviceID = session.deviceID(of: outcome)
        let adding = session.target == .newDevice
        var applied: JSONValue?
        if session.draft != nil || !outcome.settings.isEmpty || adding {
            applied = try await editBlock(platform: session.platform, name: session.name, dryRun: false, checkSchemas: false, canonical: true) { block in
                for (key, value) in session.draft?.objectValue ?? [:] where key != "_accessories" { block[key] = value }
                if let deviceID {
                    Self.editAccessorySettings(&block, deviceID: deviceID) { settings in
                        // A null setting goes, as an account's does: a port back to its default.
                        settings = AccessorySettings(json: Self.merged(settings.json, outcome.settings) { _ in })
                        if adding { settings.excluded = false }
                    }
                } else {
                    // A null setting goes: what the Setup moved into the vault leaves the block.
                    block = Self.merged(.object(block), outcome.settings) { _ in }.objectValue ?? block
                }
            }
        }
        // An account set up again is no longer refused, whether the plugin keeps its credentials or the vault does.
        if session.target == .account { host.context(platform: session.platform, name: session.name)?.accountAccepted() }
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

    /// The session's prompt, with `error` when the last answer did not work; its fields then show what was `answers`ed,
    /// secrets left out, for the person or the client to correct.
    private func asking(_ session: SetupSession, error: String?, answers: [String: String] = [:]) -> JSONValue {
        var prompt = session.prompt
        for index in prompt.fields.indices where prompt.fields[index].kind != .secret {
            if let answer = answers[prompt.fields[index].key] { prompt.fields[index].value = answer }
        }
        var answer: [String: JSONValue] = [
            "status": "asking", "session": .string(session.id), "platform": .string(session.platform), "name": .string(session.name),
            "method": .string(session.method.rawValue), "prompt": (try? JSONValue(encoding: prompt)) ?? .null,
            "message": .string(session.prompt.text),
        ]
        if let deviceID = session.deviceID { answer["deviceID"] = .string(deviceID) }
        if session.target == .newDevice { answer["addByAddress"] = true }
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
                    + "its deviceID, its accessoryID, the Authorization it needs (none, buttonPress, deviceCode, accountLogin, browserRedirect, apiKey, bridgeSetting: a Bridge Setting such as the Location, set first) and its "
                    + "status: setUp, notResponding (set up, but the plugin cannot reach it now), needsAuthorization (start_setup with its deviceID), discovered (the plugin publishes it by itself) or excluded "
                    + "(excludedBySettings: by the plugin's own settings, which get_plugin_config_schema describes; exclude or include one with update_settings, "
                    + "its accessoryID and excluded, and leave out one of its parts with parts). kind is its Device Kind, which decides its Plugin Accessory Settings. "
                    + "accountAuthorization says what the plugin's account needs (start_setup without a deviceID); accountState where it stands (none, setUp, notSetUp, refused); "
                    + "needsAuthorization that it must be set up (again) before the devices work; accountRequired false that the devices work without it, accountAdds what it adds. "
                    + "addByAddress true: the plugin also takes a device it cannot find, by its address (start_setup with addByAddress).",
                inputSchema: ["type": "object", "required": ["platform"], "properties": .object(instance)],
                scope: .admin, readOnly: true
            ) { call in
                Self.untrusted(try await catalog.discoverDevices(platform: try call.string("platform"), name: call.optionalString("name")))
            },
            MCPTool(
                name: "start_setup", title: "Set up a device",
                description: "Starts the Setup of a device discover_devices found (deviceID), of the plugin's account (no deviceID), or of a device the "
                    + "plugin cannot find, added by its address (addByAddress true, for a plugin whose discover_devices says addByAddress: the first prompt asks "
                    + "for its host and what else it needs; done gives its deviceID and accessoryID), and answers its first "
                    + "prompt: a message for the person, the fields to answer with continue_setup, a page to open (browserRedirect) or a wait (buttonPress: "
                    + "tell the person to press the button, then call continue_setup every retryAfter seconds). status done means it is set up. A plugin not "
                    + "added yet (list_plugins: a platform with no block of that name) is added when its account's Setup, or its first device added by address, is done.",
                inputSchema: ["type": "object", "required": ["platform"], "properties": .object(instance.merging([
                    "deviceID": ["type": "string", "description": "A device discover_devices found; none for the account"],
                    "addByAddress": ["type": "boolean", "description": "Add a device the plugin cannot find, by its address (not with deviceID)"],
                ]) { $1 })],
                scope: .admin
            ) { call in
                let platform = try call.string("platform")
                // A plugin not added yet: its block, saved once its account's Setup is done.
                let blocks = (try? catalog.readConfig()["platforms"]?.arrayValue) ?? []
                let name = call.optionalString("name") ?? (blocks.contains { $0["platform"]?.stringValue == platform } ? nil : catalog.host.registry.entry(for: platform)?.name)
                let exists = blocks.contains { $0["platform"]?.stringValue == platform && ($0["name"]?.stringValue ?? platform) == (name ?? platform) }
                let draft: JSONValue? = exists ? nil : ["platform": .string(platform), "name": .string(name ?? platform)]
                // A value that is not a boolean is refused rather than taken for the account's Setup.
                if let value = call.arguments["addByAddress"], value.boolValue == nil, !value.isNull { throw CatalogError("addByAddress must be true or false") }
                do {
                    return Self.untrusted(try await catalog.startSetup(platform: platform, name: name, deviceID: call.optionalString("deviceID"), addByAddress: call.bool("addByAddress"), block: draft))
                } catch let error as SetupError {
                    // The plugin's words, which a device may choose: untrusted data, as its prompts are.
                    throw CatalogError("The Setup did not start", detail: error.description)
                }
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
