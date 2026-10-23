import Foundation
import HomeswiftAI
import Logging
import Testing

@testable import HomeswiftPlugin

@Suite struct LogArchiveTests {
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-logs-\(UUID().uuidString)")
    }

    func files(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    @Test func keepsLinesAndReadsATimeRange() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = LogArchive(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<10 {
            archive.append(LogBuffer.Line(date: start.addingTimeInterval(Double(index) * 60), level: index == 3 ? .warning : .info, label: "Lamps", text: "line \(index)"))
        }
        // Read back straight away: the pending batch is written first.
        let range = archive.lines(from: start.addingTimeInterval(120), to: start.addingTimeInterval(300), limit: 100)
        #expect(range.map(\.text) == ["line 2", "line 3", "line 4", "line 5"])
        #expect(range[1].level == .warning)
        #expect(range[0].date == start.addingTimeInterval(120))
        #expect(archive.lines(from: start, to: start.addingTimeInterval(3600), limit: 3).map(\.text) == ["line 7", "line 8", "line 9"])
        let file = try #require(files(directory).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    /// A line's payload reaches the disk only while saving is on, a choice kept for the next start.
    @Test func savesPayloadsOnlyWhenAsked() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = LogArchive(directory: directory)
        #expect(!archive.savesDetails)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ index: Int) -> LogBuffer.Line {
            LogBuffer.Line(date: start.addingTimeInterval(Double(index)), level: .debug, label: "Govee", text: "message event {…} 1.2 KB", details: #"{"device":"\#(index)"}"#)
        }
        archive.append(line(0))
        try archive.setSavesDetails(true)
        archive.append(line(1))
        let read = archive.lines(from: start, to: start.addingTimeInterval(10), limit: 10)
        #expect(read.map(\.details) == [nil, #"{"device":"1"}"#])
        #expect(read.map(\.text) == ["message event {…} 1.2 KB", "message event {…} 1.2 KB"])

        let settings = directory.appendingPathComponent(LogArchive.settingsName)
        #expect((try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int) == 0o600)
        #expect(LogArchive(directory: directory).savesDetails)
        try archive.setSavesDetails(false)
        #expect(!LogArchive(directory: directory).savesDetails)
        // The settings file is not a segment: pruning and reading leave it alone.
        #expect(!files(directory).contains(LogArchive.settingsName))
    }

    @Test func startsASegmentPerDayAndPastTheSizeLimit() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = LogArchive(directory: directory, days: 3650, maxSegmentSize: 300, maxTotalSize: 1_000_000)
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(23 * 3600)
        for index in 0..<4 {
            archive.append(LogBuffer.Line(date: start.addingTimeInterval(Double(index)), level: .info, label: "L", text: String(repeating: "x", count: 100)))
            archive.flush()
        }
        let sameDay = files(directory).count
        #expect(sameDay >= 2)   // ~150 bytes a line, 300 a segment
        archive.append(LogBuffer.Line(date: start.addingTimeInterval(3600 + 5), level: .info, label: "L", text: "after midnight"))
        archive.flush()
        #expect(files(directory).count == sameDay + 1)
        #expect(archive.lines(from: start, to: start.addingTimeInterval(7200), limit: 100).count == 5)
    }

    @Test func dropsTheOldestSegmentsPastTheTotalSize() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = LogArchive(directory: directory, days: 3650, maxSegmentSize: 200, maxTotalSize: 600)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<20 {
            archive.append(LogBuffer.Line(date: start.addingTimeInterval(Double(index)), level: .info, label: "L", text: "line \(index) " + String(repeating: "y", count: 120)))
            archive.flush()
        }
        let sizes = files(directory).map { (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0).path)[.size] as? Int) ?? 0 }
        #expect(sizes.reduce(0, +) <= 600 + 200)
        let kept = archive.lines(from: start, to: start.addingTimeInterval(100), limit: 100)
        #expect(kept.last?.text.hasPrefix("line 19") == true)
        #expect(kept.first?.text.hasPrefix("line 0 ") == false)
    }

    @Test func theBufferReadsRangesFromItsArchive() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = LogBuffer(capacity: 2, archive: LogArchive(directory: directory))
        // On a whole second: the file keeps seconds since 1970, which a date from now may not round-trip exactly.
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        for index in 0..<5 { buffer.append(LogBuffer.Line(date: start.addingTimeInterval(Double(index)), level: .info, label: "L", text: "\(index)")) }
        #expect(buffer.all.map(\.text) == ["3", "4"])
        #expect(buffer.lines(from: start, to: start.addingTimeInterval(10), limit: 10).map(\.text) == ["0", "1", "2", "3", "4"])
        // Without an archive, memory answers.
        let memory = LogBuffer(capacity: 2)
        for index in 0..<5 { memory.append(LogBuffer.Line(date: start.addingTimeInterval(Double(index)), level: .info, label: "L", text: "\(index)")) }
        #expect(memory.lines(from: start, to: start.addingTimeInterval(10), limit: 10).map(\.text) == ["3", "4"])
    }

    @Test func theRingKeepsTheLatestLinesInOrder() {
        let buffer = LogBuffer(capacity: 5)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<13 {
            buffer.append(LogBuffer.Line(date: start.addingTimeInterval(Double(index)), level: index % 3 == 0 ? .warning : .info, label: "L", text: "\(index)"))
        }
        #expect(buffer.all.map(\.text) == ["8", "9", "10", "11", "12"])
        #expect(buffer.recent(3).map(\.text) == ["10", "11", "12"])
        #expect(buffer.recent(10).map(\.text) == ["8", "9", "10", "11", "12"])
        #expect(buffer.recent(10, level: .warning).map(\.text) == ["9", "12"])
        #expect(buffer.recent(1, matching: { $0.text.hasPrefix("1") }).map(\.text) == ["12"])
        #expect(buffer.recent(0).isEmpty)
    }

    @Test func timestampsAreWhatTheFormatStyleWrites() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let date = Date(timeIntervalSince1970: Double.random(in: -2_000_000_000...4_000_000_000, using: &generator))
            #expect(Timestamp.iso8601(date) == date.formatted(.iso8601))
            #expect(Timestamp.iso8601(date, separator: UInt8(ascii: " ")) == date.formatted(.iso8601.dateTimeSeparator(.space)))
        }
        #expect(Timestamp.iso8601(Date(timeIntervalSince1970: 1_792_747_644.999)) == "2026-10-23T09:27:24Z")
    }

    /// Segments written before the archive wrote its lines itself (JSONEncoder, keys in any order) still read.
    /// A range skips rows before parsing them: by their time, read from the bytes whatever the key order, and by what
    /// `mayMatch` sees in the raw row.
    @Test func skipsRowsBeforeParsing() throws {
        #expect(LogArchive.time(of: Data(#"{"l":"info","m":"\"t\":5 in the text","n":"x","t":1800000000.25}"#.utf8)) == 1_800_000_000.25)
        #expect(LogArchive.time(of: Data(#"{"t":1800000000,"l":"info","m":"a","n":"x"}"#.utf8)) == 1_800_000_000)
        #expect(LogArchive.time(of: Data("not a row".utf8)) == nil)

        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = LogArchive(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, text) in ["Dolphin M400 started", "Govee message", "dolphin m400 cleaning ⚡️", "Govee again"].enumerated() {
            archive.append(LogBuffer.Line(date: start.addingTimeInterval(Double(index)), level: .info, label: "Plugins", text: text))
        }
        var looked = 0
        let found = archive.lines(from: start.addingTimeInterval(1), to: start.addingTimeInterval(10), limit: 10, mayMatch: { row in
            looked += 1
            return TextSearch.containsAny(row, asciiCaseless: ["dolphin m400"])
        })
        #expect(found.map(\.text) == ["dolphin m400 cleaning ⚡️"])
        // The first row is before the range: its time ends the scan before anything looks at it.
        #expect(looked == 3)
    }

    @Test func readsLinesInEitherKeyOrder() throws {
        let line = LogBuffer.Line(date: Date(timeIntervalSince1970: 1_800_000_000.25), level: .warning, label: "Dyson \"Pure\"", text: "a\nb é")
        #expect(LogArchive.line(LogArchive.entry(line).dropLast()) == line)
        let legacy = Data(#"{"t":1800000000.25,"l":"warning","n":"Dyson \"Pure\"","m":"a\nb é"}"#.utf8)
        #expect(LogArchive.line(legacy) == line)
    }
}
