import Foundation
import Logging
import Testing

@testable import Homeswift
@testable import HomeswiftFFmpeg

/// What the TypeScript library produced (Fixtures/typescript-arguments.json, generated from homebridge-unifi-protect's
/// dist/lib/ffmpeg with the host profiles, encoder requests and fMP4 option sets below, in the same order).
struct TypeScriptFixture: Decodable {
    struct Crop: Decodable {
        let height: Double
        let width: Double
        let x: Double
        let y: Double
    }

    struct Characterization: Decodable {
        let audioDecoder: String
        let audioEncoder: [String: [String]]
        let cropFilter: String
        let hardwareDecoding: Bool
        let hardwareDownloadFilters: [String]
        let hardwareTranscoding: Bool
        /// -1 for Infinity.
        let hostSystemMaxPixels: Int
        let logs: [[String]]
        let recordEncoder: [String: [String]]
        let streamEncoder: [String: [String]]
        let videoDecoder: [String: [String]]
    }

    struct OptionsCase: Decodable {
        let host: String
        let ffmpegVersion: String
        let hardwareDecoding: Bool
        let hardwareTranscoding: Bool
        let crop: Crop?
        let result: Characterization
    }

    struct ProcessCase: Decodable {
        let kind: String
        let host: String
        let ffmpegVersion: String
        let hardwareDecoding: Bool
        let hardwareTranscoding: Bool
        let config: Int
        let verbose: Bool
        let options: Int
        let args: [String]
    }

    struct Redaction: Decodable {
        let args: [String]
        let redacted: String
    }

    let options: [OptionsCase]
    let processes: [ProcessCase]
    let redactions: [Redaction]

    static func load() throws -> TypeScriptFixture {
        let url = try #require(Bundle.module.url(forResource: "typescript-arguments", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(TypeScriptFixture.self, from: Data(contentsOf: url))
    }
}

/// The encoder requests of ffmpeg-options.test.ts.
let ENCODER_REQUESTS: [String: VideoEncoderOptions] = [
    "1080p-high-30to30": VideoEncoderOptions(bitrate: 3000, fps: 30, height: 1080, idrInterval: 4, inputFps: 30, level: .level4_0, profile: .high, width: 1920),
    "720p-main-30to15": VideoEncoderOptions(bitrate: 1000, fps: 15, height: 720, idrInterval: 2, inputFps: 30, level: .level3_1, profile: .main, width: 1280),
    "360p-baseline-15to30": VideoEncoderOptions(bitrate: 300, fps: 30, height: 360, idrInterval: 1, inputFps: 15, level: .level3_2, profile: .baseline, width: 640),
    "480p-nosmart-nohwdec": VideoEncoderOptions(
        bitrate: 500, fps: 24, hardwareDecoding: false, height: 480, idrInterval: 4, inputFps: 24, level: .level3_1, profile: .main, smartQuality: false,
        width: 640
    ),
    "1440p-hwtrans-off": VideoEncoderOptions(
        bitrate: 2000, fps: 30, hardwareTranscoding: false, height: 1440, idrInterval: 4, inputFps: 25, level: .level4_0, profile: .high, width: 1920
    ),
]

@Suite struct FfmpegOptionsTests {
    @Test func matchesTheTypeScriptArgumentsForEveryHostAndConfiguration() throws {
        let fixture = try TypeScriptFixture.load()
        #expect(fixture.options.count == 108)
        for testCase in fixture.options {
            let label = "\(testCase.host), ffmpeg \(testCase.ffmpegVersion), hwdec=\(testCase.hardwareDecoding), hwenc=\(testCase.hardwareTranscoding), crop=\(testCase.crop != nil)"
            let host = try #require(HOSTS[testCase.host])
            let crop = testCase.crop.map { FfmpegOptionsConfig.Crop(height: $0.height, width: $0.width, x: $0.x, y: $0.y) }
            let (logs, options) = createOptions(
                host, ffmpegVersion: testCase.ffmpegVersion, hardwareDecoding: testCase.hardwareDecoding, hardwareTranscoding: testCase.hardwareTranscoding,
                crop: crop
            )
            let expected = testCase.result
            #expect(options.audioDecoder == expected.audioDecoder, "\(label)")
            #expect(options.audioEncoder() == expected.audioEncoder["default"], "\(label)")
            #expect(options.audioEncoder(AudioEncoderOptions(codec: .aacELD)) == expected.audioEncoder["eld"], "\(label)")
            #expect(options.audioEncoder(AudioEncoderOptions(codec: .aacLC)) == expected.audioEncoder["lc"], "\(label)")
            #expect(options.cropFilter == expected.cropFilter, "\(label)")
            #expect(options.config.hardwareDecoding == expected.hardwareDecoding, "\(label)")
            #expect(options.config.hardwareTranscoding == expected.hardwareTranscoding, "\(label)")
            #expect(options.hardwareDownloadFilters == expected.hardwareDownloadFilters, "\(label)")
            #expect(options.hostSystemMaxPixels == (expected.hostSystemMaxPixels == -1 ? Int.max : expected.hostSystemMaxPixels), "\(label)")
            #expect(logs.pairs == expected.logs, "\(label)")
            for (name, request) in ENCODER_REQUESTS {
                #expect(options.streamEncoder(request) == expected.streamEncoder[name], "\(label), stream \(name)")
                #expect(options.recordEncoder(request) == expected.recordEncoder[name], "\(label), record \(name)")
            }
            #expect(options.videoDecoder("av1") == expected.videoDecoder["av1"], "\(label)")
            #expect(options.videoDecoder() == expected.videoDecoder["default"], "\(label)")
            #expect(options.videoDecoder("H264") == expected.videoDecoder["h264"], "\(label)")
            #expect(options.videoDecoder("h265") == expected.videoDecoder["h265"], "\(label)")
            #expect(options.videoDecoder("hevc") == expected.videoDecoder["hevc"], "\(label)")
            #expect(options.videoDecoder("vp9") == expected.videoDecoder["vp9"], "\(label)")
        }
    }

