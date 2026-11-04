import Crypto
import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Any camera FFmpeg can read (RTSP, HTTP, MJPEG…) in HomeKit, as homebridge-camera-ffmpeg puts it there: live
/// streams and snapshots through FFmpeg, two-way audio, HomeKit Secure Video with an optional prebuffer, and a motion
/// sensor, a doorbell and trigger switches driven by MQTT messages or a small HTTP API. Each camera is an accessory of
/// its own (`context.publishExternal`), added in the Home app with the bridge's setup code. The configuration is that
/// plugin's `Camera-ffmpeg` block, so a Homebridge block works unchanged; docs/clean-room/CameraFFmpeg.md is the
/// functional specification it was written from. See README.md.
public actor CameraFFmpegPlugin: HomeswiftPlugin {
    /// What the plugin reaches the world with; tests swap them.
    struct Dependencies: Sendable {
        var connectMQTT: @Sendable (MQTTConfiguration) -> any MQTTConnection = { MQTTClient($0) }
        /// Multiplies the plugin's timers (motion, doorbell, inactivity, the snapshot cache): tests shorten them.
        var timeScale: Double = 1
        var ports = RtpPortAllocator()
    }

    /// One camera on its own accessory.
    struct CameraRuntime {
        let accessory: Accessory
        let controller: CameraController
        let streamer: CameraStreamer
        let recorder: CameraRecorder
        let triggers: CameraTriggers
    }

    public static let platform = "Camera-ffmpeg"
    public static let name = "FFmpeg Cameras"
    public static let icon: String? = "camera"
    public static let summary: String? = "Any camera FFmpeg can read, with HomeKit Secure Video, motion and doorbell"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    /// Every camera is of this Device Kind.
    static let cameraKind = "camera"

    /// The sizes HomeKit may ask for, for streams and recordings (section 4.3); 320 x 240 at 15 fps is the Apple Watch's.
    static let resolutions: [VideoResolution] = [
        VideoResolution(320, 180, 30), VideoResolution(320, 240, 15), VideoResolution(320, 240, 30), VideoResolution(480, 270, 30),
        VideoResolution(480, 360, 30), VideoResolution(640, 360, 30), VideoResolution(640, 480, 30), VideoResolution(1280, 720, 30),
        VideoResolution(1280, 960, 30), VideoResolution(1920, 1080, 30), VideoResolution(1600, 1200, 30),
    ]

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private(set) var cameras: [String: CameraRuntime] = [:]
    private var mqtt: MQTTAutomation?
    private var http: HTTPAutomationServer?
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    static func accessoryID(name: String) -> String { "\(platform):\(name)" }

    // MARK: The cameras of the block

    /// A camera that passed the checks, with its name (given, or `Camera N`) and its video settings.
    struct AcceptedCamera: Sendable {
        var name: String
        var camera: Camera
        var video: VideoConfig
    }

    /// The cameras in order (section 4.1): an unnamed one is named `Camera N` and kept, one without `videoConfig` or
    /// `source` is skipped, a second camera of the same name (the same HAP-NodeJS UUID) is skipped.
    static func accept(_ cameras: [Camera], logger: Logger) -> [AcceptedCamera] {
        var accepted: [AcceptedCamera] = []
        var uuids = Set<String>()
        for var camera in cameras {
            if camera.name == nil {
                let name = "Camera \(accepted.count + 1)"
                logger.error("One of your cameras has no name configured. This camera will be named \"\(name)\".")
                camera.name = name
            }
            let name = camera.name ?? ""
            guard let video = camera.videoConfig else {
                logger.error("[\(name)] The videoConfig section is missing from the config. This camera will be skipped.")
                continue
            }
            guard let source = video.source else {
                logger.error("[\(name)] There is no source configured for this camera. This camera will be skipped.")
                continue
            }
            if !FFmpegArguments.split(source).contains("-i") {
                logger.warning("[\(name)] The source for this camera is missing \"-i\", it is likely misconfigured.")
            }
            if let still = video.stillImageSource, !FFmpegArguments.split(still).contains("-i") {
                logger.warning("[\(name)] The stillImageSource for this camera is missing \"-i\", it is likely misconfigured.")
            }
            if video.vcodec == "copy", video.videoFilter != nil {
                logger.warning("[\(name)] A videoFilter is defined, but the copy vcodec is being used. This will be ignored.")
            }
            guard uuids.insert(hapUUID(name)).inserted else {
                logger.warning("[\(name)] Multiple cameras are configured with this name. Duplicate cameras will be skipped.")
                continue
            }
            accepted.append(AcceptedCamera(name: name, camera: camera, video: video))
        }
        return accepted
    }

    /// HAP-NodeJS's `uuid.generate`: the SHA-1 of the text laid out as a version 4 UUID, the accessory UUID of a camera in
    /// the original (its name is the seed).
    static func hapUUID(_ text: String) -> String {
        let hex = Array(Secrets.hex(Insecure.SHA1.hash(data: Data(text.utf8))))
        func digits(_ range: Range<Int>) -> String { String(hex[range]) }
        let variant = String(Int(String(hex[15]), radix: 16).map { $0 & 0x3 | 0x8 } ?? 8, radix: 16)
        return "\(digits(0..<8))-\(digits(8..<12))-4\(digits(12..<15))-\(variant)\(digits(16..<19))-\(digits(19..<31))"
    }

    /// The block's cameras, each with its Accessory Settings (by its name) on top.
    func configuredCameras() -> [Camera] {
        configuration.cameras.map { camera in camera.name.map { camera.with(settings: context.accessorySettings(for: $0).plugin) } ?? camera }
    }

    // MARK: Lifecycle

    public func start() async throws {
        let accepted = Self.accept(configuredCameras(), logger: logger)
        var routes = MQTTRoutes()
        for entry in accepted where !context.isExcluded(entry.name) {
            do {
                let runtime = try await publish(entry)
                cameras[entry.name] = runtime
                if configuration.mqttHost != nil, let mqtt = entry.camera.mqtt {
                    routes.register(camera: entry.name, mqtt: mqtt, triggers: runtime.triggers)
                }
                if let prebuffer = runtime.recorder.prebuffer {
                    let log = runtime.streamer.log
                    tasks.add {
                        do { try await prebuffer.start() } catch { log.error("Prebuffer failed to start: \(error)") }
                    }
                }
            } catch {
                logger.error("[\(entry.name)] Could not publish the camera: \(error)")
            }
        }
        await context.removeAccessories(keeping: Set(cameras.values.map(\.accessory.id)), message: "Removing stale accessory")

        if let host = configuration.mqttHost {
            mqtt = MQTTAutomation(configuration: configuration, host: host, password: brokerPassword, routes: routes, logger: logger, connect: dependencies.connectMQTT)
        }
        if let port = configuration.httpPort {
            let server = HTTPAutomationServer()
            http = server
            let triggers = cameras.mapValues(\.triggers)
            let localOnly = configuration.httpLocalOnly
            let logger = logger
            tasks.add {
                do {
                    try await server.start(port: port, localOnly: localOnly, handler: { target in
                        await HTTPAutomation.respond(to: target, cameras: triggers)
                    }, logger: logger)
                } catch {
                    logger.error("Could not start the HTTP server on port \(port): \(error)")
                }
            }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        await http?.stop()
        await mqtt?.stop()
        for runtime in cameras.values {
            await runtime.streamer.stopAll()
            runtime.recorder.shutdown()
            await runtime.triggers.cancel()
            runtime.controller.destroy()
        }
    }

    /// Builds a camera's accessory (section 4.2) and publishes it on its own server.
    private func publish(_ entry: AcceptedCamera) async throws -> CameraRuntime {
        let name = entry.name
        let camera = entry.camera
        let video = entry.video
        let log = CameraLog(logger: logger, name: name, promotesDebug: video.debug)
        let tools = FFmpegTools(executable: configuration.videoProcessor ?? "ffmpeg", name: name, logger: logger, debug: video.debug,
                                debugReturn: video.debugReturn)
        log.debug("Recording \(video.recording ? "on" : "off"), prebuffer \(video.prebuffer ? "on" : "off").")

        let motionSensor = camera.motion ? Service(.motionSensor, name: name) : nil
        let motionSwitch = camera.motion && camera.switches ? Service(.switch, name: "\(name) Motion Trigger", subtype: "MotionTrigger") : nil
        let doorbell = camera.doorbell ? Service(.doorbell, name: "\(name) Doorbell") : nil
        let doorbellSwitch = camera.doorbell && camera.switches ? Service(.switch, name: "\(name) Doorbell Trigger", subtype: "DoorbellTrigger") : nil
        // Nothing is pressed between rings.
        doorbell?.characteristic(.programmableSwitchEvent).onRead { .null }
        let triggers = CameraTriggers(
            log: log, motionTimeout: camera.motionTimeout, motionDoorbell: camera.motionDoorbell, timeScale: dependencies.timeScale,
            motionSensor: motionSensor, motionSwitch: motionSwitch, doorbell: doorbell, doorbellSwitch: doorbellSwitch)
        motionSwitch?.characteristic(.on).onWrite { value in
            await triggers.motion(value.boolValue ?? false, minimumTimeout: 1)
        }
        doorbellSwitch?.characteristic(.on).onWrite { value in
            await triggers.doorbell(value.boolValue ?? false)
        }

        let streamer = CameraStreamer(video: video, log: log, tools: tools, ports: dependencies.ports, timeScale: dependencies.timeScale)
        let recorder = CameraRecorder(video: video, log: log, tools: tools, prebuffer: video.prebuffer ? Prebuffer(video: video, log: log, tools: tools) : nil)
        let streaming = CameraStreamingOptions(
            supportedCryptoSuites: [.aesCM128HMACSHA1_80],
            video: VideoStreamingOptions(
                codec: H264CodecParameters(profiles: [.baseline, .main, .high], levels: [.level3_1, .level3_2, .level4_0]), resolutions: Self.resolutions),
            audio: AudioStreamingOptions(codecs: [AudioStreamingCodec(type: .aacELD, samplerate: [.khz16])], twoWayAudio: video.returnAudioTarget != nil))
        let controller = try CameraController(
            CameraControllerOptions(
                cameraStreamCount: video.maxStreams, delegate: streamer, streamingOptions: streaming,
                recording: video.recording ? CameraRecordingSetup(options: CameraRecorder.options(resolutions: Self.resolutions), delegate: recorder) : nil),
            logger: logger)
        await streamer.attach(controller)

        let accessory = Accessory(
            id: Self.accessoryID(name: name), name: name, manufacturer: camera.manufacturer, model: camera.model, serialNumber: camera.serialNumber,
            firmwareRevision: camera.firmwareRevision, category: camera.doorbell ? .videoDoorbell : .ipCamera,
            services: [motionSensor, motionSwitch, doorbell, doorbellSwitch].compactMap { $0 })
        // Identify is only logged: the plugin cannot make a camera show itself.
        accessory.information.characteristic(.identify).onWrite { _ in log.info("Identify requested.") }
        accessory.configureController(controller)
        context.configureController(controller, accessoryID: accessory.id)
        log.info("Configuring new accessory.")
        try await context.publishExternal(accessory)
        return CameraRuntime(accessory: accessory, controller: controller, streamer: streamer, recorder: recorder, triggers: triggers)
    }

}
