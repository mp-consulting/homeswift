import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftLGThinQ

@Suite struct DeviceModelTests {
    let model: DeviceModel

    init() throws {
        model = DeviceModel(try fixture("airconditioner-model"))
    }

    @Test func readsValueDefinitions() throws {
        #expect(model.value("undefinedKey") == nil)
        guard case .range(let min?, let max?, let step)? = model.value("airState.tempState.target") else {
            Issue.record("no target range")
            return
        }
        #expect(min < max && step > 0)
        guard case .enumeration(let options)? = model.value("airState.opMode") else {
            Issue.record("no op mode enum")
            return
        }
        #expect(!options.isEmpty)
    }

    @Test func looksUpTheFahrenheitTables() {
        // The sample's TempCelToFah maps 26 °C to 78 °F.
        #expect(model.lookupMonitorValue("TempCelToFah", "26").map { JS.number($0) } == 78)
        #expect(model.lookupMonitorValue2("TempCelToFah", "nope", "Default") == "Default")
    }

    @Test func enumLookupsBothWays() {
        let model = DeviceModel(["Value": ["mode": ["type": "Enum", "option": ["0": "@OFF", "1": "@ON", "2": "@ON"]], "level": ["data_type": "range", "value_validation": ["min": 1, "max": 5]]]])
        #expect(model.enumValue("mode", "@ON") == "1")
        #expect(model.enumName("mode", "0") == "@OFF")
        #expect(model.enumName("mode", "9") == nil)
        #expect(model.lookupMonitorName("mode", "@OFF") == "0")
        #expect(model.value("level") == .range(min: 1, max: 5, step: 1))
    }

    @Test func followsTheThinQ2ProtocolMapping() {
        let mapped = DeviceModel([
            "Monitoring": ["type": "THINQ2", "protocol": ["state": "State"]],
            "Value": ["State": ["type": "Enum", "option": ["RUNNING": "@DW_STATE_RUNNING_W"]]],
        ])
        #expect(mapped.lookupMonitorName("state", "@DW_STATE_RUNNING_W") == "RUNNING")
        let superSet = DeviceModel([
            "Monitoring": ["type": "THINQ2", "protocol": [["superSet": "hoodState.lampLevel", "value": "LampLevel"]]],
            "Value": ["LampLevel": ["type": "Range", "option": ["min": 0, "max": 2]]],
        ])
        #expect(superSet.value("hoodState.lampLevel") == .range(min: 0, max: 2, step: 1))
        let dishwasher = DeviceModel((try? fixture("dishwasher-model")) ?? [:])
        #expect(dishwasher.lookupMonitorName("state", "@DW_STATE_RUNNING_W") != nil)
    }

    @Test func monitoringValueMappings() throws {
        let washer = DeviceModel(try fixture("washer_dryer-model"))
        // The TypeScript test took the first key in JSON order, `state`; a Swift dictionary has no order, and a few
        // keys (the course lists) have no mapping.
        #expect(washer.monitoringValue?["state"] != nil)
        let mapping = try #require(washer.monitoringValueMapping("state"))
        #expect(!mapping.isEmpty)
        #expect(washer.monitoringValueMapping("invalidKey") == nil)
    }

    @Test func decodesMonitoringData() {
        let binary = DeviceModel(["Monitoring": ["type": "BINARY(BYTE)", "protocol": [
            ["value": "State", "startByte": 0, "length": 1], ["value": "Remain", "startByte": 1, "length": 2], ["value": "Past", "startByte": 5, "length": 1],
        ]]])
        let decoded = binary.decodeMonitor(Data([3, 1, 2]))
        #expect(decoded["State"] == "3")
        #expect(decoded["Remain"] == "258")
        #expect(decoded["Past"] == .null)
        let json = DeviceModel(["Monitoring": ["type": "JSON"]])
        #expect(json.decodeMonitor(Data(#"{"key":"value"}"#.utf8)) == ["key": "value"])
        #expect(json.decodeMonitor(Data("invalidJSON".utf8)) == [:])
        #expect(json.decodeMonitor(nil) == [:])
    }
}

