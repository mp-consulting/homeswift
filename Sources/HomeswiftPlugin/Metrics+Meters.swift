import Foundation
import Homeswift
import NIOConcurrencyHelpers

extension Metrics {
    /// The Meter of a service with Total Consumption or Current Consumption, by the service's type and subtype (the
    /// same key as its iids, so it is as stable).
    static func meterID(of accessory: Accessory, service: Service) -> MeterID {
        MeterID(accessory: accessory.id, meter: "\(service.type.uuid)/\(service.subtype ?? "")")
    }

    /// Follows every accessory's Total Consumption (kWh, a counter) and Current Consumption (watts), and the Meters
    /// plugins declare. Counters are read as they stand at start and when accessories come and go, as seeds (a cached
    /// accessory's may be old), so what a device counted while the bridge was away counts; power counts only from a
    /// change, never a cached accessory's last reading.
    func followMeters(of host: PluginHost) -> Observation {
        let total = EveCharacteristic.totalConsumption.uuid, current = EveCharacteristic.currentConsumption.uuid
        // Each metered characteristic's Meter, made again by each pass over the accessories: a change looks it up.
        let known = NIOLockedValueBox<[ObjectIdentifier: MeterID]>([:])
        let scanPending = NIOLockedValueBox(false)
        let scan: @Sendable () -> Void = { [weak self, weak host] in
            scanPending.withLockedValue { $0 = false }
            guard let self, let host else { return }
            var found: [ObjectIdentifier: MeterID] = [:]
            for accessory in host.bridges.flatMap(\.server.accessories) {
                for service in accessory.services {
                    for characteristic in service.characteristics where characteristic.type.uuid == total || characteristic.type.uuid == current {
                        let id = Self.meterID(of: accessory, service: service)
                        found[ObjectIdentifier(characteristic)] = id
                        if characteristic.type.uuid == total, let kWh = characteristic.value.doubleValue { meters.seedCounter(kWh * 1000, meter: id) }
                    }
                }
            }
            known.withLockedValue { $0 = found }
        }
        // A burst of structure changes (a plugin adding its devices one by one) makes one pass.
        let structure = host.observeStructure { [queue] in
            guard scanPending.withLockedValue({ pending in defer { pending = true }; return !pending }) else { return }
            queue.async(execute: scan)
        }
        let changes = host.observeChanges { [weak self] accessory, characteristic, value in
            let uuid = characteristic.type.uuid
            guard let self, uuid == total || uuid == current, let number = value.doubleValue else { return }
            // An accessory added since the last pass is found by its services.
            let id = known.withLockedValue { $0[ObjectIdentifier(characteristic)] }
                ?? accessory.services.first { $0.characteristics.contains { $0 === characteristic } }.map { Self.meterID(of: accessory, service: $0) }
            guard let id else { return }
            if uuid == total { meters.recordCounter(number * 1000, meter: id) } else { meters.recordPower(number, meter: id) }
        }
        let declared = host.observeMeterReadings { [meters] reading in
            switch reading {
            case let .counter(id, wattHours, direction): meters.recordCounter(wattHours, direction: direction, meter: id)
            case let .power(id, watts): meters.recordPower(watts, meter: id)
            }
        }
        scan()
        return Observation { changes.cancel(); structure.cancel(); declared.cancel() }
    }
}
