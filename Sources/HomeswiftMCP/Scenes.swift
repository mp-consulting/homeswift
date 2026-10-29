import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging

// Scenes, ported from Glass UI (scenes.service.ts, scene-automation.ts, solar.ts): named lists of characteristic
// values set together, now or by triggers (a time of day on chosen days, a cron expression, sunrise or sunset
// with an offset at the configured location, a characteristic change), when their conditions hold (a time
// window, a characteristic's value). Kept in scenes.json next to config.json.
//
// Locks, garage doors, alarms and what plugins mark as security controls go through the path
// set_security_accessory takes: a person confirms. Glass UI runs them like any value, from the page and from
// automations alike; Homeswift keeps its stricter rule. The web UI asks the signed-in user before running a
// scene that has them; run_scene refuses such a scene (as homebridge-mcp-server's does), pointing to
// set_security_accessory; an automation, with nobody there to ask, skips those actions and reports them.

public struct SceneAction: Codable, Sendable, Equatable {
    /// The accessory id; for a hub's scene, its id (`recall`).
    public var id: String
    /// The service type, name or subtype, when the accessory has several with the characteristic.
    public var service: String?
    public var characteristic: String
    public var value: JSONValue
    /// A scene of a plugin's hub to recall (`<platform>:<instance>:<hub id>`) instead of a value to set.
    public var recall: String?

    /// Recalls a hub's scene: `{"recall": id}` in a request body.
    static func recalling(_ id: String) -> SceneAction {
        SceneAction(id: id, service: nil, characteristic: "Scene", value: true, recall: id)
    }
}

struct SceneUndo: Codable, Sendable {
    var at: Date
    var actions: [SceneAction]
    var expected: [SceneAction]
}

/// What runs a scene. `time`: `at` (HH:mm) on `days` (0 Sunday to 6; every day when empty); `cron`; `sun`:
/// `event` (sunrise or sunset) with `offsetMinutes` (-720 to 720) on `days`; `characteristic`: when `characteristic`
/// of accessory `id` changes (`operator` `changes`) or starts to compare with `value` (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`).
public struct SceneTrigger: Codable, Sendable, Equatable {
    public var type: String
    public var enabled: Bool?
    public var at: String?
    public var days: [Int]?
    public var cron: String?
    public var event: Solar.Event?
    public var offsetMinutes: Int?
    public var id: String?
    public var service: String?
    public var characteristic: String?
    public var `operator`: String?
    public var value: JSONValue?

    public var isEnabled: Bool { enabled != false }
}

/// What must hold for an automatic run: `time` (from `after` to `before`, HH:mm, sunrise or sunset; a window that
/// ends before it starts spans midnight), or `characteristic` (`id`, `characteristic`, `operator`, `value`).
public struct SceneCondition: Codable, Sendable, Equatable {
    public var type: String
    public var after: String?
    public var before: String?
    public var id: String?
    public var service: String?
    public var characteristic: String?
    public var `operator`: String?
    public var value: JSONValue?
}

public struct SceneRunRecord: Codable, Sendable, Equatable {
    public var at: String
    public var ok: Bool
    public var trigger: String
    /// Why an automatic run did not go ahead, or what it skipped.
    public var reason: String?
}

public struct Scene: Codable, Sendable, Equatable {
    public var artworkId: String? = nil
    public var id: String
    public var name: String
    public var actions: [SceneAction]
    public var triggers: [SceneTrigger]
    public var conditions: [SceneCondition]
    public var lastRun: SceneRunRecord?
    public var lastSkipped: SceneRunRecord?
    /// What it plays on its lights after its actions, when it moves.
    public var animation: SceneAnimation? = nil
}

public struct SceneLocation: Codable, Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var name: String?
}

public struct SceneFile: Codable, Sendable, Equatable {
    public var version = 1
    /// Where sunrise and sunset are computed for. Glass UI took its dashboard's weather city; Homeswift has a
    /// field on the Scenes page.
    public var location: SceneLocation?
    public var scenes: [Scene] = []

    public init() {}
}

public enum SceneRunTrigger: String, Sendable {
    case manual, schedule, sun, characteristic
}

enum SceneRules {
    static let maxScenes = 100
    static let maxActions = 50
    static let maxTriggers = 10
    static let maxConditions = 10
    static let operators: Set<String> = ["eq", "neq", "gt", "gte", "lt", "lte"]
    static let cooldown: TimeInterval = 5

    static func isTime(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    static func isValue(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool: true
        case .number(let number): number.isFinite
        case .string(let text): text.count <= 256
        default: false
        }
    }

    /// A characteristic value as a number when it reads as one (HAP sends booleans as 0 and 1 too).
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .bool(let bool): bool ? 1 : 0
        case .number(let number): number.isFinite ? number : nil
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// Glass UI's compareValue: numbers when both read as numbers, else text for eq and neq.
    static func compare(_ actual: JSONValue?, _ operation: String, _ expected: JSONValue?) -> Bool {
        if let a = number(actual), let b = number(expected) {
            switch operation {
            case "eq": return a == b
            case "neq": return a != b
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            case "lte": return a <= b
            default: return false
            }
        }
        let text = { (value: JSONValue?) in value?.stringValue ?? value.map { $0.isNull ? "" : $0.text() } ?? "" }
        switch operation {
        case "eq": return text(actual) == text(expected)
        case "neq": return text(actual) != text(expected)
        default: return false
        }
    }

    /// Glass UI's triggerFires: any change for `changes`, else when the value starts to match.
    static func fires(_ trigger: SceneTrigger, previous: JSONValue?, next: JSONValue) -> Bool {
        if previous == next { return false }
        if let a = number(previous), let b = number(next), a == b { return false }
        let operation = trigger.operator ?? "changes"
        if operation == "changes" { return previous != nil }
        return compare(next, operation, trigger.value) && (previous == nil || !compare(previous, operation, trigger.value))
    }

