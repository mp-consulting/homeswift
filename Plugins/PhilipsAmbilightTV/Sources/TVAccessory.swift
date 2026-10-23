import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

/// Builds the HomeKit accessory of a television and keeps it in step with the device.
///
/// A Television service with its inputs and speaker linked, an Ambilight lightbulb, and the optional
/// switches and sensors the configuration asks for. The subtypes are those of the Homebridge plugin, so
/// the services keep their identity.
enum TVAccessory {
    struct Binding: Sendable {
        let accessory: Accessory
        /// Pushes a change of the device into the characteristics.
        let apply: @Sendable (TVDevice.Change) -> Void
        /// Adaptive Lighting on the Ambilight light, kept alive as long as the binding.
        let adaptiveLighting: AdaptiveLightingController?

        /// Pushes the device's whole state: what changed while the accessory was being built.
        func sync(with device: TVDevice) async {
            apply(.power(await device.isOn))
            apply(.ambilight(await device.ambilight))
            apply(.mute(await device.muted))
            let identifier = await device.currentIdentifier
            let isOn = await device.isOn
            apply(.input(identifier: identifier, id: isOn ? await device.inputs.first { $0.identifier == identifier }?.id : nil))
            apply(.hueLamp(await device.hueLampOn))
        }
    }

    /// Makes Adaptive Lighting for the Ambilight light, its state restored and saved (the plugin's context).
    typealias AdaptiveLightingFactory = @Sendable (_ lightbulb: Service) -> AdaptiveLightingController

