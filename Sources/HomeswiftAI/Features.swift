import Foundation

// homebridge-ai-kit's other features: the connection test, the daily digest and the organiser. Their inputs are
// plain values (log lines, JSON), so the web UI, the MCP server and the command line feed them alike.

// MARK: - Connection test

/// What a connection test found: the provider, model and key work (with the latency), or why not.
public struct ConnectionTestResult: Sendable, Hashable {
    public var ok: Bool
    public var provider: String?
    /// The model that answered.
    public var model: String?
    /// Milliseconds from the request to the answer.
    public var latencyMs: Int?
    /// The start of the answer.
    public var reply: String?
    /// Why it failed, redacted.
    public var message: String?

    public init(ok: Bool, provider: String? = nil, model: String? = nil, latencyMs: Int? = nil, reply: String? = nil, message: String? = nil) {
        self.ok = ok
        self.provider = provider
        self.model = model
        self.latencyMs = latencyMs
        self.reply = reply
        self.message = message
    }

    /// upstream's `ConnectionTest`: `ok`, then `provider`, `model`, `latencyMs`, `reply` or `message`.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["ok": .bool(ok)]
        if let provider { object["provider"] = .string(provider) }
        if let model { object["model"] = .string(model) }
        if let latencyMs { object["latencyMs"] = .number(Double(latencyMs)) }
        if let reply { object["reply"] = .string(reply) }
        if let message { object["message"] = .string(message) }
        return .object(object)
    }
}

extension AssistantService {
    /// Sends a one-word request with a `HomeswiftAiKit` block, saved or not (the settings form's), to check
    /// that its provider, key and model work: homebridge-ai-kit's `testAiConnection`. The block's `enabled`
    /// is ignored. Never throws; gives up after `timeout` seconds. With `usage`, the request is counted.
    public static func testConnection(
        block: JSONValue, environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = URLSessionTransport(), timeout: TimeInterval = 30, usage: UsageTracker? = nil, user: String? = nil
    ) async -> ConnectionTestResult {
        do {
            let configuration = try AIConfiguration(block: block, environment: environment)
            return await testConnection(provider: try configuration.makeProvider(transport: transport), timeout: timeout, usage: usage, user: user)
        } catch {
            return ConnectionTestResult(ok: false, message: Redaction.redactText("\(error)"))
        }
    }

