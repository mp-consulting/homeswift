// THIS FILE IS GENERATED from Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

enum WebAssets {
    /// The UI's pages, as written.
    static let files: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// Homeswift web UI: one page, plain JavaScript, no dependencies. Talks to /api/* with the session cookie.
(() => {
  "use strict";

  const $ = (selector, root = document) => root.querySelector(selector);
  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      // Attributes with no property of the same name: data-*, aria-* (a screen reader reads those).
      else if (key.startsWith("data-") || key.startsWith("aria-")) node.setAttribute(key, value);
      else if (value !== undefined && value !== null && value !== false) node[key] = value;
    }
    for (const child of children.flat()) if (child != null) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  };

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
    $("#auth-submit").disabled = true;
    try {
      const body = { username: form.username.value, password: form.password.value };
      if (auth && auth.setupNeeded) {
        if (setupGauge && !setupGauge.acceptable) throw new Error("The password is not strong enough yet: the gauge says what is missing.");
        body.setupCode = form.setupCode.value;
      }
      await api(auth && auth.setupNeeded ? "/api/auth/setup" : "/api/auth/login", { method: "POST", body });
      form.password.value = "";
      await loadAuth();
    } catch (e) {
      error.textContent = e.message;
    } finally {
      $("#auth-submit").disabled = false;
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
    $("#logout").classList.toggle("hidden", auth.mode !== "form");
    openEvents();
    route();
  }

  // ---- Routing -------------------------------------------------------------

