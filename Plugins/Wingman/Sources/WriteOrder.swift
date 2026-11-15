import Foundation

/// The writes to one Wingman, in order per characteristic, the latest winning.
///
/// Wingman hands each write to HomeKit as it comes, and HomeKit answers each when the accessory does: two writes to a
/// slow lamp, on then off, can land off then on, and the lamp stays on. A write that gave up on this side (a timeout, an
/// Automation restarted) is still under way on the Mac. So a write waits for the one before it to the same
/// characteristic to finish, however it finishes; and when a later write came while it waited, it is not sent at all:
/// the later value is the one wanted. It answers as written then, as a slider's intermediate values do.
actor WriteOrder {
    private var last: [String: Task<Void, Never>] = [:]
    private var latest: [String: Int] = [:]
    private var counter = 0
    /// The writes asked for each key, for the tests.
    private(set) var asked: [String: Int] = [:]

    /// Runs `send` once the writes to `key` before it have finished, unless a later one for `key` came meanwhile or the
    /// caller stopped waiting before its turn. Once sent, it runs to its end, so the next one waits for it.
    func write(_ key: String, _ send: @escaping @Sendable () async throws -> Void) async throws {
        counter += 1
        let token = counter
        latest[key] = token
        asked[key, default: 0] += 1
        let before = last[key]
        let abandoned = Abandoned()
        let task = Task<Result<Void, any Error>, Never> {
            await before?.value
            guard await self.isLatest(key, token) else { return .success(()) }
            guard !abandoned.value else { return .failure(CancellationError()) }
            do { try await send() } catch { return .failure(error) }
            return .success(())
        }
        last[key] = Task { _ = await task.value }
        // Not cancelled with the caller: a write that was sent finishes, and the next one waits for it.
        try await withTaskCancellationHandler {
            try await task.value.get()
        } onCancel: {
            abandoned.set()
        }
        if latest[key] == token { latest[key] = nil; last[key] = nil }
    }

    private func isLatest(_ key: String, _ token: Int) -> Bool { latest[key] == token }

    /// Whether the caller stopped waiting.
    private final class Abandoned: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var value: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }
}
