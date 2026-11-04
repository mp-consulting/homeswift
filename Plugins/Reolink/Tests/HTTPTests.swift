import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import HomeswiftReolink

/// The HTTP API (sections 3 and 4) against a fake device, and the fixtures of 9.4.
@Suite struct ReolinkHTTPTests {
    final class Clock: Sendable {
        let box = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000_000))
        var now: Date { box.withLockedValue { $0 } }
        func advance(_ seconds: TimeInterval) { box.withLockedValue { $0 += seconds } }
    }

    func client(_ device: FakeReolinkHTTP, clock: Clock = Clock(), password: String = "secret") -> ReolinkHTTPClient {
        ReolinkHTTPClient(host: "192.168.1.20", port: nil, useHttps: nil, username: "admin", password: password, makeSender: { _ in device },
                          trust: HTTPClient.TrustOnFirstUse(), log: testLogger, timing: ReolinkTiming(scale: 0.001), now: { clock.now })
    }

    @Test func loginBodyAndTokenReuse() async throws {
        let device = FakeReolinkHTTP(cameraAnswers())
        let http = client(device)
        _ = try await http.execute([ReolinkCommand(cmd: "GetDevInfo")])
        _ = try await http.execute([ReolinkCommand(cmd: "GetDevInfo")])
        #expect(device.logins == 1)
        let login = device.state.withLockedValue { $0.requests.first }
        #expect(login?.cmd == "Login")
        #expect(login?.body == [["cmd": "Login", "action": 0, "param": ["User": ["userName": "admin", "password": "secret"]]]])
    }

    @Test func renewsBeforeExpiryWithALogoutFirst() async throws {
        let device = FakeReolinkHTTP(cameraAnswers())
        let clock = Clock()
        let http = client(device, clock: clock)
        _ = try await http.execute([ReolinkCommand(cmd: "GetDevInfo")])
        clock.advance(3600 - 299)
        _ = try await http.execute([ReolinkCommand(cmd: "GetDevInfo")])
        #expect(device.logins == 2)
        #expect(device.state.withLockedValue { $0.logouts } == 1)
        let order = device.state.withLockedValue { $0.requests.map(\.cmd) }
        #expect(order == ["Login", "GetDevInfo", "Logout", "Login", "GetDevInfo"])
    }

    @Test func pleaseLoginFirstLogsInOnceAndRetries() async throws {
        let device = FakeReolinkHTTP(cameraAnswers())
        let http = client(device)
        _ = try await http.execute([ReolinkCommand(cmd: "GetDevInfo")])
        device.state.withLockedValue { $0.expireNext = true }
        let replies = try await http.execute([ReolinkCommand.channel("GetEvents", 0)])
        #expect(replies.first?.ok == true)
        #expect(device.logins == 2)
    }

    @Test func refusedCredentials() async {
        let device = FakeReolinkHTTP(cameraAnswers())
        let http = client(device, password: "wrong")
        await #expect(throws: ReolinkError.credentials("login failed")) { try await http.execute([ReolinkCommand(cmd: "GetDevInfo")]) }
        #expect(device.logins == 1)
    }

    @Test func frequentLoginsWaitAMinute() async {
        let device = FakeReolinkHTTP(cameraAnswers())
        device.state.withLockedValue { $0.loginReply = [["cmd": "Login", "code": 1, "error": ["rspCode": -105, "detail": "Frequent logins, please try again later!"]]] }
        let http = ReolinkHTTPClient(host: "h", port: nil, useHttps: nil, username: "admin", password: "secret", makeSender: { _ in device },
                                     trust: HTTPClient.TrustOnFirstUse(), log: testLogger, timing: ReolinkTiming(scale: 1))
        await #expect(throws: ReolinkError.frequentLogins) { try await http.execute([ReolinkCommand(cmd: "GetDevInfo")]) }
        await #expect(throws: ReolinkError.frequentLogins) { try await http.execute([ReolinkCommand(cmd: "GetDevInfo")]) }
        #expect(device.logins == 1)
    }

    @Test func fortyCommandsAreTwoPosts() async throws {
        let device = FakeReolinkHTTP(cameraAnswers())
        let http = client(device)
        let replies = try await http.execute((0..<40).map { ReolinkCommand.channel("GetEvents", $0 % 2) })
        #expect(replies.count == 40)
        let posts = device.state.withLockedValue { $0.requests.filter { $0.cmd == "GetEvents" }.map { $0.body?.arrayValue?.count ?? 0 } }
        #expect(posts == [35, 5])
    }

    @Test func oneRequestInFlight() async throws {
        let device = FakeReolinkHTTP(cameraAnswers())
        device.state.withLockedValue { $0.delay = .milliseconds(5) }
        let http = client(device)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try? await http.execute([ReolinkCommand(cmd: "GetDevInfo")]) } }
        }
        #expect(device.state.withLockedValue { $0.overlapped } == false)
        #expect(device.logins == 1)
    }

    @Test func aWholeBatchRefusedIsSentOneByOne() async throws {
        let device = FakeReolinkHTTP(cameraAnswers())
        device.state.withLockedValue { $0.batchErrorOnce = true }
        let http = client(device)
        let replies = try await http.execute([.channel("GetMdState", 0), .channel("GetIrLights", 0)])
        #expect(replies.map(\.ok) == [true, true])
        let sizes = device.state.withLockedValue { $0.requests.filter { $0.cmd == "GetMdState" || $0.cmd == "GetIrLights" }.map { $0.body?.arrayValue?.count ?? 0 } }
        #expect(sizes == [2, 1, 1])
    }

    @Test func snapshots() async throws {
        let device = FakeReolinkHTTP(cameraAnswers())
        let http = client(device)
        let image = try await http.snapshot(channel: 0, sub: true, width: 640, height: 360)
        #expect(String(decoding: image, as: UTF8.self) == "JPEG0sub")
    }

    @Test func httpsThenHTTP() async throws {
        // HTTPS on 443 refused: HTTP on 80.
        final class Picky: HTTPSending, @unchecked Sendable {
            let device = FakeReolinkHTTP(cameraAnswers())
            func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
                if request.url.scheme == "https" { throw HTTPClientError.cannotConnect(host: "h", port: 443, code: 61, reason: "refused") }
                return try await device.send(request)
            }
        }
        let picky = Picky()
        let http = ReolinkHTTPClient(host: "h", port: nil, useHttps: nil, username: "admin", password: "secret", makeSender: { _ in picky },
                                     trust: HTTPClient.TrustOnFirstUse(), log: testLogger, timing: ReolinkTiming(scale: 0.001))
        _ = try await http.execute([ReolinkCommand(cmd: "GetDevInfo")])
        #expect(await http.isHTTPS == false)
        #expect(await http.apiPort == 80)
    }

    // MARK: Fixtures (9.4)

    @Test func hostFixtures() throws {
        var info = ReolinkHostInfo()
        let devInfo = try JSONValue(string: """
            [{"cmd": "GetDevInfo", "code": 0, "value": {"DevInfo": {"model": "RLC-810A", "name": "Driveway", "serial": "00000000000001",
              "hardVer": "IPC_523128M8MP", "firmVer": "v3.1.0.2368_23062508", "exactType": "IPC", "type": "IPC", "channelNum": 1, "itemNo": ""}}}]
            """)
        info.apply(try #require(ReolinkReply(json: devInfo[0]!)))
        #expect(info.model == "RLC-810A")
        #expect(!info.isMultiChannel)
        #expect(ReolinkParse.firmware(info.firmware) == "3.1.0.2368")
        #expect(ReolinkParse.firmware("v3.0.0.59_20080734") == "3.0.0.59")

        var nvr = ReolinkHostInfo()
        nvr.type = "NVR"
        let status = try JSONValue(string: """
            [{"cmd": "GetChannelstatus", "code": 0, "value": {"count": 4, "status": [
              {"channel": 0, "name": "Garden", "online": 1, "typeInfo": "RLC-520A", "uid": "95270000AAAAAAAA"},
              {"channel": 1, "name": "Front Door", "online": 1, "typeInfo": "Reolink Video Doorbell PoE", "uid": "95270000BBBBBBBB"},
              {"channel": 2, "name": "", "online": 0, "typeInfo": ""},
              {"channel": 3, "name": "Shed", "online": 1, "typeInfo": "Argus 3 Pro", "uid": "95270000CCCCCCCC", "sleep": 1}]}}]
            """)
        nvr.apply(try #require(ReolinkReply(json: status[0]!)))
        #expect(nvr.onlineChannels.map(\.channel) == [0, 1, 3])
        #expect(nvr.onlineChannels[1].model?.contains("Doorbell") == true)
        #expect(nvr.onlineChannels[2].asleep)
        let channel = ReolinkChannel(channel: 1, name: "Front Door", model: "", firmware: "", hardware: "", uid: "95270000BBBBBBBB")
        nvr.uid = "HOSTUID"
        let hostID = try #require(nvr.hostID)
        #expect(ReolinkPlugin.deviceID(hostID: hostID, info: nvr, channel: channel) == "HOSTUID:95270000BBBBBBBB")
        let noUID = ReolinkChannel(channel: 2, name: "", model: "", firmware: "", hardware: "")
        #expect(ReolinkPlugin.deviceID(hostID: "HOSTUID", info: nvr, channel: noUID) == "HOSTUID:ch2")
        #expect(ReolinkPlugin.deviceID(hostID: "HOSTUID", info: info, channel: channel) == "HOSTUID")
    }

    @Test func duplicateChannelUIDsAreMadeUnique() throws {
        let value = try JSONValue(string: """
            {"status": [{"channel": 0, "online": 1, "uid": "SAME"}, {"channel": 1, "online": 1, "uid": "SAME"}]}
            """)
        #expect(ReolinkHostInfo.channelStatus(value).map(\.uid) == ["SAME_0", "SAME_1"])
    }

    @Test func eventsFixture() throws {
        let json = try JSONValue(string: """
            [{"cmd": "GetEvents", "code": 0, "value": {"channel": 1,
              "ai": {"people": {"alarm_state": 1, "support": 1}, "vehicle": {"alarm_state": 0, "support": 1},
                     "dog_cat": {"alarm_state": 0, "support": 0}, "other": {"alarm_state": 0, "support": 0}},
              "md": {"alarm_state": 1, "support": 1}, "visitor": {"alarm_state": 1, "support": 1}}}]
            """)
        let reply = try #require(ReolinkReply(json: json[0]!))
        let events = try #require(ReolinkParse.events(reply, channel: 1))
        #expect(events.motion == .init(true, true))
        #expect(events.ai["people"] == .init(true, true))
        #expect(events.ai["vehicle"] == .init(false, true))
        #expect(events.ai["dog_cat"]?.supported == false)
        #expect(events.visitor == .init(true, true))
        // Another channel's item is ignored.
        #expect(ReolinkParse.events(reply, channel: 0) == nil)
    }

    @Test func aiStateForms() throws {
        let new = try JSONValue(string: """
            [{"cmd": "GetAiState", "code": 0, "value": {"channel": 0, "dog_cat": {"alarm_state": 0, "support": 1},
              "face": {"alarm_state": 0, "support": 0}, "people": {"alarm_state": 1, "support": 1}, "vehicle": {"alarm_state": 0, "support": 1}}}]
            """)
        let newReply = try #require(ReolinkReply(json: new[0]!))
        let parsed = try #require(ReolinkParse.aiState(newReply, channel: 0))
        #expect(parsed["people"] == .init(true, true))
        #expect(parsed["face"]?.supported == false)
        let old = try JSONValue(string: #"[{"cmd": "GetAiState", "code": 0, "value": {"channel": 0, "people": 1, "vehicle": 0}}]"#)
        let oldReply = try #require(ReolinkReply(json: old[0]!))
        let oldParsed = try #require(ReolinkParse.aiState(oldReply, channel: 0))
        #expect(oldParsed["people"] == .init(true, true))
        #expect(oldParsed["vehicle"] == .init(false, true))
    }

    @Test func writes() throws {
        let ok = try #require(ReolinkReply(json: try JSONValue(string: #"{"cmd": "SetWhiteLed", "code": 0, "value": {"rspCode": 200}}"#)))
        let refused = try #require(ReolinkReply(json: try JSONValue(string: #"{"cmd": "SetWhiteLed", "code": 1, "error": {"rspCode": -9, "detail": "not support"}}"#)))
        #expect(ok.writeOK)
        #expect(!refused.writeOK)
        #expect(refused.rspCode == -9)
        let expired = try ReolinkHTTPClient.parse(Data(#"[ { "cmd" : "GetEvents", "code" : 1, "error" : { "detail" : "please login first", "rspCode" : -6 } } ]"#.utf8))
        #expect(expired.first?.isLoginRequired == true)
    }

    @Test func streamURLs() {
        #expect(ReolinkStreamURL.rtsp(host: "192.168.1.20", port: 554, username: "admin", password: "p@ss!", channel: 0, sub: false, codec: "h264", reported: nil, rtspVersion: 1)
            == "rtsp://admin:p%40ss%21@192.168.1.20:554/h264Preview_01_main")
        #expect(ReolinkStreamURL.rtmp(host: "192.168.1.20", port: 1935, username: "admin", password: "p@ss!", channel: 0, sub: true)
            == "rtmp://192.168.1.20:1935/bcs/channel0_sub.bcs?channel=0&stream=1&user=admin&password=p@ss!")
        #expect(ReolinkStreamURL.flv(https: true, host: "192.168.1.20", apiPort: 443, rtmpPort: 1935, username: "admin", password: "p@ss!", channel: 0, sub: false)
            == "https://192.168.1.20:443/flv?port=1935&app=bcs&stream=channel0_main.bcs&user=admin&password=p@ss!")
        #expect(ReolinkStreamURL.rtsp(host: "192.168.1.20", port: 554, username: "admin", password: "pw", channel: 0, sub: true, codec: "h264",
                                      reported: "rtsp://192.168.1.20:554/Preview_01_sub", rtspVersion: 3) == "rtsp://admin:pw@192.168.1.20:554/Preview_01_sub")
        let masked = ReolinkStreamURL.masked("rtmp://h:1935/bcs/c.bcs?channel=0&user=admin&password=p@ss! rtsp://admin:pw@h/x")
        #expect(!masked.contains("p@ss!"))
        #expect(!masked.contains(":pw@"))
    }
}

import NIOConcurrencyHelpers
