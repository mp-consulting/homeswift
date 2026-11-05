import Foundation

/// The Gen 2+ models the Homebridge plugin knows, by model id (case-insensitive), with their names. Other models are
/// mapped from the components their status lists (`Gen2Layout`), named after their `app`.
enum Gen2Models {
    static let names: [String: String] = {
        var names: [String: String] = [:]
        func add(_ name: String, _ ids: String...) { for id in ids { names[id.uppercased()] = name } }
        add("Shelly Plus 1", "SNSW-001X16EU", "SNSW-001X15UL")
        add("Shelly Plus 1 PM", "SNSW-001P16EU", "SNSW-001P15UL")
        add("Shelly Plus 2 PM", "SNSW-002P16EU", "SNSW-102P16EU")
        add("Shelly Plus I4", "SNSN-0024X")
        add("Shelly Plus Plug US", "SNPL-00116US")
        add("Shelly Pro 1", "SPSW-001XE16EU", "SPSW-101XE16EU", "SPSW-201XE16EU")
        add("Shelly Pro 1 PM", "SPSW-001PE16EU", "SPSW-101PE16EU", "SPSW-201PE16EU")
        add("Shelly Pro 2", "SPSW-002XE16EU", "SPSW-102XE16EU", "SPSW-202XE16EU")
        add("Shelly Pro 2 PM", "SPSW-002PE16EU", "SPSW-102PE16EU", "SPSW-202PE16EU")
        add("Shelly Pro 3", "SPSW-003XE16EU")
        add("Shelly Pro 4 PM", "SPSW-004PE16EU")
        return names
    }()

    /// The Plus H&T: known to the Homebridge plugin's library, without accessories (it sleeps).
    static let unsupported: Set<String> = ["SNSN-0013A"]

    /// The model's name: the table's, else "Shelly " and the device's `app` (`PlusPlugS`), else its model id.
    static func name(model: String, app: String?) -> String {
        names[model.uppercased()] ?? app?.trimmedNonEmpty.map { "Shelly \($0)" } ?? "Shelly \(model)"
    }
}

/// A Gen 2+ component key, `switch:1`: its type and id.
struct ComponentKey: Hashable, Sendable, Comparable {
    var type: String
    var id: Int

    init(_ type: String, _ id: Int) {
        self.type = type
        self.id = id
    }

    init?(_ key: String) {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = Int(parts[1]) else { return nil }
        type = String(parts[0])
        self.id = id
    }

    var key: String { "\(type):\(id)" }

    static func < (a: ComponentKey, b: ComponentKey) -> Bool { (a.type, a.id) < (b.type, b.id) }
}

/// What a device's components become: the Homebridge plugin's layouts for switches, covers and the I4's inputs, and
/// lights, colour lights and energy meters beyond it.
struct Gen2Layout: Sendable, Equatable {
    enum Part: Sendable, Equatable {
        case `switch`(Int)
        case cover(Int)
        /// The I4's inputs configured as buttons, on one accessory.
        case buttons([Int])
        /// An input configured as a switch, read-only.
        case inputSwitch(Int)
        case light(Int)
        case rgb(Int)
        case rgbw(Int)
        case cct(Int)
        /// `em`, `em1` or `pm1`.
        case meter(String, Int)

        /// The channel Shelly Cloud names it by; nil for the I4's buttons, which share an accessory.
        var channel: Int? {
            switch self {
            case .switch(let id), .cover(let id), .inputSwitch(let id), .light(let id), .rgb(let id), .rgbw(let id), .cct(let id), .meter(_, let id): id
            case .buttons: nil
            }
        }
    }

    /// An accessory: the id after `<deviceId>-`, the name's suffix, and what it shows.
    struct Item: Sendable, Equatable {
        var accessoryID: String
        var suffix: String?
        var part: Part
    }

    var items: [Item]

    /// `profile` is `Shelly.GetDeviceInfo`'s; `inputTypes` each input's configured type.
    init(components: Set<ComponentKey>, profile: String?, inputTypes: [Int: String]) {
        func ids(_ type: String) -> [Int] { components.filter { $0.type == type }.map(\.id).sorted() }
        var items: [Item] = []
        let switches = ids("switch"), covers = ids("cover")
        let lights = ids("light"), rgbs = ids("rgb"), rgbws = ids("rgbw"), ccts = ids("cct")
        // A 2PM in cover profile shows its cover; in switch profile, its switches.
        let showCovers = !covers.isEmpty && (profile == nil || profile == "cover" || switches.isEmpty)
        func add(_ list: [Int], _ base: String, _ title: String, _ part: (Int) -> Part) {
            for id in list {
                items.append(list.count == 1
                    ? Item(accessoryID: base, suffix: nil, part: part(id))
                    : Item(accessoryID: "\(base)-\(id)", suffix: "\(title) \(id + 1)", part: part(id)))
            }
        }
        if showCovers {
            for id in covers {
                items.append(covers.count == 1 ? Item(accessoryID: "cover", suffix: "Cover", part: .cover(id))
                    : Item(accessoryID: "cover-\(id)", suffix: "Cover \(id + 1)", part: .cover(id)))
            }
        } else {
            add(switches, "switch", "Switch", Part.switch)
        }
        add(lights, "light", "Light", Part.light)
        add(rgbs, "rgb", "Light", Part.rgb)
        add(rgbws, "rgbw", "Light", Part.rgbw)
        add(ccts, "cct", "Light", Part.cct)
        // Inputs only on a device that has nothing else to drive: the I4's layout.
        if items.isEmpty {
            let inputs = ids("input")
            let buttons = inputs.filter { inputTypes[$0] == "button" }
            if !buttons.isEmpty { items.append(Item(accessoryID: "buttons", suffix: nil, part: .buttons(buttons))) }
            for id in inputs where inputTypes[id] != "button" {
                items.append(Item(accessoryID: "switch\(id)", suffix: nil, part: .inputSwitch(id)))
            }
        }
        for type in ["em", "em1", "pm1"] {
            for id in ids(type) {
                items.append(Item(accessoryID: "\(type)-\(id)", suffix: "Meter \(id + 1)", part: .meter(type, id)))
            }
        }
        self.items = items
    }
}
