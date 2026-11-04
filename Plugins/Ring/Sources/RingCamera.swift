import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A ding or a motion from a push, for a camera or an intercom (docs/clean-room/Ring.md, 3.6).
struct RingNotification: Sendable, Equatable {
    static let ding = "com.ring.pn.live-event.ding"
    static let motion = "com.ring.pn.live-event.motion"
    static let intercom = "com.ring.pn.live-event.intercom"

    var deviceID: String
    var category: String
    var dingID: String?
    /// The notification's snapshot, everything from the first `:` removed.
    var snapshotUUID: String?
}

/// A camera or doorbell (docs/clean-room/Ring.md, 4.5 and 6): its own HAP server (an external accessory), snapshots
/// from Ring's snapshot service with the original's timing rules, motion and doorbell from pushes, and its light, siren
/// and in-home chime switch. Live video needs WebRTC, which Homeswift has not: a stream request is refused.
final class RingCamera: CameraStreamingDelegate, @unchecked Sendable {
    let id: String
    let name: String
    let isDoorbell: Bool
    private let environment: RingEnvironment
    private let state: NIOLockedValueBox<State>

    private struct ActiveNotification {
        var notification: RingNotification
        var expires: ContinuousClock.Instant
    }

    private struct State {
        var data: JSONValue
        var active: [ActiveNotification] = []
        var motion = false
        var lastDoorbell: ContinuousClock.Instant?
        var lightOverride: (on: Bool, until: ContinuousClock.Instant)?
        // Snapshots
        var cached: Data?
        var cacheGeneration = 0
        var lastSnapshot: Data?
        var cameraTimestamp: Double = 0
        var takenAt: ContinuousClock.Instant?
        /// The request in flight and the event snapshot it asks for (nil: the camera's current image).
        var refreshing: (uuid: String?, task: Task<Data, any Error>)?
    }

    // Services
    private(set) var motionService: Service?
    private(set) var programmableSwitch: Service?
    private(set) var light: Service?
    private(set) var siren: Service?
    private(set) var inHomeDoorbell: Service?
    private(set) var battery: Service?
    private(set) var controller: CameraController?

    init(data: JSONValue, isDoorbell: Bool, environment: RingEnvironment) {
        id = data["id"]?.idString ?? ""
        name = data["description"]?.stringValue ?? "Ring Camera"
        self.isDoorbell = isDoorbell || (data["kind"]?.stringValue ?? "").hasPrefix("doorbell")
        self.environment = environment
        state = NIOLockedValueBox(State(data: data))
    }

    var data: JSONValue { state.withLockedValue { $0.data } }
    var kind: String { data["kind"]?.stringValue ?? "" }

