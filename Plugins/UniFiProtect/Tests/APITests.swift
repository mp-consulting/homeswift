import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftUniFiProtect

/// The API client against a fake controller (protect-api.test.ts, protect-api-units.test.ts).
@Suite(.timeLimit(.minutes(1))) struct APITests {
    func api(_ controller: FakeController, logs: LogCapture = LogCapture(), sockets: FakeWebSocketConnector = FakeWebSocketConnector(),
             pin: ProtectTLSPin.Options = .init(), verifyTls: Bool = false) -> ProtectAPI {
        ProtectAPI(log: ProtectLog(logger: logs.logger), options: .init(verifyTls: verifyTls, pin: pin, transport: controller, webSockets: sockets.factory, timeScale: 0.01))
    }

    @Test func fetchesACSRFTokenWhenTheLoginIsRefused() async throws {
        let controller = FakeController()
        controller.update { $0.requireCSRF = true }
        let api = api(controller)
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        let logins = controller.requests("/api/auth/login")
        #expect(logins.count == 2)
        #expect(logins[0].headers["x-csrf-token"] == nil && logins[1].headers["x-csrf-token"] == "csrf-1")
        let body = try #require(FakeController.body(logins[1]))
        #expect(body.string("username") == "user" && body.string("password") == "secret" && body.bool("rememberMe"))
        #expect(await api.isLoggedIn)
        #expect(await api.cookie == "TOKEN=session-cookie")
    }

    @Test func failsALoginTheControllerRefuses() async {
        let controller = FakeController()
        controller.update { $0.password = "other" }
        let logs = LogCapture()
        let api = api(controller, logs: logs)
        #expect(await !api.login(address: "192.168.1.1", username: "user", password: "wrong"))
        #expect(logs.contains("Invalid login credentials given. Please check your login and password."))
    }

    @Test func logsInAgainAfterA401() async throws {
        let controller = FakeController()
        let api = api(controller)
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        controller.update { $0.scripted["/proxy/protect/api/ws/livestream"] = [401] }
        #expect(await api.getWsEndpoint("livestream") == nil)
        let url = try #require(await api.getWsEndpoint("livestream"))
        #expect(controller.requests("/api/auth/login").count == 2)
        // The controller's URL on the address we use, its token kept.
        #expect(url == "wss://192.168.1.1:7442/livestream?token=abc")
        let request = try #require(controller.requests("/proxy/protect/api/ws/livestream").last)
        #expect(request.headers["cookie"] == "TOKEN=session-cookie" && request.headers["x-csrf-token"] == "csrf-2")
    }

    @Test func throttlesAfterRepeatedErrors() async {
        let controller = FakeController()
        controller.update { $0.password = "other" }
        let logs = LogCapture()
        let api = api(controller, logs: logs)
        #expect(await !api.login(address: "192.168.1.1", username: "user", password: "secret"))
        #expect(await !api.isThrottled)
        controller.update { $0.failEverything = 500 }
        var attempts = 0
        while await !api.isThrottled, attempts < 20 {
            #expect(await api.retrieve("https://192.168.1.1/fail", method: "POST", logErrors: false) == nil)
            attempts += 1
        }
        #expect(await api.isThrottled)
        #expect(attempts <= 10)
        let seen = controller.requests.count
        #expect(await api.retrieve("https://192.168.1.1/fail", method: "POST") == nil)
        #expect(controller.requests.count == seen)
        #expect(logs.contains("Throttling API calls due to errors with the 10 previous attempts"))
    }

    @Test func retriesTransientErrorsOfGets() async {
        let controller = FakeController()
        let api = api(controller)
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        controller.update { $0.scripted["/proxy/protect/api/bootstrap"] = [503, 502] }
        // The request's deadline is real time (3.5 s, unscaled): a loaded runner can spend it before the third try.
        let response = await api.retrieve("https://192.168.1.1/proxy/protect/api/bootstrap", timeout: .seconds(30))
        #expect(response?.status == 200)
        #expect(controller.requests("/proxy/protect/api/bootstrap").count == 3)
        // PATCH and POST are not retried: the controller may have done them.
        controller.update { $0.scripted["/proxy/protect/api/cameras/camera-id"] = [503] }
        #expect(await api.retrieve("https://192.168.1.1/proxy/protect/api/cameras/camera-id", method: "PATCH", body: Data("{}".utf8)) == nil)
        #expect(controller.requests("/proxy/protect/api/cameras/camera-id").count == 1)
    }

    @Test func pinsTheCertificateOnFirstUse() async {
        let controller = FakeController()
        let pinned = NIOLockedValueBox<[String]>([])
        let logs = LogCapture()
        let api = api(controller, logs: logs, pin: .init(onFingerprint: { fingerprint in pinned.withLockedValue { $0.append(fingerprint) } }))
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        let expected = normalizeFingerprint(FakeController.fingerprint)
        #expect(pinned.withLockedValue { $0 } == [expected!])
        #expect(await api.tlsFingerprint == expected)
        #expect(logs.contains("Trusting and pinning the TLS certificate presented by 192.168.1.1"))
        // The first request went out on trust, the next ones only to the pinned certificate.
        #expect(controller.requests.first?.tls == .any)
        #expect(controller.requests.dropFirst().allSatisfy { $0.tls == .pinned(expected!) })
    }

    @Test func refusesAnotherCertificateBeforeSendingCredentials() async {
        let controller = FakeController()
        let mismatches = NIOLockedValueBox(0)
        let logs = LogCapture()
        let pinned = Array(repeating: "AB", count: 31).joined(separator: ":") + ":CD"
        let api = api(controller, logs: logs, pin: .init(pinnedFingerprint: pinned, onFingerprintMismatch: { _, _ in mismatches.withLockedValue { $0 += 1 } }))
        #expect(await !api.login(address: "192.168.1.1", username: "user", password: "secret"))
        #expect(controller.requests.isEmpty)
        #expect(mismatches.withLockedValue { $0 } == 1)
        #expect(logs.messages(at: .error).filter { $0.contains("does not match the pinned certificate") }.count == 1)
        #expect(await api.tlsFingerprint == pinned)
        // The events WebSocket goes through the same check: no upgrade request, no cookie.
        let sockets = FakeWebSocketConnector()
        let other = self.api(controller, logs: logs, sockets: sockets, pin: .init(pinnedFingerprint: pinned))
        #expect(await !other.connectEvents())
        #expect(sockets.connections.isEmpty)
    }

    @Test func acceptsThePinnedCertificateInAnySpelling() async {
        let controller = FakeController()
        let api = api(controller, pin: .init(pinnedFingerprint: FakeController.fingerprint.uppercased()))
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        #expect(controller.requests.allSatisfy { if case .pinned = $0.tls { true } else { false } })
    }

    @Test func verifyTlsUsesTheSystemRoots() async {
        let controller = FakeController()
        let api = api(controller, verifyTls: true)
        // The fake console's certificate is self-signed: the system does not trust it.
        #expect(await !api.login(address: "192.168.1.1", username: "user", password: "secret"))
        #expect(controller.requests.isEmpty)
        #expect(await api.tlsFingerprint == nil)
    }

    @Test func bootstrapsAndStreamsEvents() async throws {
        let controller = FakeController()
        let sockets = FakeWebSocketConnector()
        let api = api(controller, sockets: sockets)
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        #expect(await api.getBootstrap())
        #expect(await api.isAdminUser)
        #expect(await api.name == "Home NVR [UNVR]")
        let socket = try #require(sockets.last)
        #expect(sockets.header("Cookie", of: socket) == "TOKEN=session-cookie")
        #expect(socket.url?.absoluteString == "wss://192.168.1.1/proxy/protect/ws/updates?lastUpdateId=update-1")
        socket.push(ProtectEventPacket.encode(header: ProtocolTests.action, payload: ProtocolTests.data))
        var iterator = api.packets.makeAsyncIterator()
        let packet = await iterator.next()
        #expect(packet?.payload == ProtocolTests.data)
        // A dropped connection is reconnected a few seconds later (scaled).
        socket.serverClose()
        #expect(await eventually { sockets.connections.count == 2 })
        // A message that is not a packet closes the connection.
        sockets.last?.push(Data([1, 2, 3]))
        #expect(await eventually { sockets.connections.count == 3 })
    }

    @Test func heartbeatClosesASilentEventsConnection() async throws {
        let controller = FakeController()
        let sockets = FakeWebSocketConnector()
        sockets.unansweredPings.withLockedValue { $0 = true }
        let api = api(controller, sockets: sockets)
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        #expect(await api.getBootstrap())
        let socket = try #require(sockets.last)
        // 30 s scaled: a ping first, then the connection is presumed dead.
        #expect(await eventually { socket.pingCount >= 1 })
        #expect(await eventually { socket.isClosed })
    }

    @Test func checksAdminRole() async {
        let readOnly = Fixtures.bootstrap { $0["users"] = [["id": "user-1", "allPermissions": ["camera:read:*"]]] }
        let controller = FakeController(bootstrap: readOnly)
        let logs = LogCapture()
        let api = api(controller, logs: logs)
        #expect(await api.login(address: "192.168.1.1", username: "homeswift", password: "secret"))
        #expect(await api.getBootstrap())
        #expect(await !api.isAdminUser)
        #expect(logs.contains("User 'homeswift' requires the Super Admin role"))
        #expect(await api.updateDevice(Fixtures.camera(), payload: ["name": "x"]) == nil)
    }

    @Test func updatesDevicesAndEnablesRtsp() async throws {
        let cameras = [Fixtures.camera().setting("channels", Fixtures.channels(rtsp: false))]
        let controller = FakeController(bootstrap: Fixtures.bootstrap(cameras: cameras))
        let api = api(controller)
        #expect(await api.login(address: "192.168.1.1", username: "user", password: "secret"))
        #expect(await api.getBootstrap())
        let updated = try #require(await api.updateDevice(Fixtures.camera(), payload: ["ledSettings": ["isEnabled": false]]))
        #expect(!updated.bool("ledSettings.isEnabled"))
        let patch = try #require(controller.requests("/proxy/protect/api/cameras/camera-id").last)
        #expect(patch.method == "PATCH" && FakeController.body(patch) == ["ledSettings": ["isEnabled": false]])
        let nvr = try #require(await api.updateDevice(Fixtures.bootstrap().at("nvr")!, payload: ["name": "Renamed"]))
        #expect(nvr.string("name") == "Renamed" && controller.requests("/proxy/protect/api/nvr").count == 1)
        let rtsp = try #require(await api.enableRtsp(cameras[0]))
        #expect(rtsp.array("channels").allSatisfy { $0.bool("isRtspEnabled") })
        let snapshot = await api.getSnapshot(Fixtures.camera(), width: 640, height: 360)
        #expect(snapshot == Data([0xFF, 0xD8, 0xFF]))
        #expect(controller.requests("/proxy/protect/api/cameras/camera-id/snapshot").last?.query == "h=360&w=640")
        #expect(await api.getSnapshot(Fixtures.camera(), usePackageCamera: true) == nil)
    }

    @Test func circuitBreaker() {
        let clock = NIOLockedValueBox(ContinuousClock.now)
        var breaker = CircuitBreaker(errorLimit: 3, retryInterval: .seconds(60)) { clock.withLockedValue { $0 } }
        #expect(breaker.check() == .closed)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.check() == .closed && !breaker.isOverLimit)
        breaker.recordFailure()
        #expect(breaker.check() == .tripped && breaker.isThrottled)
        #expect(breaker.check() == .open)
        clock.withLockedValue { $0 += .seconds(61) }
        #expect(breaker.check() == .resumed && breaker.errorCount == 0 && !breaker.isThrottled)
        breaker.recordFailure()
        breaker.recordSuccess()
        #expect(breaker.errorCount == 0)
    }

    @Test func pinStore() throws {
        #expect(normalizeFingerprint(String(repeating: "ab", count: 32)) == Array(repeating: "AB", count: 32).joined(separator: ":"))
        #expect(normalizeFingerprint("nope") == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("protect-pins-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("unifi-protect-tls-pins.json")
        let store = ProtectTLSPinStore(url: url)
        store.set(" 192.168.1.1 ", fingerprint: String(repeating: "cd", count: 32))
        #expect(store.get("192.168.1.1") == normalizeFingerprint(String(repeating: "cd", count: 32)))
        #expect(ProtectTLSPinStore(url: url).get("192.168.1.1") == normalizeFingerprint(String(repeating: "cd", count: 32)))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        try Data("not json".utf8).write(to: url)
        let errors = NIOLockedValueBox<[String]>([])
        let corrupt = ProtectTLSPinStore(url: url) { message in errors.withLockedValue { $0.append(message) } }
        #expect(corrupt.get("192.168.1.1") == nil)
        #expect(errors.withLockedValue { $0.count } == 1)
    }

    @Test func helpers() {
        #expect(ProtectAPI.deviceName(Fixtures.camera()) == "Driveway [G4 Bullet]")
        #expect(ProtectAPI.deviceName(Fixtures.camera(), deviceInfo: true) == "Driveway [G4 Bullet] (address: 192.168.1.50 mac: F4E2C6000001)")
        #expect(ProtectAPI.hostname(of: "192.168.1.1:443") == "192.168.1.1")
        #expect(ProtectAPI.hostname(of: "[fe80::1]:443") == "fe80::1")
        #expect(URLEncoding.form([("lastUpdateId", "a b"), ("x", "")]) == "lastUpdateId=a+b&x=")
    }
}
