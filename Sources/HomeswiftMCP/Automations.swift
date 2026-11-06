import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import NIOConcurrencyHelpers

// Automations (GLOSSARY.md; docs/adr/0007-scenes-and-automations-are-separate.md): what the bridge does on its own, a
// Trigger, Conditions and Steps run in order, kept in automations.json next to config.json. A Scene is only a set of
// values; the triggers and conditions scenes.json had move here once, at start, one Automation per Scene with a single
// Step that applies it.
//
// Triggers: a time of day on chosen days, sunrise or sunset with an offset, cron, an accessory's value changing (or
// starting to compare with a value), a value that stays in a state for a while, a number crossing a threshold.
// `AutomationRules.triggerKinds` is where a kind is added: a Person arriving or leaving and Anyone Home come with the
// Presence plugin, as a `presence` trigger read from it.
//
// Steps: apply a Scene, set a value, wait, wait until a value, notify, call a plugin's action (one its plugin does not
// mark as needing confirmation). Locks, garage doors and alarms are never set: a Step on one, or the part of a Scene
// that changes one, is skipped and the last run says so, as a scene run by a trigger did.
//
// Modes: `restart` (a new trigger cancels the run under way and starts again), `single` (a new trigger is ignored while
// it runs). Every change a run makes is the Automation's in the Logbook (`ChangeSource.automation`).

public struct AutomationStep: Codable, Sendable, Equatable {
    /// `scene`, `set`, `wait`, `waitUntil`, `notify`, `tool`.
    public var type: String
    /// `scene`: the Scene's id.
    public var scene: String?
    /// `set` and `waitUntil`: the accessory, its service when it has several, the characteristic, and the value (with
    /// `operator` for `waitUntil`).
    public var id: String?
    public var service: String?
    public var characteristic: String?
    public var `operator`: String?
    public var value: JSONValue?
    /// `wait`: how long; `waitUntil`: how long at most.
    public var seconds: Double?
    /// `notify`: what it says.
    public var title: String?
    public var message: String?
    /// `tool`: a plugin's action (its MCP tool's name) and its arguments.
    public var tool: String?
    public var arguments: JSONValue?

    public init(type: String) { self.type = type }
}

public enum AutomationMode: String, Codable, Sendable {
    case restart, single
}

public struct AutomationStepResult: Codable, Sendable, Equatable {
    public var step: Int
    public var ok: Bool
    /// Left out: a lock, a garage door or an alarm, which automations never set.
    public var skipped: Bool?
    /// What it did or why not: skipped, timed out, an error.
    public var note: String?
}

public struct AutomationRunRecord: Codable, Sendable, Equatable {
    public var at: String
    public var ok: Bool
    /// What ran it: `time`, `sun`, `cron`, `characteristic`, `stays`, `threshold`, `manual`.
    public var trigger: String
    public var reason: String?
    public var steps: [AutomationStepResult]?
}

public struct Automation: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool?
    public var mode: AutomationMode?
    public var triggers: [SceneTrigger]
    public var conditions: [SceneCondition]
    public var steps: [AutomationStep]
    /// A switch on the Homeswift Scenes accessory turns it on or off (`SceneSwitches.swift`).
    public var homeKit: Bool?
    public var lastRun: AutomationRunRecord?
    public var lastSkipped: AutomationRunRecord?

    public var isEnabled: Bool { enabled != false }
    public var runMode: AutomationMode { mode ?? .restart }
}

public struct AutomationFile: Codable, Sendable, Equatable {
    public var version = 1
    public var automations: [Automation] = []

    public init() {}
}

/// A run under way: its task, so a restart cancels it, and which run it is.
struct AutomationRunning: Sendable {
    var run: UUID
    var task: Task<Void, Never>
}

enum AutomationRules {
    static let maxAutomations = 200
    static let maxSteps = 30
    static let triggerKinds: Set<String> = ["time", "sun", "cron", "characteristic", "stays", "threshold"]
    static let stepKinds: Set<String> = ["scene", "set", "wait", "waitUntil", "notify", "tool"]
    /// The longest wait, and the longest a value is watched for.
    static let longestWait: Double = 86_400

