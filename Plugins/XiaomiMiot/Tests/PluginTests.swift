import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftXiaomiMiot

/// The plugin on a host, against fake devices on a fake LAN, miot-spec.org from the fixtures and a fake Xiaomi cloud.
@Suite(.timeLimit(.minutes(1)))
struct PluginTests {
    let environment = TestEnvironment()
    static let token = "00112233445566778899aabbccddeeff"
    static let did = "123456789"

    func lamp(ip: String = "192.168.1.50") -> FakeMiioDevice {
        let device = FakeMiioDevice(ip: ip, did: 123_456_789, token: Self.token, model: "yeelink.light.colorc", spec: Fixture.spec("yeelink.light.colorc"))
        device["2.1"] = true
        device["2.2"] = 40
        device["2.3"] = 3333
        device["2.5"] = 2
        environment.network.add(device)
        return device
    }

    func block(_ entries: [[String: Any]]) -> [String: Any] { ["devices": entries] }

    func entry(ip: String = "192.168.1.50", did: String = did, model: String? = "yeelink.light.colorc", extra: [String: Any] = [:]) -> [String: Any] {
        var entry: [String: Any] = ["name": "Desk Lamp", "ip": ip, "token": Self.token, "deviceId": did]
        if let model { entry["model"] = model }
        return entry.merging(extra) { $1 }
    }

