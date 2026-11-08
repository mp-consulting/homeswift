import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftRoborock

/// RoborockModes.md: what a model offers (sections 1 to 3), rooms (4), errors (6).
@Suite struct CleanModesTests {
    @Test func aSpinMopWithMaxPlusOffersItsLevelsAndMopOnly() {
        let modes = RoborockCleanModes(model: "roborock.vacuum.a75", featureSet: nil, newFeatureSet: nil)
        #expect(modes.fanPowers.map(\.code) == [101, 102, 103, 104, 108, 105, 106])
        #expect(modes.fanPowers.first { $0.code == 105 }?.name == "Off")
        // Off is a mode, not a level: the slider runs Quiet to Max+.
        #expect(modes.suctionLevels.map(\.code) == [101, 102, 103, 104, 108])
        #expect(modes.waterModes.map(\.code) == [200, 201, 202, 203, 204])
        #expect(modes.waterModes[1].name == "Low")
        #expect(modes.routes.map(\.code) == [300, 301, 302])
        #expect(modes.defaultWater == 202)
    }

    @Test func aRobotWithoutPureMoppingHasGentleAsItsWeakestLevel() {
        let modes = RoborockCleanModes(model: "roborock.vacuum.a40", featureSet: nil, newFeatureSet: nil)
        #expect(modes.suctionLevels.map(\.name) == ["Gentle", "Quiet", "Balanced", "Turbo", "Max"])
        #expect(!modes.hasWaterBox && modes.waterModes.isEmpty && modes.routes.isEmpty)
    }

    @Test func featureBitsAddModes() {
        // New-feature bit 55 (smart): hex digit 13 from the end, bit 3; bit 106 (water slide): digit 26, bit 2.
        var digits = Array(repeating: Character("0"), count: 27)
        digits[27 - 1 - 13] = "8"
        digits[27 - 1 - 26] = "4"
        let modes = RoborockCleanModes(model: "roborock.vacuum.a50", featureSet: nil, newFeatureSet: String(digits))
        #expect(modes.smartMode && modes.waterSlide)
        #expect(modes.fanPowers.contains { $0.code == 110 })
        #expect(modes.waterModes.map(\.code) == [200, 221, 225, 230, 235, 240, 245, 250])
        #expect(modes.defaultWater == 235)
        #expect(modes.routes.contains { $0.code == 306 })
        // A shake mop names the water levels as the app does.
        let shake = RoborockCleanModes(model: "roborock.vacuum.a50", featureSet: nil, newFeatureSet: nil)
        #expect(shake.waterModes.map(\.name).prefix(4) == ["Off", "Mild", "Standard", "Intense"])
        // UltronE: Fast and Standard only, Max+ without pure mopping.
        let ultronE = RoborockCleanModes(model: "roborock.vacuum.a72", featureSet: 262_144, newFeatureSet: nil)
        #expect(ultronE.routes.map(\.code) == [304, 300])
        #expect(ultronE.fanPowers.contains { $0.code == 108 })
    }

    @Test func speedsMapToLevelsBothWays() {
        let levels = RoborockCleanModes(model: "roborock.vacuum.a75", featureSet: nil, newFeatureSet: nil).suctionLevels
        #expect(VacuumAccessory.speed(fanPower: 101, levels: levels) == 20)
        #expect(VacuumAccessory.speed(fanPower: 108, levels: levels) == 100)
        #expect(VacuumAccessory.speed(fanPower: 106, levels: levels) == nil)
        #expect(VacuumAccessory.fanPower(speed: 20, levels: levels) == 101)
        #expect(VacuumAccessory.fanPower(speed: 50, levels: levels) == 103)
        #expect(VacuumAccessory.fanPower(speed: 100, levels: levels) == 108)
        #expect(VacuumAccessory.fanPower(speed: 0, levels: levels) == nil)
        // Six levels (Gentle to Max+): 16.67 % apart, and the Home app's 16.6667 is Gentle, not Quiet.
        let six = RoborockCleanModes(model: "roborock.vacuum.a72", featureSet: nil, newFeatureSet: nil).suctionLevels
        #expect(six.map(\.code) == [105, 101, 102, 103, 104, 108])
        #expect(VacuumAccessory.fanPower(speed: 16.6667, levels: six) == 105)
        #expect(VacuumAccessory.fanPower(speed: 33.3334, levels: six) == 101)
        #expect(VacuumAccessory.speed(fanPower: 101, levels: six) == 100.0 / 3)
    }

    @Test func modesAreFoundByNameOrCode() {
        let modes = RoborockCleanModes(model: "roborock.vacuum.a75", featureSet: nil, newFeatureSet: nil)
        #expect(RoborockCleanModes.find("turbo", in: modes.fanPowers)?.code == 103)
        #expect(RoborockCleanModes.find(.number(104), in: modes.fanPowers)?.name == "Max")
        #expect(RoborockCleanModes.find("110", in: modes.fanPowers) == nil)
        #expect(RoborockCleanModes.name(233, in: modes.waterModes) == "Water level 13")
    }

