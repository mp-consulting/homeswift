import Foundation
import Logging
import NIOConcurrencyHelpers

/// One Camera RTP Stream Management service (HAP-NodeJS's RTPStreamManagement): the supported configurations,
/// Setup Endpoints (where each side sends RTP, SRTP keys, SSRCs), the selected stream configuration (start,
/// reconfigure, stop) and the streaming status. A camera has several, so several controllers can watch at once.
final class RTPStreamManagement: @unchecked Sendable {
    let id: Int
    let service: Service
    let delegate: any CameraStreamingDelegate
    let logger: Logger
    let supportedCryptoSuites: [SRTPCryptoSuite]
    /// No audio codec was given: HomeKit gets a fake Opus one, and prepareStream may answer without audio.
    let videoOnly: Bool
    let supportedRTPConfiguration: Data
    let supportedVideoStreamConfiguration: Data
    let supportedAudioStreamConfiguration: Data
    /// Whether the camera is off through its operating mode (HomeKit Camera Active), from the recording management.
    let disabledThroughOperatingMode: @Sendable () -> Bool

    enum StreamingStatus: UInt8 {
        case available = 0
        case inUse = 1
        case unavailable = 2
    }

    private struct State {
        var activeConnection: ObjectIdentifier?
        var sessionIdentifier: String?
        var streamStatus = StreamingStatus.available
        var ipVersion: IPAddressVersion?
        var selectedConfiguration = ""
        var setupEndpointsResponse = ""
        var stateChangeDelegate: (@Sendable () -> Void)?
    }

    private let state = NIOLockedValueBox(State())

    init(
        id: Int, options: CameraStreamingOptions, delegate: any CameraStreamingDelegate, logger: Logger,
        disabledThroughOperatingMode: @escaping @Sendable () -> Bool
    ) throws {
        self.id = id
        self.delegate = delegate
        self.logger = logger
        self.disabledThroughOperatingMode = disabledThroughOperatingMode
        supportedCryptoSuites = options.supportedCryptoSuites.isEmpty ? [.none] : options.supportedCryptoSuites
        if supportedCryptoSuites == [.none] {
            logger.debug("The camera does not support SRTP. The stream may stop working with future iOS releases.")
        }
        supportedRTPConfiguration = Self.supportedRTPConfiguration(supportedCryptoSuites)
        supportedVideoStreamConfiguration = try Self.supportedVideoStreamConfiguration(options.video)
        (supportedAudioStreamConfiguration, videoOnly) = try Self.supportedAudioStreamConfiguration(options.audio, logger: logger)

        service = Service(.cameraRTPStreamManagement, subtype: String(id))
        setupServiceHandlers()
        resetSetupEndpointsResponse()
        resetSelectedStreamConfiguration()
    }

    var sessionIdentifier: String? { state.withLockedValue { $0.sessionIdentifier } }
    var streamStatus: StreamingStatus { state.withLockedValue { $0.streamStatus } }

    func setupStateChangeDelegate(_ delegate: (@Sendable () -> Void)?) {
        state.withLockedValue { $0.stateChangeDelegate = delegate }
    }

    private func setupServiceHandlers() {
        let active = service.characteristic(adding: .active)
        active.set(.int(1), notify: false)
        active.observe { [weak self] _ in self?.state.withLockedValue { $0.stateChangeDelegate }?() }
        service.characteristic(.supportedRTPConfiguration).set(.string(supportedRTPConfiguration.base64EncodedString()), notify: false)
        service.characteristic(.supportedVideoStreamConfiguration).set(.string(supportedVideoStreamConfiguration.base64EncodedString()), notify: false)
        service.characteristic(.supportedAudioStreamConfiguration).set(.string(supportedAudioStreamConfiguration.base64EncodedString()), notify: false)
        updateStreamStatus(.available)

        service.characteristic(.selectedRTPStreamConfiguration)
            .onRead { [weak self] in
                guard let self else { return .string("") }
                if self.streamingIsDisabled { return .string(Self.suspendedConfiguration.base64EncodedString()) }
                return .string(self.state.withLockedValue { $0.selectedConfiguration })
            }
            .onWrite { [weak self] value in try await self?.handleSelectedStreamConfigurationWrite(value) }

        service.characteristic(.setupEndpoints)
            .onRead { [weak self] in
                guard let self else { return .string("") }
                if self.streamingIsDisabled { return .string(HAPTLV.encode((2, .byte(2))).base64EncodedString()) }
                return .string(self.state.withLockedValue { $0.setupEndpointsResponse })
            }
            .onWrite { [weak self] value in
                guard let self else { return }
                guard let context = HAPRequestContext.current else {
                    self.logger.debug("Setup Endpoints cannot be written from a plugin: there is no connection")
                    throw HAPStatusError(.invalidValueInRequest)
                }
                try await self.handleSetupEndpoints(value, context: context)
            }
    }

