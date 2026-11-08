import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The Blind Tilt's `mapping` (§6.5): how its direction and slide position become one HomeKit position and back.
enum BlindMapping: String {
    case onlyUp = "only_up", onlyDown = "only_down", downAndUp = "down_and_up", upAndDown = "up_and_down"
    case tiltForDirection = "use_tilt_for_direction"

    /// HomeKit's position (and tilt angle, for `use_tilt_for_direction`) from the device's `slidePosition`.
    func homeKit(slide p: Int) -> (position: Int, tilt: Int?) {
        switch self {
        case .onlyUp: (p < 50 ? 100 : 100 - 2 * (p - 50), nil)
        case .onlyDown: (p > 50 ? 100 : 2 * p, nil)
        case .downAndUp: (p, nil)
        case .upAndDown: (100 - p, nil)
        case .tiltForDirection: p <= 50 ? (2 * p, -90) : (100 - 2 * (p - 50), 90)
        }
    }

    /// The direction and position to send for HomeKit's `position` (4.x's `up_and_down` goes negative above 50: the
    /// intent, 200 − 2h, is used).
    func command(position h: Int, tilt: Int) -> (direction: String, position: Int) {
        switch self {
        case .onlyUp: ("up", h)
        case .onlyDown: ("down", h)
        case .downAndUp: h <= 50 ? ("down", 100 - 2 * h) : ("up", 2 * (h - 50))
        case .upAndDown: h <= 50 ? ("up", 2 * h) : ("down", 200 - 2 * h)
        case .tiltForDirection: tilt <= 0 ? ("down", h) : ("up", h)
        }
    }

    /// The command for a mapped position: `fullyOpen` at 100, `closeUp`/`closeDown` at 0, else `setPosition` with an
    /// even position, as the API asks.
    static func command(direction: String, position: Int) -> Command {
        let position = min(max(position, 0), 100)
        if position == 100 { return Command(command: "fullyOpen") }
        if position == 0 { return Command(command: direction == "down" ? "closeDown" : "closeUp") }
        let even = Int((Double(position) / 2).rounded()) * 2
        return Command(command: "setPosition", parameter: "\(direction);\(even)")
    }
}

/// Curtain, Curtain 3, Roller Shade and Blind Tilt: a Window Covering whose moves are polled every `updateRate`
/// seconds while they last.
final class CoveringAccessory: DeviceAccessory, @unchecked Sendable {
    let family: Family
    let covering: Service
    let battery: Service
    let lightSensor: Service?
    let silentOpen: Service?
    let silentClose: Service?
    let mapping: BlindMapping
    private var target = 100
    private var tilt = 90
    private var current = 100
    private var moving = false
    private var newTargetUntil: ContinuousClock.Instant?
    private let updateRate: Duration

    override var category: AccessoryCategory { .windowCovering }

    init(info: DeviceInfo, family: Family, link: DeviceLink, debounce: Duration, updateRate: Duration, logger: Logger) {
        self.family = family
        self.updateRate = updateRate
        let options = info.options
        mapping = BlindMapping(rawValue: options.string("mapping") ?? "") ?? .onlyUp
        let step = max(options.number("set_minStep") ?? 1, 1)
        var extra = [Characteristic(CharacteristicType.targetPosition.with(minStep: step), value: .int(100))]
        let tiltType = family == .blindTilt && mapping == .tiltForDirection
        if tiltType {
            extra.append(Characteristic(CharacteristicType.targetHorizontalTiltAngle.with(minValue: -90, maxValue: 90, minStep: 180), value: .int(90)))
            extra.append(Characteristic(CharacteristicType.currentHorizontalTiltAngle.with(minValue: -90, maxValue: 90, minStep: 180), value: .int(90)))
        }
        covering = Service(
            .windowCovering, name: info.name, optional: family == .blindTilt ? [] : [.holdPosition, .obstructionDetected], extra: extra, isPrimary: true)
        battery = Self.batteryService(info.name, chargeable: family != .blindTilt)
        lightSensor = family == .rollerShade || options.flag("hide_lightsensor") ? nil : Self.lightSensorService(info.name)
        if options.flag("silentModeSwitch") {
            silentOpen = Service(.switch, name: "\(info.name) Silent Open Mode", subtype: "SilentOpenMode")
            silentClose = Service(.switch, name: "\(info.name) Silent Close Mode", subtype: "SilentCloseMode")
        } else {
            silentOpen = nil
            silentClose = nil
        }
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([covering, battery, lightSensor, silentOpen, silentClose])
        covering.characteristic(.currentPosition).value = .int(100)
        covering[.obstructionDetected]?.value = .bool(false)
        covering.characteristic(.positionState).value = .int(2)
        covering.characteristic(.targetPosition).onWrite { [weak self] value in
            guard let self else { return }
            let position = value.intValue ?? 0
            try await write { recordTarget(position) }
        }
        covering[.targetHorizontalTiltAngle]?.onWrite { [weak self] value in
            try await self?.write { self?.tilt = (value.intValue ?? 90) <= 0 ? -90 : 90 }
        }
        covering[.holdPosition]?.onWrite { [weak self] value in
            guard let self, value.boolValue == true else { return }
            try await send([Command(command: "pause")])
        }
        silentOpen?.characteristic(.on).onWrite { _ in }
        silentClose?.characteristic(.on).onWrite { _ in }
    }

