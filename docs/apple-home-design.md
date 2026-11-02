# Apple Home's rooms, scenes and automations

Renaming an Apple Home room from Homeswift, renaming and editing Apple Home scenes, and viewing and editing Apple Home
automations. This note is the design, written before the work starts; the slices at the end land one by one.

## Why Wingman

HAP is the accessory side: an accessory cannot read or change the home's rooms, scenes (action sets) or automations
(triggers). Only a HomeKit controller can, and on a Mac that is a Mac Catalyst app using Apple's HomeKit framework:
Homeswift Wingman. Wingman already serves the homes, their accessories and value changes to paired bridges; it gains
endpoints for the home's structure, and the Wingman plugin maps them onto the hooks Homeswift has
(`PluginRooms`, `PluginScenes`) and onto a new one for automations (`PluginAutomations`).

Nothing here goes over HAP, and Homeswift's own scenes that HomeKit shows as switches (`SceneSwitches.swift`) are a
separate matter.

## Wingman's side

### The owner's opt-in

A new setting, **Let bridges edit rooms, scenes and automations** (`Settings.allowStructure`, off by default), beside
**Let bridges operate locks and doors**. Off, every endpoint below that changes something answers `403` with
`"structural edits are turned off in Wingman's settings"`; the reading ones still answer. The reason is the same as for
locks: Homeswift asks its user before it changes the home, but Wingman cannot see that, and an edit here reaches every
device of the home through iCloud. Running a scene needs only **Let bridges change values** (`allowChanges`), as a
write does.

Security follows the existing rule: a scene that writes a lock, a garage door or an alarm target
(`HomeStore.securityTypes`) is run, created or given such actions only while `allowSecurity` is on. Wingman checks the
scene's actions before `executeActionSet`, not just the request.

HomeKit itself refuses structural edits from a user who is not an administrator of the home
(`home.homeAccessControl(for: home.currentUser).isAdministrator`). Wingman reports it on each home of `GET /homes`
as `editable`, beside the home's `id` and its `rooms` (`[{"id", "name"}]`), so the plugin offers no edit HomeKit would
refuse.

`GET /info` gains `"features": ["structure"]` (and `"structure": true|false`, the setting now), so a bridge knows whether
the endpoints exist without a new API version: everything is additive, `api` stays `"1"`.

### Endpoints

All behind the bearer token, JSON in and out, ids are HomeKit's `uniqueIdentifier`s as `/homes` gives them. Errors
come back as `{"error": "…"}` with `400` (bad request), `403` (setting off, not an administrator, security), `404`
(no such room, scene or automation) or `422` (HomeKit refused: its `HMError` code and description in the message).

| Method and path | Body | Does |
|---|---|---|
| `POST /rooms/rename` | `{"room", "name"}` | `HMRoom.updateName` |
| `GET /scenes` | | Every home's action sets, below |
| `POST /scenes/run` | `{"scene"}` | `HMHome.executeActionSet` |
| `POST /scenes/rename` | `{"scene", "name"}` | `HMActionSet.updateName` |
| `POST /scenes/actions` | `{"scene", "actions": [{"accessory", "characteristic", "value"}]}` | Replaces every characteristic action (removes those not listed, `updateTargetValue` on those kept, adds the new ones) |
| `POST /scenes/create` | `{"home", "name", "actions"}` | `HMHome.addActionSet`, then the actions; answers `{"id"}` |
| `POST /scenes/delete` | `{"scene"}` | `HMHome.removeActionSet` |
| `GET /automations` | | Every home's triggers, below |
| `POST /automations/enable` | `{"automation", "enabled"}` | `HMTrigger.enable` |
| `POST /automations/rename` | `{"automation", "name"}` | `HMTrigger.updateName` |
| `POST /automations/scenes` | `{"automation", "scenes": [ids]}` | `addActionSet`/`removeActionSet` until the trigger runs exactly these |
| `POST /automations/actions` | `{"automation", "actions"}` | As `/scenes/actions`, on the trigger's own action set |
| `POST /automations/time` | `{"automation", "time"}` | A timer's `updateFireDate`/`updateRecurrence`, or a significant event's offset (`updateEvents` with a new `HMSignificantTimeEvent`) |
| `POST /automations/delete` | `{"automation"}` | `HMHome.removeTrigger` |

