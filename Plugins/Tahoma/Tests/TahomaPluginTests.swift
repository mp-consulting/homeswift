import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftTahoma

@Suite(.timeLimit(.minutes(1)))
struct TahomaPluginTests {
    @Test func theSetupBecomesAccessories() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(heater) != nil })
        let accessory = try #require(host.accessory(shutter))
        let covering = try #require(accessory.service(.windowCovering))
        #expect(covering.isPrimary)
        #expect(covering.characteristic(.currentPosition).value == 70)
        #expect(covering.characteristic(.targetPosition).value == 70)
        #expect(covering[.obstructionDetected] != nil)
        #expect(covering[TahomaCharacteristics.my] == nil)
        #expect(accessory.information.characteristic(.serialNumber).value == "io:7654321")
        #expect(accessory.information.characteristic(.manufacturer).value == "Somfy")
        #expect(accessory.information.characteristic(.model).value == "RollerShutter")

        let blind = try #require(host.accessory(kitchenBlind)?.service(.windowCovering))
        #expect(blind[TahomaCharacteristics.my] != nil)
        #expect(blind[.obstructionDetected] == nil)

        let thermostat = try #require(host.accessory(heater)?.service(.thermostat))
        #expect(thermostat.characteristic(.targetHeatingCoolingState).value == .int(HAP.heat))
        #expect(thermostat.characteristic(.currentHeatingCoolingState).value == .int(HAP.heat))
        #expect(thermostat[TahomaCharacteristics.prog]?.value == true)
        #expect(thermostat.characteristic(.targetTemperature).value.doubleValue == 20.5)
        #expect(abs((thermostat.characteristic(.currentTemperature).value.doubleValue ?? 0) - 20.5) < 0.01)
        #expect(thermostat.characteristic(.targetHeatingCoolingState).type.validValues == [HAP.off, HAP.heat, HAP.auto])
        #expect(host.accessory(heaterSensor) == nil)
        await host.stop()
    }

    @Test func aWriteBecomesTheSpecsExecution() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(shutter) != nil })
        let target = try #require(host.accessory(shutter)?.service(.windowCovering)?[.targetPosition])
        try await target.writeFromHomeKit(60)
        let apply = try #require(environment.server.applies.first)
        let expected = try JSONValue(string: #"""
        { "label": "Living room shutter - Close 40% - HomeKit",
          "actions": [ { "deviceURL": "io://1234-5678-9012/7654321", "commands": [ { "type": 1, "name": "setClosure", "parameters": [40] } ] } ],
          "metadata": null }
        """#)
        #expect(apply.body == expected)
        #expect(apply.path.hasSuffix("/exec/apply"))
        await host.stop()
    }

    @Test func slidersAndDevicesAreCoalesced() async throws {
        // At a tenth: 50 ms of quiet before a slider's command, 10 ms to gather devices.
        let environment = TestEnvironment(timeScale: 0.1)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(kitchenBlind) != nil })
        let shutterTarget = try #require(host.accessory(shutter)?.service(.windowCovering)?[.targetPosition])
        let blindTarget = try #require(host.accessory(kitchenBlind)?.service(.windowCovering)?[.targetPosition])
        // A drag: many writes, one command.
        await withTaskGroup(of: Void.self) { group in
            for value in [10, 20, 30, 40, 55] {
                group.addTask { try? await shutterTarget.writeFromHomeKit(.int(value)) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(environment.server.applies.count == 1)
        #expect(environment.server.applies.first?.body?["actions"]?[0]?["commands"]?[0]?["parameters"] == [45])
        // Two devices together: one execution.
        async let first: Void = shutterTarget.writeFromHomeKit(100)
        async let second: Void = blindTarget.writeFromHomeKit(100)
        _ = try await (first, second)
        let scene = try #require(environment.server.applies.last?.body)
        #expect(scene["label"] == "Execute scene (2 devices) - HomeKit")
        #expect(scene["actions"]?.arrayValue?.count == 2)
        #expect(environment.server.applies.count == 2)
        await host.stop()
    }

    @Test func pollingAsksOncePerCycle() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        // pollingPeriod 10 s at a hundredth: a fetch every 0.1 s.
        #expect(await eventually { environment.server.requests("/fetch").count >= 5 })
        #expect(environment.server.requests("/events/register").count == 1)
        #expect(environment.server.requests("/setup/devices", method: "GET").count == 1)
        #expect(environment.server.tokenRequests.count == 1)
        #expect(environment.server.requests("/login").isEmpty)
        let fetches = environment.server.requests("/fetch").count
        let others = environment.server.requests.count - fetches
        #expect(others == 4, "login, devices, location, register and nothing else: \(environment.server.requests.map(\.path))")
        await host.stop()
    }

    @Test func executionEventsReachHomeKit() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(shutter) != nil })
        let covering = try #require(host.accessory(shutter)?.service(.windowCovering))
        try await covering.characteristic(.targetPosition).writeFromHomeKit(60)
        let execID = "exec-1"
        environment.server.queue([["name": "ExecutionStateChangedEvent", "execId": .string(execID), "newState": "IN_PROGRESS", "timeToNextState": 0]])
        #expect(await eventually { covering.characteristic(.positionState).value == .int(HAP.decreasing) })
        environment.server.queue([
            ["name": "DeviceStateChangedEvent", "deviceURL": .string(shutter), "deviceStates": [["name": "core:ClosureState", "type": 1, "value": 40]]],
            ["name": "ExecutionStateChangedEvent", "execId": .string(execID), "newState": "COMPLETED", "timeToNextState": -1],
        ])
        #expect(await eventually { covering.characteristic(.positionState).value == .int(HAP.stopped) })
        #expect(covering.characteristic(.currentPosition).value == 60)
        #expect(covering.characteristic(.targetPosition).value == 60)
        #expect(covering.characteristic(.obstructionDetected).value == false)
        #expect(await environment.plugin?.executions.inFlight == 0)

        try await covering.characteristic(.targetPosition).writeFromHomeKit(20)
        environment.server.queue([[
            "name": "ExecutionStateChangedEvent", "execId": "exec-2", "newState": "FAILED", "timeToNextState": -1,
            "failureType": "WHILEEXEC_BLOCKED_BY_HAZARD", "failedCommands": [["deviceURL": .string(shutter), "command": ["name": "setClosure"]]],
        ]])
        #expect(await eventually { covering.characteristic(.obstructionDetected).value == true })
        #expect(covering.characteristic(.positionState).value == .int(HAP.stopped))
        await host.stop()
    }

    @Test func aStatelessTimedMoveStopsItself() async throws {
        let environment = TestEnvironment()
        var settings = TestEnvironment.account
        settings["devicesConfig"] = [["key": "Kitchen blind", "movementDuration": 20]]
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(kitchenBlind) != nil })
        let blind = try #require(host.accessory(kitchenBlind)?.service(.windowCovering))
        try await blind.characteristic(.targetPosition).writeFromHomeKit(100)
        #expect(environment.server.applies.last?.body?["actions"]?[0]?["commands"]?[0]?["name"] == "open")
        try await blind.characteristic(.targetPosition).writeFromHomeKit(0)
        #expect(environment.server.applies.last?.body?["actions"]?[0]?["commands"]?[0]?["name"] == "close")
        blind.characteristic(.currentPosition).value = 0
        try await blind.characteristic(.targetPosition).writeFromHomeKit(40)
        let move = try #require(environment.server.applies.last?.body)
        #expect(move["actions"]?[0]?["commands"]?[0]?["name"] == "open")
        environment.server.queue([
            ["name": "ExecutionStateChangedEvent", "execId": "exec-1", "newState": "COMPLETED", "timeToNextState": -1],
            ["name": "ExecutionStateChangedEvent", "execId": "exec-2", "newState": "COMPLETED", "timeToNextState": -1],
            ["name": "ExecutionStateChangedEvent", "execId": "exec-3", "newState": "IN_PROGRESS", "timeToNextState": 0],
            ["name": "ExecutionStateChangedEvent", "execId": "exec-3", "newState": "COMPLETED", "timeToNextState": -1],
        ])
        // 8000 ms at a hundredth, then `stop` alone (the move had ended).
        #expect(await eventually { environment.server.applies.last?.body?["actions"]?[0]?["commands"]?[0]?["name"] == "stop" })
        #expect(blind.characteristic(.currentPosition).value == 40)
        await host.stop()
    }

    @Test func venetianAlarmAndWaterHeaterCommands() async throws {
        let server = FakeOverkiz(devices: [
            FakeOverkiz.device(
                "io://1234-5678-9012/100", label: "Blind", uiClass: "ExteriorVenetianBlind", widget: "PositionableExteriorVenetianBlind",
                commands: ["setClosureAndOrientation", "setClosure", "setOrientation"],
                states: [("core:ClosureState", 1, 50), ("core:SlateOrientationState", 1, 30)]),
            FakeOverkiz.device(
                "internal://1234-5678-9012/alarm/0", label: "Alarm", uiClass: "Alarm", widget: "TSKAlarmController_unused", commands: ["alarmZoneOn"],
                states: [("core:ActiveZonesState", 3, "")]),
            FakeOverkiz.device(
                "io://1234-5678-9012/200", label: "Water", uiClass: "WaterHeatingSystem", widget: "DomesticHotWaterProduction",
                controllable: "io:AtlanticDomesticHotWaterProductionV2_SPLIT_IOComponent", commands: ["setCurrentOperatingMode", "setDHWMode"],
                states: [("core:OperatingModeState", 11, ["relaunch": "off", "absence": "off"]), ("io:DHWModeState", 3, "autoMode")]),
        ])
        let environment = TestEnvironment(server: server)
        let host = try await environment.start()
        #expect(await eventually { host.accessory("io://1234-5678-9012/200") != nil })

        let blind = try #require(host.accessory("io://1234-5678-9012/100")?.service(.windowCovering))
        #expect(blind.characteristic(.currentHorizontalTiltAngle).value == -36)
        try await blind.characteristic(.targetHorizontalTiltAngle).writeFromHomeKit(0)
        #expect(server.applies.last?.body?["actions"]?[0]?["commands"] == [["type": 1, "name": "setClosureAndOrientation", "parameters": [50, 50]]])
        try await blind.characteristic(.targetPosition).writeFromHomeKit(100)
        #expect(server.applies.last?.body?["actions"]?[0]?["commands"] == [["type": 1, "name": "setClosureAndOrientation", "parameters": [0, 50]]])

        let alarm = try #require(host.accessory("internal://1234-5678-9012/alarm/0")?.service(.securitySystem))
        #expect(alarm.characteristic(.securitySystemTargetState).isSecurityControl)
        try await alarm.characteristic(.securitySystemTargetState).writeFromHomeKit(.int(HAP.night))
        #expect(server.applies.last?.body?["actions"]?[0]?["commands"] == [["type": 1, "name": "alarmZoneOn", "parameters": ["B"]]])

        let water = try #require(host.accessory("io://1234-5678-9012/200")?.service(.thermostat))
        #expect(water.characteristic(.targetHeatingCoolingState).value == .int(HAP.auto))
        try await water.characteristic(.targetHeatingCoolingState).writeFromHomeKit(.int(HAP.off))
        #expect(server.applies.last?.body?["actions"]?[0]?["commands"] == [["type": 1, "name": "setCurrentOperatingMode", "parameters": [["relaunch": "off", "absence": "on"]]]])
        // An object state changes too.
        server.queue([["name": "DeviceStateChangedEvent", "deviceURL": "io://1234-5678-9012/200",
                       "deviceStates": [["name": "core:OperatingModeState", "type": 11, "value": ["relaunch": "off", "absence": "on"]]]]])
        #expect(await eventually { water.characteristic(.currentHeatingCoolingState).value == .int(HAP.off) })
        await host.stop()
    }

    @Test func exclusionsAndUnsupportedDevicesAreLeftOut() async throws {
        let server = FakeOverkiz(devices: .array((FakeOverkiz.setupExcerpt.arrayValue ?? []) + [
            FakeOverkiz.device("internal://1234-5678-9012/pod/0", label: "Box", uiClass: "Pod", widget: "Pod"),
            FakeOverkiz.device("io://1234-5678-9012/300", label: "Thing", uiClass: "SomethingNew", widget: "NewWidget"),
        ]))
        let environment = TestEnvironment(server: server)
        var settings = TestEnvironment.account
        settings["exclude"] = ["rts", "Bathroom heater"]
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(shutter) != nil })
        #expect(host.accessory(kitchenBlind) == nil)
        #expect(host.accessory(heater) == nil)
        #expect(host.accessory("internal://1234-5678-9012/pod/0") == nil)
        #expect(host.accessory("io://1234-5678-9012/300") == nil)
        await host.stop()
    }

    @Test func optionsMergeInTheirOrder() async throws {
        let environment = TestEnvironment()
        var settings = TestEnvironment.account
        settings["devicesConfig"] = [
            ["key": "Living room shutter", "defaultPosition": 30], ["key": "RollerShutter", "defaultPosition": 10, "reverse": true],
            ["key": "PositionableRollerShutter", "defaultPosition": 20], ["key": "3892b52a-cffc-5c6b-92ed-821149e1148c", "cycleDuration": 9],
        ]
        settings["_accessories"] = [shutter: ["defaultPosition": 40]]
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(shutter) != nil })
        let device = OverkizDevice.list(FakeOverkiz.setupExcerpt)[0]
        let options = try #require(await environment.plugin?.options(for: device))
        #expect(options.reverse)
        #expect(options.defaultPosition == 40)
        await host.stop()
    }

    @Test func aScenarioRunsAndTurnsOff() async throws {
        let server = FakeOverkiz()
        server.setScenarios([["oid": "s-1", "label": "Good night"], ["oid": "s-2", "label": "internal:x"], ["oid": "s-3", "label": ""]])
        let environment = TestEnvironment(server: server)
        var settings = TestEnvironment.account
        settings["exposeScenarios"] = true
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory("scene:s-1") != nil })
        #expect(host.accessory("scene:s-2") == nil)
        let power = try #require(host.accessory("scene:s-1")?.service(.switch)?[.on])
        try await power.writeFromHomeKit(true)
        #expect(server.requests("/exec/s-1", method: "POST").count == 1)
        server.queue([["name": "ExecutionStateChangedEvent", "execId": "scene-exec-1", "newState": "COMPLETED", "timeToNextState": -1]])
        #expect(await eventually { power.value == false })
        await host.stop()
    }

    @Test func anExecutionWithoutEventsTimesOut() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(shutter) != nil })
        let covering = try #require(host.accessory(shutter)?.service(.windowCovering))
        try await covering.characteristic(.targetPosition).writeFromHomeKit(50)
        #expect(await environment.plugin?.executions.inFlight == 1)
        // 2 minutes at a hundredth.
        #expect(await eventually { await environment.plugin?.executions.inFlight == 0 })
        await host.stop()
    }

    @Test func aFullQueueIsTriedAgain() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(shutter) != nil })
        await environment.plugin?.executions.setLanguage(nil)
        environment.server.failApplies([400])
        let covering = try #require(host.accessory(shutter)?.service(.windowCovering))
        try await covering.characteristic(.targetPosition).writeFromHomeKit(100)
        #expect(environment.server.applies.count == 2)
        await host.stop()
    }

    @Test func anUnconfiguredBlockCostsNothing() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [:])
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.server.requests.isEmpty)
        await host.stop()
    }

    @Test func aRefusedPasswordNeedsAuthorization() async throws {
        let environment = TestEnvironment()
        environment.server.setPassword("changed")
        let host = try await environment.start()
        #expect(await eventually { await environment.plugin?.context.accountRefusal != nil })
        #expect(environment.server.tokenRequests.count == 1)
        await host.stop()
    }

    @Test func theLocalAPIFindsTheGatewayByItsPIN() async throws {
        let environment = TestEnvironment(gateways: [
            GatewayAnnouncement(name: "gateway-9999-9999-9999", pin: "9999-9999-9999", address: "192.168.1.9"),
            GatewayAnnouncement(name: "TaHoma", pin: "1234-5678-9012", address: "192.168.1.50"),
        ])
        let host = try await environment.start(settings: ["service": "local", "user": "1234-5678-9012", "password": "0123456789abcdef0123"])
        #expect(await eventually { host.accessory(shutter) != nil })
        let version = try #require(environment.server.requests("/apiVersion").first)
        #expect(version.url.host == "192.168.1.50")
        #expect(version.url.port == 8443)
        #expect(environment.localPins.withLockedValue { $0 } == ["1234-5678-9012"])
        #expect(environment.server.requests("/login").isEmpty)
        #expect(environment.server.tokenRequests.isEmpty)
        #expect(environment.server.requests("/setup/location").isEmpty)
        await host.stop()
    }

    @Test func aSomfyAccountMovesToTheLocalAPI() async throws {
        let environment = TestEnvironment(gateways: [GatewayAnnouncement(name: "TaHoma", pin: "1234-5678-9012", address: "192.168.1.50")])
        var settings = TestEnvironment.account
        settings["preferLocalAPI"] = true
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(shutter) != nil })
        #expect(environment.server.mintedTokens.count == 1)
        // Over the OAuth session: Developer Mode turned on, a token generated, then activated with exactly three keys.
        #expect(environment.server.requests("/setup/gateways/1234-5678-9012/developerMode", method: "GET").first?.headers["authorization"]?.hasPrefix("Bearer ") == true)
        #expect(environment.server.developerMode)
        let activation = try #require(environment.server.requests("/config/1234-5678-9012/local/tokens", method: "POST").first)
        #expect(activation.body == ["label": "Homeswift", "token": "minted-token-1", "scope": "devmode"])
        #expect(activation.headers["cookie"] == nil)
        #expect(environment.server.requests("/setup/devices").first?.url.host == "192.168.1.50")
        await host.stop()

        // The next start uses the kept token.
        let again = try await environment.start(settings: settings)
        #expect(await eventually { environment.server.requests("/setup/devices").count >= 2 })
        #expect(environment.server.mintedTokens.count == 1)
        await again.stop()
    }

    @Test func aRefusedTokenIsRevokedAndOnlyThatOne() async throws {
        let environment = TestEnvironment(gateways: [GatewayAnnouncement(name: "TaHoma", pin: "1234-5678-9012", address: "192.168.1.50")])
        // Another bridge's token on the same gateway.
        environment.server.addActiveToken(label: "Homeswift")
        var settings = TestEnvironment.account
        settings["preferLocalAPI"] = true
        let host = try await environment.start(settings: settings)
        #expect(await eventually { host.accessory(shutter) != nil })
        #expect(environment.server.activeTokenLabels == ["Homeswift", "Homeswift"])
        await host.stop()

        environment.server.refuseLocalToken()
        let again = try await environment.start(settings: settings)
        #expect(await eventually { environment.server.activeTokenLabels.count == 1 })
        #expect(environment.server.mintedTokens.count == 1)
        await again.stop()
    }

    @Test func theRefreshTokenIsKeptBetweenRuns() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(shutter) != nil })
        await host.stop()
        environment.server.expireAccessTokens()
        let again = try await environment.start()
        // The accessories come back from the cache at once: wait for the sign-in itself.
        #expect(await eventually { environment.server.tokenRequests.count == 2 })
        #expect(environment.server.tokenRequests.map { $0.form["grant_type"] } == ["password", "refresh_token"])
        await again.stop()
    }

    @Test func setupChecksTheAccount() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, _) = first else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["service", "user", "password"])
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["service": "somfy_europe", "user": "user@example.com", "password": "wrong"]))
        }
        let done = try await plugin.authorize(SetupRequest(target: .account, answers: ["service": "somfy_europe", "user": "user@example.com", "password": "secret"]))
        guard case .done(let outcome) = done else { Issue.record("not done"); return }
        #expect(outcome.credentials?["password"] == "secret")
        #expect(outcome.settings["service"] == "somfy_europe")
        #expect(outcome.settings["password"] == .null)
        await host.stop()
    }

    @Test func discoverListsTheDevices() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        #expect(await eventually { host.accessory(heater) != nil })
        let found = try #require(try await environment.plugin?.discover())
        #expect(found.map(\.deviceID) == [shutter, kitchenBlind, heater])
        #expect(found.first?.kind == "cover")
        #expect(await environment.plugin?.deviceKind(of: heater) == "heating")
        await host.stop()
    }
}
