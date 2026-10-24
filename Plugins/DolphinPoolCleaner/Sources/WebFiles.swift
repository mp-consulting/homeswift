// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension DolphinPoolCleanerPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Dolphin Pool Cleaner page, after the Homebridge plugin's setup wizard: the robots in this instance's block
// (with their live state), then sign-in with the MyDolphin Plus email and a verification code, the robot found and
// its settings, and done. Saving writes the block with a refresh token instead of a password; the plugin reloads.
(() => {
  "use strict";
  const { $, el, request, explain, assistant, breadcrumb, act, poll, fact, readBlock, updateBlock } = homeswift;

  const IOT_REGION = "eu-west-1";
  const DEVICE_TYPE_LABELS = { 62: "IoT Connected (M400/M600)", 60: "IoT Connected", 50: "BLE Connected" };
  const CLEANING_MODES = {
    all: { name: "All Surfaces", description: "Full pool cleaning covering floor, walls, and waterline. Most thorough cleaning option.", duration: 150 },
    floor: { name: "Floor Only", description: "Cleans just the pool bottom. Good for quick maintenance when walls are still clean.", duration: 150 },
    wall: { name: "Walls Only", description: "Cleans vertical surfaces of the pool. Useful after storms or algae treatment.", duration: 120 },
    water: { name: "Waterline", description: "Focuses on the water surface line where debris and oils accumulate.", duration: 150 },
    short: { name: "Short/Fast", description: "Quick cleaning cycle for light maintenance between full cleans.", duration: 150 },
    ultra: { name: "Ultra Clean", description: "Intensive deep cleaning mode for heavily soiled pools. Most thorough option.", duration: 150 },
    cove: { name: "Cove", description: "Focuses on corners and coves where floor meets walls. Catches hard-to-reach debris.", duration: 120 },
    spot: { name: "Spot", description: "Concentrated cleaning in a localized area. Drop robot where needed.", duration: 120 },
    tictac: { name: "Tic Tac", description: "Extended systematic coverage pattern for very large or complex pools.", duration: 600 },
    pickup: { name: "Pickup", description: "Quick retrieval mode - robot moves to edge for easy removal from pool.", duration: 5 },
    custom: { name: "Custom", description: "User-defined cleaning cycle with custom duration.", duration: 120 },
  };
  // The modes the wizard offers, in its order.
  const MODE_CHOICES = ["all", "floor", "wall", "water", "short", "ultra", "cove", "spot"];
  const POLLING_CHOICES = [[30, "30 seconds"], [60, "60 seconds (Recommended)"], [120, "2 minutes"], [300, "5 minutes"]];

  // Older versions saved "regular", which the plugin treats as "all".
  const normalizeMode = (mode) => (mode === "regular" ? "all" : mode);
  const deviceTypeLabel = (type) => DEVICE_TYPE_LABELS[type] || (type ? `Type ${type}` : "—");
  function formatDuration(minutes) {
    if (minutes < 60) return `${minutes} min`;
    if (minutes === 60) return "1 hour";
    if (minutes % 60 === 0) return `${minutes / 60} hours`;
    return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  }
  function modeText(mode) {
    const info = CLEANING_MODES[normalizeMode(mode)];
    return info ? `${info.name} (${formatDuration(info.duration)})` : mode || "All Surfaces";
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
    robotData: null,      // the robot being added or edited, with the account it came from
    pendingEmail: null,
    editingIndex: null,   // the device entry being edited
    saved: null,          // the block as last read
    live: [],             // what the plugin reports about its robots
    status: null,
    error: null,
  };
  let current = null;

  function show(step, ...children) {
    current = step;
    wizard.replaceChildren(el("div", { class: `step step-${step}` }, ...children));
    const focus = wizard.querySelector("[autofocus]");
    if (focus) focus.focus();
    breadcrumb(step === "configured" ? null : { login: "Sign in", otp: "Verification", robot: state.editingIndex !== null ? "Edit robot" : "Robot found", success: "Done" }[step], () => showConfigured());
  }

  const head = (title, text) => [el("div", { class: "step-head" }, el("h2", { text: title })), text ? el("p", { class: "muted", text }) : null];
  const statusLine = () => el("p", { class: "status-line", role: "status" });
  function fail(line, message, context) {
    line.className = "status-line error";
    line.replaceChildren(message, explain({ error: message, context, device: { model: "Maytronics Dolphin pool robot (MyDolphin Plus)" } }));
  }

  // Step 0: the configured robots.

  async function showConfigured() {
    let block;
    try {
      block = await readBlock();
    } catch (e) {
      show("configured", el("p", { class: "error", text: e.message }));
      return;
    }
    state.saved = block;
    const devices = block.devices || [];
    if (!devices.length) {
      showLogin();
      return;
    }
    state.editingIndex = null;
    const list = el("div", { class: "robots" }, devices.map((device, index) => robotCard(device, block.email, index)));
    const account = el("p", { class: "status-line" });
    describeAccount(account);
    show("configured",
      ...head("Your Dolphin Robots", "Manage your configured pool robots. A robot's card opens its settings."),
      account, list,
      el("div", { class: "actions" },
        el("button", { text: "Add Another Robot", onclick: () => showLogin({ cancellable: true }) }),
        el("button", { class: "primary", text: "Reconfigure", onclick: () => showLogin({ cancellable: true }) })));
  }

  function describeAccount(line) {
    const { status, error } = state;
    if (status === "notConfigured") {
      line.className = "status-line error";
      line.textContent = "No account yet: Reconfigure signs in and stores a refresh token.";
    } else if (status === "failed" || status === "retrying") {
      fail(line, error || "The plugin cannot reach MyDolphin Plus.",
        `The Homeswift Dolphin plugin signs in with Cognito (refresh token or email and password), then MyDolphin authenticate-user and getToken, then AWS IoT MQTT (eu-west-1). Plugin status: ${status}.`);
      if (status === "retrying") line.prepend("Retrying: ");
    } else if (status === "signingIn") {
      line.className = "status-line muted";
      line.textContent = "Signing in to MyDolphin Plus…";
    } else {
      line.className = "status-line muted";
      line.textContent = "";
    }
  }

  function liveState(serial) {
    const robot = state.live.find((r) => r.serialNumber === serial);
    if (!robot) return { text: "Configured", kind: "standby" };
    if (!robot.connected) return { text: "Not connected", kind: "away", robot };
    if (robot.fault) return { text: robot.fault, kind: "away", robot };
    return robot.isCleaning ? { text: "Cleaning", kind: "on", robot } : { text: "Idle", kind: "standby", robot };
  }

  function robotCard(device, email, index) {
    const live = liveState(device.serialNumber);
    const facts = [
      fact("Serial Number", device.serialNumber || "—"),
      fact("Device Type", deviceTypeLabel(device.deviceType)),
      fact("Account", email || "—"),
      fact("Cleaning Mode", modeText(device.cleaningMode)),
    ];
    if (live.robot) {
      facts.push(fact("Filter", live.robot.filterStatus === "needs_cleaning" ? "Needs cleaning" : "OK"));
      if (live.robot.isCleaning && live.robot.cycleTimeRemaining > 0) facts.push(fact("Time left", formatDuration(live.robot.cycleTimeRemaining)));
      if (typeof live.robot.temperature === "number") facts.push(fact("Water", homeswift.formatTemperature(live.robot.temperature)));
    }
    const card = el("div", { class: "card robot", role: "button", tabIndex: 0, "aria-label": `Edit ${device.name || "Dolphin Robot"}` },
      picture(device.serialNumber, el("span", { class: `pill status ${live.kind}`, text: live.text })),
      el("div", { class: "body" },
        el("div", { class: "head" }, el("strong", { text: device.name || "Dolphin Robot" })),
        el("div", { class: "facts" }, facts),
        el("span", { class: "edit", "aria-hidden": "true", text: "Edit settings ›" })));
    card.addEventListener("click", () => editDevice(index));
    card.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); editDevice(index); }
    });
    return card;
  }

  // Step 1: the email; Cognito sends a code.

  function showLogin({ cancellable = false } = {}) {
    const email = el("input", { type: "email", name: "email", placeholder: "your@email.com", required: true, autocomplete: "email", autofocus: true, value: state.saved?.email || "" });
    const line = statusLine();
    const send = el("button", { class: "primary", type: "submit", text: "Send Verification Code" });
    const form = el("form", { class: "narrow", onsubmit: (event) => { event.preventDefault(); act(send, () => login(email.value.trim(), line), (message) => loginProblem(line, message)); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: "Email" }), email,
        el("span", { class: "help", text: "The email associated with your MyDolphin Plus account" })),
      line,
      el("div", { class: "actions" }, cancellable ? el("button", { type: "button", text: "Cancel", onclick: showConfigured }) : null, send));
    // Without an Assistant, a tip on how to get one, as the Homebridge plugin's wizard shows.
    const hint = el("p", { class: "hint muted hidden" }, "Tip: add a ", el("strong", { text: "HomeswiftAiKit" }),
      " block to config.json to get the Assistant, which explains sign-in errors here.");
    assistant().then((status) => hint.classList.toggle("hidden", Boolean(status.enabled)));
    show("login", ...head("Connect Your MyDolphin Account", "Enter your MyDolphin Plus email address. A verification code will be sent to you."), form, hint);
  }

  function loginProblem(line, message) {
    fail(line, message, "Step 1 of the Dolphin setup page: requesting a verification code for the MyDolphin Plus account (AWS Cognito CUSTOM_AUTH, InitiateAuth) failed.");
  }

  async function login(email, line) {
    if (!email) throw new Error("Please enter your email address");
    state.pendingEmail = email;
    line.className = "status-line muted";
    line.textContent = "";
    const result = await request("authenticate", { method: "POST", body: { email } });
    if (result.success) authenticated(result, email);
    else if (result.requiresOtp) showCode(result.message);
    else loginProblem(line, result.error || "Authentication failed");
  }

  // Step 1b: the code.

  function showCode(message) {
    const code = el("input", { class: "code-input", type: "text", name: "otpCode", placeholder: "Enter code", required: true, autocomplete: "one-time-code", inputMode: "numeric", pattern: "[0-9]*", maxLength: 6, autofocus: true });
    const line = statusLine();
    const prompt = el("p", { class: "muted", text: message || "Please enter the verification code sent to your email." });
    const verify = el("button", { class: "primary", type: "submit", text: "Verify" });
    const form = el("form", { class: "narrow", onsubmit: (event) => { event.preventDefault(); act(verify, () => verifyCode(code, prompt, line), (text) => codeProblem(line, text)); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: "Verification Code" }), code,
        el("span", { class: "help", text: "Check your email or phone for the verification code" })),
      line,
      el("div", { class: "actions" }, el("button", { type: "button", text: "Back", onclick: () => showLogin({ cancellable: Boolean(state.saved?.devices?.length) }) }), verify));
    show("otp", el("div", { class: "step-head" }, el("h2", { text: "Verification Required" })), prompt, form);
  }

  function codeProblem(line, message) {
    fail(line, message, "Step 2 of the Dolphin setup page: verifying the code (AWS Cognito RespondToAuthChallenge, then the MyDolphin authenticate-user call that returns the robot) failed. The code session lasts 5 minutes.");
  }

  async function verifyCode(input, prompt, line) {
    const otpCode = input.value.trim();
    if (!otpCode) throw new Error("Please enter the verification code");
    if (!state.pendingEmail) { showLogin(); return; }
    line.className = "status-line muted";
    line.textContent = "";
    const result = await request("verify-otp", { method: "POST", body: { email: state.pendingEmail, otpCode } });
    if (result.success) authenticated(result, state.pendingEmail);
    else if (result.requiresOtp) {
      prompt.textContent = result.message || "Please enter the new verification code.";
      input.value = "";
      input.focus();
    } else codeProblem(line, result.error || "Verification failed");
  }

  function authenticated(result, email) {
    state.editingIndex = null;
    state.robotData = {
      email, iotRegion: IOT_REGION, serialNumber: result.serialNumber, robotName: result.robotName, model: result.model,
      deviceType: result.deviceType, robotImageUrl: result.robotImageUrl, refreshToken: result.refreshToken,
    };
    showRobot();
  }

  // Step 2: the robot and its settings.

  function editDevice(index) {
    const device = state.saved?.devices?.[index];
    if (!device) return;
    state.editingIndex = index;
    state.robotData = {
      email: state.saved.email, iotRegion: IOT_REGION, serialNumber: device.serialNumber, robotName: device.name, deviceType: device.deviceType,
      robotImageUrl: device.robotImageUrl, refreshToken: state.saved.refreshToken,
    };
    showRobot(device);
  }

  function showRobot(device = state.saved?.devices?.find((d) => d.serialNumber === state.robotData.serialNumber) || state.saved?.devices?.[0]) {
    const data = state.robotData;
    const editing = state.editingIndex !== null;
    const displayName = el("input", { type: "text", value: data.robotName || "", placeholder: "My Pool Robot", maxLength: 64 });
    const mode = el("select", {}, MODE_CHOICES.map((key) => el("option", { value: key, text: CLEANING_MODES[key].name })));
    mode.value = normalizeMode(device?.cleaningMode) || "all";
    if (!mode.value) mode.value = "all";
    const description = el("p", {});
    const duration = el("div", { class: "muted" });
    const updateMode = () => {
      const info = CLEANING_MODES[mode.value] || CLEANING_MODES.all;
      description.textContent = info.description;
      duration.textContent = `Duration: ~${info.duration} minutes`;
    };
    mode.addEventListener("change", updateMode);
    updateMode();
    const polling = el("select", {}, POLLING_CHOICES.map(([value, text]) => el("option", { value, text })));
    polling.value = String(state.saved?.pollingInterval || 60);
    if (!polling.value) polling.append(el("option", { value: state.saved.pollingInterval, text: `${state.saved.pollingInterval} seconds`, selected: true }));
    const temperature = el("input", { type: "checkbox", checked: device?.enableTemperature !== false });
    const filter = el("input", { type: "checkbox", checked: device?.enableFilterStatus !== false });
    const toggle = (input, title) => el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")), el("span", {}, el("span", { class: "field-title", text: title })));
    const detail = (label, value) => el("div", {}, el("span", { text: label }), el("b", { text: value }));
    const line = statusLine();
    const save = el("button", { class: "primary", text: "Save Configuration" });
    save.addEventListener("click", () => act(save, () => saveRobot({
      name: displayName.value.trim() || data.robotName, cleaningMode: mode.value, pollingInterval: Number(polling.value),
      enableTemperature: temperature.checked, enableFilterStatus: filter.checked,
    }), (message) => fail(line, message, "Saving the Dolphin plugin's block of config.json from its Homeswift page.")));

    show("robot",
      ...head(editing ? "Edit Robot Settings" : "Robot Found!", editing ? "Update the settings for your Dolphin pool robot." : "We found your Dolphin pool robot."),
      el("div", { class: "found" },
        el("div", { class: "card robot-panel" },
          picture(data.serialNumber, el("span", { class: "pill status on", text: editing ? "Configured" : "Connected" })),
          el("div", { class: "body" },
            el("label", { class: "field" }, el("span", { class: "field-title", text: "Display Name" }), displayName, el("span", { class: "help", text: "Name shown in HomeKit" })),
            el("div", { class: "details" },
              detail("Serial Number", data.serialNumber || "-"),
              detail("Model", data.model || data.robotName || "Dolphin Robot"),
              detail("Device Type", deviceTypeLabel(data.deviceType))))),
        el("div", { class: "card settings" },
          el("h3", { text: "Settings" }),
          el("label", { class: "field" }, el("span", { class: "field-title", text: "Default Cleaning Mode" }), mode, el("span", { class: "help", text: "Mode used when starting from HomeKit" })),
          el("div", { class: "mode-info" }, el("strong", { text: "Mode Details" }), description, duration),
          el("label", { class: "field" }, el("span", { class: "field-title", text: "Polling Interval" }), polling, el("span", { class: "help", text: "How often to check robot status" })),
          toggle(temperature, "Enable Water Temperature Sensor"),
          toggle(filter, "Enable Filter Status"))),
      line,
      el("div", { class: "actions" }, el("button", { text: "Back", onclick: () => (editing ? showConfigured() : showLogin({ cancellable: Boolean(state.saved?.devices?.length) })) }), save));
  }

  /// Writes the robot into the block as the Homebridge wizard does: the account (email, region, refresh token)
  /// when it came from a sign-in, the device entry, and the polling interval. The plugin reloads with it.
  async function saveRobot(settings) {
    const data = state.robotData;
    const editing = state.editingIndex !== null;
    const entry = {
      serialNumber: data.serialNumber, name: settings.name, deviceType: data.deviceType, robotImageUrl: data.robotImageUrl,
      cleaningMode: settings.cleaningMode, enableTemperature: settings.enableTemperature, enableFilterStatus: settings.enableFilterStatus,
    };
    if (!entry.robotImageUrl) delete entry.robotImageUrl;
    if (entry.deviceType === undefined) delete entry.deviceType;
    let saved;
    await updateBlock((block) => {
      block.pollingInterval = settings.pollingInterval;
      block.devices = [...(block.devices || [])];
      if (editing) {
        block.devices[state.editingIndex] = entry;
      } else {
        const existing = block.devices.findIndex((d) => d.serialNumber === data.serialNumber);
        if (existing >= 0) block.devices[existing] = entry; else block.devices.push(entry);
        block.email = data.email;
        block.iotRegion = data.iotRegion;
        if (data.refreshToken) block.refreshToken = data.refreshToken;
      }
      saved = block;
    });
    state.saved = saved;
    if (editing) {
      state.editingIndex = null;
      setTimeout(refreshLive, 1500);
      showConfigured();
    } else {
      showDone();
    }
  }

  // Step 3: done.

  function showDone() {
    show("success",
      ...head("Setup Complete!", "Your Dolphin pool robot has been configured."),
      el("div", { class: "card" },
        el("p", { text: "Your robot will now appear in HomeKit. You can:" }),
        el("ul", { class: "done-list" },
          el("li", { text: "Turn cleaning on/off with the switch" }), el("li", { text: "View water temperature" }),
          el("li", { text: "Check filter status" }), el("li", { text: "Use Siri voice commands" }))),
      el("div", { class: "actions" }, el("button", { class: "primary", text: "Done", onclick: () => { setTimeout(refreshLive, 1500); showConfigured(); } })));
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
    if (current === null || (changed && current === "configured")) showConfigured();
  }

  poll(refreshLive, 5000);
})();

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
  /* The Homebridge plugin's setup wizard on the UI's materials: the configured robots, then sign-in with a
     verification code, the robot found with its settings, and done. One step shows at a time. */
  .page-head { align-items: center; }
  .tile.pool { background: linear-gradient(160deg, #5ba0e9, #2e5a8b); }
  .step { animation: materialize var(--normal) var(--ease-out); }
  .step-head { display: flex; align-items: center; gap: 12px; margin-bottom: 4px; }
  .step-head h2 { margin: 0; }
  .step > p.muted:first-of-type { margin-top: 4px; }
  .narrow { max-width: 520px; }

  .robots { display: grid; gap: 14px; }
  .robot { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 3fr); gap: 0; padding: 0; overflow: hidden; cursor: pointer; text-align: left;
    transition: transform 160ms var(--ease-out), box-shadow var(--normal) ease; }
  .robot:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  @media (hover: hover) { .robot:hover { transform: translateY(-2px); } }
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
  @media (prefers-color-scheme: dark) { .picture { background: linear-gradient(180deg, #1e3a4c 0%, #0d2233 100%); } }

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

  .code-input { font-size: 1.5rem; letter-spacing: 0.3em; font-variant-numeric: tabular-nums; text-align: center; max-width: 240px; }
  .done-list { margin: 8px 0 0; padding-left: 20px; }
  .hint { margin-top: 16px; font-size: 0.8125rem; }
  .account-line { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin-bottom: 14px; }

  .busy::after {
    content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
    border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
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
    .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large pool" aria-hidden="true"><svg viewBox="0 0 16 16" style="fill:currentColor;stroke:none"><path fill-rule="evenodd" d="M7.21.8C7.69.295 8 0 8 0q.164.544.371 1.038c.812 1.946 2.073 3.35 3.197 4.6C12.878 7.096 14 8.345 14 10a6 6 0 0 1-12 0C2 6.668 5.58 2.517 7.21.8m.413 1.021A31 31 0 0 0 5.794 3.99c-.726.95-1.436 2.008-1.96 3.07C3.304 8.133 3 9.138 3 10c0 0 2.5 1.5 5 .5s5-.5 5-.5c0-1.201-.796-2.157-2.181-3.7l-.03-.032C9.75 5.11 8.5 3.72 7.623 1.82z"/></svg></span>
    <div>
      <h1>Dolphin Pool Cleaner</h1>
      <p class="muted">Connect your MyDolphin Plus account, then choose how your robot appears in the Home app.</p>
    </div>
  </div>
  <div id="wizard"></div>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
