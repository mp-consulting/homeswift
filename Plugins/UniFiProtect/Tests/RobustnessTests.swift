import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// What the review of the port found: stops that come during a start, numbers that trapped, payloads that wiped
/// a device's JSON, sockets opened twice, and the routes the Assistant calls.
@Suite(.timeLimit(.minutes(1)), .serialized) struct RobustnessTests {
    static let sensorID = ProtectPlatform.accessoryID(Fixtures.sensorMAC)
    static let doorbellID = ProtectPlatform.accessoryID(Fixtures.doorbellMAC)

    // MARK: Lifecycle

    @Test func stopDuringStartupStartsNothing() async throws {
        let environment = ProtectTestEnvironment()
        // A slow controller: the bootstrap takes a while.
        environment.controller.update { $0.delays["/proxy/protect/api/bootstrap"] = .milliseconds(300) }
        let host = try environment.host(settings: ProtectTestEnvironment.block())
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { !environment.controller.requests("/proxy/protect/api/bootstrap").isEmpty })
        let plugin = try #require(environment.plugin)
        await plugin.stop()
        try await Task.sleep(for: .milliseconds(800))
        // The bootstrap that came after the stop published nothing and opened no events WebSocket.
        #expect(environment.accessory(host, Self.sensorID) == nil)
        #expect(!environment.webSockets.connections.contains { $0.path.contains("updates") && !$0.isClosed })
        #expect(await plugin.nvrs.first?.deviceList.isEmpty == true)
    }

    /// A WebSocket factory that waits for the test before it connects.
    final class GatedSockets: @unchecked Sendable {
        let sockets = FakeWebSocketConnector()
        let calls = NIOLockedValueBox(0)
        private let gate: AsyncStream<Void>
        private let opener: AsyncStream<Void>.Continuation

        init() {
            (gate, opener) = AsyncStream.makeStream(of: Void.self)
        }

        func open() { opener.yield() }

        var factory: ProtectWebSocketFactory {
            { url, options in
                self.calls.withLockedValue { $0 += 1 }
                var iterator = self.gate.makeAsyncIterator()
                _ = await iterator.next()
                return try await self.sockets.factory(url, options)
            }
        }
    }

    func api(_ controller: FakeController, _ sockets: GatedSockets) -> ProtectAPI {
        ProtectAPI(log: ProtectLog(logger: LogCapture().logger), options: .init(transport: controller, webSockets: sockets.factory, timeScale: 0.01))
    }

    @Test func eventsConnectOnceForConcurrentCallers() async throws {
        let controller = FakeController()
        let sockets = GatedSockets()
        let api = api(controller, sockets)
        #expect(await api.login(address: "192.168.1.1", username: "homeswift", password: "secret"))
        async let first = api.connectEvents()
        async let second = api.connectEvents()
        #expect(await eventually { sockets.calls.withLockedValue { $0 } >= 1 })
        try await Task.sleep(for: .milliseconds(50))
        sockets.open()
        sockets.open()
        let results = await [first, second]
        #expect(results == [true, true])
        #expect(sockets.calls.withLockedValue { $0 } == 1)
        #expect(sockets.sockets.connections.count == 1)
        await api.logout()
    }

    @Test func aLogoutWhileEventsConnectKeepsThemClosed() async throws {
        let controller = FakeController()
        let sockets = GatedSockets()
        let api = api(controller, sockets)
        #expect(await api.login(address: "192.168.1.1", username: "homeswift", password: "secret"))
        let connecting = Task { await api.connectEvents() }
        #expect(await eventually { sockets.calls.withLockedValue { $0 } == 1 })
        await api.logout()
        sockets.open()
        #expect(await connecting.value == false)
        #expect(await !api.isEventsConnected)
        #expect(await !api.isLoggedIn)
        #expect(await eventually { sockets.sockets.last?.isClosed == true })
    }

    @Test func playlistClosedWhileItBinds() async throws {
        let api = ProtectAPI(log: ProtectLog(logger: LogCapture().logger))
        let server = ProtectPlaylistServer(api: api, log: ProtectLog(logger: LogCapture().logger), address: "127.0.0.1", port: 0, token: "token")
        async let started: Void = server.start()
        await server.close()
        await started
        #expect(await server.listeningPort == nil)
        // Started again after the close: nothing.
        await server.start()
        #expect(await server.listeningPort == nil)
    }

    /// With no address, the playlist answers on every interface, IPv6 included (Node's `server.listen(port)`); a host
    /// without IPv6 falls back to IPv4 alone.
    @Test func playlistListensOnIPv4AndIPv6() async throws {
        let api = ProtectAPI(log: ProtectLog(logger: LogCapture().logger))
        let server = ProtectPlaylistServer(api: api, log: ProtectLog(logger: LogCapture().logger), address: nil, port: 0, token: "secret")
        await server.start()
        let port = try #require(await server.listeningPort)
        defer { Task { await server.close() } }
        let client = HTTPClient()
        func status(_ host: String, token: String) async throws -> Int {
            try await client.send(HTTPRequest(url: try #require(URL(string: "http://\(host):\(port)/?token=\(token)")), timeout: .seconds(5))).status
        }
        #expect(try await status("127.0.0.1", token: "secret") == 200)
        #expect(try await status("127.0.0.1", token: "wrong") == 401)
        if await server.isListeningOnIPv6 {
            #expect(try await status("[::1]", token: "secret") == 200)
        }
        #if os(macOS)
        // macOS always has IPv6 on loopback.
        #expect(await server.isListeningOnIPv6)
        #endif
    }

    // MARK: Hostile numbers and payloads

    @Test func hugeNumbersDoNotTrap() throws {
        #expect(JSONValue.object(["value": 1e300]).int("value") == Int.max)
        #expect(JSONValue.object(["value": -1e300]).int("value") == Int.min)
        #expect(JSONValue.object(["value": 12.7]).int("value") == 12)
        #expect(jsNumber(1e300) == String(1e300) && jsNumber(.infinity) == "inf" && jsNumber(42) == "42" && jsNumber(2.5) == "2.5")
        #expect(DoorbellLcdMessages.mqttDuration(1e300, default: 60000) == Int.max)
        #expect(formatBps(.infinity).hasSuffix("Mbps"))
        let settings = try JSONSerialization.data(withJSONObject: ["controllers": [["address": "a", "username": "u", "password": "p",
                                                                                     "cameraOverrides": [["mac": "aa", "onvifPort": 1e300]]]],
                                                                    "ringDelay": 1e300])
        let configuration = try JSONDecoder().decode(UniFiProtectPlugin.Configuration.self, from: settings)
        #expect(configuration.ringDelay == 86_400)
        #expect(configuration.controllers.first?.cameraOverrides.first?.onvifPort == Int.max)
    }

    @Test func hugeFeatureOptionNumbers() async throws {
        let environment = ProtectTestEnvironment()
        // Four hundred digits: infinity as a Double.
        let huge = String(repeating: "9", count: 400)
        let host = try await environment.start(options: ["Enable.Motion.Duration.\(huge)", "Enable.Motion.OccupancySensor", "Enable.Motion.OccupancySensor.Duration.\(huge)",
                                                         "Enable.Nvr.DelayDeviceRemoval.\(huge)"])
        defer { Task { await host.stop() } }
        let sensor = try #require(await environment.device("sensor-id"))
        #expect(await sensor.hints.motionDuration == ProtectSettings.durationRange.upperBound)
        // A motion event arms its reset timer without overflowing.
        environment.update("sensor", id: "sensor-id", ["isMotionDetected": true, "motionDetectedAt": 1_700_000_000_000])
        let accessory = try #require(environment.accessory(host, Self.sensorID))
        #expect(await eventually { accessory.service(.motionSensor)?[.motionDetected]?.value == .bool(true) })
    }

    @Test func updatesThatAreNotObjectsKeepTheDevice() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let before = try #require(await environment.device("sensor-id")?.ufp)
        environment.update("sensor", id: "sensor-id", .null)
        environment.update("sensor", id: "sensor-id", [1, 2])
        environment.update("nvr", id: "nvr-id", "text")
        // A real update after them, to know they were handled.
        environment.update("sensor", id: "sensor-id", ["isOpened": true])
        #expect(await eventually { await environment.device("sensor-id")?.ufp.json.bool("isOpened") == true })
        let after = try #require(await environment.device("sensor-id")?.ufp)
        #expect(after.mac == before.mac && after.name == before.name && after.json.at("batteryStatus") == before.json.at("batteryStatus"))
        #expect(await environment.plugin?.nvrs.first?.mac == Fixtures.nvrMAC)
    }

    @ProtectActor func chimes(_ environment: ProtectTestEnvironment) async -> [JSONValue] {
        await environment.plugin?.nvrs.first?.api.bootstrap?.array("chimes") ?? []
    }

    @Test func chimeUpdatesWithoutAnIdReplaceTheirChime() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: ["Enable.Doorbell.Volume.Dimmer"], waitFor: Self.doorbellID)
        defer { Task { await host.stop() } }
        let doorbell = try #require(environment.accessory(host, Self.doorbellID))
        let volume = try #require(doorbell.service(.lightbulb, ProtectReservedNames.lightbulbDoorbellVolume))
        // The payload of an update carries what changed, not the chime's id: the packet's header has it.
        environment.update("chime", id: "chime-id", [
            "nvrMac": .string(Fixtures.nvrMAC), "cameraIds": ["doorbell-id"],
            "ringSettings": [["cameraId": "doorbell-id", "ringtoneId": "tone-1", "volume": 40, "repeatTimes": 1]],
        ])
        #expect(await eventually { volume[.brightness]?.value == .int(40) })
        let chimes = await chimes(environment)
        #expect(chimes.count == 1)
        #expect(chimes.first?.string("id") == "chime-id" && chimes.first?.array("ringSettings").first?.int("volume") == 40)
    }

    // MARK: The settings page

    @Test func settingsPageDevicesUseThePinAndTheSavedPassword() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let devices = { (body: JSONValue) in try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "devices", body: body, user: "admin")) }
        // A configured controller: the saved password, over the pinned certificate.
        let answer = try await devices(["address": "192.168.1.1", "username": "homeswift"])
        #expect(answer.json["devices"]?.arrayValue?.count == 7)
        let pinned = try #require(environment.controller.requests("/api/auth/login").last)
        guard case .pinned(let fingerprint) = pinned.tls else {
            Issue.record("The page's login was not pinned: \(pinned.tls)")
            return
        }
        #expect(HTTPClient.normalizeFingerprint(fingerprint) == HTTPClient.normalizeFingerprint(FakeController.fingerprint))
        // Someone else answers at that address: nothing is sent, the password least of all.
        environment.controller.update { $0.certificate = FakeController.otherFingerprint }
        let logins = environment.controller.requests("/api/auth/login").count
        let refused = try await devices(["address": "192.168.1.1", "username": "homeswift", "password": "secret"])
        #expect(refused.json["devices"]?.arrayValue?.isEmpty == true)
        #expect(environment.controller.requests("/api/auth/login").count == logins)
    }

    // MARK: Assistant actions

    func call(_ plugin: UniFiProtectPlugin, _ name: String, _ arguments: JSONValue = [:]) async throws -> PluginWebResponse {
        let action = try #require(UniFiProtectPlugin.assistantActions.first { $0.name == name })
        return try await plugin.handleWebRequest(action.request(arguments: arguments, user: "admin"))
    }

    @Test func assistantActionsReachTheirRoutes() async throws {
        let console = UbiquitiDiscovery.Console(firmware: "4.1.13", ip: "192.168.1.1", mac: "00:11:22:33:44:55", model: "UNVR", modelLong: "UniFi Network Video Recorder", name: "Home NVR")
        let environment = ProtectTestEnvironment(discovered: [console])
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(Set(UniFiProtectPlugin.assistantActions.map(\.name)) == ["list_controllers", "list_options", "discover", "check_controller"])
        #expect(UniFiProtectPlugin.assistantActions.allSatisfy { $0.access == .read && !$0.confirm })

        let controllers = try await call(plugin, "list_controllers")
        #expect(controllers.status == 200)
        let controller = try #require(controllers.json["controllers"]?[0])
        #expect(controller["address"] == "192.168.1.1" && controller["connected"] == true)
        let devices = try #require(controller["devices"]?.arrayValue)
        let sensor = try #require(devices.first { $0["mac"]?.stringValue == Fixtures.sensorMAC })
        #expect(sensor["accessoryID"]?.stringValue == Self.sensorID && sensor["modelKey"] == "sensor" && sensor["online"] == true)

        let options = try await call(plugin, "list_options")
        #expect(options.json["categories"]?.arrayValue?.isEmpty == false)

        let discover = try await call(plugin, "discover")
        #expect(discover.json["devices"]?[0]?["ip"] == "192.168.1.1" && discover.json["devices"]?[0]?["name"] == "Home NVR")

        let online = try await call(plugin, "check_controller", ["address": "192.168.1.1"])
        #expect(online.json["online"] == true)
        let blocked = try await call(plugin, "check_controller", ["address": "127.0.0.1"])
        #expect(blocked.json["online"] == false)
    }
}
