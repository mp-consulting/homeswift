import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftTuya

/// Air conditioners and thermostats through ClimateController, against the fake cloud with a list of their own.
@Suite(.timeLimit(.minutes(1)))
struct TuyaClimateTests {
    static let airConditionerID = "bfac0000000000000001"
    static let thermostatID = "bfwk0000000000000001"
    let airConditioner = TuyaPlugin.accessoryID(deviceID: airConditionerID)
    let thermostat = TuyaPlugin.accessoryID(deviceID: thermostatID)

    static let deviceList = #"""
    [{"id":"bfac0000000000000001","uuid":"ac01","name":"Bedroom AC","online":true,"category":"kt","product_id":"ac1","owner_id":"12345678",
      "status":[{"code":"switch","value":true},{"code":"mode","value":"wet"},{"code":"temp_set","value":240},{"code":"temp_current","value":270}]},
     {"id":"bfwk0000000000000001","uuid":"wk01","name":"Hall","online":true,"category":"wk","product_id":"wk1","owner_id":"12345678",
      "status":[{"code":"switch","value":true},{"code":"mode","value":"eco"},{"code":"temp_set","value":210},{"code":"temp_current","value":195},
       {"code":"work_state","value":"heating"}]}]
    """#

    static let airConditionerSpecification = #"""
    {"category":"kt",
     "functions":[{"code":"switch","type":"Boolean","values":"{}"},
      {"code":"mode","type":"Enum","values":"{\"range\":[\"auto\",\"cold\",\"hot\",\"wet\",\"wind\"]}"},
      {"code":"temp_set","type":"Integer","values":"{\"min\":160,\"max\":300,\"scale\":1,\"step\":10}"}],
     "status":[{"code":"temp_current","type":"Integer","values":"{\"min\":-200,\"max\":600,\"scale\":1,\"step\":1}"}]}
    """#

    static let thermostatSpecification = #"""
    {"category":"wk",
     "functions":[{"code":"switch","type":"Boolean","values":"{}"},
      {"code":"mode","type":"Enum","values":"{\"range\":[\"hot\",\"eco\",\"program\"]}"},
      {"code":"temp_set","type":"Integer","values":"{\"min\":50,\"max\":350,\"scale\":1,\"step\":5}"}],
     "status":[{"code":"temp_current","type":"Integer","values":"{\"min\":-200,\"max\":600,\"scale\":1,\"step\":1}"},
      {"code":"work_state","type":"Enum","values":"{\"range\":[\"heating\",\"idle\"]}"}]}
    """#

    static func environment() -> TestEnvironment {
        let environment = TestEnvironment()
        let cloud = environment.cloud
        cloud.set("GET /v1.0/homes/12345678/devices", try! JSONValue(string: deviceList))
        cloud.set("GET /v1.0/devices/\(airConditionerID)/specifications", try! JSONValue(string: airConditionerSpecification))
        cloud.set("GET /v1.0/devices/\(thermostatID)/specifications", try! JSONValue(string: thermostatSpecification))
        for id in [airConditionerID, thermostatID] { cloud.set("POST /v1.0/devices/\(id)/commands", true) }
        return environment
    }

    func started(_ environment: TestEnvironment) async throws -> PluginHost {
        let host = try await environment.start()
        #expect(await eventually { host.accessory(airConditioner) != nil && host.accessory(thermostat) != nil })
        return host
    }

    func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
        let characteristic = try #require(characteristic)
        let handler = try #require(characteristic.writeHandler(for: value))
        try await handler(value)
    }

    func commands(_ environment: TestEnvironment, _ deviceID: String) -> [String] {
        environment.cloud.sent("POST", "/v1.0/devices/\(deviceID)/commands").compactMap(\.body)
    }

    /// Dry is an Other Mode: the unit stays on with the mode shown; a mode goes out alone, and a turn-on from dry
    /// brings the unit back to auto.
    @Test func anAirConditionerInDryKeepsItsModeAndComesBackToAuto() async throws {
        let environment = Self.environment()
        let host = try await started(environment)
        let service = try #require(host.accessory(airConditioner)?.service(.heaterCooler))
        #expect(service[.targetHeaterCoolerState]?.type.validValues == [0, 1, 2])
        #expect(service[.active]?.value == 1 && service[.targetHeaterCoolerState]?.value == 1)
        #expect(service[.heatingThresholdTemperature]?.value == 24.0 && service[.currentTemperature]?.value == 27.0)
        // An Other Mode is idle: the room is not compared with the target.
        #expect(service[.currentHeaterCoolerState]?.value == 1)

        try await write(service[.targetHeaterCoolerState], 2)
        #expect(commands(environment, Self.airConditionerID).last == #"{"commands":[{"code":"mode","value":"cold"}]}"#)
        try await write(service[.coolingThresholdTemperature], 22)
        #expect(commands(environment, Self.airConditionerID).last == #"{"commands":[{"code":"temp_set","value":220}]}"#)
        #expect(service[.currentHeaterCoolerState]?.value == 3)

        // Off in dry, turned on from Apple Home: power and auto.
        try await write(host.accessory(airConditioner)?.service(.humidifierDehumidifier)?[.active], 1)
        try await write(host.accessory(airConditioner)?.service(.humidifierDehumidifier)?[.active], 0)
        #expect(await eventually {
            commands(environment, Self.airConditionerID).last == #"{"commands":[{"code":"switch","value":false},{"code":"mode","value":"wet"}]}"#
        })
        #expect(service[.active]?.value == 0)
        try await write(service[.active], 1)
        #expect(commands(environment, Self.airConditionerID).last == #"{"commands":[{"code":"switch","value":true},{"code":"mode","value":"auto"}]}"#)
        await host.stop()
    }

    /// Hot, program as auto, eco as an Other Mode; Off is the power, and a turn-on carries the mode chosen.
    @Test func aThermostatTurnsOnWithTheModeChosen() async throws {
        let environment = Self.environment()
        let host = try await started(environment)
        let service = try #require(host.accessory(thermostat)?.service(.thermostat))
        #expect(service[.targetHeatingCoolingState]?.type.validValues == [0, 1, 3])
        #expect(service[.targetTemperature]?.type.minValue == 10 && service[.targetTemperature]?.type.maxValue == 35)
        #expect(service[.targetHeatingCoolingState]?.value == 1 && service[.currentHeatingCoolingState]?.value == 1)
        #expect(service[.targetTemperature]?.value == 21.0)

        try await write(service[.targetHeatingCoolingState], 3)
        #expect(commands(environment, Self.thermostatID).last == #"{"commands":[{"code":"mode","value":"program"}]}"#)
        try await write(service[.targetHeatingCoolingState], 0)
        #expect(commands(environment, Self.thermostatID).last == #"{"commands":[{"code":"switch","value":false}]}"#)
        #expect(service[.currentHeatingCoolingState]?.value == 0)
        try await write(service[.targetHeatingCoolingState], 1)
        #expect(commands(environment, Self.thermostatID).last == #"{"commands":[{"code":"switch","value":true},{"code":"mode","value":"hot"}]}"#)
        try await write(service[.targetTemperature], 22.5)
        #expect(commands(environment, Self.thermostatID).last == #"{"commands":[{"code":"temp_set","value":225}]}"#)
        await host.stop()
    }

    /// Eco, an Other Mode, has a switch of its own: on while the thermostat is in eco, on sends eco, off goes back to the
    /// last Climate Mode.
    @Test func aThermostatsEcoIsASwitch() async throws {
        let environment = Self.environment()
        let host = try await started(environment)
        let accessory = try #require(host.accessory(thermostat))
        let eco = try #require(accessory.service(.switch, subtype: "eco"))
        #expect(eco[.name]?.value == "Hall Eco")
        #expect(eco[.on]?.value == true)
        let service = try #require(accessory.service(.thermostat))
        try await write(service[.targetHeatingCoolingState], 3)
        #expect(commands(environment, Self.thermostatID).last == #"{"commands":[{"code":"mode","value":"program"}]}"#)
        try await write(eco[.on], true)
        #expect(commands(environment, Self.thermostatID).last == #"{"commands":[{"code":"mode","value":"eco"}]}"#)
        try await write(eco[.on], false)
        #expect(commands(environment, Self.thermostatID).last == #"{"commands":[{"code":"mode","value":"program"}]}"#)
        await host.stop()
    }

    /// An air conditioner offline is No Response: its power and room are not read from the last state.
    @Test func anOfflineAirConditionerIsNoResponse() async throws {
        let environment = TestEnvironment()
        let cloud = environment.cloud
        cloud.set("GET /v1.0/homes/12345678/devices", try JSONValue(string: Self.deviceList.replacingOccurrences(of: #""uuid":"ac01","name":"Bedroom AC","online":true"#,
                                                                                                                 with: #""uuid":"ac01","name":"Bedroom AC","online":false"#)))
        cloud.set("GET /v1.0/devices/\(Self.airConditionerID)/specifications", try JSONValue(string: Self.airConditionerSpecification))
        cloud.set("GET /v1.0/devices/\(Self.thermostatID)/specifications", try JSONValue(string: Self.thermostatSpecification))
        let host = try await started(environment)
        let service = try #require(host.accessory(airConditioner)?.service(.heaterCooler))
        for type in [CharacteristicType.active, .currentTemperature] {
            let read = try #require(service[type]?.readHandler)
            await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { _ = try await read() }
        }
        await host.stop()
    }
}
