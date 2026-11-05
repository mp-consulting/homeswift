import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftTapo

/// The control API's encrypt_type 3 login and `securePassthrough`, against docs/clean-room/TapoPTZ.md's vectors (10.1).
@Suite struct TapoControlTests {
    let hash = "D23E8AD06AA8C81F7A6FC25A66922E4CFE2D3BDF6AC227C166F1EEC354E41767"
    let cnonce = "0A1B2C3D4E5F6071", nonce = "9F8E7D6C5B4A39281706F5E4D3C2B1A0"

    @Test func theLoginValuesMatchTheSpec() {
        #expect(Streamd.passwordHash("ExamplePassw0rd!", sha256: true) == hash)
        #expect(TapoControlCrypto.deviceConfirm(cnonce: cnonce, hash: hash, nonce: nonce)
            == "CC07490418AB3419BC8992A916C1F7E9180C80AAEC9BFB974988A0EAEF4FD3B09F8E7D6C5B4A39281706F5E4D3C2B1A00A1B2C3D4E5F6071")
        #expect(TapoControlCrypto.digestPassword(cnonce: cnonce, hash: hash, nonce: nonce)
            == "4A8969D3F6F04C8138348CD24ED0DE214DF3A6CA841F851A5A1B93742299C69A0A1B2C3D4E5F60719F8E7D6C5B4A39281706F5E4D3C2B1A0")
        let cipher = TapoControlCrypto.cipher(cnonce: cnonce, hash: hash, nonce: nonce)
        #expect(Streamd.hex(cipher.key) == "f40098bd0c28266869060621fabe3245")
        #expect(Streamd.hex(cipher.iv) == "f5eee14d9ff746f8158d655aeefaef92")
        #expect(TapoControlCrypto.sha(hash + cnonce) == "422619D87FEC17F74A87F5162C04C504EA9F1C3B3DD274CC2F9B44F104AB53EF")
    }

    @Test func requestsAndRepliesMatchTheSpec() throws {
        let cipher = TapoControlCrypto.cipher(cnonce: cnonce, hash: hash, nonce: nonce)
        let inner = #"{"method":"multipleRequest","params":{"requests":[{"method":"relativeMove","params":{"motor":{"movestep":{"direction":"90"}}}}]}}"#
        let encrypted = try cipher.encrypt(Data(inner.utf8))
        #expect(encrypted == "+bNQfuzri7odbg9ELj5lqf/AxG7lNM2FQsP6mbZ5vKmqbT5X1+ROuzae8KBTh0ncNSz7NHNQF7FyGESKFMcptIcGQW14iRjotC1xJODBd403f7IBsSn7Oxt7oluog//YUDtADhmfjNyeNISNYx6vkhAKG3fR+0hOoYDfkkA/zRGshmHQ6O65A48K0D6DYbla")
        let body = #"{"method":"securePassthrough","params":{"request":""# + encrypted + #""}}"#
        #expect(TapoControlCrypto.tag(hash: hash, cnonce: cnonce, body: body, seq: 1234) == "7EBE9D5E8C2A129CEAE3DEDEA0120CD5B3A147857C61219DA655C515E48A7A4D")
        let reply = try cipher.decrypt(
            "QUZT0A9a+UgKGef57O+LdN6g/YHHwZCNxKygwtheEa7FhaUmboQlWD0nU48/xkHuRvbBbFhwDROWaEUU7GNnp3zjoHEnPHWxD8JWVpi04ad1ZqIZz8ixzzaGsp99/lVF",
        )
        #expect(String(decoding: reply, as: UTF8.self) == #"{"result":{"responses":[{"method":"relativeMove","result":{},"error_code":0}]},"error_code":0}"#)
    }
}

/// The control API's client against a camera in memory: the login, pan and tilt, the session's errors.
@Suite(.timeLimit(.minutes(1)))
struct TapoControlClientTests {
    let camera = FakeTapoControlCamera()

