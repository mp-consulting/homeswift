import Foundation
import Testing

@testable import HomeswiftAPsystemsECU

/// The test vectors of docs/clean-room/APsystemsECU.md, section 7 (invented ids).
enum Vectors {
    static let v1 = "4150533132303131343030303132313530303039393939303130310002c45100001fec00000bc4202605031234290007000731303031364543552d432d5a5f43312e322e3234443031334575726f70652f57617273617702aabbccdd0102aabbccdd02303000000000000000000000454e440a"
    static let v2 = "41505331323031313630303031323135303030393939393031303100008d8b0000000000000086202411231257450004000031303031354543552d432d5a5f43312e322e31313031364575726f70652f416d7374657264616d02aabbccdd0102aabbccdd02303000000000000000000000454e440a"
    static let v3 = "4150533131303039343030303132313630303039393939303230310000aa3d0000028e000011d0d0d0d0d0d0d0d00006000631303031324543555f525f312e332e36433030394574632f474d542d3802aabbccdd03000000000000454e440a"
    static let v4 = "415053313130303539303030323030303100022022062009510370300099900100303070300099900201303101f40085005800e8005600e8454e440a"
    static let v5 = "415053313130303530303030323030303100012026110412150040600099930101303101f3008d009800e5009300e5454e440a"
    static let v6 = "415053313130303735303030323030303100022022043009133980200099910101303301f4007c008e00f10065011c011f8020009991020030330000006400000000000000000000454e440a"
    static let v7 = "415053313130303536303030323030303100012023050813190090100099920101303201f4008b00cc019c00d2019f00d6019900cd454e440a"
    static let v8 = "415053313130303536303030323030303100012026110412150050100099940101303201f5008700b400e700b000e800b600e600b3454e440a"
    static let v9 = "4150533131303037313030303230303031000220260126190751703000999003003031000000000000000000000000703000999004003031000000000000000000000000454e440a"
    static let v10 = "4150533131303032393030303230303031000020260426152000454e440a"
    static let v11 = "415053313130303339303033303030703000999002cf70300099900100802000999101a8454e440a"

    static func bytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    /// A frame with its length field rewritten for `bytes` (which carry the `APS` header, the payload and `END\n`).
    static func reframed(_ bytes: [UInt8]) -> [UInt8] {
        var frame = bytes
        let length = Array(String(format: "%04d", frame.count - 1).utf8)
        frame.replaceSubrange(5..<9, with: length)
        return frame
    }
}

@Suite struct ECUProtocolTests {
    @Test func requestsAreTheSpecsBytes() {
        #expect(String(decoding: ECUProtocol.systemRequest, as: UTF8.self) == "APS1100160001END\n")
        #expect(String(decoding: ECUProtocol.request(.realTime, ecuID: "215000999901"), as: UTF8.self) == "APS1100280002215000999901END\n")
        #expect(String(decoding: ECUProtocol.request(.signal, ecuID: "215000999901"), as: UTF8.self) == "APS1100280030215000999901END\n")
        #expect(ECUProtocol.request(.realTime, ecuID: "215000999901").count == 29)
    }

    @Test func v1ECUCSystemDaytime() throws {
        let frame = Vectors.bytes(Vectors.v1)
        #expect(frame.count == 115)
        let system = try ECUProtocol.parseSystem(try ECUProtocol.validate(frame, expecting: .system))
        #expect(ECUProtocol.ascii(frame, 3, 2) == "12")
        #expect(system.ecuID == "215000999901")
        #expect(system.model == "01")
        #expect(system.lifetimeEnergy == 18132.9)
        #expect(system.currentPower == 8172)
        #expect(system.todayEnergy == 30.12)
        #expect(system.inverters == 7)
        #expect(system.invertersOnline == 7)
        #expect(system.firmware == "ECU-C-Z_C1.2.24D")
        #expect(system.timeZone == "Europe/Warsaw")
        #expect(ECUProtocol.ecuModel(system.ecuID) == "ECU-C")
        #expect(ECUProtocol.firmwareRevision(system.firmware) == "1.2.24")
        #expect(ECUProtocol.hasMeter(system.ecuID))
    }

