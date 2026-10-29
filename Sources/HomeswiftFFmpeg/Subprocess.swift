import Foundation
import NIOConcurrencyHelpers
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// How a process ended, as Node's `exit` event reports it: an exit code, or the name of the signal that ended it.
public struct FfmpegExitStatus: Sendable, Equatable, CustomStringConvertible {
    /// The exit code, nil when a signal ended the process.
    public var exitCode: Int32?
    /// The signal that ended the process (`SIGTERM`, `SIGKILL`, ...), nil when it exited.
    public var signal: String?

    public init(exitCode: Int32?, signal: String?) {
        self.exitCode = exitCode
        self.signal = signal
    }

    public var description: String {
        "exit code \(exitCode.map(String.init) ?? "null") and signal \(signal ?? "null")"
    }
}

/// Why a child process could not be started or written to.
public enum FfmpegProcessError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The executable is not in the `PATH` (or not executable at the path given).
    case notFound(String)
    /// The executable exists but could not be started.
    case launchFailed(String)
    /// No process is running.
    case notRunning
    /// Standard input was closed (`endStdin`, `stop`), or the process closed its end (`EPIPE`).
    case stdinClosed
    /// A write to standard input failed.
    case writeFailed(Int32)
    /// The process ended before it started (FFmpeg writes to standard error as soon as it runs), with the error message.
    case endedBeforeStart(String)

    public var description: String {
        switch self {
        case .notFound(let path): "unable to find '\(path)'"
        case .launchFailed(let message): message
        case .notRunning: "no FFmpeg process is running"
        case .stdinClosed: "standard input is closed"
        case .writeFailed(let code): "write error \(code)"
        case .endedBeforeStart(let message): message
        }
    }
}

/// The name Node gives a signal number.
func signalName(_ signal: Int32) -> String {
    switch signal {
    case SIGHUP: "SIGHUP"
    case SIGINT: "SIGINT"
    case SIGQUIT: "SIGQUIT"
    case SIGILL: "SIGILL"
    case SIGABRT: "SIGABRT"
    case SIGFPE: "SIGFPE"
    case SIGKILL: "SIGKILL"
    case SIGBUS: "SIGBUS"
    case SIGSEGV: "SIGSEGV"
    case SIGPIPE: "SIGPIPE"
    case SIGALRM: "SIGALRM"
    case SIGTERM: "SIGTERM"
    case SIGUSR1: "SIGUSR1"
    case SIGUSR2: "SIGUSR2"
    default: "SIG\(signal)"
    }
}

/// Finds an executable the way `execFile` does: a name with a slash is a path, anything else is looked up in `PATH`.
func resolveExecutable(_ command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let fileManager = FileManager.default
    if command.contains("/") {
        return fileManager.isExecutableFile(atPath: command) ? command : nil
    }
    let path = environment["PATH"] ?? "/usr/bin:/bin"
    for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = directory.hasSuffix("/") ? String(directory) + command : String(directory) + "/" + command
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue, fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Writing to a pipe whose reader is gone raises SIGPIPE, which ends the whole bridge. Darwin can turn it off per descriptor;
/// Linux cannot for pipes, so the signal is ignored once, unless the program installed a handler of its own.
private let ignoreSIGPIPEOnce: Void = {
    #if os(Linux)
    // Keep a handler the program installed (signal() returns nil for the default disposition).
    if let previous = signal(SIGPIPE, SIG_IGN) {
        _ = signal(SIGPIPE, previous)
    }
    #endif
}()

#if canImport(Glibc) || canImport(Musl)
/// Runs `body` with the signals that stop a process unblocked on this thread. posix_spawn gives the child the
/// calling thread's signal mask, Foundation's `Process` does not reset it on Linux, and the threads Swift's
/// concurrency and libdispatch run on block signals: FFmpeg started from one would ignore SIGTERM and only end
/// with the SIGKILL failsafe.
private func withStopSignalsUnblocked<T>(_ body: () throws -> T) rethrows -> T {
    var stops = sigset_t()
    sigemptyset(&stops)
    for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2] { sigaddset(&stops, signal) }
    var previous = sigset_t()
    pthread_sigmask(SIG_UNBLOCK, &stops, &previous)
    defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
    return try body()
}
#endif