  // A route is a view and its arguments: #settings/ElgatoKeyLights/Desk%20lights is the settings view for that
  // block. Pages below a section keep the section lit in the header.
  const views = {};
  const sectionOf = { settings: "plugins" };
  let leaveGuard = null;   // a page with unsaved changes: false keeps it
  let shownHash = null;
  function route() {
    const [name, ...args] = (location.hash || "#status").slice(1).split("/").map(decodeURIComponent);
    const section = sectionOf[name] || name;
    for (const link of document.querySelectorAll("nav a")) link.classList.toggle("active", link.getAttribute("href") === `#${section}`);
    const view = views[name] || views.status;
    const main = $("#view");
    leaveGuard = null;
    shownHash = location.hash;
    main.replaceChildren(el("p", { class: "muted", text: "Loading…" }));
    view(main, args).catch((e) => { if (e.status !== 401) main.replaceChildren(el("p", { class: "error", text: e.message })); });
  }
  window.addEventListener("hashchange", () => {
    if (!(auth && auth.authenticated)) return;
    if (leaveGuard && !leaveGuard()) { history.replaceState(null, "", shownHash); return; }
    route();
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

  // Line icons for the tiles, drawn like the TV page's: 24-unit boxes, round caps, the current colour.
  const icons = {
    bridge: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/><path d="M10 20v-5h4v5"/>',
    child: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/><path d="M10 6.5h4a3 3 0 0 1 3 3V14"/>',
    accessory: '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/>',
    system: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    bulb: '<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/>',
    switch: '<rect x="6" y="3" width="12" height="18" rx="3"/><circle cx="12" cy="9" r="2"/>',
    outlet: '<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M10 9v2M14 9v2M10 15h4"/>',
    sensor: '<circle cx="12" cy="12" r="2"/><path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8"/>',
    fan: '<circle cx="12" cy="12" r="2"/><path d="M12 10c0-4 1-7 4-7 2 0 3 2 2 4l-4 4M14 12c4 0 7 1 7 4 0 2-2 3-4 2l-4-4M12 14c0 4-1 7-4 7-2 0-3-2-2-4l4-4M10 12c-4 0-7-1-7-4 0-2 2-3 4-2l4 4"/>',
    speaker: '<rect x="6" y="3" width="12" height="18" rx="2"/><circle cx="12" cy="14" r="3"/><path d="M12 7h.01"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    thermo: '<path d="M14 14.8V5a2 2 0 0 0-4 0v9.8a4 4 0 1 0 4 0z"/>',
    door: '<path d="M6 21V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v17M3 21h18M14 12h.01"/>',
    generic: '<rect x="4" y="4" width="16" height="16" rx="4"/>',
    plugin: '<path d="M4 7h4a2 2 0 1 1 4 0h4v4a2 2 0 1 1 0 4v4H4z"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/>',
  };
  function icon(name, kind = name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.innerHTML = icons[name];
    return el("span", { class: `tile ${kind}`, "aria-hidden": "true" }, svg);
  }
  /// A page's title, one line on what it is for, and its tools (search, filters) on the right.
  const pageHead = (title, subtitle, ...tools) => el("div", { class: "page-head" },
    el("div", { class: "who" }, el("h1", { text: title }), subtitle ? el("p", { class: "muted", text: subtitle }) : null),
    tools.filter(Boolean).length ? el("div", { class: "tools" }, ...tools) : null);
  const fact = (label, value, attrs = {}) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: String(value), title: String(value), ...attrs }));

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
      const role = bridge.external ? `Accessory of its own, from ${bridge.platforms.join(", ") || "a plugin"}` : bridge.childBridge ? "Child bridge" : "Main bridge";
      return el("div", { class: "card server" },
        el("div", { class: "server-head" },
          icon(kind),
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
        el("div", { class: "server-head" }, icon("system"),
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
    return labels && labels[value] !== undefined ? labels[value] : String(value);
  }
  /// "Color Temperature" reads "Color temperature".
  const sentence = (type) => type.charAt(0) + type.slice(1).toLowerCase();

  function writer(accessory, service, characteristic) {
    return async (value, onError = () => {}) => {
      try {
        await api(`/api/accessories/${encodeURIComponent(accessory.id)}`, { method: "PUT", body: { service: serviceKey(service), characteristic: characteristic.type, value } });
      } catch (e) { onError(e); }
    };
  }

  function controlFor(accessory, service, characteristic) {
    const writable = characteristic.permissions.includes("pw");
    const readable = characteristic.permissions.includes("pr");
    const attrs = { "data-id": accessory.id, "data-service": serviceKey(service), "data-char": characteristic.type };
    const write = writer(accessory, service, characteristic);
    const labels = enumLabels[characteristic.type];
    if (writable && characteristic.format === "bool") return powerSwitch(accessory, service, characteristic);
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
      select.addEventListener("change", () => write(Number(select.value)));
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
    return service.characteristics.filter((c) => !skip.includes(c) && !plumbing.has(c.type)).map((characteristic) => {
      const control = controlFor(accessory, service, characteristic);
      if (!control) return null;
      const label = characteristic.type === "Active Identifier" ? "Input" : characteristic.type === "Remote Key" ? "Remote" : characteristic.type === "Volume Selector" ? "Volume" : sentence(characteristic.type);
      return el("div", { class: "control" }, el("span", { text: label }), control);
    }).filter(Boolean);
  }

  const categoryIcons = {
    lightbulb: ["bulb", "light"], television: ["accessory", "accessory"], tvSetTopBox: ["accessory", "accessory"], tvStreamingStick: ["accessory", "accessory"],
    appleTV: ["accessory", "accessory"], switch: ["switch", "switch"], programmableSwitch: ["switch", "switch"], outlet: ["outlet", "switch"],
    sensor: ["sensor", "sensor"], fan: ["fan", "sensor"], airPurifier: ["fan", "sensor"], speaker: ["speaker", "accessory"], homePod: ["speaker", "accessory"],
    audioReceiver: ["speaker", "accessory"], doorLock: ["lock", "child"], thermostat: ["thermo", "light"], heater: ["thermo", "light"], airConditioner: ["thermo", "sensor"],
    garageDoorOpener: ["door", "child"], door: ["door", "child"], window: ["door", "child"], windowCovering: ["door", "child"],
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
    const services = accessory.services;
    const primary = services.find((s) => s.primary) || services[0];
    const power = primary && primary.characteristics.find((c) => (c.type === "On" || c.type === "Active") && c.permissions.includes("pw"));
    const remoteKey = primary && primary.characteristics.find((c) => c.type === "Remote Key" && c.permissions.includes("pw"));
    const [iconName, kind] = categoryIcons[accessory.category] || ["generic", "system"];
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
        icon(iconName, kind),
        el("div", { class: "who" }, el("strong", { text: accessory.name }), el("div", { class: "muted", text: subtitle })),
        power ? powerSwitch(accessory, primary, power) : null),
      primary ? el("div", { class: "controls" }, controlRows(accessory, primary, power, remoteKey)) : null,
      remoteKey ? el("div", { class: "card-remote" }, televisionRemote(accessory, primary, remoteKey)) : null,
      others.length ? el("details", { class: "more" },
        el("summary", { text: names.length > 3 ? `${names.slice(0, 2).join(", ")} and ${names.length - 2} more` : names.join(", ") }),
        el("div", { class: "controls" }, otherNodes)) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: accessory.bridge }),
        el("button", { class: "link", text: "Identify", title: "Make the device show itself (blink, beep)", onclick: (event) => {
          const button = event.currentTarget;
          api(`/api/accessories/${encodeURIComponent(accessory.id)}/identify`, { method: "POST" }).then(() => { button.textContent = "Identified"; setTimeout(() => { button.textContent = "Identify"; }, 1500); }).catch(() => {});
        } })));
    return card;
  }

  views.accessories = async (main) => {
    const accessories = await api("/api/accessories");
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
    const selector = `[data-id="${CSS.escape(event.id)}"][data-char="${CSS.escape(event.characteristic)}"]`;
    for (const node of document.querySelectorAll(selector)) {
      if (event.subtype && node.dataset.service !== event.subtype) continue;
      if (node.classList.contains("switch")) $("input", node).checked = event.value === true || event.value === 1;
      else if (node.classList.contains("range")) { $("input", node).value = event.value; $(".value", node).textContent = `${event.value}${node.dataset.unit || ""}`; }
      else if (node.tagName === "SELECT") node.value = String(event.value);
      else if (node.tagName === "INPUT") node.value = event.value;
      else node.textContent = typeof event.value === "boolean" ? (event.value ? "On" : "Off") : labelFor(event.characteristic, event.value);
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
      const [state, kind] = block.system ? ["Built in", "standby"] : instance ? ["Running", "on"] : plugin ? ["Not running", "away"] : ["No plugin", "away"];
      return el("div", { class: "card server" },
        el("div", { class: "server-head" },
          icon(block.system ? "gear" : "plugin", block.system ? "system" : "bridge"),
          el("div", { class: "who" }, el("strong", { text: block.name }), el("div", { class: "muted", text: [plugin ? plugin.name : block.platform, block.childBridge ? "child bridge" : null].filter(Boolean).join(" · ") })),
          el("span", { class: `pill status ${kind}`, text: state })),
        instance ? el("div", { class: "facts" }, fact("Bridge", instance.bridge), fact("Accessories", instance.accessories), fact("Platform", block.platform))
          : el("p", { class: "muted note", text: block.system ? "A block of the runtime itself." : plugin ? "It did not start: the log says why." : "No plugin compiled into this homeswift provides this platform." }),
        el("div", { class: "actions" },
          plugin && plugin.hasPages && instance ? el("a", { class: "button primary", href: pluginPage(block), text: "Open" }) : null,
          el("a", { class: "button", href: settingsLink(block), text: "Settings" })));
    };

    const catalog = el("div", { class: "grid" }, plugins.plugins.map((plugin) => {
      const used = plugins.blocks.some((block) => block.platform === plugin.platform);
      return el("div", { class: "card server catalog" },
        el("div", { class: "server-head" }, icon("plugin", "bridge"),
          el("div", { class: "who" }, el("strong", { text: plugin.name }), el("div", { class: "muted", text: plugin.platform })),
          used ? el("span", { class: "pill status standby", text: "In use" }) : null),
        el("div", { class: "actions" }, el("a", { class: `button ${used ? "" : "primary"}`, href: `#settings/new/${encodeURIComponent(plugin.platform)}`, text: used ? "Add another" : "Add" })));
    }));

    show(main,
      pageHead("Plugins", "The blocks of config.json. A save applies at once: the plugin reloads with its accessories kept."),
      plugins.unknownPlatforms.length ? el("div", { class: "card notice" }, el("p", { text: `No plugin provides ${plugins.unknownPlatforms.join(", ")}: those blocks are ignored.` })) : null,
      plugins.blocks.length ? el("div", { class: "grid" }, plugins.blocks.map(blockCard)) : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No plugin yet. Add one below." })),
      el("div", { class: "section-head" }, el("h2", { text: "Add a plugin" }), el("span", { class: "muted", text: "compiled into this homeswift" })),
      catalog);
  };

  const settingsLink = (block) => `#settings/${encodeURIComponent(block.platform)}/${encodeURIComponent(block.name)}`;
  const pluginPage = (block) => `/plugins/${encodeURIComponent(block.platform)}/index.html?name=${encodeURIComponent(block.name)}`;

  /// Where a page sits, each level a way back; the last is the page itself.
  function breadcrumb(...levels) {
    return el("nav", { class: "breadcrumb", "aria-label": "Breadcrumb" }, el("ol", {}, levels.map(([text, href], i) =>
      i === levels.length - 1 ? el("li", { "aria-current": "page" }, el("span", { text })) : el("li", {}, el("a", { href, text })))));
  }

  // ---- A plugin's settings: its own page ------------------------------------
  // #settings/<platform>/<name> for a block of config.json, #settings/new/<platform> to add one. The form comes
  // from the plugin's config.schema.json (or the runtime's own for the web UI's block), JSON otherwise; the save
  // bar stays in view, and leaving with unsaved changes asks first.

  views.settings = async (main, [first, second]) => {
    const isNew = first === "new";
    const [plugins, config] = await Promise.all([api("/api/plugins"), api("/api/config", { raw: true }).then(JSON.parse)]);
    const platform = isNew ? second : first;
    const plugin = plugins.plugins.find((p) => p.platform === platform);
    const found = isNew ? null : plugins.blocks.find((b) => b.platform === platform && b.name === second);
    if (!isNew && !found) {
      show(main, breadcrumb(["Plugins", "#plugins"], ["Settings"]),
        el("div", { class: "card empty" }, el("p", { class: "muted", text: `No block "${second}" of ${platform} in config.json.` })));
      return;
    }
    if (isNew && !plugin) throw new Error(`No plugin provides ${platform}.`);
    const block = found ?? { index: plugins.blocks.length, platform, name: uniqueName(plugin.name, plugins.blocks), system: false };
    const instance = plugins.platforms.find((p) => p.platform === block.platform && p.name === block.name);
    const current = isNew ? { platform, name: block.name } : (config.platforms || [])[block.index] || { platform, name: block.name };

    let schema = null;
    // A plugin's schema, or the runtime's own for its blocks that have one (the web UI's).
    if ((plugin && plugin.hasSchema) || block.system) {
      try { schema = JSON.parse(await api(`/api/plugins/${encodeURIComponent(platform)}/schema`, { raw: true })); } catch {}
    }
    let getValue;
    let body;
    if (schema) {
      const form = buildForm(schema, current);
      body = el("div", { class: "card form-card" }, form.element);
      getValue = form.getValue;
    } else {
      const textarea = el("textarea", { class: "short", value: JSON.stringify(current, null, 2), spellcheck: false, "aria-label": "The block as JSON" });
      body = el("div", { class: "card form-card" }, el("p", { class: "muted", text: "This block has no settings form; edit it as JSON." }), textarea);
      getValue = () => JSON.parse(textarea.value);
    }

    const snapshot = () => { try { return JSON.stringify(getValue()); } catch { return null; } };
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
        // The web UI's own block: it restarts on its new port, and this page follows (the login stays).
        const port = platform === "HomeswiftUI" ? Number(value.port || 8581) : null;
        if (port && String(port) !== (location.port || (location.protocol === "https:" ? "443" : "80"))) {
          message.textContent = `Saved. The web UI moves to port ${port}…`;
          setTimeout(() => { location.href = `${location.protocol}//${location.hostname}:${port}/${settingsLink({ platform, name: value.name || block.name })}`; }, 1500);
          return;
        }
        // A new block, or a renamed one, lives at its own address now.
        const name = value.name || platform;
        if (isNew || name !== block.name) { leaveGuard = null; location.hash = settingsLink({ platform, name }); return; }
        update();
      } catch (e) { message.className = "error"; message.textContent = e.message; save.disabled = false; }
    });
    revert.addEventListener("click", () => { if (isNew) { location.hash = "#plugins"; return; } leaveGuard = null; route(); });

    const [state, kind] = isNew ? ["New", "standby"] : block.system ? ["Built in", "standby"] : instance ? ["Running", "on"] : plugin ? ["Not running", "away"] : ["No plugin", "away"];
    const remove = !isNew && !block.system ? el("div", { class: "card danger-zone" },
      el("div", {}, el("strong", { text: "Remove this plugin" }),
        el("p", { class: "muted", text: "Takes the block out of config.json. Its accessories leave the Home app, with their rooms, scenes and automations." })),
      el("button", { class: "danger", text: "Remove", onclick: async () => {
        if (!confirm(`Remove "${block.name}" from config.json? Its accessories leave the Home app.`)) return;
        try { await api(`/api/config/platforms/${block.index}`, { method: "DELETE" }); leaveGuard = null; location.hash = "#plugins"; } catch (e) { alert(e.message); }
      } })) : null;

    leaveGuard = () => !dirty() || isNew || confirm("Leave without saving your changes?");
    leaveGuard.quiet = () => isNew || !dirty();
    show(main,
      breadcrumb(["Plugins", "#plugins"], [block.name, isNew ? "#plugins" : settingsLink(block)], [isNew ? "Add" : "Settings"]),
      el("div", { class: "page-head settings-head" },
        icon(block.system ? "gear" : "plugin", block.system ? "system" : "bridge"),
        el("div", { class: "who" },
          el("h1", { text: isNew ? `Add ${plugin.name}` : block.name }),
          el("p", { class: "muted", text: [...new Set([plugin ? plugin.name : platform, platform])].filter((part) => part !== block.name).concat(
            instance ? [`${instance.accessories} ${instance.accessories === 1 ? "accessory" : "accessories"} on ${instance.bridge}`] : []).join(" · ") })),
        el("div", { class: "tools" }, el("span", { class: `pill status ${kind}`, text: state }))),
      // A plugin with its own page does the everyday work there (pairing, devices); this is the raw block.
      plugin && plugin.hasPages && instance ? el("div", { class: "card page-note" },
        el("p", { text: `${plugin.name} has its own page for its devices, and it is the easier place for everyday changes. This form is the whole block, as config.json keeps it.` }),
        el("a", { class: "button primary", href: pluginPage(block), text: "Open its page" })) : null,
      body,
      el("div", { class: "settings-bar" }, message, revert, save),
      remove);
    update();
  };

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
  // The server's PasswordPolicy (Sources/HomeswiftUI/PasswordPolicy.swift), mirrored for the gauge: the ANSSI's
  // guide PG-078 (R21 length, R23 a large character set, R27 a check at creation) with the "moyen à fort" bar,
  // 12 characters and 85 bits. Entropy is length × log2(character set), less what people tend to type. The
  // server's check decides; this only shows it while typing.

  const passwordPolicy = { minimumLength: 12, minimumBits: 85, scaleBits: 128 };
  const commonWords = ["password", "passw0rd", "motdepasse", "secret", "admin", "administrator", "root", "user", "login", "welcome", "letmein", "iloveyou", "monkey", "dragon", "master", "sunshine", "princess", "football", "baseball", "shadow", "azerty", "qwerty", "qwertz", "asdf", "zxcv", "abc123", "123456", "654321", "111111", "000000", "121212", "bonjour", "soleil", "chouchou", "doudou", "loulou", "marseille", "paris", "france", "amour", "jetaime", "homeswift", "homebridge", "homekit", "apple", "iphone", "changeme", "default", "test",];
  const strengthLevels = [
    [100, "strongToVeryStrong", "Strong to very strong"], [85, "mediumToStrong", "Medium to strong"],
    [65, "lowToMedium", "Low to medium"], [0, "veryWeak", "Very weak"],
  ];

  function passwordStrength(password, username = "") {
    const chars = Array.from(password);
    const code = (c) => c.codePointAt(0);
    let pool = 0;
    if (chars.some((c) => c >= "a" && c <= "z")) pool += 26;
    if (chars.some((c) => c >= "A" && c <= "Z")) pool += 26;
    if (chars.some((c) => c >= "0" && c <= "9")) pool += 10;
    if (chars.some((c) => code(c) < 128 && !/[A-Za-z0-9]/.test(c))) pool += 33;
    if (chars.some((c) => code(c) >= 128)) pool += 64;
    const counts = chars.map(() => true);
    let patterned = false;
    for (let i = 2; i < chars.length; i++) {
      const [a, b, c] = [code(chars[i - 2]), code(chars[i - 1]), code(chars[i])];
      if ((a === b && b === c) || (b - a === c - b && Math.abs(c - b) === 1)) { counts[i] = false; patterned = true; }
    }
    const lowered = chars.map((c) => { const l = c.toLowerCase(); return Array.from(l).length === 1 ? l : c; });
    const name = username.trim().toLowerCase();
    const words = Array.from(name).length >= 3 ? [...commonWords, name] : commonWords;
    let foundCommon = false, foundName = false;
    for (const word of words) {
      const target = Array.from(word);
      for (let i = 0; i + target.length <= lowered.length;) {
        if (target.every((t, k) => lowered[i + k] === t)) {
          for (let j = i + 1; j < i + target.length; j++) counts[j] = false;
          if (word === name) foundName = true; else foundCommon = true;
          i += target.length;
        } else i++;
      }
    }
    const effective = counts.filter(Boolean).length;
    const bits = pool ? effective * Math.log2(pool) : 0;
    const [, level, label] = strengthLevels.find(([floor]) => bits >= floor);
    let hint = null;
    if (bits < passwordPolicy.minimumBits) {
      hint = foundName ? "Your username adds nothing." : foundCommon ? "Common words add little." : patterned ? "Repeated or sequential characters add nothing."
        : "Length helps most: a phrase of several random words is strong and easy to remember.";
    }
    const lengthOK = chars.length >= passwordPolicy.minimumLength;
    const bitsOK = bits >= passwordPolicy.minimumBits;
    return { bits, length: chars.length, level, label, hint, lengthOK, bitsOK, acceptable: lengthOK && bitsOK };
  }

  /// A live gauge under a password field: the ANSSI's bands along 0 to 128 bits, the 80-bit bar marked, and the
  /// two rules ticking as they are met. `username()` gives the name the password must not lean on.
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
    const update = () => {
      const s = passwordStrength(input.value, username());
      const empty = input.value.length === 0;
      gauge.dataset.level = empty ? "" : s.level;
      fill.style.width = `${Math.min(s.bits, passwordPolicy.scaleBits) / passwordPolicy.scaleBits * 100}%`;
      track.setAttribute("aria-valuenow", String(Math.round(s.bits)));
      track.setAttribute("aria-valuetext", empty ? "empty" : `${s.label}, ${Math.round(s.bits)} bits`);
      label.textContent = empty ? "Strength" : s.label;
      bits.textContent = empty ? `${passwordPolicy.minimumBits} bits needed` : `${Math.round(s.bits)} bits`;
      ruleLength.classList.toggle("met", s.lengthOK);
      ruleBits.classList.toggle("met", s.bitsOK);
      hint.textContent = empty ? "" : s.hint ?? "";
      gauge.acceptable = s.acceptable;
    };
    input.addEventListener("input", update);
    update();
    gauge.refresh = update;
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
      if (!gauge.acceptable) { next.focus(); return fail("The new password is not strong enough yet: the gauge says what is missing."); }
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
    format.addEventListener("click", () => { try { textarea.value = JSON.stringify(JSON.parse(textarea.value), null, 2); update(); } catch {} });
    update();
    show(main,
      pageHead("Configuration", "The whole config.json. Saving validates it, keeps a backup of the previous file (the last 20 under backups/), and applies it at once."),
      el("div", { class: "card editor-card" },
        el("div", { class: "editor-bar" }, el("span", { class: "mono muted", text: "config.json" }), check, el("span", { class: "spacer" }), format, revert, save),
        textarea, message));
  };

  // ---- Logs ----------------------------------------------------------------

  const levelRank = { trace: 0, debug: 1, info: 2, notice: 3, warning: 4, error: 5, critical: 6 };
  const levelChoices = [["trace", "All"], ["info", "Info"], ["warning", "Warnings"], ["error", "Errors"]];
  let logState = null;

  views.logs = async (main) => {
    const lines = await api("/api/logs");
    const output = el("div", { class: "log", role: "log", "aria-live": "off" });
    const filter = el("input", { type: "search", class: "search", placeholder: "Filter text", "aria-label": "Filter the log" });
    const follow = el("input", { type: "checkbox", checked: true });
    const count = el("span", { class: "muted count" });
    logState = { output, level: "info", filter, follow, count, lines: [] };
    const levels = el("div", { class: "group", role: "group", "aria-label": "Lowest level shown" }, levelChoices.map(([level, text]) =>
      el("button", { text, class: level === logState.level ? "on" : "", "aria-pressed": String(level === logState.level), onclick: (event) => {
        logState.level = level;
        for (const button of levels.children) { button.classList.toggle("on", button === event.currentTarget); button.setAttribute("aria-pressed", String(button === event.currentTarget)); }
        render();
      } })));
    const render = () => {
      const shown = logState.lines.filter(visible);
      output.replaceChildren(...(shown.length ? shown.map(lineNode) : [el("p", { class: "muted empty-log", text: "No line matches." })]));
      count.textContent = `${shown.length} of ${logState.lines.length} lines`;
      if (follow.checked) output.scrollTop = output.scrollHeight;
    };
    filter.addEventListener("input", render);
    follow.addEventListener("change", () => { if (follow.checked) output.scrollTop = output.scrollHeight; });
    logState.lines = lines;
    show(main,
      pageHead("Logs", "The last 2,000 lines of this homeswift, live."),
      el("div", { class: "card log-card" },
        el("div", { class: "editor-bar" }, levels, filter, el("span", { class: "spacer" }), count,
          el("label", { class: "toggle compact" }, el("span", { class: "switch" }, follow, el("span")), el("span", { text: "Follow" }))),
        output));
    render();
  };

  function visible(line) {
    const minimum = levelRank[logState.level] ?? 0;
    const text = logState.filter.value.toLowerCase();
    return (levelRank[line.level] ?? 0) >= minimum && (!text || `${line.label} ${line.text}`.toLowerCase().includes(text));
  }
  function lineNode(line) {
    const date = new Date(line.time);
    const time = isNaN(date) ? line.time : date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
    return el("div", { class: `log-line ${line.level}` },
      el("time", { text: time, title: line.time, dateTime: line.time }),
      el("span", { class: "label", text: line.label, title: line.label }),
      el("span", { class: "text", text: line.text }));
  }
  function appendLogLine(line) {
    if (!logState || !document.body.contains(logState.output)) return;
    logState.lines.push(line);
    if (logState.lines.length > 2000) logState.lines.shift();
    if (!visible(line)) return;
    const output = logState.output;
    // Follow only when the reader is at the bottom: scrolling up to read stops it without a click.
    const atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
    $(".empty-log", output)?.remove();
    output.append(lineNode(line));
    while (output.childElementCount > 2000) output.firstElementChild.remove();   // the page stays the size of the buffer
    if (logState.follow.checked && atBottom) output.scrollTop = output.scrollHeight;
    logState.count.textContent = `${output.childElementCount} of ${logState.lines.length} lines`;
  }

  // A hidden tab keeps no stream open; back in view, the live pages reload their values.
  document.addEventListener("visibilitychange", () => {
    if (!(auth && auth.authenticated)) return;
    if (document.hidden) { closeEvents(); return; }
    openEvents();
    if (["#status", "#accessories"].includes(location.hash || "#status")) route();
  });

  loadAuth().catch((e) => { $("#auth").classList.remove("hidden"); $("#auth-error").textContent = e.message; });
})();

