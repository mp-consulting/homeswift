import Foundation
import Homeswift
import HomeswiftPlugin

/// The charger's IEC 61851 state, `ChargeState` (docs/clean-room/V2CTrydan.md, 3.3). `3` is not defined.
enum ChargeState: Int, Sendable, Equatable {
    /// State A: no vehicle.
    case waitingVehicle = 0
    /// State B: a vehicle connected, not charging.
    case connected = 1
    /// State C: charging.
    case charging = 2
    /// State F: system failure, leak detected.
    case failure = 4
    /// State E: control-pilot error, ground failure.
    case pilotError = 5
    /// State D: ventilation required.
    case ventilation = 6

    /// A fault the Contact Sensor shows as Status Fault.
    var isFault: Bool { self == .failure || self == .pilotError || self == .ventilation }
}

/// The meter link's state, `SlaveError` (3.5): a diagnostic, never a fault. Codes the sheet does not list are
/// "Undefined error" (257).
enum SlaveError {
    static let names: [Int: String] = [
        0: "No error", 1: "Communication", 2: "Reading", 3: "Meter", 4: "Waiting for Wi-Fi", 5: "Waiting for communication",
        6: "Wrong IP", 7: "Meter not found", 8: "Wrong meter", 9: "No response", 10: "Clamp not connected",
        21: "Illegal function", 22: "Illegal data address", 23: "Illegal data value", 24: "Server device failure", 25: "Acknowledge",
        26: "Server device busy", 27: "Negative acknowledge", 28: "Memory parity error", 30: "Gateway path unavailable",
        31: "Gateway target did not respond", 32: "Server RTU inactive", 245: "Invalid server", 246: "CRC error",
        247: "Function code mismatch", 248: "Server id mismatch", 249: "Packet length error", 250: "Parameter count error",
        251: "Parameter limit error", 252: "Request queue full", 253: "Illegal IP or port", 254: "IP connection failed",
        255: "TCP header mismatch", 256: "Empty message", 257: "Undefined error",
    ]

    /// The code as the sheet knows it: any other is 257.
    static func code(_ raw: Int) -> Int { names[raw] == nil ? 257 : raw }

    static func name(_ raw: Int) -> String { names[code(raw)] ?? "Undefined error" }
}

/// `DynamicPowerMode` (3.6), as V2C's sheet and pytrydan name them; the names are the MCP action's.
enum DynamicPowerMode: Int, Sendable, CaseIterable {
    case timed = 0
    /// Deprecated by V2C, still accepted.
    case timedOff = 1
    case solarMin = 2
    case solarOnly = 3
    case solarGrid = 4
    case stop = 5

    var name: String {
        switch self {
        case .timed: "timed"
        case .timedOff: "timed-off"
        case .solarMin: "solar-min"
        case .solarOnly: "solar-only"
        case .solarGrid: "solar-grid"
        case .stop: "stop"
        }
    }

    var label: String {
        switch self {
        case .timed: "Timed power enabled"
        case .timedOff: "Timed power disabled (deprecated)"
        case .solarMin: "Solar and minimum power"
        case .solarOnly: "Solar only"
        case .solarGrid: "Solar and grid"
        case .stop: "Stop"
        }
    }

    init?(name: String) {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = Self.allCases.first(where: { $0.name == lowered }) {
            self = match
        } else if let number = Int(lowered), let match = Self(rawValue: number) {
            self = match
        } else {
            return nil
        }
    }
}

/// What one `/RealTimeData` read reports, with the keywords `/read` filled in (3.3). Numbers are as the device sends
/// them, decimals or whole; the fields some firmware leaves out are optional.
struct TrydanReport: Sendable, Equatable {
    var id: String?
    /// The raw `ChargeState`; `chargeState` is nil for a value outside the enum (`3`, or a new one).
    var rawChargeState: Int
    var readyState: Int?
    var chargePower: Double
    var chargeEnergy: Double
    var chargeTime: Int
    var housePower: Double
    var fvPower: Double
    var batteryPower: Double?
    var slaveError: Int
    var paused: Int
    var locked: Int
    var timer: Int
    var intensity: Int
    var minIntensity: Int
    var maxIntensity: Int
    var dynamic: Int
    var pauseDynamic: Int
    var dynamicPowerMode: Int
    var contractedPower: Int
    var voltageInstallation: Int?
    var chargeMode: Int?
    var lightLED: Int?
    var logoLED: Int?
    var firmwareVersion: String?
    var ssid: String?
    var ip: String?
    var signalStatus: Int?
    /// Measured current per phase, amperes, for the phases the firmware reports.
    var intensityMeasures: [Double] = []
    /// Measured voltage per phase, volts.
    var voltageMeasures: [Double] = []

