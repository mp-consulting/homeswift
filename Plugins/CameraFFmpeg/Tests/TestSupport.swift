import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import Homeswift
@testable import HomeswiftCameraFFmpeg

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A host with one `Camera-ffmpeg` block, its MQTT broker in memory and its timers shortened.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-CameraFFmpeg-tests-\(UUID().uuidString)")
    let mqtt = FakeMQTTConnection()
    let timeScale: Double
    private let plugins = NIOLockedValueBox<[CameraFFmpegPlugin]>([])

    init(timeScale: Double = 0.01) {
        self.timeScale = timeScale
    }

    var plugin: CameraFFmpegPlugin? { plugins.withLockedValue { $0.last } }

    func start(_ settings: [String: Any]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let mqtt = mqtt
        let timeScale = timeScale
        registry.register(platform: CameraFFmpegPlugin.platform, name: CameraFFmpegPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(CameraFFmpegPlugin.Configuration.self, from: json)
            let plugin = CameraFFmpegPlugin(configuration: configuration, context: context,
                                            dependencies: .init(connectMQTT: { _ in mqtt }, timeScale: timeScale, capabilities: { _, _ in FFmpegCapabilities(known: nil) }))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: CameraFFmpegPlugin.platform, name: CameraFFmpegPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }

    /// The accessory published on its own server for a camera.
    func accessory(_ host: PluginHost, named name: String) -> Accessory? {
        host.bridges.dropFirst().flatMap { $0.server.accessories }.first { $0.id == CameraFFmpegPlugin.accessoryID(name: name) }
    }

    /// A shell script standing in for FFmpeg: a recording prints a few MP4 boxes, a snapshot fetch prints `IMAGE`, a
    /// resize echoes its input, anything else
    /// writes a line to standard error and waits, as a stream does. Each run appends its arguments to `runs`.
    func fakeFFmpeg() throws -> (path: String, runs: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("ffmpeg")
        let runs = directory.appendingPathComponent("runs.txt")
        try """
            #!/bin/sh
            echo "$@" >> '\(runs.path)'
            case "$*" in
              *"omit_tfhd_offset"*|*"-codec:v copy -f mp4"*) printf '\\000\\000\\000\\010ftyp\\000\\000\\000\\010moov\\000\\000\\000\\010free\\000\\000\\000\\010moof\\000\\000\\000\\014mdat1234' ;;
              *"-i pipe: "*) cat ;;
              *"-frames:v 1"*) printf 'IMAGE' ;;
              *) echo "started" >&2; exec sleep 30 ;;
            esac
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, runs)
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// A camera's video settings from JSON, as a block gives them.
func videoConfig(_ json: [String: Any]) throws -> CameraFFmpegPlugin.VideoConfig {
    CameraFFmpegPlugin.VideoConfig(json: try JSONValue(any: json))
}

/// What HomeKit sends to start a stream (the spec's vector by default).
func startRequest(width: Int = 1920, height: Int = 1080, fps: Int = 30, bitrate: Int = 802, audio: AudioStreamingCodecType = .aacELD,
                  rtcpInterval: Float = 0.5, sessionID: String = "session") -> StartStreamRequest {
    StartStreamRequest(
        sessionID: sessionID,
        video: VideoInfo(codec: 0, profile: 2, level: 2, packetizationMode: 0, cvoId: nil, width: width, height: height, fps: fps, pt: 99, ssrc: 1,
                         maxBitRate: bitrate, rtcpInterval: rtcpInterval, mtu: 1378),
        audio: AudioInfo(codec: audio, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: 30, pt: 110, ssrc: 2, maxBitRate: 24,
                         rtcpInterval: 5, comfortPT: 13, comfortNoiseEnabled: false))
}

/// What HomeKit selected for recordings: High, 4.0, `bitrate` kbit/s, 1080p at 30 fps, AAC-LC 64 kbit/s mono.
func recordingConfiguration(bitrate: Int = 2000) -> CameraRecordingConfiguration {
    CameraRecordingConfiguration(
        prebufferLength: 4000, eventTriggerTypes: [.motion], mediaContainerConfiguration: MediaContainerConfiguration(fragmentLength: 4000),
        videoCodec: .init(type: .h264, parameters: .init(profile: .high, level: .level4_0, bitRate: bitrate, iFrameInterval: 4000),
                          resolution: VideoResolution(1920, 1080, 30)),
        audioCodec: .init(audioChannels: 1, type: .aacLC, samplerate: .khz32, bitrateMode: .variable, bitrate: 64))
}

/// The spec's stream target: the controller at 192.168.1.20, video on 51000, audio on 51002.
let videoKey = Data(repeating: 0x55, count: 30)
let audioKey = Data(repeating: 0x00, count: 30)
let streamTarget = FFmpegArguments.Target(
    address: "192.168.1.20", videoPort: 51000, videoSRTP: videoKey, videoSSRC: 1111, audioPort: 51002, audioSRTP: audioKey, audioSSRC: 2222, isIPv6: false)
