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
        el("button", { text: t("Add Another Robot"), onclick: () => showLogin({ cancellable: true }) }),
        el("button", { class: "primary", text: t("Reconfigure"), onclick: () => showLogin({ cancellable: true }) })));
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
    const send = el("button", { class: "primary", type: "submit", text: t("Send Verification Code") });
    const form = el("form", { class: "narrow", onsubmit: (event) => { event.preventDefault(); act(send, () => login(email.value.trim(), line), (message) => loginProblem(line, message)); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Email") }), email,
        el("span", { class: "help", text: t("The email associated with your MyDolphin Plus account") })),
      line,
      el("div", { class: "actions" }, cancellable ? el("button", { type: "button", text: t("Cancel"), onclick: showConfigured }) : null, send));
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
    const verify = el("button", { class: "primary", type: "submit", text: t("Verify") });
    const form = el("form", { class: "narrow", onsubmit: (event) => { event.preventDefault(); act(verify, () => verifyCode(code, prompt, line), (text) => codeProblem(line, text)); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Verification Code") }), code,
        el("span", { class: "help", text: t("Check your email or phone for the verification code") })),
      line,
      el("div", { class: "actions" }, el("button", { type: "button", text: t("Back"), onclick: () => showLogin({ cancellable: Boolean(state.saved?.devices?.length) }) }), verify));
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
    const save = el("button", { class: "primary", text: t("Save Configuration") });
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
      el("div", { class: "actions" }, el("button", { text: t("Back"), onclick: () => (editing ? showConfigured() : showLogin({ cancellable: Boolean(state.saved?.devices?.length) })) }), save));
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
      el("div", { class: "actions" }, el("button", { class: "primary", text: t("Done"), onclick: () => { setTimeout(refreshLive, 1500); showConfigured(); } })));
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
