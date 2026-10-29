import Foundation
import Homeswift
import HomeswiftAI
import Testing

@testable import HomeswiftPlugin

@Suite(.timeLimit(.minutes(1)))
struct VaultTests {
    func storage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-vault-\(UUID().uuidString)")
    }

    func configuration(_ block: String) throws -> HomeswiftConfiguration {
        try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "name": "H" }, "platforms": [ \#(block) ] }"#.utf8))
    }

    @Test func entriesAreSealedOnDiskAndOpenAgain() throws {
        let directory = storage()
        let vault = CredentialVault(storage: directory)
        try vault.set("unifi-home", VaultEntry(kind: .login, fields: ["username": "admin", "password": "correct horse"]))
        let text = try String(contentsOf: vault.url, encoding: .utf8)
        #expect(!text.contains("correct horse"))
        #expect(text.contains(SecretBox.prefix))
        #expect(try vault.entry(named: "unifi-home")?.fields["password"] == "correct horse")
        #expect(try vault.names() == ["unifi-home"])
        let attributes = try FileManager.default.attributesOfItem(atPath: vault.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func replacingAnEntryKeepsItsCreationDate() throws {
        let vault = CredentialVault(storage: storage())
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try vault.set("key", VaultEntry(kind: .apiKey, fields: ["key": "sk-one-111"], created: created))
        try vault.set("key", VaultEntry(kind: .apiKey, fields: ["key": "sk-two-222"]))
        let entry = try #require(try vault.entry(named: "key"))
        #expect(entry.created == created)
        #expect(entry.fields["key"] == "sk-two-222")
        #expect(try vault.remove("key"))
        #expect(try !vault.remove("key"))
    }

    @Test func namesFitInAReference() {
        #expect(CredentialVault.isValidName("unifi-home.v2_a"))
        #expect(!CredentialVault.isValidName("-starts-with-dash"))
        #expect(!CredentialVault.isValidName("has space"))
        #expect(!CredentialVault.isValidName("has#hash"))
        #expect(throws: CredentialVaultError.self) { try CredentialVault(storage: storage()).set("a b", VaultEntry(kind: .secret, fields: ["value": "x"])) }
    }

    @Test func referencesParse() {
        #expect(SecretReference("vault:unifi-home") == .vault(name: "unifi-home", field: nil))
        #expect(SecretReference("vault:unifi-home#username") == .vault(name: "unifi-home", field: "username"))
        #expect(SecretReference("env:UNIFI_PASSWORD") == .environment("UNIFI_PASSWORD"))
        #expect(SecretReference("file:/run/secrets/unifi") == .file("/run/secrets/unifi"))
        #expect(SecretReference("file:relative") == nil)
        #expect(SecretReference("vault:") == nil)
        #expect(SecretReference("vault:a#") == nil)
        #expect(SecretReference("env:has space") == nil)
        #expect(SecretReference("hunter2") == nil)
    }

    @Test func openingResolvesEachKindOfReference() throws {
        let directory = storage()
        try CredentialVault(storage: directory).set("unifi", VaultEntry(kind: .login, fields: ["username": "admin", "password": "pw-from-vault"]))
        let secretFile = directory.appendingPathComponent("docker-secret")
        try Data("pw-from-file\n".utf8).write(to: secretFile)
        let configuration = try configuration(#"""
            { "platform": "UniFi", "name": "UniFi", "password": "vault:unifi", "apiKey": "env:UNIFI_KEY",
              "token": "file:\#(secretFile.path)", "host": "vault:not-a-secret-key",
              "devices": [ { "name": "Door", "password": "vault:unifi#username" } ] }
            """#)
        let opened = try ConfigurationSecrets.opening(configuration, storage: directory, environment: ["UNIFI_KEY": "key-from-env"])
        let block = try JSONValue(data: opened.platforms[0].json)
        #expect(block["password"]?.stringValue == "pw-from-vault")
        #expect(block["apiKey"]?.stringValue == "key-from-env")
        #expect(block["token"]?.stringValue == "pw-from-file")
        #expect(block["devices"]?[0]?["password"]?.stringValue == "admin")
        // Only secret-named keys hold references: any other value is the plugin's, as written.
        #expect(block["host"]?.stringValue == "vault:not-a-secret-key")
    }

    @Test func everyReferenceThatDoesNotResolveIsNamed() throws {
        let configuration = try configuration(#"{ "platform": "UniFi", "name": "UniFi", "password": "vault:missing", "apiKey": "env:UNSET" }"#)
        do {
            _ = try ConfigurationSecrets.opening(configuration, storage: storage(), environment: [:])
            Issue.record("expected a failure")
        } catch let error as SecretReferenceError {
            #expect(error.failures.count == 2)
            #expect(error.description.contains("UniFi: vault:missing (no such entry in the vault)"))
            #expect(error.description.contains("env:UNSET (the variable is not set)"))
        }
    }

    @Test func sealingKeepsReferences() {
        let config: JSONValue = ["platforms": [["platform": "Govee", "password": "vault:govee", "token": "plain-token"]]]
        let sealed = SecretBox.sealingSecrets(config) { "sealed(\($0))" }
        #expect(sealed["platforms"]?[0]?["password"]?.stringValue == "vault:govee")
        #expect(sealed["platforms"]?[0]?["token"]?.stringValue == "sealed(plain-token)")
    }

    @Test func redactionShowsReferencesAndMasksWhatWasOpened() throws {
        let config: JSONValue = ["platforms": [["platform": "Govee", "password": "vault:govee", "token": "plain-token"]]]
        let redacted = Redaction.redactSecrets(config)
        #expect(redacted["platforms"]?[0]?["password"]?.stringValue == "vault:govee")
        #expect(redacted["platforms"]?[0]?["token"]?.stringValue == Redaction.placeholder)
        #expect(Redaction.redactText("password: vault:govee") == "password: vault:govee")

        let directory = storage()
        let unique = "opened-\(UUID().uuidString.prefix(8))"
        try CredentialVault(storage: directory).set("govee", VaultEntry(kind: .secret, fields: ["value": unique]))
        _ = try ConfigurationSecrets.opening(configuration(#"{ "platform": "Govee", "name": "Govee", "password": "vault:govee" }"#), storage: directory)
        // Whatever key or shape it turns up under, the exact value is masked.
        #expect(Redaction.redactText("reply {\"x\":\"\(unique)\"}") == "reply {\"x\":\"\(Redaction.placeholder)\"}")
    }

    struct Tokens: Codable, Equatable {
        var accessToken: String
        var region: String
    }

    @Test func aPluginsFileMovesIntoTheVaultWhenRead() throws {
        let directory = storage()
        let legacy = directory.appendingPathComponent("plugins/cloud-home/tokens.json")
        try OwnerOnlyFile.write(Data(#"{"accessToken":"legacy-access-1","region":"eu"}"#.utf8), to: legacy)
        let file = SecretFile<Tokens>(vault: CredentialVault(storage: directory), entryName: "plugin.cloud-home.tokens.json", owner: "Cloud/Home", legacyFile: legacy)
        #expect(file.load() == Tokens(accessToken: "legacy-access-1", region: "eu"))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let entry = try #require(try file.vault.entry(named: file.entryName))
        #expect(entry.kind == .token && entry.owner == "Cloud/Home")
        #expect(try !String(contentsOf: file.vault.url, encoding: .utf8).contains("legacy-access-1"))
        // What it holds under secret-named keys is masked from now on; the rest is not.
        #expect(Redaction.redactText("sent legacy-access-1 to eu") == "sent \(Redaction.placeholder) to eu")

        try file.save(Tokens(accessToken: "fresh-access-2", region: "us"))
        #expect(file.load()?.accessToken == "fresh-access-2")
        // The vault wins over a file put back afterwards.
        try OwnerOnlyFile.write(Data(#"{"accessToken":"stale","region":"eu"}"#.utf8), to: legacy)
        #expect(file.load()?.accessToken == "fresh-access-2")
        file.remove()
        #expect(try file.vault.entry(named: file.entryName) == nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(file.load() == nil)
    }

    @Test func aFileThatDoesNotDecodeStaysWhereItIs() throws {
        let directory = storage()
        let legacy = directory.appendingPathComponent("tokens.json")
        try OwnerOnlyFile.write(Data("not json".utf8), to: legacy)
        let file = SecretFile<Tokens>(vault: CredentialVault(storage: directory), entryName: "plugin.x.tokens.json", owner: "X/X", legacyFile: legacy)
        #expect(file.load() == nil)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(try file.vault.names().isEmpty)
    }

    @Test func pluginEntryNamesAreValid() {
        #expect(SecretFile<Tokens>.entryName(instance: "daikincloud-home", file: ".daikin-mobile-tokenset") == "plugin.daikincloud-home.daikin-mobile-tokenset")
        #expect(SecretFile<Tokens>.entryName(instance: "lg", file: "persist keys/é") == "plugin.lg.persist-keys--")
        let long = SecretFile<Tokens>.entryName(instance: String(repeating: "a", count: 200), file: "tokens.json")
        #expect(long.count == CredentialVault.maximumNameLength && CredentialVault.isValidName(long))
        #expect(long != SecretFile<Tokens>.entryName(instance: String(repeating: "a", count: 201), file: "tokens.json"))
    }

    @Test func sealedValuesAreRememberedToo() throws {
        let directory = storage()
        let unique = "sealed-\(UUID().uuidString.prefix(8))"
        let sealed = try SecretBox.load(storage: directory, create: true).seal(unique)
        let opened = try ConfigurationSecrets.opening(configuration(#"{ "platform": "Govee", "name": "Govee", "password": "\#(sealed)" }"#), storage: directory)
        #expect(try JSONValue(data: opened.platforms[0].json)["password"]?.stringValue == unique)
        #expect(Redaction.redactText("value \(unique) seen") == "value \(Redaction.placeholder) seen")
    }
}
