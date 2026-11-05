import Foundation
import HomeswiftAI
import HomeswiftPlugin

// What HomeKit has no service for (addendum, section 2.6): night vision's modes, as routes of `handleWebRequest` that MCP and the Assistant call.
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
                + "and night vision's mode and modes.",
            path: "cameras", access: .read),
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
