import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A camera, doorbell or display (section 5.3): a motion sensor, HomeKit's camera services (and the doorbell's), the
/// events that drive them, and the event images its snapshots show. Its accessory goes on a server of its own.
final class NestCamera: @unchecked Sendable {
    /// Motion stays detected this long after the last signal.
    static let motionWindow: Duration = .seconds(20)
    /// An event image answers snapshots this long.
    static let imageLifetime: TimeInterval = 10

    /// The sizes HomeKit may ask for (section 5.3).
    static let resolutions: [VideoResolution] = [
        VideoResolution(320, 180, 30), VideoResolution(320, 240, 15), VideoResolution(320, 240, 30), VideoResolution(480, 270, 30),
        VideoResolution(480, 360, 30), VideoResolution(640, 360, 30), VideoResolution(640, 480, 30), VideoResolution(1280, 720, 30),
        VideoResolution(1280, 960, 30), VideoResolution(1920, 1080, 30), VideoResolution(1600, 1200, 30),
    ]
    static let displayResolutions = [VideoResolution(1280, 720, 15), VideoResolution(1920, 1080, 15), VideoResolution(1600, 1200, 15)]

    /// What the camera reaches the world with.
    struct Tools: Sendable {
        var send: Commander
        /// The bytes at a URL: with this Authorization, or the account's Bearer token when nil.
        var download: @Sendable (_ url: URL, _ authorization: String?) async throws -> Data
        var ffmpeg: NestFFmpeg
        var ports: RtpPortAllocator
        var timeScale: Double
        var now: @Sendable () -> Date
    }

    let accessory: Accessory
    let controller: CameraController
    let streamer: NestStreamer
    let recorder: NestRecorder?
    let motion: Service
    let device: SDMDevice
    private let tools: Tools
    private let log: Logger

    private struct State {
        var motionGeneration = 0
        var image: (data: Data, at: Date)?
        var motionTask: Task<Void, Never>?
    }

    private let state = NIOLockedValueBox(State())

    init(device: SDMDevice, options: NestOptions, tools: Tools, log: Logger) throws {
        self.device = device
        self.tools = tools
        self.log = log
        let name = device.displayName
        let kind = device.kind ?? .camera
        let webRTC = device.isWebRTC
        let resource = device.name
        let send = tools.send
        let open: StreamOpener = { try await RTSPStream.open(device: resource, send: send, log: log) }
        let state = state
        let snapshot: @Sendable () async -> Data = {
            let now = tools.now()
            return state.withLockedValue { state in
                guard let image = state.image, now.timeIntervalSince(image.at) < Self.imageLifetime else { return nil }
                return image.data
            } ?? Placeholder.jpeg
        }
        streamer = NestStreamer(name: name, webRTC: webRTC, options: options, ffmpeg: tools.ffmpeg, ports: tools.ports, open: open, snapshot: snapshot,
                                log: log, timeScale: tools.timeScale)
        // A WebRTC device has no live view nor recording here (no WebRTC stack): its motion and doorbell still come.
        recorder = webRTC ? nil : NestRecorder(name: name, options: options, ffmpeg: tools.ffmpeg, open: open, log: log)
        motion = Service(.motionSensor, name: name)
        let resolutions = kind == .display ? Self.displayResolutions : Self.resolutions
        let streaming = CameraStreamingOptions(
            supportedCryptoSuites: [.aesCM128HMACSHA1_80],
            video: VideoStreamingOptions(codec: H264CodecParameters(profiles: [.main], levels: [.level3_1]), resolutions: resolutions),
            audio: AudioStreamingOptions(codecs: [AudioStreamingCodec(type: .aacELD, samplerate: [.khz16])], twoWayAudio: false))
        let controllerOptions = CameraControllerOptions(
            cameraStreamCount: resolutions.count, delegate: streamer, streamingOptions: streaming,
            recording: recorder.map { CameraRecordingSetup(options: NestRecorder.options(resolutions: Self.resolutions), delegate: $0) },
            sensors: CameraSensorOptions(motion: .service(motion)))
        controller = kind == .doorbell ? try DoorbellController(controllerOptions, name: name, logger: log) : try CameraController(controllerOptions, logger: log)
        accessory = Accessory(
            id: GoogleNestSDMPlugin.accessoryID(deviceID: device.name), name: name, manufacturer: "Google Nest", model: kind.suffix, serialNumber: device.shortID,
            category: kind == .doorbell ? .videoDoorbell : .ipCamera, services: [motion], onIdentify: { [log] in log.info("\(name) identified!") })
        accessory.configureController(controller)
        motion.characteristic(.motionDetected).value = false
    }

