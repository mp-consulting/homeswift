import Foundation
import Logging
import NIOConcurrencyHelpers

/// The last lines of the log, kept in memory for tools that read or search them, and on disk when it has an
/// archive (`LogArchive`), for a time range further back.
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
    public let archive: LogArchive?
    private let state = NIOLockedValueBox<(lines: [Line], observers: [UUID: @Sendable (Line) -> Void])>(([], [:]))

    public init(capacity: Int = 5000, archive: LogArchive? = nil) {
        self.capacity = capacity
        self.archive = archive
    }

    public func append(_ line: Line) {
        let observers = state.withLockedValue { state in
            state.lines.append(line)
            if state.lines.count > capacity { state.lines.removeFirst(state.lines.count - capacity) }
            return Array(state.observers.values)
        }
        archive?.append(line)
        for observer in observers { observer(line) }
    }

    /// The last `count` lines, oldest first, at or above `level`, that `matching` keeps.
    public func recent(_ count: Int, level: Logger.Level = .trace, matching: ((Line) -> Bool)? = nil) -> [Line] {
        state.withLockedValue { Array($0.lines.filter { $0.level >= level && matching?($0) != false }.suffix(max(0, count))) }
    }

    public var all: [Line] { state.withLockedValue { $0.lines } }

    /// The lines from `from` to `to`, oldest first, at most the latest `limit`: from the archive when there is
    /// one, from memory otherwise.
    public func lines(from: Date, to: Date, limit: Int, matching: ((Line) -> Bool)? = nil) -> [Line] {
        if let archive { return archive.lines(from: from, to: to, limit: limit, matching: matching) }
        return Array(all.filter { $0.date >= from && $0.date <= to && matching?($0) != false }.suffix(limit))
    }

    /// Calls `observer` with every line from now on, until the observation is cancelled.
    @discardableResult
    public func observe(_ observer: @escaping @Sendable (Line) -> Void) -> Observation {
        let id = UUID()
        state.withLockedValue { $0.observers[id] = observer }
        return Observation { [self] in _ = state.withLockedValue { $0.observers.removeValue(forKey: id) } }
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
