import Foundation
import Logging

/// USD per million tokens; `cacheRead` and `cacheWrite` default to `input` when absent.
public struct ModelPrice: Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public enum Pricing {
    /// Claude list prices. Other providers' models are not priced; their cost is nil.
    public static let modelPrices: [String: ModelPrice] = [
        "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5),
        "claude-opus-5": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-haiku-5-5": ModelPrice(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
    ]

    public static func price(of model: String) -> ModelPrice? {
        if let price = modelPrices[model] { return price }
        // Dated or suffixed ids: the longest known prefix.
        return modelPrices.filter { model.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }

    /// The cost of `usage` on `model` in USD, or nil for a model without a known price.
    public static func cost(of model: String, usage: TokenUsage) -> Double? {
        guard let price = price(of: model) else { return nil }
        let read = Double(usage.cacheReadTokens ?? 0)
        let write = Double(usage.cacheWriteTokens ?? 0)
        let uncached = max(0, Double(usage.inputTokens) - read - write)
        let input = uncached * price.input + read * (price.cacheRead ?? price.input) + write * (price.cacheWrite ?? price.input)
        return (input + Double(usage.outputTokens) * price.output) / 1_000_000
    }
}


/// Spending limits: a request fails fast once one is used up. The keys are homebridge-ai-kit's `UsageBudget`
/// and the `budget` object of the HomeswiftAiKit block. Days and months are local time.
public struct UsageBudget: Sendable, Hashable, Codable {
    /// Input plus output tokens per day.
    public var dailyTokens: Int?
    /// Input plus output tokens per month.
    public var monthlyTokens: Int?
    /// USD per day. Requests on models without a known price count as 0.
    public var dailyUsd: Double?
    /// USD per month. Requests on models without a known price count as 0.
    public var monthlyUsd: Double?

    public init(dailyTokens: Int? = nil, monthlyTokens: Int? = nil, dailyUsd: Double? = nil, monthlyUsd: Double? = nil) {
        self.dailyTokens = dailyTokens
        self.monthlyTokens = monthlyTokens
        self.dailyUsd = dailyUsd
        self.monthlyUsd = monthlyUsd
    }

    /// Reads a `budget` object. A missing, null or 0 limit is no limit; a negative or non-numeric one throws.
    public init(json: JSONValue?) throws {
        self.init()
        guard let json, !json.isNull else { return }
        guard let object = json.objectValue else { throw AIConfigurationError.invalid(key: "budget", expected: "an object") }
        func limit(_ key: String) throws -> Double? {
            guard let value = object[key], !value.isNull else { return nil }
            guard let number = value.doubleValue ?? value.stringValue.flatMap(Double.init), number.isFinite, number >= 0 else {
                throw AIConfigurationError.invalid(key: "budget.\(key)", expected: "a positive number")
            }
            return number > 0 ? number : nil
        }
        dailyTokens = try limit("dailyTokens").map { Int($0.rounded(.up)) }
        monthlyTokens = try limit("monthlyTokens").map { Int($0.rounded(.up)) }
        dailyUsd = try limit("dailyUsd")
        monthlyUsd = try limit("monthlyUsd")
    }

    public var isEmpty: Bool { self == UsageBudget() }

    /// Every key, null for no limit.
    public var json: JSONValue {
        [
            "dailyTokens": dailyTokens.map { .number(Double($0)) } ?? .null,
            "monthlyTokens": monthlyTokens.map { .number(Double($0)) } ?? .null,
            "dailyUsd": dailyUsd.map(JSONValue.number) ?? .null,
            "monthlyUsd": monthlyUsd.map(JSONValue.number) ?? .null,
        ]
    }
}

/// Thrown before a request once a budget is used up (`UsageTracker.checkBudget`): the request never reaches
/// the provider. The web UI answers it with 429.
public struct BudgetExceededError: Error, CustomStringConvertible, Sendable, Hashable {
    public enum Period: String, Sendable { case day, month }
    public enum Unit: String, Sendable { case tokens, usd }

    public let period: Period
    public let unit: Unit
    public let used: Double
    public let limit: Double

    public init(period: Period, unit: Unit, used: Double, limit: Double) {
        self.period = period
        self.unit = unit
        self.used = used
        self.limit = limit
    }

    /// homebridge-ai-kit's message: `The daily AI budget is used up: $1.02 of $1.00 today. It resets at midnight.`
    public var description: String {
        func amount(_ value: Double) -> String {
            unit == .usd ? String(format: "$%.2f", value) : "\(Self.grouped(Int(value.rounded()))) tokens"
        }
        let when = period == .day ? "today" : "this month"
        let resets = period == .day ? "at midnight" : "on the 1st of next month"
        return "The \(period == .day ? "daily" : "monthly") AI budget is used up: \(amount(used)) of \(amount(limit)) \(when). It resets \(resets)."
    }

