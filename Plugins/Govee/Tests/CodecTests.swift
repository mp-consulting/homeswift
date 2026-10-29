import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftGovee

/// A 20-byte status frame from its leading hex, zero padded (the checksum is not checked on receipt).
func frame(_ hex: String) -> String {
    Govee.hexToBase64(hex.padding(toLength: 40, withPad: "0", startingAt: 0))
}

func decoded(_ frame: String) -> [UInt8] { Govee.bytes(base64: frame) }

/// A real RGBIC scene payload ("Forest", scene 130) from the Govee scene library.
let forestParam = "AyYAAQAKAgH/GQG0CgoCyBQF//8AAP//////AP//lP8AFAGWAAAAACMAAg8FAgH/FAH7AAAB+goEBP8A"
    + "tP8AR///4/8AAAAAAAAAABoAAAABAgH/BQHIFBQC7hQBAP8AAAAAAAAAAA=="

@Suite struct FunctionTests {
    @Test func hexAndBase64RoundTrip() {
        #expect(Govee.base64ToHex(Govee.hexToBase64("aabbccddee")) == "aabbccddee")
        #expect(Govee.base64ToHex("AAEC") == "000102")
        #expect(Govee.hexToBase64("000102") == "AAEC")
    }

    @Test func temperatures() {
        #expect(Govee.cenToFar(0) == 32)
        #expect(Govee.cenToFar(100) == 212)
        #expect(Govee.cenToFar(-40) == -40)
        #expect(Govee.cenToFar(37) == 98.6)
        #expect(Govee.farToCen(32) == 0)
        #expect(Govee.farToCen(212) == 100)
        #expect(Govee.farToCen(-40) == -40)
        #expect(Govee.farToCen(98.6) == 37)
    }

    @Test func hexHelpers() {
        #expect(Govee.hexToDecimal("ff") == 255)
        #expect(Govee.hexToDecimal("0x1a") == 26)
        #expect(Govee.hexToTwoItems("aabbcc") == ["aa", "bb", "cc"])
        #expect(Govee.hexToTwoItems("aabbc") == ["aa", "bb", "c"])
        #expect(Govee.hexToTwoItems("") == [])
        #expect(Govee.item(["a", "b", "c"], 2) == "b")
        #expect(Govee.item(["a"], 4) == "")
    }

    @Test func nearestHalfRoundsLikeJavaScript() {
        #expect(Govee.nearestHalf(0.24) == 0)
        #expect(Govee.nearestHalf(0.25) == 0.5)
        #expect(Govee.nearestHalf(0.74) == 0.5)
        #expect(Govee.nearestHalf(0.75) == 1)
        #expect(Govee.nearestHalf(5) == 5)
        #expect(Govee.nearestHalf(-1.3) == -1.5)
        #expect(Govee.round(-2.5) == -2)
    }

    @Test func deviceIds() {
        #expect(Govee.parseDeviceId("aa:bb:cc") == "AA:BB:CC")
        #expect(Govee.parseDeviceId("AB-CD.EF") == "ABCDEF")
        #expect(Govee.parseDeviceId("AB:CD_EF") == "AB:CD_EF")
        #expect(Govee.parseDeviceId("0123456789abcdef") == "0123456789ABCDEF")
        #expect(Govee.colonDeviceId("ab12cd34ef56ab78") == "AB:12:CD:34:EF:56:AB:78")
        #expect(Govee.colonDeviceId("AB:12") == "AB:12")
    }

