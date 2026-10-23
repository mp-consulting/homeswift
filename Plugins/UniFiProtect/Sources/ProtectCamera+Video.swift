import Foundation
import Homeswift
import HomeswiftPlugin

/// Choosing among a camera's RTSP streams (`ProtectCameraVideo`).
enum RtspSelection {
    struct Options {
        var biasHigher = false
        /// A channel name to use whatever the resolution (`Video.Stream.Only.High`, …).
        var preferred: String?
        /// The host's transcoding limit, in pixels.
        var maxPixels: Int?
    }

    /// Highest resolution first: width, then height, then frame rate.
    static func sortByResolutions(_ a: RtspEntry, _ b: RtspEntry) -> Bool {
        if a.resolution.width != b.resolution.width { return a.resolution.width > b.resolution.width }
        if a.resolution.height != b.resolution.height { return a.resolution.height > b.resolution.height }
        return a.resolution.fps > b.resolution.fps
    }

    /// The entry for a size: the preferred channel when one is set, an exact match, else the next lower
    /// width (or the lowest), or with `biasHigher` the next higher (or the highest).
    static func find(_ entries: [RtspEntry], width: Int, height: Int, options: Options = Options()) -> RtspEntry? {
        var entries = entries
        if let maxPixels = options.maxPixels { entries = entries.filter { $0.channel.width * $0.channel.height <= maxPixels } }
        guard !entries.isEmpty else { return nil }
        if let preferred = options.preferred, !preferred.isEmpty {
            return entries.first { $0.channel.name.uppercased() == preferred.uppercased() }
        }
        if let exact = entries.first(where: { $0.channel.width == width && $0.channel.height == height }) { return exact }
        if !options.biasHigher { return entries.first { $0.channel.width < width } ?? entries.last }
        return entries.filter { $0.channel.width > width }.last ?? entries.first
    }
}

extension ProtectCamera {
    /// A third-party camera streamed from its own RTSP URL (`cameraOverrides`), not through the controller.
    var hasDirectStream: Bool { !hints.rtspOverride.isEmpty }

    /// A camera with an RTSP or snapshot URL of its own: its video does not depend on what the controller says
    /// of its connection, which Protect often reports down for third-party cameras.
    var hasDirectSource: Bool { hasDirectStream || !hints.snapshotUrlOverride.isEmpty }

