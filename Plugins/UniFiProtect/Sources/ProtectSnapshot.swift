import Foundation
import Homeswift
import HomeswiftNetwork

/// Snapshots for HomeKit (`ProtectSnapshot`), from the best source at hand: the camera's own snapshot URL
/// (third-party cameras), the timeshift buffer, the RTSP stream through FFmpeg, then the controller's
/// snapshot API (first for package cameras, whose low frame rate makes FFmpeg slow), and a recent image when
/// all of them fail. Identical requests in flight share one attempt, and an image a few seconds old serves
/// again while nothing happened on the camera.
@ProtectActor
final class ProtectSnapshot {
    private struct Cached {
        var image: Data
        var lastMotion: Double?
        var lastRing: Double?
        var request: SnapshotRequest?
        var time: ContinuousClock.Instant
    }

    private let camera: ProtectCamera
    private weak var stream: ProtectStreamingDelegate?
    private let ffmpeg: any ProtectFfmpegKit
    private let options: any ProtectFfmpegOptions
    private var cached: Cached?
    private var pending: [String: Task<Data?, Never>] = [:]

    init(camera: ProtectCamera, stream: ProtectStreamingDelegate, ffmpeg: any ProtectFfmpegKit, options: any ProtectFfmpegOptions) {
        self.camera = camera
        self.stream = stream
        self.ffmpeg = ffmpeg
        self.options = options
    }

    private var log: ProtectLog { camera.log }

    /// A snapshot, or nil when none could be had.
    func getSnapshot(_ request: SnapshotRequest?) async -> Data? {
        let api = camera.api
        guard await api.bootstrap != nil, !(await api.isThrottled), camera.isOnline else { return nil }
        if let fresh = freshSnapshot(request) { return fresh }
        let cachedSnapshot = cachedImage
        let deadline = ContinuousClock.now + .milliseconds(ProtectSettings.snapshotTimeout)
        let key = request.map { "\($0.width)x\($0.height)" } ?? "default"
        if let pending = pending[key] {
            let shared = await protectTimeout(milliseconds: ProtectSettings.snapshotTimeout) { await pending.value }
            return shared ?? fallback(cachedSnapshot)
        }
        let attempt = Task { @ProtectActor in await self.takeSnapshot(request, deadline: deadline) }
        pending[key] = attempt
        let result = await protectTimeout(milliseconds: ProtectSettings.snapshotTimeout) { [weak self] in
            let image = await attempt.value
            await self?.finished(key, attempt)
            return image
        }
        return result ?? fallback(cachedSnapshot)
    }

    private func finished(_ key: String, _ attempt: Task<Data?, Never>) {
        if pending[key] == attempt { pending[key] = nil }
    }

    private func takeSnapshot(_ request: SnapshotRequest?, deadline: ContinuousClock.Instant) async -> Data? {
        var image = await snapFromURLOverride()
        if image == nil { image = await snapFromTimeshift(budget(deadline, hasFallback: true), request) }
        if image == nil {
            if camera.context.packageCamera != nil {
                image = await snapFromAPI(budget(deadline, hasFallback: true), usePackageCamera: true, request)
                if image == nil { image = await snapFromRTSP(budget(deadline, hasFallback: false), request) }
            } else {
                image = await snapFromRTSP(budget(deadline, hasFallback: true), request)
                if image == nil { image = await snapFromAPI(budget(deadline, hasFallback: false), usePackageCamera: false, request) }
            }
        }
        guard var snapshot = image else { return nil }
        if camera.hints.crop {
            let cropped = await crop(snapshot, budget: budget(deadline, hasFallback: false))
            if cropped == nil { log.warning("Unable to crop this snapshot: returning the uncropped image instead.") }
            snapshot = cropped ?? snapshot
        }
        let markers = eventMarkers
        cached = Cached(image: snapshot, lastMotion: markers.lastMotion, lastRing: markers.lastRing, request: request, time: .now)
        return snapshot
    }

    private func fallback(_ cachedSnapshot: Data?) -> Data? {
        if let cachedSnapshot {
            log.warning("Unable to retrieve a snapshot: using the most recent cached snapshot instead.")
            return cachedSnapshot
        }
        log.error("Unable to retrieve a snapshot.")
        return nil
    }

    /// Milliseconds a source may take, keeping a reserve for the source after it.
    private func budget(_ deadline: ContinuousClock.Instant, hasFallback: Bool) -> Int {
        let left = ContinuousClock.now.duration(to: deadline)
        let milliseconds = Int(left.components.seconds * 1000) + Int(left.components.attoseconds / 1_000_000_000_000_000)
        return milliseconds - (hasFallback ? ProtectSettings.snapshotFallbackReserve : 0)
    }

    /// The camera's own snapshot URL (`snapshotUrl` of a camera override): any certificate, at most 10 MB.
    private func snapFromURLOverride() async -> Data? {
        let override = camera.hints.snapshotUrlOverride
        guard !override.isEmpty else { return nil }
        guard let url = URL(string: override) else {
            log.warning("Snapshot URL override request failed: invalid URL.")
            return nil
        }
        do {
            let request = HTTPRequest(method: "GET", url: url, timeout: .milliseconds(ProtectSettings.snapshotTimeout))
            let response = try await camera.platform.dependencies.transport.send(request, tls: override.hasPrefix("https://") ? .any : .system)
            guard response.status == 200 else {
                log.warning("Snapshot URL override returned HTTP \(response.status).")
                return nil
            }
            if let length = response.header("content-length").flatMap(Int.init), length > ProtectSettings.snapshotURLMaxSize {
                log.warning("Snapshot URL override returned an image that is too large (\(length) bytes).")
                return nil
            }
            guard response.body.count <= ProtectSettings.snapshotURLMaxSize else {
                log.warning("Snapshot URL override returned an image that is too large (\(response.body.count) bytes).")
                return nil
            }
            return response.body
        } catch {
            log.warning("Snapshot URL override request failed: \(error).")
            return nil
        }
    }

