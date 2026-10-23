import Foundation
import Homeswift
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers

/// The log on disk, so the web UI can show a past hour or yesterday after the memory buffer moved on or the
/// bridge restarted.
///
/// Lines go to segments named after their first line's time (`homeswift-20261022-221500.jsonl`, a JSON object
/// per line, owner-only). A segment ends at `maxSegmentSize` or at midnight; the oldest go once all of them
/// pass `maxTotalSize` or are older than `days`. Writes are batched on a queue of their own, once a second or
/// every 64 KB, so logging never waits for the disk. A time range opens only the segments that overlap it,
/// newest first, reads each from its end, and stops at the range's start or once it has `limit` lines.
///
/// A line's details (the JSON `LogDetails` took out of it, secrets masked) are written only while
/// `savesDetails` is on, a choice kept in `settings.json` beside the segments; otherwise the disk has the
/// line's marker (`{…} 1.4 KB`) and the details live in memory only, with the latest lines.
public final class LogArchive: @unchecked Sendable {
    public let directory: URL
    public let days: Int
    public let maxSegmentSize: Int
    public let maxTotalSize: Int

    private let queue = DispatchQueue(label: "homeswift.log-archive")
    // Confined to `queue`.
    private var pending = Data()
    private var flushScheduled = false
    private var segment: (handle: FileHandle, ends: Date, size: Int)?
    private let saving: NIOLockedValueBox<Bool>

    static let prefix = "homeswift-"
    static let settingsName = "settings.json"
    static let flushBytes = 64 * 1024

    public init(directory: URL, days: Int = 7, maxSegmentSize: Int = 8 * 1024 * 1024, maxTotalSize: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.days = days
        self.maxSegmentSize = maxSegmentSize
        self.maxTotalSize = maxTotalSize
        let settings = (try? Data(contentsOf: directory.appendingPathComponent(Self.settingsName))).flatMap { try? JSONValue(data: $0) }
        saving = NIOLockedValueBox(settings?["saveDetails"]?.boolValue ?? false)
    }

    /// Whether lines go to disk with their details.
    public var savesDetails: Bool { saving.withLockedValue { $0 } }

    /// Turns saving the details on or off, for the lines from now on, and keeps the choice for the next start.
    public func setSavesDetails(_ on: Bool) throws {
        try OwnerOnlyFile.write(JSONValue.object(["saveDetails": .bool(on)]).encoded(), to: directory.appendingPathComponent(Self.settingsName))
        saving.withLockedValue { $0 = on }
    }

    /// A line as a JSON object: `t` (seconds since 1970), `l` (level), `n` (label), `m` (text), and `d` (its
    /// details, with `withDetails`). Written and read as `JSONValue` rather than through `JSONEncoder`, which cost
    /// more than the rest of logging a line.
    static func entry(_ line: LogBuffer.Line, withDetails: Bool = false) -> Data {
        var object: [String: JSONValue] = ["t": .number(line.date.timeIntervalSince1970), "l": .string(line.level.rawValue), "n": .string(line.label), "m": .string(line.text)]
        if withDetails, let details = line.details { object["d"] = .string(details) }
        var data = JSONValue.object(object).encoded()
        data.append(0x0A)
        return data
    }

    static func line(_ row: Data) -> LogBuffer.Line? {
        row.withUnsafeBytes { line($0) }
    }

    /// The row's members are read in place, without a dictionary or an array for each of the thousands of rows a
    /// range has.
    static func line(_ row: UnsafeRawBufferPointer) -> LogBuffer.Line? {
        var time: Double?, level: String?, label: String?, text: String?, details: String?
        do {
            try JSONValue.forEachMember(of: row) { key, value in
                switch key {
                case "t": time = value.doubleValue
                case "l": level = value.stringValue
                case "n": label = value.stringValue
                case "m": text = value.stringValue
                case "d": details = value.stringValue
                default: break
                }
            }
        } catch {
            return nil
        }
        guard let time, let level, let label, let text else { return nil }
        return LogBuffer.Line(date: Date(timeIntervalSince1970: time), level: Logger.Level(rawValue: level) ?? .info, label: label, text: text, details: details)
    }

