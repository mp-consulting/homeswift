import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift

/// A camera plugin's streaming side that records what HomeKit asked.
final class FakeStreamingDelegate: CameraStreamingDelegate, @unchecked Sendable {
    let prepares = NIOLockedValueBox<[PrepareStreamRequest]>([])
    let requests = NIOLockedValueBox<[StreamingRequest]>([])
    let snapshots = NIOLockedValueBox<[SnapshotRequest]>([])
    var image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])

    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        snapshots.withLockedValue { $0.append(request) }
        return image
    }

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        prepares.withLockedValue { $0.append(request) }
        return PrepareStreamResponse(
            video: .init(port: 50000, ssrc: 0x00AB_CDEF, srtpKey: Data(repeating: 0x11, count: 16), srtpSalt: Data(repeating: 0x22, count: 14)),
            audio: .init(port: 50002, ssrc: 0x0012_3456, srtpKey: Data(repeating: 0x33, count: 16), srtpSalt: Data(repeating: 0x44, count: 14)))
    }

    func handleStreamRequest(_ request: StreamingRequest) async throws {
        requests.withLockedValue { $0.append(request) }
    }
}

/// A camera plugin's HomeKit Secure Video side: yields the fragments it is given.
final class FakeRecordingDelegate: CameraRecordingDelegate, @unchecked Sendable {
    let active = NIOLockedValueBox<[Bool]>([])
    let configurations = NIOLockedValueBox<[CameraRecordingConfiguration?]>([])
    let acknowledged = NIOLockedValueBox<[Int]>([])
    let closed = NIOLockedValueBox<[(Int, HDSProtocolSpecificErrorReason?)]>([])
    var packets: [RecordingPacket] = []

    func updateRecordingActive(_ active: Bool) { self.active.withLockedValue { $0.append(active) } }
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) { configurations.withLockedValue { $0.append(configuration) } }
    func handleRecordingStreamRequest(streamID: Int) -> AsyncThrowingStream<RecordingPacket, any Error> {
        let packets = packets
        return AsyncThrowingStream { continuation in
            for packet in packets { continuation.yield(packet) }
            continuation.finish()
        }
    }
    func acknowledgeStream(streamID: Int) { acknowledged.withLockedValue { $0.append(streamID) } }
    func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?) { closed.withLockedValue { $0.append((streamID, reason)) } }
}

/// Vectors from HAP-NodeJS 2.2.2's RTPStreamManagement and RecordingManagement (scratch script camera.js).
@Suite(.timeLimit(.minutes(1)))
struct CameraTLVTests {
    static let video = VideoStreamingOptions(
        codec: H264CodecParameters(profiles: [.main], levels: [.level3_1, .level3_2, .level4_0]),
        resolutions: [VideoResolution(1920, 1080, 30), VideoResolution(1280, 720, 30), VideoResolution(640, 360, 15), VideoResolution(320, 240, 15)])
    static let audio = AudioStreamingOptions(
        codecs: [
            AudioStreamingCodec(type: .aacELD, samplerate: [.khz16]), AudioStreamingCodec(type: .aacELD, samplerate: [.khz24]),
            AudioStreamingCodec(type: .opus, bitrate: .constant, samplerate: [.khz16, .khz24]),
        ], twoWayAudio: true, comfortNoise: true)
    static let session = "8a3c7b2e-1f4d-4e6a-9b0c-2d5e8f1a3b7c"
    static let logger = Logger(label: "camera-tests")

    static func management(_ delegate: FakeStreamingDelegate) throws -> RTPStreamManagement {
        try RTPStreamManagement(
            id: 0, options: CameraStreamingOptions(supportedCryptoSuites: [.aesCM128HMACSHA1_80], video: video, audio: audio), delegate: delegate,
            logger: logger, disabledThroughOperatingMode: { false })
    }

