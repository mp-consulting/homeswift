import Foundation
import Testing

@testable import Homeswift

struct TLV8Tests {
    @Test func roundTripsAndFragmentsLongValues() throws {
        let long = Data((0..<600).map { UInt8($0 % 251) })
        let tlv = TLV8([(.state, Data([1])), (.publicKey, long), (.salt, Data())])
        let encoded = tlv.encoded()
        // 600 bytes split as 255 + 255 + 90, each with its own two-byte header.
        #expect(encoded.count == 3 + (2 * 3 + 600) + 2)
        let decoded = try TLV8(decoding: encoded)
        #expect(decoded.byte(.state) == 1)
        #expect(decoded[.publicKey] == long)
        #expect(decoded[.salt] == Data())
    }

    @Test func splitsGroupsOnSeparators() throws {
        var tlv = TLV8()
        tlv.append(.identifier, Data("a".utf8))
        tlv.append(.separator, Data())
        tlv.append(.identifier, Data("b".utf8))
        let groups = try TLV8(decoding: tlv.encoded()).groups
        #expect(groups.map { $0[.identifier] } == [Data("a".utf8), Data("b".utf8)])
    }
}

struct SRPTests {
    /// Values produced by fast-srp-hap (the SRP used by HAP-NodeJS) with the same fixed inputs.
    @Test func matchesFastSRPHap() throws {
        let salt = Data(repeating: 7, count: 16)
        let server = SRP.Server(password: "031-45-154", salt: salt, privateKey: Data(repeating: 9, count: 32))
        let client = SRP.Client(privateKey: Data(repeating: 3, count: 32))
        #expect(server.publicKey.hex.hasPrefix("2c7ae7c3c58281a2"))
        #expect(client.publicKey.hex.hasPrefix("ba8925dbc3a76083"))

        let (clientKey, M1, expectedM2) = client.proof(salt: salt, serverPublicKey: server.publicKey, password: "031-45-154")
        #expect(M1.hex == "3cf8481972f7700660c8a3d560a0ad3e94b76e1bfd13ee1b72adaba34e45898b91eb45196141a47fbea44b7c11f20dc27d0776277abd3c04dfe99ba13c18c9eb")
        let result = try #require(server.verify(clientPublicKey: client.publicKey, clientProof: M1))
        #expect(result.sessionKey == clientKey)
        #expect(result.sessionKey.hex == "3ee0710903790f1d55fa5b7d10d2e6e5241a5e6d9a43cb6481f73b1bc8a9720c150f9ca17b9d7b7a868fd5de226bde0039a9a79d8c346987fb5e2451b06c26c4")
        #expect(result.proof == expectedM2)
        #expect(result.proof.hex == "921cb238e3f86d5973a4ca54d7247a8e9c79d233b402af0745b81a8720fef67639657f1d9bfb694d4c8dc28192087bfeea5607ea54bea9ea9e95e5ba1fea2b0b")
    }

    @Test func rejectsWrongCode() {
        let server = SRP.Server(password: "031-45-154")
        let client = SRP.Client()
        let (_, M1, _) = client.proof(salt: server.salt, serverPublicKey: server.publicKey, password: "031-45-155")
        #expect(server.verify(clientPublicKey: client.publicKey, clientProof: M1) == nil)
    }
}

struct SetupTests {
    @Test func validatesCodes() {
        #expect(SetupCode("031-45-154")?.rawValue == "031-45-154")
        #expect(SetupCode("03145154")?.rawValue == "031-45-154")
        #expect(SetupCode("005-21-956")?.description == "0052-1956")
        #expect(SetupCode("0052-1956")?.rawValue == "005-21-956")
        #expect(SetupCode("111-11-111") == nil)
        #expect(SetupCode("123-45-678") == nil)
        #expect(SetupCode("12-345-678x") == nil)
    }

    /// Same encoding as HAP-NodeJS's `Accessory.setupURI()`.
    @Test func buildsSetupURI() {
        #expect(makeSetupURI(code: SetupCode("031-45-154")!, category: .bridge, setupID: "ABCD") == "X-HM://0023ISYWYABCD")
    }

    @Test func shortensAppleUUIDs() {
        #expect(HAPUUID(0x25).shortForm == "25")
        #expect(HAPUUID("0000003E-0000-1000-8000-0026BB765291").shortForm == "3E")
        #expect(HAPUUID("D2B3E3C4-1111-2222-3333-444455556666").shortForm == "D2B3E3C4-1111-2222-3333-444455556666")
    }

