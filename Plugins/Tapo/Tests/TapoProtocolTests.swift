import Crypto
import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import Testing
import _CryptoExtras

@testable import HomeswiftTapo

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The vectors of docs/clean-room/Tapo.md, 7.1 and 7.2.
@Suite struct TapoProtocolTests {
    let localSeed = Data((0..<16).map(UInt8.init))
    let remoteSeed = Data((16..<32).map(UInt8.init))
    var authHash: Data { KLAP.authHash(username: "user@example.com", password: "password123") }

    @Test func klapHashes() {
        #expect(authHash.hex == "35365bf4467b1b0fa6569d60a5fa0b11ebc3010dc9b6c9018da3c00d9969e404")
        #expect(KLAP.serverHash(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash).hex == "21f27ccace7cf984d6ed402aa09db27fb98f16573f83e0e71b37e84b8f35d3d5")
        #expect(KLAP.clientHash(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash).hex == "5f307e5b07fa7157e8bf0d9ec5cb2e9fa08c8aca433df2d199b5962ed9859ce6")
    }

    @Test func klapSessionKeys() {
        let session = KLAP.Session(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash)
        #expect(session.key.withUnsafeBytes { Data($0) }.hex == "7ca1d32e916ce872becb13f83af7daa1")
        #expect(session.ivPrefix.hex == "491492ea81c693c9fde7cb05")
        #expect(session.sequence == 1_807_901_053)
        #expect(session.signatureKey.count == 28)
    }

