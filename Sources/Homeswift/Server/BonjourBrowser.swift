import Foundation
import Logging
import NIOConcurrencyHelpers

#if canImport(dnssd)
import dnssd
#elseif canImport(CDNSSD)
import CDNSSD
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A service found on the local network.
public struct BonjourService: Sendable, Hashable {
    /// The instance name, e.g. "Elgato Key Light 1234".
    public var name: String
    /// The registration type as announced, e.g. "_elg._tcp.".
    public var type: String
    /// The domain, e.g. "local.".
    public var domain: String
    /// The host target, e.g. "elgato-key-light-1234.local.".
    public var hostName: String
    /// The port, in host byte order.
    public var port: Int
    /// The TXT entries; an entry without "=" maps to "".
    public var txt: [String: String]
    /// IPv4 literals first, then IPv6; empty when the address lookup timed out.
    public var addresses: [String]
    /// The interface the service was found on.
    public var interfaceIndex: UInt32

    public init(
        name: String, type: String, domain: String, hostName: String, port: Int,
        txt: [String: String], addresses: [String], interfaceIndex: UInt32
    ) {
        self.name = name
        self.type = type
        self.domain = domain
        self.hostName = hostName
        self.port = port
        self.txt = txt
        self.addresses = addresses
        self.interfaceIndex = interfaceIndex
    }
}

/// Discovers services on the LAN through dns_sd (built in on macOS, Avahi's compatibility library on
/// Linux), so device plugins can find their hardware by Bonjour.
public enum BonjourBrowser {
    public enum Event: Sendable {
        /// Emitted once the service is resolved and its addresses looked up. Emitted again when the
        /// service is re-announced (same name) so callers can refresh host and port.
        case found(BonjourService)
        case lost(name: String, type: String, domain: String)
    }

    /// Browses for `type` (e.g. "_elg._tcp") until the consuming task is cancelled or the stream is
    /// dropped. Browse errors (dns_sd unavailable, no Avahi daemon) are logged at warning level and
    /// finish the stream.
    public static func browse(
        type: String, domain: String? = nil, logger: Logger = Logger(label: "homeswift.bonjour")
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let session = Session(type: type, domain: domain, logger: logger, continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }

    /// DNS TXT wire format: each entry is one length byte followed by `key=value`. An entry without "="
    /// maps to ""; later duplicates of a key are ignored (RFC 6763 §6.4) and entries without a key skipped.
    static func parseTXT(_ bytes: UnsafeBufferPointer<UInt8>) -> [String: String] {
        var txt: [String: String] = [:]
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            let entry = bytes[(index + 1)..<min(index + 1 + length, bytes.count)]
            index += 1 + length
            let key: String
            let value: String
            if let separator = entry.firstIndex(of: UInt8(ascii: "=")) {
                key = String(decoding: entry[entry.startIndex..<separator], as: UTF8.self)
                value = String(decoding: entry[(separator + 1)...], as: UTF8.self)
            } else {
                key = String(decoding: entry, as: UTF8.self)
                value = ""
            }
            if !key.isEmpty, txt[key] == nil {
                txt[key] = value
            }
        }
        return txt
    }
}

extension BonjourBrowser {
    /// One browse: a dns_sd browse ref plus the one-shot resolve and address refs it spawns, all
    /// serviced by a dedicated thread that polls their sockets. The thread is the only one to create,
    /// process and deallocate refs, every dns_sd callback runs on it, and the thread holds the session
    /// alive until every ref is gone; the mutable state is guarded by `lock`. Hence `@unchecked Sendable`.
    private final class Session: @unchecked Sendable {
        private struct Key: Hashable {
            let name: String
            let type: String
            let domain: String
            let interfaceIndex: UInt32
        }

        /// A service the browse announced, being resolved and then looked up.
        private final class Pending {
            let key: Key
            var hostName = ""
            var port = 0
            var txt: [String: String] = [:]
            var ipv4: [String] = []
            var ipv6: [String] = []
            /// Address lookups still running.
            var outstanding = 0
            /// Set when the browse reports the service gone before its lookups finish.
            var cancelled = false

