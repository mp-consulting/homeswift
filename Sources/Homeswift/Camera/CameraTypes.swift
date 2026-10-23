import Foundation

// The camera API, named after HAP-NodeJS's (camera/RTPStreamManagement.ts, camera/RecordingManagement.ts,
// controller/CameraController.ts) so a Homebridge camera plugin maps one to one. Raw values are the TLV values.

// MARK: Streaming

public enum VideoCodecType: UInt8, Sendable, Codable {
    case h264 = 0
}

public enum H264Profile: UInt8, Sendable, Codable, CaseIterable {
    case baseline = 0
    case main = 1
    case high = 2
}

public enum H264Level: UInt8, Sendable, Codable, CaseIterable {
    case level3_1 = 0
    case level3_2 = 1
    case level4_0 = 2
}

public enum VideoCodecPacketizationMode: UInt8, Sendable, Codable {
    case nonInterleaved = 0
}

public enum AudioBitrate: UInt8, Sendable, Codable {
    case variable = 0
    case constant = 1
}

/// The sample rate as it travels in the streaming TLVs.
public enum AudioSamplerate: UInt8, Sendable, Codable {
    case khz8 = 0
    case khz16 = 1
    case khz24 = 2
}

public enum SRTPCryptoSuite: UInt8, Sendable, Codable {
    case aesCM128HMACSHA1_80 = 0
    case aesCM256HMACSHA1_80 = 1
    case none = 2
}

public enum AudioStreamingCodecType: String, Sendable, Codable {
    case pcmu = "PCMU"
    case pcma = "PCMA"
    case aacELD = "AAC-eld"
    case opus = "OPUS"
    case msbc = "mSBC"
    case amr = "AMR"
    case amrWB = "AMR-WB"

    /// The value in the TLVs.
    var tlvValue: UInt8 {
        switch self {
        case .pcmu: 0
        case .pcma: 1
        case .aacELD: 2
        case .opus: 3
        case .msbc: 4
        case .amr: 5
        case .amrWB: 6
        }
    }

    init?(tlvValue: UInt8) {
        switch tlvValue {
        case 0: self = .pcmu
        case 1: self = .pcma
        case 2: self = .aacELD
        case 3: self = .opus
        case 4: self = .msbc
        case 5: self = .amr
        case 6: self = .amrWB
        default: return nil
        }
    }
}

/// A sample rate in kHz, as plugins give them.
public enum AudioStreamingSamplerate: Int, Sendable, Codable {
    case khz8 = 8
    case khz16 = 16
    case khz24 = 24

    var tlvValue: AudioSamplerate {
        switch self {
        case .khz8: .khz8
        case .khz16: .khz16
        case .khz24: .khz24
        }
    }
}

/// A resolution the camera offers: width, height and frames per second.
public struct VideoResolution: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(_ width: Int, _ height: Int, _ fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }
}

public struct H264CodecParameters: Sendable, Equatable {
    public var profiles: [H264Profile]
    public var levels: [H264Level]

    public init(profiles: [H264Profile], levels: [H264Level]) {
        self.profiles = profiles
        self.levels = levels
    }
}

public struct VideoStreamingOptions: Sendable {
    public var codec: H264CodecParameters
    public var resolutions: [VideoResolution]
    /// The RTP header extension id for coordination of video orientation, when the camera supports it.
    public var cvoId: Int?

    public init(codec: H264CodecParameters, resolutions: [VideoResolution], cvoId: Int? = nil) {
        self.codec = codec
        self.resolutions = resolutions
        self.cvoId = cvoId
    }
}

public struct AudioStreamingCodec: Sendable {
    public var type: AudioStreamingCodecType
    public var audioChannels: Int
    public var bitrate: AudioBitrate
    public var samplerate: [AudioStreamingSamplerate]

    public init(type: AudioStreamingCodecType, audioChannels: Int = 1, bitrate: AudioBitrate = .variable, samplerate: [AudioStreamingSamplerate]) {
        self.type = type
        self.audioChannels = audioChannels
        self.bitrate = bitrate
        self.samplerate = samplerate
    }
}

