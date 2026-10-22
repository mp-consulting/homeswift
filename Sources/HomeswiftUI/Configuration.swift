import Foundation
import HomeswiftAI

/// The `HomeswiftUI` platform block: where the web UI listens and how it authenticates.
///
/// ```json
/// { "platform": "HomeswiftUI", "port": 8581, "host": "0.0.0.0", "auth": "form", "https": true }
/// ```
public struct UIConfiguration: Sendable, Equatable {
    public static let platform = "HomeswiftUI"
    public static let defaultPort = 8581

    /// The block's settings form, in the shape of a plugin's config.schema.json: the web UI's Settings uses it.
    public static let schemaJSON = #"""
        {
          "pluginAlias": "HomeswiftUI",
          "schema": {
            "type": "object",
            "properties": {
              "port": { "title": "Port", "type": "integer", "default": 8581, "minimum": 1, "maximum": 65535, "description": "Where the web UI listens. After a change the page moves to the new port." },
              "host": { "title": "Listen on", "type": "string", "placeholder": "0.0.0.0", "description": "0.0.0.0 listens on every interface, so phones on the network can open the UI; 127.0.0.1 keeps it on this machine." },
              "auth": { "title": "Sign-in", "type": "string", "default": "form", "oneOf": [
                { "title": "Username and password", "enum": ["form"] },
                { "title": "None (a trusted network or this machine only)", "enum": ["none"] }
              ], "description": "Without sign-in anyone who reaches the address controls the bridge." },
              "sessionDays": { "title": "Stay signed in (days)", "type": "integer", "default": 7, "minimum": 1, "maximum": 365, "description": "How long a login lasts without activity." },
              "allowedHosts": { "title": "Other names", "type": "array", "items": { "type": "string" }, "description": "Names the UI answers to besides IP addresses, localhost and this machine's name: a DNS name, a reverse proxy's host. * allows every name." },
              "https": { "title": "HTTPS", "type": "boolean", "default": false, "description": "Serve the UI over HTTPS, which browsers need for the Assistant's microphone away from this machine. Without a certificate below, the bridge makes a self-signed one: the browser warns once, or install it from /homeswift-ui.crt to trust it." },
              "certificate": { "title": "Certificate file", "type": "string", "placeholder": "~/certs/homeswift.pem", "x-schema-form": { "type": "file", "accept": ".pem,.crt,.cer" }, "description": "A PEM certificate (with its chain) to use instead of the self-signed one: a path, or drop the file." },
              "privateKey": { "title": "Private key file", "type": "string", "placeholder": "~/certs/homeswift-key.pem", "x-schema-form": { "type": "file", "accept": ".pem,.key" }, "description": "The certificate's PEM private key: a path, or drop the file." }
            }
          },
          "layout": ["port", "host", "auth", "sessionDays", "allowedHosts", "https", "certificate", "privateKey"]
        }
        """#

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
    /// Serve over HTTPS, with `certificate` and `privateKey` (PEM files) or a self-signed certificate.
    public var https = false
    public var certificate: String?
    public var privateKey: String?

    public var scheme: String { https ? "https" : "http" }

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
        if let https = block["https"], !https.isNull {
            guard let value = https.boolValue else { throw UIConfigurationError.invalid(key: "https", expected: "true or false") }
            self.https = value
        }
        certificate = block["certificate"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        privateKey = block["privateKey"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        guard (certificate == nil) == (privateKey == nil) else {
            throw UIConfigurationError.invalid(key: certificate == nil ? "certificate" : "privateKey", expected: "given with the other: a certificate needs its private key")
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