    func client(resetTrust: @escaping @Sendable () -> Void = {}) -> TapoControl {
        let camera = camera
        return TapoControl(host: "192.168.1.40", http: { camera }, resetTrust: resetTrust, password: { "password123" },
                           motorSpacing: .milliseconds(5), logger: testLogger)
    }

    @Test func signsInAndMoves() async throws {
        let control = client()
        #expect(try await control.presets() == [.init(id: "1", name: "Gate"), .init(id: "2", name: "Drive")])
        try await control.move(x: 15, y: 0)
        try await control.goToPreset("2")
        camera.state.withLockedValue { state in
            #expect(state.logins == 1 && state.discovers == 1 && state.badTags == 0)
            #expect(state.moves.map(\.x) == [15] && state.presetsVisited == ["2"])
        }
    }

    @Test func aWrongPasswordIsRefusedBeforeTheDigest() async throws {
        camera.state.withLockedValue { $0.password = "another" }
        await #expect(throws: TapoControlError.wrongPassword) { try await self.client().presets() }
        #expect(camera.state.withLockedValue { $0.logins } == 0)
    }

    /// -40210 is a session code and METHOD_DO_NOT_EXIST: sent once more after a new login, then unsupported.
    @Test func methodDoesNotExistAfterANewLoginIsUnsupported() async throws {
        camera.state.withLockedValue { $0.presetError = -40210 }
        await #expect(throws: TapoControlError.code(-40210)) { try await self.client().presets() }
        #expect(camera.state.withLockedValue { $0.logins } == 2)
    }

    @Test func overlappingCallsSignInOnce() async throws {
        camera.state.withLockedValue { $0.delay = .milliseconds(20) }
        let control = client()
        async let presets = control.presets()
        async let move: Void = control.move(x: 0, y: 15)
        _ = try await (presets, move)
        #expect(camera.state.withLockedValue { $0.logins } == 1)
    }

    @Test func aNewCertificateIsTrustedAfterTheLoginProvesTheCamera() async throws {
        let resets = NIOLockedValueBox(0)
        let control = client(resetTrust: { resets.withLockedValue { $0 += 1 } })
        _ = try await control.presets()
        camera.state.withLockedValue { $0.certificateChanges = 1 }
        try await control.move(x: -15, y: 0)
        #expect(resets.withLockedValue { $0 } == 1)
        #expect(camera.state.withLockedValue { ($0.logins, $0.moves.count) } == (2, 1))
    }

    @Test func errorsAreDescribedWithoutTheirURL() {
        #expect(TapoControl.kind(of: HTTPClientError.invalidURL("https://h:443/stok=secret/ds")) == "invalid URL")
        #expect(!TapoControl.kind(of: HTTPClientError.invalidURL("https://h:443/stok=secret/ds")).contains("secret"))
    }
}

/// Pan and tilt through the plugin: only the tele lens, only while the camera is awake.
@Suite(.timeLimit(.minutes(1)))
struct TapoPTZTests {
    let environment = TestEnvironment()
    let teleID = "TapoP100:192.168.1.40Garden:tele"

    @Test func aSleepingCameraIsNotMovedNorAsked() async throws {
        let camera = FakeTapoControlCamera()
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera", "motion": false]], control: camera)
        let plugin = try #require(environment.plugin)
        #expect(await plugin.cameraControls(accessoryID: teleID) == nil)
        await #expect(throws: CameraControlError.self) { try await plugin.controlCamera(accessoryID: self.teleID, .move(.left)) }
        // The wide lens has no motor of its own.
        #expect(await plugin.cameraControls(accessoryID: "TapoP100:192.168.1.40Garden") == nil)
        #expect(camera.state.withLockedValue { $0.discovers + $0.logins } == 0)
        let listed = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "ptz", user: "admin"))
        #expect(listed.json["cameras"]?.arrayValue?.first?["camera"]?.stringValue == teleID)
        #expect(listed.json["cameras"]?.arrayValue?.first?["awake"] == false)
        await host.stop()
    }
}
