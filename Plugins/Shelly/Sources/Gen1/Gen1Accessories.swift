import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// One accessory's options: the device's, with its `accessories[i]` entry laid over them.
struct Gen1AccessoryOptions: Sendable, Equatable {
    var type: String?
    var name: String?
    var colorMode: String?

    init(_ fields: [String: JSONValue]) {
        type = fields["type"]?.stringValue?.trimmedNonEmpty
        name = fields["name"]?.stringValue?.trimmedNonEmpty
        colorMode = fields["colorMode"]?.stringValue?.trimmedNonEmpty
    }

    init(type: String? = nil, name: String? = nil, colorMode: String? = nil) {
        self.type = type
        self.name = name
        self.colorMode = colorMode
    }
}

/// Builds a Gen 1 device's accessories, as the Homebridge plugin's factories do, and binds them to its properties.
struct Gen1Builder: Sendable {
    let device: Gen1Device
    let platform: String
    let context: PluginContext
    let logger: Logger
    /// Lights wait this long for the next write (100 ms), rollers `rollerDelay` (1 s) before they move and
    /// `rollerSettle` (500 ms) before their target follows the device.
    let lightDelay: Duration
    let rollerDelay: Duration
    let rollerSettle: Duration

    /// How many accessories a model has in a mode.
    static func count(_ model: Gen1Model, mode: String?) -> Int {
        switch model.family {
        case .relays(let count, _): count
        case .relaysOrRoller: mode == "roller" ? 1 : 2
        case .colorOrWhiteLights: mode == "white" ? 4 : 1
        default: 1
        }
    }

    /// The type an accessory has when its options name none.
    static func defaultType(_ model: Gen1Model, mode: String?) -> String {
        switch model.family {
        case .relays: "switch"
        case .relaysOrRoller: mode == "roller" ? "windowCovering" : "switch"
        case .whiteLight: "whiteLightbulb"
        case .colorTemperatureLight: "colorTemperatureLightbulb"
        case .colorLight: "colorLightbulb"
        case .colorOrWhiteLights: mode == "white" ? "whiteLightbulb" : "colorLightbulb"
        case .buttons: "statelessSwitch"
        case .sensor: "sensor"
        }
    }

    /// The type an accessory gets: lights, buttons and sensors ignore the configured one.
    static func type(_ model: Gen1Model, mode: String?, configured: String?) -> String {
        switch model.family {
        case .relays: configured ?? "switch"
        case .relaysOrRoller: configured ?? defaultType(model, mode: mode)
        default: defaultType(model, mode: mode)
        }
    }

    /// `<model name> <device id>`, with ` #<index>` when the device has several accessories.
    static func seed(_ model: Gen1Model, deviceID: String, index: Int, count: Int) -> String {
        count > 1 ? "\(model.name) \(deviceID) #\(index)" : "\(model.name) \(deviceID)"
    }

    /// An accessory and what keeps it alive (a light's Adaptive Lighting, held here since the service holds it weakly).
    struct Built: Sendable {
        var accessory: Accessory
        var type: String
        var adaptiveLighting: AdaptiveLightingController?
    }

