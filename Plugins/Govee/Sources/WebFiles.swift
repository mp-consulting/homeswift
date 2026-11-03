// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension GoveePlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Govee page on the UI's materials: the Homebridge plugin's devices and tools tabs (its settings are the Settings
   page's), a list per device type, and a light's scene library with the Govee app's icons, to browse. */

.page-head { align-items: center; }
.main-tabs { margin: 18px 0 14px; }
.tab-pane { animation: fade var(--normal) var(--ease-out); }
h2 { margin: 0 0 10px; }
h3 { margin: 0 0 8px; font-size: 0.9375rem; }

.discover-head { display: flex; justify-content: space-between; align-items: center; gap: 14px; flex-wrap: wrap; }
.discover-head p { margin: 0; flex: 1; min-width: 220px; font-size: 0.875rem; }
.found { list-style: none; margin: 14px 0 0; padding: 0; display: grid; gap: 6px; max-height: 400px; overflow-y: auto; }
.found li { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 8px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); }
.found li > div { min-width: 0; }
.found .mono { font-size: 0.8125rem; overflow-wrap: anywhere; user-select: all; }
.summary { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; border: 1px solid var(--line); background: var(--material-thin); font-size: 0.875rem; }
.summary.ok { color: var(--ok); }

/* One section per device type: a count, its devices as rows, and an Add button. */
details.type { margin: 0 0 10px; border-radius: 18px; }
details.type > summary .count { min-width: 26px; text-align: center; }
details.type.empty > summary .entry-name { color: var(--muted); }
.type-body { padding: 0 14px 12px; }
.rows { display: grid; gap: 6px; margin: 4px 0 10px; }
.row-device { display: flex; align-items: center; gap: 12px; padding: 8px 10px 8px 14px; border-radius: 14px; background: var(--control); border: 1px solid var(--edge); }
.row-device .who { flex: 1; min-width: 0; }
.row-device .who strong { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row-device .mono { font-size: 0.75rem; color: var(--muted); overflow-wrap: anywhere; }
.row-device.ignored .who { opacity: 0.5; }
.row-device .links { display: inline-flex; gap: 4px; flex: none; }
.transports { display: inline-flex; gap: 4px; margin-left: 6px; vertical-align: middle; }
.transports .pill { font-size: 0.6875rem; padding: 1px 7px; }

/* A light's scene library. */
.editor { scroll-margin-top: 90px; animation: materialize var(--normal) var(--ease-out); }
.editor-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; margin-bottom: 12px; }
.editor-head h2 { margin: 0; overflow-wrap: anywhere; }
.editor .tabs { margin-bottom: 12px; flex-wrap: wrap; }

