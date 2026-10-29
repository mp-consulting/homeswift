import Homeswift
import Logging

/// How `FfmpegOptions` is set up: codec support, cropping, logging and the hardware acceleration wanted.
///
/// `hardwareDecoding` and `hardwareTranscoding` say what the caller wants; `FfmpegOptions` resolves them against the host and
/// its `config` holds what is available (either may turn off, and `hardwareDecoding` turns on with Intel Quick Sync Video).
public struct FfmpegOptionsConfig: Sendable {
    /// A crop rectangle as fractions of the input: `width`, `height`, `x` and `y` multiply `iw` and `ih`.
    public struct Crop: Sendable, Equatable {
        public var height: Double
        public var width: Double
        public var x: Double
        public var y: Double

        public init(height: Double, width: Double, x: Double, y: Double) {
            self.height = height
            self.width = width
            self.x = x
            self.y = y
        }
    }

    public var codecSupport: FfmpegCodecs
    public var crop: Crop?
    public var debug: Bool
    public var hardwareDecoding: Bool
    public var hardwareTranscoding: Bool
    public var log: Logger
    /// The name for log messages (usually the camera's).
    public var name: @Sendable () -> String
    /// Milliseconds a stream may go without a packet, and a stopped process may take before SIGKILL.
    public var inputTimeout = FFMPEG_INPUT_TIMEOUT
    /// Milliseconds an HKSV recording may go without a box before it ends.
    public var recordingTimeout = HKSV_TIMEOUT

    public init(
        codecSupport: FfmpegCodecs, crop: Crop? = nil, debug: Bool = false, hardwareDecoding: Bool, hardwareTranscoding: Bool, log: Logger,
        name: @escaping @Sendable () -> String
    ) {
        self.codecSupport = codecSupport
        self.crop = crop
        self.debug = debug
        self.hardwareDecoding = hardwareDecoding
        self.hardwareTranscoding = hardwareTranscoding
        self.log = log
        self.name = name
    }
}

/// The audio encoder wanted: AAC-ELD (the default) or AAC-LC.
public struct AudioEncoderOptions: Sendable {
    public var codec: AudioRecordingCodecType?

    public init(codec: AudioRecordingCodecType? = nil) {
        self.codec = codec
    }
}

/// What a video encoder produces: bitrate (kbit/s), frame rates, size, H.264 profile and level, keyframe interval (seconds),
/// and whether smart quality (a capped quality target instead of a fixed bitrate) and hardware acceleration may be used.
/// Optional flags left nil take the defaults of `FfmpegOptions.streamEncoder`.
public struct VideoEncoderOptions: Sendable, Equatable {
    public var bitrate: Int
    public var fps: Int
    public var hardwareDecoding: Bool?
    public var hardwareTranscoding: Bool?
    public var height: Int
    public var idrInterval: Int
    public var inputFps: Int
    public var level: H264Level
    public var profile: H264Profile
    public var smartQuality: Bool?
    public var width: Int

    public init(
        bitrate: Int, fps: Int, hardwareDecoding: Bool? = nil, hardwareTranscoding: Bool? = nil, height: Int, idrInterval: Int, inputFps: Int,
        level: H264Level, profile: H264Profile, smartQuality: Bool? = nil, width: Int
    ) {
        self.bitrate = bitrate
        self.fps = fps
        self.hardwareDecoding = hardwareDecoding
        self.hardwareTranscoding = hardwareTranscoding
        self.height = height
        self.idrInterval = idrInterval
        self.inputFps = inputFps
        self.level = level
        self.profile = profile
        self.smartQuality = smartQuality
        self.width = width
    }
}