    func start() async {
        await streamer.attach(controller)
    }

    func stop() async {
        state.withLockedValue { $0.motionTask }?.cancel()
        recorder?.shutdown()
        await streamer.stopAll()
        controller.destroy()
    }

    /// The device events of a Pub/Sub message (section 5.3): stale ones, and those of a thread that did not just start, do
    /// nothing; motion and person signal motion, a chime rings, sound only fetches the image; an RTSP device's image comes
    /// first, a WebRTC device's from its clip preview.
    func handle(_ event: SDMEvent) async {
        guard let events = event.events else { return }
        let now = tools.now()
        if event.isStale(now: now) {
            log.debug("\(device.displayName): camera event is too old (\(Int(now.timeIntervalSince(event.timestamp ?? now))) sec), ignoring.")
            return
        }
        if let thread = event.threadState, thread != "STARTED" { return }
        let webRTC = device.isWebRTC
        // An RTSP device's image comes first, once for a message whose motion and person share their event.
        var fetched: Set<String> = []
        func image(_ value: JSONValue) async {
            guard !webRTC, let id = value["eventId"]?.stringValue, fetched.insert(id).inserted else { return }
            await fetchImage(id)
        }
        for (key, value) in events.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "sdm.devices.events.CameraMotion.Motion", "sdm.devices.events.CameraPerson.Person":
                await image(value)
                signalMotion()
            case "sdm.devices.events.CameraSound.Sound":
                await image(value)
            case "sdm.devices.events.DoorbellChime.Chime":
                guard let doorbell = controller as? DoorbellController else { continue }
                await image(value)
                log.debug("\(device.displayName): doorbell ring!")
                doorbell.ringDoorbell()
            case "sdm.devices.events.CameraClipPreview.ClipPreview":
                if webRTC, let url = value["previewUrl"]?.stringValue.flatMap(URL.init(string:)) { await fetchClipFrame(url) }
            default:
                continue
            }
        }
    }

    /// Motion detected now, and cleared 20 seconds after the last signal.
    func signalMotion() {
        log.debug("\(device.displayName): motion detected!")
        let window = Self.motionWindow * tools.timeScale
        let motion = motion
        let box = state
        box.withLockedValue { current in
            current.motionGeneration += 1
            let generation = current.motionGeneration
            current.motionTask?.cancel()
            current.motionTask = Task {
                try? await Task.sleep(for: window)
                guard !Task.isCancelled, box.withLockedValue({ $0.motionGeneration }) == generation else { return }
                motion.characteristic(.motionDetected).value = false
            }
        }
        motion.characteristic(.motionDetected).value = true
    }

    /// `CameraEventImage.GenerateImage`, then the JPEG with `Authorization: Basic <token>` (section 3.3).
    private func fetchImage(_ eventID: String) async {
        do {
            let results = try await tools.send(device.name, "CameraEventImage.GenerateImage", ["eventId": .string(eventID)])
            guard let url = results["url"]?.stringValue.flatMap(URL.init(string:)), let token = results["token"]?.stringValue else {
                throw NestError.invalidResponse("no image in the answer")
            }
            keep(try await tools.download(url, "Basic \(token)"))
        } catch {
            log.error("\(device.displayName): could not fetch event image: \(error)")
        }
    }

    /// A WebRTC device has no event images: its clip preview (an MP4 of a few frames, Bearer) gives the first frame.
    private func fetchClipFrame(_ url: URL) async {
        do {
            let clip = try await tools.download(url, nil)
            let exec = FfmpegExec(tools.ffmpeg.options, commandLineArgs: FFmpegArguments.clipFrame, logErrors: false)
            guard let frame = await exec.exec(clip, timeout: 10_000)?.stdout, !frame.isEmpty else { throw StreamError("FFmpeg made no image of the clip") }
            keep(frame)
        } catch {
            log.error("\(device.displayName): could not fetch the clip preview: \(error)")
        }
    }

    private func keep(_ image: Data) {
        let now = tools.now()
        state.withLockedValue { $0.image = (image, now) }
    }

    /// The snapshot HomeKit would get now.
    func snapshot() async -> Data {
        (try? await streamer.handleSnapshotRequest(SnapshotRequest(height: 1080, width: 1920))) ?? Placeholder.jpeg
    }
}
