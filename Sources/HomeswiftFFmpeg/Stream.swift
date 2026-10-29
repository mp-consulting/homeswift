import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// What `FfmpegStreamingProcess` needs from a camera's streaming delegate (TypeScript's `HomebridgeStreamingDelegate`, minus the
/// `CameraStreamingDelegate` methods it inherits, which the process never calls). Every member but
/// `forceStopStreamingSession` has a default.
public protocol HomebridgeStreamingDelegate: AnyObject, Sendable {
    /// Called after FFmpeg failed with "not enough frames to estimate rate; consider increasing probesize".
    func adjustProbeSize()
    /// A message for a known FFmpeg failure in these standard error lines, logged instead of the generic report.
    func ffmpegErrorCheck(_ logEntry: [String]) -> String?
    /// Ends the plugin's own session state.
    func stopStream(_ sessionId: String)
    /// Ends the HomeKit session, when FFmpeg fails or the stream goes quiet: `controller.forceStopStreamingSession(sessionId)`.
    func forceStopStreamingSession(_ sessionId: String)
}

extension HomebridgeStreamingDelegate {
    public func adjustProbeSize() {}
    public func ffmpegErrorCheck(_ logEntry: [String]) -> String? { nil }
    public func stopStream(_ sessionId: String) {}
}

/// Where the stream health monitor listens: the video return port, on the loopback address of the session's family.
public struct FfmpegReturnPort: Sendable, Equatable {
    public var addressVersion: IPAddressVersion
    public var port: Int

    public init(addressVersion: IPAddressVersion, port: Int) {
        self.addressVersion = addressVersion
        self.port = port
    }
}

/// FFmpeg for a HomeKit live stream (stream.ts): starts at once, ends the session through the delegate when FFmpeg fails, and,
/// with a return port, watches the stream: when no packet arrives on it for `FFMPEG_INPUT_TIMEOUT`, the session is stopped.
///
/// The TypeScript callback becomes `waitForStart()`: with `awaitingStart`, a failure before FFmpeg starts is reported there
/// (the `handleStreamRequest` of the camera throws it) rather than by force-stopping the session.
///
/// ```swift
/// let ffmpeg = FfmpegStreamingProcess(delegate: self, sessionId: request.sessionID, ffmpegOptions: options, commandLineArgs: args,
///                                     returnPort: FfmpegReturnPort(addressVersion: .ipv4, port: videoReturnPort), awaitingStart: true)
/// try await ffmpeg.waitForStart()
/// ```
public final class FfmpegStreamingProcess: FfmpegProcess, @unchecked Sendable {
    private let delegate: any HomebridgeStreamingDelegate
    private let sessionId: String
    private let awaitingStart: Bool

    private enum HealthSocket {
        case none
        case binding
        case bound(any Channel)
        case closed
    }

    private let healthSocket = NIOLockedValueBox(HealthSocket.none)
    private let healthSocketReady = AsyncSignal()

    public init(
        delegate: any HomebridgeStreamingDelegate, sessionId: String, ffmpegOptions: FfmpegOptions, commandLineArgs: [String],
        returnPort: FfmpegReturnPort? = nil, awaitingStart: Bool = false, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.delegate = delegate
        self.sessionId = sessionId
        self.awaitingStart = awaitingStart
        super.init(ffmpegOptions)

        // The return port, except for two-way audio, where the RtpDemuxer does that work.
        if let returnPort {
            createSocket(returnPort, group: group)
        }

        start(commandLineArgs) { [weak self] _ in
            guard let self else { return }
            self.delegate.stopStream(self.sessionId)
            // Before FFmpeg started, the failure goes to whoever waits for the start.
            if self.awaitingStart && self.isStartPending { return }
            self.delegate.forceStopStreamingSession(self.sessionId)
            self.delegate.stopStream(self.sessionId)
        }

        // The health socket must not outlive FFmpeg: a timeout after teardown would act on a dead session.
        if !onceExit({ [weak self] _ in self?.closeSocket() }) {
            closeSocket()
        }
    }