    @Test func speeds() {
        #expect(Govee.speedPercentToValue(100, maxSpeed: 3) == 3)
        #expect(Govee.speedPercentToValue(100, maxSpeed: 8) == 8)
        #expect(Govee.speedPercentToValue(1, maxSpeed: 8) == 1)
        #expect(Govee.speedPercentToValue(200, maxSpeed: 3) == 3)
        #expect(Govee.speedPercentToValue(50, maxSpeed: 3) == 1)
        #expect(Govee.speedPercentToValue(50, maxSpeed: 3, rounding: { $0.rounded(.up) }) == 2)
        #expect([25, 50, 75, 100].map { Govee.speedPercentToValue(Double($0), maxSpeed: 4) } == [1, 2, 3, 4])
        #expect(Govee.speedValueToPercent(3, maxSpeed: 3) == 100)
        #expect(Govee.speedValueToPercent(1, maxSpeed: 3) == 33)
        #expect(Govee.speedValueToPercent(1, maxSpeed: 8) == 13)
        for value in 1...4 { #expect(Govee.speedPercentToValue(Double(Govee.speedValueToPercent(value, maxSpeed: 4)), maxSpeed: 4) == value) }
    }

    @Test func framesArePaddedAndChecksummed() {
        let bytes = decoded(Govee.code([0x33, 0x01, 0x01]))
        #expect(bytes.count == 20)
        #expect(bytes[19] == bytes[0..<19].reduce(0, ^))
        #expect(Govee.codeBytes([0xAA]).dropFirst().dropLast().allSatisfy { $0 == 0 })
        #expect(Catalog.deviceStateCodes["on"] == Govee.code([0x33, 0x01, 0x01]))
        #expect(Catalog.lockCodes["off"] == Govee.code([0x33, 0x10, 0x00]))
    }

    @Test func statusToActionCode() {
        // The Homebridge plugin's own output for this status frame.
        #expect(Govee.statusToActionCode("aa1601" + String(repeating: "0", count: 34) + "12") == "331601000000000000000000000000000000000024")
    }

    @Test func nightLight() {
        #expect(Govee.nightLightCode(brightness: 80, hue: 200, saturation: 60) == "MxsBUGbM/wAAAAAAAAAAAAAAACw=")
        let off = decoded(Govee.nightLightOffCode())
        #expect(Array(off[0..<3]) == [0x33, 0x1B, 0x00])
    }

    @Test func processCommandsPrefersOpcodeAndSubcode() {
        var exact = 0
        var opcodeOnly: [[String]] = []
        var unknown = 0
        Govee.processCommands([frame("aa0501"), frame("aa0503"), frame("bb0501"), frame("aaffff")], [
            "0501": { _, _ in exact += 1 },
            "05": { parts, _ in opcodeOnly.append(Array(parts.prefix(3))) },
        ]) { _, _, _ in unknown += 1 }
        #expect(exact == 1)
        #expect(opcodeOnly == [["aa", "05", "03"]])
        #expect(unknown == 1)
    }

    @Test func debouncedGuardLetsTheLastThrough() async {
        // The first call's turn is claimed outright, so the order holds however a loaded runner schedules: no window
        // to start the second call in.
        let guardian = LatestCallGuard(delay: .milliseconds(50))
        let first = guardian.claim()
        let second = await guardian()
        #expect(second)
        #expect(!first())
    }
}

@Suite struct ColourTests {
    @Test func hueSaturationToRGB() {
        #expect(Colour.hs2rgb(0, 100) == RGB(255, 0, 0))
        #expect(Colour.hs2rgb(120, 100) == RGB(0, 255, 0))
        #expect(Colour.hs2rgb(240, 100) == RGB(0, 0, 255))
        #expect(Colour.hs2rgb(0, 0) == RGB(255, 204, 204))
        #expect(Colour.hs2rgb(60, 100) == RGB(255, 204, 0))
        #expect(Colour.hs2rgb(360, 100) == Colour.hs2rgb(0, 100))
        #expect(Colour.hs2rgb(180, 100) == RGB(0, 255, 255))
        #expect(Colour.hs2rgb(300, 100) == RGB(255, 0, 204))
        // The Homebridge plugin's own results.
        #expect(Colour.hs2rgb(200, 60) == RGB(102, 204, 255))
        #expect(Colour.hs2rgb(33.3, 77) == RGB(255, 134, 47))
    }

    @Test func rgbToHueSaturation() {
        #expect(Colour.rgb2hs(255, 0, 0) == (0, 100))
        #expect(Colour.rgb2hs(0, 255, 0) == (120, 100))
        #expect(Colour.rgb2hs(0, 0, 255) == (240, 100))
        #expect(Colour.rgb2hs(0, 0, 0) == (0, 0))
        #expect(Colour.rgb2hs(255, 255, 255) == (0, 0))
        #expect(Colour.rgb2hs(255, 255, 0) == (60, 100))
        #expect(Colour.rgb2hs(12, 200, 99) == (148, 94))
        #expect((0...360).contains(Colour.rgb2hs(255, 0, 128).hue))
    }

