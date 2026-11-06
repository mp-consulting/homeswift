import Foundation

/// The Location (GLOSSARY.md): a Bridge Setting, where the home is, for the times of the sun and the weather.
/// config.json keeps it as `bridge.location`; changing it needs no restart. Plugins read it with `context.location`.
public struct Location: Codable, Sendable, Equatable {
    /// Degrees north, -90 to 90.
    public var latitude: Double
    /// Degrees east, -180 to 180.
    public var longitude: Double
    /// A name for the person to recognise it ("Home"), never sent anywhere.
    public var name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    /// Whether the coordinates are on Earth.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    /// The longest name kept.
    public static let nameLimit = 64
}
