import Homeswift
import Logging

// Host-specific hardware acceleration backends (hwaccel.ts). Each host family (macOS VideoToolbox, Raspberry Pi, and generic
// hosts with optional Intel Quick Sync Video) implements `HwAccelBackend`; `FfmpegOptions` selects one at construction and
// delegates every platform-specific decision to it.

/// The video codecs we know how to decode, after normalization.
public enum HwAccelVideoCodec: String, Sendable {
    case av1
    case h264
    case hevc
}

/// What a backend works with. The options configuration it resolves is passed `inout` to the two `configure` methods.
public struct HwAccelContext: Sendable {
    public var codecSupport: FfmpegCodecs
    public var log: Logger

    public init(codecSupport: FfmpegCodecs, log: Logger) {
        self.codecSupport = codecSupport
        self.log = log
    }
}

/// Host-specific hardware acceleration for FFmpeg.
public protocol HwAccelBackend: Sendable {
    /// Validates hardware decoding, updating `config.hardwareDecoding`. Only called when hardware decoding was requested.
    /// Returns false when hardware acceleration configuration should stop entirely.
    func configureDecoding(_ config: inout FfmpegOptionsConfig) -> Bool
    /// Validates hardware transcoding, updating `hardwareDecoding` and `hardwareTranscoding`. Only called when hardware
    /// transcoding was requested. Returns a message describing the acceleration in use, or an empty string.
    func configureTranscoding(_ config: inout FfmpegOptionsConfig) -> String
    /// The audio encoder arguments for this host.
    func audioEncoder(_ codec: AudioRecordingCodecType?) -> [String]
    /// The hardware decoder arguments for a codec. Only called when hardware decoding is enabled.
    func decoderArgs(_ codec: HwAccelVideoCodec) -> [String]
    /// The arguments that initialize a hardware device when encoding in hardware without decoding in hardware.
    func deviceInitArgs() -> [String]
    /// The filters that move frames from the GPU to system memory.
    func downloadFilters() -> [String]
    /// The filters that move frames from system memory to the GPU.
    func uploadFilters() -> [String]
    /// The scale filters, applied after any transfer filters; `swScale` is the default software scaler.
    func scaleFilters(_ options: VideoEncoderOptions, swScale: String) -> [String]
    /// The hardware encoder arguments for livestreaming.
    func streamEncoderArgs(_ options: VideoEncoderOptions, videoFilters: String, adjustedMaxBitrate: Int) -> [String]
    /// Whether HKSV recordings can use the (possibly hardware) livestreaming encoder.
    var hksvUsesStreamEncoder: Bool { get }
    /// The most pixels the hardware encoder handles when hardware transcoding is on; `Int.max` (TypeScript's `Infinity`) when unlimited.
    var maxTranscodePixels: Int { get }
}

/// The FFmpeg form of an H.264 level: `3.1`, or `31` when `numeric`.
public func h264LevelArg(_ level: H264Level, numeric: Bool = false) -> String {
    switch level {
    case .level3_1: numeric ? "31" : "3.1"
    case .level3_2: numeric ? "32" : "3.2"
    case .level4_0: numeric ? "40" : "4.0"
    }
}

/// The FFmpeg form of an H.264 profile: `high`, or `100` when `numeric`.
public func h264ProfileArg(_ profile: H264Profile, numeric: Bool = false) -> String {
    switch profile {
    case .baseline: numeric ? "66" : "baseline"
    case .high: numeric ? "100" : "high"
    case .main: numeric ? "77" : "main"
    }
}

/// The hardware acceleration features enabled, for log messages: `decoding and ⛭︎ transcoding`.
public func hwAccelCategories(hardwareDecoding: Bool, hardwareTranscoding: Bool) -> String {
    var categories: [String] = []
    if hardwareDecoding { categories.append("decoding") }
    if hardwareTranscoding { categories.append("⛭︎ transcoding") }
    return categories.joined(separator: " and ")
}

// Behaviour shared by the backends (BaseHwAccelBackend).
extension HwAccelBackend {
    public var hksvUsesStreamEncoder: Bool { true }
    public var maxTranscodePixels: Int { Int.max }
}

/// What every backend needs: the codec support and the shared helpers of `BaseHwAccelBackend`.
protocol BaseHwAccelBackend: HwAccelBackend {
    var ctx: HwAccelContext { get }
}

extension BaseHwAccelBackend {
    func accelCategories(_ config: FfmpegOptionsConfig) -> String {
        hwAccelCategories(hardwareDecoding: config.hardwareDecoding, hardwareTranscoding: config.hardwareTranscoding)
    }

