import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

@testable import HomeswiftWingman

/// Wingman in memory, answering as its LocalServer does: `/info` and `/pair` open, the rest behind the token; a home
/// with a colour light (Matter, through a Hue bridge), a switch on a Homeswift bridge (left out), a temperature
/// sensor that does not respond and a lock; its rooms, scenes and automations (docs/apple-home-design.md).
final class FakeWingman: WingmanTransportFactory, @unchecked Sendable {
    static let fingerprint = String(repeating: "3f9a0c71", count: 8)
    static let token = "token-1"
    static let code = "482913"

    struct Write: Equatable {
        var accessory: String
        var characteristic: String
        var value: String
    }

    private struct State {
        var events: [[String: Any]] = []
        var seq = 0
        var writes: [Write] = []
        var tls: [HTTPClient.TLS] = []
        var tokenValid = true
        var reachable = true
        var requests: [String] = []
        /// Events older than this are gone, as Wingman keeps 500 at most.
        var keptFrom = 1
        /// Accessories removed in the Home app.
        var removed: Set<String> = []
        /// Accessories Apple Home says are not reachable, besides those the home lists so.
        var unreachable: Set<String> = []
        /// Whether it serves rooms, scenes and automations (an older Wingman does not).
        var servesStructure = true
        /// Its owner's **Let bridges edit rooms, scenes and automations**.
        var allowStructure = true
        /// Whether this Mac's user administers the home.
        var administrator = true
        var roomNames: [String: String] = [:]
        var scenes: [[String: Any]] = FakeWingman.initialScenes
        var automations: [[String: Any]] = FakeWingman.initialAutomations
        var edits: [Edit] = []
        var created = 0
    }

    /// A structural edit Wingman took (or refused), with its body.
    struct Edit: Equatable {
        var path: String
        var body: JSONValue
    }

    private let state = NIOLockedValueBox(State())

    var writes: [Write] { state.withLockedValue { $0.writes } }
    var edits: [Edit] { state.withLockedValue { $0.edits } }
    var scenes: [[String: Any]] { state.withLockedValue { $0.scenes } }
    var automations: [[String: Any]] { state.withLockedValue { $0.automations } }

    /// An older Wingman, without the structure endpoints.
    func withoutStructure() { state.withLockedValue { $0.servesStructure = false } }

    /// Its owner turns structural edits off (or on): a "settings" event.
    func allowStructure(_ allowed: Bool) {
        state.withLockedValue { state in
            state.allowStructure = allowed
            state.seq += 1
            state.events.append(["seq": state.seq, "kind": "settings"])
        }
    }

    /// This Mac's user is not an administrator of the home.
    func notAdministrator() { state.withLockedValue { $0.administrator = false } }

    /// A room renamed in the Home app: a "homes" event, `/homes` with the new name.
    func renameRoomInAppleHome(_ id: String, to name: String) {
        state.withLockedValue { state in
            state.roomNames[id] = name
            state.seq += 1
            state.events.append(["seq": state.seq, "kind": "homes", "home": "Maison"])
        }
    }

    /// A scene renamed in the Home app: a "scenes" event.
    func renameSceneInAppleHome(_ id: String, to name: String) {
        state.withLockedValue { state in
            if let index = state.scenes.firstIndex(where: { $0["id"] as? String == id }) { state.scenes[index]["name"] = name }
            state.seq += 1
            state.events.append(["seq": state.seq, "kind": "scenes", "home": "Maison"])
        }
    }
    var tlsModes: [HTTPClient.TLS] { state.withLockedValue { $0.tls } }
    /// The paths asked, in order (`events`, `homes`…).
    var requests: [String] { state.withLockedValue { $0.requests } }

    /// Wingman dropped every event so far, as when more than 500 came while Homeswift was away.
    func dropKeptEvents() {
        state.withLockedValue { state in
            state.seq += 3
            state.keptFrom = state.seq + 1
            state.events = []
        }
    }

    /// A value change HomeKit pushed, as Wingman reports it.
    func push(accessory: String, characteristic: String, type: String, value: Any) {
        state.withLockedValue { state in
            state.seq += 1
            state.events.append(["seq": state.seq, "accessoryID": accessory, "characteristicID": characteristic, "type": type, "value": value])
        }
    }

