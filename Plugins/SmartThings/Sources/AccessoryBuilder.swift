import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Sends a service's commands and shows what they set at once (docs/clean-room/SmartThings.md, 5.5).
struct Writer: Sendable {
    let box: StatusBox
    let env: BindingEnvironment

    typealias Set = [(component: String, capability: String, attribute: String, value: JSONValue)]

    func send(_ commands: [DeviceCommand], set values: Set = []) async throws {
        guard env.controllable else { throw HAPStatusError(.insufficientPrivileges) }
        try await env.send(commands, values.map { StatusBox.key($0.component, $0.capability, $0.attribute) })
        box.setOptimistic(values, at: env.now())
    }

    /// Waits a moment, then says whether this is still the last write for `key`: a slider's drag sends only where it
    /// ends, so it does not spend the 12 requests a minute SmartThings allows a device (section 6.1).
    func isLatest(_ key: String) async -> Bool { await env.sliders(key) }
}

/// Builds a device's accessory from its components' capabilities (section 7.2): device-level rules first (appliances,
/// a security system), then each component's combinations, single capabilities, and energy.
struct AccessoryBuilder {
    let device: SmartThingsDevice
    let status: DeviceStatus
    let settings: SmartThingsSettings
    let options: DeviceOptions
    let box: StatusBox
    let env: BindingEnvironment
    let context: PluginContext?
    let accessoryID: String
    let name: String

    var services: [Service] = []
    var primary: Service?
    var updaters: [@Sendable (DeviceStatus) -> Void] = []
    var eventHooks: [String: @Sendable (DeviceEvent, DeviceStatus) -> Void] = [:]
    var details: [@Sendable (DeviceStatus, Date) -> [DeviceDetail]] = []
    var adaptiveLighting: [AdaptiveLightingController] = []
    var meters: [@Sendable (DeviceStatus) -> Void] = []
    var kind: String?
    var category: AccessoryCategory = .other
    /// Capabilities a rule used, by component.
    var consumed: [String: Swift.Set<String>] = [:]
    /// Services that stay together when a person separates the accessory's Functions.
    var keptTogether: [Service] = []

    var writer: Writer { Writer(box: box, env: env) }

    init(device: SmartThingsDevice, status: DeviceStatus, settings: SmartThingsSettings, options: DeviceOptions, box: StatusBox,
         env: BindingEnvironment, context: PluginContext?, accessoryID: String, name: String) {
        self.device = device
        self.status = status
        self.settings = settings
        self.options = options
        self.box = box
        self.env = env
        self.context = context
        self.accessoryID = accessoryID
        self.name = name
    }

    // MARK: Services

    /// The name of a component's service: the device's for `main`, else the device's and the component's (section 7.1).
    func serviceName(_ component: String, _ suffix: String? = nil) -> String {
        var parts = [name]
        if component != "main" { parts.append(device.component(component)?.label.flatMap { $0.isEmpty || $0 == component ? nil : $0 } ?? component) }
        if let suffix { parts.append(suffix) }
        return parts.joined(separator: " ")
    }

    /// A service with the stable subtype `<component>/<role>`; the first one of `main` is the primary one.
    mutating func makeService(_ type: ServiceType, _ component: String, _ role: String, name: String? = nil, optional: [CharacteristicType] = [],
                              extra: [Characteristic] = [], kind: String? = nil, category: AccessoryCategory? = nil) -> Service {
        let isPrimary = primary == nil && component == "main" && type != .battery
        let service = Service(type, name: name ?? serviceName(component), subtype: "\(component)/\(role)", optional: optional, extra: extra, isPrimary: isPrimary)
        if isPrimary { primary = service }
        services.append(service)
        if let kind, self.kind == nil || isPrimary { self.kind = kind }
        if let category, self.category == .other || isPrimary { self.category = category }
        return service
    }

    mutating func consume(_ component: String, _ capabilities: [String]) {
        consumed[component, default: []].formUnion(capabilities)
    }