@Suite struct DeviceTests {
    @Test @ThinQActor func readsTheDeviceRecord() throws {
        let device = ThinQDevice(try fixture("airconditioner").objectValue!)
        #expect(device.type == "AC")
        #expect(device.model == "RAC_056905")
        #expect(device.name == "MyAC")
        #expect(!device.hasValidID)
        device.data["deviceId"] = "7d0c7a8e-3c4f-4c8e-9a51-1b2b3c4d5e6f"
        #expect(device.hasValidID)
        #expect(device.online == JS.truthy(device.snapshot["online"]))
        #expect(ThinQDevice(["deviceType": 9999]).type == "undefined")
    }

    @Test func mergesSnapshotsDeeply() {
        let current: [String: JSONValue] = ["washerDryer": ["state": "RUNNING", "doorLock": "DOORLOCK_ON", "remainTimeMinute": 30], "online": true]
        let merged = mergeSnapshot(current, ["washerDryer": ["remainTimeMinute": 29]])
        #expect(merged["washerDryer"] == ["state": "RUNNING", "doorLock": "DOORLOCK_ON", "remainTimeMinute": 29])
        #expect(merged["online"] == true)
        #expect(mergeSnapshot(nil, ["a": 1]) == ["a": 1])
        #expect(mergeSnapshot(["list": [1, 2]], ["list": [3]])["list"] == [3])
    }

    @Test func registry() {
        for type in ["AC", "AIR_PURIFIER", "AERO_TOWER", "DEHUMIDIFIER"] { #expect(DeviceRegistry.snapshotKey(type) == nil) }
        #expect(DeviceRegistry.snapshotKey("REFRIGERATOR") == "refState")
        #expect(DeviceRegistry.snapshotKey("WASH_TOWER_2") == "washer")
        #expect(DeviceRegistry.snapshotKey("HOOD") == "hoodState")
        #expect(DeviceRegistry.isExternal("DISHWASHER") && DeviceRegistry.isExternal("OVEN") && DeviceRegistry.isExternal("MICROWAVE") && !DeviceRegistry.isExternal("AC"))
        #expect(DeviceRegistry.handler(for: "AC", platform: "thinq1") == AirConditionerV1.self)
        #expect(DeviceRegistry.handler(for: "DISHWASHER", platform: "thinq1") == nil)
        #expect(DeviceRegistry.handler(for: "TV", platform: "thinq2") == nil)
        #expect(DeviceRegistry.hasModelFeature("AC", "airClean", model: "RAC_056905"))
        #expect(!DeviceRegistry.hasModelFeature("AC", "airClean", model: "RAC_000000"))
        #expect(DeviceRegistry.category("DISHWASHER") == .sprinkler && DeviceRegistry.category("OVEN") == .thermostat)
    }
}

@Suite struct ThinQ1Tests {
    static let model = DeviceModel([
        "Value": [
            "Operation": ["type": "Enum", "option": ["0": "@AC_MAIN_OPERATION_OFF_W", "1": "@AC_MAIN_OPERATION_RIGHT_ON_W"]],
            "TempCur": ["type": "Range", "option": ["min": 16, "max": 30]],
            "TempCfg": ["type": "Range", "option": ["min": 18, "max": 30]],
            "VentMode": ["type": "Enum", "option": ["0": "@VENT_MODE_NORMAL", "1": "@VENT_MODE_BOOST"]],
            "Error": ["type": "Enum", "option": ["0": "@ERROR_NONE", "5": "@ERROR_FAN"]],
            "DoorOpenState": ["type": "Enum", "option": ["0": "CLOSE", "1": "OPEN"], "default": "CLOSE"],
            "TempRefrigerator": ["type": "Range", "option": ["min": 1, "max": 7], "default": "3"],
            "TempFreezer": ["type": "Range", "option": ["min": -23, "max": -15], "default": "-18"],
            "TempUnit": ["type": "Enum", "option": ["0": "F", "1": "C"], "default": "1"],
            "State": ["type": "Enum", "option": ["0": "@WM_STATE_POWER_OFF_W", "1": "@WM_STATE_RUNNING_W", "2": "@WM_STATE_END_W"]],
            "PreState": ["type": "Enum", "option": ["0": "@WM_STATE_POWER_OFF_W", "1": "@WM_STATE_RUNNING_W"]],
        ],
    ])

