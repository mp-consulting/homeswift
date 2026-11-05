import Foundation
import HomeswiftAI
import HomeswiftFFmpeg
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftImou

/// The cloud's signing and calls, the camera's Digest and event stream, against the spec's vectors
/// (docs/clean-room/Imou.md, section 9).
@Suite(.timeLimit(.minutes(1)))
struct ImouProtocolTests {
    func cloud(_ fake: FakeImouCloud, nonce: @escaping @Sendable () -> String = { UUID().uuidString }) -> ImouCloud {
        ImouCloud(appID: FakeImouCloud.appID, appSecret: FakeImouCloud.appSecret, region: .sg, apiURL: nil,
                  environment: ImouCloud.Environment(transport: fake, nonce: nonce), logger: testLogger)
    }

    @Test func theSignatureMatchesBothVectors() {
        #expect(ImouCloud.sign(time: 1_700_000_000, nonce: "Xq3vP9-nonce-0001", appSecret: "a1b2c3d4e5f60718293a4b5c6d7e8f90") == "55dfb1b302fa7e16b04c70224fa9f111")
        #expect(ImouCloud.sign(time: 1_762_257_600, nonce: "abc", appSecret: "secret") == "8585679928d99b9b73ba46ec404dbcf6")
    }

    @Test func theBodyIsTheSpecsDeviceOnlineRequest() throws {
        let body = ImouCloud.body(appID: "lcaa11bb22cc33dd44", appSecret: "a1b2c3d4e5f60718293a4b5c6d7e8f90", signing: .md5, params: ["deviceId": "8L0DF93PAZ55FD2"],
                                  token: "At_test", time: 1_700_000_000, nonce: "Xq3vP9-nonce-0001", id: "42")
        let expected = try JSONValue(string: """
            {"system":{"ver":"1.0","sign":"55dfb1b302fa7e16b04c70224fa9f111","appId":"lcaa11bb22cc33dd44","time":1700000000,"nonce":"Xq3vP9-nonce-0001"},
             "params":{"deviceId":"8L0DF93PAZ55FD2","token":"At_test"},"id":"42"}
            """)
        #expect(body == expected)
        // The time is a JSON integer, the same as in the signed text.
        #expect(body.text().contains("\"time\":1700000000"))
        // accessToken goes without a token.
        let token = ImouCloud.body(appID: "a", appSecret: "b", params: [:], token: nil, time: 1, nonce: "n", id: "1")
        #expect(token["params"] == [:])
    }

    @Test func everyRequestHasANewNonceAndAValidSignature() async throws {
        let fake = FakeImouCloud()
        fake.addCamera()
        let cloud = cloud(fake)
        _ = try await cloud.online("TEST000CAM1")
        _ = try await cloud.online("TEST000CAM1")
        let nonces = fake.calls.compactMap { $0.body["system"]?["nonce"]?.stringValue }
        #expect(nonces.count == 3 && Set(nonces).count == 3)
        #expect(fake.state.withLockedValue { $0.badSignatures } == 0)
        #expect(fake.calls.first?.url.absoluteString == "https://openapi-sg.easy4ip.com/openapi/accessToken")
    }

    @Test func theHostFollowsTheRegionTheAPIAddressAndCurrentDomain() async throws {
        #expect(ImouCloud.baseURL(region: .eu, apiURL: nil).absoluteString == "https://openapi-fk.easy4ip.com/openapi")
        #expect(ImouCloud.baseURL(region: .sg, apiURL: "openapi-or.easy4ip.com").absoluteString == "https://openapi-or.easy4ip.com/openapi")
        #expect(ImouCloud.baseURL(region: .sg, apiURL: "https://openapi.easy4ip.com/openapi/").absoluteString == "https://openapi.easy4ip.com/openapi")
        let fake = FakeImouCloud()
        fake.addCamera()
        fake.state.withLockedValue { $0.currentDomain = "https://openapi-fk.easy4ip.com:443" }
        let cloud = cloud(fake)
        _ = try await cloud.online("TEST000CAM1")
        #expect(fake.calls.last?.url.absoluteString == "https://openapi-fk.easy4ip.com:443/openapi/deviceOnline")
    }

