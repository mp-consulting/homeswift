import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

// HomeKit has no pan and tilt service: on the lens on the motor (a C675D's tele lens), a "Go to <preset>" switch per
// preset that turns the camera there, then turns itself off, and a Horizontal and a Vertical Patrol switch, the
// camera's sweep along one axis (docs/clean-room/TapoPTZ.md, 5.2 `cruise`), on until turned off or the camera sleeps.
// Like the web UI's pad, they move the camera only while a live view keeps it awake: a switch never wakes it.
// `presetSwitches` and `patrolSwitches` (on by default) choose them; the presets are the ones `ptz.json` keeps, so the
// switches come with the first live view and follow the presets made in the Tapo app.

/// The pan and tilt switches a lens has.
struct TapoPTZSwitches: Sendable, Equatable {
    var presets: [CameraControls.Preset] = []
    var patrol = false

    /// The patrol's axis: the camera's `cruise` coordinate.
    enum Axis: String, Sendable, CaseIterable {
        case horizontal = "x"
        case vertical = "y"

        var label: String { self == .horizontal ? "Horizontal" : "Vertical" }
    }

    /// A switch named in the Home app: HomeKit names an accessory's other services by their Configured Name, and numbers
    /// the ones without it. The name is the switch's alone: the Home app shows it inside the camera already.
    static func switchService(name: String, subtype: String) -> Service {
        let service = Service(.switch, name: name, subtype: subtype, optional: [.configuredName])
        service[.configuredName]?.value = .string(name)
        return service
    }

    /// The services, their writes wired to `actions`.
    func services(name: String, actions: TapoPTZActions, log: Logger) -> (presets: [Service], patrols: [Service]) {
        let presetServices = presets.map { preset -> Service in
            let service = Self.switchService(name: "Go to \(preset.name)", subtype: "preset\(preset.id)")
            let on = service.characteristic(.on)
            on.value = false
            on.onWrite { [weak on] value in
                guard value.boolValue == true else { return }
                do {
                    try await actions.goToPreset(preset.id)
                } catch {
                    log.warning("\(name): cannot go to \(preset.name): \(error)")
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
                // Momentary: off again once the move is sent, whichever lands first, this or the write's own value.
                on?.revert(to: .bool(false), after: actions.momentaryReset)
            }
            return service
        }
        guard patrol else { return (presetServices, []) }
        let patrols = Axis.allCases.map { axis in Self.switchService(name: "\(axis.label) Patrol", subtype: "patrol-\(axis.rawValue)") }
        for (axis, service) in zip(Axis.allCases, patrols) {
            service.characteristic(.on).value = false
            let others = patrols.filter { $0 !== service }
            service.characteristic(.on).onWrite(changesOnly: true) { value in
                let on = value.boolValue ?? false
                do {
                    try await actions.patrol(on ? axis : nil)
                } catch {
                    log.warning("\(name): cannot \(on ? "start" : "stop") the \(axis.label.lowercased()) patrol: \(error)")
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
                // One sweep at a time: starting one ends the other.
                if on { for other in others { other.characteristic(.on).value = false } }
            }
        }
        return (presetServices, patrols)
    }
}

/// What the switches do, on the plugin.
struct TapoPTZActions: Sendable {
    var goToPreset: @Sendable (_ id: String) async throws -> Void
    /// Starts the sweep on an axis, or stops it (nil).
    var patrol: @Sendable (_ axis: TapoPTZSwitches.Axis?) async throws -> Void
    var momentaryReset: Duration
}

extension TapoControl {
    /// The sweep along one axis until `cruiseStop` (TapoPTZ.md 5.2).
    func cruise(_ axis: TapoPTZSwitches.Axis) async throws {
        try await motor("cruiseMove", ["motor": ["cruise": ["coord": axis.rawValue]]])
    }

    func cruiseStop() async throws {
        try await motor("cruiseStop", ["motor": ["cruise_stop": [String: Any]()]])
    }
}

extension TapoPlugin {
    /// The switches a camera's movable lens should have now: from its options and what `ptz.json` keeps of its motor.
    func wantedPTZSwitches(deviceID: String, runtime: TapoCameraRuntime) -> TapoPTZSwitches {
        guard runtime.movableLens != nil, let state = keptPTZ(deviceID), state.supported else { return TapoPTZSwitches() }
        return TapoPTZSwitches(presets: runtime.presetSwitches ? state.presets : [], patrol: runtime.patrolSwitches)
    }

    /// What the movable lens's switches do.
    func ptzActions(lens: String) -> TapoPTZActions {
        TapoPTZActions(
            goToPreset: { [weak self] id in
                guard let self else { return }
                try await self.goToPreset(lens, id)
            },
            patrol: { [weak self] axis in
                guard let self else { return }
                try await self.patrol(lens, axis)
            },
            momentaryReset: scaled(1))
    }

    /// Gives the movable lens the switches it should have, publishing it again when they changed (same id, so HomeKit
    /// keeps its pairing, rooms and the other services' automations). `publish: false` before its first publish.
    func applyPTZSwitches(deviceID: String, publish: Bool = true) async {
        guard let runtime = cameraRuntimes[deviceID], let lens = runtime.movableLens,
              let camera = runtime.cameras.first(where: { $0.accessory.id == lens }) else { return }
        let wanted = wantedPTZSwitches(deviceID: deviceID, runtime: runtime)
        guard wanted != camera.ptzSwitches else { return }
        let accessory = camera.rebuild(wanted, actions: ptzActions(lens: lens))
        guard publish else { return }
        do {
            if runtime.standalone { try await context.publishExternal(accessory) } else { try context.add(accessory) }
            logger.info("\(accessory.name): \(wanted.presets.count) preset switches\(wanted.patrol ? ", patrol switches" : "")")
        } catch {
            logger.warning("Could not publish \(accessory.name) with its pan and tilt switches: \(error)")
        }
    }

    /// A live view woke the camera: its battery, and its motor and presets when it has pan and tilt switches (asked once,
    /// then the presets every `presetRefresh`), so the switches follow the Tapo app.
    func cameraAwake(deviceID: String) async {
        await readBattery(deviceID: deviceID)
        guard let runtime = cameraRuntimes[deviceID], runtime.movableLens != nil, runtime.presetSwitches || runtime.patrolSwitches else { return }
        if keptPTZ(deviceID) == nil { _ = await ptzState(deviceID: deviceID, runtime: runtime) } else { await refreshPresets(deviceID: deviceID, runtime: runtime) }
    }

    /// The camera went back to sleep: a patrol ends with it.
    func cameraAsleep(deviceID: String) {
        for camera in cameraRuntimes[deviceID]?.cameras ?? [] { camera.patrolStopped() }
    }

    /// Starts or stops the sweep of a camera that is awake.
    func patrol(_ id: String, _ axis: TapoPTZSwitches.Axis?) async throws {
        try await withControl(id) { control, _, _, _ in
            if let axis { try await control.cruise(axis) } else { try await control.cruiseStop() }
        }
    }
}