    /// `1,234,567`, whatever the locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }
}

/// Where a `UsageTracker` keeps its days and months between launches.
public protocol UsageStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// The usage as a JSON file. `write` is the bridge's `OwnerOnlyFile.write` (this library cannot import it):
/// `FileUsageStore(url: storage.appendingPathComponent(UsageTracker.fileName), write: OwnerOnlyFile.write)`.
public struct FileUsageStore: UsageStore {
    public let url: URL
    private let write: @Sendable (Data, URL) throws -> Void

    public init(url: URL, write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.url = url
        self.write = write
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws { try write(data, url) }
}

/// Keeps the usage in memory, for tests.
public final class MemoryUsageStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(_ data: Data? = nil) { self.data = data }

    public func load() throws -> Data? { lock.withLock { data } }
    public func save(_ data: Data) throws { lock.withLock { self.data = data } }
}

/// Token and cost totals per model, per local day and per local month (and per user within a day), with
/// optional budgets. With a store, the totals survive restarts: the file has homebridge-ai-kit's
/// `UsageSnapshot` shape (`version`, `models`, `days`, `months`) plus `users`, and is saved after every request.
/// Costs are computed from the token counts with the current prices.
public actor UsageTracker {
    /// The usage file in the bridge's storage directory.
    public static let fileName = "ai-usage.json"

    public struct Summary: Sendable, Hashable {
        public var requests: Int
        public var usage: TokenUsage
        /// nil when any request ran on a model without a known price.
        public var cost: Double?

        public init(requests: Int = 0, usage: TokenUsage = .zero, cost: Double? = 0) {
            self.requests = requests
            self.usage = usage
            self.cost = cost
        }

        /// Input plus output tokens, what token budgets count.
        public var tokens: Int { usage.inputTokens + usage.outputTokens }

        /// `requests`, the token counts and `costUsd` (null when unknown).
        public var json: JSONValue {
            var object: [String: JSONValue] = [
                "requests": .number(Double(requests)), "inputTokens": .number(Double(usage.inputTokens)),
                "outputTokens": .number(Double(usage.outputTokens)), "costUsd": cost.map(JSONValue.number) ?? .null,
            ]
            if let read = usage.cacheReadTokens { object["cacheReadTokens"] = .number(Double(read)) }
            if let write = usage.cacheWriteTokens { object["cacheWriteTokens"] = .number(Double(write)) }
            return .object(object)
        }
    }

    /// Requests and tokens of one model in one period, as stored.
    struct Counts: Hashable {
        var requests = 0
        var usage = TokenUsage.zero
    }

    typealias Models = [String: Counts]

    struct Snapshot: Hashable {
        var models: Models = [:]
        /// `yyyy-MM-dd` → model → counts.
        var days: [String: Models] = [:]
        /// `yyyy-MM` → model → counts.
        var months: [String: Models] = [:]
        /// `yyyy-MM-dd` → user → model → counts.
        var users: [String: [String: Models]] = [:]
    }

    private var snapshot: Snapshot
    private var limits: UsageBudget
    private let store: (any UsageStore)?
    private let retainDays: Int
    private let retainMonths: Int
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let logger: Logger?

    /// `store` loads at once (a missing or unreadable file starts empty) and saves after every request.
    /// `retainDays` and `retainMonths` bound the file; `timeZone` and `now` set what today is.
    public init(
        budget: UsageBudget = UsageBudget(), store: (any UsageStore)? = nil, retainDays: Int = 62, retainMonths: Int = 24,
        timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }, logger: Logger? = nil
    ) {
        limits = budget
        self.store = store
        self.retainDays = max(1, retainDays)
        self.retainMonths = max(1, retainMonths)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.now = now
        self.logger = logger
        var loaded = Snapshot()
        do {
            if let data = try store?.load() { loaded = try Self.decode(JSONValue(data: data)) }
        } catch {
            logger?.warning("Could not read the Assistant's usage; starting from zero", metadata: ["error": "\(error)"])
        }
        snapshot = loaded
    }

    // MARK: Recording

    /// Counts one finished request, for `user` when one is known (the web UI's signed-in user).
    public func record(model: String, usage used: TokenUsage, user: String? = nil) {
        let (day, month) = keys(now())
        Self.bump(&snapshot.models, model, used)
        Self.bump(&snapshot.days[day, default: [:]], model, used)
        Self.bump(&snapshot.months[month, default: [:]], model, used)
        if let user {
            Self.bump(&snapshot.users[day, default: [:]][user, default: [:]], model, used)
        }
        prune()
        save()
    }

