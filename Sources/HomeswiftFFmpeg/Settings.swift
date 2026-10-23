// Settings and constants for the HomeKit FFmpeg utilities, with the names of homebridge-plugin-utils' settings.ts so a
// ported plugin keeps its references. Durations are in milliseconds unless the name says otherwise.

/// HomeKit prefers an I-frame interval of 5 seconds when livestreaming.
public let HOMEKIT_IDR_INTERVAL = 5

/// Additional headroom (kbit/s) beyond the bitrate HomeKit requests when streaming: better quality for a minor bandwidth cost.
public let HOMEKIT_STREAMING_HEADROOM = 64

/// HomeKit Secure Video fragment length, in milliseconds. HomeKit only supports this value.
public let HKSV_FRAGMENT_LENGTH = 4000

/// HomeKit prefers an I-frame interval of 4 seconds for HKSV event recordings.
public let HKSV_IDR_INTERVAL = 4

/// HomeKit Secure Video communication timeout, in milliseconds: HKSV allows 5 seconds, so a little below that.
public let HKSV_TIMEOUT = 4500

/// FFmpeg's default input timeout, in milliseconds: FFmpeg ends inputs that receive nothing for this long. The SIGKILL failsafe of
/// `FfmpegProcess` and the stream health monitor of `FfmpegStreamingProcess` are coordinated with it.
public let FFMPEG_INPUT_TIMEOUT = 5000

/// Minimum GPU memory (MB) on a Raspberry Pi to enable hardware acceleration.
public let RPI_GPU_MINIMUM = 128
