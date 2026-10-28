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
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its lights.") })));
      drawHidden([]);
      return;
    }
    await loadIfChanged();
    if (!accessories.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("The bridge has no lights yet: add them in the Hue app.") })));
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
    const empty = (text) => list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text })));
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

  /// A sensor widget's ⋯ menu, after All controls: Identify (its LED flashes), the Home app, its log.
  function sensorActions(accessory) {
    const id = accessory.id.slice("PhilipsHue:device:".length);
    const item = sensors.find((entry) => entry.id === id);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { id } }).catch((e) => alert(e.message)) },
      item ? { label: t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList("excludeSensors", item.name) } : null,
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