    static func trigger(_ value: JSONValue, index: Int) throws -> SceneTrigger {
        let label = "Trigger \(index + 1)"
        guard let object = value.objectValue, let type = object["type"]?.stringValue else { throw CatalogError("\(label) must be an object with a type") }
        switch type {
        case "stays":
            var trigger = try SceneRules.trigger(["type": "characteristic", "id": object["id"] ?? .null, "service": object["service"] ?? .null,
                                                  "characteristic": object["characteristic"] ?? .null, "operator": object["operator"] ?? "eq", "value": object["value"] ?? .null], index: index)
            guard trigger.operator != "changes" else { throw CatalogError("\(label): a value stays equal to, above or below something") }
            guard let seconds = object["forSeconds"]?.doubleValue, seconds >= 1, seconds <= longestWait, seconds == seconds.rounded() else {
                throw CatalogError("\(label): forSeconds is a whole number of seconds from 1 to 86400")
            }
            trigger.type = "stays"
            trigger.forSeconds = Int(seconds)
            trigger.enabled = object["enabled"]?.boolValue == false ? false : nil
            return trigger
        case "threshold":
            guard let direction = object["direction"]?.stringValue, ["above", "below"].contains(direction) else { throw CatalogError("\(label): direction is above or below") }
            guard let number = object["value"]?.doubleValue, number.isFinite else { throw CatalogError("\(label): the threshold is a number") }
            var trigger = try SceneRules.trigger(["type": "characteristic", "id": object["id"] ?? .null, "service": object["service"] ?? .null,
                                                  "characteristic": object["characteristic"] ?? .null, "operator": direction == "above" ? "gt" : "lt", "value": .number(number)], index: index)
            trigger.type = "threshold"
            trigger.direction = direction
            trigger.enabled = object["enabled"]?.boolValue == false ? false : nil
            return trigger
        case "presence":
            // The extension point for the Presence plugin: a Person arriving or leaving, Anyone Home changing.
            throw CatalogError("\(label): Person and Anyone Home triggers need the Presence plugin, which this homeswift does not have yet")
        default:
            return try SceneRules.trigger(value, index: index)
        }
    }

