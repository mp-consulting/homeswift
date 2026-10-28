import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

// RTP utilities (rtp.ts): a demuxer that splits RTP and RTCP arriving on one UDP port (HomeKit multiplexes them, RFC 5761, FFmpeg
// cannot) toward two ports, and an allocator of UDP ports for FFmpeg.

/// How often, in seconds, FFmpeg gets a heartbeat in two-way audio sessions: below FFmpeg's five-second input timeout.
let TWOWAY_HEARTBEAT_INTERVAL = 3

/// The UDP ports a socket can be bound or sent to (0 binds any).
private let UDP_PORTS = 0...65535

/// A port outside 0...65535 (a failed reservation's -1, say): NIO would trap on it.
struct RtpInvalidPortError: Error, CustomStringConvertible {
    let port: Int
    var description: String { "invalid UDP port \(port)" }
}

/// Splits the RTP and RTCP packets HomeKit sends on one UDP port: RTP goes to `rtpPort`, RTCP to `rtcpPort`, both on the loopback
/// address. The last RTCP packet is also replayed to `rtpPort` every three seconds, which FFmpeg ignores as RTP but which keeps its
/// input from timing out between talkback bursts. Credit to dgreif, brandawg93 and Sunoo for the approach.
///
/// ```swift
/// let demuxer = await RtpDemuxer(ipFamily: request.addressVersion, inputPort: 50000, rtcpPort: 50002, rtpPort: 50004, log: log)
/// _ = await demuxer.rtpEvents.next()   // the first RTP packet (or the demuxer closing)
/// demuxer.close()
/// ```
public final class RtpDemuxer: Sendable {
    /// Fires on every RTP packet, and when the demuxer closes (the TypeScript `rtp` event). Once closed, a listener added later
    /// (or `next()`) is called at once, so a talkback waiter never waits on a demuxer that can no longer receive anything.
    public let rtpEvents = FfmpegEvent<Void>()

    private let log: Logger
    private let inputPort: Int
    private typealias State = NIOLockedValueBox<(running: Bool, channel: (any Channel)?)>
    private let state = State((false, nil))

    /// Binds `inputPort` (0 picks one; see `localPort`) on every interface of the family. A bind failure (or a port outside
    /// 0...65535) is logged and leaves the demuxer closed, with its `rtp` event fired as when it closes (TypeScript's socket
    /// error handler closes the demuxer).
    public convenience init(
        ipFamily: IPAddressVersion, inputPort: Int, rtcpPort: Int, rtpPort: Int, log: Logger,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async {
        await self.init(
            ipFamily: ipFamily, inputPort: inputPort, rtcpPort: rtcpPort, rtpPort: rtpPort, log: log, group: group,
            heartbeatInterval: .seconds(Int64(TWOWAY_HEARTBEAT_INTERVAL)))
    }

    /// `heartbeatInterval`: tests that count packets set it beyond their length, so a slow run sees no heartbeat.
    init(
        ipFamily: IPAddressVersion, inputPort: Int, rtcpPort: Int, rtpPort: Int, log: Logger, group: any EventLoopGroup,
        heartbeatInterval: TimeAmount
    ) async {
        self.log = log
        self.inputPort = inputPort
        log.debug("Creating an RtpDemuxer instance - inbound port: \(inputPort), RTCP port: \(rtcpPort), RTP port: \(rtpPort).")
        let isIPv6 = ipFamily == .ipv6
        do {
            for port in [inputPort, rtcpPort, rtpPort] where !UDP_PORTS.contains(port) {
                throw RtpInvalidPortError(port: port)
            }
            let loopback = isIPv6 ? "::1" : "127.0.0.1"
            let rtcpTarget = try SocketAddress(ipAddress: loopback, port: rtcpPort)
            let rtpTarget = try SocketAddress(ipAddress: loopback, port: rtpPort)
            let (state, events) = (state, rtpEvents)
            let channel = try await DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(RtpDemuxerHandler(
                            rtcpTarget: rtcpTarget, rtpTarget: rtpTarget, heartbeatInterval: heartbeatInterval, log: log,
                            onRtp: { events.emit() },
                            onError: { error in
                                log.error("RtpDemuxer Error: \(error)")
                                Self.close(state: state, events: events, log: log, inputPort: inputPort)
                            }
                        ))
                    }
                }
                .bind(host: isIPv6 ? "::" : "0.0.0.0", port: inputPort)
                .get()
            state.withLockedValue { $0 = (true, channel) }
        } catch {
            log.error("RtpDemuxer Error: \(error)")
            rtpEvents.finish()
        }
    }

    /// Closes the socket and stops the heartbeat. Safe to call more than once.
    public func close() {
        Self.close(state: state, events: rtpEvents, log: log, inputPort: inputPort)
    }

    private static func close(state: State, events: FfmpegEvent<Void>, log: Logger, inputPort: Int) {
        let channel = state.withLockedValue { state -> (any Channel)? in
            guard state.running else { return nil }
            defer { state.running = false }
            return state.channel
        }
        guard let channel else { return }
        log.debug("Closing the RtpDemuxer instance on port \(inputPort).")
        channel.close(promise: nil)
        events.finish()
    }

    /// Whether the demuxer is accepting packets.
    public var isRunning: Bool { state.withLockedValue { $0.running } }

    /// The port it listens on (useful when bound to port 0).
    public var localPort: Int? { state.withLockedValue { $0.channel?.localAddress?.port } }

    /// Whether a packet is RTP rather than RTCP: payload type above 90, or 0.
    static func isRtpMessage(_ payloadTypeByte: UInt8) -> Bool {
        let payloadType = payloadTypeByte & 0x7F
        return payloadType > 90 || payloadType == 0
    }
}

