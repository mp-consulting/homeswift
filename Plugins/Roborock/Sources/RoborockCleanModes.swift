import Foundation
import HomeswiftPlugin

// Suction, water flow and the mop route a robot offers (RoborockModes.md sections 1 to 3).

/// A code the robot reports and accepts, and its name.
struct RoborockMode: Sendable, Equatable {
    var code: Int
    var name: String

    var json: JSONValue { ["code": .number(Double(code)), "name": .string(name)] }
}

/// What a robot's model and feature flags say it can select (RoborockModes.md section 3).
struct RoborockCleanModes: Sendable, Equatable {
    /// The mop the model's family has.
    enum MopModule: String, Sendable { case none, electronic, shake, spin }

    /// A family's product features (section 3's table).
    struct Family: Sendable, Equatable {
        var maxPlus = false
        var noPureCleanMopWithMaxPlus = false
        var pureCleanMop = true
        var mop: MopModule = .none
    }

    let family: Family
    let featureSet: UInt64?
    let newFeatureSet: String?
    let isChina: Bool
    let isWaterSlideModel: Bool

    init(model: String?, featureSet: UInt64?, newFeatureSet: String?, region: String? = nil) {
        let short = model.map { $0.hasPrefix("roborock.vacuum.") ? String($0.dropFirst("roborock.vacuum.".count)) : $0 } ?? ""
        family = Self.families[short] ?? Self.pearlPlus
        self.featureSet = featureSet
        self.newFeatureSet = newFeatureSet
        isChina = region?.lowercased() == "cn"
        isWaterSlideModel = short == "a298"
    }

    // MARK: Flags

    /// Bit n of the new-feature string: bit (n mod 4) of the hex digit n / 4 from its end (Roborock.md section 5.4).
    func newFeature(_ bit: Int) -> Bool {
        guard let text = newFeatureSet?.lowercased(), !text.isEmpty else { return false }
        let digits = Array(text)
        let index = digits.count - 1 - bit / 4
        guard index >= 0, let digit = digits[index].hexDigitValue else { return false }
        return (digit >> (bit % 4)) & 1 == 1
    }

    /// The last 8 hex digits of the new-feature string as a number, ANDed with `mask`.
    func newFeatureMask(_ mask: UInt32) -> Bool {
        guard let text = newFeatureSet, let value = UInt32(String(text.suffix(8)), radix: 16) else { return false }
        return value & mask != 0
    }

    func feature(_ mask: UInt64) -> Bool { (featureSet ?? 0) & mask != 0 }
    func upperFeature(_ bit: Int) -> Bool { ((featureSet ?? 0) >> UInt64(32 + bit)) & 1 == 1 }

    var hasMopModule: Bool { family.mop == .shake || family.mop == .spin }
    var smartMode: Bool { newFeature(55) }
    var waterSlide: Bool { newFeature(106) || isWaterSlideModel }
    /// A water box at all: the family's mop (section 2.2).
    var hasWaterBox: Bool { family.mop != .none }
    var hasRoutes: Bool { hasMopModule || feature(262_144) }

    // MARK: What it offers

    /// Section 1.2, in its order.
    var fanPowers: [RoborockMode] {
        var modes = [RoborockMode(code: 101, name: "Quiet"), RoborockMode(code: 102, name: "Balanced"), RoborockMode(code: 103, name: "Turbo"), RoborockMode(code: 104, name: "Max")]
        if family.maxPlus || family.noPureCleanMopWithMaxPlus { modes.append(RoborockMode(code: 108, name: "Max+")) }
        modes.append(RoborockMode(code: 105, name: family.pureCleanMop ? "Off" : "Gentle"))
        if smartMode { modes.append(RoborockMode(code: 110, name: "Smart")) }
        if hasMopModule { modes.append(RoborockMode(code: 106, name: "Custom")) }
        return modes
    }

    /// The suction levels a speed slider runs through, weakest first: Gentle (when 105 is not Off), then Quiet to
    /// Max+. Custom, Smart and Off are modes, not levels.
    var suctionLevels: [RoborockMode] {
        let levels = fanPowers.filter { [101, 102, 103, 104, 108].contains($0.code) }
        guard !family.pureCleanMop, let gentle = fanPowers.first(where: { $0.code == 105 }) else { return levels }
        return [gentle] + levels
    }

