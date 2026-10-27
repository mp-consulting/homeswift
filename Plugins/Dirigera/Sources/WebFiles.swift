// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DirigeraPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The IKEA DIRIGERA page on the UI's materials: the hubs and their pairing, the devices as the Accessories page's
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
// The IKEA DIRIGERA page: the hubs (from config.json and found on the network), each paired with its action button;
// the lights, outlets and sensors as the Accessories page draws them (its widgets); the hubs' scenes as tiles (a tap
// runs one, the eye leaves it out of the Home app); and the settings. Refreshed every two seconds while visible;
// saving writes this instance's block. The hub card (the Hue page's bridge card), tabs, scene pictures, speed scale
// and tile text come from plugin.js.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, icon, request, act, readBlock, updateBlock, setKey, poll, renderKeyed } = homeswift;

  let hubs = [];
  let devices = [];
  let scenes = [];
  let found = [];
  let block = {};

  homeswift.tabs("dirigera-tab");

  // MARK: Hubs

  // The card plugin.js draws for both lighting pages: a block per hub (config.json's, paired ones, and the ones found
  // on the network), its pairing, and the address form.
  const card = homeswift.bridgePairing({
    card: $("#hubs"), tone: "blue", button: "bridge",
    texts: {
      name: t("DIRIGERA hub"), pairTitle: t("Pair Homeswift with the hub."), press: t("Press the action button under the hub."),
      pairHelp: t("Pair, then press the action button under the hub within a minute. The token stays in the plugin's folder, not in config.json."),
      summary: t("Add a hub"), placeholder: "192.168.1.30", addressHelp: t("Hubs on the network show up above on their own; type the address of one that does not."), none: t("No hub answered on the network."),
    },
    facts: (hub) => [[t("Address"), hub.host], [t("Devices"), hub.devices ?? 0], [t("Scenes"), hub.scenes ?? 0]],
    menu: (hub) => [hub.inConfig ? { label: t("Remove from config.json"), icon: "trash", danger: true, onSelect: () => removeHub(hub.host) } : null],
    problem: (hub) => ({
      error: `The DIRIGERA hub at ${hub.host} did not answer: ${hub.error}`,
      context: "The Homeswift DIRIGERA plugin reads GET https://<hub>:8443/v1/devices and /v1/scenes with its token, and follows the hub's websocket for changes.",
      device: { host: hub.host },
    }),
    discover: async () => (found = (await request("discover")).hosts),
    use: async (host) => {
      if (!host) return;
      await keep(host);
      if (!found.includes(host)) found = [...found, host];
    },
    pair: async (host) => {
      await request("pair", { method: "POST", body: { host } });
      await keep(host);
    },
    refresh: () => refresh(),
  });

  /// The hubs, then the ones found on the network that are not among them yet; with none, the one being looked for.
  function drawHubs() {
    const known = new Set(hubs.map((hub) => hub.host));
    const list = [...hubs, ...found.filter((host) => !known.has(host)).map((host) => ({ host, paired: false }))];
    card.draw(list.length ? list : [{ host: null }]);
  }

  /// Puts the hub in config.json, as homebridge-dirigera keeps it; its token stays in the plugin's folder.
  async function keep(host) {
    await updateBlock((draft) => {
      const list = draft.hubs || [];
      if (!list.some((hub) => hub.host === host)) list.push({ host });
      draft.hubs = list;
    });
    block = await readBlock();
  }

  async function removeHub(host) {
    if (!confirm(t("Remove the hub at {host} from config.json?", { host }))) return;
    await request("unpair", { method: "POST", body: { host } }).catch(() => {});
    await updateBlock((draft) => {
      const list = (draft.hubs || []).filter((hub) => hub.host !== host);
      if (list.length) draft.hubs = list; else delete draft.hubs;
    }).catch((e) => alert(e.message));
    block = await readBlock();
    found = found.filter((other) => other !== host);
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

  /// The devices left out of the Home app, as buttons that bring one back.
  function drawHidden(names) {
    homeswift.drawHidden($("#hidden-devices"), names, (name) => toggleList("excludeDevices", name));
  }

  let listening = false;
  async function drawDevices() {
    const list = $("#devices");
    if (!hubs.some((hub) => hub.paired)) {
      list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Pair a hub to see its lights and outlets.") })));
      drawHidden([]);
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
    drawHidden(devices.filter((item) => item.hidden).map((item) => item.name));
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
      } catch (e) { alert(e.message); } finally { tileNode.classList.remove("busy"); }
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
    help: t("How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for moods."),
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
    "Pair Homeswift with the hub.": "Jumelez Homeswift avec le hub.",
    "Pair, then press the action button under the hub within a minute. The token stays in the plugin's folder, not in config.json.": "Jumelez, puis appuyez sur le bouton d'action sous le hub dans la minute. Le jeton reste dans le dossier du plugin, pas dans config.json.",
    "Hubs on the network show up above on their own; type the address of one that does not.": "Les hubs du réseau apparaissent ci-dessus d'eux-mêmes ; saisissez l'adresse de celui qui n'y est pas.",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Remove from config.json": "Retirer de config.json",
    "Press the action button under the hub.": "Appuyez sur le bouton d'action sous le hub.",
    "Add a hub": "Ajouter un hub",
    "No hub answered on the network.": "Aucun hub n'a répondu sur le réseau.",
    "Remove the hub at {host} from config.json?": "Retirer le hub à {host} de config.json ?",
    "Pair a hub to see its lights and outlets.": "Jumelez un hub pour voir ses lampes et ses prises.",
    "The hub has no lights or outlets yet: add them in the IKEA Home smart app.": "Le hub n'a pas encore de lampes ni de prises : ajoutez-les dans l'app IKEA Home smart.",
    "Run {name}": "Lancer {name}",
    "Wake-up": "Réveil",
    "Scheduled": "Programmée",
    "Runs on the hub's schedule: it cannot be run from here or from the Home app.": "Suit la programmation du hub : elle ne se lance ni d'ici ni depuis l'app Maison.",
    "No scenes yet: make some in the IKEA Home smart app.": "Pas encore de scènes : créez-en dans l'app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Jumelez un hub pour voir ses scènes.",
    "Unsaved changes.": "Modifications non enregistrées.",
    "Medium": "Moyenne",
    "How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for moods.": "La vitesse à laquelle une lampe atteint une nouvelle intensité ou couleur. Rapide par défaut ; Extrême change aussitôt, le plus vif pour les ambiances.",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Un interrupteur par scène du hub. L'allumer la lance ; l'éteindre dans les 30 secondes l'annule.",
    "Changes are kept once you save.": "Les modifications sont conservées une fois enregistrées.",
    "Saved. The plugin restarted with these settings.": "Enregistré. Le plugin a redémarré avec ces réglages.",
    "{n} device": "{n} appareil",
    "{n} devices": "{n} appareils",
    "{n} scene": "{n} scène",
    "{n} scenes": "{n} scènes",
    "Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.": "Vos hubs DIRIGERA, leurs lampes et prises pièce par pièce, et leurs scènes, directement depuis le hub sur votre réseau.",
    "Devices": "Appareils",
    "Save Configuration": "Enregistrer la configuration",
    "an address is required": "une adresse est requise",
    "The action button was not pressed in time.": "Le bouton d'action n'a pas été pressé à temps.",
    "The DIRIGERA hub refused the token: pair again from the plugin's page.": "Le hub DIRIGERA a refusé le jeton : jumelez à nouveau depuis la page du plugin.",
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
    "Pair Homeswift with the hub.": "Empareja Homeswift con el hub.",
    "Pair, then press the action button under the hub within a minute. The token stays in the plugin's folder, not in config.json.": "Empareja y pulsa el botón de acción de debajo del hub antes de un minuto. El token se queda en la carpeta del plugin, no en config.json.",
    "Hubs on the network show up above on their own; type the address of one that does not.": "Los hubs de la red aparecen arriba por sí solos; escribe la dirección del que no aparezca.",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Remove from config.json": "Quitar de config.json",
    "Press the action button under the hub.": "Pulsa el botón de acción de debajo del hub.",
    "Add a hub": "Añadir un hub",
    "No hub answered on the network.": "Ningún hub ha respondido en la red.",
    "Remove the hub at {host} from config.json?": "¿Quitar el hub de {host} de config.json?",
    "Pair a hub to see its lights and outlets.": "Empareja un hub para ver sus luces y enchufes.",
    "The hub has no lights or outlets yet: add them in the IKEA Home smart app.": "El hub aún no tiene luces ni enchufes: añádelos en la app IKEA Home smart.",
    "Run {name}": "Activar {name}",
    "Wake-up": "Despertar",
    "Scheduled": "Programada",
    "Runs on the hub's schedule: it cannot be run from here or from the Home app.": "Sigue la programación del hub: no se puede activar desde aquí ni desde la app Casa.",
    "No scenes yet: make some in the IKEA Home smart app.": "Aún no hay escenas: créalas en la app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Empareja un hub para ver sus escenas.",
    "Unsaved changes.": "Cambios sin guardar.",
    "Medium": "Media",
    "How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for moods.": "La rapidez con la que una luz llega a un nuevo nivel o color. Rápida es la predeterminada; Extrema cambia al instante, lo más ágil para los ambientes.",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Un interruptor por escena del hub. Encenderlo la activa; apagarlo antes de 30 segundos la deshace.",
    "Changes are kept once you save.": "Los cambios se conservan al guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. El plugin se ha reiniciado con estos ajustes.",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} scene": "{n} escena",
    "{n} scenes": "{n} escenas",
    "Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.": "Tus hubs DIRIGERA, sus luces y enchufes habitación por habitación y sus escenas, directamente desde el hub en tu red.",
    "Devices": "Dispositivos",
    "Save Configuration": "Guardar configuración",
    "an address is required": "se necesita una dirección",
    "The action button was not pressed in time.": "No se ha pulsado el botón de acción a tiempo.",
    "The DIRIGERA hub refused the token: pair again from the plugin's page.": "El hub DIRIGERA ha rechazado el token: vuelve a emparejar desde la página del plugin.",
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
    "Pair Homeswift with the hub.": "Emparelhe o Homeswift com o hub.",
    "Pair, then press the action button under the hub within a minute. The token stays in the plugin's folder, not in config.json.": "Emparelhe e prima o botão de ação por baixo do hub no espaço de um minuto. O token fica na pasta do plugin, não em config.json.",
    "Hubs on the network show up above on their own; type the address of one that does not.": "Os hubs da rede aparecem acima por si próprios; escreva o endereço de um que não apareça.",
    "DIRIGERA hub": "Hub DIRIGERA",
    "Remove from config.json": "Remover de config.json",
    "Press the action button under the hub.": "Prima o botão de ação por baixo do hub.",
    "Add a hub": "Adicionar um hub",
    "No hub answered on the network.": "Nenhum hub respondeu na rede.",
    "Remove the hub at {host} from config.json?": "Remover o hub em {host} de config.json?",
    "Pair a hub to see its lights and outlets.": "Emparelhe um hub para ver as luzes e tomadas.",
    "The hub has no lights or outlets yet: add them in the IKEA Home smart app.": "O hub ainda não tem luzes nem tomadas: adicione-as na app IKEA Home smart.",
    "Run {name}": "Ativar {name}",
    "Wake-up": "Despertar",
    "Scheduled": "Programada",
    "Runs on the hub's schedule: it cannot be run from here or from the Home app.": "Segue o horário do hub: não pode ser ativada daqui nem a partir da app Casa.",
    "No scenes yet: make some in the IKEA Home smart app.": "Ainda não há cenas: crie-as na app IKEA Home smart.",
    "Pair a hub to see its scenes.": "Emparelhe um hub para ver as cenas.",
    "Unsaved changes.": "Alterações por guardar.",
    "Medium": "Média",
    "How fast a light reaches a new level or colour. Fast is the default; Extreme changes at once, snappiest for moods.": "A rapidez com que uma luz chega a um novo nível ou cor. Rápida é a predefinida; Extrema muda de imediato, o mais vivo para os ambientes.",
    "A switch for each scene of the hub. On runs it; off within 30 seconds undoes it.": "Um interruptor por cena do hub. Ligá-lo ativa-a; desligá-lo nos 30 segundos seguintes anula-a.",
    "Changes are kept once you save.": "As alterações ficam guardadas quando guardar.",
    "Saved. The plugin restarted with these settings.": "Guardado. O plugin reiniciou com estas definições.",
    "{n} device": "{n} dispositivo",
    "{n} devices": "{n} dispositivos",
    "{n} scene": "{n} cena",
    "{n} scenes": "{n} cenas",
    "Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.": "Os hubs DIRIGERA, as luzes e tomadas divisão a divisão e as cenas, diretamente do hub na sua rede.",
    "Devices": "Dispositivos",
    "Save Configuration": "Guardar configuração",
    "an address is required": "é necessário um endereço",
    "The action button was not pressed in time.": "O botão de ação não foi premido a tempo.",
    "The DIRIGERA hub refused the token: pair again from the plugin's page.": "O hub DIRIGERA recusou o token: emparelhe novamente a partir da página do plugin.",
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
      <p class="muted" data-i18n>Your DIRIGERA hubs, their lights and outlets room by room, and their scenes, straight from the hub on your network.</p>
    </div>
  </div>

  <div id="hubs" class="card bridge-card"></div>

  <div class="group tabs main-tabs" role="tablist">
    <button role="tab" data-tab="devices" class="on" aria-selected="true" aria-controls="tab-devices" data-i18n data-action-icon="accessory">Devices</button>
    <button role="tab" data-tab="scenes" aria-selected="false" aria-controls="tab-scenes" data-i18n data-action-icon="star">Scenes</button>
    <button role="tab" data-tab="settings" aria-selected="false" aria-controls="tab-settings" data-i18n data-action-icon="sliders">Settings</button>
  </div>

  <section id="tab-devices" class="tab-pane" role="tabpanel">
    <div class="accessory-walls"><div class="wall" id="devices"></div></div>
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
