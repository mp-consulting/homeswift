import Foundation
import HomeswiftNetwork
import Testing

@testable import HomeswiftESPHome

private func bytes(_ text: String) -> [UInt8] {
    text.split(separator: " ").map { UInt8($0, radix: 16)! }
}

private func frames(_ input: [UInt8], chunk: Int) throws -> [ESPHomeFrame] {
    var framer = PlaintextFramer()
    var result: [ESPHomeFrame] = []
    var index = 0
    while index < input.count {
        framer.append(Array(input[index..<min(index + chunk, input.count)]))
        index += chunk
        while let frame = try framer.next() { result.append(frame) }
    }
    return result
}

struct PlaintextFramingTests {
    @Test func encodesTheSpecVectors() {
        #expect(PlaintextFramer.encode(ESPHomeFrame(type: 1, body: [])) == bytes("00 00 01"))
        #expect(PlaintextFramer.encode(ESPHomeFrame(type: 7, body: [])) == bytes("00 00 07"))
        #expect(PlaintextFramer.encode(ESPHomeFrame(type: 20, body: [])) == bytes("00 00 14"))
        #expect(PlaintextFramer.encode(ESPHomeRequest.hello()) == bytes("00 0f 01 0a 09 68 6f 6d 65 73 77 69 66 74 10 01 18 0a"))
        #expect(PlaintextFramer.encode(ESPHomeFrame(type: 1, body: [UInt8](repeating: 0x42, count: 192))) == bytes("00 c0 01 01") + [UInt8](repeating: 0x42, count: 192))
        #expect(PlaintextFramer.encode(ESPHomeFrame(type: 100, body: [0x42, 0x42, 0x42, 0x42])) == bytes("00 04 64 42 42 42 42"))
        #expect(PlaintextFramer.encode(ESPHomeFrame(type: 32768, body: [0x42])) == bytes("00 01 80 80 02 42"))
    }

    @Test func readsWholeSplitAndRunTogether() throws {
        let hello = bytes("00 17 02 08 01 10 0c 1a 08 32 30 32 35 2e 31 2e 30 22 07 6b 69 74 63 68 65 6e")
        let long = bytes("00 c0 01 01") + [UInt8](repeating: 0x42, count: 192)
        let stream = hello + long + bytes("00 01 80 80 02 42") + bytes("00 00 08")
        for chunk in [stream.count, 1, 3, 7] {
            let read = try frames(stream, chunk: chunk)
            #expect(read.map(\.type) == [2, 1, 32768, 8])
            #expect(read[1].body.count == 192)
        }
        let message = try #require(ProtobufMessage(try frames(hello, chunk: 100)[0].body))
        #expect(message.uint32(1) == 1 && message.uint32(2) == 12 && message.string(3) == "2025.1.0" && message.string(4) == "kitchen")
    }

    @Test func refusesWhatIsNotPlaintext() {
        var framer = PlaintextFramer()
        framer.append(bytes("01 00 00"))
        #expect(throws: ESPHomeError.requiresEncryption) { try framer.next() }
        framer = PlaintextFramer()
        framer.append(bytes("05 00 00"))
        #expect(throws: ESPHomeError.invalidMarker(5)) { try framer.next() }
        framer = PlaintextFramer()
        framer.append(bytes("00 80 80 80 80 01 01"))
        #expect(throws: ESPHomeError.self) { try framer.next() }
        framer = PlaintextFramer()
        framer.append(bytes("00 80 80 04 01"))
        #expect(throws: ESPHomeError.malformedFrame("length 65536")) { try framer.next() }
    }
}

