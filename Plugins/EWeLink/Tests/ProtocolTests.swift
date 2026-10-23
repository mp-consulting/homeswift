import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftEWeLink

/// The pieces that must match the Homebridge plugin byte for byte or value for value.
struct ProtocolTests {
    @Test func loginIsSignedOverTheExactBody() {
        // Vectors from Node's crypto, as the Homebridge plugin signs.
        let email = CloudAPI.loginBody(username: "user@example.com", password: "secret", countryCode: "+351")
        #expect(email == #"{"countryCode":"+351","password":"secret","email":"user@example.com"}"#)
        #expect(CloudAPI.signature(email) == "SdwREr0g6jbbr6t+28BwPA2OjJZnEKmqV7y+BfUFeqU=")
        let phone = CloudAPI.loginBody(username: "+15551234567", password: #"p"ass\word"#, countryCode: "+1")
        #expect(phone == #"{"countryCode":"+1","password":"p\"ass\\word","phoneNumber":"+15551234567"}"#)
        #expect(CloudAPI.signature(phone) == "aEqEl6vMgFm6CFqNIkLjhqyy+zMSWajPUBgMBa5roEg=")
        let nonce = CloudAPI.nonce()
        #expect(nonce.count == 8 && nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(CloudAPI.nonce() != nonce)
    }

    @Test func lanPayloadsAreAESCBCWithTheMD5OfTheDeviceKey() throws {
        let key = "a1b2c3d4-e5f6-7890-abcd-ef0123456789"
        let iv = Data("0123456789abcdef".utf8)
        // Node: createCipheriv('aes-128-cbc', md5(deviceKey), iv) over JSON.stringify({switch: 'on'}).
        #expect(LANControl.encrypt(["switch": "on"], deviceKey: key, iv: iv) == "dLJ1offnyvRrZuf+f1ADfA==")
        #expect(LANControl.decrypt("dLJ1offnyvRrZuf+f1ADfA==", deviceKey: key, iv: "MDEyMzQ1Njc4OWFiY2RlZg==") == ["switch": "on"])
        #expect(LANControl.decrypt("dLJ1offnyvRrZuf+f1ADfA==", deviceKey: "another-key", iv: "MDEyMzQ1Njc4OWFiY2RlZg==") == nil)

        let encrypted = LANDevice(deviceID: "1000abcdef", ip: "10.0.0.5", port: 8081, encrypt: true, deviceKey: key)
        let payload = LANControl.payload(for: encrypted, params: ["switch": "off"], sequence: "1700000000000", selfAPIKey: "user-api-key")
        #expect(payload["encrypt"] == true && payload["deviceid"] == "1000abcdef" && payload["selfApikey"] == "user-api-key" && payload["sequence"] == "1700000000000")
        let decrypted = LANControl.decrypt(try #require(payload["data"]?.stringValue), deviceKey: key, iv: try #require(payload["iv"]?.stringValue))
        #expect(decrypted == ["switch": "off"])

        let plain = LANDevice(deviceID: "1000abcdef", ip: "10.0.0.5", port: 8081, encrypt: false)
        #expect(LANControl.payload(for: plain, params: ["switch": "on"], sequence: "1", selfAPIKey: "k") == ["sequence": "1", "deviceid": "1000abcdef", "selfApikey": "k", "data": ["switch": "on"]])
        #expect(LANControl.deviceID(fromServiceName: "eWeLink_1001edbf36") == "1001edbf36")
        #expect(LANControl.deviceID(fromServiceName: "Elgato Light") == nil)
    }

    @Test func passwordsAreDecodedLikeNode() {
        #expect(lenientBase64Decode("cGFzc3dvcmQ=\n").map { String(decoding: $0, as: UTF8.self) } == "password")
        #expect(lenientBase64Decode("cGFzc3dvcmQ").map { String(decoding: $0, as: UTF8.self) } == "password")
        #expect(javaScriptStringLiteral("a\"b\\c\n\u{1}") == #""a\"b\\c\n\u0001""#)
    }

    @Test func regionsComeFromCountryCodes() {
        #expect(EWeLinkCloud.Region(countryCode: "+44") == .eu)
        #expect(EWeLinkCloud.Region(countryCode: "351") == .eu)
        #expect(EWeLinkCloud.Region(countryCode: "+86") == .cn)
        #expect(EWeLinkCloud.Region(countryCode: "+61") == .as)
        #expect(EWeLinkCloud.Region(countryCode: "+1") == .us)
        #expect(EWeLinkCloud.Region(countryCode: "EU") == .eu)
        #expect(EWeLinkCloud.Region(countryCode: "+999") == .us)
        #expect(EWeLinkCloud.Region(countryCode: nil) == .us)
        #expect(EWeLinkCloud.Region.eu.httpHost == "eu-apia.coolkit.cc")
        #expect(EWeLinkCloud.Region.cn.socketHosts[2] == "cn-pconnect3.coolkit.cn:8080")
    }

    @Test func temperaturesAndHumiditiesAreParsedAsTheHomebridgePluginDoes() {
        #expect(DeviceValueParser.temperature(["currentTemperature": 25.5]) == 25.5)
        #expect(DeviceValueParser.temperature(["temperature": 22]) == 22)
        #expect(DeviceValueParser.temperature(["currentTemperature": 2550]) == 25.5)
        #expect(DeviceValueParser.temperature([:]) == 20)
        #expect(DeviceValueParser.temperature([:], default: 15) == 15)
        #expect(DeviceValueParser.temperature(["currentTemperature": "23.5"]) == 23.5)
        #expect(DeviceValueParser.temperature(["currentTemperature": "invalid"]) == 20)
        #expect(DeviceValueParser.temperature(["currentTemperature": 25, "temperature": 30]) == 25)
        #expect(DeviceValueParser.humidity(["currentHumidity": 65]) == 65)
        #expect(DeviceValueParser.humidity(["currentHumidity": 6500]) == 65)
        #expect(DeviceValueParser.humidity(["humidity": "55.5"]) == 55.5)
        #expect(DeviceValueParser.humidity([:]) == 50)
        #expect(DeviceValueParser.battery(["battery": 85]) == 85)
        #expect(DeviceValueParser.battery(["battery": "invalid"]) == 100)
        #expect(DeviceValueParser.number("42.5") == 42.5)
        #expect(DeviceValueParser.number(.null, default: 7) == 7)
        #expect(DeviceValueParser.parseSwitch("ON") && !DeviceValueParser.parseSwitch("off") && DeviceValueParser.parseSwitch(true))
        #expect(DeviceValueParser.parseBoolean(1) && DeviceValueParser.parseBoolean("TRUE") && DeviceValueParser.parseBoolean("1") && !DeviceValueParser.parseBoolean(2))
        #expect(DeviceValueParser.powerReadings(["power": "12.5", "voltage": 230]) == .init(power: 12.5, voltage: 230, current: nil))
        #expect(DeviceValueParser.motionState(["state": 1]) && !DeviceValueParser.motionState(["switch": "off"]))
        #expect(DeviceValueParser.contactState(["switch": "on"]))
    }

    @Test func switchesBuildTheWholeArray() {
        let params: DeviceParams = ["switches": [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "on"], ["outlet": 2, "switch": "off"]]]
        #expect(SwitchHelper.currentState(params, channel: 1))
        #expect(!SwitchHelper.currentState(params, channel: 5))
        #expect(SwitchHelper.switchParams(params, channel: 0, on: true) == ["switches": [["outlet": 0, "switch": "on"], ["outlet": 1, "switch": "on"], ["outlet": 2, "switch": "off"]]])
        #expect(SwitchHelper.switchParams(["switch": "off"], channel: 0, on: true) == ["switch": "on"])
        // A Zigbee valve (UIID 7027) reports a boolean.
        #expect(SwitchHelper.currentState(["switch": true]))
        #expect(SwitchHelper.channelCount(["switches": []]) == 1 && SwitchHelper.channelCount(params) == 3)
        #expect(SwitchHelper.isMultiChannel(params) && !SwitchHelper.isMultiChannel(["switches": [["outlet": 0]]]))
        #expect(SwitchHelper.isSCMDevice(["switches": []]) && !SwitchHelper.isSCMDevice([:]))
    }

    @Test func coloursConvertAsTheHomebridgePluginDoes() {
        #expect(EWeLinkColor.rgbToHSV(255, 0, 0) == (0, 100, 100))
        #expect(EWeLinkColor.rgbToHSV(0, 255, 0) == (120, 100, 100))
        #expect(EWeLinkColor.rgbToHSV(255, 0, 255) == (300, 100, 100))
        #expect(EWeLinkColor.rgbToHSV(128, 128, 128) == (0, 0, 50))
        #expect(EWeLinkColor.rgbToHSV(255, 165, 0) == (39, 100, 100))
        #expect(EWeLinkColor.hsvToRGB(0, 100, 100) == (255, 0, 0))
        #expect(EWeLinkColor.hsvToRGB(240, 100, 100) == (0, 0, 255))
        #expect(EWeLinkColor.hsvToRGB(0, 0, 50) == (128, 128, 128))
        #expect(EWeLinkColor.miredFromPercent(0) == 140 && EWeLinkColor.miredFromPercent(100) == 500 && EWeLinkColor.miredFromPercent(50) == 320)
        #expect(EWeLinkColor.miredFromPercent(25) == 230)
        #expect(EWeLinkColor.percentFromMired(140) == 0 && EWeLinkColor.percentFromMired(500) == 100 && EWeLinkColor.percentFromMired(320) == 50)
        #expect(EWeLinkColor.hsToRGB(0, 100) == (255, 0, 0))
        #expect(EWeLinkColor.hsToRGB(120, 100) == (0, 255, 0))
        #expect(EWeLinkColor.hsToRGB(0, 0) == (255, 255, 255))
        #expect(EWeLinkColor.hsToRGB(.nan, 100) == (255, 255, 255))
        // Near-red is red.
        #expect(EWeLinkColor.hsToRGB(5, 100) == (255, 0, 0))
        #expect(EWeLinkColor.rgbToHS(255, 0, 0) == (0, 100))
        #expect(EWeLinkColor.rgbToHS(0, 0, 255) == (240, 100))
        #expect(EWeLinkColor.rgbToHS(255, 0, 128) == (330, 100))
        #expect(EWeLinkColor.rgbToHS(0, 0, 0) == (0, 0))
    }

    @Test func namesAreSanitizedForHomeKit() {
        #expect(sanitizeHomeKitName("Living Room / Lamp") == "Living Room Lamp")
        #expect(sanitizeHomeKitName("_Kitchen_") == "Kitchen")
        #expect(sanitizeHomeKitName("Café 2’") == "Café 2’")
        #expect(sanitizeHomeKitName("🔥") == "Unnamed")
        #expect(sanitizeHomeKitName(nil, fallback: "Light") == "Light")
    }

    @Test func theCatalogRoutesUIIDs() {
        #expect(DeviceCatalog.channelCount(4) == 4 && DeviceCatalog.channelCount(1) == 1 && DeviceCatalog.channelCount(99_999) == 1)
        #expect(DeviceCategory(uiid: 1) == .singleSwitch && DeviceCategory(uiid: 4) == .multiSwitch && DeviceCategory(uiid: 28) == .rfBridge)
        #expect(DeviceCategory(uiid: 66) == .rfBridge && DeviceCategory(uiid: 174) == .singleSwitch && DeviceCategory(uiid: 5000) == .group)
        #expect(DeviceCategory(uiid: 12_345) == .unknown)
        #expect(DeviceCatalog.isWaterValve(7027) && !DeviceCatalog.isWaterValve(1) && !DeviceCatalog.isWaterValve(32) && !DeviceCatalog.isWaterValve(7019))
        #expect(DeviceCatalog.hasFullPowerReadings(32) && !DeviceCatalog.hasFullPowerReadings(5) && DeviceCatalog.hasPowerMonitoring(5))
        #expect(DeviceCatalog.position(11)?.inverted == true && DeviceCatalog.position(11)?.current == "setclose")
        #expect(DeviceCatalog.motorTurnParam(126) == "motorTurn")
        #expect(DeviceCatalog.normalizeBrightness(36, 10) == 0 && DeviceCatalog.normalizeBrightness(36, 100) == 100 && DeviceCatalog.denormalizeBrightness(36, 50) == 55)
        #expect(DeviceCatalog.hasCurtainParams(["currLocation": 50]) && !DeviceCatalog.hasCurtainParams(["switches": []]))
        let dualR3 = EWeLinkDevice(device("1000aa", uiid: 126, params: ["location": 20]))!
        #expect(DeviceCategory.resolve(dualR3) == .curtain)
        #expect(HandlerKind.resolve(showAs: "default", uiid: 15, category: .thermostat) == .thSensor)
        #expect(HandlerKind.resolve(showAs: "thermostat", uiid: 15, category: .thermostat) == .thThermostat)
        #expect(HandlerKind.resolve(showAs: "default", uiid: 127, category: .thermostat) == .thermostat)
        #expect(HandlerKind.resolve(showAs: "heater", uiid: 1, category: .singleSwitch) == .heater)
        #expect(HandlerKind.resolve(showAs: "fan", uiid: 36, category: .light) == .lightFan)
        #expect(HandlerKind.resolve(showAs: "default", uiid: 174, category: .singleSwitch) == .switchMini)
        #expect(HandlerKind.resolve(showAs: "default", uiid: 177, category: .singleSwitch) == .switchMate)
        #expect(HandlerKind.resolve(showAs: "default", uiid: 7027, category: .singleSwitch) == .tap)
        #expect(HandlerKind.resolve(showAs: "switch", uiid: 7027, category: .singleSwitch) == .switch)
        #expect(HandlerKind.resolve(showAs: "outlet", uiid: 1, category: .singleSwitch) == .outlet)
        #expect(HandlerKind.resolve(showAs: "blind", uiid: 126, category: .multiSwitch) == .blind)
        #expect(DeviceLimits.parentDeviceID("1000abcdefSW12") == "1000abcdef" && DeviceLimits.parentDeviceID("1000abcdef") == "1000abcdef")
    }

    @Test func rfRemotesListTheirButtonsInJavaScriptKeyOrder() throws {
        let bridge = try #require(EWeLinkDevice(device("1000rf", uiid: 28, extra: ["tags": ["zyx_info": [
            ["name": "Remote", "remote_type": "4", "buttonName": [["2": "C"], ["0": "A"], ["1": "B"]]],
            ["name": "Door", "remote_type": "7", "buttonName": [["3": "Sensor"]]],
        ]]])))
        let remotes = bridge.rfDevices
        #expect(remotes.count == 2)
        #expect(remotes[0].buttons.map(\.channel) == ["0", "1", "2"] && remotes[0].buttons.map(\.name) == ["A", "B", "C"])
        #expect(remotes[1].remoteType == "7")
    }

    @Test func javaScriptConversions() {
        #expect(JSONValue.string("12.5abc").jsParseFloat == 12.5)
        #expect(JSONValue.string(" 7").jsParseInt == 7)
        #expect(JSONValue.string("abc").jsParseFloat == nil)
        #expect(JSONValue.bool(true).jsNumber == 1 && JSONValue.string("").jsNumber == 0 && JSONValue.string("x").jsNumber == nil)
        #expect(JSONValue.number(25).jsString == "25" && JSONValue.number(2.5).jsString == "2.5")
        #expect(jsRound(2.5) == 3 && jsRound(-2.5) == -2)
    }

    @Test func reconnectAndRetryDelays() {
        // 5 s doubling, at most 5 min, ±20 %.
        #expect(CloudSocket.reconnectDelay(attempt: 1, random: 0.5) == 5000)
        #expect(CloudSocket.reconnectDelay(attempt: 2, random: 0.5) == 10000)
        #expect(CloudSocket.reconnectDelay(attempt: 4, random: 0.5) == 40000)
        #expect(CloudSocket.reconnectDelay(attempt: 20, random: 0.5) == 300_000)
        #expect(CloudSocket.reconnectDelay(attempt: 1, random: 0) == 4000)
        #expect(CloudSocket.reconnectDelay(attempt: 1, random: 1) == 6000)
        // Discovery: 15 s doubling, at most 5 min.
        #expect(EWeLinkPlatform.retryDelay(attempt: 1, random: 0.5) == 15000)
        #expect(EWeLinkPlatform.retryDelay(attempt: 3, random: 0.5) == 60000)
        #expect(EWeLinkPlatform.retryDelay(attempt: 9, random: 0.5) == 300_000)
    }
}