"""#),
        "icon.svg": WebFile(contentType: "image/svg+xml", body: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>Homeswift</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FFA01C"/>
      <stop offset="1" stop-color="#F0442E"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="228" fill="url(#bg)"/>
  <!-- House: 13% side margins, 12.5% above, 20% below, a 37° roof whose eaves overhang the walls -->
  <path d="M165 420.3 L512 160 L859 420.3 M227 373.8 V763 Q227 787 251 787 H773 Q797 787 797 763 V373.8"
        fill="none" stroke="#fff" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>
  <!-- The Swift logo bird (swift.org), a trademark of Apple Inc.: its bounding box centred on the house's interior -->
  <path fill="#fff" transform="translate(512 522) scale(8) translate(-28.38 -28.5)" d="m47.06 36.66-.004-.004c.066-.224.134-.446.191-.675 2.465-9.821-3.55-21.432-13.731-27.546 4.461 6.048 6.434 13.374 4.681 19.78-.156.571-.344 1.12-.552 1.653-.225-.148-.51-.316-.89-.527 0 0-10.127-6.252-21.103-17.312-.288-.29 5.852 8.777 12.822 16.14-3.284-1.843-12.434-8.5-18.227-13.802.712 1.187 1.558 2.33 2.489 3.43C17.573 23.932 23.882 31.5 31.44 37.314c-5.31 3.25-12.814 3.502-20.285.003a30.646 30.646 0 0 1-5.193-3.098c3.162 5.058 8.033 9.423 13.96 11.97 7.07 3.039 14.1 2.833 19.336.05l-.004.007c.024-.016.055-.032.08-.047.214-.116.428-.234.636-.358 2.516-1.306 7.485-2.63 10.152 2.559.654 1.27 2.041-5.46-3.061-11.74z"/>
</svg>

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Homeswift</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div id="auth" class="auth hidden">
  <form id="auth-form" class="card">
    <img src="/icon.svg" class="logo large" alt="">
    <h1>Homeswift</h1>
    <p id="auth-text"></p>
    <label>Username <input name="username" autocomplete="username" required></label>
    <label>Password <input name="password" type="password" autocomplete="current-password" required minlength="1"></label>
    <label id="auth-setup-code" class="hidden">Set-up code <input name="setupCode" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="XXXX-XXXX"></label>
    <p class="error" id="auth-error"></p>
    <button type="submit" id="auth-submit">Sign in</button>
  </form>
</div>
<div id="app" class="hidden">
  <header>
    <a class="brand" href="#status"><img src="/icon.svg" class="logo" alt="">Homeswift</a>
    <nav>
      <a href="#status">Status</a>
      <a href="#accessories">Accessories</a>
      <a href="#plugins">Plugins</a>
      <a href="#config">Config</a>
      <a href="#logs">Logs</a>
    </nav>
    <span class="spacer"></span>
    <a id="user" href="#account" title="Your account: change the password"></a>
    <button id="logout" class="link">Sign out</button>
  </header>
  <div id="banner" class="banner hidden">Some changes need a restart of homeswift. <button id="restart" class="link">Restart now</button></div>
  <main id="view"></main>
</div>
<script src="/remote.js"></script>
<script src="/app.js"></script>
</body>
</html>

"""#),
        "plugin.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// For a plugin's own pages, served at /plugins/<platform>/: homeswift.request() talks to the plugin instance
