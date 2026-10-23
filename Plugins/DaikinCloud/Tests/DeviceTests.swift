import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftDaikinCloud

/// The device model: reading by path, local writes, WebSocket merges, holiday mode, firmware; and the
/// capability detection of every fixture (the Homebridge plugin's capability-detector tests).
@Suite struct DeviceTests {
    let api = RecordingAPI()
    let cc = "climateControl"

    func device(_ name: String = "dx4Airco") -> DaikinCloudDevice { DaikinCloudDevice(Fixture.json(name), api: api) }

    @Test func reads() {
        let dx4 = device()
        #expect(dx4.deviceModel == "dx4")
        #expect(dx4.data(cc, "name").value == "Zolder")
        #expect(dx4.data(cc, "sensoryData", "/roomTemperature").value == 25)
        #expect(dx4.data(cc, "controlMode").value == nil)
        #expect(dx4.data(cc, "nothing").value == nil)
        #expect(dx4.data("nowhere", "name").value == nil)
        let setpoint = dx4.data(cc, "temperatureControl", "/operationModes/cooling/setpoints/roomTemperature")
        #expect(setpoint == DataPoint(object: ["value": 25, "minValue": 18, "maxValue": 33, "stepValue": 0.5, "settable": true]))
        let altherma = device("althermaHeatPump")
        #expect(altherma.data("climateControlMainZone", "name").value == "Altherma")
        #expect(altherma.data("domesticHotWaterTank", "sensoryData", "/tankTemperature").value == 48)
        #expect(DaikinAccessory.displayName(altherma) == "Altherma")
        #expect(DaikinAccessory.displayName(dx4) == "Zolder")
        dx4.update(raw: .object((Fixture.json("dx4Airco").objectValue ?? [:]).merging(["id": "new-id"]) { $1 }))
        #expect(dx4.id == "new-id")
    }

    @Test func webSocketPushesMergePartialTrees() {
        let dx4 = device()
        #expect(dx4.data(cc, "fanControl", "/operationModes/heating/fanSpeed/modes/fixed").number != nil)
        dx4.apply(WebSocketDeviceUpdate(deviceID: dx4.id, embeddedID: cc, managementPointID: nil, characteristicName: "fanControl", data: [
            "name": "fanControl",
            "value": ["operationModes": ["cooling": ["fanDirection": ["vertical": ["currentMode": ["name": "currentMode", "value": "stop", "settable": true, "values": ["stop", "swing", "windNice"]]]]]]],
        ]))
        #expect(dx4.data(cc, "fanControl", "/operationModes/cooling/fanDirection/vertical/currentMode").value == "stop")
        #expect(dx4.data(cc, "fanControl", "/operationModes/heating/fanSpeed/modes/fixed").number != nil)
        #expect(dx4.data(cc, "fanControl", "/operationModes/cooling/fanSpeed/modes/fixed").number != nil)
        #expect(dx4.data(cc, "fanControl", "/operationModes/cooling/fanDirection/horizontal/currentMode").string != nil)
        #expect(dx4.data(cc, "fanControl", "/operationModes/auto/fanSpeed/currentMode").string != nil)

        dx4.apply(WebSocketDeviceUpdate(deviceID: dx4.id, embeddedID: cc, managementPointID: nil, characteristicName: "operationMode", data: ["name": "operationMode", "value": "heating"]))
        #expect(dx4.data(cc, "operationMode").value == "heating")
        dx4.apply(WebSocketDeviceUpdate(deviceID: dx4.id, embeddedID: cc, managementPointID: nil, characteristicName: "operationMode", data: ["name": "operationMode", "value": "cooling", "values": ["cooling", "heating"]]))
        #expect(dx4.data(cc, "operationMode").values == ["cooling", "heating"])
        // A characteristic the device did not have is created.
        dx4.apply(WebSocketDeviceUpdate(deviceID: dx4.id, embeddedID: cc, managementPointID: nil, characteristicName: "newThing", data: ["name": "newThing", "value": 1, "settable": false]))
        #expect(dx4.data(cc, "newThing") == DataPoint(object: ["value": 1, "settable": false]))
    }

