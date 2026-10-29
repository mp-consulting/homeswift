import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftEWeLink

@Suite(.timeLimit(.minutes(1)))
struct CloudAPITests {
    let cloud = FakeCloud()

    func api(username: String = "user@example.com", password: String = "secret", countryCode: String? = "+351", storage: TokenStorage? = nil) -> CloudAPI {
        CloudAPI(credentials: .init(username: username, password: password, countryCode: countryCode), transport: cloud, storage: storage, logger: testLogger)
    }

    @Test func logsInWithASignedRequest() async throws {
        let api = api()
        try await api.login()
        let login = try #require(cloud.requests(path: "/v2/user/login").first)
        #expect(login.url.host == "eu-apia.coolkit.cc")
        let body = String(decoding: login.body ?? Data(), as: UTF8.self)
        #expect(body == #"{"countryCode":"+351","password":"secret","email":"user@example.com"}"#)
        #expect(login.header("Authorization") == "Sign \(CloudAPI.signature(body))")
        #expect(login.header("X-CK-Appid") == EWeLinkCloud.appID && login.header("X-CK-Nonce")?.count == 8)
        let (token, refresh, key) = (await api.accessToken, await api.refreshToken, await api.apiKey)
        #expect(token == "access-token-1" && refresh == "refresh-token-1" && key == "user-api-key")
    }

    @Test func phoneNumbersLogInAsPhoneNumbers() async throws {
        try await api(username: "+351912345678", countryCode: nil).login()
        let body = try #require(cloud.state.withLockedValue { $0.loginBodies.first })
        #expect(body == #"{"countryCode":"1","password":"secret","phoneNumber":"+351912345678"}"#)
    }

    @Test func missingCredentialsFail() async {
        await #expect(throws: EWeLinkError("Username and password are required")) { try await api(username: "").login() }
    }

    @Test func followsTheRegionRedirect() async throws {
        cloud.update { $0.loginAnswers = [["error": 10004, "data": ["region": "as"]]] }
        let api = api(countryCode: "+1")
        try await api.login()
        #expect(cloud.requests(path: "/v2/user/login").map { $0.url.host ?? "" } == ["us-apia.coolkit.cc", "as-apia.coolkit.cc"])
        #expect(await api.region == .as)
        cloud.update { $0.loginAnswers = [["error": 10004, "data": ["region": "mars"]]] }
        await #expect(throws: EWeLinkError("Unknown region received: mars")) { try await self.api().login() }
    }

    @Test func aRegionRedirectLoopEnds() async throws {
        let bounce: [JSONValue] = (0..<10).map { ["error": 10004, "data": ["region": .string($0 % 2 == 0 ? "us" : "eu")]] }
        cloud.update { $0.loginAnswers = bounce }
        await #expect(throws: EWeLinkError.self) { try await self.api().login() }
        #expect(cloud.requests(path: "/v2/user/login").count == CloudAPI.maximumRegionRedirects + 1)
    }

    @Test func triesTheBase64DecodedPasswordOnce() async throws {
        cloud.update { $0.loginAnswers = [["error": 10001, "msg": "wrong password"]] }
        try await api(password: "c2VjcmV0\n").login()
        let bodies = cloud.state.withLockedValue { $0.loginBodies }
        #expect(bodies.count == 2 && bodies[1].contains(#""password":"secret""#))

        cloud.update { $0.loginAnswers = [["error": 10014, "msg": "wrong"], ["error": 10001, "msg": "still wrong"]] }
        await #expect(throws: EWeLinkError("still wrong [10001]", code: 10001)) { try await self.api().login() }
        cloud.update { $0.loginAnswers = [["error": 500]] }
        await #expect(throws: EWeLinkError("Login failed: unexpected response [500]", code: 500)) { try await self.api().login() }
    }

