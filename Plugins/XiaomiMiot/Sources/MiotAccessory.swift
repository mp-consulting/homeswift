import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

// The generic mapping of a MIoT device to HomeKit (docs/clean-room/XiaomiMiot.md section 7): its spec's standard
// services and properties, by their type URNs, become HomeKit services; each characteristic is bound to the properties it
// shows, so a poll sets only what changed, and its writes go to the device through `DeviceHandle`.

typealias PropertyValues = [PropertyKey: JSONValue]

/// Characteristics shown from some properties: the device calls `apply` when one of `keys` changed.
struct MiotBinding: Sendable {
    var keys: Set<PropertyKey>
    /// `fromDevice` is false for the echo of the bridge's own write.
    var apply: @Sendable (_ values: PropertyValues, _ fromDevice: Bool) -> Void
}

/// What an accessory's handlers ask its device, which they reach weakly: the device holds the accessory.
final class DeviceHandle: Sendable {
    private let box = NIOLockedValueBox<WeakDevice>(WeakDevice())
    struct WeakDevice { weak var device: (any MiotDeviceIO)? }

    var device: (any MiotDeviceIO)? { box.withLockedValue { $0.device } }

    func attach(_ device: any MiotDeviceIO) {
        box.withLockedValue { $0.device = device }
    }

    private func required() throws -> any MiotDeviceIO {
        guard let device else { throw HAPStatusError(.serviceCommunicationFailure) }
        return device
    }

    func write(_ property: MiotSpec.Property, _ value: JSONValue, debounce: Bool = false) async throws {
        try await required().write(property, value, debounce: debounce)
    }

    func run(_ action: MiotSpec.Action, _ inputs: [JSONValue] = []) async throws {
        try await required().run(action, inputs: inputs)
    }

    func raw(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await required().raw(method, params)
    }

    func value(_ key: PropertyKey) async -> JSONValue? {
        await device?.value(key)
    }
}

protocol MiotDeviceIO: AnyObject, Sendable {
    /// Sets a property (6.4: clamped, skipped when it has that value already); `debounce` lets only the last of quick
    /// writes through (7.5).
    func write(_ property: MiotSpec.Property, _ value: JSONValue, debounce: Bool) async throws
    /// Runs an action with its `in` values, as homebridge-miot sends them (2.3).
    func run(_ action: MiotSpec.Action, inputs: [JSONValue]) async throws
    /// A raw miIO method.
    func raw(_ method: String, _ params: JSONValue) async throws -> JSONValue
    func value(_ key: PropertyKey) async -> JSONValue?
}

/// The waits of the accessory's own behaviour (7.2, 7.8); tests shorten them.
struct AccessoryTimings: Sendable {
    /// A stateless switch turns itself off, a value switch turned off back on, after this.
    var switchReset: Duration = .milliseconds(100)
    /// How long a Hue write waits for its Saturation (and the other way round) to be sent with it as one colour: the
    /// Home app writes both of a change at once (7.2 allows up to 1 s).
    var colorWait: Duration = LightChangeBatcher.defaultWindow
}

/// What a device's spec becomes in HomeKit.
struct BuiltAccessory: @unchecked Sendable {
    var accessory: Accessory
    var bindings: [MiotBinding]
    /// The readable properties a poll reads.
    var polled: [PropertyKey]
    /// Adaptive Lighting of its lights: kept here, as a lightbulb holds it weakly.
    var adaptiveLighting: [AdaptiveLightingController]
    /// The services Status Active follows (vacuum, monitors).
    var statusActive: [Service]
}

/// Plugin-wide values the mapping reads.
struct MappingDefaults: Sendable {
    var pm25Breakpoints: [Int] = MiotConversions.defaultBreakpoints
    var co2AbnormalThreshold: Double = 1000
}

final class MiotAccessoryBuilder {
    let spec: MiotSpec
    let model: String
    let name: String
    let accessoryID: String
    let serialNumber: String
    let firmware: String
    let options: DeviceOptions
    let defaults: MappingDefaults
    let handle: DeviceHandle
    let timings: AccessoryTimings
    let logger: Logger
    let makeAdaptiveLighting: (Service) -> AdaptiveLightingController?

    var primary: Service?
    var linked: [Service] = []
    var bindings: [MiotBinding] = []
    var polled = Set<PropertyKey>()
    var adaptive: [AdaptiveLightingController] = []
    var statusActive: [Service] = []
    var category: AccessoryCategory = .other
    var onIdentify: (@Sendable () async throws -> Void)?
    /// Subtypes given, so two controls never share one.
    private var subtypes = Set<String>()
    private var names = Set<String>()

    init(spec: MiotSpec, model: String, name: String, accessoryID: String, serialNumber: String, firmware: String, options: DeviceOptions,
         defaults: MappingDefaults, handle: DeviceHandle, timings: AccessoryTimings, logger: Logger,
         makeAdaptiveLighting: @escaping (Service) -> AdaptiveLightingController?) {
        self.spec = spec
        self.model = model
        self.name = name
        self.accessoryID = accessoryID
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.options = options
        self.defaults = defaults
        self.handle = handle
        self.timings = timings
        self.logger = logger
        self.makeAdaptiveLighting = makeAdaptiveLighting
    }

    var deviceType: String { spec.deviceType }
    var kind: String { MiotSpec.kind(deviceType: deviceType) }
    var main: MiotSpec.Service? { spec.mainService }
    var quirks: ModelQuirks { MiotSpec.quirks(model: model) }

    /// A vendor property a quirk names, when the spec has it.
    func property(_ vendor: VendorProperty?) -> MiotSpec.Property? {
        vendor.flatMap { spec.anyProperty($0.property, in: $0.service) }
    }

    // MARK: Building

