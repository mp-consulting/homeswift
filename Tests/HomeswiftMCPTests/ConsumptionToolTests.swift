import Foundation
import Homeswift
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// The consumption report the web UI's pages and `get_consumption` share: each Meter's kWh over a period, by day or
/// month, or over the last hours by hour, the Meters that drew the most first.
@Suite(.timeLimit(.minutes(1)))
struct ConsumptionToolTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2027-01-15 08:00 UTC.
    let hour = Date(timeIntervalSince1970: 1_800_000_000)

    func catalog(_ environment: MCPTestEnvironment, metrics: Metrics) -> HomeswiftCatalog {
        HomeswiftCatalog(host: environment.host, logs: environment.logs, metrics: metrics, configURL: environment.configURL, logger: testLogger)
    }

    @Test func reportsEachMeterByDayTheMostFirst() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let metrics = Metrics(directory: nil, now: { [hour] in hour })
        let lamp = MeterID(accessory: "Devices:lamp", meter: "43/")
        let heater = MeterID(accessory: "Devices:heater", meter: "solar")
        metrics.meters.importHours([MeterHourImport(start: hour, consumption: 500), MeterHourImport(start: hour.addingTimeInterval(-86_400), consumption: 250)], meter: lamp)
        metrics.meters.importHours([MeterHourImport(start: hour, consumption: 2_000, returned: 300)], meter: heater)
        let catalog = catalog(environment, metrics: metrics)

        let week = try catalog.consumptionJSON(period: "week", date: "2027-01-15", timeZone: utc, now: hour)
        #expect(week["step"] == "day")
        let meters = week["meters"]?.arrayValue ?? []
        #expect(meters.map { $0["accessory"]?.stringValue } == ["Devices:heater", "Devices:lamp"])
        #expect(meters[0]["consumption"] == 2 && meters[0]["returned"] == 0.3)
        #expect(meters[1]["consumption"] == 0.75)
        let bars = meters[1]["bars"]?.arrayValue ?? []
        #expect(bars.count == 8)
        #expect(bars.last?["date"] == "2027-01-15" && bars.last?["consumption"] == 0.5 && bars.last?["hours"] == 1)
        #expect(bars.first?["consumption"] == .null)

        // The last hours, by hour, one accessory's Meters only.
        let day = try catalog.consumptionJSON(hours: 3, timeZone: utc, accessory: "Devices:lamp", now: hour.addingTimeInterval(1800))
        #expect(day["step"] == "hour")
        let hourly = day["meters"]?[0]?["bars"]?.arrayValue ?? []
        #expect(hourly.count == 4)
        #expect(hourly.last?["date"] == "2027-01-15T08:00" && hourly.last?["consumption"] == 0.5)

        #expect(throws: CatalogError.self) { try catalog.consumptionJSON(period: "decade", timeZone: utc) }
        #expect(throws: CatalogError.self) { try catalog.consumptionJSON(accessory: "Devices:nothing") }
    }

    /// An accessory with a Meter's history says so, for the web UI's History.
    @Test func flagsMeteredAccessories() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let metrics = Metrics(directory: nil)
        let id = try #require(environment.host.mainBridge.server.accessories.first { $0.id != "bridge" }?.id)
        metrics.meters.recordCounter(10, meter: MeterID(accessory: id, meter: "x"))
        let catalog = catalog(environment, metrics: metrics)
        #expect(catalog.find(id: id)?.metered == true)
        #expect(HomeswiftCatalog.accessoryJSON(try #require(catalog.find(id: id)), detailed: false)["consumption"] == true)
        #expect(catalog.located().first { $0.accessory.id == id }?.metered == true)
    }

    /// A Meter's Energy Role is a Core Accessory Setting: get_settings lists the Meters with their suggestions, and a
    /// write keeps the role by the Meter's key, null giving the suggestion back.
    @Test func writesEnergyRoles() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let metrics = Metrics(directory: nil)
        let id = try #require(environment.host.mainBridge.server.accessories.first { $0.id.hasPrefix("Devices:") }?.id)
        metrics.meters.recordCounter(10, meter: MeterID(accessory: id, meter: "x"))
        let catalog = catalog(environment, metrics: metrics)

        let before = try await catalog.accessorySettingsJSON(accessoryID: id)
        #expect(before["meters"] == [["key": "x", "suggestedRole": .null]])
        #expect(before["fields"]?["energyRoles"]?["core"] == true)

        try await catalog.updateAccessorySettings([(id, ["energyRoles": ["x": "grid"]])])
        let written = try await catalog.accessorySettingsJSON(accessoryID: id)
        #expect(written["settings"]?["energyRoles"] == ["x": "grid"])
        #expect(environment.host.energyRole(of: MeterID(accessory: id, meter: "x")) == .some(.grid))

        try await catalog.updateAccessorySettings([(id, ["energyRoles": ["x": .null]])])
        #expect(try await catalog.accessorySettingsJSON(accessoryID: id)["settings"]?["energyRoles"] == nil)

        await #expect(throws: (any Error).self) { try await catalog.updateAccessorySettings([(id, ["energyRoles": ["x": "sun"]])]) }
    }
}
