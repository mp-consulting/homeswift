import Foundation
import Homeswift
import HomeswiftNetwork
import Logging

/// The LAN as it is: Bonjour, a UDP socket, HTTP through `HTTPSending`.
struct SystemLANNetwork: LANNetwork {
    static let serviceType = "_ewelink._tcp"

    var transport: any HTTPSending = URLSessionTransport()

    func browse(logger: Logger) -> AsyncStream<LANServiceEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in BonjourBrowser.browse(type: Self.serviceType, logger: logger) {
                    switch event {
                    case .found(let service):
                        continuation.yield(.found(name: service.name, addresses: service.addresses, port: service.port, txt: service.txt))
                    case .lost(let name, _, _):
                        continuation.yield(.lost(name: name))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listen(port: Int, logger: Logger) async throws -> any LANDatagramListener {
        try await UDPSocket.bind(port: port, reuseAddress: true)
    }

    func post(_ url: URL, body: Data, timeout: Int) async throws -> Data {
        try await transport.send(HTTPRequest(method: "POST", url: url, headers: [("Content-Type", "application/json")], body: body, timeout: .milliseconds(timeout))).body
    }
}

/// The UDP socket LAN control listens on (port 8082, every interface): the newest datagrams wait for it.
extension UDPSocket: LANDatagramListener {}