// named in the page's URL (?name=), with the session cookie; homeswift.el() and homeswift.$() build and find
// elements the way the UI's own pages do. A signed-out visitor is sent to the login page.
(() => {
  "use strict";
  const platform = decodeURIComponent(location.pathname.split("/")[2] || "");
  const name = new URLSearchParams(location.search).get("name") || platform;
  const prefix = `/api/plugins/${encodeURIComponent(platform)}/${encodeURIComponent(name)}/`;

  const $ = (selector, root = document) => root.querySelector(selector);
  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      // Attributes with no property of the same name: data-*, aria-* (a screen reader reads those).
      else if (key.startsWith("data-") || key.startsWith("aria-")) node.setAttribute(key, value);
      else if (value !== undefined && value !== null && value !== false) node[key] = value;
    }
    for (const child of children.flat()) if (child != null) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  };

  async function request(path, { method = "GET", body } = {}) {
    const options = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = JSON.stringify(body); }
    const response = await fetch(prefix + String(path).replace(/^\//, ""), options);
    if (response.status === 401) { location.href = "/"; throw new Error("signed out"); }
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { error: text }; }
    if (!response.ok) throw new Error((json && json.error) || `HTTP ${response.status}`);
    return json;
  }

  // The Assistant, when config.json has a HomeswiftAiKit block that works: pages offer "Explain" next to errors.
  let assistantState = null;
  const assistant = () => (assistantState ??= fetch("/api/assistant", { credentials: "same-origin" })
    .then((response) => (response.ok ? response.json() : { enabled: false })).catch(() => ({ enabled: false })));

  /// Markdown from the Assistant as elements, never as HTML: headings, paragraphs, nested lists, code blocks,
  /// bold, italics, code and http(s) links. Anything else stays text.
  function markdown(source) {
    const root = el("div", { class: "md" });
    const lines = String(source).replace(/\r/g, "").split("\n");
    let paragraph = [];
    let lists = [];   // { indent, node }, the open lists, innermost last
    const flush = () => {
      if (paragraph.length) root.append(el("p", {}, inline(paragraph.join(" "))));
      paragraph = [];
    };
    const closeLists = () => { lists = []; };
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (/^\s*```/.test(line)) {
        flush(); closeLists();
        const code = [];
        while (++i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i]);
        root.append(el("pre", {}, el("code", { text: code.join("\n") })));
        continue;
      }
      const heading = line.match(/^\s*(#{1,6})\s+(.*)$/);
      if (heading) {
        flush(); closeLists();
        root.append(el(heading[1].length <= 2 ? "h3" : "h4", {}, inline(heading[2].replace(/^"(.*)"$/, "$1"))));
        continue;
      }
      const item = line.match(/^(\s*)([-*+•]|\d+[.)])\s+(.*)$/);
      if (item) {
        flush();
        const indent = item[1].replace(/\t/g, "  ").length;
        const ordered = /\d/.test(item[2]);
        while (lists.length && lists[lists.length - 1].indent > indent) lists.pop();
        let current = lists[lists.length - 1];
        if (!current || current.indent < indent || current.ordered !== ordered) {
          const node = el(ordered ? "ol" : "ul", {});
          const parent = current && current.indent < indent ? current.node.lastElementChild : null;
          (parent || root).append(node);
          if (current && current.indent === indent) lists.pop();
          current = { indent, ordered, node };
          lists.push(current);
        }
        current.node.append(el("li", {}, inline(item[3])));
        continue;
      }
      if (!line.trim()) { flush(); continue; }
      if (lists.length && /^\s+\S/.test(line)) {
        // A continuation of the last item.
        lists[lists.length - 1].node.lastElementChild?.append(" ", ...inline(line.trim()));
        continue;
      }
      closeLists();
      paragraph.push(line.trim());
    }
    flush();
    return root;
  }

  /// Inline Markdown: **bold**, *italics*, `code`, [a link](https://…).
  function inline(text) {
    const nodes = [];
    const pattern = /(\*\*[^*]+\*\*|__[^_]+__|`[^`]+`|\*[^*\s][^*]*\*|\[[^\]]+\]\((?:https?:\/\/)[^)\s]+\))/g;
    let last = 0;
    for (const match of text.matchAll(pattern)) {
      if (match.index > last) nodes.push(text.slice(last, match.index));
      const token = match[0];
      if (token.startsWith("**") || token.startsWith("__")) nodes.push(el("strong", { text: token.slice(2, -2) }));
      else if (token.startsWith("`")) nodes.push(el("code", { text: token.slice(1, -1) }));
      else if (token.startsWith("[")) {
        const [, label, url] = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
        nodes.push(el("a", { href: url, text: label, target: "_blank", rel: "noopener noreferrer" }));
      } else nodes.push(el("em", { text: token.slice(1, -1) }));
      last = match.index + token.length;
    }
    if (last < text.length) nodes.push(text.slice(last));
    return nodes;
  }

  // The Apple Intelligence sparkle, its colours on a gradient (an id per drawing, so each has its own).
  let sparkles = 0;
  function sparkle() {
    const id = `ai-gradient-${++sparkles}`;
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.classList.add("sparkle");
    svg.innerHTML = `<defs><linearGradient id="${id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff9f0a"/><stop offset=".35" stop-color="#ff375f"/><stop offset=".7" stop-color="#bf5af2"/><stop offset="1" stop-color="#5e5ce6"/></linearGradient></defs>`
      + `<path fill="url(#${id})" d="M11 2.5c.7 5 3 7.3 8 8-5 .7-7.3 3-8 8-.7-5-3-7.3-8-8 5-.7 7.3-3 8-8z"/>`
      + `<path fill="url(#${id})" d="M19 14.5c.3 2 1 2.7 3 3-2 .3-2.7 1-3 3-.3-2-1-2.7-3-3 2-.3 2.7-1 3-3z"/>`;
    return svg;
  }

  // Answers by error, so a card a page redraws (a TV's state changed) shows the answer it already had, and a
  // request in flight carries on into the new card.
  const explanations = new Map();

  /// "Explain" for an error, after Apple Intelligence: a sparkle button; while the Assistant thinks, a glow
  /// turning around the card; then the answer, typeset, in a glass card with a thin rainbow edge. Empty without
  /// an Assistant. `context` says what was being done; `device` describes the device (no secrets).
  function explain({ error, context, device }) {
    const box = el("div", { class: "explain" });
    assistant().then((state) => {
      if (!state.enabled) return;
      const button = el("button", { class: "ai-button", title: `Ask the Assistant (${state.provider})` }, sparkle(), el("span", { text: "Explain" }));
      const card = el("div", { class: "ai-card hidden", role: "region", "aria-label": "The Assistant's explanation", "aria-live": "polite" });
      const show = (entry) => {
        card.classList.remove("hidden", "thinking", "answered", "failed");
        button.classList.add("hidden");
        const close = el("button", { class: "ai-close", title: "Close", "aria-label": "Close the explanation", text: "×", onclick: () => {
          card.classList.add("hidden");
          button.classList.remove("hidden");
        } });
        const head = (label) => el("div", { class: "ai-head" }, sparkle(), el("span", { class: "ai-label", text: label }), el("span", { class: "spacer" }), close);
        if (entry.pending) {
          card.classList.add("thinking");
          card.replaceChildren(el("div", { class: "ai-inner" }, head("Assistant"), el("p", { class: "ai-thinking", text: "Thinking about it…" })));
          entry.pending.finally(() => { if (document.body.contains(card) && !card.classList.contains("hidden")) show(explanations.get(error)); });
          return;
        }
        if (entry.failed) {
          card.classList.add("failed");
          card.replaceChildren(el("div", { class: "ai-inner" }, head("Assistant"),
            el("p", { class: "error", text: entry.failed }),
            el("button", { class: "link", text: "Try again", onclick: () => { explanations.delete(error); ask(); } })));
          return;
        }
        card.classList.add("answered");
        const body = markdown(entry.text);
        body.classList.add("ai-body");
        const more = el("button", { class: "link ai-more", text: "Show more", onclick: () => {
          body.classList.toggle("clamped");
          more.textContent = body.classList.contains("clamped") ? "Show more" : "Show less";
        } });
        card.replaceChildren(el("div", { class: "ai-inner" }, head(`Assistant · ${entry.model || state.model}`), body, more));
        // Long answers open on their first lines, with the rest a click away.
        requestAnimationFrame(() => {
          body.classList.add("clamped");
          if (body.scrollHeight <= body.clientHeight + 4) { body.classList.remove("clamped"); more.remove(); }
        });
      };
      const ask = () => {
        const entry = { pending: null };
        entry.pending = fetch("/api/assistant/explain", {
          method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ error, context, device, plugin: platform }),
        }).then(async (response) => {
          const json = await response.json().catch(() => ({}));
          if (!response.ok) throw new Error(json.error || `HTTP ${response.status}`);
          explanations.set(error, { text: json.text, model: json.model });
        }).catch((e) => { explanations.set(error, { failed: e.message }); });
        explanations.set(error, entry);
        show(entry);
        card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
      };
      button.addEventListener("click", () => (explanations.has(error) ? show(explanations.get(error)) : ask()));
      box.replaceChildren(button, card);
      if (explanations.has(error)) show(explanations.get(error));
    });
    return box;
  }

  // The UI's own header on every plugin page, Plugins highlighted, so leaving a plugin's page is one click
  // anywhere; and a breadcrumb under it: Plugins › the plugin › (its instance) › what is open on the page.
  const sections = [["#status", "Status"], ["#accessories", "Accessories"], ["#plugins", "Plugins"], ["#config", "Config"], ["#logs", "Logs"]];
  const header = $("header");
  if (header) {
    const user = el("a", { id: "user", href: "/#account", title: "Your account: change the password" });
    const logout = el("button", { id: "logout", class: "link hidden", text: "Sign out", onclick: async () => {
      try { await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }); } catch {}
      location.href = "/";
    } });
    header.replaceChildren(
      el("a", { class: "brand", href: "/#status" }, el("img", { src: "/icon.svg", class: "logo", alt: "" }), "Homeswift"),
      el("nav", { "aria-label": "Sections" }, sections.map(([hash, text]) => el("a", { href: `/${hash}`, text, class: hash === "#plugins" ? "active" : "" }))),
      el("span", { class: "spacer" }), user, logout);
    fetch("/api/auth/state", { credentials: "same-origin" }).then((response) => response.json()).then((state) => {
      user.textContent = state.username || "";
      logout.classList.toggle("hidden", state.mode !== "form");
      if (state.liveWebFiles) followWebFiles();
    }).catch(() => {});
  }

  /// Live web files (HOMESWIFT_WEB_ROOT): this page's stylesheets swap in place, its scripts and page reload,
  /// for the UI's shared files and this plugin's own.
  function followWebFiles() {
    const events = new EventSource("/api/events");
    events.addEventListener("asset", (event) => {
      const { file, kind } = JSON.parse(event.data);
      if (file.startsWith("Plugins/") && !file.startsWith(`Plugins/${platform}/`)) return;
      const name = file.split("/").pop();
      if (kind === "css") {
        for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
          const url = new URL(link.href);
          if (url.pathname.endsWith(`/${name}`)) { url.searchParams.set("v", Date.now()); link.href = url.href; }
        }
        return;
      }
      events.close();
      location.reload();
    });
  }

  const trail = el("ol", {});
  const pageTitle = document.title;
  let opened = null;   // { text, close } of a panel open on the page
  /// Shows what is open on the page as the last crumb; `close` runs when the crumb before it is clicked. null
  /// takes it away.
  function breadcrumb(text, close) {
    opened = text ? { text, close } : null;
    const crumb = (content, current) => el("li", current ? { "aria-current": "page" } : {}, content);
    const levels = [crumb(el("a", { href: "/#plugins", text: "Plugins" }))];
    const pageLevel = name !== pageTitle ? `${pageTitle} · ${name}` : pageTitle;
    levels.push(opened
      ? crumb(el("a", { href: "#", text: pageLevel, onclick: (event) => { event.preventDefault(); opened?.close?.(); } }))
      : crumb(el("span", { text: pageLevel }), true));
    if (opened) levels.push(crumb(el("span", { text: opened.text }), true));
    trail.replaceChildren(...levels);
  }
  const main = $("main");
  if (main) {
    main.prepend(el("nav", { class: "breadcrumb", "aria-label": "Breadcrumb" }, trail,
      el("a", { href: `/#settings/${encodeURIComponent(platform)}/${encodeURIComponent(name)}`, text: "Settings", title: "This plugin's block of config.json" })));
    breadcrumb(null);
  }

  window.homeswift = { platform, name, request, home: "/#plugins", $, el, assistant, explain, breadcrumb };
})();

