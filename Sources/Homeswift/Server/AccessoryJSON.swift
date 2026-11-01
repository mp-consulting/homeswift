/// `GET /accessories` body.
struct AccessoryDatabase: JSONWritable {
    struct AccessoryJSON: JSONWritable {
        var aid: Int
        var services: [ServiceJSON]

        func write(to json: inout JSONWriter) {
            json.object { json in
                json.field("aid", aid)
                json.key("services")
                json.array { json in
                    for service in services { json.value(service) }
                }
            }
        }
    }

    struct ServiceJSON: JSONWritable {
        var iid: Int
        var type: String
        var characteristics: [CharacteristicJSON]
        var primary: Bool?
        var hidden: Bool?
        var linked: [Int]?

        func write(to json: inout JSONWriter) {
            json.object { json in
                json.field("iid", iid)
                json.field("type", type)
                json.key("characteristics")
                json.array { json in
                    for characteristic in characteristics { json.value(characteristic) }
                }
                json.field("primary", primary)
                json.field("hidden", hidden)
                json.field("linked", linked)
            }
        }
    }

    var accessories: [AccessoryJSON]

    func write(to json: inout JSONWriter) {
        json.object { json in
            json.key("accessories")
            json.array { json in
                for accessory in accessories { json.value(accessory) }
            }
        }
    }
}

/// One characteristic as it appears in the database, read responses, write responses and events.
struct CharacteristicJSON: JSONWritable {
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
    /// Writes `"value":` with a hole after it (`JSONWriter.hole()`) instead of `value`, for `DatabaseTemplate`.
    var valueHole = false

    func write(to json: inout JSONWriter) {
        json.object { json in
            json.field("aid", aid)
            json.field("iid", iid)
            json.field("type", type)
            json.field("perms", perms)
            json.field("format", format)
            if valueHole {
                json.key("value")
                json.hole()
            } else {
                json.field("value", value)
            }
            json.field("description", description)
            json.field("unit", unit)
            json.field("minValue", minValue)
            json.field("maxValue", maxValue)
            json.field("minStep", minStep)
            json.field("maxLen", maxLen)
            json.field("valid-values", validValues)
            json.field("valid-values-range", validValuesRange)
            json.field("ev", ev)
            json.field("status", status)
        }
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

struct CharacteristicsJSON: JSONWritable {
    var characteristics: [CharacteristicJSON]

    func write(to json: inout JSONWriter) {
        json.object { json in
            json.key("characteristics")
            json.array { json in
                for characteristic in characteristics { json.value(characteristic) }
            }
        }
    }
}

/// `{"status": n}`, the body of errors and of `PUT /prepare`.
struct StatusJSON: JSONWritable {
    var status: Int

    func write(to json: inout JSONWriter) {
        json.object { json in json.field("status", status) }
    }
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
