import Foundation
import HomeswiftPlugin

// What HomeKit cannot show (docs/clean-room/XiaomiMiot.md section 15.9): every property and action of a device's spec,
// on the plugin's page and for the Assistant. `GET devices` lists the devices; `GET properties?did=` reads every readable
// property now, with the spec's services and actions; `POST set_property` and `POST run_action` write one, over the LAN as
// a HomeKit write. The page writes no settings: it links to them.
extension XiaomiMiotPlugin {
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        do {
            switch (request.method, request.path) {
            case ("GET", "devices"):
                var list: [JSONValue] = []
                for (_, device) in devices.sorted(by: { $0.key < $1.key }) { list.append(await device.summary()) }
                let known = known
                let excluded: [JSONValue] = context.excludedDeviceIDs.sorted().map { did in
                    ["deviceId": .string(did), "accessoryId": .string(context.accessoryID(of: did)),
                     "name": .string(context.accessorySettings(for: did).name ?? known[did]?.name ?? did)]
                }
                // The vault's names only: whether the account has credentials, none of them opened.
                let accountSetUp = context.haveCredentials([nil]).contains(nil)
                return PluginWebResponse(["devices": .array(list), "excluded": .array(excluded), "accountSetUp": .bool(accountSetUp)])
            case ("GET", "properties"):
                let device = try device(for: request.query["did"] ?? request.body["did"]?.stringValue)
                return PluginWebResponse(try await device.describe())
            case ("POST", "set_property"):
                let device = try device(for: request.body["did"]?.stringValue ?? request.query["did"])
                // An id is text ("3.10"): as a number it would read 3.1.
                guard let property = request.body["property"]?.stringValue else { return .error(400, "property is required, as text") }
                guard let value = request.body["value"], !value.isNull else { return .error(400, "value is required") }
                return PluginWebResponse(try await device.setProperty(property, value))
            case ("POST", "run_action"):
                let device = try device(for: request.body["did"]?.stringValue ?? request.query["did"])
                guard let action = request.body["action"]?.stringValue else { return .error(400, "action is required") }
                return PluginWebResponse(try await device.runAction(action, request.body["params"]?.arrayValue ?? []))
            default:
                return .error(404, "Not found")
            }
        } catch let error as PageError {
            return .error(error.status, error.description)
        } catch {
            return .error(502, "\(error)")
        }
    }

    private func device(for did: String?) throws -> MiotDevice {
        guard let did, !did.isEmpty else { throw PageError(400, "did is required") }
        guard let device = devices[did] else { throw PageError(404, "No running device has the did \(did)") }
        return device
    }

    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "devices", title: "List the Xiaomi devices",
            description: "The devices this instance runs, by did (the Device Id; accessory id miot:<did>): name, model, IP address, whether it answers, "
                + "its MIoT spec URN and its path (miot, or legacy for the older Roborock-family vacuums).",
            path: "devices", access: .read),
        AssistantAction(
            name: "properties", title: "Read a Xiaomi device's properties",
            description: "Reads every readable property of a device now, by its did, with its spec's services, each property's id (siid.piid), name "
                + "(service:property, as propertyControl and propertyMonitor name them), format, access, unit, range or value list and current value, and "
                + "each action's id (siid.aiid) and name. What HomeKit does not show is here. To put one in HomeKit, add it to the device's Accessory "
                + "Settings with update_settings (accessory miot:<did>): propertyControl, propertyMonitor or actionButtons, a list read with get_settings first.",
            path: "properties", access: .read,
            inputSchema: ["type": "object", "required": ["did"], "properties": ["did": ["type": "string", "description": "The device's did"]]]),
        AssistantAction(
            name: "set_property", title: "Set a Xiaomi device's property",
            description: "Writes one property of a device by its name (service:property) or id (siid.piid), as a HomeKit write would. The value is "
                + "converted to the property's format and clamped to its range; a value list's value is its number, not its description.",
            method: "POST", path: "set_property", access: .control,
            inputSchema: [
                "type": "object", "required": ["did", "property", "value"],
                "properties": ["did": ["type": "string"], "property": ["type": "string"], "value": ["description": "A number, a bool or a string"]],
            ], confirm: true),
        AssistantAction(
            name: "run_action", title: "Run a Xiaomi device's action",
            description: "Runs one action of a device by its name (service:action) or id (siid.aiid), with its in values in order when it takes some.",
            method: "POST", path: "run_action", access: .control,
            inputSchema: [
                "type": "object", "required": ["did", "action"],
                "properties": ["did": ["type": "string"], "action": ["type": "string"], "params": ["type": "array", "items": [:]]],
            ], confirm: true),
    ]

    public static let assistantBackground: String? = [
        "The Homeswift plugin for Xiaomi Mi Home devices (platform miot) reaches each device on the LAN over miIO (UDP port 54321) with",
        "the device's 32-hexadecimal token, and maps its MIoT spec (fetched once from miot-spec.org and kept) to HomeKit. The Xiaomi account is",
        "optional: Setup signs in with a QR code scanned in the Mi Home app or a password and an emailed code, and lists the account's devices",
        "with their tokens; it is not used at run time. \"Call to device timed out\" means no answer at the address (wrong IP, the device off or",
        "on another network, UDP blocked); \"the token does not open the device\" means a wrong token (a device reset or re-added in Mi Home gets",
        "a new one). A device that misses 4 polls shows No Response and is retried. \"needs the Xiaomi cloud\" marks models that do not answer",
        "MIoT locally; forceMiCloud is not supported yet. Extra switches (buzzer, LED, modes, fan levels...) are off by default: turn them on in",
        "the device's settings. Never ask the user for tokens or passwords in chat.",
    ].joined(separator: " ")
}
