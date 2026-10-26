import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging
import Testing

@testable import HomeswiftMCP

private let accept: JSONValue = ["action": "accept", "content": ["confirm": true]]

@Suite struct TarTests {
    @Test func readsBackWhatItWrites() throws {
        let long = "storage/plugins/" + String(repeating: "a", count: 90) + "/" + String(repeating: "b", count: 60) + ".json"
        let longer = "storage/" + Array(repeating: String(repeating: "c", count: 40), count: 8).joined(separator: "/") + "/file.json"
        var writer = Tar.Writer()
        try writer.append(Tar.Entry(path: "info.json", data: Data("{}".utf8)))
        try writer.append(Tar.Entry(path: "storage", kind: .directory))
        try writer.append(Tar.Entry(path: "storage/empty.json", data: Data()))
        try writer.append(Tar.Entry(path: long, data: Data(repeating: 7, count: 1000)))
        try writer.append(Tar.Entry(path: longer, data: Data("x".utf8)))
        let entries = try Tar.read(writer.data)
        #expect(entries.map(\.path) == ["info.json", "storage", "storage/empty.json", long, longer])
        #expect(entries[1].kind == .directory)
        #expect(entries[3].data == Data(repeating: 7, count: 1000))
        #expect(entries[4].data == Data("x".utf8))
        #expect(writer.data.count % 512 == 0)
    }

    @Test func refusesWhatCouldLeaveTheDirectory() throws {
        for path in ["../escape.json", "storage/../../escape.json", "/etc/passwd", "storage//x", "storage/./x"] {
            var writer = Tar.Writer()
            try writer.append(Tar.Entry(path: path, data: Data("x".utf8)))
            #expect(throws: Tar.FormatError.self, "\(path)") { try Tar.read(writer.data) }
        }
        // A symbolic link, written by hand: type 2.
        var header = [UInt8](repeating: 0, count: 512)
        for (index, byte) in "storage/link".utf8.enumerated() { header[index] = byte }
        for (index, byte) in "0000644\0".utf8.enumerated() { header[100 + index] = byte }
        for (index, byte) in "00000000000\0".utf8.enumerated() { header[124 + index] = byte }
        header[156] = UInt8(ascii: "2")
        for (index, byte) in "/etc".utf8.enumerated() { header[157 + index] = byte }
        for index in 148..<156 { header[index] = 32 }
        let sum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
        for (index, byte) in (String(repeating: "0", count: 6 - sum.count) + sum + "\0 ").utf8.enumerated() { header[148 + index] = byte }
        #expect(throws: Tar.FormatError.self) { try Tar.read(Data(header + [UInt8](repeating: 0, count: 1024))) }
        // Not tar at all.
        #expect(throws: Tar.FormatError.self) { try Tar.read(Data(repeating: 65, count: 2048)) }
    }

    /// A GNU base-256 size of Int.max is refused, not added to the offset (which trapped).
    @Test func refusesASizePastTheEnd() throws {
        var header = [UInt8](repeating: 0, count: 512)
        for (index, byte) in "storage/huge".utf8.enumerated() { header[index] = byte }
        for (index, byte) in "0000644\0".utf8.enumerated() { header[100 + index] = byte }
        header[124] = 0x80
        header[128] = 0x7f
        for index in 129..<136 { header[index] = 0xff }
        header[156] = UInt8(ascii: "0")
        for index in 148..<156 { header[index] = 32 }
        let sum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
        for (index, byte) in (String(repeating: "0", count: 6 - sum.count) + sum + "\0 ").utf8.enumerated() { header[148 + index] = byte }
        #expect(throws: Tar.FormatError.self) { try Tar.read(Data(header + [UInt8](repeating: 0, count: 1024))) }
    }
}

@Suite struct InstanceBackupTests {
    let storage = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-backup-tests-\(UUID().uuidString)")

