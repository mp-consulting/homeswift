import Foundation
import NIOConcurrencyHelpers
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Why a child process could not be started.
public struct ChildProcessError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The errno `posix_spawn` (or a file action) failed with.
    public var code: Int32
    public var path: String

    public var description: String { "cannot run \(path): \(String(cString: strerror(code)))" }
}

/// A child process started with `posix_spawn`, for every tool the bridge runs (FFmpeg, curl, an installer).
///
/// Not Foundation's `Process`: on Linux, swift-corelibs-foundation's `Process.run()` (through Swift 6.2) lists
/// `/proc/self/fd` copying each entry's whole 256-byte `d_name`, past the end of the shorter record `readdir` returns,
/// and crashed with a bad pointer dereference when the record sat at the end of glibc's buffer, more often the more
/// descriptors were open (swiftlang/swift-corelibs-foundation#5472). This spawns directly, the same on macOS.
///
/// The child gets its standard input, output and error from the descriptors given (`/dev/null` for nil), nothing
/// else (the parent's other descriptors are closed in it), an empty signal mask (the threads Swift's concurrency and
/// libdispatch run on block signals, which a child would inherit and so ignore SIGTERM), and a process group of its
/// own, as `Process` does. Spawns take turns, with `pipe`. A thread of its own waits for the child; `onExit` runs
/// there once, with how it ended.
public final class ChildProcess: Sendable {
    /// How a child process ended.
    public enum Termination: Sendable, Equatable, CustomStringConvertible {
        case exited(Int32)
        case signaled(Int32)

        /// The exit code, or the signal's number, as `Process.terminationStatus` has it.
        public var status: Int32 {
            switch self {
            case .exited(let code): code
            case .signaled(let signal): signal
            }
        }

        public var description: String {
            switch self {
            case .exited(let code): "exit code \(code)"
            case .signaled(let signal): "signal \(signal)"
            }
        }
    }

    public let processIdentifier: pid_t
    private let state: NIOLockedValueBox<(termination: Termination?, waiters: [CheckedContinuation<Termination, Never>])>
    // True from the moment the child has ended but before it is reaped, so a signal never reaches a reused pid.
    private let ended = NIOLockedValueBox(false)
    // Left once the child has been reaped, for `waitUntilExit`.
    private let exited = DispatchGroup()

    private init(pid: pid_t) {
        processIdentifier = pid
        state = NIOLockedValueBox((nil, []))
        exited.enter()
    }

    /// Starts `path` (a path, not a name looked up in `PATH`) with `arguments` (not including the program's name) and
    /// `environment` (this process's when nil).
    public static func launch(
        _ path: String, arguments: [String] = [], environment: [String: String]? = nil,
        standardInput: Int32? = nil, standardOutput: Int32? = nil, standardError: Int32? = nil,
        onExit: (@Sendable (Termination) -> Void)? = nil
    ) throws(ChildProcessError) -> ChildProcess {
        let pid = try spawn(path, arguments: arguments, environment: environment, descriptors: [standardInput, standardOutput, standardError])
        let child = ChildProcess(pid: pid)
        let thread = Thread { child.waitForExit(onExit) }
        thread.name = "homeswift-wait-\(pid)"
        thread.start()
        return child
    }

    /// Whether the child is still running.
    public var isRunning: Bool { !ended.withLockedValue { $0 } }

    /// How the child ended, nil while it runs.
    public var termination: Termination? { state.withLockedValue { $0.termination } }

    /// Sends `signal` (SIGTERM by default); false when the child has already ended or the signal could not be sent.
    @discardableResult
    public func signal(_ signal: Int32 = SIGTERM) -> Bool {
        ended.withLockedValue { ended in
            guard !ended else { return false }
            return kill(processIdentifier, signal) == 0
        }
    }

