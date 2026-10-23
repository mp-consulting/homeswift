import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// The Eve app's custom characteristics that plugins add to their services (energy meters, contact sensors).
///
/// The UUIDs, formats and bounds of homebridge-govee's and homebridge-ewelink's definitions. HAP has no units
/// for watts, volts, amperes or kWh; Eve knows them by UUID.
public enum EveCharacteristic {
    private static func eve(_ short: String) -> HAPUUID { HAPUUID("E863\(short)-079E-48FF-8F27-9C2605A29F52") }

    /// Watts.
    public static let currentConsumption = CharacteristicType(
        name: "Current Consumption", uuid: eve("F10D"), format: .uint16, permissions: [.pairedRead, .events], minValue: 0, maxValue: 100_000, minStep: 1
    )
    /// kWh.
    public static let totalConsumption = CharacteristicType(
        name: "Total Consumption", uuid: eve("F10C"), format: .float, permissions: [.pairedRead, .events], minValue: 0, maxValue: 100_000_000_000,
        minStep: 0.01
    )
    /// Volts.
    public static let voltage = CharacteristicType(
        name: "Voltage", uuid: eve("F10A"), format: .float, permissions: [.pairedRead, .events], minValue: 0, maxValue: 100_000_000_000, minStep: 1
    )
    /// Amperes.
    public static let electricCurrent = CharacteristicType(
        name: "Electric Current", uuid: eve("F126"), format: .float, permissions: [.pairedRead, .events], minValue: 0, maxValue: 100_000_000_000,
        minStep: 0.1
    )
    /// Seconds since 2001-01-01 when Eve's total was reset; Eve writes it.
    public static let resetTotal = CharacteristicType(
        name: "Reset Total", uuid: eve("F112"), format: .uint32, permissions: [.pairedRead, .events, .pairedWrite], unit: .seconds
    )
    /// Seconds since the history's initial time (`EveHistory.initialTime`).
    public static let lastActivation = CharacteristicType(
        name: "Last Activation", uuid: eve("F11A"), format: .uint32, permissions: [.pairedRead, .events], unit: .seconds
    )
    public static let openDuration = CharacteristicType(
        name: "Open Duration", uuid: eve("F118"), format: .uint32, permissions: [.pairedRead, .events, .pairedWrite], unit: .seconds
    )
    public static let closedDuration = CharacteristicType(
        name: "Closed Duration", uuid: eve("F119"), format: .uint32, permissions: [.pairedRead, .events, .pairedWrite], unit: .seconds
    )
    public static let timesOpened = CharacteristicType(
        name: "Times Opened", uuid: eve("F129"), format: .uint32, permissions: [.pairedRead, .events]
    )
    /// hPa.
    public static let airPressure = CharacteristicType(
        name: "Air Pressure", uuid: eve("F10F"), format: .uint16, permissions: [.pairedRead, .events], minValue: 700, maxValue: 1100, minStep: 1
    )
    /// ppm.
    public static let airQuality = CharacteristicType(
        name: "Air Quality PPM", uuid: eve("F10B"), format: .uint16, permissions: [.pairedRead, .events], minValue: 0, maxValue: 5000, minStep: 1
    )
    public static let valvePosition = CharacteristicType(
        name: "Valve Position", uuid: eve("F12E"), format: .uint8, permissions: [.pairedRead, .events], unit: .percentage, minValue: 0, maxValue: 100
    )

    // The history service's own characteristics.
    public static let historyStatus = CharacteristicType(name: "S2R1", uuid: eve("F116"), format: .data, permissions: [.pairedRead, .events, .hidden])
    public static let historyEntries = CharacteristicType(name: "S2R2", uuid: eve("F117"), format: .data, permissions: [.pairedRead, .events, .hidden])
    public static let historyRequest = CharacteristicType(name: "S2W1", uuid: eve("F11C"), format: .data, permissions: [.pairedWrite, .hidden])
    public static let historySetTime = CharacteristicType(name: "S2W2", uuid: eve("F121"), format: .data, permissions: [.pairedWrite, .hidden])
}

