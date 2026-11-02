// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Philips Hue page on the UI's materials: the bridge (or the card leading to its Setup), the lights as the Accessories page's
   widgets, the scenes of each room as tiles painted with their palette, and the settings. The bridge card, tabs,
   scene tiles, speed scale and save bar are style.css's, shared with the DIRIGERA page. */

.page-head { align-items: center; }
h2 { margin: 0 0 10px; }
.intro { margin: 0 0 14px; font-size: 0.875rem; }

/* The finder over the lights, sensors and scenes is style.css's (plugin.js `finder`); a folded room hides its tiles. */
.room.folded .scene-tiles { display: none; }
.scene .kind { position: relative; z-index: 1; font-size: 0.75rem; opacity: 0.85; }

/* An active scene's play button, at the tile's centre; lit while the scene plays. */
.scene .play { position: absolute; left: 50%; top: 50%; translate: -50% -50%; z-index: 2; width: 44px; height: 44px; min-height: 0; padding: 0; border-radius: 50%; display: grid; place-items: center; background: rgba(0, 0, 0, 0.32); border: 0; color: #fff; box-shadow: none; }
.scene .play svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.scene .play.on { background: rgba(255, 255, 255, 0.9); color: #1d1d1f; }
.scene.light:not(.pictured) .play { background: rgba(255, 255, 255, 0.55); color: #1d1d1f; }
.scene.light:not(.pictured) .play.on { background: #1d1d1f; color: #fff; }

/* A scene with Autoplay: a loop at its tile's bottom right. */
.scene .loop { position: absolute; right: 10px; bottom: 10px; z-index: 1; width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; background: rgba(0, 0, 0, 0.32); color: #fff; }
.scene .loop svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.scene.light:not(.pictured) .loop { background: rgba(255, 255, 255, 0.55); color: #1d1d1f; }
.scene:has(.loop) .name { padding-right: 28px; }

/* A scene's speed dialog: whether it follows the Settings speed, under the scale. */
.scene-speed-note { margin: 10px 0 14px; font-size: 0.875rem; }

/* Lights as the Accessories page draws them; the ones left out of the Home app below, to bring back. */
.accessory-walls { margin: 0; }

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Hue page: the bridge (set up on Add accessories: this page leads there), the lights
// as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the sensors and
// switches the same way (motion, temperature, light level, contact, battery, a button's presses), the scenes of
// each room as tiles painted with their palette (a tap recalls one, a tap on the active one switches its room off,
// play makes its colours move, its ⋯ menu leaves it out of the Home app), and the settings: the transition and what
// the Home app shows. Refreshed every two seconds while visible; saving writes this instance's block. The Setup
// card, tabs, scene pictures, speed scale and tile text come from plugin.js.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, tile, fact, explain, request, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
  let sensors = [];
  let groups = [];
  let block = {};

  homeswift.tabs("hue-tab");

  // MARK: The bridge

  /// The bridge: until it is set up, the card that leads to its Setup on Add accessories (the page pairs nowhere else);
  /// once it is, its address, state and counts, Pair again in its ⋯ menu, and Explain when it does not answer.
  function drawBridge() {
    const card = $("#bridge");
    // Nothing until the plugin has answered whether the bridge is paired.
    if (typeof status.paired !== "boolean") return;
    const key = JSON.stringify([status.paired, status.host, status.bridgeID, status.error, status.lights, status.sensors, status.scenes]);
    if (card.dataset.json === key) return;
    card.dataset.json = key;
    if (!status.paired) {
      card.replaceChildren(homeswift.setupCard({
        title: t("Set up the Hue Bridge"),
        text: t("Add accessories finds the bridge on the network, or asks for its address, then for a press on its link button. The key stays in the vault, not in config.json."),
        glyph: "bridge", tone: "violet",
      }));
      return;
    }
    const name = t("Hue Bridge");
    const [state, kind] = status.error ? [t("Not responding"), "away"] : [t("Connected"), "on"];
    card.replaceChildren(el("section", { class: "card bridge-card" }, el("div", { class: "bridge" },
      el("div", { class: "server-head" },
        tile("bridge", status.error ? "grey" : "violet"),
        el("div", { class: "who" }, el("strong", { text: name }),
          el("div", { class: "muted", text: [status.host, status.bridgeID?.toUpperCase()].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: [name, status.host].filter(Boolean).join(" ") }),
          () => [{ label: t("Pair again"), icon: "pair", href: homeswift.setupAddress({ start: true }) }])),
      el("div", { class: "facts" }, ...[[t("Address"), status.host], [t("Lights"), status.lights ?? 0], [t("Sensors"), status.sensors ?? 0], [t("Scenes"), status.scenes ?? 0]]
        .map(([label, value]) => fact(label, String(value ?? "")))),
      status.error ? explain({
        error: `The Hue Bridge at ${status.host} did not answer: ${status.error}`,
        context: "The Homeswift Philips Hue plugin reads every resource of the bridge's local API v2 (GET https://<bridge>/clip/v2/resource) every two seconds with its application key.",
        device: { host: status.host },
      }) : null)));
  }

  // MARK: Lights, as the Accessories page draws them

  /// The plugin's lights and its sensors (not its scene switches), read again when the set of either changes.
  let accessories = [];
  let sensorAccessories = [];
  let shapeKey = "";
  async function loadAccessories() {
    const all = (await homeswift.api("/api/accessories")).filter((accessory) => accessory.platform === "PhilipsHue" && accessory.platformName === homeswift.name);
    accessories = all.filter((accessory) => !accessory.id.startsWith("PhilipsHue:scenes:") && !accessory.id.startsWith("PhilipsHue:device:"));
    sensorAccessories = all.filter((accessory) => accessory.id.startsWith("PhilipsHue:device:"));
  }

  /// Reads the accessories again when the lights or sensors the plugin has published change (the plugin says which
  /// are), once for the Lights and Sensors tabs together.
  let loading = null;
  async function loadIfChanged() {
    const key = [...lights, ...sensors].filter((item) => item.published).map((item) => item.id).sort().join(",");
    if (key !== shapeKey) {
      shapeKey = key;
      loading = loadAccessories().catch(() => {});
    }
    await loading;
  }

  /// The lights left out of the Home app, as buttons that bring one back; drawn again only when they change.
  function drawHidden(names) {
    homeswift.drawHidden($("#hidden-devices"), names, (name) => toggleList("excludeLights", name));
  }

  // The lights' finder, over the plugin's widgets: each light with its room from the bridge.
  const lightFinder = homeswift.finder({
    roomPill,
    toolbar: $("#light-toolbar"), placeholder: t("Search lights"), prefix: "l", foldKey: "hue-folded-light-rooms", draw: () => drawLights(),
    items: () => accessories.map((accessory) => {
      const light = lights.find((entry) => `PhilipsHue:${entry.id}` === accessory.id);
      return { id: accessory.id, name: accessory.name, room: light?.room ?? null, roomID: light?.roomID ?? null, light: light ?? {} };
    }),
    filters: [
      // The bridge keeps a light it cannot reach on: only one that answers is on now.
      ["on", t("On now"), "bulb", (item) => item.light.on === true && item.light.reachable !== false],
      ["colour", t("Colour lights"), "sparkle", (item) => item.light.kind === "colour"],
      ["effects", t("With effects"), "star", (item) => (item.light.effects?.length ?? 0) > 0],
      ["unreachable", t("No Response"), "warning", (item) => item.light.reachable === false],
    ],
  });

  let listening = false;
  async function drawLights() {
    const list = $("#lights");
    lightFinder.show(status.paired && accessories.length > 0);
    if (!status.paired) {
      showEmpty(list, t("Pair with the bridge to see its lights."));
      drawHidden([]);
      return;
    }
    await loadIfChanged();
    if (!accessories.length) {
      showEmpty(list, t("The bridge has no lights yet: add them in the Hue app."));
    } else {
      lightFinder.show(true);
      // A widget per accessory, drawn once in its room's wall: its values follow the bridge's event stream. A light
      // that is on or off is not a new widget: only what the finder sorts by goes in its key.
      lightFinder.draw(list, {
        countText: (shown, total) => t("{shown} of {total} lights", { shown, total }),
        emptyText: t("No light matches the search and filters."), bodyClass: "wall",
        render: (body, items) => renderKeyed(body, items.map((item) => ({ id: item.id, name: item.name, services: accessories.find((accessory) => accessory.id === item.id)?.services.length })), (item) => item.id,
          (item) => HomeswiftWidgets.card(accessories.find((accessory) => accessory.id === item.id), { size: "large", actions: actionsFor })),
      });
      if (!listening) { HomeswiftWidgets.listen(); listening = true; }
    }
    drawHidden(lights.filter((item) => item.hidden).map((item) => item.name));
  }

  /// A widget's ⋯ menu, after All controls: Identify (a light blinks, a sensor's LED flashes), leaving it out of the
  /// Home app (by name, in `listKey`), its log. `prefix` is its accessory id's, `items()` the list it is in.
  const menuFor = (prefix, items, listKey) => (accessory) => {
    const id = accessory.id.slice(prefix.length);
    const item = items().find((entry) => entry.id === id);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { id } }).catch((e) => HomeswiftCommon.showAlert(e.message)) },
      item ? { label: t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList(listKey, item.name) } : null,
      { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessory.id)}` },
    ].filter(Boolean);
  };
  const actionsFor = menuFor("PhilipsHue:", () => lights, "excludeLights");

  /// A list's one line when it has nothing to show.
  const showEmpty = (list, text) => list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text })));

  // MARK: Sensors and switches, as the Accessories page draws them

  // No room pill here: whether a room's lights are on says nothing about its sensors.
  const sensorFinder = homeswift.finder({
    toolbar: $("#sensor-toolbar"), placeholder: t("Search sensors"), prefix: "s", foldKey: "hue-folded-sensor-rooms", draw: () => drawSensors(),
    items: () => sensorAccessories.map((accessory) => {
      const sensor = sensors.find((entry) => `PhilipsHue:device:${entry.id}` === accessory.id);
      return { id: accessory.id, name: accessory.name, room: sensor?.room ?? null, roomID: sensor?.roomID ?? null, sensor: sensor ?? {} };
    }),
    filters: [
      ["motion", t("Motion sensors"), "sensor", (item) => item.sensor.kind === "motion"],
      ["switches", t("Switches"), "switch", (item) => item.sensor.kind === "switch"],
      ["battery", t("Low battery"), "warning", (item) => item.sensor.lowBattery === true],
      ["unreachable", t("No Response"), "warning", (item) => item.sensor.reachable === false],
    ],
  });

  async function drawSensors() {
    const list = $("#sensors");
    const empty = (text) => showEmpty(list, text);
    sensorFinder.show(status.paired && status.sensorsOn !== false && sensorAccessories.length > 0);
    homeswift.drawHidden($("#hidden-sensors"), sensors.filter((item) => item.hidden).map((item) => item.name), (name) => toggleList("excludeSensors", name));
    if (!status.paired) return empty(t("Pair with the bridge to see its sensors and switches."));
    if (status.sensorsOn === false) return empty(t("Sensors and switches are off: turn them on in Settings."));
    await loadIfChanged();
    if (!sensorAccessories.length) return empty(t("The bridge has no sensors or switches yet: add them in the Hue app."));
    sensorFinder.show(true);
    sensorFinder.draw(list, {
      countText: (shown, total) => t("{shown} of {total} sensors", { shown, total }),
      emptyText: t("No sensor matches the search and filters."), bodyClass: "wall",
      render: (body, items) => renderKeyed(body, items.map((item) => ({ id: item.id, name: item.name })), (item) => item.id,
        (item) => HomeswiftWidgets.card(sensorAccessories.find((accessory) => accessory.id === item.id), { actions: sensorActions })),
    });
    if (!listening) { HomeswiftWidgets.listen(); listening = true; }
  }

  const sensorActions = menuFor("PhilipsHue:device:", () => sensors, "excludeSensors");

  // MARK: Scenes

  // A scene's picture: dropped on its tile or chosen from its menu (plugin.js); its ⋯ menu also leaves it out of the
  // Home app, by "<room>/<scene>".
  const pictures = homeswift.scenePictures({
    gallery: true,
    refresh: () => refresh(), toggleHidden: (key) => toggleList("excludeScenes", key),
    // A smart scene follows the time of day: the bridge takes no transition or Autoplay for it. Autoplay is the
    // scene's own on the bridge, as the Hue app's: it plays whenever it is recalled, here, in the Home app or there.
    more: (scene) => scene.smart ? [] : [
      { label: t("Speed…"), icon: "sliders", onSelect: () => sceneSpeed(scene) },
      scene.palette ? autoplayItem(scene) : null,
    ].filter(Boolean),
  });

  /// The menu's Autoplay switch: it flips in place, the menu staying open, once the bridge has it.
  function autoplayItem(scene) {
    let on = scene.autoplay;
    return {
      label: t("Autoplay"), icon: "loop", toggle: true, checkbox: true, checked: on, keepOpen: true,
      onSelect: async () => {
        try {
          await request("autoplay", { method: "POST", body: { id: scene.id, on: !on } });
          on = !on;
          refresh();
        } catch (e) { HomeswiftCommon.showAlert(e.message); }
        return on;
      },
    };
  }

  /// A scene's own transition, kept in the block's `sceneTransitions` by "<room>/<scene>": the speed scale of the
  /// Settings tab, showing the scene's or else the Settings tab's. Saved at the Settings speed (or Use the default), the
  /// scene has none of its own and follows the Settings speed when it changes.
  function sceneSpeed(scene) {
    const key = `${scene.room}/${scene.name}`;
    // The Settings speed as its tab shows it, saved or not; the line under the scale says whether the scene follows it.
    const global = speed.value();
    const settingsText = speed.element.querySelector("output").textContent;
    const note = el("p", { class: "muted scene-speed-note" });
    const scale = homeswift.speedScale({
      help: t("How fast the lights reach this scene. Without a speed of its own, a scene takes the one in Settings."),
      onInput: () => showNote(),
    });
    const showNote = () => {
      note.textContent = scale.value() === global ? t("Follows the Settings speed ({speed}).", { speed: settingsText })
        : t("A speed of its own; Settings has {speed}.", { speed: settingsText });
    };
    scale.set(scene.transitionMs ?? global);
    showNote();
    const write = (ms) => updateBlock((draft) => {
      const list = (draft.sceneTransitions || []).filter((entry) => String(entry.scene).toLowerCase() !== key.toLowerCase());
      if (ms != null) list.push({ scene: key, transitionMs: ms });
      if (list.length) draft.sceneTransitions = list; else delete draft.sceneTransitions;
    });
    const cancel = el("button", { type: "button", actionIcon: "close", text: t("Cancel"), onclick: () => dialog.close() });
    const reset = scene.transitionMs == null ? null : el("button", { type: "button", actionIcon: "restore", text: t("Use the default"),
      onclick: (event) => act(event.currentTarget, async () => { await write(null); dialog.close(); setTimeout(refresh, 1500); }) });
    const save = el("button", { type: "button", class: "primary", actionIcon: "check", text: t("Save"),
      onclick: (event) => act(event.currentTarget, async () => {
        const ms = scale.value() === global ? null : scale.value();
        // Nothing to write when the scene keeps what it had (no restart of the plugin).
        if (ms !== (scene.transitionMs ?? null)) { await write(ms); setTimeout(refresh, 1500); }
        dialog.close();
      }) });
    const dialog = el("dialog", { class: "admin-dialog card", "aria-labelledby": "scene-speed-title" },
      el("h2", { id: "scene-speed-title", text: t("Speed of {name}", { name: scene.name }) }),
      scale.element, note,
      el("div", { class: "actions" }, reset, cancel, save));
    dialog.addEventListener("close", () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
  }

  function sceneTile(scene) {
    const colours = scene.colours?.length ? scene.colours : ["#8e8e93"];
    const background = colours.length === 1 ? colours[0] : `linear-gradient(135deg, ${colours.join(", ")})`;
    const button = el("div", {
      class: `scene ${scene.active ? "active" : ""} ${scene.hidden ? "hidden-scene" : ""} ${homeswift.textStyle(colours)}`, role: "button", tabindex: 0, style: `background: ${background}`,
      // A toggle, as the scene's switch in the Home app: pressed while the scene is on.
      "aria-label": scene.name, "aria-pressed": String(scene.active),
    },
      scene.active ? el("span", { class: "badge", text: t("Active") }) : null,
      // Autoplay on: the scene plays whenever it is recalled.
      scene.autoplay && scene.palette && !scene.smart ? el("span", { class: "loop", role: "img", "aria-label": t("Autoplay is on"), title: t("Autoplay is on") }, icon("loop")) : null,
      el("span", { class: "name", text: scene.name }),
      scene.showRoom ? el("span", { class: "kind", text: scene.room }) : null,
      // A smart scene says so, unless its name already does.
      scene.smart && !/natural light/i.test(scene.name) ? el("span", { class: "kind", text: t("Natural light") }) : null);
    const send = async (path, body) => {
      button.classList.add("busy");
      try { await request(path, { method: "POST", body }); await refresh(); } catch (e) { HomeswiftCommon.showAlert(e.message); } finally { button.classList.remove("busy"); }
    };
    const recall = (dynamic) => send("recall", { id: scene.id, dynamic });
    // A tap recalls the scene; on an active one, it switches the room off, as the Home app's switch does.
    const toggle = () => (scene.active ? send("scene-off", { id: scene.id }) : recall());
    button.addEventListener("click", toggle);
    button.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(); } });
    // Once the scene is on, play, as the Hue app's button: its colours move until it is paused (recalled still). A
    // smart scene follows the time of day, and one without a palette has no colours to move: neither plays.
    if (scene.active && !scene.smart && scene.palette) {
      const play = el("button", {
        class: `play ${scene.playing ? "on" : ""}`, "aria-label": scene.playing ? t("Pause {name}", { name: scene.name }) : t("Play {name}", { name: scene.name }),
        "aria-pressed": String(scene.playing), onclick: (event) => { event.stopPropagation(); recall(!scene.playing); },
      }, icon(scene.playing ? "pause" : "play"));
      play.addEventListener("keydown", (event) => event.stopPropagation());
      button.append(play);
    }
    return pictures.decorate(button, scene, `${scene.room}/${scene.name}`);
  }

  // MARK: Finding a light or a scene

  /// The room or zone's pill, as the bridge has it: on or off.
  function roomPill(id) {
    const group = groups.find((entry) => entry.id === id);
    if (!group) return null;
    return el("span", { class: `pill status ${group.on ? "on" : "standby"}`, text: group.kind === "zone" ? (group.on ? t("Zone on") : t("Zone off")) : (group.on ? t("Room on") : t("Room off")) });
  }

  // The scenes' finder: Colour scenes leaves out the whites of Hue's standard scenes.
  const sceneFinder = homeswift.finder({ roomPill,
    toolbar: $("#scene-toolbar"), placeholder: t("Search scenes"), items: () => groups.flatMap((group) => group.scenes.map((scene) => ({ ...scene, room: group.name, roomID: group.id }))),
    foldKey: "hue-folded-rooms", draw: () => drawScenes(),
    filters: [
      ["on", t("On now"), "bulb", (scene) => scene.active],
      ["autoplay", t("Autoplay"), "loop", (scene) => scene.autoplay && scene.palette && !scene.smart],
      ["colour", t("Colour scenes"), "sparkle", (scene) => scene.colourful],
      ["picture", t("With a picture"), "image", (scene) => pictures.hasPicture(scene)],
      ["hidden", t("Not in the Home app"), "eye", (scene) => scene.hidden],
    ],
  });

  /// The scenes as the toolbar asks; a tile is drawn again only when its own scene changes, so a recall does not
  /// repaint every picture.
  function drawScenes() {
    const list = $("#scenes");
    sceneFinder.show(status.paired && groups.length);
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its scenes.") })));
      return;
    }
    if (!groups.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No scenes yet: make some in the Hue app.") })));
      return;
    }
    sceneFinder.draw(list, {
      countText: (shown, total) => t("{shown} of {total} scenes", { shown, total }),
      emptyText: t("No scene matches the search and filters."), bodyClass: "scene-tiles",
      render: (body, scenes) => renderKeyed(body, scenes, (scene) => scene.id, sceneTile),
    });
  }

  // MARK: Settings

  const toggles = [
    ["scenes", true, t("Scenes"), t("A switch for each scene, on one accessory per room or zone. Off switches the room off.")],
    ["roomLights", false, t("Room lights"), t("A lightbulb for each room and zone: on, off and brightness for all its lights at once, in one command, as the Hue app's room controls. Worth it once the Hue Bridge is no longer in the Home app.")],
    ["dynamicScenes", false, t("Play scenes dynamically"), t("Recall scenes with their colours slowly moving, as the Hue app's play button does.")],
    ["effects", true, t("Effects"), t("A switch for each effect a light has: candle, fireplace, sparkle, prism…")],
    ["flashSwitch", false, t("Flash switch"), t("A switch on each light that makes it flash for five seconds.")],
    ["gradientPoints", false, t("Gradient points"), t("On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.")],
    ["sensors", true, t("Sensors and switches"), t("Motion, temperature, light level and contact sensors, and a programmable switch for each button of a dimmer, Tap or smart button. Presses reach the Home app at once, through the bridge's event stream.")],
  ];
  /// The toggles' checkboxes, by key.
  const toggleInputs = new Map();

  let dirty = false;
  const markDirty = () => { dirty = true; $("#save-state").textContent = t("Unsaved changes."); };

  const speed = homeswift.speedScale({
    help: t("How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for animated scenes and flashes."),
    onInput: markDirty,
  });
  const polling = el("input", { type: "number", id: "pollingInterval", min: 1, max: 300, step: 1, placeholder: "2", inputmode: "numeric" });

  function buildSettings() {
    polling.addEventListener("input", markDirty);
    $("#speed").append(speed.element,
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Polling interval (s)") }), polling,
        el("span", { class: "help", text: t("How often the bridge is asked for changes made in the Hue app or with a switch.") })));
    $("#options").append(...toggles.map(([id, , label, help]) => {
      const input = el("input", { type: "checkbox", id: `option-${id}` });
      input.addEventListener("change", markDirty);
      toggleInputs.set(id, input);
      return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
        el("span", {}, el("span", { class: "field-title", text: label }), el("span", { class: "help", text: help })));
    }));
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    speed.set(block.transitionMs);
    $("#save-state").textContent = t("Changes are kept once you save.");
    polling.value = block.pollingInterval ?? "";
    for (const [id, fallback] of toggles) toggleInputs.get(id).checked = block[id] ?? fallback;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", speed.value(), 100);
      const seconds = parseInt(polling.value, 10);
      setKey(draft, "pollingInterval", Number.isNaN(seconds) ? undefined : Math.min(Math.max(seconds, 1), 300), 2);
      for (const [id, fallback] of toggles) setKey(draft, id, toggleInputs.get(id).checked, fallback);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

  /// Adds or removes a name from one of the block's lists (`excludeLights`, `excludeSensors`, `excludeScenes`), saved at once.
  async function toggleList(key, name) {
    const written = await homeswift.toggleList(key, name);
    if (!written) return;
    block = written;
    setTimeout(refresh, 1500);
  }

  // MARK: Refresh

  /// The status and the lists together; the lists count only once the bridge is paired.
  async function refresh() {
    const settle = (promise) => promise.then((value) => ({ value }), (error) => ({ error }));
    try {
      const [answer, lightList, sensorList, sceneList] = await Promise.all([request("status"), settle(request("lights")), settle(request("sensors")), settle(request("scenes"))]);
      if (answer.paired) {
        const failed = lightList.error ?? sensorList.error ?? sceneList.error;
        if (failed) throw failed;
        ({ lights } = lightList.value);
        ({ sensors } = sensorList.value);
        ({ groups } = sceneList.value);
      } else {
        lights = [];
        sensors = [];
        groups = [];
      }
      status = answer;
    } catch (e) {
      status = { error: e.message };
    }
    // Nothing redrawn when the bridge's answer is the same as the last one (the page polls every two seconds).
    const shown = JSON.stringify([status, lights, sensors, groups]);
    if (shown === lastShown) return;
    lastShown = shown;
    drawBridge();
    drawLights();
    drawSensors();
    drawScenes();
  }

  let lastShown = null;
  buildSettings();
  readBlock().then((value) => { block = value || {}; fillSettings(); }).catch(() => {});
  poll(refresh, 2000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Hue page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Sensors": "Capteurs",
    "Search sensors": "Rechercher des capteurs",
    "Motion sensors": "Capteurs de mouvement",
    "Low battery": "Batterie faible",
    "Pair with the bridge to see its sensors and switches.": "Jumelez le pont pour voir ses capteurs et interrupteurs.",
    "Sensors and switches are off: turn them on in Settings.": "Les capteurs et interrupteurs sont désactivés : activez-les dans les Réglages.",
    "The bridge has no sensors or switches yet: add them in the Hue app.": "Le pont n'a pas encore de capteurs ni d'interrupteurs : ajoutez-les dans l'app Hue.",
    "{shown} of {total} sensors": "{shown} capteurs sur {total}",
    "No sensor matches the search and filters.": "Aucun capteur ne correspond à la recherche et aux filtres.",
    "Sensors and switches": "Capteurs et interrupteurs",
    "Motion, temperature, light level and contact sensors, and a programmable switch for each button of a dimmer, Tap or smart button. Presses reach the Home app at once, through the bridge's event stream.": "Les capteurs de mouvement, de température, de luminosité et d'ouverture, et un interrupteur programmable pour chaque bouton d'un variateur, d'un Tap ou d'un bouton connecté. Les appuis arrivent aussitôt dans l'app Maison, par le flux d'événements du pont.",
    "Search lights": "Rechercher des lampes",
    "Colour lights": "Lampes couleur",
    "With effects": "Avec des effets",
    "{shown} of {total} lights": "{shown} lampes sur {total}",
    "No light matches the search and filters.": "Aucune lampe ne correspond à la recherche et aux filtres.",
    "Search scenes": "Rechercher des scènes",
    "On now": "Allumées",
    "Colour scenes": "Scènes en couleur",
    "With a picture": "Avec une image",
    "Not in the Home app": "Pas dans l'app Maison",
    "{shown} of {total} scenes": "{shown} scènes sur {total}",
    "{n} scene": "{n} scène",
    "{n} scenes": "{n} scènes",
    "No scene matches the search and filters.": "Aucune scène ne correspond à la recherche et aux filtres.",
    "Autoplay is on": "Lecture auto activée",
    "Autoplay": "Lecture auto",
    "Follows the Settings speed ({speed}).": "Suit la vitesse des Réglages ({speed}).",
    "A speed of its own; Settings has {speed}.": "Une vitesse propre ; les Réglages ont {speed}.",
    "Speed…": "Vitesse…",
    "Speed of {name}": "Vitesse de {name}",
    "Use the default": "Utiliser celle par défaut",
    "How fast the lights reach this scene. Without a speed of its own, a scene takes the one in Settings.": "La vitesse à laquelle les lampes atteignent cette scène. Sans vitesse propre, une scène prend celle des Réglages.",
    "Play {name}": "Lire {name}",
    "Pause {name}": "Mettre {name} en pause",
    "Connected": "Connecté",
    "Lights": "Lampes",
    "Hue Bridge": "Pont Hue",
    "Set up the Hue Bridge": "Configurer le pont Hue",
    "Add accessories finds the bridge on the network, or asks for its address, then for a press on its link button. The key stays in the vault, not in config.json.": "Ajouter des accessoires trouve le pont sur le réseau, ou demande son adresse, puis un appui sur son bouton de liaison. La clé reste dans le coffre, pas dans config.json.",
    "Effects": "Effets",
    "Flash": "Clignoter",
    "Pair with the bridge to see its lights.": "Jumelez le pont pour voir ses lampes.",
    "The bridge has no lights yet: add them in the Hue app.": "Le pont n'a pas encore de lampes : ajoutez-les dans l'app Hue.",
    "Active": "Active",
    "Natural light": "Lumière naturelle",
    "Pair with the bridge to see its scenes.": "Jumelez le pont pour voir ses scènes.",
    "No scenes yet: make some in the Hue app.": "Pas encore de scènes : créez-en dans l'app Hue.",
    "Zone on": "Zone allumée",
    "Zone off": "Zone éteinte",
    "Room on": "Pièce allumée",
    "Room off": "Pièce éteinte",
    "A switch for each scene, on one accessory per room or zone. Off switches the room off.": "Un interrupteur par scène, sur un accessoire par pièce ou zone. L'éteindre éteint la pièce.",
    "Play scenes dynamically": "Scènes dynamiques",
    "Recall scenes with their colours slowly moving, as the Hue app's play button does.": "Rappelle les scènes avec leurs couleurs qui évoluent lentement, comme le bouton lecture de l'app Hue.",
    "A switch for each effect a light has: candle, fireplace, sparkle, prism…": "Un interrupteur pour chaque effet d'une lampe : bougie, cheminée, scintillement, prisme…",
    "Room lights": "Lampes de la pièce",
    "A lightbulb for each room and zone: on, off and brightness for all its lights at once, in one command, as the Hue app's room controls. Worth it once the Hue Bridge is no longer in the Home app.": "Une ampoule pour chaque pièce et zone : allumer, éteindre et régler la luminosité de toutes ses lampes à la fois, en une commande, comme les commandes de pièce de l'app Hue. Utile une fois le pont Hue retiré de l'app Maison.",
    "Flash switch": "Interrupteur Clignoter",
    "A switch on each light that makes it flash for five seconds.": "Un interrupteur sur chaque lampe qui la fait clignoter cinq secondes.",
    "Gradient points": "Points du dégradé",
    "On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.": "Sur les rubans à dégradé, une lampe par point de couleur, pour que chaque partie du ruban ait sa couleur.",
    "Unsaved changes.": "Modifications non enregistrées.",
    "Medium": "Moyenne",
    "How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for animated scenes and flashes.": "La vitesse à laquelle une lampe atteint une nouvelle couleur ou luminosité. Rapide par défaut ; Extrême change aussitôt, le plus vif pour les scènes animées et les clignotements.",
    "Polling interval (s)": "Intervalle d'interrogation (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "La fréquence à laquelle le pont est interrogé sur les changements faits dans l'app Hue ou avec un interrupteur.",
    "Changes are kept once you save.": "Les modifications sont conservées une fois enregistrées.",
    "Saved. The plugin restarted with these settings.": "Enregistré. Le plugin a redémarré avec ces réglages.",
    "Your Hue Bridge, its lights with their effects, its sensors and switches, and the scenes of each room, straight from the bridge on your network.": "Votre pont Hue, ses lampes et leurs effets, ses capteurs et interrupteurs, et les scènes de chaque pièce, directement depuis le pont de votre réseau.",
    "Save Configuration": "Enregistrer la configuration",
    "Not in the Home app:": "Pas dans l'app Maison :",
    "Tap a scene to recall it, and again to switch its room off. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.": "Touchez une scène pour la rappeler, puis à nouveau pour éteindre sa pièce. Déposez une image sur une tuile pour la donner à la scène. Les scènes de chaque pièce sont des interrupteurs dans l'app Maison ; le menu ⋯ d'une tuile en retire une.",
    "the picture must be a JPEG, PNG or WebP image": "l'image doit être au format JPEG, PNG ou WebP",
    "the picture is larger than {0} KB": "l'image dépasse {0} Ko",
    "the picture has no valid name": "l'image n'a pas de nom valide",
    "a scene and a picture are required": "une scène et une image sont requises",
    "a scene is required": "une scène est requise",
    "no picture for that scene": "aucune image pour cette scène"
  },
  "es": {
    "Sensors": "Sensores",
    "Search sensors": "Buscar sensores",
    "Motion sensors": "Sensores de movimiento",
    "Low battery": "Batería baja",
    "Pair with the bridge to see its sensors and switches.": "Empareja el puente para ver sus sensores e interruptores.",
    "Sensors and switches are off: turn them on in Settings.": "Los sensores e interruptores están desactivados: actívalos en Ajustes.",
    "The bridge has no sensors or switches yet: add them in the Hue app.": "El puente aún no tiene sensores ni interruptores: añádelos en la app Hue.",
    "{shown} of {total} sensors": "{shown} de {total} sensores",
    "No sensor matches the search and filters.": "Ningún sensor coincide con la búsqueda y los filtros.",
    "Sensors and switches": "Sensores e interruptores",
    "Motion, temperature, light level and contact sensors, and a programmable switch for each button of a dimmer, Tap or smart button. Presses reach the Home app at once, through the bridge's event stream.": "Los sensores de movimiento, temperatura, luminosidad y contacto, y un interruptor programable por cada botón de un regulador, un Tap o un botón inteligente. Las pulsaciones llegan al instante a la app Casa, por el flujo de eventos del puente.",
    "Search lights": "Buscar luces",
    "Colour lights": "Luces de color",
    "With effects": "Con efectos",
    "{shown} of {total} lights": "{shown} de {total} luces",
    "No light matches the search and filters.": "Ninguna luz coincide con la búsqueda y los filtros.",
    "Search scenes": "Buscar escenas",
    "On now": "Encendidas",
    "Colour scenes": "Escenas de color",
    "With a picture": "Con imagen",
    "Not in the Home app": "No en la app Casa",
    "{shown} of {total} scenes": "{shown} de {total} escenas",
    "{n} scene": "{n} escena",
    "{n} scenes": "{n} escenas",
    "No scene matches the search and filters.": "Ninguna escena coincide con la búsqueda y los filtros.",
    "Autoplay is on": "Reproducción automática activada",
    "Autoplay": "Reproducción automática",
    "Follows the Settings speed ({speed}).": "Sigue la velocidad de Ajustes ({speed}).",
    "A speed of its own; Settings has {speed}.": "Una velocidad propia; Ajustes tiene {speed}.",
    "Speed…": "Velocidad…",
    "Speed of {name}": "Velocidad de {name}",
    "Use the default": "Usar la predeterminada",
    "How fast the lights reach this scene. Without a speed of its own, a scene takes the one in Settings.": "La rapidez con la que las luces llegan a esta escena. Sin velocidad propia, una escena usa la de Ajustes.",
    "Play {name}": "Reproducir {name}",
    "Pause {name}": "Pausar {name}",
    "Connected": "Conectado",
    "Lights": "Luces",
    "Hue Bridge": "Puente Hue",
    "Set up the Hue Bridge": "Configurar el puente Hue",
    "Add accessories finds the bridge on the network, or asks for its address, then for a press on its link button. The key stays in the vault, not in config.json.": "Añadir accesorios encuentra el puente en la red, o pide su dirección, y luego que pulses su botón de enlace. La clave se queda en la bóveda, no en config.json.",
    "Effects": "Efectos",
    "Flash": "Parpadear",
    "Pair with the bridge to see its lights.": "Empareja el puente para ver sus luces.",
    "The bridge has no lights yet: add them in the Hue app.": "El puente aún no tiene luces: añádelas en la app Hue.",
    "Active": "Activa",
    "Natural light": "Luz natural",
    "Pair with the bridge to see its scenes.": "Empareja el puente para ver sus escenas.",
    "No scenes yet: make some in the Hue app.": "Aún no hay escenas: créalas en la app Hue.",
    "Zone on": "Zona encendida",
    "Zone off": "Zona apagada",
    "Room on": "Habitación encendida",
    "Room off": "Habitación apagada",
    "A switch for each scene, on one accessory per room or zone. Off switches the room off.": "Un interruptor por escena, en un accesorio por habitación o zona. Apagarlo apaga la habitación.",
    "Play scenes dynamically": "Escenas dinámicas",
    "Recall scenes with their colours slowly moving, as the Hue app's play button does.": "Activa las escenas con sus colores moviéndose despacio, como el botón de reproducir de la app Hue.",
    "A switch for each effect a light has: candle, fireplace, sparkle, prism…": "Un interruptor por cada efecto de una luz: vela, chimenea, destello, prisma…",
    "Room lights": "Luces de la habitación",
    "A lightbulb for each room and zone: on, off and brightness for all its lights at once, in one command, as the Hue app's room controls. Worth it once the Hue Bridge is no longer in the Home app.": "Una bombilla para cada habitación y zona: encender, apagar y ajustar el brillo de todas sus luces a la vez, en un solo comando, como los controles de habitación de la app Hue. Útil cuando el puente Hue ya no está en la app Casa.",
    "Flash switch": "Interruptor Parpadear",
    "A switch on each light that makes it flash for five seconds.": "Un interruptor en cada luz que la hace parpadear cinco segundos.",
    "Gradient points": "Puntos del degradado",
    "On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.": "En las tiras con degradado, una luz por punto de color, para que cada parte de la tira tenga su color.",
    "Unsaved changes.": "Cambios sin guardar.",
    "Medium": "Media",
    "How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for animated scenes and flashes.": "La rapidez con la que una luz llega a un nuevo color o brillo. Rápida es la predeterminada; Extrema cambia al instante, lo más ágil para escenas animadas y parpadeos.",
    "Polling interval (s)": "Intervalo de consulta (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "Cada cuánto se pregunta al puente por los cambios hechos en la app Hue o con un interruptor.",
    "Changes are kept once you save.": "Los cambios se conservan al guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. El plugin se ha reiniciado con estos ajustes.",
    "Your Hue Bridge, its lights with their effects, its sensors and switches, and the scenes of each room, straight from the bridge on your network.": "Tu puente Hue, sus luces con sus efectos, sus sensores e interruptores, y las escenas de cada habitación, directamente desde el puente de tu red.",
    "Save Configuration": "Guardar configuración",
    "Not in the Home app:": "No están en la app Casa:",
    "Tap a scene to recall it, and again to switch its room off. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.": "Toca una escena para activarla, y otra vez para apagar su habitación. Suelta una imagen en un mosaico para dársela a la escena. Las escenas de cada habitación son interruptores en la app Casa; el menú ⋯ de un mosaico quita una.",
    "the picture must be a JPEG, PNG or WebP image": "la imagen debe ser JPEG, PNG o WebP",
    "the picture is larger than {0} KB": "la imagen supera los {0} KB",
    "the picture has no valid name": "la imagen no tiene un nombre válido",
    "a scene and a picture are required": "se necesitan una escena y una imagen",
    "a scene is required": "se necesita una escena",
    "no picture for that scene": "no hay imagen para esa escena"
  },
  "pt": {
    "Sensors": "Sensores",
    "Search sensors": "Procurar sensores",
    "Motion sensors": "Sensores de movimento",
    "Low battery": "Bateria fraca",
    "Pair with the bridge to see its sensors and switches.": "Emparelhe a ponte para ver os seus sensores e interruptores.",
    "Sensors and switches are off: turn them on in Settings.": "Os sensores e interruptores estão desativados: ative-os em Definições.",
    "The bridge has no sensors or switches yet: add them in the Hue app.": "A ponte ainda não tem sensores nem interruptores: adicione-os na app Hue.",
    "{shown} of {total} sensors": "{shown} de {total} sensores",
    "No sensor matches the search and filters.": "Nenhum sensor corresponde à pesquisa e aos filtros.",
    "Sensors and switches": "Sensores e interruptores",
    "Motion, temperature, light level and contact sensors, and a programmable switch for each button of a dimmer, Tap or smart button. Presses reach the Home app at once, through the bridge's event stream.": "Os sensores de movimento, temperatura, luminosidade e contacto, e um interruptor programável para cada botão de um regulador, de um Tap ou de um botão inteligente. As pressões chegam de imediato à app Casa, pelo fluxo de eventos da ponte.",
    "Search lights": "Procurar luzes",
    "Colour lights": "Luzes a cores",
    "With effects": "Com efeitos",
    "{shown} of {total} lights": "{shown} de {total} luzes",
    "No light matches the search and filters.": "Nenhuma luz corresponde à pesquisa e aos filtros.",
    "Search scenes": "Procurar cenas",
    "On now": "Ligadas agora",
    "Colour scenes": "Cenas a cores",
    "With a picture": "Com imagem",
    "Not in the Home app": "Fora da app Casa",
    "{shown} of {total} scenes": "{shown} de {total} cenas",
    "{n} scene": "{n} cena",
    "{n} scenes": "{n} cenas",
    "No scene matches the search and filters.": "Nenhuma cena corresponde à pesquisa e aos filtros.",
    "Autoplay is on": "Reprodução automática ativada",
    "Autoplay": "Reprodução automática",
    "Follows the Settings speed ({speed}).": "Segue a velocidade das Definições ({speed}).",
    "A speed of its own; Settings has {speed}.": "Uma velocidade própria; as Definições têm {speed}.",
    "Speed…": "Velocidade…",
    "Speed of {name}": "Velocidade de {name}",
    "Use the default": "Usar a predefinida",
    "How fast the lights reach this scene. Without a speed of its own, a scene takes the one in Settings.": "A rapidez com que as luzes chegam a esta cena. Sem velocidade própria, uma cena usa a das Definições.",
    "Play {name}": "Reproduzir {name}",
    "Pause {name}": "Pausar {name}",
    "Connected": "Ligada",
    "Lights": "Luzes",
    "Hue Bridge": "Ponte Hue",
    "Set up the Hue Bridge": "Configurar a ponte Hue",
    "Add accessories finds the bridge on the network, or asks for its address, then for a press on its link button. The key stays in the vault, not in config.json.": "Adicionar acessórios encontra a ponte na rede, ou pede o endereço, e depois que prima o botão de ligação. A chave fica no cofre, não em config.json.",
    "Effects": "Efeitos",
    "Flash": "Piscar",
    "Pair with the bridge to see its lights.": "Emparelhe a ponte para ver as luzes.",
    "The bridge has no lights yet: add them in the Hue app.": "A ponte ainda não tem luzes: adicione-as na app Hue.",
    "Active": "Ativa",
    "Natural light": "Luz natural",
    "Pair with the bridge to see its scenes.": "Emparelhe a ponte para ver as cenas.",
    "No scenes yet: make some in the Hue app.": "Ainda não há cenas: crie-as na app Hue.",
    "Zone on": "Zona acesa",
    "Zone off": "Zona apagada",
    "Room on": "Divisão acesa",
    "Room off": "Divisão apagada",
    "A switch for each scene, on one accessory per room or zone. Off switches the room off.": "Um interruptor por cena, num acessório por divisão ou zona. Desligá-lo apaga a divisão.",
    "Play scenes dynamically": "Cenas dinâmicas",
    "Recall scenes with their colours slowly moving, as the Hue app's play button does.": "Ativa as cenas com as cores a mudar devagar, como o botão de reprodução da app Hue.",
    "A switch for each effect a light has: candle, fireplace, sparkle, prism…": "Um interruptor por cada efeito de uma luz: vela, lareira, cintilar, prisma…",
    "Room lights": "Luzes da divisão",
    "A lightbulb for each room and zone: on, off and brightness for all its lights at once, in one command, as the Hue app's room controls. Worth it once the Hue Bridge is no longer in the Home app.": "Uma lâmpada para cada divisão e zona: ligar, desligar e ajustar o brilho de todas as suas luzes de uma vez, num só comando, como os controlos de divisão da app Hue. Útil quando a ponte Hue já não está na app Casa.",
    "Flash switch": "Interruptor Piscar",
    "A switch on each light that makes it flash for five seconds.": "Um interruptor em cada luz que a faz piscar cinco segundos.",
    "Gradient points": "Pontos do gradiente",
    "On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.": "Nas fitas com gradiente, uma luz por ponto de cor, para cada parte da fita ter a sua cor.",
    "Unsaved changes.": "Alterações por guardar.",
    "Medium": "Média",
    "How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for animated scenes and flashes.": "A rapidez com que uma luz chega a uma nova cor ou brilho. Rápida é a predefinida; Extrema muda de imediato, o mais vivo para cenas animadas e piscas.",
    "Polling interval (s)": "Intervalo de consulta (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "Com que frequência a ponte é consultada sobre as alterações feitas na app Hue ou com um interruptor.",
    "Changes are kept once you save.": "As alterações ficam guardadas quando guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. O plugin reiniciou com estas definições.",
    "Your Hue Bridge, its lights with their effects, its sensors and switches, and the scenes of each room, straight from the bridge on your network.": "A ponte Hue, as luzes com os seus efeitos, os sensores e interruptores, e as cenas de cada divisão, diretamente da ponte na sua rede.",
    "Save Configuration": "Guardar configuração",
    "Not in the Home app:": "Fora da app Casa:",
    "Tap a scene to recall it, and again to switch its room off. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.": "Toque numa cena para a ativar, e outra vez para desligar a sua divisão. Largue uma imagem num mosaico para a dar à cena. As cenas de cada divisão são interruptores na app Casa; o menu ⋯ de um mosaico retira uma.",
    "the picture must be a JPEG, PNG or WebP image": "a imagem tem de ser JPEG, PNG ou WebP",
    "the picture is larger than {0} KB": "a imagem tem mais de {0} KB",
    "the picture has no valid name": "a imagem não tem um nome válido",
    "a scene and a picture are required": "são necessárias uma cena e uma imagem",
    "a scene is required": "é necessária uma cena",
    "no picture for that scene": "não há imagem para essa cena"
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Philips Hue</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-violet" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/></svg></span>
    <div class="who">
      <h1>Philips Hue</h1>
      <p class="muted" data-i18n>Your Hue Bridge, its lights with their effects, its sensors and switches, and the scenes of each room, straight from the bridge on your network.</p>
    </div>
  </div>

  <div id="bridge"></div>

  <div class="group tabs main-tabs" role="tablist">
    <button role="tab" data-tab="lights" class="on" aria-selected="true" aria-controls="tab-lights" data-i18n data-action-icon="bulb">Lights</button>
    <button role="tab" data-tab="sensors" aria-selected="false" aria-controls="tab-sensors" data-i18n data-action-icon="sensor">Sensors</button>
    <button role="tab" data-tab="scenes" aria-selected="false" aria-controls="tab-scenes" data-i18n data-action-icon="star">Scenes</button>
    <button role="tab" data-tab="settings" aria-selected="false" aria-controls="tab-settings" data-i18n data-action-icon="sliders">Settings</button>
  </div>

  <section id="tab-lights" class="tab-pane" role="tabpanel">
    <div id="light-toolbar" class="finder"></div>
    <div class="accessory-walls" id="lights"></div>
    <div id="hidden-devices" class="hidden-devices"></div>
  </section>

  <section id="tab-sensors" class="tab-pane hidden" role="tabpanel">
    <div id="sensor-toolbar" class="finder"></div>
    <div class="accessory-walls" id="sensors"></div>
    <div id="hidden-sensors" class="hidden-devices"></div>
  </section>

  <section id="tab-scenes" class="tab-pane hidden" role="tabpanel">
    <p class="muted intro" data-i18n>Tap a scene to recall it, and again to switch its room off. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.</p>
    <div id="scene-toolbar" class="finder"></div>
    <div id="scenes"></div>
  </section>

  <section id="tab-settings" class="tab-pane hidden" role="tabpanel">
    <div class="card">
      <h2 data-i18n>Speed</h2>
      <div id="speed"></div>
    </div>
    <div class="card">
      <h2 data-i18n>In the Home app</h2>
      <div id="options"></div>
    </div>
    <div class="card save-card">
      <div class="save-bar"><span id="save-state" class="muted" data-i18n>Changes are kept once you save.</span><button id="save" class="primary" data-i18n data-action-icon="check">Save Configuration</button></div>
    </div>
  </section>
</main>
<script src="/common.js"></script>
<script src="/remote.js"></script>
<script src="/camera.js"></script>
<script src="/widgets.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
