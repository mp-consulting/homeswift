// The Dyson Pure Cool page, the Homebridge plugin's setup wizard: the devices already set up (name, sensor
// offsets, continuous monitoring, heating service, remove, saved as you change them), and account → emailed
// code → devices → options to add or re-sync devices from the Dyson account. Saving writes this instance's
// block, merged so the keys the wizard does not show are kept; the plugin reloads with it.
(() => {
  "use strict";
  const { $, el, request, name, explain, assistant, home, api, readBlock, updateBlock, poll } = homeswift;
  const { t, tn } = HomeswiftI18n;

  /// `text` with an element where its `{name}` placeholder is: a sentence keeps its words in the language's order.
  const around = (text, name, element) => {
    const [before, after = ""] = text.split(`{${name}}`);
    return [before, element, after];
  };

  const countries = [
    [t("Americas"), [["CA", "Canada"], ["US", "United States"]]],
    [t("Asia Pacific"), [["AU", "Australia"], ["CN", "China"], ["HK", "Hong Kong"], ["IN", "India"], ["JP", "Japan"], ["MY", "Malaysia"],
      ["NZ", "New Zealand"], ["SG", "Singapore"], ["KR", "South Korea"], ["TW", "Taiwan"], ["TH", "Thailand"]]],
    [t("Europe"), [["AT", "Austria"], ["BE", "Belgium"], ["CZ", "Czech Republic"], ["DK", "Denmark"], ["FI", "Finland"], ["FR", "France"],
      ["DE", "Germany"], ["IE", "Ireland"], ["IT", "Italy"], ["NL", "Netherlands"], ["NO", "Norway"], ["PL", "Poland"], ["PT", "Portugal"],
      ["ES", "Spain"], ["SE", "Sweden"], ["CH", "Switzerland"], ["GB", "United Kingdom"]]],
    [t("Middle East"), [["SA", "Saudi Arabia"], ["AE", "United Arab Emirates"]]],
  ];
  // Countries in the page's language (the list's English names otherwise), in its alphabetical order.
  const regionNames = (() => {
    if (HomeswiftI18n.language === "en") return null;
    try { return new Intl.DisplayNames([HomeswiftI18n.locale], { type: "region" }); } catch { return null; }
  })();
  if (regionNames) {
    for (const group of countries) {
      group[1] = group[1].map(([code, label]) => [code, regionNames.of(code) || label])
        .sort((a, b) => a[1].localeCompare(b[1], HomeswiftI18n.locale));
    }
  }

  const state = {
    step: 1,
    authToken: null,
    devices: [],
    selected: new Set(),
    submitting: false,
    existingConfig: null,
    isResync: false,
  };
  let productTypes = {};
  let heatingProductTypes = [];
  let jetFocusProductTypes = [];
  let running = new Map();   // serial → what the plugin instance reports
  let assistantOn = false;

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors go to the status line.
  const act = (button, work) => homeswift.act(button, work, (message) => toast(message, "error"));

  // A line under the wizard for what Homebridge showed as toasts.
  const statusLine = el("p", { class: "status-line muted", role: "status" });
  let toastTimer = null;
  function toast(message, kind = "ok") {
    statusLine.textContent = message;
    statusLine.className = `status-line ${kind}`;
    clearTimeout(toastTimer);
    if (kind !== "error") toastTimer = setTimeout(() => { statusLine.textContent = ""; }, 4000);
  }

  // MARK: The Assistant (the runtime's): never the login, codes, credentials, serial numbers or addresses.

  /// Error text without Dyson serial numbers (the server masks e-mail and IP addresses).
  const scrub = (text) => String(text ?? "").replace(/\b[A-Z0-9]{3}-[A-Z]{2}-[A-Z0-9]{6,}\b/g, "<serial>");

  /// The device facts the Assistant may see.
  const assistantDevice = (d) => ({
    name: d.name || undefined, productType: d.productType, model: productTypes[d.productType] || undefined,
    firmwareVersion: d.version || d.firmwareVersion || undefined, hasHeating: d.hasHeating === true,
    ipAddressSaved: !!d.ipAddress, continuousMonitoring: d.isContinuousMonitoringEnabled === true,
  });

  const context = (extra) => [extra, country.value ? `Dyson account country: ${country.value}.` : "",
    `Polling interval: ${parseInt(polling.value, 10) || 60} seconds.`].filter(Boolean).join(" ");

  /// An error with Explain when the Assistant is set up.
  function problem(message, extra, device) {
    return el("div", {}, el("p", { class: "status-line error", text: message }),
      explain({ error: scrub(message), context: context(extra), device: device ? assistantDevice(device) : undefined }));
  }

  // MARK: The steps

  const wizard = $("#wizard");
  const stepNames = [t("Account"), t("Devices"), t("Options")];
  const progress = el("ol", { class: "steps" }, stepNames.map((label, i) => el("li", { "data-n": String(i + 1), text: label })));

  // Step 0: the devices already set up.
  const existingList = el("div", { class: "devices" });
  const resyncButton = el("button", { actionIcon: "restore", text: t("Re-sync from Dyson Cloud"), title: t("Sign in again to add devices or refresh their credentials"), onclick: () => {
    state.isResync = true;
    go(1);
    setTimeout(() => email.focus(), 50);
  } });
  const stepExisting = el("div", { class: "step" },
    el("div", { class: "section-head" }, el("h2", { text: t("Your Dyson devices") }),
      el("div", { class: "actions", style: "margin:0" }, resyncButton, el("button", { actionIcon: "sliders", text: t("Edit options"), onclick: () => go(3) }))),
    existingList);

  // Step 1: the Dyson account.
  const email = el("input", { type: "email", placeholder: t("your@email.com"), autocomplete: "email", id: "email" });
  const password = el("input", { type: "password", placeholder: t("Your Dyson password"), autocomplete: "current-password", id: "password" });
  const showPassword = el("button", { actionIcon: "eye", type: "button", class: "link", text: t("Show"), "aria-label": t("Toggle password visibility"), onclick: () => {
    const hidden = password.type === "password";
    password.type = hidden ? "text" : "password";
    showPassword.textContent = hidden ? t("Hide") : t("Show");
  } });
  const country = el("select", { id: "country" }, countries.map(([group, list]) =>
    el("optgroup", { label: group }, list.map(([code, label]) => el("option", { value: code, text: label })))));
  country.value = "US";
  const loginProblem = el("div", {});
  const resyncHint = el("p", { class: "hint hidden", text: t("Re-enter your credentials to re-sync devices from Dyson Cloud.") });
  const cancelResync = el("button", { actionIcon: "close", class: "hidden", text: t("Cancel"), onclick: () => { state.isResync = false; go(0); } });
  const connectButton = el("button", { actionIcon: "key", class: "primary", text: t("Connect Account"), onclick: (event) => act(event.currentTarget, connect) });
  const assistantHint = el("p", { class: "hint hidden" }, ...around(t("Tip: add a {block} block to config.json to get the Assistant, which explains sign-in and device connection errors here."),
    "block", el("strong", { text: "HomeswiftAiKit" })));
  const stepAccount = el("div", { class: "step" },
    el("h2", { text: t("Connect your Dyson account") }),
    el("p", { class: "muted", text: t("Enter your Dyson account credentials to discover your devices. The password is not saved: it is only used to fetch each device's local credentials.") }),
    resyncHint,
    el("div", { class: "form" },
      el("div", { class: "wide field" }, el("label", { class: "field-title", htmlFor: "email", text: t("Email address") }), email),
      el("div", { class: "field" }, el("label", { class: "field-title", htmlFor: "password", text: t("Password") }), el("div", { class: "with-button" }, password, showPassword)),
      el("div", { class: "field" }, el("label", { class: "field-title", htmlFor: "country", text: t("Country") }), country)),
    loginProblem,
    el("div", { class: "actions" }, cancelResync, connectButton),
    assistantHint);

  // Step 1b: the emailed code.
  const code = el("input", { type: "text", class: "code-input", placeholder: "000000", maxlength: 6, inputmode: "numeric", autocomplete: "one-time-code", "aria-label": t("Verification code") });
  const codeProblem = el("div", {});
  const verifyButton = el("button", { actionIcon: "check", class: "primary", text: t("Verify"), onclick: (event) => act(event.currentTarget, verify) });
  const stepCode = el("div", { class: "step" },
    el("h2", { text: t("Verify your identity") }),
    el("p", { class: "muted", text: t("We've sent a verification code to your email. Enter it below.") }),
    el("p", { class: "hint", text: t("Check your inbox for an email from Dyson with your verification code.") }),
    el("div", { class: "field" }, el("label", { class: "field-title", text: t("Verification code") }), code),
    codeProblem,
    el("div", { class: "actions" }, el("button", { actionIcon: "restore", text: t("Back"), onclick: () => go(1) }), verifyButton));

  // Step 2: the account's devices.
  const deviceList = el("div", { class: "devices" });
  const stepDevices = el("div", { class: "step" },
    el("h2", { text: t("Select your devices") }),
    el("p", { class: "muted", text: t("Choose which devices to add to HomeKit. You can customize the name for each device.") }),
    deviceList,
    el("div", { class: "actions" },
      el("button", { actionIcon: "restore", text: t("Back"), onclick: () => go(state.existingConfig ? 0 : 1) }),
      el("button", { actionIcon: "check", class: "primary", text: t("Continue"), onclick: () => {
        if (state.selected.size === 0) return toast(t("Please select at least one device"), "error");
        go(3);
      } })));

  // Step 3: options.
  const option = (id, label, checked = true) => {
    const input = el("input", { type: "checkbox", id, checked });
    return { input, row: el("div", { class: "toggle-row" }, el("label", { class: "switch" }, input, el("span", {})), el("label", { htmlFor: id, text: label })) };
  };
  const options = {
    temperature: option("opt-temperature", t("Temperature sensor")),
    humidity: option("opt-humidity", t("Humidity sensor")),
    airQuality: option("opt-air-quality", t("Air quality sensor")),
    nightMode: option("opt-night-mode", t("Night mode switch")),
    jetFocus: option("opt-jet-focus", t("Jet focus switch (diffuse/focused)")),
    autoMode: option("opt-auto-mode", t("Auto mode switch")),
    filterStatus: option("opt-filter-status", t("Filter status indicator"), false),
  };
  const polling = el("input", { type: "number", class: "polling", value: 60, min: 10, max: 300, id: "opt-polling" });
  const saveButton = el("button", { actionIcon: "check", class: "primary", text: t("Save"), onclick: (event) => act(event.currentTarget, saveFromWizard) });
  const stepOptions = el("div", { class: "step options" },
    el("h2", { text: t("Configure options") }),
    el("p", { class: "muted", text: t("Customize how your devices appear in HomeKit.") }),
    el("h3", { text: t("Sensor options") }), options.temperature.row, options.humidity.row, options.airQuality.row,
    el("h3", { text: t("Additional controls") }), options.nightMode.row, options.jetFocus.row, options.autoMode.row, options.filterStatus.row,
    el("h3", { text: t("Advanced") }),
    el("div", { class: "field" }, el("label", { class: "field-title", htmlFor: "opt-polling", text: t("Polling interval (seconds)") }), polling,
      el("p", { class: "help", text: t("How often to check device status (10-300 seconds)") })),
    el("div", { class: "actions" },
      el("button", { actionIcon: "restore", text: t("Back"), onclick: () => go(state.existingConfig && !state.authToken ? 0 : 2) }), saveButton));

  // Done.
  const doneText = el("p", { class: "muted center" });
  const restartButton = el("button", { actionIcon: "power", class: "primary hidden", text: t("Restart Homeswift"), onclick: (event) => act(event.currentTarget, restart) });
  const stepDone = el("div", { class: "step center" },
    el("div", { class: "done-icon", text: "✓" }),
    el("h2", { text: t("Configuration complete!") }),
    doneText,
    el("div", { class: "actions", style: "justify-content:center" }, restartButton, el("button", { actionIcon: "close", text: t("Close"), onclick: () => { location.href = home; } })));

  const bodies = { 0: stepExisting, 1: stepAccount, "1b": stepCode, 2: stepDevices, 3: stepOptions, success: stepDone };
  wizard.replaceChildren(progress, ...Object.values(bodies), statusLine);

  function go(step) {
    for (const [key, body] of Object.entries(bodies)) body.classList.toggle("hidden", key !== String(step));
    // No progress while devices are already set up (not the first setup).
    progress.classList.toggle("hidden", !!state.existingConfig || step === "success");
    loginProblem.replaceChildren();
    codeProblem.replaceChildren();
    if (step === 1) {
      resyncHint.classList.toggle("hidden", !state.isResync);
      cancelResync.classList.toggle("hidden", !state.isResync);
    }
    if (step === 3) {
      // Jet focus only when a selected device has it.
      const selected = state.devices.filter((d) => state.selected.has(d.serial));
      options.jetFocus.row.classList.toggle("hidden", !selected.some((d) => d.hasJetFocus === true));
    }
    const numeric = step === 0 || step === "1b" ? 1 : step === "success" ? 4 : step;
    [...progress.children].forEach((item, i) => {
      item.classList.toggle("current", i + 1 === numeric);
      item.classList.toggle("done", i + 1 < numeric);
      if (i + 1 === numeric) item.setAttribute("aria-current", "step"); else item.removeAttribute("aria-current");
    });
    state.step = step;
  }

  // MARK: Device cards

  function deviceCard(device, { selectable = false, removable = false, container }) {
    const typeName = productTypes[device.productType] || device.productType;
    const selected = state.selected.has(device.serial);
    const live = running.get(device.serial);
    const card = el("div", { class: `card device${selectable && !removable ? " selectable" : ""}${selectable && !removable && selected ? " selected" : ""}`, "data-serial": device.serial });

    const nameInput = el("input", { type: "text", value: device.name || "", placeholder: typeName || t("Dyson Device"), "aria-label": t("Name"),
      onclick: (event) => event.stopPropagation(),
      oninput: () => { device.name = nameInput.value.trim(); if (removable) debouncedSave(); } });
    const badges = el("div", { class: "badges" },
      device.version ? el("span", { class: "badge", text: device.version }) : null,
      device.newVersionAvailable ? el("span", { class: "badge update", text: t("Update available") }) : null);

    const settings = el("div", { class: "settings hidden", onclick: (event) => event.stopPropagation() });
    const gear = el("button", { actionIcon: "sliders", class: "link", text: t("Settings"), title: t("Device settings"), onclick: (event) => {
      event.stopPropagation();
      settings.classList.toggle("hidden");
    } });

    let status = null;
    let action;
    if (removable) {
      status = live ? el("span", { class: `pill status ${live.connected ? "on" : live.retrying ? "away" : "standby"}`, text: liveText(live) }) : null;
      action = el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), title: t("Remove device"), onclick: () => {
        state.devices = state.devices.filter((d) => d.serial !== device.serial);
        state.selected.delete(device.serial);
        renderExisting();
        autoSave();
      } });
    } else {
      action = el("input", { type: "checkbox", checked: selected, "aria-label": t("Add to HomeKit"), onclick: (event) => { event.stopPropagation(); toggle(); } });
    }
    const toggle = () => {
      if (state.selected.has(device.serial)) state.selected.delete(device.serial); else state.selected.add(device.serial);
      const on = state.selected.has(device.serial);
      card.classList.toggle("selected", on);
      if (action.type === "checkbox") action.checked = on;
    };
    if (selectable && !removable) card.addEventListener("click", toggle);

    // The device's own settings.
    const id = (suffix) => `${suffix}-${device.serial.replace(/[^a-zA-Z0-9]/g, "-")}${removable ? "-saved" : ""}`;
    const monitoring = el("input", { type: "checkbox", id: id("cm"), checked: device.isContinuousMonitoringEnabled === true });
    const temperatureOffset = el("input", { type: "number", step: 0.5, min: -10, max: 10, value: typeof device.temperatureOffset === "number" ? device.temperatureOffset : 0, id: id("to") });
    const humidityOffset = el("input", { type: "number", step: 1, min: -20, max: 20, value: typeof device.humidityOffset === "number" ? device.humidityOffset : 0, id: id("ho") });
    const fahrenheit = el("input", { type: "checkbox", id: id("f"), checked: device.useFahrenheit === true });
    const problemSlot = el("div", {});
    const changed = removable ? debouncedSave : null;
    temperatureOffset.addEventListener("input", () => { const v = parseFloat(temperatureOffset.value); device.temperatureOffset = Number.isFinite(v) ? v : 0; changed?.(); });
    humidityOffset.addEventListener("input", () => { const v = parseInt(humidityOffset.value, 10); device.humidityOffset = Number.isFinite(v) ? v : 0; changed?.(); });
    fahrenheit.addEventListener("change", () => { device.useFahrenheit = fahrenheit.checked; changed?.(); });
    monitoring.addEventListener("change", () => setMonitoring(device, monitoring, problemSlot, removable));
    settings.append(
      el("div", { class: "toggle-row" }, el("label", { class: "switch" }, monitoring, el("span", {})),
        el("label", { htmlFor: monitoring.id }, t("Continuous monitoring"), el("small", { text: t("Keep sensors active when off (required for HomeKit control while off)") }))),
      el("div", { class: "row2" },
        el("div", { class: "field" }, el("label", { class: "field-title", htmlFor: temperatureOffset.id, text: t("Temperature offset (°C)") }), temperatureOffset),
        el("div", { class: "field" }, el("label", { class: "field-title", htmlFor: humidityOffset.id, text: t("Humidity offset (%)") }), humidityOffset)),
      el("p", { class: "help", text: t("Adjust if your device reads consistently high or low.") }),
      el("div", { class: "toggle-row" }, el("label", { class: "switch" }, fahrenheit, el("span", {})),
        el("label", { htmlFor: fahrenheit.id }, t("Use Fahrenheit"), el("small", { text: t("Log temperatures in °F (the Home app follows your device's settings)") }))));
    if (device.hasHeating === true) {
      const heating = el("select", { id: id("h") },
        [["thermostat", t("Thermostat (Recommended)")], ["heater-cooler", t("Heater Cooler")], ["both", t("Both")]].map(([value, text]) =>
          el("option", { value, text, selected: (device.heatingServiceType || "thermostat") === value })));
      heating.addEventListener("change", () => { device.heatingServiceType = heating.value; if (removable) autoSave(); });
      settings.append(el("div", { class: "field" }, el("label", { class: "field-title", htmlFor: heating.id, text: t("Heating service") }), heating,
        el("ul", { class: "heating-help" },
          el("li", {}, el("strong", { text: t("Thermostat") }), " — ", t("single tile with temperature control")),
          el("li", {}, el("strong", { text: t("Heater Cooler") }), " — ", t("a heater tile with the heating threshold")),
          el("li", {}, el("strong", { text: t("Both") }), " — ", t("show both tiles in HomeKit")))));
    }

    const facts = removable && live && live.connected ? el("div", { class: "facts live" },
      fact(t("Fan"), live.on ? (live.autoMode ? t("Auto") : t("Speed {n}", { n: live.fanSpeed > 0 ? live.fanSpeed : "—" })) : t("Off")),
      live.temperature !== undefined ? fact(t("Temperature"), homeswift.formatTemperature(live.temperature)) : null,
      live.humidity !== undefined ? fact(t("Humidity"), `${live.humidity} %`) : null,
      live.pm25 !== undefined ? fact("PM2.5", String(live.pm25)) : null,
      live.filterLife !== undefined ? fact(t("Filter"), `${live.filterLife} %`) : null) : null;

    card.append(
      el("div", { class: "device-head" },
        el("span", { class: "tile dyson", "aria-hidden": "true" }, fanIcon()),
        el("div", { class: "who" }, nameInput,
          el("div", { class: "muted", text: typeName }),
          el("div", { class: "muted mono", text: [device.serial, device.ipAddress].filter(Boolean).join(" · ") }),
          badges.childElementCount ? badges : null),
        status, gear, action),
      facts, settings, problemSlot);

    if (removable) fetchMonitoring(device, monitoring, problemSlot);
    return card;
  }

  const fact = (label, value) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: value }));

  /// What a status pill says of a running device.
  const liveText = (live) => (live.connected ? t("Connected") : live.retrying ? t("Not responding") : t("Connecting"));

  function fanIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.innerHTML = '<path d="M12 12c-3-5 1-9 4-7s0 5-4 7zm0 0c5-3 9 1 7 4s-5 0-7-4zm0 0c3 5-1 9-4 7s0-5 4-7zm0 0c-5 3-9-1-7-4s5 0 7 4z"/>';
    return svg;
  }

  /// Reads whether continuous monitoring is on, from the device (or the plugin's connection to it).
  async function fetchMonitoring(device, checkbox, slot) {
    checkbox.disabled = true;
    try {
      const response = await request("get-device-state", { method: "POST", body: deviceRequest(device) });
      checkbox.checked = response.continuousMonitoring;
      device.isContinuousMonitoringEnabled = response.continuousMonitoring;
      if (response.discoveredIp && response.discoveredIp !== device.ipAddress) {
        device.ipAddress = response.discoveredIp;
        debouncedSave();
      }
    } catch (e) {
      console.warn(`Failed to fetch state for ${device.serial}:`, e.message);
      if (assistantOn) slot.replaceChildren(el("p", { class: "device-problem", text: e.message }),
        explain({ error: scrub(e.message), context: context("Reading the device state over the local network (mDNS discovery or saved IP, then MQTT on port 1883) from the plugin settings failed."), device: assistantDevice(device) }));
    } finally {
      checkbox.disabled = false;
    }
  }

  async function setMonitoring(device, checkbox, slot, saved) {
    const enabled = checkbox.checked;
    checkbox.disabled = true;
    slot.replaceChildren();
    try {
      const response = await request("set-continuous-monitoring", { method: "POST", body: { ...deviceRequest(device), enabled } });
      device.isContinuousMonitoringEnabled = enabled;
      toast(enabled ? t("Continuous monitoring enabled") : t("Continuous monitoring disabled"));
      if (response.discoveredIp && response.discoveredIp !== device.ipAddress) {
        device.ipAddress = response.discoveredIp;
        if (saved) debouncedSave();
      }
      if (saved) debouncedSave();
    } catch (e) {
      checkbox.checked = !enabled;
      toast(e.message || t("Failed to set continuous monitoring"), "error");
      if (assistantOn) slot.replaceChildren(el("p", { class: "device-problem", text: e.message }),
        explain({ error: scrub(e.message), context: context("Turning continuous monitoring on or off over the local network (MQTT on port 1883) failed."), device: assistantDevice(device) }));
    } finally {
      checkbox.disabled = false;
    }
  }

  const deviceRequest = (d) => ({ serial: d.serial, productType: d.productType, localCredentials: d.localCredentials || d.credentials, ipAddress: d.ipAddress });

  function renderExisting() {
    if (state.devices.length === 0) {
      existingList.replaceChildren(el("div", { class: "card empty center" },
        el("p", { class: "muted" }, ...around(t("No devices configured. Click {button} to add devices."), "button", el("strong", { text: t("Re-sync from Dyson Cloud") })))));
      return;
    }
    existingList.replaceChildren(...state.devices.map((d) => deviceCard(d, { selectable: true, removable: true, container: existingList })));
  }

  function renderDeviceList() {
    deviceList.replaceChildren(...state.devices.map((d) => deviceCard(d, { selectable: true, container: deviceList })));
  }

  // MARK: Live state of the devices this instance runs

  async function refreshLive() {
    try {
      const { devices } = await request("devices");
      const next = new Map(devices.map((d) => [d.serial, d]));
      const changed = JSON.stringify([...next]) !== JSON.stringify([...running]);
      running = next;
      // Redraw the status pills only: the cards hold what is being typed.
      if (changed && state.step === 0) {
        for (const card of existingList.querySelectorAll(".device[data-serial]")) {
          const live = running.get(card.dataset.serial);
          const pill = card.querySelector(".pill.status");
          if (live && pill) {
            pill.className = `pill status ${live.connected ? "on" : live.retrying ? "away" : "standby"}`;
            pill.textContent = liveText(live);
          }
        }
      }
    } catch { /* the instance is restarting */ }
  }
  // While the devices already set up are shown.
  poll(() => { if (state.step === 0) refreshLive(); }, 5000);

  // MARK: config.json

  function loadExisting(config) {
    const set = (option, value) => { if (value !== undefined) option.input.checked = value; };
    set(options.temperature, config.enableTemperature);
    set(options.humidity, config.enableHumidity);
    set(options.airQuality, config.enableAirQuality);
    set(options.nightMode, config.enableNightMode);
    set(options.jetFocus, config.enableJetFocus);
    set(options.autoMode, config.enableAutoMode);
    set(options.filterStatus, config.enableFilterStatus);
    if (config.pollingInterval) polling.value = config.pollingInterval;
    if (config.countryCode) country.value = config.countryCode;
    if (Array.isArray(config.devices)) {
      // Entries without a string serial (hand-edited, older layouts) would break the cards.
      const valid = config.devices.filter((d) => d && typeof d.serial === "string");
      if (valid.length !== config.devices.length) console.warn("[Wizard] Ignored config device entries without a valid serial");
      state.devices = valid.map((d) => ({
        ...d,
        productName: productTypes[d.productType] || `Unknown (${d.productType})`,
        hasHeating: heatingProductTypes.includes(d.productType),
        hasJetFocus: jetFocusProductTypes.includes(d.productType),
      }));
      state.selected = new Set(valid.map((d) => d.serial));
    }
  }

  function buildConfig() {
    const selected = state.devices.filter((d) => state.selected.has(d.serial));
    const o = options;
    return {
      platform: "DysonPureCool",
      name: state.existingConfig?.name || name || "Dyson Pure Cool",
      countryCode: country.value,
      devices: selected.map((d) => {
        const entry = { serial: d.serial, name: d.name, productType: d.productType, localCredentials: d.localCredentials };
        if (d.ipAddress) entry.ipAddress = d.ipAddress;
        if (d.version) entry.firmwareVersion = d.version;
        if (d.isContinuousMonitoringEnabled) entry.isContinuousMonitoringEnabled = true;
        if (d.hasHeating && d.heatingServiceType) entry.heatingServiceType = d.heatingServiceType;
        if (typeof d.temperatureOffset === "number" && d.temperatureOffset !== 0) entry.temperatureOffset = d.temperatureOffset;
        if (typeof d.humidityOffset === "number" && d.humidityOffset !== 0) entry.humidityOffset = d.humidityOffset;
        if (d.useFahrenheit === true) entry.useFahrenheit = true;
        return entry;
      }),
      enableTemperature: o.temperature.input.checked,
      enableHumidity: o.humidity.input.checked,
      enableAirQuality: o.airQuality.input.checked,
      enableNightMode: o.nightMode.input.checked,
      enableJetFocus: o.jetFocus.input.checked,
      enableAutoMode: o.autoMode.input.checked,
      enableFilterStatus: o.filterStatus.input.checked,
      pollingInterval: parseInt(polling.value, 10) || 60,
    };
  }

  /// Saves the wizard's fields merged into the block: the plugin reloads with them.
  async function saveConfig() {
    let merged;
    const result = await updateBlock((current) => (merged = DysonConfigMerge.mergePluginConfig(current ?? state.existingConfig, buildConfig())));
    state.existingConfig = merged;
    return result;
  }

  async function autoSave() {
    if (state.step !== 0) return;
    try {
      await saveConfig();
      toast(t("Settings saved"));
    } catch (e) {
      toast(t("Failed to save: {error}", { error: e.message || t("Unknown error") }), "error");
    }
  }
  let saveTimer = null;
  function debouncedSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(autoSave, 500);
  }

  async function saveFromWizard() {
    const result = await saveConfig();
    const pending = result.restartNeeded || [];
    restartButton.classList.toggle("hidden", pending.length === 0);
    doneText.textContent = pending.length
      ? t("Your Dyson devices are saved. Restart Homeswift to apply the rest ({changes}).", { changes: pending.join("; ") })
      : t("Your Dyson devices are configured, and the plugin restarted with them. They show up in the Home app with the bridge.");
    toast(t("Configuration saved!"));
    go("success");
  }

  async function restart() {
    await api("/api/restart", { method: "POST" });
    toast(t("Restarting…"));
  }

  // MARK: The Dyson account

  async function connect() {
    const address = email.value.trim();
    if (!address || !password.value) return showLoginProblem(t("Please enter your email and password"));
    loginProblem.replaceChildren();
    try {
      const response = await request("authenticate", { method: "POST", body: { email: address, password: password.value, countryCode: country.value } });
      if (response.requires2FA) {
        go("1b");
        code.focus();
      } else {
        state.authToken = response.token;
        await fetchDevices();
      }
    } catch (e) {
      showLoginProblem(e.message || t("Authentication failed"));
    }
  }

  function showLoginProblem(message, extra) {
    loginProblem.replaceChildren(problem(message, extra || "Signing in to the Dyson account from the setup page (account status check, then requesting a verification code) failed."));
  }

  async function verify() {
    if (state.submitting) return;
    const value = code.value.trim();
    if (!value || value.length < 6) return codeProblem.replaceChildren(el("p", { class: "status-line error", text: t("Please enter the 6-digit verification code") }));
    state.submitting = true;
    codeProblem.replaceChildren();
    try {
      const response = await request("verify-otp", { method: "POST", body: { otpCode: value } });
      state.authToken = response.token;
      toast(t("Verification successful!"));
      await fetchDevices();
    } catch (e) {
      codeProblem.replaceChildren(problem(e.message || t("Verification failed"),
        "Verifying the 6-digit code that Dyson emailed (POST /v3/userregistration/email/verify, together with the account password) failed."));
      code.value = "";
      code.focus();
    } finally {
      state.submitting = false;
    }
  }

  async function fetchDevices() {
    try {
      const response = await request("get-devices", { method: "POST", body: { token: state.authToken } });
      // The saved per-device settings of devices already set up carry over.
      state.devices = DysonConfigMerge.withSavedDeviceSettings(response.devices, state.existingConfig?.devices);
      state.isResync = false;
      if (state.devices.length === 0) return toast(t("No compatible devices found"), "error");
      state.selected = new Set(state.devices.map((d) => d.serial));
      renderDeviceList();
      go(2);
      toast(tn("Found {n} device!", "Found {n} devices!", state.devices.length));
    } catch (e) {
      go(1);
      showLoginProblem(e.message || t("Failed to fetch devices"),
        "Signing in worked, but reading the device list and local credentials from the Dyson cloud (GET /v2/provisioningservice/manifest) failed.");
    }
  }

  email.addEventListener("input", () => loginProblem.replaceChildren());
  password.addEventListener("input", () => loginProblem.replaceChildren());
  email.addEventListener("keydown", (e) => { if (e.key === "Enter") password.focus(); });
  password.addEventListener("keydown", (e) => { if (e.key === "Enter") connectButton.click(); });
  code.addEventListener("keydown", (e) => { if (e.key === "Enter") verifyButton.click(); });
  code.addEventListener("input", () => {
    codeProblem.replaceChildren();
    code.value = code.value.replace(/\D/g, "").slice(0, 6);
    if (code.value.length === 6) verifyButton.click();
  });

  // MARK: Start

  function detectCountry() {
    const match = (navigator.language || "").match(/-([A-Z]{2})$/i);
    const found = match && match[1].toUpperCase();
    return found && country.querySelector(`option[value="${found}"]`) ? found : null;
  }

  async function init() {
    assistant().then((s) => {
      assistantOn = !!s.enabled;
      assistantHint.classList.toggle("hidden", assistantOn);
    });
    const detected = detectCountry();
    if (detected) country.value = detected;
    try {
      const response = await request("get-product-types");
      if (response.success) {
        productTypes = response.productTypes;
        heatingProductTypes = response.heatingProductTypes || [];
        jetFocusProductTypes = response.jetFocusProductTypes || [];
      }
    } catch (e) {
      console.warn("Failed to load product types:", e);
    }
    try { running = new Map((await request("devices")).devices.map((d) => [d.serial, d])); } catch { /* not running */ }
    let block = null;
    try { block = await readBlock(); } catch (e) { console.warn(e.message); }
    if (block && Array.isArray(block.devices) && block.devices.length > 0) {
      // One bad entry must never leave the page blank: fall back to a fresh setup.
      try {
        state.existingConfig = block;
        loadExisting(block);
        renderExisting();
        go(0);
        return;
      } catch (e) {
        console.error("[Wizard] Failed to render existing devices, starting fresh setup:", e);
      }
    } else if (block) {
      state.existingConfig = null;
      loadExisting(block);
    }
    go(1);
  }

  init();
})();
