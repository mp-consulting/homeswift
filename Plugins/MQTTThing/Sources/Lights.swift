import Foundation
import Homeswift
import HomeswiftPlugin

/// What a light holds between HomeKit's writes and its combined publish (sections 5.17.2–5.17.5).
final class LightState: @unchecked Sendable {
    var on = false
    var hue = 0.0
    var saturation = 0.0
    var brightness = 100.0
    /// The last value on `getWhite` (RGB with a separate white channel).
    var white = 0
    var lastRGB: [Int]?
    var lastPayload: String?
    weak var adaptiveLighting: AdaptiveLightingController?
}

/// The On characteristic's confirmation (section 6.1).
final class Confirmation: @unchecked Sendable {
    var expected: Bool?
    var retries = 0
    var markedOffline = false
}

extension Thing {
    static let coalescing: Duration = .milliseconds(20)

    /// On, published on `setOn` with confirmation, `turnOffAfterms` and `resetStateAfterms` (5.17.1, 6.1, 6.3).
    @discardableResult
    func on(_ service: ServiceBuilder, _ entry: Entry, onChange: ((Bool) -> Void)? = nil) -> Characteristic {
        let characteristic = service.add(.on)
        let config = entry.config
        let online = entry.online
        let booleans = Booleans(config)
        // Confirmation is the block's, with the block's getOnline (section 5.33).
        let period = self.config.flag("confirmationPeriodms") && config.has("getOn") ? self.config.milliseconds("confirmationPeriodms") : nil
        let retryLimit = self.config.integer("retryLimit") ?? 3
        let indicate = self.config["confirmationIndicateOffline"]?.boolValue
        let marksOffline = indicate != false && (!self.config.has("getOnline") || indicate == true)
        let confirmation = Confirmation()
        let key = "confirm-\(ObjectIdentifier(characteristic))"
        let topic = TopicSpec(config.topics["setOn"], get: false)?.topic ?? "setOn"

        func expire() {
            guard let expected = confirmation.expected else { return }
            if marksOffline, online.isOnline {
                online.isOnline = false
                confirmation.markedOffline = true
                logger.warning("\(config.name): setting accessory state to offline")
            }
            if confirmation.retries > 0 {
                confirmation.retries -= 1
                publish(config, "setOn", property: "on", booleans.encode(expected))
                after(key, period ?? .seconds(1), expire)
            } else {
                confirmation.expected = nil
                logger.error("\(config.name): unresponsive, no confirmation on \(topic), expecting [\(booleans.encode(expected).map(JS.text) ?? "nothing")]")
            }
        }
        func send(_ on: Bool) {
            publish(config, "setOn", property: "on", booleans.encode(on))
            guard let period else { return }
            confirmation.expected = on
            confirmation.retries = retryLimit
            after(key, period, expire)
        }
        let offAfter = config.milliseconds("turnOffAfterms")
        let resetAfter = config.milliseconds("resetStateAfterms")
        func turnedOn() {
            guard let offAfter, config.has("setOn") else { return }
            after("off-\(ObjectIdentifier(characteristic))", offAfter) { [weak characteristic] in
                guard let characteristic else { return }
                characteristic.value = .bool(false)
                send(false)
                onChange?(false)
            }
        }

        serveReads(characteristic, online)
        if config.has("setOn") {
            onWrite(characteristic) { value in
                let on = value.boolValue == true
                send(on)
                onChange?(on)
                if on { turnedOn() }
            }
        } else if let onChange {
            onWrite(characteristic) { onChange($0.boolValue == true) }
        }
        subscribe(config, "getOn", property: "on") { [weak characteristic] message in
            guard let characteristic else { return }
            let flag = booleans.decode(message)
            if period != nil {
                if let expected = confirmation.expected, self.isWaiting(key) {
                    if flag == expected {
                        self.cancel(key)
                        confirmation.expected = nil
                    }
                }
                if !self.isWaiting(key), confirmation.markedOffline {
                    confirmation.markedOffline = false
                    online.isOnline = true
                    self.logger.info("\(config.name): setting accessory state to online")
                }
            }
            guard let flag else { return }
            let changed = characteristic.value.boolValue != flag
            if changed {
                characteristic.value = .bool(flag)
                onChange?(flag)
                if flag { turnedOn() }
            }
            if flag, let resetAfter {
                self.after("reset-\(ObjectIdentifier(characteristic))", resetAfter) { [weak characteristic] in
                    guard let characteristic, characteristic.value.boolValue == true else { return }
                    characteristic.value = .bool(false)
                    onChange?(false)
                }
            }
        }
        return characteristic
    }

