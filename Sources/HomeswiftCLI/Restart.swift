import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import HomeswiftUI

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
        let running = ReleaseWatcher.runningExecutable
        // On a Homebrew install, its `opt` link, which an update moves to the new version: this one's Cellar may be gone.
        let installed = HomebrewInstaller(executable: running)?.executable.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        let path = installed ?? running
        var arguments: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        arguments.append(nil)
        closeOnExec()
        execv(path, arguments)
        // Only on failure: a service manager with keep-alive brings the bridge back.
        FileHandle.standardError.write(Data("homeswift: restart failed (\(String(cString: strerror(errno)))); exiting for the service manager to start it again\n".utf8))
        // A failure status: a unit with Restart=on-failure (or launchd's SuccessfulExit = false) starts it again too.
        exit(1)
    }

    /// Marks every descriptor above stderr close-on-exec, so the fresh copy starts with none of this one's sockets.
    /// Without it the web UI's kept-alive connections survived the exec, open but read by nobody: a browser sending
    /// its next request on one waited for its timeout, and the page took half a minute to come back.
    static func closeOnExec() {
        let open = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.compactMap { Int32($0) }
            ?? Array(3..<Int32(min(sysconf(Int32(_SC_OPEN_MAX)), 65536)))
        for descriptor in open where descriptor > 2 {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
        }
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
