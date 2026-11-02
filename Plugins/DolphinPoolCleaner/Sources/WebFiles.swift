// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DolphinPoolCleanerPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Dolphin Pool Cleaner page, after the Homebridge plugin's setup wizard without its sign-in: Setup signs in (a
// card leads to it while the account is not signed in), then the account's robots with their live state, each with
// its settings. Saving writes the robot's entry in this instance's block; the plugin reloads.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, explain, breadcrumb, act, poll, fact, readBlock, updateBlock, setupCard, setupAddress } = homeswift;
  // The pool robot's icon, the one its widget and its Matter row show.
  $(".tile.pool")?.replaceChildren(HomeswiftCommon.icon("poolRobot"));

  const DEVICE_TYPE_LABELS = { 62: t("IoT Connected (M400/M600)"), 60: t("IoT Connected"), 50: t("BLE Connected") };
  const CLEANING_MODES = {
    all: { name: t("All Surfaces"), description: t("Full pool cleaning covering floor, walls, and waterline. Most thorough cleaning option."), duration: 150 },
    floor: { name: t("Floor Only"), description: t("Cleans just the pool bottom. Good for quick maintenance when walls are still clean."), duration: 150 },
    wall: { name: t("Walls Only"), description: t("Cleans vertical surfaces of the pool. Useful after storms or algae treatment."), duration: 120 },
    water: { name: t("Waterline"), description: t("Focuses on the water surface line where debris and oils accumulate."), duration: 150 },
    short: { name: t("Short/Fast"), description: t("Quick cleaning cycle for light maintenance between full cleans."), duration: 150 },
    ultra: { name: t("Ultra Clean"), description: t("Intensive deep cleaning mode for heavily soiled pools. Most thorough option."), duration: 150 },
    cove: { name: t("Cove"), description: t("Focuses on corners and coves where floor meets walls. Catches hard-to-reach debris."), duration: 120 },
    spot: { name: t("Spot"), description: t("Concentrated cleaning in a localized area. Drop robot where needed."), duration: 120 },
    tictac: { name: t("Tic Tac"), description: t("Extended systematic coverage pattern for very large or complex pools."), duration: 600 },
    pickup: { name: t("Pickup"), description: t("Quick retrieval mode - robot moves to edge for easy removal from pool."), duration: 5 },
    custom: { name: t("Custom"), description: t("User-defined cleaning cycle with custom duration."), duration: 120 },
  };
  // The modes the Homebridge wizard offers, in its order.
  const MODE_CHOICES = ["all", "floor", "wall", "water", "short", "ultra", "cove", "spot"];
  const POLLING_CHOICES = [[30, t("30 seconds")], [60, t("60 seconds (Recommended)")], [120, t("2 minutes")], [300, t("5 minutes")]];

  // Older versions saved "regular", which the plugin treats as "all".
  const normalizeMode = (mode) => (mode === "regular" ? "all" : mode);
  const deviceTypeLabel = (type) => DEVICE_TYPE_LABELS[type] || (type ? t("Type {type}", { type: String(type) }) : "—");
  function formatDuration(minutes) {
    if (minutes < 60) return `${minutes} min`;
    if (minutes % 60 === 0) return tn("{n} hour", "{n} hours", minutes / 60);
    return t("{h}h {m}m", { h: Math.floor(minutes / 60), m: minutes % 60 });
  }
  function modeText(mode) {
    const info = CLEANING_MODES[normalizeMode(mode)];
    return info ? `${info.name} (${formatDuration(info.duration)})` : mode || t("All Surfaces");
  }
  /// The pool robot drawing of the Homebridge wizard; each copy has its own gradient ids.
  let drawings = 0;
  function robotDrawing() {
    const n = ++drawings;
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 200 160");
    svg.setAttribute("aria-hidden", "true");
    const track = (x) => [108, 116, 124, 132].map((y) => `<line x1="${x}" y1="${y}" x2="${x + 20}" y2="${y}" stroke="#444" stroke-width="2"/>`).join("");
    svg.innerHTML = `<defs>
      <linearGradient id="body-${n}" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#4A90D9"/><stop offset="100%" stop-color="#2E5A8B"/></linearGradient>
      <linearGradient id="top-${n}" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#5BA0E9"/><stop offset="100%" stop-color="#4A90D9"/></linearGradient>
      <linearGradient id="wheel-${n}" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0%" stop-color="#333"/><stop offset="100%" stop-color="#111"/></linearGradient></defs>
      <ellipse cx="100" cy="145" rx="70" ry="8" fill="rgba(0,0,0,0.15)"/>
      <rect x="25" y="100" width="30" height="40" rx="8" fill="url(#wheel-${n})"/><rect x="145" y="100" width="30" height="40" rx="8" fill="url(#wheel-${n})"/>
      ${track(30)}${track(150)}
      <path d="M40 120 Q40 70 100 60 Q160 70 160 120 L160 130 Q160 140 150 140 L50 140 Q40 140 40 130 Z" fill="url(#body-${n})"/>
      <ellipse cx="100" cy="75" rx="55" ry="25" fill="url(#top-${n})"/>
      <path d="M70 55 Q100 35 130 55" stroke="#3A80C9" stroke-width="6" fill="none" stroke-linecap="round"/>
      <path d="M55 90 Q100 100 145 90" stroke="#3A80C9" stroke-width="2" fill="none"/>
      <circle cx="100" cy="75" r="6" fill="#4ADE80"/>
      <path d="M60 100 L60 125 M140 100 L140 125" stroke="#5BA0E9" stroke-width="3"/><path d="M75 95 L75 130 M125 95 L125 130" stroke="#5BA0E9" stroke-width="3"/>
      <rect x="45" y="135" width="110" height="6" rx="3" fill="#2E5A8B"/>`;
    return svg;
  }

  /// The robot's picture (the plugin keeps the one MyDolphin has; pages load images from their own origin
  /// only), else the drawing.
  const pictures = new Map();
  function picture(serial, badge) {
    const box = el("div", { class: "picture" }, robotDrawing(), badge);
    if (serial) {
      if (!pictures.has(serial)) pictures.set(serial, request(`image?serial=${encodeURIComponent(serial)}`).then((answer) => answer.dataURL).catch(() => null));
      pictures.get(serial).then((url) => {
        if (!url) return;
        const image = el("img", { src: url, alt: "" });
        image.addEventListener("error", () => image.replaceWith(robotDrawing()));
        box.firstChild.replaceWith(image);
      });
    }
    return box;
  }

  // MARK: The steps

  const wizard = $("#wizard");
  const state = {
    robotData: null,      // the robot being edited
    saved: null,          // the block as last read
    live: [],             // what the plugin reports about its robots
    status: null,
    error: null,
  };
  let current = null;

  function show(step, ...children) {
    // The same step drawn again (the robots' state changed) stays still: only a new step arrives animated.
    const again = step === current;
    current = step;
    wizard.replaceChildren(el("div", { class: `step step-${step}${again ? " again" : ""}` }, ...children));
    const focus = wizard.querySelector("[autofocus]");
    if (focus) focus.focus();
    breadcrumb(step === "robot" ? t("Edit robot") : null, () => showConfigured());
  }

  const head = (title, text) => [el("div", { class: "step-head" }, el("h2", { text: title })), text ? el("p", { class: "muted", text }) : null];
  const statusLine = () => el("p", { class: "status-line", role: "status" });
  function fail(line, message, context) {
    line.className = "status-line error";
    line.replaceChildren(message, explain({ error: message, context, device: { model: "Maytronics Dolphin pool robot (MyDolphin Plus)" } }));
  }

  // The account's robots.

  async function showConfigured() {
    try {
      state.saved = await readBlock();
    } catch (e) {
      show("configured", el("p", { class: "error", text: e.message }));
      return;
    }
    drawConfigured();
  }

  /// The account's robots (what the plugin reports, and the block's entries it has not found yet) with their
  /// settings from the block as last read; the card that had the keyboard keeps it. No account: the card to Setup.
  function drawConfigured() {
    if (state.status === "notConfigured") {
      show("setup", setupCard({
        title: t("Sign in to your MyDolphin Plus account"),
        text: t("Add accessories signs in with your MyDolphin Plus email and the code Maytronics sends; the account's robots come with it."),
        glyph: "key",
        tone: "blue",
      }));
      return;
    }
    const block = state.saved;
    const entries = block.devices || [];
    const serials = [...new Set([...state.live.map((robot) => robot.serialNumber), ...entries.map((device) => device.serialNumber).filter(Boolean)])];
    const devices = serials.map((serial) => {
      const live = state.live.find((robot) => robot.serialNumber === serial);
      return entries.find((device) => device.serialNumber === serial) || { serialNumber: serial, name: live?.name, deviceType: live?.deviceType };
    });
    const focused = [...wizard.querySelectorAll(".robot")].indexOf(document.activeElement);
    const list = devices.length ? el("div", { class: "robots" }, devices.map((device) => robotCard(device, block.email)))
      : el("p", { class: "muted", text: state.status === "ready" ? t("No robot on this account yet.") : "" });
    const account = el("p", { class: "status-line" });
    describeAccount(account);
    show("configured",
      ...head(t("Your Dolphin Robots"), t("Manage your configured pool robots. A robot's card opens its settings.")),
      el("div", { class: "account-line" }, account,
        el("a", { class: "button", href: setupAddress({ start: true }), actionIcon: "key", text: t("Sign in again") })),
      list);
    if (focused >= 0) wizard.querySelectorAll(".robot")[focused]?.focus({ preventScroll: true });
  }

  function describeAccount(line) {
    const { status, error } = state;
    if (status === "failed" || status === "retrying") {
      fail(line, HomeswiftI18n.message(error) || t("The plugin cannot reach MyDolphin Plus."),
        `The Homeswift Dolphin plugin signs in with Cognito (refresh token or email and password), then MyDolphin authenticate-user and getToken, then AWS IoT MQTT (eu-west-1). Plugin status: ${status}.`);
      if (status === "retrying") line.prepend(t("Retrying: "));
    } else if (status === "signingIn") {
      line.className = "status-line muted";
      line.textContent = t("Signing in to MyDolphin Plus…");
    } else {
      line.className = "status-line muted";
      line.textContent = "";
    }
  }

  function liveState(serial) {
    const robot = state.live.find((r) => r.serialNumber === serial);
    if (!robot) return { text: t("Configured"), kind: "standby" };
    if (!robot.connected) return { text: t("Not connected"), kind: "away", robot };
    if (robot.fault) return { text: robot.fault, kind: "away", robot };
    return robot.isCleaning ? { text: t("Cleaning"), kind: "on", robot } : { text: t("Idle"), kind: "standby", robot };
  }

  function robotCard(device, email) {
    const live = liveState(device.serialNumber);
    const facts = [
      fact(t("Serial Number"), device.serialNumber || "—"),
      fact(t("Device Type"), deviceTypeLabel(device.deviceType)),
      fact(t("Account"), email || "—"),
      fact(t("Cleaning Mode"), modeText(device.cleaningMode)),
    ];
    if (live.robot) {
      facts.push(fact(t("Filter"), live.robot.filterStatus === "needs_cleaning" ? t("Needs cleaning") : t("OK")));
      if (live.robot.isCleaning && live.robot.cycleTimeRemaining > 0) facts.push(fact(t("Time left"), formatDuration(live.robot.cycleTimeRemaining)));
      if (typeof live.robot.temperature === "number") facts.push(fact(t("Water"), homeswift.formatTemperature(live.robot.temperature)));
    }
    const card = el("div", { class: "card robot", role: "button", tabIndex: 0, "aria-label": t("Edit {name}", { name: device.name || t("Dolphin Robot") }) },
      picture(device.serialNumber, el("span", { class: `pill status ${live.kind}`, text: live.text })),
      el("div", { class: "body" },
        el("div", { class: "head" }, el("strong", { text: device.name || t("Dolphin Robot") })),
        el("div", { class: "facts" }, facts),
        el("span", { class: "edit", "aria-hidden": "true", text: t("Edit settings ›") })));
    card.addEventListener("click", () => editDevice(device));
    card.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); editDevice(device); }
    });
    return card;
  }

  // A robot's settings.

  function editDevice(device) {
    const live = state.live.find((robot) => robot.serialNumber === device.serialNumber);
    state.robotData = {
      serialNumber: device.serialNumber, robotName: device.name, deviceType: device.deviceType ?? live?.deviceType,
      model: live?.modelName || live?.model, robotImageUrl: device.robotImageUrl,
    };
    showRobot(device);
  }

  function showRobot(device) {
    const data = state.robotData;
    const displayName = el("input", { type: "text", value: data.robotName || "", placeholder: t("My Pool Robot"), maxLength: 64 });
    const mode = el("select", {}, MODE_CHOICES.map((key) => el("option", { value: key, text: CLEANING_MODES[key].name })));
    mode.value = normalizeMode(device?.cleaningMode) || "all";
    if (!mode.value) mode.value = "all";
    const description = el("p", {});
    const duration = el("div", { class: "muted" });
    const updateMode = () => {
      const info = CLEANING_MODES[mode.value] || CLEANING_MODES.all;
      description.textContent = info.description;
      duration.textContent = tn("Duration: ~{n} minute", "Duration: ~{n} minutes", info.duration);
    };
    mode.addEventListener("change", updateMode);
    updateMode();
    const polling = el("select", {}, POLLING_CHOICES.map(([value, text]) => el("option", { value, text })));
    polling.value = String(state.saved?.pollingInterval || 60);
    if (!polling.value) polling.append(el("option", { value: state.saved.pollingInterval, text: tn("{n} second", "{n} seconds", Number(state.saved.pollingInterval)), selected: true }));
    const temperature = el("input", { type: "checkbox", checked: device?.enableTemperature !== false });
    const filter = el("input", { type: "checkbox", checked: device?.enableFilterStatus !== false });
    const toggle = (input, title) => el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")), el("span", {}, el("span", { class: "field-title", text: title })));
    const detail = (label, value) => el("div", {}, el("span", { text: label }), el("b", { text: value }));
    const line = statusLine();
    const save = el("button", { actionIcon: "check", class: "primary", text: t("Save Configuration") });
    save.addEventListener("click", () => act(save, () => saveRobot({
      name: displayName.value.trim() || data.robotName, cleaningMode: mode.value, pollingInterval: Number(polling.value),
      enableTemperature: temperature.checked, enableFilterStatus: filter.checked,
    }), (message) => fail(line, message, "Saving the Dolphin plugin's block of config.json from its Homeswift page.")));

    show("robot",
      ...head(t("Edit Robot Settings"), t("Update the settings for your Dolphin pool robot.")),
      el("div", { class: "found" },
        el("div", { class: "card robot-panel" },
          picture(data.serialNumber, el("span", { class: "pill status on", text: t("Configured") })),
          el("div", { class: "body" },
            el("label", { class: "field" }, el("span", { class: "field-title", text: t("Display Name") }), displayName, el("span", { class: "help", text: t("Name shown in HomeKit") })),
            el("div", { class: "details" },
              detail(t("Serial Number"), data.serialNumber || "-"),
              detail(t("Model"), data.model || data.robotName || t("Dolphin Robot")),
              detail(t("Device Type"), deviceTypeLabel(data.deviceType))))),
        el("div", { class: "card settings" },
          el("h3", { text: t("Settings") }),
          el("label", { class: "field" }, el("span", { class: "field-title", text: t("Default Cleaning Mode") }), mode, el("span", { class: "help", text: t("Mode used when starting from HomeKit") })),
          el("div", { class: "mode-info" }, el("strong", { text: t("Mode Details") }), description, duration),
          el("label", { class: "field" }, el("span", { class: "field-title", text: t("Polling Interval") }), polling, el("span", { class: "help", text: t("How often to check robot status") })),
          toggle(temperature, t("Enable Water Temperature Sensor")),
          toggle(filter, t("Enable Filter Status")))),
      line,
      el("div", { class: "actions" }, el("button", { actionIcon: "restore", text: t("Back"), onclick: showConfigured }), save));
  }

  /// Writes the robot's entry into the block as the Homebridge wizard does, with the polling interval; the account
  /// is Setup's. The plugin reloads with it.
  async function saveRobot(settings) {
    const data = state.robotData;
    const entry = {
      serialNumber: data.serialNumber, name: settings.name, deviceType: data.deviceType, robotImageUrl: data.robotImageUrl,
      cleaningMode: settings.cleaningMode, enableTemperature: settings.enableTemperature, enableFilterStatus: settings.enableFilterStatus,
    };
    if (!entry.robotImageUrl) delete entry.robotImageUrl;
    if (entry.deviceType === undefined) delete entry.deviceType;
    if (!entry.name) delete entry.name;
    let saved;
    await updateBlock((block) => {
      block.pollingInterval = settings.pollingInterval;
      block.devices = [...(block.devices || [])];
      const existing = block.devices.findIndex((d) => d.serialNumber === data.serialNumber);
      if (existing >= 0) block.devices[existing] = entry; else block.devices.push(entry);
      saved = block;
    });
    state.saved = saved;
    setTimeout(refreshLive, 1500);
    showConfigured();
  }

  // MARK: The plugin's view of its robots, refreshed while the list shows.

  /// The first answer (or failure) draws the page.
  async function refreshLive() {
    let changed = false;
    try {
      const answer = await request("robots");
      changed = JSON.stringify([answer.robots, answer.status, answer.error]) !== JSON.stringify([state.live, state.status, state.error]);
      state.live = answer.robots || [];
      state.status = answer.status;
      state.error = answer.error || null;
    } catch {
      // The plugin is restarting with a new block; the next refresh catches up.
    }
    // A change while the list (or the card to Setup) shows redraws it from the block already read: no request, no animation.
    if (current === null || (current === "configured" && !state.saved)) showConfigured();
    else if (changed && (current === "configured" || current === "setup")) drawConfigured();
  }

  poll(refreshLive, 5000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Dolphin Pool Cleaner page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Connect your MyDolphin Plus account, then choose how your robot appears in the Home app.": "Connectez votre compte MyDolphin Plus, puis choisissez comment votre robot apparaît dans l'app Maison.",
    "IoT Connected (M400/M600)": "Connecté IoT (M400/M600)",
    "IoT Connected": "Connecté IoT",
    "BLE Connected": "Connecté en BLE",
    "All Surfaces": "Toutes les surfaces",
    "Full pool cleaning covering floor, walls, and waterline. Most thorough cleaning option.": "Nettoyage complet de la piscine : fond, parois et ligne d'eau. L'option la plus minutieuse.",
    "Floor Only": "Fond uniquement",
    "Cleans just the pool bottom. Good for quick maintenance when walls are still clean.": "Nettoie seulement le fond de la piscine. Idéal pour un entretien rapide quand les parois sont encore propres.",
    "Walls Only": "Parois uniquement",
    "Cleans vertical surfaces of the pool. Useful after storms or algae treatment.": "Nettoie les surfaces verticales de la piscine. Utile après un orage ou un traitement anti-algues.",
    "Waterline": "Ligne d'eau",
    "Focuses on the water surface line where debris and oils accumulate.": "Se concentre sur la ligne d'eau, où s'accumulent débris et dépôts gras.",
    "Short/Fast": "Court/rapide",
    "Quick cleaning cycle for light maintenance between full cleans.": "Cycle de nettoyage rapide pour un entretien léger entre deux nettoyages complets.",
    "Ultra Clean": "Ultra propre",
    "Intensive deep cleaning mode for heavily soiled pools. Most thorough option.": "Mode de nettoyage intensif en profondeur pour les piscines très sales. L'option la plus minutieuse.",
    "Cove": "Angles",
    "Focuses on corners and coves where floor meets walls. Catches hard-to-reach debris.": "Se concentre sur les angles où le fond rejoint les parois. Récupère les débris difficiles d'accès.",
    "Spot": "Zone ciblée",
    "Concentrated cleaning in a localized area. Drop robot where needed.": "Nettoyage concentré sur une zone précise. Déposez le robot là où il faut.",
    "Tic Tac": "Tic Tac",
    "Extended systematic coverage pattern for very large or complex pools.": "Parcours systématique étendu pour les piscines très grandes ou complexes.",
    "Pickup": "Récupération",
    "Quick retrieval mode - robot moves to edge for easy removal from pool.": "Mode de récupération rapide : le robot va au bord pour être sorti facilement de la piscine.",
    "Custom": "Personnalisé",
    "User-defined cleaning cycle with custom duration.": "Cycle de nettoyage défini par l'utilisateur, avec une durée personnalisée.",
    "30 seconds": "30 secondes",
    "60 seconds (Recommended)": "60 secondes (recommandé)",
    "2 minutes": "2 minutes",
    "5 minutes": "5 minutes",
    "Type {type}": "Type {type}",
    "{n} hour": "{n} heure",
    "{n} hours": "{n} heures",
    "{h}h {m}m": "{h} h {m} min",
    "Edit robot": "Modifier le robot",
    "Your Dolphin Robots": "Vos robots Dolphin",
    "Sign in to your MyDolphin Plus account": "Connectez-vous à votre compte MyDolphin Plus",
    "Add accessories signs in with your MyDolphin Plus email and the code Maytronics sends; the account's robots come with it.": "Ajouter des accessoires vous connecte avec l'e-mail de votre compte MyDolphin Plus et le code que Maytronics envoie ; les robots du compte suivent.",
    "No robot on this account yet.": "Aucun robot sur ce compte pour l'instant.",
    "Manage your configured pool robots. A robot's card opens its settings.": "Gérez vos robots de piscine configurés. La carte d'un robot ouvre ses réglages.",
    "The plugin cannot reach MyDolphin Plus.": "Le plugin ne parvient pas à joindre MyDolphin Plus.",
    "Retrying: ": "Nouvelle tentative : ",
    "Signing in to MyDolphin Plus…": "Connexion à MyDolphin Plus…",
    "Configured": "Configuré",
    "Not connected": "Non connecté",
    "Cleaning": "Nettoyage",
    "Idle": "Inactif",
    "Serial Number": "Numéro de série",
    "Device Type": "Type d'appareil",
    "Account": "Compte",
    "Cleaning Mode": "Mode de nettoyage",
    "Filter": "Filtre",
    "Needs cleaning": "À nettoyer",
    "OK": "OK",
    "Time left": "Temps restant",
    "Water": "Eau",
    "Edit {name}": "Modifier {name}",
    "Dolphin Robot": "Robot Dolphin",
    "Edit settings ›": "Modifier les réglages ›",
    "Back": "Retour",
    "My Pool Robot": "Mon robot de piscine",
    "Duration: ~{n} minute": "Durée : environ {n} minute",
    "Duration: ~{n} minutes": "Durée : environ {n} minutes",
    "{n} second": "{n} seconde",
    "{n} seconds": "{n} secondes",
    "Save Configuration": "Enregistrer la configuration",
    "Edit Robot Settings": "Modifier les réglages du robot",
    "Update the settings for your Dolphin pool robot.": "Modifiez les réglages de votre robot de piscine Dolphin.",
    "Display Name": "Nom affiché",
    "Name shown in HomeKit": "Nom affiché dans HomeKit",
    "Model": "Modèle",
    "Settings": "Réglages",
    "Default Cleaning Mode": "Mode de nettoyage par défaut",
    "Mode used when starting from HomeKit": "Mode utilisé au lancement depuis HomeKit",
    "Mode Details": "Détails du mode",
    "Polling Interval": "Intervalle d'interrogation",
    "How often to check robot status": "La fréquence à laquelle l'état du robot est vérifié",
    "Enable Water Temperature Sensor": "Activer le capteur de température de l'eau",
    "Enable Filter Status": "Activer l'état du filtre",
    "Maytronics API error: HTTP {0}": "Erreur de l'API Maytronics : HTTP {0}",
    "a serial number is required": "un numéro de série est requis",
    "nothing at {0} {1}": "rien à {0} {1}"
  },
  "es": {
    "Connect your MyDolphin Plus account, then choose how your robot appears in the Home app.": "Conecta tu cuenta de MyDolphin Plus y elige cómo aparece tu robot en la app Casa.",
    "IoT Connected (M400/M600)": "Conectado por IoT (M400/M600)",
    "IoT Connected": "Conectado por IoT",
    "BLE Connected": "Conectado por BLE",
    "All Surfaces": "Todas las superficies",
    "Full pool cleaning covering floor, walls, and waterline. Most thorough cleaning option.": "Limpieza completa de la piscina: fondo, paredes y línea de flotación. La opción más minuciosa.",
    "Floor Only": "Solo el fondo",
    "Cleans just the pool bottom. Good for quick maintenance when walls are still clean.": "Limpia solo el fondo de la piscina. Útil para un mantenimiento rápido cuando las paredes aún están limpias.",
    "Walls Only": "Solo las paredes",
    "Cleans vertical surfaces of the pool. Useful after storms or algae treatment.": "Limpia las superficies verticales de la piscina. Útil tras tormentas o un tratamiento antialgas.",
    "Waterline": "Línea de flotación",
    "Focuses on the water surface line where debris and oils accumulate.": "Se centra en la línea de flotación, donde se acumulan residuos y grasa.",
    "Short/Fast": "Corto/rápido",
    "Quick cleaning cycle for light maintenance between full cleans.": "Ciclo de limpieza rápido para un mantenimiento ligero entre limpiezas completas.",
    "Ultra Clean": "Ultralimpieza",
    "Intensive deep cleaning mode for heavily soiled pools. Most thorough option.": "Modo de limpieza profunda e intensiva para piscinas muy sucias. La opción más minuciosa.",
    "Cove": "Esquinas",
    "Focuses on corners and coves where floor meets walls. Catches hard-to-reach debris.": "Se centra en las esquinas donde el fondo se une a las paredes. Recoge los residuos de difícil acceso.",
    "Spot": "Zona concreta",
    "Concentrated cleaning in a localized area. Drop robot where needed.": "Limpieza concentrada en una zona concreta. Deja el robot donde haga falta.",
    "Tic Tac": "Tic Tac",
    "Extended systematic coverage pattern for very large or complex pools.": "Patrón de cobertura sistemático y extendido para piscinas muy grandes o complejas.",
    "Pickup": "Recogida",
    "Quick retrieval mode - robot moves to edge for easy removal from pool.": "Modo de recogida rápida: el robot va al borde para sacarlo fácilmente de la piscina.",
    "Custom": "Personalizado",
    "User-defined cleaning cycle with custom duration.": "Ciclo de limpieza definido por el usuario, con duración personalizada.",
    "30 seconds": "30 segundos",
    "60 seconds (Recommended)": "60 segundos (recomendado)",
    "2 minutes": "2 minutos",
    "5 minutes": "5 minutos",
    "Type {type}": "Tipo {type}",
    "{n} hour": "{n} hora",
    "{n} hours": "{n} horas",
    "{h}h {m}m": "{h} h {m} min",
    "Edit robot": "Editar robot",
    "Your Dolphin Robots": "Tus robots Dolphin",
    "Sign in to your MyDolphin Plus account": "Inicia sesión en tu cuenta MyDolphin Plus",
    "Add accessories signs in with your MyDolphin Plus email and the code Maytronics sends; the account's robots come with it.": "Añadir accesorios inicia sesión con el correo de tu cuenta MyDolphin Plus y el código que envía Maytronics; los robots de la cuenta vienen con ella.",
    "No robot on this account yet.": "Todavía no hay ningún robot en esta cuenta.",
    "Manage your configured pool robots. A robot's card opens its settings.": "Gestiona tus robots de piscina configurados. La tarjeta de un robot abre sus ajustes.",
    "The plugin cannot reach MyDolphin Plus.": "El plugin no puede conectar con MyDolphin Plus.",
    "Retrying: ": "Reintentando: ",
    "Signing in to MyDolphin Plus…": "Iniciando sesión en MyDolphin Plus…",
    "Configured": "Configurado",
    "Not connected": "No conectado",
    "Cleaning": "Limpiando",
    "Idle": "Inactivo",
    "Serial Number": "Número de serie",
    "Device Type": "Tipo de dispositivo",
    "Account": "Cuenta",
    "Cleaning Mode": "Modo de limpieza",
    "Filter": "Filtro",
    "Needs cleaning": "Necesita limpieza",
    "OK": "OK",
    "Time left": "Tiempo restante",
    "Water": "Agua",
    "Edit {name}": "Editar {name}",
    "Dolphin Robot": "Robot Dolphin",
    "Edit settings ›": "Editar ajustes ›",
    "Back": "Atrás",
    "My Pool Robot": "Mi robot de piscina",
    "Duration: ~{n} minute": "Duración: ~{n} minuto",
    "Duration: ~{n} minutes": "Duración: ~{n} minutos",
    "{n} second": "{n} segundo",
    "{n} seconds": "{n} segundos",
    "Save Configuration": "Guardar la configuración",
    "Edit Robot Settings": "Editar los ajustes del robot",
    "Update the settings for your Dolphin pool robot.": "Cambia los ajustes de tu robot de piscina Dolphin.",
    "Display Name": "Nombre visible",
    "Name shown in HomeKit": "Nombre que se muestra en HomeKit",
    "Model": "Modelo",
    "Settings": "Ajustes",
    "Default Cleaning Mode": "Modo de limpieza predeterminado",
    "Mode used when starting from HomeKit": "Modo que se usa al iniciar desde HomeKit",
    "Mode Details": "Detalles del modo",
    "Polling Interval": "Intervalo de consulta",
    "How often to check robot status": "Cada cuánto se comprueba el estado del robot",
    "Enable Water Temperature Sensor": "Activar el sensor de temperatura del agua",
    "Enable Filter Status": "Activar el estado del filtro",
    "Maytronics API error: HTTP {0}": "Error de la API de Maytronics: HTTP {0}",
    "a serial number is required": "se necesita un número de serie",
    "nothing at {0} {1}": "no hay nada en {0} {1}"
  },
  "pt": {
    "Connect your MyDolphin Plus account, then choose how your robot appears in the Home app.": "Ligue a sua conta MyDolphin Plus e escolha como o robô aparece na app Casa.",
    "IoT Connected (M400/M600)": "Ligado por IoT (M400/M600)",
    "IoT Connected": "Ligado por IoT",
    "BLE Connected": "Ligado por BLE",
    "All Surfaces": "Todas as superfícies",
    "Full pool cleaning covering floor, walls, and waterline. Most thorough cleaning option.": "Limpeza completa da piscina: fundo, paredes e linha de água. A opção mais minuciosa.",
    "Floor Only": "Só o fundo",
    "Cleans just the pool bottom. Good for quick maintenance when walls are still clean.": "Limpa só o fundo da piscina. Útil para uma manutenção rápida quando as paredes ainda estão limpas.",
    "Walls Only": "Só as paredes",
    "Cleans vertical surfaces of the pool. Useful after storms or algae treatment.": "Limpa as superfícies verticais da piscina. Útil depois de tempestades ou de um tratamento antialgas.",
    "Waterline": "Linha de água",
    "Focuses on the water surface line where debris and oils accumulate.": "Concentra-se na linha de água, onde se acumulam detritos e gordura.",
    "Short/Fast": "Curto/rápido",
    "Quick cleaning cycle for light maintenance between full cleans.": "Ciclo de limpeza rápido para uma manutenção ligeira entre limpezas completas.",
    "Ultra Clean": "Ultralimpeza",
    "Intensive deep cleaning mode for heavily soiled pools. Most thorough option.": "Modo de limpeza profunda e intensiva para piscinas muito sujas. A opção mais minuciosa.",
    "Cove": "Cantos",
    "Focuses on corners and coves where floor meets walls. Catches hard-to-reach debris.": "Concentra-se nos cantos onde o fundo encontra as paredes. Apanha os detritos de difícil acesso.",
    "Spot": "Zona específica",
    "Concentrated cleaning in a localized area. Drop robot where needed.": "Limpeza concentrada numa zona específica. Coloque o robô onde for preciso.",
    "Tic Tac": "Tic Tac",
    "Extended systematic coverage pattern for very large or complex pools.": "Padrão de cobertura sistemático e alargado para piscinas muito grandes ou complexas.",
    "Pickup": "Recolha",
    "Quick retrieval mode - robot moves to edge for easy removal from pool.": "Modo de recolha rápida: o robô desloca-se até à borda para ser retirado facilmente da piscina.",
    "Custom": "Personalizado",
    "User-defined cleaning cycle with custom duration.": "Ciclo de limpeza definido pelo utilizador, com duração personalizada.",
    "30 seconds": "30 segundos",
    "60 seconds (Recommended)": "60 segundos (recomendado)",
    "2 minutes": "2 minutos",
    "5 minutes": "5 minutos",
    "Type {type}": "Tipo {type}",
    "{n} hour": "{n} hora",
    "{n} hours": "{n} horas",
    "{h}h {m}m": "{h} h {m} min",
    "Edit robot": "Editar robô",
    "Your Dolphin Robots": "Os seus robôs Dolphin",
    "Sign in to your MyDolphin Plus account": "Inicie sessão na sua conta MyDolphin Plus",
    "Add accessories signs in with your MyDolphin Plus email and the code Maytronics sends; the account's robots come with it.": "Adicionar acessórios inicia sessão com o e-mail da sua conta MyDolphin Plus e o código que a Maytronics envia; os robôs da conta vêm com ela.",
    "No robot on this account yet.": "Ainda não há nenhum robô nesta conta.",
    "Manage your configured pool robots. A robot's card opens its settings.": "Gira os robôs de piscina configurados. O cartão de um robô abre as suas definições.",
    "The plugin cannot reach MyDolphin Plus.": "O plugin não consegue chegar ao MyDolphin Plus.",
    "Retrying: ": "A tentar novamente: ",
    "Signing in to MyDolphin Plus…": "A iniciar sessão no MyDolphin Plus…",
    "Configured": "Configurado",
    "Not connected": "Não ligado",
    "Cleaning": "A limpar",
    "Idle": "Em repouso",
    "Serial Number": "Número de série",
    "Device Type": "Tipo de dispositivo",
    "Account": "Conta",
    "Cleaning Mode": "Modo de limpeza",
    "Filter": "Filtro",
    "Needs cleaning": "Precisa de limpeza",
    "OK": "OK",
    "Time left": "Tempo restante",
    "Water": "Água",
    "Edit {name}": "Editar {name}",
    "Dolphin Robot": "Robô Dolphin",
    "Edit settings ›": "Editar definições ›",
    "Back": "Voltar",
    "My Pool Robot": "O meu robô de piscina",
    "Duration: ~{n} minute": "Duração: ~{n} minuto",
    "Duration: ~{n} minutes": "Duração: ~{n} minutos",
    "{n} second": "{n} segundo",
    "{n} seconds": "{n} segundos",
    "Save Configuration": "Guardar a configuração",
    "Edit Robot Settings": "Editar as definições do robô",
    "Update the settings for your Dolphin pool robot.": "Altere as definições do robô de piscina Dolphin.",
    "Display Name": "Nome apresentado",
    "Name shown in HomeKit": "Nome apresentado no HomeKit",
    "Model": "Modelo",
    "Settings": "Definições",
    "Default Cleaning Mode": "Modo de limpeza predefinido",
    "Mode used when starting from HomeKit": "Modo usado ao iniciar a partir do HomeKit",
    "Mode Details": "Detalhes do modo",
    "Polling Interval": "Intervalo de consulta",
    "How often to check robot status": "Com que frequência é verificado o estado do robô",
    "Enable Water Temperature Sensor": "Ativar o sensor de temperatura da água",
    "Enable Filter Status": "Ativar o estado do filtro",
    "Maytronics API error: HTTP {0}": "Erro da API Maytronics: HTTP {0}",
    "a serial number is required": "é necessário um número de série",
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
<title>Dolphin Pool Cleaner</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's setup wizard on the UI's materials, without its sign-in (Setup signs in): the account's
     robots, then a robot's settings. One step shows at a time. */
  .page-head { align-items: center; }
  .tile.pool { background: linear-gradient(160deg, #5ba0e9, #2e5a8b); }
  .step { animation: materialize var(--normal) var(--ease-out); }
  .step.again { animation: none; }
  .step-head { display: flex; align-items: center; gap: 12px; margin-bottom: 4px; }
  .step-head h2 { margin: 0; }
  .step > p.muted:first-of-type { margin-top: 4px; }

  .robots { display: grid; gap: 14px; }
  .robot { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 3fr); gap: 0; padding: 0; overflow: hidden; cursor: pointer; text-align: left;
    transition: transform 160ms var(--ease-out), box-shadow var(--normal) ease; }
  .robot:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .robot:active { transform: scale(0.99); }
  .robot .body { padding: 16px 18px; display: grid; gap: 10px; align-content: start; min-width: 0; }
  .robot .head { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .robot .head strong { flex: 1; min-width: 0; font-size: 1.0625rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .robot .facts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .robot .edit { justify-self: end; color: var(--accent); font-weight: 500; font-size: 0.875rem; }

  .picture { position: relative; display: grid; place-items: center; min-height: 170px; padding: 18px;
    background: linear-gradient(180deg, #e8f4fc 0%, #c9e4f6 100%); }
  .picture img, .picture svg { width: 100%; max-width: 200px; max-height: 150px; object-fit: contain; filter: drop-shadow(0 4px 8px rgba(0, 0, 0, 0.2)); }
  .picture .pill { position: absolute; top: 10px; left: 10px; background: var(--material-thick); }
  /* Dark with the system unless the web UI's appearance says light, or dark when it says so (common.js sets data-theme). */
  @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) .picture { background: linear-gradient(180deg, #1e3a4c 0%, #0d2233 100%); } }
  :root[data-theme="dark"] .picture { background: linear-gradient(180deg, #1e3a4c 0%, #0d2233 100%); }

  .found { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 18px; align-items: start; }
  .found .robot-panel { padding: 0; overflow: hidden; margin: 0; }
  .found .robot-panel .body { padding: 14px 18px 18px; }
  .found .settings { margin: 0; }
  .details { display: grid; gap: 0; margin-top: 10px; }
  .details div { display: flex; justify-content: space-between; gap: 12px; padding: 6px 0; border-bottom: 1px solid var(--line); font-size: 0.8125rem; }
  .details div:last-child { border-bottom: 0; }
  .details span { color: var(--muted); white-space: nowrap; }
  .details b { font-weight: 500; font-family: var(--mono); text-align: right; overflow-wrap: anywhere; }

  .mode-info { margin: 10px 0 4px; padding: 10px 14px; border-radius: 0 14px 14px 0; border-left: 3px solid #1f6fe0; background: var(--material-thin); font-size: 0.8125rem; }
  .mode-info strong { display: block; font-size: 0.6875rem; letter-spacing: 0.06em; text-transform: uppercase; color: #1f6fe0; margin-bottom: 4px; }
  .mode-info p { margin: 0 0 6px; }
  .mode-info .muted { padding-top: 6px; border-top: 1px solid var(--line); }

  .account-line { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin-bottom: 14px; }

  @media (max-width: 640px) {
    .robot, .found { grid-template-columns: 1fr; }
    .picture { min-height: 120px; }
    .picture img, .picture svg { max-width: 140px; max-height: 100px; }
    .robot .facts { grid-template-columns: 1fr; }
  }
  @media (prefers-reduced-motion: reduce) {
    .step { animation: none; }
    .robot { transition: none; }
    .robot:hover, .robot:active { transform: none; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large pool" aria-hidden="true"></span>
    <div>
      <h1>Dolphin Pool Cleaner</h1>
      <p class="muted" data-i18n>Connect your MyDolphin Plus account, then choose how your robot appears in the Home app.</p>
    </div>
  </div>
  <div id="wizard"></div>
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
