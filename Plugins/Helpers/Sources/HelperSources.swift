import Foundation
import Homeswift
import HomeswiftPlugin

/// A characteristic a Helper may read, found on the host's accessories: what Setup and the settings editor offer.
struct SourceCandidate: Sendable {
    var ref: SourceRef
    /// For people: the accessory's name ("Living room"), the service's own too when the accessory has several of it.
    var label: String
    var type: CharacteristicType

    /// The accessory as the label, what it reads as the detail ("Current Temperature"): the web UI translates the detail.
    var option: SetupOption { SetupOption(ref.description, label: label, detail: type.name) }
}

/// The states a Stays Helper can wait on, for the characteristics that have named ones; the others' states are their
/// valid values (a flag's 1 and 0). In English, as Setup's words are; the web UI's catalogs translate them.
enum SourceStates {
    static let named: [HAPUUID: [(value: Int, label: String)]] = [
        CharacteristicType.contactSensorState.uuid: [(1, "Open"), (0, "Closed")],
        CharacteristicType.on.uuid: [(1, "On"), (0, "Off")],
        CharacteristicType.active.uuid: [(1, "Active"), (0, "Inactive")],
        CharacteristicType.motionDetected.uuid: [(1, "Motion"), (0, "No motion")],
        CharacteristicType.occupancyDetected.uuid: [(1, "Occupied"), (0, "Not occupied")],
        CharacteristicType.leakDetected.uuid: [(1, "Leak"), (0, "No leak")],
        CharacteristicType.outletInUse.uuid: [(1, "In use"), (0, "Not in use")],
        CharacteristicType.currentDoorState.uuid: [(0, "Open"), (1, "Closed"), (2, "Opening"), (3, "Closing"), (4, "Stopped")],
        CharacteristicType.lockCurrentState.uuid: [(0, "Unlocked"), (1, "Locked"), (2, "Jammed"), (3, "Unknown")],
    ]

    /// The states of a characteristic, its named ones first; nil for one without discrete states (a temperature).
    static func states(of type: CharacteristicType) -> [(value: Int, label: String)]? {
        if let named = named[type.uuid] { return named }
        if type.format == .bool { return [(1, "On"), (0, "Off")] }
        if let values = type.validValues ?? type.validValueRange.map(Array.init), !values.isEmpty, values.count <= 12 {
            return values.map { ($0, String($0)) }
        }
        return nil
    }
}

extension Array where Element == Accessory {
    /// The characteristics of these accessories a Helper may read, `matching` a test, sorted by label. A Helper never reads
    /// itself (`except`), and only what tells of changes (events) and is not a button press.
    func sourceCandidates(except excluded: String? = nil, matching test: (CharacteristicType) -> Bool) -> [SourceCandidate] {
        var found: [SourceCandidate] = []
        for accessory in self where accessory.id != excluded {
            for service in accessory.services where service.type.uuid != ServiceType.accessoryInformation.uuid {
                let twins = accessory.services.filter { $0.type.uuid == service.type.uuid }.count > 1
                for characteristic in service.characteristics where characteristic.iid > 0 {
                    let type = characteristic.type
                    guard type.permissions.contains(.pairedRead), type.permissions.contains(.events),
                          type.uuid != CharacteristicType.programmableSwitchEvent.uuid, test(type) else { continue }
                    let serviceName = twins ? (service[.configuredName] ?? service[.name])?.value.stringValue.flatMap { $0.isEmpty ? nil : $0 } : nil
                    let label = [accessory.name, serviceName].compactMap { $0 }.joined(separator: " · ")
                    found.append(SourceCandidate(ref: SourceRef(accessoryID: accessory.id, iid: characteristic.iid), label: label, type: type))
                }
            }
        }
        return found.sorted { a, b in
            let order = a.label.localizedStandardCompare(b.label)
            return order == .orderedSame ? a.type.name < b.type.name : order == .orderedAscending
        }
    }
}

extension PluginContext {
    /// The type of a source's characteristic, when its accessory is on the bridge.
    func sourceType(_ source: SourceRef) -> CharacteristicType? {
        hostAccessory(id: source.accessoryID)?.services.lazy.flatMap(\.characteristics).first { $0.iid == source.iid }?.type
    }
}

extension CharacteristicType {
    /// A number a Threshold can watch: a reading, not a flag, a named state or text.
    var isReading: Bool {
        [.float, .int, .uint8, .uint16, .uint32, .uint64].contains(format) && SourceStates.states(of: self) == nil
    }

    /// A state a Stays Helper can wait on.
    var hasStates: Bool { SourceStates.states(of: self) != nil }

    /// The Combine measure of a characteristic, when it is one.
    var measure: Measure? { Measure.allCases.first { $0.characteristic.uuid == uuid } }
}
