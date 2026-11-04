import Foundation
import Homeswift
import HomeswiftAI

/// The custom characteristics (docs/clean-room/Tahoma.md 5.13), with the Homebridge plugin's UUIDs so their iids stay.
enum TahomaCharacteristics {
    private static let permissions: Set<CharacteristicPermission> = [.pairedRead, .pairedWrite, .events]
    static let currentShower = CharacteristicType(
        name: "Current Shower", uuid: HAPUUID("10000001-0000-1000-8000-0026BB765291"), format: .uint8, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 8, minStep: 1)
    static let targetShower = CharacteristicType(
        name: "Target Shower", uuid: HAPUUID("10000002-0000-1000-8000-0026BB765291"), format: .uint8, permissions: permissions,
        minValue: 0, maxValue: 8, minStep: 1)
    static let my = CharacteristicType(name: "My", uuid: HAPUUID("10000003-0000-1000-8000-0026BB765291"), format: .bool, permissions: permissions)
    static let prog = CharacteristicType(name: "Prog", uuid: HAPUUID("10000004-0000-1000-8000-0026BB765291"), format: .bool, permissions: permissions)
    static let eco = CharacteristicType(name: "Eco", uuid: HAPUUID("10000005-0000-1000-8000-0026BB765291"), format: .bool, permissions: permissions)
}

// MARK: - Roller shutters (5.3.2)

/// A Window Covering: Overkiz's closure 0 is open, HomeKit's position 100 is.
class RollerShutterMapper: Mapper, @unchecked Sendable {
    override class var expectedStates: [String] { ["core:ClosureState", "core:TargetClosureState"] }
    override class var category: AccessoryCategory { .windowCovering }
    override class var kind: String { "cover" }

    var serviceType: ServiceType { .windowCovering }
    private(set) var service: Service!

    /// HomeKit's position as the device's value, and back.
    func converted(_ value: Double) -> Double { options.reverse ? value : 100 - value }

    /// A state's value as the read rules take it (the pergola's Uno variant inverts it first).
    func reading(_ value: JSONValue) -> Double? { value.number }

    /// The command for a stateful device's target position.
    func positionCommands(_ position: Double) -> [OverkizCommand] { [OverkizCommand("setClosure", .number(converted(position)))] }

    /// The one state an Uno variant follows for both positions, or nil for the full read rules.
    class var followedState: String? { nil }

    /// `open` and `close`, or the awning's `deploy` and `undeploy`.
    var openCommand: String { "open" }
    var closeCommand: String { "close" }
    /// Whether a stateless move honours `reverse` (a venetian blind's does not).
    var statelessReverse: Bool { options.reverse }
    var hasMy: Bool { stateless && device.has("my") }

    var current: Double { service.number(.currentPosition) ?? 0 }
    var target: Double { service.number(.targetPosition) ?? 0 }

    override func build() throws -> [Service] {
        var extra: [Characteristic] = []
        if !stateless { extra.append(Characteristic(.obstructionDetected, value: false)) }
        let service = Service(serviceType, name: label, optional: [], extra: extra, isPrimary: true)
        service.characteristic(.positionState).value = .int(HAP.stopped)
        if hasMy { service.characteristic(adding: TahomaCharacteristics.my).value = false }
        self.service = service
        service.characteristic(.targetPosition).onWrite { [weak self] value in
            try await self?.writeTarget(value.doubleValue ?? 0)
        }
        service[TahomaCharacteristics.my]?.onWrite { [weak self] value in
            guard value.boolValue == true else { return }
            try await self?.writeMy()
        }
        return [service]
    }

    /// Shows the followed state on both positions, the target only while idle; false for a mapper that reads them all.
    func followed(_ states: [String: JSONValue], from deviceURL: String) -> Bool {
        guard let name = Self.followedState else { return false }
        guard deviceURL == device.deviceURL, let value = states[name].flatMap(reading) else { return true }
        service.characteristic(.currentPosition).setClamped(converted(value))
        if isIdle { service.characteristic(.targetPosition).setClamped(converted(value)) }
        return true
    }

    /// The position a stateless cover shows after a move: `defaultPosition`, else `fallback`.
    func shownPosition(or fallback: Double) -> Double { options.defaultPosition != 0 ? options.defaultPosition : fallback }