    @Test func supportedStreamingConfigurations() throws {
        let rtp = try Self.management(FakeStreamingDelegate())
        #expect(rtp.supportedRTPConfiguration.base64EncodedString() == "AgEA")
        #expect(rtp.supportedVideoStreamConfiguration.base64EncodedString() == "AVIBAQACEwEBAQIBAAAAAgEBAAACAQIDAQADCwECgAcCAjgEAwEeAAADCwECAAUCAtACAwEeAAADCwECgAICAmgBAwEPAAADCwECQAECAvAAAwEP")
        #expect(rtp.supportedAudioStreamConfiguration.base64EncodedString() == "ARMBAQICDgEBAQIBAAMBAQAAAwECAAABEwEBAwIOAQEBAgEBAwEBAAADAQICAQE=")
        #expect(!rtp.videoOnly)
        #expect(rtp.service.subtype == "0")

        let cvo = try RTPStreamManagement(
            id: 1, options: CameraStreamingOptions(supportedCryptoSuites: [.aesCM128HMACSHA1_80, .none], video: VideoStreamingOptions(codec: Self.video.codec, resolutions: Self.video.resolutions, cvoId: 3)),
            delegate: FakeStreamingDelegate(), logger: Self.logger, disabledThroughOperatingMode: { false })
        #expect(cvo.supportedVideoStreamConfiguration.base64EncodedString() == "AVgBAQACGQEBAQIBAAAAAgEBAAACAQIDAQAEAQEFAQMDCwECgAcCAjgEAwEeAAADCwECAAUCAtACAwEeAAADCwECgAICAmgBAwEPAAADCwECQAECAvAAAwEP")
        #expect(cvo.supportedAudioStreamConfiguration.base64EncodedString() == "ARMBAQMCDgEBAQIBAAMBAQAAAwECAgEA")
        #expect(cvo.supportedRTPConfiguration.base64EncodedString() == "AgEAAAACAQI=")
        #expect(cvo.videoOnly)
    }

