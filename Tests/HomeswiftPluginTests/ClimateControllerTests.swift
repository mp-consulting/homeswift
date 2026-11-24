import Foundation
import Homeswift
@testable import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

/// The one climate mapping (docs/adr/0013-climate-is-mapped-once.md), through the service's characteristics as Apple
/// Home writes and reads them: each Setpoint Kind, Other Modes, power, writes while off, gathered writes and failures.
@Suite(.timeLimit(.minutes(1)))
struct ClimateControllerTests {
    /// A device behind a controller: the commands it was sent, and an error to fail the next one with.
    final class Unit: Sendable {
        let commands = NIOLockedValueBox<[ClimateCommand]>([])
        let failure = NIOLockedValueBox<(any Error)?>(nil)
        /// How long the device takes to answer: commands overlap with writes that come meanwhile.
        let delay = NIOLockedValueBox<Duration>(.zero)
        /// Commands being sent now: never more than one.
        let inFlight = NIOLockedValueBox(0)
        let overlapped = NIOLockedValueBox(false)
        var sent: [ClimateCommand] { commands.withLockedValue { $0 } }

        func controller(_ kind: ClimateServiceKind, _ capabilities: ClimateCapabilities) -> ClimateController {
            ClimateController(kind, name: "Living room", capabilities: capabilities, window: .milliseconds(5)) { [self] command in
                inFlight.withLockedValue { count in
                    count += 1
                    if count > 1 { overlapped.withLockedValue { $0 = true } }
                }
                defer { inFlight.withLockedValue { $0 -= 1 } }
                let delay = delay.withLockedValue { $0 }
                if delay > .zero { try await Task.sleep(for: delay) }
                if let error = failure.withLockedValue({ $0 }) { throw error }
                commands.withLockedValue { $0.append(command) }
            }
        }
    }

    static let airConditioner = ClimateCapabilities(modes: [.heat, .cool, .auto], range: 16...30)

    @Test func heaterCoolerOffersTheModesTheDeviceHas() {
        let unit = Unit()
        let all = unit.controller(.heaterCooler, Self.airConditioner).service
        #expect(all[.targetHeaterCoolerState]?.type.validValues == [0, 1, 2])
        #expect(all[.heatingThresholdTemperature]?.type.minValue == 16 && all[.coolingThresholdTemperature]?.type.maxValue == 30)
        let heater = unit.controller(.heaterCooler, ClimateCapabilities(modes: [.heat], range: 5...30, step: 1)).service
        #expect(heater[.targetHeaterCoolerState]?.type.validValues == [1])
        #expect(heater[.heatingThresholdTemperature]?.type.minStep == 1 && heater[.coolingThresholdTemperature] == nil)
        let thermostat = unit.controller(.thermostat, ClimateCapabilities(modes: [.heat], canTurnOff: true)).service
        #expect(thermostat[.targetHeatingCoolingState]?.type.validValues == [0, 1])
        #expect(thermostat[.heatingThresholdTemperature] == nil && thermostat[.targetTemperature] != nil)
    }

    /// Rule 1: a device in auto stays Auto; rule 2: only the current state is guessed.
    @Test func autoStaysAutoAndTheCurrentStateIsGuessed() {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        let service = climate.service
        climate.update(ClimateReport(power: true, mode: .auto, current: 18, target: 22))
        #expect(service[.targetHeaterCoolerState]?.value == .int(0))
        #expect(service[.currentHeaterCoolerState]?.value == .int(2))
        climate.update(ClimateReport(power: true, mode: .auto, current: 25, target: 22))
        #expect(service[.targetHeaterCoolerState]?.value == .int(0))
        #expect(service[.currentHeaterCoolerState]?.value == .int(3))
        climate.update(ClimateReport(power: true, mode: .auto, action: .idle, current: 25, target: 22))
        #expect(service[.currentHeaterCoolerState]?.value == .int(1))
        climate.update(ClimateReport(power: false, mode: .auto, current: 25, target: 22))
        #expect(service[.currentHeaterCoolerState]?.value == .int(0) && service[.active]?.value == .int(0))
        #expect(service[.targetHeaterCoolerState]?.value == .int(0))
    }

