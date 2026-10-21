import Foundation
import Homeswift

/// Builds the HomeKit accessory of a light: a lightbulb with brightness and colour temperature.
enum KeyLightAccessory {
    static func make(device: KeyLightDevice, name: String, idPrefix: String) async -> Accessory {
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
            .onRead { .int(LightState.clamp(temperature: try await device.currentState().temperature ?? 143)) }
            .onWrite(changesOnly: true) { value in
                try await device.apply(LightState(temperature: LightState.clamp(temperature: value.intValue ?? 143)))
            }

        // Changes made elsewhere (the Control Center app, the light's buttons) reach HomeKit as events.
        await device.setStateHandler { state in
            if let on = state.on { lightbulb.characteristic(.on).value = .bool(on == 1) }
            if let brightness = state.brightness { lightbulb.characteristic(.brightness).value = .int(brightness) }
            if let temperature = state.temperature {
                lightbulb.characteristic(.colorTemperature).value = .int(LightState.clamp(temperature: temperature))
            }
        }

        return await Accessory(
            id: "\(idPrefix):\(device.mac)", name: name, manufacturer: device.manufacturer, model: device.model,
            serialNumber: device.serialNumber, firmwareRevision: device.firmwareVersion, category: .lightbulb,
            services: [lightbulb],
            onIdentify: { await device.identify() })
    }
}
