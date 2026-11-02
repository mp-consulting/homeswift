// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DirigeraPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The IKEA DIRIGERA page on the UI's materials: the hubs (or the card leading to their Setup), the devices as the Accessories page's
   widgets, the hub's scenes as tiles, and the settings. The bridge card, tabs, scene tiles, speed scale
   and save bar are style.css's, shared with the Philips Hue page. */

.page-head { align-items: center; }
h2 { margin: 0 0 10px; }
.intro { margin: 0 0 14px; font-size: 0.875rem; }

/* Scenes: the hub's icon on each tile (hidden under a picture), and a flash when one runs. */
.scene .glyph { position: absolute; top: 12px; left: 14px; z-index: 1; width: 28px; height: 28px; color: rgba(255, 255, 255, 0.92); }
.scene .glyph svg { width: 28px; height: 28px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
.scene.pictured .glyph { display: none; }
.scene.light:not(.pictured) .glyph { color: rgba(29, 29, 31, 0.78); }
.scene.fired { animation: fired 0.9s var(--ease-out); }
@keyframes fired { 0% { box-shadow: 0 0 0 0 rgba(255, 214, 10, 0.7); } 100% { box-shadow: 0 0 0 14px rgba(255, 214, 10, 0); } }
@media (prefers-reduced-motion: reduce) { .scene.fired { animation: none; } }
/* A scene on the hub's schedule (wake-up): greyed as a hidden one, dashed, a clock badge, nothing to tap. */
.scene.unusable { border-style: dashed; cursor: default; box-shadow: none; }
.scene.unusable:hover, .scene.unusable:active { box-shadow: none; transform: none; }
.scene .badge.scheduled { left: auto; right: 10px; display: inline-flex; align-items: center; gap: 4px; }
.scene .badge.scheduled svg { width: 12px; height: 12px; }

/* Devices as the Accessories page draws them; the ones left out of the Home app below, to bring back. */
.accessory-walls { margin: 0; }

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The IKEA DIRIGERA page: the hubs (from config.json and paired through Setup on Add accessories: this page leads there);
// the lights, outlets, sensors, blinds, air purifiers and remotes as the Accessories page draws them (its widgets); the hubs' scenes as tiles (a tap
// runs one, the eye leaves it out of the Home app); and the settings. Refreshed every two seconds while visible;
// saving writes this instance's block. The Setup card, tabs, scene pictures, speed scale and tile text come from
// plugin.js.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, tile, fact, explain, request, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let hubs = [];
  let devices = [];
  let scenes = [];
  let block = {};

  homeswift.tabs("dirigera-tab");

  // MARK: Hubs

  /// The hubs: until one is paired, the card that leads to its Setup on Add accessories (the page pairs nowhere else);
  /// then a block per hub (config.json's and the ones Setup paired) with its address, state and counts, Pair again (or
  /// Pair) in its ⋯ menu, and Explain when it does not answer.
  let hubsLoaded = false;
  function drawHubs() {
    const card = $("#hubs");
    // Nothing until the plugin has answered which hubs it has.
    if (!hubsLoaded) return;
    const key = JSON.stringify(hubs);
    if (card.dataset.json === key) return;
    card.dataset.json = key;
    if (!hubs.some((hub) => hub.paired)) {
      card.replaceChildren(homeswift.setupCard({
        title: t("Set up a DIRIGERA hub"),
        text: t("Add accessories finds the hub on the network, or asks for its address, then for a press on its action button. The token stays in the vault, not in config.json."),
        glyph: "bridge", tone: "blue",
      }));
      return;
    }
    card.replaceChildren(el("section", { class: "card bridge-card" }, ...hubs.map(hubBlock)));
  }

  function hubBlock(hub) {
    const name = hub.name || t("DIRIGERA hub");
    const [state, kind] = !hub.paired ? [t("Not paired"), "away"] : hub.error ? [t("Not responding"), "away"]
      : hub.connected === false ? [t("Connecting…"), "standby"] : [t("Connected"), "on"];
    const setUp = { label: hub.paired ? t("Pair again") : t("Pair"), icon: "pair", href: homeswift.setupAddress({ start: true }) };
    return el("div", { class: "bridge" },
      el("div", { class: "server-head" },
        tile("bridge", hub.paired && !hub.error ? "blue" : "grey"),
        el("div", { class: "who" }, el("strong", { text: name }), el("div", { class: "muted", text: hub.host })),
        el("span", { class: `pill status ${kind}`, text: state }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: [name, hub.host].filter(Boolean).join(" ") }), () => [setUp])),
      hub.paired ? el("div", { class: "facts" }, ...[[t("Address"), hub.host], [t("Devices"), hub.devices ?? 0], [t("Scenes"), hub.scenes ?? 0]]
        .map(([label, value]) => fact(label, String(value)))) : null,
      hub.paired && hub.error ? explain({
        error: `The DIRIGERA hub at ${hub.host} did not answer: ${hub.error}`,
        context: "The Homeswift DIRIGERA plugin reads GET https://<hub>:8443/v1/devices and /v1/scenes with its token, and follows the hub's websocket for changes.",
        device: { host: hub.host },
      }) : null);
  }

  // MARK: Lights, as the Accessories page draws them

  /// The plugin's accessories (not its scene switches), read again when the set of devices changes.
  let accessories = [];
  let shapeKey = "";
  async function loadAccessories() {
    const all = await homeswift.api("/api/accessories");
    accessories = all.filter((accessory) => accessory.platform === "Dirigera" && accessory.platformName === homeswift.name && !accessory.id.startsWith("Dirigera:scenes:"));
  }

  /// The devices left out of the Home app, as buttons that bring one back.
  function drawHidden(names) {
    homeswift.drawHidden($("#hidden-devices"), names, (name) => toggleList("excludeDevices", name));
  }

  // The devices' finder, over the plugin's widgets (plugin.js, as the Hue page's): a search, a room, and filters by
  // what a device is; each accessory takes its room and kind from its group's first part.
  const kinds = { lights: ["light"], outlets: ["outlet"], sensors: ["contact", "motion", "lightSensor", "environment", "leak"], covers: ["blinds", "airPurifier"], remotes: ["controller"] };
  const deviceFinder = homeswift.finder({
    toolbar: $("#device-toolbar"), placeholder: t("Search devices"), prefix: "d", foldKey: "dirigera-folded-rooms", draw: () => drawDevices(),
    items: () => accessories.map((accessory) => {
      const device = devices.find((entry) => entry.group === accessory.id.slice("Dirigera:".length)) ?? {};
      return { id: accessory.id, name: accessory.name, room: device.room ?? null, roomID: device.room ?? null, device };
    }),
    filters: [
      ["lights", t("Lights"), "bulb", (item) => kinds.lights.includes(item.device.kind)],
      ["outlets", t("Outlets"), "outlet", (item) => kinds.outlets.includes(item.device.kind)],
      ["sensors", t("Sensors"), "sensor", (item) => kinds.sensors.includes(item.device.kind)],
      ["covers", t("Blinds and air"), "blind", (item) => kinds.covers.includes(item.device.kind)],
      ["remotes", t("Remotes"), "switch", (item) => kinds.remotes.includes(item.device.kind)],
      ["battery", t("Low battery"), "warning", (item) => typeof item.device.battery === "number" && item.device.battery < 10],
      ["unreachable", t("No Response"), "warning", (item) => item.device.reachable === false],
    ],
  });

  let listening = false;
  async function drawDevices() {
    const list = $("#devices");
    const empty = (text) => list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text })));
    // A product's parts (a VALLHORN's two sensors) share a name: it shows once.
    drawHidden([...new Set(devices.filter((item) => item.hidden).map((item) => item.name))]);
    const paired = hubs.some((hub) => hub.paired);
    deviceFinder.show(paired && accessories.length > 0);
    if (!paired) return empty(t("Pair a hub to see its devices."));
    // Read again when the devices the plugin has published change (it says which are).
    const key = [...new Set(devices.filter((item) => item.published).map((item) => item.group))].sort().join(",");
    if (key !== shapeKey) {
      shapeKey = key;
      await loadAccessories().catch(() => {});
    }
    if (!accessories.length) return empty(t("The hub has no devices yet: add them in the IKEA Home smart app."));
    deviceFinder.show(true);
    // A widget per accessory, drawn once in its room's wall: its values follow the hub's event stream.
    deviceFinder.draw(list, {
      countText: (shown, total) => t("{shown} of {total} devices", { shown, total }),
      emptyText: t("No device matches the search and filters."), bodyClass: "wall",
      render: (body, items) => renderKeyed(body, items.map((item) => ({ id: item.id, name: item.name, services: accessories.find((accessory) => accessory.id === item.id)?.services.length })), (item) => item.id,
        (item) => HomeswiftWidgets.card(accessories.find((accessory) => accessory.id === item.id), { actions: actionsFor })),
    });
    if (!listening) { HomeswiftWidgets.listen(); listening = true; }
  }

  /// The widget's ⋯ menu, after All controls: what this page adds.
  function actionsFor(accessory) {
    // The accessory's group (a device's own id, or a remote's or a VALLHORN's): its first part stands for it.
    const id = accessory.id.slice("Dirigera:".length);
    const item = devices.find((entry) => entry.group === id);
    return [
      { label: t("Identify"), icon: "identify", onSelect: () => request("identify", { method: "POST", body: { host: item?.host, id } }).catch((e) => HomeswiftCommon.showAlert(e.message)) },
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
    const tone = tones[hash % tones.length];
    return { glyph: glyphs[key ?? "home"], gradient: `linear-gradient(135deg, ${tone})`, text: homeswift.textStyle(tone.split(",")) };
  }

  // A scene's picture: dropped on its tile or chosen from its menu (plugin.js); its ⋯ menu also leaves it out of the
  // Home app, by name.
  const pictures = homeswift.scenePictures({ refresh: () => refresh(), toggleHidden: (name) => toggleList("excludeScenes", name) });

  function sceneTile(scene) {
    const { glyph, gradient, text } = sceneStyle(scene);
    const art = document.createElement("span");
    art.className = "glyph";
    art.innerHTML = `<svg viewBox="0 0 24 24">${glyph}</svg>`;
    // Wake-up and playlist scenes run on the hub's schedule: greyed with a badge, they neither run nor reach the
    // Home app.
    if (scene.runnable === false) {
      const why = t("Runs on the hub's schedule: it cannot be run from here or from the Home app.");
      return el("div", { class: `scene hidden-scene unusable ${text}`, title: why, "aria-disabled": "true", style: `background: ${gradient}`, "aria-label": `${scene.name}. ${why}` },
        art, el("span", { class: "badge scheduled" }, icon("history"), scene.type === "wakeUpScene" ? t("Wake-up") : t("Scheduled")),
        el("span", { class: "name", text: scene.name }));
    }
    const tileNode = el("div", { class: `scene ${scene.hidden ? "hidden-scene" : ""} ${text}`, role: "button", tabindex: 0, style: `background: ${gradient}`, "aria-label": t("Run {name}", { name: scene.name }) },
      art,
      el("span", { class: "name", text: scene.name }));
    const run = async () => {
      tileNode.classList.add("busy");
      try {
        await request("trigger", { method: "POST", body: { host: scene.host, id: scene.id } });
        tileNode.classList.remove("fired");
        void tileNode.offsetWidth;
        tileNode.classList.add("fired");
      } catch (e) { HomeswiftCommon.showAlert(e.message); } finally { tileNode.classList.remove("busy"); }
    };
    tileNode.addEventListener("click", run);
    tileNode.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); run(); } });
    return pictures.decorate(tileNode, scene, scene.name);
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

  const speed = homeswift.speedScale({
    help: t("How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for animated scenes."),
    onInput: markDirty,
  });
  const scenesToggle = el("input", { type: "checkbox", id: "scenes-toggle" });

  function buildSettings() {
    $("#speed").append(speed.element);
    scenesToggle.addEventListener("change", markDirty);
    $("#options").append(el("label", { class: "toggle" }, el("span", { class: "switch" }, scenesToggle, el("span")),
      el("span", {}, el("span", { class: "field-title", text: t("Scenes") }), el("span", { class: "help", text: t("A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.") }))));
    $("#save").addEventListener("click", (event) => act(event.currentTarget, save));
  }

  function fillSettings() {
    if (dirty) return;
    speed.set(block.transitionMs);
    $("#save-state").textContent = t("Changes are kept once you save.");
    scenesToggle.checked = block.scenes ?? true;
  }

  async function save() {
    await updateBlock((draft) => {
      setKey(draft, "transitionMs", speed.value(), 100);
      setKey(draft, "scenes", scenesToggle.checked, true);
    });
    dirty = false;
    block = await readBlock();
    $("#save-state").textContent = t("Saved. The plugin restarted with these settings.");
  }

  /// Adds or removes a name from one of the block's lists (`excludeDevices`, `excludeScenes`), saved at once.
  async function toggleList(key, name) {
    const written = await homeswift.toggleList(key, name);
    if (!written) return;
    block = written;
    setTimeout(refresh, 1500);
  }

  // MARK: Refresh

  /// The hubs and the lists together; the lists count only once a hub is paired.
  async function refresh() {
    const settle = (promise) => promise.then((value) => ({ value }), (error) => ({ error }));
    try {
      const [answer, deviceList, sceneList] = await Promise.all([request("hubs"), settle(request("devices")), settle(request("scenes"))]);
      if (answer.hubs.some((hub) => hub.paired)) {
        const failed = deviceList.error ?? sceneList.error;
        if (failed) throw failed;
        ({ devices } = deviceList.value);
        ({ scenes } = sceneList.value);
      } else {
        devices = [];
        scenes = [];
      }
      ({ hubs } = answer);
      hubsLoaded = true;
    } catch (e) {
      // The card keeps what it showed; the lists empty.
      hubs = [];
      hubsLoaded = false;
    }
    drawHubs();
    drawDevices();
    drawScenes();
  }

  buildSettings();
  readBlock().then((value) => { block = value || {}; fillSettings(); }).catch(() => {});
  poll(refresh, 2000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The IKEA DIRIGERA page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Search devices": "Rechercher des appareils",
    "Sensors": "Capteurs",
    "Blinds and air": "Stores et air",
    "Remotes": "Télécommandes",
    "{shown} of {total} devices": "{shown} appareils sur {total}",
    "No device matches the search and filters.": "Aucun appareil ne correspond à la recherche et aux filtres.",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Set up a DIRIGERA hub": "Configurer un hub DIRIGERA",
    "Add accessories finds the hub on the network, or asks for its address, then for a press on its action button. The token stays in the vault, not in config.json.": "Ajouter des accessoires trouve le hub sur le réseau, ou demande son adresse, puis un appui sur son bouton d'action. Le jeton reste dans le coffre, pas dans config.json.",
    "Pair a hub to see its devices.": "Jumelez un hub pour voir ses appareils.",
    "The hub has no devices yet: add them in the IKEA Home smart app.": "Le hub n'a pas encore d'appareils : ajoutez-les dans l'app IKEA Home smart.",
    "Run {name}": "Lancer {name}",
    "Wake-up": "Réveil",
    "Scheduled": "Programmée",
    "Runs on the hub's schedule: it cannot be run from here or from the Home app.": "Suit la programmation du hub : elle ne se lance ni d'ici ni depuis l'app Maison.",
    "No scenes yet: make some in the IKEA Home smart app.": "Pas encore de scènes : créez-en dans l'app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Jumelez un hub pour voir ses scènes.",
    "Unsaved changes.": "Modifications non enregistrées.",
    "Medium": "Moyenne",
    "How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for animated scenes.": "La vitesse à laquelle une lampe atteint une nouvelle intensité ou couleur. Rapide par défaut ; Extrême change aussitôt, le plus vif pour les scènes animées.",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Un interrupteur par scène du hub. L'allumer la lance ; l'éteindre dans les 30 secondes l'annule.",
    "Changes are kept once you save.": "Les modifications sont conservées une fois enregistrées.",
    "Saved. The plugin restarted with these settings.": "Enregistré. Le plugin a redémarré avec ces réglages.",
    "{n} device": "{n} appareil",
    "{n} devices": "{n} appareils",
    "{n} scene": "{n} scène",
    "{n} scenes": "{n} scènes",
    "Your DIRIGERA hubs, their lights, sensors, blinds and remotes room by room, and their scenes, straight from the hub on your network.": "Vos hubs DIRIGERA, leurs lampes, capteurs, stores et télécommandes pièce par pièce, et leurs scènes, directement depuis le hub de votre réseau.",
    "Devices": "Appareils",
    "Save Configuration": "Enregistrer la configuration",
    "Not in the Home app:": "Pas dans l'app Maison :",
    "Tap a scene to run it. Drop a picture on a tile to give the scene one. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it; a tile's ⋯ menu leaves one out.": "Touchez une scène pour la lancer. Déposez une image sur une tuile pour la donner à la scène. Dans l'app Maison, chaque scène est un interrupteur : l'allumer la lance, l'éteindre dans les 30 secondes l'annule ; le menu ⋯ d'une tuile en retire une.",
    "the picture must be a JPEG, PNG or WebP image": "l'image doit être au format JPEG, PNG ou WebP",
    "the picture is larger than {0} KB": "l'image dépasse {0} Ko",
    "the picture has no valid name": "l'image n'a pas de nom valide",
    "a scene and a picture are required": "une scène et une image sont requises",
    "a scene is required": "une scène est requise",
    "no picture for that scene": "aucune image pour cette scène"
  },
  "es": {
    "Search devices": "Buscar dispositivos",
    "Sensors": "Sensores",
    "Blinds and air": "Persianas y aire",
    "Remotes": "Mandos",
    "{shown} of {total} devices": "{shown} de {total} dispositivos",
    "No device matches the search and filters.": "Ningún dispositivo coincide con la búsqueda y los filtros.",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Set up a DIRIGERA hub": "Configurar un hub DIRIGERA",
    "Add accessories finds the hub on the network, or asks for its address, then for a press on its action button. The token stays in the vault, not in config.json.": "Añadir accesorios encuentra el hub en la red, o pide su dirección, y luego que pulses su botón de acción. El token se queda en la bóveda, no en config.json.",
    "Pair a hub to see its devices.": "Empareja un hub para ver sus dispositivos.",
    "The hub has no devices yet: add them in the IKEA Home smart app.": "El hub aún no tiene dispositivos: añádelos en la app IKEA Home smart.",
    "Run {name}": "Activar {name}",
    "Wake-up": "Despertar",
    "Scheduled": "Programada",
    "Runs on the hub's schedule: it cannot be run from here or from the Home app.": "Sigue la programación del hub: no se puede activar desde aquí ni desde la app Casa.",
    "No scenes yet: make some in the IKEA Home smart app.": "Aún no hay escenas: créalas en la app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Empareja un hub para ver sus escenas.",
    "Unsaved changes.": "Cambios sin guardar.",
    "Medium": "Media",
    "How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for animated scenes.": "La rapidez con la que una luz llega a un nuevo nivel o color. Rápida es la predeterminada; Extrema cambia al instante, lo más ágil para las escenas animadas.",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Un interruptor por escena del hub. Encenderlo la activa; apagarlo antes de 30 segundos la deshace.",
    "Changes are kept once you save.": "Los cambios se conservan al guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. El plugin se ha reiniciado con estos ajustes.",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} scene": "{n} escena",
    "{n} scenes": "{n} escenas",
    "Your DIRIGERA hubs, their lights, sensors, blinds and remotes room by room, and their scenes, straight from the hub on your network.": "Tus hubs DIRIGERA, sus luces, sensores, persianas y mandos habitación por habitación, y sus escenas, directamente desde el hub de tu red.",
    "Devices": "Dispositivos",
    "Save Configuration": "Guardar configuración",
    "Not in the Home app:": "No están en la app Casa:",
    "Tap a scene to run it. Drop a picture on a tile to give the scene one. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it; a tile's ⋯ menu leaves one out.": "Toca una escena para activarla. Suelta una imagen en un mosaico para dársela a la escena. En la app Casa cada escena es un interruptor: encenderlo la activa y apagarlo antes de 30 segundos la deshace; el menú ⋯ de un mosaico quita una.",
    "the picture must be a JPEG, PNG or WebP image": "la imagen debe ser JPEG, PNG o WebP",
    "the picture is larger than {0} KB": "la imagen supera los {0} KB",
    "the picture has no valid name": "la imagen no tiene un nombre válido",
    "a scene and a picture are required": "se necesitan una escena y una imagen",
    "a scene is required": "se necesita una escena",
    "no picture for that scene": "no hay imagen para esa escena"
  },
  "pt": {
    "Search devices": "Procurar dispositivos",
    "Sensors": "Sensores",
    "Blinds and air": "Estores e ar",
    "Remotes": "Comandos",
    "{shown} of {total} devices": "{shown} de {total} dispositivos",
    "No device matches the search and filters.": "Nenhum dispositivo corresponde à pesquisa e aos filtros.",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Set up a DIRIGERA hub": "Configurar um hub DIRIGERA",
    "Add accessories finds the hub on the network, or asks for its address, then for a press on its action button. The token stays in the vault, not in config.json.": "Adicionar acessórios encontra o hub na rede, ou pede o endereço, e depois que prima o botão de ação. O token fica no cofre, não em config.json.",
    "Pair a hub to see its devices.": "Emparelhe um hub para ver os seus dispositivos.",
    "The hub has no devices yet: add them in the IKEA Home smart app.": "O hub ainda não tem dispositivos: adicione-os na app IKEA Home smart.",
    "Run {name}": "Ativar {name}",
    "Wake-up": "Despertar",
    "Scheduled": "Programada",
    "Runs on the hub's schedule: it cannot be run from here or from the Home app.": "Segue o horário do hub: não pode ser ativada daqui nem a partir da app Casa.",
    "No scenes yet: make some in the IKEA Home smart app.": "Ainda não há cenas: crie-as na app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Emparelhe um hub para ver as cenas.",
    "Unsaved changes.": "Alterações por guardar.",
    "Medium": "Média",
    "How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for animated scenes.": "A rapidez com que uma luz chega a um novo nível ou cor. Rápida é a predefinida; Extrema muda de imediato, o mais vivo para as cenas animadas.",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Um interruptor por cena do hub. Ligá-lo ativa-a; desligá-lo nos 30 segundos seguintes anula-a.",
    "Changes are kept once you save.": "As alterações ficam guardadas quando guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. O plugin reiniciou com estas definições.",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} scene": "{n} cena",
    "{n} scenes": "{n} cenas",
    "Your DIRIGERA hubs, their lights, sensors, blinds and remotes room by room, and their scenes, straight from the hub on your network.": "Os hubs DIRIGERA, as luzes, sensores, estores e comandos divisão a divisão, e as cenas, diretamente do hub na sua rede.",
    "Devices": "Dispositivos",
    "Save Configuration": "Guardar configuração",
    "Not in the Home app:": "Fora da app Casa:",
    "Tap a scene to run it. Drop a picture on a tile to give the scene one. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it; a tile's ⋯ menu leaves one out.": "Toque numa cena para a ativar. Largue uma imagem num mosaico para a dar à cena. Na app Casa cada cena é um interruptor: ligá-lo ativa-a e desligá-lo nos 30 segundos seguintes anula-a; o menu ⋯ de um mosaico retira uma.",
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
      <p class="muted" data-i18n>Your DIRIGERA hubs, their lights, sensors, blinds and remotes room by room, and their scenes, straight from the hub on your network.</p>
    </div>
  </div>

  <div id="hubs"></div>

  <div class="group tabs main-tabs" role="tablist">
    <button role="tab" data-tab="devices" class="on" aria-selected="true" aria-controls="tab-devices" data-i18n data-action-icon="accessory">Devices</button>
    <button role="tab" data-tab="scenes" aria-selected="false" aria-controls="tab-scenes" data-i18n data-action-icon="star">Scenes</button>
    <button role="tab" data-tab="settings" aria-selected="false" aria-controls="tab-settings" data-i18n data-action-icon="sliders">Settings</button>
  </div>

  <section id="tab-devices" class="tab-pane" role="tabpanel">
    <div id="device-toolbar" class="finder"></div>
    <div class="accessory-walls" id="devices"></div>
    <div id="hidden-devices" class="hidden-devices"></div>
  </section>

  <section id="tab-scenes" class="tab-pane hidden" role="tabpanel">
    <p class="muted intro" data-i18n>Tap a scene to run it. Drop a picture on a tile to give the scene one. In the Home app each scene is a switch: on runs it, off within 30 seconds undoes it; a tile's ⋯ menu leaves one out.</p>
    <div id="scenes" class="scene-tiles"></div>
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