    /// The accessory, or nil when nothing of the spec maps and no extra control is set.
    func build() -> BuiltAccessory? {
        if !options.customAccessory {
            switch deviceType {
            case "vacuum": buildVacuum()
            case "light": buildLight()
            case "outlet": buildOutlet()
            case "switch": buildSwitches()
            case "air-purifier": buildAirPurifier()
            case "humidifier", "dehumidifier": buildHumidifier(dehumidifier: deviceType == "dehumidifier")
            case "fan": buildFan()
            case "heater": buildHeater()
            case "air-conditioner": buildAirConditioner()
            case "curtain", "window-opener", "motor-controller": buildCurtain()
            case "temperature-humidity-sensor": buildSensor()
            default: buildGeneric()
            }
            if !options.onlyMainService { buildCommon() }
        }
        buildExtraControls()
        let services = (primary.map { [$0] } ?? []) + linked
        guard !services.isEmpty else { return nil }
        if let primary { primary.linked = linked.filter { !$0.isHidden } }
        if options.customAccessory || primary == nil { category = .other }
        let accessory = Accessory(
            id: accessoryID, name: name, manufacturer: Self.manufacturer(model: model), model: model, serialNumber: serialNumber,
            firmwareRevision: firmware, category: category, services: services, onIdentify: onIdentify ?? defaultIdentify())
        return BuiltAccessory(accessory: accessory, bindings: bindings, polled: polled.sorted(), adaptiveLighting: adaptive, statusActive: statusActive)
    }

