import Foundation
import HomeswiftPlugin

/// A light service of the bridge (`light`), with its device's name and product.
struct HueLight: Sendable, Equatable {
    var id: String
    var deviceID: String
    var name: String
    var model: String
    var manufacturer: String
    var product: String
    var firmware: String
    var on: Bool
    /// 0-100, nil on a light that does not dim.
    var brightness: Double?
    var minimumBrightness: Double = 0
    /// The colour temperature in mirek (nil off the white curve), and the light's range; nil on a light without one.
    var mirek: Int?
    var mirekRange: ClosedRange<Int>?
    /// The colour, and what the light can show; nil on a light without colour.
    var xy: HueXY?
    var gamut: HueGamut?
    /// The effects it takes (candle, fire…), without `no_effect`, and the one playing.
    var effects: [String] = []
    var effect: String?
    /// Whether it takes `effects_v2` (an effect with a speed) rather than `effects`.
    var effectsV2 = false
    var signals: [String] = []
    /// A gradient light's points (at most 5) and how many it takes; 0 on other lights.
    var gradientPoints: [HueXY] = []
    var gradientCapacity = 0
    var reachable = true

    var hasColour: Bool { xy != nil }
    var hasColourTemperature: Bool { mirekRange != nil }
    var dims: Bool { brightness != nil }
    var canFlash: Bool { signals.contains("on_off") || signals.contains("on_off_color") }
}

/// A room or a zone, with the grouped light that switches it.
struct HueGroup: Sendable, Equatable {
    var id: String
    /// `room` or `zone`.
    var kind: String
    var name: String
    var groupedLightID: String?
    var on: Bool = false
    /// Its lights' brightness as the bridge sums it up (0 to 100), when it says.
    var brightness: Double?
}

/// A scene of a room or zone; a smart scene (one that follows the time of day) is one too, recalled with `activate`.
struct HueScene: Sendable, Equatable {
    var id: String
    var name: String
    var groupID: String
    var active: Bool
    var smart = false
    /// The scene's colours, for its tile on the page: its palette, else the colours it sets.
    var colours: [HueXY] = []
    /// Its colour temperatures in mirek, when it sets whites.
    var whites: [Int] = []
    var speed: Double?
}

/// Everything the plugin keeps of the bridge, from one `GET /clip/v2/resource`.
struct HueSnapshot: Sendable, Equatable {
    var lights: [HueLight] = []
    var groups: [HueGroup] = []
    var scenes: [HueScene] = []
    var bridgeID: String?

    init(lights: [HueLight] = [], groups: [HueGroup] = [], scenes: [HueScene] = [], bridgeID: String? = nil) {
        self.lights = lights
        self.groups = groups
        self.scenes = scenes
        self.bridgeID = bridgeID
    }

