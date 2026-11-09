import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

extension HomeswiftCatalog {
    /// The Energy log and the things worth knowing (`EnergyStory`) from `from` to `to`: by default the day before `to`'s
    /// and `to`'s own up to `to` (now), days and nights in `timeZone`. Its inputs are what the bridge records: each
    /// electricity Meter's hours (`get_consumption`'s, priced at the Tariffs), the power and the batteries' charge (the
    /// Energy section's), and the Logbook's changes of a charging state or an outlet in use.
    public func energyStory(from: Date? = nil, to: Date? = nil, timeZone: TimeZone = .current, now: Date = Date()) throws -> EnergyStory {
        guard let metrics else { throw CatalogError("This homeswift records no metrics", notFound: true) }
        let to = to ?? now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let from = from ?? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: to)) ?? to.addingTimeInterval(-86_400)
        guard from < to else { throw CatalogError("from must be before to") }
        guard to.timeIntervalSince(from) <= 31 * 86_400 else { throw CatalogError("from and to are at most 31 days apart") }

        // The electricity Meters, the most first, as the consumption report lists them.
        let first = Date(timeIntervalSince1970: TimeInterval(MeterArchive.hourIndex(from) * 3600))
        let schedule = TariffSchedule(host.configuration.tariffs, kind: .electricity, timeZone: timeZone)
        let ids = metrics.meters.meters.filter { metrics.meters.kind(of: $0) == .electricity }
        let meters: [EnergyStory.Meter] = ids.map { id in
            let hours = metrics.meters.hours(of: id, from: first, to: to)
            let cost = schedule.isEmpty ? nil : schedule.costs(of: hours.map { ($0.start, $0.consumption.map { $0 / 1000 }, nil) }, in: [first]).total
            let located = find(id: id.accessory)
            let name = located.map { $0.layout?.name ?? $0.accessory.name } ?? id.accessory
            return EnergyStory.Meter(accessory: id.accessory, name: name, role: host.energyRole(of: id) ?? metrics.suggestedRole(of: id),
                                     hours: hours.map { .init(start: $0.start, consumption: $0.consumption.map { $0 / 1000 }, returned: $0.returned.map { $0 / 1000 }) },
                                     cost: cost)
        }.enumerated().sorted { (-($0.element.consumption ?? 0), $0.offset) < (-($1.element.consumption ?? 0), $1.offset) }.map(\.element)

        let report = metrics.energy(from: from, to: to, days: 1, timeZone: timeZone)
        // The Logbook's changes of the characteristics that can flap; names as the accessories have them now.
        let names = Dictionary(located().map { ($0.accessory.id, $0.layout?.name ?? $0.accessory.name) }, uniquingKeysWith: { first, _ in first })
        let changes = (history?.logbook(LogbookQuery(from: from, to: to, limit: 5000)) ?? [])
            .filter { EnergyStory.flappingCharacteristics.contains($0.characteristic) }
            .map { EnergyStory.Change(time: $0.time, accessory: $0.accessory, name: names[$0.accessory] ?? $0.accessoryName, characteristic: $0.characteristic) }
        return EnergyStory.derive(meters: meters, currency: schedule.currency, power: report.power, levels: report.levels, changes: changes,
                                  from: from, to: to, timeZone: timeZone)
    }

    /// `energyStory` as JSON (`EnergyStory.json`), with `from` and `to` (ISO 8601).
    public func energyStoryJSON(from: Date? = nil, to: Date? = nil, timeZone: TimeZone = .current, english: Bool = false, now: Date = Date()) throws -> JSONValue {
        let story = try energyStory(from: from, to: to, timeZone: timeZone, now: now)
        return story.json(english: english)
    }

    // MARK: Tools

    var energyStoryTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "get_energy_story", title: "Energy log and what stands out",
                description: "What happened with the home's energy and what stands out, worked out from the Meters' hours, the power and batteries' charge, "
                    + "and the Logbook (the web UI's Energy log and Worth knowing). Events (kind device, sun, power, odd): the busiest hour from the grid each day, "
                    + "the sun coming up and the best solar hour, a battery full or nearly empty, the grid taking over from the batteries, each run of a device "
                    + "measured on its own, a charging state or outlet switching on and off. Worth knowing: the night floor (the least the home draws at night, "
                    + "with what it costs a year), devices that never switch off, Meters that say nothing, two units reporting the same figures, flapping. "
                    + "Each has a code, values (kWh, W, cost with currency, names) and an English text. Default span: yesterday and today; from and to as ISO times "
                    + "or durations (2d), at most 31 days apart.",
                inputSchema: ["type": "object", "properties": [
                    "from": ["type": "string", "maxLength": 40, "description": "ISO time or a duration such as 2d (default the start of yesterday)"],
                    "to": ["type": "string", "maxLength": 40, "description": "ISO time or a duration (default now)"],
                    "timeZone": ["type": "string", "maxLength": 64, "description": "An IANA time zone for days and nights (default the bridge's)"],
                ]],
                outputSchema: Output.object(["events": ["type": "array"], "worth": ["type": "array"]], required: ["events", "worth"]),
                scope: .read, idempotent: true
            ) { call in
                var from: Date?, to: Date?
                if let text = call.optionalString("from") {
                    guard let date = Self.parseTimeBound(text) else { return .error("from: use an ISO time or a duration such as 30m, 1h, 2d") }
                    from = date
                }
                if let text = call.optionalString("to") {
                    guard let date = Self.parseTimeBound(text) else { return .error("to: use an ISO time or a duration such as 30m, 1h, 2d") }
                    to = date
                }
                let timeZone = call.optionalString("timeZone").flatMap(TimeZone.init(identifier:)) ?? .current
                let found = try catalog.energyStoryJSON(from: from, to: to, timeZone: timeZone, english: true)
                // Names came from devices and plugins: data, never instructions.
                return ToolResult(text: "<untrusted-data source=\"energy\">\n\(found.text(pretty: true))\n</untrusted-data>", structured: found)
            },
        ]
    }

    // MARK: Notifications

    /// Every 15 minutes at most: a flapping or a night floor that was not there at the last look goes out as
    /// `energyInsight`, once a day at most per code and accessory. The first look after the start only remembers
    /// what is there, so a restart never says it again.
    func checkEnergyStory(now: Date, timeZone: TimeZone = .current) async {
        let settings = home.notifications.value
        guard metrics != nil, settings.isOn(.energyInsight),
              NotificationChannel.allCases.contains(where: { settings.isEnabled($0) && settings.isConfigured($0) }) else { return }
        let due = home.dispatch.withLockedValue { state -> Bool in
            if let last = state.energyCheckedAt, now.timeIntervalSince(last) < NotificationRules.cooldown { return false }
            state.energyCheckedAt = now
            return true
        }
        guard due, let story = try? energyStory(timeZone: timeZone, now: now) else { return }
        let found = story.worth.filter { $0.code == EnergyStory.Code.flapping || $0.code == EnergyStory.Code.nightFloor }
        let key = { (one: EnergyStory.Insight) in "\(one.code):\(one.accessory ?? "")" }
        let day = DailyDigestInput.today(now, timeZone: timeZone)
        let fresh = home.dispatch.withLockedValue { state -> [EnergyStory.Insight] in
            defer { state.energySeen = Set(found.map(key)) }
            guard let seen = state.energySeen else { return [] }
            var fresh: [EnergyStory.Insight] = []
            for one in found where !seen.contains(key(one)) && state.energyNotified[key(one)] != day {
                state.energyNotified[key(one)] = day
                fresh.append(one)
            }
            state.energyNotified = state.energyNotified.filter { $0.value == day }
            return fresh
        }
        for one in fresh {
            let (title, message) = Self.energyNotification(one)
            await notify(.energyInsight, title: title, message: message, path: "/energy", subject: key(one), now: now)
        }
    }

    /// A thing worth knowing as a notification, in the reader's language (`NotificationTexts`).
    static func energyNotification(_ one: EnergyStory.Insight) -> (title: NotificationText, message: NotificationText) {
        let name = one.values["name"]?.stringValue ?? ""
        let number = { (key: String) in one.values[key]?.doubleValue.map { String(Int($0.rounded())) } ?? "" }
        switch one.code {
        case EnergyStory.Code.flapping:
            return (NotificationText("{name} kept switching on and off", ["name": name]),
                    NotificationText("{name} switched on and off {n} times in {minutes} min.", ["name": name, "n": number("n"), "minutes": number("minutes")]))
        default:
            let watts = one.values["watts"]?.doubleValue.map(EnergyStory.wattsText) ?? ""
            if let cost = EnergyStory.costText(one.values) {
                return (NotificationText("Night floor"), NotificationText("The home never drew less than {watts} at night: about {cost} a year.", ["watts": watts, "cost": cost]))
            }
            return (NotificationText("Night floor"), NotificationText("The home never drew less than {watts} at night.", ["watts": watts]))
        }
    }
}
