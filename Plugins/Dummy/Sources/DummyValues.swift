import Foundation
import Homeswift
import HomeswiftPlugin

/// Thermostats, humidifiers and the temperature and humidity sensors (spec 4.6–4.8, 7.10, 7.11).
extension DummyEngine {
    func setTargetMode(_ device: DummyDevice, _ mode: Int, source: ChangeSource) {
        guard device.config.validStates.contains(mode) else { return }
        let changed = mode != device.targetMode
        device.targetMode = mode
        if changed {
            let name = DummyDevice.modeNames[mode]
            info(device, device.currentModeExplicit ? "Setting \(device.name) to \(name)…" : "\(device.name) set to \(name)")
            setStored(device.identifier, "TargetHeatingCoolingState", .number(Double(mode)))
            // Until a current mode is set on its own, the current mode follows the target (auto leaves it).
            if !device.currentModeExplicit, mode != 3, mode != device.currentMode {
                device.currentMode = mode
                setStored(device.identifier, "CurrentHeatingCoolingState", .number(Double(mode)))
            }
        }
        publish(device)
    }

    func setCurrentMode(_ device: DummyDevice, _ mode: Int, source: ChangeSource) {
        guard (0...2).contains(mode) else { return }
        device.currentModeExplicit = true
        let changed = mode != device.currentMode
        device.currentMode = mode
        if changed {
            info(device, "\(device.name) is \(DummyDevice.modeNames[mode])")
            setStored(device.identifier, "CurrentHeatingCoolingState", .number(Double(mode)))
        }
        publish(device)
    }

    func setTargetTemperature(_ device: DummyDevice, _ celsius: Double, source: ChangeSource) {
        let changed = celsius != device.targetTemperature
        device.targetTemperature = celsius
        if changed {
            info(device, "\(device.name) set to \(device.temperatureText(celsius))")
            setStored(device.identifier, "TargetTemperature", .number(celsius))
            if !device.currentTemperatureExplicit { setCurrentTemperature(device, celsius, explicit: false) }
        }
        publish(device)
    }

    func setCurrentTemperature(_ device: DummyDevice, _ celsius: Double, explicit: Bool) {
        if explicit { device.currentTemperatureExplicit = true }
        let changed = celsius != device.currentTemperature
        device.currentTemperature = celsius
        if changed {
            if explicit { info(device, "\(device.name) is \(device.temperatureText(celsius))") }
            setStored(device.identifier, "CurrentTemperature", .number(celsius))
            if device.config.enableHistory { addHistory(device, EveHistory.Entry(time: scheduler.now, temp: celsius, humidity: 0, pressure: 0)) }
        }
        publish(device)
    }

    func setTargetHumidity(_ device: DummyDevice, _ value: Double, source: ChangeSource) {
        let changed = value != device.targetHumidity
        device.targetHumidity = value
        if changed {
            info(device, "\(device.name) humidity set to \(javaScriptNumber(value))%")
            setStored(device.identifier, "TargetRelativeHumidity", .number(value))
        }
        publish(device)
    }

    func setCurrentHumidity(_ device: DummyDevice, _ value: Double, source: ChangeSource) {
        device.currentHumidityExplicit = true
        let changed = value != device.currentHumidity
        device.currentHumidity = value
        if changed {
            info(device, "\(device.name) humidity is \(javaScriptNumber(value))%")
            setStored(device.identifier, "CurrentRelativeHumidity", .number(value))
            if device.config.enableHistory { addHistory(device, EveHistory.Entry(time: scheduler.now, temp: 0, humidity: value, pressure: 0)) }
        }
        publish(device)
    }

    /// A temperature or humidity sensor's reading, from a webhook (spec 4.8).
    func setSensorValue(_ device: DummyDevice, _ value: Double, source: ChangeSource) {
        let changed = value != device.value
        device.value = value
        if changed {
            info(device, device.stateMessage)
            let temperature = device.config.type == .temperatureSensor
            setStored(device.identifier, temperature ? "CurrentTemperature" : "CurrentRelativeHumidity", .number(value))
            if device.config.enableHistory {
                addHistory(device, temperature
                    ? EveHistory.Entry(time: scheduler.now, temp: value, humidity: 0, pressure: 0)
                    : EveHistory.Entry(time: scheduler.now, temp: 0, humidity: value, pressure: 0))
            }
        }
        publish(device)
    }
}