    /// Section 2.2.
    var waterModes: [RoborockMode] {
        guard hasWaterBox else { return [] }
        if waterSlide {
            return [(200, "Off"), (221, "Slight"), (225, "Low"), (230, "Gentle"), (235, "Medium"), (240, "Moderate"), (245, "High"), (250, "Extreme")]
                .map { RoborockMode(code: $0.0, name: $0.1) }
        }
        let shake = family.mop == .shake
        var modes = [RoborockMode(code: 200, name: "Off"), RoborockMode(code: 201, name: shake ? "Mild" : "Low"),
                     RoborockMode(code: 202, name: shake ? "Standard" : "Medium"), RoborockMode(code: 203, name: shake ? "Intense" : "High")]
        if feature(2_147_483_648) { modes.append(RoborockMode(code: 207, name: "Custom water flow")) }
        if shake, newFeature(45) { modes.append(RoborockMode(code: 208, name: "Extreme")) }
        if smartMode { modes.append(RoborockMode(code: 209, name: "Smart")) }
        if hasMopModule { modes.append(RoborockMode(code: 204, name: "Custom")) }
        return modes
    }

    /// The water a mop gets when it is turned on: 202, or 235 on a water-slide robot (section 2.5).
    var defaultWater: Int { waterSlide ? 235 : 202 }

    /// Section 2.4.
    var routes: [RoborockMode] {
        guard hasRoutes else { return [] }
        if family.noPureCleanMopWithMaxPlus { return [RoborockMode(code: 304, name: "Fast"), RoborockMode(code: 300, name: "Standard")] }
        var modes = [RoborockMode(code: 300, name: "Standard")]
        if !newFeature(108) { modes.append(RoborockMode(code: 301, name: "Deep")) }
        if upperFeature(9) {
            let china = isChina && !newFeatureMask(2_147_483_648) && newFeatureMask(16_777_216)
            modes.append(RoborockMode(code: china ? 305 : 303, name: "Deep+"))
        }
        if newFeatureMask(256) { modes.append(RoborockMode(code: 304, name: "Fast")) }
        if smartMode { modes.append(RoborockMode(code: 306, name: "Smart")) }
        if hasMopModule { modes.append(RoborockMode(code: 302, name: "Custom")) }
        return modes
    }

    /// A code's name among those offered, or a name for any code the robot reports (section 1.1: an unknown level is
    /// shown, never written).
    static func name(_ code: Int, in modes: [RoborockMode]) -> String {
        if let mode = modes.first(where: { $0.code == code }) { return mode.name }
        return (221...250).contains(code) ? "Water level \(code - 220)" : "Level \(code)"
    }

    /// A mode the caller names (its code, or its name in any case) among those offered.
    static func find(_ value: JSONValue?, in modes: [RoborockMode]) -> RoborockMode? {
        if let code = value?.intValue { return modes.first { $0.code == code } }
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if let code = Int(text) { return modes.first { $0.code == code } }
        return modes.first { $0.name.lowercased() == text }
    }

    // MARK: The families (section 3)

    static let pearlPlus = Family(maxPlus: true, mop: .spin)

    static let families: [String: Family] = {
        var table: [String: Family] = [:]
        func add(_ models: [String], _ family: Family) { for model in models { table[model] = family } }
        // Spin mops with Max+.
        add(["a20", "a21", "a143", "a144", "a134", "a135", "a155", "a156", "a86", "a87", "a116", "a117", "a136",
             "a74", "a75", "a100", "a101", "a103", "a104", "a122", "a123", "a167", "a168", "a169", "a170", "a158", "a159"],
            Family(maxPlus: true, mop: .spin))
        // Shake mops with Max+.
        add(["a50", "a51", "a94", "a95", "a68", "a69", "a70", "a96", "a97", "a146", "a147",
             "a46", "a47", "a66", "a26", "a27", "a52", "a62", "a64", "a65"], Family(maxPlus: true, mop: .shake))
        add(["a72", "a84"], Family(noPureCleanMopWithMaxPlus: true, pureCleanMop: false, mop: .none))
        add(["a73", "a85"], Family(noPureCleanMopWithMaxPlus: true, pureCleanMop: false, mop: .electronic))
        add(["a124", "a125", "a139", "a140"], Family(noPureCleanMopWithMaxPlus: true, pureCleanMop: true, mop: .electronic))
        add(["a29", "a30", "a76", "a14", "a15"], Family(mop: .shake))
        add(["a23", "a24"], Family(mop: .shake))
        add(["a37", "a38"], Family(pureCleanMop: false, mop: .electronic))
        add(["a39", "a40", "a33", "a34"], Family(pureCleanMop: false, mop: .none))
        add(["t6", "s6"], Family(pureCleanMop: false, mop: .none))
        add(["t7", "a11", "t7p", "a09", "a10"], Family(pureCleanMop: false, mop: .electronic))
        add(["t4", "s4", "p5", "a08", "a19"], Family(pureCleanMop: false, mop: .none))
        add(["p6", "s5e", "a05"], Family(pureCleanMop: false, mop: .electronic))
        return table
    }()
}

