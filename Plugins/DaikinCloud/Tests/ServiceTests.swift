import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDaikinCloud

/// The HomeKit side: the HeaterCooler and its setters (the Homebridge plugin's climate-control tests), the
/// separate Fan, the hot water tank, the feature switches.
@Suite(.timeLimit(.minutes(1)))
struct ServiceTests {
    let api = RecordingAPI()
    let cc = "climateControl"

    func climate(_ fixture: JSONValue, _ raw: [String: JSONValue] = [:], forced: NIOLockedValueBox<Int>? = nil) -> (ClimateControlService, DaikinCloudDevice) {
        let device = DaikinCloudDevice(fixture, api: api)
        let service = ClimateControlService(device: device, managementPointID: cc, name: "TEST", context: serviceContext(raw, forced: forced))
        api.reset()
        return (service, device)
    }

    // MARK: Building

    @Test func heaterCooler() throws {
        let (dx4, _) = climate(Fixture.json("dx4Airco"))
        let service = dx4.service
        #expect(service.type.uuid == ServiceType.heaterCooler.uuid)
        #expect(service.isPrimary)
        #expect(service[.swingMode] != nil)
        let cooling = service.characteristic(.coolingThresholdTemperature)
        #expect(cooling.type.minValue == 18)
        #expect(cooling.type.maxValue == 33)
        #expect(cooling.type.minStep == 0.5)
        #expect(cooling.value == .double(25))
        #expect(service.characteristic(.heatingThresholdTemperature).value == .double(22))
        let rotation = try #require(service[.rotationSpeed])
        // minValue 0, not one step: a cached value below the step must not trip HomeKit.
        #expect(rotation.type.minValue == 0)
        #expect(rotation.type.maxValue == 100)
        #expect(rotation.type.minStep == 20)
        // Heating, on, fixed speed 2 of 5.
        #expect(service.characteristic(.active).value == 1)
        #expect(service.characteristic(.currentHeaterCoolerState).value == 2)
        #expect(service.characteristic(.targetHeaterCoolerState).value == 1)
        #expect(service.characteristic(.currentTemperature).value == .double(25))
        #expect(rotation.value == .double(40))
        #expect(service.characteristic(.swingMode).value == 0)
        #expect(dx4.fanSpeed.percentIfFixed() == 40)
        // dx23 has no fan direction: no swing.
        let (dx23, _) = climate(Fixture.json("dx23Airco"))
        #expect(dx23.service[.swingMode] == nil)
        #expect(!dx23.swing.isSupported)
        #expect(dx4.swing.isSupported)
        #expect(dx4.swing.axisValue(.vertical) != nil && dx4.swing.axisValue(.horizontal) != nil)
    }

