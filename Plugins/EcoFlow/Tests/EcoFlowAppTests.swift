import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftEcoFlow

// Synthetic property messages, in the protobuf wire format the app's stream uses. No recorded serials or readings
// are in the repository: each test builds the bytes it needs.

private func key(_ number: Int, _ wireType: Int) -> [UInt8] { EcoFlowProtobuf.tag(number, wireType) }

private func bytesField(_ number: Int, _ data: [UInt8]) -> [UInt8] { EcoFlowProtobuf.bytesField(number, data) }

private func floatField(_ number: Int, _ value: Float) -> [UInt8] {
    key(number, 5) + withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
}

private func intField(_ number: Int, _ value: Int64) -> [UInt8] {
    key(number, 0) + EcoFlowProtobuf.encode(UInt64(bitPattern: value))
}

/// One message of a payload: its header (field 1) with the body and the command (`cmd_func` 8, `cmd_id` 9).
private func header(_ function: Int64, _ id: Int64, _ body: [UInt8]) -> [UInt8] {
    bytesField(1, bytesField(1, body) + intField(8, function) + intField(9, id))
}

/// A STREAM's property message: its status message (254/21) with the flows, and its battery pack's (32/50) with the
/// percentage in field 6 when there is one.
private func propertyPayload(soc: Int64? = nil, solar: Float? = nil, home: Float? = nil, grid: Float? = nil,
                             battery: Float? = nil, panels: [Float] = []) -> Data {
    var body: [UInt8] = []
    if let solar { body += floatField(517, solar) }
    if let home { body += floatField(516, home) }
    if let grid { body += floatField(515, grid) }
    if let battery { body += floatField(518, battery) }
    for (number, panel) in zip([361, 70, 996, 997], panels) { body += floatField(number, panel) }
    var payload = body.isEmpty ? [] : header(254, 21, body)
    if let soc { payload += header(32, 50, intField(6, soc)) }
    return Data(payload)
}

/// A broker that refuses a subscription to every device's topic, as EcoFlow's does.
private final class RefusingWildcard: MQTTConnection, Sendable {
    struct Refused: Error {}
    let inner = FakeMQTTConnection()
    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }
    func subscribe(_ topic: String, qos: MQTTQoS) async throws {
        if topic.hasSuffix("/+") { throw Refused() }
        try await inner.subscribe(topic, qos: qos)
    }
    func unsubscribe(_ topic: String) async throws { try await inner.unsubscribe(topic) }
    func publish(_ message: MQTTMessage) async throws { try await inner.publish(message) }
    var messages: AsyncStream<MQTTMessage> { inner.messages }
    var states: AsyncStream<MQTTConnectionState> { inner.states }
}

/// The app's sign-in and its MQTT certificate, as the fake HTTP server answers them.
private let signInAnswers: [String: String] = [
    "/auth/login": #"{"code":"0","message":"Success","data":{"token":"session-token","user":{"userId":42}}}"#,
    "/iot-auth/app/certification": #"{"code":"0","message":"Success","data":{"url":"mqtt-e.example.test","port":8883,"protocol":"mqtts","certificateAccount":"broker-account","certificatePassword":"broker-password"}}"#,
]

