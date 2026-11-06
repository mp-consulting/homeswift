# The Home Link: implementation plan

Draft. The decisions are in [ADR 0005](adr/0005-apple-home-owns-rooms-zones-and-groups.md) (Apple Home owns the
Rooms, Zones and Groups; the bridge keeps a linked copy) and [ADR 0006](adr/0006-the-bridge-separates-functions.md)
(the bridge separates an accessory's Functions). The words are in [GLOSSARY.md](../GLOSSARY.md): Home, Room, No Room,
Zone, Group, Home Link, Pending Change, Function, Separate Functions.

## Status

Built, on branch `feat/home-link` (homeswift) and `feat/home-link` (homeswift-wingman, phase 3):

| Phase | State |
|---|---|
| 0. Clean the Wingman checkout | Left to a person: the phase 3 work is in its own worktree, the conflicted checkout untouched |
| 1. Spike on a real home | **Half run:** what a real home holds was read (below, "What a real home showed"); the edits (names, the Default Room, deleting a room, groups) wait for a run with **Let bridges edit rooms, scenes and automations** on |
| 2. Unique serials, the bridge by its serial | Done |
| 3. Wingman's `home-link` API | Done (DemoStore and loopback tests; the app builds unsigned). Create edits take a `home` |
| 4. The linked copy | Done: each Room in `accessory-layout.json` has its own id and its Home id; the Zones (by Room id) and Groups are in `home.json` |
| 5. Wingman as the Home Link | Done, but one Wingman per Home is chosen by connection and id, not the TXT `home` hash |
| 6. Rooms over the link, Room Sync retired | Done |
| 7. The first link's comparison | Done: it applies Apple Home's placements with the defaults, no choice per accessory |
| 8. Zones | Done, as a filter of the wall rather than a grouping level of its own |
| 9. Groups | Done: in `home.json` beside the Zones, the wall keeping where each one stands |
| 10. Separate Functions | Done; wall order, Quick Controls and scenes that name a moved Function are not moved with it |
| 11. Release | Paperwork done (both CHANGELOGs, the READMEs, homeswift.dev in four languages; no screenshot shows what changed). The releases themselves, Wingman first, wait to be pushed |

## Goal

One definition of the Rooms, Zones and Groups, shared by Homeswift and the Home app:

- Moving an accessory, grouping accessories, or creating, renaming or deleting a Room, Zone or Group does the same on
  the other side.
- While the Home Link is down, changes are kept as Pending Changes and replayed when it comes back.
- An accessory that does several things can be separated, so it can be grouped.

Out of scope: Matter rooms, the order of Rooms and Zones (it stays the Arrangement), and syncing Hue zones. Other hubs'
rooms only follow renames, as today.

## Where it stands

**Bridge (`homeswift`)**

- **Rooms:** a list of names in `accessory-layout.json` (`AccessoryLayout.rooms`). Each accessory's
  `_accessories.<key>.room` names one. Nothing stores a HomeKit id.
- **Room Sync** (`bridge.roomSync`, legacy `syncRoomNames`) gates `HubRooms.swift`.
  - Bridge → hubs: renames reach every hub's room of the same name, ignoring case and accents. Moves go through
    Wingman only.
  - Home app → bridge: renames and moves arrive as one unordered `Task` each (`PluginHost.swift:668-673`). A rename
    also reports every accessory in the room as moved, so the two race.
  - Creating, deleting and reordering Rooms are never synced, and there is no reconciliation on connect.
- **Wall groups:** stored in `ui-layout.json` as `{id, name, members}`, under Homeswift's own rule (`canGroup`). They
  never reach HomeKit.
- **Matching accessories:** Homeswift's own accessories are found in Apple Home by serial number. eWeLink channels,
  UniFi Protect's package camera and LG ThinQ's `"Unknown"` publish duplicate serials, so those accessories never sync.
- **Finding the bridge:** the bridge is recognised by a manufacturer or model of `"Homeswift"`, which a person can
  override and which matches every Homeswift bridge. Its serial number is its HAP device ID
  (`PluginHost.swift:780`), which is the better anchor.

**Wingman (`homeswift-wingman`, origin/main 0.3.0)**

- **What `/homes` gives:** room ids and names, without the Default Room (accessories in it show its localised name).
  Zones are names only, and there are no service groups.
- **Edits:** `rooms/rename` takes an id. `accessories/room` takes a room name and creates the room when none matches,
  so the Default Room can't be reached.
- **Events:**
  - Nothing fires for zone or service-group changes.
  - Toggling `allowChanges` sends no `settings` event.
  - `structureChanged` coalesces per kind, not per home.
- **Testing:** `HomeStore` isn't compiled in tests. Behaviour is tested through `DemoStore`.
- **Multiple Wingmen:** the Bonjour TXT `home` hash exists so a bridge can keep one Wingman per home, but the bridge
  doesn't use it yet.

## Phases

Each phase is one pull request in one repository. Phases 1 and 2 can start together. After that, the order follows
the dependencies listed with each phase.

### 0. Clean the Wingman checkout (local only)

The local `homeswift-wingman` is a conflicted `git stash pop` of an early App Store draft. origin/main already holds
that work in another form. To clean it:

- run `git reset --merge`, then `git pull --ff-only`;
- the stash `sync-2026-11-01` stays as a backup;
- the untracked `Scripts/app-store.sh.local` and `Scripts/AppStoreExport.plist` are left alone.

A person runs this, since it throws away the conflicted working tree.

### 1. Spike: what HomeKit allows (Wingman, throwaway branch)

This phase is facts only, gathered on a real home with the Home app open, before anything is designed against them:

- **Moving to the Default Room:** does `assignAccessory(_:to: roomForEntireHome())` work, and what does
  `roomForEntireHome().uniqueIdentifier` look like over time?
- **Room and zone names:** do `addRoom` and `addZone` refuse a duplicate name, and is that check case-insensitive?
  Accent-insensitive?
- **Deleting a room:** after `removeRoom`, do its accessories land in the Default Room, and which delegate calls fire?
- **Service groups:**
  - What does `addServiceGroup` with services of different kinds look like in the Home app?
  - A light with a sensor attached?
  - Services of accessories in different rooms?
  - Which `HMHomeDelegate` group callbacks fire for edits made in the Home app?
- **Zones:** whether the Home app shows zones that were made through the API.

The results go in this document and settle the exact Group rule that `canGroup` will enforce.

#### What a real home showed (read only, 2026-11-06)

Read through Wingman's `/homes` on a home of 151 accessories, 143 of them behind a Homeswift bridge:

- **Rooms and the Default Room:** every accessory has a room id, the five in the Default Room included, and the home's
  `defaultRoom` is listed with the 19 rooms, so No Room maps to an id Homeswift can keep.
- **Zones:** both of the home's zones come with ids and their rooms' ids.
- **The bridge:** each of the 143 bridged accessories names its bridge by id, so matching by bridge and serial works.
- **Service groups keep living empty.** Of 40 groups, 39 have no services: their accessories were removed, or added
  again under new ids, and the groups stayed. Several share a name ("Spots Salon" four times), so HomeKit does not keep
  group names unique among empty groups. Two consequences, both built:
  - Homeswift adopts only a group with at least two of its accessories, so empty groups never reach it.
  - Wingman lets a name held only by empty groups be used again (homeswift-wingman `521fced`); it refused it before.
- **The one live group** holds two lights of one kind in one room, which says nothing yet about mixed kinds or rooms.

### 2. Unique serials and a sure way to find the bridge (homeswift)

Unique serials:

- **Where:** the HAP server's `add` and `remove`, which every publish path goes through, give every bridged accessory
  a serial that is unique on its bridge.
- **Who keeps the plain serial:** of the accessories on one server that came with the same serial, the one with the
  lowest aid (the device's own accessory, normally the first added). The others get `-<aid>` after it: aids never
  change for an id, so neither does the suffix. Done: `HAPServer.Options.uniqueSerialNumbers`, on for every bridge.
- **Exceptions:** mirrors are left out, and the serial is a value, so the configuration number does not bump.
- **Test:** a plugin that publishes two accessories with one serial ends up with two distinct serials, stable across
  restarts.

Finding the bridge and matching only its accessories:

- **The bridge itself:** Wingman's `/homes` gains each accessory's bridge `serialNumber`. Wingman's `Structure` finds
  Homeswift's bridge by it (its HAP device ID), and the manufacturer string is no longer used. Until phase 3 ships,
  the manufacturer check stays as the fallback.
- **Its accessories:** serial matches are limited to accessories on that bridge (`onHomeswiftBridge` becomes "on this
  bridge"), or to an external accessory Homeswift publishes itself.

This phase is independent of the rest and fixes the existing room moves on eWeLink, Protect and LG.

### 3. Wingman API for the Home Link (homeswift-wingman)

This phase adds the feature string `home-link` to `/info.features`. Old bridges ignore it, and the existing endpoints
stay. The bridge's Serial Number needs nothing new: `/homes` already lists the bridge accessory itself, with its
Accessory Information, and every bridged accessory's `bridge.id` (phase 2 uses them).

**`/homes` additions** (each home; old bridges ignore unknown keys, so nothing existing changes shape)
- `defaultRoom: {id, name}`: `roomForEntireHome()`, which `rooms` still leaves out.
- Every accessory's `roomID`: its room's `uniqueIdentifier`, or `null` in the Default Room. `room` (the name) stays.
- Every zone gains `id` and `roomIDs: [roomID]`; `name` and `rooms` (names) stay.
- `serviceGroups: [{id, name, services: [serviceID]}]`, the service ids being those `services[].id` already gives.

**New edits** (all `POST`, structural: `allowChanges`, `allowStructure` and an administrator; answers as `StoreAnswer`)

| Path | Body | Answer |
|---|---|---|
| `rooms/create` | `{name}` | `{room: {id, name}, added: Bool}`: a room already named so (case and accents ignored) is answered with `added: false` |
| `rooms/delete` | `{room: id}` | `{room: id}`; its accessories go to the Default Room |
| `accessories/room` | `{accessory: id, roomID: id \| null}` | `{accessory, roomID}`; `null` is the Default Room; the by-name form (`room`) stays |
| `zones/create` | `{name}` | `{zone: {id, name}, added: Bool}` |
| `zones/rename` | `{zone: id, name}` | `{zone: id, name}` |
| `zones/delete` | `{zone: id}` | `{zone: id}` |
| `zones/rooms` | `{zone: id, add: [roomID], remove: [roomID]}` | `{zone: id, roomIDs: [roomID]}` |
| `groups/create` | `{name, services: [serviceID]}` | `{group: {id, name}}` |
| `groups/rename` | `{group: id, name}` | `{group: id, name}` |
| `groups/delete` | `{group: id}` | `{group: id}` |
| `groups/services` | `{group: id, add: [serviceID], remove: [serviceID]}` | `{group: id, services: [serviceID]}` |

An unknown id is 404, a name already taken by another zone or group 422, an empty or over-64-character name 400.

**Events**
- The `HMHomeDelegate` zone and service-group callbacks, and `didUpdateNameFor service`, emit `homes`.
- Toggling `allowChanges` emits `settings`.
- `structureChanged` coalesces per (kind, home), so two homes changing in one second make two events.

**Permissions**
- The new edits are structural: they need `allowChanges` and `allowStructure`, and an administrator.
- `/homes` exposes `editable` per home, as now.

**Tests**
- Every edit works in `DemoStore`, with its refusals and events: in `demoStructure` and, over TLS, in
  `structureRoutes`.
- `DemoStore` gains zones, a Default Room and service groups.

This phase depends on phase 1, for the exact behaviour around the Default Room and service groups.

### 4. The linked copy on the bridge (homeswift)

**The `Home` store**
- **The file:** a new `home.json` beside `accessory-layout.json`, written with `OwnerOnlyFile.write`.
- **What it holds:**
  - the Home's HomeKit id and name;
  - Rooms `{id, homeKitID?, name}`, Zones `{id, homeKitID?, name, rooms}` and Groups `{id, homeKitID?, name, members}`;
  - the Pending Changes, in order, each naming its target by local id;
  - whether the first link's comparison is still waiting.
- **What stays elsewhere:** the order of Rooms and Zones stays in `accessory-layout.json` (Arrangement), and group
  widgets' positions stay in `ui-layout.json`.

**Who writes it:** one actor owns the store. Changes arrive as whole snapshots from the link and are diffed by id,
so a rename never reads as moves, and changes are applied in order. This replaces the per-change `Task`s.

**Migration**
- `AccessoryLayout.rooms` becomes unlinked Rooms, and wall groups become unlinked Groups.
- `syncRoomNames` and `bridge.roomSync` are read once and dropped.
- Both become part of the first link's comparison (phase 7).

**Names**
- Room and Zone names are unique, compared with the same folding Wingman uses (case and accents).
- `_accessories.<key>.room` keeps the name, and a rename rewrites the accessories that name the Room, as
  `writeLayoutRooms` does now.
- "Cafe" and "Café" already in a layout are listed for a person to rename before linking.

**The plugin API**
- A `HomeLinkProvider` protocol in `HomeswiftPlugin` (Wingman implements it):
  - `snapshot()`;
  - `apply(_ change)` → done, refused (with a reason) or unreachable;
  - a stream of snapshots;
  - its state: up, down, or up but not allowed to edit.
- `PluginRooms` (`rooms()`, `renameRoom`) stays for the hubs that only follow renames: Hue, DIRIGERA, eWeLink.

**Tests:** migration, the diff by id (a rename with no moves), and the Pending Change order. Run them against a fake
provider in `HomeswiftMCPTests`.

This phase is independent of phase 3, because it is built against a fake provider.

### 5. Wingman as the Home Link provider (homeswift, Plugins/Wingman)

**Reading the Home**
- The plugin decodes the phase 3 fields and finds the Home by the bridge's serial (phase 2).
- Mirrors are limited to the Home, and the `homes` setting goes away. Schema migration: the setting is read once and
  dropped.

**Links**
- One active link per Home, chosen by the TXT `home` hash and the `/homes` ids. Another Wingman of the Home takes over
  when the active one goes down.
- Echo suppression is keyed by HomeKit id at the Home level, not per link.

**State**
- The link's state is derived from `/info.structure`, the Home's `editable` and the link phase.
- It is shown on the Wingman page and reported to the host.
- An older Wingman without `home-link` counts as down, with "Update Wingman" as the reason.

**Tests:** `FakeWingman` gains a configurable id and home hash, zones, a Default Room, service groups and the new
edits. Two fakes test failover.

This phase depends on phases 2, 3 and 4.

### 6. Rooms over the Home Link, and Room Sync retired (homeswift)

**Rooms and moves**
- Creating, renaming and deleting Rooms, and moving accessories, go through the store. While the link is up, each
  goes to the provider by HomeKit id.
- While it is down, each becomes a Pending Change. While it can't edit, it is refused with the Wingman setting to turn
  on.
- No Room is the Default Room both ways, and Wingman's Default Room never becomes a Room.
- Mirrors and DIRIGERA accessories that follow a `suggestedRoom` are moved like the others. DIRIGERA's non-mirrored
  use of `suggestedRoom` becomes a room setting.
- Hubs keep following Room renames by name (`HubRooms.renameHubRooms`), with no switch.

**Surfaces**
- **Web UI:**
  - The Accessories page's Rooms menu loses "Sync rooms with the hubs" and shows the Home Link state instead.
  - Its settings sheet loses the "Room Sync is on" help.
  - The groups dialog loses "HomeKit rooms stay unchanged".
- **MCP:** `set_accessory_layout` and `get_accessory_layout` lose `syncRoomNames` and gain the link state. Room
  create and delete get their own tool or field.
- **Assistant:** the `chat.md` prompt is updated, then `PromptFiles.swift` is re-embedded.
- **Docs and translations:** docs/ui.md, docs/mcp.md, docs/plugins.md, docs/ai.md and docs/apple-home-design.md;
  the `i18n-*.js` catalogs and `site/design/runtime` copies.

**Tests:** `HubRoomTests`, `AccessorySettingsTests` and `PluginHostTests`' Room Sync cases are rewritten for the
Home Link.

This phase depends on phases 4 and 5.

### 7. The first link's comparison (homeswift)

**What it lists:** when a Home first links while the store holds unlinked Rooms, Groups or placements, the bridge
holds them and lists:
- Rooms and Groups that only exist on one side;
- accessories whose room differs;
- name clashes;
- wall groups that break Apple Home's grouping rules.

**The defaults:**
- Apple Home's placement wins;
- an accessory in No Room in Apple Home takes Homeswift's Room;
- Homeswift-only Rooms are created in Apple Home;
- groups that break the rules are ungrouped.

**Where:** it's shown on the Accessories page and as an MCP tool pair (`get_home_link_comparison`,
`confirm_home_link`). Nothing moves until a person confirms.

This phase depends on phase 6.

### 8. Zones (homeswift)

- **Editing:** Zones are created, renamed and deleted, and Rooms added to or removed from them, through the store,
  the same way as Rooms (phase 6). A Room can be in several Zones.
- **Wall:** the wall gets a grouping by Zone, then Room, and a Zone filter.
- **MCP:** `list_accessories` and `set_accessories` gain a `zone` filter.
- **Scenes:** `run_scene`, the Scenes page and the Assistant gain a Zone scope.
- **Hue:** Hue zones are left alone.

This phase depends on phase 6.

### 9. Groups (homeswift)

**Storage:** Groups move from `ui-layout.json` to the store. `WallLayout` keeps only the group widget's position and
size, and `PUT /api/layout` stops accepting `groups`.

**Grouping rules:** `canGroup` becomes Apple Home's rule:
- members of one kind, each with one Function;
- every member in Apple Home;
- mirrors allowed;
- the details as settled by phase 1.

A refusal says why, and offers Separate Functions once phase 10 ships.

**Writes**
- Grouping, ungrouping, renaming and changing members go to the provider as service groups. On a member's main
  Function service, the change is pending or refused like any other.
- A member made Not in Home or Excluded leaves its Group, and a Group under two members is dissolved on both sides.

**Surfaces**
- `groups.js` and `app.js` (persist, ungroup, drag to join) use a catalog endpoint.
- `set_wall_layout`'s groups go through the store, with its text and schema updated.
- docs/widgets.md, docs/mcp.md and the translations follow.

This phase depends on phases 6 and 7, and on phase 1 for the rule.

### 10. Separate Functions (homeswift)

**The setting:** `separateFunctions` is a Core Accessory Setting. It is per device but applied live, which makes it
the first such key. It is taken out of the plugin's JSON like names (`Configuration.platform(from:)`), and added to
`liveKeys`, `coreAccessoryFields` and the settings editor.

**The transform**
- **Where:** a step in `PluginContext` between the plugin's accessory and `bridge.server.add`, used by every publish
  site (`add`, `restoreCache`, `applyNames`, `remove`, `removeAccessories`, `detach`).
- **What it publishes:**
  - the main accessory: the device's id, keeping its aid, with the main Function (`AccessoryNaming.primaryService`)
    and whatever must stay with it;
  - one accessory per other Function, keyed `<deviceID>:<function>`, the key derived from service type and subtype.
- **Services:** the plugin's `Service` objects are moved, not copied. Their characteristics' handlers and events
  follow, as with plugins that rebuild accessories today.
- **Information, battery and identify:** Accessory Information and Battery are copied onto each accessory and kept in
  step with `Characteristic.observe`. Identify forwards to the original.
- **Cache:** the cache keeps the plugin's own shape, and the transform runs again on restore.
- **Ids:** aids and iids come back on rejoin, because `persisted.aids` and `persisted.iids` are never purged.

**What the plugin declares:** an API on `Accessory` or `PluginContext` saying which Functions stay together.
- Built in: the camera and its RTP, recording, operating mode, data stream, microphone, speaker and the motion or
  occupancy sensors recording links; a doorbell; a television and its inputs and speaker; a ServiceLabel and its
  buttons; a lock mechanism and lock management.
- Filter Maintenance, Eve history and Protocol Information are never Functions.
- Links to a moved service are dropped from the main accessory (`HAPServer.swift:634`).

**Model changes**
- The runtime can build an `Accessory` around a given information service, or update its information.
- The camera controller can be carried onto a rebuilt main accessory (`cameraControllerBox` is internal today).
- `Service.isPrimary` doesn't need to change, since separated accessories have one Function each.

**Where separated accessories show up**
- **Ownership:** separated ids are claimed for the plugin, so `Located.platform`, `Owners` and `settingsTarget` find
  their plugin. Device-level settings (Excluded, Parts, the plugin's own) still go under the device key.
- **Category:** each separated accessory gets one from its Function, with `Mirror.category(of:)` moved to the core.
- **References:** wall order and sizes, Quick Controls, bridge scenes' actions and Group members that name the device's
  id and a moved service are moved to the separated id when separating, and back when joining.
- **Matter:** Matter keeps the joined view. It reads the plugin's own accessory and accepts events from the separated
  ones, so Matter controllers see no change.

**Limits and warnings**
- When separating would push the bridge over `maxBridgedAccessories` (149), it is refused.
- Separating and joining both warn that scenes and automations on the moved Functions need redoing. Joining also lists
  the Groups that will dissolve.
- Mirrors are never separated.

**Where it's offered:** in the accessory's settings, and from a refused grouping.

**Tests**
- A recording plugin's light with a sensor: separated, the sensor's events reach its own aid.
- Joined back, the aids return.
- A camera with recording stays whole.
- References are moved both ways.

This phase depends on phase 2 (serials of separated accessories). It isn't needed by phases 3–9, which ship first
with grouping refusals.

### 11. Release

**Order and compatibility**
- Wingman ships first (its version with `home-link`), then the bridge release.
- A bridge talking to an old Wingman shows "Update Wingman" and keeps working on its copy.

**Paperwork**
- Both CHANGELOGs.
- README and homeswift.dev in the four languages.
- Retaken screenshots: docs/ui.md, docs/widgets.md, and the Wingman README.

## Open facts

Phase 1 settles these:

- The Home app's exact grouping rule: which kinds group together, whether members can be in different rooms, and what
  an API-made group that breaks the rule looks like.
- Whether HomeKit's own name uniqueness folds case and accents the way Homeswift will.
- What happens to service groups when a member accessory moves to another bridge. (When it is removed, the group stays,
  empty: see phase 1's results.)
