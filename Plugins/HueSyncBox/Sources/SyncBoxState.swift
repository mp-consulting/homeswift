import Foundation
import HomeswiftPlugin

/// What the plugin reads of the box's state (`GET /api/v1/`, docs/clean-room/HueSyncBox.md section 4.1), validated as the
/// Homebridge plugin validates it: an answer that does not validate is a failed read.
struct SyncBoxState: Sendable, Equatable {
    /// An entertainment area of the Hue Bridge (`hue.groups`).
    struct Area: Sendable, Equatable {
        var id: String
        var name: String
    }

    var name: String
    var uniqueID: String
    var firmwareVersion: String
    /// `powersave`, `passthrough`, `video`, `music` or `game`; kept as it came for one the plugin does not know.
    var mode: String
    /// `video`, `music` or `game`; empty when the box has none.
    var lastSyncMode: String
    /// 1 to 4 (`input1` to `input4`).
    var hdmiSource: Int
    /// 0 to 200: 100 unchanged, 0 the most dimmed, 200 the most boosted.
    var brightness: Int
    /// The intensity of each sync mode the state has an object for (`execution.video.intensity`), by mode.
    var intensities: [String: String]
    /// The entertainment areas, in the order of `hue.groups`'s keys as the box sent them.
    var areas: [Area]
    /// `hue.groupId`: the selected area.
    var groupID: String?
    /// The names of HDMI inputs 1 to 4.
    var inputNames: [String]

    static let syncModes = ["video", "music", "game"]
    /// The Mode TV's inputs and the remote's SELECT, numbered from 1.
    static let modes = ["video", "music", "game", "passthrough", "powersave"]
    /// The Intensity TV's inputs and the remote's arrows, numbered from 1.
    static let intensityLevels = ["subtle", "moderate", "high", "intense"]

    /// Syncing: in a sync mode, not passthrough or powersave.
    var isSyncing: Bool { Self.syncModes.contains(mode) }

    /// The mode whose intensity the Intensity TV and the arrows change: the current one while syncing, else the last one,
    /// else video.
    var intensityMode: String {
        if isSyncing { return mode }
        return Self.syncModes.contains(lastSyncMode) ? lastSyncMode : "video"
    }

    /// Validates and reads an answer. `SyncBoxError.invalidAnswer` when it is too large or misses what section 4.1 requires.
    static func parse(_ body: Data) throws -> SyncBoxState {
        guard body.count <= SyncBoxClient.maximumBodySize else { throw SyncBoxError.invalidAnswer("the state is larger than \(SyncBoxClient.maximumBodySize) bytes") }
        guard let json = try? JSONValue(data: body), json.objectValue != nil else { throw SyncBoxError.invalidAnswer("the state is not a JSON object") }
        func invalid(_ what: String) -> SyncBoxError { .invalidAnswer("the state has no valid \(what)") }

        guard let device = json["device"]?.objectValue else { throw invalid("device") }
        guard let name = device["name"]?.stringValue, !name.isEmpty else { throw invalid("device.name") }
        guard let firmware = device["firmwareVersion"]?.stringValue else { throw invalid("device.firmwareVersion") }
        guard let uniqueID = device["uniqueId"]?.stringValue else { throw invalid("device.uniqueId") }

        guard let execution = json["execution"]?.objectValue else { throw invalid("execution") }
        guard let mode = execution["mode"]?.stringValue else { throw invalid("execution.mode") }
        guard let source = execution["hdmiSource"]?.stringValue, let input = Self.inputNumber(source) else { throw invalid("execution.hdmiSource") }
        guard let level = execution["brightness"]?.doubleValue, level.isFinite, (0...200).contains(level) else { throw invalid("execution.brightness") }
        var intensities: [String: String] = [:]
        for mode in syncModes {
            if let intensity = execution[mode]?["intensity"]?.stringValue { intensities[mode] = intensity }
        }

        guard let hue = json["hue"]?.objectValue, let groups = hue["groups"]?.objectValue else { throw invalid("hue.groups") }
        var names: [String: String] = [:]
        for (id, group) in groups {
            guard let name = group["name"]?.stringValue, !name.isEmpty else { throw invalid("hue.groups name") }
            names[id] = name
        }
        // JSONValue keeps an object as a dictionary: the order comes from the bytes. Keys it could not place go last, sorted.
        var order = GroupOrder.keys(in: body).filter { names[$0] != nil }
        var seen = Set<String>()
        order = order.filter { seen.insert($0).inserted }
        order += names.keys.filter { !seen.contains($0) }.sorted()

        guard let hdmi = json["hdmi"]?.objectValue else { throw invalid("hdmi") }
        var inputNames: [String] = []
        for number in 1...4 {
            guard let name = hdmi["input\(number)"]?["name"]?.stringValue, !name.isEmpty else { throw invalid("hdmi.input\(number).name") }
            inputNames.append(name)
        }

        return SyncBoxState(
            name: name, uniqueID: uniqueID, firmwareVersion: firmware, mode: mode, lastSyncMode: execution["lastSyncMode"]?.stringValue ?? "",
            hdmiSource: input, brightness: Int(level.rounded()), intensities: intensities,
            areas: order.map { Area(id: $0, name: names[$0] ?? $0) }, groupID: hue["groupId"]?.stringValue, inputNames: inputNames)
    }

