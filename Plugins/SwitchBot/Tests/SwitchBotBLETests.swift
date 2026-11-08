import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Testing
import _CryptoExtras

@testable import Homeswift
@testable import HomeswiftSwitchBot

private func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

/// The bytes against docs/clean-room/SwitchBotBLE.md §11, byte for byte.
@Suite struct SwitchBotBLEProtocolTests {
    let mac = "C0FFEE123456"

    func decode(sd: String, mp: String? = nil) throws -> BLEReading {
        try #require(BLEAdvertisementDecoder.decode(serviceData: hex(sd), payload: mp.map(hex)))
    }

    @Test func metersDecode() throws {
        var reading = try decode(sd: "54 00 64 05 96 37")
        #expect(reading.model == .meter)
        #expect(reading.status["battery"] == 100 && reading.status["temperature"] == 22.5 && reading.status["humidity"] == 55)
        #expect(reading.status["displayFahrenheit"] == false)

        reading = try decode(sd: "54 00 64 03 05 B7")
        #expect(reading.status["temperature"]?.doubleValue.map { abs($0 - -5.3) < 0.001 } == true)
        #expect(reading.status["humidity"] == 55 && reading.status["displayFahrenheit"] == true)

        reading = try decode(sd: "77 00 64", mp: "C0FFEE123456 36 03 02 96 37 00")
        #expect(reading.model == .outdoorMeter && reading.mac == mac)
        #expect(reading.status["temperature"]?.doubleValue.map { abs($0 - 22.2) < 0.001 } == true)
        #expect(reading.status["humidity"] == 55 && reading.status["battery"] == 100)

        reading = try decode(sd: "35 00 50", mp: "C0FFEE123456 0B 2C 04 98 2D 00 00 03 E8")
        #expect(reading.model == .meterProCO2)
        #expect(reading.status["temperature"]?.doubleValue.map { abs($0 - 24.4) < 0.001 } == true)
        #expect(reading.status["humidity"] == 45 && reading.status["CO2"] == 1000 && reading.status["battery"] == 80)

        reading = try decode(sd: "54 00 64 00 00 00")
        #expect(reading.status["temperature"] == nil && reading.status["humidity"] == nil)
    }

    @Test func otherAdvertisementsDecode() throws {
        var reading = try decode(sd: "48 C0 5A")
        #expect(reading.model == .bot && reading.status["switchMode"] == true && reading.status["power"] == "off" && reading.status["battery"] == 90)
        reading = try decode(sd: "48 80 5A")
        #expect(reading.status["power"] == "on")

        reading = try decode(sd: "63 C0 5A 1E 51")
        #expect(reading.model == .curtain && reading.status["connectable"] == true && reading.status["calibrate"] == true)
        #expect(reading.status["battery"] == 90 && reading.status["moving"] == false && reading.status["slidePosition"] == 30)
        #expect(reading.status["lightLevel"] == 5 && reading.status["chainLength"] == 1)

        reading = try decode(sd: "64 40 5A 03 00 0A 00 3C 51")
        #expect(reading.model == .contact && reading.status["moveDetected"] == true && reading.status["battery"] == 90)
        #expect(reading.status["openState"] == "open" && reading.status["brightness"] == "bright")
        #expect(reading.status["secondsSinceMotion"] == 10 && reading.status["secondsSinceDoorChange"] == 60)
        #expect(reading.status["entranceCount"] == 1 && reading.status["exitCount"] == 1 && reading.status["buttonCount"] == 1)

        reading = try decode(sd: "67 00 64", mp: "C0FFEE123456 2A 80 04 3C 00 7B")
        #expect(reading.model == .plugMiniUS && reading.sequence == 42 && reading.status["power"] == "on")
        #expect(reading.status["syncUTCTime"] == true && reading.status["loadRaw"] == 123 && reading.status["overload"] == false)

        reading = try decode(sd: "24 00 00", mp: "C0FFEE123456 07 88 10 55 00 00")
        #expect(reading.model == .lockPro && reading.status["calibrate"] == true && reading.status["lockState"] == "unlocked")
        #expect(reading.status["doorState"] == "opened" && reading.status["battery"] == 85)

        reading = try decode(sd: "78 00 64", mp: "C0FFEE123456 01 01 32 50")
        #expect(reading.model == .blindTilt && reading.status["calibrate"] == true && reading.status["moving"] == false)
        #expect(reading.status["slidePosition"] == 50 && reading.status["lightLevelRaw"] == 5)

        reading = try decode(sd: "75 00 64", mp: "C0FFEE123456 09 B2 02")
        #expect(reading.model == .colorBulb && reading.sequence == 9 && reading.status["power"] == "on")
        #expect(reading.status["brightness"] == 50 && reading.status["mode"] == 2)

        // A code the spec does not use (the Hub 2) is ignored.
        #expect(BLEAdvertisementDecoder.decode(serviceData: hex("76 00 64"), payload: nil) == nil)
    }

