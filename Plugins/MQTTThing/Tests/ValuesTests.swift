import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftMQTTThing

@Suite struct ValuesTests {
    @Test func parsesAsJavaScriptDoes() {
        #expect(JS.parseInt("57.9") == 57)
        #expect(JS.parseInt("40%") == 40)
        #expect(JS.parseInt("0x1A") == 26)
        #expect(JS.parseInt("  -12abc") == -12)
        #expect(JS.parseInt("abc") == nil)
        #expect(JS.parseFloat("21.5 C") == 21.5)
        #expect(JS.parseFloat("-3") == -3)
        #expect(JS.parseFloat("1e3x") == 1000)
        #expect(JS.parseFloat("x") == nil)
        #expect(JS.text(.number(20)) == "20")
        #expect(JS.text(.number(21.5)) == "21.5")
    }

    @Test func matchesLooselyAsTheBlocksExpect() {
        #expect(JS.matches(.string("true"), .bool(true)))
        #expect(JS.matches(.string("1"), .number(1)))
        #expect(!JS.matches(.string("ON"), .string("on")))
        #expect(JS.matches(.number(1), .string("1")))
        #expect(!JS.matches(.number(1), .string("on")))
        #expect(JS.matches(.bool(true), .string("1")))
        #expect(JS.matches(.bool(true), .number(1)))
        #expect(!JS.matches(.bool(true), .string("true")))
    }

    func booleans(_ values: [String: JSONValue]) -> Booleans { Booleans(Config(values)) }

    @Test func booleanEncodings() {
        let integer = booleans(["integerValue": .bool(true)])
        #expect(integer.encode(true) == .number(1) && integer.encode(false) == .number(0))
        #expect(integer.decode(.string("1")) == true && integer.decode(.string("0")) == false && integer.decode(.string("true")) == nil)
        #expect(integer.decode(.number(1)) == true && integer.decode(.bool(true)) == true)
        let named = booleans(["onValue": "ON", "offValue": "OFF"])
        #expect(named.decode(.string("ON")) == true && named.decode(.string("OFF")) == false && named.decode(.string("on")) == nil)
        let onOnly = booleans(["onValue": "ON"])
        #expect(onOnly.encode(false) == nil && onOnly.decode(.string("OFF")) == nil)
        let other = booleans(["onValue": "ON", "otherValueOff": .bool(true)])
        #expect(other.decode(.string("xyz")) == false)
        #expect(booleans([:]).decode(.bool(true)) == true)
    }

