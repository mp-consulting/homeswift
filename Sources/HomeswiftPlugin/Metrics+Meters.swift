import Foundation
import Homeswift

extension Metrics {
    /// The Meter a characteristic of an accessory belongs to: one per service with Total Consumption or Current
    /// Consumption, by the service's type and subtype (the same key as its iids, so it is as stable).
    static func meterID(of accessory: Accessory, characteristic: Characteristic) -> MeterID? {
        guard let service = accessory.services.first(where: { $0.characteristics.contains { $0 === characteristic } }) else { return nil }
        return MeterID(accessory: accessory.id, meter: "\(service.type.uuid)/\(service.subtype ?? "")")
    }

    /// Records a Meter's reading from one of its characteristics: Total Consumption (kWh, a counter) or Current
    /// Consumption (watts). Other characteristics are left alone.
    func recordMeter(_ accessory: Accessory, _ characteristic: Characteristic, _ value: HAPValue, at: Date? = nil, fresh: Bool = true) {
        let uuid = characteristic.type.uuid
        guard uuid == EveCharacteristic.totalConsumption.uuid || uuid == EveCharacteristic.currentConsumption.uuid,
              let number = value.doubleValue, let id = Self.meterID(of: accessory, characteristic: characteristic) else { return }
        if uuid == EveCharacteristic.totalConsumption.uuid {
            meters.recordCounter(number * 1000, meter: id, at: at, fresh: fresh)
        } else {
            meters.recordPower(number, meter: id, at: at)
        }
    }

    /// Follows every accessory's Total Consumption and Current Consumption on the host's servers. Counters are read
    /// as they stand at start and when accessories come and go, so a counter's gain while the bridge was away counts;
    /// power counts only from a change, never a cached accessory's last reading.
    func followMeters(of host: PluginHost) -> Observation {
        let counters: @Sendable () -> Void = { [weak self, weak host] in
            guard let self, let host else { return }
            for bridge in host.bridges {
                for accessory in bridge.server.accessories {
                    for service in accessory.services {
                        for characteristic in service.characteristics where characteristic.type.uuid == EveCharacteristic.totalConsumption.uuid {
                            self.recordMeter(accessory, characteristic, characteristic.value, fresh: false)
                        }
                    }
                }
            }
        }
        let changes = host.observeChanges { [weak self] accessory, characteristic, value in self?.recordMeter(accessory, characteristic, value) }
        let structure = host.observeStructure(counters)
        let declared = host.observeMeterReadings { [meters] reading in
            switch reading {
            case let .counter(id, wattHours, direction): meters.recordCounter(wattHours, direction: direction, meter: id)
            case let .power(id, watts): meters.recordPower(watts, meter: id)
            }
        }
        counters()
        return Observation { changes.cancel(); structure.cancel(); declared.cancel() }
    }
}