    /// Rule 3: an Other Mode keeps the target and shows idle.
    @Test func anOtherModeKeepsTheTarget() {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        climate.update(ClimateReport(power: true, mode: .cool, current: 28, target: 24))
        #expect(climate.service[.targetHeaterCoolerState]?.value == .int(2))
        climate.update(ClimateReport(power: true, mode: nil, current: 28, target: 24))
        #expect(climate.service[.targetHeaterCoolerState]?.value == .int(2))
        #expect(climate.service[.currentHeaterCoolerState]?.value == .int(1))
    }

    /// Rule 6: a Single setpoint shows its Auto Band, and the one written while its middle is the target.
    @Test func singleSetpointShowsItsAutoBand() async throws {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        let service = climate.service
        climate.update(ClimateReport(power: true, mode: .auto, current: 21, target: 22))
        #expect(service[.heatingThresholdTemperature]?.value == .double(21) && service[.coolingThresholdTemperature]?.value == .double(23))
        // One change of the range: both thresholds, one command with their middle.
        async let low: Void = service.characteristic(.heatingThresholdTemperature).write(.double(18))
        async let high: Void = service.characteristic(.coolingThresholdTemperature).write(.double(24))
        _ = try await (low, high)
        #expect(unit.sent == [ClimateCommand(target: 21)])
        climate.update(ClimateReport(power: true, mode: .auto, current: 21, target: 21))
        #expect(service[.heatingThresholdTemperature]?.value == .double(18) && service[.coolingThresholdTemperature]?.value == .double(24))
        // The target changed elsewhere: the band follows it.
        climate.update(ClimateReport(power: true, mode: .auto, current: 21, target: 25))
        #expect(service[.heatingThresholdTemperature]?.value == .double(24) && service[.coolingThresholdTemperature]?.value == .double(26))
        // In heat, both thresholds are the target, and the heating one writes it.
        climate.update(ClimateReport(power: true, mode: .heat, current: 21, target: 25))
        #expect(service[.heatingThresholdTemperature]?.value == .double(25) && service[.coolingThresholdTemperature]?.value == .double(25))
        try await service.characteristic(.heatingThresholdTemperature).write(.double(20.4))
        #expect(unit.sent.last == ClimateCommand(target: 20.5))
    }

    /// Rule 4: a Heater Cooler's mode never turns it on; a Thermostat's mode does.
    @Test func powerIsActiveOnAHeaterCoolerAndOffOnAThermostat() async throws {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        climate.update(ClimateReport(power: false, mode: .cool, current: 28, target: 24))
        try await climate.service.characteristic(.targetHeaterCoolerState).write(.int(0))
        #expect(unit.sent == [ClimateCommand(mode: .auto)])
        async let active: Void = climate.service.characteristic(.active).write(.int(1))
        async let mode: Void = climate.service.characteristic(.targetHeaterCoolerState).write(.int(1))
        _ = try await (active, mode)
        #expect(unit.sent.last == ClimateCommand(power: true, mode: .heat))

        let thermostatUnit = Unit()
        let thermostat = thermostatUnit.controller(.thermostat, ClimateCapabilities(modes: [.heat, .cool, .auto], setpoints: .range))
        thermostat.update(ClimateReport(power: false, mode: .heat, current: 18, target: 20, heating: 19, cooling: 24))
        #expect(thermostat.service[.targetHeatingCoolingState]?.value == .int(0))
        try await thermostat.service.characteristic(.targetHeatingCoolingState).write(.int(1))
        // The turn-on carries the mode chosen, whatever the device said while off.
        #expect(thermostatUnit.sent == [ClimateCommand(power: true, mode: .heat)])
        try await thermostat.service.characteristic(.targetHeatingCoolingState).write(.int(0))
        #expect(thermostatUnit.sent.last == ClimateCommand(power: false))
    }

    /// Rule 5: a device that refuses setpoints while off gets them with the next turn-on.
    @Test func setpointsWrittenWhileOffAreHeldForTheTurnOn() async throws {
        let unit = Unit()
        let capabilities = ClimateCapabilities(modes: [.heat, .cool, .auto], range: 16...30, whileOff: .holds)
        let climate = unit.controller(.heaterCooler, capabilities)
        climate.update(ClimateReport(power: false, mode: .cool, current: 28, target: 24))
        try await climate.service.characteristic(.coolingThresholdTemperature).write(.double(22))
        #expect(unit.sent.isEmpty)
        climate.update(ClimateReport(power: false, mode: .cool, current: 28, target: 24))
        #expect(climate.service[.coolingThresholdTemperature]?.value == .double(22))
        try await climate.service.characteristic(.active).write(.int(1))
        #expect(unit.sent == [ClimateCommand(power: true, target: 22)])

        // Turned on elsewhere: the held setpoint goes out then.
        let other = Unit()
        let remote = other.controller(.heaterCooler, capabilities)
        remote.update(ClimateReport(power: false, mode: .heat, current: 18, target: 20))
        try await remote.service.characteristic(.heatingThresholdTemperature).write(.double(23))
        remote.update(ClimateReport(power: true, mode: .heat, current: 18, target: 20))
        #expect(await eventually { other.sent == [ClimateCommand(target: 23)] })
    }