/// The most standard output kept for the first `onStdout` handler before one is registered (Node buffers a stream nobody reads
/// yet as well). Beyond it, output is dropped.
let SUBPROCESS_PENDING_STDOUT_LIMIT = 4 * 1024 * 1024

/// The buffer a pipe's reads go to, reused for every read. Only touched on that pipe's read source queue, which is serial.
private final class ReadBuffer: @unchecked Sendable {
    var bytes = [UInt8](repeating: 0, count: 65536)
}

/// One child process with its three pipes: the counterpart of Node's `ChildProcess`. Standard output and standard error are read
/// as soon as `beginReading()` is called and handed to the registered handlers in order (standard output that arrives before the
/// first standard output handler is kept for it, as Node's paused streams do); the exit handlers run once the process has ended and
/// both pipes have reached end of file (Node's `close`), so every byte is delivered before them. Standard input is written on a
/// serial queue, which gives callers backpressure by awaiting.
final class Subprocess: @unchecked Sendable {
    typealias DataHandler = @Sendable (Data) -> Void
    typealias ExitHandler = @Sendable (FfmpegExitStatus) -> Void

    private struct State {
        var stdoutHandlers: [(id: Int, handler: DataHandler)] = []
        var stderrHandlers: [DataHandler] = []
        var exitHandlers: [ExitHandler] = []
        var nextID = 0
        var killed = false
        var terminated: FfmpegExitStatus?
        var stdoutEOF = false
        var stderrEOF = false
        var delivered = false
        var stdinClosed = false
        var stdoutDestroyed = false
        var reading = false
        // Standard output read before the first handler was added (Node's stream flows from its first `data` listener on).
        var stdoutFlowing = false
        var pendingStdout: [Data] = []
        var pendingStdoutLength = 0
        // A handler is being given the pending output: new output queues behind it, so the order holds.
        var flushingStdout = false
    }

    let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let stdinQueue = DispatchQueue(label: "HomeswiftFFmpeg.stdin")
    /// Only touched on `stdinQueue`.
    nonisolated(unsafe) private var stdinFDClosed = false
    private let state = NIOLockedValueBox(State())
    /// The pipes' read sources by pipe (true for standard output), kept: a source nothing holds is released and
    /// never fires. Its handler looks it up here rather than capturing it, which Linux's non-class-bound
    /// `DispatchSourceRead` would not allow `unowned`, and a strong capture would keep alive.
    private let readSources = NIOLockedValueBox<[Bool: any DispatchSourceRead]>([:])
    private let stdoutBuffer = ReadBuffer()
    private let stderrBuffer = ReadBuffer()
    private let pidBox = NIOLockedValueBox<Int32>(0)

    /// Starts `executable` (a name looked up in `PATH`, or a path). Nothing is read until `beginReading()`. The child keeps
    /// itself alive until the process has ended and its pipes are drained, as a Node child process does.
    static func launch(_ executable: String, arguments: [String]) throws(FfmpegProcessError) -> Subprocess {
        _ = ignoreSIGPIPEOnce
        guard let path = resolveExecutable(executable) else { throw .notFound(executable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        // Close-on-exec on every end: a process another thread spawns meanwhile (tests run many at once) would otherwise
        // inherit them, and a pipe whose write end it holds reaches end of file only when that process ends, so this one's
        // exit waited for the fallback below. macOS spawns with POSIX_SPAWN_CLOEXEC_DEFAULT; Linux's Process does not. The
        // child still gets its own ends: dup2 onto 0, 1 and 2 clears the flag.
        for pipe in [stdin, stdout, stderr] {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] { _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) }
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        #if canImport(Darwin)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        let child = Subprocess(process: process, stdin: stdin.fileHandleForWriting, stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        process.terminationHandler = { process in
            let status: FfmpegExitStatus = process.terminationReason == .uncaughtSignal
                ? FfmpegExitStatus(exitCode: nil, signal: signalName(process.terminationStatus))
                : FfmpegExitStatus(exitCode: process.terminationStatus, signal: nil)
            child.terminated(status)
        }
        do {
            #if canImport(Glibc) || canImport(Musl)
            try withStopSignalsUnblocked { try process.run() }
            #else
            try process.run()
            #endif
        } catch {
            process.terminationHandler = nil
            throw .launchFailed((error as NSError).localizedDescription)
        }
        child.pidBox.withLockedValue { $0 = process.processIdentifier }
        // The parent keeps only its own ends of the pipes.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        return child
    }

