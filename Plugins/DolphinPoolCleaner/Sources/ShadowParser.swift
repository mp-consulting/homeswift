import Foundation
import Homeswift
import HomeswiftPlugin

/// Whether the filter bag needs emptying.
enum FilterStatus: String, Sendable, Equatable {
    case ok
    case needsCleaning = "needs_cleaning"
    case unknown
}

/// A robot as the plugin knows it, decoded from its AWS IoT thing shadow. A shadow sets only the fields it
/// carries, so a partial push never resets the others.
struct RobotState: Sendable, Equatable {
    var connected = false
    /// The motor unit's state (legacy `mu_state`, `RobotStates`).
    var muState = RobotStates.off
    var pwsState = PWSStates.off
    var isCleaning = false
    var cleaningMode = "all"
    /// The mode the robot will use for its next cycle, as it reports it.
    var nextCycleMode: String?
    /// Minutes.
    var cycleTime: Double = ShadowParser.defaultCycleTime
    /// Minutes.
    var cycleTimeRemaining: Double = 0
    var filterStatus: FilterStatus = .ok
    /// Degrees Celsius.
    var temperature: Double?
    /// Whether the robot runs its smart cleaning (legacy `is_smart`).
    var isSmartMode: Bool?
    var cycleStartTime: Date?
    var faultCode: Int?
    var faultDescription: String?
    var ledEnabled: Bool?
    var ledIntensity: Double?
    var weeklyEnabled: Bool?
    var delayEnabled: Bool?
    /// Minutes.
    var delayTime: Double?
}

/// Decodes AWS IoT thing shadows: the IoT format of current robots and the older BLE format, both read
/// from every document as the Homebridge plugin does.
enum ShadowParser {
    static let defaultCycleTime: Double = 120
    /// September 2001: anything earlier is no cycle start.
    static let minimumValidTimestamp: Double = 1_000_000_000

    static let cleaningRobotStates: Set<String> = ["scanning", "cleaning", "running", "active"]
    static let finishedRobotStates: Set<String> = ["finished", "idle", "off", "notconnected"]
    /// Power supply states that mean the robot is not cleaning.
    static let idlePWSStates: Set<String> = ["off", "idle", "holdweekly", "holddelay", "programming", "error"]
    static let pwsStateNumbers: [String: Int] = [
        "off": PWSStates.off, "idle": PWSStates.idle, "holdweekly": PWSStates.idle, "holddelay": PWSStates.idle,
        "programming": PWSStates.programming, "cleaning": PWSStates.cleaning, "error": PWSStates.error,
    ]
    /// The API's mode names to the plugin's.
    static let modeNames: [String: String] = [
        "standard": "all", "regular": "all", "all": "all", "fast": "short", "short": "short", "floor": "floor", "floor_only": "floor",
        "wall": "wall", "walls": "wall", "waterline": "water", "water": "water", "ultra": "ultra", "ultra_clean": "ultra",
    ]
    /// Modes as numbers, in the legacy format.
    static let numericModes: [Int: String] = [
        0: "all", 1: "short", 2: "floor", 3: "wall", 4: "water", 5: "ultra", 6: "cove", 7: "spot", 8: "tictac", 9: "pickup", 10: "custom", 11: "stairs",
    ]
    static let cleaningMUStates: Set<Int> = [RobotStates.scanning, RobotStates.cleaning, RobotStates.cleaningPause]

    /// Applies a shadow to `existing` (the defaults without one). A document without `state.reported` (an
    /// echo of a desired-only update) changes nothing.
    static func parse(_ shadow: JSONValue?, existing: RobotState = RobotState(), now: Date = Date()) -> RobotState {
        var state = existing
        guard let reported = shadow?["state"]?["reported"], reported.objectValue != nil else { return state }
        applyIoTFormat(reported, to: &state, now: now)
        applyLegacyFormat(reported, to: &state)
        return state
    }

    /// The shadow's version, which says whether anything changed since the last one.
    static func version(of shadow: JSONValue?) -> Int? {
        shadow?["version"]?.saturatingIntValue
    }

    /// A mode name or number as the plugin names it: `regular` and `standard` are `all`, unknown names stay.
    static func cleaningMode(_ mode: JSONValue?) -> String {
        switch mode {
        case .string(let name)?: cleaningMode(name)
        case .number(let number)?: numericModes[Int(saturating: number) ?? 0] ?? "all"
        default: "all"
        }
    }

