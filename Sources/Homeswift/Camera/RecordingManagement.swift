import Crypto
import Foundation
import Logging
import NIOConcurrencyHelpers

/// HomeKit Secure Video (HAP-NodeJS's RecordingManagement): the Camera Recording Management, Camera Operating Mode
/// and Data Stream Transport Management services, the recording configurations, and the `dataSend` streams a
/// home hub opens over HomeKit Data Stream to fetch recordings.
final class RecordingManagement: @unchecked Sendable {
    let options: CameraRecordingOptions
    let delegate: any CameraRecordingDelegate
    let recordingManagementService: Service
    let operatingModeService: Service
    let dataStreamManagement: DataStreamManagement
    let logger: Logger
    let supportedCameraRecordingConfiguration: Data
    let supportedVideoRecordingConfiguration: Data
    let supportedAudioRecordingConfiguration: Data
    let eventTriggerOptions: Int
    /// Of the three supported configurations, saved with the state.
    let configurationHash: String

    private struct State {
        var selectedConfiguration: (parsed: CameraRecordingConfiguration, base64: String)?
        var recordingActive = false
        var recordingStream: CameraRecordingStream?
        var sensorServices: [Service] = []
        var stateChangeDelegate: (@Sendable () -> Void)?
    }

    private let state = NIOLockedValueBox(State())

    init(options: CameraRecordingOptions, delegate: any CameraRecordingDelegate, eventTriggerOptions: Set<EventTriggerOption>, logger: Logger) throws {
        self.options = options
        self.delegate = delegate
        self.logger = logger
        self.eventTriggerOptions = eventTriggerOptions.reduce(0) { $0 | $1.rawValue }

        recordingManagementService = Service(.cameraRecordingManagement)
        recordingManagementService.characteristic(.active).set(.int(0), notify: false)
        recordingManagementService.characteristic(adding: .recordingAudioActive).set(.int(0), notify: false)
        operatingModeService = Service(.cameraOperatingMode)
        operatingModeService.characteristic(.eventSnapshotsActive).set(.int(1), notify: false)
        operatingModeService.characteristic(.homeKitCameraActive).set(.int(1), notify: false)
        operatingModeService.characteristic(adding: .periodicSnapshotsActive).set(.int(1), notify: false)
        dataStreamManagement = DataStreamManagement(logger: logger)
        recordingManagementService.linked = [dataStreamManagement.service]

        supportedCameraRecordingConfiguration = Self.supportedCameraRecordingConfiguration(options, eventTriggerOptions: self.eventTriggerOptions)
        supportedVideoRecordingConfiguration = try Self.supportedVideoRecordingConfiguration(options.video)
        supportedAudioRecordingConfiguration = try Self.supportedAudioRecordingConfiguration(options.audio)
        configurationHash = Self.configurationHash(
            supportedCameraRecordingConfiguration, supportedVideoRecordingConfiguration, supportedAudioRecordingConfiguration)
        setupServiceHandlers()
        logger.debug("RecordingManagement created", metadata: ["eventTriggers": "0x\(String(self.eventTriggerOptions, radix: 16))"])
    }

    var recordingActive: Bool { state.withLockedValue { $0.recordingActive } }
    var selectedConfiguration: CameraRecordingConfiguration? { state.withLockedValue { $0.selectedConfiguration?.parsed } }

    func addSensorService(_ service: Service) {
        state.withLockedValue { $0.sensorServices.append(service) }
    }

    func setupStateChangeDelegate(_ delegate: (@Sendable () -> Void)?) {
        state.withLockedValue { $0.stateChangeDelegate = delegate }
    }

    private func stateChanged() {
        state.withLockedValue { $0.stateChangeDelegate }?()
    }

