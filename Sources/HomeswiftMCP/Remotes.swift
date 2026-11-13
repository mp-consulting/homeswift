import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

// The Remotes (GLOSSARY.md, docs/adr/0009-remote-controls-are-not-automations.md): every accessory with Buttons, its
// Buttons and Wheels, their Controls and the Automations a Button starts, for the web UI's Remotes page and `list_remotes`.
// Controls are written as the Remote's Accessory Settings (`controls`), through the settings writers.

extension HomeswiftCatalog {
    /// The Remotes page and `list_remotes`: every Remote, what a Control may drive, power and run.
    public func remotesPageJSON() async -> JSONValue {
        let all = located()
        var answer = remotesJSON(all).objectValue ?? [:]
        for (key, value) in (await remoteTargetsJSON(all)).objectValue ?? [:] { answer[key] = value }
        // The rooms in the home's order, which the page lists the targets in.
        answer["rooms"] = .array(allRoomNames(all).map(JSONValue.string))
        // The Automations a Button's press may start (as their press Trigger).
        answer["automations"] = .array(home.automations.value.automations.map { Self.automationJSON($0) })
        return .object(answer)
    }

    /// Every Remote on the bridge, in room then name order.
    func remotesJSON(_ all: [Located]) -> JSONValue {
        let automations = home.automations.value.automations
        let notInHome = Set(host.configuration.platforms.flatMap(\.hiddenFromHomeKit))
        let remotes = all.filter { $0.accessory.isRemote && !$0.isSeparatedFunction }
            .sorted { ($0.room ?? "\u{10FFFF}", $0.accessory.name) < ($1.room ?? "\u{10FFFF}", $1.accessory.name) }
        return ["remotes": .array(remotes.compactMap { located -> JSONValue? in
            let accessory = located.accessory
            guard let state = host.remote(of: accessory.id) else { return nil }
            let layout = state.layout
            var remote: [String: JSONValue] = [
                "id": .string(accessory.id), "name": .string(accessory.name), "room": located.room.map(JSONValue.string) ?? .null,
                "plugin": located.platform.map { .string($0.pluginName) } ?? .null, "instance": located.platform.map { .string($0.name) } ?? .null,
                // Its presses reach Apple Home too, unless it is Not in Home; one Apple Home has is mirrored through Wingman.
                "inAppleHome": .bool(!notInHome.contains(accessory.id) && accessory.mirroredFrom == nil),
                "mirrored": .bool(accessory.mirroredFrom != nil),
                "parts": .array(layout.parts.enumerated().map { partJSON($1, number: $0 + 1, of: accessory, automations: automations) }),
                "controls": RemoteControl.json(state.controls),
            ]
            if accessory.isUnavailable { remote["unavailable"] = true }
            return .object(remote)
        })]
    }

    /// One Button or Wheel: its name (nil when neither its plugin nor HomeKit gives one: the page numbers it), the gestures
    /// it has, HomeKit's numbers for it, and the Automations it starts, each with the gesture its press Trigger is.
    private func partJSON(_ part: RemotePart, number: Int, of accessory: Accessory, automations: [Automation]) -> JSONValue {
        let services = Self.switches(of: part, in: accessory)
        let name = part.name ?? services.first?[.name]?.value.stringValue
        let gestures = Self.gestures(of: part, switches: services)
        let starts = automations.flatMap { automation in
            Self.presses(of: automation, for: accessory.id, services: services).map { (automation, $0) }
        }
        return [
            "id": .string(part.id), "kind": .string(part.kind.rawValue), "name": name.map(JSONValue.string) ?? .null,
            "number": .number(Double(services.first?[.serviceLabelIndex]?.value.intValue ?? number)),
            "channel": part.channel.map { .number(Double($0)) } ?? .null,
            "services": .array(part.services.map(JSONValue.string)),
            "homeKit": .array(services.compactMap { $0[.serviceLabelIndex]?.value.intValue }.map { .number(Double($0)) }),
            "gestures": .array(gestures.map { .string($0.rawValue) }),
            "automations": .array(starts.map { automation, gesture in Self.automationJSON(automation, gesture: gesture) }),
        ]
    }