    /// `Yeelight Technology` for `yeelink.*`; the model's first segment capitalised; `Xiaomi` without a dot (7.1).
    static func manufacturer(model: String) -> String {
        if model.hasPrefix("yeelink.") { return "Yeelight Technology" }
        guard let dot = model.firstIndex(of: "."), dot > model.startIndex else { return "Xiaomi" }
        let first = model[..<dot]
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// An `identify:identify` action makes the accessory identify itself.
    private func defaultIdentify() -> (@Sendable () async throws -> Void)? {
        guard let action = spec.service("identify")?.action("identify") ?? spec.service("device-information")?.action("identify") else { return nil }
        let handle = handle
        return { try await handle.run(action) }
    }

    // MARK: Helpers

    func bind(_ properties: [MiotSpec.Property?], _ apply: @escaping @Sendable (PropertyValues, Bool) -> Void) {
        let present = properties.compactMap { $0 }
        guard !present.isEmpty else { return }
        for property in present where property.isReadable { polled.insert(property.key) }
        bindings.append(MiotBinding(keys: Set(present.map(\.key)), apply: apply))
    }

    /// A subtype not given yet: the next free `-<n>` after `base` when it was.
    func subtype(_ base: String) -> String {
        var candidate = base, index = 2
        while subtypes.contains(candidate) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        subtypes.insert(candidate)
        return candidate
    }

    /// A service name HomeKit takes (7.7), ` <n>` added to a duplicate.
    func serviceName(_ raw: String) -> String {
        let base = MiotConversions.homeKitName(raw)
        var candidate = base, index = 2
        while names.contains(candidate) {
            candidate = "\(base) \(index)"
            index += 1
        }
        names.insert(candidate)
        return candidate
    }

    func add(_ service: Service) {
        linked.append(service)
    }

    static func set(_ characteristic: Characteristic?, _ value: HAPValue) {
        guard let characteristic, characteristic.value != value else { return }
        characteristic.value = value
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: number.isFinite ? number : nil
        case .bool(let flag)?: flag ? 1 : 0
        case .string(let text)?: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag)?: flag
        case .number(let number)?: number != 0
        case .string(let text)?: ["true", "1", "on"].contains(text.lowercased())
        default: nil
        }
    }

    /// The property's value is one of the values described `description`.
    static func isDescribed(_ value: JSONValue?, _ description: String, in property: MiotSpec.Property?) -> Bool {
        guard let value, let property else { return false }
        return property.values(described: description).contains { MiotSpec.sameValue($0, value) }
    }

    /// A characteristic type with the property's range as its bounds and step.
    static func bounded(_ type: CharacteristicType, _ property: MiotSpec.Property?, defaultRange: ClosedRange<Double>? = nil, step: Double? = nil) -> CharacteristicType {
        let lower = property?.isRange == true ? property?.lower : defaultRange?.lowerBound
        let upper = property?.isRange == true ? property?.upper : defaultRange?.upperBound
        let minStep = step ?? (property?.isRange == true ? property?.step : nil)
        return type.with(minValue: lower, maxValue: upper, minStep: minStep)
    }

    /// A temperature in Celsius from a `celsius` or `fahrenheit` property.
    static func celsius(_ value: JSONValue?, _ property: MiotSpec.Property) -> Double? {
        guard let number = number(value) else { return nil }
        return property.unit == "fahrenheit" ? MiotConversions.celsius(fahrenheit: number) : number
    }

    /// Active (0/1) written as the `on` property.
    func bindActive(_ service: Service, on property: MiotSpec.Property?, type: CharacteristicType = .active) {
        guard let property else { return }
        let characteristic = service.characteristic(adding: type)
        bind([property]) { values, _ in
            guard let on = Self.bool(values[property.key]) else { return }
            Self.set(characteristic, type == .on ? .bool(on) : .int(on ? 1 : 0))
        }
        guard property.isWritable else { return }
        let handle = handle
        characteristic.onWrite { value in try await handle.write(property, .bool(value.boolValue ?? false)) }
    }

    /// Lock Physical Controls on the primary (2.3 `childLockControl`).
    func bindChildLock(_ service: Service) {
        guard options.childLockControl, ["fan", "airPurifier", "humidifier", "dehumidifier", "heater", "airConditioner"].contains(kind),
              let property = spec.property("physical-controls-locked", "physical-controls-locked") else { return }
        let characteristic = service.characteristic(adding: .lockPhysicalControls)
        bind([property]) { values, _ in
            guard let locked = Self.bool(values[property.key]) else { return }
            Self.set(characteristic, .int(locked ? 1 : 0))
        }
        if property.isWritable {
            let handle = handle
            characteristic.onWrite { value in try await handle.write(property, .bool(value.intValue == 1)) }
        }
    }

    /// Rotation Speed over levels (a value list without Auto, or a range by its step; 7.2). 0 writes nothing.
    func bindLevels(_ service: Service, _ property: MiotSpec.Property?, before: (@Sendable () async throws -> Void)? = nil) {
        guard let property else { return }
        let levels = MiotConversions.levels(of: property)
        guard !levels.isEmpty else { return }
        let characteristic = service.characteristic(adding: .rotationSpeed)
        bind([property]) { values, _ in
            guard let value = values[property.key] else { return }
            let index = levels.firstIndex { MiotSpec.sameValue($0, value) }
            // A device in its Auto level reads 0.
            Self.set(characteristic, .double(Double(index.map { MiotConversions.speed(levelIndex: $0, count: levels.count) } ?? 0)))
        }
        guard property.isWritable else { return }
        let handle = handle
        characteristic.onWrite { value in
            guard let speed = value.doubleValue, let index = MiotConversions.levelIndex(speed: speed, count: levels.count) else { return }
            try await before?()
            try await handle.write(property, levels[index], debounce: true)
        }
    }

    /// Rotation Speed as a range's position (a curated override's speed property).
    func bindRangeSpeed(_ service: Service, _ property: MiotSpec.Property, before: (@Sendable () async throws -> Void)? = nil) {
        let characteristic = service.characteristic(adding: .rotationSpeed)
        bind([property]) { values, _ in
            guard let value = Self.number(values[property.key]) else { return }
            Self.set(characteristic, .double(Double(MiotConversions.percent(value, of: property))))
        }
        guard property.isWritable else { return }
        let handle = handle
        characteristic.onWrite { value in
            guard let speed = value.doubleValue, speed > 0 else { return }
            try await before?()
            try await handle.write(property, .number(MiotConversions.value(percent: speed, of: property)), debounce: true)
        }
    }

    // MARK: Lights

    /// A Lightbulb from a `light` (or `ambient-light`) service: On, Brightness, Color Temperature, Hue and Saturation,
    /// and Adaptive Lighting with Brightness and Color Temperature.
    @discardableResult
    func lightbulb(_ light: MiotSpec.Service, name: String, subtype: String?, isPrimary: Bool) -> Service? {
        guard let on = light.property("on") else { return nil }
        let brightness = light.property("brightness").flatMap { $0.isRange ? $0 : nil }
        let temperature = light.property("color-temperature").flatMap { $0.isRange ? $0 : nil }
        let color = light.property("color")
        let mode = light.property("mode")
        var optional: [CharacteristicType] = []
        if brightness != nil { optional.append(.brightness) }
        var extra: [Characteristic] = []
        var temperatureBounds: (min: Int, max: Int)?
        if let temperature, let lower = temperature.lower, let upper = temperature.upper {
            let bounds = temperature.unit == "percentage"
                ? (min: MiotConversions.mireds(percent: upper), max: MiotConversions.mireds(percent: lower))
                : MiotConversions.miredBounds(kelvinLower: lower, kelvinUpper: upper)
            temperatureBounds = bounds
            extra.append(Characteristic(.colorTemperature.with(minValue: Double(bounds.min), maxValue: Double(bounds.max)), value: .int(bounds.min)))
        }
        if color != nil { optional += [.hue, .saturation] }
        let service = Service(.lightbulb, name: name, subtype: subtype, optional: optional, extra: extra, isPrimary: isPrimary)
        bindActive(service, on: on, type: .on)
        let handle = handle
        if let brightness {
            let characteristic = service.characteristic(.brightness)
            bind([brightness]) { values, _ in
                guard let value = Self.number(values[brightness.key]) else { return }
                Self.set(characteristic, .int(MiotConversions.percent(value, of: brightness)))
            }
            if brightness.isWritable {
                characteristic.onWrite { value in
                    // A 0 is clamped to the range's minimum.
                    let target = MiotConversions.value(percent: value.doubleValue ?? 0, of: brightness)
                    try await handle.write(brightness, .number(target), debounce: true)
                }
            }
        }
        var controller: AdaptiveLightingController?
        if let temperature, let bounds = temperatureBounds {
            let characteristic = service.characteristic(.colorTemperature)
            let percentage = temperature.unit == "percentage"
            @Sendable func mireds(_ value: Double) -> Int {
                let raw = percentage ? MiotConversions.mireds(percent: value) : MiotConversions.mireds(kelvin: value)
                return min(max(raw, bounds.min), bounds.max)
            }
            if temperature.isWritable {
                characteristic.onWrite { value in
                    guard let mired = value.doubleValue, mired > 0 else { return }
                    let target = percentage ? MiotConversions.percent(mireds: mired) : MiotConversions.kelvin(mireds: mired)
                    try await handle.write(temperature, .number(target), debounce: true)
                }
            }
            if brightness != nil {
                controller = makeAdaptiveLighting(service)
                if let controller { adaptive.append(controller) }
            }
            let isColorMode: @Sendable (PropertyValues) -> Bool = { values in
                guard let mode else { return false }
                return Self.isDescribed(values[mode.key], "Color", in: mode)
            }
            bind([temperature, mode]) { [weak controller] values, fromDevice in
                guard let value = Self.number(values[temperature.key]) else { return }
                let shown = mireds(value)
                // The device's own report of a white: Adaptive Lighting stops when it was set elsewhere.
                if fromDevice, !isColorMode(values) { controller?.disableIfChangedElsewhere(mireds: shown) }
                Self.set(characteristic, .int(shown))
            }
        }
        if let color {
            let hue = service.characteristic(.hue), saturation = service.characteristic(.saturation)
            let previous = NIOLockedValueBox<JSONValue?>(nil)
            bind([color, mode]) { [weak controller] values, fromDevice in
                guard let value = Self.number(values[color.key]), let rgb = Int(saturating: value) else { return }
                let changed = previous.withLockedValue { last in
                    defer { last = values[color.key] }
                    return last != nil && last != values[color.key]
                }
                let colorMode = mode.map { Self.isDescribed(values[$0.key], "Color", in: $0) } ?? true
                // A colour the device reports set elsewhere turns Adaptive Lighting off.
                if fromDevice, changed, colorMode { controller?.disableIfChangedElsewhere(mireds: nil) }
                let (h, s) = MiotConversions.hueSaturation(rgb: rgb)
                Self.set(hue, .double(Double(h)))
                Self.set(saturation, .double(Double(s)))
            }
            if color.isWritable {
                // Hue and Saturation written together are sent as one colour (7.2); one alone goes with the other's shown value.
                // The characteristics are held weakly: they hold the writer through their handlers.
                let writer = LightChangeBatcher(window: timings.colorWait) { [weak hue, weak saturation] changes in
                    let rgb = MiotConversions.rgb(hue: changes.hue ?? hue?.value.doubleValue ?? 0,
                                                  saturation: changes.saturation ?? saturation?.value.doubleValue ?? 0)
                    try await handle.write(color, .number(Double(rgb)))
                }
                hue.onWrite { value in
                    guard let wanted = value.doubleValue else { return }
                    try await writer.set(.hue(wanted))
                }
                saturation.onWrite { value in
                    guard let wanted = value.doubleValue else { return }
                    try await writer.set(.saturation(wanted))
                }
            }
        }
        return service
    }

    func buildLight() {
        category = .lightbulb
        let lights = spec.services("light")
        guard let first = lights.first else { return buildGeneric() }
        primary = lightbulb(first, name: name, subtype: nil, isPrimary: true)
        for other in lights.dropFirst() {
            if let service = lightbulb(other, name: serviceName("\(name) Light"), subtype: subtype("\(other.urn.name)-\(other.iid)"), isPrimary: false) { add(service) }
        }
    }

    /// The lights a device of another type has: `ambient-light`, and `light` services (a ceiling fan's).
    func buildOtherLights() {
        for ambient in spec.services("ambient-light") {
            if let service = lightbulb(ambient, name: serviceName("Ambient Light"), subtype: subtype("\(ambient.urn.name)-\(ambient.iid)"), isPrimary: false) { add(service) }
        }
        guard deviceType != "light" else { return }
        for light in spec.services("light") {
            if let service = lightbulb(light, name: serviceName("\(name) Light"), subtype: subtype("\(light.urn.name)-\(light.iid)"), isPrimary: false) { add(service) }
        }
    }

    // MARK: Outlets and switches

    func buildOutlet() {
        category = .outlet
        let switches = spec.services("switch")
        guard !switches.isEmpty else { return buildGeneric() }
        let handle = handle
        for (index, item) in switches.enumerated() {
            guard let on = item.property("on") else { continue }
            let isFirst = primary == nil
            let label = isFirst ? name : serviceName(item.description.lowercased().contains("usb") ? "USB" : "Outlet \(index + 1)")
            var extra: [Characteristic] = []
            // Current power in watts (Eve's Current Consumption): the runtime makes it a Meter.
            let power = isFirst ? (spec.property("power-consumption", "electric-power") ?? item.property("electric-power")).flatMap { $0.unit == "watt" ? $0 : nil } : nil
            if power != nil { extra.append(Characteristic(EveCharacteristic.currentConsumption, value: .int(0))) }
            let service = Service(.outlet, name: label, subtype: isFirst ? nil : subtype("\(item.urn.name)-\(item.iid)"), optional: [.outletInUse], extra: extra,
                                  isPrimary: isFirst)
            let onCharacteristic = service.characteristic(.on), inUse = service.characteristic(.outletInUse)
            bind([on]) { values, _ in
                guard let value = Self.bool(values[on.key]) else { return }
                Self.set(onCharacteristic, .bool(value))
                Self.set(inUse, .bool(value))
            }
            if on.isWritable { onCharacteristic.onWrite { value in try await handle.write(on, .bool(value.boolValue ?? false)) } }
            if let power, let characteristic = service[EveCharacteristic.currentConsumption] {
                bind([power]) { values, _ in
                    guard let watts = Self.number(values[power.key]) else { return }
                    Self.set(characteristic, .int(Int(saturating: MiotConversions.round(watts), in: 0...100_000) ?? 0))
                }
            }
            if isFirst { primary = service } else { add(service) }
        }
    }

    func buildSwitches() {
        category = .switch
        let switches = spec.services("switch").filter { $0.property("on") != nil }
        guard !switches.isEmpty else { return buildGeneric() }
        for (index, item) in switches.enumerated() {
            guard let on = item.property("on") else { continue }
            let label = switches.count == 1 ? name : serviceName("\(name) \(item.description.isEmpty ? String(index + 1) : item.description)")
            let service = Service(.switch, name: label, subtype: index == 0 ? nil : subtype("\(item.urn.name)-\(item.iid)"), isPrimary: index == 0)
            bindActive(service, on: on, type: .on)
            if index == 0 { primary = service } else { add(service) }
        }
    }

    // MARK: Air purifiers

    func buildAirPurifier() {
        category = .airPurifier
        guard let purifier = spec.service("air-purifier") else { return buildGeneric() }
        let on = purifier.property("on"), mode = purifier.property("mode"), status = purifier.property("status")
        // A curated override (7.9): the speed is a vendor favourite level, set in the Favorite mode; a motor's speed says it is idle.
        let favorite = property(quirks.speed?.level), motor = property(quirks.speed?.idleAtZero)
        let service = Service(.airPurifier, name: name, isPrimary: true)
        bindActive(service, on: on)
        let current = service.characteristic(.currentAirPurifierState)
        bind([on, status, motor]) { values, _ in
            guard let on, let isOn = Self.bool(values[on.key]) else { return }
            let idle = Self.isDescribed(values[status?.key ?? on.key], "Idle", in: status) || motor.flatMap { Self.number(values[$0.key]) } == 0
            Self.set(current, .int(!isOn ? 0 : idle ? 1 : 2))
        }
        let handle = handle
        if let mode {
            let target = service.characteristic(.targetAirPurifierState)
            bind([mode]) { values, _ in
                guard let value = values[mode.key] else { return }
                let auto = Self.isDescribed(value, "Auto", in: mode) || Self.isDescribed(value, "Sleep", in: mode)
                Self.set(target, .int(auto ? 1 : 0))
            }
            if mode.isWritable {
                target.onWrite { value in
                    let wanted = value.intValue == 1 ? mode.value(described: "Auto")
                        : mode.value(described: "Favorite") ?? mode.value(described: "Manual") ?? mode.value(described: "None")
                    if let wanted { try await handle.write(mode, wanted) }
                }
            }
        }
        if let favorite, favorite.isRange {
            let favoriteMode = mode?.value(described: "Favorite")
            bindRangeSpeed(service, favorite) {
                if let mode, let favoriteMode { try await handle.write(mode, favoriteMode) }
            }
        } else {
            bindLevels(service, purifier.property("fan-level"))
        }
        bindChildLock(service)
        primary = service
    }

    // MARK: Humidifiers

    func buildHumidifier(dehumidifier: Bool) {
        category = dehumidifier ? .dehumidifier : .humidifier
        guard let main = spec.service(deviceType) else { return buildGeneric() }
        let on = main.property("on")
        let threshold = main.property("target-humidity")
        let thresholdType: CharacteristicType = dehumidifier ? .relativeHumidityDehumidifierThreshold : .relativeHumidityHumidifierThreshold
        var optional: [CharacteristicType] = []
        if let threshold { optional.append(Self.bounded(thresholdType, threshold, defaultRange: 0...100)) }
        let service = Service(.humidifierDehumidifier, name: name, optional: optional, extra: [
            Characteristic(.targetHumidifierDehumidifierState.with(validValues: [dehumidifier ? 2 : 1]), value: .int(dehumidifier ? 2 : 1)),
        ], isPrimary: true)
        bindActive(service, on: on)
        let current = service.characteristic(.currentHumidifierDehumidifierState.with(validValues: [0, 1, 2, 3]))
        bind([on]) { values, _ in
            guard let on, let isOn = Self.bool(values[on.key]) else { return }
            Self.set(current, .int(isOn ? (dehumidifier ? 3 : 2) : 0))
        }
        let handle = handle
        if let on, on.isWritable {
            // The only target: setting it turns the device on.
            service.characteristic(.targetHumidifierDehumidifierState).onWrite { _ in try await handle.write(on, .bool(true)) }
        }
        let humidity = main.property("relative-humidity") ?? spec.property("environment", "relative-humidity")
        if let humidity {
            let characteristic = service.characteristic(.currentRelativeHumidity)
            bind([humidity]) { values, _ in
                guard let value = Self.number(values[humidity.key]) else { return }
                Self.set(characteristic, .double(min(max(value, 0), 100)))
            }
        }
        if let threshold {
            let characteristic = service.characteristic(thresholdType)
            bind([threshold]) { values, _ in
                guard let value = Self.number(values[threshold.key]) else { return }
                Self.set(characteristic, .double(value))
            }
            if threshold.isWritable {
                characteristic.onWrite { value in try await handle.write(threshold, .number(value.doubleValue ?? 0), debounce: true) }
            }
        }
        bindLevels(service, main.property("fan-level") ?? main.property("speed-level"))
        if let water = main.property("water-level"), water.isRange {
            let characteristic = service.characteristic(adding: .waterLevel)
            bind([water]) { values, _ in
                guard let value = Self.number(values[water.key]) else { return }
                Self.set(characteristic, .double(Double(MiotConversions.percent(value, of: water))))
            }
        } else if let shortage = spec.anyProperty("water-shortage-fault") {
            let characteristic = service.characteristic(adding: .waterLevel)
            bind([shortage]) { values, _ in
                guard let fault = Self.bool(values[shortage.key]) else { return }
                Self.set(characteristic, .double(fault ? 0 : 100))
            }
        }
        bindChildLock(service)
        primary = service
    }

    // MARK: Fans

    func buildFan() {
        category = .fan
        guard let fan = spec.service("fan") else { return buildGeneric() }
        let on = fan.property("on")
        let service = Service(.fanv2, name: name, isPrimary: true)
        bindActive(service, on: on)
        // A curated override (7.9): the speed is a vendor range, idle while another property is 0.
        let speedLevel = property(quirks.speed?.level), speedNow = property(quirks.speed?.idleAtZero)
        let current = service.characteristic(adding: .currentFanState)
        bind([on, speedNow]) { values, _ in
            guard let on, let isOn = Self.bool(values[on.key]) else { return }
            let idle = speedNow.flatMap { Self.number(values[$0.key]) } == 0
            Self.set(current, .int(!isOn ? 0 : idle ? 1 : 2))
        }
        if let speedLevel, speedLevel.isRange {
            bindRangeSpeed(service, speedLevel)
        } else {
            bindLevels(service, fan.property("fan-level") ?? fan.property("speed-level"))
        }
        if let swing = fan.property("horizontal-swing") {
            bindSwing(service, swing)
        }
        bindChildLock(service)
        primary = service
    }

    func bindSwing(_ service: Service, _ property: MiotSpec.Property) {
        let characteristic = service.characteristic(adding: .swingMode)
        bind([property]) { values, _ in
            guard let on = Self.bool(values[property.key]) else { return }
            Self.set(characteristic, .int(on ? 1 : 0))
        }
        guard property.isWritable else { return }
        let handle = handle
        characteristic.onWrite { value in try await handle.write(property, .bool(value.intValue == 1)) }
    }

    // MARK: Heaters and air conditioners

    func buildHeater() {
        category = .heater
        guard let heater = spec.service("heater") else { return buildGeneric() }
        let on = heater.property("on")
        guard let target = heater.property("target-temperature") else {
            // No target temperature: a Switch.
            let service = Service(.switch, name: name, isPrimary: true)
            bindActive(service, on: on, type: .on)
            primary = service
            return
        }
        let service = Service(.heaterCooler, name: name, optional: [
            Self.bounded(.heatingThresholdTemperature, target, defaultRange: 10...35, step: target.isRange ? target.step : 1), .temperatureDisplayUnits,
        ], extra: [
            Characteristic(.targetHeaterCoolerState.with(validValues: [1]), value: .int(1)),
        ], isPrimary: true)
        bindActive(service, on: on)
        let current = service.characteristic(.currentHeaterCoolerState)
        bind([on]) { values, _ in
            guard let on, let isOn = Self.bool(values[on.key]) else { return }
            Self.set(current, .int(isOn ? 2 : 1))
        }
        let handle = handle
        if let on, on.isWritable {
            service.characteristic(.targetHeaterCoolerState).onWrite { _ in try await handle.write(on, .bool(true)) }
        }
        service.characteristic(.temperatureDisplayUnits).value = .int(0)
        bindThreshold(service.characteristic(.heatingThresholdTemperature), target)
        bindCurrentTemperature(service, fallback: target)
        if let mode = heater.property("mode"), let swing = mode.value(described: "Fan swing"), let still = mode.value(described: "Fan not swing") {
            let characteristic = service.characteristic(adding: .swingMode)
            bind([mode]) { values, _ in
                guard let value = values[mode.key] else { return }
                Self.set(characteristic, .int(MiotSpec.sameValue(value, swing) ? 1 : 0))
            }
            if mode.isWritable { characteristic.onWrite { value in try await handle.write(mode, value.intValue == 1 ? swing : still) } }
        }
        bindChildLock(service)
        primary = service
        // A heater's fan: a Switch, on only while the heater is.
        if let fanOn = spec.property("fan", "on") {
            let fanSwitch = Service(.switch, name: serviceName("Fan"), subtype: subtype("fan-\(fanOn.siid)"))
            let characteristic = fanSwitch.characteristic(.on)
            bind([fanOn, on]) { values, _ in
                let heaterOn = on.flatMap { Self.bool(values[$0.key]) } ?? true
                Self.set(characteristic, .bool(heaterOn && Self.bool(values[fanOn.key]) == true))
            }
            if fanOn.isWritable { characteristic.onWrite { value in try await handle.write(fanOn, .bool(value.boolValue ?? false)) } }
            add(fanSwitch)
        }
    }

    func bindThreshold(_ characteristic: Characteristic, _ property: MiotSpec.Property) {
        bind([property]) { values, _ in
            guard let value = Self.celsius(values[property.key], property) else { return }
            Self.set(characteristic, .double(value))
        }
        guard property.isWritable else { return }
        let handle = handle
        characteristic.onWrite { value in
            guard let celsius = value.doubleValue else { return }
            let written = property.unit == "fahrenheit" ? celsius * 9 / 5 + 32 : celsius
            try await handle.write(property, .number(written), debounce: true)
        }
    }

    /// Current Temperature from the environment's temperature, else the target (homebridge-miot).
    func bindCurrentTemperature(_ service: Service, fallback: MiotSpec.Property?) {
        let characteristic = service.characteristic(.currentTemperature)
        let source = spec.property("environment", "temperature") ?? main?.property("temperature")
        if let source {
            bind([source]) { values, _ in
                guard let value = Self.celsius(values[source.key], source) else { return }
                Self.set(characteristic, .double(value))
            }
        } else if let fallback {
            bind([fallback]) { values, _ in
                guard let value = Self.celsius(values[fallback.key], fallback) else { return }
                Self.set(characteristic, .double(value))
            }
        }
    }

    func buildAirConditioner() {
        category = .airConditioner
        guard let conditioner = spec.service("air-conditioner") else { return buildGeneric() }
        let on = conditioner.property("on"), mode = conditioner.property("mode"), target = conditioner.property("target-temperature")
        // Auto 0, Heat 1, Cool 2: only those the mode lists.
        let targets: [(state: Int, value: JSONValue)] = [(0, "Auto"), (1, "Heat"), (2, "Cool")].compactMap { state, description in
            mode?.value(described: description).map { (state, $0) }
        }
        var optional: [CharacteristicType] = []
        if let target {
            optional.append(Self.bounded(.heatingThresholdTemperature, target, defaultRange: 10...35))
            optional.append(Self.bounded(.coolingThresholdTemperature, target, defaultRange: 10...35))
        }
        optional.append(.temperatureDisplayUnits)
        let validTargets = targets.isEmpty ? [0, 1, 2] : targets.map(\.state)
        let service = Service(.heaterCooler, name: name, optional: optional, extra: [
            Characteristic(.targetHeaterCoolerState.with(validValues: validTargets), value: .int(validTargets[0])),
        ], isPrimary: true)
        service.characteristic(.temperatureDisplayUnits).value = .int(0)
        bindActive(service, on: on)
        let current = service.characteristic(.currentHeaterCoolerState)
        let targetState = service.characteristic(.targetHeaterCoolerState)
        bind([on, mode]) { values, _ in
            let value = mode.flatMap { values[$0.key] }
            let state = value.flatMap { value in targets.first { MiotSpec.sameValue($0.value, value) }?.state }
            // Dry and Fan read as the last target.
            if let state { Self.set(targetState, .int(state)) }
            let isOn = on.flatMap { Self.bool(values[$0.key]) } ?? true
            Self.set(current, .int(!isOn ? 1 : state == 1 ? 2 : state == 2 ? 3 : 1))
        }
        let handle = handle
        if let mode, mode.isWritable {
            targetState.onWrite { value in
                if let wanted = targets.first(where: { $0.state == value.intValue })?.value { try await handle.write(mode, wanted) }
            }
        }
        if let target {
            bindThreshold(service.characteristic(.heatingThresholdTemperature), target)
            bindThreshold(service.characteristic(.coolingThresholdTemperature), target)
        }
        bindCurrentTemperature(service, fallback: target)
        if let control = spec.service("fan-control") {
            bindLevels(service, control.property("fan-level"))
            if let swing = control.property("vertical-swing") { bindSwing(service, swing) }
        }
        bindChildLock(service)
        primary = service
    }

    // MARK: Curtains

    func buildCurtain() {
        category = .windowCovering
        guard let curtain = main, let currentPosition = curtain.property("current-position") ?? curtain.property("target-position") else { return buildGeneric() }
        let targetPosition = curtain.property("target-position")
        let status = curtain.property("status"), motor = curtain.property("motor-control"), fault = curtain.property("fault")
        let service = Service(.windowCovering, name: name, optional: [.holdPosition, .obstructionDetected], isPrimary: true)
        let current = service.characteristic(.currentPosition), target = service.characteristic(.targetPosition)
        let state = service.characteristic(.positionState)
        bind([currentPosition, targetPosition, status]) { values, _ in
            if let value = Self.number(values[currentPosition.key]) { Self.set(current, .int(MiotConversions.percent(value, of: currentPosition))) }
            if let targetPosition, let value = Self.number(values[targetPosition.key]) { Self.set(target, .int(MiotConversions.percent(value, of: targetPosition))) }
            if let status, let value = values[status.key] {
                let opening = Self.isDescribed(value, "Opening", in: status), closing = Self.isDescribed(value, "Closing", in: status)
                Self.set(state, .int(opening ? 1 : closing ? 0 : 2))
            } else if status == nil, let now = current.value.intValue, let wanted = target.value.intValue {
                Self.set(state, .int(wanted > now ? 1 : wanted < now ? 0 : 2))
            }
        }
        let handle = handle
        if let targetPosition, targetPosition.isWritable {
            target.onWrite { value in
                try await handle.write(targetPosition, .number(MiotConversions.value(percent: value.doubleValue ?? 0, of: targetPosition)), debounce: true)
            }
        }
        if let motor, motor.isWritable, let stop = motor.value(described: "Pause") ?? motor.value(described: "Stop") {
            service.characteristic(.holdPosition).onWrite { value in
                if value.boolValue == true { try await handle.write(motor, stop) }
            }
        }
        let obstruction = service.characteristic(.obstructionDetected)
        obstruction.value = .bool(false)
        if let fault {
            bind([fault]) { values, _ in
                guard let value = Self.number(values[fault.key]) else { return }
                Self.set(obstruction, .bool(value != 0))
            }
        }
        primary = service
    }

    // MARK: Sensors

    func buildSensor() {
        category = .sensor
        guard let sensor = spec.service("temperature-humidity-sensor") else { return buildGeneric() }
        let battery = sensor.property("battery-level")
        if let temperature = sensor.property("temperature") {
            primary = temperatureSensor(temperature, name: name, subtype: nil, isPrimary: true, battery: battery)
        }
        if let humidity = sensor.property("relative-humidity") {
            let service = humiditySensor(humidity, name: primary == nil ? name : serviceName("Humidity"), subtype: primary == nil ? nil : subtype("\(sensor.urn.name)-\(sensor.iid)-relative-humidity"),
                                         isPrimary: primary == nil, battery: battery)
            if primary == nil { primary = service } else { add(service) }
        }
        if let battery {
            add(batteryService(level: battery, charging: nil, status: nil, subtype: subtype("\(sensor.urn.name)-\(sensor.iid)-battery"), chargeable: false))
        }
    }

    func temperatureSensor(_ property: MiotSpec.Property, name: String, subtype: String?, isPrimary: Bool, battery: MiotSpec.Property? = nil) -> Service {
        var optional: [CharacteristicType] = [Self.bounded(.currentTemperature, property, defaultRange: -270...100)]
        if battery != nil { optional.append(.statusLowBattery) }
        let service = Service(.temperatureSensor, name: name, subtype: subtype, optional: optional, isPrimary: isPrimary)
        let characteristic = service.characteristic(.currentTemperature)
        bind([property]) { values, _ in
            guard let value = Self.celsius(values[property.key], property) else { return }
            Self.set(characteristic, .double(value))
        }
        bindLowBattery(service, battery)
        return service
    }

    func humiditySensor(_ property: MiotSpec.Property, name: String, subtype: String?, isPrimary: Bool, battery: MiotSpec.Property? = nil) -> Service {
        var optional: [CharacteristicType] = [Self.bounded(.currentRelativeHumidity, property, defaultRange: 0...100)]
        if battery != nil { optional.append(.statusLowBattery) }
        let service = Service(.humiditySensor, name: name, subtype: subtype, optional: optional, isPrimary: isPrimary)
        let characteristic = service.characteristic(.currentRelativeHumidity)
        bind([property]) { values, _ in
            guard let value = Self.number(values[property.key]) else { return }
            Self.set(characteristic, .double(min(max(value, 0), 100)))
        }
        bindLowBattery(service, battery)
        return service
    }

    func bindLowBattery(_ service: Service, _ battery: MiotSpec.Property?) {
        guard let battery else { return }
        let characteristic = service.characteristic(adding: .statusLowBattery)
        bind([battery]) { values, _ in
            guard let level = Self.number(values[battery.key]) else { return }
            Self.set(characteristic, .int(MiotConversions.isLowBattery(level) ? 1 : 0))
        }
    }

    /// A Battery: level, charging state (7.3) and low battery at 20 % or less.
    func batteryService(level: MiotSpec.Property, charging: MiotSpec.Property?, status: MiotSpec.Property?, subtype: String?, chargeable: Bool = true) -> Service {
        let service = Service(.battery, name: serviceName("Battery"), subtype: subtype, optional: [.batteryLevel, .chargingState])
        let levelCharacteristic = service.characteristic(.batteryLevel), low = service.characteristic(.statusLowBattery)
        let chargingCharacteristic = service.characteristic(.chargingState)
        if !chargeable { chargingCharacteristic.value = .int(2) }
        bind([level, charging, status]) { values, _ in
            if let value = Self.number(values[level.key]) {
                Self.set(levelCharacteristic, .int(Int(saturating: value, in: 0...100) ?? 0))
                Self.set(low, .int(MiotConversions.isLowBattery(value) ? 1 : 0))
            }
            guard chargeable else { return }
            Self.set(chargingCharacteristic, .int(Self.chargingState(values, charging: charging, status: status)))
        }
        return service
    }

    /// `Charging` → 1; `Not Charging`, `Go Charging` → 0; `Not Chargeable` → 2; else a status `Charging` (or `Charging
    /// Completed`) → 1; nothing known → 2.
    static func chargingState(_ values: PropertyValues, charging: MiotSpec.Property?, status: MiotSpec.Property?) -> Int {
        if let charging, let value = values[charging.key] {
            if isDescribed(value, "Charging", in: charging) { return 1 }
            if isDescribed(value, "Not Chargeable", in: charging) { return 2 }
            if isDescribed(value, "Not Charging", in: charging) || isDescribed(value, "Go Charging", in: charging) { return 0 }
        }
        if let status, let value = values[status.key] {
            return isDescribed(value, "Charging", in: status) || isDescribed(value, "Charging Completed", in: status) ? 1 : 0
        }
        return 2
    }

    // MARK: Generic

    /// A device type without a primary of its own (7.3): a Switch named after the device on the main service's `on`.
    func buildGeneric() {
        category = .other
        if let on = main?.property("on"), main?.urn.name != "light" {
            let service = Service(.switch, name: name, isPrimary: true)
            bindActive(service, on: on, type: .on)
            category = .switch
            primary = service
        }
    }

    // MARK: Common services

    /// The lights, environment sensors, battery and filters every mapping adds (7.3).
    func buildCommon() {
        buildOtherLights()
        let primaryHasTemperature = primary?[.currentTemperature] != nil && deviceType != "temperature-humidity-sensor"
        let primaryHasHumidity = primary?[.currentRelativeHumidity] != nil
        let suppressed = options.suppressed
        let isSensorDevice = deviceType == "temperature-humidity-sensor"
        for environment in spec.services("environment") {
            if let temperature = environment.property("temperature"), !primaryHasTemperature, !isSensorDevice, !suppressed.contains("temperature"),
               kind != "outlet" || options.showTemperature {
                add(temperatureSensor(temperature, name: serviceName("Temperature"), subtype: subtype("\(environment.urn.name)-\(environment.iid)-temperature"), isPrimary: false))
            }
            if let humidity = environment.property("relative-humidity"), !primaryHasHumidity, !isSensorDevice, !suppressed.contains("relativeHumidity") {
                add(humiditySensor(humidity, name: serviceName("Humidity"), subtype: subtype("\(environment.urn.name)-\(environment.iid)-relative-humidity"), isPrimary: false))
            }
            if let pm25 = environment.property("pm2.5-density") {
                add(airQualitySensor(environment, pm25: pm25))
            }
            if let co2 = environment.property("co2-density") {
                add(carbonDioxideSensor(environment, co2: co2))
            }
            if let illumination = environment.property("illumination"), !suppressed.contains("illumination") {
                add(lightSensor(illumination, name: serviceName("Light Sensor"), subtype: subtype("\(environment.urn.name)-\(environment.iid)-illumination")))
            }
        }
        if deviceType != "vacuum", !isSensorDevice {
            for battery in spec.services("battery") {
                guard let level = battery.property("battery-level") else { continue }
                add(batteryService(level: level, charging: battery.property("charging-state"), status: main?.property("status"), subtype: subtype("\(battery.urn.name)-\(battery.iid)")))
            }
        }
        // A vacuum's consumables are its own (8.2).
        guard deviceType != "vacuum" else { return }
        for filter in spec.services("filter") {
            if let service = filterService(filter, life: filter.property("filter-life-level"), reset: filter.action("reset-filter-life"), name: "Filter") { add(service) }
        }
    }

    func airQualitySensor(_ environment: MiotSpec.Service, pm25: MiotSpec.Property) -> Service {
        let pm10 = environment.property("pm10-density")
        let voc = environment.property("tvoc-density") ?? environment.property("hcho-density")
        var optional: [CharacteristicType] = [.pm2_5Density]
        if pm10 != nil { optional.append(.pm10Density) }
        if voc != nil { optional.append(.vocDensity.with(minValue: 0, maxValue: 1000)) }
        let service = Service(.airQualitySensor, name: serviceName("Air Quality"), subtype: subtype("\(environment.urn.name)-\(environment.iid)-air-quality"), optional: optional)
        let quality = service.characteristic(.airQuality), density = service.characteristic(.pm2_5Density)
        let breakpoints = defaults.pm25Breakpoints
        bind([pm25]) { values, _ in
            guard let value = Self.number(values[pm25.key]) else { return }
            Self.set(quality, .int(MiotConversions.airQuality(pm25: value, breakpoints: breakpoints)))
            Self.set(density, .double(min(max(value, 0), 1000)))
        }
        if let pm10, let characteristic = service[.pm10Density] {
            bind([pm10]) { values, _ in
                guard let value = Self.number(values[pm10.key]) else { return }
                Self.set(characteristic, .double(min(max(value, 0), 1000)))
            }
        }
        if let voc, let characteristic = service[.vocDensity] {
            bind([voc]) { values, _ in
                guard var value = Self.number(values[voc.key]) else { return }
                if voc.unit == "mg/m3" { value *= 1000 }
                Self.set(characteristic, .double(min(max(value, 0), 1000)))
            }
        }
        return service
    }

    func carbonDioxideSensor(_ environment: MiotSpec.Service, co2: MiotSpec.Property) -> Service {
        let service = Service(.carbonDioxideSensor, name: serviceName("Carbon Dioxide"), subtype: subtype("\(environment.urn.name)-\(environment.iid)-co2"), optional: [.carbonDioxideLevel])
        let detected = service.characteristic(.carbonDioxideDetected), level = service.characteristic(.carbonDioxideLevel)
        let threshold = defaults.co2AbnormalThreshold
        bind([co2]) { values, _ in
            guard let value = Self.number(values[co2.key]) else { return }
            Self.set(detected, .int(value > threshold ? 1 : 0))
            Self.set(level, .double(min(max(value, 0), 100_000)))
        }
        return service
    }

    func lightSensor(_ property: MiotSpec.Property, name: String, subtype: String) -> Service {
        let service = Service(.lightSensor, name: name, subtype: subtype, extra: [
            Characteristic(.currentAmbientLightLevel.with(minValue: property.isRange ? property.lower ?? 0 : 0, maxValue: property.isRange ? property.upper ?? 100_000 : 100_000)),
        ])
        let characteristic = service.characteristic(.currentAmbientLightLevel)
        bind([property]) { values, _ in
            guard let value = Self.number(values[property.key]) else { return }
            Self.set(characteristic, .double(value))
        }
        return service
    }

    /// A Filter Maintenance: life level capped at 100, change at 5 % or less, Reset Filter Indication runs the reset.
    func filterService(_ filter: MiotSpec.Service, life: MiotSpec.Property?, reset: MiotSpec.Action?, name: String) -> Service? {
        guard let life else { return nil }
        var optional: [CharacteristicType] = [.filterLifeLevel]
        if reset != nil { optional.append(.resetFilterIndication) }
        let service = Service(.filterMaintenance, name: serviceName(name), subtype: subtype("\(filter.urn.name)-\(filter.iid)"), optional: optional)
        let level = service.characteristic(.filterLifeLevel), change = service.characteristic(.filterChangeIndication)
        bind([life]) { values, _ in
            guard let value = Self.number(values[life.key]) else { return }
            Self.set(level, .double(min(max(value, 0), 100)))
            Self.set(change, .int(MiotConversions.needsChange(filterLife: value) ? 1 : 0))
        }
        if let reset {
            let handle = handle
            service.characteristic(.resetFilterIndication).onWrite { _ in try await handle.run(reset) }
        }
        return service
    }
}
