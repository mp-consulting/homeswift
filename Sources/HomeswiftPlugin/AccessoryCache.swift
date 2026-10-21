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

    func load(logger: Logger) -> [Accessory] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let file = try JSONDecoder().decode(CacheFile.self, from: Data(contentsOf: url))
            return file.accessories.map { $0.restore() }
        } catch {
            logger.warning("Ignoring an unreadable accessory cache", metadata: ["path": "\(url.path)", "error": "\(error)"])
            return []
        }
    }

    func save(_ accessories: [Accessory]) throws {
        let file = CacheFile(accessories: accessories.map(CachedAccessory.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
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
    var services: [CachedService]

    init(_ accessory: Accessory) {
        id = accessory.id
        name = accessory.name
        category = accessory.category
        let information = accessory.information
        manufacturer = information[.manufacturer]?.value.stringValue ?? ""
        model = information[.model]?.value.stringValue ?? ""
        serialNumber = information[.serialNumber]?.value.stringValue ?? ""
        firmwareRevision = information[.firmwareRevision]?.value.stringValue ?? ""
        services = accessory.services
            .filter { $0.type.uuid != ServiceType.accessoryInformation.uuid }
            .map(CachedService.init)
    }

    func restore() -> Accessory {
        Accessory(
            id: id, name: name, manufacturer: manufacturer, model: model, serialNumber: serialNumber,
            firmwareRevision: firmwareRevision, category: category, services: services.map { $0.restore() })
    }
}

struct CachedService: Codable {
    var name: String
    var uuid: String
    var subtype: String?
    var isPrimary: Bool
    var isHidden: Bool
    var characteristics: [CachedCharacteristic]

    init(_ service: Service) {
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
