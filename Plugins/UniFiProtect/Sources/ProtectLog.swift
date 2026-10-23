import Foundation
import Logging

/// The plugin's log lines as the Homebridge plugin writes them: `Controller: Device: message`. With the
/// block's `debug` option, debug lines come out at the info level, as Homebridge showed them; otherwise they
/// are debug lines, which `homeswift -D` shows.
struct ProtectLog: Sendable {
    let logger: Logger
    let prefix: String
    let debugAll: Bool

    init(logger: Logger, prefix: String = "", debugAll: Bool = false) {
        self.logger = logger
        self.prefix = prefix
        self.debugAll = debugAll
    }

    /// The same log with `name: ` before every line.
    func named(_ name: String) -> ProtectLog {
        ProtectLog(logger: logger, prefix: prefix + name + ": ", debugAll: debugAll)
    }

    func debug(_ message: @autoclosure () -> String) {
        if debugAll {
            logger.info("\(prefix)\(message())")
        } else {
            logger.debug("\(prefix)\(message())")
        }
    }

    func info(_ message: @autoclosure () -> String) { logger.info("\(prefix)\(message())") }
    func warning(_ message: @autoclosure () -> String) { logger.warning("\(prefix)\(message())") }
    func error(_ message: @autoclosure () -> String) { logger.error("\(prefix)\(message())") }
}