    static func cleaningMode(_ name: String) -> String {
        let lowercased = name.lowercased()
        return modeNames[lowercased] ?? lowercased
    }

    static func isCleaning(muState: Int) -> Bool { cleaningMUStates.contains(muState) }

    // MARK: Formats

    private static func applyIoTFormat(_ reported: JSONValue, to state: inout RobotState, now: Date) {
        if reported["isConnected"].isTruthy {
            state.connected = reported["isConnected"]?["connected"]?.boolValue == true
        }

        // What this format says about cleaning, nil until one of its objects tells.
        var isCleaning: Bool?
        if let system = reported["systemState"], system.isTruthy {
            let pwsState = system["pwsState"]?.stringValue?.lowercased()
            // The power supply first: its idle states mean the robot is not cleaning.
            if let pwsState, idlePWSStates.contains(pwsState) {
                isCleaning = false
            } else if pwsState == "cleaning" {
                isCleaning = true
            }
            if let robotState = system["robotState"]?.stringValue?.lowercased(), !robotState.isEmpty {
                if cleaningRobotStates.contains(robotState) {
                    isCleaning = true
                } else if finishedRobotStates.contains(robotState) {
                    isCleaning = false
                }
            }
            if let pwsState, let number = pwsStateNumbers[pwsState] { state.pwsState = number }
        }

        // An alternative format.
        if let robot = reported["robotState"], robot.isTruthy {
            let isOn = robot["isOn"]?.boolValue == true
            let pwsState = robot["pwsState"]?.stringValue?.lowercased()
            if pwsState == "cleaning" || pwsState == "running" {
                isCleaning = true
            } else if isCleaning == nil {
                isCleaning = isOn
            }
            if let pwsState, let number = pwsStateNumbers[pwsState] { state.pwsState = number }
        }

        if let cycle = reported["cycleInfo"], cycle.isTruthy {
            let mode = cycle["cleaningMode"]
            // Only a real timestamp: robots report 0 when no cycle ran.
            if let start = cycle["cycleStartTimeUTC"].truthyNumber ?? cycle["cycleStartTime"].truthyNumber, start > minimumValidTimestamp {
                let seconds = (now.timeIntervalSince1970).rounded(.down)
                let cycleTime = mode?["cycleTime"].truthyNumber ?? defaultCycleTime
                let elapsed = (seconds - start) / 60
                // A cycle that started recently and has not run its course is still cleaning.
                if elapsed >= 0, elapsed < cycleTime, isCleaning == nil {
                    isCleaning = true
                    state.cycleStartTime = Date(timeIntervalSince1970: start)
                    state.cycleTimeRemaining = max(0, cycleTime - elapsed)
                }
            }
            if let cycleState = cycle["cycleState"]?.stringValue?.lowercased(), !cycleState.isEmpty, cycleState != "idle" {
                isCleaning = cleaningRobotStates.contains(cycleState)
            }
            if let mode, mode.isTruthy {
                if let name = mode["mode"]?.stringValue?.lowercased(), !name.isEmpty {
                    state.cleaningMode = modeNames[name] ?? name
                }
                if let cycleTime = mode["cycleTime"].truthyNumber { state.cycleTime = cycleTime }
            }
            if let remaining = cycle["cycleTimeRemaining"], remaining.isTruthy {
                // Hours near the largest double would overflow to infinity, which JSON cannot carry.
                if let minutes = ((remaining["hours"].truthyNumber ?? 0) * 60 + (remaining["minutes"].truthyNumber ?? 0)).finite {
                    state.cycleTimeRemaining = minutes
                }
            }
        }
        if let isCleaning { state.isCleaning = isCleaning }

        if let next = reported["nextCycleInfo"]?["cleaningMode"]?["mode"], next.isTruthy {
            state.nextCycleMode = cleaningMode(next)
        }

        if let temperature = reported["inwatTemperature"]?["temperature"]?.doubleValue {
            state.temperature = temperature
        }

        // Left out when the shadow has no filter data, so the known status is kept.
        if let status = FilterParser.status(bag: reported["filterBagIndication"], indicator: reported["filterIndicator"]) {
            state.filterStatus = status
        }

        if let fault = FaultParser.all(
            robotError: reported["robotError"], pwsError: reported["pwsError"], faultCodes: reported["faultCodes"], systemState: reported["systemState"]) {
            state.faultCode = fault.code
            state.faultDescription = fault.description
        }

        // A field the object leaves out keeps its value.
        if let led = reported["led"], led.isTruthy {
            if let enabled = led["ledEnable"]?.boolValue { state.ledEnabled = enabled }
            if let intensity = led["ledIntensity"]?.doubleValue { state.ledIntensity = intensity }
        }
        if let weekly = reported["weeklyTimer"], weekly.isTruthy, let enabled = weekly["enabled"]?.boolValue {
            state.weeklyEnabled = enabled
        }
        if let delayed = reported["delayedOperation"], delayed.isTruthy {
            if let enabled = delayed["enabled"]?.boolValue { state.delayEnabled = enabled }
            if let time = delayed["time"], time.isTruthy {
                if let minutes = ((time["hours"].truthyNumber ?? 0) * 60 + (time["minutes"].truthyNumber ?? 0)).finite { state.delayTime = minutes }
            }
        }
    }

