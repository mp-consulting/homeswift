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

    /// The Tariffs are written without a restart, checked first; each Meter's Consumption is priced hour by hour.
    @Test func pricesConsumptionByTheTariffs() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let metrics = Metrics(directory: nil, now: { [hour] in hour })
        let lamp = MeterID(accessory: "Devices:lamp", meter: "43/")
        metrics.meters.importHours([MeterHourImport(start: hour, consumption: 2_000), MeterHourImport(start: hour.addingTimeInterval(-43_200), consumption: 1_000)], meter: lamp)
        let catalog = catalog(environment, metrics: metrics)

        let tariffs: JSONValue = [["start": "2027-01-01", "currency": "EUR", "periods": [
            ["name": "Off-peak", "from": "22:00", "to": "06:00", "price": 0.1], ["name": "Peak", "from": "06:00", "to": "22:00", "price": 0.25]]]]
        let written = try await catalog.updateTariffs(tariffs)
        #expect(written["restartNeeded"] == [] || written["restartNeeded"] == nil)
        #expect(environment.host.configuration.tariffs.count == 1)
        #expect(try catalog.tariffsJSON(now: hour)["current"] == "2027-01-01")

        // 08:00 UTC is peak (2 kWh, 0.50); 20:00 the day before is peak too (1 kWh, 0.25).
        let week = try catalog.consumptionJSON(period: "week", date: "2027-01-15", timeZone: utc, now: hour)
        #expect(week["currency"] == "EUR")
        #expect(week["meters"]?[0]?["cost"] == 0.75)
        #expect(week["meters"]?[0]?["bars"]?.arrayValue?.last?["cost"] == 0.5)

        await #expect(throws: CatalogError.self) {
            try await catalog.updateTariffs([["start": "2027-02-01", "currency": "EUR", "periods": [["from": "06:00", "to": "22:00", "price": 0.2]]]])
        }
    }
}
