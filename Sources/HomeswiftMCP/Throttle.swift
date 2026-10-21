import Foundation
import NIOConcurrencyHelpers

/// Slows down an address that keeps failing (bad tokens, wrong passwords, wrong set-up codes): after
/// `threshold` failures within `window`, each further attempt waits a second more, up to `maxDelay`.
public final class FailureThrottle: Sendable {
    private let failures = NIOLockedValueBox<[String: (count: Int, last: Date)]>([:])
    let window: TimeInterval
    let threshold: Int
    let maxDelay: Int

    public init(window: TimeInterval = 900, threshold: Int = 5, maxDelay: Int = 10) {
        self.window = window
        self.threshold = threshold
        self.maxDelay = maxDelay
    }

    /// The wait to impose before answering this attempt, from the failures so far.
    public func delay(for remote: String) -> Duration {
        let count = failures.withLockedValue { failures -> Int in
            guard let entry = failures[remote], Date().timeIntervalSince(entry.last) < window else { return 0 }
            return entry.count
        }
        return penalty(after: count)
    }

    /// Records a failure; returns the wait now due for this attempt.
    @discardableResult
    public func failed(_ remote: String) -> Duration {
        let count = failures.withLockedValue { failures -> Int in
            let previous = failures[remote].map { Date().timeIntervalSince($0.last) < window ? $0.count : 0 } ?? 0
            failures[remote] = (previous + 1, Date())
            return previous + 1
        }
        return penalty(after: count)
    }

    public func succeeded(_ remote: String) {
        failures.withLockedValue { $0[remote] = nil }
    }

    private func penalty(after count: Int) -> Duration {
        count >= threshold ? .seconds(min(count - threshold + 1, maxDelay)) : .zero
    }
}
