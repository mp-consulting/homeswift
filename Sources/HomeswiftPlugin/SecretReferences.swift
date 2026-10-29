import Foundation
import HomeswiftAI

/// Where a secret in config.json is kept when the file holds its name instead (docs/vault-design.md): an entry of the
/// local vault (`vault:unifi-home`, `vault:unifi-home#username`), an environment variable (`env:UNIFI_PASSWORD`) or a
/// file (`file:/run/secrets/unifi`, Docker's secrets).
public enum SecretReference: Equatable, Sendable, CustomStringConvertible {
    case vault(name: String, field: String?)
    case environment(String)
    case file(String)

    public init?(_ text: String) {
        guard Redaction.isSecretReference(text), let colon = text.firstIndex(of: ":") else { return nil }
        let rest = String(text[text.index(after: colon)...])
        switch text[..<colon] {
        case "vault":
            let parts = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard CredentialVault.isValidName(parts[0]), parts.count == 1 || !parts[1].isEmpty else { return nil }
            self = .vault(name: parts[0], field: parts.count == 2 ? parts[1] : nil)
        case "env":
            self = .environment(rest)
        case "file":
            guard rest.hasPrefix("/") else { return nil }
            self = .file(rest)
        default:
            return nil
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

    /// `value` with every reference under a secret-named key (the rule `SecretBox` seals by) replaced by its secret.
    /// Each secret it puts in goes to `resolved`; each reference it cannot resolve to `failures`.
    func resolving(_ value: JSONValue, underSecret: Bool = false, resolved: inout [String], failures: inout [SecretReferenceError.Failure]) -> JSONValue {
        switch value {
        case .string(let text) where underSecret:
            guard let reference = SecretReference(text) else { return value }
            do {
                let secret = try resolve(reference)
                resolved.append(secret)
                return .string(secret)
            } catch let failure as SecretReferenceError.Failure {
                failures.append(failure)
            } catch {
                failures.append(.init(reference: reference, reason: "\(error)"))
            }
            return value
        case .array(let items):
            return .array(items.map { resolving($0, underSecret: underSecret, resolved: &resolved, failures: &failures) })
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, entry in
                result[entry.key] = resolving(entry.value, underSecret: underSecret || Redaction.isSecretKey(entry.key), resolved: &resolved, failures: &failures)
            })
        default:
            return value
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
        let original = configuration
        var result = try SecretBox.revealing(configuration, storage: storage)
        let resolver = SecretResolver(storage: storage, environment: environment)
        var remembered: [String] = []
        var failures: [SecretReferenceError.Failure] = []
        for index in result.platforms.indices {
            let block = try JSONValue(data: result.platforms[index].json)
            var found: [SecretReferenceError.Failure] = []
            let next = resolver.resolving(block, resolved: &remembered, failures: &found)
            failures += found.map { failure in
                var failure = failure
                failure.platform = result.platforms[index].platform
                return failure
            }
            if next != block { result.platforms[index].json = next.encoded() }
            // The sealed values this block had are secrets too.
            if let before = try? JSONValue(data: original.platforms[index].json) {
                collectOpened(before, block, into: &remembered)
            }
        }
        if !failures.isEmpty { throw SecretReferenceError(failures: failures) }
        Redaction.rememberSecrets(remembered)
        return result
    }

    /// One block as config.json holds it (a form's, or the file's) with its sealed secrets opened and its references
    /// resolved: for what reads a block outside the running configuration, the Assistant's connection test.
    public static func opening(block: JSONValue, storage: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSONValue {
        let revealed = try SecretBox.revealed(block, storage: storage)
        var resolved: [String] = []
        var failures: [SecretReferenceError.Failure] = []
        let next = SecretResolver(storage: storage, environment: environment).resolving(revealed, resolved: &resolved, failures: &failures)
        if !failures.isEmpty { throw SecretReferenceError(failures: failures) }
        Redaction.rememberSecrets(resolved)
        return next
    }

    /// The strings of `opened` whose counterpart in `stored` was sealed.
    private static func collectOpened(_ stored: JSONValue, _ opened: JSONValue, into values: inout [String]) {
        switch (stored, opened) {
        case (.string(let before), .string(let after)) where SecretBox.isSealed(before):
            values.append(after)
        case (.array(let before), .array(let after)):
            for (b, a) in zip(before, after) { collectOpened(b, a, into: &values) }
        case (.object(let before), .object(let after)):
            for (key, b) in before { if let a = after[key] { collectOpened(b, a, into: &values) } }
        default:
            break
        }
    }
}
