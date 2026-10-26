// The Philips Hue page: the bridge (found on the network or at an address, paired with its link button), the lights
// as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the scenes of
// each room as tiles painted with their palette (a tap recalls one, a tap on the active one switches its room off,
// play makes its colours move, its ⋯ menu leaves it out of the Home app), and the settings: the transition and what
// the Home app shows. Refreshed every two seconds while visible; saving writes this instance's block. The bridge
// card, tabs, scene pictures, speed scale and tile text come from plugin.js.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, icon, request, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
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
    facts: (item) => [[t("Address"), item.host], [t("Lights"), item.lights ?? 0], [t("Scenes"), item.scenes ?? 0]],
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

  /// The plugin's accessories (not its scene switches), read again when the set of lights changes.
  let accessories = [];
  let shapeKey = "";
  async function loadAccessories() {
    const all = await homeswift.api("/api/accessories");
    accessories = all.filter((accessory) => accessory.platform === "PhilipsHue" && accessory.platformName === homeswift.name && !accessory.id.startsWith("PhilipsHue:scenes:"));
  }

  /// The lights left out of the Home app, as buttons that bring one back; drawn again only when they change.
  function drawHidden(names) {
    const hidden = $("#hidden-devices");
    const key = JSON.stringify(names);
    if (hidden.dataset.json === key) return;
    hidden.dataset.json = key;
    hidden.replaceChildren(...(names.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...names.map((name) => el("button", { actionIcon: "eye", text: name, title: t("Show in the Home app"), onclick: () => toggleList("excludeLights", name) }))] : []));
  }

  let listening = false;
  async function drawLights() {
    const list = $("#lights");
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its lights.") })));
      drawHidden([]);
      return;
    }
    const key = lights.filter((item) => !item.hidden).map((item) => item.id).sort().join(",");
    if (key !== shapeKey) {
      shapeKey = key;
      await loadAccessories().catch(() => {});
    }
    if (!accessories.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("The bridge has no lights yet: add them in the Hue app.") })));
    } else {
      if (list.querySelector(".card.empty")) list.replaceChildren();
      // A widget per accessory, drawn once: its values follow the bridge's event stream.
      renderKeyed(list, accessories.map((accessory) => ({ id: accessory.id, name: accessory.name, services: accessory.services.length })), (item) => item.id,
        (item) => HomeswiftWidgets.card(accessories.find((accessory) => accessory.id === item.id), { size: "large", actions: actionsFor }));
      if (!listening) { HomeswiftWidgets.listen(); listening = true; }
    }
    drawHidden(lights.filter((item) => item.hidden).map((item) => item.name));
  }

  /// The widget's ⋯ menu, after All controls: what this page adds.
  function actionsFor(accessory) {
    const id = accessory.id.slice("PhilipsHue:".length);
    const item = lights.find((entry) => entry.id === id);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { id } }).catch((e) => alert(e.message)) },
      item ? { label: t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList("excludeLights", item.name) } : null,
      { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessory.id)}` },
    ].filter(Boolean);
  }

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

  // MARK: Finding a scene

  // A bridge has dozens of scenes per room: a search (scene and room names, accents aside), a room, filters with
  // their counts, and the order, kept in the page's address so a reload or a link keeps them.
  const query = new URLSearchParams(location.search);
  const fold = (text) => String(text ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  const sceneFilters = [
    ["on", t("On now"), "bulb", (scene) => scene.active],
    ["autoplay", t("Autoplay"), "loop", (scene) => scene.autoplay && scene.palette && !scene.smart],
    ["colour", t("Colour scenes"), "sparkle", (scene) => scene.colourful],
    ["picture", t("With a picture"), "image", (scene) => Boolean(scene.picture)],
    ["hidden", t("Not in the Home app"), "eye", (scene) => scene.hidden],
  ];
  const activeFilters = new Set(sceneFilters.map(([key]) => key).filter((key) => query.has(key)));
  const sceneSearch = el("input", { type: "search", class: "search", placeholder: t("Search scenes"), "aria-label": t("Search scenes"), value: query.get("q") ?? "" });
  const roomPicker = el("select", { class: "popup", "aria-label": t("Room") });
  const sortPicker = el("select", { class: "popup", "aria-label": t("Order") },
    el("option", { value: "room", text: t("By room") }), el("option", { value: "name", text: t("By name") }));
  sortPicker.value = query.get("sort") === "name" ? "name" : "room";
  const filterButton = el("button", { type: "button", actionIcon: "sliders", "aria-haspopup": "menu" });
  const sceneCount = el("span", { class: "count muted", "aria-live": "polite" });
  $("#scene-toolbar").append(sceneSearch, roomPicker, sortPicker, filterButton, sceneCount);

  /// Writes the search, room, order and filters into the address, without a new history entry.
  function keepInAddress() {
    const next = new URLSearchParams();
    if (sceneSearch.value.trim()) next.set("q", sceneSearch.value.trim());
    if (roomPicker.value) next.set("room", roomPicker.value);
    if (sortPicker.value === "name") next.set("sort", "name");
    for (const key of activeFilters) next.set(key, "1");
    history.replaceState(history.state, "", `${location.pathname}${next.size ? `?${next}` : ""}`);
  }
  const changed = () => { keepInAddress(); drawScenes(); };
  sceneSearch.addEventListener("input", changed);
  roomPicker.addEventListener("change", changed);
  sortPicker.addEventListener("change", changed);

  function clearSceneFilters() {
    sceneSearch.value = "";
    roomPicker.value = "";
    activeFilters.clear();
    changed();
  }

  /// Every scene with its room, those the search and room keep (what a filter counts in), and those shown.
  function sceneView() {
    const text = fold(sceneSearch.value.trim());
    const all = groups.flatMap((group) => group.scenes.map((scene) => ({ ...scene, room: group.name, groupID: group.id })));
    const base = all.filter((scene) => (!roomPicker.value || scene.groupID === roomPicker.value)
      && (!text || fold(scene.name).includes(text) || fold(scene.room).includes(text)));
    const predicates = sceneFilters.filter(([key]) => activeFilters.has(key)).map(([, , , predicate]) => predicate);
    return { all, base, shown: base.filter((scene) => predicates.every((predicate) => predicate(scene))) };
  }

  /// The room menu, drawn again only when the rooms change; a room the address names that is gone falls back to all.
  let roomsKey = "";
  function drawRoomPicker() {
    const key = JSON.stringify(groups.map((group) => [group.id, group.name, group.scenes.length]));
    if (key === roomsKey) return;
    roomsKey = key;
    const wanted = roomPicker.value || query.get("room") || "";
    roomPicker.replaceChildren(el("option", { value: "", text: t("All rooms") }),
      ...groups.map((group) => el("option", { value: group.id, text: `${group.name} (${group.scenes.length})` })));
    roomPicker.value = groups.some((group) => group.id === wanted) ? wanted : "";
  }

  filterButton.addEventListener("click", () => {
    const { base } = sceneView();
    HomeswiftCommon.menu(filterButton, [
      ...sceneFilters.map(([key, label, iconName, predicate]) => ({
        label, icon: iconName, count: base.filter(predicate).length, checkbox: true, toggle: true, keepOpen: true, checked: activeFilters.has(key),
        onSelect: () => {
          if (activeFilters.has(key)) activeFilters.delete(key); else activeFilters.add(key);
          changed();
          return activeFilters.has(key);
        },
      })),
      { separator: true },
      { label: t("Clear filters"), clearFilters: true, icon: "restore", disabled: !sceneSearch.value && !roomPicker.value && !activeFilters.size, onSelect: clearSceneFilters },
    ]);
  });

  /// The Filters button with how many are on.
  function drawFilterButton() {
    const count = activeFilters.size;
    filterButton.classList.toggle("on", count > 0);
    filterButton.replaceChildren(...[el("span", { text: t("Filters") }), count ? el("span", { class: "toolbar-count", text: String(count) }) : null].filter(Boolean));
  }

  // Rooms folded away, by group id, kept between visits; a search or a filter shows every room that matches.
  const folded = new Set((() => { try { return JSON.parse(localStorage.getItem("hue-folded-rooms") || "[]"); } catch { return []; } })());
  function toggleFold(id) {
    if (folded.has(id)) folded.delete(id); else folded.add(id);
    try { localStorage.setItem("hue-folded-rooms", JSON.stringify([...folded])); } catch {}
    drawScenes();
  }

  /// The scenes as the toolbar asks: a section per room (its head drawn again when the room changes, a tile per scene
  /// drawn again only when its own scene changes, so a recall does not repaint every picture), or one list by name.
  function drawScenes() {
    const list = $("#scenes");
    const paired = status.paired && groups.length;
    $("#scene-toolbar").classList.toggle("hidden", !paired);
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its scenes.") })));
      return;
    }
    if (!groups.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No scenes yet: make some in the Hue app.") })));
      return;
    }
    drawRoomPicker();
    drawFilterButton();
    const { all, shown } = sceneView();
    const narrowed = shown.length !== all.length;
    sceneCount.textContent = narrowed ? t("{shown} of {total} scenes", { shown: shown.length, total: all.length }) : tn("{n} scene", "{n} scenes", all.length);
    if (!shown.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No scene matches the search and filters.") }),
        el("button", { type: "button", actionIcon: "restore", text: t("Clear filters"), onclick: clearSceneFilters })));
      return;
    }
    if (list.querySelector(":scope > .card.empty")) list.replaceChildren();
    const byName = sortPicker.value === "name";
    const sections = byName
      ? [{ id: "*", name: null, scenes: [...shown].sort((a, b) => a.name.localeCompare(b.name) || a.room.localeCompare(b.room)) }]
      : groups.map((group) => ({ ...group, scenes: shown.filter((scene) => scene.groupID === group.id) })).filter((section) => section.scenes.length);
    renderKeyed(list, sections.map((section) => ({ id: section.id })), (section) => section.id,
      () => el("section", { class: "room" }, el("div", { class: "room-head" }), el("div", { class: "scene-tiles" })));
    sections.forEach((section, index) => {
      const node = list.children[index];
      const [head, tiles] = node.children;
      const isFolded = !narrowed && section.name !== null && folded.has(section.id);
      node.classList.toggle("folded", isFolded);
      head.classList.toggle("hidden", section.name === null);
      const headKey = JSON.stringify([section.name, section.kind, section.on, section.scenes.length, isFolded]);
      if (section.name !== null && head.dataset.json !== headKey) {
        head.dataset.json = headKey;
        head.replaceChildren(
          el("button", { type: "button", class: "room-fold", "aria-expanded": String(!isFolded), onclick: () => toggleFold(section.id) },
            el("span", { class: "chevron", "aria-hidden": "true" }), el("h2", { text: section.name }), el("span", { class: "muted room-count", text: String(section.scenes.length) })),
          el("span", { class: `pill status ${section.on ? "on" : "standby"}`, text: section.kind === "zone" ? (section.on ? t("Zone on") : t("Zone off")) : (section.on ? t("Room on") : t("Room off")) }));
      }
      renderKeyed(tiles, isFolded ? [] : section.scenes.map((scene) => ({ ...scene, showRoom: byName })), (scene) => scene.id, sceneTile);
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

  /// Adds or removes a name from one of the block's lists (`excludeLights`, `excludeScenes`), saved at once.
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
      const [answer, lightList, sceneList] = await Promise.all([request("status"), settle(request("lights")), settle(request("scenes"))]);
      if (answer.paired) {
        const failed = lightList.error ?? sceneList.error;
        if (failed) throw failed;
        ({ lights } = lightList.value);
        ({ groups } = sceneList.value);
      } else {
        lights = [];
        groups = [];
      }
      status = answer;
    } catch (e) {
      status = { error: e.message };
    }
    drawBridge();
    drawLights();
    drawScenes();
  }

  buildSettings();
  readBlock().then((value) => { block = value || {}; fillSettings(); drawBridge(); }).catch(() => {});
  poll(refresh, 2000);
})();