    /// The camera's accessory, with every service its data calls for.
    func makeAccessory() throws -> Accessory {
        let configuration = environment.configuration
        let data = self.data
        let options = CameraControllerOptions(
            cameraStreamCount: 2, delegate: self,
            streamingOptions: CameraStreamingOptions(
                video: VideoStreamingOptions(
                    codec: H264CodecParameters(profiles: [.baseline], levels: [.level3_1]),
                    resolutions: [
                        VideoResolution(1920, 1024, 30), VideoResolution(1280, 720, 30), VideoResolution(1024, 768, 30), VideoResolution(640, 480, 30),
                        VideoResolution(640, 360, 30), VideoResolution(480, 360, 30), VideoResolution(480, 270, 30), VideoResolution(320, 240, 30),
                        VideoResolution(320, 240, 15), VideoResolution(320, 180, 30),
                    ]),
                audio: AudioStreamingOptions(codecs: [AudioStreamingCodec(type: .opus, samplerate: [.khz8, .khz16, .khz24])], twoWayAudio: true)))
        let camera: CameraController = isDoorbell
            ? try DoorbellController(options, name: name, logger: environment.logger)
            : try CameraController(options, logger: environment.logger)
        controller = camera
        var services: [Service] = []
        if configuration.hideCameraMotionSensor != true {
            let motion = Service(.motionSensor, name: name)
            motionService = motion
            services.append(motion)
        }
        if isDoorbell, configuration.hideDoorbellSwitch != true {
            let button = Service(.statelessProgrammableSwitch, name: name, optional: [.programmableSwitchEvent.with(maxValue: 0, validValues: [0])])
            button.characteristic(.programmableSwitchEvent).onRead { .null }
            programmableSwitch = button
            services.append(button)
        }
        if data["led_status"] != nil, configuration.hideCameraLight != true {
            let light = Service(.lightbulb, name: name)
            light.characteristic(.on).onRead { [weak self] in
                self?.environment.requestRefresh()
                return light.characteristic(.on).value
            }
            light.characteristic(.on).onWrite { [weak self] value in self?.setLight(value.boolValue ?? false) }
            self.light = light
            services.append(light)
        }
        if data["siren_status"] != nil, configuration.hideCameraSirenSwitch != true {
            let siren = Service(.switch, name: "\(name) Siren", subtype: "Siren")
            siren.characteristic(.on).onRead { [weak self] in
                self?.environment.requestRefresh()
                return siren.characteristic(.on).value
            }
            siren.characteristic(.on).securityControl().onWrite { [weak self] value in self?.setSiren(value.boolValue ?? false) }
            self.siren = siren
            services.append(siren)
        }
        if isDoorbell, configuration.hideInHomeDoorbellSwitch != true,
           let type = data["settings"]?["chime_settings"]?["type"]?.saturatingIntValue, type == 0 || type == 1 {
            let chime = Service(.switch, name: "\(name) In-Home Doorbell", subtype: "In-Home Doorbell")
            chime.characteristic(.on).onRead { [weak self] in
                self?.environment.requestRefresh()
                return chime.characteristic(.on).value
            }
            chime.characteristic(.on).onWrite { [weak self] value in self?.setInHomeDoorbell(value.boolValue ?? false) }
            inHomeDoorbell = chime
            services.append(chime)
        }
        if RingBattery.rest(data) != nil {
            let battery = Service(.battery, optional: [.batteryLevel, .chargingState])
            self.battery = battery
            services.append(battery)
        }
        let onvif = kind == "onvif_camera"
        let accessory = Accessory(
            id: RingPlugin.accessoryID(seed: "\(id)camera"), name: name,
            manufacturer: onvif ? data["metadata"]?["third_party_manufacturer"]?.stringValue ?? "Ring" : "Ring",
            model: onvif ? data["metadata"]?["third_party_model"]?.stringValue ?? RingModels.camera(kind) : "\(RingModels.camera(kind)) (\(kind))",
            serialNumber: data["device_id"]?.stringValue ?? id, category: isDoorbell ? .videoDoorbell : .ipCamera, services: services)
        accessory.configureController(camera)
        show(data)
        return accessory
    }

    // MARK: State

    /// A poll's data, replacing the last.
    func update(_ data: JSONValue) {
        state.withLockedValue { $0.data = data }
        show(data)
    }

    private func show(_ data: JSONValue) {
        if let light {
            let override = state.withLockedValue { state -> Bool? in
                guard let override = state.lightOverride else { return nil }
                if override.until > .now { return override.on }
                state.lightOverride = nil
                return nil
            }
            light.characteristic(.on).show(.bool(override ?? (data["led_status"]?.stringValue == "on")))
        }
        siren?.characteristic(.on).show(.bool((data["siren_status"]?["seconds_remaining"]?.looseDouble ?? 0) > 0))
        inHomeDoorbell?.characteristic(.on).show(.bool(data["settings"]?["chime_settings"]?["enable"]?.boolValue == true))
        if let battery, let level = RingBattery.rest(data) {
            battery.characteristic(.batteryLevel).show(.int(level ?? 100))
            battery.characteristic(.statusLowBattery).show(.int(data["alerts"]?["battery"]?.stringValue == "low" ? 1 : 0))
            battery.characteristic(.chargingState).show(.int(data["external_connection"]?.boolValue == true ? 1 : 0))
        }
    }

    private func setLight(_ on: Bool) {
        state.withLockedValue { $0.lightOverride = (on, .now + environment.timing.lightOverride) }
        let id = id
        environment.background("Turning the light of \(name) \(on ? "on" : "off")") { [weak self] in
            try await self?.environment.client.put("doorbots/\(id)/floodlight_light_\(on ? "on" : "off")")
            self?.state.withLockedValue { $0.data = Self.setting($0.data, ["led_status"], .string(on ? "on" : "off")) }
        }
    }

