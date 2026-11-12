import Foundation
import Testing

@testable import Homeswift
@testable import HomeswiftNetwork
@testable import HomeswiftPhilipsAmbilightTV

/// Ambilight's on/off from the TV's settings menu, for the models (a 77OLED848/12) whose Ambilight endpoints
/// answer off however it is lit.
@Suite(.timeLimit(.minutes(1)))
struct AmbilightMenuTests {
    let environment = PhilipsTestEnvironment()

    private func client(_ tv: FakeTV, menuStructureRetry: Duration = JointSpace.menuStructureRetry) -> JointSpaceClient {
        JointSpaceClient(ip: "192.168.1.20", username: "user1", password: "secret", certificateFingerprint: FakeTV.fingerprint,
            transports: FakeTransports(tv: tv), logger: testLogger, gap: .zero, menuStructureRetry: menuStructureRetry)
    }

    @Test func readsOnAndOffFromTheMenu() async throws {
        let tv = environment.tv
        await tv.set(hasAmbilightMenu: true)
        await tv.set(endpointsReportAmbilightOff: true)
        await tv.set(menuActive: FakeTV.menu.followVideo)
        let client = client(tv)

        #expect(await client.ambilightMenuNodes() == .init(style: FakeTV.menu.style, off: FakeTV.menu.off, brightness: FakeTV.menu.brightness))
        #expect(await client.ambilightMenuState() == true)
        #expect(await client.hasAmbilightMenuState)
        // Lit, though the style endpoint says OFF: on, without its configuration.
        #expect(await client.ambilightState() == .init(on: true))

        await tv.set(menuActive: FakeTV.menu.off)
        let configurationReads = await tv.requestCount("ambilight/currentconfiguration")
        #expect(await client.ambilightState() == .init(on: false))
        // Off by the menu: the style is not read.
        #expect(await tv.requestCount("ambilight/currentconfiguration") == configurationReads)
        // The structure is read once.
        #expect(await tv.requestCount("menuitems/settings/structure") == 1)
    }

    @Test func keepsTheEndpointsOnATVWithoutTheMenu() async throws {
        let tv = environment.tv
        await tv.set(ambilight: .init(styleName: "FOLLOW_VIDEO"))
        let client = client(tv, menuStructureRetry: .seconds(1))

        #expect(await client.ambilightState() == .init(on: true, configuration: .init(styleName: "FOLLOW_VIDEO")))
        #expect(await client.ambilightState()?.on == true)
        #expect(await !client.hasAmbilightMenuState)
        // A failed structure read waits before the next one rather than slowing every poll...
        #expect(await tv.requestCount("menuitems/settings/structure") == 1)
        // ...and is tried again after it.
        await tv.set(hasAmbilightMenu: true)
        await tv.set(menuActive: FakeTV.menu.followVideo)
        #expect(await eventually { await client.ambilightMenuState() == true })
    }

    @Test func stopsTrustingAMenuThatMisses() async throws {
        let tv = environment.tv
        await tv.set(hasAmbilightMenu: true)
        await tv.set(endpointsReportAmbilightOff: true)
        await tv.set(menuActive: FakeTV.menu.followVideo)
        let client = client(tv)
        #expect(await client.ambilightState()?.on == true)

        // A missed read applies nothing: the endpoints would say off.
        await tv.set(menuAnswers: false)
        #expect(await client.ambilightState() == nil)
        #expect(await client.ambilightState() == nil)
        #expect(await client.hasAmbilightMenuState)
        // The third in a row: back to the endpoints.
        #expect(await client.ambilightState() == .init(on: false, configuration: .init(styleName: "OFF")))
        #expect(await !client.hasAmbilightMenuState)
    }

    @Test func switchesOffAndSetsTheBrightnessThroughTheMenu() async throws {
        let tv = environment.tv
        await tv.set(hasAmbilightMenu: true)
        await tv.set(endpointsReportAmbilightOff: true)
        await tv.set(menuActive: FakeTV.menu.followVideo)
        let client = client(tv)

        // Before the menu has answered: the style, as before.
        try await client.setAmbilightOff()
        #expect(await tv.ambilightWrites.last?.style == "OFF")
        #expect(await tv.menuWrites.isEmpty)
        // A style OFF left the menu on its last style.
        #expect(await client.ambilightMenuState() == true)

        // Once it has: the style list's Off entry, as the TV's Ambilight button does.
        let styleWrites = await tv.ambilightWrites.count
        try await client.setAmbilightOff()
        #expect(await tv.menuWrites.last.map { [$0.node: $0.data] } == [FakeTV.menu.style: ["activenode_id": FakeTV.menu.off]])
        #expect(await tv.ambilightWrites.count == styleWrites)
        #expect(await client.ambilightState() == .init(on: false))

        // The brightness goes to the node this TV reports.
        try await client.setAmbilightBrightness(7)
        #expect(await tv.menuWrites.last?.node == FakeTV.menu.brightness)
        #expect(await tv.menuBrightness == 7)
    }

    @Test func findsMenuNodesWhereverTheyAre() throws {
        let structure = try JSONDecoder().decode(JSONPayload.self, from: JSONSerialization.data(withJSONObject: FakeTV.menuStructure))
        #expect(structure.menuNode(context: "ambilight_style")?.menuNodeID == FakeTV.menu.style)
        #expect(structure.menuNode(context: "ambilight_off")?.menuNodeID == FakeTV.menu.off)   // sent as a string
        #expect(structure.menuNode(context: "ambilight_lounge_light") == nil)
        #expect(JSONPayload.number(1.5).nodeID == nil)
        #expect(JSONPayload.string("-12").nodeID == nil)
    }

    /// The tile switched on from HomeKit stays on through the polls after the cooldown, though the endpoints
    /// say off; switched off, it goes off in the menu too; the remote's Ambilight button is followed.
    @Test func keepsTheTileOnATVWhoseEndpointsSayOff() async throws {
        let tv = environment.tv
        await tv.set(power: "On")
        await tv.set(hasAmbilightMenu: true)
        await tv.set(endpointsReportAmbilightOff: true)
        let host = try await environment.start(settings: ["devices": [livingRoom]])
        defer { Task { await host.stop() } }
        let bridge = host.bridges[1]
        #expect(await eventually { bridge.server.primary.service(.television)?[.active]?.value == .int(1) })
        // The apps the TV lists rebuild the accessory: the tile is taken from the rebuilt one, which the device updates.
        #expect(await eventually { bridge.server.primary.service(.inputSource, subtype: "input-14") != nil })
        let ambilight = try #require(bridge.server.primary.service(.lightbulb, subtype: "ambilight"))
        #expect(await eventually { await tv.menuReads.count > 0 })

        try await ambilight.characteristic(.on).write(.bool(true))
        #expect(await tv.menuActive == FakeTV.menu.followVideo)
        // Polls once the cooldown is over: it starts again at each re-apply of the style.
        let cooldownOver = ContinuousClock.now + (TVDevice.styleRetryDelays.reduce(.zero, +) + TVDevice.userActionCooldown) * tvTimeScale
        #expect(await eventually { await tv.menuReads.filter { $0 > cooldownOver }.count >= 2 })
        #expect(ambilight[.on]?.value == .bool(true))

        try await ambilight.characteristic(.on).write(.bool(false))
        #expect(await tv.menuActive == FakeTV.menu.off)
        #expect(ambilight[.on]?.value == .bool(false))

        // The remote's Ambilight button: the tile follows the menu.
        await tv.set(menuActive: FakeTV.menu.followVideo)
        #expect(await eventually { ambilight[.on]?.value == .bool(true) })
    }
}
