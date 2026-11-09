import Foundation
import HomeswiftAI

/// The Energy log and the things worth knowing about a span (two days on the Status page): what happened, hour by hour,
/// and what stands out, worked out from what the bridge records. Each Meter's hours (`MeterArchive`), the power and the
/// batteries' charge (`Metrics.energy`), and the Logbook's changes of a charging state or an outlet in use.
///
/// Nothing here is a sentence: each event and each thing worth knowing is a `code` with its `values` (kWh, W, an
/// amount of money with its currency, a name), which the web UI words in the reader's language and `get_energy_story`
/// in English (`english`).
public struct EnergyStory: Sendable, Equatable {
    /// What an event is about, as the Energy log filters it.
    public enum Kind: String, Sendable, Codable {
        case device, sun, power, odd, bridge
    }

    public enum Severity: String, Sendable, Codable {
        case info, warning
    }

    /// Something that happened at a time: the grid's busiest hour, the sun coming up, a battery full, a device's run.
    public struct Event: Sendable, Equatable {
        public var at: Date
        public var kind: Kind
        public var code: String
        public var values: [String: JSONValue]
        /// The accessory it is about, when it is one.
        public var accessory: String?
    }

    /// Something that stands out over the span: the night floor, a device always on, Meters that say nothing.
    public struct Insight: Sendable, Equatable {
        public var code: String
        public var values: [String: JSONValue]
        public var accessory: String?
        public var severity: Severity
    }

    /// A Meter (electricity) over the span: its known hours in kWh, its totals, and what its Consumption cost.
    public struct Meter: Sendable {
        public struct Hour: Sendable {
            public var start: Date
            /// kWh; nil when the hour is known but this direction is not.
            public var consumption: Double?
            public var returned: Double?

            public init(start: Date, consumption: Double?, returned: Double? = nil) {
                self.start = start
                self.consumption = consumption
                self.returned = returned
            }
        }

        public var accessory: String
        public var name: String
        /// Its Energy Role; nil for one device measured on its own.
        public var role: EnergyRole?
        /// The hours with anything known, oldest first.
        public var hours: [Hour]
        /// The span's Consumption and Returned in kWh, nil when nothing is known; its Consumption's cost at the Tariffs.
        public var consumption: Double?
        public var returned: Double?
        public var cost: Double?

        public init(accessory: String, name: String, role: EnergyRole?, hours: [Hour], consumption: Double? = nil, returned: Double? = nil, cost: Double? = nil) {
            self.accessory = accessory
            self.name = name
            self.role = role
            self.hours = hours
            self.consumption = consumption ?? hours.compactMap(\.consumption).reduce(nil as Double?) { ($0 ?? 0) + $1 }
            self.returned = returned ?? hours.compactMap(\.returned).reduce(nil as Double?) { ($0 ?? 0) + $1 }
            self.cost = cost
        }
    }

    /// A change of a characteristic from the Logbook: its accessory, the accessory's name and the characteristic's
    /// (`Charging State`, `Outlet In Use`).
    public struct Change: Sendable {
        public var time: Date
        public var accessory: String
        public var name: String
        public var characteristic: String

        public init(time: Date, accessory: String, name: String, characteristic: String) {
            self.time = time
            self.accessory = accessory
            self.name = name
            self.characteristic = characteristic
        }
    }

    /// The events, oldest first, and the things worth knowing (five at most, the unusual first).
    public var events: [Event]
    public var worth: [Insight]

    /// The codes, as `values` carry them (docs/ui.md, "Energy").
    public enum Code {
        public static let busiestGridHour = "busiestGridHour"
        public static let sunUp = "sunUp"
        public static let bestSolarHour = "bestSolarHour"
        public static let batteryFull = "batteryFull"
        public static let batteryLow = "batteryLow"
        public static let gridTookOver = "gridTookOver"
        public static let deviceRan = "deviceRan"
        public static let flapping = "flapping"
        public static let nightFloor = "nightFloor"
        public static let alwaysOn = "alwaysOn"
        public static let silentMeters = "silentMeters"
        public static let countedTwice = "countedTwice"
    }

    /// The characteristics whose flipping back and forth stands out.
    public static let flappingCharacteristics: Set<String> = ["Charging State", "Outlet In Use"]

