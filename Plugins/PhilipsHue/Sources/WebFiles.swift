// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Philips Hue page on the UI's materials: the bridge and its pairing, the lights as the Accessories page's
   widgets, the scenes of each room as tiles painted with their palette, and the settings. The bridge card, tabs,
   scene tiles, speed scale and save bar are style.css's, shared with the DIRIGERA page. */

.page-head { align-items: center; }
h2 { margin: 0 0 10px; }
.intro { margin: 0 0 14px; font-size: 0.875rem; }

/* Finding a light or a scene: one row (the search takes the room left), held under the header while the list
   scrolls, in its glass; on a phone, the search over its three menus, scrolling with the page. While a search or a
   filter narrows the list, how many it keeps and Clear filters under it. */
.finder {
  position: sticky; top: 84px; z-index: 1; display: grid; grid-template-columns: minmax(160px, 1fr) minmax(0, 200px) auto auto;
  gap: 8px; align-items: center; margin: 0 0 14px; padding: 6px; border-radius: 999px;
  background-color: var(--material-chrome); -webkit-backdrop-filter: blur(var(--blur-thick)) saturate(180%); backdrop-filter: blur(var(--blur-thick)) saturate(180%);
  border: 1px solid var(--edge); box-shadow: var(--shadow-thick), inset 0 1px 0 var(--edge-light);
}
.finder .search { width: 100%; min-width: 0; }
.finder .popup { width: 100%; max-width: none; margin: 0; }
.finder > button { white-space: nowrap; }
@media (max-width: 640px) {
  .finder { position: static; grid-template-columns: repeat(3, minmax(0, 1fr)); padding: 0; border-radius: 0; background: none; border: 0; box-shadow: none; -webkit-backdrop-filter: none; backdrop-filter: none; }
  .finder .search { grid-column: 1 / -1; }
  .finder > button { justify-content: center; }
}
@media (prefers-reduced-transparency: reduce) { .finder { -webkit-backdrop-filter: none; backdrop-filter: none; } }

