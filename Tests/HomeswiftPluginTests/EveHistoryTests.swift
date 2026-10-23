import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftPlugin

/// The expected values come from fakegato-history 0.6.7 itself, run in Node on HAP-NodeJS with the same entries
/// (`disableTimer: true`): S2R1 after each entry, then S2R2 read after the Eve app's S2W1 request for address 1.
@Suite("Eve history")
struct EveHistoryTests {
    /// 2026-10-22T08:00:00Z
    let t = 1_792_656_000
    let requestFromAddress1 = "ARQBAAAAAAAAAAA="

    func run(_ history: EveHistory, _ entries: [EveHistory.Entry]) async throws -> (s2r1: [String], s2r2: [String]) {
        var s2r1: [String] = []
        for entry in entries {
            history.add(entry)
            s2r1.append(history.service.characteristic(EveCharacteristic.historyStatus).value.stringValue ?? "")
        }
        try await history.service.characteristic(EveCharacteristic.historyRequest).write(.string(requestFromAddress1))
        let read = try #require(history.service.characteristic(EveCharacteristic.historyEntries).readHandler)
        var s2r2: [String] = []
        for _ in 0..<10 {
            let value = try await read().stringValue ?? ""
            s2r2.append(value)
            if value == "AA==" { break }
        }
        return (s2r1, s2r2)
    }