    func defaultAudioEncoder(_ codec: AudioRecordingCodecType?) -> [String] {
        var audioOptions: [String] = []
        if ctx.codecSupport.hasEncoder("aac", "libfdk_aac") {
            // libfdk_aac, since FFmpeg doesn't natively support AAC-ELD:
            //
            // -codec:a libfdk_aac           Use the libfdk_aac encoder.
            // -afterburner 1                Better audio quality for a little more computation.
            audioOptions += ["-codec:a", "libfdk_aac", "-afterburner", "1"]
            if codec != .aacELD {
                audioOptions += ["-vbr", "4"]
            }
        }
        return audioOptions
    }

    // -r framerate                        The output frame rate, set here rather than in filters to keep the hardware pipeline.
    func frameRateArgs(_ options: VideoEncoderOptions) -> [String] {
        options.fps != options.inputFps ? ["-r", String(options.fps)] : []
    }

    func validateEncoder(_ codec: String, _ config: inout FfmpegOptionsConfig) -> Bool {
        guard ctx.codecSupport.hasEncoder("h264", codec) else {
            ctx.log.error(
                "Unable to enable hardware-accelerated transcoding. Your video processor does not have support for the \(codec) encoder. Using software transcoding instead."
            )
            config.hardwareTranscoding = false
            return false
        }
        return true
    }

    func validateHwAccel(_ accel: String, _ config: inout FfmpegOptionsConfig) -> Bool {
        guard ctx.codecSupport.hasHwAccel(accel) else {
            ctx.log.error(
                "Unable to enable hardware-accelerated decoding. Your video processor does not have support for the \(accel) hardware accelerator. Using software decoding instead."
            )
            config.hardwareDecoding = false
            return false
        }
        return true
    }

    // FFmpeg 8.x unlocks several hardware pipeline capabilities.
    var isFfmpeg8: Bool { ctx.codecSupport.ffmpegVersion.hasPrefix("8.") }
}

/// macOS: VideoToolbox and AudioToolbox, on Apple Silicon and Intel Macs.
public struct VideoToolboxBackend: BaseHwAccelBackend {
    let ctx: HwAccelContext
    private let appleSilicon: Bool

    public init(_ ctx: HwAccelContext, appleSilicon: Bool) {
        self.ctx = ctx
        self.appleSilicon = appleSilicon
    }

    public func configureDecoding(_ config: inout FfmpegOptionsConfig) -> Bool {
        _ = validateHwAccel("videotoolbox", &config)
        return true
    }

    public func configureTranscoding(_ config: inout FfmpegOptionsConfig) -> String {
        _ = validateEncoder("h264_videotoolbox", &config)
        if !ctx.codecSupport.hasEncoder("aac", "aac_at") {
            ctx.log.error("Your video processor does not have support for the native macOS AAC encoder, aac_at. Will attempt to use libfdk_aac instead.")
        }
        return ""
    }

    public func audioEncoder(_ codec: AudioRecordingCodecType?) -> [String] {
        // Without AudioToolbox, back to libfdk_aac.
        guard ctx.codecSupport.hasEncoder("aac", "aac_at") else { return defaultAudioEncoder(codec) }
        // -codec:a aac_at               The macOS audio encoder.
        // -aac_at_mode                  cbr for AAC-ELD, vbr (quality 2) for AAC-LC.
        var encoderOptions = ["-codec:a", "aac_at"]
        if codec == .aacELD {
            encoderOptions += ["-aac_at_mode", "cbr"]
        } else {
            encoderOptions += ["-aac_at_mode", "vbr", "-q:a", "2"]
        }
        return encoderOptions
    }

    public func decoderArgs(_ codec: HwAccelVideoCodec) -> [String] {
        // -hwaccel videotoolbox           Hardware-accelerated decoding with Video Toolbox.
        ["-hwaccel", "videotoolbox"] + (isFfmpeg8 ? ["-hwaccel_output_format", "videotoolbox_vld"] : [])
    }

    public func deviceInitArgs() -> [String] {
        // FFmpeg before 8.0 doesn't support VideoToolbox this way.
        guard isFfmpeg8 else { return [] }
        // -init_hw_device               Initialize the accelerator and name it for the command line.
        // -filter_hw_device             The accelerator the filter pipeline uses.
        return ["-init_hw_device", "videotoolbox=hw", "-filter_hw_device", "hw"]
    }

    public func downloadFilters() -> [String] {
        isFfmpeg8 ? ["hwdownload", "format=nv12"] : []
    }

    public func uploadFilters() -> [String] {
        isFfmpeg8 ? ["hwupload"] : []
    }

    public func scaleFilters(_ options: VideoEncoderOptions, swScale: String) -> [String] {
        if isFfmpeg8 && (options.hardwareTranscoding ?? false) {
            // The VideoToolbox scaler (scale_vt), reliable from FFmpeg 8.0.
            return ["scale_vt=-2:min(ih\\, " + String(options.height) + ")"]
        }
        return [swScale]
    }