    /// Streaming is off: the service's Active, or HomeKit Camera Active of the operating mode.
    var streamingIsDisabled: Bool {
        (service[.active]?.value.intValue ?? 1) == 0 || disabledThroughOperatingMode()
    }

    static let suspendedConfiguration = HAPTLV.encode((1, .data(HAPTLV.encode((2, .byte(2))))))

    func resetSetupEndpointsResponse() {
        let response = HAPTLV.encode((2, .byte(2))).base64EncodedString()
        state.withLockedValue { $0.setupEndpointsResponse = response }
        service.characteristic(.setupEndpoints).set(.string(response))
    }

    func resetSelectedStreamConfiguration() {
        let selected = Self.suspendedConfiguration.base64EncodedString()
        state.withLockedValue { $0.selectedConfiguration = selected }
        service.characteristic(.selectedRTPStreamConfiguration).set(.string(selected))
    }

    private func updateStreamStatus(_ status: StreamingStatus) {
        state.withLockedValue { $0.streamStatus = status }
        service.characteristic(.streamingStatus).set(.string(HAPTLV.encode((1, .byte(status.rawValue))).base64EncodedString()))
    }

    /// Back to available: no session, no connection.
    func handleSessionClosed() {
        resetSelectedStreamConfiguration()
        resetSetupEndpointsResponse()
        state.withLockedValue { state in
            state.activeConnection = nil
            state.sessionIdentifier = nil
            state.ipVersion = nil
        }
        updateStreamStatus(.available)
    }

    func forceStop() {
        handleSessionClosed()
    }

    func destroy() {
        if state.withLockedValue({ $0.activeConnection != nil }) {
            Task { try? await handleStopStream() }
        }
    }

    // MARK: Selected stream configuration

    private func handleSelectedStreamConfigurationWrite(_ value: HAPValue) async throws {
        if streamingIsDisabled { throw HAPStatusError(.notAllowedInCurrentState) }
        guard let base64 = value.stringValue, let data = Data(base64Encoded: base64), let objects = try? HAPTLV.decode(data),
            let control = objects[1], let sessionControl = try? HAPTLV.decode(control),
            let identifier = sessionControl[1], let command = sessionControl[2]?.first
        else { throw HAPStatusError(.invalidValueInRequest) }
        let sessionIdentifier = HAPTLV.uuidString(identifier)
        guard sessionIdentifier == self.sessionIdentifier else {
            logger.debug("Received an unknown session identifier", metadata: ["command": "\(command)"])
            throw HAPStatusError(.invalidValueInRequest)
        }
        state.withLockedValue { $0.selectedConfiguration = base64 }

        do {
            switch command {
            case 1:  // start
                let request: StartStreamRequest
                do {
                    request = try parseStartRequest(sessionID: sessionIdentifier, video: try HAPTLV.decode(objects[2] ?? Data()), audio: try HAPTLV.decode(objects[3] ?? Data()))
                } catch {
                    logger.debug("Failed to parse a stream start request", metadata: ["error": "\(error)"])
                    throw HAPStatusError(.invalidValueInRequest)
                }
                try await delegate.handleStreamRequest(.start(request))
            case 4:  // reconfigure
                let request = try parseReconfigureRequest(sessionID: sessionIdentifier, video: try HAPTLV.decode(objects[2] ?? Data()))
                try await delegate.handleStreamRequest(.reconfigure(request))
            case 0:  // end
                try await handleStopStream()
            default:  // suspend and resume are not used by HomeKit
                logger.debug("Unhandled stream request", metadata: ["command": "\(command)"])
                throw HAPStatusError(.invalidValueInRequest)
            }
        } catch {
            // As HAP-NodeJS: a failed start, reconfigure or end ends the session.
            if [0, 1, 4].contains(command) { handleSessionClosed() }
            throw error
        }
    }

