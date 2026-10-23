import Foundation
import Testing

@testable import Homeswift

/// A plugin replaces its cached accessories one by one once the server runs: what changes the database bumps the
/// configuration number, what leaves it as it was does not, and new ids are saved at once.
@Suite struct AddWhileRunningTests {
    func lamp(_ id: String, brightness: Bool = true) -> Accessory {
        Accessory(id: id, name: id, category: .lightbulb, services: [Service(.lightbulb, name: id, optional: brightness ? [.brightness] : [], isPrimary: true)])
    }

    func configurationNumber(_ server: HAPServer) -> String {
        server.txtRecord().first { $0.0 == "c#" }?.1 ?? "?"
    }

    @Test func replacingWithTheSameShapeKeepsTheNumber() async throws {
        let storage = MemoryStorage()
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [], storage: storage,
            options: .init(port: 0, advertise: false, logger: testLogger))
        for id in ["a", "b", "c"] { try server.add(lamp(id)) }
        try await server.start()
        #expect(configurationNumber(server) == "1")

        // The same lamps again, as new objects: nothing HomeKit sees changed.
        for id in ["a", "b", "c"] { try server.add(lamp(id)) }
        #expect(configurationNumber(server) == "1")

        // One loses its brightness: a change, one bump; its iids stay.
        let iid = server.accessories.first { $0.id == "b" }?.service(.lightbulb)?.iid
        let changed = lamp("b", brightness: false)
        try server.add(changed)
        #expect(configurationNumber(server) == "2")
        #expect(changed.service(.lightbulb)?.iid == iid)

        // A new lamp: a new aid, saved before the next launch, and a bump.
        try server.add(lamp("d"))
        #expect(configurationNumber(server) == "3")
        let aid = try #require(server.accessories.first { $0.id == "d" }?.aid)
        await server.stop()

        let restarted = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [lamp("a"), changed, lamp("c"), lamp("d")],
            storage: storage, options: .init(port: 0, advertise: false, logger: testLogger))
        #expect(restarted.accessories.first { $0.id == "d" }?.aid == aid)
        try await restarted.start()
        #expect(configurationNumber(restarted) == "3")
        await restarted.stop()
    }
}
