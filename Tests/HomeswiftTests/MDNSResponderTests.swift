import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import Homeswift

/// The built-in responder's wire format against hand-assembled RFC 1035 bytes, and its probing, answers,
/// conflicts and goodbyes on a fake interface that records what it would send.
@Suite struct MDNSResponderTests {
    // MARK: Wire format

    @Test func encodesAQueryByteForByte() {
        let message = DNSMessage(questions: [DNSQuestion(name: DNSName(dotted: "_hap._tcp.local"), type: DNSType.ptr)])
        let expected: [UInt8] = [
            0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
            4, 0x5F, 0x68, 0x61, 0x70, 4, 0x5F, 0x74, 0x63, 0x70, 5, 0x6C, 0x6F, 0x63, 0x61, 0x6C, 0,
            0, 12, 0, 1,
        ]
        #expect(message.encode() == expected)
    }

    @Test func compressesRepeatedNamesAndReadsThemBack() throws {
        let instance = DNSName(["Bridge 1.2"] + DNSName(dotted: "_hap._tcp.local").labels)
        let host = DNSName(dotted: "Bridge-1-2.local")
        let message = DNSMessage(isResponse: true, answers: [
            DNSRecord(name: DNSName(dotted: "_hap._tcp.local"), data: .ptr(instance), ttl: 4500),
            DNSRecord(name: instance, data: .srv(priority: 0, weight: 0, port: 51826, target: host), ttl: 120, cacheFlush: true),
            DNSRecord(name: instance, data: .txt([4, 0x63, 0x23, 0x3D, 0x31]), ttl: 4500, cacheFlush: true),
            DNSRecord(name: host, data: .a([192, 168, 1, 5]), ttl: 120, cacheFlush: true),
        ])
        let bytes = message.encode()
        // "_hap._tcp.local" is written once; the instance and the host point back at it.
        #expect(bytes.count < 140)
        #expect(bytes[2] == 0x84)
        let parsed = try DNSMessage(bytes: bytes)
        #expect(parsed.isResponse)
        #expect(parsed.answers == message.answers)
        #expect(parsed.answers[0].name.description == "_hap._tcp.local.")
        // A dot inside the instance label stays in the label.
        if case .ptr(let target) = parsed.answers[0].data { #expect(target.labels[0] == "Bridge 1.2") }
    }

    @Test func writesNSECBitmaps() {
        var writer = DNSWriter(compress: false)
        writer.rdata(.nsec(next: DNSName(dotted: "h.local"), types: [DNSType.a]))
        #expect(writer.bytes == [1, 0x68, 5, 0x6C, 0x6F, 0x63, 0x61, 0x6C, 0, 0, 1, 0x40])
        writer = DNSWriter(compress: false)
        writer.rdata(.nsec(next: DNSName(dotted: "h.local"), types: [DNSType.txt, DNSType.srv]))
        #expect(Array(writer.bytes.suffix(7)) == [0, 5, 0, 0, 0x80, 0, 0x40])
    }

    @Test func refusesPointerLoopsAndTruncation() {
        // A question whose name points at itself.
        let loop: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]
        #expect(throws: DNSMessage.ParseError.self) { try DNSMessage(bytes: loop) }
        #expect(throws: DNSMessage.ParseError.self) { try DNSMessage(bytes: [0, 0, 0, 0, 0, 1]) }
    }

    @Test func hostLabelsAreLettersDigitsAndHyphens() {
        #expect(MDNSResponder.hostLabel(for: "Homeswift (2)") == "Homeswift-2")
        #expect(MDNSResponder.hostLabel(for: "Salon TV 55\"") == "Salon-TV-55")
        #expect(MDNSResponder.hostLabel(for: "Télé") == "T-l")
        #expect(MDNSResponder.hostLabel(for: "***") == "Homeswift")
    }

    // MARK: The responder

    final class Wire: Sendable {
        let sent = NIOLockedValueBox<[(destination: SocketAddress, message: DNSMessage)]>([])

        func take() -> [(destination: SocketAddress, message: DNSMessage)] {
            sent.withLockedValue { sent in
                defer { sent = [] }
                return sent
            }
        }