    /// Works out the story of `from` to `to`, days and nights counted in `timeZone`.
    ///
    /// `meters` are the electricity Meters in the order the consumption report lists them (the most first): a role's
    /// hours come from the first of its Meters with figures, as a system read through several units says the same.
    /// `currency` is electricity's Tariffs'; the price of a kWh is the grid Meter's cost over its Consumption.
    public static func derive(meters: [Meter], currency: String?, power: [EnergyReport.PowerPoint], levels: [EnergyReport.Level],
                              changes: [Change], from: Date, to: Date, timeZone: TimeZone) -> EnergyStory {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var events: [Event] = [], worth: [Insight] = []
        typealias Point = (at: Date, value: Double)

        func points(_ meter: Meter?, _ field: KeyPath<Meter.Hour, Double?>) -> [Point] {
            (meter?.hours ?? []).compactMap { hour in hour[keyPath: field].map { (hour.start, $0) } }
        }
        func role(_ name: EnergyRole, _ field: KeyPath<Meter.Hour, Double?>) -> [Point] {
            points(meters.first { $0.role == name && $0.hours.contains { $0[keyPath: field] != nil } }, field)
        }
        let grid = role(.grid, \.consumption), solar = role(.solar, \.returned), home = role(.home, \.consumption)
        let price: (per: Double, currency: String)? = meters.first { $0.role == .grid && $0.cost != nil && ($0.consumption ?? 0) > 0 }
            .flatMap { meter in currency.map { ((meter.cost ?? 0) / (meter.consumption ?? 1), $0) } }
        func top(_ list: [Point]) -> Point { list.dropFirst().reduce(list[0]) { $1.value > $0.value ? $1 : $0 } }
        func cost(_ kWh: Double, into values: inout [String: JSONValue]) {
            guard let price else { return }
            values["cost"] = .number(money(kWh * price.per))
            values["currency"] = .string(price.currency)
        }

        // Each day of the span: the busiest hour from the grid, the sun coming up and the best solar hour.
        var day = calendar.startOfDay(for: from)
        while day <= to {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let of = { (list: [Point]) in list.filter { $0.at >= day && $0.at < next } }
            let imported = of(grid)
            if !imported.isEmpty {
                let busiest = top(imported)
                if busiest.value >= 0.3 {
                    var values: [String: JSONValue] = ["value": .number(kWh(busiest.value))]
                    cost(busiest.value, into: &values)
                    events.append(Event(at: busiest.at, kind: .power, code: Code.busiestGridHour, values: values))
                }
            }
            let sun = of(solar)
            // Sun up: the first productive hour after a dark one the bridge knows, not the first hour it happens to know.
            if let up = sun.indices.first(where: { index in
                index > 0 && sun[index].value >= 0.015 && sun[index - 1].value < 0.015 && sun[index].at.timeIntervalSince(sun[index - 1].at) <= 3600
            }) {
                events.append(Event(at: sun[up].at, kind: .sun, code: Code.sunUp, values: ["value": .number(kWh(sun[up].value))]))
            }
            if !sun.isEmpty, top(sun).value >= 0.05 {
                let best = top(sun)
                events.append(Event(at: best.at, kind: .sun, code: Code.bestSolarHour,
                                    values: ["value": .number(kWh(best.value)), "total": .number(kWh(sun.reduce(0) { $0 + $1.value }))]))
            }
            day = next
        }

        // The night floor: the least the home drew in a night hour (midnight to five), what never stops at all.
        let use = home.isEmpty ? grid : home
        let nights = use.filter { calendar.component(.hour, from: $0.at) < 5 }
        if nights.count >= 3, let floor = nights.map(\.value).min(), floor >= 0.1 {
            var values: [String: JSONValue] = ["watts": .number(watts(floor * 1000))]
            cost(floor * 8760, into: &values)
            worth.append(Insight(code: Code.nightFloor, values: values, severity: .info))
        }

        // The batteries: full, and nearly empty, each time the charge gets there.
        for level in levels {
            var before: Double?
            for point in level.points {
                let percent = (point.percent * 10).rounded() / 10
                if let before, before < 99, percent >= 99 {
                    events.append(Event(at: point.start, kind: .power, code: Code.batteryFull, values: ["name": .string(level.device)]))
                }
                if let before, before > 10, percent <= 10 {
                    events.append(Event(at: point.start, kind: .power, code: Code.batteryLow, values: ["name": .string(level.device)]))
                }
                before = percent
            }
        }

        // The batteries stopping while the home still draws: the grid takes over.
        var discharging = false
        for point in power where !point.imported {
            let battery = point.watts[.battery] ?? 0, imported = point.watts[.grid] ?? 0
            if battery < -150 {
                discharging = true
            } else if discharging, battery > -30, imported > 300 {
                discharging = false
                events.append(Event(at: point.start, kind: .power, code: Code.gridTookOver, values: ["watts": .number(watts(imported))]))
            }
        }

        // The devices measured on their own: each run well above their own quiet hours, and a device that never stops.
        var silent: [String] = []
        for meter in meters where meter.role == nil {
            let hours = points(meter, \.consumption)
            // No hour with a figure: a Meter that says nothing.
            guard let quiet = hours.map(\.value).min(), let loud = hours.map(\.value).max() else {
                silent.append(meter.name)
                continue
            }
            if quiet > 0.003, loud < quiet * 2, hours.count >= 12 {
                let average = hours.reduce(0) { $0 + $1.value } / Double(hours.count) * 1000
                var values: [String: JSONValue] = ["name": .string(meter.name), "watts": .number(watts(average))]
                cost(average / 1000 * 8760, into: &values)
                worth.append(Insight(code: Code.alwaysOn, values: values, accessory: meter.accessory, severity: .info))
                continue
            }
            let threshold = max(0.05, quiet * 3)
            var run: [Point] = []
            func close() {
                guard let first = run.first else { return }
                let used = run.reduce(0) { $0 + $1.value }
                var values: [String: JSONValue] = ["name": .string(meter.name), "n": .number(Double(run.count)), "value": .number(kWh(used))]
                cost(used, into: &values)
                events.append(Event(at: first.at, kind: .device, code: Code.deviceRan, values: values, accessory: meter.accessory))
                run = []
            }
            for hour in hours {
                if hour.value >= threshold { run.append(hour) } else { close() }
            }
            close()
        }
        if !silent.isEmpty {
            worth.append(Insight(code: Code.silentMeters, values: ["names": .array(silent.map(JSONValue.string)), "n": .number(Double(silent.count))], severity: .info))
        }

        // Two units of one system reporting the same figures: counted twice wherever both are added up.
        for (name, field) in [(EnergyRole.solar, \Meter.returned), (.grid, \Meter.consumption)] {
            // The first pair of a role says it: three units of one system are one thing worth knowing, not three.
            let same = meters.filter { $0.role == name && ($0[keyPath: field] ?? 0) > 0 }
            let pair = same.indices.lazy.flatMap { i in same.indices.lazy.filter { $0 > i }.map { (same[i], same[$0]) } }.first { a, b in
                let (x, y) = (a[keyPath: field] ?? 0, b[keyPath: field] ?? 0)
                return a.accessory != b.accessory && abs(x - y) <= 0.03 * max(x, y)
            }
            if let (a, b) = pair {
                worth.append(Insight(code: Code.countedTwice, values: ["first": .string(a.name), "second": .string(b.name)], severity: .info))
            }
        }

        // A charging state or an outlet flipping back and forth: six changes or more within a quarter of an hour.
        var flips: [(accessory: String, characteristic: String, name: String, times: [Date])] = []
        for change in changes where flappingCharacteristics.contains(change.characteristic) {
            if let index = flips.firstIndex(where: { $0.accessory == change.accessory && $0.characteristic == change.characteristic }) {
                flips[index].times.append(change.time)
            } else {
                flips.append((change.accessory, change.characteristic, change.name, [change.time]))
            }
        }
        for flip in flips {
            let times = flip.times.sorted()
            var i = 0
            while i + 5 < times.count {
                defer { i += 1 }
                guard times[i + 5].timeIntervalSince(times[i]) <= 900 else { continue }
                var last = i + 5
                while last + 1 < times.count, times[last + 1].timeIntervalSince(times[i]) <= 900 { last += 1 }
                let count = last - i + 1, minutes = max(1, Int((times[last].timeIntervalSince(times[i]) / 60).rounded()))
                let values: [String: JSONValue] = ["name": .string(flip.name), "n": .number(Double(count)), "minutes": .number(Double(minutes))]
                worth.insert(Insight(code: Code.flapping, values: values, accessory: flip.accessory, severity: .warning), at: 0)
                events.append(Event(at: times[last], kind: .odd, code: Code.flapping, values: values, accessory: flip.accessory))
                break
            }
        }

        let shown = events.enumerated().filter { $0.element.at >= from && $0.element.at <= to }
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        return EnergyStory(events: shown, worth: Array(worth.prefix(5)))
    }