    @Test func coercesValues() {
        #expect(CharacteristicType.on.coerce(.int(1)) == .bool(true))
        #expect(CharacteristicType.brightness.coerce(.double(42.4)) == .int(42))
        #expect(CharacteristicType.brightness.coerce(.int(101)) == nil)
        #expect(CharacteristicType.lockTargetState.coerce(.int(2)) == nil)
    }

    /// The spec's bounds, as HAP-NodeJS 2.2.4 checks them: strings 64 bytes unless `maxLen` says more, never past
    /// 256; data 2 MiB of base64 unless `maxDataLen` says otherwise; numbers on the grid of `minStep`.
    @Test func keepsValuesWithinTheSpecsBounds() {
        let name = CharacteristicType.name
        #expect(name.coerce(.string(String(repeating: "a", count: 64))) != nil)
        #expect(name.coerce(.string(String(repeating: "a", count: 65))) == nil)
        var long = CharacteristicType(name: "Long", uuid: HAPUUID("00000001-0000-1000-8000-0026BB765291"), format: .string, permissions: [.pairedRead], maxLength: 1000)
        #expect(long.coerce(.string(String(repeating: "a", count: 256))) != nil)
        #expect(long.coerce(.string(String(repeating: "a", count: 257))) == nil)
        #expect(CharacteristicJSON(describing: Characteristic(long), includeValue: false, includeMeta: true).maxLen == 256)

        long.format = .data
        #expect(long.coerce(.string(String(repeating: "A", count: CharacteristicType.defaultMaxDataLength))) != nil)
        #expect(long.coerce(.string(String(repeating: "A", count: CharacteristicType.defaultMaxDataLength + 1))) == nil)
        long.maxDataLength = 8
        #expect(long.coerce(.string("AAAAAAAA")) != nil && long.coerce(.string("AAAAAAAAA")) == nil)
        #expect(CharacteristicJSON(describing: Characteristic(long), includeValue: false, includeMeta: true).maxDataLen == 8)

        // The step from the minimum, without binary noise; on an integer too.
        #expect(CharacteristicType.currentTemperature.coerce(.double(21.43)) == .double(21.4))
        #expect(CharacteristicType.currentTemperature.with(minStep: 0.5).coerce(.double(21.3)) == .double(21.5))
        #expect(CharacteristicType.targetTemperature.coerce(.double(20.26)) == .double(20.3))
        #expect(CharacteristicType.rotationSpeed.with(minStep: 25).coerce(.double(60)) == .double(50))
        #expect(CharacteristicType.brightness.with(minStep: 10).coerce(.int(47)) == .int(50))
    }

    /// HAP-NodeJS's setProps on a required characteristic: the extra takes its place, in its place.
    @Test func extraReplacesARequiredCharacteristic() {
        let thermostat = Service(.thermostat, extra: [Characteristic(.targetTemperature.with(minValue: 30, maxValue: 60))])
        let targets = thermostat.characteristics.filter { $0.type.uuid == CharacteristicType.targetTemperature.uuid }
        #expect(targets.count == 1)
        #expect(targets.first?.type.minValue == 30 && targets.first?.type.maxValue == 60)
        #expect(thermostat.characteristics.map(\.type.uuid) == Service(.thermostat).characteristics.map(\.type.uuid))
    }

