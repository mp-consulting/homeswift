import Foundation

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

/// Token and cost totals, per model, for the life of the process.
public actor UsageTracker {
    public struct Summary: Sendable, Hashable {
        public var requests: Int
        public var usage: TokenUsage
        /// nil when any request ran on a model without a known price.
        public var cost: Double?
    }

    private var totals: [String: (requests: Int, usage: TokenUsage)] = [:]

    public init() {}

    public func record(model: String, usage used: TokenUsage) {
        var entry = totals[model] ?? (0, .zero)
        entry.requests += 1
        entry.usage += used
        totals[model] = entry
    }

    public var total: Summary {
        var summary = Summary(requests: 0, usage: .zero, cost: 0)
        for (model, entry) in totals {
            summary.requests += entry.requests
            summary.usage += entry.usage
            if let cost = summary.cost, let modelCost = Pricing.cost(of: model, usage: entry.usage) {
                summary.cost = cost + modelCost
            } else {
                summary.cost = nil
            }
        }
        return summary
    }

    public var byModel: [String: Summary] {
        totals.reduce(into: [:]) { result, entry in
            result[entry.key] = Summary(requests: entry.value.requests, usage: entry.value.usage, cost: Pricing.cost(of: entry.key, usage: entry.value.usage))
        }
    }
}