    private func setupServiceHandlers() {
        let recording = recordingManagementService
        recording.characteristic(adding: .supportedCameraRecordingConfiguration).set(.string(supportedCameraRecordingConfiguration.base64EncodedString()), notify: false)
        recording.characteristic(adding: .supportedVideoRecordingConfiguration).set(.string(supportedVideoRecordingConfiguration.base64EncodedString()), notify: false)
        recording.characteristic(adding: .supportedAudioRecordingConfiguration).set(.string(supportedAudioRecordingConfiguration.base64EncodedString()), notify: false)

        recording.characteristic(adding: .selectedCameraRecordingConfiguration)
            .onRead { [weak self] in
                guard let base64 = self?.state.withLockedValue({ $0.selectedConfiguration?.base64 }) else {
                    throw HAPStatusError(.serviceCommunicationFailure)
                }
                return .string(base64)
            }
            .onWrite { [weak self] value in try self?.handleSelectedConfigurationWrite(value) }

        recording.characteristic(.active)
            .onWrite { [weak self] value in
                guard let self else { return }
                let active = (value.intValue ?? 0) != 0
                let changed = self.state.withLockedValue { state -> Bool in
                    guard state.recordingActive != active else { return false }
                    state.recordingActive = active
                    return true
                }
                // The delegate is told of changes only.
                guard changed else { return }
                self.logger.debug("Recording active changed", metadata: ["active": "\(active)"])
                self.delegate.updateRecordingActive(active)
            }
            .observe { [weak self] _ in self?.stateChanged() }
        recording.characteristic(.recordingAudioActive).observe { [weak self] _ in self?.stateChanged() }

        operatingModeService.characteristic(.homeKitCameraActive).observe { [weak self] change in
            guard let self else { return }
            let active = (change.newValue.intValue ?? 0) != 0
            let (sensors, stream) = self.state.withLockedValue { ($0.sensorServices, $0.recordingStream) }
            for service in sensors { service[.statusActive]?.value = .bool(active) }
            if !active, let stream { stream.close(reason: .notAllowed) }
            self.stateChanged()
        }
        operatingModeService.characteristic(.eventSnapshotsActive).observe { [weak self] _ in self?.stateChanged() }
        operatingModeService.characteristic(.periodicSnapshotsActive).observe { [weak self] _ in self?.stateChanged() }

        dataStreamManagement.onRequestMessage("dataSend", "open") { [weak self] connection, id, message in
            self?.handleDataSendOpen(connection, id: id, message: message)
        }
    }

    private func refuse(_ connection: DataStreamConnection, _ id: Int64, _ reason: HDSProtocolSpecificErrorReason) {
        _ = try? connection.sendResponse("dataSend", "open", id: id, status: .protocolSpecificError, ["status": .int(Int64(reason.rawValue))])
    }

    func handleDataSendOpen(_ connection: DataStreamConnection, id: Int64, message: HDSDictionary) {
        let streamID = Int(message["streamId"]?.intValue ?? 0)
        let type = message["type"]?.stringValue
        let target = message["target"]?.stringValue
        let reason = message["reason"]?.stringValue
        guard target == "controller", type == "ipcamera.recording" else {
            logger.debug("Received data send with an unexpected target or type", metadata: ["remote": "\(connection.remoteAddress)", "target": "\(target ?? "-")", "type": "\(type ?? "-")"])
            refuse(connection, id, .unexpectedFailure)
            return
        }
        let (active, busy, configured) = state.withLockedValue { ($0.recordingActive, $0.recordingStream, $0.selectedConfiguration != nil) }
        guard active else {
            logger.debug("Rejecting data send open: recording is not active", metadata: ["remote": "\(connection.remoteAddress)"])
            refuse(connection, id, .notAllowed)
            return
        }
        guard (operatingModeService.characteristic(.homeKitCameraActive).value.intValue ?? 0) != 0 else {
            logger.debug("Rejecting data send open: the HomeKit camera is off", metadata: ["remote": "\(connection.remoteAddress)"])
            refuse(connection, id, .notAllowed)
            return
        }
        if let busy {
            logger.debug("Rejecting data send open: another stream is recording", metadata: [
                "remote": "\(connection.remoteAddress)", "other": "\(busy.connection.remoteAddress)", "streamId": "\(busy.streamID)",
            ])
            refuse(connection, id, .busy)
            return
        }
        guard configured else {
            logger.debug("Rejecting data send open: no recording configuration selected", metadata: ["remote": "\(connection.remoteAddress)"])
            refuse(connection, id, .invalidConfiguration)
            return
        }
        logger.debug("Data send open", metadata: ["remote": "\(connection.remoteAddress)", "reason": "\(reason ?? "-")"])
        let stream = CameraRecordingStream(connection: connection, delegate: delegate, requestID: id, streamID: streamID, logger: logger)
        stream.onClosed { [weak self, weak stream] in
            self?.state.withLockedValue { state in
                if state.recordingStream === stream { state.recordingStream = nil }
            }
        }
        state.withLockedValue { $0.recordingStream = stream }
        stream.start()
    }

