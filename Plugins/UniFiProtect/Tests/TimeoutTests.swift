import Foundation
import Testing

@testable import HomeswiftUniFiProtect

@Suite struct ProtectTimeoutTests {
    /// Cancellation wakes the timer's sleep. It must not compete with the completed operation as an expiry.
    @Test func completedOperationsBeatCancelledTimers() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    for value in 0..<100 {
                        let result = await protectTimeout(milliseconds: 60_000, clock: FrozenClock()) { value }
                        #expect(result == value)
                    }
                }
            }
        }
    }

    @Test func elapsedTimerStillReturnsNil() async {
        struct ImmediateClock: ProtectClock {
            var now: ContinuousClock.Instant { .now }
            func sleep(for duration: Duration) async {}
        }
        let result: Int? = await protectTimeout(milliseconds: 1, clock: ImmediateClock()) {
            try? await Task.sleep(for: .milliseconds(50))
            return 42
        }
        #expect(result == nil)
        // The late operation is allowed to finish and must not resume the continuation a second time.
        try? await Task.sleep(for: .milliseconds(100))
    }
}
