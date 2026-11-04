import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// What every accessory of the plugin shares: the options, the timings, the log, the client, the state kept across
/// launches, and the bag its background writes run in.
struct RingEnvironment: Sendable {
    let configuration: RingPlugin.Configuration
    let timing: RingTiming
    let logger: Logger
    let client: RingClient
    let memory: PersistedDictionary<RingMemory>
    let tasks: TaskBag
    /// Asks for a fetch of the REST devices (throttled), when HomeKit reads a value that may be stale.
    let requestRefresh: @Sendable () -> Void

    /// A HomeKit write is acknowledged at once; the Ring call runs in the background and its failure is logged.
    func background(_ what: String, _ operation: @escaping @Sendable () async throws -> Void) {
        let logger = logger
        tasks.add {
            do { try await operation() } catch is CancellationError {} catch { logger.error("\(what) failed: \(error)") }
        }
    }
}

/// What an accessory keeps across launches (Homebridge's accessory `context`): the security panel's Night flag, the
/// last brightness of a brightness-only device.
struct RingMemory: Codable, Equatable, Sendable {
    var targetingNightMode: Bool?
    var brightness: Int?
}

/// A slider written from HomeKit (Volume, Brightness, Rotation Speed; docs/clean-room/Ring.md, 4.4): only the last
/// value of a burst goes out after the debounce, and until the device reports exactly that value the characteristic
/// keeps showing it.
final class RingLevel: Sendable {
    private let pending = NIOLockedValueBox<Double?>(nil)
    private let latest: LatestCallGuard

    init(debounce: Duration) { latest = LatestCallGuard(delay: debounce) }

    /// The value to show for what the device reports: the written one until the device has it.
    func shown(_ reported: Double?) -> Double? {
        pending.withLockedValue { pending in
            if let written = pending {
                if let reported, abs(reported - written) < 0.0001 { pending = nil } else { return written }
            }
            return reported
        }
    }

    /// Debounces, then sends `deviceValue` when no later write came.
    func write(_ deviceValue: Double, _ send: @escaping @Sendable (Double) async throws -> Void) async throws {
        pending.withLockedValue { $0 = deviceValue }
        guard await latest() else { return }
        try await send(deviceValue)
    }
}

extension JSONValue {
    /// A number, or a numeric string (`"87"`): Ring sends both.
    var looseDouble: Double? {
        switch self {
        case .number(let value): value.isFinite ? value : nil
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: nil
        }
    }

    /// JavaScript's truthiness, for the fields the original tests that way.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0 && !value.isNaN
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }

    /// The id of a device or a notification, as a string whether it came as a number or a text.
    var idString: String? {
        switch self {
        case .string(let text): text
        case .number(let value) where value.rounded() == value && abs(value) < 9_007_199_254_740_992: String(Int64(value))
        default: nil
        }
    }
}

extension Characteristic {
    /// Sets the value only when it changed (and so notifies HomeKit only then).
    func show(_ value: HAPValue) {
        if self.value != value { self.value = value }
    }
}

enum RingBattery {
    /// A hub device's battery: its level (or one guessed from the status), whether it is low, and its charging state.
    static func hub(_ data: JSONValue) -> (level: Int, low: Bool, charging: Int)? {
        let status = data["batteryStatus"]?.stringValue
        guard status != "none" else { return nil }
        let level: Int = data["batteryLevel"]?.looseDouble.flatMap { Int(saturating: $0, in: 0...100) } ?? {
            switch status {
            case "full", "charged": 100
            case "ok", "charging": 50
            default: 0
            }
        }()
        let backup = data["batteryBackup"]?.stringValue, ac = data["acStatus"]?.stringValue
        let charging: Int
        if status == "charging" || status == "charged" || backup == "charged" || backup == "charging" || ac == "ok" {
            charging = 1
        } else if backup == "inUse" || ac == "error" {
            charging = 0
        } else {
            charging = 2
        }
        return (level, level <= 20, charging)
    }

    /// A camera's or an intercom's level: the lowest of `battery_life` and `battery_life_2`; nil when neither parses, or
    /// when `health` says there is no battery.
    static func rest(_ data: JSONValue) -> Int?? {
        let values = [data["battery_life"], data["battery_life_2"]].compactMap { $0?.looseDouble }
        guard !values.isEmpty else { return nil }
        if let health = data["health"], health.objectValue != nil,
           !(health["battery_percentage"]?.isTruthy ?? false), !(health["battery_present"]?.isTruthy ?? false),
           !(health["second_battery_percentage"]?.isTruthy ?? false) {
            return nil
        }
        return .some(values.min().flatMap { Int(saturating: $0, in: 0...100) })
    }

    /// Whether a camera has a battery level and is not wired.
    static func operatesOnBattery(_ data: JSONValue) -> Bool {
        rest(data) != nil && data["settings"]?["power_mode"]?.stringValue != "wired"
    }
}