    private func handleSelectedConfigurationWrite(_ value: HAPValue) throws {
        guard let base64 = value.stringValue else { throw HAPStatusError(.invalidValueInRequest) }
        let configuration = try Self.parseSelectedConfiguration(base64)
        let changed = state.withLockedValue { state -> Bool in
            let changed = state.selectedConfiguration?.base64 != base64
            state.selectedConfiguration = (configuration, base64)
            return changed
        }
        logger.debug("Selected recording configuration written", metadata: ["changed": "\(changed)"])
        if changed {
            delegate.updateRecordingConfiguration(configuration)
            stateChanged()
        }
    }

    // MARK: TLVs

    enum ConfigurationError: Error {
        case missing(String)
        case invalid(String)
    }

    static func parseSelectedConfiguration(_ base64: String) throws -> CameraRecordingConfiguration {
        guard let data = Data(base64Encoded: base64) else { throw ConfigurationError.invalid("base64") }
        func int32(_ data: Data) -> Int { Int(Int32(truncatingIfNeeded: HAPTLV.readUInt(data.prefix(4)))) }
        func int16(_ data: Data) -> Int { Int(Int16(truncatingIfNeeded: HAPTLV.readUInt(data.prefix(2)))) }
        let decoded = try HAPTLV.decode(data)
        let recording = try HAPTLV.decode(try HAPTLV.required(decoded, 1, "recording configuration"))
        let video = try HAPTLV.decode(try HAPTLV.required(decoded, 2, "video configuration"))
        let audio = try HAPTLV.decode(try HAPTLV.required(decoded, 3, "audio configuration"))

        let prebufferLength = int32(try HAPTLV.required(recording, 1, "prebuffer length"))
        var eventTriggerOptions = int32(try HAPTLV.required(recording, 2, "event trigger options"))
        let container = try HAPTLV.decode(try HAPTLV.required(recording, 3, "media container configuration"))
        let containerType = try HAPTLV.requiredByte(container, 1, "container type")
        let containerParameters = try HAPTLV.decode(try HAPTLV.required(container, 2, "container parameters"))
        let fragmentLength = int32(try HAPTLV.required(containerParameters, 1, "fragment length"))

        let videoCodec = try HAPTLV.requiredByte(video, 1, "video codec")
        let videoParameters = try HAPTLV.decode(try HAPTLV.required(video, 2, "video parameters"))
        let videoAttributes = try HAPTLV.decode(try HAPTLV.required(video, 3, "video attributes"))
        let profile = try HAPTLV.requiredByte(videoParameters, 1, "profile")
        let level = try HAPTLV.requiredByte(videoParameters, 2, "level")
        let videoBitrate = int32(try HAPTLV.required(videoParameters, 3, "bitrate"))
        let iFrameInterval = int32(try HAPTLV.required(videoParameters, 4, "I-frame interval"))
        let width = int16(try HAPTLV.required(videoAttributes, 1, "width"))
        let height = int16(try HAPTLV.required(videoAttributes, 2, "height"))
        let framerate = try HAPTLV.requiredByte(videoAttributes, 3, "frame rate")

        let audioCodec = try HAPTLV.requiredByte(audio, 1, "audio codec")
        let audioParameters = try HAPTLV.decode(try HAPTLV.required(audio, 2, "audio parameters"))
        let channels = try HAPTLV.requiredByte(audioParameters, 1, "channels")
        let samplerate = try HAPTLV.requiredByte(audioParameters, 3, "sample rate")
        let bitrateMode = try HAPTLV.requiredByte(audioParameters, 2, "bitrate mode")
        let audioBitrate = Int(HAPTLV.readUInt(try HAPTLV.required(audioParameters, 4, "max audio bitrate").prefix(4)))

        var triggers: [EventTriggerOption] = []
        var bit = 0
        while eventTriggerOptions > 0 {
            if eventTriggerOptions & 1 != 0, let option = EventTriggerOption(rawValue: 1 << bit) { triggers.append(option) }
            eventTriggerOptions >>= 1
            bit += 1
        }

        guard let containerKind = MediaContainerType(rawValue: containerType), let videoType = VideoCodecType(rawValue: videoCodec),
            let h264Profile = H264Profile(rawValue: profile), let h264Level = H264Level(rawValue: level),
            let audioType = AudioRecordingCodecType(rawValue: audioCodec), let rate = AudioRecordingSamplerate(rawValue: samplerate),
            let mode = AudioBitrate(rawValue: bitrateMode)
        else { throw ConfigurationError.invalid("unknown enumeration value") }

        return CameraRecordingConfiguration(
            prebufferLength: prebufferLength, eventTriggerTypes: triggers,
            mediaContainerConfiguration: MediaContainerConfiguration(type: containerKind, fragmentLength: fragmentLength),
            videoCodec: .init(
                type: videoType, parameters: .init(profile: h264Profile, level: h264Level, bitRate: videoBitrate, iFrameInterval: iFrameInterval),
                resolution: VideoResolution(width, height, Int(framerate))),
            audioCodec: .init(audioChannels: Int(channels), type: audioType, samplerate: rate, bitrateMode: mode, bitrate: audioBitrate))
    }