/// Runs on the demuxer's event loop: forwards packets and owns the heartbeat timer.
final class RtpDemuxerHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let rtcpTarget: SocketAddress
    private let rtpTarget: SocketAddress
    private let heartbeatInterval: TimeAmount
    private let log: Logger
    private let onRtp: @Sendable () -> Void
    private let onError: @Sendable (any Error) -> Void
    private var heartbeatTimer: Scheduled<Void>?
    private var heartbeatMessage: ByteBuffer?

    init(
        rtcpTarget: SocketAddress, rtpTarget: SocketAddress, heartbeatInterval: TimeAmount, log: Logger,
        onRtp: @escaping @Sendable () -> Void, onError: @escaping @Sendable (any Error) -> Void
    ) {
        self.rtcpTarget = rtcpTarget
        self.rtpTarget = rtpTarget
        self.heartbeatInterval = heartbeatInterval
        self.log = log
        self.onRtp = onRtp
        self.onError = onError
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data).data
        // Too short to carry a payload type: neither RTP nor RTCP.
        guard let byte = message.getInteger(at: message.readerIndex + 1, as: UInt8.self) else { return }
        if RtpDemuxer.isRtpMessage(byte) {
            onRtp()
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: rtpTarget, data: message)), promise: nil)
        } else {
            // RTCP doubles as the heartbeat: FFmpeg ignores it on the RTP port, but it keeps the input alive.
            heartbeatMessage = message
            heartbeat(context: context)
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: rtcpTarget, data: message)), promise: nil)
        }
    }

    // Replays the last RTCP packet to the RTP port every few seconds, within FFmpeg's five-second input timeout.
    private func heartbeat(context: ChannelHandlerContext) {
        heartbeatTimer?.cancel()
        let loopBound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        heartbeatTimer = context.eventLoop.scheduleTask(in: heartbeatInterval) {
            let (handler, context) = loopBound.value
            guard context.channel.isActive, let message = handler.heartbeatMessage else { return }
            handler.log.debug("Sending ffmpeg a heartbeat.")
            context.writeAndFlush(handler.wrapOutboundOut(AddressedEnvelope(remoteAddress: handler.rtpTarget, data: message)), promise: nil)
            handler.heartbeat(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        heartbeatMessage = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        onError(error)
    }
}

/// Reserves UDP ports for FFmpeg and remembers them, so concurrent sessions never get the same one.
///
/// FFmpeg always takes the RTCP port to be the RTP port plus one, so pairs are consecutive.
///
/// ```swift
/// let allocator = RtpPortAllocator()
/// let rtpPort = await allocator.reserve(ipFamily: .ipv4, portCount: 2)   // and rtpPort + 1; -1 when none was found
/// allocator.cancel(rtpPort)
/// ```
public final class RtpPortAllocator: Sendable {
    private let portsInUse = NIOLockedValueBox<Set<Int>>([])
    private let group: any EventLoopGroup

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.group = group
    }

    // Finds a free UDP port by binding to it (0 lets the system choose), skipping those we already handed out. -1 on error, or
    // when a specific port is already ours (the caller retries with a fresh pair).
    private func getPort(_ ipFamily: IPAddressVersion, _ port: Int = 0) async -> Int {
        // The port after 65535 (the second of a pair) does not exist: try another pair.
        guard UDP_PORTS.contains(port) else { return -1 }
        do {
            while true {
                let channel = try await DatagramBootstrap(group: group)
                    .bind(host: ipFamily == .ipv6 ? "::" : "0.0.0.0", port: port)
                    .get()
                let assignedPort = channel.localAddress?.port ?? -1
                try? await channel.close()
                // A specific port must be the one bound (a resolver may read an odd value as another port).
                guard assignedPort > 0, port == 0 || assignedPort == port else { return -1 }
                let isNew = portsInUse.withLockedValue { $0.insert(assignedPort).inserted }
                if isNew { return assignedPort }
                if port != 0 { return -1 }
            }
        } catch {
            return -1
        }
    }

    private func _reserve(_ ipFamily: IPAddressVersion, _ portCount: Int, _ attempts: Int) async -> Int {
        guard portCount == 1 || portCount == 2, attempts <= 10 else { return -1 }
        var firstPort = 0
        for _ in 0..<portCount {
            let assignedPort = await getPort(ipFamily, firstPort != 0 ? firstPort + 1 : 0)
            if assignedPort == -1 {
                // Release the first port of a pair before trying again.
                if firstPort != 0 { cancel(firstPort) }
                return await _reserve(ipFamily, portCount, attempts + 1)
            }
            if firstPort == 0 { firstPort = assignedPort }
        }
        return firstPort
    }

    /// Reserves one port, or two consecutive ones (RTP and RTCP), and returns the first; -1 when none could be found.
    public func reserve(ipFamily: IPAddressVersion = .ipv4, portCount: Int = 1) async -> Int {
        await _reserve(ipFamily, portCount, 0)
    }

    /// Releases a reserved port.
    public func cancel(_ port: Int) {
        _ = portsInUse.withLockedValue { $0.remove(port) }
    }

    var reservedPorts: Set<Int> { portsInUse.withLockedValue { $0 } }
}
