import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A Tapo battery camera's kind, from its `type`: `Camera` (one lens) or `DualLensCamera` (a C675D: wide and tele).
enum TapoCameraKind: String, Sendable, Equatable {
    case single = "camera"
    case dualLens = "duallenscamera"

    init?(type: String?) {
        guard let type = type?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        self.init(rawValue: type)
    }

    var model: String {
        switch self {
        case .single: "Tapo Camera"
        case .dualLens: "Tapo C675D"
        }
    }
}

/// One lens of a camera, as an accessory of its own.
struct TapoLens: Sendable, Equatable {
    /// The lens's video stream in the feed's MPEG-TS.
    var videoIndex: Int
    /// The accessory id's suffix (none for the first lens) and the name's.
    var suffix: String?

    /// The lenses a camera shows at `resolution` (docs/clean-room/TapoCamera.md, 7): both of a C675D in HD (the first
    /// video stream the wide lens, the second the tele lens); in VGA one stream, the tele lens's.
    static func lenses(kind: TapoCameraKind, resolution: Streamd.Resolution) -> [TapoLens] {
        switch (kind, resolution) {
        case (.dualLens, .hd): [TapoLens(videoIndex: 0, suffix: nil), TapoLens(videoIndex: 1, suffix: "Tele")]
        default: [TapoLens(videoIndex: 0, suffix: nil)]
        }
    }
}

/// One lens as a camera accessory, on the bridge or on a HAP server of its own (`standalone`): live video, the last
/// snapshot, and a Motion Sensor fed by the TP-Link cloud's notifications (nothing local reports motion without keeping
/// the camera awake, TapoCamera.md 12.3); no HomeKit Secure Video, which would open the camera's stream on every detection.
final class TapoCamera: Sendable {
    /// The sizes HomeKit may ask for.
    static let resolutions: [VideoResolution] = [
        VideoResolution(320, 180, 15), VideoResolution(320, 240, 15), VideoResolution(480, 270, 15), VideoResolution(480, 360, 15),
        VideoResolution(640, 360, 15), VideoResolution(640, 480, 15), VideoResolution(1280, 720, 15), VideoResolution(1280, 960, 15),
        VideoResolution(1920, 1080, 15),
    ]

    /// The lens's accessory: rebuilt, with the same services and camera, when its pan and tilt switches change.
    var accessory: Accessory { accessoryBox.withLockedValue { $0 } }
    private let accessoryBox: NIOLockedValueBox<Accessory>
    /// The switches it has now (TapoPTZSwitches.swift).
    var ptzSwitches: TapoPTZSwitches { switchesBox.withLockedValue { $0 } }
    private let switchesBox = NIOLockedValueBox(TapoPTZSwitches())
    /// The patrol switches, while it has them, so the camera's sleep turns them off.
    let patrolServices = NIOLockedValueBox<[Service]>([])
    private let id: String
    private let name: String
    private let log: Logger
    let controller: CameraController
    let streamer: TapoCameraStreamer
    let motion: Service?
    /// The camera's battery (TapoBattery.swift).
    let battery: Service?
    private let hold: Duration
    private let reset = NIOLockedValueBox<Task<Void, Never>?>(nil)

    init(id: String, name: String, model: String, serial: String, streamer: TapoCameraStreamer, motion hasMotion: Bool, battery hasBattery: Bool = true,
         hold: Duration, log: Logger) throws {
        self.streamer = streamer
        self.hold = hold
        self.id = id
        self.name = name
        self.log = log
        let motion = hasMotion ? Service(.motionSensor, name: "\(name) Motion", subtype: "motion") : nil
        self.motion = motion
        let battery = hasBattery ? Self.batteryService(name: name) : nil
        self.battery = battery
        let streaming = CameraStreamingOptions(
            supportedCryptoSuites: [.aesCM128HMACSHA1_80],
            video: VideoStreamingOptions(codec: H264CodecParameters(profiles: [.baseline, .main, .high], levels: [.level3_1, .level3_2, .level4_0]),
                                         resolutions: Self.resolutions),
            audio: AudioStreamingOptions(codecs: [AudioStreamingCodec(type: .aacELD, samplerate: [.khz16])], twoWayAudio: false))
        controller = try CameraController(
            CameraControllerOptions(cameraStreamCount: 2, delegate: streamer, streamingOptions: streaming, sensors: motion.map { CameraSensorOptions(motion: .service($0)) }),
            logger: log)
        let accessory = Accessory(
            id: id, name: name, manufacturer: "TP-Link", model: model, serialNumber: serial, category: .ipCamera, services: [motion, battery].compactMap { $0 },
            onIdentify: { [log] in log.info("\(name): identify requested.") })
        accessory.configureController(controller)
        accessoryBox = NIOLockedValueBox(accessory)
        motion?.characteristic(.motionDetected).value = false
    }

