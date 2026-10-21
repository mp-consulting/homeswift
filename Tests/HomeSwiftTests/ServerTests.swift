import Foundation
import Testing

@testable import HomeSwift

@Suite(.timeLimit(.minutes(1)))
struct ServerTests {
    let lamp: Accessory
    let lightbulb: Service
    let server: HAPServer
    let storage = MemoryStorage()

    init() throws {
        lightbulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        lamp = Accessory(id: "lamp-1", name: "Lamp", category: .lightbulb, services: [lightbulb])
        let bridge = Accessory(
            id: "bridge", name: "Test Bridge", category: .bridge,
            services: [Service(.protocolInformation, extra: [Characteristic(.version, value: "1.1.0")])])
        server = try HAPServer(
            bridge: bridge, accessories: [lamp], storage: storage,
            options: .init(setupCode: SetupCode("031-45-154"), port: 0, advertise: false))
    }

    private func pairedController() async throws -> TestController {
        try await server.start()
        let controller = TestController()
        try await controller.connect(port: server.port!)
        try await controller.pairSetup(code: "031-45-154")
        try await controller.pairVerify()
        return controller
    }

    @Test func pairsAndServesTheDatabase() async throws {
        let controller = try await pairedController()
        #expect(server.isPaired)
        #expect(controller.accessoryID == server.deviceID)

        let response = try await controller.request("GET", "/accessories")
        #expect(response.status == 200)
        let accessories = try #require((response.json as? [String: Any])?["accessories"] as? [[String: Any]])
        #expect(accessories.map { $0["aid"] as? Int } == [1, 2])
        let lampServices = try #require(accessories[1]["services"] as? [[String: Any]])
        #expect(lampServices.first?["iid"] as? Int == 1)
        #expect(lampServices.first?["type"] as? String == "3E")
        #expect(lampServices.last?["type"] as? String == "43")
        #expect(lampServices.last?["primary"] as? Bool == true)
        await controller.close()
        await server.stop()
    }

    @Test func rejectsUnverifiedRequestsAndWrongCodes() async throws {
        try await server.start()
        let controller = TestController()
        try await controller.connect(port: server.port!)
        #expect(try await controller.request("GET", "/accessories").status == 470)
        await #expect(throws: TestController.PairingFailure.self) {
            try await controller.pairSetup(code: "999-99-998")
        }
        #expect(!server.isPaired)
        await controller.close()
        await server.stop()
    }

    @Test func readsWritesAndNotifies() async throws {
        let writes = WriteLog()
        let brightness = lightbulb.characteristic(.brightness)
        brightness.onWrite { await writes.append($0) }
        let on = lightbulb.characteristic(.on)

        let first = try await pairedController()
        let second = TestController(identifier: "second", signingKey: .init())
        // Pair the second controller through the first, as the Home app does for other users and hubs.
        var add = TLV8()
        add.append(.state, 1)
        add.append(.method, 3)
        add.append(.identifier, Data(second.identifier.utf8))
        add.append(.publicKey, second.signingKey.publicKey.rawRepresentation)
        add.append(.permissions, 0)
        let added = try await first.tlv("/pairings", add)
        #expect(added.byte(.error) == nil)
        second.accessoryLTPK = first.accessoryLTPK
        try await second.connect(port: server.port!)
        try await second.pairVerify()

        let ids = "2.\(on.iid),2.\(brightness.iid)"
        let read = try await first.request("GET", "/characteristics?id=\(ids)&meta=1")
        #expect(read.status == 200)
        let values = (read.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(values?.first?["value"] as? Bool == false)
        #expect(values?.last?["unit"] as? String == "percentage")

        // Second controller subscribes; first writes; second gets the event, first does not.
        let subscribe = try await second.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "ev": true]]])
        #expect(subscribe.status == 204)
        let write = try await first.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "value": 55]]])
        #expect(write.status == 204)
        #expect(await writes.values == [.int(55)])
        #expect(brightness.value == .int(55))

        let event = try await second.nextMessage()
        #expect(event.startLine == "EVENT/1.0 200")
        let changed = (event.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(changed?.first?["value"] as? Int == 55)

        // Device-side updates reach subscribers too.
        brightness.value = 12
        let deviceEvent = try await second.nextMessage()
        #expect(((deviceEvent.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.first?["value"] as? Int == 12)

        // Out of range and read-only writes come back as a multi-status.
        let bad = try await first.json("PUT", "/characteristics", ["characteristics": [
            ["aid": 2, "iid": brightness.iid, "value": 150],
            ["aid": 1, "iid": 3, "value": "x"],  // Manufacturer
        ]])
        #expect(bad.status == 207)
        let statuses = ((bad.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.map { $0["status"] as? Int }
        #expect(statuses == [HAPStatus.invalidValueInRequest.rawValue, HAPStatus.readOnlyCharacteristic.rawValue])

        // A non-admin cannot manage pairings.
        var list = TLV8()
        list.append(.state, 1)
        list.append(.method, 5)
        #expect(try await second.tlv("/pairings", list).byte(.error) == TLVError.authentication.rawValue)
        let pairings = try await first.tlv("/pairings", list)
        #expect(pairings.groups.count == 2)

        await first.close()
        await second.close()
        await server.stop()
    }

    @Test func identifiesBridgedAccessories() async throws {
        let identified = WriteLog()
        let sensor = Service(.temperatureSensor, name: "Sensor")
        let thermometer = Accessory(
            id: "sensor-1", name: "Sensor", category: .sensor, services: [sensor],
            onIdentify: { await identified.append(.string("sensor")) })
        try server.add(thermometer)
        let controller = try await pairedController()
        let identify = thermometer.information.characteristic(.identify)
        let response = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": thermometer.aid, "iid": identify.iid, "value": true]]])
        #expect(response.status == 204)
        #expect(await identified.values == [.string("sensor")])
        await controller.close()
        await server.stop()
    }

    @Test func keepsIdentityAndIDsAcrossRestarts() async throws {
        let controller = try await pairedController()
        let iid = lightbulb.characteristic(.brightness).iid
        await controller.close()
        await server.stop()

        let restartedBulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        let restarted = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []),
            accessories: [Accessory(id: "lamp-1", name: "Lamp", category: .lightbulb, services: [restartedBulb])],
            storage: storage, options: .init(port: 0, advertise: false))
        #expect(restarted.deviceID == server.deviceID)
        #expect(restarted.isPaired)
        #expect(restartedBulb.characteristic(.brightness).iid == iid)
        // The bridge lost its protocol information service, so the configuration number moves on.
        #expect(restarted.txtRecord().first { $0.0 == "c#" }?.1 == "2")

        try await restarted.start()
        let again = TestController(identifier: controller.identifier, signingKey: controller.signingKey)
        again.accessoryLTPK = controller.accessoryLTPK
        try await again.connect(port: restarted.port!)
        try await again.pairVerify()
        #expect(try await again.request("GET", "/accessories").status == 200)
        await again.close()
        await restarted.stop()
    }

    @Test func removingTheLastAdminUnpairs() async throws {
        let controller = try await pairedController()
        var remove = TLV8()
        remove.append(.state, 1)
        remove.append(.method, 4)
        remove.append(.identifier, Data(controller.identifier.utf8))
        let response = try await controller.tlv("/pairings", remove)
        #expect(response.byte(.error) == nil)
        #expect(!server.isPaired)
        await #expect(throws: (any Error).self) { _ = try await controller.nextMessage() }
        await server.stop()
    }
}

actor WriteLog {
    var values: [HAPValue] = []
    func append(_ value: HAPValue) { values.append(value) }
}