    @Test func optionalReplacesARequiredCharacteristic() {
        let thermostat = Service(.thermostat, optional: [.targetTemperature.with(minValue: 30), .currentRelativeHumidity])
        let targets = thermostat.characteristics.filter { $0.type.uuid == CharacteristicType.targetTemperature.uuid }
        #expect(targets.count == 1)
        #expect(targets.first?.type.minValue == 30)
        #expect(thermostat[.currentRelativeHumidity] != nil)
        #expect(
            thermostat.characteristics.map(\.type.uuid)
                == Service(.thermostat).characteristics.map(\.type.uuid) + [CharacteristicType.currentRelativeHumidity.uuid])
        // The same type again changes nothing, the Name keeps its value.
        let named = Service(.lightbulb, name: "Desk", optional: [.name])
        #expect(named[.name]?.value == .string("Desk"))
    }

    @Test func takesValuesFromACachedAccessory() {
        func make(_ name: String, minimum: Double) -> Accessory {
            Accessory(
                id: "a", name: name, firmwareRevision: name == "New" ? "2.0" : "1.0",
                services: [
                    Service(.lightbulb, name: name, subtype: "one", optional: [.brightness.with(minValue: minimum), .configuredName]),
                    Service(.lightbulb, subtype: "two"),
                ])
        }
        let cached = make("Old", minimum: 0)
        cached.services[1][.on]?.value = .bool(true)
        cached.services[2][.on]?.value = .bool(true)
        cached.services[1][.brightness]?.value = .int(5)
        let rebuilt = make("New", minimum: 10)
        rebuilt.services[1][.configuredName]?.value = .string("Kept")
        rebuilt.takeValues(from: cached)
        #expect(rebuilt.services[1][.on]?.value == .bool(true))
        #expect(rebuilt.services[2][.on]?.value == .bool(true))
        #expect(rebuilt.services[1][.brightness]?.value == .int(10))  // 5 no longer fits
        #expect(rebuilt.services[1][.name]?.value == .string("New"))
        #expect(rebuilt.services[1][.configuredName]?.value == .string("Kept"))  // the cached one was empty
        #expect(rebuilt.information[.firmwareRevision]?.value == .string("2.0"))
    }
}

struct SecureSessionTests {
    @Test func framesAcrossTheSizeLimit() throws {
        let secret = Data(repeating: 1, count: 32)
        var accessory = SecureSession(sharedSecret: secret, isAccessory: true)
        var controller = SecureSession(sharedSecret: secret, isAccessory: false)
        let message = Data((0..<2500).map { UInt8($0 % 256) })
        var wire = try accessory.encrypt(message)
        #expect(wire.count == 2500 + 3 * 18)
        // Deliver in two pieces to exercise partial frames.
        var partial = wire.prefix(1000)
        var received = try controller.decrypt(&partial)
        wire = partial + wire.dropFirst(1000)
        received += try controller.decrypt(&wire)
        #expect(received == message)
        #expect(wire.isEmpty)
    }
}

struct JSONWriterTests {
    @Test func writesWhatJSONSerializationReads() throws {
        var entry = CharacteristicJSON(aid: 2, iid: 9, value: .string("a \"quoted\"\\ line\n\u{1}/é"))
        entry.perms = ["pr", "ev"]
        entry.minValue = 0
        entry.minStep = 0.1
        entry.validValues = [0, 1, 3]
        entry.ev = false
        let response = HTTPResponse.json(207, CharacteristicsJSON(characteristics: [
            entry, CharacteristicJSON(aid: 3, iid: 4, value: .double(-21.25), status: .resourceBusy),
            CharacteristicJSON(iid: 5, value: .null),
        ]))
        let text = String(decoding: response.body, as: UTF8.self)
        #expect(text.hasPrefix(#"{"characteristics":[{"aid":2,"iid":9,"perms":["pr","ev"],"value":"a \"quoted\"\\ line\n\u0001/é","minValue":0,"minStep":0.1,"#))

        let parsed = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let items = try #require(parsed["characteristics"] as? [[String: Any]])
        #expect(items.count == 3)
        #expect(items[0]["value"] as? String == "a \"quoted\"\\ line\n\u{1}/é")
        #expect(items[0]["valid-values"] as? [Int] == [0, 1, 3])
        #expect(items[0]["ev"] as? Bool == false)
        #expect(items[1]["value"] as? Double == -21.25)
        #expect(items[1]["status"] as? Int == HAPStatus.resourceBusy.rawValue)
        #expect(items[2]["value"] is NSNull)
        #expect(items[2]["aid"] == nil)
    }

    @Test func writesStatusAndIntegers() {
        let body = HTTPResponse.hapStatus(470, .insufficientPrivileges).body
        #expect(String(decoding: body, as: UTF8.self) == #"{"status":-70401}"#)
        var json = JSONWriter()
        json.array { json in
            for value in [0, 7, -3, Int.max, Int.min] { json.value(value) }
            json.value(1e20)
            json.value(Double.nan)
        }
        #expect(String(decoding: json.bytes, as: UTF8.self) == "[0,7,-3,\(Int.max),\(Int.min),1e+20,null]")
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