    /// A new accessory for the lens with these pan and tilt switches: the same camera, Motion Sensor and Battery (the
    /// same services, so a live view goes on), the same Accessory Information, under the same id. The caller publishes it.
    func rebuild(_ switches: TapoPTZSwitches, actions: TapoPTZActions) -> Accessory {
        let current = accessory
        func info(_ type: CharacteristicType) -> String { current.information[type]?.value.stringValue ?? "" }
        let services = switches.services(name: name, actions: actions, log: log)
        let accessory = Accessory(
            id: id, name: info(.name).nonEmpty ?? name, manufacturer: "TP-Link", model: info(.model), serialNumber: info(.serialNumber),
            firmwareRevision: info(.firmwareRevision).nonEmpty ?? "1.0.0", category: .ipCamera,
            services: [motion, battery].compactMap { $0 } + services.presets + services.patrols,
            onIdentify: { [log, name] in log.info("\(name): identify requested.") })
        accessory.configureController(controller)
        accessoryBox.withLockedValue { $0 = accessory }
        switchesBox.withLockedValue { $0 = switches }
        patrolServices.withLockedValue { $0 = services.patrols }
        return accessory
    }

    /// Whether one of its patrol switches is on.
    var isPatrolling: Bool { patrolServices.withLockedValue { $0 }.contains { $0[.on]?.value == .bool(true) } }

    /// The camera went back to sleep, or moved elsewhere: its patrol stopped.
    func patrolStopped() {
        for service in patrolServices.withLockedValue({ $0 }) { service.characteristic(.on).value = false }
    }

    /// Accessory Information from the camera the TP-Link cloud knows (its device list, which never reaches the camera):
    /// the MAC as the serial number, with `-<lens>` on a camera of several lenses (they are one device), its model and
    /// its firmware. Display only: HomeKit pairs with the accessory's own identity, which stays.
    func identify(as device: TapoCloud.Device, lens: String?) {
        if !device.mac.isEmpty {
            accessory.information.characteristic(.serialNumber).value = .string(device.mac + (lens.map { "-\($0.lowercased())" } ?? ""))
        }
        if !device.model.isEmpty { accessory.information.characteristic(.model).value = .string(device.model) }
        if !device.firmware.isEmpty { accessory.information.characteristic(.firmwareRevision).value = .string(device.firmware) }
    }

    /// A detection: Motion Detected for `hold`, longer if another one comes.
    func motionDetected() {
        guard let motion else { return }
        motion.characteristic(.motionDetected).value = true
        let hold = hold
        let task = Task {
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            motion.characteristic(.motionDetected).value = false
        }
        reset.withLockedValue { previous in
            previous?.cancel()
            previous = task
        }
    }

    func start() async { await streamer.attach(controller) }

    func stop() async {
        reset.withLockedValue { $0?.cancel() }
        await streamer.stopAll()
        controller.destroy()
    }
}

/// A camera's feed and its lenses' accessories.
struct TapoCameraRuntime: Sendable {
    var feed: TapoCameraFeed
    var cameras: [TapoCamera]
    /// The camera's control API, for pan and tilt (TapoControl).
    var control: TapoControl? = nil
    /// The accessory id of the lens on the motor: the tele lens of a C675D, the only lens of another camera.
    var movableLens: String? = nil
    /// On a HAP server of its own (`standalone`), and the switches its options ask for (TapoPTZSwitches.swift).
    var standalone = false
    var presetSwitches = true
    var patrolSwitches = true
}