/// Records the MQTT configurations the plugin builds.
final class ConfigurationLog: Sendable {
    let values = NIOLockedValueBox<[MQTTConfiguration]>([])
}

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowAppTests {
    /// A synthetic serial number with a STREAM Ultra's prefix.
    let serial = "BK11-TEST-ULTRA"
    let password = "pw-secret"


    private func makeAPI(transport: FakeTransport, broker: FakeMQTTConnection, log: ConfigurationLog) -> EcoFlowAppAPI {
        EcoFlowAppAPI(email: "owner@example.test", password: password, serials: [serial], transport: transport) { configuration in
            log.values.withLockedValue { $0.append(configuration) }
            return broker
        }
    }

    @Test func theReadingsDecodeFromTheWireFormatByCommand() {
        let payload = propertyPayload(soc: 58, solar: 184.5, home: 1480, grid: -12.25, battery: -636)
        var readings: [String: Double] = [:]
        for message in EcoFlowProtobuf.messages(payload) {
            readings.merge(EcoFlowProtobuf.keyed(message.body, prefix: "\(message.command.function)_\(message.command.id)")) { $1 }
        }
        #expect(readings["32_50.6"] == 58)
        #expect(readings["254_21.517"] == 184.5)
        #expect(readings["254_21.516"] == 1480)
        #expect(readings["254_21.515"] == -12.25)
        #expect(readings["254_21.518"] == -636, "a negative integer is read as signed")
        // A nested message's numbers are under its field: the battery's precise percentage is 32_2.1.15.
        #expect(EcoFlowProtobuf.keyed(Data(bytesField(1, floatField(15, 93.5))), prefix: "32_2") == ["32_2.1.15": 93.5])
    }

    /// The model's keys as a tree: only the fields it names are read, under the same keys as a full read, nested ones
    /// included; an encrypted body reads the same once decrypted.
    @Test func onlyTheModelsFieldsAreRead() {
        let wanted = EcoFlowProtobuf.Wanted.commands(["254_21.517", "254_21.516", "32_2.1.15", "pd.soc"])
        #expect(Set(wanted.keys) == ["254_21", "32_2"], "a JSON quota's name has no command")
        let body = Data(floatField(517, 184.5) + floatField(516, 1480) + floatField(515, -12.25) + bytesField(30, floatField(1, 7)))
        let all = EcoFlowProtobuf.keyed(body, prefix: "254_21")
        #expect(all.count == 4)
        #expect(EcoFlowProtobuf.keyed(body, prefix: "254_21", wanted: wanted["254_21"]!) == ["254_21.517": 184.5, "254_21.516": 1480])
        let nested = Data(bytesField(1, floatField(15, 93.5) + floatField(12, 40)) + floatField(2, 1))
        #expect(EcoFlowProtobuf.keyed(nested, prefix: "32_2", wanted: wanted["32_2"]!) == ["32_2.1.15": 93.5])
        #expect(EcoFlowProtobuf.keyed(Data([0xFF, 0xFF]), prefix: "254_21", wanted: wanted["254_21"]!).isEmpty)

        // Split in typed parts: Linux's type checker times out on long chains of byte arrays.
        let scrambled: [UInt8] = bytesField(1, Array(body).map { $0 ^ 0x2A })
        let command: [UInt8] = intField(6, 1) + intField(8, 254) + intField(9, 21)
        let sequence: [UInt8] = intField(14, 0x12A)
        let encrypted = Data(bytesField(1, scrambled + command + sequence))
        let message = EcoFlowProtobuf.messages(encrypted).first
        #expect(message?.command == EcoFlowProtobuf.Command(function: 254, id: 21))
        #expect(message.map { EcoFlowProtobuf.keyed($0.body, prefix: "254_21") } == all, "the key is the sequence's low byte")
        #expect(EcoFlowProtobuf.hasNumber(body))
        #expect(!EcoFlowProtobuf.hasNumber(Data(bytesField(3, Array("text".utf8)))))
    }

    /// A push of fields the model does not read changes none of its readings, and the device stays listed and online.
    @Test func aPushOfUnreadFieldsChangesNoReading() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = makeAPI(transport: transport, broker: broker, log: ConfigurationLog())
        _ = try await api.devices()
        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(soc: 58, solar: 500))
        #expect(await eventually { (try? await api.devices())?.first?.state.power.solar == 500 })
        broker.receive("/app/device/property/\(serial)", payload: Data(header(254, 21, floatField(9999, 1))))
        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(solar: 640))
        #expect(await eventually { (try? await api.devices())?.first?.state.power.solar == 640 })
        let device = try #require(try await api.devices().first)
        #expect(device.online)
        #expect(device.state.battery.batteryLevel == 58)
    }

    @Test func aMalformedPayloadGivesNoReadings() {
        #expect(EcoFlowProtobuf.messages(Data([0xFF, 0xFF])).isEmpty)
        #expect(EcoFlowProtobuf.keyed(Data([0xFF, 0xFF]), prefix: "254_21").isEmpty)
        #expect(EcoFlowProtobuf.messages(Data()).isEmpty)
    }

    @Test func signInSendsThePasswordEncodedNotPlain() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let log = ConfigurationLog()
        let api = makeAPI(transport: transport, broker: broker, log: log)
        _ = try await api.devices()

        let login = try #require(transport.requests.withLockedValue { $0 }.first { $0.url.path == "/auth/login" })
        let body = String(decoding: login.body ?? Data(), as: UTF8.self)
        #expect(!body.contains(password), "the password never goes out in plain text")
        #expect(body.contains(Data(password.utf8).base64EncodedString()))
        #expect(!login.url.absoluteString.contains(password))

        let certificate = try #require(transport.requests.withLockedValue { $0 }.first { $0.url.path == "/iot-auth/app/certification" })
        #expect(certificate.header("Authorization") == "Bearer session-token")
    }

    @Test func theBrokerAndTheDevicesAreUsed() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let log = ConfigurationLog()
        let api = makeAPI(transport: transport, broker: broker, log: log)
        _ = try await api.devices()

        let configuration = try #require(log.values.withLockedValue { $0 }.first)
        #expect(configuration.username == "broker-account")
        #expect(configuration.password == "broker-password")
        #expect(configuration.clientID.hasPrefix("ANDROID_"))
        #expect(configuration.clientID.hasSuffix("_42"))
        #expect(broker.subscriptions["/app/device/property/\(serial)"] != nil)
    }

    @Test func aDeviceAppearsWithItsStateOfCharge() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = makeAPI(transport: transport, broker: broker, log: ConfigurationLog())
        _ = try await api.devices()

        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(soc: 58, solar: 500, home: 1380, grid: 180, battery: 40))
        let listed = await eventually { (try? await api.devices())?.count == 1 }
        #expect(listed)
        let device = try #require(try await api.devices().first)
        #expect(device.id == serial)
        #expect(device.online)
        #expect(device.state.battery.batteryLevel == 58)
        #expect(device.state.battery.chargingState == 1)
        #expect(device.state.power == EcoFlowState.Power(solar: 500, home: 1380, grid: 180, battery: 40))
    }

    /// The stream sends the state of charge only now and then: a device with power alone is listed, its level not known.
    /// The solar of each panel input comes from its own field.
    @Test func thePanelsAreReadPerInput() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = makeAPI(transport: transport, broker: broker, log: ConfigurationLog())
        _ = try await api.devices()

        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(soc: 58, solar: 1650, panels: [444, 462, 428, 409]))
        let listed = await eventually { (try? await api.devices())?.first?.state.power.panels == [444, 462, 428, 409] }
        #expect(listed)
    }

    @Test func aMessageWithoutTheStateOfChargeListsTheDeviceWithoutItsLevel() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = makeAPI(transport: transport, broker: broker, log: ConfigurationLog())
        _ = try await api.devices()

        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(solar: 500, home: 1380))
        let listed = await eventually { (try? await api.devices())?.count == 1 }
        #expect(listed)
        let device = try #require(try await api.devices().first)
        #expect(device.state.knowsBatteryLevel == false)
        #expect(device.state.power.solar == 500)
    }

    @Test func partialMessagesAreMerged() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = makeAPI(transport: transport, broker: broker, log: ConfigurationLog())
        _ = try await api.devices()

        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(soc: 58, solar: 500))
        _ = await eventually { (try? await api.devices())?.count == 1 }
        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(battery: 40))
        let merged = await eventually {
            (try? await api.devices().first)?.state.power.battery == 40
        }
        #expect(merged)
        let device = try #require(try await api.devices().first)
        #expect(device.state.battery.batteryLevel == 58, "a message without the state of charge keeps the last one")
        #expect(device.state.power.solar == 500)
    }

    /// A STREAM's status message carries its backup state in field 6, the number its battery pack's message uses for
    /// the percentage: an AC Pro sends 0 there in about a third of its messages. The level stays the pack's.
    @Test func theStatusMessagesBackupStateIsNotTheBattery() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = makeAPI(transport: transport, broker: broker, log: ConfigurationLog())
        _ = try await api.devices()

        broker.receive("/app/device/property/\(serial)", payload: Data(header(32, 50, intField(6, 56) + floatField(25, 55.78))))
        _ = await eventually { (try? await api.devices())?.first?.state.battery.batteryLevel == 56 }
        broker.receive("/app/device/property/\(serial)", payload: Data(header(254, 21, intField(6, 0) + floatField(262, 0) + floatField(517, 300))))
        let pushed = await eventually { (try? await api.devices())?.first?.state.power.solar == 300 }
        #expect(pushed)
        #expect(try await api.devices().first?.state.battery.batteryLevel == 56, "the precise 55.78, rounded; never the backup state's 0")
    }

    /// With no serials configured, the route subscribes to the account's property topics and lists each device
    /// that reports.
    @Test func devicesAreDiscoveredFromTheStream() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: password, serials: [], transport: transport) { _ in broker }
        _ = try await api.devices()
        #expect(broker.subscriptions["/app/device/property/+"] != nil)

        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(soc: 58, battery: 40))
        let found = await eventually { (try? await api.devices())?.map(\.id) == [serial] }
        #expect(found)
    }

    /// With no serials configured, the account's devices come from the app's device list, each subscribed to by its
    /// serial number: EcoFlow's broker refuses the wildcard. A device the route does not read gets no subscription.
    @Test func devicesComeFromTheAppsDeviceList() async throws {
        let plug = "SM2A-TEST-PLUG"
        let transport = FakeTransport(answers: signInAnswers.merging([
            "/app/user/device/list": #"{"code":"0","data":[{"sn":"\#(serial)","deviceName":"Roof","productType":1},{"sn":"\#(plug)","deviceName":"Plug","productType":2}]}"#,
        ]) { $1 })
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: password, serials: [], transport: transport) { _ in broker }
        _ = try await api.devices()
        #expect(broker.subscriptions["/app/device/property/+"] == nil)
        #expect(broker.subscriptions["/app/device/property/\(serial)"] != nil)
        #expect(broker.subscriptions["/app/42/\(serial)/thing/property/get_reply"] != nil)
        #expect(broker.subscriptions["/app/device/property/\(plug)"] == nil)
        #expect(broker.published.contains { $0.topic == "/app/42/\(serial)/thing/property/get" }, "the listed device is asked for its state")

        broker.receive("/app/device/property/\(serial)", payload: propertyPayload(soc: 58, battery: 40))
        let found = await eventually { (try? await api.devices())?.map(\.name) == ["Roof"] }
        #expect(found)
    }

    /// The configured devices come first, and the account's others from the device list are read too: a device the
    /// configuration does not list (it had not reported when the list was saved) is not left out.
    @Test func theDeviceListAddsToTheConfiguredDevices() async throws {
        let river = "R631-TEST-RIVER"
        let transport = FakeTransport(answers: signInAnswers.merging([
            "/app/user/device/list": #"{"code":"0","data":[{"sn":"\#(river)","deviceName":"Desk","online":1},{"sn":"\#(serial)","deviceName":"Roof","online":1}]}"#,
        ]) { $1 })
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: password, serials: [serial], transport: transport) { _ in broker }
        _ = try await api.devices()
        #expect(broker.subscriptions["/app/device/property/\(serial)"] != nil)
        #expect(broker.subscriptions["/app/device/property/\(river)"] != nil, "the list's other device is read too")
        let asked = broker.published.map(\.topic)
        #expect(asked.firstIndex(of: "/app/42/\(serial)/thing/property/get") ?? .max < asked.firstIndex(of: "/app/42/\(river)/thing/property/get") ?? .max,
                "the configured device first")
    }

    /// A device the app's list has offline, and that sends nothing, is listed offline with no level rather than left
    /// out; one the list has online waits for its first readings.
    @Test func anOfflineDeviceIsListedOffline() async throws {
        let bank = "P513-TEST-BANK"
        let quiet = "R631-TEST-QUIET"
        let transport = FakeTransport(answers: signInAnswers.merging([
            "/app/user/device/list": #"{"code":"0","data":[{"sn":"\#(bank)","deviceName":"Bag","online":0},{"sn":"\#(quiet)","deviceName":"Desk","online":1}]}"#,
        ]) { $1 })
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: password, serials: [], transport: transport) { _ in broker }
        let devices = try await api.devices()
        #expect(devices.map(\.id) == [bank])
        let device = try #require(devices.first)
        #expect(device.online == false)
        #expect(device.name == "Bag")
        #expect(device.state.knowsBatteryLevel == false)
    }

    /// A refused wildcard, with no device list to fall back on, says to list the devices, not that the sign-in failed.
    @Test func aRefusedWildcardAsksForTheSerials() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = RefusingWildcard()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: password, serials: [], transport: transport) { _ in broker }
        await #expect(throws: EcoFlowAppAPI.Failure.noDevices) {
            _ = try await api.devices()
        }
        #expect(EcoFlowAppAPI.Failure.retryLater.description.contains("sign-in") == false)
    }

    @Test func aFailedSignInIsNotRepeatedAtOnce() async throws {
        let transport = FakeTransport(answers: [
            "/auth/login": #"{"code":"1001","message":"Wrong password"}"#,
        ])
        let api = makeAPI(transport: transport, broker: FakeMQTTConnection(), log: ConfigurationLog())
        await #expect(throws: EcoFlowAppAPI.Failure.refused("Wrong password")) {
            _ = try await api.devices()
        }
        await #expect(throws: EcoFlowAppAPI.Failure.retryLater) {
            _ = try await api.devices()
        }
        let logins = transport.requests.withLockedValue { $0 }.filter { $0.url.path == "/auth/login" }
        #expect(logins.count == 1, "no second sign-in within five minutes")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowReadRequestTests {
    let serial = "BK11-TEST-ULTRA"

    @Test func theReadRequestIsTheAppsHeader() {
        // Send_Header_Msg { msg: Header { seq: 1, from: "Android" } }: field 1 holds a header of 12 bytes, the header
        // holds seq (field 14, varint) and from (field 23, text).
        #expect(Array(EcoFlowProtobuf.propertyRequest(seq: 1)) == [0x0A, 0x0C, 0x70, 0x01, 0xBA, 0x01, 0x07, 0x41, 0x6E, 0x64, 0x72, 0x6F, 0x69, 0x64])
    }

    @Test func connectingAsksEachDeviceForItsState() async throws {
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: "pw-secret", serials: [serial], transport: transport) { _ in broker }
        _ = try await api.devices()

        let request = try #require(broker.published.first { $0.topic == "/app/42/\(serial)/thing/property/get" })
        #expect(request.payload == EcoFlowProtobuf.propertyRequest(seq: 1))
    }

    @Test func aReadingOutOfRangeIsClampedNotTrapped() {
        // The RIVER 3 Plus reports 4294967295 in one field: the level must clamp, not crash the bridge.
        #expect(EcoFlowState(soc: 4_294_967_295, power: EcoFlowState.Power()).battery.batteryLevel == 100)
        #expect(EcoFlowState(soc: -3, power: EcoFlowState.Power()).battery.batteryLevel == 0)
        #expect(EcoFlowState(soc: .nan, power: EcoFlowState.Power()).battery.batteryLevel == 0)
    }

    @Test func aPortableStationsAnswerGivesItsFlowsAndPorts() async throws {
        let stationSerial = "R631-TEST-1"
        let transport = FakeTransport(answers: signInAnswers.merging([
            "/app/user/device/list": #"{"code":"0","message":"Success","data":[{"sn":"R631-TEST-1","deviceName":"RIVER 3 Plus","productType":68}]}"#,
        ]) { $1 })
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: "pw-secret", serials: [stationSerial], transport: transport) { _ in broker }
        _ = try await api.devices()
        #expect(broker.subscriptions["/app/42/\(stationSerial)/thing/property/get_reply"] != nil)

        // The answer, one header per command: the station's (254/21) with totals 189 in and 192 out, the AC socket
        // 189.5 W and USB-A 3.2 W (outputs come negative), the AC input 189.5 W, the system's 93 % and the 95 % charge
        // limit; the battery's (32/2) with the precise charge 93.5 one level down; the battery pack's (32/50), whose
        // capacity sits where USB-C is.
        // Built in parts: Linux's compiler times out type-checking one long sum of arrays.
        let totals: [UInt8] = intField(3, 189) + intField(4, 192)
        let ports: [UInt8] = floatField(9, -3.2) + floatField(368, -189.5) + floatField(54, 189.5)
        let charge: [UInt8] = floatField(262, 93) + intField(270, 95)
        let station = totals + ports + charge
        let answer = header(254, 21, station) + header(32, 2, bytesField(1, floatField(15, 93.5)))
            + header(32, 50, intField(6, 93) + intField(11, 12800))
        broker.receive("/app/42/\(stationSerial)/thing/property/get_reply", payload: Data(answer))

        let listed = await eventually { (try? await api.devices())?.first?.kind == .portable }
        #expect(listed)
        let device = try #require(try await api.devices().first)
        #expect(device.name == "RIVER 3 Plus", "the name from the app's device list")
        #expect(device.model?.name == "RIVER 3 Plus", "the model from the serial number")
        #expect(device.tested)
        #expect(device.state.power.input == 189)
        #expect(device.state.power.output == 192)
        #expect(device.state.power.acOut == 189.5)
        #expect(device.state.power.acIn == 189.5)
        #expect(abs(device.state.power.usbA - 3.2) < 0.001)
        #expect(device.state.power.usbC == 0)
        #expect(device.state.battery.batteryLevel == 94, "the precise 93.5, rounded as the app shows it")

        // A push of the station's message carries what changed: merged, USB-A stays.
        broker.receive("/app/device/property/\(stationSerial)", payload: Data(header(254, 21, intField(4, 195))))
        let pushed = await eventually { (try? await api.devices())?.first?.state.power.output == 195 }
        #expect(pushed)
        #expect(abs((try await api.devices().first?.state.power.usbA ?? 0) - 3.2) < 0.001)

        // The next full answer leaves out USB-A, now at zero: it reads zero, not the last value.
        broker.receive("/app/42/\(stationSerial)/thing/property/get_reply",
                       payload: Data(header(254, 21, intField(3, 189) + intField(4, 189) + floatField(368, -189.5))))
        let cleared = await eventually { (try? await api.devices())?.first?.state.power.usbA == 0 }
        #expect(cleared)
    }

    @Test func aPowerBankGivesItsInputOutputAndCharge() async throws {
        let bank = "P513-TEST-1"
        let transport = FakeTransport(answers: signInAnswers.merging([
            "/app/user/device/list": #"{"code":"0","message":"Success","data":[{"sn":"P513-TEST-1","deviceName":"RAPID Pro X","productType":92}]}"#,
        ]) { $1 })
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: "pw-secret", serials: [bank], transport: transport) { _ in broker }
        _ = try await api.devices()

        // The station's message alone (254/21): 12.5 W out, the percentage in 262, a field 5 that stays at 100, and the
        // 95 % charge limit in 270.
        let body: [UInt8] = floatField(4, 12.5) + intField(5, 100)
        let message = header(254, 21, body + floatField(262, 4.85) + intField(270, 95))
        broker.receive("/app/42/\(bank)/thing/property/get_reply", payload: Data(message))
        let listed = await eventually { (try? await api.devices())?.first?.kind == .powerBank }
        #expect(listed)
        let device = try #require(try await api.devices().first)
        #expect(device.name == "RAPID Pro X")
        #expect(device.state.power.output == 12.5)
        #expect(device.state.power.input == 0)
        #expect(device.state.battery.batteryLevel == 5)
    }

    /// A DELTA 2 speaks JSON: it is asked for its latest quotas, answers them on `get_reply`, and pushes what changed
    /// under `params`. Its keys are the developer API's. It is shown untested.
    @Test func anOlderStationIsReadFromItsJSONQuotas() async throws {
        let delta = "R331-TEST-1"
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: "pw-secret", serials: [delta], transport: transport) { _ in broker }
        _ = try await api.devices()

        let request = try #require(broker.published.first { $0.topic == "/app/42/\(delta)/thing/property/get" })
        let asked = try #require(try JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
        #expect(asked["operateType"] as? String == "latestQuotas")

        broker.receive("/app/42/\(delta)/thing/property/get_reply", payload: Data(#"""
            {"operateType":"latestQuotas","data":{"online":1,"quotaMap":{"bms_emsStatus.lcdShowSoc":71,"pd.wattsInSum":320,
            "pd.wattsOutSum":85,"inv.inputWatts":0,"inv.outputWatts":60,"mppt.inWatts":320,"pd.model":"DELTA 2"}}}
            """#.utf8))
        let listed = await eventually { (try? await api.devices())?.first?.state.battery.batteryLevel == 71 }
        #expect(listed)
        var device = try #require(try await api.devices().first)
        #expect(device.model?.name == "DELTA 2")
        #expect(!device.tested)
        #expect(device.state.power.input == 320)
        #expect(device.state.power.solar == 320)
        #expect(device.state.power.acOut == 60)
        #expect(device.state.power.battery == 235, "what comes in less what goes out")
        #expect(device.state.battery.chargingState == 1)
        #expect(device.series.map(\.key) == ["input", "output", "solar", "acIn", "acOut"])

        broker.receive("/app/device/property/\(delta)", payload: Data(#"{"params":{"pd.wattsOutSum":400}}"#.utf8))
        _ = await eventually { (try? await api.devices())?.first?.state.power.output == 400 }
        device = try #require(try await api.devices().first)
        #expect(device.state.power.output == 400)
        #expect(device.state.battery.batteryLevel == 71, "a push keeps what it does not carry")
    }

    /// A PowerStream's heartbeat (20/1) is in tenths of a watt, its battery positive while it supplies the inverter.
    @Test func aPowerStreamReadsInTenthsOfAWatt() async throws {
        let inverter = "HW51-TEST-1"
        let transport = FakeTransport(answers: signInAnswers)
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: "pw-secret", serials: [inverter], transport: transport) { _ in broker }
        _ = try await api.devices()

        let panels: [UInt8] = intField(19, 2104) + intField(24, 1896)
        let battery: [UInt8] = intField(29, 1500) + intField(31, 64)
        let heartbeat = panels + battery + intField(38, 5500)
        broker.receive("/app/device/property/\(inverter)", payload: Data(header(20, 1, heartbeat)))
        let listed = await eventually { (try? await api.devices())?.first?.kind == .home }
        #expect(listed)
        let device = try #require(try await api.devices().first)
        #expect(device.state.battery.batteryLevel == 64)
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.001 }
        #expect(zip(device.state.power.panels, [210.4, 189.6]).allSatisfy(near) && device.state.power.panels.count == 2)
        #expect(near(device.state.power.solar, 400))
        #expect(near(device.state.power.home, 550))
        #expect(near(device.state.power.battery, -150), "the battery supplies the inverter: discharging")
        #expect(device.series.map(\.key) == ["solar", "home", "battery", "pv1", "pv2"], "no grid reading")
    }

    /// A model the plugin does not know is not asked for its state, not listed, and logged once with its product type.
    @Test func anUnknownModelIsLeftOutAndLoggedOnce() async throws {
        let unknown = "ZZ99-TEST-1"
        let transport = FakeTransport(answers: signInAnswers.merging([
            "/app/user/device/list": #"{"code":"0","message":"Success","data":[{"sn":"ZZ99-TEST-1","deviceName":"Mystery","productType":123}]}"#,
        ]) { $1 })
        let broker = FakeMQTTConnection()
        let api = EcoFlowAppAPI(email: "owner@example.test", password: "pw-secret", serials: [unknown], transport: transport) { _ in broker }
        _ = try await api.devices()
        #expect(!broker.published.contains { $0.topic.contains(unknown) })

        broker.receive("/app/device/property/\(unknown)", payload: propertyPayload(soc: 50, solar: 100))
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await api.devices().isEmpty)
        let changes = await api.schemaChanges()
        #expect(changes == ["Left out the device ZZ99… (product type 123) on the EcoFlow app's route: an unknown model, which the plugin does not read"])
        #expect(!changes.joined().contains(unknown), "the log shows the model's characters, not the serial number")
        _ = try await api.devices()
        #expect(await api.schemaChanges().isEmpty, "once")
    }

    @Test func anEncryptedBodyIsReadDecrypted() {
        // enc_type 1: the body is XOR-ed with the low byte of the sequence number (0x1234 -> 0x34).
        let body = intField(3, 189) + floatField(4, 192)
        let encrypted = body.map { $0 ^ 0x34 }
        let payload = Data(bytesField(1, bytesField(1, encrypted) + intField(6, 1) + intField(8, 254) + intField(9, 21) + intField(14, 0x1234)))
        let message = EcoFlowProtobuf.messages(payload).first
        #expect(message?.command == EcoFlowProtobuf.Command(function: 254, id: 21))
        #expect(EcoFlowProtobuf.numbers(message?.body ?? Data()) == [3: 189, 4: 192])
    }
}
