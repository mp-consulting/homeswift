import Foundation
import Logging
import NIOConcurrencyHelpers
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The most recent FFmpeg standard error lines kept for diagnostics: sessions can run for days, and the reason for a failure is
/// in the last lines.
let FFMPEG_STDERR_LOG_MAX_LINES = 100

/// The command line with the password of every URL replaced (`rtsp://user:secret@host` becomes `rtsp://user:***@host`) and SRTP
/// parameters (the session keys) hidden, joined with spaces.
public func redactCommandLine(_ commandLineArgs: [String]) -> String {
    var redacted: [String] = []
    var hideNext = false
    for argument in commandLineArgs {
        if hideNext {
            redacted.append("***")
            hideNext = false
            continue
        }
        redacted.append(redactURLPasswords(argument))
        hideNext = argument == "-srtp_out_params" || argument == "-srtp_in_params"
    }
    return redacted.joined(separator: " ")
}

/// `\b([a-z][a-z0-9+.-]*:\/\/[^:/?#@\s]*):[^@/?#\s]*@` (case-insensitive) replaced by `$1:***@`.
func redactURLPasswords(_ text: String) -> String {
    guard text.contains("://") else { return text }
    return text.replacing(#/\b([a-zA-Z][a-zA-Z0-9+.\-]*:\/\/[^:\/?#@\s]*):[^@\/?#\s]*@/#) { match in
        match.output.1 + ":***@"
    }
}

/// Matches runs of non-printable characters (Unicode category C) in FFmpeg's standard error, which become line breaks.
private func replacingNonPrintable(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    var inRun = false
    for scalar in text.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            if !inRun { result.append("\n") }
            inRun = true
        default:
            result.append(scalar)
            inRun = false
        }
    }
    return String(result)
}

/// Spawns and supervises an FFmpeg process (process.ts): the command line is logged (without passwords or keys), standard error
/// is collected line by line (the last 100 lines are kept in `stderrLog` and logged when FFmpeg fails), standard input and
/// output are available, and `stop()` asks FFmpeg to quit (`q`, then SIGTERM) with a SIGKILL failsafe after
/// `FFMPEG_INPUT_TIMEOUT`.
///
/// ```swift
/// let process = FfmpegProcess(options, commandLineArgs: ["-i", "input.mp4", "-f", "null", "-"])
/// process.start()
/// try await process.waitForStart()
/// process.stop()
/// ```
///
/// One instance can be started again after its process ended (or while it winds down): the late exit of a superseded process
/// never touches the new one.
public class FfmpegProcess: @unchecked Sendable {
    /// The FFmpeg configuration.
    public let options: FfmpegOptions
    let log: Logger
    /// Verbose FFmpeg logging, from the codec support.
    let isVerbose: Bool

    enum Readiness {
        case pending
        case started
        case failed(String)
    }

    struct BaseState {
        var commandLineArgs: [String] = []
        var child: Subprocess?
        var hasError = false
        var isEnded = false
        var isStarted = false
        var isLogging = false
        var stderrLog: [String] = []
        var stderrBuffer = ""
        var killTimer: Task<Void, Never>?
        // TypeScript keeps the handle of its kill timer after clearing it, and tells a normal exit by it: set by stop(), reset by start().
        var stopRequested = false
        var readiness = Readiness.pending
        var startWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        var nextWaiter = 0
    }

    let base = NIOLockedValueBox(BaseState())

    /// Prepares a process; nothing runs until `start()`.
    public init(_ options: FfmpegOptions, commandLineArgs: [String]? = nil) {
        self.options = options
        self.log = options.log
        self.isVerbose = options.codecSupport.verbose
        if let commandLineArgs {
            base.withLockedValue { $0.commandLineArgs = commandLineArgs }
        }
    }

    // Node's garbage collector never kills a child process; Swift releases objects deterministically, and a process nobody can
    // stop any more would run forever. So a running FFmpeg is ended with its object (SIGTERM, then SIGKILL as stop() does).
    deinit {
        let (child, timer) = base.withLockedValue { ($0.child, $0.killTimer) }
        timer?.cancel()
        guard let child, !child.hasExited else { return }
        child.end()
        child.kill(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(FFMPEG_INPUT_TIMEOUT)) { child.kill(SIGKILL) }
    }

