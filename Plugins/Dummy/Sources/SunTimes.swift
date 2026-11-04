import Foundation

/// The sun's times of a day for a place, by the formulas of Astronomy Answers' "Position of the Sun" that SunCalc
/// follows: the solar transit of the Julian cycle nearest the instant, and the hour angle at which the sun's centre
/// is at a given altitude. Accurate to about a minute away from the poles.
enum SunTimes {
    private static let rad = Double.pi / 180
    private static let dayMs = 86_400_000.0
    private static let j1970 = 2_440_588.0
    private static let j2000 = 2_451_545.0
    private static let j0 = 0.0009
    private static let obliquity = rad * 23.4397

    /// The altitude of the sun's centre, in degrees, and whether the event is when the sun rises through it (morning)
    /// or sets through it (evening).
    static func definition(_ event: SunEvent) -> (altitude: Double, rising: Bool) {
        switch event {
        case .sunrise: (-0.833, true)
        case .sunset: (-0.833, false)
        case .dawn: (-6, true)
        case .dusk: (-6, false)
        case .goldenHour: (6, false)
        case .night: (-18, false)
        }
    }

    /// The event of the solar day around `date`, or nil when the sun does not reach that altitude (polar day or night).
    static func time(of event: SunEvent, on date: Date, latitude: Double, longitude: Double) -> Date? {
        let lw = rad * -longitude
        let phi = rad * latitude
        let d = date.timeIntervalSince1970 * 1000 / dayMs - 0.5 + j1970 - j2000
        let n = (d - j0 - lw / (2 * .pi)).rounded()
        let ds = j0 + lw / (2 * .pi) + n
        let m = rad * (357.5291 + 0.98560028 * ds)
        let centre = rad * (1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m))
        let l = m + centre + rad * 102.9372 + .pi
        let declination = asin(sin(obliquity) * sin(l))
        let noon = j2000 + ds + 0.0053 * sin(m) - 0.0069 * sin(2 * l)
        let (altitude, rising) = definition(event)
        let cosine = (sin(altitude * rad) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
        guard cosine >= -1, cosine <= 1 else { return nil }
        let w = acos(cosine)
        let a = j0 + (w + lw) / (2 * .pi) + n
        let set = j2000 + a + 0.0053 * sin(m) - 0.0069 * sin(2 * l)
        let julian = rising ? noon - (set - noon) : set
        return Date(timeIntervalSince1970: (julian + 0.5 - j1970) * dayMs / 1000)
    }

    /// The next time a schedule fires (spec 7.3): today's event plus the offset, or, when that is not in the future,
    /// the event computed for the same time tomorrow plus the offset. Nil when the event does not happen.
    static func next(_ event: SunEvent, offsetMinutes: Double, latitude: Double, longitude: Double, after now: Date) -> Date? {
        let offset = offsetMinutes * 60
        if let today = time(of: event, on: now, latitude: latitude, longitude: longitude)?.addingTimeInterval(offset), today > now {
            return today
        }
        guard let tomorrow = time(of: event, on: now.addingTimeInterval(86_400), latitude: latitude, longitude: longitude)?.addingTimeInterval(offset),
              tomorrow > now else { return nil }
        return tomorrow
    }
}
