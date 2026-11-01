import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift

/// A lamp, for a bridge that `PluginHost` runs.
private actor LampPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {}
    static let platform = "Lamps"
    static let name = "Lamps"
    let context: PluginContext

    init(configuration: Configuration, context: PluginContext) { self.context = context }

    func start() async throws {
        let lightbulb = Service(.lightbulb, name: "Lamp", isPrimary: true)
        try context.add(Accessory(id: "Lamps:lamp", name: "Lamp", category: .lightbulb, services: [lightbulb]))
    }
}

/// A name given in `_accessories` as a paired controller sees it: on Accessory Information's Name and the lightbulb's
/// Configured Name, a rename sent as an event on Configured Name, and a controller's write of it handed to the host.
@Suite(.timeLimit(.minutes(1)))
struct AccessoryNamingServerTests {
    static func configuration(name: String) throws -> HomeswiftConfiguration {
        try HomeswiftConfiguration.decode(Data(#"""
            { "bridge": { "name": "Test Bridge", "port": 0 }, "platforms": [
              { "platform": "Lamps", "name": "Lamps", "_accessories": { "lamp": { "name": "\#(name)" } } }
            ] }
            """#.utf8))
    }

    @Test func aPairedControllerSeesTheNameAndItsChanges() async throws {
        var registry = PluginRegistry()
        registry.register(platform: LampPlugin.platform, name: LampPlugin.name) { _, context in LampPlugin(configuration: .init(), context: context) }
        let storage = MemoryStorage()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-naming-\(UUID().uuidString)")
        let host = try PluginHost(configuration: try Self.configuration(name: "Desk"), registry: registry, storageDirectory: directory,
                                  options: PluginHost.Options(advertise: false, logger: testLogger) { _ in storage })
        let renames = NIOLockedValueBox<[String]>([])
        host.handleRenames { id, name in renames.withLockedValue { $0.append("\(id)=\(name)") } }
        try await host.start()
        let server = host.mainBridge.server
        let lamp = try #require(server.accessories.first { $0.id == "Lamps:lamp" })
        let configuredName = try #require(lamp[.lightbulb]?[.configuredName])

        let controller = TestController()
        try await controller.connect(port: server.port!)
        try controller.addPairing(to: server)
        try await controller.pairVerify()

        // The database: Accessory Information's Name (23) and the lightbulb's Configured Name (E3) say Desk.
        let response = try await controller.request("GET", "/accessories")
        let accessories = try #require((response.json as? [String: Any])?["accessories"] as? [[String: Any]])
        let served = try #require(accessories.first { $0["aid"] as? Int == lamp.aid })
        let characteristics = (served["services"] as? [[String: Any]] ?? []).flatMap { $0["characteristics"] as? [[String: Any]] ?? [] }
        let values = Dictionary(characteristics.map { ($0["type"] as? String ?? "", $0["value"]) }, uniquingKeysWith: { first, _ in first })
        #expect(values["23"] as? String == "Desk")
        #expect(values["E3"] as? String == "Desk")
        #expect(characteristics.contains { $0["type"] as? String == "E3" && $0["iid"] as? Int == configuredName.iid })

        // A rename in config.json reaches the controller as an event on Configured Name.
        let subscribe = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": lamp.aid, "iid": configuredName.iid, "ev": true]]])
        #expect(subscribe.status == 204)
        _ = await host.apply(try Self.configuration(name: "Reading Lamp"))
        let event = try await controller.nextMessage()
        #expect(event.startLine == "EVENT/1.0 200")
        let changed = (event.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(changed?.first?["iid"] as? Int == configuredName.iid)
        #expect(changed?.first?["value"] as? String == "Reading Lamp")

        // The controller renames it (the Home app does so): the host is told.
        let write = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": lamp.aid, "iid": configuredName.iid, "value": "Study"]]])
        #expect(write.status == 204)
        // Handed over on a task of its own: a ceiling, not a wait.
        let deadline = ContinuousClock.now + .seconds(30)
        while renames.withLockedValue({ $0.isEmpty }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(renames.withLockedValue { $0 } == ["Lamps:lamp=Study"])

        await controller.close()
        await host.stop()
    }
}