    /// On and a level (brightness, a fan's speed) where level 0 is off and no `setOn` exists (5.17.5).
    func levelMeansOff(_ service: ServiceBuilder, _ entry: Entry, level type: CharacteristicType, get: String, set: String, property: String) {
        let config = entry.config
        let on = service.add(.on)
        let level = service.add(type, .int(0))
        serveReads(on, entry.online)
        serveReads(level, entry.online)
        let key = "level-\(ObjectIdentifier(level))"
        func schedule() {
            after(key, Self.coalescing) { [weak on, weak level] in
                guard let on, let level else { return }
                let value = on.value.boolValue == true ? (level.value.intValue ?? 0) : 0
                self.publish(config, set, property: property, .number(Double(value)))
            }
        }
        onWrite(on) { [weak level] value in
            if value.boolValue == true, level?.value.intValue == 0 { level?.value = .int(100) }
            schedule()
        }
        onWrite(level) { [weak on] value in
            if (value.intValue ?? 0) > 0, on?.value.boolValue != true { on?.value = .bool(true) }
            schedule()
        }
        subscribe(config, get, property: property) { [weak on, weak level] message in
            guard let on, let level else { return }
            guard let number = JS.parseInt(message) else {
                self.apply(.double(.nan), to: level, config: config)
                return
            }
            let isOn = number != 0
            guard number != level.value.intValue || isOn != (on.value.boolValue == true) else { return }
            if isOn {
                if let reason = self.invalid(.int(number), for: level, config: config) {
                    self.logger.warning("Ignoring invalid value [\(number)] for \(level.type.name) - \(reason)")
                    return
                }
                level.value = .int(number)
            }
            on.value = .bool(isOn)
        }
    }

    // MARK: Lightbulb

