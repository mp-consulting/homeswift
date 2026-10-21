import Foundation
import Logging
import NIOConcurrencyHelpers

/// The last lines of the log, kept in memory for tools that read or search them.
public final class LogBuffer: Sendable {
    public struct Line: Sendable, Equatable {
        public var date: Date
        public var level: Logger.Level
        public var label: String
        public var text: String

        public init(date: Date = Date(), level: Logger.Level, label: String, text: String) {
            self.date = date
            self.level = level
            self.label = label
            self.text = text
        }
    }

    public let capacity: Int
    private let state = NIOLockedValueBox<(lines: [Line], observers: [@Sendable (Line) -> Void])>(([], []))

    public init(capacity: Int = 5000) {
        self.capacity = capacity
    }

    public func append(_ line: Line) {
        let observers = state.withLockedValue { state in
            state.lines.append(line)
            if state.lines.count > capacity { state.lines.removeFirst(state.lines.count - capacity) }
            return state.observers
        }
        for observer in observers { observer(line) }
    }

    /// The last `count` lines, oldest first, at or above `level`.
    public func recent(_ count: Int, level: Logger.Level = .trace) -> [Line] {
        state.withLockedValue { Array($0.lines.filter { $0.level >= level }.suffix(max(0, count))) }
    }

    public var all: [Line] { state.withLockedValue { $0.lines } }

    public func observe(_ observer: @escaping @Sendable (Line) -> Void) {
        state.withLockedValue { $0.observers.append(observer) }
    }
}

extension LogBuffer.Line {
    /// `[2026-10-21 10:00:00Z] [Elgato Key Lights] [WARNING] message`.
    public var formatted: String {
        "[\(date.formatted(.iso8601.dateTimeSeparator(.space)))] [\(label)] " + level.tag.map { $0 + " " }.orEmpty + text
    }
}

extension Logger.Level {
    /// `[WARNING]`, `[ERROR]`, `[DEBUG]` or `[TRACE]` in a log line; nothing for info and notice.
    public var tag: String? {
        switch self {
        case .trace, .debug: "[\(rawValue.uppercased())]"
        case .warning: "[WARNING]"
        case .error, .critical: "[ERROR]"
        case .info, .notice: nil
        }
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
