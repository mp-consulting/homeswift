import Foundation
import Homeswift
import HomeswiftFFmpeg

/// The FFmpeg command lines of homebridge-camera-ffmpeg (docs/clean-room/CameraFFmpeg.md, sections 7 and 9). Users write
/// several options in one string (`source`, `encoderOptions`, `videoFilter`…), so each command but the recording's and the
/// prebuffer's is built as one string and split on whitespace, as the original does: a value cannot hold a space. Unlike
/// the original, empty tokens (a `source` with a leading space) are dropped rather than passed to FFmpeg.
enum FFmpegArguments {
    /// The tokens of a string split on runs of whitespace, empty ones dropped.
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The prebuffer's split: on single spaces (section 9.3), empty tokens dropped.
    static func splitOnSpaces(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    // MARK: Sizes and filters (7.1)

    struct Filters: Equatable {
        /// The size asked for, after the caps; 0 keeps the source's.
        var width: Int
        var height: Int
        /// The user's filters with the scaling ones, joined by commas; nil when there are none.
        var videoFilter: String?
        /// The user's filters alone, for a snapshot's fetch; "" when there are none.
        var snapFilter: String
        /// The first scaling filter, for a snapshot's resize.
        var resizeFilter: String?
    }

    static func filters(_ video: CameraFFmpegPlugin.VideoConfig, width: Int, height: Int, snapshot: Bool) -> Filters {
        var w = width
        var h = height
        if !snapshot {
            if let maxWidth = video.maxWidth, video.forceMax || width > maxWidth { w = maxWidth }
            if let maxHeight = video.maxHeight, video.forceMax || height > maxHeight { h = maxHeight }
        }
        var filters = video.videoFilter.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) } ?? []
        var none = false
        if let index = filters.firstIndex(of: "none") {
            filters.remove(at: index)
            none = true
        }
        let snapFilter = filters.joined(separator: ",")
        var resizeFilter: String?
        if !none, w > 0 || h > 0 {
            let a = w > 0 ? "'min(\(w),iw)'" : "iw"
            let b = h > 0 ? "'min(\(h),ih)'" : "ih"
            let resize = "scale=\(a):\(b):force_original_aspect_ratio=decrease"
            resizeFilter = resize
            filters += [resize, "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        }
        return Filters(width: w, height: h, videoFilter: filters.isEmpty ? nil : filters.joined(separator: ","), snapFilter: snapFilter, resizeFilter: resizeFilter)
    }

    // MARK: Snapshots (7.2)

    static func snapshotFetch(_ video: CameraFFmpegPlugin.VideoConfig, snapFilter: String) -> [String] {
        let input = video.stillImageSource ?? video.source ?? ""
        return split(input + " -frames:v 1" + (snapFilter.isEmpty ? "" : " -filter:v " + snapFilter) + " -f image2 - -hide_banner -loglevel error")
    }

    static func snapshotResize(resizeFilter: String?) -> [String] {
        split("-i pipe: -frames:v 1" + (resizeFilter.map { " -filter:v " + $0 } ?? "") + " -f image2 -")
    }

    // MARK: Live streams (7.4)

    /// Where a prepared stream goes, from Setup Endpoints.
    struct Target: Sendable {
        var address: String
        var videoPort: Int
        var videoSRTP: Data
        var videoSSRC: UInt32
        var audioPort: Int
        var audioSRTP: Data
        var audioSSRC: UInt32
        var isIPv6: Bool

        /// The address as a URL's host: an IPv6 one in brackets (the original wrote none, which FFmpeg reads as a host
        /// ending at the first colon).
        var urlHost: String { isIPv6 ? "[\(address)]" : address }
    }

    /// The values a started stream runs with, after the caps.
    struct StreamValues: Equatable {
        var vcodec: String
        var mtu: Int
        var encoderOptions: String?
        var filters: Filters
        var fps: Int
        var bitrate: Int
    }

    static func streamValues(_ video: CameraFFmpegPlugin.VideoConfig, request: VideoInfo) -> StreamValues {
        let vcodec = video.vcodec
        let encoderOptions = video.encoderOptions ?? (vcodec == "libx264" ? "-preset ultrafast -tune zerolatency" : nil)
        var filters = filters(video, width: request.width, height: request.height, snapshot: false)
        var fps = request.fps
        if let maxFPS = video.maxFPS, video.forceMax || request.fps > maxFPS { fps = maxFPS }
        var bitrate = request.maxBitRate
        if let maxBitrate = video.maxBitrate, video.forceMax || request.maxBitRate > maxBitrate { bitrate = maxBitrate }
        if vcodec == "copy" {
            filters.width = 0
            filters.height = 0
            filters.videoFilter = nil
            fps = 0
            bitrate = 0
        }
        return StreamValues(vcodec: vcodec, mtu: video.packetSize, encoderOptions: encoderOptions, filters: filters, fps: fps, bitrate: bitrate)
    }

    /// The main stream's command line, and whether HomeKit asked for an audio codec it cannot have (then without audio). The
    /// user's options are split on whitespace; what comes from HomeKit (the SRTP keys, the controller's address) is
    /// appended whole, so it can never become options of its own.
    /// libfdk_aac's AAC-ELD, the original's encoder.
    static let libfdkAACELD = ["-codec:a", "libfdk_aac", "-profile:a", "aac_eld"]

    static func stream(
        _ video: CameraFFmpegPlugin.VideoConfig, values: StreamValues, request: StartStreamRequest, target: Target,
        aacELDEncoder: [String]? = libfdkAACELD
    ) -> (arguments: [String], unsupportedAudio: Bool) {
        var arguments: [String] = []
        var command = video.source ?? ""
        command += video.mapvideo.map { " -map " + $0 } ?? " -an -sn -dn"
        command += " -codec:v \(values.vcodec) -pix_fmt yuv420p -color_range mpeg"
        if values.fps > 0 { command += " -r \(values.fps)" }
        command += " -f rawvideo"
        if let options = values.encoderOptions { command += " " + options }
        if let filter = values.filters.videoFilter { command += " -filter:v " + filter }
        if values.bitrate > 0 { command += " -b:v \(values.bitrate)k" }
        arguments += split(command) + ["-payload_type", "\(request.video.pt)"]
            + srtpOutput(ssrc: target.videoSSRC, srtp: target.videoSRTP, host: target.urlHost, port: target.videoPort, packetSize: values.mtu)
        var unsupportedAudio = false
        if video.audio {
            let audio = request.audio
            let encoder = audio.codec == .opus ? ["-codec:a", "libopus", "-application", "lowdelay"] : audio.codec == .aacELD ? aacELDEncoder : nil
            if let encoder {
                arguments += split(video.mapaudio.map { "-map " + $0 } ?? "-vn -sn -dn")
                arguments += encoder
                arguments += ["-flags", "+global_header", "-f", "null", "-ar", "\(audio.sampleRate)k", "-b:a", "\(audio.maxBitRate)k", "-ac", "\(audio.channel)",
                              "-payload_type", "\(audio.pt)"]
                arguments += srtpOutput(ssrc: target.audioSSRC, srtp: target.audioSRTP, host: target.urlHost, port: target.audioPort, packetSize: 188)
            } else {
                unsupportedAudio = true
            }
        }
        arguments += ["-loglevel", video.debug ? "level+verbose" : "level", "-progress", "pipe:1"]
        return (arguments, unsupportedAudio)
    }

    /// An SRTP output to the controller.
    private static func srtpOutput(ssrc: UInt32, srtp: Data, host: String, port: Int, packetSize: Int) -> [String] {
        ["-ssrc", "\(ssrc)", "-f", "rtp", "-srtp_out_suite", "AES_CM_128_HMAC_SHA1_80", "-srtp_out_params", srtp.base64EncodedString(),
         "srtp://\(host):\(port)?rtcpport=\(port)&pkt_size=\(packetSize)"]
    }

    // MARK: Two-way audio (7.7)

    /// `decoder`: libfdk_aac's, the original's, or none for FFmpeg's own AAC-ELD decoder.
    static func returnAudio(_ video: CameraFFmpegPlugin.VideoConfig, decoder: [String] = ["-c:a", "libfdk_aac"]) -> [String] {
        ["-hide_banner", "-protocol_whitelist", "pipe,udp,rtp,file,crypto", "-f", "sdp"] + decoder + ["-i", "pipe:"]
            + split((video.returnAudioTarget ?? "") + " -loglevel level" + (video.debugReturn ? "+verbose" : ""))
    }

    /// The SDP FFmpeg reads the return audio with: HomeKit sends it to `port`, the audio return port.
    static func returnAudioSDP(address: String, isIPv6: Bool, port: Int, srtp: Data) -> String {
        let version = isIPv6 ? "IP6" : "IP4"
        return [
            "v=0",
            "o=- 0 0 IN \(version) \(address)",
            "s=Talk",
            "c=IN \(version) \(address)",
            "t=0 0",
            "m=audio \(port) RTP/AVP 110",
            "b=AS:24",
            "a=rtpmap:110 MPEG4-GENERIC/16000/1",
            "a=rtcp-mux",
            "a=fmtp:110 profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=F8F0212C00BC00",
            "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\(srtp.base64EncodedString())",
        ].joined(separator: "\r\n") + "\r\n"
    }

    // MARK: HomeKit Secure Video (9.3, 9.4)

    /// The prebuffer's FFmpeg: the source copied into fragmented MP4 on its standard output (the original sends it to a TCP
    /// server of its own; a pipe exposes nothing on the network).
    static func prebuffer(_ video: CameraFFmpegPlugin.VideoConfig) -> [String] {
        splitOnSpaces(video.source ?? "") + ["-f", "mp4", "-vcodec", "copy", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "pipe:1"]
    }

    struct NoVideoSource: Error, CustomStringConvertible {
        var description: String { "no video source" }
    }

    /// The recording FFmpeg: the source, or with the prebuffer the buffered MP4 on standard input (the original reads it
    /// from a TCP server of its own), encoded as HomeKit selected.
    static func recording(_ video: CameraFFmpegPlugin.VideoConfig, configuration: CameraRecordingConfiguration, prebuffered: Bool) throws -> [String] {
        var arguments = ["-hide_banner"]
        if prebuffered {
            arguments += ["-f", "mp4", "-i", "pipe:0"]
        } else {
            let source = split(video.source ?? "")
            guard !source.isEmpty else { throw NoVideoSource() }
            arguments += source
        }
        if video.audioExplicitlyOff {
            arguments += ["-f", "lavfi", "-i", "anullsrc=cl=mono:r=32000"]
        }
        let parameters = configuration.videoCodec.parameters
        let profile = switch parameters.profile {
        case .high: "high"
        case .main: "main"
        default: "baseline"
        }
        let level = switch parameters.level {
        case .level4_0: "4.0"
        case .level3_2: "3.2"
        default: "3.1"
        }
        let audio = configuration.audioCodec
        let bitrate = parameters.bitRate
        arguments += [
            "-f", "mp4",
            "-acodec", "aac", "-profile:a", audio.type == .aacLC ? "aac_low" : "aac_eld", "-ar", "32000", "-b:a", "\(audio.bitrate)k", "-ac", "\(audio.audioChannels)",
            "-sn", "-dn", "-vcodec", "libx264", "-pix_fmt", "yuv420p", "-profile:v", profile, "-level:v", level,
            "-preset", "veryfast", "-tune", "zerolatency", "-b:v", "\(bitrate)k", "-maxrate", "\(bitrate * 12 / 10)k", "-bufsize", "\(bitrate * 2)k",
            "-g", "30", "-keyint_min", "15", "-sc_threshold", "0", "-force_key_frames", "expr:gte(t,n_forced*1)", "-r", "\(configuration.videoCodec.resolution.fps)",
            // Scaled down to the size HomeKit selected, as live streams are (the original sends the source's).
            "-filter:v", scale(width: configuration.videoCodec.resolution.width, height: configuration.videoCodec.resolution.height),
            "-movflags", "frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset", "pipe:1",
        ]
        return arguments
    }

    /// The scaling filters of 7.1 for a size: no larger than it, the aspect ratio kept, even dimensions.
    static func scale(width: Int, height: Int) -> String {
        "scale='min(\(width),iw)':'min(\(height),ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }

    /// The web UI's live view without a prebuffer: the source's video copied into fragmented MP4, no audio.
    static func liveFeed(_ video: CameraFFmpegPlugin.VideoConfig) -> [String] {
        split(video.source ?? "") + ["-an", "-sn", "-dn", "-codec:v", "copy", "-f", "mp4", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "pipe:1"]
    }

    // MARK: Stream supervision (7.5)

    /// How long a stream runs without RTCP from HomeKit: five RTCP intervals, between 30 seconds and 5 minutes.
    static func inactivityTimeout(rtcpInterval: Float) -> Duration {
        let milliseconds = Double(rtcpInterval) * 5 * 1000
        let clamped = milliseconds.isFinite ? min(max(milliseconds, 30_000), 300_000) : 30_000
        return .milliseconds(Int(clamped))
    }
}

/// What the log never shows: the credentials of URLs (`rtsp://user:pass@host`), the SRTP keys of a command line and of an
/// SDP, the MQTT password.
enum Masking {
    /// A command line for the log, the SRTP parameters hidden and every URL's credentials masked.
    static func commandLine(_ arguments: [String]) -> String {
        var masked: [String] = []
        var hideNext = false
        for argument in arguments {
            masked.append(hideNext ? "***" : text(argument))
            hideNext = argument == "-srtp_out_params" || argument == "-srtp_in_params"
        }
        return masked.joined(separator: " ")
    }

    /// The text with the user name and password of every URL replaced, secret-looking query values and SDP keys (`inline:…`)
    /// hidden.
    static func text(_ text: String) -> String {
        var result = text
        if result.contains("://") {
            result = result.replacing(#/([a-zA-Z][a-zA-Z0-9+.\-]*:\/\/)[^\/?#\s]*@/#) { $0.output.1 + "***@" }
        }
        // Credentials some cameras take in the query (`?usr=admin&pwd=…`), as HomeswiftFFmpeg hides them in its own lines.
        result = redactURLPasswords(result)
        if result.contains("inline:") {
            result = result.replacing(#/inline:[A-Za-z0-9+\/=]+/#) { _ in "inline:***" }
        }
        return result
    }
}
