import Foundation
import HomeswiftNetwork
import Testing

@testable import HomeswiftDolphinPoolCleaner

/// The shadow client on HomeswiftNetwork's MQTT client and SigV4 presigning.
@Suite(.timeLimit(.minutes(1)))
struct AdapterTests {
    /// The URL the Homebridge plugin's `getSignedWebSocketUrl` builds for these inputs (computed with its code
    /// in Node.js), including the session token's encoding after the signature.
    @Test func presignedURLMatchesTheHomebridgePlugin() {
        let url = AWSSignatureV4.presignIoTURL(
            endpoint: "a12rqfdx55bdbv-ats.iot.eu-west-1.amazonaws.com", region: "eu-west-1",
            credentials: AWSCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", sessionToken: "new token/+="),
            date: Date(timeIntervalSince1970: 1_768_747_264), expires: ShadowClient.signatureLifetime,
            service: ShadowClient.iotService)
        #expect(url.absoluteString == "wss://a12rqfdx55bdbv-ats.iot.eu-west-1.amazonaws.com/mqtt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260118%2Feu-west-1%2Fiotdevicegateway%2Faws4_request&X-Amz-Date=20260118T144104Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=21a58aad0449fa79f8baa56752eb6b5f7801cc76047f515b09e9cb626a9117bd&X-Amz-Security-Token=new%20token%2F%2B%3D")
    }

    func client(credentials: @escaping @Sendable () -> IoTCredentials?) -> ShadowClient {
        ShadowClient(
            serialNumber: "E3086OFG2M", endpoint: "127.0.0.1:9", region: "eu-west-1", timing: .fast, logger: LogRecorder().logger, credentials: credentials)
    }

    @Test func missingCredentialsFailTheConnection() async {
        await #expect(throws: DolphinError.mqttConnectionFailed("AWS credentials not available")) { try await client(credentials: { nil }).connect() }
    }

    @Test func unreachableBrokerFailsTheConnection() async {
        await #expect(throws: DolphinError.self) { try await client(credentials: { .test }).connect() }
    }
}