    static func int32LE(_ value: Int) -> Data { HAPTLV.uint32(UInt32(truncatingIfNeeded: Int32(truncatingIfNeeded: value))) }

    static func supportedCameraRecordingConfiguration(_ options: CameraRecordingOptions, eventTriggerOptions: Int) -> Data {
        // The event trigger options take eight bytes, the value in the first four.
        let triggers = int32LE(eventTriggerOptions) + Data(count: 4)
        return HAPTLV.encode(
            (1, .data(int32LE(options.prebufferLength))),
            (2, .data(triggers)),
            (3, .list(options.mediaContainerConfiguration.map { configuration in
                HAPTLV.encode(
                    (1, .byte(configuration.type.rawValue)),
                    (2, .data(HAPTLV.encode((1, .data(int32LE(configuration.fragmentLength)))))))
            })))
    }

    static func resolutionTLV(_ resolution: VideoResolution) -> Data {
        HAPTLV.encode(
            (1, .data(HAPTLV.uint16(UInt16(clamping: resolution.width)))),
            (2, .data(HAPTLV.uint16(UInt16(clamping: resolution.height)))),
            (3, .byte(UInt8(clamping: resolution.fps))))
    }

    static func supportedVideoRecordingConfiguration(_ video: VideoRecordingOptions) throws -> Data {
        guard !video.resolutions.isEmpty else { throw ConfigurationError.missing("video resolutions") }
        let parameters = HAPTLV.encode(
            (1, .list(video.parameters.profiles.map { Data([$0.rawValue]) })),
            (2, .list(video.parameters.levels.map { Data([$0.rawValue]) })))
        let configuration = HAPTLV.encode(
            (1, .byte(video.type.rawValue)),
            (2, .data(parameters)),
            (3, .list(video.resolutions.map(resolutionTLV))))
        return HAPTLV.encode((1, .data(configuration)))
    }