    @Test func serviceShape() {
        let history = EveHistory(.energy, accessoryName: "energy")
        #expect(history.service.type.uuid == HAPUUID("E863F007-079E-48FF-8F27-9C2605A29F52"))
        #expect(history.service.subtype == "energy")
        #expect(history.service[.name]?.value == .string("Energy History"))
        #expect(
            history.service.characteristics.map(\.type.uuid.uuidString) == [
                "E863F116-079E-48FF-8F27-9C2605A29F52", "E863F117-079E-48FF-8F27-9C2605A29F52", "E863F11C-079E-48FF-8F27-9C2605A29F52",
                "E863F121-079E-48FF-8F27-9C2605A29F52", "00000023-0000-1000-8000-0026BB765291",
            ]
        )
    }

    @Test func energy() async throws {
        let result = try await run(
            EveHistory(.energy, accessoryName: "Energy", averaging: false),
            [.init(unixTime: t, power: 12.3), .init(unixTime: t + 600, power: 45.67), .init(unixTime: t + 1200, power: 0)]
        )
        #expect(result.s2r1 == [
            "AAAAAAAAAAAA+okwBAECAgIHAg8DAwDADwAAAAAAAAAAAQE=", "WAIAAAAAAAAA+okwBAECAgIHAg8DBADADwAAAAAAAAAAAQE=",
            "sAQAAAAAAAAA+okwBAECAgIHAg8DBQDADwAAAAAAAAAAAQE=",
        ])
        #expect(result.s2r2 == [
            "FQEAAAABAAAAgQD6iTAAAAAAAAAAFAIAAAAAAAAAHwAAAAB7AAAAAAAUAwAAAFgCAAAfAAAAAMgBAAAAABQEAAAAsAQAAB8AAAAAAAAAAAAA", "AA==",
        ])
    }

    @Test func switchMotionAndDoor() async throws {
        let switched = try await run(EveHistory(.switch, accessoryName: "Switch", averaging: false), [.init(unixTime: t, status: 1), .init(unixTime: t + 30, status: 0)])
        #expect(switched.s2r1 == ["AAAAAAAAAAAA+okwAQ4BAwDADwAAAAAAAAAAAQE=", "HgAAAAAAAAAA+okwAQ4BBADADwAAAAAAAAAAAQE="])
        #expect(switched.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAACwIAAAAAAAAAAQELAwAAAB4AAAABAA==", "AA=="])

        let motion = try await run(EveHistory(.motion, accessoryName: "Motion", averaging: false), [.init(unixTime: t, status: 1)])
        #expect(motion.s2r1 == ["AAAAAAAAAAAA+okwAhMBHAEDAMAPAAAAAAAAAAABAQ=="])
        #expect(motion.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAACwIAAAAAAAAAAgE=", "AA=="])

        let door = try await run(EveHistory(.door, accessoryName: "Door", averaging: false), [.init(unixTime: t, status: 0), .init(unixTime: t + 5, status: 1)])
        #expect(door.s2r1 == ["AAAAAAAAAAAA+okwAQYBAwDADwAAAAAAAAAAAQE=", "BQAAAAAAAAAA+okwAQYBBADADwAAAAAAAAAAAQE="])
        #expect(door.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAACwIAAAAAAAAAAQALAwAAAAUAAAABAQ==", "AA=="])
    }

    @Test func weatherWithNegativeTemperaturesAndJavaScriptTruncation() async throws {
        let result = try await run(
            EveHistory(.weather, accessoryName: "Weather", averaging: false),
            [.init(unixTime: t, temp: 21.37, humidity: 48.5, pressure: 1013.2), .init(unixTime: t + 600, temp: -3.25, humidity: 0.29, pressure: 990)]
        )
        #expect(result.s2r1 == ["AAAAAAAAAAAA+okwAwECAgIDAgMAwA8AAAAAAAAAAAEB", "WAIAAAAAAAAA+okwAwECAgIDAgQAwA8AAAAAAAAAAAEB"])
        #expect(result.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAAEAIAAAAAAAAAB1kI8hKUJxADAAAAWAIAAAe7/hwArCY=", "AA=="])
    }

    @Test func roomRoom2AndThermo() async throws {
        let room = try await run(EveHistory(.room, accessoryName: "Room", averaging: false), [.init(unixTime: t, temp: 22.5, humidity: 40, ppm: 650)])
        #expect(room.s2r1 == ["AAAAAAAAAAAA+okwBAECAgIEAg8DAwDADwAAAAAAAAAAAQE="])
        #expect(room.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAAEwIAAAAAAAAAD8oIoA+KAgAAAA==", "AA=="])

        let room2 = try await run(EveHistory(.room2, accessoryName: "Room2", averaging: false), [.init(unixTime: t, temp: 22.5, humidity: 40, voc: 120)])
        #expect(room2.s2r1 == ["AAAAAAAAAAAA+okwBwECAgIiAikBJQEjAigBAwDADwAAAAAAAAAAAQE="])
        #expect(room2.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAAFQIAAAAAAAAAf8oIoA94AABUqA8B", "AA=="])

        let thermo = try await run(
            EveHistory(.thermo, accessoryName: "Thermo", averaging: false), [.init(unixTime: t, currentTemp: 19.5, setTemp: 21, valvePosition: 40)]
        )
        #expect(thermo.s2r1 == ["AAAAAAAAAAAA+okwBQECEQIQARIBHQEDAMAPAAAAAAAAAAABAQ=="])
        #expect(thermo.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAAEQIAAAAAAAAAH54HNAgoAAA=", "AA=="])
    }

    /// homebridge-govee's thermo-hygrometers: a custom history over a temperature and a humidity sensor.
    @Test func customFieldsFoundOnTheServices() async throws {
        let fields = EveHistory.fields(of: [Service(.temperatureSensor), Service(.humiditySensor)])
        #expect(fields == [.temperature, .humidity])
        let result = try await run(
            EveHistory(.custom(fields), accessoryName: "Custom", averaging: false),
            [.init(unixTime: t, temp: 21.37, humidity: 48.5), .init(unixTime: t + 600, temp: 20), .init(unixTime: t + 1200, humidity: 55)]
        )
        #expect(result.s2r1 == [
            "AAAAAAAAAAAA+okwAgECAgIDAMAPAAAAAAAAAAABAQ==", "WAIAAAAAAAAA+okwAgECAgIEAMAPAAAAAAAAAAABAQ==",
            "sAQAAAAAAAAA+okwAgECAgIFAMAPAAAAAAAAAAABAQ==",
        ])
        #expect(result.s2r2 == ["FQEAAAABAAAAgQD6iTAAAAAAAAAADgIAAAAAAAAAA1kI8hIMAwAAAFgCAAAB0AcMBAAAALAEAAACfBU=", "AA=="])
    }

    /// A ring of four entries written six times: the marker after the restart, the addresses modulo the size.
    @Test func wrapsAroundTheMemory() async throws {
        let result = try await run(
            EveHistory(.energy, accessoryName: "Wrap", size: 4, averaging: false), (1...6).map { .init(unixTime: t + $0 * 600, power: Double($0)) }
        )
        #expect(result.s2r1 == [
            "AAAAAAAAAABY/IkwBAECAgIHAg8DAwAEAAAAAAAAAAAAAQE=", "WAIAAAAAAABY/IkwBAECAgIHAg8DBAAEAAAAAAAAAAAAAQE=",
            "sAQAAAAAAABY/IkwBAECAgIHAg8DBAAEAAEAAAAAAAAAAQE=", "CAcAAAAAAABY/IkwBAECAgIHAg8DBAAEAAMAAAAAAAAAAQE=",
            "YAkAAAAAAABY/IkwBAECAgIHAg8DBAAEAAQAAAAAAAAAAQE=", "uAsAAAAAAABY/IkwBAECAgIHAg8DBAAEAAUAAAAAAAAAAQE=",
        ])
        #expect(result.s2r2 == [
            "FQEAAAABAAAAgVj8iTAAAAAAAAAAFAIAAAAIBwAAHwAAAAAoAAAAAAAUAwAAAGAJAAAfAAAAADIAAAAAABQEAAAAuAsAAB8AAAAAPAAAAAAAFQUAAAABAAAAgVj8iTAAAAAAAAAAFAYAAAAIBwAAHwAAAAAoAAAAAAAUBwAAAGAJAAAfAAAAADIAAAAAABQIAAAAuAsAAB8AAAAAPAAAAAAA",
            "AA==",
        ])
    }

    @Test func averagesReadingsEveryIntervalAndRepeatsTheLastValues() throws {
        let clock = NIOLockedValueBox(t)
        let history = EveHistory(.energy, accessoryName: "Plug", interval: .seconds(3600), now: { Date(timeIntervalSince1970: TimeInterval(clock.withLockedValue { $0 })) })
        history.add(.init(unixTime: t, power: 10))
        history.add(.init(unixTime: t + 60, power: 20.555))
        #expect(history.state.withLockedValue { $0.usedMemory } == 0)
        clock.withLockedValue { $0 = t + 600 }
        history.tick()
        var state = history.state.withLockedValue { $0 }
        // The marker entry, then the average rounded to two decimals at the tick's time.
        #expect(state.usedMemory == 2)
        #expect(state.history[2] == EveHistory.Entry(unixTime: t + 600, power: 15.28))
        // No readings in the next interval: the last average is repeated.
        clock.withLockedValue { $0 = t + 1200 }
        history.tick()
        state = history.state.withLockedValue { $0 }
        #expect(state.history[3] == EveHistory.Entry(unixTime: t + 1200, power: 15.28))
    }

    @Test func switchStatesAreRecordedAtOnceAndRepeated() {
        let clock = NIOLockedValueBox(t)
        let history = EveHistory(.switch, accessoryName: "Lamp", interval: .seconds(3600), now: { Date(timeIntervalSince1970: TimeInterval(clock.withLockedValue { $0 })) })
        history.add(.init(unixTime: t, status: 1))
        #expect(history.state.withLockedValue { $0.history[2] } == EveHistory.Entry(unixTime: t, status: 1))
        clock.withLockedValue { $0 = t + 600 }
        history.tick()
        #expect(history.state.withLockedValue { $0.history[3] } == EveHistory.Entry(unixTime: t + 600, status: 1))
        #expect(history.initialTime == t)
    }

    @Test func customReadingsWithoutPowerTemperatureOrLightAreRecordedAtOnce() {
        let history = EveHistory(.custom([.temperature, .humidity]), accessoryName: "Sensor", interval: .seconds(3600))
        history.add(.init(unixTime: t, humidity: 50))
        history.add(.init(unixTime: t, temp: 20))
        let state = history.state.withLockedValue { $0 }
        #expect(state.usedMemory == 2)
        #expect(state.backLog == [EveHistory.Entry(unixTime: t, temp: 20)])
    }

    @Test func persistsInFakegatosFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plug_persist.json")
        let history = EveHistory(.energy, accessoryName: "Plug", averaging: false, storageURL: url)
        history.add(.init(unixTime: t, power: 12.3))
        history.extraPersistedData = "{\"totalPower\":1.5}"
        history.flush()
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["refTime"] as? Int == t - 978_307_200)
        #expect((json["history"] as? [Any])?.first as? String == "noValue")
        #if !os(Windows)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #endif

        let restored = EveHistory(.energy, accessoryName: "Plug", averaging: false, storageURL: url)
        #expect(restored.initialTime == t)
        #expect(restored.extraPersistedData == "{\"totalPower\":1.5}")
        #expect(restored.state.withLockedValue { $0.history[2] } == EveHistory.Entry(unixTime: t, power: 12.3))
    }

    @Test func aHistoryElementThatIsNotAnEntryIsSkipped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plug_persist.json")
        // A number, an object without a time and an array: each used to stop the decoder for ever.
        let json = #"{"firstEntry":0,"lastEntry":3,"usedMemory":3,"refTime":\#(t - 978_307_200),"history":["noValue",42,{"power":1},[1],{"time":\#(t),"power":7}]}"#
        try Data(json.utf8).write(to: url)
        let restored = EveHistory(.energy, accessoryName: "Plug", averaging: false, storageURL: url)
        let state = restored.state.withLockedValue { $0 }
        #expect(state.history.count == 1)
        #expect(state.history[4] == EveHistory.Entry(unixTime: t, power: 7))
    }

    @Test func nonFiniteReadingsAreLeftOutAndTheHistoryStillSaves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("weather_persist.json")
        let history = EveHistory(.weather, accessoryName: "Weather", averaging: false, storageURL: url)
        history.add(.init(unixTime: t, temp: .nan, humidity: 40, pressure: .infinity))
        history.flush()
        history.add(.init(unixTime: t + 600, temp: 21))
        history.flush()
        let restored = EveHistory(.weather, accessoryName: "Weather", averaging: false, storageURL: url)
        let state = restored.state.withLockedValue { $0 }
        #expect(state.history[2] == EveHistory.Entry(unixTime: t, humidity: 40))
        #expect(state.history[3] == EveHistory.Entry(unixTime: t + 600, temp: 21))
        // Averages that overflow are left out too.
        let averaged = EveHistory(.energy, accessoryName: "Plug", interval: .seconds(3600), now: { Date(timeIntervalSince1970: TimeInterval(1_792_656_600)) })
        averaged.add(.init(unixTime: t, power: .greatestFiniteMagnitude))
        averaged.add(.init(unixTime: t, power: .greatestFiniteMagnitude))
        averaged.tick()
        #expect(averaged.state.withLockedValue { $0.history[2] } == nil)
    }

    @Test func aReadingAddedWhileTheTimerAveragesIsKept() {
        let clock = NIOLockedValueBox(t)
        let history = EveHistory(.energy, accessoryName: "Plug", interval: .seconds(3600), now: { Date(timeIntervalSince1970: TimeInterval(clock.withLockedValue { $0 })) })
        history.add(.init(unixTime: t, power: 10))
        // The reading arrives while the tick records its average (between averaging and clearing the backlog).
        let added = NIOLockedValueBox(false)
        history.service.characteristic(EveCharacteristic.historyStatus).observe { [t] _ in
            // A named argument: Swift 6.2 (CI) does not let `$0` reach into a `defer` block.
            guard !added.withLockedValue({ seen in
                defer { seen = true }
                return seen
            }) else { return }
            history.add(.init(unixTime: t + 300, power: 30))
        }
        clock.withLockedValue { $0 = t + 600 }
        history.tick()
        #expect(history.state.withLockedValue { $0.backLog } == [EveHistory.Entry(unixTime: t + 300, power: 30)])
        clock.withLockedValue { $0 = t + 1200 }
        history.tick()
        #expect(history.state.withLockedValue { $0.history[3] } == EveHistory.Entry(unixTime: t + 1200, power: 30))
    }

    @Test func eveCharacteristicTypes() {
        #expect(EveCharacteristic.currentConsumption.uuid.uuidString == "E863F10D-079E-48FF-8F27-9C2605A29F52")
        #expect(EveCharacteristic.totalConsumption.format == .float)
        #expect(EveCharacteristic.resetTotal.permissions.contains(.pairedWrite))
        let outlet = Service(.outlet, extra: [Characteristic(EveCharacteristic.currentConsumption, value: 42), Characteristic(EveCharacteristic.voltage, value: 230.5)])
        #expect(outlet[EveCharacteristic.currentConsumption]?.value == .int(42))
        #expect(EveHistory.fields(of: [outlet]) == [.status, .power])
    }
}
