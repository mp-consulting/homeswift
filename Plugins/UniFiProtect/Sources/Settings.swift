import Foundation

/// The constants of `homebridge-unifi-protect` (settings.ts), with the same values. Durations keep the unit
/// the Homebridge plugin uses for them: seconds where it counts seconds, milliseconds elsewhere.
enum ProtectSettings {
    /// How often, in seconds, the controllers are checked for new or removed devices.
    static let controllerRefreshInterval = 120
    /// How often, in seconds, a failed bootstrap is retried.
    static let controllerRetryInterval = 10
    /// Milliseconds the doorbell's authentication contact sensor stays open.
    static let doorbellAuthSensorDuration = 5000
    /// Milliseconds of a digital physical chime, as Protect configures it.
    static let doorbellChimeDurationDigital = 1000
    /// Milliseconds of a mechanical physical chime, as Protect configures it.
    static let doorbellChimeDurationMechanical = 300
    /// Milliseconds before the chime's buzzer or speaker can be triggered again.
    static let doorbellChimeSpeakerDuration = 3500
    /// Milliseconds a doorbell LCD message shows by default.
    static let doorbellMessageDuration = 60_000
    /// Milliseconds the doorbell trigger switch stays on.
    static let doorbellTriggerDuration = 5000
    /// FFmpeg probesize, in bytes, for standard cameras.
    static let ffmpegProbesize = 16384
    /// FFmpeg probesize, in bytes, for package cameras.
    static let ffmpegProbesizePackage = 32768
    /// Maximum FFmpeg probesize, in bytes, after automatic adjustments.
    static let ffmpegProbesizeMax = 5_000_000
    /// Consecutive probesize adjustments before the override becomes permanent.
    static let ffmpegProbesizeAdjustmentThreshold = 10
    /// Milliseconds before a temporary probesize override resets.
    static let ffmpegProbesizeOverrideTimeout = 600_000
    /// FFmpeg afftdn noise reduction, in decibels.
    static let ffmpegAudioFilterFFTNR = 14
    /// The livestream API's I-frame interval, in seconds.
    static let livestreamAPIIDRInterval = 5
    /// Base backoff, in seconds, when reconnecting a livestream.
    static let livestreamRestartInterval = 10
    /// Milliseconds without a segment before a livestream session is restarted.
    static let livestreamTimeout = 3500
    /// Milliseconds between livestream retries while the controller is offline or throttled.
    static let livestreamOfflineRetryInterval = 60_000
    /// Milliseconds of one fMP4 segment.
    static let segmentResolution = 100
    /// Segments queued for a process that does not keep up before the oldest are dropped: thirty seconds.
    static let segmentQueueMaxLength = (30 * 1000) / segmentResolution
    /// Milliseconds to wait for a livestream's initialization segment.
    static let livestreamInitSegmentTimeout = 2000
    /// How far back, in milliseconds, the HKSV timeshift buffer reaches.
    static let hksvTimeshiftBufferMaxDuration = livestreamAPIIDRInterval * 1000 * 2
    /// Default port of the M3U playlist.
    static let m3uPlaylistPort = 10110
    /// Default seconds of a motion event.
    static let motionDuration = 10
    /// The seconds a duration option may give (motion, occupancy, removal delay): a year at most, so their
    /// timers never overflow.
    static let durationRange = 0...31_536_000
    /// Default MQTT base topic.
    static let mqttTopic = "unifi/protect"
    /// Default seconds of an occupancy event.
    static let occupancyDuration = 300
    /// Maximum age of a cached snapshot, in seconds.
    static let snapshotCacheMaxAge = 90
    /// Seconds a cached snapshot is served without making a new one.
    static let snapshotCacheFreshness = 5
    /// Maximum size, in bytes, of a snapshot from a configured snapshot URL.
    static let snapshotURLMaxSize = 10 * 1024 * 1024
    /// Snapshot budget, in milliseconds (HomeKit allows five seconds).
    static let snapshotTimeout = 4990
    /// Milliseconds each snapshot source leaves for the next one in the fallback chain.
    static let snapshotFallbackReserve = 1750
    /// Largest per-dimension downscale allowed when choosing a source stream for transcoding.
    static let transcodeMaxDownscaleRatio = 2
    /// Kilobits per second when transcoding for local clients.
    static let transcodeBitrate = 2000
    /// Kilobits per second when transcoding for high-latency clients.
    static let transcodeHighLatencyBitrate = 1000
    /// Milliseconds between ambient light polls.
    static let ambientLightPollInterval = 60_000
    /// Milliseconds before a deferred characteristic update, so a write's echo reaches HomeKit.
    static let homeKitUpdateDelay = 50
    /// The lowest ambient light level HomeKit accepts, in lux.
    static let homeKitAmbientLightMinimum = 0.0001
    /// The logo the M3U playlist's guide entries point at.
    static let playlistLogoURL = "https://raw.githubusercontent.com/mp-consulting/homebridge-unifi-protect/main/docs/media/homebridge-unifi-protect-4x3.png"
    /// The file, in the plugin's directory, of the controllers' pinned certificate fingerprints.
    static let tlsPinFile = "unifi-protect-tls-pins.json"
}