    /// A failed or timed-out move: obstruction for a hazard, and the target back on the current position.
    func showFailure(_ update: ExecutionUpdate) {
        service[.obstructionDetected]?.value = .bool(update.failureType == "WHILEEXEC_BLOCKED_BY_HAZARD")
        if !hasState("core:TargetClosureState") { service.characteristic(.targetPosition).value = service.characteristic(.currentPosition).value }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard !followed(states, from: deviceURL), deviceURL == device.deviceURL else { return }
        if let closure = states["core:ClosureState"].flatMap(reading) {
            service.characteristic(.currentPosition).setClamped(converted(closure))
            if !hasState("core:TargetClosureState"), isIdle { service.characteristic(.targetPosition).setClamped(converted(closure)) }
        }
        if let target = states["core:TargetClosureState"].flatMap(reading) {
            service.characteristic(.targetPosition).setClamped(converted(target))
            if !hasState("core:ClosureState") { service.characteristic(.currentPosition).setClamped(converted(target)) }
        }
    }

    // MARK: Writes

    func writeTarget(_ value: Double) async throws {
        cancelTimer("stop")
        if value != 0, value != 100 {
            guard await debounced("position") else { return }
        }
        let current = current
        var commands: [OverkizCommand]
        var timed = false
        if !stateless {
            commands = positionCommands(value)
        } else {
            let (open, close) = statelessReverse ? (closeCommand, openCommand) : (openCommand, closeCommand)
            switch value {
            case 100: commands = [OverkizCommand(open)]
            case 0: commands = [OverkizCommand(close)]
            default:
                if options.movementDuration > 0 {
                    commands = [OverkizCommand(value > current ? open : close)]
                    timed = true
                } else {
                    commands = [OverkizCommand("my")]
                }
            }
            commands = statelessCommands(value, default: commands)
        }
        let isTimed = timed
        try await execute(commands, standalone: isTimed) { [weak self] update in
            self?.positionFeedback(update, target: value, from: current, timed: isTimed)
        }
    }

    /// A subclass's stateless commands (the RTS generic's `up` and `down`).
    func statelessCommands(_ value: Double, default commands: [OverkizCommand]) -> [OverkizCommand] { commands }

    func positionFeedback(_ update: ExecutionUpdate, target: Double, from current: Double, timed: Bool) {
        switch update.state {
        case .inProgress:
            service.characteristic(.positionState).value = .int(target == 100 || target > current ? HAP.increasing : HAP.decreasing)
            if timed {
                let milliseconds = options.offsetMovementDuration * 1000 + (options.movementDuration * abs(target - current) * 1000 / 100).rounded()
                logger.info("[\(label)] Will stop movement in \(Int(milliseconds)) millisec")
                let execID = update.execID
                schedule("stop", after: scaled(milliseconds / 1000)) { [weak self] in await self?.stopMovement(execID: execID) }
            }
        case .completed:
            completed(target: target)
        case .failed where timed && update.failureType == "CMDCANCELLED":
            completed(target: target)
        case .failed, .timedOut:
            service.characteristic(.positionState).value = .int(HAP.stopped)
            showFailure(update)
        default:
            break
        }
    }

    func completed(target: Double) {
        service.characteristic(.positionState).value = .int(HAP.stopped)
        if stateless {
            let shown = shownPosition(or: target)
            service.characteristic(.currentPosition).setClamped(shown)
            service.characteristic(.targetPosition).setClamped(shown)
        } else {
            service[.obstructionDetected]?.value = false
            if options.blindsOnRollerShutter, target < 98 {
                // A 2 % move back from the closure reached, for blinds hung on a roller shutter's motor (10.9).
                let closure = max(0, converted(target) - 2)
                schedule("blindsOffset", after: .zero) { [weak self] in _ = try? await self?.execute([OverkizCommand("setClosure", .number(closure))]) }
            }
        }
    }

    func writeMy() async throws {
        try await execute([OverkizCommand("my")]) { [weak self] update in
            guard let self else { return }
            switch update.state {
            case .completed:
                service[TahomaCharacteristics.my]?.value = false
                if stateless {
                    let shown = shownPosition(or: 50)
                    service.characteristic(.currentPosition).setClamped(shown)
                    service.characteristic(.targetPosition).setClamped(shown)
                }
            case .failed, .timedOut:
                service[TahomaCharacteristics.my]?.value = false
                showFailure(update)
            default:
                break
            }
        }
    }
}

/// `PositionableRollerShutterUno`: only `core:TargetClosureState` is read (5.3.3).
final class RollerShutterUnoMapper: RollerShutterMapper, @unchecked Sendable {
    override class var followedState: String? { "core:TargetClosureState" }
}

/// `PositionableRollerShutterWithLowSpeedManagement` (5.3.4): `setClosureAndLinearSpeed` with `lowspeed` when
/// `lowSpeed` is true or the time is within its window. The other cover options apply too (the Homebridge plugin
/// dropped them for this one).
final class LowSpeedRollerShutterMapper: RollerShutterMapper, @unchecked Sendable {
    override func positionCommands(_ position: Double) -> [OverkizCommand] {
        guard Self.lowSpeedApplies(options.lowSpeed, at: environment.now(), calendar: environment.calendar) else { return super.positionCommands(position) }
        return [OverkizCommand("setClosureAndLinearSpeed", [.number(converted(position)), "lowspeed"])]
    }