    /// An accessory removed in the Home app, as Wingman reports it: gone from `/homes`, and a "homes" event.
    func remove(accessory: String) {
        state.withLockedValue { state in
            state.removed.insert(accessory)
            state.seq += 1
            state.events.append(["seq": state.seq, "kind": "homes", "home": "Maison", "accessory": accessory])
        }
    }

    /// A room or a name changed in the Home app: a "homes" event, `/homes` as it was.
    func changeHomes() {
        state.withLockedValue { state in
            state.seq += 1
            state.events.append(["seq": state.seq, "kind": "homes", "home": "Maison", "accessory": ""])
        }
    }

    /// Apple Home says this accessory is not reachable (HomeKit's reachability lags for Matter devices).
    func markUnreachable(_ accessory: String) { state.withLockedValue { _ = $0.unreachable.insert(accessory) } }

    /// Wingman's menu removed this bridge.
    func forgetBridge() { state.withLockedValue { $0.tokenValid = false } }

    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending {
        state.withLockedValue { $0.tls.append(tls) }
        return Transport(wingman: self)
    }

    struct Transport: HTTPSending {
        let wingman: FakeWingman
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            try await wingman.answer(request)
        }
    }

    private func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object), certificateFingerprint: Self.fingerprint)
    }

    func answer(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        state.withLockedValue { $0.requests.append(String(path.dropFirst())) }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch (request.method, path) {
        case ("GET", "/info"):
            var info: [String: Any] = ["service": "homeswift-wingman", "api": "1", "id": "wm-1", "version": "0.2.0", "fingerprint": Self.fingerprint, "pairing": true]
            state.withLockedValue { state in
                if state.servesStructure {
                    info["features"] = ["structure"]
                    info["structure"] = state.allowStructure
                }
            }
            return json(info)
        case ("POST", "/pair"):
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            guard body?["code"] as? String == Self.code else { return json(["error": "wrong code"], status: 403) }
            return json(["token": Self.token, "bridge": "b-1", "wingman": "wm-1", "fingerprint": Self.fingerprint])
        default: break
        }
        let authorized = request.headers.contains { $0.name == "Authorization" && $0.value == "Bearer \(Self.token)" }
        guard authorized, state.withLockedValue({ $0.tokenValid }) else { return json(["error": "pair first"], status: 401) }
        switch (request.method, path) {
        case ("GET", "/homes"):
            let (removed, unreachable, roomNames, administrator, structure) = state.withLockedValue { ($0.removed, $0.unreachable, $0.roomNames, $0.administrator, $0.servesStructure) }
            var home = Self.home
            let rooms = Self.rooms.map { id, name in (id: id, original: name, name: roomNames[id] ?? name) }
            home["accessories"] = (home["accessories"] as? [[String: Any]] ?? []).compactMap { accessory -> [String: Any]? in
                let id = accessory["id"] as? String ?? ""
                guard !removed.contains(id) else { return nil }
                var accessory = accessory
                if unreachable.contains(id) { accessory["reachable"] = false }
                if let room = rooms.first(where: { $0.original == accessory["room"] as? String }) { accessory["room"] = room.name }
                return accessory
            }
            if structure {
                home["editable"] = administrator
                home["rooms"] = rooms.map { ["id": $0.id, "name": $0.name, "accessories": 1] }
            }
            return json(["homes": [home]])
        case ("GET", "/events"):
            let since = Int(query["since"] ?? "") ?? 0
            let wait = Double(query["wait"] ?? "") ?? 0
            var answer = state.withLockedValue { state in (state.events.filter { ($0["seq"] as? Int ?? 0) > since }, state.seq, state.keptFrom) }
            if answer.0.isEmpty, wait > 0 {
                // A short wait stands for the long-poll.
                try await Task.sleep(for: .milliseconds(50))
                answer = state.withLockedValue { state in (state.events.filter { ($0["seq"] as? Int ?? 0) > since }, state.seq, state.keptFrom) }
            }
            return json(["events": answer.0, "last": answer.1, "first": answer.2])
        case ("POST", "/write"):
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
            let write = Write(accessory: body["accessory"] as? String ?? "", characteristic: body["characteristic"] as? String ?? "", value: "\(body["value"] ?? "")")
            state.withLockedValue { $0.writes.append(write) }
            if write.characteristic == "light-saturation" { return HTTPResponse(status: 500, body: Data()) }
            if write.characteristic == "lock-target" {
                return json(["error": "Lock Target State is a security control; not written through Wingman"], status: 422)
            }
            return json(["written": body["value"] ?? NSNull()])
        case ("GET", "/scenes") where state.withLockedValue({ $0.servesStructure }):
            return json(["scenes": state.withLockedValue { $0.scenes }])
        case ("GET", "/automations") where state.withLockedValue({ $0.servesStructure }):
            return json(["automations": state.withLockedValue { $0.automations }])
        case ("POST", _) where state.withLockedValue({ $0.servesStructure }) && Self.editPaths.contains(String(path.dropFirst())):
            return edit(String(path.dropFirst()), body: request.body ?? Data())
        default:
            return json(["error": "not found"], status: 404)
        }
    }

    static let editPaths: Set<String> = [
        "rooms/rename", "scenes/run", "scenes/rename", "scenes/actions", "scenes/create", "scenes/delete",
        "automations/enable", "automations/rename", "automations/time", "automations/scenes", "automations/actions", "automations/delete",
    ]

    /// Applies an edit as Wingman would, with the event it makes.
    private func edit(_ path: String, body data: Data) -> HTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return state.withLockedValue { state -> HTTPResponse in
            state.edits.append(Edit(path: path, body: (try? JSONValue(data: data)) ?? .null))
            if path != "scenes/run" {
                guard state.allowStructure else { return json(["error": "structural edits are turned off in Wingman's settings"], status: 403) }
                guard state.administrator else { return json(["error": "only an administrator of the home can change it"], status: 403) }
            }
            func event(_ kind: String) {
                state.seq += 1
                state.events.append(["seq": state.seq, "kind": kind, "home": "Maison"])
            }
            let scene = state.scenes.firstIndex { $0["id"] as? String == body["scene"] as? String }
            let automation = state.automations.firstIndex { $0["id"] as? String == body["automation"] as? String }
            switch path {
            case "rooms/rename":
                guard let id = body["room"] as? String, Self.rooms.contains(where: { $0.0 == id }), let name = body["name"] as? String else { break }
                state.roomNames[id] = name
                event("homes")
                return json(["renamed": id])
            case "scenes/run":
                guard scene != nil else { break }
                return json(["ran": body["scene"] ?? ""])
            case "scenes/rename":
                guard let scene else { break }
                state.scenes[scene]["name"] = body["name"]
                event("scenes")
                return json(["renamed": body["scene"] ?? ""])
            case "scenes/actions":
                guard let scene else { break }
                state.scenes[scene]["actions"] = Self.typed(body["actions"])
                event("scenes")
                return json(["actions": (body["actions"] as? [Any])?.count ?? 0])
            case "scenes/create":
                state.created += 1
                let id = "scene-new-\(state.created)"
                state.scenes.append(["id": id, "home": body["home"] ?? "", "name": body["name"] ?? "", "type": "user", "builtIn": false,
                                     "actions": Self.typed(body["actions"]), "unsupported": 0])
                event("scenes")
                return json(["id": id])
            case "scenes/delete":
                guard let scene else { break }
                state.scenes.remove(at: scene)
                event("scenes")
                return json(["deleted": body["scene"] ?? ""])
            case "automations/enable", "automations/rename", "automations/time", "automations/scenes", "automations/actions":
                guard let automation else { break }
                switch path {
                case "automations/enable": state.automations[automation]["enabled"] = body["enabled"]
                case "automations/rename": state.automations[automation]["name"] = body["name"]
                case "automations/time": state.automations[automation]["trigger"] = ["kind": "time", "time": body["time"] ?? [:]]
                case "automations/scenes": state.automations[automation]["scenes"] = body["scenes"]
                default: state.automations[automation]["actions"] = Self.typed(body["actions"])
                }
                event("automations")
                return json(["changed": body["automation"] ?? ""])
            case "automations/delete":
                guard let automation else { break }
                state.automations.remove(at: automation)
                event("automations")
                return json(["deleted": body["automation"] ?? ""])
            default: break
            }
            return json(["error": "no such room, scene or automation"], status: 404)
        }
    }

    /// Actions as Wingman lists them: with each characteristic's type, from the home.
    private static func typed(_ actions: Any?) -> [[String: Any]] {
        (actions as? [[String: Any]] ?? []).map { action in
            var action = action
            action["type"] = characteristicTypes[action["characteristic"] as? String ?? ""]
            return action
        }
    }

    /// Every characteristic's type, by id.
    nonisolated(unsafe) static let characteristicTypes: [String: String] = {
        var types: [String: String] = [:]
        for accessory in home["accessories"] as? [[String: Any]] ?? [] {
            for service in accessory["services"] as? [[String: Any]] ?? [] {
                for characteristic in service["characteristics"] as? [[String: Any]] ?? [] {
                    if let id = characteristic["id"] as? String { types[id] = characteristic["type"] as? String }
                }
            }
        }
        return types
    }()

    static let rooms = [("room-salon", "Salon"), ("room-bureau", "Bureau"), ("room-cave", "Cave"), ("room-entree", "Entrée")]

    static let on = "00000025-0000-1000-8000-0026BB765291"
    static let brightness = "00000008-0000-1000-8000-0026BB765291"
    static let hue = "00000013-0000-1000-8000-0026BB765291"
    static let saturation = "0000002F-0000-1000-8000-0026BB765291"

    /// "Soirée": the light in a colour and the Homeswift plug (not mirrored); "Lecture": the light alone, in the Salon;
    /// "Bonjour", built in; "Raccourci", with a shortcut action Wingman cannot show.
    nonisolated(unsafe) static let initialScenes: [[String: Any]] = [
        ["id": "scene-evening", "home": "home-1", "name": "Soirée", "type": "user", "builtIn": false, "unsupported": 0, "actions": [
            ["accessory": "light-1", "characteristic": "light-on", "type": on, "value": true],
            ["accessory": "light-1", "characteristic": "light-brightness", "type": brightness, "value": 30],
            ["accessory": "light-1", "characteristic": "light-hue", "type": hue, "value": 30],
            ["accessory": "light-1", "characteristic": "light-saturation", "type": saturation, "value": 80],
            ["accessory": "homeswift-switch", "characteristic": "switch-on", "type": on, "value": true],
        ]],
        ["id": "scene-reading", "home": "home-1", "name": "Lecture", "type": "user", "builtIn": false, "unsupported": 0, "actions": [
            ["accessory": "light-1", "characteristic": "light-on", "type": on, "value": true],
            ["accessory": "light-1", "characteristic": "light-ct", "type": "000000CE-0000-1000-8000-0026BB765291", "value": 370],
        ]],
        ["id": "scene-wake", "home": "home-1", "name": "Bonjour", "type": "wakeUp", "builtIn": true, "unsupported": 0, "actions": [
            ["accessory": "light-1", "characteristic": "light-on", "type": on, "value": true],
        ]],
        ["id": "scene-shortcut", "home": "home-1", "name": "Raccourci", "type": "user", "builtIn": false, "unsupported": 1, "actions": []],
    ]

    /// At sunset on weekdays before 23:00, "Soirée"; when it is warm in the cellar, the light for ten minutes if anyone
    /// is home; when someone arrives, off.
    nonisolated(unsafe) static let initialAutomations: [[String: Any]] = [
        ["id": "auto-sunset", "home": "home-1", "name": "Coucher du soleil", "enabled": true, "lastFired": "2026-11-01T17:12:03Z",
         "trigger": ["kind": "time", "time": ["significant": "sunset", "offsetMinutes": -15, "weekdays": [2, 3, 4, 5, 6]]],
         "conditions": [["kind": "time", "before": ["hour": 23, "minute": 0]]],
         "scenes": ["scene-evening"], "actions": [], "unsupported": 0],
        ["id": "auto-warm", "home": "home-1", "name": "Cave chaude", "enabled": true,
         "trigger": ["kind": "event", "events": [["kind": "threshold", "accessory": "sensor-1", "characteristic": "temp", "type": "00000011-0000-1000-8000-0026BB765291", "min": 25]]],
         "endEvents": [["kind": "duration", "seconds": 600]],
         "conditions": [["kind": "presence", "who": "anyone", "home": true], ["kind": "other", "text": "SUBQUERY(...)"]],
         "scenes": [], "actions": [["accessory": "light-1", "characteristic": "light-on", "type": on, "value": true]], "unsupported": 0],
        ["id": "auto-arrive", "home": "home-1", "name": "Arrivée", "enabled": false,
         "trigger": ["kind": "event", "events": [["kind": "presence", "who": "anyone", "arriving": true]]],
         "scenes": [], "actions": [["accessory": "light-1", "characteristic": "light-on", "type": on, "value": false]], "unsupported": 1],
    ]

    static let lightbulb = "00000043-0000-1000-8000-0026BB765291"

    nonisolated(unsafe) static let home: [String: Any] = [
        "id": "home-1", "name": "Maison",
        "accessories": [
            [
                "id": "light-1", "name": "Plafonnier", "room": "Salon", "reachable": true, "manufacturer": "Signify", "model": "Hue color", "matter": true,
                "bridge": ["id": "hue-bridge", "name": "Hue Bridge", "manufacturer": "Signify"],
                "services": [
                    ["id": "info-1", "type": "0000003E-0000-1000-8000-0026BB765291", "characteristics": [
                        ["id": "light-identify", "type": "00000014-0000-1000-8000-0026BB765291", "properties": ["write"], "format": "bool"],
                        ["id": "c-name", "type": "00000023-0000-1000-8000-0026BB765291", "properties": ["read"], "value": "Plafonnier", "format": "string"],
                    ]],
                    ["id": "bulb-1", "name": "Plafonnier", "type": lightbulb, "primary": true, "characteristics": [
                        ["id": "light-on", "type": "00000025-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 1, "format": "bool"],
                        ["id": "light-brightness", "type": "00000008-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 40, "format": "int", "min": 0, "max": 100, "step": 1],
                        ["id": "light-hue", "type": "00000013-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 30, "format": "float", "min": 0, "max": 360],
                        ["id": "light-saturation", "type": "0000002F-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 80, "format": "float"],
                        ["id": "light-ct", "type": "000000CE-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 300, "format": "int", "min": 153, "max": 454, "step": 1],
                    ]],
                ],
            ],
            [
                "id": "homeswift-switch", "name": "Plug from Homeswift", "room": "Bureau", "reachable": true, "manufacturer": "Meross",
                "bridge": ["id": "homeswift-bridge", "name": "Homeswift", "manufacturer": "Homeswift", "model": "Homeswift"],
                "services": [
                    ["id": "switch-1", "type": "00000049-0000-1000-8000-0026BB765291", "characteristics": [
                        ["id": "switch-on", "type": "00000025-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 0, "format": "bool"],
                    ]],
                ],
            ],
            [
                "id": "sensor-1", "name": "Thermomètre", "room": "Cave", "reachable": false, "manufacturer": "Eve",
                "services": [
                    ["id": "temp-1", "type": "0000008A-0000-1000-8000-0026BB765291", "primary": true, "characteristics": [
                        ["id": "temp", "type": "00000011-0000-1000-8000-0026BB765291", "properties": ["read", "events"], "value": 12.5, "format": "float", "min": -100, "max": 100, "step": 0.1],
                    ]],
                ],
            ],
            [
                // Published by Homeswift on its own (a TV, a camera): not bridged, known by its serial number.
                "id": "tv-1", "name": "Salon TV", "room": "Salon", "reachable": true, "manufacturer": "Philips",
                "services": [
                    ["id": "tv-info", "type": "0000003E-0000-1000-8000-0026BB765291", "characteristics": [
                        ["id": "tv-serial", "type": "00000030-0000-1000-8000-0026BB765291", "properties": ["read"], "value": "TV-SERIAL", "format": "string"],
                    ]],
                    ["id": "tv-switch", "type": "00000049-0000-1000-8000-0026BB765291", "primary": true, "characteristics": [
                        ["id": "tv-on", "type": "00000025-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 0, "format": "bool"],
                    ]],
                ],
            ],
            [
                "id": "lock-1", "name": "Porte", "room": "Entrée", "reachable": true, "manufacturer": "Nuki",
                "services": [
                    ["id": "lock-service", "type": "00000045-0000-1000-8000-0026BB765291", "primary": true, "characteristics": [
                        ["id": "lock-current", "type": "0000001D-0000-1000-8000-0026BB765291", "properties": ["read", "events"], "value": 1, "format": "uint8"],
                        ["id": "lock-target", "type": "0000001E-0000-1000-8000-0026BB765291", "properties": ["read", "write", "events"], "value": 1, "format": "uint8"],
                    ]],
                ],
            ],
        ],
    ]
}