    private func snapFromAPI(_ budget: Int, usePackageCamera: Bool, _ request: SnapshotRequest?) async -> Data? {
        guard budget > 0 else { return nil }
        return await camera.api.getSnapshot(camera.ufp.json, width: request?.width, height: request?.height, timeout: .milliseconds(budget),
                                            usePackageCamera: usePackageCamera)
    }

    private func snapFromTimeshift(_ budget: Int, _ request: SnapshotRequest?) async -> Data? {
        guard camera.hints.highResSnapshots, let hksv = stream?.hksv,
              let buffer = hksv.timeshift.getLast(ProtectSettings.livestreamAPIIDRInterval * 1000) else { return nil }
        let input = ["-r", hksv.rtspEntry.map { String($0.channel.fps) } ?? "30", "-probesize", String(buffer.count), "-f", "mp4", "-i", "pipe:0"]
        return await snapFromFfmpeg(input, budget: budget, request, stdin: buffer)
    }

    private func snapFromRTSP(_ budget: Int, _ request: SnapshotRequest?) async -> Data? {
        guard camera.hints.highResSnapshots, let stream, let entry = camera.findRtsp(width: 3840, height: 2160, biasHigher: true) else { return nil }
        let input = ["-avioflags", "direct", "-r", String(entry.channel.fps), "-probesize", String(stream.probesize), "-rtsp_transport", "tcp", "-i", entry.url]
        return await snapFromFfmpeg(input, budget: budget, request)
    }

    /// The FFmpeg command line of a snapshot: one key frame, scaled down (never up) to the request with
    /// letterboxing, as a JPEG on standard output.
    nonisolated static func snapshotArguments(input: [String], decoder: [String], request: SnapshotRequest?, verbose: Bool) -> [String] {
        var arguments = ["-hide_banner", "-nostats", "-fflags", "+discardcorrupt+genpts"] + decoder
            + ["-max_delay", "500000", "-flags", "low_delay", "-skip_frame", "nointra"] + input + ["-fps_mode", "vfr", "-frames:v", "1", "-q:v", "2"]
        if let request {
            let download = decoder.contains { ["h264_qsv", "hevc_qsv"].contains($0) } ? "hwdownload,format=nv12," : ""
            arguments += ["-filter:v", [download + "scale=" + String(request.width), String(request.height),
                                        "force_original_aspect_ratio=decrease,pad=" + String(request.width), String(request.height),
                                        "(ow-iw)/2", "(oh-ih)/2"].joined(separator: ":")]
        }
        arguments += ["-f", "image2pipe", "-c:v", "mjpeg", "pipe:1"]
        if verbose { arguments.insert(contentsOf: ["-loglevel", "level+verbose"], at: 0) }
        return arguments
    }

    private func snapFromFfmpeg(_ input: [String], budget: Int, _ request: SnapshotRequest?, stdin: Data? = nil) async -> Data? {
        guard budget > 0 else { return nil }
        let arguments = Self.snapshotArguments(input: input, decoder: options.videoDecoder(camera.ufp.videoCodec), request: request,
                                               verbose: camera.hasFeature("Debug.Video.Snapshot"))
        guard let result = await ffmpeg.exec(options: options, arguments: arguments, stdin: stdin, timeout: budget, logErrors: false),
              result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    private func crop(_ snapshot: Data, budget: Int) async -> Data? {
        guard budget > 0 else { return nil }
        let arguments = ["-hide_banner", "-nostats", "-fflags", "+discardcorrupt+genpts"] + options.videoDecoder(camera.ufp.videoCodec)
            + ["-max_delay", "500000", "-flags", "low_delay", "-i", "pipe:0", "-filter:v", options.cropFilter, "-f", "image2pipe", "-c:v", "mjpeg", "pipe:1"]
        guard let result = await ffmpeg.exec(options: options, arguments: arguments, stdin: snapshot, timeout: budget, logErrors: true),
              result.exitCode == 0 else { return nil }
        return result.stdout
    }

    /// An image from the last five seconds that answers this request, taken after the camera's last motion
    /// and ring.
    private func freshSnapshot(_ request: SnapshotRequest?) -> Data? {
        guard let cached, ContinuousClock.now - cached.time <= .seconds(ProtectSettings.snapshotCacheFreshness) else { return nil }
        let markers = eventMarkers
        guard markers.lastMotion == cached.lastMotion, markers.lastRing == cached.lastRing else { return nil }
        guard let request else { return cached.request == nil ? cached.image : nil }
        if let size = cached.request, size.width < request.width || size.height < request.height { return nil }
        return cached.image
    }

    private var eventMarkers: (lastMotion: Double?, lastRing: Double?) {
        (camera.ufp.json.double("lastMotion"), camera.ufp.json.double("lastRing"))
    }

    /// The last image when it is at most 90 seconds old.
    private var cachedImage: Data? {
        guard let cached, ContinuousClock.now - cached.time <= .seconds(ProtectSettings.snapshotCacheMaxAge) else {
            cached = nil
            return nil
        }
        return cached.image
    }
}
