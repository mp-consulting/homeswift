import Foundation
import Homeswift
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
    /// The room its device is in (a room holds devices; a zone, which crosses rooms, does not count).
    var roomID: String?
    var room: String?
    var signals: [String] = []
    /// A gradient light's points (at most 5) and how many it takes; 0 on other lights.
    var gradientPoints: [HueXY] = []
    var gradientCapacity = 0
    var reachable = true

    var hasColour: Bool { xy != nil }
    var hasColourTemperature: Bool { mirekRange != nil }

    /// Takes in the changed part of the light's resource an event carries (`on`, `dimming`, `color`,
    /// `color_temperature`, an effect, a gradient's points); what it can do stays.
    mutating func apply(_ change: JSONValue) {
        if let on = change["on"]?["on"]?.boolValue { self.on = on }
        if let level = change["dimming"]?["brightness"]?.doubleValue, brightness != nil { brightness = level }
        if let point = HueSnapshot.xy(change["color"]?["xy"]), xy != nil { xy = point }
        if let temperature = change["color_temperature"], mirekRange != nil {
            if temperature["mirek_valid"]?.boolValue == false { mirek = nil } else if let value = temperature["mirek"]?.intValue { mirek = value }
        }
        if let effect = change["effects_v2"]?["status"]?["effect"]?.stringValue ?? change["effects"]?["status"]?.stringValue {
            self.effect = effect == "no_effect" ? nil : effect
        }
        if let points = change["gradient"]?["points"]?.arrayValue { gradientPoints = points.compactMap { HueSnapshot.xy($0["color"]?["xy"]) } }
    }
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
    /// Active with its colours moving (the bridge's `dynamic_palette`), as the Hue app's play button leaves it.
    var playing = false
    /// Plays as soon as it is recalled (the bridge's `auto_dynamic`, the Hue app's Autoplay).
    var autoplay = false
    /// Has a palette, so its colours can move: a scene made of fixed colours per light cannot play.
    var hasPalette = false
    /// Has a colour that is not a white (Hue's standard scenes set whites as xy on colour lights).
    var colourful = false
    /// The scene's colours, for its tile on the page: its palette, else the colours it sets.
    var colours: [HueXY] = []
    /// Its colour temperatures in mirek, when it sets whites.
    var whites: [Int] = []
    var speed: Double?
}

/// A device with sensors or buttons (a motion sensor, a dimmer switch, a Tap dial, a Secure contact sensor): what its
/// services say, each by the id of its resource, so an event about one of them finds it.
struct HueSensorDevice: Sendable, Equatable {
    struct Motion: Sendable, Equatable { var id: String; var detected: Bool; var enabled: Bool }
    struct Temperature: Sendable, Equatable { var id: String; var celsius: Double; var enabled: Bool }
    struct LightLevel: Sendable, Equatable { var id: String; var lux: Double; var enabled: Bool }
    struct Contact: Sendable, Equatable { var id: String; var closed: Bool; var enabled: Bool }
    struct Battery: Sendable, Equatable { var id: String; var level: Int?; var low: Bool }
    /// A button, by its `control_id` (1 to 4 on a dimmer switch), and its last report: an event and when it came.
    struct Button: Sendable, Equatable { var id: String; var controlID: Int; var event: String?; var updated: String? }

    var id: String
    var name: String
    var model: String
    var manufacturer: String
    var firmware: String
    var motion: Motion?
    var temperature: Temperature?
    var lightLevel: LightLevel?
    var contact: Contact?
    var battery: Battery?
    var buttons: [Button] = []
    var reachable = true
    /// The room its device is in, as the Hue app puts it.
    var roomID: String?
    var room: String?

    var hasSensorOrButton: Bool { motion != nil || temperature != nil || lightLevel != nil || contact != nil || !buttons.isEmpty }
    /// The ids of its services' resources.
    var serviceIDs: [String] { [motion?.id, temperature?.id, lightLevel?.id, contact?.id, battery?.id].compactMap { $0 } + buttons.map(\.id) }