    /// Two quick writes, as a slider sends them.
    static func writeTogether(_ characteristic: Characteristic, _ first: HAPValue, _ second: HAPValue) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await characteristic.write(first) }
            group.addTask {
                try await Task.sleep(for: .milliseconds(2))
                try await characteristic.write(second)
            }
            try await group.waitForAll()
        }
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(XiaomiMiotPlugin.Configuration.self, from: Data(#"{"platform":"miot"}"#.utf8))
        #expect(configuration.devices.isEmpty)
        #expect(configuration.country == "cn")
        #expect(XiaomiMiotPlugin.platform == "miot")
    }

    /// A light: published with its spec, its values polled, a write reaching the device and a change on it reaching HomeKit.
    @Test func lightEndToEnd() async throws {
        let device = lamp()
        let host = try await environment.start(settings: block([entry()]))
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.brightness]?.value == .int(40) })
        let accessory = try #require(environment.accessory(host, did: Self.did))
        #expect(accessory.id == "miot:123456789")
        #expect(accessory.information[.name]?.value == .string("Desk Lamp"))
        #expect(accessory.information[.manufacturer]?.value == .string("Yeelight Technology"))
        #expect(accessory.information[.model]?.value == .string("yeelink.light.colorc"))
        #expect(await eventually { accessory.information[.firmwareRevision]?.value == .string("1.4.2_0010") })
        // Without the cloud's MAC, the device's own (miIO.info) is the serial number.
        #expect(await eventually { accessory.information[.serialNumber]?.value == .string("AABBCCDDEE01") })
        let light = try #require(accessory.service(.lightbulb))
        #expect(light[.on]?.value == .bool(true))
        // A write reaches the device, as one set_properties of one item.
        let on = try #require(light[.on])
        try await on.write(.bool(false))
        #expect(device["2.1"] == .bool(false))
        #expect(device.calls("set_properties").last?[0]?["siid"]?.intValue == 2)
        // Brightness: 0 writes the range's minimum, the last of quick writes only.
        let brightness = try #require(light[.brightness])
        try await Self.writeTogether(brightness, .int(10), .int(0))
        #expect(device["2.2"] == .number(1))
        #expect(device.calls("set_properties").filter { $0[0]?["piid"]?.intValue == 2 }.count == 1)
        // A change on the device reaches HomeKit.
        device["2.2"] = 75
        #expect(await eventually { light[.brightness]?.value == .int(75) })
        // Only what is polled is asked.
        let asked = Set(device.calls("get_properties").flatMap { $0.arrayValue ?? [] }.compactMap { $0["piid"]?.intValue })
        #expect(asked == [1, 2, 3, 4, 5])
        await host.stop()
    }

    /// Adaptive Lighting: kept by the light's own white, turned off by a white set elsewhere.
    @Test func adaptiveLighting() async throws {
        let device = lamp()
        let host = try await environment.start(settings: block([entry()]))
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.colorTemperature]?.value == .int(300) })
        let light = try #require(environment.accessory(host, did: Self.did)?.service(.lightbulb))
        let controller = try #require(light.adaptiveLighting)
        // Turned on in the Home app at 250 mireds: its write reaches the device in kelvin.
        try controller.activateForTesting(mireds: 250)
        #expect(controller.isAdaptiveLightingActive)
        #expect(await eventually { device["2.3"] == .number(4000) })
        // The device reports what the bridge wrote: still on.
        let polls = device.calls("get_properties").count
        #expect(await eventually { device.calls("get_properties").count > polls + 1 })
        #expect(controller.isAdaptiveLightingActive)
        // A white set in the Mi Home app: off.
        device["2.3"] = 2700
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        await host.stop()
    }

    /// A device that stops answering shows No Response after 4 polls, without a crash, and comes back.
    @Test func unreachableDevice() async throws {
        let device = lamp()
        let host = try await environment.start(settings: block([entry()]))
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.on]?.value == .bool(true) })
        let accessory = try #require(environment.accessory(host, did: Self.did))
        #expect(!accessory.isUnavailable)
        device.silent = true
        #expect(await eventually(timeout: .seconds(15)) { accessory.isUnavailable })
        // A write while unreachable fails.
        let on = try #require(accessory.service(.lightbulb)?[.on])
        await #expect(throws: (any Error).self) { try await on.write(.bool(false)) }
        device.silent = false
        #expect(await eventually(timeout: .seconds(15)) { !accessory.isUnavailable })
        await host.stop()
    }

    /// A device that never answered: no accessory yet, nothing thrown, and the plugin keeps trying.
    @Test func neverReachedDevice() async throws {
        let host = try await environment.start(settings: block([entry(model: nil)]))
        try await Task.sleep(for: .milliseconds(400))
        #expect(environment.accessory(host, did: Self.did) == nil)
        // It appears once the device answers.
        _ = lamp()
        #expect(await eventually(timeout: .seconds(10)) { environment.accessory(host, did: Self.did) != nil })
        await host.stop()
    }

    /// The legacy robot (8.3): get_status, consumables, app_start, app_stop then app_charge, find_me.
    @Test func legacyVacuum() async throws {
        let robot = FakeMiioDevice(ip: "192.168.1.52", did: 345_678_912, token: "0123456789abcdef0123456789abcdef", model: "rockrobo.vacuum.v1")
        robot.state.withLockedValue {
            $0.unknownMIoT = true
            $0.status = [["state": 8, "battery": 100, "charge_status": 1, "error_code": 0, "in_cleaning": 0]]
            $0.consumables = [["main_brush_work_time": 324_000, "side_brush_work_time": 360_000, "filter_work_time": 513_000]]
        }
        environment.network.add(robot)
        let host = try await environment.start(settings: block([[
            "name": "Robot", "ip": "192.168.1.52", "token": "0123456789abcdef0123456789abcdef", "deviceId": "345678912", "model": "rockrobo.vacuum.v1",
            "methodButtons": [["method": "find_me", "name": "Find robot"]],
        ]]))
        #expect(await eventually { environment.accessory(host, did: "345678912")?.service(.battery)?[.batteryLevel]?.value == .int(100) })
        let accessory = try #require(environment.accessory(host, did: "345678912"))
        let fan = try #require(accessory.service(.fanv2))
        #expect(fan.isPrimary && fan.standsFor == .cleaningRobot)
        #expect(fan[.active]?.value == .int(0))
        #expect(fan[.statusFault]?.value == .int(0))
        #expect(accessory.service(.battery)?[.chargingState]?.value == .int(1))
        #expect(await eventually { accessory.service(subtype: "filter")?[.filterLifeLevel]?.value == .double(5) })
        #expect(accessory.service(subtype: "main-brush")?[.filterLifeLevel]?.value == .double(70))
        #expect(accessory.service(subtype: "side-brush")?[.filterLifeLevel]?.value == .double(50))
        #expect(accessory.service(subtype: "filter")?[.filterChangeIndication]?.value == .int(1))
        try await #require(fan[.active]).write(.int(1))
        #expect(robot.calls.contains { $0.method == "app_start" })
        try await fan[.active]!.write(.int(0))
        #expect(await eventually { robot.calls.map(\.method).suffix(4).contains("app_charge") })
        let methods = robot.calls.map(\.method)
        #expect(methods.lastIndex(of: "app_stop")! < methods.lastIndex(of: "app_charge")!)
        await accessory.identify()
        #expect(await eventually { robot.calls.contains { $0.method == "find_me" } })
        #expect(accessory.service(subtype: "method-0") != nil)
        // No MIoT request after the model said it is a legacy robot.
        #expect(robot.calls("get_properties").isEmpty)
        await host.stop()
    }

    /// 8.1 rule 2: a robot whose `get_properties` answers `unknown_method` and whose `get_status` answers is legacy.
    @Test func legacyFallback() async throws {
        let robot = FakeMiioDevice(ip: "192.168.1.53", did: 4242, token: Self.token, model: "dreame.vacuum.p2009")
        robot.state.withLockedValue {
            $0.unknownMIoT = true
            $0.status = [["state": 5, "battery": 60, "charge_status": 0, "error_code": 0]]
        }
        environment.network.add(robot)
        let host = try await environment.start(settings: block([entry(ip: "192.168.1.53", did: "4242", model: "dreame.vacuum.p2009")]))
        #expect(await eventually { environment.accessory(host, did: "4242")?.service(subtype: "main-brush") != nil })
        #expect(await eventually { environment.accessory(host, did: "4242")?.service(.fanv2)?[.active]?.value == .int(1) })
        await host.stop()
    }

    /// The MIoT robot (8.2): on starts a sweep (action 2.1), off sends it to the dock (action 3.1).
    @Test func miotVacuum() async throws {
        let robot = FakeMiioDevice(ip: "192.168.1.54", did: 5150, token: Self.token, model: "dreame.vacuum.p2009", spec: Fixture.spec("dreame.vacuum.p2009"))
        robot["2.1"] = 6
        robot["3.1"] = 88
        robot["3.2"] = 1
        robot["9.2"] = 40
        environment.network.add(robot)
        let host = try await environment.start(settings: block([entry(ip: "192.168.1.54", did: "5150", model: "dreame.vacuum.p2009")]))
        #expect(await eventually { environment.accessory(host, did: "5150")?.service(.battery)?[.batteryLevel]?.value == .int(88) })
        let accessory = try #require(environment.accessory(host, did: "5150"))
        #expect(accessory.service(.battery)?[.chargingState]?.value == .int(1))
        #expect(accessory.service(subtype: "brush-cleaner-9")?[.filterLifeLevel]?.value == .double(40))
        let fan = try #require(accessory.service(.fanv2))
        try await fan[.active]!.write(.int(1))
        #expect(robot.calls("action").last?["siid"]?.intValue == 2 && robot.calls("action").last?["aiid"]?.intValue == 1)
        try await fan[.active]!.write(.int(0))
        #expect(robot.calls("action").last?["siid"]?.intValue == 3 && robot.calls("action").last?["aiid"]?.intValue == 1)
        #expect(robot.calls("action").last?["in"] == .array([]))
        // Reset a brush: its action.
        try await accessory.service(subtype: "brush-cleaner-9")![.resetFilterIndication]!.write(.int(1))
        #expect(robot.calls("action").last?["siid"]?.intValue == 9)
        // Identify: the vendor audio position.
        await accessory.identify()
        #expect(await eventually { robot.calls("action").last?["siid"]?.intValue == 7 })
        await host.stop()
    }

    /// A write-only property (a curtain's motor command) is sent each time; the target position is written as a range.
    @Test func curtainCommands() async throws {
        let curtain = FakeMiioDevice(ip: "192.168.1.55", did: 6060, token: Self.token, model: "lumi.curtain.hagl08", spec: Fixture.spec("lumi.curtain.hagl08"))
        curtain["2.3"] = 20
        curtain["2.7"] = 20
        environment.network.add(curtain)
        let host = try await environment.start(settings: block([entry(ip: "192.168.1.55", did: "6060", model: "lumi.curtain.hagl08", extra: ["motorControl": true])]))
        #expect(await eventually { environment.accessory(host, did: "6060")?.service(.windowCovering)?[.currentPosition]?.value == .int(20) })
        let accessory = try #require(environment.accessory(host, did: "6060"))
        let covering = try #require(accessory.service(.windowCovering))
        try await covering[.targetPosition]!.write(.int(75))
        #expect(curtain["2.7"] == .number(75))
        try await covering[.holdPosition]!.write(.bool(true))
        try await covering[.holdPosition]!.write(.bool(true))
        #expect(curtain.calls("set_properties").filter { $0[0]?["piid"]?.intValue == 2 }.count == 2)
        let open = try #require(accessory.service(subtype: "ctl-2-2-1"))
        try await open[.on]!.write(.bool(true))
        #expect(curtain.calls("set_properties").last?[0]?["value"] == .number(1))
        // A stateless switch turns itself off.
        #expect(await eventually { open[.on]?.value == .bool(false) })
        await host.stop()
    }

    // MARK: Setup

    /// A Xiaomi account behind a fake HTTP: QR code and password logins, the signed device list.
    final class FakeCloud: @unchecked Sendable {
        let polls = NIOLockedValueBox(0)
        let pendingPolls: Int
        let flag: Int
        let captcha: Bool
        let list: JSONValue
        let refuse: Bool
        /// The device list's HTTP status instead of an answer (a server error).
        let listStatus: Int?

        init(pendingPolls: Int = 1, flag: Int = 8, captcha: Bool = false, list: JSONValue = ["list": []], refuse: Bool = false, listStatus: Int? = nil) {
            self.refuse = refuse
            self.listStatus = listStatus
            self.pendingPolls = pendingPolls
            self.flag = flag
            self.captcha = captcha
            self.list = list
        }

        static let ssecurity = "AAECAwQFBgcICQoLDA0ODw=="

        func respond(_ request: HomeswiftNetwork.HTTPRequest) throws -> HomeswiftNetwork.HTTPResponse {
            let url = request.url.absoluteString
            func json(_ text: String, headers: [(name: String, value: String)] = []) -> HomeswiftNetwork.HTTPResponse {
                HomeswiftNetwork.HTTPResponse(status: 200, headers: headers, body: Data(("&&&START&&&" + text).utf8))
            }
            switch true {
            case url.hasPrefix("https://account.xiaomi.com/longPolling/loginUrl"):
                return json(#"{"qr":"https://account.xiaomi.com/qr.png?id=1","lp":"https://account.xiaomi.com/lp/1","loginUrl":"https://account.xiaomi.com/login/1","timeout":300,"code":0}"#)
            case url.hasPrefix("https://account.xiaomi.com/lp/1"):
                let count = polls.withLockedValue { $0 += 1; return $0 }
                if count <= pendingPolls { return json(#"{"code":700,"desc":"not scanned"}"#) }
                return json(#"{"userId":42,"ssecurity":"\#(Self.ssecurity)","cUserId":"cu","passToken":"pass-secret","location":"https://sts.api.io.mi.com/sts?ticket=1","code":0}"#)
            case url.hasPrefix("https://sts.api.io.mi.com/sts"):
                return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Set-Cookie", "serviceToken=service-secret; Path=/")])
            case url.hasPrefix("https://account.xiaomi.com/pass/serviceLoginAuth2/end"):
                return HomeswiftNetwork.HTTPResponse(status: 302, headers: [("Location", "https://sts.api.io.mi.com/sts?ticket=2"), ("extension-pragma", #"{"ssecurity":"\#(Self.ssecurity)","psecurity":"p"}"#)])
            case url.hasPrefix("https://account.xiaomi.com/pass/serviceLoginAuth2"):
                if captcha { return json(#"{"captchaUrl":"/pass/getCode?icodeType=login","code":87001}"#) }
                return json(#"{"code":0,"notificationUrl":"https://account.xiaomi.com/fe/service/identity/authStart?sid=xiaomiio&context=ctx123"}"#)
            case url.hasPrefix("https://account.xiaomi.com/pass/serviceLogin"):
                return json(#"{"_sign":"sign123","code":70016}"#)
            case url.hasPrefix("https://account.xiaomi.com/fe/service/identity/authStart"):
                return HomeswiftNetwork.HTTPResponse(status: 200, body: Data("<html></html>".utf8))
            case url.hasPrefix("https://account.xiaomi.com/identity/list"):
                return json(#"{"code":0,"flag":\#(flag)}"#, headers: [("Set-Cookie", "identity_session=idsession; Path=/"), ("Set-Cookie", "ick=ick1; Path=/")])
            case url.hasPrefix("https://account.xiaomi.com/identity/auth/sendEmailTicket"):
                return json(#"{"code":0}"#)
            case url.hasPrefix("https://account.xiaomi.com/identity/auth/verifyEmail"):
                let body = URLEncoding.fields(String(decoding: request.body ?? Data(), as: UTF8.self))
                if body["ticket"] != "735091" { return json(#"{"code":70014,"tips":"wrong code"}"#) }
                return json(#"{"code":0,"location":"https://account.xiaomi.com/identity/result/check?sid=xiaomiio&context=ctx123"}"#)
            case url.hasPrefix("https://account.xiaomi.com/identity/result/check"):
                return HomeswiftNetwork.HTTPResponse(status: 302, headers: [("Location", "https://account.xiaomi.com/pass/serviceLoginAuth2/end?x=1"), ("Set-Cookie", "userId=42; Path=/")])
            case url.hasPrefix("https://de.api.io.mi.com/app/home/device_list"), url.hasPrefix("https://api.io.mi.com/app/home/device_list"):
                if refuse { return HomeswiftNetwork.HTTPResponse(status: 401) }
                if let listStatus { return HomeswiftNetwork.HTTPResponse(status: listStatus) }
                let fields = URLEncoding.fields(String(decoding: request.body ?? Data(), as: UTF8.self))
                guard let nonce = fields["_nonce"], let signed = MiCloudSigning.signedNonce(ssecurity: fields["ssecurity"] ?? "", nonce: nonce) else {
                    return HomeswiftNetwork.HTTPResponse(status: 401)
                }
                let answer: JSONValue = ["code": 0, "message": "ok", "result": list]
                return HomeswiftNetwork.HTTPResponse(status: 200, body: Data((MiCloudSigning.encrypt(answer.text(), signedNonce: signed) ?? "").utf8))
            default:
                return HomeswiftNetwork.HTTPResponse(status: 404)
            }
        }
    }

    func useCloud(_ cloud: FakeCloud) {
        environment.http.handler.withLockedValue { $0 = { try cloud.respond($0) } }
    }

    @Test func qrCodeSetup() async throws {
        let cloud = FakeCloud(pendingPolls: 1)
        useCloud(cloud)
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)
        guard case .ask(let first, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected the choice"); return }
        #expect(first.fields.map(\.key) == ["method", "country"])
        #expect(first.fields[0].options.map(\.value) == ["qr", "password"])
        #expect(first.fields[0].value == "qr")
        #expect(first.fields[1].options.count == 8)
        guard case .ask(let scan, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: ["method": "qr", "country": "de"])) else {
            Issue.record("expected the QR code"); return
        }
        #expect(scan.url == "https://account.xiaomi.com/qr.png?id=1")
        #expect(scan.message == "Open the QR code and scan it with the Mi Home app, then confirm on the phone.")
        #expect(scan.waitSeconds == 300 && scan.retryAfter == 2)
        #expect(state["method"] == "qr" && state["country"] == "de")
        // Not scanned yet: the same wait.
        guard case .ask(_, let pending) = try await plugin.authorize(SetupRequest(target: .account, state: state)) else { Issue.record("expected a wait"); return }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, state: pending)) else { Issue.record("expected done"); return }
        #expect(outcome.credentials?["session"]?["serviceToken"] == "service-secret")
        #expect(outcome.credentials?["session"]?["loginMethod"] == "qr")
        #expect(outcome.credentials?["session"]?["userId"] == "42")
        #expect(outcome.settings["micloud"]?["country"] == "de")
        #expect(await plugin.session()?.ssecurity == FakeCloud.ssecurity)
        // Time up: expired.
        environment.now.withLockedValue { $0 = $0.addingTimeInterval(400) }
        await #expect(throws: SetupError("The QR code expired. Start again to get a new one.")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, state: state))
        }
        await host.stop()
    }

    @Test func passwordSetupWithTwoFactor() async throws {
        useCloud(FakeCloud())
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        let chosen = SetupRequest(target: .account, answers: ["method": "password", "country": "cn"])
        guard case .ask(let credentials, let state) = try await plugin.authorize(chosen) else { Issue.record("expected the password"); return }
        #expect(credentials.fields.map(\.kind) == [.text, .secret])
        guard case .ask(let code, let codeState) = try await plugin.authorize(SetupRequest(target: .account, answers: ["username": "user@example.com", "password": "hunter2"], state: state)) else {
            Issue.record("expected the code"); return
        }
        #expect(code.message == "Enter the code Xiaomi sent to your email.")
        #expect(environment.http.count("https://account.xiaomi.com/identity/auth/sendEmailTicket") == 1)
        // The hash, never the password, goes to Xiaomi.
        let login = try #require(environment.http.requests.withLockedValue { $0.first { $0.url.absoluteString.hasSuffix("serviceLoginAuth2") } })
        let fields = URLEncoding.fields(String(decoding: login.body ?? Data(), as: UTF8.self))
        #expect(fields["hash"] == "2AB96390C7DBE3439DE74D0C9B0B1767" && fields["qs"] == "%3Fsid%3Dxiaomiio%26_json%3Dtrue" && fields["_sign"] == "sign123")
        await #expect(throws: SetupError("Xiaomi did not take that code. Check it and try again.")) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "000000"], state: codeState))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "735091"], state: codeState)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials?["username"] == "user@example.com")
        #expect(outcome.credentials?["password"] == "hunter2")
        #expect(outcome.credentials?["session"]?["loginMethod"] == "password_2fa")
        #expect(outcome.credentials?["session"]?["serviceToken"] == "service-secret")
        #expect(outcome.settings["micloud"]?["country"] == "cn")
        await host.stop()
    }

    @Test func passwordSetupRefusals() async throws {
        useCloud(FakeCloud(captcha: true))
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        let request = SetupRequest(target: .account, answers: ["method": "password", "country": "cn", "username": "u", "password": "p"])
        await #expect(throws: SetupError("Xiaomi asks for a captcha. Use the QR code instead.")) { _ = try await plugin.authorize(request) }
        useCloud(FakeCloud(flag: 4))
        await #expect(throws: SetupError("Xiaomi sends this account's code by text message, which Homeswift cannot ask for. Use the QR code instead.")) {
            _ = try await plugin.authorize(request)
        }
        await host.stop()
    }

    /// Discovery (3.5): the hello broadcast and the account's list merged by did, out-of-scope devices skipped; a device
    /// of the account comes with its token, another asks for one.
    @Test func discoveryAndDeviceSetup() async throws {
        let list: JSONValue = ["list": [
            ["did": "123456789", "token": .string(Self.token), "name": "Desk Lamp", "model": "yeelink.light.colorc", "localip": "192.168.1.50",
             "mac": "AA:BB:CC:DD:EE:01", "ssid": "Home", "isOnline": true, "extra": ["fw_version": "2.1.8_0042"]],
            ["did": "blt.3.1abc", "name": "BLE thing", "model": "xiaomi.sensor.x", "localip": "", "ssid": ""],
            ["did": "lumi.158d0001", "name": "Zigbee curtain", "model": "lumi.curtain.hagl08", "localip": "", "parent_id": "999"],
            ["did": "777", "token": "ffeeddccbbaa99887766554433221100", "name": "Old lamp", "model": "yeelink.light.color1", "localip": "192.168.1.70", "ssid": "Home"],
        ]]
        useCloud(FakeCloud(list: list))
        _ = lamp(ip: "192.168.1.50")
        let other = FakeMiioDevice(ip: "192.168.1.60", did: 555, token: "ffeeddccbbaa99887766554433221100", model: "zhimi.fan.za5", spec: Fixture.spec("zhimi.fan.za5"))
        environment.network.add(other)
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        await plugin.keep(MiSession(json: ["ssecurity": .string(FakeCloud.ssecurity), "userId": "42", "serviceToken": "service-secret"])!)
        #expect(await plugin.accountAuthorized() == true)
        let found = try await plugin.discover()
        #expect(found.map(\.deviceID).sorted() == ["123456789", "555"])
        let lampFound = try #require(found.first { $0.deviceID == "123456789" })
        #expect(lampFound.name == "Desk Lamp" && lampFound.authorization == .none && lampFound.kind == "light" && lampFound.address == "192.168.1.50")
        let fan = try #require(found.first { $0.deviceID == "555" })
        #expect(fan.authorization == .apiKey && fan.name == "Xiaomi device 555")
        // The account's device: its token, address and model.
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(lampFound))) else { Issue.record("expected done"); return }
        #expect(outcome.credentials?["token"] == .string(Self.token))
        #expect(outcome.settings["ip"] == "192.168.1.50" && outcome.settings["model"] == "yeelink.light.colorc")
        // Its MAC is kept as the serial number.
        #expect(await plugin.knownDevices.load()?["123456789"]?.serialNumber == "AABBCCDDEE01")
        // The other asks for its token, checked with a hello and miIO.info.
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .device(fan))) else { Issue.record("expected the token"); return }
        #expect(prompt.fields.first?.kind == .secret)
        await #expect(throws: SetupError("A token is 32 hexadecimal characters.")) {
            _ = try await plugin.authorize(SetupRequest(target: .device(fan), answers: ["token": "1234"]))
        }
        await #expect(throws: SetupError("That token does not open the device at 192.168.1.60.")) {
            _ = try await plugin.authorize(SetupRequest(target: .device(fan), answers: ["token": Self.token]))
        }
        guard case .done(let fanOutcome) = try await plugin.authorize(SetupRequest(target: .device(fan), answers: ["token": "FFEEDDCCBBAA99887766554433221100"])) else {
            Issue.record("expected done"); return
        }
        #expect(fanOutcome.credentials?["token"] == "ffeeddccbbaa99887766554433221100")
        #expect(fanOutcome.settings["model"] == "zhimi.fan.za5")
        await host.stop()
    }

    /// A session the account refuses (4.6): a QR session's refresh fails too, so the account Needs Authorization.
    @Test func refusedSession() async throws {
        useCloud(FakeCloud(refuse: true))
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        await plugin.keep(MiSession(json: ["ssecurity": .string(FakeCloud.ssecurity), "userId": "42", "serviceToken": "old", "passToken": "pass-secret"])!)
        #expect(plugin.context.accountRefusal == nil)
        #expect(try await plugin.discover().isEmpty)
        #expect(plugin.context.accountRefusal == "The Xiaomi session expired; sign in again.")
        await host.stop()
    }

    /// A cloud that fails (HTTP 503) is not a refused session: the account stays set up.
    @Test func serverErrorIsNotARefusal() async throws {
        useCloud(FakeCloud(listStatus: 503))
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        await plugin.keep(MiSession(json: ["ssecurity": .string(FakeCloud.ssecurity), "userId": "42", "serviceToken": "old"])!)
        #expect(try await plugin.discover().isEmpty)
        #expect(plugin.context.accountRefusal == nil)
        await host.stop()
    }

    /// A homebridge-miot block's account, without a session: the plugin signs in with its password (here Xiaomi asks for
    /// a code, so the account needs a person).
    @Test func blockPasswordSignsIn() async throws {
        useCloud(FakeCloud())
        let host = try await environment.start(settings: ["micloud": ["username": "user@example.com", "password": "secret-password", "country": "de"]])
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == true)
        #expect(try await plugin.discover().isEmpty)
        #expect(environment.http.count("https://account.xiaomi.com/pass/serviceLoginAuth2") == 1)
        #expect(plugin.context.accountRefusal == "Xiaomi asks for a code to sign in; sign in again.")
        await host.stop()
    }

    /// A write the device refuses fails, so HomeKit keeps the value the device has.
    @Test func refusedWriteFails() async throws {
        let device = lamp()
        let host = try await environment.start(settings: block([entry()]))
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.on]?.value == .bool(true) })
        let on = try #require(environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.on])
        device.state.withLockedValue { $0.writeCode = -4005 }
        await #expect(throws: (any Error).self) { try await on.write(.bool(false)) }
        #expect(on.value == .bool(true))
        #expect(device["2.1"] == .bool(true))
        await host.stop()
    }

    /// A device without deviceId keeps its accessory when it is off at the next start: its did was kept.
    @Test func learnedDIDOutlivesARestart() async throws {
        let device = lamp()
        let first = try await environment.start(settings: block([entry(did: "", extra: ["deviceId": NSNull()])]))
        #expect(await eventually { environment.accessory(first, did: Self.did) != nil })
        await first.stop()
        device.silent = true
        let second = try await environment.start(settings: block([entry(did: "", extra: ["deviceId": NSNull()])]))
        #expect(await eventually { environment.accessory(second, did: Self.did) != nil })
        #expect(await eventually(timeout: .seconds(10)) { environment.accessory(second, did: Self.did)?.isUnavailable == true })
        await second.stop()
    }

    /// Setup's probe of a running device's address leaves the running device its replies.
    @Test func probeLeavesTheRunningDevice() async throws {
        let device = lamp()
        let host = try await environment.start(settings: block([entry()]))
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.brightness]?.value == .int(40) })
        let plugin = try #require(environment.plugin)
        _ = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["ip": "192.168.1.50", "token": Self.token]))
        device["2.2"] = 80
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.brightness]?.value == .int(80) })
        await host.stop()
    }

    /// Add by address: the ip and the token; the hello's did is the Device Id.
    @Test func addByAddress() async throws {
        _ = lamp()
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(XiaomiMiotPlugin.newDevices == .byAddress)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("expected the address"); return }
        #expect(prompt.fields.map(\.key) == ["ip", "token"])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["ip": "192.168.1.50", "token": Self.token])) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.deviceID == Self.did)
        #expect(outcome.settings["ip"] == "192.168.1.50" && outcome.settings["model"] == "yeelink.light.colorc")
        #expect(outcome.credentials?["token"] == .string(Self.token))
        await #expect(throws: SetupError("No Xiaomi device answered at 192.168.1.99.")) {
            _ = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["ip": "192.168.1.99", "token": Self.token]))
        }
        await host.stop()
    }

    /// A device set up through Setup runs from its Accessory Settings and the token in the vault.
    @Test func setUpDeviceRunsFromTheVault() async throws {
        _ = lamp()
        let host = try await environment.start(settings: ["_accessories": [Self.did: ["ip": "192.168.1.50", "model": "yeelink.light.colorc"]]])
        let plugin = try #require(environment.plugin)
        try plugin.context.saveCredentials(["token": .string(Self.token)], for: Self.did)
        let configured = await plugin.configuredDevices()
        #expect(configured.map(\.did) == [Self.did])
        #expect(configured.first?.ip == "192.168.1.50")
        #expect(configured.first?.token.hex == Self.token)
        await host.stop()
    }

    // MARK: Settings

    /// 2.5: a homebridge-miot block's canonical shape, its tokens and password in the vault.
    @Test func canonicalSettingsOfTheExample() async throws {
        let example = try JSONValue(string: #"""
        {"platform":"miot","name":"Xiaomi","micloud":{"username":"user@example.com","password":"secret-password","country":"de"},"devices":[
          {"name":"Desk Lamp","ip":"192.168.1.50","token":"00112233445566778899aabbccddeeff","deviceId":"123456789","model":"yeelink.light.colorc","pollingInterval":10},
          {"name":"Bedroom Purifier","ip":"192.168.1.51","token":"ffeeddccbbaa99887766554433221100","deviceId":"234567891","ledControl":true,"fanLevelControl":true,
           "pm25Breakpoints":[10,20,35,60],"actionButtons":[{"action":"filter:reset-filter-life","name":"Reset filter"}],
           "propertyControl":[{"property":"2.5","value":1,"name":"Sleep mode"}],
           "propertyMonitor":[{"property":"environment:pm2.5-density","value":50,"valueOperator":"greater","name":"Dusty"}]},
          {"name":"Robot","ip":"192.168.1.52","token":"0123456789abcdef0123456789abcdef","deviceId":"345678912","model":"rockrobo.vacuum.v1",
           "methodButtons":[{"method":"find_me","name":"Find robot"}]}]}
        """#)
        let expected = try JSONValue(string: #"""
        {"platform":"miot","name":"Xiaomi","micloud":{"country":"de"},"_accessories":{
          "123456789":{"name":"Desk Lamp","ip":"192.168.1.50","model":"yeelink.light.colorc","pollingInterval":10},
          "234567891":{"name":"Bedroom Purifier","ip":"192.168.1.51","ledControl":true,"fanLevelControl":true,"pm25Breakpoints":[10,20,35,60],
            "actionButtons":[{"action":"filter:reset-filter-life","name":"Reset filter"}],"propertyControl":[{"property":"2.5","value":1,"name":"Sleep mode"}],
            "propertyMonitor":[{"property":"environment:pm2.5-density","value":50,"valueOperator":"greater","name":"Dusty"}]},
          "345678912":{"name":"Robot","ip":"192.168.1.52","model":"rockrobo.vacuum.v1","methodButtons":[{"method":"find_me","name":"Find robot"}]}}}
        """#)
        var settings = try #require(example.objectValue)
        settings.removeValue(forKey: "platform")
        settings.removeValue(forKey: "name")
        let host = try await environment.start(settings: settings.mapValues { try! JSONSerialization.jsonObject(with: $0.encoded(), options: .fragmentsAllowed) })
        let plugin = try #require(environment.plugin)
        let canonical = await host.canonicalSettings(platform: XiaomiMiotPlugin.platform, name: XiaomiMiotPlugin.name, block: example)
        #expect(canonical == expected)
        #expect(plugin.context.credentials(for: "123456789")?["token"] == .string(Self.token))
        #expect(plugin.context.credentials(for: "234567891")?["token"] == "ffeeddccbbaa99887766554433221100")
        #expect(plugin.context.credentials(for: "345678912")?["token"] == "0123456789abcdef0123456789abcdef")
        #expect(plugin.context.credentials()?["username"] == "user@example.com")
        #expect(plugin.context.credentials()?["password"] == "secret-password")
        // Written again, it changes nothing.
        #expect(XiaomiMiotPlugin.canonical(expected).block == expected)
        // An entry without its did stays until the plugin learned it.
        let unknown = try JSONValue(string: #"{"platform":"miot","devices":[{"ip":"192.168.1.9","token":"00112233445566778899aabbccddeeff"}]}"#)
        #expect(XiaomiMiotPlugin.canonical(unknown).block["devices"]?.arrayValue?.count == 1)
        let learned = XiaomiMiotPlugin.canonical(unknown, learnedDIDs: ["192.168.1.9": "99"]).block
        #expect(learned["devices"] == nil && learned["_accessories"]?["99"]?["ip"] == "192.168.1.9")
        await host.stop()
    }

    /// Flags that add a service are off by default (15.8); the child lock and the outlet's temperature stay on.
    @Test func defaults() {
        let options = DeviceOptions()
        #expect(!options.buzzerControl && !options.ledControl && !options.modeControl && !options.screenControl && !options.motorControl)
        #expect(options.childLockControl && options.showTemperature && options.deviceEnabled)
        #expect(DeviceOptions.interval(.number(10)) == 10)
        #expect(DeviceOptions.interval(.number(15000)) == 15)
        #expect(DeviceOptions.interval(.number(0.5)) == nil)
        #expect(DeviceOptions(["propertyChunkSize": 30]).propertyChunkSize == 14)
    }

    // MARK: Page and Assistant

    @Test func pageAndAssistantRoutes() async throws {
        let device = lamp()
        let host = try await environment.start(settings: block([entry()]))
        let plugin = try #require(environment.plugin)
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.on]?.value == .bool(true) })
        let list = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "devices", user: "admin"))
        #expect(list.json["devices"]?[0]?["deviceId"] == .string(Self.did))
        let properties = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "properties", query: ["did": Self.did], user: "admin"))
        #expect(properties.status == 200)
        let light = properties.json["services"]?.arrayValue?.first { $0["name"] == "light" }
        #expect(light?["properties"]?.arrayValue?.first { $0["id"] == "2.2" }?["value"] == .number(40))
        let set = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "set_property", body: ["did": .string(Self.did), "property": "light:brightness", "value": 55], user: "admin"))
        #expect(set.status == 200)
        #expect(device["2.2"] == .number(55))
        let missing = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "run_action", body: ["did": .string(Self.did), "action": "nothing:here"], user: "admin"))
        #expect(missing.status == 404)
        #expect(XiaomiMiotPlugin.assistantActions.map(\.name) == ["devices", "properties", "set_property", "run_action"])
        #expect(XiaomiMiotPlugin.assistantActions.filter(\.confirm).map(\.name) == ["set_property", "run_action"])
        await host.stop()
    }

    // MARK: Files and log

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(XiaomiMiotPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/XiaomiMiot XiaomiMiotPlugin")
        let schema = try JSONValue(string: try #require(XiaomiMiotPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "miot")
        #expect(schema["accessorySchema"]?["properties"]?["pollingInterval"]?["x-default"] == "pollingInterval")
        for key in XiaomiMiotPlugin.accessoryKeys { #expect(schema["accessorySchema"]?["properties"]?[key] != nil, "\(key) is not declared") }
    }

    @Test func pageFilesAreCurrent() throws {
        let web = Self.root.appendingPathComponent("Web")
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) {
            let file = try Data(contentsOf: web.appendingPathComponent(name))
            #expect(XiaomiMiotPlugin.webFiles[name]?.data == file, "run: swift Scripts/embed-assets.swift web Plugins/XiaomiMiot/Web Plugins/XiaomiMiot/Sources/WebFiles.swift XiaomiMiotPlugin")
        }
    }

    /// Tokens, passwords, sessions and codes never reach the log, at any level.
    @Test func nothingSecretInTheLog() async throws {
        let recorder = LogRecorder()
        let device = lamp()
        useCloud(FakeCloud(pendingPolls: 0))
        let host = try await environment.start(settings: block([entry()]), logger: recorder.logger, pluginLogger: recorder.logger)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { environment.accessory(host, did: Self.did)?.service(.lightbulb)?[.on]?.value == .bool(true) })
        try await environment.accessory(host, did: Self.did)!.service(.lightbulb)![.on]!.write(.bool(false))
        #expect(device["2.1"] == .bool(false))
        // A QR sign-in and a password sign-in with its code.
        guard case .ask(_, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: ["method": "qr", "country": "de"])) else {
            Issue.record("expected the QR code"); return
        }
        guard case .done = try await plugin.authorize(SetupRequest(target: .account, state: state)) else { Issue.record("expected done"); return }
        let request = SetupRequest(target: .account, answers: ["method": "password", "country": "cn", "username": "user@example.com", "password": "hunter2"])
        guard case .ask(_, let codeState) = try await plugin.authorize(request) else { Issue.record("expected the code"); return }
        guard case .done = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "735091"], state: codeState)) else {
            Issue.record("expected done"); return
        }
        _ = try await plugin.discover()
        _ = try? await plugin.authorize(SetupRequest(target: .newDevice, answers: ["ip": "192.168.1.50", "token": Self.token]))
        await host.stop()
        let secrets = [Self.token, Self.token.uppercased(), "hunter2", "2AB96390C7DBE3439DE74D0C9B0B1767", FakeCloud.ssecurity, "service-secret", "pass-secret",
                       "735091", "idsession", "ick1", "sign123", hexString(MiioToken(hex: Self.token)!.key), "https://account.xiaomi.com/lp/1",
                       "sts.api.io.mi.com/sts?ticket"]
        #expect(recorder.contains("Signed in to the Xiaomi account with the QR code"))
        #expect(recorder.contains("Signed in to the Xiaomi account with its password"))
        #expect(recorder.contains("Connected to Desk Lamp"))
        for secret in secrets { #expect(!recorder.contains(secret), "the log has \(secret)") }
    }
}
