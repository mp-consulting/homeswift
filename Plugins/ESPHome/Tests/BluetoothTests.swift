import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftESPHome

// MARK: Advertisements as proxies send them

/// An AD structure: its length, its type, its data.
func adStructure(_ type: UInt8, _ data: [UInt8]) -> [UInt8] {
    [UInt8(data.count + 1), type] + data
}

/// A raw advertisement: the flags, service data under a 16-bit UUID, manufacturer data, a name.
func rawAdvertisement(serviceData: (UInt16, [UInt8])? = nil, manufacturerData: (UInt16, [UInt8])? = nil, name: String? = nil) -> [UInt8] {
    var raw = adStructure(0x01, [0x06])
    if let (uuid, data) = serviceData { raw += adStructure(0x16, [UInt8(uuid & 0xFF), UInt8(uuid >> 8)] + data) }
    if let (company, data) = manufacturerData { raw += adStructure(0xFF, [UInt8(company & 0xFF), UInt8(company >> 8)] + data) }
    if let name { raw += adStructure(0x09, Array(name.utf8)) }
    return raw
}

func address(_ mac: String) -> UInt64 {
    mac.split(separator: ":").reduce(UInt64(0)) { $0 << 8 | UInt64($1, radix: 16)! }
}

/// BluetoothLERawAdvertisementsResponse with one advertisement per entry.
func rawAdvertisements(_ entries: [(mac: String, rssi: Int, raw: [UInt8])]) -> ESPHomeFrame {
    frame(BluetoothProxy.rawAdvertisementsResponse) { writer in
        for entry in entries {
            var item = ProtobufWriter()
            item.varint(1, address(entry.mac))
            let rssi = Int32(entry.rssi)
            item.varint(2, UInt64(UInt32(bitPattern: (rssi << 1) ^ (rssi >> 31))))
            item.bytes(4, entry.raw)
            writer.bytes(1, item.bytes)
        }
    }
}

private let thermometer = "A4:C1:38:00:00:01"
private let bthomeKey = Hex.bytes("231d39c1d7cc1ab1aee224cd096db932")!

/// A MiBeacon v5 frame as a LYWSD03MMC sends it: frame control 0x5858 (encrypted, MAC and objects included), product
/// 0x055B, the objects sealed with `key` as the format says.
func miBeacon(mac: String, counter: UInt8, objects: [UInt8], key: [UInt8], extended: [UInt8] = [0x01, 0x00, 0x00]) throws -> [UInt8] {
    let reversed = Array(BluetoothDecoders.octets(mac).reversed())
    let header: [UInt8] = [0x58, 0x58, 0x5B, 0x05, counter]
    let nonce = reversed + Array(header[2..<5]) + extended
    let sealed = try AESCCM.seal(objects, key: key, nonce: nonce, associatedData: [0x11], tagLength: 4)
    return header + reversed + sealed.ciphertext + extended + sealed.tag
}

/// Whether a characteristic shows `expected`, to its step (HomeKit's 0.1 °C, 1 %).
func shows(_ characteristic: Characteristic?, _ expected: Double, within step: Double = 0.1) -> Bool {
    guard let value = characteristic?.value.doubleValue else { return false }
    return abs(value - expected) <= step / 2 + 0.0001
}

/// A BTHome v2 frame encrypted as its specification says: the device information, the objects sealed, the counter, the MIC.
func sealedBTHome(mac: String, objects: [UInt8], counter: UInt32, key: [UInt8]) throws -> [UInt8] {
    let info: UInt8 = 0x41
    let count = withUnsafeBytes(of: counter.littleEndian, Array.init)
    let sealed = try AESCCM.seal(objects, key: key, nonce: BluetoothDecoders.octets(mac) + [0xD2, 0xFC, info] + count, tagLength: 4)
    return [info] + sealed.ciphertext + count + sealed.tag
}