    func build(index: Int, count: Int, options: Gen1AccessoryOptions, deviceName: String?, armed: Bool) async throws -> Built? {
        let model = device.model
        let mode = await device.mode
        let deviceID = device.deviceID
        let seed = Self.seed(model, deviceID: deviceID, index: index, count: count)
        let id = "\(platform):\(seed)"
        let name = options.name ?? deviceName ?? seed
        let type = Self.type(model, mode: mode, configured: options.type)
        var services: [Service] = []
        var category = AccessoryCategory.other
        var adaptiveLighting: AdaptiveLightingController?
        var flashesOnIdentify = false
        switch model.family {
        case .relaysOrRoller where mode == "roller":
            (services, category) = await roller(type: type)
        case .relays(_, let meters), .relaysOrRoller(let meters):
            // The Uni's factory names power meters it does not have: it gets none.
            let meter = meters > 0 && model.id != "SHUNI-1" ? "power\(min(index, meters - 1))" : nil
            (services, category) = await relay(index: index, type: type, meter: meter)
            if ["switch", "outlet", "valve"].contains(Self.relayType(type)) { flashesOnIdentify = true }
        case .whiteLight, .colorTemperatureLight:
            let light = await whiteLight(index: nil, colorTemperature: model.family == .colorTemperatureLight)
            services = [light]
            category = .lightbulb
            if model.family == .colorTemperatureLight { adaptiveLighting = context.adaptiveLighting(for: light, accessoryID: id) }
            flashesOnIdentify = true
        case .colorOrWhiteLights where mode == "white":
            services = [await whiteLight(index: index, colorTemperature: false)]
            category = .lightbulb
            flashesOnIdentify = true
        case .colorLight, .colorOrWhiteLights:
            let colorMode = options.colorMode ?? "rgbw"
            guard colorMode == "rgb" || colorMode == "rgbw" else {
                logger.error("Invalid color mode \"\(colorMode)\" for \(name)")
                return nil
            }
            services = [await colorLight(rgbw: colorMode == "rgbw")]
            category = .lightbulb
            flashesOnIdentify = true
        case .buttons(let buttons):
            services = await buttonServices(buttons, armed: armed)
            category = .programmableSwitch
        case .sensor:
            services = await sensorServices()
            category = .sensor
        }
        if adaptiveLighting != nil {
            let controller = adaptiveLighting
            await device.observe(["colorTemperature"]) { values in
                if let kelvin = values["colorTemperature"]?.number, kelvin > 0 { controller?.disableIfChangedElsewhere(mireds: ShellyColor.mireds(kelvin: kelvin)) }
            }
        }
        let firmware = await device.firmware ?? "1.0.0"
        let device = device, logger = logger, flashes = flashesOnIdentify, primary = services.first
        let accessory = Accessory(
            id: id, name: name, manufacturer: "Shelly", model: model.id, serialNumber: deviceID, firmwareRevision: firmware, category: category,
            services: services, onIdentify: {
                let host = await device.host
                logger.info("\(name) at \(host) identified")
                guard flashes, let primary else { return }
                // Flashes: the on state inverted for a second, then put back.
                let characteristic = primary.characteristic(primary.type == .valve ? .active : .on)
                let original = characteristic.value
                let inverted: HAPValue = primary.type == .valve ? .int(original.intValue == 1 ? 0 : 1) : .bool(!(original.boolValue ?? false))
                try? await characteristic.write(inverted)
                try? await Task.sleep(for: .seconds(1))
                try? await characteristic.write(original)
            })
        if let hardware = await self.device.hardwareRevision { accessory.information.characteristic(adding: .hardwareRevision).value = .string(hardware) }
        return Built(accessory: accessory, type: type, adaptiveLighting: adaptiveLighting)
    }

    // MARK: Relays

    /// `contactSensor`, `motionSensor`, `occupancySensor`, `outlet`, `valve`, else `switch`.
    static func relayType(_ type: String) -> String {
        ["outlet", "valve", "contactSensor", "motionSensor", "occupancySensor"].contains(type) ? type : "switch"
    }

