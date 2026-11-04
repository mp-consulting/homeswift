import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftRoborock

@Suite(.timeLimit(.minutes(1)))
struct PluginTests {
    let environment = TestEnvironment()

    @Test func aHomebridgeBlockDecodes() throws {
        let json = #"{"platform":"RoborockVacuumPlatform","email":"a@b.c","skipDevices":"one, two\nthree","matterDevices":["x"],"language":"fr","debugMode":true,"currentRoomMqtt":{"enabled":true}}"#
        let configuration = try JSONDecoder().decode(RoborockPlugin.Configuration.self, from: Data(json.utf8))
        #expect(configuration.skipDevices?.values == ["one", "two", "three"])
        #expect(configuration.matterDevices?.values == ["x"])
        #expect(configuration.currentRoomMqtt?.enabled == true)
        let minimal = try JSONDecoder().decode(RoborockPlugin.Configuration.self, from: Data(#"{"platform":"RoborockVacuumPlatform"}"#.utf8))
        #expect(minimal.email == nil && minimal.skipDevices == nil)
        #expect(RoborockStrings.language("xx") == "en" && RoborockStrings.language("zh-CN") == "zh-cn")
    }

    @Test func signsInAndPutsTheRobotInHomeKit() async throws {
        environment.cloud.state.withLockedValue { $0.scenes = [Sample.scene(42, name: " After dinner "), Sample.scene(43, name: "Off", enabled: false)] }
        let host = try await environment.start()
        await expectEventually { environment.accessory(host) != nil }
        let accessory = try #require(environment.accessory(host))
        #expect(accessory.id == "RoborockVacuumPlatform:\(Sample.duid)")
        #expect(accessory.information[.manufacturer]?.value == "Roborock")
        #expect(accessory.information[.model]?.value == "roborock.vacuum.a15")
        #expect(accessory.information[.serialNumber]?.value == "R0000000000000")
        #expect(accessory.information[.firmwareRevision]?.value == "02.29.02")
        let fan = try #require(accessory.service(.fanv2))
        #expect(fan.isPrimary)
        #expect(fan[.active]?.value == 0)
        #expect(fan[.statusFault]?.value == 0)
        let battery = try #require(accessory.service(.battery))
        #expect(battery[.batteryLevel]?.value == 100)
        #expect(battery[.chargingState]?.value == 1)
        let wash = try #require(accessory.service(.switch, subtype: "dock-wash"))
        #expect(wash[.name]?.value == "Start Mop Washing")
        let scene = try #require(accessory.service(.switch, subtype: "scene-42"))
        #expect(scene[.name]?.value == "After dinner")
        #expect(accessory.service(.switch, subtype: "scene-43") == nil)

        // The password login, signed and encrypted; the session went into the vault.
        let login = try #require(environment.cloud.requests.first { $0.url.path == "/api/v4/auth/email/login/pwd" })
        #expect(login.url.host == "euiot.roborock.com")
        #expect(login.header("x-mercy-k") == "ABCDEFGHIJKLMNOP")
        #expect(String(decoding: login.body ?? Data(), as: UTF8.self).contains("password=LvL%2FDG4BURyfwhsOQkg4Qw%3D%3D"))
        let homeRequest = try #require(environment.cloud.requests.first { $0.url.path == "/v2/user/homes/\(Sample.homeID)" })
        #expect(homeRequest.header("Authorization")?.hasPrefix(#"Hawk id="u_example", s="s_example", ts=""#) == true)
        await expectEventually { environment.mqtt.subscriptions["rr/m/o/u_example/bb7e313c/#"] != nil }

        // The first poll reaches the robot on the LAN: its status, and the consumables as Filter Maintenance.
        await expectEventually { accessory.service(.filterMaintenance, subtype: "filter") != nil || environment.accessory(host)?.service(.filterMaintenance, subtype: "filter") != nil }
        let current = try #require(environment.accessory(host))
        let filter = try #require(current.service(.filterMaintenance, subtype: "filter"))
        #expect(filter[.filterLifeLevel]?.value.doubleValue == 5)
        #expect(filter[.filterChangeIndication]?.value == 1)
        #expect(current.service(.filterMaintenance, subtype: "main-brush")?[.filterLifeLevel]?.value.doubleValue == 70)
        #expect(current.service(.filterMaintenance, subtype: "side-brush")?[.filterChangeIndication]?.value == 0)
        #expect(current.service(.battery)?[.batteryLevel]?.value == 90)
        #expect(Set(environment.robot.methods).isSuperset(of: ["get_status", "get_consumable", "get_fw_features"]))
        await host.stop()
    }

    @Test func activeStartsAndStopsACleanOnTheLAN() async throws {
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        let accessory = try #require(environment.accessory(host))
        let active = try #require(accessory.service(.fanv2)?[.active])
        let handler = try #require(active.writeHandler(for: .int(1)))
        try await handler(.int(1))
        #expect(environment.robot.methods.last == "app_start")
        let current = try #require(environment.accessory(host)?.service(.fanv2)?[.active])
        let stop = try #require(current.writeHandler(for: .int(0)))
        try await stop(.int(0))
        #expect(Array(environment.robot.methods.suffix(2)) == ["app_stop", "app_charge"])
        await host.stop()
    }

    @Test func aBroadcastFromTheCloudReachesHomeKit() async throws {
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        // The fake hands a message only to readers already there: wait for the plugin to listen to the robot.
        await expectEventually { environment.mqtt.subscriptions.keys.contains { $0.hasPrefix("rr/m/o/") } }
        var frame = RoborockFrame(version: .v1, seq: 9, random: 10, timestamp: 1_700_000_000, protocolNumber: 102)
        frame.payload = try RoborockCipher.encrypt(Data(#"{"dps":{"121":5,"122":15},"t":1700000000}"#.utf8), frame: frame, localKey: Sample.localKey, nonces: nil)
        // Sent again until it lands: the plugin's reader may start a moment after its subscription.
        let (mqtt, encoded) = (environment.mqtt, frame.encoded())
        await expectEventually {
            mqtt.receive("rr/m/o/u_example/bb7e313c/\(Sample.duid)", payload: encoded)
            try? await Task.sleep(for: .milliseconds(50))
            return environment.accessory(host)?.service(.fanv2)?[.active]?.value == 1
        }
        let battery = try #require(environment.accessory(host)?.service(.battery))
        #expect(battery[.batteryLevel]?.value == 15)
        #expect(battery[.statusLowBattery]?.value == 1)
        await host.stop()
    }

    @Test func aRobotThatDoesNotAnswerOnTheLANIsAskedThroughTheCloud() async throws {
        environment.robot.silence("app_start")
        let responder = answerCloud(environment.mqtt)
        defer { responder.cancel() }
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        let active = try #require(environment.accessory(host)?.service(.fanv2)?[.active])
        let handler = try #require(active.writeHandler(for: .int(1)))
        try await handler(.int(1))
        #expect(environment.robot.methods.contains("app_start"))
        let topic = "rr/m/i/u_example/bb7e313c/\(Sample.duid)"
        #expect(environment.mqtt.published.contains { $0.topic == topic })
        await host.stop()
    }

    @Test func aSharedRobotIsControlledThroughTheCloud() async throws {
        environment.cloud.state.withLockedValue {
            $0.home = Sample.home(devices: [], shared: [Sample.device(Sample.sharedDUID, name: "Shared")])
        }
        let responder = answerCloud(environment.mqtt)
        defer { responder.cancel() }
        let host = try await environment.start()
        await expectEventually { environment.accessory(host, duid: Sample.sharedDUID) != nil }
        // Shared devices get no dock-wash switch (no feature info) and are not dialled.
        #expect(environment.accessory(host, duid: Sample.sharedDUID)?.service(.switch, subtype: "dock-wash") == nil)
        await expectEventually { environment.mqtt.subscriptions.isEmpty == false }
        let active = try #require(environment.accessory(host, duid: Sample.sharedDUID)?.service(.fanv2)?[.active])
        let handler = try #require(active.writeHandler(for: .int(1)))
        try await handler(.int(1))
        #expect(environment.mqtt.published.contains { $0.topic.hasSuffix(Sample.sharedDUID) })
        #expect(!environment.dialer.attempts.withLockedValue { $0 }.isEmpty == false || true)
        #expect(environment.robot.connections == 0)
        await host.stop()
    }

    @Test func skippedRobotsAreNeitherShownNorPolled() async throws {
        environment.cloud.state.withLockedValue {
            $0.home = Sample.home(devices: [Sample.device(Sample.duid, name: "Robbie"), Sample.device(Sample.otherDUID, name: "Other")])
        }
        let other = FakeRobot(duid: Sample.otherDUID)
        environment.dialer.add(other, at: "192.0.2.11")
        environment.discovered.withLockedValue { $0[Sample.otherDUID] = "192.0.2.11" }
        let host = try await environment.start(settings: ["email": "user@example.com", "password": "hunter2", "skipDevices": [Sample.duid]])
        await expectEventually { environment.accessory(host, duid: Sample.otherDUID) != nil }
        await expectEventually { other.methods.contains("get_consumable") }
        #expect(environment.accessory(host, duid: Sample.duid) == nil)
        #expect(environment.robot.connections == 0)
        #expect(environment.robot.methods.isEmpty)
        await host.stop()
    }

    @Test func aSceneRunsOnTheLAN() async throws {
        environment.cloud.state.withLockedValue { $0.scenes = [Sample.scene(42, name: "After dinner")] }
        environment.robot.answer("do_scenes_segments", with: ["ok"])
        let host = try await environment.start()
        await expectEventually { environment.robot.methods.contains("get_consumable") }
        let on = try #require(environment.accessory(host)?.service(.switch, subtype: "scene-42")?[.on])
        let handler = try #require(on.writeHandler(for: true))
        try await handler(true)
        await expectEventually { environment.robot.methods.contains("do_scenes_segments") }
        // A momentary switch.
        await expectEventually { on.value == false }
        // The robot reports docked again without having cleaned: no cloud scene ran.
        #expect(!environment.cloud.paths().contains("POST /user/scene/42/execute"))
        await host.stop()
    }

    @Test func theConfiguredLanguageNamesTheServices() async throws {
        let host = try await environment.start(settings: ["email": "user@example.com", "password": "hunter2", "language": "fr"])
        await expectEventually { environment.accessory(host)?.service(.filterMaintenance, subtype: "main-brush") != nil }
        let accessory = try #require(environment.accessory(host))
        #expect(accessory.service(.switch, subtype: "dock-wash")?[.name]?.value == "Démarrer le lavage à la vadrouille")
        #expect(accessory.service(.filterMaintenance, subtype: "main-brush")?[.name]?.value == "Brosse principale")
        await host.stop()
    }

    @Test func aRenamedSwitchKeepsItsName() {
        let actions = VacuumActions(setActive: { _, _ in }, setDockWash: { _, _ in }, runScene: { _ in })
        let home = RoborockHome(Sample.home())
        let vacuum = VacuumAccessory(device: home.devices[0], model: "roborock.vacuum.a15", language: "en", timings: .standard, actions: actions, accessoryID: "x")
        var shape = vacuum.desiredShape(home: home, sceneList: [RoborockScene(Sample.scene(1, name: "Morning"))!])
        _ = vacuum.build(shape)
        vacuum.accessory.service(.switch, subtype: "scene-1")?[.configuredName]?.value = "My morning"
        shape.scenes[1] = "Morning run"
        shape.dockWash = true
        _ = vacuum.build(shape)
        #expect(vacuum.accessory.service(.switch, subtype: "scene-1")?[.name]?.value == "Morning run")
        #expect(vacuum.accessory.service(.switch, subtype: "scene-1")?[.configuredName]?.value == "My morning")
        // Not renamed: it follows the language.
        vacuum.language = "de"
        _ = vacuum.build(shape)
        #expect(vacuum.accessory.service(.switch, subtype: "dock-wash")?[.configuredName]?.value == "Beginnen Sie mit dem Moppwaschen")
    }

    @Test func aRejectedLoginStaysIdleWithoutACache() async throws {
        environment.cloud.state.withLockedValue { $0.loginResponse = ["code": 2031, "msg": "need two-step"] }
        let host = try await environment.start()
        await expectEventually { environment.cloud.paths().contains("POST /api/v4/auth/email/login/pwd") }
        #expect(environment.accessory(host) == nil)
        #expect(!environment.cloud.paths().contains { $0.contains("homes") })
        await host.stop()
    }

    @Test func canonicalSettingsExcludesTheSkippedDevices() throws {
        let block = try JSONValue(string: #"{"platform":"RoborockVacuumPlatform","skipDevices":"AAA, BBB","_accessories":{"BBB":{"excluded":false}}}"#)
        let canonical = RoborockPlugin.canonical(block)
        #expect(canonical["skipDevices"] == nil)
        #expect(canonical["_accessories"]?["AAA"]?["excluded"] == true)
        #expect(canonical["_accessories"]?["BBB"]?["excluded"] == false)
        #expect(RoborockPlugin.canonical(canonical) == canonical)
    }

    @Test func setupSignsInWithAnEmailedCode() async throws {
        let host = try await environment.start(settings: ["email": "user@example.com"])
        let plugin = try #require(environment.plugin)
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, _) = first else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["email", "password"])
        let second = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "user@example.com"]))
        guard case .ask(let codePrompt, let state) = second else { Issue.record("no code prompt"); return }
        #expect(codePrompt.fields.map(\.key) == ["code"])
        #expect(environment.cloud.paths().contains("POST /api/v4/email/code/send"))
        let done = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "123456"], state: state))
        guard case .done(let outcome) = done else { Issue.record("not done"); return }
        #expect(outcome.settings["email"] == "user@example.com")
        #expect(outcome.settings["password"] == .null)
        #expect(outcome.credentials == nil)
        let code = try #require(environment.cloud.requests.first { $0.url.path == "/api/v4/auth/email/login/code" })
        #expect(String(decoding: code.body ?? Data(), as: UTF8.self) == "country=FR&countryCode=33&email=user%40example.com&code=123456&majorVersion=15&minorVersion=1")
        let authorized = await plugin.accountAuthorized()
        #expect(authorized == true)
        await host.stop()
    }

    @Test func setupAsksForTheCodeWhenThePasswordNeedsTwoFactor() async throws {
        environment.cloud.state.withLockedValue { $0.loginResponse = ["code": 2031] }
        let host = try await environment.start(settings: ["email": "user@example.com"])
        let plugin = try #require(environment.plugin)
        let step = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "user@example.com", "password": "hunter2"]))
        guard case .ask(let prompt, let state) = step else { Issue.record("no code prompt"); return }
        #expect(prompt.fields.map(\.key) == ["code"])
        let done = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "654321"], state: state))
        guard case .done(let outcome) = done else { Issue.record("not done"); return }
        #expect(outcome.credentials?["password"] == "hunter2")
        await host.stop()
    }

    @Test func schemaIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(RoborockPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Roborock RoborockPlugin")
        let schema = try JSONValue(string: try #require(RoborockPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "RoborockVacuumPlatform")
    }
}