    @Test func kelvinAndMired() {
        #expect(Colour.k2rgb(2000) == RGB(255, 141, 11))
        #expect(Colour.k2rgb(6500) == RGB(255, 249, 253))
        #expect(Colour.k2rgb(7100) == RGB(243, 242, 255))
        #expect(Colour.k2rgb(1000) == Colour.k2rgb(2000))
        #expect(Colour.k2rgb(9000) == Colour.k2rgb(7100))
        #expect(Colour.k2rgb(2049) == Colour.k2rgb(2000))
        #expect(Colour.k2rgb(2050) == Colour.k2rgb(2100))
        #expect(Colour.k2rgb(4567) == RGB(255, 225, 188))
        #expect(Colour.m2hs(50) == Colour.m2hs(100))
        #expect(Colour.m2hs(600) == Colour.m2hs(500))
        #expect(Colour.m2hs(200.4) == Colour.m2hs(200))
        #expect(Colour.m2hs(200.6) == Colour.m2hs(201))
        #expect(Colour.m2hs(321.6) == (27, 34))
    }
}

@Suite struct SceneCodeTests {
    @Test func singleFrame() {
        let frame = SceneCodes.singleFrame(SceneCodes.protocolWrite, SceneCodes.commandMode, [Int(SceneCodes.subModeScene), 0xD4, 0x00])
        #expect(frame.count == 20)
        #expect(Array(frame[0..<5]) == [0x33, 0x05, 0x04, 0xD4, 0x00])
        #expect(frame[5..<19].allSatisfy { $0 == 0 })
        #expect(frame[19] == frame[0..<19].reduce(0, ^))
    }

    @Test func shortPayloadFitsTheOpeningFrame() {
        let frames = SceneCodes.multiPacketFrames(SceneCodes.protocolMulti, header: [0x02], payload: [1, 2, 3, 4, 5])
        #expect(frames.count == 2)
        #expect(Array(frames[0][0..<5]) == [0xA3, 0x00, 0x01, 0x02, 0x02])
        #expect(Array(frames[0][5..<10]) == [1, 2, 3, 4, 5])
        #expect(frames[1][0] == 0xA3 && frames[1][1] == 0xFF)
    }

    @Test func continuationFramesAreNumbered() {
        // Typed step by step: the compiler on CI gives up on these as single expressions.
        let length: Int = 14 + 17 + 17 + 5
        let payload: [UInt8] = (0..<length).map { (index: Int) -> UInt8 in UInt8(index & 0xFF) }
        let frames = SceneCodes.multiPacketFrames(SceneCodes.protocolMulti, header: [0x02], payload: payload)
        #expect(frames.count == 4)
        #expect(frames.map { $0[1] } == [0x00, 0x01, 0x02, 0xFF])
        let checksummed: Bool = frames.allSatisfy { (frame: [UInt8]) -> Bool in
            let sum: UInt8 = frame[0..<19].reduce(UInt8(0), ^)
            return frame.count == 20 && frame[0] == 0xA3 && frame[19] == sum
        }
        #expect(checksummed)
        for length in [5, 14, 31, 48, 103, 400] {
            let frames = SceneCodes.multiPacketFrames(SceneCodes.protocolMulti, header: [0x02], payload: [UInt8](repeating: 0xAB, count: length))
            #expect(Int(frames[0][3]) == frames.count)
        }
    }

    @Test func framesReassembleToThePayload() {
        let payload = (0..<103).map { UInt8(($0 * 7) & 0xFF) }
        let frames = SceneCodes.multiPacketFrames(SceneCodes.protocolMulti, header: [0x02], payload: payload)
        var rebuilt = Array(frames[0][5..<19])
        for frame in frames.dropFirst() { rebuilt += frame[2..<19] }
        #expect(Array(rebuilt.prefix(payload.count)) == payload)
        let exact = SceneCodes.multiPacketFrames(SceneCodes.protocolMulti, header: [0x02], payload: [UInt8](repeating: 0x5A, count: 31))
        #expect(exact.count == 2)
        #expect(exact[1][2..<19].allSatisfy { $0 == 0x5A })
    }

    @Test func sceneTypeDetection() {
        #expect(SceneCodes.detectSceneType(Govee.bytes(base64: forestParam)) == SceneCodes.SceneType.rgbic.rawValue)
        #expect(SceneCodes.detectSceneType([0x02, 0x01, 0x02, 0x03]) == SceneCodes.SceneType.rgb.rawValue)
    }

