import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Replaces this process with a fresh copy of itself: same binary, same arguments, same PID, so launchd,
/// systemd and `brew services` see a bridge that never went away. Everything must be stopped first.
enum Restart {
    /// A stalled plugin or shutdown callback must not leave a stopped bridge offline forever.
    /// The independent dispatch timer also works when Swift's cooperative tasks are blocked.
    static func perform(
        timeout: TimeInterval = 30,
        shutdown: @escaping @Sendable () async -> Void,
        replace: @escaping @Sendable () -> Void = { exec() },
        timedOut: (@Sendable () -> Void)? = nil
    ) async {
        let gate = RestartGate()
        let deadline = DispatchWorkItem {
            guard gate.claim() else { return }
            if let timedOut { timedOut() }
            else { FileHandle.standardError.write(Data("homeswift: shutdown exceeded \(Int(timeout)) seconds; restarting the process now\n".utf8)) }
            replace()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: deadline)
        await shutdown()
        guard gate.claim() else { return }
        deadline.cancel()
        replace()
    }

    static func exec() -> Never {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var arguments: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        arguments.append(nil)
        execv(path, arguments)
        // Only on failure: a service manager with keep-alive brings the bridge back.
        FileHandle.standardError.write(Data("homeswift: restart failed (\(String(cString: strerror(errno)))); exiting for the service manager to start it again\n".utf8))
        // A failure status: a unit with Restart=on-failure (or launchd's SuccessfulExit = false) starts it again too.
        exit(1)
    }
}

/// Only one path may replace the process, including when shutdown completes at its deadline.
private final class RestartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