    @Test func usesLibx264WithACappedCRFForSoftwareStreaming() {
        let (_, options) = createOptions(HOSTS["generic"]!, ffmpegVersion: "8.0", hardwareDecoding: false, hardwareTranscoding: false)
        #expect(options.streamEncoder(ENCODER_REQUESTS["720p-main-30to15"]!) == [
            "-codec:v", "libx264", "-preset", "veryfast", "-profile:v", "main", "-level:v", "3.1", "-noautoscale", "-bf", "0",
            "-filter:v", "fps=15, scale=-2:min(ih\\, 720):in_range=auto:out_range=auto", "-g:v", "30", "-bufsize", "2000k", "-maxrate", "1064k", "-crf", "20",
        ])
    }

    @Test func usesVideoToolboxWithUploadAndScaleVTOnAppleSiliconWithFFmpeg8() {
        let (_, options) = createOptions(HOSTS["macOS.Apple"]!, ffmpegVersion: "8.0", hardwareDecoding: true, hardwareTranscoding: true)
        #expect(options.streamEncoder(ENCODER_REQUESTS["480p-nosmart-nohwdec"]!) == [
            "-init_hw_device", "videotoolbox=hw", "-filter_hw_device", "hw", "-codec:v", "h264_videotoolbox", "-allow_sw", "1", "-realtime", "1",
            "-profile:v", "main", "-level:v", "0", "-bf", "0", "-noautoscale", "-filter:v", "hwupload, scale_vt=-2:min(ih\\, 480)", "-g:v", "96",
            "-bufsize", "1000k", "-maxrate", "500k", "-b:v", "500k",
        ])
    }

    @Test func enablesHardwareDecodingWhenQuickSyncIsDetected() {
        let (_, options) = createOptions(HOSTS["generic-qsv-gen12"]!, ffmpegVersion: "8.0", hardwareDecoding: false, hardwareTranscoding: true)
        #expect(options.config.hardwareDecoding)
        #expect(options.videoDecoder("hevc") == ["-hwaccel", "qsv", "-hwaccel_output_format", "qsv", "-codec:v", "hevc_qsv"])
    }

    @Test func limitsRaspberryPiHardwareTranscodingTo1080p() {
        #expect(createOptions(HOSTS["raspbian"]!, ffmpegVersion: "8.0", hardwareDecoding: false, hardwareTranscoding: true).options.hostSystemMaxPixels == 1920 * 1080)
        #expect(createOptions(HOSTS["raspbian"]!, ffmpegVersion: "8.0", hardwareDecoding: false, hardwareTranscoding: false).options.hostSystemMaxPixels == Int.max)
    }

    @Test func recordEncoderAlwaysTurnsSmartQualityOff() {
        let (_, options) = createOptions(HOSTS["generic"]!, ffmpegVersion: "8.0", hardwareDecoding: false, hardwareTranscoding: false)
        var request = ENCODER_REQUESTS["1080p-high-30to30"]!
        request.smartQuality = true
        let recorded = options.recordEncoder(request)
        #expect(recorded.contains("-b:v"))
        #expect(!recorded.contains("-crf"))
    }

    @Test func translatesProfilesAndLevels() {
        #expect(H264Profile.allCases.map { h264ProfileArg($0) } == ["baseline", "main", "high"])
        #expect(H264Profile.allCases.map { h264ProfileArg($0, numeric: true) } == ["66", "77", "100"])
        #expect(H264Level.allCases.map { h264LevelArg($0) } == ["3.1", "3.2", "4.0"])
        #expect(H264Level.allCases.map { h264LevelArg($0, numeric: true) } == ["31", "32", "40"])
        #expect(hwAccelCategories(hardwareDecoding: true, hardwareTranscoding: true) == "decoding and ⛭︎ transcoding")
        #expect(jsNumber(1) == "1")
        #expect(jsNumber(0.75) == "0.75")
        #expect(jsNumber(0.1) == "0.1")
    }
}