    @Test func refreshesAnExpiredTokenOnceForConcurrentRequests() async throws {
        let api = api()
        try await api.login()
        cloud.update { $0.validToken = "rotated" }
        async let first = api.homes()
        async let second = api.homes()
        #expect(try await first == ["home-1"])
        #expect(try await second == ["home-1"])
        #expect(cloud.state.withLockedValue { $0.refreshCount } == 1)
        let (token, refresh) = (await api.accessToken, await api.refreshToken)
        #expect(token == "access-token-2" && refresh == "refresh-token-2")

        // A plain HTTP 401 is refreshed too.
        cloud.update {
            $0.validToken = "rotated-again"
            $0.httpTokenErrors = true
        }
        #expect(try await api.homes() == ["home-1"])
        #expect(cloud.state.withLockedValue { $0.refreshCount } == 2)

        // A refresh that fails fails the request.
        cloud.update {
            $0.validToken = "gone"
            $0.failRefresh = true
        }
        await #expect(throws: (any Error).self) { try await api.homes() }
    }

    @Test func listsDevicesAndGroupsOfEveryHome() async throws {
        cloud.update {
            $0.homes = ["home-1", "home-2"]
            $0.devices = [device("1000aaaaaa", uiid: 1), device("1000bbbbbb", uiid: 0)]
            $0.groups = [["id": "group-1", "name": "Group", "params": ["switch": "off"]]]
        }
        let api = api()
        try await api.login()
        let (devices, groups) = try await api.devices()
        // Each home lists the same fake things; a thing without a UIID is not a device.
        #expect(devices.map(\.deviceid) == ["1000aaaaaa", "1000aaaaaa"])
        #expect(groups.count == 2 && groups[0]["id"] == "group-1")
        let request = try #require(cloud.requests(path: "/v2/device/thing").first)
        #expect(request.url.query?.contains("familyid=home-1") == true && request.url.query?.contains("num=0") == true)
        #expect(request.header("Authorization") == "Bearer access-token-1")
    }

    @Test func sendsStatusUpdates() async throws {
        let api = api()
        try await api.login()
        #expect(await api.updateDevice("1000aaaaaa", params: ["switch": "on"]))
        #expect(await api.updateGroup("group-1", params: ["switch": "off"]))
        #expect(await api.setDeviceState("1000aaaaaa", params: ["switch": "on"]))
        let bodies = try cloud.requests(path: "/v2/device/thing/status").map { try JSONValue(data: $0.body ?? Data()) }
        #expect(bodies[0] == ["type": 1, "id": "1000aaaaaa", "params": ["switch": "on"]])
        #expect(bodies[1] == ["type": 2, "id": "group-1", "params": ["switch": "off"]])
        cloud.update { $0.statusError = 504 }
        #expect(await !api.setDeviceState("1000aaaaaa", params: ["switch": "on"]))
        cloud.update { $0.unreachable = true }
        #expect(await !api.updateDevice("1000aaaaaa", params: [:]))
        #expect(await api.device("1000aaaaaa") == nil)
    }

    @Test func findsTheWebSocketHost() async throws {
        let api = api()
        try await api.login()
        #expect(await api.socketURL() == "wss://eu-pconnect9.coolkit.cc:8080/api/ws")
        cloud.update { $0.dispatchDomain = nil }
        #expect(await api.socketURL() == "wss://eu-pconnect3.coolkit.cc:8080/api/ws")
    }

    @Test func keepsTokensOwnerOnlyForADay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ewelink-tokens-\(UUID().uuidString)")
        let storage = TokenStorage(directory: directory)
        let api = api(storage: storage)
        try await api.login()
        let tokens = try #require(storage.loadValid())
        #expect(tokens.accessToken == "access-token-1" && tokens.region == "eu" && tokens.apiKey == "user-api-key")
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(!storage.isValid(tokens, now: tokens.timestamp + TokenStorage.maximumAge))
        #expect(storage.isValid(tokens, now: tokens.timestamp + TokenStorage.maximumAge - 1))

