import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A chime (docs/clean-room/Ring.md, 4.5): Snooze, Play Ding and Play Motion switches, its volume (0…11) and its
/// nightlight.
enum RingChime {
    static func make(data: JSONValue, environment: RingEnvironment) -> RingBuiltAccessory {
        let id = data["id"]?.idString ?? ""
        let name = data["description"]?.stringValue ?? "Ring Chime"
        let client = environment.client, logger = environment.logger
        func refreshingRead(_ characteristic: Characteristic) {
            characteristic.onRead {
                environment.requestRefresh()
                return characteristic.value
            }
        }

        let snooze = Service(.switch, name: "\(name) Snooze", subtype: "snooze", isPrimary: true)
        refreshingRead(snooze.characteristic(.on))
        snooze.characteristic(.on).onWrite { value in
            let on = value.boolValue ?? false
            logger.info(on ? "\(name) snoozed for 24 hours" : "\(name) snooze cleared")
            environment.background("Snoozing \(name)") {
                try await client.snoozeChime(id, minutes: on ? 1440 : nil)
                environment.requestRefresh()
            }
        }

        let speaker = Service(.speaker, name: name, optional: [.volume.with(minValue: 0, maxValue: 11, minStep: 1)])
        speaker.characteristic(.mute).value = .bool(false)
        speaker.characteristic(.mute).onWrite { _ in speaker.characteristic(.mute).value = .bool(false) }
        refreshingRead(speaker.characteristic(.volume))
        let level = RingLevel(debounce: environment.timing.levelDebounce)
        speaker.characteristic(.volume).onWrite { value in
            let volume = value.doubleValue ?? 0
            guard (0...11).contains(volume) else { return }
            environment.background("Setting the volume of \(name)") {
                try await level.write(volume) { try await client.put("chimes/\(id)/", body: ["chime": ["settings": ["volume": .number($0.rounded())]]]) }
                environment.requestRefresh()
            }
        }

        func player(_ kind: String, subtype: String, label: String) -> Service {
            let service = Service(.switch, name: "\(name) \(label)", subtype: subtype)
            let on = service.characteristic(.on)
            on.onRead { .bool(false) }
            on.onWrite { value in
                guard value.boolValue == true else { return }
                environment.background("Playing \(kind) on \(name)") { try await client.playChime(id, kind: kind) }
                _ = on.revert(to: .bool(false), after: environment.timing.playSwitchReset)
            }
            return service
        }
        let ding = player("ding", subtype: "play-ding", label: "Play Ding")
        let motion = player("motion", subtype: "play-motion", label: "Play Motion")

        var nightlight: Service?
        if data["settings"]?["night_light_settings"]?.objectValue != nil {
            let light = Service(.lightbulb, name: "\(name) Nightlight", subtype: "nightlight")
            refreshingRead(light.characteristic(.on))
            light.characteristic(.on).onWrite { value in
                let on = value.boolValue ?? false
                logger.info("\(name) nightlight \(on ? "enabled" : "disabled")")
                environment.background("Setting the nightlight of \(name)") {
                    try await client.setChimeNightlight(id, on: on)
                    environment.requestRefresh()
                }
            }
            nightlight = light
        }

        let nightlightService = nightlight
        let show: @Sendable (JSONValue) -> Void = { data in
            snooze.characteristic(.on).show(.bool((data["do_not_disturb"]?["seconds_left"]?.looseDouble ?? 0) > 0))
            if let volume = level.shown(data["settings"]?["volume"]?.looseDouble) {
                speaker.characteristic(.volume).show(.int(Int(saturating: volume, in: 0...11) ?? 0))
            }
            nightlightService?.characteristic(.on).show(.bool(data["settings"]?["night_light_settings"]?["light_sensor_enabled"]?.boolValue == true))
        }
        let kind = data["kind"]?.stringValue ?? "chime"
        let accessory = Accessory(
            id: RingPlugin.accessoryID(seed: id), name: name, manufacturer: "Ring", model: RingModels.chime(kind),
            serialNumber: data["device_id"]?.stringValue ?? "Unknown", category: .other,
            services: [snooze, speaker, ding, motion, nightlight].compactMap { $0 })
        show(data)
        return RingBuiltAccessory(seed: id, deviceType: kind, accessory: accessory, update: show)
    }
}