    @Test func airState() {
        let state = ThinQ1.airState(Self.model, ["Operation": "1", "OpMode": "0", "TempCur": "25", "TempCfg": "22", "WindStrength": "4", "Jet": "1", "SensorHumidity": "45"])
        #expect(state["airState.operation"] == true)
        #expect(state["airState.opMode"] == 0)
        #expect(state["airState.tempState.current"] == 25)
        #expect(state["airState.tempState.target"] == 22)
        #expect(state["airState.windStrength"] == 4)
        #expect(state["airState.wMode.jet"] == 1)
        #expect(state["airState.humidity.current"] == 45)
        let off = ThinQ1.airState(Self.model, ["Operation": "0", "TempCur": "5", "TempCfg": "10"])
        #expect(off["airState.operation"] == false)
        #expect(off["airState.tempState.current"] == 16)
        #expect(off["airState.tempState.target"] == 18)
        let purifier = ThinQ1.airPurifierState(Self.model, ["Operation": "1", "AirFast": "0", "SensorPM2": "9"])
        #expect(purifier["airState.operation"] == true && purifier["airState.miscFuncState.airFast"] == false && purifier["airState.quality.PM2"] == 9)
    }

    @Test func hoodState() {
        let hood = ThinQ1.hoodState(Self.model, ["VentMode": "1", "Error": "5", "VentLevel": "2", "LampLevel": "1", "HoodState": "1"])["hoodState"]
        #expect(hood?["ventMode"] == "@VENT_MODE_BOOST")
        #expect(hood?["error"] == "@ERROR_FAN")
        #expect(hood?["ventLevel"] == 2 && hood?["lampLevel"] == 1 && hood?["hoodState"] == "USING")
    }

    @Test func refState() {
        let state = ThinQ1.refState(Self.model, ["TempRefrigerator": "4", "TempFreezer": "-20", "DoorOpenState": "1", "TempUnit": "1", "IcePlus": "1"])["refState"]
        #expect(state?["fridgeTemp"] == 4 && state?["freezerTemp"] == -20)
        #expect(state?["atLeastOneDoorOpen"] == "OPEN" && state?["tempUnit"] == "CELSIUS")
        #expect(state?["expressMode"] == "1" && state?["expressFridge"] == nil)
        let defaults = ThinQ1.refState(Self.model, [:])["refState"]
        #expect(defaults?["fridgeTemp"] == 3 && defaults?["freezerTemp"] == -18 && defaults?["atLeastOneDoorOpen"] == "CLOSE")
    }

    @Test func washerDryer() {
        let washer = ThinQ1.washerDryer(Self.model, ["State": "1", "PreState": "0", "Remain_Time_H": "1", "Remain_Time_M": "30", "TCLCount": 3])["washerDryer"]
        #expect(washer?["state"] == "RUNNING" && washer?["preState"] == "POWEROFF")
        #expect(washer?["remainTimeHour"] == 1 && washer?["remainTimeMinute"] == 30 && washer?["TCLCount"] == 3)
        #expect(ThinQ1.washerDryer(Self.model, [:])["washerDryer"]?["state"] == "POWEROFF")
    }

    @Test @ThinQActor func preparesBinaryControlData() {
        let device = ThinQDevice(["deviceId": "dev1", "snapshot": ["raw": [:]]])
        device.deviceModel = DeviceModel(["ControlWifi": ["type": "BINARY(BYTE)", "action": ["SetControl": ["data": "[{{myKey}}]"]]]])
        let data = ThinQ1.prepareControlData(device, key: "myKey", value: true, workID: "w")
        #expect(data["value"] == "ControlData" && data["format"] == "B64")
        #expect(data["data"] == .string(Data([1]).base64EncodedString()))
        #expect(ThinQ1.prepareControlData(device, key: "myKey", value: "non-numeric", workID: "w")["data"] == .string(Data([0]).base64EncodedString()))
        // Bytes above 127 travel as UTF-8, as Buffer.from(String.fromCharCode(...)) encodes them.
        #expect(ThinQ1.prepareControlData(device, key: "myKey", value: 200, workID: "w")["data"] == .string(Data([0xC3, 0x88]).base64EncodedString()))
        device.deviceModel = DeviceModel([:])
        let json = ThinQ1.prepareControlData(device, key: "Jet", value: 1, workID: "w")
        #expect(json["value"] == ["Jet": 1] && json["data"] == "" && json["cmd"] == "Control" && json["deviceId"] == "dev1")
    }