    /// `true` (or `always`), or `HH:MM-HH:MM` containing the time of day: after the start or before the end when the window spans
    /// midnight, strictly between them otherwise.
    static func lowSpeedApplies(_ option: JSONValue, at date: Date, calendar: Calendar) -> Bool {
        if option.boolValue == true { return true }
        guard let text = option.stringValue else { return false }
        if ["always", "true"].contains(text.lowercased()) { return true }
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, (0...24).contains(parts[0]), (0...24).contains(parts[2]), (0..<60).contains(parts[1]), (0..<60).contains(parts[3]) else { return false }
        let start = parts[0] * 60 + parts[1], end = parts[2] * 60 + parts[3]
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let now = Double((components.hour ?? 0) * 60 + (components.minute ?? 0)) + Double(components.second ?? 0) / 60
        if end < start { return now > Double(start) || now < Double(end) }
        return now > Double(start) && now < Double(end)
    }
}

/// `Window` (5.3.5): the roller shutter on a Window service, without My.
final class WindowMapper: RollerShutterMapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .window }
    override var serviceType: ServiceType { .window }
    override var hasMy: Bool { false }

    override func build() throws -> [Service] {
        let services = try super.build()
        if stateless {
            let initial = options.initPosition ?? shownPosition(or: 50)
            service.characteristic(.currentPosition).setClamped(initial)
            service.characteristic(.targetPosition).setClamped(initial)
        }
        return services
    }
}

/// `Generic/RTSGeneric`: `down` for 0, `up` otherwise.
final class RTSGenericMapper: RollerShutterMapper, @unchecked Sendable {
    override func statelessCommands(_ value: Double, default commands: [OverkizCommand]) -> [OverkizCommand] {
        [OverkizCommand(value == 0 ? "down" : "up")]
    }

    override func positionCommands(_ position: Double) -> [OverkizCommand] { [OverkizCommand(position == 0 ? "down" : "up")] }
}

/// `Pergola/PergolaHorizontalAwningUno` (5.3.7): every state inverted first, then the roller shutter's rules.
final class PergolaAwningUnoMapper: RollerShutterMapper, @unchecked Sendable {
    override func reading(_ value: JSONValue) -> Double? { value.number.map { 100 - $0 } }
}

/// `Pergola/BioclimaticPergola` (5.3.7): the slats only.
final class BioclimaticPergolaMapper: RollerShutterMapper, @unchecked Sendable {
    override class var followedState: String? { "core:SlatsOrientationState" }
    override func positionCommands(_ position: Double) -> [OverkizCommand] { [OverkizCommand("setOrientation", .number(converted(position)))] }
}

// MARK: - Awnings (5.3.6)

/// An awning: its deployment is HomeKit's position.
class AwningMapper: RollerShutterMapper, @unchecked Sendable {
    override func converted(_ value: Double) -> Double { options.reverse ? 100 - value : value }
    override var openCommand: String { "deploy" }
    override var closeCommand: String { "undeploy" }
    override func positionCommands(_ position: Double) -> [OverkizCommand] { [OverkizCommand("setDeployment", .number(converted(position)))] }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard !followed(states, from: deviceURL), deviceURL == device.deviceURL else { return }
        for name in ["core:DeploymentState", "core:ClosureState"] {
            guard let value = states[name]?.number else { continue }
            service.characteristic(.currentPosition).setClamped(converted(value))
            if !hasState("core:TargetClosureState") { service.characteristic(.targetPosition).setClamped(converted(value)) }
        }
        if let target = states["core:TargetClosureState"]?.number {
            service.characteristic(.targetPosition).setClamped(converted(target))
            if !hasState("core:ClosureState") { service.characteristic(.currentPosition).setClamped(converted(target)) }
        }
    }
}

/// `Awning/PositionableHorizontalAwningUno`: only `core:TargetClosureState`, with the awning's conversion.
final class AwningUnoMapper: AwningMapper, @unchecked Sendable {
    override class var followedState: String? { "core:TargetClosureState" }
}

// MARK: - Venetian blinds (5.4)

/// A venetian blind: the roller shutter with its slats' tilt, or with `blindMode` the slats on the main slider.
class VenetianBlindMapper: RollerShutterMapper, @unchecked Sendable {
    override class var kind: String { "venetianBlind" }
    override var statelessReverse: Bool { false }

    var hasTilt: Bool { !stateless && !options.blindMode }

