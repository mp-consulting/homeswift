import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

// MIoT robot vacuums (docs/clean-room/XiaomiMiot.md section 8.2, in the Roborock plugin's shape, 8.4) and the extra
// controls a device's Plugin Accessory Settings turn on (2.3, 7.8). Nothing extra is in HomeKit unless turned on.
extension MiotAccessoryBuilder {
    // MARK: Vacuums

    func buildVacuum() {
        category = .other
        guard let vacuum = spec.service("vacuum") else { return buildGeneric() }
        let status = vacuum.property("status"), fault = vacuum.property("fault")
        let batteryService = spec.service("battery")
        var linked: [Service] = []
        if let level = batteryService?.property("battery-level") {
            let battery = Service(.battery, optional: [.batteryLevel, .chargingState])
            let levelCharacteristic = battery.characteristic(.batteryLevel), low = battery.characteristic(.statusLowBattery)
            let charging = battery.characteristic(.chargingState)
            let chargingState = batteryService?.property("charging-state")
            bind([level, chargingState, status]) { values, _ in
                if let value = Self.number(values[level.key]) {
                    Self.set(levelCharacteristic, .int(Int(saturating: value, in: 0...100) ?? 0))
                    Self.set(low, .int(MiotConversions.isLowBattery(value) ? 1 : 0))
                }
                if chargingState.map({ values[$0.key] != nil }) ?? false || status.map({ values[$0.key] != nil }) ?? false {
                    Self.set(charging, .int(Self.chargingState(values, charging: chargingState, status: status)))
                }
            }
            linked.append(battery)
        }
        // One Filter Maintenance per consumable the spec has, named by its service.
        for filter in spec.services("filter") {
            if let service = filterService(filter, life: filter.property("filter-life-level"), reset: filter.action("reset-filter-life"),
                                           name: filter.description.isEmpty ? "Filter" : filter.description) { linked.append(service) }
        }
        for brush in spec.services("brush-cleaner") {
            if let service = filterService(brush, life: brush.property("brush-life-level"), reset: brush.action("reset-brush-life"),
                                           name: brush.description.isEmpty ? "Brush" : brush.description) { linked.append(service) }
        }
        let fan = Service(.fanv2, name: name, extra: [Characteristic(.statusFault, value: .int(0)), Characteristic(.statusActive, value: .bool(true))], isPrimary: true)
        // A Robotic Vacuum Cleaner over Matter, its battery the Battery beside it.
        fan.standsFor = .cleaningRobot
        let active = fan.characteristic(.active), faultCharacteristic = fan.characteristic(.statusFault)
        bind([status, fault]) { values, _ in
            if let status, let value = values[status.key] {
                let cleaning = ["Sweeping", "Mopping", "Sweeping and Mopping"].contains { Self.isDescribed(value, $0, in: status) }
                Self.set(active, .int(cleaning ? 1 : 0))
            }
            let faulty = (fault.flatMap { Self.number(values[$0.key]) } ?? 0) > 0 || Self.isDescribed(status.flatMap { values[$0.key] }, "Error", in: status)
            Self.set(faultCharacteristic, .int(faulty ? 1 : 0))
        }
        let handle = handle
        let start = vacuum.action("start-sweep")
        // Stopping only pauses the robot: off sends it to its dock.
        let dock = batteryService?.action("start-charge") ?? vacuum.action("start-charge")
        active.onWrite { value in
            if value.intValue == 1 {
                if let start { try await handle.run(start) }
            } else if let dock {
                try await handle.run(dock)
            }
        }
        statusActive.append(fan)
        onIdentify = vacuumIdentify()
        primary = fan
        self.linked = linked + self.linked
    }

    /// `identify:identify`, else the vendor `find-vacuum` or `audio:position`, else the alarm set on, else `find_me`.
    private func vacuumIdentify() -> @Sendable () async throws -> Void {
        let handle = handle
        if let action = spec.service("identify")?.action("identify") ?? spec.service("device-information")?.action("identify") {
            return { try await handle.run(action) }
        }
        let vendor = spec.services.lazy.flatMap(\.actions).first { $0.urn.name == "find-vacuum" }
            ?? spec.services.first { $0.urn.name == "audio" }?.actions.first { $0.urn.name == "position" }
        if let vendor { return { try await handle.run(vendor) } }
        if let alarm = spec.property("alarm", "alarm"), alarm.isWritable { return { try await handle.write(alarm, .bool(true)) } }
        return { _ = try await handle.raw("find_me", []) }
    }

