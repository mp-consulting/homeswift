import Foundation
import Homeswift
import HomeswiftPlugin

/// `lights[]`: a dimmable Lightbulb. `state=true|false` and `value=<brightness>` set it, the brightness in the target
/// system's scale (HomeKit's 0–100 times `brightness_factor`). HomeKit's On calls `on_*`/`off_*`, its Brightness
/// `brightness_*` with `%statusPlaceholder` and `%brightnessPlaceholder`.
///
/// The brightness is kept in the target system's scale whoever set it, so the readback answers what the system was
/// told or said.
final class LightAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    let factor: Double
    private let on: Characteristic
    private let brightness: Characteristic
    private let environment: KindEnvironment
    private let coalesce: LatestCallGuard
    private var key: String { "http-webhook-\(id)" }
    private var brightnessKey: String { "http-webhook-brightness-\(id)" }

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        factor = entry.number("brightness_factor", default: 1)
        coalesce = LatestCallGuard(delay: environment.timing.coalescing)
        let service = Service(.lightbulb, name: name, optional: [.brightness], isPrimary: true)
        on = service.characteristic(.on)
        brightness = service.characteristic(.brightness)
        accessory = Accessory(
            id: HTTPWebhooksPlugin.accessoryID(name: name), name: name, manufacturer: HTTPWebhooksPlugin.manufacturer,
            model: "HttpWebHookLightAccessory-\(name)", serialNumber: "HttpWebHookLightAccessory-\(id)", category: .lightbulb, services: [service])
        on.show(environment.store.bool(key))
        brightness.show(homeKitBrightness(storedBrightness))

        let calls = (on: entry.call("on"), off: entry.call("off"), brightness: entry.call("brightness"))
        let (key, brightnessKey, factor, coalesce) = (key, brightnessKey, factor, coalesce)
        on.onWrite { [environment, name] value in
            let state = value.boolValue ?? false
            environment.logger.info("\(name): switching \(state ? "on" : "off") for \(id)")
            try await environment.send(state ? calls.on : calls.off, name: name)
            environment.store.set(key, state)
        }
        brightness.onWrite { [environment, name] value in
            let level = value.doubleValue ?? 0
            let out = Self.scaled(level, by: factor)
            guard await coalesce() else { return }
            environment.logger.info("\(name): setting brightness to \(Format.number(level)) for \(id)")
            let call = calls.brightness?.substituting(
                [("%statusPlaceholder", level > 0 ? "true" : "false"), ("%brightnessPlaceholder", Format.number(out))], in: .all)
            try await environment.send(call, name: name)
            environment.store.set(key, level > 0)
            environment.store.set(brightnessKey, out)
        }
    }

    /// The stored brightness in the target scale; HomeKit's full brightness before anything set one.
    private var storedBrightness: Double { environment.store.number(brightnessKey, default: Self.scaled(100, by: factor)) }

    /// HomeKit's 0–100 in the target scale, rounded up (`ceil(brightness × factor)`).
    static func scaled(_ level: Double, by factor: Double) -> Double {
        (level * factor - 1e-9).rounded(.up)
    }

    /// The target scale's brightness in HomeKit's 0–100, rounded up.
    private func homeKitBrightness(_ value: Double) -> Double {
        min(100, max(0, (value / factor - 1e-9).rounded(.up)))
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        let state = query.nonEmpty("state")
        let value = query.nonEmpty("value")
        guard state != nil || value != nil else {
            return .success(["brightness": .number(storedBrightness), "state": .bool(environment.store.bool(key))])
        }
        let on = state.map { $0 == "true" } ?? environment.store.bool(key)
        var level = storedBrightness
        if let value {
            if let number = WebhookNumber.integer(value) {
                level = Double(number)
            } else {
                environment.logger.warning("\(name): ignoring brightness \"\(value)\", which is not a number")
            }
        }
        environment.store.set(key, on)
        environment.store.set(brightnessKey, level)
        let changedOn = self.on.show(on)
        let changedBrightness = brightness.show(homeKitBrightness(level))
        if changedOn || changedBrightness {
            environment.logger.info("\(name): changing HomeKit state for light to \(on), brightness \(Format.number(homeKitBrightness(level)))")
        }
        // Only `value` leaves the light as it was: it does not turn it on.
        return .success
    }
}