        let other = CloudAPI(credentials: .init(countryCode: "+1"), transport: cloud, storage: storage, logger: testLogger)
        #expect(await other.reloadTokensFromStorage())
        let (region, token) = (await other.region, await other.accessToken)
        #expect(region == .eu && token == "access-token-1")
        storage.clear()
        #expect(storage.load() == nil)
    }
}

/// The dispatcher's routing and retry rules, against scripted transports.
@Suite(.timeLimit(.minutes(1)))
struct CommandDispatcherTests {
    /// The LAN side of `Transports`.
    struct LAN: LANTransport {
        let transports: Transports
        func sendCommand(_ deviceID: String, params: DeviceParams) async -> Bool {
            transports.state.withLockedValue {
                $0.lanCalls.append(deviceID)
                return $0.lanAnswer
            }
        }
    }

    final class Transports: CloudTransport, GroupTransport, @unchecked Sendable {
        struct State {
            var lanAnswer = false
            var lanCalls: [String] = []
            /// The cloud's answers, in order: true, false (not sent) or an error message; then true.
            var cloudAnswers: [Result<Bool, EWeLinkError>] = []
            var cloudCalls: [String] = []
            var groupCalls: [String] = []
            var queries = 0
            var connected = true
        }

        let state = NIOLockedValueBox(State())

        func sendCommand(_ deviceID: String, params: DeviceParams) async throws -> Bool {
            let answer = state.withLockedValue { state -> Result<Bool, EWeLinkError> in
                state.cloudCalls.append(deviceID)
                return state.cloudAnswers.isEmpty ? .success(true) : state.cloudAnswers.removeFirst()
            }
            return try answer.get()
        }

        func queryDeviceState(_ deviceID: String) async throws -> Bool {
            let fail = state.withLockedValue { state -> Bool in
                state.queries += 1
                return state.queries < 3
            }
            if fail { throw EWeLinkError("Query timeout") }
            return true
        }

        var isConnected: Bool { state.withLockedValue { $0.connected } }

        func updateGroup(_ groupID: String, params: DeviceParams) async -> Bool {
            state.withLockedValue { $0.groupCalls.append(groupID) }
            return true
        }
    }

    @EWeLinkActor
    func dispatcher(mode: String = "auto", lan: Bool = true, cloud: Bool = true, maxQueueSize: Int = 100) -> (CommandDispatcher, Transports) {
        let transports = Transports()
        let registry = DeviceRegistry()
        registry.store(EWeLinkDevice(device("1000aaaaaa", uiid: 2, name: "Lamp"))!)
        registry.store(EWeLinkDevice(device("group-1", uiid: 5000))!)
        var configuration = EWeLinkPlugin.Configuration()
        configuration.mode = mode
        configuration.commandQueueInterval = 0
        let dispatcher = CommandDispatcher(
            configuration: configuration, registry: registry, logger: testLogger, clock: testClock, maxQueueSize: maxQueueSize,
            lan: { lan ? LAN(transports: transports) : nil }, cloud: { cloud ? transports : nil }, groups: { transports })
        return (dispatcher, transports)
    }

    @Test @EWeLinkActor func routesLANFirstThenTheCloud() async {
        let (dispatcher, transports) = dispatcher()
        transports.state.withLockedValue { $0.lanAnswer = true }
        #expect(await dispatcher.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.cloudCalls.isEmpty })
        transports.state.withLockedValue { $0.lanAnswer = false }
        #expect(await dispatcher.sendDeviceCommand("1000aaaaaaSW1", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.cloudCalls } == ["1000aaaaaaSW1"])
        #expect(await !dispatcher.sendDeviceCommand("unknown", ["switch": "on"]))
        #expect(await dispatcher.sendDeviceCommand("group-1", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.groupCalls } == ["group-1"])

        let (wan, wanTransports) = self.dispatcher(mode: "wan")
        #expect(await wan.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
        #expect(wanTransports.state.withLockedValue { $0.lanCalls.isEmpty })

        let (lanOnly, _) = self.dispatcher(mode: "lan", cloud: false)
        #expect(await !lanOnly.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
    }