    private func recordTarget(_ position: Int) {
        target = position
        newTargetUntil = .now + updateRate
        covering[.holdPosition]?.value = .bool(false)
        covering.characteristic(.positionState).value = .int(position > current ? 1 : position < current ? 0 : 2)
    }

    override var isMoving: Bool {
        lock.withLock { moving || newTargetUntil.map { .now < $0 } ?? false }
    }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        showBattery(status, on: battery)
        // The cloud says `bright` or `dim`; Bluetooth a level of 1 to 10.
        let light = status["lightLevel"] ?? status["brightness"]
        if case .number = light { showLightLevel(light, steps: 9, on: lightSensor) } else { showBrightness(light, on: lightSensor) }
        guard let slide = status["slidePosition"].flatMap(number).flatMap({ Int(saturating: $0, in: 0...100) }) else { return }
        var position: Int
        var angle: Int?
        if family == .blindTilt {
            (position, angle) = mapping.homeKit(slide: slide)
            if let min = options.number("set_min"), Double(position) <= min { position = 0 }
            if let max = options.number("set_max"), Double(position) >= max { position = 100 }
        } else {
            position = 100 - slide
            if let min = options.number("set_min"), Double(position) >= min { position = 100 }
            if let max = options.number("set_max"), Double(position) <= max { position = 0 }
        }
        let isMoving = status["moving"]?.boolValue ?? false
        let (target, settled) = lock.withLock { () -> (Int, Bool) in
            current = position
            moving = isMoving
            let pending = newTargetUntil.map { .now < $0 } ?? false
            if !pending && !isMoving { self.target = position }
            return (self.target, !pending && !isMoving)
        }
        covering.characteristic(.currentPosition).value = .int(position)
        covering.characteristic(.targetPosition).value = .int(target)
        covering.characteristic(.positionState).value = .int(settled ? 2 : target > position ? 1 : target < position ? 0 : 2)
        if let angle {
            covering[.currentHorizontalTiltAngle]?.value = .int(angle)
            if settled {
                lock.withLock { tilt = angle }
                covering[.targetHorizontalTiltAngle]?.value = .int(angle)
            }
        }
    }

    override func showOffline() {
        covering.characteristic(.currentPosition).value = .int(100)
        covering.characteristic(.targetPosition).value = .int(100)
        covering.characteristic(.positionState).value = .int(2)
    }

    override func push() async throws {
        let (target, tilt, current) = lock.withLock { (self.target, self.tilt, self.current) }
        guard options.flag("disableCaching") || target != current || family == .blindTilt && mapping == .tiltForDirection else { return }
        if family == .blindTilt {
            let (direction, position) = mapping.command(position: target, tilt: tilt)
            try await send([BlindMapping.command(direction: direction, position: position)])
            return
        }
        let opening = target > 50
        let configured = options.string(opening ? "setOpenMode" : "setCloseMode")
        let switchOn = (opening ? silentOpen : silentClose)?.characteristic(.on).value.boolValue ?? false
        let mode = configured == "1" || switchOn ? "1" : "ff"
        try await send([Command(command: "setPosition", parameter: "0,\(mode),\(100 - target)")])
    }
}
