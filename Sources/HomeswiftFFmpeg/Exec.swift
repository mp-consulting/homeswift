import Foundation
import NIOConcurrencyHelpers

/// The result of an FFmpeg run: the exit code (nil when a signal ended it), standard error and standard output.
public struct ProcessResult: Sendable {
    public var exitCode: Int32?
    public var stderr: Data
    public var stdout: Data

    public init(exitCode: Int32?, stderr: Data, stdout: Data) {
        self.exitCode = exitCode
        self.stderr = stderr
        self.stdout = stdout
    }
}

/// Runs an FFmpeg command to completion and returns what it wrote (exec.ts): probing, snapshots, one-off transcodes.
///
/// ```swift
/// let exec = FfmpegExec(options, commandLineArgs: ["-i", "pipe:0", "-f", "image2pipe", "-c:v", "mjpeg", "pipe:1"], logErrors: false)
/// if let result = await exec.exec(jpegInput, timeout: 5000), result.exitCode == 0 { ... result.stdout ... }
/// ```
public final class FfmpegExec: FfmpegProcess, @unchecked Sendable {
    private let isLoggingErrors: Bool

    private final class Run: Sendable {
        let output = NIOLockedValueBox((stdout: Data(), stderr: Data()))
        private let state = NIOLockedValueBox<(continuation: CheckedContinuation<ProcessResult?, Never>?, isCancelled: Bool)>((nil, false))

        /// Keeps the continuation; false, without keeping it, when the run was already cancelled.
        func begin(_ continuation: CheckedContinuation<ProcessResult?, Never>) -> Bool {
            state.withLockedValue { state in
                guard !state.isCancelled else { return false }
                state.continuation = continuation
                return true
            }
        }

        var isPending: Bool { state.withLockedValue { $0.continuation != nil } }

        var isCancelled: Bool { state.withLockedValue { $0.isCancelled } }

        func settle(_ result: ProcessResult?) {
            state.withLockedValue { state in
                defer { state.continuation = nil }
                return state.continuation
            }?.resume(returning: result)
        }

        /// Marks the run cancelled; true when it was still pending.
        func cancel() -> Bool {
            state.withLockedValue { state in
                state.isCancelled = true
                return state.continuation != nil
            }
        }
    }

    private let run = NIOLockedValueBox<Run?>(nil)

    /// `logErrors: false` keeps a failed run out of the log.
    public init(_ options: FfmpegOptions, commandLineArgs: [String]? = nil, logErrors: Bool = true) {
        self.isLoggingErrors = logErrors
        super.init(options, commandLineArgs: commandLineArgs)
    }

    /// Runs FFmpeg, writing `stdinData` to its standard input first, and returns its exit code and output. nil when FFmpeg could
    /// not be started, when `timeout` (milliseconds) passed first, or when the task was cancelled: FFmpeg is then stopped, so a
    /// stalled input never leaves it running.
    public func exec(_ stdinData: Data? = nil, timeout: Int? = nil) async -> ProcessResult? {
        let run = Run()
        self.run.withLockedValue { $0 = run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard run.begin(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                start()
                guard isRunning else {
                    // The spawn failed (and was logged), or the process already ended and settled.
                    run.settle(nil)
                    return
                }
                // Cancelled while starting: the cancellation handler found no process to stop.
                if run.isCancelled {
                    stop()
                    return
                }
                if let timeout {
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(timeout))
                        guard let self, run.isPending else { return }
                        self.log.debug("FFmpeg command timed out after \(timeout) ms. Terminating.")
                        // Settle first: the exit that stop() causes would otherwise settle with the killed process's result.
                        run.settle(nil)
                        self.stop()
                    }
                }
                if let stdinData {
                    endStdin(stdinData)
                }
            }
        } onCancel: {
            guard run.cancel() else { return }
            log.debug("FFmpeg command cancelled. Terminating.")
            run.settle(nil)
            stop()
        }
    }

    override func configureProcess(_ child: Subprocess, errorHandler: (@Sendable (String) -> Void)?) {
        super.configureProcess(child, errorHandler: errorHandler)
        guard let run = run.withLockedValue({ $0 }) else { return }
        child.addStdoutHandler { data in run.output.withLockedValue { $0.stdout.append(data) } }
        child.addStderrHandler { data in run.output.withLockedValue { $0.stderr.append(data) } }
        // Stop before the base handler sees the exit, so a normal exit is reported as one.
        child.prependExitHandler { [weak self] _ in self?.stop() }
        child.addExitHandler { status in
            let output = run.output.withLockedValue { $0 }
            run.settle(ProcessResult(exitCode: status.exitCode, stderr: output.stderr, stdout: output.stdout))
        }
    }

    override func logFfmpegError(_ status: FfmpegExitStatus) {
        guard isLoggingErrors else { return }
        super.logFfmpegError(status)
    }
}
