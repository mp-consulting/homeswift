import Foundation
import Homeswift
import Logging

/// The accessories of one platform instance, saved as JSON so they are back on the bridge at the next
/// launch before the plugin has reached its devices (Homebridge's cachedAccessories).
///
/// A restored accessory serves its last values, and accepts writes without a handler, until the plugin
/// adds an accessory with the same `id` and replaces it.
final class AccessoryCache: Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    /// The cached accessories, each with whether it was published as an external accessory.
    func load(logger: Logger) -> [(accessory: Accessory, external: Bool)] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let file = try JSONDecoder().decode(CacheFile.self, from: Data(contentsOf: url))
            return file.accessories.map { ($0.restore(), $0.external ?? false) }
        } catch {
            logger.warning("Ignoring an unreadable accessory cache", metadata: ["path": "\(url.path)", "error": "\(error)"])
            return []
        }
    }

    /// `external` lists the ids published as standalone accessories rather than on the bridge.
    func save(_ accessories: [Accessory], external: Set<String> = []) throws {
        let file = CacheFile(accessories: accessories.map { CachedAccessory($0, external: external.contains($0.id)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try OwnerOnlyFile.write(encoder.encode(file), to: url)
    }
}

struct CacheFile: Codable {
    var version = 1
    var accessories: [CachedAccessory]
}

struct CachedAccessory: Codable {
    var id: String
    var name: String
    var category: AccessoryCategory
    var manufacturer: String
    var model: String
    var serialNumber: String
    var firmwareRevision: String
    /// Published on its own HAP server, not the bridge.
    var external: Bool?
    var services: [CachedService]

    init(_ accessory: Accessory, external: Bool = false) {
        id = accessory.id
        self.external = external ? true : nil
        name = accessory.name
        category = accessory.category
        let information = accessory.information
        manufacturer = information[.manufacturer]?.value.stringValue ?? ""
        model = information[.model]?.value.stringValue ?? ""
        serialNumber = information[.serialNumber]?.value.stringValue ?? ""
        firmwareRevision = information[.firmwareRevision]?.value.stringValue ?? ""
        // The server adds Protocol Information itself.
        let kept = accessory.services.filter { $0.type.uuid != ServiceType.accessoryInformation.uuid && $0.type.uuid != ServiceType.protocolInformation.uuid }
        let indexes = Dictionary(kept.enumerated().map { (ObjectIdentifier($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
        services = kept.map { service in
            CachedService(service, linked: service.linked.compactMap { indexes[ObjectIdentifier($0)] })
        }
    }

    func restore() -> Accessory {
        let restored = services.map { $0.restore() }
        for (service, cached) in zip(restored, services) {
            service.linked = (cached.linked ?? []).filter { restored.indices.contains($0) }.map { restored[$0] }
        }
        return Accessory(
            id: id, name: name, manufacturer: manufacturer, model: model, serialNumber: serialNumber,
            firmwareRevision: firmwareRevision, category: category, services: restored)
    }
}

struct CachedService: Codable {
    var name: String
    var uuid: String
    var subtype: String?
    var isPrimary: Bool
    var isHidden: Bool
    /// Positions, in the accessory's cached services, of the services this one links to.
    var linked: [Int]?
    var characteristics: [CachedCharacteristic]

    init(_ service: Service, linked: [Int]) {
        self.linked = linked.isEmpty ? nil : linked
        name = service.type.name
        uuid = service.type.uuid.uuidString
        subtype = service.subtype
        isPrimary = service.isPrimary
        isHidden = service.isHidden
        characteristics = service.characteristics.map(CachedCharacteristic.init)
    }

    func restore() -> Service {
        // No required characteristics: every characteristic comes back exactly as saved.
        let type = ServiceType(name: name, uuid: HAPUUID(uuid), required: [], optional: [])
        return Service(type, subtype: subtype, extra: characteristics.map { $0.restore() }, isPrimary: isPrimary, isHidden: isHidden)
    }
}

struct CachedCharacteristic: Codable {
    var name: String
    var uuid: String
    var format: CharacteristicFormat
    var permissions: [CharacteristicPermission]
    var unit: CharacteristicUnit?
    var minValue: Double?
    var maxValue: Double?
    var minStep: Double?
    var maxLength: Int?
    var validValues: [Int]?
    var validValueRange: [Int]?
    var value: HAPValue

    init(_ characteristic: Characteristic) {
        let type = characteristic.type
        name = type.name
        uuid = type.uuid.uuidString
        format = type.format
        permissions = type.permissions.sorted { $0.rawValue < $1.rawValue }
        unit = type.unit
        minValue = type.minValue
        maxValue = type.maxValue
        minStep = type.minStep
        maxLength = type.maxLength
        validValues = type.validValues
        validValueRange = type.validValueRange.map { [$0.lowerBound, $0.upperBound] }
        value = characteristic.value
    }

    func restore() -> Characteristic {
        var range: ClosedRange<Int>?
        if let validValueRange, validValueRange.count == 2, validValueRange[0] <= validValueRange[1] {
            range = validValueRange[0]...validValueRange[1]
        }
        let type = CharacteristicType(
            name: name, uuid: HAPUUID(uuid), format: format, permissions: Set(permissions), unit: unit,
            minValue: minValue, maxValue: maxValue, minStep: minStep, maxLength: maxLength,
            validValues: validValues, validValueRange: range)
        return Characteristic(type, value: value)
    }
}