    @Test @ThinQActor func transformsADevice() {
        let device = ThinQDevice(["deviceId": "dev", "deviceType": 401, "platformType": "thinq1", "snapshot": [:]])
        device.deviceModel = DeviceModel(["Monitoring": ["type": "BINARY(BYTE)", "protocol": [["value": "Operation", "startByte": 0, "length": 1], ["value": "TempCur", "startByte": 1, "length": 1]]],
            "Value": ["Operation": ["type": "Enum", "option": ["0": "@AC_MAIN_OPERATION_OFF_W", "1": "@AC_MAIN_OPERATION_RIGHT_ON_W"]]]])
        ThinQ1.transform(device, monitorData: nil)
        #expect(device.snapshot["raw"] == .null && device.snapshot["online"] == nil)
        ThinQ1.transform(device, monitorData: Data([1, 24]))
        #expect(device.snapshot["airState.operation"] == true && device.snapshot["airState.tempState.current"] == 24)
        #expect(device.snapshot["online"] == true && device.online)
        #expect(device.snapshot["raw"]?["TempCur"] == "24")
    }
}

@Suite struct ControlTests {
    @ThinQActor
    func thinq(_ lg: FakeLG, model: JSONValue) async throws -> ThinQ {
        let client = RequestClient(transport: lg, logger: testLogger)
        let api = ThinQAPI(country: "US", language: "en-US", client: client, logger: testLogger)
        try api.setRefreshToken("refresh")
        try await api.ready()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lg-control-\(UUID().uuidString)")
        let thinq = ThinQ(api: api, persist: Persist(directory: directory), mqtt: noMQTT, logger: testLogger)
        lg.add(device: ["deviceId": "dev1", "deviceType": 401, "alias": "A"], model: model)
        let device = ThinQDevice(["deviceId": "dev1", "deviceType": 401, "modelJsonUri": "https://fake-cdn.lgthinq.test/models/dev1.json"])
        _ = try await thinq.loadDeviceModel(device)
        return thinq
    }

    @Test @ThinQActor func coercesValuesToTheModel() async throws {
        let lg = FakeLG()
        let thinq = try await thinq(lg, model: ["Value": [
            "power": ["type": "Bit", "option": [:]], "temp": ["type": "Range", "option": ["min": 16, "max": 30]],
            "mode": ["type": "Enum", "option": ["1": "Cool", "2": "Heat"]],
        ]])
        #expect(try await thinq.deviceControl("dev1", values: ["dataKey": "power", "dataValue": true, "nested": ["flag": false]]))
        #expect(lg.commands.last?["dataValue"] == 1)
        #expect(lg.commands.last?["nested"]?["flag"] == 0)
        #expect(lg.commands.last?["ctrlKey"] == "basicCtrl" && lg.commands.last?["command"] == "Set")
        _ = try await thinq.deviceControl("dev1", values: ["dataSetList": ["temp": "23", "mode": "Cool"]], command: "Operation", ctrlKey: "favoriteCtrl")
        #expect(lg.commands.last?["dataSetList"]?["temp"] == 23)
        #expect(lg.commands.last?["dataSetList"]?["mode"] == "1")
        #expect(lg.commands.last?["ctrlKey"] == "favoriteCtrl" && lg.commands.last?["command"] == "Operation")
        lg.state.withLockedValue { $0.commandResult = "0001" }
        #expect(try await !thinq.deviceControl("dev1", values: ["dataKey": "temp", "dataValue": 20]))
        await #expect(throws: ThinQError.self) { try await thinq.deviceControl("dev1", values: [:], command: "Get") }
    }

    @Test @ThinQActor func keepsTheModelOnceLoaded() async throws {
        let lg = FakeLG()
        let thinq = try await thinq(lg, model: ["Info": ["version": "1.0"], "Value": [:]])
        let device = ThinQDevice(["deviceId": "dev1", "deviceType": 401, "modelJsonUri": "https://fake-cdn.lgthinq.test/models/dev1.json"])
        let before = lg.requests.filter { $0.url.absoluteString.contains("fake-cdn") }.count
        _ = try await thinq.loadDeviceModel(device)
        #expect(lg.requests.filter { $0.url.absoluteString.contains("fake-cdn") }.count == before)
        // And on disk: a new instance reads the stored model.
        let other = ThinQ(api: thinq.api, persist: thinq.persist, mqtt: noMQTT, logger: testLogger)
        _ = try await other.loadDeviceModel(device)
        #expect(lg.requests.filter { $0.url.absoluteString.contains("fake-cdn") }.count == before)
    }

