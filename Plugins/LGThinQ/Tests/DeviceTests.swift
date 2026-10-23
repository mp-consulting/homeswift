import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftLGThinQ

let acID = "7d0c7a8e-3c4f-4c8e-9a51-1b2b3c4d5e6f"
let washerID = "11111111-2222-3333-4444-555555555555"
let dishwasherID = "22222222-3333-4444-5555-666666666666"
let fridgeID = "33333333-4444-5555-6666-777777777777"
let purifierID = "44444444-5555-6666-7777-888888888888"
let ovenID = "55555555-6666-7777-8888-999999999999"
let microwaveID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
let hoodID = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
let dehumidifierID = "88888888-9999-aaaa-bbbb-cccccccccccc"
let stylerID = "99999999-aaaa-bbbb-cccc-dddddddddddd"

@Suite(.timeLimit(.minutes(1)))
struct AirConditionerTests {
    func start(_ settings: [String: Any] = [:]) async throws -> (LGTestEnvironment, PluginHost, Accessory) {
        let environment = LGTestEnvironment()
        environment.lg.add(device: try fixture("airconditioner").withDevice(id: acID, snapshot: try fixture("airconditioner-snapshot")), model: try fixture("airconditioner-model"))
        var block = LGTestEnvironment.defaultSettings
        block["devices"] = [["id": acID, "name": "MyAC", "type": "AC"].merging(settings) { $1 }]
        let host = try await environment.start(settings: block)
        let accessory = try #require(await environment.accessory(host, id: acID))
        return (environment, host, accessory)
    }

    @Test func mapsTheUnitToAHeaterCooler() async throws {
        let (_, host, accessory) = try await start(["ac_jet_control": true, "ac_temperature_sensor": true, "ac_humidity_sensor": true, "ac_led_control": true,
                                                    "ac_fan_control": true, "ac_buttons": [["name": "Dry", "op_mode": 1]], "serial_number": "SN-1"])
        defer { Task { await host.stop() } }
        #expect(accessory.category == .airConditioner)
        #expect(accessory.information[.manufacturer]?.value == "LG" && accessory.information[.serialNumber]?.value == "SN-1")
        let heater = try #require(accessory.service(.heaterCooler))
        #expect(heater.subtype == "MyAC" && heater[.configuredName]?.value == "MyAC")
        #expect(heater[.active]?.value == .int(1))
        #expect(heater.number(.currentTemperature) == 26.5)
        #expect(heater[.currentHeaterCoolerState]?.value == .int(3) && heater[.targetHeaterCoolerState]?.value == .int(2))
        #expect(heater.number(.coolingThresholdTemperature) == 26)
        #expect(heater.number(.totalConsumption) == 5.64)
        #expect(heater.number(.rotationSpeed) == 50 && heater[.swingMode]?.value == .int(1))
        #expect(heater[.targetHeaterCoolerState]?.type.validValues == [0, 1, 2])
        // RAC_056905: jet mode, energy save and air purify; the options add sensors, a light, a fan and a button.
        #expect(accessory.service(.switch, subtype: "Jet Mode")?[.configuredName]?.value == "MyAC Jet Mode")
        #expect(accessory.service(.switch, subtype: "Energy save") != nil && accessory.service(.switch, subtype: "Air Purify") != nil)
        #expect(accessory.service(.switch, subtype: "Quiet mode") == nil)
        #expect(accessory.service(.temperatureSensor)?.number(.currentTemperature) == 26.5)
        #expect(accessory.service(.humiditySensor) != nil)
        #expect(accessory.service(.lightbulb, subtype: "Light")?[.on]?.value == .bool(true))
        let fan = try #require(accessory.service(.fanv2, subtype: "MyAC Fan"))
        #expect(fan[.targetFanState]?.value == .int(1) && fan.linked.first === heater)
        let label = try #require(accessory.service(.serviceLabel, subtype: "Buttons"))
        #expect(label.linked.count == 1 && accessory.service(.switch, subtype: "Dry")?[.on]?.value == .bool(false))
    }