    /// The command line FFmpeg runs with.
    public internal(set) var commandLineArgs: [String] {
        get { base.withLockedValue { $0.commandLineArgs } }
        set { base.withLockedValue { $0.commandLineArgs = newValue } }
    }

    // Prepares a new process lifecycle and logs the command line.
    private func prepareProcess(_ commandLineArgs: [String]?) {
        let (arguments, isLogging) = base.withLockedValue { state -> ([String], Bool) in
            if let commandLineArgs { state.commandLineArgs = commandLineArgs }
            // A command line with a log level asks for FFmpeg's output.
            state.isLogging = state.commandLineArgs.contains("-loglevel")
            state.isStarted = false
            state.isEnded = false
            // Fresh diagnostics: a reused instance never reports a previous process's output.
            state.stderrLog = []
            state.stderrBuffer = ""
            return (state.commandLineArgs, state.isLogging)
        }
        let message: Logger.Message =
            "FFmpeg command (version: \(options.codecSupport.ffmpegVersion)): \(options.codecSupport.ffmpegExec) \(redactCommandLine(arguments))"
        if isLogging || isVerbose || options.debug {
            log.info(message)
        } else {
            log.debug(message)
        }
    }

    /// Starts FFmpeg, with a new command line if one is given. `errorHandler` is called with a message when FFmpeg cannot start or
    /// ends unexpectedly.
    public func start(_ commandLineArgs: [String]? = nil, errorHandler: (@Sendable (String) -> Void)? = nil) {
        prepareProcess(commandLineArgs)
        // A kill timer armed for a previous process must not strike the replacement.
        let arguments = base.withLockedValue { state -> [String] in
            state.killTimer?.cancel()
            state.killTimer = nil
            state.stopRequested = false
            if case .failed = state.readiness { state.readiness = .pending }
            if case .started = state.readiness { state.readiness = .pending }
            return state.commandLineArgs
        }
        let child: Subprocess
        do throws(FfmpegProcessError) {
            child = try Subprocess.launch(options.codecSupport.ffmpegExec, arguments: arguments)
        } catch {
            let message = error.description
            log.error("FFmpeg failed to start: \(message).")
            base.withLockedValue { $0.child = nil }
            errorHandler?("Error: " + message)
            failStart("Error: " + message)
            return
        }
        base.withLockedValue { $0.child = child }
        configureProcess(child, errorHandler: errorHandler)
        child.beginReading()
    }

    /// Wires a newly started process: standard error and the exit. Subclasses add their own handlers after calling this.
    func configureProcess(_ child: Subprocess, errorHandler: (@Sendable (String) -> Void)?) {
        child.addStderrHandler { [weak self] data in self?.receivedStderr(data) }
        child.addExitHandler { [weak self] status in self?.processExited(child, status: status, errorHandler: errorHandler) }
    }

    private func receivedStderr(_ data: Data) {
        // FFmpeg always writes to standard error once it runs, whether or not it uses standard input and output: our sign it started.
        let (justStarted, lines, show) = base.withLockedValue { state -> (Bool, [String], Bool) in
            var justStarted = false
            if !state.isStarted {
                state.isStarted = true
                state.isEnded = false
                justStarted = true
            }
            // Non-printable characters become line breaks, which keeps the log readable.
            state.stderrBuffer += replacingNonPrintable(String(decoding: data, as: UTF8.self))
            var lines: [String] = []
            while let newline = state.stderrBuffer.firstIndex(of: "\n") {
                let line = String(state.stderrBuffer[..<newline])
                state.stderrBuffer = String(state.stderrBuffer[state.stderrBuffer.index(after: newline)...])
                Self.appendStderrLog(line, to: &state)
                lines.append(line)
            }
            return (justStarted, lines, state.isLogging || isVerbose || options.debug)
        }
        if justStarted {
            log.debug("FFmpeg process started.")
            resolveStart()
        }
        if show {
            for line in lines { log.info("\(redactURLPasswords(line))") }
        }
    }

