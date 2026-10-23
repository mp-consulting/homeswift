import NIOConcurrencyHelpers

/// One event of the TypeScript library's `EventEmitter`s (`segment`, `close`, `rtp`): listeners added with `on` or `once` and
/// removed with `off`, or awaited with `next()`. Listeners run synchronously on the thread that emits, in the order they were added.
public final class FfmpegEvent<Value: Sendable>: Sendable {
    /// Identifies a listener for `off`.
    public struct Listener: Hashable, Sendable {
        let id: Int
    }

    private struct Entry {
        let id: Int
        let once: Bool
        let handler: @Sendable (Value) -> Void
    }

    private struct State {
        var entries: [Entry] = []
        var nextID = 0
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    /// Calls `handler` on every emission until `off`.
    @discardableResult
    public func on(_ handler: @escaping @Sendable (Value) -> Void) -> Listener {
        add(handler, once: false)
    }

    /// Calls `handler` on the next emission only.
    @discardableResult
    public func once(_ handler: @escaping @Sendable (Value) -> Void) -> Listener {
        add(handler, once: true)
    }

    public func off(_ listener: Listener) {
        state.withLockedValue { $0.entries.removeAll { $0.id == listener.id } }
    }

    /// Removes every listener (Node's `removeAllListeners(event)`).
    public func removeAllListeners() {
        state.withLockedValue { $0.entries.removeAll() }
    }

    /// The number of listeners (Node's `listenerCount`).
    public var listenerCount: Int { state.withLockedValue { $0.entries.count } }

    /// Waits for the next emission (Node's `once(emitter, event)`). Returns nil when the task is cancelled.
    public func next() async -> Value? {
        let box = NIOLockedValueBox<(listener: Listener?, continuation: CheckedContinuation<Value?, Never>?, cancelled: Bool)>((nil, nil, false))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let cancelled = box.withLockedValue { value -> Bool in
                    value.continuation = continuation
                    return value.cancelled
                }
                if cancelled {
                    box.withLockedValue { $0.continuation = nil }
                    continuation.resume(returning: nil)
                    return
                }
                let listener = once { value in
                    let continuation = box.withLockedValue { state in
                        defer { state.continuation = nil }
                        return state.continuation
                    }
                    continuation?.resume(returning: value)
                }
                box.withLockedValue { $0.listener = listener }
            }
        } onCancel: {
            let (listener, continuation) = box.withLockedValue { state in
                defer {
                    state.cancelled = true
                    state.continuation = nil
                }
                return (state.listener, state.continuation)
            }
            if let listener { off(listener) }
            continuation?.resume(returning: nil)
        }
    }

    /// Calls the listeners with `value`, removing the `once` ones first.
    public func emit(_ value: Value) {
        let handlers = state.withLockedValue { state -> [@Sendable (Value) -> Void] in
            let handlers = state.entries.map(\.handler)
            state.entries.removeAll { $0.once }
            return handlers
        }
        for handler in handlers { handler(value) }
    }

    private func add(_ handler: @escaping @Sendable (Value) -> Void, once: Bool) -> Listener {
        state.withLockedValue { state in
            state.nextID += 1
            state.entries.append(Entry(id: state.nextID, once: once, handler: handler))
            return Listener(id: state.nextID)
        }
    }
}

extension FfmpegEvent where Value == Void {
    public func emit() { emit(()) }
}

/// Wakes the tasks waiting on it; each wait can time out. The counterpart of `runWithTimeout(once(emitter, event), timeout)`.
final class AsyncSignal: Sendable {
    private struct State {
        var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
        var nextID = 0
    }

    private let state = NIOLockedValueBox(State())

    /// Waits for `signal()`: true when signalled, false on timeout or cancellation. When `skipIf` returns true (it is evaluated
    /// under the signal's lock, so a `signal()` that follows the state change it checks is never missed), returns true at once.
    func wait(timeout: Duration?, skipIf: @Sendable () -> Bool = { false }) async -> Bool {
        let id = state.withLockedValue { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        let timer = NIOLockedValueBox<Task<Void, Never>?>(nil)
        defer { timer.withLockedValue { $0?.cancel() } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registered = state.withLockedValue { state -> Bool? in
                    if Task.isCancelled { return false }
                    if skipIf() { return nil }
                    state.waiters[id] = continuation
                    return true
                }
                guard registered == true else {
                    continuation.resume(returning: registered == nil)
                    return
                }
                if let timeout {
                    timer.withLockedValue {
                        $0 = Task { [weak self] in
                            try? await Task.sleep(for: timeout)
                            self?.resume(id, with: false)
                        }
                    }
                }
            }
        } onCancel: {
            resume(id, with: false)
        }
    }

    /// Wakes every current waiter.
    func signal() {
        let waiters = state.withLockedValue { state in
            defer { state.waiters = [:] }
            return state.waiters
        }
        for continuation in waiters.values { continuation.resume(returning: true) }
    }

    private func resume(_ id: Int, with value: Bool) {
        let continuation = state.withLockedValue { $0.waiters.removeValue(forKey: id) }
        continuation?.resume(returning: value)
    }
}