An action set's actions are a batch: `/scenes/actions` validates every action first (accessory, writable
characteristic, value within its format and range, security) and changes nothing when one is wrong. HomeKit has no
transaction, so a failure halfway (a HomeKit error on the third of five) answers `422` with what was done, and the
bridge reads the scene again.

`GET /scenes`:

```json
{"scenes": [{
  "id": "…", "home": "…", "name": "Soirée", "type": "user",
  "builtIn": false, "executing": false,
  "actions": [{"accessory": "…", "characteristic": "…", "type": "00000008-…", "value": 40}],
  "unsupported": 0
}]}
```

`type` is `user`, `wakeUp`, `sleep`, `homeArrival`, `homeDeparture` (from `actionSetType`); the four built-in ones can be
run and their actions changed, not renamed or deleted (HomeKit refuses), so `builtIn` says so. Action sets of type
`HMActionSetTypeTriggerOwned` are an automation's own actions ("Control accessories" in an automation): they are left
out of `/scenes` and come with their automation. `unsupported` counts actions Wingman cannot show (a shortcut action,
a media action): a scene with any is offered for running and renaming only, never for `/scenes/actions`, which would
drop them.

`GET /automations`:

```json
{"automations": [{
  "id": "…", "home": "…", "name": "Lights at sunset", "enabled": true,
  "lastFired": "2026-11-01T17:12:03Z",
  "trigger": {"kind": "time", "time": {"significant": "sunset", "offsetMinutes": -15, "weekdays": [1,2,3,4,5]}},
  "endEvents": [{"kind": "duration", "seconds": 600}],
  "conditions": [{"kind": "time", "after": {"significant": "sunset"}, "before": {"hour": 23, "minute": 0}}],
  "executeOnce": false,
  "scenes": ["…"],
  "actions": [{"accessory": "…", "characteristic": "…", "type": "…", "value": true}],
  "unsupported": 0
}]}
```

- `trigger.kind` is `time` for an `HMTimerTrigger` (`fireDate`, `recurrence` as weekdays or a calendar interval,
  `timeZone`) and for an `HMEventTrigger` whose only event is an `HMSignificantTimeEvent` or an `HMCalendarEvent`;
  `event` for the other event triggers, whose `trigger.events` list each one (any of them starts it):
  `{"kind": "characteristic", "accessory", "characteristic", "type", "value"}` (`HMCharacteristicEvent`),
  `{"kind": "threshold", …, "min", "max"}` (`HMCharacteristicThresholdRangeEvent`), `{"kind": "presence", "who":
  "anyone|me|everyone", "arriving": true}` (`HMPresenceEvent`), `{"kind": "location", "arriving": true}`
  (`HMLocationEvent`, the region left out: it is where the person lives), `{"kind": "duration", "seconds"}` as an end
  event (`HMDurationEvent`, "Turn off after"), `{"kind": "time", "time"}` for a significant or calendar event among
  others, and `{"kind": "other", "text"}` for anything else. A time is `{"hour", "minute"}` or `{"significant":
  "sunrise|sunset", "offsetMinutes"}`, with `"weekdays"` (1 is Sunday; none is every day).
- `conditions` come from the trigger's `predicate`. HomeKit keeps it as an `NSPredicate`; Wingman recognises the shapes
  the Home app and `HMEventTrigger`'s own builders make (a time window by significant events or date components, a
  characteristic compared with a value, presence) as `{"kind": "time", "after", "before"}` (times as above, either
  open), `{"kind": "characteristic", "accessory", "characteristic", "type", "comparison", "value"}` and `{"kind":
  "presence", "who", "home"}`, and lists anything else as `{"kind": "other", "text": predicateFormat}`.
