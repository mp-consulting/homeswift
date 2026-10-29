import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A Multicast DNS responder in the process, for `_hap._tcp` services: what HAP-NodeJS's ciao does. The bridge
/// uses it when the system's dns_sd is unavailable (a Synology NAS, whose Avahi the package cannot reach, a
/// container without Avahi) or when config.json asks for it (`"advertiser": "ciao"`).
///
/// It shares UDP port 5353 with the system's responder (`SO_REUSEADDR`/`SO_REUSEPORT`, as Avahi and
/// mDNSResponder do), with a socket per IPv4 interface so each one is answered with its own addresses. Each
/// service gets a host name of its own, made from its name (`Homeswift.local`), so it never contends with the
/// machine's. Names are probed before use and renamed on a conflict (`Homeswift (2)`), announced twice,
/// re-announced when the TXT record changes, and withdrawn with a goodbye (RFC 6762).
final class MDNSResponder: @unchecked Sendable {
    static let shared = MDNSResponder()

    static let group = try! SocketAddress(ipAddress: "224.0.0.251", port: 5353)
    static let serviceType = DNSName(dotted: "_hap._tcp.local")
    static let serviceEnumeration = DNSName(dotted: "_services._dns-sd._udp.local")
    /// RFC 6762 §10: records about a host, and the others.
    static let hostTTL: UInt32 = 120
    static let otherTTL: UInt32 = 4500

    /// Used on `loop` only.
    final class Service: @unchecked Sendable {
        let id: Int
        let baseName: String
        var name: String
        var port: UInt16
        var txt: [UInt8]
        var isAnnounced = false
        /// Bumped when probing or announcing starts again, so the timers of the previous round stop.
        var generation = 0
        var renames = 0
        let logger: Logger

        init(id: Int, name: String, port: UInt16, txt: [UInt8], logger: Logger) {
            self.id = id
            baseName = name
            self.name = name
            self.port = port
            self.txt = txt
            self.logger = logger
        }

        var instance: DNSName { DNSName([name] + MDNSResponder.serviceType.labels) }
        var host: DNSName { DNSName([MDNSResponder.hostLabel(for: name), "local"]) }
    }

    struct Interface: Sendable {
        var index: Int
        var name: String
        /// IPv4 addresses, 4 bytes each.
        var addresses: [[UInt8]]
        /// The netmask of each address, in the same order; an address without one (a test's interface) takes
        /// packets from anywhere.
        var netmasks: [[UInt8]?] = []
        var channel: (any Channel)?

        /// Whether `source` is on one of the interface's networks (ciao's check, RFC 6762 §11): a packet from
        /// elsewhere reached port 5353 by unicast, and answering it would make the bridge a reflector.
        func isOnLink(_ source: SocketAddress) -> Bool {
            guard case .v4 = source, let ip = source.ipAddress, let bytes = MDNSResponder.parseIPv4(ip) else { return false }
            return addresses.indices.contains { index in
                guard index < netmasks.count, let mask = netmasks[index] else { return true }
                return (0..<4).allSatisfy { bytes[$0] & mask[$0] == addresses[index][$0] & mask[$0] }
            }
        }
    }

    // Everything below is used on `loop` only.
    let loop: any EventLoop
    private var services: [Int: Service] = [:]
    private var interfaces: [Int: Interface] = [:]
    private var nextID = 1
    private var filter: [String] = []
    private var refreshTask: RepeatedTask?
    /// When each record last went out by multicast in answer to a query, by interface: RFC 6762 §6 allows it once a
    /// second, so a flood of queries cannot make the bridge flood the network.
    private var lastMulticast: [Int: [DNSRecord: NIODeadline]] = [:]
    private var logger = Logger(label: "homeswift.mdns")
    /// Sends instead of the sockets, for tests: the interface index, the destination and the packet.
    var send: (@Sendable (Int, SocketAddress, [UInt8]) -> Void)?

    init(loop: any EventLoop = MultiThreadedEventLoopGroup.singleton.next()) {
        self.loop = loop
    }

    // MARK: Services