    private init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdinHandle = stdin
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
        self.stdinFD = stdin.fileDescriptor
        self.stdoutFD = stdout.fileDescriptor
        self.stderrFD = stderr.fileDescriptor
        // A spurious wake-up of a read source must never block its queue in `read`.
        for fd in [stdoutFD, stderrFD] {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }
    }

    var processIdentifier: Int32 { pidBox.withLockedValue { $0 } }

    // MARK: Handlers

    /// Adds a standard output handler; returns its id for `removeStdoutHandler`. The first one also gets the output read before it.
    @discardableResult
    func addStdoutHandler(_ handler: @escaping DataHandler) -> Int {
        let (id, flush) = state.withLockedValue { state -> (Int, Bool) in
            state.nextID += 1
            state.stdoutHandlers.append((state.nextID, handler))
            state.stdoutFlowing = true
            let flush = !state.pendingStdout.isEmpty && !state.flushingStdout
            if flush { state.flushingStdout = true }
            return (state.nextID, flush)
        }
        if flush { flushPendingStdout() }
        return id
    }

    // Hands the pending output to the handlers, including what arrives meanwhile, then lets reads deliver directly again.
    private func flushPendingStdout() {
        while true {
            let next = state.withLockedValue { state -> ([Data], [DataHandler])? in
                guard !state.pendingStdout.isEmpty, !state.stdoutDestroyed else {
                    state.flushingStdout = false
                    state.pendingStdout = []
                    state.pendingStdoutLength = 0
                    return nil
                }
                defer {
                    state.pendingStdout = []
                    state.pendingStdoutLength = 0
                }
                return (state.pendingStdout, state.stdoutHandlers.map(\.handler))
            }
            guard let (chunks, handlers) = next else { return }
            for chunk in chunks {
                for handler in handlers { handler(chunk) }
            }
        }
    }

    func removeStdoutHandler(_ id: Int) {
        state.withLockedValue { $0.stdoutHandlers.removeAll { $0.id == id } }
    }

    func addStderrHandler(_ handler: @escaping DataHandler) {
        state.withLockedValue { $0.stderrHandlers.append(handler) }
    }

    /// Adds a handler for the end of the process. Returns false, without adding it, when the process has already ended.
    @discardableResult
    func addExitHandler(_ handler: @escaping ExitHandler) -> Bool {
        state.withLockedValue { state in
            guard !state.delivered else { return false }
            state.exitHandlers.append(handler)
            return true
        }
    }

    /// Prepends an exit handler, so it runs before those already registered (Node's `prependOnceListener`).
    @discardableResult
    func prependExitHandler(_ handler: @escaping ExitHandler) -> Bool {
        state.withLockedValue { state in
            guard !state.delivered else { return false }
            state.exitHandlers.insert(handler, at: 0)
            return true
        }
    }

    var hasExited: Bool { state.withLockedValue { $0.delivered || $0.terminated != nil } }

    /// Whether a signal was sent with `kill` (Node's `killed`).
    var killed: Bool { state.withLockedValue { $0.killed } }

    // MARK: Reading

    /// Starts reading standard output and standard error. Call once, after registering the handlers that must see every byte.
    func beginReading() {
        let first = state.withLockedValue { state -> Bool in
            defer { state.reading = true }
            return !state.reading
        }
        guard first else { return }
        // A read source per pipe rather than FileHandle's readabilityHandler: at end of file the source is
        // cancelled from its own handler, and the pipe is closed in the cancel handler, once nothing watches its
        // descriptor (closing it earlier makes libdispatch's event loop crash on Linux).
        for (handle, isStdout) in [(stdoutHandle, true), (stderrHandle, false)] {
            let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: DispatchQueue(label: "HomeswiftFFmpeg.read"))
            source.setEventHandler { self.readable(isStdout: isStdout) }
            source.setCancelHandler { try? handle.close() }
            readSources.withLockedValue { $0[isStdout] = source }
            source.resume()
        }
    }

    /// Reads until the pipe is empty or ends. On Linux the source is edge-triggered: output and the end of file arriving
    /// together are one event, and a single read left the end unseen until the fallback in `terminated` (2 s per exit).
    private func readable(isStdout: Bool) {
        while readOnce(isStdout: isStdout) {}
    }

    /// One read; returns whether data came, so the pipe may hold more.
    private func readOnce(isStdout: Bool) -> Bool {
        guard state.withLockedValue({ isStdout ? !$0.stdoutEOF : !$0.stderrEOF }) else { return false }
        let fd = isStdout ? stdoutFD : stderrFD
        let buffer = isStdout ? stdoutBuffer : stderrBuffer
        var count: Int
        repeat {
            count = buffer.bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        } while count < 0 && errno == EINTR
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return false }
        guard count > 0 else {
            let deliver = state.withLockedValue { state -> Bool in
                if isStdout { state.stdoutEOF = true } else { state.stderrEOF = true }
                return Self.readyToDeliver(&state)
            }
            readSources.withLockedValue { $0[isStdout] }?.cancel()
            if deliver { deliverExit() }
            return false
        }
        let data = Data(buffer.bytes[0..<count])
        if isStdout {
            let handlers = state.withLockedValue { state -> [DataHandler] in
                if state.stdoutDestroyed { return [] }
                // Before the first handler (within bounds), or behind output still being handed over to it: keep it.
                if !state.stdoutFlowing || state.flushingStdout {
                    if state.flushingStdout || state.pendingStdoutLength + data.count <= SUBPROCESS_PENDING_STDOUT_LIMIT {
                        state.pendingStdout.append(data)
                        state.pendingStdoutLength += data.count
                    }
                    return []
                }
                return state.stdoutHandlers.map(\.handler)
            }
            for handler in handlers { handler(data) }
        } else {
            let handlers = state.withLockedValue { $0.stderrHandlers }
            for handler in handlers { handler(data) }
        }
        return true
    }

    /// Stops handing standard output to the handlers (Node's `stdout.destroy()`); the pipe is still drained.
    func destroyStdout() {
        state.withLockedValue { state in
            state.stdoutDestroyed = true
            state.pendingStdout = []
            state.pendingStdoutLength = 0
        }
    }

    /// Whether either output pipe is still watched by its read source.
    var isReadingOutput: Bool { readSources.withLockedValue { $0.values.contains { !$0.isCancelled } } }

    /// Whether the parent's end of standard input is still open.
    var isStdinOpen: Bool { stdinQueue.sync { !stdinFDClosed } }

    // MARK: Exit

    private func terminated(_ status: FfmpegExitStatus) {
        let deliver = state.withLockedValue { state -> Bool in
            state.terminated = status
            return Self.readyToDeliver(&state)
        }
        if deliver {
            deliverExit()
        } else {
            // A grandchild holding the pipes open must not keep the exit from being reported, nor the pipes and
            // their sources (which hold this process) from being let go. Weakly: when the ends of file come meanwhile,
            // nothing is left to do and the process goes at once.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let deliver = self.state.withLockedValue { state -> Bool in
                    state.stdoutEOF = true
                    state.stderrEOF = true
                    return Self.readyToDeliver(&state)
                }
                for source in self.readSources.withLockedValue({ Array($0.values) }) where !source.isCancelled { source.cancel() }
                if deliver { self.deliverExit() }
            }
        }
    }

    private static func readyToDeliver(_ state: inout State) -> Bool {
        guard !state.delivered, state.terminated != nil, state.stdoutEOF, state.stderrEOF else { return false }
        state.delivered = true
        return true
    }

    // Runs once. Every handler is dropped (they often capture the child, which holds them) and standard input is closed, so an
    // ended child frees its descriptors and itself. The read sources are cancelled by then (at end of file, or by the fallback).
    private func deliverExit() {
        let (status, handlers) = state.withLockedValue { state -> (FfmpegExitStatus, [ExitHandler]) in
            defer {
                state.exitHandlers = []
                state.stdoutHandlers = []
                state.stderrHandlers = []
                state.pendingStdout = []
                state.pendingStdoutLength = 0
            }
            return (state.terminated ?? FfmpegExitStatus(exitCode: nil, signal: nil), state.exitHandlers)
        }
        process.terminationHandler = nil
        end()
        for handler in handlers { handler(status) }
    }

    // MARK: Signals

    /// Sends a signal (SIGTERM by default, as Node's `kill()`); false when the process has already ended.
    @discardableResult
    func kill(_ signal: Int32 = SIGTERM) -> Bool {
        state.withLockedValue { state in
            guard state.terminated == nil, !state.delivered else { return false }
            let pid = processIdentifier
            guard pid > 0 else { return false }
            #if canImport(Glibc)
            let result = Glibc.kill(pid, signal)
            #elseif canImport(Musl)
            let result = Musl.kill(pid, signal)
            #else
            let result = Darwin.kill(pid, signal)
            #endif
            if result == 0 { state.killed = true }
            return result == 0
        }
    }

    // MARK: Standard input

    /// Whether standard input still accepts data (Node's `stdin.writable`).
    var isStdinWritable: Bool { state.withLockedValue { !$0.stdinClosed && !$0.delivered } }

    /// Writes to standard input, resuming once the data is in the pipe.
    func write(_ data: Data) async throws(FfmpegProcessError) {
        guard state.withLockedValue({ !$0.stdinClosed }) else { throw .stdinClosed }
        let result: FfmpegProcessError? = await withCheckedContinuation { continuation in
            stdinQueue.async {
                continuation.resume(returning: self.writeAll(data))
            }
        }
        if let result { throw result }
    }

    /// Writes `data`, if any, then closes standard input (Node's `stdin.end(data)`). Errors other than a closed pipe are passed to `onError`.
    func end(_ data: Data? = nil, onError: (@Sendable (FfmpegProcessError) -> Void)? = nil) {
        let first = state.withLockedValue { state -> Bool in
            defer { state.stdinClosed = true }
            return !state.stdinClosed
        }
        guard first else { return }
        stdinQueue.async {
            if let data, !data.isEmpty, let error = self.writeAll(data), error != .stdinClosed {
                onError?(error)
            }
            if !self.stdinFDClosed {
                self.stdinFDClosed = true
                try? self.stdinHandle.close()
            }
        }
    }

    /// Runs on `stdinQueue`.
    private func writeAll(_ data: Data) -> FfmpegProcessError? {
        guard !stdinFDClosed else { return .stdinClosed }
        let fd = stdinFD
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> FfmpegProcessError? in
            guard let base = bytes.baseAddress else { return nil }
            var offset = 0
            while offset < bytes.count {
                #if canImport(Glibc)
                let written = Glibc.write(fd, base + offset, bytes.count - offset)
                #elseif canImport(Musl)
                let written = Musl.write(fd, base + offset, bytes.count - offset)
                #else
                let written = Darwin.write(fd, base + offset, bytes.count - offset)
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno == EPIPE || errno == EBADF ? .stdinClosed : .writeFailed(errno)
                }
                offset += written
            }
            return nil
        }
    }
}
