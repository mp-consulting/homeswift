/// `GET /accessories` body.
struct AccessoryDatabase: Encodable {
    struct AccessoryJSON: Encodable {
        var aid: Int
        var services: [ServiceJSON]
    }

    struct ServiceJSON: Encodable {
        var iid: Int
        var type: String
        var characteristics: [CharacteristicJSON]
        var primary: Bool?
        var hidden: Bool?
    }

    var accessories: [AccessoryJSON]
}

/// One characteristic as it appears in the database, read responses, write responses and events.
struct CharacteristicJSON: Encodable {
    var aid: Int?
    var iid: Int
    var type: String?
    var perms: [String]?
    var format: String?
    var value: HAPValue?
    var description: String?
    var unit: String?
    var minValue: Double?
    var maxValue: Double?
    var minStep: Double?
    var maxLen: Int?
    var validValues: [Int]?
    var validValuesRange: [Int]?
    var ev: Bool?
    var status: Int?

    enum CodingKeys: String, CodingKey {
        case aid, iid, type, perms, format, value, description, unit, minValue, maxValue, minStep, maxLen, ev, status
        case validValues = "valid-values"
        case validValuesRange = "valid-values-range"
    }

    init(aid: Int? = nil, iid: Int, value: HAPValue? = nil, status: HAPStatus? = nil) {
        self.aid = aid
        self.iid = iid
        self.value = value
        self.status = status?.rawValue
    }

    init(describing characteristic: Characteristic, includeValue: Bool, includeMeta: Bool, includePerms: Bool = true, includeType: Bool = true) {
        let type = characteristic.type
        iid = characteristic.iid
        if includeType { self.type = type.uuid.shortForm }
        if includePerms {
            perms = CharacteristicPermission.allCases.filter(type.permissions.contains).map(\.rawValue)
        }
        if includeValue, type.permissions.contains(.pairedRead) {
            value = characteristic.value
        }
        if includeMeta {
            format = type.format.rawValue
            description = type.name
            unit = type.unit?.rawValue
            minValue = type.minValue
            maxValue = type.maxValue
            minStep = type.minStep
            maxLen = type.format == .string ? type.maxLength : nil
            validValues = type.validValues
            validValuesRange = type.validValueRange.map { [$0.lowerBound, $0.upperBound] }
        }
    }
}

struct CharacteristicsJSON: Encodable {
    var characteristics: [CharacteristicJSON]
}

/// `PUT /characteristics` body.
struct WriteRequest: Decodable {
    struct Item: Decodable {
        var aid: Int
        var iid: Int
        var value: HAPValue?
        var ev: Bool?
        var r: Bool?
        var authData: String?
        var remote: Bool?
    }

    var characteristics: [Item]
    var pid: UInt64?
}

/// `PUT /prepare` body for timed writes.
struct PrepareRequest: Decodable {
    var ttl: Int
    var pid: UInt64
}
