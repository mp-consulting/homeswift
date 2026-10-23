import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// The camera code when things overlap: a recording stream closed as it starts, two consumers starting one
/// livestream session, a stray stop; and the operating mode's characteristics.
extension CameraStreamingTests {
    @ProtectActor func manager(_ device: ProtectDevice?) -> ProtectLivestreamManager? { (device as? ProtectCamera)?.livestream }

    @Test func aRecordingClosedAsItStartsLeavesNothingRunning() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(timeScale: 1, ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let recording = try #require(await recording(environment.device("camera-id")))
        await recording.updateRecordingConfiguration(Self.recordingConfiguration())
        let activation = Task { await recording.updateRecordingActive(true) }
        let socket = try #require(await eventually { environment.webSockets.connections.contains { $0.path.contains("livestream") } }
            ? environment.webSockets.connections.last { $0.path.contains("livestream") } : nil)
        socket.push(ProtocolTests.livePacket(250, Data("init".utf8)))
        await activation.value
        for value in UInt8(1)...UInt8(3) {
            socket.push(ProtocolTests.livePacket(249) + ProtocolTests.livePacket(251, Data([value])) + ProtocolTests.livePacket(254, Data([value])) + ProtocolTests.livePacket(255))
        }
        let timeshift = await recording.timeshift
        #expect(await eventually { await timeshift.time == 300 })
        // The home hub asks for an event and closes the stream at once.
        let packets = await recording.handleRecordingStreamRequest(streamID: 7)
        await recording.closeRecordingStream(streamID: 7, reason: .cancelled)
        for try await _ in packets {}
        // Whatever FFmpeg the event started is stopped, and the livestream was not restarted for it.
        #expect(await eventually { ffmpeg.state.withLockedValue { $0.recordings.allSatisfy { $0.process.isStopped } } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!socket.isClosed)
        #expect(environment.webSockets.connections.filter { $0.path.contains("livestream") }.count == 1)
        await recording.updateRecordingActive(false)
    }

    @Test func consumersStartingTogetherShareOneSession() async throws {
        let environment = ProtectTestEnvironment(timeScale: 1, ffmpeg: FakeFfmpegKit())
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await controller(environment, host, Self.cameraID)
        let device = await environment.device("camera-id")
        let manager = try #require(await manager(device))
        let entry = try #require(await liveFeedEntry(device))
        #expect(await manager.acquire(entry) != nil)
        async let first = manager.start(entry)
        async let second = manager.start(entry)
        let started = await [first, second]
        #expect(started == [true, true])
        #expect(await manager.subscriberCount(entry) == 2)
        // One WebSocket: the second start waited for the first instead of starting the session again.
        #expect(environment.webSockets.connections.filter { $0.path.contains("livestream") }.count == 1)
        let socket = try #require(environment.webSockets.connections.last { $0.path.contains("livestream") })
        #expect(!socket.isClosed)
        // Two consumers leave; a third stop, from a consumer that was never counted, changes nothing.
        await manager.stop(entry)
        #expect(await manager.subscriberCount(entry) == 1 && !socket.isClosed)
        await manager.stop(entry)
        #expect(await manager.subscriberCount(entry) == 0)
        await manager.stop(entry)
        #expect(await manager.subscriberCount(entry) == 0)
        #expect(await eventually { socket.isClosed })
    }

    @Test func operatingModeCharacteristics() async throws {
        let environment = ProtectTestEnvironment(ffmpeg: FakeFfmpegKit())
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let controller = try #require(await controller(environment, host, Self.cameraID))
        // The controller's own service, which the camera's status light and night vision join.
        let operatingMode = try #require(controller.services.first { $0.type.uuid == ServiceType.cameraOperatingMode.uuid })
        let indicator = try #require(operatingMode[.cameraOperatingModeIndicator])
        #expect(indicator.value == .bool(true))
        #expect(operatingMode[.nightVision]?.value == .bool(true))
        // As published: the accessory HomeKit sees has them.
        let published = try #require(environment.accessory(host, Self.cameraID)?.services.first { $0.type.uuid == ServiceType.cameraOperatingMode.uuid })
        #expect(published[.cameraOperatingModeIndicator] != nil && published[.nightVision] != nil)
        try await indicator.write(.bool(false))
        let patch = try #require(environment.controller.requests("/proxy/protect/api/cameras/camera-id").last)
        #expect(FakeController.body(patch) == ["ledSettings": ["isEnabled": false]])
    }
}