    @Test func roomsAreNamedFromTheHome() throws {
        let names = RoborockRooms.names(["rooms": [["id": 14731399, "name": "Kitchen"], ["id": "2220009", "name": "Hall"]]])
        let rooms = RoborockRooms.rooms(mapping: [[16, "14731399", 12], [17, "2220009", 2], [18, "999", 1], ["bad"]], names: names)
        #expect(rooms == [.init(segment: 16, name: "Kitchen"), .init(segment: 17, name: "Hall"), .init(segment: 18, name: "Room 18")])
        // One flat pair.
        #expect(RoborockRooms.rooms(mapping: [16, "14731399"], names: names) == [.init(segment: 16, name: "Kitchen")])
        #expect(try RoborockRooms.segments(["kitchen", 18], in: rooms) == [16, 18])
        #expect(throws: RoborockRoomError.self) { try RoborockRooms.segments(["Garage"], in: rooms) }
    }

    @Test func theDocksErrorIsClearedFirst() {
        #expect(RoborockErrors.toResolve(robot: 5, dock: 38) == 38)
        #expect(RoborockErrors.toResolve(robot: 5, dock: 0) == 5)
        #expect(RoborockErrors.toResolve(robot: 0, dock: nil) == nil)
        #expect(RoborockErrors.describe(38, in: RoborockErrors.robot) == "Check the clean water tank")
        #expect(RoborockErrors.describe(0, in: RoborockErrors.robot) == nil)
    }
}

/// The modes on a robot, end to end against the fake robot on the LAN.
@Suite struct ModesOnARobotTests {
    let environment = TestEnvironment()

    @Test func suctionMopAndIdentifyReachTheRobot() async throws {
        environment.robot.answer("get_status", with: [["state": 8, "battery": 90, "charge_status": 1, "error_code": 0, "fan_power": 102, "water_box_mode": 200]])
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        let accessory = try #require(environment.accessory(host))
        let speed = try #require(accessory.service(.fanv2)?[.rotationSpeed])
        // An S7 (a15, a TanosS) has four levels, Quiet to Max: Balanced is 50 %.
        await expectEventually { environment.accessory(host)?.service(.fanv2)?[.rotationSpeed]?.value == .double(50) }
        let write1 = try #require(speed.writeHandler(for: .double(80)))
        try await write1(.double(80))
        #expect(environment.robot.params(of: "set_custom_mode") == [104])

        let mop = try #require(environment.accessory(host)?.services.first { $0.subtype == "mop" })
        #expect(mop[.on]?.value == .bool(false))
        let write2 = try #require(mop[.on]?.writeHandler(for: .bool(true)))
        try await write2(.bool(true))
        #expect(environment.robot.params(of: "set_water_box_custom_mode") == [202])
        let write3 = try #require(mop[.on]?.writeHandler(for: .bool(false)))
        try await write3(.bool(false))
        #expect(environment.robot.params(of: "set_water_box_custom_mode") == [200])

        await environment.accessory(host)?.identify()
        await expectEventually { environment.robot.methods.contains("find_me") }
        await host.stop()
    }

    @Test func aRefusedSuctionFailsTheWrite() async throws {
        environment.robot.answer("set_custom_mode", with: ["error": ["code": -10000, "message": "invalid"]])
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        let speed = try #require(environment.accessory(host)?.service(.fanv2)?[.rotationSpeed])
        let write = try #require(speed.writeHandler(for: .double(20)))
        await #expect(throws: HAPStatusError.self) { try await write(.double(20)) }
        await host.stop()
    }

    @Test func roomsAreCleanedByName() async throws {
        environment.robot.answer("get_room_mapping", with: [[16, "11", 12], [17, "12", 2]])
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        let plugin = try #require(environment.plugin)
        let rooms = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "rooms", user: "test"))
        #expect(rooms.json["rooms"]?[0]?["name"] == "Kitchen")
        #expect(rooms.json["rooms"]?[1]?["name"] == "Room 17")
        let clean = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "clean-rooms", body: ["rooms": ["kitchen", 17], "repeat": 2], user: "test"))
        #expect(clean.status == 200)
        #expect(environment.robot.params(of: "app_segment_clean") == [["segments": [16, 17], "repeat": 2]])
        let unknown = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "clean-rooms", body: ["rooms": ["Garage"]], user: "test"))
        #expect(unknown.status == 400)
        await host.stop()
    }

    @Test func modesAreSetByNameAndErrorsCleared() async throws {
        environment.robot.answer("get_status", with: [["state": 12, "battery": 90, "charge_status": 0, "error_code": 5, "dock_error_status": 38]])
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        let plugin = try #require(environment.plugin)
        let mode = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "mode", body: ["fan_power": "Max", "water_box_mode": 203], user: "test"))
        #expect(mode.status == 200)
        #expect(environment.robot.params(of: "set_custom_mode") == [104])
        #expect(environment.robot.params(of: "set_water_box_custom_mode") == [203])
        let wrong = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "mode", body: ["fan_power": "Smart"], user: "test"))
        #expect(wrong.status == 400)

        let robots = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "robots", user: "test"))
        #expect(robots.json["robots"]?[0]?["error"]?["meaning"] == "Main brush jammed")
        let cleared = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "resolve-error", body: [:], user: "test"))
        #expect(cleared.json["cleared"] == 38)
        #expect(environment.robot.params(of: "resolve_error") == ["error_code": 38])

        _ = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "locate", body: [:], user: "test"))
        #expect(environment.robot.methods.contains("find_me"))
        await host.stop()
    }
}
