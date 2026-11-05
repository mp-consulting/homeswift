import Foundation

/// A Meter a plugin declares for readings no characteristic carries (an inverter's solar, a meter's Returned energy, a
/// battery system's flows), made by `PluginContext.meter`. The bridge keeps its Consumption and Returned by the hour as
/// it does an accessory's Total Consumption; with an Energy Role, its power also counts in the Home Energy.
///
/// Power is in watts with the signs of the Meter's suggested role, as `EnergyRole` gives them: a solar array's
/// production above zero (its Returned energy), a grid connection's import above zero and export below, a battery's
/// charge above zero and discharge below, anything else's use above zero. Counters are in watt-hours and only go up,
/// but for a reset.
public struct PluginMeter: Sendable {
    public let id: MeterID
    /// Whether its power is production (a solar array's), so above zero is Returned.
    let produces: Bool
    let readings: @Sendable (MeterReading) -> Void
    /// Its power into the Home Energy, when it has an Energy Role.
    let homeEnergy: (@Sendable (Double) -> Void)?

    /// A power reading, in watts.
    public func record(watts: Double) {
        guard watts.isFinite else { return }
        readings(.power(id, produces ? -watts : watts, Date()))
        homeEnergy?(watts)
    }

    /// A counter's reading, in watt-hours.
    public func record(counter wattHours: Double, direction: MeterDirection = .consumption) {
        guard wattHours.isFinite else { return }
        readings(.counter(id, wattHours, direction, Date()))
    }
}

extension PluginContext {
    /// Declares a Meter of the device `deviceID` (its accessory is `<platform>:<deviceID>`), `key` naming it among the
    /// device's Meters for as long as the device is there. `device` is the name the Status page shows it by;
    /// `suggestedRole` its Energy Role in the Home Energy (solar, home, grid or battery; nil for none, a single device's
    /// use); `shared` for a figure several devices report alike (`EnergyTag.shared`). Its power is also recorded as the
    /// series `plugin:<platform>:<series>`, `<deviceID>:<key>` unless `series` names it otherwise (a plugin keeping the
    /// name it recorded before).
    public func meter(_ key: String, deviceID: String, device: String, suggestedRole: EnergyRole? = nil, shared: String? = nil,
                      series: String? = nil) -> PluginMeter {
        let role = suggestedRole.flatMap { $0.isPower ? $0 : nil }
        let recorded = self.series(series ?? "\(deviceID):\(key)")
        return PluginMeter(
            id: MeterID(accessory: "\(platform):\(deviceID)", meter: key),
            produces: role == .solar,
            readings: meterSink,
            homeEnergy: role.map { role in
                let tag = EnergyTag(role: role, device: device, shared: shared)
                return { [self] watts in recordValue(watts, series: recorded, energy: tag) }
            })
    }
}
