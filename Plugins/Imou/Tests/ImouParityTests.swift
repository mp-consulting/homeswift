import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftImou

/// The addendum's signatures (docs/clean-room/Imou.md, "Addendum").
@Suite(.timeLimit(.minutes(1)))
struct ImouParityTests {
    func cloud(_ fake: FakeImouCloud, now: @escaping @Sendable () -> Date = { Date() }) -> ImouCloud {
        ImouCloud(appID: FakeImouCloud.appID, appSecret: FakeImouCloud.appSecret, region: .sg, apiURL: nil,
                  environment: ImouCloud.Environment(transport: fake, now: now), logger: testLogger)
    }

    // MARK: Signatures

    @Test func bothSignaturesMatchTheAddendumsVectors() {
        let secret = FakeImouCloud.appSecret
        #expect(ImouCloud.password(appSecret: secret) == "ff25d2389ab7917a77cc0c3546331401054d53cb7b2edeedb7b4e7742bb5286d")
        #expect(ImouCloud.password(appSecret: "test123456789test123456789") == "1f2da89b2fab404859f02bcc80e8521bc7a63af3e5b1da5318f7cf7c56836b09")
        let rows: [(Int, String, String, String, String)] = [
            (1_700_000_000, "Xq3vP9-nonce-0001", secret, "55dfb1b302fa7e16b04c70224fa9f111", "/KGDnPf4k0KNIoUMRkEtRBoKUOkWjrLVE0o0BDIymdQ="),
            (1_762_300_000, "nonce-ptz-0002", secret, "7a6b5b38ad6ccd64362550b46107e15f", "a+nlbu3RzTvpjkaZszXXHDT2Oa/PlfD3pVpNGPVMBuk="),
            (1_762_300_060, "nonce-cam-0003", secret, "702096723e475730eab7927aac7470a4", "iLddnaTOjE9xcTr72RwfBRJifAscu4yd810ozYxTgjs="),
            // The documentation's own worked example.
            (1_706_511_734, "f5a1ae2d-c09c-4d39-a744-83a5c2c653c2", "test123456789test123456789", "fd37b62889e4757c58b8f3bf05fb9976",
             "xjhCQBoJ9hRDsCjyDcHjtDNzRZ3ZJezcawsfWeiaoxU="),
        ]
        for (time, nonce, secret, md5, hmac) in rows {
            #expect(ImouCloud.sign(.md5, time: time, nonce: nonce, appSecret: secret) == md5)
            #expect(ImouCloud.sign(.hmac, time: time, nonce: nonce, appSecret: secret) == hmac)
        }
    }

    @Test func theRequestBodiesAreTheAddendums() throws {
        let ptz = ImouCloud.body(appID: FakeImouCloud.appID, appSecret: FakeImouCloud.appSecret, params: [
            "deviceId": "TEST000CAM1", "channelId": "0", "operation": "2", "duration": 500,
        ], token: "At_test", time: 1_762_300_000, nonce: "nonce-ptz-0002", id: "ptz-1")
        #expect(ptz == (try JSONValue(string: """
            {"id":"ptz-1","system":{"ver":"1.0","appId":"lcaa11bb22cc33dd44","sign":"a+nlbu3RzTvpjkaZszXXHDT2Oa/PlfD3pVpNGPVMBuk=","time":1762300000,"nonce":"nonce-ptz-0002"},
             "params":{"token":"At_test","deviceId":"TEST000CAM1","channelId":"0","operation":"2","duration":500}}
            """)))
        let privacy = ImouCloud.body(appID: FakeImouCloud.appID, appSecret: FakeImouCloud.appSecret, signing: .md5, params: [
            "deviceId": "TEST000CAM1", "channelId": "0", "enableType": "closeCamera",
        ], token: "At_test", time: 1_762_300_060, nonce: "nonce-cam-0003", id: "cam-1")
        #expect(privacy == (try JSONValue(string: """
            {"id":"cam-1","system":{"ver":"1.0","appId":"lcaa11bb22cc33dd44","sign":"702096723e475730eab7927aac7470a4","time":1762300060,"nonce":"nonce-cam-0003"},
             "params":{"token":"At_test","deviceId":"TEST000CAM1","channelId":"0","enableType":"closeCamera"}}
            """)))
    }

    @Test func aCloudThatRefusesTheHMACIsSignedWithMD5FromThenOn() async throws {
        let fake = FakeImouCloud()
        fake.addCamera()
        fake.state.withLockedValue { $0.refusesHMAC = true }
        let cloud = cloud(fake)
        _ = try await cloud.online("TEST000CAM1")
        _ = try await cloud.online("TEST000CAM1")
        #expect(await cloud.signing == .md5)
        let signs = fake.calls.compactMap { $0.body["system"]?["sign"]?.stringValue }
        // The HMAC once (refused), then MD5 hex for the token and each call.
        #expect(signs.count == 4 && signs[0].hasSuffix("=") && signs.dropFirst().allSatisfy { $0.count == 32 && !$0.contains("=") })
        #expect(fake.calls("accessToken").count == 2)
        // An account that takes the documented form keeps it.
        let documented = FakeImouCloud()
        documented.addCamera()
        let other = self.cloud(documented)
        _ = try await other.online("TEST000CAM1")
        #expect(await other.signing == .hmac && documented.calls.count == 2)
    }
}
