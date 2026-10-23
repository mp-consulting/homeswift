import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftFFmpeg

@Suite struct RtpDemuxerTests {
    // Payload type 96 with the marker bit: RTP. Payload type 200 (a sender report): RTCP.
    let rtpPacket = Data([0x80, 0xE0, 0x00, 0x01, 0xAA, 0xBB])
    let rtcpPacket = Data([0x80, 0xC8, 0x00, 0x06, 0x01, 0x02, 0x03, 0x04])

    @Test func classifiesPayloadTypes() {
        #expect(RtpDemuxer.isRtpMessage(0xE0))
        #expect(RtpDemuxer.isRtpMessage(0x60 + 1 + 0x80))
        #expect(RtpDemuxer.isRtpMessage(0x00))
        #expect(!RtpDemuxer.isRtpMessage(0xC8))
        #expect(!RtpDemuxer.isRtpMessage(0xC9))
        #expect(!RtpDemuxer.isRtpMessage(90))
    }

    @Test func splitsRtpAndRtcpTowardTheirPorts() async throws {
        let rtp = try await UDPReceiver()
        let rtcp = try await UDPReceiver()
        let demuxer = await RtpDemuxer(ipFamily: .ipv4, inputPort: 0, rtcpPort: rtcp.port, rtpPort: rtp.port, log: Logger(label: "test"))
        #expect(demuxer.isRunning)
        let inputPort = try #require(demuxer.localPort)
        let rtpEvents = NIOLockedValueBox(0)
        demuxer.rtpEvents.on { rtpEvents.withLockedValue { $0 += 1 } }

        try await sendUDP(rtpPacket, to: inputPort)
        try await sendUDP(rtcpPacket, to: inputPort)
        try await sendUDP(rtpPacket, to: inputPort)

        #expect(await eventually { rtp.packets.count == 2 && rtcp.packets.count == 1 })
        #expect(rtp.packets == [rtpPacket, rtpPacket])
        #expect(rtcp.packets == [rtcpPacket])
        #expect(rtpEvents.withLockedValue { $0 } == 2)

        demuxer.close()
        await rtp.close()
        await rtcp.close()
    }