extension ServiceType {
    /// Eve's history service (`E863F007`), as `EveHistory` builds it.
    public static let eveHistory = ServiceType(
        name: "Eve History", uuid: HAPUUID("E863F007-079E-48FF-8F27-9C2605A29F52"),
        required: [EveCharacteristic.historyStatus, EveCharacteristic.historyEntries, EveCharacteristic.historyRequest, EveCharacteristic.historySetTime]
    )
}

/// The history the Eve app graphs, a port of fakegato-history 0.6.7: a ring of entries the app reads through
/// the history service's S2R1/S2R2/S2W1/S2W2 characteristics, with the same byte layouts.
///
/// Add `service` to the accessory, then `add` readings. Like fakegato, energy, weather, room and custom
/// readings of power, temperature or light are averaged over `interval` (10 minutes) before they become an
/// entry, and door, motion and switch states are recorded at once and repeated every interval; pass
/// `averaging: false` (fakegato's `disableTimer`) to record every reading as it comes.
///
/// ```swift
/// let history = EveHistory(.energy, accessoryName: "Desk Plug")
/// let accessory = Accessory(id: id, name: "Desk Plug", category: .outlet, services: [outlet, history.service])
/// history.add(EveHistory.Entry(power: 42.5))
/// ```
public final class EveHistory: Sendable {
    /// fakegato's accessory types. `custom` records the fields given, which `fields(of:)` finds on an accessory's
    /// services the way fakegato does.
    public enum Kind: Sendable, Equatable {
        case weather, energy, room, room2, door, motion, `switch`, thermo, aqua
        case custom([Field])

        var name: String {
            switch self {
            case .weather: "weather"
            case .energy: "energy"
            case .room: "room"
            case .room2: "room2"
            case .door: "door"
            case .motion: "motion"
            case .switch: "switch"
            case .thermo: "thermo"
            case .aqua: "aqua"
            case .custom: "custom"
            }
        }
    }

    /// A value a custom history records: its signature in S2R1, its size and scale in an entry.
    public enum Field: String, Sendable, CaseIterable {
        case temperature, voc, humidity, pressure, ppm, contact, power, status, motion, targetTemperature, valvePosition, lux

        var signature: String {
            switch self {
            case .temperature: "0102"
            case .voc: "2202"
            case .humidity: "0202"
            case .pressure: "0302"
            case .ppm, .power: "0702"
            case .contact: "0601"
            case .status: "0e01"
            case .motion: "1c01"
            case .targetTemperature: "1102"
            case .valvePosition: "1001"
            case .lux: "3002"
            }
        }

        /// Hex digits in an entry: 4 is a little-endian UInt16, 2 one byte.
        var length: Int {
            switch self {
            case .contact, .status, .motion, .valvePosition: 2
            default: 4
            }
        }

        var factor: Double {
            switch self {
            case .temperature, .humidity, .targetTemperature: 100
            case .pressure, .ppm, .power: 10
            default: 1
            }
        }

        var keyPath: KeyPath<Entry, Double?> {
            switch self {
            case .temperature: \.temp
            case .voc: \.voc
            case .humidity: \.humidity
            case .pressure: \.pressure
            case .ppm: \.ppm
            case .contact: \.contact
            case .power: \.power
            case .status: \.status
            case .motion: \.motion
            case .targetTemperature: \.setTemp
            case .valvePosition: \.valvePosition
            case .lux: \.lux
            }
        }

        static func field(for uuid: HAPUUID) -> Field? {
            switch uuid {
            case CharacteristicType.currentTemperature.uuid: .temperature
            case CharacteristicType.vocDensity.uuid: .voc
            case CharacteristicType.currentRelativeHumidity.uuid: .humidity
            case EveCharacteristic.airPressure.uuid: .pressure
            case EveCharacteristic.airQuality.uuid: .ppm
            case CharacteristicType.contactSensorState.uuid: .contact
            case EveCharacteristic.currentConsumption.uuid: .power
            case CharacteristicType.on.uuid: .status
            case CharacteristicType.motionDetected.uuid: .motion
            case CharacteristicType.targetTemperature.uuid: .targetTemperature
            case EveCharacteristic.valvePosition.uuid: .valvePosition
            case CharacteristicType.currentAmbientLightLevel.uuid: .lux
            default: nil
            }
        }
    }