    /// Probes the name and advertises the service once it is the network's. `interfaces` are names or
    /// addresses to advertise on (Homebridge's `bind`); empty means every IPv4 interface with multicast.
    func register(name: String, port: Int, txt: Data, interfaces filter: [String], logger: Logger) -> EventLoopFuture<Int> {
        loop.submit { [self] in
            let service = Service(id: nextID, name: name, port: UInt16(clamping: port), txt: Array(txt), logger: logger)
            nextID += 1
            services[service.id] = service
            self.filter = filter
            self.logger = logger
            return service
        }.flatMap { [self] service in
            openInterfaces().map { [self] in
                if interfaces.isEmpty {
                    logger.error("Built-in mDNS responder: no IPv4 interface with multicast to advertise on\(filter.isEmpty ? "" : " among \(filter.joined(separator: ", "))")")
                }
                probe(service)
                return service.id
            }
        }
    }

    func update(id: Int, txt: Data) {
        loop.execute { [self] in
            guard let service = services[id], service.txt != Array(txt) else { return }
            service.txt = Array(txt)
            if service.isAnnounced { announce(service) }
        }
    }

    /// Sends the goodbye, and closes the sockets after the last service.
    func unregister(id: Int) -> EventLoopFuture<Void> {
        loop.flatSubmit { [self] in
            guard let service = services.removeValue(forKey: id) else { return loop.makeSucceededVoidFuture() }
            service.generation += 1
            var sent: [EventLoopFuture<Void>] = []
            if service.isAnnounced {
                for interface in interfaces.values {
                    let goodbye = records(of: service, on: interface).all.map { record -> DNSRecord in
                        var record = record
                        record.ttl = 0
                        return record
                    }
                    sent.append(multicast(DNSMessage(isResponse: true, answers: goodbye), on: interface))
                }
            }
            return EventLoopFuture.whenAllComplete(sent, on: loop).flatMap { [self] _ in
                guard services.isEmpty else { return loop.makeSucceededVoidFuture() }
                refreshTask?.cancel()
                refreshTask = nil
                let channels = interfaces.values.compactMap(\.channel)
                interfaces = [:]
                lastMulticast = [:]
                return EventLoopFuture.andAllComplete(channels.map { $0.close() }, on: loop)
            }
        }
    }

    /// Scales the protocol's delays (probes, announcements, the once-a-second rule): tests run them faster.
    var timeScale = 1.0

    private func scaled(_ delay: TimeAmount) -> TimeAmount { .nanoseconds(Int64(Double(delay.nanoseconds) * timeScale)) }

    // MARK: Probing and announcing

    /// Three probes 250 ms apart after a random delay (RFC 6762 §8.1); the name is ours when no one objects.
    func probe(_ service: Service) {
        service.generation += 1
        service.isAnnounced = false
        let generation = service.generation
        loop.scheduleTask(in: scaled(.milliseconds(Int64.random(in: 0...250)))) { [self] in
            sendProbe(service, generation: generation, number: 0)
        }
    }

    private func sendProbe(_ service: Service, generation: Int, number: Int) {
        guard services[service.id] === service, service.generation == generation else { return }
        guard number < 3 else {
            service.isAnnounced = true
            service.logger.info("Advertising \"\(service.name)\" with the built-in mDNS responder", metadata: ["interfaces": "\(describeInterfaces())"])
            announce(service)
            return
        }
        for interface in interfaces.values {
            let own = records(of: service, on: interface)
            let message = DNSMessage(
                questions: [DNSQuestion(name: service.instance, type: DNSType.any, unicastResponse: number == 0),
                            DNSQuestion(name: service.host, type: DNSType.any, unicastResponse: number == 0)],
                authorities: [own.srv, own.txt] + own.addresses)
            _ = multicast(message, on: interface)
        }
        loop.scheduleTask(in: scaled(.milliseconds(250))) { [self] in
            sendProbe(service, generation: generation, number: number + 1)
        }
    }

    /// Every record, twice, a second apart (RFC 6762 §8.3).
    func announce(_ service: Service) {
        service.generation += 1
        let generation = service.generation
        sendAnnouncement(service, generation: generation, remaining: 2)
    }

    private func sendAnnouncement(_ service: Service, generation: Int, remaining: Int) {
        guard remaining > 0, services[service.id] === service, service.generation == generation else { return }
        for interface in interfaces.values {
            let own = records(of: service, on: interface)
            _ = multicast(DNSMessage(isResponse: true, answers: own.all, additionals: own.nsec), on: interface)
        }
        loop.scheduleTask(in: scaled(.seconds(1))) { [self] in
            sendAnnouncement(service, generation: generation, remaining: remaining - 1)
        }
    }

