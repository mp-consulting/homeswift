import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDaikinCloud

/// `consumptionData` as the Energy section's hours, and the plugin importing them only when asked.
@Suite(.timeLimit(.minutes(1)))
struct ConsumptionTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Wednesday 4 November 2026, 13:30 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_799_000)

    static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    /// A unit whose climate control heated 1 kWh every two hours yesterday and 0.5 this morning, cooled 0.2 in today's
    /// first slot, and 10 kWh a day over the two weeks (5 so far today).
    static let unit: JSONValue = [
        "id": "unit-1",
        "managementPoints": [
            ["embeddedId": "climateControl", "managementPointType": "climateControl",
             "consumptionData": ["value": ["electrical": [
                "heating": [
                    "d": .array(Array(repeating: 1.0, count: 12).map { .number($0) } + Array(repeating: 0.5, count: 6).map { .number($0) } + Array(repeating: JSONValue.null, count: 6)),
                    "w": .array(Array(repeating: 10.0, count: 9).map { .number($0) } + [5] + Array(repeating: JSONValue.null, count: 4)),
                ],
                "cooling": ["d": .array([.number(0)] + Array(repeating: JSONValue.null, count: 11) + [0.2] + Array(repeating: JSONValue.null, count: 11))],
                "unit": "kWh",
             ]]]],
            ["embeddedId": "gateway", "managementPointType": "gateway"],
        ],
    ]

    @Test func theCloudsSlotsAndDaysAreRead() {
        let totals = DaikinConsumption.totals(of: Self.unit, now: Self.now, calendar: Self.calendar)
        #expect(totals.slots[Self.date("2026-11-03T00:00:00Z")]?.kWh == 1)
        #expect(totals.slots[Self.date("2026-11-03T22:00:00Z")]?.kWh == 1)
        #expect(abs((totals.slots[Self.date("2026-11-04T00:00:00Z")]?.kWh ?? 0) - 0.7) < 1e-9, "heating and cooling added up")
        #expect(totals.slots[Self.date("2026-11-04T12:00:00Z")] == nil, "not reached yet")
        // Last week's Monday is 26 October; this Wednesday is 5 so far.
        #expect(totals.days[Self.date("2026-10-26T00:00:00Z")] == 10)
        #expect(totals.days[Self.date("2026-11-04T00:00:00Z")] == 5)
        #expect(totals.days.count == 10)
        #expect(abs(DaikinConsumption.today(totals, now: Self.now, calendar: Self.calendar) - 3.2) < 1e-9)
    }

    @Test func slotsAndDaysBecomeHoursOfTheHomesUse() {
        let totals = DaikinConsumption.totals(of: Self.unit, now: Self.now, calendar: Self.calendar)
        let result = DaikinConsumption.hours(totals, now: Self.now, calendar: Self.calendar)
        let hours = DaikinConsumption.imports(result.hours)
        let byStart = Dictionary(uniqueKeysWithValues: hours.map { ($0.start, $0.flows) })
        #expect(result.detailed == [Self.date("2026-11-03T00:00:00Z"), Self.date("2026-11-04T00:00:00Z")])
        // Yesterday and today come from the two-hour slots, the days before from the week's.
        #expect(byStart[Self.date("2026-11-03T05:00:00Z")]?.home == 500)
        #expect(abs((byStart[Self.date("2026-11-04T01:00:00Z")]?.home ?? 0) - 350) < 1e-9)
        #expect(byStart[Self.date("2026-11-04T11:00:00Z")]?.home == 250)
        #expect(byStart[Self.date("2026-11-04T12:00:00Z")] == nil, "a slot not over is not imported")
        #expect(abs((byStart[Self.date("2026-11-02T07:00:00Z")]?.home ?? 0) - 10000.0 / 24) < 1e-9)
        #expect(byStart[Self.date("2026-10-25T23:00:00Z")] == nil)
        // Eight days of 24 hours from the weeks, yesterday's 24 and today's 12 from the slots.
        #expect(hours.count == 8 * 24 + 24 + 12)
        #expect(hours.allSatisfy { $0.flows.solar == nil && $0.flows.gridImport == nil })
        let total = hours.reduce(0) { $0 + ($1.flows.home ?? 0) }
        #expect(abs(total - (80_000 + 12_000 + 3_200)) < 1e-6)
    }

    /// Monday's slots went into the Energy section on Tuesday: on Wednesday, its week's flat figure leaves them be.
    @Test func aDayImportedFromItsSlotsIsNotFlattenedLater() {
        let totals = DaikinConsumption.totals(of: Self.unit, now: Self.now, calendar: Self.calendar)
        let monday = Self.date("2026-11-02T00:00:00Z")
        let result = DaikinConsumption.hours(totals, now: Self.now, calendar: Self.calendar, detailed: [monday])
        #expect(result.hours[Self.date("2026-11-02T07:00:00Z")] == nil)
        #expect(result.hours[Self.date("2026-11-01T07:00:00Z")] != nil, "the days before are still the week's")
    }

    /// The slots are the unit's wall clock: its gateway's time zone, two hours each, one on the night the clocks go
    /// forward.
    @Test func theSlotsAreTheUnitsWallClock() {
        var unit = Self.unit.objectValue!
        var points = unit["managementPoints"]!.arrayValue!
        points[1] = ["embeddedId": "gateway", "managementPointType": "gateway", "timeZone": ["settable": true, "value": "Europe/Paris"]]
        unit["managementPoints"] = .array(points)
        let calendar = DaikinConsumption.calendar(of: .object(unit))
        #expect(calendar.timeZone.identifier == "Europe/Paris")
        // Monday 30 March 2026, 13:30 in Paris: yesterday, the clocks went from 02:00 to 03:00.
        let now = Self.date("2026-03-30T11:30:00Z")
        let totals = DaikinConsumption.totals(of: .object(unit), now: now, calendar: calendar)
        #expect(totals.slots[Self.date("2026-03-28T23:00:00Z")]?.kWh == 1, "midnight in Paris")
        #expect(totals.slots[Self.date("2026-03-28T23:00:00Z")]?.end == Self.date("2026-03-29T01:00:00Z"))
        #expect(totals.slots[Self.date("2026-03-29T01:00:00Z")]?.kWh == 1, "02:00 to 04:00, which lasted an hour")
        #expect(totals.slots[Self.date("2026-03-29T01:00:00Z")]?.end == Self.date("2026-03-29T02:00:00Z"))
        #expect(totals.slots[Self.date("2026-03-29T22:00:00Z")] != nil, "today's midnight")
        let hours = DaikinConsumption.hours(totals, now: now, calendar: calendar).hours
        #expect(hours[Self.date("2026-03-28T23:00:00Z")] == 500)
        #expect(hours[Self.date("2026-03-29T01:00:00Z")] == 1000, "a one-hour slot")
    }

    @Test func anotherUnitIsNotRead() {
        var other = Self.unit.objectValue!
        var points = other["managementPoints"]!.arrayValue!
        var point = points[0].objectValue!
        point["consumptionData"] = ["value": ["electrical": ["heating": ["d": [1, 1]], "unit": "Wh"]]]
        points[0] = .object(point)
        other["managementPoints"] = .array(points)
        #expect(DaikinConsumption.totals(of: .object(other), now: Self.now, calendar: Self.calendar) == DaikinConsumption.Totals())
    }

    /// The plugin records each unit's day in the history, and imports the hours into the Energy section only with
    /// `energyHistory`.
    @Test(arguments: [false, true]) func theEnergySectionGetsTheHoursWhenAsked(_ enabled: Bool) async throws {
        let environment = DaikinEnvironment(devices: [Self.unit])
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        let host = try environment.host(developerBlock.merging(["energyHistory": enabled]) { $1 })
        let imports = NIOLockedValueBox<[[EnergyHourImport]]>([])
        let values = NIOLockedValueBox<[String]>([])
        let observations = [
            host.observeEnergyImports { _, hours, _ in imports.withLockedValue { $0.append(hours) } },
            host.observeValues { series, _ in values.withLockedValue { $0.append(series) } },
        ]
        try await host.start()
        await environment.plugin?.settle()
        #expect(await eventually { values.withLockedValue { $0 }.contains("plugin:DaikinCloud:unit-1:energyToday") })
        if enabled {
            #expect(await eventually { !imports.withLockedValue { $0 }.isEmpty })
            #expect(imports.withLockedValue { $0 }.first?.allSatisfy { $0.flows.home != nil } == true)
        } else {
            #expect(imports.withLockedValue { $0 }.isEmpty)
        }
        _ = observations
        await host.stop()
    }
}
