import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftUniFiAccess

/// `access-api.test.ts` and `access-api-tls.test.ts`: login, requests, bootstrap, events, unlocking, pinning.
@Suite(.timeLimit(.minutes(1)))
struct AccessAPITests {
    let controller = FakeController()
    let events = FakeEvents()
    let log = LogRecorder()

    static let timing = AccessAPI.Timing(
        requestTimeout: .seconds(2), heartbeatTimeout: .milliseconds(150), reconnectMinimum: .milliseconds(20), reconnectMaximum: .milliseconds(100),
        throttle: .milliseconds(300), retryMinimum: .milliseconds(1), retryMaximum: .milliseconds(5))

    func makeAPI(trust: HTTPClient.TrustOnFirstUse = .init(), verifyTLS: Bool = false, events: Bool = true, mismatchHint: String? = nil) -> AccessAPI {
        let controller = controller
        return AccessAPI(
            logger: log.logger, http: { controller.client(tls: $0) }, events: events ? self.events.connector : nil, verifyTLS: verifyTLS, trust: trust,
            mismatchHint: mismatchHint, timing: Self.timing)
    }

    static let bootstrap: JSONValue = [
        "alias": "My Controller",
        "device_groups": [[.object(deviceJSON(["alias": "Top Level", "mac": "11:22:33:44:55:66", "unique_id": "top-level"]))]],
        "floors": [
            ["doors": [["device_groups": [[.object(deviceJSON(["unique_id": "door-device"]))]], "name": "Front", "unique_id": "door-1"]]],
            ["doors": []],
        ],
    ]

    @Test func loginKeepsTheSession() async throws {
        let api = makeAPI()
        #expect(await api.login(address: "10.0.0.1", username: "user", password: "pass"))
        let login = try #require(controller.requests.first { $0.url == "https://10.0.0.1/api/auth/login" })
        #expect(login.method == "POST")
        #expect(login.body == #"{"password":"pass","rememberMe":true,"token":"","username":"user"}"#)
        #expect(login.headers.contains { $0.name == "x-csrf-token" && $0.value == "csrf-1" })
        #expect(login.headers.contains { $0.name == "user-agent" && $0.value == "unifi-access" })

        _ = await api.retrieve("https://10.0.0.1/proxy/access/api/v2/anything")
        let last = try #require(controller.requests.last)
        #expect(last.headers.contains { $0.name == "cookie" && $0.value == "TOKEN=abc123" })
        #expect(last.headers.contains { $0.name == "x-csrf-token" && $0.value == "csrf-2" })
        await api.close()
    }

    @Test func loginFailures() async {
        controller.override("/api/auth/login") { _ in HTTPResponse(status: 200, headers: [("X-CSRF-Token", "csrf-2")]) }
        #expect(!(await makeAPI().login(address: "10.0.0.1", username: "user", password: "pass")))

        controller.override("/api/auth/login") { _ in HTTPResponse(status: 401) }
        #expect(!(await makeAPI().login(address: "10.0.0.1", username: "user", password: "wrong")))
        #expect(log.contains("Invalid login credentials given. Please check your login and password.", level: .error))
    }

    @Test func unauthorisedLogsOutButKeepsTheToken() async throws {
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        controller.override("/expired") { _ in HTTPResponse(status: 401) }
        #expect(await api.retrieve("https://10.0.0.1/expired") == nil)
        _ = await api.retrieve("https://10.0.0.1/next")
        let last = try #require(controller.requests.last)
        #expect(last.headers.contains { $0.name == "x-csrf-token" && $0.value == "csrf-2" })
        #expect(!last.headers.contains { $0.name == "cookie" })
    }

    @Test func retriesOnlyTransientIdempotentRequests() async {
        let api = makeAPI()
        controller.override("/flaky") { _ in HTTPResponse(status: 503) }
        _ = await api.retrieve("https://10.0.0.1/flaky")
        #expect(controller.requests(matching: "/flaky").count == 6)
        controller.clearRequests()
        _ = await api.retrieve("https://10.0.0.1/flaky", method: "PUT", body: Data("{}".utf8))
        #expect(controller.requests(matching: "/flaky").count == 1)
        controller.clearRequests()
        controller.override("/missing") { _ in HTTPResponse(status: 404) }
        _ = await api.retrieve("https://10.0.0.1/missing")
        #expect(controller.requests(matching: "/missing").count == 1)
    }

    @Test(arguments: [(403, "Insufficient privileges"), (503, "Unable to connect to the Access controller"), (418, "418 - I'm a Teapot")])
    func statusMessages(status: Int, message: String) async {
        controller.override("/x") { _ in HTTPResponse(status: status) }
        #expect(await makeAPI().retrieve("https://10.0.0.1/x") == nil)
        #expect(log.contains(message, level: .error))
    }

    @Test func quietRequests() async {
        controller.override("/x") { _ in HTTPResponse(status: 503) }
        #expect(await makeAPI().retrieve("https://10.0.0.1/x", logErrors: false) == nil)
        #expect(log.messages(.error).isEmpty)
    }

