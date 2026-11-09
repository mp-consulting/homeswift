import Foundation
import Homeswift
import HomeswiftPlugin
import Matter

// The plugin's page (docs/ui.md): the nodes Homeswift added, how each is reached and what it reported last, its
// remote's channels and the lights they dim, and the pairing windows open on the network. It writes no settings: a
// channel's light is an Accessory Setting, edited on the Settings page.
extension MatterDevicesPlugin {
    public static let assistantActions = [
        AssistantAction(
            name: "nodes", title: "List Matter devices",
            description: "Lists the Matter devices this instance added: each one's Device Id, name, vendor and product, how it is reached (status connecting, connected or unreachable, address, last error), its endpoints and their clusters, a remote's wheel channels with the lights they dim and the switch that powers them, and its last events. A channel's lights are the device's Accessory Setting light<N> (a list of light accessory ids), its power switches power<N> (a list of switch or outlet accessory ids, switched together, optional), with dimStep, reverseWheel and powerDelay: read their choices with get_settings and write them with update_settings.",
            path: "nodes", access: .read),
        AssistantAction(
            name: "reconnect", title: "Reconnect a Matter device",
            description: "Opens the session and subscription with one of this instance's Matter devices again now. Argument: device, its Device Id from nodes.",
            method: "POST", path: "reconnect", access: .control,
            inputSchema: ["type": "object", "required": ["device"], "properties": ["device": ["type": "string"]]]),
    ]

    public static let assistantBackground: String? = """
        Matter Devices makes Homeswift one more Matter controller of devices another app already has (multi-admin): that \
        app opens a pairing window (Apple Home: the accessory's settings, Turn On Pairing Mode) and Setup takes the code. \
        Homeswift finds its nodes by DNS-SD (_matter._tcp); a Thread device answers through a Thread border router (a \
        HomePod, an Apple TV, a hub), so the bridge's host needs IPv6 routes to the Thread network, which most border \
        routers announce. A battery device sleeps and answers only when it wakes to poll, so its commands and its first \
        connection can take several seconds. "not found on the network" means no DNS-SD record and no address kept; "did \
        not acknowledge" means the address did not answer. Forget removes Homeswift from the device's controllers.
        """

    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "nodes"):
            return PluginWebResponse(await nodesJSON())
        case ("POST", "reconnect"):
            guard let deviceID = request.body["device"]?.stringValue ?? request.query["device"], let node = nodes[deviceID] else {
                return .error(404, "No Matter device with that Device Id")
            }
            await node.link.reconnect()
            return PluginWebResponse(["ok": true])
        case ("GET", "windows"):
            let windows = await dependencies.discovery.commissionable(for: .seconds(3), until: nil)
            return PluginWebResponse(["windows": .array(windows.map { window in
                [
                    "name": .string(Self.windowName(window.info)), "vendor": Self.vendorText(window.info.vendorID).map(JSONValue.string) ?? .null,
                    "discriminator": .number(Double(window.info.discriminator)), "address": .string(window.address.description),
                ]
            })])
        default:
            return .error(404, "Unknown request")
        }
    }

    private func nodesJSON() async -> JSONValue {
        var list: [JSONValue] = []
        // A running node's record is in memory; only the others are read. Authorizations by name, nothing opened.
        var known = records()
        for (deviceID, node) in nodes { known[deviceID] = node.record }
        let authorized = context.haveCredentials(Array(known.keys))
        for (deviceID, record) in known.sorted(by: { ($0.value.name ?? $0.key) < ($1.value.name ?? $1.key) }) {
            var entry: [String: JSONValue] = [
                "device": .string(deviceID), "accessory": .string(Self.accessoryID(deviceID: deviceID)),
                "name": .string(record.name ?? "Matter device"), "vendor": (record.vendorName ?? Self.vendorText(record.vendorID)).map(JSONValue.string) ?? .null,
                "product": record.productName.map(JSONValue.string) ?? .null, "kind": record.kind.map(JSONValue.string) ?? .null,
                "added": record.added.map { .string(Timestamp.iso8601($0)) } ?? .null,
                "forgotten": .bool(!authorized.contains(deviceID)), "excluded": .bool(context.isExcluded(deviceID)),
            ]
            if let node = nodes[deviceID] {
                let link = await node.link.snapshot
                entry["status"] = .string(link.status.rawValue)
                entry["error"] = link.error.map(JSONValue.string) ?? .null
                entry["address"] = link.address.map { .string($0.description) } ?? .null
                entry["since"] = link.since.map { .string(Timestamp.iso8601($0)) } ?? .null
                entry["accessories"] = .array(node.plan.accessories.map { .string($0.name) })
                entry["endpoints"] = .array((node.structure?.endpoints ?? []).map { endpoint in
                    [
                        "id": .number(Double(endpoint.id)), "deviceTypes": .array(endpoint.deviceTypes.map { .number(Double($0)) }),
                        "clusters": .array(endpoint.clusters.map { .number(Double($0)) }), "label": endpoint.label.map(JSONValue.string) ?? .null,
                        "rotary": .bool(endpoint.isRotary),
                    ]
                })
                let settings = DimmerSettings(context.accessorySettings(for: deviceID).plugin)
                // The Home app numbers a remote's buttons by their Service Label Index, and shows no names.
                func button(_ endpoint: EndpointNumber?) -> JSONValue {
                    endpoint.flatMap { node.plan.buttons[$0]?[.serviceLabelIndex]?.value.intValue }.map { .number(Double($0)) } ?? .null
                }
                entry["channels"] = .array(node.channels.map { channel in
                    let lights = settings.lights[channel.number] ?? []
                    let power = settings.power[channel.number] ?? []
                    let name = { (id: String) in self.context.hostAccessory(id: id)?.name ?? id }
                    return [
                        "buttons": ["up": button(channel.up), "down": button(channel.down), "press": button(channel.press)],
                        "number": .number(Double(channel.number)), "up": .number(Double(channel.up)), "down": .number(Double(channel.down)),
                        "press": channel.press.map { .number(Double($0)) } ?? .null,
                        "lights": .array(lights.map { ["id": .string($0), "name": .string(name($0))] }),
                        "power": .array(power.map { ["id": .string($0), "name": .string(name($0))] }),
                    ]
                })
                entry["step"] = .number(Double(settings.step))
                entry["events"] = .array(node.events.suffix(20).reversed().map { event in
                    [
                        "time": .string(Timestamp.iso8601(event.time)), "endpoint": .number(Double(event.endpoint)),
                        "name": .string(event.name), "detail": event.detail.map(JSONValue.string) ?? .null,
                    ]
                })
            } else {
                entry["status"] = .string(!authorized.contains(deviceID) ? "forgotten" : context.isExcluded(deviceID) ? "excluded" : "stopped")
                entry["address"] = record.address.map { .string($0.description) } ?? .null
            }
            list.append(.object(entry))
        }
        var answer: [String: JSONValue] = ["nodes": .array(list), "fabric": .bool(commissioner != nil)]
        if let commissioner {
            // The fabric's public identity only: its compressed fabric id names its nodes on the network.
            answer["compressedFabricID"] = .string((await commissioner.compressedFabricID).map { String(format: "%02X", $0) }.joined())
        }
        return .object(answer)
    }
}
