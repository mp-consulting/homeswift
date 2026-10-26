import Foundation
import Homeswift
import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The page's routes (`Web/`): `GET status` the bridge and pairing, `GET discover` the bridges on the network,
    /// `POST host` another address, `POST pair`, `GET lights` and `GET scenes` with their colours,
    /// `POST recall` a scene (`dynamic` plays it or stops it playing), `POST scene-off` its room, `POST autoplay` its Autoplay, `POST light` a light's power, brightness, effect or flash, `POST identify` a light;
    /// `GET scene-picture`, `POST scene-picture` and `POST scene-picture-remove` the picture a person gave a scene.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        if let response = pictures.handle(request) { return response }
        switch (request.method, request.path) {
        case ("GET", "status"):
            let stored = storedBridge
            return PluginWebResponse([
                "host": stored.host.map(JSONValue.string) ?? .null, "bridgeID": stored.bridgeID.map(JSONValue.string) ?? .null,
                "paired": .bool(stored.applicationKey != nil), "pairing": .bool(isPairing),
                "pairingSecondsLeft": pairingSecondsLeft.map { .number(Double($0)) } ?? .null, "error": lastError.map(JSONValue.string) ?? .null,
                "lights": .number(Double(snapshot.lights.count)), "scenes": .number(Double(snapshot.scenes.count)),
            ])
        case ("GET", "discover"):
            return PluginWebResponse(["hosts": .array(await discover().map(JSONValue.string))])
        case ("POST", "host"):
            guard let host = request.body["host"]?.stringValue?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return .error(400, "an address is required") }
            await use(host: host)
            return PluginWebResponse(["host": .string(host)])
        case ("POST", "pair"):
            let paired = await startPairing()
            return paired ? PluginWebResponse(["paired": true]) : .error(409, lastError ?? "The link button was not pressed in time.")
        case ("GET", "lights"):
            return PluginWebResponse(["lights": .array(snapshot.lights.map { lightJSON($0) })])
        case ("GET", "scenes"):
            let versions = pictures.versions()
            let groups: [JSONValue] = snapshot.groups.compactMap { group in
                let scenes = snapshot.scenes.filter { $0.groupID == group.id }
                guard !scenes.isEmpty else { return nil }
                let visible = Set(visibleScenes(of: group).map(\.id))
                return [
                    "id": .string(group.id), "name": .string(group.name), "kind": .string(group.kind), "on": .bool(group.on),
                    "scenes": .array(scenes.map { scene in
                        [
                            "id": .string(scene.id), "name": .string(scene.name), "active": .bool(scene.active), "playing": .bool(scene.playing), "smart": .bool(scene.smart),
                            "autoplay": .bool(scene.autoplay), "palette": .bool(scene.hasPalette),
                            // Colours, not only whites: what the page's Colour scenes filter keeps.
                            "colourful": .bool(scene.colourful),
                            "hidden": .bool(!visible.contains(scene.id)), "colours": .array(Self.swatches(scene).map(JSONValue.string)),
                            "picture": versions[scene.id].map(JSONValue.string) ?? .null,
                            "transitionMs": ownTransition(scene, room: group.name).map { .number(Double($0)) } ?? .null,
                        ]
                    }),
                ]
            }
            return PluginWebResponse(["groups": .array(groups)])
        case ("GET", "assistant-scenes"):
            return PluginWebResponse(assistantScenes(room: request.query["room"]))
        case ("POST", "recall"):
            guard let id = request.body["id"]?.stringValue else { return .error(400, "a scene id is required") }
            try await recall(sceneID: id, dynamic: request.body["dynamic"]?.boolValue)
            return PluginWebResponse(["recalled": .string(id)])
        case ("POST", "scene-off"):
            guard let id = request.body["id"]?.stringValue else { return .error(400, "a scene id is required") }
            try await switchOff(sceneID: id)
            return PluginWebResponse(["off": .string(id)])
        case ("POST", "autoplay"):
            guard let id = request.body["id"]?.stringValue, let on = request.body["on"]?.boolValue else { return .error(400, "a scene id and on are required") }
            // A smart scene follows the time of day: it has no Autoplay.
            guard snapshot.scenes.contains(where: { $0.id == id && !$0.smart }) else { return .error(404, "no such scene") }
            try await setAutoplay(sceneID: id, on)
            return PluginWebResponse(["autoplay": .bool(on)])
        case ("POST", "light"):
            guard let id = request.body["id"]?.stringValue, let light = snapshot.lights.first(where: { $0.id == id }) else { return .error(404, "no light with that id") }
            var body: [String: JSONValue] = [:]
            if let on = request.body["on"]?.boolValue { body["on"] = ["on": .bool(on)] }
            if let brightness = request.body["brightness"]?.doubleValue { body["dimming"] = ["brightness": .number(min(max(brightness, 1), 100))] }
            if let effect = request.body["effect"]?.stringValue {
                let name = effect.isEmpty ? "no_effect" : effect
                body[light.effectsV2 ? "effects_v2" : "effects"] = light.effectsV2 ? ["action": ["effect": .string(name)]] : ["effect": .string(name)]
            }
            if request.body["flash"]?.boolValue == true {
                body["signaling"] = ["signal": .string(light.signals.contains("on_off") ? "on_off" : "on_off_color"), "duration": .number(Double(Self.flashDuration))]
            }
            guard !body.isEmpty else { return .error(400, "nothing to change") }
            if body["dimming"] != nil || body["on"] != nil { body["dynamics"] = ["duration": .number(Double(transitionMs))] }
            try await lightAction(id: id, .object(body))
            return PluginWebResponse(["light": lightJSON(snapshot.lights.first { $0.id == id } ?? light)])
        case ("POST", "identify"):
            guard let id = request.body["id"]?.stringValue else { return .error(400, "a light id is required") }
            try await identify(lightID: id)
            return PluginWebResponse(["identified": .string(id)])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    func lightJSON(_ light: HueLight) -> JSONValue {
        let gamut = light.gamut ?? .c
        var colour: String?
        if let mirek = light.mirek, light.xy == nil || !light.hasColour {
            colour = Self.hex(mirek: mirek)
        } else if let xy = light.xy {
            colour = Self.hex(xy, gamut: gamut)
        }
        return [
            "id": .string(light.id), "name": .string(light.name), "product": .string(light.product), "model": .string(light.model),
            "on": .bool(light.on), "reachable": .bool(light.reachable), "brightness": light.brightness.map { .number($0.rounded()) } ?? .null,
            "colour": colour.map(JSONValue.string) ?? .null, "mirek": light.mirek.map { .number(Double($0)) } ?? .null,
            "kind": .string(light.hasColour ? "colour" : light.hasColourTemperature ? "white" : light.dims ? "dimmable" : "onoff"),
            "effects": .array(light.effects.map(JSONValue.string)), "effect": light.effect.map(JSONValue.string) ?? .null,
            "canFlash": .bool(light.canFlash), "gradient": .array(light.gradientPoints.map { .string(Self.hex($0, gamut: gamut)) }),
            "hidden": .bool(isExcluded(light)), "firmware": .string(light.firmware),
        ]
    }

    /// A scene's colours as CSS colours, for its tile: the palette, else its whites.
    static func swatches(_ scene: HueScene) -> [String] {
        // A smart scene follows the day: warm to daylight.
        if scene.smart { return [hex(mirek: 454), hex(mirek: 300), hex(mirek: 182)] }
        let colours = scene.colours.prefix(5).map { hex($0, gamut: .c) }
        if !colours.isEmpty { return colours }
        return scene.whites.prefix(3).map { hex(mirek: $0) }
    }

    static func hex(_ point: HueXY, gamut: HueGamut) -> String {
        let colour = HueColor.hueSaturation(point, gamut: gamut)
        return hex(hue: colour.hue, saturation: colour.saturation)
    }

    static func hex(mirek: Int) -> String {
        let colour = ColorUtils.colorTemperatureToHueAndSaturation(Double(mirek))
        return hex(hue: colour.hue, saturation: colour.saturation)
    }

    static func hex(hue: Double, saturation: Double) -> String {
        let (r, g, b) = HueColor.rgb(hue: hue, saturation: saturation)
        func byte(_ value: Double) -> String {
            let text = String(Int((min(max(value, 0), 1) * 255).rounded()), radix: 16)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + byte(r) + byte(g) + byte(b)
    }
}