- Whether it can be edited is its home's `editable`.

### What can be edited

| Edit | HomeKit API | In the first version |
|---|---|---|
| Rename a room | `HMRoom.updateName` | Yes |
| Run, rename, delete a scene | `executeActionSet`, `updateName`, `removeActionSet` | Yes (built-in scenes: run only) |
| A scene's actions | `addAction`, `removeAction`, `HMCharacteristicWriteAction.updateTargetValue` | Yes, characteristic writes only |
| Create a scene | `addActionSet` | Yes |
| Enable, disable, rename, delete an automation | `enable`, `updateName`, `removeTrigger` | Yes |
| Which scenes an automation runs, and its own actions | `addActionSet`/`removeActionSet` on the trigger, the trigger-owned action set | Yes |
| An automation's time (a timer's time and days, a sunrise or sunset offset) | `updateFireDate`, `updateRecurrence`, `updateEvents` | Yes |
| An automation's accessory events, end events and conditions | `updateEvents`, `updateEndEvents`, `updatePredicate` | Shown, not edited: rebuilding a predicate the Home app made risks changing what it means, and the Home app's own editor does this better. A later slice may edit the recognised shapes |
| Create an automation | `addTrigger` | No: an automation made in Homeswift is a Homeswift scene with triggers, which runs on the bridge, not the home hub |
| Shortcut and media actions | none public | No: counted as `unsupported` |