"""#),
        "remote.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// A small TV remote for the web UI and plugin pages, after the Control Center remote: a round pad with OK in
// the middle, round keys (Back, Home, Info, Play/Pause, Mute) and a volume rocker. Each page says which
// actions its TV takes and how to send them: HomeKit's Remote Key on the Accessories page, the TV's own keys
// on a plugin's page. The pad also takes the keyboard (arrows, Enter, Backspace, Space) once focused.
(() => {
  "use strict";

  const icons = {
    up: '<path d="M6 15l6-6 6 6"/>', down: '<path d="M6 9l6 6 6-6"/>', left: '<path d="M15 6l-6 6 6 6"/>', right: '<path d="M9 6l6 6-6 6"/>',
    back: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
    home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5h.01"/>',
    playPause: '<path d="M4 6l7 6-7 6z"/><path d="M15 6v12M20 6v12"/>',
    mute: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M22 9l-6 6M16 9l6 6"/>',
    volumeUp: '<path d="M12 5v14M5 12h14"/>', volumeDown: '<path d="M5 12h14"/>',
    power: '<path d="M12 3v9"/><path d="M6.3 7.2a8 8 0 1 0 11.4 0"/>',
  };
  const labels = {
    up: "Up", down: "Down", left: "Left", right: "Right", select: "OK", back: "Back", home: "Home", info: "Info",
    playPause: "Play/Pause", mute: "Mute", volumeUp: "Volume up", volumeDown: "Volume down", power: "Power",
  };
  const keyboard = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Enter: "select", Backspace: "back", " ": "playPause" };

  function svg(name) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    node.setAttribute("viewBox", "0 0 24 24");
    node.setAttribute("aria-hidden", "true");
    node.innerHTML = icons[name];
    return node;
  }

  /// `actions`: the actions this TV takes (others are left out). `send(action)`: a promise. `disabled`: the
  /// TV cannot take keys now. `extra`: nodes for the side (a power or Ambilight button).
  function build({ actions, send, disabled = false, label = "Remote", extra = [] }) {
    const has = new Set(actions);
    const remote = document.createElement("div");
    remote.className = `mini-remote${disabled ? " is-disabled" : ""}`;
    remote.setAttribute("role", "group");
    remote.setAttribute("aria-label", label);

    // Feedback on the press, at once; the key goes on release, as a remote's does, and a press dragged off
    // the key is cancelled.
    const key = (action, className, content) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = className;
      button.title = labels[action];
      button.setAttribute("aria-label", labels[action]);
      button.disabled = disabled || !has.has(action);
      button.append(content ?? svg(action));
      button.addEventListener("click", () => fire(action, button));
      return button;
    };
    const fire = async (action, button) => {
      if (!has.has(action) || disabled) return;
      button?.classList.add("sent");
      try { await send(action); } catch { remote.classList.add("failed"); setTimeout(() => remote.classList.remove("failed"), 600); }
      setTimeout(() => button?.classList.remove("sent"), 160);
    };

    const pad = document.createElement("div");
    pad.className = "pad";
    pad.tabIndex = disabled ? -1 : 0;
    pad.setAttribute("aria-label", `${label}: arrows move, Enter selects, Backspace goes back`);
    const ok = document.createElement("span");
    ok.textContent = "OK";
    pad.append(key("up", "pad-key up"), key("left", "pad-key left"), key("select", "pad-ok", ok), key("right", "pad-key right"), key("down", "pad-key down"));
    pad.addEventListener("keydown", (event) => {
      const action = keyboard[event.key];
      if (!action || !has.has(action)) return;
      event.preventDefault();
      const button = [...pad.querySelectorAll("button")].find((b) => b.classList.contains(action) || (action === "select" && b.classList.contains("pad-ok")));
      fire(action, button ?? null);
    });

    const keys = document.createElement("div");
    keys.className = "round-keys";
    for (const action of ["back", "home", "info", "playPause"]) if (has.has(action)) keys.append(key(action, "round-key"));

    const side = document.createElement("div");
    side.className = "remote-side";
    if (has.has("volumeUp") || has.has("volumeDown")) {
      const rocker = document.createElement("div");
      rocker.className = "rocker";
      rocker.setAttribute("role", "group");
      rocker.setAttribute("aria-label", "Volume");
      rocker.append(key("volumeUp", "rocker-key"), key("volumeDown", "rocker-key"));
      side.append(rocker);
    }
    if (has.has("mute")) side.append(key("mute", "round-key"));

    remote.append(pad, keys, side);
    if (extra.length) {
      const more = document.createElement("div");
      more.className = "remote-extra";
      more.append(...extra);
      remote.append(more);
    }
    return remote;
  }

  window.HomeswiftRemote = { build, icon: svg };
})();

"""#),
        "style.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* Liquid glass over a soft, colourful backdrop, after Apple's fluid-interface guidance: materials of three
   weights (thick chrome, regular cards, thin chips) with solid controls on top, feedback on the press, type
   sized and tracked per size, and quieter variants for reduced motion, reduced transparency and more contrast. */
:root {
  color-scheme: light dark;
  --bg: #e9edf6; --bg-warm: #ffe9d6; --bg-cool: #dcefff; --bg-mint: #e2f7ee;
  --material-thick: rgba(255, 255, 255, 0.7); --material: rgba(255, 255, 255, 0.52); --material-thin: rgba(255, 255, 255, 0.38);
  --material-solid: #f7f8fb;
  --control: rgba(255, 255, 255, 0.82); --field: rgba(255, 255, 255, 0.6);
  --edge: rgba(255, 255, 255, 0.85); --edge-light: rgba(255, 255, 255, 0.6);
  --shadow-thick: 0 10px 30px rgba(25, 34, 56, 0.16); --shadow: 0 12px 36px rgba(25, 34, 56, 0.12); --shadow-control: 0 2px 8px rgba(25, 34, 56, 0.08);
  --sheen: linear-gradient(180deg, rgba(255, 255, 255, 0.45), rgba(255, 255, 255, 0) 45%);
  --text: #15171c; --muted: #596170; --line: rgba(20, 30, 50, 0.1);
  --accent: #ff7a1a; --accent-2: #ffb15c; --accent-text: #ffffff; --ok: #1f9d55; --warn: #c9731a; --error: #d0383b;
  --font: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  --mono: ui-monospace, SFMono-Regular, Menlo, monospace;
  --radius: 22px; --blur-thick: 32px; --blur: 20px;
  --ease-out: cubic-bezier(0.23, 1, 0.32, 1); --fast: 120ms; --normal: 200ms;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1218; --bg-warm: #3a2a1e; --bg-cool: #15243a; --bg-mint: #14302a;
    --material-thick: rgba(28, 31, 40, 0.74); --material: rgba(34, 38, 48, 0.54); --material-thin: rgba(255, 255, 255, 0.06);
    --material-solid: #1d2129;
    --control: rgba(70, 76, 92, 0.75); --field: rgba(0, 0, 0, 0.28);
    --edge: rgba(255, 255, 255, 0.16); --edge-light: rgba(255, 255, 255, 0.14);
    --shadow-thick: 0 10px 30px rgba(0, 0, 0, 0.5); --shadow: 0 14px 40px rgba(0, 0, 0, 0.42); --shadow-control: 0 2px 8px rgba(0, 0, 0, 0.3);
    --sheen: linear-gradient(180deg, rgba(255, 255, 255, 0.10), rgba(255, 255, 255, 0) 45%);
    --text: #f3f4f7; --muted: #a2a9b5; --line: rgba(255, 255, 255, 0.1);
    --warn: #e9a04a;
  }
}
* { box-sizing: border-box; }
html { min-height: 100%; background: var(--bg); }
body {
  margin: 0; font: 400 0.9375rem/1.45 var(--font); font-optical-sizing: auto; color: var(--text);
  -webkit-tap-highlight-color: transparent;
}
/* The backdrop is a fixed layer of its own: `background-attachment: fixed` repaints the page on every scroll
   frame under the blurred surfaces. */
body::before {
  content: ""; position: fixed; inset: 0; z-index: -1; pointer-events: none;
  background:
    radial-gradient(55% 45% at 8% 6%, var(--bg-warm) 0%, transparent 62%),
    radial-gradient(50% 42% at 92% 16%, var(--bg-cool) 0%, transparent 60%),
    radial-gradient(60% 55% at 50% 100%, var(--bg-mint) 0%, transparent 65%),
    var(--bg);
}
.hidden { display: none !important; }

/* Materials. Content scrolls under the floating header (thick); cards hold content (regular); chips and
   groups are tinted only (thin); controls are solid, since a blur on a blur loses contrast and frames. */
.card, .log, .toolbar, .banner {
  background-color: var(--material); background-image: var(--sheen);
  -webkit-backdrop-filter: blur(var(--blur)) saturate(180%); backdrop-filter: blur(var(--blur)) saturate(180%);
  border: 1px solid var(--edge); box-shadow: var(--shadow), inset 0 1px 0 var(--edge-light);
  border-radius: var(--radius);
}
header {
  position: sticky; top: 12px; z-index: 2; margin: 12px auto 0; max-width: 1100px; width: calc(100% - 24px);
  display: flex; align-items: center; gap: 14px; padding: 8px 10px 8px 20px; border-radius: 999px;
  background-color: var(--material-thick); background-image: var(--sheen);
  -webkit-backdrop-filter: blur(var(--blur-thick)) saturate(180%); backdrop-filter: blur(var(--blur-thick)) saturate(180%);
  border: 1px solid var(--edge); box-shadow: var(--shadow-thick), inset 0 1px 0 var(--edge-light);
}
.card .toolbar { -webkit-backdrop-filter: none; backdrop-filter: none; background: var(--material-thin); box-shadow: none; }
.brand { display: inline-flex; align-items: center; gap: 10px; font-weight: 700; letter-spacing: -0.01em; color: var(--text); text-decoration: none; }
.logo { width: 36px; height: 36px; border-radius: 10px; box-shadow: 0 2px 8px rgba(255, 122, 26, 0.35); }
.logo.large { width: 72px; height: 72px; border-radius: 18px; margin-bottom: 4px; }
nav { display: flex; gap: 2px; }
nav a {
  color: var(--text); text-decoration: none; padding: 7px 14px; border-radius: 999px; touch-action: manipulation;
  transition: background-color var(--fast) var(--ease-out), transform var(--fast) var(--ease-out);
}
nav a:hover { background-color: var(--material-thin); }
nav a:active { transform: scale(0.96); }
nav a.active { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); box-shadow: 0 6px 16px rgba(255, 122, 26, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.5); }
.spacer { flex: 1; }
#user { color: var(--muted); text-decoration: none; padding: 6px 10px; border-radius: 999px; }
#user:hover { color: var(--text); background: var(--material-thin); }
/* A plugin's settings page: the form in a card, a save bar that floats at the bottom of the window while the
   form scrolls (a thick material, like the header), and removal set apart at the end. */