    func populate() throws {
        let config = """
            { "bridge": { "name": "Old", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 51000 },
              "platforms": [ { "platform": "HomeswiftUI", "port": 9000 }, { "platform": "Devices", "name": "Devices" } ] }
            """
        try OwnerOnlyFile.write(Data(config.utf8), to: storage.appendingPathComponent("config.json"))
        try OwnerOnlyFile.write(Data("{\"pairings\":1}".utf8), to: storage.appendingPathComponent("homeswift.json"))
        try OwnerOnlyFile.write(Data("[]".utf8), to: storage.appendingPathComponent("accessories/Devices-Devices.json"))
        try OwnerOnlyFile.write(Data("plugin".utf8), to: storage.appendingPathComponent("plugins/Devices-Devices/state.json"))
        try OwnerOnlyFile.write(Data("line".utf8), to: storage.appendingPathComponent("logs/homeswift-1.jsonl"))
        try OwnerOnlyFile.write(Data("{}".utf8), to: storage.appendingPathComponent("metrics/day.json"))
        try OwnerOnlyFile.write(Data("{}".utf8), to: storage.appendingPathComponent("ui-sessions.json"))
        try OwnerOnlyFile.write(Data("{}".utf8), to: storage.appendingPathComponent("ui-users.json"))
        try OwnerOnlyFile.write(Data(repeating: 0, count: InstanceBackups.maxFileSize + 1), to: storage.appendingPathComponent("plugins/huge.bin"))
        #if !os(Windows)
        try FileManager.default.createSymbolicLink(atPath: storage.appendingPathComponent("link.json").path, withDestinationPath: "/etc/hosts")
        #endif
    }

