import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftTapo

/// The tele lens's preset and patrol switches: they come with the first live view, move the camera only while it is
/// awake, and keep the lens's other services and its id.
@Suite(.timeLimit(.minutes(1)))
struct TapoPTZSwitchTests {
    let environment = TestEnvironment()
    /// Live views over the fake camera: a handshake within 400 ms, which a loaded runner keeps to.
    static let timeScale = 0.02
    let deviceID = "192.168.1.40Garden"
    let teleID = "TapoP100:192.168.1.40Garden:tele"
    let wideID = "TapoP100:192.168.1.40Garden"

    func awakeCamera() -> (FakeTapoControlCamera, FakeStreamdCamera) {
        let camera = FakeStreamdCamera()
        camera.state.withLockedValue {
            $0.password = "password123"
            $0.keepStreaming = .milliseconds(5)
        }
        return (FakeTapoControlCamera(), camera)
    }

    /// The accessory the bridge has now under `id` (a new one once its switches change).
    func published(_ host: PluginHost, _ id: String) -> Accessory? {
        host.bridges.flatMap(\.server.accessories).first { $0.id == id }
    }

    func switches(_ host: PluginHost, _ id: String) -> [String: Service] {
        Dictionary(uniqueKeysWithValues: (published(host, id)?.services ?? []).filter { $0.type.uuid == ServiceType.switch.uuid }.map { ($0.subtype ?? "", $0) })
    }

    @Test func theFirstLiveViewBringsThePresetAndPatrolSwitches() async throws {
        let (control, camera) = awakeCamera()
        let devices: [[String: Any]] = [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera", "motion": false]]
        let host = try await environment.start(devices: devices, connect: camera.connect, control: control, timeScale: Self.timeScale)
        #expect(await eventually { published(host, teleID) != nil })
        // Nothing is known of the motor before the camera was ever watched.
        #expect(switches(host, teleID).isEmpty)
        let feed = try #require(await environment.plugin?.cameraRuntimes[deviceID]?.feed)
        let viewer = await feed.join()
        #expect(await eventually { Set(switches(host, teleID).keys) == ["preset1", "preset2", "patrol-x", "patrol-y"] })
        let tele = try #require(published(host, teleID))
        #expect(switches(host, teleID)["preset1"]?[.name]?.value == .string("Go to Gate"))
        #expect(switches(host, teleID)["patrol-y"]?[.name]?.value == .string("Vertical Patrol"))
        // The Home app shows a Configured Name, and numbers a service without one.
        #expect(switches(host, teleID)["preset1"]?[.configuredName]?.value == .string("Go to Gate"))
        #expect(switches(host, teleID)["patrol-x"]?[.configuredName]?.value == .string("Horizontal Patrol"))
        // The same lens: its camera and battery are still there; the wide lens has no switches.
        #expect(tele.cameraController != nil)
        #expect(tele.service(.battery) != nil)
        #expect(switches(host, wideID).isEmpty)

        // A preset switch turns the camera there, then turns itself off.
        let gate = try #require(switches(host, teleID)["preset2"])
        try await gate.characteristic(.on).write(.bool(true))
        #expect(control.state.withLockedValue { $0.presetsVisited } == ["2"])
        #expect(await eventually { gate[.on]?.value == .bool(false) })

        // One patrol at a time; turning it off stops the sweep.
        let horizontal = try #require(switches(host, teleID)["patrol-x"])
        let vertical = try #require(switches(host, teleID)["patrol-y"])
        try await horizontal.characteristic(.on).write(.bool(true))
        try await vertical.characteristic(.on).write(.bool(true))
        #expect(horizontal[.on]?.value == .bool(false))
        try await vertical.characteristic(.on).write(.bool(false))
        #expect(control.state.withLockedValue { $0.cruises } == ["x", "y", "stop"])

        // Going to a preset ends a patrol: the sweep is stopped first, and its switch turns off.
        try await horizontal.characteristic(.on).write(.bool(true))
        try await gate.characteristic(.on).write(.bool(true))
        #expect(control.state.withLockedValue { $0.cruises } == ["x", "y", "stop", "x", "stop"])
        #expect(control.state.withLockedValue { $0.presetsVisited } == ["2", "2"])
        #expect(horizontal[.on]?.value == .bool(false))

        // The camera goes back to sleep with its patrol on: the switch turns off, and the next one is refused.
        try await horizontal.characteristic(.on).write(.bool(true))
        await feed.leave(viewer.id)
        #expect(await eventually { horizontal[.on]?.value == .bool(false) })
        await #expect(throws: HAPStatusError.self) { try await gate.characteristic(.on).write(.bool(true)) }
        #expect(control.state.withLockedValue { $0.presetsVisited } == ["2", "2"])
        await host.stop()

        // A restart has them from the start, from `ptz.json`, without waking the camera.
        let reads = control.state.withLockedValue { $0.logins }
        let again = try await environment.start(devices: devices, connect: camera.connect, control: control, timeScale: Self.timeScale)
        #expect(await eventually { Set(switches(again, teleID).keys) == ["preset1", "preset2", "patrol-x", "patrol-y"] })
        #expect(control.state.withLockedValue { $0.logins } == reads)
        await again.stop()
    }

    @Test func theOptionsLeaveThemOut() async throws {
        let (control, camera) = awakeCamera()
        let devices: [[String: Any]] = [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera", "motion": false,
                                         "presetSwitches": false, "patrolSwitches": false]]
        let host = try await environment.start(devices: devices, connect: camera.connect, control: control, timeScale: Self.timeScale)
        #expect(await eventually { published(host, teleID) != nil })
        let feed = try #require(await environment.plugin?.cameraRuntimes[deviceID]?.feed)
        // Kept: a viewer whose stream is dropped leaves, and the live view closes.
        let viewer = await feed.join()
        // Not asked about its motor for switches nobody wants: the battery alone is read.
        #expect(await eventually { control.state.withLockedValue { $0.deviceInfoReads } >= 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(switches(host, teleID).isEmpty)
        await feed.leave(viewer.id)
        await host.stop()
    }
}
