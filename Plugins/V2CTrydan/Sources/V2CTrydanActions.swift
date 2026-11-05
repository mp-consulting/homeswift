import Foundation
import Homeswift
import HomeswiftPlugin

// What the Assistant and MCP clients can do with an instance: list the chargers, check an address, and set the dynamic
// power mode, an installation setting HomeKit has no place for (docs/clean-room/V2CTrydan.md, 4.2).
extension V2CTrydanPlugin {
    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "list_chargers", title: "Look at the chargers",
            description: "The chargers this instance runs, by Device Id, with their address, whether they answer, the car's state, "
                + "the charge power (W), the session's energy (kWh), the current offered and its range (A), the meter's status and the dynamic power mode.",
            path: "chargers", access: .read),
        AssistantAction(
            name: "probe", title: "Check an address",
            description: "Reads /RealTimeData from a V2C Trydan at an address once: its Device Id, firmware and state. To add it, "
                + "update_settings by accessory V2CTrydan:<deviceID> with {\"host\": \"<address>\"} (its Accessory Settings).",
            // Configure, as adding the charger it finds is: it reaches any address the caller names.
            path: "probe", access: .configure,
            inputSchema: ["type": "object", "required": ["host"], "properties": ["host": ["type": "string", "description": "IP address or host name"]]]),
        AssistantAction(
            name: "set_mode", title: "Set the dynamic power mode",
            description: "Sets a charger's DynamicPowerMode, by Device Id: timed (the V2C app's schedule), timed-off (deprecated), "
                + "solar-min (solar plus minimum power), solar-only, solar-grid (solar plus grid) or stop.",
            method: "POST", path: "mode", access: .control,
            inputSchema: [
                "type": "object", "required": ["deviceID", "mode"],
                "properties": [
                    "deviceID": ["type": "string"],
                    "mode": ["type": "string", "enum": .array(DynamicPowerMode.allCases.map { .string($0.name) })],
                ],
            ]),
    ]

    public static let assistantBackground: String? = [
        "The Homeswift plugin bridges V2C Trydan EV chargers to HomeKit over their local HTTP interface (port 80, no account, no",
        "password, no cloud): GET /RealTimeData every pollingInterval seconds (10 by default, 5 at least), /read/<Keyword> for the",
        "values some firmware leaves out, /write/<Keyword>=<Value> answered OK. A charger is keyed by the ID it reports (else by its",
        "address, HOST-<address>) and reached at the host of its Accessory Settings. After 3 failed reads in a row the plugin logs",
        "\"is not responding, will keep retrying\", HomeKit shows No Response and it retries after 30 s, 1, 2, 4 then every 5 minutes;",
        "\"is responding again\" ends it. A timeout means the charger is off, on weak Wi-Fi or at another address (a DHCP reservation",
        "keeps it stable). The Outlet's On allows charging (Paused 0), the Charge current fan's speed is the current in amperes",
        "(6 to 32, within the installation's minimum and maximum), the lock disables the charger (Locked 1). A meter status other",
        "than No error is normal without an installed meter. Never ask the user for passwords, tokens or API keys.",
    ].joined(separator: " ")

    /// `GET chargers`, `GET probe?host=`, `POST mode` with `deviceID` and `mode`.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "chargers"):
            var list: [JSONValue] = []
            for charger in chargers.values { list.append(await charger.snapshot()) }
            list.sort { ($0["deviceID"]?.stringValue ?? "", $0["host"]?.stringValue ?? "") < ($1["deviceID"]?.stringValue ?? "", $1["host"]?.stringValue ?? "") }
            return PluginWebResponse(["chargers": .array(list)])
        case ("GET", "probe"):
            guard let raw = request.query["host"], let host = TrydanIdentity.normalizedHost(raw) else { return .error(400, "an IP address or host name is required") }
            do {
                let report = try await Self.probe(host: host, transport: dependencies.transport, timeout: timeout, logger: logger)
                var fields: [String: JSONValue] = [
                    "host": .string(host), "deviceID": .string(report.deviceID(host: host)),
                    "connected": .bool(report.isConnected), "charging": .bool(report.isCharging), "chargePower": .number(report.chargePower),
                ]
                if let firmware = report.firmwareVersion { fields["firmware"] = .string(firmware) }
                return PluginWebResponse(["charger": .object(fields)])
            } catch {
                return .error(502, "No V2C Trydan answered at \(host): \(error)")
            }
        case ("POST", "mode"):
            guard let deviceID = request.body["deviceID"]?.stringValue ?? request.query["deviceID"] else { return .error(400, "deviceID is required") }
            guard let name = request.body["mode"]?.stringValue ?? request.query["mode"], let mode = DynamicPowerMode(name: name) else {
                return .error(400, "mode is one of \(DynamicPowerMode.allCases.map(\.name).joined(separator: ", "))")
            }
            guard let charger = await charger(deviceID: deviceID) else { return .error(404, "no charger with that Device Id") }
            do {
                try await charger.set("DynamicPowerMode", mode.rawValue)
            } catch {
                return .error(502, "The charger did not take the mode: \(error)")
            }
            return PluginWebResponse(["deviceID": .string(deviceID), "mode": .string(mode.name)])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }
}