    @Test(arguments: [(ECONNREFUSED, "Connection refused."), (ECONNRESET, "has been reset")])
    func networkErrors(code: Int32, message: String) async {
        controller.fail("/x", with: HTTPClientError.cannotConnect(host: "10.0.0.1", port: 443, code: code, reason: "boom"))
        #expect(await makeAPI().retrieve("https://10.0.0.1/x") == nil)
        #expect(log.contains(message, level: .error))
    }

    @Test func timeouts() async {
        controller.fail("/x", with: HTTPClientError.timeout)
        #expect(await makeAPI().retrieve("https://10.0.0.1/x") == nil)
        #expect(log.contains("taking too long to respond", level: .error))
    }

    @Test func throttlesAfterRepeatedErrors() async {
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        controller.override("/x") { _ in HTTPResponse(status: 400) }
        for _ in 0..<10 { _ = await api.retrieve("https://10.0.0.1/x") }
        controller.clearRequests()
        #expect(await api.retrieve("https://10.0.0.1/x") == nil)
        #expect(await api.isThrottled)
        #expect(await api.retrieve("https://10.0.0.1/x") == nil)
        #expect(controller.requests.isEmpty)
        #expect(log.contains("Throttling API calls due to errors with the 10 previous attempts", level: .error))

        try? await Task.sleep(for: .milliseconds(350))
        controller.removeOverride("/x")
        #expect(await api.retrieve("https://10.0.0.1/x") != nil)
        #expect(!(await api.isThrottled))
        #expect(log.contains("Resuming connectivity", level: .error))
    }

    @Test func bootstrapFlattensDoorsAndDevices() async throws {
        controller.setBootstrap(Self.bootstrap)
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        #expect(await api.getBootstrap())
        #expect(await api.controller?.version == "2.0.0")
        #expect(await api.doors?.map(\.uniqueId) == ["door-1"])
        #expect(await api.devices?.map(\.uniqueId) == ["door-device", "top-level"])
        #expect(await api.name == "My Controller")
        #expect(events.connections.count == 1)
        #expect(events.connections[0].url.absoluteString == "wss://10.0.0.1/proxy/access/api/v2/ws/notification")
        #expect(events.connections[0].options.headers.contains { $0.name == "Cookie" && $0.value == "TOKEN=abc123" })
        await api.close()
    }

