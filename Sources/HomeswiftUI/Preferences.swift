import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// Each user's choices for the pages (Preferences, GLOSSARY.md): the appearance (`theme`, `wallpaper`, `temperatureUnit`), the
/// Language (`language`), the Regional Formats (`timeFormat`, `dateFormat`, `numberFormat`, `firstWeekday`) and whether
/// times show in Home Time or the device's (`timeZone`), and the Status
/// page's widgets (`dashboard`: their `order` and those `hidden`). Kept in `ui-preferences.json` next to
/// config.json, owner-only, so they follow the user from one browser to the next; their own wallpapers are images
/// under `ui-wallpapers/<user>/`, `wallpaperImages` lists them and `wallpaperImage` is the one shown. Glass UI keeps its theme and units in config.json and its dashboard layout in
/// `.uix-dashboard.json`, for everyone; here each user has their own.
final class PreferencesStore: Sendable {
    static let energyHouseStyles: Set<String> = ["simple", "realistic", "beach", "cabin", "apartment", "snow", "christmas", "halloween", "custom"]
    static let themes: Set<String> = ["auto", "light", "dark"]
    /// The backdrops the stylesheet draws (`[data-wallpaper]`), and `custom`, the user's own image.
    static let wallpapers: Set<String> = ["none", "aurora", "sunset", "ocean", "forest", "graphite", "silk", "prism", "ribbon", "lagoon", "ember", "midnight", "custom"]
    static let temperatureUnits: Set<String> = ["c", "f"]
    /// The pages' language (i18n.js): the browser's, or one of the UI's four.
    static let languages = Set(["auto"] + HomeLanguage.all)
    /// The Regional Formats (i18n.js): "auto" follows the Language and the browser's region.
    static let timeFormats: Set<String> = ["auto", "12", "24"]
    static let dateFormats: Set<String> = ["auto", "dmy", "mdy", "ymd"]
    /// 1,234.5, 1.234,5 and 1 234,5.
    static let numberFormats: Set<String> = ["auto", "point", "comma", "space"]
    static let firstWeekdays: Set<String> = ["auto", "mon", "sat", "sun"]
    /// Timestamps in Home Time, or in the device's own time zone. Rules (Tariffs, schedules) stay in Home Time.
    static let timeZones: Set<String> = ["home", "device"]
    /// The preferences that are one of a few words.
    static let choices: [String: Set<String>] = [
        "theme": themes, "wallpaper": wallpapers, "temperatureUnit": temperatureUnits, "language": languages,
        "timeFormat": timeFormats, "dateFormat": dateFormats, "numberFormat": numberFormats, "firstWeekday": firstWeekdays, "timeZone": timeZones,
    ]
    /// An uploaded wallpaper, after the page has scaled it down.
    static let maximumWallpaperBytes = 2_500_000
    /// How many images of their own a user keeps.
    static let maximumWallpapers = 12

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
        var object: [String: JSONValue] = ["theme": "auto", "wallpaper": "none", "temperatureUnit": "c", "language": "auto",
                                              "timeFormat": "auto", "dateFormat": "auto", "numberFormat": "auto", "firstWeekday": "auto", "timeZone": "home",
                                              "energyHouseStyle": "realistic", "dashboard": ["order": [], "hidden": [], "widgets": []],
                                              "energyPage": ["order": [], "hidden": [], "widgets": []]]
        for (key, value) in state.withLockedValue({ $0[user]?.objectValue ?? [:] }) { object[key] = value }
        // Not a choice: the zone "home" means, which the pages format times in.
        object["homeTimeZone"] = .string(HomeTime.zone.identifier)
        let images = wallpaperIDs(for: user)
        object["wallpaperImages"] = .array(images.map(JSONValue.string))
        // Chosen before there could be several: the image kept then.
        if object["wallpaper"] == "custom", object["wallpaperImage"] == nil, let shown = images.last {
            object["wallpaperImage"] = .string(images.first { $0 == object["wallpaperVersion"]?.stringValue } ?? shown)
        }
        return .object(object)
    }

    /// The Language the user chose; nil for automatic (the browser's). Reads only the kept choices: no wallpapers.
    func language(for user: String) -> String? {
        state.withLockedValue { $0[user]?["language"]?.stringValue }.flatMap { $0 == "auto" ? nil : $0 }
    }

    /// Changes the keys `change` has, after checking them; answers all of the user's choices.
    @discardableResult
    func update(_ user: String, with change: JSONValue) throws -> JSONValue {
        guard let fields = change.objectValue else { throw PreferencesError("send the choices as a JSON object") }
        var accepted: [String: JSONValue] = [:]
        for (key, value) in fields {
            switch key {
            // The house style is a choice too, but a photo of one's own must be there before it is chosen.
            case "energyHouseStyle":
                if value == "custom", preferences(for: user)["customHouse"] == nil { throw PreferencesError("upload your house photo first") }
                accepted[key] = try Self.choice(value, in: Self.energyHouseStyles, key)
            case _ where Self.choices[key] != nil: accepted[key] = try Self.choice(value, in: Self.choices[key] ?? [], key)
            // The Status page's layout, and the Energy page's (its units' order and those hidden), checked alike.
            case "dashboard", "energyPage": accepted[key] = try Self.dashboard(value)
            // The Assistant chat's model, one of the provider's; null goes back to the block's.
            case "assistantModel":
                if value.isNull { accepted[key] = .null; break }
                guard let id = value.stringValue, Self.isModelID(id) else { throw PreferencesError("assistantModel is a model id of the Assistant's provider, or null") }
                accepted[key] = .string(id)
            // One of the user's own images; `wallpaperVersion` follows it, for the address common.js loads.
            case "wallpaperImage":
                guard let id = value.stringValue, wallpaperIDs(for: user).contains(id) else { throw PreferencesError("wallpaperImage is one of your images") }
                accepted[key] = .string(id)
                accepted["wallpaperVersion"] = .string(id)
            default: throw PreferencesError("unknown preference \(key)")
            }
        }
        try save { all in
            var object = all[user]?.objectValue ?? [:]
            // A null goes back to the default: the key goes.
            for (key, value) in accepted { if value.isNull { object.removeValue(forKey: key) } else { object[key] = value } }
            all[user] = .object(object)
        }
        return preferences(for: user)
    }

    /// Forgets a removed user's choices and wallpaper: a new account by the same name starts with the defaults.
    func forget(user: String) {
        try? FileManager.default.removeItem(at: wallpaperFolder(for: user))
        try? FileManager.default.removeItem(at: houseFolder(for: user))
        try? save { $0[user] = nil }
    }

    private func save(_ change: (inout [String: JSONValue]) -> Void) throws {
        try state.withLockedValue { all in
            var next = all
            change(&next)
            try OwnerOnlyFile.write(JSONValue.object(next).encoded(pretty: true), to: url)
            all = next
        }
    }

    // MARK: The user's house photo and normalized equipment positions

    private func houseFolder(for user: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("ui-houses")
            .appendingPathComponent(Data(user.utf8).map { String(format: "%02x", $0) }.joined())
    }

    func housePhoto(for user: String, version: String) -> (data: Data, type: String)? {
        guard preferences(for: user)["customHouse"]?["version"]?.stringValue == version,
              Self.isID(version), let data = try? Data(contentsOf: houseFolder(for: user).appendingPathComponent(version)),
              let type = Self.imageType(data) else { return nil }
        return (data, type)
    }

    func saveHouse(_ body: JSONValue, for user: String) throws -> JSONValue {
        guard let name = body["name"]?.stringValue, name.count <= 80,
              let description = body["description"]?.stringValue, description.count <= 500,
              let width = body["width"]?.intValue, let height = body["height"]?.intValue,
              (1...8192).contains(width), (1...8192).contains(height) else { throw PreferencesError("invalid house details or image dimensions") }
        var markers: [String: JSONValue] = [:]
        for role in ["solar", "battery", "grid", "home"] {
            guard let point = body["markers"]?[role]?.arrayValue, point.count == 2,
                  point.allSatisfy({ if let n = $0.doubleValue { return n.isFinite && (0...1).contains(n) }; return false }) else {
                throw PreferencesError("place each equipment marker inside the photo")
            }
            markers[role] = .array(point)
        }
        let previous = preferences(for: user)["customHouse"]?["version"]?.stringValue
        var version = previous
        if let text = body["data"]?.stringValue {
            guard let data = Data(base64Encoded: text), data.count <= Self.maximumWallpaperBytes,
                  Self.imageType(data) != nil else { throw PreferencesError("choose a JPEG, PNG or WebP image under 2.5 MB") }
            version = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16).description
            try OwnerOnlyFile.write(data, to: houseFolder(for: user).appendingPathComponent(version!))
        }
        guard let version, housePhotoExists(user, version) else { throw PreferencesError("upload your house photo first") }
        do {
            try save { all in
                var object = all[user]?.objectValue ?? [:]
                object["energyHouseStyle"] = "custom"
                object["customHouse"] = .object(["name": .string(name), "description": .string(description),
                    "width": .number(Double(width)), "height": .number(Double(height)), "markers": .object(markers), "version": .string(version)])
                all[user] = .object(object)
            }
        } catch {
            if version != previous { try? FileManager.default.removeItem(at: houseFolder(for: user).appendingPathComponent(version)) }
            throw error
        }
        if let previous, previous != version { try? FileManager.default.removeItem(at: houseFolder(for: user).appendingPathComponent(previous)) }
        return preferences(for: user)
    }

    private func housePhotoExists(_ user: String, _ version: String) -> Bool {
        Self.isID(version) && FileManager.default.fileExists(atPath: houseFolder(for: user).appendingPathComponent(version).path)
    }

    func removeHouse(for user: String) throws -> JSONValue {
        try save { all in
            var object = all[user]?.objectValue ?? [:]
            object.removeValue(forKey: "customHouse")
            if object["energyHouseStyle"] == "custom" { object["energyHouseStyle"] = "realistic" }
            all[user] = .object(object)
        }
        try? FileManager.default.removeItem(at: houseFolder(for: user))
        return preferences(for: user)
    }

    // MARK: The user's own wallpapers

    /// The user's folder of images: their name in hex, so any name makes a plain file name.
    func wallpaperFolder(for user: String) -> URL {
        wallpaperDirectory.appendingPathComponent(Data(user.utf8).map { String(format: "%02x", $0) }.joined())
    }

    /// The ids of the user's images, oldest first (an id is the time it was added). A single image kept by an
    /// earlier version, a file where the folder goes, moves into the folder under its version.
    func wallpaperIDs(for user: String) -> [String] {
        let folder = wallpaperFolder(for: user)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), !isFolder.boolValue {
            let id = state.withLockedValue { $0[user]?["wallpaperVersion"]?.stringValue }.flatMap { Self.isID($0) ? $0 : nil } ?? "0"
            if let data = try? Data(contentsOf: folder) {
                try? FileManager.default.removeItem(at: folder)
                try? OwnerOnlyFile.write(data, to: folder.appendingPathComponent(id))
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(Self.isID).sorted { ($0.count, $0) < ($1.count, $1) }
    }

    /// One of the user's images and its type; without an id, the one shown.
    func wallpaper(for user: String, id: String? = nil) -> (data: Data, type: String)? {
        guard let id = id ?? preferences(for: user)["wallpaperImage"]?.stringValue ?? wallpaperIDs(for: user).last, Self.isID(id),
              let data = try? Data(contentsOf: wallpaperFolder(for: user).appendingPathComponent(id)), let type = Self.imageType(data) else { return nil }
        return (data, type)
    }

    /// Keeps a JPEG, PNG or WebP image among the user's own and shows it.
    func addWallpaper(_ data: Data, for user: String) throws -> JSONValue {
        guard data.count <= Self.maximumWallpaperBytes else { throw PreferencesError("the image is too large: \(Self.maximumWallpaperBytes / 1_000_000) MB at most") }
        guard Self.imageType(data) != nil else { throw PreferencesError("this is not a JPEG, PNG or WebP image") }
        let existing = wallpaperIDs(for: user)
        guard existing.count < Self.maximumWallpapers else { throw PreferencesError("you keep \(Self.maximumWallpapers) images at most: remove one first") }
        // The time, in base 36: a new address for each image, so browsers do not show one they kept, and its order.
        var stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        while existing.contains(String(stamp, radix: 36)) { stamp += 1 }
        let id = String(stamp, radix: 36)
        try OwnerOnlyFile.write(data, to: wallpaperFolder(for: user).appendingPathComponent(id))
        try save { all in
            var object = all[user]?.objectValue ?? [:]
            object["wallpaper"] = "custom"
            object["wallpaperImage"] = .string(id)
            object["wallpaperVersion"] = .string(id)
            all[user] = .object(object)
        }
        return preferences(for: user)
    }

    /// Removes one of the user's images, or all of them without an id. The one shown gone, the wallpaper is none.
    func removeWallpaper(for user: String, id: String? = nil) throws -> JSONValue {
        if let id {
            guard Self.isID(id), wallpaperIDs(for: user).contains(id) else { throw PreferencesError("no image \(id) of yours") }
            try? FileManager.default.removeItem(at: wallpaperFolder(for: user).appendingPathComponent(id))
        } else {
            try? FileManager.default.removeItem(at: wallpaperFolder(for: user))
        }
        try save { all in
            var object = all[user]?.objectValue ?? [:]
            if id == nil || object["wallpaperImage"]?.stringValue == id {
                if object["wallpaper"] == "custom" { object["wallpaper"] = "none" }
                object["wallpaperImage"] = nil
                object["wallpaperVersion"] = nil
            }
            all[user] = .object(object)
        }
        return preferences(for: user)
    }

    /// An image's id: base 36 digits, so it is a plain file name.
    /// A provider's model id as the models lists give them (`claude-opus-5-5`, `gemini-3.8-flash`, `llama3.1:8b`,
    /// `org/model`): no spaces or quotes, 100 characters at most.
    static func isModelID(_ text: String) -> Bool {
        (1...100).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:/-@".contains($0)) }
    }

    static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 16 && text.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLowercase) }
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

    /// `order` and `hidden`: the sections' ids; `widgets`: the small widgets added to At a glance, in order. Short words.
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
        return ["order": try ids(value["order"]), "hidden": try ids(value["hidden"]), "widgets": try ids(value["widgets"])]
    }
}

