import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A Tuya camera's (`sp`) video on an accessory of its own (docs/clean-room/TuyaCamera.md): live streams and snapshots
/// from an RTSP URL the cloud allocates for each use, and a Motion Sensor and Doorbell that follow the bridged
/// accessory's, so HomeKit's notifications carry a picture. The bridged doorbell, motion sensor and floodlight stay where
/// they are: homes keep their rooms and automations.
actor TuyaCamera {
    /// The camera's timers; tests shorten them.
    struct Timing: Sendable {
        var scale: Double = 1

        func duration(_ seconds: Double) -> Duration { .milliseconds(Int((seconds * 1000 * scale).rounded())) }
    }

    /// One frame of an RTSP URL as a JPEG, nil when FFmpeg gave none; tests swap it for a fake.
    typealias FrameGrabber = @Sendable (RTSPCameraFFmpeg, String) async -> Data?

    /// How long a snapshot answers the requests that follow (section 7): each one costs an allocation and an RTSP connection.
    static let snapshotWindow: Double = 10
    /// After Tuya refuses an allocation for the subscription or its quota, none is asked for this long (section 9).
    static let refusalBackoff: Double = 300
    /// The codes of an expired or missing API subscription (section 9).
    static let subscriptionCodes: Set<Int> = [28841002, 28841101, 28841105]
    /// FFmpeg reads the cloud's stream over TCP and gives up after 10 seconds of silence (section 8).
    static let options = RTSPCameraOptions(analyzeDuration: 5_000_000, probeSize: 5_000_000, rtspOverTCP: true, socketTimeout: 10_000_000)
    /// A stream ends after 30 seconds without HomeKit's reports at the least, whatever RTCP interval it asked (section 5.2).
    static let minimumInactivity: Duration = .seconds(30)

    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    nonisolated let accessoryID: String
    nonisolated let name: String
    nonisolated let motion: Service
    private let device: TuyaDevice
    private let api: TuyaOpenAPI
    private let ffmpeg: RTSPCameraFFmpeg
    private let grabFrame: FrameGrabber
    private let timing: Timing
    private let log: Logger
    private var controller: CameraController?
    private var streamer: RTSPCameraStreamer?
    private var recorder: RTSPCameraRecorder?
    private var snapshot: (data: Data, at: ContinuousClock.Instant)?
    private var fetching: Task<Data, any Error>?
    private var refusedUntil: ContinuousClock.Instant?
    /// The bridged characteristics this camera follows, and its observers' tokens.
    private let observers = NIOLockedValueBox<[(Characteristic, Int)]>([])

    init(accessoryID: String, device: TuyaDevice, api: TuyaOpenAPI, ffmpeg: RTSPCameraFFmpeg, grabFrame: @escaping FrameGrabber, timing: Timing, log: Logger) {
        self.accessoryID = accessoryID
        self.name = device.name
        self.device = device
        self.api = api
        self.ffmpeg = ffmpeg
        self.grabFrame = grabFrame
        self.timing = timing
        self.log = log
        motion = Service(.motionSensor, name: device.name, optional: [.statusActive])
        motion.characteristic(.statusActive).value = .bool(device.online)
    }

    func attach(controller: CameraController, streamer: RTSPCameraStreamer, recorder: RTSPCameraRecorder?) {
        self.controller = controller
        self.streamer = streamer
        self.recorder = recorder
    }

    /// The camera's Motion Sensor follows the bridged one, its Doorbell rings when the bridged one does, and its Status
    /// Active follows the device's online state.
    nonisolated func follow(bridged accessory: Accessory, doorbell: DoorbellController?) {
        let motionDetected = motion.characteristic(.motionDetected), statusActive = motion.characteristic(.statusActive)
        var tokens: [(Characteristic, Int)] = []
        func mirror(_ source: Characteristic?, to target: Characteristic) {
            guard let source else { return }
            target.value = source.value
            tokens.append((source, source.observe { change in
                if target.value != change.newValue { target.value = change.newValue }
            }))
        }
        mirror(accessory.services.first { $0.type.uuid == ServiceType.motionSensor.uuid }?[.motionDetected], to: motionDetected)
        mirror(accessory.information[.statusActive], to: statusActive)
        if let doorbell, let press = accessory.services.first(where: { $0.type.uuid == ServiceType.doorbell.uuid })?[.programmableSwitchEvent] {
            tokens.append((press, press.observe { [weak doorbell] change in
                if change.reason == .event { doorbell?.ringDoorbell() }
            }))
        }
        observers.withLockedValue { $0 += tokens }
    }

    // MARK: Allocation

    /// A fresh RTSP URL from the cloud (section 3): never for an offline device, nor while Tuya's last refusal of the
    /// subscription holds. The URL carries a credential: it is never logged.
    func allocate() async throws -> String {
        guard device.online else { throw Unavailable(description: "\(name) is offline") }
        if let refusedUntil, ContinuousClock.now < refusedUntil {
            throw Unavailable(description: "\(name): Tuya refused the last stream, no other is asked for a few minutes")
        }
        do {
            let url = try await api.streamURL(device.id)
            refusedUntil = nil
            return url
        } catch let error as TuyaAPIError where Self.subscriptionCodes.contains(error.code) {
            refusedUntil = .now + timing.duration(Self.refusalBackoff)
            log.error("\(name): Tuya gives no video stream: \(error). Authorize IoT Video Live Stream on the cloud project, and check its quota; no stream is asked for the next 5 minutes")
            throw error
        } catch {
            log.warning("\(name): Tuya gives no video stream: \(error)")
            throw error
        }
    }

    /// A stream's or a recording's source: a URL allocated for it alone (section 6), nothing to release.
    func source() async throws -> RTSPSource {
        RTSPSource(url: try await allocate())
    }

    // MARK: Snapshots

    /// The picture HomeKit asks for (section 7): a frame of a freshly allocated stream, kept `snapshotWindow`; requests while
    /// one is fetched share it. An offline device is refused without a cloud call.
    func snapshotImage() async throws -> Data {
        guard device.online else { throw Unavailable(description: "\(name) is offline") }
        if let snapshot, ContinuousClock.now - snapshot.at < timing.duration(Self.snapshotWindow) { return snapshot.data }
        if let fetching { return try await fetching.value }
        let task = Task { try await self.fetchSnapshot() }
        fetching = task
        defer { fetching = nil }
        return try await task.value
    }

    private func fetchSnapshot() async throws -> Data {
        let url = try await allocate()
        guard let image = await grabFrame(ffmpeg, url) else {
            log.warning("\(name): FFmpeg gave no snapshot of the stream")
            throw Unavailable(description: "\(name): no snapshot")
        }
        snapshot = (image, .now)
        return image
    }

    /// One JPEG frame through FFmpeg, killed after 15 seconds (HomeKit waits about 20).
    static func ffmpegFrame(_ ffmpeg: RTSPCameraFFmpeg, _ url: String) async -> Data? {
        await ffmpeg.frame(url: url, options: options, logErrors: true)
    }

    func shutdown() async {
        let followed = observers.withLockedValue { observers in
            defer { observers = [] }
            return observers
        }
        for (characteristic, token) in followed { characteristic.removeObserver(token) }
        fetching?.cancel()
        await streamer?.stopAll()
        recorder?.shutdown()
        controller?.destroy()
    }
}