    var chargeState: ChargeState? { ChargeState(rawValue: rawChargeState) }

    /// Plugged in: any state but A. A value outside the enum counts as connected, not charging (5.3).
    var isConnected: Bool { rawChargeState != ChargeState.waitingVehicle.rawValue }
    var isCharging: Bool { chargeState == .charging }
    var isFault: Bool { chargeState?.isFault ?? false }

    /// The fields pytrydan fails a read without (3.3, presence R).
    static let requiredKeys = [
        "ChargeState", "ChargePower", "ChargeEnergy", "ChargeTime", "HousePower", "FVPower", "SlaveError", "Paused", "Locked",
        "Timer", "Intensity", "MinIntensity", "MaxIntensity", "Dynamic", "PauseDynamic", "DynamicPowerMode", "ContractedPower",
    ]

    /// The optional keywords asked through `/read` when `/RealTimeData` leaves them out (3.3, Recommendation), by name.
    static let fallbackKeys = ["ChargeMode", "LightLED", "LogoLED", "VoltageInstallation"]

    /// The report in an object, `extras` (from `/read`) filling what it lacks; nil names the first required key missing.
    init(_ object: [String: JSONValue], extras: [String: Double] = [:]) throws(TrydanError) {
        func number(_ key: String) -> Double? {
            if let value = object[key], let number = Self.number(value) { return number }
            return extras[key]
        }
        func required(_ key: String) throws(TrydanError) -> Double {
            guard let value = number(key) else { throw .missingField(key) }
            return value
        }
        func requiredInt(_ key: String) throws(TrydanError) -> Int {
            guard let value = Int(saturating: try required(key).rounded()) else { throw .missingField(key) }
            return value
        }
        func optionalInt(_ key: String) -> Int? { number(key).flatMap { Int(saturating: $0.rounded()) } }
        func text(_ key: String) -> String? {
            switch object[key] {
            case .string(let string): string.trimmingCharacters(in: .whitespacesAndNewlines)
            case .number(let number): Self.versionText(number)
            default: nil
            }
        }

        id = text("ID").flatMap { $0.isEmpty ? nil : $0 }
        rawChargeState = try requiredInt("ChargeState")
        readyState = optionalInt("ReadyState")
        chargePower = try required("ChargePower")
        chargeEnergy = try required("ChargeEnergy")
        chargeTime = try requiredInt("ChargeTime")
        housePower = try required("HousePower")
        fvPower = try required("FVPower")
        batteryPower = number("BatteryPower")
        slaveError = try requiredInt("SlaveError")
        paused = try requiredInt("Paused")
        locked = try requiredInt("Locked")
        timer = try requiredInt("Timer")
        intensity = try requiredInt("Intensity")
        minIntensity = try requiredInt("MinIntensity")
        maxIntensity = try requiredInt("MaxIntensity")
        dynamic = try requiredInt("Dynamic")
        pauseDynamic = try requiredInt("PauseDynamic")
        dynamicPowerMode = try requiredInt("DynamicPowerMode")
        contractedPower = try requiredInt("ContractedPower")
        voltageInstallation = optionalInt("VoltageInstallation")
        chargeMode = optionalInt("ChargeMode")
        lightLED = optionalInt("LightLED")
        logoLED = optionalInt("LogoLED")
        firmwareVersion = text("FirmwareVersion").flatMap { $0.isEmpty ? nil : $0 }
        ssid = text("SSID")
        ip = text("IP")
        signalStatus = optionalInt("SignalStatus")
        // The sheet's sample spells the first phase `IntensityMeasure_L1y`: both are read.
        intensityMeasures = [["IntensityMeasure_L1", "IntensityMeasure_L1y"], ["IntensityMeasure_L2"], ["IntensityMeasure_L3"]].compactMap { keys in
            keys.lazy.compactMap { object[$0].flatMap(Self.number) }.first
        }
        voltageMeasures = ["VoltageMeasure_L1", "VoltageMeasure_L2", "VoltageMeasure_L3"].compactMap { object[$0].flatMap(Self.number) }
    }

