import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftGovee

// MARK: Fakes

/// The LAN sockets in memory: what was sent, and datagrams the test delivers.
final class FakeLANSocket: LANSocket, @unchecked Sendable {
    let datagrams: AsyncStream<(data: Data, address: String)>
    private let continuation: AsyncStream<(data: Data, address: String)>.Continuation
    private let lock = NIOLock()
    private var _sent: [(data: Data, host: String, port: Int)] = []
    var failing = false
    /// Answers a scan, as devices on the network would.
    var scanReplies: [(device: String, sku: String, address: String)] = []

    init() { (datagrams, continuation) = AsyncStream.makeStream() }

    var sent: [(json: JSONValue, host: String, port: Int)] {
        lock.withLock { _sent.map { ((try? JSONValue(data: $0.data)) ?? .null, $0.host, $0.port) } }
    }

    func deliver(_ json: JSONValue, from address: String) { continuation.yield((json.encoded(), address)) }

    func send(_ data: Data, to host: String, port: Int) async throws {
        if failing { throw GoveeAPIError.unreachable("unreachable") }
        lock.withLock { _sent.append((data, host, port)) }
        if port == LANClient.scanPort {
            for reply in scanReplies { deliver(["msg": ["cmd": "scan", "data": ["device": .string(reply.device), "sku": .string(reply.sku), "ip": "1.2.3.4"]]], from: reply.address) }
        }
    }

    private var _closes = 0
    var closes: Int { lock.withLock { _closes } }

    func close() async {
        lock.withLock { _closes += 1 }
        continuation.finish()
    }
}

/// AWS IoT's broker in memory: the shared fake, whose publishes can hang (a broker that never acknowledges).
final class FakeAWSBroker: MQTTConnection {
    let broker = FakeMQTTConnection()
    private let hanging = NIOLockedValueBox(false)

    var hangs: Bool {
        get { hanging.withLockedValue { $0 } }
        set { hanging.withLockedValue { $0 = newValue } }
    }

    func connect() async throws { try await broker.connect() }
    func disconnect() async { await broker.disconnect() }
    func subscribe(_ topic: String, qos: MQTTQoS) async throws { try await broker.subscribe(topic, qos: qos) }
    func unsubscribe(_ topic: String) async throws { try await broker.unsubscribe(topic) }
    var messages: AsyncStream<MQTTMessage> { broker.messages }
    var states: AsyncStream<MQTTConnectionState> { broker.states }

    func publish(_ message: MQTTMessage) async throws {
        if hangs { try await Task.sleep(for: .seconds(60)) }
        try await broker.publish(message)
    }

    /// What was published, the payloads as JSON.
    var published: [(topic: String, payload: JSONValue)] { broker.published.map { ($0.topic, (try? JSONValue(data: $0.payload)) ?? .null) } }
    var subscribed: [String] { broker.subscriptions.keys.sorted() }
}

/// Debug lines, at debug level.
let quietDebug = DebugLog(logger: testLogger, raised: false)
/// A device's lines.
let testDeviceLog = DeviceLog(logger: testLogger, name: "Test", deviceLogging: true, debugLogging: false)

/// A Bluetooth adapter in memory.
actor FakeCentral: BLECentral {
    var state: String { "poweredOn" }
    private(set) var scans = 0
    private(set) var stops = 0
    private(set) var scanning = false
    private(set) var written: [Data] = []
    private(set) var disconnects = 0
    var discovery: Duration = .zero
    /// How long the adapter takes to report it is on; `powerWaits` counts the waits that started.
    var powerDelay: Duration = .zero
    private(set) var powerWaits = 0
    var onDiscover: (@Sendable (BLEAdvertisement) -> Void)?

    func set(discovery: Duration) { self.discovery = discovery }
    func set(powerDelay: Duration) { self.powerDelay = powerDelay }

    func waitForPoweredOn(timeout: Duration) async -> Bool {
        powerWaits += 1
        if powerDelay > .zero { try? await Task.sleep(for: powerDelay) }
        return true
    }

    func startScanning(services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws {
        scans += 1
        scanning = true
        self.onDiscover = onDiscover
    }

    func stopScanning() async {
        stops += 1
        scanning = false
    }

    func advertise(_ advertisement: BLEAdvertisement) { onDiscover?(advertisement) }

    func connect(_ target: BLETarget) async throws -> any BLEConnection { Connection(central: self) }

    func reset() async {}

    func record(_ data: Data) { written.append(data) }
    func recordDisconnect() { disconnects += 1 }

    struct Connection: BLEConnection {
        let central: FakeCentral
        func discoverCharacteristic(_ uuid: String) async throws -> Bool {
            let delay = await central.discovery
            if delay > .zero { try await Task.sleep(for: delay) }
            return uuid == BLEClient.controlCharacteristic
        }
        func write(_ data: Data, to characteristic: String) async throws { await central.record(data) }
        func disconnect() async throws { await central.recordDisconnect() }
    }
}

/// Collects what a callback receives.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NIOLock()
    private var _items: [T] = []
    var items: [T] { lock.withLock { _items } }
    func append(_ item: T) { lock.withLock { _items.append(item) } }
}

