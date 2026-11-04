import Foundation
import HomeswiftFFmpeg
import Logging

/// The log of one camera: every line starts with `[<camera name>] ` and goes through `Masking`, and the camera's `debug`
/// option promotes its debug lines to info, as the original does (section 10).
struct CameraLog: Sendable {
    let logger: Logger
    let name: String
    let promotesDebug: Bool

    func debug(_ message: @autoclosure () -> String) {
        if promotesDebug {
            logger.info("\(line(message()))")
        } else {
            logger.debug("\(line(message()))")
        }
    }

    func info(_ message: @autoclosure () -> String) { logger.info("\(line(message()))") }
    func warning(_ message: @autoclosure () -> String) { logger.warning("\(line(message()))") }
    func error(_ message: @autoclosure () -> String) { logger.error("\(line(message()))") }

    private func line(_ message: String) -> String {
        "[\(name)] " + Masking.text(message)
    }
}

/// Runs FFmpeg for one camera: `videoProcessor`, and the options `HomeswiftFFmpeg` logs with. Its own lines (command lines,
/// standard error) show only with the camera's `debug`, as the original's; failures always do.
struct FFmpegTools: Sendable {
    let options: FfmpegOptions
    /// For the two-way audio process, which `debugReturn` makes verbose.
    let returnOptions: FfmpegOptions
    let executable: String
    let capabilities: FFmpegCapabilities

    init(executable: String, capabilities: FFmpegCapabilities, name: String, logger: Logger, debug: Bool, debugReturn: Bool) {
        self.executable = executable
        self.capabilities = capabilities
        func options(verbose: Bool) -> FfmpegOptions {
            var processLogger = logger
            processLogger[metadataKey: "camera"] = "\(name)"
            if !verbose { processLogger.logLevel = max(logger.logLevel, .error) }
            let codecs = FfmpegCodecs(ffmpegExec: executable, log: processLogger, ffmpegVersion: "")
            var config = FfmpegOptionsConfig(codecSupport: codecs, debug: verbose, hardwareDecoding: false, hardwareTranscoding: false, log: processLogger, name: { name })
            // Stopping writes `q`, then kills FFmpeg if it is still running two seconds later.
            config.inputTimeout = 2000
            return FfmpegOptions(config)
        }
        self.options = options(verbose: debug)
        self.returnOptions = options(verbose: debugReturn)
    }
}

/// Logs how long FFmpeg took (snapshots, first frames): debug below 5 seconds, a warning below 22, an error beyond.
func logTiming(_ log: CameraLog, _ elapsed: Duration, _ message: String, slowSuffix: String = "") {
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let text = "\(message) in \(String(format: "%.1f", seconds))s"
    switch seconds {
    case ..<5: log.debug(text)
    case ..<22: log.warning(text)
    default: log.error(text + slowSuffix)
    }
}