    /// Forgets everything (and saves the empty state).
    public func reset() {
        snapshot = Snapshot()
        save()
    }

    // MARK: Totals

    /// Since the tracker started (with a store: since the file was created).
    public var total: Summary { Self.sum(snapshot.models) }

    public var byModel: [String: Summary] { Self.summaries(snapshot.models) }

    /// Today's totals, local time.
    public var today: Summary { Self.sum(snapshot.days[keys(now()).day]) }

    /// This month's totals, local time.
    public var thisMonth: Summary { Self.sum(snapshot.months[keys(now()).month]) }

    /// Totals per kept day, `yyyy-MM-dd` → summary.
    public var byDay: [String: Summary] { snapshot.days.mapValues { Self.sum($0) } }

    /// Totals per kept month, `yyyy-MM` → summary.
    public var byMonth: [String: Summary] { snapshot.months.mapValues { Self.sum($0) } }

    // MARK: Budgets

    public var budget: UsageBudget { limits }

    /// Replaces the limits, e.g. after the HomeswiftAiKit block changed.
    public func setBudget(_ budget: UsageBudget) { limits = budget }

    /// The first budget that is used up, or nil while every limit has room.
    public func exceededBudget() -> BudgetExceededError? {
        let (dayKey, monthKey) = keys(now())
        let day = snapshot.days[dayKey]
        let month = snapshot.months[monthKey]
        let checks: [(BudgetExceededError.Period, BudgetExceededError.Unit, Double?, () -> Double)] = [
            (.day, .tokens, limits.dailyTokens.map(Double.init), { Double(Self.sum(day).tokens) }),
            (.day, .usd, limits.dailyUsd, { Self.knownCost(day) }),
            (.month, .tokens, limits.monthlyTokens.map(Double.init), { Double(Self.sum(month).tokens) }),
            (.month, .usd, limits.monthlyUsd, { Self.knownCost(month) }),
        ]
        for (period, unit, limit, used) in checks {
            guard let limit else { continue }
            let value = used()
            if value >= limit { return BudgetExceededError(period: period, unit: unit, used: value, limit: limit) }
        }
        return nil
    }

    /// Throws `BudgetExceededError` once a budget is used up. Call before a request.
    public func checkBudget() throws {
        if let exceeded = exceededBudget() { throw exceeded }
    }

    /// Everything a usage page shows.
    public func report() -> UsageReport {
        let (day, month) = keys(now())
        let monthModels = snapshot.months[month] ?? [:]
        var monthUsers: [String: Models] = [:]
        for (key, users) in snapshot.users where key.hasPrefix(month + "-") {
            for (user, models) in users {
                for (model, counts) in models { Self.add(&monthUsers[user, default: [:]][model, default: Counts()], counts) }
            }
        }
        return UsageReport(
            day: day, month: month, today: Self.sum(snapshot.days[day]), thisMonth: Self.sum(monthModels), total: total,
            budget: limits, exceeded: exceededBudget(),
            byModel: byModel, todayByModel: Self.summaries(snapshot.days[day] ?? [:]), monthByModel: Self.summaries(monthModels),
            todayByUser: (snapshot.users[day] ?? [:]).mapValues { Self.sum($0) }, monthByUser: monthUsers.mapValues { Self.sum($0) })
    }

    // MARK: Internals

