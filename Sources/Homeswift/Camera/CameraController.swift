import Foundation
import Logging
import NIOConcurrencyHelpers

/// HomeKit Secure Video settings of a camera: what it can record and who serves the recordings.
public struct CameraRecordingSetup: Sendable {
    public var options: CameraRecordingOptions
    public var delegate: any CameraRecordingDelegate

    public init(options: CameraRecordingOptions, delegate: any CameraRecordingDelegate) {
        self.options = options
        self.delegate = delegate
    }
}

/// A sensor of the camera: one the controller creates, or a service of the plugin (HAP-NodeJS: `true` or a Service).
public enum CameraSensor: Sendable {
    case create
    case service(Service)
}

public struct CameraSensorOptions: Sendable {
    /// A motion sensor; with recording, motion triggers recordings.
    public var motion: CameraSensor?
    public var occupancy: CameraSensor?

    public init(motion: CameraSensor? = nil, occupancy: CameraSensor? = nil) {
        self.motion = motion
        self.occupancy = occupancy
    }
}

/// HAP-NodeJS's `CameraControllerOptions`.
public struct CameraControllerOptions: Sendable {
    /// How many streams can run at once (one RTP Stream Management service each). HomeKit wants at least two for
    /// live view; HomeKit Secure Video uses one more.
    public var cameraStreamCount: Int
    public var delegate: any CameraStreamingDelegate
    public var streamingOptions: CameraStreamingOptions
    /// HomeKit Secure Video; leave nil when the camera cannot record.
    public var recording: CameraRecordingSetup?
    public var sensors: CameraSensorOptions?

    public init(
        cameraStreamCount: Int = 1, delegate: any CameraStreamingDelegate, streamingOptions: CameraStreamingOptions, recording: CameraRecordingSetup? = nil,
        sensors: CameraSensorOptions? = nil
    ) {
        self.cameraStreamCount = cameraStreamCount
        self.delegate = delegate
        self.streamingOptions = streamingOptions
        self.recording = recording
        self.sensors = sensors
    }
}

/// A camera, as HAP-NodeJS's `CameraController`: live streams (RTP Stream Management), snapshots (HAP's
/// `POST /resource`), a microphone and speaker, and HomeKit Secure Video when `recording` is given.
///
/// ```swift
/// let camera = try CameraController(CameraControllerOptions(cameraStreamCount: 2, delegate: streaming, streamingOptions: ...))
/// let accessory = Accessory(id: "Protect:\(mac)", name: name, category: .ipCamera, services: [motion])
/// accessory.configureController(camera)                        // adds the services, serves snapshots
/// context.configureController(camera, accessoryID: accessory.id)  // keeps the recording settings
/// try await context.publishExternal(accessory)                 // HomeKit wants cameras on their own server
/// ```
public class CameraController: SerializableController, @unchecked Sendable {
    public let options: CameraControllerOptions
    let logger: Logger
    let streamManagements: [RTPStreamManagement]
    let recordingManagement: RecordingManagement?
    /// When a slow snapshot is logged, and when the request gives up (8 and 25 seconds, as HAP-NodeJS).
    let snapshotTimeouts: (warning: Duration, total: Duration)

    public let microphoneService: Service?
    public let speakerService: Service?
    /// The sensors the controller created (`.create`), or the services the plugin gave.
    public let motionService: Service?
    public let occupancyService: Service?
    private let createdSensors: [Service]

    private enum AudioEndpoint { case microphone, speaker }

    /// The microphone's or the speaker's mute and volume, and who hears of HomeKit's changes.
    private struct AudioEndpointState {
        var muted = false
        var volume = 100
        var onChange: (@Sendable (_ muted: Bool, _ volume: Int) -> Void)?
    }

    private struct State {
        var microphone = AudioEndpointState()
        var speaker = AudioEndpointState()
        var stateChangeDelegate: (@Sendable () -> Void)?

