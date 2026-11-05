import Foundation
import Homeswift
import HomeswiftPlugin

extension HomeswiftCatalog {
    /// How a consumption report is cut: by hour (`hours` up to 48), by day, or by month.
    enum ConsumptionStep { case hour, day, month }

    /// Each Meter's Consumption and Returned in kWh over a span, with a bar per hour, day or month, the Meters that drew
    /// the most first (docs/adr/0004-meters-and-consumption-history.md).
    ///
    /// The span is either the last `hours` (hourly bars up to 48 hours, daily beyond), or a `period` around `date`
    /// (YYYY-MM-DD, today without it): `week` (the 8 days to it, daily), `month` (daily) or `year` (monthly). Days and
    /// months are counted in `timeZone`. `accessory` keeps one accessory's Meters. Each bar has `recordedHours` (the
    /// bridge's own measurement) and `hours` (anything known, imports and estimates included); a bar with nothing known
    /// has null figures.
    public func consumptionJSON(period: String? = nil, date: String? = nil, hours: Double? = nil, timeZone: TimeZone = .current,
                                accessory: String? = nil, now: Date = Date()) throws -> JSONValue {
        guard let metrics else { throw CatalogError("This homeswift records no metrics", notFound: true) }
        let from: Date, to: Date, step: ConsumptionStep
        if let hours {
            guard hours > 0, hours <= 24 * 366 else { throw CatalogError("hours is more than 0 and at most a year's") }
            to = now
            from = now.addingTimeInterval(-hours * 3600)
            step = hours <= 48 ? .hour : .day
        } else {
            let period = period ?? "week"
            guard let span = EnergyCalendar.span(period: period, date: date, timeZone: timeZone, now: now) else {
                throw CatalogError("period is week, month or year, and date YYYY-MM-DD")
            }
            (from, to) = span
            step = period == "year" ? .month : .day
        }
        if let accessory, find(id: accessory) == nil, metrics.meters.meters(of: accessory).isEmpty {
            throw CatalogError("No accessory with that id", notFound: true)
        }
        let ids = accessory.map { metrics.meters.meters(of: $0) } ?? metrics.meters.meters
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = switch step { case .hour: "yyyy-MM-dd'T'HH:mm"; case .day: "yyyy-MM-dd"; case .month: "yyyy-MM" }
        let kWh = { (wattHours: Double?) in wattHours.map { JSONValue.number(($0).rounded() / 1000) } ?? .null }

        var meters: [(consumption: Double, json: JSONValue)] = []
        for id in ids {
            var bars: [JSONValue] = []
            var consumption: Double?, returned: Double?
            func add(_ start: Date, _ drawn: Double?, _ back: Double?, recorded: Int, known: Int) {
                if let drawn { consumption = (consumption ?? 0) + drawn }
                if let back { returned = (returned ?? 0) + back }
                bars.append(["date": .string(format.string(from: start)), "consumption": kWh(drawn), "returned": kWh(back),
                             "recordedHours": .number(Double(recorded)), "hours": .number(Double(known))])
            }
            switch step {
            case .hour:
                // Every hour of the span, known or not, so the bars line up with the clock.
                let known = Dictionary(metrics.meters.hours(of: id, from: from, to: to).map { (MeterArchive.hourIndex($0.start), $0) }) { first, _ in first }
                for index in MeterArchive.hourIndex(from)...MeterArchive.hourIndex(to) {
                    let hour = known[index]
                    add(Date(timeIntervalSince1970: TimeInterval(index * 3600)), hour?.consumption, hour?.returned,
                        recorded: hour?.recorded == true ? 1 : 0, known: hour == nil ? 0 : 1)
                }
            case .day, .month:
                for one in metrics.meters.periods(of: id, step == .month ? .month : .day, from: from, to: to, timeZone: timeZone) {
                    add(one.start, one.consumption, one.returned, recorded: one.recordedHours, known: one.hours)
                }
            }
            let located = find(id: id.accessory)
            var json: [String: JSONValue] = [
                "accessory": .string(id.accessory), "meter": .string(id.meter),
                "name": .string(located.map { $0.layout?.name ?? $0.accessory.name } ?? id.accessory),
                "consumption": kWh(consumption), "returned": kWh(returned), "bars": .array(bars),
            ]
            // A device with several Meters (a relay's channels): each is named by its service.
            if let located, metrics.meters.meters(of: id.accessory).count > 1 { json["label"] = .string(Self.meterLabel(id, of: located.accessory)) }
            meters.append((consumption ?? 0, .object(json)))
        }
        format.dateFormat = "yyyy-MM-dd"
        return [
            "from": .string(format.string(from: from)), "to": .string(format.string(from: to)),
            "step": .string("\(step)"),
            "meters": .array(meters.sorted { $0.consumption > $1.consumption }.map(\.json)),
        ]
    }

    /// A Meter's own name on its accessory: its service's name, else the key its plugin gave it.
    static func meterLabel(_ id: MeterID, of accessory: Accessory) -> String {
        let service = accessory.services.first { "\($0.type.uuid)/\($0.subtype ?? "")" == id.meter }
        let name = service?[.configuredName]?.value.stringValue ?? service?[.name]?.value.stringValue
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? service?.subtype ?? id.meter
    }
}
