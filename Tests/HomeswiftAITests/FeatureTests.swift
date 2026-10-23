import Foundation
import Testing

@testable import HomeswiftAI

/// A clock the tests move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ iso: String) { date = ISO8601DateFormatter().date(from: iso)! }

    var now: @Sendable () -> Date { { [self] in lock.withLock { date } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// Answers each request with what `answer` makes of it, from any number of tasks at once.
final class ScriptedProvider: Provider, @unchecked Sendable {
    let name = "scripted"
    let model = "claude-haiku-5-5"
    let capabilities = ProviderCapabilities(streaming: false, contextTokens: 100_000)
    private let answer: @Sendable (ChatRequest) -> String
    /// How long it takes to answer, waited without holding a thread (a loaded CI runner has few).
    private let delay: Duration?
    private let lock = NSLock()
    private(set) var requests: [ChatRequest] = []

    init(delay: Duration? = nil, _ answer: @escaping @Sendable (ChatRequest) -> String) {
        self.delay = delay
        self.answer = answer
    }

    func chat(_ request: ChatRequest) async throws -> ChatResult {
        lock.withLock { requests.append(request) }
        if let delay { try await Task.sleep(for: delay) }
        return ChatResult(model: model, text: answer(request), toolCalls: [], usage: TokenUsage(inputTokens: 100, outputTokens: 20), stopReason: .end)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do { continuation.yield(.done(try await self.chat(request))) } catch { continuation.finish(throwing: error) }
                continuation.finish()
            }
        }
    }

    var count: Int { lock.withLock { requests.count } }
}

@Suite struct UsagePersistenceTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func keepsDaysAndMonthsAcrossLaunches() async throws {
        let clock = TestClock("2026-10-30T10:00:00Z")
        let store = MemoryUsageStore()
        let tracker = UsageTracker(store: store, timeZone: utc, now: clock.now)
        await tracker.record(model: "claude-haiku-5-5", usage: TokenUsage(inputTokens: 1000, outputTokens: 100), user: "ana")
        clock.advance(86_400)
        await tracker.record(model: "claude-haiku-5-5", usage: TokenUsage(inputTokens: 2000, outputTokens: 200), user: "bob")
        await tracker.record(model: "llama3.1", usage: TokenUsage(inputTokens: 10, outputTokens: 1))
        #expect(await tracker.today.requests == 2)
        #expect(await tracker.today.cost == nil)
        #expect(await tracker.thisMonth.usage == TokenUsage(inputTokens: 3010, outputTokens: 301))
        #expect(await tracker.byDay.keys.sorted() == ["2026-10-30", "2026-10-31"])

        // The file has upstream's snapshot shape, and a new tracker reads it back.
        let saved = try JSONValue(data: #require(try store.load()))
        #expect(saved["version"] == 1)
        #expect(saved["days"]?["2026-10-30"]?["claude-haiku-5-5"] == ["calls": 1, "inputTokens": 1000, "outputTokens": 100])
        #expect(saved["months"]?["2026-10"]?["llama3.1"]?["calls"] == 1)
        #expect(saved["users"]?["2026-10-31"]?["bob"]?["claude-haiku-5-5"]?["calls"] == 1)
        let reloaded = UsageTracker(store: store, timeZone: utc, now: clock.now)
        #expect(await reloaded.total == tracker.total)
        #expect(await reloaded.today == tracker.today)

        // A new month starts at zero; the report has the month's users.
        let report = await reloaded.report()
        #expect(report.day == "2026-10-31")
        #expect(report.monthByUser.keys.sorted() == ["ana", "bob"])
        #expect(report.todayByUser.keys.sorted() == ["bob"])
        #expect(report.json["byUser"]?["thisMonth"]?["ana"]?["requests"] == 1)
        clock.advance(86_400)
        #expect(await reloaded.thisMonth.requests == 0)
        #expect(await reloaded.total.requests == 3)
    }

    @Test func dropsOldDaysAndStartsEmptyOnABadFile() async throws {
        let clock = TestClock("2026-10-01T12:00:00Z")
        let tracker = UsageTracker(retainDays: 2, timeZone: utc, now: clock.now)
        for _ in 0..<3 {
            await tracker.record(model: "m", usage: TokenUsage(inputTokens: 1, outputTokens: 1))
            clock.advance(86_400)
        }
        #expect(await tracker.byDay.keys.sorted() == ["2026-10-02", "2026-10-03"])
        let broken = UsageTracker(store: MemoryUsageStore(Data("{not json".utf8)))
        #expect(await broken.total.requests == 0)
    }

