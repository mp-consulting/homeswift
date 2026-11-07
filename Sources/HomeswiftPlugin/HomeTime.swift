import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Home Time (GLOSSARY.md, docs/adr/0008-rules-are-written-in-home-time.md): the time zone the home is in. Tariffs,
/// energy by the hour, Automations and the log all run on the process's time zone, so Home Time is that zone: the
/// host's, unless config.json's `bridge.timeZone` names another, which `apply` makes the process's at start.
public enum HomeTime {
    /// The host's own time zone, as it was before `apply`.
    public static let host: TimeZone = TimeZone.current

    /// Home Time: the process's time zone.
    public static var zone: TimeZone { TimeZone.current }

    /// Whether `identifier` is an IANA time zone this system knows.
    public static func isValid(_ identifier: String) -> Bool {
        !identifier.isEmpty && TimeZone(identifier: identifier) != nil
    }

    /// Makes the time zone `identifier` names the process's (TZ for C and the log's dates, Foundation's default for
    /// `TimeZone.current` and `Calendar.current`); nil leaves the host's. Answers the zone applied, nil when none was.
    /// Call it once at start, before anything keeps a calendar.
    @discardableResult
    public static func apply(_ identifier: String?) -> TimeZone? {
        _ = host
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return nil }
        setenv("TZ", identifier, 1)
        tzset()
        NSTimeZone.default = zone
        return zone
    }

    /// A zone without daylight saving whose offset is zero (UTC, GMT, Etc/UTC): what a container runs in unless told
    /// otherwise. Not London, which shares its offset in winter.
    public static func isUniversal(_ zone: TimeZone, at date: Date = Date()) -> Bool {
        zone.secondsFromGMT(for: date) == 0 && zone.nextDaylightSavingTimeTransition(after: date) == nil
    }
}