    private static func applyLegacyFormat(_ reported: JSONValue, to state: inout RobotState) {
        // The motor unit's state.
        if let muState = reported["mu_state"]?.saturatingIntValue {
            state.muState = muState
            state.isCleaning = isCleaning(muState: muState)
        }
        // The power supply's state machine.
        if let smState = reported["sm_state"]?.saturatingIntValue {
            state.pwsState = smState
        }
        if let mode = reported["cleaning_mode"] {
            state.cleaningMode = cleaningMode(mode)
        }
        if let filter = reported["filter_state"]?.doubleValue {
            state.filterStatus = FilterParser.legacyStatus(filter)
        }
        // Tenths of a degree Celsius.
        if let temperature = reported["temperature"]?.doubleValue {
            state.temperature = temperature / 10
        }
        if let smart = reported["is_smart"]?.boolValue {
            state.isSmartMode = smart
        }
        // The first four hex digits are the minutes elapsed.
        if let cycleInfo = reported["cycle_info"]?.stringValue, cycleInfo.count >= 4, let elapsed = parseHexPrefix(String(cycleInfo.prefix(4))) {
            state.cycleTimeRemaining = max(0, defaultCycleTime - Double(elapsed))
        }
        if let faults = reported["faults"]?.stringValue, let fault = FaultParser.hexString(faults) {
            state.faultCode = fault.code
            state.faultDescription = fault.description
        }
    }

    /// JavaScript's `parseInt(text, 16)`: the leading hex digits, nil when there are none.
    static func parseHexPrefix(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isHexDigit }
        return digits.isEmpty ? nil : Int(digits, radix: 16)
    }
}

/// The filter bag, from whichever of its formats the shadow carries.
enum FilterParser {
    /// The bag is full above this percentage.
    static let needsCleaningThreshold: Double = 80

    /// `filterBagIndication.state` (0 to 100), `filterIndicator.filterState` (a word) or `filterLevel` (0 is
    /// clean). nil when the shadow has neither object, so a partial push does not reset a known status.
    static func status(bag: JSONValue?, indicator: JSONValue?) -> FilterStatus? {
        let data = bag.isTruthy ? bag : indicator.isTruthy ? indicator : nil
        guard let data else { return nil }

        if let state = data["state"] {
            // As JavaScript compares: a number, or a number in a string; anything else is 0.
            let level = state.doubleValue ?? state.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            return level > needsCleaningThreshold ? .needsCleaning : .ok
        }
        if let word = data["filterState"]?.stringValue?.lowercased(), !word.isEmpty {
            if word == "clean" || word == "ok" { return .ok }
            if word == "dirty" || word == "needs_cleaning" || word == "full" { return .needsCleaning }
        }
        if let level = data["filterLevel"]?.doubleValue {
            return level > 0 ? .needsCleaning : .ok
        }
        return .ok
    }

    /// The legacy number: 0 is clean.
    static func legacyStatus(_ value: Double?) -> FilterStatus {
        guard let value else { return .ok }
        return value > 0 ? .needsCleaning : .ok
    }
}