    /// Hue's light level, 10,000 × log₁₀(lux) + 1, in lux, within HomeKit's range; 0 is darkness, not 1 lux.
    static func lux(lightLevel: Double) -> Double {
        guard lightLevel > 0 else { return 0.0001 }
        return min(max(pow(10, (lightLevel - 1) / 10000), 0.0001), 100_000)
    }

    /// A button's report as HomeKit's Programmable Switch Event: single press on release, double, long once held; nil
    /// for the steps in between (`initial_press`, `repeat`, `long_release`).
    static func switchEvent(_ event: String) -> Int? {
        switch event {
        case "short_release": HAPConstants.ProgrammableSwitchEvent.singlePress
        case "double_short_release": HAPConstants.ProgrammableSwitchEvent.doublePress
        case "long_press": HAPConstants.ProgrammableSwitchEvent.longPress
        default: nil
        }
    }

    /// The services of `device` among `resources` (by id); nil when it has no sensor or button.
    static func make(device: JSONValue, id: String, resources: [String: JSONValue], reachable: Bool) -> HueSensorDevice? {
        let product = device["product_data"]
        var sensor = HueSensorDevice(
            id: id, name: device["metadata"]?["name"]?.stringValue ?? "Hue sensor",
            model: product?["model_id"]?.stringValue ?? "Hue", manufacturer: product?["manufacturer_name"]?.stringValue ?? "Signify",
            firmware: product?["software_version"]?.stringValue ?? "", reachable: reachable)
        for reference in device["services"]?.arrayValue ?? [] {
            guard let rid = reference["rid"]?.stringValue, let resource = resources[rid] else { continue }
            sensor.apply(resource)
        }
        sensor.buttons.sort { $0.controlID < $1.controlID }
        return sensor.hasSensorOrButton ? sensor : nil
    }

    /// Takes in a resource of this device, whole (a read) or in part (an event, which carries only what changed).
    mutating func apply(_ resource: JSONValue) {
        guard let rid = resource["id"]?.stringValue else { return }
        let enabled = resource["enabled"]?.boolValue
        switch resource["type"]?.stringValue {
        case "motion":
            // `motion_report` is the bridge's current shape; `motion` alone is the older one, kept for a while.
            let detected = resource["motion"]?["motion_report"]?["motion"]?.boolValue ?? resource["motion"]?["motion"]?.boolValue
            var motion = self.motion ?? Motion(id: rid, detected: false, enabled: true)
            if let detected { motion.detected = detected }
            if let enabled { motion.enabled = enabled }
            self.motion = motion
        case "temperature":
            let value = resource["temperature"]?["temperature_report"]?["temperature"]?.doubleValue ?? resource["temperature"]?["temperature"]?.doubleValue
            var temperature = self.temperature ?? Temperature(id: rid, celsius: 0, enabled: true)
            if let value { temperature.celsius = value }
            if let enabled { temperature.enabled = enabled }
            self.temperature = temperature
        case "light_level":
            let value = resource["light"]?["light_level_report"]?["light_level"]?.doubleValue ?? resource["light"]?["light_level"]?.doubleValue
            var level = lightLevel ?? LightLevel(id: rid, lux: 0.0001, enabled: true)
            if let value { level.lux = Self.lux(lightLevel: value) }
            if let enabled { level.enabled = enabled }
            lightLevel = level
        case "contact":
            var contact = self.contact ?? Contact(id: rid, closed: true, enabled: true)
            if let state = resource["contact_report"]?["state"]?.stringValue { contact.closed = state == "contact" }
            if let enabled { contact.enabled = enabled }
            self.contact = contact
        case "device_power":
            var battery = self.battery ?? Battery(id: rid, level: nil, low: false)
            if let level = resource["power_state"]?["battery_level"]?.intValue { battery.level = level }
            if let state = resource["power_state"]?["battery_state"]?.stringValue { battery.low = state != "normal" }
            // A device on mains power reports no battery: it gets no Battery service.
            if battery.level != nil { self.battery = battery }
        case "button":
            let report = resource["button"]?["button_report"]
            let event = report?["event"]?.stringValue ?? resource["button"]?["last_event"]?.stringValue
            if let index = buttons.firstIndex(where: { $0.id == rid }) {
                if let event { buttons[index].event = event }
                if let updated = report?["updated"]?.stringValue { buttons[index].updated = updated }
            } else if let control = resource["metadata"]?["control_id"]?.intValue {
                buttons.append(Button(id: rid, controlID: control, event: event, updated: report?["updated"]?.stringValue))
            }
        default:
            break
        }
    }
}