    @Test func separateFan() async throws {
        #expect(climate(Fixture.json("dx4Airco")).0.separateFan == nil)
        let (dx4, _) = climate(Fixture.json("dx4Airco"), ["showSeparateFanControl": true])
        let fan = try #require(dx4.separateFan)
        #expect(fan.subtype == "separate_fan")
        #expect(fan[.name]?.value == "TEST Fan")
        #expect(fan[.configuredName]?.value == "TEST Fan")
        #expect(fan[.active]?.value == 1)
        let rotation = try #require(fan[.rotationSpeed])
        #expect(rotation.type.minValue == 0 && rotation.type.maxValue == 100 && rotation.type.minStep == 20)
        #expect(fan[.swingMode] != nil)
        // dx23: a fan speed, no swing.
        let (dx23, _) = climate(Fixture.json("dx23Airco"), ["showSeparateFanControl": true])
        #expect(dx23.separateFan != nil)
        #expect(dx23.separateFan?[.swingMode] == nil)
        // The Fan's writes go where the HeaterCooler's go.
        try await rotation.write(60)
        try await fan.characteristic(.swingMode).write(1)
        #expect(api.recorded == [
            Write(cc, "fanControl", 3, "/operationModes/heating/fanSpeed/modes/fixed"),
            Write(cc, "fanControl", "swing", "/operationModes/heating/fanDirection/horizontal/currentMode"),
            Write(cc, "fanControl", "swing", "/operationModes/heating/fanDirection/vertical/currentMode"),
        ])
    }

    // MARK: Setters

    @Test(arguments: [
        ("dx23Airco", "cooling", 0, "auto"), ("dx23Airco", "cooling", 1, "heating"), ("dx23Airco", "cooling", 2, nil),
        ("dx23Airco2", "heating", 0, "auto"), ("dx23Airco2", "heating", 1, nil), ("dx23Airco2", "heating", 2, "cooling"),
        // Dry and fan only read back as Auto but must still switch the unit to auto.
        ("dx23Airco2", "dry", 0, "auto"), ("dx23Airco2", "fanOnly", 0, "auto"), ("dx23Airco2", "auto", 0, nil),
        ("unknownJan", "cooling", 0, "auto"), ("unknownKitchenGuests", "cooling", 2, nil),
    ] as [(String, String, Int, String?)])
    func targetState(_ fixture: String, _ mode: String, _ state: Int, _ expected: String?) async throws {
        let (service, _) = climate(Fixture.json(fixture, operationMode: mode))
        try await service.setTargetState(state)
        #expect(api.recorded == (expected.map { [Write(cc, "operationMode", .string($0))] } ?? []))
    }

    @Test(arguments: [
        ("dx23Airco2", "cooling", 80.0, [("/operationModes/cooling/fanSpeed/modes/fixed", JSONValue.number(4))]),
        ("dx23Airco2", "auto", 80, [("/operationModes/auto/fanSpeed/modes/fixed", 4)]),
        ("dx23Airco2", "fanOnly", 80, [("/operationModes/fanOnly/fanSpeed/modes/fixed", 4)]),
        ("dx23Airco2", "dry", 80, []),
        ("dx23Airco", "cooling", 100, [("/operationModes/cooling/fanSpeed/modes/fixed", 3)]),
        ("dx23Airco", "auto", 67, [("/operationModes/auto/fanSpeed/modes/fixed", 2)]),
        ("dx23Airco", "dry", 67, []),
        // Auto fan mode: switch to fixed first.
        ("unknownJan", "cooling", 67, [("/operationModes/cooling/fanSpeed/currentMode", "fixed"), ("/operationModes/cooling/fanSpeed/modes/fixed", 2)]),
        ("unknownKitchenGuests", "fanOnly", 67, [("/operationModes/fanOnly/fanSpeed/currentMode", "fixed"), ("/operationModes/fanOnly/fanSpeed/modes/fixed", 2)]),
        // In auto fan mode, the stored fixed speed coming back is a HomeKit cache replay.
        ("unknownKitchenGuests", "fanOnly", 100, []),
        // dx4: already fixed, so only the speed; 100 % is the maximum, 5 % clamps to the minimum.
        ("dx4Airco", "heating", 60, [("/operationModes/heating/fanSpeed/modes/fixed", 3)]),
        ("dx4Airco", "heating", 100, [("/operationModes/heating/fanSpeed/modes/fixed", 5)]),
        ("dx4Airco", "heating", 5, [("/operationModes/heating/fanSpeed/modes/fixed", 1)]),
        ("dx4Airco", "auto", 20, []),
        ("dx4Airco", "auto", 40, [("/operationModes/auto/fanSpeed/currentMode", "fixed"), ("/operationModes/auto/fanSpeed/modes/fixed", 2)]),
    ] as [(String, String, Double, [(String, JSONValue)])])
    func rotationSpeed(_ fixture: String, _ mode: String, _ percent: Double, _ expected: [(String, JSONValue)]) async throws {
        let (service, _) = climate(Fixture.json(fixture, operationMode: mode))
        try await service.setRotationSpeed(percent)
        #expect(api.recorded == expected.map { Write(cc, "fanControl", $0.1, $0.0) })
    }

    @Test func noFixedSpeedInDryNoWrite() async throws {
        let fixture = Fixture.json("dx4Airco", managementPoint: cc) { point in
            var fan = point["fanControl"]?.objectValue ?? [:]
            guard case .object(var value) = fan["value"], case .object(var modes) = value["operationModes"], case .object(var dry) = modes["dry"],
                case .object(var speed) = dry["fanSpeed"] else { return }
            speed["modes"] = nil
            dry["fanSpeed"] = .object(speed)
            modes["dry"] = .object(dry)
            value["operationModes"] = .object(modes)
            fan["value"] = .object(value)
            point["fanControl"] = .object(fan)
            point["operationMode"] = ["value": "dry", "values": ["auto", "dry", "cooling", "heating", "fanOnly"]]
        }
        let (service, _) = climate(fixture)
        try await service.setRotationSpeed(60)
        #expect(api.recorded.isEmpty)
        #expect(service.service[.rotationSpeed] == nil)
    }

    @Test(arguments: ["cooling", "auto", "dry", "fanOnly"])
    func coolingThresholdSyncsAuto(_ mode: String) async throws {
        let (service, _) = climate(Fixture.json("dx23Airco2", operationMode: mode))
        // Heating 13 + cooling 22 → 17.5, clamped to the auto minimum 18.
        try await service.setThreshold(.cooling, 22)
        #expect(api.recorded == [
            Write(cc, "temperatureControl", 22, "/operationModes/cooling/setpoints/roomTemperature"),
            Write(cc, "temperatureControl", 18, "/operationModes/auto/setpoints/roomTemperature"),
        ])
    }

    @Test(arguments: ["cooling", "auto", "dry", "fanOnly"])
    func heatingThresholdSyncsAuto(_ mode: String) async throws {
        let (service, _) = climate(Fixture.json("dx23Airco", operationMode: mode))
        // Heating 21 + cooling 17 → 19.
        try await service.setThreshold(.heating, 21)
        #expect(api.recorded == [
            Write(cc, "temperatureControl", 21, "/operationModes/heating/setpoints/roomTemperature"),
            Write(cc, "temperatureControl", 19, "/operationModes/auto/setpoints/roomTemperature"),
        ])
    }

    @Test(arguments: ["unknownJan", "unknownKitchenGuests"])
    func noAutoSetpointOnlyTheThreshold(_ fixture: String) async throws {
        let (service, _) = climate(Fixture.json(fixture))
        try await service.setThreshold(.cooling, 24.3)
        #expect(api.recorded == [Write(cc, "temperatureControl", 24.5, "/operationModes/cooling/setpoints/roomTemperature")])
    }

    @Test func equalityGuards() async throws {
        let forced = NIOLockedValueBox(0)
        let (service, _) = climate(Fixture.json("dx4Airco"), forced: forced)
        try await service.setThreshold(.cooling, 25)
        try await service.setThreshold(.cooling, 24.9)
        try await service.setThreshold(.heating, 22)
        try await service.setTargetState(1)
        try await service.setSwing(false)
        try await service.setActive(true)
        #expect(api.recorded.isEmpty)
        #expect(forced.withLockedValue { $0 } == 0)
        try await service.setActive(false)
        #expect(api.recorded == [Write(cc, "onOffMode", "off")])
        #expect(forced.withLockedValue { $0 } == 1)
        #expect(service.service.characteristic(.active).value == 0)
        #expect(service.service.characteristic(.currentHeaterCoolerState).value == 0)
    }

    @Test func rangeChangeSyncsAutoOnceWithTheFinalValues() async throws {
        let (service, _) = climate(Fixture.json("dx4Airco"))
        let heatingGate = Signal(), coolingGate = Signal()
        api.next { _ in await heatingGate.wait() }
        api.next { _ in await coolingGate.wait() }
        // HomeKit writes both thresholds of a range change at once.
        async let heating: Void = service.setThreshold(.heating, 19)
        try await Task.sleep(for: .milliseconds(20))
        async let cooling: Void = service.setThreshold(.cooling, 27)
        try await Task.sleep(for: .milliseconds(20))
        heatingGate.fire()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!api.recorded.contains { $0.path == "/operationModes/auto/setpoints/roomTemperature" })
        coolingGate.fire()
        _ = try await (heating, cooling)
        // (19 + 27) / 2 = 23, not the stale (19 + 25) / 2.
        #expect(api.recorded.count == 3)
        #expect(api.recorded.last == Write(cc, "temperatureControl", 23, "/operationModes/auto/setpoints/roomTemperature"))
    }

    @Test func syncsTheThresholdThatSucceeded() async throws {
        let (service, _) = climate(Fixture.json("dx4Airco"))
        let heatingGate = Signal()
        api.next { _ in
            await heatingGate.wait()
            throw DaikinError("422")
        }
        let heating = Task { try await service.setThreshold(.heating, 19) }
        try await Task.sleep(for: .milliseconds(20))
        let cooling = Task { try await service.setThreshold(.cooling, 27) }
        try await Task.sleep(for: .milliseconds(20))
        heatingGate.fire()
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await heating.value }
        try await cooling.value
        // Heating stays 22 (its write failed) + cooling 27 → 24.5.
        #expect(api.recorded.filter { $0.path == "/operationModes/auto/setpoints/roomTemperature" } == [Write(cc, "temperatureControl", 24.5, "/operationModes/auto/setpoints/roomTemperature")])
    }

    @Test func aFailedWriteIsNoResponse() async throws {
        let log = LogRecorder()
        let device = DaikinCloudDevice(Fixture.json("dx4Airco"), api: api)
        let service = ClimateControlService(device: device, managementPointID: cc, name: "Zolder", context: serviceContext(logger: log.logger))
        api.next { _ in throw DaikinError("Bad Request (400): nope") }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await service.setActive(false) }
        #expect(log.contains("[Zolder] ActiveState: write failed: Bad Request (400): nope"))
    }

    @Test func rotationSpeedFollowsTheOperationMode() throws {
        let (service, device) = climate(Fixture.json("dx4Airco"))
        #expect(!service.needsRebuild)
        device.apply(WebSocketDeviceUpdate(deviceID: device.id, embeddedID: cc, characteristicName: "operationMode", data: ["name": "operationMode", "value": "cooling"]))
        // Cooling has a fixed speed with the same range: nothing to rebuild.
        #expect(!service.needsRebuild)
        // A unit whose dry mode has no fixed speed: RotationSpeed goes.
        let dry = Fixture.json("dx23Airco2", operationMode: "cooling")
        let (other, otherDevice) = climate(dry)
        otherDevice.apply(WebSocketDeviceUpdate(deviceID: otherDevice.id, embeddedID: cc, characteristicName: "operationMode", data: ["name": "operationMode", "value": "dry"]))
        #expect(other.needsRebuild)
    }

    @Test func autoFanSwitchFollowsTheSlider() async throws {
        let (service, _) = climate(Fixture.json("unknownJan"), ["showAutoFanMode": true])
        let autoFan = try #require(service.features.feature(.autoFan)?.service)
        #expect(autoFan.characteristic(.on).value == true)
        try await service.setRotationSpeed(67)
        #expect(autoFan.characteristic(.on).value == false)
    }

    // MARK: Hot water tank

    struct TankCase: Sendable {
        var name: String
        var tank: String
        var on: Bool
        var target: Double
        var min: Double
        var max: Double
    }

    static let tanks: [TankCase] = [
        TankCase(name: "althermaHeatPump", tank: "domesticHotWaterTank", on: true, target: 48, min: 30, max: 60),
        TankCase(name: "althermaHeatPump2", tank: "domesticHotWaterTank", on: true, target: 50, min: 30, max: 60),
        TankCase(name: "althermaCrSense2", tank: "2", on: true, target: 45, min: 30, max: 60),
        TankCase(name: "althermaWithEmbeddedIdZero", tank: "2", on: true, target: 45, min: 30, max: 60),
        TankCase(name: "althermaV1ckoeln", tank: "domesticHotWaterTank", on: true, target: 46, min: 30, max: 60),
        TankCase(name: "althermaFraction", tank: "domesticHotWaterTank", on: true, target: 47, min: 30, max: 60),
        TankCase(name: "althermaMiladcerkic", tank: "domesticHotWaterTank", on: true, target: 50, min: 30, max: 55),
        TankCase(name: "althermaMiladcerkicOff", tank: "domesticHotWaterTank", on: false, target: 50, min: -127, max: 127),
    ]

    func tank(_ test: TankCase, _ raw: [String: JSONValue] = [:], fixture: JSONValue? = nil) -> HotWaterTankService {
        let device = DaikinCloudDevice(fixture ?? Fixture.json(test.name), api: api)
        let tank = HotWaterTankService(device: device, managementPointID: test.tank, accessoryName: "TANK", context: serviceContext(raw))
        api.reset()
        return tank
    }

    @Test(arguments: tanks)
    func hotWaterTank(_ test: TankCase) async throws {
        let service = tank(test).service
        #expect(service.subtype == "hot_water_tank")
        #expect(service[.name]?.value == "Hot water tank")
        #expect(service[.configuredName]?.value == "Hot water tank")
        let target = service.characteristic(.targetTemperature)
        #expect(target.type.minValue == test.min)
        #expect(target.type.maxValue == test.max)
        #expect(target.value == .double(test.target))
        #expect(service.characteristic(.currentHeatingCoolingState).value == .int(test.on ? 1 : 0))
        #expect(service.characteristic(.targetHeatingCoolingState).value == .int(test.on ? 1 : 0))

        // The rounded setpoint; nothing when unchanged.
        try await tank(test).setTargetTemperature(test.target - 1.2)
        #expect(api.recorded == [Write(test.tank, "temperatureControl", .number(jsRound((test.target - 1.2) * 2) / 2), HotWaterTankService.targetTemperaturePath)])
        api.reset()
        try await tank(test).setTargetTemperature(test.target)
        #expect(api.recorded.isEmpty)

        // Off: only when on.
        try await tank(test).setTargetState(0)
        #expect(api.recorded == (test.on ? [Write(test.tank, "onOffMode", "off")] : []))
        api.reset()
        // Heat: on when off, and never the fixed heating mode.
        try await tank(test).setTargetState(1)
        #expect(api.recorded == (test.on ? [] : [Write(test.tank, "onOffMode", "on")]))
        api.reset()
        // Auto: a mode the unit does not let anyone set is not written.
        try await tank(test).setTargetState(3)
        #expect(api.recorded == (test.on ? [] : [Write(test.tank, "onOffMode", "on")]))
        api.reset()
        // Auto with a settable mode: on, then the mode.
        let settable = Fixture.json(test.name, managementPoint: test.tank) { $0["operationMode"] = ["settable": true, "values": ["heating", "auto"], "value": "heating"] }
        try await tank(test, fixture: settable).setTargetState(3)
        #expect(api.recorded == (test.on ? [] : [Write(test.tank, "onOffMode", "on")]) + [Write(test.tank, "operationMode", "auto")])
        api.reset()

        // The tank's Powerful mode switch.
        let powered = tank(test, ["showPowerfulMode": true])
        let powerful = try #require(powered.features.feature(.powerful))
        #expect(powerful.isSupported)
        #expect(powerful.service?.subtype == "\(test.tank):powerful_mode")
        try await powerful.set(true)
        try await powerful.set(false)
        #expect(api.recorded == [Write(test.tank, "powerfulMode", "on"), Write(test.tank, "powerfulMode", "off")])
    }

    @Test func tankModesAndTargetStates() {
        let test = Self.tanks[0]
        let unit = tank(test)
        #expect(unit.currentTemperature == 48)
        // Not settable and heating: Off and Heat only.
        #expect(unit.service.characteristic(.targetHeatingCoolingState).type.validValues == [0, 1])
        let states: [(String, Int)] = [("cooling", 2), ("auto", 3), ("fanOnly", 3), ("dry", 3), ("heating", 1)]
        for (mode, state) in states {
            let fixture = Fixture.json(test.name, managementPoint: test.tank) { $0["operationMode"] = ["settable": true, "values": ["auto", "dry", "cooling", "heating", "fanOnly"], "value": .string(mode)] }
            #expect(tank(test, fixture: fixture).targetState == state)
        }
        let off = Fixture.json(test.name, managementPoint: test.tank) { $0["onOffMode"] = ["value": "off"] }
        #expect(tank(test, fixture: off).targetState == 0)
        let settable = Fixture.json(test.name, managementPoint: test.tank) { $0["operationMode"] = ["settable": true, "value": "heating"] }
        let props = HotWaterTankService.targetStateProps(DaikinCloudDevice(settable, api: api).data(test.tank, "operationMode"))
        #expect(props.validValues == nil && props.maxValue == 3)
        // Powerful mode follows its switch, off by default here.
        #expect(tank(test, ["showExtraFeatures": true]).features.feature(.powerful)?.isOn == false)
    }

    // MARK: Feature switches

    func features(_ fixture: JSONValue, _ raw: [String: JSONValue]) -> (FeatureSet, DaikinCloudDevice) {
        let device = DaikinCloudDevice(fixture, api: api)
        let set = FeatureSet(device: device, managementPointID: cc, name: "TEST", context: serviceContext(raw), kinds: FeatureSet.climateControl)
        return (set, device)
    }

    @Test func onOffSwitches() async throws {
        let (all, _) = features(Fixture.json("dx4Airco"), ["showExtraFeatures": true])
        let names = all.services.map { $0[.name]?.value.stringValue ?? "" }
        #expect(names == ["Powerful mode", "Econo mode", "Streamer mode", "Outdoor silent mode", "Indoor silent mode", "Auto fan mode", "Oscillation", "Dry operation mode", "Fan only operation mode", "Holiday mode"])
        #expect(all.services.map { $0.subtype ?? "" }.allSatisfy { $0.hasPrefix("climateControl:") })
        #expect(all.services.allSatisfy { $0.type.uuid == ServiceType.switch.uuid && $0[.configuredName] != nil })
        // Each one writes its data point.
        let expected: [(FeatureSet.Kind, Write, Write)] = [
            (.powerful, Write(cc, "powerfulMode", "on"), Write(cc, "powerfulMode", "off")),
            (.econo, Write(cc, "econoMode", "on"), Write(cc, "econoMode", "off")),
            (.streamer, Write(cc, "streamerMode", "on"), Write(cc, "streamerMode", "off")),
            (.outdoorSilent, Write(cc, "outdoorSilentMode", "on"), Write(cc, "outdoorSilentMode", "off")),
            (.indoorSilent, Write(cc, "fanControl", "quiet", "/operationModes/heating/fanSpeed/currentMode"), Write(cc, "fanControl", "fixed", "/operationModes/heating/fanSpeed/currentMode")),
            (.autoFan, Write(cc, "fanControl", "auto", "/operationModes/heating/fanSpeed/currentMode"), Write(cc, "fanControl", "fixed", "/operationModes/heating/fanSpeed/currentMode")),
            (.dry, Write(cc, "operationMode", "dry"), Write(cc, "operationMode", "auto")),
            (.fanOnly, Write(cc, "operationMode", "fanOnly"), Write(cc, "operationMode", "auto")),
        ]
        for (kind, on, off) in expected {
            let (set, _) = features(Fixture.json("dx4Airco"), ["showExtraFeatures": true])
            let feature = try #require(set.feature(kind))
            api.reset()
            try await feature.set(true)
            #expect(feature.isOn, "\(kind)")
            try await feature.set(false)
            #expect(api.recorded == [on, off], "\(kind)")
        }
        // Off: no switches. Individually on: that one.
        #expect(features(Fixture.json("dx4Airco"), [:]).0.services.isEmpty)
        #expect(features(Fixture.json("dx4Airco"), ["showEconoMode": true]).0.services.map(\.subtype) == ["climateControl:econo_mode"])
        // Not supported: no switch even when on.
        #expect(features(Fixture.json("dx23Airco"), ["showPowerfulMode": true, "showOscillationSwitch": true]).0.services.isEmpty)
    }

    @Test func aFailedSwitchWriteIsNoResponse() async throws {
        let (set, _) = features(Fixture.json("dx4Airco"), ["showEconoMode": true])
        api.next { _ in throw DaikinError("down") }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await set.feature(.econo)?.set(true) }
    }

    @Test func oscillation() async throws {
        let (set, device) = features(Fixture.json("dx4Airco"), ["showOscillationSwitch": true])
        let oscillation = try #require(set.feature(.oscillation))
        #expect(oscillation.service != nil)
        #expect(!oscillation.isOn)
        try await oscillation.set(false)
        #expect(api.recorded.isEmpty)
        try await oscillation.set(true)
        #expect(api.recorded == [
            Write(cc, "fanControl", "swing", "/operationModes/heating/fanDirection/horizontal/currentMode"),
            Write(cc, "fanControl", "swing", "/operationModes/heating/fanDirection/vertical/currentMode"),
        ])
        #expect(oscillation.isOn)
        api.reset()
        // Only the axis that differs.
        device.apply(WebSocketDeviceUpdate(deviceID: device.id, embeddedID: cc, characteristicName: "fanControl", data: [
            "name": "fanControl", "value": ["operationModes": ["heating": ["fanDirection": ["vertical": ["currentMode": ["value": "stop"]]]]]],
        ]))
        try await oscillation.set(false)
        #expect(api.recorded == [Write(cc, "fanControl", "stop", "/operationModes/heating/fanDirection/horizontal/currentMode")])
        #expect(features(Fixture.json("dx23Airco"), ["showOscillationSwitch": true]).0.feature(.oscillation)?.isSupported == false)
    }

    @Test func holiday() async throws {
        let (set, _) = features(Fixture.json("dx4Airco"), ["showHolidayMode": true])
        let holiday = try #require(set.feature(.holiday))
        #expect(holiday.isSupported && holiday.service != nil)
        #expect(!holiday.isOn)
        try await holiday.set(true)
        #expect(holiday.isOn)
        try await holiday.set(false)
        #expect(api.holidays.withLockedValue { $0.map(\.1) } == [true, false])
        api.next { _ in throw DaikinError("down") }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await holiday.set(true) }
        let noHoliday = Fixture.json("dx4Airco", managementPoint: cc) { $0["holidayMode"] = nil }
        #expect(features(noHoliday, ["showHolidayMode": true]).0.feature(.holiday)?.isSupported == false)
    }

    func firmwareFixture(supported: Bool = true, staged: Bool = false, status: String? = nil) -> JSONValue {
        Fixture.json("dx4Airco", managementPoint: "gateway") { point in
            point["isFirmwareUpdateSupported"] = ["value": .bool(supported)]
            if staged { point["firmwareUpdate"] = ["value": ["id": "fw-uuid-123", "version": "1.15.0", "description": "Fixes"]] }
            if let status { point["firmwareUpdateStatus"] = ["value": .string(status)] }
        }
    }

    @Test func firmwareUpdateSwitch() async throws {
        #expect(features(firmwareFixture(), ["showFirmwareUpdateSwitch": true]).0.feature(.firmwareUpdate)?.service != nil)
        #expect(features(firmwareFixture(supported: false), ["showFirmwareUpdateSwitch": true]).0.feature(.firmwareUpdate)?.isSupported == false)
        // Never implied by showExtraFeatures.
        #expect(features(firmwareFixture(), ["showExtraFeatures": true]).0.feature(.firmwareUpdate)?.service == nil)
        #expect(features(firmwareFixture(status: "in-progress"), ["showFirmwareUpdateSwitch": true]).0.feature(.firmwareUpdate)?.isOn == true)

        let log = LogRecorder()
        let device = DaikinCloudDevice(firmwareFixture(staged: true), api: api)
        let set = FeatureSet(device: device, managementPointID: cc, name: "TEST", context: serviceContext(["showFirmwareUpdateSwitch": true], logger: log.logger), kinds: FeatureSet.climateControl)
        let firmware = try #require(set.feature(.firmwareUpdate))
        #expect(!firmware.isOn)
        firmware.refresh()
        #expect(log.contains("Firmware update available: 1.15.0 (Fixes)"))
        try await firmware.set(true)
        #expect(api.firmware.withLockedValue { $0.map(\.1) } == ["fw-uuid-123"])
        #expect(firmware.isOn)
        #expect(log.contains("Installing firmware update 1.15.0"))

        // Nothing staged: no call, and the switch goes back off.
        let quiet = features(firmwareFixture(), ["showFirmwareUpdateSwitch": true]).0.feature(.firmwareUpdate)!
        quiet.revertDelay = .milliseconds(10)
        try await quiet.service?.characteristic(.on).write(true)
        #expect(await eventually { quiet.service?.characteristic(.on).value == false })
        #expect(api.firmware.withLockedValue { $0.count } == 1)

        // Off during an install cannot cancel it.
        let running = features(firmwareFixture(status: "in-progress"), ["showFirmwareUpdateSwitch": true]).0.feature(.firmwareUpdate)!
        running.revertDelay = .milliseconds(10)
        try await running.service?.characteristic(.on).write(false)
        #expect(await eventually { running.service?.characteristic(.on).value == true })
        #expect(api.firmware.withLockedValue { $0.count } == 1)
    }
}
