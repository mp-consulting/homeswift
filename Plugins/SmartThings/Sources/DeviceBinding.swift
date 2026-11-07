import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A device's last known status, shared by its services' handlers: what reconciliations and events bring, and what the
/// bridge's own writes set until SmartThings confirms them (docs/clean-room/SmartThings.md, 5.5).
final class StatusBox: Sendable {
    private struct State {
        var status: DeviceStatus
        /// When the bridge last wrote an attribute (`component/capability/attribute`): an older status leaves it alone.
        var written: [String: Date] = [:]
        /// When an event last came for an attribute: a command's follow-up read is skipped when one came.
        var evented: [String: Date] = [:]
        /// When the bridge last sent a command to the device (`Writer.send`).
        var lastWrite: Date?
    }

    private let state: NIOLockedValueBox<State>
    /// Runs the device's updaters; set by its binding, which the box does not keep.
    let onChange = NIOLockedValueBox<(@Sendable (DeviceStatus) -> Void)?>(nil)

    init(_ status: DeviceStatus) {
        state = NIOLockedValueBox(State(status: status))
    }

    var status: DeviceStatus { state.withLockedValue { $0.status } }

    static func key(_ component: String, _ capability: String, _ attribute: String) -> String { "\(component)/\(capability)/\(attribute)" }

    /// A whole status read at `requestedAt`: each attribute replaces the known one unless the bridge wrote it after. The
    /// updaters run when a value, a unit or the health changed, and after any read within two minutes of a write (a
    /// target held while the device moved settles then).
    func merge(_ fresh: DeviceStatus, requestedAt: Date) {
        let changed = state.withLockedValue { state -> DeviceStatus? in
            let expiry = requestedAt.addingTimeInterval(-120)
            state.written = state.written.filter { $0.value > expiry }
            var changed = state.lastWrite.map { $0 > expiry } ?? false
            for (component, capabilities) in fresh.components {
                for (capability, attributes) in capabilities {
                    for (name, value) in attributes {
                        let key = Self.key(component, capability, name)
                        let time = value.timestamp ?? requestedAt
                        if let written = state.written[key] {
                            if time < written { continue }
                            state.written[key] = nil
                        }
                        let known = state.status.attribute(component, capability, name)
                        // A read older than an event already applied leaves the event's value (section 5.5).
                        if let knownTime = known?.timestamp, state.evented[key] != nil, time < knownTime { continue }
                        // A null keeps the last value (section 7.3.8).
                        if value.value.isNull, known?.value.isNull == false { continue }
                        var merged = value
                        // A value without its unit keeps the one known (an event's temperature, section 5.1).
                        if merged.unit == nil { merged.unit = known?.unit }
                        guard merged != known else { continue }
                        // A new timestamp alone is kept (a poll notices button presses by it) without running the updaters.
                        if merged.value != known?.value || merged.unit != known?.unit { changed = true }
                        state.status.set(component, capability, name, merged)
                    }
                }
            }
            if let health = fresh.health, health != state.status.health {
                state.status.health = health
                changed = true
            }
            return changed ? state.status : nil
        }
        if let changed { notify(changed) }
    }

    /// An event: the attribute's new value, its unit kept from the last status read.
    func apply(_ event: DeviceEvent, at now: Date) {
        let status = state.withLockedValue { state -> DeviceStatus in
            let key = Self.key(event.component, event.capability, event.attribute)
            let unit = state.status.attribute(event.component, event.capability, event.attribute)?.unit
            state.status.set(event.component, event.capability, event.attribute, AttributeValue(value: event.value, unit: unit, timestamp: event.time ?? now))
            state.written[key] = nil
            state.evented[key] = now
            // An event is the device answering: it is online, whatever the last health said (section 6.4).
            if state.status.health == "OFFLINE" { state.status.health = "ONLINE" }
            if state.evented.count > 512 { state.evented = state.evented.filter { now.timeIntervalSince($0.value) < 600 } }
            return state.status
        }
        notify(status)
    }

