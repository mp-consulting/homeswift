import Homeswift
import HomeswiftPlugin

/// The battery's readings HomeKit has no characteristic for (5.2), on the Battery service as the plugin's own
/// characteristics: the Home app does not show them, the web UI's accessory details and apps such as Eve do. The charge
/// power is Eve's Current Consumption, in watts, as Eve shows it on an outlet. The UUIDs are fixed: they key the iids.
enum RenaultCharacteristic {
    private static let readEvents: Set<CharacteristicPermission> = [.pairedRead, .events]

    /// Kilometres the battery has left (`batteryAutonomy`).
    static let range = CharacteristicType(
        name: "Range (km)", uuid: HAPUUID("94AEB5D7-DAD1-45E0-A24C-97A162D218B5"), format: .uint16, permissions: readEvents,
        minValue: 0, maxValue: 2000, minStep: 1)
    /// Minutes to a full charge (`chargingRemainingTime`), 0 when the car is not charging.
    static let timeToFull = CharacteristicType(
        name: "Time to Full (min)", uuid: HAPUUID("E4668EF1-CDD6-43FE-AA6A-221A2B81F5F0"), format: .uint16, permissions: readEvents,
        minValue: 0, maxValue: 10_000, minStep: 1)
    /// kWh left in the battery (`batteryAvailableEnergy`, older cars; 0 there means unknown).
    static let availableEnergy = CharacteristicType(
        name: "Available Energy (kWh)", uuid: HAPUUID("221F20E7-C05E-46E1-881F-0A3BF5345B04"), format: .float, permissions: readEvents,
        minValue: 0, maxValue: 500, minStep: 0.1)
    /// What the charge is doing, in words (`chargingStatus`, 4.3: "waiting for a planned charge", "charge ended"…).
    static let chargeStatus = CharacteristicType(
        name: "Charge Status", uuid: HAPUUID("45BCE881-3AD8-4B18-A480-FE49C16C8176"), format: .string, permissions: readEvents)
    /// When the car last reported its battery (`timestamp`, ISO 8601).
    static let batteryUpdated = CharacteristicType(
        name: "Battery Updated", uuid: HAPUUID("ED895794-A9A2-4C1C-9286-FD65A0F663DE"), format: .string, permissions: readEvents)
}