    private func relay(index: Int, type: String, meter: String?) async -> ([Service], AccessoryCategory) {
        let relay = "relay\(index)"
        let device = device
        let write: @Sendable (Bool) async throws -> Void = { on in
            guard await device.value(relay).isTruthy != on else { return }
            do {
                try await device.set(relay, "relay/\(index)", [("turn", on ? "on" : "off")])
            } catch {
                await device.logFailure("Failed to set \(relay)", error)
                throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
            }
        }
        let service: Service
        let category: AccessoryCategory
        switch Self.relayType(type) {
        case "outlet":
            service = Service(.outlet, optional: [.outletInUse], isPrimary: true)
            category = .outlet
            service.characteristic(.on).onWrite { try await write($0.boolValue ?? false) }
            await device.observe([relay, meter ?? relay]) { values in
                service.characteristic(.on).update(.bool(values[relay]?.isTruthy ?? false))
                service.characteristic(.outletInUse).update(.bool(meter.flatMap { values[$0]?.isTruthy } ?? false))
            }
        case "valve":
            service = Service(.valve, isPrimary: true)
            category = .faucet
            service.characteristic(.valveType).value = .int(0)
            service.characteristic(.active).onWrite { try await write($0.intValue == 1) }
            await device.observe([relay, meter ?? relay]) { values in
                let on = values[relay]?.isTruthy ?? false
                service.characteristic(.active).update(.int(on ? 1 : 0))
                service.characteristic(.inUse).update(.int(meter.map { values[$0]?.isTruthy == true ? 1 : 0 } ?? (on ? 1 : 0)))
            }
        case "contactSensor":
            service = Service(.contactSensor, isPrimary: true)
            category = .sensor
            await device.observe([relay]) { values in service.characteristic(.contactSensorState).update(.int(values[relay]?.isTruthy == true ? 1 : 0)) }
        case "motionSensor":
            service = Service(.motionSensor, isPrimary: true)
            category = .sensor
            await device.observe([relay]) { values in service.characteristic(.motionDetected).update(.bool(values[relay]?.isTruthy ?? false)) }
        case "occupancySensor":
            service = Service(.occupancySensor, isPrimary: true)
            category = .sensor
            await device.observe([relay]) { values in service.characteristic(.occupancyDetected).update(.int(values[relay]?.isTruthy == true ? 1 : 0)) }
        default:
            service = Service(.switch, isPrimary: true)
            category = .switch
            service.characteristic(.on).onWrite { try await write($0.boolValue ?? false) }
            await device.observe([relay]) { values in service.characteristic(.on).update(.bool(values[relay]?.isTruthy ?? false)) }
        }
        guard let meter else { return ([service], category) }
        return ([service, await powerMeter(meter)], category)
    }

    private func powerMeter(_ property: String) async -> Service {
        let meter = Service(PowerMeter.service, extra: [Characteristic(PowerMeter.gen1Consumption)])
        await device.observe([property]) { values in meter.characteristic(PowerMeter.gen1Consumption).update(clamping: values[property]?.number ?? 0) }
        return meter
    }

    // MARK: Rollers

    private func roller(type: String) async -> ([Service], AccessoryCategory) {
        let device = device
        if type == "garageDoorOpener" {
            let service = Service(.garageDoorOpener, isPrimary: true)
            let target = service.characteristic(.targetDoorState)
            let written = NIOLockedValueBox<Int?>(nil)
            service.characteristic(.obstructionDetected).value = .bool(false)
            target.onWrite { value in
                guard let state = value.intValue, state != written.withLockedValue({ $0 }) else { return }
                do {
                    try await device.set("rollerPosition", "roller/0", [("go", "to_pos"), ("roller_pos", state == 0 ? "100" : "0")])
                    written.withLockedValue { $0 = state }
                } catch {
                    await device.logFailure("Failed to set roller", error)
                    throw HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
                }
            }
            await device.observe(["rollerState"]) { values in
                let state = values["rollerState"]?.stringValue
                let position = values["rollerPosition"]?.number ?? 0
                let current = state == "open" ? 2 : state == "close" ? 3 : position >= 100 ? 0 : position <= 0 ? 1 : 4
                service.characteristic(.currentDoorState).update(.int(current))
                // Stopped open or closed: what HomeKit asked is done, or a wall button overruled it.
                let goal = written.withLockedValue { written -> Int? in
                    if current == 0 || current == 1 { written = nil }
                    return written
                }
                target.update(.int(goal ?? (current == 0 || current == 2 ? 0 : 1)))
            }
            return ([service], .garageDoorOpener)
        }
        let (serviceType, category): (ServiceType, AccessoryCategory) = switch type {
        case "door": (.door, .door)
        case "window": (.window, .window)
        default: (.windowCovering, .windowCovering)
        }
        let service = Service(serviceType, isPrimary: true)
        let current = service.characteristic(.currentPosition), target = service.characteristic(.targetPosition)
        let state = service.characteristic(.positionState)
        let control = NIOLockedValueBox(0)
        let moves = LatestCallGuard(delay: rollerDelay), settle = rollerSettle
        target.value = .int(Int(saturating: await device.value("rollerPosition").number ?? 0, in: 0...100) ?? 0)
        control.withLockedValue { $0 = target.value.intValue ?? 0 }
        // HomeKit is answered at once; the roller moves a second later, to the last position asked meanwhile.
        target.onWrite { value in
            guard let position = value.intValue, position != control.withLockedValue({ $0 }) else { return }
            let isLatest = moves.ticket()
            Task {
                guard await isLatest() else { return }
                do {
                    try await device.set("rollerPosition", "roller/0", [("go", "to_pos"), ("roller_pos", "\(position)")])
                    control.withLockedValue { $0 = position }
                } catch {
                    await device.logFailure("Failed to set roller", error)
                }
            }
        }
        let recompute = LatestCallGuard(delay: settle)
        await device.observe(["rollerState", "rollerPosition"]) { values in
            let position = Int(saturating: values["rollerPosition"]?.number ?? 0, in: 0...100) ?? 0
            let moving = values["rollerState"]?.stringValue
            current.update(.int(position))
            state.update(.int(moving == "open" ? 1 : moving == "close" ? 0 : 2))
            let isLatest = recompute.ticket()
            Task {
                guard await isLatest() else { return }
                let goal = control.withLockedValue { goal -> Int in
                    switch moving {
                    case "stop": goal = position
                    case "open" where goal <= position: goal = 100
                    case "close" where goal >= position: goal = 0
                    default: break
                    }
                    return goal
                }
                target.update(.int(goal))
            }
        }
        return ([service], category)
    }