        subscript(endpoint: AudioEndpoint) -> AudioEndpointState {
            get { endpoint == .speaker ? speaker : microphone }
            set { if endpoint == .speaker { speaker = newValue } else { microphone = newValue } }
        }
    }

    private let state = NIOLockedValueBox(State())

    /// Builds the services. Throws when the options cannot be described to HomeKit (no resolution, an audio codec
    /// without sample rate).
    public convenience init(_ options: CameraControllerOptions, logger: Logger = Logger(label: "homeswift.camera")) throws {
        try self.init(options, extraEventTriggers: [], logger: logger)
    }

    init(
        _ options: CameraControllerOptions, extraEventTriggers: Set<EventTriggerOption>, logger: Logger,
        snapshotTimeouts: (warning: Duration, total: Duration) = (.seconds(8), .seconds(25))
    ) throws {
        self.options = options
        self.logger = logger
        self.snapshotTimeouts = snapshotTimeouts
        let count = max(1, options.cameraStreamCount)

        var recordingManagement: RecordingManagement?
        if let recording = options.recording {
            var triggers = extraEventTriggers.union(recording.options.overrideEventTriggerOptions)
            if options.sensors?.motion != nil { triggers.insert(.motion) }
            recordingManagement = try RecordingManagement(options: recording.options, delegate: recording.delegate, eventTriggerOptions: triggers, logger: logger)
        }
        self.recordingManagement = recordingManagement
        let operatingMode = recordingManagement?.operatingModeService
        let disabled: @Sendable () -> Bool = {
            guard let operatingMode else { return false }
            return (operatingMode[.homeKitCameraActive]?.value.intValue ?? 1) == 0
        }
        streamManagements = try (0..<count).map { id in
            try RTPStreamManagement(id: id, options: options.streamingOptions, delegate: options.delegate, logger: logger, disabledThroughOperatingMode: disabled)
        }

        if let audio = options.streamingOptions.audio {
            let microphone = Service(.microphone, optional: [.volume])
            microphone.characteristic(.volume).set(.int(100), notify: false)
            microphoneService = microphone
            if audio.twoWayAudio {
                let speaker = Service(.speaker, optional: [.volume])
                speaker.characteristic(.volume).set(.int(100), notify: false)
                speakerService = speaker
            } else {
                speakerService = nil
            }
        } else {
            microphoneService = nil
            speakerService = nil
        }

        var created: [Service] = []
        func sensor(_ option: CameraSensor?, _ type: ServiceType) -> Service? {
            guard let option else { return nil }
            let service: Service
            switch option {
            case .create:
                service = Service(type, optional: [.statusActive])
                created.append(service)
            case .service(let given):
                service = given
                service.characteristic(adding: .statusActive)
            }
            service.characteristic(.statusActive).value = .bool(true)
            if let recordingManagement {
                recordingManagement.recordingManagementService.linked.append(service)
                recordingManagement.addSensorService(service)
            }
            return service
        }
        motionService = sensor(options.sensors?.motion, .motionSensor)
        occupancyService = sensor(options.sensors?.occupancy, .occupancySensor)
        createdSensors = created
        configureServices()
    }

    /// The services to put on the accessory; `Accessory.configureController(_:)` adds them.
    public var services: [Service] {
        var services: [Service] = streamManagements.map(\.service)
        if let microphoneService { services.append(microphoneService) }
        if let speakerService { services.append(speakerService) }
        if let recordingManagement {
            services += [recordingManagement.recordingManagementService, recordingManagement.operatingModeService, recordingManagement.dataStreamManagement.service]
        }
        return services + createdSensors
    }

    /// The RTP Stream Management services, one per stream.
    public var streamManagementServices: [Service] { streamManagements.map(\.service) }

