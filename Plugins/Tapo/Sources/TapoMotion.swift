import Foundation
import HomeswiftNetwork
import Logging

/// The cameras' motion, from the account's notification inbox in the TP-Link cloud (docs/clean-room/TapoCloudEvents.md,
/// 8): one poll every few seconds covers every camera, each message goes to the camera its `deviceId` names, and none
/// of it reaches a camera, so a battery camera sleeps until its own sensor wakes it.
actor TapoMotionWatcher {
    struct Timing: Sendable {
        var interval: Duration = .seconds(5)
        var maximumBackoff: Duration = .seconds(300)
        /// How often the account's cameras are listed again while one is not matched yet.
        var relist: Duration = .seconds(1800)
    }

    /// A camera to watch: what it is known by, and what to call on a detection.
    struct Camera: Sendable {
        var name: String
        /// The cloud's id, when the settings give it.
        var cloudID: String?
        var host: String
        var model: String?
        var onMotion: @Sendable (_ type: String) -> Void
    }

    private let cloud: TapoCloud
    private let timing: Timing
    private let logger: Logger
    private let macAddress: @Sendable (String) async -> String?
    private var cameras: [Camera] = []
    /// The cloud ids of the cameras, by their index in `cameras`.
    private var matched: [String: [Int]] = [:]
    private var seen: [String] = []
    private var cursor: Int?
    /// When the watch began: older messages are not news.
    private var startedAt: Int?

    init(cloud: TapoCloud, timing: Timing = Timing(), logger: Logger, macAddress: @escaping @Sendable (String) async -> String? = { await ARPTable.macAddress(for: $0) }) {
        self.cloud = cloud
        self.timing = timing
        self.logger = logger
        self.macAddress = macAddress
    }

    func add(_ camera: Camera) { cameras.append(camera) }

    var matchedCount: Int { matched.values.reduce(0) { $0 + $1.count } }

    /// Signs in, finds the cameras and polls until cancelled. A refused sign-in (a wrong password, a code to give) stops
    /// it: Setup signs in again.
    func run(now: @Sendable () -> Date = Date.init) async {
        guard !cameras.isEmpty else { return }
        var delay = timing.interval
        var lastListing: ContinuousClock.Instant?
        while !Task.isCancelled {
            do {
                if matchedCount < cameras.count, lastListing.map({ ContinuousClock.now - $0 >= timing.relist }) ?? true {
                    lastListing = .now
                    try await match()
                }
                if !matched.isEmpty { try await poll(now: now) }
                delay = timing.interval
            } catch let error as TapoCloudError where error.isRefusedSignIn {
                if case .mfaRequired = error {
                    logger.error("No motion from the Tapo cameras: the Tapo cloud wants a code. Sign in again through Add accessories.")
                } else {
                    logger.error("No motion from the Tapo cameras: \(error). Sign in again through Add accessories.")
                }
                return
            } catch {
                if Task.isCancelled { return }
                logger.warning("Tapo cloud: \(error)")
                delay = min(delay * 2, timing.maximumBackoff)
            }
            try? await Task.sleep(for: delay)
        }
    }

    /// Each camera's cloud id (4.3): the one its settings give, else the camera with its MAC (if the bridge already
    /// knows it), its name, or the only one of its model or of the account.
    private func match() async throws {
        let devices = try await cloud.cameras()
        var result: [String: [Int]] = [:]
        for (index, camera) in cameras.enumerated() {
            var found: TapoCloud.Device?
            if let id = camera.cloudID { found = devices.first { $0.deviceID == id } }
            if found == nil, let mac = await macAddress(camera.host).map(TapoCloud.normalizedMAC), !mac.isEmpty {
                found = devices.first { $0.mac == mac }
            }
            if found == nil { found = devices.first { $0.alias.caseInsensitiveCompare(camera.name) == .orderedSame } }
            if found == nil, let model = camera.model {
                let sameModel = devices.filter { $0.model.caseInsensitiveCompare(model) == .orderedSame }
                if sameModel.count == 1 { found = sameModel[0] }
            }
            if found == nil, devices.count == 1 { found = devices[0] }
            if let found {
                result[found.deviceID, default: []].append(index)
                logger.debug("\(camera.name): motion comes from the cloud's \(found.model) \"\(found.alias)\".")
            } else {
                let names = devices.map { "\($0.alias) (\($0.model), \($0.deviceID))" }.joined(separator: ", ")
                logger.warning("\(camera.name): no camera of the Tapo account matches it (\(names.isEmpty ? "none" : names)); set its cloudId.")
            }
        }
        matched = result
    }

    /// New notifications: each detection to its cameras, once.
    private func poll(now: @Sendable () -> Date) async throws {
        let startedAt = self.startedAt ?? Int(now().timeIntervalSince1970)
        self.startedAt = startedAt
        let start = cursor ?? startedAt
        if cursor == nil { cursor = start }
        // A little overlap: a message the cloud wrote late is not missed; `seen` keeps it from counting twice.
        let messages = try await cloud.notifications(since: max(0, start - 30))
        for message in messages {
            let key = message.id.isEmpty ? "\(message.deviceID)@\(message.time)" : message.id
            guard !seen.contains(key) else { continue }
            seen.append(key)
            if seen.count > 500 { seen.removeFirst(seen.count - 500) }
            cursor = max(cursor ?? 0, Int(message.time))
            guard Int(message.time) >= startedAt, let indexes = matched[message.deviceID] else { continue }
            for index in indexes {
                logger.debug("\(cameras[index].name): \(message.type) reported by the cloud.")
                cameras[index].onMotion(message.type)
            }
        }
    }
}
