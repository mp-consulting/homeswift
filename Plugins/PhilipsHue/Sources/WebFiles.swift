// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension PhilipsHuePlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Philips Hue page on the UI's materials: the bridge and its pairing, the lights as the Accessories page's
   widgets, the scenes of each room as tiles painted with their palette, and the settings. The tabs, pairing, address
   form, scene tiles, speed scale and save bar are style.css's, shared with the DIRIGERA page. */

.page-head { align-items: center; }
h2 { margin: 0 0 10px; }
.intro { margin: 0 0 14px; font-size: 0.875rem; }

/* The bridge. */
.bridge-card .server-head { display: flex; align-items: center; gap: 14px; }
.bridge-card .who { flex: 1; min-width: 0; }
.bridge-card .who strong { display: block; }
.found { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }

/* Scenes: a section per room, a tile per scene; a smart scene says so under its name. */
.room { margin-bottom: 22px; }
.room-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 0 0 10px; }
.room-head h2 { margin: 0; font-size: 1.0625rem; }
.scene .kind { position: relative; z-index: 1; font-size: 0.75rem; opacity: 0.85; }

/* Lights as the Accessories page draws them; the ones left out of the Home app below, to bring back. */
.accessory-walls { margin: 0; }

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Hue page: the bridge (found on the network or at an address, paired with its link button), the
// lights as the Accessories page draws them (its widgets: power, brightness, colour; effects in All controls), the
// scenes of each room as tiles painted with their palette (a tap recalls one, the eye leaves it out of the Home app),
// and the settings: the transition and what the Home app shows. Refreshed every two seconds while visible; saving
// writes this instance's block. The tabs, scene pictures, speed scale and tile text come from plugin.js.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, tile, request, explain, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let status = {};
  let lights = [];
  let groups = [];
  let block = {};

  homeswift.tabs("hue-tab");

  // MARK: The bridge

  // The end of the minute the link button can be pressed in: the bridge's own when it is pairing (from this page, another,
  // or the plugin at start without a key), else the one this page's Pair started. A second's tick redraws it meanwhile.
  let pairingUntil = 0;
  let asking = false;
  let ticker = 0;
  function followPairing() {
    if (status.pairing && status.pairingSecondsLeft != null) pairingUntil = Date.now() + status.pairingSecondsLeft * 1000;
    else if (!status.pairing && !asking) pairingUntil = 0;
    const on = status.pairing || Date.now() < pairingUntil;
    if (on && !ticker) ticker = setInterval(drawBridge, 1000);
    if (!on && ticker) { clearInterval(ticker); ticker = 0; }
  }

  /// The address form, made once and kept at the end of the card, so it stays open and keeps what was typed; until a
  /// person types, it shows the address in config.json, else the bridge's.
  let addressTyped = false;
  const addressInput = el("input", { type: "text", id: "bridge-address", placeholder: "192.168.1.20", inputmode: "url", autocomplete: "off" });
  addressInput.addEventListener("input", () => { addressTyped = true; });
  const foundList = el("div", { class: "found" });
  const addressBox = el("details", { class: "address-box" },
    el("summary", { text: t("Bridge address") }),
    // The title, then the input with its buttons on one row (so they line up at any width), then the help.
    el("div", { class: "address" },
      el("label", { class: "field-title", htmlFor: "bridge-address", text: t("Address") }),
      el("div", { class: "address-row" }, addressInput,
        el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
          const { hosts } = await request("discover");
          foundList.replaceChildren(...(hosts.length ? hosts.map((host) => el("button", { actionIcon: "bridge", text: host, onclick: () => { addressInput.value = host; addressTyped = true; } })) : [el("span", { class: "muted", text: t("No bridge answered on the network.") })]));
        }) }),
        el("button", { class: "primary", actionIcon: "check", text: t("Use"), onclick: (event) => act(event.currentTarget, async () => {
          const host = addressInput.value.trim();
          await updateBlock((draft) => { setKey(draft, "host", host, ""); });
          if (host) await request("host", { method: "POST", body: { host } });
          block = await readBlock();
          addressTyped = false;
          await refresh();
        }) })),
      el("span", { class: "help", text: t("Leave it empty to find the bridge on the network.") })),
    foundList);
  $("#bridge").append(addressBox);

  /// The card above the address form, drawn again only when what it shows changed; while pairing, the second's tick
  /// only counts down.
  let bridgeKey = "";
  let countdown = null;
  function drawBridge() {
    if (!addressTyped && document.activeElement !== addressInput) addressInput.value = block.host || status.host || "";
    const paired = status.paired;
    const pairing = status.pairing || Date.now() < pairingUntil;
    const seconds = Math.max(0, Math.ceil((pairingUntil - Date.now()) / 1000));
    const waiting = () => t("Waiting for the button… {seconds} s left.", { seconds });
    const key = JSON.stringify([{ ...status, pairingSecondsLeft: null }, pairing]);
    if (key === bridgeKey) {
      if (countdown) countdown.textContent = waiting();
      return;
    }
    bridgeKey = key;
    const [state, kind] = !status.host ? [t("Not found"), "away"] : !paired ? [pairing ? t("Pairing…") : t("Not paired"), pairing ? "standby" : "away"]
      : status.error ? [t("Not responding"), "away"] : [t("Connected"), "on"];
    const facts = paired && status.host
      ? el("div", { class: "facts" },
        homeswift.fact(t("Address"), status.host), homeswift.fact(t("Lights"), String(status.lights ?? 0)), homeswift.fact(t("Scenes"), String(status.scenes ?? 0)))
      : null;
    const note = el("p", { class: "muted", text: pairing ? waiting() : t("Pair, then press the link button on the bridge within a minute. The key stays in the plugin's folder, not in config.json.") });
    countdown = pairing ? note : null;
    const pairBox = status.host && !paired ? el("div", { class: `pair-prompt ${pairing ? "pairing" : ""}` },
      el("span", { class: "link-button", "aria-hidden": "true" }, icon("link")),
      el("div", {},
        el("p", {}, el("strong", { text: pairing ? t("Press the round link button on top of the bridge.") : t("Pair Homeswift with the bridge.") })),
        note,
        pairing ? null : el("div", { class: "actions" }, el("button", { class: "primary", actionIcon: "key", text: t("Pair"), onclick: (event) => pair(event.currentTarget) })))) : null;
    const card = $("#bridge");
    for (const node of [...card.children]) if (node !== addressBox) node.remove();
    addressBox.before(...[
      el("div", { class: "server-head" },
        tile("bridge", paired && !status.error ? "violet" : "grey"),
        el("div", { class: "who" }, el("strong", { text: t("Hue Bridge") }), el("div", { class: "muted", text: [status.host, status.bridgeID?.toUpperCase()].filter(Boolean).join(" · ") || t("Looking on the network…") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      facts, pairBox,
      status.error && paired ? explain({
        error: `The Hue Bridge at ${status.host} did not answer: ${status.error}`,
        context: "The Homeswift Philips Hue plugin reads every resource of the bridge's local API v2 (GET https://<bridge>/clip/v2/resource) every two seconds with its application key.",
        device: { host: status.host },
      }) : null].filter(Boolean));
  }

  async function pair(button) {
    pairingUntil = Date.now() + 60000;
    asking = true;
    followPairing();
    drawBridge();
    try {
      await act(button, () => request("pair", { method: "POST", body: {} }), null);
      pairingUntil = 0;
    } catch (e) {
      pairingUntil = 0;
      alert(e.message);
    } finally {
      asking = false;
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
  const pictures = homeswift.scenePictures({ refresh: () => refresh(), toggleHidden: (key) => toggleList("excludeScenes", key) });

  function sceneTile(scene) {
    const colours = scene.colours?.length ? scene.colours : ["#8e8e93"];
    const background = colours.length === 1 ? colours[0] : `linear-gradient(135deg, ${colours.join(", ")})`;
    const button = el("div", {
      class: `scene ${scene.active ? "active" : ""} ${scene.hidden ? "hidden-scene" : ""} ${homeswift.textStyle(colours)}`, role: "button", tabindex: 0, style: `background: ${background}`,
      "aria-label": t("Recall {name}", { name: scene.name }), "aria-pressed": String(scene.active),
    },
      scene.active ? el("span", { class: "badge", text: t("Active") }) : null,
      el("span", { class: "name", text: scene.name }),
      // A smart scene says so, unless its name already does.
      scene.smart && !/natural light/i.test(scene.name) ? el("span", { class: "kind", text: t("Natural light") }) : null);
    const recall = async () => {
      button.classList.add("busy");
      try { await request("recall", { method: "POST", body: { id: scene.id } }); await refresh(); } catch (e) { alert(e.message); } finally { button.classList.remove("busy"); }
    };
    button.addEventListener("click", recall);
    button.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); recall(); } });
    return pictures.decorate(button, scene, `${scene.room}/${scene.name}`);
  }

  /// A section per room, its head drawn again when the room changes and a tile per scene drawn again only when its own
  /// scene changes, so a recall does not repaint every picture of the room.
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
    renderKeyed(list, groups.map((group) => ({ id: group.id })), (group) => group.id,
      () => el("section", { class: "room" }, el("div", { class: "room-head" }), el("div", { class: "scene-tiles" })));
    groups.forEach((group, index) => {
      const [head, tiles] = list.children[index].children;
      const headKey = JSON.stringify([group.name, group.kind, group.on]);
      if (head.dataset.json !== headKey) {
        head.dataset.json = headKey;
        head.replaceChildren(el("h2", { text: group.name }),
          el("span", { class: `pill status ${group.on ? "on" : "standby"}`, text: group.kind === "zone" ? (group.on ? t("Zone on") : t("Zone off")) : (group.on ? t("Room on") : t("Room off")) }));
      }
      renderKeyed(tiles, group.scenes.map((scene) => ({ ...scene, room: group.name })), (scene) => scene.id, sceneTile);
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
    followPairing();
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
    "Not responding": "Ne répond pas",
    "Connected": "Connecté",
    "Address": "Adresse",
    "Lights": "Lampes",
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
    "Flash": "Clignoter",
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
    "Tap a scene to recall it. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.": "Touchez une scène pour la rappeler. Déposez une image sur une tuile pour la donner à la scène. Les scènes de chaque pièce sont des interrupteurs dans l'app Maison ; le menu ⋯ d'une tuile en retire une.",
    "the picture must be a JPEG, PNG or WebP image": "l'image doit être au format JPEG, PNG ou WebP",
    "the picture is larger than {0} KB": "l'image dépasse {0} Ko",
    "the picture has no valid name": "l'image n'a pas de nom valide",
    "a scene and a picture are required": "une scène et une image sont requises",
    "a scene is required": "une scène est requise",
    "no picture for that scene": "aucune image pour cette scène"
  },
  "es": {
    "Not found": "No encontrado",
    "Pairing…": "Emparejando…",
    "Not responding": "No responde",
    "Connected": "Conectado",
    "Address": "Dirección",
    "Lights": "Luces",
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
    "Flash": "Parpadear",
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
    "Tap a scene to recall it. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.": "Toca una escena para activarla. Suelta una imagen en un mosaico para dársela a la escena. Las escenas de cada habitación son interruptores en la app Casa; el menú ⋯ de un mosaico quita una.",
    "the picture must be a JPEG, PNG or WebP image": "la imagen debe ser JPEG, PNG o WebP",
    "the picture is larger than {0} KB": "la imagen supera los {0} KB",
    "the picture has no valid name": "la imagen no tiene un nombre válido",
    "a scene and a picture are required": "se necesitan una escena y una imagen",
    "a scene is required": "se necesita una escena",
    "no picture for that scene": "no hay imagen para esa escena"
  },
  "pt": {
    "Not found": "Não encontrada",
    "Pairing…": "A emparelhar…",
    "Not responding": "Não responde",
    "Connected": "Ligada",
    "Address": "Endereço",
    "Lights": "Luzes",
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
    "Flash": "Piscar",
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
    "Tap a scene to recall it. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.": "Toque numa cena para a ativar. Largue uma imagem num mosaico para a dar à cena. As cenas de cada divisão são interruptores na app Casa; o menu ⋯ de um mosaico retira uma.",
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
    <button role="tab" data-tab="scenes" aria-selected="false" aria-controls="tab-scenes" data-i18n data-action-icon="star">Scenes</button>
    <button role="tab" data-tab="settings" aria-selected="false" aria-controls="tab-settings" data-i18n data-action-icon="sliders">Settings</button>
  </div>

  <section id="tab-lights" class="tab-pane" role="tabpanel">
    <div class="accessory-walls"><div class="wall" id="lights"></div></div>
    <div id="hidden-devices" class="hidden-devices"></div>
  </section>

  <section id="tab-scenes" class="tab-pane hidden" role="tabpanel">
    <p class="muted intro" data-i18n>Tap a scene to recall it. Drop a picture on a tile to give the scene one. Each room's scenes are switches in the Home app; a tile's ⋯ menu leaves one out.</p>
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
