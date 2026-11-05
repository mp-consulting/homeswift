import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftTapo

/// The ARP table in memory: `entries` before the local networks are resolved, `resolved` after.
final class FakeNeighbours: Sendable {
    private let state: NIOLockedValueBox<(entries: [(ip: String, mac: String)], resolved: [(ip: String, mac: String)]?, resolves: Int)>

    init(_ entries: [(ip: String, mac: String)] = [], resolved: [(ip: String, mac: String)]? = nil) {
        state = NIOLockedValueBox((entries, resolved, 0))
    }

    var entries: [(ip: String, mac: String)] { state.withLockedValue { $0.entries } }
    var resolves: Int { state.withLockedValue { $0.resolves } }

    func resolve() {
        state.withLockedValue { state in
            state.resolves += 1
            if let resolved = state.resolved { state.entries = resolved }
        }
    }
}

/// Setup finding the account's cameras through the TP-Link cloud, and their addresses through the ARP table.
@Suite(.timeLimit(.minutes(1)))
struct TapoCloudDiscoveryTests {
    let environment = TestEnvironment()
    /// The fake cloud's camera: a C675D called Garden, MAC 10-5A-95-2F-AD-17.
    static let garden = (ip: "192.168.1.40", mac: "10:5A:95:2F:AD:17")

    /// A plugin of a block without devices, signed in to the cloud as Setup leaves it.
    func signedIn(_ neighbours: FakeNeighbours, devices: [[String: Any]] = [], cloud: FakeTapoCloud = FakeTapoCloud()) async throws -> (PluginHost, TapoPlugin) {
        let host = try await environment.start(devices: devices, cloud: cloud, neighbours: neighbours)
        let plugin = try #require(environment.plugin)
        try await plugin.cloud.signIn()
        return (host, plugin)
    }

    @Test func discoveryListsTheAccountsCameraAtItsAddress() async throws {
        let neighbours = FakeNeighbours([("192.168.1.2", "AA:BB:CC:DD:EE:FF"), Self.garden])
        let (host, plugin) = try await signedIn(neighbours)
        let found = try await plugin.discover()
        #expect(found.map(\.deviceID) == ["CLOUDID0001"])
        #expect(found.first?.name == "Garden")
        #expect(found.first?.model == "Tapo C675D")
        #expect(found.first?.address == "192.168.1.40")
        #expect(found.first?.authorization == .accountLogin)
        #expect(found.first?.kind == "camera")
        #expect(neighbours.resolves == 0)
        await host.stop()
    }

    @Test func aCameraTheTableLacksResolvesTheNetworkOnce() async throws {
        let neighbours = FakeNeighbours([], resolved: [Self.garden])
        let (host, plugin) = try await signedIn(neighbours)
        let found = try await plugin.discover()
        #expect(found.first?.address == "192.168.1.40")
        #expect(neighbours.resolves == 1)
        await host.stop()
    }

    @Test func aCameraNowhereOnTheNetworkHasNoAddress() async throws {
        let neighbours = FakeNeighbours()
        let (host, plugin) = try await signedIn(neighbours)
        let found = try await plugin.discover()
        #expect(found.map(\.deviceID) == ["CLOUDID0001"])
        #expect(found.first?.address == nil)
        #expect(neighbours.resolves == 1)
        await host.stop()
    }

    /// The camera on another subnet: not in the ARP table, its address from the cloud's registry, no sweep.
    @Test func aCameraOnAnotherSubnetHasTheAddressTheCloudKeeps() async throws {
        let cloud = FakeTapoCloud()
        cloud.state.withLockedValue { $0.addresses["CLOUDID0001"] = "192.168.5.185" }
        let neighbours = FakeNeighbours([("192.168.1.2", "AA:BB:CC:DD:EE:FF")])
        let (host, plugin) = try await signedIn(neighbours, cloud: cloud)
        let found = try await plugin.discover()
        #expect(found.first?.address == "192.168.5.185")
        #expect(neighbours.resolves == 0)
        // The NBU app server was asked once, then kept with the session.
        _ = try await plugin.discover()
        #expect(cloud.paths.filter { $0 == "/api/v2/common/getAppServiceUrl" }.count == 1)
        await host.stop()
    }