/// Everything the plugin keeps of the bridge, from one `GET /clip/v2/resource`.
struct HueSnapshot: Sendable, Equatable {
    var lights: [HueLight] = []
    var groups: [HueGroup] = []
    var scenes: [HueScene] = []
    /// The devices with sensors or buttons; a device with a light is the light's, not one of these.
    var sensors: [HueSensorDevice] = []
    /// Which sensor (its index in `sensors`) each sensor service belongs to, by the service's id: an event about it
    /// finds its device at once, and one about anything else is told apart as quickly.
    var sensorOfService: [String: Int] = [:]
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
        var roomOfDevice: [String: (id: String, name: String)] = [:]
        var byID: [String: JSONValue] = [:]
        for resource in resources {
            if let id = resource["id"]?.stringValue { byID[id] = resource }
        }
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
                if resource["type"]?.stringValue == "room", let name = resource["metadata"]?["name"]?.stringValue {
                    for child in resource["children"]?.arrayValue ?? [] where child["rtype"]?.stringValue == "device" {
                        if let device = child["rid"]?.stringValue { roomOfDevice[device] = (id, name) }
                    }
                }
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
        for index in lights.indices {
            (lights[index].roomID, lights[index].room) = (roomOfDevice[lights[index].deviceID]?.id, roomOfDevice[lights[index].deviceID]?.name)
        }
        let lightDevices = Set(lights.map(\.deviceID))
        for (id, device) in devices where !lightDevices.contains(id) {
            guard var sensor = HueSensorDevice.make(device: device, id: id, resources: byID, reachable: !unreachable.contains(id)) else { continue }
            (sensor.roomID, sensor.room) = (roomOfDevice[id]?.id, roomOfDevice[id]?.name)
            sensors.append(sensor)
        }
        sensors.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        for (index, sensor) in sensors.enumerated() {
            for id in sensor.serviceIDs { sensorOfService[id] = index }
        }
        // The bridge keeps a scene's status after its room is switched off (a dimmer, the Hue app, the Home app):
        // a scene is on, and plays, only while its room or zone is on.
        let roomsOn = Dictionary(groups.map { ($0.id, $0.on) }, uniquingKeysWith: { first, _ in first })
        for index in scenes.indices where roomsOn[scenes[index].groupID] == false {
            scenes[index].active = false
            scenes[index].playing = false
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
        scene.playing = resource["status"]?["active"]?.stringValue == "dynamic_palette"
        scene.autoplay = resource["auto_dynamic"]?.boolValue ?? false
        let palette = resource["palette"]
        scene.colours = (palette?["color"]?.arrayValue ?? []).compactMap { xy($0["color"]?["xy"]) }
        scene.whites = (palette?["color_temperature"]?.arrayValue ?? []).compactMap { $0["color_temperature"]?["mirek"]?.intValue }
        scene.hasPalette = !scene.colours.isEmpty || !scene.whites.isEmpty
        if scene.colours.isEmpty, scene.whites.isEmpty {
            for action in resource["actions"]?.arrayValue ?? [] {
                if let point = xy(action["action"]?["color"]?["xy"]) { scene.colours.append(point) }
                if let mirek = action["action"]?["color_temperature"]?["mirek"]?.intValue { scene.whites.append(mirek) }
            }
        }
        scene.colourful = scene.colours.contains { !HueColor.isWhite($0) }
        return scene
    }
}
