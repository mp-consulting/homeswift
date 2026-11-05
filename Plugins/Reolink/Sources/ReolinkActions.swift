import Foundation
import HomeswiftPlugin

// PTZ for MCP clients and the Assistant (addendum B): HomeKit has no PTZ service, so the moves, zoom, presets, patrols and
// the guard are routes of `handleWebRequest`, described as `assistantActions`; the web UI's live view gets the moves,
// presets and guard through `cameraControls` and `controlCamera` (HomeswiftPlugin's `CameraControls`). Moving a camera changes what it watches,
// so every route that moves one needs the configure scope; listing them needs read.
extension ReolinkPlugin {
    /// The longest move the Assistant may ask for before the plugin stops it.
    static let longestMove: Double = 10

    public static let assistantActions: [AssistantAction] = {
        let camera: JSONValue = ["type": "string", "description": "The camera's accessory id (Reolink:<Device Id>), from list_ptz_cameras"]
        return [
            AssistantAction(
                name: "list_ptz_cameras", title: "Look at the PTZ cameras",
                description: "The cameras that pan, tilt or zoom, by accessory id: which moves each makes, whether it takes a speed, its presets "
                    + "(id and name), its patrols, whether it has a home position (guard), its zoom and focus ranges, and whether a patrol runs.",
                path: "ptz", access: .read),
            AssistantAction(
                name: "move_camera", title: "Move a camera",
                description: "Moves a PTZ camera in a direction, or zooms it (zoomIn, zoomOut), for a number of seconds (default 1, at most 10), "
                    + "then stops it. Only the moves list_ptz_cameras gives for that camera; speed (1 to 64) only where it says it takes one.",
                method: "POST", path: "ptz/move", access: .configure,
                inputSchema: [
                    "type": "object", "required": ["camera", "direction"],
                    "properties": [
                        "camera": camera,
                        "direction": ["type": "string", "enum": .array(ReolinkPTZ.moves.keys.sorted().map(JSONValue.string))],
                        "seconds": ["type": "number", "minimum": 0.1, "maximum": .number(longestMove)],
                        "speed": ["type": "integer", "minimum": 1, "maximum": 64],
                    ],
                ]),
            AssistantAction(
                name: "go_to_preset", title: "Turn a camera to a preset",
                description: "Turns a PTZ camera to one of its presets, by id or by name (from list_ptz_cameras).",
                method: "POST", path: "ptz/preset", access: .configure,
                inputSchema: [
                    "type": "object", "required": ["camera", "preset"],
                    "properties": ["camera": camera, "preset": ["description": "The preset's id or name"], "speed": ["type": "integer", "minimum": 1, "maximum": 64]],
                ]),
            AssistantAction(
                name: "run_patrol", title: "Start or stop a patrol",
                description: "Starts (run true) or stops (run false) a PTZ camera's first patrol, the tour of presets set up in the Reolink app.",
                method: "POST", path: "ptz/patrol", access: .configure,
                inputSchema: ["type": "object", "required": ["camera", "run"], "properties": ["camera": camera, "run": ["type": "boolean"]]]),
            AssistantAction(
                name: "camera_home_position", title: "Use a camera's home position",
                description: "A PTZ camera's guard (home position): action goHome turns it there; setHome saves where it points now as home; "
                    + "configure changes only whether it returns home on its own (returns) and after how many idle seconds (timeout).",
                method: "POST", path: "ptz/guard", access: .configure,
                inputSchema: [
                    "type": "object", "required": ["camera", "action"],
                    "properties": [
                        "camera": camera, "action": ["type": "string", "enum": ["goHome", "setHome", "configure"]],
                        "returns": ["type": "boolean"], "timeout": ["type": "integer", "minimum": 1],
                    ],
                ]),
            AssistantAction(
                name: "zoom_camera", title: "Zoom or focus a camera",
                description: "Sets a camera's zoom or focus to a position within the range list_ptz_cameras gives (a value outside is refused).",
                method: "POST", path: "ptz/zoom", access: .configure,
                inputSchema: [
                    "type": "object", "required": ["camera"],
                    "properties": ["camera": camera, "zoom": ["type": "integer"], "focus": ["type": "integer"]],
                ]),
        ]
    }()

    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "ptz"):
            return PluginWebResponse(["cameras": .array(await ptzCameras())])
        case ("POST", let path) where path.hasPrefix("ptz/"):
            guard let id = request.body["camera"]?.stringValue, let target = await ptzTarget(id) else {
                return .error(404, "no PTZ camera with that id: list_ptz_cameras gives them")
            }
            do {
                return try await ptz(String(path.dropFirst(4)), request.body, host: target.host, channel: target.channel, ptz: target.ptz)
            } catch let error as ReolinkError {
                switch error {
                case .unsupported, .outOfRange: return .error(400, error.description)
                default: return .error(502, error.description)
                }
            }
        default:
            return .error(404, "not found")
        }
    }

    private func ptz(_ route: String, _ body: JSONValue, host: ReolinkHost, channel: Int, ptz: ReolinkPTZ) async throws -> PluginWebResponse {
        let speed = body["speed"]?.saturatingIntValue
        switch route {
        case "move":
            guard let direction = body["direction"]?.stringValue, let op = ReolinkPTZ.moves[direction] else { return .error(400, "an unknown direction") }
            guard ptz.allows(direction) else { return .error(400, "this camera does not \(direction == "stop" ? "move" : "make the move \(direction)")") }
            try await host.ptzControl(channel: channel, op: op, speed: speed)
            guard op != "Stop" else { return PluginWebResponse(["ok": true]) }
            // Moves go on until `Stop`: the plugin sends it, so a camera is never left turning.
            let seconds = min(Self.longestMove, max(0.1, body["seconds"]?.doubleValue ?? 1))
            try? await Task.sleep(for: dependencies.timing.seconds(seconds))
            try await host.ptzControl(channel: channel, op: "Stop")
            return PluginWebResponse(["ok": true, "seconds": .number(seconds)])
        case "preset":
            let wanted = body["preset"]
            let preset = ptz.presets.first { entry in
                if let id = wanted?.saturatingIntValue { return entry.id == id }
                return entry.name.caseInsensitiveCompare(wanted?.stringValue ?? "") == .orderedSame || String(entry.id) == wanted?.stringValue
            }
            guard let preset else { return .error(400, "no such preset: list_ptz_cameras gives them") }
            try await host.ptzControl(channel: channel, op: "ToPos", id: preset.id, speed: speed)
            return PluginWebResponse(["ok": true, "preset": .string(preset.name)])
        case "patrol":
            guard let run = body["run"]?.boolValue else { return .error(400, "run must be true or false") }
            try await host.setPatrol(channel: channel, on: run)
            return PluginWebResponse(["ok": true])
        case "guard":
            switch body["action"]?.stringValue {
            case "goHome": try await host.ptzGuard(channel: channel, goHome: true, saveHere: false, enable: nil, timeout: nil)
            case let action? where action == "setHome" || action == "configure":
                try await host.ptzGuard(channel: channel, goHome: false, saveHere: action == "setHome", enable: body["returns"]?.boolValue, timeout: body["timeout"]?.saturatingIntValue)
            default: return .error(400, "action must be goHome, setHome or configure")
            }
            return PluginWebResponse(["ok": true])
        case "zoom":
            let zoom = body["zoom"]?.saturatingIntValue, focus = body["focus"]?.saturatingIntValue
            guard zoom != nil || focus != nil else { return .error(400, "give zoom or focus") }
            try await host.setZoomFocus(channel: channel, zoom: zoom, focus: focus)
            return PluginWebResponse(["ok": true])
        default:
            return .error(404, "not found")
        }
    }

    // MARK: The web UI's live view

    /// How long one step of the live view's pad turns a camera before `Stop`, in seconds.
    static let padStep: Double = 0.4

    /// A PTZ camera's moves, presets and guard for the pad over its live view (`CameraControls`).
    public func cameraControls(accessoryID: String) async -> CameraControls? {
        guard let target = await ptzTarget(accessoryID) else { return nil }
        let directions = CameraControls.Direction.allCases.filter { target.ptz.allows($0.rawValue) }
        guard !directions.isEmpty || !target.ptz.presets.isEmpty || target.ptz.hasGuard else { return nil }
        return CameraControls(directions: directions, presets: target.ptz.presets.map { CameraControls.Preset(id: String($0.id), name: $0.name) },
                              home: target.ptz.hasGuard)
    }

    /// One step of the pad (a move stopped after `padStep`, as `move_camera` stops its own), a preset, or the guard's
    /// home position.
    public func controlCamera(accessoryID: String, _ command: CameraCommand) async throws {
        guard let target = await ptzTarget(accessoryID) else { throw CameraControlError("no PTZ camera with that id") }
        do {
            switch command {
            case .move(let direction):
                guard target.ptz.allows(direction.rawValue), let op = ReolinkPTZ.moves[direction.rawValue] else {
                    throw CameraControlError("this camera does not move \(direction.rawValue)")
                }
                try await target.host.ptzControl(channel: target.channel, op: op)
                try? await Task.sleep(for: dependencies.timing.seconds(Self.padStep))
                try await target.host.ptzControl(channel: target.channel, op: "Stop")
            case .preset(let id):
                guard let preset = target.ptz.presets.first(where: { String($0.id) == id }) else { throw CameraControlError("no such preset") }
                try await target.host.ptzControl(channel: target.channel, op: "ToPos", id: preset.id)
            case .home:
                guard target.ptz.hasGuard else { throw CameraControlError("this camera has no home position") }
                try await target.host.ptzGuard(channel: target.channel, goHome: true, saveHere: false, enable: nil, timeout: nil)
            }
        } catch let error as ReolinkError {
            switch error {
            case .unsupported, .outOfRange: throw CameraControlError(error.description)
            default: throw error
            }
        }
    }

    /// The published cameras with PTZ.
    private func ptzCameras() async -> [JSONValue] {
        var list: [JSONValue] = []
        for runtime in runtimes.values {
            for (channel, camera) in runtime.cameras.sorted(by: { $0.key < $1.key }) {
                guard let info = await runtime.host.channelInfo(channel), let ptz = info.ptz else { continue }
                func entries(_ list: [ReolinkPTZ.Entry]) -> JSONValue { .array(list.map { ["id": .number(Double($0.id)), "name": .string($0.name)] }) }
                func range(_ range: ClosedRange<Int>?) -> JSONValue {
                    range.map { ["min": .number(Double($0.lowerBound)), "max": .number(Double($0.upperBound))] } ?? .null
                }
                list.append([
                    "camera": .string(camera.accessory.id), "name": .string(camera.accessory.name),
                    "moves": .array(ReolinkPTZ.moves.keys.sorted().filter(ptz.allows).map(JSONValue.string)), "speed": .bool(ptz.speed),
                    "presets": entries(ptz.presets), "patrols": entries(ptz.patrols), "guard": .bool(ptz.hasGuard),
                    "zoomRange": range(ptz.zoomRange), "focusRange": range(ptz.focusRange),
                    "patrolling": info.state.patrolling.map(JSONValue.bool) ?? .null,
                ])
            }
        }
        return list
    }

    /// A published camera with PTZ, by accessory id or Device Id.
    private func ptzTarget(_ id: String) async -> (host: ReolinkHost, channel: Int, ptz: ReolinkPTZ)? {
        let accessoryID = id.hasPrefix("\(Self.platform):") ? id : Self.accessoryID(deviceID: id)
        for runtime in runtimes.values {
            for (channel, camera) in runtime.cameras where camera.accessory.id == accessoryID {
                guard let ptz = await runtime.host.channelInfo(channel)?.ptz else { return nil }
                return (runtime.host, channel, ptz)
            }
        }
        return nil
    }
}
