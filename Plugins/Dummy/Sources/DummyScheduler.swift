import Foundation
import NIOConcurrencyHelpers

/// The clock and the timers of the plugin's schedules, auto-resets, fades, limiters and simulations: real time in the
/// bridge, a clock the tests move.
protocol DummyScheduler: Sendable {
    var now: Date { get }
    /// Runs `action` once `milliseconds` have passed, unless the timer is cancelled first.
    func after(milliseconds: Double, _ action: @escaping @Sendable () async -> Void) -> DummyTimer
}

/// One pending timer.
final class DummyTimer: Sendable {
    private let cancellation: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        cancellation = cancel
    }

    func cancel() { cancellation() }
}

/// Real time: each timer is a task that sleeps.
struct SystemScheduler: DummyScheduler {
    var now: Date { Date() }

    func after(milliseconds: Double, _ action: @escaping @Sendable () async -> Void) -> DummyTimer {
        let delay = max(0, milliseconds.isFinite ? milliseconds : 0)
        let task = Task {
            do { try await Task.sleep(for: .milliseconds(Int64(delay.rounded()))) } catch { return }
            await action()
        }
        return DummyTimer { task.cancel() }
    }
}

/// A clock that moves only when told to: `advance` runs the timers that come due, in order, each at its own time.
final class ManualScheduler: DummyScheduler {
    private struct Pending {
        var id: Int
        var due: Date
        var action: @Sendable () async -> Void
    }

    private struct State {
        var now: Date
        var next = 0
        var pending: [Pending] = []
    }

    private let state: NIOLockedValueBox<State>

    init(now: Date) {
        state = NIOLockedValueBox(State(now: now))
    }

    var now: Date { state.withLockedValue { $0.now } }

    var pendingCount: Int { state.withLockedValue { $0.pending.count } }

    func after(milliseconds: Double, _ action: @escaping @Sendable () async -> Void) -> DummyTimer {
        let id = state.withLockedValue { state -> Int in
            state.next += 1
            state.pending.append(Pending(id: state.next, due: state.now.addingTimeInterval(max(0, milliseconds) / 1000), action: action))
            return state.next
        }
        return DummyTimer { [weak self] in self?.state.withLockedValue { $0.pending.removeAll { $0.id == id } } }
    }

    /// Moves the clock by `seconds`, running each timer due on the way at its time (the earliest first, timers it
    /// sets included).
    func advance(by seconds: Double) async {
        let target = now.addingTimeInterval(seconds)
        while true {
            let due = state.withLockedValue { state -> Pending? in
                guard let index = state.pending.indices.filter({ state.pending[$0].due <= target })
                    .min(by: { (state.pending[$0].due, state.pending[$0].id) < (state.pending[$1].due, state.pending[$1].id) }) else { return nil }
                let pending = state.pending.remove(at: index)
                state.now = max(state.now, pending.due)
                return pending
            }
            guard let due else { break }
            await due.action()
        }
        state.withLockedValue { $0.now = target }
    }
}
