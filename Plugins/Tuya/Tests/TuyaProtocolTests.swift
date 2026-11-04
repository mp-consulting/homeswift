import Crypto
import Foundation
import HomeswiftAI
import Testing

@testable import HomeswiftTuya

/// The spec's test vectors (docs/clean-room/Tuya.md, §9) and the parts that need no host.
@Suite struct TuyaProtocolTests {
    let accessID = "4h3dxjpwamt9gcrkqv8e"
    let accessKey = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
    let t = "1700000000000"
    let nonce = "6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b"

    @Test func signsTheTokenGrant() {
        let text = TuyaSignature.stringToSign(method: "GET", path: "/v1.0/token", query: [("grant_type", "1")], body: nil, accessID: accessID)
        #expect(text == "GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nclient_id:4h3dxjpwamt9gcrkqv8e\n\n/v1.0/token?grant_type=1")
        let sign = TuyaSignature.sign(accessID: accessID, accessKey: accessKey, accessToken: "", t: t, nonce: nonce, stringToSign: text)
        #expect(sign == "BBCEDB8CC771DF36B9E16982F15ECBE008FFA31026C0A8041E0000ABF894BA57")
    }

    @Test func signsTheSmartHomeLogin() {
        #expect(TuyaSignature.loginPassword("Secr3t!pass") == ("e4dac8847254e28266642c1bfe2ea3d2", false))
        #expect(TuyaSignature.loginPassword("E4DAC8847254E28266642C1BFE2EA3D2").wasHashed)
        let body = OrderedJSON.object([
            ("country_code", .number(33)), ("username", .string("user@example.com")), ("password", .string("e4dac8847254e28266642c1bfe2ea3d2")),
            ("schema", .string("smartlife")),
        ])
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"country_code":33,"username":"user@example.com","password":"e4dac8847254e28266642c1bfe2ea3d2","schema":"smartlife"}"#)
        let text = TuyaSignature.stringToSign(method: "POST", path: "/v1.0/iot-01/associated-users/actions/authorized-login", query: [], body: body, accessID: accessID)
        #expect(text.contains("7f77ea3885dd00d20ebf40d005fc98d6c3998f5f29830d944c40aabb6d1e50f4"))
        #expect(TuyaSignature.sign(accessID: accessID, accessKey: accessKey, accessToken: "", t: t, nonce: nonce, stringToSign: text)
            == "51464A1C46F10EFD15B3845A45C533975E0730391490D70EF6FF780D37E3359F")
    }

    @Test func signsAQueryWithAToken() {
        let text = TuyaSignature.stringToSign(method: "GET", path: "/v1.0/devices", query: [("device_ids", "bf0123456789abcdefgh,bf9876543210zyxwvuts")], body: nil, accessID: accessID)
        #expect(text.hasSuffix("/v1.0/devices?device_ids=bf0123456789abcdefgh,bf9876543210zyxwvuts"))
        #expect(TuyaSignature.sign(accessID: accessID, accessKey: accessKey, accessToken: "c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4", t: t, nonce: nonce, stringToSign: text)
            == "D376AAB0F3BF8DDCBA697E337E3E35D5608E9F295A103F47EA6A536C07B4D592")
    }

    @Test func signsCommands() {
        let body = OrderedJSON.commands([TuyaCommand(code: "switch_led", value: .bool(true)), TuyaCommand(code: "bright_value_v2", value: .number(500))])
        #expect(String(decoding: body, as: UTF8.self) == #"{"commands":[{"code":"switch_led","value":true},{"code":"bright_value_v2","value":500}]}"#)
        #expect(TuyaSignature.hex(SHA256.hash(data: body)) == "1d7e4c0d0f92331a844393b7e3f87cd8794efa411efd49dc900666f0ff826dd5")
        let text = TuyaSignature.stringToSign(method: "POST", path: "/v1.0/devices/bf0123456789abcdefgh/commands", query: [], body: body, accessID: accessID)
        #expect(TuyaSignature.sign(accessID: accessID, accessKey: accessKey, accessToken: "c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4", t: t, nonce: nonce, stringToSign: text)
            == "67B12C4036EFA91F434C4E129DFBDB6D2EFB31C4BB3D7D5AE575FA8EAB3252C1")
        #expect(TuyaSignature.sha256Hex("homebridge") == "eb54078a2ac3e88954aa509df41065698b9f18606ae744920390556247074cda")
    }

    @Test func choosesTheDataCentre() {
        #expect(TuyaRegion.host(countryCode: 33) == "openapi.tuyaeu.com")
        #expect(TuyaRegion.host(countryCode: 230) == "openapi.tuyaeu.com")
        #expect(TuyaRegion.host(countryCode: 1) == "openapi.tuyaus.com")
        #expect(TuyaRegion.host(countryCode: 999) == "openapi.tuyaus.com")
        #expect(TuyaRegion.host(countryCode: 86) == "openapi.tuyacn.com")
        #expect(TuyaRegion.host(countryCode: 91) == "openapi.tuyain.com")
        #expect(TuyaSettings.host(of: "https://openapi.tuyaeu.com/some/path") == "openapi.tuyaeu.com")
    }

    static let ecbData = "8qixNmdvVT+TMqkJInoo3vQAgAFyqOItDMaFGNCvjmWtxTkXMPpekhOf6egmTwX2oQox0bCHEAywYuWN2lWUDJViw3Fwega4FzDCAOT5bT1ETZPpZzyBbTX7MMXBqI3SwYRTFbaZBM9UpqniXQcOcGKMn7JGu7U7ZD4Pk4SUpwIrkgs1A6rJcLmVUo7635GZhgM4/xXJitON6iajtwqWtbo9S3UQHulImCG0umcKaQg="
    static let gcmData = "AAAADDAxMjM0NTY3ODlhYs6FQVWU/rqyjQiKtsFMaOU4yLadR5iBnNVPg9uW/EkV12dT2zEOaN0ZSpeHyNGmlSYLNLSct0bJsgTau/MZs8mz7c8UVhcFlUeHmf5hnFmVBkgKuq8igppGkA3gUSqk0q/Xbq1Jt/GqPKQYu5IcstYepmYw5LiIUFtEJ1zXLAS4VZdmOgYR/2rBXtkuhNCm6RykzC4L/Rvtj0L7ZLGqazCbKN9GBSdq6nwejzhSjZVm"
    static let plaintext = #"{"dataId":"0005f1a2b3c4d5e6","devId":"bf0123456789abcdefgh","productKey":"keyabc123","status":[{"code":"switch_led","t":1700000000123,"value":false,"1":false}]}"#

    @Test func decryptsBothMessageVersions() throws {
        let key = try #require(TuyaMessageCrypto.key(fromPassword: "f3a9c1d2e4b5a6978877665544332211"))
        #expect(key.withUnsafeBytes { Data($0) } == Data("e4b5a69788776655".utf8))
        #expect(String(decoding: try TuyaMessageCrypto.decryptECB(Self.ecbData, key: key), as: UTF8.self) == Self.plaintext)
        #expect(String(decoding: try TuyaMessageCrypto.decryptGCM(Self.gcmData, key: key, t: 1_700_000_000), as: UTF8.self) == Self.plaintext)
        // The same time in milliseconds is tried too.
        #expect(String(decoding: try TuyaMessageCrypto.decryptGCM(Self.gcmData, key: key, t: 1_700_000_000_000), as: UTF8.self) == Self.plaintext)
        // Another time, or a changed byte, fails the tag.
        #expect(throws: (any Error).self) { try TuyaMessageCrypto.decryptGCM(Self.gcmData, key: key, t: 1_700_000_001) }
        var bytes = [UInt8](Data(base64Encoded: Self.gcmData)!)
        bytes[30] ^= 1
        #expect(throws: (any Error).self) { try TuyaMessageCrypto.decryptGCM(Data(bytes).base64EncodedString(), key: key, t: 1_700_000_000) }
    }

    @Test func readsPushMessages() throws {
        let message = try #require(try TuyaPushMessage.parse(Data(Self.plaintext.utf8), protocol: 4, t: 1_700_000_000))
        #expect(message == .status(deviceID: "bf0123456789abcdefgh", items: [.init(code: "switch_led", value: .bool(false), t: 1_700_000_000_123)], t: 1_700_000_000))
        let offline = try TuyaPushMessage.parse(Data(#"{"bizCode":"offline","bizData":{"time":1700000001},"devId":"bf0123456789abcdefgh"}"#.utf8), protocol: 20, t: 0)
        #expect(offline == .lifecycle(code: "offline", deviceID: "bf0123456789abcdefgh", data: ["time": 1_700_000_001]))
        #expect(try TuyaPushMessage.parse(Data("{}".utf8), protocol: 99, t: 0) == nil)
    }

    @Test func aLateMessageDoesNotRollBack() {
        var order = TuyaMessageOrder()
        let now: Int64 = 1_700_000_010_000
        let newer = order.order(deviceID: "d", items: [.init(code: "switch_led", value: .bool(true))], t: 1_700_000_005, now: now)
        #expect(!newer.late)
        let late = order.order(deviceID: "d", items: [.init(code: "switch_led", value: .bool(false)), .init(code: "other", value: 1)], t: 1_700_000_004, now: now)
        #expect(late.late)
        #expect(late.items.map(\.value) == [.bool(true), 1])
        // A kept message older than the late one does not correct it.
        _ = order.order(deviceID: "d", items: [.init(code: "y", value: 5)], t: 1_700_000_006, now: now)
        let between = order.order(deviceID: "d", items: [.init(code: "x", value: 2)], t: 1_700_000_005_500, now: now)
        #expect(between.late && between.items.map(\.value) == [2])
        // Thirty seconds on, the kept message is gone.
        let later = order.order(deviceID: "d", items: [.init(code: "switch_led", value: .bool(false))], t: 1_700_000_004, now: now + 40_000)
        #expect(later.items.map(\.value) == [.bool(false)])
    }

    // MARK: Expressions

    func run(_ source: String, value: TuyaExpression.Value, device: TuyaExpression.Value = .object([:])) throws -> TuyaExpression.Value {
        try TuyaExpression(source).evaluate(value: value, device: device)
    }

    @Test func runsTheDocumentedExpressions() throws {
        let device = TuyaExpression.Value.object(["online": .bool(false), "status": .array([
            .object(["code": .string("switch_led"), "value": .bool(true)]), .object(["code": .string("temp"), "value": .number(20)]),
        ])])
        #expect(try run("(device.online && value)", value: .bool(true), device: device) == .bool(false))
        #expect(try run("(value === 'open') ? true : false;", value: .string("open")) == .bool(true))
        #expect(try run("(value === true) ? 'open' : 'close';", value: .bool(false)) == .string("close"))
        #expect(try run("(value * 5);", value: .number(44)) == .number(220))
        #expect(try run("(value / 5);", value: .number(220)) == .number(44))
        #expect(try run("(100 - value)", value: .number(30)) == .number(70))
        #expect(try run("(value === device.status.find(status => status.code === 'switch_led').value) ? undefined : value", value: .bool(true), device: device)
            == .undefined)
        #expect(try run("(value === device.status.find((s) => s.code === 'switch_led').value) ? undefined : value", value: .bool(false), device: device)
            == .bool(false))
        #expect(try run("Math.round((value - 32) / 1.8);", value: .number(68)) == .number(20))
        #expect(try run("Math.round(1.8 * value + 32);", value: .number(20)) == .number(68))
        #expect(try run("Math.max(Math.min(value, 10), 0) + Math.abs(-1) + Math.floor(1.5) + Math.ceil(0.2)", value: .number(12)) == .number(13))
        #expect(try run("value == '1'", value: .number(1)) == .bool(true))
        #expect(try run("value === '1'", value: .number(1)) == .bool(false))
        #expect(try run("!value || value > 3", value: .number(2)) == .bool(false))
        #expect(try run("'a' + value", value: .number(2)) == .string("a2"))
        #expect(try run("Math.round(-2.5)", value: .number(0)) == .number(-2))
    }

    @Test func refusesWhatItCannotRun() {
        for source in ["require('fs')", "process.exit(1)", "value = 3", "while(true){}", "value.constructor('x')()", "`${value}`", "(", "",
                       String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200)] {
            #expect(throws: (any Error).self, "\(source)") { _ = try run(source, value: .number(1)) }
        }
        #expect(throws: (any Error).self) { _ = try run("device.status.find(s => s.code === 'x').value", value: .number(1), device: .object(["status": .array([])])) }
    }

    // MARK: Devices

    @Test func mergesTheSpecification() throws {
        let merged = TuyaSpecification.merge(try JSONValue(string: FakeTuyaCloud.lampSpecification))
        #expect(merged.keys.sorted() == ["bright_value_v2", "colour_data_v2", "switch_led", "temp_value_v2", "work_mode"])
        #expect(merged.values.allSatisfy { $0.mode == "rw" })
        let partial = TuyaSpecification.merge([
            "status": [["code": "a", "type": "Boolean", "values": "{}"], ["code": "bad", "type": "Raw", "values": "not json"]],
            "functions": [["code": "b", "type": "Integer", "values": #"{"min":1}"#]],
        ])
        #expect(partial["a"]?.mode == "ro")
        #expect(partial["b"]?.mode == "wo")
        #expect(partial["bad"] == nil)
    }

    @Test func appliesOverrides() throws {
        let override = TuyaConfiguration.DeviceOverride(id: "d", schema: [
            .init(code: "temp_set", onGet: "(value * 5);", onSet: "(value / 5);"),
            .init(code: "old", newCode: "switch_led"),
            .init(code: "floodlight_switch", hidden: true),
        ])
        let schema = TuyaSpecification.merge([
            "status": [["code": "temp_set", "type": "Integer", "values": #"{"min":10,"max":70}"#], ["code": "old", "type": "Enum", "values": #"{"range":["open","close"]}"#],
                       ["code": "floodlight_switch", "type": "Boolean", "values": "{}"]],
            "functions": [],
        ])
        let device = TuyaDevice(id: "d", name: "D", online: true, category: "wk", status: ["temp_set": 44, "old": "open", "floodlight_switch": true],
                                schema: schema, override: override)
        #expect(device.status("temp_set") == 220)
        #expect(device.deviceCommands([TuyaCommand(code: "temp_set", value: 220)]) == [TuyaCommand(code: "temp_set", value: 44)])
        #expect(device.find("switch_led")?.type == "Enum")
        #expect(device.status("switch_led") == "open")
        #expect(device.deviceCommands([TuyaCommand(code: "switch_led", value: "close")]) == [TuyaCommand(code: "old", value: "close")])
        #expect(device.find("floodlight_switch", "temp_set") == nil)
        #expect(device.find("old") != nil)
    }

    @Test func readsTheLegacyOverrideShape() throws {
        let element = try JSONDecoder().decode(TuyaConfiguration.SchemaOverride.self, from: Data(#"{"oldCode":"switch_1","code":"switch"}"#.utf8))
        #expect(element.code == "switch_1")
        #expect(element.newCode == "switch")
    }

    @Test func decodesTheExampleBlock() throws {
        let block = #"""
        {"platform":"TuyaPlatform","name":"Tuya","options":{"projectType":"2","accessId":"4h3dxjpwamt9gcrkqv8e","accessKey":"a1b2","countryCode":33,
         "username":"user@example.com","password":"x","appSchema":"smartlife","homeWhitelist":[12345678],"deviceOverrides":[
         {"id":"bf0123456789abcdefgh","adaptiveLighting":true},{"id":"keyabc123","category":"kg"},
         {"id":"bf9876543210zyxwvuts","schema":[{"code":"temp_set","onGet":"(value * 5);","onSet":"(value / 5);","property":{"min":50,"max":350,"scale":1,"step":5}}]},
         {"id":"global","unbridged":false}]}}
        """#
        let configuration = try JSONDecoder().decode(TuyaConfiguration.self, from: Data(block.utf8))
        let settings = try TuyaSettings.validate(configuration.options, credentials: nil).get()
        #expect(settings.projectType == .smartHome)
        #expect(settings.endpointHost == "openapi.tuyaeu.com")
        #expect(settings.override(id: "x", uuid: nil, productID: "keyabc123")?.category == "kg")
        #expect(settings.override(id: "x", uuid: nil, productID: "other")?.id == "global")
        #expect(settings.override(id: "bf9876543210zyxwvuts", uuid: nil, productID: "keyabc123")?.schema?.first?.property?["max"] == 350)
        // Numbers for the project type are read too; a Custom project needs its endpoint.
        let custom = try JSONDecoder().decode(TuyaConfiguration.self, from: Data(#"{"options":{"projectType":1,"accessId":"a","accessKey":"b"}}"#.utf8))
        #expect(throws: TuyaConfigurationError.self) { try TuyaSettings.validate(custom.options, credentials: nil).get() }
        #expect(throws: TuyaConfigurationError.self) { try TuyaSettings.validate(nil, credentials: nil).get() }
        // The vault's secrets stand in for the block's.
        let bare = try JSONDecoder().decode(TuyaConfiguration.self, from: Data(#"{"options":{"projectType":"1","accessId":"a","endpoint":"https://openapi.tuyaus.com"}}"#.utf8))
        #expect(try TuyaSettings.validate(bare.options, credentials: TuyaAccountCredentials(accessKey: "k")).get().accessKey == "k")
    }

    @Test func movesDeviceOverridesIntoAccessorySettings() throws {
        let block = try JSONValue(string: #"""
        {"platform":"TuyaPlatform","options":{"projectType":"2","accessKey":"k","password":"p","deviceOverrides":[
          {"id":"a1b2c3d4e5f60718","adaptiveLighting":false,"schema":[{"code":"x","hidden":true}]},{"id":"keyabc123","category":"kg"}]}}
        """#)
        let canonical = TuyaPlugin.canonical(block, vaultHasKey: true, vaultHasPassword: true, devices: ["a1b2c3d4e5f60718": "bf0123456789abcdefgh"])
        #expect(canonical["options"]?["accessKey"] == nil)
        #expect(canonical["options"]?["password"] == nil)
        #expect(canonical["_accessories"]?["bf0123456789abcdefgh"]?["adaptiveLighting"] == false)
        #expect(canonical["_accessories"]?["bf0123456789abcdefgh"]?["schema"]?.arrayValue?.count == 1)
        #expect(canonical["options"]?["deviceOverrides"]?.arrayValue?.count == 1)
        #expect(TuyaPlugin.canonical(canonical, vaultHasKey: true, vaultHasPassword: true, devices: [:]) == canonical)
    }

    @Test func colourJSONKeepsItsOrder() {
        #expect(TuyaHSV(h: 120, s: 500, v: 1000).json == .string(#"{"h":120,"s":500,"v":1000}"#))
        #expect(TuyaHSV(.string("{}")) == TuyaHSV(h: 0, s: 0, v: 0))
        #expect(TuyaHSV(nil) == TuyaHSV(h: 0, s: 0, v: 0))
    }
}
