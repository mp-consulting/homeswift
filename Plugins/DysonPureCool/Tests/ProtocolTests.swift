import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import HomeswiftDysonPureCool

/// The Homebridge plugin's messageCodec, deviceCatalog, mdnsDiscovery and cloudApi tests, with its fixtures.
struct MessageCodecTests {
    func message(_ text: String) throws -> [String: JSONValue] {
        try #require(try JSONValue(string: text).objectValue)
    }

    /// The state a message leaves, from nothing; nil for a message that carries none.
    func state(_ message: [String: JSONValue]) -> DeviceState? {
        var state = DeviceState()
        return MessageCodec.apply(message, to: &state) ? state : nil
    }

    func parsed(_ fields: [String: JSONValue]) -> DeviceState {
        var state = DeviceState()
        MessageCodec.parseState(fields, into: &state)
        return state
    }

    @Test func currentStateOfAPureCool() throws {
        let update = try #require(state(try message("""
            {"msg":"CURRENT-STATE","time":"2026-01-16T10:30:00.000Z","mode-reason":"LAPP","product-state":{
             "fpwr":"ON","fmod":"FAN","auto":"OFF","fnsp":"0005","oson":"ON","oscs":"0045","osce":"0315","nmod":"OFF","rhtm":"ON",
             "ffoc":"OFF","tact":"2951","hact":"0055","p25r":"0003","p10r":"0005","va10":"0002","filf":"2400","cflr":"0100"}}
            """)))
        #expect(update.isOn == true)
        #expect(update.autoMode == false)
        #expect(update.fanSpeed == 5)
        #expect(update.oscillation == true)
        #expect(update.oscillationAngleStart == 45)
        #expect(update.oscillationAngleEnd == 315)
        #expect(update.nightMode == false)
        #expect(update.continuousMonitoring == true)
        #expect(update.frontAirflow == false)
        #expect(update.temperature == 2951)
        #expect(update.humidity == 55)
        #expect(update.pm25 == 3)
        #expect(update.pm10 == 5)
        #expect(update.vocIndex == 2)
        // filf is hours of 4300: 2400 h is 56 %.
        #expect(update.hepaFilterLife == 56)
        #expect(update.carbonFilterLife == 100)
    }

    @Test func currentStateOfAHotCoolLink() throws {
        let update = parsed(try #require(try JSONValue(encoding: FakeStates.hp02).objectValue))
        #expect(update.isOn == false)
        #expect(update.fanSpeed == MessageCodec.FanSpeed.auto)
        #expect(update.fanState == false)
        #expect(update.airQualityTarget == 4)
        #expect(update.heatingEnabled == true)
        #expect(update.targetTemperature == 2950)
        #expect(update.heatingActive == false)
        #expect(update.frontAirflow == true)
        #expect(update.errorCode == "NONE")
        #expect(update.warningCode == "NONE")
        #expect(update.tiltStatus == "OK")
        #expect(update.hepaFilterLife == 96)
    }

    @Test func humidifierAndFormaldehydeFields() throws {
        let humidifier = parsed(try #require(try JSONValue(encoding: FakeStates.ph03).objectValue))
        #expect(humidifier.humidifierEnabled == true)
        #expect(humidifier.humidifierAuto == false)
        #expect(humidifier.targetHumidity == 50)
        #expect(humidifier.autoMode == true)
        let auto = parsed(["hume": "AUTO"])
        #expect(auto.humidifierEnabled == true)
        #expect(auto.humidifierAuto == true)
        let formaldehyde = parsed(try #require(try JSONValue(encoding: FakeStates.tp09).objectValue))
        #expect(formaldehyde.no2Index == 1)
        #expect(formaldehyde.formaldehydeLevel == 5)
        #expect(formaldehyde.carbonFilterLife == 95)
    }

    @Test func stateChangeTakesTheNewValue() throws {
        let update = try #require(state(try message("""
            {"msg":"STATE-CHANGE","product-state":{"fpwr":["OFF","ON"],"fmod":["OFF","FAN"],"fnsp":["0000","0005"]}}
            """)))
        #expect(update.isOn == true)
        #expect(update.fanSpeed == 5)
        let auto = try #require(state(try message(#"{"msg":"STATE-CHANGE","product-state":{"fmod":["FAN","AUTO"],"auto":["OFF","ON"]}}"#)))
        #expect(auto.autoMode == true)
        let heating = try #require(state(try message(#"{"msg":"STATE-CHANGE","product-state":{"hmod":["OFF","HEAT"],"hmax":["2931","2951"]}}"#)))
        #expect(heating.heatingEnabled == true)
        #expect(heating.targetTemperature == 2951)
        // `data` instead of `product-state`.
        let data = try #require(state(try message(#"{"msg":"CURRENT-STATE","data":{"nmod":"ON"}}"#)))
        #expect(data.nightMode == true)
        #expect(state(try message(#"{"msg":"CURRENT-STATE"}"#)) == nil)
        #expect(state(try message(#"{"msg":"HELLO"}"#)) == nil)
    }

    @Test func environmentalData() throws {
        let link = try #require(state(try message("""
            {"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"tact":"2903","hact":"0083","pact":"0000","vact":"0002","sltm":"OFF"}}
            """)))
        #expect(link.temperature == 2903)
        #expect(link.humidity == 83)
        #expect(link.pm25 == 0)
        #expect(link.vocIndex == 2)
        #expect(link.sleepTimer == 0)
        let warming = try #require(state(try message("""
            {"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"tact":"OFF","hact":"OFF","p25r":"INIT","p10r":"INIT","va10":"INIT"}}
            """)))
        // No reading, but the sensors say they are off.
        var off = DeviceState()
        off.temperatureOff = true
        off.humidityOff = true
        #expect(warming == off)
        // pact never overrides a p25r density, vact never a va10 reading.
        var both = DeviceState()
        MessageCodec.parseEnvironment(["p25r": "0012", "pact": "0003", "va10": "0040", "vact": "0001", "sltm": "0030"], into: &both)
        #expect(both.pm25 == 12)
        #expect(both.vocIndex == 40)
        #expect(both.sleepTimer == 30)
    }

    @Test func filterFields() {
        #expect(parsed(["fltf": "0042"]).hepaFilterLife == 42)
        // The TP04 generation reports the HEPA filter as hflr.
        #expect(parsed(["hflr": "0005", "cflr": "0080"]).hepaFilterLife == 5)
        #expect(parsed(["hflr": "INV"]).hepaFilterLife == nil)
        #expect(parsed(["filf": "9999"]).hepaFilterLife == 100)
        #expect(parsed(["cflr": "-005"]).carbonFilterLife == 0)
        #expect(parsed(["filf": "INVALID"]).hepaFilterLife == nil)
    }

    @Test func javascriptIntegers() {
        #expect(MessageCodec.integer("0005") == 5)
        #expect(MessageCodec.integer("2951") == 2951)
        #expect(MessageCodec.integer("12abc") == 12)
        #expect(MessageCodec.integer("-3") == -3)
        #expect(MessageCodec.integer("AUTO") == nil)
        #expect(MessageCodec.integer("") == nil)
    }

    @Test func fanSpeeds() {
        #expect(MessageCodec.encodeFanSpeed(5) == "0005")
        #expect(MessageCodec.encodeFanSpeed(10) == "0010")
        #expect(MessageCodec.encodeFanSpeed(0) == "0001")
        #expect(MessageCodec.encodeFanSpeed(15) == "0010")
        #expect(MessageCodec.encodeFanSpeed(-1) == "AUTO")
        #expect(MessageCodec.decodeFanSpeed("0007") == (7, false))
        #expect(MessageCodec.decodeFanSpeed("AUTO") == (-1, true))
        #expect(MessageCodec.decodeFanSpeed("junk") == (0, false))
        #expect(MessageCodec.percentToSpeed(0) == 1)
        #expect(MessageCodec.percentToSpeed(10) == 1)
        #expect(MessageCodec.percentToSpeed(55) == 6)
        #expect(MessageCodec.percentToSpeed(100) == 10)
        #expect(MessageCodec.percentToSpeed(150) == 10)
        #expect(MessageCodec.speedToPercent(5) == 50)
        #expect(MessageCodec.speedToPercent(-1) == 0)
        #expect(MessageCodec.speedToPercent(12) == 100)
    }

    /// Numbers no device or HomeKit write should send still convert without trapping.
    @Test func outOfRangeNumbers() {
        #expect(MessageCodec.value(.number(1e300)) == String(1e300))
        #expect(MessageCodec.value(.number(.infinity)) == String(Double.infinity))
        #expect(MessageCodec.value(.number(42)) == "42")
        #expect(MessageCodec.value(.number(2.5)) == "2.5")
        #expect(parsed(["fnsp": .number(1e300), "filf": .number(1e300), "fltf": .number(-1e300)]).hepaFilterLife == 0)
        #expect(parsed(["filf": "99999999999999999999"]).hepaFilterLife == nil)
        #expect(MessageCodec.clampPercent(1e300) == 100)
        #expect(MessageCodec.clampPercent(-.infinity) == 0)
        #expect(MessageCodec.clampPercent(.nan) == 0)
        #expect(MessageCodec.percentToSpeed(.infinity) == 10)
        #expect(MessageCodec.percentToSpeed(.nan) == 1)
        #expect(MessageCodec.speedToPercent(.max) == 100)
        #expect(MessageCodec.encodeTemperature(1e300) == String(Int.max))
        #expect(MessageCodec.encodeTemperature(.nan) == "0")
    }

    @Test func temperatures() {
        // Kelvin × 10: 2951 is 21.95 °C.
        #expect(MessageCodec.encodeTemperature(21) == "2942")
        #expect(MessageCodec.encodeTemperature(22) == "2952")
        #expect(MessageCodec.encodeTemperature(1) == "2742")
        #expect(abs(MessageCodec.decodeTemperature(2951) - 21.95) < 0.0001)
        #expect(MessageCodec.decodeCelsius(2951) == 22.0)
        #expect(MessageCodec.decodeCelsius(2901) == 17.0)
        #expect(MessageCodec.decodeCelsius(0) == nil)
        #expect(MessageCodec.decodeCelsius(nil) == nil)
    }

    @Test func commands() throws {
        let date = Date(timeIntervalSince1970: 1_768_559_400)
        let set = try JSONValue(data: MessageCodec.stateSet(["fmod": "FAN", "fnsp": "0007"], time: date))
        #expect(set == ["msg": "STATE-SET", "time": "2026-01-16T10:30:00.000Z", "mode-reason": "LAPP", "data": ["fmod": "FAN", "fnsp": "0007"]])
        let request = try JSONValue(data: MessageCodec.requestCurrentState(time: date))
        #expect(request == ["msg": "REQUEST-CURRENT-STATE", "time": "2026-01-16T10:30:00.000Z"])
        let environment = MessageCodec.requestEnvironment(time: date)
        #expect(String(decoding: environment, as: UTF8.self) == #"{"msg":"REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA","time":"2026-01-16T10:30:00.000Z"}"#)
        #expect(MessageCodec.statusTopic(productType: "438", serial: "ABC-AB-12345678") == "438/ABC-AB-12345678/status/current")
        #expect(MessageCodec.commandTopic(productType: "438", serial: "ABC-AB-12345678") == "438/ABC-AB-12345678/command")
    }

    @Test func reportedPower() throws {
        #expect(MessageCodec.reportedPower(["fpwr": "ON"]) == true)
        #expect(MessageCodec.reportedPower(["fpwr": "ON", "fmod": "OFF"]) == false)
        #expect(MessageCodec.reportedPower(["fmod": ["OFF", "AUTO"]]) == true)
        #expect(MessageCodec.reportedPower(["oson": "ON"]) == nil)
    }
}

struct DeviceCatalogTests {
    @Test func features() {
        let tp04 = DeviceCatalog.features("438")
        #expect(tp04.fan && tp04.oscillation && tp04.autoMode && tp04.frontAirflow && tp04.airQualitySensor)
        #expect(!tp04.heating && !tp04.humidifier && !tp04.no2Sensor && !tp04.basicAirQualitySensor)
        let hp02 = DeviceCatalog.features("455")
        #expect(hp02.heating && hp02.basicAirQualitySensor && hp02.frontAirflow)
        #expect(!DeviceCatalog.features("438M").frontAirflow)
        #expect(DeviceCatalog.features("438K").no2Sensor)
        #expect(DeviceCatalog.features("358E").humidifier && DeviceCatalog.features("358E").no2Sensor)
        let bigQuiet = DeviceCatalog.features("664")
        #expect(!bigQuiet.oscillation && bigQuiet.no2Sensor)
        let cf1 = DeviceCatalog.features("739")
        #expect(!cf1.autoMode && !cf1.temperatureSensor && !cf1.hepaFilter && !cf1.continuousMonitoring && cf1.oscillation)
        #expect(DeviceCatalog.features("999") == .default)
    }

    @Test func powerProtocolAndNames() {
        #expect(DeviceCatalog.powerProtocol("475") == .fpwr)
        #expect(DeviceCatalog.powerProtocol("469") == .fpwr)
        #expect(DeviceCatalog.powerProtocol("739") == .fpwr)
        #expect(DeviceCatalog.powerProtocol("438") == .fmod)
        #expect(DeviceCatalog.powerProtocol("999") == .fmod)
        #expect(DeviceCatalog.modelName("438") == "Dyson Pure Cool Tower (TP04)")
        #expect(DeviceCatalog.modelName("999") == "Dyson Device (999)")
        #expect(DeviceCatalog.displayNames["527K"] == "HP09 - Dyson Purifier Hot+Cool Formaldehyde")
        #expect(DeviceCatalog.isSupported("664F"))
        #expect(!DeviceCatalog.isSupported("123"))
        #expect(Set(DeviceCatalog.heatingProductTypes) == ["455", "527", "527E", "527K", "527M"])
        #expect(DeviceCatalog.models.count == 24)
    }
}

struct DiscoveryTests {
    @Test func serials() {
        #expect(Discovery.serial(fromServiceName: "ABC-AB-12345678") == "ABC-AB-12345678")
        #expect(Discovery.serial(fromServiceName: "ABC-AB-12345678_dyson_mqtt") == "ABC-AB-12345678")
        #expect(Discovery.serial(fromServiceName: "455_abc-ab-12345678") == "ABC-AB-12345678")
        #expect(Discovery.serial(fromServiceName: "455_AB-CD-ABCD1234_dyson_mqtt") == "AB-CD-ABCD1234")
        #expect(Discovery.serial(fromServiceName: "Living Room") == nil)
    }

    @Test func fallsBackToTheSenderWithoutALocalIPv4Record() {
        // As mdnsDiscovery's referer fallback: a private IPv4 sender beats IPv6 records, a public one never counts.
        #expect(Discovery.address(of: ["fe80::1"], referer: "192.168.1.30") == "192.168.1.30")
        #expect(Discovery.address(of: ["192.168.1.20"], referer: "192.168.1.30") == "192.168.1.20")
        #expect(Discovery.address(of: ["fe80::1"], referer: "8.8.8.8") == "fe80::1")
        #expect(Discovery.address(of: [], referer: "fe80::2") == nil)
        let responses = [
            MDNSQuery.Response(sender: "192.168.1.30", names: ["_dyson_mqtt._tcp.local", "455_ABC-AB-12345678._dyson_mqtt._tcp.local", "ABC-AB-12345678.local"]),
            MDNSQuery.Response(sender: "192.168.1.31", names: ["XYZ-AB-87654321._dyson_mqtt._tcp.local"]),
            // A host name alone is not an instance of the service.
            MDNSQuery.Response(sender: "192.168.1.32", names: ["QQQ-AB-11111111.local"]),
        ]
        let referers = Discovery.senders(of: responses)
        #expect(referers == ["ABC-AB-12345678": "192.168.1.30", "XYZ-AB-87654321": "192.168.1.31"])
        let merged = Discovery.merge(addresses: ["ABC-AB-12345678": [], "DEF-AB-00000000": ["192.168.1.40"]], referers: referers)
        #expect(merged == ["ABC-AB-12345678": "192.168.1.30", "XYZ-AB-87654321": "192.168.1.31", "DEF-AB-00000000": "192.168.1.40"])
    }

    @Test func onlyLocalAddresses() {
        #expect(Discovery.isLocalNetworkAddress("192.168.1.10"))
        #expect(Discovery.isLocalNetworkAddress("10.0.0.2"))
        #expect(Discovery.isLocalNetworkAddress("172.16.4.1"))
        #expect(!Discovery.isLocalNetworkAddress("172.32.4.1"))
        #expect(!Discovery.isLocalNetworkAddress("8.8.8.8"))
        #expect(Discovery.isLocalNetworkAddress("fe80::1"))
        #expect(Discovery.isLocalNetworkAddress("fd00::1"))
        #expect(!Discovery.isLocalNetworkAddress("2001:db8::1"))
        #expect(Discovery.address(of: ["fe80::1", "8.8.8.8", "192.168.1.20"]) == "192.168.1.20")
        #expect(Discovery.address(of: ["fe80::1", "8.8.8.8"]) == "fe80::1")
        #expect(Discovery.address(of: ["8.8.8.8"]) == nil)
        #expect(!Discovery.isIPv4("192.168.1"))
        #expect(!Discovery.isIPv4("192.168.1.256"))
        // UInt8("+19") is 19: a sign is not a digit.
        #expect(!Discovery.isIPv4("+19.168.1.1"))
        #expect(!Discovery.isIPv4("192.+16.1.1"))
        #expect(!Discovery.isPrivateIPv4("+10.0.0.1"))
        #expect(Discovery.isIPv4("192.168.1.1"))
    }
}

struct CloudTests {
    let cloud = FakeCloud()
    var api: DysonCloud { DysonCloud(transport: cloud, logger: testLogger) }

    @Test func credentialsDecrypt() throws {
        let encrypted = try DysonCloud.encrypt(apPasswordHash: "local-pass-123")
        #expect(try DysonCloud.decrypt(encrypted) == "local-pass-123")
        #expect(api.decryptCredentials("invalid-base64-garbage") == "")
        // The Node reference: AES-256-CBC, key 0x01...0x20, IV zero, of {"apPasswordHash":"local-pass-123"}.
        #expect(encrypted == "juMwpAl06WHHsg7JAUz6XQ0zQ/ibw7oFiIwIqjnQNvEo46CpQa5G/rBBVFprneMY")
    }

    @Test func signInWithACode() async throws {
        let challenge = try await api.requestCode(email: "user@example.com", countryCode: "GB")
        #expect(challenge == .code(challengeID: "challenge-1"))
        #expect(cloud.paths == ["GET /v1/provisioningservice/application/Android/version", "POST /v3/userregistration/email/userstatus", "POST /v3/userregistration/email/auth"])
        #expect(cloud.requests[1].url.query == "country=GB")
        #expect(cloud.requests[2].url.query == "country=GB&culture=en-GB")
        #expect(cloud.requests[0].header("User-Agent") == "android client")
        let token = try await api.verify(email: "user@example.com", password: "secret", challengeID: "challenge-1", code: "123456", countryCode: "GB")
        #expect(token == "token-1")
        let verify = try #require(cloud.requests.last)
        #expect(try JSONValue(data: verify.body ?? Data()) == ["email": "user@example.com", "password": "secret", "challengeId": "challenge-1", "otpCode": "123456"])
    }

    @Test func signInFailures() async throws {
        await #expect(throws: DysonCloud.Failure(status: 401, message: "Account not active or not found")) {
            _ = try await api.requestCode(email: "nobody@example.com", countryCode: "US")
        }
        await #expect(throws: DysonCloud.Failure(status: 401, message: "Unable to authenticate user.")) {
            _ = try await api.verify(email: "user@example.com", password: "wrong", challengeID: "challenge-1", code: "123456", countryCode: "US")
        }
        await #expect(throws: DysonCloud.Failure(status: 400, message: "Invalid OTP code")) {
            _ = try await api.verify(email: "user@example.com", password: "secret", challengeID: "challenge-1", code: "000000", countryCode: "US")
        }
        cloud.set(account: .init(direct: true))
        #expect(try await api.requestCode(email: "user@example.com", countryCode: "US") == .token("token-1"))
    }

    @Test func manifest() async throws {
        let credentials = try DysonCloud.encrypt(apPasswordHash: "local-pass-123")
        cloud.set(manifest: [
            ["serialNumber": "ABC-AB-12345678", "name": "Living Room", "type": "438", "variant": nil, "model": nil, "category": "ec", "connectionCategory": "wifiOnly",
             "productName": "Pure Cool", "connectedConfiguration": ["mqtt": ["remoteBrokerType": "wss", "localBrokerCredentials": .string(credentials), "mqttRootTopicLevel": "438"], "firmware": ["autoUpdate": true]]],
            ["Serial": "XYZ-AB-87654321", "Name": "Bedroom", "ProductType": "527", "Version": "21.04.03", "LocalCredentials": .string(credentials), "AutoUpdate": false, "NewVersionAvailable": true],
            ["serialNumber": "VAC-AB-00000000", "type": "276", "connectedConfiguration": nil],
        ])
        let devices = try await api.devices(token: "token-1")
        #expect(devices.count == 3)
        #expect(devices[0] == DysonCloud.CloudDevice(serial: "ABC-AB-12345678", name: "Living Room", productType: "438", version: "", autoUpdate: true, newVersionAvailable: false, localCredentials: "local-pass-123"))
        #expect(devices[1] == DysonCloud.CloudDevice(serial: "XYZ-AB-87654321", name: "Bedroom", productType: "527", version: "21.04.03", autoUpdate: false, newVersionAvailable: true, localCredentials: "local-pass-123"))
        #expect(devices[2].localCredentials == "")
        #expect(cloud.requests.last?.header("Authorization") == "Bearer token-1")
        cloud.expire(token: "token-1")
        await #expect(throws: DysonCloud.Failure(status: 401, message: "Session expired")) { _ = try await api.devices(token: "token-1") }
    }

    /// A refusal with no body is a refusal, not an empty manifest.
    @Test func anEmptyRefusal() async throws {
        struct Refusing: HTTPSending {
            let status: Int
            func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
                HomeswiftNetwork.HTTPResponse(status: status)
            }
        }
        for status in [401, 403] {
            let api = DysonCloud(transport: Refusing(status: status), logger: testLogger)
            await #expect(throws: DysonCloud.Failure(status: 401, message: "Session expired")) { _ = try await api.devices(token: "t") }
            await #expect(throws: DysonCloud.Failure(status: status, message: "HTTP \(status)")) { _ = try await api.request("/v1/provisioningservice/application/Android/version") }
        }
        // Other empty answers are still nothing, as in Homebridge.
        let api = DysonCloud(transport: Refusing(status: 204), logger: testLogger)
        #expect(try await api.request("/v1/provisioningservice/application/Android/version") == nil)
    }

    @Test func inputChecks() throws {
        #expect(try CloudInput.email("a@b.co") == "a@b.co")
        #expect(throws: DysonCloud.Failure.self) { try CloudInput.email("not an email") }
        #expect(throws: DysonCloud.Failure.self) { try CloudInput.password("") }
        #expect(try CloudInput.code("123456") == "123456")
        #expect(throws: DysonCloud.Failure.self) { try CloudInput.code("12345") }
        #expect(throws: DysonCloud.Failure.self) { try CloudInput.code("12345a") }
        #expect(try CloudInput.countryCode("gb") == "GB")
        #expect(try CloudInput.countryCode(nil) == "US")
        #expect(throws: DysonCloud.Failure.self) { try CloudInput.countryCode("GBR") }
        #expect(try CloudInput.optionalIPAddress("") == nil)
        #expect(try CloudInput.optionalIPAddress(nil) == nil)
        #expect(try CloudInput.optionalIPAddress("192.168.1.2") == "192.168.1.2")
        #expect(throws: DysonCloud.Failure.self) { try CloudInput.optionalIPAddress("evil.example.com") }
    }
}

struct ConfigurationTests {
    /// A block as the Homebridge settings wizard and hand edits write it.
    static let block = """
        {
          "platform": "DysonPureCool",
          "name": "Dyson Pure Cool",
          "countryCode": "GB",
          "devices": [
            {
              "serial": "ABC-AB-12345678", "name": "Living Room Purifier", "productType": "527",
              "localCredentials": "secret-hash", "ipAddress": "192.168.1.100", "firmwareVersion": "21.04.03",
              "temperatureOffset": -2, "humidityOffset": "5", "useFahrenheit": true, "heatingServiceType": "both",
              "isHeatingSafetyIgnored": false, "fullRangeHumidity": true, "enableAutoModeWhenActivating": true,
              "enableOscillationWhenActivating": "true", "enableNightModeWhenActivating": false,
              "isContinuousMonitoringEnabled": true, "isNightModeEnabled": false, "isJetFocusEnabled": true,
              "isTemperatureIgnored": false, "isHumidityIgnored": false, "isAirQualityIgnored": true, "isHeatingDisabled": false
            },
            { "serial": "XYZ-AB-87654321", "productType": 438, "credentials": "legacy" },
            null
          ],
          "isSingleAccessoryModeEnabled": false,
          "isSingleSensorAccessoryModeEnabled": false,
          "enableTemperature": true, "enableHumidity": false, "enableAirQuality": true, "enableNightMode": true,
          "enableAutoMode": true, "enableContinuousMonitoring": false, "enableJetFocus": false, "enableHeater": true,
          "enableHumidifier": true, "enableFilterStatus": false, "pollingInterval": "120", "discoveryTimeout": 30,
          "_bridge": { "username": "0E:1A:2B:3C:4D:5F" }
        }
        """

    @Test func decodesAFullBlock() throws {
        let configuration = try JSONDecoder().decode(DysonPureCoolPlugin.Configuration.self, from: Data(Self.block.utf8))
        #expect(configuration.countryCode == "GB")
        #expect(configuration.pollingInterval == 120)
        #expect(configuration.discoveryDuration == .seconds(30))
        #expect(configuration.enableHumidity == false)
        #expect(configuration.enableFilterStatus == false)
        let devices = try #require(configuration.devices)
        #expect(devices.count == 3)
        let first = devices[0]
        #expect(first.serial == "ABC-AB-12345678")
        #expect(first.temperatureOffset == -2)
        #expect(first.humidityOffset == 5)
        #expect(first.enableOscillationWhenActivating == true)
        #expect(first.heatingServiceType == "both")
        #expect(devices[1].productType == "438")
        #expect(devices[1].credentials == "legacy")
        #expect(devices[2].serial == nil)

        let options = DeviceOptions(configuration.merged(first))
        #expect(options.temperatureOffset == -2)
        #expect(options.heatingServiceType == .both)
        #expect(options.activation == ActivationDefaults(autoMode: true, oscillation: true, nightMode: false))
        #expect(options.isAirQualityIgnored)
        // The device's own keys win over the platform's toggles…
        #expect(!options.isHumidityIgnored)
        #expect(options.isJetFocusEnabled)
        #expect(!options.isNightModeEnabled)
        // …which fill in the rest.
        let second = DeviceOptions(configuration.merged(devices[1]))
        #expect(second.isHumidityIgnored)
        #expect(!second.isJetFocusEnabled)
        #expect(second.isFilterStatusDisabled)
        #expect(!second.isContinuousMonitoringEnabled)
        #expect(second.heatingServiceType == .thermostat)
    }

    @Test func defaults() throws {
        let configuration = try JSONDecoder().decode(DysonPureCoolPlugin.Configuration.self, from: Data(#"{"platform":"DysonPureCool"}"#.utf8))
        #expect(configuration.devices == nil)
        #expect(configuration.discoveryDuration == .seconds(10))
        let options = DeviceOptions(configuration.merged(.init(serial: "A")))
        #expect(options == DeviceOptions())
        #expect(options.isNightModeEnabled && options.isJetFocusEnabled && !options.isContinuousMonitoringEnabled && !options.isFilterStatusDisabled)
        // Milliseconds, the Homebridge plugin's unit, are understood too.
        let milliseconds = try JSONDecoder().decode(DysonPureCoolPlugin.Configuration.self, from: Data(#"{"discoveryTimeout":5000}"#.utf8))
        #expect(milliseconds.discoveryDuration == .seconds(5))
    }
}