            init(key: Key) {
                self.key = key
            }

            var service: BonjourService {
                BonjourService(
                    name: key.name, type: key.type, domain: key.domain, hostName: hostName, port: port,
                    txt: txt, addresses: ipv4 + ipv6, interfaceIndex: key.interfaceIndex)
            }
        }

        /// A one-shot ref: deallocated by the poll thread once done or past its deadline.
        private final class Lookup {
            enum Kind { case resolve, ipv4, ipv6 }

            let ref: DNSServiceRef
            let kind: Kind
            let deadline: ContinuousClock.Instant
            let pending: Pending
            var done = false

            init(ref: DNSServiceRef, kind: Kind, deadline: ContinuousClock.Instant, pending: Pending) {
                self.ref = ref
                self.kind = kind
                self.deadline = deadline
                self.pending = pending
            }
        }

        private static let noError = DNSServiceErrorType(kDNSServiceErr_NoError)
        private static let lookupTimeout: Duration = .seconds(3)
        private static let pollTimeout: Int32 = 250

        private let regtype: String
        private let domain: String?
        private let logger: Logger
        private let continuation: AsyncStream<Event>.Continuation

        private let lock = NIOLock()
        private var running = true
        private var browseRef: DNSServiceRef?
        private var lookups: [Lookup] = []

        init(type: String, domain: String?, logger: Logger, continuation: AsyncStream<Event>.Continuation) {
            self.regtype = type
            self.domain = domain
            self.logger = logger
            self.continuation = continuation
        }

        // MARK: Lifecycle

        /// Starts the browse and its poll thread, or finishes the stream when dns_sd refuses the browse.
        func start() {
            var ref: DNSServiceRef?
            let result = withDomain { domain in
                DNSServiceBrowse(
                    &ref, 0, 0, regtype, domain,
                    { _, flags, interfaceIndex, error, name, regtype, domain, context in
                        Session.from(context)?.browseReply(
                            flags: flags, interfaceIndex: interfaceIndex, error: error,
                            name: name, regtype: regtype, domain: domain)
                    },
                    Unmanaged.passUnretained(self).toOpaque())
            }
            guard result == Self.noError, let ref else {
                logger.warning("Bonjour browse for \(regtype) failed: dns_sd error \(result)")
                continuation.finish()
                return
            }
            lock.withLock { browseRef = ref }
            let thread = Thread { self.run() }
            thread.name = "homeswift.bonjour.browse"
            thread.start()
        }

        /// Asks the poll thread to deallocate every ref and finish the stream.
        func stop() {
            lock.withLock { running = false }
        }

        private func withDomain<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
            if let domain {
                return domain.withCString { body($0) }
            }
            return body(nil)
        }

        // MARK: Poll thread

        private func run() {
            while true {
                let refs: [DNSServiceRef] = lock.withLock {
                    guard running, let browseRef else { return [] }
                    return [browseRef] + lookups.map(\.ref)
                }
                if refs.isEmpty { break }
                var descriptors = refs.map {
                    pollfd(fd: DNSServiceRefSockFD($0), events: Int16(POLLIN), revents: 0)
                }
                let ready = descriptors.withUnsafeMutableBufferPointer {
                    poll($0.baseAddress, nfds_t($0.count), Self.pollTimeout)
                }
                if ready > 0 {
                    for (index, ref) in refs.enumerated() where descriptors[index].revents != 0 {
                        let error = DNSServiceProcessResult(ref)
                        if error != Self.noError {
                            processingFailed(ref, error: error)
                        }
                    }
                }
                reap(now: .now)
            }
            let refs: [DNSServiceRef] = lock.withLock {
                defer {
                    browseRef = nil
                    lookups = []
                }
                return [browseRef].compactMap { $0 } + lookups.map(\.ref)
            }
            for ref in refs {
                DNSServiceRefDeallocate(ref)
            }
            continuation.finish()
        }

