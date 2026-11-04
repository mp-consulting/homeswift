import Foundation
import Homeswift
import HomeswiftPlugin

/// `fanv2s[]`: a Fanv2 with Active, Rotation Speed and Rotation Direction, and Lock Physical Controls, Target Fan State
/// and Swing Mode when the entry enables them. `state`, `speed` (HomeKit's 0–100), `rotationDirection`, `lockstate`,
/// `targetState` and `swingMode` set each its own characteristic; HomeKit's speed goes out times `speed_factor`.
final class FanAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    let factor: Double
    private let active: Characteristic
    private let speed: Characteristic
    /// The integer characteristics a parameter sets: rotation direction, and those the entry enables.
    private let integers: [(parameter: String, key: String, characteristic: Characteristic)]
    private let environment: KindEnvironment
    private var key: String { "http-webhook-\(id)" }
    private var speedKey: String { "http-webhook-speed-\(id)" }

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        factor = entry.number("speed_factor", default: 1)
        let lockControls = entry.flag("enableLockPhysicalControls", default: false)
        let targetState = entry.flag("enableTargetStateControls", default: false)
        let swingMode = entry.flag("enableSwingModeControls", default: false)
        var optional: [CharacteristicType] = [.rotationSpeed, .rotationDirection]
        if lockControls { optional.append(.lockPhysicalControls) }
        if targetState { optional.append(.targetFanState) }
        if swingMode { optional.append(.swingMode) }
        let service = Service(.fanv2, name: name, optional: optional, isPrimary: true)
        active = service.characteristic(.active)
        speed = service.characteristic(.rotationSpeed)
        accessory = Accessory(
            id: HTTPWebhooksPlugin.accessoryID(name: name), name: name, manufacturer: HTTPWebhooksPlugin.manufacturer,
            model: "HttpWebHookFanv2Accessory-\(name)", serialNumber: "HttpWebHookFanv2Accessory-\(id)", category: .fan, services: [service])

        var integers: [(parameter: String, key: String, characteristic: Characteristic)] = [("rotationDirection", "http-webhook-rotationdirection-\(id)", service.characteristic(.rotationDirection))]
        if lockControls { integers.append(("lockstate", "http-webhook-lockstate-\(id)", service.characteristic(.lockPhysicalControls))) }
        if targetState { integers.append(("targetState", "http-webhook-targetstate-\(id)", service.characteristic(.targetFanState))) }
        if swingMode { integers.append(("swingMode", "http-webhook-swingmode-\(id)", service.characteristic(.swingMode))) }
        self.integers = integers
        active.show(environment.store.bool(key) ? 1 : 0)
        speed.show(environment.store.number(speedKey, default: 100))
        for value in integers { value.characteristic.show(environment.store.number(value.key, default: 0)) }

        let (key, speedKey, factor) = (key, speedKey, factor)
        let coalesce = LatestCallGuard(delay: environment.timing.coalescing)
        let calls = (on: entry.call("on"), off: entry.call("off"), speed: entry.call("speed"))
        active.onWrite { [environment, name] value in
            let on = value.intValue == 1
            environment.logger.info("\(name): switching \(on ? "on" : "off") for \(id)")
            try await environment.send(on ? calls.on : calls.off, name: name)
            environment.store.set(key, on)
        }
        speed.onWrite { [environment, name] value in
            let level = value.doubleValue ?? 0
            let out = LightAccessory.scaled(level, by: factor)
            guard await coalesce() else { return }
            environment.logger.info("\(name): setting rotation speed to \(Format.number(level)) for \(id)")
            let call = calls.speed?.substituting([("%statusPlaceholder", level > 0 ? "true" : "false"), ("%speedPlaceholder", Format.number(out))], in: .all)
            try await environment.send(call, name: name)
            environment.store.set(key, level > 0)
            environment.store.set(speedKey, level)
        }
        // Each a call with its value in the URL and the body (not a form), or, for the physical controls, a lock and an
        // unlock call.
        let placeholders = ["rotationDirection": "%rotationDirection", "targetState": "%targetState", "swingMode": "%swingMode"]
        let groups = ["rotationDirection": "rotation_direction", "targetState": "target_state", "swingMode": "swing_mode"]
        for (parameter, key, characteristic) in integers {
            let label = characteristic.type.name
            let call = groups[parameter].flatMap(entry.call)
            let lockCalls = (lock: entry.call("lock"), unlock: entry.call("unlock"))
            characteristic.onWrite { [environment, name] value in
                let number = value.intValue ?? 0
                environment.logger.info("\(name): setting \(label) to \(number) for \(id)")
                if parameter == "lockstate" {
                    try await environment.send(number != 0 ? lockCalls.lock : lockCalls.unlock, name: name)
                } else if let placeholder = placeholders[parameter] {
                    try await environment.send(call?.substituting([(placeholder, String(number))], in: [.url, .body]), name: name)
                }
                environment.store.set(key, Double(number))
            }
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        // Only the parameters given change something: `speed` alone leaves Active as it is.
        if let state = query.nonEmpty("state") {
            let on = state == "true"
            environment.store.set(key, on)
            if active.show(on ? 1 : 0) { environment.logger.info("\(name): changing HomeKit Active for fan to \(on)") }
        }
        if let text = query.nonEmpty("speed") {
            // In HomeKit's scale, as the Homebridge plugin reads it: `speed_factor` scales the outgoing calls only.
            if let number = WebhookNumber.integer(text) {
                let level = min(100, max(0, Double(number)))
                environment.store.set(speedKey, level)
                if speed.show(level) { environment.logger.info("\(name): changing HomeKit Rotation Speed for fan to \(Format.number(level))") }
            } else {
                environment.logger.warning("\(name): ignoring speed \"\(text)\", which is not a number")
            }
        }
        for value in integers {
            guard let text = query.nonEmpty(value.parameter) else { continue }
            guard let number = WebhookNumber.integer(text), value.characteristic.type.validValues?.contains(number) ?? true else {
                environment.logger.warning("\(name): ignoring \(value.parameter) \"\(text)\", which is not one of its values")
                continue
            }
            environment.store.set(value.key, Double(number))
            if value.characteristic.show(Double(number)) {
                environment.logger.info("\(name): changing HomeKit \(value.characteristic.type.name) for fan to \(number)")
            }
        }
        return .success
    }
}