    /// Another device has the name: pick the next one and probe again (RFC 6762 §9).
    private func conflict(_ service: Service) {
        service.renames += 1
        service.name = "\(service.baseName) (\(service.renames + 1))"
        service.logger.warning("Another device on the network is advertising this name; using \"\(service.name)\" instead")
        // RFC 6762 §8.1: after 15 conflicts within 10 seconds, wait 5 seconds before probing again.
        if service.renames % 15 == 0 {
            service.generation += 1
            let generation = service.generation
            loop.scheduleTask(in: scaled(.seconds(5))) { [self] in
                guard service.generation == generation else { return }
                probe(service)
            }
        } else {
            probe(service)
        }
    }

    // MARK: Records

    struct Records {
        var ptr: DNSRecord
        var enumeration: DNSRecord
        var srv: DNSRecord
        var txt: DNSRecord
        var addresses: [DNSRecord]
        /// What exists for the instance and the host: their absence of AAAA, for one.
        var nsec: [DNSRecord]

        var all: [DNSRecord] { [ptr, enumeration, srv, txt] + addresses }
    }

    func records(of service: Service, on interface: Interface) -> Records {
        let instance = service.instance
        let host = service.host
        return Records(
            ptr: DNSRecord(name: Self.serviceType, data: .ptr(instance), ttl: Self.otherTTL),
            enumeration: DNSRecord(name: Self.serviceEnumeration, data: .ptr(Self.serviceType), ttl: Self.otherTTL),
            srv: DNSRecord(name: instance, data: .srv(priority: 0, weight: 0, port: service.port, target: host), ttl: Self.hostTTL, cacheFlush: true),
            txt: DNSRecord(name: instance, data: .txt(service.txt), ttl: Self.otherTTL, cacheFlush: true),
            addresses: interface.addresses.map { DNSRecord(name: host, data: .a($0), ttl: Self.hostTTL, cacheFlush: true) },
            nsec: [
                DNSRecord(name: instance, data: .nsec(next: instance, types: [DNSType.txt, DNSType.srv]), ttl: Self.otherTTL, cacheFlush: true),
                DNSRecord(name: host, data: .nsec(next: host, types: [DNSType.a]), ttl: Self.hostTTL, cacheFlush: true),
            ])
    }

    /// The host label of a service name: letters, digits and hyphens (RFC 952), `Homeswift-2` for `Homeswift (2)`.
    static func hostLabel(for name: String) -> String {
        var label = ""
        for character in name.unicodeScalars {
            if character.isASCII, CharacterSet.alphanumerics.contains(character) {
                label.unicodeScalars.append(character)
            } else if !label.isEmpty, !label.hasSuffix("-") {
                label += "-"
            }
        }
        while label.hasSuffix("-") { label.removeLast() }
        return label.isEmpty ? "Homeswift" : String(label.prefix(63))
    }

    // MARK: Incoming packets

    func received(_ bytes: [UInt8], from source: SocketAddress, interface index: Int) {
        guard let interface = interfaces[index], interface.isOnLink(source), let message = try? DNSMessage(bytes: bytes) else { return }
        if message.isResponse {
            checkConflicts(in: message)
        } else {
            checkSimultaneousProbes(in: message, on: interface)
            answer(message, from: source, on: interface)
        }
    }

    /// A response that holds one of our unique names with other data: a device has it (RFC 6762 §9). Our own
    /// packets, looped back or reflected from another interface, carry our data and are not conflicts.
    private func checkConflicts(in message: DNSMessage) {
        let ourAddresses = Set(interfaces.values.flatMap(\.addresses))
        for service in Array(services.values) {
            let instance = service.instance
            let host = service.host
            let conflicting = (message.answers + message.additionals).contains { record in
                guard record.ttl > 0 else { return false }
                switch (record.data, record.name) {
                case (.srv(_, _, let port, let target), instance): return port != service.port || target != host
                case (.txt(let txt), instance): return txt != service.txt && !(txt == [0] && service.txt.isEmpty)
                case (.a(let address), host): return !ourAddresses.contains(address)
                default: return false
                }
            }
            if conflicting {
                if service.isAnnounced {
                    // It may be stale data in a cache: probe again, and rename only if someone answers.
                    service.logger.debug("mDNS: conflicting records for \"\(service.name)\"; probing again")
                    probe(service)
                } else {
                    conflict(service)
                }
            }
        }
    }

