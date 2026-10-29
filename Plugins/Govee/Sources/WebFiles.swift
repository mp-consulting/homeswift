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
.picker-cats button:hover { transform: none; }
@media (hover: hover) and (pointer: fine) { .picker-cats button:not(.on):hover { background: var(--material-thin); } }
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
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, name, platform, explain, breadcrumb, api, readBlock, updateBlock, poll } = homeswift;

  const clamp = (value, min, max, fallback) => {
    const number = Number(value);
    if (value === null || value === "" || value === undefined || !Number.isFinite(number)) return fallback;
    return Math.min(max ?? Infinity, Math.max(min ?? -Infinity, number));
  };

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors reach the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Device types, as the Homebridge page lists them

  // `count` says how many there are, `fresh` names a device not given an id yet.
  const typeNames = {
    lightDevices: { count: (n) => tn("{n} light", "{n} lights", n), fresh: t("New light"), title: t("Light Devices"), add: t("Add Light Device"), badge: t("Light") },
    switchDevices: { count: (n) => tn("{n} switch/outlet", "{n} switches/outlets", n), fresh: t("New switch/outlet"), title: t("Switch/Outlet Devices"), add: t("Add Switch Device"), badge: t("Switch/Outlet") },
    thermoDevices: { count: (n) => tn("{n} temperature/humidity sensor", "{n} temperature/humidity sensors", n), fresh: t("New temperature/humidity sensor"), title: t("Temperature/Humidity Sensors"), add: t("Add Sensor"), badge: t("Temp/Humidity Sensor") },
    leakDevices: { count: (n) => tn("{n} leak sensor", "{n} leak sensors", n), fresh: t("New leak sensor"), title: t("Leak Sensors"), add: t("Add Leak Sensor"), badge: t("Leak Sensor") },
    fanDevices: { count: (n) => tn("{n} fan", "{n} fans", n), fresh: t("New fan"), title: t("Fan Devices"), add: t("Add Fan"), badge: t("Fan") },
    heaterDevices: { count: (n) => tn("{n} heater", "{n} heaters", n), fresh: t("New heater"), title: t("Heater Devices"), add: t("Add Heater"), badge: t("Heater") },
    humidifierDevices: { count: (n) => tn("{n} humidifier", "{n} humidifiers", n), fresh: t("New humidifier"), title: t("Humidifier Devices"), add: t("Add Humidifier"), badge: t("Humidifier") },
    purifierDevices: { count: (n) => tn("{n} air purifier", "{n} air purifiers", n), fresh: t("New air purifier"), title: t("Air Purifier Devices"), add: t("Add Purifier"), badge: t("Air Purifier") },
    dehumidifierDevices: { count: (n) => tn("{n} dehumidifier", "{n} dehumidifiers", n), fresh: t("New dehumidifier"), title: t("Dehumidifier Devices"), add: t("Add Dehumidifier"), badge: t("Dehumidifier") },
    diffuserDevices: { count: (n) => tn("{n} diffuser", "{n} diffusers", n), fresh: t("New diffuser"), title: t("Diffuser Devices"), add: t("Add Diffuser"), badge: t("Diffuser") },
    kettleDevices: { count: (n) => tn("{n} kettle", "{n} kettles", n), fresh: t("New kettle"), title: t("Kettle Devices"), add: t("Add Kettle"), badge: t("Kettle") },
    iceMakerDevices: { count: (n) => tn("{n} ice maker", "{n} ice makers", n), fresh: t("New ice maker"), title: t("Ice Maker Devices"), add: t("Add Ice Maker"), badge: t("Ice Maker") },
  };

  const basic = [
    { id: "deviceId", label: t("Device ID"), type: "text", required: true },
    { id: "label", label: t("Custom Label"), type: "text" },
    { id: "ignoreDevice", label: t("Ignore Device"), type: "checkbox" },
  ];

  const deviceTypes = {
    lightDevices: {
      // A light does far more than the others, so its editor has tabs; `mode` hides a tab Govee says the light lacks.
      tabs: [
        { id: "general", title: t("General") },
        { id: "scenes", title: t("Scene Library"), mode: "scene" },
        { id: "music", title: t("Music Mode"), mode: "music" },
      ],
      fields: [
        { id: "deviceId", label: t("Device ID"), type: "text", required: true, help: t("Govee's own identifier for this light. Discover Devices fills it in for you.") },
        { id: "label", label: t("Custom Label"), type: "text", help: t("Replaces the name HomeKit shows. Leave blank to keep the name set in the Govee app.") },
        { id: "ignoreDevice", label: t("Ignore Device"), type: "checkbox", help: t("Keeps this light out of HomeKit without discarding any of the settings below.") },
        { id: "showAs", label: t("Show As"), type: "select", help: t("A Light gets brightness and colour controls. Pick Switch for a light you only ever turn on and off."),
          options: [["default", t("Light (default)")], ["switch", t("Switch")]] },
        { id: "musicModeLive.enabled", label: t("Add a Music tile to HomeKit"), type: "checkbox", tab: "music",
          help: t("Adds a second tile for this light. On/off starts music mode, brightness is the microphone sensitivity, and colour sets the music colour.") },
        { id: "musicModeLive.effect", label: t("Effect"), type: "iconselect", default: "rhythm", tab: "music",
          help: t("How the light reacts to sound. Rhythm follows the beat, Energic flashes on peaks, Rolling sweeps colour along the strip, and Spectrum maps pitch to colour."),
          options: [["rhythm", t("Rhythm")], ["energic", t("Energic")], ["rolling", t("Rolling")], ["spectrum", t("Spectrum")]] },
        { id: "musicModeLive.sensitivity", label: t("Default Sensitivity"), type: "range", min: 0, max: 100, step: 5, default: 50, unit: "%", tab: "music",
          help: t("How loud a sound must be before the light reacts. Only the starting value: the tile's brightness slider changes it live.") },
        { id: "musicModeLive.autoColour", label: t("Auto Colour"), type: "checkbox", default: true, tab: "music",
          help: t("Let the light pick colours from the music itself. Turn this off to choose the colour yourself, from the tile's colour picker.") },
        { id: "musicModeLive.soft", label: t("Soft Rhythm"), type: "checkbox", tab: "music", help: t("Rhythm only: the gentler of its two styles, with slower fades between beats.") },
        { id: "musicModeLive.protocol", label: t("Protocol"), type: "select", tab: "music",
          help: t("Older lights speak an earlier version of the music command. If the tile appears but does nothing, switch to Legacy."),
          options: [["modern", t("Modern")], ["legacy", t("Legacy (older lights)")]] },
        { id: "customIPAddress", label: t("Custom IP Address"), type: "text", advanced: true,
          help: t("Only for LAN control, when the light is not found automatically. Pair it with a DHCP reservation so the address does not move.") },
        { id: "customAddress", label: t("Custom BLE Address"), type: "text", advanced: true,
          help: t("The light's Bluetooth MAC address. Only needed when Bluetooth control cannot find the device by name.") },
        { id: "brightnessStep", label: t("Brightness Step"), type: "range", min: 1, max: 100, step: 1, default: 1, unit: "%", advanced: true,
          help: t("Smallest brightness change HomeKit will send. Raise it to stop a dragged slider flooding the light with updates.") },
        { id: "adaptiveLightingShift", label: t("Adaptive Lighting"), type: "togglerange", advanced: true, offValue: -1, default: 0, min: 0, max: 500, step: 10,
          unit: " mireds", rangeLabel: t("Warmth shift"),
          help: t("Lets HomeKit track the colour temperature to the time of day. Turn it off to keep whatever colour you set."),
          rangeHelp: t("Biases the curve warmer than Apple's. 150 keeps evenings noticeably cosier; 0 follows HomeKit exactly.") },
        { id: "awsBrightnessNoScale", label: t("AWS Brightness No Scale"), type: "checkbox", advanced: true,
          help: t("Sends brightness as 0-100 instead of 0-254. A few models need this, otherwise they jump straight to full brightness.") },
        { id: "awsColourMode", label: t("AWS Colour Mode"), type: "select", advanced: true,
          help: t("Which shape of colour command this model accepts over the cloud connection. Change it only if colours are ignored or come out wrong."),
          options: [["default", t("Default")], ["rgb", t("RGB")], ["redgreenblue", t("Red/Green/Blue")]] },
        { id: "lanScenes", label: t("Scenes over LAN"), type: "checkbox", advanced: true,
          help: t("Sends scenes, DIY effects and music mode straight to the light on your network, which is faster and works without the cloud. The light does not confirm LAN commands: if a scene does nothing, turn this off.") },
      ],
    },
    switchDevices: {
      fields: [...basic,
        { id: "showAs", label: t("Show As"), type: "select", options: [
          ["default", t("Default (Switch)")], ["outlet", t("Outlet")], ["switch", t("Switch")], ["purifier", t("Air Purifier")], ["heater", t("Heater")],
          ["cooler", t("Cooler")], ["tap", t("Tap/Faucet")], ["valve", t("Valve")], ["audio", t("Audio Receiver")], ["box", t("Set-Top Box")], ["stick", t("Streaming Stick")]] },
        { id: "temperatureSource", label: t("Temperature Source (Device ID)"), type: "text", advanced: true,
          help: t("For a plug shown as a heater or a cooler: the Govee thermo-hygrometer whose temperature switches it.") }],
    },
    thermoDevices: { fields: [...basic, { id: "lowBattThreshold", label: t("Low Battery Threshold (%)"), type: "number", min: 1, max: 100, default: 20 }, { id: "showExtraSwitch", label: t("Show Extra Switch"), type: "checkbox" }] },
    leakDevices: { fields: [...basic, { id: "lowBattThreshold", label: t("Low Battery Threshold (%)"), type: "number", min: 1, max: 100, default: 20 }] },
    fanDevices: { fields: [...basic, { id: "hideLight", label: t("Hide Light Control"), type: "checkbox" }] },
    heaterDevices: { fields: [...basic, { id: "tempReporting", label: t("Temperature Reporting"), type: "checkbox" }] },
    humidifierDevices: { fields: basic },
    purifierDevices: { fields: basic },
    dehumidifierDevices: { fields: basic },
    diffuserDevices: { fields: basic },
    kettleDevices: { fields: [...basic,
      { id: "hideModeGreenTea", label: t("Hide Green Tea Mode"), type: "checkbox", advanced: true },
      { id: "hideModeOolongTea", label: t("Hide Oolong Tea Mode"), type: "checkbox", advanced: true },
      { id: "hideModeCoffee", label: t("Hide Coffee Mode"), type: "checkbox", advanced: true },
      { id: "hideModeBlackTea", label: t("Hide Black Tea Mode"), type: "checkbox", advanced: true },
      { id: "showCustomMode1", label: t("Show Custom Mode 1"), type: "checkbox", advanced: true },
      { id: "showCustomMode2", label: t("Show Custom Mode 2"), type: "checkbox", advanced: true }] },
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
    const fresh = typeNames[type].fresh;
    return position === 1 ? fresh : `${fresh} ${position}`;
  }

  const dirty = () => JSON.stringify(readSettings({ ...config })) !== saved;
  function markDirty() {
    const state = $("#save-state");
    const changed = dirty();
    state.className = changed ? "dirty" : "muted";
    state.textContent = changed ? t("Unsaved changes") : t("Changes are kept once you save.");
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
        state.textContent = pending.length
          ? t("Saved. Restart Homeswift to apply: {changes}.", { changes: pending.map((change) => HomeswiftI18n.message(change)).join("; ") })
          : t("Saved: the plugin restarted with the new configuration.");
        $("#restart").classList.toggle("hidden", pending.length === 0);
      } catch (e) {
        state.className = "error";
        state.textContent = t("Failed to save configuration: {error}", { error: e.message });
      }
    });
  }

  // MARK: Settings tab

  const textFields = ["username", "password", "code"];
  const numberFields = [
    ["httpRefreshTime", "aws", t("HTTP Refresh (seconds)"), 30, 30, t("How often to poll the Govee API for sensor readings. Minimum 30 seconds; leave blank for the default of 30.")],
    ["lanRefreshTime", "lan", t("Refresh (seconds)"), 10, 30, t("How often to poll LAN devices for their state. Leave blank for the default of 30.")],
    ["lanScanInterval", "lan", t("Scan Interval (seconds)"), 30, 60, t("How often to scan the network for new LAN-capable devices. Minimum 30 seconds; leave blank for the default of 60.")],
    ["bleRefreshTime", "ble", t("Refresh (seconds)"), 60, 300, t("How often to scan for BLE sensor readings. Minimum 60 seconds; leave blank for the default of 300.")],
    ["bleControlInterval", "ble", t("Control Interval (ms)"), 500, 500, t("Minimum time between BLE commands, so devices are not overwhelmed. Minimum 500 ms; leave blank for the default of 500.")],
  ];
  const booleanFields = [
    ["ignoreMatter", "general", t("Ignore Matter Devices"), t("Skip devices that support Matter. Enable this if you connect those devices to HomeKit through Matter directly.")],
    ["disableDeviceLogging", "general", t("Disable Device Logging"), t("Stop logging device state changes to reduce log clutter. Errors are still logged.")],
    ["colourSafeMode", "general", t("Colour Safe Mode"), t("A slower but more reliable way of setting colours. Enable this if your lights show colour problems.")],
    ["debug", "general", t("Debug Logging"), t("Verbose debug logging in the Homeswift log.")],
    ["awsDisable", "aws", t("Disable"), t("Disable real-time cloud control through AWS IoT. Not recommended unless you have connection problems.")],
    ["lanDisable", "lan", t("Disable"), t("Disable local network control. LAN is faster and works without internet; disable it only on network problems.")],
    ["bleDisable", "ble", t("Disable"), t("Disable Bluetooth control and sensor scanning.")],
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
      $("#toggle-password").textContent = field.type === "password" ? t("Show") : t("Hide");
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
      result.replaceChildren(el("p", { class: "status-line error", text: t("Please enter your username and password.") }));
      return;
    }
    result.replaceChildren();
    await act(button, async () => {
      try {
        const answer = await request("test-login", { method: "POST", body: login });
        if (answer.success) {
          result.replaceChildren(el("p", { class: "status-line ok", text: HomeswiftI18n.message(answer.message) }));
        } else if (answer.twoFactorRequired) {
          // Govee just emailed a code: a prompt, not a failure.
          result.replaceChildren(el("p", { class: "status-line", text: HomeswiftI18n.message(answer.message) }));
          $("#code").focus();
        } else {
          problem(result, HomeswiftI18n.message(answer.message) || t("Connection failed"),
            context(answer.twoFactorInvalid ? "Test Connection logged in to the Govee cloud with a verification code, and Govee rejected the code."
              : "Test Connection tried to log in to the Govee cloud (app2.govee.com) from the plugin settings and Govee refused."), undefined, "error");
          if (answer.twoFactorInvalid) $("#code").focus();
        }
      } catch (e) {
        problem(result, e.message || t("Connection failed"), context("Test Connection could not complete a Govee cloud login from the plugin settings."));
      }
    });
  }

  // MARK: Devices tab

  function transportsOf(device) {
    const running = live[device.deviceId];
    if (!running) return null;
    const states = { enabled: t("enabled"), disabled: t("disabled") };
    const pill = (label, state) => (state === "unsupported" ? null : el("span", { class: `pill ${state === "enabled" ? "on" : ""}`, text: label, title: t("{transport}: {state}", { transport: label, state: states[state] ?? state }) }));
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
                  el("strong", {}, label, device.ignoreDevice ? el("span", { class: "pill", text: t("Ignored") }) : null, transportsOf(device)),
                  device.deviceId ? el("span", { class: "mono", text: device.deviceId }) : null),
                el("span", { class: "links" },
                  el("button", { actionIcon: "sliders", class: "link", text: t("Edit"), "aria-label": t("Edit {name}", { name: label }), onclick: () => edit(type, index) }),
                  el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), "aria-label": t("Remove {name}", { name: label }), onclick: () => remove(type, index) })));
            }))
            : el("p", { class: "muted note", text: t("No devices configured.") }),
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

  async function remove(type, index) {
    const device = config[type]?.[index];
    if (!device) return;
    if (!await HomeswiftCommon.confirmDialog(t("Remove “{name}” and its settings from the configuration? The change is kept once you click Save Configuration.", { name: displayName(type, index, device) }))) return;
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
    breadcrumb(t("Edit {name}", { name: displayName(type, index, config[type][index]) }), closeEditor);
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
      const details = el("details", { class: "group-box", open: editing.advanced }, el("summary", { text: t("Advanced settings") }),
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
        el("button", { actionIcon: "restore", class: "link", text: t("Back"), onclick: closeEditor })),
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
      el("h3", { text: t("Add from the Govee library") }),
      el("div", { id: "picker-status" }),
      el("div", { id: "picker-body" }, el("p", { class: "muted", text: t("Loading scenes…") })),
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
    const summary = chosen.length === 0 ? t("Nothing selected yet")
      : [sceneCount ? tn("{n} scene", "{n} scenes", sceneCount) : "", diyCount ? tn("{n} DIY effect", "{n} DIY effects", diyCount) : ""].filter(Boolean).join(" · ");
    const body = chosen.length === 0
      ? el("div", { class: "scene-empty" }, el("p", { text: t("No scenes selected. Pick scenes and your own DIY effects from the library below; each becomes its own switch in HomeKit.") }))
      : el("div", { class: "scene-strip" }, chosen.map((scene, sceneIndex) => el("span", { class: "scene-chip", title: scene.name || "" },
        iconFor(scene), el("span", { class: "name", text: scene.name || t("Scene") }), scene.kind === "diy" ? el("span", { class: "pill", text: "DIY" }) : null,
        el("button", { class: "link", text: "×", "aria-label": scene.name ? t("Remove {name}", { name: scene.name }) : t("Remove the scene"), onclick: () => {
          chosen.splice(sceneIndex, 1);
          if (chosen.length === 0) delete config[type][index].scenes;
          refreshSelection();
        } }))));
    return el("div", { class: "scene-panel" },
      el("div", { class: "scene-panel-head" },
        el("div", {}, el("strong", { text: t("Selected scenes") }), el("p", { class: "muted", text: summary })),
        chosen.length ? el("button", { actionIcon: "trash", class: "danger", text: t("Clear all"), onclick: () => { delete config[type][index].scenes; refreshSelection(); } }) : null),
      el("div", { class: "scene-panel-body" }, body));
  }

  async function loadPicker(type, index) {
    const device = config[type]?.[index];
    const body = $("#picker-body");
    if (!body || !device) return;
    pickerTarget = { type, index };
    if (body.dataset.loadedFor && body.dataset.loadedFor === device.deviceId) { refreshPicker(); return; }
    if (!device.deviceId) {
      body.replaceChildren(el("p", { class: "notice", text: t("Enter the device ID on the General tab and its scenes will appear here.") }));
      return;
    }
    const payload = devicePayload(device);
    if (!payload.model) {
      body.replaceChildren(el("p", { class: "notice", text: t("This device's model is unknown. Run Discover Devices first so the plugin knows which scenes to offer.") }));
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
      problem(body, e.message || t("Could not load scenes"),
        "Loading the Govee scene library and DIY effects for one device in the plugin settings failed (the bundled catalogue had no entry for this model either).",
        assistantDevice(type, device));
    }
  }

  function renderPicker(library, diys) {
    const body = $("#picker-body");
    const notes = [];
    if (library.source === "offline") notes.push(t("Showing the scene list bundled with the plugin. Log in and rediscover for the full, device-specific list."));
    if (library.warning) notes.push(HomeswiftI18n.message(library.warning));
    $("#picker-status").replaceChildren(...notes.map((note) => el("p", { class: "notice", text: note })));

    const groups = library.categories.map((category) => ({
      id: `cat-${category.id}`, name: category.name,
      items: category.scenes.map((scene) => ({
        key: `scene:${scene.sceneId}`, name: scene.name, iconUrl: scene.iconUrl, iconUrlDark: scene.iconUrlDark, variants: scene.variants,
        payload: { name: scene.name, sceneCode: scene.code, sceneId: scene.sceneId, variantId: scene.variants[0]?.id, iconUrl: scene.iconUrl, iconUrlDark: scene.iconUrlDark, kind: "scene" },
      })),
    }));
    if (diys.length) {
      groups.push({ id: "cat-diy", name: t("My DIY"), items: diys.map((diy) => ({
        key: `diy:${diy.diyId}`, name: diy.name, iconUrl: diy.iconUrl, variants: [],
        payload: { name: diy.name, sceneCode: diy.code, sceneId: diy.diyId, iconUrl: diy.iconUrl, kind: "diy" },
      })) });
    }
    if (!groups.length) {
      body.replaceChildren(el("p", { class: "notice", text: t("Govee returned no scenes for this device.") }));
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
    count.textContent = tn("{n} scene selected", "{n} scenes selected", selected.size);
    // HomeKit refuses accessories with too many services: a warning well before that.
    warning.textContent = selected.size > 50
      ? t("{n} scenes means {n} HomeKit switches on this accessory. Much beyond this and HomeKit may refuse to add it — consider trimming the list.", { n: selected.size }) : "";
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
      result.replaceChildren(el("p", { class: "status-line error", text: t("Please enter your username and password in the Settings tab.") }));
      return;
    }
    result.replaceChildren();
    await act(button, async () => {
      try {
        const devices = (await request("discover", { method: "POST", body: login })).devices || [];
        if (!devices.length) { result.replaceChildren(el("p", { class: "summary", text: t("No devices found.") })); return; }
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
          blocks.push(el("div", { class: "summary ok" }, el("strong", { text: tn("Added {n} new device: ", "Added {n} new devices: ", added) }),
            t("{list}. Click Save Configuration to keep them.", { list: Object.entries(addedByType).map(([type, count]) => typeNames[type].count(count)).join(", ") })));
        }
        if (skipped) blocks.push(el("p", { class: "summary", text: tn("{n} device was already in the configuration.", "{n} devices were already in the configuration.", skipped) }));
        blocks.push(el("ul", { class: "found" }, devices.map((device) => el("li", {},
          el("div", {}, el("strong", { text: device.deviceName || t("Unknown") }), " ",
            el("span", { class: "pill", text: typeNames[typeFor(device.model, device.deviceType)].badge }),
            el("div", { class: "muted note", text: t("Model: {model}", { model: device.model || t("Unknown") }) })),
          el("span", { class: "mono", text: device.deviceId || "" })))));
        result.replaceChildren(...blocks);
      } catch (e) {
        problem(result, t("Error: {error}", { error: e.message || t("Unknown error") }), context("Discover Devices logged in to the Govee cloud and asked for the account's device list, and it failed."));
      }
    });
  }

  // MARK: Tools

  async function clearCache(button) {
    if (!await HomeswiftCommon.confirmDialog(t("Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards."))) return;
    const result = $("#clear-result");
    await act(button, async () => {
      try {
        const answer = await request("clear-cache", { method: "POST", body: {} });
        if (answer.success) {
          result.replaceChildren(el("p", { class: "status-line ok", text: HomeswiftI18n.message(answer.message) }));
          $("#restart").classList.remove("hidden");
        } else {
          problem(result, HomeswiftI18n.message(answer.message) || t("Cache partially cleared"), "Clear Cache deletes the plugin's saved login, IoT certificate and device data; some could not be removed.", undefined, "error");
        }
      } catch (e) {
        problem(result, e.message || t("Failed to clear cache"), "Clear Cache (the plugin's saved login, IoT certificate and device data) failed.");
      }
    });
  }

  async function restart(button) {
    await act(button, async () => {
      await api("/api/restart", { method: "POST", body: {} });
      $("#save-state").textContent = t("Restarting…");
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
      // Only what the rows show: lastUpdate changes with every report, and a redraw every five seconds would
      // take the focus off a row's button and flicker the lists.
      const next = {};
      for (const device of answer.devices || []) next[device.deviceId] = { lan: device.lan, aws: device.aws, ble: device.ble };
      const changed = JSON.stringify(next) !== JSON.stringify(live);
      live = next;
      if (changed) renderTypes();
    } catch { /* the plugin may be restarting */ }
  }

  // Sentences with a word in bold, each one string to translate.
  const [introBefore, introAfter = ""] = t("Discover all devices linked to your Govee account and add them to the lists below. Enter your credentials in the {tab} tab first.").split("{tab}");
  $("#discover-intro").replaceChildren(introBefore, el("strong", { text: t("Settings") }), introAfter);

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
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Govee page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "New light": "Nouvelle lampe",
    "Light Devices": "Lampes",
    "Add Light Device": "Ajouter une lampe",
    "Light": "Lampe",
    "New switch/outlet": "Nouvel interrupteur/prise",
    "Switch/Outlet Devices": "Interrupteurs et prises",
    "Add Switch Device": "Ajouter un interrupteur",
    "Switch/Outlet": "Interrupteur/prise",
    "New temperature/humidity sensor": "Nouveau capteur de température/humidité",
    "Temperature/Humidity Sensors": "Capteurs de température/humidité",
    "Add Sensor": "Ajouter un capteur",
    "Temp/Humidity Sensor": "Capteur temp./humidité",
    "New leak sensor": "Nouveau capteur de fuite",
    "Leak Sensors": "Capteurs de fuite",
    "Add Leak Sensor": "Ajouter un capteur de fuite",
    "Leak Sensor": "Capteur de fuite",
    "New fan": "Nouveau ventilateur",
    "Fan Devices": "Ventilateurs",
    "Add Fan": "Ajouter un ventilateur",
    "Fan": "Ventilateur",
    "New heater": "Nouveau radiateur",
    "Heater Devices": "Radiateurs",
    "Add Heater": "Ajouter un radiateur",
    "Heater": "Radiateur",
    "New humidifier": "Nouvel humidificateur",
    "Humidifier Devices": "Humidificateurs",
    "Add Humidifier": "Ajouter un humidificateur",
    "Humidifier": "Humidificateur",
    "New air purifier": "Nouveau purificateur d'air",
    "Air Purifier Devices": "Purificateurs d'air",
    "Add Purifier": "Ajouter un purificateur",
    "Air Purifier": "Purificateur d'air",
    "New dehumidifier": "Nouveau déshumidificateur",
    "Dehumidifier Devices": "Déshumidificateurs",
    "Add Dehumidifier": "Ajouter un déshumidificateur",
    "Dehumidifier": "Déshumidificateur",
    "New diffuser": "Nouveau diffuseur",
    "Diffuser Devices": "Diffuseurs",
    "Add Diffuser": "Ajouter un diffuseur",
    "Diffuser": "Diffuseur",
    "New kettle": "Nouvelle bouilloire",
    "Kettle Devices": "Bouilloires",
    "Add Kettle": "Ajouter une bouilloire",
    "Kettle": "Bouilloire",
    "New ice maker": "Nouvelle machine à glaçons",
    "Ice Maker Devices": "Machines à glaçons",
    "Add Ice Maker": "Ajouter une machine à glaçons",
    "Ice Maker": "Machine à glaçons",
    "{n} light": "{n} lampe",
    "{n} lights": "{n} lampes",
    "{n} switch/outlet": "{n} interrupteur/prise",
    "{n} switches/outlets": "{n} interrupteurs/prises",
    "{n} temperature/humidity sensor": "{n} capteur de température/humidité",
    "{n} temperature/humidity sensors": "{n} capteurs de température/humidité",
    "{n} leak sensor": "{n} capteur de fuite",
    "{n} leak sensors": "{n} capteurs de fuite",
    "{n} fan": "{n} ventilateur",
    "{n} fans": "{n} ventilateurs",
    "{n} heater": "{n} radiateur",
    "{n} heaters": "{n} radiateurs",
    "{n} humidifier": "{n} humidificateur",
    "{n} humidifiers": "{n} humidificateurs",
    "{n} air purifier": "{n} purificateur d'air",
    "{n} air purifiers": "{n} purificateurs d'air",
    "{n} dehumidifier": "{n} déshumidificateur",
    "{n} dehumidifiers": "{n} déshumidificateurs",
    "{n} diffuser": "{n} diffuseur",
    "{n} diffusers": "{n} diffuseurs",
    "{n} kettle": "{n} bouilloire",
    "{n} kettles": "{n} bouilloires",
    "{n} ice maker": "{n} machine à glaçons",
    "{n} ice makers": "{n} machines à glaçons",
    "Device ID": "Identifiant de l'appareil",
    "Custom Label": "Nom personnalisé",
    "Ignore Device": "Ignorer l'appareil",
    "General": "Général",
    "Scene Library": "Bibliothèque de scènes",
    "Music Mode": "Mode musique",
    "Govee's own identifier for this light. Discover Devices fills it in for you.": "L'identifiant que Govee donne à cette lampe. Découvrir les appareils le remplit pour vous.",
    "Replaces the name HomeKit shows. Leave blank to keep the name set in the Govee app.": "Remplace le nom affiché par HomeKit. Laissez vide pour garder le nom choisi dans l'app Govee.",
    "Keeps this light out of HomeKit without discarding any of the settings below.": "Tient cette lampe hors de HomeKit sans perdre les réglages ci-dessous.",
    "Show As": "Afficher comme",
    "A Light gets brightness and colour controls. Pick Switch for a light you only ever turn on and off.": "L'option Lampe offre des réglages de luminosité et de couleur. Choisissez Interrupteur pour une lampe que vous ne faites qu'allumer et éteindre.",
    "Light (default)": "Lampe (par défaut)",
    "Switch": "Interrupteur",
    "Add a Music tile to HomeKit": "Ajouter une vignette Musique à HomeKit",
    "Adds a second tile for this light. On/off starts music mode, brightness is the microphone sensitivity, and colour sets the music colour.": "Ajoute une seconde vignette pour cette lampe. Allumer/éteindre lance le mode musique, la luminosité règle la sensibilité du micro et la couleur, celle de la musique.",
    "Effect": "Effet",
    "How the light reacts to sound. Rhythm follows the beat, Energic flashes on peaks, Rolling sweeps colour along the strip, and Spectrum maps pitch to colour.": "Comment la lampe réagit au son. Rythme suit le tempo, Énergique clignote sur les pics, Défilement fait courir la couleur le long du ruban et Spectre associe la hauteur du son à une couleur.",
    "Rhythm": "Rythme",
    "Energic": "Énergique",
    "Rolling": "Défilement",
    "Spectrum": "Spectre",
    "Default Sensitivity": "Sensibilité par défaut",
    "How loud a sound must be before the light reacts. Only the starting value: the tile's brightness slider changes it live.": "Le volume qu'un son doit atteindre pour que la lampe réagisse. Ce n'est que la valeur de départ : le curseur de luminosité de la vignette la change en direct.",
    "Auto Colour": "Couleur automatique",
    "Let the light pick colours from the music itself. Turn this off to choose the colour yourself, from the tile's colour picker.": "La lampe choisit les couleurs d'après la musique. Désactivez cette option pour choisir la couleur vous-même, avec le sélecteur de couleur de la vignette.",
    "Soft Rhythm": "Rythme doux",
    "Rhythm only: the gentler of its two styles, with slower fades between beats.": "Rythme uniquement : le plus doux de ses deux styles, avec des fondus plus lents entre les temps.",
    "Protocol": "Protocole",
    "Older lights speak an earlier version of the music command. If the tile appears but does nothing, switch to Legacy.": "Les lampes plus anciennes utilisent une version antérieure de la commande musique. Si la vignette apparaît mais ne fait rien, passez à Ancien.",
    "Modern": "Moderne",
    "Legacy (older lights)": "Ancien (lampes plus anciennes)",
    "Custom IP Address": "Adresse IP personnalisée",
    "Only for LAN control, when the light is not found automatically. Pair it with a DHCP reservation so the address does not move.": "Uniquement pour le contrôle LAN, quand la lampe n'est pas trouvée automatiquement. Associez-la à une réservation DHCP pour que l'adresse ne change pas.",
    "Custom BLE Address": "Adresse BLE personnalisée",
    "The light's Bluetooth MAC address. Only needed when Bluetooth control cannot find the device by name.": "L'adresse MAC Bluetooth de la lampe. Utile seulement quand le contrôle Bluetooth ne trouve pas l'appareil par son nom.",
    "Brightness Step": "Pas de luminosité",
    "Smallest brightness change HomeKit will send. Raise it to stop a dragged slider flooding the light with updates.": "Le plus petit changement de luminosité que HomeKit enverra. Augmentez-le pour qu'un curseur qu'on fait glisser n'inonde pas la lampe de mises à jour.",
    "Adaptive Lighting": "Éclairage adaptatif",
    "Warmth shift": "Décalage vers le chaud",
    "Lets HomeKit track the colour temperature to the time of day. Turn it off to keep whatever colour you set.": "Laisse HomeKit adapter la température de couleur à l'heure de la journée. Désactivez-le pour garder la couleur que vous choisissez.",
    "Biases the curve warmer than Apple's. 150 keeps evenings noticeably cosier; 0 follows HomeKit exactly.": "Rend la courbe plus chaude que celle d'Apple. 150 rend les soirées nettement plus douillettes ; 0 suit HomeKit exactement.",
    "AWS Brightness No Scale": "Luminosité AWS sans mise à l'échelle",
    "Sends brightness as 0-100 instead of 0-254. A few models need this, otherwise they jump straight to full brightness.": "Envoie la luminosité de 0 à 100 au lieu de 0 à 254. Quelques modèles en ont besoin, sinon ils passent directement à pleine luminosité.",
    "AWS Colour Mode": "Mode de couleur AWS",
    "Which shape of colour command this model accepts over the cloud connection. Change it only if colours are ignored or come out wrong.": "La forme de commande de couleur que ce modèle accepte par le cloud. Ne la changez que si les couleurs sont ignorées ou fausses.",
    "Default": "Par défaut",
    "RGB": "RVB",
    "Red/Green/Blue": "Rouge/vert/bleu",
    "Scenes over LAN": "Scènes par le LAN",
    "Sends scenes, DIY effects and music mode straight to the light on your network, which is faster and works without the cloud. The light does not confirm LAN commands: if a scene does nothing, turn this off.": "Envoie les scènes, les effets DIY et le mode musique directement à la lampe sur votre réseau, ce qui est plus rapide et fonctionne sans le cloud. La lampe ne confirme pas les commandes LAN : si une scène ne fait rien, désactivez cette option.",
    "Default (Switch)": "Par défaut (interrupteur)",
    "Outlet": "Prise",
    "Cooler": "Climatiseur",
    "Tap/Faucet": "Robinet",
    "Valve": "Vanne",
    "Audio Receiver": "Récepteur audio",
    "Set-Top Box": "Décodeur",
    "Streaming Stick": "Clé de streaming",
    "Temperature Source (Device ID)": "Source de température (identifiant de l'appareil)",
    "For a plug shown as a heater or a cooler: the Govee thermo-hygrometer whose temperature switches it.": "Pour une prise affichée comme radiateur ou climatiseur : le thermo-hygromètre Govee dont la température la commande.",
    "Low Battery Threshold (%)": "Seuil de batterie faible (%)",
    "Show Extra Switch": "Afficher un interrupteur supplémentaire",
    "Hide Light Control": "Masquer la commande de lumière",
    "Temperature Reporting": "Relevé de température",
    "Hide Green Tea Mode": "Masquer le mode thé vert",
    "Hide Oolong Tea Mode": "Masquer le mode thé oolong",
    "Hide Coffee Mode": "Masquer le mode café",
    "Hide Black Tea Mode": "Masquer le mode thé noir",
    "Show Custom Mode 1": "Afficher le mode personnalisé 1",
    "Show Custom Mode 2": "Afficher le mode personnalisé 2",
    "Unsaved changes": "Modifications non enregistrées",
    "Changes are kept once you save.": "Les modifications sont conservées une fois enregistrées.",
    "Saved. Restart Homeswift to apply: {changes}.": "Enregistré. Redémarrez Homeswift pour appliquer : {changes}.",
    "Saved: the plugin restarted with the new configuration.": "Enregistré : le plugin a redémarré avec la nouvelle configuration.",
    "Failed to save configuration: {error}": "Impossible d'enregistrer la configuration : {error}",
    "Save Configuration": "Enregistrer la configuration",
    "HTTP Refresh (seconds)": "Actualisation HTTP (secondes)",
    "How often to poll the Govee API for sensor readings. Minimum 30 seconds; leave blank for the default of 30.": "La fréquence d'interrogation de l'API Govee pour les relevés des capteurs. 30 secondes minimum ; laissez vide pour la valeur par défaut de 30.",
    "Refresh (seconds)": "Actualisation (secondes)",
    "How often to poll LAN devices for their state. Leave blank for the default of 30.": "La fréquence d'interrogation de l'état des appareils LAN. Laissez vide pour la valeur par défaut de 30.",
    "Scan Interval (seconds)": "Intervalle de recherche (secondes)",
    "How often to scan the network for new LAN-capable devices. Minimum 30 seconds; leave blank for the default of 60.": "La fréquence de recherche de nouveaux appareils LAN sur le réseau. 30 secondes minimum ; laissez vide pour la valeur par défaut de 60.",
    "How often to scan for BLE sensor readings. Minimum 60 seconds; leave blank for the default of 300.": "La fréquence de recherche des relevés des capteurs BLE. 60 secondes minimum ; laissez vide pour la valeur par défaut de 300.",
    "Control Interval (ms)": "Intervalle de commande (ms)",
    "Minimum time between BLE commands, so devices are not overwhelmed. Minimum 500 ms; leave blank for the default of 500.": "Délai minimal entre deux commandes BLE, pour ne pas submerger les appareils. 500 ms minimum ; laissez vide pour la valeur par défaut de 500.",
    "Ignore Matter Devices": "Ignorer les appareils Matter",
    "Skip devices that support Matter. Enable this if you connect those devices to HomeKit through Matter directly.": "Ignore les appareils compatibles Matter. Activez cette option si vous les connectez à HomeKit directement par Matter.",
    "Disable Device Logging": "Désactiver le journal des appareils",
    "Stop logging device state changes to reduce log clutter. Errors are still logged.": "N'inscrit plus les changements d'état des appareils, pour alléger le journal. Les erreurs restent journalisées.",
    "Colour Safe Mode": "Mode couleur fiable",
    "A slower but more reliable way of setting colours. Enable this if your lights show colour problems.": "Une façon plus lente mais plus fiable de régler les couleurs. Activez-la si vos lampes ont des problèmes de couleur.",
    "Debug Logging": "Journal de débogage",
    "Verbose debug logging in the Homeswift log.": "Journal de débogage détaillé dans le journal de Homeswift.",
    "Disable": "Désactiver",
    "Disable real-time cloud control through AWS IoT. Not recommended unless you have connection problems.": "Désactive le contrôle en temps réel par le cloud via AWS IoT. Déconseillé, sauf en cas de problèmes de connexion.",
    "Disable local network control. LAN is faster and works without internet; disable it only on network problems.": "Désactive le contrôle par le réseau local. Le LAN est plus rapide et fonctionne sans internet ; ne le désactivez qu'en cas de problèmes de réseau.",
    "Disable Bluetooth control and sensor scanning.": "Désactive le contrôle Bluetooth et la recherche des capteurs.",
    "Show": "Afficher",
    "Hide": "Masquer",
    "Please enter your username and password.": "Saisissez votre nom d'utilisateur et votre mot de passe.",
    "Connection failed": "Échec de la connexion",
    "enabled": "activé",
    "disabled": "désactivé",
    "{transport}: {state}": "{transport} : {state}",
    "Ignored": "Ignoré",
    "Edit": "Modifier",
    "Edit {name}": "Modifier {name}",
    "Remove": "Retirer",
    "Remove {name}": "Retirer {name}",
    "No devices configured.": "Aucun appareil configuré.",
    "Remove “{name}” and its settings from the configuration? The change is kept once you click Save Configuration.": "Retirer « {name} » et ses réglages de la configuration ? La modification est conservée une fois que vous cliquez sur Enregistrer la configuration.",
    "Advanced settings": "Réglages avancés",
    "Back": "Retour",
    "Add from the Govee library": "Ajouter depuis la bibliothèque Govee",
    "Loading scenes…": "Chargement des scènes…",
    "Nothing selected yet": "Rien de sélectionné pour l'instant",
    "{n} scene": "{n} scène",
    "{n} scenes": "{n} scènes",
    "{n} DIY effect": "{n} effet DIY",
    "{n} DIY effects": "{n} effets DIY",
    "No scenes selected. Pick scenes and your own DIY effects from the library below; each becomes its own switch in HomeKit.": "Aucune scène sélectionnée. Choisissez des scènes et vos propres effets DIY dans la bibliothèque ci-dessous ; chacun devient un interrupteur dans HomeKit.",
    "Scene": "Scène",
    "Remove the scene": "Retirer la scène",
    "Selected scenes": "Scènes sélectionnées",
    "Clear all": "Tout effacer",
    "Enter the device ID on the General tab and its scenes will appear here.": "Saisissez l'identifiant de l'appareil dans l'onglet Général et ses scènes apparaîtront ici.",
    "This device's model is unknown. Run Discover Devices first so the plugin knows which scenes to offer.": "Le modèle de cet appareil est inconnu. Lancez d'abord Découvrir les appareils pour que le plugin sache quelles scènes proposer.",
    "Could not load scenes": "Impossible de charger les scènes",
    "Showing the scene list bundled with the plugin. Log in and rediscover for the full, device-specific list.": "Liste de scènes fournie avec le plugin. Connectez-vous et relancez la découverte pour la liste complète propre à l'appareil.",
    "My DIY": "Mes effets DIY",
    "Govee returned no scenes for this device.": "Govee n'a renvoyé aucune scène pour cet appareil.",
    "{n} scene selected": "{n} scène sélectionnée",
    "{n} scenes selected": "{n} scènes sélectionnées",
    "{n} scenes means {n} HomeKit switches on this accessory. Much beyond this and HomeKit may refuse to add it — consider trimming the list.": "{n} scènes, c'est {n} interrupteurs HomeKit sur cet accessoire. Bien au-delà, HomeKit risque de refuser de l'ajouter : pensez à raccourcir la liste.",
    "Please enter your username and password in the Settings tab.": "Saisissez votre nom d'utilisateur et votre mot de passe dans l'onglet Réglages.",
    "No devices found.": "Aucun appareil trouvé.",
    "Added {n} new device: ": "{n} nouvel appareil ajouté : ",
    "Added {n} new devices: ": "{n} nouveaux appareils ajoutés : ",
    "{list}. Click Save Configuration to keep them.": "{list}. Cliquez sur Enregistrer la configuration pour les garder.",
    "{n} device was already in the configuration.": "{n} appareil était déjà dans la configuration.",
    "{n} devices were already in the configuration.": "{n} appareils étaient déjà dans la configuration.",
    "Unknown": "Inconnu",
    "Model: {model}": "Modèle : {model}",
    "Error: {error}": "Erreur : {error}",
    "Unknown error": "Erreur inconnue",
    "Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards.": "Vider le cache ? Cela supprime la connexion enregistrée, le certificat IoT et les données des appareils. Redémarrez Homeswift ensuite.",
    "Cache partially cleared": "Cache vidé en partie",
    "Failed to clear cache": "Impossible de vider le cache",
    "Restarting…": "Redémarrage…",
    "Discover all devices linked to your Govee account and add them to the lists below. Enter your credentials in the {tab} tab first.": "Découvrez tous les appareils liés à votre compte Govee et ajoutez-les aux listes ci-dessous. Saisissez d'abord vos identifiants dans l'onglet {tab}.",
    "Settings": "Réglages",
    "Your Govee account, the devices it brings to the Home app and how each one appears, scenes and music mode for lights, and the connections the plugin uses.": "Votre compte Govee, les appareils qu'il apporte à l'app Maison et leur apparence, les scènes et le mode musique des lampes, et les connexions qu'utilise le plugin.",
    "Devices": "Appareils",
    "Tools": "Outils",
    "Discover Devices": "Découvrir les appareils",
    "Account": "Compte",
    "Email": "E-mail",
    "your-email@example.com": "vous@exemple.com",
    "The email address you use to log in to the Govee app. Required for cloud control and device discovery.": "L'adresse e-mail avec laquelle vous vous connectez à l'app Govee. Requise pour le contrôle par le cloud et la découverte des appareils.",
    "Password": "Mot de passe",
    "Your Govee account password. Stored in config.json and used only to authenticate with Govee's servers.": "Le mot de passe de votre compte Govee. Enregistré dans config.json et utilisé uniquement pour s'authentifier auprès des serveurs de Govee.",
    "Verification Code": "Code de vérification",
    "e.g. 1234": "p. ex. 1234",
    "Only needed the first time, or when Govee flags a new device. If Test Connection reports that a code was emailed to you, paste it here and test again. Ignored once login succeeds.": "Nécessaire seulement la première fois, ou quand Govee signale un nouvel appareil. Si Tester la connexion indique qu'un code vous a été envoyé par e-mail, collez-le ici et testez à nouveau. Ignoré une fois la connexion réussie.",
    "Test Connection": "Tester la connexion",
    "Connection": "Connexion",
    "Cache Management": "Gestion du cache",
    "Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.": "Videz le cache du plugin si la découverte des appareils se comporte mal ou si les données semblent périmées : la connexion et le certificat IoT enregistrés, les appareils découverts, l'état enregistré des appareils. Redémarrez Homeswift ensuite.",
    "Clear Cache": "Vider le cache",
    "Restart Homeswift": "Redémarrer Homeswift",
    "Documentation": "Documentation",
    "The options are described in the plugin's README; the connections are tried in this order:": "Les options sont décrites dans le README du plugin ; les connexions sont essayées dans cet ordre :",
    "local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.": "contrôle par le réseau local (plus rapide, fonctionne sans internet), pour les modèles dont l'API LAN est activée dans l'app Govee.",
    "real-time control through Govee's cloud (requires credentials).": "contrôle en temps réel par le cloud de Govee (nécessite des identifiants).",
    "Bluetooth control for nearby devices (requires a Bluetooth adapter).": "contrôle Bluetooth des appareils à proximité (nécessite un adaptateur Bluetooth).",
    "Username and password are required": "Le nom d'utilisateur et le mot de passe sont requis",
    "Enter your Govee credentials in the Settings tab first.": "Saisissez d'abord vos identifiants Govee dans l'onglet Réglages.",
    "Login successful. Account ID: {0}": "Connexion réussie. Identifiant du compte : {0}",
    "Cache cleared successfully. Please restart Homeswift to apply changes.": "Cache vidé. Redémarrez Homeswift pour appliquer les modifications.",
    "Cache partially cleared. Errors: {0}": "Cache vidé en partie. Erreurs : {0}",
    "A device ID and model are required to load scenes.": "Un identifiant d'appareil et un modèle sont requis pour charger les scènes.",
    "A device ID and model are required to load DIY effects.": "Un identifiant d'appareil et un modèle sont requis pour charger les effets DIY.",
    "A device ID and model are required.": "Un identifiant d'appareil et un modèle sont requis.",
    "Govee login failed: {0}": "Échec de la connexion à Govee : {0}",
    "Request failed with status code {0}": "La requête a échoué avec le code {0}",
    "Govee scene library response did not contain any categories": "La réponse de la bibliothèque de scènes Govee ne contenait aucune catégorie",
    "nothing at {0} {1}": "rien à {0} {1}"
  },
  "es": {
    "New light": "Nueva luz",
    "Light Devices": "Luces",
    "Add Light Device": "Añadir luz",
    "Light": "Luz",
    "New switch/outlet": "Nuevo interruptor/enchufe",
    "Switch/Outlet Devices": "Interruptores y enchufes",
    "Add Switch Device": "Añadir interruptor",
    "Switch/Outlet": "Interruptor/enchufe",
    "New temperature/humidity sensor": "Nuevo sensor de temperatura/humedad",
    "Temperature/Humidity Sensors": "Sensores de temperatura/humedad",
    "Add Sensor": "Añadir sensor",
    "Temp/Humidity Sensor": "Sensor de temp./humedad",
    "New leak sensor": "Nuevo sensor de fugas",
    "Leak Sensors": "Sensores de fugas",
    "Add Leak Sensor": "Añadir sensor de fugas",
    "Leak Sensor": "Sensor de fugas",
    "New fan": "Nuevo ventilador",
    "Fan Devices": "Ventiladores",
    "Add Fan": "Añadir ventilador",
    "Fan": "Ventilador",
    "New heater": "Nuevo calefactor",
    "Heater Devices": "Calefactores",
    "Add Heater": "Añadir calefactor",
    "Heater": "Calefactor",
    "New humidifier": "Nuevo humidificador",
    "Humidifier Devices": "Humidificadores",
    "Add Humidifier": "Añadir humidificador",
    "Humidifier": "Humidificador",
    "New air purifier": "Nuevo purificador de aire",
    "Air Purifier Devices": "Purificadores de aire",
    "Add Purifier": "Añadir purificador",
    "Air Purifier": "Purificador de aire",
    "New dehumidifier": "Nuevo deshumidificador",
    "Dehumidifier Devices": "Deshumidificadores",
    "Add Dehumidifier": "Añadir deshumidificador",
    "Dehumidifier": "Deshumidificador",
    "New diffuser": "Nuevo difusor",
    "Diffuser Devices": "Difusores",
    "Add Diffuser": "Añadir difusor",
    "Diffuser": "Difusor",
    "New kettle": "Nuevo hervidor",
    "Kettle Devices": "Hervidores",
    "Add Kettle": "Añadir hervidor",
    "Kettle": "Hervidor",
    "New ice maker": "Nueva máquina de hielo",
    "Ice Maker Devices": "Máquinas de hielo",
    "Add Ice Maker": "Añadir máquina de hielo",
    "Ice Maker": "Máquina de hielo",
    "{n} light": "{n} luz",
    "{n} lights": "{n} luces",
    "{n} switch/outlet": "{n} interruptor/enchufe",
    "{n} switches/outlets": "{n} interruptores/enchufes",
    "{n} temperature/humidity sensor": "{n} sensor de temperatura/humedad",
    "{n} temperature/humidity sensors": "{n} sensores de temperatura/humedad",
    "{n} leak sensor": "{n} sensor de fugas",
    "{n} leak sensors": "{n} sensores de fugas",
    "{n} fan": "{n} ventilador",
    "{n} fans": "{n} ventiladores",
    "{n} heater": "{n} calefactor",
    "{n} heaters": "{n} calefactores",
    "{n} humidifier": "{n} humidificador",
    "{n} humidifiers": "{n} humidificadores",
    "{n} air purifier": "{n} purificador de aire",
    "{n} air purifiers": "{n} purificadores de aire",
    "{n} dehumidifier": "{n} deshumidificador",
    "{n} dehumidifiers": "{n} deshumidificadores",
    "{n} diffuser": "{n} difusor",
    "{n} diffusers": "{n} difusores",
    "{n} kettle": "{n} hervidor",
    "{n} kettles": "{n} hervidores",
    "{n} ice maker": "{n} máquina de hielo",
    "{n} ice makers": "{n} máquinas de hielo",
    "Device ID": "ID del dispositivo",
    "Custom Label": "Nombre personalizado",
    "Ignore Device": "Ignorar el dispositivo",
    "General": "General",
    "Scene Library": "Biblioteca de escenas",
    "Music Mode": "Modo música",
    "Govee's own identifier for this light. Discover Devices fills it in for you.": "El identificador que Govee da a esta luz. Detectar dispositivos lo rellena por ti.",
    "Replaces the name HomeKit shows. Leave blank to keep the name set in the Govee app.": "Sustituye el nombre que muestra HomeKit. Déjalo vacío para mantener el nombre de la app Govee.",
    "Keeps this light out of HomeKit without discarding any of the settings below.": "Deja esta luz fuera de HomeKit sin descartar ninguno de los ajustes de abajo.",
    "Show As": "Mostrar como",
    "A Light gets brightness and colour controls. Pick Switch for a light you only ever turn on and off.": "Una luz tiene controles de brillo y color. Elige Interruptor para una luz que solo enciendes y apagas.",
    "Light (default)": "Luz (predeterminado)",
    "Switch": "Interruptor",
    "Add a Music tile to HomeKit": "Añadir un mosaico de música a HomeKit",
    "Adds a second tile for this light. On/off starts music mode, brightness is the microphone sensitivity, and colour sets the music colour.": "Añade un segundo mosaico para esta luz. Encender/apagar inicia el modo música, el brillo es la sensibilidad del micrófono y el color fija el color de la música.",
    "Effect": "Efecto",
    "How the light reacts to sound. Rhythm follows the beat, Energic flashes on peaks, Rolling sweeps colour along the strip, and Spectrum maps pitch to colour.": "Cómo reacciona la luz al sonido. Ritmo sigue el compás, Enérgico destella en los picos, Desplazamiento recorre la tira con el color y Espectro asigna un color a cada tono.",
    "Rhythm": "Ritmo",
    "Energic": "Enérgico",
    "Rolling": "Desplazamiento",
    "Spectrum": "Espectro",
    "Default Sensitivity": "Sensibilidad predeterminada",
    "How loud a sound must be before the light reacts. Only the starting value: the tile's brightness slider changes it live.": "Lo fuerte que debe ser un sonido para que la luz reaccione. Solo es el valor inicial: el control de brillo del mosaico lo cambia en directo.",
    "Auto Colour": "Color automático",
    "Let the light pick colours from the music itself. Turn this off to choose the colour yourself, from the tile's colour picker.": "La luz elige los colores según la música. Desactívalo para elegir tú el color con el selector de color del mosaico.",
    "Soft Rhythm": "Ritmo suave",
    "Rhythm only: the gentler of its two styles, with slower fades between beats.": "Solo Ritmo: el más suave de sus dos estilos, con transiciones más lentas entre golpes.",
    "Protocol": "Protocolo",
    "Older lights speak an earlier version of the music command. If the tile appears but does nothing, switch to Legacy.": "Las luces más antiguas usan una versión anterior del comando de música. Si el mosaico aparece pero no hace nada, cambia a Antiguo.",
    "Modern": "Moderno",
    "Legacy (older lights)": "Antiguo (luces más antiguas)",
    "Custom IP Address": "Dirección IP personalizada",
    "Only for LAN control, when the light is not found automatically. Pair it with a DHCP reservation so the address does not move.": "Solo para el control por LAN, cuando la luz no se encuentra automáticamente. Combínalo con una reserva DHCP para que la dirección no cambie.",
    "Custom BLE Address": "Dirección BLE personalizada",
    "The light's Bluetooth MAC address. Only needed when Bluetooth control cannot find the device by name.": "La dirección MAC Bluetooth de la luz. Solo hace falta cuando el control por Bluetooth no encuentra el dispositivo por su nombre.",
    "Brightness Step": "Paso de brillo",
    "Smallest brightness change HomeKit will send. Raise it to stop a dragged slider flooding the light with updates.": "El cambio de brillo más pequeño que enviará HomeKit. Súbelo para que un control deslizado no sature la luz de actualizaciones.",
    "Adaptive Lighting": "Iluminación adaptativa",
    "Warmth shift": "Desplazamiento cálido",
    "Lets HomeKit track the colour temperature to the time of day. Turn it off to keep whatever colour you set.": "Deja que HomeKit ajuste la temperatura de color a la hora del día. Desactívalo para mantener el color que elijas.",
    "Biases the curve warmer than Apple's. 150 keeps evenings noticeably cosier; 0 follows HomeKit exactly.": "Hace la curva más cálida que la de Apple. 150 deja las noches notablemente más acogedoras; 0 sigue HomeKit exactamente.",
    "AWS Brightness No Scale": "Brillo AWS sin escalar",
    "Sends brightness as 0-100 instead of 0-254. A few models need this, otherwise they jump straight to full brightness.": "Envía el brillo de 0 a 100 en lugar de 0 a 254. Algunos modelos lo necesitan; si no, saltan directamente al brillo máximo.",
    "AWS Colour Mode": "Modo de color AWS",
    "Which shape of colour command this model accepts over the cloud connection. Change it only if colours are ignored or come out wrong.": "El formato de comando de color que este modelo acepta por la nube. Cámbialo solo si los colores se ignoran o salen mal.",
    "Default": "Predeterminado",
    "RGB": "RGB",
    "Red/Green/Blue": "Rojo/verde/azul",
    "Scenes over LAN": "Escenas por LAN",
    "Sends scenes, DIY effects and music mode straight to the light on your network, which is faster and works without the cloud. The light does not confirm LAN commands: if a scene does nothing, turn this off.": "Envía las escenas, los efectos DIY y el modo música directamente a la luz en tu red, lo que es más rápido y funciona sin la nube. La luz no confirma los comandos LAN: si una escena no hace nada, desactiva esta opción.",
    "Default (Switch)": "Predeterminado (interruptor)",
    "Outlet": "Enchufe",
    "Cooler": "Enfriador",
    "Tap/Faucet": "Grifo",
    "Valve": "Válvula",
    "Audio Receiver": "Receptor de audio",
    "Set-Top Box": "Descodificador",
    "Streaming Stick": "Stick de streaming",
    "Temperature Source (Device ID)": "Fuente de temperatura (ID del dispositivo)",
    "For a plug shown as a heater or a cooler: the Govee thermo-hygrometer whose temperature switches it.": "Para un enchufe mostrado como calefactor o enfriador: el termohigrómetro Govee cuya temperatura lo activa.",
    "Low Battery Threshold (%)": "Umbral de batería baja (%)",
    "Show Extra Switch": "Mostrar un interruptor adicional",
    "Hide Light Control": "Ocultar el control de luz",
    "Temperature Reporting": "Informe de temperatura",
    "Hide Green Tea Mode": "Ocultar el modo té verde",
    "Hide Oolong Tea Mode": "Ocultar el modo té oolong",
    "Hide Coffee Mode": "Ocultar el modo café",
    "Hide Black Tea Mode": "Ocultar el modo té negro",
    "Show Custom Mode 1": "Mostrar el modo personalizado 1",
    "Show Custom Mode 2": "Mostrar el modo personalizado 2",
    "Unsaved changes": "Cambios sin guardar",
    "Changes are kept once you save.": "Los cambios se conservan al guardar.",
    "Saved. Restart Homeswift to apply: {changes}.": "Guardado. Reinicia Homeswift para aplicar: {changes}.",
    "Saved: the plugin restarted with the new configuration.": "Guardado: el plugin se ha reiniciado con la nueva configuración.",
    "Failed to save configuration: {error}": "No se ha podido guardar la configuración: {error}",
    "Save Configuration": "Guardar la configuración",
    "HTTP Refresh (seconds)": "Actualización HTTP (segundos)",
    "How often to poll the Govee API for sensor readings. Minimum 30 seconds; leave blank for the default of 30.": "Cada cuánto se consulta la API de Govee para las lecturas de los sensores. Mínimo 30 segundos; déjalo vacío para el valor predeterminado de 30.",
    "Refresh (seconds)": "Actualización (segundos)",
    "How often to poll LAN devices for their state. Leave blank for the default of 30.": "Cada cuánto se consulta el estado de los dispositivos LAN. Déjalo vacío para el valor predeterminado de 30.",
    "Scan Interval (seconds)": "Intervalo de búsqueda (segundos)",
    "How often to scan the network for new LAN-capable devices. Minimum 30 seconds; leave blank for the default of 60.": "Cada cuánto se busca en la red nuevos dispositivos con LAN. Mínimo 30 segundos; déjalo vacío para el valor predeterminado de 60.",
    "How often to scan for BLE sensor readings. Minimum 60 seconds; leave blank for the default of 300.": "Cada cuánto se buscan lecturas de sensores BLE. Mínimo 60 segundos; déjalo vacío para el valor predeterminado de 300.",
    "Control Interval (ms)": "Intervalo de control (ms)",
    "Minimum time between BLE commands, so devices are not overwhelmed. Minimum 500 ms; leave blank for the default of 500.": "Tiempo mínimo entre comandos BLE, para no saturar los dispositivos. Mínimo 500 ms; déjalo vacío para el valor predeterminado de 500.",
    "Ignore Matter Devices": "Ignorar los dispositivos Matter",
    "Skip devices that support Matter. Enable this if you connect those devices to HomeKit through Matter directly.": "Omite los dispositivos compatibles con Matter. Actívalo si los conectas a HomeKit directamente por Matter.",
    "Disable Device Logging": "Desactivar el registro de dispositivos",
    "Stop logging device state changes to reduce log clutter. Errors are still logged.": "Deja de registrar los cambios de estado de los dispositivos para aligerar el registro. Los errores se siguen registrando.",
    "Colour Safe Mode": "Modo de color seguro",
    "A slower but more reliable way of setting colours. Enable this if your lights show colour problems.": "Una forma más lenta pero más fiable de fijar los colores. Actívalo si tus luces tienen problemas de color.",
    "Debug Logging": "Registro de depuración",
    "Verbose debug logging in the Homeswift log.": "Registro de depuración detallado en el registro de Homeswift.",
    "Disable": "Desactivar",
    "Disable real-time cloud control through AWS IoT. Not recommended unless you have connection problems.": "Desactiva el control en tiempo real por la nube mediante AWS IoT. No se recomienda salvo si tienes problemas de conexión.",
    "Disable local network control. LAN is faster and works without internet; disable it only on network problems.": "Desactiva el control por la red local. La LAN es más rápida y funciona sin internet; desactívala solo si hay problemas de red.",
    "Disable Bluetooth control and sensor scanning.": "Desactiva el control por Bluetooth y la búsqueda de sensores.",
    "Show": "Mostrar",
    "Hide": "Ocultar",
    "Please enter your username and password.": "Introduce tu nombre de usuario y tu contraseña.",
    "Connection failed": "No se ha podido conectar",
    "enabled": "activado",
    "disabled": "desactivado",
    "{transport}: {state}": "{transport}: {state}",
    "Ignored": "Ignorado",
    "Edit": "Editar",
    "Edit {name}": "Editar {name}",
    "Remove": "Quitar",
    "Remove {name}": "Quitar {name}",
    "No devices configured.": "No hay dispositivos configurados.",
    "Remove “{name}” and its settings from the configuration? The change is kept once you click Save Configuration.": "¿Quitar «{name}» y sus ajustes de la configuración? El cambio se conserva al hacer clic en Guardar la configuración.",
    "Advanced settings": "Ajustes avanzados",
    "Back": "Atrás",
    "Add from the Govee library": "Añadir desde la biblioteca de Govee",
    "Loading scenes…": "Cargando escenas…",
    "Nothing selected yet": "Aún no hay nada seleccionado",
    "{n} scene": "{n} escena",
    "{n} scenes": "{n} escenas",
    "{n} DIY effect": "{n} efecto DIY",
    "{n} DIY effects": "{n} efectos DIY",
    "No scenes selected. Pick scenes and your own DIY effects from the library below; each becomes its own switch in HomeKit.": "No hay escenas seleccionadas. Elige escenas y tus propios efectos DIY en la biblioteca de abajo; cada uno se convierte en un interruptor en HomeKit.",
    "Scene": "Escena",
    "Remove the scene": "Quitar la escena",
    "Selected scenes": "Escenas seleccionadas",
    "Clear all": "Borrar todo",
    "Enter the device ID on the General tab and its scenes will appear here.": "Introduce el ID del dispositivo en la pestaña General y sus escenas aparecerán aquí.",
    "This device's model is unknown. Run Discover Devices first so the plugin knows which scenes to offer.": "No se conoce el modelo de este dispositivo. Ejecuta primero Detectar dispositivos para que el plugin sepa qué escenas ofrecer.",
    "Could not load scenes": "No se han podido cargar las escenas",
    "Showing the scene list bundled with the plugin. Log in and rediscover for the full, device-specific list.": "Se muestra la lista de escenas incluida en el plugin. Inicia sesión y vuelve a detectar para tener la lista completa de este dispositivo.",
    "My DIY": "Mis DIY",
    "Govee returned no scenes for this device.": "Govee no ha devuelto ninguna escena para este dispositivo.",
    "{n} scene selected": "{n} escena seleccionada",
    "{n} scenes selected": "{n} escenas seleccionadas",
    "{n} scenes means {n} HomeKit switches on this accessory. Much beyond this and HomeKit may refuse to add it — consider trimming the list.": "{n} escenas son {n} interruptores de HomeKit en este accesorio. Si son muchas más, HomeKit puede negarse a añadirlo: plantéate acortar la lista.",
    "Please enter your username and password in the Settings tab.": "Introduce tu nombre de usuario y tu contraseña en la pestaña Ajustes.",
    "No devices found.": "No se han encontrado dispositivos.",
    "Added {n} new device: ": "{n} dispositivo nuevo añadido: ",
    "Added {n} new devices: ": "{n} dispositivos nuevos añadidos: ",
    "{list}. Click Save Configuration to keep them.": "{list}. Haz clic en Guardar la configuración para conservarlos.",
    "{n} device was already in the configuration.": "{n} dispositivo ya estaba en la configuración.",
    "{n} devices were already in the configuration.": "{n} dispositivos ya estaban en la configuración.",
    "Unknown": "Desconocido",
    "Model: {model}": "Modelo: {model}",
    "Error: {error}": "Error: {error}",
    "Unknown error": "Error desconocido",
    "Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards.": "¿Vaciar la caché? Se borran el inicio de sesión guardado, el certificado IoT y los datos de los dispositivos. Reinicia Homeswift después.",
    "Cache partially cleared": "Caché vaciada en parte",
    "Failed to clear cache": "No se ha podido vaciar la caché",
    "Restarting…": "Reiniciando…",
    "Discover all devices linked to your Govee account and add them to the lists below. Enter your credentials in the {tab} tab first.": "Detecta todos los dispositivos vinculados a tu cuenta de Govee y añádelos a las listas de abajo. Introduce primero tus credenciales en la pestaña {tab}.",
    "Settings": "Ajustes",
    "Your Govee account, the devices it brings to the Home app and how each one appears, scenes and music mode for lights, and the connections the plugin uses.": "Tu cuenta de Govee, los dispositivos que lleva a la app Casa y cómo aparece cada uno, las escenas y el modo música de las luces, y las conexiones que usa el plugin.",
    "Devices": "Dispositivos",
    "Tools": "Herramientas",
    "Discover Devices": "Detectar dispositivos",
    "Account": "Cuenta",
    "Email": "Correo",
    "your-email@example.com": "tu-correo@ejemplo.com",
    "The email address you use to log in to the Govee app. Required for cloud control and device discovery.": "La dirección de correo con la que inicias sesión en la app Govee. Necesaria para el control por la nube y la detección de dispositivos.",
    "Password": "Contraseña",
    "Your Govee account password. Stored in config.json and used only to authenticate with Govee's servers.": "La contraseña de tu cuenta de Govee. Se guarda en config.json y solo se usa para autenticarse en los servidores de Govee.",
    "Verification Code": "Código de verificación",
    "e.g. 1234": "p. ej., 1234",
    "Only needed the first time, or when Govee flags a new device. If Test Connection reports that a code was emailed to you, paste it here and test again. Ignored once login succeeds.": "Solo hace falta la primera vez, o cuando Govee detecta un dispositivo nuevo. Si Probar la conexión indica que te han enviado un código por correo, pégalo aquí y vuelve a probar. Se ignora una vez iniciada la sesión.",
    "Test Connection": "Probar la conexión",
    "Connection": "Conexión",
    "Cache Management": "Gestión de la caché",
    "Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.": "Vacía la caché del plugin si la detección de dispositivos falla o los datos parecen desfasados: el inicio de sesión y el certificado IoT guardados, los dispositivos detectados y su estado guardado. Reinicia Homeswift después.",
    "Clear Cache": "Vaciar la caché",
    "Restart Homeswift": "Reiniciar Homeswift",
    "Documentation": "Documentación",
    "The options are described in the plugin's README; the connections are tried in this order:": "Las opciones se describen en el README del plugin; las conexiones se prueban en este orden:",
    "local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.": "control por la red local (más rápido, funciona sin internet), para los modelos con la API LAN activada en la app Govee.",
    "real-time control through Govee's cloud (requires credentials).": "control en tiempo real por la nube de Govee (requiere credenciales).",
    "Bluetooth control for nearby devices (requires a Bluetooth adapter).": "control por Bluetooth de los dispositivos cercanos (requiere un adaptador Bluetooth).",
    "Username and password are required": "Se necesitan el nombre de usuario y la contraseña",
    "Enter your Govee credentials in the Settings tab first.": "Introduce primero tus credenciales de Govee en la pestaña Ajustes.",
    "Login successful. Account ID: {0}": "Sesión iniciada. ID de la cuenta: {0}",
    "Cache cleared successfully. Please restart Homeswift to apply changes.": "Caché vaciada. Reinicia Homeswift para aplicar los cambios.",
    "Cache partially cleared. Errors: {0}": "Caché vaciada en parte. Errores: {0}",
    "A device ID and model are required to load scenes.": "Se necesitan un ID de dispositivo y un modelo para cargar las escenas.",
    "A device ID and model are required to load DIY effects.": "Se necesitan un ID de dispositivo y un modelo para cargar los efectos DIY.",
    "A device ID and model are required.": "Se necesitan un ID de dispositivo y un modelo.",
    "Govee login failed: {0}": "No se ha podido iniciar sesión en Govee: {0}",
    "Request failed with status code {0}": "La solicitud ha fallado con el código {0}",
    "Govee scene library response did not contain any categories": "La respuesta de la biblioteca de escenas de Govee no contenía ninguna categoría",
    "nothing at {0} {1}": "no hay nada en {0} {1}"
  },
  "pt": {
    "New light": "Nova luz",
    "Light Devices": "Luzes",
    "Add Light Device": "Adicionar luz",
    "Light": "Luz",
    "New switch/outlet": "Novo interruptor/tomada",
    "Switch/Outlet Devices": "Interruptores e tomadas",
    "Add Switch Device": "Adicionar interruptor",
    "Switch/Outlet": "Interruptor/tomada",
    "New temperature/humidity sensor": "Novo sensor de temperatura/humidade",
    "Temperature/Humidity Sensors": "Sensores de temperatura/humidade",
    "Add Sensor": "Adicionar sensor",
    "Temp/Humidity Sensor": "Sensor de temp./humidade",
    "New leak sensor": "Novo sensor de fugas",
    "Leak Sensors": "Sensores de fugas",
    "Add Leak Sensor": "Adicionar sensor de fugas",
    "Leak Sensor": "Sensor de fugas",
    "New fan": "Nova ventoinha",
    "Fan Devices": "Ventoinhas",
    "Add Fan": "Adicionar ventoinha",
    "Fan": "Ventoinha",
    "New heater": "Novo aquecedor",
    "Heater Devices": "Aquecedores",
    "Add Heater": "Adicionar aquecedor",
    "Heater": "Aquecedor",
    "New humidifier": "Novo humidificador",
    "Humidifier Devices": "Humidificadores",
    "Add Humidifier": "Adicionar humidificador",
    "Humidifier": "Humidificador",
    "New air purifier": "Novo purificador de ar",
    "Air Purifier Devices": "Purificadores de ar",
    "Add Purifier": "Adicionar purificador",
    "Air Purifier": "Purificador de ar",
    "New dehumidifier": "Novo desumidificador",
    "Dehumidifier Devices": "Desumidificadores",
    "Add Dehumidifier": "Adicionar desumidificador",
    "Dehumidifier": "Desumidificador",
    "New diffuser": "Novo difusor",
    "Diffuser Devices": "Difusores",
    "Add Diffuser": "Adicionar difusor",
    "Diffuser": "Difusor",
    "New kettle": "Nova chaleira",
    "Kettle Devices": "Chaleiras",
    "Add Kettle": "Adicionar chaleira",
    "Kettle": "Chaleira",
    "New ice maker": "Nova máquina de gelo",
    "Ice Maker Devices": "Máquinas de gelo",
    "Add Ice Maker": "Adicionar máquina de gelo",
    "Ice Maker": "Máquina de gelo",
    "{n} light": "{n} luz",
    "{n} lights": "{n} luzes",
    "{n} switch/outlet": "{n} interruptor/tomada",
    "{n} switches/outlets": "{n} interruptores/tomadas",
    "{n} temperature/humidity sensor": "{n} sensor de temperatura/humidade",
    "{n} temperature/humidity sensors": "{n} sensores de temperatura/humidade",
    "{n} leak sensor": "{n} sensor de fugas",
    "{n} leak sensors": "{n} sensores de fugas",
    "{n} fan": "{n} ventoinha",
    "{n} fans": "{n} ventoinhas",
    "{n} heater": "{n} aquecedor",
    "{n} heaters": "{n} aquecedores",
    "{n} humidifier": "{n} humidificador",
    "{n} humidifiers": "{n} humidificadores",
    "{n} air purifier": "{n} purificador de ar",
    "{n} air purifiers": "{n} purificadores de ar",
    "{n} dehumidifier": "{n} desumidificador",
    "{n} dehumidifiers": "{n} desumidificadores",
    "{n} diffuser": "{n} difusor",
    "{n} diffusers": "{n} difusores",
    "{n} kettle": "{n} chaleira",
    "{n} kettles": "{n} chaleiras",
    "{n} ice maker": "{n} máquina de gelo",
    "{n} ice makers": "{n} máquinas de gelo",
    "Device ID": "ID do dispositivo",
    "Custom Label": "Nome personalizado",
    "Ignore Device": "Ignorar o dispositivo",
    "General": "Geral",
    "Scene Library": "Biblioteca de cenas",
    "Music Mode": "Modo música",
    "Govee's own identifier for this light. Discover Devices fills it in for you.": "O identificador que a Govee dá a esta luz. Descobrir dispositivos preenche-o automaticamente.",
    "Replaces the name HomeKit shows. Leave blank to keep the name set in the Govee app.": "Substitui o nome que o HomeKit mostra. Deixe vazio para manter o nome definido na app Govee.",
    "Keeps this light out of HomeKit without discarding any of the settings below.": "Mantém esta luz fora do HomeKit sem descartar nenhuma das definições abaixo.",
    "Show As": "Mostrar como",
    "A Light gets brightness and colour controls. Pick Switch for a light you only ever turn on and off.": "Uma luz tem controlos de brilho e cor. Escolha Interruptor para uma luz que só liga e desliga.",
    "Light (default)": "Luz (predefinido)",
    "Switch": "Interruptor",
    "Add a Music tile to HomeKit": "Adicionar um mosaico de música ao HomeKit",
    "Adds a second tile for this light. On/off starts music mode, brightness is the microphone sensitivity, and colour sets the music colour.": "Adiciona um segundo mosaico para esta luz. Ligar/desligar inicia o modo música, o brilho é a sensibilidade do microfone e a cor define a cor da música.",
    "Effect": "Efeito",
    "How the light reacts to sound. Rhythm follows the beat, Energic flashes on peaks, Rolling sweeps colour along the strip, and Spectrum maps pitch to colour.": "Como a luz reage ao som. Ritmo segue a batida, Enérgico pisca nos picos, Deslizante percorre a fita com a cor e Espetro associa cada tom a uma cor.",
    "Rhythm": "Ritmo",
    "Energic": "Enérgico",
    "Rolling": "Deslizante",
    "Spectrum": "Espetro",
    "Default Sensitivity": "Sensibilidade predefinida",
    "How loud a sound must be before the light reacts. Only the starting value: the tile's brightness slider changes it live.": "O volume que um som deve ter para a luz reagir. É só o valor inicial: o controlo de brilho do mosaico altera-o em direto.",
    "Auto Colour": "Cor automática",
    "Let the light pick colours from the music itself. Turn this off to choose the colour yourself, from the tile's colour picker.": "A luz escolhe as cores a partir da música. Desative para escolher a cor no seletor de cor do mosaico.",
    "Soft Rhythm": "Ritmo suave",
    "Rhythm only: the gentler of its two styles, with slower fades between beats.": "Só Ritmo: o mais suave dos seus dois estilos, com transições mais lentas entre batidas.",
    "Protocol": "Protocolo",
    "Older lights speak an earlier version of the music command. If the tile appears but does nothing, switch to Legacy.": "As luzes mais antigas usam uma versão anterior do comando de música. Se o mosaico aparecer mas não fizer nada, mude para Antigo.",
    "Modern": "Moderno",
    "Legacy (older lights)": "Antigo (luzes mais antigas)",
    "Custom IP Address": "Endereço IP personalizado",
    "Only for LAN control, when the light is not found automatically. Pair it with a DHCP reservation so the address does not move.": "Só para o controlo por LAN, quando a luz não é encontrada automaticamente. Combine-o com uma reserva DHCP para que o endereço não mude.",
    "Custom BLE Address": "Endereço BLE personalizado",
    "The light's Bluetooth MAC address. Only needed when Bluetooth control cannot find the device by name.": "O endereço MAC Bluetooth da luz. Só é preciso quando o controlo por Bluetooth não encontra o dispositivo pelo nome.",
    "Brightness Step": "Passo de brilho",
    "Smallest brightness change HomeKit will send. Raise it to stop a dragged slider flooding the light with updates.": "A menor alteração de brilho que o HomeKit envia. Aumente-a para que um controlo arrastado não inunde a luz de atualizações.",
    "Adaptive Lighting": "Iluminação adaptativa",
    "Warmth shift": "Desvio para o quente",
    "Lets HomeKit track the colour temperature to the time of day. Turn it off to keep whatever colour you set.": "Deixa o HomeKit ajustar a temperatura de cor à hora do dia. Desative para manter a cor que definir.",
    "Biases the curve warmer than Apple's. 150 keeps evenings noticeably cosier; 0 follows HomeKit exactly.": "Torna a curva mais quente do que a da Apple. 150 deixa as noites visivelmente mais acolhedoras; 0 segue o HomeKit exatamente.",
    "AWS Brightness No Scale": "Brilho AWS sem escala",
    "Sends brightness as 0-100 instead of 0-254. A few models need this, otherwise they jump straight to full brightness.": "Envia o brilho de 0 a 100 em vez de 0 a 254. Alguns modelos precisam disto; caso contrário, saltam logo para o brilho máximo.",
    "AWS Colour Mode": "Modo de cor AWS",
    "Which shape of colour command this model accepts over the cloud connection. Change it only if colours are ignored or come out wrong.": "O formato do comando de cor que este modelo aceita pela nuvem. Altere-o só se as cores forem ignoradas ou saírem erradas.",
    "Default": "Predefinido",
    "RGB": "RGB",
    "Red/Green/Blue": "Vermelho/verde/azul",
    "Scenes over LAN": "Cenas por LAN",
    "Sends scenes, DIY effects and music mode straight to the light on your network, which is faster and works without the cloud. The light does not confirm LAN commands: if a scene does nothing, turn this off.": "Envia as cenas, os efeitos DIY e o modo de música diretamente para a luz na sua rede, o que é mais rápido e funciona sem a nuvem. A luz não confirma os comandos LAN: se uma cena não fizer nada, desative esta opção.",
    "Default (Switch)": "Predefinido (interruptor)",
    "Outlet": "Tomada",
    "Cooler": "Arrefecedor",
    "Tap/Faucet": "Torneira",
    "Valve": "Válvula",
    "Audio Receiver": "Recetor de áudio",
    "Set-Top Box": "Box de TV",
    "Streaming Stick": "Pen de streaming",
    "Temperature Source (Device ID)": "Origem da temperatura (ID do dispositivo)",
    "For a plug shown as a heater or a cooler: the Govee thermo-hygrometer whose temperature switches it.": "Para uma tomada mostrada como aquecedor ou arrefecedor: o termo-higrómetro Govee cuja temperatura a aciona.",
    "Low Battery Threshold (%)": "Limiar de bateria fraca (%)",
    "Show Extra Switch": "Mostrar um interruptor adicional",
    "Hide Light Control": "Ocultar o controlo de luz",
    "Temperature Reporting": "Leitura de temperatura",
    "Hide Green Tea Mode": "Ocultar o modo chá verde",
    "Hide Oolong Tea Mode": "Ocultar o modo chá oolong",
    "Hide Coffee Mode": "Ocultar o modo café",
    "Hide Black Tea Mode": "Ocultar o modo chá preto",
    "Show Custom Mode 1": "Mostrar o modo personalizado 1",
    "Show Custom Mode 2": "Mostrar o modo personalizado 2",
    "Unsaved changes": "Alterações não guardadas",
    "Changes are kept once you save.": "As alterações só são mantidas depois de guardar.",
    "Saved. Restart Homeswift to apply: {changes}.": "Guardado. Reinicie o Homeswift para aplicar: {changes}.",
    "Saved: the plugin restarted with the new configuration.": "Guardado: o plugin reiniciou com a nova configuração.",
    "Failed to save configuration: {error}": "Não foi possível guardar a configuração: {error}",
    "Save Configuration": "Guardar a configuração",
    "HTTP Refresh (seconds)": "Atualização HTTP (segundos)",
    "How often to poll the Govee API for sensor readings. Minimum 30 seconds; leave blank for the default of 30.": "Com que frequência a API da Govee é consultada para as leituras dos sensores. Mínimo de 30 segundos; deixe vazio para o valor predefinido de 30.",
    "Refresh (seconds)": "Atualização (segundos)",
    "How often to poll LAN devices for their state. Leave blank for the default of 30.": "Com que frequência é consultado o estado dos dispositivos LAN. Deixe vazio para o valor predefinido de 30.",
    "Scan Interval (seconds)": "Intervalo de pesquisa (segundos)",
    "How often to scan the network for new LAN-capable devices. Minimum 30 seconds; leave blank for the default of 60.": "Com que frequência a rede é pesquisada à procura de novos dispositivos com LAN. Mínimo de 30 segundos; deixe vazio para o valor predefinido de 60.",
    "How often to scan for BLE sensor readings. Minimum 60 seconds; leave blank for the default of 300.": "Com que frequência são procuradas leituras de sensores BLE. Mínimo de 60 segundos; deixe vazio para o valor predefinido de 300.",
    "Control Interval (ms)": "Intervalo de controlo (ms)",
    "Minimum time between BLE commands, so devices are not overwhelmed. Minimum 500 ms; leave blank for the default of 500.": "Tempo mínimo entre comandos BLE, para não sobrecarregar os dispositivos. Mínimo de 500 ms; deixe vazio para o valor predefinido de 500.",
    "Ignore Matter Devices": "Ignorar os dispositivos Matter",
    "Skip devices that support Matter. Enable this if you connect those devices to HomeKit through Matter directly.": "Ignora os dispositivos compatíveis com Matter. Ative se os ligar ao HomeKit diretamente por Matter.",
    "Disable Device Logging": "Desativar o registo dos dispositivos",
    "Stop logging device state changes to reduce log clutter. Errors are still logged.": "Deixa de registar as alterações de estado dos dispositivos para aligeirar o registo. Os erros continuam a ser registados.",
    "Colour Safe Mode": "Modo de cor seguro",
    "A slower but more reliable way of setting colours. Enable this if your lights show colour problems.": "Uma forma mais lenta mas mais fiável de definir as cores. Ative se as luzes tiverem problemas de cor.",
    "Debug Logging": "Registo de depuração",
    "Verbose debug logging in the Homeswift log.": "Registo de depuração detalhado no registo do Homeswift.",
    "Disable": "Desativar",
    "Disable real-time cloud control through AWS IoT. Not recommended unless you have connection problems.": "Desativa o controlo em tempo real pela nuvem através do AWS IoT. Não recomendado, exceto em caso de problemas de ligação.",
    "Disable local network control. LAN is faster and works without internet; disable it only on network problems.": "Desativa o controlo pela rede local. A LAN é mais rápida e funciona sem internet; desative-a só em caso de problemas de rede.",
    "Disable Bluetooth control and sensor scanning.": "Desativa o controlo por Bluetooth e a pesquisa de sensores.",
    "Show": "Mostrar",
    "Hide": "Ocultar",
    "Please enter your username and password.": "Introduza o nome de utilizador e a palavra-passe.",
    "Connection failed": "Falha na ligação",
    "enabled": "ativado",
    "disabled": "desativado",
    "{transport}: {state}": "{transport}: {state}",
    "Ignored": "Ignorado",
    "Edit": "Editar",
    "Edit {name}": "Editar {name}",
    "Remove": "Remover",
    "Remove {name}": "Remover {name}",
    "No devices configured.": "Nenhum dispositivo configurado.",
    "Remove “{name}” and its settings from the configuration? The change is kept once you click Save Configuration.": "Remover «{name}» e as suas definições da configuração? A alteração fica guardada quando clicar em Guardar a configuração.",
    "Advanced settings": "Definições avançadas",
    "Back": "Voltar",
    "Add from the Govee library": "Adicionar a partir da biblioteca Govee",
    "Loading scenes…": "A carregar cenas…",
    "Nothing selected yet": "Ainda nada selecionado",
    "{n} scene": "{n} cena",
    "{n} scenes": "{n} cenas",
    "{n} DIY effect": "{n} efeito DIY",
    "{n} DIY effects": "{n} efeitos DIY",
    "No scenes selected. Pick scenes and your own DIY effects from the library below; each becomes its own switch in HomeKit.": "Nenhuma cena selecionada. Escolha cenas e os seus próprios efeitos DIY na biblioteca abaixo; cada um torna-se um interruptor no HomeKit.",
    "Scene": "Cena",
    "Remove the scene": "Remover a cena",
    "Selected scenes": "Cenas selecionadas",
    "Clear all": "Limpar tudo",
    "Enter the device ID on the General tab and its scenes will appear here.": "Introduza o ID do dispositivo no separador Geral e as suas cenas aparecem aqui.",
    "This device's model is unknown. Run Discover Devices first so the plugin knows which scenes to offer.": "O modelo deste dispositivo é desconhecido. Execute primeiro Descobrir dispositivos para que o plugin saiba que cenas oferecer.",
    "Could not load scenes": "Não foi possível carregar as cenas",
    "Showing the scene list bundled with the plugin. Log in and rediscover for the full, device-specific list.": "É mostrada a lista de cenas incluída no plugin. Inicie sessão e volte a descobrir para obter a lista completa deste dispositivo.",
    "My DIY": "Os meus DIY",
    "Govee returned no scenes for this device.": "A Govee não devolveu nenhuma cena para este dispositivo.",
    "{n} scene selected": "{n} cena selecionada",
    "{n} scenes selected": "{n} cenas selecionadas",
    "{n} scenes means {n} HomeKit switches on this accessory. Much beyond this and HomeKit may refuse to add it — consider trimming the list.": "{n} cenas são {n} interruptores do HomeKit neste acessório. Muito acima disto, o HomeKit pode recusar adicioná-lo: considere encurtar a lista.",
    "Please enter your username and password in the Settings tab.": "Introduza o nome de utilizador e a palavra-passe no separador Definições.",
    "No devices found.": "Nenhum dispositivo encontrado.",
    "Added {n} new device: ": "{n} dispositivo novo adicionado: ",
    "Added {n} new devices: ": "{n} dispositivos novos adicionados: ",
    "{list}. Click Save Configuration to keep them.": "{list}. Clique em Guardar a configuração para os manter.",
    "{n} device was already in the configuration.": "{n} dispositivo já estava na configuração.",
    "{n} devices were already in the configuration.": "{n} dispositivos já estavam na configuração.",
    "Unknown": "Desconhecido",
    "Model: {model}": "Modelo: {model}",
    "Error: {error}": "Erro: {error}",
    "Unknown error": "Erro desconhecido",
    "Clear the cache? This removes the saved login, the IoT certificate and the device data. Restart Homeswift afterwards.": "Limpar a cache? Isto remove o início de sessão guardado, o certificado IoT e os dados dos dispositivos. Reinicie o Homeswift a seguir.",
    "Cache partially cleared": "Cache parcialmente limpa",
    "Failed to clear cache": "Não foi possível limpar a cache",
    "Restarting…": "A reiniciar…",
    "Discover all devices linked to your Govee account and add them to the lists below. Enter your credentials in the {tab} tab first.": "Descubra todos os dispositivos associados à sua conta Govee e adicione-os às listas abaixo. Introduza primeiro as credenciais no separador {tab}.",
    "Settings": "Definições",
    "Your Govee account, the devices it brings to the Home app and how each one appears, scenes and music mode for lights, and the connections the plugin uses.": "A sua conta Govee, os dispositivos que traz para a app Casa e como cada um aparece, as cenas e o modo música das luzes, e as ligações que o plugin usa.",
    "Devices": "Dispositivos",
    "Tools": "Ferramentas",
    "Discover Devices": "Descobrir dispositivos",
    "Account": "Conta",
    "Email": "E-mail",
    "your-email@example.com": "o-seu-email@exemplo.com",
    "The email address you use to log in to the Govee app. Required for cloud control and device discovery.": "O endereço de e-mail com que inicia sessão na app Govee. Necessário para o controlo pela nuvem e a descoberta de dispositivos.",
    "Password": "Palavra-passe",
    "Your Govee account password. Stored in config.json and used only to authenticate with Govee's servers.": "A palavra-passe da sua conta Govee. Guardada no config.json e usada só para autenticar nos servidores da Govee.",
    "Verification Code": "Código de verificação",
    "e.g. 1234": "p. ex. 1234",
    "Only needed the first time, or when Govee flags a new device. If Test Connection reports that a code was emailed to you, paste it here and test again. Ignored once login succeeds.": "Só é necessário da primeira vez, ou quando a Govee assinala um novo dispositivo. Se Testar a ligação indicar que foi enviado um código por e-mail, cole-o aqui e teste de novo. Ignorado depois de iniciar sessão.",
    "Test Connection": "Testar a ligação",
    "Connection": "Ligação",
    "Cache Management": "Gestão da cache",
    "Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.": "Limpe a cache do plugin se a descoberta de dispositivos falhar ou os dados parecerem desatualizados: o início de sessão e o certificado IoT guardados, os dispositivos descobertos e o seu estado guardado. Reinicie o Homeswift a seguir.",
    "Clear Cache": "Limpar a cache",
    "Restart Homeswift": "Reiniciar o Homeswift",
    "Documentation": "Documentação",
    "The options are described in the plugin's README; the connections are tried in this order:": "As opções estão descritas no README do plugin; as ligações são tentadas por esta ordem:",
    "local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.": "controlo pela rede local (mais rápido, funciona sem internet), para os modelos com a API LAN ativada na app Govee.",
    "real-time control through Govee's cloud (requires credentials).": "controlo em tempo real pela nuvem da Govee (requer credenciais).",
    "Bluetooth control for nearby devices (requires a Bluetooth adapter).": "controlo por Bluetooth dos dispositivos próximos (requer um adaptador Bluetooth).",
    "Username and password are required": "São necessários o nome de utilizador e a palavra-passe",
    "Enter your Govee credentials in the Settings tab first.": "Introduza primeiro as credenciais Govee no separador Definições.",
    "Login successful. Account ID: {0}": "Sessão iniciada. ID da conta: {0}",
    "Cache cleared successfully. Please restart Homeswift to apply changes.": "Cache limpa. Reinicie o Homeswift para aplicar as alterações.",
    "Cache partially cleared. Errors: {0}": "Cache parcialmente limpa. Erros: {0}",
    "A device ID and model are required to load scenes.": "São necessários um ID de dispositivo e um modelo para carregar as cenas.",
    "A device ID and model are required to load DIY effects.": "São necessários um ID de dispositivo e um modelo para carregar os efeitos DIY.",
    "A device ID and model are required.": "São necessários um ID de dispositivo e um modelo.",
    "Govee login failed: {0}": "Não foi possível iniciar sessão na Govee: {0}",
    "Request failed with status code {0}": "O pedido falhou com o código {0}",
    "Govee scene library response did not contain any categories": "A resposta da biblioteca de cenas Govee não continha nenhuma categoria",
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
      <p class="muted" data-i18n>Your Govee account, the devices it brings to the Home app and how each one appears, scenes and music mode for lights, and the connections the plugin uses.</p>
    </div>
  </div>

  <div class="group tabs main-tabs" role="tablist">
    <button role="tab" data-tab="devices" class="on" aria-selected="true" aria-controls="tab-devices" data-i18n>Devices</button>
    <button role="tab" data-tab="settings" aria-selected="false" aria-controls="tab-settings" data-i18n data-action-icon="sliders">Settings</button>
    <button role="tab" data-tab="tools" aria-selected="false" aria-controls="tab-tools" data-i18n>Tools</button>
  </div>

  <section id="tab-devices" class="tab-pane" role="tabpanel">
    <div class="card discover">
      <div class="discover-head">
        <p id="discover-intro" class="muted">Discover all devices linked to your Govee account and add them to the lists below. Enter your credentials in the <strong>Settings</strong> tab first.</p>
        <button id="discover" class="primary" data-i18n data-action-icon="search">Discover Devices</button>
      </div>
      <div id="discover-result"></div>
    </div>
    <div id="device-types"></div>
    <div id="editor" class="card editor hidden"></div>
  </section>

  <section id="tab-settings" class="tab-pane hidden" role="tabpanel">
    <div class="card">
      <h2 data-i18n>Account</h2>
      <div class="fields">
        <label class="field"><span class="field-title" data-i18n>Email</span>
          <input type="email" id="username" data-i18n placeholder="your-email@example.com" autocomplete="username">
          <span class="help" data-i18n>The email address you use to log in to the Govee app. Required for cloud control and device discovery.</span></label>
        <label class="field"><span class="field-title" data-i18n>Password</span>
          <span class="password"><input type="password" id="password" autocomplete="current-password"><button type="button" id="toggle-password" data-i18n data-action-icon="eye">Show</button></span>
          <span class="help" data-i18n>Your Govee account password. Stored in config.json and used only to authenticate with Govee's servers.</span></label>
        <label class="field"><span class="field-title" data-i18n>Verification Code</span>
          <input type="text" id="code" data-i18n placeholder="e.g. 1234" autocomplete="one-time-code" inputmode="numeric">
          <span class="help" data-i18n>Only needed the first time, or when Govee flags a new device. If Test Connection reports that a code was emailed to you, paste it here and test again. Ignored once login succeeds.</span></label>
      </div>
      <div class="actions"><button id="test-login" data-i18n>Test Connection</button></div>
      <div id="login-result"></div>
    </div>

    <div class="card">
      <h2 data-i18n>General</h2>
      <div id="general"></div>
    </div>

    <div class="card">
      <h2 data-i18n>Connection</h2>
      <div class="connections">
        <div><h3>AWS IoT</h3><div id="connection-aws"></div></div>
        <div><h3>LAN</h3><div id="connection-lan"></div></div>
        <div><h3>Bluetooth (BLE)</h3><div id="connection-ble"></div></div>
      </div>
    </div>
  </section>

  <section id="tab-tools" class="tab-pane hidden" role="tabpanel">
    <div class="card">
      <h2 data-i18n>Cache Management</h2>
      <p class="muted" data-i18n>Clear the plugin's cache if device discovery misbehaves or data looks stale: the saved login and IoT certificate, the discovered devices, the devices' saved state. Restart Homeswift afterwards.</p>
      <div class="actions"><button id="clear-cache" class="danger" data-i18n data-action-icon="trash">Clear Cache</button><button id="restart" class="hidden" data-i18n data-action-icon="power">Restart Homeswift</button></div>
      <div id="clear-result"></div>
    </div>
    <div class="card">
      <h2 data-i18n>Documentation</h2>
      <p data-i18n>The options are described in the plugin's README; the connections are tried in this order:</p>
      <ul class="docs">
        <li><strong>LAN:</strong> <span data-i18n>local network control (faster, works without internet), for models with the LAN API turned on in the Govee app.</span></li>
        <li><strong>AWS IoT:</strong> <span data-i18n>real-time control through Govee's cloud (requires credentials).</span></li>
        <li><strong>BLE:</strong> <span data-i18n>Bluetooth control for nearby devices (requires a Bluetooth adapter).</span></li>
      </ul>
    </div>
  </section>

  <div class="card save-card">
    <div class="save-bar"><span id="save-state" class="muted" data-i18n>Changes are kept once you save.</span><button id="save" class="primary" data-i18n data-action-icon="check">Save Configuration</button></div>
  </div>
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
