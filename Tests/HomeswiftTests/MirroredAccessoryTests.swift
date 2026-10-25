import Foundation
import NIOConcurrencyHelpers
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

    /// Mirroring a whole home adds many accessories at once: none of them makes HomeKit fetch its database again.
    @Test func addingAMirroredAccessoryLeavesTheConfigurationNumber() async throws {
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [], storage: MemoryStorage(),
            options: .init(port: 0, advertise: false, logger: testLogger))
        try server.add(lamp("own"))
        try await server.start()
        let number = { server.txtRecord().first { $0.0 == "c#" }?.1 }
        let before = number()
        for id in ["m1", "m2", "m3"] {
            let mirrored = lamp(id)
            mirrored.mirroredFrom = "Apple Home"
            try server.add(mirrored)
            #expect(mirrored.aid > 0)
        }
        #expect(number() == before)
        // An accessory of its own still bumps it.
        try server.add(lamp("own2"))
        #expect(number() != before)
        await server.stop()
    }

    /// An accessory HomeKit could see that comes back mirrored leaves its database: the configuration number moves.
    @Test func anAccessoryThatBecomesMirroredLeavesHomeKitsDatabase() async throws {
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [], storage: MemoryStorage(),
            options: .init(port: 0, advertise: false, logger: testLogger))
        try server.add(lamp("x"))
        try await server.start()
        let before = server.txtRecord().first { $0.0 == "c#" }?.1
        let mirrored = lamp("x")
        mirrored.mirroredFrom = "Apple Home"
        try server.add(mirrored)
        #expect(server.txtRecord().first { $0.0 == "c#" }?.1 != before)
        #expect(!server.database(includeValues: false).accessories.map(\.aid).contains(mirrored.aid))
        await server.stop()
    }

    /// Becoming unavailable, or available again, is announced with an event of a value that did not change, so the web
    /// UI's cards follow; setting it to what it is announces nothing, and a button's press is never what announces it.
    @Test func availabilityChangesAreAnnounced() {
        let light = lamp("l")
        let on = light.service(.lightbulb)!.characteristic(.on)
        let changes = NIOLockedValueBox<[Characteristic.Change]>([])
        _ = on.observe { change in changes.withLockedValue { $0.append(change) } }
        light.isUnavailable = true
        light.isUnavailable = true
        light.isUnavailable = false
        #expect(changes.withLockedValue { $0.count } == 2)
        #expect(changes.withLockedValue { $0.allSatisfy { $0.oldValue == $0.newValue } })

        let button = Accessory(id: "b", name: "b", services: [Service(.statelessProgrammableSwitch, isPrimary: true)])
        let press = button.service(.statelessProgrammableSwitch)!.characteristic(.programmableSwitchEvent)
        let presses = NIOLockedValueBox(0)
        _ = press.observe { _ in presses.withLockedValue { $0 += 1 } }
        button.isUnavailable = true
        #expect(presses.withLockedValue { $0 } == 0)
    }

    @Test func knownTypesAreFoundByUUID() {
        #expect(CharacteristicType.known(uuid: HAPUUID("00000008-0000-1000-8000-0026BB765291"))?.name == "Brightness")
        #expect(CharacteristicType.known(uuid: HAPUUID("CE")) == .colorTemperature)
        #expect(ServiceType.known(uuid: HAPUUID("00000043-0000-1000-8000-0026BB765291"))?.name == "Lightbulb")
        #expect(ServiceType.known(uuid: HAPUUID("12345678-1234-1234-1234-123456789012")) == nil)
    }
}
