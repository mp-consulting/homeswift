import Crypto
import Foundation
import HomeswiftNetwork
import Testing

@testable import HomeswiftMagicHome

/// The spec's vectors (docs/clean-room/MagicHome.md, sections 7 and 10.8), byte for byte.
struct ProtocolTests {
    static let defaults = MagicHomeWhiteEffects()

    static func profile(_ model: UInt8, version: UInt8 = 1, mode: UInt8 = 0) -> MagicHomeProfile {
        MagicHomeProfile.make(model: model, version: version, modeByte: mode)!
    }

    static func light(_ hue: Double, _ saturation: Double, _ brightness: Double) -> MagicHomeLight {
        MagicHomeLight(isOn: true, hue: hue, saturation: saturation, brightness: brightness)
    }

    static func original(_ logic: MagicHomeLogic, _ hue: Double, _ saturation: Double, _ brightness: Double) -> [String] {
        MagicHomeLevels.original(logic, light: light(hue, saturation, brightness), effects: defaults).map(hex)
    }

    /// One frame of a family's rules, wrapped as the connection would with `counter`.
    static func family(_ profile: MagicHomeProfile, _ request: MagicHomeLevelRequest, counter: UInt8 = 0) -> [String] {
        var wrapper = MagicHomeWrapper(counter: counter)
        return MagicHomeLevels.family(profile: profile, request: request).map { frame in
            hex(frame.wrapVersion.map { wrapper.wrap(frame.bytes, version: $0) } ?? frame.bytes)
        }
    }

    // MARK: 7.1, 7.2

    @Test func fixedFrames() {
        #expect(hex(MagicHomeFrame.stateQuery) == "81 8A 8B 96")
        #expect(hex(MagicHomeFrame.power(true)) == "71 23 0F A3")
        #expect(hex(MagicHomeFrame.power(false)) == "71 24 0F A4")
    }

    @Test func theHomebridgePluginsLevelFrames() {
        // The probe frame of an RGB strip's first write (the 8-byte body), then the frame it keeps sending.
        #expect(hex(MagicHomeFrame.levels(red: 0, green: 0x7F, blue: 0, warm: 0, cool: 0, mask: 0xF0)) == "31 00 7F 00 00 00 F0 0F AF")
        #expect(Self.original(.rgbStrip, 120, 100, 50) == ["31 00 7F 00 00 F0 0F AF"])
        #expect(Self.original(.grbStrip, 120, 100, 50) == ["31 00 7F 00 00 F0 0F AF"])
        #expect(Self.original(.rgbwBulb, 120, 5, 80) == ["31 00 00 00 CC 0F 0F 1B"])
        #expect(Self.original(.rgbwBulb, 240, 60, 100) == ["31 66 66 FF 00 F0 0F FB"])
        #expect(Self.original(.rgbwStrip, 0, 30, 40) == ["31 FF 00 00 66 FF 0F A4"])
        #expect(Self.original(.rgbwwStrip, 0, 100, 100) == ["31 FF 00 00 00 00 FF 0F 3E"])
        #expect(Self.original(.rgbwwStrip, 31, 33, 60) == ["31 00 00 00 99 00 0F 0F E8"])
        #expect(Self.original(.rgbwwStrip, 208, 17, 60) == ["31 00 00 00 00 99 0F 0F E8"])
        #expect(Self.original(.rgbwwStrip, 200, 30, 50) == ["31 00 AA FF 1C 7F FF 0F 83"])
        #expect(Self.original(.rgbwwStrip, 200, 3, 50) == ["31 00 00 00 1C 7F FF 0F DA"])
        #expect(Self.original(.rgbwwBulb, 45, 5, 100) == ["31 00 00 00 FF 80 0F 0F CE"])
        #expect(Self.original(.cctStrip, 0, 0, 50) == ["31 00 00 00 40 00 FF 0F 7F", "35 B1 40 00 00 00 00 03 29"])
        #expect(Self.original(.cctStrip, 135, 0, 100) == ["31 00 00 00 7F 7F FF 0F 3D", "35 B1 7F 7F 00 00 00 03 E7"])
        // A dimmer whose last read was red-only.
        #expect(Self.original(.dimmerStrip, 0, 100, 75) == ["31 BF 00 00 00 F0 0F EF"])
        #expect(Self.original(.switch, 0, 100, 75).isEmpty)
    }

