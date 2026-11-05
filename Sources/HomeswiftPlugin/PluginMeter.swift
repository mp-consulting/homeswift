import Foundation

/// A Meter a plugin declares for readings no characteristic carries (an inverter's solar, a meter's Returned energy, a
/// battery system's flows), made by `PluginContext.meter`. The bridge keeps its Consumption and Returned by the hour as
/// it does an accessory's Total Consumption; with an Energy Role, its power also counts in the Home Energy.
///
/// Power is in watts, above zero drawn and below zero sent back or produced: a battery charging is drawing, a solar
/// array producing is sending, a grid connection exporting is sending. Counters are in watt-hours and only go up, but
/// for a reset.
public struct PluginMeter: Sendable {
    public let id: MeterID
    /// Its Energy Role, if it has one, and the name and shared figure the Home Energy shows it by.
    public let tag: EnergyTag?
    let series: RecordedSeries
    let readings: @Sendable (MeterReading) -> Void
    let values: @Sendable (String, Double, EnergyTag?) -> Void

    /// A power reading, in watts.
    public func record(watts: Double) {
        guard watts.isFinite else { return }
        readings(.power(id, watts))
        // The Home Energy's signs: solar is production, zero or above.
        if let tag { values(series.name, tag.role == .solar ? -watts : watts, tag) }
    }

    /// A counter's reading, in watt-hours.
    public func record(counter wattHours: Double, direction: MeterDirection = .consumption) {
        guard wattHours.isFinite else { return }
        readings(.counter(id, wattHours, direction))
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
        return PluginMeter(
            id: MeterID(accessory: "\(platform):\(deviceID)", meter: key),
            tag: role.map { EnergyTag(role: $0, device: device, shared: shared) },
            series: self.series(series ?? "\(deviceID):\(key)"),
            readings: meterSink,
            values: { [self] series, value, tag in recordValue(value, series: RecordedSeries(name: series), energy: tag) })
    }
}
