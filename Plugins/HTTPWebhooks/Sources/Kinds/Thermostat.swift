import Foundation
import Homeswift
import HomeswiftPlugin

/// `thermostats[]`: `currenttemperature`, `targettemperature`, `currentstate` (0 off, 1 heat, 2 cool) and `targetstate`
/// (0 off, 1 heat, 2 cool, 3 auto) set it. HomeKit's Target Temperature calls `set_target_temperature_*` with `%f` in
/// its URL, its Target Heating Cooling State `set_target_heating_cooling_state_*` with `%b`.
final class ThermostatAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    private let values: [(parameter: String, key: String, characteristic: Characteristic, label: String)]
    private let environment: KindEnvironment

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let target = CharacteristicType.targetTemperature.with(
            minValue: entry.number("minTemp", default: 15), maxValue: entry.number("maxTemp", default: 30), minStep: entry.number("minStep", default: 0.5))
        let service = Service(.thermostat, name: name, optional: [target], isPrimary: true)
        accessory = Accessory(
            id: HTTPWebhooksPlugin.accessoryID(name: name), name: name, manufacturer: HTTPWebhooksPlugin.manufacturer,
            model: "HttpWebHookThermostatAccessory-\(name)", serialNumber: "HttpWebHookThermostatAccessory-\(id)", category: .thermostat,
            services: [service])
        let keys = (
            current: "http-webhook-current-temperature-\(id)", target: "http-webhook-target-temperature-\(id)",
            currentState: "http-webhook-current-heating-cooling-state-\(id)", targetState: "http-webhook-target-heating-cooling-state-\(id)")
        values = [
            ("currenttemperature", keys.current, service.characteristic(.currentTemperature), "current temperature"),
            ("targettemperature", keys.target, service.characteristic(.targetTemperature), "target temperature"),
            ("currentstate", keys.currentState, service.characteristic(.currentHeatingCoolingState), "current state"),
            ("targetstate", keys.targetState, service.characteristic(.targetHeatingCoolingState), "target state"),
        ]
        let defaults = [20.0, 20, 0, 0]
        for (value, initial) in zip(values, defaults) { value.characteristic.show(environment.store.number(value.key, default: initial)) }

        let calls = (temperature: entry.call("set_target_temperature"), state: entry.call("set_target_heating_cooling_state"))
        let coalesce = LatestCallGuard(delay: environment.timing.coalescing)
        service.characteristic(.targetTemperature).onWrite { [environment, name] value in
            let temperature = value.doubleValue ?? 0
            guard await coalesce() else { return }
            environment.logger.info("\(name): setting target temperature to \(Format.number(temperature)) for \(id)")
            try await environment.send(calls.temperature?.substituting([("%f", Format.number(temperature))], in: .url), name: name)
            environment.store.set(keys.target, temperature)
        }
        service.characteristic(.targetHeatingCoolingState).onWrite { [environment, name] value in
            let state = Double(value.intValue ?? 0)
            environment.logger.info("\(name): setting target heating cooling state to \(Format.number(state)) for \(id)")
            try await environment.send(calls.state?.substituting([("%b", Format.number(state))], in: .url), name: name)
            environment.store.set(keys.targetState, state)
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        for value in values {
            guard let text = query.nonEmpty(value.parameter) else { continue }
            guard let number = WebhookNumber.parse(text) else {
                environment.logger.warning("\(name): ignoring \(value.parameter) \"\(text)\", which is not a number")
                continue
            }
            environment.store.set(value.key, number)
            if value.characteristic.show(number) { environment.logger.info("\(name): changing HomeKit \(value.label) for thermostat to \(text)") }
        }
        return .success
    }
}
