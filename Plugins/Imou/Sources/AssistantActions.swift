import Foundation
import HomeswiftAI
import HomeswiftPlugin

// What HomeKit has no service for (addendum, sections 1.4 and 2.6): pan, tilt and zoom, presets and night vision's modes, as routes of `handleWebRequest` that MCP and the Assistant call.
extension ImouPlugin {
    /// A camera by `accessoryId` (`Imou:<deviceId>:<channel>`), or `deviceId` with an optional `channel` ("0").
    static let cameraArguments: [String: JSONValue] = [
        "accessoryId": ["type": "string", "description": "Imou:<deviceId>:<channel>"],
        "deviceId": ["type": "string"], "channel": ["type": "string", "description": "The cloud's channel id; \"0\" when left out"],
    ]

    static func arguments(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "required": .array(required.map(JSONValue.string)), "properties": .object(cameraArguments.merging(properties) { $1 })]
    }

    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_cameras", title: "Look at the cameras",
            description: "The cameras this instance runs, one per channel (accessory Imou:<deviceId>:<channel>): whether they answer, privacy, their switches, "
                + "what they can do (ptz: PTZ moves and zooms, PT moves in eight directions, PT2 only left and right; presets), night vision's mode and modes.",
            path: "cameras", access: .read),
        AssistantAction(
            name: "move", title: "Move a camera",
            description: "Pans, tilts or zooms a camera for a duration (100 to 10000 ms, 1000 when left out) through the IMOU cloud. direction: up, down, left, "
                + "right, upLeft, upRight, downLeft, downRight, zoomIn, zoomOut or stop. Only what list_cameras' ptz allows.",
            method: "POST", path: "ptz/move", access: .configure,
            inputSchema: arguments([
                "direction": ["type": "string", "enum": .array(ImouPTZMove.allCases.map { .string($0.name) })],
                "duration": ["type": "integer", "minimum": 100, "maximum": 10000],
            ], required: ["direction"])),
        AssistantAction(
            name: "point", title: "Point a camera",
            description: "Points a PTZ or PT camera at a position: h (horizontal) and v (vertical) from -1 to 1, z (zoom) from 0 (widest) to 1.",
            method: "POST", path: "ptz/position", access: .configure,
            inputSchema: arguments(["h": ["type": "number", "minimum": -1, "maximum": 1], "v": ["type": "number", "minimum": -1, "maximum": 1],
                                    "z": ["type": "number", "minimum": 0, "maximum": 1]], required: ["h", "v"])),
        AssistantAction(
            name: "list_presets", title: "List a camera's presets",
            description: "The names of a camera's PTZ presets (its collection points), read from the cloud.",
            path: "ptz/presets", access: .configure, inputSchema: arguments([:])),
        AssistantAction(
            name: "go_to_preset", title: "Turn a camera to a preset",
            description: "Turns a camera to one of its presets, by the name list_presets gives.",
            method: "POST", path: "ptz/preset", access: .configure, inputSchema: arguments(["name": ["type": "string"]], required: ["name"])),
        AssistantAction(
            name: "set_night_vision", title: "Set a camera's night vision",
            description: "Sets a camera's night vision mode: one of the modes list_cameras gives (Intelligent, FullColor, Infrared, Off, LowLight, SmartLowLight), "
                + "exactly as written.",
            method: "POST", path: "night-vision", access: .configure, inputSchema: arguments(["mode": ["type": "string"]], required: ["mode"])),
    ]
}

extension ImouPlugin {
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        let arguments = request.method == "GET" ? JSONValue.object(request.query.mapValues(JSONValue.string)) : request.body
        if request.method == "GET", request.path == "cameras" {
            var list: [JSONValue] = []
            for camera in cameras.values.sorted(by: { $0.accessoryID < $1.accessoryID }) {
                list.append(.object(await camera.summary()))
            }
            return PluginWebResponse(["cameras": .array(list)])
        }
        guard let camera = camera(for: arguments) else { return .error(404, "No camera with that accessoryId, or deviceId and channel") }
        do {
            switch (request.method, request.path) {
            case ("POST", "ptz/move"):
                guard let move = arguments["direction"]?.stringValue.flatMap(ImouPTZMove.init(name:)) else { return .error(400, "Unknown direction") }
                let duration = arguments["duration"].lenientInt ?? ImouCamera.ptzDefaultDuration
                try await camera.move(move, milliseconds: duration)
            case ("POST", "ptz/position"):
                guard let h = arguments["h"].lenientDouble, let v = arguments["v"].lenientDouble else { return .error(400, "h and v are needed") }
                try await camera.locate(h: h, v: v, z: arguments["z"].lenientDouble ?? 0)
            case ("GET", "ptz/presets"):
                return PluginWebResponse(["presets": .array(try await camera.presets().map(JSONValue.string))])
            case ("POST", "ptz/preset"):
                guard let name = arguments["name"].text, name.count <= 64 else { return .error(400, "A preset name is needed") }
                try await camera.goToPreset(name)
            case ("POST", "night-vision"):
                guard let mode = arguments["mode"].text, mode.count <= 32 else { return .error(400, "A mode is needed") }
                try await camera.setNightVision(mode: mode)
            default:
                return .error(404, "Not found")
            }
        } catch let refused as ImouCamera.ActionRefused {
            return .error(409, refused.description)
        } catch let error as ImouError {
            return .error(502, error.description)
        }
        return PluginWebResponse(["ok": true])
    }

    private func camera(for arguments: JSONValue) -> ImouCamera? {
        if let id = arguments["accessoryId"].text { return cameras[id] }
        guard let deviceID = arguments["deviceId"].text else { return nil }
        return cameras[Self.accessoryID(deviceID: deviceID, channel: arguments["channel"].text ?? "0")]
    }
}