    // MARK: Extra controls

    /// A control reads off while its link does not hold: a bool that must be true, or a property that must have a value.
    struct Link: Sendable {
        var property: MiotSpec.Property
        var value: JSONValue?

        func holds(_ values: PropertyValues) -> Bool {
            guard let current = values[property.key] else { return false }
            if let value { return MiotSpec.sameValue(current, value) }
            return MiotAccessoryBuilder.bool(current) == true
        }
    }

    func buildExtraControls() {
        let mainOn = main?.property("on")
        let onLink = mainOn.map { Link(property: $0, value: nil) }
        if options.buzzerControl, let alarm = spec.property("alarm", "alarm") {
            boolSwitch(alarm, name: "Buzzer")
        }
        if options.ledControl, let light = spec.service("indicator-light") {
            if let on = light.property("on") {
                boolSwitch(on, name: "Led")
            } else if let property = light.property("brightness") ?? light.property("indicator-light") {
                rangeOrList(property, name: "Led")
            }
        }
        if options.modeControl, let mode = main?.property("mode") {
            valueSwitches(mode, name: "Mode", link: onLink)
        }
        if options.screenControl, let screen = spec.service("screen") {
            if let on = screen.property("on") {
                boolSwitch(on, name: "Screen")
            } else if let brightness = screen.property("brightness") {
                rangeOrList(brightness, name: "Screen")
            }
        }
        if options.fanLevelControl, let level = main?.property("fan-level") ?? spec.service("fan-control")?.property("fan-level") {
            // An air purifier's levels apply in its Favorite mode only.
            let favorite = deviceType == "air-purifier" ? main?.property("mode").flatMap { mode in mode.value(described: "Favorite").map { Link(property: mode, value: $0) } } : nil
            valueSwitches(level, name: "Fan Level", link: favorite)
        }
        if options.swingControl {
            let swingService = main?.property("horizontal-swing") != nil ? main : spec.service("fan-control")
            if let swing = swingService?.property("horizontal-swing") { boolSwitch(swing, name: "Horizontal Swing") }
            if let swing = main?.property("vertical-swing") ?? spec.service("fan-control")?.property("vertical-swing") { boolSwitch(swing, name: "Vertical Swing") }
        }
        if options.moveControl {
            if let move = spec.anyProperty("swing-step-move"), move.isWritable {
                statelessWrite(move, value: "left", name: "Move left", suffix: "left")
                statelessWrite(move, value: "right", name: "Move right", suffix: "right")
            }
            if let move = spec.anyProperty("v-swing-step-move"), move.isWritable {
                statelessWrite(move, value: "up", name: "Move up", suffix: "up")
                statelessWrite(move, value: "down", name: "Move down", suffix: "down")
            }
        }
        if options.ioniserControl, let anion = main?.property("anion") ?? spec.services.lazy.compactMap({ $0.property("anion") }).first {
            boolSwitch(anion, name: "Ioniser", link: onLink)
        }
        if options.offDelayControl, let delay = main?.property("off-delay") ?? spec.property("countdown", "countdown-time") ?? main?.property("off-delay-time") {
            // Only with a unit of time (15.7): the thresholds to guess one are not established.
            if delay.isBool {
                boolSwitch(delay, name: "Off delay")
            } else if ["seconds", "minutes", "hours"].contains(delay.unit ?? ""), delay.isRange {
                rangeControl(delay, name: "Off delay", asFan: false)
            } else {
                logger.debug("No off delay control for \(model): its \(delay.name) has no unit of time")
            }
        }
        if options.motorControl, let motor = main?.property("motor-control") {
            valueSwitches(motor, name: "Motor Control")
        }
        if let angles = options.angleButtons("horizontalAngleButtons"), let angle = main?.property("horizontal-angle") {
            angleButtons(angle, angles: angles, name: "Horizontal Angle", swing: main?.property("horizontal-swing"))
        }
        if let angles = options.angleButtons("verticalAngleButtons"), let angle = main?.property("vertical-angle") {
            angleButtons(angle, angles: angles, name: "Vertical Angle", swing: main?.property("vertical-swing"))
        }
        actionButtons()
        methodButtons()
        propertyControls()
        propertyMonitors()
    }