    /// A number, whole or decimal, or a numeric string; nil for anything else, NaN and infinity.
    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number): number.finite
        case .string(let string): Double(string.trimmingCharacters(in: .whitespaces))?.finite
        case .bool(let bool): bool ? 1 : 0
        default: nil
        }
    }

    /// A firmware version a parser read as a number (`2.1`): its text.
    static func versionText(_ number: Double) -> String? {
        guard number.isFinite else { return nil }
        return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    // MARK: Values for HomeKit

    /// The installation's voltage: `VoltageInstallation` when above 0, else the mean of the phases measured.
    var voltage: Double? {
        if let voltageInstallation, voltageInstallation > 0 { return Double(voltageInstallation) }
        let measured = voltageMeasures.filter { $0 > 0 }
        return measured.isEmpty ? nil : measured.reduce(0, +) / Double(measured.count)
    }

    /// The current drawn: the phases measured, else the power over the voltage.
    var current: Double? {
        if !intensityMeasures.isEmpty { return max(0, intensityMeasures.reduce(0, +)) }
        guard let voltage, voltage > 0 else { return nil }
        return max(0, chargePower / voltage)
    }

    /// The offered current's range, `MinIntensity`...`MaxIntensity` within 6...32 A (6...32 when it makes no sense).
    var intensityRange: ClosedRange<Int> {
        let low = min(max(minIntensity, 6), 32), high = min(max(maxIntensity, 6), 32)
        return low <= high ? low...high : 6...32
    }
}

/// The charger's errors, for the log and HomeKit's No Response.
enum TrydanError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Not an HTTP 200 (401 and 403 too: the device has no authentication).
    case status(Int)
    /// A body that is not a JSON object (an HTML page, a broken reply).
    case invalidResponse(String)
    /// A field the read needs is not there.
    case missingField(String)
    /// The keyword is not on this firmware (HTTP 404 on `/read`).
    case unsupported(String)
    /// A write the device did not answer `OK`.
    case writeRefused(keyword: String, status: Int, body: String)
    /// A value refused before any request (3.4).
    case outOfRange(keyword: String, value: Int, allowed: String)
    /// HTTP 429, with how long to wait.
    case rateLimited(Duration)
    case invalidHost(String)

    var description: String {
        switch self {
        case .status(let status): status == 401 || status == 403 ? "the charger refused the request (HTTP \(status))" : "the charger answered HTTP \(status)"
        case .invalidResponse(let reason): "the charger's answer is not valid: \(reason)"
        case .missingField(let key): "the charger's answer has no \(key)"
        case .unsupported(let key): "the charger's firmware has no \(key)"
        case .writeRefused(let keyword, let status, let body): "the charger refused \(keyword) (HTTP \(status), \(body.isEmpty ? "empty" : "\"\(body)\""))"
        case .outOfRange(let keyword, let value, let allowed): "\(keyword)=\(value) is out of range (\(allowed))"
        case .rateLimited(let delay): "the charger asks to wait \(delay)"
        case .invalidHost(let host): "\(host) is not an IP address or host name"
        }
    }
}

/// `/RealTimeData`'s body as an object: parsed as it is, else after the repairs for the malformed JSON some firmware
/// sends (3.2): a duplicated `FirmwareVersion` (the last kept), an unquoted version, a missing comma before
/// `"ReadyState":`.
enum TrydanJSON {
    struct Parsed: Sendable, Equatable {
        var object: [String: JSONValue]
        /// The body needed a repair.
        var repaired: Bool
    }

    static func parse(_ data: Data) throws(TrydanError) -> Parsed {
        if let object = strict(data), !hasDuplicateFirmware(data) { return Parsed(object: object, repaired: false) }
        guard let text = String(data: data, encoding: .utf8) else { throw .invalidResponse("not UTF-8 text") }
        let fixed = repair(text)
        guard let object = strict(Data(fixed.utf8)) else {
            throw .invalidResponse(logExcerptOf(text))
        }
        return Parsed(object: object, repaired: true)
    }

    private static func strict(_ data: Data) -> [String: JSONValue]? {
        (try? JSONValue(data: data))?.objectValue
    }