struct BluetoothDecoderTests {
    /// RFC 3610's packet vector #1: AES-CCM with an 8-byte tag, 13-byte nonce and 8 bytes of associated data.
    @Test func ccmMatchesRFC3610() throws {
        let key = Hex.bytes("C0C1C2C3C4C5C6C7C8C9CACBCCCDCECF")!
        let nonce = Hex.bytes("00000003020100A0A1A2A3A4A5")!
        let aad = Hex.bytes("0001020304050607")!
        let plaintext = Hex.bytes("08090A0B0C0D0E0F101112131415161718191A1B1C1D1E")!
        let sealed = try AESCCM.seal(plaintext, key: key, nonce: nonce, associatedData: aad, tagLength: 8)
        #expect(sealed.ciphertext == Hex.bytes("588C979A61C663D2F066D0C2C0F989806D5F6B61DAC384")!)
        #expect(sealed.tag == Hex.bytes("17E8D12CFDF926E0")!)
        #expect(try AESCCM.open(sealed.ciphertext, tag: sealed.tag, key: key, nonce: nonce, associatedData: aad) == plaintext)
        var altered = sealed.ciphertext
        altered[0] ^= 1
        #expect(throws: AESCCM.Failure.authenticationFailed) { try AESCCM.open(altered, tag: sealed.tag, key: key, nonce: nonce, associatedData: aad) }
    }

    @Test func rawAdvertisementsAreParsed() throws {
        let raw = rawAdvertisement(serviceData: (0xFCD2, [0x40, 0x01, 0x5D]), manufacturerData: (0xEC88, [1, 2]), name: "Hall")
        let message = try #require(ProtobufMessage(rawAdvertisements([(thermometer, -71, raw)]).body))
        let advertisement = try #require(BluetoothProxy.advertisements(type: BluetoothProxy.rawAdvertisementsResponse, message: message)?.first)
        #expect(advertisement.mac == thermometer)
        #expect(advertisement.rssi == -71)
        #expect(advertisement.name == "Hall")
        #expect(advertisement.serviceData == [0xFCD2: [0x40, 0x01, 0x5D]])
        #expect(advertisement.manufacturerData == [0xEC88: [1, 2]])
        // A structure running past the end stops the reading.
        let truncated = BluetoothAdvertisement(mac: thermometer, rssi: 0, raw: adStructure(0x09, Array("Hall".utf8)) + [0x09, 0x16, 0xD2])
        #expect(truncated.name == "Hall" && truncated.serviceData.isEmpty)
    }

    /// The older BluetoothLEAdvertisementResponse, with its UUIDs as text.
    @Test func parsedAdvertisementsAreRead() throws {
        let body = frame(BluetoothProxy.advertisementResponse) {
            $0.varint(1, address(thermometer))
            $0.bytes(2, Array("GVH5075_0001".utf8))
            $0.varint(3, 141)  // -71
            var service = ProtobufWriter()
            service.string(1, "0000fcd2-0000-1000-8000-00805f9b34fb")
            service.bytes(3, [0x40, 0x01, 0x64])
            $0.bytes(5, service.bytes)
            var maker = ProtobufWriter()
            maker.string(1, "0xEC88")
            maker.bytes(3, [0x00, 0x03, 0x51, 0x9E, 0x64, 0x00])
            $0.bytes(6, maker.bytes)
        }
        let message = try #require(ProtobufMessage(body.body))
        let advertisement = try #require(BluetoothProxy.advertisements(type: body.type, message: message)?.first)
        #expect(advertisement.rssi == -71)
        #expect(advertisement.name == "GVH5075_0001")
        #expect(advertisement.serviceData[0xFCD2] == [0x40, 0x01, 0x64])
        #expect(advertisement.manufacturerData[0xEC88] == [0x00, 0x03, 0x51, 0x9E, 0x64, 0x00])
    }

