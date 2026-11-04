import Foundation

/// One SSDP message (UPnP Device Architecture 1.1, section 1): an M-SEARCH response (`HTTP/1.1 200 OK`), a `NOTIFY`
/// announcement or an `M-SEARCH` request, as its start line and headers, the header names lower-cased.
public struct SSDPMessage: Sendable, Equatable {
    public var startLine: String
    public var headers: [String: String]

    public init(startLine: String, headers: [String: String] = [:]) {
        self.startLine = startLine
        self.headers = headers
    }

    /// Parses a datagram: lines separated by CRLF (a bare LF too), the first the start line, every other
    /// `name: value` a header; a line without a colon is skipped, and a header without a value (`EXT:`) is kept empty.
    /// Nil when the datagram is not text or has no start line.
    public static func parse(_ data: Data) -> SSDPMessage? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        guard let startLine = lines.first, !startLine.isEmpty else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return SSDPMessage(startLine: startLine, headers: headers)
    }

    public subscript(header: String) -> String? { headers[header.lowercased()] }

    /// A response to an M-SEARCH.
    public var isSearchResponse: Bool { startLine.uppercased() == "HTTP/1.1 200 OK" }
    /// A `NOTIFY * HTTP/1.1` announcement.
    public var isNotify: Bool { startLine.uppercased() == "NOTIFY * HTTP/1.1" }
    /// An `ssdp:alive` announcement.
    public var isAlive: Bool { isNotify && self["nts"]?.lowercased() == "ssdp:alive" }
    /// The type a message is about: `ST` of a search response, `NT` of an announcement.
    public var type: String? { isNotify ? self["nt"] : self["st"] }
}

/// SSDP discovery over IPv4 multicast: an M-SEARCH from an ephemeral socket and its answers, and the `NOTIFY`
/// announcements devices send to 239.255.255.250:1900.
public enum SSDP {
    public static let multicastAddress = "239.255.255.250"
    public static let port = 1900

    /// What arrives, with the sender's IP address: answers and announcements may name another address in `LOCATION`.
    public typealias Received = (message: SSDPMessage, address: String)

    /// The M-SEARCH datagram for `searchTarget`: its lines separated by CRLF and ending with an empty line.
    public static func searchRequest(searchTarget: String, mx: Int = 5) -> Data {
        let lines = [
            "M-SEARCH * HTTP/1.1", "HOST: \(multicastAddress):\(port)", "MAN: \"ssdp:discover\"", "MX: \(mx)", "ST: \(searchTarget)",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Sends one M-SEARCH for `searchTarget` from a fresh ephemeral socket and yields the answers that arrive within
    /// `duration`; the socket closes then, and the stream ends. The stream is empty when no socket could be bound.
    public static func search(searchTarget: String, mx: Int = 5, duration: Duration = .seconds(5)) -> AsyncStream<Received> {
        AsyncStream { continuation in
            let task = Task {
                guard let socket = try? await UDPSocket.bind() else { return continuation.finish() }
                let reader = Task {
                    for await datagram in socket.datagrams {
                        guard let message = SSDPMessage.parse(datagram.data), message.isSearchResponse else { continue }
                        continuation.yield((message, datagram.address))
                    }
                }
                try? await socket.send(searchRequest(searchTarget: searchTarget, mx: mx), to: multicastAddress, port: port)
                try? await Task.sleep(for: duration)
                await socket.close()
                reader.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Listens on port 1900 (shared with other listeners, `SO_REUSEADDR`) in the SSDP multicast group and yields the
    /// `NOTIFY` announcements, until the consuming task is cancelled. It throws when the port cannot be bound.
    public static func listen(bufferSize: Int = 256) async throws -> (announcements: AsyncStream<Received>, close: @Sendable () async -> Void) {
        let socket = try await UDPSocket.bind(port: port, reuseAddress: true, multicastGroup: multicastAddress, bufferSize: bufferSize)
        let stream = AsyncStream<Received> { continuation in
            let task = Task {
                for await datagram in socket.datagrams {
                    guard let message = SSDPMessage.parse(datagram.data), message.isNotify else { continue }
                    continuation.yield((message, datagram.address))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, { await socket.close() })
    }
}