    @Test func enterpriseHubsBecomeOneDevicePerDoor() async throws {
        let eah = deviceJSON([
            "alias": "Lobby EAH", "device_type": "UAH-Ent", "display_model": "UA Hub Enterprise", "unique_id": "eah",
            "extensions": [
                ["extension_name": "port_setting", "source_id": "port1", "target_name": "North Door", "target_value": "door-north", "unique_id": "ext-1"],
                ["extension_name": "port_setting", "source_id": "port2", "target_name": "South Door", "target_value": "door-south", "unique_id": "ext-2"],
            ],
        ])
        controller.setBootstrap(["device_groups": [[.object(eah)]], "floors": []])
        let api = makeAPI(events: false)
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        _ = await api.getBootstrap()
        let doors = (await api.devices ?? []).filter { $0.sourceId?.hasPrefix("port") == true }
        #expect(doors.map { [$0.alias, $0.locationId, $0.displayModel, $0.name] } == [
            ["North Door", "door-north", "UA Hub Enterprise Port1", "Lobby EAH"], ["South Door", "door-south", "UA Hub Enterprise Port2", "Lobby EAH"],
        ])
        #expect(doors.map(\.identifier) == ["AABBCCDDEEFF-PORT1", "AABBCCDDEEFF-PORT2"])
        #expect(doors.map(\.uniqueId) == ["ext-1", "ext-2"])
    }

    @Test func unparsableBootstrapRetriesOnce() async {
        controller.override("devices/topology4") { _ in HTTPResponse(status: 200, body: Data("not json".utf8)) }
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        controller.clearRequests()
        #expect(!(await api.getBootstrap()))
        #expect(controller.requests(matching: "devices/topology4").count == 2)
    }

    @Test func eventsAreDecodedAndHeartbeatsIgnored() async throws {
        controller.setBootstrap(Self.bootstrap)
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        _ = await api.getBootstrap()
        let socket = try #require(events.last)
        socket.receive(text: "\"Hello\"\n")
        socket.receive(text: #"{"event":"access.data.device.update","event_object_id":"x","data":{"a":1}}"#)
        var iterator = api.events.makeAsyncIterator()
        var packets: [AccessEventPacket] = []
        while packets.isEmpty, let event = await iterator.next() {
            if case .message(let packet) = event { packets.append(packet) }
        }
        #expect(packets.first?.event == "access.data.device.update")
        #expect(packets.first?.eventObjectId == "x")
        await api.close()
    }

    @Test func reconnectsWhenTheConnectionDrops() async throws {
        controller.setBootstrap(Self.bootstrap)
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        _ = await api.getBootstrap()
        events.last?.finish()
        #expect(await eventually { events.all.count == 2 })
        await api.close()
    }

    @Test func reconnectsWhenTheHeartbeatStops() async throws {
        controller.setBootstrap(Self.bootstrap)
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        _ = await api.getBootstrap()
        let first = try #require(events.last)
        first.receive(text: "\"Hello\"\n")
        #expect(await eventually { !first.isOpen })
        #expect(log.contains("Failed to detect heartbeat from the events API. Resetting the connection.", level: .error))
        #expect(await eventually { events.all.count == 2 })
        await api.close()
    }

    @Test func noReconnectionOnceClosed() async throws {
        controller.setBootstrap(Self.bootstrap)
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        _ = await api.getBootstrap()
        await api.close()
        events.last?.finish()
        try await Task.sleep(for: .milliseconds(300))
        #expect(events.all.count == 1)
    }

    static let hub = AccessDevice(deviceJSON(["extensions": [["extension_name": "port_setting", "target_value": "door-7"]], "unique_id": "hub-1"]))

    @Test func unlocking() async throws {
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        controller.clearRequests()
        #expect(!(await api.unlock(AccessDevice(deviceJSON(["capabilities": ["is_reader"]])))))
        #expect(controller.requests.isEmpty)

        #expect(await api.unlock(Self.hub))
        #expect(controller.requests.last?.url == "https://10.0.0.1/proxy/access/api/v2/location/door-7/unlock")
        #expect(controller.requests.last?.method == "PUT")

        for (duration, payload) in [(0.0, #"{"type":"reset"}"#), (-5, #"{"type":"reset"}"#), (.infinity, #"{"type":"keep_unlock"}"#), (5.7, #"{"interval":5,"type":"custom"}"#)] {
            #expect(await api.unlock(Self.hub, minutes: duration))
            #expect(controller.requests.last?.url == "https://10.0.0.1/proxy/access/api/v2/device/hub-1/lock_rule?get_result=true")
            #expect(controller.requests.last?.body == payload)
        }
    }

    @Test(arguments: [#"{"codeS":"CODE_DEVICE_OFFLINE"}"#, "not json", "null"])
    func unlockFailures(body: String) async {
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        controller.override("/unlock") { _ in HTTPResponse(status: 200, body: Data(body.utf8)) }
        #expect(!(await api.unlock(Self.hub)))
    }

    @Test func unlockRequestFailure() async {
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        controller.override("/unlock") { _ in HTTPResponse(status: 500) }
        #expect(!(await api.unlock(Self.hub)))
    }

    @Test func endpoints() async {
        let api = makeAPI()
        _ = await api.login(address: "10.0.0.1", username: "user", password: "pass")
        #expect(await api.endpoint("bootstrap") == "https://10.0.0.1/proxy/access/api/v2/devices/topology4")
        #expect(await api.endpoint("controller") == "https://10.0.0.1/proxy/access/api/v2/access/info")
        #expect(await api.endpoint("login") == "https://10.0.0.1/api/auth/login")
        #expect(await api.endpoint("self") == "https://10.0.0.1/api/users/self")
        #expect(await api.endpoint("unknown") == "")
    }

    /// Trust on first use: the first certificate is pinned and later requests must present it.
    @Test func pinsTheFirstCertificate() async throws {
        let pinned = LockedBox<String?>(nil)
        let trust = HTTPClient.TrustOnFirstUse(pinned: nil, onPinned: { pinned.set($0) })
        let api = makeAPI(trust: trust, mismatchHint: "UDM: Remove the pin to trust a new certificate.")
        #expect(await api.login(address: "10.0.0.1", username: "user", password: "pass"))
        let expected = String(repeating: "ab", count: 32)
        #expect(pinned.get() == expected)
        #expect(controller.requests.first?.tls == .any)
        #expect(controller.requests.last?.tls == .pinned(expected))
        #expect(log.contains("Trusting and pinning the TLS certificate presented by 10.0.0.1 (SHA-256 fingerprint: \(Array(repeating: "AB", count: 32).joined(separator: ":"))).", level: .info))

        // The controller's certificate changes: refused, told once.
        controller.setFingerprint(String(repeating: "cd", count: 32))
        #expect(await api.retrieve("https://10.0.0.1/x") == nil)
        #expect(await api.retrieve("https://10.0.0.1/y") == nil)
        #expect(log.messages(.error).filter { $0.contains("does not match the pinned certificate") }.count == 1)
        #expect(log.messages(.error).filter { $0 == "UDM: Remove the pin to trust a new certificate." }.count == 1)
    }

    @Test func strictTLSNeverPins() async throws {
        let trust = HTTPClient.TrustOnFirstUse()
        let api = makeAPI(trust: trust, verifyTLS: true)
        #expect(await api.login(address: "10.0.0.1", username: "user", password: "pass"))
        #expect(controller.requests.allSatisfy { $0.tls == .system })
        #expect(trust.fingerprint == nil)
    }
}

/// A value tests set from a `@Sendable` closure.
final class LockedBox<Value: Sendable>: Sendable {
    private let value: NIOLockedValueBox<Value>
    init(_ value: Value) { self.value = NIOLockedValueBox(value) }
    func get() -> Value { value.withLockedValue { $0 } }
    func set(_ newValue: Value) { value.withLockedValue { $0 = newValue } }
}