    @Test func enforcesBudgets() async throws {
        let clock = TestClock("2026-10-30T10:00:00Z")
        let tracker = UsageTracker(budget: UsageBudget(dailyTokens: 1000), timeZone: utc, now: clock.now)
        try await tracker.checkBudget()
        await tracker.record(model: "claude-opus-5-5", usage: TokenUsage(inputTokens: 1200, outputTokens: 34))
        let error = await tracker.exceededBudget()
        #expect(error == BudgetExceededError(period: .day, unit: .tokens, used: 1234, limit: 1000))
        #expect(error?.description == "The daily AI budget is used up: 1,234 tokens of 1,000 tokens today. It resets at midnight.")
        clock.advance(86_400)
        try await tracker.checkBudget()

        // $0.0055 yesterday and $0.50 today.
        await tracker.record(model: "claude-haiku-5-5", usage: TokenUsage(inputTokens: 0, outputTokens: 1_000_000))
        await tracker.setBudget(UsageBudget(monthlyUsd: 0.25))
        #expect(await tracker.exceededBudget()?.description == "The monthly AI budget is used up: $0.51 of $0.25 this month. It resets on the 1st of next month.")
        // Unpriced models count as free against a USD budget.
        let local = UsageTracker(budget: UsageBudget(dailyUsd: 0.01), timeZone: utc, now: clock.now)
        await local.record(model: "llama3.1", usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000))
        try await local.checkBudget()
    }

    /// A used-up budget stops a request before it reaches the provider.
    @Test func assistantRefusesOverBudget() async throws {
        let provider = FakeProvider(replies: ["one", "two"])
        let assistant = AssistantService(provider: provider, usage: UsageTracker(budget: UsageBudget(dailyTokens: 10)), logger: testLogger).forUser("ana")
        _ = try await assistant.ask("hello")
        await #expect(throws: BudgetExceededError.self) { try await assistant.ask("again") }
        await #expect(throws: BudgetExceededError.self) { try await assistant.dailyDigest(DailyDigestInput()) }
        #expect(provider.requests.count == 1)
        #expect(await assistant.usage.report().todayByUser["ana"]?.requests == 1)
    }

    @Test func readsTheBudgetFromTheBlock() throws {
        let configuration = try AIConfiguration(block: ["apiKey": "k", "budget": ["dailyTokens": 50000, "monthlyUsd": 12.5, "dailyUsd": 0, "monthlyTokens": .null]], environment: [:])
        #expect(configuration.budget == UsageBudget(dailyTokens: 50000, monthlyUsd: 12.5))
        #expect(try AIConfiguration(block: ["apiKey": "k"], environment: [:]).budget.isEmpty)
        #expect(throws: AIConfigurationError.invalid(key: "budget.dailyUsd", expected: "a positive number")) {
            try AIConfiguration(block: ["budget": ["dailyUsd": -1]], environment: [:])
        }
        let properties = try JSONValue(string: AIConfiguration.schemaJSON)["schema"]?["properties"]?["budget"]?["properties"]
        #expect(properties?.objectValue?.keys.sorted() == ["dailyTokens", "dailyUsd", "monthlyTokens", "monthlyUsd"])
        // Token counts, not tokens: the settings page shows them.
        #expect(!Redaction.isSecretKey("dailyTokens"))
        #expect(!Redaction.isSecretKey("monthlyTokens"))
        #expect(Redaction.isSecretKey("token"))
    }
}

