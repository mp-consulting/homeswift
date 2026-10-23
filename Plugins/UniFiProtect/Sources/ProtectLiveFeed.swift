import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin
import NIOConcurrencyHelpers

// The web UI's live view of a camera: the Protect livestream API's fMP4 as it comes, through the camera's
// `ProtectLivestreamManager`, so a viewer shares the session of HomeKit's streams and the timeshift buffer when
// they use the same channel, and the session stops with its last consumer. A third-party camera with an RTSP URL
// of its own (`cameraOverrides`), which the controller does not relay, is remuxed by FFmpeg instead.

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
        if hasDirectStream { return await rtspLiveFeed(url: hints.rtspOverride) }
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

// MARK: Third-party cameras

extension ProtectCamera {
    /// How long a viewer of an RTSP camera waits for FFmpeg's initialization segment: the connection, then the
    /// first key frame, which a camera may send every few seconds.
    static let rtspLiveFeedInitTimeout = 10_000

    /// FFmpeg's command line for a live view of an RTSP URL: the video as the camera sends it (no transcoding),
    /// as fragmented MP4 on standard output, a fragment at each key frame and at least every half second. No
    /// audio: the card plays muted, and a camera's G.711 does not go in MP4 without transcoding.
    nonisolated static func rtspLiveFeedArguments(url: String, codec: String) -> [String] {
        let hevc = ["h265", "hevc"].contains(codec.lowercased())
        return ["-hide_banner", "-nostats", "-fflags", "+genpts+discardcorrupt", "-rtsp_transport", "tcp", "-i", url,
                "-map", "0:v:0", "-an", "-codec:v", "copy"]
            // Safari plays HEVC in MP4 only as `hvc1`.
            + (hevc ? ["-tag:v", "hvc1"] : [])
            + ["-f", "mp4", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-frag_duration", "500000", "pipe:1"]
    }

    /// The live view of a camera's own RTSP stream: one FFmpeg per viewer, stopped when the viewer leaves; nil
    /// when FFmpeg is not there or gives no initialization segment in time.
    func rtspLiveFeed(url: String) async -> CameraLiveFeed? {
        guard let stream else { return nil }
        let process = stream.ffmpeg.startProcess(options: stream.ffmpegOptions, arguments: Self.rtspLiveFeedArguments(url: url, codec: ufp.videoCodec))
        let (fragments, continuation) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(Self.liveFeedBacklog))
        let (initSegments, initContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        let splitter = NIOLockedValueBox(FMp4FeedSplitter())
        let log = self.log
        process.onStdout { [weak process] chunk in
            guard let output = splitter.withLockedValue({ $0.push(chunk) }) else {
                log.error("FFmpeg sent unreadable fMP4 for a live view.")
                process?.stop()
                return
            }
            if let initSegment = output.initSegment {
                initContinuation.yield(initSegment)
                initContinuation.finish()
            }
            for fragment in output.fragments { continuation.yield(fragment) }
        }
        process.onExit {
            initContinuation.finish()
            continuation.finish()
        }
        let release: @Sendable () -> Void = {
            process.stop()
            initContinuation.finish()
            continuation.finish()
        }
        continuation.onTermination = { _ in process.stop() }
        let initSegment = await protectTimeout(milliseconds: Self.rtspLiveFeedInitTimeout) { await initSegments.first { _ in true } }
        guard let initSegment else {
            log.debug("No initialization segment from FFmpeg for a live view of this camera's RTSP stream.")
            release()
            return nil
        }
        let mimeType = CameraLiveFeed.mimeType(initSegment: initSegment)
        log.debug("Live view of the camera's own RTSP stream: \(mimeType ?? "unknown codecs").")
        return CameraLiveFeed(mimeType: mimeType, initSegment: initSegment, fragments: fragments, onCancel: release)
    }
}

/// Cuts FFmpeg's fragmented MP4 into what a live feed hands out: the initialization segment (the boxes up to
/// and including `moov`) once, then each fragment, from a `moof` to the end of its `mdat`.
struct FMp4FeedSplitter: Sendable {
    private var reader = FMp4BoxReader()
    private var header = Data()
    private var hasInitSegment = false
    private var fragment = Data()

    /// The initialization segment when this chunk completed it, and the fragments it completed. nil when the
    /// stream is corrupt.
    mutating func push(_ chunk: Data) -> (initSegment: Data?, fragments: [Data])? {
        var boxes: [FMp4ParsedBox] = []
        var reader = self.reader
        let readable = reader.push(chunk) { boxes.append($0) }
        self.reader = reader
        guard readable else { return nil }
        var initSegment: Data?
        var fragments: [Data] = []
        for box in boxes {
            let bytes = box.header + box.data
            guard hasInitSegment else {
                header += bytes
                if box.type == BOX_TYPE_MOOV {
                    hasInitSegment = true
                    initSegment = header
                    header = Data()
                }
                continue
            }
            if box.type == BOX_TYPE_MOOF {
                fragment = bytes
            } else {
                fragment += bytes
                if box.type == BOX_TYPE_MDAT {
                    fragments.append(fragment)
                    fragment = Data()
                }
            }
        }
        return (initSegment, fragments)
    }
}
