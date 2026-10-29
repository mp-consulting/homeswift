import Foundation
import HomeswiftFFmpeg
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// The plugin's camera code on the HAP camera controller, and HomeswiftCameraKit.swift: HomeswiftFFmpeg behind the FFmpeg protocols.
@Suite(.timeLimit(.minutes(1))) struct CameraKitAdapterTests {
    static let cameraID = ProtectPlatform.accessoryID(Fixtures.cameraMAC)

    @Test func theCameraControllerOnTheAccessory() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        #expect(await eventually {
            environment.accessory(host, Self.cameraID)?.services.contains { $0.type.uuid == ServiceType.cameraRecordingManagement.uuid } == true
        })
        let accessory = try #require(environment.accessory(host, Self.cameraID))
        let controller = try #require(accessory.cameraController)
        // Ten streams, a microphone, HKSV with the plugin's motion sensor, and no doubled services.
        #expect(controller.streamManagementServices.count == 10)
        #expect(accessory.services.filter { $0.type.uuid == ServiceType.cameraRTPStreamManagement.uuid }.count == 10)
        #expect(accessory.services.filter { $0.type.uuid == ServiceType.motionSensor.uuid }.count == 1)
        #expect(controller.motionService === accessory[.motionSensor])
        #expect(controller.microphoneService != nil && controller.speakerService == nil)
        // A snapshot from HomeKit goes through the plugin's snapshot pipeline.
        let image = try await controller.handleSnapshotRequest(height: 360, width: 640)
        #expect(image == Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(ffmpeg.execs.last?.arguments.contains("scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2") == true)
    }

    @Test func theStreamingDelegateIsThePlugins() async throws {
        let ffmpeg = FakeFfmpegKit()
        let environment = ProtectTestEnvironment(ffmpeg: ffmpeg)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        _ = await eventually { environment.accessory(host, Self.cameraID)?.cameraController != nil }
        let controller = try #require(environment.accessory(host, Self.cameraID)?.cameraController)
        let delegate = controller.options.delegate
        let response = try await delegate.prepareStream(PrepareStreamRequest(
            sessionID: "session-1", sourceAddress: "10.0.0.1", targetAddress: "10.0.0.2", addressVersion: .ipv4,
            video: .init(port: 51000, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data(repeating: 1, count: 16), srtpSalt: Data(repeating: 2, count: 14)),
            audio: .init(port: 51002, srtpCryptoSuite: .aesCM128HMACSHA1_80, srtpKey: Data(repeating: 3, count: 16), srtpSalt: Data(repeating: 4, count: 14))))
        #expect(response.video.port == 50001 && response.audio?.port == 50000 && response.video.srtpKey == Data(repeating: 1, count: 16))
        try await delegate.handleStreamRequest(.start(StartStreamRequest(
            sessionID: "session-1",
            video: VideoInfo(codec: 0, profile: 1, level: 2, packetizationMode: 0, cvoId: nil, width: 1280, height: 720, fps: 30, pt: 99, ssrc: 1,
                             maxBitRate: 299, rtcpInterval: 0.5, mtu: 1378),
            audio: AudioInfo(codec: .aacELD, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: 30, pt: 110, ssrc: 2, maxBitRate: 24,
                             rtcpInterval: 5, comfortPT: 13, comfortNoiseEnabled: false))))
        let process = try #require(ffmpeg.streams.last)
        #expect(process.argument(after: "-payload_type") == "99" && process.argument(after: "-ar") == "16k")
        try await delegate.handleStreamRequest(.stop(sessionID: "session-1"))
        #expect(process.isStopped)
    }

    static let hasFFmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].contains { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: hasFFmpeg)) func realFFmpegMakesASnapshot() async throws {
        let ffmpeg = HomeswiftFfmpegKit(videoProcessor: nil, verbose: false, logger: testLogger)
        #expect(await ffmpeg.probe())
        let options = ffmpeg.makeOptions(name: { "Test" }, crop: nil, debug: false, hardwareDecoding: false, hardwareTranscoding: false, log: testLogger)
        let arguments = ProtectSnapshot.snapshotArguments(input: ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=1"], decoder: [],
                                                          request: SnapshotRequest(height: 120, width: 160), verbose: false)
        let result = try #require(await ffmpeg.exec(options: options, arguments: arguments, stdin: nil, timeout: 10_000, logErrors: true))
        #expect(result.exitCode == 0)
        #expect(result.stdout.prefix(2) == Data([0xFF, 0xD8]))
        let port = await ffmpeg.reservePort(ipv6: false, count: 2)
        #expect(port > 0)
        ffmpeg.cancelPort(port)
        ffmpeg.cancelPort(port + 1)
    }
}