public struct AudioStreamingOptions: Sendable {
    public var codecs: [AudioStreamingCodec]
    /// Adds a Speaker service: the Home app offers to talk through the camera.
    public var twoWayAudio: Bool
    public var comfortNoise: Bool

    public init(codecs: [AudioStreamingCodec], twoWayAudio: Bool = false, comfortNoise: Bool = false) {
        self.codecs = codecs
        self.twoWayAudio = twoWayAudio
        self.comfortNoise = comfortNoise
    }
}

public struct CameraStreamingOptions: Sendable {
    public var supportedCryptoSuites: [SRTPCryptoSuite]
    public var video: VideoStreamingOptions
    /// Without audio, the camera offers a fake Opus codec (HomeKit wants one) and no Microphone service.
    public var audio: AudioStreamingOptions?

    public init(supportedCryptoSuites: [SRTPCryptoSuite] = [.aesCM128HMACSHA1_80], video: VideoStreamingOptions, audio: AudioStreamingOptions? = nil) {
        self.supportedCryptoSuites = supportedCryptoSuites
        self.video = video
        self.audio = audio
    }
}

/// Why HomeKit asks for a snapshot (sent by controllers that support the operating mode).
public enum ResourceRequestReason: Int, Sendable {
    case periodic = 0
    case event = 1
}

public struct SnapshotRequest: Sendable, Equatable {
    public var height: Int
    public var width: Int
    public var reason: ResourceRequestReason?

    public init(height: Int, width: Int, reason: ResourceRequestReason? = nil) {
        self.height = height
        self.width = width
        self.reason = reason
    }
}

public enum IPAddressVersion: String, Sendable {
    case ipv4
    case ipv6
}

/// What the controller sent in Setup Endpoints: where to send each stream and its SRTP keys.
public struct PrepareStreamRequest: Sendable {
    public struct Source: Sendable {
        /// The controller's port for this stream.
        public var port: Int
        public var srtpCryptoSuite: SRTPCryptoSuite
        public var srtpKey: Data
        public var srtpSalt: Data
    }

    public var sessionID: String
    /// The accessory's address on the controller's connection.
    public var sourceAddress: String
    /// The controller's address.
    public var targetAddress: String
    public var addressVersion: IPAddressVersion
    public var video: Source
    public var audio: Source
}

/// The plugin's answer to `prepareStream`: where the controller sends RTCP and return audio, and the SSRCs.
public struct PrepareStreamResponse: Sendable {
    public struct Stream: Sendable {
        /// The local port the accessory listens on for this stream (RTCP, and return audio for audio).
        public var port: Int
        public var ssrc: UInt32
        /// Required unless the crypto suite is `.none`; usually the controller's own key and salt.
        public var srtpKey: Data?
        public var srtpSalt: Data?

        public init(port: Int, ssrc: UInt32, srtpKey: Data? = nil, srtpSalt: Data? = nil) {
            self.port = port
            self.ssrc = ssrc
            self.srtpKey = srtpKey
            self.srtpSalt = srtpSalt
        }
    }

    /// An address to announce instead of the one the controller connected to.
    public var addressOverride: String?
    public var video: Stream
    /// Required when the camera has audio.
    public var audio: Stream?

    public init(addressOverride: String? = nil, video: Stream, audio: Stream? = nil) {
        self.addressOverride = addressOverride
        self.video = video
        self.audio = audio
    }
}

/// The video of a started stream (HAP-NodeJS's `VideoInfo`).
public struct VideoInfo: Sendable, Equatable {
    public var codec: UInt8
    public var profile: UInt8
    public var level: UInt8
    public var packetizationMode: UInt8
    public var cvoId: Int?
    public var width: Int
    public var height: Int
    public var fps: Int
    /// The RTP payload type, usually 99.
    public var pt: Int
    public var ssrc: UInt32
    /// kbit/s.
    public var maxBitRate: Int
    /// Seconds.
    public var rtcpInterval: Float
    public var mtu: Int
}