    func setHealth(_ health: String) {
        let status = state.withLockedValue { state -> DeviceStatus in
            state.status.health = health
            return state.status
        }
        notify(status)
    }

    /// What the bridge just commanded, shown until SmartThings says otherwise.
    func setOptimistic(_ values: [(component: String, capability: String, attribute: String, value: JSONValue)], at now: Date) {
        guard !values.isEmpty else { return }
        let status = state.withLockedValue { state -> DeviceStatus in
            for item in values {
                let unit = state.status.attribute(item.component, item.capability, item.attribute)?.unit
                state.status.set(item.component, item.capability, item.attribute, AttributeValue(value: item.value, unit: unit, timestamp: now))
                state.written[Self.key(item.component, item.capability, item.attribute)] = now
            }
            return state.status
        }
        notify(status)
    }

    /// Stamps a command about to go to the device; returns the stamp it replaced, for `unstampWrite`.
    func stampWrite(at date: Date) -> Date? {
        state.withLockedValue { state in
            defer { state.lastWrite = date }
            return state.lastWrite
        }
    }

    /// A command that failed: the stamp before it comes back, unless another write stamped since.
    func unstampWrite(_ date: Date, previous: Date?) {
        state.withLockedValue { state in if state.lastWrite == date { state.lastWrite = previous } }
    }

    /// Whether the bridge sent a command within `window` of `now`: what the device reports then may be its echo.
    func wroteRecently(within window: TimeInterval, now: Date) -> Bool {
        state.withLockedValue { $0.lastWrite.map { now.timeIntervalSince($0) < window } ?? false }
    }

    /// Whether an event came for any of these attributes since `date`.
    func eventCame(for keys: [String], since date: Date) -> Bool {
        state.withLockedValue { state in keys.contains { (state.evented[$0] ?? .distantPast) >= date } }
    }

    func notify() { notify(status) }

    private func notify(_ status: DeviceStatus) {
        onChange.withLockedValue { $0 }?(status)
    }
}

/// What a device's services need from the plugin: sending commands, the clock, the log.
struct BindingEnvironment: Sendable {
    var deviceID: String
    var timing: SmartThingsTiming
    var logger: Logger
    var now: @Sendable () -> Date
    /// Sends commands; throws `HAPStatusError` for HomeKit when SmartThings refuses or does not answer.
    var send: @Sendable (_ commands: [DeviceCommand], _ watched: [String]) async throws -> Void
    var controllable: Bool
    /// Coalesces each slider's writes (`AccessoryBuilder.onSlide`).
    var sliders: LatestCallGuard
}

/// An appliance value for the web page and the Assistant (section 8.9): a label and its value.
struct DeviceDetail: Sendable, Equatable {
    var label: String
    var value: String
}

/// A device's accessory and what keeps it in step with SmartThings.
final class DeviceBinding: Sendable {
    let device: SmartThingsDevice
    let accessory: Accessory
    let kind: String
    let box: StatusBox
    /// What the accessory was built from: a different one rebuilds it.
    let signature: String
    let isTelevision: Bool
    private let updaters: [@Sendable (DeviceStatus) -> Void]
    private let eventHooks: [String: @Sendable (DeviceEvent, DeviceStatus) -> Void]
    private let detailProviders: [@Sendable (DeviceStatus, Date) -> [DeviceDetail]]
    /// Kept with the light's services, which hold them weakly.
    let adaptiveLighting: [AdaptiveLightingController]
    let meters: [@Sendable (DeviceStatus) -> Void]

    init(device: SmartThingsDevice, accessory: Accessory, kind: String, box: StatusBox, signature: String, isTelevision: Bool,
         updaters: [@Sendable (DeviceStatus) -> Void], eventHooks: [String: @Sendable (DeviceEvent, DeviceStatus) -> Void],
         details: [@Sendable (DeviceStatus, Date) -> [DeviceDetail]], adaptiveLighting: [AdaptiveLightingController], meters: [@Sendable (DeviceStatus) -> Void]) {
        self.device = device
        self.accessory = accessory
        self.kind = kind
        self.box = box
        self.signature = signature
        self.isTelevision = isTelevision
        self.updaters = updaters
        self.eventHooks = eventHooks
        detailProviders = details
        self.adaptiveLighting = adaptiveLighting
        self.meters = meters
        box.onChange.withLockedValue { $0 = { [weak self] status in self?.show(status) } }
    }