    @Test func jsonPathFindsTheFirstValue() throws {
        let json = try JSONValue(string: #"{"Time":"x","AM2301":{"Temperature":-3.5},"sensors":[{"value":7}]}"#)
        #expect(JSONPath.first(try #require(JSONPath.parse("$.AM2301.Temperature")), in: json) == .number(-3.5))
        #expect(JSONPath.first(try #require(JSONPath.parse("$.sensors[0].value")), in: json) == .number(7))
        #expect(JSONPath.first(try #require(JSONPath.parse("$['AM2301']['Temperature']")), in: json) == .number(-3.5))
        #expect(JSONPath.first(try #require(JSONPath.parse("$..value")), in: json) == .number(7))
        #expect(JSONPath.first(try #require(JSONPath.parse("$.AM2301.Humidity")), in: json) == nil)
        let spec = try #require(TopicSpec(.string("tele/garden/SENSOR$.AM2301.Temperature"), get: true))
        #expect(spec.topic == "tele/garden/SENSOR" && spec.path != nil)
        #expect(TopicSpec(.string("a$b"), get: false)?.topic == "a$b")
    }

    /// Section 10.8.
    @Test func hsvToRGB() {
        func rgb(_ h: Double, _ s: Double, _ v: Double) -> [Int] {
            let c = Colour.rgb(hue: h, saturation: s, value: v)
            return [c.r, c.g, c.b]
        }
        #expect(rgb(0, 100, 100) == [255, 0, 0])
        #expect(rgb(120, 100, 50) == [0, 128, 0])
        #expect(rgb(240, 50, 100) == [128, 128, 255])
        #expect(rgb(30, 60, 80) == [204, 143, 82])
        #expect(rgb(0, 50, 100) == [255, 128, 128])
        #expect(Colour.hex([204, 143, 82], prefix: "#") == "#cc8f52")
    }

    @Test func rgbToHSV() {
        func hsv(_ r: Int, _ g: Int, _ b: Int) -> [Int] {
            let (h, s, v) = Colour.hsv(Colour.RGB(r: r, g: g, b: b))
            return [h, s, v]
        }
        #expect(hsv(255, 0, 0) == [0, 100, 100])
        #expect(hsv(0, 0, 255) == [240, 100, 100])
        #expect(hsv(255, 165, 0) == [38, 100, 100])
        #expect(hsv(min(127 + 128, 255), 128, 128) == [0, 49, 100])
        #expect(Colour.components("#0000ff", count: 3, hexPrefix: "#") == [0, 0, 255])
        #expect(Colour.components("0000ff", count: 3, hexPrefix: "#") == nil)
        #expect(Colour.components("255,0,0", count: 4, hexPrefix: nil) == nil)
    }

    @Test func rgbwwVectors() {
        let thresholds = Colour.RGB(r: 15, g: 15, b: 15)
        func out(_ h: Double, _ s: Double, _ v: Double, noMix: Bool = false) -> [Int] {
            let c = Colour.rgbww(
                Colour.rgb(hue: h, saturation: s, value: v), warm: Colour.defaultWarmWhite, cold: Colour.defaultColdWhite, noWhiteMix: noMix, thresholds: thresholds)
            return [c.r, c.g, c.b, c.warm, c.cold]
        }
        #expect(out(0, 0, 100) == [0, 0, 0, 127, 127])
        #expect(out(240, 100, 100) == [0, 0, 255, 0, 0])
        #expect(out(30, 60, 100) == [0, 1, 0, 227, 26])
        #expect(out(30, 60, 100, noMix: true) == [0, 0, 0, 227, 26])
        func back(_ warm: Int, _ cold: Int) -> [Int] {
            let c = Colour.adding(warm: warm, cold: cold, to: Colour.RGB(r: 0, g: 0, b: 0), warmWhite: Colour.defaultWarmWhite, coldWhite: Colour.defaultColdWhite)
            let (h, s, v) = Colour.hsv(Colour.RGB(r: min(c.r, 255), g: min(c.g, 255), b: min(c.b, 255)))
            return [h, s, v]
        }
        #expect(back(127, 127) == [25, 31, 89])
        #expect(back(255, 0) == [30, 76, 100])
    }

    @Test func televisionDisplayOrder() {
        #expect(Thing.displayOrder(inputs: 2) == "AQEBAQEC")
        #expect(Thing.displayOrder(inputs: 3) == "AQEBAQECAQED")
    }

    @Test func orderedJSONKeepsTheOrderSet() {
        var message = OrderedJSON(.object(["v": .number(2)]))
        message.set(["light", "on"], to: .bool(true))
        message.set(["light", "colour"], to: .string("255,0,0"))
        #expect(message.text() == #"{"v":2,"light":{"on":true,"colour":"255,0,0"}}"#)
    }

    @Test func typesIgnoreWhatFollowsTheirDash() {
        #expect(Config(["type": "lightbulb-RGB"]).type == "lightbulb")
        #expect(Config(["type": "irrigationSystem"]).type == "irrigationSystem")
        #expect(MQTTThingPlugin.accessoryID(Config(["name": "Desk Lamp"])) == "mqttthing:Desk Lamp")
        #expect(MQTTThingPlugin.accessoryID(Config(["name": "Desk Lamp", "uuid_base": "lamp-1"])) == "mqttthing:lamp-1")
        #expect(MQTTThingPlugin.clientID("Désk", options: .object([:])).hasPrefix("mqttthing_Dsk_"))
    }
}