    private func setSiren(_ on: Bool) {
        let id = id
        environment.background("Turning the siren of \(name) \(on ? "on" : "off")") { [weak self] in
            try await self?.environment.client.put("doorbots/\(id)/siren_\(on ? "on" : "off")")
            self?.state.withLockedValue { $0.data = Self.setting($0.data, ["siren_status", "seconds_remaining"], .number(on ? 1 : 0)) }
        }
    }

    private func setInHomeDoorbell(_ on: Bool) {
        let id = id
        environment.background("Setting the in-home doorbell of \(name)") { [weak self] in
            try await self?.environment.client.put("doorbots/\(id)/", body: ["doorbot": ["settings": ["chime_settings": ["enable": .bool(on)]]]])
            self?.environment.requestRefresh()
        }
    }

    /// `data` with the value at `path` replaced.
    static func setting(_ data: JSONValue, _ path: [String], _ value: JSONValue) -> JSONValue {
        guard let key = path.first else { return value }
        var object = data.objectValue ?? [:]
        object[key] = setting(object[key] ?? [:], Array(path.dropFirst()), value)
        return .object(object)
    }

    // MARK: Notifications

    /// A ding or a motion push for this camera: active for 65 s, the doorbell pressed, motion while any motion is active.
    func handle(_ notification: RingNotification) {
        guard notification.dingID != nil else { return }
        let lifetime = environment.timing.notificationLifetime
        state.withLockedValue { state in
            state.active.removeAll { $0.notification.dingID == notification.dingID }
            state.active.append(ActiveNotification(notification: notification, expires: .now + lifetime))
        }
        environment.tasks.add { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.expireNotifications()
        }
        if notification.category == RingNotification.ding { doorbellPressed() }
        updateMotion()
    }

    private func expireNotifications() {
        state.withLockedValue { state in state.active.removeAll { $0.expires <= .now } }
        updateMotion()
    }

    /// The snapshot of the latest active notification.
    var latestSnapshotUUID: String? { state.withLockedValue { $0.active.last?.notification.snapshotUUID } }

    private func updateMotion() {
        let changed = state.withLockedValue { state -> Bool? in
            let motion = state.active.contains { $0.notification.category == RingNotification.motion }
            guard motion != state.motion else { return nil }
            state.motion = motion
            return motion
        }
        guard let changed, let motionService else { return }
        if changed {
            environment.tasks.add { [weak self] in
                await self?.loadEventSnapshot(event: "Detected Motion")
                guard self?.state.withLockedValue({ $0.motion }) == true else { return }
                motionService.characteristic(.motionDetected).show(.bool(true))
            }
        } else {
            motionService.characteristic(.motionDetected).show(.bool(false))
        }
    }

    private func doorbellPressed() {
        programmableSwitch?.characteristic(.programmableSwitchEvent).sendEvent(.int(0))
        let throttle = environment.timing.doorbellThrottle
        let passes = state.withLockedValue { state -> Bool in
            if let last = state.lastDoorbell, .now - last < throttle { return false }
            state.lastDoorbell = .now
            return true
        }
        guard passes, let doorbell = controller as? DoorbellController else { return }
        environment.tasks.add { [weak self] in
            await self?.loadEventSnapshot(event: "Doorbell Pressed")
            doorbell.ringDoorbell()
        }
    }