        private func processingFailed(_ ref: DNSServiceRef, error: DNSServiceErrorType) {
            var event: Event?
            let isBrowse: Bool = lock.withLock {
                if ref == browseRef {
                    running = false
                    return true
                }
                if let lookup = lookups.first(where: { $0.ref == ref && !$0.done }) {
                    event = finishLocked(lookup, reason: "dns_sd error \(error)")
                }
                return false
            }
            if isBrowse {
                logger.warning("Bonjour browse for \(regtype) stopped: dns_sd error \(error)")
            }
            if let event {
                continuation.yield(event)
            }
        }

        /// Deallocates the one-shot refs that finished and times out those past their deadline.
        private func reap(now: ContinuousClock.Instant) {
            var finished: [DNSServiceRef] = []
            var events: [Event] = []
            lock.withLock {
                lookups.removeAll { lookup in
                    if !lookup.done, lookup.deadline <= now, let event = finishLocked(lookup, reason: "timed out") {
                        events.append(event)
                    }
                    guard lookup.done else { return false }
                    finished.append(lookup.ref)
                    return true
                }
            }
            for ref in finished {
                DNSServiceRefDeallocate(ref)
            }
            for event in events {
                continuation.yield(event)
            }
        }

        /// Ends a lookup that got no (further) reply. Returns the `.found` to emit once a service's last
        /// address lookup ends. Call with `lock` held.
        private func finishLocked(_ lookup: Lookup, reason: String) -> Event? {
            lookup.done = true
            let pending = lookup.pending
            guard !pending.cancelled else { return nil }
            switch lookup.kind {
            case .resolve:
                logger.debug("Resolving \(pending.key.name) (\(pending.key.type)) \(reason)")
                return nil
            case .ipv4, .ipv6:
                logger.trace("Address lookup for \(pending.hostName) \(reason)")
                pending.outstanding -= 1
                return pending.outstanding == 0 ? .found(pending.service) : nil
            }
        }

        // MARK: Callbacks (on the poll thread)

        private static func from(_ context: UnsafeMutableRawPointer?) -> Session? {
            context.map { Unmanaged<Session>.fromOpaque($0).takeUnretainedValue() }
        }

        private static func string(_ pointer: UnsafePointer<CChar>?) -> String {
            pointer.map { String(cString: $0) } ?? ""
        }

