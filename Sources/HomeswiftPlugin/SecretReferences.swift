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
///
/// What a reference may reach is limited: a plugin's own entry (one with an owner) only from that plugin's block,
/// `file:` only below the folders `HOMESWIFT_SECRET_FILES` lists (`:`-separated; `/run/secrets`, Docker's, when it is
/// not set), and `env:` only the variables `HOMESWIFT_SECRET_ENV` lists when it is set (`,`-separated names, a trailing
/// `*` for a prefix).
public final class SecretResolver: @unchecked Sendable {
    public static let defaultFileFolders = ["/run/secrets"]

    private let vault: CredentialVault
    private let environment: [String: String]
    private let readFile: (String) throws -> Data
    private let fileFolders: [String]
    private let variables: [String]?
    private var entries: [String: VaultEntry]?
    /// The entries a reference read, for `recordUse`.
    public private(set) var used: Set<String> = []

    public init(storage: URL, environment: [String: String] = ProcessInfo.processInfo.environment, readFile: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }) {
        vault = CredentialVault(storage: storage)
        self.environment = environment
        self.readFile = readFile
        let folders = environment["HOMESWIFT_SECRET_FILES"].map { $0.split(separator: ":").map(String.init) } ?? Self.defaultFileFolders
        fileFolders = folders.filter { $0.hasPrefix("/") }.map(Self.canonical)
        variables = environment["HOMESWIFT_SECRET_ENV"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    /// The path with `.`, `..` and symbolic links resolved, so a reference cannot leave its folder through them.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The secret `reference` names, for the block of `owner` (`<platform>/<name>`).
    public func resolve(_ reference: SecretReference, owner: String? = nil) throws -> String {
        let failure = { (reason: String) in SecretReferenceError.Failure(reference: reference, reason: reason) }
        switch reference {
        case .vault(let name, let field):
            if entries == nil { entries = try vault.entries() }
            guard let entry = entries?[name] else { throw failure("no such entry in the vault") }
            // A plugin's own token is that plugin's: another block naming it gets nothing.
            if let entryOwner = entry.owner, entryOwner != owner { throw failure("the entry belongs to \(entryOwner)") }
            guard let value = entry.value(field: field) else {
                throw failure(field.map { "the entry has no field \($0)" } ?? "the entry has no \(entry.kind.mainField) field; name one with #field")
            }
            used.insert(name)
            return value
        case .environment(let name):
            if let variables, !variables.contains(where: { $0.hasSuffix("*") ? name.hasPrefix($0.dropLast()) : name == $0 }) {
                throw failure("HOMESWIFT_SECRET_ENV does not list the variable")
            }
            guard let value = environment[name], !value.isEmpty else { throw failure("the variable is not set") }
            return value
        case .file(let path):
            let resolved = Self.canonical(path)
            guard fileFolders.contains(where: { resolved.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else {
                throw failure("the file is not in a folder HOMESWIFT_SECRET_FILES lists (\(fileFolders.joined(separator: ":")))")
            }
            let data: Data
            do { data = try readFile(resolved) } catch { throw failure("the file cannot be read") }
            // Docker's secrets and `echo … > file` end with a newline that is not part of the secret.
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { throw SecretReferenceError.Failure(reference: reference, reason: "the file is empty") }
            return text
        }
    }

    /// Notes in the vault when the entries read were last used. Failing to write it changes nothing else.
    public func recordUse(now: Date = Date()) {
        try? vault.recordUse(used, now: now)
    }

    /// `value`, the block of `platform`'s instance `name`, with every reference under a secret-named key (`SecretWalk`)
    /// replaced by its secret. Each secret it puts in goes to `resolved`; each reference it cannot resolve to `failures`.
    func resolving(_ value: JSONValue, platform: String, name: String, resolved: inout [String], failures: inout [SecretReferenceError.Failure]) -> JSONValue {
        SecretWalk.map(value) { _, secret in
            guard let text = secret.stringValue, let reference = SecretReference(text) else { return nil }
            do {
                let plain = try resolve(reference, owner: "\(platform)/\(name)")
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

    /// The same failures without their reasons: for a caller that must not learn whether a file exists, a variable is
    /// set or an entry is in the vault (an MCP client, a dry run).
    public var withoutReasons: SecretReferenceError {
        SecretReferenceError(failures: failures.map { Failure(platform: $0.platform, reference: $0.reference, reason: "does not resolve") })
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
            let platform = result.platforms[index]
            let block = try JSONValue(data: platform.json)
            let next = resolver.resolving(block, platform: platform.platform, name: platform.name, resolved: &secrets.values, failures: &secrets.failures)
            if next != block { result.platforms[index].json = next.encoded() }
        }
        try secrets.finish()
        resolver.recordUse()
        return result
    }

    /// One block as config.json holds it (a form's, or the file's) with its sealed secrets opened and its references
    /// resolved: for what reads a block outside the running configuration, the Assistant's connection test.
    public static func opening(block: JSONValue, storage: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSONValue {
        let secrets = Opened()
        let revealed = try SecretBox.revealed(block, storage: storage) { secrets.values.append($0) }
        let platform = block["platform"]?.stringValue ?? ""
        let resolver = SecretResolver(storage: storage, environment: environment)
        let next = resolver.resolving(revealed, platform: platform, name: block["name"]?.stringValue ?? platform, resolved: &secrets.values, failures: &secrets.failures)
        try secrets.finish()
        resolver.recordUse()
        return next
    }

    /// The `env:` and `file:` references of `next` that `current` does not have at the same place, by
    /// `<platform>/<name>:<path>`: what a client that may not add them (an MCP client, the chat) would add.
    public static func newExternalReferences(in next: JSONValue, comparedWith current: JSONValue) -> [String] {
        func external(_ config: JSONValue) -> [String: String] {
            var found: [String: String] = [:]
            for block in config["platforms"]?.arrayValue ?? [] {
                let platform = block["platform"]?.stringValue ?? ""
                let name = block["name"]?.stringValue ?? platform
                SecretWalk.forEach(block) { path, _, value in
                    guard let text = value.stringValue, let reference = SecretReference(text) else { return }
                    if case .vault = reference { return }
                    found["\(platform)/\(name):\(SecretWalk.text(path))"] = text
                }
            }
            return found
        }
        let before = external(current)
        return external(next).filter { before[$0.key] != $0.value }.map(\.key).sorted()
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