    static func supportedAudioRecordingConfiguration(_ codecs: [AudioRecordingCodec]) throws -> Data {
        guard !codecs.isEmpty else { throw ConfigurationError.missing("At least one audio codec configuration must be specified") }
        let configurations = try codecs.map { codec -> Data in
            guard !codec.samplerate.isEmpty else { throw ConfigurationError.missing("Audio samplerate cannot be empty") }
            let parameters = HAPTLV.encode(
                (1, .byte(UInt8(clamping: max(1, codec.audioChannels)))),
                (2, .byte(codec.bitrateMode.rawValue)),
                (3, .list(codec.samplerate.map { Data([$0.rawValue]) })))
            return HAPTLV.encode((1, .byte(codec.type.rawValue)), (2, .data(parameters)))
        }
        return HAPTLV.encode((1, .list(configurations)))
    }

    /// Changes when the supported configurations change; a saved selection is dropped then.
    static func configurationHash(_ configurations: Data...) -> String {
        var hash = SHA256()
        for configuration in configurations { hash.update(data: Data(configuration.base64EncodedString().utf8)) }
        return Secrets.hex(hash.finalize())
    }

    // MARK: State

    struct Serialized: Codable {
        struct ConfigurationHash: Codable {
            var algorithm: String
            var hash: String
        }

        var configurationHash: ConfigurationHash
        var selectedConfiguration: String?
        var recordingActive: Bool
        var recordingAudioActive: Bool
        var eventSnapshotsActive: Bool
        var homeKitCameraActive: Bool
        var periodicSnapshotsActive: Bool
    }

    func serialize() -> Serialized {
        let (selected, active) = state.withLockedValue { ($0.selectedConfiguration?.base64, $0.recordingActive) }
        func flag(_ service: Service, _ type: CharacteristicType) -> Bool { (service[type]?.value.intValue ?? 0) != 0 }
        return Serialized(
            configurationHash: .init(algorithm: "sha256", hash: configurationHash), selectedConfiguration: selected, recordingActive: active,
            recordingAudioActive: flag(recordingManagementService, .recordingAudioActive),
            eventSnapshotsActive: flag(operatingModeService, .eventSnapshotsActive),
            homeKitCameraActive: flag(operatingModeService, .homeKitCameraActive),
            periodicSnapshotsActive: flag(operatingModeService, .periodicSnapshotsActive))
    }

    func deserialize(_ serialized: Serialized) {
        var changedState = false
        if let selected = serialized.selectedConfiguration {
            if serialized.configurationHash.hash == configurationHash, let parsed = try? Self.parseSelectedConfiguration(selected) {
                state.withLockedValue { $0.selectedConfiguration = (parsed, selected) }
            } else {
                logger.debug("Discarding the saved recording configuration: the supported configuration changed")
                changedState = true
            }
        }
        state.withLockedValue { $0.recordingActive = serialized.recordingActive }
        recordingManagementService.characteristic(.active).value = .bool(serialized.recordingActive)
        recordingManagementService.characteristic(.recordingAudioActive).value = .bool(serialized.recordingAudioActive)
        operatingModeService.characteristic(.eventSnapshotsActive).value = .bool(serialized.eventSnapshotsActive)
        operatingModeService.characteristic(.periodicSnapshotsActive).value = .bool(serialized.periodicSnapshotsActive)
        operatingModeService.characteristic(.homeKitCameraActive).value = .bool(serialized.homeKitCameraActive)
        for service in state.withLockedValue({ $0.sensorServices }) {
            service[.statusActive]?.value = .bool(serialized.homeKitCameraActive)
        }
        if let selected = selectedConfiguration { delegate.updateRecordingConfiguration(selected) }
        if serialized.recordingActive { delegate.updateRecordingActive(true) }
        if changedState { stateChanged() }
    }

    func destroy() {
        dataStreamManagement.destroy()
    }
}

/// One recording a home hub fetches over `dataSend` (HAP-NodeJS's CameraRecordingStream).
final class CameraRecordingStream: @unchecked Sendable {
    /// HomeKit takes the fragments in chunks of at most 256 KiB.
    static let maxChunk = 0x40000

    let connection: DataStreamConnection
    let delegate: any CameraRecordingDelegate
    let requestID: Int64
    let streamID: Int
    let logger: Logger

    private struct State {
        var closed = false
        var streaming: Task<Void, Never>?
        var closingTimeout: Task<Void, Never>?
        var onClosed: [@Sendable () -> Void] = []
        var handler: DataStreamConnection.ProtocolHandler?
    }

