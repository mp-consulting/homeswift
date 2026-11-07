import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftEcoFlow

// The writes (docs/clean-room/EcoFlowWrites.md): the spec's vectors byte for byte, both routes against the fakes, and
// the plugin's Outlets, limits and gating. The serial numbers are the spec's fakes.

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func hex(_ bytes: [UInt8]) -> String { hex(Data(bytes)) }
private func bytes(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! })
}

private let appSignIn: [String: String] = [
    "/auth/login": #"{"code":"0","message":"Success","data":{"token":"session-token","user":{"userId":42}}}"#,
    "/iot-auth/app/certification": #"{"code":"0","message":"Success","data":{"url":"mqtt.example.test","port":8883,"certificateAccount":"broker-account","certificatePassword":"broker-password"}}"#,
]

private func device(_ serial: String, online: Bool = true) -> EcoFlowDevice {
    var device = EcoFlowDevice(id: serial, name: EcoFlowModel.describe(serial: serial), online: online, model: EcoFlowModel.model(serial: serial))
    device.state = EcoFlowState(soc: 60, power: EcoFlowState.Power())
    return device
}

/// Answers the first write published to `serial` with `reply` on its `set_reply`.
private func answer(_ broker: FakeMQTTConnection, serial: String, with reply: Data) -> Task<Void, Never> {
    Task {
        _ = await eventually { broker.published.contains { $0.topic == "/app/42/\(serial)/thing/property/set" } }
        broker.receive("/app/42/\(serial)/thing/property/set_reply", payload: reply)
    }
}

