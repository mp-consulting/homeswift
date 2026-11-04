import Foundation
import HomeswiftPlugin

// What the cloud's home data says (section 2.7) and what the devices' states mean (section 5).

/// The account's home: its products, devices (owned and shared) and rooms.
struct RoborockHome: Sendable {
    struct Product: Sendable {
        var id: String
        var name: String?
        var model: String?
        /// Schema code → id (as text), to read `deviceStatus`.
        var schema: [String: String]
    }

    struct Device: Sendable {
        var duid: String
        var name: String
        var localKey: String?
        var productID: String
        var firmware: String?
        var protocolVersion: String?
        var online: Bool?
        var serialNumber: String?
        var featureSet: UInt64?
        var newFeatureSet: String?
        /// Schema id → value.
        var status: [String: Double]
        /// From `receivedDevices`: another account's, shared with this one.
        var isShared: Bool
        /// The field names it has (for the log when it has no local key).
        var fieldNames: [String]
    }

    var raw: JSONValue
    var products: [String: Product]
    var devices: [Device]
    var rooms: [Int: String]

    init(_ json: JSONValue) {
        raw = json
        var products: [String: Product] = [:]
        for product in json["products"]?.arrayValue ?? [] {
            guard let id = Self.text(product["id"]) else { continue }
            var schema: [String: String] = [:]
            for entry in product["schema"]?.arrayValue ?? [] {
                if let code = entry["code"]?.stringValue, let id = Self.text(entry["id"]) { schema[code] = id }
            }
            products[id] = Product(id: id, name: product["name"]?.stringValue, model: product["model"]?.stringValue, schema: schema)
        }
        self.products = products
        func devices(_ key: String, shared: Bool) -> [Device] {
            (json[key]?.arrayValue ?? []).compactMap { device in
                guard let duid = device["duid"]?.stringValue, !duid.isEmpty else { return nil }
                var status: [String: Double] = [:]
                for (key, value) in device["deviceStatus"]?.objectValue ?? [:] {
                    if let number = value.doubleValue, number.isFinite { status[key] = number }
                }
                return Device(
                    duid: duid, name: device["name"]?.stringValue ?? "", localKey: device["localKey"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    productID: Self.text(device["productId"]) ?? "", firmware: device["fv"]?.stringValue, protocolVersion: device["pv"]?.stringValue,
                    online: device["online"]?.boolValue, serialNumber: device["sn"]?.stringValue,
                    featureSet: Self.unsigned(device["featureSet"]), newFeatureSet: device["newFeatureSet"]?.stringValue,
                    status: status, isShared: shared, fieldNames: device.objectValue?.keys.sorted() ?? [])
            }
        }
        self.devices = devices("devices", shared: false) + devices("receivedDevices", shared: true)
        var rooms: [Int: String] = [:]
        for room in json["rooms"]?.arrayValue ?? [] {
            if let id = room["id"]?.intValue, let name = room["name"]?.stringValue { rooms[id] = name }
        }
        self.rooms = rooms
    }

    func device(_ duid: String) -> Device? { devices.first { $0.duid == duid } }

    func product(of device: Device) -> Product? { products[device.productID] }

    func model(of device: Device) -> String? { product(of: device)?.model }

    /// A device's home-data value of a status field, through its product's schema.
    func snapshot(_ field: String, of device: Device) -> Double? {
        guard let id = product(of: device)?.schema[field] else { return nil }
        return device.status[id]
    }

    static func text(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue { return string }
        if let number = value?.doubleValue, number.isFinite, number.rounded() == number { return String(Int64(number)) }
        return nil
    }

    /// `featureSet` as a number or numeric text, as an unsigned 64-bit integer.
    static func unsigned(_ value: JSONValue?) -> UInt64? {
        if let text = value?.stringValue { return UInt64(text.trimmingCharacters(in: .whitespaces)) }
        if let number = value?.doubleValue, number.isFinite, number >= 0, number < 18_446_744_073_709_551_616 { return UInt64(number) }
        return nil
    }

    static func isSupported(model: String?) -> Bool { model?.hasPrefix("roborock.vacuum.") == true }
}

/// What a device's `featureSet` says it can do (section 5.4).
struct RoborockFeatures: Sendable, Equatable {
    var featureSet: UInt64?

    private func high(_ bit: Int) -> Bool {
        guard let featureSet else { return false }
        return (featureSet >> UInt64(32 + bit)) & 1 == 1
    }

    /// The dock washes the mop: bit 5 of the upper word.
    var dockWashesMop: Bool { high(5) }
    /// Off-peak ("valley electricity") charging: bit 13 of the upper word.
    var offPeakCharging: Bool { high(13) }

    /// A live `dock_type` that washes the mop: anything but 0, 1 and 5.
    static func dockWashes(dockType: Double?) -> Bool {
        guard let dockType else { return false }
        return ![0, 1, 5].contains(dockType)
    }
}

/// The meaning of the state codes (section 5.3).
enum RoborockStates {
    static let cleaning = Set([4, 5, 6, 7, 11, 15, 16, 17, 18, 23, 25, 26, 33, 34] + Array(6301...6310))
    static let mopWashing: Set<Int> = [23, 25, 26, 6310]
    static let docked: Set<Int> = [8, 100]
    static let dockBusy: Set<Int> = [22, 23, 25, 26]
    static let charging = 8

    static func isCleaning(_ state: Int?) -> Bool { state.map(cleaning.contains) ?? false }

