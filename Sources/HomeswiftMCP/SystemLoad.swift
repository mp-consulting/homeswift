import Foundation
import NIOConcurrencyHelpers
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The machine's load average and network throughput, for `get_system_info`: the byte counters of each
/// interface (`/proc/net/dev` on Linux, `getifaddrs` on macOS), read twice to get a rate.
enum SystemLoad {
    /// Bytes received and sent by one interface since it came up.
    struct Counters: Sendable, Equatable {
        var received: UInt64
        var sent: UInt64
    }

    struct Sample: Sendable {
        var date: Date
        var interfaces: [String: Counters]
    }

    /// The 1, 5 and 15 minute load averages; nil where the system has none.
    static func loadAverage() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return loads
    }

    /// The counters of the interfaces that are up, loopback left out.
    static func sample() -> Sample {
        Sample(date: Date(), interfaces: counters())
    }

    #if os(Linux)
    static func counters() -> [String: Counters] {
        guard let text = try? String(contentsOfFile: "/proc/net/dev", encoding: .utf8) else { return [:] }
        return parseProcNetDev(text)
    }
    #elseif canImport(Darwin)
    static func counters() -> [String: Counters] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: Counters] = [:]
        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[String(cString: entry.ifa_name)] = Counters(received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes))
        }
        return result
    }
    #else
    static func counters() -> [String: Counters] { [:] }
    #endif

    /// `/proc/net/dev`: two header lines, then `name: rx-bytes rx-packets … tx-bytes …` (tx bytes is the ninth number).
    static func parseProcNetDev(_ text: String) -> [String: Counters] {
        var result: [String: Counters] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let fields = line[line.index(after: colon)...].split(separator: " ").compactMap { UInt64($0) }
            guard name != "lo", fields.count >= 9 else { continue }
            result[name] = Counters(received: fields[0], sent: fields[8])
        }
        return result
    }

    /// Bytes per second between two samples, per interface and in all. A counter that went down wrapped (macOS
    /// keeps 32 bits) or was reset: counted from zero.
    static func throughput(from old: Sample, to new: Sample) -> (perInterface: [String: (received: Double, sent: Double)], received: Double, sent: Double) {
        let seconds = max(new.date.timeIntervalSince(old.date), 0.001)
        var perInterface: [String: (received: Double, sent: Double)] = [:]
        var received = 0.0
        var sent = 0.0
        for (name, counters) in new.interfaces {
            guard let before = old.interfaces[name] else { continue }
            let delta = { (now: UInt64, then: UInt64) -> Double in
                guard now >= then else { return then <= UInt64(UInt32.max) && now <= UInt64(UInt32.max) ? Double(UInt64(UInt32.max) - then + now + 1) : Double(now) }
                return Double(now - then)
            }
            let rate = (received: delta(counters.received, before.received) / seconds, sent: delta(counters.sent, before.sent) / seconds)
            perInterface[name] = rate
            received += rate.received
            sent += rate.sent
        }
        return (perInterface, received, sent)
    }

    /// The previous sample, so a call reads the rate since the one before it instead of waiting.
    private static let last = NIOLockedValueBox<Sample?>(nil)

    /// The throughput since the previous call when it was at most ten minutes ago (and at least a second),
    /// else over the next second.
    static func currentThroughput() async -> (sample: Sample, perInterface: [String: (received: Double, sent: Double)], received: Double, sent: Double, seconds: Double) {
        var previous = last.withLockedValue { $0 }
        if previous.map({ Date().timeIntervalSince($0.date) > 600 || Date().timeIntervalSince($0.date) < 1 }) ?? true {
            previous = sample()
            try? await Task.sleep(for: .seconds(1))
        }
        let now = sample()
        last.withLockedValue { $0 = now }
        let rates = throughput(from: previous!, to: now)
        return (now, rates.perInterface, rates.received, rates.sent, now.date.timeIntervalSince(previous!.date))
    }
}
