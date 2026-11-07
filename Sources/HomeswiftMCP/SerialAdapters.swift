import Foundation
import HomeswiftAI

/// The Zigbee and Z-Wave USB sticks plugged into this machine, by their names under `/dev/serial/by-id` (Linux, a
/// Synology NAS, a container given that folder): the Status page shows them, for docs/zigbee-zwave.md's `devices:`
/// lines. A stick is known by the words its maker puts in its USB name; one whose name says nothing is left out.
public enum SerialAdapters {
    public enum Radio: String, Sendable {
        case zigbee, zwave, both
    }

    public struct Adapter: Sendable, Equatable {
        /// `/dev/serial/by-id/usb-…`, the name that stays the same across reboots and ports.
        public var path: String
        public var radio: Radio
    }

    public static let directory = "/dev/serial/by-id"

    /// Words in a stick's name, lowercased.
    static let both = ["husbzb", "hubz"]
    static let zigbee = ["zigbee", "conbee", "raspbee", "skyconnect", "zbt-1", "zbt1", "zbdongle", "cc2652", "cc2531", "cc1352", "slzb", "tube_zb", "dresden_elektronik"]
    static let zwave = ["z-wave", "zwave", "z_wave", "zooz", "aeotec", "z-stick", "zst10", "zst39", "uzb", "0658_0200", "zwa-"]

    /// The radio a stick's name says it has, or nil.
    public static func radio(of name: String) -> Radio? {
        let name = name.lowercased()
        if both.contains(where: name.contains) { return .both }
        let isZigbee = zigbee.contains(where: name.contains), isZWave = zwave.contains(where: name.contains)
        switch (isZigbee, isZWave) {
        case (true, true): return .both
        case (true, false): return .zigbee
        case (false, true): return .zwave
        default: return nil
        }
    }

    /// The sticks in `directory`, by name.
    public static func list(in directory: String = directory) -> [Adapter] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.sorted().compactMap { name in
            radio(of: name).map { Adapter(path: "\(directory)/\(name)", radio: $0) }
        }
    }

    static var json: JSONValue {
        .array(list().map { ["path": .string($0.path), "radio": .string($0.radio.rawValue)] })
    }
}