    @Test @EWeLinkActor func retriesOnlyWhatIsSafeToResend() async {
        // Not delivered: retried.
        var (dispatcher, transports) = dispatcher(lan: false)
        transports.state.withLockedValue { $0.cloudAnswers = [.success(false), .failure(EWeLinkError("WebSocket not ready")), .success(true)] }
        #expect(await dispatcher.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.cloudCalls.count } == 3)

        // Lost in flight: never resent.
        (dispatcher, transports) = self.dispatcher(lan: false)
        transports.state.withLockedValue { $0.cloudAnswers = [.failure(EWeLinkError(CloudSocket.inFlightLostMessage))] }
        #expect(await !dispatcher.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.cloudCalls.count } == 1)

        // A timeout is retried once.
        (dispatcher, transports) = self.dispatcher(lan: false)
        transports.state.withLockedValue { $0.cloudAnswers = [.failure(EWeLinkError("Command timeout")), .failure(EWeLinkError("Command timeout"))] }
        #expect(await !dispatcher.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.cloudCalls.count } == 2)

        // Rejected by the server: not retried.
        (dispatcher, transports) = self.dispatcher(lan: false)
        transports.state.withLockedValue { $0.cloudAnswers = [.failure(EWeLinkError("Command failed: 504"))] }
        #expect(await !dispatcher.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.cloudCalls.count } == 1)

        // Never connected: gives up after three attempts.
        (dispatcher, transports) = self.dispatcher(lan: false)
        transports.state.withLockedValue { $0.cloudAnswers = [.success(false), .success(false), .success(false)] }
        #expect(await !dispatcher.sendDeviceCommand("1000aaaaaa", ["switch": "on"]))
        #expect(transports.state.withLockedValue { $0.cloudCalls.count } == 3)
    }

    @Test @EWeLinkActor func queriesRetry() async {
        let (dispatcher, transports) = dispatcher()
        #expect(await dispatcher.queryDeviceState("1000aaaaaa"))
        #expect(transports.state.withLockedValue { $0.queries } == 3)
        transports.state.withLockedValue { $0.connected = false }
        #expect(await !dispatcher.queryDeviceState("1000aaaaaa"))
        #expect(dispatcher.curtainStaggerDelay() == 1000 && dispatcher.curtainStaggerDelay() == 2000)
    }

    @Test @EWeLinkActor func theQueueDropsTheOldestBeyondItsSize() async throws {
        let queue = CommandQueue(minInterval: 0, concurrency: 1, maxSize: 2, clock: testClock)
        let gate = NIOLockedValueBox(false)
        // Each command is in the queue before the next is sent: tasks started together may run in any order.
        let running = Task { try await queue.enqueue("a") { while !gate.withLockedValue({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }; return true } }
        #expect(await eventually { await queue.activeCount == 1 })
        let second = Task { try await queue.enqueue("b") { true } }
        #expect(await eventually { await queue.queuedCount == 1 })
        let third = Task { try await queue.enqueue("c") { true } }
        #expect(await eventually { await queue.queuedCount == 2 })
        let fourth = Task { try await queue.enqueue("d") { true } }
        await #expect(throws: CommandQueue.OverflowError.self) { try await second.value }
        gate.withLockedValue { $0 = true }
        let results = (try await running.value, try await third.value, try await fourth.value)
        #expect(results == (true, true, true))

        // Ten real seconds between commands: the second is still queued however long a loaded runner takes to look.
        let blocked = CommandQueue(minInterval: 10_000, concurrency: 1, clock: EWeLinkClock())
        _ = try await blocked.enqueue("x") { true }
        let waiting = Task { try await blocked.enqueue("y") { true } }
        #expect(await eventually { await blocked.queuedCount == 1 })
        blocked.clear()
        await #expect(throws: EWeLinkError("Queue cleared")) { try await waiting.value }

        // A concurrency of 0 (config.json) still runs commands.
        let none = CommandQueue(minInterval: 0, concurrency: 0, clock: testClock)
        #expect(none.concurrency == 1)
        #expect(try await none.enqueue("z") { true })
    }
}

/// LAN control against the fake network.
@Suite(.timeLimit(.minutes(1)))
struct LANControlTests {
    let network = FakeLAN()
    let updates = NIOLockedValueBox<[(String, DeviceParams)]>([])
    let keys = NIOLockedValueBox<[String: String]>(["1000aaaaaa": "a1b2c3d4-e5f6-7890-abcd-ef0123456789"])

