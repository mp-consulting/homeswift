import Foundation
import Logging

/// The log on disk, so the web UI can show a past hour or yesterday after the memory buffer moved on or the
/// bridge restarted.
///
/// Lines go to segments named after their first line's time (`homeswift-20261022-221500.jsonl`, a JSON object
/// per line, owner-only). A segment ends at `maxSegmentSize` or at midnight; the oldest go once all of them
/// pass `maxTotalSize` or are older than `days`. Writes are batched on a queue of their own, once a second or
/// every 64 KB, so logging never waits for the disk. A time range opens only the segments that overlap it,
/// newest first, reads each from its end, and stops at the range's start or once it has `limit` lines.
public final class LogArchive: @unchecked Sendable {
    public let directory: URL
    public let days: Int
    public let maxSegmentSize: Int
    public let maxTotalSize: Int

    private let queue = DispatchQueue(label: "homeswift.log-archive")
    // Confined to `queue`.
    private let encoder = JSONEncoder()
    private var pending = Data()
    private var flushScheduled = false
    private var segment: (handle: FileHandle, ends: Date, size: Int)?

    static let prefix = "homeswift-"
    static let flushBytes = 64 * 1024

    public init(directory: URL, days: Int = 7, maxSegmentSize: Int = 8 * 1024 * 1024, maxTotalSize: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.days = days
        self.maxSegmentSize = maxSegmentSize
        self.maxTotalSize = maxTotalSize
    }

    private struct Entry: Codable {
        var t: Double
        var l: String
        var n: String
        var m: String
    }

    public func append(_ line: LogBuffer.Line) {
        queue.async { [self] in
            guard var data = try? encoder.encode(Entry(t: line.date.timeIntervalSince1970, l: line.level.rawValue, n: line.label, m: line.text)) else { return }
            data.append(0x0A)
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
        let stamp = Self.names().string(from: date)
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
        let formatter = Self.names()
        return names.compactMap { name -> (URL, Date)? in
            guard name.hasPrefix(Self.prefix), name.hasSuffix(".jsonl"),
                  let start = formatter.date(from: String(name.dropFirst(Self.prefix.count).prefix(15))) else { return nil }
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
    public func lines(from: Date, to: Date, limit: Int, matching: ((LogBuffer.Line) -> Bool)? = nil) -> [LogBuffer.Line] {
        flush()
        let all = segments()
        let decoder = JSONDecoder()
        var chunks: [[LogBuffer.Line]] = []   // newest segment first, each newest line first
        var count = 0
        // A segment covers from its start to the next one's.
        scan: for (index, segment) in all.enumerated().reversed() {
            let end = index + 1 < all.count ? all[index + 1].start : .distantFuture
            guard segment.start <= to, end >= from else { continue }
            guard let data = try? Data(contentsOf: segment.url) else { continue }
            var found: [LogBuffer.Line] = []
            for row in data.split(separator: 0x0A).reversed() {
                guard let entry = try? decoder.decode(Entry.self, from: row) else { continue }
                let date = Date(timeIntervalSince1970: entry.t)
                if date > to { continue }
                if date < from { chunks.append(found); break scan }
                let line = LogBuffer.Line(date: date, level: Logger.Level(rawValue: entry.l) ?? .info, label: entry.n, text: entry.m)
                if let matching, !matching(line) { continue }
                found.append(line)
                count += 1
                if count >= limit { chunks.append(found); break scan }
            }
            chunks.append(found)
        }
        return chunks.joined().reversed()
    }

    /// `20261022-221500`, in UTC: names sort by time whatever the time zone.
    static func names() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}
