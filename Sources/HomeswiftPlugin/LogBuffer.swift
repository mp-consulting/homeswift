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
        /// JSON taken out of the text (`LogDetails`), compact, its secrets masked.
        public var details: String?

        public init(date: Date = Date(), level: Logger.Level, label: String, text: String, details: String? = nil) {
            self.date = date
            self.level = level
            self.label = label
            self.text = text
            self.details = details
        }
    }

    public let capacity: Int
    public let archive: LogArchive?
    private let state: NIOLockedValueBox<State>

    /// The lines in a ring: appending never moves the others.
    private struct State {
        var ring: [Line] = []
        /// Where the oldest line is once the ring is full.
        var start = 0
        var observers: [UUID: @Sendable (Line) -> Void] = [:]

        mutating func append(_ line: Line, capacity: Int) {
            if ring.count < capacity {
                ring.append(line)
            } else if capacity > 0 {
                ring[start] = line
                start = (start + 1) % capacity
            }
        }

        /// Oldest first.
        var ordered: [Line] { start == 0 ? ring : Array(ring[start...] + ring[..<start]) }

        /// The line `offset` places back from the newest.
        func fromNewest(_ offset: Int) -> Line { ring[(start + ring.count - 1 - offset) % ring.count] }
    }

    public init(capacity: Int = 5000, archive: LogArchive? = nil) {
        self.capacity = capacity
        self.archive = archive
        state = NIOLockedValueBox(State())
    }

    public func append(_ line: Line) {
        let observers = state.withLockedValue { state in
            state.append(line, capacity: capacity)
            return state.observers.isEmpty ? [] : Array(state.observers.values)
        }
        archive?.append(line)
        for observer in observers { observer(line) }
    }

    /// The last `count` lines, oldest first, at or above `level`, that `matching` keeps.
    public func recent(_ count: Int, level: Logger.Level = .trace, matching: ((Line) -> Bool)? = nil) -> [Line] {
        // From the newest back, until there are enough: the filter runs on as few lines as it can.
        state.withLockedValue { state in
            var found: [Line] = []
            var offset = 0
            while found.count < count, offset < state.ring.count {
                let line = state.fromNewest(offset)
                if line.level >= level, matching?(line) != false { found.append(line) }
                offset += 1
            }
            return found.reversed()
        }
    }

    public var all: [Line] { state.withLockedValue { $0.ordered } }

    /// The lines from `from` to `to`, oldest first, at most the latest `limit`: from the archive when there is
    /// one, from memory otherwise.
    /// `mayMatch` lets the archive skip rows before parsing them (`LogArchive.lines`).
    public func lines(from: Date, to: Date, limit: Int, matching: ((Line) -> Bool)? = nil, mayMatch: ((String) -> Bool)? = nil) -> [Line] {
        if let archive { return archive.lines(from: from, to: to, limit: limit, matching: matching, mayMatch: mayMatch) }
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
        "[\(Timestamp.iso8601(date, separator: UInt8(ascii: " ")))] [\(label)] " + level.tag.map { $0 + " " }.orEmpty + text
    }

    /// `formatted`, then the details on the next line, indented: for whoever reads a payload too (the Assistant).
    public var formattedWithDetails: String {
        details.map { "\(formatted)\n    \($0)" } ?? formatted
    }

    /// The label, the text and the details, for a search that looks inside payloads too.
    public var searchable: String {
        details.map { "\(label) \(text) \($0)" } ?? "\(label) \(text)"
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