@Suite struct RateLimiterTests {
    @Test func allowsLimitPerWindowAndKey() {
        let clock = TestClock("2026-10-30T10:00:00Z")
        let limiter = SlidingWindowRateLimiter(limit: 2, window: 60, now: clock.now)
        #expect(limiter.consume("ana") == .init(allowed: true, remaining: 1, retryAfter: 0))
        clock.advance(10)
        #expect(limiter.consume("ana").remaining == 0)
        let refused = limiter.consume("ana")
        #expect(!refused.allowed)
        #expect(refused.retryAfter == 50)
        #expect(limiter.consume("bob").allowed)
        // A refused request is not counted: the first leaves the window at 60 s.
        clock.advance(50)
        #expect(limiter.peek("ana") == .init(allowed: true, remaining: 1, retryAfter: 0))
        #expect(limiter.consume("ana").allowed)
        #expect(!limiter.consume("ana").allowed)
        // Idle keys go.
        clock.advance(120)
        limiter.prune()
        #expect(limiter.count == 0)
        #expect(SlidingWindowRateLimiter.assistant().limit == 20)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct FeatureTests {
    @Test func testsTheConnection() async throws {
        let transport = FakeTransport(json: #"{"id":"msg_1","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":12,"output_tokens":2}}"#)
        let usage = UsageTracker()
        let result = await AssistantService.testConnection(block: ["provider": "anthropic", "apiKey": "sk-ant-test-key-0123456789", "enabled": false], environment: [:], transport: transport, usage: usage)
        #expect(result.ok)
        #expect(result.provider == "anthropic")
        #expect(result.model == "claude-opus-5-5")
        #expect(result.reply == "OK")
        #expect(result.latencyMs != nil)
        #expect(try transport.body()["messages"]?[0]?["content"]?.text().contains("single word OK") == true)
        #expect(await usage.total.requests == 1)

        let refused = FakeTransport([.init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key sk-ant-test-key-0123456789"}}"#)])
        let failed = await AssistantService.testConnection(block: ["apiKey": "sk-ant-test-key-0123456789", "maxRetries": 0], environment: [:], transport: refused)
        #expect(!failed.ok)
        #expect(failed.message?.contains("sk-ant-test") == false)
        #expect(failed.json["ok"] == false)

        let missingKey = await AssistantService.testConnection(block: ["provider": "openai"], environment: [:], transport: FakeTransport())
        #expect(missingKey.message?.contains("needs an API key") == true)
    }

    @Test func testTimesOut() async {
        let slow = ScriptedProvider(delay: .seconds(30)) { _ in "OK" }
        let result = await AssistantService.testConnection(provider: slow, timeout: 0.1)
        #expect(!result.ok)
        #expect(result.message?.contains("no answer within") == true)
    }

    @Test func writesTheDailyDigest() async throws {
        let provider = FakeProvider(replies: ["All good"], streaming: false)
        let assistant = AssistantService(provider: provider, logger: testLogger)
        let lines = ["[10:00] fine", "[10:01] [Govee] [WARNING] token=abc123 refused", "[10:02] Lamp failed to respond"]
        #expect(DailyDigestInput.problemLines(lines) == Array(lines.dropFirst()))
        let reply = try await assistant.dailyDigest(DailyDigestInput(
            date: "2026-10-30", status: ["version": "1.0", "password": "hunter2"], logs: DailyDigestInput.problemLines(lines),
            accessories: [["uniqueId": "ElgatoKeyLights:3C:6A:9D:18:F2:35", "name": "Lamp", "On": true]], events: [["accessory": "Lamp", "event": "unreachable"]]))
        #expect(reply.text == "All good")
        let request = try #require(provider.lastRequest)
        #expect(request.system == Prompts.DailyDigest.system)
        let user = request.messages[0].text
        #expect(user.hasPrefix("Write the Homeswift digest for 2026-10-30."))
        #expect(user.contains("## Warnings and errors from the log\n<untrusted-data>"))
        #expect(user.contains("token=__REDACTED__"))
        #expect(!user.contains("hunter2"))
        #expect(user.contains("## Accessory events"))
        #expect(!user.contains("3C:6A:9D"))
        #expect(DailyDigestInput.today(ISO8601DateFormatter().date(from: "2026-10-30T23:30:00Z")!, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-30")
    }

    @Test func suggestsOrganizationInBatchesWithAliases() async throws {
        // Puts every accessory of a batch in one room, renames the first, and makes up an id.
        let provider = ScriptedProvider { request in
            let prompt = request.messages[0].text
            let aliases = (1...20).map { "a\($0)" }.filter { prompt.contains("\"\($0)\"") }
            let list = aliases.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"rooms":[{"name":"Living Room","accessories":[\#(list),"a99"]}],"renames":[{"uniqueId":"\#(aliases[0])","name":"Better","reason":"clearer"}],"orphans":[{"uniqueId":"a99","reason":"made up"}]}"#
        }
        let assistant = AssistantService(provider: provider, maxOutputTokens: 400, logger: testLogger)
        #expect(AssistantService.organizationBatchSize(maxOutputTokens: 400) == 5)
        let accessories: [JSONValue] = (1...7).map { ["uniqueId": .string("ElgatoKeyLights:AA:BB:\($0)"), "name": .string("Light \($0)")] }
        let progress = ProgressRecorder()
        let suggestion = try await assistant.suggestOrganization(accessories: accessories) { done, total in progress.add(done, total) }
        #expect(provider.count == 2)
        #expect(suggestion.rooms.count == 1)
        #expect(Set(suggestion.rooms[0].accessories) == Set((1...7).map { "ElgatoKeyLights:AA:BB:\($0)" }))
        #expect(suggestion.renames.count == 2)
        #expect(suggestion.renames.allSatisfy { $0.uniqueId.hasPrefix("ElgatoKeyLights:") })
        #expect(suggestion.orphans.isEmpty)
        #expect(suggestion.usage == TokenUsage(inputTokens: 200, outputTokens: 40))
        #expect(progress.last?.0 == 2 && progress.last?.1 == 2)
        #expect(await assistant.usage.total.requests == 2)
        // The model sees aliases, never the ids (MAC addresses here).
        for request in provider.requests {
            #expect(!request.messages[0].text.contains("AA:BB"))
            #expect(request.messages[0].text.contains("<untrusted-data>"))
            #expect(request.system?.contains("JSON Schema") == true)
        }
        #expect(suggestion.json["renames"]?[0]?["uniqueId"]?.stringValue?.hasPrefix("ElgatoKeyLights:") == true)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int, Int)] = []
    func add(_ done: Int, _ total: Int) { lock.withLock { calls.append((done, total)) } }
    var last: (Int, Int)? { lock.withLock { calls.last } }
}
