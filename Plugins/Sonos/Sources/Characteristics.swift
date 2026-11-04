import Homeswift

/// The Homebridge plugin's own characteristics (homebridge-lib's), with their UUIDs
/// `000000XX-0000-1000-8000-656261617577` (`00000041` for Bass), so HomeKit keeps them.
enum SonosCharacteristic {
    /// `041` → `00000041-0000-1000-8000-656261617577`.
    private static func uuid3(_ suffix: String) -> HAPUUID { HAPUUID("00000\(suffix)-0000-1000-8000-656261617577") }

    private static let readWrite: Set<CharacteristicPermission> = [.pairedRead, .pairedWrite, .events]
    private static let readOnly: Set<CharacteristicPermission> = [.pairedRead, .events]

    private static func int(_ name: String, _ suffix: String, _ range: ClosedRange<Double>, step: Double = 1, unit: CharacteristicUnit? = nil) -> CharacteristicType {
        CharacteristicType(name: name, uuid: uuid3(suffix), format: .int, permissions: readWrite, unit: unit, minValue: range.lowerBound, maxValue: range.upperBound, minStep: step)
    }
    private static func bool(_ name: String, _ suffix: String, writable: Bool = true) -> CharacteristicType {
        CharacteristicType(name: name, uuid: uuid3(suffix), format: .bool, permissions: writable ? readWrite : readOnly)
    }
    private static func string(_ name: String, _ suffix: String) -> CharacteristicType {
        CharacteristicType(name: name, uuid: uuid3(suffix), format: .string, permissions: readOnly)
    }

    static let bass = int("Bass", "041", -10...10)
    static let treble = int("Treble", "042", -10...10)
    static let loudness = bool("Loudness", "043")
    static let balance = int("Balance", "044", -100...100, step: 5, unit: .percentage)
    static let currentTrack = string("Track", "045")
    static let sonosGroup = string("Sonos Group", "046")
    static let changeTrack = int("Track Change", "047", -1...1)
    static let changeVolume = int("Volume Change", "049", -10...10)
    static let changeInput = int("Input Change", "04A", -1...1)
    static let nightSound = bool("Night Sound", "04B")
    static let speechEnhancement = bool("Speech Enhancement", "04C")
    static let sonosCoordinator = bool("Sonos Coordinator", "04D")
    static let tv = bool("TV", "04E", writable: false)
    static let time = string("Time", "04F")
    static let lastSeen = string("Last Seen", "061")
    static let logLevel = CharacteristicType(name: "Log Level", uuid: uuid3("065"), format: .uint8, permissions: readWrite, minValue: 0, maxValue: 4, minStep: 1)
    static let repeatMode = CharacteristicType(name: "Repeat", uuid: uuid3("066"), format: .uint8, permissions: readWrite, minValue: 0, maxValue: 2, minStep: 1)
    static let shuffle = bool("Shuffle", "067")
    static let crossfade = bool("Crossfade", "068")
    static let subEnabled = bool("Sub Enabled", "06D")
    static let subLevel = int("Sub Level", "07D", -15...15)
    static let surroundEnabled = bool("Surround Enabled", "08C")
    static let tvLevel = int("TV Level", "08D", -15...15)
    static let musicLevel = int("Music Level", "08E", -15...15)
    static let musicPlaybackFull = bool("Music Playback Full", "08F")
    static let heightLevel = int("Height Level", "090", -10...10)

    /// Configured Name as homebridge-lib gives every service: hidden as well.
    static let configuredName = CharacteristicType(
        name: "Configured Name", uuid: CharacteristicType.configuredName.uuid, format: .string, permissions: [.pairedRead, .pairedWrite, .events, .hidden])
}
