import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftDysonPureCool

/// The Homebridge plugin's mqttClient and dysonLinkDevice tests, against the in-memory device.
@Suite(.timeLimit(.minutes(1)))
struct MQTTClientTests {
    let dyson = FakeDyson(productState: FakeStates.tp04)

    func client(autoReconnect: Bool = true, timeout: Duration = .seconds(2)) -> DysonMQTTClient {
        DysonMQTTClient(
            settings: .init(host: "192.168.1.50", serial: "ABC-AB-12345678", credentials: "secret", productType: "438", timeout: timeout, autoReconnect: autoReconnect),
            mqtt: dyson.mqtt, backoff: { _ in .milliseconds(10) })
    }

    @Test func connectsWithTheSerialAndCredentials() async throws {
        let client = client()
        try await client.connect()
        try await client.subscribeToStatus()
        let options = try #require(dyson.connects.first)
        #expect(options.host == "192.168.1.50")
        #expect(options.port == 1883)
        #expect(options.username == "ABC-AB-12345678")
        #expect(options.password == "secret")
        #expect(options.clientID.hasPrefix("homebridge_ABC-AB-12345678_"))
        #expect(options.protocolVersion == .v3_1_1)
        #expect(options.cleanSession)
        #expect(options.keepAlive == .seconds(30))
        #expect(options.reconnect == nil)
        #expect(dyson.subscriptions == ["438/ABC-AB-12345678/status/current"])
        #expect(await client.activeVariant?.label == "default")
        try await client.requestCurrentState()
        #expect(dyson.published.last?.topic == "438/ABC-AB-12345678/command")
        #expect(dyson.published.last?.json["msg"] == "REQUEST-CURRENT-STATE")
        await client.disconnect()
        #expect(await client.topics.isEmpty)
    }

    @Test func reachesAnMQTT5OnlyBroker() async throws {
        dyson.set(onlyVersion: .v5)
        let client = client()
        try await client.connect()
        #expect(await client.activeVariant?.label == "mqtt5-short-id")
        #expect(dyson.connects.map(\.protocolVersion) == [.v3_1_1, .v3_1_1, .v3_1_1, .v5])
        #expect(dyson.connects.last?.clientID == "ABC-AB-12345678")
    }

    @Test func climbsTheVariantLadderOnIdentifierRejected() async throws {
        dyson.set(refuseLongClientIDs: 2)
        let client = client()
        try await client.connect()
        #expect(await client.activeVariant?.label == "short-id")
        #expect(dyson.connects.map(\.clientID).last == "ABC-AB-12345678")
        #expect(dyson.connects.count == 2)
    }

    @Test func otherFailuresDoNotClimb() async throws {
        dyson.set(refuseAll: DysonMQTTError.unreachable("connect ECONNREFUSED"))
        let client = client()
        await #expect(throws: DysonMQTTError.unreachable("connect ECONNREFUSED")) { try await client.connect() }
        #expect(dyson.connects.count == 1)
        dyson.set(refuseAll: MQTTError.connectionRefused(code: 5))
        await #expect(throws: DysonMQTTError.refused(code: 5)) { try await client.connect() }
        // Every variant, the MQTT 5 one included, reaches the device.
        #expect(dyson.connects.count == 1 + DysonMQTTClient.variants.count)
        #expect(dyson.connects.map(\.protocolVersion).suffix(2) == [.v5, .v3_1])
        #expect(DysonMQTTClient.isRecoverable(DysonMQTTError.refused(code: 4)))
        #expect(!DysonMQTTClient.isRecoverable(DysonMQTTError.timeout(.seconds(10))))
        // As the plugin's patterns: "Server unavailable" does not climb, in either numbering.
        #expect(!DysonMQTTClient.isRecoverable(DysonMQTTError.refused(code: 3)))
        #expect(!DysonMQTTClient.isRecoverable(DysonMQTTError.refused(code: 0x88)))
        #expect(DysonMQTTClient.isRecoverable(DysonMQTTError.refused(code: 0x86)))
        #expect(DysonMQTTError.refused(code: 0x86).description == "Connection refused: Bad User Name or Password")
        #expect(DysonMQTTError.refused(code: 0x85).description == "Connection refused: Client Identifier not valid")
        #expect(DysonMQTTError.refused(code: 2).description == "Connection refused: Identifier rejected")
    }

