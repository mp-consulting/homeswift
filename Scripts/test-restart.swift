// Compile with Sources/HomeswiftCLI/Restart.swift; exercises recovery without restarting the test process.
import Foundation

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0, 0]
    func add(_ index: Int) { lock.lock(); defer { lock.unlock() }; values[index] += 1 }
    var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct RestartTests {
    static func main() async {
        let normal = Counts()
        await Restart.perform(timeout: 0.1, shutdown: {}, replace: { normal.add(0) }, timedOut: { normal.add(1) })
        try? await Task.sleep(for: .milliseconds(200))
        precondition(normal.snapshot == [1, 0], "Normal shutdown must replace once and cancel its deadline")

        let stalled = Counts()
        let task = Task {
            await Restart.perform(timeout: 0.05, shutdown: {
                try? await Task.sleep(for: .seconds(10))
            }, replace: { stalled.add(0) }, timedOut: { stalled.add(1) })
        }
        try? await Task.sleep(for: .milliseconds(200))
        precondition(stalled.snapshot == [1, 1], "Deadline must replace even while shutdown is pending")
        task.cancel()
        await task.value
        precondition(stalled.snapshot == [1, 1], "Late cleanup must not replace a second time")

        for _ in 0..<25 {
            let race = Counts()
            await Restart.perform(timeout: 0.002, shutdown: {
                try? await Task.sleep(for: .milliseconds(2))
            }, replace: { race.add(0) }, timedOut: { race.add(1) })
            try? await Task.sleep(for: .milliseconds(10))
            precondition(race.snapshot[0] == 1, "Deadline and completion must never replace twice")
        }
        print("Restart tests passed: normal shutdown, stalled shutdown, late completion and 25 deadline races")
    }
}