    /// The same test on a provider already made.
    public static func testConnection(provider: any Provider, timeout: TimeInterval = 30, usage: UsageTracker? = nil, user: String? = nil) async -> ConnectionTestResult {
        let started = ContinuousClock.now
        do {
            let result = try await withThrowingTaskGroup(of: ChatResult.self) { group in
                group.addTask {
                    try await provider.chat(ChatRequest(messages: [.user(Prompts.connectionTest)], maxOutputTokens: 256))
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw ProviderError(provider: provider.name, message: "no answer within \(Int(timeout)) seconds")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
            let elapsed = ContinuousClock.now - started
            await usage?.record(model: result.model, usage: result.usage, user: user)
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return ConnectionTestResult(
                ok: true, provider: provider.name, model: result.model.isEmpty ? provider.model : result.model, latencyMs: milliseconds,
                reply: String(result.text.prefix(200)))
        } catch {
            // The message comes from the provider: make sure no key slipped in.
            return ConnectionTestResult(ok: false, provider: provider.name, model: provider.model, message: Redaction.redactText("\(error)"))
        }
    }
}

// MARK: - Daily digest

/// What the daily digest is written from. Each part is optional; the web UI and the MCP server collect them.
public struct DailyDigestInput: Sendable {
    /// The day, `yyyy-MM-dd`; today (local time) when nil.
    public var date: String?
    /// The bridge's status: version, uptime, bridges, plugins.
    public var status: JSONValue?
    /// Log lines of the last day; `problemLines` keeps the warnings and errors.
    public var logs: [String]
    /// Accessories with their states.
    public var accessories: JSONValue?
    /// What happened to accessories during the day (changes, unreachable devices).
    public var events: JSONValue?

    public init(date: String? = nil, status: JSONValue? = nil, logs: [String] = [], accessories: JSONValue? = nil, events: JSONValue? = nil) {
        self.date = date
        self.status = status
        self.logs = logs
        self.accessories = accessories
        self.events = events
    }

    private static let problem = try! NSRegularExpression(pattern: #"\b(?:warn(?:ing)?|error|err!|exception|fail(?:ed|ure)?|unhandled|crash(?:ed)?)\b"#, options: [.caseInsensitive])

    /// The lines that report a problem (warnings, errors, failures, crashes), as Glass UI picks them for its digest.
    public static func problemLines(_ lines: [String]) -> [String] {
        lines.filter { problem.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    /// Today as `yyyy-MM-dd`, local time.
    public static func today(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension AssistantService {
    /// A short digest of the last day: what needs attention first, then what is fine (homebridge-ai-kit's
    /// `dailyDigest`). Every part is redacted and trimmed to the provider's context, and its network addresses
    /// stay home (`<IP>`, `<MAC>`, as for `explain`: accessory ids often hold a MAC address).
    public func dailyDigest(_ input: DailyDigestInput, onChunk: (@Sendable (String) -> Void)? = nil) async throws -> AssistantReply {
        let cap = budget(16_000)
        let logs = input.logs.isEmpty ? nil : Tokens.trim(Redaction.redactText(Redaction.scrubAddresses(ANSI.strip(input.logs.joined(separator: "\n")))), to: cap / 2)
        let user = Prompts.DailyDigest.user(
            date: input.date ?? DailyDigestInput.today(),
            status: input.status.map { boundedJSON(Redaction.scrubAddresses($0), cap / 8) },
            logs: logs,
            accessories: input.accessories.map { boundedJSON(Redaction.scrubAddresses($0), cap / 4) },
            events: input.events.map { boundedJSON(Redaction.scrubAddresses($0), cap / 8) })
        return try await reply(system: Prompts.DailyDigest.system, messages: [.user(user)], onChunk: onChunk)
    }
}

// MARK: - Organiser

/// Rooms, clearer names and orphans for a list of accessories, in the accessories' own ids.
public struct OrganizationSuggestion: Sendable, Hashable {
    public struct Room: Sendable, Hashable {
        public var name: String
        public var accessories: [String]
    }

    public struct Rename: Sendable, Hashable {
        public var uniqueId: String
        public var name: String
        public var reason: String?
    }

    public struct Orphan: Sendable, Hashable {
        public var uniqueId: String
        public var reason: String
    }

    public var rooms: [Room]
    public var renames: [Rename]
    public var orphans: [Orphan]
    public var usage: TokenUsage

    /// upstream's shape: `rooms`, `renames`, `orphans` with `uniqueId`s, and the usage.
    public var json: JSONValue {
        [
            "rooms": .array(rooms.map { ["name": .string($0.name), "accessories": .array($0.accessories.map(JSONValue.string))] }),
            "renames": .array(renames.map { rename in
                var object: [String: JSONValue] = ["uniqueId": .string(rename.uniqueId), "name": .string(rename.name)]
                if let reason = rename.reason { object["reason"] = .string(reason) }
                return .object(object)
            }),
            "orphans": .array(orphans.map { ["uniqueId": .string($0.uniqueId), "reason": .string($0.reason)] }),
            "usage": ["inputTokens": .number(Double(usage.inputTokens)), "outputTokens": .number(Double(usage.outputTokens))],
        ]
    }
}

extension AssistantService {
    static let organizationSchema: JSONValue = [
        "type": "object",
        "required": ["rooms", "renames", "orphans"],
        "properties": [
            "rooms": ["type": "array", "items": [
                "type": "object", "required": ["name", "accessories"],
                "properties": ["name": ["type": "string"], "accessories": ["type": "array", "items": ["type": "string"]]],
            ]],
            "renames": ["type": "array", "items": [
                "type": "object", "required": ["uniqueId", "name"],
                "properties": ["uniqueId": ["type": "string"], "name": ["type": "string"], "reason": ["type": "string"]],
            ]],
            "orphans": ["type": "array", "items": [
                "type": "object", "required": ["uniqueId", "reason"],
                "properties": ["uniqueId": ["type": "string"], "reason": ["type": "string"]],
            ]],
        ],
    ]

    /// Output tokens one accessory can take in the reply (a room entry, a rename with a short reason).
    static let tokensPerAccessory = 60
    /// Organiser requests in flight at once.
    static let organizationConcurrency = 3

    /// Accessories per request, so each reply fits the output limit (a large home in one request ran past it).
    public static func organizationBatchSize(maxOutputTokens: Int) -> Int {
        max(5, Int(Double(maxOutputTokens) * 0.75) / tokensPerAccessory)
    }

    /// Suggests rooms, clearer names and orphans (homebridge-ai-kit's `suggestOrganization`). `accessories` are
    /// JSON objects identified by `uniqueId` (or `id`): name, category, manufacturer, model, services, room.
    /// The ids reach the model as short aliases (`a1`, `a2`…) and come back as the originals; ids the model
    /// invents are dropped. Large lists go in batches, three at a time; `onProgress` gets (done, total).
    /// Each reply is schema-checked JSON (`JSONGeneration`), repaired once.
    public func suggestOrganization(
        accessories: [JSONValue], rooms: JSONValue? = nil, onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> OrganizationSuggestion {
        let cap = budget(32_000)
        var byAlias: [String: String] = [:]
        let items: [JSONValue] = accessories.map { accessory in
            guard var object = accessory.objectValue, let id = (object["uniqueId"] ?? object["id"])?.stringValue else { return accessory }
            let alias = "a\(byAlias.count + 1)"
            byAlias[alias] = id
            object["id"] = nil
            object["uniqueId"] = .string(alias)
            return .object(object)
        }
        // With ids, only the aliases handed out count; without any, keep what the model says.
        let resolve: (String) -> String? = { alias in byAlias.isEmpty ? alias : byAlias[alias] }
        let size = Self.organizationBatchSize(maxOutputTokens: maxOutputTokens)
        let batches = items.isEmpty ? [[]] : stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
        let currentRooms = rooms.map { boundedJSON($0, cap / 4) }
        let instructions = system(Prompts.SuggestOrganization.system)

        var replies = [JSONGenerationResult?](repeating: nil, count: batches.count)
        var done = 0
        onProgress?(0, batches.count)
        for start in stride(from: 0, to: batches.count, by: Self.organizationConcurrency) {
            try await usage.checkBudget()
            let group = Array(start..<min(start + Self.organizationConcurrency, batches.count))
            try await withThrowingTaskGroup(of: (Int, JSONGenerationResult).self) { tasks in
                for index in group {
                    let prompt = Prompts.SuggestOrganization.user(accessories: boundedJSON(.array(batches[index]), cap * 3 / 4), rooms: currentRooms)
                    tasks.addTask { [provider, maxOutputTokens] in
                        (index, try await JSONGeneration.generate(
                            provider: provider, schema: Self.organizationSchema, prompt: prompt, system: instructions, maxOutputTokens: maxOutputTokens))
                    }
                }
                for try await (index, result) in tasks {
                    replies[index] = result
                    await record(model: provider.model, usage: result.usage)
                    done += 1
                    onProgress?(done, batches.count)
                }
            }
        }

        var roomOrder: [String] = []
        var roomMembers: [String: [String]] = [:]
        var suggestion = OrganizationSuggestion(rooms: [], renames: [], orphans: [], usage: .zero)
        for reply in replies.compactMap({ $0 }) {
            suggestion.usage += reply.usage
            for room in reply.data["rooms"]?.arrayValue ?? [] {
                guard let name = room["name"]?.stringValue else { continue }
                if roomMembers[name] == nil { roomOrder.append(name) }
                roomMembers[name, default: []] += (room["accessories"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(resolve) }
            }
            for rename in reply.data["renames"]?.arrayValue ?? [] {
                guard let id = rename["uniqueId"]?.stringValue.flatMap(resolve), let name = rename["name"]?.stringValue else { continue }
                suggestion.renames.append(.init(uniqueId: id, name: name, reason: rename["reason"]?.stringValue))
            }
            for orphan in reply.data["orphans"]?.arrayValue ?? [] {
                guard let id = orphan["uniqueId"]?.stringValue.flatMap(resolve), let reason = orphan["reason"]?.stringValue else { continue }
                suggestion.orphans.append(.init(uniqueId: id, reason: reason))
            }
        }
        suggestion.rooms = roomOrder.map { OrganizationSuggestion.Room(name: $0, accessories: roomMembers[$0] ?? []) }
        return suggestion
    }
}

// MARK: - Moods

extension AssistantService {
    /// The shape of a mood (Homeswift's `Mood`): steps of colours for a room's lights, played once or looped.
    public static let moodSchema: JSONValue = {
        let color: JSONValue = [
            "type": "object", "additionalProperties": false,
            "properties": [
                "on": ["type": "boolean"], "brightness": ["type": "number", "minimum": 0, "maximum": 100],
                "hue": ["type": "number", "minimum": 0, "maximum": 360], "saturation": ["type": "number", "minimum": 0, "maximum": 100],
                "colorTemperature": ["type": "number", "minimum": 140, "maximum": 500],
            ],
        ]
        return [
            "type": "object", "required": ["name", "steps"],
            "properties": [
                "name": ["type": "string", "minLength": 1, "maxLength": 64],
                "steps": ["type": "array", "minItems": 1, "maxItems": 60, "items": [
                    "type": "object", "required": ["colors", "seconds"],
                    "properties": [
                        "colors": ["type": "array", "minItems": 1, "maxItems": 12, "items": color],
                        "assign": ["type": "string", "enum": ["spread", "random"]],
                        "seconds": ["type": "number", "minimum": 0.5, "maximum": 3600],
                        "jitter": ["type": "number", "minimum": 0, "maximum": 50],
                    ],
                ]],
                "loop": ["type": "boolean"],
                "durationSeconds": ["type": "number", "minimum": 1, "maximum": 3600],
                "restore": ["type": "boolean"],
            ],
        ]
    }()

    /// Writes a mood from what the user describes. `lights` says how many lights there are and which take colours
    /// or whites (no names: nothing about the home but its lights' abilities reaches the provider).
    public func designMood(_ description: String, lights: JSONValue) async throws -> JSONGenerationResult {
        try await usage.checkBudget()
        let result = try await JSONGeneration.generate(
            provider: provider, schema: Self.moodSchema, prompt: Prompts.DesignMood.user(description: description, lights: lights),
            system: system(Prompts.DesignMood.system), maxOutputTokens: maxOutputTokens)
        await record(model: provider.model, usage: result.usage)
        return result
    }
}
