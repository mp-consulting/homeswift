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
}