    private let state = NIOLockedValueBox(State())

    init(connection: DataStreamConnection, delegate: any CameraRecordingDelegate, requestID: Int64, streamID: Int, logger: Logger) {
        self.connection = connection
        self.delegate = delegate
        self.requestID = requestID
        self.streamID = streamID
        self.logger = logger
        let handler = DataStreamConnection.ProtocolHandler(events: [
            "close": { [weak self] message in self?.handleDataSendClose(message) },
            "ack": { [weak self] message in self?.handleDataSendAck(message) },
        ])
        state.withLockedValue { $0.handler = handler }
        _ = connection.addProtocolHandler("dataSend", handler)
        connection.onClose { [weak self] in self?.handleDataStreamConnectionClosed() }
    }

    var isClosed: Bool { state.withLockedValue { $0.closed } }

    func onClosed(_ handler: @escaping @Sendable () -> Void) {
        state.withLockedValue { $0.onClosed.append(handler) }
    }

    func start() {
        let task = Task { [weak self] () -> Void in await self?.stream() }
        state.withLockedValue { $0.streaming = task }
    }

    private func stream() async {
        logger.debug("Sending DATA_SEND OPEN response", metadata: ["remote": "\(connection.remoteAddress)", "streamId": "\(streamID)"])
        _ = try? connection.sendResponse("dataSend", "open", id: requestID, status: .success, ["status": .int(HDSStatus.success.rawValue)])

        var initialization = true
        var dataSequenceNumber = 1
        var lastFragmentWasMarkedLast = false
        do {
            for try await packet in delegate.handleRecordingStreamRequest(streamID: streamID) {
                if isClosed {
                    logger.debug("Delegate yielded a fragment after the stream was closed", metadata: ["streamId": "\(streamID)"])
                    break
                }
                if lastFragmentWasMarkedLast {
                    logger.error("Delegate yielded a fragment after signaling the end of the stream", metadata: ["streamId": "\(streamID)"])
                    break
                }
                let fragment = packet.data
                var offset = 0
                var chunkSequenceNumber = 1
                while offset < fragment.count, !isClosed {
                    let end = min(fragment.count, offset + Self.maxChunk)
                    let chunk = fragment.subdata(in: fragment.startIndex + offset..<fragment.startIndex + end)
                    offset = end
                    let last = offset >= fragment.count
                    var metadata: HDSDictionary = [
                        "dataType": .string(initialization ? "mediaInitialization" : "mediaFragment"),
                        "dataSequenceNumber": .int(Int64(dataSequenceNumber)),
                        "dataChunkSequenceNumber": .int(Int64(chunkSequenceNumber)),
                        "isLastDataChunk": .bool(last),
                    ]
                    if chunkSequenceNumber == 1 { metadata["dataTotalSize"] = .int(Int64(fragment.count)) }
                    var event: HDSDictionary = [
                        "streamId": .int(Int64(streamID)),
                        "packets": .array([.dictionary(["data": .data(chunk), "metadata": .dictionary(metadata)])]),
                    ]
                    if last { event["endOfStream"] = .bool(packet.isLast) }
                    logger.trace("Sending DATA_SEND DATA", metadata: ["streamId": "\(streamID)", "length": "\(chunk.count)", "sequence": "\(dataSequenceNumber).\(chunkSequenceNumber)"])
                    // Waits for the socket: a slow hub slows the delegate down instead of filling memory.
                    try await connection.sendEvent("dataSend", "data", event)?.get()
                    chunkSequenceNumber += 1
                    initialization = false
                }
                lastFragmentWasMarkedLast = packet.isLast
                if packet.isLast { break }
                dataSequenceNumber += 1
            }
            if !lastFragmentWasMarkedLast, !isClosed {
                logger.warning("Delegate finished the recording stream without marking a packet isLast: the hub is not told it ended", metadata: ["streamId": "\(streamID)"])
            }
        } catch {
            if isClosed {
                if !(error is CancellationError) {
                    logger.warning("Error on an already closed recording stream", metadata: ["streamId": "\(streamID)", "error": "\(error)"])
                }
            } else if let protocolError = error as? HDSProtocolError {
                logger.debug("Delegate closed the recording stream", metadata: ["streamId": "\(streamID)"])
                close(reason: protocolError.reason)
            } else if let connectionError = error as? DataStreamConnection.ConnectionError, connectionError == .closedSocket {
                logger.debug("Recording stream ended with the data stream socket", metadata: ["streamId": "\(streamID)"])
            } else if connection.isConsideredClosed {
                logger.debug("Recording stream ended with the data stream socket", metadata: ["streamId": "\(streamID)"])
            } else {
                logger.error("Unexpected error in a recording stream", metadata: ["streamId": "\(streamID)", "error": "\(error)"])
                close(reason: .unexpectedFailure)
            }
            return
        }
        if !isClosed { kickOffCloseTimeout() }
        logger.debug("Finished DATA_SEND transmission", metadata: ["streamId": "\(streamID)"])
    }