    @Test func aRangeDeviceTakesItsLowAndHighTogether() async throws {
        let unit = Unit()
        let climate = unit.controller(.thermostat, ClimateCapabilities(modes: [.heat, .cool, .auto], setpoints: .range, range: 10...32))
        let service = climate.service
        climate.update(ClimateReport(power: true, mode: .auto, current: 21, target: 20, heating: 19, cooling: 25))
        #expect(service[.targetTemperature]?.value == .double(22))
        try await service.characteristic(.coolingThresholdTemperature).write(.double(26))
        #expect(unit.sent == [ClimateCommand(heating: 19, cooling: 26)])
        // Target Temperature in auto moves the range, keeping its width.
        try await service.characteristic(.targetTemperature).write(.double(23.5))
        #expect(unit.sent.last == ClimateCommand(heating: 20, cooling: 27))
        // In heat, the target.
        try await service.characteristic(.targetHeatingCoolingState).write(.int(1))
        try await service.characteristic(.targetTemperature).write(.double(21))
        #expect(unit.sent.suffix(2) == [ClimateCommand(mode: .heat), ClimateCommand(target: 21)])
    }

    @Test func separateSetpointsKeepTheAutoSetpointAtTheirMiddle() async throws {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, ClimateCapabilities(modes: [.heat, .cool, .auto], setpoints: .separate(autoSetpoint: true),
                                                                        heatingRange: 10...30, coolingRange: 18...32))
        let service = climate.service
        climate.update(ClimateReport(power: true, mode: .auto, current: 21, target: 22, heating: 20, cooling: 24))
        async let low: Void = service.characteristic(.heatingThresholdTemperature).write(.double(19))
        async let high: Void = service.characteristic(.coolingThresholdTemperature).write(.double(26))
        _ = try await (low, high)
        #expect(unit.sent == [ClimateCommand(target: 22.5, heating: 19, cooling: 26)])
        // An unchanged threshold sends nothing, not even the auto setpoint when it moved elsewhere.
        try await service.characteristic(.heatingThresholdTemperature).write(.double(19))
        #expect(unit.sent.count == 1)
        climate.update(ClimateReport(power: true, mode: .auto, current: 21, target: 23, heating: 19, cooling: 26))
        try await service.characteristic(.heatingThresholdTemperature).write(.double(19))
        #expect(unit.sent.count == 1)
        // Without an auto setpoint, only the threshold.
        let plain = Unit()
        let nest = plain.controller(.thermostat, ClimateCapabilities(modes: [.heat, .cool, .auto], setpoints: .separate(autoSetpoint: false)))
        nest.update(ClimateReport(power: true, mode: .cool, current: 26, heating: 19, cooling: 24))
        #expect(nest.service[.targetTemperature]?.value == .double(24))
        try await nest.service.characteristic(.targetTemperature).write(.double(23))
        #expect(plain.sent == [ClimateCommand(cooling: 23)])
    }

    @Test func aFailedCommandPutsTheServiceBackAndFailsTheWrites() async throws {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        climate.update(ClimateReport(power: true, mode: .cool, current: 28, target: 24))
        unit.failure.withLockedValue { $0 = HAPStatusError(.serviceCommunicationFailure) }
        await #expect(throws: HAPStatusError.self) {
            try await climate.service.characteristic(.targetHeaterCoolerState).write(.int(1))
        }
        #expect(climate.service[.targetHeaterCoolerState]?.value == .int(2))
        #expect(climate.report?.mode == .cool)
    }

    /// A write that comes while the device is still answering waits for it, and is built from what it sent.
    @Test func commandsGoOneAtATime() async throws {
        let unit = Unit()
        unit.delay.withLockedValue { $0 = .milliseconds(50) }
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        climate.update(ClimateReport(power: true, mode: .cool, current: 28, target: 24))
        let first = Task { try await climate.service.characteristic(.coolingThresholdTemperature).write(.double(22)) }
        #expect(await eventually { unit.inFlight.withLockedValue { $0 } == 1 })
        try await climate.service.characteristic(.coolingThresholdTemperature).write(.double(26))
        try await first.value
        try await climate.service.characteristic(.coolingThresholdTemperature).write(.double(26))
        #expect(unit.sent == [ClimateCommand(target: 22), ClimateCommand(target: 26)])
        #expect(!unit.overlapped.withLockedValue { $0 })
    }

    /// A slider dragged for longer than the window is one command, when it stops.
    @Test func aDragIsOneCommandWhenItStops() async throws {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        climate.update(ClimateReport(power: true, mode: .cool, current: 28, target: 24))
        var writes: [Task<Void, any Error>] = []
        for value in stride(from: 23.0, through: 20.0, by: -0.5) {
            writes.append(Task { try await climate.service.characteristic(.coolingThresholdTemperature).write(.double(value)) })
            try await Task.sleep(for: .milliseconds(3))
        }
        for write in writes { try await write.value }
        #expect(unit.sent == [ClimateCommand(target: 20)])
    }

    /// A turn-on that fails keeps the setpoints held for it; a failed range leaves the Auto Band as it was.
    @Test func aFailureKeepsWhatWasHeldAndTheBand() async throws {
        let unit = Unit()
        let capabilities = ClimateCapabilities(modes: [.heat, .cool, .auto], range: 16...30, whileOff: .holds)
        let climate = unit.controller(.heaterCooler, capabilities)
        climate.update(ClimateReport(power: false, mode: .auto, current: 20, target: 22))
        try await climate.service.characteristic(.heatingThresholdTemperature).write(.double(19))
        unit.failure.withLockedValue { $0 = HAPStatusError(.serviceCommunicationFailure) }
        await #expect(throws: HAPStatusError.self) { try await climate.service.characteristic(.active).write(.int(1)) }
        unit.failure.withLockedValue { $0 = nil }
        try await climate.service.characteristic(.active).write(.int(1))
        #expect(unit.sent == [ClimateCommand(power: true, target: 21)])

        climate.update(ClimateReport(power: true, mode: .auto, current: 20, target: 22))
        unit.failure.withLockedValue { $0 = HAPStatusError(.serviceCommunicationFailure) }
        await #expect(throws: HAPStatusError.self) { try await climate.service.characteristic(.coolingThresholdTemperature).write(.double(28)) }
        #expect(climate.service[.heatingThresholdTemperature]?.value == .double(21) && climate.service[.coolingThresholdTemperature]?.value == .double(23))
    }

    @Test func aSeparateTargetStaysInItsModesRange() async throws {
        let unit = Unit()
        let climate = unit.controller(.thermostat, ClimateCapabilities(modes: [.heat, .cool], setpoints: .separate(autoSetpoint: false),
                                                                      heatingRange: 10...30, coolingRange: 18...32))
        climate.update(ClimateReport(power: true, mode: .heat, current: 20, heating: 21, cooling: 25))
        try await climate.service.characteristic(.targetTemperature).write(.double(31))
        #expect(unit.sent == [ClimateCommand(heating: 30)])
    }

    @Test func aSingleTargetStaysInItsModesRange() async throws {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, ClimateCapabilities(modes: [.heat, .cool], heatingRange: 16...28, coolingRange: 18...32))
        climate.update(ClimateReport(power: true, mode: .heat, current: 20, target: 22))
        try await climate.service.characteristic(.heatingThresholdTemperature).write(.double(31))
        #expect(unit.sent == [ClimateCommand(target: 28)])
    }

    @Test func aWriteOfTheModeTheDeviceHasSendsNothing() async throws {
        let unit = Unit()
        let climate = unit.controller(.heaterCooler, Self.airConditioner)
        climate.update(ClimateReport(power: true, mode: .heat, current: 18, target: 21))
        try await climate.service.characteristic(.targetHeaterCoolerState).write(.int(1))
        try await climate.service.characteristic(.active).write(.int(1))
        #expect(unit.sent.isEmpty)
        // Auto while in dry: the device's mode differs, so it is sent.
        climate.update(ClimateReport(power: true, mode: nil, current: 18, target: 21))
        try await climate.service.characteristic(.targetHeaterCoolerState).write(.int(1))
        #expect(unit.sent == [ClimateCommand(mode: .heat)])
    }
}

private func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