    // Binds the stream health socket: every packet re-arms a five-second timer that stops the session when it fires.
    private func createSocket(_ portInfo: FfmpegReturnPort, group: any EventLoopGroup) {
        let isIPv6 = portInfo.addressVersion == .ipv6
        healthSocket.withLockedValue { $0 = .binding }
        let log = self.log
        let sessionId = self.sessionId
        let delegate = self.delegate
        let inputTimeout = options.config.inputTimeout
        Task { [weak self] in
            do {
                let channel = try await DatagramBootstrap(group: group)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(StreamHealthHandler(
                                timeout: inputTimeout,
                                onTimeout: {
                                    log.debug("Video stream appears to be inactive for 5 seconds. Stopping stream.")
                                    delegate.forceStopStreamingSession(sessionId)
                                    delegate.stopStream(sessionId)
                                },
                                onError: { error in
                                    log.error("Socket error: \(error).")
                                    delegate.stopStream(sessionId)
                                }
                            ))
                        }
                    }
                    .bind(host: isIPv6 ? "::1" : "127.0.0.1", port: portInfo.port)
                    .get()
                let keep = self?.healthSocket.withLockedValue { state -> Bool in
                    guard case .binding = state else { return false }
                    state = .bound(channel)
                    return true
                } ?? false
                if !keep { try? await channel.close() }
            } catch {
                log.error("Socket error: \(error).")
                delegate.stopStream(sessionId)
                self?.healthSocket.withLockedValue { if case .binding = $0 { $0 = .closed } }
            }
            self?.healthSocketReady.signal()
        }
    }

    // Closes the health socket and its timer. Safe from every teardown path.
    private func closeSocket() {
        let channel = healthSocket.withLockedValue { state -> (any Channel)? in
            defer { state = .closed }
            if case .bound(let channel) = state { return channel }
            return nil
        }
        channel?.close(promise: nil)
    }

    override func stopProcess() {
        closeSocket()
        super.stopProcess()
    }

    override func logFfmpegError(_ status: FfmpegExitStatus) {
        let stderrLog = self.stderrLog
        // Errors the plugin knows about, with its own message.
        if let message = delegate.ffmpegErrorCheck(stderrLog) {
            log.error("\(message)")
            return
        }
        // Not enough frames to estimate the rate: the plugin tunes its probe size for the next run.
        if stderrLog.contains(where: { $0.contains("not enough frames to estimate rate; consider increasing probesize") }) {
            delegate.adjustProbeSize()
            return
        }
        super.logFfmpegError(status)
    }

    // MARK: Tests

    /// Waits until the health socket is bound (or failed); true when it is bound now.
    func waitForHealthSocket() async -> Bool {
        let isBinding = healthSocket.withLockedValue { if case .binding = $0 { true } else { false } }
        if isBinding {
            _ = await healthSocketReady.wait(timeout: .seconds(5)) { [healthSocket] in
                healthSocket.withLockedValue { if case .binding = $0 { false } else { true } }
            }
        }
        return healthSocketPort != nil
    }

    /// The bound health socket's port, nil when it is not open.
    var healthSocketPort: Int? {
        healthSocket.withLockedValue { if case .bound(let channel) = $0 { channel.localAddress?.port } else { nil } }
    }

    var isHealthSocketClosed: Bool { healthSocket.withLockedValue { if case .closed = $0 { true } else { false } } }
}

/// Re-arms the inactivity timer on every packet; runs on the socket's event loop.
private final class StreamHealthHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let onTimeout: @Sendable () -> Void
    private let onError: @Sendable (any Error) -> Void
    private var streamTimeout: Scheduled<Void>?
    private let timeout: Int

    init(timeout: Int, onTimeout: @escaping @Sendable () -> Void, onError: @escaping @Sendable (any Error) -> Void) {
        self.timeout = timeout
        self.onTimeout = onTimeout
        self.onError = onError
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        streamTimeout?.cancel()
        let onTimeout = self.onTimeout
        streamTimeout = context.eventLoop.scheduleTask(in: .milliseconds(Int64(timeout))) { onTimeout() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        streamTimeout?.cancel()
        streamTimeout = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        onError(error)
    }
}