    /// Works out the streams HomeKit may ask for from the camera's RTSP channels (or the configured RTSP URL
    /// of a third-party camera), and sets up the streaming delegate once.
    @discardableResult
    func configureVideo() async -> Bool {
        var entries: [RtspEntry] = []
        let channels = ufp.channels
        guard !channels.isEmpty else {
            log.warning("No camera channel metadata available from the Protect controller. Streaming cannot be configured for this camera. This typically means the camera "
                + "has not finished initializing on the controller, or that the local Protect user this plugin is configured with lacks an admin role.")
            return false
        }
        let codec = (ufp.videoCodec.isEmpty ? "h264" : ufp.videoCodec).replacingOccurrences(of: "h265", with: "hevc").uppercased()
        if !hints.rtspOverride.isEmpty {
            let source = channels.sorted { $0.width * $0.height > $1.width * $1.height }[0]
            guard !source.name.isEmpty, (1...65535).contains(source.width), (1...65535).contains(source.height) else {
                log.warning("RTSP override is set but the camera channels report invalid resolutions. Streaming cannot be configured.")
                return false
            }
            let resolution = VideoResolution(source.width, source.height, source.fps)
            entries.append(RtspEntry(channel: source, name: resolution.formatted + " (Override) [\(codec)]", resolution: resolution, url: hints.rtspOverride))
            log.info("Using a custom RTSP URL for livestreams. The Protect controller will not be used to relay this stream.")
        } else {
            if let updated = await api.enableRtsp(ufp.json) { ufp = ProtectDeviceConfig(updated) }
            let cameraChannels = ufp.channels.filter { $0.isRtspEnabled && $0.name != "Package Camera" }
            if ufp.isThirdPartyCamera {
                log.warning("Third-party camera detected without an RTSP override URL. The Protect controller often does not relay third-party camera streams successfully. "
                    + "If livestreams fail to render in HomeKit, add a cameraOverrides entry on this camera's controller in config.json with the camera's native RTSP(S) URL.")
            }
            let host = nvr.config.overrideAddress ?? (ufp.isThirdPartyCamera ? nvr.ufp.string("host") : ufp.connectionHost) ?? nvr.ufp.string("host") ?? ""
            let cameraURL = "rtsps://" + host + ":" + (nvr.ufp.int("ports.rtsps").map(String.init) ?? "") + "/"
            guard !cameraChannels.isEmpty else {
                log.info("No RTSP profiles found for this camera. Enable at least one RTSP profile in the UniFi Protect webUI or assign an admin role to the local Protect user you configured for use with this plugin.")
                return false
            }
            for channel in cameraChannels {
                guard !channel.name.isEmpty, (1...65535).contains(channel.width), (1...65535).contains(channel.height) else { continue }
                let resolution = VideoResolution(channel.width, channel.height, channel.fps)
                entries.append(RtspEntry(channel: channel, name: resolution.formatted + " (\(channel.name)) [\(codec)]", resolution: resolution,
                                         url: cameraURL + channel.rtspAlias + "?enableSrtp"))
            }
        }
        guard let generated = Self.homeKitResolutions(for: entries) else {
            log.warning("No usable RTSP streams could be derived for this camera. Streaming cannot be configured.")
            return false
        }
        rtspEntries = generated
        guard stream == nil else { return true }
        if hasFeature("Debug.Video.Startup") {
            for entry in rtspEntries { log.info("Mapping resolution: \(entry.resolution.formatted) => \(entry.name).") }
        }
        for profile in ["Low", "Medium", "High"] {
            if hasFeature("Video.Stream.Only." + profile) { hints.streamingDefault = profile.uppercased() }
            if hasFeature("Video.HKSV.Record.Only." + profile) { hints.recordingDefault = profile.uppercased() }
        }
        if !hints.streamingDefault.isEmpty { log.info("Video streaming configured to use only: \(toCamelCase(hints.streamingDefault.lowercased())).") }
        if !hints.highResSnapshots { log.info("Disabling the use of higher quality snapshots.") }
        stream = platform.ffmpeg.map { ProtectStreamingDelegate(camera: self, resolutions: rtspEntries.map(\.resolution), ffmpeg: $0) }
        if hints.recordingDefault.isEmpty {
            if stream?.hostSystem == "raspbian" {
                hints.recordingDefault = findRtsp(width: 1920, height: 1080, maxPixels: stream?.hostSystemMaxPixels)?.channel.name ?? ""
            } else {
                hints.recordingDefault = hints.hardwareTranscoding ? "High" : ""
            }
        } else {
            log.info("HomeKit Secure Video event recording configured to use only: \(toCamelCase(hints.recordingDefault.lowercased())).")
        }
        return true
    }

    /// Adds the resolutions HomeKit requires (1080p and 720p, and Apple TV and Watch sizes) in the camera's
    /// aspect ratio, each mapped to the closest channel at or below it, at that channel's frame rate; and,
    /// for HKSV, a 1080p entry at 15, 24 or 30 fps when the camera's own rate is none of those. nil when the
    /// camera has no usable entry.
    nonisolated static func homeKitResolutions(for native: [RtspEntry]) -> [RtspEntry]? {
        var entries = native.sorted(by: RtspSelection.sortByResolutions)
        guard let nativeEntry = entries.first else { return nil }
        let sizes: [(Int, Int)] = Double(nativeEntry.resolution.width) / Double(nativeEntry.resolution.height) == 4.0 / 3.0
            ? [(3840, 2880), (2560, 1920), (1920, 1440), (1280, 960), (640, 480), (480, 360), (320, 240)]
            : [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720), (640, 360), (480, 270), (320, 180)]
        let base = entries
        for (width, height) in sizes {
            for _ in [30, 15] {
                if width >= nativeEntry.resolution.width, ![1920, 1280].contains(width) { continue }
                guard let found = RtspSelection.find(base, width: width, height: height) else { continue }
                if entries.contains(where: { $0.resolution.width == width && $0.resolution.height == height && $0.resolution.fps == found.channel.fps }) { continue }
                entries.append(RtspEntry(channel: found.channel, lens: found.lens, name: found.name, resolution: VideoResolution(width, height, found.channel.fps), url: found.url))
            }
        }
        entries.sort(by: RtspSelection.sortByResolutions)
        if let top = entries.first, ![15, 24, 30].contains(top.resolution.fps),
           let index = entries.firstIndex(where: { $0.resolution.width == 1920 && [1080, 1440].contains($0.resolution.height) }) {
            let fps = entries[index].resolution.fps
            entries[index].resolution.fps = fps > 24 ? 30 : fps > 15 ? 24 : 15
        }
        return entries
    }

}