struct NoiseFramingTests {
    @Test func serverHelloAndHandshakeAnswers() throws {
        var framer = NoiseFramer()
        framer.append(bytes("01 00 0d 01 73 65 72 76 69 63 65 74 65 73 74 00"))
        let hello = try ESPHomeNoise.ServerHello(try #require(try framer.next()))
        #expect(hello.name == "servicetest")
        #expect(hello.mac == nil)
        let withMAC = try ESPHomeNoise.ServerHello([0x01] + Array("kitchen".utf8) + [0] + Array("acbc32890ea9".utf8) + [0])
        #expect(withMAC.mac == "acbc32890ea9")
        #expect(throws: ESPHomeError.self) { try ESPHomeNoise.ServerHello([]) }
        #expect(throws: ESPHomeError.unknownNoiseProtocol(2)) { try ESPHomeNoise.ServerHello([0x02]) }

        framer.append(bytes("01 00 16 01") + Array("Handshake MAC failure".utf8))
        #expect(throws: ESPHomeError.invalidEncryptionKey) { try ESPHomeNoise.handshakeResult(try #require(try framer.next())) }
        #expect(throws: ESPHomeError.handshakeFailed("forced to fail")) { try ESPHomeNoise.handshakeResult([0x01] + Array("forced to fail".utf8)) }
        #expect(throws: ESPHomeError.self) { try ESPHomeNoise.handshakeResult([]) }

        framer.append(bytes("00 00 07"))
        #expect(throws: ESPHomeError.usesPlaintext) { try framer.next() }
    }

    @Test func keys() throws {
        #expect(try ESPHomeNoise.psk(fromBase64: "QRTIErOb/fcE9Ukd/5qA3RGYMn0Y+p06U58SCtOXvPc=").count == 32)
        #expect(try ESPHomeNoise.psk(fromBase64: " QRTIErOb/fcE9Ukd/5qA3RGYMn0Y+p06U58SCtOXvPc=\n").count == 32)
        #expect(throws: ESPHomeError.self) { try ESPHomeNoise.psk(fromBase64: "QRTIErOb/fcE9Ukd/5qA3RGYMn0Y+p06U58SCtOXvPc") }
        #expect(throws: ESPHomeError.malformedKey(length: 3)) { try ESPHomeNoise.psk(fromBase64: "AAAA") }
        #expect(ESPHomeNoise.prologue == bytes("4e 6f 69 73 65 41 50 49 49 6e 69 74 00 00"))
    }

    @Test func encryptedMessageLayout() throws {
        let frame = ESPHomeFrame(type: MessageType.pingRequest, body: [])
        #expect(ESPHomeNoise.plaintext(frame) == bytes("00 07 00 00"))
        var cipher = NoiseCipherState(key: [UInt8](repeating: 9, count: 32))
        let wire = NoiseFramer.encode(try cipher.encrypt(ESPHomeNoise.plaintext(frame)))
        #expect(Array(wire.prefix(3)) == bytes("01 00 14"))
        #expect(wire.count == 23)
        #expect(try ESPHomeNoise.frame(bytes("00 19 00 05 01 02")) == ESPHomeFrame(type: 25, body: [1, 2]))
        #expect(throws: ESPHomeError.self) { try ESPHomeNoise.frame([0, 1]) }
    }
}

struct MessageTests {
    @Test func entityAndCommandVectors() throws {
        let list = try frames(bytes("00 13 11 0a 05 72 65 6c 61 79 15 78 56 34 12 1a 05 52 65 6c 61 79"), chunk: 64)[0]
        let entity = EntityInfo(kind: try #require(EntityKind(listType: list.type)), message: try #require(ProtobufMessage(list.body)))
        #expect(entity.kind == .switch && entity.key == 0x1234_5678 && entity.name == "Relay" && entity.objectID == "relay")
        #expect(PlaintextFramer.encode(ESPHomeRequest.switch(key: 0x1234_5678, on: true)) == bytes("00 07 21 0d 78 56 34 12 10 01"))
        #expect(PlaintextFramer.encode(ESPHomeRequest.Light(key: 0x0102_0304, state: true, brightness: 0.5).frame)
            == bytes("00 10 20 0d 04 03 02 01 10 01 18 01 20 01 2d 00 00 00 3f"))
        let sensor = try frames(bytes("00 0a 19 0d 78 56 34 12 15 00 00 ac 41"), chunk: 64)[0]
        #expect(ProtobufMessage(sensor.body)?.float(2) == 21.5)
    }

    @Test func lightCapabilities() throws {
        let list = try frames(
            bytes("00 23 0f 0a 04 6c 61 6d 70 15 04 03 02 01 1a 04 4c 61 6d 70 5a 04 4e 6f 6e 65 5a 07 52 61 69 6e 62 6f 77 62 01 23"), chunk: 64)[0]
        let light = EntityInfo(kind: .light, message: try #require(ProtobufMessage(list.body)))
        #expect(light.name == "Lamp" && light.effects == ["None", "Rainbow"] && light.colorModes == [35])
        #expect(light.supportsRGB && light.supportsBrightness && !light.supportsColorTemperature)
        // Legacy flags, for firmware without color modes.
        var legacy = ProtobufWriter()
        legacy.bool(5, true)
        #expect(EntityInfo(kind: .light, message: try #require(ProtobufMessage(legacy.bytes))).colorModes == [3])
    }

    @Test func colors() {
        let red = Color.hueSaturation(red: 1, green: 0, blue: 0)
        #expect(red.hue == 0 && red.saturation == 100)
        #expect(Color.hueSaturation(red: 0, green: 0, blue: 1).hue == 240)
        let green = Color.rgb(hue: 120, saturation: 100)
        #expect(green.red == 0 && green.green == 1 && green.blue == 0)
        let white = Color.rgb(hue: 300, saturation: 0)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
    }

    @Test func climateModesAndUnits() {
        let modes = ClimateModes(supported: [0, 3])
        #expect(modes.validValues == [0, 1])
        #expect(modes.esphome(1) == 3 && modes.esphome(2) == nil)
        #expect(ClimateModes(supported: [0, 6]).esphome(3) == 6)
        #expect(Temperature.celsius(212, unit: 1) == 100)
        #expect(abs(Temperature.device(20, unit: 1) - 68) < 0.001)
        #expect(abs(Temperature.celsius(293.15, unit: 2) - 20) < 0.001)
        #expect(ESPHomeDevice.firmwareRevision("2025.2.0-dev") == "2025.2.0")
        #expect(ESPHomeDevice.firmwareRevision("dev") == "1.0.0")
    }

    @Test func addresses() {
        #expect(ESPHomePlugin.split("kitchen.local")! == ("kitchen.local", 6053))
        #expect(ESPHomePlugin.split("192.168.1.40:9001")! == ("192.168.1.40", 9001))
        #expect(ESPHomePlugin.split("[fe80::1]:9001")! == ("fe80::1", 9001))
        #expect(ESPHomePlugin.address("fe80::1", 6053) == "[fe80::1]")
        #expect(ESPHomePlugin.deviceID(ofAccessory: "Temperature@AC:BC:32:89:0E:A9") == "AC:BC:32:89:0E:A9")
        #expect(ESPHomePlugin.deviceID(ofAccessory: "Temperature@AC:BC:32:89:0E:A9#1f") == "AC:BC:32:89:0E:A9")
        #expect(ESPHomePlugin.deviceID(ofAccessory: "Temperature") == nil)
    }
}