    @Test func advertisementsMergeTheirTwoPackets() throws {
        let advertisement = BLEAdvertisement(
            identifier: "4F1C0D2E-0000-4000-8000-000000000001", manufacturerData: hex("69 09 C0FFEE123456 2A 80 04 3C 00 7B"),
            serviceData: ["fd3d": hex("67 00 64")], rssi: -60)
        let reading = try #require(BLEAdvertisementDecoder.decode(advertisement))
        #expect(reading.mac == mac && reading.model == .plugMiniUS)
        // Without SwitchBot's service data, nothing.
        #expect(BLEAdvertisementDecoder.decode(BLEAdvertisement(identifier: "x", manufacturerData: hex("69 09 C0FFEE123456"), rssi: -60)) == nil)
    }

    @Test func commandsAreTheSpecsBytes() throws {
        // The curtain to HomeKit 70 % open: the device's 30.
        var request = try BLEFrames.request(for: Command(command: "setPosition", parameter: "0,ff,30"), model: .curtain)
        #expect(request.frames == [hex("57 0F 45 01 05 FF 1E")])
        request = try BLEFrames.request(for: Command(command: "setPosition", parameter: "0,ff,50"), model: .curtain3)
        #expect(request.frames == [hex("57 0F 45 01 05 FF 32")])
        // Silent: low speed on a Curtain 3; a Curtain's goes to the cloud when it can.
        request = try BLEFrames.request(for: Command(command: "setPosition", parameter: "0,1,30"), model: .curtain3)
        #expect(request.frames == [hex("57 0F 45 01 05 01 1E")])
        #expect(throws: BLEUnsupported.self) {
            try BLEFrames.request(for: Command(command: "setPosition", parameter: "0,1,30"), model: .curtain, cloudAvailable: true)
        }
        #expect(try BLEFrames.request(for: Command(command: "setPosition", parameter: "0,1,30"), model: .curtain).frames == [hex("57 0F 45 01 05 FF 1E")])

        request = try BLEFrames.request(for: Command(command: "setBrightness", parameter: "100"), model: .colorBulb)
        #expect(request.frames == [hex("57 0F 47 01 14 64")])
        request = try BLEFrames.request(for: Command(command: "setColorTemperature", parameter: "2700"), model: .colorBulb)
        #expect(request.frames == [hex("57 0F 47 01 17 0A 8C")])
        request = try BLEFrames.request(for: Command(command: "setColor", parameter: "0:0:255"), model: .stripLight, brightness: 32)
        #expect(request.frames == [hex("57 0F 49 01 12 20 00 00 FF")])

        #expect(try BLEFrames.request(for: Command(command: "turnOn"), model: .plugMiniJP).frames == [hex("57 0F 50 01 01 80")])
        #expect(try BLEFrames.request(for: Command(command: "turnOff"), model: .plugMiniUS).frames == [hex("57 0F 50 01 01 00")])
        #expect(try BLEFrames.request(for: Command(command: "press"), model: .bot).frames == [hex("57 01 00")])