    /// Local `yyyy-MM-dd` and `yyyy-MM`.
    func keys(_ date: Date) -> (day: String, month: String) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return (month + String(format: "-%02d", parts.day ?? 0), month)
    }

    private static func add(_ counts: inout Counts, _ other: Counts) {
        counts.requests += other.requests
        counts.usage += other.usage
    }

    private static func bump(_ models: inout Models, _ model: String, _ usage: TokenUsage) {
        add(&models[model, default: Counts()], Counts(requests: 1, usage: usage))
    }

    private static func summaries(_ models: Models) -> [String: Summary] {
        models.reduce(into: [:]) { result, entry in
            result[entry.key] = Summary(requests: entry.value.requests, usage: entry.value.usage, cost: Pricing.cost(of: entry.key, usage: entry.value.usage))
        }
    }

    private static func sum(_ models: Models?) -> Summary {
        var summary = Summary()
        for (model, counts) in models ?? [:] {
            summary.requests += counts.requests
            summary.usage += counts.usage
            if let cost = summary.cost, let modelCost = Pricing.cost(of: model, usage: counts.usage) {
                summary.cost = cost + modelCost
            } else {
                summary.cost = nil
            }
        }
        return summary
    }

    /// USD of the priced requests only, for budgets.
    private static func knownCost(_ models: Models?) -> Double {
        (models ?? [:]).reduce(0) { $0 + (Pricing.cost(of: $1.key, usage: $1.value.usage) ?? 0) }
    }

    private func prune() {
        func keep<Value>(_ periods: inout [String: Value], _ count: Int) {
            for key in periods.keys.sorted().dropLast(count) { periods[key] = nil }
        }
        keep(&snapshot.days, retainDays)
        keep(&snapshot.months, retainMonths)
        keep(&snapshot.users, retainDays)
    }

    private func save() {
        guard let store else { return }
        do {
            try store.save(Self.encode(snapshot).encoded(pretty: true))
        } catch {
            logger?.warning("Could not save the Assistant's usage", metadata: ["error": "\(error)"])
        }
    }

    // MARK: The file

    static func encode(_ snapshot: Snapshot) -> JSONValue {
        func counts(_ counts: Counts) -> JSONValue {
            var object: [String: JSONValue] = [
                "calls": .number(Double(counts.requests)), "inputTokens": .number(Double(counts.usage.inputTokens)),
                "outputTokens": .number(Double(counts.usage.outputTokens)),
            ]
            if let read = counts.usage.cacheReadTokens { object["cacheReadTokens"] = .number(Double(read)) }
            if let write = counts.usage.cacheWriteTokens { object["cacheWriteTokens"] = .number(Double(write)) }
            return .object(object)
        }
        func models(_ models: Models) -> JSONValue { .object(models.mapValues(counts)) }
        return [
            "version": 1, "models": models(snapshot.models), "days": .object(snapshot.days.mapValues(models)),
            "months": .object(snapshot.months.mapValues(models)),
            "users": .object(snapshot.users.mapValues { .object($0.mapValues(models)) }),
        ]
    }

    /// Reads a snapshot; malformed fields are dropped, as upstream's `fromJSON` does.
    static func decode(_ json: JSONValue) -> Snapshot {
        func count(_ value: JSONValue?) -> Int? {
            guard let number = value?.doubleValue, number.isFinite, number >= 0 else { return nil }
            return Int(number)
        }
        func counts(_ value: JSONValue) -> Counts {
            var usage = TokenUsage(inputTokens: count(value["inputTokens"]) ?? 0, outputTokens: count(value["outputTokens"]) ?? 0)
            usage.cacheReadTokens = count(value["cacheReadTokens"])
            usage.cacheWriteTokens = count(value["cacheWriteTokens"])
            return Counts(requests: count(value["calls"]) ?? 0, usage: usage)
        }
        func models(_ value: JSONValue?) -> Models { (value?.objectValue ?? [:]).mapValues(counts) }
        func periods(_ value: JSONValue?) -> [String: Models] { (value?.objectValue ?? [:]).mapValues { models($0) } }
        return Snapshot(
            models: models(json["models"]), days: periods(json["days"]), months: periods(json["months"]),
            users: (json["users"]?.objectValue ?? [:]).mapValues { periods($0) })
    }
}

/// Today's and this month's usage with the budgets, by model and by user: what the web UI's usage view shows.
public struct UsageReport: Sendable, Hashable {
    /// Local `yyyy-MM-dd` and `yyyy-MM`.
    public var day: String
    public var month: String
    public var today: UsageTracker.Summary
    public var thisMonth: UsageTracker.Summary
    public var total: UsageTracker.Summary
    public var budget: UsageBudget
    /// The budget used up, when one is.
    public var exceeded: BudgetExceededError?
    public var byModel: [String: UsageTracker.Summary]
    public var todayByModel: [String: UsageTracker.Summary]
    public var monthByModel: [String: UsageTracker.Summary]
    /// Requests recorded with a user only.
    public var todayByUser: [String: UsageTracker.Summary]
    public var monthByUser: [String: UsageTracker.Summary]

    public var json: JSONValue {
        func map(_ summaries: [String: UsageTracker.Summary]) -> JSONValue { .object(summaries.mapValues(\.json)) }
        return [
            "day": .string(day), "month": .string(month), "today": today.json, "thisMonth": thisMonth.json, "total": total.json,
            "budget": budget.json, "exceeded": exceeded.map { .string($0.description) } ?? .null,
            "byModel": map(byModel), "todayByModel": map(todayByModel), "monthByModel": map(monthByModel),
            "byUser": ["today": map(todayByUser), "thisMonth": map(monthByUser)],
        ]
    }
}
