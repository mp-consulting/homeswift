import Foundation

/// Allows `limit` requests per key (a user name) in any `window` seconds: homebridge-ai-kit's
/// `SlidingWindowRateLimiter`. A key with no request in the last window is evicted (at most once per window,
/// during calls), so memory stays bounded by the keys active recently. Safe to call from any thread.
public final class SlidingWindowRateLimiter: @unchecked Sendable {
    /// What a request gets.
    public struct Result: Sendable, Hashable {
        public var allowed: Bool
        /// Requests left in the current window after this one.
        public var remaining: Int
        /// When refused: seconds until the oldest request leaves the window (a `Retry-After`). 0 when allowed.
        public var retryAfter: TimeInterval
    }

    /// Glass UI's limit for the Assistant: 20 requests a minute per user.
    public static func assistant(now: @escaping @Sendable () -> Date = { Date() }) -> SlidingWindowRateLimiter {
        SlidingWindowRateLimiter(limit: 20, window: 60, now: now)
    }

    /// The message to answer a refused request with (429).
    public static let refusal = "Too many Assistant requests. Wait a minute and try again."

    public let limit: Int
    public let window: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    // Guarded by `lock`.
    private var hits: [String: [Date]] = [:]
    private var lastPrune: Date

    /// `limit` must be at least 1 and `window` positive.
    public init(limit: Int, window: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(limit >= 1 && window > 0, "SlidingWindowRateLimiter needs limit >= 1 and window > 0")
        self.limit = limit
        self.window = window
        self.now = now
        lastPrune = now()
    }

    /// Counts a request for `key` when there is room; a refused one is never counted.
    public func consume(_ key: String) -> Result {
        let now = self.now()
        return lock.withLock {
            if now.timeIntervalSince(lastPrune) >= window { pruneLocked(now) }
            var list = recentLocked(key, now)
            if list.count >= limit { return refused(list, now) }
            list.append(now)
            hits[key] = list
            return Result(allowed: true, remaining: limit - list.count, retryAfter: 0)
        }
    }

    /// What `consume` would answer, without counting anything.
    public func peek(_ key: String) -> Result {
        let now = self.now()
        return lock.withLock {
            let list = recentLocked(key, now)
            return list.count >= limit ? refused(list, now) : Result(allowed: true, remaining: limit - list.count, retryAfter: 0)
        }
    }

    /// Forgets one key, or every key.
    public func reset(_ key: String? = nil) {
        lock.withLock {
            if let key { hits[key] = nil } else { hits.removeAll() }
        }
    }

    /// Evicts every key without a request in the current window.
    public func prune() {
        let now = self.now()
        lock.withLock { pruneLocked(now) }
    }

    /// Keys currently tracked.
    public var count: Int { lock.withLock { hits.count } }

    private func refused(_ list: [Date], _ now: Date) -> Result {
        Result(allowed: false, remaining: 0, retryAfter: max(0, list[0].addingTimeInterval(window).timeIntervalSince(now)))
    }

    private func recentLocked(_ key: String, _ now: Date) -> [Date] {
        let list = (hits[key] ?? []).filter { now.timeIntervalSince($0) < window }
        hits[key] = list.isEmpty ? nil : list
        return list
    }

    private func pruneLocked(_ now: Date) {
        lastPrune = now
        for key in Array(hits.keys) { _ = recentLocked(key, now) }
    }
}