    @Test func v2ECUCSystemEvening() throws {
        let system = try ECUProtocol.parseSystem(try ECUProtocol.validate(Vectors.bytes(Vectors.v2), expecting: .system))
        #expect(Vectors.bytes(Vectors.v2).count == 117)
        #expect(system.ecuID == "215000999901")
        #expect(system.lifetimeEnergy == 3623.5)
        #expect(system.currentPower == 0)
        #expect(system.todayEnergy == 1.34)
        #expect(system.inverters == 4)
        #expect(system.invertersOnline == 0)
        #expect(system.firmware == "ECU-C-Z_C1.2.11")
        #expect(system.timeZone == "Europe/Amsterdam")
    }

    @Test func v3ECURSystem() throws {
        let frame = Vectors.bytes(Vectors.v3)
        #expect(frame.count == 95)
        let system = try ECUProtocol.parseSystem(try ECUProtocol.validate(frame, expecting: .system))
        #expect(ECUProtocol.ascii(frame, 3, 2) == "11")
        #expect(system.ecuID == "216000999902")
        #expect(ECUProtocol.ecuModel(system.ecuID) == "ECU-R")
        #expect(!ECUProtocol.hasMeter(system.ecuID))
        #expect(system.lifetimeEnergy == 4358.1)
        #expect(system.currentPower == 654)
        #expect(system.todayEnergy == 45.6)
        #expect(system.inverters == 6)
        #expect(system.invertersOnline == 6)
        #expect(system.firmware == "ECU_R_1.3.6C")
        #expect(ECUProtocol.firmwareRevision(system.firmware) == "1.3.6")
        #expect(system.timeZone == "Etc/GMT-8")
    }