    init(resources: [JSONValue]) {
        var devices: [String: JSONValue] = [:]
        var groupedLights: [String: (on: Bool, brightness: Double?)] = [:]
        var unreachable: Set<String> = []
        for resource in resources {
            guard let id = resource["id"]?.stringValue else { continue }
            switch resource["type"]?.stringValue {
            case "device": devices[id] = resource
            case "grouped_light": groupedLights[id] = (resource["on"]?["on"]?.boolValue ?? false, resource["dimming"]?["brightness"]?.doubleValue)
            case "zigbee_connectivity":
                // A light the bridge cannot reach reports `connectivity_issue` on its device's connectivity.
                if let status = resource["status"]?.stringValue, status != "connected", let owner = resource["owner"]?["rid"]?.stringValue {
                    unreachable.insert(owner)
                }
            case "bridge": bridgeID = resource["bridge_id"]?.stringValue
            default: break
            }
        }
        for resource in resources {
            guard let id = resource["id"]?.stringValue else { continue }
            switch resource["type"]?.stringValue {
            case "light":
                var light = Self.light(resource, id: id, device: resource["owner"]?["rid"]?.stringValue.flatMap { devices[$0] })
                light.reachable = !unreachable.contains(light.deviceID)
                lights.append(light)
            case "room", "zone":
                let grouped = resource["services"]?.arrayValue?.first { $0["rtype"]?.stringValue == "grouped_light" }?["rid"]?.stringValue
                groups.append(HueGroup(
                    id: id, kind: resource["type"]?.stringValue ?? "room", name: resource["metadata"]?["name"]?.stringValue ?? "Room",
                    groupedLightID: grouped, on: grouped.flatMap { groupedLights[$0]?.on } ?? false,
                    brightness: grouped.flatMap { groupedLights[$0]?.brightness }))
            case "scene":
                guard let group = resource["group"]?["rid"]?.stringValue else { continue }
                scenes.append(Self.scene(resource, id: id, group: group))
            case "smart_scene":
                guard let group = resource["group"]?["rid"]?.stringValue else { continue }
                scenes.append(HueScene(
                    id: id, name: resource["metadata"]?["name"]?.stringValue ?? "Smart scene", groupID: group,
                    active: resource["state"]?.stringValue == "active", smart: true))
            default: break
            }
        }
        lights.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        groups.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }
        scenes.sort { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func xy(_ value: JSONValue?) -> HueXY? {
        guard let x = value?["x"]?.doubleValue, let y = value?["y"]?.doubleValue, x.isFinite, y.isFinite else { return nil }
        return HueXY(x: x, y: y)
    }

    static func light(_ resource: JSONValue, id: String, device: JSONValue?) -> HueLight {
        let product = device?["product_data"]
        let name = device?["metadata"]?["name"]?.stringValue ?? resource["metadata"]?["name"]?.stringValue ?? "Hue light"
        var light = HueLight(
            id: id, deviceID: resource["owner"]?["rid"]?.stringValue ?? id, name: name,
            model: product?["model_id"]?.stringValue ?? "Hue", manufacturer: product?["manufacturer_name"]?.stringValue ?? "Signify",
            product: product?["product_name"]?.stringValue ?? "Hue light", firmware: product?["software_version"]?.stringValue ?? "",
            on: resource["on"]?["on"]?.boolValue ?? false)
        if let dimming = resource["dimming"] {
            light.brightness = dimming["brightness"]?.doubleValue ?? 100
            light.minimumBrightness = dimming["min_dim_level"]?.doubleValue ?? 0
        }
        if let temperature = resource["color_temperature"] {
            let schema = temperature["mirek_schema"]
            let low = schema?["mirek_minimum"]?.intValue ?? 153, high = schema?["mirek_maximum"]?.intValue ?? 500
            light.mirekRange = min(low, high)...max(low, high)
            if temperature["mirek_valid"]?.boolValue != false { light.mirek = temperature["mirek"]?.intValue }
        }
        if let colour = resource["color"] {
            light.xy = xy(colour["xy"]) ?? HueColor.white
            if let gamut = colour["gamut"], let red = xy(gamut["red"]), let green = xy(gamut["green"]), let blue = xy(gamut["blue"]) {
                light.gamut = HueGamut(red: red, green: green, blue: blue)
            }
        }
        if let v2 = resource["effects_v2"] {
            light.effectsV2 = true
            light.effects = (v2["action"]?["effect_values"]?.arrayValue ?? v2["status"]?["effect_values"]?.arrayValue ?? []).compactMap(\.stringValue)
            light.effect = v2["status"]?["effect"]?.stringValue
        } else if let effects = resource["effects"] {
            light.effects = (effects["effect_values"]?.arrayValue ?? effects["status_values"]?.arrayValue ?? []).compactMap(\.stringValue)
            light.effect = effects["status"]?.stringValue ?? effects["effect"]?.stringValue
        }
        light.effects.removeAll { $0 == "no_effect" }
        if light.effect == "no_effect" { light.effect = nil }
        light.signals = (resource["signaling"]?["signal_values"]?.arrayValue ?? []).compactMap(\.stringValue)
        if let gradient = resource["gradient"] {
            light.gradientCapacity = gradient["points_capable"]?.intValue ?? 0
            light.gradientPoints = (gradient["points"]?.arrayValue ?? []).compactMap { xy($0["color"]?["xy"]) }
        }
        return light
    }

    static func scene(_ resource: JSONValue, id: String, group: String) -> HueScene {
        var scene = HueScene(
            id: id, name: resource["metadata"]?["name"]?.stringValue ?? "Scene", groupID: group,
            active: (resource["status"]?["active"]?.stringValue ?? "inactive") != "inactive", speed: resource["speed"]?.doubleValue)
        let palette = resource["palette"]
        scene.colours = (palette?["color"]?.arrayValue ?? []).compactMap { xy($0["color"]?["xy"]) }
        scene.whites = (palette?["color_temperature"]?.arrayValue ?? []).compactMap { $0["color_temperature"]?["mirek"]?.intValue }
        if scene.colours.isEmpty, scene.whites.isEmpty {
            for action in resource["actions"]?.arrayValue ?? [] {
                if let point = xy(action["action"]?["color"]?["xy"]) { scene.colours.append(point) }
                if let mirek = action["action"]?["color_temperature"]?["mirek"]?.intValue { scene.whites.append(mirek) }
            }
        }
        return scene
    }
}
