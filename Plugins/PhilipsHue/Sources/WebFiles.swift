// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Philips Hue page on the UI's materials: the bridge and its pairing, the lights as the Accessories page's
   widgets, the scenes of each room as tiles painted with their palette, and the settings. */

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

/* Lights as the Accessories page draws them; the ones left out of the Home app below, to bring back. */
.accessory-walls { margin: 0; }
.hidden-devices { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 14px; font-size: 0.875rem; }
.hidden-devices:empty { display: none; }

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Hue page: the bridge (found on the network or at an address, paired with its link button), the
// lights as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the
// scenes of each room as tiles painted with their palette (a tap recalls one, the eye leaves it out of the Home app),
// and the settings: the transition and what the Home app shows. Refreshed every two seconds while visible; saving
// writes this instance's block.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, tile, request, explain, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
  let groups = [];
  let block = {};

  // MARK: Tabs

  for (const button of document.querySelectorAll(".main-tabs [data-tab]")) {
    button.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".main-tabs [data-tab]")) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`).classList.toggle("hidden", !on);
      }
      try { localStorage.setItem("hue-tab", button.dataset.tab); } catch {}
    });
  }
  try {
    const saved = localStorage.getItem("hue-tab");
    if (saved) document.querySelector(`.main-tabs [data-tab="${saved}"]`)?.click();
  } catch {}

  // MARK: The bridge

  let pairingUntil = 0;
  function drawBridge() {
    const card = $("#bridge");
    const paired = status.paired;
    const pairing = status.pairing || Date.now() < pairingUntil;
    const [state, kind] = !status.host ? [t("Not found"), "away"] : !paired ? [pairing ? t("Pairing…") : t("Not paired"), pairing ? "standby" : "away"]
      : status.error ? [t("Not responding"), "away"] : [t("Connected"), "on"];
    const facts = paired && status.host
      ? el("div", { class: "facts" },
        homeswift.fact(t("Address"), status.host), homeswift.fact(t("Lights"), String(status.lights ?? 0)), homeswift.fact(t("Scenes"), String(status.scenes ?? 0)))
      : null;
    const seconds = Math.max(0, Math.ceil((pairingUntil - Date.now()) / 1000));
    const pairBox = status.host && !paired ? el("div", { class: `pair-steps ${pairing ? "pairing" : ""}` },
      el("span", { class: "link-button", "aria-hidden": "true" }, linkGlyph()),
      el("div", {},
        el("p", {}, el("strong", { text: pairing ? t("Press the round link button on top of the bridge.") : t("Pair Homeswift with the bridge.") })),
        el("p", { class: "muted", text: pairing ? t("Waiting for the button… {seconds} s left.", { seconds }) : t("Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.") }),
        pairing ? null : el("div", { class: "actions" }, el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => pair(event.currentTarget) })))) : null;
    card.replaceChildren(...[
      el("div", { class: "server-head" },
        tile("bridge", paired && !status.error ? "violet" : "grey"),
        el("div", { class: "who" }, el("strong", { text: t("Hue Bridge") }), el("div", { class: "muted", text: [status.host, status.bridgeID?.toUpperCase()].filter(Boolean).join(" · ") || t("Looking on the network…") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      facts, pairBox,
      status.error && paired ? explain({
        error: `The Hue Bridge at ${status.host} did not answer: ${status.error}`,
        context: "The Homeswift Philips Hue plugin reads every resource of the bridge's local API v2 (GET https://<bridge>/clip/v2/resource) every two seconds with its application key.",
        device: { host: status.host },
      }) : null,
      addressForm()].filter(Boolean));
  }

  function linkGlyph() {
    const span = document.createElement("span");
    span.innerHTML = '<svg viewBox="0 0 24 24"><path d="M9.5 14.5l5-5M8 11l-2 2a3.5 3.5 0 0 0 5 5l2-2M16 13l2-2a3.5 3.5 0 0 0-5-5l-2 2"/></svg>';
    return span.firstChild;
  }

  function addressForm() {
    const input = el("input", { type: "text", value: block.host || status.host || "", placeholder: "192.168.1.20", inputmode: "url", autocomplete: "off" });
    const found = el("div", { class: "found" });
    return el("details", { class: "address-box" },
      el("summary", { text: t("Bridge address") }),
      el("div", { class: "address" },
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Address") }), input,
          el("span", { class: "help", text: t("Leave it empty to find the bridge on the network.") })),
        el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
          const { hosts } = await request("discover");
          found.replaceChildren(...(hosts.length ? hosts.map((host) => el("button", { text: host, onclick: () => { input.value = host; } })) : [el("span", { class: "muted", text: t("No bridge answered on the network.") })]));
        }) }),
        el("button", { class: "primary", text: t("Use"), onclick: (event) => act(event.currentTarget, async () => {
          const host = input.value.trim();
          await updateBlock((draft) => { setKey(draft, "host", host, ""); });
          if (host) await request("host", { method: "POST", body: { host } });
          await refresh();
        }) })),
      found);
  }

  async function pair(button) {
    pairingUntil = Date.now() + 60000;
    drawBridge();
    const timer = setInterval(drawBridge, 1000);
    try {
      await act(button, () => request("pair", { method: "POST", body: {} }), null);
      pairingUntil = 0;
    } catch (e) {
      pairingUntil = 0;
      alert(e.message);
    } finally {
      clearInterval(timer);
      await refresh();
    }
  }

  // MARK: Lights, as the Accessories page draws them

  /// The plugin's accessories (not its scene switches), read again when the set of lights changes.
  let accessories = [];
  let shapeKey = "";
  async function loadAccessories() {
    const all = await homeswift.api("/api/accessories");
    accessories = all.filter((accessory) => accessory.platform === "PhilipsHue" && accessory.platformName === homeswift.name && !accessory.id.startsWith("PhilipsHue:scenes:"));
  }

  let listening = false;
  async function drawLights() {
    const list = $("#lights");
    const hidden = $("#hidden-devices");
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its lights.") })));
      hidden.replaceChildren();
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
    const left = lights.filter((item) => item.hidden);
    hidden.replaceChildren(...(left.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...left.map((item) => el("button", { actionIcon: "eye", text: item.name, title: t("Show in the Home app"), onclick: () => toggleList("excludeLights", item.name) }))] : []));
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

  function sceneTile(group, scene) {
    const colours = scene.colours?.length ? scene.colours : ["#8e8e93"];
    const background = colours.length === 1 ? colours[0] : `linear-gradient(135deg, ${colours.join(", ")})`;
    const button = el("div", {
      class: `scene ${scene.active ? "active" : ""} ${scene.hidden ? "hidden-scene" : ""}`, role: "button", tabindex: 0, style: `background: ${background}`,
      "aria-label": t("Recall {name}", { name: scene.name }), "aria-pressed": String(scene.active),
    },
      scene.active ? el("span", { class: "badge", text: t("Active") }) : null,
      el("button", {
        type: "button", class: "eye", title: scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"),
        "aria-label": scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"),
        onclick: (event) => { event.stopPropagation(); toggleList("excludeScenes", `${group.name}/${scene.name}`); },
      }, icon("eye")),
      el("span", { class: "name", text: scene.name }),
      scene.smart ? el("span", { class: "kind", text: t("Natural light") }) : null);
    const recall = async () => {
      button.classList.add("busy");
      try { await request("recall", { method: "POST", body: { id: scene.id } }); await refresh(); } catch (e) { alert(e.message); } finally { button.classList.remove("busy"); }
    };
    button.addEventListener("click", recall);
    button.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); recall(); } });
    return button;
  }

  function drawScenes() {
    const list = $("#scenes");
    if (!status.paired) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair with the bridge to see its scenes.") })));
      return;
    }
    if (!groups.length) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No scenes yet: make some in the Hue app.") })));
      return;
    }
    renderKeyed(list, groups, (group) => group.id, (group) => el("section", { class: "room" },
      el("div", { class: "room-head" },
        el("h2", { text: group.name }),
        el("span", { class: `pill status ${group.on ? "on" : "standby"}`, text: group.kind === "zone" ? (group.on ? t("Zone on") : t("Zone off")) : (group.on ? t("Room on") : t("Room off")) })),
      el("div", { class: "scene-grid" }, group.scenes.map((scene) => sceneTile(group, scene)))));
  }

  // MARK: Settings

  const toggles = [
    ["scenes", true, t("Scenes"), t("A switch for each scene, on one accessory per room or zone. Off switches the room off.")],
    ["dynamicScenes", false, t("Play scenes dynamically"), t("Recall scenes with their colours slowly moving, as the Hue app's play button does.")],
    ["effects", true, t("Effects"), t("A switch for each effect a light has: candle, fireplace, sparkle, prism…")],
    ["flashSwitch", false, t("Flash switch"), t("A switch on each light that makes it flash for five seconds.")],
    ["gradientPoints", false, t("Gradient points"), t("On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.")],
  ];

  let dirty = false;
  const markDirty = () => { dirty = true; $("#save-state").textContent = t("Unsaved changes."); };

  function buildSettings() {
    const value = el("output");
    const slider = el("input", { type: "range", id: "transitionMs", min: 0, max: 2000, step: 50, "aria-label": t("Transition") });
    const show = () => { value.textContent = Number(slider.value) === 0 ? t("Instant") : `${slider.value} ms`; };
    slider.addEventListener("input", () => { show(); markDirty(); });
    const presets = [[0, t("Instant: flashes and fast moods")], [100, t("Quick (default)")], [400, t("Soft, as the Hue app")]].map(([ms, label]) =>
      el("button", { type: "button", text: label, onclick: () => { slider.value = ms; show(); markDirty(); } }));
    const polling = el("input", { type: "number", id: "pollingInterval", min: 1, max: 300, step: 1, placeholder: "2", inputmode: "numeric" });
    polling.addEventListener("input", markDirty);
    $("#speed").append(
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Transition") }), el("div", { class: "range" }, slider, value),
        el("span", { class: "help", text: t("How long a light takes to reach a new colour or brightness. Shorter is snappier for moods and flashes.") })),
      el("div", { class: "presets" }, presets),
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Polling interval (s)") }), polling,
        el("span", { class: "help", text: t("How often the bridge is asked for changes made in the Hue app or with a switch.") })));
    $("#options").append(...toggles.map(([id, , label, help]) => {
      const input = el("input", { type: "checkbox", id });
      input.addEventListener("change", markDirty);
      return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
        el("span", {}, el("span", { class: "field-title", text: label }), el("span", { class: "help", text: help })));
    }));
    show.call();
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    $("#transitionMs").value = block.transitionMs ?? 100;
    $("#transitionMs").dispatchEvent(new Event("input"));
    dirty = false;
    $("#save-state").textContent = t("Changes are kept once you save.");
    $("#pollingInterval").value = block.pollingInterval ?? "";
    for (const [id, fallback] of toggles) $(`#${id}`).checked = block[id] ?? fallback;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", Number($("#transitionMs").value), 100);
      const polling = parseInt($("#pollingInterval").value, 10);
      setKey(draft, "pollingInterval", Number.isNaN(polling) ? undefined : Math.min(Math.max(polling, 1), 300), 2);
      for (const [id, fallback] of toggles) setKey(draft, id, $(`#${id}`).checked, fallback);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

  /// Adds or removes a name from one of the block's lists (`excludeLights`, `excludeScenes`) and saves at once.
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
      status = await request("status");
      if (status.paired) {
        [{ lights }, { groups }] = await Promise.all([request("lights"), request("scenes")]);
      } else {
        lights = [];
        groups = [];
      }
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

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Hue page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Not found": "Introuvable",
    "Pairing…": "Jumelage…",
    "Not paired": "Non jumelé",
    "Not responding": "Ne répond pas",
    "Connected": "Connecté",
    "Address": "Adresse",
    "Lights": "Lampes",
    "Scenes": "Scènes",
    "Press the round link button on top of the bridge.": "Appuyez sur le bouton rond de liaison sur le dessus du pont.",
    "Pair Homeswift with the bridge.": "Jumelez Homeswift avec le pont.",
    "Waiting for the button… {seconds} s left.": "En attente du bouton… encore {seconds} s.",
    "Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.": "Jumelez, puis appuyez sur le bouton de liaison du pont dans la minute. La clé reste dans le dossier du plugin, pas dans config.json.",
    "Pair": "Jumeler",
    "Hue Bridge": "Pont Hue",
    "Looking on the network…": "Recherche sur le réseau…",
    "Bridge address": "Adresse du pont",
    "Leave it empty to find the bridge on the network.": "Laissez vide pour trouver le pont sur le réseau.",
    "Find": "Rechercher",
    "No bridge answered on the network.": "Aucun pont n'a répondu sur le réseau.",
    "Use": "Utiliser",
    "Effects": "Effets",
    "Identify": "Identifier",
    "Flash": "Clignoter",
    "Show in the Home app": "Afficher dans l'app Maison",
    "Leave out of the Home app": "Retirer de l'app Maison",
    "Show its log": "Afficher son journal",
    "Pair with the bridge to see its lights.": "Jumelez le pont pour voir ses lampes.",
    "The bridge has no lights yet: add them in the Hue app.": "Le pont n'a pas encore de lampes : ajoutez-les dans l'app Hue.",
    "Recall {name}": "Rappeler {name}",
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
    "Flash switch": "Interrupteur Clignoter",
    "A switch on each light that makes it flash for five seconds.": "Un interrupteur sur chaque lampe qui la fait clignoter cinq secondes.",
    "Gradient points": "Points du dégradé",
    "On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.": "Sur les rubans à dégradé, une lampe par point de couleur, pour que chaque partie du ruban ait sa couleur.",
    "Unsaved changes.": "Modifications non enregistrées.",
    "Transition": "Transition",
    "Instant": "Instantané",
    "Instant: flashes and fast moods": "Instantané : clignotements et ambiances rapides",
    "Quick (default)": "Rapide (par défaut)",
    "Soft, as the Hue app": "Douce, comme l'app Hue",
    "How long a light takes to reach a new colour or brightness. Shorter is snappier for moods and flashes.": "Le temps que met une lampe pour atteindre une nouvelle couleur ou luminosité. Plus court, c'est plus vif pour les ambiances et les clignotements.",
    "Polling interval (s)": "Intervalle d'interrogation (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "La fréquence à laquelle le pont est interrogé sur les changements faits dans l'app Hue ou avec un interrupteur.",
    "Changes are kept once you save.": "Les modifications sont conservées une fois enregistrées.",
    "Saved. The plugin restarted with these settings.": "Enregistré. Le plugin a redémarré avec ces réglages.",
    "Your Hue Bridge, its lights with their effects, and the scenes of each room, straight from the bridge on your network.": "Votre pont Hue, ses lampes et leurs effets, et les scènes de chaque pièce, directement depuis le pont sur votre réseau.",
    "Settings": "Réglages",
    "Tap a scene to recall it. Each room's scenes are switches in the Home app; the eye leaves one out.": "Touchez une scène pour la rappeler. Les scènes de chaque pièce sont des interrupteurs dans l'app Maison ; l'œil en retire une.",
    "Speed": "Vitesse",
    "In the Home app": "Dans l'app Maison",
    "Save Configuration": "Enregistrer la configuration",
    "an address is required": "une adresse est requise",
    "The link button was not pressed in time.": "Le bouton de liaison n'a pas été pressé à temps.",
    "Press the link button on the Hue Bridge.": "Appuyez sur le bouton de liaison du pont Hue.",
    "The link button was not pressed in time: pair again from the plugin's page.": "Le bouton de liaison n'a pas été pressé à temps : jumelez à nouveau depuis la page du plugin.",
    "No Hue Bridge found on the network: set its address on the plugin's page.": "Aucun pont Hue trouvé sur le réseau : indiquez son adresse sur la page du plugin.",
    "The Hue Bridge refused the application key: pair again from the plugin's page.": "Le pont Hue a refusé la clé d'application : jumelez à nouveau depuis la page du plugin.",
    "Not in the Home app:": "Pas dans l'app Maison :"
  },
  "es": {
    "Not found": "No encontrado",
    "Pairing…": "Emparejando…",
    "Not paired": "Sin emparejar",
    "Not responding": "No responde",
    "Connected": "Conectado",
    "Address": "Dirección",
    "Lights": "Luces",
    "Scenes": "Escenas",
    "Press the round link button on top of the bridge.": "Pulsa el botón redondo de enlace en la parte superior del puente.",
    "Pair Homeswift with the bridge.": "Empareja Homeswift con el puente.",
    "Waiting for the button… {seconds} s left.": "Esperando el botón… quedan {seconds} s.",
    "Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.": "Empareja y pulsa el botón de enlace del puente antes de un minuto. La clave se queda en la carpeta del plugin, no en config.json.",
    "Pair": "Emparejar",
    "Hue Bridge": "Puente Hue",
    "Looking on the network…": "Buscando en la red…",
    "Bridge address": "Dirección del puente",
    "Leave it empty to find the bridge on the network.": "Déjalo vacío para buscar el puente en la red.",
    "Find": "Buscar",
    "No bridge answered on the network.": "Ningún puente ha respondido en la red.",
    "Use": "Usar",
    "Effects": "Efectos",
    "Identify": "Identificar",
    "Flash": "Parpadear",
    "Show in the Home app": "Mostrar en la app Casa",
    "Leave out of the Home app": "Quitar de la app Casa",
    "Show its log": "Ver su registro",
    "Pair with the bridge to see its lights.": "Empareja el puente para ver sus luces.",
    "The bridge has no lights yet: add them in the Hue app.": "El puente aún no tiene luces: añádelas en la app Hue.",
    "Recall {name}": "Activar {name}",
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
    "Flash switch": "Interruptor Parpadear",
    "A switch on each light that makes it flash for five seconds.": "Un interruptor en cada luz que la hace parpadear cinco segundos.",
    "Gradient points": "Puntos del degradado",
    "On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.": "En las tiras con degradado, una luz por punto de color, para que cada parte de la tira tenga su color.",
    "Unsaved changes.": "Cambios sin guardar.",
    "Transition": "Transición",
    "Instant": "Instantánea",
    "Instant: flashes and fast moods": "Instantánea: parpadeos y ambientes rápidos",
    "Quick (default)": "Rápida (predeterminada)",
    "Soft, as the Hue app": "Suave, como la app Hue",
    "How long a light takes to reach a new colour or brightness. Shorter is snappier for moods and flashes.": "Lo que tarda una luz en llegar a un nuevo color o brillo. Más corto es más ágil para ambientes y parpadeos.",
    "Polling interval (s)": "Intervalo de consulta (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "Cada cuánto se pregunta al puente por los cambios hechos en la app Hue o con un interruptor.",
    "Changes are kept once you save.": "Los cambios se conservan al guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. El plugin se ha reiniciado con estos ajustes.",
    "Your Hue Bridge, its lights with their effects, and the scenes of each room, straight from the bridge on your network.": "Tu puente Hue, sus luces con sus efectos y las escenas de cada habitación, directamente desde el puente en tu red.",
    "Settings": "Ajustes",
    "Tap a scene to recall it. Each room's scenes are switches in the Home app; the eye leaves one out.": "Toca una escena para activarla. Las escenas de cada habitación son interruptores en la app Casa; el ojo quita una.",
    "Speed": "Velocidad",
    "In the Home app": "En la app Casa",
    "Save Configuration": "Guardar configuración",
    "an address is required": "se necesita una dirección",
    "The link button was not pressed in time.": "No se ha pulsado el botón de enlace a tiempo.",
    "Press the link button on the Hue Bridge.": "Pulsa el botón de enlace del puente Hue.",
    "The link button was not pressed in time: pair again from the plugin's page.": "No se ha pulsado el botón de enlace a tiempo: vuelve a emparejar desde la página del plugin.",
    "No Hue Bridge found on the network: set its address on the plugin's page.": "No se ha encontrado ningún puente Hue en la red: indica su dirección en la página del plugin.",
    "The Hue Bridge refused the application key: pair again from the plugin's page.": "El puente Hue ha rechazado la clave de aplicación: vuelve a emparejar desde la página del plugin.",
    "Not in the Home app:": "No están en la app Casa:"
  },
  "pt": {
    "Not found": "Não encontrada",
    "Pairing…": "A emparelhar…",
    "Not paired": "Não emparelhada",
    "Not responding": "Não responde",
    "Connected": "Ligada",
    "Address": "Endereço",
    "Lights": "Luzes",
    "Scenes": "Cenas",
    "Press the round link button on top of the bridge.": "Prima o botão redondo de ligação no topo da ponte.",
    "Pair Homeswift with the bridge.": "Emparelhe o Homeswift com a ponte.",
    "Waiting for the button… {seconds} s left.": "À espera do botão… faltam {seconds} s.",
    "Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.": "Emparelhe e prima o botão de ligação da ponte no espaço de um minuto. A chave fica na pasta do plugin, não em config.json.",
    "Pair": "Emparelhar",
    "Hue Bridge": "Ponte Hue",
    "Looking on the network…": "A procurar na rede…",
    "Bridge address": "Endereço da ponte",
    "Leave it empty to find the bridge on the network.": "Deixe vazio para procurar a ponte na rede.",
    "Find": "Procurar",
    "No bridge answered on the network.": "Nenhuma ponte respondeu na rede.",
    "Use": "Usar",
    "Effects": "Efeitos",
    "Identify": "Identificar",
    "Flash": "Piscar",
    "Show in the Home app": "Mostrar na app Casa",
    "Leave out of the Home app": "Retirar da app Casa",
    "Show its log": "Ver o registo",
    "Pair with the bridge to see its lights.": "Emparelhe a ponte para ver as luzes.",
    "The bridge has no lights yet: add them in the Hue app.": "A ponte ainda não tem luzes: adicione-as na app Hue.",
    "Recall {name}": "Ativar {name}",
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
    "Flash switch": "Interruptor Piscar",
    "A switch on each light that makes it flash for five seconds.": "Um interruptor em cada luz que a faz piscar cinco segundos.",
    "Gradient points": "Pontos do gradiente",
    "On gradient lightstrips, a light for each colour point, so each part of the strip takes its own colour.": "Nas fitas com gradiente, uma luz por ponto de cor, para cada parte da fita ter a sua cor.",
    "Unsaved changes.": "Alterações por guardar.",
    "Transition": "Transição",
    "Instant": "Instantânea",
    "Instant: flashes and fast moods": "Instantânea: piscas e ambientes rápidos",
    "Quick (default)": "Rápida (predefinida)",
    "Soft, as the Hue app": "Suave, como a app Hue",
    "How long a light takes to reach a new colour or brightness. Shorter is snappier for moods and flashes.": "O tempo que uma luz demora a chegar a uma nova cor ou brilho. Mais curto é mais vivo para ambientes e piscas.",
    "Polling interval (s)": "Intervalo de consulta (s)",
    "How often the bridge is asked for changes made in the Hue app or with a switch.": "Com que frequência a ponte é consultada sobre as alterações feitas na app Hue ou com um interruptor.",
    "Changes are kept once you save.": "As alterações ficam guardadas quando guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. O plugin reiniciou com estas definições.",
    "Your Hue Bridge, its lights with their effects, and the scenes of each room, straight from the bridge on your network.": "A ponte Hue, as luzes com os seus efeitos e as cenas de cada divisão, diretamente da ponte na sua rede.",
    "Settings": "Definições",
    "Tap a scene to recall it. Each room's scenes are switches in the Home app; the eye leaves one out.": "Toque numa cena para a ativar. As cenas de cada divisão são interruptores na app Casa; o olho retira uma.",
    "Speed": "Velocidade",
    "In the Home app": "Na app Casa",
    "Save Configuration": "Guardar configuração",
    "an address is required": "é necessário um endereço",
    "The link button was not pressed in time.": "O botão de ligação não foi premido a tempo.",
    "Press the link button on the Hue Bridge.": "Prima o botão de ligação da ponte Hue.",
    "The link button was not pressed in time: pair again from the plugin's page.": "O botão de ligação não foi premido a tempo: emparelhe novamente a partir da página do plugin.",
    "No Hue Bridge found on the network: set its address on the plugin's page.": "Nenhuma ponte Hue encontrada na rede: indique o endereço na página do plugin.",
    "The Hue Bridge refused the application key: pair again from the plugin's page.": "A ponte Hue recusou a chave da aplicação: emparelhe novamente a partir da página do plugin.",
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
    <button role="tab" data-tab="lights" class="on" aria-selected="true" aria-controls="tab-lights" data-i18n>Lights</button>
    <button role="tab" data-tab="scenes" aria-selected="false" aria-controls="tab-scenes" data-i18n>Scenes</button>
    <button role="tab" data-tab="settings" aria-selected="false" aria-controls="tab-settings" data-i18n data-action-icon="sliders">Settings</button>
  </div>

  <section id="tab-lights" class="tab-pane" role="tabpanel">
    <div class="accessory-walls"><div class="wall" id="lights"></div></div>
    <div id="hidden-devices" class="hidden-devices"></div>
  </section>

  <section id="tab-scenes" class="tab-pane hidden" role="tabpanel">
    <p class="muted intro" data-i18n>Tap a scene to recall it. Each room's scenes are switches in the Home app; the eye leaves one out.</p>
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