    /// The table knows the camera: the cloud is not asked. An address another device has now is not taken.
    @Test func theTableWinsOverTheCloud() async throws {
        let cloud = FakeTapoCloud()
        cloud.state.withLockedValue { $0.addresses["CLOUDID0001"] = "192.168.1.2" }
        let (host, plugin) = try await signedIn(FakeNeighbours([Self.garden]), cloud: cloud)
        #expect(try await plugin.discover().first?.address == "192.168.1.40")
        #expect(cloud.state.withLockedValue { $0.detailRequests } == 0)
        await host.stop()
        let stale = try await signedIn(FakeNeighbours([("192.168.1.2", "AA:BB:CC:DD:EE:FF")]), cloud: cloud)
        #expect(try await stale.1.discover().first?.address == nil)
        await stale.0.stop()
    }

    @Test func discoveryNeverSignsIn() async throws {
        let cloud = FakeTapoCloud()
        let host = try await environment.start(devices: [], cloud: cloud, neighbours: FakeNeighbours([Self.garden]))
        let plugin = try #require(environment.plugin)
        #expect(try await plugin.discover().isEmpty)
        #expect(cloud.logins == 0)
        await host.stop()
    }

    @Test func aCameraOfTheBlockIsNotListedTwice() async throws {
        let byCloudID = try await signedIn(FakeNeighbours(), devices: [["name": "Back", "host": "192.168.1.41", "type": "Camera", "motion": false, "cloudId": "CLOUDID0001"]])
        #expect(try await byCloudID.1.discover().map(\.deviceID) == ["192.168.1.41Back"])
        await byCloudID.0.stop()
        let byMAC = try await signedIn(FakeNeighbours([Self.garden]), devices: [["name": "Back", "host": "192.168.1.40", "type": "Camera", "motion": false]])
        #expect(try await byMAC.1.discover().map(\.deviceID) == ["192.168.1.40Back"])
        await byMAC.0.stop()
        let byName = try await signedIn(FakeNeighbours(), devices: [["name": "garden", "host": "192.168.1.42", "type": "Camera", "motion": false]])
        #expect(try await byName.1.discover().map(\.deviceID) == ["192.168.1.42garden"])
        await byName.0.stop()
    }

    @Test func settingUpACameraWritesItsAddressTypeAndCloudID() async throws {
        let (host, plugin) = try await signedIn(FakeNeighbours([Self.garden]))
        let camera = try #require(try await plugin.discover().first)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(camera))) else {
            Issue.record("A camera found at its address asks nothing")
            return
        }
        #expect(outcome.credentials == nil)
        #expect(outcome.deviceID == nil)
        #expect(outcome.settings == ["host": "192.168.1.40", "type": "DualLensCamera", "cloudId": "CLOUDID0001", "name": "Garden"])
        await host.stop()
    }

    @Test func aCameraWithoutAddressAsksForIt() async throws {
        let neighbours = FakeNeighbours([("192.168.1.50", "AA:BB:CC:DD:EE:FF")])
        let (host, plugin) = try await signedIn(neighbours)
        let camera = try #require(try await plugin.discover().first)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(camera))) else {
            Issue.record("No address asked")
            return
        }
        #expect(prompt.fields.map(\.key) == ["host"])
        #expect(prompt.values["name"] == "Garden")
        // An address whose MAC is another device's is refused; one the table does not know is taken as given.
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .device(camera), answers: ["host": "192.168.1.50"]))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(camera), answers: ["host": "192.168.1.60"])) else {
            Issue.record("The address given was not taken")
            return
        }
        #expect(outcome.settings["host"] == "192.168.1.60")
        await host.stop()
    }

    @Test func theAccountSignsInToTheCloudWithoutCameras() async throws {
        let cloud = FakeTapoCloud()
        let host = try await environment.start(devices: [], settings: [:], cloud: cloud)
        let plugin = try #require(environment.plugin)
        guard case .done = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "user@example.com", "password": "password123"])) else {
            Issue.record("Not signed in")
            return
        }
        #expect(cloud.logins == 1)
        await host.stop()
    }

    @Test func theCodeMayBeLeftOutWithoutCameras() async throws {
        let cloud = FakeTapoCloud()
        cloud.state.withLockedValue { $0.requiresCode = true }
        let host = try await environment.start(devices: [], settings: [:], cloud: cloud)
        let plugin = try #require(environment.plugin)
        guard case .ask(let prompt, let state) = try await plugin.authorize(
            SetupRequest(target: .account, answers: ["username": "user@example.com", "password": "password123"])) else {
            Issue.record("No code asked")
            return
        }
        #expect(prompt.fields.first?.optional == true)
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: [:], state: state)) else {
            Issue.record("Not signed in without the code")
            return
        }
        #expect(outcome.credentials?["username"]?.stringValue == "user@example.com")
        #expect(cloud.state.withLockedValue { $0.trustedTerminals.isEmpty })
        await host.stop()
    }
}