/// What `get_status` says about errors (section 6.1).
enum RoborockErrors {
    static let robot: [Int: String] = [
        1: "Lidar blocked", 2: "Bumper stuck", 3: "Wheels suspended", 4: "Cliff sensor error", 5: "Main brush jammed",
        6: "Side brush jammed", 7: "Wheels jammed", 8: "Robot trapped", 9: "No dustbin", 10: "Filter wet or blocked",
        11: "Strong magnetic field", 12: "Low battery", 13: "Charging error", 14: "Battery error", 15: "Wall sensor dirty",
        16: "Robot tilted", 17: "Side brush error", 18: "Fan error", 19: "Dock not connected to power",
        20: "Optical flow sensor dirty", 21: "Vertical bumper pressed", 22: "Dock locator error", 23: "Return to dock failed",
        24: "No-go zone detected", 25: "Camera error", 26: "Wall sensor error", 27: "VibraRise jammed", 28: "Robot on carpet",
        29: "Filter blocked", 30: "Invisible wall detected", 31: "Cannot cross carpet", 32: "Internal error",
        34: "Clean the auto-empty dock", 35: "Auto-empty dock voltage error", 36: "Wash roller may be jammed",
        37: "Wash roller not lowered properly", 38: "Check the clean water tank", 39: "Check the dirty water tank",
        40: "Reinstall the water filter", 41: "Clean water tank empty", 42: "Check the water filter is installed",
        43: "Positioning button error", 44: "Clean the dock water filter", 45: "Wash roller may be jammed",
        48: "Water supply error", 49: "Drain error", 51: "Temperature protection", 52: "Cleaning carousel error",
        53: "Cleaning carousel water full", 54: "Water carriage dropped", 55: "Check the cleaning carousel", 56: "Audio error",
        254: "Bin full", 255: "Internal error",
    ]

    static let dock: [Int: String] = [
        32: "No dustbin or filter", 33: "Auto-empty fan error", 34: "Auto-empty jammed", 35: "Auto-empty voltage error",
        38: "Clean water tank empty", 39: "Dirty water tank full or missing", 42: "Maintenance brush jammed",
        44: "Water filter blocked or dirty tank latch open", 46: "Dustbin not installed", 53: "Cleaning tank full or blocked",
    ]

    static func describe(_ code: Int, in table: [Int: String]) -> String? {
        code == 0 ? nil : table[code] ?? "Error \(code)"
    }

    /// The error `resolve_error` clears first (section 6.2): the dock's, else the robot's; nil when there is none.
    static func toResolve(robot: Int?, dock: Int?) -> Int? {
        if let dock, dock != 0 { return dock }
        if let robot, robot != 0 { return robot }
        return nil
    }
}

/// Rooms of the loaded map (section 4.1, 4.2).
enum RoborockRooms {
    struct Room: Sendable, Equatable {
        var segment: Int
        var name: String

        var json: JSONValue { ["segment": .number(Double(segment)), "name": .string(name)] }
    }

    /// `get_room_mapping`'s entries `[segment, iot room id, …]` (or one flat pair), named from the home's rooms; a
    /// segment without a name is "Room <segment>".
    static func rooms(mapping: JSONValue, names: [String: String]) -> [Room] {
        var entries = mapping.arrayValue ?? []
        if entries.count >= 2, entries.first?.arrayValue == nil { entries = [mapping] }
        return entries.compactMap { entry -> Room? in
            guard let parts = entry.arrayValue, parts.count >= 2, let segment = parts[0].intValue else { return nil }
            let iot = RoborockHome.text(parts[1]) ?? ""
            return Room(segment: segment, name: names[iot]?.nonEmptyValue ?? "Room \(segment)")
        }
    }

    /// The home data's `rooms`: id (as text) → name.
    static func names(_ home: JSONValue?) -> [String: String] {
        var names: [String: String] = [:]
        for room in home?["rooms"]?.arrayValue ?? [] {
            if let id = RoborockHome.text(room["id"] ?? room["roomId"]), let name = room["name"]?.stringValue { names[id] = name }
        }
        return names
    }

    /// The segments the caller names: numbers, or room names in any case. Throws the first name not found.
    static func segments(_ wanted: [JSONValue], in rooms: [Room]) throws -> [Int] {
        try wanted.map { value in
            if let segment = value.intValue, rooms.isEmpty || rooms.contains(where: { $0.segment == segment }) { return segment }
            let text = value.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if let room = rooms.first(where: { $0.name.lowercased() == text }) { return room.segment }
            throw RoborockRoomError.unknown(value.stringValue ?? value.text())
        }
    }
}

enum RoborockRoomError: Error, CustomStringConvertible {
    case unknown(String)

    var description: String {
        switch self {
        case .unknown(let name): "No room named \(name) on the robot's current map"
        }
    }
}