    @Test func forestIsEncodedAsTheHomebridgePluginDoes() {
        let frames = SceneCodes.encodeScene(scenceParam: forestParam, sceneCode: 212, sceneType: 2)
        #expect(frames == [
            "owABBwIDJgABAAoCAf8ZAbQKCtk=", "owECyBQF//8AAP//////AP//lBI=", "owL/ABQBlgAAAAAjAAIPBQIB/wo=", "owMUAfsAAAH6CgQE/wC0/wBH/7M=",
            "owT/4/8AAAAAAAAAABoAAAABAl0=", "owUB/wUByBQUAu4UAQD/AAAAAJI=", "o/8AAAAAAAAAAAAAAAAAAAAAAFw=", "MwUE1AAAAAAAAAAAAAAAAAAAAOY=",
        ])
        #expect(SceneCodes.encodeScene(scenceParam: forestParam, sceneCode: 212) == frames)
    }

    @Test func activationFrames() {
        #expect(Array(decoded(SceneCodes.encodeScene(scenceParam: "", sceneCode: 0x0134, sceneType: 0)[0])[2..<5]) == [0x04, 0x34, 0x01])
        #expect(SceneCodes.encodeScene(scenceParam: forestParam, sceneCode: 49, sceneType: 0).count == 1)
        #expect(SceneCodes.encodeScene(scenceParam: "", sceneCode: 49).count == 1)
    }

    @Test func graffitiDropsItsPrefix() {
        let payload = Data((0..<20).map { UInt8($0) }).base64EncodedString()
        let first = decoded(SceneCodes.encodeScene(scenceParam: payload, sceneCode: 1, sceneType: 3)[0])
        #expect(first[4] == 0x07)
        #expect(first[5] == 2)
    }

    @Test func diy() {
        #expect(Array(decoded(SceneCodes.encodeDIY(effect: "", code: 7)[0])[2..<5]) == [Int(SceneCodes.subModeDIY), 7, 0].map(UInt8.init))
        let effect = Data((1...20).map { UInt8($0) }).base64EncodedString()
        #expect(SceneCodes.encodeDIY(effect: effect, code: 300) == ["owABAgoBAgMEBQYHCAkKCwwNDqU=", "o/8PEBESExQAAAAAAAAAAAAAAEc=", "MwUKLAEAAAAAAAAAAAAAAAAAABE="])
    }

    @Test func musicMode() {
        let auto = decoded(SceneCodes.encodeMusicMode(.init(effect: .spectrum, sensitivity: 50, autoColour: true))[0])
        #expect(Array(auto[2..<6]) == [SceneCodes.subModeMusicModern, 4, 50, 0])
        #expect(auto[6..<19].allSatisfy { $0 == 0 })
        let manual = decoded(SceneCodes.encodeMusicMode(.init(effect: .spectrum, sensitivity: 80, autoColour: false, colour: RGB(0x11, 0x22, 0x33)))[0])
        #expect(Array(manual[2..<9]) == [SceneCodes.subModeMusicModern, 4, 80, 1, 0x11, 0x22, 0x33])
        let soft = decoded(SceneCodes.encodeMusicMode(.init(effect: .rhythm, sensitivity: 10, autoColour: true, soft: true))[0])
        let power = decoded(SceneCodes.encodeMusicMode(.init(effect: .rhythm, sensitivity: 10, autoColour: true, soft: false))[0])
        #expect(Array(soft[2..<7]) == [SceneCodes.subModeMusicModern, 3, 10, 1, 0])
        #expect(Array(power[2..<7]) == [SceneCodes.subModeMusicModern, 3, 10, 0, 0])
        let legacy = decoded(SceneCodes.encodeMusicMode(.init(effect: .energic, sensitivity: 30, autoColour: true, musicProtocol: .legacy))[0])
        #expect(Array(legacy[2..<6]) == [SceneCodes.subModeMusicLegacy, 0, 30, 0])
        let legacySoft = decoded(SceneCodes.encodeMusicMode(.init(effect: .rhythm, sensitivity: 10, autoColour: true, soft: true, musicProtocol: .legacy))[0])
        #expect(Array(legacySoft[2..<7]) == [SceneCodes.subModeMusicLegacy, 5, 10, 0, 0])
        #expect(decoded(SceneCodes.encodeMusicMode(.init(effect: .rolling, sensitivity: 400, autoColour: true))[0])[4] == 100)
        #expect(decoded(SceneCodes.encodeMusicMode(.init(effect: .rolling, sensitivity: -20, autoColour: true))[0])[4] == 0)
        #expect(SceneCodes.encodeMusicMode(.init(effect: .rhythm, sensitivity: 70, autoColour: false, colour: RGB(1, 2, 3), soft: true, musicProtocol: .legacy))
            == ["MwUMBUYAAQECAwAAAAAAAAAAAHg="])
    }

    @Test func codesInConfigJSON() {
        let frames = SceneCodes.encodeScene(scenceParam: forestParam, sceneCode: 212, sceneType: 2)
        #expect(SceneCodes.codeToFrames(SceneCodes.framesToCode(frames)) == frames)
        #expect(SceneCodes.codeToFrames(" AAA, BBB ,, ") == ["AAA", "BBB"])
        // JavaScript's trim(): a code pasted over several lines.
        #expect(SceneCodes.codeToFrames("AAA,\nBBB\r\n,\tCCC\n") == ["AAA", "BBB", "CCC"])
    }
}