/// The models Ring's `kind` codes stand for (docs/clean-room/Ring.md, 4.3).
enum RingModels {
    static let cameras: [String: String] = [
        "doorbot": "Doorbell", "doorbell": "Doorbell", "doorbell_v3": "Doorbell", "doorbell_v4": "Doorbell 2", "doorbell_v5": "Doorbell 2",
        "doorbell_oyster": "Doorbell 4", "doorbell_portal": "Door View Cam", "doorbell_scallop": "Doorbell 3 Plus",
        "doorbell_scallop_lite": "Doorbell 3", "doorbell_graham_cracker": "Doorbell Wired", "lpd_v1": "Doorbell Pro", "lpd_v2": "Doorbell Pro",
        "lpd_v4": "Doorbell Pro 2", "jbox_v1": "Doorbell Elite", "stickup_cam": "Stick Up Cam", "stickup_cam_v3": "Stick Up Cam",
        "stickup_cam_elite": "Stick Up Cam", "stickup_cam_lunar": "Stick Up Cam", "cocoa_camera": "Stick Up Cam",
        "stickup_cam_longfin": "Spotlight Cam Pro", "spotlightw_v2": "Spotlight Cam", "hp_cam_v2": "Spotlight Cam", "stickup_cam_v4": "Spotlight Cam",
        "hp_cam_v1": "Floodlight Cam", "floodlight_v1": "Floodlight Cam", "floodlight_v2": "Floodlight Cam", "floodlight_pro": "Floodlight Pro",
        "cocoa_doorbell": "Doorbell Gen 2", "cocoa_doorbell_v2": "Battery Doorbell Plus", "cocoa_doorbell_v3": "Battery Doorbell Pro",
        "cocoa_floodlight": "Floodlight Cam Plus", "cocoa_spotlight": "Spotlight Cam Plus", "stickup_cam_mini": "Indoor Cam",
        "onvif_camera": "ONVIF Camera",
    ]
    static let chimes = ["chime": "Chime", "chime_pro": "Chime Pro", "chime_v2": "Chime v2", "chime_pro_v2": "Chime Pro v2"]

    static func camera(_ kind: String) -> String { cameras[kind] ?? "Unknown Model" }
    static func chime(_ kind: String) -> String { chimes[kind] ?? "Chime" }
}

/// Adds a Battery service from a hub device's data, and the Status Low Battery and Tampered of its sensor services.
enum RingCommon {
    struct Parts {
        var battery: Service?
        var speaker: Service?
        var speakerLevel: RingLevel?
        var sensors: [Service] = []
    }

    /// The Speaker (when the device has a volume) and Battery services every hub device's accessory gets.
    static func services(zid: String, data: JSONValue, name: String, hub: RingLocationHub, environment: RingEnvironment) -> Parts {
        var parts = Parts()
        if RingBattery.hub(data) != nil {
            parts.battery = Service(.battery, optional: [.batteryLevel, .chargingState])
        }
        if data["volume"] != nil {
            let speaker = Service(.speaker, optional: [.volume])
            speaker.characteristic(.mute).value = .bool(false)
            speaker.characteristic(.mute).onWrite { _ in speaker.characteristic(.mute).value = .bool(false) }
            let level = RingLevel(debounce: environment.timing.levelDebounce)
            let deviceType = data["deviceType"]?.stringValue ?? ""
            speaker.characteristic(.volume).onWrite { value in
                let volume = (value.doubleValue ?? 0) / 100
                guard ["hub.redsky", "security-keypad"].contains(deviceType), (0...1).contains(volume) else {
                    environment.logger.error("Volume can only be set on base stations and keypads")
                    return
                }
                environment.background("Setting the volume of \(name)") {
                    try await level.write(volume) { try await hub.set(zid, ["volume": .number($0)]) }
                }
            }
            parts.speaker = speaker
            parts.speakerLevel = level
        }
        return parts
    }

    /// A sensor service with Status Tampered, and Status Low Battery when the device has a battery.
    static func sensor(_ type: ServiceType, name: String? = nil, data: JSONValue, isPrimary: Bool = false) -> Service {
        var optional: [CharacteristicType] = [.statusTampered]
        if RingBattery.hub(data) != nil { optional.append(.statusLowBattery) }
        return Service(type, name: name, optional: optional, isPrimary: isPrimary)
    }

    static func show(_ data: JSONValue, on parts: Parts) {
        if let battery = parts.battery, let state = RingBattery.hub(data) {
            battery.characteristic(.batteryLevel).show(.int(state.level))
            battery.characteristic(.statusLowBattery).show(.int(state.low ? 1 : 0))
            battery.characteristic(.chargingState).show(.int(state.charging))
        }
        if let speaker = parts.speaker {
            let volume = parts.speakerLevel?.shown(data["volume"]?.looseDouble) ?? data["volume"]?.looseDouble ?? 0
            speaker.characteristic(.volume).show(.int(Int(saturating: volume * 100, in: 0...100) ?? 0))
        }
        // A device that reports no tamper status (a Smart Lighting motion sensor) is not tampered.
        let tampered = data["tamperStatus"]?.stringValue.map { $0 == "ok" ? 0 : 1 }
        let low = RingBattery.hub(data)?.low
        for sensor in parts.sensors {
            if let tampered { sensor[.statusTampered]?.show(.int(tampered)) }
            if let low { sensor[.statusLowBattery]?.show(.int(low ? 1 : 0)) }
        }
    }
}