    @Test func sendsCommands() async throws {
        let (environment, host, accessory) = try await start(["ac_mode": "COOLING"])
        defer { Task { await host.stop() } }
        let heater = try #require(accessory.service(.heaterCooler))
        #expect(heater[.targetHeaterCoolerState]?.type.validValues == [2])

        try await heater.characteristic(.coolingThresholdTemperature).write(.double(24))
        #expect(environment.lg.commands.last?["dataKey"] == "airState.tempState.target" && environment.lg.commands.last?["dataValue"] == 24)
        #expect(environment.lg.requests.last?.url.absoluteString == "\(FakeLG.thinq2)/service/devices/\(acID)/control-sync")

        try await heater.characteristic(.rotationSpeed).write(.double(100))
        #expect(environment.lg.commands.last?["dataKey"] == "airState.windStrength" && environment.lg.commands.last?["dataValue"] == 6)

        try await heater.characteristic(.swingMode).write(.int(0))
        let swing = try #require(environment.lg.commands.last)
        #expect(swing["ctrlKey"] == "favoriteCtrl" && swing["dataSetList"]?["airState.wDir.vStep"] != nil && swing["dataKey"] == .null)

        try await heater.characteristic(.active).write(.int(0))
        #expect(environment.lg.commands.last?["command"] == "Operation" && environment.lg.commands.last?["dataValue"] == 0)
        #expect(heater[.active]?.value == .int(0))

        // A refused command is a communication failure for HomeKit.
        environment.lg.state.withLockedValue { $0.commandResult = "0001" }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await heater.characteristic(.active).write(.int(1)) }
    }

    @Test func followsMQTTPushes() async throws {
        let (environment, host, accessory) = try await start()
        defer { Task { await host.stop() } }
        let heater = try #require(accessory.service(.heaterCooler))
        #expect(await eventually(timeout: .seconds(15)) { environment.mqtt.connection.subscriptions == ["app/clients/abc/push": .atMostOnce] })
        let configuration = try #require(environment.mqtt.configurations.withLockedValue { $0.first })
        guard case .tls(let host, let port, let tls) = configuration.transport else { Issue.record("not TLS"); return }
        #expect(host == "a3abcdef-ats.iot.eu-west-1.amazonaws.com" && port == 8883 && tls.trust == .amazonRootCA1)
        guard case .pem(_, let privateKey)? = tls.clientIdentity else { Issue.record("no client identity"); return }
        #expect(privateKey.contains("PRIVATE KEY") && configuration.clientID.count == 64)
        #expect(configuration.keepAlive == .seconds(300) && configuration.reconnect == nil)
        // The client registered and sent its CSR.
        let csr = try #require(environment.lg.requests.first { $0.url.absoluteString.hasSuffix("/service/users/client/certificate") })
        let sentCSR = try #require(csr.body.flatMap { try? JSONValue(data: $0) }?["csr"]?.stringValue)
        #expect(!sentCSR.contains("BEGIN") && !sentCSR.contains("\n"))

        await environment.mqtt.push(["deviceId": .string(acID), "data": ["state": ["reported": ["airState.tempState.current": 22, "airState.operation": 0]]]])
        #expect(await eventually(timeout: .seconds(15)) { heater.number(.currentTemperature) == 22 })
        #expect(heater[.active]?.value == .int(0) && heater[.currentHeaterCoolerState]?.value == .int(0))
        // Other messages are ignored.
        await environment.mqtt.push(["deviceId": .string(acID), "type": "monitoring"])
        await environment.mqtt.push(["deviceId": "unknown", "data": ["state": ["reported": ["x": 1]]]])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ApplianceTests {
    @Test func washerFinishesAProgram() async throws {
        let environment = LGTestEnvironment()
        let record = try fixture("washer_dryer")
        var snapshot = (record["data"] ?? record)["snapshot"]!.objectValue!
        var washer = snapshot["washerDryer"]!.objectValue!
        washer["state"] = "RUNNING"
        washer["remainTimeHour"] = 1
        washer["remainTimeMinute"] = 20
        snapshot["washerDryer"] = .object(washer)
        environment.lg.add(device: try fixture("washer_dryer").withDevice(id: washerID, snapshot: .object(snapshot)), model: try fixture("washer_dryer-model"))
        var block = LGTestEnvironment.defaultSettings
        block["devices"] = [["id": washerID, "washer_trigger": true, "washer_door_lock": true, "washer_tub_clean": true]]
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        let accessory = try #require(await environment.accessory(host, id: washerID))
        let valve = try #require(accessory.service(.valve))
        #expect(valve[.active]?.value == .int(1) && valve[.inUse]?.value == .int(1) && valve.number(.remainingDuration) == 4800)
        #expect(valve[.valveType]?.value == .int(3) && valve[.remainingDuration]?.type.maxValue == 86_400)
        let lock = try #require(accessory.service(.lockMechanism, subtype: "Door"))
        #expect(lock[.lockCurrentState]?.value == .int(0))
        let finished = try #require(accessory.service(.occupancySensor, subtype: "Program Finished"))
        let tubClean = try #require(accessory.service(.occupancySensor, subtype: "Tub Clean Coach"))
        #expect(finished[.occupancyDetected]?.value == .int(0))

        // Not controllable: a write sends nothing.
        try await valve.characteristic(.active).write(.int(0))

        await environment.mqtt.push(["deviceId": .string(washerID), "data": ["state": ["reported": ["washerDryer": ["state": "END", "TCLCount": 31, "doorLock": "DOOR_LOCK_ON"]]]]])
        #expect(await eventually(timeout: .seconds(15)) { finished[.occupancyDetected]?.value == .int(1) })
        #expect(tubClean[.occupancyDetected]?.value == .int(1))
        #expect(valve[.active]?.value == .int(0) && valve.number(.remainingDuration) == 0)
        #expect(lock[.lockCurrentState]?.value == .int(1))
        #expect(environment.lg.commands.isEmpty)
    }

    @Test func dishwasherIsPublishedOnItsOwn() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: try fixture("dishwasher").withDevice(id: dishwasherID), model: try fixture("dishwasher-model"))
        var block = LGTestEnvironment.defaultSettings
        block["devices"] = [["id": dishwasherID, "dishwasher_trigger": true]]
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        let accessory = try #require(await environment.accessory(host, id: dishwasherID))
        #expect(await eventually(timeout: .seconds(15)) { host.bridges.contains { $0.isExternal && $0.server.primary.id == "LGThinQ:\(dishwasherID)" } })
        #expect(accessory.category == .sprinkler)
        let tv = try #require(accessory.service(.television, subtype: "CataNicoGaTa-70"))
        #expect(tv[.configuredName]?.value == "LG Dishwasher" && tv.linked.count == 7)
        let state = try #require(accessory.service(.inputSource, subtype: "CataNicoGaTa-10030"))
        #expect(state[.configuredName]?.value == "Running a Auto Cycle. Step: Cleaning")
        let options = try #require(accessory.service(.inputSource, subtype: "CataNicoGaTa-10040"))
        #expect(options[.configuredName]?.value == "Options: Dual Zone, Steam, Extra Dry")
        let valve = try #require(accessory.service(.valve))
        #expect(valve.isPrimary && valve.number(.remainingDuration) == 3 * 3600 + 4 * 60 && valve.number(.setDuration) == 3 * 3600 + 48 * 60)
        #expect(valve[.inUse]?.value == .int(1) && valve[.active]?.value == .int(1))
        let door = try #require(accessory.service(.contactSensor))
        #expect(door[.contactSensorState]?.value == .int(0) && door[.batteryLevel]?.value == .int(100))
        let cleanliness = try #require(accessory.service(.inputSource, subtype: "CataNicoGaTa-10060"))
        #expect(cleanliness[.configuredName]?.value == "Machine Cleaning Cycle is Needed Soon")
        #expect(tv[.activeIdentifier]?.value == .int(7))
        let start = try #require(accessory.service(.inputSource, subtype: "CataNico-Always10"))
        #expect(start[.configuredName]?.value.stringValue?.hasPrefix("Start: ") == true && start[.currentVisibilityState]?.value == .int(0))

        let finished = try #require(accessory.service(.occupancySensor))
        await environment.mqtt.push(["deviceId": .string(dishwasherID), "data": ["state": ["reported": ["dishwasher": ["state": "END", "process": "NONE"]]]]])
        #expect(await eventually(timeout: .seconds(15)) { finished[.occupancyDetected]?.value == .int(1) })
        #expect(state[.configuredName]?.value.stringValue?.hasPrefix("Finished Cycle ") == true)
    }

    @Test func refrigerator() async throws {
        let environment = LGTestEnvironment()
        let mapping: JSONValue = ["valueMapping": ["1": ["label": "1"], "2": ["label": "2"], "3": ["label": "3"], "4": ["label": "4"], "5": ["label": "5"]]]
        let freezer: JSONValue = ["valueMapping": ["1": ["label": "-23"], "2": ["label": "-20"], "3": ["label": "-15"]]]
        let model: JSONValue = [
            "Config": ["visibleItems": [["Feature": "fridgeTemp", "ControlTitle": "Fridge"], ["Feature": "freezerTemp", "ControlTitle": "Freezer"], ["Feature": "waterFilter", "ControlTitle": "Filter"]]],
            "MonitoringValue": ["fridgeTemp_C": mapping, "freezerTemp_C": freezer, "expressMode": ["valueMapping": ["ON": ["label": "@CP_ON_EN_W"], "OFF": ["label": "@CP_OFF_EN_W"]]]],
        ]
        environment.lg.add(device: ["deviceId": .string(fridgeID), "deviceType": 101, "alias": "Fridge", "modelName": "GBB", "snapshot": [
            "refState": ["fridgeTemp": "3", "freezerTemp": "2", "atLeastOneDoorOpen": "OPEN", "tempUnit": "CELSIUS", "expressMode": "ON", "waterFilter1RemainP": 3],
        ]], model: model)
        var block = LGTestEnvironment.defaultSettings
        block["devices"] = [["id": fridgeID, "ref_express_freezer": true, "ref_eco_friendly": true]]
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        let accessory = try #require(await environment.accessory(host, id: fridgeID))
        let fridge = try #require(accessory.service(.thermostat, subtype: "Fridge"))
        #expect(fridge.number(.targetTemperature) == 3 && fridge.number(.currentTemperature) == 3)
        #expect(fridge[.targetTemperature]?.type.minValue == 1 && fridge[.targetTemperature]?.type.maxValue == 5 && fridge[.targetTemperature]?.type.minStep == 1)
        #expect(fridge[.targetHeatingCoolingState]?.value == .int(2) && fridge[.targetHeatingCoolingState]?.type.validValues == [2])
        let freezerService = try #require(accessory.service(.thermostat, subtype: "Freezer"))
        #expect(freezerService.number(.targetTemperature) == -20)
        #expect(accessory.service(.contactSensor)?[.contactSensorState]?.value == .int(1))
        let express = try #require(accessory.service(.switch, subtype: "Express Freezer"))
        #expect(express[.on]?.value == .bool(true))
        #expect(accessory.service(.switch, subtype: "Eco Friendly") == nil, "no ecoFriendly in the snapshot")
        let filter = try #require(accessory.service(.filterMaintenance))
        #expect(filter.number(.filterLifeLevel) == 3 && filter[.filterChangeIndication]?.value == .int(1))

        try await fridge.characteristic(.targetTemperature).write(.double(4))
        let command = try #require(environment.lg.commands.last)
        #expect(command["dataSetList"]?["refState"] == ["fridgeTemp": 4, "tempUnit": "CELSIUS"])
        await #expect(throws: HAPStatusError(.invalidValueInRequest)) { try await freezerService.characteristic(.targetTemperature).write(.double(-18)) }
        try await express.characteristic(.on).write(.bool(false))
        #expect(environment.lg.commands.last?["dataSetList"]?["refState"]?["expressMode"] == "OFF")
    }

    @Test func airPurifierAndAeroTower() async throws {
        let environment = LGTestEnvironment()
        let snapshot: JSONValue = [
            "airState.operation": 1, "airState.opMode": 14, "airState.windStrength": 4, "airState.lightingState.displayControl": 9,
            "airState.quality.overall": 2, "airState.quality.PM2": 12, "airState.filterMngStates.useTime": 100, "airState.filterMngStates.maxTime": 1000,
            "airState.tempState.current": 21.5, "airState.humidity.current": 40, "airState.miscFuncState.Uvnano": 1,
        ]
        environment.lg.add(device: ["deviceId": .string(purifierID), "deviceType": 410, "alias": "Tower", "snapshot": snapshot], model: [:])
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let accessory = try #require(await environment.accessory(host, id: purifierID))
        #expect(accessory.category == .airPurifier)
        let purifier = try #require(accessory.service(.airPurifier))
        #expect(purifier[.active]?.value == .int(1) && purifier[.targetAirPurifierState]?.value == .int(0) && purifier.number(.rotationSpeed) == 2)
        #expect(purifier[.name]?.value == "Tower" && purifier[.configuredName]?.value == "Air Purifier")
        #expect(accessory.service(.airQualitySensor)?[.airQuality]?.value == .int(2))
        #expect(accessory.service(.filterMaintenance)?.number(.filterLifeLevel) == 90)
        let light = try #require(accessory.service(.lightbulb, subtype: "Light"))
        #expect(light[.brightness]?.value == .int(2) && light[.brightness]?.type.maxValue == 3)
        #expect(accessory.service(.temperatureSensor)?.number(.currentTemperature) == 21.5)
        #expect(accessory.service(.switch, subtype: "UV Purifier")?[.on]?.value == .bool(true))
        try await purifier.characteristic(.rotationSpeed).write(.double(4))
        #expect(environment.lg.commands.last?["dataKey"] == "airState.windStrength" && environment.lg.commands.last?["dataValue"] == 7)
        try await light.characteristic(.brightness).write(.int(3))
        #expect(environment.lg.commands.last?["dataValue"] == 10)
    }

    @Test func dehumidifierHoodAndStyler() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(dehumidifierID), "deviceType": 403, "alias": "Dry", "snapshot": [
            "airState.operation": 1, "airState.opMode": 17, "airState.humidity.current": 60, "airState.humidity.desired": 50, "airState.windStrength": 6,
            "airState.notificationExt": 1,
        ]], model: [:])
        environment.lg.add(device: ["deviceId": .string(hoodID), "deviceType": 304, "alias": "Hood", "snapshot": [
            "hoodState": ["ventSet": "ENABLE", "ventLevel": 2, "lampSet": "DISABLE", "lampLevel": 0],
        ]], model: ["Value": ["VentLevel": ["type": "Range", "option": ["min": 0, "max": 5]], "VentSet": ["type": "Enum", "option": ["ENABLE": "@CP_ENABLE_W", "DISABLE": "@CP_DISABLE_W"]],
                              "LampSet": ["type": "Enum", "option": ["ENABLE": "@CP_ENABLE_W", "DISABLE": "@CP_DISABLE_W"]]]])
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "snapshot": [
            "styler": ["state": "RUNNING", "remainTimeHour": 0, "remainTimeMinute": 30],
        ]], model: [:])
        let host = try await environment.start()
        defer { Task { await host.stop() } }

        let dehumidifier = try #require(await environment.accessory(host, id: dehumidifierID)?.service(.humidifierDehumidifier))
        #expect(dehumidifier[.currentHumidifierDehumidifierState]?.value == .int(3) && dehumidifier.number(.rotationSpeed) == 2)
        #expect(dehumidifier.number(.waterLevel) == 100 && dehumidifier.number(.relativeHumidityDehumidifierThreshold) == 50)
        try await dehumidifier.characteristic(.relativeHumidityDehumidifierThreshold).write(.double(45))
        #expect(environment.lg.commands.last?["dataKey"] == "airState.humidity.desired" && environment.lg.commands.last?["dataValue"] == 45)

        let hood = try #require(await environment.accessory(host, id: hoodID))
        let fan = try #require(hood.service(.fan))
        #expect(fan[.on]?.value == .bool(true) && fan.number(.rotationSpeed) == 2 && fan[.rotationSpeed]?.type.maxValue == 5)
        #expect(hood.service(.lightbulb, subtype: "Light")?[.on]?.value == .bool(false))
        try await fan.characteristic(.rotationSpeed).write(.double(4))
        #expect(environment.lg.commands.last?["dataSetList"]?["hoodState"] == ["ventLevel": 4])

        let styler = try #require(await environment.accessory(host, id: stylerID)?.service(.valve))
        #expect(styler[.inUse]?.value == .int(1) && styler.number(.remainingDuration) == 1800 && styler[.valveType]?.value == .int(0))
    }

    @Test func ovenComposesACook() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(ovenID), "deviceType": 301, "alias": "Range", "snapshot": ["ovenState": [
            "upperState": "INITIAL", "upperRemoteStart": "ENABLE", "upperCurrentTemperatureUnit": "FAHRENHEIT", "burnerOnCounter": 1,
            "cooktop1CooktopState": "ON", "upperCookAndWarmStatus": "DISABLE", "commonControlLock": "DISABLE", "upperDoorOpen": "DISABLE",
        ]]], model: [:])
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let accessory = try #require(await environment.accessory(host, id: ovenID))
        #expect(accessory.category == .thermostat)
        let status = try #require(accessory.service(.inputSource, subtype: "NicoCataGaTa-Oven1003"))
        #expect(status[.configuredName]?.value == "Oven is in Standby (Homekit Monitor Only Mode)")
        #expect(accessory.service(.inputSource, subtype: "NicoCataGaTa-Oven001")?[.configuredName]?.value == "Front Left Burner is On")
        #expect(accessory.service(.lightSensor)?.number(.currentAmbientLightLevel) == 1)
        let monitorOnly = try #require(accessory.service(.switch, subtype: "CataNicoGaTa-Control7"))
        #expect(monitorOnly[.on]?.value == .bool(true))
        let start = try #require(accessory.service(.switch, subtype: "CataNicoGaTa-Control8"))

        // Monitor Only: nothing is sent.
        try await start.characteristic(.on).write(.bool(true))
        #expect(environment.lg.commands.isEmpty)

        try await monitorOnly.characteristic(.on).write(.bool(false))
        try await accessory.service(.switch, subtype: "CataNicoGaTa-Control1")!.characteristic(.on).write(.bool(true))
        try await accessory.service(.thermostat, subtype: "NicoCataGaTa-OvenTC")!.characteristic(.targetTemperature).write(.double(200))
        try await accessory.service(.valve, subtype: "NicoCataGaTa-OvenT2")!.characteristic(.setDuration).write(.int(3600))
        try await start.characteristic(.on).write(.bool(true))
        let command = try #require(environment.lg.commands.last)
        #expect(command["ctrlKey"] == "SetCookStart")
        let oven = try #require(command["dataSetList"]?["ovenState"])
        #expect(oven["cmdOptionSetCookName"] == "CONVECTION_BAKE" && oven["setTargetTemperature"] == 392 && oven["cmdOptionSetTargetTimeHour"] == 1)
        #expect(oven["cmdOptionSetTargetTemperatureUnit"] == "FAHRENHEIT")
    }

    @Test func microwaveVentAndLamp() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(microwaveID), "deviceType": 302, "alias": "Microwave", "snapshot": ["ovenState": [
            "LWOState": "INITIAL", "mwoVentSpeedLevel": 2, "mwoLampLevel": 1, "LWOTargetTemperatureUnit": "FAHRENHEIT", "LWOMGTPowerLevel": "5",
        ]]], model: [:])
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let accessory = try #require(await environment.accessory(host, id: microwaveID))
        #expect(accessory.service(.inputSource, subtype: "NicoCata-Always15")?[.configuredName]?.value == "Light is set to Low and Vent is set to Level 2")
        let fan = try #require(accessory.service(.fanv2, subtype: "YourUniqueIdentifier-59F"))
        #expect(fan[.active]?.value == .int(1) && fan.number(.rotationSpeed) == 2)
        #expect(accessory.service(.lightbulb, subtype: "YourUniqueIdentifier-59SP")?.number(.brightness) == 50)
        try await fan.characteristic(.rotationSpeed).write(.double(4))
        let vent = try #require(environment.lg.commands.last?["dataSetList"]?["ovenState"])
        #expect(environment.lg.commands.last?["ctrlKey"] == "setVentLampLevel")
        #expect(vent["mwoVentSpeedLevel"] == 4 && vent["mwoVentOnOff"] == "ENABLE" && vent["cmdOptionContentsType"] == "REMOTE_VENT_LAMP")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PlatformTests {
    @Test func addsOnlyConfiguredDevicesAndRemovesTheOthers() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: try fixture("airconditioner").withDevice(id: acID, snapshot: try fixture("airconditioner-snapshot")), model: try fixture("airconditioner-model"))
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "snapshot": ["styler": ["state": "POWEROFF"]]], model: [:])
        environment.lg.add(device: ["deviceId": "not-a-uuid", "deviceType": 203, "alias": "Bad"], model: [:])
        environment.lg.add(device: ["deviceId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "deviceType": 701, "alias": "TV"], model: [:])
        let host = try await environment.start()
        #expect(await environment.accessory(host, id: acID) != nil)
        #expect(await environment.accessory(host, id: stylerID) != nil)
        let ids = host.mainBridge.server.accessories.map(\.id)
        #expect(!ids.contains("LGThinQ:not-a-uuid") && !ids.contains("LGThinQ:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let devices = try await host.handleWebRequest(platform: "LGThinQ", name: "LG ThinQ", PluginWebRequest(method: "GET", path: "devices", user: "admin"))
        #expect(devices?.json["devices"]?.arrayValue?.count == 2)
        await host.stop()

        // Restarted with only the AC listed: the styler leaves HomeKit.
        var block = LGTestEnvironment.defaultSettings
        block["devices"] = [["id": acID]]
        let next = try await environment.start(settings: block)
        defer { Task { await next.stop() } }
        #expect(await environment.accessory(next, id: acID) != nil)
        #expect(await eventually(timeout: .seconds(15)) { !next.mainBridge.server.accessories.contains { $0.id == "LGThinQ:\(stylerID)" } })
    }

    @Test func keepsCachedAccessoriesWhenLGListsNothing() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "snapshot": ["styler": ["state": "POWEROFF"]]], model: [:])
        let host = try await environment.start()
        #expect(await environment.accessory(host, id: stylerID) != nil)
        await host.stop()
        environment.lg.state.withLockedValue { $0.devices = [] }
        let next = try await environment.start()
        defer { Task { await next.stop() } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(next.mainBridge.server.accessories.contains { $0.id == "LGThinQ:\(stylerID)" })
    }

    @Test func missingSettingsAreReported() async throws {
        let environment = LGTestEnvironment()
        let host = try await environment.start(settings: ["country": "US"])
        defer { Task { await host.stop() } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.lg.requests.isEmpty)
    }

    @Test func signsInWithAnAccount() async throws {
        let environment = LGTestEnvironment()
        environment.lg.override("lgemembers.com") { request in
            let url = request.url.absoluteString
            if url.contains("signInAct") { return FakeLG.json(["account": ["loginSessionID": "s", "userID": "u", "userIDType": "LGE"]]) }
            if url.contains("signInComplete") { return FakeLG.json(["code": "SUCCESS"]) }
            if url.contains("/oauth") { return FakeLG.json(["redirect_uri": "lgaccount.lgsmartthinq:/?code=c"]) }
            return FakeLG.json([:], cookies: ["JSESSIONID=x"])
        }
        environment.lg.override("us.lgeapi.com/oauth") { _ in FakeLG.json(["access_token": "from-code", "refresh_token": "refresh-new", "expires_in": 3600]) }
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler"], model: [:])
        let host = try await environment.start(settings: ["auth_mode": "account", "username": "me@example.com", "password": "secret", "country": "US", "language": "en-US"])
        defer { Task { await host.stop() } }
        #expect(await environment.accessory(host, id: stylerID) != nil)
        let refresh = try #require(environment.lg.requests.first { $0.url.absoluteString == FakeLG.oauth + "/oauth/1.0/oauth2/token" })
        #expect(refresh.bodyText.contains("refresh_token=refresh-new"))
    }

    @Test func pollsThinQ1Devices() async throws {
        let environment = LGTestEnvironment()
        let model: JSONValue = [
            "Monitoring": ["type": "BINARY(BYTE)", "protocol": [["value": "Operation", "startByte": 0, "length": 1], ["value": "TempCur", "startByte": 1, "length": 1],
                                                                 ["value": "TempCfg", "startByte": 2, "length": 1], ["value": "OpMode", "startByte": 3, "length": 1]]],
            "Value": ["Operation": ["type": "Enum", "option": ["0": "@AC_MAIN_OPERATION_OFF_W", "1": "@AC_MAIN_OPERATION_RIGHT_ON_W"]],
                      "TempCfg": ["type": "Range", "option": ["min": 18, "max": 30]]],
            "ControlWifi": ["type": "JSON"],
        ]
        environment.lg.add(device: ["deviceId": .string(acID), "deviceType": 401, "alias": "Old AC", "platformType": "thinq1", "modelName": "OLD"], model: model)
        environment.lg.state.withLockedValue { $0.monitorData[acID] = Data([1, 27, 24, 0]) }
        var block = LGTestEnvironment.defaultSettings
        block["thinq1"] = true
        block["refresh_interval"] = "0.05"
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        let heater = try #require(await environment.accessory(host, id: acID)?.service(.heaterCooler))
        #expect(heater[.coolingThresholdTemperature]?.type.minValue == 18 && heater[.coolingThresholdTemperature]?.type.maxValue == 30)
        #expect(await eventually(timeout: .seconds(15)) { heater.number(.currentTemperature) == 27 })
        #expect(heater[.active]?.value == .int(1) && heater[.currentHeaterCoolerState]?.value == .int(3))
        try await heater.characteristic(.coolingThresholdTemperature).write(.double(22))
        let control = try #require(environment.lg.thinq1Controls.last?["lgedmRoot"])
        #expect(control["value"] == ["TempCfg": "22"] && control["deviceId"] == .string(acID))
        try await heater.characteristic(.active).write(.int(0))
        #expect(environment.lg.thinq1Controls.last?["lgedmRoot"]?["value"] == ["Operation": "0"])
    }

    @Test func skipsThinQ1DevicesUnlessEnabled() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(acID), "deviceType": 401, "alias": "Old AC", "platformType": "thinq1"], model: [:])
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler"], model: [:])
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await environment.accessory(host, id: stylerID) != nil)
        #expect(!host.mainBridge.server.accessories.contains { $0.id == "LGThinQ:\(acID)" })
    }
}