    static func step(_ value: JSONValue, index: Int, tools: [String: AssistantToolInfo]) throws -> AutomationStep {
        let label = "Step \(index + 1)"
        guard let object = value.objectValue, let type = object["type"]?.stringValue, stepKinds.contains(type) else {
            throw CatalogError("\(label): the type must be scene, set, wait, waitUntil, notify or tool")
        }
        var step = AutomationStep(type: type)
        switch type {
        case "scene":
            step.scene = try SceneRules.string(object, "scene", label, max: 512)
        case "set", "waitUntil":
            step.id = try SceneRules.string(object, "id", label)
            step.service = object["service"]?.stringValue?.nonEmpty
            step.characteristic = try SceneRules.string(object, "characteristic", label, max: 64)
            guard SceneRules.isValue(object["value"]) else { throw CatalogError("\(label): the value must be a boolean, a number or a short text") }
            step.value = object["value"]
            if type == "waitUntil" {
                let operation = object["operator"]?.stringValue ?? "eq"
                guard SceneRules.operators.contains(operation) else { throw CatalogError("\(label): invalid operator") }
                step.operator = operation
                step.seconds = try seconds(object["seconds"], label, default: 3600)
            }
        case "wait":
            step.seconds = try seconds(object["seconds"], label, default: nil)
        case "notify":
            let message = object["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !message.isEmpty, message.count <= 500 else { throw CatalogError("\(label): the message is 1 to 500 characters") }
            step.message = message
            step.title = object["title"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty.map { String($0.prefix(80)) }
        case "tool":
            let name = try SceneRules.string(object, "tool", label, max: 128)
            guard let tool = tools[name] else { throw CatalogError("\(label): no plugin action \(name) an automation may call (one that needs no confirmation)") }
            let arguments = object["arguments"] ?? [:]
            guard arguments.objectValue != nil else { throw CatalogError("\(label): arguments must be an object") }
            let errors = JSONSchema.validate(arguments, against: tool.inputSchema)
            guard errors.isEmpty else { throw CatalogError("\(label): \(errors.joined(separator: "; "))") }
            step.tool = name
            step.arguments = arguments
        default:
            break
        }
        return step
    }

    static func seconds(_ value: JSONValue?, _ label: String, default fallback: Double?) throws -> Double {
        guard let value, !value.isNull else {
            if let fallback { return fallback }
            throw CatalogError("\(label): seconds is missing")
        }
        guard let seconds = value.doubleValue, seconds >= 1, seconds <= longestWait else { throw CatalogError("\(label): seconds is from 1 to 86400") }
        return seconds.rounded()
    }

    /// An Automation's fields from a request body.
    static func automation(from body: JSONValue, id: String, existing: Automation?, tools: [String: AssistantToolInfo]) throws -> Automation {
        guard let object = body.objectValue else { throw CatalogError("Expected an automation") }
        let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name.count <= 64 else { throw CatalogError("The name must be 1 to 64 characters") }
        let triggers = try object["triggers"].map { value -> [SceneTrigger] in
            guard let list = value.arrayValue else { throw CatalogError("triggers must be a list") }
            return try list.enumerated().map { try trigger($1, index: $0) }
        } ?? existing?.triggers ?? []
        guard (1...SceneRules.maxTriggers).contains(triggers.count) else { throw CatalogError("An automation needs 1 to \(SceneRules.maxTriggers) triggers") }
        let conditions = try object["conditions"].map { value -> [SceneCondition] in
            guard let list = value.arrayValue, list.count <= SceneRules.maxConditions else { throw CatalogError("At most \(SceneRules.maxConditions) conditions") }
            return try list.enumerated().map { try SceneRules.condition($1, index: $0) }
        } ?? existing?.conditions ?? []
        let steps = try object["steps"].map { value -> [AutomationStep] in
            guard let list = value.arrayValue else { throw CatalogError("steps must be a list") }
            return try list.enumerated().map { try step($1, index: $0, tools: tools) }
        } ?? existing?.steps ?? []
        guard (1...maxSteps).contains(steps.count) else { throw CatalogError("An automation needs 1 to \(maxSteps) steps") }
        var mode = existing?.mode
        if let value = object["mode"] {
            guard let chosen = value.stringValue.flatMap(AutomationMode.init(rawValue:)) else { throw CatalogError("mode is restart or single") }
            mode = chosen == .restart ? nil : chosen
        }
        var enabled = existing?.enabled
        if let value = object["enabled"] {
            guard let on = value.boolValue else { throw CatalogError("enabled is true or false") }
            enabled = on ? nil : false
        }
        var homeKit = existing?.homeKit
        if let value = object["homeKit"] {
            guard value.isNull || value.boolValue != nil else { throw CatalogError("homeKit is true or false") }
            homeKit = value.boolValue == true ? true : nil
        }
        return Automation(id: id, name: name, enabled: enabled, mode: mode, triggers: triggers, conditions: conditions, steps: steps, homeKit: homeKit,
                          lastRun: existing?.lastRun, lastSkipped: existing?.lastSkipped)
    }

    /// Whether `value` crosses `trigger`'s threshold from `previous`: from at or below it to above it (`above`), or the
    /// other way.
    static func crosses(_ trigger: SceneTrigger, previous: JSONValue?, next: JSONValue) -> Bool {
        guard let threshold = SceneRules.number(trigger.value), let now = SceneRules.number(next) else { return false }
        let before = SceneRules.number(previous)
        if trigger.direction == "below" { return now < threshold && (before.map { $0 >= threshold } ?? true) }
        return now > threshold && (before.map { $0 <= threshold } ?? true)
    }
}

/// A plugin's action an Automation may call: its tool's name, the platform, and how to call it.
struct AssistantToolInfo: Sendable {
    var name: String
    var platform: String
    var pluginName: String
    var action: AssistantAction
    var inputSchema: JSONValue
}

extension HomeswiftCatalog {
    // MARK: Plugins' actions

    /// The plugin actions Automations may call: those that read or control, never one its plugin asks to confirm or
    /// that configures.
    var automationTools: [String: AssistantToolInfo] {
        var tools: [String: AssistantToolInfo] = [:]
        for entry in host.registry.entries {
            for action in entry.assistantActions where !action.confirm && action.access != .configure {
                let name = Self.actionToolName(platform: entry.platform, action: action.name)
                tools[name] = AssistantToolInfo(name: name, platform: entry.platform, pluginName: entry.name, action: action, inputSchema: Self.actionInputSchema(action, platform: entry.platform))
            }
        }
        return tools
    }

    /// The actions for the editor: each with its title, plugin, description and input schema, by plugin.
    public func automationToolsJSON() -> JSONValue {
        let running = Set(host.platforms.map(\.platform))
        return ["tools": .array(automationTools.values.filter { running.contains($0.platform) }.sorted { ($0.pluginName, $0.action.title) < ($1.pluginName, $1.action.title) }.map { tool in
            ["name": .string(tool.name), "title": .string(tool.action.title), "plugin": .string(tool.pluginName), "description": .string(tool.action.description), "inputSchema": tool.inputSchema]
        })]
    }

    // MARK: Reading

    /// The Automations, with what their steps and triggers name: accessories' and scenes' names, and whether they touch
    /// a lock, a garage door or an alarm.
    public func automationsJSON() -> JSONValue {
        let file = home.automations.value
        return withLookup {
            ["automations": .array(file.automations.map { automationJSON($0) }), "location": locationJSON()["location"] ?? .null,
             "running": .array(home.automationRuns.withLockedValue { Array($0.keys) }.sorted().map(JSONValue.string))]
        }
    }

    func automationJSON(_ automation: Automation) -> JSONValue {
        guard var object = (try? JSONValue(encoding: automation))?.objectValue else { return .null }
        object["mode"] = .string(automation.runMode.rawValue)
        object["enabled"] = .bool(automation.isEnabled)
        object["security"] = .bool(touchesSecurity(automation))
        object["running"] = .bool(home.automationRuns.withLockedValue { $0[automation.id] != nil })
        let scenes = home.scenes.value.scenes
        object["steps"] = .array(automation.steps.map { step in
            var entry = (try? JSONValue(encoding: step))?.objectValue ?? [:]
            if let id = step.scene { entry["name"] = scenes.first { $0.id == id }.map { .string($0.name) } ?? .null }
            if let id = step.id { entry["accessory"] = find(id: id).map { .string($0.layout?.name ?? $0.accessory.name) } ?? .null }
            return .object(entry)
        })
        return .object(object)
    }

    /// Whether a trigger, a condition or a Step names a lock, a garage door or an alarm, or applies a Scene that changes
    /// one: saving it over MCP asks the person first.
    func touchesSecurity(_ automation: Automation) -> Bool {
        let isSecurity = { (id: String?, service: String?, name: String?) -> Bool in
            guard let id, let name, let found = self.find(id: id) else { return false }
            if (try? self.characteristic(in: found, service: service, characteristic: name).isSecurityControl) == true { return true }
            return found.accessory.services.contains { $0.characteristics.contains(where: \.isSecurityControl) }
        }
        if automation.triggers.contains(where: { isSecurity($0.id, $0.service, $0.characteristic) }) { return true }
        if automation.conditions.contains(where: { isSecurity($0.id, $0.service, $0.characteristic) }) { return true }
        let scenes = home.scenes.value.scenes
        return automation.steps.contains { step in
            if let id = step.scene, let scene = scenes.first(where: { $0.id == id }) { return !securityActions(of: scene).isEmpty }
            return isSecurity(step.id, step.service, step.characteristic)
        }
    }

    public func savedAutomation(reference: String) -> Automation? {
        let all = home.automations.value.automations
        return all.first { $0.id == reference } ?? all.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
    }

    func automation(_ reference: String) throws -> Automation {
        guard let found = savedAutomation(reference: reference) else {
            let names = home.automations.value.automations.map(\.name)
            throw CatalogError("No automation \"\(reference)\". Automations: \(names.isEmpty ? "none" : names.joined(separator: ", ")).", notFound: true)
        }
        return found
    }

    // MARK: Changing

    /// Saves a new Automation (no `id` in the body, or one not saved) or changes one.
    public func saveAutomation(_ body: JSONValue, dryRun: Bool = false) throws -> JSONValue {
        let tools = automationTools
        let id = body["id"]?.stringValue?.nonEmpty
        let existing = id.flatMap { id in home.automations.value.automations.first { $0.id == id } }
        if let id, existing == nil { throw CatalogError("No automation \(id): leave id out to make a new one", notFound: true) }
        let automation = try AutomationRules.automation(from: body, id: existing?.id ?? SceneRules.newID(), existing: existing, tools: tools)
        if dryRun { return ["dryRun": true, "automation": automationJSON(automation)] }
        try home.automations.update { file in
            if let index = file.automations.firstIndex(where: { $0.id == automation.id }) {
                file.automations[index] = automation
            } else {
                guard file.automations.count < AutomationRules.maxAutomations else { throw CatalogError("At most \(AutomationRules.maxAutomations) automations") }
                file.automations.append(automation)
            }
        }
        automationsChanged(automation.id)
        return automationJSON(automation)
    }

    public func deleteAutomation(_ reference: String) throws -> JSONValue {
        let found = try automation(reference)
        try home.automations.update { $0.automations.removeAll { $0.id == found.id } }
        cancelAutomation(found.id)
        automationsChanged(found.id)
        return ["deleted": .string(found.id), "name": .string(found.name)]
    }

    /// Turns an Automation on or off, as its switch in the Home app does.
    public func setAutomationEnabled(_ id: String, _ on: Bool) throws {
        try home.automations.update { file in
            guard let index = file.automations.firstIndex(where: { $0.id == id }) else { throw CatalogError("No automation \(id)", notFound: true) }
            file.automations[index].enabled = on ? nil : false
        }
        if !on { cancelAutomation(id) }
        automationsChanged(id)
    }

    /// After a change to one Automation: the watched values, its stays timers (the others count on) and the switches follow.
    func automationsChanged(_ id: String) {
        seedWatchedValues()
        home.staysTimers.withLockedValue { timers in
            for (key, timer) in timers where key.hasPrefix("\(id)|") {
                timer.cancel()
                timers.removeValue(forKey: key)
            }
        }
        seedStaysTimers()
        syncSceneSwitches()
    }

    // MARK: Migration

    /// Each Scene of scenes.json with triggers or conditions becomes an Automation with its name and one Step that
    /// applies it, and keeps only its values. Its `homeKit` switch stays the Scene's. Once: a Scene without triggers
    /// has nothing more to move.
    public func migrateSceneAutomations() {
        let moving = home.scenes.value.scenes.filter { !$0.triggers.isEmpty || !$0.conditions.isEmpty }
        guard !moving.isEmpty else { return }
        do {
            try home.automations.update { file in
                for scene in moving where !file.automations.contains(where: { $0.steps.count == 1 && $0.steps[0].scene == scene.id && $0.name == scene.name }) {
                    var step = AutomationStep(type: "scene")
                    step.scene = scene.id
                    file.automations.append(Automation(id: SceneRules.newID(), name: scene.name, enabled: nil, mode: nil,
                                                       triggers: scene.triggers.isEmpty ? [] : scene.triggers, conditions: scene.conditions, steps: [step], homeKit: nil,
                                                       lastRun: nil, lastSkipped: nil))
                }
            }
            try home.scenes.update { file in
                for index in file.scenes.indices {
                    file.scenes[index].triggers = []
                    file.scenes[index].conditions = []
                }
            }
            logger.info("Moved the triggers and conditions of \(moving.count) scene(s) into automations of the same names")
        } catch {
            logger.warning("Could not move the scenes' triggers into automations: \(error)")
        }
    }

    // MARK: Running

    /// Runs an Automation now: by hand, its conditions are not checked (`manual`); by a trigger, they are.
    @discardableResult
    public func runAutomation(_ reference: String, trigger: String = "manual") async throws -> JSONValue {
        let found = try automation(reference)
        guard let task = start(found, trigger: trigger) else {
            return ["automation": .string(found.id), "started": false, "reason": .string(home.automations.value.automations.first { $0.id == found.id }?.lastSkipped?.reason ?? "not started")]
        }
        await task.value
        let record = home.automations.value.automations.first { $0.id == found.id }?.lastRun
        return ["automation": .string(found.id), "name": .string(found.name), "started": true, "lastRun": (try? JSONValue(encoding: record)) ?? .null]
    }

    /// Starts a run unless its conditions fail (a trigger's run), it is off (a trigger's run), or it already runs in
    /// `single` mode; a `restart` one cancels the run under way. Answers the run's task.
    @discardableResult
    func start(_ automation: Automation, trigger: String) -> Task<Void, Never>? {
        let manual = trigger == "manual"
        if !manual {
            guard automation.isEnabled else { return nil }
            if let reason = conditionsFail(automation.conditions) {
                logger.info("Automation \"\(automation.name)\" not run (\(trigger)): \(reason)")
                noteSkip(automation, trigger: trigger, reason: reason)
                return nil
            }
        }
        let run = UUID()
        let catalog = self
        let task = Task<Void, Never>.detached {
            await ChangeSource.automation(automation.name).run { await catalog.runSteps(of: automation, trigger: trigger, run: run) }
        }
        let started = home.automationRuns.withLockedValue { runs -> Bool in
            if let current = runs[automation.id] {
                guard automation.runMode == .restart else { return false }
                current.task.cancel()
            }
            runs[automation.id] = AutomationRunning(run: run, task: task)
            return true
        }
        guard started else {
            task.cancel()
            noteSkip(automation, trigger: trigger, reason: "already running (single mode)")
            return nil
        }
        logger.info("Running automation \"\(automation.name)\" (\(trigger))")
        return task
    }

    func cancelAutomation(_ id: String) {
        home.automationRuns.withLockedValue { $0.removeValue(forKey: id) }?.task.cancel()
    }

    /// How a Step's waits are counted: 1 is real time; tests make it shorter.
    var automationTimeScale: Double { home.automationTimeScale.withLockedValue { $0 } }

    private func runSteps(of automation: Automation, trigger: String, run: UUID) async {
        var results: [AutomationStepResult] = []
        // Cancelled by a restart: the run that replaced it records its own.
        defer {
            home.automationRuns.withLockedValue { runs in
                if runs[automation.id]?.run == run { runs.removeValue(forKey: automation.id) }
            }
        }
        for (index, step) in automation.steps.enumerated() {
            if Task.isCancelled { break }
            var result = AutomationStepResult(step: index + 1, ok: true)
            do {
                // Stamped again for each Step: a Step after a long wait is still the Automation's in the Logbook.
                let done = try await ChangeSource.automation(automation.name).run { try await perform(step, of: automation) }
                result.note = done.note
                result.skipped = done.skipped ? true : nil
            } catch is CancellationError {
                break
            } catch {
                result.ok = false
                result.note = Redaction.redactText("\(error)")
            }
            results.append(result)
        }
        if Task.isCancelled, home.automationRuns.withLockedValue({ $0[automation.id]?.run != run }) { return }
        let ok = results.allSatisfy(\.ok)
        let skipped = results.filter { $0.skipped == true }.count
        recordAutomation(automation.id) {
            $0.lastRun = AutomationRunRecord(at: SceneRules.now(), ok: ok, trigger: trigger, reason: skipped > 0 ? "\(skipped) step(s) on a lock, door or alarm not run" : nil, steps: results)
        }
        if !ok, trigger != "manual" {
            let failed = results.filter { !$0.ok }.map { "step \($0.step)" }.joined(separator: ", ")
            await notify(.sceneFailed, title: "Automation \(automation.name) failed", message: "\(failed) failed when the \(trigger) trigger ran it.", path: "/automations", subject: automation.id)
        }
    }

    /// Does one Step; answers what to note in the run (nil when there is nothing to say).
    private func perform(_ step: AutomationStep, of automation: Automation) async throws -> (note: String?, skipped: Bool) {
        let scale = automationTimeScale
        switch step.type {
        case "scene":
            guard let id = step.scene, let scene = home.scenes.value.scenes.first(where: { $0.id == id }) else { throw CatalogError("the scene is gone") }
            let answer = try await run(scene, trigger: .automation, allowSecurity: false)
            if answer["ok"] == false { throw CatalogError("some of \(scene.name)'s actions failed") }
            let held = answer["note"] != nil
            return (held ? "\(scene.name): its locks, doors and alarms were left out: automations do not change them" : nil, held)
        case "set":
            guard let found = find(id: step.id ?? "") else { throw CatalogError("the accessory is gone") }
            let target = try characteristic(in: found, service: step.service, characteristic: step.characteristic ?? "")
            if target.isSecurityControl { return ("\(found.accessory.name) \(target.type.name): a lock, door or alarm: automations do not change them", true) }
            _ = try await write(found, service: step.service, characteristic: step.characteristic ?? "", value: step.value ?? .null, allowSecurity: false)
            return (nil, false)
        case "wait":
            try await Task.sleep(for: .seconds((step.seconds ?? 0) * scale))
            return (nil, false)
        case "waitUntil":
            let deadline = ContinuousClock.now + .seconds((step.seconds ?? 3600) * scale)
            // The characteristic is a live reference: found once, read each second.
            guard let found = find(id: step.id ?? "") else { throw CatalogError("the accessory is gone") }
            let target = try characteristic(in: found, service: step.service, characteristic: step.characteristic ?? "")
            while ContinuousClock.now < deadline {
                if SceneRules.compare(Self.json(target.value), step.operator ?? "eq", step.value) { return (nil, false) }
                try await Task.sleep(for: .seconds(min(1, max(0.01, scale))))
            }
            return ("timed out: went on", false)
        case "notify":
            let sent = await notify(.automationMessage, title: step.title ?? automation.name, message: step.message ?? "", path: "/automations",
                                    subject: "\(automation.id):\(UUID().uuidString)")
            return (sent == nil ? "no notification channel is on, or the limit was reached" : nil, false)
        case "tool":
            return (try await callPluginAction(step.tool ?? "", arguments: step.arguments ?? [:], by: automation.name), false)
        default:
            throw CatalogError("unknown step \(step.type)")
        }
    }

    /// Calls a plugin's action as its MCP tool does, for an Automation.
    func callPluginAction(_ name: String, arguments: JSONValue, by automation: String) async throws -> String? {
        guard let tool = automationTools[name] else { throw CatalogError("\(name) is gone, or needs a person's confirmation") }
        let (found, instances) = actionInstance(platform: tool.platform, wanted: arguments["instance"]?.stringValue)
        guard let instance = found else {
            throw CatalogError(instances.isEmpty ? "no \(tool.pluginName) block is running" : "say which instance: \(instances.map(\.name).joined(separator: ", "))")
        }
        var bare = arguments.objectValue ?? [:]
        bare.removeValue(forKey: "instance")
        let request = tool.action.request(arguments: .object(bare), user: "automation \(automation)")
        var sent: PluginWebResponse?
        let send = { () async throws -> Bool in
            sent = try await self.host.handleWebRequest(platform: tool.platform, name: instance.name, request)
            return (sent?.status ?? 500) < 400
        }
        // A scene recalled on the plugin's own hub: what its lights were is kept, as after any scene, for stop_scene.
        if tool.action.changesLights {
            _ = try await holdLightChanges("\(tool.pluginName): \(tool.action.title)", id: Self.showID(of: "action-" + SceneRules.newID()), platform: instance, by: "automation \(automation)", during: send)
        } else {
            _ = try await send()
        }
        guard let response = sent else { throw CatalogError("\(instance.name) is not running") }
        guard response.status < 400 else { throw CatalogError(response.json["error"]?.stringValue ?? "HTTP \(response.status)") }
        return nil
    }

    /// Why a trigger's run did not go ahead: written when the reason changes, else at most once a minute, so a flapping
    /// sensor does not rewrite automations.json at each change.
    func noteSkip(_ automation: Automation, trigger: String, reason: String) {
        if let last = automation.lastSkipped, last.reason == reason, let at = ISO8601DateFormatter().date(from: last.at), Date().timeIntervalSince(at) < 60 { return }
        recordAutomation(automation.id) { $0.lastSkipped = AutomationRunRecord(at: SceneRules.now(), ok: true, trigger: trigger, reason: reason) }
    }

    func recordAutomation(_ id: String, _ change: (inout Automation) -> Void) {
        try? home.automations.update { file in
            guard let index = file.automations.firstIndex(where: { $0.id == id }) else { return }
            change(&file.automations[index])
        }
    }

    // MARK: Triggers

    /// Runs the Automations whose timed triggers are due at this minute.
    func runDueAutomations(at now: Date, calendar: Calendar = .current) {
        let location = host.configuration.location
        for automation in home.automations.value.automations where automation.isEnabled {
            guard let trigger = automation.triggers.first(where: { SceneRules.due($0, at: now, location: location, calendar: calendar) }) else { continue }
            start(automation, trigger: trigger.type)
        }
    }

    /// A characteristic changed: starts the Automations whose triggers fire (each at most once per 5 seconds), and starts
    /// or ends the stays timers it concerns.
    func automationCharacteristicChanged(_ accessory: Accessory, _ characteristic: Characteristic, _ value: HAPValue, previous: HAPValue?, now: Date = Date()) {
        let name = Self.normalized(characteristic.type.name)
        for automation in home.automations.value.automations where automation.isEnabled {
            for (index, trigger) in automation.triggers.enumerated() where trigger.isEnabled && trigger.id == accessory.id && Self.normalized(trigger.characteristic ?? "") == name {
                let next = Self.json(value), before = previous.map(Self.json)
                switch trigger.type {
                case "characteristic":
                    guard SceneRules.fires(trigger, previous: before, next: next) else { continue }
                case "threshold":
                    guard AutomationRules.crosses(trigger, previous: before, next: next) else { continue }
                case "stays":
                    stays(automation, trigger: trigger, index: index, matches: SceneRules.compare(next, trigger.operator ?? "eq", trigger.value))
                    continue
                default:
                    continue
                }
                let key = "automation:\(automation.id)|\(index)"
                let allowed = home.watched.withLockedValue { watched -> Bool in
                    if let last = watched.fired[key], now.timeIntervalSince(last) < SceneRules.cooldown { return false }
                    watched.fired[key] = now
                    return true
                }
                guard allowed else { continue }
                start(automation, trigger: trigger.type)
                break
            }
        }
    }

    /// A `stays` trigger's value now matches (a timer starts, unless one runs) or no longer does (its timer ends).
    private func stays(_ automation: Automation, trigger: SceneTrigger, index: Int, matches: Bool) {
        let key = "\(automation.id)|\(index)"
        guard matches else {
            home.staysTimers.withLockedValue { $0.removeValue(forKey: key) }?.cancel()
            return
        }
        let seconds = Double(trigger.forSeconds ?? 0) * automationTimeScale
        let catalog = self
        home.staysTimers.withLockedValue { timers in
            guard timers[key] == nil else { return }
            timers[key] = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                catalog.home.staysTimers.withLockedValue { _ = $0.removeValue(forKey: key) }
                // Still as it was asked to stay: it runs with the automation as saved now.
                guard let current = catalog.home.automations.value.automations.first(where: { $0.id == automation.id }), current.isEnabled,
                      let found = catalog.find(id: trigger.id ?? ""), let target = try? catalog.characteristic(in: found, service: trigger.service, characteristic: trigger.characteristic ?? ""),
                      SceneRules.compare(Self.json(target.value), trigger.operator ?? "eq", trigger.value) else { return }
                catalog.start(current, trigger: "stays")
            }
        }
    }

    /// At start: a `stays` trigger whose value already matches starts counting from now.
    func seedStaysTimers() {
        for automation in home.automations.value.automations where automation.isEnabled {
            for (index, trigger) in automation.triggers.enumerated() where trigger.type == "stays" && trigger.isEnabled {
                guard let found = find(id: trigger.id ?? ""), let target = try? characteristic(in: found, service: trigger.service, characteristic: trigger.characteristic ?? "") else { continue }
                if SceneRules.compare(Self.json(target.value), trigger.operator ?? "eq", trigger.value) { stays(automation, trigger: trigger, index: index, matches: true) }
            }
        }
    }

    /// Stops every run and timer (stopHome).
    func stopAutomations() {
        for running in home.automationRuns.withLockedValue({ runs in defer { runs = [:] }; return Array(runs.values) }) { running.task.cancel() }
        for timer in home.staysTimers.withLockedValue({ timers in defer { timers = [:] }; return Array(timers.values) }) { timer.cancel() }
    }
}

extension HomeswiftCatalog {
    // MARK: The Assistant's draft