    public func append(_ line: LogBuffer.Line) {
        let withDetails = line.details != nil && savesDetails
        queue.async { [self] in
            let data = Self.entry(line, withDetails: withDetails)
            // A line of a new day starts a new segment: what is pending belongs to the old one.
            if let open = segment, line.date >= open.ends {
                write()
                close()
            }
            if segment == nil { segment = start(at: line.date) }
            pending.append(data)
            if pending.count >= Self.flushBytes {
                write()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    flushScheduled = false
                    write()
                }
            }
        }
    }

    /// Writes what is pending; at shutdown, so the last lines are kept.
    public func flush() {
        queue.sync { write() }
    }

    /// Removes every segment, and what is pending: the next line starts a new one.
    public func removeAll() {
        queue.sync {
            pending.removeAll()
            close()
            for segment in segments() { try? FileManager.default.removeItem(at: segment.url) }
        }
    }

    private func write() {
        guard !pending.isEmpty, var open = segment else { return }
        try? open.handle.write(contentsOf: pending)
        open.size += pending.count
        pending.removeAll(keepingCapacity: true)
        segment = open
        if open.size >= maxSegmentSize { close() }
    }

    private func close() {
        try? segment?.handle.close()
        segment = nil
    }

    /// A new segment for lines from `date` to the end of its day, after making room for it.
    private func start(at date: Date) -> (handle: FileHandle, ends: Date, size: Int)? {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune()
        let stamp = Self.names.string(from: date)
        var url = directory.appendingPathComponent("\(Self.prefix)\(stamp).jsonl")
        // Two segments in one second (a burst past the size limit): the next name.
        var suffix = 1
        while manager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(Self.prefix)\(stamp)-\(suffix).jsonl")
            suffix += 1
        }
        let midnight = Calendar.current.startOfDay(for: date)
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: url.path),
              let ends = Calendar.current.date(byAdding: .day, value: 1, to: midnight) else { return nil }
        return (handle, ends, 0)
    }

    /// The segments, oldest first, with when each starts.
    private func segments() -> [(url: URL, start: Date)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (URL, Date)? in
            guard name.hasPrefix(Self.prefix), name.hasSuffix(".jsonl"),
                  let start = Self.names.date(from: String(name.dropFirst(Self.prefix.count).prefix(15))) else { return nil }
            return (directory.appendingPathComponent(name), start)
        }.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
    }

    /// Removes the oldest segments while they are older than `days` or the segments pass `maxTotalSize`.
    private func prune() {
        var all = segments()
        var sizes = all.map { (try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.size] as? Int) ?? 0 }
        var total = sizes.reduce(0, +)
        let oldest = Date().addingTimeInterval(-Double(days) * 86_400)
        while !all.isEmpty, total > maxTotalSize || (all.count > 1 && all[1].start < oldest) {
            try? FileManager.default.removeItem(at: all.removeFirst().url)
            total -= sizes.removeFirst()
        }
    }

    /// The lines from `from` to `to` that `matching` keeps, oldest first; the latest `limit` when there are more.
    ///
    /// A row is parsed only once its time, read from its bytes, is in the range and `mayMatch`, given the row's raw
    /// JSON text, says it could match (an accessory's name in it): parsing was most of a range's cost.
    public func lines(
        from: Date, to: Date, limit: Int, matching: ((LogBuffer.Line) -> Bool)? = nil, mayMatch: ((String) -> Bool)? = nil
    ) -> [LogBuffer.Line] {
        flush()
        let all = segments()
        var chunks: [[LogBuffer.Line]] = []   // newest segment first, each newest line first
        var count = 0
        // A segment covers from its start to the next one's.
        scan: for (index, segment) in all.enumerated().reversed() {
            let end = index + 1 < all.count ? all[index + 1].start : .distantFuture
            guard segment.start <= to, end >= from else { continue }
            guard let data = try? Data(contentsOf: segment.url) else { continue }
            var found: [LogBuffer.Line] = []
            // Row by row from the end, in place: splitting the segment into rows first cost as much as parsing them.
            let done = data.withUnsafeBytes { bytes -> Bool in
                var end = bytes.count
                while end > 0 {
                    var start = end
                    while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
                    defer { end = start - 1 }
                    guard start < end else { continue }
                    let row = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
                    if let time = Self.time(of: row) {
                        if time > to.timeIntervalSince1970 { continue }
                        if time < from.timeIntervalSince1970 { return true }
                    }
                    if let mayMatch, !mayMatch(String(decoding: row, as: UTF8.self)) { continue }
                    guard let line = Self.line(row) else { continue }
                    if line.date > to { continue }
                    if line.date < from { return true }
                    if let matching, !matching(line) { continue }
                    found.append(line)
                    count += 1
                    if count >= limit { return true }
                }
                return false
            }
            chunks.append(found)
            if done { break scan }
        }
        // Oldest first, in one array.
        var lines: [LogBuffer.Line] = []
        lines.reserveCapacity(count)
        for chunk in chunks.reversed() { lines.append(contentsOf: chunk.reversed()) }
        return lines
    }

    /// A row's `t`, read from its bytes without parsing the row: inside a JSON string every quote is escaped, so the
    /// bytes `"t":` are the key wherever it is. nil when there is none (not a row).
    static func time(of row: Data) -> Double? {
        row.withUnsafeBytes { time(of: $0) }
    }

    static func time(of raw: UnsafeRawBufferPointer) -> Double? {
        let bytes = raw.bindMemory(to: UInt8.self)
        guard bytes.count >= 5 else { return nil }
        // Rows are written with sorted keys, `t` last: from the end it is found at once.
        var index = bytes.count - 4
        while index >= 0 {
            if bytes[index] == UInt8(ascii: "\""), bytes[index + 1] == UInt8(ascii: "t"), bytes[index + 2] == UInt8(ascii: "\""), bytes[index + 3] == UInt8(ascii: ":") { break }
            index -= 1
        }
        guard index >= 0 else { return nil }
        var end = index + 4
        while end < bytes.count, bytes[end] != UInt8(ascii: ","), bytes[end] != UInt8(ascii: "}") { end += 1 }
        // Parsed as JSON, in place: no text to make for it.
        return (try? JSONValue(bytes: UnsafeRawBufferPointer(rebasing: raw[(index + 4)..<end])))?.doubleValue
    }

    /// Segment names' times.
    static let names = SegmentNames()

    /// `20261022-221500`, in UTC: names sort by time whatever the time zone. The formatter is made once (making one
    /// cost a time range more than reading its rows) and used by one caller at a time, formatters not being Sendable.
    final class SegmentNames: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter
        }()

        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter.string(from: date)
        }

        func date(from string: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return formatter.date(from: string)
        }
    }
}
