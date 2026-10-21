import Foundation
import NIOConcurrencyHelpers

#if canImport(dnssd)
import dnssd
#elseif canImport(CDNSSD)
import CDNSSD
#endif

#if canImport(Glibc)
import Glibc
#endif

/// Advertises `_hap._tcp` with the HAP TXT record through dns_sd (built in on macOS, Avahi's
/// compatibility library on Linux).
final class BonjourAdvertiser: @unchecked Sendable {
    enum AdvertiserError: Error { case registration(Int32) }

    private struct Registration {
        var ref: DNSServiceRef
        var name: String
        var port: Int
        var running: NIOLockedValueBox<Bool>
    }

    private let lock = NIOLock()
    private var registration: Registration?
    private let queue = DispatchQueue(label: "homeswift.bonjour")

    func start(name: String, port: Int, txt: [(String, String)]) throws {
        try lock.withLock {
            stopLocked()
            registration = try register(name: name, port: port, txt: txt)
        }
    }

    /// Republishes the TXT record, e.g. after pairing changes `sf` or the database changes `c#`.
    func update(txt: [(String, String)]) {
        lock.withLock {
            guard let current = registration else { return }
            let record = Self.encode(txt)
            let result = record.withUnsafeBytes { bytes in
                DNSServiceUpdateRecord(current.ref, nil, 0, UInt16(bytes.count), bytes.baseAddress, 0)
            }
            if result != DNSServiceErrorType(kDNSServiceErr_NoError) {
                // Some dns_sd implementations cannot update the primary TXT record; register again.
                stopLocked()
                registration = try? register(name: current.name, port: current.port, txt: txt)
            }
        }
    }

    func stop() {
        lock.withLock { stopLocked() }
    }

    private func stopLocked() {
        guard let current = registration else { return }
        registration = nil
        #if os(Linux)
        // The polling thread deallocates the ref once it sees `running` turn false.
        current.running.withLockedValue { $0 = false }
        #else
        DNSServiceRefDeallocate(current.ref)
        #endif
    }

    private func register(name: String, port: Int, txt: [(String, String)]) throws -> Registration {
        var ref: DNSServiceRef?
        let record = Self.encode(txt)
        let result = record.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0, name, "_hap._tcp", nil, nil, UInt16(port).bigEndian,
                UInt16(bytes.count), bytes.baseAddress,
                { _, _, _, _, _, _, _ in }, nil
            )
        }
        guard result == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            throw AdvertiserError.registration(Int32(result))
        }
        let running = NIOLockedValueBox(true)
        #if os(Linux)
        let thread = Thread { Self.poll(ref, running: running) }
        thread.name = "homeswift.bonjour"
        thread.start()
        #else
        DNSServiceSetDispatchQueue(ref, queue)
        #endif
        return Registration(ref: ref, name: name, port: port, running: running)
    }

    #if os(Linux)
    private static func poll(_ ref: DNSServiceRef, running: NIOLockedValueBox<Bool>) {
        let fd = DNSServiceRefSockFD(ref)
        while running.withLockedValue({ $0 }) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if Glibc.poll(&descriptor, 1, 500) > 0, descriptor.revents & Int16(POLLIN) != 0 {
                DNSServiceProcessResult(ref)
            }
        }
        DNSServiceRefDeallocate(ref)
    }
    #endif

    /// DNS TXT wire format: each `key=value` prefixed by its length.
    static func encode(_ txt: [(String, String)]) -> Data {
        var data = Data()
        for (key, value) in txt {
            let entry = Data("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }
}
