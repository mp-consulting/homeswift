import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

// The web UI's live view of a camera: the Protect livestream API's fMP4 as it comes, through the camera's
// `ProtectLivestreamManager`, so a viewer shares the session of HomeKit's streams and the timeshift buffer when
// they use the same channel, and the session stops with its last consumer.

extension UniFiProtectPlugin {
    /// The live feed of a camera or a doorbell's package camera of this instance: its lowest-resolution channel,
    /// which is plenty for a card and light on the controller. nil for another accessory, or a camera offline.
    public func liveFeed(accessoryID: String) async throws -> CameraLiveFeed? {
        for controller in nvrs {
            if let camera = await controller.camera(accessoryID: accessoryID) {
                return await camera.liveFeed()
            }
        }
        return nil
    }
}

extension ProtectNVR {
    /// The camera behind an accessory id: a camera or doorbell, or a doorbell's package camera.
    func camera(accessoryID: String) -> ProtectCamera? {
        if let camera = configuredDevices[accessoryID] as? ProtectCamera { return camera }
        for case let doorbell as ProtectDoorbell in deviceList where doorbell.packageCamera?.accessory.id == accessoryID {
            return doorbell.packageCamera
        }
        return nil
    }
}

extension ProtectCamera {
    /// How long a viewer waits for a new session's initialization segment.
    static let liveFeedInitTimeout = 5000
    /// Fragments kept for a viewer that reads slower than the camera sends: about 13 seconds at the
    /// livestream's 100 ms segments. Past that the oldest go; the page jumps to the live edge.
    static let liveFeedBacklog = 128

    /// The channel a live view reads: the one with the fewest pixels, or a package camera's own.
    var liveFeedEntry: RtspEntry? {
        if let package = self as? ProtectCameraPackage { return package.findRtsp(width: 0, height: 0) }
        return rtspEntries.min { $0.channel.width * $0.channel.height < $1.channel.width * $1.channel.height }
    }

    /// Joins (or starts) the livestream session of the preview channel and hands its fragments to a viewer.
    func liveFeed() async -> CameraLiveFeed? {
        guard isOnline, let entry = liveFeedEntry, let livestream = livestream.acquire(entry) else { return nil }
        let (fragments, continuation) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(Self.liveFeedBacklog))
        let listener = ProtectLivestreamListener(livestream) { event in
            switch event {
            case .segment(let segment): continuation.yield(segment)
            // A restart rebases the timestamps and sends a new initialization segment: the page starts afresh.
            case .close: continuation.finish()
            default: break
            }
        }
        let manager = self.livestream
        guard await manager.start(entry) else {
            listener.cancel()
            return nil
        }
        let released = NIOLockedValueBox(false)
        let release: @Sendable () -> Void = {
            guard released.withLockedValue({ done in defer { done = true }; return !done }) else { return }
            continuation.finish()
            Task { @ProtectActor in
                listener.cancel()
                manager.stop(entry)
            }
        }
        continuation.onTermination = { _ in release() }
        var initSegment = livestream.initSegment
        if initSegment == nil {
            initSegment = await protectTimeout(milliseconds: Self.liveFeedInitTimeout) { try? await livestream.getInitSegment() }
        }
        guard let initSegment else {
            log.debug("No initialization segment from the livestream API for a live view.")
            release()
            return nil
        }
        // The codecs of the segment itself, else what the livestream API announced.
        let codec = livestream.codec
        let mimeType = CameraLiveFeed.mimeType(initSegment: initSegment) ?? (codec.isEmpty ? nil : "video/mp4; codecs=\"\(codec)\"")
        log.debug("Live view of \(entry.channel.name) (\(entry.channel.width)x\(entry.channel.height)): \(mimeType ?? "unknown codecs").")
        return CameraLiveFeed(mimeType: mimeType, initSegment: initSegment, fragments: fragments, onCancel: release)
    }
}
