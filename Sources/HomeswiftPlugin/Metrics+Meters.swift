import Foundation
import Homeswift
import NIOConcurrencyHelpers

extension Metrics {
    /// What a Meter is to the Home Energy, as its last power reading said; nil for one with no power yet.
    public func meterDescription(of id: MeterID) -> MeterDescription? {
        meterDescriptions.withLockedValue { $0[id] }
    }

    /// A Meter's power (its signs: above zero drawn) in the Home Energy, under its Energy Role: the one a person gave it
    /// (`PluginHost.energyRole(of:)`, live), else its plugin's suggestion; nothing for none. Solar and the home's use
    /// count as amounts, whichever way the Meter measures them; the grid and a battery keep their direction.
    func recordHomeEnergy(_ id: MeterID, watts: Double, _ description: MeterDescription, role given: EnergyRole??) {
        meterDescriptions.withLockedValue { $0[id] = description }
        guard let role = given ?? description.suggestedRole else { return }
        let value = role == .solar || role == .home ? abs(watts) : watts
        // A role other than the suggestion is a series of its own: what was recorded under another role stays as it was.
        let series = role == description.suggestedRole ? description.series : "\(description.series):\(role.rawValue)"
        record(value, series: series, tag: EnergyTag(role: role, device: description.device, shared: description.shared))
    }

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
        // The Meters plugins took over: the bridge reads them no more from their characteristics.
        let claimed = NIOLockedValueBox<Set<MeterID>>([])
        let scanPending = NIOLockedValueBox(false)
        let scan: @Sendable () -> Void = { [weak self, weak host] in
            scanPending.withLockedValue { $0 = false }
            guard let self, let host else { return }
            var found: [ObjectIdentifier: MeterID] = [:]
            for accessory in host.bridges.flatMap(\.server.accessories) {
                for service in accessory.services {
                    for characteristic in service.characteristics where characteristic.type.uuid == total || characteristic.type.uuid == current {
                        let id = Self.meterID(of: accessory, service: service)
                        guard !claimed.withLockedValue({ $0.contains(id) }) else { continue }
                        found[ObjectIdentifier(characteristic)] = id
                        if characteristic.type.uuid == total, let kWh = characteristic.value.doubleValue { meters.seedCounter(kWh * 1000, meter: id) }
                    }
                }
            }
            known.withLockedValue { $0 = found }
        }
        // The plugins' own Meters first: what they took over before the bridge looked is not read twice.
        let declared = host.observeMeterReadings { [weak self, weak host] reading in
            guard let self else { return }
            switch reading {
            // When they were read: those a plugin made before the store followed arrive late.
            case let .counter(id, wattHours, direction, at): meters.recordCounter(wattHours, direction: direction, meter: id, at: at)
            case let .claim(id): claimed.withLockedValue { _ = $0.insert(id) }
            case let .power(id, watts, at, description):
                meters.recordPower(watts, meter: id, at: at)
                recordHomeEnergy(id, watts: watts, description, role: host?.energyRole(of: id))
            }
        }
        // A burst of structure changes (a plugin adding its devices one by one) makes one pass.
        let structure = host.observeStructure { [queue] in
            guard scanPending.withLockedValue({ pending in defer { pending = true }; return !pending }) else { return }
            queue.async(execute: scan)
        }
        let changes = host.observeChanges { [weak self, weak host] accessory, characteristic, value in
            let uuid = characteristic.type.uuid
            guard let self, uuid == total || uuid == current, let number = value.doubleValue else { return }
            // An accessory added since the last pass is found by its services.
            let id = known.withLockedValue { $0[ObjectIdentifier(characteristic)] }
                ?? accessory.services.first { $0.characteristics.contains { $0 === characteristic } }.map { Self.meterID(of: accessory, service: $0) }
            guard let id, !claimed.withLockedValue({ $0.contains(id) }) else { return }
            if uuid == total {
                meters.recordCounter(number * 1000, meter: id)
            } else {
                meters.recordPower(number, meter: id)
                recordHomeEnergy(id, watts: number, MeterDescription(device: accessory.name, series: "meter:\(id)"), role: host?.energyRole(of: id))
            }
        }
        scan()
        return Observation { changes.cancel(); structure.cancel(); declared.cancel() }
    }
}