    /// Overkiz's orientation (0–100) as HomeKit's tilt angle (−90…90), and back.
    static func angle(_ orientation: Double) -> Double { (orientation * 1.8 - 90).rounded() }
    static func orientation(_ angle: Double) -> Double { ((angle + 90) / 1.8).rounded() }

    var targetAngle: Double { service.number(.targetHorizontalTiltAngle) ?? 0 }

    override func build() throws -> [Service] {
        let services = try super.build()
        if hasTilt {
            service.characteristic(adding: .currentHorizontalTiltAngle)
            service.characteristic(adding: CharacteristicType.targetHorizontalTiltAngle.with(minStep: 10)).onWrite { [weak self] value in
                try await self?.writeTilt(value.doubleValue ?? 0)
            }
        }
        return services
    }

    var closureAndOrientation: String { "setClosureAndOrientation" }

    override func writeTarget(_ value: Double) async throws {
        // Seen by a tilt written with it, so the two become one command.
        service.characteristic(.targetPosition).setClamped(value)
        try await super.writeTarget(value)
    }

    override func positionCommands(_ position: Double) -> [OverkizCommand] {
        options.blindMode ? blindModeCommands(position) : commands(position: position, angle: targetAngle)
    }

    /// With `blindMode`, the main slider moves the slats of a closed blind.
    func blindModeCommands(_ position: Double) -> [OverkizCommand] {
        if position == 100 { return [OverkizCommand("open")] }
        if device.has(closureAndOrientation) { return [OverkizCommand(closureAndOrientation, [100, .number(converted(position))])] }
        return [OverkizCommand("setClosure", 100), OverkizCommand("setOrientation", .number(converted(position)))]
    }

    func commands(position: Double, angle: Double) -> [OverkizCommand] {
        if device.has(closureAndOrientation) {
            return [OverkizCommand(closureAndOrientation, [.number(converted(position)), .number(Self.orientation(angle))])]
        }
        var commands = [OverkizCommand("setClosure", .number(converted(position)))]
        if device.has("setOrientation") { commands.append(OverkizCommand("setOrientation", .number(Self.orientation(angle)))) }
        return commands
    }

    func writeTilt(_ value: Double) async throws {
        service[.targetHorizontalTiltAngle]?.setClamped(value)
        guard await debounced("tilt"), !stateless else { return }
        try await execute(commands(position: target, angle: value)) { [weak self] update in
            guard let self, update.state == .failed || update.state == .timedOut else { return }
            if let current = service[.currentHorizontalTiltAngle]?.value { service[.targetHorizontalTiltAngle]?.value = current }
        }
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if options.blindMode {
            guard states["core:OpenClosedState"] != nil || states["core:SlateOrientationState"] != nil else { return }
            if string("core:OpenClosedState") == "closed" {
                guard let orientation = number("core:SlateOrientationState"), orientation.rounded() == orientation else { return }
                let position = converted(orientation)
                service.characteristic(.currentPosition).setClamped(position)
                if isIdle || (position / 5).rounded() == (target / 5).rounded() { service.characteristic(.targetPosition).setClamped(position) }
            } else {
                service.characteristic(.currentPosition).value = 100
                if isIdle { service.characteristic(.targetPosition).value = 100 }
            }
            return
        }
        super.apply(states, from: deviceURL)
        if let orientation = states["core:SlateOrientationState"]?.number {
            service[.currentHorizontalTiltAngle]?.setClamped(Self.angle(orientation))
            if isIdle { service[.targetHorizontalTiltAngle]?.setClamped(Self.angle(orientation)) }
        }
    }
}

/// `AdjustableSlatsRollerShutter`: the venetian blind with `setClosureOrOrientation`.
final class AdjustableSlatsMapper: VenetianBlindMapper, @unchecked Sendable {
    override var closureAndOrientation: String { "setClosureOrOrientation" }

    override func blindModeCommands(_ position: Double) -> [OverkizCommand] {
        if position == 100 { return [OverkizCommand("setClosure", 0)] }
        return [OverkizCommand(closureAndOrientation, [100, .number(converted(position))])]
    }

    override func commands(position: Double, angle: Double) -> [OverkizCommand] {
        [OverkizCommand(closureAndOrientation, [.number(converted(position)), .number(Self.orientation(angle))])]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        super.apply(states, from: deviceURL)
        guard deviceURL == device.deviceURL, !options.blindMode, let value = states["core:ClosureOrRockerPositionState"]?.number else { return }
        service.characteristic(.currentPosition).setClamped(converted(value))
        if !hasState("core:TargetClosureState") { service.characteristic(.targetPosition).setClamped(converted(value)) }
    }
}
