import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// A device or an IR remote as the plugin knows it once its options are merged.
struct DeviceInfo: Sendable {
    /// The cloud's id, which commands, statuses and webhooks use.
    var id: String
    /// The Device Id: 4.x's seed `<deviceId>-<deviceType>` (`<deviceId>-<remoteType>`), the accessory's id after
    /// `SwitchBot:`.
    var deviceID: String
    /// The OpenAPI `deviceType`, or the IR remote's `remoteType`.
    var type: String
    var name: String
    var options: DeviceOptions
    var isRemote: Bool
    var firmware: String
}

/// How an accessory reaches its device: `send` sends the commands in turn and says whether the cloud took them all; it
/// throws when the cloud does not answer (No Response) or the device has no usable transport.
struct DeviceLink: Sendable {
    var send: @Sendable (_ commands: [Command]) async throws -> Bool
}

/// What one device shows in HomeKit: its services, the values of its statuses and webhooks, and its commands. Each
/// family subclasses it. HomeKit's writes land in the subclass's targets; `write` waits for the debounce (`pushRate`)
/// and the last write of a burst calls `push`, which sends what differs from what the device last reported.
class DeviceAccessory: @unchecked Sendable {
    let info: DeviceInfo
    let link: DeviceLink
    let logger: Logger
    let lock = NSLock()
    private let latest: LatestCallGuard
    private var writes = 0
    /// The services, primary first, which the subclass hands over once it made them (`adopt`).
    private(set) var services: [Service] = []
    var category: AccessoryCategory { .other }
    /// The lux of `dim`/level 1 and of `bright`/the top level (`set_minLux`, `set_maxLux`; also spelled `set_minlux`).
    let lux: ClosedRange<Double>

    init(info: DeviceInfo, link: DeviceLink, debounce: Duration, logger: Logger) {
        self.info = info
        self.link = link
        self.logger = logger
        latest = LatestCallGuard(delay: debounce)
        let minimum = max(info.options.number("set_minLux", "set_minlux") ?? 1, 0.0001)
        let maximum = min(max(info.options.number("set_maxLux", "set_maxlux") ?? 6001, minimum), 100_000)
        lux = minimum...maximum
    }

    func adopt(_ services: [Service?]) { self.services = services.compactMap { $0 } }

    var name: String { info.name }
    var options: DeviceOptions { info.options }

    /// Shows a status (or a webhook's context, `webhook` true).
    func show(_ status: [String: JSONValue], webhook: Bool) {}

    /// "Offline as Off" (`offline`): what a device without a usable transport shows.
    func showOffline() {}

    /// Whether the device moves now and its position should be polled every `updateRate` seconds.
    var isMoving: Bool { false }

    /// Sends what the targets changed; called by `write` for the last write of a burst.
    func push() async throws {}

    /// A write is waiting for its debounce or being sent: polls skip the device, so they do not undo it.
    var isWriting: Bool { lock.withLock { writes > 0 } }

    /// Records a write with `record` (under the lock), then, after the debounce, pushes unless a later write came.
    func write(_ record: () -> Void) async throws {
        lock.withLock {
            record()
            writes += 1
        }
        defer { lock.withLock { writes -= 1 } }
        guard await latest() else { return }
        try await push()
    }

    /// Sends commands; false when the cloud refused one (the next refresh shows the device as it is).
    @discardableResult
    func send(_ commands: [Command]) async throws -> Bool {
        guard !commands.isEmpty else { return true }
        return try await link.send(commands)
    }

    // MARK: Shared services

    static func batteryService(_ name: String, chargeable: Bool = false) -> Service {
        let battery = Service(.battery, name: "\(name) Battery", optional: [.batteryLevel, .chargingState])
        battery.characteristic(.chargingState).value = .int(chargeable ? 0 : 2)
        return battery
    }

    func showBattery(_ status: [String: JSONValue], on service: Service?) {
        guard let service, let level = status["battery"].flatMap(number) else { return }
        let percent = Int(saturating: level, in: 0...100) ?? 0
        service.characteristic(.batteryLevel).value = .int(percent)
        service.characteristic(.statusLowBattery).value = .int(percent < 10 ? 1 : 0)
    }

    static func lightSensorService(_ name: String, minStep: Double? = nil) -> Service {
        let sensor = Service(
            .lightSensor, name: "\(name) Light Sensor", optional: [.statusActive],
            extra: minStep.map { [Characteristic(CharacteristicType.currentAmbientLightLevel.with(minStep: $0), value: .double(0.0001))] } ?? [])
        sensor.characteristic(.statusActive).value = .bool(true)
        return sensor
    }

    /// The lux of `bright` (the maximum) or `dim` (the minimum): 4.x's evident intent.
    func showBrightness(_ value: JSONValue?, on sensor: Service?) {
        guard let sensor, let text = value?.stringValue else { return }
        sensor.characteristic(.currentAmbientLightLevel).value = .double(text == "bright" ? lux.upperBound : lux.lowerBound)
    }

    /// A light level of 1 to `steps + 1` as lux (§6.3).
    func showLightLevel(_ value: JSONValue?, steps: Double, on sensor: Service?) {
        guard let sensor, let level = value.flatMap(number) else { return }
        let lux = Self.lux(level: level, steps: steps, range: lux)
        sensor.characteristic(.currentAmbientLightLevel).value = .double(lux)
    }

    static func lux(level: Double, steps: Double, range: ClosedRange<Double>) -> Double {
        if level <= 1 { return range.lowerBound }
        if level >= steps + 1 { return range.upperBound }
        return max((range.upperBound - range.lowerBound) / steps * (level - 1), 0.0001)
    }

    /// A temperature in Celsius from a status or a webhook. A webhook's `scale` FAHRENHEIT is converted; with
    /// `convertUnitTo: "FAHRENHEIT"` 4.x's rounding (to half a degree) is kept.
    func celsius(_ status: [String: JSONValue], webhook: Bool) -> Double? {
        guard let value = status["temperature"].flatMap(number) else { return nil }
        guard webhook, status["scale"]?.stringValue?.uppercased() == "FAHRENHEIT" else { return value }
        let converted = (value - 32) * 5 / 9
        if options.string("convertUnitTo")?.uppercased() == "FAHRENHEIT" { return (converted * 2).rounded() / 2 }
        return (converted * 10).rounded() / 10
    }
}

/// A number from JSON, written as a number or as text.
func number(_ value: JSONValue) -> Double? {
    switch value {
    case .number(let number) where number.isFinite: number
    case .string(let text): Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
    case .bool(let flag): flag ? 1 : 0
    default: nil
    }
}