    enum RequestError: Error {
        case unknownAudioCodec(UInt8)
        case unknownSamplerate(UInt8)
    }

    /// A required item: absent or empty is `HAPTLV.DecodingError.missing`.
    private func value(_ tlv: [UInt8: Data], _ type: UInt8, _ name: String) throws -> Data {
        try HAPTLV.required(tlv, type, name, nonEmpty: true)
    }

    func parseStartRequest(sessionID: String, video: [UInt8: Data], audio: [UInt8: Data]) throws -> StartStreamRequest {
        let codec = try value(video, 1, "video codec")[0]
        let parameters = try HAPTLV.decode(try value(video, 2, "video parameters"))
        let attributes = try HAPTLV.decode(try value(video, 3, "video attributes"))
        let rtp = try HAPTLV.decode(try value(video, 4, "video RTP parameters"))
        var cvoID: Int?
        if parameters[4]?.first == 1 { cvoID = Int(try value(parameters, 5, "CVO id")[0]) }
        let ipVersion = state.withLockedValue { $0.ipVersion }
        var mtu = ipVersion == .ipv6 ? 1228 : 1378
        if let maxMTU = rtp[5], maxMTU.count >= 2 { mtu = Int(HAPTLV.readUInt(maxMTU.prefix(2))) }
        let videoInfo = VideoInfo(
            codec: codec,
            profile: try value(parameters, 1, "profile")[0], level: try value(parameters, 2, "level")[0],
            packetizationMode: try value(parameters, 3, "packetization mode")[0], cvoId: cvoID,
            width: Int(HAPTLV.readUInt(try value(attributes, 1, "width").prefix(2))),
            height: Int(HAPTLV.readUInt(try value(attributes, 2, "height").prefix(2))),
            fps: Int(try value(attributes, 3, "frame rate")[0]),
            pt: Int(try value(rtp, 1, "payload type")[0]),
            ssrc: UInt32(HAPTLV.readUInt(try value(rtp, 2, "SSRC").prefix(4))),
            maxBitRate: Int(HAPTLV.readUInt(try value(rtp, 3, "max bit rate").prefix(2))),
            rtcpInterval: try HAPTLV.readFloat32(try value(rtp, 4, "RTCP interval")),
            mtu: mtu)

        let audioCodec = try value(audio, 1, "audio codec")[0]
        let audioParameters = try HAPTLV.decode(try value(audio, 2, "audio parameters"))
        let audioRTP = try HAPTLV.decode(try value(audio, 3, "audio RTP parameters"))
        let comfortNoise = try value(audio, 4, "comfort noise")[0] != 0
        guard let codecType = AudioStreamingCodecType(tlvValue: audioCodec) else { throw RequestError.unknownAudioCodec(audioCodec) }
        let samplerate = try value(audioParameters, 3, "sample rate")[0]
        let sampleRate: Int
        switch samplerate {
        case 0: sampleRate = 8
        case 1: sampleRate = 16
        case 2: sampleRate = 24
        default: throw RequestError.unknownSamplerate(samplerate)
        }
        let audioInfo = AudioInfo(
            codec: codecType, channel: Int(try value(audioParameters, 1, "channels")[0]),
            bitRate: AudioBitrate(rawValue: try value(audioParameters, 2, "bit rate")[0]) ?? .variable, sampleRate: sampleRate,
            packetTime: Int(try value(audioParameters, 4, "packet time")[0]),
            pt: Int(try value(audioRTP, 1, "payload type")[0]),
            ssrc: UInt32(HAPTLV.readUInt(try value(audioRTP, 2, "SSRC").prefix(4))),
            maxBitRate: Int(HAPTLV.readUInt(try value(audioRTP, 3, "max bit rate").prefix(2))),
            rtcpInterval: try HAPTLV.readFloat32(try value(audioRTP, 4, "RTCP interval")),
            comfortPT: Int(try value(audioRTP, 6, "comfort noise payload type")[0]),
            comfortNoiseEnabled: comfortNoise)
        return StartStreamRequest(sessionID: sessionID, video: videoInfo, audio: audioInfo)
    }

