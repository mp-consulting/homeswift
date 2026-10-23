import Foundation
import HomeswiftPlugin

/// `homeswift logs`: the bridge's log on disk (`logs/` under the storage path), in the console's format. For a
/// bridge whose output goes nowhere a person reads it: a Synology package, a service.
enum LogsCommand {
    static let usage = "usage: homeswift logs [-n <lines>] [-f]   the last lines (100), then the new ones with -f"

    static func run(arguments: [String], storagePath: URL) throws {
        var count = 100
        var follow = false
        var arguments = arguments.makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "-f", "--follow":
                follow = true
            case "-n", "--lines":
                guard let value = arguments.next().flatMap(Int.init), value >= 0 else { throw CommandError(usage) }
                count = value
            default:
                throw CommandError(usage)
            }
        }
        let archive = LogArchive(directory: storagePath.appendingPathComponent("logs"))
        var printed = count == 0 ? [] : archive.lines(from: .distantPast, to: Date(), limit: count)
        printed.forEach(write)
        guard follow else { return }
        // The bridge writes in batches; what it wrote since the last line printed, skipping the lines of that
        // same instant already shown.
        while true {
            Thread.sleep(forTimeInterval: 1)
            let since = printed.last?.date ?? Date()
            let shown = printed.reversed().prefix { $0.date == since }.count
            let lines = archive.lines(from: since, to: .distantFuture, limit: 10_000)
            guard lines.count > shown else { continue }
            lines.dropFirst(shown).forEach(write)
            printed = lines
        }
    }

    private static func write(_ line: LogBuffer.Line) {
        var text = "[\(HomeswiftLogHandler.time(line.date))] [\(line.label)] "
        if let tag = line.level.tag { text += tag + " " }
        say(text + line.text)
    }
}
