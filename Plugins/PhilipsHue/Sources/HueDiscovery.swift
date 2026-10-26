import Foundation
import HomeswiftNetwork

/// Finds Hue Bridges: mDNS first (`_hue._tcp`, the bridges answering from their own address), else Philips' discovery
/// service, which lists the bridges of this public address (rate limited, and its answers may not be on this network).
enum HueDiscovery {
    static let serviceName = "_hue._tcp.local"
    static let cloudURL = URL(string: "https://discovery.meethue.com/")!

    @Sendable static func find() async -> [String] {
        if let answers = try? await MDNSQuery.query(serviceName, duration: .seconds(3)) {
            let hosts = unique(answers.map(\.sender))
            if !hosts.isEmpty { return hosts }
        }
        guard let response = try? await HTTPClient().send(HTTPRequest(url: cloudURL, timeout: .seconds(5))), response.status == 200 else { return [] }
        return cloudHosts(response.body)
    }

    /// `[{"id","internalipaddress","port"}]` as addresses.
    static func cloudHosts(_ body: Data) -> [String] {
        guard let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return [] }
        return unique(list.compactMap { $0["internalipaddress"] as? String }.filter { !$0.isEmpty })
    }

    static func unique(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        return hosts.filter { seen.insert($0).inserted }
    }
}