    func parseReconfigureRequest(sessionID: String, video: [UInt8: Data]) throws -> ReconfigureStreamRequest {
        let attributes = try HAPTLV.decode(try value(video, 3, "video attributes"))
        let rtp = try HAPTLV.decode(try value(video, 4, "video RTP parameters"))
        var interval = try HAPTLV.readFloat32(try value(rtp, 4, "RTCP interval"))
        // Seems to be always zero; HAP-NodeJS uses 0.5.
        if interval == 0 { interval = 0.5 }
        return ReconfigureStreamRequest(
            sessionID: sessionID,
            video: ReconfiguredVideoInfo(
                width: Int(HAPTLV.readUInt(try value(attributes, 1, "width").prefix(2))),
                height: Int(HAPTLV.readUInt(try value(attributes, 2, "height").prefix(2))),
                fps: Int(try value(attributes, 3, "frame rate")[0]),
                maxBitRate: Int(HAPTLV.readUInt(try value(rtp, 3, "max bit rate").prefix(2))), rtcpInterval: interval))
    }

    func handleStopStream() async throws {
        let sessionID = sessionIdentifier
        handleSessionClosed()
        try await delegate.handleStreamRequest(.stop(sessionID: sessionID ?? ""))
    }

    // MARK: Setup endpoints

