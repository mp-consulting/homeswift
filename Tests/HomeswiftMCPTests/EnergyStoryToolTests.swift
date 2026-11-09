import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// The Energy log and Worth knowing over MCP (`get_energy_story`), and the notifications of a new night floor.
@Suite(.timeLimit(.minutes(1)))
struct EnergyStoryToolTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2027-01-15 08:00 UTC; the 14th's midnight 32 hours before.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var day: Date { now.addingTimeInterval(-32 * 3600) }
    let grid = MeterID(accessory: "Meter:grid", meter: "grid")
    let dishwasher = MeterID(accessory: "Plugs:dishwasher", meter: "43/")

    /// The grid: 250 Wh a night hour, 200 by day, 1.2 kWh at 18:00 on the 14th; a dishwasher's two-hour run at 20:00.
    func record(_ metrics: Metrics) {
        metrics.meters.importHours((0..<32).map { hour in
            MeterHourImport(start: day.addingTimeInterval(Double(hour) * 3600), consumption: hour == 18 ? 1200 : hour % 24 < 5 ? 250 : 200)
        }, meter: grid)
        metrics.meters.setSuggestedRole(.grid, meter: grid)
        metrics.meters.importHours((0..<24).map { hour in
            MeterHourImport(start: day.addingTimeInterval(Double(hour) * 3600), consumption: hour == 20 || hour == 21 ? 800 : 10)
        }, meter: dishwasher)
    }

    func catalog(_ environment: MCPTestEnvironment, metrics: Metrics) -> (HomeswiftCatalog, MCPServer) {
        let catalog = HomeswiftCatalog(host: environment.host, logs: environment.logs, metrics: metrics, configURL: environment.configURL, logger: testLogger)
        var options = MCPServer.Options(version: "test", instructions: HomeswiftCatalog.instructions)
        options.logger = testLogger
        let server = MCPServer(options: options, tools: catalog.tools, resources: catalog.resources, templates: catalog.templates, prompts: catalog.prompts,
                               audit: AuditLog(url: environment.directory.appendingPathComponent("story-audit.jsonl"), logger: testLogger))
        _ = catalog.attach(to: server)
        return (catalog, server)
    }

    @Test func tellsTheStoryWithEnglishWrappedAsData() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let metrics = Metrics(directory: nil, now: { [now] in now })
        record(metrics)
        let (_, server) = catalog(environment, metrics: metrics)
        let client = DirectClient(server: server, scope: .read)
        try await client.initialize()

        let tools = try await client.call("tools/list")["tools"]?.arrayValue ?? []
        let tool = try #require(tools.first { $0["name"] == "get_energy_story" })
        #expect(tool["annotations"]?["readOnlyHint"] == true)
        #expect(tool["annotations"]?["destructiveHint"] == false)

        let result = ToolResult(json: try await client.tool("get_energy_story", ["from": "2027-01-14T00:00:00Z", "to": "2027-01-15T08:00:00Z", "timeZone": "UTC"]))
        #expect(!result.isError)
        // Names came from devices: the text is data, never instructions.
        #expect(result.text.hasPrefix("<untrusted-data source=\"energy\">") && result.text.hasSuffix("</untrusted-data>"))
        let events = try #require(result.structured?["events"]?.arrayValue)
        let busiest = try #require(events.first { $0["code"] == "busiestGridHour" })
        #expect(busiest["at"] == "2027-01-14T18:00:00Z" && busiest["kind"] == "power" && busiest["values"]?["value"] == 1.2)
        #expect(busiest["text"] == "Busiest hour from the grid: 1.2 kWh")
        let ran = try #require(events.first { $0["code"] == "deviceRan" })
        #expect(ran["accessory"] == "Plugs:dishwasher" && ran["values"]?["n"] == 2 && ran["values"]?["value"] == 1.6)
        let worth = try #require(result.structured?["worth"]?.arrayValue)
        #expect(worth.first?["code"] == "nightFloor" && worth.first?["values"]?["watts"] == 250 && worth.first?["severity"] == "info")
        #expect(worth.first?["text"] == "The home never drew less than 250 W at night")

        let wrong = ToolResult(json: try await client.tool("get_energy_story", ["from": "yesterday"]))
        #expect(wrong.isError)
    }

    /// A night floor that was not there at the last look goes out once; the first look after a start only remembers.
    @Test func notifiesANewNightFloorOnce() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let metrics = Metrics(directory: nil, now: { [now] in now })
        let (catalog, _) = catalog(environment, metrics: metrics)
        let sender = RecordingSender()
        catalog.home.http = sender
        _ = try catalog.updateNotificationSettings(["channels": ["webhook": ["enabled": true, "url": "https://hooks.example.com/energy"]]])

        await catalog.checkEnergyStory(now: now, timeZone: utc)
        #expect(sender.requests.isEmpty)
        record(metrics)
        // Within 15 minutes of the last look: no look.
        await catalog.checkEnergyStory(now: now.addingTimeInterval(600), timeZone: utc)
        #expect(sender.requests.isEmpty)
        await catalog.checkEnergyStory(now: now.addingTimeInterval(16 * 60), timeZone: utc)
        let sent = try #require(sender.requests.first)
        #expect(sender.requests.count == 1)
        let body = try JSONValue(data: sent.body ?? Data())
        #expect(body["event"] == "energyInsight")
        #expect(body.text(pretty: false).contains("250 W"))
        // Still there: not new.
        await catalog.checkEnergyStory(now: now.addingTimeInterval(32 * 60), timeZone: utc)
        #expect(sender.requests.count == 1)
    }
}
