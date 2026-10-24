import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin

/// Two-way audio (`ProtectTalkback`): what HomeKit's microphone sends, decoded by FFmpeg from the SRTP
/// session described in an SDP, encoded as AAC in ADTS, and sent to the camera's speaker over the
/// controller's talkback WebSocket, or straight to the camera over UDP with `Audio.TwoWay.Direct`.
@ProtectActor
final class ProtectTalkback {
    struct Session: Sendable {
        /// The HomeKit client.
        var address: String
        /// Where the microphone's RTP arrives, after the demuxer.
        var audioIncomingRtpPort: Int
        /// Key and salt.
        var audioSRTP: Data
        var rtpDemuxer: (any ProtectRtpDemuxer)?
        /// The controller's talkback WebSocket URL.
        var talkBack: String?
    }

    private let camera: ProtectCamera
    private let ffmpeg: any ProtectFfmpegKit
    private let options: any ProtectFfmpegOptions

    init(camera: ProtectCamera, ffmpeg: any ProtectFfmpegKit, options: any ProtectFfmpegOptions) {
        self.camera = camera
        self.ffmpeg = ffmpeg
        self.options = options
    }

    private var log: ProtectLog { camera.log }

    /// Starts the return audio of a session once HomeKit sends audio; `register` adds FFmpeg to the session.
    func start(_ request: StartStreamRequest, session: Session, sdpIpVersion: String, host: any HomebridgeStreamingDelegate,
               register: @escaping @ProtectActor (any ProtectFfmpegProcess) -> Void) async {
        let sdp = Self.sdp(request, session: session, sdpIpVersion: sdpIpVersion, accessoryName: camera.accessoryName)
        await startReturnAudio(request, session: session, sdp: sdp, arguments: returnAudioArguments(request), host: host, register: register)
    }

    /// The SDP FFmpeg reads the microphone's SRTP session from.
    nonisolated static func sdp(_ request: StartStreamRequest, session: Session, sdpIpVersion: String, accessoryName: String) -> String {
        let is16 = request.audio.sampleRate == 16
        // Opus (ProtectStream.liveAudioCodec) is always 48 kHz and two channels in RTP (RFC 7587).
        let format = request.audio.codec == .opus
            ? ["a=rtpmap:" + String(request.audio.pt) + " opus/48000/2"]
            : ["a=rtpmap:110 MPEG4-GENERIC/" + (is16 ? "16000" : "24000") + "/" + String(request.audio.channel),
               "a=fmtp:110 profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=" + (is16 ? "F8F0212C00BC00" : "F8EC212C00BC00")]
        return ([
            "v=0",
            "o=- 0 0 IN " + sdpIpVersion + " 127.0.0.1",
            // A name is one line: a line break in it would add lines to the SDP.
            "s=" + accessoryName.filter { !$0.isNewline } + " Audio Talkback",
            "c=IN " + sdpIpVersion + " " + session.address,
            "t=0 0",
            "m=audio " + String(session.audioIncomingRtpPort) + " RTP/AVP " + String(request.audio.pt),
            "b=AS:24",
        ] + format + [
            "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:" + session.audioSRTP.base64EncodedString(),
        ]).joined(separator: "\n")
    }

    /// FFmpeg's command line: the SDP on standard input, ADTS out at the camera's talkback rate and channels.
    func returnAudioArguments(_ request: StartStreamRequest) -> [String] {
        let talkback = camera.ufp.json
        // With Opus from the Home app, FFmpeg has no AAC-ELD encoder (ProtectStream.liveAudioCodec): its own AAC-LC
        // encoder makes the ADTS the camera takes.
        let isOpus = request.audio.codec == .opus
        let encoder = options.audioEncoder()
        var arguments = ["-hide_banner", "-nostats", "-protocol_whitelist", "crypto,file,pipe,rtp,udp", "-f", "sdp",
                         "-codec:a", isOpus ? "libopus" : options.audioDecoder, "-i", "pipe:0", "-map", "0:a:0"]
            + (isOpus && encoder.isEmpty ? ["-codec:a", "aac"] : encoder)
            + ["-flags", "+global_header", "-ar", talkback.number("talkbackSettings.samplingRate"), "-b:a", String(request.audio.maxBitRate) + "k",
               "-ac", talkback.number("talkbackSettings.channels"), "-f", "adts"]
        if camera.hints.twoWayAudioDirect {
            arguments.append("udp://" + (camera.ufp.host ?? "") + ":" + talkback.number("talkbackSettings.bindPort"))
        } else {
            arguments.append("pipe:1")
        }
        if camera.platform.verboseFfmpeg { arguments += ["-loglevel", "level+verbose"] }
        if camera.platform.configuration.debug { arguments += ["-loglevel", "level+debug"] }
        return arguments
    }

    private func startReturnAudio(_ request: StartStreamRequest, session: Session, sdp: String, arguments: [String], host: any HomebridgeStreamingDelegate,
                                  register: @escaping @ProtectActor (any ProtectFfmpegProcess) -> Void) async {
        let api = camera.api
        let log = self.log
        // The controller's talkback channel: audio frames go out in order through one sender.
        var channel: (sender: Task<Void, Never>, frames: AsyncStream<Data>.Continuation)?
        if let talkBack = session.talkBack, let url = URL(string: talkBack), !camera.hints.twoWayAudioDirect {
            let (frames, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(256))
            let sender = Task {
                let socket: any WebSocketConnection
                do {
                    socket = try await api.openWebSocket(url)
                } catch {
                    log.error("Error in communicating with the return audio channel: \(error)")
                    return
                }
                for await frame in frames {
                    do {
                        try await socket.send(binary: frame)
                    } catch {
                        break
                    }
                }
                await socket.close()
            }
            channel = (sender, continuation)
        }
        let outgoing = channel?.frames
        let sender = channel?.sender
        let cleanup = {
            outgoing?.finish()
            sender?.cancel()
        }
        if let demuxer = session.rtpDemuxer {
            // FFmpeg starts with the first packet from HomeKit.
            await demuxer.firstPacket()
            guard demuxer.isRunning else {
                cleanup()
                return
            }
        }
        let ffmpeg = self.ffmpeg.startStreaming(delegate: host, sessionID: request.sessionID, options: options, arguments: arguments, returnPort: nil)
        register(ffmpeg)
        ffmpeg.endStdin(Data((sdp + "\n").utf8))
        if let outgoing {
            ffmpeg.onStdout { data in outgoing.yield(data) }
        }
        // The talkback channel closes with FFmpeg.
        ffmpeg.onExit { outgoing?.finish() }
    }
}

private extension JSONValue {
    /// A number as JavaScript's `toString()` writes it.
    func number(_ path: String) -> String {
        guard let value = double(path) else { return "undefined" }
        return jsNumber(value)
    }
}
