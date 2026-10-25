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
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, explain, assistant, breadcrumb, act, poll, fact, readBlock, updateBlock } = homeswift;

  const IOT_REGION = "eu-west-1";
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
  // The modes the wizard offers, in its order.
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
    // The same step drawn again (the robots' state changed) stays still: only a new step arrives animated.
    const again = step === current;
    current = step;
    wizard.replaceChildren(el("div", { class: `step step-${step}${again ? " again" : ""}` }, ...children));
    const focus = wizard.querySelector("[autofocus]");
    if (focus) focus.focus();
    breadcrumb(step === "configured" ? null : { login: t("Sign in"), otp: t("Verification"), robot: state.editingIndex !== null ? t("Edit robot") : t("Robot found"), success: t("Done") }[step], () => showConfigured());
  }

  const head = (title, text) => [el("div", { class: "step-head" }, el("h2", { text: title })), text ? el("p", { class: "muted", text }) : null];
  const statusLine = () => el("p", { class: "status-line", role: "status" });
  function fail(line, message, context) {
    line.className = "status-line error";
    line.replaceChildren(message, explain({ error: message, context, device: { model: "Maytronics Dolphin pool robot (MyDolphin Plus)" } }));
  }

  // Step 0: the configured robots.

  async function showConfigured() {
    try {
      state.saved = await readBlock();
    } catch (e) {
      show("configured", el("p", { class: "error", text: e.message }));
      return;
    }
    drawConfigured();
  }

  /// The robots of the block as last read, with what the plugin reports about them; the card that had the
  /// keyboard keeps it.
  function drawConfigured() {
    const block = state.saved;
    const devices = block.devices || [];
    const focused = [...wizard.querySelectorAll(".robot")].indexOf(document.activeElement);
    if (!devices.length) {
      showLogin();
      return;
    }
    state.editingIndex = null;
    const list = el("div", { class: "robots" }, devices.map((device, index) => robotCard(device, block.email, index)));
    const account = el("p", { class: "status-line" });
    describeAccount(account);
    show("configured",
      ...head(t("Your Dolphin Robots"), t("Manage your configured pool robots. A robot's card opens its settings.")),
      account, list,
      el("div", { class: "actions" },
        el("button", { actionIcon: "plus", text: t("Add Another Robot"), onclick: () => showLogin({ cancellable: true }) }),
        el("button", { actionIcon: "sliders", class: "primary", text: t("Reconfigure"), onclick: () => showLogin({ cancellable: true }) })));
    if (focused >= 0) wizard.querySelectorAll(".robot")[focused]?.focus({ preventScroll: true });
  }

  function describeAccount(line) {
    const { status, error } = state;
    if (status === "notConfigured") {
      line.className = "status-line error";
      line.textContent = t("No account yet: Reconfigure signs in and stores a refresh token.");
    } else if (status === "failed" || status === "retrying") {
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

  function robotCard(device, email, index) {
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
    card.addEventListener("click", () => editDevice(index));
    card.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); editDevice(index); }
    });
    return card;
  }

  // Step 1: the email; Cognito sends a code.

  function showLogin({ cancellable = false } = {}) {
    const email = el("input", { type: "email", name: "email", placeholder: t("your@email.com"), required: true, autocomplete: "email", autofocus: true, value: state.saved?.email || "" });
    const line = statusLine();
    const send = el("button", { actionIcon: "send", class: "primary", type: "submit", text: t("Send Verification Code") });
    const form = el("form", { class: "narrow", onsubmit: (event) => { event.preventDefault(); act(send, () => login(email.value.trim(), line), (message) => loginProblem(line, message)); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Email") }), email,
        el("span", { class: "help", text: t("The email associated with your MyDolphin Plus account") })),
      line,
      el("div", { class: "actions" }, cancellable ? el("button", { actionIcon: "close", type: "button", text: t("Cancel"), onclick: showConfigured }) : null, send));
    // Without an Assistant, a tip on how to get one, as the Homebridge plugin's wizard shows.
    // One sentence to translate, the block's name in bold where the language puts it.
    const [tipBefore, tipAfter = ""] = t("Tip: add a {block} block to config.json to get the Assistant, which explains sign-in errors here.").split("{block}");
    const hint = el("p", { class: "hint muted hidden" }, tipBefore, el("strong", { text: "HomeswiftAiKit" }), tipAfter);
    assistant().then((status) => hint.classList.toggle("hidden", Boolean(status.enabled)));
    show("login", ...head(t("Connect Your MyDolphin Account"), t("Enter your MyDolphin Plus email address. A verification code will be sent to you.")), form, hint);
  }

  function loginProblem(line, message) {
    fail(line, message, "Step 1 of the Dolphin setup page: requesting a verification code for the MyDolphin Plus account (AWS Cognito CUSTOM_AUTH, InitiateAuth) failed.");
  }

  async function login(email, line) {
    if (!email) throw new Error(t("Please enter your email address"));
    state.pendingEmail = email;
    line.className = "status-line muted";
    line.textContent = "";
    const result = await request("authenticate", { method: "POST", body: { email } });
    if (result.success) authenticated(result, email);
    else if (result.requiresOtp) showCode(HomeswiftI18n.message(result.message));
    else loginProblem(line, HomeswiftI18n.message(result.error) || t("Authentication failed"));
  }

  // Step 1b: the code.

  function showCode(message) {
    const code = el("input", { class: "code-input", type: "text", name: "otpCode", placeholder: t("Enter code"), required: true, autocomplete: "one-time-code", inputMode: "numeric", pattern: "[0-9]*", maxLength: 6, autofocus: true });
    const line = statusLine();
    const prompt = el("p", { class: "muted", text: message || t("Please enter the verification code sent to your email.") });
    const verify = el("button", { actionIcon: "check", class: "primary", type: "submit", text: t("Verify") });
    const form = el("form", { class: "narrow", onsubmit: (event) => { event.preventDefault(); act(verify, () => verifyCode(code, prompt, line), (text) => codeProblem(line, text)); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Verification Code") }), code,
        el("span", { class: "help", text: t("Check your email or phone for the verification code") })),
      line,
      el("div", { class: "actions" }, el("button", { actionIcon: "restore", type: "button", text: t("Back"), onclick: () => showLogin({ cancellable: Boolean(state.saved?.devices?.length) }) }), verify));
    show("otp", el("div", { class: "step-head" }, el("h2", { text: t("Verification Required") })), prompt, form);
  }

  function codeProblem(line, message) {
    fail(line, message, "Step 2 of the Dolphin setup page: verifying the code (AWS Cognito RespondToAuthChallenge, then the MyDolphin authenticate-user call that returns the robot) failed. The code session lasts 5 minutes.");
  }

  async function verifyCode(input, prompt, line) {
    const otpCode = input.value.trim();
    if (!otpCode) throw new Error(t("Please enter the verification code"));
    if (!state.pendingEmail) { showLogin(); return; }
    line.className = "status-line muted";
    line.textContent = "";
    const result = await request("verify-otp", { method: "POST", body: { email: state.pendingEmail, otpCode } });
    if (result.success) authenticated(result, state.pendingEmail);
    else if (result.requiresOtp) {
      prompt.textContent = HomeswiftI18n.message(result.message) || t("Please enter the new verification code.");
      input.value = "";
      input.focus();
    } else codeProblem(line, HomeswiftI18n.message(result.error) || t("Verification failed"));
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
      ...head(editing ? t("Edit Robot Settings") : t("Robot Found!"), editing ? t("Update the settings for your Dolphin pool robot.") : t("We found your Dolphin pool robot.")),
      el("div", { class: "found" },
        el("div", { class: "card robot-panel" },
          picture(data.serialNumber, el("span", { class: "pill status on", text: editing ? t("Configured") : t("Connected") })),
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
      el("div", { class: "actions" }, el("button", { actionIcon: "restore", text: t("Back"), onclick: () => (editing ? showConfigured() : showLogin({ cancellable: Boolean(state.saved?.devices?.length) })) }), save));
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
      ...head(t("Setup Complete!"), t("Your Dolphin pool robot has been configured.")),
      el("div", { class: "card" },
        el("p", { text: t("Your robot will now appear in HomeKit. You can:") }),
        el("ul", { class: "done-list" },
          el("li", { text: t("Turn cleaning on/off with the switch") }), el("li", { text: t("View water temperature") }),
          el("li", { text: t("Check filter status") }), el("li", { text: t("Use Siri voice commands") }))),
      el("div", { class: "actions" }, el("button", { actionIcon: "check", class: "primary", text: t("Done"), onclick: () => { setTimeout(refreshLive, 1500); showConfigured(); } })));
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
    // A change while the list shows redraws it from the block already read: no request, no animation.
    if (current === null || (current === "configured" && !state.saved)) showConfigured();
    else if (changed && current === "configured") drawConfigured();
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
    "Sign in": "Connexion",
    "Verification": "Vérification",
    "Edit robot": "Modifier le robot",
    "Robot found": "Robot trouvé",
    "Done": "Terminé",
    "Your Dolphin Robots": "Vos robots Dolphin",
    "Manage your configured pool robots. A robot's card opens its settings.": "Gérez vos robots de piscine configurés. La carte d'un robot ouvre ses réglages.",
    "Add Another Robot": "Ajouter un autre robot",
    "Reconfigure": "Reconfigurer",
    "No account yet: Reconfigure signs in and stores a refresh token.": "Pas encore de compte : Reconfigurer vous connecte et enregistre un jeton d'actualisation.",
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
    "your@email.com": "vous@exemple.com",
    "Send Verification Code": "Envoyer le code de vérification",
    "Email": "E-mail",
    "The email associated with your MyDolphin Plus account": "L'e-mail associé à votre compte MyDolphin Plus",
    "Cancel": "Annuler",
    "Tip: add a {block} block to config.json to get the Assistant, which explains sign-in errors here.": "Astuce : ajoutez un bloc {block} à config.json pour activer l'Assistant, qui explique ici les erreurs de connexion.",
    "Connect Your MyDolphin Account": "Connectez votre compte MyDolphin",
    "Enter your MyDolphin Plus email address. A verification code will be sent to you.": "Saisissez l'adresse e-mail de votre compte MyDolphin Plus. Un code de vérification vous sera envoyé.",
    "Please enter your email address": "Saisissez votre adresse e-mail",
    "Authentication failed": "Échec de l'authentification",
    "Enter code": "Saisir le code",
    "Please enter the verification code sent to your email.": "Saisissez le code de vérification envoyé à votre adresse e-mail.",
    "Verify": "Vérifier",
    "Verification Code": "Code de vérification",
    "Check your email or phone for the verification code": "Consultez vos e-mails ou votre téléphone pour obtenir le code de vérification",
    "Back": "Retour",
    "Verification Required": "Vérification requise",
    "Please enter the verification code": "Saisissez le code de vérification",
    "Please enter the new verification code.": "Saisissez le nouveau code de vérification.",
    "Verification failed": "Échec de la vérification",
    "My Pool Robot": "Mon robot de piscine",
    "Duration: ~{n} minute": "Durée : environ {n} minute",
    "Duration: ~{n} minutes": "Durée : environ {n} minutes",
    "{n} second": "{n} seconde",
    "{n} seconds": "{n} secondes",
    "Save Configuration": "Enregistrer la configuration",
    "Edit Robot Settings": "Modifier les réglages du robot",
    "Robot Found!": "Robot trouvé !",
    "Update the settings for your Dolphin pool robot.": "Modifiez les réglages de votre robot de piscine Dolphin.",
    "We found your Dolphin pool robot.": "Nous avons trouvé votre robot de piscine Dolphin.",
    "Connected": "Connecté",
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
    "Setup Complete!": "Configuration terminée !",
    "Your Dolphin pool robot has been configured.": "Votre robot de piscine Dolphin est configuré.",
    "Your robot will now appear in HomeKit. You can:": "Votre robot apparaît maintenant dans HomeKit. Vous pouvez :",
    "Turn cleaning on/off with the switch": "Lancer ou arrêter le nettoyage avec l'interrupteur",
    "View water temperature": "Voir la température de l'eau",
    "Check filter status": "Vérifier l'état du filtre",
    "Use Siri voice commands": "Utiliser les commandes vocales de Siri",
    "Please enter the verification code sent to your phone": "Saisissez le code de vérification envoyé sur votre téléphone",
    "Please enter the code from your authenticator app": "Saisissez le code de votre app d'authentification",
    "Please enter the verification code sent to your email": "Saisissez le code de vérification envoyé à votre adresse e-mail",
    "MFA setup required. Please complete setup in the MyDolphin app first.": "Configuration de l'authentification à deux facteurs requise. Terminez-la d'abord dans l'app MyDolphin.",
    "Invalid email or password": "E-mail ou mot de passe incorrect",
    "User not found. Please check your email address.": "Utilisateur introuvable. Vérifiez votre adresse e-mail.",
    "Please confirm your email address first": "Confirmez d'abord votre adresse e-mail",
    "Invalid verification code": "Code de vérification incorrect",
    "Verification code has expired. Please try again.": "Le code de vérification a expiré. Réessayez.",
    "Email is required": "L'e-mail est requis",
    "Unexpected authentication response": "Réponse d'authentification inattendue",
    "Email and OTP code are required": "L'e-mail et le code à usage unique sont requis",
    "No pending authentication. Please try again.": "Aucune authentification en cours. Réessayez.",
    "Session expired. Please try again.": "La session a expiré. Réessayez.",
    "No authentication token received": "Aucun jeton d'authentification reçu",
    "MyDolphin authentication failed": "Échec de l'authentification MyDolphin",
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
    "Sign in": "Iniciar sesión",
    "Verification": "Verificación",
    "Edit robot": "Editar robot",
    "Robot found": "Robot encontrado",
    "Done": "Listo",
    "Your Dolphin Robots": "Tus robots Dolphin",
    "Manage your configured pool robots. A robot's card opens its settings.": "Gestiona tus robots de piscina configurados. La tarjeta de un robot abre sus ajustes.",
    "Add Another Robot": "Añadir otro robot",
    "Reconfigure": "Reconfigurar",
    "No account yet: Reconfigure signs in and stores a refresh token.": "Aún no hay cuenta: Reconfigurar inicia sesión y guarda un token de actualización.",
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
    "your@email.com": "tu@email.com",
    "Send Verification Code": "Enviar el código de verificación",
    "Email": "Correo",
    "The email associated with your MyDolphin Plus account": "El correo asociado a tu cuenta de MyDolphin Plus",
    "Cancel": "Cancelar",
    "Tip: add a {block} block to config.json to get the Assistant, which explains sign-in errors here.": "Consejo: añade un bloque {block} a config.json para tener el Asistente, que aquí explica los errores de inicio de sesión.",
    "Connect Your MyDolphin Account": "Conecta tu cuenta de MyDolphin",
    "Enter your MyDolphin Plus email address. A verification code will be sent to you.": "Introduce el correo de tu cuenta de MyDolphin Plus. Te enviaremos un código de verificación.",
    "Please enter your email address": "Introduce tu dirección de correo",
    "Authentication failed": "No se ha podido autenticar",
    "Enter code": "Introduce el código",
    "Please enter the verification code sent to your email.": "Introduce el código de verificación enviado a tu correo.",
    "Verify": "Verificar",
    "Verification Code": "Código de verificación",
    "Check your email or phone for the verification code": "Busca el código de verificación en tu correo o en tu móvil",
    "Back": "Atrás",
    "Verification Required": "Verificación necesaria",
    "Please enter the verification code": "Introduce el código de verificación",
    "Please enter the new verification code.": "Introduce el nuevo código de verificación.",
    "Verification failed": "No se ha podido verificar",
    "My Pool Robot": "Mi robot de piscina",
    "Duration: ~{n} minute": "Duración: ~{n} minuto",
    "Duration: ~{n} minutes": "Duración: ~{n} minutos",
    "{n} second": "{n} segundo",
    "{n} seconds": "{n} segundos",
    "Save Configuration": "Guardar la configuración",
    "Edit Robot Settings": "Editar los ajustes del robot",
    "Robot Found!": "¡Robot encontrado!",
    "Update the settings for your Dolphin pool robot.": "Cambia los ajustes de tu robot de piscina Dolphin.",
    "We found your Dolphin pool robot.": "Hemos encontrado tu robot de piscina Dolphin.",
    "Connected": "Conectado",
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
    "Setup Complete!": "¡Configuración completada!",
    "Your Dolphin pool robot has been configured.": "Tu robot de piscina Dolphin está configurado.",
    "Your robot will now appear in HomeKit. You can:": "Tu robot aparecerá ahora en HomeKit. Puedes:",
    "Turn cleaning on/off with the switch": "Iniciar o detener la limpieza con el interruptor",
    "View water temperature": "Ver la temperatura del agua",
    "Check filter status": "Comprobar el estado del filtro",
    "Use Siri voice commands": "Usar comandos de voz de Siri",
    "Please enter the verification code sent to your phone": "Introduce el código de verificación enviado a tu móvil",
    "Please enter the code from your authenticator app": "Introduce el código de tu app de autenticación",
    "Please enter the verification code sent to your email": "Introduce el código de verificación enviado a tu correo",
    "MFA setup required. Please complete setup in the MyDolphin app first.": "Hay que configurar la autenticación de dos factores. Complétala primero en la app MyDolphin.",
    "Invalid email or password": "Correo o contraseña incorrectos",
    "User not found. Please check your email address.": "No se ha encontrado el usuario. Comprueba tu dirección de correo.",
    "Please confirm your email address first": "Confirma primero tu dirección de correo",
    "Invalid verification code": "Código de verificación incorrecto",
    "Verification code has expired. Please try again.": "El código de verificación ha caducado. Vuelve a intentarlo.",
    "Email is required": "Se necesita el correo",
    "Unexpected authentication response": "Respuesta de autenticación inesperada",
    "Email and OTP code are required": "Se necesitan el correo y el código de un solo uso",
    "No pending authentication. Please try again.": "No hay ninguna autenticación pendiente. Vuelve a intentarlo.",
    "Session expired. Please try again.": "La sesión ha caducado. Vuelve a intentarlo.",
    "No authentication token received": "No se ha recibido ningún token de autenticación",
    "MyDolphin authentication failed": "No se ha podido autenticar en MyDolphin",
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
    "Sign in": "Iniciar sessão",
    "Verification": "Verificação",
    "Edit robot": "Editar robô",
    "Robot found": "Robô encontrado",
    "Done": "Concluído",
    "Your Dolphin Robots": "Os seus robôs Dolphin",
    "Manage your configured pool robots. A robot's card opens its settings.": "Gira os robôs de piscina configurados. O cartão de um robô abre as suas definições.",
    "Add Another Robot": "Adicionar outro robô",
    "Reconfigure": "Reconfigurar",
    "No account yet: Reconfigure signs in and stores a refresh token.": "Ainda não há conta: Reconfigurar inicia sessão e guarda um token de atualização.",
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
    "your@email.com": "nome@email.com",
    "Send Verification Code": "Enviar o código de verificação",
    "Email": "E-mail",
    "The email associated with your MyDolphin Plus account": "O e-mail associado à sua conta MyDolphin Plus",
    "Cancel": "Cancelar",
    "Tip: add a {block} block to config.json to get the Assistant, which explains sign-in errors here.": "Sugestão: adicione um bloco {block} ao config.json para ter o Assistente, que aqui explica os erros de início de sessão.",
    "Connect Your MyDolphin Account": "Ligue a sua conta MyDolphin",
    "Enter your MyDolphin Plus email address. A verification code will be sent to you.": "Introduza o endereço de e-mail da conta MyDolphin Plus. Será enviado um código de verificação.",
    "Please enter your email address": "Introduza o endereço de e-mail",
    "Authentication failed": "Falha na autenticação",
    "Enter code": "Introduza o código",
    "Please enter the verification code sent to your email.": "Introduza o código de verificação enviado para o seu e-mail.",
    "Verify": "Verificar",
    "Verification Code": "Código de verificação",
    "Check your email or phone for the verification code": "Procure o código de verificação no e-mail ou no telemóvel",
    "Back": "Voltar",
    "Verification Required": "Verificação necessária",
    "Please enter the verification code": "Introduza o código de verificação",
    "Please enter the new verification code.": "Introduza o novo código de verificação.",
    "Verification failed": "Falha na verificação",
    "My Pool Robot": "O meu robô de piscina",
    "Duration: ~{n} minute": "Duração: ~{n} minuto",
    "Duration: ~{n} minutes": "Duração: ~{n} minutos",
    "{n} second": "{n} segundo",
    "{n} seconds": "{n} segundos",
    "Save Configuration": "Guardar a configuração",
    "Edit Robot Settings": "Editar as definições do robô",
    "Robot Found!": "Robô encontrado!",
    "Update the settings for your Dolphin pool robot.": "Altere as definições do robô de piscina Dolphin.",
    "We found your Dolphin pool robot.": "Encontrámos o seu robô de piscina Dolphin.",
    "Connected": "Ligado",
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
    "Setup Complete!": "Configuração concluída!",
    "Your Dolphin pool robot has been configured.": "O robô de piscina Dolphin foi configurado.",
    "Your robot will now appear in HomeKit. You can:": "O robô passa a aparecer no HomeKit. Pode:",
    "Turn cleaning on/off with the switch": "Iniciar ou parar a limpeza com o interruptor",
    "View water temperature": "Ver a temperatura da água",
    "Check filter status": "Verificar o estado do filtro",
    "Use Siri voice commands": "Usar comandos de voz da Siri",
    "Please enter the verification code sent to your phone": "Introduza o código de verificação enviado para o telemóvel",
    "Please enter the code from your authenticator app": "Introduza o código da app de autenticação",
    "Please enter the verification code sent to your email": "Introduza o código de verificação enviado para o seu e-mail",
    "MFA setup required. Please complete setup in the MyDolphin app first.": "É necessário configurar a autenticação de dois fatores. Conclua-a primeiro na app MyDolphin.",
    "Invalid email or password": "E-mail ou palavra-passe incorretos",
    "User not found. Please check your email address.": "Utilizador não encontrado. Verifique o endereço de e-mail.",
    "Please confirm your email address first": "Confirme primeiro o endereço de e-mail",
    "Invalid verification code": "Código de verificação incorreto",
    "Verification code has expired. Please try again.": "O código de verificação expirou. Tente novamente.",
    "Email is required": "O e-mail é obrigatório",
    "Unexpected authentication response": "Resposta de autenticação inesperada",
    "Email and OTP code are required": "O e-mail e o código de utilização única são obrigatórios",
    "No pending authentication. Please try again.": "Não há nenhuma autenticação pendente. Tente novamente.",
    "Session expired. Please try again.": "A sessão expirou. Tente novamente.",
    "No authentication token received": "Não foi recebido nenhum token de autenticação",
    "MyDolphin authentication failed": "Falha na autenticação MyDolphin",
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
  /* The Homebridge plugin's setup wizard on the UI's materials: the configured robots, then sign-in with a
     verification code, the robot found with its settings, and done. One step shows at a time. */
  .page-head { align-items: center; }
  .tile.pool { background: linear-gradient(160deg, #5ba0e9, #2e5a8b); }
  .step { animation: materialize var(--normal) var(--ease-out); }
  .step.again { animation: none; }
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

  .code-input { font-size: 1.5rem; letter-spacing: 0.3em; font-variant-numeric: tabular-nums; text-align: center; max-width: 240px; }
  .done-list { margin: 8px 0 0; padding-left: 20px; }
  .hint { margin-top: 16px; font-size: 0.8125rem; }
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
    <span class="tile large pool" aria-hidden="true"><svg viewBox="0 0 16 16" style="fill:currentColor;stroke:none"><path fill-rule="evenodd" d="M7.21.8C7.69.295 8 0 8 0q.164.544.371 1.038c.812 1.946 2.073 3.35 3.197 4.6C12.878 7.096 14 8.345 14 10a6 6 0 0 1-12 0C2 6.668 5.58 2.517 7.21.8m.413 1.021A31 31 0 0 0 5.794 3.99c-.726.95-1.436 2.008-1.96 3.07C3.304 8.133 3 9.138 3 10c0 0 2.5 1.5 5 .5s5-.5 5-.5c0-1.201-.796-2.157-2.181-3.7l-.03-.032C9.75 5.11 8.5 3.72 7.623 1.82z"/></svg></span>
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