    @Test func v4DS3AndARegisteredOnlyInverter() throws {
        let frame = Vectors.bytes(Vectors.v4)
        #expect(frame.count == 60)
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(frame, expecting: .realTime))
        #expect(realTime.model == "01")
        #expect(realTime.time == "20220620095103")
        #expect(realTime.date == "20220620")
        #expect(realTime.inverters.count == 2)
        #expect(realTime.unknownType == nil && !realTime.truncated)
        let first = realTime.inverters[0]
        #expect(first.uid == "703000999001" && !first.online && first.isRegisteredOnly && first.powers.isEmpty)
        let second = realTime.inverters[1]
        #expect(second.uid == "703000999002" && second.online && second.type == "01")
        #expect(second.frequency == 50.0)
        #expect(second.temperature == 33)
        #expect(second.powers == [88, 86])
        #expect(second.voltages == [232, 232])
        #expect(second.power == 174)
        #expect(ECUProtocol.inverterModel(second.uid) == "DS3 series")
    }

    @Test func v5YC600() throws {
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(Vectors.bytes(Vectors.v5), expecting: .realTime))
        #expect(Vectors.bytes(Vectors.v5).count == 51)
        #expect(realTime.time == "20261104121500")
        let inverter = try #require(realTime.inverters.first)
        #expect(realTime.inverters.count == 1)
        #expect(inverter.uid == "406000999301" && inverter.online)
        #expect(inverter.frequency == 49.9)
        #expect(inverter.temperature == 41)
        #expect(inverter.powers == [152, 147])
        #expect(inverter.voltages == [229, 229])
        #expect(ECUProtocol.inverterModel(inverter.uid) == "YC600 series")
    }

    @Test func v6QS1OnlineAndOffline() throws {
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(Vectors.bytes(Vectors.v6), expecting: .realTime))
        #expect(Vectors.bytes(Vectors.v6).count == 76)
        #expect(realTime.time == "20220430091339")
        #expect(realTime.inverters.count == 2)
        let online = realTime.inverters[0]
        #expect(online.uid == "802000999101" && online.online && online.type == "03")
        #expect(online.frequency == 50.0)
        #expect(online.temperature == 24)
        #expect(online.powers == [142, 101, 284, 287])
        #expect(online.power == 814)
        #expect(online.voltages == [241])
        let offline = realTime.inverters[1]
        #expect(offline.uid == "802000999102" && !offline.online)
        #expect(offline.frequency == 0)
        #expect(offline.temperature == 0)
        #expect(offline.powers == [0, 0, 0, 0])
        #expect(offline.voltages == [0])
        #expect(ECUProtocol.inverterModel(offline.uid) == "QS1 series")
    }

    @Test func v7QT2ThreePhase() throws {
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(Vectors.bytes(Vectors.v7), expecting: .realTime))
        #expect(Vectors.bytes(Vectors.v7).count == 57)
        let inverter = try #require(realTime.inverters.first)
        #expect(inverter.uid == "901000999201" && inverter.online && inverter.type == "02")
        #expect(inverter.frequency == 50.0)
        #expect(inverter.temperature == 39)
        #expect(inverter.powers == [204, 210, 214, 205])
        #expect(inverter.power == 833)
        #expect(inverter.voltages == [412, 415, 409])
        #expect(ECUProtocol.inverterModel(inverter.uid) == "QT2 series")
    }

    @Test func v8YC1000() throws {
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(Vectors.bytes(Vectors.v8), expecting: .realTime))
        let inverter = try #require(realTime.inverters.first)
        #expect(inverter.uid == "501000999401")
        #expect(inverter.frequency == 50.1)
        #expect(inverter.temperature == 35)
        #expect(inverter.powers == [180, 176, 182, 179])
        #expect(inverter.voltages == [231, 232, 230])
        #expect(ECUProtocol.inverterModel(inverter.uid) == "YC1000 series")
    }

    @Test func v9NightRecordsReadMinus100() throws {
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(Vectors.bytes(Vectors.v9), expecting: .realTime))
        #expect(Vectors.bytes(Vectors.v9).count == 72)
        #expect(realTime.time == "20260126190751")
        #expect(realTime.inverters.count == 2)
        for inverter in realTime.inverters {
            #expect(!inverter.online)
            #expect(inverter.temperature == -100)
            #expect(inverter.frequency == 0)
            #expect(inverter.power == 0)
        }
    }

    @Test func v10NoRecords() throws {
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(Vectors.bytes(Vectors.v10), expecting: .realTime))
        #expect(Vectors.bytes(Vectors.v10).count == 30)
        #expect(realTime.inverters.isEmpty)
        #expect(realTime.time == "20260426152000")
    }

    @Test func v11SignalLevels() throws {
        let frame = Vectors.bytes(Vectors.v11)
        #expect(frame.count == 40)
        let levels = try ECUProtocol.parseSignal(try ECUProtocol.validate(frame, expecting: .signal))
        #expect(levels == ["703000999002": 207, "703000999001": 0, "802000999101": 168])
        #expect(ECUProtocol.signalPercent(207) == 81)
        #expect(ECUProtocol.signalPercent(168) == 65)
        #expect(ECUProtocol.signalPercent(0) == 0)
    }

    // MARK: The negative cases

    @Test func aMissingLineFeedFailsTheLengthCheck() {
        let frame = Array(Vectors.bytes(Vectors.v1).dropLast())
        #expect(frame.count == 114)
        #expect(throws: ECUFrameError.lengthMismatch(announced: 114, received: 114)) { try ECUProtocol.validate(frame, expecting: .system) }
    }

    @Test func aSplitReadFailsTheLengthCheck() {
        let frame = Array(Vectors.bytes(Vectors.v4).prefix(40))
        #expect(throws: ECUFrameError.lengthMismatch(announced: 59, received: 40)) { try ECUProtocol.validate(frame, expecting: .realTime) }
    }

    @Test func aBadStartSignatureFails() {
        var frame = Vectors.bytes(Vectors.v4)
        frame.replaceSubrange(0..<3, with: [0x41, 0x50, 0x5A])
        #expect(throws: ECUFrameError.badSignature) { try ECUProtocol.validate(frame, expecting: .realTime) }
    }

    @Test func theWrongCommandFails() {
        #expect(throws: ECUFrameError.wrongCommand(expected: "0001", received: "0002")) {
            try ECUProtocol.validate(Vectors.bytes(Vectors.v4), expecting: .system)
        }
    }

    @Test func aBadEndFails() {
        var frame = Vectors.bytes(Vectors.v10)
        frame[frame.count - 2] = 0x58
        #expect(throws: ECUFrameError.badEnd) { try ECUProtocol.validate(frame, expecting: .realTime) }
    }

    @Test func shortAndGarbageFramesFail() {
        #expect(throws: ECUFrameError.short(received: 0)) { try ECUProtocol.validate([], expecting: .system) }
        #expect(throws: ECUFrameError.short(received: 4)) { try ECUProtocol.validate(Array("END\n".utf8), expecting: .system) }
        let garbage = Array("APS11abcd0001xxxxEND\n".utf8)
        #expect(throws: ECUFrameError.lengthMismatch(announced: nil, received: garbage.count)) { try ECUProtocol.validate(garbage, expecting: .system) }
    }

    @Test func anUnknownTypeKeepsTheRecordsBeforeIt() throws {
        // V6's second record retyped "07": the first record kept, parsing stopped there.
        var frame = Vectors.bytes(Vectors.v6)
        let second = 26 + 23
        frame[second + 7] = 0x30
        frame[second + 8] = 0x37
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(frame, expecting: .realTime))
        #expect(realTime.inverters.map(\.uid) == ["802000999101"])
        #expect(realTime.unknownType == "07")
    }

    @Test func aCountPastTheFrameStopsAtItsEnd() throws {
        // V5's count raised to 3: one record read, the rest missing.
        var frame = Vectors.bytes(Vectors.v5)
        frame[18] = 3
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(frame, expecting: .realTime))
        #expect(realTime.inverters.count == 1)
        #expect(realTime.truncated)
        // A count of 65535 on an empty frame reads nothing and does not trap.
        var empty = Vectors.bytes(Vectors.v10)
        empty[17] = 0xFF
        empty[18] = 0xFF
        let none = try ECUProtocol.parseRealTime(try ECUProtocol.validate(empty, expecting: .realTime))
        #expect(none.inverters.isEmpty && none.truncated)
    }

    @Test func aType05RecordIsReadWithFourChannels() throws {
        var frame = Vectors.bytes(Vectors.v7)
        frame[26 + 8] = 0x35
        let realTime = try ECUProtocol.parseRealTime(try ECUProtocol.validate(frame, expecting: .realTime))
        #expect(realTime.inverters.first?.powers == [204, 210, 214, 205])
    }

    @Test func aStatusOtherThan00Fails() {
        var frame = Vectors.bytes(Vectors.v10)
        frame[14] = 0x31
        #expect(throws: ECUFrameError.status("01")) { try ECUProtocol.parseRealTime(try ECUProtocol.validate(frame, expecting: .realTime)) }
    }

    @Test func aTruncatedSystemAnswerIsMalformed() throws {
        // V3 cut after its counts, its length rewritten: the firmware length runs past END.
        let bytes = Vectors.bytes(Vectors.v3)
        let cut = Vectors.reframed(Array(bytes.prefix(53)) + Array("END\n".utf8))
        let frame = try ECUProtocol.validate(cut, expecting: .system)
        #expect(throws: ECUFrameError.malformed("firmware length")) { try ECUProtocol.parseSystem(frame) }
        // An ECU id that is not digits.
        var letters = bytes
        letters[13] = 0x41
        #expect(throws: ECUFrameError.malformed("ECU id")) { try ECUProtocol.parseSystem(try ECUProtocol.validate(letters, expecting: .system)) }
    }

    @Test func systemLayout02() throws {
        // Layout "02": counts at 39 and 41, firmware length at 49 (no frame of it was seen: built from the layout).
        var payload = Array("215000999901".utf8) + Array("02".utf8)
        payload += [0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x01, 0xF4, 0x00, 0x00, 0x00, 0xC8]
        payload += [0x00, 0x03, 0x00, 0x02] + [UInt8](repeating: 0, count: 6) + Array("005".utf8) + Array("1.2.3".utf8)
        let frame = Vectors.reframed(Array("APS1100000001".utf8) + payload + Array("END\n".utf8))
        let system = try ECUProtocol.parseSystem(try ECUProtocol.validate(frame, expecting: .system))
        #expect(system.lifetimeEnergy == 10)
        #expect(system.currentPower == 500)
        #expect(system.todayEnergy == 2)
        #expect(system.inverters == 3 && system.invertersOnline == 2)
        #expect(system.firmware == "1.2.3")
        #expect(system.timeZone == nil)
    }

    // MARK: The reader

    @Test func theReaderWaitsForTheLengthTheHeaderAnnounces() throws {
        let frame = Vectors.bytes(Vectors.v4)
        var reader = ECUFrameReader()
        #expect(try reader.append(Array(frame.prefix(5))) == nil)
        #expect(try reader.append(Array(frame[5..<40])) == nil)
        // The rest, and a stray byte after it.
        #expect(try reader.append(Array(frame[40...]) + [0x00]) == frame)
    }

    @Test func theReaderDoesNotStopAtAnEndInsideBinaryFields() throws {
        // A frame whose payload holds "END\n": the length decides.
        let frame = Vectors.reframed(Array("APS11000000020001".utf8) + [0x00, 0x00] + Array("END\n".utf8) + [0x00] + Array("END\n".utf8))
        var reader = ECUFrameReader()
        let cut = 19 + 4
        #expect(try reader.append(Array(frame.prefix(cut))) == nil)
        #expect(try reader.append(Array(frame[cut...])) == frame)
    }

    @Test func theReaderFallsBackOnATrailingEnd() throws {
        var reader = ECUFrameReader()
        let garbage = Array("APS11abcd0001xxxxEND\n".utf8)
        #expect(try reader.append(garbage) == garbage)
    }

    @Test func theReaderRefusesTooMuch() {
        var reader = ECUFrameReader(limit: 100)
        #expect(throws: ECUFrameError.tooLarge(limit: 100)) { try reader.append(Array("APS1199990001".utf8)) }
        var unbounded = ECUFrameReader(limit: 100)
        #expect(throws: ECUFrameError.tooLarge(limit: 100)) { try unbounded.append([UInt8](repeating: 0x20, count: 101)) }
    }

    // MARK: The meter

    @Test func theMeterTakesEachArraysLastElement() throws {
        let json = #"{"power1":[{"powerA":1,"powerB":2,"powerC":3},{"powerA":1000,"powerB":"500.5","powerC":0}],"power2":[{"powerA":-200,"powerB":100,"powerC":50}]}"#
        let meter = try ECUMeter.parse(Data(json.utf8))
        #expect(meter.gridPhases == ["A": -200, "B": 100, "C": 50])
        #expect(meter.gridPower == -50)
        #expect(meter.homePower == 1450.5)
        #expect(meter.productionPhases == ["A": 1000, "B": 500.5, "C": 0])
        #expect(meter.homePhases == ["A": 800, "B": 600.5, "C": 50])
        // A phase left out keeps the others' names.
        let twoPhases = try ECUMeter.parse(Data(#"{"power1":[{"powerA":"x","powerB":10,"powerC":20}],"power2":[{"powerB":5}]}"#.utf8))
        #expect(twoPhases.productionPhases == ["B": 10, "C": 20])
        #expect(twoPhases.homePhases == ["B": 15])
        let empty = try ECUMeter.parse(Data(#"{"power1":[],"power2":[]}"#.utf8))
        #expect(empty.gridPower == nil && empty.homePower == nil)
        #expect(throws: (any Error).self) { try ECUMeter.parse(Data("<html>".utf8)) }
    }

    // MARK: The log

    @Test func theLogMasksTheECUIdAndTheMACs() {
        let frame = Vectors.bytes(Vectors.v1)
        let range = ECUProtocol.systemMACRange(frame)
        #expect(range == 87..<99)
        let hex = ECUProtocol.maskedHex(frame, ecuID: "215000999901", masked: range)
        #expect(!hex.contains(Vectors.v1.dropFirst(26).prefix(24)))
        #expect(hex.contains("323135303030787878787878"))
        #expect(!hex.contains("02aabbccdd01"))
        #expect(ECUProtocol.masked("215000999901") == "215000xxxxxx")
    }
}