/// The audio configurations of the fMP4 fixture cases: (type, samplerate, channels).
let FMP4_CONFIGS: [(AudioRecordingCodecType, AudioRecordingSamplerate, Int)] = [
    (.aacELD, .khz24, 1), (.aacLC, .khz32, 1), (.aacLC, .khz44_1, 2), (.aacELD, .khz48, 1), (.aacLC, .khz8, 1),
]

let RECORDING_OPTIONS: [FMp4RecordingOptions] = [
    FMp4RecordingOptions(),
    FMp4RecordingOptions(
        audioFilters: ["highpass=f=200", "lowpass=f=3000"], audioStream: 1, codec: "hevc", enableAudio: true, fps: 15, probesize: 32768, timeshift: 1500,
        transcodeAudio: false
    ),
    FMp4RecordingOptions(enableAudio: false, hardwareDecoding: true, hardwareTranscoding: false, videoFilters: ["hflip"], videoStream: 2),
    FMp4RecordingOptions(transcodeAudio: false),
]

let LIVESTREAM_OPTIONS: [FMp4LivestreamOptions] = [
    FMp4LivestreamOptions(url: "rtsp://user:pw@10.0.0.2:554/stream"),
    FMp4LivestreamOptions(url: "rtsps://10.0.0.2:7441/abc?enableSrtp", codec: "av1", enableAudio: false),
    FMp4LivestreamOptions(url: "rtsp://cam/video", audioInput: FMp4AudioInputConfig(url: "RTSPS://cam/audio")),
    FMp4LivestreamOptions(url: "rtsp://cam/video", audioInput: FMp4AudioInputConfig(url: "http://doorbird/bha-api/audio.cgi", format: .mulaw)),
    FMp4LivestreamOptions(
        url: "rtsp://cam/video", audioFilters: ["volume=2"],
        audioInput: FMp4AudioInputConfig(url: "http://cam/a", format: .s16le, sampleRate: 16000, channels: 2), transcodeAudio: false
    ),
    FMp4LivestreamOptions(url: "rtsp://cam/video", audioInput: FMp4AudioInputConfig(url: "http://cam/a"), enableAudio: false),
]

@Suite struct FMp4CommandLineTests {
    @Test func matchesTheTypeScriptCommandLines() throws {
        let fixture = try TypeScriptFixture.load()
        #expect(fixture.processes.count == 120)
        for testCase in fixture.processes {
            let (_, options) = createOptions(
                try #require(HOSTS[testCase.host]), ffmpegVersion: testCase.ffmpegVersion, hardwareDecoding: testCase.hardwareDecoding,
                hardwareTranscoding: testCase.hardwareTranscoding
            )
            let (type, samplerate, channels) = FMP4_CONFIGS[testCase.config]
            let configuration = recordingConfiguration(audio: type, samplerate: samplerate, channels: channels)
            let arguments: [String]
            if testCase.kind == "recording" {
                arguments = FfmpegRecordingProcess(
                    options, recordingConfig: configuration, fMp4Options: RECORDING_OPTIONS[testCase.options], isVerbose: testCase.verbose
                ).commandLineArgs
            } else {
                arguments = FfmpegLivestreamProcess(
                    options, recordingConfig: configuration, livestreamOptions: LIVESTREAM_OPTIONS[testCase.options], isVerbose: testCase.verbose
                ).commandLineArgs
            }
            #expect(arguments == testCase.args, "\(testCase.kind) \(testCase.host) config \(testCase.config) options \(testCase.options) verbose \(testCase.verbose)")
        }
    }

    @Test func appliesTheSegmentLengthWhenALivestreamStarts() {
        let (_, options) = shellOptions()
        let livestream = FfmpegLivestreamProcess(options, recordingConfig: recordingConfiguration(), livestreamOptions: FMp4LivestreamOptions(url: "rtsp://cam"))
        #expect(livestream.commandLineArgs.contains("1000000"))
        livestream.segmentLength = 250
        livestream.start(["-c", "exit 0", "-frag_duration", "1"])
        #expect(livestream.commandLineArgs == ["-c", "exit 0", "-frag_duration", "250000"])
    }
}