    private static func appendStderrLog(_ line: String, to state: inout BaseState) {
        state.stderrLog.append(line)
        if state.stderrLog.count > FFMPEG_STDERR_LOG_MAX_LINES {
            state.stderrLog.removeFirst()
        }
    }

    private func processExited(_ child: Subprocess, status: FfmpegExitStatus, errorHandler: (@Sendable (String) -> Void)?) {
        enum Outcome {
            case normal
            case killed(String?)
            case failed
        }
        let outcome = base.withLockedValue { state -> Outcome? in
            // The exit of a process superseded by a restart must not touch the new one.
            guard state.child === child else { return nil }
            state.killTimer?.cancel()
            state.killTimer = nil
            state.isStarted = false
            state.isEnded = true
            // We keep stderrLog for post-mortem diagnostics.
            state.child = nil
            if state.stopRequested && status.exitCode == 0 {
                return .normal
            }
            if (status.exitCode == nil || status.exitCode == 255) && child.killed {
                return .killed(status.signal)
            }
            state.hasError = true
            if !state.stderrBuffer.isEmpty {
                Self.appendStderrLog(state.stderrBuffer + "\n", to: &state)
                state.stderrBuffer = ""
            }
            return .failed
        }
        guard let outcome else { return }
        let logPrefix = "FFmpeg process ended "
        switch outcome {
        case .normal:
            log.debug("\(logPrefix)(Normal).")
        case .killed(let signal):
            log.debug("\(logPrefix)\(signal == "SIGKILL" ? "(Killed)." : "(Expected).")")
        case .failed:
            logFfmpegError(status)
            let message = options.name() + ": " + logPrefix + " unexpectedly with exit code \(status.exitCode.map(String.init) ?? "null") and signal \(status.signal ?? "null")."
            errorHandler?(message)
            failStart(message)
        }
        if case .failed = outcome {} else { failStart(logPrefix + "before it started.") }
    }