/// The audio of a started stream (HAP-NodeJS's `AudioInfo`).
public struct AudioInfo: Sendable, Equatable {
    public var codec: AudioStreamingCodecType
    public var channel: Int
    public var bitRate: AudioBitrate
    /// kHz: 8, 16 or 24.
    public var sampleRate: Int
    /// Milliseconds of audio per packet.
    public var packetTime: Int
    /// The RTP payload type, usually 110.
    public var pt: Int
    public var ssrc: UInt32
    public var maxBitRate: Int
    public var rtcpInterval: Float
    /// The comfort noise payload type, usually 13.
    public var comfortPT: Int
    public var comfortNoiseEnabled: Bool
}

public struct ReconfiguredVideoInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var maxBitRate: Int
    public var rtcpInterval: Float
}

public struct StartStreamRequest: Sendable, Equatable {
    public var sessionID: String
    public var video: VideoInfo
    public var audio: AudioInfo
}

public struct ReconfigureStreamRequest: Sendable, Equatable {
    public var sessionID: String
    public var video: ReconfiguredVideoInfo
}

/// HAP-NodeJS's `StreamingRequest`.
public enum StreamingRequest: Sendable, Equatable {
    case start(StartStreamRequest)
    case reconfigure(ReconfigureStreamRequest)
    case stop(sessionID: String)

    public var sessionID: String {
        switch self {
        case .start(let request): request.sessionID
        case .reconfigure(let request): request.sessionID
        case .stop(let sessionID): sessionID
        }
    }
}

/// What a camera plugin implements for live streams and snapshots (HAP-NodeJS's `CameraStreamingDelegate`,
/// with async functions instead of callbacks). Throw `HAPStatusError` to report a specific status.
public protocol CameraStreamingDelegate: AnyObject, Sendable {
    /// A JPEG of about the requested size. HomeKit gives up after about 25 seconds.
    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data
    /// Reserve ports and say where the controller sends RTCP and return audio.
    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse
    /// Start (FFmpeg towards the controller), reconfigure or stop a prepared stream.
    func handleStreamRequest(_ request: StreamingRequest) async throws
}

// MARK: Recording (HomeKit Secure Video)

public enum EventTriggerOption: Int, Sendable, Codable, CaseIterable {
    case motion = 0x01
    case doorbell = 0x02
}

public enum MediaContainerType: UInt8, Sendable, Codable {
    case fragmentedMP4 = 0
}

public enum AudioRecordingCodecType: UInt8, Sendable, Codable {
    case aacLC = 0
    case aacELD = 1
}

public enum AudioRecordingSamplerate: UInt8, Sendable, Codable {
    case khz8 = 0
    case khz16 = 1
    case khz24 = 2
    case khz32 = 3
    case khz44_1 = 4
    case khz48 = 5
}

public struct MediaContainerConfiguration: Sendable, Equatable, Codable {
    public var type: MediaContainerType
    /// Milliseconds; HomeKit only accepts 4000.
    public var fragmentLength: Int

    public init(type: MediaContainerType = .fragmentedMP4, fragmentLength: Int) {
        self.type = type
        self.fragmentLength = fragmentLength
    }
}

public struct VideoRecordingOptions: Sendable {
    public var type: VideoCodecType
    public var parameters: H264CodecParameters
    public var resolutions: [VideoResolution]

    public init(type: VideoCodecType = .h264, parameters: H264CodecParameters, resolutions: [VideoResolution]) {
        self.type = type
        self.parameters = parameters
        self.resolutions = resolutions
    }
}

public struct AudioRecordingCodec: Sendable {
    public var type: AudioRecordingCodecType
    public var audioChannels: Int
    public var bitrateMode: AudioBitrate
    public var samplerate: [AudioRecordingSamplerate]

    public init(type: AudioRecordingCodecType, audioChannels: Int = 1, bitrateMode: AudioBitrate = .variable, samplerate: [AudioRecordingSamplerate]) {
        self.type = type
        self.audioChannels = audioChannels
        self.bitrateMode = bitrateMode
        self.samplerate = samplerate
    }
}