struct PreferencesError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension UIServer {
    /// `/api/preferences`: the signed-in user's choices (`GET`, `PUT` with the keys to change), and their own
    /// wallpapers: `GET …/wallpaper` the one shown, `GET …/wallpaper/<id>` one of them, `PUT …/wallpaper {data: base64}`
    /// adds one and shows it, `DELETE …/wallpaper/<id>` removes one (`DELETE …/wallpaper` all). nil for a route it does not know.
    func preferencesRoute(_ route: [String], _ request: Request, body: JSONValue, username: String) -> Reply? {
        do {
            switch (request.method, route) {
            case (.GET, []):
                return .json(preferences.preferences(for: username))
            case (.PUT, []):
                return .json(try preferences.update(username, with: body))
            case (.PUT, ["house"]):
                return .json(try preferences.saveHouse(body, for: username))
            case (.DELETE, ["house"]):
                return .json(try preferences.removeHouse(for: username))
            case (.GET, _) where route.count == 2 && route[0] == "house":
                guard let image = preferences.housePhoto(for: username, version: route[1]) else { return .error(404, "no house photo of your own") }
                return .data(status: 200, contentType: image.type, body: image.data, headers: ["Cache-Control": "private, no-store"])
            case (.GET, _) where route.first == "wallpaper" && route.count <= 2:
                guard let image = preferences.wallpaper(for: username, id: route.count == 2 ? route[1] : nil) else { return .error(404, "no wallpaper of your own") }
                // Its address changes with the image (?v=), so the browser may keep it.
                return .data(status: 200, contentType: image.type, body: image.data, headers: ["Cache-Control": "private, max-age=31536000, immutable"])
            case (.PUT, ["wallpaper"]):
                guard let text = body["data"]?.stringValue, let data = Data(base64Encoded: text) else { return .error(400, "send the image as base64 in data") }
                let result = try preferences.addWallpaper(data, for: username)
                logger.info("Web UI wallpaper changed", metadata: ["user": "\(username)", "bytes": "\(data.count)"])
                return .json(result)
            case (.DELETE, ["wallpaper"]):
                return .json(try preferences.removeWallpaper(for: username))
            case (.DELETE, _) where route.count == 2 && route[0] == "wallpaper":
                return .json(try preferences.removeWallpaper(for: username, id: route[1]))
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