    @Test func thresholdsComeFromTheBlock() {
        let mixOff = MagicHomeWhiteEffects(simultaneous: false)
        // Without mixing, the 30 % red of an RGBW strip is the colour scaled.
        #expect(MagicHomeLevels.original(.rgbwStrip, light: Self.light(0, 30, 40), effects: mixOff).map(hex) == ["31 66 48 48 00 FF 0F 35"])
        let higher = MagicHomeWhiteEffects(colorWhiteThreshold: 70)
        #expect(MagicHomeLevels.original(.rgbwBulb, light: Self.light(240, 60, 100), effects: higher).map(hex) == ["31 00 00 00 FF 0F 0F 4E"])
    }

    // MARK: 7.3

    @Test func colourMaths() {
        let split = [0, 45, 90, 135, 180, 225, 270, 315, 360].map { MagicHomeColour.hueSplit(Double($0)) }
        #expect(split.map(\.warm) == [255, 255, 255, 128, 0, 128, 255, 255, 255])
        #expect(split.map(\.cold) == [0, 128, 255, 255, 255, 255, 255, 128, 0])
        func rgb(_ hue: Double, _ saturation: Double) -> [Double] {
            let colour = MagicHomeColour.fullColour(hue: hue, saturation: saturation)
            return [colour.red, colour.green, colour.blue]
        }
        #expect(rgb(0, 100) == [255, 0, 0])
        #expect(rgb(30, 100) == [255, 128, 0])
        #expect(rgb(100, 100) == [85, 255, 0])
        #expect(rgb(240, 50) == [128, 128, 255])
        #expect(rgb(255, 100) == [64, 0, 255])
        #expect(rgb(359, 100) == [255, 0, 4])
        #expect(rgb(360, 100) == [255, 0, 0])
        // 255 / 100 × 50 is 127.4999… in doubles: 127, as in JavaScript.
        #expect(MagicHomeColour.scaled(255, brightness: 50) == 127)
    }

    // MARK: 7.4

    static func reading(_ hex: String, _ mode: UInt8? = nil) -> MagicHomeReading {
        let state = MagicHomeState(standard: bytes(hex))!
        let profile = MagicHomeProfile.make(model: state.model, version: state.version, modeByte: mode ?? state.mode)!
        return MagicHomeReading.of(state, profile: profile, effects: defaults)
    }

    @Test func stateResponses() throws {
        let strip = try #require(MagicHomeState(standard: bytes("81 25 23 61 01 10 FF 80 00 00 05 00 F0 AF")))
        #expect(strip.model == 0x25 && strip.isOn && strip.red == 255 && strip.green == 128 && strip.blue == 0 && strip.version == 5)
        #expect(MagicHomeProfile.make(model: 0x25, version: 5, modeByte: 1)?.logic == .rgbwwStrip)
        #expect(abs(MagicHomeColour.hsv(red: 255, green: 128, blue: 0).hue - 30.1176) < 0.001)
        #expect(Self.reading("81 25 23 61 01 10 FF 80 00 00 05 00 F0 AF") == MagicHomeReading(on: true, brightness: 100, hue: 30, saturation: 100))

        let bulb = Self.reading("81 35 23 61 01 10 00 00 00 C0 08 40 0F 62")
        #expect(bulb.on && bulb.brightness == 100 && bulb.hue == 0 && bulb.saturation == 7)
        // The bulb has Color Temperature here: 64 cool of 256 is 3650 K.
        #expect(bulb.mireds == 274 && bulb.showsWhite)

        let off = Self.reading("81 44 24 61 01 10 00 00 FF 00 04 00 F0 4E")
        #expect(off == MagicHomeReading(on: false, brightness: nil, hue: 240, saturation: 100))
        let socket = Self.reading("81 97 23 61 41 10 00 00 00 00 01 00 00 EE")
        #expect(socket == MagicHomeReading(on: true))
        #expect(MagicHomeProfile.make(model: 0x97, version: 1, modeByte: 0)?.isSwitch == true)
        let dimmer = MagicHomeReading.of(MagicHomeState(model: 0x21, isOn: true, red: 0x80, version: 2), profile: Self.profile(0x21, version: 2), effects: Self.defaults)
        #expect(dimmer.brightness == 50)
        // A reply that is not a state: none.
        #expect(MagicHomeState(standard: bytes("81 25 23 61 01 10 FF 80 00 00 05 00 F0 AE")) == nil)
        #expect(MagicHomeState(standard: bytes("80 25 23 61 01 10 FF 80 00 00 05 00 F0 AE")) == nil)
    }