    @Test func setupStartReconfigureStop() async throws {
        let delegate = FakeStreamingDelegate()
        let rtp = try Self.management(delegate)
        let context = HAPRequestContext(
            connectionID: ObjectIdentifier(delegate), controllerID: "controller", localAddress: "192.168.1.10", remoteAddress: "192.168.1.20",
            sharedSecret: nil, connection: nil)
        let setup = "ARCKPHsuH01OapsMLV6PGjt8AxkBAQACDDE5Mi4xNjguMS4yMAMCOMcEAjrHBCUBAQACEKGhoaGhoaGhoaGhoaGhoaEDDqKioqKioqKioqKioqKiBSUBAQACELGxsbGxsbGxsbGxsbGxsbEDDrKysrKysrKysrKysrKy"
        try await rtp.handleSetupEndpoints(.string(setup), context: context)
        let prepare = try #require(delegate.prepares.withLockedValue { $0.first })
        #expect(prepare.sessionID == Self.session)
        #expect(prepare.sourceAddress == "192.168.1.10")
        #expect(prepare.targetAddress == "192.168.1.20")
        #expect(prepare.addressVersion == .ipv4)
        #expect(prepare.video.port == 51000)
        #expect(prepare.audio.port == 51002)
        #expect(prepare.video.srtpCryptoSuite == .aesCM128HMACSHA1_80)
        #expect(prepare.video.srtpKey == Data(repeating: 0xA1, count: 16))
        #expect(prepare.video.srtpSalt == Data(repeating: 0xA2, count: 14))
        #expect(prepare.audio.srtpKey == Data(repeating: 0xB1, count: 16))
        let setupResponse = "ARCKPHsuH01OapsMLV6PGjt8AgEAAxkBAQACDDE5Mi4xNjguMS4xMAMCUMMEAlLDBCUBAQACEBEREREREREREREREREREREDDiIiIiIiIiIiIiIiIiIiBSUBAQACEDMzMzMzMzMzMzMzMzMzMzMDDkREREREREREREREREREBgTvzasABwRWNBIA"
        #expect(try await rtp.service.characteristic(.setupEndpoints).readHandler?() == .string(setupResponse))
        #expect(rtp.service.characteristic(.streamingStatus).value == .string("AQEB"))

        // A second controller while in use: busy.
        try await rtp.handleSetupEndpoints(.string(setup), context: context)
        #expect(try await rtp.service.characteristic(.setupEndpoints).readHandler?() == .string(HAPTLV.encode((1, .data(HAPTLV.uuidBytes(Self.session))), (2, .byte(1))).base64EncodedString()))

        let selected = rtp.service.characteristic(.selectedRTPStreamConfiguration)
        try await selected.write(.string("ARUBEIo8ey4fTU5qmwwtXo8aO3wCAQECNAEBAAIJAQEBAgECAwEAAwsBAgAFAgLQAgMBHgQXAQFjAgQEAwIBAwIrAQQEAAAAPwUCYgUDLAEBAgIMAQEBAgEAAwEBBAEeAxYBAW4CBA0MCwoDAhgABAQAAKBABgENBAEA"), origin: nil)
        let start = StartStreamRequest(
            sessionID: Self.session,
            video: VideoInfo(codec: 0, profile: 1, level: 2, packetizationMode: 0, cvoId: nil, width: 1280, height: 720, fps: 30, pt: 99, ssrc: 16_909_060, maxBitRate: 299, rtcpInterval: 0.5, mtu: 1378),
            audio: AudioInfo(codec: .aacELD, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: 30, pt: 110, ssrc: 168_496_141, maxBitRate: 24, rtcpInterval: 5, comfortPT: 13, comfortNoiseEnabled: false))
        #expect(delegate.requests.withLockedValue { $0.last } == .start(start))

        try await selected.write(.string("ARUBEIo8ey4fTU5qmwwtXo8aO3wCAQQCNAEBAAIJAQEBAgECAwEAAwsBAoACAgJoAQMBDwQXAQFjAgQEAwIBAwKEAAQEAAAAAAUCYgU="), origin: nil)
        #expect(delegate.requests.withLockedValue { $0.last } == .reconfigure(ReconfigureStreamRequest(
            sessionID: Self.session, video: ReconfiguredVideoInfo(width: 640, height: 360, fps: 15, maxBitRate: 132, rtcpInterval: 0.5))))

        try await selected.write(.string("ARUBEIo8ey4fTU5qmwwtXo8aO3wCAQA="), origin: nil)
        #expect(delegate.requests.withLockedValue { $0.last } == .stop(sessionID: Self.session))
        #expect(try await selected.readHandler?() == .string("AQMCAQI="))
        #expect(try await rtp.service.characteristic(.setupEndpoints).readHandler?() == .string("AgEC"))
        #expect(rtp.service.characteristic(.streamingStatus).value == .string("AQEA"))

        // An unknown session is refused.
        await #expect(throws: HAPStatusError(.invalidValueInRequest)) {
            try await selected.write(.string("ARUBEIo8ey4fTU5qmwwtXo8aO3wCAQA="), origin: nil)
        }
    }

    static let recordingOptions = CameraRecordingOptions(
        prebufferLength: 4000, mediaContainerConfiguration: [MediaContainerConfiguration(fragmentLength: 4000)],
        video: VideoRecordingOptions(parameters: H264CodecParameters(profiles: [.main, .high], levels: [.level3_1, .level3_2, .level4_0]),
            resolutions: [VideoResolution(1920, 1080, 30), VideoResolution(1280, 720, 30)]),
        audio: [AudioRecordingCodec(type: .aacLC, samplerate: [.khz16]), AudioRecordingCodec(type: .aacELD, audioChannels: 2, bitrateMode: .constant, samplerate: [.khz48, .khz32])])

    @Test func recordingConfigurations() async throws {
        let delegate = FakeRecordingDelegate()
        let recording = try RecordingManagement(options: Self.recordingOptions, delegate: delegate, eventTriggerOptions: [.motion, .doorbell], logger: Self.logger)
        #expect(recording.supportedCameraRecordingConfiguration.base64EncodedString() == "AQSgDwAAAggDAAAAAAAAAAMLAQEAAgYBBKAPAAA=")
        #expect(recording.supportedVideoRecordingConfiguration.base64EncodedString() == "ATYBAQACFQEBAQAAAQECAgEAAAACAQEAAAIBAgMLAQKABwICOAQDAR4AAAMLAQIABQIC0AIDAR4=")
        #expect(recording.supportedAudioRecordingConfiguration.base64EncodedString() == "AQ4BAQACCQEBAQIBAAMBAQAAARMBAQECDgEBAgIBAQMBBQAAAwED")
        #expect(recording.configurationHash == "635daa0dd0c5b68c01f8d0d4bdfc5b477584390b382fbb898ca2597e7d4a123b")

        let selected = "AR0BBKAPAAACCAMAAAAAAAAAAwsBAQACBgEEoA8AAAIkAQEAAhIBAQECAQIDBNAHAAAEBKAPAAADCwECgAcCAjgEAwEeAxQBAQACDwEBAQIBAAMBAQQEQAAAAA=="
        let expected = CameraRecordingConfiguration(
            prebufferLength: 4000, eventTriggerTypes: [.motion, .doorbell], mediaContainerConfiguration: MediaContainerConfiguration(fragmentLength: 4000),
            videoCodec: .init(type: .h264, parameters: .init(profile: .main, level: .level4_0, bitRate: 2000, iFrameInterval: 4000), resolution: VideoResolution(1920, 1080, 30)),
            audioCodec: .init(audioChannels: 1, type: .aacLC, samplerate: .khz16, bitrateMode: .variable, bitrate: 64))
        #expect(try RecordingManagement.parseSelectedConfiguration(selected) == expected)

        let characteristic = recording.recordingManagementService.characteristic(.selectedCameraRecordingConfiguration)
        let saves = NIOLockedValueBox(0)
        recording.setupStateChangeDelegate { saves.withLockedValue { $0 += 1 } }
        try await characteristic.write(.string(selected), origin: nil)
        #expect(delegate.configurations.withLockedValue { $0 } == [expected])
        #expect(saves.withLockedValue { $0 } == 1)
        #expect(try await characteristic.readHandler?() == .string(selected))

        // The state survives a restart: the configuration and the switches come back and are replayed.
        recording.recordingManagementService.characteristic(.active).value = .int(1)
        let serialized = recording.serialize()
        let restoredDelegate = FakeRecordingDelegate()
        let restored = try RecordingManagement(options: Self.recordingOptions, delegate: restoredDelegate, eventTriggerOptions: [.motion, .doorbell], logger: Self.logger)
        restored.deserialize(serialized)
        #expect(restored.selectedConfiguration == expected)
        #expect(restoredDelegate.configurations.withLockedValue { $0 } == [expected])
    }
}