    /// BTHome's own example: 25.06 °C and 50.55 %, with a battery of 93 %, a motion and a window.
    @Test func bthomeOpen() throws {
        let data: [UInt8] = [0x40, 0x00, 0x07, 0x01, 0x5D, 0x02, 0xCA, 0x09, 0x03, 0xBF, 0x13, 0x21, 0x01, 0x2D, 0x00]
        let advertisement = BluetoothAdvertisement(mac: thermometer, rssi: -60, serviceData: [0xFCD2: data])
        #expect(BluetoothDecoders.recognize(advertisement, name: nil) == BluetoothRecognition(format: .bthome, model: nil, encrypted: false))
        let readings = try #require(try BluetoothDecoders.decode(advertisement, as: .bthome, key: nil, name: nil)).readings
        #expect(readings.battery == 93)
        #expect(abs(readings.temperature! - 25.06) < 0.001)
        #expect(abs(readings.humidity! - 50.55) < 0.001)
        #expect(readings.motion == true)
        #expect(readings.open == false)
        // Negative temperatures, illuminance in hundredths, buttons in order.
        let more = BTHome.readings([0x02, 0x18, 0xFC, 0x05, 0x13, 0x8A, 0x14, 0x3A, 0x00, 0x3A, 0x02, 0x3A, 0x04])
        #expect(abs(more.temperature! - -10.0) < 0.001)
        #expect(abs(more.illuminance! - 13460.67) < 0.001)
        #expect(more.buttons == [nil, .double, .long])
        // An unknown object ends the reading, keeping what came before.
        #expect(BTHome.readings([0x01, 0x50, 0xEE, 0x01, 0x02]).battery == 80)
    }