    @Test @ThinQActor func selectsTheWashTower2Root() async throws {
        let lg = FakeLG()
        let thinq = try await thinq(lg, model: [:])
        lg.add(device: ["deviceId": "tower", "deviceType": 223], model: ["Info": ["version": "3.1", "defaultTargetDeviceRoot": "washer"], "washer": ["Value": ["state": ["type": "Enum", "option": [:]]]]])
        let device = ThinQDevice(["deviceId": "tower", "deviceType": 223, "modelJsonUri": "https://fake-cdn.lgthinq.test/models/tower.json"])
        let model = try await thinq.loadDeviceModel(device)
        #expect(model.data["Value"]?["state"] != nil)
    }
}

@Suite struct StatusTests {
    static let model = DeviceModel((try? fixture("airconditioner-model")) ?? [:])

    @Test func airConditionerStatus() throws {
        let snapshot = try fixture("airconditioner-snapshot").objectValue!
        let status = ACStatus(data: snapshot, deviceModel: Self.model, temperatureUnit: "C")
        #expect(status.isPowerOn && status.opMode == ACOpMode.cool)
        #expect(status.currentTemperature == 26.5 && status.targetTemperature == 26 && status.targetTemperatureLG == 26)
        #expect(status.isLightOn && status.isSwingOn)
        #expect(status.currentConsumption == 5.64)
        #expect(status.isWindStrengthAuto && status.windStrength == 50)
        #expect(status.airQuality == .init(isOn: true, overall: 0, pm2: 0, pm10: 0))
        #expect(status.type == "RAC")
        #expect(!ACStatus(data: [:], deviceModel: Self.model, temperatureUnit: "C").isPowerOn)
        #expect(ACStatus(data: [:], deviceModel: Self.model, temperatureUnit: "C").airQuality == nil)
        #expect(ACStatus(data: ["airState.humidity.current": 455], deviceModel: Self.model, temperatureUnit: "C").currentRelativeHumidity == 45.5)
        let range = try #require(status.temperatureRange(status.coolingLimits()))
        #expect(range.min > 0 && range.max > range.min)
    }

    @Test func fahrenheitUsesTheModelTables() throws {
        let snapshot = try fixture("airconditioner-snapshot").objectValue!
        let status = ACStatus(data: snapshot, deviceModel: Self.model, temperatureUnit: "F")
        #expect(status.targetTemperature == TemperatureConverter.fToC(78))
        #expect(status.converter.fromHomeKit(status.targetTemperature) == 26)
        #expect(status.converter.toHomeKit(22.5) == TemperatureConverter.fToC(73))
        let plain = TemperatureConverter(isFahrenheit: true, deviceModel: nil)
        for celsius in stride(from: 16.0, through: 30, by: 0.5) {
            let homeKit = plain.toHomeKit(celsius)
            #expect(plain.toHomeKit(plain.fromHomeKit(homeKit)) == homeKit)
            #expect(abs(plain.fromHomeKit(homeKit) - celsius) <= 0.5)
        }
        #expect(TemperatureConverter.roundToHalf(22.3) == 22.5 && TemperatureConverter.roundToHalf(22.2) == 22)
        #expect(TemperatureConverter(isFahrenheit: false, deviceModel: nil).toHomeKit(22.5) == 22.5)
    }

