import Foundation
import Homeswift
import HomeswiftAI
import Testing

@testable import HomeswiftPlugin

@Suite(.timeLimit(.minutes(1)))
struct ConfigImportTests {
    /// A registry with one plugin whose schema marks `password` as a secret and has no `extra` setting.
    static let registry: PluginRegistry = {
        var registry = PluginRegistry()
        registry.register(platform: "Govee", name: "Govee", configurationSchemaJSON: #"""
        { "properties": {
            "name": { "type": "string" },
            "username": { "type": "string" },
            "password": { "type": "string", "x-schema-form": { "type": "password" } },
            "lanRefreshTime": { "type": "integer" },
            "lightDevices": { "type": "array", "items": { "type": "object", "properties": {
                "deviceId": { "type": "string" },
                "label": { "type": "string" },
                "localKey": { "type": "string", "x-schema-form": { "type": "password" } }
            } } }
        } }
        """#) { _, _ in fatalError("not run") }
        return registry
    }()

    /// A sealer that marks its output, so tests see which values were sealed without a real key.
    static let sealer: @Sendable (String) throws -> String = { "sealed(\($0))" }

    func check(_ text: String, existing: JSONValue? = nil) throws -> HomebridgeImport.Result {
        try HomebridgeImport.check(Data(text.utf8), registry: Self.registry, existing: existing, seal: Self.sealer)
    }

    @Test func reportsTheLineAndColumnOfASyntaxError() throws {
        let result = try check("{\n  \"bridge\": {\n    \"name\": \"Homebridge\",\n  },\n  \"platforms\": []\n}")
        #expect(!result.report.valid)
        let syntax = try #require(result.report.syntax)
        #expect(syntax.line == 4)
        #expect(syntax.column == 3)
        #expect(result.additions == nil)
    }

    @Test func reportsAnEmptyFileAsUnexpectedEnd() throws {
        let result = try check("{ \"platforms\": [")
        #expect(result.report.syntax?.hint == "unexpectedEnd")
    }

    @Test func keepsSupportedPlatformsAndSealsTheirSecrets() throws {
        let text = #"""
        { "bridge": { "name": "Homebridge D679", "username": "0E:B1:ED:96:AE:38", "pin": "151-96-328", "port": 51513, "matter": { "port": 5530 } },
          "platforms": [ { "platform": "Govee", "name": "Govee", "username": "me@example.com", "password": "secret-1", "lanRefreshTime": 30,
                           "lightDevices": [ { "deviceId": "AB", "label": "Lamp", "localKey": "key-1" } ] } ] }
        """#
        let result = try check(text)
        #expect(result.report.valid)
        let additions = try #require(result.additions?.objectValue)
        let platform = try #require(additions["platforms"]?.arrayValue?.first?.objectValue)
        #expect(platform["platform"]?.stringValue == "Govee")
        #expect(platform["password"]?.stringValue == "sealed(secret-1)")
        #expect(platform["username"]?.stringValue == "me@example.com")
        let light = try #require(platform["lightDevices"]?.arrayValue?.first?.objectValue)
        #expect(light["localKey"]?.stringValue == "sealed(key-1)")

        let encrypted = result.report.items.filter { $0.outcome == .encrypted }.map(\.path)
        #expect(encrypted.contains("password"))
        #expect(encrypted.contains("lightDevices[0].localKey"))
        // A sealed value is never listed with its plain text.
        #expect(!result.report.items.contains { $0.value == "secret-1" || $0.value == "key-1" })
        let dropped = result.report.items.filter { $0.outcome == .dropped }
        #expect(dropped.contains { $0.path == "matter" && $0.note?.code == "notUsed" })
    }

    @Test func dropsPlatformsWithoutAPlugin() throws {
        let text = #"{ "platforms": [ { "platform": "Dyson Fan", "name": "Fan" }, { "platform": "config", "name": "Glass" } ] }"#
        let result = try check(text)
        let notes = result.report.items.compactMap(\.note?.code)
        #expect(notes == ["unsupportedPlatform", "webUI"])
        #expect(result.report.summary.platforms == 0)
        #expect(result.report.summary.dropped == 2)
    }

    @Test func dropsSettingsThePluginDoesNotDeclare() throws {
        let text = #"{ "platforms": [ { "platform": "Govee", "name": "Govee", "extra": true, "httpRefreshTime": 60 } ] }"#
        let result = try check(text)
        #expect(result.report.items.contains { $0.path == "extra" && $0.note?.code == "notSetting" })
        #expect(result.report.items.contains { $0.path == "httpRefreshTime" && $0.note?.code == "notSetting" })
        let platform = try #require(result.additions?["platforms"]?.arrayValue?.first?.objectValue)
        #expect(platform["extra"] == nil)
    }

    @Test func leavesOutANumericSecret() throws {
        let text = #"{ "platforms": [ { "platform": "Govee", "name": "Govee", "password": 1234 } ] }"#
        let result = try check(text)
        let platform = try #require(result.additions?["platforms"]?.arrayValue?.first?.objectValue)
        #expect(platform["password"] == nil)
        #expect(result.report.items.contains { $0.path == "password" && $0.outcome == .dropped && $0.note?.code == "numericSecret" })
    }

    @Test func sealsCredentialsInsideURLs() throws {
        let text = #"{ "platforms": [ { "platform": "Govee", "name": "Govee", "username": "rtsp://unifi:pw@192.168.2.100:8555/cam" } ] }"#
        let result = try check(text)
        let platform = try #require(result.additions?["platforms"]?.arrayValue?.first?.objectValue)
        #expect(platform["username"]?.stringValue == "sealed(rtsp://unifi:pw@192.168.2.100:8555/cam)")
    }

    @Test func pausesPlatformsDisabledInHomebridge() throws {
        let text = #"{ "platforms": [ { "platform": "Govee", "name": "Govee" } ], "disabledPlugins": ["homebridge-govee"] }"#
        let result = try check(text)
        let platform = try #require(result.additions?["platforms"]?.arrayValue?.first?.objectValue)
        #expect(platform["_paused"]?.boolValue == true)
        #expect(result.report.items.contains { $0.path == "_paused" && $0.note?.code == "paused" })
    }

    @Test func warnsWhenADisabledPluginMatchesNothing() throws {
        let result = try check(#"{ "disabledPlugins": ["homebridge-unifi-access"] }"#)
        #expect(result.report.warnings.contains { $0.code == "disabledMatchesNothing" })
    }

    @Test func refusesADuplicateOfAnExistingPlatform() throws {
        let existing = JSONValue.object(["platforms": .array([.object(["platform": .string("Govee"), "name": .string("Govee")])])])
        let result = try check(#"{ "platforms": [ { "platform": "Govee", "name": "Govee" } ] }"#, existing: existing)
        #expect(!result.report.valid)
        #expect(result.report.problems.contains { $0.code == "duplicatePlatform" })
        #expect(result.additions == nil)
    }

    @Test func keepsTheBridgeOnlyForAnEmptyConfig() throws {
        let bridge = #"{ "bridge": { "name": "Homebridge", "username": "0E:B1:ED:96:AE:38", "pin": "151-96-328" }, "platforms": [] }"#
        let empty = try check(bridge, existing: .object(["platforms": .array([])]))
        #expect(empty.additions?["bridge"] != nil)

        let populated = JSONValue.object(["platforms": .array([.object(["platform": .string("Govee"), "name": .string("Govee")])])])
        let kept = try check(bridge, existing: populated)
        #expect(kept.additions?["bridge"] == nil)
        #expect(kept.report.warnings.contains { $0.code == "bridgeKeptExisting" })
    }

    @Test func refusesABridgeIdentityTheRuntimeRejects() throws {
        let result = try check(#"{ "bridge": { "username": "not-an-id" } }"#)
        #expect(!result.report.valid)
        #expect(result.report.problems.contains { $0.code == "invalidConfig" })
    }

    @Test func mergeAppendsPlatformsAndKeepsTheRest() {
        let existing = JSONValue.object(["bridge": .object(["name": .string("Homeswift")]), "platforms": .array([.object(["platform": .string("A")])])])
        let additions = JSONValue.object(["platforms": .array([.object(["platform": .string("B")])])])
        let merged = HomebridgeImport.merge(existing, additions: additions).objectValue ?? [:]
        #expect(merged["platforms"]?.arrayValue?.count == 2)
        #expect(merged["bridge"]?["name"]?.stringValue == "Homeswift")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SecretBoxTests {
    func storage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-secrets-\(UUID().uuidString)")
    }

    @Test func sealsAndOpensWithTheSameKey() throws {
        let directory = storage()
        let box = try SecretBox.load(storage: directory, create: true)
        let sealed = try box.seal("hunter2")
        #expect(SecretBox.isSealed(sealed))
        #expect(!sealed.contains("hunter2"))
        #expect(try box.open(sealed) == "hunter2")
        // A new nonce each time: equal secrets seal to different text.
        #expect(try box.seal("hunter2") != sealed)
    }

    @Test func aDifferentKeyDoesNotOpen() throws {
        let box = try SecretBox.load(storage: storage(), create: true)
        let other = try SecretBox.load(storage: storage(), create: true)
        let sealed = try box.seal("token")
        #expect(throws: SecretBoxError.wrongKey) { try other.open(sealed) }
    }

    @Test func missingKeyFileIsAnErrorWhenNotCreating() {
        #expect(throws: SecretBoxError.self) { try SecretBox.load(storage: storage(), create: false) }
    }

    @Test func keyFileIsOwnerOnly() throws {
        let directory = storage()
        _ = try SecretBox.load(storage: directory, create: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(SecretBox.fileName).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func revealingOpensTheSealedSecretsOfTheConfiguration() throws {
        let box = try SecretBox.load(storage: storage(), create: true)
        let sealed = try box.seal("pw-1")
        let text = #"{ "bridge": { "name": "H" }, "platforms": [ { "platform": "Govee", "name": "Govee", "password": "\#(sealed)" } ] }"#
        let configuration = try HomeswiftConfiguration.decode(Data(text.utf8))
        let revealed = try box.revealing(configuration)
        let block = try JSONValue(data: revealed.platforms[0].json)
        #expect(block["password"]?.stringValue == "pw-1")
    }
}