/// FFmpeg decoder and encoder arguments for this host: codecs, pixel formats, hardware acceleration (VideoToolbox, Quick Sync
/// Video, Raspberry Pi) with software fallbacks, for livestreaming and HKSV recording.
///
/// ```swift
/// let options = FfmpegOptions(FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: true, hardwareTranscoding: true,
///                                                 log: log, name: { "Front Door" }))
/// let args = options.streamEncoder(VideoEncoderOptions(bitrate: 3000, fps: 30, height: 1080, idrInterval: HOMEKIT_IDR_INTERVAL,
///                                                      inputFps: 30, level: .level4_0, profile: .high, width: 1920))
/// ```
public final class FfmpegOptions: Sendable {
    /// FFmpeg codec and hardware capabilities of the host.
    public let codecSupport: FfmpegCodecs
    /// The configuration, with the hardware acceleration flags resolved against the host.
    public let config: FfmpegOptionsConfig
    public let debug: Bool
    public let log: Logger
    /// The name for log messages.
    public let name: @Sendable () -> String
    /// The audio decoder.
    public let audioDecoder = "libfdk_aac"

    private let hwAccel: any HwAccelBackend

    public init(_ options: FfmpegOptionsConfig) {
        codecSupport = options.codecSupport
        debug = options.debug
        log = options.log
        name = options.name
        hwAccel = createHwAccelBackend(HwAccelContext(codecSupport: options.codecSupport, log: options.log))
        var config = options
        Self.configureHwAccel(&config, hwAccel: hwAccel, log: options.log)
        self.config = config
    }

    // Resolves hardware decoding and transcoding for the host, falling back to software where needed.
    @discardableResult
    private static func configureHwAccel(_ config: inout FfmpegOptionsConfig, hwAccel: any HwAccelBackend, log: Logger) -> Bool {
        var logMessage = ""
        // A backend can stop hardware acceleration entirely (a Raspberry Pi without enough GPU memory).
        if config.hardwareDecoding && !hwAccel.configureDecoding(&config) {
            return false
        }
        if config.hardwareTranscoding {
            logMessage = hwAccel.configureTranscoding(&config)
        }
        if config.hardwareDecoding || config.hardwareTranscoding {
            let categories = hwAccelCategories(hardwareDecoding: config.hardwareDecoding, hardwareTranscoding: config.hardwareTranscoding)
            log.info("⚡️ Hardware-accelerated \(categories) enabled\(logMessage.isEmpty ? "" : ": " + logMessage).")
        }
        return config.hardwareTranscoding
    }

    // The filters that move frames between software and hardware:
    //
    // 1. Software decode -> software encode: nothing.
    // 2. Software decode -> hardware encode: upload to the GPU.
    // 3. Hardware decode -> software encode: download to the CPU.
    // 4. Hardware decode -> hardware encode: nothing.
    private func getHardwareTransferFilters(hardwareDecoding: Bool?, hardwareTranscoding: Bool?) -> [String] {
        let decoding = hardwareDecoding ?? false
        let transcoding = hardwareTranscoding ?? false
        if !decoding && transcoding { return hwAccel.uploadFilters() }
        if decoding && !transcoding { return hwAccel.downloadFilters() }
        return []
    }

    // Hardware encoding without hardware decoding needs the device initialized explicitly; the decoder does it otherwise.
    private func getHardwareDeviceInit(_ options: VideoEncoderOptions) -> [String] {
        !(options.hardwareDecoding ?? false) && (options.hardwareTranscoding ?? false) ? hwAccel.deviceInitArgs() : []
    }

    /// The audio encoder arguments: AAC-ELD unless another codec is asked for. Empty when the host has no AAC encoder.
    public func audioEncoder(_ options: AudioEncoderOptions = AudioEncoderOptions()) -> [String] {
        hwAccel.audioEncoder(options.codec ?? .aacELD)
    }

    // Not in homebridge-unifi-protect: Opus for live streams, when FFmpeg has no AAC-ELD encoder. ffmpeg-for-homeswift
    // (FFmpeg/) leaves out libfdk_aac, whose licence FFmpeg cannot combine with the GPL, and has libopus instead.

    /// Whether FFmpeg has libopus.
    public var hasOpusEncoder: Bool { codecSupport.hasEncoder("opus", "libopus") }

