import Foundation
import HomeswiftPlugin

// The Location (GLOSSARY.md), a Bridge Setting: config.json's `bridge.location`, where the home is, for the times of
// the sun (scenes' sunrise and sunset) and the weather. Written like the Tariffs: no restart, the running
// configuration takes it at once, and plugins read it through `context.location`.

extension HomeswiftCatalog {
    /// The Location, with the next sunrise and sunset there; `location` is null when none is set.
    public func locationJSON(now: Date = Date()) -> JSONValue {
        Self.locationJSON(host.configuration.location, now: now)
    }

    static func locationJSON(_ location: Location?, now: Date) -> JSONValue {
        guard let location else { return ["location": .null, "nextSunrise": .null, "nextSunset": .null] }
        let next = { (event: Solar.Event) -> JSONValue in
            Solar.next(event, latitude: location.latitude, longitude: location.longitude, after: now).map { .string(Timestamp.iso8601($0)) } ?? .null
        }
        return ["location": (try? JSONValue(encoding: location)) ?? .null, "nextSunrise": next(.sunrise), "nextSunset": next(.sunset)]
    }

    /// A Location from a request: latitude, longitude and a name; nil for null or an empty object, which forgets it;
    /// anything else is refused.
    static func location(from value: JSONValue) throws -> Location? {
        if value.isNull { return nil }
        guard let object = value.objectValue else { throw CatalogError("A Location is an object: latitude, longitude and a name; null forgets it") }
        if object.isEmpty { return nil }
        let unknown = object.keys.filter { !["latitude", "longitude", "name"].contains($0) }.sorted()
        guard unknown.isEmpty else { throw CatalogError("Not part of a Location: \(unknown.joined(separator: ", "))") }
        guard let latitude = object["latitude"]?.doubleValue, let longitude = object["longitude"]?.doubleValue else { throw CatalogError(locationRange) }
        let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { String($0.prefix(Location.nameLimit)) }
        return try checked(Location(latitude: latitude, longitude: longitude, name: name))
    }

    static let locationRange = "A Location needs latitude (-90 to 90) and longitude (-180 to 180)"

    static func checked(_ location: Location) throws -> Location {
        guard location.isValid else { throw CatalogError(locationRange) }
        return location
    }

    /// Writes the Location from a request (`location(from:)`) and answers it as `locationJSON` does, with what the
    /// write did.
    public func updateLocation(_ value: JSONValue, dryRun: Bool = false, by writer: ConfigWriter = .person) async throws -> JSONValue {
        try await writeLocation(try Self.location(from: value), dryRun: dryRun, by: writer)
    }

    /// Writes the Location (`bridge.location`; nil removes it), with no restart. The same Location again writes nothing.
    /// No config.json backup: the map saves on every click, and the last 20 backups are for changes worth going back to.
    func writeLocation(_ location: Location?, dryRun: Bool = false, by writer: ConfigWriter = .person) async throws -> JSONValue {
        var answer = Self.locationJSON(location, now: Date()).objectValue ?? [:]
        guard dryRun || location != host.configuration.location else { return .object(answer) }
        let applied = try await updateBridgeBlock(dryRun: dryRun, by: writer, backup: false) { bridge in
            if let location { bridge["location"] = try JSONValue(encoding: location) } else { bridge.removeValue(forKey: "location") }
        }
        Self.copyApplied(applied, into: &answer)
        return .object(answer)
    }

    /// Moves the location an older scenes.json kept (set on the Scenes page) to the Location, once: when config.json
    /// has none yet, it becomes the Location; either way scenes.json forgets it.
    public func migrateSceneLocation() async {
        guard let old = home.scenes.value.location else { return }
        do {
            if host.configuration.location == nil {
                _ = try await writeLocation(try Self.checked(Location(latitude: old.lat, longitude: old.lon, name: old.name)))
                logger.info("Moved the scenes' location to the Location, a Bridge Setting (config.json's bridge.location)")
            }
            try home.scenes.update { $0.location = nil }
        } catch {
            logger.warning("Could not move the scenes' location to the Location: \(error)")
        }
    }

    // MARK: get_settings and update_settings

    /// The Bridge Settings that change without a restart, for get_settings (bridge: true), from a `locationJSON` answer.
    static func bridgeLiveSettingsJSON(_ located: JSONValue) -> JSONValue {
        [
            "settings": ["location": located["location"] ?? .null],
            "fields": ["location": [
                "type": ["object", "null"], "title": "Location", "core": true,
                "description": "Where the home is, for sunrise and sunset and the weather. null when none is set.",
                "required": ["latitude", "longitude"], "additionalProperties": false,
                "properties": [
                    "latitude": ["type": "number", "minimum": -90, "maximum": 90],
                    "longitude": ["type": "number", "minimum": -180, "maximum": 180],
                    "name": ["type": "string", "maxLength": .number(Double(Location.nameLimit))],
                ],
            ]],
            "nextSunrise": located["nextSunrise"] ?? .null, "nextSunset": located["nextSunset"] ?? .null,
        ]
    }

    /// update_settings with bridge: true. Only `location` is one: the bridge's name, port and setup code restart
    /// homeswift, and stay update_bridge_settings'.
    func updateBridgeLiveSettings(_ settings: [String: JSONValue], dryRun: Bool, by writer: ConfigWriter) async throws -> JSONValue {
        let unknown = settings.keys.filter { $0 != "location" }.sorted()
        guard unknown.isEmpty else {
            throw CatalogError("Not a Bridge Setting update_settings changes: \(unknown.joined(separator: ", ")) (the name, port and setup code are update_bridge_settings')")
        }
        guard let location = settings["location"] else { return Self.bridgeLiveSettingsJSON(locationJSON()) }
        // The written Location, dry run or not, and what the write did.
        let written = try await updateLocation(location, dryRun: dryRun, by: writer)
        var answer = Self.bridgeLiveSettingsJSON(written).objectValue ?? [:]
        Self.copyApplied(written, into: &answer)
        answer["changed"] = ["location"]
        return .object(answer)
    }
}
