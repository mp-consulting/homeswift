// The Dolphin Pool Cleaner page, after the Homebridge plugin's setup wizard without its sign-in: Setup signs in (a
// card leads to it while the account is not signed in), then the account's robots with their live state. It writes no
// settings (docs/adr/0002-schema-declares-every-setting.md): a robot's card opens its settings on the Settings page.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, explain, poll, fact, setupCard, setupAddress } = homeswift;
  // The pool robot's icon, the one its widget and its Matter row show.
  $(".tile.pool")?.replaceChildren(HomeswiftCommon.icon("poolRobot"));

  const DEVICE_TYPE_LABELS = { 62: t("IoT Connected (M400/M600)"), 60: t("IoT Connected"), 50: t("BLE Connected") };
  const CLEANING_MODES = {
    all: { name: t("All Surfaces"), duration: 150 },
    floor: { name: t("Floor Only"), duration: 150 },
    wall: { name: t("Walls Only"), duration: 120 },
    water: { name: t("Waterline"), duration: 150 },
    short: { name: t("Short/Fast"), duration: 150 },
    ultra: { name: t("Ultra Clean"), duration: 150 },
    cove: { name: t("Cove"), duration: 120 },
    spot: { name: t("Spot"), duration: 120 },
    tictac: { name: t("Tic Tac"), duration: 600 },
    pickup: { name: t("Pickup"), duration: 5 },
    custom: { name: t("Custom"), duration: 120 },
  };

  // MARK: Where settings are edited: the plugin's Settings page, and each robot's there.

  const pluginSettings = `/plugins/${location.pathname.split("/")[2] || ""}/settings`;
  const robotSettings = (serial) => `${pluginSettings}?accessory=${encodeURIComponent(`DolphinPoolCleaner:${serial}`)}`;

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

  // MARK: The robots

  const wizard = $("#wizard");
  const state = {
    live: null,           // what the plugin reports about its robots; null before its first answer
    status: null,
    error: null,
  };
  let current = null;

  function show(step, ...children) {
    // The same step drawn again (the robots' state changed) stays still: only a new step arrives animated.
    const again = step === current;
    current = step;
    wizard.replaceChildren(el("div", { class: `step step-${step}${again ? " again" : ""}` }, ...children));
  }

  const head = (title, text) => [el("div", { class: "step-head" }, el("h2", { text: title })), text ? el("p", { class: "muted", text }) : null];
  function fail(line, message, context) {
    line.className = "status-line error";
    line.replaceChildren(message, explain({ error: message, context, device: { model: "Maytronics Dolphin pool robot (MyDolphin Plus)" } }));
  }

  /// The account's robots as the plugin reports them; the card that had the keyboard keeps it. No account: the card to
  /// Setup.
  function drawRobots() {
    if (state.status === "notConfigured") {
      show("setup", setupCard({
        title: t("Sign in to your MyDolphin Plus account"),
        text: t("Add accessories signs in with your MyDolphin Plus email and the code Maytronics sends; the account's robots come with it."),
        glyph: "key",
        tone: "blue",
      }));
      return;
    }
    const robots = state.live || [];
    const focused = [...wizard.querySelectorAll(".robot")].indexOf(document.activeElement);
    const list = robots.length ? el("div", { class: "robots" }, robots.map(robotCard))
      : el("p", { class: "muted", text: state.status === "ready" ? t("No robot on this account yet.") : "" });
    const account = el("p", { class: "status-line" });
    describeAccount(account);
    show("configured",
      ...head(t("Your Dolphin Robots"), t("The robots of your MyDolphin Plus account. A robot's card opens its settings.")),
      el("div", { class: "account-line" }, account,
        el("a", { class: "button", href: setupAddress({ start: true }), actionIcon: "key", text: t("Sign in again") })),
      list);
    if (focused >= 0) wizard.querySelectorAll(".robot")[focused]?.focus({ preventScroll: true });
  }

  function describeAccount(line) {
    const { status, error } = state;
    if (status === "failed" || status === "retrying") {
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

  function liveState(robot) {
    if (robot.excluded) return { text: t("Excluded"), kind: "standby" };
    if (!robot.connected) return { text: t("Not connected"), kind: "away" };
    if (robot.fault) return { text: robot.fault, kind: "away" };
    return robot.isCleaning ? { text: t("Cleaning"), kind: "on" } : { text: t("Idle"), kind: "standby" };
  }

  function robotCard(robot) {
    const live = liveState(robot);
    const facts = [
      fact(t("Serial Number"), robot.serialNumber || "—"),
      fact(t("Device Type"), deviceTypeLabel(robot.deviceType)),
    ];
    if (!robot.excluded) {
      facts.push(fact(t("Cleaning Mode"), modeText(robot.cleaningMode)));
      facts.push(fact(t("Filter"), robot.filterStatus === "needs_cleaning" ? t("Needs cleaning") : t("OK")));
      if (robot.isCleaning && robot.cycleTimeRemaining > 0) facts.push(fact(t("Time left"), formatDuration(robot.cycleTimeRemaining)));
      if (typeof robot.temperature === "number") facts.push(fact(t("Water"), homeswift.formatTemperature(robot.temperature)));
    }
    const name = robot.name || t("Dolphin Robot");
    return el("a", { class: "card robot", href: robotSettings(robot.serialNumber), "aria-label": t("Settings of {name}", { name }) },
      picture(robot.serialNumber, el("span", { class: `pill status ${live.kind}`, text: live.text })),
      el("div", { class: "body" },
        el("div", { class: "head" }, el("strong", { text: name })),
        robot.excluded ? el("p", { class: "muted", text: t("Not on the bridge, nor in the Home app. Its settings bring it back.") }) : null,
        el("div", { class: "facts" }, facts),
        el("span", { class: "edit", "aria-hidden": "true", text: t("Settings ›") })));
  }

  // MARK: The plugin's view of its robots, refreshed while the list shows.

  /// The first answer (or failure) draws the page.
  async function refreshLive() {
    let changed = state.live === null;
    try {
      const answer = await request("robots");
      changed = JSON.stringify([answer.robots, answer.status, answer.error]) !== JSON.stringify([state.live, state.status, state.error]);
      state.live = answer.robots || [];
      state.status = answer.status;
      state.error = answer.error || null;
    } catch {
      // The plugin is restarting with a new block; the next refresh catches up.
    }
    // A change redraws the list (or the card to Setup) in place: no animation.
    if (changed || current === null) drawRobots();
  }

  poll(refreshLive, 5000);
})();