    @Test func timesOut() async throws {
        /// A broker that never answers the CONNECT.
        final class Silent: MQTTConnection {
            func connect() async throws { try await Task.sleep(for: .seconds(30)) }
            func disconnect() async {}
            func subscribe(_ topic: String, qos: MQTTQoS) async throws {}
            func unsubscribe(_ topic: String) async throws {}
            func publish(_ message: MQTTMessage) async throws {}
            var messages: AsyncStream<MQTTMessage> { AsyncStream { _ in } }
            var states: AsyncStream<MQTTConnectionState> { AsyncStream { _ in } }
        }
        let client = DysonMQTTClient(settings: .init(host: "192.168.1.50", serial: "S", credentials: "c", productType: "438", timeout: .milliseconds(100)), mqtt: { _ in Silent() })
        await #expect(throws: DysonMQTTError.timeout(.milliseconds(100))) { try await client.connect() }
    }

    @Test func reconnectsAndResubscribes() async throws {
        let client = client()
        let events = NIOLockedValueBox<[String]>([])
        let stream = client.events
        let reader = Task {
            for await event in stream {
                switch event {
                case .connected: events.withLockedValue { $0.append("connected") }
                case .disconnected: events.withLockedValue { $0.append("disconnected") }
                case .reconnecting(let attempt): events.withLockedValue { $0.append("reconnecting \(attempt)") }
                case .reconnectFailed: events.withLockedValue { $0.append("failed") }
                default: break
                }
            }
        }
        defer { reader.cancel() }
        try await client.connect()
        try await client.subscribeToStatus()
        dyson.dropConnections()
        #expect(await eventually { await client.isConnected && dyson.subscriptions.count == 2 })
        // The reader records events on its own task: wait for it rather than read it right away.
        #expect(await eventually { events.withLockedValue { $0 } == ["connected", "disconnected", "reconnecting 1", "connected"] })

        // A device that stays away: five attempts, then the client gives up.
        dyson.set(refuseAll: MQTTError.protocolError("EHOSTUNREACH"))
        dyson.dropConnections()
        #expect(await eventually { events.withLockedValue { $0.last } == "failed" })
        #expect(events.withLockedValue { $0.filter { $0.hasPrefix("reconnecting") } }.count == 1 + 5)
        #expect(await !client.isConnected)
        await client.disconnect()
    }

    /// disconnect() while the CONNECT is in flight: the connection that lands afterwards is closed, not kept.
    @Test func aDisconnectDuringTheConnectWins() async throws {
        let gate = Gate()
        dyson.set(connectGate: gate)
        let client = client(timeout: .seconds(20))
        let connecting = Task { try await client.connect() }
        #expect(await eventually { await gate.arrivals == 1 })
        await client.disconnect()
        await gate.open()
        await #expect(throws: DysonMQTTError.notConnected) { try await connecting.value }
        #expect(await !client.isConnected)
        #expect(dyson.openConnections.isEmpty)
        // The ladder does not go on to the next variant.
        #expect(dyson.connects.count == 1)
        // A later connect() works again.
        try await client.connect()
        #expect(await client.isConnected)
        await client.disconnect()
    }

