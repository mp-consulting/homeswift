import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftZigbee2MQTT

/// The pure rules of docs/clean-room/Zigbee2MQTT.md, against its section 15 vectors.
struct RulesTests {
    // MARK: 15.2 Colour

    @Test(arguments: [
        (0.0, 0.70061, 0.2993), (120, 0.17242, 0.7468), (240, 0.1355, 0.03988), (300, 0.38547, 0.15463), (60, 0.44416, 0.51657),
    ])
    func hueToXY(hue: Double, x: Double, y: Double) {
        let xy = ColorMath.hsToXY(hue: hue, saturation: 100)
        #expect(xy.x == x)
        #expect(xy.y == y)
    }

    @Test func xyToHue() {
        let hs = ColorMath.xyToHS(x: 0.44416, y: 0.51657)
        #expect(hs.hue == 60)
        #expect(hs.saturation == 100)
    }

    @Test func miredToXYAndHue() {
        let xy = ColorMath.miredToXY(343)
        #expect(xy.x == 0.4426)
        #expect(xy.y == 0.4062)
        let hs = ColorMath.miredToHS(343)
        #expect(hs.hue == 39)
        #expect(hs.saturation == 48)
    }

    @Test(arguments: [(153.0, 212.0, 5.0), (250, 43, 26), (370, 39, 54), (500, 35, 75)])
    func miredToHue(mired: Double, hue: Double, saturation: Double) {
        let hs = ColorMath.miredToHS(mired)
        #expect(hs.hue == hue)
        #expect(hs.saturation == saturation)
    }

    // MARK: 15.4 Buttons

    /// "identifier/ext label: single, double, long" for each mapping.
    static func describe(_ values: [String]) throws -> [String] {
        try ButtonMapping.mappings(for: values).map {
            "\($0.subtype ?? "") \($0.label ?? 0): \($0.single ?? "-") \($0.double ?? "-") \($0.long ?? "-")"
        }
    }

