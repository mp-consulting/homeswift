// The LG ThinQ page: the Homebridge plugin's settings wizard. Step 1 signs in to the LG account (or uses the
// refresh token of the block); step 2 lists the account's devices to pick for HomeKit, with each device's
// options, and the account and sync settings; saving writes this instance's block, which reloads the plugin.
(() => {
  "use strict";
  const { $, el, api, request, readBlock, updateBlock, explain, breadcrumb } = homeswift;

  const DEFAULT_COUNTRY = "US";
  const DEFAULT_LANGUAGE = "en-US";
  const DEFAULT_REFRESH_INTERVAL = 60;

  // The options of each device type, as the Homebridge page shows them.
  const DEVICE_TYPE_FIELDS = {
    AC: {
      selects: [
        { key: "ac_mode", label: "AC mode", options: [["", "Both (default)"], ["COOLING", "Cooling only"], ["HEATING", "Heating only"], ["BOTH", "Both"]] },
        { key: "ac_swing_mode", label: "Swing mode", options: [["", "Default"], ["BOTH", "Both axes"], ["VERTICAL", "Vertical only"], ["HORIZONTAL", "Horizontal only"]] },
        { key: "ac_temperature_unit", label: "Temperature unit", options: [["C", "Celsius (°C)"], ["F", "Fahrenheit (°F)"]] },
      ],
      toggles: [
        { key: "ac_fan_control", label: "Separate fan control", group: "Controls" },
        { key: "ac_jet_control", label: "Separate jet control", group: "Controls" },
        { key: "ac_energy_save", label: "Energy save switch", group: "Controls" },
        { key: "ac_air_clean", label: "Air purify switch", group: "Controls" },
        { key: "ac_led_control", label: "LED panel control", group: "Controls" },
        { key: "ac_air_quality", label: "Air quality sensor", group: "Sensors" },
        { key: "ac_temperature_sensor", label: "Current temperature as sensor", group: "Sensors" },
        { key: "ac_humidity_sensor", label: "Humidity sensor", group: "Sensors" },
      ],
    },
    WASHER: {
      toggles: [
        { key: "washer_trigger", label: "Program finished trigger" },
        { key: "washer_tub_clean", label: "Tub clean event" },
        { key: "washer_door_lock", label: "Door lock status" },
      ],
    },
    REFRIGERATOR: {
      toggles: [
        { key: "ref_express_freezer", label: "Express Freezer / Ice Plus" },
        { key: "ref_express_fridge", label: "Express Fridge" },
        { key: "ref_eco_friendly", label: "Eco Friendly" },
      ],
    },
    DISHWASHER: { toggles: [{ key: "dishwasher_trigger", label: "Program finished trigger" }] },
    AIR_PURIFIER: { toggles: [{ key: "air_fast_mode", label: "Air Fast Mode" }] },
  };
  for (const type of ["WASHER_NEW", "WASH_TOWER", "DRYER"]) DEVICE_TYPE_FIELDS[type] = DEVICE_TYPE_FIELDS.WASHER;
  const AC_OP_MODES = [[0, "Cool"], [1, "Dry"], [2, "Fan"], [4, "Heat"], [5, "Air Clean"], [6, "Auto"]];

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

  const countrySelect = $("#country-language");
  countrySelect.replaceChildren(...window.LG_COUNTRIES.map(({ country, language, label }) =>
    el("option", { value: `${country}|${language}`, text: label })));
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
      showProblem(problem, "Please enter your username and password.");
      return;
    }
    clearProblem(problem);
    act(button, async () => {
      try {
        const answer = await request("login-by-user-pass", { method: "POST", body: { country, language, username, password } });
        if (!answer.success) throw new Error(answer.error || "Login failed");
        await connected(answer.token, country, language, { username, password });
      } catch (e) {
        showProblem(problem, e.message || "Login failed",
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
      if (!answer.success) throw new Error(answer.error || "Login failed");
      await connected(answer.token, country, language, null);
    } catch (e) {
      showProblem(problem, e.message || "Login failed",
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
        if (!answer.success) throw new Error(answer.error || "Failed to load devices");
        devices = answer.devices || [];
        if (selected.size === 0) devices.forEach((device) => selected.add(device.id));
        try {
          running = new Set(((await request("devices")).devices || []).map((device) => device.id));
        } catch { running = new Set(); }
        renderDevices();
      } catch (e) {
        showProblem(problem, e.message || "Failed to load devices",
          "Loading the device list from the LG ThinQ cloud with the stored refresh token failed in the plugin settings.");
      }
    });
  }

  function renderDevices() {
    $("#device-count").textContent = String(devices.length);
    $("#select-all").textContent = selected.size === devices.length && devices.length > 0 ? "Deselect all" : "Select all";
    if (!devices.length) {
      list.replaceChildren(el("li", { class: "empty muted", text: "No devices found. Connect your LG account and press Refresh." }));
      return;
    }
    list.replaceChildren(...devices.map((device) => {
      const overrides = deviceSettings[device.id] || {};
      const isSelected = selected.has(device.id);
      const online = device.online !== false;
      const checkbox = el("input", { type: "checkbox", checked: isSelected, "aria-label": `Add ${overrides.name || device.name} to HomeKit` });
      const row = el("li", { class: `device${isSelected ? " selected" : ""}`, "data-id": device.id },
        checkbox,
        el("div", { class: "who" }, el("strong", { text: overrides.name || device.name }),
          el("div", { class: "meta muted" }, el("span", { text: typeOf(device) }), " · ", el("span", { class: "id mono", text: `ID: ${device.id}` }))),
        online ? null : explain({
          error: "The LG ThinQ cloud reports this appliance as offline (not connected to LG).",
          context: assistantContext("The user is looking at the device list of the LG ThinQ plugin settings."),
          device: { name: overrides.name || device.name, type: typeOf(device), online, includedInHomeKit: isSelected },
        }),
        running.has(device.id) ? el("span", { class: "pill on", text: "In HomeKit" }) : null,
        el("span", { class: `pill status ${online ? "on" : "away"}`, text: online ? "Online" : "Offline" }),
        el("button", { class: "gear", title: "Device settings", "aria-label": `Settings of ${overrides.name || device.name}`, text: "⚙",
          onclick: (event) => { event.stopPropagation(); openDevice(device.id); } }));
      row.addEventListener("click", (event) => {
        if (event.target.closest(".gear, .explain")) return;
        if (event.target !== checkbox) checkbox.checked = !checkbox.checked;
        if (checkbox.checked) selected.add(device.id); else selected.delete(device.id);
        row.classList.toggle("selected", checkbox.checked);
        $("#select-all").textContent = selected.size === devices.length ? "Deselect all" : "Select all";
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
      typeSection.push(el("h3", { class: "group-title", text: `${device.type} settings` }));
      if (fields.selects) {
        typeSection.push(el("div", { class: "columns" }, fields.selects.map((field) => {
          const select = el("select", {}, field.options.map(([value, label]) => el("option", { value, text: label, selected: (overrides[field.key] || "") === value })));
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
          const label = el("input", { type: "text", placeholder: "Name", value: button.name || "" });
          const mode = el("select", {}, AC_OP_MODES.map(([value, title]) => el("option", { value: String(value), text: title, selected: Number(button.op_mode ?? 0) === value })));
          const row = el("div", { class: "button-row" }, label, mode, el("button", { class: "link danger", text: "Remove", onclick: () => row.remove() }));
          buttonsList.append(row);
        };
        (overrides.ac_buttons || []).forEach(addButton);
        typeSection.push(el("div", { class: "buttons-editor" },
          el("div", { class: "list-head" }, el("h3", { class: "group-title", text: "AC buttons" }), el("button", { text: "Add button", onclick: () => addButton() })),
          el("p", { class: "help", text: "Custom HomeKit switches that select an operation mode." }), buttonsList));
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
      $("#devices-status").textContent = "Device settings applied: Save to keep them.";
    };
    breadcrumb(overrides.name || device.name, closeDevice);
    panel.classList.remove("hidden");
    panel.replaceChildren(
      el("div", { class: "panel-head" }, el("h3", { text: overrides.name || device.name }), el("button", { class: "link", text: "Close", onclick: closeDevice })),
      el("div", { class: "columns" },
        fieldRow("Display name", nameInput, "Its name in HomeKit; empty uses the device's name."),
        fieldRow("Serial number (optional)", serialInput)),
      typeSection,
      el("div", { class: "save-bar" }, el("span", { class: "muted", text: "" }), el("button", { text: "Cancel", onclick: closeDevice }), el("button", { class: "primary", text: "Apply", onclick: apply })));
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
          ? `Saved. Restart Homeswift to apply the rest (${pending.join("; ")}).`
          : "Saved. The plugin restarted with the new settings: its devices keep their place in the Home app.";
        showStep("complete");
      } catch (e) {
        $("#devices-status").textContent = e.message || "Failed to save the configuration";
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
    $("#complete-text").textContent = "Restarting…";
    for (let tries = 0; tries < 60; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try { await request("devices"); break; } catch { /* not back yet */ }
    }
    $("#complete-text").textContent = "Homeswift restarted with the new settings.";
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