    /// Before HomeKit hears of motion or a ring, the moment's snapshot, so the notification shows it.
    private func loadEventSnapshot(event: String) async {
        var uuid = latestSnapshotUUID
        if !canSnapshotWhileRecording, uuid == nil {
            let deadline = ContinuousClock.now + environment.timing.snapshotUUIDWait
            while uuid == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                uuid = latestSnapshotUUID
            }
            if uuid == nil {
                environment.logger.info("\(name) \(event)")
                return
            }
        }
        environment.logger.info("\(name) \(event), loading snapshot before sending event to HomeKit")
        do {
            _ = try await refreshSnapshot(uuid: uuid)
        } catch {
            environment.logger.info("\(name) failed to load snapshot, sending event without new snapshot")
        }
    }

    // MARK: Snapshots (6.6, 6.7)

    var operatesOnBattery: Bool { RingBattery.operatesOnBattery(data) }
    var canSnapshotWhileRecording: Bool { !operatesOnBattery && kind != "doorbell_graham_cracker" }
    var snapshotLifetime: Duration { environment.configuration.avoidSnapshotBatteryDrain == true && operatesOnBattery ? .seconds(600) : .seconds(10) }
    var isOffline: Bool { data["alerts"]?["connection"]?.stringValue == "offline" }
    var snapshotsBlocked: Bool { data["settings"]?["motion_detection_enabled"]?.boolValue == false }

    private var isWithinLifetime: Bool {
        let lifetime = snapshotLifetime
        return state.withLockedValue { state in state.takenAt.map { .now - $0 < lifetime } ?? false }
    }

    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        if isOffline || snapshotsBlocked { return RingPlaceholder.jpeg }
        if !isWithinLifetime {
            environment.tasks.add { [weak self] in _ = try? await self?.refreshSnapshot(uuid: nil) }
        }
        guard let cached = state.withLockedValue({ $0.cached }) else { throw RingError.unexpected("No snapshot cached for \(name)") }
        return cached
    }

    /// A new snapshot into the cache, one request at a time per event uuid (callers asking for the same share it).
    func refreshSnapshot(uuid: String?) async throws -> Data {
        let task = state.withLockedValue { state -> Task<Data, any Error> in
            if let refreshing = state.refreshing, refreshing.uuid == uuid { return refreshing.task }
            let task = Task { try await self.takeSnapshot(uuid: uuid) }
            state.refreshing = (uuid, task)
            return task
        }
        do {
            let image = try await task.value
            let keep = snapshotLifetime + environment.timing.snapshotKeep
            let generation = state.withLockedValue { state -> Int in
                if state.refreshing?.task == task { state.refreshing = nil }
                state.cached = image
                state.cacheGeneration += 1
                return state.cacheGeneration
            }
            environment.tasks.add { [weak self] in
                try? await Task.sleep(for: keep)
                self?.state.withLockedValue { state in if state.cacheGeneration == generation { state.cached = nil } }
            }
            return image
        } catch {
            state.withLockedValue { state in
                if state.refreshing?.task == task { state.refreshing = nil }
                state.cached = nil
            }
            environment.logger.debug("\(name) snapshot failed\(isOffline ? " (the camera is offline)" : ""): \(error)")
            throw error
        }
    }

    /// The camera's snapshot: the last one while within its lifetime, else a new one from Ring within 15 s.
    private func takeSnapshot(uuid: String?) async throws -> Data {
        if uuid == nil, isWithinLifetime, let last = state.withLockedValue({ $0.lastSnapshot }) { return last }
        if snapshotsBlocked { throw RingError.unexpected("Motion detection is disabled for \(name), which prevents snapshots (Modes or Record Motion)") }
        if isOffline { throw RingError.unexpected("\(name) is offline") }
        let after = state.withLockedValue { $0.cameraTimestamp }
        let client = environment.client, id = id
        let timeout = environment.timing.snapshotTimeout
        let response = try await withThrowingTaskGroup(of: RingResponse.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await client.snapshot(cameraID: id, uuid: uuid, afterMilliseconds: after) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RingError.unexpected("Snapshot for \(self.name) failed to refresh after 15 seconds")
            }
            return try await group.next()!
        }
        state.withLockedValue { state in
            if let millis = response.timeMillis {
                state.cameraTimestamp = millis
                let age = response.responseTimestamp.map { abs($0 - millis) } ?? 0
                state.takenAt = .now - .milliseconds(Int64(min(age, 86_400_000)))
            } else {
                state.takenAt = .now
            }
            state.lastSnapshot = response.body
        }
        return response.body
    }

    // MARK: Streams

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        if data["settings"]?["live_view_disabled"]?.boolValue == true {
            throw RingError.unexpected("Live view is disabled for \(name) by Modes; enable it in the Ring app")
        }
        environment.logger.warning("Live video from \(name) needs WebRTC, which Homeswift does not have yet: snapshots and events only")
        throw HAPStatusError(.resourceDoesNotExist)
    }

    func handleStreamRequest(_ request: StreamingRequest) async throws {
        if case .stop = request { return }
        throw HAPStatusError(.resourceDoesNotExist)
    }
}

