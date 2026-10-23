// Homeswift web UI: one page, plain JavaScript, no dependencies. Talks to /api/* with the session cookie.
(() => {
  "use strict";

  const { $, el, tile, sparkle, menuButton, copyText, jsonEditor, fact, setPaused, slug, withSlugs } = HomeswiftCommon;

  const show = (main, ...nodes) => main.replaceChildren(...nodes.flat().filter(Boolean));

  class ApiError extends Error { constructor(status, message) { super(message); this.status = status; } }

  async function api(path, { method = "GET", body, raw = false } = {}) {
    const options = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = typeof body === "string" ? body : JSON.stringify(body); }
    const response = await fetch(path, options);
    if (response.status === 401 && !path.startsWith("/api/auth/")) { showAuth(); throw new ApiError(401, "signed out"); }
    const text = await response.text();
    if (!response.ok) {
      let message = text;
      try { message = JSON.parse(text).error || text; } catch {}
      throw new ApiError(response.status, message || `HTTP ${response.status}`);
    }
    return raw ? text : (text ? JSON.parse(text) : null);
  }

  // ---- Authentication ------------------------------------------------------

  let auth = null;

  async function loadAuth() {
    auth = await api("/api/auth/state");
    if (auth.authenticated) showApp(); else showAuth();
  }

  function showAuth() {
    $("#app").classList.add("hidden");
    $("#auth").classList.remove("hidden");
    closeEvents();
    const setup = auth && auth.setupNeeded;
    $("#auth-text").textContent = setup
      ? "Create the administrator account for this bridge. The set-up code is in the bridge's output, next to the web UI address."
      : "Sign in to manage the bridge.";
    $("#auth-submit").textContent = setup ? "Create account" : "Sign in";
    $("input[name=password]", $("#auth-form")).autocomplete = setup ? "new-password" : "current-password";
    $("#auth-setup-code").classList.toggle("hidden", !setup);
    $("input[name=setupCode]", $("#auth-form")).required = !!setup;
    const form = $("#auth-form");
    if (setup && !setupGauge) {
      setupGauge = strengthGauge(form.password, () => form.username.value);
      form.password.closest("label").after(setupGauge);
      form.username.addEventListener("input", () => setupGauge.refresh());
    }
    setupGauge?.classList.toggle("hidden", !setup);
  }
  let setupGauge = null;

  $("#auth-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.target;
    const error = $("#auth-error");
    error.textContent = "";
    // Feedback on the press: the button says what happens while the bridge checks the password.
    const submit = $("#auth-submit");
    const label = submit.textContent;
    submit.disabled = true;
    submit.classList.add("busy");
    submit.textContent = auth && auth.setupNeeded ? "Creating the account…" : "Signing in…";
    try {
      const body = { username: form.username.value, password: form.password.value };
      if (auth && auth.setupNeeded) {
        if (setupGauge && !(await setupGauge.acceptable())) throw new Error("The password is not strong enough yet: the gauge says what is missing.");
        body.setupCode = form.setupCode.value;
      }
      await api(auth && auth.setupNeeded ? "/api/auth/setup" : "/api/auth/login", { method: "POST", body });
      form.password.value = "";
      await loadAuth();
    } catch (e) {
      error.textContent = e.message;
    } finally {
      submit.disabled = false;
      submit.classList.remove("busy");
      submit.textContent = label;
    }
  });

  $("#logout").addEventListener("click", async () => { try { await api("/api/auth/logout", { method: "POST" }); } catch {} await loadAuth(); });

  /// What a save did: applied at once, homeswift restarting by itself (the bridge block), or, when it
  /// cannot, what still waits for a restart (which also shows the banner).
  function savedText(result) {
    if (result.restarting) { waitForRestart(); return "Saved. Homeswift restarts by itself to apply the bridge settings…"; }
    const pending = result.restartNeeded || [];
    $("#banner").classList.toggle("hidden", pending.length === 0);
    return pending.length ? `Saved. Restart homeswift to apply the rest: ${pending.join("; ")}.` : "Saved and applied.";
  }

  // ---- Restart -------------------------------------------------------------

  async function restartBridge(event) {
    if (!confirm("Restart homeswift now? Every connection drops for a few seconds.")) return;
    const button = event.target;
    button.disabled = true;
    try {
      await api("/api/restart", { method: "POST" });
    } catch (e) {
      alert(e.message);
      button.disabled = false;
      return;
    }
    waitForRestart();
  }

  /// Shows the restart in the banner and reloads the page once a younger process answers.
  function waitForRestart() {
    closeEvents();
    const banner = $("#banner");
    banner.classList.remove("hidden");
    banner.replaceChildren("Restarting homeswift…");
    const started = Date.now();
    // Back when a status answers from a process younger than this restart; the login survives it.
    const poll = async () => {
      try {
        const response = await fetch("/api/status", { credentials: "same-origin" });
        if (response.ok) {
          const status = await response.json();
          if (status.uptimeSeconds < (Date.now() - started) / 1000 + 5) { location.reload(); return; }
        } else if (response.status === 401) { location.reload(); return; }
      } catch {}
      if (Date.now() - started < 90000) setTimeout(poll, 1000);
      else banner.replaceChildren("homeswift did not come back; check its log.");
    };
    setTimeout(poll, 1500);
  }
  $("#restart").addEventListener("click", restartBridge);

  function showApp() {
    $("#auth").classList.add("hidden");
    $("#app").classList.remove("hidden");
    $("#user").textContent = auth.username || "";
    HomeswiftCommon.tabBar({ parent: $("#app") });
    HomeswiftChat.mount();
    $("#logout").classList.toggle("hidden", auth.mode !== "form");
    openEvents();
    route();
  }

  // ---- Routing -------------------------------------------------------------

  // A path is a view and its arguments: /status (or /), /accessories, /plugins, /plugins/<slug>/expert[/json]
  // (a block's settings; /plugins/<slug> itself is the plugin's own page when it has one), /plugins/add/<platform>,
  // /config, /logs[/<accessory>]?since=…&level=…&q=…, /account. Pages below a section keep it lit in the header.
  const views = {};
  let leaveGuard = null;   // a page with unsaved changes: false keeps it
  let shownPath = null;
  function route() {
    const decode = (part) => { try { return decodeURIComponent(part); } catch { return part; } };
    const [name = "status", ...args] = location.pathname.split("/").filter(Boolean).map(decode);
    for (const link of document.querySelectorAll("nav a")) {
      const current = link.getAttribute("href") === `/${name}`;
      link.classList.toggle("active", current);
      if (current) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
    }
    const view = name === "plugins" && args.length ? views.settings : views[name] || views.status;
    const main = $("#view");
    leaveGuard = null;
    shownPath = location.pathname + location.search;
    main.replaceChildren(el("p", { class: "muted", text: "Loading…" }));
    view(main, args).catch((e) => { if (e.status !== 401) main.replaceChildren(el("p", { class: "error", text: e.message })); });
  }
  /// Shows the view at `path` without loading the page again; `replace` keeps it out of the history.
  function navigate(path, { replace = false } = {}) {
    if (leaveGuard && !leaveGuard()) return;
    history[replace ? "replaceState" : "pushState"](null, "", path);
    route();
  }
  window.addEventListener("popstate", () => {
    if (!(auth && auth.authenticated)) return;
    if (leaveGuard && !leaveGuard()) { history.pushState(null, "", shownPath); return; }
    route();
  });
  // A link within the UI changes the view in place. A plugin's own page (/plugins/<slug>) is a page of its own,
  // and a click with a modifier opens where the browser puts it.
  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest("a[href]");
    if (!link || link.target || link.hasAttribute("download") || !(auth && auth.authenticated)) return;
    const url = new URL(link.href, location.href);
    if (url.origin !== location.origin || url.pathname.startsWith("/api/") || /\.[a-z0-9]+$/i.test(url.pathname) || /^\/plugins\/[^/]+\/?$/.test(url.pathname)) return;
    event.preventDefault();
    if (url.pathname + url.search !== location.pathname + location.search) navigate(url.pathname + url.search);
  });
  // Closing the tab or reloading: the browser asks, when the page has unsaved changes.
  window.addEventListener("beforeunload", (event) => { if (leaveGuard?.quiet && !leaveGuard.quiet()) event.preventDefault(); });

  // ---- Live events ---------------------------------------------------------

  let events = null;
  function openEvents() {
    if (events) return;
    events = new EventSource("/api/events");
    events.addEventListener("accessory", (event) => applyAccessoryEvent(JSON.parse(event.data)));
    events.addEventListener("log", (event) => appendLogLine(JSON.parse(event.data)));
    events.addEventListener("asset", (event) => applyAsset(JSON.parse(event.data)));
  }
  /// Live web files (HOMESWIFT_WEB_ROOT): a stylesheet swaps in place, keeping what is open on the page; a
  /// script or a page of the UI reloads. Plugins' files are their pages' business.
  function applyAsset({ file, kind }) {
    if (file.startsWith("Plugins/")) return;
    const name = file.split("/").pop();
    if (kind === "css") {
      for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
        const url = new URL(link.href);
        if (url.pathname.endsWith(`/${name}`)) { url.searchParams.set("v", Date.now()); link.href = url.href; }
      }
      return;
    }
    location.reload();
  }
  function closeEvents() { if (events) { events.close(); events = null; } }

  // ---- Status --------------------------------------------------------------

  /// A page's title, one line on what it is for, and its tools (search, filters) on the right.
  const pageHead = (title, subtitle, ...tools) => el("div", { class: "page-head" },
    el("div", { class: "who" }, el("h1", { text: title }), subtitle ? el("p", { class: "muted", text: subtitle }) : null),
    tools.filter(Boolean).length ? el("div", { class: "tools" }, ...tools) : null);

  views.status = async (main) => {
    const status = await api("/api/status");
    $("#banner").classList.toggle("hidden", !status.restartNeeded);
    const waiting = status.bridges.filter((bridge) => !bridge.paired);
    const [health, healthKind] = status.restartNeeded ? ["Running; some changes need a restart", "away"]
      : waiting.length ? [`Running; ${waiting.length === 1 ? "one server waits" : `${waiting.length} servers wait`} to be added in the Home app`, "away"]
      : ["Running, and everything is in the Home app", "on"];
    const plugins = new Set(status.bridges.filter((bridge) => !bridge.external).flatMap((bridge) => bridge.platforms));
    const main0 = status.bridges.find((bridge) => !bridge.childBridge && !bridge.external);

    const bridges = status.bridges.map((bridge, index) => {
      const kind = bridge.external ? "accessory" : bridge.childBridge ? "child" : "bridge";
      const tone = { accessory: "blue", child: "violet", bridge: "orange" }[kind];
      const role = bridge.external ? `Accessory of its own, from ${bridge.platforms.join(", ") || "a plugin"}` : bridge.childBridge ? "Child bridge" : "Main bridge";
      return el("div", { class: "card server" },
        el("div", { class: "server-head" },
          tile(kind, tone),
          el("div", { class: "who" }, el("strong", { text: bridge.name }), el("div", { class: "muted", text: role })),
          el("span", { class: `pill status ${bridge.paired ? "on" : "away"}`, text: bridge.paired ? `Paired · ${bridge.controllers}` : "Not paired", title: bridge.paired ? `${bridge.controllers} Home app controller(s)` : "" })),
        el("div", { class: "facts lead" },
          fact("Device ID", bridge.deviceId, { class: "mono" }), fact("Port", bridge.port ?? "?"), fact("Accessories", bridge.accessories)),
        !bridge.external && bridge.platforms.length ? el("div", { class: "chips" }, bridge.platforms.map((name) => el("span", { class: "chip", text: name }))) : null,
        bridge.setupCode ? el("div", { class: "setup" },
          el("img", { class: "qr", src: `/api/qr/${index}.svg`, alt: "Pairing QR code", width: 148, height: 148 }),
          el("div", {},
            el("p", { text: "In the Home app: Add Accessory, then scan this code, or choose More options and type it." }),
            el("div", { class: "code", text: bridge.setupCode }))) : null);
    });

    show(main,
      el("div", { class: "card hero" },
        el("img", { src: "/icon.svg", class: "logo large", alt: "" }),
        el("div", { class: "who" },
          el("h1", { text: "Homeswift" }),
          el("p", { class: `health ${healthKind}`, text: health }),
          el("p", { class: "muted", text: `Version ${status.version} · ${status.system.hostname}` }))),
      el("div", { class: "stats" },
        el("div", { class: "stat" }, el("b", { text: status.bridges.reduce((sum, bridge) => sum + bridge.accessories, 0) }), el("span", { text: "Accessories" })),
        el("div", { class: "stat" }, el("b", { text: plugins.size }), el("span", { text: plugins.size === 1 ? "Plugin" : "Plugins" })),
        el("div", { class: "stat" }, el("b", { text: main0 ? main0.controllers : 0 }), el("span", { text: "Home app controllers" })),
        el("div", { class: "stat" }, el("b", { text: formatDuration(status.uptimeSeconds) }), el("span", { text: "Up" }))),
      el("h2", { text: status.bridges.length === 1 ? "Bridge" : "Bridges and accessories" }),
      el("div", { class: "servers" }, ...bridges),
      el("h2", { text: "System" }),
      el("div", { class: "card server" },
        el("div", { class: "server-head" }, tile("system", "grey"),
          el("div", { class: "who" }, el("strong", { text: status.system.hostname }), el("div", { class: "muted", text: `${status.system.platform} ${status.system.os}` }))),
        el("div", { class: "facts" },
          fact("CPUs", status.system.cpus),
          fact("Assistant", status.assistant ? `${status.assistant.provider} · ${status.assistant.model}` : "Off"),
          fact("Machine up", formatDuration(status.system.systemUptimeSeconds ?? 0))),
        el("div", { class: "fact wide" }, el("span", { text: "Configuration" }), el("b", { class: "mono", text: status.configPath, title: status.configPath })),
        // Changes apply without one; this is for a plugin that misbehaves.
        el("div", { class: "actions" }, el("button", { class: "link", text: "Restart homeswift…", onclick: restartBridge }))));
  };

  function formatDuration(seconds) {
    const d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60);
    return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
  }

  // ---- Accessories ---------------------------------------------------------

  const enumLabels = {
    "Lock Target State": ["Unsecured", "Secured"], "Lock Current State": ["Unsecured", "Secured", "Jammed", "Unknown"],
    "Target Door State": ["Open", "Closed"], "Current Door State": ["Open", "Closed", "Opening", "Closing", "Stopped"],
    "Security System Target State": ["Home", "Away", "Night", "Off"], "Security System Current State": ["Home", "Away", "Night", "Off", "Alarm"],
    "Active": ["Inactive", "Active"], "Target Heating Cooling State": ["Off", "Heat", "Cool", "Auto"], "Current Heating Cooling State": ["Off", "Heating", "Cooling"],
    "Target Fan State": ["Manual", "Auto"], "Current Fan State": ["Inactive", "Idle", "Blowing"], "Rotation Direction": ["Clockwise", "Counter-clockwise"],
    "Swing Mode": ["Disabled", "Enabled"], "Programmable Switch Event": ["Single press", "Double press", "Long press"],
    "Contact Sensor State": ["Contact", "No contact"], "Temperature Display Units": ["Celsius", "Fahrenheit"],
    "Air Quality": ["Unknown", "Excellent", "Good", "Fair", "Inferior", "Poor"], "Charging State": ["Not charging", "Charging", "Not chargeable"],
    "Status Low Battery": ["Normal", "Low"], "Leak Detected": ["Dry", "Leak"], "Smoke Detected": ["Clear", "Smoke"], "Carbon Monoxide Detected": ["Normal", "Abnormal"],
    "Target Air Purifier State": ["Manual", "Auto"], "Current Air Purifier State": ["Inactive", "Idle", "Purifying"],
    "Motion Detected": ["No motion", "Motion"], "Occupancy Detected": ["Not occupied", "Occupied"], "Mute": ["Off", "On"],
  };
  // What HomeKit needs to describe an accessory rather than a state a person reads or changes: kept off the page.
  const plumbing = new Set([
    "Name", "Configured Name", "Identifier", "Is Configured", "Current Visibility State", "Target Visibility State", "Input Source Type",
    "Input Device Type", "Sleep Discovery Mode", "Display Order", "Closed Captions", "Picture Mode", "Power Mode Selection",
    "Volume Control Type", "Current Media State", "Target Media State", "Version",
  ]);
  const remoteKeys = [["←", 6, "Left"], ["↑", 4, "Up"], ["↓", 5, "Down"], ["→", 7, "Right"], ["Select", 8], ["Back", 9], ["Play/Pause", 11], ["Info", 15]];

  function serviceKey(service) { return service.subtype || service.type; }
  /// The text for an enumerated value, or the value itself.
  function labelFor(type, value) {
    const labels = enumLabels[type];
    // Motion Detected and the like are booleans whose labels are listed for 0 and 1.
    const index = typeof value === "boolean" ? Number(value) : value;
    return labels && labels[index] !== undefined ? labels[index] : String(value);
  }
  /// "Color Temperature" reads "Color temperature".
  const sentence = (type) => type.charAt(0) + type.slice(1).toLowerCase();

  function writer(accessory, service, characteristic) {
    return async (value, onError = () => {}) => {
      // A security control (a lock, a door, an alarm, or what a plugin marked, such as a switch that unlocks a door)
      // asks first, as the Assistant's set_security_accessory does.
      if (characteristic.security) {
        const label = characteristic.format === "bool" ? (value ? "On" : "Off") : labelFor(characteristic.type, value);
        if (!confirm(`Set ${sentence(characteristic.type).toLowerCase()} of ${accessory.name} to ${label}?`)) { onError(new Error("cancelled")); return; }
      }
      try {
        await api(`/api/accessories/${encodeURIComponent(accessory.id)}`, { method: "PUT", body: { service: serviceKey(service), characteristic: characteristic.type, value } });
      } catch (e) { onError(e); }
    };
  }

  // On and off as 1 and 0.
  const numericSwitches = new Set(["HomeKit Camera Active"]);

  function controlFor(accessory, service, characteristic) {
    const writable = characteristic.permissions.includes("pw");
    const readable = characteristic.permissions.includes("pr");
    const attrs = { "data-id": accessory.id, "data-service": serviceKey(service), "data-char": characteristic.type };
    const write = writer(accessory, service, characteristic);
    const labels = enumLabels[characteristic.type];
    if (writable && (characteristic.format === "bool" || numericSwitches.has(characteristic.type))) return powerSwitch(accessory, service, characteristic);
    if (writable && characteristic.type === "Active Identifier") {
      // The TV's input picker: the input services' identifiers under their names.
      const inputs = accessory.services.filter((s) => s.type === "InputSource").map((s) => {
        const value = (type) => s.characteristics.find((c) => c.type === type)?.value;
        return { identifier: value("Identifier"), name: value("Configured Name") || s.name, hidden: value("Current Visibility State") === 1 };
      }).filter((input) => input.identifier !== undefined && !input.hidden);
      const select = el("select", attrs, ...inputs.map((input) => el("option", { value: input.identifier, text: input.name, selected: input.identifier === characteristic.value })));
      select.addEventListener("change", () => write(Number(select.value)));
      return select;
    }
    if (writable && !readable && characteristic.type === "Remote Key") {
      return el("div", { class: "keys" }, remoteKeys.map(([text, value, label]) => el("button", { text, "aria-label": label || text, onclick: () => write(value) })));
    }
    if (writable && !readable && characteristic.type === "Volume Selector") {
      return el("div", { class: "group" }, el("button", { text: "−", "aria-label": "Volume down", onclick: () => write(1) }), el("button", { text: "+", "aria-label": "Volume up", onclick: () => write(0) }));
    }
    if (writable && (characteristic.validValues || labels)) {
      const values = characteristic.validValues || labels.map((_, index) => index);
      const select = el("select", attrs, ...values.map((value) => el("option", { value, text: labelFor(characteristic.type, value), selected: value === characteristic.value })));
      // A write that fails or is cancelled puts the menu back on the value it had.
      let shown = select.value;
      select.addEventListener("focus", () => { shown = select.value; });
      select.addEventListener("change", () => { const previous = shown; shown = select.value; write(Number(select.value), () => { select.value = previous; shown = previous; }); });
      return select;
    }
    if (writable && ["int", "uint8", "uint16", "uint32", "uint64", "float"].includes(characteristic.format) && characteristic.minValue !== undefined && characteristic.maxValue !== undefined) {
      const input = el("input", { type: "range", min: characteristic.minValue, max: characteristic.maxValue, step: characteristic.minStep || 1, value: characteristic.value ?? 0, "aria-label": sentence(characteristic.type) });
      const value = el("span", { class: "value", text: formatValue(characteristic) });
      let timer;
      input.addEventListener("input", () => { value.textContent = `${input.value}${unit(characteristic)}`; clearTimeout(timer); timer = setTimeout(() => write(Number(input.value)), 250); });
      return el("span", { class: "range", "data-unit": unit(characteristic), ...attrs }, input, value);
    }
    if (writable && characteristic.format === "string") {
      const input = el("input", { type: "text", value: characteristic.value ?? "", ...attrs });
      input.addEventListener("change", () => write(input.value));
      return input;
    }
    if (!readable) return null;
    const text = labels ? labelFor(characteristic.type, characteristic.value) : formatValue(characteristic);
    return el("span", { class: "value", text, ...attrs });
  }

  /// On/Off or Active as a switch; Active writes 1 and 0.
  function powerSwitch(accessory, service, characteristic) {
    const numeric = characteristic.format !== "bool";
    const input = el("input", { type: "checkbox", checked: characteristic.value === true || characteristic.value === 1, "aria-label": `${accessory.name}: ${sentence(characteristic.type)}` });
    const label = el("label", { class: "switch", "data-id": accessory.id, "data-service": serviceKey(service), "data-char": characteristic.type }, input, el("span"));
    const write = writer(accessory, service, characteristic);
    input.addEventListener("change", () => write(numeric ? (input.checked ? 1 : 0) : input.checked, () => { input.checked = !input.checked; }));
    return label;
  }

  function unit(characteristic) {
    return { celsius: " °C", percentage: " %", lux: " lx", seconds: " s", arcdegrees: "°" }[characteristic.unit] || "";
  }
  function formatValue(characteristic) {
    if (characteristic.format === "bool") return characteristic.value ? "On" : "Off";
    if (characteristic.value === null || characteristic.value === undefined) return "";
    return `${characteristic.value}${unit(characteristic)}`;
  }

  /// Rows for the characteristics of a service a person reads or changes; `skip` are shown elsewhere (the
  /// power switch in the header, the remote).
  function controlRows(accessory, service, ...skip) {
    // `internal`: what only HomeKit uses (TLV8 stream configurations, snapshot settings), never a row.
    return service.characteristics.filter((c) => !skip.includes(c) && !plumbing.has(c.type) && !c.internal).map((characteristic) => {
      const control = controlFor(accessory, service, characteristic);
      if (!control) return null;
      const label = rowLabels[characteristic.type] || sentence(characteristic.type);
      return el("div", { class: "control" }, el("span", { text: label }), control);
    }).filter(Boolean);
  }

  const rowLabels = {
    "Active Identifier": "Input", "Remote Key": "Remote", "Volume Selector": "Volume",
    "HomeKit Camera Active": "On in the Home app", "Camera Operating Mode Indicator": "Status light",
  };

  // An accessory's category as its tile: the icon and the colour.
  const categoryIcons = {
    lightbulb: ["bulb", "yellow"], television: ["accessory", "blue"], tvSetTopBox: ["accessory", "blue"], tvStreamingStick: ["accessory", "blue"],
    appleTV: ["accessory", "blue"], switch: ["switch", "green"], programmableSwitch: ["switch", "green"], outlet: ["outlet", "green"],
    sensor: ["sensor", "teal"], fan: ["fan", "teal"], airPurifier: ["fan", "teal"], speaker: ["speaker", "blue"], homePod: ["speaker", "blue"],
    audioReceiver: ["speaker", "blue"], doorLock: ["lock", "violet"], thermostat: ["thermo", "yellow"], heater: ["thermo", "yellow"], airConditioner: ["thermo", "teal"],
    garageDoorOpener: ["door", "violet"], door: ["door", "violet"], window: ["door", "violet"], windowCovering: ["door", "violet"],
    ipCamera: ["camera", "grey"], videoDoorbell: ["camera", "grey"],
  };

  // A television's remote: HomeKit's Remote Key values, and its speaker's volume and mute.
  const homeKitKeys = { up: 4, down: 5, left: 6, right: 7, select: 8, back: 9, playPause: 11, info: 15 };
  function televisionRemote(accessory, primary, remoteKey) {
    const speaker = accessory.services.find((s) => s.type === "TelevisionSpeaker");
    const volume = speaker?.characteristics.find((c) => c.type === "Volume Selector" && c.permissions.includes("pw"));
    const mute = speaker?.characteristics.find((c) => c.type === "Mute" && c.permissions.includes("pw"));
    const actions = [...Object.keys(homeKitKeys), ...(volume ? ["volumeUp", "volumeDown"] : []), ...(mute ? ["mute"] : [])];
    const failing = (e) => { throw e; };
    // Mute toggles from the live state the speaker's switch shows (it follows the TV's events).
    let muted = mute?.value === true;
    const muteState = () => document.querySelector(`[data-id="${CSS.escape(accessory.id)}"][data-char="Mute"] input`)?.checked ?? muted;
    return HomeswiftRemote.build({
      actions, label: `Remote for ${accessory.name}`,
      send: (action) => {
        if (action in homeKitKeys) return writer(accessory, primary, remoteKey)(homeKitKeys[action], failing);
        if (action === "volumeUp" || action === "volumeDown") return writer(accessory, speaker, volume)(action === "volumeUp" ? 0 : 1, failing);
        muted = !muteState();
        return writer(accessory, speaker, mute)(muted, failing);
      },
    });
  }

  // Inputs are chosen with the Input picker; the protocol version is HomeKit's business.
  const quietServices = new Set(["InputSource", "ProtocolInformation"]);

  function accessoryCard(accessory) {
    if (accessory.camera && window.HomeswiftCamera) return cameraCard(accessory);
    const services = accessory.services.filter((s) => !s.internal);
    const primary = services.find((s) => s.primary) || services[0];
    const power = primary && primary.characteristics.find((c) => (c.type === "On" || c.type === "Active") && c.permissions.includes("pw"));
    const remoteKey = primary && primary.characteristics.find((c) => c.type === "Remote Key" && c.permissions.includes("pw"));
    const [iconName, tone] = categoryIcons[accessory.category] || ["generic", "grey"];
    // "Living Room TV HDMI 1" reads "HDMI 1" inside the Living Room TV's card.
    const shortName = (service) => {
      const name = service.name || service.type.replace(/([a-z])([A-Z])/g, "$1 $2");
      return name.startsWith(`${accessory.name} `) ? name.slice(accessory.name.length + 1) : name;
    };
    const others = services.filter((s) => s !== primary && !quietServices.has(s.type))
      .map((service) => ({ service, rows: controlRows(accessory, service) })).filter((other) => other.rows.length);
    // A service with one control (a switch, a sensor) is one row under its own name; the others get a heading.
    const otherNodes = others.map(({ service, rows }) => rows.length === 1
      ? el("div", { class: "control" }, el("span", { text: shortName(service) }), rows[0].lastChild)
      : el("div", { class: "controls" }, el("div", { class: "service-name", text: shortName(service) }), rows));
    const names = others.map(({ service }) => shortName(service));
    const subtitle = [...new Set([describeModel(accessory), accessory.platformName].filter(Boolean))].join(" · ");
    const card = el("div", { class: "card accessory-card", "data-search": `${accessory.name} ${accessory.platformName || ""} ${accessory.model || ""}`.toLowerCase() },
      el("div", { class: "server-head" },
        tile(iconName, tone),
        el("div", { class: "who" }, el("strong", { text: accessory.name }), el("div", { class: "muted", text: subtitle })),
        power ? powerSwitch(accessory, primary, power) : null),
      primary ? el("div", { class: "controls" }, controlRows(accessory, primary, power, remoteKey)) : null,
      remoteKey ? el("div", { class: "card-remote" }, televisionRemote(accessory, primary, remoteKey)) : null,
      others.length ? el("details", { class: "more" },
        el("summary", { text: names.length > 3 ? `${names.slice(0, 2).join(", ")} and ${names.length - 2} more` : names.join(", ") }),
        el("div", { class: "controls" }, otherNodes)) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: accessory.bridge }),
        menuButton(`Actions for ${accessory.name}`, () => accessoryActions(accessory))));
    return card;
  }

  // Under a camera's video: its light (a package camera's flashlight), switches and HomeKit camera setting;
  // sensors and the rest under "More".
  const cameraFirst = new Set(["Lightbulb", "Switch", "Outlet", "CameraOperatingMode"]);
  const cameraServiceNames = { CameraOperatingMode: "Camera", Microphone: "Microphone", Speaker: "Speaker" };

  /// A camera's card: its live video or snapshots on top (camera.js), with its name and state over it, then
  /// its controls. A doorbell's ring shows on the video rather than as a row.
  function cameraCard(accessory) {
    const find = (type, characteristic) => accessory.services.find((s) => s.type === type)?.characteristics.find((c) => c.type === characteristic);
    const view = HomeswiftCamera.view({
      id: accessory.id, name: accessory.name, doorbell: !!accessory.doorbell, lastRing: accessory.lastRing,
      motion: find("MotionSensor", "Motion Detected")?.value === true, recording: find("CameraRecordingManagement", "Active")?.value === 1,
    });
    const rings = accessory.services.flatMap((s) => s.characteristics.filter((c) => c.type === "Programmable Switch Event"));
    // A camera's sensors carry its own name: they read as what they are.
    const shortName = (service) => {
      const own = !service.name || service.name === accessory.name;
      const name = own ? cameraServiceNames[service.type] || service.type.replace(/([a-z])([A-Z])/g, "$1 $2") : service.name;
      return name.startsWith(`${accessory.name} `) ? name.slice(accessory.name.length + 1) : name;
    };
    const groups = accessory.services.filter((s) => !s.internal && !quietServices.has(s.type))
      .map((service) => ({ service, rows: controlRows(accessory, service, ...rings) })).filter((group) => group.rows.length);
    const node = ({ service, rows }) => rows.length === 1
      ? el("div", { class: "control" }, el("span", { text: shortName(service) }), rows[0].lastChild)
      : el("div", { class: "controls" }, el("div", { class: "service-name", text: shortName(service) }), rows);
    const first = groups.filter((group) => cameraFirst.has(group.service.type));
    const more = groups.filter((group) => !cameraFirst.has(group.service.type));
    const names = more.map(({ service }) => shortName(service));
    const subtitle = [...new Set([describeModel(accessory), accessory.platformName].filter(Boolean))].join(" · ");
    return el("div", { class: "card accessory-card camera-card", "data-search": `${accessory.name} ${accessory.platformName || ""} ${accessory.model || ""}`.toLowerCase() },
      view.element,
      subtitle ? el("div", { class: "camera-meta muted", text: subtitle }) : null,
      first.length ? el("div", { class: "controls" }, first.map(node)) : null,
      more.length ? el("details", { class: "more" },
        el("summary", { text: names.length > 3 ? `${names.slice(0, 2).join(", ")} and ${names.length - 2} more` : names.join(", ") }),
        el("div", { class: "controls" }, more.map(node))) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: accessory.bridge }),
        menuButton(`Actions for ${accessory.name}`, () => accessoryActions(accessory))));
  }

  /// What the menu of an accessory's card offers.
  function accessoryActions(accessory) {
    return [
      { label: "Identify", icon: "identify", onSelect: () => api(`/api/accessories/${encodeURIComponent(accessory.id)}/identify`, { method: "POST" }).catch((e) => alert(e.message)) },
      { label: "Show its log", icon: "logs", href: `/logs/${accessory.slug ?? encodeURIComponent(accessory.id)}` },
      window.HomeswiftChat?.available() ? { label: "Ask the Assistant", icon: sparkle(), onSelect: () => HomeswiftChat.ask(`About ${accessory.name}: `) } : null,
      accessory.platform ? { label: "Plugin settings", icon: "gear", href: `/plugins/${slug(accessory.platformName || accessory.platform)}` } : null,
    ];
  }

  views.accessories = async (main) => {
    const accessories = withSlugs(await api("/api/accessories"), "accessory");
    const byBridge = new Map();
    for (const accessory of accessories) {
      if (!byBridge.has(accessory.bridge)) byBridge.set(accessory.bridge, []);
      byBridge.get(accessory.bridge).push(accessory);
    }
    const search = el("input", { type: "search", class: "search", placeholder: "Search accessories", "aria-label": "Search accessories" });
    const sections = [...byBridge].map(([bridge, list]) => el("section", { class: "bridge-section" },
      el("div", { class: "section-head" }, el("h2", { text: bridge }), el("span", { class: "muted", text: `${list.length} ${list.length === 1 ? "accessory" : "accessories"}` })),
      el("div", { class: "grid" }, list.map(accessoryCard))));
    const none = el("p", { class: "muted hidden", text: "No accessory matches." });
    search.addEventListener("input", () => {
      const text = search.value.trim().toLowerCase();
      let shown = 0;
      for (const section of sections) {
        let inSection = 0;
        for (const card of section.querySelectorAll(".accessory-card")) {
          const match = !text || card.dataset.search.includes(text);
          card.classList.toggle("hidden", !match);
          if (match) inSection++;
        }
        section.classList.toggle("hidden", inSection === 0);
        shown += inSection;
      }
      none.classList.toggle("hidden", shown > 0);
    });
    show(main,
      pageHead("Accessories", accessories.length ? `${accessories.length} on ${byBridge.size} ${byBridge.size === 1 ? "server" : "servers"}, as the Home app sees them. Changes here reach your devices.` : "", accessories.length ? search : null),
      accessories.length ? [...sections, none] : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No accessories yet. Plugins add them once they reach their devices." })));
  };

  function describeModel(accessory) {
    const manufacturer = accessory.manufacturer || "";
    const model = accessory.model || "";
    return model.toLowerCase().startsWith(manufacturer.toLowerCase()) ? model : `${manufacturer} ${model}`.trim();
  }

  function applyAccessoryEvent(event) {
    window.HomeswiftCamera?.event(event);
    const selector = `[data-id="${CSS.escape(event.id)}"][data-char="${CSS.escape(event.characteristic)}"]`;
    for (const node of document.querySelectorAll(selector)) {
      if (event.subtype && node.dataset.service !== event.subtype) continue;
      if (node.classList.contains("switch")) $("input", node).checked = event.value === true || event.value === 1;
      else if (node.classList.contains("range")) { $("input", node).value = event.value; $(".value", node).textContent = `${event.value}${node.dataset.unit || ""}`; }
      else if (node.tagName === "SELECT") node.value = String(event.value);
      else if (node.tagName === "INPUT") node.value = event.value;
      else node.textContent = typeof event.value === "boolean" && !enumLabels[event.characteristic] ? (event.value ? "On" : "Off") : labelFor(event.characteristic, event.value);
    }
  }

  // ---- Plugins and settings forms -----------------------------------------

  views.plugins = async (main) => {
    const plugins = await api("/api/plugins");
    const byPlatform = new Map(plugins.plugins.map((plugin) => [plugin.platform, plugin]));
    const running = (block) => plugins.platforms.find((p) => p.platform === block.platform && p.name === block.name);

    const blockCard = (block) => {
      const plugin = byPlatform.get(block.platform);
      const instance = running(block);
      const [state, kind] = blockState(block, plugin, instance);
      // The name opens what the menu's first item opens: the plugin's page, else the form.
      const opens = plugin && plugin.hasPages && instance && !instance.paused ? pluginPage(block) : block.system ? settingsLink(block) : expertLink(block);
      return el("div", { class: "card server" },
        el("div", { class: "server-head" },
          tile(block.system ? "gear" : "plugin", block.system ? "grey" : "orange"),
          el("div", { class: "who" }, el("a", { class: "card-title", href: opens }, el("strong", { text: block.name })),
            el("div", { class: "muted", text: [plugin ? plugin.name : block.platform, block.childBridge ? "child bridge" : null].filter(Boolean).join(" · ") })),
          el("span", { class: `pill status ${kind}`, text: state })),
        instance ? el("div", { class: "facts" }, fact("Bridge", instance.bridge), fact("Accessories", instance.accessories), fact("Platform", block.platform))
          : el("p", { class: "muted note", text: block.system ? "A block of the runtime itself." : plugin ? "It did not start: the log says why." : "No plugin compiled into this homeswift provides this platform." }),
        el("div", { class: "card-foot" },
          el("span", { class: "muted", text: instance?.paused ? "Paused: no calls to its devices; they show No Response in the Home app." : "" }),
          menuButton(`Actions for ${block.name}`, () => blockActions(block, plugin, instance))));
    };

    /// What the menu of a plugin's card offers: its page, the block as a form or as JSON (Expert), pause or
    /// resume, and removal.
    function blockActions(block, plugin, instance) {
      if (block.system) return [{ label: "Settings", icon: "gear", href: settingsLink(block) }, { label: "Edit as JSON", icon: "code", href: expertLink(block, "json") }];
      const toggle = async (paused) => {
        try { await setPaused(block.platform, block.name, paused); route(); } catch (e) { alert(e.message); }
      };
      return [
        plugin && plugin.hasPages && instance && !instance.paused ? { label: "Open its page", icon: "open", href: pluginPage(block) } : null,
        { label: "Edit settings (Expert)", icon: "edit", href: expertLink(block) },
        { label: "Edit as JSON (Expert)", icon: "code", href: expertLink(block, "json") },
        instance && !instance.paused ? { label: "Pause", icon: "pause", onSelect: () => toggle(true) } : null,
        instance?.paused ? { label: "Resume", icon: "play", onSelect: () => toggle(false) } : null,
        { label: "Remove", icon: "trash", danger: true, onSelect: () => removeBlock(block) },
      ];
    }

    const catalog = el("div", { class: "grid" }, plugins.plugins.map((plugin) => {
      const used = plugins.blocks.some((block) => block.platform === plugin.platform);
      return el("div", { class: "card server catalog" },
        el("div", { class: "server-head" }, tile("plugin", "orange"),
          el("div", { class: "who" }, el("strong", { text: plugin.name }), el("div", { class: "muted", text: plugin.platform })),
          used ? el("span", { class: "pill status standby", text: "In use" }) : null),
        el("div", { class: "actions" }, plugin.hasPages
          // A plugin with its own page sets itself up there (pairing a TV, finding lights), as Homebridge's
          // custom UIs do: Add writes an empty block and opens the page.
          ? el("button", { class: used ? "" : "primary", text: used ? "Add another" : "Add", onclick: (event) => addWithPage(plugin, event.currentTarget) })
          : el("a", { class: `button ${used ? "" : "primary"}`, href: `/plugins/add/${encodeURIComponent(plugin.platform)}`, text: used ? "Add another" : "Add" })));
    }));

    async function addWithPage(plugin, button) {
      button.disabled = true;
      const block = { platform: plugin.platform, name: uniqueName(plugin.name, plugins.blocks) };
      try {
        await api(`/api/config/block/${encodeURIComponent(block.platform)}/${encodeURIComponent(block.name)}`, { method: "POST", body: {} });
        location.href = pluginPage(block);
      } catch (e) {
        button.disabled = false;
        alert(e.message);
      }
    }

    show(main,
      pageHead("Plugins", "The blocks of config.json. A save applies at once: the plugin reloads with its accessories kept."),
      plugins.unknownPlatforms.length ? el("div", { class: "card notice" }, el("p", { text: `No plugin provides ${plugins.unknownPlatforms.join(", ")}: those blocks are ignored.` })) : null,
      plugins.blocks.length ? el("div", { class: "grid" }, plugins.blocks.map(blockCard)) : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No plugin yet. Add one below." })),
      el("div", { class: "section-head" }, el("h2", { text: "Add a plugin" }), el("span", { class: "muted", text: "compiled into this homeswift" })),
      catalog);
  };

  /// A block's state pill: its label and tone.
  const blockState = (block, plugin, instance) => block.system ? ["Built in", "standby"] : instance?.paused ? ["Paused", "standby"]
    : instance ? ["Running", "on"] : plugin ? ["Not running", "away"] : ["No plugin", "away"];

  /// Takes a block out of config.json, after asking: its accessories leave the Home app.
  async function removeBlock(block, after = () => route()) {
    if (!confirm(`Remove "${block.name}" from config.json? Its accessories leave the Home app.`)) return;
    try { await api(`/api/config/platforms/${block.index}`, { method: "DELETE" }); leaveGuard = null; after(); } catch (e) { alert(e.message); }
  }

  /// A block's address: its plugin's own page when it has one, else its settings. `expertLink` is always the form
  /// (or the JSON), the whole block as config.json keeps it.
  const settingsLink = (block) => `/plugins/${block.slug}`;
  const pluginPage = settingsLink;
  const expertLink = (block, mode = "form") => `${settingsLink(block)}/expert${mode === "json" ? "/json" : ""}`;

  /// Where a page sits, each level a way back; the last is the page itself.
  function breadcrumb(...levels) {
    return el("nav", { class: "breadcrumb", "aria-label": "Breadcrumb" }, el("ol", {}, levels.map(([text, href], i) =>
      i === levels.length - 1 ? el("li", { "aria-current": "page" }, el("span", { text })) : el("li", {}, el("a", { href, text })))));
  }

  // ---- A plugin's settings: its own page ------------------------------------
  // /plugins/<slug> for a block of config.json, /plugins/add/<platform> to add one. A running plugin with its own
  // page shows that page there: the form is its Expert part, at /plugins/<slug>/expert (or /expert/json). The form comes from the plugin's config.schema.json (or the runtime's own for the web UI's block),
  // JSON otherwise; the save bar stays in view, and leaving with unsaved changes asks first.

  views.settings = async (main, [first, second, third]) => {
    const isNew = first === "add";
    const [plugins, config] = await Promise.all([api("/api/plugins"), api("/api/config", { raw: true }).then(JSON.parse)]);
    const found = isNew ? null : plugins.blocks.find((b) => b.slug === first);
    if (!isNew && !found) {
      show(main, breadcrumb(["Plugins", "/plugins"], ["Settings"]),
        el("div", { class: "card empty" }, el("p", { class: "muted", text: `No plugin at /plugins/${first} in config.json.` })));
      return;
    }
    const platform = isNew ? second : found.platform;
    const plugin = plugins.plugins.find((p) => p.platform === platform);
    const view = isNew ? null : second === "expert" ? (third === "json" ? "json" : "form") : null;
    if (isNew && !plugin) throw new Error(`No plugin provides ${platform}.`);
    const block = found ?? { index: plugins.blocks.length, platform, name: uniqueName(plugin.name, plugins.blocks), system: false };
    const instance = plugins.platforms.find((p) => p.platform === block.platform && p.name === block.name);
    const hasPage = Boolean(!isNew && plugin && plugin.hasPages && instance);
    // Its page is a page of its own, which the server sends for this address once signed in: load it, once (should
    // the server answer with this page again, the form shows rather than a loop).
    if (hasPage && !view && !history.state?.reloaded) { history.replaceState({ reloaded: true }, ""); location.reload(); return; }
    const current = isNew ? { platform, name: block.name } : (config.platforms || [])[block.index] || { platform, name: block.name };

    let schema = null;
    // A plugin's schema, or the runtime's own for its blocks that have one (the web UI's).
    if ((plugin && plugin.hasSchema) || block.system) {
      try { schema = JSON.parse(await api(`/api/plugins/${encodeURIComponent(platform)}/schema`, { raw: true })); } catch {}
    }
    let getValue;
    let body;
    const textarea = el("textarea", { class: "short", value: JSON.stringify(current, null, 2), spellcheck: false, "aria-label": "The block as JSON" });
    const editor = jsonEditor(textarea);
    const fromJSON = () => { const value = JSON.parse(textarea.value); delete value.platform; return value; };
    if (schema) {
      // The form first; the block as JSON one tap away, for what the form does not show. Each view starts
      // from the other's value, and Save takes the one on screen.
      let mode = view === "json" ? "json" : "form";
      let form = buildForm(schema, current);
      const formView = el("div", { class: mode === "form" ? "" : "hidden" }, form.element);
      const jsonView = el("div", { class: mode === "json" ? "" : "hidden" }, el("p", { class: "muted", text: "The block as config.json keeps it." }), editor);
      const switchError = el("p", { class: "error" });
      const tabs = el("div", { class: "group view-switch", role: "tablist", "aria-label": "Edit as" },
        [["form", "Form"], ["json", "JSON"]].map(([value, text]) => el("button", { type: "button", role: "tab", text, class: value === mode ? "on" : "", "aria-selected": String(value === mode), onclick: () => {
          if (value === mode) return;
          switchError.textContent = "";
          try {
            if (value === "json") {
              textarea.value = JSON.stringify({ platform, ...form.getValue() }, null, 2);
              editor.repaint();
            } else {
              form = buildForm(schema, { platform, ...fromJSON() });
              formView.replaceChildren(form.element);
            }
          } catch (e) { switchError.textContent = `The JSON is not valid: ${e.message}`; return; }
          mode = value;
          formView.classList.toggle("hidden", mode !== "form");
          jsonView.classList.toggle("hidden", mode !== "json");
          for (const tab of tabs.children) { tab.classList.toggle("on", tab.textContent.toLowerCase() === mode); tab.setAttribute("aria-selected", String(tab.textContent.toLowerCase() === mode)); }
        } })));
      body = el("div", { class: "card form-card" }, tabs, switchError, formView, jsonView);
      getValue = () => (mode === "form" ? form.getValue() : fromJSON());
    } else {
      body = el("div", { class: "card form-card" }, el("p", { class: "muted", text: "This block has no settings form; edit it as JSON." }), editor);
      getValue = fromJSON;
    }

    // The block as a comparable text: without its platform (the form keeps it, the JSON view leaves it to
    // Save) and with sorted keys, so switching views or reordering keys is not a change.
    const sorted = (value) => Array.isArray(value) ? value.map(sorted)
      : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])])) : value;
    const snapshot = () => { try { const { platform: _, ...rest } = getValue(); return JSON.stringify(sorted(rest)); } catch { return null; } };
    let saved = isNew ? null : snapshot();
    const dirty = () => snapshot() !== saved;
    const message = el("span", { class: "muted" });
    const save = el("button", { class: "primary", text: isNew ? "Add" : "Save" });
    const revert = el("button", { text: isNew ? "Cancel" : "Revert" });
    const update = () => {
      const changed = dirty();
      save.disabled = !isNew && !changed;
      revert.disabled = !isNew && !changed;
      if (!message.classList.contains("error") && !message.classList.contains("ok")) {
        message.className = changed ? "dirty" : "muted";
        message.textContent = isNew ? "A new block: Add writes it to config.json." : changed ? "Unsaved changes" : "Saved";
      }
    };
    body.addEventListener("input", () => { message.className = ""; update(); });
    body.addEventListener("change", () => { message.className = ""; update(); });
    body.addEventListener("click", () => setTimeout(update, 0));   // the array editors add and remove rows by click

    save.addEventListener("click", async () => {
      save.disabled = true;
      message.className = "muted";
      message.textContent = "Saving…";
      try {
        const value = getValue();
        value.platform = platform;
        const result = await api(`/api/config/platforms/${block.index}`, { method: "PUT", body: value });
        saved = snapshot();
        message.className = "ok";
        message.textContent = savedText(result);
        // The web UI's own block: it restarts on its new port or scheme, and this page follows (the login
        // stays, though a session started over HTTPS does not go back to HTTP).
        const port = platform === "HomeswiftUI" ? Number(value.port || 8581) : null;
        const scheme = value.https === true ? "https:" : "http:";
        if (port && (String(port) !== (location.port || (location.protocol === "https:" ? "443" : "80")) || scheme !== location.protocol)) {
          message.textContent = scheme !== location.protocol ? `Saved. The web UI moves to ${scheme.slice(0, -1).toUpperCase()}…` : `Saved. The web UI moves to port ${port}…`;
          setTimeout(() => { location.href = `${scheme}//${location.hostname}:${port}${location.pathname}`; }, 1500);
          return;
        }
        // A new block, or a renamed one, lives at its own address now.
        const name = value.name || platform;
        if (isNew || name !== block.name) { leaveGuard = null; navigate((hasPage ? expertLink : settingsLink)({ slug: slug(name) }), { replace: true }); return; }
        update();
      } catch (e) { message.className = "error"; message.textContent = e.message; save.disabled = false; }
    });
    revert.addEventListener("click", () => { if (isNew) { navigate("/plugins"); return; } leaveGuard = null; route(); });

    const [state, kind] = isNew ? ["New", "standby"] : blockState(block, plugin, instance);
    const remove = !isNew && !block.system ? el("div", { class: "card danger-zone" },
      el("div", {}, el("strong", { text: "Remove this plugin" }),
        el("p", { class: "muted", text: "Takes the block out of config.json. Its accessories leave the Home app, with their rooms, scenes and automations." })),
      el("button", { class: "danger", text: "Remove", onclick: () => removeBlock(block, () => navigate("/plugins")) })) : null;

    leaveGuard = () => !dirty() || isNew || confirm("Leave without saving your changes?");
    leaveGuard.quiet = () => isNew || !dirty();
    show(main,
      breadcrumb(["Plugins", "/plugins"], [block.name, isNew ? "/plugins" : settingsLink(block)], [isNew ? "Add" : hasPage ? "Expert" : "Settings"]),
      el("div", { class: "page-head settings-head" },
        tile(block.system ? "gear" : "plugin", block.system ? "grey" : "orange"),
        el("div", { class: "who" },
          el("h1", { text: isNew ? `Add ${plugin.name}` : block.name }),
          el("p", { class: "muted", text: [...new Set([plugin ? plugin.name : platform, platform])].filter((part) => part !== block.name).concat(
            instance ? [`${instance.accessories} ${instance.accessories === 1 ? "accessory" : "accessories"} on ${instance.bridge}`] : []).join(" · ") })),
        el("div", { class: "tools" }, el("span", { class: `pill status ${kind}`, text: state }))),
      // A plugin with its own page does the everyday work there (pairing, devices); this is the raw block.
      hasPage ? el("div", { class: "card page-note" },
        el("p", {}, el("strong", { text: "Expert. " }), `Every setting of the block, as config.json keeps it, including what ${plugin.name}'s page does not show. A save reloads the plugin.`),
        el("a", { class: "button", href: pluginPage(block), text: "Back to its page" })) : null,
      body,
      el("div", { class: "settings-bar" }, message, revert, save),
      remove);
    update();
  };

  /// A place to drop a file for a path field (a certificate, its key), or to choose it: the bridge keeps the
  /// file next to config.json, owner-only, and the field gets its path.
  function dropZone(key, input, accept = "") {
    const picker = el("input", { type: "file", accept, class: "hidden" });
    const zone = el("div", { class: "drop-zone", role: "button", tabIndex: 0, "aria-label": `Drop or choose the file for ${key}` },
      "Drop the file here, or ", el("strong", { text: "choose it" }), picker);
    const take = async (file) => {
      if (!file) return;
      zone.classList.remove("ok", "error");
      try {
        if (file.size > 256 * 1024) throw new Error("That file is too large for a certificate or a key.");
        const { path } = await api("/api/files", { method: "POST", body: { field: key, name: file.name, content: await file.text() } });
        input.value = path;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        zone.classList.add("ok");
        zone.replaceChildren(`${file.name} saved`, picker);
      } catch (e) {
        zone.classList.add("error");
        zone.replaceChildren(e.message, picker);
      }
    };
    zone.addEventListener("click", (event) => { if (event.target !== picker) picker.click(); });
    zone.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); picker.click(); } });
    picker.addEventListener("change", () => take(picker.files[0]));
    zone.addEventListener("dragover", (event) => { event.preventDefault(); zone.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("over"));
    zone.addEventListener("drop", (event) => { event.preventDefault(); zone.classList.remove("over"); take(event.dataTransfer.files[0]); });
    return zone;
  }

  /// A block name not in use yet: "Elgato Key Lights", then "Elgato Key Lights 2".
  function uniqueName(name, blocks) {
    const taken = new Set(blocks.map((b) => b.name));
    if (!taken.has(name)) return name;
    let n = 2;
    while (taken.has(`${name} ${n}`)) n++;
    return `${name} ${n}`;
  }

  /// A form from a Homebridge-style config.schema.json; key order follows the schema (and its layout).
  function buildForm(root, value) {
    const schema = root.schema || root;
    const properties = schema.properties || {};
    const requiredTop = new Set(Array.isArray(schema.required) ? schema.required : []);
    const fields = new Map();
    const container = el("div", {});

    const field = (key, property, current, required) => {
      const title = property.title || key;
      const help = property.description ? el("div", { class: "help", text: property.description }) : null;
      const wrap = (control) => el("label", { class: "field" }, el("span", { class: "field-title" }, title, required ? el("span", { class: "muted", text: " · required" }) : null), control, help);
      const type = property.type;
      const options = property.oneOf && property.oneOf.every((o) => Array.isArray(o.enum)) ? property.oneOf.map((o) => ({ value: o.enum[0], title: o.title ?? String(o.enum[0]) })) : property.enum ? property.enum.map((v) => ({ value: v, title: String(v) })) : null;
      if (options) {
        const select = el("select", {}, el("option", { value: "", text: "—" }), ...options.map((o) => el("option", { value: JSON.stringify(o.value), text: o.title, selected: current !== undefined ? JSON.stringify(o.value) === JSON.stringify(current) : JSON.stringify(o.value) === JSON.stringify(property.default) })));
        return { element: wrap(select), get: () => (select.value === "" ? undefined : JSON.parse(select.value)) };
      }
      if (type === "boolean") {
        const input = el("input", { type: "checkbox", checked: current !== undefined ? current === true : property.default === true });
        const present = current !== undefined;
        return { element: el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")), el("span", {}, el("span", { class: "field-title", text: title }), help)), get: () => (input.checked || present ? input.checked : undefined) };
      }
      if (type === "integer" || type === "number") {
        const input = el("input", { type: "number", value: current ?? "", placeholder: property.placeholder ?? property.default ?? "", min: property.minimum, max: property.maximum, step: property.step ?? (type === "integer" ? 1 : "any"), required });
        return { element: wrap(input), get: () => (input.value === "" ? undefined : Number(input.value)) };
      }
      if (type === "object" && property.properties) {
        const nested = buildObject(property, current || {});
        return { element: el("fieldset", {}, el("legend", { text: title }), nested.element), get: () => { const v = nested.getValue(); return Object.keys(v).length ? v : undefined; } };
      }
      if (type === "array") {
        const items = property.items || { type: "string" };
        const list = el("div", {});
        const rows = [];
        const addRow = (itemValue) => {
          const entry = {};
          if (items.type === "object" && items.properties) {
            // An entry (a light, a TV) is a row with its name and address; it opens to edit, a new one open.
            const nested = buildObject(items, itemValue || {});
            const name = el("span", { class: "entry-name" });
            const detail = el("span", { class: "entry-detail" });
            const describe = () => {
              const value = nested.getValue();
              name.textContent = value.name || value.displayName || `${title.replace(/s$/, "")} ${rows.indexOf(entry) + 1}`;
              detail.textContent = [value.ip || value.host, value.mac].filter(Boolean).join(" · ");
            };
            const row = el("details", { class: "entry", open: itemValue === undefined },
              el("summary", {}, name, detail, el("button", { class: "link danger", text: "Remove", onclick: (event) => {
                event.preventDefault();
                row.remove();
                rows.splice(rows.indexOf(entry), 1);
                list.dispatchEvent(new Event("input", { bubbles: true }));
              } })),
              nested.element);
            nested.element.addEventListener("input", describe);
            entry.get = nested.getValue;
            rows.push(entry);
            list.append(row);
            describe();
            return;
          }
          const row = el("div", { class: "item" });
          const remove = el("button", { class: "link danger", text: "Remove", onclick: () => { row.remove(); rows.splice(rows.indexOf(entry), 1); } });
          {
            const f = field("", items, itemValue, false);
            row.append(el("div", { class: "item-head" }, f.element, remove));
            entry.get = f.get;
          }
          rows.push(entry);
          list.append(row);
        };
        for (const item of Array.isArray(current) ? current : []) addRow(item);
        const element = el("fieldset", {}, el("legend", { text: title }), help, list,
          el("button", { text: `Add ${title.replace(/s$/, "").toLowerCase()}`, onclick: () => addRow(undefined) }));
        return { element, get: () => { const v = rows.map((r) => r.get()).filter((x) => x !== undefined); return v.length ? v : undefined; } };
      }
      const input = el("input", { type: property["x-schema-form"] && property["x-schema-form"].type === "password" ? "password" : "text", value: current ?? "", placeholder: property.placeholder ?? property.default ?? "", required });
      if (property["x-schema-form"]?.type === "file") return { element: el("div", {}, wrap(input), dropZone(key, input, property["x-schema-form"].accept)), get: () => (input.value === "" ? undefined : input.value) };
      return { element: wrap(input), get: () => (input.value === "" ? undefined : input.value) };
    };

    /// Required fields and the ones that hold a value show; the rest wait under "More options".
    const isSet = (value) => value !== undefined && value !== null && value !== "" && !(Array.isArray(value) && !value.length);
    function splitFields(entries) {
      const shown = [], more = [];
      for (const { element, required, value } of entries) (required || isSet(value) ? shown : more).push(element);
      if (!more.length) return shown;
      return [...shown, el("details", { class: "more-options" }, el("summary", { text: `More options (${more.length})` }), el("div", { class: "fields" }, more))];
    }

    function buildObject(objectSchema, current) {
      const props = objectSchema.properties || {};
      const required = new Set(Array.isArray(objectSchema.required) ? objectSchema.required : []);
      const parts = new Map();
      const element = el("div", { class: "entry-body" });
      const entries = [];
      for (const [key, property] of Object.entries(props)) {
        const isRequired = required.has(key) || property.required === true;
        const f = field(key, property, current[key], isRequired);
        parts.set(key, f);
        entries.push({ element: f.element, required: isRequired, value: current[key] });
      }
      const split = splitFields(entries);
      const first = split.filter((node) => !node.classList?.contains("more-options"));
      element.append(el("div", { class: "fields" }, first), ...split.filter((node) => node.classList?.contains("more-options")));
      return { element, getValue: () => {
        const out = {};
        for (const [key, value] of Object.entries(current)) if (!props[key]) out[key] = value;
        for (const [key, f] of parts) { const v = f.get(); if (v !== undefined) out[key] = v; }
        return out;
      } };
    }

    const render = (key) => {
      const property = properties[key];
      if (!property || fields.has(key)) return null;
      const f = field(key, property, value[key], requiredTop.has(key) || property.required === true);
      fields.set(key, f);
      return f.element;
    };
    const layoutItem = (item) => {
      if (typeof item === "string") return item === "*" ? Object.keys(properties).map(render) : render(item);
      if (item && item.key) return render(item.key);
      if (item && Array.isArray(item.items)) {
        const inner = item.items.map(layoutItem).flat().filter(Boolean);
        if (!inner.length) return null;
        if (item.type === "fieldset" || item.title) {
          return el("details", { class: "group-box", open: !item.expandable || item.expanded !== false }, el("summary", { text: item.title || "More" }), el("div", { class: "fields" }, ...inner));
        }
        return el("div", { class: "fields" }, ...inner);
      }
      return null;
    };
    if (Array.isArray(root.layout)) for (const item of root.layout) { const node = layoutItem(item); if (node) container.append(...[node].flat()); }
    const restKeys = Object.keys(properties).filter((key) => !fields.has(key));
    const rest = restKeys.map((key) => ({ key, element: render(key) })).filter((entry) => entry.element)
      .map(({ key, element }) => ({ element, required: requiredTop.has(key) || properties[key].required === true, value: value[key] }));
    if (rest.length) {
      const split = splitFields(rest);
      container.append(el("div", { class: "fields" }, split.filter((node) => !node.classList?.contains("more-options"))),
        ...split.filter((node) => node.classList?.contains("more-options")));
    }

    return { element: container, getValue: () => {
      const out = {};
      for (const [key, v] of Object.entries(value)) if (!properties[key]) out[key] = v;
      for (const [key, f] of fields) { const v = f.get(); if (v !== undefined) out[key] = v; }
      return out;
    } };
  }

  // ---- Password strength ---------------------------------------------------
  // The gauge asks the server's PasswordPolicy (Sources/HomeswiftUI/PasswordPolicy.swift) while the password is
  // typed: the ANSSI's guide PG-078 (R21 length, R23 a large character set, R27 a check at creation) with the
  // "moyen à fort" bar, 12 characters and 85 bits. The numbers here only draw the gauge.

  const passwordPolicy = { minimumLength: 12, minimumBits: 85, scaleBits: 128 };
  const strengthLabels = { strongToVeryStrong: "Strong to very strong", mediumToStrong: "Medium to strong", lowToMedium: "Low to medium", veryWeak: "Very weak" };

  /// A live gauge under a password field: the ANSSI's bands along 0 to 128 bits, the 85-bit bar marked, and the
  /// two rules ticking as they are met. `username()` gives the name the password must not lean on.
  /// `gauge.acceptable()` answers, once the server has, whether the password as typed passes.
  function strengthGauge(input, username = () => "") {
    const fill = el("div", { class: "gauge-fill" });
    const label = el("strong", {});
    const bits = el("span", { class: "muted" });
    const ruleLength = el("li", { text: `At least ${passwordPolicy.minimumLength} characters` });
    const ruleBits = el("li", { text: `At least ${passwordPolicy.minimumBits} bits of entropy (ANSSI: medium to strong)` });
    const hint = el("p", { class: "help gauge-hint" });
    const track = el("div", { class: "gauge-track", role: "meter", "aria-label": "Password strength", "aria-valuemin": "0", "aria-valuemax": String(passwordPolicy.scaleBits) },
      fill,
      ...[65, 85, 100].map((at) => el("span", { class: "gauge-tick", style: `left:${(at / passwordPolicy.scaleBits) * 100}%` })),
      el("span", { class: "gauge-mark", title: `Required: ${passwordPolicy.minimumBits} bits`, style: `left:${(passwordPolicy.minimumBits / passwordPolicy.scaleBits) * 100}%` }));
    const gauge = el("div", { class: "gauge" }, track, el("div", { class: "gauge-legend" }, label, bits), el("ul", { class: "gauge-rules" }, ruleLength, ruleBits), hint);

    // One request per password and username as typed; an answer that is no longer the latest is dropped.
    let latest = null;
    const evaluate = () => {
      const body = { password: input.value, username: username() };
      const key = JSON.stringify(body);
      if (latest?.key !== key) latest = { key, answer: api("/api/auth/password-strength", { method: "POST", body }) };
      return latest.answer;
    };
    const draw = (s) => {
      gauge.dataset.level = s ? s.level : "";
      fill.style.width = `${Math.min(s?.bits ?? 0, passwordPolicy.scaleBits) / passwordPolicy.scaleBits * 100}%`;
      track.setAttribute("aria-valuenow", String(s?.bits ?? 0));
      track.setAttribute("aria-valuetext", s ? `${strengthLabels[s.level]}, ${s.bits} bits` : "empty");
      label.textContent = s ? strengthLabels[s.level] : "Strength";
      bits.textContent = s ? `${s.bits} bits` : `${passwordPolicy.minimumBits} bits needed`;
      ruleLength.classList.toggle("met", Boolean(s?.lengthMet));
      ruleBits.classList.toggle("met", Boolean(s?.bitsMet));
      hint.textContent = !s || s.bitsMet ? "" : s.reason ? `${s.reason[0].toUpperCase()}${s.reason.slice(1)}.`
        : "Length helps most: a phrase of several random words is strong and easy to remember.";
    };
    let timer = null;
    const update = () => {
      clearTimeout(timer);
      if (!input.value) { latest = null; draw(null); return; }
      timer = setTimeout(async () => {
        const answer = evaluate();
        try { const s = await answer; if (latest?.answer === answer) draw(s); } catch { /* the server's check still decides */ }
      }, 120);
    };
    input.addEventListener("input", update);
    draw(null);
    gauge.refresh = update;
    // When the server cannot be asked, the form goes through: the server's own check then answers.
    gauge.acceptable = async () => input.value !== "" && (await evaluate().catch(() => ({ acceptable: true }))).acceptable;
    return gauge;
  }

  // ---- Account ---------------------------------------------------------------

  views.account = async (main) => {
    const state = await api("/api/auth/state");
    if (state.mode !== "form") {
      show(main, pageHead("Account", "This web UI has no sign-in: its HomeswiftUI block says auth none, so there is no password to change."),
        el("div", { class: "card" }, el("p", { class: "muted", text: "Plugins › HomeswiftUI › Settings turns sign-in on." })));
      return;
    }
    const field = (label, input, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, help ? el("span", { class: "help", text: help }) : null);
    const current = el("input", { type: "password", autocomplete: "current-password", required: true });
    const next = el("input", { type: "password", autocomplete: "new-password", required: true, minLength: passwordPolicy.minimumLength });
    const again = el("input", { type: "password", autocomplete: "new-password", required: true, minLength: passwordPolicy.minimumLength });
    const gauge = strengthGauge(next, () => state.username || "");
    const message = el("p", { class: "status-line muted", role: "status" });
    const submit = el("button", { class: "primary", type: "submit", text: "Change password" });
    const fail = (text) => { message.className = "status-line error"; message.textContent = text; };
    const form = el("form", { class: "card account-form", onsubmit: async (event) => {
      event.preventDefault();
      if (!(await gauge.acceptable())) { next.focus(); return fail("The new password is not strong enough yet: the gauge says what is missing."); }
      if (next.value !== again.value) { again.focus(); return fail("The two new passwords are not the same."); }
      if (next.value === current.value) return fail("The new password is the current one.");
      submit.disabled = true;
      try {
        await api("/api/account/password", { method: "POST", body: { current: current.value, new: next.value } });
        form.reset();
        gauge.refresh();
        message.className = "status-line ok";
        message.textContent = `Password changed. Other browsers signed in as ${state.username} are signed out; this one stays.`;
      } catch (e) { fail(e.message); current.focus(); }
      submit.disabled = false;
    } },
      el("h2", { text: "Change your password" }),
      field("Current password", current),
      el("label", { class: "field" }, el("span", { class: "field-title", text: "New password" }), next, gauge),
      field("New password again", again),
      el("div", { class: "actions" }, submit), message);
    show(main,
      pageHead("Account", `Signed in as ${state.username}. Logins last ${state.sessionDays ?? 7} days without activity.`),
      el("div", { class: "account" }, form,
        el("div", { class: "card" }, el("h2", { text: "Sign out" }),
          el("p", { class: "muted", text: "Ends this browser's session. Changing the password ends the others." }),
          el("button", { text: "Sign out", onclick: () => $("#logout").click() }))));
  };

  // ---- Config --------------------------------------------------------------

  views.config = async (main) => {
    let saved = await api("/api/config", { raw: true });
    const textarea = el("textarea", { value: saved, spellcheck: false, "aria-label": "config.json" });
    const check = el("span", { class: "muted" });
    const message = el("p", { class: "status-line muted" });
    const save = el("button", { class: "primary", text: "Save", disabled: true });
    const revert = el("button", { text: "Revert", disabled: true });
    const format = el("button", { class: "link", text: "Format" });
    // Validity and the unsaved state follow every keystroke, so Save is only offered when it can work.
    const update = () => {
      const dirty = textarea.value !== saved;
      let valid = true;
      try { JSON.parse(textarea.value); check.className = "ok"; check.textContent = dirty ? "Valid JSON · unsaved" : "Saved"; }
      catch (e) { valid = false; check.className = "error"; check.textContent = e.message; }
      save.disabled = !dirty || !valid;
      revert.disabled = !dirty;
    };
    const doSave = async () => {
      if (save.disabled) return;
      save.disabled = true;
      try {
        const result = await api("/api/config", { method: "PUT", body: JSON.parse(textarea.value) });
        message.className = "status-line ok";
        message.textContent = `Changed: ${result.changes.join(", ") || "nothing"}. ${savedText(result)}`;
        saved = await api("/api/config", { raw: true });
        textarea.value = saved;
        editor.repaint();
      } catch (e) { message.className = "status-line error"; message.textContent = e.message; }
      update();
    };
    textarea.addEventListener("input", update);
    textarea.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "s") { event.preventDefault(); doSave(); }
      if (event.key === "Tab" && !event.shiftKey) { event.preventDefault(); textarea.setRangeText("  ", textarea.selectionStart, textarea.selectionEnd, "end"); update(); }
    });
    save.addEventListener("click", doSave);
    revert.addEventListener("click", () => { textarea.value = saved; message.textContent = ""; update(); });
    const editor = jsonEditor(textarea);
    format.addEventListener("click", () => { try { textarea.value = JSON.stringify(JSON.parse(textarea.value), null, 2); editor.repaint(); update(); } catch {} });
    revert.addEventListener("click", () => editor.repaint());
    update();
    show(main,
      pageHead("Configuration", "The whole config.json. Saving validates it, keeps a backup of the previous file (the last 20 under backups/), and applies it at once."),
      el("div", { class: "card editor-card" },
        el("div", { class: "editor-bar" }, el("span", { class: "mono muted", text: "config.json" }), check, el("span", { class: "spacer" }), format, revert, save),
        editor, message));
  };

  // ---- Logs ----------------------------------------------------------------

  const levelRank = { trace: 0, debug: 1, info: 2, notice: 3, warning: 4, error: 5, critical: 6 };
  // The server's caps: the latest lines (/api/logs) and a time range (UIServer.logLimit).
  const latestLines = 2000, rangeLines = 10000;
  const timeFormat = new Intl.DateTimeFormat([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  /// A line with what filtering reads, worked out once: its date and its text in lower case.
  const prepared = (line) => Object.assign(line, { date: new Date(line.time), haystack: `${line.label} ${line.text}`.toLowerCase() });
  const levelChoices = [["trace", "All"], ["info", "Info"], ["warning", "Warnings"], ["error", "Errors"]];
  let logState = null;

  // /logs/<accessory>?bridge=<bridge>&since=24h&level=warning&q=text: the accessory by its slug (a plugin's page
  // may give its id), the bridge by its slug,
  // the range (latest, 1h, 6h, 24h, today, yesterday, 7d, or custom with from= and to=), the lowest level and the
  // text. The address follows what is chosen, so it can be kept or shared.
  views.logs = async (main, [wanted] = []) => {
    const [accessories, bridges] = await Promise.all([
      api("/api/accessories").then((list) => withSlugs(list, "accessory")).catch(() => []),
      api("/api/status").then((status) => withSlugs(status.bridges, "bridge")).catch(() => []),
    ]);
    const accessoryID = accessories.find((accessory) => accessory.slug === wanted || accessory.id === wanted)?.id ?? "";
    const params = new URLSearchParams(location.search);
    const output = el("div", { class: "log", role: "log", "aria-live": "off" });
    const filter = el("input", { type: "search", class: "search", placeholder: "Filter text", "aria-label": "Filter the log" });
    const follow = el("input", { type: "checkbox", checked: true });
    const count = el("span", { class: "muted count" });
    // What the lines are about, one menu: every line; the bridges' own lines (their servers': connections, pairings,
    // controllers), every bridge's or one's; or one accessory's (those of its own server and those naming it, its id
    // or its address). The server picks them before its limit (UIServer.logMatcher), so a week of one accessory
    // is not cut short by the others'. Values: "", "bridge:all", "bridge:<device ID>", "accessory:<id>".
    const byID = new Map(accessories.map((accessory) => [accessory.id, accessory]));
    const termsFor = (id) => {
      const accessory = byID.get(id);
      if (!accessory) return null;
      // ElgatoKeyLights:3C:6A:… → the MAC, as the server matches.
      const rest = id.includes(":") ? id.slice(id.indexOf(":") + 1) : "";
      const address = /^([0-9a-f]{1,2}[:-]){5}[0-9a-f]{1,2}$/i.test(rest) ? rest : null;
      return [accessory.name, id, address, accessory.serialNumber].filter((term) => typeof term === "string" && term.length >= 3).map((term) => term.toLowerCase());
    };
    const bridgeFor = (choice) => {
      const chosen = choice === "all" ? bridges : bridges.filter((b) => b.deviceId === choice);
      if (!chosen.length) return null;
      const labels = new Set(chosen.map((bridge) => bridge.name));
      return (line) => labels.has(line.label);
    };
    const wantedBridge = params.get("bridge") === "all" ? "all" : bridges.find((bridge) => bridge.slug === params.get("bridge"))?.deviceId;
    const initial = accessoryID ? `accessory:${accessoryID}` : wantedBridge ? `bridge:${wantedBridge}` : "";
    const option = (value, text) => el("option", { value, text, selected: value === initial });
    const sourcePicker = el("select", { class: "popup", "aria-label": "What the lines are about" },
      option("", "All lines"),
      bridges.length ? el("optgroup", { label: "Bridges" }, option("bridge:all", "Bridges only"),
        bridges.map((bridge) => option(`bridge:${bridge.deviceId}`, bridge.external ? `${bridge.name} · its own server` : bridge.childBridge ? `${bridge.name} · child bridge` : bridge.name))) : null,
      accessories.length ? el("optgroup", { label: "Accessories" }, [...accessories].sort((a, b) => a.name.localeCompare(b.name)).map((accessory) =>
        option(`accessory:${accessory.id}`, accessory.platformName ? `${accessory.name} · ${accessory.platformName}` : accessory.name))) : null);
    /// The picker's choice: its kind and value.
    const source = () => {
      const [kind, ...rest] = sourcePicker.value.split(":");
      return { kind, value: rest.join(":") };
    };
    const choose = () => {
      const { kind, value } = source();
      logState.accessory = kind === "accessory" ? termsFor(value) : null;
      logState.bridge = kind === "bridge" ? bridgeFor(value) : null;
      sourcePicker.classList.toggle("chosen", Boolean(sourcePicker.value));
    };
    // `live`: new lines join the page (not while a span in the past is shown); `cap`: how many it keeps.
    filter.value = params.get("q") ?? "";
    const level = levelChoices.some(([value]) => value === params.get("level")) ? params.get("level") : "info";
    logState = { output, level, filter, follow, count, lines: [], accessory: null, bridge: null, live: true, cap: latestLines, capped: false };
    choose();
    sourcePicker.addEventListener("change", () => { choose(); load(); });
    const levels = el("div", { class: "group", role: "group", "aria-label": "Lowest level shown" }, levelChoices.map(([level, text]) =>
      el("button", { text, class: level === logState.level ? "on" : "", "aria-pressed": String(level === logState.level), onclick: (event) => {
        logState.level = level;
        for (const button of levels.children) { button.classList.toggle("on", button === event.currentTarget); button.setAttribute("aria-pressed", String(button === event.currentTarget)); }
        render();
        keepAddress();
      } })));
    const render = () => {
      const needle = filter.value.toLowerCase();
      const shown = logState.lines.filter((line) => visible(line, needle));
      output.replaceChildren(...(shown.length ? shown.map(lineNode) : [el("p", { class: "muted empty-log", text: "No line matches." })]));
      count.textContent = `${shown.length} of ${logState.lines.length} lines${logState.capped ? " (the latest of the range)" : ""}`;
      if (follow.checked) output.scrollTop = output.scrollHeight;
    };
    // Typing filters once it pauses: thousands of lines are not drawn again per key.
    let typing = null;
    filter.addEventListener("input", () => { clearTimeout(typing); typing = setTimeout(() => { render(); keepAddress(); }, 120); });
    follow.addEventListener("change", () => { if (follow.checked) output.scrollTop = output.scrollHeight; });

    // A time range: the latest lines from memory, or a span from the log the bridge keeps on disk (rotated, a
    // week at most). A span that ends now keeps following; one in the past stays as it is.
    const ranges = [["latest", "Latest lines"], ["1h", "Last hour"], ["6h", "Last 6 hours"], ["24h", "Last 24 hours"],
      ["today", "Today"], ["yesterday", "Yesterday"], ["7d", "Last 7 days"], ["custom", "Custom range…"]];
    const since = ranges.some(([value]) => value === params.get("since")) ? params.get("since") : "latest";
    const rangePicker = el("select", { class: `popup ${since === "latest" ? "" : "chosen"}`, "aria-label": "Time range" }, ranges.map(([value, text]) => el("option", { value, text, selected: value === since })));
    const localInput = (date) => new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    const fromInput = el("input", { type: "datetime-local", "aria-label": "From", value: params.get("from") ?? localInput(new Date(Date.now() - 3600000)) });
    const toInput = el("input", { type: "datetime-local", "aria-label": "To", value: params.get("to") ?? localInput(new Date()) });
    const customRow = el("div", { class: `log-range ${since === "custom" ? "" : "hidden"}` },
      el("label", {}, "From", fromInput), el("label", {}, "To", toInput),
      el("button", { text: "Show", onclick: () => load() }));
    const span = (choice) => {
      const now = new Date();
      const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      switch (choice) {
      case "1h": return [new Date(now - 3600000), null];
      case "6h": return [new Date(now - 6 * 3600000), null];
      case "24h": return [new Date(now - 86400000), null];
      case "today": return [midnight, null];
      case "yesterday": return [new Date(midnight - 86400000), midnight];
      case "7d": return [new Date(now - 7 * 86400000), null];
      case "custom": {
        const from = new Date(fromInput.value), to = new Date(toInput.value);
        return isNaN(from) ? null : [from, isNaN(to) || to > now ? null : to];
      }
      default: return null;
      }
    };
    /// The address of what is shown, in place: no new history entry per choice.
    function keepAddress() {
      const query = new URLSearchParams();
      if (rangePicker.value !== "latest") query.set("since", rangePicker.value);
      if (rangePicker.value === "custom") { query.set("from", fromInput.value); if (toInput.value) query.set("to", toInput.value); }
      if (logState.level !== "info") query.set("level", logState.level);
      if (filter.value) query.set("q", filter.value);
      const { kind, value } = source();
      const bridge = kind === "bridge" ? bridges.find((b) => b.deviceId === value) : null;
      if (kind === "bridge") query.set("bridge", bridge ? bridge.slug : "all");
      const accessory = kind === "accessory" ? byID.get(value) : null;
      const path = `/logs${accessory ? `/${accessory.slug}` : ""}${query.size ? `?${query}` : ""}`;
      if (path !== location.pathname + location.search) history.replaceState(null, "", path);
    }
    async function load() {
      keepAddress();
      const chosen = span(rangePicker.value);
      const query = new URLSearchParams();
      if (chosen) query.set("from", chosen[0].toISOString());
      if (chosen?.[1]) query.set("to", chosen[1].toISOString());
      const { kind, value } = source();
      if (kind) query.set(kind, value);
      count.textContent = "Loading…";
      try {
        logState.lines = (await api(`/api/logs${query.size ? `?${query}` : ""}`)).map(prepared);
      } catch (e) {
        count.textContent = e.message;
        return;
      }
      logState.live = !chosen?.[1];
      logState.cap = chosen ? rangeLines : latestLines;
      logState.capped = Boolean(chosen) && logState.lines.length >= rangeLines;
      render();
    }
    // What the page shows, as text: a line each, the time, the label, the level when it is not info.
    const copy = el("button", { text: "Copy", title: "Copy the lines shown", onclick: async () => {
      const needle = filter.value.toLowerCase();
      const shown = logState.lines.filter((line) => visible(line, needle));
      const text = shown.map((line) => {
        const level = line.level === "info" || line.level === "notice" ? "" : ` [${line.level.toUpperCase()}]`;
        return `${line.time} [${line.label}]${level} ${line.text}`;
      }).join("\n");
      try {
        await copyText(text);
        copy.textContent = `Copied ${shown.length} line${shown.length === 1 ? "" : "s"}`;
      } catch (e) {
        copy.textContent = "Not copied";
        copy.title = e.message;
      }
      setTimeout(() => { copy.textContent = "Copy"; copy.title = "Copy the lines shown"; }, 1800);
    } });
    rangePicker.addEventListener("change", () => {
      customRow.classList.toggle("hidden", rangePicker.value !== "custom");
      rangePicker.classList.toggle("chosen", rangePicker.value !== "latest");
      if (rangePicker.value === "custom") fromInput.focus(); else load();
    });
    show(main,
      pageHead("Logs", "This homeswift's log, live, and up to a week back."),
      el("div", { class: "card log-card" },
        el("div", { class: "editor-bar" }, levels, rangePicker, sourcePicker, filter, el("span", { class: "spacer" }), count, copy,
          el("label", { class: "toggle compact" }, el("span", { class: "switch" }, follow, el("span")), el("span", { text: "Follow" })),
          customRow),
        output));
    await load();
  };

  /// Whether a prepared line passes the level, the text (`needle`, in lower case) and the accessory.
  function visible(line, needle = logState.filter.value.toLowerCase()) {
    return (levelRank[line.level] ?? 0) >= (levelRank[logState.level] ?? 0) && (!needle || line.haystack.includes(needle))
      && (!logState.accessory || logState.accessory.some((term) => line.haystack.includes(term)))
      && (!logState.bridge || logState.bridge(line));
  }
  function lineNode(line) {
    const time = isNaN(line.date) ? line.time : timeFormat.format(line.date);
    return el("div", { class: `log-line ${line.level}` },
      el("time", { text: time, title: line.time, dateTime: line.time }),
      el("span", { class: "label", text: line.label, title: line.label }),
      el("span", { class: "text", text: line.text }));
  }
  function appendLogLine(line) {
    if (!logState || !logState.live || !document.body.contains(logState.output)) return;
    logState.lines.push(prepared(line));
    if (logState.lines.length > logState.cap) logState.lines.splice(0, logState.lines.length - logState.cap);
    if (!visible(line)) return;
    const output = logState.output;
    // Follow only when the reader is at the bottom: scrolling up to read stops it without a click.
    const atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
    $(".empty-log", output)?.remove();
    output.append(lineNode(line));
    while (output.childElementCount > logState.cap) output.firstElementChild.remove();   // the page stays the size of what it keeps
    if (logState.follow.checked && atBottom) output.scrollTop = output.scrollHeight;
    logState.count.textContent = `${output.childElementCount} of ${logState.lines.length} lines`;
  }

  // A hidden tab keeps no stream open; back in view, the live pages reload their values.
  document.addEventListener("visibilitychange", () => {
    if (!(auth && auth.authenticated)) return;
    if (document.hidden) { closeEvents(); return; }
    openEvents();
    if (["/", "/status", "/accessories"].includes(location.pathname)) route();
  });

  loadAuth().catch((e) => { $("#auth").classList.remove("hidden"); $("#auth-error").textContent = e.message; });
})();
