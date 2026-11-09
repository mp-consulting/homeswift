import Foundation
import HomeswiftAI
import Testing

@testable import HomeswiftPlugin

/// The Energy log and Worth knowing, worked out on the bridge from the Meters' hours, the power and batteries' charge,
/// and the Logbook: codes and values, never sentences.
@Suite(.timeLimit(.minutes(1)))
struct EnergyStoryTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2027-01-14 00:00 UTC: the span is the 14th and the 15th to noon.
    let day = Date(timeIntervalSince1970: 1_799_884_800)
    var from: Date { day }
    var to: Date { day.addingTimeInterval(36 * 3600) }

    func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    /// Hours 0 to `count - 1` from the 14th's midnight, each `value(hour)` kWh.
    func hours(_ count: Int, consumption: ((Int) -> Double?)? = nil, returned: ((Int) -> Double?)? = nil) -> [EnergyStory.Meter.Hour] {
        (0..<count).map { EnergyStory.Meter.Hour(start: at(Double($0)), consumption: consumption?($0), returned: returned?($0)) }
    }

    func story() -> EnergyStory {
        // The grid: 0.25 kWh a night hour (both nights), 0.2 by day, 1 kWh at 18:00 on the 14th; 0.2 EUR a kWh.
        let gridHours = hours(36, consumption: { hour in hour == 18 ? 1 : hour % 24 < 5 ? 0.25 : 0.2 })
        let gridTotal = gridHours.compactMap(\.consumption).reduce(0, +)
        let grid = EnergyStory.Meter(accessory: "Meter:grid", name: "Grid", role: .grid, hours: gridHours, cost: gridTotal * 0.2)
        // Solar: dark until 07:00 (0.02), 0.5 at 08:00, 1.5 at noon; nothing on the 15th's morning.
        let sun: (Int) -> Double = { hour in [7: 0.02, 8: 0.5, 12: 1.5][hour] ?? 0 }
        let roof = EnergyStory.Meter(accessory: "Solar:a", name: "Roof A", role: .solar, hours: hours(36, returned: sun))
        let twin = EnergyStory.Meter(accessory: "Solar:b", name: "Roof B", role: .solar, hours: hours(36, returned: sun))
        // A dishwasher run of two hours at 20:00; a fridge that never stops; a plug that says nothing.
        let dishwasher = EnergyStory.Meter(accessory: "Plugs:dishwasher", name: "Dishwasher", role: nil, hours: hours(24, consumption: { [20: 0.8, 21: 0.8][$0] ?? 0.01 }))
        let fridge = EnergyStory.Meter(accessory: "Plugs:fridge", name: "Fridge", role: nil, hours: hours(24, consumption: { $0 % 2 == 0 ? 0.05 : 0.06 }))
        let plug = EnergyStory.Meter(accessory: "Plugs:old", name: "Old plug", role: nil, hours: [])
        // A battery full at 10:00, nearly empty at 22:00; one point before the span says nothing.
        let level = EnergyReport.Level(series: "plugin:Test:level", device: "Pack", points: [
            (day.addingTimeInterval(-7200), 100), (at(1), 50), (at(10), 99.5), (at(15), 60), (at(22), 5),
        ])
        // The batteries discharging, then the grid taking over at 23:00; an imported step is left out.
        let power = [
            EnergyReport.PowerPoint(start: at(21), watts: [.battery: -600, .grid: 50]),
            EnergyReport.PowerPoint(start: at(22), watts: [.battery: 0, .grid: 900], imported: true),
            EnergyReport.PowerPoint(start: at(23), watts: [.battery: 0, .grid: 800]),
        ]
        // A charger flipping 7 times in 10 minutes; an outlet changing twice says nothing.
        let flips = (0..<7).map { EnergyStory.Change(time: at(30).addingTimeInterval(Double($0) * 100), accessory: "Plugs:charger", name: "Charger", characteristic: "Charging State") }
        let calm = [EnergyStory.Change(time: at(3), accessory: "Plugs:tv", name: "TV", characteristic: "Outlet In Use"),
                    EnergyStory.Change(time: at(4), accessory: "Plugs:tv", name: "TV", characteristic: "On")]
        return EnergyStory.derive(meters: [grid, roof, twin, dishwasher, fridge, plug], currency: "EUR", power: power, levels: [level],
                                  changes: flips + calm, from: from, to: to, timeZone: utc)
    }

    @Test func tellsEachEventWithItsValues() throws {
        let events = story().events
        #expect(events.map(\.at) == events.map(\.at).sorted())
        func event(_ code: String) throws -> EnergyStory.Event { try #require(events.first { $0.code == code }) }

        let busiest = try event("busiestGridHour")
        #expect(busiest.at == at(18) && busiest.kind == .power)
        #expect(busiest.values == ["value": 1, "cost": 0.2, "currency": "EUR"])
        // The 15th's busiest hour (0.25 kWh) is too small to tell.
        #expect(events.filter { $0.code == "busiestGridHour" }.count == 1)

        let up = try event("sunUp")
        #expect(up.at == at(7) && up.kind == .sun && up.values == ["value": 0.02])
        let best = try event("bestSolarHour")
        #expect(best.at == at(12) && best.values == ["value": 1.5, "total": 2.02])

        #expect(try event("batteryFull").at == at(10))
        #expect(try event("batteryFull").values == ["name": "Pack"])
        #expect(try event("batteryLow").at == at(22))
        // The point before the span is not a change the span saw.
        #expect(events.filter { $0.code == "batteryFull" }.count == 1)

        let grid = try event("gridTookOver")
        #expect(grid.at == at(23) && grid.values == ["watts": 800])

        let ran = try event("deviceRan")
        #expect(ran.at == at(20) && ran.kind == .device && ran.accessory == "Plugs:dishwasher")
        #expect(ran.values == ["name": "Dishwasher", "n": 2, "value": 1.6, "cost": 0.32, "currency": "EUR"])
        // The fridge is always on, not running.
        #expect(!events.contains { $0.code == "deviceRan" && $0.accessory == "Plugs:fridge" })

        let flapping = try event("flapping")
        #expect(flapping.kind == .odd && flapping.accessory == "Plugs:charger" && flapping.at == at(30).addingTimeInterval(600))
        #expect(flapping.values == ["name": "Charger", "n": 7, "minutes": 10])
    }

    @Test func saysWhatStandsOut() throws {
        let worth = story().worth
        // The unusual first, five at most.
        #expect(worth.map(\.code) == ["flapping", "nightFloor", "alwaysOn", "silentMeters", "countedTwice"])
        #expect(worth[0].severity == .warning && worth[0].accessory == "Plugs:charger")
        #expect(worth[0].values == ["name": "Charger", "n": 7, "minutes": 10])
        // 250 W all night, every night: 2190 kWh a year at 0.2.
        #expect(worth[1].values == ["watts": 250, "cost": 438, "currency": "EUR"])
        #expect(worth[1].severity == .info && worth[1].accessory == nil)
        #expect(worth[2].accessory == "Plugs:fridge")
        #expect(worth[2].values["name"] == "Fridge" && worth[2].values["watts"] == 55)
        #expect(worth[2].values["cost"] == 96.36)
        #expect(worth[3].values == ["names": ["Old plug"], "n": 1])
        #expect(worth[4].values == ["first": "Roof A", "second": "Roof B"])
    }

    @Test func goesWithoutAPrice() {
        let story = EnergyStory.derive(
            meters: [EnergyStory.Meter(accessory: "Meter:grid", name: "Grid", role: .grid, hours: hours(36, consumption: { $0 == 18 ? 1 : 0.25 }))],
            currency: nil, power: [], levels: [], changes: [], from: from, to: to, timeZone: utc)
        #expect(story.events.first { $0.code == "busiestGridHour" }?.values == ["value": 1])
        #expect(story.worth.map(\.code) == ["nightFloor"])
        #expect(story.worth[0].values == ["watts": 250])
        // In another time zone the nights are other hours: Tokyo's are 15:00 to 20:00 UTC, 0.25 too except 18:00.
        let tokyo = EnergyStory.derive(
            meters: [EnergyStory.Meter(accessory: "Meter:grid", name: "Grid", role: .grid, hours: hours(36, consumption: { $0 == 18 ? 1 : 0.25 }))],
            currency: nil, power: [], levels: [], changes: [], from: from, to: to, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(tokyo.worth[0].values == ["watts": 250])
    }

    @Test func givesJSONAndEnglish() throws {
        let json = story().json(english: true)
        let event = try #require(json["events"]?.arrayValue?.first { $0["code"] == "deviceRan" })
        #expect(event["at"] == "2027-01-14T20:00:00Z")
        #expect(event["kind"] == "device" && event["accessory"] == "Plugs:dishwasher")
        #expect(event["text"] == "Dishwasher ran 2 hours (1.6 kWh, 0.32 EUR)")
        let worth = try #require(json["worth"]?.arrayValue)
        #expect(worth[1]["text"] == "The home never drew less than 250 W at night: about 438.00 EUR a year")
        #expect(worth[0]["severity"] == "warning")
        // The page words it: no text without english.
        #expect(story().json()["worth"]?[0]?["text"] == nil)
    }
}