    static func make(device: TVDevice, idPrefix: String, logger: Logger, adaptiveLighting: AdaptiveLightingFactory? = nil) async -> Binding {
        let settings = device.settings
        let inputs = await device.inputs
        let currentIdentifier = await device.currentIdentifier
        let isOn = await device.isOn
        let muted = await device.muted
        let ambilight = await device.ambilight
        let hueOn = await device.hueLampOn
        let name = settings.name

        // The television itself.
        let inputServices = inputs.map { input -> Service in
            let type = switch input.data.type {
            case .source: input.id == JointSpace.homeURI ? HAPConstants.InputSourceType.homeScreen : HAPConstants.InputSourceType.hdmi
            case .app: HAPConstants.InputSourceType.application
            case .channel: HAPConstants.InputSourceType.tuner
            }
            let visibility = input.hidden ? HAPConstants.CurrentVisibilityState.hidden : HAPConstants.CurrentVisibilityState.shown
            let service = Service(.inputSource, name: input.configuredName, subtype: "input-\(input.identifier)", optional: [.identifier, .targetVisibilityState])
            service.characteristic(.configuredName).value = .string(input.configuredName)
            service.characteristic(.inputSourceType).value = .int(type)
            service.characteristic(.isConfigured).value = .int(HAPConstants.IsConfigured.configured)
            service.characteristic(.currentVisibilityState).value = .int(visibility)
            service.characteristic(.targetVisibilityState).value = .int(visibility)
            service.characteristic(.identifier).value = .int(input.identifier)
            let identifier = input.identifier
            service.characteristic(.configuredName).onWrite { value in
                guard let name = value.stringValue else { return }
                await device.renameInput(identifier: identifier, to: name)
            }
            service.characteristic(.targetVisibilityState).onWrite { value in
                let hidden = value.intValue == HAPConstants.CurrentVisibilityState.hidden
                service.characteristic(.currentVisibilityState).value = .int(hidden ? HAPConstants.CurrentVisibilityState.hidden : HAPConstants.CurrentVisibilityState.shown)
                await device.setInputHidden(identifier: identifier, hidden: hidden)
            }
            return service
        }

        let speaker = Service(.televisionSpeaker, name: "\(name) Speaker", optional: [.active, .volumeControlType, .volumeSelector])
        speaker.characteristic(.mute).value = .bool(muted)
        speaker.characteristic(.active).value = .int(HAPConstants.Active.active)
        speaker.characteristic(.volumeControlType).value = .int(HAPConstants.VolumeControlType.relative)
        speaker.characteristic(.mute).onWrite { value in try await device.setMuted(value.boolValue ?? false) }
        speaker.characteristic(.volumeSelector).onWrite { value in try await device.volume(up: value.intValue == HAPConstants.VolumeSelector.increment) }

        let ambilightService = Service(
            .lightbulb, name: "Ambilight", subtype: "ambilight", optional: [.brightness, .hue, .saturation],
            extra: [
                Characteristic(.colorTemperature.with(minValue: Double(TVDevice.colorTemperatureRange.lowerBound), maxValue: Double(TVDevice.colorTemperatureRange.upperBound)), value: .int(ambilight.colorTemperature)),
                Characteristic(.configuredName, value: .string("Ambilight")),
            ])
        applyAmbilight(ambilight, to: ambilightService)
        // Adaptive Lighting in automatic mode, as the Homebridge plugin has it: the controller writes the colour
        // temperature every minute, which the TV takes only while it shows a colour.
        let adaptive = adaptiveLighting?(ambilightService)
        ambilightService.characteristic(.on).onWrite { value in try await device.setAmbilight(on: value.boolValue ?? false) }
        ambilightService.characteristic(.brightness).onWrite(changesOnly: true) { value in try await device.setAmbilightBrightness(value.intValue ?? 100) }
        ambilightService.characteristic(.hue).onWrite(changesOnly: true) { value in try await device.setAmbilightHue(value.doubleValue ?? 0) }
        ambilightService.characteristic(.saturation).onWrite(changesOnly: true) { value in try await device.setAmbilightSaturation(value.doubleValue ?? 0) }
        ambilightService.characteristic(.colorTemperature).onWrite(changesOnly: true) { value in
            try await device.setAmbilightColorTemperature(value.intValue ?? 280, adaptiveLighting: adaptive?.isAdaptiveLightingActive ?? false)
        }

        let television = Service(
            .television, name: name, optional: [.displayOrder, .currentMediaState],
            linked: inputServices + [speaker, ambilightService], isPrimary: true)
        television.characteristic(.active).value = .int(isOn ? HAPConstants.Active.active : HAPConstants.Active.inactive)
        television.characteristic(.activeIdentifier).value = .int(currentIdentifier)
        television.characteristic(.configuredName).value = .string(name)
        television.characteristic(.sleepDiscoveryMode).value = .int(HAPConstants.SleepDiscoveryMode.alwaysDiscoverable)
        television.characteristic(.displayOrder).value = .string(await device.displayOrder)
        // The TV does not report playback; the Homebridge plugin says interrupted.
        television.characteristic(.currentMediaState).value = .int(HAPConstants.CurrentMediaState.interrupted)
        television.characteristic(.active).onWrite { value in try await device.setPower(value.intValue == HAPConstants.Active.active) }
        television.characteristic(.activeIdentifier).onWrite { value in try await device.selectInput(identifier: value.intValue ?? 0) }
        television.characteristic(.remoteKey).onWrite { value in await device.remoteKey(value.intValue ?? -1) }

        // Switches and sensors. Source switches for the inputs shown in the Home app only, as the Homebridge
        // plugin builds them; a change of visibility takes effect at the next rebuild (new inputs, a restart).
        var sourceSwitches: [String: Service] = [:]
        if settings.sourceSwitches {
            for input in inputs where !input.hidden {
                let label = await device.switchName(for: input.id) ?? input.name
                let service = Service(.switch, name: "\(name) \(input.name)", subtype: "source-switch-\(input.id)", extra: [Characteristic(.configuredName, value: .string(label))])
                service.characteristic(.on).value = .bool(input.identifier == currentIdentifier && isOn)
                let id = input.id
                service.characteristic(.on).onWrite { value in
                    if value.boolValue == true {
                        try await device.selectSource(id: id)
                    } else if await device.currentIdentifier == input.identifier {
                        // The source is still active: the switch goes back on.
                        Task {
                            try? await Task.sleep(for: .milliseconds(100))
                            service.characteristic(.on).value = .bool(true)
                        }
                    }
                }
                service.characteristic(.configuredName).onWrite { value in
                    guard let name = value.stringValue else { return }
                    await device.renameSwitch(id: id, to: name)
                }
                sourceSwitches[input.id] = service
            }
        }

        var hueSwitch: Service?
        if settings.ambilightHueSwitch {
            let service = Service(.switch, name: "\(name) Ambilight Plus Hue", subtype: "ambilight-hue-switch", extra: [Characteristic(.configuredName, value: .string("Ambilight Plus Hue"))])
            service.characteristic(.on).value = .bool(hueOn)
            service.characteristic(.on).onRead { .bool(await device.hueLampState()) }
            service.characteristic(.on).onWrite { value in try await device.setHueLamp(value.boolValue ?? false) }
            hueSwitch = service
        }

        var buttons: [Service] = []
        var seenKeys = Set<String>()
        for button in settings.customButtons where seenKeys.insert(button.key).inserted {
            let service = Service(.switch, name: "\(name) \(button.name)", subtype: "custom-button-\(button.key)", extra: [Characteristic(.configuredName, value: .string(button.name))])
            service.characteristic(.on).value = .bool(false)
            let key = button.key
            service.characteristic(.on).onWrite { value in
                guard value.boolValue == true else { return }
                // Momentary: the switch shows on for a second so the tap registers, then goes back off.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    service.characteristic(.on).value = .bool(false)
                }
                try await device.sendKey(key)
            }
            buttons.append(service)
        }