    /// One reading. The names are fakegato's (`temp`, `setTemp`, `currentTemp`), and so is the JSON.
    public struct Entry: Sendable, Equatable, Codable {
        /// Unix seconds.
        public var time: Int
        public var temp: Double?
        public var humidity: Double?
        public var pressure: Double?
        public var ppm: Double?
        public var voc: Double?
        public var power: Double?
        /// On/off, open/closed, motion: 0 or 1.
        public var status: Double?
        public var contact: Double?
        public var motion: Double?
        public var currentTemp: Double?
        public var setTemp: Double?
        public var valvePosition: Double?
        public var lux: Double?
        public var waterAmount: Double?
        var setRefTime: Int?

        public init(
            time: Date = Date(), temp: Double? = nil, humidity: Double? = nil, pressure: Double? = nil, ppm: Double? = nil, voc: Double? = nil,
            power: Double? = nil, status: Double? = nil, contact: Double? = nil, motion: Double? = nil, currentTemp: Double? = nil,
            setTemp: Double? = nil, valvePosition: Double? = nil, lux: Double? = nil, waterAmount: Double? = nil
        ) {
            self.init(
                unixTime: Int(time.timeIntervalSince1970.rounded()), temp: temp, humidity: humidity, pressure: pressure, ppm: ppm, voc: voc,
                power: power, status: status, contact: contact, motion: motion, currentTemp: currentTemp, setTemp: setTemp,
                valvePosition: valvePosition, lux: lux, waterAmount: waterAmount
            )
        }

        public init(
            unixTime: Int, temp: Double? = nil, humidity: Double? = nil, pressure: Double? = nil, ppm: Double? = nil, voc: Double? = nil,
            power: Double? = nil, status: Double? = nil, contact: Double? = nil, motion: Double? = nil, currentTemp: Double? = nil,
            setTemp: Double? = nil, valvePosition: Double? = nil, lux: Double? = nil, waterAmount: Double? = nil
        ) {
            self.time = unixTime
            self.temp = temp
            self.humidity = humidity
            self.pressure = pressure
            self.ppm = ppm
            self.voc = voc
            self.power = power
            self.status = status
            self.contact = contact
            self.motion = motion
            self.currentTemp = currentTemp
            self.setTemp = setTemp
            self.valvePosition = valvePosition
            self.lux = lux
            self.waterAmount = waterAmount
        }

        static func marker(time: Int) -> Entry {
            var entry = Entry(unixTime: time)
            entry.setRefTime = 1
            return entry
        }

        /// The averaged fields, in fakegato's order.
        static var averagedKeys: [WritableKeyPath<Entry, Double?>] { [
            \.temp, \.humidity, \.pressure, \.ppm, \.voc, \.power, \.status, \.contact, \.motion, \.currentTemp, \.setTemp, \.valvePosition,
            \.lux, \.waterAmount,
        ] }
    }

    /// What fakegato persists, in its JSON shape.
    struct Persisted: Codable {
        var firstEntry: Int
        var lastEntry: Int
        var usedMemory: Int
        var refTime: Int
        var initialTime: Int?
        var history: [Entry?]
        var extra: String?

        init(state: State) {
            firstEntry = state.firstEntry
            lastEntry = state.lastEntry
            usedMemory = state.usedMemory
            refTime = state.refTime
            initialTime = state.initialTime
            let count = (state.history.keys.max() ?? 0) + 1
            history = (0..<count).map { state.history[$0] }
            extra = state.extra
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            firstEntry = try container.decode(Int.self, forKey: .firstEntry)
            lastEntry = try container.decode(Int.self, forKey: .lastEntry)
            usedMemory = try container.decode(Int.self, forKey: .usedMemory)
            refTime = try container.decode(Int.self, forKey: .refTime)
            initialTime = try container.decodeIfPresent(Int.self, forKey: .initialTime)
            extra = try? container.decodeIfPresent(String.self, forKey: .extra)
            // The first element is fakegato's "noValue" string; holes are null.
            var array = try container.nestedUnkeyedContainer(forKey: .history)
            var history: [Entry?] = []
            while !array.isAtEnd {
                if let entry = try? array.decode(Entry.self) {
                    history.append(entry)
                } else {
                    _ = try? array.decode(String?.self)
                    history.append(nil)
                }
            }
            self.history = history
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(firstEntry, forKey: .firstEntry)
            try container.encode(lastEntry, forKey: .lastEntry)
            try container.encode(usedMemory, forKey: .usedMemory)
            try container.encode(refTime, forKey: .refTime)
            try container.encodeIfPresent(initialTime, forKey: .initialTime)
            try container.encodeIfPresent(extra, forKey: .extra)
            var array = container.nestedUnkeyedContainer(forKey: .history)
            for (index, entry) in history.enumerated() {
                if index == 0, entry == nil { try array.encode("noValue") } else { try array.encode(entry) }
            }
        }

