import Foundation
import HomeswiftFFmpeg
import Logging

/// What the FFmpeg of `videoProcessor` has, asked once in the background: the original always uses libfdk_aac for
/// HomeKit's AAC-ELD, which most FFmpeg builds (Homebrew's, distributions') leave out. Without it, macOS's AudioToolbox
/// encoder and decoder (`aac_at`) make and read AAC-ELD.
final class FFmpegCapabilities: Sendable {
    private let probe: Task<FfmpegCodecs?, Never>

    /// Probes `executable`; nil for its codecs when it does not answer (the original's options are then used).
    init(executable: String, logger: Logger) {
        probe = Task {
            let codecs = FfmpegCodecs(ffmpegExec: executable, log: logger)
            return await codecs.probe() ? codecs : nil
        }
    }

    /// Codecs known in advance (tests), or nil for the original's options.
    init(known: FfmpegCodecs?) {
        probe = Task { known }
    }

    /// The encoder options for HomeKit's AAC-ELD; nil when FFmpeg has none. AudioToolbox names no profiles: 38 is FFmpeg's
    /// AAC-ELD, at a constant bitrate.
    func aacELDEncoder() async -> [String]? {
        guard let codecs = await probe.value, !codecs.hasEncoder("aac", "libfdk_aac") else {
            return ["-codec:a", "libfdk_aac", "-profile:a", "aac_eld"]
        }
        return codecs.hasEncoder("aac", "aac_at") ? ["-codec:a", "aac_at", "-profile:a", "38", "-aac_at_mode", "cbr"] : nil
    }

    /// The decoder option of the two-way audio's AAC-ELD: libfdk_aac when FFmpeg has it, then AudioToolbox's, then FFmpeg's
    /// own (which fails on some encoders' ELD).
    func aacELDDecoder() async -> [String] {
        guard let codecs = await probe.value, !codecs.hasDecoder("aac", "libfdk_aac") else { return ["-c:a", "libfdk_aac"] }
        return codecs.hasDecoder("aac", "aac_at") ? ["-c:a", "aac_at"] : []
    }
}
