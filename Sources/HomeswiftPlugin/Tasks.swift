import Foundation
import NIOConcurrencyHelpers

/// The tasks a plugin starts (polls, sockets, retries), cancelled together when it stops. Once `cancelAll()` ran,
/// `add` starts nothing, so a late callback cannot bring a stopped plugin back to life.
public final class TaskBag: Sendable {
    private struct State {
        var tasks: [Int: Task<Void, Never>] = [:]
        var next = 0
        var stopped = false
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    /// Whether `cancelAll()` ran.
    public var isStopped: Bool { state.withLockedValue { $0.stopped } }

    /// Runs `operation` in a task of the bag. Returns nil, starting nothing, once the bag is stopped.
    @discardableResult
    public func add(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        state.withLockedValue { state in
            guard !state.stopped else { return nil }
            state.next += 1
            let id = state.next
            // The task removes itself under the same lock, so it cannot finish before it is in the list.
            let task = Task { [weak self] in
                await operation()
                self?.finished(id)
            }
            state.tasks[id] = task
            return task
        }
    }

    /// Keeps a task started elsewhere, to cancel it with the others; cancels it at once when the bag is stopped.
    public func add(_ task: Task<Void, Never>) {
        let added = add { await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() } }
        if added == nil { task.cancel() }
    }

    /// Cancels every task and stops the bag. The tasks end on their own; `idle()` waits for them.
    public func cancelAll() {
        let tasks = state.withLockedValue { state in
            state.stopped = true
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
    }

    /// Waits until no task of the bag runs, for tests.
    public func idle() async {
        await withCheckedContinuation { continuation in
            let done = state.withLockedValue { state in
                if state.tasks.isEmpty { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func finished(_ id: Int) {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            state.tasks[id] = nil
            guard state.tasks.isEmpty else { return [] }
            defer { state.idleWaiters = [] }
            return state.idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Lets only the last of quick successive calls through, as the Homebridge plugins' debounced guards do for
/// sliders: each call waits `delay` and says whether no later call for the same key came in meanwhile.
public final class LatestCallGuard: Sendable {
    private let delay: Duration
    private let tokens = NIOLockedValueBox<(next: Int, latest: [String: Int])>((0, [:]))

    public init(delay: Duration) { self.delay = delay }

    /// Waits `delay`, then says whether this is still the latest call for `key`; false when the task was cancelled.
    public func callAsFunction(_ key: String = "") async -> Bool {
        let isLatest = claim(key)
        do { try await Task.sleep(for: delay) } catch { return false }
        return isLatest()
    }

    /// Makes this the latest call for `key` without waiting: the closure says whether it still is.
    public func claim(_ key: String = "") -> @Sendable () -> Bool {
        let token = tokens.withLockedValue { tokens in
            tokens.next += 1
            tokens.latest[key] = tokens.next
            return tokens.next
        }
        return { [tokens] in tokens.withLockedValue { $0.latest[key] == token } }
    }
}

extension AsyncSequence where Self: Sendable, Element: Sendable {
    /// What the sequence yields within `window`, or until it ends if that is sooner; it is cancelled then. For a Bonjour
    /// browse made for a moment (a plugin made only for Setup looking for its devices).
    public func collect(for window: Duration) async -> [Element] {
        await withTaskGroup(of: [Element]?.self) { group in
            group.addTask {
                var found: [Element] = []
                do { for try await element in self { found.append(element) } } catch {}
                return found
            }
            group.addTask {
                try? await Task.sleep(for: window)
                return nil
            }
            // The window's end, or a sequence that ended first: either way it stops and says what it found.
            var found = await group.next().flatMap { $0 } ?? []
            group.cancelAll()
            while let result = await group.next() { found += result ?? [] }
            return found
        }
    }
}

/// The error `withTimeout` throws by default.
public struct TimeoutError: Error, CustomStringConvertible, Sendable, Equatable {
    public let timeout: Duration
    public init(_ timeout: Duration) { self.timeout = timeout }
    public var description: String { "no answer within \(timeout)" }
}

/// Runs `body`, or, once `timeout` passes first, cancels it, calls `onTimeout` (to close what `body` waits on) and throws
/// `error` (a `TimeoutError` by default). A plugin passes its own error so its callers see the same one as before.
public func withTimeout<T: Sendable>(
    _ timeout: Duration, error: @escaping @Sendable () -> any Error = { TimeoutError(.zero) }, onTimeout: @escaping @Sendable () async -> Void = {},
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        if let first = try await group.next(), let value = first { return value }
        await onTimeout()
        let thrown = error()
        throw (thrown as? TimeoutError).map { _ in TimeoutError(timeout) } ?? thrown
    }
}


/// Runs work one piece after the other, in the order it was asked for, each piece once the one before it has ended
/// (thrown or not): the host's reloads and controls, the Home Link's follows and changes.
public final class SerialTasks: Sendable {
    private let tail = NIOLockedValueBox<Task<Void, Never>?>(nil)

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = tail.withLockedValue { tail -> Task<T, any Error> in
            let previous = tail
            let task = Task<T, any Error> {
                await previous?.value
                return try await work()
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }

    public func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let task = tail.withLockedValue { tail -> Task<T, Never> in
            let previous = tail
            let task = Task<T, Never> {
                await previous?.value
                return await work()
            }
            tail = Task { _ = await task.value }
            return task
        }
        return await task.value
    }

    /// Waits for the work asked for so far to end.
    public func idle() async {
        await tail.withLockedValue { $0 }?.value
    }
}
