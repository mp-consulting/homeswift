import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDaikinCloud

/// `consumptionData` as each unit's Meter's hours.
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

    @Test func slotsAndDaysBecomeHoursOfTheUnitsMeter() {
        let totals = DaikinConsumption.totals(of: Self.unit, now: Self.now, calendar: Self.calendar)
        let result = DaikinConsumption.hours(totals, now: Self.now, calendar: Self.calendar)
        let hours = DaikinConsumption.imports(result.hours)
        let byStart: [Date: Double] = Dictionary(uniqueKeysWithValues: hours.compactMap { hour in hour.consumption.map { (hour.start, $0) } })
        #expect(result.detailed == [Self.date("2026-11-03T00:00:00Z"), Self.date("2026-11-04T00:00:00Z")])
        // Yesterday and today come from the two-hour slots, the days before from the week's.
        #expect(byStart[Self.date("2026-11-03T05:00:00Z")] == 500)
        #expect(abs((byStart[Self.date("2026-11-04T01:00:00Z")] ?? 0) - 350) < 1e-9)
        #expect(byStart[Self.date("2026-11-04T11:00:00Z")] == 250)
        #expect(byStart[Self.date("2026-11-04T12:00:00Z")] == nil, "a slot not over is not imported")
        #expect(abs((byStart[Self.date("2026-11-02T07:00:00Z")] ?? 0) - 10000.0 / 24) < 1e-9)
        #expect(byStart[Self.date("2026-10-25T23:00:00Z")] == nil)
        // Eight days of 24 hours from the weeks, yesterday's 24 and today's 12 from the slots.
        #expect(hours.count == 8 * 24 + 24 + 12)
        #expect(hours.allSatisfy { $0.returned == nil })
        let total = hours.reduce(0) { $0 + ($1.consumption ?? 0) }
        #expect(abs(total - (80_000 + 12_000 + 3_200)) < 1e-6)
    }

    /// The 24 months: last year's January to December, then this year's. October 2026 is 62 kWh, of which the two weeks
    /// have 26–31 October (60 kWh): its 25 days before them share the other 2; September 2025 is 30 kWh over 30 days; a
    /// month without use, and the months after this one, add nothing.
    @Test func theMonthsFillTheTwoYearsBeforeTheTwoWeeks() {
        var object = Self.unit.objectValue!
        var months: [JSONValue] = Array(repeating: .number(0), count: 24)
        months[8] = 30      // September 2025
        months[21] = 62     // October 2026
        months[22] = 45     // November 2026: the two weeks have it
        months[23] = 99     // December 2026: not there yet
        var points = object["managementPoints"]!.arrayValue!
        var point = points[0].objectValue!
        var electrical = point["consumptionData"]!["value"]!["electrical"]!.objectValue!
        var heating = electrical["heating"]!.objectValue!
        heating["m"] = .array(months)
        electrical["heating"] = .object(heating)
        point["consumptionData"] = ["value": ["electrical": .object(electrical)]]
        points[0] = .object(point)
        object["managementPoints"] = .array(points)
        let unit = JSONValue.object(object)

        let totals = DaikinConsumption.totals(of: unit, now: Self.now, calendar: Self.calendar)
        #expect(totals.months[Self.date("2025-09-01T00:00:00Z")] == 30)
        #expect(totals.months[Self.date("2026-12-01T00:00:00Z")] == nil, "a month to come")
        let hours = DaikinConsumption.monthHours(totals, now: Self.now, calendar: Self.calendar)
        #expect(abs((hours[Self.date("2025-09-14T10:00:00Z")] ?? 0) - 1000.0 / 24) < 1e-9, "a kWh a day")
        #expect(abs((hours[Self.date("2026-10-25T23:00:00Z")] ?? 0) - 2000.0 / 25 / 24) < 1e-9)
        #expect(hours[Self.date("2026-10-26T00:00:00Z")] == nil, "the two weeks' own")
        #expect(hours[Self.date("2025-08-10T00:00:00Z")] == nil, "a month without use")
        #expect(hours.keys.count == (30 + 25) * 24)
        #expect(abs(hours.values.reduce(0, +) - 32_000) < 1e-6)
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

    /// The plugin records each unit's day in the history and puts its hours on the unit's own Meter
    /// (`DaikinCloud:<Device Id>`, `consumption`), never as the home's use.
    @Test func eachUnitsHoursGoOnItsOwnMeter() async throws {
        let environment = DaikinEnvironment(devices: [Self.unit])
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        let host = try environment.host(developerBlock)
        let received = NIOLockedValueBox<[(MeterID, [MeterHourImport])]>([])
        let imports = NIOLockedValueBox<[[EnergyHourImport]]>([])
        let values = NIOLockedValueBox<[String]>([])
        let observations = [
            host.observeMeterReadings { reading in
                guard case let .history(id, hours, _) = reading else { return }
                received.withLockedValue { $0.append((id, hours)) }
            },
            host.observeEnergyImports { _, hours, _ in imports.withLockedValue { $0.append(hours) } },
            host.observeValues { series, _ in values.withLockedValue { $0.append(series) } },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await host.start()
        await environment.plugin?.settle()
        #expect(await eventually { values.withLockedValue { $0 }.contains("plugin:DaikinCloud:unit-1:energyToday") })
        #expect(await eventually { !received.withLockedValue { $0 }.isEmpty })
        let (id, hours) = try #require(received.withLockedValue { $0 }.first)
        #expect(id == MeterID(accessory: "DaikinCloud:unit-1", meter: "consumption"))
        #expect(hours.allSatisfy { $0.consumption != nil && $0.returned == nil })
        #expect(imports.withLockedValue { $0 }.allSatisfy { $0.isEmpty }, "nothing as the home's use")
        await host.stop()
    }

    /// A bridge that imported the units' use as the home's (the former `energyHistory`) has it dropped once.
    @Test func theHomesUseImportedBeforeIsDroppedOnce() async throws {
        let environment = DaikinEnvironment(devices: [Self.unit])
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        let first = try await environment.start(developerBlock)
        await first.stop()
        let legacy = environment.storage.appendingPathComponent(DaikinCloudPlugin.legacyEnergyDaysFileName)
        try JSONEncoder().encode([Self.now]).write(to: legacy)

        let host = try environment.host(developerBlock)
        let forgotten = NIOLockedValueBox(0)
        let observation = host.observeEnergyImports { _, _, forget in if forget { forgotten.withLockedValue { $0 += 1 } } }
        defer { observation.cancel() }
        try await host.start()
        await environment.plugin?.settle()
        #expect(await eventually { forgotten.withLockedValue { $0 } == 1 })
        #expect(await eventually { !FileManager.default.fileExists(atPath: legacy.path) })
        await host.stop()
    }
}