    func available(_ component: DeviceComponent) -> Swift.Set<String> {
        Swift.Set(component.capabilities).subtracting(consumed[component.id] ?? [])
    }

    mutating func update(_ body: @escaping @Sendable (DeviceStatus) -> Void) { updaters.append(body) }

    /// The components SmartThings reports disabled (`custom.disabledComponents`, section 7.5).
    var disabledComponents: Swift.Set<String> {
        let value = status.value("main", "custom.disabledComponents", "disabledComponents")
        let list = value?.arrayValue ?? value?["custom"]?["disabledComponents"]?["disabledComponents"]?.arrayValue ?? []
        return Swift.Set(list.compactMap(\.stringValue))
    }

    // MARK: The build

    mutating func build() {
        let disabled = disabledComponents
        let appliance = Appliance.kind(of: device, status: status)
        if let appliance { buildAppliance(appliance) }
        for component in device.components where component.has("securitySystem") && !disabled.contains(component.id) {
            securitySystem(component.id, has: component.capabilities)
        }
        // A remote's buttons are its components; `main`'s repeats the last press (section 7.3.11).
        let buttonComponents = device.components.filter { $0.id != "main" && $0.has("button") && !disabled.contains($0.id) }
        if !buttonComponents.isEmpty { consume("main", ["button"]) }
        for component in device.components where !disabled.contains(component.id) {
            combinations(component)
            singles(component, buttonIndex: buttonComponents.firstIndex { $0.id == component.id }.map { Self.buttonIndex(buttonComponents[$0].id, position: $0) })
        }
        if !buttonComponents.isEmpty {
            let label = Service(.serviceLabel, subtype: "main/serviceLabel")
            label.characteristic(.serviceLabelNamespace).value = .int(HAPConstants.ServiceLabelNamespace.arabicNumerals)
            services.append(label)
        }
        if appliance == nil || appliance == .washer || appliance == .dryer || appliance == .dishwasher { energy() }
        if let primary {
            primary.linked = services.filter { $0 !== primary && $0.type != .serviceLabel && $0.type != .battery }
        }
    }

    static func buttonIndex(_ component: String, position: Int) -> Int {
        let digits = component.filter(\.isWholeNumber)
        return Int(digits).flatMap { $0 > 0 ? $0 : nil } ?? position + 1
    }

    // MARK: Combinations (section 7.2, C1 to C12)

