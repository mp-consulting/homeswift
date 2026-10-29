# Unified scenes

One concept, the scene, in place of moods, Homeswift scenes and the scenes plugins keep on their hubs. This note
is the design agreed before the work started; each slice below lands on its own and leaves the bridge working.

## Model

- **Sources.** Homeswift scenes live in `scenes.json`. Plugin scenes come from a provider API: a plugin lists its
  hub's scenes with a stable id `<platform>:<instance>:<native id>`, a name, the room or zone its hub reports, and
  what it can do with each (`recall`, `rename`, `update`, `create`, `delete`, `animate`).
- **Source of truth.** The hub keeps its own scenes; Homeswift keeps no copy. Writes go through and are read
  back; the last write wins.
- **Triggers.** Only Homeswift scenes have triggers and conditions. A plugin scene is automated by a Homeswift
  scene with a plugin-scene action (the "Automate" button makes one). An action whose plugin scene went away is
  kept, skipped at run time, and reported in `lastSkipped`.
- **Lights.** A scene made for a room (from a template, by the Assistant) lists its lights when it is made; the
  editor offers to add the room's new lights.
- **Rooms.** A plugin scene sits in the Homeswift room of the same name as its hub's room or zone, else in
  "Other".
- **Active.** A plugin scene is active when its hub says so (Hue does, DIRIGERA does not); a static Homeswift
  scene while every value matches; an animated one while it plays.
- **Artwork.** The core keeps every scene's artwork, plugin scenes' included (by plugin scene id), in
  `scene-pictures/`; a plugin's page reads and writes the same pictures through `context.scenePictures()`, and the
  plugins' own `scene-pictures` are moved there once.

## Animation

A scene may animate. Its animation is an effect configuration: a style — candle, fire, sparkle, prism, opal,
glisten, underwater, cosmos, sunbeam, enchant, palette, sunrise, sunset, music — with an optional colour or white,
speed and brightness, and optional overrides for a provider (an exact Hue effect, a Govee scene code). Two kinds:

- `effect`: each provider plays its own lights natively; the lights no provider plays go to Homeswift's player.
- `sequence` (siren, lightning, alerts, a wave): timed across lights, always played by Homeswift's player.

| Lights | Native |
|---|---|
| Philips Hue | `effects_v2` with colour and speed; `timed_effects` sunrise and sunset; a palette moves natively only in a scene saved to the bridge (`dynamic_palette` and `speed`), else the player plays it. Homeswift makes no hidden bridge scenes |
| Govee | The model's library scene of the style's name (a curated table: fire → "Fire", candle → "Candlelight"…); speed ignored until its encoding is verified |
| IKEA DIRIGERA | Sunrise and sunset as one long fade; no effects |
| Philips Ambilight TV | Music through its FOLLOW_AUDIO modes |
| eWeLink | Its own modes, later, ported from homebridge-ewelink |
| Others | Homeswift's player; music stays static |

Brands are not kept in step. Stopping tells each provider to stop its effect, then puts the lights back.

## Running and undo

Every run — static, animated, a plugin scene recalled, by hand or by an automation — can be undone for 12 hours:
the lights go back to how they were. A light has one undo: the next scene that changes it takes it over.

## Scenes composed on the fly

The AI composes a scene and runs it without saving it, as moods did:

- `run_scene` takes a saved `scene`, or a `plan` (an inline scene: values per light, a native effect, hub scenes to
  recall, mixed), or a `description` and a `room` that the bridge's Assistant turns into a plan. An MCP client, an AI
  itself, writes the plan; the web UI and its chat may describe it instead.
- It runs at once with the same 12-hour undo, nothing saved; the answer has the plan it ran and the run.
- `save_scene` takes that `plan` and a name to keep it (to the hub too, once write-back exists).
- The web UI has a "Describe a scene" box on the Scenes page and in each room, with Undo and Save after it runs.

## Writing to hubs

- A hub scene can be updated from the lights as they are, or light by light within what its hub keeps; triggers,
  other accessories and security controls are refused there.
- Saving a new scene offers "Save to Hue bridge" or "Save to IKEA hub" when all its lights are on that hub and it
  fits; Homeswift is the default.
- Deleting on the hub is confirmed and audited; renaming and updating are audited.

## Surfaces

- **Home page:** a strip of scenes per room (Homeswift's and the plugins'), then "From template".
- **Scenes page:** every scene by room, filtered by source.
- **Templates:** the mood collection and the gallery become templates applied to a room, artwork included.
- **The Assistant:** writes a draft scene from a description, previewed (with undo), saved when confirmed;
  `save_scene` takes a `description`.
- **HomeKit:** a Homeswift scene can be a switch, chosen per scene, on one "Homeswift Scenes" accessory; the
  plugins' scene switches stay as they are.
- **Govee** provides the scenes picked on its page; the library stays a place to pick from.
- **Removed:** `list_moods`, `start_mood`, `stop_mood`, `/api/moods/*`, `held-moods.json`, `design-mood.md`;
  `stop_scene` and `undo_scene` are added.

## Slices

1. The provider API; Hue, DIRIGERA and Govee recall; the one list, the room strip, active state, core artwork.
2. Undo and stop for every run; `plan` on `run_scene` and `save_scene`.
3. Animated scenes: styles, native providers (Hue, Govee, IKEA fades, Ambilight), the player as fallback.
4. Templates; the Assistant writes scenes (`description`).
5. Moods removed (`feat!`), with docs, translations and screenshots; each room's scenes above the templates.
6. Hue and DIRIGERA write-back (DIRIGERA's from lpgera/dirigera, noted in THIRD-PARTY-NOTICES.md).
7. eWeLink's own modes.