        var sensors: [TVSettings.StateSensor: Service] = [:]
        for sensor in settings.stateSensors where sensors[sensor] == nil {
            let service = Service(.motionSensor, name: "\(name) \(sensor.label)", subtype: "state-sensor-\(sensor.rawValue)", extra: [Characteristic(.configuredName, value: .string("\(name) \(sensor.label)"))])
            let active = switch sensor {
            case .power: isOn
            case .ambilight: ambilight.on
            case .mute: muted
            }
            service.characteristic(.motionDetected).value = .bool(active)
            sensors[sensor] = service
        }

        var services: [Service] = [television]
        services += inputServices
        services += [speaker, ambilightService]
        services += sourceSwitches.values.sorted { ($0.subtype ?? "") < ($1.subtype ?? "") }
        if let hueSwitch { services.append(hueSwitch) }
        services += buttons
        services += sensors.values.sorted { ($0.subtype ?? "") < ($1.subtype ?? "") }
        let accessory = Accessory(
            id: "\(idPrefix):\(settings.mac)", name: name, manufacturer: "Philips", model: "Ambilight TV", serialNumber: settings.mac,
            firmwareRevision: "1.0", category: .television, services: services)

        let switches = sourceSwitches
        let sensorServices = sensors
        let hueService = hueSwitch
        let apply: @Sendable (TVDevice.Change) -> Void = { change in
            switch change {
            case .power(let on):
                television.characteristic(.active).value = .int(on ? HAPConstants.Active.active : HAPConstants.Active.inactive)
                sensorServices[.power]?.characteristic(.motionDetected).value = .bool(on)
                if !on {
                    // Standby: Ambilight and mute sensors clear, the source and Ambilight+hue switches go off.
                    sensorServices[.ambilight]?.characteristic(.motionDetected).value = .bool(false)
                    sensorServices[.mute]?.characteristic(.motionDetected).value = .bool(false)
                    for service in switches.values { service.characteristic(.on).value = .bool(false) }
                    hueService?.characteristic(.on).value = .bool(false)
                }
            case .ambilight(let state):
                // Following video or audio again (from the TV's menu or remote) ends Adaptive Lighting, as a colour
                // picked elsewhere does.
                if state.on, let style = state.style, style != "FOLLOW_COLOR", let adaptive, adaptive.isAdaptiveLightingActive {
                    adaptive.disableAdaptiveLighting()
                }
                applyAmbilight(state, to: ambilightService)
                sensorServices[.ambilight]?.characteristic(.motionDetected).value = .bool(state.on)
            case .mute(let muted):
                speaker.characteristic(.mute).value = .bool(muted)
                sensorServices[.mute]?.characteristic(.motionDetected).value = .bool(muted)
            case .input(let identifier, let id):
                television.characteristic(.activeIdentifier).value = .int(identifier)
                for (sourceID, service) in switches {
                    service.characteristic(.on).value = .bool(sourceID == id)
                }
            case .hueLamp(let on):
                hueService?.characteristic(.on).value = .bool(on)
            case .inputs:
                break
            }
        }
        return Binding(accessory: accessory, apply: apply, adaptiveLighting: adaptive)
    }

    private static func applyAmbilight(_ state: TVDevice.AmbilightState, to service: Service) {
        service.characteristic(.on).value = .bool(state.on)
        service.characteristic(.brightness).value = .int(state.brightness)
        service.characteristic(.hue).value = .double(state.hue)
        service.characteristic(.saturation).value = .double(state.saturation)
        service.characteristic(.colorTemperature).value = .int(state.colorTemperature)
    }
}
