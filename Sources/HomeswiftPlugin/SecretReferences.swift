import Foundation
import HomeswiftAI

/// Where a secret in config.json is kept when the file holds its name instead (docs/vault-design.md): an entry of the
/// local vault (`vault:unifi-home`, `vault:unifi-home#username`), an environment variable (`env:UNIFI_PASSWORD`) or a
/// file (`file:/run/secrets/unifi`, Docker's secrets).
public enum SecretReference: Equatable, Sendable, CustomStringConvertible {
    case vault(name: String, field: String?)
    case environment(String)
    case file(String)

    /// The reference `text` is, by `Redaction.referencePattern`, the rule sealing and masking follow too.
    public init?(_ text: String) {
        guard Redaction.isSecretReference(text), let colon = text.firstIndex(of: ":") else { return nil }
        let rest = String(text[text.index(after: colon)...])
        switch text[..<colon] {
        case "vault":
            let parts = rest.split(separator: "#", maxSplits: 1).map(String.init)
            self = .vault(name: parts[0], field: parts.count == 2 ? parts[1] : nil)
        case "env":
            self = .environment(rest)
        default:
            self = .file(rest)
        }
    }

    public var description: String {
        switch self {
        case .vault(let name, let field): "vault:\(name)" + (field.map { "#\($0)" } ?? "")
        case .environment(let name): "env:\(name)"
        case .file(let path): "file:\(path)"
        }
    }
}

/// Turns references into the secrets they name. The vault is read once per resolver, so a config that names an entry
/// ten times opens the file once.
public final class SecretResolver: @unchecked Sendable {
    private let vault: CredentialVault
    private let environment: [String: String]
    private let readFile: (String) throws -> Data
    private var entries: [String: VaultEntry]?

    public init(storage: URL, environment: [String: String] = ProcessInfo.processInfo.environment, readFile: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }) {
        vault = CredentialVault(storage: storage)
        self.environment = environment
        self.readFile = readFile
    }

    public func resolve(_ reference: SecretReference) throws -> String {
        switch reference {
        case .vault(let name, let field):
            if entries == nil { entries = try vault.entries() }
            guard let entry = entries?[name] else { throw SecretReferenceError.Failure(reference: reference, reason: "no such entry in the vault") }
            guard let value = entry.value(field: field) else {
                let reason = field.map { "the entry has no field \($0)" } ?? "the entry has no \(entry.kind.mainField) field; name one with #field"
                throw SecretReferenceError.Failure(reference: reference, reason: reason)
            }
            return value
        case .environment(let name):
            guard let value = environment[name], !value.isEmpty else { throw SecretReferenceError.Failure(reference: reference, reason: "the variable is not set") }
            return value
        case .file(let path):
            let data: Data
            do { data = try readFile(path) } catch { throw SecretReferenceError.Failure(reference: reference, reason: "the file cannot be read") }
            // Docker's secrets and `echo … > file` end with a newline that is not part of the secret.
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { throw SecretReferenceError.Failure(reference: reference, reason: "the file is empty") }
            return text
        }
    }

    /// `value` with every reference under a secret-named key (`SecretWalk`) replaced by its secret. Each secret it puts
    /// in goes to `resolved`; each reference it cannot resolve to `failures`, with `platform`.
    func resolving(_ value: JSONValue, platform: String? = nil, resolved: inout [String], failures: inout [SecretReferenceError.Failure]) -> JSONValue {
        SecretWalk.map(value) { _, secret in
            guard let text = secret.stringValue, let reference = SecretReference(text) else { return nil }
            do {
                let plain = try resolve(reference)
                resolved.append(plain)
                return .string(plain)
            } catch var failure as SecretReferenceError.Failure {
                failure.platform = platform
                failures.append(failure)
            } catch {
                failures.append(.init(platform: platform, reference: reference, reason: "\(error)"))
            }
            return nil
        }
    }
}

public struct SecretReferenceError: Error, CustomStringConvertible, Equatable, Sendable {
    public struct Failure: Error, Equatable, Sendable {
        public var platform: String?
        public var reference: SecretReference
        public var reason: String
    }

    public var failures: [Failure]

    public var description: String {
        // References are names, never secrets: they are shown as they are.
        "secrets cannot be resolved: " + failures.map { failure in
            (failure.platform.map { "\($0): " } ?? "") + "\(failure.reference) (\(failure.reason))"
        }.joined(separator: "; ")
    }
}

/// The secrets of a configuration opened for the runtime: sealed ones (`SecretBox`), then references
/// (`SecretResolver`). What it opens is given to `Redaction.rememberSecrets`, so those exact values are masked in logs,
/// MCP replies and the Assistant's prompts wherever they turn up.
public enum ConfigurationSecrets {
    public static func opening(
        _ configuration: HomeswiftConfiguration, storage: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HomeswiftConfiguration {
        let secrets = Opened()
        var result = try SecretBox.revealing(configuration, storage: storage) { secrets.values.append($0) }
        let resolver = SecretResolver(storage: storage, environment: environment)
        for index in result.platforms.indices {
            let block = try JSONValue(data: result.platforms[index].json)
            let next = resolver.resolving(block, platform: result.platforms[index].platform, resolved: &secrets.values, failures: &secrets.failures)
            if next != block { result.platforms[index].json = next.encoded() }
        }
        try secrets.finish()
        return result
    }

    /// One block as config.json holds it (a form's, or the file's) with its sealed secrets opened and its references
    /// resolved: for what reads a block outside the running configuration, the Assistant's connection test.
    public static func opening(block: JSONValue, storage: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSONValue {
        let secrets = Opened()
        let revealed = try SecretBox.revealed(block, storage: storage) { secrets.values.append($0) }
        let next = SecretResolver(storage: storage, environment: environment).resolving(revealed, resolved: &secrets.values, failures: &secrets.failures)
        try secrets.finish()
        return next
    }

    /// What an opening found: the values it opened or resolved, remembered for masking once nothing failed.
    private final class Opened {
        var values: [String] = []
        var failures: [SecretReferenceError.Failure] = []

        func finish() throws {
            if !failures.isEmpty { throw SecretReferenceError(failures: failures) }
            Redaction.rememberSecrets(values)
        }
    }
}