        enum CodingKeys: String, CodingKey { case firstEntry, lastEntry, usedMemory, refTime, initialTime, history, extra }
    }

    struct State {
        var firstEntry = 0
        var lastEntry = 0
        var history: [Int: Entry] = [:]
        var usedMemory = 0
        var currentEntry = 1
        var transfer = false
        var setTime = true
        var restarted = true
        var refTime = 0
        var initialTime: Int?
        var extra: String?
        // The averaging timer's backlog (fakegato-timer).
        var backLog: [Entry] = []
        var previousAverage: Entry?
        var timer: Task<Void, Never>?
        /// A change waits to be written (`save()`).
        var savePending = false
    }

    static let epochOffset = 978_307_200

    public let kind: Kind
    /// Add it to the accessory.
    public let service: Service
    public let memorySize: Int
    public let interval: Duration
    public let averaging: Bool
    /// fakegato's `disableRepeatLastData`: an interval without readings repeats nothing.
    public let repeatsLastData: Bool
    /// The S2R1 description of the entries' fields, and the entry type in S2R2.
    private let type116: String
    private let type117: String
    private let fields: [Field]
    private let storageURL: URL?
    private let now: @Sendable () -> Date
    let state = NIOLockedValueBox(State())

    /// - Parameters:
    ///   - accessoryName: The service is named "<name> History", like fakegato's.
    ///   - size: Entries kept (fakegato's `size`, 4032: four weeks of 10-minute entries).
    ///   - storageURL: A JSON file (fakegato's format) to keep the history across launches; written owner-only.
    public init(
        _ kind: Kind, accessoryName: String, size: Int = 4032, interval: Duration = .seconds(600), averaging: Bool = true,
        repeatsLastData: Bool = true, storageURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.kind = kind
        self.memorySize = size
        self.interval = interval
        self.averaging = averaging
        self.repeatsLastData = repeatsLastData
        self.storageURL = storageURL
        self.now = now
        let base116: String
        switch kind {
        case .weather: (base116, type117) = ("03 0102 0202 0302", "07")
        case .energy: (base116, type117) = ("04 0102 0202 0702 0f03", "1f")
        case .room: (base116, type117) = ("04 0102 0202 0402 0f03", "0f")
        case .room2: (base116, type117) = ("07 0102 0202 2202 2901 2501 2302 2801", "7f")
        case .door: (base116, type117) = ("01 0601", "01")
        case .motion: (base116, type117) = ("02 1301 1c01", "02")
        case .switch: (base116, type117) = ("01 0e01", "01")
        case .aqua: (base116, type117) = ("03 1f01 2a08 2302", "05")
        case .thermo: (base116, type117) = ("05 0102 1102 1001 1201 1d01", "1f")
        case .custom: (base116, type117) = ("", "")
        }
        if case .custom(let custom) = kind {
            // fakegato sorts the signatures (stably) and numbers the entry's fields in that order.
            fields = custom.enumerated().sorted { ($0.element.signature, $0.offset) < ($1.element.signature, $1.offset) }.map(\.element)
        } else {
            fields = []
        }
        // fakegato writes the count in decimal after a 0; the same for fewer than ten fields.
        type116 = if case .custom = kind { String(format: "%02x", fields.count) + fields.map(\.signature).joined() } else { base116 }

        service = Service(.eveHistory, name: "\(accessoryName.prefix(1).uppercased())\(accessoryName.dropFirst()) History", subtype: kind.name)
        service.characteristic(EveCharacteristic.historyEntries).onRead { [weak self] in
            .string(self?.readEntries() ?? Self.base64("00"))
        }
        service.characteristic(EveCharacteristic.historyRequest).onWrite { [weak self] value in
            self?.requestEntries(value.stringValue ?? "")
        }
        service.characteristic(EveCharacteristic.historySetTime).onWrite { _ in }
        load()
    }