    /// A Switch on a bool property.
    func boolSwitch(_ property: MiotSpec.Property, name: String, link: Link? = nil) {
        guard property.isReadable || property.isWritable else { return }
        let service = Service(.switch, name: serviceName(name), subtype: subtype("ctl-\(property.siid)-\(property.iid)"))
        let on = service.characteristic(.on)
        bind([property, link?.property]) { values, _ in
            guard let value = Self.bool(values[property.key]) else { return }
            Self.set(on, .bool(value && (link?.holds(values) ?? true)))
        }
        let handle = handle
        if property.isWritable {
            on.onWrite { value in
                let wanted = value.boolValue ?? false
                if wanted, let link, link.value == nil, link.property.isWritable { try await handle.write(link.property, .bool(true)) }
                try await handle.write(property, .bool(wanted))
            }
        }
        add(service)
    }

    /// A range → a Lightbulb slider; a value list → a switch per value.
    func rangeOrList(_ property: MiotSpec.Property, name: String) {
        if property.isList {
            valueSwitches(property, name: name)
        } else if property.isRange {
            rangeControl(property, name: name, asFan: false)
        } else if property.isBool {
            boolSwitch(property, name: name)
        }
    }

    /// One switch per value of a list (7.2): `<name> - <description>`. Stateful (on while the property has the value),
    /// stateless for a write-only property.
    func valueSwitches(_ property: MiotSpec.Property, name: String, link: Link? = nil) {
        for entry in property.values ?? [] {
            let label = "\(name) - \(entry.description.isEmpty ? entry.value.text() : entry.description)"
            valueSwitch(property, value: entry.value, name: label, link: link)
        }
    }

    func valueSwitch(_ property: MiotSpec.Property, value: JSONValue, name: String, link: Link? = nil, also: (@Sendable () async throws -> Void)? = nil) {
        guard property.isWritable else { return }
        let suffix = Self.subtypeValue(value)
        let service = Service(.switch, name: serviceName(name), subtype: subtype("ctl-\(property.siid)-\(property.iid)-\(suffix)"))
        let on = service.characteristic(.on)
        on.value = .bool(false)
        let handle = handle, reset = timings.switchReset
        guard property.isReadable else {
            // Write-only (a curtain's motor control): stateless.
            on.onWrite { [weak on] wanted in
                guard wanted.boolValue == true else { return }
                try await handle.write(property, value)
                Task { try? await Task.sleep(for: reset); on?.value = .bool(false) }
            }
            add(service)
            return
        }
        bind([property, link?.property]) { values, _ in
            guard let current = values[property.key] else { return }
            Self.set(on, .bool(MiotSpec.sameValue(current, value) && (link?.holds(values) ?? true)))
        }
        on.onWrite { [weak on] wanted in
            if wanted.boolValue == true {
                if let link, link.property.isWritable, !(link.holds(await Self.values(handle, [link.property]))) {
                    try await handle.write(link.property, link.value ?? .bool(true))
                }
                try await also?()
                try await handle.write(property, value)
            } else {
                // A value is chosen by turning another on: this one comes back while the property still has it.
                Task {
                    try? await Task.sleep(for: reset)
                    let current = await handle.value(property.key)
                    let linkHolds = link == nil ? true : link!.holds(await Self.values(handle, [link!.property]))
                    on?.value = .bool(current.map { MiotSpec.sameValue($0, value) } == true && linkHolds)
                }
            }
        }
        add(service)
    }

    static func values(_ handle: DeviceHandle, _ properties: [MiotSpec.Property]) async -> PropertyValues {
        var values: PropertyValues = [:]
        for property in properties { values[property.key] = await handle.value(property.key) }
        return values
    }