    /// Another device probing for a name we are probing: the lexicographically later data wins (RFC 6762 §8.2).
    private func checkSimultaneousProbes(in message: DNSMessage, on interface: Interface) {
        guard !message.authorities.isEmpty else { return }
        for service in Array(services.values) where !service.isAnnounced {
            let own = records(of: service, on: interface)
            for name in [service.instance, service.host] {
                let theirs = message.authorities.filter { $0.name == name }
                guard !theirs.isEmpty else { continue }
                let ours = ([own.srv, own.txt] + own.addresses).filter { $0.name == name }
                if Self.compare(theirs, ours) > 0 {
                    // We lost: wait a second and probe again; the winner's records then make it a conflict.
                    service.generation += 1
                    let generation = service.generation
                    loop.scheduleTask(in: scaled(.seconds(1))) { [self] in
                        guard service.generation == generation else { return }
                        probe(service)
                    }
                    return
                }
            }
        }
    }

    /// Compares two record sets as RFC 6762 §8.2 orders them: sorted, then record by record on class, type
    /// and data, the longer set winning a tie.
    static func compare(_ lhs: [DNSRecord], _ rhs: [DNSRecord]) -> Int {
        func key(_ record: DNSRecord) -> [UInt8] {
            [UInt8(record.type >> 8), UInt8(record.type & 0xFF)] + record.canonicalData
        }
        let left = lhs.map(key).sorted { $0.lexicographicallyPrecedes($1) }
        let right = rhs.map(key).sorted { $0.lexicographicallyPrecedes($1) }
        for (a, b) in zip(left, right) where a != b {
            return a.lexicographicallyPrecedes(b) ? -1 : 1
        }
        return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
    }

    /// Answers a query from what the announced services have on this interface (RFC 6762 §6).
    func answer(_ query: DNSMessage, from source: SocketAddress, on interface: Interface) {
        let announced = services.values.filter(\.isAnnounced).sorted { $0.id < $1.id }
        guard !announced.isEmpty, !query.questions.isEmpty else { return }
        var answers: [DNSRecord] = []
        var additionals: [DNSRecord] = []
        func add(_ record: DNSRecord, to list: inout [DNSRecord]) {
            if !list.contains(where: { $0.sameData(as: record) }) { list.append(record) }
        }
        // Built once for the query, not for each of its questions.
        let owned = announced.map { (service: $0, records: records(of: $0, on: interface)) }
        for question in query.questions {
            let wants = { (type: UInt16) in question.type == type || question.type == DNSType.any }
            for (service, own) in owned {
                switch question.name {
                case Self.serviceEnumeration where wants(DNSType.ptr):
                    add(own.enumeration, to: &answers)
                case Self.serviceType where wants(DNSType.ptr):
                    add(own.ptr, to: &answers)
                    for record in [own.srv, own.txt] + own.addresses + own.nsec { add(record, to: &additionals) }
                case service.instance:
                    if wants(DNSType.srv) { add(own.srv, to: &answers) }
                    if wants(DNSType.txt) { add(own.txt, to: &answers) }
                    if !wants(DNSType.srv), !wants(DNSType.txt) { add(own.nsec[0], to: &answers) }
                    if wants(DNSType.srv) { for record in own.addresses + [own.nsec[1]] { add(record, to: &additionals) } }
                case service.host:
                    if wants(DNSType.a) { for record in own.addresses { add(record, to: &answers) } }
                    if question.type == DNSType.aaaa { add(own.nsec[1], to: &answers) }
                default:
                    break
                }
            }
        }
        // Known-answer suppression (RFC 6762 §7.1): what the querier holds with more than half its TTL left.
        answers.removeAll { record in
            query.answers.contains { $0.sameData(as: record) && $0.ttl > record.ttl / 2 }
        }
        additionals.removeAll { record in answers.contains { $0.sameData(as: record) } }
        guard !answers.isEmpty else { return }

        if source.port != 5353 {
            // A legacy unicast query, from a resolver that is not a full mDNS querier (RFC 6762 §6.7): the query's
            // id and questions, short TTLs, no cache-flush bits.
            func legacy(_ record: DNSRecord) -> DNSRecord {
                var record = record
                record.ttl = min(record.ttl, 10)
                record.cacheFlush = false
                return record
            }
            let response = DNSMessage(id: query.id, isResponse: true, questions: query.questions, answers: answers.map(legacy), additionals: additionals.map(legacy))
            _ = transmit(response.encode(), to: source, on: interface)
        } else if query.questions.allSatisfy(\.unicastResponse) {
            _ = transmit(DNSMessage(isResponse: true, answers: answers, additionals: additionals).encode(), to: source, on: interface)
        } else {
            // Not a record more than once a second on an interface, but at once for a probe (RFC 6762 §6).
            if query.authorities.isEmpty {
                let now = NIODeadline.now()
                var recent = (lastMulticast[interface.index] ?? [:]).filter { now - $0.value < scaled(.seconds(1)) }
                answers.removeAll { recent[$0] != nil }
                for record in answers { recent[record] = now }
                lastMulticast[interface.index] = recent
                guard !answers.isEmpty else { return }
            }
            let response = DNSMessage(isResponse: true, answers: answers, additionals: additionals)
            // Shared records go out after 20–120 ms, so the answers of several responders can merge (§6).
            if answers.contains(where: { $0.type == DNSType.ptr }) {
                let index = interface.index
                loop.scheduleTask(in: scaled(.milliseconds(Int64.random(in: 20...120)))) { [self] in
                    guard let interface = interfaces[index] else { return }
                    _ = multicast(response, on: interface)
                }
            } else {
                _ = multicast(response, on: interface)
            }
        }
    }