.settings-head { align-items: center; }
.settings-head .tools { margin-left: auto; }
.form-card { margin: 0; }
.page-note { display: flex; align-items: center; gap: 14px; justify-content: space-between; margin: 0 0 14px; padding: 12px 16px 12px 18px; }
.page-note p { margin: 0; font-size: 0.875rem; }
.page-note .button, .danger-zone button { flex: none; white-space: nowrap; }
.settings-bar {
  position: sticky; bottom: 14px; z-index: 3; display: flex; align-items: center; gap: 10px; margin: 14px 0 0;
  padding: 8px 8px 8px 20px; border-radius: 999px;
  background-color: var(--material-thick); background-image: var(--sheen);
  -webkit-backdrop-filter: blur(var(--blur-thick)) saturate(180%); backdrop-filter: blur(var(--blur-thick)) saturate(180%);
  border: 1px solid var(--edge); box-shadow: var(--shadow-thick), inset 0 1px 0 var(--edge-light);
}
.settings-bar > span:first-child { flex: 1; min-width: 0; font-size: 0.875rem; }
.settings-bar > .dirty, .save-bar > .dirty { color: var(--warn); font-weight: 500; }
.danger-zone { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin: 32px 0 0; }
.danger-zone p { margin: 4px 0 0; font-size: 0.875rem; }
button.danger { color: var(--error); border-color: rgba(208, 56, 59, 0.35); }
button.danger:hover:not(:disabled) { background: rgba(208, 56, 59, 0.08); }

/* Forms stay calm: list entries (lights, TVs) are rows that open to edit, and options left unset wait under
   "More options". */
details.entry { border: 1px solid var(--line); border-radius: 16px; margin: 8px 0; background: var(--material-thin); }
details.entry > summary { display: flex; align-items: center; gap: 10px; padding: 10px 14px; list-style: none; color: var(--text); }
details.entry > summary::-webkit-details-marker { display: none; }
details.entry > summary::before { content: "›"; color: var(--muted); transition: transform var(--fast) var(--ease-out); }
details.entry[open] > summary::before { transform: rotate(90deg); }
details.entry > summary .entry-name { font-weight: 600; }
details.entry > summary .entry-detail { color: var(--muted); font-size: 0.8125rem; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
details.entry > .fields, details.entry > .entry-body { padding: 0 14px 12px; }
details.more-options { margin: 10px 0 2px; }
details.more-options > summary { font-size: 0.8125rem; color: var(--accent); font-weight: 500; padding: 6px 0; }
details.more-options[open] > summary { margin-bottom: 4px; }

/* The password gauge: the ANSSI's bands along 0 to 128 bits, the 80-bit bar marked; the fill eases to its
   width as you type and takes the band's colour. */
.gauge { margin-top: 10px; }
.gauge-track { position: relative; height: 8px; border-radius: 4px; background: var(--material-thin); border: 1px solid var(--line); overflow: visible; }
.gauge-fill { position: absolute; inset: 0 auto 0 0; width: 0; border-radius: 4px; background: var(--error); transition: width var(--normal) var(--ease-out), background-color var(--normal) var(--ease-out); }
.gauge[data-level="lowToMedium"] .gauge-fill { background: var(--warn); }
.gauge[data-level="mediumToStrong"] .gauge-fill { background: #37b26c; }
.gauge[data-level="strongToVeryStrong"] .gauge-fill { background: var(--ok); }
.gauge-tick { position: absolute; top: 1px; bottom: 1px; width: 1px; background: var(--line); }
.gauge-mark { position: absolute; top: -4px; bottom: -4px; width: 2px; margin-left: -1px; border-radius: 1px; background: var(--text); opacity: 0.55; }
.gauge-legend { display: flex; justify-content: space-between; gap: 10px; margin-top: 6px; font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.gauge[data-level="veryWeak"] .gauge-legend strong { color: var(--error); }
.gauge[data-level="lowToMedium"] .gauge-legend strong { color: var(--warn); }
.gauge[data-level="mediumToStrong"] .gauge-legend strong, .gauge[data-level="strongToVeryStrong"] .gauge-legend strong { color: var(--ok); }
.gauge-rules { list-style: none; margin: 8px 0 0; padding: 0; display: grid; gap: 3px; font-size: 0.8125rem; color: var(--muted); }
.gauge-rules li::before { content: "○"; display: inline-block; width: 1.3em; }
.gauge-rules li.met { color: var(--ok); }
.gauge-rules li.met::before { content: "✓"; }
.gauge-hint { margin: 6px 0 0; min-height: 1em; }
@media (prefers-reduced-motion: reduce) { .gauge-fill { transition: none; } }
.account { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 14px; align-items: start; }
.account .card { margin: 0; }
.account h2 { margin-top: 0; }
.account-form .field { max-width: 420px; }
@media (max-width: 640px) { .account { grid-template-columns: 1fr; } }
main { max-width: 1100px; margin: 0 auto; padding: 22px 12px 40px; }

/* Type: the system font with its optical sizes, sizes in rem so the reader's text size applies, tracking
   and leading per size (tight and negative when large, a little wider when small), hierarchy by weight. */
h1 { font-size: 1.625rem; line-height: 1.15; letter-spacing: -0.02em; font-weight: 700; margin: 6px 0 16px; }
h2 { font-size: 1.0625rem; line-height: 1.25; letter-spacing: -0.01em; font-weight: 600; margin: 24px 0 10px; }
strong { font-weight: 600; }
.help, .pill, dt, legend, .log { letter-spacing: 0.01em; }
.card { padding: 18px 20px; margin-bottom: 14px; }
.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 14px; }
.cards .card { margin: 0; }
.muted { color: var(--muted); }
.row { display: flex; align-items: center; gap: 12px; justify-content: space-between; padding: 8px 0; border-top: 1px solid var(--line); }
.row:first-of-type { border-top: 0; }
.row .name { flex: 1; }
.value { font-variant-numeric: tabular-nums; color: var(--muted); min-width: 52px; text-align: right; }

/* Controls: feedback on the press, at once, and a focus ring for the keyboard. */
button, a.button {
  font: inherit; font-weight: 500; padding: 8px 16px; border-radius: 999px; cursor: pointer; color: var(--text); touch-action: manipulation;
  background: var(--control); border: 1px solid var(--edge); box-shadow: inset 0 1px 0 var(--edge-light), var(--shadow-control);
  transition: transform var(--fast) var(--ease-out), box-shadow var(--fast) var(--ease-out), opacity var(--fast) var(--ease-out);
}
a.button { display: inline-block; text-decoration: none; line-height: normal; }
button:hover, a.button:hover { transform: translateY(-1px); }
button:active:not(:disabled), a.button:active { transform: scale(0.97); transition-duration: 80ms; }
button.primary { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: rgba(255, 255, 255, 0.4); box-shadow: 0 8px 20px rgba(255, 122, 26, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.5); }
button.link { border: 0; background: none; box-shadow: none; color: var(--accent); padding: 4px 6px; }
button.link:hover { transform: none; }
button.link:active:not(:disabled) { transform: none; opacity: 0.6; }
button:disabled { opacity: .5; cursor: default; transform: none; }
button:focus-visible, nav a:focus-visible, summary:focus-visible, .switch input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }
input, select, textarea {
  font: inherit; color: var(--text); width: 100%; padding: 8px 12px; border-radius: 14px;
  background: var(--field); border: 1px solid var(--edge); box-shadow: inset 0 1px 2px rgba(25, 34, 56, 0.08);
  transition: border-color var(--fast) var(--ease-out), box-shadow var(--fast) var(--ease-out);
}
input:focus, select:focus, textarea:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 4px rgba(255, 122, 26, 0.18); }
input[type=checkbox] { width: auto; box-shadow: none; accent-color: var(--accent); }
input[type=range] { padding: 0; width: 160px; background: none; border: 0; box-shadow: none; accent-color: var(--accent); }
select { touch-action: manipulation; }
textarea { font-family: var(--mono); font-size: 0.8125rem; min-height: 420px; white-space: pre; border-radius: var(--radius); }
label { display: block; margin: 10px 0 6px; }
label > input, label > select { margin-top: 5px; }
.help { font-size: 0.8125rem; color: var(--muted); margin: 3px 0 0; }
.error { color: var(--error); min-height: 1.2em; }
.ok { color: var(--ok); }
.pill { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 0.75rem; font-weight: 500; border: 1px solid var(--edge); background: var(--material-thin); color: var(--muted); vertical-align: middle; }
.pill.on { color: var(--ok); border-color: rgba(31, 157, 85, 0.4); }
.pill.status { white-space: nowrap; display: inline-flex; align-items: center; gap: 6px; flex: none; }
.pill.status::before { content: ""; width: 7px; height: 7px; border-radius: 50%; background: currentColor; }
.pill.status.standby { color: var(--muted); }
.pill.status.away { color: var(--warn); border-color: rgba(201, 115, 26, 0.35); }

/* Tiles: an icon on a solid colour per kind of thing, like the Home app's: the bridge in the accent, child
   bridges violet, accessories of their own (televisions) blue, the machine grey. */