    func control() -> LANControl {
        let updates = updates, keys = keys
        return LANControl(
            dependencies: .init(network: network, clock: testClock), logger: testLogger, selfAPIKey: { "user-api-key" },
            deviceInfo: { id in keys.withLockedValue { $0[id] }.map { (name: "Lamp", deviceKey: $0) } },
            knownDevices: { [] }, onUpdate: { id, params in updates.withLockedValue { $0.append((id, params)) } })
    }

    @Test func sendsEncryptedCommandsAndFallsBackAfterFailures() async throws {
        let lan = control()
        #expect(await !lan.sendCommand("1000aaaaaa", params: ["switch": "on"]))
        await lan.registerDevice("1000aaaaaa", ip: "10.0.0.5", port: 8081, deviceKey: "", encrypt: true)
        await lan.registerDevice("1000bbbbbb", ip: "", port: 8081, deviceKey: "k")
        #expect(await !lan.isDeviceAvailable("1000bbbbbb"))
        // The key comes lazily from the device cache.
        #expect(await lan.sendCommand("1000aaaaaaSW1", params: ["switch": "on"]))
        let post = try #require(network.posts.last)
        #expect(post.url.absoluteString == "http://10.0.0.5:8081/zeroconf/switch")
        #expect(post.body["encrypt"] == true && post.body["deviceid"] == "1000aaaaaa")
        let decrypted = LANControl.decrypt(try #require(post.body["data"]?.stringValue), deviceKey: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", iv: try #require(post.body["iv"]?.stringValue))
        #expect(decrypted == ["switch": "on"])

        // Three failures in a row: the device is skipped for a minute.
        network.update { $0.answer = 400 }
        for _ in 0..<3 { #expect(await !lan.sendCommand("1000aaaaaa", params: ["switch": "on"])) }
        network.update { $0.answer = 0 }
        let count = network.posts.count
        #expect(await !lan.sendCommand("1000aaaaaa", params: ["switch": "on"]))
        #expect(network.posts.count == count)
        #expect(await lan.isInCooldown("1000aaaaaa"))
        // An announcement makes LAN worth trying again.
        await lan.handle(.found(name: "eWeLink_1000aaaaaa", addresses: ["fe80::1", "10.0.0.5"], port: 8081, txt: ["encrypt": "true"]))
        #expect(await lan.sendCommand("1000aaaaaa", params: ["switch": "on"]))
        await lan.handle(.lost(name: "eWeLink_1000aaaaaa"))
        #expect(await lan.isInCooldown("1000aaaaaa"))
    }

    @Test func discoversDevicesOverMDNS() async throws {
        let lan = control()
        await lan.handle(.found(name: "eWeLink_1000aaaaaa", addresses: ["fe80::1", "10.0.0.7"], port: 0, txt: ["encrypt": "true", "iv": "abc"]))
        let device = try #require(await lan.lanDevice("1000aaaaaa"))
        #expect(device.ip == "10.0.0.7" && device.port == 8081 && device.encrypt && device.deviceKey == "a1b2c3d4-e5f6-7890-abcd-ef0123456789")
        await lan.handle(.found(name: "Something else", addresses: ["10.0.0.8"], port: 80, txt: [:]))
        await lan.handle(.found(name: "eWeLink_1000cccccc", addresses: [], port: 80, txt: [:]))
        #expect(await lan.devices.count == 1)
        // An API registration does not move a device mDNS found.
        await lan.registerDevice("1000aaaaaa", ip: "10.0.0.99", port: 8081, deviceKey: "x", encrypt: false)
        #expect(await lan.lanDevice("1000aaaaaa")?.ip == "10.0.0.7")
        // Announced encrypted, a device stays encrypted whatever a later announcement (anyone's) says.
        await lan.handle(.found(name: "eWeLink_1000aaaaaa", addresses: ["10.0.0.66"], port: 8081, txt: [:]))
        #expect(await lan.lanDevice("1000aaaaaa")?.encrypt == true)
    }

    @Test func acceptsUDPUpdatesThatAuthenticate() async throws {
        let lan = control()
        await lan.start()
        defer { Task { await lan.stop() } }
        await lan.registerDevice("1000aaaaaa", ip: "10.0.0.5", port: 8081, deviceKey: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", encrypt: true)
        await lan.registerDevice("1000bbbbbb", ip: "10.0.0.6", port: 8081, deviceKey: "", encrypt: false)
        await lan.handle(.found(name: "eWeLink_1000bbbbbb", addresses: ["10.0.0.6"], port: 8081, txt: [:]))

        // Plaintext from an encrypted device, or from the wrong address, does not count.
        network.deliver(["action": "update", "deviceid": "1000aaaaaa", "params": ["switch": "on"]], from: "10.0.0.5")
        network.deliver(["action": "update", "deviceid": "1000bbbbbb", "params": ["switch": "on"]], from: "10.0.0.66")
        network.deliver(["action": "update", "deviceid": "1000bbbbbb", "params": ["switch": "off"]], from: "10.0.0.6")
        #expect(await eventually { updates.withLockedValue { $0.count } == 1 })
        #expect(updates.withLockedValue { $0[0].0 == "1000bbbbbb" && $0[0].1 == ["switch": "off"] })

        // An encrypted update decrypts with the key: it counts from any address, but a replayed datagram from
        // another host does not move where commands go.
        let iv = Data("0123456789abcdef".utf8)
        let data = try #require(LANControl.encrypt(["switch": "on"], deviceKey: "a1b2c3d4-e5f6-7890-abcd-ef0123456789", iv: iv))
        network.deliver(["action": "update", "deviceid": "1000aaaaaa", "encrypt": true, "iv": .string(iv.base64EncodedString()), "data": .string(data)], from: "10.0.0.50")
        #expect(await eventually { updates.withLockedValue { $0.count } == 2 })
        #expect(updates.withLockedValue { $0[1].0 == "1000aaaaaa" && $0[1].1 == ["switch": "on"] })
        #expect(await lan.lanDevice("1000aaaaaa")?.ip == "10.0.0.5")
        network.deliver(["action": "update", "deviceid": "1000aaaaaa", "encrypt": true, "iv": .string(iv.base64EncodedString()), "data": "garbage"], from: "10.0.0.51")
        try await Task.sleep(for: .milliseconds(50))
        #expect(updates.withLockedValue { $0.count } == 2)
        #expect(await lan.lanDevice("1000aaaaaa")?.ip == "10.0.0.5")
        // mDNS moves it.
        await lan.handle(.found(name: "eWeLink_1000aaaaaa", addresses: ["10.0.0.50"], port: 8081, txt: ["encrypt": "true"]))
        #expect(await lan.lanDevice("1000aaaaaa")?.ip == "10.0.0.50")
    }

    @Test func stopDuringStartLeavesNothingListening() async throws {
        let network = SlowLAN()
        let lan = LANControl(
            dependencies: .init(network: network, clock: testClock), logger: testLogger, selfAPIKey: { "" }, deviceInfo: { _ in nil },
            knownDevices: { [] }, onUpdate: { _, _ in })
        let starting = Task { await lan.start() }
        #expect(await eventually { network.state.withLockedValue { $0.waiting } })
        await lan.stop()
        network.state.withLockedValue { $0.release = true }
        await starting.value
        #expect(network.listener.closed.withLockedValue { $0 })
    }
}