    func lightbulb(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.lightbulb)
        let supportsAdaptiveLighting = config["adaptiveLighting"] != .bool(false)
        if config.has("setHSV") {
            combined(service, entry, mode: .hsv, adaptiveLighting: supportsAdaptiveLighting)
        } else if config.hasAny("setRGB", "setRGBW", "setRGBWW") {
            let mode: LightMode = config.has("setRGBWW") ? .rgbww : config.has("setRGBW") ? .rgbw : config.has("setWhite") ? .rgbWithWhite : .rgb
            combined(service, entry, mode: mode, adaptiveLighting: supportsAdaptiveLighting)
        } else if config.has("setWhite") {
            whiteOnly(service, entry)
        } else {
            separate(service, entry, adaptiveLighting: supportsAdaptiveLighting)
        }
        let built = primary(service, entry)
        if supportsAdaptiveLighting, let controller = context.adaptiveLighting(for: built, accessoryID: id) {
            logger.info("\(config.name): enabling adaptive lighting")
            adaptiveLighting.append(controller)
            lightStates[ObjectIdentifier(service)]?.adaptiveLighting = controller
        }
        return [built]
    }

    enum LightMode { case hsv, rgb, rgbWithWhite, rgbw, rgbww }

    /// Received hue or saturation: Adaptive Lighting stops (section 5.17.6).
    func externalColour(_ light: LightState, _ name: String) {
        guard let controller = light.adaptiveLighting, controller.isAdaptiveLightingActive else { return }
        logger.info("\(name): external control (colour) disabling adaptive lighting")
        controller.disableAdaptiveLighting()
    }

    /// HSV and the RGB family: one combined topic for On, Hue, Saturation and Brightness.
    func combined(_ service: ServiceBuilder, _ entry: Entry, mode: LightMode, adaptiveLighting: Bool) {
        let config = entry.config
        let light = LightState()
        lightStates[ObjectIdentifier(service)] = light
        let hasSetOn = config.has("setOn")
        let hue = service.add(.hue, .int(0)), saturation = service.add(.saturation, .int(0)), brightness = service.add(.brightness, .int(100))
        let on = hasSetOn ? self.on(service, entry) { light.on = $0 } : service.add(.on)
        for characteristic in [hue, saturation, brightness] { serveReads(characteristic, entry.online) }
        if !hasSetOn { serveReads(on, entry.online) }
        let prefix: String? = config.string("hexPrefix").flatMap { $0.isEmpty ? nil : $0 } ?? (config.flag("hex") ? "" : nil)
        let warm = Colour.white(config.string("warmWhite"), default: Colour.defaultWarmWhite)
        let cold = Colour.white(config.string("coldWhite"), default: Colour.defaultColdWhite)
        let switchWhites = config.flag("switchWhites")
        let property: String, setKey: String, getKey: String, count: Int
        switch mode {
        case .hsv: (property, setKey, getKey, count) = ("HSV", "setHSV", "getHSV", 3)
        case .rgb, .rgbWithWhite: (property, setKey, getKey, count) = ("RGB", "setRGB", "getRGB", 3)
        case .rgbw: (property, setKey, getKey, count) = ("RGBW", "setRGBW", "getRGBW", 4)
        case .rgbww: (property, setKey, getKey, count) = ("RGBWW", "setRGBWW", "getRGBWW", 5)
        }
        let key = "light-\(ObjectIdentifier(light))"

        func payload() -> (String, white: Int?) {
            let value = !hasSetOn && !light.on ? 0 : light.brightness
            if mode == .hsv { return ("\(Int(light.hue)),\(Int(light.saturation)),\(Int(value))", nil) }
            let rgb = Colour.rgb(hue: light.hue, saturation: light.saturation, value: value)
            var components: [Int]
            var white: Int?
            switch mode {
            case .rgb, .hsv: components = [rgb.r, rgb.g, rgb.b]
            case .rgbWithWhite, .rgbw:
                let w = min(rgb.r, rgb.g, rgb.b)
                components = [rgb.r - w, rgb.g - w, rgb.b - w]
                if mode == .rgbw { components.append(w) } else { white = w }
            case .rgbww:
                let thresholds = Colour.RGB(
                    r: config.integer("redThreshold") ?? 15, g: config.integer("greenThreshold") ?? 15, b: config.integer("blueThreshold") ?? 15)
                let noMix = config["whiteMix"] == .bool(false) || config.flag("noWhiteMix")
                let out = Colour.rgbww(rgb, warm: warm, cold: cold, noWhiteMix: noMix, thresholds: thresholds)
                components = switchWhites ? [out.r, out.g, out.b, out.cold, out.warm] : [out.r, out.g, out.b, out.warm, out.cold]
            }
            let text = prefix.map { Colour.hex(components, prefix: $0) } ?? components.map(String.init).joined(separator: ",")
            return (text, white)
        }
        func schedule() {
            after(key, Self.coalescing) {
                let (text, white) = payload()
                if text != light.lastPayload {
                    light.lastPayload = text
                    self.publish(config, setKey, property: property, .string(text))
                }
                if let white {
                    let value: JSONValue = prefix.map { .string(Colour.hex([white], prefix: $0)) } ?? .number(Double(white))
                    self.publish(config, "setWhite", property: "white", value)
                }
            }
        }
        onWrite(hue) { light.hue = $0.doubleValue ?? 0; schedule() }
        onWrite(saturation) { light.saturation = $0.doubleValue ?? 0; schedule() }
        onWrite(brightness) { [weak on] value in
            light.brightness = value.doubleValue ?? 0
            if light.brightness > 0, !light.on {
                light.on = true
                on?.value = .bool(true)
            }
            schedule()
        }
        if !hasSetOn {
            onWrite(on) { [weak brightness] value in
                light.on = value.boolValue == true
                if light.on, light.brightness == 0 {
                    light.brightness = 100
                    brightness?.value = .int(100)
                }
                schedule()
            }
        }
        if adaptiveLighting {
            let temperature = service.add(.colorTemperature, .int(140))
            serveReads(temperature, entry.online)
            onWrite(temperature) { [weak hue, weak saturation] value in
                let (h, s) = ColorUtils.colorTemperatureToHueAndSaturation(value.doubleValue ?? 140)
                light.hue = h
                light.saturation = s
                hue?.value = .int(Int(h))
                saturation?.value = .int(Int(s))
                schedule()
            }
        }

        func show(_ rgb: Colour.RGB) {
            let (h, s, v) = Colour.hsv(rgb)
            update(h: Double(h), s: Double(s), v: Double(v))
        }
        func update(h: Double, s: Double, v: Double) {
            if !hasSetOn {
                light.on = v > 0
                if on.value.boolValue != light.on { on.value = .bool(light.on) }
            }
            if h != light.hue || s != light.saturation { externalColour(light, config.name) }
            if h != light.hue { light.hue = h; hue.value = .int(Int(h)) }
            if s != light.saturation { light.saturation = s; saturation.value = .int(Int(s)) }
            if v != light.brightness { light.brightness = v; brightness.value = .int(Int(v)) }
        }
        func received(_ components: [Int]) {
            var c = components
            if switchWhites, c.count == 5 { c.swapAt(3, 4) }
            var rgb = Colour.RGB(r: c[0], g: c[1], b: c[2])
            var white = 0
            switch mode {
            case .rgbww: rgb = Colour.adding(warm: c[3], cold: c[4], to: rgb, warmWhite: warm, coldWhite: cold)
            case .rgbw: white = c[3]
            case .rgbWithWhite: white = light.white
            default: break
            }
            show(Colour.RGB(r: min(rgb.r + white, 255), g: min(rgb.g + white, 255), b: min(rgb.b + white, 255)))
        }
        subscribe(config, getKey, property: property) { message in
            let text = JS.text(message)
            if mode == .hsv {
                let parts = text.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 3 else { return }
                let values = parts.map { JS.parseInt(String($0)) }
                guard let h = values[0], let s = values[1], let v = values[2] else { return }
                update(h: Double(h), s: Double(s), v: Double(v))
                return
            }
            guard let components = Colour.components(text, count: count, hexPrefix: prefix) else { return }
            light.lastRGB = components
            received(components)
        }
        if mode == .rgbWithWhite {
            subscribe(config, "getWhite", property: "white") { message in
                let text = JS.text(message)
                guard let white = prefix != nil ? Colour.components(text, count: 1, hexPrefix: prefix)?.first : (text.contains(",") ? nil : JS.parseInt(message)) else { return }
                light.white = white
                if let last = light.lastRGB { received(last) }
            }
        }
    }

    /// White mode: `setWhite` without an RGB topic (5.17.4).
    func whiteOnly(_ service: ServiceBuilder, _ entry: Entry) {
        let config = entry.config
        let on = service.add(.on), brightness = service.add(.brightness, .int(100))
        serveReads(on, entry.online)
        serveReads(brightness, entry.online)
        let prefix: String? = config.string("hexPrefix").flatMap { $0.isEmpty ? nil : $0 } ?? (config.flag("hex") ? "" : nil)
        func send() {
            let level = on.value.boolValue == true ? min(Int((2.55 * Double(brightness.value.intValue ?? 0)).rounded(.up)), 255) : 0
            publish(config, "setWhite", property: "white", prefix.map { .string(Colour.hex([level], prefix: $0)) } ?? .number(Double(level)))
        }
        // The handler runs before HomeKit's value is stored: the value goes in first, so `send` reads it.
        onWrite(on) { [weak brightness, weak on] value in
            on?.value = value
            if value.boolValue == true, brightness?.value.intValue == 0 { brightness?.value = .int(100) }
            send()
        }
        onWrite(brightness) { [weak on, weak brightness] value in
            brightness?.value = value
            if (value.intValue ?? 0) > 0, on?.value.boolValue != true { on?.value = .bool(true) }
            send()
        }
        subscribe(config, "getWhite", property: "white") { message in
            let text = JS.text(message)
            guard let level = prefix != nil ? Colour.components(text, count: 1, hexPrefix: prefix)?.first : (text.contains(",") ? nil : JS.parseInt(message)) else { return }
            let value = min(Int((Double(level) / 2.55).rounded(.down)), 100)
            if brightness.value.intValue != value { brightness.value = .int(value) }
            if on.value.boolValue != (value > 0) { on.value = .bool(value > 0) }
        }
    }

    /// Separate topics for each characteristic (5.17.5).
    func separate(_ service: ServiceBuilder, _ entry: Entry, adaptiveLighting: Bool) {
        let config = entry.config
        let light = LightState()
        lightStates[ObjectIdentifier(service)] = light
        if config.has("setOn") || !config.has("setBrightness") { on(service, entry) }
        if config.has("setBrightness") {
            if config.has("setOn") {
                integer(service, .brightness, entry, get: "getBrightness", set: "setBrightness", property: "brightness")
            } else {
                levelMeansOff(service, entry, level: .brightness, get: "getBrightness", set: "setBrightness", property: "brightness")
            }
        }
        let name = config.name
        var hue: Characteristic?, saturation: Characteristic?
        if config.has("setHue") {
            hue = integer(service, .hue, entry, get: "getHue", set: "setHue", property: "hue") { _ in self.externalColour(light, name) }
        }
        if config.has("setSaturation") {
            saturation = integer(service, .saturation, entry, get: "getSaturation", set: "setSaturation", property: "saturation") { _ in
                self.externalColour(light, name)
            }
        }
        if config.has("setColorTemperature") {
            let minimum = config.integer("minColorTemperature"), maximum = config.integer("maxColorTemperature")
            let temperature = service.add(CharacteristicType.colorTemperature.with(minValue: minimum.map(Double.init), maxValue: maximum.map(Double.init)), .int(minimum ?? 140))
            bind(
                temperature, config, .int, get: "getColorTemperature", set: "setColorTemperature", property: "colorTemperature", online: entry.online,
                received: { value, changed in if changed { _ = light.adaptiveLighting?.disableIfChangedElsewhere(mireds: value.intValue) } })
        } else if adaptiveLighting, let hue, let saturation {
            let temperature = service.add(.colorTemperature, .int(140))
            serveReads(temperature, entry.online)
            onWrite(temperature) { [weak hue, weak saturation] value in
                let (h, s) = ColorUtils.colorTemperatureToHueAndSaturation(value.doubleValue ?? 140)
                hue?.value = .int(Int(h))
                saturation?.value = .int(Int(s))
                self.publish(config, "setHue", property: "hue", .number(h))
                self.publish(config, "setSaturation", property: "saturation", .number(s))
            }
        }
    }
}
