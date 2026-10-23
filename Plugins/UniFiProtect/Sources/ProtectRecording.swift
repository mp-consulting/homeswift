import Foundation
import Homeswift
import HomeswiftFFmpeg

/// HomeKit Secure Video for a Protect camera (`ProtectRecordingDelegate`): a timeshift buffer of the
/// livestream runs while the Home app records events, and an event becomes an FFmpeg process fed with the
/// buffer and then the livestream, whose fMP4 fragments go to the home hub.
@ProtectActor
final class ProtectRecordingDelegate {
    private let camera: ProtectCamera
    private let ffmpeg: any ProtectFfmpegKit
    private let options: any ProtectFfmpegOptions
    private(set) var isRecording = false
    private var ffmpegStream: (any ProtectFfmpegRecording)?
    private var isInitialized = false
    private var isTransmitting = false
    private(set) var recordingConfiguration: CameraRecordingConfiguration?
    private(set) var rtspEntry: RtspEntry?
    let timeshift: ProtectTimeshiftBuffer
    private var timeshiftedSegments = 0
    private var transmittedSegments = 0
    private var queue: ProtectSegmentQueue?
    /// The controller's RecordingAudioActive, once the controller exists.
    var recordingAudioActive: () -> Bool = { false }

    init(camera: ProtectCamera, ffmpeg: any ProtectFfmpegKit, options: any ProtectFfmpegOptions) {
        self.camera = camera
        self.ffmpeg = ffmpeg
        self.options = options
        timeshift = ProtectTimeshiftBuffer(camera: camera)
        timeshift.fragmentLength = { [weak self] in self?.recordingConfiguration?.mediaContainerConfiguration.fragmentLength }
    }

    private var log: ProtectLog { camera.log }
    private var isRecordingDisabled: Bool { camera.context.hksvRecordingDisabled ?? false }

    /// Recording turned on or off in the Home app.
    func updateRecordingActive(_ active: Bool) async {
        guard active else {
            deactivate()
            return
        }
        isRecording = active
        guard await configureTimeshifting(), !isInitialized else { return }
        isInitialized = true
        let hardware = camera.hints.hardwareTranscoding && ffmpeg.hostSystem != "raspbian" ? "\u{26A1}\u{FE0F} " : ""
        log.info("HKSV: \(hardware)\(rtspEntry?.name ?? ""), \(formatBps(Double(recordingConfiguration?.videoCodec.parameters.bitRate ?? 0) * 1000)).")
    }

    /// The synchronous half of turning recording off.
    private func deactivate() {
        timeshift.stop()
        if isRecording { log.info("Disabling HomeKit Secure Video event recording.") }
        isRecording = false
        camera.accessory.firstService(.motionSensor)?[.motionDetected]?.value = .bool(false)
    }

    /// HomeKit selected recording settings, or reset them.
    func updateRecordingConfiguration(_ configuration: CameraRecordingConfiguration?) {
        recordingConfiguration = configuration
        guard configuration != nil else {
            timeshift.stop()
            return
        }
        timeshift.configuredDuration = ProtectSettings.hksvTimeshiftBufferMaxDuration
        // As `void updateRecordingActive(isRecording)`: turning off happens at once.
        if isRecording {
            Task { await self.updateRecordingActive(true) }
        } else {
            deactivate()
        }
    }

