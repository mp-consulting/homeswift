// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension LGThinQPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The LG ThinQ page: the Homebridge plugin's settings wizard. Step 1 signs in to the LG account (or uses the
// refresh token of the block); step 2 lists the account's devices to pick for HomeKit, with each device's
// options, and the account and sync settings; saving writes this instance's block, which reloads the plugin.
(() => {
  "use strict";
  const { $, el, api, request, readBlock, updateBlock, explain, breadcrumb } = homeswift;
  const { t } = HomeswiftI18n;

  const DEFAULT_COUNTRY = "US";
  const DEFAULT_LANGUAGE = "en-US";
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

  // State: the block as saved, the session used to list devices, the devices and the choices on them.
  let config = {};
  let credentials = { refresh_token: null, country: null, language: null };
  let devices = [];
  let running = new Set();
  const selected = new Set();
  const deviceSettings = {};
  let activeDevice = null;

  const steps = { login: $("#step-login"), devices: $("#step-devices"), complete: $("#step-complete") };
  const showStep = (step) => Object.entries(steps).forEach(([key, node]) => node.classList.toggle("hidden", key !== step));

  /// Runs `work` with the button disabled and a spinner on it; errors reach the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Problems, with the Assistant's explanation when it is set up

  // What the Assistant may see: the region and modes, never the email, password, refresh token or device ids.
  const assistantContext = (extra) => [
    extra,
    `Auth mode: ${config.auth_mode || "token"}.`,
    `Account region: country ${credentials.country || config.country || DEFAULT_COUNTRY}, language ${credentials.language || config.language || DEFAULT_LANGUAGE}.`,
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

  // MARK: Step 1: sign in

  /// A sentence of the page with elements in it (a link, code): the translation's {0}, {1}… are the element's
  /// children, in order.
  function sentence(node, text) {
    const parts = [...node.children];
    node.replaceChildren(...text.split(/\{(\d+)\}/).map((part, i) => (i % 2 ? parts[Number(part)] : part)));
  }
  sentence($("#login-form .wiki"), t("Signing in to LG with Google, Apple, Facebook or Amazon? {0}, or use LG's own sign-in page below."));
  sentence($("#third-party .help"), t("Open LG's sign-in page, sign in, then paste the address of the page it ends on (it starts with the LG account site and contains {0})."));

  // In another language than English, a region is named in the page's language and its language by its own name
  // (Intl.DisplayNames), in that order; the Homebridge plugin's English labels are the fallback.
  const displayNames = (locale, type) => { try { return new Intl.DisplayNames([locale], { type }); } catch { return null; } };
  const regionNames = HomeswiftI18n.language === "en" ? null : displayNames(HomeswiftI18n.locale, "region");
  function regionLabel({ country, language, label }) {
    if (!regionNames) return label;
    try {
      const region = regionNames.of(country);
      const primary = language.split("-")[0];
      const speech = displayNames(primary, "language")?.of(primary);
      if (!region || region === country) return label;
      return `${region}/${speech && speech !== primary ? speech : label.slice(label.indexOf("/") + 1)}`;
    } catch { return label; }
  }
  const regions = window.LG_COUNTRIES.map((entry) => ({ ...entry, text: regionLabel(entry) }));
  if (regionNames) regions.sort((a, b) => a.text.localeCompare(b.text, HomeswiftI18n.locale));
  const countrySelect = $("#country-language");
  countrySelect.replaceChildren(...regions.map(({ country, language, text }) =>
    el("option", { value: `${country}|${language}`, text })));
  const selectedRegion = () => {
    const [country, language] = countrySelect.value.split("|");
    return { country, language };
  };
  function selectRegion(country, language) {
    const value = `${country}|${language}`;
    countrySelect.value = [...countrySelect.options].some((o) => o.value === value) ? value : `${DEFAULT_COUNTRY}|${DEFAULT_LANGUAGE}`;
  }

  function prefillLogin() {
    if (config.username) $("#username").value = config.username;
    if (config.password) $("#password").value = config.password;
    $("#remember").checked = !!(config.username && config.password);
    selectRegion(config.country || DEFAULT_COUNTRY, config.language || DEFAULT_LANGUAGE);
  }

  $("#switch-account").addEventListener("click", () => $("#new-login").click());
  $("#new-login").addEventListener("click", () => {
    $("#session-notice").classList.add("hidden");
    $("#login-form").classList.remove("hidden");
    $("#third-party").classList.remove("hidden");
    showStep("login");
  });

  $("#login-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const button = $("#login");
    if (button.disabled) return;
    const username = $("#username").value.trim();
    const password = $("#password").value;
    const { country, language } = selectedRegion();
    const problem = $("#login-problem");
    if (!username || !password) {
      showProblem(problem, t("Please enter your username and password."));
      return;
    }
    clearProblem(problem);
    act(button, async () => {
      try {
        const answer = await request("login-by-user-pass", { method: "POST", body: { country, language, username, password } });
        if (!answer.success) throw new Error(HomeswiftI18n.message(answer.error) || t("Login failed"));
        await connected(answer.token, country, language, { username, password });
      } catch (e) {
        showProblem(problem, e.message || t("Login failed"),
          `Signing in to the LG ThinQ cloud with an LG account email and password from the plugin settings failed. Selected region: ${country} / ${language}.`);
      }
    });
  });

  /// Signed in: the refresh token goes into the block (with the email and password when they are to be
  /// remembered), then the devices.
  async function connected(token, country, language, account) {
    credentials = { refresh_token: token, country, language };
    const next = { ...config, platform: "LGThinQ", name: config.name || "LG ThinQ", country, language, refresh_token: token, auth_mode: "token" };
    if (account && $("#remember").checked) {
      next.username = account.username;
      next.password = account.password;
    } else {
      delete next.username;
      delete next.password;
    }
    await updateBlock(() => next);
    config = next;
    prefillSettings();
    showStep("devices");
    await loadDevices();
  }

  // The `thinq auth` command of the Homebridge plugin: LG's own page for accounts of Google, Apple and others.
  $("#open-lg").addEventListener("click", (event) => act(event.currentTarget, async () => {
    const { country, language } = selectedRegion();
    const problem = $("#login-problem");
    clearProblem(problem);
    try {
      const { url } = await request(`login-url?country=${encodeURIComponent(country)}&language=${encodeURIComponent(language)}`);
      window.open(url, "_blank", "noopener");
    } catch (e) {
      showProblem(problem, e.message, "Opening LG's sign-in page for an account that signs in with Google, Apple, Facebook or Amazon failed.");
    }
  }));
  $("#redirect-login").addEventListener("click", (event) => act(event.currentTarget, async () => {
    const { country, language } = selectedRegion();
    const problem = $("#login-problem");
    clearProblem(problem);
    try {
      const answer = await request("login-by-redirect", { method: "POST", body: { url: $("#redirect-url").value.trim(), country, language } });
      if (!answer.success) throw new Error(HomeswiftI18n.message(answer.error) || t("Login failed"));
      await connected(answer.token, country, language, null);
    } catch (e) {
      showProblem(problem, e.message || t("Login failed"),
        `Signing in through LG's own page (an account of Google, Apple, Facebook or Amazon) failed. Selected region: ${country} / ${language}.`);
    }
  }));

  // MARK: Step 2: devices

  const list = $("#device-list");
  const typeOf = (device) => String(device.type || "Unknown");

  async function loadDevices() {
    const button = $("#refresh");
    const problem = $("#devices-problem");
    clearProblem(problem);
    await act(button, async () => {
      try {
        const answer = await request("get-all-devices", { method: "POST", body: credentials });
        if (!answer.success) throw new Error(HomeswiftI18n.message(answer.error) || t("Failed to load devices"));
        devices = answer.devices || [];
        if (selected.size === 0) devices.forEach((device) => selected.add(device.id));
        try {
          running = new Set(((await request("devices")).devices || []).map((device) => device.id));
        } catch { running = new Set(); }
        renderDevices();
      } catch (e) {
        showProblem(problem, e.message || t("Failed to load devices"),
          "Loading the device list from the LG ThinQ cloud with the stored refresh token failed in the plugin settings.");
      }
    });
  }

  function renderDevices() {
    $("#device-count").textContent = String(devices.length);
    $("#select-all").textContent = selected.size === devices.length && devices.length > 0 ? t("Deselect all") : t("Select all");
    if (!devices.length) {
      list.replaceChildren(el("li", { class: "empty muted", text: t("No devices found. Connect your LG account and press Refresh.") }));
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
        running.has(device.id) ? el("span", { class: "pill on", text: t("In HomeKit") }) : null,
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
          const row = el("div", { class: "button-row" }, label, mode, el("button", { class: "link danger", text: t("Remove"), onclick: () => row.remove() }));
          buttonsList.append(row);
        };
        (overrides.ac_buttons || []).forEach(addButton);
        typeSection.push(el("div", { class: "buttons-editor" },
          el("div", { class: "list-head" }, el("h3", { class: "group-title", text: t("AC buttons") }), el("button", { text: t("Add button"), onclick: () => addButton() })),
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
      el("div", { class: "panel-head" }, el("h3", { text: overrides.name || device.name }), el("button", { class: "link", text: t("Close"), onclick: closeDevice })),
      el("div", { class: "columns" },
        fieldRow(t("Display name"), nameInput, t("Its name in HomeKit; empty uses the device's name.")),
        fieldRow(t("Serial number (optional)"), serialInput)),
      typeSection,
      el("div", { class: "save-bar" }, el("span", { class: "muted", text: "" }), el("button", { text: t("Cancel"), onclick: closeDevice }), el("button", { class: "primary", text: t("Apply"), onclick: apply })));
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
        const next = {
          ...config, platform: "LGThinQ", name: config.name || "LG ThinQ",
          country: $("#country").value.trim() || config.country || DEFAULT_COUNTRY,
          language: $("#language").value.trim() || config.language || DEFAULT_LANGUAGE,
          refresh_token: credentials.refresh_token || config.refresh_token,
          auth_mode: config.auth_mode || "token",
          refresh_interval: parseInt($("#refresh-interval").value, 10) || DEFAULT_REFRESH_INTERVAL,
          devices: selectedDevicesConfig(),
        };
        if (!next.refresh_token) delete next.refresh_token;
        if (!next.thinq1) delete next.thinq1;
        if ($("#remember").checked && $("#username").value.trim()) {
          next.username = $("#username").value.trim();
          next.password = $("#password").value;
        } else if (!$("#remember").checked) {
          delete next.username;
          delete next.password;
        }
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
    const mode = config.auth_mode || "token";
    $("#auth-mode").value = mode;
    $("#refresh-token").value = config.refresh_token || "";
    $("#country").value = config.country || DEFAULT_COUNTRY;
    $("#language").value = config.language || DEFAULT_LANGUAGE;
    $("#refresh-interval").value = config.refresh_interval || DEFAULT_REFRESH_INTERVAL;
    $("#thinq1").checked = !!config.thinq1;
    $("#token-field").classList.toggle("hidden", mode !== "token");
  }

  $("#auth-mode").addEventListener("change", () => $("#token-field").classList.toggle("hidden", $("#auth-mode").value !== "token"));
  $("#save-settings").addEventListener("click", (event) => {
    config.auth_mode = $("#auth-mode").value;
    config.refresh_token = $("#refresh-token").value.trim() || config.refresh_token;
    config.country = $("#country").value.trim() || DEFAULT_COUNTRY;
    config.language = $("#language").value.trim() || DEFAULT_LANGUAGE;
    config.refresh_interval = parseInt($("#refresh-interval").value, 10) || DEFAULT_REFRESH_INTERVAL;
    config.thinq1 = $("#thinq1").checked || undefined;
    if (config.auth_mode === "token") credentials.refresh_token = config.refresh_token;
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

  countrySelect.addEventListener("change", () => {
    const { country, language } = selectedRegion();
    config.country = country;
    config.language = language;
  });

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

  // MARK: Start: the block, then its session if it has one

  (async () => {
    try {
      config = (await readBlock()) || {};
    } catch (e) {
      showProblem($("#login-problem"), e.message);
    }
    for (const device of config.devices || []) {
      selected.add(device.id);
      deviceSettings[device.id] = { ...device };
    }
    prefillLogin();
    prefillSettings();
    if (config.refresh_token) {
      credentials = { refresh_token: config.refresh_token, country: config.country || DEFAULT_COUNTRY, language: config.language || DEFAULT_LANGUAGE };
      $("#session-notice").classList.remove("hidden");
      $("#login-form").classList.add("hidden");
      $("#third-party").classList.add("hidden");
      showStep("devices");
      await loadDevices();
    } else {
      showStep("login");
    }
  })();
})();

"""#),
        "countries.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The LG account regions of the Homebridge plugin's settings page: country, language and their label.
window.LG_COUNTRIES = [
  { country: 'AE', language: 'ar-AE', label: 'United Arab Emirates/العربية' },
  { country: 'AE', language: 'en-AE', label: 'United Arab Emirates/English' },
  { country: 'AG', language: 'en-AG', label: 'Antigua and Barbuda/English' },
  { country: 'AL', language: 'en-AL', label: 'Albania/English' },
  { country: 'AL', language: 'sq-AL', label: 'Albania/Shqip' },
  { country: 'AM', language: 'en-AM', label: 'Armenia/English' },
  { country: 'AM', language: 'fr-AM', label: 'Armenia/français' },
  { country: 'AO', language: 'en-AO', label: 'Angola/English' },
  { country: 'AR', language: 'es-AR', label: 'Argentina/Spanish' },
  { country: 'AT', language: 'de-AT', label: 'Austria/Deutsch' },
  { country: 'AT', language: 'en-AT', label: 'Austria/English' },
  { country: 'AU', language: 'en-AU', label: 'Australia/English' },
  { country: 'AZ', language: 'en-AZ', label: 'Azerbaijan/English' },
  { country: 'BA', language: 'hr-BA', label: 'Bosnia/Hrvatski' },
  { country: 'BA', language: 'sr-BA', label: 'Bosnia/Srpski' },
  { country: 'BB', language: 'en-BB', label: 'Barbados/English' },
  { country: 'BD', language: 'en-BD', label: 'Bangladesh/English' },
  { country: 'BE', language: 'en-BE', label: 'Belgium/English' },
  { country: 'BE', language: 'fr-BE', label: 'Belgium/français' },
  { country: 'BE', language: 'nl-BE', label: 'Belgium/Nederlands' },
  { country: 'BF', language: 'fr-BF', label: 'Burkina Faso/français' },
  { country: 'BG', language: 'bg-BG', label: 'Bulgaria/Български' },
  { country: 'BG', language: 'en-BG', label: 'Bulgaria/English' },
  { country: 'BH', language: 'ar-BH', label: 'Bahrain/العربية' },
  { country: 'BH', language: 'en-BH', label: 'Bahrain/English' },
  { country: 'BJ', language: 'fr-BJ', label: 'Benin/français' },
  { country: 'BO', language: 'es-BO', label: 'Bolivia/Spanish' },
  { country: 'BR', language: 'pt-BR', label: 'Brazil/Português' },
  { country: 'BS', language: 'en-BS', label: 'Bahamas/English' },
  { country: 'BY', language: 'ru-BY', label: 'Belarus/Русский' },
  { country: 'BZ', language: 'en-BZ', label: 'Belize/English' },
  { country: 'CA', language: 'en-CA', label: 'Canada/English' },
  { country: 'CA', language: 'fr-CA', label: 'Canada/français' },
  { country: 'CD', language: 'fr-CD', label: 'DR Congo/français' },
  { country: 'CF', language: 'fr-CF', label: 'Central African Republic/français' },
  { country: 'CG', language: 'fr-CG', label: 'Congo Brazzaville/français' },
  { country: 'CH', language: 'de-CH', label: 'Switzerland/Deutsch' },
  { country: 'CH', language: 'en-CH', label: 'Switzerland/English' },
  { country: 'CH', language: 'fr-CH', label: 'Switzerland/français' },
  { country: 'CI', language: 'fr-CI', label: 'Cote dKIvoire(Republic of Ivory Coast)/français' },
  { country: 'CL', language: 'en-CL', label: 'Chile/English' },
  { country: 'CL', language: 'es-CL', label: 'Chile/Spanish' },
  { country: 'CM', language: 'fr-CM', label: 'Cameroon/français' },
  { country: 'CN', language: 'en-CN', label: 'China/English' },
  { country: 'CN', language: 'zh-CN', label: 'China/中国语' },
  { country: 'CO', language: 'en-CO', label: 'Colombia/English' },
  { country: 'CO', language: 'es-CO', label: 'Colombia/Spanish' },
  { country: 'CR', language: 'es-CR', label: 'Costa Rica/Spanish' },
  { country: 'CU', language: 'es-CU', label: 'Cuba/Spanish' },
  { country: 'CV', language: 'pt-CV', label: 'Cape Verde/Português' },
  { country: 'CY', language: 'el-CY', label: 'Cyprus/Ελληνικά' },
  { country: 'CY', language: 'en-CY', label: 'Cyprus/English' },
  { country: 'CZ', language: 'cs-CZ', label: 'Czech Republic/Česky' },
  { country: 'CZ', language: 'en-CZ', label: 'Czech Republic/English' },
  { country: 'DE', language: 'de-DE', label: 'Germany/Deutsch' },
  { country: 'DE', language: 'en-DE', label: 'Germany/English' },
  { country: 'DJ', language: 'fr-DJ', label: 'Djibouti/francais' },
  { country: 'DK', language: 'da-DK', label: 'Denmark/Dansk' },
  { country: 'DK', language: 'en-DK', label: 'Denmark/English' },
  { country: 'DM', language: 'en-DM', label: 'Dominica/English' },
  { country: 'DO', language: 'es-DO', label: 'Dominican Rep./Spanish' },
  { country: 'DZ', language: 'ar-DZ', label: 'Algeria/العربية' },
  { country: 'DZ', language: 'en-DZ', label: 'Algeria/English' },
  { country: 'DZ', language: 'fr-DZ', label: 'Algeria/francais' },
  { country: 'EC', language: 'en-EC', label: 'Ecuador/English' },
  { country: 'EC', language: 'es-EC', label: 'Ecuador/Spanish' },
  { country: 'EE', language: 'en-EE', label: 'Estonia/English' },
  { country: 'EE', language: 'et-EE', label: 'Estonia/Eesti' },
  { country: 'EE', language: 'ru-EE', label: 'Estonia/Русский' },
  { country: 'EG', language: 'ar-EG', label: 'Egypt/العربية' },
  { country: 'EG', language: 'en-EG', label: 'Egypt/English' },
  { country: 'ES', language: 'en-ES', label: 'Spain/English' },
  { country: 'ES', language: 'es-ES', label: 'Spain/Spanish' },
  { country: 'ET', language: 'en-ET', label: 'Ethiopia/English' },
  { country: 'FI', language: 'en-FI', label: 'Finland/English' },
  { country: 'FI', language: 'fi-FI', label: 'Finland/Suomi' },
  { country: 'FR', language: 'fr-FR', label: 'France/français' },
  { country: 'GA', language: 'fr-GA', label: 'Gabon/français' },
  { country: 'GB', language: 'en-GB', label: 'UK/English' },
  { country: 'GD', language: 'en-GD', label: 'Grenada/English' },
  { country: 'GE', language: 'en-GE', label: 'Georgia/English' },
  { country: 'GH', language: 'en-GH', label: 'Ghana/English' },
  { country: 'GM', language: 'en-GM', label: 'Gambia/English' },
  { country: 'GN', language: 'fr-GN', label: 'Guinea Conakry/français' },
  { country: 'GQ', language: 'es-GQ', label: 'Guinea Equatorial/Spanish' },
  { country: 'GQ', language: 'fr-GQ', label: 'Guinea Equatorial/français' },
  { country: 'GR', language: 'el-GR', label: 'Greece/Ελληνικά' },
  { country: 'GR', language: 'en-GR', label: 'Greece/English' },
  { country: 'GT', language: 'es-GT', label: 'Guatemala/Spanish' },
  { country: 'GY', language: 'en-GY', label: 'Guyana/English' },
  { country: 'HK', language: 'en-HK', label: 'Hong Kong/English' },
  { country: 'HK', language: 'zh-HK', label: 'Hong Kong/中国语' },
  { country: 'HN', language: 'es-HN', label: 'Honduras/Spanish' },
  { country: 'HR', language: 'en-HR', label: 'Croatia/English' },
  { country: 'HR', language: 'hr-HR', label: 'Croatia/Hrvatski' },
  { country: 'HT', language: 'fr-HT', label: 'Haiti/français' },
  { country: 'HU', language: 'en-HU', label: 'Hungary/English' },
  { country: 'HU', language: 'hu-HU', label: 'Hungary/magyar' },
  { country: 'ID', language: 'en-ID', label: 'Indonesia/English' },
  { country: 'ID', language: 'id-ID', label: 'Indonesia/Bahasa Indonesia' },
  { country: 'IE', language: 'en-IE', label: 'Ireland/English' },
  { country: 'IL', language: 'en-IL', label: 'Israel/English' },
  { country: 'IN', language: 'en-IN', label: 'India/English' },
  { country: 'IQ', language: 'ar-IQ', label: 'Iraq/العربية' },
  { country: 'IQ', language: 'en-IQ', label: 'Iraq/English' },
  { country: 'IR', language: 'en-IR', label: 'Iran/English' },
  { country: 'IS', language: 'en-IS', label: 'Iceland/English' },
  { country: 'IT', language: 'en-IT', label: 'Italy/English' },
  { country: 'IT', language: 'it-IT', label: 'Italy/Italiano' },
  { country: 'JM', language: 'en-JM', label: 'Jamaica/English' },
  { country: 'JO', language: 'ar-JO', label: 'Jordan/العربية' },
  { country: 'JO', language: 'en-JO', label: 'Jordan/English' },
  { country: 'JP', language: 'ja-JP', label: 'Japan/日本語' },
  { country: 'KE', language: 'en-KE', label: 'Kenya/English' },
  { country: 'KG', language: 'ru-KG', label: 'Kyrgyzstan/Русский' },
  { country: 'KH', language: 'en-KH', label: 'Cambodia/English' },
  { country: 'KN', language: 'en-KN', label: 'Saint Kitts and Nevis/English' },
  { country: 'KR', language: 'ko-KR', label: 'Korea/한국어' },
  { country: 'KW', language: 'ar-KW', label: 'Kuwait/العربية' },
  { country: 'KW', language: 'en-KW', label: 'Kuwait/English' },
  { country: 'KZ', language: 'en-KZ', label: 'Kazakhstan/English' },
  { country: 'KZ', language: 'kk-KZ', label: 'Kazakhstan/Kazakh' },
  { country: 'KZ', language: 'ru-KZ', label: 'Kazakhstan/Русский' },
  { country: 'LB', language: 'ar-LB', label: 'Lebanon/العربية' },
  { country: 'LB', language: 'en-LB', label: 'Lebanon/English' },
  { country: 'LC', language: 'en-LC', label: 'Saint Lucia/English' },
  { country: 'LK', language: 'en-LK', label: 'Sri Lanka/English' },
  { country: 'LR', language: 'en-LR', label: 'Liberia/English' },
  { country: 'LT', language: 'en-LT', label: 'Lithuania/English' },
  { country: 'LT', language: 'lt-LT', label: 'Lithuania/Lietuvių' },
  { country: 'LU', language: 'de-LU', label: 'Luxemburg/Deutsch' },
  { country: 'LU', language: 'en-LU', label: 'Luxemburg/English' },
  { country: 'LU', language: 'fr-LU', label: 'Luxemburg/français' },
  { country: 'LV', language: 'en-LV', label: 'Latvia/English' },
  { country: 'LV', language: 'lv-LV', label: 'Latvia/Latviešu' },
  { country: 'LY', language: 'ar-LY', label: 'Libya/العربية' },
  { country: 'LY', language: 'en-LY', label: 'Libya/English' },
  { country: 'MA', language: 'ar-MA', label: 'Morocco/العربية' },
  { country: 'MA', language: 'en-MA', label: 'Morocco/English' },
  { country: 'MA', language: 'fr-MA', label: 'Morocco/français' },
  { country: 'MD', language: 'ro-MD', label: 'Moldova/Română' },
  { country: 'MD', language: 'ru-MD', label: 'Moldova/Русский' },
  { country: 'ME', language: 'en-ME', label: 'Montenegro/English' },
  { country: 'ME', language: 'sr-ME', label: 'Montenegro/Srpski' },
  { country: 'MK', language: 'en-MK', label: 'Macedonia/English' },
  { country: 'MK', language: 'mk-MK', label: 'Macedonia/Македонски' },
  { country: 'ML', language: 'fr-ML', label: 'Mali/français' },
  { country: 'MM', language: 'en-MM', label: 'Myanmar (Burma)/English' },
  { country: 'MT', language: 'en-MT', label: 'Malta/English' },
  { country: 'MU', language: 'en-MU', label: 'Mauritius/English' },
  { country: 'MX', language: 'en-MX', label: 'Mexico/English' },
  { country: 'MX', language: 'es-MX', label: 'Mexico/Spanish' },
  { country: 'MY', language: 'en-MY', label: 'Malaysia/English' },
  { country: 'NE', language: 'fr-NE', label: 'Niger/français' },
  { country: 'NG', language: 'en-NG', label: 'Nigeria/English' },
  { country: 'NI', language: 'es-NI', label: 'Nicaragua/Spanish' },
  { country: 'NL', language: 'en-NL', label: 'Netherlands/English' },
  { country: 'NL', language: 'nl-NL', label: 'Netherlands/Nederlands' },
  { country: 'NO', language: 'en-NO', label: 'Norway/English' },
  { country: 'NO', language: 'no-NO', label: 'Norway/Norsk' },
  { country: 'NZ', language: 'en-NZ', label: 'New Zealand/English' },
  { country: 'OM', language: 'ar-OM', label: 'Oman/العربية' },
  { country: 'OM', language: 'en-OM', label: 'Oman/English' },
  { country: 'PA', language: 'en-PA', label: 'Panama/English' },
  { country: 'PA', language: 'es-PA', label: 'Panama/Spanish' },
  { country: 'PE', language: 'en-PE', label: 'Peru/English' },
  { country: 'PE', language: 'es-PE', label: 'Peru/Spanish' },
  { country: 'PH', language: 'en-PH', label: 'Philippines/English' },
  { country: 'PK', language: 'en-PK', label: 'Pakistan/English' },
  { country: 'PL', language: 'en-PL', label: 'Poland/English' },
  { country: 'PL', language: 'pl-PL', label: 'Poland/Polski' },
  { country: 'PR', language: 'es-PR', label: 'Puerto Rico/Spanish' },
  { country: 'PS', language: 'en-PS', label: 'Palestine/English' },
  { country: 'PT', language: 'en-PT', label: 'Portugal/English' },
  { country: 'PT', language: 'pt-PT', label: 'Portugal/Português' },
  { country: 'PY', language: 'es-PY', label: 'Paraguay/Spanish' },
  { country: 'QA', language: 'ar-QA', label: 'Qatar/العربية' },
  { country: 'QA', language: 'en-QA', label: 'Qatar/English' },
  { country: 'RO', language: 'en-RO', label: 'Romania/English' },
  { country: 'RO', language: 'ro-RO', label: 'Romania/Română' },
  { country: 'RS', language: 'en-RS', label: 'Serbia/English' },
  { country: 'RS', language: 'sr-RS', label: 'Serbia/Srpski' },
  { country: 'RU', language: 'ru-RU', label: 'Russia/Русский' },
  { country: 'RW', language: 'fr-RW', label: 'Rwanda/français' },
  { country: 'SA', language: 'ar-SA', label: 'Saudi arabia/العربية' },
  { country: 'SA', language: 'en-SA', label: 'Saudi arabia/English' },
  { country: 'SD', language: 'en-SD', label: 'Sudan/English' },
  { country: 'SE', language: 'en-SE', label: 'Sweden/English' },
  { country: 'SE', language: 'sv-SE', label: 'Sweden/Svenska' },
  { country: 'SG', language: 'en-SG', label: 'Singapore/English' },
  { country: 'SI', language: 'en-SI', label: 'Slovenia/English' },
  { country: 'SI', language: 'sl-SI', label: 'Slovenia/Slovenščina' },
  { country: 'SK', language: 'en-SK', label: 'Slovakia/English' },
  { country: 'SK', language: 'sk-SK', label: 'Slovakia/Slovenčina' },
  { country: 'SL', language: 'en-SL', label: 'Sierra Leone/English' },
  { country: 'SN', language: 'fr-SN', label: 'Senegal/français' },
  { country: 'SO', language: 'en-SO', label: 'Somalia/English' },
  { country: 'SR', language: 'nl-SR', label: 'Republic of Suriname/Nederlands' },
  { country: 'ST', language: 'pt-ST', label: 'Sao Tome and Principe/Português' },
  { country: 'SV', language: 'es-SV', label: 'El salvador/Spanish' },
  { country: 'SY', language: 'ar-SY', label: 'Syria/العربية' },
  { country: 'SY', language: 'en-SY', label: 'Syria/English' },
  { country: 'TD', language: 'fr-TD', label: 'Chad/français' },
  { country: 'TG', language: 'fr-TG', label: 'Togo/français' },
  { country: 'TH', language: 'en-TH', label: 'Thailand/English' },
  { country: 'TH', language: 'th-TH', label: 'Thailand/ไทย' },
  { country: 'TN', language: 'ar-TN', label: 'Tunisia/العربية' },
  { country: 'TN', language: 'en-TN', label: 'Tunisia/English' },
  { country: 'TR', language: 'en-TR', label: 'Turkey/English' },
  { country: 'TR', language: 'tr-TR', label: 'Turkey/Türkçe' },
  { country: 'TT', language: 'en-TT', label: 'Trinidad/English' },
  { country: 'TW', language: 'en-TW', label: 'Taiwan/English' },
  { country: 'TW', language: 'zh-TW', label: 'Taiwan/繁體中文' },
  { country: 'TZ', language: 'en-TZ', label: 'Tanzania/English' },
  { country: 'UA', language: 'ru-UA', label: 'Ukraine/Русский' },
  { country: 'UA', language: 'uk-UA', label: 'Ukraine/Українська мова' },
  { country: 'UG', language: 'en-UG', label: 'Uganda/English' },
  { country: 'US', language: 'en-US', label: 'USA/English' },
  { country: 'UY', language: 'es-UY', label: 'Uruguay/Spanish' },
  { country: 'UZ', language: 'en-UZ', label: 'Uzbekistan/English' },
  { country: 'UZ', language: 'ru-UZ', label: 'Uzbekistan/Русский' },
  { country: 'UZ', language: 'uz-UZ', label: "Uzbekistan/O'zbek tili" },
  { country: 'VC', language: 'en-VC', label: 'Saint Vincent/English' },
  { country: 'VE', language: 'es-VE', label: 'Venezuela/Spanish' },
  { country: 'VN', language: 'en-VN', label: 'Vietnam/English' },
  { country: 'VN', language: 'vi-VN', label: 'Vietnam/Tiếng Việt' },
  { country: 'XK', language: 'en-XK', label: 'Kosovo/English' },
  { country: 'YE', language: 'ar-YE', label: 'Yemen/العربية' },
  { country: 'YE', language: 'en-YE', label: 'Yemen/English' },
  { country: 'ZA', language: 'en-ZA', label: 'South Africa/English' },
  { country: 'ZM', language: 'en-ZM', label: 'Zambia/English' },
];

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The LG ThinQ page's strings and the plugin's errors in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Connect your LG account to manage its appliances in HomeKit.": "Connectez votre compte LG pour gérer ses appareils dans HomeKit.",
    "Connect your LG account": "Connectez votre compte LG",
    "Active session": "Session active",
    "Using the refresh token saved in this plugin's settings.": "Le jeton d'actualisation enregistré dans les réglages de ce plugin est utilisé.",
    "Sign in with another account": "Se connecter avec un autre compte",
    "Country / language": "Pays / langue",
    "The region of your LG account.": "La région de votre compte LG.",
    "Email": "E-mail",
    "Your LG ThinQ account's email.": "L'adresse e-mail de votre compte LG ThinQ.",
    "Password": "Mot de passe",
    "Remember the email and password": "Mémoriser l'e-mail et le mot de passe",
    "Optional: the sign-in keeps only a refresh token otherwise.": "Facultatif : sinon, la connexion ne garde qu'un jeton d'actualisation.",
    "Connect account": "Connecter le compte",
    "Signing in to LG with Google, Apple, Facebook or Amazon? {0}, or use LG's own sign-in page below.": "Vous vous connectez à LG avec Google, Apple, Facebook ou Amazon ? {0}, ou utilisez la page de connexion de LG ci-dessous.",
    "See the authorization guide": "Consultez le guide d'autorisation",
    "Sign in with Google, Apple, Facebook or Amazon": "Se connecter avec Google, Apple, Facebook ou Amazon",
    "Open LG's sign-in page, sign in, then paste the address of the page it ends on (it starts with the LG account site and contains {0}).": "Ouvrez la page de connexion de LG, connectez-vous, puis collez l'adresse de la page sur laquelle vous arrivez (elle commence par le site du compte LG et contient {0}).",
    "Open LG's sign-in page": "Ouvrir la page de connexion de LG",
    "Address after signing in": "Adresse après la connexion",
    "Use this sign-in": "Utiliser cette connexion",
    "Your devices": "Vos appareils",
    "Devices": "Appareils",
    "Settings": "Réglages",
    "Devices in your account": "Appareils de votre compte",
    "Select all": "Tout sélectionner",
    "Deselect all": "Tout désélectionner",
    "Refresh": "Actualiser",
    "Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.": "Les appareils cochés sont ajoutés à HomeKit (aucun coché : tous). ⚙ règle les options d'un appareil.",
    "Save configuration": "Enregistrer la configuration",
    "Authentication": "Authentification",
    "Auth mode": "Mode d'authentification",
    "LG account (email and password)": "Compte LG (e-mail et mot de passe)",
    "Refresh token": "Jeton d'actualisation",
    "Paste your refresh token": "Collez votre jeton d'actualisation",
    "Region": "Région",
    "Country": "Pays",
    "Language": "Langue",
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
    "Please enter your username and password.": "Saisissez votre nom d'utilisateur et votre mot de passe.",
    "Login failed": "Échec de la connexion",
    "Failed to load devices": "Impossible de charger les appareils",
    "No devices found. Connect your LG account and press Refresh.": "Aucun appareil trouvé. Connectez votre compte LG et appuyez sur Actualiser.",
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
    "Failed to get devices": "Impossible d'obtenir les appareils",
    "Cannot reach LG": "Impossible de joindre LG",
    "This instance has no LG sign-in yet: sign in on the LG ThinQ plugin page first.": "Cette instance n'a pas encore de connexion LG : connectez-vous d'abord sur la page du plugin LG ThinQ.",
    "LG ThinQ did not answer; try again later.": "LG ThinQ n'a pas répondu ; réessayez plus tard.",
    "Missing required fields: {0}": "Champs obligatoires manquants : {0}",
    "LG returned no sign-in page": "LG n'a renvoyé aucune page de connexion",
    "That is not a URL.": "Ce n'est pas une URL.",
    "The redirected URL is not valid: try again, or use an LG account.": "L'URL de redirection n'est pas valide : réessayez, ou utilisez un compte LG.",
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
    "not signed in": "non connecté"
  },
  "es": {
    "Connect your LG account to manage its appliances in HomeKit.": "Conecta tu cuenta de LG para gestionar sus electrodomésticos en HomeKit.",
    "Connect your LG account": "Conecta tu cuenta de LG",
    "Active session": "Sesión activa",
    "Using the refresh token saved in this plugin's settings.": "Se usa el token de actualización guardado en los ajustes de este plugin.",
    "Sign in with another account": "Iniciar sesión con otra cuenta",
    "Country / language": "País / idioma",
    "The region of your LG account.": "La región de tu cuenta de LG.",
    "Email": "Correo electrónico",
    "Your LG ThinQ account's email.": "El correo de tu cuenta de LG ThinQ.",
    "Password": "Contraseña",
    "Remember the email and password": "Recordar el correo y la contraseña",
    "Optional: the sign-in keeps only a refresh token otherwise.": "Opcional: si no, el inicio de sesión solo guarda un token de actualización.",
    "Connect account": "Conectar cuenta",
    "Signing in to LG with Google, Apple, Facebook or Amazon? {0}, or use LG's own sign-in page below.": "¿Inicias sesión en LG con Google, Apple, Facebook o Amazon? {0}, o usa la página de inicio de sesión de LG más abajo.",
    "See the authorization guide": "Consulta la guía de autorización",
    "Sign in with Google, Apple, Facebook or Amazon": "Iniciar sesión con Google, Apple, Facebook o Amazon",
    "Open LG's sign-in page, sign in, then paste the address of the page it ends on (it starts with the LG account site and contains {0}).": "Abre la página de inicio de sesión de LG, inicia sesión y pega la dirección de la página en la que terminas (empieza por el sitio de la cuenta de LG y contiene {0}).",
    "Open LG's sign-in page": "Abrir la página de inicio de sesión de LG",
    "Address after signing in": "Dirección tras iniciar sesión",
    "Use this sign-in": "Usar este inicio de sesión",
    "Your devices": "Tus dispositivos",
    "Devices": "Dispositivos",
    "Settings": "Ajustes",
    "Devices in your account": "Dispositivos de tu cuenta",
    "Select all": "Seleccionar todo",
    "Deselect all": "Deseleccionar todo",
    "Refresh": "Actualizar",
    "Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.": "Los dispositivos marcados se añaden a HomeKit (ninguno marcado: todos). ⚙ ajusta las opciones de un dispositivo.",
    "Save configuration": "Guardar configuración",
    "Authentication": "Autenticación",
    "Auth mode": "Modo de autenticación",
    "LG account (email and password)": "Cuenta de LG (correo y contraseña)",
    "Refresh token": "Token de actualización",
    "Paste your refresh token": "Pega tu token de actualización",
    "Region": "Región",
    "Country": "País",
    "Language": "Idioma",
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
    "Please enter your username and password.": "Introduce tu nombre de usuario y tu contraseña.",
    "Login failed": "Error al iniciar sesión",
    "Failed to load devices": "No se han podido cargar los dispositivos",
    "No devices found. Connect your LG account and press Refresh.": "No se han encontrado dispositivos. Conecta tu cuenta de LG y pulsa Actualizar.",
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
    "Failed to get devices": "No se han podido obtener los dispositivos",
    "Cannot reach LG": "No se puede contactar con LG",
    "This instance has no LG sign-in yet: sign in on the LG ThinQ plugin page first.": "Esta instancia aún no ha iniciado sesión en LG: inicia sesión primero en la página del plugin LG ThinQ.",
    "LG ThinQ did not answer; try again later.": "LG ThinQ no ha respondido; vuelve a intentarlo más tarde.",
    "Missing required fields: {0}": "Faltan campos obligatorios: {0}",
    "LG returned no sign-in page": "LG no ha devuelto ninguna página de inicio de sesión",
    "That is not a URL.": "Eso no es una URL.",
    "The redirected URL is not valid: try again, or use an LG account.": "La URL de redirección no es válida: vuelve a intentarlo o usa una cuenta de LG.",
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
    "not signed in": "sin sesión iniciada"
  },
  "pt": {
    "Connect your LG account to manage its appliances in HomeKit.": "Ligue a sua conta LG para gerir os eletrodomésticos no HomeKit.",
    "Connect your LG account": "Ligue a sua conta LG",
    "Active session": "Sessão ativa",
    "Using the refresh token saved in this plugin's settings.": "É usado o token de atualização guardado nas definições deste plugin.",
    "Sign in with another account": "Iniciar sessão com outra conta",
    "Country / language": "País / idioma",
    "The region of your LG account.": "A região da sua conta LG.",
    "Email": "E-mail",
    "Your LG ThinQ account's email.": "O e-mail da sua conta LG ThinQ.",
    "Password": "Palavra-passe",
    "Remember the email and password": "Memorizar o e-mail e a palavra-passe",
    "Optional: the sign-in keeps only a refresh token otherwise.": "Opcional: caso contrário, o início de sessão guarda apenas um token de atualização.",
    "Connect account": "Ligar conta",
    "Signing in to LG with Google, Apple, Facebook or Amazon? {0}, or use LG's own sign-in page below.": "Início de sessão na LG com Google, Apple, Facebook ou Amazon? {0}, ou use a página de início de sessão da LG abaixo.",
    "See the authorization guide": "Consulte o guia de autorização",
    "Sign in with Google, Apple, Facebook or Amazon": "Iniciar sessão com Google, Apple, Facebook ou Amazon",
    "Open LG's sign-in page, sign in, then paste the address of the page it ends on (it starts with the LG account site and contains {0}).": "Abra a página de início de sessão da LG, inicie sessão e cole o endereço da página onde termina (começa pelo site da conta LG e contém {0}).",
    "Open LG's sign-in page": "Abrir a página de início de sessão da LG",
    "Address after signing in": "Endereço após iniciar sessão",
    "Use this sign-in": "Usar este início de sessão",
    "Your devices": "Os seus dispositivos",
    "Devices": "Dispositivos",
    "Settings": "Definições",
    "Devices in your account": "Dispositivos da sua conta",
    "Select all": "Selecionar tudo",
    "Deselect all": "Desmarcar tudo",
    "Refresh": "Atualizar",
    "Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.": "Os dispositivos assinalados são adicionados ao HomeKit (nenhum assinalado: todos). ⚙ define as opções de um dispositivo.",
    "Save configuration": "Guardar configuração",
    "Authentication": "Autenticação",
    "Auth mode": "Modo de autenticação",
    "LG account (email and password)": "Conta LG (e-mail e palavra-passe)",
    "Refresh token": "Token de atualização",
    "Paste your refresh token": "Cole o token de atualização",
    "Region": "Região",
    "Country": "País",
    "Language": "Idioma",
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
    "Please enter your username and password.": "Introduza o nome de utilizador e a palavra-passe.",
    "Login failed": "Falha ao iniciar sessão",
    "Failed to load devices": "Não foi possível carregar os dispositivos",
    "No devices found. Connect your LG account and press Refresh.": "Nenhum dispositivo encontrado. Ligue a sua conta LG e prima Atualizar.",
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
    "Failed to get devices": "Não foi possível obter os dispositivos",
    "Cannot reach LG": "Não é possível contactar a LG",
    "This instance has no LG sign-in yet: sign in on the LG ThinQ plugin page first.": "Esta instância ainda não tem sessão LG: inicie sessão primeiro na página do plugin LG ThinQ.",
    "LG ThinQ did not answer; try again later.": "O LG ThinQ não respondeu; tente novamente mais tarde.",
    "Missing required fields: {0}": "Faltam campos obrigatórios: {0}",
    "LG returned no sign-in page": "A LG não devolveu nenhuma página de início de sessão",
    "That is not a URL.": "Isso não é um URL.",
    "The redirected URL is not valid: try again, or use an LG account.": "O URL de redirecionamento não é válido: tente novamente ou use uma conta LG.",
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
    "not signed in": "sem sessão iniciada"
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
  /* The Homebridge plugin's settings page on the UI's materials: sign in to the LG account (step 1), pick the
     devices and their options (step 2, with a Settings tab for the account and sync), done (step 3). */

  .step { animation: materialize var(--normal) var(--ease-out); }
  .step-head { display: flex; align-items: center; gap: 12px; margin: 22px 0 12px; }
  .step-head h2 { margin: 0; }
  .step-number {
    width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; flex: none; font-weight: 600; font-variant-numeric: tabular-nums;
    background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text);
  }
  .step-number.done { background: linear-gradient(180deg, #4cd07d, #1f9d55); }
  .notice { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin-bottom: 14px; }
  .notice p { margin: 2px 0 0; }
  .form { display: grid; gap: 2px; max-width: 520px; }
  .form .actions { margin-top: 14px; }
  #third-party { margin-top: 14px; }
  #third-party .help { margin: 4px 0 0; }
  .wiki { margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--line); font-size: 0.8125rem; }
  .wiki a { color: var(--accent); text-decoration: none; font-weight: 500; }
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

  <section id="step-login" class="step">
    <div class="step-head"><span class="step-number">1</span><h2 data-i18n>Connect your LG account</h2></div>
    <div id="session-notice" class="card notice hidden">
      <div><strong data-i18n>Active session</strong><p class="muted" data-i18n>Using the refresh token saved in this plugin's settings.</p></div>
      <button id="new-login" data-i18n>Sign in with another account</button>
    </div>
    <form id="login-form" class="card form" autocomplete="on" novalidate>
      <label class="field"><span class="field-title" data-i18n>Country / language</span><select id="country-language"></select><span class="help" data-i18n>The region of your LG account.</span></label>
      <label class="field"><span class="field-title" data-i18n>Email</span><input type="email" id="username" placeholder="your@email.com" autocomplete="username" autocapitalize="none" spellcheck="false"><span class="help" data-i18n>Your LG ThinQ account's email.</span></label>
      <label class="field"><span class="field-title" data-i18n>Password</span><input type="password" id="password" autocomplete="current-password" enterkeyhint="go"></label>
      <label class="toggle"><span class="switch"><input type="checkbox" id="remember"><span></span></span><span><span class="field-title" data-i18n>Remember the email and password</span><span class="help" data-i18n>Optional: the sign-in keeps only a refresh token otherwise.</span></span></label>
      <div class="actions"><button type="submit" id="login" class="primary" data-i18n>Connect account</button></div>
      <p class="wiki muted">Signing in to LG with Google, Apple, Facebook or Amazon? <a href="https://github.com/mp-consulting/homebridge-lg-thinq/wiki/Plugin-Authorization-Setting" target="_blank" rel="noopener" data-i18n>See the authorization guide</a>, or use LG's own sign-in page below.</p>
    </form>
    <div id="third-party" class="card form">
      <strong data-i18n>Sign in with Google, Apple, Facebook or Amazon</strong>
      <p class="help">Open LG's sign-in page, sign in, then paste the address of the page it ends on (it starts with the LG account site and contains <span class="mono">iabClose</span>).</p>
      <div class="actions"><button id="open-lg" type="button" data-i18n>Open LG's sign-in page</button></div>
      <label class="field"><span class="field-title" data-i18n>Address after signing in</span><input type="url" id="redirect-url" placeholder="https://…/login/iabClose?…" spellcheck="false" autocapitalize="none"></label>
      <div class="actions"><button id="redirect-login" type="button" class="primary" data-i18n>Use this sign-in</button></div>
    </div>
    <div id="login-problem" class="problem hidden"></div>
  </section>

  <section id="step-devices" class="step hidden">
    <div class="step-head"><span class="step-number">2</span><h2 data-i18n>Your devices</h2></div>
    <div class="group tabs" role="tablist">
      <button id="tab-devices" role="tab" class="on" aria-selected="true" aria-controls="pane-devices" data-i18n>Devices</button>
      <button id="tab-settings" role="tab" aria-selected="false" aria-controls="pane-settings" data-i18n>Settings</button>
    </div>

    <div id="pane-devices" role="tabpanel" aria-labelledby="tab-devices">
      <div class="card">
        <div class="list-head">
          <h3 data-i18n>Devices in your account <span id="device-count" class="pill count">0</span></h3>
          <div class="actions"><button id="select-all" data-i18n>Select all</button><button id="refresh" data-i18n>Refresh</button></div>
        </div>
        <div id="devices-problem" class="problem hidden"></div>
        <ul id="device-list" class="devices"></ul>
        <p class="list-foot muted" data-i18n>Checked devices are added to HomeKit (none checked: all of them). ⚙ sets a device's options.</p>
      </div>
      <div id="device-panel" class="card panel hidden"></div>
      <div class="save-bar"><span id="devices-status" class="muted"></span><button id="save" class="primary" data-i18n>Save configuration</button></div>
    </div>

    <div id="pane-settings" class="settings hidden" role="tabpanel" aria-labelledby="tab-settings">
      <div class="card">
        <h3 data-i18n>Authentication</h3>
        <label class="field"><span class="field-title" data-i18n>Auth mode</span>
          <select id="auth-mode"><option value="account" data-i18n>LG account (email and password)</option><option value="token" data-i18n>Refresh token</option></select></label>
        <label id="token-field" class="field"><span class="field-title" data-i18n>Refresh token</span><input type="password" id="refresh-token" data-i18n placeholder="Paste your refresh token" autocomplete="off" autocapitalize="none" spellcheck="false" class="mono"></label>
        <div class="actions"><button id="switch-account" class="link" data-i18n>Sign in with another account</button></div>
      </div>
      <div class="card">
        <h3 data-i18n>Region</h3>
        <div class="columns">
          <label class="field"><span class="field-title" data-i18n>Country</span><input type="text" id="country" placeholder="US" maxlength="2" autocapitalize="characters"></label>
          <label class="field"><span class="field-title" data-i18n>Language</span><input type="text" id="language" placeholder="en-US" autocapitalize="none"></label>
        </div>
      </div>
      <div class="card">
        <h3 data-i18n>Sync</h3>
        <label class="toggle"><span class="switch"><input type="checkbox" id="thinq1"><span></span></span><span><span class="field-title" data-i18n>ThinQ1 support</span><span class="help" data-i18n>Adds the account's older ThinQ v1 devices, which are polled.</span></span></label>
        <label class="field"><span class="field-title" data-i18n>Refresh interval (seconds)</span><input type="number" id="refresh-interval" min="1" inputmode="numeric" class="number"><span class="help" data-i18n>How often ThinQ1 devices are polled. Default: 60.</span></label>
      </div>
      <div class="save-bar"><span class="muted" data-i18n>ThinQ2 devices are pushed by LG and need no polling.</span><button id="save-settings" class="primary" data-i18n>Save configuration</button></div>
    </div>
  </section>

  <section id="step-complete" class="step hidden">
    <div class="step-head"><span class="step-number done">✓</span><h2 data-i18n>Configuration saved</h2></div>
    <div class="card">
      <p id="complete-text" data-i18n>The plugin restarted with the new settings.</p>
      <div class="done-actions"><button id="restart" class="hidden" data-i18n>Restart Homeswift</button><button id="back" data-i18n>Back to the devices</button></div>
    </div>
  </section>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="countries.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