    /// An Automation the Assistant writes from a sentence, not saved: the person reviews it in the editor. Accessories
    /// reach the model by handles (a1, a2…), never their ids, with their names, rooms and characteristics; locks,
    /// garage doors and alarms are listed only to be watched. Answers the draft and what the bridge's checks say of it.
    public func draftAutomation(_ sentence: String, language: String? = nil) async throws -> JSONValue {
        let words = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.count <= 500 else { throw CatalogError("Describe the automation in 1 to 500 characters") }
        guard let assistant = host.assistant?.speaking(language) else { throw CatalogError("the Assistant is off: add a HomeswiftAiKit block") }
        var handles: [String: String] = [:]
        let accessories: [JSONValue] = located().filter { $0.layout?.hidden != true }.prefix(300).enumerated().map { index, found in
            let handle = "a\(index + 1)"
            handles[handle] = found.accessory.id
            let characteristics = found.accessory.services.flatMap(\.characteristics).filter { !$0.isConfidential && $0.type.permissions.contains(.events) && HistoryStore.kind(of: $0.type) != nil }
            var object: [String: JSONValue] = ["id": .string(handle), "name": .string(found.layout?.name ?? found.accessory.name), "characteristics": .array(characteristics.map { one in
                var entry: [String: JSONValue] = ["name": .string(one.type.name), "value": Self.json(one.value)]
                if one.type.permissions.contains(.pairedWrite) && !one.isSecurityControl { entry["writable"] = true }
                if let valid = one.type.validValues { entry["validValues"] = .array(valid.map { .number(Double($0)) }) }
                return .object(entry)
            })]
            if let room = found.room { object["room"] = .string(room) }
            return .object(object)
        }
        let home: JSONValue = [
            "accessories": .array(accessories),
            "scenes": .array(home.scenes.value.scenes.map { ["id": .string($0.id), "name": .string($0.name)] }),
            "actions": .array(automationTools.values.map { ["name": .string($0.name), "title": .string($0.action.title), "arguments": $0.inputSchema] }),
        ]
        let reply: JSONGenerationResult
        do {
            reply = try await assistant.draftAutomation(words, home: home)
        } catch let error as JSONGenerationError {
            throw CatalogError("The Assistant could not write an automation: \(error.message)")
        }
        // The handles back to the accessories' ids.
        func restore(_ value: JSONValue) -> JSONValue {
            switch value {
            case .array(let list): return .array(list.map(restore))
            case .object(var object):
                if let handle = object["id"]?.stringValue, let id = handles[handle] { object["id"] = .string(id) }
                for (key, inner) in object where key != "id" { object[key] = restore(inner) }
                return .object(object)
            default: return value
            }
        }
        let draft = restore(reply.data)
        var answer: [String: JSONValue] = ["draft": draft]
        do {
            answer["automation"] = try saveAutomation(draft, dryRun: true)["automation"] ?? .null
        } catch let error as CatalogError {
            answer["problem"] = .string(error.description)
        }
        return .object(answer)
    }