/// The platform block users have today.
struct ConfigurationTests {
    @Test func decodesARealisticBlock() throws {
        let json = #"""
        {
          "platform": "eWeLink", "name": "eWeLink", "username": "user@example.com", "password": "c2VjcmV0", "countryCode": "+351",
          "mode": "auto", "language": "en", "debug": true, "disableDeviceLogging": false, "offlineAsOff": "true", "outlineInLog": true,
          "commandQueueInterval": "500", "commandQueueConcurrency": 2,
          "singleDevices": [
            { "deviceId": "1000aaaaaa", "label": "Porch", "showAs": "garage", "operationTime": "30" },
            { "deviceId": "1000bbbbbb", "showAs": "outlet", "isInched": true, "inUsePowerThreshold": 5 },
            { "deviceId": "1000cccccc", "showAs": "heater", "tempSource": "1000dddddd" },
            { "label": "no id" }
          ],
          "multiDevices": [{ "deviceId": "1000eeeeee", "showAs": "blind", "operationTime": 25, "operationTimeDown": 20, "hideChannels": "1,2" }],
          "thDevices": [{ "deviceId": "1000ffffff", "showAs": "thermostat", "tempOffset": -0.5, "minTarget": 15, "maxTarget": 28, "targetTempThreshold": 1, "showHeatCool": true }],
          "lightDevices": [{ "deviceId": "1000gggggg", "showAs": "fan", "brightnessStep": 10, "adaptiveLightingShift": 0 }],
          "fanDevices": [{ "deviceId": "1000hhhhhh", "hideLight": true }],
          "sensorDevices": [{ "deviceId": "1000iiiiii", "hideTemp": false, "tempOffset": 1, "humidityOffset": -3, "lowBattery": 15 }],
          "rfDevices": [{ "deviceId": "1000jjjjjj", "subdevices": [{ "index": 0, "label": "Hall", "showAs": "contact", "resetTime": 30 }] }],
          "bridgeSensors": [{ "fullDeviceId": "1000jjjjjjSW2", "label": "Shade", "deviceType": "curtain", "curtainType": "blind", "operationTime": 40, "sensorTimeLength": 60, "sensorTimeDifference": 60 }],
          "groups": [{ "type": "blind", "deviceIds": ["1000aaaaaa"], "label": "All", "operationTime": 20 }],
          "ignoredDevices": ["1000zzzzzz"],
          "_bridge": { "username": "0E:00:00:00:00:01" }
        }
        """#
        let configuration = try JSONDecoder().decode(EWeLinkPlugin.Configuration.self, from: Data(json.utf8))
        #expect(configuration.username == "user@example.com" && configuration.password == "c2VjcmV0" && configuration.countryCode == "+351")
        #expect(configuration.connectionMode == .auto && configuration.debug == true && configuration.offlineAsOff == true)
        #expect(configuration.commandQueueInterval == 500 && configuration.commandQueueConcurrency == 2)
        #expect(configuration.singleDevices?.count == 4)
        #expect(configuration.single("1000aaaaaa")?.showAs == "garage" && configuration.single("1000aaaaaa")?.operationTime == 30)
        #expect(configuration.single("1000bbbbbb")?.isInched == true && configuration.single("1000bbbbbb")?.inUsePowerThreshold == 5)
        #expect(configuration.single("1000cccccc")?.tempSource == "1000dddddd")
        #expect(configuration.multi("1000eeeeee")?.hideChannels == "1,2" && configuration.multi("1000eeeeee")?.operationTimeDown == 20)
        #expect(configuration.thermostat("1000ffffff")?.tempOffset == -0.5 && configuration.thermostat("1000ffffff")?.showHeatCool == true)
        #expect(configuration.light("1000gggggg")?.brightnessStep == 10 && configuration.fan("1000hhhhhh")?.hideLight == true)
        #expect(configuration.sensor("1000iiiiii")?.lowBattery == 15)
        #expect(configuration.rf("1000jjjjjj")?.subdevices?.first?.showAs == "contact" && configuration.rf("1000jjjjjj")?.subdevices?.first?.resetTime == 30)
        #expect(configuration.bridgeSensors?.first?.curtainType == "blind" && configuration.groups?.first?.deviceIds == ["1000aaaaaa"])
        #expect(configuration.isIgnored("1000zzzzzz") && !configuration.isIgnored("1000aaaaaa"))
        #expect(configuration.showAs("1000eeeeee", category: .multiSwitch) == "blind")

        let minimal = try JSONDecoder().decode(EWeLinkPlugin.Configuration.self, from: Data(#"{"platform":"eWeLink","mode":"wan","singleDevices":"oops"}"#.utf8))
        #expect(minimal.connectionMode == .wan && minimal.singleDevices == nil && minimal.username == nil)
        #expect(try JSONDecoder().decode(EWeLinkPlugin.Configuration.self, from: Data(#"{"mode":"nonsense"}"#.utf8)).connectionMode == .auto)
    }

    @Test func theSchemaIsEmbeddedAndCurrent() throws {
        let schema = try #require(EWeLinkPlugin.configurationSchemaJSON)
        let parsed = try JSONValue(string: schema)
        #expect(parsed["pluginAlias"] == "eWeLink")
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: directory.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(file.trimmingCharacters(in: .whitespacesAndNewlines) == schema)
    }

    @Test func theWebFilesAreEmbeddedAndCurrent() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        #expect(Set(names) == Set(EWeLinkPlugin.webFiles.keys))
        for name in names {
            let content = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(EWeLinkPlugin.webFiles[name]?.body == content, "\(name) is stale: run Scripts/embed-assets.swift")
        }
    }
}
