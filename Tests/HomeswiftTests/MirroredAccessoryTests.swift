import Foundation
import Testing

@testable import Homeswift

/// A mirrored accessory (`Accessory.mirroredFrom`: Apple Home's, through Wingman) is the bridge's own for the web UI and
/// the MCP server, and never HomeKit's: not in the database, out of reach of reads, writes and subscriptions.
@Suite struct MirroredAccessoryTests {
    func lamp(_ id: String) -> Accessory {
        Accessory(id: id, name: id, category: .lightbulb, services: [Service(.lightbulb, name: id, optional: [.brightness], isPrimary: true)])
    }

    @Test func homeKitNeverSeesAMirroredAccessory() async throws {
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [], storage: MemoryStorage(),
            options: .init(port: 0, advertise: false, logger: testLogger))
        let own = lamp("own")
        let mirrored = lamp("mirrored")
        mirrored.mirroredFrom = "Apple Home"
        mirrored.suggestedRoom = "Salon"
        try server.add(own)
        try server.add(mirrored)
        try await server.start()

        let aids = server.database(includeValues: true).accessories.map(\.aid)
        #expect(aids.contains(own.aid))
        #expect(!aids.contains(mirrored.aid))
        // Still the bridge's: listed, with its aid, for the web UI and the MCP server.
        #expect(server.accessories.contains { $0.id == "mirrored" })
        let on = try #require(mirrored.service(.lightbulb)?[.on])
        #expect(server.accessory(aid: mirrored.aid) == nil)
        #expect(server.characteristic(aid: mirrored.aid, iid: on.iid) == nil)
        #expect(server.characteristic(aid: own.aid, iid: try #require(own.service(.lightbulb)?[.on]).iid) != nil)
        await server.stop()
    }

    @Test func knownTypesAreFoundByUUID() {
        #expect(CharacteristicType.known(uuid: HAPUUID("00000008-0000-1000-8000-0026BB765291"))?.name == "Brightness")
        #expect(CharacteristicType.known(uuid: HAPUUID("CE")) == .colorTemperature)
        #expect(ServiceType.known(uuid: HAPUUID("00000043-0000-1000-8000-0026BB765291"))?.name == "Lightbulb")
        #expect(ServiceType.known(uuid: HAPUUID("12345678-1234-1234-1234-123456789012")) == nil)
    }
}
