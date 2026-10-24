import Foundation
import NIOCore
import NIOPosix

/// Handlers to run once a connection or socket closes, by registration token, so a stream or session that ends
/// first removes its own. Kept under its owner's lock.
struct CloseHandlers {
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var lastToken = 0

    var count: Int { handlers.count }

    mutating func add(_ handler: @escaping @Sendable () -> Void) -> Int {
        lastToken += 1
        handlers[lastToken] = handler
        return lastToken
    }

    mutating func remove(_ token: Int) {
        handlers[token] = nil
    }

    /// Every handler, in the order they were added; none is left.
    mutating func takeAll() -> [@Sendable () -> Void] {
        defer { handlers = [:] }
        return handlers.sorted { $0.key < $1.key }.map(\.value)
    }
}

/// The controller connection a request arrived on, available to read and write handlers while they run
/// (`HAPRequestContext.current`). Camera streams need the addresses and end with the connection; HomeKit Data
/// Stream derives its keys from the connection's shared secret.
public struct HAPRequestContext: Sendable {
    /// Identifies the connection for as long as it is open.
    public let connectionID: ObjectIdentifier
    /// The paired controller's identifier.
    public let controllerID: String?
    /// Whether the controller's pairing has admin permissions (HAP-NodeJS's `hasAdminPermissions`).
    public let isAdmin: Bool
    /// The accessory's own address on this connection, as the controller reaches it.
    public let localAddress: String?
    /// The controller's address.
    public let remoteAddress: String?
    let sharedSecret: Data?
    let connection: HAPConnection?

    init(
        connectionID: ObjectIdentifier, controllerID: String?, isAdmin: Bool = false, localAddress: String?, remoteAddress: String?,
        sharedSecret: Data?, connection: HAPConnection?
    ) {
        self.connectionID = connectionID
        self.controllerID = controllerID
        self.isAdmin = isAdmin
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.sharedSecret = sharedSecret
        self.connection = connection
    }

    /// The request being served, inside a characteristic's read or write handler; nil elsewhere.
    @TaskLocal public static var current: HAPRequestContext?

    /// Throws `insufficientPrivileges` (-70401) when the request being served comes from a controller without admin
    /// permissions: HAP-NodeJS's `adminOnlyAccess: [Access.WRITE]`. Writes from the plugin itself (no request) pass.
    public static func requireAdmin() throws {
        if let current, !current.isAdmin { throw HAPStatusError(.insufficientPrivileges) }
    }

    /// A close handler's registration: `remove()` drops it when what it ends (a stream, a session) ends first.
    public struct CloseRegistration: Sendable {
        weak var connection: HAPConnection?
        let token: Int?

        /// Nothing to remove: the handler ran at once, or the context has no connection.
        static let none = CloseRegistration(connection: nil, token: nil)

        public func remove() {
            if let token { connection?.removeCloseHandler(token) }
        }
    }

    /// Runs `handler` once the connection has closed (never for a context made without a connection, in tests).
    /// Remove the registration when what it ends ends first, or the connection keeps it until it closes.
    @discardableResult
    public func onClose(_ handler: @escaping @Sendable () -> Void) -> CloseRegistration {
        guard let connection else { return .none }
        return CloseRegistration(connection: connection, token: connection.onClose(handler))
    }

    /// Whether the address is IPv6, for the setup endpoints response.
    static func isIPv6(_ address: String) -> Bool { address.contains(":") }

    /// The accessory's address of `version` for this connection (HAP-NodeJS's `getLocalAddress`): the connection's
    /// own address when it has that version, else one of that version on the same network interface; nil when the
    /// interface has none.
    public func localAddress(for version: IPAddressVersion) -> String? {
        guard let localAddress else { return nil }
        if Self.isIPv6(localAddress) == (version == .ipv6) { return localAddress }
        let devices = ((try? System.enumerateDevices()) ?? []).compactMap { device in device.address.map { (device.name, $0) } }
        return Self.address(of: version, onInterfaceOf: localAddress, devices: devices)
    }

    /// An address of `version` on the interface that has `address`; IPv6 prefers an address without a scope (not
    /// link-local), as HAP-NodeJS does.
    static func address(of version: IPAddressVersion, onInterfaceOf address: String, devices: [(name: String, address: SocketAddress)]) -> String? {
        guard let interface = devices.first(where: { HAPConnection.plainAddress($0.address.ipAddress) == address })?.name else { return nil }
        let candidates = devices.filter { $0.name == interface }.map(\.address)
        switch version {
        case .ipv4:
            for case .v4(let ipv4) in candidates { return SocketAddress.v4(ipv4).ipAddress }
            return nil
        case .ipv6:
            var scoped: String?
            for case .v6(let ipv6) in candidates {
                guard let string = SocketAddress.v6(ipv6).ipAddress else { continue }
                if ipv6.address.sin6_scope_id == 0, !string.lowercased().hasPrefix("fe80:") { return string }
                scoped = scoped ?? string
            }
            return scoped
        }
    }
}