/// A location's mode (Ring Modes, for locations with cameras and no alarm), as a Security System (4.5).
final class RingLocationMode: Sendable {
    let locationID: String
    let name: String
    private let environment: RingEnvironment
    let service: Service
    let accessory: Accessory
    private let state = NIOLockedValueBox<(mode: String?, target: Int?, sequence: Int)>((nil, nil, 0))

    init(locationID: String, locationName: String, mode: String, environment: RingEnvironment) {
        self.locationID = locationID
        name = "\(locationName) Mode"
        self.environment = environment
        service = Service(.securitySystem, name: name, optional: [.securitySystemTargetState.with(validValues: [0, 1, 3])], isPrimary: true)
        accessory = Accessory(
            id: RingPlugin.accessoryID(seed: "\(locationID)mode"), name: name, manufacturer: "Ring", model: "Location Mode", serialNumber: "N/A",
            category: .securitySystem, services: [service])
        received(mode)
        service.characteristic(.securitySystemCurrentState).onRead { [weak self] in
            self?.fetchInBackground()
            return self?.service.characteristic(.securitySystemCurrentState).value ?? .int(3)
        }
        service.characteristic(.securitySystemTargetState).onWrite { [weak self] value in self?.write(value.intValue ?? 3) }
    }

    static func state(of mode: String?) -> Int {
        switch mode {
        case "away": 1
        case "home": 0
        default: 3
        }
    }

    /// A fetched mode: the current state, and the target once it matches.
    func received(_ mode: String) {
        let current = Self.state(of: mode)
        let target = state.withLockedValue { state -> Int in
            state.mode = mode
            if state.target == current { state.target = nil }
            return state.target ?? current
        }
        service.characteristic(.securitySystemCurrentState).show(.int(current))
        service.characteristic(.securitySystemTargetState).show(.int(target))
    }

    func fetch() async throws {
        let response = try await environment.client.locationMode(locationID)
        environment.logger.debug("Location mode of \(name): \(response["mode"]?.stringValue ?? "none")")
        if let mode = response["mode"]?.stringValue { received(mode) }
    }

    private func fetchInBackground() {
        environment.tasks.add { [weak self] in try? await self?.fetch() }
    }

    private func write(_ requested: Int) {
        let sequence = state.withLockedValue { state -> Int in
            state.sequence += 1
            return state.sequence
        }
        let environment = environment, name = name, locationID = locationID
        environment.tasks.add { [weak self] in
            guard let self else { return }
            var target = requested
            if target == 2 {
                target = 0
                let service = service
                try? await Task.sleep(for: environment.timing.locationModeTargetPush)
                service.characteristic(.securitySystemTargetState).value = .int(0)
            }
            do {
                try await fetch()
                let current = Self.state(of: state.withLockedValue { $0.mode })
                guard state.withLockedValue({ $0.sequence }) == sequence, target != current else { return }
                state.withLockedValue { $0.target = target }
                let mode = target == 1 ? "away" : target == 3 ? "disarmed" : "home"
                environment.logger.info("Setting \(name) to \(mode)")
                let response = try await environment.client.setLocationMode(locationID, mode)
                if let mode = response["mode"]?.stringValue { received(mode) }
            } catch {
                guard state.withLockedValue({ $0.sequence }) == sequence else { return }
                environment.logger.error("Failed to set \(name): \(error)")
                let current = state.withLockedValue { state -> Int in
                    state.target = nil
                    return Self.state(of: state.mode)
                }
                service.characteristic(.securitySystemTargetState).value = .int(current)
            }
        }
    }
}