    func handleSetupEndpoints(_ value: HAPValue, context: HAPRequestContext) async throws {
        if streamingIsDisabled { throw HAPStatusError(.notAllowedInCurrentState) }
        guard let base64 = value.stringValue, let data = Data(base64Encoded: base64), let objects = try? HAPTLV.decode(data),
            let identifierData = objects[1]
        else { throw HAPStatusError(.invalidValueInRequest) }
        let sessionIdentifier = HAPTLV.uuidString(identifierData)

        let claimed = state.withLockedValue { state -> Bool in
            guard state.streamStatus == .available else {
                state.setupEndpointsResponse = HAPTLV.encode((1, .data(HAPTLV.uuidBytes(sessionIdentifier))), (2, .byte(1))).base64EncodedString()
                return false
            }
            state.activeConnection = context.connectionID
            state.sessionIdentifier = sessionIdentifier
            return true
        }
        guard claimed else { return }
        updateStreamStatus(.inUse)
        // The stream ends with the controller's connection.
        context.onClose { [weak self] in
            guard let self, self.state.withLockedValue({ $0.activeConnection == context.connectionID && $0.sessionIdentifier == sessionIdentifier }) else { return }
            Task { try? await self.handleStopStream() }
        }

        let request: PrepareStreamRequest
        do {
            let address = try HAPTLV.decode(try self.value(objects, 3, "controller address"))
            let videoSRTP = try HAPTLV.decode(try self.value(objects, 4, "video SRTP parameters"))
            let audioSRTP = try HAPTLV.decode(try self.value(objects, 5, "audio SRTP parameters"))
            let version: IPAddressVersion = (address[1]?.first ?? 0) == 1 ? .ipv6 : .ipv4
            func source(_ srtp: [UInt8: Data], port: Data?) throws -> PrepareStreamRequest.Source {
                PrepareStreamRequest.Source(
                    port: Int(HAPTLV.readUInt((port ?? Data()).prefix(2))),
                    srtpCryptoSuite: SRTPCryptoSuite(rawValue: srtp[1]?.first ?? 2) ?? .none,
                    srtpKey: srtp[2] ?? Data(), srtpSalt: srtp[3] ?? Data())
            }
            request = PrepareStreamRequest(
                sessionID: sessionIdentifier, sourceAddress: context.localAddress ?? "",
                targetAddress: String(decoding: address[2] ?? Data(), as: UTF8.self), addressVersion: version,
                video: try source(videoSRTP, port: address[3]), audio: try source(audioSRTP, port: address[4]))
        } catch {
            handleSessionClosed()
            throw HAPStatusError(.invalidValueInRequest)
        }
        // Never log the SRTP keys.
        logger.debug("Setup endpoints", metadata: [
            "session": "\(sessionIdentifier)", "controller": "\(request.targetAddress)", "videoPort": "\(request.video.port)",
            "audioPort": "\(request.audio.port)", "videoCrypto": "\(request.video.srtpCryptoSuite)", "audioCrypto": "\(request.audio.srtpCryptoSuite)",
        ])

        let response: PrepareStreamResponse
        do {
            response = try await delegate.prepareStream(request)
        } catch {
            logger.debug("prepareStream failed", metadata: ["error": "\(error)"])
            let failed = HAPTLV.encode((1, .data(HAPTLV.uuidBytes(sessionIdentifier))), (2, .byte(2))).base64EncodedString()
            handleSessionClosed()
            state.withLockedValue { $0.setupEndpointsResponse = failed }
            throw error
        }
        do {
            try generateSetupEndpointResponse(context: context, identifier: sessionIdentifier, request: request, response: response)
        } catch {
            logger.error("Invalid prepareStream response", metadata: ["error": "\(error)"])
            handleSessionClosed()
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    enum ResponseError: Error, CustomStringConvertible {
        case missingAudio
        case addressVersionMismatch(expected: IPAddressVersion, got: IPAddressVersion)
        case missingSRTP(String)

        var description: String {
            switch self {
            case .missingAudio: "Audio was enabled but not supplied in PrepareStreamResponse!"
            case .addressVersionMismatch(let expected, let got): "Incoming and outgoing ip address versions must match! Expected \(expected) but got \(got)"
            case .missingSRTP(let stream): "SRTP was selected for the prepared \(stream) stream, but no srtpKey or srtpSalt was specified!"
            }
        }
    }

    func generateSetupEndpointResponse(context: HAPRequestContext, identifier: String, request: PrepareStreamRequest, response: PrepareStreamResponse) throws {
        if !videoOnly, response.audio == nil { throw ResponseError.missingAudio }
        let audio = response.audio
            ?? PrepareStreamResponse.Stream(
                port: request.audio.port, ssrc: CameraController.generateSynchronisationSource(), srtpKey: request.audio.srtpKey,
                srtpSalt: request.audio.srtpSalt)
        var addressVersion = request.addressVersion
        let address: String
        if let override = response.addressOverride {
            addressVersion = HAPRequestContext.isIPv6(override) ? .ipv6 : .ipv4
            address = override
        } else {
            address = context.localAddress ?? ""
        }
        guard addressVersion == request.addressVersion else {
            throw ResponseError.addressVersionMismatch(expected: request.addressVersion, got: addressVersion)
        }
        if request.video.srtpCryptoSuite != .none, response.video.srtpKey == nil || response.video.srtpSalt == nil {
            throw ResponseError.missingSRTP("video")
        }
        if request.audio.srtpCryptoSuite != .none, audio.srtpKey == nil || audio.srtpSalt == nil {
            throw ResponseError.missingSRTP("audio")
        }
        state.withLockedValue { $0.ipVersion = addressVersion }
        let accessoryAddress = HAPTLV.encode(
            (1, .byte(addressVersion == .ipv4 ? 0 : 1)),
            (2, .data(Data(address.utf8))),
            (3, .data(HAPTLV.uint16(UInt16(clamping: response.video.port)))),
            (4, .data(HAPTLV.uint16(UInt16(clamping: audio.port)))))
        let videoSRTP = HAPTLV.encode(
            (1, .byte(request.video.srtpCryptoSuite.rawValue)), (2, .data(response.video.srtpKey ?? Data())), (3, .data(response.video.srtpSalt ?? Data())))
        let audioSRTP = HAPTLV.encode(
            (1, .byte(request.audio.srtpCryptoSuite.rawValue)), (2, .data(audio.srtpKey ?? Data())), (3, .data(audio.srtpSalt ?? Data())))
        let setup = HAPTLV.encode(
            (1, .data(HAPTLV.uuidBytes(identifier))),
            (2, .byte(0)),
            (3, .data(accessoryAddress)),
            (4, .data(videoSRTP)),
            (5, .data(audioSRTP)),
            (6, .data(HAPTLV.uint32(response.video.ssrc))),
            (7, .data(HAPTLV.uint32(audio.ssrc))))
        state.withLockedValue { $0.setupEndpointsResponse = setup.base64EncodedString() }
    }

    // MARK: Supported configurations

    static func supportedRTPConfiguration(_ suites: [SRTPCryptoSuite]) -> Data {
        HAPTLV.encode((2, .list(suites.map { Data([$0.rawValue]) })))
    }

    enum OptionsError: Error, CustomStringConvertible {
        case noResolutions
        case emptySamplerate

        var description: String {
            switch self {
            case .noResolutions: "Video resolutions cannot be undefined"
            case .emptySamplerate: "Audio samplerate cannot be empty!"
            }
        }
    }

    static func supportedVideoStreamConfiguration(_ video: VideoStreamingOptions) throws -> Data {
        guard !video.resolutions.isEmpty else { throw OptionsError.noResolutions }
        var parameters = HAPTLV.encode(
            (1, .list(video.codec.profiles.map { Data([$0.rawValue]) })),
            (2, .list(video.codec.levels.map { Data([$0.rawValue]) })),
            (3, .byte(VideoCodecPacketizationMode.nonInterleaved.rawValue)))
        if let cvoID = video.cvoId {
            parameters.append(HAPTLV.encode((4, .byte(1)), (5, .byte(UInt8(clamping: cvoID)))))
        }
        let configuration = HAPTLV.encode(
            (1, .byte(VideoCodecType.h264.rawValue)),
            (2, .data(parameters)),
            (3, .list(video.resolutions.map(RecordingManagement.resolutionTLV))))
        return HAPTLV.encode((1, .data(configuration)))
    }

    static func supportedAudioStreamConfiguration(_ audio: AudioStreamingOptions?, logger: Logger) throws -> (Data, videoOnly: Bool) {
        // Several entries of one codec are merged into one with all their sample rates, as HAP-NodeJS does.
        var codecs: [AudioStreamingCodec] = []
        for codec in audio?.codecs ?? [] {
            if let index = codecs.firstIndex(where: { $0.type == codec.type }) {
                codecs[index].samplerate += codec.samplerate
            } else {
                codecs.append(codec)
            }
        }
        var videoOnly = false
        if codecs.isEmpty {
            // HomeKit wants an audio codec to start the video; Opus at 16 and 24 kHz (Apple Watch needs 16).
            logger.debug("The camera supports no audio codec HomeKit supports.")
            videoOnly = true
            codecs = [AudioStreamingCodec(type: .opus, samplerate: [.khz16, .khz24])]
        }
        let configurations = try codecs.map { codec -> Data in
            guard !codec.samplerate.isEmpty else { throw OptionsError.emptySamplerate }
            let parameters = HAPTLV.encode(
                (1, .byte(UInt8(clamping: max(1, codec.audioChannels)))),
                (2, .byte(codec.bitrate.rawValue)),
                (3, .list(codec.samplerate.map { Data([$0.tlvValue.rawValue]) })))
            return HAPTLV.encode((1, .byte(codec.type.tlvValue)), (2, .data(parameters)))
        }
        let comfortNoise = audio?.comfortNoise ?? false
        return (HAPTLV.encode((1, .list(configurations)), (2, .byte(comfortNoise ? 1 : 0))), videoOnly)
    }

    // MARK: State

    struct Serialized: Codable {
        var id: Int
        var active: Bool
    }

    /// Only an inactive stream is kept (active is the default).
    func serialize() -> Serialized? {
        let active = (service[.active]?.value.intValue ?? 1) != 0
        return active ? nil : Serialized(id: id, active: false)
    }

    func deserialize(_ serialized: Serialized) {
        guard serialized.id == id else { return }
        service.characteristic(.active).value = .bool(serialized.active)
    }
}
