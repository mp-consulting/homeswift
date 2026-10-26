import Foundation
import Homeswift
import HomeswiftAI

/// Homeswift's opt-in daily white-temperature schedule, independent of HomeKit Adaptive Lighting.
/// Only services without an AdaptiveLightingController use this scheduler.
public actor NaturalLighting {
    struct Setting: Codable, Sendable {
        var accessory: String
        var service: String
        var timeZone: String
        var paused = false
        /// The same light (accessory and service), whatever its settings.
        func matches(_ other: Setting) -> Bool { accessory == other.accessory && service == other.service }
    }
    nonisolated let settings: JSONFileStore<[Setting]>
    private var observers: [String: [(Characteristic, Int)]] = [:]
    private var expected: [String: Int] = [:]
    private var busy = false
    private var suspended: Set<String> = []
    private var generations: [String: UUID] = [:]
    private var errors: [String: String] = [:]

    init(directory: URL) {
        settings = JSONFileStore(url: directory.appendingPathComponent("natural-lighting.json")) { [] }
    }

    static func key(_ service: Service) -> String { service.subtype ?? service.type.name }
    static func eligible(_ service: Service) -> Bool {
        service.type.uuid == ServiceType.lightbulb.uuid && service.adaptiveLighting == nil &&
        service[.colorTemperature]?.type.permissions.contains(.pairedWrite) == true
    }
    private func identity(_ entry: Setting) -> String { "\(entry.accessory.utf8.count):\(entry.accessory)\(entry.service)" }
    /// Whether `entry`'s light is still set and not paused in the saved settings.
    private func isActive(_ entry: Setting) -> Bool { settings.value.contains { $0.matches(entry) && !$0.paused } }

    public nonisolated func json(for accessory: String) -> JSONValue? {
        let entries = settings.value.filter { $0.accessory == accessory }
        guard !entries.isEmpty else { return nil }
        return .object(Dictionary(entries.map { ($0.service, JSONValue.object([
            "enabled": true, "paused": .bool($0.paused), "timeZone": .string($0.timeZone)
        ])) }, uniquingKeysWith: { _, last in last }))
    }

    /// Smooth interpolation of a fixed daily curve in the user's time zone, including DST.
    static func mireds(at date: Date, timeZone: TimeZone, minimum: Double, maximum: Double) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        let curve: [(Double, Double)] = [(0, 2200), (6, 2200), (9, 4000), (12, 5000), (15, 5000), (18, 3500), (21, 2200), (24, 2200)]
        let index = (1..<curve.count).first { hour <= curve[$0].0 } ?? curve.count - 1
        let (start, warm) = curve[index - 1], (end, cool) = curve[index]
        let kelvin = warm + (cool - warm) * (hour - start) / (end - start)
        return Int(max(minimum, min(maximum, (1_000_000 / kelvin).rounded())))
    }

    public func configure(_ located: HomeswiftCatalog.Located, service name: String?, on: Bool, timeZone: String, catalog: HomeswiftCatalog) async throws -> JSONValue {
        guard TimeZone(identifier: timeZone) != nil else { throw CatalogError("invalid time zone") }
        let characteristic = try catalog.characteristic(in: located, service: name, characteristic: "Color Temperature")
        guard let service = located.accessory.services.first(where: { $0[.colorTemperature] === characteristic }), Self.eligible(service) else {
            throw CatalogError("this light does not support Homeswift Natural Lighting")
        }
        let entry = Setting(accessory: located.accessory.id, service: Self.key(service), timeZone: timeZone)
        let key = identity(entry)
        try settings.update { entries in
            entries.removeAll { $0.matches(entry) }
            if on { entries.append(entry) }
        }
        expected[key] = nil
        suspended.remove(key)
        unwatch(key)
        errors[key] = nil
        // Its own light only, and not through `tick`: a minute tick still writing other lamps would skip it.
        if on {
            watch(service, entry: entry)
            await apply(entry, catalog: catalog, at: Date())
        }
        if let error = errors[key] {
            pause(entry)
            throw CatalogError(error)
        }
        characteristic.sendEvent(characteristic.value)
        return json(for: entry.accessory) ?? [:]
    }

    private func unwatch(_ key: String) {
        generations[key] = nil
        for (characteristic, token) in observers.removeValue(forKey: key) ?? [] { characteristic.removeObserver(token) }
    }

    private func watch(_ service: Service, entry: Setting) {
        let key = identity(entry)
        if observers[key]?.first?.0 === service[.colorTemperature] { return }
        unwatch(key)
        let context = ObjectIdentifier(self)
        let generation = UUID()
        generations[key] = generation
        observers[key] = [CharacteristicType.colorTemperature, .hue, .saturation].compactMap { type in
            guard let characteristic = service[type] else { return nil }
            let token = characteristic.observe { [weak self] change in
                // Device echoes/reads are not manual writes. In particular a temperature write can also
                // update Hue and Saturation. Check external temperature drift separately on each tick.
                guard case .write = change.reason, change.context != context else { return }
                Task { await self?.pauseIfCurrent(entry, generation: generation) }
            }
            return (characteristic, token)
        }
    }

    private func pauseIfCurrent(_ entry: Setting, generation: UUID) {
        guard generations[identity(entry)] == generation else { return }
        pause(entry)
    }

    private func pause(_ entry: Setting) {
        suspended.insert(identity(entry))
        guard isActive(entry) else { return }
        do {
            try settings.update { entries in
                if let index = entries.firstIndex(where: { $0.matches(entry) }) {
                    entries[index].paused = true
                }
            }
            if let characteristic = observers[identity(entry)]?.first?.0 { characteristic.sendEvent(characteristic.value) }
        } catch { errors[identity(entry)] = "could not save Natural Lighting pause: \(error)" }
    }

    /// Called before manual UI/MCP writes, so a concurrent tick cannot start another scheduled write. Answers the
    /// lights it paused, for `resume` when the write fails.
    @discardableResult
    func pause(_ located: HomeswiftCatalog.Located, characteristic: Characteristic) -> [Setting] {
        guard [CharacteristicType.colorTemperature.uuid, CharacteristicType.hue.uuid, CharacteristicType.saturation.uuid].contains(characteristic.type.uuid) else { return [] }
        var paused: [Setting] = []
        for entry in settings.value where entry.accessory == located.accessory.id {
            guard located.accessory.services.contains(where: { Self.key($0) == entry.service && $0.characteristics.contains { $0 === characteristic } }) else { continue }
            if isActive(entry), !suspended.contains(identity(entry)) { paused.append(entry) }
            pause(entry)
        }
        return paused
    }

    /// A manual write that failed changed nothing: the lights it paused follow the schedule again.
    func resume(_ entries: [Setting]) {
        guard !entries.isEmpty else { return }
        do {
            try settings.update { saved in
                for index in saved.indices where entries.contains(where: { $0.matches(saved[index]) }) { saved[index].paused = false }
            }
        } catch { return }
        for entry in entries {
            suspended.remove(identity(entry))
            if let characteristic = observers[identity(entry)]?.first?.0 { characteristic.sendEvent(characteristic.value) }
        }
    }

    /// Whether the light moved away from the temperature last written, beyond what a device's rounding explains:
    /// lamps quantise to their own kelvin steps (often 50 or 100 K), which is many mireds at the warm end.
    static func drifted(_ current: Int, from expected: Int) -> Bool {
        guard current > 0, expected > 0 else { return current != expected }
        return abs(1_000_000 / Double(current) - 1_000_000 / Double(expected)) > 100
    }

    func tick(_ catalog: HomeswiftCatalog, at now: Date) async {
        guard !busy, !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        for entry in settings.value {
            guard !Task.isCancelled else { return }
            await apply(entry, catalog: catalog, at: now)
        }
    }

    /// Writes the curve's temperature to one light, unless it is off, paused, unreachable or changed by someone else.
    private func apply(_ entry: Setting, catalog: HomeswiftCatalog, at now: Date) async {
        // Re-read after every awaited device write: a user may have disabled or paused another lamp meanwhile.
        guard !suspended.contains(identity(entry)), isActive(entry) else { return }
        guard !Task.isCancelled, let located = catalog.find(id: entry.accessory), !located.accessory.isUnavailable,
              located.platform?.paused != true,
              let service = located.accessory.services.first(where: { Self.key($0) == entry.service && Self.eligible($0) }),
              let temperature = service[.colorTemperature], let zone = TimeZone(identifier: entry.timeZone) else { return }
        watch(service, entry: entry)
        guard service[.on]?.value.boolValue == true else { return }
        let key = identity(entry)
        // If another controller changed the white temperature, stop competing with it.
        if let last = expected[key], let current = temperature.value.intValue, Self.drifted(current, from: last) {
            pause(entry)
            return
        }
        let target = Self.mireds(at: now, timeZone: zone, minimum: temperature.type.minValue ?? 140, maximum: temperature.type.maxValue ?? 500)
        if expected[key] != nil, temperature.value.intValue == target { return }
        do {
            try await temperature.write(.int(target), context: ObjectIdentifier(self))
            expected[key] = target
            errors[key] = nil
        } catch {
            errors[key] = HomeswiftCatalog.failure((error as? HAPStatusError) ?? HAPStatusError(.serviceCommunicationFailure), of: located).description
            // A failed write does not establish an expected colour; try again on the next tick.
            expected[key] = nil
            catalog.logger.warning("Natural Lighting could not update a light", metadata: ["accessory": "\(located.accessory.name)", "error": "\(error)"])
        }
    }
}