    @Test func replaysTheLastRtcpPacketToTheRtpPortAsAHeartbeat() async throws {
        let rtp = try await UDPReceiver()
        let rtcp = try await UDPReceiver()
        let demuxer = await RtpDemuxer(ipFamily: .ipv4, inputPort: 0, rtcpPort: rtcp.port, rtpPort: rtp.port, log: Logger(label: "test"))
        try await sendUDP(rtcpPacket, to: try #require(demuxer.localPort))
        #expect(await eventually { rtcp.packets.count == 1 })
        #expect(rtp.packets.isEmpty)
        // Every TWOWAY_HEARTBEAT_INTERVAL seconds, FFmpeg's RTP input gets the RTCP packet, which keeps it from timing out.
        #expect(await eventually(timeout: .seconds(Int64(TWOWAY_HEARTBEAT_INTERVAL) + 2)) { rtp.packets == [rtcpPacket] })
        demuxer.close()
        // No heartbeat after closing.
        try await Task.sleep(for: .seconds(Int64(TWOWAY_HEARTBEAT_INTERVAL) + 1))
        #expect(rtp.packets.count <= 2)
        await rtp.close()
        await rtcp.close()
    }

    @Test func wakesTheTalkbackWaiterOnTheFirstRtpPacketOrOnClose() async throws {
        let rtp = try await UDPReceiver()
        let demuxer = await RtpDemuxer(ipFamily: .ipv4, inputPort: 0, rtcpPort: rtp.port, rtpPort: rtp.port, log: Logger(label: "test"))
        let port = try #require(demuxer.localPort)
        async let first: Void? = demuxer.rtpEvents.next()
        try await Task.sleep(for: .milliseconds(50))
        try await sendUDP(rtpPacket, to: port)
        #expect(await first != nil)
        #expect(demuxer.isRunning)

        async let closing: Void? = demuxer.rtpEvents.next()
        try await Task.sleep(for: .milliseconds(50))
        demuxer.close()
        #expect(await closing != nil)
        #expect(!demuxer.isRunning)
        await rtp.close()
    }

    @Test func closesIdempotently() async {
        let log = LogRecorder()
        let demuxer = await RtpDemuxer(ipFamily: .ipv4, inputPort: 0, rtcpPort: 9, rtpPort: 9, log: log.logger)
        #expect(demuxer.isRunning)
        demuxer.close()
        #expect(!demuxer.isRunning)
        demuxer.close()
        #expect(log.messages(.debug).filter { $0.hasPrefix("Closing the RtpDemuxer") }.count == 1)
    }

    @Test func staysClosedWhenThePortIsTaken() async throws {
        let taken = try await UDPReceiver(host: "0.0.0.0")
        let log = LogRecorder()
        let demuxer = await RtpDemuxer(ipFamily: .ipv4, inputPort: taken.port, rtcpPort: 9, rtpPort: 9, log: log.logger)
        #expect(!demuxer.isRunning)
        #expect(log.messages(.error).first?.hasPrefix("RtpDemuxer Error:") == true)
        // It closed as the TypeScript demuxer does on a socket error: a talkback waiter added now is woken at once.
        let woken = NIOLockedValueBox(false)
        demuxer.rtpEvents.once { woken.withLockedValue { $0 = true } }
        #expect(woken.withLockedValue { $0 })
        #expect(await demuxer.rtpEvents.next() != nil)
        demuxer.close()
        await taken.close()
    }

    @Test func refusesPortsOutsideTheUDPRange() async {
        let log = LogRecorder()
        // A failed reservation's -1 used to trap in NIO's address conversion.
        let demuxer = await RtpDemuxer(ipFamily: .ipv4, inputPort: 0, rtcpPort: -1, rtpPort: 65536, log: log.logger)
        #expect(!demuxer.isRunning)
        #expect(log.messages(.error) == ["RtpDemuxer Error: invalid UDP port -1"])
        #expect(await demuxer.rtpEvents.next() != nil)
    }

    @Test func wakesWaitersThatComeAfterTheClose() async {
        let demuxer = await RtpDemuxer(ipFamily: .ipv4, inputPort: 0, rtcpPort: 9, rtpPort: 9, log: Logger(label: "test"))
        demuxer.close()
        #expect(await demuxer.rtpEvents.next() != nil)
    }
}

@Suite struct RtpPortAllocatorTests {
    @Test func reservesDistinctPorts() async {
        let allocator = RtpPortAllocator()
        var ports: Set<Int> = []
        for _ in 0..<20 {
            let port = await allocator.reserve()
            #expect(port > 0)
            #expect(!ports.contains(port))
            ports.insert(port)
        }
        #expect(allocator.reservedPorts == ports)
        for port in ports { allocator.cancel(port) }
        #expect(allocator.reservedPorts.isEmpty)
    }

    @Test func reservesConsecutivePairs() async throws {
        let allocator = RtpPortAllocator()
        for _ in 0..<5 {
            let port = await allocator.reserve(ipFamily: .ipv4, portCount: 2)
            #expect(port > 0)
            #expect(allocator.reservedPorts.contains(port))
            #expect(allocator.reservedPorts.contains(port + 1))
            // Both are free for FFmpeg to bind. The allocator releases its probe sockets (as the original does), and
            // other suites in this process bind ports in parallel, so a pair can be taken in between: a pair that
            // binds within a few tries shows the allocator hands out usable pairs.
            var bound = false
            for attempt in 0..<5 where !bound {
                let candidate = attempt == 0 ? port : await allocator.reserve(ipFamily: .ipv4, portCount: 2)
                guard let rtp = try? await UDPReceiver(host: "0.0.0.0", port: candidate) else { continue }
                if let rtcp = try? await UDPReceiver(host: "0.0.0.0", port: candidate + 1) {
                    await rtcp.close()
                    bound = true
                }
                await rtp.close()
            }
            #expect(bound)
        }
    }

    @Test func refusesMoreThanTwoPorts() async {
        let allocator = RtpPortAllocator()
        #expect(await allocator.reserve(portCount: 3) == -1)
        #expect(await allocator.reserve(portCount: 0) == -1)
        #expect(allocator.reservedPorts.isEmpty)
    }
}