        // The Blind Tilt's two forms; (up, 40) is tilt 80.
        request = try BLEFrames.request(for: Command(command: "setPosition", parameter: "up;40"), model: .blindTilt)
        #expect(request.frames == [hex("57 0F 45 01 01 01 50"), hex("57 0F 45 01 05 FF 50")])
        #expect(try BLEFrames.request(for: Command(command: "fullyOpen"), model: .blindTilt).frames.first == hex("57 0F 45 01 01 01 32"))
        #expect(try BLEFrames.request(for: Command(command: "closeDown"), model: .blindTilt).frames.first == hex("57 0F 45 01 01 01 00"))
    }

    @Test func botPasswordsAreCRC32() throws {
        #expect(CRC32.checksum("1234".utf8) == 0x9BE3_E0A3)
        #expect(CRC32.checksum("A1b2".utf8) == 0xB859_3746)
        #expect(try BLEFrames.request(for: Command(command: "press"), model: .bot, password: "1234").frames == [hex("57 11 9B E3 E0 A3 00")])
        #expect(try BLEFrames.request(for: Command(command: "turnOn"), model: .bot, password: "A1b2").frames == [hex("57 11 B8 59 37 46 01")])
        #expect(validBotPassword("A1b2") && !validBotPassword("abc") && !validBotPassword("ab-c"))
    }

    @Test func bulbStateReply() throws {
        let request = try #require(BLEFrames.read(.colorBulb))
        #expect(request.frames == [hex("57 0F 48 01")])
        let status = try #require(BLEFrames.status(ofReply: hex("01 80 20 00 00 FF 00 00 FF FF 02"), to: request, model: .colorBulb))
        #expect(status["power"] == "on" && status["brightness"] == 32 && status["color"] == "0:0:255" && status["mode"] == 2)
        #expect(status["colorTemperature"] == nil)
    }

    @Test func lockFramesAreAESCTR() throws {
        let key = try #require(BLEKey(key: "000102030405060708090A0B0C0D0E0F", id: "01"))
        #expect(BLEFrames.encryptionInit(keyID: key.id) == hex("57 00 00 00 0F 21 03 01"))
        var cipher = try BLECipher(key: key, initReply: hex("01 00 00 00 F0 F1 F2 F3 F4 F5 F6 F7 F8 F9 FA FB FC FD FE FF"))
        #expect(cipher.mode == .ctr && cipher.iv == hex("F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF"))
        var block = hex("F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF")
        try AES.permute(&block, key: SymmetricKey(data: key.key))
        #expect(block == hex("66 A7 C7 E8 34 52 31 48 97 51 DE 07 33 16 AD AD"))

        #expect(try cipher.encrypt(BLEFrames.lock(0x00, pro: false)) == hex("57 01 F0 F1 69 E9 C6 E9 24 52"))
        #expect(try cipher.encrypt(BLEFrames.lock(0x80, pro: false)) == hex("57 01 F0 F1 69 E9 C6 E9 24 D2"))
        #expect(try cipher.encrypt(BLEFrames.lockInfo(pro: false)) == hex("57 01 F0 F1 69 E8 46 E9"))
        // CTR restarts at the IV for every message.
        cipher.advance()
        #expect(try cipher.encrypt(BLEFrames.lockInfo(pro: false)) == hex("57 01 F0 F1 69 E8 46 E9"))
        let reply = try cipher.decrypt(hex("01 00 00 00 E6 A7"))
        #expect(reply == hex("01 80 00"))
        let status = try #require(BLEFrames.status(ofReply: reply, to: BLEFrames.read(.lock)!, model: .lock))
        #expect(status["calibrate"] == true && status["lockState"] == "locked" && status["doorState"] == "closed")

        #expect(BLEFrames.lock(0x00, pro: true) == hex("57 0F 4E 01 01 00 00 00"))
        #expect(BLEFrames.lockInfo(pro: true) == hex("57 0F 4F 81 04"))
        #expect(throws: BLECipher.Rejected.self) { try BLECipher(key: key, initReply: hex("07 00")) }
        #expect(throws: BLECipher.Rejected.self) { try BLECipher(key: key, initReply: hex("01 00 00 00 F0 F1")) }
        #expect(BLEKey(key: "0001", id: "01") == nil && BLEKey(key: "000102030405060708090A0B0C0D0E0F", id: "1") == nil)
    }

    /// No GCM vector exists (§11.5): the session is checked against swift-crypto's AES-GCM, an independent implementation.
    @Test func gcmAgreesWithAESGCM() throws {
        let key = try #require(BLEKey(key: "000102030405060708090A0B0C0D0E0F", id: "02"))
        let iv = hex("A0 A1 A2 A3 A4 A5 A6 A7 A8 A9 AA FF")
        var cipher = try BLECipher(key: key, initReply: hex("01 00 01 00") + iv + hex("00 00 00 00"))
        #expect(cipher.mode == .gcm)
        let plain = BLEFrames.lock(0x80, pro: true)
        let sent = try cipher.encrypt(plain)
        let sealed = try AES.GCM.seal(Array(plain.dropFirst()), using: SymmetricKey(data: key.key), nonce: AES.GCM.Nonce(data: iv))
        #expect(sent == [0x57, 0x02] + Array(sealed.tag.prefix(2)) + Array(sealed.ciphertext))
        // A reply's payload is decrypted by the same keystream.
        #expect(try cipher.decrypt([0x01, 0, 0, 0] + Array(sealed.ciphertext)) == [0x01] + Array(plain.dropFirst()))
        cipher.advance()
        #expect(cipher.iv == hex("A0 A1 A2 A3 A4 A5 A6 A7 A8 A9 AB 00"))
    }

    @Test func bluetoothKeysMoveToSecretNamedSettings() throws {
        let block = try JSONValue(string: """
            {"platform":"SwitchBot","devices":[{"deviceId":"C0FFEE123456","configDeviceType":"Smart Lock","encryptionKey":"000102030405060708090A0B0C0D0E0F",
              "keyId":"01","connectionPreference":"auto","customBLEaddress":"C0:FF:EE:12:34:56","maxRetry":3}]}
            """)
        let canonical = SwitchBotPlugin.canonical(block, list: DeviceList(devices: [["deviceId": "C0FFEE123456", "deviceType": "Smart Lock"]]))
        let settings = try #require(canonical["_accessories"]?["C0FFEE123456-Smart Lock"])
        #expect(settings["encryptionKey"] == "000102030405060708090A0B0C0D0E0F" && settings["encryptionKeyId"] == "01" && settings["keyId"] == nil)
        #expect(settings["connectionType"] == "BLE/OpenAPI" && settings["customBLEaddress"] == "C0:FF:EE:12:34:56" && settings["maxRetry"] == 3)
        #expect(canonical["devices"] == nil)
    }

    @Test func statuses() {
        #expect(BLEStatus(code: 0x01).succeeded && BLEStatus(code: 0x06).succeeded)
        #expect(!BLEStatus(code: 0x05).succeeded && !BLEStatus(code: 0x07).succeeded && BLEStatus(code: 0x03).retryable)
        #expect(!BLEStatus(code: 0x09).retryable)
        #expect(bluetoothMAC("c0:ff:ee:12:34:56") == mac && bluetoothMAC("C0FFEE123456") == mac && bluetoothMAC("C0FFEE12345") == nil)
        #expect(colonMAC(mac) == "C0:FF:EE:12:34:56")
    }
}

