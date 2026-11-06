import Foundation
@testable import Homeswift
import Testing

@testable import HomeswiftPlugin

/// Separate Functions (docs/adr/0006-the-bridge-separates-functions.md): the bridge publishes each Function of an
/// accessory as an accessory of its own when its Accessory Settings ask, live, and joins them back.
@Suite(.timeLimit(.minutes(1)))
struct SeparationTests {
    func config(separated: Bool) -> String {
        let accessories = separated ? #", "_accessories": { "desk": { "separateFunctions": true, "name": "Desk" }, "desk:motionsensor": { "name": "Hall Motion" } }"# : ""
        return #"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Lamps", "sensorLamps": ["desk"], "lamps": ["plain"]\#(accessories) }] }"#
    }

    @Test func aSeparatedAccessoryIsPublishedFunctionByFunction() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(config(separated: true))
        try await host.start()
        defer { Task { await host.stop() } }
        let server = host.mainBridge.server
        let main = try #require(server.accessories.first { $0.id == "Recording:desk" })
        let part = try #require(server.accessories.first { $0.id == "Recording:desk:motionsensor" })
        #expect(main.services.contains { $0.type.uuid == ServiceType.lightbulb.uuid })
        #expect(!main.services.contains { $0.type.uuid == ServiceType.motionSensor.uuid })
        #expect(part.services.contains { $0.type.uuid == ServiceType.motionSensor.uuid })
        #expect(part.category == .sensor && part.name == "Hall Motion")
        #expect(part.separatedFrom?.id == "Recording:desk")
        // Each has a battery: the part's a copy that follows the device's.
        let battery = try #require(main[.battery]?[.batteryLevel])
        battery.value = .int(42)
        #expect(part[.battery]?[.batteryLevel]?.value == .int(42))
        // The light's link to the sensor is left out of HomeKit's database: it is on another accessory now.
        let light = try #require(server.database(includeValues: false).accessories.first { $0.aid == main.aid }?.services.first { $0.type == ServiceType.lightbulb.uuid.shortForm })
        #expect(light.linked == nil)
        // The motion sensor's events are the part's: its characteristic answers on the part's aid.
        let motion = try #require(part[.motionSensor]?[.motionDetected])
        #expect(motion.aid == part.aid)
        // The instance names its parts, so the pages find their plugin; one that does one thing is left alone.
        #expect(host.platforms.first?.accessoryIDs.contains("Recording:desk:motionsensor") == true)
        #expect(!server.accessories.contains { $0.id.hasPrefix("Recording:plain:") })
        #expect(Separation.groups(of: try #require(server.accessories.first { $0.id == "Recording:plain" })) == nil)
    }

    /// Off again, live: the part leaves, and the device's accessory has every Function back under its own aid.
    @Test func joinedBackItKeepsItsAid() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(config(separated: true))
        try await host.start()
        defer { Task { await host.stop() } }
        let server = host.mainBridge.server
        let aid = try #require(server.accessories.first { $0.id == "Recording:desk" }).aid
        let partAid = try #require(server.accessories.first { $0.id == "Recording:desk:motionsensor" }).aid
        let report = await host.apply(try HomeswiftConfiguration.decode(Data(config(separated: false).utf8)))
        #expect(report.reloaded.isEmpty)
        let desk = try #require(server.accessories.first { $0.id == "Recording:desk" })
        #expect(desk.aid == aid)
        #expect(desk.services.contains { $0.type.uuid == ServiceType.motionSensor.uuid })
        #expect(!server.accessories.contains { $0.id == "Recording:desk:motionsensor" })
        #expect(desk[.motionSensor]?[.motionDetected]?.aid == aid)
        // Separated again, the part gets its old aid back.
        _ = await host.apply(try HomeswiftConfiguration.decode(Data(config(separated: true).utf8)))
        #expect(server.accessories.first { $0.id == "Recording:desk:motionsensor" }?.aid == partAid)
    }

    /// What stays whole: a camera, a doorbell or a television, and a remote's buttons; what a plugin keeps together.
    @Test func whatStaysTogether() {
        let tv = Accessory(id: "tv", name: "TV", services: [Service(.television, isPrimary: true), Service(.switch)])
        #expect(Separation.groups(of: tv) == nil)
        let label = Service(.serviceLabel)
        let remote = Accessory(id: "remote", name: "Remote", services: [label, Service(.statelessProgrammableSwitch, subtype: "1"), Service(.statelessProgrammableSwitch, subtype: "2")])
        #expect(Separation.groups(of: remote) == nil)
        let light = Service(.lightbulb, isPrimary: true), sensor = Service(.lightSensor), fan = Service(.fanv2)
        let kept = Accessory(id: "kept", name: "Kept", services: [light, sensor, fan])
        kept.keepFunctionsTogether([light, sensor])
        #expect(Separation.groups(of: kept)?.map(\.count) == [2, 1])
    }
}
