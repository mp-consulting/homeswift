import Foundation
import HomeswiftPlugin
import Logging

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

    private func write(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?) {
        let time = Date().formatted(date: .numeric, time: .standard)
        var text = "[\(time)] [\(label)] "
        if let tag = level.tag { text += tag + " " }
        var line = message.description
        let merged = self.metadata.merging(metadata ?? [:]) { $1 }
        if !merged.isEmpty {
            line += " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        text += line
        (standardError ? FileHandle.standardError : FileHandle.standardOutput).write(Data((text + "\n").utf8))
        buffer?.append(LogBuffer.Line(level: level, label: label, text: line))
    }
}
