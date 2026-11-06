import Foundation
import NIOCore
import NIOPosix

/// What a reachability check asks: a host name or address, or the host of a URL (and its port). A MAC address has no
/// target: finding its address needs the ARP table (`ARPTable`).
public struct ReachabilityTarget: Sendable, Equatable {
    public var host: String
    public var ports: [Int]

    public init(host: String, ports: [Int]) {
        self.host = host
        self.ports = ports
    }

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if MACAddress.canonical(text) != nil { return nil }
        if text.contains("://"), let url = URL(string: text), let host = url.host, !host.isEmpty {
            self.host = host
            if let port = url.port { ports = [port] } else { ports = url.scheme?.lowercased() == "http" ? [80, 443] : [443, 80] }
            return
        }
        guard !text.isEmpty, !text.contains(" "), !text.contains("/") else { return nil }
        host = text
        ports = [80, 443]
    }
}

/// Whether a host answers; nil when the check itself failed (an unknown name).
public protocol ReachabilityProbing: Sendable {
    func isReachable(_ target: ReachabilityTarget) async -> Bool?
}

/// Reachability without ICMP, which needs privileges the bridge does not have: a TCP connection to the host's ports.
/// A host that accepts or refuses it answered, so it is reachable; a timeout or no route means it is not. A host that
/// drops every packet on those ports reads as unreachable. Dummy's "host comes or goes" and Presence's devices use it.
public struct TCPReachabilityProbe: ReachabilityProbing {
    public var timeout: TimeAmount

    public init(timeout: TimeAmount = .seconds(3)) {
        self.timeout = timeout
    }

    public func isReachable(_ target: ReachabilityTarget) async -> Bool? {
        var answered = false
        for port in target.ports {
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(timeout)
            do {
                let channel = try await bootstrap.connect(host: target.host, port: port).get()
                try? await channel.close()
                return true
            } catch let error as IOError where error.errnoCode == ECONNREFUSED || error.errnoCode == ECONNRESET {
                return true
            } catch let error as NIOConnectionError {
                // Every address of the name refused: the host answered.
                if error.connectionErrors.contains(where: { ($0.error as? IOError)?.errnoCode == ECONNREFUSED }) { return true }
                if error.dnsAAAAError != nil, error.dnsAError != nil, error.connectionErrors.isEmpty { return nil }
                answered = true
            } catch {
                answered = true
            }
        }
        return answered ? false : nil
    }
}