Not tried yet anywhere: none of this has run against real HomeKit. In particular whether HomeKit takes structural edits from a menu bar
app as it takes writes (the empty host window rule in Wingman's CLAUDE.md probably applies to these too), and whether `HMTimerTrigger`'s deprecated recurrence calls still
apply to automations the Home app made on iOS 17 and later, which it stores as event triggers with calendar events.

### Events

The `HMHomeDelegate` calls Wingman does not watch yet each note a structural change, debounced like `homes` (one event
a second after a burst):

- `"kind": "scenes"`: `didAdd`/`didRemove` an action set, `didUpdateNameFor`, `didUpdateActionsFor` an action set;
- `"kind": "automations"`: `didAdd`/`didRemove` a trigger, `didUpdateNameFor`, `didUpdate` a trigger (enabled,
  fire date, events), `didUpdateActionSetsFor` a trigger;
- room renames already make a `homes` event;
- `"kind": "settings"`: the owner turned **Let bridges edit rooms, scenes and automations** on or off. The bridge asks
  `/info` again for `structure`.

An older bridge ignores kinds it does not know (it read the homes again only on `homes`), so these are additive.
The menu bar panel's activity list shows them as it shows `homes`.

### Demo mode

`DemoStore` answers the same endpoints from its synthetic home (a "Demo Evening (Synthetic)" scene, a "Demo Sunset
(Synthetic)" automation) and applies edits in memory, so App Review can exercise them and Wingman's tests cover the
JSON without HomeKit. `HomeStore` and `DemoStore` keep the security and structure checks in step.

## Homeswift's side

### The Wingman plugin

The plugin reads `/info`'s `features` when a link connects; without `structure` it implements none of the hooks below
(`rooms()`, `scenes()` and `automations()` answer `[]`), so an older Wingman behaves as today. With it, a `Link` keeps
the last `/scenes` and `/automations` it read, read again on a `scenes` or `automations` event, at each refresh, and
after each edit it makes.

**Rooms** (`PluginRooms`): `rooms()` answers each home's rooms from `/homes` (`WingmanAPI.Home` gains `id` and `rooms`),
`id` the HomeKit room id, `place` the home's name (and the Wingman's when several are paired). `renameRoom` posts
`/rooms/rename` through the link that has that room. The host already renames, when the room layout's `syncRoomNames`
is on, every hub room named as the Homeswift room was: Apple Home becomes one of those hubs. The UI's text "Rooms of
this name on your Philips Hue, IKEA and eWeLink hubs are renamed too" becomes "… on your hubs and in Apple Home …",
in the four languages. The mirrored accessories take the new room from the `homes` event that follows.

**Scenes** (`PluginScenes`): `scenes()` answers each action set:

| `PluginScene` | From |
|---|---|
| `id` | The action set's HomeKit id (no `/` in a UUID) |
| `name`, `room` | Its name; the room of its accessories when they share one, else none ("Other") |
| `accessoryIDs` | `Wingman:<accessory id>` of its actions' accessories that are mirrored |
| `active` | nil (HomeKit does not tell; `executing` is only true while it runs) |
| `colours` | Up to five lights' colours from their hue/saturation or colour temperature actions |
| `capabilities` | `recall`; with `structure` on and the home `editable`: `rename` and `delete` unless built-in, `update` unless it has `unsupported` actions; `create` through `sceneTarget` |

- `recallScene` posts `/scenes/run`.
- `updateScene(name:lights:)` renames, and turns each `PluginSceneLight` into characteristic actions on the mirrored
  light (On, Brightness, Hue and Saturation or Color Temperature, by the mirror's characteristic ids), keeps the scene's
  other actions, and posts the whole list to `/scenes/actions`. This is what the hub-scene ⋯ menu's **Keep the lights
  as they are** sends, so the menu works unchanged for Apple Home scenes.
- `sceneTarget(accessoryIDs:)` answers "<home> in Apple Home" when every light is a mirror of one home on a Wingman with
  `structure`; `createScene` posts `/scenes/create`.
- `deleteScene` posts `/scenes/delete`.

The general editor (a scene's every action, not just lights) is the automations surface's `actions` below, shared:
`PluginScenes` stays lights-only, as Hue and IKEA need.

### A surface for automations a plugin's hub keeps

Homeswift has none: its automations are its own scenes with triggers. `Sources/HomeswiftPlugin/PluginAutomations.swift`
adds one, shaped like `PluginScenes` (the hub keeps them, Homeswift asks each time and keeps no copy):

```swift
public struct PluginAutomation: Sendable, Equatable {
    public enum Capability: String, Sendable, CaseIterable { case enable, rename, time, scenes, actions, delete }

    public var id: String              // the hub's, without a `/`
    public var name: String
    public var enabled: Bool
    public var place: String?          // the home, for an instance with several
    public var triggers: [PluginAutomationTrigger]      // any of them starts it
    public var endTriggers: [PluginAutomationTrigger]   // "Turn off after 10 minutes"
    public var conditions: [PluginAutomationCondition]
    public var sceneIDs: [String]      // the plugin's own `PluginScene` ids it runs
    public var actions: [PluginAutomationAction]      // its own actions
    public var names: [String: String] // the hub's names of the accessories it mentions, by Homeswift id
    public var lastRun: Date?
    public var capabilities: Set<Capability>
}

public enum PluginAutomationTrigger: Sendable, Equatable {
    case time(PluginAutomationTime)                // at a time or sunrise/sunset ± minutes, on weekdays
    case accessory(accessoryID: String, characteristic: String, value: JSONValue?, minimum: Double?, maximum: Double?)
    case presence(who: String, arriving: Bool)
    case duration(seconds: Int)                    // an end trigger
    case other(String)                             // shown as written
}

public enum PluginAutomationCondition: Sendable, Equatable {
    case time(after: PluginAutomationTime?, before: PluginAutomationTime?)
    case accessory(accessoryID: String, characteristic: String, comparison: String, value: JSONValue)
    case presence(who: String, home: Bool)
    case other(String)
}

public struct PluginAutomationAction: Sendable, Equatable {
    public var accessoryID: String     // Homeswift's id (`Wingman:<id>`)
    public var characteristic: String  // Homeswift's characteristic type name ("Brightness")
    public var value: JSONValue
}

public struct PluginAutomationChange: Sendable, Equatable {
    public var name: String?
    public var enabled: Bool?
    public var time: PluginAutomationTime?
    public var sceneIDs: [String]?
    public var actions: [PluginAutomationAction]?
}

extension HomeswiftPlugin {
    public func automations() async -> [PluginAutomation] { [] }
    public func updateAutomation(id: String, change: PluginAutomationChange) async throws { throw … }
    public func deleteAutomation(id: String) async throws { throw … }
}
```

`PluginHost` gains `pluginAutomations()`, `updateAutomation(platform:name:id:change:)` and
`deleteAutomation(platform:name:id:)`, like the scenes'. Accessories are named by Homeswift's ids and characteristic
types, so the web UI draws a trigger or an action with the accessory's own name and widgets; a Wingman accessory left
out of Homeswift (excluded, or Homeswift's own) shows by the name Wingman gives.

The Wingman plugin maps `/automations` onto it: `trigger` and `endEvents` onto `PluginAutomationTrigger`s,
`conditions` onto `PluginAutomationCondition`, `scenes` onto `sceneIDs`, and the capabilities from `structure`,
`editable` and `unsupported`. `updateAutomation` posts only the endpoints the change needs (`enable`, `rename`, `time`,
`scenes`, `actions`), in that order, and stops at the first refusal.

### MCP and the web UI

- MCP: `list_hub_automations` (read scope) lists them with their source, as `list_scenes` lists hub scenes;
  `update_hub_automation` (write scope; enabling, disabling and renaming are not destructive) and
  `delete_hub_automation` (destructive, through `ToolCall.confirm`). Every write is audited. An action on a lock, a
  garage door or an alarm goes only through `set_security_accessory`'s rule: `update_hub_automation` refuses actions on
  security characteristics and says to make them in the Home app. The existing `update_hub_scene` and
  `delete_hub_scene` cover Apple Home scenes unchanged.
- The web UI's Scenes page gets **Automations from your hubs** below **Scenes from your hubs**: each automation as a
  row with its trigger in words ("At sunset − 15 min, weekdays"), its conditions, what it runs, and a switch for
  enabled. Its ⋯ menu has **Rename…**, **Change the time…** (for a time trigger), **Change what it runs…** (the hub's
  scenes as checkboxes, and its own actions as accessory rows with the widgets' controls), and **Delete from Apple
  Home**. Every edit is an administrator's, and each text goes through `t()` with its French, Spanish and Portuguese.
  docs/ui.md and the Wingman README describe them, and the Scenes page's screenshots are retaken.
- The hub scenes section's text names Apple Home with Hue and IKEA for the ⋯ menu.

### Tests

`FakeWingman` gains rooms with ids on its home, `/scenes` and `/automations` answered from in-memory state, the edit
endpoints applying to it (with `structure`, the owner's setting and `editable` switchable), and `scenes` and
`automations` events. The tests cover: rooms listed and renamed through the host's `renameRoom` with `syncRoomNames`;
scenes listed with their capabilities, run, renamed, updated from lights (other actions kept), created and deleted;
automations listed with each trigger and condition kind, enabled, given a new time and new scenes, and deleted; the cache read again on
events; an older Wingman without `structure` giving none of it; Wingman's `403` reported as the error the UI shows.

## Slices

1. This note.
2. Homeswift: `PluginAutomations` in `HomeswiftPlugin`, and the Wingman plugin's rooms, scenes and automations against
   `FakeWingman`, with tests. Done; it does nothing until a Wingman serves the endpoints.
3. Wingman: the setting, the endpoints, the events and `DemoStore`, with its tests on synthetic data. Built, signed and
   tried against a real home by its owner.
4. Homeswift: the MCP tools and the web UI's automations section, translations, docs and screenshots.