    @Test func archivesTheStateAndLeavesOutTheRest() throws {
        try populate()
        defer { try? FileManager.default.removeItem(at: storage) }
        let backups = InstanceBackups(storage: storage, instanceID: "0E:11:22:33:44:55", logger: testLogger)
        let (data, skipped) = try backups.makeArchive(info: ["bridge": "Old"])
        let paths = Set(try Tar.read(data).filter { $0.kind == .file }.map(\.path))
        #expect(paths.isSuperset(of: ["info.json", "storage/config.json", "storage/homeswift.json", "storage/accessories/Devices-Devices.json", "storage/plugins/Devices-Devices/state.json", "storage/ui-users.json"]))
        #expect(!paths.contains { $0.contains("logs/") || $0.contains("metrics/") || $0.contains("ui-sessions") || $0.contains("link.json") || $0.contains("huge.bin") })
        #expect(skipped == ["plugins/huge.bin"])

        // Kept in the folder, listed, pruned and deleted by id.
        let made = try backups.create(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(made.fileName == "homeswift-backup-0E1122334455.1700000000000.tar")
        #expect(backups.folder.lastPathComponent == "instance-backups")
        let recent = try backups.create()
        #expect(try backups.list().map(\.id) == [recent.id, made.id])
        // The folder itself is not in the next archive.
        #expect(try Tar.read(try backups.makeArchive().data).allSatisfy { !$0.path.contains("instance-backups") })
        #expect(backups.prune(keepingDays: 7) == [made.fileName])
        #expect(throws: InstanceBackups.BackupError.self) { try backups.backup(id: "../../config") }
        try backups.delete(id: recent.id)
        #expect(try backups.list().isEmpty)
    }

    @Test func stagesARestoreAndAppliesItAtStart() throws {
        try populate()
        defer { try? FileManager.default.removeItem(at: storage) }
        let backups = InstanceBackups(storage: storage, instanceID: "0E:11:22:33:44:55", logger: testLogger)
        let archive = try backups.makeArchive().data

        // This machine moved on: another port, another UI port, a pairing that is not in the backup.
        let now = """
            { "bridge": { "name": "New", "username": "0E:11:22:33:44:55", "port": 52000 }, "platforms": [ { "platform": "HomeswiftUI", "port": 8581 } ] }
            """
        try OwnerOnlyFile.write(Data(now.utf8), to: storage.appendingPathComponent("config.json"))
        try OwnerOnlyFile.write(Data("{\"pairings\":2}".utf8), to: storage.appendingPathComponent("homeswift.json"))
        try OwnerOnlyFile.write(Data("new".utf8), to: storage.appendingPathComponent("accessories/Other.json"))

        let staged = try backups.stageRestore(archive)
        #expect(staged.bridge == "Old")
        #expect(staged.files >= 5)
        #expect(backups.hasPendingRestore)
        // Nothing changed yet: the running bridge keeps its files until the next start.
        #expect(try String(contentsOf: storage.appendingPathComponent("homeswift.json"), encoding: .utf8) == "{\"pairings\":2}")

        #expect(InstanceBackups.applyPendingRestore(storage: storage, logger: testLogger) != nil)
        #expect(!backups.hasPendingRestore)
        #expect(try String(contentsOf: storage.appendingPathComponent("homeswift.json"), encoding: .utf8) == "{\"pairings\":1}")
        #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent("accessories/Other.json").path))
        let config = try JSONValue(data: Data(contentsOf: storage.appendingPathComponent("config.json")))
        #expect(config["bridge"]?["name"] == "Old")
        #expect(config["bridge"]?["port"] == 52000)
        #expect(config["platforms"]?[0]?["port"] == 8581)
        #expect(config["platforms"]?.arrayValue?.count == 2)
        // Applied once.
        #expect(InstanceBackups.applyPendingRestore(storage: storage, logger: testLogger) == nil)
    }

    @Test func refusesArchivesItCannotTrust() throws {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let backups = InstanceBackups(storage: storage, instanceID: "x", logger: testLogger)
        func archive(_ entries: [Tar.Entry]) throws -> Data {
            var writer = Tar.Writer()
            for entry in entries { try writer.append(entry) }
            return writer.data
        }
        let info = Tar.Entry(path: "info.json", data: Data(#"{"format":"homeswift-backup"}"#.utf8))
        let config = Tar.Entry(path: "storage/config.json", data: Data(#"{"bridge":{"name":"B"},"platforms":[]}"#.utf8))
        // No info.json, a config.json that cannot run, a path that climbs out, not tar.
        #expect(throws: InstanceBackups.BackupError.self) { try backups.stageRestore(try archive([config])) }
        #expect(throws: InstanceBackups.BackupError.self) {
            try backups.stageRestore(try archive([info, Tar.Entry(path: "storage/config.json", data: Data(#"{"bridge":{"pin":"123"}}"#.utf8))]))
        }
        #expect(throws: InstanceBackups.BackupError.self) { try backups.stageRestore(try archive([info, config, Tar.Entry(path: "storage/../../evil", data: Data("x".utf8))])) }
        #expect(throws: InstanceBackups.BackupError.self) { try backups.stageRestore(Data("not an archive".utf8)) }
        #expect(!backups.hasPendingRestore)
        // Excluded names are skipped, the rest staged.
        let staged = try backups.stageRestore(try archive([info, config, Tar.Entry(path: "storage/ui-sessions.json", data: Data("{}".utf8)), Tar.Entry(path: "storage/node_modules/x.js", data: Data())]))
        #expect(staged.files == 1)
        #expect(staged.skipped == ["node_modules", "ui-sessions.json"])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AdminToolTests {
    @Test func backsUpListsAndAudits() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()

        #expect(try await client.tool("list_backups")["structuredContent"]?["backups"] == [])
        let created = try await client.tool("create_backup")
        #expect(created["isError"] == nil)
        let listed = try await client.tool("list_backups")["structuredContent"]?["backups"]?.arrayValue ?? []
        #expect(listed.count == 1)
        #expect(listed.first?["id"]?.stringValue?.hasPrefix("0E1122334455.") == true)

        // A read-only token cannot make one.
        let reader = DirectClient(server: environment.server, scope: .read)
        try await reader.initialize()
        #expect(try await reader.tool("create_backup")["isError"] == true)
        #expect(try await reader.tool("get_audit_log")["isError"] == true)

        // The bridge block: asked first, previewed, applied.
        let preview = try await client.tool("update_bridge_settings", ["settings": ["name": "Renamed"], "dryRun": true])
        #expect(preview["structuredContent"]?["changes"] == ["bridge.name"])
        let refused = try await client.tool("update_bridge_settings", ["settings": ["username": "0E:00:00:00:00:01"]])
        #expect(refused["isError"] == true)
        let renamed = try await client.tool("update_bridge_settings", ["settings": ["name": "Renamed"]], answer: accept)
        #expect(renamed["isError"] == nil)
        #expect(try environment.catalog.readConfig()["bridge"]?["name"] == "Renamed")
        #expect(try environment.catalog.readConfig()["bridge"]?["pin"] == "031-45-154")

        #expect(environment.auditEntries.contains { $0["tool"] == "create_backup" && $0["ok"] == true })
    }

    @Test func readsTheAuditLogWithFilters() throws {
        let environment = try MCPTestEnvironment()
        let log = try #require(environment.catalog.auditLog())
        let entry = { (tool: String, ok: Bool, client: String, notConfirmed: Bool) in
            AuditLog.Entry(tool: tool, arguments: ["password": "hunter2"], ok: ok, session: "s", client: client, principal: "p", scope: .admin, notConfirmed: notConfirmed)
        }
        log.record(entry("update_config", true, "Claude", false))
        log.record(entry("reset_pairings", false, "Cursor", true))
        log.record(entry("PUT /api/config", true, "web UI", false))
        let all = environment.catalog.auditEntriesJSON(.init())
        #expect(all["total"] == 3)
        // Newest first, secrets masked when written.
        #expect(all["entries"]?[0]?["tool"] == "PUT /api/config")
        #expect(all["entries"]?[0]?["args"]?["password"] != "hunter2")
        #expect(environment.catalog.auditEntriesJSON(.init(client: "web"))["total"] == 1)
        #expect(environment.catalog.auditEntriesJSON(.init(outcome: "notConfirmed"))["entries"]?[0]?["tool"] == "reset_pairings")
        #expect(environment.catalog.auditEntriesJSON(.init(outcome: "failed"))["total"] == 0)
        #expect(environment.catalog.auditEntriesJSON(.init(tool: "config"))["total"] == 2)
        #expect(environment.catalog.auditEntriesJSON(.init(since: Date().addingTimeInterval(60)))["total"] == 0)

        // With spans, each outcome and each range is counted against the other filters, in the same answer.
        var query = HomeswiftCatalog.AuditQuery(client: "c", outcome: "ok")
        query.spans = [("24h", Date().addingTimeInterval(-86400)), ("future", Date().addingTimeInterval(60)), ("", nil)]
        let counted = environment.catalog.auditEntriesJSON(query)
        #expect(counted["total"] == 1)
        #expect(counted["counts"]?["outcome"] == ["": 2, "ok": 1, "failed": 0, "notConfirmed": 1])
        #expect(counted["counts"]?["since"] == ["24h": 1, "future": 0, "": 1])
        #expect(environment.catalog.auditEntriesJSON(.init())["counts"] == nil)
    }

    @Test func listsAndRestoresConfigBackups() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        _ = try await environment.catalog.editBlock(platform: "Devices", name: "Devices", dryRun: false) { $0["token"] = "second" }
        let backups = environment.catalog.configBackupsJSON()["backups"]?.arrayValue ?? []
        #expect(backups.count == 1)
        let name = try #require(backups.first?["name"]?.stringValue)
        #expect(backups.first?["date"]?.stringValue != nil)
        #expect(try environment.catalog.configBackupText(named: name).contains("secret-token"))
        #expect(throws: CatalogError.self) { try environment.catalog.configBackupText(named: "../config.json") }
        _ = try await environment.catalog.restoreConfigBackup(name)
        #expect(try environment.catalog.readConfig()["platforms"]?[0]?["token"] == "secret-token")
    }

    @Test func turningTheMCPServerOnMakesItsToken() throws {
        let environment = try MCPTestEnvironment(config: """
            {
              "bridge": { "name": "Test Bridge", "username": "0E:11:22:33:44:55", "pin": "031-45-154", "port": 0 },
              "platforms": [
                { "platform": "Devices", "name": "Devices" },
                { "platform": "HomeswiftAiKit", "mcp": { "http": { "enabled": true, "port": 18583 } } }
              ]
            }
            """)
        let updated = try #require(try environment.catalog.addMissingMCPToken())
        let token = try #require(try environment.catalog.readConfig()["platforms"]?[1]?["mcp"]?["http"]?["token"]?.stringValue)
        #expect(!token.isEmpty)
        #expect(try MCPConfiguration(block: try #require(try updated.block(for: AIConfiguration.platform))).token == token)
        #expect(try environment.catalog.readConfig()["platforms"]?[1]?["mcp"]?["http"]?["port"] == 18583)
        #expect(environment.catalog.configBackupsJSON()["backups"]?.arrayValue?.count == 1)
        // Once it has one, and with the server off, nothing changes.
        #expect(try environment.catalog.addMissingMCPToken() == nil)
        #expect(try MCPTestEnvironment().catalog.addMissingMCPToken() == nil)
    }
}
