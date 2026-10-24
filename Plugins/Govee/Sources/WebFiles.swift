// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension GoveePlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The Govee page on the UI's materials: the Homebridge plugin's three tabs (devices, settings, tools), a list
   per device type, an editor per device (a light's in three tabs: general, scene library, music mode), and the
   scene picker with the Govee app's icons. */

.page-head { align-items: center; }
.main-tabs { margin: 18px 0 14px; }
.tab-pane { animation: fade var(--normal) var(--ease-out); }
h2 { margin: 0 0 10px; }
h3 { margin: 0 0 8px; font-size: 0.9375rem; }

.discover-head { display: flex; justify-content: space-between; align-items: center; gap: 14px; flex-wrap: wrap; }
.discover-head p { margin: 0; flex: 1; min-width: 220px; font-size: 0.875rem; }
.found { list-style: none; margin: 14px 0 0; padding: 0; display: grid; gap: 6px; max-height: 400px; overflow-y: auto; }
.found li { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 8px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); }
.found li > div { min-width: 0; }
.found .mono { font-size: 0.8125rem; overflow-wrap: anywhere; user-select: all; }
.summary { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; border: 1px solid var(--line); background: var(--material-thin); font-size: 0.875rem; }
.summary.ok { color: var(--ok); }

/* One section per device type: a count, its devices as rows, and an Add button. */
details.type { margin: 0 0 10px; border-radius: 18px; }
details.type > summary .count { min-width: 26px; text-align: center; }
details.type.empty > summary .entry-name { color: var(--muted); }
.type-body { padding: 0 14px 12px; }
.rows { display: grid; gap: 6px; margin: 4px 0 10px; }
.row-device { display: flex; align-items: center; gap: 12px; padding: 8px 10px 8px 14px; border-radius: 14px; background: var(--control); border: 1px solid var(--edge); }
.row-device .who { flex: 1; min-width: 0; }
.row-device .who strong { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row-device .mono { font-size: 0.75rem; color: var(--muted); overflow-wrap: anywhere; }
.row-device.ignored .who { opacity: 0.5; }
.row-device .links { display: inline-flex; gap: 4px; flex: none; }
.transports { display: inline-flex; gap: 4px; margin-left: 6px; vertical-align: middle; }
.transports .pill { font-size: 0.6875rem; padding: 1px 7px; }

/* The device editor. */
.editor { scroll-margin-top: 90px; animation: materialize var(--normal) var(--ease-out); }
.editor-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; margin-bottom: 12px; }
.editor-head h2 { margin: 0; overflow-wrap: anywhere; }
.editor .tabs { margin-bottom: 12px; flex-wrap: wrap; }
.icon-select { display: flex; flex-wrap: wrap; }
.range { display: flex; align-items: center; gap: 12px; }
.range input { flex: 1; width: auto; }
.range output { min-width: 72px; text-align: right; font-variant-numeric: tabular-nums; }
.sub { margin: 4px 0 0 60px; }

/* The scene library: the selection on top, the library below with its categories down the side. */
.scene-panel { border: 1px solid var(--line); border-radius: 18px; overflow: hidden; margin-bottom: 16px; }
.scene-panel-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 16px; background: var(--material-thin); }
.scene-panel-head p { margin: 2px 0 0; font-size: 0.8125rem; }
.scene-panel-body { padding: 12px 16px; }
.scene-empty { text-align: center; padding: 10px; color: var(--muted); font-size: 0.875rem; }
.scene-strip { display: flex; flex-wrap: wrap; gap: 8px; }
.scene-chip { display: inline-flex; align-items: center; gap: 8px; padding: 4px 6px 4px 4px; border-radius: 999px; background: var(--control); border: 1px solid var(--edge); max-width: 240px; }
.scene-chip span.name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.8125rem; }
.scene-chip button { padding: 0 6px; min-height: 0; font-size: 1rem; line-height: 1.4; }
.scene-icon { width: 28px; height: 28px; border-radius: 8px; object-fit: cover; flex: none; background: var(--material-thin); display: inline-block; }
.scene-icon.large { width: 52px; height: 52px; border-radius: 14px; }
.scene-icon.empty { border: 1px dashed var(--line); }
.picker { display: grid; grid-template-columns: minmax(140px, 200px) minmax(0, 1fr); gap: 14px; }
.picker-cats { display: grid; gap: 4px; align-content: start; max-height: 460px; overflow-y: auto; }
.picker-cats button { display: flex; justify-content: space-between; gap: 8px; text-align: left; border: 0; background: none; box-shadow: none; padding: 7px 10px; border-radius: 12px; }
.picker-cats button:hover { transform: none; background: var(--material-thin); }
.picker-cats button.on { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); }
.picker-cats .count { opacity: 0.7; font-variant-numeric: tabular-nums; }
.picker-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 8px; max-height: 460px; overflow-y: auto; align-content: start; padding: 2px; }
.tile-scene { display: grid; justify-items: center; gap: 6px; padding: 10px 6px; border-radius: 16px; position: relative; text-align: center; font-size: 0.75rem; }
.tile-scene.selected { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent); }
.tile-scene .name { overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.tile-scene .variants { position: absolute; top: 6px; right: 6px; }
.picker-foot { display: flex; justify-content: space-between; gap: 12px; margin-top: 10px; font-size: 0.8125rem; }
.picker-foot .warn { color: var(--warn); text-align: right; }
.notice { margin: 0 0 10px; padding: 8px 12px; border-radius: 12px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }

/* Settings. */
.password { display: flex; gap: 8px; }
.password input { flex: 1; }
.connections { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 240px), 1fr)); gap: 18px; }
.docs { margin: 0; padding-left: 20px; font-size: 0.875rem; }
.docs li { margin: 4px 0; }
.save-card { position: sticky; bottom: 12px; z-index: 3; margin-top: 18px; }
.save-card .save-bar { border-top: 0; padding-top: 0; }
.problem { margin-top: 12px; }
.problem p { margin: 0; }
.busy::after {
  content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
  border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }

@media (max-width: 640px) {
  .picker { grid-template-columns: 1fr; }
  .picker-cats { grid-auto-flow: column; grid-auto-columns: max-content; overflow-x: auto; max-height: none; }
  .sub { margin-left: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .tab-pane, .editor { animation: none; }
  .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
}

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Govee page, after the Homebridge plugin's settings page: Devices (discover the account's devices, a list per
// device type, an editor per device; a light's editor has its Scene Library and Music Mode tabs), Settings (the
// account with Test Connection, general options, the three connections) and Tools (clear the cache). Changes are
// kept by Save Configuration, which writes this instance's block; the plugin reloads with it.
(() => {
  "use strict";
  const { $, el, request, name, platform, explain, breadcrumb, api, readBlock, updateBlock, poll } = homeswift;

  const plural = (count, one, other) => `${count} ${count === 1 ? one : other}`;
  const clamp = (value, min, max, fallback) => {
    const number = Number(value);
    if (value === null || value === "" || value === undefined || !Number.isFinite(number)) return fallback;
    return Math.min(max ?? Infinity, Math.max(min ?? -Infinity, number));
  };

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors reach the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Device types, as the Homebridge page lists them

  const typeNames = {
    lightDevices: { one: "light", other: "lights", title: "Light Devices", add: "Add Light Device", badge: "Light" },
    switchDevices: { one: "switch/outlet", other: "switches/outlets", title: "Switch/Outlet Devices", add: "Add Switch Device", badge: "Switch/Outlet" },
    thermoDevices: { one: "temperature/humidity sensor", other: "temperature/humidity sensors", title: "Temperature/Humidity Sensors", add: "Add Sensor", badge: "Temp/Humidity Sensor" },
    leakDevices: { one: "leak sensor", other: "leak sensors", title: "Leak Sensors", add: "Add Leak Sensor", badge: "Leak Sensor" },
    fanDevices: { one: "fan", other: "fans", title: "Fan Devices", add: "Add Fan", badge: "Fan" },
    heaterDevices: { one: "heater", other: "heaters", title: "Heater Devices", add: "Add Heater", badge: "Heater" },
    humidifierDevices: { one: "humidifier", other: "humidifiers", title: "Humidifier Devices", add: "Add Humidifier", badge: "Humidifier" },
    purifierDevices: { one: "air purifier", other: "air purifiers", title: "Air Purifier Devices", add: "Add Purifier", badge: "Air Purifier" },
    dehumidifierDevices: { one: "dehumidifier", other: "dehumidifiers", title: "Dehumidifier Devices", add: "Add Dehumidifier", badge: "Dehumidifier" },
    diffuserDevices: { one: "diffuser", other: "diffusers", title: "Diffuser Devices", add: "Add Diffuser", badge: "Diffuser" },
    kettleDevices: { one: "kettle", other: "kettles", title: "Kettle Devices", add: "Add Kettle", badge: "Kettle" },
    iceMakerDevices: { one: "ice maker", other: "ice makers", title: "Ice Maker Devices", add: "Add Ice Maker", badge: "Ice Maker" },
  };

  const basic = [
    { id: "deviceId", label: "Device ID", type: "text", required: true },
    { id: "label", label: "Custom Label", type: "text" },
    { id: "ignoreDevice", label: "Ignore Device", type: "checkbox" },
  ];

  const deviceTypes = {
    lightDevices: {
      // A light does far more than the others, so its editor has tabs; `mode` hides a tab Govee says the light lacks.
      tabs: [
        { id: "general", title: "General" },
        { id: "scenes", title: "Scene Library", mode: "scene" },
        { id: "music", title: "Music Mode", mode: "music" },
      ],
      fields: [
        { id: "deviceId", label: "Device ID", type: "text", required: true, help: "Govee's own identifier for this light. Discover Devices fills it in for you." },
        { id: "label", label: "Custom Label", type: "text", help: "Replaces the name HomeKit shows. Leave blank to keep the name set in the Govee app." },
        { id: "ignoreDevice", label: "Ignore Device", type: "checkbox", help: "Keeps this light out of HomeKit without discarding any of the settings below." },
        { id: "showAs", label: "Show As", type: "select", help: "A Light gets brightness and colour controls. Pick Switch for a light you only ever turn on and off.",
          options: [["default", "Light (default)"], ["switch", "Switch"]] },
        { id: "musicModeLive.enabled", label: "Add a Music tile to HomeKit", type: "checkbox", tab: "music",
          help: "Adds a second tile for this light. On/off starts music mode, brightness is the microphone sensitivity, and colour sets the music colour." },
        { id: "musicModeLive.effect", label: "Effect", type: "iconselect", default: "rhythm", tab: "music",
          help: "How the light reacts to sound. Rhythm follows the beat, Energic flashes on peaks, Rolling sweeps colour along the strip, and Spectrum maps pitch to colour.",
          options: [["rhythm", "Rhythm"], ["energic", "Energic"], ["rolling", "Rolling"], ["spectrum", "Spectrum"]] },
        { id: "musicModeLive.sensitivity", label: "Default Sensitivity", type: "range", min: 0, max: 100, step: 5, default: 50, unit: "%", tab: "music",
          help: "How loud a sound must be before the light reacts. Only the starting value: the tile's brightness slider changes it live." },
        { id: "musicModeLive.autoColour", label: "Auto Colour", type: "checkbox", default: true, tab: "music",
          help: "Let the light pick colours from the music itself. Turn this off to choose the colour yourself, from the tile's colour picker." },
        { id: "musicModeLive.soft", label: "Soft Rhythm", type: "checkbox", tab: "music", help: "Rhythm only: the gentler of its two styles, with slower fades between beats." },
        { id: "musicModeLive.protocol", label: "Protocol", type: "select", tab: "music",
          help: "Older lights speak an earlier version of the music command. If the tile appears but does nothing, switch to Legacy.",
          options: [["modern", "Modern"], ["legacy", "Legacy (older lights)"]] },
        { id: "customIPAddress", label: "Custom IP Address", type: "text", advanced: true,
          help: "Only for LAN control, when the light is not found automatically. Pair it with a DHCP reservation so the address does not move." },
        { id: "customAddress", label: "Custom BLE Address", type: "text", advanced: true,
          help: "The light's Bluetooth MAC address. Only needed when Bluetooth control cannot find the device by name." },
        { id: "brightnessStep", label: "Brightness Step", type: "range", min: 1, max: 100, step: 1, default: 1, unit: "%", advanced: true,
          help: "Smallest brightness change HomeKit will send. Raise it to stop a dragged slider flooding the light with updates." },
        { id: "adaptiveLightingShift", label: "Adaptive Lighting", type: "togglerange", advanced: true, offValue: -1, default: 0, min: 0, max: 500, step: 10,
          unit: " mireds", rangeLabel: "Warmth shift",
          help: "Lets HomeKit track the colour temperature to the time of day. Turn it off to keep whatever colour you set.",
          rangeHelp: "Biases the curve warmer than Apple's. 150 keeps evenings noticeably cosier; 0 follows HomeKit exactly." },
        { id: "awsBrightnessNoScale", label: "AWS Brightness No Scale", type: "checkbox", advanced: true,
          help: "Sends brightness as 0-100 instead of 0-254. A few models need this, otherwise they jump straight to full brightness." },
        { id: "awsColourMode", label: "AWS Colour Mode", type: "select", advanced: true,
          help: "Which shape of colour command this model accepts over the cloud connection. Change it only if colours are ignored or come out wrong.",
          options: [["default", "Default"], ["rgb", "RGB"], ["redgreenblue", "Red/Green/Blue"]] },
      ],
    },
    switchDevices: {
      fields: [...basic,
        { id: "showAs", label: "Show As", type: "select", options: [
          ["default", "Default (Switch)"], ["outlet", "Outlet"], ["switch", "Switch"], ["purifier", "Air Purifier"], ["heater", "Heater"],
          ["cooler", "Cooler"], ["tap", "Tap/Faucet"], ["valve", "Valve"], ["audio", "Audio Receiver"], ["box", "Set-Top Box"], ["stick", "Streaming Stick"]] },
        { id: "temperatureSource", label: "Temperature Source (Device ID)", type: "text", advanced: true,
          help: "For a plug shown as a heater or a cooler: the Govee thermo-hygrometer whose temperature switches it." }],
    },
    thermoDevices: { fields: [...basic, { id: "lowBattThreshold", label: "Low Battery Threshold (%)", type: "number", min: 1, max: 100, default: 20 }, { id: "showExtraSwitch", label: "Show Extra Switch", type: "checkbox" }] },
    leakDevices: { fields: [...basic, { id: "lowBattThreshold", label: "Low Battery Threshold (%)", type: "number", min: 1, max: 100, default: 20 }] },
    fanDevices: { fields: [...basic, { id: "hideLight", label: "Hide Light Control", type: "checkbox" }] },
    heaterDevices: { fields: [...basic, { id: "tempReporting", label: "Temperature Reporting", type: "checkbox" }] },
    humidifierDevices: { fields: basic },
    purifierDevices: { fields: basic },
    dehumidifierDevices: { fields: basic },
    diffuserDevices: { fields: basic },
    kettleDevices: { fields: [...basic,
      { id: "hideModeGreenTea", label: "Hide Green Tea Mode", type: "checkbox", advanced: true },
      { id: "hideModeOolongTea", label: "Hide Oolong Tea Mode", type: "checkbox", advanced: true },
      { id: "hideModeCoffee", label: "Hide Coffee Mode", type: "checkbox", advanced: true },
      { id: "hideModeBlackTea", label: "Hide Black Tea Mode", type: "checkbox", advanced: true },
      { id: "showCustomMode1", label: "Show Custom Mode 1", type: "checkbox", advanced: true },
      { id: "showCustomMode2", label: "Show Custom Mode 2", type: "checkbox", advanced: true }] },
    iceMakerDevices: { fields: basic },
  };

  // MARK: State

  let config = { platform, name };   // this instance's block, as edited here until saved
  let saved = "";
  const deviceMeta = {};              // Govee's product identifiers by device id, from discovery
  const sceneLibraries = {};          // cloud scene libraries by device id
  const capabilities = {};            // the modes Govee says a device has; null: unknown, show everything
  const iconCache = new Map();
  const openTypes = new Set();
  let editing = null;                 // { type, index, tab, advanced }
  let live = {};                      // the running devices by id: name, transports

  const getField = (object, path) => path.split(".").reduce((value, key) => (value == null ? undefined : value[key]), object);
  function setField(object, path, value) {
    const keys = path.split(".");
    const last = keys.pop();
    let target = object;
    for (const key of keys) {
      if (typeof target[key] !== "object" || target[key] === null) target[key] = {};
      target = target[key];
    }
    if (value === undefined) delete target[last]; else target[last] = value;
  }

  /// The type list a model goes in; unknown models are lights.
  const typeFor = (model, given) => (given && typeNames[given] ? given : "lightDevices");

  function displayName(type, index, device) {
    if (device.label || device.deviceId) return device.label || device.deviceId;
    const devices = config[type] || [];
    const position = devices.slice(0, index).filter((d) => !d?.label && !d?.deviceId).length + 1;
    const noun = typeNames[type].one;
    return position === 1 ? `New ${noun}` : `New ${noun} ${position}`;
  }

  const dirty = () => JSON.stringify(readSettings({ ...config })) !== saved;
  function markDirty() {
    const state = $("#save-state");
    const changed = dirty();
    state.className = changed ? "dirty" : "muted";
    state.textContent = changed ? "Unsaved changes" : "Changes are kept once you save.";
  }

  // MARK: Problems, with the Assistant's Explain when there is one

  /// Error text for the Assistant: Govee's device ids (six to eight bytes) masked; the server masks e-mail and IP
  /// addresses.
  const scrub = (text) => String(text ?? "").replace(/\b[0-9a-f]{2}(?::[0-9a-f]{2}){5,7}\b/gi, "<device id>");

  function problem(container, message, context, device, kind = "error") {
    container.replaceChildren(el("div", { class: "problem" }, el("p", { class: kind, text: message }), explain({ error: scrub(message), context, device })));
  }

  function context(extra) {
    const checked = (id) => !!$(`#${id}`)?.checked;
    const disabled = [["awsDisable", "AWS IoT"], ["lanDisable", "LAN"], ["bleDisable", "BLE"]].filter(([id]) => checked(id)).map(([, label]) => label);
    const count = Object.keys(deviceTypes).reduce((sum, type) => sum + (config[type]?.length || 0), 0);
    const login = credentials();
    return [extra,
      login.username && login.password ? "Govee account email and password are entered." : "No Govee account credentials are entered (LAN and BLE only).",
      login.code ? "A verification code is entered." : "",
      disabled.length ? `Disabled connections: ${disabled.join(", ")}.` : "AWS IoT, LAN and BLE are all enabled.",
      checked("ignoreMatter") ? "Matter-capable models are ignored." : "",
      `${count} device(s) in the configuration.`].filter(Boolean).join(" ");
  }

  /// Device facts the Assistant may see: no id, address or credentials.
  function assistantDevice(type, device) {
    const meta = deviceMeta[device.deviceId] || {};
    return { label: device.label, model: meta.model, configList: type, foundInGoveeAccount: meta.goodsType !== undefined, customIpAddressSet: !!device.customIPAddress, ignored: !!device.ignoreDevice };
  }

  // MARK: config.json

  async function save(button) {
    await act(button, async () => {
      const state = $("#save-state");
      try {
        readSettings(config);
        for (const type of Object.keys(deviceTypes)) if (config[type] && config[type].length === 0) delete config[type];
        const result = await updateBlock(() => config);
        saved = JSON.stringify(config);
        const pending = result.restartNeeded || [];
        state.className = "ok";
        state.textContent = pending.length ? `Saved. Restart Homeswift to apply: ${pending.join("; ")}.` : "Saved: the plugin restarted with the new configuration.";
        $("#restart").classList.toggle("hidden", pending.length === 0);
      } catch (e) {
        state.className = "error";
        state.textContent = `Failed to save configuration: ${e.message}`;
      }
    });
  }

  // MARK: Settings tab

  const textFields = ["username", "password", "code"];
  const numberFields = [
    ["httpRefreshTime", "aws", "HTTP Refresh (seconds)", 30, 30, "How often to poll the Govee API for sensor readings. Minimum 30 seconds; leave blank for the default of 30."],
    ["lanRefreshTime", "lan", "Refresh (seconds)", 10, 30, "How often to poll LAN devices for their state. Leave blank for the default of 30."],
    ["lanScanInterval", "lan", "Scan Interval (seconds)", 30, 60, "How often to scan the network for new LAN-capable devices. Minimum 30 seconds; leave blank for the default of 60."],
    ["bleRefreshTime", "ble", "Refresh (seconds)", 60, 300, "How often to scan for BLE sensor readings. Minimum 60 seconds; leave blank for the default of 300."],
    ["bleControlInterval", "ble", "Control Interval (ms)", 500, 500, "Minimum time between BLE commands, so devices are not overwhelmed. Minimum 500 ms; leave blank for the default of 500."],
  ];
  const booleanFields = [
    ["ignoreMatter", "general", "Ignore Matter Devices", "Skip devices that support Matter. Enable this if you connect those devices to HomeKit through Matter directly."],
    ["disableDeviceLogging", "general", "Disable Device Logging", "Stop logging device state changes to reduce log clutter. Errors are still logged."],
    ["colourSafeMode", "general", "Colour Safe Mode", "A slower but more reliable way of setting colours. Enable this if your lights show colour problems."],
    ["debug", "general", "Debug Logging", "Verbose debug logging in the Homeswift log."],
    ["awsDisable", "aws", "Disable", "Disable real-time cloud control through AWS IoT. Not recommended unless you have connection problems."],
    ["lanDisable", "lan", "Disable", "Disable local network control. LAN is faster and works without internet; disable it only on network problems."],
    ["bleDisable", "ble", "Disable", "Disable Bluetooth control and sensor scanning."],
  ];

  function toggleRow(id, label, help) {
    const input = el("input", { type: "checkbox", id });
    input.addEventListener("change", markDirty);
    return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
      el("span", {}, el("span", { class: "field-title", text: label }), help ? el("span", { class: "help", text: help }) : null));
  }

  function buildSettings() {
    for (const [id, group, label, help] of booleanFields) $(group === "general" ? "#general" : `#connection-${group}`).append(toggleRow(id, label, help));
    for (const [id, group, label, min, fallback, help] of numberFields) {
      const input = el("input", { type: "number", id, min, step: 1, placeholder: String(fallback), inputmode: "numeric" });
      input.addEventListener("input", markDirty);
      input.addEventListener("change", () => {
        const value = parseInt(input.value, 10);
        if (!Number.isNaN(value)) input.value = clamp(value, min, undefined, value);
      });
      $(`#connection-${group}`).append(el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, el("span", { class: "help", text: help })));
    }
    for (const id of textFields) $(`#${id}`).addEventListener("input", markDirty);
    $("#toggle-password").addEventListener("click", () => {
      const field = $("#password");
      field.type = field.type === "password" ? "text" : "password";
      $("#toggle-password").textContent = field.type === "password" ? "Show" : "Hide";
    });
  }

  function fillSettings() {
    for (const id of textFields) $(`#${id}`).value = config[id] || "";
    for (const [id] of numberFields) $(`#${id}`).value = config[id] ?? "";
    for (const [id] of booleanFields) $(`#${id}`).checked = !!config[id];
  }

  /// Copies the Settings tab into `target`: texts when filled, numbers when typed (held to their minimum), the toggles.
  function readSettings(target) {
    for (const id of textFields) {
      const value = $(`#${id}`).value.trim();
      if (value) target[id] = value; else delete target[id];
    }
    for (const [id, , , min] of numberFields) {
      const value = parseInt($(`#${id}`).value, 10);
      if (Number.isNaN(value)) { delete target[id]; continue; }
      // A value already in the file stays as it is: the plugin takes some older forms (bleControlInterval in seconds).
      target[id] = value === config[id] ? value : clamp(value, min, undefined, value);
    }
    for (const [id] of booleanFields) {
      if ($(`#${id}`).checked) target[id] = true;
      else if (id in target || id !== "debug") target[id] = false;
    }
    if (!target.debug) delete target.debug;
    return target;
  }

  const credentials = () => ({
    username: $("#username").value.trim(),
    password: $("#password").value,
    code: $("#code").value.trim() || undefined,
  });

  async function testLogin(button) {
    const result = $("#login-result");
    const login = credentials();
    if (!login.username || !login.password) {
      result.replaceChildren(el("p", { class: "status-line error", text: "Please enter your username and password." }));
      return;
    }
    result.replaceChildren();
    await act(button, async () => {
      try {
        const answer = await request("test-login", { method: "POST", body: login });
        if (answer.success) {
          result.replaceChildren(el("p", { class: "status-line ok", text: answer.message }));
        } else if (answer.twoFactorRequired) {
          // Govee just emailed a code: a prompt, not a failure.
          result.replaceChildren(el("p", { class: "status-line", text: answer.message }));
          $("#code").focus();
        } else {
          problem(result, answer.message || "Connection failed",
            context(answer.twoFactorInvalid ? "Test Connection logged in to the Govee cloud with a verification code, and Govee rejected the code."
              : "Test Connection tried to log in to the Govee cloud (app2.govee.com) from the plugin settings and Govee refused."), undefined, "error");
          if (answer.twoFactorInvalid) $("#code").focus();
        }
      } catch (e) {
        problem(result, e.message || "Connection failed", context("Test Connection could not complete a Govee cloud login from the plugin settings."));
      }
    });
  }

  // MARK: Devices tab

  function transportsOf(device) {
    const running = live[device.deviceId];
    if (!running) return null;
    const pill = (label, state) => (state === "unsupported" ? null : el("span", { class: `pill ${state === "enabled" ? "on" : ""}`, text: label, title: `${label}: ${state}` }));
    return el("span", { class: "transports" }, pill("LAN", running.lan), pill("AWS", running.aws), pill("BLE", running.ble));
  }

  /// Redraws the lists; the editor moves with its section, and the field being typed in keeps the caret.
  function renderTypes() {
    const active = document.activeElement;
    const keep = active && editor.contains(active) ? { active, start: active.selectionStart, end: active.selectionEnd } : null;
    drawTypes();
    if (keep && document.contains(keep.active)) {
      keep.active.focus();
      try { if (typeof keep.start === "number") keep.active.setSelectionRange(keep.start, keep.end); } catch { /* inputs without a caret */ }
    }
  }

  function drawTypes() {
    const container = $("#device-types");
    container.replaceChildren(...Object.keys(deviceTypes).map((type) => {
      const devices = config[type] || [];
      const names = typeNames[type];
      const section = el("details", { class: `entry type ${devices.length ? "" : "empty"}`, open: openTypes.has(type) },
        el("summary", {}, el("span", { class: `pill count ${devices.length ? "on" : ""}`, text: String(devices.length) }), el("span", { class: "entry-name", text: names.title })),
        el("div", { class: "type-body" },
          devices.length
            ? el("div", { class: "rows" }, devices.map((device, index) => {
              const label = displayName(type, index, device);
              return el("div", { class: `row-device ${device.ignoreDevice ? "ignored" : ""}` },
                el("div", { class: "who" },
                  el("strong", {}, label, device.ignoreDevice ? el("span", { class: "pill", text: "Ignored" }) : null, transportsOf(device)),
                  device.deviceId ? el("span", { class: "mono", text: device.deviceId }) : null),
                el("span", { class: "links" },
                  el("button", { class: "link", text: "Edit", "aria-label": `Edit ${label}`, onclick: () => edit(type, index) }),
                  el("button", { class: "link danger", text: "Remove", "aria-label": `Remove ${label}`, onclick: () => remove(type, index) })));
            }))
            : el("p", { class: "muted note", text: "No devices configured." }),
          el("button", { text: `+ ${names.add}`, onclick: () => add(type) }),
          // The open editor sits in its type's section, under the list, as on the Homebridge page.
          editing && editing.type === type ? editor : null));
      section.addEventListener("toggle", () => { if (section.open) openTypes.add(type); else openTypes.delete(type); });
      return section;
    }));
  }

  function add(type) {
    config[type] = config[type] || [];
    config[type].push({ deviceId: "" });
    openTypes.add(type);
    renderTypes();
    edit(type, config[type].length - 1);
    markDirty();
  }

  function remove(type, index) {
    const device = config[type]?.[index];
    if (!device) return;
    if (!confirm(`Remove "${displayName(type, index, device)}" and its settings from the configuration? The change is kept once you click Save Configuration.`)) return;
    config[type].splice(index, 1);
    if (config[type].length === 0) delete config[type];
    if (editing && editing.type === type) closeEditor();
    renderTypes();
    markDirty();
  }

  // MARK: The device editor

  const editor = $("#editor");

  function edit(type, index) {
    editing = { type, index, tab: "general", advanced: false };
    openTypes.add(type);
    renderTypes();
    editor.classList.remove("hidden");
    renderEditor();
    breadcrumb(`Edit ${displayName(type, index, config[type][index])}`, closeEditor);
    editor.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
    loadCapabilities(type, index);
  }

  function closeEditor() {
    editing = null;
    pickerTarget = null;
    editor.classList.add("hidden");
    editor.replaceChildren();
    breadcrumb(null);
    renderTypes();
  }

  /// A field applies unless Govee says the device lacks its mode; unknown capabilities show everything.
  const applies = (item, device) => !item.mode || !capabilities[device.deviceId] || capabilities[device.deviceId].includes(item.mode);

  function fieldControl(type, index, field) {
    const device = config[type][index];
    const value = getField(device, field.id);
    const changed = (newValue) => {
      setField(device, field.id, newValue);
      markDirty();
      if (field.id === "deviceId" || field.id === "label" || field.id === "ignoreDevice") renderTypes();
    };
    const help = field.help ? el("span", { class: "help", text: field.help }) : null;
    switch (field.type) {
    case "checkbox": {
      const input = el("input", { type: "checkbox", checked: !!(value ?? field.default) });
      input.addEventListener("change", () => changed(input.checked));
      return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
        el("span", {}, el("span", { class: "field-title", text: field.label }), help));
    }
    case "iconselect": {
      const current = value ?? field.default;
      const group = el("div", { class: "group icon-select", role: "radiogroup", "aria-label": field.label });
      for (const [optionValue, label] of field.options) {
        const button = el("button", { type: "button", text: label, role: "radio", class: current === optionValue ? "on" : "", "aria-checked": String(current === optionValue) });
        button.addEventListener("click", () => {
          changed(optionValue);
          for (const other of group.children) {
            other.classList.toggle("on", other === button);
            other.setAttribute("aria-checked", String(other === button));
          }
        });
        group.append(button);
      }
      return el("div", { class: "field" }, el("span", { class: "field-title", text: field.label }), group, help);
    }
    case "range": {
      // A hand-edited value the slider cannot show is displayed clamped; it is rewritten only when moved.
      const fallback = field.default ?? field.min ?? 0;
      const current = clamp(value ?? fallback, field.min ?? 0, field.max ?? 100, fallback);
      const output = el("output", { text: `${current}${field.unit || ""}` });
      const input = el("input", { type: "range", min: field.min ?? 0, max: field.max ?? 100, step: field.step ?? 1, value: current });
      input.addEventListener("input", () => { output.textContent = `${input.value}${field.unit || ""}`; changed(parseInt(input.value, 10)); });
      return el("div", { class: "field" }, el("span", { class: "field-title", text: field.label }), el("div", { class: "range" }, input, output), help);
    }
    case "togglerange": {
      // One number that means two things: the "off" value, or an amount.
      const isOn = value === undefined ? true : value !== field.offValue;
      let amount = value === undefined || value === field.offValue ? field.default : clamp(value, field.min, field.max, field.default);
      const toggle = el("input", { type: "checkbox", checked: isOn });
      const output = el("output", { text: `${amount}${field.unit || ""}` });
      const range = el("input", { type: "range", min: field.min, max: field.max, step: field.step, value: amount });
      const body = el("div", { class: `sub ${isOn ? "" : "hidden"}` },
        el("span", { class: "field-title", text: field.rangeLabel }), el("div", { class: "range" }, range, output),
        field.rangeHelp ? el("span", { class: "help", text: field.rangeHelp }) : null);
      toggle.addEventListener("change", () => { body.classList.toggle("hidden", !toggle.checked); changed(toggle.checked ? amount : field.offValue); });
      range.addEventListener("input", () => { amount = parseInt(range.value, 10); output.textContent = `${amount}${field.unit || ""}`; changed(amount); });
      return el("div", {}, el("label", { class: "toggle" }, el("span", { class: "switch" }, toggle, el("span")),
        el("span", {}, el("span", { class: "field-title", text: field.label }), help)), body);
    }
    case "select": {
      const select = el("select", {}, field.options.map(([optionValue, label]) => el("option", { value: optionValue, text: label, selected: (value ?? field.options[0][0]) === optionValue })));
      select.addEventListener("change", () => changed(select.value));
      return el("label", { class: "field" }, el("span", { class: "field-title", text: field.label }), select, help);
    }
    default: {
      const input = el("input", { type: field.type, value: value ?? "", placeholder: field.default !== undefined ? String(field.default) : "", min: field.min, max: field.max, spellcheck: false, autocomplete: "off" });
      input.addEventListener("input", () => {
        if (field.type === "number") {
          const number = parseInt(input.value, 10);
          changed(Number.isNaN(number) ? undefined : clamp(number, field.min, field.max, number));
        } else {
          changed(input.value.trim() || undefined);
        }
      });
      input.addEventListener("change", () => { if (field.type === "number" && input.value !== "") input.value = clamp(parseInt(input.value, 10), field.min, field.max, input.value); });
      return el("label", { class: "field" }, el("span", { class: "field-title", text: `${field.label}${field.required ? " *" : ""}` }), input, help);
    }
    }
  }

  function fieldsBlock(type, index, fields) {
    const plain = fields.filter((f) => !f.advanced);
    const advanced = fields.filter((f) => f.advanced);
    const blocks = [];
    if (plain.length) blocks.push(el("div", { class: "fields" }, plain.map((f) => fieldControl(type, index, f))));
    if (advanced.length) {
      const details = el("details", { class: "group-box", open: editing.advanced }, el("summary", { text: "Advanced settings" }),
        el("div", { class: "fields" }, advanced.map((f) => fieldControl(type, index, f))));
      details.addEventListener("toggle", () => { editing.advanced = details.open; });
      blocks.push(details);
    }
    return blocks;
  }

  function renderEditor() {
    if (!editing) return;
    const { type, index } = editing;
    const device = config[type][index];
    const typeConfig = deviceTypes[type];
    const fields = typeConfig.fields.filter((f) => applies(f, device));
    let body;
    let tabs = null;
    if (typeConfig.tabs) {
      const panes = typeConfig.tabs.filter((tab) => applies(tab, device))
        .filter((tab) => tab.id === "scenes" || fields.some((f) => (f.tab || "general") === tab.id));
      if (!panes.some((tab) => tab.id === editing.tab)) editing.tab = panes[0].id;
      if (panes.length > 1) {
        tabs = el("div", { class: "group tabs", role: "tablist" }, panes.map((tab) => el("button", {
          text: tab.title, role: "tab", class: tab.id === editing.tab ? "on" : "", "aria-selected": String(tab.id === editing.tab),
          onclick: () => { editing.tab = tab.id; renderEditor(); },
        })));
      }
      body = editing.tab === "scenes" ? scenesTab(type, index) : fieldsBlock(type, index, fields.filter((f) => (f.tab || "general") === editing.tab));
    } else {
      body = fieldsBlock(type, index, fields);
    }
    editor.replaceChildren(
      el("div", { class: "editor-head" },
        el("div", {}, el("h2", { text: displayName(type, index, device) }), el("p", { class: "muted note", text: `${typeNames[type].badge}${deviceMeta[device.deviceId]?.model ? ` · ${deviceMeta[device.deviceId].model}` : ""}` })),
        el("button", { class: "link", text: "Back", onclick: closeEditor })),
      tabs, el("div", {}, body));
    if (editing.tab === "scenes" && typeConfig.tabs) loadPicker(type, index);
  }

  /// Asks Govee which modes the device has and redraws when it knows; failures leave everything shown.
  async function loadCapabilities(type, index) {
    const device = config[type]?.[index];
    if (!device?.deviceId || capabilities[device.deviceId] !== undefined) return;
    const payload = devicePayload(device);
    if (!payload.model || !payload.username || !payload.password) return;
    try {
      const answer = await request("device-capabilities", { method: "POST", body: payload });
      capabilities[device.deviceId] = answer?.modes || null;
      if (answer?.modes && editing && editing.type === type && editing.index === index && editing.tab !== "scenes") renderEditor();
    } catch {
      capabilities[device.deviceId] = null;
    }
  }

  function devicePayload(device) {
    const meta = deviceMeta[device.deviceId] || {};
    return { ...credentials(), deviceId: device.deviceId, model: meta.model || device.model || "", goodsType: meta.goodsType, pactType: meta.pactType, pactCode: meta.pactCode, versionSoft: meta.versionSoft, versionHard: meta.versionHard };
  }

  // MARK: The scene library

  let pickerTarget = null;   // { type, index }
  let pickerItems = {};
  let pickerCategory = null;

  function scenesTab(type, index) {
    return [
      el("div", { id: "selected-scenes" }, selectedScenes(type, index)),
      el("h3", { text: "Add from the Govee library" }),
      el("div", { id: "picker-status" }),
      el("div", { id: "picker-body" }, el("p", { class: "muted", text: "Loading scenes…" })),
      el("div", { class: "picker-foot" }, el("span", { id: "picker-count", class: "muted" }), el("span", { id: "picker-warning", class: "warn" })),
    ];
  }

  function iconFor(scene, large = false) {
    const url = scene.iconUrl || scene.iconUrlDark;
    const className = `scene-icon ${large ? "large" : ""}`;
    if (!url) return el("span", { class: `${className} empty`, "aria-hidden": "true" });
    const cached = iconCache.get(url);
    const image = el("img", { class: className, alt: "" });
    if (cached) image.src = cached; else image.dataset.iconUrl = url;
    return image;
  }

  function selectedScenes(type, index) {
    const chosen = config[type][index].scenes || [];
    const sceneCount = chosen.filter((s) => s.kind !== "diy").length;
    const diyCount = chosen.length - sceneCount;
    const summary = chosen.length === 0 ? "Nothing selected yet"
      : [sceneCount ? plural(sceneCount, "scene", "scenes") : "", diyCount ? plural(diyCount, "DIY effect", "DIY effects") : ""].filter(Boolean).join(" · ");
    const body = chosen.length === 0
      ? el("div", { class: "scene-empty" }, el("p", { text: "No scenes selected. Pick scenes and your own DIY effects from the library below; each becomes its own switch in HomeKit." }))
      : el("div", { class: "scene-strip" }, chosen.map((scene, sceneIndex) => el("span", { class: "scene-chip", title: scene.name || "" },
        iconFor(scene), el("span", { class: "name", text: scene.name || "Scene" }), scene.kind === "diy" ? el("span", { class: "pill", text: "DIY" }) : null,
        el("button", { class: "link", text: "×", "aria-label": `Remove ${scene.name || "scene"}`, onclick: () => {
          chosen.splice(sceneIndex, 1);
          if (chosen.length === 0) delete config[type][index].scenes;
          refreshSelection();
        } }))));
    return el("div", { class: "scene-panel" },
      el("div", { class: "scene-panel-head" },
        el("div", {}, el("strong", { text: "Selected scenes" }), el("p", { class: "muted", text: summary })),
        chosen.length ? el("button", { class: "danger", text: "Clear all", onclick: () => { delete config[type][index].scenes; refreshSelection(); } }) : null),
      el("div", { class: "scene-panel-body" }, body));
  }

  async function loadPicker(type, index) {
    const device = config[type]?.[index];
    const body = $("#picker-body");
    if (!body || !device) return;
    pickerTarget = { type, index };
    if (body.dataset.loadedFor && body.dataset.loadedFor === device.deviceId) { refreshPicker(); return; }
    if (!device.deviceId) {
      body.replaceChildren(el("p", { class: "notice", text: "Enter the device ID on the General tab and its scenes will appear here." }));
      return;
    }
    const payload = devicePayload(device);
    if (!payload.model) {
      body.replaceChildren(el("p", { class: "notice", text: "This device's model is unknown. Run Discover Devices first so the plugin knows which scenes to offer." }));
      return;
    }
    try {
      let library = sceneLibraries[device.deviceId];
      if (!library) {
        library = await request("scenes", { method: "POST", body: payload });
        // The bundled fallback is never kept: credentials entered later must reach the device's own list.
        if (library?.source !== "offline") sceneLibraries[device.deviceId] = library;
      }
      let diys = [];
      try { diys = (await request("diys", { method: "POST", body: payload }))?.diys || []; } catch { diys = []; }
      if (!$("#picker-body")) return;
      renderPicker(library, diys);
      $("#picker-body").dataset.loadedFor = device.deviceId;
    } catch (e) {
      problem(body, e.message || "Could not load scenes",
        "Loading the Govee scene library and DIY effects for one device in the plugin settings failed (the bundled catalogue had no entry for this model either).",
        assistantDevice(type, device));
    }
  }

  function renderPicker(library, diys) {
    const body = $("#picker-body");
    const notes = [];
    if (library.source === "offline") notes.push("Showing the scene list bundled with the plugin. Log in and rediscover for the full, device-specific list.");
    if (library.warning) notes.push(library.warning);
    $("#picker-status").replaceChildren(...notes.map((note) => el("p", { class: "notice", text: note })));

    const groups = library.categories.map((category) => ({
      id: `cat-${category.id}`, name: category.name,
      items: category.scenes.map((scene) => ({
        key: `scene:${scene.sceneId}`, name: scene.name, iconUrl: scene.iconUrl, iconUrlDark: scene.iconUrlDark, variants: scene.variants,
        payload: { name: scene.name, sceneCode: scene.code, sceneId: scene.sceneId, variantId: scene.variants[0]?.id, iconUrl: scene.iconUrl, iconUrlDark: scene.iconUrlDark, kind: "scene" },
      })),
    }));
    if (diys.length) {
      groups.push({ id: "cat-diy", name: "My DIY", items: diys.map((diy) => ({
        key: `diy:${diy.diyId}`, name: diy.name, iconUrl: diy.iconUrl, variants: [],
        payload: { name: diy.name, sceneCode: diy.code, sceneId: diy.diyId, iconUrl: diy.iconUrl, kind: "diy" },
      })) });
    }
    if (!groups.length) {
      body.replaceChildren(el("p", { class: "notice", text: "Govee returned no scenes for this device." }));
      return;
    }
    pickerItems = {};
    for (const group of groups) for (const item of group.items) pickerItems[item.key] = item;
    if (!groups.some((g) => g.id === pickerCategory)) pickerCategory = groups[0].id;

    const grid = el("div", { class: "picker-grid" });
    const showCategory = (group) => {
      pickerCategory = group.id;
      for (const button of cats.children) button.classList.toggle("on", button.dataset.id === group.id);
      grid.replaceChildren(...group.items.map((item) => el("button", { class: "tile-scene", "data-key": item.key, "aria-pressed": "false", title: item.name, onclick: () => toggleScene(item.key) },
        iconFor(item, true), el("span", { class: "name", text: item.name }),
        item.variants.length > 1 ? el("span", { class: "pill variants", text: String(item.variants.length) }) : null)));
      refreshPicker();
      hydrateIcons(grid);
    };
    // Categories down the side: their names are long and a strip across the top had to scroll.
    const cats = el("div", { class: "picker-cats", role: "tablist" }, groups.map((group) => el("button", {
      "data-id": group.id, role: "tab", onclick: () => showCategory(group),
    }, el("span", { text: group.name }), el("span", { class: "count", text: String(group.items.length) }))));
    body.replaceChildren(el("div", { class: "picker" }, cats, grid));
    showCategory(groups.find((g) => g.id === pickerCategory));
  }

  const selectionKey = (scene) => `${scene.kind || "scene"}:${scene.sceneId}`;

  function toggleScene(key) {
    const item = pickerItems[key];
    if (!item || !pickerTarget) return;
    const device = config[pickerTarget.type]?.[pickerTarget.index];
    if (!device) return;
    device.scenes = Array.isArray(device.scenes) ? device.scenes : [];
    const existing = device.scenes.findIndex((scene) => selectionKey(scene) === key);
    if (existing >= 0) device.scenes.splice(existing, 1); else device.scenes.push({ ...item.payload });
    if (device.scenes.length === 0) delete device.scenes;
    refreshSelection();
  }

  /// A selection change shows in both halves, without redrawing the picker (its category and scroll stay).
  function refreshSelection() {
    markDirty();
    const panel = $("#selected-scenes");
    if (!panel || !pickerTarget) { renderEditor(); return; }
    panel.replaceChildren(selectedScenes(pickerTarget.type, pickerTarget.index));
    hydrateIcons(panel);
    refreshPicker();
  }

  function refreshPicker() {
    const device = config[pickerTarget?.type]?.[pickerTarget?.index];
    const selected = new Set((device?.scenes || []).map(selectionKey));
    for (const tile of document.querySelectorAll("#picker-body .tile-scene")) {
      const on = selected.has(tile.dataset.key);
      tile.classList.toggle("selected", on);
      tile.setAttribute("aria-pressed", String(on));
    }
    const count = $("#picker-count");
    const warning = $("#picker-warning");
    if (!count || !warning) return;
    count.textContent = `${plural(selected.size, "scene", "scenes")} selected`;
    // HomeKit refuses accessories with too many services: a warning well before that.
    warning.textContent = selected.size > 50
      ? `${selected.size} scenes means ${selected.size} HomeKit switches on this accessory. Much beyond this and HomeKit may refuse to add it — consider trimming the list.` : "";
  }

  // MARK: Scene icons, proxied by the plugin in batches as their tiles come into view

  const iconQueue = new Map();
  let iconTimer = null;

  async function flushIcons() {
    iconTimer = null;
    const pending = [...iconQueue];
    iconQueue.clear();
    for (let start = 0; start < pending.length; start += 60) {
      const batch = pending.slice(start, start + 60);
      try {
        const icons = (await request("scene-icons", { method: "POST", body: { urls: batch.map(([url]) => url) } }))?.icons || {};
        for (const [url, images] of batch) {
          if (icons[url]) iconCache.set(url, icons[url]);
          for (const image of images) { if (icons[url]) image.src = icons[url]; else image.classList.add("empty"); }
        }
      } catch {
        for (const [, images] of batch) images.forEach((image) => image.classList.add("empty"));
      }
    }
  }

  function queueIcon(image) {
    const url = image.dataset.iconUrl;
    if (!url) return;
    delete image.dataset.iconUrl;
    if (iconCache.has(url)) { image.src = iconCache.get(url); return; }
    if (iconQueue.has(url)) { iconQueue.get(url).push(image); return; }
    iconQueue.set(url, [image]);
    if (!iconTimer) iconTimer = setTimeout(flushIcons, 60);
  }

  function hydrateIcons(root) {
    const pending = root.querySelectorAll("img[data-icon-url]");
    if (!pending.length) return;
    if (typeof IntersectionObserver !== "function") { pending.forEach(queueIcon); return; }
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) { observer.unobserve(entry.target); queueIcon(entry.target); }
    }, { rootMargin: "200px" });
    pending.forEach((image) => observer.observe(image));
  }

  const hydrateObserver = new MutationObserver(() => hydrateIcons(editor));
  hydrateObserver.observe(editor, { childList: true, subtree: true });

  // MARK: Discovery

  /// Adds the devices the plugin found at its start (account and LAN) that the lists do not have yet.
  async function loadCachedDevices() {
    try {
      const answer = await request("cached-devices");
      for (const device of answer.devices || []) {
        if (!device.deviceId) continue;
        deviceMeta[device.deviceId] = { model: device.model, goodsType: device.goodsType, pactType: device.pactType, pactCode: device.pactCode, versionSoft: device.versionSoft, versionHard: device.versionHard };
        const type = typeFor(device.model, device.deviceType);
        config[type] = config[type] || [];
        // The LAN address is never copied: discovery is unauthenticated, and a custom address is pinned for good.
        if (!config[type].some((d) => d.deviceId === device.deviceId)) config[type].push({ deviceId: device.deviceId, label: device.deviceName || "Unknown" });
      }
    } catch { /* cached devices are optional */ }
  }

  async function discover(button) {
    const result = $("#discover-result");
    const login = credentials();
    if (!login.username || !login.password) {
      result.replaceChildren(el("p", { class: "status-line error", text: "Please enter your username and password in the Settings tab." }));
      return;
    }
    result.replaceChildren();
    await act(button, async () => {
      try {
        const devices = (await request("discover", { method: "POST", body: login })).devices || [];
        if (!devices.length) { result.replaceChildren(el("p", { class: "summary", text: "No devices found." })); return; }
        let added = 0;
        let skipped = 0;
        const addedByType = {};
        for (const device of devices) {
          if (!device.deviceId) continue;
          deviceMeta[device.deviceId] = { model: device.model, goodsType: device.goodsType, pactType: device.pactType, pactCode: device.pactCode, versionSoft: device.versionSoft, versionHard: device.versionHard };
          const type = typeFor(device.model, device.deviceType);
          config[type] = config[type] || [];
          if (config[type].some((d) => d.deviceId === device.deviceId)) { skipped++; continue; }
          config[type].push({ deviceId: device.deviceId, label: device.deviceName || "Unknown" });
          added++;
          addedByType[type] = (addedByType[type] || 0) + 1;
          openTypes.add(type);
        }
        renderTypes();
        markDirty();
        const blocks = [];
        if (added) {
          blocks.push(el("div", { class: "summary ok" }, el("strong", { text: `Added ${plural(added, "new device", "new devices")}: ` }),
            Object.entries(addedByType).map(([type, count]) => plural(count, typeNames[type].one, typeNames[type].other)).join(", "),
            ". Click Save Configuration to keep them."));
        }
        if (skipped) blocks.push(el("p", { class: "summary", text: `${plural(skipped, "device was", "devices were")} already in the configuration.` }));
        blocks.push(el("ul", { class: "found" }, devices.map((device) => el("li", {},
          el("div", {}, el("strong", { text: device.deviceName || "Unknown" }), " ",
            el("span", { class: "pill", text: typeNames[typeFor(device.model, device.deviceType)].badge }),
            el("div", { class: "muted note", text: `Model: ${device.model || "Unknown"}` })),
          el("span", { class: "mono", text: device.deviceId || "" })))));
        result.replaceChildren(...blocks);
      } catch (e) {
        problem(result, `Error: ${e.message || "Unknown error"}`, context("Discover Devices logged in to the Govee cloud and asked for the account's device list, and it failed."));
      }
    });
  }

  // MARK: Tools

  async function clearCache(button) {
    if (!confirm("Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards.")) return;
    const result = $("#clear-result");
    await act(button, async () => {
      try {
        const answer = await request("clear-cache", { method: "POST", body: {} });
        if (answer.success) {
          result.replaceChildren(el("p", { class: "status-line ok", text: answer.message }));
          $("#restart").classList.remove("hidden");
        } else {
          problem(result, answer.message || "Cache partially cleared", "Clear Cache deletes the plugin's saved login, IoT certificate and device data; some could not be removed.", undefined, "error");
        }
      } catch (e) {
        problem(result, e.message || "Failed to clear cache", "Clear Cache (the plugin's saved login, IoT certificate and device data) failed.");
      }
    });
  }

  async function restart(button) {
    await act(button, async () => {
      await api("/api/restart", { method: "POST", body: {} });
      $("#save-state").textContent = "Restarting…";
      for (let tries = 0; tries < 60; tries++) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        try { await request("devices"); break; } catch { /* not back yet */ }
      }
      location.reload();
    });
  }

  // MARK: Start

  for (const button of document.querySelectorAll(".main-tabs button")) {
    button.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".main-tabs button")) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`).classList.toggle("hidden", !on);
      }
    });
  }
  $("#discover").addEventListener("click", (event) => discover(event.currentTarget));
  $("#test-login").addEventListener("click", (event) => testLogin(event.currentTarget));
  $("#clear-cache").addEventListener("click", (event) => clearCache(event.currentTarget));
  $("#restart").addEventListener("click", (event) => restart(event.currentTarget));
  $("#save").addEventListener("click", (event) => save(event.currentTarget));
  window.addEventListener("beforeunload", (event) => { if (dirty()) event.preventDefault(); });

  async function refreshLive() {
    try {
      const answer = await request("devices");
      const next = {};
      for (const device of answer.devices || []) next[device.deviceId] = device;
      const changed = JSON.stringify(next) !== JSON.stringify(live);
      live = next;
      if (changed) renderTypes();
    } catch { /* the plugin may be restarting */ }
  }

  (async () => {
    buildSettings();
    try {
      config = await readBlock();
    } catch (e) {
      $("#save-state").className = "error";
      $("#save-state").textContent = e.message;
    }
    fillSettings();
    saved = JSON.stringify(readSettings({ ...config }));
    await loadCachedDevices();
    for (const type of Object.keys(deviceTypes)) if (config[type]?.length) openTypes.add(type);
    renderTypes();
    markDirty();
    poll(refreshLive, 5000);
  })();
})();

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Govee</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large light" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/></svg></span>
    <div class="who">
      <h1>Govee</h1>
      <p class="muted">Your Govee account, the devices it brings to the Home app and how each one appears, scenes and music mode for lights, and the connections the plugin uses.</p>
    </div>
  </div>

  <div class="group tabs main-tabs" role="tablist">
    <button role="tab" data-tab="devices" class="on" aria-selected="true">Devices</button>
    <button role="tab" data-tab="settings" aria-selected="false">Settings</button>
    <button role="tab" data-tab="tools" aria-selected="false">Tools</button>
  </div>

  <section id="tab-devices" class="tab-pane">
    <div class="card discover">
      <div class="discover-head">
        <p class="muted">Discover all devices linked to your Govee account and add them to the lists below. Enter your credentials in the <strong>Settings</strong> tab first.</p>
        <button id="discover" class="primary">Discover Devices</button>
      </div>
      <div id="discover-result"></div>
    </div>
    <div id="device-types"></div>
    <div id="editor" class="card editor hidden"></div>
  </section>

  <section id="tab-settings" class="tab-pane hidden">
    <div class="card">
      <h2>Account</h2>
      <div class="fields">
        <label class="field"><span class="field-title">Email</span>
          <input type="email" id="username" placeholder="your-email@example.com" autocomplete="username">
          <span class="help">The email address you use to log in to the Govee app. Required for cloud control and device discovery.</span></label>
        <label class="field"><span class="field-title">Password</span>
          <span class="password"><input type="password" id="password" autocomplete="current-password"><button type="button" id="toggle-password">Show</button></span>
          <span class="help">Your Govee account password. Stored in config.json and used only to authenticate with Govee's servers.</span></label>
        <label class="field"><span class="field-title">Verification Code</span>
          <input type="text" id="code" placeholder="e.g. 1234" autocomplete="one-time-code" inputmode="numeric">
          <span class="help">Only needed the first time, or when Govee flags a new device. If Test Connection reports that a code was emailed to you, paste it here and test again. Ignored once login succeeds.</span></label>
      </div>
      <div class="actions"><button id="test-login">Test Connection</button></div>
      <div id="login-result"></div>
    </div>

    <div class="card">
      <h2>General</h2>
      <div id="general"></div>
    </div>

    <div class="card">
      <h2>Connection</h2>
      <div class="connections">
        <div><h3>AWS IoT</h3><div id="connection-aws"></div></div>
        <div><h3>LAN</h3><div id="connection-lan"></div></div>
        <div><h3>Bluetooth (BLE)</h3><div id="connection-ble"></div></div>
      </div>
    </div>
  </section>

  <section id="tab-tools" class="tab-pane hidden">
    <div class="card">
      <h2>Cache Management</h2>
      <p class="muted">Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.</p>
      <div class="actions"><button id="clear-cache" class="danger">Clear Cache</button><button id="restart" class="hidden">Restart Homeswift</button></div>
      <div id="clear-result"></div>
    </div>
    <div class="card">
      <h2>Documentation</h2>
      <p>The options are described in the plugin's README; the connections are tried in this order:</p>
      <ul class="docs">
        <li><strong>LAN:</strong> local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.</li>
        <li><strong>AWS IoT:</strong> real-time control through Govee's cloud (requires credentials).</li>
        <li><strong>BLE:</strong> Bluetooth control for nearby devices (requires a Bluetooth adapter).</li>
      </ul>
    </div>
  </section>

  <div class="card save-card">
    <div class="save-bar"><span id="save-state" class="muted">Changes are kept once you save.</span><button id="save" class="primary">Save Configuration</button></div>
  </div>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