    /// Waits for the child to end.
    public func wait() async -> Termination {
        await withCheckedContinuation { continuation in
            let done = state.withLockedValue { state -> Termination? in
                if let termination = state.termination { return termination }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    /// SIGTERM once `timeout` has passed, then SIGKILL `grace` later for a child that ignores it (its pipes would stay
    /// open, and readers waiting for their end with them). Cancel the task once the child has ended.
    public func terminate(after timeout: Duration, killAfter grace: Duration) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard signal(SIGTERM) else { return }
            do { try await Task.sleep(for: grace) } catch { return }
            signal(SIGKILL)
        }
    }

    /// Blocks the calling thread until the child ends: for tests and tools that are not async.
    @discardableResult
    public func waitUntilExit() -> Termination {
        exited.wait()
        return state.withLockedValue { $0.termination! }
    }

    private func waitForExit(_ onExit: (@Sendable (Termination) -> Void)?) {
        // Wait without reaping first: until it is reaped, the pid cannot be reused, and `signal` checks `ended` first.
        var info = siginfo_t()
        while waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        ended.withLockedValue { $0 = true }
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(processIdentifier, &status, 0) } while reaped < 0 && errno == EINTR
        // The macros are not imported: the low seven bits are the signal that ended it, zero for an exit.
        let termination: Termination = reaped < 0 ? .exited(-1)
            : (status & 0x7f) == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Termination, Never>] in
            state.termination = termination
            defer { state.waiters = [] }
            return state.waiters
        }
        exited.leave()
        onExit?(termination)
        for waiter in waiters { waiter.resume(returning: termination) }
    }

    /// A pipe whose two ends are close-on-exec before any child can be started: it is made under the lock spawns take
    /// (Swift's Glibc has no `pipe2`). The child a pipe is given to still gets its end: dup2 onto 0, 1 or 2 clears the flag.
    public static func pipe() throws(ChildProcessError) -> (reading: FileHandle, writing: FileHandle) {
        var ends: [Int32] = [-1, -1]
        let result = spawning.withLock { () -> Int32 in
            #if canImport(Darwin)
            guard Darwin.pipe(&ends) == 0 else { return errno }
            #elseif canImport(Musl)
            guard Musl.pipe(&ends) == 0 else { return errno }
            #else
            guard Glibc.pipe(&ends) == 0 else { return errno }
            #endif
            for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return 0
        }
        if result != 0 { throw ChildProcessError(code: result, path: "pipe") }
        return (FileHandle(fileDescriptor: ends[0], closeOnDealloc: true), FileHandle(fileDescriptor: ends[1], closeOnDealloc: true))
    }

    /// What a tool printed, and how it ended.
    public struct Output: Sendable {
        public var termination: Termination
        public var standardOutput: Data
        public var standardError: Data

        public var status: Int32 { termination.status }
        public var text: String { String(decoding: standardOutput, as: UTF8.self) }
        public var errorText: String { String(decoding: standardError, as: UTF8.self) }
    }

    /// Runs a tool to its end, `input` written to its standard input, and returns what it printed. Blocks the calling
    /// thread: for tests and short tools outside Swift's pool.
    public static func run(_ path: String, arguments: [String] = [], environment: [String: String]? = nil, input: Data = Data()) throws(ChildProcessError) -> Output {
        ignoreSIGPIPE()
        // Without input, the tool's standard input is /dev/null: no pipe and no thread to write it.
        let stdin = input.isEmpty ? nil : try pipe()
        let stdout = try pipe(), stderr = try pipe()
        let ends = [stdin, stdout, stderr].compactMap { $0 }.flatMap { [$0.reading, $0.writing] }
        let child: ChildProcess
        do {
            child = try launch(path, arguments: arguments, environment: environment,
                               standardInput: stdin?.reading.fileDescriptor,
                               standardOutput: stdout.writing.fileDescriptor,
                               standardError: stderr.writing.fileDescriptor)
        } catch {
            for handle in ends { try? handle.close() }
            throw error
        }
        try? stdin?.reading.close()
        try? stdout.writing.close()
        try? stderr.writing.close()
        // Threads of their own, not DispatchQueue.global(): `run` blocks its caller, often a thread of Swift's cooperative
        // pool, and on macOS the global queue shares that pool's threads. With every one of them blocked here (three on a
        // three-core runner), the reads never started and `run` waited for them forever.
        let group = DispatchGroup()
        func onThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
            group.enter()
            let thread = Thread {
                body()
                group.leave()
            }
            thread.name = name
            thread.start()
        }
        let output = NIOLockedValueBox(Data()), error = NIOLockedValueBox(Data())
        for (handle, box) in [(stdout.reading, output), (stderr.reading, error)] {
            onThread("homeswift-run-read") {
                let data = handle.readDataToEndOfFile()
                try? handle.close()
                box.withLockedValue { $0 = data }
            }
        }
        if let stdin {
            onThread("homeswift-run-write") {
                // A tool that exits without reading its input closes the pipe: the write fails rather than raising SIGPIPE
                // where it is ignored, and is of no interest then.
                #if canImport(Darwin)
                _ = fcntl(stdin.writing.fileDescriptor, F_SETNOSIGPIPE, 1)
                #endif
                try? stdin.writing.write(contentsOf: input)
                try? stdin.writing.close()
            }
        }
        let termination = child.waitUntilExit()
        group.wait()
        return Output(termination: termination, standardOutput: output.withLockedValue { $0 }, standardError: error.withLockedValue { $0 })
    }

    /// Writing to a pipe whose reader is gone (a tool that has exited) raises SIGPIPE, which ends the whole process. Darwin
    /// turns it off per descriptor (F_SETNOSIGPIPE, which writers set); Linux cannot for pipes, so the signal is ignored,
    /// once, unless the program installed a handler of its own. For every caller that writes to a child.
    public static func ignoreSIGPIPE() { _ = ignoreSIGPIPEOnce }

    private static let ignoreSIGPIPEOnce: Void = {
        // The module's names: inside this class, `signal` is the instance method.
        #if canImport(Glibc)
        if let previous = Glibc.signal(SIGPIPE, SIG_IGN) { _ = Glibc.signal(SIGPIPE, previous) }
        #elseif canImport(Musl)
        if let previous = Musl.signal(SIGPIPE, SIG_IGN) { _ = Musl.signal(SIGPIPE, previous) }
        #endif
    }()

    // MARK: Spawning

    private static let spawning = NIOLock()

    private static func spawn(_ path: String, arguments: [String], environment: [String: String]?, descriptors: [Int32?]) throws(ChildProcessError) -> pid_t {
        func check(_ result: Int32) throws(ChildProcessError) {
            if result != 0 { throw ChildProcessError(code: result, path: path) }
        }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        for (target, source) in descriptors.enumerated() {
            if let source {
                try check(posix_spawn_file_actions_adddup2(&actions, source, Int32(target)))
            } else {
                try check(posix_spawn_file_actions_addopen(&actions, Int32(target), "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0))
            }
        }

        // SETSIGDEF: every signal back to its default in the child. exec keeps a signal the bridge ignores ignored (SIGPIPE,
        // which Subprocess ignores on Linux), and a tool would then live on after writing into a pipe nobody reads.
        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        #if canImport(Darwin)
        // Every descriptor but 0, 1 and 2 is closed in the child.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        try check(posix_spawnattr_setsigmask(&attributes, &noSignals))
        var everySignal = sigset_t()
        sigemptyset(&everySignal)
        for number: Int32 in 1..<32 where number != SIGKILL && number != SIGSTOP { sigaddset(&everySignal, number) }
        try check(posix_spawnattr_setsigdefault(&attributes, &everySignal))

        // One spawn at a time, under the lock `pipe` takes: pipes are close-on-exec before any child can see them, and
        // the descriptors listed are those open as the child starts.
        var pid: pid_t = 0
        try check(spawning.withLock { () -> Int32 in
            #if !canImport(Darwin)
            // Linux has no POSIX_SPAWN_CLOEXEC_DEFAULT. glibc 2.34 and later close every other descriptor in the child
            // (posix_spawn_file_actions_addclosefrom_np, looked up as it runs: DSM's glibc is 2.26); before, each one open
            // now is closed, and one another thread opens meanwhile without close-on-exec stays open in the child (a
            // script being written then could not be run while the child ran: "Text file busy").
            if let closeFrom = closeFrom {
                let result = closeFrom(&actions, 3)
                if result != 0 { return result }
            } else {
                for fd in openDescriptors() where fd > 2 {
                    let result = posix_spawn_file_actions_addclose(&actions, fd)
                    if result != 0 { return result }
                }
            }
            #endif
            return posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        })
        return pid
    }

    #if !canImport(Darwin)
    private typealias CloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32
    /// glibc's posix_spawn_file_actions_addclosefrom_np, nil before 2.34.
    private static let closeFrom: CloseFrom? = dlsym(nil, "posix_spawn_file_actions_addclosefrom_np").map { unsafeBitCast($0, to: CloseFrom.self) }
    static var closesOtherDescriptorsInTheChild: Bool { closeFrom != nil }

    /// The descriptors open in this process, from `/proc/self/fd`, or every number below the limit without it.
    static func openDescriptors() -> [Int32] {
        guard let directory = opendir("/proc/self/fd") else {
            return Array(3..<min(getdtablesize(), 65536))
        }
        defer { closedir(directory) }
        let own = dirfd(directory)
        let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
        var descriptors: [Int32] = []
        while let entry = readdir(directory) {
            // The name is read up to its own terminator: the record is only as long as `d_reclen`, not the
            // declared 256 bytes of `d_name`, and copying the field reads past glibc's buffer.
            let name = String(cString: UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self))
            if let fd = Int32(name), fd != own { descriptors.append(fd) }
        }
        return descriptors
    }
    #endif
}