    /// The BTHome encryption page's example: the same 25.06 °C and 50.55 % from MAC 54:48:E6:8F:80:A5.
    @Test func bthomeEncrypted() throws {
        let mac = "54:48:E6:8F:80:A5"
        let data = Hex.bytes("41a47266c95f730011223378237214")!
        let advertisement = BluetoothAdvertisement(mac: mac, rssi: -60, serviceData: [0xFCD2: data])
        #expect(BluetoothDecoders.recognize(advertisement, name: nil)?.encrypted == true)
        #expect(throws: BluetoothDecodeError.needsKey) { try BluetoothDecoders.decode(advertisement, as: .bthome, key: nil, name: nil) }
        #expect(throws: BluetoothDecodeError.wrongKey) {
            try BluetoothDecoders.decode(advertisement, as: .bthome, key: [UInt8](repeating: 1, count: 16), name: nil)
        }
        let frame = try #require(try BluetoothDecoders.decode(advertisement, as: .bthome, key: bthomeKey, name: nil))
        let readings = frame.readings
        #expect(abs(readings.temperature! - 25.06) < 0.001)
        #expect(abs(readings.humidity! - 50.55) < 0.001)
        #expect(frame.counter == 0x3322_1100)
        // Our own sealing gives the specification's bytes back.
        #expect(try sealedBTHome(mac: mac, objects: [0x02, 0xCA, 0x09, 0x03, 0xBF, 0x13], counter: 0x3322_1100, key: bthomeKey) == data)
        // An open frame from a sensor with a bindkey could come from anyone.
        let open = BluetoothAdvertisement(mac: mac, rssi: -60, serviceData: [0xFCD2: [0x40, 0x02, 0xCA, 0x09]])
        #expect(throws: BluetoothDecodeError.unencrypted) { try BluetoothDecoders.decode(open, as: .bthome, key: bthomeKey, name: nil) }
    }

    @Test func xiaomiMiBeacon() throws {
        let key = Hex.bytes("814aac74c4f17b6c1581e1ab87816b99")!
        // Temperature 21.3 °C, then humidity 48.7 %, then battery 87 %, as a LYWSD03MMC sends them one per frame.
        let frames = [
            try miBeacon(mac: thermometer, counter: 1, objects: [0x04, 0x10, 0x02, 0xD5, 0x00], key: key),
            try miBeacon(mac: thermometer, counter: 2, objects: [0x06, 0x10, 0x02, 0xE7, 0x01], key: key),
            try miBeacon(mac: thermometer, counter: 3, objects: [0x0A, 0x10, 0x01, 0x57], key: key),
        ]
        let first = BluetoothAdvertisement(mac: thermometer, rssi: -60, serviceData: [0xFE95: frames[0]])
        #expect(BluetoothDecoders.recognize(first, name: nil) == BluetoothRecognition(format: .xiaomi, model: "LYWSD03MMC", encrypted: true))
        #expect(throws: BluetoothDecodeError.needsKey) { try MiBeacon.decode(frames[0], mac: thermometer, key: nil) }
        #expect(throws: BluetoothDecodeError.wrongKey) { try MiBeacon.decode(frames[0], mac: thermometer, key: bthomeKey) }
        #expect(try MiBeacon.decode(frames[0], mac: thermometer, key: key).readings.temperature == 21.3)
        #expect(try MiBeacon.decode(frames[1], mac: thermometer, key: key).readings.humidity == 48.7)
        #expect(try MiBeacon.decode(frames[2], mac: thermometer, key: key).readings.battery == 87)
        #expect(try MiBeacon.decode(frames[0], mac: thermometer, key: key).counter == 0x0000_0101)
        // An open frame (an older sensor), temperature and humidity together.
        let open: [UInt8] = [0x50, 0x20, 0xAA, 0x01, 0x07] + BluetoothDecoders.octets(thermometer).reversed() + [0x0D, 0x10, 0x04, 0xF6, 0xFF, 0x02, 0x02]
        let readings = try MiBeacon.decode(open, mac: thermometer, key: nil).readings
        #expect(readings.temperature == -1.0)
        #expect(readings.humidity == 51.4)
        #expect(MiBeacon.Header(open, mac: thermometer)?.productID == 0x01AA)
    }

    @Test func goveeThermometers() throws {
        // H5075: 0x03519E is 217502, 21.7 °C and 50.2 %.
        let h5075 = BluetoothAdvertisement(mac: thermometer, rssi: -60, manufacturerData: [0xEC88: [0x00, 0x03, 0x51, 0x9E, 0x64, 0x00]])
        #expect(BluetoothDecoders.recognize(h5075, name: "GVH5075_0001") == BluetoothRecognition(format: .govee, model: "H5075", encrypted: false))
        #expect(Govee.decode(h5075, name: nil) == BluetoothReadings(temperature: 21.7, humidity: 50.2, battery: 100))
        // Below freezing: the top bit is the sign.
        let cold = BluetoothAdvertisement(mac: thermometer, rssi: -60, manufacturerData: [0xEC88: [0x00, 0x80, 0x62, 0x23, 0x37, 0x00]])
        #expect(Govee.decode(cold, name: nil) == BluetoothReadings(temperature: -2.5, humidity: 12.3, battery: 55))
        // H5074: hundredths, little-endian.
        let h5074 = BluetoothAdvertisement(mac: thermometer, rssi: -60, manufacturerData: [0xEC88: [0x00, 0xE5, 0x07, 0x3A, 0x14, 0x5A, 0x02]])
        #expect(Govee.decode(h5074, name: "Govee_H5074_0001") == BluetoothReadings(temperature: 20.21, humidity: 51.78, battery: 90))
        // The H5100 family and the H5179 use company id 1, told by their name.
        let h5100 = BluetoothAdvertisement(mac: thermometer, rssi: -60, manufacturerData: [0x0001: [0x01, 0x01, 0x03, 0x51, 0x9E, 0x64]])
        #expect(BluetoothDecoders.recognize(h5100, name: nil) == nil)
        #expect(BluetoothDecoders.recognize(h5100, name: "GVH5100_ABCD")?.model == "H5100")
        #expect(Govee.decode(h5100, name: "GVH5100_ABCD") == BluetoothReadings(temperature: 21.7, humidity: 50.2, battery: 100))
        let h5179 = BluetoothAdvertisement(mac: thermometer, rssi: -60, manufacturerData: [0x0001: [0x01, 0x01, 0x0A, 0x00, 0xE5, 0x07, 0x3A, 0x14, 0x5A]])
        #expect(Govee.decode(h5179, name: "GVH5179_1A2B") == BluetoothReadings(temperature: 20.21, humidity: 51.78, battery: 90))
    }
}

