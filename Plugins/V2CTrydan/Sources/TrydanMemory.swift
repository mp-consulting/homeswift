import Foundation
import Homeswift
import HomeswiftPlugin

/// The energy a charger has delivered since the plugin first read it, made of its sessions' `ChargeEnergy` (the charger
/// keeps no lifetime total: docs/clean-room/V2CTrydan.md, 8.6). Only grows.
struct LifetimeEnergy: Codable, Sendable, Equatable {
    /// kWh.
    var total: Double = 0
    /// The session's energy at the last reading, to count what it added since.
    var session: Double?

    /// Adds a reading of the session's energy: what it grew by, or all of it when it fell (a new session started from
    /// 0). The first reading counts the session so far. A negative or non-finite reading is ignored.
    mutating func add(sessionEnergy reading: Double) {
        guard reading.isFinite, reading >= 0 else { return }
        if let session, reading >= session {
            total += reading - session
        } else {
            total += reading
        }
        session = reading
    }
}

/// What the plugin keeps of a charger across restarts (`charger-<Device Id>.json`): its lifetime energy, and the
/// installation settings it sent, so a value is sent once per change of the Accessory Settings.
struct ChargerMemory: Codable, Sendable, Equatable {
    var energy = LifetimeEnergy()
    /// By keyword (`ChargeMode`): the value last sent.
    var sent: [String: Int] = [:]

    static func file(_ context: PluginContext, deviceID: String) -> JSONFile<ChargerMemory> {
        context.jsonFile("charger-\(deviceID).json", as: ChargerMemory.self)
    }
}

/// The wiring a charger's Accessory Settings can set (`ChargeMode`, 3.3).
enum ChargeWiring: String, Sendable, CaseIterable {
    case monophasic, threephase, mixed

    var value: Int {
        switch self {
        case .monophasic: 0
        case .threephase: 1
        case .mixed: 2
        }
    }
}

/// The plugin's own characteristic for the session's energy, now that Eve's Total Consumption is the lifetime total.
/// The UUID is fixed: it keys the iid.
enum TrydanCharacteristic {
    /// kWh of the current (or last) session, `ChargeEnergy`.
    static let sessionEnergy = CharacteristicType(
        name: "Session Energy (kWh)", uuid: HAPUUID("CEC2B583-4814-49BF-AC0C-EEE15D53497D"), format: .float, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 100_000, minStep: 0.01)
}
