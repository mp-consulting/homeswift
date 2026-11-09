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
    /// it has, HomeKit's numbers for it, and the Automations it starts.
    private func partJSON(_ part: RemotePart, number: Int, of accessory: Accessory, automations: [Automation]) -> JSONValue {
        let services = accessory.services.filter { $0.type == .statelessProgrammableSwitch && part.services.contains(RemoteLayout.partID(of: $0)) }
        let name = part.name ?? services.first?[.name]?.value.stringValue
        // A Button's gestures: those its switch sends (its Programmable Switch Event's valid values); a long press
        // either runs something or, held, dims.
        var gestures: [RemoteControl.Gesture]
        if part.kind == .wheel {
            gestures = [.turn]
        } else {
            let presses = Set(services.first?[.programmableSwitchEvent]?.type.validValues ?? [0, 1, 2])
            gestures = [.press]
            if presses.contains(HAPConstants.ProgrammableSwitchEvent.doublePress) { gestures.append(.double) }
            if presses.contains(HAPConstants.ProgrammableSwitchEvent.longPress) { gestures += [.long, .hold] }
        }
        let starts = automations.filter { automation in
            automation.triggers.contains { trigger in
                trigger.type == "press" && trigger.id == accessory.id
                    && (trigger.service.map { wanted in services.contains { Self.service($0, isNamed: wanted) } } ?? true)
            }
        }
        return [
            "id": .string(part.id), "kind": .string(part.kind.rawValue), "name": name.map(JSONValue.string) ?? .null,
            "number": .number(Double(services.first?[.serviceLabelIndex]?.value.intValue ?? number)),
            "channel": part.channel.map { .number(Double($0)) } ?? .null,
            "services": .array(part.services.map(JSONValue.string)),
            "homeKit": .array(services.compactMap { $0[.serviceLabelIndex]?.value.intValue }.map { .number(Double($0)) }),
            "gestures": .array(gestures.map { .string($0.rawValue) }),
            "automations": .array(starts.map { ["id": .string($0.id), "name": .string($0.name), "enabled": .bool($0.isEnabled)] }),
        ]
    }

    /// What a Control may drive (lights and shutters), power (switches and outlets) and run (the home's Scenes: Homeswift's
    /// own and its hubs'). Each accessory says its Group, if any, which the page lists its members under.
    func remoteTargetsJSON(_ located: [Located]) async -> JSONValue {
        let all = located.filter { !$0.accessory.isRemote }
        let groupOf = Dictionary(wallGroups.flatMap { group in group.members.map { ($0, group) } }, uniquingKeysWith: { first, _ in first })
        func entry(_ located: Located, kind: String) -> JSONValue {
            var item: [String: JSONValue] = ["id": .string(located.accessory.id), "name": .string(located.accessory.name), "kind": .string(kind),
                                             "room": located.room.map(JSONValue.string) ?? .null]
            if let group = groupOf[located.accessory.id] { item["group"] = ["id": .string(group.id), "name": .string(group.name)] }
            if kind == RemoteControl.TargetKind.light.rawValue, !located.accessory.services.contains(where: { $0[.brightness] != nil }) { item["onOffOnly"] = true }
            return .object(item)
        }
        let targets = all.compactMap { located in RemoteControl.targetKind(of: located.accessory).map { entry(located, kind: $0.rawValue) } }
        let power = all.filter { RemoteControl.canPower($0.accessory) }
            .map { entry($0, kind: $0.accessory.services.contains { $0.type == .outlet } ? "outlet" : "switch") }
        let own: [JSONValue] = home.scenes.value.scenes.map { ["id": .string($0.id), "name": .string($0.name), "room": .null] }
        let hubs: [JSONValue] = await foundPluginScenes().map { ["id": .string($0.id), "name": .string($0.scene.name), "room": $0.scene.room.map(JSONValue.string) ?? .null] }
        return ["targets": .array(targets), "power": .array(power), "scenes": .array(own + hubs)]
    }

    /// Why Controls cannot drive what they name, or nil: their targets are lights and shutters, their power switches or
    /// outlets, none a security control (a door's unlock shown as a switch). An accessory not on the bridge now (a plugin
    /// starting) passes: the bridge checks again when the Control runs.
    func remoteTargetsProblem(in controls: [RemoteControl]) -> String? {
        for target in Set(controls.flatMap(\.targets)) {
            if let accessory = find(id: target)?.accessory, RemoteControl.targetKind(of: accessory) == nil {
                return "\(accessory.name) is no light or shutter a remote may drive"
            }
        }
        for power in Set(controls.flatMap(\.power)) {
            if let accessory = find(id: power)?.accessory, !RemoteControl.canPower(accessory) {
                return "\(accessory.name) is no switch or outlet a remote may power the lights with"
            }
        }
        return nil
    }

    var remoteTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "list_remotes", title: "List remotes",
                description: "Every Remote (an accessory with Buttons, from any plugin): its Buttons and Wheels (part ids, names, Channels, the gestures each has: "
                    + "press, double, long, hold, turn), their Controls (what each gesture does, run by the bridge at once), and the Automations each Button starts. "
                    + "Also what a Control may drive (lights and shutters), power (switches and outlets) and run (Scenes). Change a Remote's Controls with update_settings "
                    + "on the Remote's accessory, key controls: a list of {part, gesture, action, targets, power, scene, direction, step, reversed, powerDelay}; "
                    + "actions: press, double and long: toggle, on, off, scene, stop; hold: dim (direction alternate, up or down); turn: step. A Button has a long press or a hold, not both.",
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
                    + "turn) and action: press, double and long toggle, on, off, scene (scene: an id from list_remotes' scenes) or stop (moving shutters); hold dim "
                    + "(direction alternate, up or down); turn step. targets: lights and shutters (list_remotes' targets), power: switches or outlets that power the "
                    + "lights. step 1-25 % (5), reversed (a Wheel turned up dims), powerDelay 1-30 s (5). A Button has a long press or a hold, not both. "
                    + "The bridge runs them the moment the remote is pressed; locks, doors and alarms are never driven. dryRun checks without saving.",
                inputSchema: ["type": "object", "required": ["remote", "part", "controls"], "properties": [
                    "remote": ["type": "string", "maxLength": 200, "description": "The Remote's accessory id"],
                    "part": ["type": "string", "maxLength": 200, "description": "The Button's or Wheel's id (list_remotes' parts)"],
                    "controls": ["type": "array", "maxItems": 5, "items": ["type": "object", "required": ["gesture", "action"], "properties": [
                        "gesture": ["type": "string", "enum": .array(RemoteControl.Gesture.allCases.map { .string($0.rawValue) })],
                        "action": ["type": "string", "enum": .array(RemoteControl.Action.allCases.map { .string($0.rawValue) })],
                        "targets": ["type": "array", "maxItems": 50, "items": ["type": "string"]], "power": ["type": "array", "maxItems": 10, "items": ["type": "string"]],
                        "scene": ["type": "string"], "direction": ["type": "string", "enum": ["alternate", "up", "down"]],
                        "step": ["type": "integer", "minimum": 1, "maximum": 25], "reversed": ["type": "boolean"], "powerDelay": ["type": "integer", "minimum": 1, "maximum": 30],
                    ]]],
                ]],
                scope: .admin, supportsDryRun: true
            ) { call in
                let id = try call.string("remote"), part = try call.string("part")
                let controls = try await catalog.remoteControls(setting: call.arguments["controls"] ?? .array([]), part: part, of: id)
                let who = "MCP \(call.session.clientInfo?.name ?? "client")"
                return .json(try await catalog.updateAccessorySettings([(id, ["controls": controls.isEmpty ? .null : RemoteControl.json(controls)])],
                                                                       dryRun: call.isDryRun, by: .client, who: who))
            },
        ]
    }

    /// A Remote's Controls with one part's replaced by `given` (its gesture, action and the rest, without the part), checked
    /// as the page checks them: a part the Remote has, gestures it sends, targets that are lights or shutters, power that
    /// switches, Scenes that exist.
    func remoteControls(setting given: JSONValue, part: String, of id: String) async throws -> [RemoteControl] {
        guard let state = host.remote(of: id), let located = find(id: id) else { throw CatalogError("\(id) is no Remote (list_remotes)", notFound: true) }
        guard let remote = remotesJSON([located])["remotes"]?.arrayValue?.first,
              let info = remote["parts"]?.arrayValue?.first(where: { $0["id"]?.stringValue == part }) else {
            throw CatalogError("\(id) has no part \(part); its parts are \(state.layout.parts.map(\.id).joined(separator: ", "))", notFound: true)
        }
        let gestures = Set(info["gestures"]?.arrayValue?.compactMap(\.stringValue) ?? [])
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
        for scene in mine.compactMap(\.scene) where !scenes.contains(scene) { throw CatalogError("No scene \(scene) (list_remotes' scenes)", notFound: true) }
        let next = state.controls.filter { $0.part != part } + mine
        if let problem = RemoteControl.problem(in: next) { throw CatalogError(problem) }
        return next
    }
}