    private func configureServices() {
        func bind(_ service: Service?, _ endpoint: AudioEndpoint) {
            guard let service else { return }
            service.characteristic(.mute)
                .onRead { [weak self] in .bool(self?.state.withLockedValue { $0[endpoint].muted } ?? false) }
                .onWrite { [weak self] value in self?.changed(endpoint) { $0.muted = value.boolValue ?? false } }
            service.characteristic(.volume)
                .onRead { [weak self] in .int(self?.state.withLockedValue { $0[endpoint].volume } ?? 100) }
                .onWrite { [weak self] value in self?.changed(endpoint) { $0.volume = value.intValue ?? 100 } }
        }
        bind(microphoneService, .microphone)
        bind(speakerService, .speaker)
    }

    /// A random RTP synchronisation source, as HAP-NodeJS makes them (the top byte zero).
    public static func generateSynchronisationSource() -> UInt32 {
        UInt32.random(in: 0...UInt32.max) & 0x00FF_FFFF
    }

    /// Ends the streaming session with this id (the stream died on the camera's side), so the stream can be used again.
    public func forceStopStreamingSession(_ sessionID: String) {
        for management in streamManagements where management.sessionIdentifier == sessionID {
            management.forceStop()
        }
    }

    // MARK: Microphone and speaker

    public func setMicrophoneMuted(_ muted: Bool = true) { set(.microphone, muted: muted) }
    public func setMicrophoneVolume(_ volume: Int) { set(.microphone, volume: volume) }
    public func setSpeakerMuted(_ muted: Bool = true) { set(.speaker, muted: muted) }
    public func setSpeakerVolume(_ volume: Int) { set(.speaker, volume: volume) }

    /// HomeKit changed the microphone's mute or volume (`microphone-change`).
    public func onMicrophoneChange(_ handler: (@Sendable (_ muted: Bool, _ volume: Int) -> Void)?) {
        state.withLockedValue { $0.microphone.onChange = handler }
    }

    /// HomeKit changed the speaker's mute or volume (`speaker-change`).
    public func onSpeakerChange(_ handler: (@Sendable (_ muted: Bool, _ volume: Int) -> Void)?) {
        state.withLockedValue { $0.speaker.onChange = handler }
    }

    private func service(_ endpoint: AudioEndpoint) -> Service? { endpoint == .speaker ? speakerService : microphoneService }

    /// The plugin sets a value: the characteristic follows, the change handler is not called.
    private func set(_ endpoint: AudioEndpoint, muted: Bool? = nil, volume: Int? = nil) {
        guard let service = service(endpoint) else { return }
        state.withLockedValue { state in
            if let muted { state[endpoint].muted = muted }
            if let volume { state[endpoint].volume = volume }
        }
        if let muted { service.characteristic(.mute).value = .bool(muted) }
        if let volume { service.characteristic(.volume).value = .int(volume) }
    }

    /// HomeKit wrote a value: the change handler hears of it.
    private func changed(_ endpoint: AudioEndpoint, _ change: (inout AudioEndpointState) -> Void) {
        let current = state.withLockedValue { state in
            change(&state[endpoint])
            return state[endpoint]
        }
        current.onChange?(current.muted, current.volume)
    }

    // MARK: Snapshots