    @Test func fanSpeeds() {
        for (percent, strength) in [(0.0, 2), (1, 2), (12, 2), (13, 3), (50, 4), (75, 5), (100, 6), (150, 6), (-5, 2)] {
            #expect(ACFan.windStrength(percent: percent) == strength, "\(percent)")
        }
        for (strength, percent) in [(JSONValue.number(2), 1), (3, 25), (4, 50), (6, 100), (8, 50), ("x", 50), (9, 50)] {
            #expect(ACFan.percent(windStrength: strength) == percent, "\(strength)")
        }
        for strength in ACFan.speeds { #expect(ACFan.windStrength(percent: Double(ACFan.percent(windStrength: .number(Double(strength))))) == strength) }
        #expect(AirPurifierStatus.windStrength(rotationSpeed: 0) == 2 && AirPurifierStatus.windStrength(rotationSpeed: 2.4) == 4 && AirPurifierStatus.windStrength(rotationSpeed: 9) == 7)
        #expect(AirPurifierStatus.rotationSpeed(windStrength: 6) == 3 && AirPurifierStatus.rotationSpeed(windStrength: 5) == 2)
        #expect(Dehumidifier.windStrength(speed: 0) == 2 && Dehumidifier.windStrength(speed: 2) == 6)
    }

    @Test func purifierStatus() {
        let status = AirPurifierStatus([
            "airState.operation": 1, "airState.opMode": 14, "airState.windStrength": 6, "airState.circulate.rotate": 1, "airState.lightingState.signal": 1,
            "airState.quality.overall": 2, "airState.quality.PM2": 12, "airState.quality.PM10": 20, "airState.miscFuncState.airFast": 1,
            "airState.filterMngStates.useTime": 100, "airState.filterMngStates.maxTime": 1000,
        ])
        #expect(status.isPowerOn && status.isNormalMode && status.isSwing && status.isLightOn && status.isAirFastEnable)
        #expect(status.rotationSpeed == 3)
        #expect(status.airQuality == .init(isOn: true, overall: 2, pm2: 12, pm10: 20))
        #expect(status.filterRemainingPercent == 90)
        #expect(!AirPurifierStatus.needsFilterChange(90) && AirPurifierStatus.needsFilterChange(4))
    }

    @Test func washerStatus() {
        let model = DeviceModel([:])
        let running = WasherDryerStatus(data: ["state": "RUNNING", "remainTimeHour": 1, "remainTimeMinute": 5, "TCLCount": 40, "doorLock": "DOORLOCK_ON"], deviceModel: model)
        #expect(running.isRunning && running.remainDuration == 3900 && running.tclCount == 30 && running.isDoorLocked)
        let ended = WasherDryerStatus(data: ["state": "END", "remainTimeHour": 1], deviceModel: model)
        #expect(ended.isPowerOn && !ended.isRunning && ended.remainDuration == 0)
        #expect(!WasherDryerStatus(data: ["state": "POWEROFF"], deviceModel: model).isPowerOn)
    }

    @Test func refrigeratorStatus() {
        let model = DeviceModel([:])
        #expect(RefrigeratorStatus(data: ["waterFilter1RemainP": 42], deviceModel: model).waterFilterRemain == 42)
        #expect(RefrigeratorStatus(data: ["waterFilter": "3_month"], deviceModel: model).waterFilterRemain == 75)
        #expect(RefrigeratorStatus(data: ["waterFilter": "NONE"], deviceModel: model).waterFilterRemain == 0)
        #expect(RefrigeratorStatus(data: [:], deviceModel: model).tempUnit == "CELSIUS")
        #expect(RefrigeratorStatus(data: ["atLeastOneDoorOpen": "CLOSE"], deviceModel: model).isDoorClosed)
    }
}

@Suite struct CookingTests {
    @Test func helpers() {
        #expect(Cooking.truncateName(String(repeating: "a", count: 64)) == String(repeating: "a", count: 60) + "...")
        #expect(Cooking.truncateName("short") == "short")
        #expect(Cooking.toNumber("12") == 12 && Cooking.toNumber(" ") == 0 && Cooking.toNumber(nil) == 0 && Cooking.toNumber(.number(.infinity)) == 0)
        #expect(Cooking.nonZero(5) == 5 && Cooking.nonZero(0) == nil && Cooking.nonZero("5") == nil)
        #expect(Cooking.includes("ON_X", "ON") && !Cooking.includes(nil, "ON"))
        #expect(Cooking.excludes("OFF", "ON") && !Cooking.excludes(nil, "ON"))
        #expect(Cooking.sumTimeFields(1, 2, 3) == 3723)
        #expect(Cooking.sumTimeFields(["upperTimerHour": 1, "upperTimerSecond": 5], prefix: "upperTimer") == 3605)
        #expect(Cooking.formatClock(5400) == "1:30:00" && Cooking.formatClock(300) == "0:05:00" && Cooking.formatClock(36000) == "10:00:00")
        #expect(Cooking.formatDuration(3600) == "1:00:00 Hour" && Cooking.formatDuration(7200) == "2:00:00 Hours" && Cooking.formatDuration(60) == "0:01:00 Minutes")
        #expect(Cooking.capitalize("SOME_VALUE") == "Some_value" && Cooking.capitalize(5) == "")
        #expect(Cooking.tempCtoF(100) == 212 && Cooking.tempFtoC(350) == 176.5)
        #expect(Cooking.toCelsius(350, "FAHRENHEIT") == 176.5 && Cooking.toCelsius(180.2, "CELSIUS") == 180 && Cooking.toCelsius(180.2, nil) == 180)
        #expect(Cooking.clampCookTemp(Cooking.ovenLimits, mode: "BAKE", unit: nil, 500) == 285)
        #expect(Cooking.clampCookTemp(Cooking.ovenLimits, mode: "BAKE", unit: "FAHRENHEIT", .nan) == 170)
        #expect(Cooking.clampCookTemp(Cooking.ovenLimits, mode: "CONVECTION_BAKE", unit: "FAHRENHEIT", 200) == 300)
        #expect(Cooking.clampCookTemp(Cooking.ovenLimits, mode: "BROIL", unit: "FAHRENHEIT", 600) == 600)
        #expect(Cooking.clampCookTemp(Cooking.microwaveLimits, mode: "DEHYDRATE", unit: "CELSIUS", 100) == 92)
        #expect(Cooking.enteredState("RUNNING", "END", "END") && !Cooking.enteredState("END", "END", "END"))
        let backLeft = Cooking.Burner(index: 2, label: "Back Left", subtype: "s", identifier: 11)
        #expect(Cooking.burnerStatus([:], backLeft) == ("Back Left Burner Not in Use", false))
        #expect(Cooking.burnerStatus(["cooktop2CooktopState": "INIT"], backLeft) == ("Back Left Burner Not in Use", false))
        #expect(Cooking.burnerStatus(["cooktop2CooktopState": "ON", "cooktop2OperationTimeMinute": 5], backLeft) == ("Back Left Burner is On. Cooking for 0:05:00 Minutes", true))
        let date = Date(timeIntervalSince1970: 1_704_114_300) // 2024-01-01 13:05:00 UTC
        #expect(Cooking.formatDateTime(date, timeZone: TimeZone(identifier: "UTC")!) == "Monday, January 1, 2024 at 13:05:00 UTC")
        #expect(Cooking.formatDateTime(date, short: true, timeZone: TimeZone(identifier: "UTC")!) == "Mon, Jan 1, 2024, 13:05:00 UTC")
    }

