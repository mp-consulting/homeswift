import Foundation
import HomeswiftPlugin

/// The queue BLE commands go through (the Homebridge plugin's `p-queue` with a concurrency of 1 and one task
/// per interval): one at a time, in order, each started at least `interval` after the previous one started.
/// No timeout of its own: the BLE client bounds every step, and a timeout here would let the next command
/// overlap a write still running.
actor CommandQueue {
    private let interval: Duration
    private var lastStart: ContinuousClock.Instant?
    private var tail: Task<Void, Never>?
    private var paused = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(interval: Duration) {
        self.interval = interval
    }

    /// Runs `work` after the queued tasks, and returns what it returns.
    func add<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            await self.waitWhilePaused()
            await self.waitForSlot()
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func waitForSlot() async {
        if let lastStart {
            let next = lastStart + interval
            if next > .now { try? await Task.sleep(until: next) }
        }
        lastStart = .now
    }

    /// For tests: holds the queue so commands pile up.
    func pause() { paused = true }

    func start() {
        paused = false
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitWhilePaused() async {
        guard paused else { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }
}