    public func streamEncoderArgs(_ options: VideoEncoderOptions, videoFilters: String, adjustedMaxBitrate: Int) -> [String] {
        // -codec:v h264_videotoolbox    The macOS hardware encoder.
        // -allow_sw 1                   Fall back to the software encoder when the hardware engines are busy.
        // -realtime 1                   Prefer speed over quality.
        // -profile:v                    The H.264 profile HomeKit requests.
        // -level:v 0                    Let the hardware encoder choose its level.
        // -bf 0                         No B-frames, for finicky HomeKit clients.
        // -noautoscale                  Don't scale automatically.
        // -filter:v                     Pixel format, frame rate and scaling.
        // -b:v / -q:v                   Average bitrate (Intel), or a quality target on Apple Silicon when smart quality is on.
        // -g:v                          Frames per second times the keyframe interval.
        // -bufsize / -maxrate           Bound the bitrate.
        // -r                            The output frame rate, outside the filters.
        var encoderOptions = [
            "-codec:v", "h264_videotoolbox", "-allow_sw", "1", "-realtime", "1", "-profile:v", h264ProfileArg(options.profile),
            "-level:v", "0", "-bf", "0", "-noautoscale", "-filter:v", videoFilters,
        ]
        guard appleSilicon else {
            encoderOptions += [
                "-b:v", String(options.bitrate) + "k", "-g:v", String(options.fps * options.idrInterval),
                "-bufsize", String(2 * options.bitrate) + "k", "-maxrate", String(adjustedMaxBitrate) + "k",
            ] + frameRateArgs(options)
            return encoderOptions
        }
        encoderOptions += [
            "-g:v", String(options.fps * options.idrInterval), "-bufsize", String(2 * options.bitrate) + "k",
            "-maxrate", String(adjustedMaxBitrate) + "k",
        ] + frameRateArgs(options)
        if options.smartQuality ?? false {
            // -q:v 90                   A fixed quality, letting VideoToolbox vary the bitrate within the maximum (Apple Silicon only).
            encoderOptions += ["-q:v", "90"]
        } else {
            encoderOptions += ["-b:v", String(options.bitrate) + "k"]
        }
        return encoderOptions
    }
}

/// Raspberry Pi: the V4L2 memory-to-memory encoder.
public struct RaspberryPiBackend: BaseHwAccelBackend {
    let ctx: HwAccelContext

    public init(_ ctx: HwAccelContext) {
        self.ctx = ctx
    }

    // The FFmpeg codec driver struggles with hardware HKSV recordings on the Pi: those use libx264.
    public var hksvUsesStreamEncoder: Bool { false }

    // The Pi's GPU handles no more than 1080p when transcoding in hardware.
    public var maxTranscodePixels: Int { 1920 * 1080 }

    public func configureDecoding(_ config: inout FfmpegOptionsConfig) -> Bool {
        // Below the minimum GPU memory, back to software.
        if ctx.codecSupport.gpuMem < RPI_GPU_MINIMUM {
            ctx.log.info(
                "Disabling hardware-accelerated \(accelCategories(config)). Adjust the GPU memory configuration on your Raspberry Pi to at least \(RPI_GPU_MINIMUM) MB to enable it."
            )
            config.hardwareDecoding = false
            config.hardwareTranscoding = false
            return false
        }
        // Hardware decoding is flaky on the Pi as of FFmpeg 7: software decoding.
        config.hardwareDecoding = false
        return true
    }

    public func configureTranscoding(_ config: inout FfmpegOptionsConfig) -> String {
        _ = validateEncoder("h264_v4l2m2m", &config)
        return "Raspberry Pi hardware acceleration will be used for livestreaming. "
            + "HomeKit Secure Video recordings are not supported by the hardware encoder and will use software transcoding instead"
    }

    // libfdk_aac for audio encoding.
    public func audioEncoder(_ codec: AudioRecordingCodecType?) -> [String] { defaultAudioEncoder(codec) }

    public func decoderArgs(_ codec: HwAccelVideoCodec) -> [String] { [] }
    public func deviceInitArgs() -> [String] { [] }
    public func downloadFilters() -> [String] { [] }

    // The Pi's encoder prefers yuv420p.
    public func uploadFilters() -> [String] { ["format=yuv420p"] }

    public func scaleFilters(_ options: VideoEncoderOptions, swScale: String) -> [String] { [swScale] }