    /// Busy for a scene's step: cleaning, or the dock busy, or `in_cleaning` set.
    static func isBusy(state: Int?, inCleaning: Int?) -> Bool {
        if let inCleaning, inCleaning > 0 { return true }
        guard let state else { return false }
        return cleaning.contains(state) || dockBusy.contains(state)
    }

    static let stateNames: [Int: String] = [
        0: "Unknown", 1: "Initiating", 2: "Sleeping", 3: "Idle", 4: "Remote control", 5: "Cleaning", 6: "Returning to dock",
        7: "Manual mode", 8: "Charging", 9: "Charging error", 10: "Paused", 11: "Spot cleaning", 12: "In error", 13: "Shutting down",
        14: "Updating", 15: "Docking", 16: "Go to", 17: "Zone clean", 18: "Room clean", 22: "Emptying dust bin", 23: "Washing the mop",
        25: "Washing the mop", 26: "Going to wash the mop", 28: "In call", 29: "Mapping", 30: "Egg attack", 32: "Patrol",
        33: "Attaching the mop", 34: "Detaching the mop", 100: "Fully charged", 101: "Device offline", 103: "Locked",
        202: "Air drying stopping", 6301: "Mopping", 6302: "Clean and mop", 6303: "Clean and mop", 6304: "Segment mopping",
        6305: "Segment clean and mop", 6306: "Segment clean and mop", 6307: "Zoned mopping", 6308: "Zoned clean and mop",
        6309: "Zoned clean and mop", 6310: "Washing the duster",
    ]

    static let errorNames: [Int: String] = [
        1: "Laser sensor fault", 2: "Collision sensor fault", 3: "Wheel floating", 4: "Cliff sensor fault", 5: "Main brush blocked",
        6: "Side brush blocked", 7: "Wheel blocked", 8: "Device stuck", 9: "Dust bin missing", 10: "Filter blocked",
        11: "Magnetic field detected", 12: "Low battery", 13: "Charging problem", 14: "Battery failure", 15: "Wall sensor fault",
        16: "Uneven surface", 17: "Side brush failure", 18: "Suction fan failure", 19: "Unpowered charging station",
        21: "Laser pressure sensor problem", 22: "Charge sensor problem", 23: "Dock problem", 24: "No-go zone or invisible wall detected",
        254: "Bin full", 255: "Internal error",
    ]

    static let dockErrorNames: [Int: String] = [
        32: "No dock dustbin or filter", 33: "Auto-empty fan error", 34: "Auto-empty jammed", 35: "Auto-empty voltage error",
        38: "Clean water tank empty", 39: "Dirty water tank full or missing", 42: "Maintenance brush jammed", 44: "Water filter blocked",
        46: "Dustbin not installed", 53: "Cleaning tank full or blocked",
    ]
}

/// The consumables' rated life and the life a work time leaves (section 5.5).
enum RoborockConsumables {
    struct Kind: Sendable {
        var field: String
        var workTimeField: String
        var subtype: String
        var ratedHours: Double
    }

    static let all = [
        Kind(field: "filter_life", workTimeField: "filter_work_time", subtype: "filter", ratedHours: 150),
        Kind(field: "main_brush_life", workTimeField: "main_brush_work_time", subtype: "main-brush", ratedHours: 300),
        Kind(field: "side_brush_life", workTimeField: "side_brush_work_time", subtype: "side-brush", ratedHours: 200),
    ]

    /// max(0, round(100 − work / rated × 100)), halves up as JavaScript rounds.
    static func life(workSeconds: Double, ratedHours: Double) -> Int {
        let value = 100 - workSeconds / (ratedHours * 3600) * 100
        return max(0, Int((value + 0.5).rounded(.down)))
    }

    /// The life of each consumable a `get_consumable` answer has.
    static func lives(_ answer: [String: JSONValue]) -> [String: Double] {
        var lives: [String: Double] = [:]
        for kind in all {
            if let work = answer[kind.workTimeField]?.doubleValue, work.isFinite { lives[kind.field] = Double(life(workSeconds: work, ratedHours: kind.ratedHours)) }
        }
        return lives
    }
}

/// A scene of the home (section 2.7): its items, each a device's command or something the cloud runs.
struct RoborockScene: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var type: String
        var entityID: String?
        var method: String?
        var params: JSONValue
    }

    var id: Int
    var name: String
    var enabled: Bool
    var items: [Item]
    var raw: JSONValue

    /// nil for a scene whose `param` does not parse.
    init?(_ json: JSONValue) {
        guard let id = json["id"]?.intValue else { return nil }
        self.id = id
        let name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty ? "Scene \(id)" : name
        enabled = json["enabled"]?.boolValue ?? false
        raw = json
        guard let text = json["param"]?.stringValue, let param = try? JSONValue(string: text) else { return nil }
        items = (param["action"]?["items"]?.arrayValue ?? []).map { item in
            let inner = item["param"]?.stringValue.flatMap { try? JSONValue(string: $0) }
            let method = inner?["method"]?.stringValue
            return Item(type: item["type"]?.stringValue ?? "", entityID: item["entityId"]?.stringValue, method: method, params: inner?["params"] ?? [])
        }
    }

    func belongs(to duid: String) -> Bool { items.contains { $0.entityID == duid } }

    var targets: Set<String> { Set(items.compactMap(\.entityID)) }

    /// Every item is a device command with a method.
    var isLocalCommands: Bool { !items.isEmpty && items.allSatisfy { $0.type == "CMD" && $0.method?.isEmpty == false && $0.entityID != nil } }
}
