import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// Each user's choices for the pages: the appearance (`theme`, `wallpaper`, `temperatureUnit`) and the Status
/// page's widgets (`dashboard`: their `order` and those `hidden`). Kept in `ui-preferences.json` next to
/// config.json, owner-only, so they follow the user from one browser to the next; a wallpaper of their own is an
/// image under `ui-wallpapers/`. Glass UI keeps its theme and units in config.json and its dashboard layout in
/// `.uix-dashboard.json`, for everyone; here each user has their own.
final class PreferencesStore: Sendable {
    static let themes: Set<String> = ["auto", "light", "dark"]
    /// The backdrops the stylesheet draws (`[data-wallpaper]`), and `custom`, the user's own image.
    static let wallpapers: Set<String> = ["none", "aurora", "sunset", "ocean", "forest", "graphite", "custom"]
    static let temperatureUnits: Set<String> = ["c", "f"]
    /// An uploaded wallpaper, after the page has scaled it down.
    static let maximumWallpaperBytes = 2_500_000

    let url: URL
    let wallpaperDirectory: URL
    private let state: NIOLockedValueBox<[String: JSONValue]>

    init(url: URL) {
        self.url = url
        wallpaperDirectory = url.deletingLastPathComponent().appendingPathComponent("ui-wallpapers")
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONValue(data: $0) }?.objectValue ?? [:]
        state = NIOLockedValueBox(loaded)
    }

    /// The user's choices, with the defaults for what they never chose.
    func preferences(for user: String) -> JSONValue {
        var object: [String: JSONValue] = ["theme": "auto", "wallpaper": "none", "temperatureUnit": "c", "dashboard": ["order": [], "hidden": []]]
        for (key, value) in state.withLockedValue({ $0[user]?.objectValue ?? [:] }) { object[key] = value }
        return .object(object)
    }

    /// Changes the keys `change` has, after checking them; answers all of the user's choices.
    @discardableResult
    func update(_ user: String, with change: JSONValue) throws -> JSONValue {
        guard let fields = change.objectValue else { throw PreferencesError("send the choices as a JSON object") }
        var accepted: [String: JSONValue] = [:]
        for (key, value) in fields {
            switch key {
            case "theme": accepted[key] = try Self.choice(value, in: Self.themes, key)
            case "wallpaper": accepted[key] = try Self.choice(value, in: Self.wallpapers, key)
            case "temperatureUnit": accepted[key] = try Self.choice(value, in: Self.temperatureUnits, key)
            case "dashboard": accepted[key] = try Self.dashboard(value)
            default: throw PreferencesError("unknown preference \(key)")
            }
        }
        try save { all in
            var object = all[user]?.objectValue ?? [:]
            for (key, value) in accepted { object[key] = value }
            all[user] = .object(object)
        }
        return preferences(for: user)
    }

    private func save(_ change: (inout [String: JSONValue]) -> Void) throws {
        try state.withLockedValue { all in
            var next = all
            change(&next)
            try OwnerOnlyFile.write(JSONValue.object(next).encoded(pretty: true), to: url)
            all = next
        }
    }

    // MARK: The user's own wallpaper

    /// The image's file: the user's name in hex, so any name makes a plain file name.
    func wallpaperURL(for user: String) -> URL {
        wallpaperDirectory.appendingPathComponent(Data(user.utf8).map { String(format: "%02x", $0) }.joined())
    }

    /// The user's image and its type, when they set one.
    func wallpaper(for user: String) -> (data: Data, type: String)? {
        guard let data = try? Data(contentsOf: wallpaperURL(for: user)), let type = Self.imageType(data) else { return nil }
        return (data, type)
    }

    /// Keeps a JPEG, PNG or WebP image as the user's wallpaper and chooses it.
    func setWallpaper(_ data: Data, for user: String) throws -> JSONValue {
        guard data.count <= Self.maximumWallpaperBytes else { throw PreferencesError("the image is too large: \(Self.maximumWallpaperBytes / 1_000_000) MB at most") }
        guard Self.imageType(data) != nil else { throw PreferencesError("this is not a JPEG, PNG or WebP image") }
        try OwnerOnlyFile.write(data, to: wallpaperURL(for: user))
        // A new address for the new image, so browsers do not show the one they kept.
        let version = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
        try save { all in
            var object = all[user]?.objectValue ?? [:]
            object["wallpaper"] = "custom"
            object["wallpaperVersion"] = .string(version)
            all[user] = .object(object)
        }
        return preferences(for: user)
    }

    func removeWallpaper(for user: String) throws -> JSONValue {
        try? FileManager.default.removeItem(at: wallpaperURL(for: user))
        try save { all in
            var object = all[user]?.objectValue ?? [:]
            if object["wallpaper"] == "custom" { object["wallpaper"] = "none" }
            object["wallpaperVersion"] = nil
            all[user] = .object(object)
        }
        return preferences(for: user)
    }

    /// The media type of an image by its first bytes.
    static func imageType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    // MARK: Checks

    private static func choice(_ value: JSONValue, in allowed: Set<String>, _ key: String) throws -> JSONValue {
        guard let text = value.stringValue, allowed.contains(text) else { throw PreferencesError("\(key) is one of \(allowed.sorted().joined(separator: ", "))") }
        return .string(text)
    }

    /// `order` and `hidden`: widget ids, short words.
    private static func dashboard(_ value: JSONValue) throws -> JSONValue {
        func ids(_ list: JSONValue?) throws -> JSONValue {
            let items = list?.arrayValue ?? []
            guard items.count <= 32 else { throw PreferencesError("too many widgets") }
            return .array(try items.map { item in
                guard let id = item.stringValue, !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                    throw PreferencesError("a widget id is a short word")
                }
                return .string(id)
            })
        }
        return ["order": try ids(value["order"]), "hidden": try ids(value["hidden"])]
    }
}

struct PreferencesError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension UIServer {
    /// `/api/preferences`: the signed-in user's choices (`GET`, `PUT` with the keys to change), and their own
    /// wallpaper (`GET`, `PUT {data: base64}`, `DELETE` …/wallpaper). nil for a route it does not know.
    func preferencesRoute(_ route: [String], _ request: Request, body: JSONValue, username: String) -> Reply? {
        do {
            switch (request.method, route) {
            case (.GET, []):
                return .json(preferences.preferences(for: username))
            case (.PUT, []):
                return .json(try preferences.update(username, with: body))
            case (.GET, ["wallpaper"]):
                guard let image = preferences.wallpaper(for: username) else { return .error(404, "no wallpaper of your own") }
                // Its address changes with the image (?v=), so the browser may keep it.
                return .data(status: 200, contentType: image.type, body: image.data, headers: ["Cache-Control": "private, max-age=31536000, immutable"])
            case (.PUT, ["wallpaper"]):
                guard let text = body["data"]?.stringValue, let data = Data(base64Encoded: text) else { return .error(400, "send the image as base64 in data") }
                let result = try preferences.setWallpaper(data, for: username)
                logger.info("Web UI wallpaper changed", metadata: ["user": "\(username)", "bytes": "\(data.count)"])
                return .json(result)
            case (.DELETE, ["wallpaper"]):
                return .json(try preferences.removeWallpaper(for: username))
            default:
                return nil
            }
        } catch let error as PreferencesError {
            return .error(400, error.description)
        } catch {
            return .error(500, "the preferences could not be saved: \(error)")
        }
    }
}
