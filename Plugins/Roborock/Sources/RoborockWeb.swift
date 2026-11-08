import Foundation
import HomeswiftPlugin

// What HomeKit has no service for (RoborockModes.md): the clean modes by name, rooms, finding the robot and clearing an
// error, as routes of `handleWebRequest` that the MCP server and the Assistant call.
extension RoborockPlugin {
    static let robotArgument: [String: JSONValue] = [
        "duid": ["type": "string", "description": "The robot's duid from list_robots; may be left out when there is one robot"],
    ]

    static func arguments(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        ["type": "object", "required": .array(required.map(JSONValue.string)), "properties": .object(robotArgument.merging(properties) { $1 })]
    }

    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_robots", title: "Look at the robot vacuums",
            description: "Every Roborock robot: duid, name, state code, battery, the robot's and the dock's error (code and meaning), and the current and "
                + "offered suction (fan_power), water flow (water_box_mode) and mop route (mop_mode), each a code and a name.",
            path: "robots", access: .read),
        AssistantAction(
            name: "list_rooms", title: "List a robot's rooms",
            description: "The rooms of the robot's current map, from the robot (segment ids) named from the Roborock app's rooms.",
            path: "rooms", access: .read, inputSchema: arguments(), queryKeys: ["duid"]),
        AssistantAction(
            name: "clean_rooms", title: "Clean rooms",
            description: "Starts cleaning the given rooms of the current map, by name (as list_rooms gives them) or segment id, each `repeat` times (1 to 3).",
            method: "POST", path: "clean-rooms", access: .control,
            inputSchema: arguments([
                "rooms": ["type": "array", "items": ["type": ["string", "integer"]], "minItems": 1],
                "repeat": ["type": "integer", "minimum": 1, "maximum": 3],
            ], required: ["rooms"])),
        AssistantAction(
            name: "set_clean_mode", title: "Set the suction and mop",
            description: "Sets the suction (fan_power), the water flow (water_box_mode) and the mop route (mop_mode), each by a name or code that list_robots "
                + "offers for the robot; any of them may be left out. Water Off vacuums only; suction Off with water mops only.",
            method: "POST", path: "mode", access: .control,
            inputSchema: arguments([
                "fan_power": ["type": ["string", "integer"]], "water_box_mode": ["type": ["string", "integer"]], "mop_mode": ["type": ["string", "integer"]],
            ])),
        AssistantAction(
            name: "find_robot", title: "Find a robot", description: "The robot says where it is, out loud.",
            method: "POST", path: "locate", access: .control, inputSchema: arguments()),
        AssistantAction(
            name: "clear_error", title: "Clear a robot's error",
            description: "Clears the dock's error, else the robot's, once its cause is fixed (some dock errors stay latched until cleared).",
            method: "POST", path: "resolve-error", access: .control, inputSchema: arguments()),
    ]

    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "robots"):
            return PluginWebResponse(["robots": .array(accessories.values.sorted { $0.name < $1.name }.map(robotJSON))])
        case ("GET", "rooms"):
            let found = robotOrError(request.query["duid"])
            guard let duid = found.duid else { return found.error }
            do {
                return PluginWebResponse(["rooms": .array(try await rooms(duid).map(\.json))])
            } catch {
                return .error(502, "The robot did not answer: \(error)")
            }
        case ("POST", "clean-rooms"):
            let found = robotOrError(request.body["duid"]?.stringValue)
            guard let duid = found.duid else { return found.error }
            let wanted = request.body["rooms"]?.arrayValue ?? []
            guard !wanted.isEmpty else { return .error(400, "Name at least one room") }
            let repeats = min(3, max(1, request.body["repeat"]?.intValue ?? 1))
            do {
                let segments = try RoborockRooms.segments(wanted, in: try await rooms(duid))
                let params: JSONValue = [["segments": .array(segments.map { .number(Double($0)) }), "repeat": .number(Double(repeats))]]
                _ = try await self.request(duid, "app_segment_clean", params)
                return PluginWebResponse(["ok": true, "segments": .array(segments.map { .number(Double($0)) })])
            } catch let error as RoborockRoomError {
                return .error(400, error.description)
            } catch {
                return .error(502, "The robot refused: \(error)")
            }
        case ("POST", "mode"):
            let found = robotOrError(request.body["duid"]?.stringValue)
            guard let duid = found.duid, let vacuum = accessories[duid] else { return found.error }
            let modes = vacuum.cleanModes
            var sent: [String: JSONValue] = [:]
            for (key, offered, method) in [("fan_power", modes.fanPowers, "set_custom_mode"), ("water_box_mode", modes.waterModes, "set_water_box_custom_mode"),
                                           ("mop_mode", modes.routes, "set_mop_mode")] {
                guard let value = request.body[key], value != .null else { continue }
                guard let mode = RoborockCleanModes.find(value, in: offered) else {
                    return .error(400, "\(key) \(value.stringValue ?? value.text()) is not offered: \(offered.map(\.name).joined(separator: ", "))")
                }
                do {
                    _ = try await self.request(duid, method, [.number(Double(mode.code))])
                } catch {
                    let done = sent.keys.sorted().joined(separator: ", ")
                    return .error(502, "The robot refused \(key): \(error)" + (done.isEmpty ? "" : " (\(done) set already)"))
                }
                sent[key] = mode.json
            }
            guard !sent.isEmpty else { return .error(400, "Give fan_power, water_box_mode or mop_mode") }
            await refreshStatus(duid)
            return PluginWebResponse(["ok": true, "set": .object(sent)])
        case ("POST", "locate"):
            let found = robotOrError(request.body["duid"]?.stringValue)
            guard let duid = found.duid else { return found.error }
            do {
                _ = try await self.request(duid, "find_me")
                return PluginWebResponse(["ok": true])
            } catch {
                return .error(502, "The robot did not answer: \(error)")
            }
        case ("POST", "resolve-error"):
            let found = robotOrError(request.body["duid"]?.stringValue)
            guard let duid = found.duid else { return found.error }
            return await resolveError(duid)
        default:
            return .error(404, "No such route")
        }
    }

    /// The robot, or why there is none: an unknown duid, or several robots and none named.
    func robotOrError(_ duid: String?) -> (duid: String?, error: PluginWebResponse) {
        if let duid = duid?.nonEmptyValue {
            return accessories[duid] != nil ? (duid, .error(404, "")) : (nil, .error(404, "No robot with duid \(duid): list_robots gives them"))
        }
        if accessories.count == 1 { return (accessories.keys.first, .error(404, "")) }
        return (nil, accessories.isEmpty ? .error(404, "No robot yet") : .error(400, "Several robots: name one by its duid from list_robots"))
    }

    func robotJSON(_ vacuum: VacuumAccessory) -> JSONValue {
        let modes = vacuum.cleanModes
        func number(_ field: String) -> Int? { vacuum.value(field, home: home).map { Int($0) } }
        func current(_ field: String, _ offered: [RoborockMode]) -> JSONValue {
            guard let code = number(field) else { return .null }
            return ["code": .number(Double(code)), "name": .string(RoborockCleanModes.name(code, in: offered))]
        }
        func error(_ field: String, _ table: [Int: String]) -> JSONValue {
            guard let code = number(field), let text = RoborockErrors.describe(code, in: table) else { return .null }
            return ["code": .number(Double(code)), "meaning": .string(text)]
        }
        return [
            "duid": .string(vacuum.duid), "name": .string(vacuum.name), "model": vacuum.model.map(JSONValue.string) ?? .null,
            "state": number("state").map { .number(Double($0)) } ?? .null, "battery": number("battery").map { .number(Double($0)) } ?? .null,
            "error": error("error_code", RoborockErrors.robot), "dockError": error("dock_error_status", RoborockErrors.dock),
            "fan_power": current("fan_power", modes.fanPowers), "water_box_mode": current("water_box_mode", modes.waterModes),
            "mop_mode": current("mop_mode", modes.routes),
            "offered": [
                "fan_power": .array(modes.fanPowers.map(\.json)), "water_box_mode": .array(modes.waterModes.map(\.json)),
                "mop_mode": .array(modes.routes.map(\.json)),
            ],
        ]
    }

    /// The current map's rooms: `get_room_mapping`, named from the home data's rooms (section 4).
    func rooms(_ duid: String) async throws -> [RoborockRooms.Room] {
        let mapping = try await request(duid, "get_room_mapping")
        return RoborockRooms.rooms(mapping: mapping, names: RoborockRooms.names(home?.raw))
    }

    /// Section 6.2: the status read again, the dock's error resolved first, else the robot's, then the status again.
    func resolveError(_ duid: String) async -> PluginWebResponse {
        if let answer = await send(duid, "get_status"), let status = RoborockMessages.firstObject(answer) {
            accessories[duid]?.record(status)
        }
        let robotError = accessories[duid]?.value("error_code", home: home).map { Int($0) }
        let dockError = accessories[duid]?.value("dock_error_status", home: home).map { Int($0) }
        guard let code = RoborockErrors.toResolve(robot: robotError, dock: dockError) else { return PluginWebResponse(["ok": true, "cleared": .null]) }
        do {
            _ = try await request(duid, "resolve_error", ["error_code": .number(Double(code))])
        } catch {
            return .error(502, "The robot refused: \(error)")
        }
        await refreshStatus(duid)
        return PluginWebResponse(["ok": true, "cleared": .number(Double(code))])
    }
}
