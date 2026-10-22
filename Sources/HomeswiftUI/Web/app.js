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