/// The plugin on a bridge over a fake Bluetooth adapter.
@Suite(.timeLimit(.minutes(1)))
struct SwitchBotBLEPluginTests {
    let environment = TestEnvironment()

    static let key = "000102030405060708090A0B0C0D0E0F"

    /// A Smart Lock answering as §11.5's: the session init, its info (locked), and every command OK.
    static func lockResponder(_ written: [UInt8]) -> [UInt8]? {
        if written == hex("57 00 00 00 0F 21 03 01") { return hex("01 00 00 00 F0 F1 F2 F3 F4 F5 F6 F7 F8 F9 FA FB FC FD FE FF") }
        if written == hex("57 01 F0 F1 69 E8 46 E9") { return hex("01 00 00 00 E6 A7") }
        return [0x01, 0, 0, 0]
    }

    @Test func aCurtainMovesOverBluetooth() async throws {
        var settings = TestEnvironment.keys
        settings["options"] = ["devices": [["deviceId": "E2F6032048AB", "configDeviceType": "Curtain", "connectionType": "BLE"]]]
        environment.central.respond(to: "e2:f6:03:20:48:ab") { _ in [0x01] }
        let host = try await environment.start(settings)
        let id = "SwitchBot:E2F6032048AB-Curtain"
        #expect(await eventually { host.accessory(id) != nil })
        #expect(await eventually { environment.central.isScanning })
        try await host.accessory(id)!.service(.windowCovering)![.targetPosition]!.write(.int(70))
        #expect(await eventually { environment.central.writes(to: "e2:f6:03:20:48:ab").map(\.value).contains(hex("57 0F 45 01 05 FF 1E")) })
        let write = try #require(environment.central.writes(to: "e2:f6:03:20:48:ab").first)
        #expect(write.characteristic == BLEGATT.write && write.withResponse)
        #expect(environment.cloud.commands(to: "E2F6032048AB").isEmpty)
        // Its advertisement moves HomeKit's position: 30 closed is 70 open.
        environment.central.advertise(BLEAdvertisement(
            identifier: "e2:f6:03:20:48:ab", address: "E2:F6:03:20:48:AB", serviceData: ["fd3d": hex("63 C0 5A 1E 51")], rssi: -60))
        #expect(await eventually { host.accessory(id)?.service(.windowCovering)?[.currentPosition]?.value == .int(70) })
        #expect(host.accessory(id)?.service(.battery)?[.batteryLevel]?.value == .int(90))
        await host.stop()
    }