    /// A value in a subtype: `1`, `true`, `left`.
    static func subtypeValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text.lowercased().filter { $0.isLetter || $0.isNumber }
        default: value.text()
        }
    }

    /// A stateless switch that writes `value` and turns itself off.
    func statelessWrite(_ property: MiotSpec.Property, value: JSONValue, name: String, suffix: String) {
        let service = Service(.switch, name: serviceName(name), subtype: subtype("ctl-\(property.siid)-\(property.iid)-\(suffix)"))
        let on = service.characteristic(.on)
        on.value = .bool(false)
        let handle = handle, reset = timings.switchReset
        on.onWrite { [weak on] wanted in
            guard wanted.boolValue == true else { return }
            try await handle.write(property, value)
            Task { try? await Task.sleep(for: reset); on?.value = .bool(false) }
        }
        add(service)
    }

    /// A range as a Lightbulb (or a Fan v2): its percentage the range's position; on is a value above the minimum, off
    /// writes the minimum, on writes the value it had before off or the maximum.
    func rangeControl(_ property: MiotSpec.Property, name: String, asFan: Bool, subtypeBase: String? = nil) {
        guard property.isWritable, let lower = property.lower, let upper = property.upper else { return }
        let base = subtypeBase ?? "ctl-\(property.siid)-\(property.iid)"
        let service = asFan
            ? Service(.fanv2, name: serviceName(name), subtype: subtype(base), optional: [.rotationSpeed])
            : Service(.lightbulb, name: serviceName(name), subtype: subtype(base), optional: [.brightness])
        let power = service.characteristic(asFan ? .active : .on)
        let level = service.characteristic(asFan ? .rotationSpeed : .brightness)
        let lastOn = NIOLockedValueBox<Double?>(nil)
        bind([property]) { values, _ in
            guard let value = Self.number(values[property.key]) else { return }
            if value > lower { lastOn.withLockedValue { $0 = value } }
            let isOn = value > lower
            Self.set(power, asFan ? .int(isOn ? 1 : 0) : .bool(isOn))
            let percent = MiotConversions.percent(value, of: property)
            Self.set(level, asFan ? .double(Double(percent)) : .int(percent))
        }
        let handle = handle
        power.onWrite { value in
            let on = asFan ? value.intValue == 1 : value.boolValue == true
            let target = on ? (lastOn.withLockedValue { $0 } ?? upper) : lower
            try await handle.write(property, .number(target))
        }
        level.onWrite { value in
            guard let percent = value.doubleValue else { return }
            try await handle.write(property, .number(MiotConversions.value(percent: percent, of: property)), debounce: true)
        }
        add(service)
    }

    /// Stateful switches that set an angle (and turn the swing on).
    func angleButtons(_ property: MiotSpec.Property, angles: [Int], name: String, swing: MiotSpec.Property?) {
        var chosen = angles
        if chosen.isEmpty {
            // `true`: the angles the spec lists, else the ends of its range.
            chosen = (property.values ?? []).compactMap { $0.value.intValue }
            if chosen.isEmpty, let lower = property.lower.flatMap({ Int(exactly: $0) }), let upper = property.upper.flatMap({ Int(exactly: $0) }) {
                chosen = lower == upper ? [lower] : [lower, upper]
            }
        }
        let handle = handle
        var turnSwing: (@Sendable () async throws -> Void)?
        if let swing, swing.isWritable {
            turnSwing = { try await handle.write(swing, .bool(true)) }
        }
        for angle in chosen {
            valueSwitch(property, value: .number(Double(angle)), name: "\(name) \(angle)", also: turnSwing)
        }
    }

    // MARK: actionButtons, methodButtons

    func actionButtons() {
        var entries: [(reference: String, name: String?, params: [JSONValue])] = []
        switch options.actionButtons {
        case .bool(true)?:
            entries = spec.services.filter { $0.urn.name != "device-information" }.flatMap(\.actions).map { ($0.name, nil, []) }
        case .array(let items)?:
            for item in items {
                if let reference = item.stringValue ?? item.intValue.map(String.init) {
                    entries.append((reference, nil, []))
                } else if let reference = item["action"]?.stringValue {
                    entries.append((reference, item["name"]?.stringValue, item["params"]?.arrayValue ?? []))
                }
            }
        default:
            return
        }
        let handle = handle, reset = timings.switchReset
        for (index, entry) in entries.enumerated() {
            guard let action = spec.action(named: entry.reference) else {
                logger.warning("actionButtons: \(model) has no action \(entry.reference); skipped")
                continue
            }
            let label = entry.name ?? MiotConversions.friendlyName(action.name)
            let service = Service(.switch, name: serviceName(label), subtype: subtype("action-\(action.siid)-\(action.iid)-\(index)"))
            let on = service.characteristic(.on)
            on.value = .bool(false)
            let params = entry.params
            on.onWrite { [weak on] value in
                guard value.boolValue == true else { return }
                try await handle.run(action, params)
                Task { try? await Task.sleep(for: reset); on?.value = .bool(false) }
            }
            add(service)
        }
    }

    func methodButtons() {
        for service in Self.methodButtons(options: options, handle: handle, timings: timings, logger: logger, name: { self.serviceName($0) }) { add(service) }
    }

    /// Stateless switches sending raw miIO methods (2.3), the result logged at info; for MIoT and legacy devices alike.
    static func methodButtons(options: DeviceOptions, handle: DeviceHandle, timings: AccessoryTimings, logger: Logger,
                              name: (String) -> String) -> [Service] {
        let reset = timings.switchReset
        var services: [Service] = []
        for (index, item) in options.methodButtons.enumerated() {
            guard let method = item.stringValue ?? item["method"]?.stringValue, !method.isEmpty else { continue }
            let label = item["name"]?.stringValue ?? MiotConversions.friendlyName(method)
            let params = item["params"] ?? .array([])
            let service = Service(.switch, name: name(label), subtype: "method-\(index)")
            let on = service.characteristic(.on)
            on.value = .bool(false)
            on.onWrite { [weak on] value in
                guard value.boolValue == true else { return }
                Task { try? await Task.sleep(for: reset); on?.value = .bool(false) }
                do {
                    let result = try await handle.raw(method, params)
                    logger.info("Method \(method) answered \(result.text())")
                } catch MiioError.unknownMethod {
                    logger.warning("Method \(method): the device does not know it (unknown_method)")
                } catch {
                    logger.warning("Method \(method) failed: \(error)")
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
            }
            services.append(service)
        }
        return services
    }

    // MARK: propertyControl

    func propertyControls() {
        for item in options.propertyControl {
            let reference = item.stringValue ?? item["property"]?.stringValue ?? item["property"]?.doubleValue.map { String($0) }
            guard let reference, let property = spec.property(named: reference) else {
                logger.warning("propertyControl: \(model) has no property \(item.stringValue ?? item["property"]?.text() ?? "?"); skipped")
                continue
            }
            guard property.isWritable else {
                logger.warning("propertyControl: \(property.name) of \(model) cannot be written; skipped")
                continue
            }
            let friendly = item["name"]?.stringValue ?? MiotConversions.friendlyName(property.name)
            let link = item["linkedProperty"]?.stringValue.flatMap { spec.property(named: $0) }.map { linked in
                Link(property: linked, value: item["linkedPropertyValue"].map { linked.coerce($0) })
            }
            if let fixed = item["value"], !fixed.isNull {
                let value = property.coerce(fixed)
                let label = item["name"]?.stringValue ?? "\(friendly) - \(property.description(of: value) ?? value.text())"
                valueSwitch(property, value: value, name: label, link: link)
            } else if property.isBool {
                boolSwitch(property, name: friendly, link: link)
            } else if property.isList {
                valueSwitches(property, name: friendly, link: link)
            } else if property.isRange {
                rangeControl(property, name: friendly, asFan: item["config"]?["type"]?.stringValue == "fan")
            } else {
                logger.warning("propertyControl: \(property.name) of \(model) has no value to set; skipped")
            }
        }
    }

    // MARK: propertyMonitor

    enum Comparison: String {
        case equal, less, greater, lessOrEqual, greaterOrEqual, contains

        init(_ text: String?) {
            switch text?.trimmingCharacters(in: .whitespaces) {
            case "less", "below", "<": self = .less
            case "greater", "above", ">": self = .greater
            case "lessOrEqual", "belowOrEqual", "<=": self = .lessOrEqual
            case "greaterOrEqual", "aboveOrEqual", ">=": self = .greaterOrEqual
            case "contains", "[]", "[]=": self = .contains
            default: self = .equal
            }
        }

        func holds(_ current: JSONValue, _ wanted: JSONValue) -> Bool {
            let a = MiotAccessoryBuilder.number(current), b = MiotAccessoryBuilder.number(wanted)
            switch self {
            case .equal: return MiotSpec.sameValue(current, wanted)
            case .less: return a != nil && b != nil && a! < b!
            case .greater: return a != nil && b != nil && a! > b!
            case .lessOrEqual: return a != nil && b != nil && a! <= b!
            case .greaterOrEqual: return a != nil && b != nil && a! >= b!
            case .contains: return (wanted.arrayValue ?? [wanted]).contains { MiotSpec.sameValue($0, current) }
            }
        }
    }

    func propertyMonitors() {
        let logger = logger
        for item in options.propertyMonitor {
            let reference = item.stringValue ?? item["property"]?.stringValue
            guard let reference, let property = spec.property(named: reference), property.isReadable else {
                logger.warning("propertyMonitor: \(model) has no readable property \(item.stringValue ?? item["property"]?.text() ?? "?"); skipped")
                continue
            }
            let friendly = item["name"]?.stringValue ?? MiotConversions.friendlyName(property.name)
            let link = item["linkedProperty"]?.stringValue.flatMap { spec.property(named: $0) }.map { linked in
                Link(property: linked, value: item["linkedPropertyValue"].map { linked.coerce($0) })
            }
            let fixed = item["value"].flatMap { $0.nonNull }
            let base = "monitor-\(property.siid)-\(property.iid)" + (fixed.map { "-\(Self.subtypeValue($0))" } ?? "")
            let service: Service
            if let fixed {
                let comparison = Comparison(item["valueOperator"]?.stringValue)
                service = Service(.occupancySensor, name: serviceName(friendly), subtype: subtype(base), optional: [.statusActive])
                let detected = service.characteristic(.occupancyDetected)
                let wanted = comparison == .contains ? fixed : property.coerce(fixed)
                bind([property, link?.property]) { values, _ in
                    guard let current = values[property.key] else { return }
                    Self.set(detected, .int(comparison.holds(current, wanted) ? 1 : 0))
                }
            } else if property.unit == "celsius" {
                service = Service(.temperatureSensor, name: serviceName(friendly), subtype: subtype(base),
                                  optional: [Self.bounded(.currentTemperature, property, defaultRange: -270...100), .statusActive])
                let characteristic = service.characteristic(.currentTemperature)
                bind([property, link?.property]) { values, _ in
                    guard let value = Self.number(values[property.key]) else { return }
                    Self.set(characteristic, .double(value))
                }
            } else {
                let lower = property.isRange ? property.lower ?? 0 : 0, upper = property.isRange ? property.upper ?? 100_000 : 100_000
                service = Service(.lightSensor, name: serviceName(friendly), subtype: subtype(base),
                                  optional: [.statusActive], extra: [Characteristic(.currentAmbientLightLevel.with(minValue: lower, maxValue: upper))])
                let characteristic = service.characteristic(.currentAmbientLightLevel)
                let isString = property.isString
                let previous = NIOLockedValueBox<String?>(nil)
                bind([property, link?.property]) { values, _ in
                    guard let current = values[property.key] else { return }
                    if isString {
                        let text = current.stringValue ?? current.text()
                        let changed = previous.withLockedValue { last in defer { last = text }; return last != nil && last != text }
                        if changed { logger.info("\(property.name) is now \(text)") }
                        return
                    }
                    guard let value = Self.number(current) else { return }
                    Self.set(characteristic, .double(min(max(value, lower), upper)))
                }
            }
            // Status Active: false while unreachable (the device sets it) or the link does not hold.
            let active = service.characteristic(.statusActive)
            active.value = .bool(true)
            if let link {
                bind([link.property]) { values, _ in Self.set(active, .bool(link.holds(values))) }
            }
            statusActive.append(service)
            add(service)
        }
    }
}