    /// The custom fields fakegato would find on these services (every characteristic it knows, in order).
    public static func fields(of services: [Service]) -> [Field] {
        services.flatMap { $0.characteristics.compactMap { Field.field(for: $0.type.uuid) } }
    }

    deinit {
        state.withLockedValue { $0.timer?.cancel() }
        flush()
    }

    /// The time of the first entry (Unix seconds); Eve's Last Activation counts from it.
    public var initialTime: Int? { state.withLockedValue { $0.initialTime } }

    /// fakegato's `setExtraPersistedData`: a string kept with the history (e.g. a total consumption).
    public var extraPersistedData: String? {
        get { state.withLockedValue { $0.extra } }
        set {
            state.withLockedValue { $0.extra = newValue }
            save()
        }
    }

    /// Records a reading, through the averaging timer like fakegato's `addEntry`.
    public func add(_ entry: Entry) {
        guard averaging else {
            switch kind {
            case .door, .motion, .switch: record(Entry(unixTime: entry.time, status: entry.status))
            case .weather: record(Entry(unixTime: entry.time, temp: entry.temp, humidity: entry.humidity, pressure: entry.pressure))
            case .room: record(Entry(unixTime: entry.time, temp: entry.temp, humidity: entry.humidity, ppm: entry.ppm))
            case .room2: record(Entry(unixTime: entry.time, temp: entry.temp, humidity: entry.humidity, voc: entry.voc))
            case .energy: record(Entry(unixTime: entry.time, power: entry.power))
            case .aqua: record(Entry(unixTime: entry.time, status: entry.status, waterAmount: entry.waterAmount))
            case .thermo, .custom: record(entry)
            }
            return
        }
        switch kind {
        case .door, .motion, .switch:
            // Replaces the backlog and is recorded at once; every interval repeats it with the current time.
            state.withLockedValue { $0.backLog = [entry] }
            record(Entry(unixTime: entry.time, status: entry.status))
            startTimer()
        case .aqua:
            record(Entry(unixTime: entry.time, status: entry.status, waterAmount: entry.waterAmount))
        case .thermo:
            record(entry)
        case .weather, .room, .room2, .energy:
            state.withLockedValue { $0.backLog.append(entry) }
            startTimer()
        case .custom:
            if entry.power != nil || entry.temp != nil || entry.lux != nil {
                state.withLockedValue { $0.backLog.append(entry) }
                startTimer()
            } else {
                record(entry)
            }
        }
    }

    private func startTimer() {
        let interval = interval
        state.withLockedValue { state in
            guard state.timer == nil else { return }
            state.timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        }
    }

    /// One period of fakegato's timer: averages the backlog into an entry (or repeats the last state).
    func tick() {
        let time = Int(now().timeIntervalSince1970.rounded())
        switch kind {
        case .door, .motion, .switch:
            guard let last = state.withLockedValue({ $0.backLog.first }) else { return }
            record(Entry(unixTime: time, status: last.status))
        case .weather, .room, .room2, .energy, .custom:
            let (backLog, previous) = state.withLockedValue { ($0.backLog, $0.previousAverage) }
            var average = Entry(unixTime: time)
            var keys = 0
            for key in Entry.averagedKeys {
                let values = backLog.compactMap { $0[keyPath: key] }
                if !values.isEmpty {
                    // JavaScript's Math.round: halves round up.
                    var value = ((values.reduce(0, +) / Double(values.count)) * 100 + 0.5).rounded(.down) / 100
                    if key == \Entry.voc { value = (value + 0.5).rounded(.down) }
                    average[keyPath: key] = value
                } else if repeatsLastData, let previous, let value = previous[keyPath: key] {
                    average[keyPath: key] = value
                }
                if average[keyPath: key] != nil { keys += 1 }
            }
            state.withLockedValue { $0.previousAverage = average }
            if keys > 0 {
                record(average)
                state.withLockedValue { $0.backLog = [] }
            }
        case .aqua, .thermo:
            return
        }
    }