    @Test func klapFirstRequest() throws {
        var session = KLAP.Session(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash)
        let plaintext = Data(#"{"method": "get_device_info","requestTimeMils": 1700000000000000};"#.utf8)
        #expect(plaintext.count == 66)
        let (sequence, body) = try session.encrypt(plaintext)
        #expect(sequence == 1_807_901_054)
        #expect(session.iv(sequence: sequence).hex == "491492ea81c693c9fde7cb056bc2617e")
        #expect(body.count == 112)
        #expect(body.prefix(32).hex == "f016df10e98536e688bc649677dac545c5ff375cbc875dd4f909d158f117c3c6")
        #expect(body.dropFirst(32).hex == "e5fb36aed11b86f799c10cb5d55d2d145248f2438075184783487c9fdd8acc4c488c1c30fce28e17791187cb962e424c22b678d2649afc6682442f4b2e5a1eb8e395ec9dd641276d71d7f756428627d3")
        // The device answers under the same IV, behind a signature the client skips.
        #expect(try session.decrypt(body, sequence: sequence) == plaintext)
    }

    @Test func sequenceWrapsWithinSigned32Bits() {
        #expect(Int32(bigEndianBytes: Data(hex: "6bc2617d")) == 1_807_901_053)
        #expect(Int32(bigEndianBytes: Data(hex: "ffffffff")) == -1)
        #expect(Int32(-2).bigEndianBytes.hex == "fffffffe")
        #expect(Int32.max &+ 1 == Int32.min)
    }

    @Test func passthroughLogin() {
        let parameters = SecurePassthrough.loginParameters(username: "user@example.com", password: "password123")
        #expect(parameters["username"] == "NjNhNzEwNTY5MjYxYTI0YjM3NjYyNzViNzAwMGNlOGQ3YjMyZTJmNw==")
        #expect(parameters["password"] == "cGFzc3dvcmQxMjM=")
    }

    /// The device encrypts 32 known bytes with the client's public key; the client takes the first 16 as the key and the
    /// next 16 as the IV.
    @Test func passthroughHandshakeKey() throws {
        let keys = try SecurePassthrough.KeyPair()
        #expect(keys.publicKeyPEM.hasPrefix("-----BEGIN PUBLIC KEY-----"))
        let publicKey = try _RSA.Encryption.PublicKey(unsafePEMRepresentation: keys.publicKeyPEM)
        let secret = Data((0..<32).map(UInt8.init))
        let cipher = try keys.cipher(fromHandshakeKey: try publicKey.encrypt(secret, padding: ._WEAK_AND_INSECURE_PKCS_V1_5).base64EncodedString())
        #expect(cipher.key == secret.prefix(16))
        #expect(cipher.iv == secret.suffix(16))
        let message = Data(#"{"method":"get_device_info"}"#.utf8)
        #expect(try cipher.decrypt(try cipher.encrypt(message)) == message)
    }

    @Test func lenientErrorCodes() throws {
        #expect(TapoMessage.errorCode(of: try TapoMessage.parse(Data(#"{"error_code":-0301}"#.utf8))) == -301)
        #expect(TapoMessage.errorCode(of: try TapoMessage.parse(Data(#"{"error_code":0x,"result":{"a":1}}"#.utf8))) == 0)
        #expect(try TapoMessage.parse(Data(#"{"error_code": 00 ,"result":{"a":1}}"#.utf8))["result"]?["a"] == 1)
        #expect(TapoMessage.errorCode(of: ["error_code": "0"]) == 0)
        #expect(TapoMessage.errorCode(of: ["error_code": 0]) == 0)
        #expect(throws: TapoError.device(-1501)) { try TapoMessage.result(of: ["error_code": -1501]) }
        #expect(TapoError.device(-1501).description == "error -1501 (invalid request or credentials)")
    }

    @Test func requestShape() throws {
        let request = try JSONValue(data: TapoMessage.request("set_device_info", params: ["device_on": true], terminalUUID: "UUID", now: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(request["method"] == "set_device_info")
        #expect(request["params"]?["device_on"] == true)
        #expect(request["terminalUUID"] == "UUID")
        #expect(request["requestTimeMils"] == 1_700_000_000_000_000)
        #expect(try JSONValue(data: TapoMessage.request("get_device_info"))["params"] == nil)
    }

    @Test func cookieAndTimeout() {
        let response = HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Set-Cookie", "TP_SESSIONID=0A1B;TIMEOUT=86400")])
        let cookie = TapoConnection.cookie(of: response)
        #expect(cookie?.cookie == "TP_SESSIONID=0A1B")
        #expect(cookie?.timeout == 86400)
        #expect(TapoConnection.cookie(of: HomeswiftNetwork.HTTPResponse(status: 200)) == nil)
    }

    @Test func colourTemperatureConversions() {
        #expect([140, 154, 200, 370, 400].map(TapoConversion.kelvin(mireds:)) == [6500, 6493, 5000, 2702, 2500])
        #expect([2500, 2700, 4000, 6500, 0].map(TapoConversion.mireds(kelvin:)) == [400, 370, 250, 154, 400])
    }

    @Test func energyReadings() throws {
        let plug = try #require(TapoEnergy(plugUsage: ["today_runtime": 120, "today_energy": 250, "current_power": 15300]))
        #expect(plug == TapoEnergy(watts: 15.3, todayKWh: 0.25))
        let usage: JSONValue = ["time_usage": ["today": 120], "power_usage": ["today": 18]]
        #expect(TapoEnergy(bulbUsage: usage, isOn: true) == TapoEnergy(watts: 9, todayKWh: 0.018))
        #expect(TapoEnergy(bulbUsage: usage, isOn: false)?.watts == 0)
        #expect(TapoEnergy(bulbUsage: ["time_usage": ["today": 0], "power_usage": ["today": 18]], isOn: true)?.watts == 0)
    }

    @Test func kinds() {
        #expect(["plug", "PLUG", nil, "toaster"].map(TapoKind.init(type:)) == [.plug, .plug, .plug, .plug])
        #expect(TapoKind(type: "PowerPlug") == .powerPlug)
        #expect(TapoKind(type: "light") == .light)
        #expect(TapoKind(type: "WhiteLight") == .whiteLight)
        #expect(TapoKind(type: "colorlight") == .colorLight)
        #expect(TapoKind.allCases.map(\.model) == ["Tapo P100", "Tapo P110", "Tapo L510E", "Tapo L520E", "Tapo L530"])
    }

    @Test func writesMerge() {
        var write = TapoWrite(hue: 120)
        write.merge(TapoWrite(saturation: 50))
        #expect(write == TapoWrite(hue: 120, saturation: 50))
        write.merge(TapoWrite(mireds: 300))
        #expect(write == TapoWrite(mireds: 300))
        write.merge(TapoWrite(on: true))
        write.merge(TapoWrite(brightness: 40))
        #expect(write == TapoWrite(on: true, brightness: 40, mireds: 300))
    }

    @Test func firmwareRevision() {
        var state = TapoState()
        state.firmware = "1.2.1 Build 20200616 Rel. 31218"
        #expect(state.firmwareRevision == "1.2.1")
        state.firmware = "beta"
        #expect(state.firmwareRevision == nil)
    }

    /// Two requests at once go one after the other, behind one handshake.
    @Test func concurrentRequestsShareOneHandshake() async throws {
        let network = FakeTapoNetwork()
        let credentials = TapoCredentials(username: "user@example.com", password: "password123")
        let connection = TapoConnection(host: "192.168.1.21", http: network, requestTimeout: .seconds(1), logger: testLogger) { credentials }
        async let first = connection.call("get_device_info")
        async let second = connection.call("get_device_info")
        _ = try await (first, second)
        #expect(network.device().handshakes == 1)
        #expect(network.device().methods == ["get_device_info", "get_device_info"])
    }

    @Test func wrongCredentialsAreReported() async throws {
        let network = FakeTapoNetwork()
        let credentials = TapoCredentials(username: "user@example.com", password: "wrong")
        let connection = TapoConnection(host: "192.168.1.21", http: network, requestTimeout: .seconds(1), logger: testLogger) { credentials }
        await #expect(throws: TapoError.invalidCredentials) { try await connection.call("get_device_info") }
        let passthrough = FakeTapoNetwork(["192.168.1.21": FakeTapoNetwork.Device(mode: .passthrough)])
        let legacy = TapoConnection(host: "192.168.1.21", http: passthrough, requestTimeout: .seconds(1), logger: testLogger) { credentials }
        await #expect(throws: TapoError.invalidCredentials) { try await legacy.call("get_device_info") }
    }

    /// A session the device ended: one handshake more, the request again, for a get as for a set.
    @Test func expiredSessionSignsInAgainOnce() async throws {
        let network = FakeTapoNetwork()
        let credentials = TapoCredentials(username: "user@example.com", password: "password123")
        let connection = TapoConnection(host: "192.168.1.21", http: network, requestTimeout: .seconds(1), logger: testLogger) { credentials }
        _ = try await connection.call("get_device_info")
        network.update { $0.expireNext = 1 }
        _ = try await connection.call("set_device_info", params: ["device_on": true])
        #expect(network.device().handshakes == 2)
        #expect(network.device().info["device_on"] == true)
        network.update { $0.expireNext = 2 }
        await #expect(throws: TapoError.sessionRefused) { try await connection.call("get_device_info") }
    }

    /// A cookie whose TIMEOUT has passed is not used: a new handshake first.
    @Test func cookieTimeoutStartsANewSession() async throws {
        let network = FakeTapoNetwork()
        let clock = ClockBox()
        let credentials = TapoCredentials(username: "user@example.com", password: "password123")
        let connection = TapoConnection(
            host: "192.168.1.21", http: network, requestTimeout: .seconds(1), logger: testLogger, now: { clock.now }) { credentials }
        _ = try await connection.call("get_device_info")
        clock.advance(.seconds(86_000))
        _ = try await connection.call("get_device_info")
        #expect(network.device().handshakes == 1)
        clock.advance(.seconds(400))
        _ = try await connection.call("get_device_info")
        #expect(network.device().handshakes == 2)
    }

    @Test func passthroughFallback() async throws {
        let network = FakeTapoNetwork(["192.168.1.21": FakeTapoNetwork.Device(mode: .passthrough)])
        let credentials = TapoCredentials(username: "user@example.com", password: "password123")
        let connection = TapoConnection(host: "192.168.1.21", http: network, requestTimeout: .seconds(1), logger: testLogger) { credentials }
        let info = try await connection.call("get_device_info")
        #expect(info["hw_id"] == "0123456789ABCDEF0123456789ABCDEF")
        _ = try await connection.call("set_device_info", params: ["device_on": true])
        #expect(network.device().info["device_on"] == true)
        #expect(network.device().handshakes == 1)
    }

    @Test func setErrorsAreChecked() async throws {
        let network = FakeTapoNetwork()
        network.update { $0.setError = -1008 }
        let credentials = TapoCredentials(username: "user@example.com", password: "password123")
        let connection = TapoConnection(host: "192.168.1.21", http: network, requestTimeout: .seconds(1), logger: testLogger) { credentials }
        await #expect(throws: TapoError.device(-1008)) { try await connection.call("set_device_info", params: ["device_on": true]) }
        network.update { $0.malformedErrorCodes = true }
        _ = try await connection.call("set_device_info", params: ["device_on": true])
    }

    /// The accessory's identity is the Homebridge plugin's: its UUID was SHA-1 of the host and the name run together.
    @Test func identitySeedMatchesTheHomebridgeUUID() throws {
        func uuid(_ seed: String) -> String {
            let hex = Insecure.SHA1.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
            let digits = Array(hex.prefix(32))
            return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(digits[$0]) }.joined(separator: "-")
        }
        let named = try JSONDecoder().decode(TapoPlugin.Configuration.Device.self, from: Data(#"{"name":"Kitchen","host":"192.168.1.21"}"#.utf8))
        let unnamed = try JSONDecoder().decode(TapoPlugin.Configuration.Device.self, from: Data(#"{"host":"192.168.1.21","name":""}"#.utf8))
        #expect(named.deviceID == "192.168.1.21Kitchen")
        #expect(uuid(try #require(named.deviceID)) == "009b9a12-f6ba-1713-a87a-6ac8637c17f0")
        #expect(unnamed.deviceID == "192.168.1.21")
        #expect(uuid(try #require(unnamed.deviceID)) == "0d12ca59-9dc0-316b-eec6-436bb3beb04e")
    }
}

/// A clock a test moves.
final class ClockBox: Sendable {
    private let start = ContinuousClock.now
    private let offset = NIOLockedDuration()
    var now: ContinuousClock.Instant { start + offset.value }
    func advance(_ by: Duration) { offset.add(by) }
}

import NIOConcurrencyHelpers

final class NIOLockedDuration: Sendable {
    private let box = NIOLockedValueBox<Duration>(.zero)
    var value: Duration { box.withLockedValue { $0 } }
    func add(_ duration: Duration) { box.withLockedValue { $0 += duration } }
}