    @Test func cookTimes() {
        var tracker = CookTimeTracker(.init(start: "S", cookTime: "C", end: "E", timer: "T"))
        let now = Date(timeIntervalSince1970: 1_704_114_300)
        tracker.update(cooking: true, targetSeconds: 1800, timerSeconds: 60, now: now)
        #expect(tracker.showTime && tracker.showTimer)
        #expect(tracker.cookTimeString == "Duration: 0:30:00 Minutes" && tracker.timerString == "Timer: 0:01:00 Minutes")
        #expect(tracker.startString.hasPrefix("Start: "))
        let start = tracker.startString
        tracker.update(cooking: true, targetSeconds: 1800, timerSeconds: 0, now: now.addingTimeInterval(60))
        #expect(tracker.startString == start && !tracker.showTimer && tracker.timerString == "T")
        tracker.update(cooking: false, targetSeconds: 0, timerSeconds: 0, now: now)
        #expect(!tracker.showTime && tracker.startString == "S" && tracker.cookTimeString == "C" && tracker.endString == "E")
    }

    @Test @ThinQActor func commandGateDropsOverlappingCommands() async throws {
        let gate = CommandGate(cooldown: .milliseconds(50))
        let ran = NIOLockedValueBox(0)
        async let first = gate.run {
            try await Task.sleep(for: .milliseconds(30))
            ran.withLockedValue { $0 += 1 }
        }
        try await Task.sleep(for: .milliseconds(5))
        #expect(try await gate.run { ran.withLockedValue { $0 += 1 } } == false)
        #expect(try await first)
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await gate.run { ran.withLockedValue { $0 += 1 } })
        #expect(ran.withLockedValue { $0 } == 2)
    }

    @Test @ThinQActor func pauserReplaysAnUpdate() async throws {
        let replayed = NIOLockedValueBox(0)
        let pauser = UpdatePauser(fallback: .milliseconds(200)) { replayed.withLockedValue { $0 += 1 } }
        pauser.pause(.milliseconds(30))
        #expect(pauser.isPaused)
        pauser.markPending()
        #expect(await eventually { await !pauser.isPaused && replayed.withLockedValue { $0 } == 1 })
        pauser.pause(.milliseconds(10))
        try await Task.sleep(for: .milliseconds(40))
        #expect(replayed.withLockedValue { $0 } == 1, "nothing to replay")
    }
}
