import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing
@testable import HomeswiftMCP

private let accept: JSONValue = ["action": "accept", "content": ["confirm": true]]

/// Automations: Steps in order with their waits, conditions, the modes, the triggers that watch a value (a change, a
/// value that stays, a threshold crossed), locks left out, the scenes' triggers moved over once, and the MCP tools.
@Suite(.timeLimit(.minutes(1)))
struct AutomationTests {
    /// An environment whose Automations' waits pass a hundred times faster.
    func environment() async throws -> MCPTestEnvironment {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        environment.catalog.home.automationTimeScale.withLockedValue { $0 = 0.01 }
        return environment
    }

    func lampWrites(_ environment: MCPTestEnvironment, _ key: String) -> [HAPValue] {
        environment.written.filter { $0.0 == key }.map(\.1)
    }

    @Test func aChangeRunsTheStepsInOrder() async throws {
        let environment = try await environment()
        let catalog = environment.catalog
        catalog.startHome(restarted: true)
        defer { Task { await catalog.stopHome(restarting: true); await environment.stop() } }
        _ = try catalog.saveAutomation(["name": "Bright, then dim", "triggers": [["type": "characteristic", "id": "Devices:lamp", "characteristic": "On", "operator": "eq", "value": true]],
            "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 100], ["type": "wait", "seconds": 5],
                      ["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 20]]])
        let lamp = try #require(catalog.find(id: "Devices:lamp"))
        _ = try await catalog.write(lamp, service: nil, characteristic: "On", value: true, allowSecurity: false)
        #expect(await eventually { lampWrites(environment, "lamp.brightness") == [.int(100), .int(20)] })
        #expect(await eventually { catalog.home.automations.value.automations.first?.lastRun?.ok == true })
        #expect(catalog.home.automations.value.automations.first?.lastRun?.steps?.count == 3)
    }

    @Test func conditionsHoldATriggersRunBackButNotOneByHand() async throws {
        let environment = try await environment()
        let saved = try environment.catalog.saveAutomation(["name": "Only when on", "triggers": [["type": "time", "at": "07:00"]],
            "conditions": [["type": "characteristic", "id": "Devices:lamp", "characteristic": "On", "operator": "eq", "value": true]],
            "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 10]]])
        defer { Task { await environment.stop() } }
        let savedID = try #require(saved["id"]?.stringValue)
        let automation = try #require(environment.catalog.savedAutomation(reference: savedID))
        #expect(environment.catalog.start(automation, trigger: "time") == nil)
        #expect(environment.catalog.home.automations.value.automations.first?.lastSkipped?.reason?.contains("On is false") == true)
        _ = try await environment.catalog.runAutomation("only when on")
        #expect(lampWrites(environment, "lamp.brightness") == [.int(10)])
    }

    @Test func locksAreLeftOutAndTheRunSaysSo() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        _ = try environment.catalog.saveAutomation(["name": "Leave", "triggers": [["type": "time", "at": "08:00"]], "steps": [
            ["type": "set", "id": "Devices:lock", "characteristic": "Lock Target State", "value": 1], ["type": "set", "id": "Devices:lamp", "characteristic": "On", "value": false],
        ]])
        let answer = try await environment.catalog.runAutomation("Leave")
        #expect(!environment.written.contains { $0.0 == "lock.target" })
        #expect(lampWrites(environment, "lamp.on") == [.bool(false)])
        #expect(answer["lastRun"]?["reason"]?.stringValue?.contains("lock, door or alarm") == true)
        #expect(answer["lastRun"]?["steps"]?[0]?["note"]?.stringValue?.contains("automations do not change them") == true)
    }

    @Test func restartStartsAgainAndSingleIgnoresANewTrigger() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let steps: JSONValue = [["type": "wait", "seconds": 60], ["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 30]]
        let singleID = try #require(catalog.saveAutomation(["name": "Single", "mode": "single", "triggers": [["type": "time", "at": "09:00"]], "steps": steps])["id"]?.stringValue)
        let single = try catalog.automation(singleID)
        let first = try #require(catalog.start(single, trigger: "time"))
        #expect(catalog.start(single, trigger: "time") == nil)
        #expect(catalog.home.automations.value.automations.first { $0.id == single.id }?.lastSkipped?.reason?.contains("single") == true)
        await first.value

        let restartID = try #require(catalog.saveAutomation(["name": "Restart", "triggers": [["type": "time", "at": "09:00"]], "steps": steps])["id"]?.stringValue)
        let restart = try catalog.automation(restartID)
        let cancelled = try #require(catalog.start(restart, trigger: "time"))
        let again = try #require(catalog.start(restart, trigger: "time"))
        await cancelled.value
        await again.value
        // One write for the single run, one for the restarted run: the first restart run was cancelled in its wait.
        #expect(lampWrites(environment, "lamp.brightness") == [.int(30), .int(30)])
    }

    @Test func aValueThatStaysRunsItAndOneThatChangesBackDoesNot() async throws {
        let environment = try await environment()
        let catalog = environment.catalog
        catalog.startHome(restarted: true)
        defer { Task { await catalog.stopHome(restarting: true); await environment.stop() } }
        _ = try catalog.saveAutomation(["name": "Left on", "triggers": [["type": "stays", "id": "Devices:lamp", "characteristic": "On", "operator": "eq", "value": true, "forSeconds": 100]],
            "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 1]]])
        let lamp = try #require(catalog.find(id: "Devices:lamp"))
        // On and back off within the time: nothing.
        _ = try await catalog.write(lamp, service: nil, characteristic: "On", value: true, allowSecurity: false)
        _ = try await catalog.write(lamp, service: nil, characteristic: "On", value: false, allowSecurity: false)
        try await Task.sleep(for: .seconds(2))
        #expect(lampWrites(environment, "lamp.brightness").isEmpty)
        // On for the whole time (a second, scaled): it runs.
        _ = try await catalog.write(lamp, service: nil, characteristic: "On", value: true, allowSecurity: false)
        #expect(await eventually { lampWrites(environment, "lamp.brightness") == [.int(1)] })
    }

    @Test func aThresholdFiresWhenItIsCrossed() async throws {
        let environment = try await environment()
        let catalog = environment.catalog
        catalog.startHome(restarted: true)
        defer { Task { await catalog.stopHome(restarting: true); await environment.stop() } }
        _ = try catalog.saveAutomation(["name": "Too bright", "triggers": [["type": "threshold", "id": "Devices:lamp", "characteristic": "Brightness", "direction": "above", "value": 50]],
            "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "On", "value": false]]])
        let lamp = try #require(catalog.find(id: "Devices:lamp"))
        // 40 at start; 45 stays below, 60 crosses.
        _ = try await catalog.write(lamp, service: nil, characteristic: "Brightness", value: 45, allowSecurity: false)
        _ = try await catalog.write(lamp, service: nil, characteristic: "Brightness", value: 60, allowSecurity: false)
        #expect(await eventually { lampWrites(environment, "lamp.on") == [.bool(false)] })
        #expect(AutomationRules.crosses(SceneTrigger(type: "threshold", value: 50, direction: "above"), previous: 60, next: 70) == false)
        #expect(AutomationRules.crosses(SceneTrigger(type: "threshold", value: 50, direction: "below"), previous: 60, next: 40) == true)
    }

    @Test func scenesTriggersMoveIntoAutomationsOnce() async throws {
        let environment = try MCPTestEnvironment()
        let catalog = environment.catalog
        try catalog.home.scenes.update { file in
            file.scenes = [Scene(id: "s1", name: "Evening", actions: [SceneAction(id: "Devices:lamp", characteristic: "On", value: true)],
                                 triggers: [SceneTrigger(type: "sun", event: .sunset, offsetMinutes: -15)], conditions: [], lastRun: nil, lastSkipped: nil),
                           Scene(id: "s2", name: "Plain", actions: [SceneAction(id: "Devices:lamp", characteristic: "On", value: false)], triggers: [], conditions: [], lastRun: nil, lastSkipped: nil)]
        }
        catalog.migrateSceneAutomations()
        catalog.migrateSceneAutomations()
        let automations = catalog.home.automations.value.automations
        #expect(automations.count == 1)
        #expect(automations.first?.name == "Evening")
        #expect(automations.first?.steps == [{ var step = AutomationStep(type: "scene"); step.scene = "s1"; return step }()])
        #expect(automations.first?.triggers.first?.event == .sunset)
        #expect(catalog.home.scenes.value.scenes.allSatisfy { $0.triggers.isEmpty && $0.conditions.isEmpty })
        // A scene takes no triggers of its own any more.
        #expect(throws: CatalogError.self) {
            try catalog.createScene(["name": "Timed", "actions": [["id": "Devices:lamp", "characteristic": "On", "value": true]], "triggers": [["type": "time", "at": "07:00"]]])
        }
    }

    @Test func refusesBadAutomations() throws {
        let environment = try MCPTestEnvironment()
        let catalog = environment.catalog
        let step: JSONValue = [["type": "set", "id": "Devices:lamp", "characteristic": "On", "value": true]]
        for triggers: JSONValue in [[["type": "time", "at": "25:00"]], [["type": "cron", "cron": "61 * * * *"]], [["type": "sun", "event": "sunset", "offsetMinutes": 900]],
                                     [["type": "stays", "id": "Devices:lamp", "characteristic": "On", "value": true]], [["type": "threshold", "id": "Devices:lamp", "characteristic": "Brightness", "direction": "up", "value": 1]], []] {
            #expect(throws: CatalogError.self) { try catalog.saveAutomation(["name": "Bad", "triggers": triggers, "steps": step]) }
        }
        #expect(throws: CatalogError.self) { try catalog.saveAutomation(["name": "No steps", "triggers": [["type": "time", "at": "07:00"]], "steps": []]) }
        #expect(throws: CatalogError.self) { try catalog.saveAutomation(["name": "Unknown tool", "triggers": [["type": "time", "at": "07:00"]], "steps": [["type": "tool", "tool": "Nobody_do"]]]) }
        do {
            _ = try catalog.saveAutomation(["name": "Home", "triggers": [["type": "presence", "person": "Alex"]], "steps": step])
            Issue.record("a presence trigger was taken")
        } catch let error as CatalogError {
            #expect(error.description.contains("Presence plugin"))
        }
    }

    @Test func theToolsListSaveRunAndDelete() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let saved = try await client.tool("save_automation", ["name": "Dim", "triggers": [["type": "time", "at": "22:00"]],
            "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 15]]])
        let id = try #require(saved["structuredContent"]?["id"]?.stringValue)
        // One that names the lock asks the person first.
        let withLock: JSONValue = ["name": "Night", "triggers": [["type": "characteristic", "id": "Devices:lock", "characteristic": "Lock Current State", "operator": "eq", "value": 1]],
            "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "On", "value": false]]]
        #expect(environment.server.tools.first { $0.name == "save_automation" }?.confirms(withLock) == true)
        #expect(environment.server.tools.first { $0.name == "save_automation" }?.confirms(["name": "Dim", "triggers": [["type": "time", "at": "22:00"]],
            "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "Brightness", "value": 15]]]) == false)
        #expect(try await client.tool("save_automation", withLock, answer: accept)["isError"] != true)

        let list = try await client.tool("list_automations")["structuredContent"]?["automations"]?.arrayValue ?? []
        #expect(list.compactMap { $0["name"]?.stringValue }.sorted() == ["Dim", "Night"])
        #expect(list.first { $0["name"] == "Night" }?["security"] == true)
        let run = try await client.tool("run_automation", ["automation": "dim"])
        #expect(run["structuredContent"]?["lastRun"]?["ok"] == true)
        #expect(lampWrites(environment, "lamp.brightness") == [.int(15)])
        #expect(try await client.tool("delete_automation", ["automation": .string(id)], answer: accept)["isError"] != true)
        #expect(environment.catalog.savedAutomation(reference: id) == nil)
    }

    @Test func aSwitchInTheHomeAppTurnsItOnAndOff() async throws {
        let environment = try await environment()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let porch: JSONValue = ["name": "Porch", "homeKit": true, "triggers": [["type": "sun", "event": "sunset"]],
                                "steps": [["type": "set", "id": "Devices:lamp", "characteristic": "On", "value": true]]]
        let id = try #require(catalog.saveAutomation(porch)["id"]?.stringValue)
        let accessory = try #require(environment.host.mainBridge.server.accessory(id: HomeswiftCatalog.sceneSwitchesID))
        #expect(accessory.name == "Homeswift Scenes")
        let service = accessory.services.first { $0.subtype == "automation:\(id)" }
        let on = try #require(service?.characteristic(.on))
        #expect(on.value == .bool(true))
        try await on.write(.bool(false))
        #expect(catalog.savedAutomation(reference: id)?.isEnabled == false)
    }
}
