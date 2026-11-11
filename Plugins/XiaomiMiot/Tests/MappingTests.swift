import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftXiaomiMiot

/// The generic mapping on the saved specs (docs/clean-room/XiaomiMiot.md sections 7 and 13) and the conversions (12.12).
@Suite struct MappingTests {
    /// What each accessory was shown so far, as the device keeps its values.
    let shown = NIOLockedValueBox<[ObjectIdentifier: PropertyValues]>([:])

    /// Shows `values` (by `siid.piid`) through the bindings of what changed, with what was shown before, as a poll does.
    func show(_ built: BuiltAccessory, _ values: [String: JSONValue]) {
        var changed: PropertyValues = [:]
        for (key, value) in values { changed[PropertyKey(key)!] = value }
        let all = shown.withLockedValue { shown in
            shown[ObjectIdentifier(built.accessory), default: [:]].merge(changed) { $1 }
            return shown[ObjectIdentifier(built.accessory)] ?? [:]
        }
        for binding in built.bindings where !binding.keys.isDisjoint(with: Set(changed.keys)) { binding.apply(all, true) }
    }

    func keys(_ list: [String]) -> [PropertyKey] { list.map { PropertyKey($0)! }.sorted() }

    // MARK: 12.12

    @Test func conversions() throws {
        #expect([6500.0, 2700, 4000, 1700].map(MiotConversions.mireds(kelvin:)) == [154, 370, 250, 588])
        let bounds = MiotConversions.miredBounds(kelvinLower: 2700, kelvinUpper: 6500)
        #expect(bounds.min == 154 && bounds.max == 370)
        #expect(MiotConversions.miredBounds(kelvinLower: 1700, kelvinUpper: 6500).max == 500)
        #expect([154.0, 370, 250].map(MiotConversions.kelvin(mireds:)) == [6494, 2703, 4000])
        #expect(MiotConversions.hueSaturation(rgb: 0xFF8000) == (30, 100))
        #expect(MiotConversions.rgb(hue: 240, saturation: 50) == 8_421_631)
        #expect(MiotConversions.rgb(hue: 0, saturation: 0) == 16_777_215)
        // 4 levels 1–4.
        #expect((0..<4).map { MiotConversions.speed(levelIndex: $0, count: 4) } == [25, 50, 75, 100])
        #expect([1.0, 37, 38, 63, 88, 100].map { MiotConversions.levelIndex(speed: $0, count: 4)! + 1 } == [1, 1, 2, 3, 4, 4])
        // 3 levels, Auto excluded.
        #expect((0..<3).map { MiotConversions.speed(levelIndex: $0, count: 3) } == [33, 67, 100])
        #expect([1.0, 33, 50, 67, 84].map { MiotConversions.levelIndex(speed: $0, count: 3)! + 1 } == [1, 1, 2, 2, 3])
        #expect(MiotConversions.levelIndex(speed: 0, count: 3) == nil)
        let ranged = MiotSpec.Property(siid: 2, iid: 11, urn: MiotURN("urn:miot-spec-v2:property:speed-level:0:x:1"), description: "", format: "int32",
                                       access: ["read", "write"], unit: nil, range: [200, 2000, 10], values: nil, name: "x:speed-level")
        #expect(MiotConversions.percent(1100, of: ranged) == 50)
        #expect(MiotConversions.value(percent: 50, of: ranged) == 1100)
        var percentage = ranged
        percentage.range = [1, 100, 1]
        #expect(MiotConversions.percent(50, of: percentage) == 50)
        #expect(MiotConversions.value(percent: 0, of: percentage) == 1)
        #expect([5.0, 7, 8, 30, 56].map { MiotConversions.airQuality(pm25: $0, breakpoints: MiotConversions.defaultBreakpoints) } == [1, 1, 2, 3, 5])
        #expect(MiotConversions.isLowBattery(20) && !MiotConversions.isLowBattery(21))
        #expect(MiotConversions.needsChange(filterLife: 5) && !MiotConversions.needsChange(filterLife: 6))
        #expect(MiotConversions.validBreakpoints([10, 20, 35, 60]) == [10, 20, 35, 60])
        #expect(MiotConversions.validBreakpoints([10, 5, 35, 60]) == nil)
        #expect(MiotConversions.homeKitName("Mode - Color") == "Mode Color")
        #expect(MiotConversions.homeKitName(" 'x' ") == "x")
        #expect(MiotConversions.homeKitName("—") == "Unnamed")
        #expect(MiotConversions.friendlyName("fan:toggle") == "Toggle")
        #expect(MiotAccessoryBuilder.manufacturer(model: "yeelink.light.colorc") == "Yeelight Technology")
        #expect(MiotAccessoryBuilder.manufacturer(model: "zhimi.fan.za5") == "Zhimi")
        #expect(MiotAccessoryBuilder.manufacturer(model: "nodot") == "Xiaomi")
    }