/* The scene library: the selection on top, the library below with its categories down the side. */
.scene-panel { border: 1px solid var(--line); border-radius: 18px; overflow: hidden; margin: 14px 0 0; }
.scene-panel-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 16px; background: var(--material-thin); }
.scene-panel-head p { margin: 2px 0 0; font-size: 0.8125rem; }
.scene-panel-body { padding: 8px 16px; display: grid; gap: 4px; }
.scene-field { display: grid; grid-template-columns: minmax(90px, auto) minmax(0, 1fr) auto; align-items: center; gap: 10px; font-size: 0.8125rem; }
.scene-field .mono { overflow-wrap: anywhere; user-select: all; max-height: 4.5em; overflow-y: auto; }
#signed-out { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 12px; }
#signed-out.hidden { display: none; }
#signed-out .notice { margin: 0; flex: 1; }
.scene-icon { width: 28px; height: 28px; border-radius: 8px; object-fit: cover; flex: none; background: var(--material-thin); display: inline-block; }
.scene-icon.large { width: 52px; height: 52px; border-radius: 14px; }
.scene-icon.empty { border: 1px dashed var(--line); }
.picker { display: grid; grid-template-columns: minmax(140px, 200px) minmax(0, 1fr); gap: 14px; }
.picker-cats { display: grid; gap: 4px; align-content: start; max-height: 460px; overflow-y: auto; }
.picker-cats button { display: flex; justify-content: space-between; gap: 8px; text-align: left; border: 0; background: none; box-shadow: none; padding: 7px 10px; border-radius: 12px; }
.picker-cats button:hover { transform: none; }
@media (hover: hover) and (pointer: fine) { .picker-cats button:not(.on):hover { background: var(--material-thin); } }
.picker-cats button.on { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); }
.picker-cats .count { opacity: 0.7; font-variant-numeric: tabular-nums; }
.picker-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 8px; max-height: 460px; overflow-y: auto; align-content: start; padding: 2px; }
.tile-scene { display: grid; justify-items: center; gap: 6px; padding: 10px 6px; border-radius: 16px; position: relative; text-align: center; font-size: 0.75rem; }
.tile-scene.selected { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent); }
.tile-scene .name { overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.tile-scene .variants { position: absolute; top: 6px; right: 6px; }
.picker-foot { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-top: 10px; font-size: 0.8125rem; flex-wrap: wrap; }
.notice { margin: 0 0 10px; padding: 8px 12px; border-radius: 12px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }

/* Tools. */
.docs { margin: 0; padding-left: 20px; font-size: 0.875rem; }
.docs li { margin: 4px 0; }
.problem { margin-top: 12px; }
.problem p { margin: 0; }
.busy::after {
  content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
  border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }

@media (max-width: 640px) {
  .picker { grid-template-columns: 1fr; }
  .picker-cats { grid-auto-flow: column; grid-auto-columns: max-content; overflow-x: auto; max-height: none; }
}
@media (prefers-reduced-motion: reduce) {
  .tab-pane, .editor { animation: none; }
  .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
}

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Govee page, after the Homebridge plugin's settings page: Devices (the account's and the LAN's devices by type,
// how the plugin reaches each, and a light's Scene Library to browse) and Tools (clear the cache). It writes no
// settings (docs/adr/0002-schema-declares-every-setting.md): signing in is Setup's, and the plugin's settings and each
// device's (its Name, Show As, a light's scenes…) are on the Settings page, which a device's row opens.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, explain, breadcrumb, api, poll, setupAddress } = homeswift;

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors reach the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Where settings are edited: the plugin's Settings page, and each device's there.

  const deviceSettings = (deviceId) => homeswift.accessorySettings(`Govee:${deviceId}`);

  // MARK: Device types, as the Homebridge page lists them

  // `count` says how many there are.
  const typeNames = {
    lightDevices: { count: (n) => tn("{n} light", "{n} lights", n), fresh: t("New light"), title: t("Light Devices"), add: t("Add Light Device"), badge: t("Light") },
    switchDevices: { count: (n) => tn("{n} switch/outlet", "{n} switches/outlets", n), fresh: t("New switch/outlet"), title: t("Switch/Outlet Devices"), add: t("Add Switch Device"), badge: t("Switch/Outlet") },
    thermoDevices: { count: (n) => tn("{n} temperature/humidity sensor", "{n} temperature/humidity sensors", n), fresh: t("New temperature/humidity sensor"), title: t("Temperature/Humidity Sensors"), add: t("Add Sensor"), badge: t("Temp/Humidity Sensor") },
    leakDevices: { count: (n) => tn("{n} leak sensor", "{n} leak sensors", n), fresh: t("New leak sensor"), title: t("Leak Sensors"), add: t("Add Leak Sensor"), badge: t("Leak Sensor") },
    fanDevices: { count: (n) => tn("{n} fan", "{n} fans", n), fresh: t("New fan"), title: t("Fan Devices"), add: t("Add Fan"), badge: t("Fan") },
    heaterDevices: { count: (n) => tn("{n} heater", "{n} heaters", n), fresh: t("New heater"), title: t("Heater Devices"), add: t("Add Heater"), badge: t("Heater") },
    humidifierDevices: { count: (n) => tn("{n} humidifier", "{n} humidifiers", n), fresh: t("New humidifier"), title: t("Humidifier Devices"), add: t("Add Humidifier"), badge: t("Humidifier") },
    purifierDevices: { count: (n) => tn("{n} air purifier", "{n} air purifiers", n), fresh: t("New air purifier"), title: t("Air Purifier Devices"), add: t("Add Purifier"), badge: t("Air Purifier") },
    dehumidifierDevices: { count: (n) => tn("{n} dehumidifier", "{n} dehumidifiers", n), fresh: t("New dehumidifier"), title: t("Dehumidifier Devices"), add: t("Add Dehumidifier"), badge: t("Dehumidifier") },
    diffuserDevices: { count: (n) => tn("{n} diffuser", "{n} diffusers", n), fresh: t("New diffuser"), title: t("Diffuser Devices"), add: t("Add Diffuser"), badge: t("Diffuser") },
    kettleDevices: { count: (n) => tn("{n} kettle", "{n} kettles", n), fresh: t("New kettle"), title: t("Kettle Devices"), add: t("Add Kettle"), badge: t("Kettle") },
    iceMakerDevices: { count: (n) => tn("{n} ice maker", "{n} ice makers", n), fresh: t("New ice maker"), title: t("Ice Maker Devices"), add: t("Add Ice Maker"), badge: t("Ice Maker") },
  };

  // MARK: State

  let found = [];                     // the devices the plugin found at its start (account and LAN)
  let live = {};                      // the running devices by id: name, transports, a light's scenes
  let signedIn = true;
  const sceneLibraries = {};          // cloud scene libraries by device id
  const iconCache = new Map();
  const openTypes = new Set();
  let browsing = null;                // the light whose Scene Library shows

  /// The type list a model goes in; unknown models are lights.
  const typeFor = (model, given) => (given && typeNames[given] ? given : "lightDevices");

  // MARK: Problems, with the Assistant's Explain when there is one

  /// Error text for the Assistant: Govee's device ids (six to eight bytes) masked; the server masks e-mail and IP
  /// addresses.
  const scrub = (text) => String(text ?? "").replace(/\b[0-9a-f]{2}(?::[0-9a-f]{2}){5,7}\b/gi, "<device id>");

  function problem(container, message, context, device, kind = "error") {
    container.replaceChildren(el("div", { class: "problem" }, el("p", { class: kind, text: message }), explain({ error: scrub(message), context, device })));
  }

  // MARK: Devices tab

  function transportsOf(device) {
    const running = live[device.deviceId];
    if (!running) return null;
    const states = { enabled: t("enabled"), disabled: t("disabled") };
    const pill = (label, state) => (state === "unsupported" ? null : el("span", { class: `pill ${state === "enabled" ? "on" : ""}`, text: label, title: t("{transport}: {state}", { transport: label, state: states[state] ?? state }) }));
    return el("span", { class: "transports" }, pill("LAN", running.lan), pill("AWS", running.aws), pill("BLE", running.ble));
  }

  /// The devices to list: those found at the start, and those running that were not.
  function listed() {
    const all = [...found];
    for (const [deviceId, running] of Object.entries(live)) {
      if (!all.some((device) => device.deviceId === deviceId)) all.push({ deviceId, deviceName: running.name, model: running.model, deviceType: running.list, onBridge: true });
    }
    return all;
  }

  function drawTypes() {
    const devices = listed();
    const container = $("#device-types");
    if (!devices.length) {
      container.replaceChildren(el("p", { class: "muted note", text: t("No devices yet: the plugin lists those of your Govee account and of the LAN once it has started.") }));
      return;
    }
    container.replaceChildren(...Object.keys(typeNames).map((type) => {
      const ofType = devices.filter((device) => typeFor(device.model, device.deviceType) === type);
      if (!ofType.length) return null;
      const names = typeNames[type];
      const section = el("details", { class: "entry type", open: openTypes.has(type) },
        el("summary", {}, el("span", { class: "pill count on", text: String(ofType.length) }), el("span", { class: "entry-name", text: names.title })),
        el("div", { class: "type-body" },
          el("div", { class: "rows" }, ofType.map((device) => {
            const label = live[device.deviceId]?.name || device.deviceName || device.deviceId;
            const state = device.excluded ? el("span", { class: "pill", text: t("Excluded") })
              : device.onBridge || live[device.deviceId] ? null : el("span", { class: "pill", text: t("Not on the bridge") });
            return el("div", { class: `row-device ${device.excluded ? "ignored" : ""}` },
              el("div", { class: "who" },
                el("strong", {}, label, state, transportsOf(device)),
                el("span", { class: "mono", text: [device.deviceId, device.model].filter(Boolean).join(" · ") })),
              el("span", { class: "links" },
                type === "lightDevices" && device.model ? el("button", { actionIcon: "sparkle", class: "link", text: t("Scenes"), "aria-label": t("Scene Library of {name}", { name: label }), onclick: () => browse(device, label) }) : null,
                el("a", { class: "button link", href: deviceSettings(device.deviceId), actionIcon: "gear", text: t("Settings"), "aria-label": t("Settings of {name}", { name: label }) })));
          })),
          browsing && typeFor(browsing.device.model, browsing.device.deviceType) === type ? library : null));
      section.addEventListener("toggle", () => { if (section.open) openTypes.add(type); else openTypes.delete(type); });
      return section;
    }).filter(Boolean));
  }

  /// Redraws the lists; the Scene Library keeps its place and scroll.
  function renderTypes() {
    drawTypes();
    $("#signed-out").classList.toggle("hidden", signedIn);
  }

  // MARK: The Scene Library, to browse: a light's scenes are its settings

  const library = $("#library");

  function browse(device, label) {
    browsing = { device, label };
    openTypes.add(typeFor(device.model, device.deviceType));
    library.classList.remove("hidden");
    library.replaceChildren(
      el("div", { class: "editor-head" },
        el("div", {}, el("h2", { text: label }), el("p", { class: "muted note", text: t("Scene Library · {model}", { model: device.model }) })),
        el("button", { actionIcon: "restore", class: "link", text: t("Back"), onclick: closeLibrary })),
      el("p", { class: "muted", text: t("The scenes Govee offers for this light and your own DIY effects. Those with a tick are the light's switches in HomeKit. A scene becomes one in the light's settings (Scenes), with the name and the code a tile shows here; the Assistant can add it for you.") }),
      el("div", { id: "picker-status" }),
      el("div", { id: "picker-body" }, el("p", { class: "muted", text: t("Loading scenes…") })),
      el("div", { id: "scene-detail" }),
      el("div", { class: "picker-foot" }, el("span", { id: "picker-count", class: "muted" }),
        el("a", { class: "button", href: deviceSettings(device.deviceId), actionIcon: "gear", text: t("Open the light's settings") })));
    renderTypes();
    breadcrumb(t("Scenes of {name}", { name: label }), closeLibrary);
    library.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
    loadPicker(device);
  }

  function closeLibrary() {
    browsing = null;
    library.classList.add("hidden");
    library.replaceChildren();
    breadcrumb(null);
    renderTypes();
  }

  function iconFor(scene, large = false) {
    const url = scene.iconUrl || scene.iconUrlDark;
    const className = `scene-icon ${large ? "large" : ""}`;
    if (!url) return el("span", { class: `${className} empty`, "aria-hidden": "true" });
    const cached = iconCache.get(url);
    const image = el("img", { class: className, alt: "" });
    if (cached) image.src = cached; else image.dataset.iconUrl = url;
    return image;
  }

  function devicePayload(device) {
    return { deviceId: device.deviceId, model: device.model || "", goodsType: device.goodsType, pactType: device.pactType, pactCode: device.pactCode, versionSoft: device.versionSoft, versionHard: device.versionHard };
  }

  async function loadPicker(device) {
    const body = $("#picker-body");
    if (!body) return;
    try {
      let scenes = sceneLibraries[device.deviceId];
      if (!scenes) {
        scenes = await request("scenes", { method: "POST", body: devicePayload(device) });
        // The bundled fallback is never kept: a sign-in later must reach the device's own list.
        if (scenes?.source !== "offline") sceneLibraries[device.deviceId] = scenes;
      }
      let diys = [];
      try { diys = (await request("diys", { method: "POST", body: devicePayload(device) }))?.diys || []; } catch { diys = []; }
      if (!$("#picker-body") || browsing?.device !== device) return;
      renderPicker(scenes, diys);
    } catch (e) {
      problem(body, e.message || t("Could not load scenes"),
        "Loading the Govee scene library and DIY effects for one light on the plugin's page failed (the bundled catalogue had no entry for this model either).",
        { model: device.model });
    }
  }

  let pickerItems = {};
  let pickerCategory = null;

  function renderPicker(scenes, diys) {
    const body = $("#picker-body");
    const notes = [];
    if (scenes.source === "offline") notes.push(t("Showing the scene list bundled with the plugin. Sign in to your Govee account for the full, device-specific list."));
    if (scenes.warning) notes.push(HomeswiftI18n.message(scenes.warning));
    $("#picker-status").replaceChildren(...notes.map((note) => el("p", { class: "notice", text: note })));

    const groups = scenes.categories.map((category) => ({
      id: `cat-${category.id}`, name: category.name,
      items: category.scenes.map((scene) => ({ key: `scene:${scene.sceneId}`, name: scene.name, iconUrl: scene.iconUrl, iconUrlDark: scene.iconUrlDark, variants: scene.variants, code: scene.code, sceneId: scene.sceneId, kind: "scene" })),
    }));
    if (diys.length) {
      groups.push({ id: "cat-diy", name: t("My DIY"), items: diys.map((diy) => ({ key: `diy:${diy.diyId}`, name: diy.name, iconUrl: diy.iconUrl, variants: [], code: diy.code, sceneId: diy.diyId, kind: "diy" })) });
    }
    if (!groups.length) {
      body.replaceChildren(el("p", { class: "notice", text: t("Govee returned no scenes for this device.") }));
      return;
    }
    pickerItems = {};
    for (const group of groups) for (const item of group.items) pickerItems[item.key] = item;
    if (!groups.some((g) => g.id === pickerCategory)) pickerCategory = groups[0].id;

    const grid = el("div", { class: "picker-grid" });
    const showCategory = (group) => {
      pickerCategory = group.id;
      for (const button of cats.children) button.classList.toggle("on", button.dataset.id === group.id);
      grid.replaceChildren(...group.items.map((item) => el("button", { class: "tile-scene", "data-key": item.key, "aria-pressed": "false", title: item.name, onclick: () => showScene(item.key) },
        iconFor(item, true), el("span", { class: "name", text: item.name }),
        item.variants.length > 1 ? el("span", { class: "pill variants", text: String(item.variants.length) }) : null)));
      refreshPicker();
      hydrateIcons(grid);
    };
    // Categories down the side: their names are long and a strip across the top had to scroll.
    const cats = el("div", { class: "picker-cats", role: "tablist" }, groups.map((group) => el("button", {
      "data-id": group.id, role: "tab", onclick: () => showCategory(group),
    }, el("span", { text: group.name }), el("span", { class: "count", text: String(group.items.length) }))));
    body.replaceChildren(el("div", { class: "picker" }, cats, grid));
    showCategory(groups.find((g) => g.id === pickerCategory));
  }

  /// A scene's name, id and code, to copy into the light's settings.
  function showScene(key) {
    const item = pickerItems[key];
    const detail = $("#scene-detail");
    if (!item || !detail) return;
    for (const tile of document.querySelectorAll("#picker-body .tile-scene")) tile.setAttribute("aria-pressed", String(tile.dataset.key === key));
    const copy = (text) => el("button", { actionIcon: "copy", class: "link", text: t("Copy"), onclick: async (event) => {
      // common.js's copy, which works over plain HTTP too; the button is kept before the await (currentTarget is not after).
      const button = event.currentTarget;
      try { await HomeswiftCommon.copyText(text); button.textContent = t("Copied"); } catch { /* the code stays selectable */ }
    } });
    const row = (label, value) => el("div", { class: "scene-field" }, el("span", { class: "muted", text: label }), el("span", { class: "mono", text: String(value) }), copy(String(value)));
    detail.replaceChildren(el("div", { class: "scene-panel" },
      el("div", { class: "scene-panel-head" }, el("div", {}, el("strong", { text: item.name }), el("p", { class: "muted", text: item.kind === "diy" ? t("DIY Effect") : t("Scene") }))),
      el("div", { class: "scene-panel-body" }, row(t("Name"), item.name), row(t("Scene Code"), item.code || ""), row(t("Govee Scene ID"), item.sceneId), row(t("Kind"), item.kind))));
  }

  /// Ticks the scenes the light's settings have.
  function refreshPicker() {
    const selected = new Set(live[browsing?.device.deviceId]?.scenes || []);
    for (const tile of document.querySelectorAll("#picker-body .tile-scene")) tile.classList.toggle("selected", selected.has(tile.dataset.key));
    const count = $("#picker-count");
    if (count) count.textContent = tn("{n} scene in HomeKit", "{n} scenes in HomeKit", selected.size);
  }

  // MARK: Scene icons, proxied by the plugin in batches as their tiles come into view

  const iconQueue = new Map();
  let iconTimer = null;

  async function flushIcons() {
    iconTimer = null;
    const pending = [...iconQueue];
    iconQueue.clear();
    for (let start = 0; start < pending.length; start += 60) {
      const batch = pending.slice(start, start + 60);
      try {
        const icons = (await request("scene-icons", { method: "POST", body: { urls: batch.map(([url]) => url) } }))?.icons || {};
        for (const [url, images] of batch) {
          if (icons[url]) iconCache.set(url, icons[url]);
          for (const image of images) { if (icons[url]) image.src = icons[url]; else image.classList.add("empty"); }
        }
      } catch {
        for (const [, images] of batch) images.forEach((image) => image.classList.add("empty"));
      }
    }
  }

  function queueIcon(image) {
    const url = image.dataset.iconUrl;
    if (!url) return;
    delete image.dataset.iconUrl;
    if (iconCache.has(url)) { image.src = iconCache.get(url); return; }
    if (iconQueue.has(url)) { iconQueue.get(url).push(image); return; }
    iconQueue.set(url, [image]);
    if (!iconTimer) iconTimer = setTimeout(flushIcons, 60);
  }

  function hydrateIcons(root) {
    const pending = root.querySelectorAll("img[data-icon-url]");
    if (!pending.length) return;
    if (typeof IntersectionObserver !== "function") { pending.forEach(queueIcon); return; }
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) { observer.unobserve(entry.target); queueIcon(entry.target); }
    }, { rootMargin: "200px" });
    pending.forEach((image) => observer.observe(image));
  }

  const hydrateObserver = new MutationObserver(() => hydrateIcons(library));
  hydrateObserver.observe(library, { childList: true, subtree: true });

  // MARK: Discovery

  /// Asks Govee for the account's devices now: what it answers, beside the devices the plugin found at its start.
  async function discover(button) {
    const result = $("#discover-result");
    result.replaceChildren();
    await act(button, async () => {
      try {
        const devices = (await request("discover", { method: "POST", body: {} })).devices || [];
        if (!devices.length) { result.replaceChildren(el("p", { class: "summary", text: t("No devices found.") })); return; }
        const fresh = devices.filter((device) => device.deviceId && !found.some((known) => known.deviceId === device.deviceId));
        result.replaceChildren(
          el("p", { class: "summary", text: fresh.length
            ? tn("{n} device is new since the plugin started: it is added when the plugin starts again.", "{n} devices are new since the plugin started: they are added when the plugin starts again.", fresh.length)
            : t("The plugin already has every device of the account.") }),
          el("ul", { class: "found" }, devices.map((device) => el("li", {},
            el("div", {}, el("strong", { text: device.deviceName || t("Unknown") }), " ",
              el("span", { class: "pill", text: typeNames[typeFor(device.model, device.deviceType)].badge }),
              el("div", { class: "muted note", text: t("Model: {model}", { model: device.model || t("Unknown") }) })),
            el("span", { class: "mono", text: device.deviceId || "" })))));
      } catch (e) {
        problem(result, t("Error: {error}", { error: e.message || t("Unknown error") }), "Discover Devices asked the Govee cloud for the account's device list with the plugin's login, and it failed.");
      }
    });
  }

  // MARK: Tools

  async function clearCache(button) {
    if (!await HomeswiftCommon.confirmDialog(t("Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards."))) return;
    const result = $("#clear-result");
    await act(button, async () => {
      try {
        const answer = await request("clear-cache", { method: "POST", body: {} });
        if (answer.success) {
          result.replaceChildren(el("p", { class: "status-line ok", text: HomeswiftI18n.message(answer.message) }));
          $("#restart").classList.remove("hidden");
        } else {
          problem(result, HomeswiftI18n.message(answer.message) || t("Cache partially cleared"), "Clear Cache deletes the plugin's saved login, IoT certificate and device data; some could not be removed.", undefined, "error");
        }
      } catch (e) {
        problem(result, e.message || t("Failed to clear cache"), "Clear Cache (the plugin's saved login, IoT certificate and device data) failed.");
      }
    });
  }

  async function restart(button) {
    await act(button, async () => {
      await api("/api/restart", { method: "POST", body: {} });
      $("#clear-result").replaceChildren(el("p", { class: "status-line", text: t("Restarting…") }));
      for (let tries = 0; tries < 60; tries++) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        try { await request("devices"); break; } catch { /* not back yet */ }
      }
      location.reload();
    });
  }

  // MARK: Start

  for (const button of document.querySelectorAll(".main-tabs button")) {
    button.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".main-tabs button")) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`).classList.toggle("hidden", !on);
      }
    });
  }
  $("#discover").addEventListener("click", (event) => discover(event.currentTarget));
  $("#sign-in").href = setupAddress({ start: true });
  $("#clear-cache").addEventListener("click", (event) => clearCache(event.currentTarget));
  $("#restart").addEventListener("click", (event) => restart(event.currentTarget));

  async function refreshLive() {
    try {
      const answer = await request("devices");
      // Only what the rows show: lastUpdate changes with every report, and a redraw every five seconds would
      // take the focus off a row's button and flicker the lists.
      const next = {};
      for (const device of answer.devices || []) next[device.deviceId] = { name: device.name, model: device.model, list: device.list, lan: device.lan, aws: device.aws, ble: device.ble, scenes: device.scenes };
      const changed = JSON.stringify(next) !== JSON.stringify(live) || answer.signedIn !== signedIn;
      live = next;
      signedIn = answer.signedIn !== false;
      if (changed) { renderTypes(); refreshPicker(); }
    } catch { /* the plugin may be restarting */ }
  }

  (async () => {
    try { found = (await request("cached-devices")).devices || []; } catch { /* the plugin may be restarting */ }
    for (const device of found) openTypes.add(typeFor(device.model, device.deviceType));
    renderTypes();
    poll(refreshLive, 5000);
  })();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Govee page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "DIY Effect": "Effet DIY",
    "Govee Scene ID": "Identifiant de scène Govee",
    "Scene Code": "Code de scène",
    "Not on the bridge": "Pas sur le pont",
    "Open the light's settings": "Ouvrir les réglages de la lampe",
    "No devices yet: the plugin lists those of your Govee account and of the LAN once it has started.": "Aucun appareil pour l'instant : le plugin liste ceux de votre compte Govee et du réseau local une fois démarré.",
    "Not signed in to a Govee account: the plugin uses LAN and Bluetooth only. Add accessories signs in.": "Pas de compte Govee connecté : le plugin n'utilise que le réseau local et le Bluetooth. Ajouter des accessoires vous connecte.",
    "Scene Library of {name}": "Bibliothèque de scènes de {name}",
    "Scene Library · {model}": "Bibliothèque de scènes · {model}",
    "Scenes of {name}": "Scènes de {name}",
    "Showing the scene list bundled with the plugin. Sign in to your Govee account for the full, device-specific list.": "Liste des scènes fournie avec le plugin. Connectez-vous à votre compte Govee pour la liste complète, propre à l'appareil.",
    "The devices of your Govee account and of the LAN, as the plugin found them at its start. A device's Settings name it, leave it out, or choose how it appears in the Home app.": "Les appareils de votre compte Govee et du réseau local, tels que le plugin les a trouvés à son démarrage. Les réglages d'un appareil le nomment, le laissent de côté ou choisissent comment il apparaît dans l'app Maison.",
    "The devices your Govee account and the LAN bring to the Home app, how the plugin reaches each one, and the scenes of your lights.": "Les appareils que votre compte Govee et le réseau local amènent dans l'app Maison, comment le plugin joint chacun, et les scènes de vos lampes.",
    "The plugin already has every device of the account.": "Le plugin a déjà tous les appareils du compte.",
    "The scenes Govee offers for this light and your own DIY effects. Those with a tick are the light's switches in HomeKit. A scene becomes one in the light's settings (Scenes), with the name and the code a tile shows here; the Assistant can add it for you.": "Les scènes que Govee propose pour cette lampe et vos propres effets DIY. Celles qui sont cochées sont les interrupteurs de la lampe dans HomeKit. Une scène en devient un dans les réglages de la lampe (Scènes), avec le nom et le code qu'une vignette affiche ici ; l'Assistant peut l'ajouter pour vous.",
    "{n} device is new since the plugin started: it is added when the plugin starts again.": "{n} appareil est nouveau depuis le démarrage du plugin : il est ajouté au prochain démarrage.",
    "{n} devices are new since the plugin started: they are added when the plugin starts again.": "{n} appareils sont nouveaux depuis le démarrage du plugin : ils sont ajoutés au prochain démarrage.",
    "{n} scene in HomeKit": "{n} scène dans HomeKit",
    "{n} scenes in HomeKit": "{n} scènes dans HomeKit",
    "New light": "Nouvelle lampe",
    "Light Devices": "Lampes",
    "Add Light Device": "Ajouter une lampe",
    "Light": "Lampe",
    "New switch/outlet": "Nouvel interrupteur/prise",
    "Switch/Outlet Devices": "Interrupteurs et prises",
    "Add Switch Device": "Ajouter un interrupteur",
    "Switch/Outlet": "Interrupteur/prise",
    "New temperature/humidity sensor": "Nouveau capteur de température/humidité",
    "Temperature/Humidity Sensors": "Capteurs de température/humidité",
    "Add Sensor": "Ajouter un capteur",
    "Temp/Humidity Sensor": "Capteur temp./humidité",
    "New leak sensor": "Nouveau capteur de fuite",
    "Leak Sensors": "Capteurs de fuite",
    "Add Leak Sensor": "Ajouter un capteur de fuite",
    "Leak Sensor": "Capteur de fuite",
    "New fan": "Nouveau ventilateur",
    "Fan Devices": "Ventilateurs",
    "Add Fan": "Ajouter un ventilateur",
    "Fan": "Ventilateur",
    "New heater": "Nouveau radiateur",
    "Heater Devices": "Radiateurs",
    "Add Heater": "Ajouter un radiateur",
    "Heater": "Radiateur",
    "New humidifier": "Nouvel humidificateur",
    "Humidifier Devices": "Humidificateurs",
    "Add Humidifier": "Ajouter un humidificateur",
    "Humidifier": "Humidificateur",
    "New air purifier": "Nouveau purificateur d'air",
    "Air Purifier Devices": "Purificateurs d'air",
    "Add Purifier": "Ajouter un purificateur",
    "Air Purifier": "Purificateur d'air",
    "New dehumidifier": "Nouveau déshumidificateur",
    "Dehumidifier Devices": "Déshumidificateurs",
    "Add Dehumidifier": "Ajouter un déshumidificateur",
    "Dehumidifier": "Déshumidificateur",
    "New diffuser": "Nouveau diffuseur",
    "Diffuser Devices": "Diffuseurs",
    "Add Diffuser": "Ajouter un diffuseur",
    "Diffuser": "Diffuseur",
    "New kettle": "Nouvelle bouilloire",
    "Kettle Devices": "Bouilloires",
    "Add Kettle": "Ajouter une bouilloire",
    "Kettle": "Bouilloire",
    "New ice maker": "Nouvelle machine à glaçons",
    "Ice Maker Devices": "Machines à glaçons",
    "Add Ice Maker": "Ajouter une machine à glaçons",
    "Ice Maker": "Machine à glaçons",
    "{n} light": "{n} lampe",
    "{n} lights": "{n} lampes",
    "{n} switch/outlet": "{n} interrupteur/prise",
    "{n} switches/outlets": "{n} interrupteurs/prises",
    "{n} temperature/humidity sensor": "{n} capteur de température/humidité",
    "{n} temperature/humidity sensors": "{n} capteurs de température/humidité",
    "{n} leak sensor": "{n} capteur de fuite",
    "{n} leak sensors": "{n} capteurs de fuite",
    "{n} fan": "{n} ventilateur",
    "{n} fans": "{n} ventilateurs",
    "{n} heater": "{n} radiateur",
    "{n} heaters": "{n} radiateurs",
    "{n} humidifier": "{n} humidificateur",
    "{n} humidifiers": "{n} humidificateurs",
    "{n} air purifier": "{n} purificateur d'air",
    "{n} air purifiers": "{n} purificateurs d'air",
    "{n} dehumidifier": "{n} déshumidificateur",
    "{n} dehumidifiers": "{n} déshumidificateurs",
    "{n} diffuser": "{n} diffuseur",
    "{n} diffusers": "{n} diffuseurs",
    "{n} kettle": "{n} bouilloire",
    "{n} kettles": "{n} bouilloires",
    "{n} ice maker": "{n} machine à glaçons",
    "{n} ice makers": "{n} machines à glaçons",
    "enabled": "activé",
    "disabled": "désactivé",
    "{transport}: {state}": "{transport} : {state}",
    "Back": "Retour",
    "Loading scenes…": "Chargement des scènes…",
    "Scene": "Scène",
    "Could not load scenes": "Impossible de charger les scènes",
    "My DIY": "Mes effets DIY",
    "Govee returned no scenes for this device.": "Govee n'a renvoyé aucune scène pour cet appareil.",
    "No devices found.": "Aucun appareil trouvé.",
    "Unknown": "Inconnu",
    "Model: {model}": "Modèle : {model}",
    "Error: {error}": "Erreur : {error}",
    "Unknown error": "Erreur inconnue",
    "Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards.": "Vider le cache ? Cela supprime la connexion enregistrée, le certificat IoT et les données des appareils. Redémarrez Homeswift ensuite.",
    "Cache partially cleared": "Cache vidé en partie",
    "Failed to clear cache": "Impossible de vider le cache",
    "Restarting…": "Redémarrage…",
    "Settings": "Réglages",
    "Devices": "Appareils",
    "Tools": "Outils",
    "Discover Devices": "Découvrir les appareils",
    "Cache Management": "Gestion du cache",
    "Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.": "Videz le cache du plugin si la découverte des appareils se comporte mal ou si les données semblent périmées : la connexion et le certificat IoT enregistrés, les appareils découverts, l'état enregistré des appareils. Redémarrez Homeswift ensuite.",
    "Clear Cache": "Vider le cache",
    "Restart Homeswift": "Redémarrer Homeswift",
    "Documentation": "Documentation",
    "The options are described in the plugin's README; the connections are tried in this order:": "Les options sont décrites dans le README du plugin ; les connexions sont essayées dans cet ordre :",
    "local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.": "contrôle par le réseau local (plus rapide, fonctionne sans internet), pour les modèles dont l'API LAN est activée dans l'app Govee.",
    "real-time control through Govee's cloud (requires credentials).": "contrôle en temps réel par le cloud de Govee (nécessite des identifiants).",
    "Bluetooth control for nearby devices (requires a Bluetooth adapter).": "contrôle Bluetooth des appareils à proximité (nécessite un adaptateur Bluetooth).",
    "Username and password are required": "Le nom d'utilisateur et le mot de passe sont requis",
    "Sign in to your Govee account on Add accessories first.": "Connectez-vous d'abord à votre compte Govee dans Ajouter des accessoires.",
    "Login successful. Account ID: {0}": "Connexion réussie. Identifiant du compte : {0}",
    "Cache cleared successfully. Please restart Homeswift to apply changes.": "Cache vidé. Redémarrez Homeswift pour appliquer les modifications.",
    "Cache partially cleared. Errors: {0}": "Cache vidé en partie. Erreurs : {0}",
    "A device ID and model are required to load scenes.": "Un identifiant d'appareil et un modèle sont requis pour charger les scènes.",
    "A device ID and model are required to load DIY effects.": "Un identifiant d'appareil et un modèle sont requis pour charger les effets DIY.",
    "A device ID and model are required.": "Un identifiant d'appareil et un modèle sont requis.",
    "Govee login failed: {0}": "Échec de la connexion à Govee : {0}",
    "Request failed with status code {0}": "La requête a échoué avec le code {0}",
    "Govee scene library response did not contain any categories": "La réponse de la bibliothèque de scènes Govee ne contenait aucune catégorie",
    "nothing at {0} {1}": "rien à {0} {1}"
  },
  "es": {
    "DIY Effect": "Efecto DIY",
    "Govee Scene ID": "ID de escena de Govee",
    "Scene Code": "Código de escena",
    "Not on the bridge": "No está en el puente",
    "Open the light's settings": "Abrir los ajustes de la luz",
    "No devices yet: the plugin lists those of your Govee account and of the LAN once it has started.": "Aún no hay dispositivos: el plugin muestra los de tu cuenta de Govee y los de la red local cuando se inicia.",
    "Not signed in to a Govee account: the plugin uses LAN and Bluetooth only. Add accessories signs in.": "Sin una cuenta de Govee: el plugin solo usa la red local y Bluetooth. Añadir accesorios inicia la sesión.",
    "Scene Library of {name}": "Biblioteca de escenas de {name}",
    "Scene Library · {model}": "Biblioteca de escenas · {model}",
    "Scenes of {name}": "Escenas de {name}",
    "Showing the scene list bundled with the plugin. Sign in to your Govee account for the full, device-specific list.": "Se muestra la lista de escenas incluida con el plugin. Inicia sesión en tu cuenta de Govee para ver la lista completa del dispositivo.",
    "The devices of your Govee account and of the LAN, as the plugin found them at its start. A device's Settings name it, leave it out, or choose how it appears in the Home app.": "Los dispositivos de tu cuenta de Govee y de la red local, tal como el plugin los encontró al iniciarse. Los ajustes de un dispositivo le dan nombre, lo dejan fuera o eligen cómo aparece en la app Casa.",
    "The devices your Govee account and the LAN bring to the Home app, how the plugin reaches each one, and the scenes of your lights.": "Los dispositivos que tu cuenta de Govee y la red local llevan a la app Casa, cómo llega el plugin a cada uno y las escenas de tus luces.",
    "The plugin already has every device of the account.": "El plugin ya tiene todos los dispositivos de la cuenta.",
    "The scenes Govee offers for this light and your own DIY effects. Those with a tick are the light's switches in HomeKit. A scene becomes one in the light's settings (Scenes), with the name and the code a tile shows here; the Assistant can add it for you.": "Las escenas que Govee ofrece para esta luz y tus propios efectos DIY. Las marcadas son los interruptores de la luz en HomeKit. Una escena se convierte en uno en los ajustes de la luz (Escenas), con el nombre y el código que muestra aquí su recuadro; el Asistente puede añadirla por ti.",
    "{n} device is new since the plugin started: it is added when the plugin starts again.": "{n} dispositivo es nuevo desde que se inició el plugin: se añade cuando el plugin se vuelva a iniciar.",
    "{n} devices are new since the plugin started: they are added when the plugin starts again.": "{n} dispositivos son nuevos desde que se inició el plugin: se añaden cuando el plugin se vuelva a iniciar.",
    "{n} scene in HomeKit": "{n} escena en HomeKit",
    "{n} scenes in HomeKit": "{n} escenas en HomeKit",
    "New light": "Nueva luz",
    "Light Devices": "Luces",
    "Add Light Device": "Añadir luz",
    "Light": "Luz",
    "New switch/outlet": "Nuevo interruptor/enchufe",
    "Switch/Outlet Devices": "Interruptores y enchufes",
    "Add Switch Device": "Añadir interruptor",
    "Switch/Outlet": "Interruptor/enchufe",
    "New temperature/humidity sensor": "Nuevo sensor de temperatura/humedad",
    "Temperature/Humidity Sensors": "Sensores de temperatura/humedad",
    "Add Sensor": "Añadir sensor",
    "Temp/Humidity Sensor": "Sensor de temp./humedad",
    "New leak sensor": "Nuevo sensor de fugas",
    "Leak Sensors": "Sensores de fugas",
    "Add Leak Sensor": "Añadir sensor de fugas",
    "Leak Sensor": "Sensor de fugas",
    "New fan": "Nuevo ventilador",
    "Fan Devices": "Ventiladores",
    "Add Fan": "Añadir ventilador",
    "Fan": "Ventilador",
    "New heater": "Nuevo calefactor",
    "Heater Devices": "Calefactores",
    "Add Heater": "Añadir calefactor",
    "Heater": "Calefactor",
    "New humidifier": "Nuevo humidificador",
    "Humidifier Devices": "Humidificadores",
    "Add Humidifier": "Añadir humidificador",
    "Humidifier": "Humidificador",
    "New air purifier": "Nuevo purificador de aire",
    "Air Purifier Devices": "Purificadores de aire",
    "Add Purifier": "Añadir purificador",
    "Air Purifier": "Purificador de aire",
    "New dehumidifier": "Nuevo deshumidificador",
    "Dehumidifier Devices": "Deshumidificadores",
    "Add Dehumidifier": "Añadir deshumidificador",
    "Dehumidifier": "Deshumidificador",
    "New diffuser": "Nuevo difusor",
    "Diffuser Devices": "Difusores",
    "Add Diffuser": "Añadir difusor",
    "Diffuser": "Difusor",
    "New kettle": "Nuevo hervidor",
    "Kettle Devices": "Hervidores",
    "Add Kettle": "Añadir hervidor",
    "Kettle": "Hervidor",
    "New ice maker": "Nueva máquina de hielo",
    "Ice Maker Devices": "Máquinas de hielo",
    "Add Ice Maker": "Añadir máquina de hielo",
    "Ice Maker": "Máquina de hielo",
    "{n} light": "{n} luz",
    "{n} lights": "{n} luces",
    "{n} switch/outlet": "{n} interruptor/enchufe",
    "{n} switches/outlets": "{n} interruptores/enchufes",
    "{n} temperature/humidity sensor": "{n} sensor de temperatura/humedad",
    "{n} temperature/humidity sensors": "{n} sensores de temperatura/humedad",
    "{n} leak sensor": "{n} sensor de fugas",
    "{n} leak sensors": "{n} sensores de fugas",
    "{n} fan": "{n} ventilador",
    "{n} fans": "{n} ventiladores",
    "{n} heater": "{n} calefactor",
    "{n} heaters": "{n} calefactores",
    "{n} humidifier": "{n} humidificador",
    "{n} humidifiers": "{n} humidificadores",
    "{n} air purifier": "{n} purificador de aire",
    "{n} air purifiers": "{n} purificadores de aire",
    "{n} dehumidifier": "{n} deshumidificador",
    "{n} dehumidifiers": "{n} deshumidificadores",
    "{n} diffuser": "{n} difusor",
    "{n} diffusers": "{n} difusores",
    "{n} kettle": "{n} hervidor",
    "{n} kettles": "{n} hervidores",
    "{n} ice maker": "{n} máquina de hielo",
    "{n} ice makers": "{n} máquinas de hielo",
    "enabled": "activado",
    "disabled": "desactivado",
    "{transport}: {state}": "{transport}: {state}",
    "Back": "Atrás",
    "Loading scenes…": "Cargando escenas…",
    "Scene": "Escena",
    "Could not load scenes": "No se han podido cargar las escenas",
    "My DIY": "Mis DIY",
    "Govee returned no scenes for this device.": "Govee no ha devuelto ninguna escena para este dispositivo.",
    "No devices found.": "No se han encontrado dispositivos.",
    "Unknown": "Desconocido",
    "Model: {model}": "Modelo: {model}",
    "Error: {error}": "Error: {error}",
    "Unknown error": "Error desconocido",
    "Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards.": "¿Vaciar la caché? Se borran el inicio de sesión guardado, el certificado IoT y los datos de los dispositivos. Reinicia Homeswift después.",
    "Cache partially cleared": "Caché vaciada en parte",
    "Failed to clear cache": "No se ha podido vaciar la caché",
    "Restarting…": "Reiniciando…",
    "Settings": "Ajustes",
    "Devices": "Dispositivos",
    "Tools": "Herramientas",
    "Discover Devices": "Detectar dispositivos",
    "Cache Management": "Gestión de la caché",
    "Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.": "Vacía la caché del plugin si la detección de dispositivos falla o los datos parecen desfasados: el inicio de sesión y el certificado IoT guardados, los dispositivos detectados y su estado guardado. Reinicia Homeswift después.",
    "Clear Cache": "Vaciar la caché",
    "Restart Homeswift": "Reiniciar Homeswift",
    "Documentation": "Documentación",
    "The options are described in the plugin's README; the connections are tried in this order:": "Las opciones se describen en el README del plugin; las conexiones se prueban en este orden:",
    "local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.": "control por la red local (más rápido, funciona sin internet), para los modelos con la API LAN activada en la app Govee.",
    "real-time control through Govee's cloud (requires credentials).": "control en tiempo real por la nube de Govee (requiere credenciales).",
    "Bluetooth control for nearby devices (requires a Bluetooth adapter).": "control por Bluetooth de los dispositivos cercanos (requiere un adaptador Bluetooth).",
    "Username and password are required": "Se necesitan el nombre de usuario y la contraseña",
    "Sign in to your Govee account on Add accessories first.": "Inicia sesión primero en tu cuenta de Govee en Añadir accesorios.",
    "Login successful. Account ID: {0}": "Sesión iniciada. ID de la cuenta: {0}",
    "Cache cleared successfully. Please restart Homeswift to apply changes.": "Caché vaciada. Reinicia Homeswift para aplicar los cambios.",
    "Cache partially cleared. Errors: {0}": "Caché vaciada en parte. Errores: {0}",
    "A device ID and model are required to load scenes.": "Se necesitan un ID de dispositivo y un modelo para cargar las escenas.",
    "A device ID and model are required to load DIY effects.": "Se necesitan un ID de dispositivo y un modelo para cargar los efectos DIY.",
    "A device ID and model are required.": "Se necesitan un ID de dispositivo y un modelo.",
    "Govee login failed: {0}": "No se ha podido iniciar sesión en Govee: {0}",
    "Request failed with status code {0}": "La solicitud ha fallado con el código {0}",
    "Govee scene library response did not contain any categories": "La respuesta de la biblioteca de escenas de Govee no contenía ninguna categoría",
    "nothing at {0} {1}": "no hay nada en {0} {1}"
  },
  "pt": {
    "DIY Effect": "Efeito DIY",
    "Govee Scene ID": "ID de cena Govee",
    "Scene Code": "Código da cena",
    "Not on the bridge": "Fora da ponte",
    "Open the light's settings": "Abrir as definições da luz",
    "No devices yet: the plugin lists those of your Govee account and of the LAN once it has started.": "Ainda sem dispositivos: o plugin mostra os da sua conta Govee e os da rede local quando arranca.",
    "Not signed in to a Govee account: the plugin uses LAN and Bluetooth only. Add accessories signs in.": "Sem sessão numa conta Govee: o plugin usa só a rede local e o Bluetooth. Adicionar acessórios inicia a sessão.",
    "Scene Library of {name}": "Biblioteca de cenas de {name}",
    "Scene Library · {model}": "Biblioteca de cenas · {model}",
    "Scenes of {name}": "Cenas de {name}",
    "Showing the scene list bundled with the plugin. Sign in to your Govee account for the full, device-specific list.": "A mostrar a lista de cenas incluída no plugin. Inicie sessão na sua conta Govee para ver a lista completa do dispositivo.",
    "The devices of your Govee account and of the LAN, as the plugin found them at its start. A device's Settings name it, leave it out, or choose how it appears in the Home app.": "Os dispositivos da sua conta Govee e da rede local, tal como o plugin os encontrou ao arrancar. As definições de um dispositivo dão-lhe um nome, deixam-no de fora ou escolhem como aparece na app Casa.",
    "The devices your Govee account and the LAN bring to the Home app, how the plugin reaches each one, and the scenes of your lights.": "Os dispositivos que a sua conta Govee e a rede local trazem para a app Casa, como o plugin chega a cada um e as cenas das suas luzes.",
    "The plugin already has every device of the account.": "O plugin já tem todos os dispositivos da conta.",
    "The scenes Govee offers for this light and your own DIY effects. Those with a tick are the light's switches in HomeKit. A scene becomes one in the light's settings (Scenes), with the name and the code a tile shows here; the Assistant can add it for you.": "As cenas que a Govee oferece para esta luz e os seus próprios efeitos DIY. As assinaladas são os interruptores da luz no HomeKit. Uma cena passa a ser um nas definições da luz (Cenas), com o nome e o código que o seu mosaico mostra aqui; o Assistente pode adicioná-la por si.",
    "{n} device is new since the plugin started: it is added when the plugin starts again.": "{n} dispositivo é novo desde que o plugin arrancou: é adicionado quando o plugin voltar a arrancar.",
    "{n} devices are new since the plugin started: they are added when the plugin starts again.": "{n} dispositivos são novos desde que o plugin arrancou: são adicionados quando o plugin voltar a arrancar.",
    "{n} scene in HomeKit": "{n} cena no HomeKit",
    "{n} scenes in HomeKit": "{n} cenas no HomeKit",
    "New light": "Nova luz",
    "Light Devices": "Luzes",
    "Add Light Device": "Adicionar luz",
    "Light": "Luz",
    "New switch/outlet": "Novo interruptor/tomada",
    "Switch/Outlet Devices": "Interruptores e tomadas",
    "Add Switch Device": "Adicionar interruptor",
    "Switch/Outlet": "Interruptor/tomada",
    "New temperature/humidity sensor": "Novo sensor de temperatura/humidade",
    "Temperature/Humidity Sensors": "Sensores de temperatura/humidade",
    "Add Sensor": "Adicionar sensor",
    "Temp/Humidity Sensor": "Sensor de temp./humidade",
    "New leak sensor": "Novo sensor de fugas",
    "Leak Sensors": "Sensores de fugas",
    "Add Leak Sensor": "Adicionar sensor de fugas",
    "Leak Sensor": "Sensor de fugas",
    "New fan": "Nova ventoinha",
    "Fan Devices": "Ventoinhas",
    "Add Fan": "Adicionar ventoinha",
    "Fan": "Ventoinha",
    "New heater": "Novo aquecedor",
    "Heater Devices": "Aquecedores",
    "Add Heater": "Adicionar aquecedor",
    "Heater": "Aquecedor",
    "New humidifier": "Novo humidificador",
    "Humidifier Devices": "Humidificadores",
    "Add Humidifier": "Adicionar humidificador",
    "Humidifier": "Humidificador",
    "New air purifier": "Novo purificador de ar",
    "Air Purifier Devices": "Purificadores de ar",
    "Add Purifier": "Adicionar purificador",
    "Air Purifier": "Purificador de ar",
    "New dehumidifier": "Novo desumidificador",
    "Dehumidifier Devices": "Desumidificadores",
    "Add Dehumidifier": "Adicionar desumidificador",
    "Dehumidifier": "Desumidificador",
    "New diffuser": "Novo difusor",
    "Diffuser Devices": "Difusores",
    "Add Diffuser": "Adicionar difusor",
    "Diffuser": "Difusor",
    "New kettle": "Nova chaleira",
    "Kettle Devices": "Chaleiras",
    "Add Kettle": "Adicionar chaleira",
    "Kettle": "Chaleira",
    "New ice maker": "Nova máquina de gelo",
    "Ice Maker Devices": "Máquinas de gelo",
    "Add Ice Maker": "Adicionar máquina de gelo",
    "Ice Maker": "Máquina de gelo",
    "{n} light": "{n} luz",
    "{n} lights": "{n} luzes",
    "{n} switch/outlet": "{n} interruptor/tomada",
    "{n} switches/outlets": "{n} interruptores/tomadas",
    "{n} temperature/humidity sensor": "{n} sensor de temperatura/humidade",
    "{n} temperature/humidity sensors": "{n} sensores de temperatura/humidade",
    "{n} leak sensor": "{n} sensor de fugas",
    "{n} leak sensors": "{n} sensores de fugas",
    "{n} fan": "{n} ventoinha",
    "{n} fans": "{n} ventoinhas",
    "{n} heater": "{n} aquecedor",
    "{n} heaters": "{n} aquecedores",
    "{n} humidifier": "{n} humidificador",
    "{n} humidifiers": "{n} humidificadores",
    "{n} air purifier": "{n} purificador de ar",
    "{n} air purifiers": "{n} purificadores de ar",
    "{n} dehumidifier": "{n} desumidificador",
    "{n} dehumidifiers": "{n} desumidificadores",
    "{n} diffuser": "{n} difusor",
    "{n} diffusers": "{n} difusores",
    "{n} kettle": "{n} chaleira",
    "{n} kettles": "{n} chaleiras",
    "{n} ice maker": "{n} máquina de gelo",
    "{n} ice makers": "{n} máquinas de gelo",
    "enabled": "ativado",
    "disabled": "desativado",
    "{transport}: {state}": "{transport}: {state}",
    "Back": "Voltar",
    "Loading scenes…": "A carregar cenas…",
    "Scene": "Cena",
    "Could not load scenes": "Não foi possível carregar as cenas",
    "My DIY": "Os meus DIY",
    "Govee returned no scenes for this device.": "A Govee não devolveu nenhuma cena para este dispositivo.",
    "No devices found.": "Nenhum dispositivo encontrado.",
    "Unknown": "Desconhecido",
    "Model: {model}": "Modelo: {model}",
    "Error: {error}": "Erro: {error}",
    "Unknown error": "Erro desconhecido",
    "Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards.": "Limpar a cache? Isto remove o início de sessão guardado, o certificado IoT e os dados dos dispositivos. Reinicie o Homeswift a seguir.",
    "Cache partially cleared": "Cache parcialmente limpa",
    "Failed to clear cache": "Não foi possível limpar a cache",
    "Restarting…": "A reiniciar…",
    "Settings": "Definições",
    "Devices": "Dispositivos",
    "Tools": "Ferramentas",
    "Discover Devices": "Descobrir dispositivos",
    "Cache Management": "Gestão da cache",
    "Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.": "Limpe a cache do plugin se a descoberta de dispositivos falhar ou os dados parecerem desatualizados: o início de sessão e o certificado IoT guardados, os dispositivos descobertos e o seu estado guardado. Reinicie o Homeswift a seguir.",
    "Clear Cache": "Limpar a cache",
    "Restart Homeswift": "Reiniciar o Homeswift",
    "Documentation": "Documentação",
    "The options are described in the plugin's README; the connections are tried in this order:": "As opções estão descritas no README do plugin; as ligações são tentadas por esta ordem:",
    "local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.": "controlo pela rede local (mais rápido, funciona sem internet), para os modelos com a API LAN ativada na app Govee.",
    "real-time control through Govee's cloud (requires credentials).": "controlo em tempo real pela nuvem da Govee (requer credenciais).",
    "Bluetooth control for nearby devices (requires a Bluetooth adapter).": "controlo por Bluetooth dos dispositivos próximos (requer um adaptador Bluetooth).",
    "Username and password are required": "São necessários o nome de utilizador e a palavra-passe",
    "Sign in to your Govee account on Add accessories first.": "Inicie primeiro sessão na sua conta Govee em Adicionar acessórios.",
    "Login successful. Account ID: {0}": "Sessão iniciada. ID da conta: {0}",
    "Cache cleared successfully. Please restart Homeswift to apply changes.": "Cache limpa. Reinicie o Homeswift para aplicar as alterações.",
    "Cache partially cleared. Errors: {0}": "Cache parcialmente limpa. Erros: {0}",
    "A device ID and model are required to load scenes.": "São necessários um ID de dispositivo e um modelo para carregar as cenas.",
    "A device ID and model are required to load DIY effects.": "São necessários um ID de dispositivo e um modelo para carregar os efeitos DIY.",
    "A device ID and model are required.": "São necessários um ID de dispositivo e um modelo.",
    "Govee login failed: {0}": "Não foi possível iniciar sessão na Govee: {0}",
    "Request failed with status code {0}": "O pedido falhou com o código {0}",
    "Govee scene library response did not contain any categories": "A resposta da biblioteca de cenas Govee não continha nenhuma categoria",
    "nothing at {0} {1}": "nada em {0} {1}"
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Govee</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large light" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/></svg></span>
    <div class="who">
      <h1>Govee</h1>
      <p class="muted" data-i18n>The devices your Govee account and the LAN bring to the Home app, how the plugin reaches each one, and the scenes of your lights.</p>
    </div>
  </div>

  <div class="group tabs main-tabs" role="tablist">
    <button role="tab" data-tab="devices" class="on" aria-selected="true" aria-controls="tab-devices" data-i18n data-action-icon="bulb">Devices</button>
    <button role="tab" data-tab="tools" aria-selected="false" aria-controls="tab-tools" data-i18n data-action-icon="sliders">Tools</button>
  </div>

  <section id="tab-devices" class="tab-pane" role="tabpanel">
    <div class="card discover">
      <div class="discover-head">
        <p class="muted" data-i18n>The devices of your Govee account and of the LAN, as the plugin found them at its start. A device's Settings name it, leave it out, or choose how it appears in the Home app.</p>
        <button id="discover" data-i18n data-action-icon="search">Discover Devices</button>
      </div>
      <div id="signed-out" class="hidden">
        <p class="notice" data-i18n>Not signed in to a Govee account: the plugin uses LAN and Bluetooth only. Add accessories signs in.</p>
        <a id="sign-in" class="button" data-i18n data-action-icon="key">Sign in</a>
      </div>
      <div id="discover-result"></div>
    </div>
    <div id="device-types"></div>
    <div id="library" class="card editor hidden"></div>
  </section>

  <section id="tab-tools" class="tab-pane hidden" role="tabpanel">
    <div class="card">
      <h2 data-i18n>Cache Management</h2>
      <p class="muted" data-i18n>Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.</p>
      <div class="actions"><button id="clear-cache" class="danger" data-i18n data-action-icon="trash">Clear Cache</button><button id="restart" class="hidden" data-i18n data-action-icon="power">Restart Homeswift</button></div>
      <div id="clear-result"></div>
    </div>
    <div class="card">
      <h2 data-i18n>Documentation</h2>
      <p data-i18n>The options are described in the plugin's README; the connections are tried in this order:</p>
      <ul class="docs">
        <li><strong>LAN:</strong> <span data-i18n>local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.</span></li>
        <li><strong>AWS IoT:</strong> <span data-i18n>real-time control through Govee's cloud (requires credentials).</span></li>
        <li><strong>BLE:</strong> <span data-i18n>Bluetooth control for nearby devices (requires a Bluetooth adapter).</span></li>
      </ul>
    </div>
  </section>

</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