@Suite struct SensorDecodingTests {
    @Test func h5074() throws {
        let reading = try SensorDecoding.decodeH5074("0188ec2909ae155a00")
        #expect(abs(reading.tempInC - 23.45) < 0.001)
        #expect(abs(reading.humidity - 55.5) < 0.001)
        #expect(reading.battery == 90)
        #expect(abs(try SensorDecoding.decodeH5074("0188ec0cfe401f3200").tempInC + 5) < 0.001)
    }

    @Test func h5075() throws {
        let reading = try SensorDecoding.decodeH5075("0088ec03d5a65a00")
        #expect(abs(reading.tempInC - 25.1302) < 0.001)
        #expect(abs(reading.humidity - 30.2) < 0.01)
        #expect(reading.battery == 90)
        let negative = try SensorDecoding.decodeH5075("0088ec80c5a84600")
        #expect(abs(negative.tempInC + 5.06) < 0.001)
        #expect(abs(negative.humidity - 60) < 0.01)
        #expect(negative.battery == 70)
    }

    @Test func h5101AndH5179() throws {
        let h5101 = try SensorDecoding.decodeH5101("0100000003d5a65a")
        #expect(abs(h5101.tempInC - 25.1302) < 0.001)
        #expect(h5101.battery == 90)
        let h5179 = try SensorDecoding.decodeH5179("0188000000000008ca195a")
        #expect(abs(h5179.tempInC - 22.5) < 0.001)
        #expect(abs(h5179.humidity - 66.02) < 0.001)
        #expect(h5179.battery == 90)
    }

    @Test func dispatchAndValidation() throws {
        #expect(abs(try SensorDecoding.decode("0188ec2909ae155a00").tempInC - 23.45) < 0.001)
        #expect(abs(try SensorDecoding.decode("0088ec03d5a65a00").tempInC - 25.1302) < 0.001)
        #expect(abs(try SensorDecoding.decode("0100000003d5a65a").tempInC - 25.1302) < 0.001)
        #expect(throws: SensorDecoding.DecodingError.unsupported("ffffffffffffffff")) { try SensorDecoding.decode("ffffffffffffffff") }
        #expect(SensorDecoding.isValid(manufacturerData: Govee.bytes(hex: "0188ec2909ae155a00")))
        #expect(!SensorDecoding.isValid(manufacturerData: nil))
        #expect(!SensorDecoding.isValid(manufacturerData: Govee.bytes(hex: "ffffffff")))
    }
}

