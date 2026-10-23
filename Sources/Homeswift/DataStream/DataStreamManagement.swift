import Foundation
import Logging
import NIOConcurrencyHelpers

/// The Data Stream Transport Management service and its data stream server (HAP-NodeJS's DataStreamManagement).
final class DataStreamManagement: @unchecked Sendable {
    let service: Service
    let server: DataStreamServer
    /// The last response, without the accessory's key salt: what a read returns.
    private let lastResponse = NIOLockedValueBox("")

    init(service: Service? = nil, logger: Logger = Logger(label: "homeswift.datastream")) {
        server = DataStreamServer(logger: logger)
        let service = service ?? Service(.dataStreamTransportManagement)
        self.service = service
        service.characteristic(.supportedDataStreamTransportConfiguration).set(.string(Self.supportedConfiguration().base64EncodedString()), notify: false)
        service.characteristic(.version).set(.string(DataStreamServer.version), notify: false)
        let setup = service.characteristic(.setupDataStreamTransport)
        setup.set(.string(""), notify: false)
        setup.onRead { [weak self] in .string(self?.lastResponse.withLockedValue { $0 } ?? "") }
        setup.onWriteResponse { [weak self] value in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            return .string(try await self.handleSetupWrite(value))
        }
    }

    /// One transport type: HomeKit Data Stream over TCP.
    static func supportedConfiguration() -> Data {
        HAPTLV.encode((1, .data(HAPTLV.encode((1, .byte(0))))))
    }

    func handleSetupWrite(_ value: HAPValue) async throws -> String {
        guard let context = HAPRequestContext.current, let sharedSecret = context.sharedSecret else {
            // HAP-NodeJS: the handler cannot be called from a plugin, only from a controller's connection.
            throw HAPStatusError(.invalidValueInRequest)
        }
        guard let string = value.stringValue, let data = Data(base64Encoded: string), let tlv = try? HAPTLV.decode(data),
            let command = tlv[1]?.first, let transport = tlv[2]?.first
        else { throw HAPStatusError(.invalidValueInRequest) }
        let controllerKeySalt = tlv[3] ?? Data()
        // Only "start session" over HomeKit Data Stream, with a 32-byte salt.
        guard command == 0, transport == 0, controllerKeySalt.count == 32 else { throw HAPStatusError(.invalidValueInRequest) }
        let prepared = try await server.prepareSession(context: context, sharedSecret: sharedSecret, controllerKeySalt: controllerKeySalt)
        let listeningPort = HAPTLV.encode((1, .data(HAPTLV.uint16(UInt16(prepared.port)))))
        let response = HAPTLV.encode((1, .byte(0)), (2, .data(listeningPort)))
        lastResponse.withLockedValue { $0 = response.base64EncodedString() }
        return (response + HAPTLV.encode((3, .data(prepared.accessoryKeySalt)))).base64EncodedString()
    }

    func onRequestMessage(_ proto: String, _ topic: String, _ handler: @escaping DataStreamServer.RequestHandler) {
        server.onRequestMessage(proto, topic, handler)
    }

    func destroy() {
        server.destroy()
        lastResponse.withLockedValue { $0 = "" }
    }
}
