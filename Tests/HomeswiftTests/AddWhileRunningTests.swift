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

    /// HomeKit takes 150 accessories from a bridge, itself included: those added last wait outside, and come in as
    /// others leave.
    @Test func aBridgeServesAtMost149Accessories() async throws {
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [], storage: MemoryStorage(),
            options: .init(port: 0, advertise: false, logger: testLogger))
        let lamps = (1...HAPServer.maxBridgedAccessories + 2).map { lamp("lamp \($0)") }
        for lamp in lamps { try server.add(lamp) }
        try await server.start()
        func served() -> [Int] { server.database(includeValues: false).accessories.map(\.aid) }
        #expect(served().count == HAPServer.maxBridgedAccessories + 1)
        let waiting = try #require(lamps.last)
        #expect(!served().contains(waiting.aid))
        #expect(server.accessory(aid: waiting.aid) == nil)
        #expect(server.characteristic(aid: waiting.aid, iid: 1) == nil)

        // One that HomeKit has leaves: the first waiting comes in, the last still waits.
        let number = configurationNumber(server)
        try server.remove(lamps[0])
        #expect(served().contains(lamps[lamps.count - 2].aid))
        #expect(!served().contains(waiting.aid))
        #expect(configurationNumber(server) != number)
        await server.stop()
    }

    /// A burst of new accessories bumps the number for each and settles the hash once, shortly after.
    @Test func newAccessoriesSettleTheHashAfterTheBurst() async throws {
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [], storage: MemoryStorage(),
            options: .init(port: 0, advertise: false, logger: testLogger))
        try await server.start()
        for id in ["a", "b", "c"] { try server.add(lamp(id)) }
        #expect(configurationNumber(server) == "4")
        #expect(server.state.withLockedValue { $0.hashBehind })
        // The settle is due 250 ms after the burst; a loaded CI runner may run it late.
        let deadline = ContinuousClock.now + .seconds(10)
        while server.state.withLockedValue({ $0.hashBehind }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!server.state.withLockedValue { $0.hashBehind })
        #expect(configurationNumber(server) == "4")
        // A change after the settle is counted from the settled hash: one bump.
        try server.remove(try #require(server.accessories.first { $0.id == "b" }))
        #expect(configurationNumber(server) == "5")
        // While behind, a removal still bumps.
        try server.add(lamp("d"))
        try server.remove(try #require(server.accessories.first { $0.id == "a" }))
        #expect(configurationNumber(server) == "7")
        await server.stop()
    }

    /// Removals bump the number each, as HomeKit must refetch, but hash, save and advertise once, after the burst: a
    /// plugin removing its stale accessories hashed the whole database for each.
    @Test func removalsSaveOnceAfterTheBurst() async throws {
        let storage = MemoryStorage()
        let server = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []),
            accessories: ["a", "b", "c", "d"].map { lamp($0) }, storage: storage,
            options: .init(port: 0, advertise: false, logger: testLogger))
        try await server.start()
        func saved() throws -> Int { try JSONDecoder().decode(PersistedState.self, from: try #require(try storage.load())).configurationNumber }
        #expect(try saved() == 1)

        for id in ["a", "b", "c"] { try server.remove(try #require(server.accessories.first { $0.id == id })) }
        #expect(configurationNumber(server) == "4")
        #expect(server.state.withLockedValue { $0.hashBehind && $0.announceBehind })
        #expect(try saved() == 1)
        let deadline = ContinuousClock.now + .seconds(10)
        while server.state.withLockedValue({ $0.hashBehind }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try saved() == 4)
        #expect(configurationNumber(server) == "4")

        // One HomeKit does not see (mirrored) leaves the number as it is.
        let mirror = lamp("m")
        mirror.mirroredFrom = "Other:m"
        try server.add(mirror)
        try server.remove(mirror)
        #expect(configurationNumber(server) == "4")
        await server.stop()
    }

    /// The state the server writes itself reads back with JSONDecoder as what JSONEncoder wrote.
    @Test func persistedStateReadsBackAsJSONEncoderWroteIt() throws {
        var state = PersistedState.new(setupCode: nil)
        state.configurationNumber = 42
        state.databaseHash = "ab12"
        state.port = 51826
        state.pairings = [Pairing(identifier: "A1/\"quoted\"", publicKey: Data((0..<32).map { UInt8($0) }), isAdmin: true),
                          Pairing(identifier: "B2", publicKey: Data(), isAdmin: false)]
        for index in 0..<200 {
            state.aids["Plugin:\(index) é/ü"] = index + 2
            state.iids["\(index + 2)/0000003E-0000-1000-8000-0026BB765291/sub\(index)/00000014-0000-1000-8000-0026BB765291"] = index
        }
        for port in [Int?.none, 51826] {
            state.port = port
            let sorted = JSONEncoder()
            sorted.outputFormatting = [.sortedKeys]
            let mine = try JSONDecoder().decode(PersistedState.self, from: state.encoded())
            let theirs = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
            #expect(try sorted.encode(mine) == sorted.encode(theirs))
            #expect(mine.signingKey == state.signingKey && mine.port == port)
        }
    }
}