@Suite struct DeviceUpdateTests {
    @Test func awsLightStatus() throws {
        let raw = try JSONValue(string: #"{"device":"AA:BB:CC:DD:EE:FF:00:11","sku":"H6008","cmd":"status","state":{"onOff":1,"brightness":64,"color":{"r":10,"g":20,"b":30},"colorTemInKelvin":0}}"#)
        let update = DeviceUpdate(raw: raw, source: .aws, model: "H6008")
        #expect(update.state == "on")
        #expect(update.brightness == 64)
        #expect(update.rgb == RGB(10, 20, 30))
        #expect(update.kelvin == nil)
        #expect(DeviceUpdate(raw: ["state": ["onOff": 0, "colorTemInKelvin": 4000]], source: .aws).kelvin == 4000)
    }

    @Test func lanStatusAtTheTopLevel() {
        let update = DeviceUpdate(raw: ["onOff": 1, "brightness": 100, "color": ["r": 255, "g": 255, "b": 255], "colorTemInKelvin": 7200], source: .lan)
        #expect(update.state == "on")
        #expect(update.brightness == 100)
        #expect(update.kelvin == 7200)
    }

    @Test func opcodesBitmasksAndOnOff() {
        #expect(DeviceUpdate(raw: ["state": ["onOff": 1], "op": ["command": ["qhIBAA==", "qgUBAQ=="]]], source: .aws).commands == ["qhIBAA==", "qgUBAQ=="])
        #expect(DeviceUpdate(raw: ["state": ["sta": ["stateCode": 119]]], source: .aws).stateDual == 119)
        #expect(DeviceUpdate(raw: ["state": ["onOff": 17]], source: .aws).state == "on")
        #expect(DeviceUpdate(raw: ["state": ["onOff": "garbage"]], source: .aws).state == "off")
    }

    @Test func brightnessScales() {
        #expect(DeviceUpdate(raw: ["brightness": 127], source: .aws, model: "H6008").brightness == 50)
        #expect(DeviceUpdate(raw: ["brightness": 127], source: .aws, model: "H6002").brightness == 50)
        #expect(DeviceUpdate(raw: ["brightness": 80], source: .aws, model: "h6002").brightness == 31)
        #expect(DeviceUpdate(raw: ["brightness": 80], source: .aws, model: "H6008").brightness == 80)
    }

    @Test func sensorsAndWrongTypes() {
        let update = DeviceUpdate(raw: ["battery": 140, "temperature": 2213, "humidity": 5170, "pm25": 12, "online": true, "leakDetected": false], source: .http)
        #expect(update.battery == 100)
        #expect(update.temperature == 2213 && update.humidity == 5170 && update.pm25 == 12)
        #expect(update.online == true && update.leakDetected == false)
        let junk = DeviceUpdate(raw: ["brightness": "50", "color": ["r": "x", "g": 0, "b": 0], "online": "yes", "op": ["command": [1, 2]]], source: .aws)
        #expect(!junk.hasValues)
    }

    /// Numbers no device sends, which trapped: they saturate (a colour channel to 0-255).
    @Test func hugeNumbersSaturate() {
        let update = DeviceUpdate(
            raw: ["brightness": 1e300, "colorTemInKelvin": 1e300, "color": ["r": 1e300, "g": -1e300, "b": 300], "stateDual": -1e300], source: .lan)
        #expect(update.brightness == 100)
        #expect(update.kelvin == Int.max)
        #expect(update.rgb == RGB(255, 0, 255))
        #expect(update.stateDual == Int.min)
        #expect(Govee.roundInt(1e300) == Int.max && Govee.roundInt(-.infinity) == Int.min && Govee.roundInt(.nan) == 0)
        #expect(Govee.speedPercentToValue(1e300, maxSpeed: 8) == 8)
        #expect(Colour.rgb2hs(Int.max, Int.min, 0) == Colour.rgb2hs(255, 0, 0))
        _ = Colour.hs2rgb(1e300, 100)
        #expect(Colour.hs2rgb(.nan, 100) == RGB(255, 0, 0))
    }

    @Test func hugeConfigNumbersSaturate() {
        #expect(GoveePlugin.Configuration.integer(.number(1e300)) == Int.max)
        #expect(GoveePlugin.Configuration.integer(.number(-1e300)) == Int.min)
        #expect(GoveePlugin.Configuration.integer(.number(.infinity)) == nil)
        // Intervals stop at about 68 years (seconds) or 24 days (milliseconds), so sleeps and products never overflow.
        let huge = GoveePlugin.Configuration(["httpRefreshTime": 1e300, "bleRefreshTime": 1e300, "bleControlInterval": 1e300])
        #expect(huge.httpRefreshTime == Int(Int32.max) && huge.bleRefreshTime == Int(Int32.max))
        #expect(huge.bleQueueInterval == .milliseconds(Int(Int32.max)))
        #expect(huge.belowMinimum.isEmpty)
    }
}

@Suite struct TransportCommandTests {
    @Test func stateAndBrightness() {
        let state = TransportCommands(.state(true), model: "H6008")
        #expect(state.aws == AWSParams(cmd: "turn", data: ["val": 1]))
        #expect(state.ble == .command(0x01, [1]))
        #expect(state.lan == LANParams(cmd: "turn", data: ["value": 1]))
        let brightness = TransportCommands(.brightness(57), model: "H6008")
        #expect(brightness.aws == AWSParams(cmd: "brightness", data: ["val": 145]))
        #expect(brightness.ble == .command(0x04, [145]))
        #expect(TransportCommands(.brightness(50), model: "H6052").ble == .command(0x04, [50]))
        #expect(TransportCommands(.brightness(50), model: "H6008").ble == .command(0x04, [127]))
        #expect(TransportCommands(.brightness(40), model: "H6008", options: .init(awsBrightnessNoScale: true)).aws == AWSParams(cmd: "brightness", data: ["val": 40]))
    }

