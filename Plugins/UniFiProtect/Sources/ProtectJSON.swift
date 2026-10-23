import Foundation
import HomeswiftPlugin

/// The controller's JSON as it comes: the bootstrap, devices and event payloads stay `JSONValue`, as the
/// Homebridge plugin keeps them as plain objects. An update payload is a subset of a device's JSON that is
/// merged into it (`merging`), and the code reads the few properties it needs through the accessors below.
extension JSONValue {
    /// `mergeJson` of the Homebridge plugin: objects merge key by key, deeply; anything else (arrays, null,
    /// scalars) replaces what was there.
    func merging(_ patch: JSONValue) -> JSONValue {
        guard case .object(let changes) = patch else { return patch }
        var result = objectValue ?? [:]
        for (key, value) in changes {
            if let existing = result[key], case .object = existing, case .object = value {
                result[key] = existing.merging(value)
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }

    /// The value at a dotted path (`"featureFlags.hasMic"`), or nil when a step is missing.
    func at(_ path: String) -> JSONValue? {
        var current: JSONValue? = self
        for key in path.split(separator: ".") {
            guard let object = current?.objectValue else { return nil }
            current = object[String(key)]
        }
        return current
    }

    /// Whether the object has the key, whatever its value (null included), as `'key' in object` does.
    func has(_ key: String) -> Bool { objectValue?[key] != nil }

    func string(_ path: String) -> String? { at(path)?.stringValue }
    func bool(_ path: String) -> Bool { at(path)?.boolValue ?? false }
    func double(_ path: String) -> Double? { at(path)?.doubleValue }
    func int(_ path: String) -> Int? { at(path)?.doubleValue.map { Int($0) } }
    func array(_ path: String) -> [JSONValue] { at(path)?.arrayValue ?? [] }
    func strings(_ path: String) -> [String] { array(path).compactMap(\.stringValue) }

    /// Whether the value at the path is present and not null.
    func isSet(_ path: String) -> Bool {
        guard let value = at(path) else { return false }
        return !value.isNull
    }

    /// The object with one key set, or created.
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        var object = objectValue ?? [:]
        object[key] = value
        return .object(object)
    }

    /// Truthiness as JavaScript sees it: false, null, 0, "" and missing are false.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0 && !value.isNaN
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }
}

/// One device of the bootstrap (camera, chime, light, sensor, viewer, or the NVR), with the properties the
/// plugin reads.
struct ProtectDeviceConfig: Sendable, Equatable {
    var json: JSONValue

    init(_ json: JSONValue) {
        self.json = json
    }

    var id: String { json.string("id") ?? "" }
    var mac: String { json.string("mac") ?? "" }
    var name: String? { json.string("name") }
    var marketName: String? { json.string("marketName") }
    var type: String { json.string("type") ?? "" }
    var modelKey: String { json.string("modelKey") ?? "" }
    var host: String? { json.string("host") }
    var connectionHost: String? { json.string("connectionHost") }
    var firmwareVersion: String? { json.string("firmwareVersion") }
    var hardwareRevision: String? { json.string("hardwareRevision") }
    var isConnected: Bool { json.bool("isConnected") }
    var isAdopted: Bool { json.bool("isAdopted") }
    var isAdoptedByOther: Bool { json.bool("isAdoptedByOther") }
    var isAdopting: Bool { json.bool("isAdopting") }
    var isThirdPartyCamera: Bool { json.bool("isThirdPartyCamera") }
    var isAdoptedByAccessApp: Bool { json.bool("isAdoptedByAccessApp") }
    var isPairedWithAiPort: Bool { json.bool("isPairedWithAiPort") }
    var videoCodec: String { json.string("videoCodec") ?? "" }

    /// The name, else the market name: what Protect shows.
    var displayName: String { name ?? marketName ?? type }

    /// A flag of the device's `featureFlags`.
    func feature(_ name: String) -> Bool { json.bool("featureFlags.\(name)") }

    var smartDetectTypes: [String] { json.strings("featureFlags.smartDetectTypes") }
    var smartDetectAudioTypes: [String] { json.strings("featureFlags.smartDetectAudioTypes") }

    var channels: [ProtectChannel] { json.array("channels").map(ProtectChannel.init) }
}

/// A camera channel: one of the streams Protect offers (High, Medium, Low, Package Camera).
struct ProtectChannel: Sendable, Equatable {
    var json: JSONValue

    init(_ json: JSONValue) {
        self.json = json
    }

    var id: Int { json.int("id") ?? 0 }
    var name: String { json.string("name") ?? "" }
    var width: Int { json.int("width") ?? 0 }
    var height: Int { json.int("height") ?? 0 }
    var fps: Int { json.int("fps") ?? 0 }
    var bitrate: Int { json.int("bitrate") ?? 0 }
    var isRtspEnabled: Bool { json.bool("isRtspEnabled") }
    var rtspAlias: String { json.string("rtspAlias") ?? "" }
}

/// A liveview of the controller: named slots of cameras.
struct ProtectLiveview: Sendable, Equatable {
    var id: String
    var name: String
    var cameras: [String]

    init(_ json: JSONValue) {
        id = json.string("id") ?? ""
        name = json.string("name") ?? ""
        cameras = json.array("slots").flatMap { $0.strings("cameras") }
    }
}

/// The plugin's own `toCamelCase`: the first letter of each word upper-cased.
func toCamelCase(_ input: String) -> String {
    var result = ""
    var atWordStart = true
    for character in input {
        if character.isWhitespace {
            atWordStart = true
            result.append(character)
        } else if atWordStart {
            result += character.uppercased()
            atWordStart = false
        } else {
            result.append(character)
        }
    }
    return result
}

/// A name HomeKit accepts, as the plugin's `sanitizeName` makes it: characters HomeKit does not allow become
/// spaces, runs of spaces collapse, and the name starts and ends with a letter or a digit.
func sanitizeName(_ name: String) -> String {
    let allowedPunctuation: Set<Character> = ["’", "'", "&", "!", ".", "_", ":", ";", "(", ")", "/", ",", "-"]
    var replaced = ""
    for character in name {
        if character.isLetter || character.isNumber || character.isWhitespace || allowedPunctuation.contains(character) {
            replaced.append(character.isWhitespace ? " " : character)
        } else {
            replaced.append(" ")
        }
    }
    var collapsed = replaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    while let first = collapsed.first, !(first.isLetter || first.isNumber) { collapsed.removeFirst() }
    while let last = collapsed.last, !(last.isLetter || last.isNumber) { collapsed.removeLast() }
    return collapsed
}

/// A MAC address for comparisons: hex digits only, lower case (`normalizeMac`).
func normalizeMAC(_ mac: String) -> String {
    String(mac.filter(\.isHexDigit)).lowercased()
}
