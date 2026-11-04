import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging

// The Assistant's surface over the bridge, for the web UI's panels and the MCP server alike: its usage and
// budgets, a connection test, the daily digest (cached for the day, as Glass UI's widget keeps it), and the
// log's download and truncation (Glass UI's log module).

extension HomeswiftCatalog {
    /// Where today's digest is kept, next to `ai-usage.json`.
    public static let digestFileName = "ai-digest.json"

    var digestURL: URL { host.storageDirectory.appendingPathComponent(Self.digestFileName) }

    // MARK: Usage

    /// The Assistant's usage report (`UsageReport.json`: today, this month, budgets, by model, by user), with its
    /// provider and model. Without a working Assistant, the counts kept in `ai-usage.json` and the block's budget.
    public func assistantUsageJSON() async -> JSONValue {
        if let assistant = host.assistant {
            return ["enabled": true, "provider": .string(assistant.providerName), "model": .string(assistant.model), "usage": await assistant.usage.report().json]
        }
        let store = FileUsageStore(url: host.storageDirectory.appendingPathComponent(UsageTracker.fileName), write: { _, _ in })
        let tracker = UsageTracker(budget: host.aiConfiguration?.budget ?? UsageBudget(), store: store)
        return ["enabled": false, "usage": await tracker.report().json]
    }

    // MARK: Connection test

    /// Sends a one-word request with a `HomeswiftAiKit` block (the settings form's, saved or not; the saved one
    /// when nil) and answers `ConnectionTestResult.json`. `__REDACTED__` values come from the saved block. The
    /// request counts in the Assistant's usage, for `user`.
    ///
    /// A key the bridge supplies (`__REDACTED__`, a sealed value, a reference) goes only to the saved block's provider
    /// and address: a form that points elsewhere tests with a key typed into it, or the bridge would send its secrets
    /// wherever the form says.
    public func testAssistantConnection(block: JSONValue?, user: String?) async -> JSONValue {
        let tested: AssistantRequestBlock
        switch assistantBlock(block) {
        case .success(let block): tested = block
        case .failure(let problem): return ConnectionTestResult(ok: false, message: problem.description).json
        }
        let result = await AssistantService.testConnection(
            block: tested.block, environment: tested.environment, transport: host.aiTransport, usage: host.assistant?.usage, user: user)
        logger.info("Assistant connection test", metadata: ["ok": "\(result.ok)", "provider": "\(result.provider ?? "?")", "model": "\(result.model ?? "?")"])
        return result.json
    }

    /// A problem with the block a request to the provider would be made with, in words.
    struct AssistantBlockProblem: Error, CustomStringConvertible { var description: String }

    /// The block a request to the provider is made with, and the environment its configuration reads a key from
    /// when the block has none (`ANTHROPIC_API_KEY` and the like).
    struct AssistantRequestBlock {
        var block: JSONValue
        var environment: [String: String]
    }