public struct CameraRecordingOptions: Sendable {
    /// Milliseconds of video kept before an event (at least 4000).
    public var prebufferLength: Int
    /// Event triggers to offer besides those the sensors imply (motion with a motion sensor, doorbell for a doorbell).
    public var overrideEventTriggerOptions: [EventTriggerOption]
    public var mediaContainerConfiguration: [MediaContainerConfiguration]
    public var video: VideoRecordingOptions
    public var audio: [AudioRecordingCodec]

    public init(
        prebufferLength: Int, overrideEventTriggerOptions: [EventTriggerOption] = [], mediaContainerConfiguration: [MediaContainerConfiguration],
        video: VideoRecordingOptions, audio: [AudioRecordingCodec]
    ) {
        self.prebufferLength = prebufferLength
        self.overrideEventTriggerOptions = overrideEventTriggerOptions
        self.mediaContainerConfiguration = mediaContainerConfiguration
        self.video = video
        self.audio = audio
    }
}

/// The recording settings HomeKit selected (HAP-NodeJS's `CameraRecordingConfiguration`).
public struct CameraRecordingConfiguration: Sendable, Equatable {
    public struct VideoParameters: Sendable, Equatable {
        public var profile: H264Profile
        public var level: H264Level
        /// kbit/s.
        public var bitRate: Int
        /// Milliseconds.
        public var iFrameInterval: Int
    }

    public struct VideoCodec: Sendable, Equatable {
        public var type: VideoCodecType
        public var parameters: VideoParameters
        public var resolution: VideoResolution
    }

    public struct AudioCodec: Sendable, Equatable {
        public var audioChannels: Int
        public var type: AudioRecordingCodecType
        public var samplerate: AudioRecordingSamplerate
        public var bitrateMode: AudioBitrate
        /// kbit/s.
        public var bitrate: Int
    }

    public var prebufferLength: Int
    public var eventTriggerTypes: [EventTriggerOption]
    public var mediaContainerConfiguration: MediaContainerConfiguration
    public var videoCodec: VideoCodec
    public var audioCodec: AudioCodec
}

/// One fragment of a recording: the initialization segment (`ftyp` + `moov`) first, then `moof` + `mdat` pairs.
public struct RecordingPacket: Sendable {
    public var data: Data
    /// Set on the last fragment of the recording.
    public var isLast: Bool

    public init(data: Data, isLast: Bool = false) {
        self.data = data
        self.isLast = isLast
    }
}

/// HAP-NodeJS's `HDSProtocolSpecificErrorReason`: why a data stream transfer is closed or refused.
public enum HDSProtocolSpecificErrorReason: Int, Sendable, Error {
    case normal = 0
    case notAllowed = 1
    case busy = 2
    case cancelled = 3
    case unsupported = 4
    case unexpectedFailure = 5
    case timeout = 6
    case badData = 7
    case protocolError = 8
    case invalidConfiguration = 9
}

/// Thrown by a recording stream to close it with a reason (HAP-NodeJS's `HDSProtocolError`).
public struct HDSProtocolError: Error, Sendable {
    public let reason: HDSProtocolSpecificErrorReason
    public init(_ reason: HDSProtocolSpecificErrorReason) { self.reason = reason }
}

/// What a camera plugin implements for HomeKit Secure Video (HAP-NodeJS's `CameraRecordingDelegate`).
public protocol CameraRecordingDelegate: AnyObject, Sendable {
    /// Recording turned on or off in the Home app (also replayed at launch from the saved state).
    func updateRecordingActive(_ active: Bool)
    /// HomeKit selected recording settings, or nil after a reset.
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?)
    /// A home hub asks for a recording, typically after a motion event: return the fragments, prebuffer first,
    /// and mark the last one `isLast`. The stream is cancelled (its `onTermination` runs) when the hub closes it;
    /// finish with `HDSProtocolError` to close it with a reason.
    func handleRecordingStreamRequest(streamID: Int) -> AsyncThrowingStream<RecordingPacket, any Error>
    /// The hub acknowledged the end of the stream.
    func acknowledgeStream(streamID: Int)
    /// The stream was closed, by the hub (with its reason) or because the connection dropped (nil).
    func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?)
}

extension CameraRecordingDelegate {
    public func acknowledgeStream(streamID: Int) {}
}