    /// fakegato's `_addEntry`: stores the entry in the ring and updates S2R1.
    func record(_ entry: Entry) {
        let status = state.withLockedValue { state -> String in
            let size = memorySize
            if state.usedMemory < size {
                state.usedMemory += 1
                state.firstEntry = 0
                state.lastEntry = state.usedMemory
            } else {
                state.firstEntry += 1
                state.lastEntry = state.firstEntry + state.usedMemory
                if state.restarted {
                    state.history[state.lastEntry % size] = .marker(time: entry.time)
                    state.firstEntry += 1
                    state.lastEntry = state.firstEntry + state.usedMemory
                    state.restarted = false
                }
            }
            if state.refTime == 0 {
                state.refTime = entry.time - Self.epochOffset
                state.history[state.lastEntry] = .marker(time: entry.time)
                state.initialTime = entry.time
                state.lastEntry += 1
                state.usedMemory += 1
            }
            state.history[state.lastEntry % size] = entry
            let full = state.usedMemory >= size
            return Self.hex32(entry.time - state.refTime - Self.epochOffset) + "00000000" + Self.hex32(state.refTime) + type116
                + Self.hex16(Double(full ? state.usedMemory : state.usedMemory + 1)) + Self.hex16(Double(size))
                + Self.hex32(full ? state.firstEntry + 1 : state.firstEntry) + "000000000101"
        }
        service.characteristic(EveCharacteristic.historyStatus).value = .string(Self.base64(status))
        save()
    }

    /// S2W1: the Eve app asks for the entries from an address.
    func requestEntries(_ base64: String) {
        guard let bytes = Data(base64Encoded: base64), bytes.count >= 6 else { return }
        let address = Int(UInt32(bytes[bytes.startIndex + 2]) | UInt32(bytes[bytes.startIndex + 3]) << 8 | UInt32(bytes[bytes.startIndex + 4]) << 16
            | UInt32(bytes[bytes.startIndex + 5]) << 24)
        state.withLockedValue { state in
            state.currentEntry = address != 0 ? address : 1
            state.transfer = true
        }
    }

    /// S2R2: up to 11 entries from the requested address, then `00` once the transfer is over.
    func readEntries() -> String {
        let hex = state.withLockedValue { state -> String in
            guard state.currentEntry <= state.lastEntry, state.transfer else {
                state.transfer = false
                return "00"
            }
            let size = memorySize
            var stream = ""
            for _ in 0..<11 {
                let entry = state.history[state.currentEntry % size] ?? Entry(unixTime: 0)
                if entry.setRefTime == 1 || state.setTime || state.currentEntry == state.firstEntry + 1 {
                    stream += "15" + Self.hex32(state.currentEntry) + "01000000" + "81" + Self.hex32(state.refTime) + "00000000000000"
                    state.setTime = false
                } else {
                    stream += self.encode(entry, address: state.currentEntry, refTime: state.refTime)
                }
                state.currentEntry += 1
                if state.currentEntry > state.lastEntry { break }
            }
            return stream
        }
        return Self.base64(hex)
    }