extension TapoPlugin {
    /// FFmpeg, set up once its codecs are known: the options choose the hardware encoder from them, and HEVC from two
    /// 4K lenses is too much for a software one.
    func cameraFFmpeg() async -> FfmpegOptions {
        if let ffmpegOptions { return ffmpegOptions }
        let codecs = FfmpegCodecs(ffmpegExec: configuration.videoProcessor?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "ffmpeg", log: logger)
        _ = await codecs.probe()
        if let ffmpegOptions { return ffmpegOptions }
        let options = FfmpegOptions(FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: true, log: logger, name: { "Tapo" }))
        ffmpegOptions = options
        return options
    }

    /// The accessory id of a lens: the device's for the first, with `:<suffix>` for the others.
    static func lensAccessoryID(deviceID: String, lens: TapoLens) -> String {
        accessoryID(deviceID: deviceID) + (lens.suffix.map { ":\($0.lowercased())" } ?? "")
    }

    /// Publishes a camera's lenses; the camera itself is reached only when one of them is watched.
    func startCamera(deviceID: String, device: Configuration.Device, kind: TapoCameraKind) async throws -> [String] {
        guard let host = device.trimmedHost else { return [] }
        let name = context.accessorySettings(for: deviceID).name ?? device.trimmedName ?? host
        let resolution = Streamd.Resolution(rawValue: device.resolution?.trimmingCharacters(in: .whitespaces).uppercased() ?? "") ?? .hd
        let ffmpeg = await cameraFFmpeg()
        let lenses = TapoLens.lenses(kind: kind, resolution: resolution)
        var stores: [TapoSnapshotStore] = []
        for lens in lenses {
            let file = context.storageDirectory.appendingPathComponent("tapo-snapshots/\(Self.fileName(Self.lensAccessoryID(deviceID: deviceID, lens: lens))).jpg")
            stores.append(TapoSnapshotStore(file: file))
        }
        let client = StreamdClient(
            host: host, password: { [weak self] in self?.credentials?.password }, connect: dependencies.connect,
            handshakeTimeout: scaled(20), silenceTimeout: scaled(10), logger: logger)
        let snapshotTargets = zip(lenses, stores).map { ($0.videoIndex, $1) }
        let log = logger
        let feed = TapoCameraFeed(name: name, client: client, resolution: resolution, timing: dependencies.cameraTiming, logger: logger,
                                  onAwake: { [weak self] in await self?.cameraAwake(deviceID: deviceID) },
                                  onAsleep: { [weak self] in await self?.cameraAsleep(deviceID: deviceID) }) { sample in
            for (index, store) in snapshotTargets {
                if let image = await TapoCameraStreamer.snapshot(from: sample, videoIndex: index, ffmpeg: ffmpeg) {
                    store.update(image)
                } else {
                    log.debug("\(name): no snapshot from the live view's sample (lens \(index)).")
                }
            }
        }
        var cameras: [TapoCamera] = []
        for (lens, store) in zip(lenses, stores) {
            let id = Self.lensAccessoryID(deviceID: deviceID, lens: lens)
            let lensName = lens.suffix.map { "\(name) \($0)" } ?? name
            let streamer = TapoCameraStreamer(
                name: lensName, videoIndex: lens.videoIndex, feed: feed, snapshots: store, ffmpeg: ffmpeg, ports: dependencies.ports, inputFps: 15, log: logger)
            let camera = try TapoCamera(id: id, name: lensName, model: kind.model, serial: id, streamer: streamer, motion: device.motion ?? true,
                                        hold: dependencies.motionHold, log: logger)
            if let kept = keptBattery(deviceID) { camera.apply(kept) }
            await camera.start()
            cameras.append(camera)
        }
        let control = makeControl(deviceID: deviceID, host: host)
        // The lens on the motor: the tele one when both show, the one shown otherwise (a C675D in VGA shows its tele lens).
        let movable = zip(lenses, cameras).first { $0.0.suffix == "Tele" }?.1 ?? (cameras.count == 1 ? cameras[0] : nil)
        let standalone = device.standalone ?? false
        cameraRuntimes[deviceID] = TapoCameraRuntime(
            feed: feed, cameras: cameras, control: control, movableLens: movable?.accessory.id, standalone: standalone,
            presetSwitches: device.presetSwitches ?? true, patrolSwitches: device.patrolSwitches ?? true)
        // Its pan and tilt switches from what `ptz.json` keeps, before it is published.
        await applyPTZSwitches(deviceID: deviceID, publish: false)
        for camera in cameras {
            if standalone { try await context.publishExternal(camera.accessory) } else { try context.add(camera.accessory) }
        }
        if device.motion ?? true {
            // Each lens's serial: the MAC, with `-wide` or `-tele` when the camera has several.
            let labels = lenses.map { lens in lenses.count > 1 ? lens.suffix ?? "Wide" : nil }
            await motionWatcher.add(TapoMotionWatcher.Camera(
                name: name, cloudID: device.cloudId?.trimmingCharacters(in: .whitespaces).nonEmpty, host: host, model: kind == .dualLens ? "C675D" : nil,
                onMotion: { [weak self, cameras] type in
                    if Self.batteryNotifications.contains(type) {
                        Task { await self?.batteryReportedLow(deviceID: deviceID) }
                    } else {
                        for camera in cameras { camera.motionDetected() }
                    }
                },
                onMatched: { [cameras] found in
                    for (camera, label) in zip(cameras, labels) { camera.identify(as: found, lens: label) }
                }))
        }
        return cameras.map(\.accessory.id)
    }

    func stopCameras() async {
        for runtime in cameraRuntimes.values {
            await runtime.feed.stop()
            for camera in runtime.cameras { await camera.stop() }
        }
        cameraRuntimes.removeAll()
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