        private func browseReply(
            flags: DNSServiceFlags, interfaceIndex: UInt32, error: DNSServiceErrorType,
            name: UnsafePointer<CChar>?, regtype: UnsafePointer<CChar>?, domain: UnsafePointer<CChar>?
        ) {
            guard error == Self.noError else {
                logger.warning("Bonjour browse for \(self.regtype) failed: dns_sd error \(error)")
                lock.withLock { running = false }
                return
            }
            let key = Key(
                name: Self.string(name), type: Self.string(regtype), domain: Self.string(domain),
                interfaceIndex: interfaceIndex)
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                logger.debug("Found \(key.name) (\(key.type)\(key.domain)) on interface \(interfaceIndex)")
                resolve(key)
            } else {
                logger.debug("Lost \(key.name) (\(key.type)\(key.domain)) on interface \(interfaceIndex)")
                lock.withLock {
                    for lookup in lookups where lookup.pending.key == key {
                        lookup.pending.cancelled = true
                        lookup.done = true
                    }
                }
                continuation.yield(.lost(name: key.name, type: key.type, domain: key.domain))
            }
        }

        private func resolve(_ key: Key) {
            lock.withLock {
                guard running, !lookups.contains(where: { $0.pending.key == key && !$0.pending.cancelled }) else {
                    return
                }
                var ref: DNSServiceRef?
                let result = DNSServiceResolve(
                    &ref, 0, key.interfaceIndex, key.name, key.type, key.domain,
                    { ref, _, _, error, _, host, port, txtLength, txt, context in
                        Session.from(context)?.resolveReply(
                            ref: ref, error: error, host: host, port: port, txtLength: txtLength, txt: txt)
                    },
                    Unmanaged.passUnretained(self).toOpaque())
                guard result == Self.noError, let ref else {
                    logger.debug("Resolving \(key.name) (\(key.type)) failed: dns_sd error \(result)")
                    return
                }
                lookups.append(
                    Lookup(ref: ref, kind: .resolve, deadline: .now + Self.lookupTimeout, pending: Pending(key: key)))
            }
        }

        private func resolveReply(
            ref: DNSServiceRef?, error: DNSServiceErrorType, host: UnsafePointer<CChar>?, port: UInt16,
            txtLength: UInt16, txt: UnsafeRawPointer?
        ) {
            var event: Event?
            lock.withLock {
                guard let lookup = lookups.first(where: { $0.ref == ref && !$0.done }) else { return }
                lookup.done = true
                let pending = lookup.pending
                guard !pending.cancelled else { return }
                guard error == Self.noError else {
                    logger.debug("Resolving \(pending.key.name) (\(pending.key.type)) failed: dns_sd error \(error)")
                    return
                }
                pending.hostName = Self.string(host)
                pending.port = Int(UInt16(bigEndian: port))
                pending.txt = BonjourBrowser.parseTXT(
                    UnsafeBufferPointer(start: txt?.assumingMemoryBound(to: UInt8.self), count: Int(txtLength)))
                logger.trace("Resolved \(pending.key.name): \(pending.hostName) port \(pending.port) txt \(pending.txt)")
                guard running else { return }
                for kind in [Lookup.Kind.ipv4, .ipv6] {
                    if let ref = query(kind, for: pending) {
                        lookups.append(Lookup(ref: ref, kind: kind, deadline: .now + Self.lookupTimeout, pending: pending))
                        pending.outstanding += 1
                    }
                }
                if pending.outstanding == 0 {
                    event = .found(pending.service)
                }
            }
            if let event {
                continuation.yield(event)
            }
        }

        /// Starts a one-shot A or AAAA query for the pending service's host. Call with `lock` held.
        private func query(_ kind: Lookup.Kind, for pending: Pending) -> DNSServiceRef? {
            let rrtype = kind == .ipv4 ? kDNSServiceType_A : kDNSServiceType_AAAA
            var ref: DNSServiceRef?
            let result = DNSServiceQueryRecord(
                &ref, 0, pending.key.interfaceIndex, pending.hostName, UInt16(rrtype), UInt16(kDNSServiceClass_IN),
                { ref, flags, _, error, _, _, _, rdlen, rdata, _, context in
                    Session.from(context)?.queryReply(ref: ref, flags: flags, error: error, rdlen: rdlen, rdata: rdata)
                },
                Unmanaged.passUnretained(self).toOpaque())
            guard result == Self.noError, let ref else {
                logger.debug("Address lookup for \(pending.hostName) failed to start: dns_sd error \(result)")
                return nil
            }
            return ref
        }

        private func queryReply(
            ref: DNSServiceRef?, flags: DNSServiceFlags, error: DNSServiceErrorType, rdlen: UInt16,
            rdata: UnsafeRawPointer?
        ) {
            var event: Event?
            lock.withLock {
                guard let lookup = lookups.first(where: { $0.ref == ref && !$0.done }) else { return }
                let pending = lookup.pending
                if error == Self.noError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata {
                    switch lookup.kind {
                    case .ipv4 where rdlen == 4:
                        pending.ipv4.append(Self.ipv4(rdata))
                    case .ipv6 where rdlen == 16:
                        if let address = Self.ipv6(rdata) {
                            pending.ipv6.append(address)
                        }
                    default:
                        break
                    }
                }
                if error != Self.noError || flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
                    event = finishLocked(lookup, reason: error == Self.noError ? "done" : "ended: dns_sd error \(error)")
                }
            }
            if let event {
                continuation.yield(event)
            }
        }

        private static func ipv4(_ rdata: UnsafeRawPointer) -> String {
            (0..<4).map { String(rdata.load(fromByteOffset: $0, as: UInt8.self)) }.joined(separator: ".")
        }

        private static func ipv6(_ rdata: UnsafeRawPointer) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return buffer.withUnsafeMutableBufferPointer { buffer -> String? in
                guard let start = buffer.baseAddress,
                    inet_ntop(AF_INET6, rdata, start, socklen_t(buffer.count)) != nil
                else { return nil }
                return String(cString: start)
            }
        }
    }
}
