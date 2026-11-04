import Foundation
import HomeswiftPlugin

// Settings (docs/plugins.md, "Settings"): the Plugin Settings are the block's options (`host`, `transitionMs`,
// `pollingInterval`, `scenes`, `roomLights`, `dynamicScenes`, `effects`, `flashSwitch`, `gradientPoints`, `sensors`).
// Each light (Device Id: its light id), sensor or switch (`device:<id>`) and scene (its scene id) has its Accessory
// Settings in `_accessories`: Excluded, and the plugin's own (a light's `effects`, `flashSwitch` and `gradientPoints`, a
// scene's `transitionMs`), whose plugin-wide defaults are the options of the same names. The Homebridge-shaped lists
// (`excludeLights`, `excludeSensors`, `excludeScenes` by name or id, `sceneTransitions` by "Room/Scene" or name) still
// load, and `canonicalSettings` moves what the bridge's names resolve into `_accessories`.
extension PhilipsHuePlugin {
    /// A light's own Plugin Accessory Settings; nil takes the plugin-wide option.
    struct LightOptions: Decodable, Sendable {
        var effects: Bool?
        var flashSwitch: Bool?
        var gradientPoints: Bool?
    }

    /// A scene's own Plugin Accessory Settings.
    struct SceneOptions: Decodable, Sendable {
        var transitionMs: Int?
    }

    func lightOptions(_ lightID: String) -> LightOptions {
        context.accessorySettings(for: lightID).decode(LightOptions.self) ?? LightOptions()
    }

    /// What a light's accessory has beside the light: a switch per effect, a Flash switch, a light per gradient point.
    struct LightExtras {
        var effects: Bool
        var flash: Bool
        var gradientPoints: Bool
    }

    /// The light's extras: its own Accessory Settings, else the plugin-wide options (decoded once for the three).
    func extras(_ light: HueLight) -> LightExtras {
        let own = lightOptions(light.id)
        return LightExtras(
            effects: own.effects ?? configuration.effects ?? true, flash: own.flashSwitch ?? configuration.flashSwitch ?? false,
            gradientPoints: own.gradientPoints ?? configuration.gradientPoints ?? false)
    }

    /// A scene's own transition from its Accessory Settings.
    func sceneTransition(_ sceneID: String) -> Int? {
        context.accessorySettings(for: sceneID).decode(SceneOptions.self)?.transitionMs
    }

    /// The Device Id of a sensor or switch: `device:<id>`, as its accessory's `PhilipsHue:device:<id>`.
    static func sensorDeviceID(_ id: String) -> String { "device:\(id)" }

    /// A sensor device's Device Kind: `switch` for one with buttons only (a dimmer, a Tap), `sensor` otherwise.
    static func kind(of sensor: HueSensorDevice) -> String {
        sensor.motion == nil && sensor.temperature == nil && sensor.lightLevel == nil && sensor.contact == nil && !sensor.buttons.isEmpty ? "switch" : "sensor"
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if snapshot.lights.contains(where: { $0.id == deviceID }) { return "light" }
        if let sensor = snapshot.sensors.first(where: { Self.sensorDeviceID($0.id) == deviceID }) { return Self.kind(of: sensor) }
        if snapshot.scenes.contains(where: { $0.id == deviceID }) { return "scene" }
        return nil
    }

    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        Self.canonical(block, snapshot: snapshot)
    }

    /// The block with its Homebridge-shaped lists moved into `_accessories`, as far as `snapshot` (what the bridge has)
    /// resolves them: `excludeLights`, `excludeSensors` and `excludeScenes` as Excluded, `sceneTransitions` as each scene's
    /// `transitionMs` ("Room/Scene" before a scene's name, as they were read). A name that matches nothing stays in its
    /// list; before the bridge was read, nothing moves. What `_accessories` holds already wins.
    static func canonical(_ block: JSONValue, snapshot: HueSnapshot) -> JSONValue {
        guard var fields = block.objectValue, !snapshot.lights.isEmpty || !snapshot.sensors.isEmpty || !snapshot.scenes.isEmpty else { return block }
        var entries = AccessoryEntries(fields)
        let roomOf = Dictionary(snapshot.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func scenes(matching text: String, byID: Bool) -> [HueScene] {
            let wanted = text.lowercased()
            return snapshot.scenes.filter { scene in
                "\(roomOf[scene.groupID] ?? "")/\(scene.name)".lowercased() == wanted || scene.name.lowercased() == wanted || (byID && scene.id.lowercased() == wanted)
            }
        }
        entries.excludeList("excludeLights", in: &fields) { name in
            snapshot.lights.filter { $0.name.lowercased() == name.lowercased() || $0.id.lowercased() == name.lowercased() }.map(\.id)
        }
        entries.excludeList("excludeSensors", in: &fields) { name in
            snapshot.sensors.filter { $0.name.lowercased() == name.lowercased() || $0.id.lowercased() == name.lowercased() }.map { sensorDeviceID($0.id) }
        }
        entries.excludeList("excludeScenes", in: &fields) { name in scenes(matching: name, byID: true).map(\.id) }
        if let list = fields["sceneTransitions"]?.arrayValue {
            // "Room/Scene" first: it was read before a scene's name alone.
            let ordered = list.filter { $0["scene"]?.stringValue?.contains("/") == true } + list.filter { $0["scene"]?.stringValue?.contains("/") != true }
            var left: [JSONValue] = []
            for value in ordered {
                guard let scene = value["scene"]?.stringValue, let milliseconds = value["transitionMs"]?.intValue else { left.append(value); continue }
                let found = scenes(matching: scene, byID: false)
                if found.isEmpty { left.append(value) } else { for match in found { entries.setIfAbsent("transitionMs", .number(Double(milliseconds)), on: match.id) } }
            }
            if left.isEmpty { fields.removeValue(forKey: "sceneTransitions") } else { fields["sceneTransitions"] = .array(left) }
        }
        entries.write(into: &fields)
        return .object(fields)
    }
}