    // MARK: Lights

    /// A white light: the Dimmer, Vintage and Duo (`index` nil), or an RGBW2 channel in white mode.
    private func whiteLight(index: Int?, colorTemperature: Bool) async -> Service {
        var optional: [CharacteristicType] = [.brightness]
        if colorTemperature { optional.append(.colorTemperature.with(minValue: 154, maxValue: 370)) }
        let light = Service(.lightbulb, optional: optional, isPrimary: true)
        let on = index.map { "switch\($0)" } ?? "switch", brightness = index.map { "brightness\($0)" } ?? "brightness"
        let path = index.map { "white/\($0)" } ?? "light/0"
        let device = device, writes = LatestCallGuard(delay: lightDelay)
        let pending = PendingWrites()
        let send: @Sendable () async throws -> Void = {
            guard await writes() else { return }
            let current = pending.take(light)
            let isOn = current(.on).boolValue ?? false
            var query = [("turn", isOn ? "on" : "off"), ("brightness", "\(max(current(.brightness).intValue ?? 100, 1))")]
            if colorTemperature {
                let kelvin = 1_000_000 / max(current(.colorTemperature).doubleValue ?? 300, 1)
                let white = min(max(((kelvin - 2700) / (6500 - 2700) * 100).rounded(), 0), 100)
                query += [("temp", "\(Int(kelvin.rounded()))"), ("white", "\(Int(white))")]
            }
            do { try await device.set("light", path, query) } catch { await device.logFailure("Failed to set light", error) }
        }
        pending.register(light, [.on] + optional, send)
        await device.observe([on, brightness, "colorTemperature"]) { values in
            light.characteristic(.on).update(.bool(values[on]?.isTruthy ?? false))
            light.characteristic(.brightness).update(clamping: values[brightness]?.number ?? 0)
            if colorTemperature, let kelvin = values["colorTemperature"]?.number, kelvin > 0 {
                light.characteristic(.colorTemperature).update(clamping: Double(ShellyColor.mireds(kelvin: kelvin)))
            }
        }
        return light
    }