/// Vectors from HAP-NodeJS 2.2.2's DataStreamParser and DataStreamConnection (scratch script hds.js).
@Suite struct HDSCodecTests {
    static func hex(_ string: String) -> Data { HAPTLV.hexBytes(string) }

    @Test func encodesHeadersLikeHAPNodeJS() {
        #expect(HDSWriter.encode(["protocol": "dataSend", "event": "data"] as HDSDictionary) == Self.hex("e24870726f746f636f6c486461746153656e64456576656e744464617461"))
        #expect(HDSWriter.encode(["protocol": "dataSend", "response": "open", "id": .int64(1_234_567), "status": .int64(0)] as HDSDictionary)
            == Self.hex("e44870726f746f636f6c486461746153656e6448726573706f6e7365446f70656e4269643387d612000000000046737461747573330000000000000000"))
        #expect(HDSWriter.encode(["protocol": "control", "request": "hello", "id": .int64(42)] as HDSDictionary)
            == Self.hex("e34870726f746f636f6c47636f6e74726f6c47726571756573744568656c6c6f426964332a00000000000000"))
    }

    @Test func encodesADataEventLikeHAPNodeJS() {
        let metadata: HDSDictionary = [
            "dataType": "mediaInitialization", "dataSequenceNumber": .int(1), "dataChunkSequenceNumber": .int(1), "isLastDataChunk": .bool(true),
            "dataTotalSize": .int(300),
        ]
        let message: HDSDictionary = [
            "streamId": .int(1), "packets": .array([.dictionary(["data": .data(Data(repeating: 7, count: 300)), "metadata": .dictionary(metadata)])]),
            "endOfStream": .bool(false),
        ]
        let expected = "e34873747265616d496409477061636b657473d1e24464617461922c01" + String(repeating: "07", count: 300)
            + "486d65746164617461e5486461746154797065536d65646961496e697469616c697a6174696f6e526461746153657175656e63654e756d6265720957646174614368756e6b53657175656e63654e756d626572094f69734c617374446174614368756e6b014d64617461546f74616c53697a65312c014b656e644f6653747265616d02"
        #expect(HDSWriter.encode(message) == Self.hex(expected))
    }

    static let compressed = "e94161467265706561744162a14163dba131e803a430fb360000000000000a40a6327011010033005ed0b20000000004010241646128787878787878787878787878787878787878787878787878787878787878787878787878787878784165736162634166350000c03f4167050f7f5c268c8f4d7a9b8e3c2a1d0e9f8b4168060000000000002940a109"

    @Test func compressesRepeatedValuesLikeHAPNodeJS() {
        let value: HDSDictionary = [
            "a": "repeat", "b": "repeat",
            "c": .array(["repeat", .int(1000), .int(1000), .int(-5), .double(3.25), .double(3.25), .int(70000), .int(3_000_000_000), .null, .bool(true), .bool(false)]),
            "d": .string(String(repeating: "x", count: 40)), "e": .data(Data("abc".utf8)), "f": .float32(1.5),
            "g": .uuid("0f7f5c26-8c8f-4d7a-9b8e-3c2a1d0e9f8b"), "h": .date(12.5), "repeat": .int(1),
        ]
        #expect(HDSWriter.encode(value) == Self.hex(Self.compressed))
        let many = HDSDictionary((0..<16).map { HDSDictionary.Entry(key: "k\($0)", value: .int(Int64($0))) })
        #expect(HDSWriter.encode(many) == Self.hex("ef426b3008426b3109426b320a426b330b426b340c426b350d426b360e426b370f426b3810426b3911436b313012436b313113436b313214436b313315436b313416436b31351703"))
        #expect(HDSWriter.encode(.array((0..<13).map { .int(Int64($0 * 100)) })) == Self.hex("df08306431c800312c0131900131f40131580231bc0231200331840331e803314c0431b00403"))
    }

    @Test func decodesWhatHAPNodeJSEncodes() throws {
        let decoded = try #require(try HDSReader.decode(Self.hex(Self.compressed)).dictionaryValue)
        #expect(decoded["a"] == "repeat")
        #expect(decoded["b"] == "repeat")
        #expect(decoded["c"] == .array(["repeat", .int(1000), .int(1000), .int(-5), .double(3.25), .double(3.25), .int(70000), .int(3_000_000_000), .null, .bool(true), .bool(false)]))
        // HAP-NodeJS returns nothing for short data (a missing return); the bytes are what was sent.
        #expect(decoded["e"] == .data(Data("abc".utf8)))
        #expect(decoded["f"] == .double(1.5))
        #expect(decoded["g"] == .uuid("0f7f5c26-8c8f-4d7a-9b8e-3c2a1d0e9f8b"))
        #expect(decoded["h"] == .double(12.5))
        #expect(decoded["repeat"] == .int(1))
        let many = try #require(try HDSReader.decode(Self.hex("ef426b3008426b3109426b320a426b330b426b340c426b350d426b360e426b370f426b3810426b3911436b313012436b313113436b313214436b313315436b313416436b31351703")).dictionaryValue)
        #expect(many.entries.count == 16)
        #expect(many["k15"] == .int(15))
    }

    @Test func derivesKeysAndSealsFramesLikeHAPNodeJS() throws {
        let keys = HDSFrame.keys(sharedSecret: Data(repeating: 1, count: 32), controllerKeySalt: Data(repeating: 2, count: 32), accessoryKeySalt: Data(repeating: 3, count: 32))
        #expect(keys.accessoryToController.withUnsafeBytes { Data($0) } == Self.hex("3f4d50bff63e61f935f23f6333ebb98aad7180d6b084a89eca567e41c12fc2ed"))
        #expect(keys.controllerToAccessory.withUnsafeBytes { Data($0) } == Self.hex("dbdffef30fd1a0ef3ecb1816f8dc96836b35da57cedaabcb0c5418ce7a695911"))

        let key = SymmetricKeyForTests.nines
        let hello = HDSFrame.payload(header: ["protocol": "control", "request": "hello", "id": .int64(1)], message: [:])
        let frame0 = "0100002eb2e7f688e1b5202b169bd7eadf5d13fa84800f2fb26a0c42847a0232ea423353b29f0dcfb67a54b86d0a37a7d517c37a80bdf9511d0881147ab7b0d87cd2"
        #expect(try HDSFrame.seal(payload: hello, key: key, counter: 0) == Self.hex(frame0))
        let frame1 = "010000362f0f5fed4cbba2e37c3a346b93bbc2d3187e51e7524b0a02a1e28fa8ae284f9a217b981d075dc84468eee20e88f844c6eb71cf6e126f203b8a42578a330454dd2164b4dbc0b8"
        var buffer = Self.hex(frame0 + frame1) + Data([1, 0])
        let frames = try HDSFrame.split(&buffer)
        #expect(frames.count == 2)
        #expect(buffer == Data([1, 0]))
        let ack = try #require(HDSFrame.message(from: try HDSFrame.open(frames[1], key: key, counter: 1)))
        #expect(ack == HDSFrame.Message(kind: .event, protocol: "dataSend", topic: "ack", message: ["streamId": .int(1), "endOfStream": .bool(true)]))
        let decodedHello = try #require(HDSFrame.message(from: try HDSFrame.open(frames[0], key: key, counter: 0)))
        #expect(decodedHello.kind == .request(id: 1))
        #expect(throws: (any Error).self) { try HDSFrame.open(frames[1], key: key, counter: 0) }
    }
}

import Crypto

enum SymmetricKeyForTests {
    static let nines = SymmetricKey(data: Data(repeating: 9, count: 32))
}