    @Test func noReconnectionAfterAnIntentionalDisconnect() async throws {
        let client = client()
        try await client.connect()
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(dyson.connects.count == 1)
        #expect(DysonMQTTClient.exponentialBackoff(attempt: 0) == .seconds(1))
        #expect(DysonMQTTClient.exponentialBackoff(attempt: 4) == .seconds(16))
        #expect(DysonMQTTClient.exponentialBackoff(attempt: 5) == .seconds(30))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DeviceTests {
    func connected(_ productType: String = "438", state: [String: String] = FakeStates.tp04) async throws -> (DysonDevice, FakeDyson) {
        let dyson = FakeDyson(productState: state)
        let device = DysonDevice(serial: "ABC-AB-12345678", productType: productType, name: "Fan", credentials: "secret", ipAddress: "192.168.1.50", mqtt: dyson.mqtt, logger: testLogger)
        try await device.connect()
        #expect(await eventually { await device.state.connected && dyson.published.count >= 1 })
        // The CURRENT-STATE answer has landed once anything but the connection differs from a blank state: a fan
        // speed alone is not enough, an off fan in auto mode reports 0.
        let blank = { var state = DeviceState(); state.connected = true; return state }()
        _ = await eventually { await device.state != blank || state.isEmpty }
        dyson.clearPublished()
        return (device, dyson)
    }

    @Test func connectReadsTheState() async throws {
        let (device, _) = try await connected()
        let state = await device.state
        #expect(state.isOn && state.fanSpeed == 5 && state.oscillation && state.temperature == 2951)
        #expect(state.connected)
    }

    /// The plugin's stop() disconnects devices that may still be connecting.
    @Test func aDisconnectDuringTheConnectLeavesNothingOpen() async throws {
        let dyson = FakeDyson(productState: FakeStates.tp04)
        let gate = Gate()
        dyson.set(connectGate: gate)
        let device = DysonDevice(serial: "ABC-AB-12345678", productType: "438", name: "Fan", credentials: "secret", ipAddress: "192.168.1.50", mqtt: dyson.mqtt, logger: testLogger)
        let connecting = Task { try await device.connect() }
        #expect(await eventually { await gate.arrivals == 1 })
        await device.disconnect()
        await gate.open()
        await #expect(throws: DysonMQTTError.notConnected) { try await connecting.value }
        #expect(await !device.isConnected)
        #expect(await !device.state.connected)
        #expect(dyson.openConnections.isEmpty)
        #expect(dyson.published.isEmpty)
    }

    /// Only state changes move the accessory: a connection does not re-read the state from a task, which could
    /// land after a newer state (the cause of a rare stale Active in the plugin tests).
    @Test func aConnectionDoesNotReapplyAnOlderState() async throws {
        let device = DysonDevice(serial: "ABC-AB-12345678", productType: "358H", name: "Fan", credentials: "c", ipAddress: "192.168.1.5", mqtt: FakeDyson().mqtt, logger: testLogger)
        let accessory = await DysonAccessory(
            device: device, id: "DysonPureCool:ABC-AB-12345678", name: "Fan", options: DeviceOptions(), firmwareVersion: nil, cached: nil, logger: testLogger)
        let humidifier = try #require(accessory.humidifier)
        // The device's own state is still empty (humidifier off); the accessory was told of a newer one.
        var state = DeviceState()
        state.connected = true
        state.humidifierEnabled = true
        accessory.handle(.stateChanged(state))
        accessory.handle(.connected)
        try await Task.sleep(for: .milliseconds(100))
        #expect(humidifier[.active]?.value == .int(1))
    }

    @Test func connectNeedsAnAddress() async throws {
        let device = DysonDevice(serial: "S", productType: "438", name: "Fan", credentials: "c", ipAddress: nil, mqtt: FakeDyson().mqtt, logger: testLogger)
        await #expect(throws: DysonMQTTError.self) { try await device.connect() }
    }

    /// The Link series (HP02, TP02, DP01) takes power and mode through `fmod`, jet focus through `ffoc`.
    @Test(arguments: ["455", "475", "469"])
    func gen1Commands(productType: String) async throws {
        let (device, dyson) = try await connected(productType, state: ["fmod": "OFF", "fnsp": "0004"])
        try await device.setFanPower(true)
        #expect(dyson.commands.last == ["fmod": "FAN"])
        #expect(await eventually { await device.state.isOn })
        try await device.setFanSpeed(5)
        #expect(dyson.commands.last == ["fmod": "FAN", "fnsp": "0005"])
        try await device.setAutoMode(true)
        #expect(dyson.commands.last == ["fmod": "AUTO"])
        try await device.setJetFocus(true)
        #expect(dyson.commands.last == ["ffoc": "ON"])
        try await device.setFanPower(false)
        #expect(dyson.commands.last == ["fmod": "OFF"])
        #expect(await eventually { await !device.state.isOn })
    }

    /// Every newer model takes power through `fpwr` and the airflow direction through `fdir`, and ignores `fmod`
    /// and `ffoc` (the HP09 in homebridge-dyson-pure-cool#29).
    @Test(arguments: ["527K", "739"])
    func gen2Commands(productType: String) async throws {
        let (device, dyson) = try await connected(productType, state: ["fpwr": "OFF", "fnsp": "0006", "auto": "OFF"])
        try await device.setFanPower(true)
        #expect(dyson.commands.last == ["fpwr": "ON", "auto": "OFF", "fnsp": "0006"])
        #expect(await eventually { await device.state.isOn })
        try await device.setJetFocus(false)
        #expect(dyson.commands.last == ["fdir": "OFF"])
        try await device.setFanPower(false)
        #expect(dyson.commands.last == ["fpwr": "OFF"])
        #expect(await eventually { await !device.state.isOn })
    }

    /// A gen2 model reads power from `fpwr` and the jet focus from `fdir`, whatever `fmod` and `ffoc` say.
    @Test func gen2ReadsItsOwnFields() async throws {
        let (device, _) = try await connected("527K", state: ["fpwr": "ON", "fmod": "FAN", "fdir": "ON", "ffoc": "OFF"])
        #expect(await eventually { let state = await device.state; return state.isOn && state.frontAirflow == true })
        let change: JSONValue = ["msg": "STATE-CHANGE", "product-state": ["fpwr": ["ON", "OFF"], "fmod": "FAN", "ffoc": ["OFF", "ON"]]]
        await device.handleMessage(change.encoded())
        #expect(await !device.state.isOn)
        #expect(await device.state.frontAirflow == true)
    }

    @Test func alreadyOnSendsNothing() async throws {
        let (device, dyson) = try await connected()
        try await device.setFanPower(true)
        #expect(dyson.commands.isEmpty)
    }

    @Test func onAfterAnUnconfirmedOff() async throws {
        let (device, dyson) = try await connected()
        // The device takes the OFF but has not confirmed it yet: the reported state still says on.
        dyson.set(echoesCommands: false)
        try await device.setFanPower(false)
        #expect(await device.state.isOn)
        try await device.setFanPower(true)
        #expect(dyson.commands == [["fpwr": "OFF"], ["fpwr": "ON", "auto": "OFF", "fnsp": "0005"]])
        // Once a state message confirms the power commanded, "already on" holds again.
        let confirmation: JSONValue = ["msg": "STATE-CHANGE", "product-state": ["fpwr": ["OFF", "ON"]]]
        await device.handleMessage(confirmation.encoded())
        try await device.setFanPower(true)
        #expect(dyson.commands.count == 2)
    }

    @Test func activationDefaultsGoInThePowerOnCommand() async throws {
        let (device, dyson) = try await connected(state: ["fpwr": "OFF", "auto": "OFF", "fnsp": "0004"])
        await device.setActivationDefaults(ActivationDefaults(autoMode: true, oscillation: true, nightMode: true))
        try await device.setFanPower(true)
        #expect(dyson.commands == [["fpwr": "ON", "auto": "ON", "fnsp": "AUTO", "oson": "ON", "nmod": "ON"]])

        // Modes the model lacks are not sent: a CF1 has no auto mode.
        let (fan, fanDyson) = try await connected("739", state: ["fpwr": "OFF", "fnsp": "0003", "auto": "OFF"])
        await fan.setActivationDefaults(ActivationDefaults(autoMode: true, oscillation: true, nightMode: false))
        try await fan.setFanPower(true)
        #expect(fanDyson.commands == [["fpwr": "ON", "auto": "OFF", "fnsp": "0003", "oson": "ON"]])
    }

    @Test func speedAndAuto() async throws {
        let (device, dyson) = try await connected()
        try await device.setFanSpeed(7)
        #expect(dyson.commands.last == ["fpwr": "ON", "auto": "OFF", "fnsp": "0007"])
        try await device.setFanSpeed(0)
        #expect(dyson.commands.last == ["fpwr": "ON", "auto": "OFF", "fnsp": "0001"])
        try await device.setFanSpeed(14)
        #expect(dyson.commands.last == ["fpwr": "ON", "auto": "OFF", "fnsp": "0010"])
        try await device.setFanSpeed(-1)
        #expect(dyson.commands.last == ["fpwr": "ON", "auto": "ON", "fnsp": "AUTO"])
        try await device.setAutoMode(false)
        #expect(dyson.commands.last?["auto"] == "OFF")
    }

    @Test func modesRightAfterOffAreDropped() async throws {
        let (device, dyson) = try await connected()
        try await device.setFanPower(false)
        try await device.setAutoMode(true)
        try await device.setFanSpeed(3)
        #expect(dyson.commands == [["fpwr": "OFF"]])
        // Switching on through the speed lifts it, though the device has not confirmed the OFF yet.
        try await device.powerOnAndSetSpeed(3)
        #expect(dyson.commands.last == ["fpwr": "ON", "auto": "OFF", "fnsp": "0003"])
        try await device.setAutoMode(true)
        #expect(dyson.commands.last == ["fpwr": "ON", "auto": "ON", "fnsp": "AUTO"])
    }

    @Test func otherCommands() async throws {
        let (device, dyson) = try await connected("527", state: FakeStates.hp04)
        try await device.setOscillation(true)
        try await device.setNightMode(true)
        try await device.setContinuousMonitoring(false)
        try await device.setJetFocus(false)
        try await device.setHeating(true)
        try await device.setTargetTemperature(22)
        try await device.setTargetTemperature(50)
        try await device.setHumidifier(true)
        try await device.setHumidifierAuto()
        try await device.setTargetHumidity(45.4)
        try await device.setTargetHumidity(120)
        #expect(dyson.commands == [
            ["oson": "ON"], ["nmod": "ON"], ["rhtm": "OFF"], ["fdir": "OFF"], ["hmod": "HEAT"], ["hmax": "2952"], ["hmax": "3102"],
            ["hume": "ON"], ["hume": "AUTO"], ["humt": "0045"], ["humt": "0100"],
        ])
    }

    @Test func commandsNeedAConnection() async throws {
        let device = DysonDevice(serial: "S", productType: "438", name: "Fan", credentials: "c", ipAddress: "192.168.1.5", mqtt: FakeDyson().mqtt, logger: testLogger)
        await #expect(throws: DysonMQTTError.self) { try await device.setNightMode(true) }
    }

    @Test func eventsReachObservers() async throws {
        let (device, dyson) = try await connected()
        let seen = NIOLockedValueBox<[DeviceState]>([])
        await device.observe { event in
            if case .stateChanged(let state) = event { seen.withLockedValue { $0.append(state) } }
        }
        dyson.sendEnvironment(["tact": "2961", "hact": "0050"])
        #expect(await eventually { seen.withLockedValue { $0.last?.temperature } == 2961 })
        // An identical report changes nothing and tells nobody.
        let count = seen.withLockedValue { $0.count }
        dyson.sendEnvironment(["tact": "2961", "hact": "0050"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.withLockedValue { $0.count } == count)
    }

    @Test func connectAndPollAskForStateAndSensors() async throws {
        let dyson = FakeDyson(productState: FakeStates.hp02)
        let device = DysonDevice(serial: "S", productType: "455", name: "Fan", credentials: "c", ipAddress: "192.168.1.5", mqtt: dyson.mqtt, logger: testLogger)
        try await device.connect()
        let requests = ["REQUEST-CURRENT-STATE", "REQUEST-PRODUCT-ENVIRONMENT-CURRENT-SENSOR-DATA"]
        #expect(dyson.published.compactMap { $0.json["msg"]?.stringValue } == requests)
        #expect(dyson.published.allSatisfy { $0.topic == "455/S/command" })
        dyson.clearPublished()
        await device.poll()
        #expect(dyson.published.compactMap { $0.json["msg"]?.stringValue } == requests)
        await device.disconnect()
    }

    @Test func onlyChangesReachObservers() async throws {
        let device = DysonDevice(serial: "S", productType: "438", name: "Fan", credentials: "c", ipAddress: "192.168.1.5", mqtt: FakeDyson().mqtt, logger: testLogger)
        let changes = NIOLockedValueBox(0)
        await device.observe { event in
            if case .stateChanged = event { changes.withLockedValue { $0 += 1 } }
        }
        let message = Data(#"{"msg":"CURRENT-STATE","product-state":{"fpwr":"ON","fnsp":"0005"}}"#.utf8)
        await device.handleMessage(message)
        await device.handleMessage(message)
        await device.handleMessage(Data(#"{"msg":"HELLO"}"#.utf8))
        await device.handleMessage(Data(#"{"msg":"ENVIRONMENTAL-CURRENT-SENSOR-DATA","data":{"tact":"2951"}}"#.utf8))
        #expect(changes.withLockedValue { $0 } == 2)
        let state = await device.state
        #expect(state.isOn && state.fanSpeed == 5 && state.temperature == 2951)
    }

    @Test func pollingInterval() async throws {
        let device = DysonDevice(serial: "S", productType: "438", name: "Fan", credentials: "c", ipAddress: "192.168.1.5", mqtt: FakeDyson().mqtt, logger: testLogger)
        await device.setPollingInterval(seconds: 5)
        #expect(await device.pollingInterval == .seconds(10))
        await device.setPollingInterval(seconds: 1000)
        #expect(await device.pollingInterval == .seconds(300))
        await device.setPollingInterval(seconds: 120)
        #expect(await device.pollingInterval == .seconds(120))
    }
}

/// The CONNECT onto `HomeswiftNetwork.MQTTClient`.
struct MQTTConnectTests {
    func client(_ mqtt: @escaping DysonMQTTClient.Connect) -> DysonMQTTClient {
        DysonMQTTClient(settings: .init(host: "127.0.0.1", serial: "S", credentials: "p", productType: "438", timeout: .seconds(2), autoReconnect: false), mqtt: mqtt)
    }

    @Test func theLadderTriesMQTT5() async throws {
        let attempts = NIOLockedValueBox<[MQTTProtocolVersion]>([])
        // Every variant refused at CONNACK: the ladder goes through all of them, MQTT 5 included.
        let client = client { configuration in
            attempts.withLockedValue { $0.append(configuration.protocolVersion) }
            let connection = FakeMQTTRefusal()
            return connection
        }
        await #expect(throws: DysonMQTTError.refused(code: 2)) { try await client.connect() }
        #expect(attempts.withLockedValue { $0 } == [.v3_1_1, .v3_1_1, .v3_1_1, .v5, .v3_1])
        #expect(DysonMQTTClient.isRecoverable(DysonMQTTError.refused(code: 1)))
        #expect(DysonMQTTError.refused(code: 1).description == "Connection refused: Unacceptable protocol version")
    }

    @Test func nothingListeningIsNotRecoverable() async throws {
        // Port 9 (discard) has nothing listening on a test machine: the ladder must not climb on it.
        let client = client { configuration in
            #expect(configuration.port == 1883)
            var configuration = configuration
            configuration.transport = .tcp(host: "127.0.0.1", port: 9)
            return MQTTClient(configuration)
        }
        do {
            try await client.connect()
            Issue.record("connected to nothing")
        } catch {
            #expect(!DysonMQTTClient.isRecoverable(error))
            #expect(error is DysonMQTTError)
        }
    }
}

/// A broker that refuses every client id.
final class FakeMQTTRefusal: MQTTConnection {
    func connect() async throws { throw MQTTError.connectionRefused(code: 2) }
    func disconnect() async {}
    func subscribe(_ topic: String, qos: MQTTQoS) async throws {}
    func unsubscribe(_ topic: String) async throws {}
    func publish(_ message: MQTTMessage) async throws { throw MQTTError.notConnected }
    var messages: AsyncStream<MQTTMessage> { AsyncStream { _ in } }
    var states: AsyncStream<MQTTConnectionState> { AsyncStream { _ in } }
}