    /// Stops FFmpeg: `q` on standard input (unless FFmpeg reads its input there), closes its input and output, sends SIGTERM, and
    /// SIGKILL after `FFMPEG_INPUT_TIMEOUT` if it is still running.
    func stopProcess() {
        let (child, arguments) = base.withLockedValue { ($0.child, $0.commandLineArgs) }
        // Nothing to kill when the process has already ended.
        guard let child else { return }
        if !arguments.contains("pipe:0") {
            child.end(Data("q".utf8)) { [log] error in log.error("FFmpeg error: \(error).") }
        }
        child.end()
        child.destroyStdout()
        base.withLockedValue { state in
            state.killTimer?.cancel()
            state.stopRequested = true
            state.killTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(FFMPEG_INPUT_TIMEOUT))
                guard !Task.isCancelled, let self else { return }
                self.base.withLockedValue { $0.child }?.kill(SIGKILL)
            }
        }
        child.kill(SIGTERM)
    }

    /// Stops the FFmpeg process.
    public func stop() {
        stopProcess()
    }

    /// Logs why FFmpeg ended unexpectedly: the exit code or signal, the command line and the last lines of standard error.
    func logFfmpegError(_ status: FfmpegExitStatus) {
        let exitCode = status.exitCode.map { "an exit code of \($0)" } ?? ""
        let separator = status.exitCode != nil && status.signal != nil ? " and " : ""
        let signal = status.signal.map { "a signal received of \($0)" } ?? ""
        log.error("FFmpeg process ended unexpectedly with \(exitCode)\(separator)\(signal).")
        log.error(
            "FFmpeg (\(options.codecSupport.ffmpegVersion)) command that errored out was: \(options.codecSupport.ffmpegExec) \(redactCommandLine(commandLineArgs))"
        )
        for line in stderrLog {
            log.error("\(redactURLPasswords(line))")
        }
    }

    // MARK: Start

    /// Waits until FFmpeg has started (it wrote to standard error): the counterpart of the TypeScript `StreamRequestCallback`.
    /// Throws when FFmpeg could not be started or ended before starting.
    public func waitForStart() async throws {
        let id = base.withLockedValue { state -> Int in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result = base.withLockedValue { state -> Result<Void, any Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    switch state.readiness {
                    case .started: return .success(())
                    case .failed(let message): return .failure(FfmpegProcessError.endedBeforeStart(message))
                    case .pending:
                        state.startWaiters[id] = continuation
                        return nil
                    }
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            base.withLockedValue { $0.startWaiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Whether `waitForStart()` would still wait: FFmpeg has neither started nor failed since `start()`.
    var isStartPending: Bool {
        base.withLockedValue { if case .pending = $0.readiness { true } else { false } }
    }

    private func resolveStart() {
        let waiters = base.withLockedValue { state -> [CheckedContinuation<Void, any Error>] in
            state.readiness = .started
            defer { state.startWaiters = [:] }
            return Array(state.startWaiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func failStart(_ message: String) {
        let waiters = base.withLockedValue { state -> [CheckedContinuation<Void, any Error>] in
            guard case .pending = state.readiness else { return [] }
            state.readiness = .failed(message)
            defer { state.startWaiters = [:] }
            return Array(state.startWaiters.values)
        }
        for waiter in waiters { waiter.resume(throwing: FfmpegProcessError.endedBeforeStart(message)) }
    }

    // MARK: State

    /// Whether FFmpeg ended unexpectedly.
    public var hasError: Bool { base.withLockedValue { $0.hasError } }

    /// Whether the FFmpeg process has ended.
    public var isEnded: Bool { base.withLockedValue { $0.isEnded } }

    func setEnded() { base.withLockedValue { $0.isEnded = true } }

    /// Whether the FFmpeg process has started (written to standard error).
    public var isStarted: Bool { base.withLockedValue { $0.isStarted } }

    /// The last 100 lines FFmpeg wrote to standard error, for the current or most recent process.
    public var stderrLog: [String] { base.withLockedValue { $0.stderrLog } }

    /// Whether a process is running (TypeScript's non-null `ffmpegProcess`).
    public var isRunning: Bool { base.withLockedValue { $0.child != nil } }

    /// The process identifier of the running process.
    public var processIdentifier: Int32? { base.withLockedValue { $0.child?.processIdentifier } }

    var currentChild: Subprocess? { base.withLockedValue { $0.child } }

    // MARK: Standard input and output

    /// Writes to FFmpeg's standard input, returning once the data is in the pipe (backpressure).
    public func writeStdin(_ data: Data) async throws {
        guard let child = currentChild else { throw FfmpegProcessError.notRunning }
        try await child.write(data)
    }

    /// Writes `data`, if any, and closes FFmpeg's standard input (Node's `stdin.end(data)`).
    public func endStdin(_ data: Data? = nil) {
        currentChild?.end(data) { [log] error in log.error("FFmpeg error: \(error).") }
    }

    /// Whether standard input accepts data (Node's `stdin.writable`).
    public var isStdinWritable: Bool { currentChild?.isStdinWritable ?? false }

    /// A standard output listener of the running process.
    public struct StdoutListener: Sendable {
        let child: Subprocess
        let id: Int
    }

    /// Calls `handler` with each chunk of FFmpeg's standard output (Node's `stdout.on('data')`). nil when no process runs. The first
    /// listener of a process also gets what FFmpeg wrote before it was added (up to 4 MB), as a Node stream that nobody read yet.
    @discardableResult
    public func onStdout(_ handler: @escaping @Sendable (Data) -> Void) -> StdoutListener? {
        guard let child = currentChild else { return nil }
        return StdoutListener(child: child, id: child.addStdoutHandler(handler))
    }

    /// Removes a standard output listener (Node's `stdout.off('data')`).
    public func offStdout(_ listener: StdoutListener) {
        listener.child.removeStdoutHandler(listener.id)
    }

    /// Calls `handler` once when the running process ends, after the process state is updated (Node's
    /// `ffmpegProcess.once('exit')`). False when no process runs.
    @discardableResult
    public func onceExit(_ handler: @escaping @Sendable (FfmpegExitStatus) -> Void) -> Bool {
        currentChild?.addExitHandler(handler) ?? false
    }
}