    @Test func colours() {
        let rgb = RGB(1, 2, 3)
        #expect(TransportCommands(.color(rgb), model: "H6008").ble == .command(0x05, [0x02, 1, 2, 3]))
        #expect(TransportCommands(.color(rgb), model: "H6005").ble == .command(0x05, [0x0D, 1, 2, 3]))
        #expect(TransportCommands(.color(rgb), model: "H6199").ble == .command(0x05, [0x15, 0x01, 1, 2, 3, 0, 0, 0, 0, 0, 0xFF, 0x7F]))
        #expect(TransportCommands(.color(rgb), model: "H6008", options: .init(awsColourMode: "redgreenblue")).aws == AWSParams(cmd: "color", data: ["red": 1, "green": 2, "blue": 3]))
        #expect(TransportCommands(.color(rgb), model: "H6008", options: .init(awsColourMode: "rgb")).aws == AWSParams(cmd: "color", data: ["r": 1, "g": 2, "b": 3]))
        #expect(TransportCommands(.color(rgb), model: "H6008").aws == AWSParams(cmd: "colorwc", data: ["color": ["r": 1, "g": 2, "b": 3], "colorTemInKelvin": 0]))
        let temperature = TransportCommands(.colorTem(4321), model: "H6199")
        #expect(temperature.aws == AWSParams(cmd: "colorwc", data: ["color": ["r": 255, "g": 219, "b": 175], "colorTemInKelvin": 4321]))
        #expect(temperature.ble == .command(0x05, [2, 255, 255, 255, 1, 255, 219, 175]))
    }

    @Test func plugsAndFrames() {
        #expect(TransportCommands(.stateOutlet(true), model: "H5080").aws == AWSParams(cmd: "turn", data: ["val": 17]))
        #expect(TransportCommands(.stateOutlet(true), model: "H5001").aws == AWSParams(cmd: "turn", data: ["val": 1]))
        #expect(TransportCommands(.stateOutlet(true), model: "H5001").ble == nil)
        #expect(TransportCommands(.stateDual(34), model: "H5082").aws == AWSParams(cmd: "turn", data: ["val": 34]))
        #expect(TransportCommands(.ptReal("MwUBAA=="), model: "H7130").aws == AWSParams(cmd: "ptReal", data: ["command": ["MwUBAA=="]]))
        #expect(TransportCommands(.ptReal("MwUBAA=="), model: "H7130").ble == .ptReal(["MwUBAA=="]))
        let scene = TransportCommands(.rgbScene(code: "AAA,BBB", bleCode: ""), model: "H6008")
        #expect(scene.aws == AWSParams(cmd: "ptReal", data: ["command": ["AAA", "BBB"]]))
        #expect(scene.ble == .ptReal(["AAA", "BBB"]))
        #expect(TransportCommands(.rgbScene(code: "AAA", bleCode: "CCC"), model: "H6008").ble == .ptReal(["CCC"]))
        #expect(TransportCommands(.stateHeat(true), model: "H7131").aws == AWSParams(cmd: "multiSync", data: ["command": [.string(Catalog.deviceStateCodes["on"]!)]]))
    }

    /// With `lanScenes`, scenes, DIY effects and music mode also go over LAN as `ptReal`, with the cloud's frames
    /// (a scene's BLE frames are for BLE only); without it they have no LAN form, as before.
    @Test func scenesOverLAN() {
        let options = TransportCommands.Options(lanScenes: true)
        #expect(TransportCommands(.rgbScene(code: "AAA,BBB", bleCode: "CCC"), model: "H6008").lan == nil)
        #expect(TransportCommands(.rgbScene(code: "AAA,BBB", bleCode: "CCC"), model: "H6008", options: options).lan == LANParams(cmd: "ptReal", data: ["command": ["AAA", "BBB"]]))
        #expect(TransportCommands(.rgbScene(code: "", bleCode: "CCC"), model: "H6008", options: options).lan == nil)
        #expect(TransportCommands(.ptReal("MwUBAA=="), model: "H6008", options: options).lan == LANParams(cmd: "ptReal", data: ["command": ["MwUBAA=="]]))
        let music = SceneCodes.MusicMode(effect: .rhythm, sensitivity: 50, autoColour: true)
        let frames = SceneCodes.encodeMusicMode(music)
        #expect(TransportCommands(.musicMode(music), model: "H6008", options: options).lan == LANParams(cmd: "ptReal", data: ["command": .array(frames.map(JSONValue.string))]))
        #expect(TransportCommands(.musicMode(music), model: "H6008").lan == nil)
        // Colour and the rest keep their LAN form either way.
        #expect(TransportCommands(.state(true), model: "H6008", options: options).lan == LANParams(cmd: "turn", data: ["value": 1]))
    }

