import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// An IR remote behind a Hub: no status, so HomeKit shows what was last written. Commands go at once (the air
/// conditioner's settings wait 1.5 s to go as one `setAll`).
final class RemoteAccessory: DeviceAccessory, @unchecked Sendable {
    let family: RemoteFamily
    let primary: Service
    let speaker: Service?
    let offButton: Service?
    let others: ControlKind?
    /// The linked meter's last temperature (`meterType` and `meterId`), for an air conditioner.
    let meterTemperature: @Sendable () -> Double?
    private var climate = (active: false, mode: 2, threshold: 24.0, speed: 4)
    private let settle: Duration

    override var category: AccessoryCategory {
        switch family {
        case .television:
            let base = info.type.replacingOccurrences(of: "DIY ", with: "")
            return base == "Speaker" ? .speaker : base == "IPTV" ? .tvStreamingStick : base == "DVD" || base == "Set Top Box" ? .tvSetTopBox : .television
        case .fan: return .fan
        case .airConditioner: return .airConditioner
        case .light: return offButton == nil ? .lightbulb : .programmableSwitch
        case .airPurifier: return .airPurifier
        case .waterHeater: return .faucet
        case .vacuumCleaner: return .other
        case .camera: return .ipCamera
        case .others: return others?.category ?? .outlet
        }
    }

    /// Whether it goes on a HAP server of its own: televisions always (HomeKit wants them so), `DIY` remotes and those
    /// with `external` otherwise.
    var isExternal: Bool { family == .television || info.options.bool("external") ?? info.type.hasPrefix("DIY ") }

    init(info: DeviceInfo, family: RemoteFamily, link: DeviceLink, settle: Duration = .milliseconds(1500), meterTemperature: @escaping @Sendable () -> Double?, logger: Logger) {
        self.family = family
        self.settle = settle
        self.meterTemperature = meterTemperature
        let options = info.options, name = info.name
        var speaker: Service?, offButton: Service?, others: ControlKind?
        switch family {
        case .television:
            let tvSpeaker = Service(.televisionSpeaker, name: "\(name) Speaker", optional: [.active, .volumeControlType, .volumeSelector])
            primary = Service(.television, name: name, optional: [.configuredName, .remoteKey], linked: [tvSpeaker], isPrimary: true)
            speaker = tvSpeaker
        case .fan:
            var optional: [CharacteristicType] = []
            if options.flag("rotation_speed") {
                optional.append(CharacteristicType.rotationSpeed.with(
                    minValue: options.number("set_min") ?? 1, maxValue: options.number("set_max") ?? 100, minStep: max(options.number("set_minStep") ?? 1, 1)))
            }
            if options.flag("swing_mode") { optional.append(.swingMode) }
            primary = Service(.fanv2, name: name, optional: optional, isPrimary: true)
        case .light where options.flag("stateless"):
            primary = Service(.statefulProgrammableSwitch, name: "\(name) On", subtype: "On", extra: [
                Characteristic(CharacteristicType.programmableSwitchEvent.with(validValues: [0])),
            ], isPrimary: true)
            offButton = Service(.statefulProgrammableSwitch, name: "\(name) Off", subtype: "Off", extra: [
                Characteristic(CharacteristicType.programmableSwitchEvent.with(validValues: [0])),
            ])
        case .light: primary = Service(.lightbulb, name: name, isPrimary: true)
        case .airConditioner:
            let modes = options.flag("hide_automode") ? [1, 2] : [0, 1, 2]
            primary = Service(.heaterCooler, name: name, optional: [], extra: [
                Characteristic(CharacteristicType.targetHeaterCoolerState.with(validValues: modes), value: .int(2)),
                Characteristic(CharacteristicType.currentTemperature, value: .double(24)),
                Characteristic(CharacteristicType.heatingThresholdTemperature.with(
                    minValue: options.number("set_min_heat") ?? 0, maxValue: options.number("set_max_heat") ?? 35, minStep: 0.5), value: .double(24)),
                Characteristic(CharacteristicType.coolingThresholdTemperature.with(
                    minValue: options.number("set_min_cool") ?? 0, maxValue: options.number("set_max_cool") ?? 35, minStep: 0.5), value: .double(24)),
                Characteristic(CharacteristicType.rotationSpeed.with(minValue: 1, maxValue: 4, minStep: 1), value: .int(4)),
            ], isPrimary: true)
        case .airPurifier: primary = Service(.airPurifier, name: name, isPrimary: true)
        case .waterHeater: primary = Service(.valve, name: name, isPrimary: true)
        case .vacuumCleaner, .camera: primary = Service(.switch, name: name, isPrimary: true)
        case .others:
            let kind = ControlKind(type: options.string("type"), fallback: .outlet)
            others = kind
            primary = Service(kind.serviceType, name: name, isPrimary: true)
        }
        self.speaker = speaker
        self.offButton = offButton
        self.others = others
        super.init(info: info, link: link, debounce: .zero, logger: logger)
        adopt([primary, speaker, offButton])
        wire()
    }

