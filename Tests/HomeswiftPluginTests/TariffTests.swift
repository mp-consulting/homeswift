import Foundation
import Testing

@testable import HomeswiftPlugin

/// The Tariff: its checks (each moment of the week once), its periods past midnight and by day of the week, the one in
/// force by its first day, and an hour's cost.
@Suite(.timeLimit(.minutes(1)))
struct TariffTests {
    let paris = TimeZone(identifier: "Europe/Paris")!
    let peakOffPeak = Tariff(start: "2026-01-01", currency: "EUR", periods: [
        .init(name: "Off-peak", from: "22:00", to: "06:00", price: 0.17),
        .init(name: "Peak", from: "06:00", to: "22:00", price: 0.21),
    ], exportPrice: 0.04)

    /// A YYYY-MM-DDTHH:mm in Paris.
    func date(_ text: String) -> Date {
        let numbers = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4]))!
    }

    @Test func checksEachMomentOfTheWeekOnce() {
        #expect(Tariff.problems([peakOffPeak]).isEmpty)
        let gap = Tariff(start: "2026-01-01", currency: "EUR", periods: [.init(from: "06:00", to: "22:00", price: 0.2)])
        #expect(Tariff.problems([gap]) == ["tariffs[0].periods leave part of the week without a price"])
        let overlap = Tariff(start: "2026-01-01", currency: "EUR", periods: [.init(from: "00:00", to: "24:00", price: 0.2), .init(from: "12:00", to: "13:00", price: 0.1)])
        #expect(Tariff.problems([overlap]) == ["tariffs[0].periods overlap: each moment of the week needs one price"])
        // Weekdays and weekends, each a whole day.
        let week = Tariff(start: "2026-01-01", currency: "GBP", periods: [.init(from: "00:00", to: "24:00", days: [1, 2, 3, 4, 5], price: 0.3), .init(from: "00:00", to: "24:00", days: [6, 7], price: 0.2)])
        #expect(Tariff.problems([week]).isEmpty)
        let wrong = Tariff(start: "2026-13-01", currency: "eur", periods: [.init(from: "25:00", to: "06:00", price: -1)], exportPrice: -2)
        #expect(Tariff.problems([wrong]).count == 5)
        #expect(Tariff.problems([peakOffPeak, peakOffPeak]).contains("tariffs[1].start: another Tariff starts that day"))
    }

    @Test func pricesByPeriodAndByTheTariffInForce() {
        let later = Tariff(start: "2026-06-01", currency: "EUR", periods: [.init(from: "00:00", to: "24:00", price: 0.25)])
        let schedule = TariffSchedule([later, peakOffPeak], timeZone: paris)
        #expect(schedule.price(at: date("2025-12-31T12:00")) == nil)
        #expect(schedule.price(at: date("2026-03-02T23:30"))?.price == 0.17)
        #expect(schedule.price(at: date("2026-03-03T05:59"))?.price == 0.17)
        #expect(schedule.price(at: date("2026-03-03T06:00"))?.price == 0.21)
        #expect(schedule.price(at: date("2026-06-01T23:30"))?.price == 0.25)
        #expect(schedule.price(at: date("2026-03-03T12:00"))?.exportPrice == 0.04)
        // 2 kWh drawn and 1 sent back in a peak hour: 0.42 less 0.04.
        let cost = schedule.cost(hour: date("2026-03-03T12:00"), drawn: 2, sent: 1)
        #expect(abs((cost ?? 0) - 0.38) < 1e-9)
        #expect(schedule.tariff(at: date("2026-07-01T00:00"))?.start == "2026-06-01")
    }

    @Test func weekendsAreTheirOwnDays() {
        let week = Tariff(start: "2026-01-01", currency: "GBP", periods: [.init(from: "00:00", to: "24:00", days: [1, 2, 3, 4, 5], price: 0.3), .init(from: "00:00", to: "24:00", days: [6, 7], price: 0.2)])
        let schedule = TariffSchedule([week], timeZone: paris)
        // 2026-03-07 is a Saturday, 2026-03-09 a Monday.
        #expect(schedule.price(at: date("2026-03-07T10:00"))?.price == 0.2)
        #expect(schedule.price(at: date("2026-03-08T23:00"))?.price == 0.2)
        #expect(schedule.price(at: date("2026-03-09T00:30"))?.price == 0.3)
    }

    @Test func configJSONReadsTheTariffs() throws {
        let configuration = try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "name": "Home", "tariffs": [{ "start": "2026-01-01", "currency": "EUR", "periods": [{ "from": "00:00", "to": "24:00", "price": 0.2 }] }] } }"#.utf8))
        #expect(configuration.tariffs.first?.periods.first?.price == 0.2)
        #expect(configuration.bridge.name == "Home")
        #expect(throws: (any Error).self) { try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "tariffs": [{ "start": 1 }] } }"#.utf8)) }
    }
}

/// The Location, a Bridge Setting: config.json's bridge.location, which plugins read live through `context.location`.
@Suite(.timeLimit(.minutes(1)))
struct LocationTests {
    @Test func configJSONReadsTheLocation() throws {
        let configuration = try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "name": "Home", "location": { "latitude": 48.8566, "longitude": 2.3522, "name": "Paris" } } }"#.utf8))
        #expect(configuration.location == Location(latitude: 48.8566, longitude: 2.3522, name: "Paris"))
        #expect(configuration.location?.label == "Paris")
        #expect(Location(latitude: 1.5, longitude: -2).label == "1.5000, -2.0000")
        #expect(try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "location": null } }"#.utf8)).location == nil)
        #expect(throws: (any Error).self) { try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "location": { "latitude": 91, "longitude": 0 } } }"#.utf8)) }
        #expect(throws: (any Error).self) { try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "location": "Paris" } }"#.utf8)) }
    }

    @Test func pluginsReadTheLocationAsItChanges() async throws {
        let environment = TestEnvironment()
        let host = try environment.host(#"{ "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Plugs" }] }"#)
        try await host.start()
        defer { Task { await host.stop() } }
        let context = try #require(host.context(platform: "Recording", name: "Plugs"))
        #expect(context.location == nil)

        let report = await host.apply(try HomeswiftConfiguration.decode(Data(#"{ "bridge": { "port": 0, "location": { "latitude": 40.2, "longitude": -8.4 } }, "platforms": [{ "platform": "Recording", "name": "Plugs" }] }"#.utf8)))
        #expect(report.needsRestart.isEmpty)
        #expect(report.reloaded.isEmpty)
        #expect(context.location == Location(latitude: 40.2, longitude: -8.4))
    }
}