    /// kWh to a thousandth, watts to a watt, money to a hundredth.
    static func kWh(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    static func watts(_ value: Double) -> Double { value.rounded() }
    static func money(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: JSON and English

    /// `{ events: [{ at, kind, code, values, accessory? }], worth: [{ code, values, accessory?, severity }] }`, `at` in
    /// ISO 8601; `english` adds each one's English sentence as `text`.
    public func json(english: Bool = false) -> JSONValue {
        [
            "events": .array(events.map { event in
                var object: [String: JSONValue] = ["at": .string(Timestamp.iso8601(event.at)), "kind": .string(event.kind.rawValue),
                                                   "code": .string(event.code), "values": .object(event.values)]
                if let accessory = event.accessory { object["accessory"] = .string(accessory) }
                if english { object["text"] = .string(Self.english(event.code, event.values, event: true)) }
                return .object(object)
            }),
            "worth": .array(worth.map { one in
                var object: [String: JSONValue] = ["code": .string(one.code), "values": .object(one.values), "severity": .string(one.severity.rawValue)]
                if let accessory = one.accessory { object["accessory"] = .string(accessory) }
                if english { object["text"] = .string(Self.english(one.code, one.values, event: false)) }
                return .object(object)
            }),
        ]
    }

    /// An event or a thing worth knowing in English, as the web UI's English words it.
    public static func english(_ code: String, _ values: [String: JSONValue], event: Bool) -> String {
        let name = values["name"]?.stringValue ?? ""
        let cost = costText(values)
        let energy = values["value"]?.doubleValue.map(kWhText) ?? ""
        let power = values["watts"]?.doubleValue.map(wattsText) ?? ""
        let n = Int(values["n"]?.doubleValue ?? 0), minutes = Int(values["minutes"]?.doubleValue ?? 0)
        switch code {
        case Code.busiestGridHour: return "Busiest hour from the grid: \(energy)" + (cost.map { " (\($0))" } ?? "")
        case Code.sunUp: return "Sun up: first \(energy)"
        case Code.bestSolarHour: return "Best solar hour of the day: \(energy) (\(values["total"]?.doubleValue.map(kWhText) ?? "") in all)"
        case Code.batteryFull: return "\(name) full"
        case Code.batteryLow: return "\(name) nearly empty"
        case Code.gridTookOver: return "The batteries stopped, the grid took over (\(power))"
        case Code.deviceRan: return "\(name) ran \(n) \(n == 1 ? "hour" : "hours") (\(energy)\(cost.map { ", \($0)" } ?? ""))"
        case Code.flapping:
            return event ? "\(name) kept switching on and off (\(n) times in \(minutes) min)" : "\(name) switched on and off \(n) times in \(minutes) min"
        case Code.nightFloor:
            return "The home never drew less than \(power) at night" + (cost.map { ": about \($0) a year" } ?? "")
        case Code.alwaysOn: return "\(name) never switches off: about \(power)" + (cost.map { ", \($0) a year" } ?? "")
        case Code.silentMeters:
            return "No readings over these days: " + (values["names"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
        case Code.countedTwice:
            return "\(values["first"]?.stringValue ?? "") and \(values["second"]?.stringValue ?? "") report the same figures"
        default: return code
        }
    }

    /// kWh with up to three decimals: `0.42 kWh`.
    public static func kWhText(_ value: Double) -> String {
        "\(number(value, digits: value < 10 ? 2 : 1)) kWh"
    }

    /// Watts, as kW from 1 kW: `85 W`, `1.2 kW`.
    public static func wattsText(_ value: Double) -> String {
        abs(value) >= 1000 ? "\(number(value / 1000, digits: 1)) kW" : "\(Int(value.rounded())) W"
    }

    /// An amount with its currency, `12.30 EUR`; nil without one.
    public static func costText(_ values: [String: JSONValue]) -> String? {
        guard let amount = values["cost"]?.doubleValue, let currency = values["currency"]?.stringValue else { return nil }
        return String(format: "%.2f", amount) + " " + currency
    }

    private static func number(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