        /// Waits until what was sent matches, for up to `timeout`: timers run late on a busy CI runner.
        func wait(
            _ timeout: Duration = .seconds(10), until match: @Sendable ([(destination: SocketAddress, message: DNSMessage)]) -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + timeout
            while !sent.withLockedValue({ match($0) }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    static let interface = MDNSResponder.Interface(index: 7, name: "eth0", addresses: [[192, 168, 1, 5]])
    static let peer = try! SocketAddress(ipAddress: "192.168.1.20", port: 5353)

    func makeResponder(interface: MDNSResponder.Interface = interface) throws -> (MDNSResponder, Wire) {
        let responder = MDNSResponder()
        let wire = Wire()
        try responder.loop.submit {
            responder.send = { _, destination, bytes in
                if let message = try? DNSMessage(bytes: bytes) { wire.sent.withLockedValue { $0.append((destination, message)) } }
            }
            responder.addInterface(interface)
        }.wait()
        return (responder, wire)
    }

    func deliver(_ message: DNSMessage, to responder: MDNSResponder, from source: SocketAddress = peer) throws {
        try responder.loop.submit { responder.received(message.encode(), from: source, interface: Self.interface.index) }.wait()
    }

    func txt(_ value: String) -> Data { BonjourAdvertiser.encode([("sf", value)]) }

    @Test func probesThenAnnouncesThenAnswersThenSaysGoodbye() async throws {
        let (responder, wire) = try makeResponder()
        let id = try await responder.register(name: "Homeswift", port: 51826, txt: txt("1"), interfaces: [], logger: testLogger).get()
        // Up to a second of probing, then two announcements a second apart.
        try await wire.wait { $0.filter(\.message.isResponse).count >= 2 }

        let sent = wire.take()
        let probes = sent.filter { !$0.message.isResponse }
        #expect(probes.count == 3)
        #expect(probes.allSatisfy { $0.message.authorities.contains { $0.type == DNSType.srv } })
        #expect(probes[0].message.questions.allSatisfy { $0.unicastResponse })
        #expect(sent.filter(\.message.isResponse).count == 2)
        let announcement = try #require(sent.first { $0.message.isResponse })
        #expect(announcement.destination == MDNSResponder.group)
        let host = DNSName(dotted: "Homeswift.local")
        #expect(announcement.message.answers.contains { $0.name == host && $0.data == .a([192, 168, 1, 5]) && $0.cacheFlush })
        #expect(announcement.message.answers.contains { $0.data == .ptr(DNSName(["Homeswift", "_hap", "_tcp", "local"])) && !$0.cacheFlush })

        // A browse: the PTR, with what resolving it needs as additionals, after the shared-record delay.
        try deliver(DNSMessage(questions: [DNSQuestion(name: MDNSResponder.serviceType, type: DNSType.ptr)]), to: responder)
        try await wire.wait { $0.contains { $0.message.additionals.contains { $0.type == DNSType.srv } } }
        let answer = try #require(wire.take().last { $0.message.answers.first?.type == DNSType.ptr })
        #expect(answer.message.additionals.contains { $0.type == DNSType.srv })
        #expect(answer.message.additionals.contains { $0.type == DNSType.a })

        // The querier already has the PTR: nothing to say.
        let known = DNSRecord(name: MDNSResponder.serviceType, data: .ptr(DNSName(["Homeswift", "_hap", "_tcp", "local"])), ttl: 4500)
        try deliver(DNSMessage(questions: [DNSQuestion(name: MDNSResponder.serviceType, type: DNSType.ptr)], answers: [known]), to: responder)
        try await Task.sleep(for: .milliseconds(200))
        #expect(wire.take().isEmpty)

        // A legacy resolver, from a port other than 5353: answered directly, with its id and short TTLs.
        let resolver = try SocketAddress(ipAddress: "192.168.1.20", port: 40000)
        try deliver(DNSMessage(id: 99, questions: [DNSQuestion(name: host, type: DNSType.a)]), to: responder, from: resolver)
        let direct = try #require(wire.take().first)
        #expect(direct.destination == resolver)
        #expect(direct.message.id == 99)
        #expect(direct.message.answers.allSatisfy { $0.ttl <= 10 && !$0.cacheFlush })

        // A TXT change is announced.
        responder.update(id: id, txt: txt("0"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(wire.take().contains { $0.message.answers.contains { $0.data == .txt(Array(txt("0"))) } })

        try await responder.unregister(id: id).get()
        let goodbye = try #require(wire.take().last)
        #expect(!goodbye.message.answers.isEmpty)
        #expect(goodbye.message.answers.allSatisfy { $0.ttl == 0 })
    }

    @Test func renamesWhenAnotherDeviceHasTheName() async throws {
        let (responder, wire) = try makeResponder()
        _ = try await responder.register(name: "Homeswift", port: 51826, txt: txt("1"), interfaces: [], logger: testLogger).get()
        // Another bridge has the name and answers every probe for it, with its own port: as a real device
        // defends its name, whenever this test gets to run.
        let original = DNSName(["Homeswift", "_hap", "_tcp", "local"])
        let theirs = DNSRecord(
            name: original, data: .srv(priority: 0, weight: 0, port: 40000, target: DNSName(dotted: "Other.local")), ttl: 120, cacheFlush: true)
        let renamed = DNSRecord.Data.ptr(DNSName(["Homeswift (2)", "_hap", "_tcp", "local"]))
        var announcement: DNSMessage?
        let deadline = ContinuousClock.now + .seconds(10)
        while announcement == nil, ContinuousClock.now < deadline {
            let sent = wire.take()
            if sent.contains(where: { !$0.message.isResponse && $0.message.questions.contains { $0.name == original } }) {
                try deliver(DNSMessage(isResponse: true, answers: [theirs]), to: responder)
            }
            announcement = sent.first { $0.message.isResponse && $0.message.answers.contains { $0.data == renamed } }?.message
            try await Task.sleep(for: .milliseconds(20))
        }
        let renamedAnnouncement = try #require(announcement)
        #expect(!renamedAnnouncement.answers.contains { $0.data == .ptr(original) })
        #expect(renamedAnnouncement.answers.contains { $0.name == DNSName(dotted: "Homeswift-2.local") && $0.type == DNSType.a })
    }

    @Test func ourOwnAnnouncementLoopedBackIsNoConflict() async throws {
        let (responder, wire) = try makeResponder()
        let id = try await responder.register(name: "Homeswift", port: 51826, txt: txt("1"), interfaces: [], logger: testLogger).get()
        try await wire.wait { $0.filter(\.message.isResponse).count >= 2 }
        let announcement = try #require(wire.take().first { $0.message.isResponse })
        try deliver(announcement.message, to: responder)
        try await Task.sleep(for: .milliseconds(1300))
        // No new probes: the name stays.
        #expect(wire.take().allSatisfy { $0.message.isResponse })
        try await responder.unregister(id: id).get()
    }

    @Test func ignoresPacketsFromOtherNetworks() async throws {
        var interface = Self.interface
        interface.netmasks = [[255, 255, 255, 0]]
        let (responder, wire) = try makeResponder(interface: interface)
        let id = try await responder.register(name: "Homeswift", port: 51826, txt: txt("1"), interfaces: [], logger: testLogger).get()
        try await wire.wait { $0.filter(\.message.isResponse).count >= 2 }
        _ = wire.take()
        let query = DNSMessage(id: 7, questions: [DNSQuestion(name: DNSName(dotted: "Homeswift.local"), type: DNSType.a)])

        // A unicast query from beyond the network (a spoofed source, to use the bridge as a reflector): no answer.
        try deliver(query, to: responder, from: try SocketAddress(ipAddress: "203.0.113.9", port: 40000))
        // Nor a conflict from there.
        let theirs = DNSRecord(name: DNSName(dotted: "Homeswift.local"), data: .a([10, 9, 9, 9]), ttl: 120, cacheFlush: true)
        try deliver(DNSMessage(isResponse: true, answers: [theirs]), to: responder, from: try SocketAddress(ipAddress: "203.0.113.9", port: 5353))
        try await Task.sleep(for: .milliseconds(300))
        #expect(wire.take().isEmpty)

        // The same query from this network is answered.
        try deliver(query, to: responder, from: try SocketAddress(ipAddress: "192.168.1.20", port: 40000))
        #expect(wire.take().first?.message.id == 7)
        try await responder.unregister(id: id).get()
    }

    @Test func multicastsARecordAtMostOnceASecond() async throws {
        let (responder, wire) = try makeResponder()
        let id = try await responder.register(name: "Homeswift", port: 51826, txt: txt("1"), interfaces: [], logger: testLogger).get()
        try await wire.wait { $0.filter(\.message.isResponse).count >= 2 }
        _ = wire.take()
        let query = DNSMessage(questions: [DNSQuestion(name: DNSName(dotted: "Homeswift.local"), type: DNSType.a)])
        for _ in 0..<5 { try deliver(query, to: responder) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(wire.take().count == 1)

        // A second later, the record may go out again.
        try await Task.sleep(for: .milliseconds(1000))
        try deliver(query, to: responder)
        #expect(wire.take().count == 1)
        try await responder.unregister(id: id).get()
    }

    @Test func simultaneousProbesCompareTheirData() {
        let name = DNSName(dotted: "h.local")
        let low = [DNSRecord(name: name, data: .a([10, 0, 0, 1]), ttl: 120)]
        let high = [DNSRecord(name: name, data: .a([10, 0, 0, 2]), ttl: 120)]
        #expect(MDNSResponder.compare(high, low) > 0)
        #expect(MDNSResponder.compare(low, high) < 0)
        #expect(MDNSResponder.compare(low, low) == 0)
        #expect(MDNSResponder.compare(low + high, low) > 0)
    }
}
