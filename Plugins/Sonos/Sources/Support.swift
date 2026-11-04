import Foundation

/// The plugin, weakly: what accessories' handlers call back into without keeping it alive.
struct PluginReference: Sendable {
    weak var plugin: SonosPlugin?
}

enum SleepTimer {
    /// `00:29:41` → 1781; `""` or anything else → 0.
    static func seconds(_ text: String?) -> Int {
        let parts = (text ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// 5400 → `01:30:00`.
    static func text(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

enum LastSeen {
    static let never = "n/a"

    /// As JavaScript's `Date.toString()` begins: `Wed Nov 04 2026 10:15:30`, in local time.
    static func text(_ date: Date?) -> String {
        guard let date else { return never }
        return formatter.string(from: date)
    }

    /// Made once: a formatter is costly to build, and every message from a player updates Last Seen.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss"
        return formatter
    }()
}