    private func wire() {
        switch family {
        case .television:
            primary.characteristic(.activeIdentifier).value = .int(1)
            primary.characteristic(.sleepDiscoveryMode).value = .int(1)
            primary[.configuredName]?.value = .string(name)
            primary.characteristic(.active).onWrite { [weak self] value in try await self?.power(value.intValue == 1) }
            primary[.remoteKey]?.onWrite { [weak self] value in
                self?.logger.debug("\(self?.info.type ?? "") \(self?.name ?? ""): remote key \(value.intValue ?? -1) has no IR command")
            }
            speaker?[.active]?.value = .int(1)
            speaker?[.volumeControlType]?.value = .int(3)
            speaker?[.volumeSelector]?.onWrite { [weak self] value in
                try await self?.detail(Command(command: value.intValue == 0 ? "volumeAdd" : "volumeSub"))
            }
        case .fan:
            primary.characteristic(.active).onWrite { [weak self] value in try await self?.power(value.intValue == 1) }
            primary[.swingMode]?.onWrite { [weak self] _ in
                try await self?.power(true)
                try await self?.detail(Command(command: "swing"))
            }
            let speed = primary[.rotationSpeed]
            speed?.onWrite { [weak self] value in
                let previous = speed?.value.doubleValue ?? 0
                if (value.doubleValue ?? 0) > previous {
                    try await self?.detail(Command(command: "highSpeed"))
                    try await self?.power(true)
                } else {
                    try await self?.detail(Command(command: "lowSpeed"))
                }
            }
        case .light where offButton != nil:
            for (button, on) in [(primary, true), (offButton!, false)] {
                button.characteristic(.programmableSwitchOutputState).onWrite { [weak self] value in
                    guard value.intValue == 1 else { return }
                    try await self?.power(on)
                    button.characteristic(.programmableSwitchEvent).sendEvent(.int(0))
                    button.characteristic(.programmableSwitchOutputState).revert(to: .int(0), after: .milliseconds(500))
                }
            }
        case .light, .vacuumCleaner, .camera:
            primary.characteristic(.on).onWrite { [weak self] value in try await self?.power(value.boolValue ?? false) }
        case .airPurifier:
            primary.characteristic(.active).onWrite { [weak self] value in
                guard let self else { return }
                try await power(value.intValue == 1)
                primary.characteristic(.currentAirPurifierState).value = .int(value.intValue == 1 ? 2 : 0)
            }
        case .waterHeater:
            primary.characteristic(.active).onWrite { [weak self] value in
                guard let self else { return }
                try await power(value.intValue == 1)
                primary.characteristic(.inUse).value = .int(value.intValue == 1 ? 1 : 0)
            }
        case .airConditioner:
            wireAirConditioner()
        case .others:
            guard let others else { return }
            primary.characteristic(others.written).onWrite { [weak self] value in
                guard let self else { return }
                guard options.flag("customize") else {
                    logger.error("\(info.type) \(name): an Others remote needs customize and the learned buttons customOn and customOff")
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
                let on = others.isOn(value)
                try await power(on)
                others.show(on, on: primary)
            }
        }
    }

    // MARK: Commands

    /// The on or off command (`customOn`/`customOff` with `customize`), unless `disablePushOn`/`disablePushOff`.
    func power(_ on: Bool) async throws {
        guard !options.flag(on ? "disablePushOn" : "disablePushOff") else { return }
        let customize = options.flag("customize")
        let name = customize ? options.string(on ? "customOn" : "customOff") ?? (on ? "turnOn" : "turnOff") : (on ? "turnOn" : "turnOff")
        try await send([Command(command: name, commandType: customize ? options.string("commandType") ?? "customize" : "command")])
    }

    /// Any other command, unless `disablePushDetail`.
    func detail(_ command: Command) async throws {
        guard !options.flag("disablePushDetail") else { return }
        try await send([command])
    }

    // MARK: Air conditioner

    private func wireAirConditioner() {
        primary.characteristic(.currentHeaterCoolerState).value = .int(0)
        primary.characteristic(.currentTemperature).onRead { [weak self] in
            .double(self?.meterTemperature() ?? self?.primary.characteristic(.currentTemperature).value.doubleValue ?? 24)
        }
        primary.characteristic(.active).onWrite { [weak self] value in
            guard let self else { return }
            let on = value.intValue == 1
            lock.withLock { climate.active = on }
            if on, options.flag("disablePushOn") {
                try await setAll()
            } else {
                try await power(on)
            }
            showClimateState()
        }
        primary.characteristic(.targetHeaterCoolerState).onWrite { [weak self] value in
            try await self?.settleThenSetAll { self?.climate.mode = value.intValue ?? 2 }
        }
        for type in [CharacteristicType.heatingThresholdTemperature, .coolingThresholdTemperature] {
            primary.characteristic(type).onWrite { [weak self] value in
                try await self?.settleThenSetAll { self?.climate.threshold = value.doubleValue ?? 24 }
            }
        }
        primary.characteristic(.rotationSpeed).onWrite { [weak self] value in
            try await self?.settleThenSetAll { self?.climate.speed = min(max(value.intValue ?? 4, 1), 4) }
        }
    }

    private let climateGuard = LatestCallGuard(delay: .zero)

    private func settleThenSetAll(_ record: () -> Void) async throws {
        lock.withLock(record)
        let isLatest = climateGuard.claim()
        try await Task.sleep(for: settle)
        guard isLatest() else { return }
        try await setAll()
        showClimateState()
    }

    /// `setAll` with `<°C>,<mode>,<fan>,<on|off>`: auto is mode 1 at 25 °C, cool 2, heat 5; HomeKit's speed 4 is the
    /// fan's auto (1), 1 to 3 are low, medium and high (2 to 4).
    static func setAllParameter(active: Bool, mode: Int, threshold: Double, speed: Int) -> String {
        let (code, temperature): (Int, Double) = switch mode {
        case 0: (1, 25)
        case 1: (5, threshold)
        default: (2, threshold)
        }
        let fan = speed >= 4 ? 1 : max(speed, 1) + 1
        let degrees = temperature.rounded() == temperature ? String(Int(temperature)) : String(temperature)
        return "\(degrees),\(code),\(fan),\(active ? "on" : "off")"
    }

    private func setAll() async throws {
        guard !options.flag("disablePushDetail") else { return }
        let climate = lock.withLock { self.climate }
        try await send([Command(command: "setAll", parameter: Self.setAllParameter(
            active: climate.active, mode: climate.mode, threshold: climate.threshold, speed: climate.speed))])
    }

    private func showClimateState() {
        let climate = lock.withLock { self.climate }
        let current = meterTemperature() ?? primary.characteristic(.currentTemperature).value.doubleValue ?? 24
        let state: Int
        if !climate.active { state = 0 }
        else if climate.threshold < current && climate.mode != 1 { state = 3 }
        else if climate.threshold > current && climate.mode != 2 { state = 2 }
        else { state = 1 }
        primary.characteristic(.currentHeaterCoolerState).value = .int(state)
    }
}
