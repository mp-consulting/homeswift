import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import NIOConcurrencyHelpers
@testable import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftMQTTThing

/// The vectors of section 10, on a host and a fake broker.
@Suite(.timeLimit(.minutes(1)))
struct AccessoryTests {
    let environment = TestEnvironment()
    var broker: FakeMQTTConnection { environment.broker() }

    func block(_ type: String, _ name: String, topics: [String: Any], _ extra: [String: Any] = [:]) -> [String: Any] {
        var block: [String: Any] = ["accessory": "mqttthing", "type": type, "name": name, "url": "mqtt://broker.local", "topics": topics]
        for (key, value) in extra { block[key] = value }
        return block
    }

    /// 10.1
    @Test func aSwitchWithDefaultBooleans() async throws {
        let host = try await environment.start([block("switch", "Desk Lamp", topics: ["getOn": "desk/lamp/state", "setOn": "desk/lamp/set"])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Desk Lamp"
        let accessory = try #require(host.accessory(id))
        #expect(accessory.information.characteristic(.model).value == .string("switch"))
        #expect(accessory.information.characteristic(.manufacturer).value == .string("mqttthing"))
        #expect(accessory.information.characteristic(.serialNumber).value == .string("testhost.local-Desk Lamp"))
        await broker.send("desk/lamp/state", "true")
        #expect(await eventually { host.value(id, .switch, .on) == .bool(true) })
        for ignored in ["1", "ON", "True"] { broker.receive("desk/lamp/state", string: ignored) }
        broker.receive("desk/lamp/state", string: "false")
        #expect(await eventually { host.value(id, .switch, .on) == .bool(false) })
        try await write(host.service(id, .switch)?[.on], .bool(true))
        try await write(host.service(id, .switch)?[.on], .bool(false))
        #expect(await broker.waitFor("desk/lamp/set", count: 2) == ["true", "false"])
    }

    @Test func blocksOnOneBrokerShareAConnection() async throws {
        let host = try await environment.start([
            block("switch", "One", topics: ["getOn": "one", "setOn": "one/set"]),
            block("switch", "Two", topics: ["getOn": "two", "setOn": "two/set"]),
            block("switch", "Three", topics: ["getOn": "three"], ["url": "mqtt://other.local"]),
        ])
        defer { Task { await host.stop() } }
        #expect(environment.connections.map(\.url).sorted() == ["mqtt://broker.local", "mqtt://other.local"])
        #expect(await eventually { broker.subscriptions.keys.sorted() == ["one", "two"] })
        #expect(broker.connectCount == 1)
    }

    /// 10.3: unconfirmed, retried, offline, back online on the echo.
    @Test func confirmationRetriesAndMarksOffline() async throws {
        let host = try await environment.start([block(
            "outlet", "Heater Plug", topics: ["getOn": "plug/heater/stat", "setOn": "plug/heater/cmnd"],
            ["integerValue": true, "confirmationPeriodms": 1000, "retryLimit": 2])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Heater Plug"
        _ = await eventually { broker.isConnected }
        try await write(host.service(id, .outlet)?[.on], .bool(true))
        #expect(await broker.waitFor("plug/heater/cmnd", count: 3) == ["1", "1", "1"])
        await #expect(throws: HAPStatusError.self) { try await read(host.service(id, .outlet)?[.on]) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(broker.published(on: "plug/heater/cmnd").count == 3)
        broker.receive("plug/heater/stat", string: "1")
        #expect(await eventually { (try? await read(host.service(id, .outlet)?[.on])) == .bool(true) })
    }

    /// 10.4
    @Test func autoOffAndReset() async throws {
        let host = try await environment.start([
            block("switch", "Timed", topics: ["getOn": "timed", "setOn": "timed/set"], ["turnOffAfterms": 2000]),
            block("motionSensor", "PIR", topics: ["getMotionDetected": "pir"], ["turnOffAfterms": 5000]),
            block("contactSensor", "Door", topics: ["getContactSensorState": "door"], ["resetStateAfterms": 1000]),
        ])
        defer { Task { await host.stop() } }
        await broker.send("timed", "true")
        #expect(await eventually { host.value("mqttthing:Timed", .switch, .on) == .bool(true) })
        #expect(await broker.waitFor("timed/set") == ["false"])
        #expect(host.value("mqttthing:Timed", .switch, .on) == .bool(false))
        await broker.send("pir", "true")
        #expect(await eventually { host.value("mqttthing:PIR", .motionSensor, .motionDetected) == .bool(true) })
        #expect(await eventually { host.value("mqttthing:PIR", .motionSensor, .motionDetected) == .bool(false) })
        await broker.send("door", "true")
        #expect(await eventually { host.value("mqttthing:Door", .contactSensor, .contactSensorState) == .int(1) })
        #expect(await eventually { host.value("mqttthing:Door", .contactSensor, .contactSensorState) == .int(0) })
        #expect(broker.published(on: "pir").isEmpty)
    }

    /// 10.5
    @Test func aSensorThroughJSONPath() async throws {
        let host = try await environment.start([block(
            "temperatureSensor", "Garden Sensor",
            topics: ["getCurrentTemperature": "tele/garden/SENSOR$.AM2301.Temperature", "getStatusLowBattery": "tele/garden/battery_low"])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Garden Sensor"
        await broker.send("tele/garden/SENSOR", #"{"Time":"2026-01-01T00:00:00","AM2301":{"Temperature":-3.5,"Humidity":80}}"#)
        #expect(await eventually { host.value(id, .temperatureSensor, .currentTemperature) == .double(-3.5) })
        broker.receive("tele/garden/SENSOR", string: #"{"AM2301":{}}"#)
        await broker.send("tele/garden/battery_low", "true")
        #expect(await eventually { host.value(id, .temperatureSensor, .statusLowBattery) == .int(1) })
        #expect(host.value(id, .temperatureSensor, .currentTemperature) == .double(-3.5))
        #expect(host.service(id, .battery) == nil)
    }

    /// 10.6
    @Test func aDimmerWhoseZeroIsOff() async throws {
        let host = try await environment.start([block("lightbulb-Dimmable", "Hall Light", topics: ["getBrightness": "hall/bri", "setBrightness": "hall/bri/set"])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Hall Light"
        await broker.send("hall/bri", "40")
        #expect(await eventually { host.value(id, .lightbulb, .brightness) == .int(40) && host.value(id, .lightbulb, .on) == .bool(true) })
        broker.receive("hall/bri", string: "0")
        #expect(await eventually { host.value(id, .lightbulb, .on) == .bool(false) })
        #expect(host.value(id, .lightbulb, .brightness) == .int(40))
        try await write(host.service(id, .lightbulb)?[.on], .bool(true))
        #expect(await broker.waitFor("hall/bri/set") == ["40"])
        try await write(host.service(id, .lightbulb)?[.on], .bool(false))
        #expect(await broker.waitFor("hall/bri/set", count: 2).last == "0")
        try await write(host.service(id, .lightbulb)?[.brightness], .int(70))
        #expect(await broker.waitFor("hall/bri/set", count: 3).last == "70")
        #expect(host.value(id, .lightbulb, .on) == .bool(true))
    }

    /// 10.7, with Adaptive Lighting on the internal colour temperature.
    @Test func anHSVLight() async throws {
        let host = try await environment.start([block("lightbulb-HSV", "Strip", topics: ["getHSV": "strip/hsv", "setHSV": "strip/hsv/set"])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Strip"
        let light = try #require(host.service(id, .lightbulb))
        #expect(light.adaptiveLighting != nil)
        _ = await eventually { broker.isConnected }
        try await write(light[.hue], .int(120))
        try await write(light[.saturation], .int(100))
        try await write(light[.brightness], .int(50))
        #expect(await broker.waitFor("strip/hsv/set") == ["120,100,50"])
        try await write(light[.on], .bool(false))
        #expect(await broker.waitFor("strip/hsv/set", count: 2).last == "120,100,0")
        try await write(light[.on], .bool(true))
        #expect(await broker.waitFor("strip/hsv/set", count: 3).last == "120,100,50")
        await broker.send("strip/hsv", "240,100,30")
        #expect(await eventually { light[.hue]?.value.doubleValue == 240 && light[.brightness]?.value == .int(30) && light[.on]?.value == .bool(true) })
        broker.receive("strip/hsv", string: "240,100")
        try await Task.sleep(for: .milliseconds(20))
        #expect(broker.published(on: "strip/hsv/set").count == 3)
    }

    @Test func rgbLightsWithWhites() async throws {
        let host = try await environment.start([
            block("lightbulb-RGBW", "W", topics: ["getRGBW": "w", "setRGBW": "w/set"]),
            block("lightbulb-RGB", "Hex", topics: ["getRGB": "hex", "setRGB": "hex/set"], ["hexPrefix": "#"]),
        ])
        defer { Task { await host.stop() } }
        let light = try #require(host.service("mqttthing:W", .lightbulb))
        _ = await eventually { broker.isConnected }
        try await write(light[.on], .bool(true))
        try await write(light[.hue], .int(240))
        try await write(light[.saturation], .int(50))
        #expect(await broker.waitFor("w/set").last == "0,0,127,128")
        await broker.send("hex", "#0000ff")
        #expect(await eventually { host.value("mqttthing:Hex", .lightbulb, .hue)?.doubleValue == 240 })
        broker.receive("w", string: "127,0,0,128")
        #expect(await eventually { light[.saturation]?.value.doubleValue == 49 && light[.hue]?.value.doubleValue == 0 })
    }

    /// 10.9
    @Test func aWhiteOnlyLight() async throws {
        let host = try await environment.start([block("lightbulb-White", "Shelf", topics: ["getWhite": "shelf/w", "setWhite": "shelf/w/set"], ["hexPrefix": "#"])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Shelf"
        _ = await eventually { broker.isConnected }
        try await write(host.service(id, .lightbulb)?[.brightness], .int(50))
        #expect(await broker.waitFor("shelf/w/set") == ["#80"])
        try await write(host.service(id, .lightbulb)?[.on], .bool(false))
        #expect(await broker.waitFor("shelf/w/set", count: 2).last == "#00")
        await broker.send("shelf/w", "#fe")
        #expect(await eventually { host.value(id, .lightbulb, .brightness) == .int(99) && host.value(id, .lightbulb, .on) == .bool(true) })
    }

    /// 10.10, both ways of knowing the door's position.
    @Test func garageDoors() async throws {
        let host = try await environment.start([
            block("garageDoorOpener", "Garage", topics: [
                "setTargetDoorState": "garage/target/set", "getTargetDoorState": "garage/target", "getCurrentDoorState": "garage/current",
                "getObstructionDetected": "garage/obstruction",
            ]),
            block("garageDoorOpener", "Moving", topics: ["setTargetDoorState": "moving/target/set", "getDoorMoving": "moving/moving"]),
        ])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Garage"
        #expect(host.value(id, .garageDoorOpener, .targetDoorState) == .int(0) && host.value(id, .garageDoorOpener, .currentDoorState) == .int(1))
        try await write(host.service(id, .garageDoorOpener)?[.targetDoorState], .int(1))
        #expect(await broker.waitFor("garage/target/set") == ["C"])
        await broker.send("garage/current", "c")
        #expect(await eventually { host.value(id, .garageDoorOpener, .currentDoorState) == .int(3) })
        broker.receive("garage/current", string: "X")
        broker.receive("garage/current", string: "C")
        #expect(await eventually { host.value(id, .garageDoorOpener, .currentDoorState) == .int(1) })

        let moving = "mqttthing:Moving"
        #expect(await eventually { host.value(moving, .garageDoorOpener, .currentDoorState) == .int(0) })
        try await write(host.service(moving, .garageDoorOpener)?[.targetDoorState], .int(1))
        await broker.send("moving/moving", "true")
        #expect(await eventually { host.value(moving, .garageDoorOpener, .currentDoorState) == .int(3) })
        broker.receive("moving/moving", string: "false")
        #expect(await eventually { host.value(moving, .garageDoorOpener, .currentDoorState) == .int(1) })
    }

    /// 10.11 and 10.12
    @Test func aSecuritySystemAndAThermostat() async throws {
        let host = try await environment.start([
            block("securitySystem", "Alarm", topics: ["setTargetState": "alarm/set", "getTargetState": "alarm/target", "getCurrentState": "alarm/state"], ["restrictTargetState": [1, 3]]),
            block("thermostat", "Living Thermostat", topics: [
                "getCurrentHeatingCoolingState": "th/mode", "setTargetHeatingCoolingState": "th/target/set", "getCurrentTemperature": "th/temp",
                "setTargetTemperature": "th/setpoint/set", "getTargetTemperature": "th/setpoint",
            ], ["minTemperature": 5, "maxTemperature": 30, "restrictHeatingCoolingState": [0, 1]]),
        ])
        defer { Task { await host.stop() } }
        let alarm = "mqttthing:Alarm"
        #expect(host.value(alarm, .securitySystem, .securitySystemTargetState) == .int(3))
        #expect(host.service(alarm, .securitySystem)?[.securitySystemTargetState]?.type.validValues == [1, 3])
        try await write(host.service(alarm, .securitySystem)?[.securitySystemTargetState], .int(1))
        #expect(await broker.waitFor("alarm/set") == ["AA"])
        await broker.send("alarm/state", "T")
        #expect(await eventually { host.value(alarm, .securitySystem, .securitySystemCurrentState) == .int(4) })

        let thermostat = "mqttthing:Living Thermostat"
        let service = try #require(host.service(thermostat, .thermostat))
        #expect(service[.active] != nil && service[.temperatureDisplayUnits] != nil)
        try await write(service[.targetHeatingCoolingState], .int(1))
        try await write(service[.targetTemperature], .double(21.5))
        #expect(await broker.waitFor("th/target/set") == ["HEAT"])
        #expect(await broker.waitFor("th/setpoint/set") == ["21.5"])
        await broker.send("th/temp", "19.25")
        // Rounded to the characteristic's step of 0.1, as HAP-NodeJS does.
        #expect(await eventually { service[.currentTemperature]?.value == .double(19.3) })
        broker.receive("th/setpoint", string: "35")
        broker.receive("th/mode", string: "HEAT")
        #expect(await eventually { service[.currentHeatingCoolingState]?.value == .int(1) })
        #expect(service[.targetTemperature]?.value == .double(21.5))
    }

    /// 10.13
    @Test func aRemoteWithButtons() async throws {
        let host = try await environment.start([block(
            "statelessProgrammableSwitch", "Hall Remote", topics: ["getSwitch": ["remote/b1", "remote/b2"]],
            ["switchValues": [["s", "d", "l"]], "labelType": "numerals"])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Hall Remote"
        let accessory = try #require(host.accessory(id))
        let buttons = accessory.services.filter { $0.type.uuid == ServiceType.statelessProgrammableSwitch.uuid }
        #expect(buttons.map(\.subtype) == ["1", "2"])
        #expect(buttons.compactMap { $0[.name]?.value.stringValue } == ["Hall Remote 0", "Hall Remote 1"])
        #expect(host.value(id, .serviceLabel, .serviceLabelNamespace) == .int(1))
        let events = NIOLockedBox()
        _ = buttons[1].characteristic(.programmableSwitchEvent).observe { change in events.append(change.newValue) }
        await broker.send("remote/b2", "d")
        broker.receive("remote/b2", string: "d")
        broker.receive("remote/b1", string: "1")
        #expect(await eventually { events.values == [.int(1), .int(1)] })
    }

    /// 10.14, on a server of its own.
    @Test func aTelevision() async throws {
        let host = try await environment.start([block(
            "television", "Lounge TV", topics: [
                "setActive": "tv/power/set", "getActive": "tv/power", "setActiveInput": "tv/input/set", "getActiveInput": "tv/input", "setRemoteKey": "tv/key",
            ], ["inputs": [["name": "HDMI 1", "value": "hdmi1"], ["name": "Antenna"]]])])
        defer { Task { await host.stop() } }
        let id = "mqttthing:Lounge TV"
        #expect(await eventually { host.accessory(id) != nil })
        let tv = try #require(host.service(id, .television))
        #expect(tv[.displayOrder]?.value == .string("AQEBAQEC"))
        #expect(host.accessory(id)?.services.filter { $0.type.uuid == ServiceType.inputSource.uuid }.map(\.subtype) == ["1", "2"])
        _ = await eventually { broker.isConnected }
        try await write(tv[.activeIdentifier], .int(1))
        try await write(tv[.activeIdentifier], .int(2))
        #expect(await broker.waitFor("tv/input/set", count: 2) == ["hdmi1", "2"])
        try await write(tv[.remoteKey], .int(4))
        try await write(tv[.remoteKey], .int(15))
        try await write(host.service(id, .televisionSpeaker)?[.volumeSelector], .int(1))
        #expect(await broker.waitFor("tv/key", count: 3) == ["UP", "INFO", "VOLUME_DOWN"])
        try await write(tv[.active], .int(1))
        #expect(await broker.waitFor("tv/power/set") == ["true"])
        await broker.send("tv/input", "hdmi1")
        try await write(tv[.activeIdentifier], .int(0))
        broker.receive("tv/input", string: "hdmi1")
        #expect(await eventually { tv[.activeIdentifier]?.value == .int(1) })
    }

    /// 10.15
    @Test func aValveWithItsDurationTimer() async throws {
        let environment = TestEnvironment(timeScale: 0.0005)
        let broker = environment.broker()
        let host = try await environment.start([block(
            "valve", "Lawn", topics: ["setActive": "lawn/set", "getActive": "lawn/active", "getInUse": "lawn/inuse"],
            ["valveType": "sprinkler", "durationTimer": true, "minDuration": 60, "maxDuration": 600])])
        defer { Task { await host.stop() } }
        let valve = try #require(host.service("mqttthing:Lawn", .valve))
        #expect(valve[.setDuration]?.value == .int(600) && valve[.setDuration]?.type.minValue == 60)
        #expect(valve[.valveType]?.value == .int(1))
        _ = await eventually { broker.isConnected }
        try await write(valve[.active], .int(1))
        #expect(await broker.waitFor("lawn/set") == ["true"])
        await broker.send("lawn/inuse", "true")
        #expect(await eventually { valve[.remainingDuration]?.value == .int(600) })
        environment.clock.advance(100)
        #expect(try await read(valve[.remainingDuration]) == .int(500))
        // The 600 s timer, scaled down, turns it off.
        #expect(await broker.waitFor("lawn/set", count: 2).last == "false")
        #expect(valve[.active]?.value == .int(0))
    }

    /// 10.16
    @Test func anOutletCountsItsEnergy() async throws {
        let host = try await environment.start([block("outlet", "Plug", topics: ["getOn": "plug/on", "getWatts": "plug/power"], ["history": true])])
        defer { Task { await host.stop() } }
        let service = try #require(host.service("mqttthing:Plug", .outlet))
        await broker.send("plug/power", "100")
        #expect(await eventually { service[Eve.currentConsumption]?.value == .double(100) })
        environment.clock.advance(36)
        broker.receive("plug/power", string: "200")
        #expect(await eventually { abs((service[Eve.totalConsumption]?.value.doubleValue ?? 0) - 0.001) < 1e-9 })
        environment.clock.advance(36)
        broker.receive("plug/power", string: "0")
        #expect(await eventually { abs((service[Eve.totalConsumption]?.value.doubleValue ?? 0) - 0.003) < 1e-9 })
        let history = try #require(host.accessory("mqttthing:Plug").flatMap { EveHistory.histories(of: $0).first })
        #expect(history.kind == .energy)
    }

    /// 10.17
    @Test func publishingOptionsAndStartUp() async throws {
        let host = try await environment.start([block(
            "switch", "Opt", topics: ["setOn": "opt/set"],
            ["optimizePublishing": true, "mqttPubOptions": ["retain": true], "startPub": [["topic": "dev/reset", "message": "1"], ["topic": "dev/hello"]]])])
        defer { Task { await host.stop() } }
        #expect(await broker.waitFor("dev/reset") == ["1"])
        #expect(await broker.waitFor("dev/hello") == [""])
        let on = host.service("mqttthing:Opt", .switch)?[.on]
        try await write(on, .bool(true))
        try await write(on, .bool(false))
        try await write(on, .bool(false))
        #expect(await broker.waitFor("opt/set", count: 2) == ["true", "false"])
        try await Task.sleep(for: .milliseconds(20))
        #expect(broker.published(on: "opt/set").count == 2)
        let retained = broker.published.allSatisfy { $0.retain }
        #expect(retained)
    }

    /// 10.18
    @Test func anOnlineTopic() async throws {
        let host = try await environment.start([block(
            "switch", "Lwt", topics: ["getOn": "lwt/on", "getOnline": "dev/lwt"], ["onlineValue": "Online", "offlineValue": "Offline"])])
        defer { Task { await host.stop() } }
        let on = host.service("mqttthing:Lwt", .switch)?[.on]
        await broker.send("dev/lwt", "Offline")
        #expect(await eventually { (try? await read(on)) == nil })
        broker.receive("dev/lwt", string: "online")
        broker.receive("dev/lwt", string: "Online")
        #expect(await eventually { (try? await read(on)) != nil })
    }

    /// 10.19
    @Test func aCustomAccessory() async throws {
        let host = try await environment.start([[
            "accessory": "homebridge-mqttthing.mqttthing", "type": "custom", "name": "Porch", "integerValue": true, "url": "mqtt://broker.local",
            "services": [
                ["type": "switch", "name": "Porch Light", "topics": ["getOn": "porch/light", "setOn": "porch/light/set"]],
                ["type": "motionSensor", "name": "Porch PIR", "topics": ["getMotionDetected": "porch/pir"]],
            ],
        ]])
        defer { Task { await host.stop() } }
        let accessory = try #require(host.accessory("mqttthing:Porch"))
        #expect(accessory.information.characteristic(.model).value == .string("custom"))
        #expect(host.service("mqttthing:Porch", .switch)?.subtype == "Porch Light")
        #expect(host.service("mqttthing:Porch", .motionSensor)?.subtype == "Porch PIR")
        try await write(host.service("mqttthing:Porch", .switch)?[.on], .bool(true))
        #expect(await broker.waitFor("porch/light/set") == ["1"])
        await broker.send("porch/pir", "1")
        #expect(await eventually { host.value("mqttthing:Porch", .motionSensor, .motionDetected) == .bool(true) })
    }

    /// 10.20: `apply` is JavaScript; its topic is left out, the others work.
    @Test func applyFunctionsAreLeftOut() async throws {
        let host = try await environment.start([block(
            "lightbulb", "Apply", topics: [
                "getOn": "apply/on", "setOn": "apply/on/set",
                "setBrightness": ["topic": "apply/bri/set", "apply": "return Math.round(message * 2.55)"],
            ])])
        defer { Task { await host.stop() } }
        let light = try #require(host.service("mqttthing:Apply", .lightbulb))
        _ = await eventually { broker.isConnected }
        try await write(light[.brightness], .int(50))
        try await write(light[.on], .bool(true))
        #expect(await broker.waitFor("apply/on/set") == ["true"])
        #expect(broker.published(on: "apply/bri/set").isEmpty)
    }

    /// 10.21
    @Test func theJSONCodec() async throws {
        let host = try await environment.start([block(
            "lightbulb", "Desk RGB", topics: ["getOn": "desk/rgb/state", "setOn": "desk/rgb/cmd", "getRGB": "desk/rgb/state", "setRGB": "desk/rgb/cmd"],
            ["codec": "json", "jsonCodec": ["properties": ["on": "light.on", "RGB": "light.colour"], "fixed": ["v": 2]]])])
        defer { Task { await host.stop() } }
        let light = try #require(host.service("mqttthing:Desk RGB", .lightbulb))
        _ = await eventually { broker.isConnected }
        try await write(light[.on], .bool(true))
        try await write(light[.hue], .int(0))
        try await write(light[.saturation], .int(100))
        try await write(light[.brightness], .int(100))
        #expect(await broker.waitFor("desk/rgb/cmd") == [#"{"v":2,"light":{"on":true,"colour":"255,0,0"}}"#])
        await broker.send("desk/rgb/state", #"{"light":{"on":false,"colour":"0,0,255"}}"#)
        #expect(await eventually { light[.on]?.value == .bool(false) && light[.hue]?.value.doubleValue == 240 })
        broker.receive("desk/rgb/state", string: #"{"other":1}"#)
        try await Task.sleep(for: .milliseconds(20))
        #expect(light[.hue]?.value.doubleValue == 240)
    }

    @Test func setupKeepsTheBrokerPasswordInTheVault() async throws {
        let host = try await environment.start([block("switch", "Secret", topics: ["getOn": "s"], ["username": "me"])])
        defer { Task { await host.stop() } }
        let plugin = try #require(host.runningPlugins().first?.plugin as? MQTTThingPlugin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["broker", "username", "password"])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["broker": "mqtt://broker.local", "password": "pw"])) else {
            Issue.record("not done")
            return
        }
        #expect(outcome.credentials?["brokers"]?["mqtt://broker.local"]?["password"] == .string("pw"))
        #expect(try await plugin.discover().map(\.deviceID) == ["Secret"])
        #expect(environment.connections.first?.username == "me")
    }
}

/// Values seen by an observer.
final class NIOLockedBox: Sendable {
    private let box = NIOLockedValueBox<[HAPValue]>([])
    var values: [HAPValue] { box.withLockedValue { $0 } }
    func append(_ value: HAPValue) { box.withLockedValue { $0.append(value) } }
}