    @Test func sensorsOnBluetoothSpendNoRequests() async throws {
        var settings = TestEnvironment.keys
        settings["options"] = ["devices": [["deviceId": "C271111EC0AB", "configDeviceType": "Meter", "connectionType": "BLE"]]]
        let host = try await environment.start(settings)
        let id = "SwitchBot:C271111EC0AB-Meter"
        #expect(await eventually { host.accessory(id) != nil && environment.central.isScanning })
        // As macOS reports it: no address, the MAC in the manufacturer data.
        func advertise(_ triple: String) {
            environment.central.advertise(BLEAdvertisement(
                identifier: "6D1E3A90-0000-4000-8000-0000000000AB", manufacturerData: hex("69 09 C271111EC0AB 00 00 \(triple)"),
                serviceData: ["fd3d": hex("54 00 5F")], rssi: -70))
        }
        advertise("05 96 37")
        #expect(await eventually { host.accessory(id)?.service(.temperatureSensor)?[.currentTemperature]?.value.near(22.5) == true })
        #expect(host.accessory(id)?.service(.humiditySensor)?[.currentRelativeHumidity]?.value.near(55) == true)
        #expect(host.accessory(id)?.service(.battery)?[.batteryLevel]?.value == .int(95))
        advertise("01 97 30")
        #expect(await eventually { host.accessory(id)?.service(.temperatureSensor)?[.currentTemperature]?.value.near(23.1) == true })
        // Only the device list reached the cloud: no status of the meter.
        let paths = environment.cloud.state.withLockedValue { $0.requests.map(\.url.path) }
        #expect(paths == ["/v1.1/devices"])
        #expect(await environment.plugin?.budget.used == 1)
        #expect(environment.central.connectionCount == 0)
        await host.stop()
    }

    @Test func bluetoothFallsBackToTheCloud() async throws {
        var settings = TestEnvironment.keys
        settings["options"] = ["devices": [["deviceId": "D1A2B3C4D5E6", "configDeviceType": "Bot", "connectionType": "BLE/OpenAPI", "maxRetry": 2]]]
        environment.central.setUnreachable("d1:a2:b3:c4:d5:e6")
        let host = try await environment.start(settings)
        let id = "SwitchBot:D1A2B3C4D5E6-Bot"
        #expect(await eventually { host.accessory(id) != nil })
        try await host.accessory(id)!.service(.switch)![.on]!.write(.bool(true))
        #expect(await eventually { environment.cloud.commands(to: "D1A2B3C4D5E6") == [Command(command: "turnOn")] })
        // Once it is in range, Bluetooth again, and the cloud is not asked.
        environment.central.setUnreachable("d1:a2:b3:c4:d5:e6", false)
        environment.central.respond(to: "d1:a2:b3:c4:d5:e6") { _ in hex("01 FF 00") }
        try await host.accessory(id)!.service(.switch)![.on]!.write(.bool(false))
        #expect(await eventually { environment.central.writes(to: "d1:a2:b3:c4:d5:e6").map(\.value) == [hex("57 01 02")] })
        #expect(environment.cloud.commands(to: "D1A2B3C4D5E6") == [Command(command: "turnOn")])
        await host.stop()
    }

