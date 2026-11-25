import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftWingman

/// HomeKit's ids are the Mac's own and can all change at once (docs/adr/0013-mirrors-keep-their-device-id.md): a mirror
/// keeps its Device Id, so what refers to it (Automations, groups, Accessory Settings) keeps working.
@Suite(.timeLimit(.minutes(1)))
final class AccessoryIDsTests: @unchecked Sendable {
    deinit { try? FileManager.default.removeItem(at: directory) }

    let environment = TestEnvironment()

    func mirrored(_ host: PluginHost) -> Set<String> {
        Set(host.mainBridge.server.accessories.map(\.id).filter { $0.hasPrefix("Wingman:") })
    }

    @Test func aMirrorKeepsItsIdWhenAppleHomeGivesANewOne() async throws {
        let host = try await environment.start()
        #expect(await eventually { mirrored(host).contains("Wingman:light-1") })
        let before = mirrored(host)
        environment.wingman.reissueIDs()
        // The next read of the homes asks Wingman for the light by its new id.
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.candidates().contains { $0.name == "Plafonnier" } && environment.wingman.requests.filter { $0 == "homes" }.count >= 2 })
        #expect(await eventually {
            guard let light = host.mainBridge.server.accessories.first(where: { $0.id == "Wingman:light-1" }),
                  let on = light.service(.lightbulb)?[.on] else { return false }
            return (try? await on.writeHandler(for: .bool(false))?(.bool(false))) != nil
                && environment.wingman.writes.last == .init(accessory: "v2-light-1", characteristic: "v2-light-on", value: "0")
        })
        #expect(mirrored(host) == before)
        #expect(!mirrored(host).contains("Wingman:v2-light-1"))
        // Its Device Id stays what the Discovered Devices list.
        #expect(await plugin.mirroredDevices().contains { $0.deviceID == "light-1" })

        // A restart keeps it too: the ids are kept on disk.
        await host.stop()
        let again = try await environment.start()
        #expect(await eventually { mirrored(again).contains("Wingman:light-1") && mirrored(again).count == before.count })
        #expect(!mirrored(again).contains("Wingman:v2-light-1"))
        await again.stop()
    }

    @Test func anExcludedAccessoryStaysExcludedUnderItsNewId() async throws {
        let settings: [String: Any] = ["devices": [TestEnvironment.paired], "_accessories": ["light-1": ["excluded": true]]]
        let host = try await environment.start(settings: settings)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.candidates().contains { $0.id == "light-1" } })
        environment.wingman.reissueIDs()
        // The read that gave the new ids decided what it mirrors before it let anything else in.
        #expect(await eventually { plugin.identities.ids(wingman: "wm-1").homeKitID(of: "light-1") == "v2-light-1" })
        let loaded = try #require(await plugin.links["wm-1"]?.loadedIDs)
        #expect(loaded.contains("Wingman:lock-1"))
        #expect(!loaded.contains("Wingman:light-1"))
        #expect(!mirrored(host).contains("Wingman:light-1"))
        #expect(!mirrored(host).contains("Wingman:v2-light-1"))
        await host.stop()
    }

    /// A Homebridge-shaped `exclude` naming the HomeKit id Wingman gives the accessory now: shown as left out too.
    @Test func discoveredDevicesKnowAnExcludeByTheNewHomeKitId() async throws {
        let host = try await environment.start(settings: ["devices": [TestEnvironment.paired], "exclude": ["v2-light-1"]])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { mirrored(host).contains("Wingman:light-1") })
        environment.wingman.reissueIDs()
        #expect(await eventually { plugin.identities.ids(wingman: "wm-1").homeKitID(of: "light-1") == "v2-light-1" })
        let light = try #require(await plugin.mirroredDevices().first { $0.deviceID == "light-1" })
        #expect(light.excludedBySettings)
        #expect(!light.isSetUp)
        await host.stop()
    }

    // MARK: Recognising an accessory

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-wingman-ids-\(UUID().uuidString).json")

    func identities() -> AccessoryIdentities { AccessoryIdentities(file: JSONFile(url: directory)) }

    func accessory(_ id: String, name: String, room: String = "Salon", serial: String? = nil, model: String = "Lamp") throws -> WingmanAPI.Accessory {
        var characteristics: [[String: Any]] = []
        if let serial { characteristics.append(["id": "\(id)-serial", "type": "00000030-0000-1000-8000-0026BB765291", "properties": ["read"], "value": serial, "format": "string"]) }
        let json: [String: Any] = [
            "id": id, "name": name, "room": room, "manufacturer": "IKEA", "model": model,
            "services": [["id": "\(id)-info", "type": "0000003E-0000-1000-8000-0026BB765291", "characteristics": characteristics]],
        ]
        return try JSONDecoder().decode(WingmanAPI.Accessory.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func read(_ ids: AccessoryIdentities, _ accessories: [WingmanAPI.Accessory], at date: Date = Date()) -> AccessoryIDs {
        ids.resolve(wingman: "wm-1", accessories: accessories.map { ($0, "Maison") }, present: Set(accessories.map(\.id)), now: date).ids
    }

    @Test func bySerialNumberWhereverItMoved() throws {
        let ids = identities()
        _ = read(ids, [try accessory("a", name: "Lampe", serial: "S1"), try accessory("b", name: "Plafonnier", serial: "S2")])
        let next = read(ids, [try accessory("x", name: "Lampe du salon", room: "Cuisine", serial: "S1"), try accessory("y", name: "Plafonnier", serial: "S2")])
        #expect(next.deviceID(of: "x") == "a")
        #expect(next.deviceID(of: "y") == "b")
        #expect(next.homeKitID(of: "a") == "x")
        // An id Apple Home no longer uses goes nowhere.
        #expect(next.homeKitID(of: "x") == nil)
        // Kept on disk.
        #expect(identities().ids(wingman: "wm-1") == next)
    }

    @Test func byWhereItIsWithoutASerialNumber() throws {
        let ids = identities()
        _ = read(ids, [try accessory("a", name: "Lampe"), try accessory("b", name: "Lampe", room: "Cuisine")])
        let next = read(ids, [try accessory("x", name: "Lampe"), try accessory("y", name: "Lampe", room: "Cuisine")])
        #expect(next.deviceID(of: "x") == "a")
        #expect(next.deviceID(of: "y") == "b")
    }

    @Test func twoAlikeKeepTheirNewIds() throws {
        let ids = identities()
        _ = read(ids, [try accessory("a", name: "Lampe"), try accessory("b", name: "Lampe")])
        let next = read(ids, [try accessory("x", name: "Lampe"), try accessory("y", name: "Lampe")])
        #expect(next.deviceID(of: "x") == "x")
        #expect(next.deviceID(of: "y") == "y")
    }

    @Test func anotherSerialNumberIsAnotherDevice() throws {
        let ids = identities()
        _ = read(ids, [try accessory("a", name: "Lampe", serial: "S1")])
        let next = read(ids, [try accessory("x", name: "Lampe", serial: "S9")])
        #expect(next.deviceID(of: "x") == "x")
    }

    @Test func anAccessoryBackAfterADayKeepsItsIdButNotAfterAMonth() throws {
        let ids = identities()
        let start = Date()
        _ = read(ids, [try accessory("a", name: "Lampe", serial: "S1"), try accessory("b", name: "Prise", serial: "S2")], at: start)
        _ = read(ids, [try accessory("b", name: "Prise", serial: "S2")], at: start)
        let day = read(ids, [try accessory("x", name: "Lampe", serial: "S1"), try accessory("b", name: "Prise", serial: "S2")], at: start + 24 * 3600)
        #expect(day.deviceID(of: "x") == "a")

        _ = read(ids, [try accessory("b", name: "Prise", serial: "S2")], at: start + 2 * 24 * 3600)
        _ = read(ids, [try accessory("b", name: "Prise", serial: "S2")], at: start + 40 * 24 * 3600)
        let month = read(ids, [try accessory("z", name: "Lampe", serial: "S1"), try accessory("b", name: "Prise", serial: "S2")], at: start + 41 * 24 * 3600)
        #expect(month.deviceID(of: "z") == "z")
    }

    @Test func eachWingmanHasItsOwnIds() throws {
        let ids = identities()
        _ = read(ids, [try accessory("a", name: "Lampe", serial: "S1")])
        let other = ids.resolve(wingman: "wm-2", accessories: [(try accessory("x", name: "Lampe", serial: "S1"), "Maison")], present: ["x"]).ids
        #expect(other.deviceID(of: "x") == "x")
        #expect(read(ids, [try accessory("a", name: "Lampe", serial: "S1")]).deviceID(of: "a") == "a")
    }
}
