import Foundation
import Homeswift
import Logging

/// Builds the HomeKit accessory of a light: a lightbulb with brightness and colour temperature, and Adaptive Lighting.
enum KeyLightAccessory {
    /// The accessory, and its Adaptive Lighting: the plugin keeps the controller and saves its schedule.
    static func make(device: KeyLightDevice, name: String, idPrefix: String, logger: Logger? = nil) async -> (accessory: Accessory, adaptiveLighting: AdaptiveLightingController) {
        let state = await device.state
        let temperature = LightState.clamp(temperature: state.temperature ?? LightState.temperatureRange.lowerBound)
        let lightbulb = Service(
            .lightbulb, name: name, optional: [.brightness],
            extra: [
                // The light's range (2900 K to 7000 K) is narrower than HomeKit's default of 140...500 mirek.
                Characteristic(.colorTemperature.with(minValue: 143, maxValue: 344), value: .int(temperature)),
                Characteristic(.configuredName, value: .string(name)),
            ],
            isPrimary: true)
        lightbulb.characteristic(.on).value = .bool(state.on == 1)
        lightbulb.characteristic(.brightness).value = .int(state.brightness ?? 0)

        lightbulb.characteristic(.on)
            .onRead { .bool(try await device.currentState().on == 1) }
            .onWrite(changesOnly: true) { value in
                try await device.apply(LightState(on: value.boolValue == true ? 1 : 0))
            }
        lightbulb.characteristic(.brightness)
            .onRead { .int(try await device.currentState().brightness ?? 0) }
            .onWrite(changesOnly: true) { value in
                try await device.apply(LightState(brightness: value.intValue ?? 0))
            }
        lightbulb.characteristic(.colorTemperature)
            .onRead { .int(LightState.clamp(temperature: try await device.currentState().temperature ?? LightState.temperatureRange.lowerBound)) }
            .onWrite(changesOnly: true) { value in
                try await device.apply(LightState(temperature: LightState.clamp(temperature: value.intValue ?? LightState.temperatureRange.lowerBound)))
            }

        // Adaptive Lighting, once turned on in the Home app: the controller sets the temperature through the handler
        // above, every minute and when the brightness changes.
        let adaptiveLighting = AdaptiveLightingController(lightbulb, mode: .automatic, logger: logger)

        // Changes made elsewhere (the Control Center app, the light's buttons) reach HomeKit as events. A poll
        // reports only what differs from what was sent, so a white a few mireds away was set elsewhere: Adaptive
        // Lighting stops, as when the Home app sets one.
        await device.setStateHandler { state in
            if let on = state.on { lightbulb.characteristic(.on).value = .bool(on == 1) }
            if let brightness = state.brightness { lightbulb.characteristic(.brightness).value = .int(brightness) }
            if let temperature = state.temperature {
                let clamped = LightState.clamp(temperature: temperature)
                let current = lightbulb.characteristic(.colorTemperature).value.intValue ?? clamped
                if adaptiveLighting.isAdaptiveLightingActive, abs(current - clamped) > 3 { adaptiveLighting.disableAdaptiveLighting() }
                lightbulb.characteristic(.colorTemperature).value = .int(clamped)
            }
        }

        let accessory = await Accessory(
            id: "\(idPrefix):\(device.mac)", name: name, manufacturer: device.manufacturer, model: device.model,
            serialNumber: device.serialNumber, firmwareRevision: device.firmwareVersion, category: .lightbulb,
            services: [lightbulb],
            onIdentify: { await device.identify() })
        return (accessory, adaptiveLighting)
    }
}