/* Scenes: a section per room, a tile per scene; a smart scene says so under its name. A room's name folds it away. */
.room { margin-bottom: 22px; }
.room-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 0 0 10px; }
.room-head h2 { margin: 0; font-size: 1.0625rem; }
.room-fold { display: inline-flex; align-items: center; gap: 8px; min-width: 0; padding: 4px 6px 4px 0; border: 0; background: none; box-shadow: none; color: var(--text); font: inherit; }
.room-fold:active:not(:disabled) { transform: none; opacity: 0.7; }
.room-fold .chevron { width: 8px; height: 8px; flex: none; border-right: 2px solid var(--muted); border-bottom: 2px solid var(--muted); rotate: 45deg; translate: 0 -2px; transition: rotate var(--fast) var(--ease-out); }
.room.folded .room-fold .chevron { rotate: -45deg; translate: 0 0; }
.room-fold .room-count { font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.room.folded { margin-bottom: 6px; }
.room.folded .scene-tiles { display: none; }
@media (prefers-reduced-motion: reduce) { .room-fold .chevron { transition: none; } }
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
// The Philips Hue page: the bridge (found on the network or at an address, paired with its link button), the lights
// as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the sensors and
// switches the same way (motion, temperature, light level, contact, battery, a button's presses), the scenes of
// each room as tiles painted with their palette (a tap recalls one, a tap on the active one switches its room off,
// play makes its colours move, its ⋯ menu leaves it out of the Home app), and the settings: the transition and what
// the Home app shows. Refreshed every two seconds while visible; saving writes this instance's block. The bridge
// card, tabs, scene pictures, speed scale and tile text come from plugin.js.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, request, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
  let sensors = [];
  let groups = [];
  let block = {};

  homeswift.tabs("hue-tab");

  // MARK: The bridge

  // The card plugin.js draws for both lighting pages: the bridge, its pairing and the address form.
  const bridge = homeswift.bridgePairing({
    card: $("#bridge"), tone: "violet", button: "link",
    texts: {
      name: t("Hue Bridge"), pairTitle: t("Pair Homeswift with the bridge."), press: t("Press the round link button on top of the bridge."),
      pairHelp: t("Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json."),
      summary: t("Bridge address"), placeholder: "192.168.1.20", addressHelp: t("Leave it empty to find the bridge on the network."), none: t("No bridge answered on the network."),
    },
    facts: (item) => [[t("Address"), item.host], [t("Lights"), item.lights ?? 0], [t("Sensors"), item.sensors ?? 0], [t("Scenes"), item.scenes ?? 0]],
    problem: (item) => ({
      error: `The Hue Bridge at ${item.host} did not answer: ${item.error}`,
      context: "The Homeswift Philips Hue plugin reads every resource of the bridge's local API v2 (GET https://<bridge>/clip/v2/resource) every two seconds with its application key.",
      device: { host: item.host },
    }),
    discover: async () => (await request("discover")).hosts,
    use: async (host) => {
      await updateBlock((draft) => { setKey(draft, "host", host, ""); });
      if (host) await request("host", { method: "POST", body: { host } });
      block = await readBlock();
    },
    pair: () => request("pair", { method: "POST", body: {} }),
    refresh: () => refresh(),
  });

  function drawBridge() {
    bridge.draw([{ ...status, detail: [status.host, status.bridgeID?.toUpperCase()].filter(Boolean).join(" · ") }], { address: block.host || status.host || "" });
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

  /// Reads the accessories again when the lights or sensors the Home app has changed.
  async function loadIfChanged() {
    const key = [...lights, ...sensors].filter((item) => !item.hidden).map((item) => item.id).sort().join(",");
    if (key === shapeKey) return;
    shapeKey = key;
    await loadAccessories().catch(() => {});
  }

  /// The lights left out of the Home app, as buttons that bring one back; drawn again only when they change.
  function drawHidden(names) {
    homeswift.drawHidden($("#hidden-devices"), names, (name) => toggleList("excludeLights", name));
  }

  // The lights' finder, over the plugin's widgets: each light with its room from the bridge.
  const lightFinder = finder({
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
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { id } }).catch((e) => alert(e.message)) },
      item ? { label: t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList(listKey, item.name) } : null,
      { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessory.id)}` },
    ].filter(Boolean);
  };
  const actionsFor = menuFor("PhilipsHue:", () => lights, "excludeLights");

  /// A list's one line when it has nothing to show.
  const showEmpty = (list, text) => list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text })));

  // MARK: Sensors and switches, as the Accessories page draws them

  const sensorFinder = finder({
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
        } catch (e) { alert(e.message); }
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
      try { await request(path, { method: "POST", body }); await refresh(); } catch (e) { alert(e.message); } finally { button.classList.remove("busy"); }
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

  const fold = (text) => String(text ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

  /// The room or zone's pill, as the bridge has it: on or off.
  function roomPill(id) {
    const group = groups.find((entry) => entry.id === id);
    if (!group) return null;
    return el("span", { class: `pill status ${group.on ? "on" : "standby"}`, text: group.kind === "zone" ? (group.on ? t("Zone on") : t("Zone off")) : (group.on ? t("Room on") : t("Room off")) });
  }

  /// What finds a light or a scene among dozens, the same on both tabs: a toolbar (a search of names and rooms,
  /// accents aside; a room; by room or by name; Filters with their counts and Clear filters) kept in the page's
  /// address under `prefix`, each tab its own; and the list it keeps, a section per room (its name folds it away,
  /// remembered under `foldKey`, unless a search or a filter is on) or one list by name. `items()` answers the items,
  /// each { id, name, room, roomID }; `filters` are [key, label, icon, predicate]; `draw()` draws the list again.
  function finder({ toolbar, placeholder, prefix = "", items, filters, foldKey, draw }) {
    const param = (key) => prefix + key;
    const query = new URLSearchParams(location.search);
    const active = new Set(filters.map(([key]) => key).filter((key) => query.has(param(key))));
    const search = el("input", { type: "search", class: "search", placeholder, "aria-label": placeholder, value: query.get(param("q")) ?? "" });
    const room = el("select", { class: "popup", "aria-label": t("Room") });
    const order = el("select", { class: "popup", "aria-label": t("Order") },
      el("option", { value: "room", text: t("By room") }), el("option", { value: "name", text: t("By name") }));
    order.value = query.get(param("sort")) === "name" ? "name" : "room";
    const button = el("button", { type: "button", actionIcon: "sliders", "aria-haspopup": "menu" });
    toolbar.append(search, room, order, button);
    // Under the toolbar while a search or a filter narrows the list: how many it keeps, and the way back.
    const status = el("div", { class: "finder-status", "aria-live": "polite" });
    toolbar.after(status);
    let wantedRoom = query.get(param("room")) || "";

    /// Writes this tab's search, room, order and filters into the address, the other tab's left as they are.
    function keep() {
      const next = new URLSearchParams(location.search);
      for (const key of ["q", "room", "sort", ...filters.map(([key]) => key)]) next.delete(param(key));
      if (search.value.trim()) next.set(param("q"), search.value.trim());
      if (room.value) next.set(param("room"), room.value);
      if (order.value === "name") next.set(param("sort"), "name");
      for (const key of active) next.set(param(key), "1");
      history.replaceState(history.state, "", `${location.pathname}${next.size ? `?${next}` : ""}`);
    }
    const changed = () => { wantedRoom = room.value; keep(); draw(); };
    // A search filters once the typing pauses, not on every key.
    let typing = 0;
    search.addEventListener("input", () => { clearTimeout(typing); typing = setTimeout(changed, 120); });
    room.addEventListener("change", changed);
    order.addEventListener("change", changed);
    function clear() {
      search.value = "";
      room.value = "";
      active.clear();
      changed();
    }

    /// Every item, those the search and room keep (what a filter counts in), and those shown.
    function view() {
      const text = fold(search.value.trim());
      const all = items();
      const base = all.filter((item) => (!room.value || item.roomID === room.value) && (!text || fold(item.name).includes(text) || fold(item.room).includes(text)));
      const predicates = filters.filter(([key]) => active.has(key)).map(([, , , predicate]) => predicate);
      const shown = base.filter((item) => predicates.every((predicate) => predicate(item)));
      return { all, base, shown, narrowed: shown.length !== all.length };
    }

    /// The rooms, by name, with how many items each has: the room menu (drawn again only when they change; a room the
    /// address names that is gone falls back to all) and the order of the sections.
    let roomsKey = "";
    function rooms() {
      const found = new Map();
      for (const item of items()) if (item.roomID) found.set(item.roomID, { name: item.room, count: (found.get(item.roomID)?.count ?? 0) + 1 });
      return [...found].sort(([, a], [, b]) => a.name.localeCompare(b.name));
    }
    function drawRooms(list) {
      const key = JSON.stringify(list);
      if (key === roomsKey) return;
      roomsKey = key;
      room.replaceChildren(el("option", { value: "", text: t("All rooms") }), ...list.map(([id, entry]) => el("option", { value: id, text: `${entry.name} (${entry.count})` })));
      room.value = list.some(([id]) => id === wantedRoom) ? wantedRoom : "";
    }

    button.addEventListener("click", () => {
      const { base } = view();
      HomeswiftCommon.menu(button, [
        ...filters.map(([key, label, iconName, predicate]) => ({
          label, icon: iconName, count: base.filter(predicate).length, checkbox: true, toggle: true, keepOpen: true, checked: active.has(key),
          onSelect: () => {
            if (active.has(key)) active.delete(key); else active.add(key);
            changed();
            return active.has(key);
          },
        })),
        { separator: true },
        { label: t("Clear filters"), clearFilters: true, icon: "restore", disabled: !search.value && !room.value && !active.size, onSelect: clear },
      ]);
    });

    const folded = new Set((() => { try { return JSON.parse(localStorage.getItem(foldKey) || "[]"); } catch { return []; } })());
    function toggleFold(id) {
      if (folded.has(id)) folded.delete(id); else folded.add(id);
      try { localStorage.setItem(foldKey, JSON.stringify([...folded])); } catch {}
      draw();
    }

    return {
      show(visible) {
        toolbar.classList.toggle("hidden", !visible);
        if (!visible) { status.replaceChildren(); delete status.dataset.key; }
      },
      /// Draws `list`: how many the search and filters keep (`countText(shown, total)`), `emptyText` with Clear
      /// filters when none, else a
      /// section per room (those without one last, under "No room") or one by name, each a `bodyClass` element
      /// whose items `render(body, items)` draws.
      draw(list, { countText, emptyText, bodyClass, render }) {
        const roomList = rooms();
        drawRooms(roomList);
        const active_ = active.size;
        button.classList.toggle("on", active_ > 0);
        button.replaceChildren(...[el("span", { text: t("Filters") }), active_ ? el("span", { class: "toolbar-count", text: String(active_) }) : null].filter(Boolean));
        const { all, shown, narrowed } = view();
        const statusKey = narrowed ? `${shown.length}/${all.length}` : "";
        if (status.dataset.key !== statusKey) {
          status.dataset.key = statusKey;
          status.replaceChildren(...(narrowed ? [el("span", { text: countText(shown.length, all.length) }),
            el("button", { type: "button", class: "small", actionIcon: "restore", text: t("Clear filters"), onclick: clear })] : []));
        }
        if (!shown.length) {
          list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: emptyText })));
          return;
        }
        if (list.querySelector(":scope > .card.empty")) list.replaceChildren();
        const byName = order.value === "name";
        const sections = byName
          ? [{ id: "*", name: null, items: [...shown].sort((a, b) => a.name.localeCompare(b.name) || fold(a.room).localeCompare(fold(b.room))) }]
          : [...roomList.map(([id, entry]) => ({ id, name: entry.name, items: shown.filter((item) => item.roomID === id) })),
            { id: "-", name: t("No room"), items: shown.filter((item) => !item.roomID) }].filter((section) => section.items.length);
        renderKeyed(list, sections.map((section) => ({ id: section.id })), (section) => section.id,
          () => el("section", { class: "room" }, el("div", { class: "room-head" }), el("div", { class: bodyClass })));
        sections.forEach((section, index) => {
          const node = list.children[index];
          const [head, body] = node.children;
          const isFolded = !narrowed && section.name !== null && folded.has(section.id);
          node.classList.toggle("folded", isFolded);
          head.classList.toggle("hidden", section.name === null);
          const pill = roomPill(section.id);
          const headKey = JSON.stringify([section.name, section.items.length, isFolded, pill?.outerHTML ?? null]);
          if (section.name !== null && head.dataset.json !== headKey) {
            head.dataset.json = headKey;
            head.replaceChildren(...[
              el("button", { type: "button", class: "room-fold", "aria-expanded": String(!isFolded), onclick: () => toggleFold(section.id) },
                el("span", { class: "chevron", "aria-hidden": "true" }), el("h2", { text: section.name }), el("span", { class: "muted room-count", text: String(section.items.length) })),
              pill].filter(Boolean));
          }
          render(body, isFolded ? [] : section.items.map((item) => ({ ...item, showRoom: byName })));
        });
      },
    };
  }

  // The scenes' finder: Colour scenes leaves out the whites of Hue's standard scenes.
  const sceneFinder = finder({
    toolbar: $("#scene-toolbar"), placeholder: t("Search scenes"), items: () => groups.flatMap((group) => group.scenes.map((scene) => ({ ...scene, room: group.name, roomID: group.id }))),
    foldKey: "hue-folded-rooms", draw: () => drawScenes(),
    filters: [
      ["on", t("On now"), "bulb", (scene) => scene.active],
      ["autoplay", t("Autoplay"), "loop", (scene) => scene.autoplay && scene.palette && !scene.smart],
      ["colour", t("Colour scenes"), "sparkle", (scene) => scene.colourful],
      ["picture", t("With a picture"), "image", (scene) => Boolean(scene.picture)],
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
    help: t("How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for moods and flashes."),
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
  readBlock().then((value) => { block = value || {}; fillSettings(); drawBridge(); }).catch(() => {});
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
    "All rooms": "Toutes les pièces",
    "Order": "Ordre",
    "By name": "Par nom",
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
    "Not found": "Introuvable",
    "Connected": "Connecté",
    "Lights": "Lampes",
    "Press the round link button on top of the bridge.": "Appuyez sur le bouton rond de liaison sur le dessus du pont.",
    "Pair Homeswift with the bridge.": "Jumelez Homeswift avec le pont.",
    "Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.": "Jumelez, puis appuyez sur le bouton de liaison du pont dans la minute. La clé reste dans le dossier du plugin, pas dans config.json.",
    "Hue Bridge": "Pont Hue",
    "Bridge address": "Adresse du pont",
    "Leave it empty to find the bridge on the network.": "Laissez vide pour trouver le pont sur le réseau.",
    "No bridge answered on the network.": "Aucun pont n'a répondu sur le réseau.",
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
    "How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for moods and flashes.": "La vitesse à laquelle une lampe atteint une nouvelle couleur ou luminosité. Rapide par défaut ; Extrême change aussitôt, le plus vif pour les ambiances et les clignotements.",
    "Polling interval (s)": "Intervalle d'interrogation (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "La fréquence à laquelle le pont est interrogé sur les changements faits dans l'app Hue ou avec un interrupteur.",
    "Changes are kept once you save.": "Les modifications sont conservées une fois enregistrées.",
    "Saved. The plugin restarted with these settings.": "Enregistré. Le plugin a redémarré avec ces réglages.",
    "Your Hue Bridge, its lights with their effects, and the scenes of each room, straight from the bridge on your network.": "Votre pont Hue, ses lampes et leurs effets, et les scènes de chaque pièce, directement depuis le pont sur votre réseau.",
    "Save Configuration": "Enregistrer la configuration",
    "an address is required": "une adresse est requise",
    "The link button was not pressed in time.": "Le bouton de liaison n'a pas été pressé à temps.",
    "Press the link button on the Hue Bridge.": "Appuyez sur le bouton de liaison du pont Hue.",
    "The link button was not pressed in time: pair again from the plugin's page.": "Le bouton de liaison n'a pas été pressé à temps : jumelez à nouveau depuis la page du plugin.",
    "No Hue Bridge found on the network: set its address on the plugin's page.": "Aucun pont Hue trouvé sur le réseau : indiquez son adresse sur la page du plugin.",
    "The Hue Bridge refused the application key: pair again from the plugin's page.": "Le pont Hue a refusé la clé d'application : jumelez à nouveau depuis la page du plugin.",
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
    "All rooms": "Todas las habitaciones",
    "Order": "Orden",
    "By name": "Por nombre",
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
    "Not found": "No encontrado",
    "Connected": "Conectado",
    "Lights": "Luces",
    "Press the round link button on top of the bridge.": "Pulsa el botón redondo de enlace en la parte superior del puente.",
    "Pair Homeswift with the bridge.": "Empareja Homeswift con el puente.",
    "Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.": "Empareja y pulsa el botón de enlace del puente antes de un minuto. La clave se queda en la carpeta del plugin, no en config.json.",
    "Hue Bridge": "Puente Hue",
    "Bridge address": "Dirección del puente",
    "Leave it empty to find the bridge on the network.": "Déjalo vacío para buscar el puente en la red.",
    "No bridge answered on the network.": "Ningún puente ha respondido en la red.",
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
    "How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for moods and flashes.": "La rapidez con la que una luz llega a un nuevo color o brillo. Rápida es la predeterminada; Extrema cambia al instante, lo más ágil para ambientes y parpadeos.",
    "Polling interval (s)": "Intervalo de consulta (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "Cada cuánto se pregunta al puente por los cambios hechos en la app Hue o con un interruptor.",
    "Changes are kept once you save.": "Los cambios se conservan al guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. El plugin se ha reiniciado con estos ajustes.",
    "Your Hue Bridge, its lights with their effects, and the scenes of each room, straight from the bridge on your network.": "Tu puente Hue, sus luces con sus efectos y las escenas de cada habitación, directamente desde el puente en tu red.",
    "Save Configuration": "Guardar configuración",
    "an address is required": "se necesita una dirección",
    "The link button was not pressed in time.": "No se ha pulsado el botón de enlace a tiempo.",
    "Press the link button on the Hue Bridge.": "Pulsa el botón de enlace del puente Hue.",
    "The link button was not pressed in time: pair again from the plugin's page.": "No se ha pulsado el botón de enlace a tiempo: vuelve a emparejar desde la página del plugin.",
    "No Hue Bridge found on the network: set its address on the plugin's page.": "No se ha encontrado ningún puente Hue en la red: indica su dirección en la página del plugin.",
    "The Hue Bridge refused the application key: pair again from the plugin's page.": "El puente Hue ha rechazado la clave de aplicación: vuelve a emparejar desde la página del plugin.",
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
    "All rooms": "Todas as divisões",
    "Order": "Ordem",
    "By name": "Por nome",
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
    "Not found": "Não encontrada",
    "Connected": "Ligada",
    "Lights": "Luzes",
    "Press the round link button on top of the bridge.": "Prima o botão redondo de ligação no topo da ponte.",
    "Pair Homeswift with the bridge.": "Emparelhe o Homeswift com a ponte.",
    "Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.": "Emparelhe e prima o botão de ligação da ponte no espaço de um minuto. A chave fica na pasta do plugin, não em config.json.",
    "Hue Bridge": "Ponte Hue",
    "Bridge address": "Endereço da ponte",
    "Leave it empty to find the bridge on the network.": "Deixe vazio para procurar a ponte na rede.",
    "No bridge answered on the network.": "Nenhuma ponte respondeu na rede.",
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
    "How fast a light reaches a new colour or brightness. Fast is the default; Extreme changes at once, snappiest for moods and flashes.": "A rapidez com que uma luz chega a uma nova cor ou brilho. Rápida é a predefinida; Extrema muda de imediato, o mais vivo para ambientes e piscas.",
    "Polling interval (s)": "Intervalo de consulta (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "Com que frequência a ponte é consultada sobre as alterações feitas na app Hue ou com um interruptor.",
    "Changes are kept once you save.": "As alterações ficam guardadas quando guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. O plugin reiniciou com estas definições.",
    "Your Hue Bridge, its lights with their effects, and the scenes of each room, straight from the bridge on your network.": "A ponte Hue, as luzes com os seus efeitos e as cenas de cada divisão, diretamente da ponte na sua rede.",
    "Save Configuration": "Guardar configuração",
    "an address is required": "é necessário um endereço",
    "The link button was not pressed in time.": "O botão de ligação não foi premido a tempo.",
    "Press the link button on the Hue Bridge.": "Prima o botão de ligação da ponte Hue.",
    "The link button was not pressed in time: pair again from the plugin's page.": "O botão de ligação não foi premido a tempo: emparelhe novamente a partir da página do plugin.",
    "No Hue Bridge found on the network: set its address on the plugin's page.": "Nenhuma ponte Hue encontrada na rede: indique o endereço na página do plugin.",
    "The Hue Bridge refused the application key: pair again from the plugin's page.": "A ponte Hue recusou a chave da aplicação: emparelhe novamente a partir da página do plugin.",
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
      <p class="muted" data-i18n>Your Hue Bridge, its lights with their effects, and the scenes of each room, straight from the bridge on your network.</p>
    </div>
  </div>

  <div id="bridge" class="card bridge-card"></div>

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
