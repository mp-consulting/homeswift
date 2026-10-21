import Foundation
import HomeswiftAI

/// The `HomeswiftUI` platform block: where the web UI listens and how it authenticates.
///
/// ```json
/// { "platform": "HomeswiftUI", "port": 8581, "host": "0.0.0.0", "auth": "form" }
/// ```
public struct UIConfiguration: Sendable, Equatable {
    public static let platform = "HomeswiftUI"
    public static let defaultPort = 8581

    public enum AuthMode: String, Sendable, Codable {
        /// A username and password, created on the first visit.
        case form
        /// No login: for a bridge that only listens on a trusted network or on localhost.
        case none
    }

    public var host = "0.0.0.0"
    public var port = defaultPort
    public var auth = AuthMode.form
    /// How long a login lasts without activity.
    public var sessionDays = 7
    /// Names the UI answers to besides IP addresses, localhost and this machine's name: a DNS name, a reverse
    /// proxy's host. Lower-cased. `*` allows every name.
    public var allowedHosts: [String] = []

    public init() {}

    public init(block: JSONValue) throws {
        if let host = block["host"]?.stringValue?.trimmingCharacters(in: .whitespaces), !host.isEmpty { self.host = host }
        if let port = block["port"], !port.isNull {
            guard let value = port.portValue else { throw UIConfigurationError.invalid(key: "port", expected: "a port number") }
            self.port = value
        }
        if let auth = block["auth"]?.stringValue {
            guard let mode = AuthMode(rawValue: auth) else { throw UIConfigurationError.invalid(key: "auth", expected: "form or none") }
            self.auth = mode
        }
        if let days = block["sessionDays"], !days.isNull {
            guard let value = days.intValue, value > 0 else { throw UIConfigurationError.invalid(key: "sessionDays", expected: "a positive number") }
            sessionDays = value
        }
        if let hosts = block["allowedHosts"], !hosts.isNull {
            guard let list = hosts.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                throw UIConfigurationError.invalid(key: "allowedHosts", expected: "a list of host names")
            }
            allowedHosts = list.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
    }
}

public enum UIConfigurationError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalid(key: String, expected: String)

    public var description: String {
        switch self {
        case .invalid(let key, let expected): "HomeswiftUI: \"\(key)\" must be \(expected)"
        }
    }
}