/// A ceiling, not a wait: it returns as soon as the condition holds, and a loaded CI runner can take seconds.
func eventually(_ timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

let deviceID = "AA:BB:CC:DD:EE:FF:00:11"

func scanReply(_ device: String, sku: String = "H6008", extra: [String: JSONValue] = [:]) -> JSONValue {
    var data: [String: JSONValue] = ["device": .string(device), "sku": .string(sku)]
    for (key, value) in extra { data[key] = value }
    return ["msg": ["cmd": "scan", "data": .object(data)]]
}

// MARK: LAN

@Suite struct LANClientTests {
    final class Received: @unchecked Sendable {
        let lock = NIOLock()
        var items: [(String, JSONValue, String)] = []
        func add(_ item: (String, JSONValue, String)) { lock.withLock { items.append(item) } }
        var all: [(String, JSONValue, String)] { lock.withLock { items } }
    }

    func client(custom: [String: String] = [:]) -> (LANClient, FakeLANSocket, Received) {
        let socket = FakeLANSocket()
        let received = Received()
        let client = LANClient(socket: socket, customAddresses: custom, settleTime: .milliseconds(100), logger: testLogger, debug: quietDebug) { id, data, ip in received.add((id, data, ip)) }
        return (client, socket, received)
    }

    @Test func localAddresses() {
        let cases: [(String, Bool)] = [
            ("192.168.1.20", true), ("10.0.0.5", true), ("172.16.0.1", true), ("172.31.255.255", true), ("169.254.10.10", true),
            ("172.32.0.1", false), ("8.8.8.8", false), ("127.0.0.1", false), ("not-an-ip", false), ("192.168.1.300", false),
        ]
        for (address, local) in cases { #expect(LANClient.isLocalIPv4(address) == local, "\(address)") }
    }

    @Test func registersADeviceAtThePacketsSourceAddress() async {
        let (client, _, received) = client()
        await client.handle(scanReply(deviceID, extra: ["ip": "192.168.1.99"]).encoded(), from: "192.168.1.20")
        #expect(await client.devices == [LANDevice(device: deviceID, ip: "192.168.1.20", sku: "H6008")])
        #expect(received.all.first?.0 == deviceID && received.all.first?.2 == "192.168.1.20")
    }

    @Test func ignoresInvalidIdsAndRemoteAddresses() async {
        let (client, _, _) = client()
        await client.handle(scanReply("not-a-device").encoded(), from: "192.168.1.20")
        await client.handle(Data(#"{"msg":{"cmd":"scan","data":{"device":{"toString":1}}}}"#.utf8), from: "192.168.1.20")
        await client.handle(scanReply(deviceID).encoded(), from: "8.8.8.8")
        await client.handle(Data(String(repeating: "x", count: 10000).utf8), from: "192.168.1.20")
        #expect(await client.devices.isEmpty)
    }

    @Test func capsTheDevices() async {
        let (client, _, _) = client()
        for index in 0..<300 {
            await client.handle(scanReply(String(format: "AA:BB:CC:DD:EE:FF:%02X:%02X", index >> 8, index & 0xFF)).encoded(), from: "192.168.1.20")
        }
        #expect(await client.devices.count == 256)
    }

    @Test func keepsAConfiguredAddress() async {
        let (client, _, received) = client(custom: [deviceID: "192.168.5.5"])
        await client.handle(scanReply(deviceID).encoded(), from: "192.168.1.66")
        #expect(await client.devices == [LANDevice(device: deviceID, ip: "192.168.5.5", sku: "H6008", isManual: true)])
        #expect(received.all.last?.2 == "192.168.5.5")
        await client.handle(scanReply(deviceID).encoded(), from: "192.168.1.77")
        #expect(await client.devices.first?.ip == "192.168.5.5")
    }

    @Test func followsADiscoveredDevice() async {
        let (client, _, received) = client()
        await client.handle(scanReply(deviceID).encoded(), from: "192.168.1.20")
        await client.handle(scanReply(deviceID).encoded(), from: "192.168.1.21")
        #expect(await client.devices.first?.ip == "192.168.1.21")
        #expect(received.all.last?.2 == "192.168.1.21")
    }

    @Test func forwardsStatusFromKnownDevicesOnly() async {
        let (client, _, received) = client()
        await client.handle(scanReply(deviceID).encoded(), from: "192.168.1.20")
        let data: JSONValue = ["onOff": 1, "brightness": 50, "color": ["r": 1, "g": 2, "b": 3], "colorTemInKelvin": 0]
        await client.handle(jsonData(["msg": ["cmd": "devStatus", "data": data]]), from: "192.168.1.20")
        await client.handle(jsonData(["msg": ["cmd": "devStatus", "data": data]]), from: "192.168.1.50")
        #expect(received.all.count == 2)
        #expect(received.all.last?.1 == data)
    }

    @Test func sendsCommandsToPort4003AndForgetsFailingDevices() async throws {
        let (client, socket, _) = client()
        await client.handle(scanReply(deviceID).encoded(), from: "192.168.1.20")
        try await client.updateDevice(id: deviceID, params: LANParams(cmd: "turn", data: ["value": 1]), log: testDeviceLog)
        #expect(socket.sent.last?.json == ["msg": ["cmd": "turn", "data": ["value": 1]]])
        #expect(socket.sent.last?.host == "192.168.1.20" && socket.sent.last?.port == 4003)
        socket.failing = true
        await #expect(throws: (any Error).self) { try await client.updateDevice(id: deviceID, params: LANParams(cmd: "turn", data: [:]), log: testDeviceLog) }
        #expect(await client.devices.isEmpty)
    }

    @Test func discoveryScansTheMulticastGroup() async {
        let (client, socket, _) = client()
        socket.scanReplies = [(deviceID, "H6008", "192.168.1.20")]
        await client.start()
        let found = await client.discover()
        #expect(found.map(\.device) == [deviceID])
        #expect(socket.sent.first?.host == "239.255.255.250" && socket.sent.first?.port == 4001)
        #expect(socket.sent.first?.json == ["msg": ["cmd": "scan", "data": ["account_topic": "reserve"]]])
        await client.close()
    }

    @Test func discoveryEndsAtOnceWhenCancelled() async {
        let (client, socket, _) = client()
        socket.scanReplies = [(deviceID, "H6008", "192.168.1.20")]
        await client.start()
        // Timed from inside the task, so a loaded runner's late start of it does not count.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let started = ContinuousClock.now
            _ = await client.discover()
            return ContinuousClock.now - started
        }
        #expect(await task.value < LANClient.scanSettleTime)
        await client.close()
    }
}

// MARK: AWS

@Suite struct AWSClientTests {
    func client(_ connection: FakeAWSBroker, received: Collector<JSONValue> = Collector()) async -> AWSClient {
        let client = AWSClient(accountTopic: "account-topic", connection: connection, publishTimeout: .milliseconds(200), debug: quietDebug) { received.append($0) }
        await client.start()
        try? await client.connect()
        _ = await eventually { await client.connected }
        return client
    }

    @Test func subscribesAndPublishesToTheDeviceTopic() async throws {
        let connection = FakeAWSBroker()
        let client = await client(connection)
        #expect(connection.subscribed == ["account-topic"])
        try await client.updateDevice(topic: "device-topic", params: AWSParams(cmd: "turn", data: ["val": 1]), log: testDeviceLog)
        let published = try #require(connection.published.first)
        #expect(published.topic == "device-topic")
        #expect(published.payload["msg"]?["cmd"] == "turn")
        #expect(published.payload["msg"]?["data"] == ["val": 1])
        #expect(published.payload["msg"]?["accountTopic"] == "account-topic")
        #expect(published.payload["msg"]?["type"] == 1)
        try await client.requestUpdate(topic: "device-topic", log: testDeviceLog)
        #expect(connection.published.last?.payload["msg"]?["cmd"] == "status")
        #expect(connection.published.last?.payload["msg"]?["cmdVersion"] == 2)
    }

    @Test func failsAPublishTheBrokerNeverAcknowledges() async {
        let connection = FakeAWSBroker()
        connection.hangs = true
        let client = await client(connection)
        await #expect(throws: GoveeAPIError.message(Lang.notAWSConn)) { try await client.updateDevice(topic: "t", params: AWSParams(cmd: "turn", data: [:]), log: testDeviceLog) }
    }

    @Test func refusesWhileDisconnected() async {
        let connection = FakeAWSBroker()
        let client = await client(connection)
        connection.broker.setState(.connectionLost("gone"))
        _ = await eventually { await !client.connected }
        await #expect(throws: GoveeAPIError.self) { try await client.updateDevice(topic: "t", params: AWSParams(cmd: "turn", data: [:]), log: testDeviceLog) }
        #expect(connection.published.isEmpty)
    }

    @Test func unwrapsMessages() async {
        let connection = FakeAWSBroker()
        let received = Collector<JSONValue>()
        let client = await client(connection, received: received)
        let inner: JSONValue = ["device": .string(deviceID), "data": .string(#"{"a":1}"#), "state": ["onOff": 1]]
        connection.broker.receive("account-topic", payload: jsonData(["msg": .string(inner.text())]))
        connection.broker.receive("account-topic", string: "not json")
        #expect(await eventually { received.items.count == 1 })
        #expect(received.items.first?["data"] == ["a": 1])
        #expect(received.items.first?["device"] == .string(deviceID))
        await client.disconnect()
    }

    @Test func connectsWithTheAccountCertificateAndRetriesTheFirstConnection() throws {
        let identity = try GoveeIoTIdentity(pkcs12: Data(base64Encoded: legacyPKCS12)!, passphrase: "secret")
        let configuration = GoveePlugin.mqttConfiguration(endpoint: "aws.example", clientID: "AP/acc/hb123", identity: identity)
        #expect(configuration.clientID == "AP/acc/hb123")
        #expect(configuration.reconnect?.firstConnection == true)
        #expect(configuration.reconnect?.delay == .seconds(1) && configuration.reconnect?.maximumDelay == .seconds(60))
        guard case .tls(let host, let port, let options) = configuration.transport else {
            Issue.record("not TLS")
            return
        }
        #expect(host == "aws.example" && port == 8883)
        #expect(options.trust == .amazonRootCA1)
    }

    /// Two bridges on one account (or this one and Homebridge) each keep their connection: AWS IoT drops one when
    /// another opens with its id, and the login's client id is the same for both.
    @Test func eachRunConnectsWithAClientIDOfItsOwn() {
        #expect(GoveePlugin.awsClientID(accountId: "acc", clientId: "hb123", run: "1a2b3c4d") == "AP/acc/hb123-1a2b3c4d")
        let first = GoveePlugin.awsClientID(accountId: "acc", clientId: "hb123"), second = GoveePlugin.awsClientID(accountId: "acc", clientId: "hb123")
        #expect(first.hasPrefix("AP/acc/hb123-") && first != second)
    }

    @Test func decodesTheAccountCertificate() throws {
        for fixture in [legacyPKCS12, modernPKCS12] {
            let identity = try GoveeIoTIdentity(pkcs12: Data(base64Encoded: fixture)!, passphrase: "secret")
            #expect(identity.passphrase == "secret")
        }
        #expect(throws: (any Error).self) { try GoveeIoTIdentity(pkcs12: Data(base64Encoded: legacyPKCS12)!, passphrase: "wrong") }
        #expect(throws: (any Error).self) { try GoveeIoTIdentity(pkcs12: Data("not-a-pfx".utf8), passphrase: "secret") }
    }
}

// MARK: BLE

@Suite struct BLEClientTests {
    let timing = BLEClient.Timing(connection: .milliseconds(300), discovery: .milliseconds(150), write: .milliseconds(300), disconnect: .milliseconds(300), resumeScan: .milliseconds(100))
    let target = BLETarget(address: "a4:c1:38:00:00:01", name: "ihoment_H6199_0001")

    @Test func stopsATimedScan() async throws {
        let central = FakeCentral()
        let client = BLEClient(central: central, logger: testLogger, timing: timing, debug: quietDebug)
        try await client.scan(for: { _ in }, duration: .milliseconds(150))
        #expect(await client.isScanning)
        // The 150 ms timer, with room for a loaded runner.
        #expect(await eventually(.seconds(10)) { await !client.isScanning })
        #expect(await central.stops == 1)
    }

    /// The test reads the scan's deadline rather than waiting for it: a resumed window keeps the original deadline
    /// exactly, where a new one would end later.
    @Test func writesTheFramesAndResumesTheScanForWhatRemains() async throws {
        let central = FakeCentral()
        let client = BLEClient(central: central, logger: testLogger, timing: timing, debug: quietDebug)
        try await client.scan(for: { _ in }, duration: .seconds(60))
        let deadline = try #require(await client.scanDeadline)
        try await client.updateDevice(target, params: .ptReal(["MwEBAAAAAAAAAAAAAAAAAAAAADM=", "MwEAAAAAAAAAAAAAAAAAAAAAADI="]), log: testDeviceLog)
        #expect(await central.written.map(Array.init) == [Govee.codeBytes([0x33, 1, 1]), Govee.codeBytes([0x33, 1, 0])])
        #expect(await central.disconnects == 1)
        #expect(await eventually(.seconds(15)) { await central.scans == 2 })
        #expect(await client.isScanning)
        // …and still ends at the original deadline: what remained of the window, not a new one.
        #expect(await client.scanDeadline == deadline)
        await client.stopDiscovery()
        #expect(await !client.isScanning)
    }

    @Test func timesOutAStalledDiscoveryAndDisconnects() async {
        let central = FakeCentral()
        await central.set(discovery: .seconds(30))
        let client = BLEClient(central: central, logger: testLogger, timing: timing, debug: quietDebug)
        await #expect(throws: BLEError.timeout("Service discovery timeout")) {
            try await client.updateDevice(target, params: .command(0x01, [1]), log: testDeviceLog)
        }
        #expect(await central.disconnects == 1)
    }

    @Test func decodesSensorAdvertisements() async throws {
        let central = FakeCentral()
        let readings = Collector<BLESensorReading>()
        let client = BLEClient(central: central, logger: testLogger, timing: timing, debug: quietDebug)
        try await client.scan(for: { readings.append($0) }, duration: nil)
        await central.advertise(BLEAdvertisement(identifier: "1", address: nil, localName: "GVH5075_0001", manufacturerData: Govee.bytes(hex: "0088ec03d5a65a00"), rssi: -60))
        await central.advertise(BLEAdvertisement(identifier: "2", address: nil, localName: "Other", manufacturerData: [1, 2, 3], rssi: -60))
        #expect(await eventually { readings.items.count == 1 })
        #expect(readings.items.first?.model == "GVH5075_0001")
        #expect(readings.items.first?.battery == 90)
    }

    /// A command claims the adapter before it waits for power: a sensor scan starting meanwhile would replace the
    /// scan that finds the device (CoreBluetooth has one per manager).
    @Test func aSensorScanWaitsForACommandThatWaitsForPower() async throws {
        let central = FakeCentral()
        await central.set(powerDelay: .milliseconds(200))
        let client = BLEClient(central: central, logger: testLogger, timing: timing, debug: quietDebug)
        let command = Task { try await client.updateDevice(target, params: .command(0x01, [1]), log: testDeviceLog) }
        #expect(await eventually { await central.powerWaits == 1 })
        try await client.scan(for: { _ in }, duration: .seconds(1))
        #expect(await central.scans == 0)
        try await command.value
        #expect(await central.written.count == 1)
        #expect(await central.scans == 0)
        #expect(await !client.isConnecting)
        // Once the command is done, the next window scans.
        try await client.scan(for: { _ in }, duration: .milliseconds(100))
        #expect(await central.scans == 1)
    }

    @Test func noScanAfterShutdown() async throws {
        let central = FakeCentral()
        let client = BLEClient(central: central, logger: testLogger, timing: timing, debug: quietDebug)
        await client.shutdown()
        try await client.scan(for: { _ in }, duration: .seconds(1))
        #expect(await central.scans == 0)
    }

    @Test func sensorsAreMatchedByAddressOrName() {
        let reading = BLESensorReading(identifier: "x", address: nil, model: "GVH5075_0001", battery: 1, humidity: 1, tempInC: 1, tempInF: 1, rssi: 0)
        #expect(GoveePlugin.matches(BLETarget(address: "a4:c1:38:00:00:01", name: nil), reading))
        #expect(GoveePlugin.matches(BLETarget(address: "a4:c1:38:00:99:99", name: "GVH5075_0001"), reading))
        #expect(!GoveePlugin.matches(BLETarget(address: "a4:c1:38:00:00:02", name: nil), reading))
        var withAddress = reading
        withAddress.address = "A4:C1:38:00:00:01"
        #expect(GoveePlugin.matches(BLETarget(address: "a4:c1:38:00:00:01", name: nil), withAddress))
        #expect(!GoveePlugin.matches(BLETarget(address: "a4:c1:38:00:00:09", name: "GVH5075_0001"), withAddress))
    }
}

@Suite struct QueueWaitTests {
    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NIOLock()
        private var _value: T?
        var value: T? { lock.withLock { _value } }
        func set(_ value: T) { lock.withLock { _value = value } }
    }

    let queue = DispatchQueue(label: "test.queue-wait")

    /// The case `withTaskCancellationHandler` alone gets wrong: the task was cancelled before the wait parked.
    @Test func aTaskCancelledBeforeItWaitsDoesNotHang() async {
        let wait = QueueWait<Bool>(queue: queue)
        let result = Box<Bool>()
        Task {
            withUnsafeCurrentTask { $0?.cancel() }
            result.set(await wait.wait(cancelled: false) { _ in })
        }
        #expect(await eventually { result.value == false })
    }

    @Test func endsWithTheValueOrTheCancellation() async {
        let parked = Box<QueueWait<Bool>>()
        let result = Box<Bool>()
        let wait = QueueWait<Bool>(queue: queue)
        Task { result.set(await wait.wait(cancelled: false) { parked.set($0) }) }
        #expect(await eventually { parked.value != nil })
        queue.async {
            parked.value?.resume(true)
            parked.value?.resume(false)
        }
        #expect(await eventually { result.value == true })

        let cancelled = Box<Bool>()
        let other = QueueWait<Bool>(queue: queue)
        let task = Task { cancelled.set(await other.wait(cancelled: false) { _ in }) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await eventually { cancelled.value == false })
    }
}

@Suite struct CommandQueueTests {
    @Test func runsInOrderAndSpacesTheStarts() async throws {
        let queue = CommandQueue(interval: .milliseconds(60))
        let starts = Collector<ContinuousClock.Instant>()
        let order = Collector<Int>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask { try await queue.add { starts.append(.now); order.append(index) } }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await group.waitForAll()
        }
        #expect(order.items == [0, 1, 2])
        let times = starts.items
        for index in 1..<times.count { #expect(times[index] - times[index - 1] >= .milliseconds(55)) }
    }
}

func jsonText(_ value: JSONValue) -> String { value.text() }
func jsonData(_ value: JSONValue) -> Data { value.encoded() }

@Suite struct AWSEventTests {
    /// The AWS IoT SDK's `error` and `offline` events of the Homebridge plugin, on a dropped connection.
    @Test func aDroppedConnectionLogsTheErrorEvent() async {
        let recorder = LogRecorder()
        let client = AWSClient(accountTopic: "account-topic", connection: FakeAWSBroker(), debug: DebugLog(logger: recorder.logger, raised: true)) { _ in }
        await client.handle(.connectionLost("TLS handshake failed"))
        await client.handle(.disconnected)
        #expect(recorder.lines == ["[AWS] error event [TLS handshake failed].", "[AWS] offline event.", "[AWS] close event."])
    }
}
