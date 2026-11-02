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