    /// An Automation's summary for the Remotes page, with the gesture whose press starts it when it is a Button's.
    static func automationJSON(_ automation: Automation, gesture: RemoteControl.Gesture? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(automation.id), "name": .string(automation.name), "enabled": .bool(automation.isEnabled)]
        if let gesture { object["gesture"] = .string(gesture.rawValue) }
        return .object(object)
    }

    /// A Button's Stateless Programmable Switches: the services its part is made of.
    static func switches(of part: RemotePart, in accessory: Accessory) -> [Service] {
        accessory.services.filter { $0.type == .statelessProgrammableSwitch && part.services.contains(RemoteLayout.partID(of: $0)) }
    }

    /// A part's gestures: a Wheel turns; a Button presses, and double or long presses when its switch sends them (its
    /// Programmable Switch Event's valid values), a long press either running something or, held, dimming.
    static func gestures(of part: RemotePart, switches: [Service]) -> [RemoteControl.Gesture] {
        guard part.kind == .button else { return [.turn] }
        let presses = Set(switches.first?[.programmableSwitchEvent]?.type.validValues ?? [0, 1, 2])
        var gestures: [RemoteControl.Gesture] = [.press]
        if presses.contains(HAPConstants.ProgrammableSwitchEvent.doublePress) { gestures.append(.double) }
        if presses.contains(HAPConstants.ProgrammableSwitchEvent.longPress) { gestures += [.long, .hold] }
        return gestures
    }

    /// Whether a Trigger is a press of this accessory's Button (`services`): one naming none of its switches is any of them.
    static func isPress(_ trigger: SceneTrigger, of accessoryID: String, services: [Service]) -> Bool {
        trigger.type == "press" && trigger.id == accessoryID
            && (trigger.service.map { wanted in services.contains { Self.service($0, isNamed: wanted) } } ?? true)
    }

    /// The gestures of a Button an Automation starts on (its press Triggers: press, double or long), in that order.
    static func presses(of automation: Automation, for accessoryID: String, services: [Service]) -> [RemoteControl.Gesture] {
        let pressed = Set(automation.triggers.filter { Self.isPress($0, of: accessoryID, services: services) }.compactMap(\.press))
        return RemoteControl.Gesture.automationGestures.filter { pressed.contains(Self.press(of: $0)) }
    }

    /// A press Trigger's kind for a gesture: single, double or long.
    static func press(of gesture: RemoteControl.Gesture) -> String {
        gesture == .press ? "single" : gesture.rawValue
    }

    /// What a Control may drive (lights, shutters and Appliances), power (switches and outlets) and run (the home's Scenes:
    /// Homeswift's own and its hubs'). Each accessory says its Group, if any, which the page lists its members under; an
    /// accessory with more than one Function it may drive (a two-channel relay, a fan with a light) lists them too, each
    /// `<id>#<key>` with `of` its accessory (docs/adr/0011-a-control-names-a-function.md).
    func remoteTargetsJSON(_ located: [Located]) async -> JSONValue {
        let all = located.filter { !$0.accessory.isRemote }
        let groupOf = Dictionary(wallGroups.flatMap { group in group.members.map { ($0, group) } }, uniquingKeysWith: { first, _ in first })
        func entry(_ located: Located, _ target: ControlTarget, kind: String) -> JSONValue {
            let id = ControlTarget.reference(located.accessory.id, function: target.function)
            var item: [String: JSONValue] = ["id": .string(id), "name": .string(Self.targetName(target, located: located)), "kind": .string(kind),
                                             "room": located.room.map(JSONValue.string) ?? .null]
            if target.function != nil {
                item["of"] = .string(located.accessory.id)
            } else if let group = groupOf[located.accessory.id] {
                item["group"] = ["id": .string(group.id), "name": .string(group.name)]
            }
            if kind == RemoteControl.TargetKind.light.rawValue, target.light?.service[.brightness] == nil { item["onOffOnly"] = true }
            if kind == RemoteControl.TargetKind.appliance.rawValue, target.opens { item["opens"] = true }
            if target.isSecurity { item["security"] = true }
            return .object(item)
        }
        func powerKind(_ target: ControlTarget) -> String {
            target.powerService?.type == .outlet ? "outlet" : "switch"
        }
        var targets: [JSONValue] = [], power: [JSONValue] = []
        for located in all {
            let whole = ControlTarget(accessory: located.accessory)
            if let kind = whole.kind { targets.append(entry(located, whole, kind: kind.rawValue)) }
            if whole.powerSwitch != nil { power.append(entry(located, whole, kind: powerKind(whole))) }
            // A separated accessory's Functions are accessories of their own already.
            guard located.accessory.separatedFrom == nil else { continue }
            let functions = Separation.functions(of: located.accessory).map { ControlTarget(accessory: located.accessory, function: $0.key, services: $0.services) }
            let driven = functions.compactMap { function in function.kind.map { (function, $0) } }
            if driven.count > 1 { targets += driven.map { entry(located, $0, kind: $1.rawValue) } }
            let powering = functions.filter { $0.powerSwitch != nil }
            if powering.count > 1 { power += powering.map { entry(located, $0, kind: powerKind($0)) } }
        }
        let own: [JSONValue] = home.scenes.value.scenes.map { ["id": .string($0.id), "name": .string($0.name), "room": .null] }
        let hubs: [JSONValue] = await foundPluginScenes().map { ["id": .string($0.id), "name": .string($0.scene.name), "room": $0.scene.room.map(JSONValue.string) ?? .null] }
        return ["targets": .array(targets), "power": .array(power), "scenes": .array(own + hubs)]
    }

    /// A target's name: its accessory's, or its Function's as Separate Functions would name it ("Relay Channel 2").
    static func targetName(_ target: ControlTarget, located: Located?) -> String {
        let name = located?.layout?.name ?? target.accessory.name
        guard target.function != nil, let first = target.services.first else { return name }
        return Separation.name(of: first, in: target.accessory)
    }

    /// What a Control's target or Power Switch names now, on the bridge.
    func controlTarget(_ reference: String) -> ControlTarget? {
        ControlTarget.resolve(reference) { find(id: $0)?.accessory }
    }

    /// Why Controls cannot drive what they name, or nil: their targets are lights, shutters and Appliances (locks, garage
    /// doors and alarms included), their power switches or outlets; a hold or a Wheel dims something,
    /// not only Appliances. A target not on the bridge now (a plugin starting, a device gone) passes: the bridge checks
    /// again when the Control runs.
    func remoteTargetsProblem(in controls: [RemoteControl]) -> String? {
        for reference in Set(controls.flatMap(\.targets)) {
            if let target = controlTarget(reference), target.kind == nil {
                return "\(Self.targetName(target, located: nil)) is no light, shutter or appliance a remote may drive"
            }
        }
        for reference in Set(controls.flatMap(\.power)) {
            if let target = controlTarget(reference), target.powerSwitch == nil {
                return "\(Self.targetName(target, located: nil)) is no switch or outlet a remote may power the lights with"
            }
        }
        for control in controls where control.gesture == .hold || control.gesture == .turn {
            let kinds = control.targets.compactMap { controlTarget($0)?.kind }
            if !kinds.isEmpty, kinds.allSatisfy({ $0 == .appliance }) {
                return "\(control.part) \(control.gesture.rawValue): appliances only turn on and off, it has nothing to dim or move"
            }
        }
        return nil
    }

    /// Whether writing `controls` (a list of Controls' JSON) to the Remote `remoteID` asks the user first
    /// (docs/adr/0012-a-remote-drives-what-it-is-given.md): a target or Power Switch it adds is a lock, a garage door, a
    /// door, an alarm or a security control, or is not on the bridge now, so cannot be shown not to be one (a Function's
    /// separated id before Separate Functions is turned on, a plugin starting). What the Remote names already is not asked
    /// again.
    func remoteControlsAsk(_ controls: JSONValue?, of remoteID: String?) -> Bool {
        guard let list = controls?.arrayValue, !list.isEmpty else { return false }
        let named = Set((remoteID.flatMap { host.remote(of: $0) }?.controls ?? []).flatMap { $0.targets + $0.power })
        let references = list.flatMap { control in ((control["targets"]?.arrayValue ?? []) + (control["power"]?.arrayValue ?? [])).compactMap(\.stringValue) }
        return withLookup {
            Set(references).subtracting(named).contains { reference in controlTarget(reference).map(\.isSecurity) ?? true }
        }
    }

    /// Whether joining an accessory's Functions again (`separateFunctions` off or cleared) asks the user first: a Remote's
    /// Control naming the device drives the whole of it once joined, and the whole of it holds a lock, a garage door, an
    /// alarm or a security control the Control was never confirmed for (docs/adr/0012-a-remote-drives-what-it-is-given.md).
    func joiningAsks(_ settings: JSONValue?, of accessoryID: String?) -> Bool {
        guard let value = settings?["separateFunctions"], value.boolValue != true, let accessoryID else { return false }
        return withLookup {
            guard let device = find(id: accessoryID)?.device, ControlTarget(accessory: device).isSecurity else { return false }
            let names = { (reference: String) in reference == device.id || reference.hasPrefix("\(device.id)#") || reference.hasPrefix("\(device.id):") }
            return located().contains { located in
                located.accessory.isRemote && (host.remote(of: located.accessory.id)?.controls ?? []).contains { control in
                    (control.targets + control.power).contains(where: names)
                }
            }
        }
    }

    var remoteTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "list_remotes", title: "List remotes",
                description: "Every Remote (an accessory with Buttons, from any plugin): its Buttons and Wheels (part ids, names, Channels, the gestures each has: "
                    + "press, double, long, hold, turn), their Controls (what each gesture does, run by the bridge at once), and the Automations each Button starts. "
                    + "Also what a Control may drive (lights and shutters, and appliances it only turns on and off: switches, outlets, fans, purifiers, TVs, valves, "
                    + "garage doors (on is open), locks (on is unlocked) and alarms (on is armed Away), those with security: true; "
                    + "an accessory with several lists each Function as <id>#<key>), power (switches and outlets) and run (Scenes). Change a Remote's Controls with update_settings "
                    + "on the Remote's accessory, key controls: a list of {part, gesture, action, targets, power, scenes, direction, step, reversed, powerDelay}; "
                    + "actions: press, double and long: toggle, on, off, stop, or scene (it only runs its scenes); a press, a double or a long press also runs its scenes beside its action; hold: dim (direction alternate, up or down); turn: step. A Button has a long press or a hold, not both.",
                outputSchema: Output.object(["remotes": ["type": "array"], "targets": ["type": "array"], "power": ["type": "array"], "scenes": ["type": "array"]],
                                            required: ["remotes"]),
                scope: .read, idempotent: true
            ) { _ in
                .json(await catalog.remotesPageJSON())
            },
            MCPTool(
                name: "set_remote_controls", title: "Set a remote's controls",
                description: "Sets what one Button or Wheel of a Remote does (its Controls; list_remotes gives the remote, its parts and the gestures each has): "
                    + "controls replaces that part's, the remote's other parts keep theirs; an empty list clears it. Each control: gesture (press, double, long, hold, "
                    + "turn) and action: press, double and long toggle, on, off, stop (moving shutters) or scene (it only runs its scenes); scenes (ids from list_remotes' scenes) run on a press, a double or a long press beside its action; hold dim "
                    + "(direction alternate, up or down); turn step. targets: lights, shutters and appliances (list_remotes' targets; a hold or a turn needs a light "
                    + "or a shutter and leaves appliances alone), power: switches or outlets that power the lights, never also a target of the same control. step 1-25 % (5), reversed (a Wheel turned up dims), powerDelay 1-30 s (5). A Button has a long press or a hold, not both. "
                    + "The bridge runs them the moment the remote is pressed, locks, garage doors and alarms included: attaching one asks the user first. "
                    + "automations (optional): {press, double, long: [automation ids]}, the Automations each of the Button's presses starts, as their press Trigger "
                    + "(their Conditions still checked); a gesture left out keeps its own. dryRun checks without saving.",
                inputSchema: ["type": "object", "required": ["remote", "part", "controls"], "properties": [
                    "remote": ["type": "string", "maxLength": 200, "description": "The Remote's accessory id"],
                    "part": ["type": "string", "maxLength": 200, "description": "The Button's or Wheel's id (list_remotes' parts)"],
                    "controls": ["type": "array", "maxItems": 5, "items": ["type": "object", "required": ["gesture", "action"], "properties": [
                        "gesture": ["type": "string", "enum": .array(RemoteControl.Gesture.allCases.map { .string($0.rawValue) })],
                        "action": ["type": "string", "enum": .array(RemoteControl.Action.allCases.map { .string($0.rawValue) })],
                        "targets": ["type": "array", "maxItems": 50, "items": ["type": "string"]], "power": ["type": "array", "maxItems": 10, "items": ["type": "string"]],
                        "scenes": ["type": "array", "maxItems": 20, "items": ["type": "string"]], "direction": ["type": "string", "enum": ["alternate", "up", "down"]],
                        "step": ["type": "integer", "minimum": 1, "maximum": 25], "reversed": ["type": "boolean"], "powerDelay": ["type": "integer", "minimum": 1, "maximum": 30],
                    ]]],
                    "automations": ["type": "object", "description": "The Automations each press starts, by id (list_automations)", "properties": [
                        "press": ["type": "array", "items": ["type": "string"]], "double": ["type": "array", "items": ["type": "string"]],
                        "long": ["type": "array", "items": ["type": "string"]],
                    ]],
                ]],
                scope: .admin, supportsDryRun: true,
                confirmsWhen: { arguments in catalog.remoteControlsAsk(arguments["controls"], of: arguments["remote"]?.stringValue) }
            ) { call in
                let id = try call.string("remote"), part = try call.string("part")
                let controls = try await catalog.remoteControls(setting: call.arguments["controls"] ?? .array([]), part: part, of: id)
                let starts = try call.arguments["automations"].map(HomeswiftCatalog.remoteStarts) ?? [:]
                // The Automations are checked before anything is written: a refusal leaves the Controls as they were.
                if !starts.isEmpty { try catalog.setRemoteAutomations(starts, part: part, of: id, controls: controls, dryRun: true) }
                let who = "MCP \(call.session.clientInfo?.name ?? "client")"
                var answer = try await catalog.updateAccessorySettings([(id, ["controls": controls.isEmpty ? .null : RemoteControl.json(controls)])],
                                                                      dryRun: call.isDryRun, by: .client, who: who).objectValue ?? [:]
                if !starts.isEmpty, !call.isDryRun {
                    answer["automationsChanged"] = .array(try catalog.setRemoteAutomations(starts, part: part, of: id).map(JSONValue.string))
                }
                return .json(.object(answer))
            },
        ]
    }

    /// A Remote's Controls with one part's replaced by `given` (its gesture, action and the rest, without the part), checked
    /// as the page checks them: a part the Remote has, gestures it sends, targets that are lights or shutters, power that
    /// switches, Scenes that exist.
    func remoteControls(setting given: JSONValue, part: String, of id: String) async throws -> [RemoteControl] {
        guard let state = host.remote(of: id), let located = find(id: id) else { throw CatalogError("\(id) is no Remote (list_remotes)", notFound: true) }
        guard let layout = state.layout.parts.first(where: { $0.id == part }) else {
            throw CatalogError("\(id) has no part \(part); its parts are \(state.layout.parts.map(\.id).joined(separator: ", "))", notFound: true)
        }
        let gestures = Set(Self.gestures(of: layout, switches: Self.switches(of: layout, in: located.accessory)).map(\.rawValue))
        let parts = (given.arrayValue ?? []).map { control -> JSONValue in
            var object = control.objectValue ?? [:]
            object["part"] = .string(part)
            return .object(object)
        }
        guard let mine = RemoteControl.list(from: .array(parts)) else { throw CatalogError("controls must be a list of {gesture, action, targets, …}") }
        for control in mine where !gestures.contains(control.gesture.rawValue) {
            throw CatalogError("\(part) has no \(control.gesture.rawValue); its gestures are \(gestures.sorted().joined(separator: ", "))")
        }
        if let problem = remoteTargetsProblem(in: mine) { throw CatalogError(problem) }
        let scenes = Set(((await remoteTargetsJSON([]))["scenes"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        for scene in mine.flatMap(\.scenes) where !scenes.contains(scene) { throw CatalogError("No scene \(scene) (list_remotes' scenes)", notFound: true) }
        let next = state.controls.filter { $0.part != part } + mine
        if let problem = RemoteControl.problem(in: next) { throw CatalogError(problem) }
        return next
    }

    /// `starts`' JSON, `{ press: [ids], double: [ids], long: [ids] }`, as `setRemoteAutomations` takes it.
    public static func remoteStarts(_ json: JSONValue?) throws -> [RemoteControl.Gesture: [String]] {
        guard let object = json?.objectValue else { throw CatalogError("starts is { press, double, long }: the Automations each starts") }
        var starts: [RemoteControl.Gesture: [String]] = [:]
        for (key, value) in object {
            guard let gesture = RemoteControl.Gesture(rawValue: key), RemoteControl.Gesture.automationGestures.contains(gesture),
                  let ids = value.arrayValue?.compactMap(\.stringValue), ids.count == value.arrayValue?.count else {
                throw CatalogError("starts' \(key): a press, double or long press starts a list of Automations, by id")
            }
            starts[gesture] = ids
        }
        return starts
    }

    /// Sets the Automations a Button's press, double press and long press start (docs/adr/0009-remote-controls-are-not-automations.md):
    /// each one's press Trigger for this Button, added or removed, its other Triggers kept. A gesture left out keeps its
    /// Automations. A long press starts none while the Button holds to dim (they are the same press). `dryRun` checks it
    /// all and writes nothing; answers the Automations changed. `controls`: the Remote's Controls as a save about to write
    /// them has them (a hold given in the same save), else its own.
    @discardableResult
    public func setRemoteAutomations(_ starts: [RemoteControl.Gesture: [String]], part: String, of id: String, controls: [RemoteControl]? = nil,
                                     dryRun: Bool = false) throws -> [String] {
        guard let state = host.remote(of: id), let located = find(id: id) else { throw CatalogError("\(id) is no Remote (list_remotes)", notFound: true) }
        guard let layout = state.layout.parts.first(where: { $0.id == part }), layout.kind == .button else {
            throw CatalogError("\(id) has no Button \(part); its Buttons are \(state.layout.parts.filter { $0.kind == .button }.map(\.id).joined(separator: ", "))", notFound: true)
        }
        let services = Self.switches(of: layout, in: located.accessory)
        let gestures = Self.gestures(of: layout, switches: services)
        let byID = Dictionary(home.automations.value.automations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (gesture, ids) in starts {
            guard RemoteControl.Gesture.automationGestures.contains(gesture), gestures.contains(gesture) else {
                throw CatalogError("\(part) cannot start an automation on \(gesture.rawValue): a press, a double or a long press it sends can")
            }
            for automation in ids where byID[automation] == nil { throw CatalogError("No automation \(automation)", notFound: true) }
            // One it starts already keeps going (the page warns); a new one waits for the hold to go.
            let added = ids.filter { byID[$0].map { Self.presses(of: $0, for: id, services: services).contains(gesture) } != true }
            if gesture == .long, !added.isEmpty, (controls ?? state.controls).contains(where: { $0.part == part && $0.gesture == .hold }) {
                throw CatalogError("\(part) holds to dim: its long press is the same press, it starts no new automation")
            }
        }
        // The Button as a press Trigger names it: its subtype, else its name, when the remote has several.
        let several = located.accessory.services.filter { $0.type == .statelessProgrammableSwitch }.count > 1
        let named = several ? (services.first?.subtype ?? services.first?[.name]?.value.stringValue) : nil
        let change = { (automations: inout [Automation]) throws -> [String] in
            var changed: [String] = []
            for index in automations.indices {
                var automation = automations[index]
                let had = Self.presses(of: automation, for: id, services: services)
                for (gesture, ids) in starts {
                    let wanted = ids.contains(automation.id)
                    guard wanted != had.contains(gesture) else { continue }
                    let press = Self.press(of: gesture)
                    if wanted {
                        automation.triggers.append(try AutomationRules.trigger(
                            ["type": "press", "id": .string(id), "service": named.map(JSONValue.string) ?? .null, "press": .string(press)],
                            index: automation.triggers.count))
                        continue
                    }
                    let mine = { (trigger: SceneTrigger) in Self.isPress(trigger, of: id, services: services) && trigger.press == press }
                    // A press Trigger naming no Button starts on all of them: taking it off one is the Automation's to change.
                    if several, automation.triggers.contains(where: { mine($0) && $0.service == nil }) {
                        throw CatalogError("\(automation.name) starts on any of the remote's buttons: change its trigger on the Automations page")
                    }
                    automation.triggers.removeAll(where: mine)
                }
                if automation.triggers.isEmpty {
                    throw CatalogError("\(automation.name) would have no trigger left: delete it, or give it another, on the Automations page")
                }
                if automation.triggers.count > SceneRules.maxTriggers { throw CatalogError("\(automation.name) has \(SceneRules.maxTriggers) triggers already") }
                if automation != automations[index] {
                    automations[index] = automation
                    changed.append(automation.id)
                }
            }
            return changed
        }
        if dryRun {
            var copy = home.automations.value.automations
            return try change(&copy)
        }
        var changed: [String] = []
        try home.automations.update { file in changed = try change(&file.automations) }
        for automation in changed { automationsChanged(automation) }
        return changed
    }
}