    mutating func combinations(_ component: DeviceComponent) {
        var caps = available(component)
        func has(_ list: String...) -> Bool { list.allSatisfy(caps.contains) }
        let id = component.id
        if has("switch", "airConditionerMode", "airConditionerFanMode", "thermostatCoolingSetpoint", "temperatureMeasurement") {
            airConditioner(id, caps: caps)
            consume(id, ["switch", "airConditionerMode", "airConditionerFanMode", "thermostatCoolingSetpoint", "temperatureMeasurement",
                         "fanOscillationMode", "relativeHumidityMeasurement", "custom.airConditionerOptionalMode"])
            caps = available(component)
        }
        let purifierExtras = ["custom.filterState", "custom.hepaFilter", "filterState", "airQualitySensor", "dustSensor", "fineDustSensor", "veryFineDustSensor", "odorSensor"]
        if has("switch", "airConditionerFanMode") || has("switch", "airPurifierFanMode") {
            let c2b = !has("airConditionerFanMode")
            airPurifier(id, caps: caps, purifierFanMode: c2b)
            consume(id, ["switch", c2b ? "airPurifierFanMode" : "airConditionerFanMode"] + purifierExtras)
            caps = available(component)
        }
        if has("switch", "fanSpeed", "switchLevel") {
            fan(id, speed: .level)
            consume(id, ["switch", "fanSpeed", "switchLevel"])
            caps = available(component)
        } else if has("switch", "fanSpeedPercent") {
            fan(id, speed: .percent)
            consume(id, ["switch", "fanSpeedPercent", "fanSpeed"])
            caps = available(component)
        } else if has("switch", "fanSpeed") {
            fan(id, speed: .steps)
            consume(id, ["switch", "fanSpeed"])
            caps = available(component)
        }
        if caps.contains("switch"), !caps.isDisjoint(with: ["switchLevel", "colorControl", "colorTemperature"]) {
            light(id, level: caps.contains("switchLevel"), color: caps.contains("colorControl"), temperature: caps.contains("colorTemperature"))
            consume(id, ["switch", "switchLevel", "colorControl", "colorTemperature"])
            caps = available(component)
        }
        if has("switch", "valve") {
            valve(id)
            consume(id, ["switch", "valve"])
            caps = available(component)
        }
        if has("temperatureMeasurement", "thermostatMode", "thermostatHeatingSetpoint", "thermostatCoolingSetpoint") {
            thermostat(id, variant: .both, caps: caps)
            consume(id, ["temperatureMeasurement", "thermostatMode", "thermostatHeatingSetpoint", "thermostatCoolingSetpoint", "thermostatOperatingState", "thermostatFanMode"])
            caps = available(component)
        } else if has("temperatureMeasurement", "thermostatHeatingSetpoint") {
            thermostat(id, variant: .heating, caps: caps)
            consume(id, ["temperatureMeasurement", "thermostatHeatingSetpoint", "thermostatMode", "thermostatOperatingState"])
            caps = available(component)
        } else if has("temperatureMeasurement", "thermostatMode", "temperatureSetpoint") {
            thermostat(id, variant: .single, caps: caps)
            consume(id, ["temperatureMeasurement", "thermostatMode", "temperatureSetpoint", "switch", "thermostatOperatingState"])
            caps = available(component)
        }
        if has("windowShade", "windowShadeLevel") {
            windowCovering(id, level: .shadeLevel, shade: true, caps: caps)
            consume(id, ["windowShade", "windowShadeLevel", "windowShadePreset", "windowShadeTiltLevel"])
        } else if has("windowShade", "switchLevel") {
            windowCovering(id, level: .switchLevel, shade: true, caps: caps)
            consume(id, ["windowShade", "switchLevel", "windowShadePreset", "windowShadeTiltLevel"])
        }
    }

    // MARK: Single capabilities (section 7.2, 3)

    mutating func singles(_ component: DeviceComponent, buttonIndex: Int?) {
        let id = component.id
        var caps = available(component)
        func take(_ capability: String) -> Bool {
            guard caps.contains(capability) else { return false }
            caps.remove(capability)
            consume(id, [capability])
            return true
        }
        if take("doorControl") { garageDoor(id) }
        if take("lock") { lock(id) }
        if take("switch") { plainSwitch(id, component: component) }
        if take("windowShadeLevel") { windowCovering(id, level: .shadeLevel, shade: false, caps: caps) }
        if take("windowShade") { windowCovering(id, level: .none, shade: true, caps: caps) }
        if take("valve") { valve(id) }
        for sensor in Sensor.all where take(sensor.capability) { self.sensor(id, sensor) }
        if take("button") { button(id, index: buttonIndex) }
        if take("samsungce.airConditionerLighting"), options.displayLight { displayLight(id) }
        if id == "main", settings.exposeZigbangSmartDoorlock, take("absoluteweather46907.lockstaterelease") { zigbangLock(id) }
        if take("battery") { battery(id) }
    }
}

// MARK: Device Kinds (section 7.7)

enum DeviceKind {
    static let all = [
        "light", "switch", "outlet", "fan", "thermostat", "airConditioner", "airPurifier", "lock", "garageDoor", "windowCovering", "valve", "sensor",
        "button", "securitySystem", "television", "washer", "dryer", "dishwasher", "oven", "refrigerator", "robotVacuum", "scene", "unsupported",
    ]
}