    /// 1 to 4 for `input1` to `input4`, exactly.
    static func inputNumber(_ source: String) -> Int? {
        guard source.count == 6, source.hasPrefix("input"), let number = Int(source.dropFirst(5)), (1...4).contains(number) else { return nil }
        return number
    }
}

/// Reads the keys of `hue.groups` in the order they appear in the bytes: a bounded scan of the JSON (depth 32, the body
/// already at most 100 kB) that skips everything else. Empty when the body is not as expected; the parser then sorts.
enum GroupOrder {
    static func keys(in body: Data) -> [String] {
        body.withUnsafeBytes { raw in
            var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self))
            return (try? scanner.topLevel()) ?? []
        }
    }

    private struct Malformed: Error {}

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        var found: [String] = []

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        mutating func topLevel() throws -> [String] {
            try value(path: [], depth: 0)
            return found
        }

        static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

        mutating func skipSpace() {
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
        }

        /// `path` is the keys from the top while they can still lead to `hue.groups`; nil off that path, where keys are
        /// skipped rather than read.
        mutating func value(path: [String]?, depth: Int) throws {
            guard depth < 32 else { throw Malformed() }
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            switch bytes[index] {
            case UInt8(ascii: "{"): try object(path: path, depth: depth)
            case UInt8(ascii: "["): try array(depth: depth)
            case UInt8(ascii: "\""): try skipString()
            default:
                // A number, true, false or null: up to the next delimiter.
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") || Self.isSpace(byte) { break }
                    index += 1
                }
            }
        }

        mutating func object(path: [String]?, depth: Int) throws {
            index += 1
            let isGroups = path == ["hue", "groups"]
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return }
            while true {
                skipSpace()
                // Only the keys down to hue.groups and its own are read; deeper ones are skipped.
                var child: [String]?
                if let path, path.count < 2 || isGroups {
                    let key = try string()
                    if isGroups { found.append(key) } else { child = path + [key] }
                } else {
                    try skipString()
                }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Malformed() }
                index += 1
                try value(path: child, depth: depth + 1)
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return }
                throw Malformed()
            }
        }

        mutating func array(depth: Int) throws {
            index += 1
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return }
            while true {
                try value(path: nil, depth: depth + 1)
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return }
                throw Malformed()
            }
        }

        /// Past a string, its closing quote included; the range it took.
        @discardableResult
        mutating func skipString() throws -> Range<Int> {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Malformed() }
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw Malformed() }
            index += 1
            return start..<index
        }

        /// A string, decoded by JSONValue so its escapes read as they do in the parsed state.
        mutating func string() throws -> String {
            let range = try skipString()
            guard let text = (try? JSONValue(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: bytes[range]))))?.stringValue else { throw Malformed() }
            return text
        }
    }
}
