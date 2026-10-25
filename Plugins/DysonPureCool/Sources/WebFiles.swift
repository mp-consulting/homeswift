// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DysonPureCoolPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
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

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Dyson Pure Cool page's strings and the errors its plugin answers, in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Connect your Dyson devices to HomeKit.": "Connectez vos appareils Dyson à HomeKit.",
    "Americas": "Amériques",
    "Asia Pacific": "Asie-Pacifique",
    "Europe": "Europe",
    "Middle East": "Moyen-Orient",
    "Account": "Compte",
    "Devices": "Appareils",
    "Options": "Options",
    "Re-sync from Dyson Cloud": "Resynchroniser depuis Dyson Cloud",
    "Sign in again to add devices or refresh their credentials": "Reconnectez-vous pour ajouter des appareils ou renouveler leurs identifiants",
    "Your Dyson devices": "Vos appareils Dyson",
    "Edit options": "Modifier les options",
    "your@email.com": "vous@exemple.com",
    "Your Dyson password": "Votre mot de passe Dyson",
    "Show": "Afficher",
    "Hide": "Masquer",
    "Toggle password visibility": "Afficher ou masquer le mot de passe",
    "Re-enter your credentials to re-sync devices from Dyson Cloud.": "Saisissez à nouveau vos identifiants pour resynchroniser les appareils depuis Dyson Cloud.",
    "Cancel": "Annuler",
    "Connect Account": "Connecter le compte",
    "Tip: add a {block} block to config.json to get the Assistant, which explains sign-in and device connection errors here.": "Astuce : ajoutez un bloc {block} à config.json pour activer l'Assistant, qui explique ici les erreurs de connexion au compte et aux appareils.",
    "Connect your Dyson account": "Connectez votre compte Dyson",
    "Enter your Dyson account credentials to discover your devices. The password is not saved: it is only used to fetch each device's local credentials.": "Saisissez les identifiants de votre compte Dyson pour découvrir vos appareils. Le mot de passe n'est pas enregistré : il sert seulement à récupérer les identifiants locaux de chaque appareil.",
    "Email address": "Adresse e-mail",
    "Password": "Mot de passe",
    "Country": "Pays",
    "Verification code": "Code de vérification",
    "Verify": "Vérifier",
    "Verify your identity": "Vérifiez votre identité",
    "We've sent a verification code to your email. Enter it below.": "Nous avons envoyé un code de vérification à votre adresse e-mail. Saisissez-le ci-dessous.",
    "Check your inbox for an email from Dyson with your verification code.": "Cherchez dans votre boîte de réception un e-mail de Dyson contenant votre code de vérification.",
    "Back": "Retour",
    "Select your devices": "Sélectionnez vos appareils",
    "Choose which devices to add to HomeKit. You can customize the name for each device.": "Choisissez les appareils à ajouter à HomeKit. Vous pouvez personnaliser le nom de chacun.",
    "Continue": "Continuer",
    "Please select at least one device": "Sélectionnez au moins un appareil",
    "Temperature sensor": "Capteur de température",
    "Humidity sensor": "Capteur d'humidité",
    "Air quality sensor": "Capteur de qualité de l'air",
    "Night mode switch": "Interrupteur du mode nuit",
    "Jet focus switch (diffuse/focused)": "Interrupteur Jet Focus (diffus/concentré)",
    "Auto mode switch": "Interrupteur du mode auto",
    "Filter status indicator": "Indicateur d'état du filtre",
    "Save": "Enregistrer",
    "Configure options": "Configurer les options",
    "Customize how your devices appear in HomeKit.": "Personnalisez la façon dont vos appareils apparaissent dans HomeKit.",
    "Sensor options": "Options des capteurs",
    "Additional controls": "Commandes supplémentaires",
    "Advanced": "Avancé",
    "Polling interval (seconds)": "Intervalle d'interrogation (secondes)",
    "How often to check device status (10-300 seconds)": "Fréquence de vérification de l'état des appareils (10 à 300 secondes)",
    "Restart Homeswift": "Redémarrer Homeswift",
    "Configuration complete!": "Configuration terminée !",
    "Close": "Fermer",
    "Dyson Device": "Appareil Dyson",
    "Name": "Nom",
    "Update available": "Mise à jour disponible",
    "Settings": "Réglages",
    "Device settings": "Réglages de l'appareil",
    "Remove": "Supprimer",
    "Remove device": "Supprimer l'appareil",
    "Add to HomeKit": "Ajouter à HomeKit",
    "Continuous monitoring": "Surveillance continue",
    "Keep sensors active when off (required for HomeKit control while off)": "Garde les capteurs actifs à l'arrêt (nécessaire pour le contrôle par HomeKit à l'arrêt)",
    "Temperature offset (°C)": "Décalage de température (°C)",
    "Humidity offset (%)": "Décalage d'humidité (%)",
    "Adjust if your device reads consistently high or low.": "À ajuster si votre appareil indique toujours trop ou trop peu.",
    "Use Fahrenheit": "Utiliser les degrés Fahrenheit",
    "Log temperatures in °F (the Home app follows your device's settings)": "Journalise les températures en °F (l'app Maison suit les réglages de votre appareil)",
    "Thermostat (Recommended)": "Thermostat (recommandé)",
    "Heater Cooler": "Climatiseur",
    "Both": "Les deux",
    "Heating service": "Service de chauffage",
    "Thermostat": "Thermostat",
    "single tile with temperature control": "une seule vignette avec le réglage de la température",
    "a heater tile with the heating threshold": "une vignette de chauffage avec le seuil de chauffe",
    "show both tiles in HomeKit": "affiche les deux vignettes dans HomeKit",
    "Fan": "Ventilateur",
    "Auto": "Auto",
    "Speed {n}": "Vitesse {n}",
    "Off": "Éteint",
    "Temperature": "Température",
    "Humidity": "Humidité",
    "Filter": "Filtre",
    "Connected": "Connecté",
    "Not responding": "Ne répond pas",
    "Connecting": "Connexion…",
    "Continuous monitoring enabled": "Surveillance continue activée",
    "Continuous monitoring disabled": "Surveillance continue désactivée",
    "Failed to set continuous monitoring": "Impossible de régler la surveillance continue",
    "No devices configured. Click {button} to add devices.": "Aucun appareil configuré. Cliquez sur {button} pour en ajouter.",
    "Settings saved": "Réglages enregistrés",
    "Failed to save: {error}": "Échec de l'enregistrement : {error}",
    "Unknown error": "Erreur inconnue",
    "Your Dyson devices are saved. Restart Homeswift to apply the rest ({changes}).": "Vos appareils Dyson sont enregistrés. Redémarrez Homeswift pour appliquer le reste ({changes}).",
    "Your Dyson devices are configured, and the plugin restarted with them. They show up in the Home app with the bridge.": "Vos appareils Dyson sont configurés et le plugin a redémarré avec eux. Ils apparaissent dans l'app Maison avec le pont.",
    "Configuration saved!": "Configuration enregistrée !",
    "Restarting…": "Redémarrage…",
    "Please enter your email and password": "Saisissez votre adresse e-mail et votre mot de passe",
    "Authentication failed": "Échec de l'authentification",
    "Please enter the 6-digit verification code": "Saisissez le code de vérification à 6 chiffres",
    "Verification successful!": "Vérification réussie !",
    "Verification failed": "Échec de la vérification",
    "No compatible devices found": "Aucun appareil compatible trouvé",
    "Failed to fetch devices": "Impossible de récupérer les appareils",
    "Found {n} device!": "{n} appareil trouvé !",
    "Found {n} devices!": "{n} appareils trouvés !",
    "No pending authentication": "Aucune authentification en cours",
    "Invalid verification code": "Code de vérification non valide",
    "Token is required": "Le jeton est requis",
    "Missing device info (serial, productType, localCredentials)": "Informations sur l'appareil manquantes (serial, productType, localCredentials)",
    "Device {0} not found on network": "Appareil {0} introuvable sur le réseau",
    "Failed to get device state: {0}": "Impossible de lire l'état de l'appareil : {0}",
    "Failed to set continuous monitoring: {0}": "Impossible de régler la surveillance continue : {0}",
    "Account not active or not found": "Compte inactif ou introuvable",
    "Unexpected response from Dyson": "Réponse inattendue de Dyson",
    "Session expired": "Session expirée",
    "Network error: {0}": "Erreur réseau : {0}",
    "Request timed out": "La requête a expiré",
    "Invalid response from Dyson API": "Réponse non valide de l'API Dyson",
    "A valid email address is required": "Une adresse e-mail valide est requise",
    "Password is required": "Le mot de passe est requis",
    "Verification code must be 6 digits": "Le code de vérification doit comporter 6 chiffres",
    "Country code must be a 2-letter ISO code": "Le code pays doit être un code ISO à 2 lettres",
    "ipAddress must be a valid IPv4 address": "ipAddress doit être une adresse IPv4 valide"
  },
  "es": {
    "Connect your Dyson devices to HomeKit.": "Conecta tus dispositivos Dyson a HomeKit.",
    "Americas": "América",
    "Asia Pacific": "Asia-Pacífico",
    "Europe": "Europa",
    "Middle East": "Oriente Próximo",
    "Account": "Cuenta",
    "Devices": "Dispositivos",
    "Options": "Opciones",
    "Re-sync from Dyson Cloud": "Volver a sincronizar desde Dyson Cloud",
    "Sign in again to add devices or refresh their credentials": "Vuelve a iniciar sesión para añadir dispositivos o renovar sus credenciales",
    "Your Dyson devices": "Tus dispositivos Dyson",
    "Edit options": "Editar opciones",
    "your@email.com": "tu@email.com",
    "Your Dyson password": "Tu contraseña de Dyson",
    "Show": "Mostrar",
    "Hide": "Ocultar",
    "Toggle password visibility": "Mostrar u ocultar la contraseña",
    "Re-enter your credentials to re-sync devices from Dyson Cloud.": "Vuelve a introducir tus credenciales para sincronizar de nuevo los dispositivos desde Dyson Cloud.",
    "Cancel": "Cancelar",
    "Connect Account": "Conectar cuenta",
    "Tip: add a {block} block to config.json to get the Assistant, which explains sign-in and device connection errors here.": "Consejo: añade un bloque {block} a config.json para tener el Asistente, que explica aquí los errores de inicio de sesión y de conexión con los dispositivos.",
    "Connect your Dyson account": "Conecta tu cuenta de Dyson",
    "Enter your Dyson account credentials to discover your devices. The password is not saved: it is only used to fetch each device's local credentials.": "Introduce las credenciales de tu cuenta de Dyson para descubrir tus dispositivos. La contraseña no se guarda: solo se usa para obtener las credenciales locales de cada dispositivo.",
    "Email address": "Correo electrónico",
    "Password": "Contraseña",
    "Country": "País",
    "Verification code": "Código de verificación",
    "Verify": "Verificar",
    "Verify your identity": "Verifica tu identidad",
    "We've sent a verification code to your email. Enter it below.": "Hemos enviado un código de verificación a tu correo. Introdúcelo a continuación.",
    "Check your inbox for an email from Dyson with your verification code.": "Busca en tu bandeja de entrada un correo de Dyson con tu código de verificación.",
    "Back": "Atrás",
    "Select your devices": "Selecciona tus dispositivos",
    "Choose which devices to add to HomeKit. You can customize the name for each device.": "Elige qué dispositivos añadir a HomeKit. Puedes personalizar el nombre de cada uno.",
    "Continue": "Continuar",
    "Please select at least one device": "Selecciona al menos un dispositivo",
    "Temperature sensor": "Sensor de temperatura",
    "Humidity sensor": "Sensor de humedad",
    "Air quality sensor": "Sensor de calidad del aire",
    "Night mode switch": "Interruptor del modo noche",
    "Jet focus switch (diffuse/focused)": "Interruptor Jet Focus (difuso/concentrado)",
    "Auto mode switch": "Interruptor del modo automático",
    "Filter status indicator": "Indicador del estado del filtro",
    "Save": "Guardar",
    "Configure options": "Configurar opciones",
    "Customize how your devices appear in HomeKit.": "Personaliza cómo aparecen tus dispositivos en HomeKit.",
    "Sensor options": "Opciones de sensores",
    "Additional controls": "Controles adicionales",
    "Advanced": "Avanzado",
    "Polling interval (seconds)": "Intervalo de consulta (segundos)",
    "How often to check device status (10-300 seconds)": "Cada cuánto se comprueba el estado de los dispositivos (10-300 segundos)",
    "Restart Homeswift": "Reiniciar Homeswift",
    "Configuration complete!": "¡Configuración completada!",
    "Close": "Cerrar",
    "Dyson Device": "Dispositivo Dyson",
    "Name": "Nombre",
    "Update available": "Actualización disponible",
    "Settings": "Ajustes",
    "Device settings": "Ajustes del dispositivo",
    "Remove": "Eliminar",
    "Remove device": "Eliminar dispositivo",
    "Add to HomeKit": "Añadir a HomeKit",
    "Continuous monitoring": "Monitorización continua",
    "Keep sensors active when off (required for HomeKit control while off)": "Mantiene los sensores activos con el aparato apagado (necesario para controlarlo desde HomeKit apagado)",
    "Temperature offset (°C)": "Corrección de temperatura (°C)",
    "Humidity offset (%)": "Corrección de humedad (%)",
    "Adjust if your device reads consistently high or low.": "Ajústalo si tu dispositivo marca siempre de más o de menos.",
    "Use Fahrenheit": "Usar Fahrenheit",
    "Log temperatures in °F (the Home app follows your device's settings)": "Registra las temperaturas en °F (la app Casa sigue los ajustes de tu dispositivo)",
    "Thermostat (Recommended)": "Termostato (recomendado)",
    "Heater Cooler": "Climatizador",
    "Both": "Ambos",
    "Heating service": "Servicio de calefacción",
    "Thermostat": "Termostato",
    "single tile with temperature control": "un solo mosaico con control de temperatura",
    "a heater tile with the heating threshold": "un mosaico de calefactor con el umbral de calefacción",
    "show both tiles in HomeKit": "muestra ambos mosaicos en HomeKit",
    "Fan": "Ventilador",
    "Auto": "Auto",
    "Speed {n}": "Velocidad {n}",
    "Off": "Apagado",
    "Temperature": "Temperatura",
    "Humidity": "Humedad",
    "Filter": "Filtro",
    "Connected": "Conectado",
    "Not responding": "No responde",
    "Connecting": "Conectando",
    "Continuous monitoring enabled": "Monitorización continua activada",
    "Continuous monitoring disabled": "Monitorización continua desactivada",
    "Failed to set continuous monitoring": "No se ha podido ajustar la monitorización continua",
    "No devices configured. Click {button} to add devices.": "No hay dispositivos configurados. Haz clic en {button} para añadirlos.",
    "Settings saved": "Ajustes guardados",
    "Failed to save: {error}": "No se ha podido guardar: {error}",
    "Unknown error": "Error desconocido",
    "Your Dyson devices are saved. Restart Homeswift to apply the rest ({changes}).": "Tus dispositivos Dyson se han guardado. Reinicia Homeswift para aplicar el resto ({changes}).",
    "Your Dyson devices are configured, and the plugin restarted with them. They show up in the Home app with the bridge.": "Tus dispositivos Dyson están configurados y el plugin se ha reiniciado con ellos. Aparecen en la app Casa con el puente.",
    "Configuration saved!": "¡Configuración guardada!",
    "Restarting…": "Reiniciando…",
    "Please enter your email and password": "Introduce tu correo y tu contraseña",
    "Authentication failed": "Error de autenticación",
    "Please enter the 6-digit verification code": "Introduce el código de verificación de 6 dígitos",
    "Verification successful!": "¡Verificación correcta!",
    "Verification failed": "Error de verificación",
    "No compatible devices found": "No se han encontrado dispositivos compatibles",
    "Failed to fetch devices": "No se han podido obtener los dispositivos",
    "Found {n} device!": "¡{n} dispositivo encontrado!",
    "Found {n} devices!": "¡{n} dispositivos encontrados!",
    "No pending authentication": "No hay ninguna autenticación pendiente",
    "Invalid verification code": "Código de verificación no válido",
    "Token is required": "El token es obligatorio",
    "Missing device info (serial, productType, localCredentials)": "Falta información del dispositivo (serial, productType, localCredentials)",
    "Device {0} not found on network": "No se ha encontrado el dispositivo {0} en la red",
    "Failed to get device state: {0}": "No se ha podido obtener el estado del dispositivo: {0}",
    "Failed to set continuous monitoring: {0}": "No se ha podido ajustar la monitorización continua: {0}",
    "Account not active or not found": "Cuenta inactiva o no encontrada",
    "Unexpected response from Dyson": "Respuesta inesperada de Dyson",
    "Session expired": "La sesión ha caducado",
    "Network error: {0}": "Error de red: {0}",
    "Request timed out": "Se ha agotado el tiempo de espera de la solicitud",
    "Invalid response from Dyson API": "Respuesta no válida de la API de Dyson",
    "A valid email address is required": "Se necesita un correo electrónico válido",
    "Password is required": "La contraseña es obligatoria",
    "Verification code must be 6 digits": "El código de verificación debe tener 6 dígitos",
    "Country code must be a 2-letter ISO code": "El código de país debe ser un código ISO de 2 letras",
    "ipAddress must be a valid IPv4 address": "ipAddress debe ser una dirección IPv4 válida"
  },
  "pt": {
    "Connect your Dyson devices to HomeKit.": "Ligue os dispositivos Dyson ao HomeKit.",
    "Americas": "Américas",
    "Asia Pacific": "Ásia-Pacífico",
    "Europe": "Europa",
    "Middle East": "Médio Oriente",
    "Account": "Conta",
    "Devices": "Dispositivos",
    "Options": "Opções",
    "Re-sync from Dyson Cloud": "Ressincronizar a partir do Dyson Cloud",
    "Sign in again to add devices or refresh their credentials": "Inicie sessão novamente para adicionar dispositivos ou renovar as credenciais",
    "Your Dyson devices": "Os seus dispositivos Dyson",
    "Edit options": "Editar opções",
    "your@email.com": "nome@email.com",
    "Your Dyson password": "Palavra-passe Dyson",
    "Show": "Mostrar",
    "Hide": "Ocultar",
    "Toggle password visibility": "Mostrar ou ocultar a palavra-passe",
    "Re-enter your credentials to re-sync devices from Dyson Cloud.": "Introduza novamente as credenciais para ressincronizar os dispositivos a partir do Dyson Cloud.",
    "Cancel": "Cancelar",
    "Connect Account": "Ligar conta",
    "Tip: add a {block} block to config.json to get the Assistant, which explains sign-in and device connection errors here.": "Sugestão: adicione um bloco {block} ao config.json para ter o Assistente, que explica aqui os erros de início de sessão e de ligação aos dispositivos.",
    "Connect your Dyson account": "Ligue a conta Dyson",
    "Enter your Dyson account credentials to discover your devices. The password is not saved: it is only used to fetch each device's local credentials.": "Introduza as credenciais da conta Dyson para descobrir os dispositivos. A palavra-passe não é guardada: serve apenas para obter as credenciais locais de cada dispositivo.",
    "Email address": "Endereço de e-mail",
    "Password": "Palavra-passe",
    "Country": "País",
    "Verification code": "Código de verificação",
    "Verify": "Verificar",
    "Verify your identity": "Confirme a sua identidade",
    "We've sent a verification code to your email. Enter it below.": "Foi enviado um código de verificação para o seu e-mail. Introduza-o abaixo.",
    "Check your inbox for an email from Dyson with your verification code.": "Procure na caixa de entrada um e-mail da Dyson com o código de verificação.",
    "Back": "Voltar",
    "Select your devices": "Selecione os dispositivos",
    "Choose which devices to add to HomeKit. You can customize the name for each device.": "Escolha os dispositivos a adicionar ao HomeKit. É possível personalizar o nome de cada um.",
    "Continue": "Continuar",
    "Please select at least one device": "Selecione pelo menos um dispositivo",
    "Temperature sensor": "Sensor de temperatura",
    "Humidity sensor": "Sensor de humidade",
    "Air quality sensor": "Sensor de qualidade do ar",
    "Night mode switch": "Interruptor do modo noturno",
    "Jet focus switch (diffuse/focused)": "Interruptor Jet Focus (difuso/concentrado)",
    "Auto mode switch": "Interruptor do modo automático",
    "Filter status indicator": "Indicador do estado do filtro",
    "Save": "Guardar",
    "Configure options": "Configurar opções",
    "Customize how your devices appear in HomeKit.": "Personalize a forma como os dispositivos aparecem no HomeKit.",
    "Sensor options": "Opções dos sensores",
    "Additional controls": "Controlos adicionais",
    "Advanced": "Avançado",
    "Polling interval (seconds)": "Intervalo de consulta (segundos)",
    "How often to check device status (10-300 seconds)": "Frequência de verificação do estado dos dispositivos (10-300 segundos)",
    "Restart Homeswift": "Reiniciar o Homeswift",
    "Configuration complete!": "Configuração concluída!",
    "Close": "Fechar",
    "Dyson Device": "Dispositivo Dyson",
    "Name": "Nome",
    "Update available": "Atualização disponível",
    "Settings": "Definições",
    "Device settings": "Definições do dispositivo",
    "Remove": "Remover",
    "Remove device": "Remover dispositivo",
    "Add to HomeKit": "Adicionar ao HomeKit",
    "Continuous monitoring": "Monitorização contínua",
    "Keep sensors active when off (required for HomeKit control while off)": "Mantém os sensores ativos com o aparelho desligado (necessário para o controlo pelo HomeKit quando desligado)",
    "Temperature offset (°C)": "Correção de temperatura (°C)",
    "Humidity offset (%)": "Correção de humidade (%)",
    "Adjust if your device reads consistently high or low.": "Ajuste se o dispositivo indicar valores sempre acima ou abaixo do real.",
    "Use Fahrenheit": "Usar Fahrenheit",
    "Log temperatures in °F (the Home app follows your device's settings)": "Regista as temperaturas em °F (a app Casa segue as definições do dispositivo)",
    "Thermostat (Recommended)": "Termóstato (recomendado)",
    "Heater Cooler": "Climatizador",
    "Both": "Ambos",
    "Heating service": "Serviço de aquecimento",
    "Thermostat": "Termóstato",
    "single tile with temperature control": "um único mosaico com controlo da temperatura",
    "a heater tile with the heating threshold": "um mosaico de aquecedor com o limiar de aquecimento",
    "show both tiles in HomeKit": "mostra os dois mosaicos no HomeKit",
    "Fan": "Ventoinha",
    "Auto": "Auto",
    "Speed {n}": "Velocidade {n}",
    "Off": "Desligado",
    "Temperature": "Temperatura",
    "Humidity": "Humidade",
    "Filter": "Filtro",
    "Connected": "Ligado",
    "Not responding": "Não responde",
    "Connecting": "A ligar",
    "Continuous monitoring enabled": "Monitorização contínua ativada",
    "Continuous monitoring disabled": "Monitorização contínua desativada",
    "Failed to set continuous monitoring": "Não foi possível definir a monitorização contínua",
    "No devices configured. Click {button} to add devices.": "Nenhum dispositivo configurado. Clique em {button} para adicionar dispositivos.",
    "Settings saved": "Definições guardadas",
    "Failed to save: {error}": "Não foi possível guardar: {error}",
    "Unknown error": "Erro desconhecido",
    "Your Dyson devices are saved. Restart Homeswift to apply the rest ({changes}).": "Os dispositivos Dyson foram guardados. Reinicie o Homeswift para aplicar o resto ({changes}).",
    "Your Dyson devices are configured, and the plugin restarted with them. They show up in the Home app with the bridge.": "Os dispositivos Dyson estão configurados e o plugin reiniciou com eles. Aparecem na app Casa com a ponte.",
    "Configuration saved!": "Configuração guardada!",
    "Restarting…": "A reiniciar…",
    "Please enter your email and password": "Introduza o e-mail e a palavra-passe",
    "Authentication failed": "Falha na autenticação",
    "Please enter the 6-digit verification code": "Introduza o código de verificação de 6 dígitos",
    "Verification successful!": "Verificação concluída!",
    "Verification failed": "Falha na verificação",
    "No compatible devices found": "Nenhum dispositivo compatível encontrado",
    "Failed to fetch devices": "Não foi possível obter os dispositivos",
    "Found {n} device!": "{n} dispositivo encontrado!",
    "Found {n} devices!": "{n} dispositivos encontrados!",
    "No pending authentication": "Nenhuma autenticação pendente",
    "Invalid verification code": "Código de verificação inválido",
    "Token is required": "O token é obrigatório",
    "Missing device info (serial, productType, localCredentials)": "Faltam informações do dispositivo (serial, productType, localCredentials)",
    "Device {0} not found on network": "Dispositivo {0} não encontrado na rede",
    "Failed to get device state: {0}": "Não foi possível obter o estado do dispositivo: {0}",
    "Failed to set continuous monitoring: {0}": "Não foi possível definir a monitorização contínua: {0}",
    "Account not active or not found": "Conta inativa ou não encontrada",
    "Unexpected response from Dyson": "Resposta inesperada da Dyson",
    "Session expired": "A sessão expirou",
    "Network error: {0}": "Erro de rede: {0}",
    "Request timed out": "O pedido expirou",
    "Invalid response from Dyson API": "Resposta inválida da API da Dyson",
    "A valid email address is required": "É necessário um endereço de e-mail válido",
    "Password is required": "A palavra-passe é obrigatória",
    "Verification code must be 6 digits": "O código de verificação tem de ter 6 dígitos",
    "Country code must be a 2-letter ISO code": "O código do país tem de ser um código ISO de 2 letras",
    "ipAddress must be a valid IPv4 address": "ipAddress tem de ser um endereço IPv4 válido"
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dyson Pure Cool</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's setup wizard on the UI's materials: the devices already set up, then account →
     code → devices → options, one step showing at a time. */
  .page-head { align-items: center; }
  .tile.dyson { background: linear-gradient(160deg, #c3c9d6, #6f7a8f); }
  .steps { display: flex; gap: 6px; list-style: none; margin: 0 0 18px; padding: 0; flex-wrap: wrap; }
  .steps li { display: inline-flex; align-items: center; gap: 8px; padding: 5px 12px 5px 5px; border-radius: 999px; color: var(--muted); font-weight: 500; }
  .steps li::before {
    content: attr(data-n); width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-size: 0.8125rem;
    background: var(--material-thin); border: 1px solid var(--edge); font-variant-numeric: tabular-nums;
  }
  .steps li.current { color: var(--text); background: var(--material-thin); }
  .steps li.current::before { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: transparent; }
  .steps li.done::before { content: "✓"; color: var(--ok); }
  .step { animation: fade var(--normal) var(--ease-out); }
  .step h2 { margin-top: 0; }
  .step > p.muted { margin-top: 0; }

  .form { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 4px 16px; }
  .form .wide { grid-column: 1 / -1; }
  .with-button { display: flex; gap: 8px; align-items: center; }
  .with-button input { flex: 1; }
  .status-line { margin: 14px 0 0; min-height: 1.2em; }
  .status-line.error { color: var(--error); }
  .status-line.ok { color: var(--ok); }
  .status-line .explain { display: block; }
  .hint { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }
  .code-input { max-width: 260px; text-align: center; font-size: 1.5rem; letter-spacing: 0.5em; font-family: var(--mono); }

  .devices { display: grid; gap: 10px; }
  .device { margin: 0; display: grid; gap: 12px; animation: materialize var(--normal) var(--ease-out); }
  .device.selectable { cursor: pointer; }
  @media (hover: hover) and (pointer: fine) { .device.selectable:not(.selected):hover { box-shadow: 0 0 0 1px var(--edge), var(--shadow-control, none); } }
  .device.selected { box-shadow: 0 0 0 2px var(--accent), var(--shadow-control, none); }
  .device-head { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .device-head .who { flex: 1; min-width: 0; }
  .device-head .who input { font-weight: 600; }
  .device-head .muted { font-size: 0.8125rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .badges { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 4px; }
  .badge { font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.02em; padding: 2px 8px; border-radius: 999px; background: var(--material-thin); border: 1px solid var(--line); color: var(--muted); }
  .badge.update { color: var(--warn); border-color: rgba(201, 115, 26, 0.35); }
  .settings { border-top: 1px solid var(--line); padding-top: 10px; display: grid; gap: 10px; }
  .settings .row2 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px 16px; }
  .toggle-row { display: flex; align-items: center; gap: 12px; }
  .toggle-row label:last-child { margin: 0; }
  .toggle-row small { display: block; color: var(--muted); font-size: 0.75rem; }
  .heating-help { margin: 4px 0 0; padding-left: 18px; font-size: 0.75rem; color: var(--muted); }
  .device-problem { font-size: 0.8125rem; color: var(--warn); }
  .facts.live { grid-template-columns: repeat(auto-fill, minmax(110px, 1fr)); }

  .options h3 { margin: 18px 0 6px; font-size: 0.9375rem; }
  .options h3:first-child { margin-top: 0; }
  .options .toggle-row { padding: 6px 0; }
  .polling { max-width: 140px; }
  .done-icon { font-size: 2.4rem; color: var(--ok); text-align: center; margin: 8px 0; }
  .center { text-align: center; }

  .busy::after {
    content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
    border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) {
    .step, .device { animation: none; }
    .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  }
  @media (max-width: 640px) { .form, .settings .row2 { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large dyson" aria-hidden="true"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" opacity="0.35"/><circle cx="12" cy="12" r="6" opacity="0.6"/><circle cx="12" cy="12" r="3"/></svg></span>
    <div class="who">
      <h1>Dyson Pure Cool</h1>
      <p class="muted" data-i18n>Connect your Dyson devices to HomeKit.</p>
    </div>
  </div>
  <div id="wizard" class="card"></div>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="merge.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
        "merge.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// Merges the setup wizard's output into this instance's saved block, as the Homebridge plugin's
// config-merge.js: the wizard renders only part of the block, so the keys it does not write are kept
// (isSingleAccessoryModeEnabled, enableHeater, _bridge, per-device overrides), and `devices` follows the
// wizard's list, each entry matched to the saved one by serial number.
(function (root) {
  "use strict";
  // Per-device keys the wizard edits: when it leaves one out, the user turned it off or reset it, so a
  // saved value must not come back.
  const WIZARD_DEVICE_SETTINGS = ["isContinuousMonitoringEnabled", "heatingServiceType", "temperatureOffset", "humidityOffset", "useFahrenheit"];

  const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  const withoutUndefined = (object) => Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));

  function savedDevicesBySerial(savedDevices) {
    const bySerial = new Map();
    for (const device of Array.isArray(savedDevices) ? savedDevices : []) {
      if (isObject(device) && typeof device.serial === "string" && !bySerial.has(device.serial)) bySerial.set(device.serial, device);
    }
    return bySerial;
  }

  function mergeDevice(saved, built) {
    const kept = { ...saved };
    for (const key of WIZARD_DEVICE_SETTINGS) delete kept[key];
    return { ...kept, ...withoutUndefined(built) };
  }

  /// The block to save: `existing` (the saved block, may be undefined) updated with `built` (the wizard's fields).
  function mergePluginConfig(existing, built) {
    const base = isObject(existing) ? existing : {};
    const saved = savedDevicesBySerial(base.devices);
    const devices = (Array.isArray(built.devices) ? built.devices : []).map((device) => {
      const savedDevice = saved.get(device.serial);
      return savedDevice ? mergeDevice(savedDevice, device) : withoutUndefined(device);
    });
    return { ...base, ...withoutUndefined(built), devices };
  }

  /// Devices fetched from the Dyson cloud carry no wizard settings: the saved ones (offsets, heating service…)
  /// are copied onto them by serial, so a re-sync does not reset them.
  function withSavedDeviceSettings(cloudDevices, savedDevices) {
    const saved = savedDevicesBySerial(savedDevices);
    return (Array.isArray(cloudDevices) ? cloudDevices : []).map((device) => {
      const savedDevice = isObject(device) ? saved.get(device.serial) : undefined;
      if (!savedDevice) return device;
      const settings = {};
      for (const key of WIZARD_DEVICE_SETTINGS) {
        if (savedDevice[key] !== undefined && device[key] === undefined) settings[key] = savedDevice[key];
      }
      return { ...device, ...settings };
    });
  }

  root.DysonConfigMerge = { mergePluginConfig, withSavedDeviceSettings, WIZARD_DEVICE_SETTINGS };
})(globalThis);

"""#),
    ]
}
