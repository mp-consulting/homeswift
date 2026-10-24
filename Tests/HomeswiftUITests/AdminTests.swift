import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import HomeswiftUI

@Suite struct ScheduleSettingsTests {
    @Test func readsCronExpressions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        let mondays = try CronSchedule("0 4 * * 1")
        // 2026-10-23 is a Friday.
        #expect(mondays.next(after: date("2026-10-23T10:00:00Z"), calendar: calendar) == date("2026-10-26T04:00:00Z"))
        #expect(try CronSchedule("*/15 * * * *").next(after: date("2026-10-23T10:07:30Z"), calendar: calendar) == date("2026-10-23T10:15:00Z"))
        #expect(try CronSchedule("30 2 1 JAN *").next(after: date("2026-10-23T10:00:00Z"), calendar: calendar) == date("2027-01-01T02:30:00Z"))
        // Both day fields: either one.
        #expect(try CronSchedule("0 0 1 * SUN").next(after: date("2026-10-23T10:00:00Z"), calendar: calendar) == date("2026-10-25T00:00:00Z"))
        // Sunday as 7, a range with a step.
        #expect(try CronSchedule("0 22 * * 7").next(after: date("2026-10-23T10:00:00Z"), calendar: calendar) == date("2026-10-25T22:00:00Z"))
        #expect(try CronSchedule("0-30/10 9 * * *").next(after: date("2026-10-23T09:20:00Z"), calendar: calendar) == date("2026-10-23T09:30:00Z"))
        for bad in ["", "0 4 * *", "61 * * * *", "* 24 * * *", "* * 0 * *", "*/0 * * * *", "5-1 * * * *", "0 4 * * FUNDAY"] {
            #expect(throws: CronSchedule.ParseError.self, "\(bad)") { try CronSchedule(bad) }
        }
    }

    /// Clock changes: the hour that repeats in autumn is passed once, not forever, and the one skipped in spring is skipped.
    @Test func readsCronExpressionsAcrossClockChanges() throws {
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        var dublin = Calendar(identifier: .gregorian)
        dublin.timeZone = TimeZone(identifier: "Europe/Dublin")!
        // 2026-10-25 02:00 IST is 01:00 GMT: 01:00 to 02:00 happens twice.
        #expect(try CronSchedule("30 4 * * *").next(after: date("2026-10-24T06:41:00Z"), calendar: dublin) == date("2026-10-25T04:30:00Z"))
        #expect(try CronSchedule("15 1 * * *").next(after: date("2026-10-24T06:41:00Z"), calendar: dublin) == date("2026-10-25T00:15:00Z"))
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        // 2026-10-25 03:00 CEST is 02:00 CET.
        #expect(try CronSchedule("0 4 * * *").next(after: date("2026-10-24T10:00:00Z"), calendar: paris) == date("2026-10-25T03:00:00Z"))
        // 2027-03-28 02:00 CET is 03:00 CEST: 02:30 does not exist that day.
        #expect(try CronSchedule("0 4 * * *").next(after: date("2027-03-27T12:00:00Z"), calendar: paris) == date("2027-03-28T02:00:00Z"))
        #expect(try CronSchedule("30 2 * * *").next(after: date("2027-03-27T12:00:00Z"), calendar: paris) == date("2027-03-29T00:30:00Z"))
    }

    @Test func trustsOnlyTheProxiesNamed() throws {
        let proxies = try TrustedProxies(["127.0.0.1", "10.0.0.0/8", "fd00::/8", "192.168.1.0/255.255.255.0"])
        #expect(proxies.trusts("127.0.0.1"))
        #expect(proxies.trusts("::ffff:10.1.2.3"))
        #expect(proxies.trusts("fd12::1"))
        #expect(proxies.trusts("192.168.1.77"))
        #expect(!proxies.trusts("192.168.2.1"))
        #expect(!proxies.trusts("8.8.8.8"))
        // The right-most address that is not a proxy; from anyone else, the header counts for nothing.
        #expect(proxies.client(remote: "127.0.0.1", forwardedFor: "1.2.3.4, 203.0.113.9, 10.0.0.2") == "203.0.113.9")
        #expect(proxies.client(remote: "8.8.8.8", forwardedFor: "1.2.3.4") == "8.8.8.8")
        #expect(proxies.client(remote: "127.0.0.1", forwardedFor: "not an address") == "127.0.0.1")
        #expect(proxies.forwardedHTTPS(remote: "10.9.9.9", proto: "https"))
        #expect(!proxies.forwardedHTTPS(remote: "8.8.8.8", proto: "https"))
        #expect(try TrustedProxies(["loopback"]).trusts("::1"))
        #expect(try TrustedProxies(["uniquelocal"]).trusts("172.20.0.1"))
        for bad in [["true"], ["*"], ["10.0.0.0/33"], ["fe80::1%en0"], ["example.com"]] {
            #expect(throws: UIConfigurationError.self, "\(bad)") { try TrustedProxies(bad) }
        }
    }

    @Test func readsTheBlocksNewSettings() throws {
        let configuration = try UIConfiguration(block: [
            "platform": "HomeswiftUI", "trustProxy": "127.0.0.1, 10.0.0.0/8", "scheduledRestartCron": "0 4 * * 1",
            "scheduledBackupDisable": true, "scheduledBackupPath": " /Volumes/Backups ", "scheduledBackupDays": 14,
        ])
        #expect(configuration.trustProxy.entries == ["127.0.0.1", "10.0.0.0/8"])
        #expect(configuration.scheduledRestart?.expression == "0 4 * * 1")
        #expect(configuration.scheduledBackupDisable)
        #expect(configuration.scheduledBackupPath == "/Volumes/Backups")
        #expect(configuration.scheduledBackupDays == 14)
        #expect(UIConfiguration().trustProxy.isEmpty)
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["scheduledRestartCron": "every day"]) }
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["trustProxy": true]) }
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["scheduledBackupDays": 0]) }
        // The schema the Settings form is built from has them.
        let schema = try JSONValue(string: UIConfiguration.schemaJSON)
        for key in ["trustProxy", "scheduledRestartCron", "scheduledBackupDisable", "scheduledBackupPath", "scheduledBackupDays"] {
            #expect(schema["schema"]?["properties"]?[key] != nil, "\(key)")
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AdminPageTests {
    @Test func administersTheBridge() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        // The bridge block and the network.
        let settings = try #require(try await browser.get("/api/settings/bridge").json)
        #expect(settings["bridge"]?["name"] == "UI Bridge")
        #expect(settings["deviceId"] == "0E:11:22:33:44:66")
        #expect(settings["advertiser"]?.stringValue != nil)
        #expect(try await browser.put("/api/settings/bridge", ["settings": ["username": "0E:00:00:00:00:01"]]).status == 400)
        let renamed = try await browser.put("/api/settings/bridge", ["settings": ["name": "Renamed", "port": .null]])
        #expect(renamed.status == 200)
        #expect(try environment.server.catalog.readConfig()["bridge"]?["name"] == "Renamed")
        #expect(try environment.server.catalog.readConfig()["bridge"]?["port"] == nil)
        #expect(try environment.server.catalog.readConfig()["bridge"]?["pin"] == "031-45-154")

        // Pairings and caches: the destructive ones need confirm.
        #expect(try await browser.get("/api/pairings").json?["bridges"]?[0]?["kind"] == "main")
        #expect(try await browser.post("/api/pairings/reset", [:]).status == 400)
        #expect(try await browser.post("/api/pairings/reset", ["confirm": true]).json?["paired"] == false)
        let cached = try await browser.get("/api/cached-accessories").json?["accessories"]?.arrayValue ?? []
        #expect(cached.contains { $0["id"] == "Lamps:lamp" })
        #expect(try await browser.post("/api/cached-accessories/reset", [:]).status == 400)
        #expect(try await browser.get("/api/child-bridges").json?["childBridges"] == [])
        #expect(try await browser.post("/api/child-bridges/0E:00:00:00:00:09/nap", [:]).status == 404)

        // History: an accessory without one says so.
        let history = try await browser.get("/api/accessories/Lamps:lamp/history?hours=24").json
        #expect(history?["series"] == [])
        #expect(history?["note"]?.stringValue != nil)
        #expect(try await browser.get("/api/accessories/nope/history").status == 404)

        // The audit log has the UI's own changes, as client "web UI".
        let audit = try #require(try await browser.get("/api/audit?client=web").json)
        #expect(audit["enabled"] == true)
        let tools = audit["entries"]?.arrayValue?.compactMap { $0["tool"]?.stringValue } ?? []
        #expect(tools.contains("POST /api/pairings/reset"))
        #expect(tools.contains("PUT /api/settings/bridge"))
        #expect(audit["entries"]?.arrayValue?.contains { $0["tool"] == "POST /api/pairings/reset" && $0["ok"] == false } == true)
        #expect(try await browser.get("/api/audit?outcome=ok&tool=pairings").json?["total"] == 1)
    }

    @Test func backsUpAndRestores() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        let empty = try #require(try await browser.get("/api/backups").json)
        #expect(empty["backups"] == [])
        #expect(empty["scheduled"] == true)
        #expect(empty["pendingRestore"] == false)
        let created = try await browser.post("/api/backups", [:])
        #expect(created.status == 201)
        let id = try #require(created.json?["backup"]?["id"]?.stringValue)
        #expect(try await browser.get("/api/backups").json?["backups"]?.arrayValue?.count == 1)

        // Downloads, kept or fresh: tar, as an attachment.
        let download = try await browser.get("/api/backups/download")
        #expect(download.status == 200)
        #expect(download.headers["content-type"] == "application/x-tar")
        #expect(download.headers["content-disposition"]?.contains("homeswift-backup-0E1122334466.") == true)
        let kept = try await browser.get("/api/backups/\(id)/download")
        #expect(kept.status == 200)
        #expect(try await browser.get("/api/backups/..%2Fconfig/download").status == 400)

        // A restore takes the archive itself; JSON and junk are refused.
        let archive = try Data(contentsOf: environment.server.catalog.instanceBackups.backup(id: id).url)
        browser.contentType = "text/plain"
        #expect(try await browser.send("POST", "/api/backups/restore", body: "x").status == 415)
        browser.contentType = "application/json"
        #expect(try await upload(Data("not a backup".utf8), base: base).status == 400)
        let restored = try await upload(archive, base: base)
        #expect(restored.status == 200)
        let answer = try JSONValue(data: restored.body)
        #expect(answer["staged"] == true)
        #expect(answer["restarting"] == true)
        #expect(await eventually { environment.restarts.withLockedValue { $0 } == 1 })
        #expect(try await browser.get("/api/backups").json?["pendingRestore"] == true)
        environment.server.catalog.instanceBackups.cancelPendingRestore()

        // config.json's backups: listed, read, restored.
        #expect(try await browser.put("/api/settings/bridge", ["settings": ["model": "M2"]]).status == 200)
        let configBackups = try await browser.get("/api/config/backups").json?["backups"]?.arrayValue ?? []
        let name = try #require(configBackups.first?["name"]?.stringValue)
        #expect(try await browser.get("/api/config/backups/\(name)").body.contains("UI Bridge"))
        #expect(try await browser.get("/api/config/backups/nope.json").status == 400)
        #expect(try await browser.post("/api/config/backups/\(name)/restore", [:]).status == 200)
        #expect(try environment.server.catalog.readConfig()["bridge"]?["model"] == nil)

        #expect(try await browser.send("DELETE", "/api/backups/\(id)").status == 200)
        #expect(try await browser.get("/api/backups").json?["backups"] == [])
    }

    /// Binary bodies, which Browser (text) cannot send.
    func upload(_ data: Data, base: URL) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: base.appendingPathComponent("api/backups/restore"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await Browser.session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, body)
    }
}