    @Test func bluetoothOnlyDevicesDoNotFallBack() async throws {
        var settings = TestEnvironment.keys
        settings["options"] = ["devices": [["deviceId": "D1A2B3C4D5E6", "configDeviceType": "Bot", "connectionType": "BLE", "maxRetry": 1]]]
        environment.central.setUnreachable("d1:a2:b3:c4:d5:e6")
        let host = try await environment.start(settings)
        let id = "SwitchBot:D1A2B3C4D5E6-Bot"
        #expect(await eventually { host.accessory(id) != nil })
        await #expect(throws: (any Error).self) { try await host.accessory(id)!.service(.switch)![.on]!.write(.bool(true)) }
        #expect(environment.cloud.commands(to: "D1A2B3C4D5E6").isEmpty)
        #expect(host.accessory(id)?.isUnreachable == true)
        await host.stop()
    }

    /// The parity's "done": a Bot, a Curtain 3, a Meter and a Lock with the cloud turned off (no token at all).
    @Test func devicesWorkWithoutTheCloud() async throws {
        let settings: [String: Any] = ["options": ["devices": [
            ["deviceId": "D1A2B3C4D5E6", "configDeviceType": "Bot", "configDeviceName": "Kettle", "botPassword": "1234"],
            ["deviceId": "E2F6032048AB", "configDeviceType": "Curtain3", "configDeviceName": "Window", "setOpenMode": "1"],
            ["deviceId": "C271111EC0AB", "configDeviceType": "Meter", "configDeviceName": "Office"],
            ["deviceId": "C0FFEE123456", "configDeviceType": "Smart Lock", "configDeviceName": "Front Door", "encryptionKey": Self.key, "keyId": "01"],
        ]]]
        environment.central.respond(to: "d1:a2:b3:c4:d5:e6") { _ in hex("01 FF 00") }
        environment.central.respond(to: "e2:f6:03:20:48:ab") { _ in [0x01] }
        environment.central.respond(to: "c0:ff:ee:12:34:56", Self.lockResponder)
        let host = try await environment.start(settings)
        let bot = "SwitchBot:D1A2B3C4D5E6-Bot", curtain = "SwitchBot:E2F6032048AB-Curtain3"
        let meter = "SwitchBot:C271111EC0AB-Meter", lock = "SwitchBot:C0FFEE123456-Smart Lock"
        #expect(await eventually { [bot, curtain, meter, lock].allSatisfy { host.accessory($0) != nil } })

        // The lock's info is read at start: locked.
        let mechanism = try #require(host.accessory(lock)?.service(.lockMechanism))
        #expect(await eventually { mechanism[.lockCurrentState]?.value == .int(1) })
        try await mechanism[.lockTargetState]!.write(.int(0))
        #expect(await eventually { environment.central.writes(to: "c0:ff:ee:12:34:56").map(\.value).contains(hex("57 01 F0 F1 69 E9 C6 E9 24 D2")) })
        let lockWrites = environment.central.writes(to: "c0:ff:ee:12:34:56").map(\.value)
        #expect(lockWrites.first == hex("57 00 00 00 0F 21 03 01"))

        try await host.accessory(bot)!.service(.switch)![.on]!.write(.bool(true))
        #expect(await eventually { environment.central.writes(to: "d1:a2:b3:c4:d5:e6").map(\.value) == [hex("57 11 9B E3 E0 A3 01")] })

        let covering = try #require(host.accessory(curtain)?.service(.windowCovering))
        // Opening to 60 % in silent mode (`setOpenMode` 1): low speed, the device's 40.
        try await covering[.targetPosition]!.write(.int(60))
        #expect(await eventually { environment.central.writes(to: "e2:f6:03:20:48:ab").map(\.value) == [hex("57 0F 45 01 05 01 28")] })

        environment.central.advertise(BLEAdvertisement(
            identifier: "c2:71:11:1e:c0:ab", address: "C2:71:11:1E:C0:AB", serviceData: ["fd3d": hex("54 00 64 05 96 37")], rssi: -60))
        #expect(await eventually { host.accessory(meter)?.service(.temperatureSensor)?[.currentTemperature]?.value.near(22.5) == true })

        #expect(environment.cloud.state.withLockedValue { $0.requests.isEmpty })
        await host.stop()
    }

