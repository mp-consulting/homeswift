// The Philips Hue page: the bridge (set up on Add accessories: this page leads there), the lights
// as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the sensors and
// switches the same way (motion, temperature, light level, contact, battery, a button's presses), the scenes of
// each room as tiles painted with their palette (a tap recalls one, a tap on the active one switches its room off,
// play makes its colours move). Refreshed every two seconds while visible. It writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): the plugin's open its Settings page, and a light's, a sensor's or a
// scene's (Excluded, a scene's transition) its own there. The Setup card, tabs, scene pictures and tile text come from
// plugin.js.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, tile, fact, explain, request, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
  let sensors = [];
  let groups = [];

  homeswift.tabs("hue-tab");

  // Where settings are edited: the plugin's Settings page, and each light's, sensor's or scene's there (its Accessory
  // Settings: a light's id, `device:<id>` for a sensor, a scene's id).
  const settingsOf = (deviceID) => homeswift.accessorySettings(`PhilipsHue:${deviceID}`);
  const openSettings = (deviceID) => { location.href = settingsOf(deviceID); };

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

  /// The lights left out of the Home app, as buttons that open their settings; drawn again only when they change.
  function drawHidden(names) {
    homeswift.drawHidden($("#hidden-devices"), names, (name) => { const light = lights.find((item) => item.name === name); if (light) openSettings(light.id); });
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

  /// A widget's ⋯ menu, after All controls: Identify (a light blinks, a sensor's LED flashes), its settings (where it is
  /// Excluded), its log. `prefix` is its accessory id's.
  const menuFor = (prefix) => (accessory) => {
    const id = accessory.id.slice(prefix.length);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { id } }).catch((e) => HomeswiftCommon.showAlert(e.message)) },
      { label: t("Settings"), icon: "gear", href: settingsOf(accessory.id.slice("PhilipsHue:".length)) },
      { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessory.id)}` },
    ];
  };
  const actionsFor = menuFor("PhilipsHue:");

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
    homeswift.drawHidden($("#hidden-sensors"), sensors.filter((item) => item.hidden).map((item) => item.name), (name) => {
      const sensor = sensors.find((item) => item.name === name);
      if (sensor) openSettings(`device:${sensor.id}`);
    });
    if (!status.paired) return empty(t("Pair with the bridge to see its sensors and switches."));
    if (status.sensorsOn === false) return empty(t("Sensors and switches are off: turn them on in the plugin's Settings."));
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

  const sensorActions = menuFor("PhilipsHue:device:");

  // MARK: Scenes

  // A scene's picture: dropped on its tile or chosen from its menu (plugin.js); its ⋯ menu's Settings… opens the
  // scene's Accessory Settings, where it is Excluded and its speed set.
  const pictures = homeswift.scenePictures({
    gallery: true,
    refresh: () => refresh(), settings: (scene, sceneID) => settingsOf(sceneID),
    // A smart scene follows the time of day: the bridge takes no transition or Autoplay for it. Autoplay is the
    // scene's own on the bridge, as the Hue app's: it plays whenever it is recalled, here, in the Home app or there.
    more: (scene) => !scene.smart && scene.palette ? [autoplayItem(scene)] : [],
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
    return pictures.decorate(button, scene, scene.id);
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
  poll(refresh, 2000);
})();