    /// Whether `FirmwareVersion` appears more than once, which a parser keeping the first would read wrong.
    private static func hasDuplicateFirmware(_ data: Data) -> Bool {
        let key = Array(#""FirmwareVersion""#.utf8)
        var count = 0
        let bytes = [UInt8](data)
        guard bytes.count >= key.count else { return false }
        var index = 0
        while index <= bytes.count - key.count {
            if bytes[index] == key[0], Array(bytes[index..<index + key.count]) == key {
                count += 1
                if count > 1 { return true }
                index += key.count
            } else {
                index += 1
            }
        }
        return false
    }

    /// The three repairs, in turn: a bare version quoted, all but the last `"FirmwareVersion":"…",` dropped, a comma
    /// put before `"ReadyState":` where none is.
    static func repair(_ text: String) -> String {
        var text = text
        text = text.replacingOccurrences(
            of: #"("FirmwareVersion"\s*:\s*)(\d+(?:\.\d+)+)"#, with: "$1\"$2\"", options: .regularExpression)
        if let pattern = try? NSRegularExpression(pattern: #""FirmwareVersion"\s*:\s*"[^"]*"\s*,?"#) {
            let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if matches.count > 1 {
                let mutable = NSMutableString(string: text)
                // From the end, so earlier ranges stay where they are; the last one stays.
                for match in matches.dropLast().reversed() { mutable.replaceCharacters(in: match.range, with: "") }
                text = mutable as String
            }
        }
        var output = ""
        output.reserveCapacity(text.count + 4)
        var lastNonSpace: Character?
        var rest = Substring(text)
        let key = #""ReadyState""#
        while let range = rest.range(of: key) {
            let before = rest[rest.startIndex..<range.lowerBound]
            output += before
            if let last = before.last(where: { !$0.isWhitespace }) { lastNonSpace = last }
            if let lastNonSpace, lastNonSpace != ",", lastNonSpace != "{" { output += "," }
            output += key
            lastNonSpace = "\""
            rest = rest[range.upperBound...]
        }
        output += rest
        return output
    }

    /// A body's start for the debug log.
    static func logExcerptOf(_ text: String) -> String {
        text.isEmpty ? "an empty body" : String(text.prefix(200))
    }
}

/// The charger's identifiers (5.4).
enum TrydanIdentity {
    /// The `ID` as a Device Id: trimmed, upper-cased, only `A-Z`, `0-9`, `-` and `_` kept; nil when nothing is left.
    static func deviceID(_ raw: String) -> String? {
        let kept = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().unicodeScalars.filter { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
        let id = String(String.UnicodeScalarView(kept))
        return id.isEmpty ? nil : id
    }

    /// The Device Id of a charger that sends no `ID`: `host-<host>`, normalised the same way.
    static func hostDeviceID(_ host: String) -> String {
        deviceID("host-\(host)") ?? "HOST"
    }

    /// `FirmwareVersion` as Accessory Information's Firmware Revision: `major.minor.patch`, digits only, `0.0.0` when absent.
    static func firmwareRevision(_ version: String?) -> String {
        guard let version else { return "0.0.0" }
        var parts = version.split(separator: ".").map { $0.filter(\.isASCII).filter(\.isNumber) }.filter { !$0.isEmpty }.prefix(3).map { part in
            // Leading zeros dropped, and a number HAP's revision can hold.
            String(Int(part.prefix(9)) ?? 0)
        }
        guard !parts.isEmpty else { return "0.0.0" }
        while parts.count < 3 { parts.append("0") }
        return parts.joined(separator: ".")
    }

    /// An address as the plugin takes it: an IPv4 address or host name, an IPv6 address in brackets, each with an
    /// optional `:port`; nil for anything else (a URL, spaces, a path).
    static func normalizedHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 255 else { return nil }
        var name = Substring(host), port: Substring?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let inside = host[host.index(after: host.startIndex)..<close]
            guard !inside.isEmpty, inside.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }) else { return nil }
            let after = host[host.index(after: close)...]
            if !after.isEmpty {
                guard after.first == ":" else { return nil }
                port = after.dropFirst()
            }
            name = host[...close]
        } else {
            let pieces = host.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            name = pieces[0]
            if pieces.count == 2 { port = pieces[1] }
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else { return nil }
        }
        if let port {
            guard let number = Int(port), (1...65535).contains(number) else { return nil }
            return number == 80 ? String(name) : "\(name):\(number)"
        }
        return String(name)
    }
}