    @Test func aLockWithoutItsKeyStaysOnTheCloud() async throws {
        environment.cloud.state.withLockedValue {
            $0.list = ["statusCode": 100, "body": ["deviceList": [["deviceId": "C0FFEE123456", "deviceName": "Door", "deviceType": "Smart Lock", "hubDeviceId": "FA7310762361"]]]]
        }
        var settings = TestEnvironment.keys
        settings["options"] = ["devices": [["deviceId": "C0FFEE123456", "configDeviceType": "Smart Lock", "connectionType": "BLE"]]]
        let host = try await environment.start(settings)
        let id = "SwitchBot:C0FFEE123456-Smart Lock"
        #expect(await eventually { host.accessory(id) != nil })
        try await host.accessory(id)!.service(.lockMechanism)![.lockTargetState]!.write(.int(0))
        #expect(await eventually { environment.cloud.commands(to: "C0FFEE123456") == [Command(command: "unlock")] })
        #expect(environment.central.connectionCount == 0)
        await host.stop()
    }

    /// A lock on Bluetooth without its key Needs Authorization; Setup refuses a key of the wrong form, keeps a good one in
    /// the vault, and the lock's commands are encrypted with it (§11.5).
    @Test func setupKeepsALocksKey() async throws {
        let settings: [String: Any] = ["options": ["devices": [
            ["deviceId": "C0FFEE123456", "configDeviceType": "Smart Lock", "configDeviceName": "Front Door"],
            ["deviceId": "C271111EC0AB", "configDeviceType": "Meter", "configDeviceName": "Office"],
        ]]]
        environment.central.respond(to: "c0:ff:ee:12:34:56", Self.lockResponder)
        let host = try await environment.start(settings)
        let deviceID = "C0FFEE123456-Smart Lock", id = "SwitchBot:\(deviceID)"
        #expect(await eventually { host.accessory(id) != nil })
        let plugin = try #require(environment.plugin)
        let found = try await plugin.discover()
        let lock = try #require(found.first { $0.deviceID == deviceID })
        #expect(lock.authorization == .apiKey && !lock.isSetUp)
        #expect(found.first { $0.deviceID == "C271111EC0AB-Meter" }?.authorization == AuthorizationMethod.none)
        #expect(environment.central.connectionCount == 0)

        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(lock))) else {
            Issue.record("no prompt")
            return
        }
        #expect(prompt.fields.map(\.key) == ["encryptionKeyId", "encryptionKey"] && prompt.fields.allSatisfy { $0.kind == .secret })
        #expect(prompt.values["name"] == "Front Door")
        for answers in [["encryptionKeyId": "1", "encryptionKey": Self.key], ["encryptionKeyId": "01", "encryptionKey": "0001"],
                        ["encryptionKeyId": "01", "encryptionKey": String(Self.key.dropLast()) + "G"]] {
            await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .device(lock), answers: answers)) }
        }
        guard case .done(let outcome) = try await plugin.authorize(
            SetupRequest(target: .device(lock), answers: ["encryptionKeyId": " 01 ", "encryptionKey": Self.key.lowercased()])) else {
            Issue.record("not done")
            return
        }
        #expect(outcome.settings["encryptionKey"] == .null && outcome.settings["encryptionKeyId"] == .null && outcome.settings["keyId"] == .null)
        let credentials = try #require(outcome.credentials)
        #expect(credentials == ["encryptionKey": .string(Self.key), "encryptionKeyId": "01"])

        // What the bridge does with it: the vault, then a reload.
        try await plugin.context.saveCredentials(credentials, for: deviceID)
        await host.stop()
        let restarted = try await environment.start(settings)
        let reloaded = try #require(environment.plugin)
        // The plugin's own accessory, not the one the cache restored.
        #expect(await eventually { await reloaded.entries[deviceID] != nil })
        #expect(try await reloaded.discover().first { $0.deviceID == deviceID }?.isSetUp == true)
        let mechanism = try #require(restarted.accessory(id)?.service(.lockMechanism))
        #expect(await eventually { mechanism[.lockCurrentState]?.value == .int(1) })
        try await mechanism[.lockTargetState]!.write(.int(0))
        #expect(await eventually { environment.central.writes(to: "c0:ff:ee:12:34:56").map(\.value).contains(hex("57 01 F0 F1 69 E9 C6 E9 24 D2")) })
        #expect(environment.central.writes(to: "c0:ff:ee:12:34:56").first?.value == hex("57 00 00 00 0F 21 03 01"))
        #expect(environment.cloud.state.withLockedValue { $0.requests.isEmpty })
        await restarted.stop()
    }

    /// A Bot that asks for its password Needs Authorization; Setup keeps a password of 4 letters or digits, which its
    /// presses carry (§11.3).
    @Test func setupKeepsABotsPassword() async throws {
        let settings: [String: Any] = ["options": ["devices": [["deviceId": "D1A2B3C4D5E6", "configDeviceType": "Bot", "configDeviceName": "Kettle", "maxRetry": 1]]]]
        environment.central.respond(to: "d1:a2:b3:c4:d5:e6") { written in written[1] == 0x11 ? hex("01 FF 00") : [0x07] }
        let host = try await environment.start(settings)
        let deviceID = "D1A2B3C4D5E6-Bot", id = "SwitchBot:\(deviceID)"
        #expect(await eventually { host.accessory(id) != nil })
        let plugin = try #require(environment.plugin)
        let bot = try #require(try await plugin.discover().first { $0.deviceID == deviceID })
        #expect(bot.authorization == .apiKey && bot.isSetUp)
        _ = try? await host.accessory(id)!.service(.switch)![.on]!.write(.bool(true))
        #expect(await eventually { environment.central.writes(to: "d1:a2:b3:c4:d5:e6").map(\.value) == [hex("57 01 01")] })
        #expect(await eventually { (try? await plugin.discover().first { $0.deviceID == deviceID }?.isSetUp) == false })

        guard case .ask(let prompt, let state) = try await plugin.authorize(SetupRequest(target: .device(bot))) else {
            Issue.record("no prompt")
            return
        }
        #expect(prompt.fields.map(\.key) == ["botPassword"] && prompt.fields.first?.kind == .secret)
        for password in ["12345", "12 4", "ab-c"] {
            await #expect(throws: SetupError.self) {
                try await plugin.authorize(SetupRequest(target: .device(bot), answers: ["botPassword": password], state: state))
            }
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(bot), answers: ["botPassword": "1234"], state: state)) else {
            Issue.record("not done")
            return
        }
        #expect(outcome.settings["botPassword"] == .null && outcome.credentials == ["botPassword": "1234"])
        try await plugin.context.saveCredentials(try #require(outcome.credentials), for: deviceID)
        await host.stop()
        let restarted = try await environment.start(settings)
        let reloaded = try #require(environment.plugin)
        // The plugin's own accessory, not the one the cache restored.
        #expect(await eventually { await reloaded.entries[deviceID] != nil })
        try await restarted.accessory(id)!.service(.switch)![.on]!.write(.bool(true))
        #expect(await eventually { environment.central.writes(to: "d1:a2:b3:c4:d5:e6").map(\.value).last == hex("57 11 9B E3 E0 A3 01") })
        #expect(try await reloaded.discover().first { $0.deviceID == deviceID }?.isSetUp == true)
        await restarted.stop()
    }
}