    /// libopus for a live stream: low delay, a frame per packet of `packetTime` milliseconds (Opus has no 30 ms
    /// frames: 20 then).
    public func opusEncoder(packetTime: Int) -> [String] {
        let frame = [60, 40, 20].first { $0 <= packetTime } ?? 20
        // -codec:a libopus             The Opus encoder.
        // -application lowdelay        The lowest-latency mode, for a conversation.
        // -frame_duration              Milliseconds of audio per frame.
        return ["-codec:a", "libopus", "-application", "lowdelay", "-frame_duration", String(frame)]
    }

    /// The video decoder arguments for `av1`, `h264` (the default), `h265` or `hevc`; empty for anything else, or without
    /// hardware decoding.
    public func videoDecoder(_ codec: String = "h264") -> [String] {
        let normalizedCodec: HwAccelVideoCodec
        switch codec.lowercased() {
        case "av1": normalizedCodec = .av1
        case "h264": normalizedCodec = .h264
        case "h265", "hevc": normalizedCodec = .hevc
        default: return []
        }
        return config.hardwareDecoding ? hwAccel.decoderArgs(normalizedCodec) : []
    }

    /// The filters that bring hardware-decoded frames to system memory before CPU filters (crop, scale, format). Empty without
    /// hardware decoding, or where the platform does it implicitly.
    public var hardwareDownloadFilters: [String] {
        getHardwareTransferFilters(hardwareDecoding: config.hardwareDecoding, hardwareTranscoding: false)
    }

    /// The crop filter, or one that keeps the whole frame when cropping is off.
    public var cropFilter: String {
        guard let crop = config.crop else { return "crop=w=iw*100:h=ih*100:x=iw*0:y=ih*0" }
        return "crop=" + [
            "w=iw*" + jsNumber(crop.width),
            "h=ih*" + jsNumber(crop.height),
            "x=iw*" + jsNumber(crop.x),
            "y=ih*" + jsNumber(crop.y),
        ].joined(separator: ":")
    }

    private func getScaleFilter(_ options: VideoEncoderOptions) -> [String] {
        // scale=-2:min(ih\,height)          The requested size, keeping the aspect ratio with even dimensions. Backends may use an
        //                                   accelerated scaler (scale_vt, vpp_qsv) instead.
        let swScale = "scale=-2:min(ih\\, " + String(options.height) + ")" + ":in_range=auto:out_range=auto"
        return getHardwareTransferFilters(hardwareDecoding: options.hardwareDecoding, hardwareTranscoding: options.hardwareTranscoding)
            + hwAccel.scaleFilters(options, swScale: swScale)
    }

    // libx264, for software transcoding.
    private func defaultVideoEncoderOptions(_ options: VideoEncoderOptions) -> [String] {
        // fps=                              The frame rate HomeKit asks for, only when it differs from the input's.
        let fpsFilter = ["fps=" + String(options.fps)]
        // Download from the GPU if we decoded in hardware, then scale.
        let pixelFilters = getHardwareTransferFilters(hardwareDecoding: options.hardwareDecoding, hardwareTranscoding: options.hardwareTranscoding)
            + ["scale=-2:min(ih\\, " + String(options.height) + "):in_range=auto:out_range=auto"]
        // Reducing the frame rate: drop frames first so the other filters do less. Increasing it: filter the source frames, then duplicate.
        let videoFilters = options.fps < options.inputFps
            ? fpsFilter + pixelFilters
            : pixelFilters + (options.fps > options.inputFps ? fpsFilter : [])
        let smartQuality = options.smartQuality ?? false

        // -codec:v libx264                  The libx264 H.264 encoder.
        // -preset veryfast                  A good balance of speed and quality.
        // -profile:v / -level:v             The H.264 profile and level HomeKit requests.
        // -noautoscale                      Don't scale automatically.
        // -bf 0                             No B-frames, for finicky HomeKit clients.
        // -filter:v                         Pixel format, frame rate and scaling.
        // -g:v                              Frames per second times the keyframe interval.
        // -bufsize / -maxrate               Bound the bitrate, with some headroom for smart quality.
        var encoderOptions = [
            "-codec:v", "libx264",
            "-preset", "veryfast",
            "-profile:v", h264ProfileArg(options.profile),
            "-level:v", h264LevelArg(options.level),
            "-noautoscale",
            "-bf", "0",
            "-filter:v", videoFilters.joined(separator: ", "),
            "-g:v", String(options.fps * options.idrInterval),
            "-bufsize", String(2 * options.bitrate) + "k",
            "-maxrate", String(options.bitrate + (smartQuality ? HOMEKIT_STREAMING_HEADROOM : 0)) + "k",
        ]
        if smartQuality {
            // -crf 20                         A capped constant rate factor: quality varies within the maximum bitrate.
            encoderOptions += ["-crf", "20"]
        } else {
            // HKSV is latency sensitive and particular about bitrates: a fixed average bitrate.
            encoderOptions += ["-b:v", String(options.bitrate) + "k"]
        }
        return encoderOptions
    }