    /// 6.1: the highest released version of each model, whatever the list's order.
    @Test func registryChoosesTheHighestReleasedVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("miot-registry-\(UUID().uuidString)")
        let registry = SpecRegistry(http: FakeHTTP(), file: { JSONFile(url: directory.appendingPathComponent("spec_\($0).json")) }, logger: testLogger)
        #expect(try await registry.choose(model: "zhimi.fan.za5").version == 4)
        #expect(try await registry.choose(model: "cuco.plug.v3").version == 2)
        #expect(try await registry.choose(model: "dreame.vacuum.p2009").version == 2)
        let spec = try await registry.spec(model: "zhimi.fan.za5")
        #expect(spec.type == "urn:miot-spec-v2:device:fan:0000A005:zhimi-za5:4")
        // Kept: a new registry reads it without asking.
        let offline = SpecRegistry(http: FakeHTTP(), file: { JSONFile(url: directory.appendingPathComponent("spec_\($0).json")) }, logger: testLogger)
        #expect(await offline.cached(model: "zhimi.fan.za5")?.type == spec.type)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Devices of one model starting together: one fetch of its spec, one list of each status.
    @Test func registryFetchesAModelOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("miot-registry-\(UUID().uuidString)")
        let http = FakeHTTP()
        let registry = SpecRegistry(http: http, file: { JSONFile(url: directory.appendingPathComponent("spec_\($0).json")) }, logger: testLogger)
        let types = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await registry.spec(model: "cuco.plug.v3").type } }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(types.count == 1)
        #expect(http.count("https://miot-spec.org/miot-spec-v2/instance?type=") == 1)
        #expect(http.count("https://miot-spec.org/miot-spec-v2/instances?status=released") == 1)
        // A refresh the same day asks nothing; the list is kept a day.
        _ = try await registry.spec(model: "cuco.plug.v3", refresh: true)
        #expect(http.count("https://miot-spec.org/miot-spec-v2/instances") == 1)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 6.3: homebridge-miot's names: a second service of a name gets its siid, items their own names.
    @Test func names() {
        let spec = Fixture.spec("dreame.vacuum.p2009")
        #expect(spec.property(named: "brush-cleaner10:brush-life-level")?.key == PropertyKey(siid: 10, piid: 2))
        #expect(spec.property(named: "brush-cleaner:brush-life-level")?.key == PropertyKey(siid: 9, piid: 2))
        #expect(spec.action(named: "filter:reset-filter-life").map { "\($0.siid).\($0.iid)" } == "11.1")
        #expect(spec.property(named: "2.1")?.name == "vacuum:status")
        #expect(spec.deviceType == "vacuum")
        // The vendor indicator light of cuco.plug.v3 is not the standard one.
        let plug = Fixture.spec("cuco.plug.v3")
        #expect(plug.service("indicator-light")?.iid == 13)
        #expect(plug.mainService?.iid == 2)
    }

    // MARK: Section 13

    @Test func colorLight() throws {
        let built = try #require(buildFixture("yeelink.light.colorc", options: ["modeControl": true]))
        let accessory = built.accessory
        #expect(accessory.category == .lightbulb)
        let light = try #require(accessory.service(.lightbulb))
        #expect(light.isPrimary)
        for type in [CharacteristicType.on, .brightness, .colorTemperature, .hue, .saturation] { #expect(light[type] != nil, "\(type.name)") }
        #expect(light[.colorTemperature]?.type.minValue == 154)
        #expect(light[.colorTemperature]?.type.maxValue == 370)
        #expect(built.adaptiveLighting.count == 1)
        #expect(accessory.switchNames() == ["Mode Color", "Mode Ct"])
        #expect(built.polled == keys(["2.1", "2.2", "2.3", "2.4", "2.5"]))
        // A 0 % brightness writes the range's minimum.
        let brightness = try #require(Fixture.spec("yeelink.light.colorc").property(named: "2.2"))
        #expect(MiotConversions.value(percent: 0, of: brightness) == 1)
        show(built, ["2.1": true, "2.2": 40, "2.3": 4000, "2.4": .number(0xFF8000), "2.5": 2])
        #expect(light[.on]?.value == .bool(true))
        #expect(light[.brightness]?.value == .int(40))
        #expect(light[.colorTemperature]?.value == .int(250))
        #expect(light[.hue]?.value == .double(30))
        // Mode switches: on only while the light is.
        #expect(accessory.service(subtype: "ctl-2-5-2")?[.on]?.value == .bool(true))
        show(built, ["2.1": false])
        #expect(accessory.service(subtype: "ctl-2-5-2")?[.on]?.value == .bool(false))
        // Without the flag, no switch.
        #expect(try #require(buildFixture("yeelink.light.colorc")).accessory.services(.switch).isEmpty)
    }

    @Test func plug() throws {
        let built = try #require(buildFixture("cuco.plug.v3", options: ["ledControl": true, "buzzerControl": true]))
        let accessory = built.accessory
        #expect(accessory.category == .outlet)
        let outlet = try #require(accessory.service(.outlet))
        #expect(outlet.isPrimary)
        #expect(outlet[EveCharacteristic.currentConsumption] != nil)
        #expect(outlet[.lockPhysicalControls] == nil)
        #expect(accessory.service(subtype: "ctl-13-1")?[.name]?.value == .string("Led"))
        #expect(accessory.services(.switch).count == 1)
        #expect(!built.polled.contains(PropertyKey(siid: 11, piid: 1)))
        #expect(built.polled.contains(PropertyKey(siid: 11, piid: 2)))
        show(built, ["2.1": true, "11.2": 12.6])
        #expect(outlet[.outletInUse]?.value == .bool(true))
        #expect(outlet[EveCharacteristic.currentConsumption]?.value == .int(13))
    }

    @Test func airPurifier() throws {
        let built = try #require(buildFixture("zhimi.airpurifier.ma4", options: ["buzzerControl": true, "ledControl": true, "modeControl": true, "fanLevelControl": true]))
        let accessory = built.accessory
        #expect(accessory.category == .airPurifier)
        let purifier = try #require(accessory.service(.airPurifier))
        for type in [CharacteristicType.active, .currentAirPurifierState, .targetAirPurifierState, .rotationSpeed, .lockPhysicalControls] {
            #expect(purifier[type] != nil, "\(type.name)")
        }
        let filter = try #require(accessory.service(subtype: "filter-4"))
        #expect(filter[.resetFilterIndication] != nil)
        let quality = try #require(accessory.service(.airQualitySensor))
        #expect(quality[.pm10Density] == nil && quality[.vocDensity] == nil)
        let temperature = try #require(accessory.service(.temperatureSensor))
        #expect(temperature[.currentTemperature]?.type.minValue == -40 && temperature[.currentTemperature]?.type.maxValue == 125)
        #expect(temperature[.currentTemperature]?.type.minStep == 0.1)
        #expect(accessory.service(.humiditySensor) != nil)
        #expect(Set(purifier.linked.map(\.subtype)).isSuperset(of: ["filter-4", "environment-3-temperature", "environment-3-relative-humidity"]))
        #expect(accessory.service(subtype: "ctl-5-1")?[.name]?.value == .string("Buzzer"))
        #expect(accessory.service(subtype: "ctl-6-6")?[.name]?.value == .string("Led"))
        #expect(accessory.switchNames().filter { $0.hasPrefix("Mode") } == ["Mode Auto", "Mode Sleep", "Mode Favorite", "Mode None"])
        #expect(accessory.switchNames().filter { $0.hasPrefix("Fan Level") } == ["Fan Level Level1", "Fan Level Level2", "Fan Level Level3"])
        // The favourite level (7.9): 10.10, 0–14; idle while the motor (10.8) is still.
        #expect(built.polled.contains(PropertyKey(siid: 10, piid: 10)))
        show(built, ["2.2": true, "2.5": 2, "10.10": 7, "10.8": 0, "3.6": 8, "4.3": 5, "2.4": 2])
        #expect(purifier[.rotationSpeed]?.value == .double(50))
        #expect(purifier[.targetAirPurifierState]?.value == .int(0))
        #expect(purifier[.currentAirPurifierState]?.value == .int(1))
        #expect(quality[.airQuality]?.value == .int(2))
        #expect(filter[.filterChangeIndication]?.value == .int(1))
        // Fan level switches apply in Favorite only.
        #expect(accessory.service(subtype: "ctl-2-4-2")?[.on]?.value == .bool(true))
        show(built, ["2.5": 0, "10.8": 900])
        #expect(purifier[.targetAirPurifierState]?.value == .int(1))
        #expect(purifier[.currentAirPurifierState]?.value == .int(2))
        #expect(accessory.service(subtype: "ctl-2-4-2")?[.on]?.value == .bool(false))
        // Custom breakpoints.
        let custom = try #require(buildFixture("zhimi.airpurifier.ma4", defaults: MappingDefaults(pm25Breakpoints: [10, 20, 35, 60])))
        show(custom, ["3.6": 8])
        #expect(custom.accessory.service(.airQualitySensor)?[.airQuality]?.value == .int(1))
    }

    @Test func humidifier() throws {
        let built = try #require(buildFixture("zhimi.humidifier.ca4", options: ["buzzerControl": true, "screenControl": true, "fanLevelControl": true]))
        let accessory = built.accessory
        #expect(accessory.category == .humidifier)
        let humidifier = try #require(accessory.service(.humidifierDehumidifier))
        #expect(humidifier[.targetHumidifierDehumidifierState]?.type.validValues == [1])
        let threshold = try #require(humidifier[.relativeHumidityHumidifierThreshold])
        #expect(threshold.type.minValue == 30 && threshold.type.maxValue == 80 && threshold.type.minStep == 1)
        #expect(humidifier[.waterLevel] != nil && humidifier[.lockPhysicalControls] != nil && humidifier[.rotationSpeed] != nil)
        #expect(accessory.service(.temperatureSensor) != nil)
        #expect(accessory.service(.humiditySensor) == nil)
        #expect(accessory.switchNames().filter { $0.hasPrefix("Screen") }.count == 3)
        #expect(accessory.switchNames().filter { $0.hasPrefix("Fan Level") }.count == 4)
        #expect(accessory.service(subtype: "ctl-4-1") != nil)
        show(built, ["2.1": true, "3.9": 45, "2.5": 2, "2.7": 64, "2.6": 50])
        #expect(humidifier[.currentHumidifierDehumidifierState]?.value == .int(2))
        #expect(humidifier[.currentRelativeHumidity]?.value == .double(45))
        #expect(humidifier[.rotationSpeed]?.value == .double(67))
        #expect(humidifier[.waterLevel]?.value == .double(50))
        show(built, ["2.5": 0])
        #expect(humidifier[.rotationSpeed]?.value == .double(0))
    }

    @Test func fan() throws {
        let built = try #require(buildFixture("zhimi.fan.za5", options: [
            "buzzerControl": true, "ledControl": true, "modeControl": true, "ioniserControl": true, "offDelayControl": true, "fanLevelControl": true,
            "swingControl": true, "horizontalAngleButtons": true, "moveControl": true,
        ]))
        let accessory = built.accessory
        #expect(accessory.category == .fan)
        let fan = try #require(accessory.service(.fanv2))
        for type in [CharacteristicType.active, .currentFanState, .rotationSpeed, .swingMode, .lockPhysicalControls] { #expect(fan[type] != nil, "\(type.name)") }
        let temperature = try #require(accessory.service(.temperatureSensor))
        #expect(temperature[.currentTemperature]?.type.minValue == -30)
        #expect(accessory.service(.humiditySensor) != nil)
        #expect(accessory.service(subtype: "ctl-5-1") != nil)
        let led = try #require(accessory.service(subtype: "ctl-4-3"))
        #expect(led.type.uuid == ServiceType.lightbulb.uuid)
        #expect(accessory.switchNames().contains("Mode Natural Wind") && accessory.switchNames().contains("Mode Straight Wind"))
        #expect(accessory.service(subtype: "ctl-2-11")?[.name]?.value == .string("Ioniser"))
        // 15.7: 2.10 has no unit of time, so no off delay control.
        #expect(accessory.service(subtype: "ctl-2-10") == nil)
        #expect(accessory.switchNames().filter { $0.hasPrefix("Fan Level") }.count == 4)
        #expect(accessory.service(subtype: "ctl-2-3")?[.name]?.value == .string("Horizontal Swing"))
        #expect(accessory.switchNames().contains("Horizontal Angle 30") && accessory.switchNames().contains("Horizontal Angle 120"))
        #expect(accessory.service(subtype: "ctl-6-3-left") != nil && accessory.service(subtype: "ctl-6-3-right") != nil)
        // The speed (7.9): the vendor 6.8 as a percentage; idle while 6.4 is 0.
        show(built, ["2.1": true, "6.8": 42, "6.4": 0, "2.3": true])
        #expect(fan[.rotationSpeed]?.value == .double(42))
        #expect(fan[.currentFanState]?.value == .int(1))
        #expect(fan[.swingMode]?.value == .int(1))
        show(built, ["6.4": 1200])
        #expect(fan[.currentFanState]?.value == .int(2))
    }

    @Test(arguments: [true, false]) func climateSwingCapabilities(_ writableHorizontal: Bool) throws {
        let property: (Int, String, [String]) -> JSONValue = { id, name, access in
            ["iid": .number(Double(id)), "type": .string("urn:miot-spec-v2:property:\(name):0:test:1"),
             "description": .string(name), "format": "bool", "access": .array(access.map { .string($0) })]
        }
        let spec = try MiotSpec(json: ["type": "urn:miot-spec-v2:device:air-conditioner:0:test:1", "services": [
            ["iid": 2, "type": "urn:miot-spec-v2:service:air-conditioner:0:test:1", "description": "AC", "properties": [property(1, "on", ["read", "write"])]] ,
            ["iid": 3, "type": "urn:miot-spec-v2:service:fan-control:0:test:1", "description": "Fan", "properties": [
                property(1, "vertical-swing", ["read", "write", "notify"]),
                property(2, "horizontal-swing", writableHorizontal ? ["read", "write", "notify"] : ["read", "notify"]),
            ]],
        ]])
        let built = try #require(MiotAccessoryBuilder(spec: spec, model: "test.ac", name: "Test", accessoryID: "miot:1",
            serialNumber: "1", firmware: "1", options: DeviceOptions([:]), defaults: MappingDefaults(), handle: detachedHandle,
            timings: fastTimings.accessory, logger: testLogger, makeAdaptiveLighting: { AdaptiveLightingController($0, mode: .automatic) }).build())
        let service = try #require(built.accessory.service(.heaterCooler))
        #expect(service[ClimateSwing.vertical.characteristic] != nil)
        #expect((service[ClimateSwing.horizontal.characteristic] != nil) == writableHorizontal)
        show(built, ["3.1": true, "3.2": false])
        #expect(service[ClimateSwing.vertical.characteristic]?.value == .bool(true))
        if writableHorizontal { #expect(service[ClimateSwing.horizontal.characteristic]?.value == .bool(false)) }
        show(built, ["3.1": false, "3.2": true])
        #expect(service[ClimateSwing.vertical.characteristic]?.value == .bool(false))
        if writableHorizontal { #expect(service[ClimateSwing.horizontal.characteristic]?.value == .bool(true)) }
    }

    @Test func heater() throws {
        let built = try #require(buildFixture("zhimi.heater.mc2", options: ["buzzerControl": true, "ledControl": true, "offDelayControl": true]))
        let accessory = built.accessory
        #expect(accessory.category == .heater)
        let heater = try #require(accessory.service(.heaterCooler))
        #expect(heater[.targetHeaterCoolerState]?.type.validValues == [1])
        let threshold = try #require(heater[.heatingThresholdTemperature])
        #expect(threshold.type.minValue == 18 && threshold.type.maxValue == 28 && threshold.type.minStep == 1)
        #expect(heater[.temperatureDisplayUnits]?.value == .int(0))
        #expect(heater[.lockPhysicalControls] != nil)
        #expect(accessory.service(subtype: "ctl-6-1") != nil)
        #expect(accessory.service(subtype: "ctl-7-3")?.type.uuid == ServiceType.lightbulb.uuid)
        let delay = try #require(accessory.service(subtype: "ctl-3-1"))
        #expect(delay[.brightness] != nil)
        show(built, ["2.1": true, "4.7": 19.5, "2.5": 22, "3.1": 6])
        #expect(heater[.currentHeaterCoolerState]?.value == .int(2))
        #expect(heater[.currentTemperature]?.value == .double(19.5))
        #expect(heater[.heatingThresholdTemperature]?.value == .double(22))
        #expect(delay[.brightness]?.value == .int(50))
        show(built, ["2.1": false])
        #expect(heater[.currentHeaterCoolerState]?.value == .int(1))
    }

    @Test func curtain() throws {
        let built = try #require(buildFixture("lumi.curtain.hagl08", options: ["motorControl": true]))
        let accessory = built.accessory
        #expect(accessory.category == .windowCovering)
        #expect(accessory.supportsIdentify)
        let covering = try #require(accessory.service(.windowCovering))
        #expect(covering[.holdPosition] != nil && covering[.obstructionDetected] != nil)
        #expect(accessory.switchNames() == ["Motor Control Pause", "Motor Control Open", "Motor Control Close", "Motor Control Toggle"])
        #expect(!built.polled.contains(PropertyKey(siid: 2, piid: 2)))
        show(built, ["2.3": 30, "2.7": 80, "2.6": 1, "2.1": 0])
        #expect(covering[.currentPosition]?.value == .int(30))
        #expect(covering[.targetPosition]?.value == .int(80))
        #expect(covering[.positionState]?.value == .int(1))
        #expect(covering[.obstructionDetected]?.value == .bool(false))
        show(built, ["2.6": 2])
        #expect(covering[.positionState]?.value == .int(0))
        show(built, ["2.6": 0])
        #expect(covering[.positionState]?.value == .int(2))
    }

    @Test func miotVacuum() throws {
        let built = try #require(buildFixture("dreame.vacuum.p2009", options: ["modeControl": true]))
        let accessory = built.accessory
        let fan = try #require(accessory.service(.fanv2))
        #expect(fan.isPrimary && fan.standsFor == .cleaningRobot)
        #expect(fan[.statusFault] != nil && fan[.statusActive] != nil)
        #expect(accessory.service(subtype: "brush-cleaner-9")?[.name]?.value == .string("Main Cleaning Brush"))
        #expect(accessory.service(subtype: "brush-cleaner-10")?[.name]?.value == .string("Side Cleaning Brush"))
        #expect(accessory.service(subtype: "filter-11")?[.name]?.value == .string("Filter"))
        #expect(accessory.services(.filterMaintenance).count == 3)
        #expect(accessory.switchNames() == ["Mode Silent", "Mode Basic", "Mode Strong", "Mode Full Speed"])
        #expect(built.polled == keys(["2.1", "2.2", "2.3", "3.1", "3.2", "9.2", "10.2", "11.1"]))
        let battery = try #require(accessory.service(.battery))
        show(built, ["2.1": 1, "2.2": 0, "3.1": 20, "3.2": 2])
        #expect(fan[.active]?.value == .int(1))
        #expect(battery[.statusLowBattery]?.value == .int(1))
        #expect(battery[.chargingState]?.value == .int(0))
        show(built, ["2.1": 7, "3.1": 21, "3.2": 1])
        #expect(fan[.active]?.value == .int(1))
        #expect(battery[.statusLowBattery]?.value == .int(0))
        #expect(battery[.chargingState]?.value == .int(1))
        show(built, ["2.1": 4])
        #expect(fan[.active]?.value == .int(0))
        #expect(fan[.statusFault]?.value == .int(1))
        show(built, ["3.2": 5])
        #expect(battery[.chargingState]?.value == .int(0))
    }

    @Test func sensor() throws {
        let built = try #require(buildFixture("cgllc.sensor_ht.qpg1"))
        let accessory = built.accessory
        #expect(accessory.category == .sensor)
        let temperature = try #require(accessory.service(.temperatureSensor))
        #expect(temperature.isPrimary)
        #expect(temperature[.currentTemperature]?.type.minValue == -30 && temperature[.currentTemperature]?.type.minStep == 0.1)
        #expect(temperature[.statusLowBattery] != nil)
        let humidity = try #require(accessory.service(.humiditySensor))
        #expect(humidity[.currentRelativeHumidity]?.type.minStep == 0.1)
        let battery = try #require(accessory.service(.battery))
        #expect(battery[.chargingState]?.value == .int(2))
        show(built, ["2.1": 21.4, "2.2": 48.5, "2.3": 15])
        #expect(temperature[.currentTemperature]?.value == .double(21.4))
        #expect(temperature[.statusLowBattery]?.value == .int(1))
        #expect(battery[.batteryLevel]?.value == .int(15))
    }

    /// propertyControl, propertyMonitor and actionButtons of section 2.5's purifier.
    @Test func optionsOfTheExample() throws {
        let built = try #require(buildFixture("zhimi.airpurifier.ma4", options: [
            "actionButtons": [["action": "filter:reset-filter-life", "name": "Reset filter"]],
            "propertyControl": [["property": "2.5", "value": 1, "name": "Sleep mode"]],
            "propertyMonitor": [["property": "environment:pm2.5-density", "value": 50, "valueOperator": "greater", "name": "Dusty"]],
            "methodButtons": [["method": "find_me", "name": "Find robot"]],
        ]))
        let accessory = built.accessory
        #expect(accessory.service(subtype: "action-4-1-0")?[.name]?.value == .string("Reset filter"))
        let sleep = try #require(accessory.service(subtype: "ctl-2-5-1"))
        #expect(sleep[.name]?.value == .string("Sleep mode"))
        let dusty = try #require(accessory.service(subtype: "monitor-3-6-50"))
        #expect(dusty.type.uuid == ServiceType.occupancySensor.uuid)
        #expect(accessory.service(subtype: "method-0")?[.name]?.value == .string("Find robot"))
        show(built, ["2.5": 1, "3.6": 51])
        #expect(sleep[.on]?.value == .bool(true))
        #expect(dusty[.occupancyDetected]?.value == .int(1))
        show(built, ["3.6": 12])
        #expect(dusty[.occupancyDetected]?.value == .int(0))
        // An unknown action is skipped.
        let unknown = try #require(buildFixture("zhimi.airpurifier.ma4", options: ["actionButtons": ["nothing:here"]]))
        #expect(unknown.accessory.services(.switch).isEmpty)
    }

    /// customAccessory: only the extra controls; nothing at all without them.
    @Test func customAccessory() throws {
        let built = try #require(buildFixture("zhimi.fan.za5", options: ["customAccessory": true, "buzzerControl": true]))
        #expect(built.accessory.service(.fanv2) == nil)
        #expect(built.accessory.services(.switch).count == 1)
        #expect(buildFixture("zhimi.fan.za5", options: ["customAccessory": true]) == nil)
    }
}