// MARK: The plugin, on fake proxies

struct BluetoothPluginTests {
    static let proxyFeatures = BluetoothProxy.passiveScanFeature | BluetoothProxy.rawAdvertisementsFeature

    func proxy(_ name: String, mac: String) -> FakeDevice {
        FakeDevice(.init(name: name, mac: mac, friendlyName: name, bluetoothFeatures: Self.proxyFeatures))
    }

    func subscribed(_ proxy: FakeDevice) -> Bool {
        proxy.commands.contains { $0.type == BluetoothProxy.subscribeRequest && ProtobufMessage($0.body)?.uint32(1) == 1 }
    }

    @Test func aSensorSetUpBecomesAnAccessoryHeardOnceThroughTwoProxies() async throws {
        let environment = ESPHomeTestEnvironment()
        environment.bluetoothTimeout = .milliseconds(400)
        let hall = proxy("hall", mac: "AC:BC:32:89:0E:01"), garage = proxy("garage", mac: "AC:BC:32:89:0E:02")
        environment.transport.add(hall, at: "hall.local")
        environment.transport.add(garage, at: "garage.local")
        let host = try await environment.start(settings: [
            "devices": [["host": "hall.local"], ["host": "garage.local"]],
            "_accessories": [thermometer: ["format": "bthome", "name": "Hallway"]],
        ])
        defer { Task { await host.stop() } }
        #expect(await eventually { subscribed(hall) && subscribed(garage) })

        let id = "esphome:\(thermometer)"
        let reading = rawAdvertisement(serviceData: (0xFCD2, [0x40, 0x00, 0x07, 0x01, 0x5D, 0x02, 0xCA, 0x09, 0x03, 0xBF, 0x13, 0x3A, 0x00]))
        hall.push(rawAdvertisements([(thermometer, -80, reading)]))
        garage.push(rawAdvertisements([(thermometer, -50, reading)]))
        #expect(await eventually { shows(host.accessory(id)?.service(.temperatureSensor)?.characteristic(.currentTemperature), 25.06) })
        let accessory = try #require(host.accessory(id))
        // An advertisement's readings land one after the other: each waited for.
        #expect(await eventually { shows(accessory.service(.humiditySensor)?.characteristic(.currentRelativeHumidity), 50.55, within: 1) })
        #expect(await eventually { accessory.service(.battery)?[.batteryLevel]?.value == .int(93) })
        #expect(accessory.service(.statelessProgrammableSwitch) != nil)
        #expect(accessory.information.characteristic(.serialNumber).value == .string("A4C138000001"))
        #expect(accessory.information.characteristic(.manufacturer).value == .string("BTHome"))
        // Its Accessory Settings' name, by its Device Id: the accessory id is `<platform>:<MAC>`.
        #expect(accessory.information.characteristic(.name).value == .string("Hallway"))
        let plugin = try #require(environment.plugin)
        // Heard twice, read once; the loudest proxy is the one it is nearest.
        #expect(await eventually { await plugin.bluetooth.heard[thermometer]?.proxy == "garage.local:6053" })
        #expect(await plugin.bluetooth.framesRead == 1)

        // Unheard for longer than the timeout: No Response, until it is heard again.
        #expect(await eventually { accessory.isUnavailable })
        let next = rawAdvertisement(serviceData: (0xFCD2, [0x40, 0x00, 0x08, 0x02, 0x1F, 0x0A]))
        hall.push(rawAdvertisements([(thermometer, -80, next)]))
        #expect(await eventually { !accessory.isUnavailable })
        // Its availability and its reading land one after the other.
        #expect(await eventually { shows(accessory.service(.temperatureSensor)?.characteristic(.currentTemperature), 25.91) })
    }