    @Test func bleFrames() {
        #expect(BLEParams.command(0x01, [1]).frames == [Govee.codeBytes([0x33, 0x01, 0x01])])
        #expect(BLEParams.ptReal(["MwEBAAAAAAAAAAAAAAAAAAAAADM="]).frames.first?.count == 20)
    }
}

@Suite struct CatalogAndModelTests {
    @Test func airQuality() {
        #expect([0, 12, 13, 35, 36, 75, 76, 115, 116, 500].map { Catalog.airQuality(pm25: Double($0)) } == [1, 1, 2, 2, 3, 3, 4, 4, 5, 5])
        #expect(Catalog.airQualityLabel(pm25: 5) == "excellent")
        #expect(Catalog.airQualityLabel(pm25: 200) == "poor")
    }

    @Test func modelListsAreConsistent() {
        let lists: [(String, [String])] = [
            ("rgb", GoveeConstants.Models.rgb), ("switchSingle", GoveeConstants.Models.switchSingle), ("sensorThermo", GoveeConstants.Models.sensorThermo),
            ("fan", GoveeConstants.Models.fan), ("purifier", GoveeConstants.Models.purifier), ("kettle", GoveeConstants.Models.kettle),
        ]
        for (name, models) in lists {
            #expect(!models.isEmpty, "\(name)")
            #expect(Set(models).count == models.count, "\(name) has duplicates")
        }
        for model in GoveeConstants.bleColourD.union(GoveeConstants.bleColour1501).union(GoveeConstants.apiBrightnessScale) {
            #expect(GoveeConstants.Models.rgb.contains(model))
        }
        #expect(GoveeConstants.awsOutlet1617.isSubset(of: Set(GoveeConstants.Models.switchSingle)))
    }

    @Test func configArrays() {
        #expect(DeviceConfigKey(model: "H6008") == .lightDevices)
        #expect(DeviceConfigKey(model: "h5080") == .switchDevices)
        #expect(DeviceConfigKey(model: "H5106") == .thermoDevices)
        #expect(DeviceConfigKey(model: "H7172") == .iceMakerDevices)
        #expect(DeviceConfigKey(model: "HZZZZ") == .lightDevices)
        #expect(DeviceConfigKey(model: nil) == .lightDevices)
    }

    @Test func categories() {
        #expect(DeviceCategory.forModel("h6001") == .light)
        #expect(DeviceCategory.forModel("H5082") == .switchDouble)
        #expect(DeviceCategory.forModel("H5160") == .switchTriple)
        #expect(DeviceCategory.forModel("H5054") == .sensorLeak)
        #expect(DeviceCategory.forModel("H5122") == .sensorButton)
        #expect(DeviceCategory.forModel("H5127") == .sensorPresence)
        #expect(DeviceCategory.forModel("H7131") == .heater)
        #expect(DeviceCategory.forModel("HZZZZ") == nil)
        let cases: [(String, JSONValue, DeviceCategory)] = [
            ("H6008", [:], .light), ("H6008", ["showAs": "switch"], .lightSwitch), ("H5080", [:], .switchSingle), ("H5080", ["showAs": "outlet"], .outletSingle),
            ("H5080", ["showAs": "valve"], .valve), ("H5080", ["showAs": "stick"], .tv), ("H5082", [:], .switchDouble), ("H5082", ["showAs": "outlet"], .outletDouble),
            ("H5075", ["showExtraSwitch": true], .sensorThermoSwitch), ("H7130", ["tempReporting": true], .heater1b),
        ]
        for (model, settings, expected) in cases {
            #expect(DeviceCategory.resolve(model: model, settings: DeviceSettings(raw: settings)) == expected, "\(model) \(settings)")
        }
    }

    @Test func multiChannelCodes() {
        #expect([1, 2, 3].map { MultiChannelDevice.encode(channel: $0, on: true) } == [17, 34, 68])
        #expect([1, 2, 3].map { MultiChannelDevice.encode(channel: $0, on: false) } == [16, 32, 64])
        #expect(MultiChannelDevice.decode(17, channels: 2) == ["on", nil])
        #expect(MultiChannelDevice.decode(32, channels: 2) == [nil, "off"])
        #expect(MultiChannelDevice.decode(51, channels: 2) == ["on", "on"])
        #expect(MultiChannelDevice.decode(48, channels: 2) == ["off", "off"])
        #expect(MultiChannelDevice.decode(119, channels: 3) == ["on", "on", "on"])
        #expect(MultiChannelDevice.decode(112, channels: 3) == ["off", "off", "off"])
        #expect(MultiChannelDevice.decode(0x75, channels: 3) == ["on", "off", "on"])
    }
}