    // MARK: Tools

    static let automationSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string", "description": "An automation's id, to change it; left out for a new one"],
            "name": ["type": "string", "minLength": 1, "maxLength": 64],
            "enabled": ["type": "boolean"], "mode": ["type": "string", "enum": ["restart", "single"]],
            "homeKit": ["type": "boolean", "description": "A switch on the Homeswift Scenes accessory in the Home app turns it on and off"],
            "triggers": ["type": "array", "maxItems": 10, "items": ["type": "object"], "description": .string(
                "Any of them starts it. {type: time, at: HH:mm, days: [0-6, 0 Sunday]}; {type: sun, event: sunrise|sunset, offsetMinutes, days}; {type: cron, cron}; "
                + "{type: characteristic, id, characteristic, operator: changes|eq|neq|gt|gte|lt|lte, value}; {type: stays, id, characteristic, operator, value, forSeconds}; "
                + "{type: threshold, id, characteristic, direction: above|below, value}")],
            "conditions": ["type": "array", "maxItems": 10, "items": ["type": "object"], "description": .string(
                "All must hold when a trigger fires. {type: time, after, before: HH:mm|sunrise|sunset}; {type: characteristic, id, characteristic, operator, value}")],
            "steps": ["type": "array", "minItems": 1, "maxItems": 30, "items": ["type": "object"], "description": .string(
                "Run in order. {type: scene, scene: <id>}; {type: set, id, characteristic, value}; {type: wait, seconds}; {type: waitUntil, id, characteristic, operator, value, seconds}; "
                + "{type: notify, title, message}; {type: tool, tool: <a plugin action's tool name>, arguments}. Locks, garage doors and alarms are never set: such a step is skipped.")],
        ],
    ]

    var automationToolsList: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "list_automations", title: "List automations",
                description: "What the bridge does on its own: each Automation's triggers (a time, the sun, cron, an accessory's change, a value that stays so for a while, a number crossing a threshold), "
                    + "conditions, steps (apply a scene, set a value, wait, wait until, notify, a plugin's action), mode (restart or single), whether it is on, whether it touches a lock, "
                    + "garage door or alarm (security), and its last run with each step's result. Also the plugins' actions a step may call (tools).",
                outputSchema: Output.object(["automations": ["type": "array"]], required: ["automations"]),
                scope: .read, idempotent: true
            ) { _ in
                var answer = catalog.automationsJSON().objectValue ?? [:]
                answer["tools"] = catalog.automationToolsJSON()["tools"]
                return .json(.object(answer))
            },
            MCPTool(
                name: "save_automation", title: "Save automation",
                description: "Creates an Automation, or changes one (id). It runs when any trigger fires and every condition holds, its steps in order. "
                    + "mode restart (the default) starts again when a trigger fires during a run; single ignores it. Locks, garage doors and alarms are never set by an automation. "
                    + "One that touches them (a trigger, a condition or a step on one, or a scene that changes one) asks the user first. dryRun checks it without saving.",
                inputSchema: Self.automationSchema, scope: .admin, supportsDryRun: true,
                confirmsWhen: { arguments in
                    guard let automation = try? AutomationRules.automation(from: arguments, id: "check", existing: nil, tools: catalog.automationTools) else { return false }
                    return catalog.withLookup { catalog.touchesSecurity(automation) }
                }
            ) { call in .json(try catalog.saveAutomation(call.arguments, dryRun: call.isDryRun)) },
            MCPTool(
                name: "run_automation", title: "Run automation",
                description: "Runs an Automation's steps now, whatever its triggers and conditions, and answers its run: each step's result. Its locks, doors and alarms stay as they are.",
                inputSchema: ["type": "object", "required": ["automation"], "properties": ["automation": ["type": "string", "minLength": 1, "description": "Its id or name, from list_automations"]]],
                scope: .control
            ) { call in .json(try await catalog.runAutomation(try call.string("automation"))) },
            MCPTool(
                name: "delete_automation", title: "Delete automation",
                description: "Removes an Automation: it stops running, and its switch leaves the Home app. Its scenes stay. The user confirms first.",
                inputSchema: ["type": "object", "required": ["automation"], "properties": ["automation": ["type": "string", "minLength": 1, "description": "Its id or name"]]],
                scope: .admin, destructive: true
            ) { call in .json(try catalog.deleteAutomation(try call.string("automation"))) },
        ]
    }
}
