import Foundation
import HomeswiftPlugin

extension SmartThingsPlugin {
    /// The page's routes (`Web/`): `GET status` the sign-in and how updates come, `GET devices` every device with its
    /// kind, health and appliance values (section 8.9), `GET diagnostics` what was skipped or not mapped (sections 7.6
    /// and 12.3). Signing in is Setup's (SmartThingsSetup.swift), never here.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "status"):
            let stored = await tokens.tokens
            return PluginWebResponse([
                "signedIn": .bool(await tokens.isSignedIn), "refusal": (await tokens.refusal).map(JSONValue.string) ?? .null,
                "personalToken": .bool(stored?.isPersonal ?? false), "sseGranted": .bool(stored?.grantsSSE ?? false), "events": .bool(sseActive),
                "eventsNote": sseNote.map(JSONValue.string) ?? .null, "pollSeconds": .number(pollPeriod),
                "requests": .number(Double(await api.requestCount)), "location": locationID.flatMap { locationNames[$0] }.map(JSONValue.string) ?? .null,
                "lastError": lastReconcileFailure.map(JSONValue.string) ?? .null,
            ])
        case ("GET", "devices"):
            let now = dependencies.now()
            var list: [JSONValue] = []
            for binding in bindings.values.sorted(by: { $0.device.displayName < $1.device.displayName }) {
                let device = binding.device
                list.append([
                    "deviceId": .string(device.deviceID), "accessoryId": .string(binding.accessory.id), "name": .string(device.displayName),
                    "kind": .string(binding.kind), "online": .bool(binding.box.status.health != "OFFLINE"), "matter": .bool(device.isMatter),
                    "room": device.roomID.flatMap { rooms[$0] }.map(JSONValue.string) ?? .null,
                    "details": .array(binding.details(now: now).map { ["label": .string($0.label), "value": .string($0.value)] }),
                ])
            }
            return PluginWebResponse(["devices": .array(list)])
        case ("GET", "diagnostics"):
            return PluginWebResponse(diagnostics())
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    /// Devices with nothing to map (their capabilities, per component) and copies of Homeswift's own accessories (the rule
    /// that matched and what SmartThings said of them), so a person can ask for support or check rule 12.3.
    func diagnostics() -> JSONValue {
        func components(_ device: SmartThingsDevice) -> JSONValue {
            .array(device.components.map { component in
                ["id": .string(component.id),
                 "capabilities": .array(component.capabilities.map { ["id": .string($0), "version": .number(Double(component.versions[$0] ?? 1))] })]
            })
        }
        let unmapped = unsupported.values.sorted { $0.displayName < $1.displayName }.map { device -> JSONValue in
            ["deviceId": .string(device.deviceID), "name": .string(device.displayName), "type": device.type.map(JSONValue.string) ?? .null,
             "components": components(device)]
        }
        let skipped = copies.values.sorted { $0.device.displayName < $1.device.displayName }.map { entry -> JSONValue in
            ["deviceId": .string(entry.device.deviceID), "name": .string(entry.device.displayName), "rules": .array(entry.match.rules.map(JSONValue.string)),
             "type": entry.device.type.map(JSONValue.string) ?? .null, "parentDeviceId": entry.device.parentDeviceID.map(JSONValue.string) ?? .null,
             "matter": entry.device.matter ?? .null, "manufacturerName": entry.device.manufacturerName.map(JSONValue.string) ?? .null]
        }
        return ["unsupported": .array(unmapped), "skippedCopies": .array(skipped)]
    }

    /// The page's routes for the Assistant.
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_devices", title: "Look at the SmartThings devices",
            description: "Every SmartThings device on the bridge: deviceId, accessoryId, name, kind (light, washer, refrigerator…), online, whether it is a "
                + "Matter device, its room, and details HomeKit has no characteristic for (an appliance's state, job, cycle, remaining minutes, finish "
                + "time, remote control). To change a device, use the accessory tools with its accessoryId.",
            path: "devices", access: .read),
        AssistantAction(
            name: "diagnostics", title: "Check what SmartThings devices were left out",
            description: "Devices with nothing HomeKit can show (their capabilities by component) and devices skipped because they are Homeswift's own "
                + "accessories brought back through Homeswift's Matter bridge (the rule that matched).",
            path: "diagnostics", access: .read),
    ]
}