/// An intercom (4.5): a Lock Mechanism that unlocks for 5 s, a Doorbell and a programmable switch for its dings.
final class RingIntercom: Sendable {
    let id: String
    let name: String
    private let environment: RingEnvironment
    private let lock: Service
    private let doorbell: Service
    private let button: Service
    private let battery: Service?
    private let lastDing = NIOLockedValueBox<ContinuousClock.Instant?>(nil)
    private let unlockGeneration = NIOLockedValueBox(0)
    let accessory: Accessory

    init(data: JSONValue, environment: RingEnvironment) {
        id = data["id"]?.idString ?? ""
        name = data["description"]?.stringValue ?? "Ring Intercom"
        self.environment = environment
        lock = Service(.lockMechanism, name: name, isPrimary: true)
        doorbell = Service(.doorbell, name: name)
        button = Service(.statelessProgrammableSwitch, name: name, optional: [.programmableSwitchEvent.with(maxValue: 0, validValues: [0])])
        doorbell.characteristic(.programmableSwitchEvent).onRead { .null }
        button.characteristic(.programmableSwitchEvent).onRead { .null }
        battery = RingBattery.rest(data) != nil ? Service(.battery, optional: [.batteryLevel, .chargingState]) : nil
        accessory = Accessory(
            id: RingPlugin.accessoryID(seed: id), name: name, manufacturer: "Ring", model: "Intercom Handset Audio",
            serialNumber: data["device_id"]?.stringValue ?? "Unknown", category: .door, services: [lock, doorbell, button, battery].compactMap { $0 })
        lock.characteristic(.lockCurrentState).value = .int(1)
        lock.characteristic(.lockTargetState).value = .int(1)
        let id = id, name = name, logger = environment.logger
        lock.characteristic(.lockTargetState).onWrite { [weak self] value in
            guard (value.intValue ?? 1) == 0 else {
                self?.showLocked(true)
                return
            }
            logger.info("Unlocking \(name)")
            environment.background("Unlocking \(name)") { [weak self] in
                let response = try await environment.client.unlockIntercom(id)
                logger.info("Unlock response: \(response.text())")
                self?.showUnlocked()
            }
        }
        if let battery {
            battery.characteristic(.batteryLevel).onRead {
                environment.requestRefresh()
                return battery.characteristic(.batteryLevel).value
            }
        }
        update(data)
    }

    func update(_ data: JSONValue) {
        guard let battery, let level = RingBattery.rest(data) else { return }
        battery.characteristic(.batteryLevel).show(.int(level ?? 100))
        battery.characteristic(.statusLowBattery).show(.int((level ?? 100) <= 20 ? 1 : 0))
    }

    private func showLocked(_ locked: Bool) {
        lock.characteristic(.lockCurrentState).show(.int(locked ? 1 : 0))
        lock.characteristic(.lockTargetState).show(.int(locked ? 1 : 0))
    }

    /// Unsecured for 5 s, then secured again.
    func showUnlocked() {
        showLocked(false)
        let generation = unlockGeneration.withLockedValue { $0 += 1; return $0 }
        let delay = environment.timing.intercomUnlocked
        environment.tasks.add { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.unlockGeneration.withLockedValue({ $0 }) == generation else { return }
            self.showLocked(true)
        }
    }

    func ding() {
        let throttle = environment.timing.doorbellThrottle
        let passes = lastDing.withLockedValue { last -> Bool in
            if let last, .now - last < throttle { return false }
            last = .now
            return true
        }
        guard passes else { return }
        environment.logger.info("\(name) Ding")
        doorbell.characteristic(.programmableSwitchEvent).sendEvent(.int(0))
        button.characteristic(.programmableSwitchEvent).sendEvent(.int(0))
    }
}