/// A ConfigWriteAck (254/18) with `config_ok`.
private func ack(_ ok: UInt64) -> Data {
    EcoFlowWrites.message(pdata: EcoFlowProtobuf.varintField(1, 5) + EcoFlowProtobuf.varintField(2, ok),
                          header: EcoFlowWrites.Header(cmdID: 18, seq: 1, version: 19))
}

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowWritesTests {
    // MARK: - The spec's vectors (section 6)

    @Test func theStreamVectorsMatch() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let on = try #require(EcoFlowWrites.protobufPayload(.output(.ac, true), family: .stream, serial: "BK11ZZZZ", seq: 1000, now: now))
        #expect(hex(on) == "0a310a093080e2cfaa06e01701102018022001280140fe0148115009580170e8077838800103880101ba0107416e64726f6964")
        let off = try #require(EcoFlowWrites.protobufPayload(.output(.ac, false), family: .stream, serial: "BK11ZZZZ", seq: 1000, now: now))
        #expect(hex(off) == "0a310a093080e2cfaa06e01700102018022001280140fe0148115009580170e8077838800103880101ba0107416e64726f6964")
        let ac2 = try #require(EcoFlowWrites.protobufPayload(.output(.ac2, true), family: .stream, serial: "BK11ZZZZ", seq: 1000, now: now))
        #expect(hex(ac2) == hex(on).replacingOccurrences(of: "e017", with: "e817"))
        #expect(hex(ac2).contains("0a093080e2cfaa06e81701"))
    }

    @Test func theRiver3VectorMatches() throws {
        let on = try #require(EcoFlowWrites.protobufPayload(.output(.ac, true), family: .river3, serial: "R651ZZZZ00000001", seq: 1000, now: Date()))
        #expect(hex(on) == "0a340a03e00401102018022001280140fe0148115003580170e8077801800113880101ca0110523635315a5a5a5a3030303030303031")
    }

    @Test func theSingleFieldPayloadsMatch() throws {
        func pdata(_ write: EcoFlowWrite, _ family: EcoFlowWrites.Family) throws -> String {
            let field = try #require(EcoFlowWrites.configField(write, family: family))
            return hex(EcoFlowProtobuf.varintField(field.number, field.value))
        }
        #expect(try pdata(.output(.dc12v, true), .river3) == "900101")
        #expect(try pdata(.output(.usb, true), .delta3) == "980101")
        #expect(try pdata(.chargeLimit(80), .delta3) == "880250")
        #expect(try pdata(.dischargeLimit(10), .delta3) == "90020a")
        #expect(try pdata(.output(.ac2, true), .delta3) == "c81701")
        #expect(try pdata(.output(.ac, true), .deltaPro3) == "7801")
        #expect(try pdata(.output(.ac2, true), .deltaPro3) == "800101")
        #expect(EcoFlowWrites.configField(.output(.usb, true), family: .deltaPro3) == nil, "left out (5.3)")
    }

    @Test func theReplyIsRead() {
        // action_id 5, config_ok 1, the AC echoed on; then refused, base64-encoded, and JSON.
        let body: [UInt8] = Array(bytes("08051001e00401"))
        let accepted = EcoFlowWrites.message(pdata: body, header: EcoFlowWrites.Header(cmdID: 18, seq: 7, version: 19))
        #expect(EcoFlowWrites.reply(accepted) == .accepted)
        #expect(EcoFlowWrites.reply(ack(0)) == .refused("config_ok 0"))
        #expect(EcoFlowWrites.reply(Data(ack(0).base64EncodedString().utf8)) == .refused("config_ok 0"))
        #expect(EcoFlowWrites.reply(Data(#"{"code":"0","data":{"ack":0},"id":1}"#.utf8)) == .accepted)
        #expect(EcoFlowWrites.reply(Data(#"{"code":"1","message":"bad"}"#.utf8)) == .refused("bad"))
        #expect(EcoFlowWrites.reply(Data([0xFF, 0xFF])) == nil)
    }

    // MARK: - The developer API's signature (2.2)

    @Test func thePagesSignatureVectorMatches() {
        let body = EcoFlowWrites.Body.object(["sn": .string("123456789"), "params": .object(["cmdSet": .int(11), "id": .int(24), "eps": .int(0)])])
        let joined = body.flattened().sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        #expect(joined == "params.cmdSet=11&params.eps=0&params.id=24&sn=123456789")
        #expect(EcoFlowCloud.signature(query: body.flattened(), accessKey: "Fp4SvIprYSDPXtYJidEtUAd1o", secretKey: "WIbFEKre0s6sLnh4ei7SPUeYnptHG6V",
                                       nonce: "345164", timestamp: 1_671_171_709_428)
                == "07c13b65e037faf3b153d51613638fa80003c4c38d2407379a7f52851af1473e")
    }

    @Test func theDelta2USBVectorMatches() throws {
        let model = try #require(EcoFlowModel.model(serial: "R331ZZZZ00000001"))
        let body = try #require(EcoFlowWrites.developerBody(.output(.usb, true), model: model, serial: "R331ZZZZ00000001", id: 123_456_789))
        let joined = body.flattened().sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        #expect(joined == "id=123456789&moduleType=1&operateType=dcOutCfg&params.enabled=1&sn=R331ZZZZ00000001&version=1.0")
        #expect(EcoFlowCloud.signature(query: body.flattened(), accessKey: "TESTACCESSKEY0000", secretKey: "TESTSECRETKEY0000",
                                       nonce: "123456", timestamp: 1_700_000_000_000)
                == "4a7cd3628b090a2f2041ed14d7c9a9660f079a27900a6f19cc8a6e8f480497ec")
    }

    // MARK: - The developer API

    private func cloud(_ transport: FakeTransport) -> EcoFlowCloud {
        var cloud = EcoFlowCloud(accessKey: "TESTACCESSKEY0000", secretKey: "TESTSECRETKEY0000", baseURL: URL(string: "https://api.example.test")!, transport: transport)
        cloud.nonce = { "123456" }
        cloud.timestamp = { 1_700_000_000_000 }
        cloud.writeID = { 123_456_789 }
        return cloud
    }

    @Test func theDeveloperAPIPutsASignedBody() async throws {
        let transport = FakeTransport(answers: ["/iot-open/sign/device/quota": #"{"code":"0","message":"Success"}"#])
        try await cloud(transport).set(.output(.usb, true), on: device("R331ZZZZ00000001"))
        let request = try #require(transport.requests.withLockedValue { $0 }.first)
        #expect(request.method == "PUT")
        #expect(request.url.absoluteString == "https://api.example.test/iot-open/sign/device/quota")
        #expect(request.header("sign") == "4a7cd3628b090a2f2041ed14d7c9a9660f079a27900a6f19cc8a6e8f480497ec")
        #expect(request.header("accessKey") == "TESTACCESSKEY0000")
        #expect(request.header("Content-Type") == "application/json;charset=UTF-8")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect(body["operateType"] as? String == "dcOutCfg")
        #expect(body["moduleType"] as? Int == 1)
        #expect((body["params"] as? [String: Any])?["enabled"] as? Int == 1)
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains("TESTSECRETKEY0000") == false)
    }

    @Test func theDeveloperAPIsRefusalThrows() async throws {
        let transport = FakeTransport(answers: ["/iot-open/sign/device/quota": #"{"code":"8521","message":"device offline"}"#])
        await #expect(throws: EcoFlowCloud.Failure.api(code: "8521", message: "device offline")) {
            try await cloud(transport).set(.chargeLimit(90), on: device("R331ZZZZ00000001"))
        }
    }

    /// A STREAM's, a DELTA 3 Max's and a DELTA Pro 3's developer bodies carry booleans whose signing is not known: none
    /// is sent there. A DELTA 2's AC carries values the plugin cannot read: it goes by the app's route.
    @Test func theDeveloperAPISendsIntegerBodiesOnly() async throws {
        let transport = FakeTransport(answers: [:])
        let api = cloud(transport)
        for serial in ["BK11ZZZZ", "D3N1ZZZZ", "MR51ZZZZ"] {
            #expect(api.writes(for: device(serial)).isEmpty, "\(serial)")
            await #expect(throws: EcoFlowWriteError.self) { try await api.set(.output(.ac, true), on: device(serial)) }
        }
        #expect(api.writes(for: device("R331ZZZZ")) == EcoFlowCapabilities(outputs: [.dc12v: .developer, .usb: .developer], limits: .developer))
        #expect(transport.requests.withLockedValue { $0 }.isEmpty)
        // With the app's route beside it, the AC goes there and the rest by the developer API; a STREAM by the app's.
        let both = EcoFlowAll(apis: [api, EcoFlowAppAPI(email: "a@example.test", password: "p", serials: [], transport: transport) { _ in FakeMQTTConnection() }])
        #expect(both.writes(for: device("R331ZZZZ")) == EcoFlowCapabilities(outputs: [.ac: .app, .dc12v: .developer, .usb: .developer], limits: .developer))
        #expect(both.writes(for: device("BK11ZZZZ")) == EcoFlowCapabilities(outputs: [.ac: .app, .ac2: .app], limits: .app))
    }

    /// A STREAM's sockets are read back from its developer pushes' booleans (3.1).
    @Test func theRelaysAreReadBackFromThePushes() {
        let numbers = EcoFlowDeveloperStream.numbers(Data(#"{"relay2Onoff":true,"relay3Onoff":false,"cmsMaxChgSoc":95,"other":true}"#.utf8),
                                                     wanted: EcoFlowModel.streamDeveloper.all)
        #expect(numbers == ["relay2Onoff": 1, "relay3Onoff": 0, "cmsMaxChgSoc": 95])
        let state = EcoFlowState(readings: numbers ?? [:], keys: EcoFlowModel.streamDeveloper)
        #expect(state.outputs == [.ac: true, .ac2: false])
        #expect(state.chargeLimit == 95)
        // A DELTA 3 Max's outputs are on when not 4; a DELTA Pro Ultra's DC is bit 5 of its flags.
        #expect(EcoFlowState(readings: ["flowInfoAcOut": 2, "flowInfo12v": 4], keys: EcoFlowModel.delta3Developer).outputs == [.ac: true, .dc12v: false])
        let ultra = EcoFlowModel.model(serial: "Y711ZZZZ")?.developer ?? EcoFlowModel.Keys()
        #expect(EcoFlowState(readings: ["hs_yj751_pd_appshow_addr.showFlag": 0b100100], keys: ultra).outputs == [.dc12v: true])
    }

    // MARK: - The app's route

    private func appAPI(_ broker: FakeMQTTConnection, timeout: Duration = .seconds(5)) -> EcoFlowAppAPI {
        let options = EcoFlowAppAPI.WriteOptions(timeout: timeout, seq: { 1000 }, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        return EcoFlowAppAPI(email: "owner@example.test", password: "pw", serials: ["BK11ZZZZ", "R651ZZZZ00000001", "R331ZZZZ"],
                             transport: FakeTransport(answers: appSignIn), writes: options) { _ in broker }
    }

    @Test func aStreamWriteIsPublishedAndAcknowledged() async throws {
        let broker = FakeMQTTConnection()
        let api = appAPI(broker)
        _ = try await api.devices()
        #expect(broker.subscriptions["/app/42/BK11ZZZZ/thing/property/set_reply"] != nil)
        let replying = answer(broker, serial: "BK11ZZZZ", with: ack(1))
        try await api.set(.output(.ac, true), on: device("BK11ZZZZ"))
        await replying.value
        let sent = try #require(broker.published.first { $0.topic == "/app/42/BK11ZZZZ/thing/property/set" })
        #expect(hex(sent.payload) == "0a310a093080e2cfaa06e01701102018022001280140fe0148115009580170e8077838800103880101ba0107416e64726f6964")

        // The acknowledged state stands for the readings, which have no read-back of the sockets on this route.
        broker.receive("/app/device/property/BK11ZZZZ", payload: Data(EcoFlowProtobuf.bytesField(1, EcoFlowProtobuf.bytesField(1, EcoFlowProtobuf.varintField(6, 58))
            + EcoFlowProtobuf.varintField(8, 32) + EcoFlowProtobuf.varintField(9, 50))))
        #expect(await eventually { (try? await api.devices())?.first { $0.id == "BK11ZZZZ" }?.state.outputs[.ac] == true })
    }

    @Test func aRefusedAppWriteThrows() async throws {
        let broker = FakeMQTTConnection()
        let api = appAPI(broker)
        _ = try await api.devices()
        let replying = answer(broker, serial: "R651ZZZZ00000001", with: ack(0))
        await #expect(throws: EcoFlowWriteError.refused("config_ok 0")) {
            try await api.set(.output(.dc12v, false), on: device("R651ZZZZ00000001"))
        }
        await replying.value
        let sent = try #require(broker.published.first { $0.topic == "/app/42/R651ZZZZ00000001/thing/property/set" })
        #expect(EcoFlowProtobuf.messages(sent.payload).first.map { hex($0.body) } == "900100")
    }

    @Test func anUnansweredAppWriteThrows() async throws {
        let broker = FakeMQTTConnection()
        let api = appAPI(broker, timeout: .milliseconds(200))
        _ = try await api.devices()
        await #expect(throws: EcoFlowWriteError.unanswered) {
            try await api.set(.chargeLimit(80), on: device("R651ZZZZ00000001"))
        }
    }

    /// A DELTA 2 speaks JSON (4.2): its write is done once its readings show it, which it is asked for at once.
    @Test func aJSONWriteIsConfirmedByTheReadings() async throws {
        let broker = FakeMQTTConnection()
        let api = appAPI(broker)
        _ = try await api.devices()
        let pushing = Task {
            _ = await eventually { broker.published.contains { $0.topic == "/app/42/R331ZZZZ/thing/property/set" } }
            broker.receive("/app/device/property/R331ZZZZ", payload: Data(#"{"params":{"bms_emsStatus.lcdShowSoc":71,"mppt.cfgAcEnabled":1}}"#.utf8))
        }
        try await api.set(.output(.ac, true), on: device("R331ZZZZ"))
        await pushing.value
        let sent = try #require(broker.published.first { $0.topic == "/app/42/R331ZZZZ/thing/property/set" })
        let body = try #require(try JSONSerialization.jsonObject(with: sent.payload) as? [String: Any])
        #expect(body["moduleType"] as? Int == 5)
        #expect(body["operateType"] as? String == "acOutCfg")
        #expect(body["from"] as? String == "Homeswift")
        #expect((body["params"] as? [String: Any])?.compactMapValues { $0 as? Int } == ["enabled": 1, "out_voltage": -1, "out_freq": 255, "xboost": 255])
        #expect(broker.published.filter { $0.topic == "/app/42/R331ZZZZ/thing/property/get" }.count >= 2, "asked for its readings after the write")
    }

    @Test func theLimitsAreClamped() throws {
        let table = try #require(EcoFlowWrites.table(EcoFlowModel.model(serial: "BK11ZZZZ")))
        #expect(EcoFlowWrites.clamp(charge: 120, discharge: -5, table: table) == (100, 0))
        #expect(EcoFlowWrites.clamp(charge: 40, discharge: 10, table: table) == (50, 10))
        // The charge limit stays above the device's discharge limit.
        var narrow = table
        narrow.charge = 20...100
        #expect(EcoFlowWrites.clamp(charge: 20, discharge: nil, current: (nil, 25), table: narrow) == (26, nil))
        let powerStream = try #require(EcoFlowWrites.table(EcoFlowModel.model(serial: "HW51ZZZZ")))
        #expect(EcoFlowWrites.clamp(charge: 60, discharge: 0, table: powerStream) == (70, 1))
    }

    // MARK: - The plugin

    let environment = TestEnvironment()
    let stream = "BK11-TEST-ULTRA"

    private func outlet(_ host: PluginHost, _ serial: String, _ subtype: String) -> Service? {
        host.mainBridge.server.accessories.first { $0.id == EcoFlowPlugin.accessoryID(deviceID: serial) }?.service(.outlet, subtype: subtype)
    }

    @Test func aStreamsSocketsAreOutlets() async throws {
        await environment.api.add(device(stream))
        let host = try await environment.start(configure: { $0.holdFor = .milliseconds(300) })
        #expect(await eventually { outlet(host, stream, "ac") != nil })
        let ac1 = try #require(outlet(host, stream, "ac"))
        #expect(ac1.characteristic(.name).value == .string("AC1"))
        #expect(ac1.characteristic(.outletInUse).value == .bool(true))
        #expect(outlet(host, stream, "ac2")?.characteristic(.name).value == .string("AC2"))
        #expect(outlet(host, stream, "dc12v") == nil)

        try await ac1.characteristic(.on).write(.bool(true))
        #expect(await environment.api.sent.map(\.write) == [.output(.ac, true)])
        #expect(ac1.characteristic(.on).value == .bool(true))

        // A reading from before the device caught up does not flip it back; once the hold has passed, the reading wins.
        await environment.api.update(deviceID: stream) { $0.outputs[.ac] = false }
        await environment.plugin?.refresh()
        #expect(ac1.characteristic(.on).value == .bool(true))
        #expect(await eventually {
            await environment.plugin?.refresh()
            return ac1.characteristic(.on).value == .bool(false)
        })
        await host.stop()
    }

    @Test func aRefusedWriteFailsInHomeKit() async throws {
        await environment.api.add(device(stream))
        let host = try await environment.start()
        #expect(await eventually { outlet(host, stream, "ac") != nil })
        let ac1 = try #require(outlet(host, stream, "ac"))
        await environment.api.refuse(true)
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) {
            try await ac1.characteristic(.on).write(.bool(true))
        }
        #expect(ac1.characteristic(.on).value == .bool(false))
        await host.stop()
    }

    @Test func thePageSwitchesAnOutput() async throws {
        await environment.api.add(device(stream))
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(await eventually { outlet(host, stream, "ac2") != nil })
        let listed = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "power", user: "admin")).json["devices"]?.arrayValue ?? []
        let card = try #require(listed.first { $0["id"]?.stringValue == stream })
        #expect(card["outputs"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["ac", "ac2"])
        #expect(card["writesTested"] == .bool(true))
        let switched = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "output", body: ["id": .string(stream), "output": "ac2", "on": true], user: "admin"))
        #expect(switched.status == 200)
        #expect(await environment.api.sent.map(\.write) == [.output(.ac2, true)])
        #expect(outlet(host, stream, "ac2")?.characteristic(.on).value == .bool(true))
        let missing = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "output", body: ["id": .string(stream), "output": "usb", "on": true], user: "admin"))
        #expect(missing.status == 404)
        await host.stop()
    }

    /// A DELTA 2's writes were not seen working: no Outlets unless `untestedWrites` is on, and the page marks them.
    @Test func anUncheckedModelWritesOnlyWithUntestedWrites() async throws {
        await environment.api.add(device("R331-TEST-1"))
        let host = try await environment.start()
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == EcoFlowPlugin.accessoryID(deviceID: "R331-TEST-1") } })
        #expect(outlet(host, "R331-TEST-1", "ac") == nil)
        await host.stop()

        let untested = TestEnvironment()
        await untested.api.add(device("R331-TEST-1"))
        let second = try await untested.start(settings: ["untestedWrites": true])
        #expect(await eventually { outlet(second, "R331-TEST-1", "ac") != nil })
        #expect(outlet(second, "R331-TEST-1", "dc12v") != nil)
        #expect(outlet(second, "R331-TEST-1", "usb")?.characteristic(.name).value == .string("USB"))
        let plugin = try #require(untested.plugin)
        let listed = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "power", user: "admin")).json["devices"]?.arrayValue ?? []
        #expect(listed.first { $0["id"]?.stringValue == "R331-TEST-1" }?["writesTested"] == .bool(false))
        await second.stop()
    }

    /// The limits come from the device's Accessory Settings, clamped, and are sent once: a device that already has them
    /// is not sent them again.
    @Test func theLimitsComeFromTheAccessorySettings() async throws {
        var unit = device(stream)
        unit.state.chargeLimit = 90
        unit.state.dischargeLimit = 10
        await environment.api.add(unit)
        let host = try await environment.start(settings: ["_accessories": [self.stream: ["chargeLimit": 120, "dischargeLimit": 10]]])
        #expect(await eventually { await environment.api.sent.count == 1 })
        #expect(await environment.api.sent.map(\.write) == [.chargeLimit(100)], "clamped; the discharge limit is already the device's")
        await environment.plugin?.refresh()
        await environment.plugin?.refresh()
        #expect(await environment.api.sent.count == 1, "sent once")
        await host.stop()
    }
}