.tile {
  width: 40px; height: 40px; flex: none; border-radius: 12px; display: flex; align-items: center; justify-content: center; color: #fff;
  background: linear-gradient(160deg, var(--accent-2), var(--accent)); box-shadow: 0 6px 16px rgba(25, 34, 56, 0.18), inset 0 1px 0 rgba(255, 255, 255, 0.4);
}
/* A block of fixed size, centred by flexbox: Safari left an inline SVG at the top of a grid cell. */
.tile svg { display: block; flex: none; width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.tile.large { width: 48px; height: 48px; border-radius: 14px; }
.tile.large svg { width: 26px; height: 26px; }
.tile.child { background: linear-gradient(160deg, #a78bfa, #7c4ddb); }
.tile.accessory { background: linear-gradient(160deg, #4aa3ff, #1f6fe0); }
.tile.system { background: linear-gradient(160deg, #9aa3b2, #687284); }
.tile.light { background: linear-gradient(160deg, #ffd66b, #f0a01e); color: #5c3b00; }
.tile.sensor { background: linear-gradient(160deg, #4fd1c5, #1c9c91); }
.tile.switch { background: linear-gradient(160deg, #6ee7a0, #23a55a); }

/* Breadcrumb, on plugin pages: where the page sits, each level a way back. */
.breadcrumb { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 2px 0 10px; }
.breadcrumb > a { font-size: 0.8125rem; color: var(--accent); text-decoration: none; font-weight: 500; }
.breadcrumb > a:hover { text-decoration: underline; }
.breadcrumb ol { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; align-items: center; gap: 6px; font-size: 0.8125rem; color: var(--muted); }
.breadcrumb li { display: inline-flex; align-items: center; gap: 6px; min-width: 0; }
.breadcrumb li + li::before { content: "›"; color: var(--muted); }
.breadcrumb a { color: var(--accent); text-decoration: none; font-weight: 500; }
.breadcrumb a:hover { text-decoration: underline; }
.breadcrumb [aria-current] span { color: var(--text); font-weight: 500; }

/* Page heads: the title, one line on what the page is for, and the page's tools on the right. */
.page-head { display: flex; align-items: flex-end; gap: 16px; margin: 6px 0 20px; flex-wrap: wrap; }
.page-head h1 { margin: 0; }
.page-head p { margin: 4px 0 0; max-width: 62ch; }
.page-head .tools { display: flex; gap: 10px; align-items: center; }
.section-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin: 26px 0 10px; }
.section-head h2 { margin: 0; }
.section-head .muted { font-size: 0.8125rem; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr)); gap: 14px; }
.grid > .card { margin: 0; }
.card.empty { text-align: center; padding: 28px 20px; }
.card.empty p { margin: 0; }
.card.notice { color: var(--warn); font-weight: 500; }
.card.notice p { margin: 0; }
.search { width: 240px; max-width: 100%; }
input[type=search] { -webkit-appearance: none; appearance: none; }
.note { margin: 0; font-size: 0.8125rem; }
.spacer { flex: 1; }
.link.danger { color: var(--error); }
/* The Assistant, after Apple Intelligence: the sparkle and its colours, a glow that turns around the card while
   it thinks, then a glass card with a thin rainbow edge and the answer typeset. Reduced motion keeps the colours
   still; reduced transparency makes the card solid. */
@property --ai-angle { syntax: "<angle>"; inherits: false; initial-value: 0deg; }
:root { --ai-colors: #ff9f0a, #ff375f, #bf5af2, #5e5ce6, #64d2ff, #ff9f0a; }
.explain { margin-top: 8px; }
.sparkle { width: 16px; height: 16px; flex: none; display: block; }
.ai-button { display: inline-flex; align-items: center; gap: 6px; padding: 6px 14px 6px 11px; }
.ai-button span {
  font-weight: 600; background: linear-gradient(90deg, #ff9f0a, #ff375f 35%, #bf5af2 70%, #5e5ce6);
  -webkit-background-clip: text; background-clip: text; color: transparent;
}
.ai-card {
  position: relative; isolation: isolate; margin-top: 4px; padding: 1.5px; border-radius: 20px;
  background: conic-gradient(from var(--ai-angle), var(--ai-colors));
  animation: materialize var(--normal) var(--ease-out);
}
/* The glow: the same colours, blurred, behind the card; it turns while the Assistant thinks and fades after. */
.ai-card::before {
  content: ""; position: absolute; inset: -4px; z-index: -1; border-radius: 24px;
  background: conic-gradient(from var(--ai-angle), var(--ai-colors)); filter: blur(14px);
  opacity: 0; transition: opacity 600ms var(--ease-out);
}
.ai-card.thinking, .ai-card.thinking::before { animation: ai-turn 3s linear infinite; }
.ai-card.thinking::before { opacity: 0.55; }
.ai-card.answered { background: conic-gradient(from 210deg, var(--ai-colors)); }
.ai-card.failed { background: linear-gradient(var(--line), var(--line)); }
@keyframes ai-turn { to { --ai-angle: 360deg; } }
.ai-inner {
  border-radius: 18.5px; padding: 14px 18px 12px; background: var(--material-solid);
  background-image: linear-gradient(160deg, rgba(255, 159, 10, 0.06), rgba(191, 90, 242, 0.06) 60%, rgba(100, 210, 255, 0.05));
}
.ai-head { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; font-size: 0.8125rem; color: var(--muted); }
.ai-label { font-weight: 600; letter-spacing: 0.01em; }
.ai-close { padding: 0; width: 26px; height: 26px; display: grid; place-items: center; font-size: 1rem; line-height: 1; border-radius: 50%; }
.ai-thinking {
  margin: 4px 0 6px; font-weight: 500; background: linear-gradient(90deg, var(--muted) 20%, var(--text) 50%, var(--muted) 80%);
  background-size: 250% 100%; -webkit-background-clip: text; background-clip: text; color: transparent; animation: ai-shimmer 1.8s linear infinite;
}
@keyframes ai-shimmer { from { background-position: 100% 0; } to { background-position: -150% 0; } }
.ai-body { font-size: 0.9375rem; line-height: 1.55; animation: fade var(--normal) var(--ease-out); }
.ai-body.clamped { max-height: 15em; overflow: hidden; -webkit-mask-image: linear-gradient(#000 65%, transparent); mask-image: linear-gradient(#000 65%, transparent); }
.ai-more { padding: 6px 0 2px; font-weight: 500; }
.md > :first-child { margin-top: 0; }
.md h3 { font-size: 1rem; letter-spacing: -0.01em; margin: 14px 0 4px; }
.md h4 { font-size: 0.9375rem; margin: 12px 0 2px; color: var(--muted); font-weight: 600; }
.md p { margin: 6px 0; }
.md ul, .md ol { margin: 6px 0; padding-left: 1.3em; }
.md li { margin: 4px 0; }
.md li::marker { color: var(--muted); }
.md strong { font-weight: 600; }
.md code { font-family: var(--mono); font-size: 0.85em; padding: 1px 6px; border-radius: 6px; background: var(--material-thin); border: 1px solid var(--line); overflow-wrap: anywhere; }
.md pre { margin: 8px 0; padding: 10px 12px; border-radius: 12px; background: var(--material-thin); border: 1px solid var(--line); overflow: auto; }
.md pre code { padding: 0; border: 0; background: none; }
.md a { color: var(--accent); }
@media (prefers-reduced-motion: reduce) {
  .ai-card.thinking, .ai-card.thinking::before, .ai-thinking, .ai-body { animation: none; }
  .ai-thinking { color: var(--muted); background: none; }
}
@media (prefers-reduced-transparency: reduce) { .ai-card::before { display: none; } .ai-inner { background-image: none; } }

/* A group of buttons in one pill (a segmented control); `.on` marks the chosen one. */
.group {
  display: inline-flex; gap: 2px; padding: 3px; border-radius: 999px; flex: none;
  background: var(--control); border: 1px solid var(--edge); box-shadow: inset 0 1px 0 var(--edge-light), var(--shadow-control);
}
.group button { border: 0; background: none; box-shadow: none; padding: 5px 13px; white-space: nowrap; transition: background-color var(--fast) var(--ease-out), transform var(--fast) var(--ease-out); }
.group button:hover:not(:disabled) { transform: none; }
.group button:hover:not(:disabled):not(.on) { background: var(--material-thin); }
.group button.on { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); }

/* The mini remote (remote.js): a round pad with OK in the middle, round keys and a volume rocker. Keys give
   way under the press at once and the one that sent flashes the accent; a TV that cannot take keys dims it. */
.mini-remote { display: grid; grid-template-columns: auto auto auto; align-items: center; justify-content: start; gap: 14px; }
.mini-remote svg { display: block; width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.mini-remote button { touch-action: manipulation; transition: transform var(--fast) var(--ease-out), color var(--fast) var(--ease-out), background-color var(--fast) var(--ease-out); }
.mini-remote button:hover:not(:disabled) { transform: none; }
.mini-remote button:active:not(:disabled) { transform: scale(0.9); transition-duration: 60ms; }
.mini-remote button.sent { color: var(--accent); }
.mini-remote.is-disabled .pad, .mini-remote.is-disabled .round-keys, .mini-remote.is-disabled .remote-side { opacity: 0.45; }
.pad {
  width: 124px; height: 124px; border-radius: 50%; display: grid; grid-template: repeat(3, 1fr) / repeat(3, 1fr);
  background: var(--control); border: 1px solid var(--edge); box-shadow: inset 0 1px 0 var(--edge-light), var(--shadow-control);
  transition: border-color var(--normal) var(--ease-out);
}
.pad:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
.mini-remote.failed .pad { border-color: var(--error); }
.pad-key { border: 0; background: none; box-shadow: none; padding: 0; border-radius: 12px; display: grid; place-items: center; color: var(--muted); }
.pad-key:hover:not(:disabled) { color: var(--text); }
.pad-key.up { grid-area: 1 / 2; } .pad-key.left { grid-area: 2 / 1; } .pad-key.right { grid-area: 2 / 3; } .pad-key.down { grid-area: 3 / 2; }
.pad-ok {
  grid-area: 2 / 2; place-self: center; width: 48px; height: 48px; padding: 0; border-radius: 50%; display: grid; place-items: center;
  font-size: 0.8125rem; font-weight: 600; letter-spacing: 0.02em; background: var(--material-solid); border: 1px solid var(--edge);
  box-shadow: 0 2px 6px rgba(25, 34, 56, 0.12), inset 0 1px 0 var(--edge-light);
}
.round-keys { display: grid; grid-template-columns: repeat(2, 42px); gap: 8px; }
.round-key { width: 42px; height: 42px; padding: 0; border-radius: 50%; display: grid; place-items: center; }
.remote-side { display: flex; flex-direction: column; align-items: center; gap: 10px; }
.rocker {
  display: flex; flex-direction: column; border-radius: 22px; overflow: hidden;
  background: var(--control); border: 1px solid var(--edge); box-shadow: inset 0 1px 0 var(--edge-light), var(--shadow-control);
}
.rocker-key { width: 42px; height: 44px; padding: 0; border: 0; border-radius: 0; background: none; box-shadow: none; display: grid; place-items: center; }
.rocker-key + .rocker-key { border-top: 1px solid var(--line); }
/* Only a remote with side buttons gets the row for them, so a card without any keeps no empty gap. */
.remote-extra { grid-column: 1 / -1; display: flex; gap: 10px; flex-wrap: wrap; }
@media (prefers-reduced-motion: reduce) { .mini-remote button:active:not(:disabled) { transform: none; opacity: 0.7; } }
@media (max-width: 400px) { .pad { width: 112px; height: 112px; } .mini-remote { gap: 10px; } }

/* Accessories: a card per accessory, its power in the header, readable rows below. */
.accessory-card { display: grid; gap: 10px; align-content: start; }
.controls { display: grid; }
.control { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-height: 42px; padding: 4px 0; border-top: 1px solid var(--line); }
.controls > .control:first-child, .service-name + .control { border-top: 0; }
.control > span:first-child { color: var(--muted); flex: none; }
.control select, .control input[type=text] { width: auto; max-width: 62%; }
.control .range { flex: 1; justify-content: flex-end; min-width: 0; }
.control input[type=range] { flex: 1 1 auto; width: auto; min-width: 60px; max-width: 190px; }
.control .value { white-space: nowrap; }
.control .range .value { flex: none; min-width: 3.6em; text-align: right; }
.keys { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; }
.keys button { padding: 5px 11px; font-size: 0.8125rem; }
.more > summary { font-size: 0.8125rem; padding: 4px 0; }
.service-name { font-size: 0.75rem; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted); margin: 12px 0 2px; }
.card-remote { padding: 8px 0 2px; display: flex; justify-content: center; }
.card-foot { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding-top: 10px; border-top: 1px solid var(--line); font-size: 0.8125rem; }
.card-foot .link { padding: 0; font-size: inherit; }
.bridge-section + .bridge-section { margin-top: 8px; }

/* Plugins: a card per block; the settings form opens across the grid. */
.server .actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.server.editor { grid-column: 1 / -1; gap: 18px; }
.form-body { display: grid; gap: 4px; }
.fields { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 280px), 1fr)); gap: 4px 18px; align-items: start; }
.fields > fieldset, .fields > .group-box { grid-column: 1 / -1; }
.field { margin: 10px 0 4px; }
.field-title { display: block; font-weight: 500; margin-bottom: 6px; }
.field > input, .field > select { margin-top: 0; }
.toggle { display: flex; align-items: flex-start; gap: 12px; margin: 14px 0 6px; cursor: pointer; }
.toggle .field-title { margin: 3px 0 2px; }
.toggle.compact { align-items: center; margin: 0; gap: 8px; }
.group-box { border: 1px solid var(--line); border-radius: 18px; padding: 4px 16px 12px; margin: 12px 0; background: var(--material-thin); }
.group-box > summary { font-weight: 600; color: var(--text); padding: 10px 0 6px; }
.item .item-head strong { font-weight: 600; }
textarea.short { min-height: 220px; }
.save-bar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; padding-top: 14px; border-top: 1px solid var(--line); }
.save-bar > span:first-child { flex: 1; font-size: 0.8125rem; }
.status-line { margin: 12px 0 0; min-height: 1.2em; font-size: 0.875rem; }

/* Config and logs: a toolbar on top of the content, inside one card. */
.editor-card, .log-card { padding: 0; overflow: hidden; }
.editor-bar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; padding: 12px 16px; border-bottom: 1px solid var(--line); background: var(--material-thin); }
.editor-bar .search { width: 220px; }
.editor-bar .count { font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.editor-card textarea { display: block; border: 0; border-radius: 0; box-shadow: none; background: transparent; min-height: 62vh; padding: 16px 18px; resize: vertical; tab-size: 2; line-height: 1.55; }
.editor-card textarea:focus { box-shadow: none; }
.editor-card .status-line { padding: 0 18px 14px; margin: 0; }

/* Facts: label over value in thin chips, three to a row; long values end in an ellipsis with the whole
   value in the tooltip. */
.facts { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; }
.fact { padding: 8px 12px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); min-width: 0; }
.fact span { display: block; font-size: 0.75rem; color: var(--muted); letter-spacing: 0.01em; }
.fact b { display: block; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.fact.wide { grid-column: 1 / -1; }
.facts.lead { grid-template-columns: minmax(0, 2fr) repeat(2, minmax(0, 1fr)); }
.mono { font-family: var(--mono); font-size: 0.8125rem; letter-spacing: 0; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { padding: 3px 10px; border-radius: 999px; font-size: 0.8125rem; background: var(--material-thin); border: 1px solid var(--line); }

/* Status: a summary that says whether all is well, the numbers that matter, then a card per server. */
.hero { display: flex; align-items: center; gap: 16px; padding: 20px 22px; }
.hero .logo.large { margin: 0; }
.hero h1 { margin: 0 0 2px; }
.hero p { margin: 0; }
.who { flex: 1; min-width: 0; }
.health { font-weight: 500; display: flex; align-items: center; gap: 8px; }
.health::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: currentColor; flex: none; }
.health.on { color: var(--ok); }
.health.away { color: var(--warn); }
.stats { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin: 0 0 6px; }
.stat {
  padding: 14px 16px; border-radius: 18px; background: var(--material); border: 1px solid var(--edge);
  box-shadow: var(--shadow-control), inset 0 1px 0 var(--edge-light);
}
.stat b { display: block; font-size: 1.5rem; line-height: 1.1; letter-spacing: -0.02em; font-weight: 650; font-variant-numeric: tabular-nums; }
.stat span { color: var(--muted); font-size: 0.8125rem; letter-spacing: 0.01em; }
.servers { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 420px), 1fr)); gap: 14px; }
.server { margin: 0; display: grid; gap: 14px; align-content: start; }
.servers .server, .card.server { animation: materialize var(--normal) var(--ease-out); }
.server-head { display: flex; align-items: center; gap: 12px; min-width: 0; }
.server-head strong { display: block; font-size: 1.0625rem; letter-spacing: -0.01em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.server-head .muted { font-size: 0.8125rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.setup { display: flex; gap: 16px; align-items: center; padding-top: 14px; border-top: 1px solid var(--line); }
.setup p { margin: 0 0 6px; }
.setup .code { margin: 0; }
.server .actions { margin-top: 0; }
.banner { margin: 14px auto 0; max-width: 1100px; width: calc(100% - 24px); padding: 10px 20px; text-align: center; color: var(--warn); font-weight: 600; animation: materialize var(--normal) var(--ease-out); }
.auth { min-height: 100vh; min-height: 100dvh; display: grid; place-items: center; padding: 20px; }
.auth .card { width: min(400px, 100%); padding: 26px 26px 22px; animation: materialize 320ms var(--ease-out); }
.auth h1 { margin-top: 6px; }
.auth button { width: 100%; margin-top: 10px; }
.pairing { display: flex; gap: 18px; align-items: center; flex-wrap: wrap; margin: 10px 0; }
.qr { width: 148px; height: 148px; border-radius: 14px; background: #fff; padding: 6px; box-shadow: var(--shadow-control); }
.pairing .code { margin-top: 0; }
.code { font-family: var(--mono); font-size: 1.875rem; letter-spacing: 0.1em; font-variant-numeric: tabular-nums; margin: 10px 0; padding: 10px 16px; border-radius: 16px; display: inline-block; background: var(--material-thin); border: 1px solid var(--edge); box-shadow: inset 0 1px 0 var(--edge-light); }

/* A glass surface arrives as a material: blur and scale settle together, not a plain fade. */
@keyframes materialize {
  from { opacity: 0; transform: scale(0.97); filter: blur(8px); }
  to { opacity: 1; transform: none; filter: none; }
}
@keyframes fade { from { opacity: 0; } }

/* Switch: the knob slides with a strong ease-out and no overshoot (a tap carries no momentum) and widens
   while pressed, the way a real one gives under the finger. */
.switch { position: relative; width: 48px; height: 28px; margin: 0; flex: none; touch-action: manipulation; }
.switch input { opacity: 0; width: 0; height: 0; }
.switch span {
  position: absolute; inset: 0; border-radius: 14px; background-color: rgba(120, 128, 142, 0.35); border: 1px solid var(--edge);
  box-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.15); transition: background-color var(--normal) var(--ease-out), box-shadow var(--normal) var(--ease-out);
}
.switch span::before {
  content: ""; position: absolute; width: 22px; height: 22px; left: 2px; top: 2px; border-radius: 50%;
  background: linear-gradient(180deg, #fff, #eef0f4); box-shadow: 0 2px 6px rgba(0, 0, 0, 0.25);
  transition: transform var(--normal) var(--ease-out), width var(--fast) var(--ease-out);
}
.switch input:checked + span { background-color: var(--accent); box-shadow: 0 4px 12px rgba(255, 122, 26, 0.4), inset 0 1px 0 rgba(255, 255, 255, 0.35); }
.switch input:checked + span::before { transform: translateX(20px); }
.switch input:active + span::before { width: 26px; }
.switch input:checked:active + span::before { transform: translateX(16px); }
.range { display: inline-flex; align-items: center; gap: 10px; }

/* Log: a row per line, its time and source in columns, warnings and errors tinted. */
.log { font-size: 0.8125rem; line-height: 1.45; padding: 6px 0; height: calc(100vh - 290px); min-height: 320px; overflow: auto; overscroll-behavior: contain; }
.log-line { display: grid; grid-template-columns: auto minmax(0, 11em) minmax(0, 1fr); gap: 12px; padding: 3px 16px; align-items: baseline; }
.log-line:hover { background: var(--material-thin); }
.log-line time { font-family: var(--mono); font-size: 0.75rem; color: var(--muted); font-variant-numeric: tabular-nums; }
.log-line .label { color: var(--muted); font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.log-line .text { overflow-wrap: anywhere; white-space: pre-wrap; }
.log-line.warning { background: rgba(201, 115, 26, 0.08); }
.log-line.warning .text { color: var(--warn); }
.log-line.error, .log-line.critical { background: rgba(208, 56, 59, 0.08); }
.log-line.error .text, .log-line.critical .text { color: var(--error); }
.log-line.debug .text, .log-line.trace .text { color: var(--muted); }
.empty-log { padding: 20px; text-align: center; }
.toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-bottom: 14px; padding: 10px 14px; border-radius: 999px; }
.toolbar input, .toolbar select { width: auto; }
.toolbar label { margin: 0; display: inline-flex; align-items: center; gap: 6px; }

/* Forms */
fieldset { border: 1px solid var(--line); border-radius: 18px; padding: 8px 16px 14px; margin: 14px 0; background: var(--material-thin); }
legend { color: var(--muted); padding: 0 8px; font-weight: 500; }
.item { border: 1px solid var(--line); border-radius: 16px; padding: 6px 14px 12px; margin: 10px 0; background: var(--material-thin); }
.item-head { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
.actions { display: flex; gap: 10px; margin-top: 16px; align-items: center; }
details > summary { cursor: pointer; color: var(--muted); padding: 8px 0; touch-action: manipulation; }
dl { display: grid; grid-template-columns: max-content 1fr; gap: 5px 16px; margin: 0; }
dt { color: var(--muted); font-weight: 500; }
dd { margin: 0; }

/* Preferences. Reduced motion keeps fades and colour changes, which aid comprehension, and drops what
   moves, scales or blurs in. Reduced transparency makes the frosted surfaces solid. More contrast gives
   them a defined edge and lifts the secondary text. */
@media (prefers-reduced-motion: reduce) {
  .banner, .auth .card { animation: fade var(--normal) ease; }
  button, nav a { transition-property: background-color, box-shadow, opacity; }
  button:hover, button:active:not(:disabled), a.button:hover, a.button:active, nav a:active { transform: none; }
  button:active:not(:disabled) { opacity: 0.7; }
  .switch span::before { transition: none; }
  .switch input:active + span::before { width: 22px; }
  .switch input:checked:active + span::before { transform: translateX(20px); }
}
@media (prefers-reduced-transparency: reduce) {
  :root { --material: var(--material-solid); --material-thick: var(--material-solid); --material-thin: var(--field); --sheen: none; }
  .card, header, .log, .toolbar, .banner { -webkit-backdrop-filter: none; backdrop-filter: none; }
}
@media (prefers-contrast: more) {
  :root { --material: var(--material-solid); --material-thick: var(--material-solid); --sheen: none; --edge: rgba(20, 30, 50, 0.55); --line: rgba(20, 30, 50, 0.3); --muted: #3a4150; }
  @media (prefers-color-scheme: dark) { :root { --edge: rgba(255, 255, 255, 0.6); --line: rgba(255, 255, 255, 0.3); --muted: #cfd4dc; } }
  .card, header, .log, .toolbar, .banner { -webkit-backdrop-filter: none; backdrop-filter: none; }
  button, input, select, textarea, .pill { border-color: var(--edge); }
}
@media (max-width: 640px) {
  /* The header stays one line: the brand keeps its icon, the links scroll sideways. */
  header { flex-wrap: nowrap; }
  header .brand { font-size: 0; gap: 0; }
  header nav { flex: 1 1 auto; min-width: 0; overflow-x: auto; scrollbar-width: none; }
  header nav::-webkit-scrollbar { display: none; }
  header .spacer { display: none; }
  #user { padding: 6px 8px; max-width: 7em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .page-head .tools, .page-head .search, .editor-bar .search { width: 100%; }
  .log-line { grid-template-columns: auto minmax(0, 1fr); }
  .log-line .label { display: none; }
  .facts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .setup { flex-direction: column; align-items: flex-start; }
}
@media (prefers-reduced-motion: reduce) { .servers .server, .card.server { animation: fade var(--normal) ease; } }
@media (max-width: 640px) { header { gap: 6px; padding: 6px 8px; } nav a { padding: 6px 10px; white-space: nowrap; } main { padding: 14px 10px 30px; } input[type=range] { width: 110px; } }

"""#),
    ]
}
