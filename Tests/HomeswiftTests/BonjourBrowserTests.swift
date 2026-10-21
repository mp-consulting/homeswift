import Foundation
import Logging
import Testing

@testable import Homeswift

#if canImport(dnssd)
import dnssd
#endif

@Suite(.timeLimit(.minutes(1)))
struct BonjourBrowserTests {
    @Test func parsesTXTRecords() {
        var record = [UInt8](BonjourAdvertiser.encode([("id", "AA:BB"), ("md", "Elgato Key Light")]))
        record += [4] + Array("bare".utf8)
        let txt = record.withUnsafeBufferPointer { BonjourBrowser.parseTXT($0) }
        #expect(txt == ["id": "AA:BB", "md": "Elgato Key Light", "bare": ""])

        let empty = [UInt8]().withUnsafeBufferPointer { BonjourBrowser.parseTXT($0) }
        #expect(empty.isEmpty)
    }

    #if os(macOS)
    @Test func findsAnAdvertisedService() async throws {
        let name = "homeswift-test-\(UInt32.random(in: 1_000...9_999_999))"
        let registration = try TestRegistration(
            name: name, type: "_homeswifttest._tcp", port: 4711, txt: [("id", "AA:BB:CC"), ("md", "Test")])
        defer { registration.stop() }

        let stream = BonjourBrowser.browse(type: "_homeswifttest._tcp", logger: testLogger)
        let browsing = Task { () -> BonjourService? in
            for await event in stream {
                if case .found(let service) = event, service.name == name, !service.addresses.isEmpty {
                    return service
                }
            }
            return nil
        }
        let found = await withTaskGroup(of: BonjourService?.self) { group in
            group.addTask { await browsing.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                browsing.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let service = try #require(found, "no .found with addresses for \(name) within 10 seconds")
        #expect(service.type == "_homeswifttest._tcp.")
        #expect(service.port == 4711)
        #expect(service.txt == ["id": "AA:BB:CC", "md": "Test"])
        #expect(!service.hostName.isEmpty)

        registration.stop()
        browsing.cancel()
        _ = await browsing.value
    }
    #endif
}

#if os(macOS)
/// Registers a service the way `BonjourAdvertiser` does, with a test-only type instead of `_hap._tcp`.
private final class TestRegistration {
    struct Failure: Error {
        let code: DNSServiceErrorType
    }

    private var ref: DNSServiceRef?

    init(name: String, type: String, port: Int, txt: [(String, String)]) throws {
        var ref: DNSServiceRef?
        let record = BonjourAdvertiser.encode(txt)
        let result = record.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0, name, type, nil, nil, UInt16(port).bigEndian,
                UInt16(bytes.count), bytes.baseAddress,
                { _, _, _, _, _, _, _ in }, nil
            )
        }
        guard result == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            throw Failure(code: result)
        }
        self.ref = ref
    }

    /// Idempotent: the test stops explicitly and again from a `defer` on failure.
    func stop() {
        guard let ref else { return }
        self.ref = nil
        DNSServiceRefDeallocate(ref)
    }
}
#endif