    @Test func setupFindsSensorsAndAsksForABindkey() async throws {
        let environment = ESPHomeTestEnvironment()
        let hall = proxy("hall", mac: "AC:BC:32:89:0E:01")
        environment.transport.add(hall, at: "hall.local")
        let host = try await environment.start(settings: ["devices": [["host": "hall.local"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { subscribed(hall) })

        let govee = "A4:C1:38:00:00:02", xiaomi = "A4:C1:38:00:00:03", stranger = "11:22:33:44:55:66"
        let key = Hex.bytes("814aac74c4f17b6c1581e1ab87816b99")!
        hall.push(rawAdvertisements([
            (govee, -60, rawAdvertisement(manufacturerData: (0xEC88, [0x00, 0x03, 0x51, 0x9E, 0x64, 0x00]), name: "GVH5075_0002")),
            (xiaomi, -60, rawAdvertisement(serviceData: (0xFE95, try miBeacon(mac: xiaomi, counter: 9, objects: [0x04, 0x10, 0x02, 0xD5, 0x00], key: key)))),
            (stranger, -60, rawAdvertisement(manufacturerData: (0x004C, [0x02, 0x15]))),
        ]))
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.bluetooth.heard.count == 2 })
        let devices = try await plugin.discover()
        let thermometer = try #require(devices.first { $0.deviceID == govee })
        #expect(thermometer.kind == "sensor" && thermometer.authorization == .none && thermometer.model == "H5075" && !thermometer.isSetUp)
        let sensor = try #require(devices.first { $0.deviceID == xiaomi })
        #expect(sensor.kind == "sensor" && sensor.authorization == .apiKey && sensor.name == "LYWSD03MMC 0003")
        #expect(!devices.contains { $0.deviceID == stranger })
        #expect(await plugin.deviceKind(of: xiaomi) == "sensor")
        #expect(await plugin.deviceKind(of: "AC:BC:32:89:0E:01") == "device")

        guard case .done(let open) = try await plugin.authorize(SetupRequest(target: .device(thermometer))) else { Issue.record("Govee asked"); return }
        #expect(open.settings["format"] == .string("govee") && open.credentials == nil)

        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(sensor))) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["encryptionKey"])
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .device(sensor), answers: ["encryptionKey": "not hex"], state: ["asked": true]))
        }
        await #expect(throws: SetupError("The sensor's advertisements do not open with that bindkey")) {
            try await plugin.authorize(SetupRequest(target: .device(sensor), answers: ["encryptionKey": "231d39c1d7cc1ab1aee224cd096db932"], state: ["asked": true]))
        }
        guard case .done(let outcome) = try await plugin.authorize(
            SetupRequest(target: .device(sensor), answers: ["encryptionKey": "814AAC74C4F17B6C1581E1AB87816B99"], state: ["asked": true])) else {
            Issue.record("the bindkey was refused"); return
        }
        #expect(outcome.settings["format"] == .string("xiaomi"))
        #expect(outcome.credentials?["encryptionKey"]?.stringValue == "814aac74c4f17b6c1581e1ab87816b99")
    }

    @Test func anEncryptedSensorReadsWithTheVaultsBindkey() async throws {
        let environment = ESPHomeTestEnvironment()
        let hall = proxy("hall", mac: "AC:BC:32:89:0E:01")
        environment.transport.add(hall, at: "hall.local")
        let mac = "54:48:E6:8F:80:A5"
        let first = try await environment.start(settings: [:])
        let context = try #require(first.context(platform: ESPHomePlugin.platform, name: "ESPHome"))
        try context.saveCredentials(ESPHomeCredentials(encryptionKey: "231d39c1d7cc1ab1aee224cd096db932"), for: mac)
        await first.stop()

        let host = try await environment.start(settings: ["devices": [["host": "hall.local"]], "_accessories": [mac: ["format": "bthome"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { subscribed(hall) })
        hall.push(rawAdvertisements([(mac, -60, rawAdvertisement(serviceData: (0xFCD2, Hex.bytes("41a47266c95f730011223378237214")!)))]))
        #expect(await eventually { shows(host.accessory("esphome:\(mac)")?.service(.temperatureSensor)?.characteristic(.currentTemperature), 25.06) })
        #expect(ESPHomePlugin.deviceID(ofAccessory: mac) == mac)

        // A later frame is read; an open one, and an older one replayed, are not.
        let plugin = try #require(environment.plugin)
        let later = try sealedBTHome(mac: mac, objects: [0x02, 0xB8, 0x0B], counter: 0x3322_1101, key: bthomeKey)
        hall.push(rawAdvertisements([(mac, -60, rawAdvertisement(serviceData: (0xFCD2, later)))]))
        let temperature = host.accessory("esphome:\(mac)")?.service(.temperatureSensor)?.characteristic(.currentTemperature)
        #expect(await eventually { shows(temperature, 30) })
        let older = try sealedBTHome(mac: mac, objects: [0x02, 0xE8, 0x03], counter: 0x3322_1000, key: bthomeKey)
        hall.push(rawAdvertisements([
            (mac, -60, rawAdvertisement(serviceData: (0xFCD2, [0x40, 0x02, 0xD0, 0x07]))),
            (mac, -60, rawAdvertisement(serviceData: (0xFCD2, older))),
        ]))
        #expect(await eventually { await plugin.bluetooth.framesRead == 4 })
        #expect(shows(temperature, 30))
    }

    /// Restored from the cache after a restart; with `bluetooth` off, No Response and no subscription; Excluded, never added.
    @Test func cachedSensorsBluetoothOffAndExcluded() async throws {
        let environment = ESPHomeTestEnvironment()
        let hall = proxy("hall", mac: "AC:BC:32:89:0E:01")
        environment.transport.add(hall, at: "hall.local")
        let excluded = "A4:C1:38:00:00:09"
        let settings: [String: Any] = [
            "devices": [["host": "hall.local"]],
            "_accessories": [thermometer: ["format": "bthome"], excluded: ["format": "bthome", "excluded": true]],
        ]
        let first = try await environment.start(settings: settings)
        #expect(await eventually { subscribed(hall) })
        let reading = rawAdvertisement(serviceData: (0xFCD2, [0x40, 0x02, 0xCA, 0x09]))
        hall.push(rawAdvertisements([(thermometer, -60, reading), (excluded, -60, reading)]))
        #expect(await eventually { first.accessory("esphome:\(thermometer)")?.service(.temperatureSensor) != nil })
        #expect(first.accessory("esphome:\(excluded)") == nil)
        await first.stop()

        var off = settings
        off["bluetooth"] = false
        let host = try await environment.start(settings: off)
        defer { Task { await host.stop() } }
        let restored = try #require(host.accessory("esphome:\(thermometer)"))
        #expect(shows(restored.service(.temperatureSensor)?.characteristic(.currentTemperature), 25.06))
        #expect(restored.isUnavailable)
        #expect(await eventually { hall.connections == 2 && hall.isConnected })
        // The first run's subscription only.
        #expect(hall.commands.filter { $0.type == BluetoothProxy.subscribeRequest }.count == 1)
    }

    @Test func aProxyWithoutRawAdvertisementsIsAskedForParsedOnes() async throws {
        let environment = ESPHomeTestEnvironment()
        let old = FakeDevice(.init(name: "old", mac: "AC:BC:32:89:0E:03", bluetoothFeatures: BluetoothProxy.passiveScanFeature))
        let plain = FakeDevice(.init(name: "plain", mac: "AC:BC:32:89:0E:04"))
        environment.transport.add(old, at: "old.local")
        environment.transport.add(plain, at: "plain.local")
        let host = try await environment.start(settings: ["devices": [["host": "old.local"], ["host": "plain.local"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { old.commands.contains { $0.type == BluetoothProxy.subscribeRequest } })
        #expect(old.commands.first { $0.type == BluetoothProxy.subscribeRequest }?.body == [])
        #expect(await eventually { plain.isConnected })
        #expect(!plain.commands.contains { $0.type == BluetoothProxy.subscribeRequest })
    }
}
