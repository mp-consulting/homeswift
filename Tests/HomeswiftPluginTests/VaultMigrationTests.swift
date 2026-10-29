import Foundation
import HomeswiftAI
import Testing

@testable import HomeswiftPlugin

@Suite(.timeLimit(.minutes(1)))
struct VaultMigrationTests {
    static let config: JSONValue = [
        "bridge": ["name": "H", "pin": "031-45-154"],
        "platforms": [
            ["platform": "UniFiProtect", "name": "Protect", "password": "unifi-pass-1", "username": "admin"],
            ["platform": "UniFiAccess", "name": "Access", "password": "unifi-pass-1"],
            ["platform": "Govee", "name": "Govee", "apiKey": "govee-key-2", "devices": [["label": "Desk Lamp", "token": 123456], ["token": "lan-key-3"]]],
            ["platform": "Hue", "name": "Upstairs", "token": "vault:hue-upstairs"],
            ["platform": "Hue", "name": "Downstairs", "token": "hue-token-4", "_bridge": ["username": "0E:00:00:00:00:01", "pin": "111-22-333"]],
            ["platform": "HomeswiftAiKit", "apiKey": "sk-ant-5", "mcp": ["http": ["token": "mcp-token-6"]]],
            ["platform": "HomeswiftUI", "secret": "ui-secret-7"],
        ],
    ]

    func plan(existing: [String: VaultEntry] = [:], names: [String: String] = [:], excluded: Set<String> = [], separate: Set<String> = []) throws -> VaultMigration {
        try VaultMigration.plan(stored: Self.config, opened: Self.config, existing: existing, choices: .init(names: names, excluded: excluded, separate: separate))
    }

    func entries(_ plan: VaultMigration) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.entry) })
    }

    @Test func findsTheSecretsOfThePluginBlocksAndTheAssistant() throws {
        let found = try entries(plan())
        #expect(found == [
            "UniFiProtect/Protect:password": "unifi-password",
            "UniFiAccess/Access:password": "unifi-password",
            "Govee/Govee:apiKey": "govee-apikey",
            "Govee/Govee:devices[0].token": "govee-devices-desk-lamp-token",
            "Govee/Govee:devices[1].token": "govee-devices-2-token",
            "Hue/Downstairs:token": "hue-downstairs-token",
            "HomeswiftAiKit/HomeswiftAiKit:apiKey": "homeswiftaikit-apikey",
        ])
    }

    @Test func identicalValuesShareAnEntry() throws {
        let plan = try plan()
        #expect(plan.newEntries.count == 6)
        #expect(plan.newEntries["unifi-password"]?.fields == ["value": "unifi-pass-1"])
        #expect(plan.items.filter(\.shared).map(\.id) == ["UniFiAccess/Access:password"])
        // A number under a secret's name is its text; kinds follow the key.
        #expect(plan.newEntries["govee-devices-desk-lamp-token"]?.fields == ["token": "123456"])
        #expect(plan.newEntries["govee-apikey"]?.kind == .apiKey)
        #expect(plan.newEntries["hue-downstairs-token"]?.kind == .token)
    }

    @Test func theConfigNamesTheEntriesAndKeepsTheRest() throws {
        let config = try plan().config
        let platforms = try #require(config["platforms"]?.arrayValue)
        #expect(platforms[0]["password"] == "vault:unifi-password")
        #expect(platforms[0]["username"] == "admin")
        #expect(platforms[1]["password"] == "vault:unifi-password")
        #expect(platforms[2]["devices"]?[0]?["token"] == "vault:govee-devices-desk-lamp-token")
        #expect(platforms[2]["devices"]?[0]?["label"] == "Desk Lamp")
        #expect(platforms[3]["token"] == "vault:hue-upstairs")
        // What the runtime reads before references resolve: a child bridge, the MCP tokens, the web UI's block, the bridge.
        #expect(platforms[4]["_bridge"]?["pin"] == "111-22-333")
        #expect(platforms[5]["mcp"]?["http"]?["token"] == "mcp-token-6")
        #expect(platforms[6]["secret"] == "ui-secret-7")
        #expect(config["bridge"]?["pin"] == "031-45-154")
        #expect(VaultMigration.isMigrated(config))
        #expect(!VaultMigration.isMigrated(["platforms": [["platform": "A", "token": "plain"]]]))
    }

    @Test func aValueTheVaultHasGoesToItsEntry() throws {
        let plan = try plan(existing: ["govee": VaultEntry(kind: .apiKey, fields: ["key": "govee-key-2"])])
        #expect(entries(plan)["Govee/Govee:apiKey"] == "govee")
        #expect(plan.newEntries["govee"] == nil)
        #expect(plan.items.first { $0.id == "Govee/Govee:apiKey" }?.shared == true)
    }

    @Test func namesExclusionsAndSeparateEntries() throws {
        let plan = try plan(
            names: ["UniFiProtect/Protect:password": "unifi-home"], excluded: ["Govee/Govee:apiKey"], separate: ["UniFiAccess/Access:password"])
        let found = entries(plan)
        #expect(found["UniFiProtect/Protect:password"] == "unifi-home")
        #expect(found["UniFiAccess/Access:password"] == "unifiaccess-password")
        #expect(plan.items.first { $0.id == "Govee/Govee:apiKey" }?.excluded == true)
        #expect(plan.config["platforms"]?[2]?["apiKey"] == "govee-key-2")
        #expect(plan.newEntries["unifi-home"] != nil && plan.newEntries["unifiaccess-password"] != nil)
    }

    @Test func aNameTakenByAnotherValueIsRefused() throws {
        #expect(throws: VaultMigrationError.nameTaken("taken")) {
            try plan(existing: ["taken": VaultEntry(kind: .secret, fields: ["value": "other"])], names: ["Hue/Downstairs:token": "taken"])
        }
        #expect(throws: CredentialVaultError.self) { try plan(names: ["Hue/Downstairs:token": "not a name"]) }
    }

    @Test func newNamesDoNotCollide() throws {
        let plan = try plan(existing: ["govee-apikey": VaultEntry(kind: .apiKey, fields: ["key": "another"])])
        #expect(entries(plan)["Govee/Govee:apiKey"] == "govee-apikey-2")
    }

    @Test func onlyPlainLeavesSealedValues() throws {
        let sealed = SecretBox.prefix + "abc"
        let stored: JSONValue = ["platforms": [["platform": "A", "password": .string(sealed), "token": "plain-token-8"]]]
        let opened: JSONValue = ["platforms": [["platform": "A", "password": "opened-pass", "token": "plain-token-8"]]]
        let plan = try VaultMigration.plan(stored: stored, opened: opened, existing: [:], onlyPlain: true)
        #expect(plan.items.map(\.id) == ["A/A:token"])
        #expect(plan.config["platforms"]?[0]?["password"]?.stringValue == sealed)
        let all = try VaultMigration.plan(stored: stored, opened: opened, existing: [:])
        #expect(all.newEntries.values.contains { $0.fields["value"] == "opened-pass" })
    }

    @Test func sharedNames() {
        #expect(VaultMigration.sharedName(["unifiprotect-password", "unifiaccess-password"]) == "unifi-password")
        #expect(VaultMigration.sharedName(["hue-password", "govee-password"]) == "password")
        #expect(VaultMigration.sharedName(["unifi-protect-password", "unifi-access-password"]) == "unifi-password")
        #expect(VaultMigration.sharedName(["hue-token", "govee-apikey"]) == "hue-token")
    }
}