    /// Answers a snapshot request from HomeKit: refused while streaming or the HomeKit camera is off, or for a
    /// reason whose snapshots are turned off; times out after 25 seconds, as HAP-NodeJS.
    public func handleSnapshotRequest(height: Int, width: Int, accessoryName: String = "", reason: ResourceRequestReason? = nil) async throws -> Data {
        let streamingDisabled = streamManagements.allSatisfy { ($0.service[.active]?.value.intValue ?? 1) == 0 }
        if streamingDisabled {
            logger.debug("Rejecting snapshot as streaming is disabled", metadata: ["accessory": "\(accessoryName)"])
            throw HAPStatusError(.notAllowedInCurrentState)
        }
        if let operatingMode = recordingManagement?.operatingModeService {
            func flag(_ type: CharacteristicType) -> Bool { (operatingMode[type]?.value.intValue ?? 1) != 0 }
            if !flag(.homeKitCameraActive) {
                logger.debug("Rejecting snapshot as the HomeKit camera is disabled", metadata: ["accessory": "\(accessoryName)"])
                throw HAPStatusError(.notAllowedInCurrentState)
            }
            if !flag(.eventSnapshotsActive) {
                if reason == nil { throw HAPStatusError(.insufficientPrivileges) }
                if reason == .event { throw HAPStatusError(.notAllowedInCurrentState) }
            }
            if !flag(.periodicSnapshotsActive) {
                if reason == nil { throw HAPStatusError(.insufficientPrivileges) }
                if reason == .periodic { throw HAPStatusError(.notAllowedInCurrentState) }
            }
        }

        let delegate = options.delegate
        let request = SnapshotRequest(height: height, width: width, reason: reason)
        let logger = logger
        let (warning, total) = snapshotTimeouts
        // Not a task group: a group waits for all its children, so a delegate that ignores cancellation would hold
        // the request past the timeout. The loser is cancelled and left to finish on its own.
        let first: Data? = try await Self.first(
            {
                do {
                    return try await delegate.handleSnapshotRequest(request)
                } catch let error as HAPStatusError {
                    throw error
                } catch {
                    logger.debug("Error getting snapshot", metadata: ["accessory": "\(accessoryName)", "error": "\(error)"])
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
            },
            {
                try await Task.sleep(for: warning)
                logger.warning("The image snapshot handler is slow to respond", metadata: ["accessory": "\(accessoryName)"])
                try await Task.sleep(for: total - warning)
                logger.warning("The image snapshot handler didn't respond at all", metadata: ["accessory": "\(accessoryName)"])
                return nil
            })
        guard let image = first else { throw HAPStatusError(.operationTimedOut) }
        guard !image.isEmpty else {
            logger.warning("Snapshot request handler provided an empty image", metadata: ["accessory": "\(accessoryName)"])
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        return image
    }

    /// Whether the camera is on in the Home app (HomeKit Camera Active of Camera Operating Mode). A camera without
    /// HomeKit Secure Video has no such switch and is always on.
    public var isHomeKitCameraActive: Bool {
        (recordingManagement?.operatingModeService[.homeKitCameraActive]?.value.intValue ?? 1) != 0
    }

    /// A snapshot for the bridge's own pages (the web UI's camera cards): the delegate's image, or
    /// `operationTimedOut` after `timeout`. Refused, as HomeKit's requests are, while the camera is off in the Home
    /// app; the settings of HomeKit's event and periodic snapshots do not apply.
    public func previewSnapshot(width: Int, height: Int, timeout: Duration = .seconds(10)) async throws -> Data {
        guard isHomeKitCameraActive else { throw HAPStatusError(.notAllowedInCurrentState) }
        let delegate = options.delegate
        let request = SnapshotRequest(height: height, width: width, reason: nil)
        let first: Data? = try await Self.first(
            { try await delegate.handleSnapshotRequest(request) },
            {
                try await Task.sleep(for: timeout)
                return nil
            })
        guard let image = first else { throw HAPStatusError(.operationTimedOut) }
        guard !image.isEmpty else { throw HAPStatusError(.serviceCommunicationFailure) }
        return image
    }

    /// The result of whichever operation finishes first, in unstructured tasks: returns then even when the other
    /// ignores cancellation (it is cancelled). Cancelling the caller throws `CancellationError` at once.
    static func first<T: Sendable>(_ operations: (@Sendable () async throws -> T)...) async throws -> T {
        let race = FirstResult<T>()
        let tasks = operations.map { operation in
            Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            }
        }
        defer { for task in tasks { task.cancel() } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.wait($0) }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    // MARK: SerializableController

    public var controllerID: String { "camera" }

    struct Serialized: Codable {
        var streamManagements: [RTPStreamManagement.Serialized]
        var recordingManagement: RecordingManagement.Serialized?
    }

    public func serialize() -> Data? {
        try? JSONEncoder().encode(Serialized(streamManagements: streamManagements.compactMap { $0.serialize() }, recordingManagement: recordingManagement?.serialize()))
    }

    public func deserialize(_ data: Data) throws {
        let serialized = try JSONDecoder().decode(Serialized.self, from: data)
        for saved in serialized.streamManagements where streamManagements.indices.contains(saved.id) {
            streamManagements[saved.id].deserialize(saved)
        }
        if let recording = serialized.recordingManagement {
            if let recordingManagement {
                recordingManagement.deserialize(recording)
            } else {
                // Recording was turned off: streaming must not stay disabled by an old setting.
                for management in streamManagements { management.service.characteristic(.active).value = .bool(true) }
                state.withLockedValue { $0.stateChangeDelegate }?()
            }
        }
    }

    public func setupStateChangeDelegate(_ delegate: (@Sendable () -> Void)?) {
        state.withLockedValue { $0.stateChangeDelegate = delegate }
        for management in streamManagements { management.setupStateChangeDelegate(delegate) }
        recordingManagement?.setupStateChangeDelegate(delegate)
    }

    /// Stops the streams and the data stream server, when the accessory goes away.
    public func destroy() {
        for management in streamManagements { management.destroy() }
        recordingManagement?.destroy()
    }

    /// The recording configuration HomeKit selected, if any.
    public var recordingConfiguration: CameraRecordingConfiguration? { recordingManagement?.selectedConfiguration }
    /// Whether recording is on in the Home app.
    public var isRecordingActive: Bool { recordingManagement?.recordingActive ?? false }
}

/// The first result of a race, handed to the one waiter.
private final class FirstResult<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, any Error>?
        var continuation: CheckedContinuation<T, any Error>?
    }