    private func encode(_ entry: Entry, address: Int, refTime: Int) -> String {
        let head = Self.hex32(address) + Self.hex32(entry.time - refTime - Self.epochOffset)
        func v(_ value: Double?) -> Double { value ?? .nan }
        switch kind {
        case .weather:
            return "10" + head + type117 + Self.hex16(v(entry.temp) * 100) + Self.hex16(v(entry.humidity) * 100) + Self.hex16(v(entry.pressure) * 10)
        case .energy:
            return "14" + head + type117 + "00000000" + Self.hex16(v(entry.power) * 10) + "00000000"
        case .room:
            return "13" + head + type117 + Self.hex16(v(entry.temp) * 100) + Self.hex16(v(entry.humidity) * 100) + Self.hex16(v(entry.ppm)) + "000000"
        case .room2:
            return "15" + head + type117 + Self.hex16(v(entry.temp) * 100) + Self.hex16(v(entry.humidity) * 100) + Self.hex16(v(entry.voc)) + "0054a80f01"
        case .door, .motion, .switch:
            return "0b" + head + type117 + Self.hex8(v(entry.status))
        case .aqua:
            if entry.status == 1 {
                return "0d" + head + "05" + Self.hex8(v(entry.status)) + "300c"
            }
            return "15" + head + "07" + Self.hex8(v(entry.status)) + Self.hex32(Int(Self.int32(v(entry.waterAmount)))) + "00000000300c"
        case .thermo:
            return "11" + head + type117 + Self.hex16(v(entry.currentTemp) * 100) + Self.hex16(v(entry.setTemp) * 100) + Self.hex8(v(entry.valvePosition))
                + "0000"
        case .custom:
            var bitmask = 0
            var values = ""
            for (index, field) in fields.enumerated() {
                guard let value = entry[keyPath: field.keyPath] else { continue }
                let scaled = value * field.factor
                switch field.length {
                case 4: values += Self.hex16(scaled)
                default: values += Self.hex8(scaled)
                }
                bitmask += 1 << index
            }
            let body = head + Self.hex8(Double(bitmask)) + values
            return Self.evenHex(body.count / 2 + 1) + body
        }
    }

    // MARK: - fakegato's number formatting

    /// JavaScript's ToInt32: truncation, then modulo 2^32.
    static func int32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let truncated = value.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)
        return Int32(truncatingIfNeeded: Int64(truncated))
    }

    /// `numToHex(swap32(value), 8)`: four bytes, little-endian.
    static func hex32(_ value: Int) -> String {
        Secrets.hex(withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian, Array.init))
    }

    /// `numToHex(swap16(value), 4)`: two bytes, little-endian, of the value truncated like JavaScript's bit operators.
    static func hex16(_ value: Double) -> String {
        Secrets.hex(withUnsafeBytes(of: UInt16(truncatingIfNeeded: int32(value)).littleEndian, Array.init))
    }

    /// `numToHex(value, 2)`: the low byte.
    static func hex8(_ value: Double) -> String {
        Secrets.hex([UInt8(truncatingIfNeeded: int32(value))])
    }

    /// `numToHex(value)`: hex padded to an even number of digits.
    static func evenHex(_ value: Int) -> String {
        let hex = String(value, radix: 16)
        return hex.count.isMultiple(of: 2) ? hex : "0" + hex
    }

    /// The bytes of hex digits (spaces and other separators skipped), base64.
    static func base64(_ hex: String) -> String {
        HAPTLV.hexBytes(hex.filter(\.isHexDigit)).base64EncodedString()
    }

    // MARK: - Persistence

    /// Writes the history soon, once for a burst of changes (an entry and the extra data of the same reading).
    private func save() {
        guard storageURL != nil else { return }
        let schedule = state.withLockedValue { state -> Bool in
            defer { state.savePending = true }
            return !state.savePending
        }
        guard schedule else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.flush()
        }
    }

    /// Writes the pending changes to the storage file now.
    public func flush() {
        guard let storageURL else { return }
        let persisted = state.withLockedValue { state -> Persisted? in
            guard state.savePending else { return nil }
            state.savePending = false
            return Persisted(state: state)
        }
        guard let persisted, let data = try? JSONEncoder().encode(persisted) else { return }
        try? OwnerOnlyFile.write(data, to: storageURL)
    }

    private func load() {
        guard let storageURL, let data = try? Data(contentsOf: storageURL), let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        state.withLockedValue { state in
            state.firstEntry = persisted.firstEntry
            state.lastEntry = persisted.lastEntry
            state.usedMemory = persisted.usedMemory
            state.refTime = persisted.refTime
            state.initialTime = persisted.initialTime
            state.extra = persisted.extra
            state.history = [:]
            for (index, entry) in persisted.history.enumerated() {
                if let entry { state.history[index] = entry }
            }
        }
    }
}