    // MARK: 7.5, 7.6

    @Test func discovery() throws {
        #expect(hex(Array(MagicHomeDiscovery.probe)) == "48 46 2D 41 31 31 41 53 53 49 53 54 48 52 45 41 44")
        #expect(MagicHomeDiscovery.port == 48899)
        let reply = try #require(MagicHomeDiscovery.announcement(Data("192.168.1.50,ACCF23A1B2C3,AK001-ZJ2145\r\n".utf8), from: "192.168.1.50"))
        #expect(reply == MagicHomeAnnouncement(address: "192.168.1.50", mac: "ACCF23A1B2C3", module: "AK001-ZJ2145"))
        // The socket's own probe heard back, too few or too many fields, no MAC.
        #expect(MagicHomeDiscovery.announcement(MagicHomeDiscovery.probe, from: "192.168.1.2") == nil)
        #expect(MagicHomeDiscovery.announcement(Data("192.168.1.50,ACCF23A1B2C3".utf8), from: "192.168.1.50") == nil)
        #expect(MagicHomeDiscovery.announcement(Data("a,ACCF23A1B2C3,b,c,d".utf8), from: "192.168.1.50") == nil)
        #expect(MagicHomeDiscovery.announcement(Data("192.168.1.50,hello,AK001".utf8), from: "192.168.1.50") == nil)
        // A lowercase MAC, and an address that is not one: the sender's.
        #expect(MagicHomeDiscovery.announcement(Data("x,accf23a1b2c3,AK001".utf8), from: "10.0.0.9") == MagicHomeAnnouncement(address: "10.0.0.9", mac: "ACCF23A1B2C3", module: "AK001"))

        let version = try #require(MagicHomeDiscovery.versionReply(Data("+ok=35_0A_20220103_ZG-BL\r".utf8)))
        #expect(version == MagicHomeVersionReply(model: 0x35, version: 10, date: "20220103", moduleInfo: "ZG-BL"))
        #expect(MagicHomeProfile.make(model: 0x35, version: 10, modeByte: 0)?.family == .twentyFiveByte)
        #expect(MagicHomeDiscovery.versionReply(Data("+ok=03\r".utf8)) == MagicHomeVersionReply(model: nil, version: 3))
        #expect(MagicHomeDiscovery.versionReply(Data("HF-A11ASSISTHREAD".utf8)) == nil)

        let networks = [IPv4NetworkFixture.lan, IPv4NetworkFixture.loopback]
        #expect(MagicHomeDiscovery.targets(networks: networks, extra: ["192.168.2.255", "192.168.1.255", "10.0.0.7", "not an address"]) == ["192.168.1.255", "192.168.2.255", "10.0.0.7"])
    }

