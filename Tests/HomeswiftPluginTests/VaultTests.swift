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
        let opened = try ConfigurationSecrets.opening(configuration, storage: directory, environment: ["UNIFI_KEY": "key-from-env", "HOMESWIFT_SECRET_FILES": directory.path])
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

    func failure(_ block: String, storage: URL, environment: [String: String] = [:]) -> String? {
        do {
            _ = try ConfigurationSecrets.opening(configuration(block), storage: storage, environment: environment)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func aPluginsEntryResolvesOnlyInItsOwnBlock() throws {
        let directory = storage()
        try CredentialVault(storage: directory).set("plugin.ewelink.tokens", VaultEntry(kind: .token, fields: ["token": "plugin-token-1"], owner: "eWeLink/Home"))
        #expect(failure(#"{ "platform": "eWeLink", "name": "Home", "token": "vault:plugin.ewelink.tokens" }"#, storage: directory) == nil)
        let other = failure(#"{ "platform": "UniFi", "name": "UniFi", "password": "vault:plugin.ewelink.tokens" }"#, storage: directory)
        #expect(other?.contains("the entry belongs to eWeLink/Home") == true)
    }

    @Test func filesResolveOnlyInTheFoldersListed() throws {
        let allowed = storage().appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try Data("in-folder-secret".utf8).write(to: allowed.appendingPathComponent("unifi"))
        let outside = storage()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside-secret".utf8).write(to: outside.appendingPathComponent("key"))
        // A link inside the folder to a file outside it is followed before the check.
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("key"))
        let environment = ["HOMESWIFT_SECRET_FILES": allowed.path]
        #expect(failure(#"{ "platform": "A", "name": "A", "password": "file:\#(allowed.path)/unifi" }"#, storage: storage(), environment: environment) == nil)
        for path in ["\(outside.path)/key", "\(allowed.path)/../../\(outside.lastPathComponent)/key", "\(allowed.path)/link", "\(allowed.path)"] {
            let message = failure(#"{ "platform": "A", "name": "A", "password": "file:\#(path)" }"#, storage: storage(), environment: environment)
            #expect(message?.contains("not in a folder HOMESWIFT_SECRET_FILES lists") == true, "\(path)")
        }
        // Without the variable, only Docker's folder.
        #expect(failure(#"{ "platform": "A", "name": "A", "password": "file:\#(allowed.path)/unifi" }"#, storage: storage())?.contains("(/run/secrets)") == true)
    }

    @Test func variablesResolveOnlyWhenListed() {
        let environment = ["UNIFI_PASSWORD": "env-secret-1", "HOME_TOKEN": "env-secret-2", "HOMESWIFT_SECRET_ENV": "UNIFI_PASSWORD, HOME_*"]
        #expect(failure(#"{ "platform": "A", "name": "A", "password": "env:UNIFI_PASSWORD", "token": "env:HOME_TOKEN" }"#, storage: storage(), environment: environment) == nil)
        let refused = failure(#"{ "platform": "A", "name": "A", "password": "env:AWS_SECRET" }"#, storage: storage(), environment: environment.merging(["AWS_SECRET": "x"]) { $1 })
        #expect(refused?.contains("HOMESWIFT_SECRET_ENV does not list the variable") == true)
        // Without the list, any variable.
        #expect(failure(#"{ "platform": "A", "name": "A", "password": "env:UNIFI_PASSWORD" }"#, storage: storage(), environment: ["UNIFI_PASSWORD": "y"]) == nil)
    }

    @Test func failuresCanBeToldWithoutTheirReasons() {
        let error = SecretReferenceError(failures: [.init(platform: "A", reference: .file("/etc/hosts"), reason: "the file cannot be read")])
        #expect(error.withoutReasons.description == "secrets cannot be resolved: A: file:/etc/hosts (does not resolve)")
    }

    @Test func newExternalReferencesAreThoseNotThereBefore() {
        let current: JSONValue = ["platforms": [["platform": "A", "name": "A", "password": "env:KEPT", "token": "vault:x"]]]
        let next: JSONValue = ["platforms": [
            ["platform": "A", "name": "A", "password": "env:KEPT", "token": "vault:y", "apiKey": "file:/run/secrets/new"],
            ["platform": "B", "name": "B", "password": "env:KEPT"],
        ]]
        #expect(ConfigurationSecrets.newExternalReferences(in: next, comparedWith: current) == ["A/A:apiKey", "B/B:password"])
    }

    @Test func sealingKeepsReferences() {
        let config: JSONValue = ["platforms": [["platform": "Govee", "password": "vault:govee", "token": "plain-token"]]]
        let sealed = SecretBox.sealingSecrets(config) { "sealed(\($0))" }
        #expect(sealed["platforms"]?[0]?["password"]?.stringValue == "vault:govee")
        #expect(sealed["platforms"]?[0]?["token"]?.stringValue == "sealed(plain-token)")
    }

    @Test func sealingLeavesTheWebUISignInMode() {
        let config: JSONValue = ["platforms": [["platform": "HomeswiftUI", "auth": "form"], ["platform": "X", "auth": "Bearer abcdef"]]]
        let sealed = SecretBox.sealingSecrets(config) { "sealed(\($0))" }
        #expect(sealed["platforms"]?[0]?["auth"]?.stringValue == "form")
        #expect(sealed["platforms"]?[1]?["auth"]?.stringValue == "sealed(Bearer abcdef)")
    }

    @Test func aSealedSignInModeOpens() throws {
        let box = try SecretBox.load(storage: storage(), create: true)
        let config: JSONValue = ["platforms": [["platform": "HomeswiftUI", "auth": .string(try box.seal("form"))], ["platform": "X", "auth": .string(try box.seal("Bearer abcdef"))]]]
        let opened = SecretBox.openingSignInModes(config, open: box.open)
        #expect(opened["platforms"]?[0]?["auth"]?.stringValue == "form")
        #expect(SecretBox.isSealed(opened["platforms"]?[1]?["auth"]?.stringValue ?? ""))
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

    @Test func resolvingAnEntryNotesWhenItWasUsedOnceAnHour() throws {
        let directory = storage()
        let vault = CredentialVault(storage: directory)
        try vault.set("unifi", VaultEntry(kind: .secret, fields: ["value": "pw-used-1"]))
        try vault.set("idle", VaultEntry(kind: .secret, fields: ["value": "pw-idle-2"]))
        _ = try ConfigurationSecrets.opening(configuration(#"{ "platform": "UniFi", "name": "UniFi", "password": "vault:unifi" }"#), storage: directory)
        let used = try #require(try vault.listing()["unifi"]?.used)
        #expect(abs(used.timeIntervalSinceNow) < 60)
        #expect(try vault.listing()["idle"]?.used == nil)

        // Within the hour nothing is written; after it, the new date.
        try vault.recordUse(["unifi"], now: used.addingTimeInterval(600))
        #expect(try vault.listing()["unifi"]?.used == used)
        let later = used.addingTimeInterval(CredentialVault.useResolution)
        try vault.recordUse(["unifi", "gone"], now: later)
        #expect(try vault.listing()["unifi"]?.used == later)
        // Replacing the value keeps it.
        try vault.update("unifi", kind: .secret, fields: ["value": "pw-new-3"])
        #expect(try vault.listing()["unifi"]?.used == later)
    }

    @Test func aPluginReadingItsTokenNotesTheUse() throws {
        let file = SecretFile<[String: String]>(vault: CredentialVault(storage: storage()), entryName: "plugin.home.tokens", owner: "eWeLink/Home")
        try file.save(["token": "plugin-token-4"])
        #expect(try file.vault.listing()["plugin.home.tokens"]?.used == nil)
        #expect(file.load() == ["token": "plugin-token-4"])
        #expect(try file.vault.listing()["plugin.home.tokens"]?.used != nil)
    }

    @Test func healthReportsWhatNeedsAttentionMostPressingFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let config: JSONValue = ["platforms": [
            ["platform": "UniFi", "name": "Home", "password": "vault:unifi", "apiKey": "vault:unifi#username", "token": "vault:gone"],
            ["platform": "Govee", "name": "Govee", "apiKey": "vault:govee", "token": "vault:plugin.home.tokens"],
            ["platform": "Hue", "name": "Hue", "token": "vault:hue"],
        ]]
        let entries: [String: VaultEntry] = [
            "unifi": VaultEntry(kind: .secret, fields: ["value": "x"], expires: now.addingTimeInterval(-day)),
            "govee": VaultEntry(kind: .apiKey, fields: ["key": "x"], expires: now.addingTimeInterval(10 * day)),
            "hue": VaultEntry(kind: .token, fields: ["token": "x"], expires: now.addingTimeInterval(90 * day)),
            "plugin.home.tokens": VaultEntry(kind: .token, fields: ["token": "x"], owner: "eWeLink/Home"),
        ]
        let health = VaultHealth.check(config: config, entries: entries, now: now)
        #expect(health.problems.map { "\($0.entry) \($0.state.rawValue)" } == [
            "gone missing", "plugin.home.tokens failing", "unifi failing", "unifi expired", "govee expiring",
        ])
        #expect(health.problems[0].usedBy == ["UniFi/Home:token"])
        #expect(health.problems[1].reason == "the entry belongs to eWeLink/Home")
        #expect(health.problems[2].usedBy == ["UniFi/Home:apiKey"])
        #expect(health.problems[2].reason == "the entry has no field username")
        #expect(health.problems[3].usedBy == ["UniFi/Home:apiKey", "UniFi/Home:password"])
        #expect(health.states == ["gone": .missing, "plugin.home.tokens": .failing, "unifi": .failing, "govee": .expiring])
        #expect(VaultHealth.check(config: ["platforms": []], entries: ["hue": entries["hue"]!], now: now).problems.isEmpty)
    }
}
