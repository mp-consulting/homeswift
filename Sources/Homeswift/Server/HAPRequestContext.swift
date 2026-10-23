import Foundation

/// The controller connection a request arrived on, available to read and write handlers while they run
/// (`HAPRequestContext.current`). Camera streams need the addresses and end with the connection; HomeKit Data
/// Stream derives its keys from the connection's shared secret.
public struct HAPRequestContext: Sendable {
    /// Identifies the connection for as long as it is open.
    public let connectionID: ObjectIdentifier
    /// The paired controller's identifier.
    public let controllerID: String?
    /// The accessory's own address on this connection, as the controller reaches it.
    public let localAddress: String?
    /// The controller's address.
    public let remoteAddress: String?
    let sharedSecret: Data?
    let connection: HAPConnection?

    init(
        connectionID: ObjectIdentifier, controllerID: String?, localAddress: String?, remoteAddress: String?, sharedSecret: Data?,
        connection: HAPConnection?
    ) {
        self.connectionID = connectionID
        self.controllerID = controllerID
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.sharedSecret = sharedSecret
        self.connection = connection
    }

    /// The request being served, inside a characteristic's read or write handler; nil elsewhere.
    @TaskLocal public static var current: HAPRequestContext?

    /// Runs `handler` once the connection has closed (never for a context made without a connection, in tests).
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        connection?.onClose(handler)
    }

    /// Whether the address is IPv6, for the setup endpoints response.
    static func isIPv6(_ address: String) -> Bool { address.contains(":") }
}