    @Test func anExpiredTokenIsFetchedOnceForConcurrentCallsAndEachIsRetriedOnce() async throws {
        let fake = FakeImouCloud()
        fake.addCamera()
        let cloud = cloud(fake)
        _ = try await cloud.online("TEST000CAM1")
        #expect(fake.tokenFetches == 1)
        // The cloud forgets the token: every call answers TK1002 until a new one.
        fake.state.withLockedValue { $0.tokens += 100 }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await cloud.online("TEST000CAM1") } }
            try await group.waitForAll()
        }
        #expect(fake.calls("accessToken").count == 2)
        // Each call at most twice: those that started after the new token went once.
        #expect((1 + 5)...(1 + 5 * 2) ~= fake.calls("deviceOnline").count)
        // A second TK1002 is an error.
        fake.fail("deviceOnline", with: "TK1002", "TK1002")
        await #expect(throws: ImouError.self) { _ = try await cloud.online("TEST000CAM1") }
    }

    @Test func refusedKeysAndOtherErrorsAreTold() async throws {
        let fake = FakeImouCloud()
        let wrong = ImouCloud(appID: FakeImouCloud.appID, appSecret: "wrong", region: .sg, apiURL: nil, environment: .init(transport: fake), logger: testLogger)
        do {
            try await wrong.verify()
            Issue.record("expected a refusal")
        } catch let error as ImouError {
            #expect(error.isAuthRefused)
            #expect(error.description.contains("system clock"))
        }
        #expect(ImouError.api(code: "OP1008", message: "").isAuthRefused)
        #expect(ImouError.api(code: "DV1030", message: "").isDormant)
        #expect(ImouError.api(code: "FL1001", message: "x").description.contains("licences"))
    }

    @Test func pagingStopsOnAShortPage() async throws {
        let fake = FakeImouCloud()
        for index in 0..<12 { fake.addCamera(String(format: "CAM%04d", index)) }
        let devices = try await cloud(fake).listDevices()
        #expect(devices.count == 12)
        #expect(fake.calls("listDeviceDetailsByPage").map { $0.params["page"]?.intValue } == [1, 2])
        let ten = FakeImouCloud()
        for index in 0..<10 { ten.addCamera(String(format: "CAM%04d", index)) }
        _ = try await cloud(ten).listDevices()
        #expect(ten.calls("listDeviceDetailsByPage").count == 2)
    }

    @Test func theSpecsDeviceListGivesOneCameraWithItsFeatures() throws {
        let json = try JSONValue(string: """
            {"deviceId":"TEST000CAM1","deviceName":"Garden","deviceStatus":"1","brand":"Imou","deviceModel":"IPC-F42P","deviceVersion":"2.840.0000000.12.R",
             "channelNum":1,"multiFlag":false,"accessType":"PaaS","deviceAbility":"WLAN,AlarmMD,CloseCamera,Siren,WhiteLight,SCCode,Auth",
             "channelList":[{"channelId":"0","channelName":"Garden","channelStatus":"online","channelAbility":"AlarmMD,HeaderDetect"}]}
            """)
        let device = try #require(ImouDevice(json: json))
        #expect(device.isIPC && device.productID == nil)
        let channel = try #require(device.cameraChannels.first)
        #expect(channel.id == "0" && channel.localChannel == 1)
        let features = ImouFeatures(abilities: device.abilities(of: channel))
        #expect(features.privacy && features.siren && features.whiteLight && features.motionDetectSwitch)
        #expect(!features.battery && !features.doorbell)
        // A channel of a multi-channel device has its own abilities only; an integer channel id is a string.
        let nvr = try #require(ImouDevice(json: ["deviceId": "NVR1", "channelNum": 4, "deviceAbility": "Siren",
                                                 "channelList": [["channelId": 2, "channelAbility": "CloseCamera"]]]))
        #expect(!nvr.isIPC && nvr.channels.first?.id == "2" && nvr.channels.first?.name == "NVR1-3")
        #expect(nvr.abilities(of: nvr.channels[0]) == ["CloseCamera"])
        #expect(ImouDevice(json: ["deviceId": "PLUG", "productId": "abc"])?.productID == "abc")
        #expect(ImouDevice(json: ["deviceName": "no id"]) == nil)
    }

    @Test func statusesAndOnlineValuesReadLeniently() {
        #expect(ImouCloud.status("on") == true && ImouCloud.status("off") == false && ImouCloud.status(1) == true && ImouCloud.status("0") == false)
        #expect(ImouCloud.status(.bool(true)) == true && ImouCloud.status("maybe") == nil && ImouCloud.status(nil) == nil)
        #expect(ImouOnline("1") == .online && ImouOnline("4") == .sleeping && ImouOnline("3") == .upgrading && ImouOnline("9") == .offline && ImouOnline(nil) == .offline)
    }

    @Test func theDayCountStartsAgainAtMidnightUTC() {
        var usage = ImouUsage()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<3 { _ = usage.record(at: day) }
        #expect(usage.callsToday(at: day) == 3)
        #expect(usage.callsToday(at: day.addingTimeInterval(86_400)) == 0)
        _ = usage.record(at: day.addingTimeInterval(86_400))
        #expect(usage.callsToday(at: day.addingTimeInterval(86_400)) == 1)
    }

    // MARK: The camera

    @Test func theDigestAnswerIsTheSpecsVector() throws {
        var digest = DigestAuthentication(username: "admin", password: "L2A3B4C5")
        let accepted = digest.accept(challenge: #"Digest realm="Login to 8L0DF93PAZ55FD2",qop="auth",nonce="211955164",opaque="x""#)
        #expect(accepted)
        let answer = digest.authorization(method: "GET", uri: "/cgi-bin/eventManager.cgi?action=attach&codes=[VideoMotion]", cnonce: "0a4f113b")
        let header = try #require(answer)
        #expect(header.contains(#"response="d04e4f238fda0e2aabd2e5f3fa9b08b9""#))
        #expect(header.contains(#"uri="/cgi-bin/eventManager.cgi?action=attach&codes=[VideoMotion]""#))
        #expect(header.contains("nc=00000001"))
        #expect(md5("admin:Login to 8L0DF93PAZ55FD2:L2A3B4C5") == "a67c39a0a978effee2c8e065f74724a6")
        #expect(md5("GET:/cgi-bin/eventManager.cgi?action=attach&codes=[VideoMotion]") == "62ee70f0204ed207d44daabe5f69182f")
    }

    @Test func theEventStreamParsesAcrossChunksWithDataBlocks() {
        let stream = "--myboundary\r\nContent-Type: text/plain\r\nContent-Length:37\r\n\r\nCode=VideoMotion;action=Start;index=0\r\n"
            + "--myboundary\r\nContent-Type: text/plain\r\nContent-Length:9\r\n\r\nHeartbeat\r\n"
        var data = "Code=VideoMotion;action=Stop;index=5;data={\n  \"SmartMotionEnable\" : false\n}\n"
        data = "--myboundary\nContent-Type: text/plain\nContent-Length: \(data.utf8.count)\n\n\(data)"
        var parser = DahuaMultipartParser(contentType: "multipart/x-mixed-replace; boundary=myboundary")
        var parts: [String] = []
        // One byte at a time: every boundary falls inside a chunk.
        for byte in Array((stream + data).utf8) { parts += parser.feed([byte]) }
        #expect(parts.count == 3)
        let events = parts.compactMap(DahuaEvent.init(text:))
        #expect(events.count == 2)
        #expect(events[0] == DahuaEvent(code: "VideoMotion", action: .start, index: 0))
        #expect(events[1].action == .stop && events[1].index == 5 && events[1].data?["SmartMotionEnable"] == false)
        // A part without a length ends at the next boundary; an oversized one is skipped.
        var lengthless = DahuaMultipartParser(contentType: nil)
        let more = lengthless.feed(Array("--myboundary\r\n\r\nCode=AlarmLocal;action=Pulse;index=1\r\n--myboundary\r\nContent-Length: 999999\r\n\r\nxx".utf8))
        #expect(more.compactMap(DahuaEvent.init(text:)) == [DahuaEvent(code: "AlarmLocal", action: .pulse, index: 1)])
        // A boundary line that never ends is dropped once it passes the bound, and the stream goes on.
        var endless = DahuaMultipartParser(contentType: nil)
        #expect(endless.feed(Array("--myboundary".utf8) + Array(repeating: 0x41, count: 70 * 1024)).isEmpty)
        let after = endless.feed(Array("\n--myboundary\r\nContent-Length: 36\r\n\r\nCode=AlarmLocal;action=Pulse;index=2\r\n".utf8))
        #expect(after.compactMap(DahuaEvent.init(text:)) == [DahuaEvent(code: "AlarmLocal", action: .pulse, index: 2)])
    }

    @Test func theCameraReadsItsSerialAndRefusesAWrongCode() async throws {
        let camera = FakeCamera()
        let client = try #require(DahuaClient(host: "192.0.2.20", port: 80, username: "admin", password: "L2A3B4C5", transport: camera))
        #expect(try await client.serialNumber() == "TEST000CAM1")
        #expect(try await client.snapshot(channel: 1) == jpeg)
        // The challenge kept answers at once the second time.
        #expect(camera.targets.filter { $0.hasPrefix("/cgi-bin/snapshot.cgi") }.count == 1)
        let wrong = try #require(DahuaClient(host: "192.0.2.20", port: 80, username: "admin", password: "WRONG", transport: camera))
        await #expect(throws: DahuaError.wrongPassword) { try await wrong.serialNumber() }
        #expect(DahuaClient.serial("sn=8L0DF93PAZ55FD2\r\n") == "8L0DF93PAZ55FD2")
        #expect(DahuaClient.serial(realm: "Login to 8L0DF93PAZ55FD2") == "8L0DF93PAZ55FD2")
        #expect(DahuaClient.serial(realm: "Other") == nil)
    }

    @Test func theRTSPAddressEscapesTheCredentialsAndCountsChannelsFromOne() {
        #expect(dahuaRTSPURL(host: "192.0.2.20", port: 554, username: "admin", password: "L2A3B4C5", channel: 1, subStream: false)
            == "rtsp://admin:L2A3B4C5@192.0.2.20:554/cam/realmonitor?channel=1&subtype=0")
        #expect(dahuaRTSPURL(host: "cam.local", port: 10554, username: "a b", password: "p@ss:/", channel: 3, subStream: true)
            == "rtsp://a%20b:p%40ss%3A%2F@cam.local:10554/cam/realmonitor?channel=3&subtype=1")
        #expect(ImouPlugin.firmwareRevision("2.840.0000000.12.R") == "2.840.0")
        #expect(ImouPlugin.firmwareRevision(nil) == "1.0.0" && ImouPlugin.firmwareRevision("3") == "3.0.0")
    }

    @Test func theSharedCameraArgumentsReadRTSPOverTCP() {
        let options = RTSPCameraOptions(rtspOverTCP: true)
        #expect(RTSPCameraArguments.input(url: "rtsp://x/y", options: options).prefix(2) == ["-rtsp_transport", "tcp"])
        #expect(RTSPCameraArguments.input(url: "rtsps://x/y", options: RTSPCameraOptions()).first == "-analyzeduration")
        #expect(RTSPCameraArguments.frame(input: ["-i", "u"]) == ["-hide_banner", "-i", "u", "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "pipe:1"])
        #expect(RTSPCameraOptions(encoder: ["copy"]).copiesVideo && RTSPCameraOptions(encoder: []).encoder == RTSPCameraOptions.defaultEncoder)
    }
}