    // MARK: Sockets

    @discardableResult
    private func multicast(_ message: DNSMessage, on interface: Interface) -> EventLoopFuture<Void> {
        transmit(message.encode(), to: Self.group, on: interface)
    }

    private func transmit(_ bytes: [UInt8], to destination: SocketAddress, on interface: Interface) -> EventLoopFuture<Void> {
        if let send {
            send(interface.index, destination, bytes)
            return loop.makeSucceededVoidFuture()
        }
        guard let channel = interface.channel else { return loop.makeSucceededVoidFuture() }
        let envelope = AddressedEnvelope(remoteAddress: destination, data: channel.allocator.buffer(bytes: bytes))
        return channel.writeAndFlush(envelope).recover { [logger = self.logger] error in
            logger.debug("mDNS: could not send on \(interface.name): \(error)")
        }
    }

    /// Opens a socket on each interface to advertise on, and checks again every 30 seconds: an address that
    /// changes, an interface that comes up after the bridge.
    private func openInterfaces() -> EventLoopFuture<Void> {
        if send != nil { return loop.makeSucceededVoidFuture() }
        let wanted = Self.candidateInterfaces(filter: filter)
        var opening: [EventLoopFuture<Void>] = []
        for (index, current) in interfaces where wanted[index] == nil {
            current.channel?.close(promise: nil)
            interfaces[index] = nil
            lastMulticast[index] = nil
        }
        for (index, interface) in wanted {
            if var current = interfaces[index] {
                guard current.addresses != interface.addresses || current.netmasks != interface.netmasks else { continue }
                let moved = current.addresses != interface.addresses
                current.addresses = interface.addresses
                current.netmasks = interface.netmasks
                interfaces[index] = current
                guard moved else { continue }
                for service in services.values where service.isAnnounced { announce(service) }
                continue
            }
            opening.append(open(interface).map { [self] channel in
                var interface = interface
                interface.channel = channel
                interfaces[index] = interface
                for service in services.values where service.isAnnounced { announce(service) }
            }.recover { [logger = self.logger] error in
                logger.warning("mDNS: cannot listen on \(interface.name): \(error)")
            })
        }
        if refreshTask == nil {
            refreshTask = loop.scheduleRepeatedTask(initialDelay: .seconds(30), delay: .seconds(30)) { [self] _ in
                _ = openInterfaces()
            }
        }
        return EventLoopFuture.andAllComplete(opening, on: loop)
    }