    /// The Bulb, Bulb RGBW and RGBW2 in colour mode: On, Brightness (`gain`), Hue and Saturation from red, green and blue.
    private func colorLight(rgbw: Bool) async -> Service {
        let light = Service(.lightbulb, optional: [.brightness, .hue, .saturation], isPrimary: true)
        let isRGBW2 = device.model.id == "SHRGBW2"
        let device = device, writes = LatestCallGuard(delay: lightDelay), colors = LatestCallGuard(delay: lightDelay)
        let pending = PendingWrites()
        let send: @Sendable () async throws -> Void = {
            guard await writes() else { return }
            let current = pending.take(light)
            let isOn = current(.on).boolValue ?? false
            let gain = max(current(.brightness).intValue ?? 100, 1)
            let color = ShellyColor.rgb(hue: current(.hue).doubleValue ?? 0, saturation: current(.saturation).doubleValue ?? 0)
            var query = isRGBW2 ? [] : [("mode", "color")]
            query += [("turn", isOn ? "on" : "off"), ("gain", "\(gain)"), ("red", "\(color.red)"), ("green", "\(color.green)"), ("blue", "\(color.blue)")]
            if rgbw { query.append(("white", "\(Int((Double(min(color.red, color.green, color.blue)) * Double(gain) / 100).rounded()))")) }
            do { try await device.set("light", isRGBW2 ? "color/0" : "light/0", query) } catch { await device.logFailure("Failed to set light", error) }
        }
        pending.register(light, [.on, .brightness, .hue, .saturation], send)
        await device.observe(["switch", "gain"]) { values in
            light.characteristic(.on).update(.bool(values["switch"]?.isTruthy ?? false))
            light.characteristic(.brightness).update(clamping: values["gain"]?.number ?? 0)
        }
        await device.observe(["red", "green", "blue"]) { values in
            let isLatest = colors.ticket()
            Task {
                guard await isLatest() else { return }
                let hsv = ShellyColor.hsv(red: values["red"]?.number ?? 0, green: values["green"]?.number ?? 0, blue: values["blue"]?.number ?? 0)
                light.characteristic(.hue).update(.double(Double(hsv.hue)))
                light.characteristic(.saturation).update(.double(Double(hsv.saturation)))
            }
        }
        return light
    }

    // MARK: Buttons

    /// Button1's one button (with its battery) or the i3's three, firing on a new `inputEvent` or event counter. A device
    /// made from the cache before it was heard takes its first report as where it is, not as a press.
    private func buttonServices(_ count: Int, armed: Bool) async -> [Service] {
        var services: [Service] = []
        for index in 0..<count {
            let button = Service(.statelessProgrammableSwitch, name: "Button \(index + 1)", subtype: "\(index + 1)", optional: [.serviceLabelIndex])
            button.characteristic(.serviceLabelIndex).value = .int(index + 1)
            let isArmed = NIOLockedValueBox(false)
            let event = "inputEvent\(index)", counter = "inputEventCounter\(index)"
            let logger = logger
            await device.observe([event, counter]) { values in
                guard isArmed.withLockedValue({ armed in defer { armed = true }; return armed }) else { return }
                let press: Int? = switch values[event]?.stringValue {
                case "S": 0
                case "SS": 1
                case "L": 2
                default: nil
                }
                guard let press else { return }
                logger.debug("Button \(index + 1): \(["single", "double", "long"][press]) press")
                button.characteristic(.programmableSwitchEvent).sendEvent(.int(press))
            }
            // `observe` calls at once with what the device has: that call is no press.
            isArmed.withLockedValue { $0 = armed }
            services.append(button)
        }
        if count > 1 {
            let label = Service(.serviceLabel)
            label.characteristic(.serviceLabelNamespace).value = .int(1)
            services.append(label)
        } else {
            services.append(await battery())
        }
        return services
    }

    // MARK: Sensors

    private func sensorServices() async -> [Service] {
        switch device.model.id {
        case "SHDW-1", "SHDW-2":
            var services = [await contact("state"), await lightSensor("illuminance"), await motion("vibration"), await tilt("tilt")]
            if device.model.id == "SHDW-2" { services.append(await temperature("temperature")) }
            return services + [await battery()]
        case "SHWT-1": return [await leak("flood"), await temperature("temperature"), await battery()]
        case "SHHT-1": return [await temperature("temperature"), await humidity("humidity"), await battery(externalPowerIsFull: true)]
        case "SHGS-1": return [await smoke("gas")]
        case "SHSEN-1":
            return [await motion("motion"), await temperature("temperature"), await humidity("humidity"), await lightSensor("illuminance"),
                    await battery(charging: "charging")]
        default: return [await motion("motion"), await lightSensor("illuminance"), await battery()]
        }
    }

