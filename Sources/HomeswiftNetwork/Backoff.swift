import Foundation

/// Delays between retries that grow by `factor` from `initial` up to `maximum`, with jitter so that several
/// clients that lost the same cloud do not come back all at once.
///
/// ```swift
/// let backoff = Backoff(initial: .seconds(5), maximum: .seconds(300), jitter: .proportional(0.2))
/// try await Task.sleep(for: backoff.delay(attempt: attempt))   // 5 s ±20 %, 10 s ±20 %, … 300 s ±20 %
/// ```
public struct Backoff: Sendable, Equatable {
    public enum Jitter: Sendable, Equatable {
        case none
        /// The delay times a random factor in `1 - fraction ..< 1 + fraction` (0.2 is ±20 %).
        case proportional(Double)
        /// A random part of `amount` added to the delay.
        case additive(Duration)
    }

    public var initial: Duration
    public var factor: Double
    public var maximum: Duration
    public var jitter: Jitter

    public init(initial: Duration, factor: Double = 2, maximum: Duration, jitter: Jitter = .none) {
        self.initial = initial
        self.factor = factor
        self.maximum = maximum
        self.jitter = jitter
    }

    /// The delay before retry `attempt`, counted from 0: `initial` times `factor` to the `attempt`, at most `maximum`,
    /// then the jitter. `random` (in `0..<1`) is for tests.
    public func delay(attempt: Int, random: Double = Double.random(in: 0..<1)) -> Duration {
        let grown = Self.seconds(initial) * pow(factor, Double(max(0, attempt)))
        let base = min(grown.isFinite ? grown : .greatestFiniteMagnitude, Self.seconds(maximum))
        switch jitter {
        case .none: return Self.duration(base)
        case .proportional(let fraction): return Self.duration(base * (1 + (random * 2 - 1) * fraction))
        case .additive(let amount): return Self.duration(base + Self.seconds(amount) * random)
        }
    }

    /// `Duration.seconds(_:)` traps on NaN and on more than about 1.7e20 seconds, which a factor or a jitter
    /// from a configuration can produce: no delay for NaN or a negative one, at most `Int64.max` seconds.
    private static func duration(_ seconds: Double) -> Duration {
        guard seconds > 0 else { return .zero }
        return seconds < 9.2e18 ? .seconds(seconds) : .seconds(Int64.max)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
