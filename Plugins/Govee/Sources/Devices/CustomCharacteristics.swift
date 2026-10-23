import Homeswift
import HomeswiftPlugin

/// The plugin's own characteristics (`utils/custom-chars.ts`), switches the Eve app shows on a light or a
/// purifier. Same UUIDs, so Eve keeps showing them; the Eve ones (`utils/eve-chars.ts`) are Homeswift's `EveCharacteristic`.
enum GoveeCharacteristic {
    private static func toggle(_ name: String, _ number: String) -> CharacteristicType {
        CharacteristicType(name: name, uuid: HAPUUID("E964F\(number)-079E-48FF-8F27-9C2605A29F52"), format: .bool, permissions: [.pairedRead, .pairedWrite, .events])
    }

    static let colourMode = toggle("Colour Mode", "004")
    static let musicMode = toggle("Music Mode", "005")
    static let musicModeTwo = toggle("Music Mode 2", "006")
    static let scene = toggle("Scene", "007")
    static let sceneTwo = toggle("Scene 2", "008")
    static let diyMode = toggle("DIY Mode", "009")
    static let diyModeTwo = toggle("DIY Mode 2", "010")
    static let sceneThree = toggle("Scene 3", "011")
    static let sceneFour = toggle("Scene 4", "012")
    static let diyModeThree = toggle("DIY Mode 3", "013")
    static let diyModeFour = toggle("DIY Mode 4", "014")
    static let segmented = toggle("Segmented", "015")
    static let segmentedTwo = toggle("Segmented 2", "016")
    static let segmentedThree = toggle("Segmented 3", "017")
    static let segmentedFour = toggle("Segmented 4", "018")
    static let videoMode = toggle("Video Mode", "019")
    static let videoModeTwo = toggle("Video Mode 2", "020")
    static let nightLight = toggle("Night Light", "021")
    static let displayLight = toggle("Display Light", "022")

    /// The legacy scene slots of a light, by their config.json key, in the Homebridge plugin's order.
    static let sceneSlots: [(key: String, type: CharacteristicType)] = [
        ("diyMode", diyMode), ("diyModeTwo", diyModeTwo), ("diyModeThree", diyModeThree), ("diyModeFour", diyModeFour),
        ("musicMode", musicMode), ("musicModeTwo", musicModeTwo),
        ("scene", scene), ("sceneTwo", sceneTwo), ("sceneThree", sceneThree), ("sceneFour", sceneFour),
        ("segmented", segmented), ("segmentedTwo", segmentedTwo), ("segmentedThree", segmentedThree), ("segmentedFour", segmentedFour),
        ("videoMode", videoMode), ("videoModeTwo", videoModeTwo),
    ]
}
