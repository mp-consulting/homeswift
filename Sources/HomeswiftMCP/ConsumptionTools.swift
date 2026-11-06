import Foundation
import Homeswift
import HomeswiftPlugin

extension HomeswiftCatalog {
    /// How a consumption report is cut: by hour (`hours` up to 48), by day, or by month.
    enum ConsumptionStep { case hour, day, month }

    /// Each Meter's Consumption and Returned over a span, in kWh for electricity and m³ for gas and water (`kind`, `unit`), with a bar per hour, day or month, the Meters that drew
    /// the most first (docs/adr/0004-meters-and-consumption-history.md).
    ///
    /// The span is either the last `hours` (hourly bars up to 48 hours, daily beyond), or a `period` around `date`
    /// (YYYY-MM-DD, today without it): `week` (the 8 days to it, daily), `month` (daily) or `year` (monthly). Days and
    /// months are counted in `timeZone`. `accessory` keeps one accessory's Meters. Each bar has `recordedHours` (the
    /// bridge's own measurement) and `hours` (anything known, imports and estimates included); a bar with nothing known
    /// has null figures; `role` is its Energy Role (grid, home, solar, battery or null for one device's use; always null for gas
    /// and water). With Tariffs of its kind, each Meter and bar has its `cost`: its Consumption hour by hour at that hour's
    /// price, in the Meter's `currency` (null where no hour is priced); `currency` is electricity's.
    /// `kind` keeps one kind's Meters.
    public func consumptionJSON(period: String? = nil, date: String? = nil, hours: Double? = nil, timeZone: TimeZone = .current,
                                accessory: String? = nil, kind: MeterKind? = nil, now: Date = Date()) throws -> JSONValue {
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
        let all = metrics.meters.meters
        var ids = accessory.map { one in all.filter { $0.accessory == one } } ?? all
        if let kind { ids = ids.filter { metrics.meters.kind(of: $0) == kind } }
        if let accessory, ids.isEmpty, find(id: accessory) == nil { throw CatalogError("No accessory with that id", notFound: true) }
        let byAccessory = Dictionary(grouping: ids, by: \.accessory)
        // The bars: every hour of the span, so they line up with the clock, or its days or months.
        let starts: [Date], end: Date
        switch step {
        case .hour:
            starts = (MeterArchive.hourIndex(from)...MeterArchive.hourIndex(to)).map { Date(timeIntervalSince1970: TimeInterval($0 * 3600)) }
            end = to
        case .day, .month:
            guard let span = EnergyCalendar.periods(step == .month ? .month : .day, from: from, to: to, timeZone: timeZone) else { throw CatalogError("No such span") }
            (starts, end) = (span.starts, span.end.addingTimeInterval(-1))
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = switch step { case .hour: "yyyy-MM-dd'T'HH:mm"; case .day: "yyyy-MM-dd"; case .month: "yyyy-MM" }
        let dates = starts.map { JSONValue.string(format.string(from: $0)) }
        // Thousandths of the unit (Wh, litres) to the unit (kWh, m³), to a thousandth.
        let kWh = { (wattHours: Double?) in wattHours.map { JSONValue.number(($0).rounded() / 1000) } ?? .null }
        // Each hour's Consumption at that hour's price of its kind (whatever source covered it): devices compare alike.
        let schedules = TariffSchedule.byKind(host.configuration.tariffs, timeZone: timeZone)
        let money = { (amount: Double?) in amount.map { JSONValue.number(($0 * 100).rounded() / 100) } ?? .null }

        var meters: [(kind: MeterKind, consumption: Double, json: JSONValue)] = []
        for id in ids {
            let kind = metrics.meters.kind(of: id)
            let schedule = schedules[kind]!
            // The Meter's hours, read once, added up by bar.
            let hours = metrics.meters.hours(of: id, from: starts[0], to: end)
            var bars = [(drawn: Double?, back: Double?, recorded: Int, known: Int)](repeating: (nil, nil, 0, 0), count: starts.count)
            for hour in hours {
                let index = EnergyCalendar.index(of: hour.start, in: starts)
                if let value = hour.consumption { bars[index].drawn = (bars[index].drawn ?? 0) + value }
                if let value = hour.returned { bars[index].back = (bars[index].back ?? 0) + value }
                bars[index].known += 1
                if hour.recorded { bars[index].recorded += 1 }
            }
            let costs = schedule.isEmpty ? nil : schedule.costs(of: hours.map { ($0.start, $0.consumption.map { $0 / 1000 }, nil) }, in: starts)
            let consumption = bars.compactMap(\.drawn).reduce(nil as Double?) { ($0 ?? 0) + $1 }
            let returned = bars.compactMap(\.back).reduce(nil as Double?) { ($0 ?? 0) + $1 }
            let located = find(id: id.accessory)
            var json: [String: JSONValue] = [
                "accessory": .string(id.accessory), "meter": .string(id.meter), "kind": .string(kind.rawValue), "unit": .string(kind.unit),
                "name": .string(located.map { $0.layout?.name ?? $0.accessory.name } ?? id.accessory),
                "consumption": kWh(consumption), "returned": kWh(returned),
                "bars": .array(bars.indices.map { index in
                    var bar: [String: JSONValue] = ["date": dates[index], "consumption": kWh(bars[index].drawn), "returned": kWh(bars[index].back),
                                                    "recordedHours": .number(Double(bars[index].recorded)), "hours": .number(Double(bars[index].known))]
                    if let costs { bar["cost"] = money(costs.periods[index]) }
                    return .object(bar)
                }),
            ]
            if let costs {
                json["cost"] = money(costs.total)
                json["currency"] = schedule.currency.map(JSONValue.string) ?? .null
            }
            // Its Energy Role (the person's, else its plugin's suggestion): a grid or home meter holds the devices measured
            // on their own, which the web UI nests under it with what no meter measures (Unmetered).
            let role: EnergyRole? = kind != .electricity ? nil : host.energyRole(of: id) ?? metrics.meterDescription(of: id)?.suggestedRole
            json["role"] = role.map { .string($0.rawValue) } ?? .null
            // A device with several Meters (a relay's channels): each is named by its service.
            if let located, (byAccessory[id.accessory]?.count ?? 0) > 1 { json["label"] = .string(Self.meterLabel(id, of: located.accessory)) }
            meters.append((kind, consumption ?? 0, .object(json)))
        }
        format.dateFormat = "yyyy-MM-dd"
        return [
            "from": .string(format.string(from: from)), "to": .string(format.string(from: to)),
            "step": .string("\(step)"),
            // Electricity's; a gas or water Meter has its own with its cost.
            "currency": schedules[.electricity]?.currency.map(JSONValue.string) ?? .null,
            // By kind (kWh and m³ do not compare), then the Meters that drew the most first.
            "meters": .array(meters.sorted { ($0.kind.order, -$0.consumption) < ($1.kind.order, -$1.consumption) }.map(\.json)),
        ]
    }

    /// A Meter's own name on its accessory: its service's name, else the key its plugin gave it.
    static func meterLabel(_ id: MeterID, of accessory: Accessory) -> String {
        let service = accessory.services.first { "\($0.type.uuid)/\($0.subtype ?? "")" == id.meter }
        let name = service?[.configuredName]?.value.stringValue ?? service?[.name]?.value.stringValue
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? service?.subtype ?? id.meter
    }

    // MARK: Tariffs

    /// The Tariffs as config.json's bridge block has them (`bridge.tariffs`), oldest first, and the one in force now.
    public func tariffsJSON(now: Date = Date()) throws -> JSONValue {
        let list = try readConfig()["bridge"]?["tariffs"]?.arrayValue ?? []
        let tariffs = (try? JSONValue.array(list).decode([Tariff].self)) ?? []
        // Each kind's Tariff in force now, by its first day; `current` is electricity's. `meterKinds`: the kinds of the
        // Meters the bridge keeps, which Settings offers a Tariff for.
        let schedules = TariffSchedule.byKind(tariffs)
        let byKind: [String: JSONValue] = schedules.reduce(into: [:]) { result, entry in
            if let tariff = entry.value.tariff(at: now) { result[entry.key.rawValue] = .string(tariff.start) }
        }
        let kinds = (metrics?.meters.kinds ?? []).union(tariffs.map(\.kind)).sorted { $0.order < $1.order }
        return ["tariffs": .array(list), "current": byKind[MeterKind.electricity.rawValue] ?? .null, "currentByKind": .object(byKind),
                "meterKinds": .array(kinds.map { .string($0.rawValue) })]
    }

    /// Writes the Tariffs (`bridge.tariffs`, sorted by their first day; an empty list removes them), checked first
    /// (`Tariff.problems`). No restart: the bridge's identity does not change.
    public func updateTariffs(_ tariffs: JSONValue, dryRun: Bool = false) async throws -> JSONValue {
        guard let list = tariffs.arrayValue, let decoded = try? tariffs.decode([Tariff].self) else {
            throw CatalogError("tariffs must be a list of Tariffs: start (YYYY-MM-DD), currency, periods (from, to, price, days), exportPrice, kind (electricity, gas or water)")
        }
        let problems = Tariff.problems(decoded)
        guard problems.isEmpty else { throw CatalogError(problems.joined(separator: "; ")) }
        let sorted = zip(list, decoded).sorted { ($0.1.start, $0.1.kind.order) < ($1.1.start, $1.1.kind.order) }.map(\.0)
        let current = try readConfig()
        var root = current.objectValue ?? [:]
        var bridge = root["bridge"]?.objectValue ?? [:]
        if sorted.isEmpty { bridge.removeValue(forKey: "tariffs") } else { bridge["tariffs"] = .array(sorted) }
        root["bridge"] = .object(bridge)
        return try await applyConfig(.object(root), dryRun: dryRun, current: current)
    }
}
