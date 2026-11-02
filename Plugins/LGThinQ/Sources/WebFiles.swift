// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension LGThinQPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The LG ThinQ page: the Homebridge plugin's settings wizard. Step 1 is the LG account: signed out, a card to Setup on
// Add accessories, which signs in; signed in, its region and way, with Sign in again. Step 2 lists the account's devices
// to pick for HomeKit, with each device's options, and the sync settings; saving writes this instance's block, which
// reloads the plugin.
(() => {
  "use strict";
  const { $, el, api, request, readBlock, updateBlock, explain, breadcrumb } = homeswift;
  const { t } = HomeswiftI18n;

  const DEFAULT_REFRESH_INTERVAL = 60;

  // The options of each device type, as the Homebridge page shows them.
  const DEVICE_TYPE_FIELDS = {
    AC: {
      selects: [
        { key: "ac_mode", label: t("AC mode"), options: [["", t("Both (default)")], ["COOLING", t("Cooling only")], ["HEATING", t("Heating only")], ["BOTH", t("Both")]] },
        { key: "ac_swing_mode", label: t("Swing mode"), options: [["", t("Default")], ["BOTH", t("Both axes")], ["VERTICAL", t("Vertical only")], ["HORIZONTAL", t("Horizontal only")]] },
        { key: "ac_temperature_unit", label: t("Temperature unit"), options: [["C", t("Celsius (°C)")], ["F", t("Fahrenheit (°F)")]] },
      ],
      toggles: [
        { key: "ac_fan_control", label: t("Separate fan control"), group: t("Controls") },
        { key: "ac_jet_control", label: t("Separate jet control"), group: t("Controls") },
        { key: "ac_energy_save", label: t("Energy save switch"), group: t("Controls") },
        { key: "ac_air_clean", label: t("Air purify switch"), group: t("Controls") },
        { key: "ac_led_control", label: t("LED panel control"), group: t("Controls") },
        { key: "ac_air_quality", label: t("Air quality sensor"), group: t("Sensors") },
        { key: "ac_temperature_sensor", label: t("Current temperature as sensor"), group: t("Sensors") },
        { key: "ac_humidity_sensor", label: t("Humidity sensor"), group: t("Sensors") },
      ],
    },
    WASHER: {
      toggles: [
        { key: "washer_trigger", label: t("Program finished trigger") },
        { key: "washer_tub_clean", label: t("Tub clean event") },
        { key: "washer_door_lock", label: t("Door lock status") },
      ],
    },
    REFRIGERATOR: {
      toggles: [
        { key: "ref_express_freezer", label: t("Express Freezer / Ice Plus") },
        { key: "ref_express_fridge", label: t("Express Fridge") },
        { key: "ref_eco_friendly", label: t("Eco Friendly") },
      ],
    },
    DISHWASHER: { toggles: [{ key: "dishwasher_trigger", label: t("Program finished trigger") }] },
    AIR_PURIFIER: { toggles: [{ key: "air_fast_mode", label: t("Air Fast Mode") }] },
  };
  for (const type of ["WASHER_NEW", "WASH_TOWER", "WASH_TOWER_2", "DRYER"]) DEVICE_TYPE_FIELDS[type] = DEVICE_TYPE_FIELDS.WASHER;
  // The AeroTower is an air purifier with the same Air Fast switch.
  DEVICE_TYPE_FIELDS.AERO_TOWER = DEVICE_TYPE_FIELDS.AIR_PURIFIER;
  const AC_OP_MODES = [[0, t("Cool")], [1, t("Dry")], [2, t("Fan")], [4, t("Heat")], [5, t("Air Clean")], [6, t("Auto")]];

  // State: the block as saved, the sign-in's state, the account's devices and the choices on them.
  let config = {};
  let account = {};
  let devices = [];
  const selected = new Set();
  const deviceSettings = {};
  let activeDevice = null;

  const steps = { devices: $("#step-devices"), complete: $("#step-complete") };
  const showStep = (step) => Object.entries(steps).forEach(([key, node]) => node.classList.toggle("hidden", key !== step));

  /// Runs `work` with the button disabled and a spinner on it; errors reach the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Problems, with the Assistant's explanation when it is set up

  // What the Assistant may see: the region and modes, never the email, password, refresh token or device ids.
  const assistantContext = (extra) => [
    extra,
    `Auth mode: ${account.authMode || config.auth_mode || "token"}.`,
    `Account region: country ${account.country || config.country || "unset"}, language ${account.language || config.language || "unset"}.`,
    config.thinq1 ? `ThinQ1 support is enabled (refresh interval ${config.refresh_interval || DEFAULT_REFRESH_INTERVAL} s).` : "ThinQ1 support is disabled.",
  ].filter(Boolean).join(" ");

  function showProblem(container, message, context) {
    container.classList.remove("hidden");
    container.replaceChildren(el("p", { class: "error", text: message }), explain({ error: message, context: assistantContext(context) }));
  }
  function clearProblem(container) {
    container.classList.add("hidden");
    container.replaceChildren();
  }

  // MARK: Step 1: the account, signed in through Setup

  // A region named in the page's language (Intl.DisplayNames), its language by its own name; the codes otherwise.
  const displayNames = (locale, type) => { try { return new Intl.DisplayNames([locale], { type }); } catch { return null; } };
  function regionText(country, language) {
    if (!country || !language) return "—";
    try {
      const region = displayNames(HomeswiftI18n.locale, "region")?.of(country) || country;
      const primary = language.split("-")[0];
      const speech = displayNames(primary, "language")?.of(primary) || language;
      return `${region} / ${speech}`;
    } catch { return `${country} / ${language}`; }
  }

  $("#sign-in-again").href = homeswift.setupAddress({ start: true });

  /// The sign-in's state: signed out, the card to Setup; signed in, its facts and the devices.
  function renderAccount() {
    const signedIn = !!account.authorized;
    $("#account").classList.toggle("hidden", !signedIn);
    $("#account-setup").replaceChildren(signedIn ? "" : homeswift.setupCard({
      title: t("Sign in to your LG account"),
      text: t("Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done."),
      glyph: "key",
    }));
    if (!signedIn) return;
    $("#account-region").textContent = regionText(account.country, account.language);
    $("#account-mode").textContent = account.authMode === "account" ? t("Email and password") : t("LG's sign-in page");
    $("#account-email-row").classList.toggle("hidden", !account.username);
    $("#account-email").textContent = account.username || "";
  }

  // MARK: Step 2: devices

  const list = $("#device-list");
  const typeOf = (device) => String(device.type || "Unknown");

  async function loadDevices() {
    const button = $("#refresh");
    const problem = $("#devices-problem");
    clearProblem(problem);
    await act(button, async () => {
      try {
        const answer = await request("account-devices");
        devices = answer.devices || [];
        if (selected.size === 0) devices.forEach((device) => selected.add(device.id));
        renderDevices();
      } catch (e) {
        showProblem(problem, HomeswiftI18n.message(e.message) || t("Failed to load devices"),
          "Loading the device list of the account this instance signed in with from the LG ThinQ cloud failed in the plugin settings.");
      }
    });
  }

  function renderDevices() {
    $("#device-count").textContent = String(devices.length);
    $("#select-all").textContent = selected.size === devices.length && devices.length > 0 ? t("Deselect all") : t("Select all");
    if (!devices.length) {
      list.replaceChildren(el("li", { class: "empty muted", text: t("No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.") }));
      return;
    }
    list.replaceChildren(...devices.map((device) => {
      const overrides = deviceSettings[device.id] || {};
      const isSelected = selected.has(device.id);
      const online = device.online !== false;
      const checkbox = el("input", { type: "checkbox", checked: isSelected, "aria-label": t("Add {name} to HomeKit", { name: overrides.name || device.name }) });
      const row = el("li", { class: `device${isSelected ? " selected" : ""}`, "data-id": device.id },
        checkbox,
        el("div", { class: "who" }, el("strong", { text: overrides.name || device.name }),
          el("div", { class: "meta muted" }, el("span", { text: device.type ? typeOf(device) : t("Unknown") }), " · ", el("span", { class: "id mono", text: t("ID: {id}", { id: device.id }) }))),
        online ? null : explain({
          error: "The LG ThinQ cloud reports this appliance as offline (not connected to LG).",
          context: assistantContext("The user is looking at the device list of the LG ThinQ plugin settings."),
          device: { name: overrides.name || device.name, type: typeOf(device), online, includedInHomeKit: isSelected },
        }),
        device.running ? el("span", { class: "pill on", text: t("In HomeKit") }) : null,
        el("span", { class: `pill status ${online ? "on" : "away"}`, text: online ? t("Online") : t("Offline") }),
        el("button", { class: "gear", title: t("Device settings"), "aria-label": t("Settings of {name}", { name: overrides.name || device.name }), text: "⚙",
          onclick: (event) => { event.stopPropagation(); openDevice(device.id); } }));
      row.addEventListener("click", (event) => {
        if (event.target.closest(".gear, .explain")) return;
        if (event.target !== checkbox) checkbox.checked = !checkbox.checked;
        if (checkbox.checked) selected.add(device.id); else selected.delete(device.id);
        row.classList.toggle("selected", checkbox.checked);
        $("#select-all").textContent = selected.size === devices.length ? t("Deselect all") : t("Select all");
      });
      return row;
    }));
  }

  $("#refresh").addEventListener("click", () => loadDevices());
  $("#select-all").addEventListener("click", () => {
    if (selected.size === devices.length) selected.clear(); else devices.forEach((device) => selected.add(device.id));
    renderDevices();
  });

  // MARK: A device's options

  const panel = $("#device-panel");
  const fieldRow = (label, control, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), control, help ? el("span", { class: "help", text: help }) : null);
  const toggleRow = (label, input) => el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")), el("span", {}, el("span", { class: "field-title", text: label })));

  function openDevice(id) {
    const device = devices.find((d) => d.id === id);
    if (!device) return;
    activeDevice = id;
    const overrides = deviceSettings[id] || {};
    const fields = DEVICE_TYPE_FIELDS[device.type];
    const nameInput = el("input", { type: "text", value: overrides.name || "", placeholder: device.name, maxLength: 64 });
    const serialInput = el("input", { type: "text", value: overrides.serial_number || "", class: "mono", spellcheck: false });
    const selects = {};
    const toggles = {};
    let buttonsList = null;
    const typeSection = [];
    if (fields) {
      typeSection.push(el("h3", { class: "group-title", text: t("{type} settings", { type: device.type }) }));
      if (fields.selects) {
        typeSection.push(el("div", { class: "columns" }, fields.selects.map((field) => {
          const select = el("select", {}, field.options.map(([value, label]) => el("option", { value, text: label, selected: String(overrides[field.key] || "").toUpperCase() === value })));
          selects[field.key] = select;
          return fieldRow(field.label, select);
        })));
      }
      const groups = [];
      for (const field of fields.toggles || []) {
        const group = field.group || "";
        let entry = groups.find((g) => g.name === group);
        if (!entry) groups.push(entry = { name: group, fields: [] });
        entry.fields.push(field);
      }
      typeSection.push(el("div", { class: "columns" }, groups.map((group) => el("div", {},
        group.name ? el("p", { class: "group-title", text: group.name }) : null,
        group.fields.map((field) => {
          const input = el("input", { type: "checkbox", checked: !!overrides[field.key] });
          toggles[field.key] = input;
          return toggleRow(field.label, input);
        })))));
      if (device.type === "AC") {
        buttonsList = el("div", {});
        const addButton = (button = {}) => {
          const label = el("input", { type: "text", placeholder: t("Name"), value: button.name || "" });
          const mode = el("select", {}, AC_OP_MODES.map(([value, title]) => el("option", { value: String(value), text: title, selected: Number(button.op_mode ?? 0) === value })));
          const row = el("div", { class: "button-row" }, label, mode, el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: () => row.remove() }));
          buttonsList.append(row);
        };
        (overrides.ac_buttons || []).forEach(addButton);
        typeSection.push(el("div", { class: "buttons-editor" },
          el("div", { class: "list-head" }, el("h3", { class: "group-title", text: t("AC buttons") }), el("button", { actionIcon: "plus", text: t("Add button"), onclick: () => addButton() })),
          el("p", { class: "help", text: t("Custom HomeKit switches that select an operation mode.") }), buttonsList));
      }
    }
    const apply = () => {
      const next = { ...(deviceSettings[id] || {}) };
      next.name = nameInput.value.trim();
      next.serial_number = serialInput.value.trim() || undefined;
      for (const [key, select] of Object.entries(selects)) { if (select.value) next[key] = select.value; else delete next[key]; }
      for (const [key, input] of Object.entries(toggles)) next[key] = input.checked;
      if (buttonsList) {
        next.ac_buttons = [...buttonsList.querySelectorAll(".button-row")]
          .map((row) => ({ name: row.querySelector("input").value.trim(), op_mode: parseInt(row.querySelector("select").value, 10) || 0 }))
          .filter((button) => button.name);
      }
      deviceSettings[id] = next;
      closeDevice();
      renderDevices();
      $("#devices-status").textContent = t("Device settings applied: Save to keep them.");
    };
    breadcrumb(overrides.name || device.name, closeDevice);
    panel.classList.remove("hidden");
    panel.replaceChildren(
      el("div", { class: "panel-head" }, el("h3", { text: overrides.name || device.name }), el("button", { actionIcon: "close", class: "link", text: t("Close"), onclick: closeDevice })),
      el("div", { class: "columns" },
        fieldRow(t("Display name"), nameInput, t("Its name in HomeKit; empty uses the device's name.")),
        fieldRow(t("Serial number (optional)"), serialInput)),
      typeSection,
      el("div", { class: "save-bar" }, el("span", { class: "muted", text: "" }), el("button", { actionIcon: "close", text: t("Cancel"), onclick: closeDevice }), el("button", { actionIcon: "check", class: "primary", text: t("Apply"), onclick: apply })));
    panel.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "nearest" });
  }

  function closeDevice() {
    if (activeDevice) breadcrumb(null);
    activeDevice = null;
    panel.classList.add("hidden");
    panel.replaceChildren();
  }

  /// The selected devices with their options; options left off are dropped, as the Homebridge page keeps the block clean.
  const selectedDevicesConfig = () => devices.filter((device) => selected.has(device.id)).map((device) => {
    const cleaned = Object.fromEntries(Object.entries(deviceSettings[device.id] || {}).filter(([, value]) => value !== false && value !== "" && value !== undefined));
    return { id: device.id, name: device.name, type: device.type, ...cleaned };
  });

  async function saveConfiguration(button) {
    await act(button, async () => {
      try {
        // The sign-in (the way, the region, the account) is Setup's: the block keeps what it has.
        const next = {
          ...config, platform: "LGThinQ", name: config.name || "LG ThinQ",
          refresh_interval: parseInt($("#refresh-interval").value, 10) || DEFAULT_REFRESH_INTERVAL,
          devices: selectedDevicesConfig(),
        };
        if (!next.thinq1) delete next.thinq1;
        const report = await updateBlock(() => next);
        config = next;
        const pending = report.restartNeeded || [];
        $("#restart").classList.toggle("hidden", pending.length === 0);
        $("#complete-text").textContent = pending.length
          ? t("Saved. Restart Homeswift to apply the rest ({changes}).", { changes: pending.join("; ") })
          : t("Saved. The plugin restarted with the new settings: its devices keep their place in the Home app.");
        showStep("complete");
      } catch (e) {
        $("#devices-status").textContent = e.message || t("Failed to save the configuration");
      }
    });
  }

  $("#save").addEventListener("click", (event) => saveConfiguration(event.currentTarget));

  // MARK: Settings tab

  function prefillSettings() {
    $("#refresh-interval").value = config.refresh_interval || DEFAULT_REFRESH_INTERVAL;
    $("#thinq1").checked = !!config.thinq1;
  }

  $("#save-settings").addEventListener("click", (event) => {
    config.refresh_interval = parseInt($("#refresh-interval").value, 10) || DEFAULT_REFRESH_INTERVAL;
    config.thinq1 = $("#thinq1").checked || undefined;
    saveConfiguration(event.currentTarget);
  });

  function selectTab(tab) {
    for (const [key, button, pane] of [["devices", $("#tab-devices"), $("#pane-devices")], ["settings", $("#tab-settings"), $("#pane-settings")]]) {
      button.classList.toggle("on", key === tab);
      button.setAttribute("aria-selected", String(key === tab));
      pane.classList.toggle("hidden", key !== tab);
    }
    if (tab === "devices") closeDevice();
  }
  $("#tab-devices").addEventListener("click", () => selectTab("devices"));
  $("#tab-settings").addEventListener("click", () => selectTab("settings"));

  // MARK: Step 3

  $("#back").addEventListener("click", () => showStep("devices"));
  $("#restart").addEventListener("click", (event) => act(event.currentTarget, async () => {
    await api("/api/restart", { method: "POST" });
    $("#complete-text").textContent = t("Restarting…");
    for (let tries = 0; tries < 60; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try { await request("devices"); break; } catch { /* not back yet */ }
    }
    $("#complete-text").textContent = t("Homeswift restarted with the new settings.");
    $("#restart").classList.add("hidden");
  }));

  // MARK: Start: the block and the sign-in, then the account's devices once signed in

  (async () => {
    try {
      config = (await readBlock()) || {};
      account = await request("account");
    } catch (e) {
      showProblem($("#account-problem"), e.message);
    }
    for (const device of config.devices || []) {
      selected.add(device.id);
      deviceSettings[device.id] = { ...device };
    }
    prefillSettings();
    renderAccount();
    if (account.authorized) {
      showStep("devices");
      await loadDevices();
    } else {
      showStep(null);
    }
  })();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The LG ThinQ page's strings and the plugin's errors in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Connect your LG account to manage its appliances in HomeKit.": "Connectez votre compte LG pour gérer ses appareils dans HomeKit.",
    "Email": "E-mail",
    "Your devices": "Vos appareils",
    "Devices": "Appareils",
    "Settings": "Réglages",
    "Devices in your account": "Appareils de votre compte",
    "Select all": "Tout sélectionner",
    "Deselect all": "Tout désélectionner",
    "Refresh": "Actualiser",
    "Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.": "Les appareils cochés sont ajoutés à HomeKit (aucun coché : tous). ⚙ règle les options d'un appareil.",
    "Save configuration": "Enregistrer la configuration",
    "Region": "Région",
    "Sync": "Synchronisation",
    "ThinQ1 support": "Prise en charge de ThinQ1",
    "Adds the account's older ThinQ v1 devices, which are polled.": "Ajoute les anciens appareils ThinQ v1 du compte, qui sont interrogés régulièrement.",
    "Refresh interval (seconds)": "Intervalle d'actualisation (secondes)",
    "How often ThinQ1 devices are polled. Default: 60.": "La fréquence d'interrogation des appareils ThinQ1. Par défaut : 60.",
    "ThinQ2 devices are pushed by LG and need no polling.": "Les appareils ThinQ2 sont mis à jour par LG et n'ont pas besoin d'être interrogés.",
    "Configuration saved": "Configuration enregistrée",
    "The plugin restarted with the new settings.": "Le plugin a redémarré avec les nouveaux réglages.",
    "Restart Homeswift": "Redémarrer Homeswift",
    "Back to the devices": "Retour aux appareils",
    "AC mode": "Mode du climatiseur",
    "Both (default)": "Les deux (par défaut)",
    "Cooling only": "Refroidissement seul",
    "Heating only": "Chauffage seul",
    "Both": "Les deux",
    "Swing mode": "Mode d'oscillation",
    "Default": "Par défaut",
    "Both axes": "Deux axes",
    "Vertical only": "Vertical seul",
    "Horizontal only": "Horizontal seul",
    "Temperature unit": "Unité de température",
    "Celsius (°C)": "Celsius (°C)",
    "Fahrenheit (°F)": "Fahrenheit (°F)",
    "Controls": "Commandes",
    "Sensors": "Capteurs",
    "Separate fan control": "Commande distincte du ventilateur",
    "Separate jet control": "Commande distincte du mode Jet",
    "Energy save switch": "Interrupteur d'économie d'énergie",
    "Air purify switch": "Interrupteur de purification d'air",
    "LED panel control": "Commande du panneau LED",
    "Air quality sensor": "Capteur de qualité de l'air",
    "Current temperature as sensor": "Température actuelle comme capteur",
    "Humidity sensor": "Capteur d'humidité",
    "Program finished trigger": "Déclencheur de fin de programme",
    "Tub clean event": "Événement de nettoyage de la cuve",
    "Door lock status": "État du verrouillage de la porte",
    "Express Freezer / Ice Plus": "Congélation express / Ice Plus",
    "Express Fridge": "Réfrigération express",
    "Eco Friendly": "Mode éco",
    "Air Fast Mode": "Mode Air Fast",
    "Cool": "Froid",
    "Dry": "Déshumidification",
    "Fan": "Ventilation",
    "Heat": "Chaud",
    "Air Clean": "Purification",
    "Auto": "Auto",
    "Failed to load devices": "Impossible de charger les appareils",
    "Add {name} to HomeKit": "Ajouter {name} à HomeKit",
    "Unknown": "Inconnu",
    "ID: {id}": "ID : {id}",
    "In HomeKit": "Dans HomeKit",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Device settings": "Réglages de l'appareil",
    "Settings of {name}": "Réglages de {name}",
    "{type} settings": "Réglages {type}",
    "Name": "Nom",
    "Remove": "Supprimer",
    "AC buttons": "Boutons du climatiseur",
    "Add button": "Ajouter un bouton",
    "Custom HomeKit switches that select an operation mode.": "Des interrupteurs HomeKit personnalisés qui choisissent un mode de fonctionnement.",
    "Device settings applied: Save to keep them.": "Réglages de l'appareil appliqués : enregistrez pour les conserver.",
    "Close": "Fermer",
    "Display name": "Nom affiché",
    "Its name in HomeKit; empty uses the device's name.": "Son nom dans HomeKit ; vide, le nom de l'appareil est utilisé.",
    "Serial number (optional)": "Numéro de série (facultatif)",
    "Cancel": "Annuler",
    "Apply": "Appliquer",
    "Saved. Restart Homeswift to apply the rest ({changes}).": "Enregistré. Redémarrez Homeswift pour appliquer le reste ({changes}).",
    "Saved. The plugin restarted with the new settings: its devices keep their place in the Home app.": "Enregistré. Le plugin a redémarré avec les nouveaux réglages : ses appareils gardent leur place dans l'app Maison.",
    "Failed to save the configuration": "Impossible d'enregistrer la configuration",
    "Restarting…": "Redémarrage…",
    "Homeswift restarted with the new settings.": "Homeswift a redémarré avec les nouveaux réglages.",
    "LG ThinQ did not answer; try again later.": "LG ThinQ n'a pas répondu ; réessayez plus tard.",
    "Invalid refreshToken: refreshToken must be a non-empty string.": "refreshToken non valide : il ne doit pas être vide.",
    "Your account was already used to registered in {0}.": "Votre compte est déjà enregistré dans {0}.",
    "LG rejected the sign-in. If you sign in to LG with Google, Apple or Facebook, use a token instead.": "LG a refusé la connexion. Si vous vous connectez à LG avec Google, Apple ou Facebook, utilisez plutôt un jeton.",
    "LG rejected the sign-in.": "LG a refusé la connexion.",
    "LG returned no account for this sign-in.": "LG n'a renvoyé aucun compte pour cette connexion.",
    "LG returned no authorization code.": "LG n'a renvoyé aucun code d'autorisation.",
    "LG returned no redirect.": "LG n'a renvoyé aucune redirection.",
    "LG returned no access token for the refresh token.": "LG n'a renvoyé aucun jeton d'accès pour le jeton d'actualisation.",
    "LG returned no user number.": "LG n'a renvoyé aucun numéro d'utilisateur.",
    "Could not read the terms signature from LG. Open the LG ThinQ app and accept the new terms.": "Impossible de lire la signature des conditions de LG. Ouvrez l'app LG ThinQ et acceptez les nouvelles conditions.",
    "Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift.": "Ouvrez l'app LG et connectez-vous à votre compte pour voir ce qui s'est passé : de nouvelles conditions sont peut-être à accepter. Redémarrez ensuite Homeswift.",
    "Request failed with status code {0}": "La requête a échoué avec le code {0}",
    "not signed in": "non connecté",
    "Your LG account": "Votre compte LG",
    "Signed in with": "Connecté avec",
    "Sign in to your LG account": "Connectez-vous à votre compte LG",
    "Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done.": "Homeswift se connecte dans Ajouter des accessoires, avec la page de connexion de LG (pour les comptes LG, Google, Apple, Facebook ou Amazon) ou l'e-mail et le mot de passe du compte. Ses appareils apparaissent ici une fois la connexion faite.",
    "Email and password": "E-mail et mot de passe",
    "LG's sign-in page": "La page de connexion de LG",
    "No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.": "Aucun appareil trouvé. Ajoutez-les à votre compte LG dans l'app LG ThinQ, puis appuyez sur Actualiser.",
    "This instance has no LG sign-in yet: sign in through Setup (Add accessories) first.": "Cette instance n'a pas encore de connexion LG : connectez-vous d'abord dans Ajouter des accessoires."
  },
  "es": {
    "Connect your LG account to manage its appliances in HomeKit.": "Conecta tu cuenta de LG para gestionar sus electrodomésticos en HomeKit.",
    "Email": "Correo electrónico",
    "Your devices": "Tus dispositivos",
    "Devices": "Dispositivos",
    "Settings": "Ajustes",
    "Devices in your account": "Dispositivos de tu cuenta",
    "Select all": "Seleccionar todo",
    "Deselect all": "Deseleccionar todo",
    "Refresh": "Actualizar",
    "Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.": "Los dispositivos marcados se añaden a HomeKit (ninguno marcado: todos). ⚙ ajusta las opciones de un dispositivo.",
    "Save configuration": "Guardar configuración",
    "Region": "Región",
    "Sync": "Sincronización",
    "ThinQ1 support": "Compatibilidad con ThinQ1",
    "Adds the account's older ThinQ v1 devices, which are polled.": "Añade los dispositivos ThinQ v1 más antiguos de la cuenta, que se consultan periódicamente.",
    "Refresh interval (seconds)": "Intervalo de actualización (segundos)",
    "How often ThinQ1 devices are polled. Default: 60.": "Cada cuánto se consultan los dispositivos ThinQ1. Predeterminado: 60.",
    "ThinQ2 devices are pushed by LG and need no polling.": "LG envía los cambios de los dispositivos ThinQ2, que no necesitan consultas.",
    "Configuration saved": "Configuración guardada",
    "The plugin restarted with the new settings.": "El plugin se ha reiniciado con los nuevos ajustes.",
    "Restart Homeswift": "Reiniciar Homeswift",
    "Back to the devices": "Volver a los dispositivos",
    "AC mode": "Modo del aire acondicionado",
    "Both (default)": "Ambos (predeterminado)",
    "Cooling only": "Solo refrigeración",
    "Heating only": "Solo calefacción",
    "Both": "Ambos",
    "Swing mode": "Modo de oscilación",
    "Default": "Predeterminado",
    "Both axes": "Ambos ejes",
    "Vertical only": "Solo vertical",
    "Horizontal only": "Solo horizontal",
    "Temperature unit": "Unidad de temperatura",
    "Celsius (°C)": "Celsius (°C)",
    "Fahrenheit (°F)": "Fahrenheit (°F)",
    "Controls": "Controles",
    "Sensors": "Sensores",
    "Separate fan control": "Control independiente del ventilador",
    "Separate jet control": "Control independiente del modo Jet",
    "Energy save switch": "Interruptor de ahorro de energía",
    "Air purify switch": "Interruptor de purificación del aire",
    "LED panel control": "Control del panel LED",
    "Air quality sensor": "Sensor de calidad del aire",
    "Current temperature as sensor": "Temperatura actual como sensor",
    "Humidity sensor": "Sensor de humedad",
    "Program finished trigger": "Activador de fin de programa",
    "Tub clean event": "Evento de limpieza del tambor",
    "Door lock status": "Estado del bloqueo de la puerta",
    "Express Freezer / Ice Plus": "Congelación exprés / Ice Plus",
    "Express Fridge": "Refrigeración exprés",
    "Eco Friendly": "Modo eco",
    "Air Fast Mode": "Modo Air Fast",
    "Cool": "Frío",
    "Dry": "Deshumidificación",
    "Fan": "Ventilación",
    "Heat": "Calor",
    "Air Clean": "Purificación",
    "Auto": "Auto",
    "Failed to load devices": "No se han podido cargar los dispositivos",
    "Add {name} to HomeKit": "Añadir {name} a HomeKit",
    "Unknown": "Desconocido",
    "ID: {id}": "ID: {id}",
    "In HomeKit": "En HomeKit",
    "Online": "Conectado",
    "Offline": "Desconectado",
    "Device settings": "Ajustes del dispositivo",
    "Settings of {name}": "Ajustes de {name}",
    "{type} settings": "Ajustes de {type}",
    "Name": "Nombre",
    "Remove": "Eliminar",
    "AC buttons": "Botones del aire acondicionado",
    "Add button": "Añadir botón",
    "Custom HomeKit switches that select an operation mode.": "Interruptores de HomeKit personalizados que eligen un modo de funcionamiento.",
    "Device settings applied: Save to keep them.": "Ajustes del dispositivo aplicados: guarda para conservarlos.",
    "Close": "Cerrar",
    "Display name": "Nombre visible",
    "Its name in HomeKit; empty uses the device's name.": "Su nombre en HomeKit; si está vacío, se usa el del dispositivo.",
    "Serial number (optional)": "Número de serie (opcional)",
    "Cancel": "Cancelar",
    "Apply": "Aplicar",
    "Saved. Restart Homeswift to apply the rest ({changes}).": "Guardado. Reinicia Homeswift para aplicar el resto ({changes}).",
    "Saved. The plugin restarted with the new settings: its devices keep their place in the Home app.": "Guardado. El plugin se ha reiniciado con los nuevos ajustes: sus dispositivos conservan su lugar en la app Casa.",
    "Failed to save the configuration": "No se ha podido guardar la configuración",
    "Restarting…": "Reiniciando…",
    "Homeswift restarted with the new settings.": "Homeswift se ha reiniciado con los nuevos ajustes.",
    "LG ThinQ did not answer; try again later.": "LG ThinQ no ha respondido; vuelve a intentarlo más tarde.",
    "Invalid refreshToken: refreshToken must be a non-empty string.": "refreshToken no válido: no puede estar vacío.",
    "Your account was already used to registered in {0}.": "Tu cuenta ya está registrada en {0}.",
    "LG rejected the sign-in. If you sign in to LG with Google, Apple or Facebook, use a token instead.": "LG ha rechazado el inicio de sesión. Si inicias sesión en LG con Google, Apple o Facebook, usa un token.",
    "LG rejected the sign-in.": "LG ha rechazado el inicio de sesión.",
    "LG returned no account for this sign-in.": "LG no ha devuelto ninguna cuenta para este inicio de sesión.",
    "LG returned no authorization code.": "LG no ha devuelto ningún código de autorización.",
    "LG returned no redirect.": "LG no ha devuelto ninguna redirección.",
    "LG returned no access token for the refresh token.": "LG no ha devuelto ningún token de acceso para el token de actualización.",
    "LG returned no user number.": "LG no ha devuelto ningún número de usuario.",
    "Could not read the terms signature from LG. Open the LG ThinQ app and accept the new terms.": "No se ha podido leer la firma de las condiciones de LG. Abre la app LG ThinQ y acepta las nuevas condiciones.",
    "Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift.": "Abre la app de LG e inicia sesión en tu cuenta para ver qué ha pasado: quizá haya nuevas condiciones que aceptar. Después reinicia Homeswift.",
    "Request failed with status code {0}": "La solicitud ha fallado con el código {0}",
    "not signed in": "sin sesión iniciada",
    "Your LG account": "Tu cuenta de LG",
    "Signed in with": "Sesión iniciada con",
    "Sign in to your LG account": "Inicia sesión en tu cuenta de LG",
    "Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done.": "Homeswift inicia sesión en Añadir accesorios, con la página de inicio de sesión de LG (para cuentas de LG, Google, Apple, Facebook o Amazon) o el correo electrónico y la contraseña de la cuenta. Sus electrodomésticos aparecen aquí una vez hecho.",
    "Email and password": "Correo electrónico y contraseña",
    "LG's sign-in page": "La página de inicio de sesión de LG",
    "No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.": "No se han encontrado dispositivos. Añádelos a tu cuenta de LG en la app LG ThinQ y pulsa Actualizar.",
    "This instance has no LG sign-in yet: sign in through Setup (Add accessories) first.": "Esta instancia aún no tiene sesión de LG: inicia sesión primero en Añadir accesorios."
  },
  "pt": {
    "Connect your LG account to manage its appliances in HomeKit.": "Ligue a sua conta LG para gerir os eletrodomésticos no HomeKit.",
    "Email": "E-mail",
    "Your devices": "Os seus dispositivos",
    "Devices": "Dispositivos",
    "Settings": "Definições",
    "Devices in your account": "Dispositivos da sua conta",
    "Select all": "Selecionar tudo",
    "Deselect all": "Desmarcar tudo",
    "Refresh": "Atualizar",
    "Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.": "Os dispositivos assinalados são adicionados ao HomeKit (nenhum assinalado: todos). ⚙ define as opções de um dispositivo.",
    "Save configuration": "Guardar configuração",
    "Region": "Região",
    "Sync": "Sincronização",
    "ThinQ1 support": "Suporte de ThinQ1",
    "Adds the account's older ThinQ v1 devices, which are polled.": "Adiciona os dispositivos ThinQ v1 mais antigos da conta, que são consultados periodicamente.",
    "Refresh interval (seconds)": "Intervalo de atualização (segundos)",
    "How often ThinQ1 devices are polled. Default: 60.": "A frequência de consulta dos dispositivos ThinQ1. Predefinição: 60.",
    "ThinQ2 devices are pushed by LG and need no polling.": "A LG envia as alterações dos dispositivos ThinQ2, que não precisam de consultas.",
    "Configuration saved": "Configuração guardada",
    "The plugin restarted with the new settings.": "O plugin reiniciou com as novas definições.",
    "Restart Homeswift": "Reiniciar o Homeswift",
    "Back to the devices": "Voltar aos dispositivos",
    "AC mode": "Modo do ar condicionado",
    "Both (default)": "Ambos (predefinição)",
    "Cooling only": "Só arrefecimento",
    "Heating only": "Só aquecimento",
    "Both": "Ambos",
    "Swing mode": "Modo de oscilação",
    "Default": "Predefinição",
    "Both axes": "Ambos os eixos",
    "Vertical only": "Só vertical",
    "Horizontal only": "Só horizontal",
    "Temperature unit": "Unidade de temperatura",
    "Celsius (°C)": "Celsius (°C)",
    "Fahrenheit (°F)": "Fahrenheit (°F)",
    "Controls": "Controlos",
    "Sensors": "Sensores",
    "Separate fan control": "Controlo separado da ventoinha",
    "Separate jet control": "Controlo separado do modo Jet",
    "Energy save switch": "Interruptor de poupança de energia",
    "Air purify switch": "Interruptor de purificação do ar",
    "LED panel control": "Controlo do painel LED",
    "Air quality sensor": "Sensor de qualidade do ar",
    "Current temperature as sensor": "Temperatura atual como sensor",
    "Humidity sensor": "Sensor de humidade",
    "Program finished trigger": "Acionador de fim de programa",
    "Tub clean event": "Evento de limpeza do tambor",
    "Door lock status": "Estado do bloqueio da porta",
    "Express Freezer / Ice Plus": "Congelação rápida / Ice Plus",
    "Express Fridge": "Refrigeração rápida",
    "Eco Friendly": "Modo eco",
    "Air Fast Mode": "Modo Air Fast",
    "Cool": "Frio",
    "Dry": "Desumidificação",
    "Fan": "Ventilação",
    "Heat": "Calor",
    "Air Clean": "Purificação",
    "Auto": "Auto",
    "Failed to load devices": "Não foi possível carregar os dispositivos",
    "Add {name} to HomeKit": "Adicionar {name} ao HomeKit",
    "Unknown": "Desconhecido",
    "ID: {id}": "ID: {id}",
    "In HomeKit": "No HomeKit",
    "Online": "Online",
    "Offline": "Offline",
    "Device settings": "Definições do dispositivo",
    "Settings of {name}": "Definições de {name}",
    "{type} settings": "Definições de {type}",
    "Name": "Nome",
    "Remove": "Remover",
    "AC buttons": "Botões do ar condicionado",
    "Add button": "Adicionar botão",
    "Custom HomeKit switches that select an operation mode.": "Interruptores HomeKit personalizados que escolhem um modo de funcionamento.",
    "Device settings applied: Save to keep them.": "Definições do dispositivo aplicadas: guarde para as manter.",
    "Close": "Fechar",
    "Display name": "Nome apresentado",
    "Its name in HomeKit; empty uses the device's name.": "O nome no HomeKit; se ficar vazio, é usado o do dispositivo.",
    "Serial number (optional)": "Número de série (opcional)",
    "Cancel": "Cancelar",
    "Apply": "Aplicar",
    "Saved. Restart Homeswift to apply the rest ({changes}).": "Guardado. Reinicie o Homeswift para aplicar o resto ({changes}).",
    "Saved. The plugin restarted with the new settings: its devices keep their place in the Home app.": "Guardado. O plugin reiniciou com as novas definições: os dispositivos mantêm o seu lugar na app Casa.",
    "Failed to save the configuration": "Não foi possível guardar a configuração",
    "Restarting…": "A reiniciar…",
    "Homeswift restarted with the new settings.": "O Homeswift reiniciou com as novas definições.",
    "LG ThinQ did not answer; try again later.": "O LG ThinQ não respondeu; tente novamente mais tarde.",
    "Invalid refreshToken: refreshToken must be a non-empty string.": "refreshToken inválido: não pode estar vazio.",
    "Your account was already used to registered in {0}.": "A sua conta já está registada em {0}.",
    "LG rejected the sign-in. If you sign in to LG with Google, Apple or Facebook, use a token instead.": "A LG recusou o início de sessão. Se inicia sessão na LG com Google, Apple ou Facebook, use um token.",
    "LG rejected the sign-in.": "A LG recusou o início de sessão.",
    "LG returned no account for this sign-in.": "A LG não devolveu nenhuma conta para este início de sessão.",
    "LG returned no authorization code.": "A LG não devolveu nenhum código de autorização.",
    "LG returned no redirect.": "A LG não devolveu nenhum redirecionamento.",
    "LG returned no access token for the refresh token.": "A LG não devolveu nenhum token de acesso para o token de atualização.",
    "LG returned no user number.": "A LG não devolveu nenhum número de utilizador.",
    "Could not read the terms signature from LG. Open the LG ThinQ app and accept the new terms.": "Não foi possível ler a assinatura dos termos da LG. Abra a app LG ThinQ e aceite os novos termos.",
    "Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift.": "Abra a app da LG e inicie sessão na sua conta para ver o que aconteceu: talvez haja novos termos para aceitar. Depois reinicie o Homeswift.",
    "Request failed with status code {0}": "O pedido falhou com o código {0}",
    "not signed in": "sem sessão iniciada",
    "Your LG account": "A sua conta LG",
    "Signed in with": "Sessão iniciada com",
    "Sign in to your LG account": "Inicie sessão na sua conta LG",
    "Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done.": "O Homeswift inicia sessão em Adicionar acessórios, com a página de início de sessão da LG (para contas LG, Google, Apple, Facebook ou Amazon) ou o e-mail e a palavra-passe da conta. Os eletrodomésticos aparecem aqui quando terminar.",
    "Email and password": "E-mail e palavra-passe",
    "LG's sign-in page": "A página de início de sessão da LG",
    "No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.": "Nenhum dispositivo encontrado. Adicione-os à sua conta LG na app LG ThinQ e prima Atualizar.",
    "This instance has no LG sign-in yet: sign in through Setup (Add accessories) first.": "Esta instância ainda não tem sessão LG: inicie sessão primeiro em Adicionar acessórios."
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LG ThinQ</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's settings page on the UI's materials: the LG account (step 1: its sign-in, which Setup
     does), pick the devices and their options (step 2, with a Settings tab for the sync), done (step 3). */

  .step { animation: materialize var(--normal) var(--ease-out); }
  .step-head { display: flex; align-items: center; gap: 12px; margin: 22px 0 12px; }
  .step-head h2 { margin: 0; }
  .step-number {
    width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; flex: none; font-weight: 600; font-variant-numeric: tabular-nums;
    background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text);
  }
  .step-number.done { background: linear-gradient(180deg, #4cd07d, #1f9d55); }
  .account { display: grid; gap: 12px; }
  .account .actions { margin: 0; }
  .problem { margin-top: 14px; }
  .problem .error { margin: 0; }

  .tabs { margin-bottom: 14px; }
  .list-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; margin-bottom: 10px; }
  .list-head h3 { margin: 0; }
  .list-head .count { margin-left: 6px; }
  .devices { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
  .device {
    display: flex; align-items: center; gap: 12px; padding: 10px 10px 10px 14px; border-radius: 14px; cursor: pointer;
    background: var(--material-thin); border: 1px solid var(--line); transition: background-color var(--fast) var(--ease-out), border-color var(--fast) var(--ease-out);
  }
  @media (hover: hover) and (pointer: fine) { .device:not(.selected):hover { border-color: var(--edge); } }
  .device.selected { background: var(--control); border-color: var(--edge); box-shadow: inset 0 1px 0 var(--edge-light), var(--shadow-control); }
  .device input[type="checkbox"] { width: 18px; height: 18px; margin: 0; flex: none; accent-color: var(--accent); }
  .device .who { flex: 1; min-width: 0; }
  .device strong { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .device .meta { font-size: 0.75rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .device .gear { flex: none; width: 34px; height: 34px; padding: 0; display: grid; place-items: center; font-size: 1.05rem; }
  .device .explain { flex: none; }
  .list-foot { margin: 10px 0 0; font-size: 0.8125rem; }
  .empty { text-align: center; padding: 22px; border-radius: 14px; border: 1px dashed var(--line); }

  .panel { margin-top: 14px; animation: materialize var(--normal) var(--ease-out); }
  .panel-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
  .panel-head h3 { margin: 0; }
  .columns { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 4px 18px; }
  .group-title { margin: 16px 0 0; font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
  .buttons-editor { margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--line); }
  .button-row { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
  .button-row input { flex: 1; max-width: 220px; }
  .button-row select { width: auto; }
  .panel .save-bar, .settings .save-bar { margin-top: 16px; }
  .settings .card { margin-bottom: 14px; }
  .settings h3 { margin: 0 0 6px; }
  .number { max-width: 140px; }
  .done-actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 14px; }

  .busy::after {
    content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
    border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) {
    .step, .panel { animation: none; }
    .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  }
  @media (max-width: 640px) {
    .columns { grid-template-columns: 1fr; }
    .device .meta .id { display: none; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="6" y="2.5" width="12" height="19" rx="2.5"/><path d="M10.5 18.5h3"/></svg></span>
    <div>
      <h1>LG ThinQ</h1>
      <p class="muted" data-i18n>Connect your LG account to manage its appliances in HomeKit.</p>
    </div>
  </div>

  <section id="step-account" class="step">
    <div class="step-head"><span class="step-number">1</span><h2 data-i18n>Your LG account</h2></div>
    <div id="account-setup"></div>
    <div id="account" class="card account hidden">
      <div class="facts">
        <div class="fact"><span data-i18n>Region</span><b id="account-region">—</b></div>
        <div class="fact"><span data-i18n>Signed in with</span><b id="account-mode">—</b></div>
        <div class="fact hidden" id="account-email-row"><span data-i18n>Email</span><b id="account-email"></b></div>
      </div>
      <div class="actions"><a id="sign-in-again" class="button" href="/setup?start" data-i18n data-action-icon="key">Sign in again</a></div>
    </div>
    <div id="account-problem" class="problem hidden"></div>
  </section>

  <section id="step-devices" class="step hidden">
    <div class="step-head"><span class="step-number">2</span><h2 data-i18n>Your devices</h2></div>
    <div class="group tabs" role="tablist">
      <button id="tab-devices" role="tab" class="on" aria-selected="true" aria-controls="pane-devices" data-i18n>Devices</button>
      <button id="tab-settings" role="tab" aria-selected="false" aria-controls="pane-settings" data-i18n data-action-icon="sliders">Settings</button>
    </div>

    <div id="pane-devices" role="tabpanel" aria-labelledby="tab-devices">
      <div class="card">
        <div class="list-head">
          <h3 data-i18n>Devices in your account <span id="device-count" class="pill count">0</span></h3>
          <div class="actions"><button id="select-all" data-i18n data-action-icon="check">Select all</button><button id="refresh" data-i18n data-action-icon="restore">Refresh</button></div>
        </div>
        <div id="devices-problem" class="problem hidden"></div>
        <ul id="device-list" class="devices"></ul>
        <p class="list-foot muted" data-i18n>Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.</p>
      </div>
      <div id="device-panel" class="card panel hidden"></div>
      <div class="save-bar"><span id="devices-status" class="muted"></span><button id="save" class="primary" data-i18n data-action-icon="check">Save configuration</button></div>
    </div>

    <div id="pane-settings" class="settings hidden" role="tabpanel" aria-labelledby="tab-settings">
      <div class="card">
        <h3 data-i18n>Sync</h3>
        <label class="toggle"><span class="switch"><input type="checkbox" id="thinq1"><span></span></span><span><span class="field-title" data-i18n>ThinQ1 support</span><span class="help" data-i18n>Adds the account's older ThinQ v1 devices, which are polled.</span></span></label>
        <label class="field"><span class="field-title" data-i18n>Refresh interval (seconds)</span><input type="number" id="refresh-interval" min="1" inputmode="numeric" class="number"><span class="help" data-i18n>How often ThinQ1 devices are polled. Default: 60.</span></label>
      </div>
      <div class="save-bar"><span class="muted" data-i18n>ThinQ2 devices are pushed by LG and need no polling.</span><button id="save-settings" class="primary" data-i18n data-action-icon="check">Save configuration</button></div>
    </div>
  </section>

  <section id="step-complete" class="step hidden">
    <div class="step-head"><span class="step-number done">✓</span><h2 data-i18n>Configuration saved</h2></div>
    <div class="card">
      <p id="complete-text" data-i18n>The plugin restarted with the new settings.</p>
      <div class="done-actions"><button id="restart" class="hidden" data-i18n data-action-icon="power">Restart Homeswift</button><button id="back" data-i18n data-action-icon="restore">Back to the devices</button></div>
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
