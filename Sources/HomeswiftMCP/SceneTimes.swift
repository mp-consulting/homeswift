import Foundation

/// Sunrise and sunset without a dependency, Glass UI's solar.ts: the sunrise equation (as NOAA and Wikipedia
/// give it), accurate to a minute or two away from the poles.
public enum Solar {
    public enum Event: String, Sendable, Codable { case sunrise, sunset }

    private static let radians = Double.pi / 180
    private static let dayMilliseconds = 86_400_000.0
    private static let julian1970 = 2440587.5
    private static let julian2000 = 2451545.0
    /// The sun's centre is 0.833° below the horizon at sunrise (refraction and its radius).
    private static let altitude = -0.833

    private static func toJulian(_ ms: Double) -> Double { ms / dayMilliseconds + julian1970 }
    private static func fromJulian(_ j: Double) -> Double { ((j - julian1970) * dayMilliseconds).rounded() }

    /// Sunrise and sunset of the solar day around the given instant's UTC date at that longitude; nil for
    /// either when the sun does not rise or set that day (polar night, midnight sun).
    public static func times(on day: Date, latitude: Double, longitude: Double) -> (sunrise: Date?, sunset: Date?) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.startOfDay(for: day).timeIntervalSince1970 * 1000
        let n = (toJulian(midnight + dayMilliseconds / 2) - julian2000).rounded()
        let meanNoon = n - longitude / 360
        // JavaScript's % keeps the dividend's sign, as truncatingRemainder does.
        let anomaly = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
        let m = anomaly * radians
        let centre = 1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m)
        let eclipticLongitude = (anomaly + centre + 180 + 102.9372).truncatingRemainder(dividingBy: 360) * radians
        let transit = julian2000 + meanNoon + 0.0053 * sin(m) - 0.0069 * sin(2 * eclipticLongitude)
        let declination = asin(sin(eclipticLongitude) * sin(23.4397 * radians))
        let cosHourAngle = (sin(altitude * radians) - sin(latitude * radians) * sin(declination)) / (cos(latitude * radians) * cos(declination))
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return (nil, nil) }
        let hourAngle = acos(cosHourAngle) / radians
        return (Date(timeIntervalSince1970: fromJulian(transit - hourAngle / 360) / 1000), Date(timeIntervalSince1970: fromJulian(transit + hourAngle / 360) / 1000))
    }

    /// The next time after `now` of an event plus an offset in minutes, or nil when it does not happen in the
    /// next few days (near the poles).
    public static func next(_ event: Event, offsetMinutes: Int = 0, latitude: Double, longitude: Double, after now: Date = Date()) -> Date? {
        var next: Date?
        for days in -1...3 {
            let times = times(on: now.addingTimeInterval(Double(days) * 86_400), latitude: latitude, longitude: longitude)
            guard let at = event == .sunrise ? times.sunrise : times.sunset else { continue }
            let shifted = at.addingTimeInterval(Double(offsetMinutes) * 60)
            if shifted > now, next.map({ shifted < $0 }) ?? true { next = shifted }
        }
        return next
    }

    /// The event on `now`'s local date (the UTC days around it can hold it), or nil.
    public static func onLocalDay(_ event: Event, of now: Date, latitude: Double, longitude: Double, calendar: Calendar = .current) -> Date? {
        for days in [0, -1, 1] {
            let times = times(on: now.addingTimeInterval(Double(days) * 86_400), latitude: latitude, longitude: longitude)
            if let at = event == .sunrise ? times.sunrise : times.sunset, calendar.isDate(at, inSameDayAs: now) { return at }
        }
        return nil
    }

    public static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

/// A cron expression as Glass UI's scenes take them: five fields (minute, hour, day of month, month, day of
/// week; Sunday is 0 or 7), or six with seconds first, which are ignored: automations run on the minute.
/// Each field is `*`, numbers, ranges `a-b`, lists and steps (`*/15`, `1-5/2`). When both the day of month and
/// the day of week are restricted, either matching is enough, as cron does.
public struct CronExpression: Sendable, Equatable {
    let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let anyDay: Bool, anyWeekday: Bool

    public init?(_ text: String) {
        var fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if fields.count == 6 { fields.removeFirst() }
        guard fields.count == 5 else { return nil }
        func parse(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
            var values: Set<Int> = []
            for part in field.split(separator: ",", omittingEmptySubsequences: false) {
                let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
                guard pieces.count <= 2 else { return nil }
                var step = 1
                if pieces.count == 2 {
                    guard let parsed = Int(pieces[1]), parsed > 0 else { return nil }
                    step = parsed
                }
                let base = pieces[0]
                var bounds: ClosedRange<Int>
                if base == "*" {
                    bounds = range
                } else if let dash = base.firstIndex(of: "-") {
                    guard let low = Int(base[..<dash]), let high = Int(base[base.index(after: dash)...]), low <= high else { return nil }
                    bounds = low...high
                } else {
                    guard let value = Int(base) else { return nil }
                    bounds = value...(pieces.count == 2 ? range.upperBound : value)
                }
                guard range.contains(bounds.lowerBound), range.contains(bounds.upperBound) else { return nil }
                values.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
            }
            return values.isEmpty ? nil : values
        }
        guard let minutes = parse(fields[0], 0...59), let hours = parse(fields[1], 0...23), let days = parse(fields[2], 1...31),
              let months = parse(fields[3], 1...12), let weekdays = parse(fields[4], 0...7) else { return nil }
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = Set(weekdays.map { $0 % 7 })
        anyDay = fields[2] == "*"
        anyWeekday = fields[4] == "*"
    }

    /// Whether it runs at this local minute.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = parts.minute, let hour = parts.hour, let day = parts.day, let month = parts.month, let weekday = parts.weekday else { return false }
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let dayMatches = days.contains(day), weekdayMatches = weekdays.contains(weekday - 1)
        if anyDay || anyWeekday { return (anyDay || dayMatches) && (anyWeekday || weekdayMatches) }
        return dayMatches || weekdayMatches
    }
}
