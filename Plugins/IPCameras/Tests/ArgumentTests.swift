import Foundation
import HomeswiftFFmpeg
import Testing

@testable import Homeswift
@testable import HomeswiftIPCameras

/// The FFmpeg command lines against the vectors of docs/clean-room/CameraFFmpeg.md, sections 7 and 9.
struct ArgumentTests {
    let source = "-i rtsp://u:p@10.0.0.5:554/s1"

    @Test func snapshotCommands() throws {
        let video = try videoConfig(["source": source])
        let filters = FFmpegArguments.filters(video, width: 640, height: 360, snapshot: true)
        #expect(FFmpegArguments.snapshotFetch(video, snapFilter: filters.snapFilter)
            == ["-i", "rtsp://u:p@10.0.0.5:554/s1", "-frames:v", "1", "-f", "image2", "-", "-hide_banner", "-loglevel", "error"])
        #expect(FFmpegArguments.snapshotResize(resizeFilter: filters.resizeFilter)
            == ["-i", "pipe:", "-frames:v", "1", "-filter:v", "scale='min(640,iw)':'min(360,ih)':force_original_aspect_ratio=decrease", "-f", "image2", "-"])
    }

    @Test func noneLeavesTheScalingOut() throws {
        let video = try videoConfig(["source": source, "videoFilter": "hflip,none"])
        let filters = FFmpegArguments.filters(video, width: 640, height: 360, snapshot: true)
        #expect(FFmpegArguments.snapshotFetch(video, snapFilter: filters.snapFilter).contains("hflip"))
        #expect(!FFmpegArguments.snapshotResize(resizeFilter: filters.resizeFilter).contains("-filter:v"))
    }

    @Test func aStillImageSourceIsTheSnapshotsInput() throws {
        let video = try videoConfig(["source": source, "stillImageSource": "-i http://10.0.0.5/snap.jpg"])
        #expect(FFmpegArguments.snapshotFetch(video, snapFilter: "").prefix(2) == ["-i", "http://10.0.0.5/snap.jpg"])
    }

    @Test func streamCommand() throws {
        let video = try videoConfig(["source": source, "maxWidth": 1280, "maxHeight": 720, "maxFPS": 30, "audio": true])
        let request = startRequest()
        let values = FFmpegArguments.streamValues(video, request: request.video)
        let (arguments, unsupported) = FFmpegArguments.stream(video, values: values, request: request, target: streamTarget)
        #expect(!unsupported)
        let expected = """
            -i rtsp://u:p@10.0.0.5:554/s1
            -an -sn -dn -codec:v libx264 -pix_fmt yuv420p -color_range mpeg -r 30 -f rawvideo -preset ultrafast -tune zerolatency
            -filter:v scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2
            -b:v 802k -payload_type 99
            -ssrc 1111 -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params \(videoKey.base64EncodedString()) srtp://192.168.1.20:51000?rtcpport=51000&pkt_size=1316
            -vn -sn -dn -codec:a libfdk_aac -profile:a aac_eld -flags +global_header -f null -ar 16k -b:a 24k -ac 1 -payload_type 110
            -ssrc 2222 -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params \(audioKey.base64EncodedString()) srtp://192.168.1.20:51002?rtcpport=51002&pkt_size=188
            -loglevel level -progress pipe:1
            """
        #expect(arguments == FFmpegArguments.split(expected))
        #expect(videoKey.base64EncodedString().count == 40)
    }

    @Test func streamCaps() throws {
        let capped = try videoConfig(["source": source, "maxBitrate": 299])
        let request = startRequest()
        let arguments = FFmpegArguments.stream(capped, values: FFmpegArguments.streamValues(capped, request: request.video), request: request, target: streamTarget).arguments
        #expect(arguments.contains("299k"))

        let forced = try videoConfig(["source": source, "maxFPS": 15, "forceMax": true])
        #expect(FFmpegArguments.streamValues(forced, request: startRequest(fps: 30).video).fps == 15)
        #expect(FFmpegArguments.streamValues(forced, request: startRequest(fps: 10).video).fps == 15)

        let native = try videoConfig(["source": source, "maxWidth": 0, "maxHeight": 0])
        #expect(FFmpegArguments.streamValues(native, request: request.video).filters.videoFilter == nil)
    }

    @Test func copySendsTheSourceAsItIs() throws {
        let video = try videoConfig(["source": source, "vcodec": "copy", "videoFilter": "hflip", "maxFPS": 15])
        let request = startRequest()
        let arguments = FFmpegArguments.stream(video, values: FFmpegArguments.streamValues(video, request: request.video), request: request, target: streamTarget).arguments
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("-an -sn -dn -codec:v copy -pix_fmt yuv420p -color_range mpeg -f rawvideo -payload_type 99"))
        #expect(!arguments.contains("-r") && !arguments.contains("-filter:v") && !arguments.contains("-b:v") && !arguments.contains("-preset"))
    }

    @Test func userStringsAreSplitAndMapped() throws {
        let video = try videoConfig([
            "source": " -rtsp_transport tcp  -i rtsp://cam/s1", "mapvideo": "0:0", "mapaudio": "0:1", "audio": true,
            "encoderOptions": "-preset veryfast", "vcodec": "h264_videotoolbox", "packetSize": 564,
        ])
        let request = startRequest(audio: .opus)
        let values = FFmpegArguments.streamValues(video, request: request.video)
        let arguments = FFmpegArguments.stream(video, values: values, request: request, target: streamTarget).arguments
        #expect(arguments.prefix(4) == ["-rtsp_transport", "tcp", "-i", "rtsp://cam/s1"])
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("-map 0:0 -codec:v h264_videotoolbox"))
        #expect(joined.contains("-preset veryfast"))
        #expect(joined.contains("pkt_size=564"))
        #expect(joined.contains("-map 0:1 -codec:a libopus -application lowdelay"))
    }

    @Test func whatHomeKitSendsStaysOneArgument() throws {
        let video = try videoConfig(["source": source])
        var target = streamTarget
        target.address = "1.2.3.4 -y /tmp/out.mp4"
        let request = startRequest()
        let arguments = FFmpegArguments.stream(video, values: FFmpegArguments.streamValues(video, request: request.video), request: request, target: target).arguments
        #expect(arguments.contains("srtp://1.2.3.4 -y /tmp/out.mp4:51000?rtcpport=51000&pkt_size=1316"))
        #expect(!arguments.contains("-y"))

        // An IPv6 controller in brackets, so FFmpeg reads the whole address as the host.
        target.address = "fe80::1"
        target.isIPv6 = true
        let v6 = FFmpegArguments.stream(video, values: FFmpegArguments.streamValues(video, request: request.video), request: request, target: target).arguments
        #expect(v6.contains("srtp://[fe80::1]:51000?rtcpport=51000&pkt_size=1316"))
    }

    @Test func aacELDWithoutLibfdk() async throws {
        func codecs(_ encoders: Set<String>) -> FfmpegCodecs {
            FfmpegCodecs(log: testLogger, ffmpegVersion: "8.0", encoders: ["aac": encoders])
        }
        #expect(await FFmpegCapabilities(known: nil).aacELDEncoder() == FFmpegArguments.libfdkAACELD)
        #expect(await FFmpegCapabilities(known: codecs(["libfdk_aac", "aac_at"])).aacELDEncoder() == FFmpegArguments.libfdkAACELD)
        #expect(await FFmpegCapabilities(known: codecs(["aac", "aac_at"])).aacELDEncoder() == ["-codec:a", "aac_at", "-profile:a", "38", "-aac_at_mode", "cbr"])
        #expect(await FFmpegCapabilities(known: codecs(["aac"])).aacELDEncoder() == nil)
        #expect(await FFmpegCapabilities(known: codecs(["aac"])).aacELDDecoder() == [])

        let video = try videoConfig(["source": source, "audio": true])
        let request = startRequest()
        let values = FFmpegArguments.streamValues(video, request: request.video)
        let (none, unsupported) = FFmpegArguments.stream(video, values: values, request: request, target: streamTarget, aacELDEncoder: nil)
        #expect(unsupported && !none.contains("-codec:a"))
        let native = FFmpegArguments.returnAudio(try videoConfig(["source": source, "returnAudioTarget": "-f adts udp://camera:5000"]), decoder: [])
        #expect(native.prefix(7) == ["-hide_banner", "-protocol_whitelist", "pipe,udp,rtp,file,crypto", "-f", "sdp", "-i", "pipe:"])
    }

    @Test func anUnsupportedAudioCodecSendsNoAudio() throws {
        let video = try videoConfig(["source": source, "audio": true])
        let request = startRequest(audio: .pcmu)
        let (arguments, unsupported) = FFmpegArguments.stream(video, values: FFmpegArguments.streamValues(video, request: request.video), request: request,
                                                              target: streamTarget)
        #expect(unsupported)
        #expect(!arguments.contains("-codec:a"))
    }

    @Test func twoWayAudio() throws {
        let video = try videoConfig(["source": source, "returnAudioTarget": "-acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://camera:5000"])
        #expect(FFmpegArguments.returnAudio(video) == FFmpegArguments.split(
            "-hide_banner -protocol_whitelist pipe,udp,rtp,file,crypto -f sdp -c:a libfdk_aac -i pipe: -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://camera:5000 -loglevel level"))
        let sdp = FFmpegArguments.returnAudioSDP(address: "192.168.1.20", isIPv6: false, port: 52000, srtp: audioKey)
        #expect(sdp == "v=0\r\no=- 0 0 IN IP4 192.168.1.20\r\ns=Talk\r\nc=IN IP4 192.168.1.20\r\nt=0 0\r\nm=audio 52000 RTP/AVP 110\r\nb=AS:24\r\n"
            + "a=rtpmap:110 MPEG4-GENERIC/16000/1\r\na=rtcp-mux\r\n"
            + "a=fmtp:110 profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=F8F0212C00BC00\r\n"
            + "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\(audioKey.base64EncodedString())\r\n")
        #expect(FFmpegArguments.returnAudioSDP(address: "fe80::1", isIPv6: true, port: 1, srtp: audioKey).contains("c=IN IP6 fe80::1"))
        // The web UI's microphone goes to the same target, its PCM on standard input.
        #expect(FFmpegArguments.webTalk(video, sampleRate: 16000) == FFmpegArguments.split(
            "-hide_banner -f s16le -ar 16000 -ac 1 -i pipe: -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://camera:5000 -loglevel level"))
    }

    @Test func recordingCommand() throws {
        let video = try videoConfig(["source": source])
        let expected = """
            -hide_banner -i rtsp://u:p@10.0.0.5:554/s1 -f mp4
            -acodec aac -profile:a aac_low -ar 32000 -b:a 64k -ac 1 -sn -dn -vcodec libx264 -pix_fmt yuv420p -profile:v high -level:v 4.0
            -preset veryfast -tune zerolatency -b:v 2000k -maxrate 2400k -bufsize 4000k -g 30 -keyint_min 15 -sc_threshold 0
            -force_key_frames expr:gte(t,n_forced*1) -r 30
            -filter:v scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2
            -movflags frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset pipe:1
            """
        #expect(try FFmpegArguments.recording(video, configuration: recordingConfiguration(), prebuffered: false) == FFmpegArguments.split(expected))

        let silent = try videoConfig(["source": source, "audio": false])
        #expect(try FFmpegArguments.recording(silent, configuration: recordingConfiguration(), prebuffered: false).prefix(8)
            == ["-hide_banner", "-i", "rtsp://u:p@10.0.0.5:554/s1", "-f", "lavfi", "-i", "anullsrc=cl=mono:r=32000", "-f"])

        let low = try FFmpegArguments.recording(video, configuration: recordingConfiguration(bitrate: 333), prebuffered: false).joined(separator: " ")
        #expect(low.contains("-maxrate 399k -bufsize 666k"))

        let prebuffered = try FFmpegArguments.recording(video, configuration: recordingConfiguration(), prebuffered: true)
        #expect(prebuffered.prefix(5) == ["-hide_banner", "-f", "mp4", "-i", "pipe:0"])
    }

    @Test func prebufferCommand() throws {
        let video = try videoConfig(["source": "-rtsp_transport tcp -i rtsp://cam/s1", "recording": true, "prebuffer": true])
        #expect(FFmpegArguments.prebuffer(video)
            == ["-rtsp_transport", "tcp", "-i", "rtsp://cam/s1", "-f", "mp4", "-vcodec", "copy", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "pipe:1"])
    }

    @Test func inactivityTimeout() {
        #expect(FFmpegArguments.inactivityTimeout(rtcpInterval: 0.5) == .milliseconds(30_000))
        #expect(FFmpegArguments.inactivityTimeout(rtcpInterval: 10) == .milliseconds(50_000))
        #expect(FFmpegArguments.inactivityTimeout(rtcpInterval: 100) == .milliseconds(300_000))
        #expect(FFmpegArguments.inactivityTimeout(rtcpInterval: .nan) == .milliseconds(30_000))
    }

    @Test func theLogNeverShowsCredentialsOrKeys() {
        let arguments = ["-i", "rtsp://admin:s3cr@t@10.0.0.5:554/s1", "-srtp_out_params", "c2VjcmV0a2V5", "srtp://192.168.1.20:51000?rtcpport=51000"]
        let line = Masking.commandLine(arguments)
        #expect(!line.contains("admin") && !line.contains("s3cr") && !line.contains("c2VjcmV0a2V5"))
        #expect(line.contains("rtsp://***@10.0.0.5:554/<redacted>"))
        #expect(line.contains("srtp://192.168.1.20:51000"))
        #expect(Masking.text("a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:QUJDRA==") == "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:***")
        #expect(Masking.text("-i http://cam/snapshot.cgi?usr=admin&pwd=hunter2&res=1") == "-i http://cam/snapshot.cgi?usr=admin&pwd=***&res=1")
        #expect(Masking.text("http://cam/video?Password=x&token=y") == "http://cam/video?Password=***&token=***")
    }

    @Test func boxes() throws {
        var reader = MP4BoxReader()
        let ftyp = Data([0, 0, 0, 0x10]) + Data("ftyp".utf8) + Data(repeating: 1, count: 8)
        // Split anywhere, header included.
        #expect(try reader.push(ftyp.prefix(5)).isEmpty)
        let boxes = try reader.push(ftyp.dropFirst(5) + Data([0, 0, 0, 8]) + Data("moov".utf8))
        #expect(boxes.map(\.type) == ["ftyp", "moov"])
        #expect(boxes[0].data == ftyp)

        var corrupt = MP4BoxReader()
        #expect(throws: MP4BoxReader.InvalidBox.self) { try corrupt.push(Data([0, 0, 0, 4]) + Data("free".utf8)) }
        var huge = MP4BoxReader()
        #expect(throws: MP4BoxReader.InvalidBox.self) { try huge.push(Data([0x7F, 0xFF, 0xFF, 0xFF]) + Data("mdat".utf8)) }
        var negative = MP4BoxReader()
        #expect(throws: MP4BoxReader.InvalidBox.self) { try negative.push(Data([0xFF, 0xFF, 0xFF, 0xF0]) + Data("mdat".utf8)) }
    }

    @Test func fragments() {
        func box(_ type: String) -> MP4Box { MP4Box(type: type, data: Data([0, 0, 0, 8]) + Data(type.utf8)) }
        var fragmenter = RecordingFragmenter()
        #expect(fragmenter.add(box("ftyp")) == nil)
        #expect(fragmenter.add(box("moov")) == box("ftyp").data + box("moov").data)
        #expect(fragmenter.add(box("free")) == nil)
        #expect(fragmenter.add(box("moof")) == nil)
        #expect(fragmenter.add(box("mdat")) == box("moof").data + box("mdat").data)
        #expect(fragmenter.add(box("mdat")) == nil)
    }

    @Test func progressBlocks() {
        #expect(CameraStreamer.progressFrame(Data("frame=12\nfps=30.0\n".utf8)) == 12)
        #expect(CameraStreamer.progressFrame(Data("fps=30.0\n".utf8)) == nil)
    }
}
