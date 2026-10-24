import Foundation
import NIOConcurrencyHelpers

/// Slows down an address that keeps failing (bad tokens, wrong passwords, wrong set-up codes): after
/// `threshold` failures within `window`, each further attempt waits a second more, up to `maxDelay`. Addresses whose
/// failures are older than `window` are forgotten once `capacity` are kept, and beyond that the oldest half, so a scan
/// from many addresses (IPv6 privacy addresses) cannot grow it without end.
public final class FailureThrottle: Sendable {
    private let failures = NIOLockedValueBox<[String: (count: Int, last: Date)]>([:])
    let window: TimeInterval
    let threshold: Int
    let maxDelay: Int
    let capacity: Int

    public init(window: TimeInterval = 900, threshold: Int = 5, maxDelay: Int = 10, capacity: Int = 4096) {
        self.window = window
        self.threshold = threshold
        self.maxDelay = maxDelay
        self.capacity = capacity
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
            let now = Date()
            let previous = failures[remote].map { now.timeIntervalSince($0.last) < window ? $0.count : 0 } ?? 0
            if failures[remote] == nil, failures.count >= capacity {
                failures = failures.filter { now.timeIntervalSince($0.value.last) < window }
                if failures.count >= capacity {
                    let newest = failures.sorted { $0.value.last > $1.value.last }.prefix(capacity / 2)
                    failures = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
                }
            }
            failures[remote] = (previous + 1, now)
            return previous + 1
        }
        return penalty(after: count)
    }

    public func succeeded(_ remote: String) {
        failures.withLockedValue { $0[remote] = nil }
    }

    var count: Int { failures.withLockedValue { $0.count } }

    private func penalty(after count: Int) -> Duration {
        count >= threshold ? .seconds(min(count - threshold + 1, maxDelay)) : .zero
    }
}