    /// The accessory's identity is the Homebridge plugin's: its UUID was SHA-1 of the MAC as discovered.
    @Test func identitySeedMatchesTheHomebridgeUUID() {
        func uuid(_ seed: String) -> String {
            let hex = Insecure.SHA1.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
            let digits = Array(hex.prefix(32))
            return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(digits[$0]) }.joined(separator: "-")
        }
        #expect(uuid("ACCF23A1B2C3") == "90f6f8b9-3d5d-f625-9c68-0e82779f3f9f")
        #expect(uuid("6001940EDC1F") == "4cb4622f-7322-6e03-b334-f7a135a4ca57")
        #expect(MagicHomeAccessory.accessoryID("ACCF23A1B2C3") == "homebridge-magichome-dynamic-platform:ACCF23A1B2C3")
    }

    @Test func names() {
        #expect(Self.profile(0x35).defaultName(mac: "ACCF23A1B2C3", withMAC: true) == "Bulb A1B2C3")
        #expect(Self.profile(0x07).defaultName(mac: "ACCF23A1B2C3", withMAC: true) == "Strip A1B2C3")
        #expect(Self.profile(0x97).defaultName(mac: "ACCF23A1B2C3", withMAC: true) == "Switch A1B2C3")
        #expect(Self.profile(0x25).defaultName(mac: "ACCF23A1B2C3", withMAC: false) == "RGBWW Simultaneous")
        #expect(Self.profile(0x44).defaultName(mac: "ACCF23A1B2C3", withMAC: false) == "RGBW Non-Simultaneous")
        #expect(Self.profile(0x93).defaultName(mac: "ACCF23A1B2C3", withMAC: false) == "Power Socket")
        // The models the plugin drives as section 10 says: their own description.
        #expect(Self.profile(0x52).defaultName(mac: "ACCF23A1B2C3", withMAC: false) == "Bulb CCT")
        #expect(Self.profile(0xE1).defaultName(mac: "ACCF23A1B2C3", withMAC: false) == "Ceiling Light CCT")
    }

    // MARK: Section 1 and 10.2: what each model is

    @Test func profiles() {
        func shape(_ model: UInt8, version: UInt8 = 1, mode: UInt8 = 0) -> String {
            guard let profile = MagicHomeProfile.make(model: model, version: version, modeByte: mode) else { return "none" }
            if profile.isSwitch { return "switch" }
            return [profile.hasBrightness ? "B" : "", profile.hasColour ? "HS" : "", profile.hasTemperature ? "CT" : ""].joined()
        }
        #expect(shape(0x04) == "BHS")
        #expect(shape(0x06) == "BHS")
        #expect(shape(0x07, mode: 0x17) == "BHSCT")
        #expect(shape(0x09) == "BCT")
        #expect(shape(0x21) == "B")
        #expect(shape(0x25) == "BHSCT")
        #expect(shape(0x25, mode: 0x03) == "BHS")
        #expect(shape(0x33) == "BHS")
        #expect(shape(0x35) == "BHSCT")
        #expect(shape(0x35, version: 11) == "BHSCT")
        #expect(shape(0x41) == "B")
        #expect(shape(0x44) == "BHS")
        // A CCT bulb (section 10.7), not an RGBWW one.
        #expect(shape(0x52) == "BCT")
        #expect(shape(0x65) == "B")
        #expect(shape(0x93) == "switch")
        #expect(shape(0x97) == "switch")
        #expect(shape(0x0B) == "switch")
        #expect(shape(0xA1) == "BHS")
        #expect(shape(0xA3) == "BHS")
        #expect(shape(0x1C) == "BCT")
        #expect(shape(0x1E) == "BHSCT")
        #expect(shape(0x18) == "")
        // The original protocol and unknown bytes are not driven.
        #expect(shape(0x01) == "none")
        #expect(shape(0x03) == "none")
        #expect(shape(0x99) == "none")
        // Families by version: the highest minimum the version reaches.
        #expect(Self.profile(0x35, version: 9).family == .nineByteDimmableEffects)
        #expect(Self.profile(0x35, version: 7).family == .nineByteAutoOn)
        #expect(Self.profile(0x35, version: 3).family == .nineByte)
        #expect(Self.profile(0x06, version: 1).family == .eightByteAutoOn)
        #expect(Self.profile(0x06, version: 0).family == .eightByte)
        #expect(Self.profile(0x65).family == .eightByte)
        // The Homebridge plugin's power-on rule for its models, the family's for the others.
        #expect(Self.profile(0x25, version: 5).needsPowerOnFirst(module: "AK001-ZJ2145"))
        #expect(!Self.profile(0x25, version: 6).needsPowerOnFirst(module: "AK001-ZJ2145"))
        #expect(Self.profile(0x25, version: 8).needsPowerOnFirst(module: ""))
        #expect(Self.profile(0x44, version: 1).needsPowerOnFirst(module: "HF-LPB100-ZJ200"))
        #expect(!Self.profile(0x44, version: 1).needsPowerOnFirst(module: "AK001-ZJ2145"))
        #expect(Self.profile(0x52, version: 1).needsPowerOnFirst(module: ""))
        #expect(!Self.profile(0x0E, version: 7).needsPowerOnFirst(module: ""))
    }

    // MARK: 10.8: commands

    @Test func familyFrames() {
        let red = MagicHomeLevelRequest(colour: (255, 0, 0))
        #expect(Self.family(Self.profile(0x33), red) == ["31 FF 00 00 00 00 0F 3F"])
        #expect(Self.family(Self.profile(0x44), MagicHomeLevelRequest(colour: (0, 0, 255))) == ["31 00 00 FF 00 F0 0F 2F"])
        #expect(Self.family(Self.profile(0x44), MagicHomeLevelRequest(warm: 128)) == ["31 00 00 00 80 0F 0F CF"])
        #expect(Self.family(Self.profile(0x35), MagicHomeLevelRequest(colour: (255, 128, 0))) == ["31 FF 80 00 00 00 F0 0F AF"])
        #expect(Self.family(Self.profile(0x07, mode: 0x17), MagicHomeLevelRequest(colour: (255, 128, 0))) == ["31 FF 80 00 00 00 F0 0F AF"])
        let neutral = MagicHomeColour.whiteLevels(kelvin: 4600, brightness: 255)
        #expect(neutral.warm == 128 && neutral.cool == 128)
        #expect(Self.family(Self.profile(0x35), MagicHomeLevelRequest(warm: neutral.warm, cool: neutral.cool)) == ["31 00 00 00 80 80 0F 0F 4F"])
        #expect(Self.family(Self.profile(0x25), MagicHomeLevelRequest(colour: (255, 0, 0), warm: 64, cool: 32)) == ["31 FF 00 00 40 20 00 0F 9F"])

        let warmest = MagicHomeColour.whiteLevels(kelvin: 2700, brightness: 255)
        #expect(warmest.warm == 255 && warmest.cool == 0)
        #expect(Self.family(Self.profile(0x09), MagicHomeLevelRequest(warm: warmest.warm, cool: warmest.cool)) == ["35 B1 00 64 00 00 00 03 4D"])
        let half = MagicHomeColour.whiteLevels(kelvin: 5000, brightness: 128)
        #expect(half.warm == 50 && half.cool == 77)
        #expect(Self.family(Self.profile(0x09), MagicHomeLevelRequest(warm: half.warm, cool: half.cool)) == ["35 B1 3D 32 00 00 00 03 58"])
        #expect(Self.family(Self.profile(0x1C), MagicHomeLevelRequest(warm: half.warm, cool: half.cool)) == ["B0 B1 B2 B3 00 01 01 00 00 09 35 B1 3D 32 00 00 00 03 58 81"])

        #expect(Self.family(Self.profile(0x52), MagicHomeLevelRequest(warm: neutral.warm, cool: neutral.cool)) == ["31 80 80 00 00 00 0F 40"])
        #expect(Self.family(Self.profile(0x21, version: 2), MagicHomeLevelRequest(warm: 128)) == ["31 80 00 00 00 00 0F C0"])
        #expect(Self.family(Self.profile(0x41, version: 2), MagicHomeLevelRequest(warm: 128)) == ["31 80 00 00 00 F0 0F B0"])

        // The 25-byte family: two level frames on one connection, its counter 0 then 1.
        var wrapper = MagicHomeWrapper()
        let bulb = Self.profile(0x35, version: 10)
        let frames = (MagicHomeLevels.family(profile: bulb, request: MagicHomeLevelRequest(colour: (0, 255, 0)))
            + MagicHomeLevels.family(profile: bulb, request: MagicHomeLevelRequest(warm: neutral.warm, cool: neutral.cool)))
            .map { hex(wrapper.wrap($0.bytes, version: $0.wrapVersion!)) }
        #expect(frames == [
            "B0 B1 B2 B3 00 01 02 00 00 0E E0 01 00 A1 3C 64 64 00 00 00 00 14 00 00 71",
            "B0 B1 B2 B3 00 01 02 01 00 0E E0 01 00 B1 00 00 00 32 64 00 00 14 00 00 14",
        ])

        #expect(Self.family(Self.profile(0xA1), red) == ["31 FF 00 00 00 00 F0 0F 2F"])
        #expect(hex(MagicHomeFrame.addressableV1Effect(5, speed: 50)) == "61 00 68 32 0F 0A")
        #expect(Self.family(Self.profile(0xA2), red) == ["41 01 FF 00 00 00 00 00 60 FF 00 00 A0"])
        #expect(Self.family(Self.profile(0xA2), MagicHomeLevelRequest(warm: 128)) == ["47 80 C7"])
        // Colour and white: the white a second later.
        #expect(MagicHomeLevels.family(profile: Self.profile(0xA2), request: MagicHomeLevelRequest(colour: (255, 0, 0), warm: 128)).map(\.delay) == [.zero, .seconds(1)])
        #expect(hex(MagicHomeFrame.addressableEffect(12, speed: 50, brightness: 100)) == "42 0C 32 64 E4")
        #expect(Self.family(Self.profile(0xA3), red, counter: 1) == ["B0 B1 B2 B3 00 01 01 01 00 0D 41 01 FF 00 00 00 00 00 60 FF 00 00 A0 16"])
        #expect(hex(MagicHomeWrapper.wrap(MagicHomeFrame.power(true), version: 1, counter: 2)) == "B0 B1 B2 B3 00 01 01 02 00 04 71 23 0F A3 14")
        #expect(hex(MagicHomeWrapper.wrap(MagicHomeFrame.stateQuery, version: 1, counter: 12)) == "B0 B1 B2 B3 00 01 01 0C 00 04 81 8A 8B 96 04")
        #expect(Self.family(Self.profile(0x1A), red, counter: 5) == ["B0 B1 B2 B3 00 01 01 05 00 0D 3B A1 00 64 64 00 00 00 00 00 00 00 A4 22"])

        #expect(MagicHomeFrame.delay(speed: 50) == 16)
        #expect(MagicHomeFrame.speed(delay: 16) == 50)
        #expect(hex(MagicHomeFrame.effect(0x25, delay: MagicHomeFrame.delay(speed: 50))) == "61 25 10 0F A5")
        #expect(hex(MagicHomeFrame.dimmableEffect(0x25, delay: 16, brightness: 80)) == "38 25 10 50 BD")
        #expect(hex(MagicHomeFrame.setTime(year: 2026, month: 11, day: 4, hour: 13, minute: 5, second: 9, weekday: 3)) == "10 14 1A 0B 04 0D 05 09 03 00 0F 7A")
        #expect(hex(MagicHomeFrame.timeQuery) == "11 1A 1B 0F 55")
        #expect(hex(MagicHomeFrame.powerRestoreQuery) == "32 3A 3B 0F B6")
        #expect(hex(MagicHomeFrame.stripConfigurationQuery) == "63 12 21 0F A5")
        #expect(hex(MagicHomeFrame.addressableV1ConfigurationQuery) == "63 12 21 36")
        #expect(hex(MagicHomeWrapper.wrap(MagicHomeFrame.remoteConfigurationQuery, version: 1, counter: 0)) == "B0 B1 B2 B3 00 01 01 00 00 04 2B 2C 2D 84 D4")
    }

    @Test func theWrapperCounterSkips255() {
        var wrapper = MagicHomeWrapper(counter: 253)
        let counters = (0..<3).map { _ in wrapper.wrap([0x00])[7] }
        #expect(counters == [253, 254, 0])
    }

    // MARK: 10.8: replies

    @Test func familyStateReplies() throws {
        let cct = Self.reading("81 09 23 61 00 10 00 00 00 1E 05 50 0F A0")
        #expect(cct.mireds == 260 && cct.brightness == 80 && cct.showsWhite)
        #expect(MagicHomeColour.whiteLevels(temperaturePercent: 30, brightnessPercent: 80) == (143, 61))
        let bulb = Self.reading("81 52 23 61 02 10 C0 40 00 00 03 00 0F 7B")
        #expect(bulb.mireds == 274 && bulb.brightness == 100 && bulb.hue == nil)
        let multiMode = Self.reading("81 25 23 61 07 10 00 00 00 80 05 80 0F 55")
        #expect(MagicHomeProfile.make(model: 0x25, version: 5, modeByte: 7)?.mode == .rgbOrCCT)
        #expect(multiMode.mireds == 217 && multiMode.brightness == 100 && multiMode.showsWhite)
        #expect(Self.reading("81 21 23 61 00 10 80 00 00 00 02 00 00 B8").brightness == 50)

        var reader = MagicHomeReader()
        let wrapped = bytes("B0 B1 B2 B3 00 01 01 07 00 0E 81 A3 23 61 00 10 FF 00 00 00 01 00 F0 A8 2D")
        // Split anywhere, as TCP may.
        #expect(reader.add(Array(wrapped[..<7])).isEmpty)
        let messages = reader.add(Array(wrapped[7...]))
        guard case .state(let addressable)? = messages.first else { Issue.record("no state in \(messages)"); return }
        #expect(addressable.model == 0xA3 && addressable.isOn && addressable.red == 255 && reader.pending == 0)

        let extended = bytes("EA 81 01 00 35 0B 23 61 00 32 F0 5A 64 32 00 00 00 00 00 00")
        let colour = try #require(MagicHomeState(extended: extended))
        #expect(colour.model == 0x35 && colour.version == 11 && colour.isOn && (colour.red, colour.green, colour.blue) == (0, 127, 127))
        let wrappedExtended = MagicHomeWrapper.wrap(extended, version: 1, counter: 9)
        #expect(hex(Array(wrappedExtended.prefix(10))) == "B0 B1 B2 B3 00 01 01 09 00 14" && wrappedExtended.last == 0x27)
        #expect(reader.add(wrappedExtended) == [.state(colour)])
        let white = try #require(MagicHomeState(extended: bytes("EA 81 01 00 35 0B 23 61 01 32 0F 00 00 00 32 64 00 00 00 00")))
        #expect((white.warm, white.cool) == (128, 128) && (white.red, white.green, white.blue) == (0, 0, 0))
        let whiteReading = MagicHomeReading.of(white, profile: Self.profile(0x35, version: 11), effects: Self.defaults)
        #expect(whiteReading.mireds == 217 && whiteReading.brightness == 100)

        // Power replies (their checksum not checked), a state, garbage in between.
        #expect(reader.add(bytes("F0 71 23 84 0F 71 24 A4")) == [.power(true), .power(false)])
        #expect(reader.add(bytes("F0 71 23 00")) == [.power(true)])
        let state = bytes("81 44 24 61 01 10 00 00 FF 00 04 00 F0 4E")
        #expect(reader.add([0x55, 0x81, 0x00] + state).count == 1)
        #expect(reader.pending == 0)
    }

    @Test func whitesForHomeKit() {
        let percents = [140, 154, 200, 250, 370, 400].map { Int(MagicHomeColour.round(100 * MagicHomeColour.temperatureFraction(mireds: $0))) }
        #expect(percents == [100, 100, 61, 34, 0, 0])
        #expect(MagicHomeColour.mireds(fraction: 0.30) == 260)
        #expect(MagicHomeColour.mireds(fraction: 0.5) == 217)
        // 217 mireds is 4608 K: a hair cooler than the middle. A CCT bulb takes a percent; a brightness under 2 is sent as 2.
        let cct = Self.profile(0x09)
        #expect(MagicHomeLevels.whiteFrames(mireds: 200, brightness: 50, profile: cct).map { hex($0.bytes) } == ["35 B1 3D 32 00 00 00 03 58"])
        #expect(MagicHomeLevels.whiteFrames(mireds: 370, brightness: 1, profile: cct).map { hex($0.bytes) } == [hex(MagicHomeFrame.temperature(0, brightness: 2))])
        #expect(MagicHomeLevels.whiteFrames(mireds: 217, brightness: 100, profile: Self.profile(0x52)).map { hex($0.bytes) } == ["31 7F 80 00 00 00 0F 3F"])
        #expect(MagicHomeLevels.whiteFrames(mireds: 217, brightness: 100, profile: Self.profile(0x35, version: 8)).map { hex($0.bytes) } == ["31 00 00 00 7F 80 0F 0F 4E"])
        #expect(MagicHomeLevels.whiteFrames(mireds: 217, brightness: 100, profile: Self.profile(0x25, version: 5, mode: 7)).map { hex($0.bytes) } == ["31 00 00 00 7F 80 00 0F 3F"])
        #expect(MagicHomeLevels.whiteFrames(mireds: 217, brightness: 100, profile: Self.profile(0x35, version: 10)).map(\.wrapVersion) == [2])
    }
}

enum IPv4NetworkFixture {
    static let lan = IPv4Network(address: IPv4Network.parse("192.168.1.2")!, netmask: 0xFFFF_FF00)
    static let loopback = IPv4Network(address: IPv4Network.parse("127.0.0.1")!, netmask: 0xFF00_0000)
}