    /// The video encoder arguments for HomeKit Secure Video recordings. Smart quality is always off: HKSV is strict about bitrates.
    public func recordEncoder(_ options: VideoEncoderOptions) -> [String] {
        var options = options
        options.smartQuality = false
        return hwAccel.hksvUsesStreamEncoder ? streamEncoder(options) : defaultVideoEncoderOptions(options)
    }

    /// The video encoder arguments for livestreaming. Hardware decoding and smart quality default to on, hardware transcoding to
    /// the configuration; neither hardware flag can turn on what the host does not have.
    public func streamEncoder(_ options: VideoEncoderOptions) -> [String] {
        var options = options
        options.hardwareDecoding = options.hardwareDecoding ?? true
        options.hardwareTranscoding = options.hardwareTranscoding ?? config.hardwareTranscoding
        options.smartQuality = options.smartQuality ?? true
        if !config.hardwareDecoding { options.hardwareDecoding = false }
        if !config.hardwareTranscoding { options.hardwareTranscoding = false }
        guard options.hardwareTranscoding == true else { return defaultVideoEncoderOptions(options) }

        // The maximum bitrate, with some headroom for quality variations.
        let adjustedMaxBitrate = options.bitrate + (options.smartQuality == true ? HOMEKIT_STREAMING_HEADROOM : 0)
        // crop (when configured), then the platform's scaling, which handles any hardware transfer.
        let videoFilters = (config.crop != nil ? [cropFilter] : []) + getScaleFilter(options)
        return getHardwareDeviceInit(options) + hwAccel.streamEncoderArgs(options, videoFilters: videoFilters.joined(separator: ", "), adjustedMaxBitrate: adjustedMaxBitrate)
    }

    /// The most pixels the hardware encoder supports, `Int.max` (TypeScript's `Infinity`) when not limited.
    public var hostSystemMaxPixels: Int {
        config.hardwareTranscoding ? hwAccel.maxTranscodePixels : Int.max
    }
}

/// A number as JavaScript prints it: `1` for 1.0, `0.75`, `0.1`, `100000000000000000000` for 1e20.
func jsNumber(_ value: Double) -> String {
    guard value.isFinite, value == value.rounded(), abs(value) < 1e21 else { return String(value) }
    if let integer = Int64(exactly: value) {
        return String(integer)
    }
    // Beyond Int64 JavaScript still prints integers in full: the shortest round-trip digits, then zeros. Swift's description has
    // the same digits, in exponent form ("9.223372036854776e+18").
    let description = String(value)
    guard let exponentIndex = description.firstIndex(of: "e"), let exponent = Int(description[description.index(after: exponentIndex)...]) else {
        return description
    }
    let mantissa = description[..<exponentIndex]
    let sign = mantissa.hasPrefix("-") ? "-" : ""
    let unsigned = mantissa.drop { $0 == "-" }
    let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let fraction = parts.count > 1 ? parts[1] : ""
    let zeros = exponent - fraction.count
    guard zeros >= 0 else { return description }
    return sign + parts[0] + fraction + String(repeating: "0", count: zeros)
}