    private func open(_ interface: Interface) -> EventLoopFuture<any Channel> {
        let index = interface.index
        return DatagramBootstrap(group: loop)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(.so_reuseport), value: 1)
            .channelOption(.receivePacketInfo, value: true)
            .channelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Handler(responder: self, interfaceIndex: index))
                }
            }
            .bind(host: "0.0.0.0", port: 5353)
            .flatMap { channel in
                guard let multicast = channel as? any MulticastChannel, let options = channel as? any SocketOptionProvider,
                      let device = (try? System.enumerateDevices())?.first(where: { $0.interfaceIndex == index && $0.address?.protocol == .inet })
                else {
                    return channel.close().flatMapThrowing { throw ChannelError.operationUnsupported }
                }
                var address = in_addr()
                withUnsafeMutableBytes(of: &address.s_addr) { $0.copyBytes(from: interface.addresses.first ?? [0, 0, 0, 0]) }
                return multicast.joinGroup(Self.group, device: device)
                    .flatMap { [address] in options.setIPMulticastIF(address) }
                    .flatMap { options.setIPMulticastTTL(255) }
                    .flatMap { options.setIPMulticastLoop(1) }
                    .map { channel }
                    .flatMapError { error in channel.close().flatMapThrowing { throw error } }
            }
    }

    private func describeInterfaces() -> String {
        interfaces.values.sorted { $0.index < $1.index }.map { interface in
            "\(interface.name) (\(interface.addresses.map { $0.map(String.init).joined(separator: ".") }.joined(separator: ", ")))"
        }.joined(separator: ", ")
    }

    /// IPv4 interfaces with multicast, by index. Without a filter, loopback and container bridges are left
    /// out; with one, an interface is kept when its name or one of its addresses is listed.
    static func candidateInterfaces(filter: [String]) -> [Int: Interface] {
        var result: [Int: Interface] = [:]
        for device in (try? System.enumerateDevices()) ?? [] {
            guard device.multicastSupported, let address = device.address, address.protocol == .inet,
                  let ip = address.ipAddress, let bytes = parseIPv4(ip), bytes[0] != 127 else { continue }
            if filter.isEmpty {
                guard !["docker", "veth", "br-", "virbr", "lo"].contains(where: { device.name.hasPrefix($0) }) else { continue }
            } else {
                guard filter.contains(device.name) || filter.contains(ip) else { continue }
            }
            var interface = result[device.interfaceIndex] ?? Interface(index: device.interfaceIndex, name: device.name, addresses: [])
            interface.addresses.append(bytes)
            interface.netmasks.append(device.netmask?.ipAddress.flatMap(parseIPv4))
            result[device.interfaceIndex] = interface
        }
        return result
    }

    static func parseIPv4(_ string: String) -> [UInt8]? {
        let parts = string.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    /// Adds an interface without a socket, for tests that set `send`.
    func addInterface(_ interface: Interface) {
        loop.preconditionInEventLoop()
        interfaces[interface.index] = interface
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>

        let responder: MDNSResponder
        let interfaceIndex: Int

        init(responder: MDNSResponder, interfaceIndex: Int) {
            self.responder = responder
            self.interfaceIndex = interfaceIndex
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            // Every socket on port 5353 receives what reaches any interface: keep this interface's packets.
            if let info = envelope.metadata?.packetInfo, info.interfaceIndex != interfaceIndex { return }
            responder.received(Array(envelope.data.readableBytesView), from: envelope.remoteAddress, interface: interfaceIndex)
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            // A datagram error (an unreachable host for a unicast answer) leaves the socket usable.
        }
    }
}

/// Advertises a HAP server through `MDNSResponder`: the counterpart of `BonjourAdvertiser`.
final class MDNSAdvertiser: @unchecked Sendable {
    private let responder: MDNSResponder
    private let interfaces: [String]
    private let logger: Logger
    private let registration = NIOLockedValueBox<EventLoopFuture<Int>?>(nil)

    init(responder: MDNSResponder = .shared, interfaces: [String], logger: Logger) {
        self.responder = responder
        self.interfaces = interfaces
        self.logger = logger
    }

    func start(name: String, port: Int, txt: [(String, String)]) {
        let next = responder.register(name: name, port: port, txt: BonjourAdvertiser.encode(txt), interfaces: interfaces, logger: logger)
        let previous = registration.withLockedValue { registration in
            defer { registration = next }
            return registration
        }
        previous?.whenSuccess { [responder] id in _ = responder.unregister(id: id) }
    }

    func update(txt: [(String, String)]) {
        registration.withLockedValue { $0 }?.whenSuccess { [responder] id in responder.update(id: id, txt: BonjourAdvertiser.encode(txt)) }
    }

    /// Sends the goodbye before returning, so HomeKit drops the service at once.
    func stop() async {
        guard let current = registration.withLockedValue({ registration in
            defer { registration = nil }
            return registration
        }) else { return }
        guard let id = try? await current.get() else { return }
        try? await responder.unregister(id: id).get()
    }
}
