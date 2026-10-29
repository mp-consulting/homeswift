import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import Testing

@testable import HomeswiftEcoFlow

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowDeveloperStreamTests {
    let serial = "BK11-TEST-1"
    let topic = "/open/open-account/BK11-TEST-1/quota"

    private var answers: [String: String] {
        [
            "/iot-open/sign/certification": #"{"code":"0","message":"Success","data":{"url":"mqtt-e.example.test","port":8883,"certificateAccount":"open-account","certificatePassword":"open-password"}}"#,
            "/iot-open/sign/device/list": #"{"code":"0","message":"Success","data":[{"sn":"BK11-TEST-1","deviceName":"STREAM Ultra","online":1}]}"#,
            "/iot-open/sign/device/quota/all?sn=BK11-TEST-1": #"{"code":"0","message":"Success","data":{"cmsBattSoc":68,"powGetPvSum":1000,"powGetSysLoad":500,"powGetSysGrid":0,"powGetBpCms":300,"gridConnectionPower":200}}"#,
        ]
    }

    /// A cloud whose MQTT pushes come from `broker`.
    private func makeCloud(transport: FakeTransport, broker: FakeMQTTConnection) -> EcoFlowCloud {
        var cloud = EcoFlowCloud(accessKey: "access", secretKey: "secret", baseURL: EcoFlowCloud.euBaseURL, transport: transport)
        cloud.stream = EcoFlowDeveloperStream(cloud: cloud, mqtt: { _ in broker })
        return cloud
    }

    @Test func theBatteryAndThePowerComeFromTheMQTTPushes() async throws {
        let transport = FakeTransport(answers: answers)
        let broker = FakeMQTTConnection()
        let cloud = makeCloud(transport: transport, broker: broker)

        // Before any push, the REST quota is what the device reports: its power, and no level (its cmsBattSoc is the
        // system's).
        let before = try #require(try await cloud.devices().first)
        #expect(before.state.knowsBatteryLevel == false)
        #expect(before.state.power.solar == 1000)

        broker.receive(topic, payload: Data(#"{"f32ShowSoc":86.79,"powGetPvSum":1317,"powGetSysLoad":500,"powGetSysGrid":0,"powGetBpCms":300,"gridConnectionPower":1168.2,"powGetPv":700,"powGetPv2":617,"powGetPv3":0,"powGetPv4":0,"powGetSchuko1":12,"powGetSchuko2":0}"#.utf8))
        let updated = await eventually {
            (try? await cloud.devices().first)?.state.battery.batteryLevel == 87
        }
        #expect(updated, "the battery is f32ShowSoc rounded to the nearest percent, the app's figure (86.79 shows 87)")
        let device = try #require(try await cloud.devices().first)
        #expect(device.source == .mqtt)
        #expect(device.online, "a device that just pushed is online")
        #expect(device.state.power.solar == 1317)
        #expect(device.state.power.ac == 1168.2)
        #expect(device.state.power.home == 500)
        #expect(device.state.power.panels == [700, 617, 0, 0], "the panel inputs the pushes carry, PV1 first")
        #expect(device.state.power.ac1 == 12)
        #expect(device.state.power.ac2 == 0)
        #expect(broker.subscriptions[topic] != nil)
    }

    @Test func aPartialPushLeavesTheWholeDeviceOnTheRESTQuota() async throws {
        let transport = FakeTransport(answers: answers)
        let broker = FakeMQTTConnection()
        let cloud = makeCloud(transport: transport, broker: broker)
        _ = try await cloud.devices()

        // A push with only some of the values would mix the two sources, so the REST quota stands for the device.
        broker.receive(topic, payload: Data(#"{"f32ShowSoc":86.79,"powGetPvSum":1317}"#.utf8))
        let listed = await eventually {
            (try? await cloud.devices().first)?.source == .rest
        }
        #expect(listed)
        let device = try #require(try await cloud.devices().first)
        #expect(device.state.knowsBatteryLevel == false, "nor the push's level: one source for the whole device")
        #expect(device.state.power.solar == 1000, "the REST value, not the push's")
    }

    /// A push is read from its bytes: the wanted names' numbers, the others skipped, text, literals and nested values
    /// too, as JSONSerialization reads them; what is not an object, or has an escaped name, is left to it (nil).
    @Test func aPushsWantedNumbersAreReadFromItsBytes() throws {
        let wanted: Set<String> = ["powGetPvSum", "f32ShowSoc", "gridConnectionPower"]
        let push = #" { "powGetPvSum" : 512.5, "powGetPvSumX": 1, "f32ShowSoc":-8.25e1 ,"gridConnectionPower":0,"other":12345678901234} "#
        #expect(EcoFlowDeveloperStream.numbers(Data(push.utf8), wanted: wanted) == ["powGetPvSum": 512.5, "f32ShowSoc": -82.5, "gridConnectionPower": 0])
        #expect(EcoFlowDeveloperStream.numbers(Data("{}".utf8), wanted: wanted) == [:])
        let mixed = #"{"typeCode":"pd \"303\" {x}","f32ShowSoc":83,"list":[1,{"powGetPvSum":9},"]"],"on":true,"off":false,"none":null,"#
            + #""nested":{"a":{"b":[]}},"powGetPvSum":1042.0,"text":"\\","gridConnectionPower":"12"}"#
        let read = try #require(EcoFlowDeveloperStream.numbers(Data(mixed.utf8), wanted: wanted))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(mixed.utf8)) as? [String: Any])
        #expect(read == json.compactMapValues { $0 as? NSNumber }.filter { wanted.contains($0.key) }.mapValues(\.doubleValue)
            .filter { !["on", "off"].contains($0.key) })
        #expect(read == ["f32ShowSoc": 83, "powGetPvSum": 1042])
        for other in [#"{"pow\u0047etPvSum":1}"#, #"{"powGetPvSum":1"#, #"{"powGetPvSum":1}x"#, #"{"a":tru}"#, #"{"a":"x}"#, "[1]", ""] {
            #expect(EcoFlowDeveloperStream.numbers(Data(other.utf8), wanted: wanted) == nil, "\(other)")
        }
    }

    @Test func theMQTTLoginIsTheCertificate() async throws {
        let transport = FakeTransport(answers: answers)
        let cloud = makeCloud(transport: transport, broker: FakeMQTTConnection())
        let account = try await cloud.mqttAccount()
        #expect(account == EcoFlowCloud.MQTTAccount(host: "mqtt-e.example.test", port: 8883, account: "open-account", password: "open-password"))
    }
}
