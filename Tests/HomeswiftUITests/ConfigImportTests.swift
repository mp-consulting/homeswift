import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftUI

// The import API end to end: a real server, a browser on loopback (text is accepted there without HTTPS).
@Suite(.timeLimit(.minutes(1)))
struct ConfigImportServerTests {
    /// A started environment and a browser signed in as its first account, an administrator.
    func signedIn(_ environment: UITestEnvironment) async throws -> Browser {
        let base = try await environment.start()
        let browser = Browser(base: base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        let code = try #require(environment.server.setupCode)
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": .string(code)]).status == 200)
        return browser
    }

    static let homebridge = #"""
    { "bridge": { "name": "Homebridge D679", "username": "0E:B1:ED:96:AE:38", "pin": "151-96-328", "port": 51513 },
      "platforms": [
        { "platform": "Lamps", "name": "Garden", "password": "plain-secret-7" },
        { "platform": "config", "name": "Glass UI" },
        { "platform": "Not Installed", "name": "Other" }
      ],
      "disabledPlugins": [] }
    """#

    @Test func checksPastedTextAndNeverEchoesASecret() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let admin = try await signedIn(environment)

        let answer = try await admin.post("/api/import/check", ["source": "paste", "text": .string(Self.homebridge)])
        #expect(answer.status == 200)
        #expect(answer.json?["valid"] == true)
        #expect(!answer.body.contains("plain-secret-7"))
        let items = answer.json?["items"]?.arrayValue ?? []
        #expect(items.contains { $0["path"]?.stringValue == "password" && $0["outcome"]?.stringValue == "encrypted" && $0["value"] == nil })
        #expect(items.contains { $0["group"]?.stringValue == "Glass UI" && $0["outcome"]?.stringValue == "dropped" })
        #expect(items.contains { $0["group"]?.stringValue == "Other" && $0["note"]?["code"]?.stringValue == "unsupportedPlatform" })
    }

    @Test func reportsASyntaxErrorWithItsPlace() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let admin = try await signedIn(environment)

        let answer = try await admin.post("/api/import/check", ["source": "paste", "text": "{\n  \"platforms\": [,\n]}"])
        #expect(answer.status == 200)
        #expect(answer.json?["valid"] == false)
        #expect(answer.json?["syntax"]?["line"] != nil)
    }

    @Test func savesWithSealedSecretsAndAKeyOnlyTheOwnerReads() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let admin = try await signedIn(environment)

        let saved = try await admin.post("/api/import/save", ["source": "paste", "text": .string(Self.homebridge)])
        #expect(saved.status == 200)
        #expect(saved.json?["saved"]?.intValue == 1)
        // The save applies at once: the imported block runs without a restart.
        #expect(environment.host.platforms.contains { $0.platform == "Lamps" && $0.name == "Garden" })
        #expect(saved.json?["backup"]?.stringValue?.hasPrefix("config-") == true)

        let stored = try String(contentsOf: environment.configURL, encoding: .utf8)
        #expect(stored.contains(SecretBox.prefix))
        #expect(!stored.contains("plain-secret-7"))
        let keyURL = environment.directory.appendingPathComponent(SecretBox.fileName)
        let mode = try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        // The runtime reads the plain value back.
        let revealed = try SecretBox.revealing(HomeswiftConfiguration.load(from: environment.configURL), storage: environment.directory)
        let block = try JSONValue(data: revealed.platforms.first { $0.name == "Garden" }?.json ?? Data())
        #expect(block["password"]?.stringValue == "plain-secret-7")
    }

    @Test func refusesASecondSaveOfTheSameBlock() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let admin = try await signedIn(environment)

        #expect(try await admin.post("/api/import/save", ["source": "paste", "text": .string(Self.homebridge)]).status == 200)
        let again = try await admin.post("/api/import/save", ["source": "paste", "text": .string(Self.homebridge)])
        #expect(again.status == 422)
        #expect(again.json?["problems"]?.arrayValue?.contains { $0["code"]?.stringValue == "duplicatePlatform" } == true)
    }

    @Test func browsesOnlyTheStorageFolder() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let admin = try await signedIn(environment)

        let listing = try await admin.get("/api/import/browse?path=")
        #expect(listing.status == 200)
        let names = (listing.json?["entries"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names.contains("config.json"))
        #expect(!names.contains(SecretBox.fileName))
        #expect(!names.contains("homeswift.json"))

        #expect(try await admin.get("/api/import/browse?path=..").status == 400)
        #expect(try await admin.get("/api/import/browse?path=%2Fetc").status == 400)
    }

    @Test func readsAServerFileOnlyFromInsideTheStorageFolder() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let admin = try await signedIn(environment)

        let inside = try await admin.post("/api/import/check", ["source": "server", "path": "config.json"])
        #expect(inside.status == 200)
        // The bridge's own state (its signing key) is never read as a config.
        #expect(try await admin.post("/api/import/check", ["source": "server", "path": "homeswift.json"]).status == 400)
        #expect(try await admin.post("/api/import/check", ["source": "server", "path": "../../etc/hosts"]).status == 400)
        #expect(try await admin.post("/api/import/check", ["source": "server", "path": "/etc/passwd"]).status == 400)
    }

    @Test func auditKeepsOnlyTheSizeOfAPastedConfig() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let admin = try await signedIn(environment)

        let text = #"{ "platforms": [ { "platform": "Govee", "name": "Govee", "password": "audit-canary-7" } ] }"#
        _ = try await admin.post("/api/import/check", ["source": "paste", "text": .string(text)])

        // The audit entry is written in the background: wait for it, then read the log.
        var log = ""
        for _ in 0..<50 {
            log = (try? String(contentsOf: environment.directory.appendingPathComponent("homeswift-mcp-audit.jsonl"), encoding: .utf8)) ?? ""
            if log.contains("import/check") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(log.contains("import/check"))
        #expect(!log.contains("audit-canary-7"))
    }

    @Test func refusesAnAnonymousImport() async throws {
        let environment = try UITestEnvironment()
        defer { Task { await environment.stop() } }
        let base = try await environment.start()
        let browser = Browser(base: base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        #expect(try await browser.post("/api/import/check", ["source": "paste", "text": "{}"]).status == 401)
    }
}

@Suite struct ConfigImportStorageTests {
    @Test func resolvesOnlyPathsInsideTheFolder() throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        #expect(try UIServer.storageURL("a/b.json", storage: storage).lastPathComponent == "b.json")
        #expect(throws: ImportRouteError.self) { try UIServer.storageURL("../x", storage: storage) }
        #expect(throws: ImportRouteError.self) { try UIServer.storageURL("a\0b", storage: storage) }
        #expect(throws: ImportRouteError.self) { try UIServer.storageURL("/abs", storage: storage) }
    }
}