    private func handleDataSendAck(_ message: HDSDictionary) {
        logger.debug("Received DATA_SEND ACK", metadata: ["streamId": "\(message["streamId"]?.intValue ?? -1)", "endOfStream": "\(message["endOfStream"]?.boolValue ?? false)"])
        handleClosed { $0.delegate.acknowledgeStream(streamID: $0.streamID) }
    }

    private func handleDataSendClose(_ message: HDSDictionary) {
        guard let id = message["streamId"]?.intValue, Int(id) == streamID else { return }
        let reason = message["reason"]?.intValue.flatMap { HDSProtocolSpecificErrorReason(rawValue: Int($0)) }
        logger.debug("Received DATA_SEND CLOSE", metadata: ["streamId": "\(streamID)", "reason": "\(reason.map { "\($0)" } ?? "-")"])
        handleClosed { $0.delegate.closeRecordingStream(streamID: $0.streamID, reason: reason) }
    }

    private func handleDataStreamConnectionClosed() {
        logger.debug("The data stream connection of the recording stream closed", metadata: ["streamId": "\(streamID)"])
        handleClosed { $0.delegate.closeRecordingStream(streamID: $0.streamID, reason: nil) }
    }

    private func handleClosed(_ closure: (CameraRecordingStream) -> Void) {
        let (first, streaming, handlers, handler) = state.withLockedValue { state in
            let first = !state.closed
            state.closed = true
            state.closingTimeout?.cancel()
            state.closingTimeout = nil
            defer { if first { state.onClosed = [] } }
            return (first, state.streaming, state.onClosed, state.handler)
        }
        guard first else { return }
        // Cancelling the consuming task ends the delegate's stream (its onTermination runs): HAP-NodeJS's abort.
        streaming?.cancel()
        if let handler { connection.removeProtocolHandler("dataSend", handler) }
        closure(self)
        for handler in handlers { handler() }
    }

    /// Closes the stream from our side, telling the hub why.
    func close(reason: HDSProtocolSpecificErrorReason?) {
        guard !isClosed else { return }
        logger.debug("Recording stream closed", metadata: ["streamId": "\(streamID)", "reason": "\(reason.map { "\($0)" } ?? "closed")"])
        if !connection.isConsideredClosed {
            var message: HDSDictionary = ["streamId": .int(Int64(streamID))]
            if let reason { message["reason"] = .int(Int64(reason.rawValue)) }
            _ = try? connection.sendEvent("dataSend", "close", message)
        }
        handleClosed { $0.delegate.closeRecordingStream(streamID: $0.streamID, reason: reason) }
    }

    /// The hub acknowledges or closes a finished stream; after 12 s we close it ourselves.
    private func kickOffCloseTimeout() {
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !self.isClosed else { return }
            self.logger.debug("Recording stream took longer than expected to close, closing it now", metadata: ["streamId": "\(self.streamID)"])
            self.close(reason: .cancelled)
        }
        state.withLockedValue { state in
            state.closingTimeout?.cancel()
            state.closingTimeout = task
        }
    }
}