    public func streamEncoderArgs(_ options: VideoEncoderOptions, videoFilters: String, adjustedMaxBitrate: Int) -> [String] {
        // -codec:v h264_v4l2m2m         The Raspberry Pi hardware encoder, with a numeric profile.
        // -b:v                          Average bitrate: v4l2m2m has no quality target.
        [
            "-codec:v", "h264_v4l2m2m", "-profile:v", h264ProfileArg(options.profile, numeric: true), "-bf", "0", "-noautoscale",
            "-reset_timestamps", "1", "-filter:v", videoFilters, "-b:v", String(options.bitrate) + "k",
            "-g:v", String(options.fps * options.idrInterval), "-bufsize", String(2 * options.bitrate) + "k",
            "-maxrate", String(adjustedMaxBitrate) + "k",
        ] + frameRateArgs(options)
    }
}

/// Generic hosts: hardware acceleration only with Intel Quick Sync Video, software otherwise.
public struct QuickSyncBackend: BaseHwAccelBackend {
    let ctx: HwAccelContext

    public init(_ ctx: HwAccelContext) {
        self.ctx = ctx
    }

    // libfdk_aac for audio encoding.
    public func audioEncoder(_ codec: AudioRecordingCodecType?) -> [String] { defaultAudioEncoder(codec) }

    private static func qsvDecoder(_ codec: HwAccelVideoCodec) -> String {
        switch codec {
        case .av1: "av1_qsv"
        case .h264: "h264_qsv"
        case .hevc: "hevc_qsv"
        }
    }

    public func configureDecoding(_ config: inout FfmpegOptionsConfig) -> Bool {
        // Software decoding unless transcoding finds Quick Sync below.
        config.hardwareDecoding = false
        return true
    }

    public func configureTranscoding(_ config: inout FfmpegOptionsConfig) -> String {
        let codecSupport = ctx.codecSupport
        if codecSupport.hasHwAccel("qsv") && codecSupport.hasDecoder("h264", "h264_qsv") && codecSupport.hasEncoder("h264", "h264_qsv")
            && codecSupport.hasDecoder("hevc", "hevc_qsv")
        {
            config.hardwareDecoding = true
            return "Intel Quick Sync Video"
        }
        config.hardwareDecoding = false
        config.hardwareTranscoding = false
        return ""
    }

    public func decoderArgs(_ codec: HwAccelVideoCodec) -> [String] {
        // -hwaccel qsv -hwaccel_output_format qsv -codec:v X_qsv. AV1 needs an 11th generation Intel CPU or later.
        if codec == .av1 && ctx.codecSupport.cpuGeneration < 11 { return [] }
        return ["-hwaccel", "qsv", "-hwaccel_output_format", "qsv", "-codec:v", Self.qsvDecoder(codec)]
    }

    public func deviceInitArgs() -> [String] {
        ["-init_hw_device", "qsv=hw", "-filter_hw_device", "hw"]
    }

    public func downloadFilters() -> [String] { ["hwdownload"] }
    public func uploadFilters() -> [String] { ["hwupload"] }

    public func scaleFilters(_ options: VideoEncoderOptions, swScale: String) -> [String] {
        guard options.hardwareTranscoding ?? false else { return [swScale] }
        // vpp_qsv: scale on the GPU, keeping the pixel format.
        return [
            "vpp_qsv=" + [
                "format=same",
                "w=min(iw\\, (iw / ih) * " + String(options.height) + ")",
                "h=min(ih\\, " + String(options.height) + ")",
            ].joined(separator: ":")
        ]
    }

    public func streamEncoderArgs(_ options: VideoEncoderOptions, videoFilters: String, adjustedMaxBitrate: Int) -> [String] {
        // -codec:v h264_qsv             The Quick Sync Video encoder; -level:v 0 lets it choose the level.
        var encoderOptions = [
            "-codec:v", "h264_qsv", "-profile:v", h264ProfileArg(options.profile), "-level:v", "0", "-bf", "0", "-noautoscale",
            "-filter:v", videoFilters, "-g:v", String(options.fps * options.idrInterval),
            "-bufsize", String(2 * options.bitrate) + "k", "-maxrate", String(adjustedMaxBitrate) + "k",
        ] + frameRateArgs(options)
        if options.smartQuality ?? false {
            // -global_quality 20        Intelligent constant quality within the maximum bitrate.
            encoderOptions += ["-global_quality", "20"]
        } else {
            encoderOptions += ["-b:v", String(options.bitrate) + "k"]
        }
        return encoderOptions
    }
}

/// The backend for the host system our codec support reports.
public func createHwAccelBackend(_ ctx: HwAccelContext) -> any HwAccelBackend {
    switch ctx.codecSupport.hostSystem {
    case "macOS.Apple": VideoToolboxBackend(ctx, appleSilicon: true)
    case "macOS.Intel": VideoToolboxBackend(ctx, appleSilicon: false)
    case "raspbian": RaspberryPiBackend(ctx)
    default: QuickSyncBackend(ctx)
    }
}
