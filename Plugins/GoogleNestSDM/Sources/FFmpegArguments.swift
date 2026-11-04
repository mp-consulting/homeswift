import Foundation
import Homeswift

/// FFmpeg's command lines for live streams and recordings (sections 6.4 and 6.7), as argv: no shell is involved.
enum FFmpegArguments {
    /// Where the stream goes: HomeKit's controller and the keys it gave.
    struct Target: Sendable, Equatable {
        var address: String
        var videoPort: Int
        /// Key and salt, 30 bytes.
        var videoSRTP: Data
        var videoSSRC: UInt32
        var audioPort: Int
        var audioSRTP: Data
        var audioSSRC: UInt32
    }

    /// Reading the SDM stream: an RTSP device's `rtsps://` URL.
    static func input(rtspURL: String, options: NestOptions) -> [String] {
        ["-analyzeduration", "\(options.analyzeDuration)", "-probesize", "\(options.probeSize)", "-i", rtspURL]
    }

    /// The scaling filter for a requested size; nil when HomeKit asked for none (the Homebridge plugin then leaves an empty
    /// `-filter:v`, which swallows the next option).
    static func filter(width: Int, height: Int) -> String? {
        guard width > 0 || height > 0 else { return nil }
        let w = width > 0 ? "'min(\(width),iw)'" : "iw"
        let h = height > 0 ? "'min(\(height),ih)'" : "ih"
        return "scale=\(w):\(h):force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }

    /// The live stream: the input, video to HomeKit's video port and, when FFmpeg has an AAC-ELD encoder
    /// (`audioEncoder`), audio to its audio port, both SRTP.
    static func live(input: [String], request: StartStreamRequest, target: Target, options: NestOptions, audioEncoder: [String]?) -> [String] {
        let video = request.video
        var arguments = input
        arguments += ["-an", "-sn", "-dn", "-codec:v"] + options.encoder + ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-color_range", "mpeg"]
        if !options.copiesVideo {
            let bitrate = video.maxBitRate * 4
            arguments += ["-bf", "0", "-r", "\(video.fps)", "-b:v", "\(bitrate)k", "-bufsize", "\(bitrate)k", "-maxrate", "\(bitrate * 2)k"]
            if let filter = filter(width: video.width, height: video.height) { arguments += ["-filter:v", filter] }
        }
        arguments += [
            "-payload_type", "\(video.pt)", "-ssrc", "\(target.videoSSRC)", "-f", "rtp",
            "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.videoSRTP.base64EncodedString(),
            "srtp://\(target.address):\(target.videoPort)?rtcpport=\(target.videoPort)&pkt_size=\(video.mtu)",
        ]
        if let audioEncoder {
            let audio = request.audio
            arguments += ["-vn", "-sn", "-dn"] + audioEncoder + [
                "-flags", "+global_header", "-ar", "\(audio.sampleRate)k", "-b:a", "\(audio.maxBitRate)k", "-ac", "\(audio.channel)",
                "-payload_type", "\(audio.pt)", "-ssrc", "\(target.audioSSRC)", "-f", "rtp",
                "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", target.audioSRTP.base64EncodedString(),
                "srtp://\(target.address):\(target.audioPort)?rtcpport=\(target.audioPort)&pkt_size=188",
            ]
        }
        if options.debug { arguments += ["-loglevel", "level+verbose"] }
        return arguments
    }

    struct UnsupportedRecording: Error, CustomStringConvertible {
        var description: String
    }

    /// A recording: H.264 as HomeKit chose it (always libx264, whatever `vEncoder` says) and its audio, as fragmented MP4 on
    /// standard output. Unlike the Homebridge plugin's, whose `-an` drops it, the recording has its audio track when FFmpeg
    /// can encode it (`audioEncoder`: the codec and its profile).
    static func recording(input: [String], configuration: CameraRecordingConfiguration, audioEncoder: [String]?) throws -> [String] {
        let video = configuration.videoCodec
        guard video.type == .h264 else { throw UnsupportedRecording(description: "the recording's codec is not H.264") }
        let rates: [AudioRecordingSamplerate: String] = [.khz8: "8", .khz16: "16", .khz24: "24", .khz32: "32", .khz44_1: "44.1", .khz48: "48"]
        let audio = configuration.audioCodec
        guard let sampleRate = rates[audio.samplerate] else { throw UnsupportedRecording(description: "unsupported sample rate") }
        var arguments = input
        if let audioEncoder {
            arguments += audioEncoder + [
                "-ar", "\(sampleRate)k", "-b:a", "\(audio.bitrate)k", "-ac", "\(audio.audioChannels)",
            ]
        } else {
            arguments += ["-an"]
        }
        let profile = [H264Profile.high: "high", .main: "main"][video.parameters.profile] ?? "baseline"
        let level = [H264Level.level4_0: "4.0", .level3_2: "3.2"][video.parameters.level] ?? "3.1"
        let interval = Double(video.parameters.iFrameInterval) / 1000
        let seconds = interval == interval.rounded() ? String(Int(interval)) : String(interval)
        arguments += [
            "-sn", "-dn", "-codec:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", profile, "-level:v", level,
            "-b:v", "\(video.parameters.bitRate)k", "-force_key_frames", "expr:eq(t,n_forced*\(seconds))", "-r", "\(video.resolution.fps)",
            "-fflags", "+genpts", "-reset_timestamps", "1", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1",
        ]
        return arguments
    }

    /// One JPEG frame of a clip preview (an MP4 of a few frames) on standard input.
    static let clipFrame = ["-hide_banner", "-i", "pipe:0", "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "pipe:1"]
}