    @Test func buttonMappings() throws {
        #expect(try Self.describe(["single", "double", "hold"]) == [" 1: single double hold"])
        #expect(try Self.describe(["off", "single", "double", "hold"]) == [" 1: single double hold", "off 2: off - -"])
        #expect(try Self.describe(["1_single", "1_double", "1_hold", "2_single", "2_double", "2_hold"])
            == ["1 1: 1_single 1_double 1_hold", "2 2: 2_single 2_double 2_hold"])
        #expect(try Self.describe(["single", "double", "triple", "quadruple", "hold", "release"])
            == [" 1: single double hold", "#ext1 2: triple quadruple -"])
        let buttons = (1...4).flatMap { ["button_\($0)_click", "button_\($0)_hold", "button_\($0)_release"] }
        #expect(try Self.describe(buttons) == (1...4).map { "button_\($0) \($0): button_\($0)_click - button_\($0)_hold" })
        let opple = (1...6).flatMap { n in ["hold", "release", "single", "double", "triple"].map { "button_\(n)_\($0)" } }
        #expect(try Self.describe(opple) == (1...6).flatMap { n in
            ["button_\(n) \(n * 10): button_\(n)_single button_\(n)_double button_\(n)_hold", "button_\(n)#ext1 \(n * 10 + 1): button_\(n)_triple - -"]
        })
        let dimmer = [1, 2].flatMap { n in ["on", "off", "brightness_move_up", "brightness_move_down", "brightness_stop"].map { "\($0)_\(n)" } }
        #expect(try ButtonMapping.mappings(for: dimmer).map { "\($0.identifier ?? "") \($0.label ?? 0)" } == [
            "off_1 10", "on_1 11", "brightness_stop_1 12", "brightness_move_down_1 13", "brightness_move_up_1 14",
            "off_2 20", "on_2 21", "brightness_stop_2 22", "brightness_move_down_2 23", "brightness_move_up_2 24",
        ])
        #expect(try ButtonMapping.mappings(for: (1...6).map { "scene_\($0)" }).map(\.label) == [1, 2, 3, 4, 5, 6])
        #expect(try Self.describe(["close", "open", "stop"]) == ["close 1: close - -", "open 2: open - -", "stop 3: stop - -"])
        #expect(try Self.describe(["up", "up_hold", "up_release", "down_release", "down", "down_hold", "circle_click", "circle_release", "circle_hold"])
            == ["circle 1: circle_click - circle_hold", "down 2: down - down_hold", "up 3: up - up_hold"])
        #expect(try Self.describe(["on", "up", "down", "off", "on_double", "on_long", "off_double", "off_long"])
            == ["down 1: down - -", "off 2: off off_double off_long", "on 3: on on_double on_long", "up 4: up - -"])
        #expect(try ButtonMapping.mappings(for: ["home", "sleep", "away", "panic"]).map { "\($0.identifier ?? "") \($0.label ?? 0)" }
            == ["away 1", "home 2", "panic 3", "sleep 4"])
        let sides = ["single", "double", "hold"].flatMap { press in ["left", "right", "both"].map { "\(press)_\($0)" } }
        #expect(try Self.describe(sides) == ["both 1: single_both double_both hold_both", "left 2: single_left double_left hold_left", "right 3: single_right double_right hold_right"])
        #expect(try ButtonMapping.mappings(for: ["recall_scene_0", "recall_scene_1", "recall_scene_2", "toggle"]).map { "\($0.identifier ?? "") \($0.label ?? 0)" }
            == ["recall_scene_1 1", "recall_scene_2 2", "recall_scene_0 3", "toggle 4"])
        let hue = ["on", "up", "down", "off"].flatMap { ["\($0)-press", "\($0)-hold", "\($0)-hold-release"] }
        #expect(try Self.describe(hue) == ["down 1: down-press - down-hold", "off 2: off-press - off-hold", "on 3: on-press - on-hold", "up 4: up-press - up-hold"])
        #expect(try Self.describe(["button_5_hold", "button_5_release", "button_5_triple"]) == ["button_5 50: - - button_5_hold", "button_5#ext1 51: button_5_triple - -"])
    }

    @Test func buttonMappingFailures() {
        #expect(throws: ButtonMapping.Failure.self) { try ButtonMapping.mappings(for: ["button_*"]) }
        #expect(throws: ButtonMapping.Failure.self) { try ButtonMapping.mappings(for: ["single_a", "click_a"]) }
    }

    // MARK: 15.5 Names

    @Test func names() {
        for kept in ["Living Room Light", "Kitchen-Light", "Dr. Smith, Jr", "Bob\u{2019}s Light", "Гостиная", "客厅灯", "غرفة"] {
            #expect(Names.sanitize(kept) == kept)
        }
        #expect(Names.sanitize("Kitchen@Light!") == "Kitchen Light")
        for name in ["My Device-", "My Device.", "My  Device", "---My Device", "My Device   "] { #expect(Names.sanitize(name) == "My Device") }
        #expect(Names.sanitize("💡🔥") == nil)
    }

    // MARK: 15.6, 15.7 Online and availability

    @Test func bridgeState() {
        for online in [#"{"state":"online"}"#, "online", #"{"foo":"bar"}"#, #"{"state":123}"#, #"["online"]"#, "null"] {
            #expect(!OnlineState.bridgeIsOffline(Data(online.utf8)), "\(online)")
        }
        #expect(OnlineState.bridgeIsOffline(Data(#"{"state":"offline"}"#.utf8)))
        #expect(OnlineState.bridgeIsOffline(Data("offline".utf8)))
        #expect(OnlineState.deviceIsOnline(Data(#"{"state":"online"}"#.utf8)))
        #expect(!OnlineState.deviceIsOnline(Data(#"{"state":"offline"}"#.utf8)))
    }

    @Test func availabilityConfiguration() throws {
        for enabled in [#"{"availability":true}"#, #"{"availability":{"active":{"timeout":10}}}"#, #"{"availability":{"passive":{"timeout":1500}}}"#,
                        #"{"availability":{}}"#, #"{"advanced":{"availability_timeout":1}}"#] {
            #expect(AvailabilityConfiguration(config: try JSONValue(string: enabled)).global, "\(enabled)")
        }
        for disabled in ["{}", #"{"advanced":{"availability_timeout":0}}"#, #"{"availability":false}"#,
                         #"{"availability":true,"advanced":{"availability_passlist":["0x1"]}}"#] {
            #expect(!AvailabilityConfiguration(config: try JSONValue(string: disabled)).global, "\(disabled)")
        }
        let lists = AvailabilityConfiguration(config: try JSONValue(string: #"{"availability":true,"advanced":{"availability_blocklist":["Hall"]},"devices":{"0x2":{"friendly_name":"Desk","availability":false}}}"#))
        #expect(!lists.isEnabled(address: "0x1", name: "Hall"))
        #expect(!lists.isEnabled(address: "0x2", name: "Desk"))
        #expect(lists.isEnabled(address: "0x3", name: "Kitchen"))
    }

    // MARK: Configuration (2)

    @Test func invalidConfigurations() throws {
        let invalid = [
            "{}", #"{"mqtt":{"server":"mqtt://h"}}"#, #"{"mqtt":{"base_topic":"","server":"mqtt://h"}}"#,
            #"{"mqtt":{"base_topic":"z","server":"mqtt://h"},"exclude_grouped_devices":1}"#,
            #"{"mqtt":{"base_topic":"z","server":"mqtt://h"},"devices":{}}"#,
            #"{"mqtt":{"base_topic":"z","server":"mqtt://h"},"defaults":{"converters":{"Light":{}}}}"#,
            #"{"mqtt":{"base_topic":"z","server":"mqtt://h"},"devices":[{"id":"a","converters":{"occupancy":{"type":"Motion"}}}]}"#,
            #"{"mqtt":{"base_topic":"z","server":"mqtt://h"},"devices":[{"id":"a","converters":{"light":{"adaptive_lighting":{"min_delta":0}}}}]}"#,
        ]
        for block in invalid { #expect(throws: SettingsError.self, "\(block)") { try Settings(try JSONValue(string: block)) } }
        let valid = try Settings(try JSONValue(string: #"{"mqtt":{"base_topic":"z","server":"mqtt://h"},"devices":[5,{"exclude":true},{"id":"x"}]}"#))
        #expect(valid.skippedDevices.count == 2)
        #expect(valid.devices.count == 1)
    }

    @Test func optionsMerge() throws {
        let settings = try Settings(try JSONValue(string: #"""
            {"mqtt":{"base_topic":"z","server":"mqtt://h"},"experimental":[" availability "],
             "defaults":{"exclude":false,"excluded_keys":["lqi"],"converters":{"switch":{"type":"outlet"},"light":{"adaptive_lighting":false}}},
             "devices":[{"id":"0xABC","excluded_keys":["battery"],"converters":{"light":{"adaptive_lighting":{"transition":2,"min_delta":5}}}}]}
            """#))
        let options = settings.options(for: ["0xabc", "Desk"])
        #expect(options.matched)
        #expect(options.excludedKeys == ["battery"])
        #expect(options.outlet)
        #expect(options.light.adaptiveLighting)
        #expect(options.light.transition == 2)
        #expect(options.light.minDelta == 5)
        #expect(options.exclude == nil)
        #expect(options.experimental == ["AVAILABILITY"])
        let other = settings.options(for: ["0x1"])
        #expect(!other.matched)
        #expect(!other.light.adaptiveLighting)
        #expect(other.excludedKeys == ["lqi"])
    }

    // MARK: Exposes (7, 11)

    @Test func filtering() throws {
        let exposes = try JSONValue(string: #"""
            [{"type":"switch","endpoint":"l1","features":[{"type":"binary","name":"state","property":"state_l1","access":7,"value_on":"ON","value_off":"OFF"}]},
             {"type":"switch","endpoint":"l2","features":[{"type":"binary","name":"state","property":"state_l2","access":7,"value_on":"ON","value_off":"OFF"}]},
             {"type":"numeric","name":"linkquality","property":"linkquality","access":1},
             {"type":"enum","name":"action","property":"action","access":1,"values":["toggle","recall_scene_1","recall_scene_2","off"]}]
            """#).decode([Expose].self)
        var options = DeviceOptions()
        options.excludedKeys = ["linkquality"]
        options.excludedEndpoints = ["l2"]
        options.values = [.init(property: "action", include: ["toggle", "recall_scene_*"], exclude: ["*_2"])]
        let filtered = options.filter(exposes)
        #expect(filtered.map(\.endpoint) == ["l1", nil])
        #expect(filtered[0].features?.first?.endpoint == "l1")
        #expect(filtered[1].valueStrings == ["toggle", "recall_scene_1"])
        #expect(DeviceOptions.pattern("*", matches: "*"))
        #expect(!DeviceOptions.pattern("*", matches: "a"))
        #expect(!DeviceOptions.pattern("", matches: ""))
    }

    @Test func groupIntersection() throws {
        let first = try JSONValue(string: #"""
            [{"type":"light","features":[{"type":"binary","name":"state","property":"state","access":7,"value_on":"ON","value_off":"OFF"},
              {"type":"numeric","name":"brightness","property":"brightness","access":7,"value_min":0,"value_max":254},
              {"type":"numeric","name":"color_temp","property":"color_temp","access":7,"value_min":150,"value_max":500}]},
             {"type":"enum","name":"effect","property":"effect","access":2,"values":["blink","breathe","okay"]}]
            """#).decode([Expose].self)
        let second = try JSONValue(string: #"""
            [{"type":"light","endpoint":"l1","features":[{"type":"binary","name":"state","property":"state_l1","access":7,"value_on":"ON","value_off":"OFF"},
              {"type":"numeric","name":"brightness","property":"brightness_l1","access":7,"value_min":1,"value_max":254},
              {"type":"numeric","name":"color_temp","property":"color_temp_l1","access":7,"value_min":153,"value_max":454}]},
             {"type":"enum","name":"effect","property":"effect","access":2,"values":["breathe","blink"]}]
            """#).decode([Expose].self)
        let merged = Expose.intersection(first, second)
        #expect(merged.count == 2)
        let light = try #require(merged.first)
        #expect(light.endpoint == nil)
        #expect(light.features?.map(\.property) == ["state", "brightness", "color_temp"])
        #expect(light.feature("brightness")?.valueMin == 1)
        #expect(light.feature("color_temp")?.valueMin == 153)
        #expect(light.feature("color_temp")?.valueMax == 454)
        #expect(merged[1].valueStrings == ["blink", "breathe"])
    }

    @Test func versions() {
        #expect(Zigbee2MQTTPlugin.isOlder("1.16.2", than: [1, 17, 0]))
        #expect(!Zigbee2MQTTPlugin.isOlder("1.17.0-dev", than: [1, 17, 0]))
        #expect(!Zigbee2MQTTPlugin.isOlder("2.7.2", than: [1, 17, 0]))
    }

    @Test func maskedServer() {
        #expect(Zigbee2MQTTPlugin.masked("mqtt://user:secret@broker:1883") == "mqtt://user:***@broker:1883")
        #expect(Zigbee2MQTTPlugin.masked("mqtt://broker") == "mqtt://broker")
    }
}