    /// A home hub asks for an event: the buffer and the livestream through FFmpeg, as fMP4 fragments. A
    /// single zero byte marked last tells HomeKit there is nothing to send.
    func handleRecordingStreamRequest(streamID: Int) -> AsyncStream<RecordingPacket> {
        let (packets, continuation) = AsyncStream.makeStream(of: RecordingPacket.self)
        let task = Task { @ProtectActor in
            await self.produce(continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return packets
    }

    private func produce(_ continuation: AsyncStream<RecordingPacket>.Continuation) async {
        transmittedSegments = 0
        // Recording was turned on before the camera had a configuration: set it up now.
        if !isRecordingDisabled, isRecording, !isInitialized {
            await updateRecordingActive(isRecording)
        }
        var ready = !isRecordingDisabled && isInitialized && !timeshift.isRestarting && camera.isOnline
            && timeshift.time >= (recordingConfiguration?.prebufferLength ?? -1)
        if ready { ready = await startTransmitting() && ffmpegStream != nil }
        guard ready, let ffmpeg = ffmpegStream else {
            if isTransmitting { stopTransmitting() }
            transmittedSegments = -1
            continuation.yield(RecordingPacket(data: Data([0]), isLast: true))
            return
        }
        for await segment in ffmpeg.segments() {
            if !isTransmitting || Task.isCancelled { break }
            transmittedSegments += 1
            continuation.yield(RecordingPacket(data: segment, isLast: false))
        }
        // FFmpeg timed out, or nothing came: the livestream needs a new connection.
        if ffmpegStream?.isTimedOut == true || transmittedSegments == 0 {
            timeshift.restart()
            if ffmpegStream?.isTimedOut == true {
                continuation.yield(RecordingPacket(data: Data([0]), isLast: true))
            }
        }
    }

    func acknowledgeStream(streamID: Int) {
        stopTransmitting()
    }

    func closeRecordingStream(streamID: Int, reason: HDSProtocolSpecificErrorReason?) {
        stopTransmitting(reason: reason)
    }

    /// Starts the timeshift buffer on the stream that suits the recording configuration.
    private func configureTimeshifting() async -> Bool {
        guard let configuration = recordingConfiguration else { return false }
        let timeshiftError = "Unable to configure HKSV event recording support"
        guard camera.isOnline else {
            log.error("\(timeshiftError): the camera is offline or unavailable. Event recording will resume after the camera is online.")
            return false
        }
        let oldEntry = rtspEntry
        rtspEntry = camera.findRecordingRtsp(width: configuration.videoCodec.resolution.width, height: configuration.videoCodec.resolution.height)
        guard let entry = rtspEntry else {
            log.error("\(timeshiftError): no valid RTSP stream profile was found for this camera.")
            return false
        }
        guard isRecording else { return true }
        // Already buffering this stream.
        if timeshift.isStarted, entry.channel.id == oldEntry?.channel.id, entry.lens == nil || entry.lens == oldEntry?.lens {
            return true
        }
        return await timeshift.start(entry)
    }

    private func startTransmitting() async -> Bool {
        ffmpegStream?.stop(logErrors: false)
        ffmpegStream = nil
        timeshift.onSegment = nil
        queue = nil
        guard camera.stream != nil, let configuration = recordingConfiguration, let entry = rtspEntry, !timeshift.isRestarting,
              timeshift.time >= configuration.prebufferLength else { return false }
        transmittedSegments = 0
        timeshiftedSegments = 0
        let ffmpeg = self.ffmpeg.startRecording(
            options: options, configuration: configuration,
            fMp4Options: FMp4RecordingOptions(audioFilters: camera.audioFilters, audioStream: 0, codec: camera.ufp.videoCodec, enableAudio: isAudioActive,
                                              fps: entry.channel.fps, timeshift: max(timeshift.time - configuration.prebufferLength, 0), transcodeAudio: false),
            verbose: camera.hasFeature("Debug.Video.HKSV"))
        ffmpegStream = ffmpeg
        isTransmitting = true
        let queue = ProtectSegmentQueue(log: log, process: { [weak self] in self?.ffmpegStream }, onWritten: { [weak self] in self?.timeshiftedSegments += 1 })
        self.queue = queue
        timeshift.onSegment = { [weak self] segment in
            guard self?.ffmpegStream?.isStdinWritable == true else { return }
            queue.push(segment)
        }
        guard await timeshift.transmitStart() else {
            ffmpeg.stop()
            timeshift.stop()
            timeshift.onSegment = nil
            ffmpegStream = nil
            self.queue = nil
            isTransmitting = false
            return false
        }
        if camera.hints.hksvRecordingIndicator, !camera.statusLed {
            Task { if !(await self.camera.setStatusLed(true)) { self.log.error("Unable to set status LED.") } }
        }
        log.debug("Beginning a HomeKit Secure Video recording event.")
        return true
    }

    private func stopTransmitting(reason: HDSProtocolSpecificErrorReason? = nil) {
        timeshift.transmitStop()
        if let ffmpegStream {
            let quiet = (reason != nil && reason != .normal) || timeshift.isRestarting
            ffmpegStream.stop(logErrors: !quiet)
            self.ffmpegStream = nil
        }
        isTransmitting = false
        timeshift.onSegment = nil
        queue = nil
        if camera.hints.hksvRecordingIndicator, camera.statusLed {
            Task { if !(await self.camera.setStatusLed(false)) { self.log.error("Unable to clear status LED.") } }
        }
        guard camera.stream != nil, transmittedSegments != -1 else { return }
        // The last segment is the one HomeKit has not used.
        timeshiftedSegments = max(timeshiftedSegments - 1, 0)
        transmittedSegments = max(transmittedSegments - 1, 0)
        if !isRecordingDisabled, timeshiftedSegments != 0, transmittedSegments != 0, rtspEntry != nil {
            let (recordedTime, unit) = formatRecordingDuration(Double(timeshiftedSegments * timeshift.segmentLength) / 1000)
            if reason == .normal, camera.hints.logHksv { log.info("HKSV: \(recordedTime) \(unit) event.") }
        }
        let description: String? = switch reason {
        case .cancelled: "HomeKit canceled the request."
        case .unexpectedFailure: "the request was slow to respond. This error can be safely ignored - it will occur occasionally."
        case .timeout: "the request timed out. This error can be safely ignored - it will occur occasionally."
        default: nil
        }
        if let reason, reason != .normal, !timeshift.isRestarting, camera.isOnline, timeshift.time >= (recordingConfiguration?.prebufferLength ?? 0) {
            log.error("HKSV recording event ended early: \(description ?? "undefined")")
        }
    }

    /// Whether recordings carry audio: a microphone, the `Audio` option, and audio turned on in the Home app.
    var isAudioActive: Bool {
        camera.ufp.feature("hasMic") && camera.hasFeature("Audio") && recordingAudioActive()
    }
}