    /// A sensor service with Status Fault: General Fault while the device reports `invalid`.
    private func sensor(_ type: ServiceType, _ property: String, invalid: Double, primary: Bool = false,
                        _ apply: @escaping @Sendable (Service, JSONValue) -> Void) async -> Service {
        let service = Service(type, optional: [.statusFault], isPrimary: primary)
        await device.observe([property]) { values in
            let value = values[property] ?? .null
            service.characteristic(.statusFault).update(.int(value.number == invalid ? 1 : 0))
            apply(service, value)
        }
        return service
    }

    private func contact(_ property: String) async -> Service {
        await sensor(.contactSensor, property, invalid: -1, primary: true) { service, value in
            service.characteristic(.contactSensorState).update(.int(!value.isTruthy && value.number != -1 ? 0 : 1))
        }
    }

    private func motion(_ property: String) async -> Service {
        await sensor(.motionSensor, property, invalid: -1) { service, value in
            service.characteristic(.motionDetected).update(.bool(value.isTruthy && value.number != -1))
        }
    }

    private func leak(_ property: String) async -> Service {
        await sensor(.leakSensor, property, invalid: -1, primary: true) { service, value in
            service.characteristic(.leakDetected).update(.int(value.isTruthy && value.number != -1 ? 1 : 0))
        }
    }

    private func smoke(_ property: String) async -> Service {
        let service = Service(.smokeSensor, isPrimary: true)
        await device.observe([property]) { values in
            let gas = values[property]?.stringValue ?? "unknown"
            service.characteristic(.smokeDetected).update(.int(gas == "unknown" || gas == "none" ? 0 : 1))
        }
        return service
    }

    private func temperature(_ property: String) async -> Service {
        let service = Service(.temperatureSensor, optional: [.statusFault, .currentTemperature.with(minValue: -100)])
        await device.observe([property]) { values in
            let value = values[property]?.number ?? 0
            service.characteristic(.statusFault).update(.int(value == 999 ? 1 : 0))
            service.characteristic(.currentTemperature).update(clamping: value == 999 ? 0 : min(max(value, -270), 100))
        }
        return service
    }

    private func humidity(_ property: String) async -> Service {
        await sensor(.humiditySensor, property, invalid: 999) { service, value in
            let humidity = value.number ?? 0
            service.characteristic(.currentRelativeHumidity).update(clamping: humidity == 999 ? 0 : humidity)
        }
    }

    private func lightSensor(_ property: String) async -> Service {
        let service = Service(.lightSensor, optional: [.statusFault, .currentAmbientLightLevel.with(minValue: 0.0001, maxValue: 500_000)])
        await device.observe([property]) { values in
            let lux = values[property]?.number ?? -1
            service.characteristic(.statusFault).update(.int(lux == -1 ? 1 : 0))
            service.characteristic(.currentAmbientLightLevel).update(clamping: lux == -1 ? 0.0001 : lux)
        }
        return service
    }

    private func tilt(_ property: String) async -> Service {
        let service = Service(TiltSensor.service, name: "Tilt Sensor", extra: [Characteristic(.statusFault, value: .int(0))])
        await device.observe([property]) { values in
            let angle = values[property]?.number ?? -1
            service.characteristic(.statusFault).update(.int(angle == -1 ? 1 : 0))
            service.characteristic(TiltSensor.angle).update(clamping: angle == -1 ? 0 : angle)
        }
        return service
    }

    private func battery(externalPowerIsFull: Bool = false, charging: String? = nil) async -> Service {
        let service = Service(.battery, optional: [.batteryLevel, .chargingState])
        service.characteristic(.chargingState).value = .int(2)
        await device.observe(["battery", charging ?? "battery"]) { values in
            var level = values["battery"]?.number ?? 0
            if externalPowerIsFull, level == -1 { level = 100 }
            level = min(max(level, 0), 100)
            service.characteristic(.batteryLevel).update(clamping: level)
            service.characteristic(.statusLowBattery).update(.int(level < 10 ? 1 : 0))
            if let charging { service.characteristic(.chargingState).update(.int(values[charging]?.isTruthy == true ? 1 : 0)) }
        }
        return service
    }
}