    private let state = NIOLockedValueBox(State())

    func wait(_ continuation: CheckedContinuation<T, any Error>) {
        let result = state.withLockedValue { state -> Result<T, any Error>? in
            if state.result == nil { state.continuation = continuation }
            return state.result
        }
        if let result { continuation.resume(with: result) }
    }

    /// Only the first result counts.
    func finish(_ result: Result<T, any Error>) {
        let continuation = state.withLockedValue { state -> CheckedContinuation<T, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

/// A video doorbell (HAP-NodeJS's `DoorbellController`): a camera with a Doorbell service as its primary service.
public final class DoorbellController: CameraController, @unchecked Sendable {
    public let doorbellService: Service
    private let ownsDoorbellService: Bool

    /// `externalDoorbellService` uses a Doorbell service of the plugin instead of creating one; make it primary.
    public init(
        _ options: CameraControllerOptions, name: String? = nil, externalDoorbellService: Service? = nil,
        logger: Logger = Logger(label: "homeswift.camera")
    ) throws {
        if let externalDoorbellService {
            doorbellService = externalDoorbellService
            ownsDoorbellService = false
        } else {
            doorbellService = Service(.doorbell, name: name, isPrimary: true)
            ownsDoorbellService = true
        }
        try super.init(options, extraEventTriggers: [.doorbell], logger: logger)
        // Nothing is pressed between rings.
        doorbellService.characteristic(.programmableSwitchEvent).onRead { .null }
    }

    /// Rings: a single press event to every subscribed controller.
    public func ringDoorbell() {
        doorbellService.characteristic(.programmableSwitchEvent).sendEvent(.int(HAPConstants.ProgrammableSwitchEvent.singlePress))
    }

    public override var services: [Service] {
        (ownsDoorbellService ? [doorbellService] : []) + super.services
    }
}

extension Accessory {
    /// Adds a camera's services to the accessory and answers HomeKit's snapshot requests with it, as Homebridge's
    /// `accessory.configureController(cameraController)`. Call it before the accessory goes on a server.
    public func configureController(_ controller: CameraController) {
        for service in controller.services { append(service) }
        cameraControllerBox.withLockedValue { $0 = controller }
    }

    /// The camera configured on this accessory.
    public var cameraController: CameraController? { cameraControllerBox.withLockedValue { $0 } }
}