/// A fault the robot or its power supply reports.
struct FaultInfo: Sendable, Equatable {
    var code: Int
    var description: String
}

/// Fault codes: the robot's, the power supply's and the legacy ones, of the current session only.
enum FaultParser {
    static let notApplicable = 65535
    static let noError = 255

    static let descriptions: [Int: String] = [
        0x01: "Motor fault", 0x02: "Robot out of water", 0x03: "Communication error",
        0x04: "Filter blocked", 0x05: "Impeller blocked", 0x06: "Overheating",
    ]

    static func description(of code: Int) -> String {
        descriptions[code] ?? "Unknown fault (\(code))"
    }

    /// 0, 255 and 65535 mean no error.
    static func isRealErrorCode(_ code: Int?) -> Bool {
        guard let code else { return false }
        return ![0, noError, notApplicable].contains(code)
    }

    /// An error recorded at an earlier power-on (a lower turn-on count) is history, not a current fault.
    static func isCurrentSessionError(_ errorTurnOnCount: Int?, _ currentTurnOnCount: Int?) -> Bool {
        guard let currentTurnOnCount, let errorTurnOnCount else { return true }
        if errorTurnOnCount == notApplicable { return true }
        return errorTurnOnCount >= currentTurnOnCount
    }

    static func robotError(_ data: JSONValue?, currentTurnOnCount: Int?, isPWSError: Bool = false) -> FaultInfo? {
        guard let data, data.isTruthy else { return nil }
        let code = data["errorCode"]?.saturatingIntValue
        guard isRealErrorCode(code), let code else { return nil }
        let turnOnCount = data["turnOnCount"]?.saturatingIntValue
        // A stale robot error still counts while the power supply is in error.
        guard isCurrentSessionError(turnOnCount, currentTurnOnCount) || isPWSError else { return nil }
        return FaultInfo(code: code, description: description(of: code))
    }

    /// The power supply's error, by the robot's rule without the power supply's exception.
    static func pwsError(_ data: JSONValue?, currentTurnOnCount: Int?) -> FaultInfo? {
        robotError(data, currentTurnOnCount: currentTurnOnCount)
    }

    static func legacyFaultCodes(code: Int?, description given: String?) -> FaultInfo? {
        guard isRealErrorCode(code), let code else { return nil }
        let text = given.flatMap { $0.isEmpty ? nil : $0 } ?? description(of: code)
        return FaultInfo(code: code, description: text)
    }

    /// The legacy BLE string: the first byte in hex.
    static func hexString(_ faults: String?) -> FaultInfo? {
        guard let faults, let value = ShadowParser.parseHexPrefix(String(faults.prefix(2))), value > 0 else { return nil }
        return FaultInfo(code: value, description: description(of: value))
    }

    /// The robot's error first, then the power supply's, then the legacy codes.
    static func all(robotError: JSONValue?, pwsError: JSONValue?, faultCodes: JSONValue?, systemState: JSONValue?) -> FaultInfo? {
        let currentTurnOnCount = systemState?["rTurnOnCount"]?.saturatingIntValue
        let isPWSError = systemState?["pwsState"]?.stringValue == "error"
        if let fault = self.robotError(robotError, currentTurnOnCount: currentTurnOnCount, isPWSError: isPWSError) { return fault }
        if let fault = self.pwsError(pwsError, currentTurnOnCount: currentTurnOnCount) { return fault }
        if let faultCodes, faultCodes.isTruthy {
            return legacyFaultCodes(code: faultCodes["faultCode"]?.saturatingIntValue, description: faultCodes["faultDescription"]?.stringValue)
        }
        return nil
    }
}

extension Optional where Wrapped == JSONValue {
    /// JavaScript's truthiness: present, not null, not false, 0 or "".
    var isTruthy: Bool {
        switch self {
        case nil, .null?: false
        case .bool(let value)?: value
        case .number(let value)?: value != 0 && !value.isNaN
        case .string(let value)?: !value.isEmpty
        case .array?, .object?: true
        }
    }

    /// The number, unless it is 0 (what `value || fallback` skips in JavaScript).
    var truthyNumber: Double? {
        guard case .number(let value)? = self, value != 0, !value.isNaN else { return nil }
        return value
    }
}

extension JSONValue {
    var isTruthy: Bool { Optional(self).isTruthy }
}