    @Test func writesShowAtOnce() async throws {
        let dx4 = device()
        #expect(dx4.data(cc, "fanControl", "/operationModes/heating/fanSpeed/currentMode").value == "fixed")
        try await dx4.setData(cc, "fanControl", "auto", path: "/operationModes/heating/fanSpeed/currentMode")
        #expect(dx4.data(cc, "fanControl", "/operationModes/heating/fanSpeed/currentMode").value == "auto")
        try await dx4.setData(cc, "fanControl", 4, path: "/operationModes/heating/fanSpeed/modes/fixed")
        #expect(dx4.data(cc, "fanControl", "/operationModes/heating/fanSpeed/modes/fixed").value == 4)
        try await dx4.setData(cc, "operationMode", "cooling")
        #expect(dx4.data(cc, "operationMode").value == "cooling")
        // A path that does not resolve changes nothing (and does not fail).
        let before = dx4.raw
        try await dx4.setData(cc, "fanControl", "auto", path: "/operationModes/nonexistent/fanSpeed/currentMode")
        #expect(dx4.raw == before)
        #expect(api.recorded == [
            Write(cc, "fanControl", "auto", "/operationModes/heating/fanSpeed/currentMode"), Write(cc, "fanControl", 4, "/operationModes/heating/fanSpeed/modes/fixed"),
            Write(cc, "operationMode", "cooling"), Write(cc, "fanControl", "auto", "/operationModes/nonexistent/fanSpeed/currentMode"),
        ])
    }

    @Test func holidayMode() async throws {
        let dx4 = device()
        #expect(dx4.data(cc, "holidayMode").value?["enabled"] == false)
        try await dx4.setHolidayMode(cc, enabled: true)
        #expect(api.holidays.withLockedValue { $0.map(\.1) } == [true])
        #expect(dx4.data(cc, "holidayMode").value?["enabled"] == true)
        let offline = DaikinCloudDevice(Fixture.json("dx4Airco").replacing("isCloudConnectionUp", with: ["value": false]), api: api)
        await #expect(throws: DeviceOfflineError(deviceID: offline.id)) { try await offline.setHolidayMode(cc, enabled: false) }
        await #expect(throws: DeviceOfflineError(deviceID: offline.id)) { try await offline.setData(cc, "onOffMode", "on") }
        #expect(api.holidays.withLockedValue { $0.count } == 1)
        #expect("\(DeviceOfflineError(deviceID: "abc"))" == "Device abc is offline (cloud connection down)")
    }

    @Test func firmware() async throws {
        let dx4 = device()
        let gateway = try #require(dx4.managementPointID(type: "gateway"))
        #expect(gateway == "gateway")
        #expect(dx4.firmwareUpdateInfo(gateway) == nil)
        await #expect(throws: DaikinError("No firmware update is currently staged for this device")) { try await dx4.triggerFirmwareUpdate(gateway) }
        let staged = DaikinCloudDevice(Fixture.json("dx4Airco", managementPoint: "gateway") { point in
            point["firmwareUpdate"] = ["value": ["id": "fw-uuid-123", "version": "1.15.0", "description": "Fixes"]]
            point["isFirmwareUpdateSupported"] = ["value": true]
        }, api: api)
        #expect(staged.firmwareUpdateInfo(gateway) == FirmwareUpdateInfo(id: "fw-uuid-123", version: "1.15.0", description: "Fixes"))
        #expect(staged.isFirmwareUpdateSupported(gateway))
        try await staged.triggerFirmwareUpdate(gateway)
        #expect(api.firmware.withLockedValue { $0.map(\.1) } == ["fw-uuid-123"])
        #expect(staged.firmwareUpdateStatus(gateway) == "in-progress")
    }

    @Test func maskingForTheLog() throws {
        let masked = DaikinCloudDevice.masked(Fixture.json("althermaHeatPump"))
        let text = masked.text()
        let gateway = try #require(masked["managementPoints"]?.arrayValue?.first { $0["embeddedId"] == "gateway" })
        #expect(gateway["macAddress"]?["value"] == "REDACTED")
        #expect(gateway["ipAddress"]?["value"] == "REDACTED")
        #expect(gateway["ssid"]?["value"] == "REDACTED")
        #expect(!text.contains(Fixture.json("althermaHeatPump")["managementPoints"]?[0]?["macAddress"]?["value"]?.stringValue ?? "never"))
        // The input is left alone.
        #expect(Fixture.json("althermaHeatPump") != masked)
        #expect(DaikinCloudDevice.masked(["id": "x"]) == ["id": "x"])
    }

    // MARK: Capabilities

    struct ACCase: Sendable {
        var name: String
        var expected: [String: Bool]
        var cooling: TemperatureConstraints?
        var heating: TemperatureConstraints?
        var auto: TemperatureConstraints?
    }

    /// A setpoint's range, as the fixtures carry it.
    struct TemperatureConstraints: Sendable, Equatable {
        var minValue: Double
        var maxValue: Double
        var stepValue: Double
    }

    struct TemperatureCapabilities: Sendable, Equatable {
        var cooling: TemperatureConstraints?
        var heating: TemperatureConstraints?
        var auto: TemperatureConstraints?
        var domesticHotWater: TemperatureConstraints?
    }

    /// The setpoint ranges of a management point, read the way the services read them.
    static func temperatures(_ device: DaikinCloudDevice, _ managementPointID: String) -> TemperatureCapabilities {
        func constraints(_ mode: String, _ setpoint: String) -> TemperatureConstraints? {
            let data = device.data(managementPointID, "temperatureControl", DataPaths.setpoint(mode, setpoint))
            guard let min = data.minValue, let max = data.maxValue, let step = data.stepValue else { return nil }
            return TemperatureConstraints(minValue: min, maxValue: max, stepValue: step)
        }
        return TemperatureCapabilities(
            cooling: constraints("cooling", "roomTemperature"), heating: constraints("heating", "roomTemperature"), auto: constraints("auto", "roomTemperature"),
            domesticHotWater: constraints("heating", "domesticHotWaterTemperature"))
    }

    static let none: [String: Bool] = [
        "powerful": false, "econo": false, "streamer": false, "outdoorSilent": false, "indoorSilent": false, "autoFan": false,
        "swingVertical": false, "swingHorizontal": false, "fanControl": false,
    ]

    static func flags(_ c: DeviceCapabilities) -> [String: Bool] {
        [
            "powerful": c.hasPowerfulMode, "econo": c.hasEconoMode, "streamer": c.hasStreamerMode, "outdoorSilent": c.hasOutdoorSilentMode,
            "indoorSilent": c.hasIndoorSilentMode, "autoFan": c.hasAutoFanMode, "swingVertical": c.hasSwingModeVertical, "swingHorizontal": c.hasSwingModeHorizontal,
            "fanControl": c.hasFanControl, "holiday": c.hasHolidayMode, "dry": c.hasDryOperationMode, "fanOnly": c.hasFanOnlyOperationMode,
        ]
    }

    static let airConditioners: [ACCase] = [
        ACCase(name: "dx4Airco", expected: [
            "powerful": true, "econo": true, "streamer": true, "outdoorSilent": true, "indoorSilent": true, "autoFan": true,
            "swingVertical": true, "swingHorizontal": true, "fanControl": true, "holiday": true, "dry": true, "fanOnly": true,
        ], cooling: .init(minValue: 18, maxValue: 33, stepValue: 0.5), heating: .init(minValue: 10, maxValue: 31, stepValue: 0.5), auto: .init(minValue: 18, maxValue: 30, stepValue: 0.5)),
        ACCase(name: "dx23Airco", expected: none.merging(["fanControl": true, "holiday": true, "dry": true, "fanOnly": true]) { $1 },
            cooling: .init(minValue: 16, maxValue: 32, stepValue: 0.5), heating: .init(minValue: 16, maxValue: 32, stepValue: 0.5), auto: .init(minValue: 16, maxValue: 32, stepValue: 0.5)),
        ACCase(name: "dx23Airco2", expected: none.merging(["powerful": true, "indoorSilent": true, "autoFan": true, "swingVertical": true, "fanControl": true, "holiday": true]) { $1 },
            cooling: .init(minValue: 18, maxValue: 32, stepValue: 0.5), heating: .init(minValue: 10, maxValue: 30, stepValue: 0.5), auto: .init(minValue: 18, maxValue: 30, stepValue: 0.5)),
        ACCase(name: "unknownJan", expected: none.merging(["autoFan": true, "fanControl": true, "holiday": true]) { $1 },
            cooling: .init(minValue: 16, maxValue: 32, stepValue: 0.1)),
        ACCase(name: "unknownKitchenGuests", expected: none.merging(["autoFan": true, "fanControl": true, "holiday": true]) { $1 },
            cooling: .init(minValue: 16, maxValue: 32, stepValue: 0.1)),
    ]

    @Test(arguments: airConditioners)
    func airConditionerCapabilities(_ test: ACCase) {
        let unit = device(test.name)
        let flags = Self.flags(CapabilityDetector(device: unit, managementPointID: cc).capabilities())
        for (key, value) in test.expected {
            #expect(flags[key] == value, "\(test.name): \(key)")
        }
        #expect(Self.temperatures(unit, cc) == TemperatureCapabilities(cooling: test.cooling, heating: test.heating, auto: test.auto))
    }

    @Test func everyOperationModeOfAFullFeaturedUnit() {
        let modes = CapabilityDetector(device: device("dx23Airco"), managementPointID: cc).capabilities().supportedOperationModes
        #expect(modes.sorted() == ["auto", "cooling", "dry", "fanOnly", "heating"])
    }

    struct AlthermaCase: Sendable {
        var name: String
        var climate: String
        var tank: String
        var room: TemperatureCapabilities
        var hotWater: TemperatureConstraints
    }

    static let roomRanges = TemperatureCapabilities(
        cooling: .init(minValue: 15, maxValue: 35, stepValue: 0.5), heating: .init(minValue: 12, maxValue: 30, stepValue: 0.5), auto: .init(minValue: 12, maxValue: 30, stepValue: 0.5))
    static let dhw = TemperatureConstraints(minValue: 30, maxValue: 60, stepValue: 1)

    static let althermas: [AlthermaCase] = [
        AlthermaCase(name: "althermaHeatPump", climate: "climateControlMainZone", tank: "domesticHotWaterTank",
            room: .init(heating: .init(minValue: 12, maxValue: 30, stepValue: 0.5), auto: .init(minValue: 12, maxValue: 30, stepValue: 0.5)), hotWater: dhw),
        AlthermaCase(name: "althermaHeatPump2", climate: "climateControlMainZone", tank: "domesticHotWaterTank", room: .init(), hotWater: dhw),
        AlthermaCase(name: "althermaCrSense2", climate: "1", tank: "2", room: roomRanges, hotWater: dhw),
        AlthermaCase(name: "althermaWithEmbeddedIdZero", climate: "1", tank: "2", room: roomRanges, hotWater: dhw),
        AlthermaCase(name: "althermaV1ckoeln", climate: "climateControlMainZone", tank: "domesticHotWaterTank", room: .init(), hotWater: dhw),
        AlthermaCase(name: "althermaFraction", climate: "climateControlMainZone", tank: "domesticHotWaterTank", room: .init(), hotWater: dhw),
        AlthermaCase(name: "althermaMiladcerkic", climate: "climateControlMainZone", tank: "domesticHotWaterTank", room: .init(), hotWater: .init(minValue: 30, maxValue: 55, stepValue: 1)),
        AlthermaCase(name: "althermaMiladcerkicOff", climate: "climateControlMainZone", tank: "domesticHotWaterTank", room: .init(), hotWater: .init(minValue: -127, maxValue: 127, stepValue: 1)),
    ]

    @Test(arguments: althermas)
    func althermaCapabilities(_ test: AlthermaCase) {
        let unit = device(test.name)
        let climate = CapabilityDetector(device: unit, managementPointID: test.climate)
        let flags = Self.flags(climate.capabilities())
        let expected = Self.none.merging(["dry": false, "fanOnly": false, "holiday": true]) { $1 }
        for (key, value) in expected {
            #expect(flags[key] == value, "\(test.name): \(key)")
        }
        #expect(Self.temperatures(unit, test.climate) == test.room)
        let tank = CapabilityDetector(device: unit, managementPointID: test.tank)
        let tankCapabilities = tank.capabilities()
        #expect(tankCapabilities.hasPowerfulMode)
        #expect(!tankCapabilities.hasEconoMode)
        #expect(!tankCapabilities.hasHolidayMode)
        #expect(tankCapabilities.supportedOperationModes == ["heating"])
        #expect(Self.temperatures(unit, test.tank) == TemperatureCapabilities(domesticHotWater: test.hotWater))
        #expect(DeviceProfile.match(unit) == .altherma)
    }

    @Test func summaries() {
        #expect(CapabilityDetector(device: device(), managementPointID: cc).capabilities().summary
            == "powerful, econo, streamer, outdoor-silent, indoor-silent, auto-fan, fan-speed, swing, dry-mode, fan-only, holiday")
        #expect(CapabilityDetector(device: device("althermaHeatPump"), managementPointID: "climateControlMainZone").capabilities().summary == "holiday")
        #expect(DeviceProfile.match(device()) == .airConditioning)
        #expect(DeviceProfile.match(DaikinCloudDevice(["id": "x", "managementPoints": []], api: api)) == .unknown)
    }
}

extension JSONValue {
    /// The object with one key replaced.
    func replacing(_ key: String, with value: JSONValue) -> JSONValue {
        guard case .object(var object) = self else { return self }
        object[key] = value
        return .object(object)
    }
}
