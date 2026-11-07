import Foundation
import Homeswift
import HomeswiftPlugin

// The older Roborock-family robots that speak only miIO's vacuum commands (docs/clean-room/XiaomiMiot.md section 8.3),
// in the Roborock plugin's HomeKit shape (8.4): a Fan v2 that cleans, its Battery, and a Filter Maintenance for the
// main brush, the side brush and the filter. The state codes and the cleaning set are docs/clean-room/Roborock.md 5.3's.
final class LegacyVacuumAccessory: @unchecked Sendable {
    /// Roborock.md 5.3: the states that count as cleaning.
    static let cleaningStates = Set([4, 5, 6, 7, 11, 15, 16, 17, 18, 23, 25, 26, 33, 34] + Array(6301...6310))
    static let charging = 8

    /// Roborock.md 5.5: rated hours of each consumable, by its `get_consumable` field.
    static let consumables: [(field: String, subtype: String, name: String, hours: Double)] = [
        ("main_brush_work_time", "main-brush", "Main brush", 300),
        ("side_brush_work_time", "side-brush", "Side brush", 200),
        ("filter_work_time", "filter", "Filter", 150),
    ]

    let accessory: Accessory
    let fan: Service
    let battery: Service
    let filters: [String: Service]

    init(accessoryID: String, name: String, model: String, serialNumber: String, firmware: String, handle: DeviceHandle, extra: [Service]) {
        let battery = Service(.battery, optional: [.batteryLevel, .chargingState])
        var filters: [String: Service] = [:]
        var linked = [battery]
        for consumable in Self.consumables {
            let service = Service(.filterMaintenance, name: consumable.name, subtype: consumable.subtype, optional: [.filterLifeLevel, .configuredName])
            service.characteristic(.configuredName).value = .string(consumable.name)
            filters[consumable.field] = service
            linked.append(service)
        }
        let fan = Service(.fanv2, name: name, extra: [Characteristic(.statusFault, value: .int(0)), Characteristic(.statusActive, value: .bool(true))],
                          linked: linked, isPrimary: true)
        fan.standsFor = .cleaningRobot
        fan.characteristic(.active).onWrite { value in
            if value.intValue == 1 {
                _ = try await handle.raw("app_start", [])
            } else {
                // Stop, then back to the dock (Roborock 6.1).
                _ = try await handle.raw("app_stop", [])
                _ = try await handle.raw("app_charge", [])
            }
        }
        self.fan = fan
        self.battery = battery
        self.filters = filters
        accessory = Accessory(
            id: accessoryID, name: name, manufacturer: MiotAccessoryBuilder.manufacturer(model: model), model: model, serialNumber: serialNumber,
            firmwareRevision: firmware, category: .other, services: [fan] + linked + extra,
            onIdentify: { _ = try await handle.raw("find_me", []) })
    }

    /// A `get_status` result: `[{…}]` or `{…}`.
    static func status(_ result: JSONValue) -> [String: JSONValue]? {
        result.arrayValue?.first?.objectValue ?? result.objectValue
    }

    /// Shows a status: Active from the cleaning set (`in_cleaning`, when present, wins), the fault, the battery.
    func show(status: [String: JSONValue]) {
        let state = status["state"]?.intValue
        if let state { set(fan, .active, .int(Self.cleaningStates.contains(state) ? 1 : 0)) }
        if let inCleaning = status["in_cleaning"]?.doubleValue { set(fan, .active, .int(inCleaning != 0 ? 1 : 0)) }
        if let error = status["error_code"]?.doubleValue { set(fan, .statusFault, .int(error != 0 ? 1 : 0)) }
        if let level = status["battery"]?.doubleValue {
            set(battery, .batteryLevel, .int(Int(saturating: level, in: 0...100) ?? 0))
            set(battery, .statusLowBattery, .int(MiotConversions.isLowBattery(level) ? 1 : 0))
        }
        if let charge = status["charge_status"]?.doubleValue {
            set(battery, .chargingState, .int(charge != 0 || state == Self.charging ? 1 : 0))
        } else if let state {
            set(battery, .chargingState, .int(state == Self.charging ? 1 : 0))
        }
    }

    /// Shows a `get_consumable` result: life % = max(0, round(100 − work time / rated time × 100)).
    func show(consumables result: JSONValue) {
        guard let fields = Self.status(result) else { return }
        for consumable in Self.consumables {
            guard let seconds = fields[consumable.field]?.doubleValue, let service = filters[consumable.field] else { continue }
            let life = max(0, MiotConversions.round(100 - seconds / (consumable.hours * 3600) * 100))
            set(service, .filterLifeLevel, .double(min(life, 100)))
            set(service, .filterChangeIndication, .int(MiotConversions.needsChange(filterLife: life) ? 1 : 0))
        }
    }

    private func set(_ service: Service, _ type: CharacteristicType, _ value: HAPValue) {
        MiotAccessoryBuilder.set(service[type], value)
    }
}