    /// Minutes since local midnight of HH:mm, sunrise or sunset; nil for a sun event without a location or that
    /// does not happen that day.
    static func minutesOfDay(_ time: String, on now: Date, location: SceneLocation?, calendar: Calendar) -> Int? {
        if let event = Solar.Event(rawValue: time) {
            guard let location, let at = Solar.onLocalDay(event, of: now, latitude: location.lat, longitude: location.lon, calendar: calendar) else { return nil }
            let parts = calendar.dateComponents([.hour, .minute], from: at)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// Whether `now` is in a time window; nil when it cannot be told.
    static func inWindow(_ condition: SceneCondition, now: Date, location: SceneLocation?, calendar: Calendar) -> Bool? {
        guard let from = minutesOfDay(condition.after ?? "", on: now, location: location, calendar: calendar),
              let to = minutesOfDay(condition.before ?? "", on: now, location: location, calendar: calendar) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let current = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return from <= to ? current >= from && current < to : current >= from || current < to
    }

    /// Whether a timed trigger runs at this local minute.
    static func due(_ trigger: SceneTrigger, at now: Date, location: SceneLocation?, calendar: Calendar) -> Bool {
        guard trigger.isEnabled else { return false }
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let onDay = (trigger.days ?? []).isEmpty || (trigger.days ?? []).contains((parts.weekday ?? 1) - 1)
        switch trigger.type {
        case "time":
            guard onDay, let at = trigger.at, let minutes = minutesOfDay(at, on: now, location: nil, calendar: calendar) else { return false }
            return minutes == (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        case "cron":
            return trigger.cron.flatMap { try? CronSchedule($0) }?.matches(now, calendar: calendar) ?? false
        case "sun":
            guard let location, let event = trigger.event else { return false }
            // The event of the day the shifted time falls on: sunset + 30 minutes may be after midnight.
            let shift = Double(trigger.offsetMinutes ?? 0) * 60
            guard let at = Solar.onLocalDay(event, of: now.addingTimeInterval(-shift), latitude: location.lat, longitude: location.lon, calendar: calendar)?.addingTimeInterval(shift) else { return false }
            let eventDay = calendar.dateComponents([.weekday], from: at.addingTimeInterval(-shift)).weekday ?? 1
            let sunDay = (trigger.days ?? []).isEmpty || (trigger.days ?? []).contains(eventDay - 1)
            return sunDay && calendar.isDate(at, equalTo: now, toGranularity: .minute)
        default:
            return false
        }
    }

    // MARK: Parsing request bodies

    static func string(_ object: [String: JSONValue], _ key: String, _ label: String, max: Int = 128) throws -> String {
        guard let text = object[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= max else { throw CatalogError("\(label): \(key) is missing") }
        return text
    }

    static func action(_ value: JSONValue, index: Int) throws -> SceneAction {
        let label = "Action \(index + 1)"
        guard let object = value.objectValue else { throw CatalogError("\(label) must be an object") }
        if object["recall"] != nil { return .recalling(try string(object, "recall", label, max: 512)) }
        guard isValue(object["value"]) else { throw CatalogError("\(label): the value must be a boolean, a number or a short text") }
        return SceneAction(id: try string(object, "id", label), service: object["service"]?.stringValue?.nonEmpty, characteristic: try string(object, "characteristic", label, max: 64), value: object["value"]!)
    }

    static func days(_ value: JSONValue?, _ label: String) throws -> [Int]? {
        guard let value, !value.isNull else { return nil }
        guard let list = value.arrayValue?.compactMap(\.intValue), list.count == value.arrayValue?.count, list.allSatisfy({ (0...6).contains($0) }) else {
            throw CatalogError("\(label): days are 0 (Sunday) to 6")
        }
        let sorted = Array(Set(list)).sorted()
        return sorted.isEmpty || sorted.count == 7 ? nil : sorted
    }

    static func trigger(_ value: JSONValue, index: Int) throws -> SceneTrigger {
        let label = "Trigger \(index + 1)"
        guard let object = value.objectValue else { throw CatalogError("\(label) must be an object") }
        var trigger = SceneTrigger(type: object["type"]?.stringValue ?? "")
        trigger.enabled = object["enabled"]?.boolValue == false ? false : nil
        switch trigger.type {
        case "time":
            guard let at = object["at"]?.stringValue, isTime(at) else { throw CatalogError("\(label): the time must be HH:mm") }
            trigger.at = at
            trigger.days = try days(object["days"], label)
        case "cron":
            guard let cron = object["cron"]?.stringValue?.trimmingCharacters(in: .whitespaces), cron.count <= 100, (try? CronSchedule(cron)) != nil else {
                throw CatalogError("\(label): invalid cron expression")
            }
            trigger.cron = cron
        case "sun":
            guard let event = object["event"]?.stringValue.flatMap(Solar.Event.init(rawValue:)) else { throw CatalogError("\(label): the event must be sunrise or sunset") }
            let offset = object["offsetMinutes"]?.intValue ?? 0
            guard object["offsetMinutes"] == nil || object["offsetMinutes"]?.intValue != nil, abs(offset) <= 720 else {
                throw CatalogError("\(label): the offset must be a whole number of minutes from -720 to 720")
            }
            trigger.event = event
            trigger.offsetMinutes = offset
            trigger.days = try days(object["days"], label)
        case "characteristic":
            trigger.id = try string(object, "id", label)
            trigger.service = object["service"]?.stringValue?.nonEmpty
            trigger.characteristic = try string(object, "characteristic", label, max: 64)
            let operation = object["operator"]?.stringValue ?? "changes"
            guard operation == "changes" || operators.contains(operation) else { throw CatalogError("\(label): invalid operator") }
            trigger.operator = operation
            if operation != "changes" {
                guard isValue(object["value"]) else { throw CatalogError("\(label): the value must be a boolean, a number or a short text") }
                trigger.value = object["value"]
            }
        default:
            throw CatalogError("\(label): the type must be time, cron, sun or characteristic")
        }
        return trigger
    }

    static func condition(_ value: JSONValue, index: Int) throws -> SceneCondition {
        let label = "Condition \(index + 1)"
        guard let object = value.objectValue else { throw CatalogError("\(label) must be an object") }
        var condition = SceneCondition(type: object["type"]?.stringValue ?? "")
        switch condition.type {
        case "time":
            let valid = { (text: String?) in text.map { $0 == "sunrise" || $0 == "sunset" || isTime($0) } ?? false }
            guard valid(object["after"]?.stringValue), valid(object["before"]?.stringValue) else { throw CatalogError("\(label): a time must be HH:mm, sunrise or sunset") }
            condition.after = object["after"]?.stringValue
            condition.before = object["before"]?.stringValue
            guard condition.after != condition.before else { throw CatalogError("\(label): the window is empty") }
        case "characteristic":
            condition.id = try string(object, "id", label)
            condition.service = object["service"]?.stringValue?.nonEmpty
            condition.characteristic = try string(object, "characteristic", label, max: 64)
            guard let operation = object["operator"]?.stringValue, operators.contains(operation) else { throw CatalogError("\(label): invalid operator") }
            guard isValue(object["value"]) else { throw CatalogError("\(label): the value must be a boolean, a number or a short text") }
            condition.operator = operation
            condition.value = object["value"]
        default:
            throw CatalogError("\(label): the type must be time or characteristic")
        }
        return condition
    }

    /// A scene's fields from a request body. Triggers and conditions left out keep the existing scene's.
    static func scene(from body: JSONValue, id: String, existing: Scene?) throws -> Scene {
        guard let object = body.objectValue else { throw CatalogError("Expected a scene") }
        let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name.count <= 64 else { throw CatalogError("The name must be 1 to 64 characters") }
        let animation = try object["animation"].flatMap { $0.isNull ? nil : try SceneAnimation.checked($0) } ?? (object["animation"] == nil ? existing?.animation : nil)
        guard let actions = object["actions"]?.arrayValue ?? (animation != nil ? [] : nil), !actions.isEmpty || animation != nil, actions.count <= maxActions else {
            throw CatalogError("A scene needs 1 to \(maxActions) actions, or an animation")
        }
        let triggers = try object["triggers"].map { value -> [SceneTrigger] in
            guard let list = value.arrayValue, list.count <= maxTriggers else { throw CatalogError("At most \(maxTriggers) triggers") }
            return try list.enumerated().map { try trigger($1, index: $0) }
        } ?? existing?.triggers ?? []
        let conditions = try object["conditions"].map { value -> [SceneCondition] in
            guard let list = value.arrayValue, list.count <= maxConditions else { throw CatalogError("At most \(maxConditions) conditions") }
            return try list.enumerated().map { try condition($1, index: $0) }
        } ?? existing?.conditions ?? []
        let artworkId: String?
        if let value = object["artworkId"] {
            if value.isNull { artworkId = nil }
            else if let id = value.stringValue, SceneArtwork.find(id) != nil { artworkId = id }
            else { throw CatalogError("Unknown scene artwork") }
        } else { artworkId = existing?.artworkId }
        return Scene(artworkId: artworkId, id: id, name: name, actions: try actions.enumerated().map { try action($1, index: $0) }, triggers: triggers, conditions: conditions,
                     lastRun: existing?.lastRun, lastSkipped: existing?.lastSkipped, animation: animation)
    }

    static func newID() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func now() -> String { Timestamp.iso8601(Date()) }
}

extension HomeswiftCatalog {
    // MARK: Reading

    /// What the Scenes page and list_scenes show: each scene with its accessories' names and whether it changes a
    /// security control, the location, and the next sunrise and sunset there.
    public func scenesJSON(now: Date = Date()) -> JSONValue {
        let file = home.scenes.value
        var answer: [String: JSONValue] = ["scenes": .array(file.scenes.map(sceneJSON)), "artworks": .array(SceneArtwork.all.map(\.json))]
        if let location = file.location {
            answer["location"] = (try? JSONValue(encoding: location)) ?? .null
            answer["nextSunrise"] = Solar.next(.sunrise, latitude: location.lat, longitude: location.lon, after: now).map { .string(Timestamp.iso8601($0)) } ?? .null
            answer["nextSunset"] = Solar.next(.sunset, latitude: location.lat, longitude: location.lon, after: now).map { .string(Timestamp.iso8601($0)) } ?? .null
        } else {
            answer["location"] = .null
        }
        return .object(answer)
    }

    func sceneJSON(_ scene: Scene) -> JSONValue {
        guard var object = (try? JSONValue(encoding: scene))?.objectValue else { return .null }
        let security = securityActions(of: scene)
        object["security"] = .bool(!security.isEmpty)
        let undo = home.sceneUndo.value[scene.id]
        object["stopSecurity"] = .bool(undo?.actions.contains { action in
            guard let found = find(id: action.id) else { return false }
            return (try? characteristic(in: found, service: action.service, characteristic: action.characteristic).isSecurityControl) == true
        } ?? false)
        object["stoppable"] = .bool((undo.map { Date().timeIntervalSince($0.at) < MoodRules.undoSeconds && !$0.actions.isEmpty } ?? false)
            || home.runningMoods.withLockedValue { $0.values.contains { $0.mood.id == "scene:" + scene.id } })
        object["room"] = sharedRoom(of: scene.actions.map(\.id)).map(JSONValue.string) ?? .null
        object["active"] = .bool(isActive(scene))
        object["actions"] = .array(scene.actions.map { action in
            var entry = (try? JSONValue(encoding: action))?.objectValue ?? [:]
            if action.recall != nil {
                // Named, or marked missing, with the hubs' scenes (allScenesJSON).
            } else if let found = find(id: action.id) {
                entry["name"] = .string(found.layout?.name ?? found.accessory.name)
                if let target = try? characteristic(in: found, service: action.service, characteristic: action.characteristic), target.isSecurityControl { entry["security"] = true }
            } else {
                entry["missing"] = true
            }
            return .object(entry)
        })
        return .object(object)
    }

    /// Whether every value the scene sets is what its accessory shows now. A light switched off shows no colour: once
    /// a scene's On is false, its other values for that light are not compared.
    func isActive(_ scene: Scene) -> Bool {
        if scene.animation != nil { return isPlaying(scene.id) }
        let scene = Scene(id: scene.id, name: scene.name, actions: scene.actions.filter { $0.recall == nil }, triggers: [], conditions: [])
        guard !scene.actions.isEmpty else { return false }
        let off = Set(scene.actions.filter { Self.normalized($0.characteristic) == Self.normalized("On") && SceneRules.number($0.value) == 0 }.map { "\($0.id)|\($0.service ?? "")" })
        return scene.actions.allSatisfy { action in
            if off.contains("\(action.id)|\(action.service ?? "")"), Self.normalized(action.characteristic) != Self.normalized("On") { return true }
            guard let found = find(id: action.id), let target = try? characteristic(in: found, service: action.service, characteristic: action.characteristic) else { return false }
            let current = Self.value(of: target)
            if let a = SceneRules.number(current), let b = SceneRules.number(action.value) { return abs(a - b) <= max(1, target.type.minStep ?? 0) }
            return SceneRules.compare(current, "eq", action.value)
        }
    }

    /// Why run_scene does not run this scene: it changes a lock, a garage door or an alarm. nil when it does not.
    func securityRefusal(_ scene: Scene) -> String? {
        let sensitive = securityActions(of: scene)
        guard !sensitive.isEmpty else { return nil }
        let names = sensitive.map { "\(find(id: $0.id)?.accessory.name ?? $0.id) \($0.characteristic)" }.joined(separator: ", ")
        return "Scene \"\(scene.name)\" changes a lock, garage door or alarm (\(names)), so run_scene does not run it. "
            + "Apply those actions with set_security_accessory (it asks the user to confirm), or ask the user to run the scene in the web UI."
    }

    /// The actions of a scene that unlock, open or disarm (security controls).
    func securityActions(of scene: Scene) -> [SceneAction] {
        scene.actions.filter { action in
            guard action.recall == nil, let found = find(id: action.id), let target = try? characteristic(in: found, service: action.service, characteristic: action.characteristic) else { return false }
            return target.isSecurityControl
        }
    }

    func scene(_ reference: String) throws -> Scene {
        let scenes = home.scenes.value.scenes
        guard let scene = scenes.first(where: { $0.id == reference }) ?? scenes.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw CatalogError("No scene \"\(reference)\". Scenes: \(scenes.isEmpty ? "none" : scenes.map(\.name).joined(separator: ", ")).")
        }
        return scene
    }

    // MARK: Changing

    public func createScene(_ body: JSONValue) throws -> JSONValue {
        let scene = try SceneRules.scene(from: body, id: SceneRules.newID(), existing: nil)
        try home.scenes.update { file in
            guard file.scenes.count < SceneRules.maxScenes else { throw CatalogError("At most \(SceneRules.maxScenes) scenes") }
            file.scenes.append(scene)
        }
        seedWatchedValues()
        return sceneJSON(scene)
    }

    public func updateScene(id: String, _ body: JSONValue) throws -> JSONValue {
        let updated = try home.scenes.update { file -> Scene in
            guard let index = file.scenes.firstIndex(where: { $0.id == id }) else { throw CatalogError("No scene \(id)") }
            file.scenes[index] = try SceneRules.scene(from: body, id: id, existing: file.scenes[index])
            return file.scenes[index]
        }
        seedWatchedValues()
        return sceneJSON(updated)
    }

    public func deleteScene(id: String) throws {
        try home.scenes.update { file in
            guard file.scenes.contains(where: { $0.id == id }) else { throw CatalogError("No scene \(id)") }
            file.scenes.removeAll { $0.id == id }
        }
    }

    /// Sets where sunrise and sunset are computed for; nil forgets it.
    public func setSceneLocation(_ body: JSONValue) throws -> JSONValue {
        var location: SceneLocation?
        if !body.isNull, body.objectValue?.isEmpty == false {
            guard let lat = body["lat"]?.doubleValue, let lon = body["lon"]?.doubleValue, Solar.isValid(latitude: lat, longitude: lon) else {
                throw CatalogError("A location needs lat (-90 to 90) and lon (-180 to 180)")
            }
            let name = body["name"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty.map { String($0.prefix(64)) }
            location = SceneLocation(lat: lat, lon: lon, name: name)
        }
        try home.scenes.update { $0.location = location }
        return scenesJSON()
    }

    /// save_scene: a scene from the current values of these accessories (every writable characteristic, or only
    /// `characteristics`), never a security control nor what triggers or names something.
    public func captureScene(name: String, ids: [String], characteristics wanted: [String]?, dryRun: Bool) throws -> JSONValue {
        let names = wanted.map { Set($0.map(Self.normalized)) }
        let notState: Set<String> = ["identify", "name", "configuredname"]
        var actions: [JSONValue] = []
        var skipped: [JSONValue] = []
        var seen: Set<String> = []
        for id in ids where seen.insert(id).inserted {
            guard let found = find(id: id) else { skipped.append(["id": .string(id), "reason": "no such accessory"]); continue }
            var captured = 0
            for service in found.accessory.services where service.type.uuid != ServiceType.accessoryInformation.uuid && !Self.isInternal(service) {
                for characteristic in service.characteristics {
                    let type = Self.normalized(characteristic.type.name)
                    let permissions = characteristic.type.permissions
                    guard permissions.contains(.pairedWrite), permissions.contains(.pairedRead), !notState.contains(type), !characteristic.isSecurityControl,
                          !Self.isInternal(characteristic), !characteristic.isConfidential, names?.contains(type) ?? true else { continue }
                    let value = Self.json(characteristic.value)
                    guard SceneRules.isValue(value) else { continue }
                    let several = found.accessory.services.filter { $0.characteristics.contains { Self.normalized($0.type.name) == type } }.count > 1
                    var action: [String: JSONValue] = ["id": .string(id), "characteristic": .string(characteristic.type.name), "value": value]
                    if several { action["service"] = .string(service.subtype ?? service[.name]?.value.stringValue ?? service.type.name) }
                    actions.append(.object(action))
                    captured += 1
                }
            }
            if captured == 0 { skipped.append(["id": .string(id), "name": .string(found.accessory.name), "reason": "nothing to capture"]) }
        }
        guard !actions.isEmpty else { throw CatalogError("Nothing to save: \(skipped.map { "\($0["id"]?.stringValue ?? "") (\($0["reason"]?.stringValue ?? ""))" }.joined(separator: ", "))") }
        guard actions.count <= SceneRules.maxActions else {
            throw CatalogError("That is \(actions.count) actions; a scene holds at most \(SceneRules.maxActions). Pass fewer accessories or limit characteristics.")
        }
        if dryRun { return ["dryRun": true, "name": .string(name), "actions": .array(actions), "skipped": .array(skipped)] }
        return ["created": try createScene(["name": .string(name), "actions": .array(actions)]), "skipped": .array(skipped)]
    }

    // MARK: Running

    /// Sets every value of a scene in order; an action that fails is reported and the rest still run. A security
    /// control runs only with `allowSecurity` (a person confirmed); otherwise it is skipped and reported. An
    /// automatic run checks the conditions first, and records why it did not go ahead.
    public func runScene(_ reference: String, trigger: SceneRunTrigger = .manual, allowSecurity: Bool = false) async throws -> JSONValue {
        let scene: Scene
        do {
            scene = try self.scene(reference)
        } catch {
            // Not one of Homeswift's: a scene of a plugin's hub.
            guard let found = await pluginScene(reference) else { throw error }
            return try await runPluginScene(found, by: "scene \(trigger.rawValue)")
        }
        return try await run(scene, trigger: trigger, allowSecurity: allowSecurity)
    }

    /// Runs a scene, saved or not (a plan: `runPlan`). Its changes are kept for `MoodRules.undoSeconds` under its id,
    /// so `stopScene` puts them back.
    func run(_ scene: Scene, trigger: SceneRunTrigger, allowSecurity: Bool) async throws -> JSONValue {
        guard home.runningScenes.withLockedValue({ $0.insert(scene.id).inserted }) else { throw CatalogError("This scene is already running") }
        defer { _ = home.runningScenes.withLockedValue { $0.remove(scene.id) } }
        if trigger != .manual, let reason = conditionsFail(scene.conditions) {
            logger.info("Scene \"\(scene.name)\" not run (\(trigger.rawValue)): \(reason)")
            record(scene.id) { $0.lastSkipped = SceneRunRecord(at: SceneRules.now(), ok: true, trigger: trigger.rawValue, reason: reason) }
            return ["sceneId": .string(scene.id), "name": .string(scene.name), "ok": true, "results": [], "skipped": .string(reason)]
        }
        // Light snapshots include color mode, power and Adaptive Lighting, and inherit the baseline of a mood they replace.
        let located = Set(scene.actions.map(\.id)).compactMap { find(id: $0) }
        let lights = Self.lights(of: located).filter { light in
            scene.actions.contains { action in
                guard action.id == light.located.accessory.id,
                      let target = try? characteristic(in: light.located, service: action.service, characteristic: action.characteristic) else { return false }
                return [light.on, light.brightness, light.hue, light.saturation, light.colorTemperature].compactMap { $0 }.contains { $0 === target }
            }
        }
        let beforeLights = Dictionary(uniqueKeysWithValues: lights.map { ($0.key, $0.snapshot()) })
        var snapshots: [String: MoodSnapshot] = [:]
        var changedLights: [MoodLight] = []
        var undoActions: [SceneAction] = [], expected: [SceneAction] = []
        // A skipped or failed rerun still owes restoration for earlier successful writes.
        if let prior = home.sceneUndo.value[scene.id], Date().timeIntervalSince(prior.at) < MoodRules.undoSeconds {
            for (action, after) in zip(prior.actions, prior.expected) {
                guard let found = find(id: after.id),
                      let target = try? characteristic(in: found, service: after.service, characteristic: after.characteristic),
                      Self.value(of: target) == after.value else { continue }
                undoActions.append(action)
                expected.append(after)
            }
        }
        var results: [JSONValue] = []
        var failed = 0, held = 0
        for action in scene.actions {
            if let recall = action.recall {
                var result: [String: JSONValue] = ["recall": .string(recall)]
                do {
                    guard let found = await pluginScene(recall) else { throw CatalogError("the hub's scene is gone") }
                    result["name"] = .string(found.scene.name)
                    _ = try await runPluginScene(found, by: "scene \(scene.name)", holdAs: scene.id)
                    result["ok"] = true
                } catch {
                    failed += 1
                    result["ok"] = false
                    result["error"] = .string(Redaction.redactText("\(error)"))
                }
                results.append(.object(result))
                continue
            }
            var result: [String: JSONValue] = ["id": .string(action.id), "characteristic": .string(action.characteristic), "value": action.value]
            do {
                guard let found = find(id: action.id) else { throw CatalogError("the accessory is gone") }
                result["name"] = .string(found.accessory.name)
                let target = try characteristic(in: found, service: action.service, characteristic: action.characteristic)
                if target.isSecurityControl, !allowSecurity {
                    held += 1
                    result["ok"] = false
                    result["skipped"] = .string(trigger == .manual
                        ? "a lock, door or alarm: a person confirms it (set_security_accessory, or the web UI)"
                        : "a lock, door or alarm: automations do not change them")
                    results.append(.object(result))
                    continue
                }
                let before = Self.value(of: target)
                _ = try await write(found, service: action.service, characteristic: action.characteristic, value: action.value, allowSecurity: allowSecurity)
                let light = lights.first { light in [light.on, light.brightness, light.hue, light.saturation, light.colorTemperature].compactMap { $0 }.contains { $0 === target } }
                // Only a successful write may take ownership from an existing mood.
                if let light, !changedLights.contains(where: { $0.key == light.key }) {
                    snapshots.merge(await takeOver([light], before: beforeLights)) { _, new in new }
                    changedLights.append(light)
                }
                let isLight = light != nil
                if !isLight, target.type.permissions.contains(.pairedRead), !target.isConfidential, !before.isNull {
                    if let index = expected.firstIndex(where: { $0.id == action.id && $0.service == action.service && $0.characteristic == action.characteristic }) {
                        if expected[index].value != before { undoActions[index].value = before }
                        expected[index].value = Self.value(of: target)
                    } else {
                        undoActions.append(SceneAction(id: action.id, service: action.service, characteristic: action.characteristic, value: before))
                        expected.append(SceneAction(id: action.id, service: action.service, characteristic: action.characteristic, value: Self.value(of: target)))
                    }
                }
                result["ok"] = true
            } catch {
                failed += 1
                result["ok"] = false
                result["error"] = .string(Redaction.redactText("\(error)"))
            }
            results.append(.object(result))
        }
        if !changedLights.isEmpty {
            let mood = Mood(id: "scene:" + scene.id, name: scene.name, steps: [MoodStep(changedLights.map(\.color), seconds: MoodRules.minSeconds)])
            _ = hold(mood, on: changedLights, snapshots: snapshots, by: "scene", room: nil)
        }
        var animated: JSONValue?
        if let animation = scene.animation { animated = await startAnimation(animation, of: scene, by: "scene \(trigger.rawValue)") }
        try home.sceneUndo.update { file in
            file = file.filter { Date().timeIntervalSince($0.value.at) < MoodRules.undoSeconds }
            file[scene.id] = SceneUndo(at: Date(), actions: undoActions, expected: expected)
        }
        let ok = failed == 0
        let note = held > 0 ? "\(held) security action(s) not run" : nil
        record(scene.id) { $0.lastRun = SceneRunRecord(at: SceneRules.now(), ok: ok, trigger: trigger.rawValue, reason: note) }
        if trigger != .manual, !ok {
            await notify(.sceneFailed, title: "Scene \(scene.name) failed", message: "\(failed) of \(scene.actions.count) actions failed when the \(trigger.rawValue) trigger ran it.", path: "/scenes", subject: scene.id)
        }
        var answer: [String: JSONValue] = ["sceneId": .string(scene.id), "name": .string(scene.name), "ok": .bool(ok), "results": .array(results)]
        if let note { answer["note"] = .string(note) }
        if let animated { answer["animation"] = animated }
        return .object(answer)
    }

    /// Stops a saved scene and restores its captured state. Later manual changes to non-light controls are preserved.
    public func stopScene(_ reference: String, allowSecurity: Bool = false) async throws -> JSONValue {
        // A saved scene by id or name; else what ran under this id (a hub's scene, a plan).
        let id: String
        if let scene = try? scene(reference) {
            id = scene.id
        } else if home.sceneUndo.value[reference] != nil || home.runningMoods.withLockedValue({ $0.values.contains { $0.mood.id == "scene:" + reference } }) {
            id = reference
        } else if let found = await pluginScene(reference) {
            id = found.id
        } else {
            throw CatalogError("No scene \"\(reference)\" to stop")
        }
        guard home.runningScenes.withLockedValue({ $0.insert(id).inserted }) else { throw CatalogError("This scene is already running") }
        defer { _ = home.runningScenes.withLockedValue { $0.remove(id) } }
        let undo = home.sceneUndo.value[id]
        let actions = undo.map { Date().timeIntervalSince($0.at) < MoodRules.undoSeconds ? $0.actions : [] } ?? []
        if !allowSecurity, actions.contains(where: { action in
            guard let found = find(id: action.id) else { return false }
            return (try? characteristic(in: found, service: action.service, characteristic: action.characteristic).isSecurityControl) == true
        }) { throw CatalogError("Confirm before restoring a lock, door or alarm") }
        if let native = home.nativeAnimations.withLockedValue({ $0.removeValue(forKey: id) }) { await host.stopAnimation(accessoryIDs: native) }
        let runs = home.runningMoods.withLockedValue { $0.values.filter { $0.mood.id == "scene:" + id }.map(\.id) }
        for run in runs { _ = try await stopMoods(id: run) }
        var failures: [JSONValue] = [], remaining: [SceneAction] = [], expected: [SceneAction] = []
        for (index, action) in actions.enumerated() {
            do {
                guard let found = find(id: action.id) else { throw CatalogError("the accessory is gone") }
                let target = try characteristic(in: found, service: action.service, characteristic: action.characteristic)
                guard Self.value(of: target) == undo?.expected[index].value else { continue }
                _ = try await write(found, service: action.service, characteristic: action.characteristic, value: action.value, allowSecurity: allowSecurity)
            } catch {
                remaining.append(action); expected.append(undo!.expected[index])
                failures.append(["id": .string(action.id), "error": .string(Redaction.redactText("\(error)"))])
            }
        }
        try home.sceneUndo.update { $0[id] = remaining.isEmpty ? nil : SceneUndo(at: undo!.at, actions: remaining, expected: expected) }
        return ["ok": .bool(failures.isEmpty), "failed": .array(failures)]
    }

    private func record(_ id: String, _ change: (inout Scene) -> Void) {
        do {
            try home.scenes.update { file in
                if let index = file.scenes.firstIndex(where: { $0.id == id }) { change(&file.scenes[index]) }
            }
        } catch {
            logger.debug("Could not save the scene's last run: \(error)")
        }
    }

    /// Why the conditions do not hold now, or nil when they all do.
    func conditionsFail(_ conditions: [SceneCondition], now: Date = Date()) -> String? {
        let location = home.scenes.value.location
        for condition in conditions {
            if condition.type == "time" {
                guard let inside = SceneRules.inWindow(condition, now: now, location: location, calendar: .current) else {
                    return "the time window uses sunrise or sunset, but no location is set"
                }
                if !inside { return "outside \(condition.after ?? "")–\(condition.before ?? "")" }
            } else {
                guard let found = find(id: condition.id ?? ""), let target = try? characteristic(in: found, service: condition.service, characteristic: condition.characteristic ?? "") else {
                    return "\(condition.characteristic ?? "the characteristic") of the accessory could not be read"
                }
                let value = Self.json(target.value)
                if !SceneRules.compare(value, condition.operator ?? "eq", condition.value) {
                    return "\(target.type.name) is \(value.text()), not \(condition.operator ?? "eq") \(condition.value?.text() ?? "")"
                }
            }
        }
        return nil
    }

    // MARK: Automations

    /// Runs the timed triggers due at this minute.
    func runDueScenes(at now: Date, calendar: Calendar = .current) async {
        let file = home.scenes.value
        for scene in file.scenes {
            guard let trigger = scene.triggers.first(where: { SceneRules.due($0, at: now, location: file.location, calendar: calendar) }) else { continue }
            let kind: SceneRunTrigger = trigger.type == "sun" ? .sun : .schedule
            logger.info("Running scene \"\(scene.name)\" (\(trigger.type == "sun" ? trigger.event?.rawValue ?? "sun" : "schedule"))")
            do { _ = try await runScene(scene.id, trigger: kind) } catch { logger.warning("Scene \"\(scene.name)\" (\(kind.rawValue)) failed: \(error)") }
        }
    }

    static func watchKey(_ id: String, _ characteristic: String) -> String { "\(id)|\(normalized(characteristic))" }

    /// Reads the current value of every characteristic a trigger watches, so its first change has something to
    /// compare with.
    func seedWatchedValues() {
        var values: [String: HAPValue] = [:]
        for scene in home.scenes.value.scenes {
            for trigger in scene.triggers where trigger.type == "characteristic" && trigger.isEnabled {
                guard let id = trigger.id, let name = trigger.characteristic, let found = find(id: id),
                      let target = try? characteristic(in: found, service: trigger.service, characteristic: name) else { continue }
                values[Self.watchKey(id, target.type.name)] = target.value
            }
        }
        home.watched.withLockedValue { watched in
            for (key, value) in values where watched.values[key] == nil { watched.values[key] = value }
        }
    }

    /// A characteristic changed: runs the scenes whose triggers fire, each at most once per 5 seconds.
    func characteristicChanged(_ accessory: Accessory, _ characteristic: Characteristic, _ value: HAPValue, now: Date = Date()) {
        // Every change of every accessory comes here: the accessory's id first, the names only for its triggers.
        let scenes = home.scenes.value.scenes
        guard scenes.contains(where: { $0.triggers.contains { $0.type == "characteristic" && $0.id == accessory.id } }) else { return }
        let name = Self.normalized(characteristic.type.name)
        let watching = scenes.contains { $0.triggers.contains { $0.type == "characteristic" && $0.id == accessory.id && Self.normalized($0.characteristic ?? "") == name } }
        guard watching else { return }
        let key = Self.watchKey(accessory.id, characteristic.type.name)
        let previous = home.watched.withLockedValue { watched -> HAPValue? in
            defer { watched.values[key] = value }
            return watched.values[key]
        }
        for scene in scenes {
            for trigger in scene.triggers where trigger.type == "characteristic" && trigger.isEnabled && trigger.id == accessory.id
                && Self.normalized(trigger.characteristic ?? "") == name {
                guard SceneRules.fires(trigger, previous: previous.map(Self.json), next: Self.json(value)) else { continue }
                let cooldownKey = "\(scene.id)|\(key)"
                let allowed = home.watched.withLockedValue { watched -> Bool in
                    if let last = watched.fired[cooldownKey], now.timeIntervalSince(last) < SceneRules.cooldown { return false }
                    watched.fired[cooldownKey] = now
                    return true
                }
                guard allowed else { continue }
                logger.info("Running scene \"\(scene.name)\": \(characteristic.type.name) of \(accessory.name) changed to \(Self.json(value).text())")
                let catalog = self
                Task { do { _ = try await catalog.runScene(scene.id, trigger: .characteristic) } catch { catalog.logger.warning("Scene \"\(scene.name)\" failed: \(error)") } }
                break
            }
        }
    }

    // MARK: Tools

    var sceneTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "list_scenes", title: "List scenes",
                description: "The scenes: scenes kept by Homeswift, named sets of accessory values applied together, with their room, whether they are active now, their actions "
                    + "(security: true marks a lock, door or alarm), triggers (time of day and days, cron, sunrise or sunset with an offset, a characteristic change), conditions and last run; "
                    + "and pluginScenes, the scenes plugins' hubs keep (a Hue Bridge's, an IKEA hub's, a Govee light's), with their room, source and whether the hub reports them active. "
                    + "run_scene runs either kind by id.",
                outputSchema: Output.object(["scenes": ["type": "array"], "pluginScenes": ["type": "array"]], required: ["scenes"]),
                scope: .read, idempotent: true
            ) { _ in .json(await catalog.allScenesJSON()) },
            MCPTool(
                name: "run_scene", title: "Run scene",
                description: "Runs a scene now and answers the result per action: a saved one or a hub's (scene, from list_scenes), or one you compose (plan), which is not saved. "
                    + "Compose a plan for an ambiance the user describes: set the room's lights (On, Brightness, Hue, Saturation, Color Temperature), recall a hub's scene where one fits, "
                    + "and add an animation (a fire, a candle, a sunrise…) when the lights should move. "
                    + "What a run changes can be put back for 12 hours with stop_scene (a plan by the run it answers); save_scene keeps a plan the user likes. "
                    + "Scenes and plans that lock or unlock, open or close, or arm or disarm something are refused: apply those actions with set_security_accessory, which asks the user to confirm, "
                    + "or let the user run the scene in the web UI.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "scene": ["type": "string", "minLength": 1, "description": "The scene id or name, from list_scenes (scenes or pluginScenes)"],
                        "plan": HomeswiftCatalog.planSchema,
                        "template": ["type": "string", "description": "A template's id, from list_scene_templates, for the lights of room (or ids)"],
                        "description": ["type": "string", "maxLength": 500, "description": "An ambiance in words that the bridge's Assistant turns into a plan for the lights of room (or ids)"],
                        "room": ["type": "string", "description": "With template or description: the room whose lights it sets"],
                        "ids": ["type": "array", "items": ["type": "string"], "description": "With template or description: the lights it sets, instead of a room"],
                    ],
                ],
                scope: .control, idempotent: true
            ) { call in
                if call.arguments["template"] != nil || call.arguments["description"] != nil {
                    return .json(try await catalog.tryScene(call.arguments))
                }
                if let plan = call.arguments["plan"] {
                    guard call.arguments["scene"] == nil else { return .error("Pass scene or plan, not both") }
                    let scene = try catalog.planScene(plan)
                    if let refusal = catalog.securityRefusal(scene) { return .error(refusal) }
                    return .json(try await catalog.runPlan(plan))
                }
                let reference = try call.string("scene")
                guard let scene = try? catalog.scene(reference) else {
                    guard let found = await catalog.pluginScene(reference) else { return .json(try await catalog.runScene(reference)) }
                    return .json(try await catalog.runPluginScene(found, by: "MCP \(call.session.principal.name)"))
                }
                if let refusal = catalog.securityRefusal(scene) { return .error(refusal) }
                return .json(try await catalog.runScene(scene.id, trigger: .manual))
            },
            MCPTool(
                name: "list_scene_templates", title: "List scene templates",
                description: "Ready-made ambiances to start a scene from: calm ones that set the lights once (candlelight, cinema, focus), effects each brand plays its own way "
                    + "(a fireplace, a candle flicker, an ocean, a sunrise), timed sequences (disco, a police siren, an alert flash) and the gallery's pictures, each a palette. "
                    + "run_scene with template and room tries one on a room's lights; save_scene with template, room and name keeps it.",
                outputSchema: Output.object(["templates": ["type": "array"]], required: ["templates"]),
                scope: .read, idempotent: true
            ) { _ in .json(["templates": .array(MoodLibrary.all.map { mood in
                var entry = HomeswiftCatalog.templateJSON(mood).objectValue ?? [:]
                entry.removeValue(forKey: "swatch")
                return .object(entry)
            })]) },
            MCPTool(
                name: "stop_scene", title: "Stop scene",
                description: "Puts back what a scene changed when it ran in the last 12 hours, and stops it if it still plays: a saved scene, a hub's scene, or a plan by the run run_scene answered. "
                    + "A value changed since the run is left as it is. Restoring a lock, garage door or alarm is refused: the user does it in the web UI.",
                inputSchema: ["type": "object", "required": ["scene"], "properties": ["scene": ["type": "string", "minLength": 1, "description": "A scene's id or name, a hub scene's id, or a plan's run"]]],
                scope: .control, idempotent: true
            ) { call in
                .json(try await catalog.stopScene(try call.string("scene")))
            },
            MCPTool(
                name: "save_scene", title: "Save scene",
                description: "Creates a scene the user can run again with run_scene or from the web UI's Scenes page: from a plan (one run_scene ran, or a new one), "
                    + "or from the current values of the chosen accessories (ids), every writable characteristic unless characteristics names some (On, Brightness…). "
                    + "Locks, garage doors and alarms are never captured. dryRun shows the actions first.",
                inputSchema: [
                    "type": "object", "required": ["name"],
                    "properties": [
                        "name": ["type": "string", "minLength": 1, "maxLength": 64],
                        "plan": HomeswiftCatalog.planSchema,
                        "template": ["type": "string", "description": "A template's id, from list_scene_templates, for the lights of room (or ids)"],
                        "description": ["type": "string", "maxLength": 500, "description": "An ambiance in words that the bridge's Assistant turns into the scene, for the lights of room (or ids)"],
                        "room": ["type": "string", "description": "With template or description: the room whose lights it sets"],
                        "ids": ["type": "array", "minItems": 1, "maxItems": 50, "items": ["type": "string"], "description": "The accessories to capture, from list_accessories (with template or description: the lights it sets)"],
                        "characteristics": ["type": "array", "minItems": 1, "items": ["type": "string"], "description": "Only these characteristics, e.g. On, Brightness"],
                    ],
                ],
                scope: .admin, supportsDryRun: true
            ) { call in
                let name = try call.string("name").trimmingCharacters(in: .whitespaces)
                if call.arguments["template"] != nil || call.arguments["description"] != nil {
                    return .json(try catalog.savePlan(try await catalog.composedPlan(call.arguments, language: nil).plan, name: name, dryRun: call.isDryRun))
                }
                if let plan = call.arguments["plan"] {
                    return .json(try catalog.savePlan(plan, name: name, dryRun: call.isDryRun))
                }
                let ids = call.arguments["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard !ids.isEmpty else { return .error("Pass a plan, or the ids of the accessories to capture") }
                let wanted = call.arguments["characteristics"]?.arrayValue?.compactMap(\.stringValue)
                return .json(try catalog.captureScene(name: name, ids: ids, characteristics: wanted, dryRun: call.isDryRun))
            },
        ]
    }
}
