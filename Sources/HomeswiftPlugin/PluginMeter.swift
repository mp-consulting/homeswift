import Foundation
import Homeswift

/// A Meter a plugin declares for readings no characteristic carries (an inverter's solar, a meter's Returned energy, a
/// battery system's flows), made by `PluginContext.meter`. The bridge keeps its Consumption and Returned by the hour as
/// it does an accessory's Total Consumption; with an Energy Role (the person's, else the plugin's suggestion), its
/// power also counts in the Home Energy.
///
/// Power is in watts with the signs of the Meter's suggested role, as `EnergyRole` gives them: a solar array's
/// production above zero (its Returned energy), a grid connection's import above zero and export below, a battery's
/// charge above zero and discharge below, anything else's use above zero. Counters are in watt-hours and only go up,
/// but for a reset.
///
/// A gas or water Meter (`kind`) is read in m³: `record(cubicMetres:)` for its counter, `MeterHourImport(start:cubicMetres:)`
/// for its past. It has no power and no Energy Role, and never counts in the Home Energy.
public struct PluginMeter: Sendable {
    public let id: MeterID
    /// What it measures.
    public let kind: MeterKind
    let description: MeterDescription
    let readings: @Sendable (MeterReading) -> Void

    init(id: MeterID, kind: MeterKind = .electricity, description: MeterDescription, readings: @escaping @Sendable (MeterReading) -> Void) {
        self.id = id
        self.kind = kind
        self.description = description
        self.readings = readings
        if kind != .electricity { readings(.kind(id, kind)) }
    }

    /// A power reading, in watts; nothing for a gas or water Meter.
    public func record(watts: Double) {
        guard watts.isFinite, kind == .electricity else { return }
        // On the Meter, production is sent back.
        readings(.power(id, description.suggestedRole == .solar ? -watts : watts, Date(), description))
    }

    /// A counter's reading, in watt-hours (litres for a gas or water Meter: `record(cubicMetres:)` says it in m³).
    public func record(counter wattHours: Double, direction: MeterDirection = .consumption) {
        guard wattHours.isFinite else { return }
        readings(.counter(id, wattHours, direction, Date()))
    }

    /// A gas or water meter's index, in m³, as its counter reads now.
    public func record(cubicMetres: Double) {
        guard cubicMetres.isFinite, kind != .electricity else { return }
        readings(.counter(id, cubicMetres * 1000, .consumption, Date()))
    }

    /// Hours of its past from the device's or the cloud's record (a meter's per-minute records, a cloud's history), in
    /// watt-hours drawn (`consumption`) and sent back or produced (`returned`): each replaces what was imported for that
    /// hour before, and an hour the bridge measured keeps its own figures. With an Energy Role, they fill the Home
    /// Energy's long-term history too, where the bridge recorded nothing.
    public func importHours(_ hours: [MeterHourImport]) {
        let known = hours.filter { [$0.consumption, $0.returned].allSatisfy { $0.map(\.isFinite) ?? true } }
        guard !known.isEmpty else { return }
        readings(.history(id, known, description))
    }
}

extension PluginContext {
    /// Takes over the Meter of one of its services (a power meter service with Total Consumption or Current
    /// Consumption, which the bridge would read on its own): its readings come from this `PluginMeter` instead, with the
    /// power's sign, a counter of Returned energy, or a figure the characteristics cannot carry (several phases added up).
    /// The Meter keeps the service's key (`<uuid>/<subtype>`), so its history and Energy Role stay. Take it over before
    /// the accessory is added.
    public func meter(of service: Service, accessoryID: String, device: String, suggestedRole: EnergyRole? = nil, shared: String? = nil,
                      series: String? = nil) -> PluginMeter {
        let id = MeterID(accessory: accessoryID, meter: "\(service.type.uuid)/\(service.subtype ?? "")")
        meterSink(.claim(id))
        return PluginMeter(
            id: id,
            description: MeterDescription(device: device, suggestedRole: suggestedRole, shared: shared,
                                          series: self.series(series ?? "\(AccessoryNaming.deviceID(of: accessoryID, platform: platform)):\(id.meter)").name),
            readings: meterSink)
    }

    /// Declares a Meter of the device `deviceID` (its accessory is `<platform>:<deviceID>`), `key` naming it among the
    /// device's Meters for as long as the device is there. `device` is the name the Status page shows it by;
    /// `suggestedRole` its Energy Role in the Home Energy (solar, home, grid or battery; nil for none, a single device's
    /// use), which a person may change; `shared` for a figure several devices report alike (`EnergyTag.shared`). Its
    /// power in the Home Energy is recorded as the series `plugin:<platform>:<series>`, `<deviceID>:<key>` unless
    /// `series` names it otherwise (a plugin keeping the name it recorded before).
    /// `kind` is what it measures: electricity (the default), or gas or water in m³, which HAP has no characteristics
    /// for, so only plugins feed them; those take no Energy Role.
    public func meter(_ key: String, deviceID: String, device: String, kind: MeterKind = .electricity, suggestedRole: EnergyRole? = nil, shared: String? = nil,
                      series: String? = nil) -> PluginMeter {
        PluginMeter(
            id: MeterID(accessory: "\(platform):\(deviceID)", meter: key), kind: kind,
            description: MeterDescription(device: device, suggestedRole: kind == .electricity ? suggestedRole : nil, shared: shared,
                                          series: self.series(series ?? "\(deviceID):\(key)").name),
            readings: meterSink)
    }
}
