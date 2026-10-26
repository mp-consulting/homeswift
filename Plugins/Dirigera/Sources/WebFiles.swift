// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DirigeraPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The IKEA DIRIGERA page on the UI's materials: the hubs and their pairing, the devices as the Accessories page's
   widgets, the hub's scenes as tiles, and the settings. */

.page-head { align-items: center; }
.main-tabs { margin: 18px 0 14px; }
.tab-pane { animation: fade var(--normal) var(--ease-out); }
h2 { margin: 0 0 10px; }
.intro { margin: 0 0 14px; font-size: 0.875rem; }

/* The bridge. */
.bridge-card .server-head { display: flex; align-items: center; gap: 14px; }
.bridge-card .who { flex: 1; min-width: 0; }
.bridge-card .who strong { display: block; }
.pair-steps { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 16px; align-items: center; margin-top: 14px; padding: 14px 16px; border-radius: 16px; background: var(--material-thin); border: 1px solid var(--line); }
.pair-steps p { margin: 0; font-size: 0.875rem; }
.link-button { width: 54px; height: 54px; border-radius: 50%; display: grid; place-items: center; background: radial-gradient(circle at 50% 40%, #fff, #e6e8ee 70%); box-shadow: inset 0 -2px 0 rgba(0, 0, 0, 0.08), 0 1px 3px rgba(0, 0, 0, 0.15); color: #3d4352; }
.link-button svg { width: 24px; height: 24px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; }
.pairing .link-button { animation: press 1.6s var(--ease-out) infinite; }
@keyframes press { 0%, 100% { box-shadow: 0 0 0 0 rgba(124, 77, 219, 0.45), inset 0 -2px 0 rgba(0, 0, 0, 0.08); } 50% { box-shadow: 0 0 0 10px rgba(124, 77, 219, 0), inset 0 -2px 0 rgba(0, 0, 0, 0.08); } }
.countdown { font-variant-numeric: tabular-nums; }
.address { display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap; margin-top: 12px; }
.address .field { flex: 1; min-width: 200px; margin: 0; }
.found { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }

/* Scenes: a section per room, a tile per scene painted with its colours. */
.room { margin-bottom: 22px; }
.room-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 0 0 10px; }
.room-head h2 { margin: 0; font-size: 1.0625rem; }
.scene-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 168px), 1fr)); gap: 10px; }
.scene { position: relative; display: grid; align-content: end; min-height: 96px; padding: 12px 14px; border-radius: 18px; border: 1px solid var(--edge); color: #fff; text-align: left; cursor: pointer; overflow: hidden; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.08); transition: transform var(--fast) var(--ease-out), box-shadow var(--fast) var(--ease-out); }
.scene::after { content: ""; position: absolute; inset: 0; background: linear-gradient(180deg, transparent 35%, rgba(0, 0, 0, 0.42)); pointer-events: none; }
@media (hover: hover) and (pointer: fine) { .scene:hover { transform: translateY(-1px); box-shadow: 0 6px 18px rgba(0, 0, 0, 0.14); } }
.scene:active { transform: scale(0.98); }
.scene .name { position: relative; z-index: 1; font-weight: 600; font-size: 0.9375rem; text-shadow: 0 1px 2px rgba(0, 0, 0, 0.35); overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.scene .kind { position: relative; z-index: 1; font-size: 0.75rem; opacity: 0.85; }
.scene.active { box-shadow: 0 0 0 3px var(--accent), 0 6px 18px rgba(0, 0, 0, 0.14); }
.scene .badge { position: absolute; top: 10px; left: 12px; z-index: 1; font-size: 0.6875rem; font-weight: 600; padding: 2px 8px; border-radius: 999px; background: rgba(255, 255, 255, 0.85); color: #1d1d1f; }
.scene .eye { position: absolute; top: 6px; right: 6px; z-index: 2; width: 30px; height: 30px; min-height: 0; padding: 0; border-radius: 50%; display: grid; place-items: center; background: rgba(0, 0, 0, 0.28); border: 0; color: #fff; box-shadow: none; }
.scene .eye svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.scene.hidden-scene { filter: grayscale(0.85); opacity: 0.55; }
.scene.busy { pointer-events: none; }

/* Settings. */
.range { display: flex; align-items: center; gap: 12px; }
.range input { flex: 1; width: auto; }
.range output { min-width: 72px; text-align: right; font-variant-numeric: tabular-nums; }
.presets { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 8px; }
.presets button { padding: 4px 11px; min-height: 0; font-size: 0.8125rem; border-radius: 999px; }
.save-card { position: sticky; bottom: 12px; z-index: 3; margin-top: 18px; }
.save-card .save-bar { border-top: 0; padding-top: 0; }

@media (max-width: 640px) {
  .pair-steps { grid-template-columns: 1fr; justify-items: start; }
}
@media (prefers-reduced-motion: reduce) {
  .tab-pane { animation: none; }
  .pairing .link-button { animation: none; }
  .scene { transition: none; }
}

/* Hubs and rooms. */
.hub { display: grid; gap: 4px; padding: 12px 0; border-top: 1px solid var(--line); }
.hub:first-of-type { border-top: 0; padding-top: 0; }
.hub-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.hub-row .who { flex: 1; min-width: 180px; }
.scene .glyph { position: absolute; top: 12px; left: 14px; z-index: 1; width: 28px; height: 28px; color: rgba(255, 255, 255, 0.92); }
.scene .glyph svg { width: 28px; height: 28px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
.scene.fired { animation: fired 0.9s var(--ease-out); }
@keyframes fired { 0% { box-shadow: 0 0 0 0 rgba(255, 214, 10, 0.7); } 100% { box-shadow: 0 0 0 14px rgba(255, 214, 10, 0); } }
@media (prefers-reduced-motion: reduce) { .scene.fired { animation: none; } }

/* Lights as the Accessories page draws them; the ones left out of the Home app below, to bring back. */
.accessory-walls { margin: 0; }
.hidden-devices { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 14px; font-size: 0.875rem; }
.hidden-devices:empty { display: none; }

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The IKEA DIRIGERA page: the hubs (from config.json and found on the network), each paired with its action button;
// the lights, outlets and sensors as the Accessories page draws them (its widgets); the hubs' scenes as tiles (a tap
// runs one, the eye leaves it out of the Home app); and the settings. Refreshed every two seconds while visible;
// saving writes this instance's block.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, icon, tile, request, explain, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let hubs = [];
  let devices = [];
  let scenes = [];
  let found = [];
  let block = {};
  const pairing = new Map();

  // MARK: Tabs

  for (const button of document.querySelectorAll(".main-tabs [data-tab]")) {
    button.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".main-tabs [data-tab]")) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`).classList.toggle("hidden", !on);
      }
      try { localStorage.setItem("dirigera-tab", button.dataset.tab); } catch {}
    });
  }
  try {
    const saved = localStorage.getItem("dirigera-tab");
    if (saved) document.querySelector(`.main-tabs [data-tab="${saved}"]`)?.click();
  } catch {}

  // MARK: Hubs

  function hubRow(hub) {
    const until = pairing.get(hub.host) ?? 0;
    const waiting = Date.now() < until || hub.pairing;
    const [state, kind] = waiting ? [t("Pairing…"), "standby"] : !hub.paired ? [t("Not paired"), "away"]
      : hub.error ? [t("Not responding"), "away"] : hub.connected ? [t("Connected"), "on"] : [t("Connecting…"), "standby"];
    const seconds = Math.max(0, Math.ceil((until - Date.now()) / 1000));
    return el("div", { class: "hub" },
      el("div", { class: "hub-row" },
        tile("bridge", hub.paired && !hub.error ? "blue" : "grey"),
        el("div", { class: "who" }, el("strong", { text: hub.name || t("DIRIGERA hub") }),
          el("div", { class: "muted", text: hub.paired ? [hub.host, tn("{n} device", "{n} devices", hub.devices), tn("{n} scene", "{n} scenes", hub.scenes)].join(" · ") : hub.host })),
        el("span", { class: `pill status ${kind}`, text: state }),
        hub.paired || waiting ? null : el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => pair(event.currentTarget, hub.host) }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: hub.name || hub.host }), () => [
          hub.paired ? { label: t("Pair again"), icon: "key", onSelect: () => pair(null, hub.host) } : null,
          hub.inConfig ? { label: t("Remove from config.json"), icon: "trash", danger: true, onSelect: () => removeHub(hub.host) } : null,
        ])),
      waiting ? el("div", { class: "pair-steps pairing" },
        el("span", { class: "link-button", "aria-hidden": "true" }, icon("power")),
        el("div", {},
          el("p", {}, el("strong", { text: t("Press the action button under the hub.") })),
          el("p", { class: "muted", text: t("Waiting for the button… {seconds} s left.", { seconds }) }))) : null,
      hub.error && hub.paired ? explain({
        error: `The DIRIGERA hub at ${hub.host} did not answer: ${hub.error}`,
        context: "The Homeswift DIRIGERA plugin reads GET https://<hub>:8443/v1/devices and /v1/scenes with its token, and follows the hub's websocket for changes.",
        device: { host: hub.host },
      }) : null);
  }

  const hubList = el("div");
  const foundList = el("div", { class: "found" });
  const addressInput = el("input", { type: "text", placeholder: "192.168.1.30", inputmode: "url", autocomplete: "off" });
  $("#hubs").append(hubList, foundList,
    el("details", { class: "address-box" },
      el("summary", { text: t("Add a hub") }),
      el("div", { class: "address" },
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Address") }), addressInput),
        el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
          ({ hosts: found } = await request("discover"));
          if (!found.length) alert(t("No hub answered on the network."));
          drawHubs();
        }) }),
        el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => { const host = addressInput.value.trim(); if (host) pair(event.currentTarget, host); } }))));

  /// The hub rows, and the hubs found on the network that are not paired yet; the address form stays as typed.
  function drawHubs() {
    const known = new Set(hubs.map((hub) => hub.host));
    const extra = found.filter((host) => !known.has(host));
    hubList.replaceChildren(...(hubs.length ? hubs.map(hubRow) : [el("p", { class: "muted", text: t("No hub yet. Find one on the network or type its address.") })]));
    foundList.replaceChildren(...extra.map((host) => el("button", { actionIcon: "key", text: t("Pair {host}", { host }), onclick: (event) => pair(event.currentTarget, host) })));
  }

  async function pair(button, host) {
    pairing.set(host, Date.now() + 60000);
    drawHubs();
    const timer = setInterval(drawHubs, 1000);
    try {
      await request("pair", { method: "POST", body: { host } });
      // The hub goes in config.json, as homebridge-dirigera keeps it; its token stays in the plugin's folder.
      await updateBlock((draft) => {
        const list = draft.hubs || [];
        if (!list.some((hub) => hub.host === host)) list.push({ host });
        draft.hubs = list;
      });
      block = await readBlock();
    } catch (e) {
      alert(e.message);
    } finally {
      pairing.delete(host);
      clearInterval(timer);
      await refresh();
    }
  }

  async function removeHub(host) {
    if (!confirm(t("Remove the hub at {host} from config.json?", { host }))) return;
    await request("unpair", { method: "POST", body: { host } }).catch(() => {});
    await updateBlock((draft) => {
      const list = (draft.hubs || []).filter((hub) => hub.host !== host);
      if (list.length) draft.hubs = list; else delete draft.hubs;
    }).catch((e) => alert(e.message));
    block = await readBlock();
    await refresh();
  }

  // MARK: Lights, as the Accessories page draws them

  /// The plugin's accessories (not its scene switches), read again when the set of devices changes.
  let accessories = [];
  let shapeKey = "";
  async function loadAccessories() {
    const all = await homeswift.api("/api/accessories");
    accessories = all.filter((accessory) => accessory.platform === "Dirigera" && accessory.platformName === homeswift.name && !accessory.id.startsWith("Dirigera:scenes:"));
  }

  let listening = false;
  async function drawDevices() {
    const list = $("#devices");
    const hidden = $("#hidden-devices");
    if (!hubs.some((hub) => hub.paired)) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair a hub to see its lights and outlets.") })));
      hidden.replaceChildren();
      return;
    }
    const key = devices.filter((item) => !item.hidden).map((item) => item.id).sort().join(",");
    if (key !== shapeKey) {
      shapeKey = key;
      await loadAccessories().catch(() => {});
    }
    if (!accessories.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("The hub has no lights or outlets yet: add them in the IKEA Home smart app.") })));
    } else {
      if (list.querySelector(".card.empty")) list.replaceChildren();
      // A widget per accessory, drawn once: its values follow the bridge's event stream.
      renderKeyed(list, accessories.map((accessory) => ({ id: accessory.id, name: accessory.name, services: accessory.services.length })), (item) => item.id,
        (item) => HomeswiftWidgets.card(accessories.find((accessory) => accessory.id === item.id), { size: "large", actions: actionsFor }));
      if (!listening) { HomeswiftWidgets.listen(); listening = true; }
    }
    const left = devices.filter((item) => item.hidden);
    hidden.replaceChildren(...(left.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...left.map((item) => el("button", { actionIcon: "eye", text: item.name, title: t("Show in the Home app"), onclick: () => toggleList("excludeDevices", item.name) }))] : []));
  }

  /// The widget's ⋯ menu, after All controls: what this page adds.
  function actionsFor(accessory) {
    const id = accessory.id.slice("Dirigera:".length);
    const item = devices.find((entry) => entry.id === id);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { host: item?.host, id } }).catch((e) => alert(e.message)) },
      item ? { label: t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleList("excludeDevices", item.name) } : null,
      { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessory.id)}` },
    ].filter(Boolean);
  }

  // MARK: Scenes

  // The hub's scene icons, as line drawings; others take the generic one.
  const glyphs = {
    tv: '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>',
    book: '<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z"/><path d="M4 19V5"/>',
    party: '<path d="M4 20l5-14 9 9z"/><path d="M14 4l1 2M19 7l2-1M18 3l-1 2"/>',
    home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/>',
    off: '<path d="M12 3v9M6.3 5.8a8 8 0 1 0 11.4 0"/>',
  };
  const tones = ["#0058a3, #3d8bd8", "#f2b705, #ffd85c", "#5b4fd6, #9a8cff", "#0a7a5a, #36c08f", "#c2410c, #f59e5b", "#334155, #64748b"];
  function sceneStyle(scene) {
    const name = (scene.icon || "").replace(/^scenes_/, "");
    const key = Object.keys(glyphs).find((k) => name.includes(k) || (k === "moon" && /night|sleep/.test(name)) || (k === "sun" && /morning|wake|bright/.test(name))
      || (k === "off" && /off|away|leave/.test(name)) || (k === "book" && /read/.test(name)) || (k === "party" && /party|dinner|cozy/.test(name)));
    let hash = 0;
    for (const c of scene.name) hash = (hash * 31 + c.charCodeAt(0)) >>> 0;
    return { glyph: glyphs[key ?? "home"], gradient: `linear-gradient(135deg, ${tones[hash % tones.length]})` };
  }

  function sceneTile(scene) {
    const { glyph, gradient } = sceneStyle(scene);
    const art = document.createElement("span");
    art.className = "glyph";
    art.innerHTML = `<svg viewBox="0 0 24 24">${glyph}</svg>`;
    const tileNode = el("div", { class: `scene ${scene.hidden ? "hidden-scene" : ""}`, role: "button", tabindex: 0, style: `background: ${gradient}`, "aria-label": t("Run {name}", { name: scene.name }) },
      art,
      el("button", {
        type: "button", class: "eye", title: scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"),
        "aria-label": scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"),
        onclick: (event) => { event.stopPropagation(); toggleList("excludeScenes", scene.name); },
      }, icon("eye")),
      el("span", { class: "name", text: scene.name }));
    const run = async () => {
      tileNode.classList.add("busy");
      try {
        await request("trigger", { method: "POST", body: { host: scene.host, id: scene.id } });
        tileNode.classList.remove("fired");
        void tileNode.offsetWidth;
        tileNode.classList.add("fired");
      } catch (e) { alert(e.message); } finally { tileNode.classList.remove("busy"); }
    };
    tileNode.addEventListener("click", run);
    tileNode.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); run(); } });
    return tileNode;
  }

  function drawScenes() {
    const list = $("#scenes");
    if (!scenes.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: hubs.some((hub) => hub.paired) ? t("No scenes yet: make some in the IKEA Home smart app.") : t("Pair a hub to see its scenes.") })));
      return;
    }
    renderKeyed(list, scenes, (scene) => `${scene.host}/${scene.id}`, sceneTile);
  }

  // MARK: Settings

  let dirty = false;
  const markDirty = () => { dirty = true; $("#save-state").textContent = t("Unsaved changes."); };

  function buildSettings() {
    const value = el("output");
    const slider = el("input", { type: "range", id: "transitionMs", min: 0, max: 2000, step: 50, "aria-label": t("Transition") });
    const show = () => { value.textContent = Number(slider.value) === 0 ? t("Instant") : `${slider.value} ms`; };
    slider.addEventListener("input", () => { show(); markDirty(); });
    const presets = [[0, t("Instant: flashes and fast moods")], [100, t("Quick (default)")], [500, t("Soft")]].map(([ms, label]) =>
      el("button", { type: "button", text: label, onclick: () => { slider.value = ms; show(); markDirty(); } }));
    $("#speed").append(
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Transition") }), el("div", { class: "range" }, slider, value),
        el("span", { class: "help", text: t("How long a light takes to reach a new level or colour. Shorter is snappier for moods.") })),
      el("div", { class: "presets" }, presets));
    const input = el("input", { type: "checkbox", id: "scenes-toggle" });
    input.addEventListener("change", markDirty);
    $("#options").append(el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
      el("span", {}, el("span", { class: "field-title", text: t("Scenes") }), el("span", { class: "help", text: t("A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.") }))));
    show();
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    $("#transitionMs").value = block.transitionMs ?? 100;
    $("#transitionMs").dispatchEvent(new Event("input"));
    dirty = false;
    $("#save-state").textContent = t("Changes are kept once you save.");
    $("#scenes-toggle").checked = block.scenes ?? true;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", Number($("#transitionMs").value), 100);
      setKey(draft, "scenes", $("#scenes-toggle").checked, true);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

  async function toggleList(key, name) {
    try {
      await updateBlock((draft) => {
        const list = draft[key] || [];
        const index = list.findIndex((item) => item.toLowerCase() === name.toLowerCase());
        if (index >= 0) list.splice(index, 1); else list.push(name);
        if (list.length) draft[key] = list; else delete draft[key];
      });
      block = await readBlock();
      setTimeout(refresh, 1500);
    } catch (e) {
      alert(e.message);
    }
  }

  // MARK: Refresh

  async function refresh() {
    try {
      ({ hubs } = await request("hubs"));
      if (hubs.some((hub) => hub.paired)) {
        [{ devices }, { scenes }] = await Promise.all([request("devices"), request("scenes")]);
      } else {
        devices = [];
        scenes = [];
      }
    } catch (e) {
      hubs = [];
    }
    drawHubs();
    drawDevices();
    drawScenes();
  }

  buildSettings();
  readBlock().then((value) => { block = value || {}; fillSettings(); }).catch(() => {});
  poll(refresh, 2000);
  // Hubs announce themselves: look once when the page opens.
  request("discover").then(({ hosts }) => { found = hosts; drawHubs(); }).catch(() => {});
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The IKEA DIRIGERA page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Pairing…": "Jumelage…",
    "Not paired": "Non jumelé",
    "Not responding": "Ne répond pas",
    "Connected": "Connecté",
    "Connecting…": "Connexion…",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Pair": "Jumeler",
    "Actions for {name}": "Actions pour {name}",
    "Pair again": "Jumeler à nouveau",
    "Remove from config.json": "Retirer de config.json",
    "Press the action button under the hub.": "Appuyez sur le bouton d'action sous le hub.",
    "Waiting for the button… {seconds} s left.": "En attente du bouton… encore {seconds} s.",
    "Add a hub": "Ajouter un hub",
    "Address": "Adresse",
    "Find": "Rechercher",
    "No hub answered on the network.": "Aucun hub n'a répondu sur le réseau.",
    "No hub yet. Find one on the network or type its address.": "Pas encore de hub. Recherchez-en un sur le réseau ou saisissez son adresse.",
    "Pair {host}": "Jumeler {host}",
    "Remove the hub at {host} from config.json?": "Retirer le hub à {host} de config.json ?",
    "Identify": "Identifier",
    "Show in the Home app": "Afficher dans l'app Maison",
    "Leave out of the Home app": "Retirer de l'app Maison",
    "Show its log": "Afficher son journal",
    "Pair a hub to see its lights and outlets.": "Jumelez un hub pour voir ses lampes et ses prises.",
    "The hub has no lights or outlets yet: add them in the IKEA Home smart app.": "Le hub n'a pas encore de lampes ni de prises : ajoutez-les dans l'app IKEA Home smart.",
    "Run {name}": "Lancer {name}",
    "No scenes yet: make some in the IKEA Home smart app.": "Pas encore de scènes : créez-en dans l'app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Jumelez un hub pour voir ses scènes.",
    "Unsaved changes.": "Modifications non enregistrées.",
    "Transition": "Transition",
    "Instant": "Instantané",
    "Instant: flashes and fast moods": "Instantané : clignotements et ambiances rapides",
    "Quick (default)": "Rapide (par défaut)",
    "Soft": "Douce",
    "How long a light takes to reach a new level or colour. Shorter is snappier for moods.": "Le temps que met une lampe pour atteindre une nouvelle intensité ou couleur. Plus court, c'est plus vif pour les ambiances.",
    "Scenes": "Scènes",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Un interrupteur par scène du hub. L'allumer la lance ; l'éteindre dans les 30 secondes l'annule.",
    "Changes are kept once you save.": "Les modifications sont conservées une fois enregistrées.",
    "Saved. The plugin restarted with these settings.": "Enregistré. Le plugin a redémarré avec ces réglages.",
    "{n} device": "{n} appareil",
    "{n} devices": "{n} appareils",
    "{n} scene": "{n} scène",
    "{n} scenes": "{n} scènes",
    "Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.": "Vos hubs DIRIGERA, leurs lampes et prises pièce par pièce, et leurs scènes, directement depuis le hub sur votre réseau.",
    "Devices": "Appareils",
    "Settings": "Réglages",
    "Tap a scene to run it. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it. The eye leaves one out.": "Touchez une scène pour la lancer. Dans l'app Maison, chaque scène est un interrupteur : l'allumer la lance, l'éteindre dans les 30 secondes l'annule. L'œil en retire une.",
    "Speed": "Vitesse",
    "In the Home app": "Dans l'app Maison",
    "Save Configuration": "Enregistrer la configuration",
    "an address is required": "une adresse est requise",
    "The action button was not pressed in time.": "Le bouton d'action n'a pas été pressé à temps.",
    "The DIRIGERA hub refused the token: pair again from the plugin's page.": "Le hub DIRIGERA a refusé le jeton : jumelez à nouveau depuis la page du plugin.",
    "Battery": "Batterie",
    "Not in the Home app:": "Pas dans l'app Maison :"
  },
  "es": {
    "Pairing…": "Emparejando…",
    "Not paired": "Sin emparejar",
    "Not responding": "No responde",
    "Connected": "Conectado",
    "Connecting…": "Conectando…",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Pair": "Emparejar",
    "Actions for {name}": "Acciones para {name}",
    "Pair again": "Volver a emparejar",
    "Remove from config.json": "Quitar de config.json",
    "Press the action button under the hub.": "Pulsa el botón de acción de debajo del hub.",
    "Waiting for the button… {seconds} s left.": "Esperando el botón… quedan {seconds} s.",
    "Add a hub": "Añadir un hub",
    "Address": "Dirección",
    "Find": "Buscar",
    "No hub answered on the network.": "Ningún hub ha respondido en la red.",
    "No hub yet. Find one on the network or type its address.": "Aún no hay ningún hub. Busca uno en la red o escribe su dirección.",
    "Pair {host}": "Emparejar {host}",
    "Remove the hub at {host} from config.json?": "¿Quitar el hub de {host} de config.json?",
    "Identify": "Identificar",
    "Show in the Home app": "Mostrar en la app Casa",
    "Leave out of the Home app": "Quitar de la app Casa",
    "Show its log": "Ver su registro",
    "Pair a hub to see its lights and outlets.": "Empareja un hub para ver sus luces y enchufes.",
    "The hub has no lights or outlets yet: add them in the IKEA Home smart app.": "El hub aún no tiene luces ni enchufes: añádelos en la app IKEA Home smart.",
    "Run {name}": "Activar {name}",
    "No scenes yet: make some in the IKEA Home smart app.": "Aún no hay escenas: créalas en la app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Empareja un hub para ver sus escenas.",
    "Unsaved changes.": "Cambios sin guardar.",
    "Transition": "Transición",
    "Instant": "Instantánea",
    "Instant: flashes and fast moods": "Instantánea: parpadeos y ambientes rápidos",
    "Quick (default)": "Rápida (predeterminada)",
    "Soft": "Suave",
    "How long a light takes to reach a new level or colour. Shorter is snappier for moods.": "Lo que tarda una luz en llegar a un nuevo nivel o color. Más corto es más ágil para los ambientes.",
    "Scenes": "Escenas",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Un interruptor por escena del hub. Encenderlo la activa; apagarlo antes de 30 segundos la deshace.",
    "Changes are kept once you save.": "Los cambios se conservan al guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. El plugin se ha reiniciado con estos ajustes.",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} scene": "{n} escena",
    "{n} scenes": "{n} escenas",
    "Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.": "Tus hubs DIRIGERA, sus luces y enchufes habitación por habitación y sus escenas, directamente desde el hub en tu red.",
    "Devices": "Dispositivos",
    "Settings": "Ajustes",
    "Tap a scene to run it. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it. The eye leaves one out.": "Toca una escena para activarla. En la app Casa cada escena es un interruptor: encenderlo la activa y apagarlo antes de 30 segundos la deshace. El ojo quita una.",
    "Speed": "Velocidad",
    "In the Home app": "En la app Casa",
    "Save Configuration": "Guardar configuración",
    "an address is required": "se necesita una dirección",
    "The action button was not pressed in time.": "No se ha pulsado el botón de acción a tiempo.",
    "The DIRIGERA hub refused the token: pair again from the plugin's page.": "El hub DIRIGERA ha rechazado el token: vuelve a emparejar desde la página del plugin.",
    "Battery": "Batería",
    "Not in the Home app:": "No están en la app Casa:"
  },
  "pt": {
    "Pairing…": "A emparelhar…",
    "Not paired": "Não emparelhada",
    "Not responding": "Não responde",
    "Connected": "Ligada",
    "Connecting…": "A ligar…",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Pair": "Emparelhar",
    "Actions for {name}": "Ações para {name}",
    "Pair again": "Emparelhar novamente",
    "Remove from config.json": "Remover de config.json",
    "Press the action button under the hub.": "Prima o botão de ação por baixo do hub.",
    "Waiting for the button… {seconds} s left.": "À espera do botão… faltam {seconds} s.",
    "Add a hub": "Adicionar um hub",
    "Address": "Endereço",
    "Find": "Procurar",
    "No hub answered on the network.": "Nenhum hub respondeu na rede.",
    "No hub yet. Find one on the network or type its address.": "Ainda não há nenhum hub. Procure um na rede ou introduza o endereço.",
    "Pair {host}": "Emparelhar {host}",
    "Remove the hub at {host} from config.json?": "Remover o hub em {host} de config.json?",
    "Identify": "Identificar",
    "Show in the Home app": "Mostrar na app Casa",
    "Leave out of the Home app": "Retirar da app Casa",
    "Show its log": "Ver o registo",
    "Pair a hub to see its lights and outlets.": "Emparelhe um hub para ver as luzes e tomadas.",
    "The hub has no lights or outlets yet: add them in the IKEA Home smart app.": "O hub ainda não tem luzes nem tomadas: adicione-as na app IKEA Home smart.",
    "Run {name}": "Ativar {name}",
    "No scenes yet: make some in the IKEA Home smart app.": "Ainda não há cenas: crie-as na app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Emparelhe um hub para ver as cenas.",
    "Unsaved changes.": "Alterações por guardar.",
    "Transition": "Transição",
    "Instant": "Instantânea",
    "Instant: flashes and fast moods": "Instantânea: piscas e ambientes rápidos",
    "Quick (default)": "Rápida (predefinida)",
    "Soft": "Suave",
    "How long a light takes to reach a new level or colour. Shorter is snappier for moods.": "O tempo que uma luz demora a chegar a um novo nível ou cor. Mais curto é mais vivo para os ambientes.",
    "Scenes": "Cenas",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Um interruptor por cena do hub. Ligá-lo ativa-a; desligá-lo nos 30 segundos seguintes anula-a.",
    "Changes are kept once you save.": "As alterações ficam guardadas quando guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. O plugin reiniciou com estas definições.",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} scene": "{n} cena",
    "{n} scenes": "{n} cenas",
    "Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.": "Os hubs DIRIGERA, as luzes e tomadas divisão a divisão e as cenas, diretamente do hub na sua rede.",
    "Devices": "Dispositivos",
    "Settings": "Definições",
    "Tap a scene to run it. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it. The eye leaves one out.": "Toque numa cena para a ativar. Na app Casa cada cena é um interruptor: ligá-lo ativa-a e desligá-lo nos 30 segundos seguintes anula-a. O olho retira uma.",
    "Speed": "Velocidade",
    "In the Home app": "Na app Casa",
    "Save Configuration": "Guardar configuração",
    "an address is required": "é necessário um endereço",
    "The action button was not pressed in time.": "O botão de ação não foi premido a tempo.",
    "The DIRIGERA hub refused the token: pair again from the plugin's page.": "O hub DIRIGERA recusou o token: emparelhe novamente a partir da página do plugin.",
    "Battery": "Bateria",
    "Not in the Home app:": "Fora da app Casa:"
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>IKEA DIRIGERA</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-blue" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/></svg></span>
    <div class="who">
      <h1>IKEA DIRIGERA</h1>
      <p class="muted" data-i18n>Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.</p>
    </div>
  </div>

  <div id="hubs" class="card bridge-card"></div>

  <div class="group tabs main-tabs" role="tablist">
    <button role="tab" data-tab="devices" class="on" aria-selected="true" aria-controls="tab-devices" data-i18n>Devices</button>
    <button role="tab" data-tab="scenes" aria-selected="false" aria-controls="tab-scenes" data-i18n>Scenes</button>
    <button role="tab" data-tab="settings" aria-selected="false" aria-controls="tab-settings" data-i18n data-action-icon="sliders">Settings</button>
  </div>

  <section id="tab-devices" class="tab-pane" role="tabpanel">
    <div class="accessory-walls"><div class="wall" id="devices"></div></div>
    <div id="hidden-devices" class="hidden-devices"></div>
  </section>

  <section id="tab-scenes" class="tab-pane hidden" role="tabpanel">
    <p class="muted intro" data-i18n>Tap a scene to run it. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it. The eye leaves one out.</p>
    <div id="scenes" class="scene-grid"></div>
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