    /// The `HomeswiftAiKit` block a request to the provider goes with (the form's, saved or not; the saved one when nil),
    /// its keys as they are sent: `__REDACTED__` from the saved block, a sealed key or a reference opened. A key the
    /// bridge supplies goes only to the saved block's provider and address: the placeholder, a sealed value, a
    /// reference, or the key in the bridge's environment that a block without one falls back to. And the form brings
    /// no sealed value or reference of its own (a `file:` or `env:` the saved block does not have, another vault
    /// entry): those are the saved block's, at the same place.
    func assistantBlock(
        _ block: JSONValue?, purpose: String = "test", environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<AssistantRequestBlock, AssistantBlockProblem> {
        let saved = ((try? readConfig())?["platforms"]?.arrayValue ?? []).first { $0["platform"]?.stringValue == AIConfiguration.platform }
        guard var tested = block ?? saved else {
            return .failure(AssistantBlockProblem(description: "There is no HomeswiftAiKit block: choose a provider first."))
        }
        let sameService = tested["provider"] == saved?["provider"] && tested["baseUrl"] == saved?["baseUrl"]
        if !sameService, Self.holdsSuppliedSecret(tested) {
            return .failure(AssistantBlockProblem(description: "Type the API key to \(purpose) another provider or address: a saved key goes only to the saved one."))
        }
        if let foreign = Self.foreignSuppliedSecret(tested, saved: saved) {
            return .failure(AssistantBlockProblem(description: "\(foreign) is not the saved block's: type the API key, or keep the saved one."))
        }
        if let saved, Redaction.containsRedacted(tested) { tested = (try? Redaction.restoreSecrets(tested, from: saved)) ?? tested }
        // A sealed key or a reference (`vault:`, `env:`) is sent as the key it stands for.
        do {
            let opened = try ConfigurationSecrets.opening(block: tested, storage: storageDirectory)
            return .success(AssistantRequestBlock(block: opened, environment: sameService ? environment : [:]))
        } catch {
            return .failure(AssistantBlockProblem(description: "\(error)"))
        }
    }

    /// The models the block's provider offers (the settings form's block, saved or not; the saved one when nil), for the
    /// Model menu: `{ models: [{ id, name }], default }`, or `{ models: [], default, error }` when the provider cannot
    /// be asked. Its key goes as the connection test's does.
    public func assistantModels(block: JSONValue?) async -> JSONValue {
        let provider = (block?["provider"]?.stringValue).flatMap(AIConfiguration.ProviderKind.init(rawValue:)) ?? .anthropic
        var answer: [String: JSONValue] = ["default": .string(provider.defaultModel), "models": []]
        do {
            let listed = try assistantBlock(block, purpose: "list the models of").get()
            let models = try await AIConfiguration(block: listed.block, environment: listed.environment).listModels(transport: host.aiTransport)
            answer["models"] = .array(models.map(\.json))
        } catch {
            answer["error"] = .string(Redaction.redactText("\(error)"))
        }
        return .object(answer)
    }

    /// The path of the first secret-named value of `block` that is a sealed value or a reference the saved block does
    /// not have at the same place: a client naming a secret of the bridge's it was never shown. nil when there is none.
    static func foreignSuppliedSecret(_ block: JSONValue, saved: JSONValue?) -> String? {
        var foreign: String?
        SecretWalk.forEach(block) { path, _, value in
            guard foreign == nil, let text = value.stringValue, SecretBox.isSealed(text) || Redaction.isSecretReference(text) else { return }
            if let saved, SecretWalk.value(at: path, in: saved) == value { return }
            foreign = SecretWalk.text(path)
        }
        if foreign == nil, let saved, Self.sealedValues(block).subtracting(Self.sealedValues(saved)).isEmpty == false { foreign = "A sealed value" }
        else if foreign == nil, saved == nil, !Self.sealedValues(block).isEmpty { foreign = "A sealed value" }
        return foreign
    }

    /// Every sealed string of `value`, under any key: the bridge opens them all, not only those under secret-named keys.
    static func sealedValues(_ value: JSONValue) -> Set<String> {
        switch value {
        case .string(let text): SecretBox.isSealed(text) ? [text] : []
        case .array(let items): items.reduce(into: []) { $0.formUnion(sealedValues($1)) }
        case .object(let object): object.values.reduce(into: []) { $0.formUnion(sealedValues($1)) }
        default: []
        }
    }

    /// Whether a secret-named value of `block` is one the bridge fills in: the placeholder, a sealed value or a reference.
    static func holdsSuppliedSecret(_ block: JSONValue) -> Bool {
        var supplied = false
        SecretWalk.forEach(block) { _, _, value in
            guard let text = value.stringValue else { return }
            if text == Redaction.placeholder || SecretBox.isSealed(text) || Redaction.isSecretReference(text) { supplied = true }
        }
        return supplied || !sealedValues(block).isEmpty
    }

    // MARK: Daily digest

    /// What the digest is written from: the status, the warnings and errors of the last `hours` (the latest 150, as
    /// Glass UI picks them, through `safe`: a confirmation code is a warning line, and the digest goes back to
    /// clients), the accessories with their values, and the vault's problems (`vaultHealth`) in the status.
    public func digestInput(hours: Double = 24, now: Date = Date()) -> DailyDigestInput {
        let lines = logs.lines(from: now.addingTimeInterval(-hours * 3600), to: now, limit: 20_000).map(\.formatted)
        var status = statusJSON().objectValue ?? [:]
        let vault = vaultHealth(now: now)
        if !vault.problems.isEmpty { status["vault"] = vault.json }
        return DailyDigestInput(
            date: DailyDigestInput.today(now), status: .object(status),
            logs: DailyDigestInput.problemLines(lines).suffix(150).map(Self.safe),
            accessories: .array(located().map { Self.accessoryJSON($0, detailed: false) }))
    }

    /// Today's digest when one was written today by the Assistant's current provider and model, in `language` (a BCP 47
    /// tag; nil for the Assistant's own choice): `text`, `generatedAt`, `date`, `model`, `cached`. nil otherwise.
    public func cachedDigest(language: String? = nil, now: Date = Date()) -> JSONValue? {
        guard let assistant = host.assistant, let data = try? Data(contentsOf: digestURL), let kept = try? JSONValue(data: data),
              kept["date"]?.stringValue == DailyDigestInput.today(now), kept["provider"]?.stringValue == assistant.providerName,
              kept["model"]?.stringValue == assistant.model, kept["text"]?.stringValue != nil,
              kept["language"]?.stringValue == Prompts.answerLanguage(language).flatMap({ _ in Self.primaryLanguage(language) }) else { return nil }
        var object = kept.objectValue ?? [:]
        object["cached"] = true
        return .object(object)
    }

    /// Writes today's digest (`AssistantService.dailyDigest`) and keeps it for the day, owner-only. `onChunk`
    /// streams the text, in `language` (a BCP 47 tag). Throws when the Assistant is off, over budget, or the provider fails.
    public func writeDigest(user: String?, language: String? = nil, onChunk: (@Sendable (String) -> Void)? = nil) async throws -> JSONValue {
        guard let assistant = host.assistant?.forUser(user).speaking(language) else { throw CatalogError("The Assistant is off: add a HomeswiftAiKit block") }
        let input = digestInput()
        let reply = try await assistant.dailyDigest(input, onChunk: onChunk)
        let kept: JSONValue = [
            "date": .string(input.date ?? DailyDigestInput.today()), "provider": .string(assistant.providerName), "model": .string(assistant.model),
            "text": .string(reply.text), "generatedAt": .string(Timestamp.iso8601(Date())),
            "language": Prompts.answerLanguage(language).flatMap { _ in Self.primaryLanguage(language) }.map(JSONValue.string) ?? .null,
        ]
        do {
            try OwnerOnlyFile.write(kept.encoded(pretty: true), to: digestURL)
        } catch {
            logger.warning("Could not keep the daily digest", metadata: ["error": "\(error)"])
        }
        var object = kept.objectValue ?? [:]
        object["cached"] = false
        return .object(object)
    }

    /// "fr" for "fr-FR".
    static func primaryLanguage(_ tag: String?) -> String? {
        tag?.lowercased().split(separator: "-").first.map(String.init)
    }

    // MARK: The log

    /// The log from `from` to `to` (everything kept when nil) as text, a formatted line each, oldest first: the
    /// archive on disk when there is one, else the lines in memory. For the Logs page's download.
    public func logText(from: Date? = nil, to: Date? = nil) -> String {
        logs.lines(from: from ?? .distantPast, to: to ?? Date(), limit: Int.max).map(\.formatted).joined(separator: "\n")
    }

    /// Empties the log, in memory and on disk, then says so in it (who, and how many lines went).
    public func truncateLogs(by who: String) -> JSONValue {
        let count = logs.all.count
        logs.clear()
        logger.warning("Log truncated", metadata: ["by": "\(who)"])
        return ["truncated": true, "linesInMemory": .number(Double(count))]
    }

    // MARK: Tools

    var assistantTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "get_assistant_usage", title: "Assistant usage",
                description: "The bridge's Assistant (its HomeswiftAiKit block): requests, tokens and cost today, this month and in total, by model and by user, and the daily and monthly budgets with whether one is used up.",
                scope: .read, idempotent: true
            ) { _ in .json(await catalog.assistantUsageJSON()) },
            MCPTool(
                name: "test_assistant_connection", title: "Test the Assistant's connection",
                description: "Sends a one-word request with the saved HomeswiftAiKit block to check its provider, key and model: ok, the model, the latency, or why it failed. It counts as one request.",
                scope: .admin
            ) { call in .json(await catalog.testAssistantConnection(block: nil, user: call.session.principal.name)) },
            MCPTool(
                name: "get_daily_digest", title: "Daily digest",
                description: "The bridge Assistant's digest of the last day (status, warnings and errors in the log, accessories), under 200 words, what needs attention first. "
                    + "Written once a day and kept; refresh: true writes it again (a control or admin token).",
                inputSchema: ["type": "object", "properties": ["refresh": ["type": "boolean"]]],
                scope: .read
            ) { call in
                guard catalog.host.assistant != nil else { return .error("The Assistant is off: add a HomeswiftAiKit block") }
                let refresh = call.bool("refresh")
                if refresh, call.session.principal.scope < .control || call.session.principal.hides(HomeswiftCatalog.digestRefresh) {
                    return .error("refresh needs a control or admin token, of an administrator for an app signed in through the web UI")
                }
                var digest: JSONValue
                if !refresh, let cached = catalog.cachedDigest() { digest = cached } else { digest = try await catalog.writeDigest(user: call.session.principal.name) }
                // Written from log lines and device names: data for the client, never instructions; the structured copy
                // through `safe` too, which the text gets.
                let text = Self.safe(digest["text"]?.stringValue ?? "")
                if var object = digest.objectValue {
                    object["text"] = .string(text)
                    digest = .object(object)
                }
                return ToolResult(text: "<untrusted-data source=\"digest\">\n\(text)\n</untrusted-data>", structured: digest)
            },
            MCPTool(
                name: "truncate_logs", title: "Empty the log",
                description: "Empties homeswift's log: the lines in memory and the files kept under logs/ (up to a week). The Logs page and the log tools start again from the next line. Cannot be undone.",
                scope: .admin, destructive: true
            ) { call in .json(catalog.truncateLogs(by: "MCP principal \(call.session.principal.name)")) },
        ]
    }
}
