import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Homebridge-style lines: `[10/21/2026, 10:00:00 AM] [Elgato Key Lights] Discovered Key Light Air`.
///
/// Writes straight to the file descriptor so lines reach log files (`brew services`) at once, and keeps
/// the line in the buffer the MCP tools read.
struct HomeswiftLogHandler: LogHandler {
    let label: String
    var logLevel: Logger.Level
    var metadata: Logger.Metadata = [:]
    let buffer: LogBuffer?
    /// Log to standard error instead, when standard output carries a protocol (`homeswift mcp`).
    var standardError = false

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

    /// The last second's text: lines come in bursts, and the format style costs more than the rest of a line.
    private static let clock = NIOLockedValueBox<(second: Int, text: String)>((-1, ""))

    static func time(_ date: Date) -> String {
        let second = Int(date.timeIntervalSince1970.rounded(.down))
        if let text = clock.withLockedValue({ $0.second == second ? $0.text : nil }) { return text }
        let text = date.formatted(date: .numeric, time: .standard)
        clock.withLockedValue { $0 = (second, text) }
        return text
    }

    private func write(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?) {
        let time = Self.time(Date())
        var text = "[\(time)] [\(label)] "
        if let tag = level.tag { text += tag + " " }
        var line = message.description
        let merged = self.metadata.merging(metadata ?? [:]) { $1 }
        if !merged.isEmpty {
            line += " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        // A JSON payload leaves the line for a marker; it stays with the buffered line, to expand in the web UI.
        let split = LogDetails.split(line)
        text += split?.text ?? line
        (standardError ? FileHandle.standardError : FileHandle.standardOutput).write(Data((text + "\n").utf8))
        buffer?.append(LogBuffer.Line(level: level, label: label, text: split?.text ?? line, details: split?.details))
    }
}
