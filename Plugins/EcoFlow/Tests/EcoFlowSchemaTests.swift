import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import Testing

@testable import HomeswiftEcoFlow

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowSchemaTests {
    @Test func aMissingOrMistypedFieldIsAProblem() {
        // The port may be text or a number (the API answers text today); a list is not a port, and the password is missing.
        let answer: [String: Any] = ["url": "mqtt.example.test", "port": ["8883"], "certificateAccount": "account"]
        #expect(EcoFlowSchema.certification.problems(in: answer) == ["port", "certificatePassword"])
        #expect(EcoFlowSchema.certification.problems(in: ["url": "x", "port": "8883", "certificateAccount": "a", "certificatePassword": "p"]).isEmpty)
        #expect(EcoFlowSchema.certification.problems(in: ["url": "x", "port": 8883, "certificateAccount": "a", "certificatePassword": "p"]).isEmpty)
    }

    @Test func aListsItemsAreCheckedOneByOne() {
        let answer: [[String: Any]] = [["sn": "A", "deviceName": "STREAM", "online": 1], ["sn": "B", "online": 0]]
        #expect(EcoFlowSchema.deviceList.problems(in: answer) == ["[*].deviceName"])
        #expect(EcoFlowSchema.deviceList.problems(in: "not a list") == ["items"])
    }

    @Test func aChangeIsReportedOnceAndAMatchAgainIsReportedOnce() async {
        let watch = EcoFlowNotices()
        let broken: [String: Any] = ["url": "x"]
        let good: [String: Any] = ["url": "x", "port": 8883, "certificateAccount": "a", "certificatePassword": "p"]

        await watch.record(.certification, problems: EcoFlowSchema.certification.problems(in: good))
        await watch.record(.certification, problems: EcoFlowSchema.certification.problems(in: good))
        #expect(await watch.drain().isEmpty, "a steady answer is silent")

        await watch.record(.certification, problems: EcoFlowSchema.certification.problems(in: broken))
        await watch.record(.certification, problems: EcoFlowSchema.certification.problems(in: broken))
        let changed = await watch.drain()
        #expect(changed.count == 1)
        #expect(changed.first?.contains("port") == true)

        await watch.record(.certification, problems: EcoFlowSchema.certification.problems(in: good))
        #expect(await watch.drain().count == 1, "the answer matches again")
    }

    @Test func aChangedAnswerFromTheDeveloperAPIIsLoggedThroughTheCloud() async throws {
        let transport = FakeTransport(answers: [
            "/iot-open/sign/device/list": #"{"code":"0","message":"Success","data":[{"sn":"SN-1","online":1}]}"#,
            "/iot-open/sign/device/quota/all?sn=SN-1": #"{"code":"0","message":"Success","data":{"cmsBattSoc":68}}"#,
        ])
        let cloud = EcoFlowCloud(accessKey: "access", secretKey: "secret", baseURL: EcoFlowCloud.euBaseURL, transport: transport)
        _ = try await cloud.devices()

        let changes = await cloud.schemaChanges()
        #expect(changes.contains { $0.contains("device/list") && $0.contains("deviceName") })
        #expect(await cloud.schemaChanges().isEmpty, "read once, not again")
    }
}
