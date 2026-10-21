import Foundation
import Logging

/// Homebridge-style lines: `[10/21/2026, 10:00:00 AM] [Elgato Key Lights] Discovered Key Light Air`.
///
/// Writes straight to the file descriptor so lines reach log files (`brew services`) at once.
struct HomeswiftLogHandler: LogHandler {
    let label: String
    var logLevel: Logger.Level
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        write(level: event.level, message: event.message, metadata: event.metadata)
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        write(level: level, message: message, metadata: metadata)
    }

    private func write(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?) {
        let time = Date().formatted(date: .numeric, time: .standard)
        var text = "[\(time)] [\(label)] "
        switch level {
        case .trace, .debug: text += "[\(level.rawValue.uppercased())] "
        case .warning: text += "[WARNING] "
        case .error, .critical: text += "[ERROR] "
        case .info, .notice: break
        }
        text += message.description
        let merged = self.metadata.merging(metadata ?? [:]) { $1 }
        if !merged.isEmpty {
            text += " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