    /// Sets every characteristic from the status; only those that change reach HomeKit.
    func show(_ status: DeviceStatus) {
        // A TV fully off reports OFFLINE: it reads Active 0, not No Response (section 9.2).
        accessory.isUnavailable = Self.isOffline(status) && !isTelevision
        for update in updaters { update(status) }
        for meter in meters { meter(status) }
    }

    /// Offline by its health, or by the health attributes some drivers report (section 6.4); UNKNOWN is not offline.
    static func isOffline(_ status: DeviceStatus) -> Bool {
        if status.health == "OFFLINE" { return true }
        for (capability, attribute) in [("healthCheck", "healthStatus"), ("healthCheck", "DeviceWatch-DeviceStatus")] {
            if status.string("main", capability, attribute)?.lowercased() == "offline" { return true }
        }
        return false
    }

    /// An event: hooks that act on the event itself (a button press) first, then the status.
    func apply(_ event: DeviceEvent, now: Date) {
        let key = StatusBox.key(event.component, event.capability, event.attribute)
        if let hook = eventHooks[key] {
            hook(event, box.status)
            // A press repeats the value: it changes nothing else.
            if !event.stateChange { return }
        }
        box.apply(event, at: now)
    }

    var hasEventHooks: Bool { !eventHooks.isEmpty }

    /// The button presses a poll noticed (their attribute's timestamp moved), for an instance without events.
    func pollPresses(previous: DeviceStatus, current: DeviceStatus) {
        for key in eventHooks.keys {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3, let now = current.attribute(parts[0], parts[1], parts[2]),
                  let before = previous.attribute(parts[0], parts[1], parts[2]), let time = now.timestamp, time != before.timestamp else { continue }
            eventHooks[key]?(DeviceEvent(deviceID: device.deviceID, component: parts[0], capability: parts[1], attribute: parts[2], value: now.value), current)
        }
    }

    func details(_ status: DeviceStatus, now: Date) -> [DeviceDetail] { detailProviders.flatMap { $0(status, now) } }
}

// MARK: Conversions (section 7.4)

enum Convert {
    /// A temperature in °C from the device's unit.
    static func celsius(_ value: Double, unit: String?) -> Double {
        unit?.uppercased() == "F" ? (value - 32) * 5 / 9 : value
    }

    /// A HomeKit temperature in the device's unit: whole degrees in Fahrenheit.
    static func deviceTemperature(_ celsius: Double, unit: String?) -> JSONValue {
        if unit?.uppercased() == "F" { return .number((celsius * 9 / 5 + 32).rounded()) }
        let rounded = (celsius * 10).rounded() / 10
        return .number(rounded)
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(max(value, range.lowerBound), range.upperBound) }

    static func percent(_ value: Double?) -> Int? {
        value?.finite.flatMap { Int(saturating: $0.rounded(), in: 0...100) }
    }

    static func mireds(kelvin: Double) -> Int? {
        guard let kelvin = kelvin.finite, kelvin > 0 else { return nil }
        return Int(saturating: (1_000_000 / kelvin).rounded())
    }

    static func kelvin(mireds: Double) -> Int? {
        guard let mireds = mireds.finite, mireds > 0 else { return nil }
        return Int(saturating: (1_000_000 / mireds).rounded())
    }

    /// `true`/`false` as a JSON boolean or a string (section 7.4).
    static func flag(_ value: JSONValue?) -> Bool? {
        if let flag = value?.boolValue { return flag }
        guard let text = value?.stringValue?.lowercased() else { return nil }
        return text == "true" ? true : text == "false" ? false : nil
    }
}

extension Service {
    /// Sets a characteristic the service has, when the value is known.
    func set(_ type: CharacteristicType, _ value: HAPValue?) {
        guard let value, let characteristic = self[type] else { return }
        characteristic.value = value
    }
}
