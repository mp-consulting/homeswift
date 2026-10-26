import Foundation
import Homeswift
import HomeswiftPlugin

extension DirigeraPlugin {
    /// The page's routes (`Web/`): `GET hubs` each hub with its state, `GET discover` the hubs on the network,
    /// `POST pair` and `POST unpair` a hub, `GET devices` and `GET scenes`, `POST trigger` a scene, `POST device` a light's
    /// or outlet's power and level, `POST identify` a device.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        let host = request.body["host"]?.stringValue ?? request.query["host"]
        switch (request.method, request.path) {
        case ("GET", "hubs"):
            var list: [JSONValue] = []
            for host in Set(hubHosts + hubs.keys).sorted() {
                let status = await hubStatus(host)
                list.append([
                    "host": .string(host), "name": configuration.hubs?.first { $0.host == host }?.name.map(JSONValue.string) ?? .null,
                    "paired": .bool(status.paired), "connected": .bool(status.connected), "pairing": .bool(status.pairing),
                    "error": status.error.map(JSONValue.string) ?? .null, "devices": .number(Double(status.devices)), "scenes": .number(Double(status.scenes)),
                    "inConfig": .bool(configuration.hubs?.contains { $0.host == host } ?? false),
                ])
            }
            return PluginWebResponse(["hubs": .array(list)])
        case ("GET", "discover"):
            return PluginWebResponse(["hosts": .array(await discover().map(JSONValue.string))])
        case ("POST", "pair"):
            guard let host, !host.isEmpty else { return .error(400, "an address is required") }
            do {
                try await pair(host: host)
            } catch DirigeraClient.Failure.buttonNotPressed {
                return .error(409, "The action button was not pressed in time.")
            }
            return PluginWebResponse(["paired": .string(host)])
        case ("POST", "unpair"):
            guard let host else { return .error(400, "an address is required") }
            await unpair(host: host)
            return PluginWebResponse(["unpaired": .string(host)])
        case ("GET", "devices"):
            var list: [JSONValue] = []
            for (host, hub) in hubs.sorted(by: { $0.key < $1.key }) {
                for device in hub.devices.values.sorted(by: { ($0.room ?? "", $0.name) < ($1.room ?? "", $1.name) }) {
                    list.append(deviceJSON(device, host: host))
                }
            }
            return PluginWebResponse(["devices": .array(list)])
        case ("GET", "scenes"):
            var list: [JSONValue] = []
            for (host, hub) in hubs.sorted(by: { $0.key < $1.key }) {
                let visible = Set(visibleScenes(hub).map(\.id))
                for scene in hub.scenes {
                    list.append([
                        "host": .string(host), "id": .string(scene.id), "name": .string(scene.name), "icon": scene.icon.map(JSONValue.string) ?? .null,
                        "hidden": .bool(!visible.contains(scene.id)),
                    ])
                }
            }
            return PluginWebResponse(["scenes": .array(list)])
        case ("POST", "trigger"):
            guard let host, let id = request.body["id"]?.stringValue else { return .error(400, "a hub and a scene are required") }
            try await trigger(host: host, sceneID: id)
            return PluginWebResponse(["triggered": .string(id)])
        case ("POST", "device"):
            guard let host, let id = request.body["id"]?.stringValue else { return .error(400, "a hub and a device are required") }
            if let on = request.body["on"]?.boolValue { try await set(host: host, deviceID: id, attributes: ["isOn": .bool(on)]) }
            if let level = request.body["brightness"]?.doubleValue { try await set(host: host, deviceID: id, attributes: ["lightLevel": .number(min(max(level, 1), 100))]) }
            guard let device = hubs[host]?.devices[id] else { return .error(404, "no device with that id") }
            return PluginWebResponse(["device": deviceJSON(device, host: host)])
        case ("POST", "identify"):
            guard let host, let id = request.body["id"]?.stringValue else { return .error(400, "a hub and a device are required") }
            try await identify(host: host, deviceID: id)
            return PluginWebResponse(["identified": .string(id)])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    func deviceJSON(_ device: DirigeraDevice, host: String) -> JSONValue {
        var colour: String?
        if let hue = device.hue, let saturation = device.saturation {
            colour = Self.hex(hue: hue, saturation: saturation)
        } else if let mirek = device.mirek {
            let white = ColorUtils.colorTemperatureToHueAndSaturation(Double(mirek))
            colour = Self.hex(hue: white.hue, saturation: white.saturation)
        }
        return [
            "host": .string(host), "id": .string(device.id), "kind": .string(device.kind.rawValue), "name": .string(device.name),
            "model": .string(device.model), "room": device.room.map(JSONValue.string) ?? .null, "reachable": .bool(device.reachable),
            "on": .bool(device.on), "brightness": device.brightness.map { .number(Double($0)) } ?? .null,
            "colour": colour.map(JSONValue.string) ?? .null, "hidden": .bool(isExcluded(device)),
            "open": .bool(device.open), "battery": device.battery.map { .number(Double($0)) } ?? .null,
            "type": .string(device.kind != .light ? device.kind.rawValue : device.hasColour ? "colour" : device.mirekRange != nil ? "white" : device.brightness != nil ? "dimmable" : "onoff"),
        ]
    }

    static func hex(hue: Double, saturation: Double) -> String {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation, 0), 100) / 100
        let sector = Int(h.rounded(.down)), f = h - Double(sector)
        let p = 1 - s, q = 1 - s * f, t = 1 - s * (1 - f)
        let (r, g, b): (Double, Double, Double) = switch sector {
        case 0: (1, t, p)
        case 1: (q, 1, p)
        case 2: (p, 1, t)
        case 3: (p, q, 1)
        case 4: (t, p, 1)
        default: (1, p, q)
        }
        func byte(_ value: Double) -> String {
            let text = String(Int((value * 255).rounded()), radix: 16)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + byte(r) + byte(g) + byte(b)
    }
}
