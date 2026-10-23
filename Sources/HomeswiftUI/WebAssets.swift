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

  // /status?since=24h&bridge=<bridge>&accessory=<accessory>: the activity charts' range and whose durations they show,
  // as on the Logs page.
  views.status = async (main) => {
    const [status, accessories] = await Promise.all([
      api("/api/status"),
      api("/api/accessories").then((list) => withSlugs(list, "accessory")).catch(() => []),
    ]);
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
      activity(accessories, withSlugs(status.bridges, "bridge")),
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

  /// The Status page's charts: the process's memory and CPU, and how long the Home app's requests and the plugins'
  /// calls to their devices take, over the range and for the bridge or accessory the filters above them choose (the
  /// Logs page's). A range that ends now refreshes every minute; while new data loads the charts stay, faded.
  function activity(accessories, bridges) {
    const params = new URLSearchParams(location.search);
    const range = rangeFilter(params, { changed: () => load() });
    const sources = sourceFilter(accessories, bridges, initialSource(accessories, bridges, params.get("accessory"), params.get("bridge")), {
      label: "Whose requests", everything: "All servers", changed: () => load() });
    const byID = new Map(accessories.map((accessory) => [accessory.id, accessory]));
    const durations = (key) => [
      { label: "Average", tone: 1, value: (point) => point[key]?.average ?? null },
      { label: "Longest", tone: 2, value: (point) => point[key]?.longest ?? null },
    ];
    const charts = [
      { title: "Memory", note: "The homeswift process, at its highest in each point", series: [{ label: "Memory", tone: 1, value: (point) => point.memory }], format: formatBytes,
        unit: (max) => 1024 ** (max >= 1024 ** 3 ? 3 : 2) },
      { title: "CPU", note: "The homeswift process; 100% is one core busy", series: [{ label: "CPU", tone: 1, value: (point) => point.cpu }], format: formatPercent },
      { title: "Home app requests", note: "How long the bridge takes to answer reads and writes", series: durations("requests"), format: formatMilliseconds, key: "requests" },
      { title: "Plugin device calls", note: "How long plugins take to reach their devices or clouds", series: durations("handlers"), format: formatMilliseconds, key: "handlers" },
    ].map((chart) => {
      const figure = el("b", { class: "chart-figure" });
      const detail = el("div", { class: "muted chart-detail" });
      const body = el("div", { class: "chart-body" });
      const card = el("div", { class: "card chart-card" },
        el("div", { class: "chart-head" }, el("div", { class: "who" }, el("strong", { text: chart.title }), el("div", { class: "muted", text: chart.note })), figure),
        body, detail);
      return { ...chart, card, figure, detail, body, view: null };
    });
    const table = el("details", { class: "more chart-table" }, el("summary", { text: "Show as a table" }));
    table.addEventListener("toggle", () => { if (table.open) fillTable(); });
    const section = el("section", { class: "activity" },
      el("h2", { text: "Activity" }),
      el("div", { class: "filter-bar" }, range.picker, sources.picker, range.customRow),
      el("div", { class: "chart-grid" }, charts.map((chart) => chart.card)),
      table);
    let shown = null;   // the last history loaded, for the table
    let refresh = null;

    function keepAddress() {
      const query = new URLSearchParams();
      range.address(query);
      const { kind, value } = sources.source();
      if (kind === "bridge") query.set("bridge", bridges.find((bridge) => bridge.deviceId === value)?.slug ?? value);
      if (kind === "accessory") query.set("accessory", byID.get(value)?.slug ?? value);
      const path = `${location.pathname}${query.size ? `?${query}` : ""}`;
      if (path !== location.pathname + location.search) history.replaceState(null, "", path);
    }
    async function load() {
      clearTimeout(refresh);
      keepAddress();
      const [from, end] = range.span() ?? [new Date(Date.now() - 3600000), null];
      const to = end ?? new Date();
      const query = new URLSearchParams({ from: from.toISOString(), to: to.toISOString() });
      const { kind, value } = sources.source();
      if (kind) query.set(kind, value);
      section.classList.add("loading");
      let history;
      try {
        history = await api(`/api/metrics?${query}`);
      } catch (e) {
        // A homeswift that records nothing (a library, a test) has no charts.
        if (e.status === 404) { section.remove(); return; }
        for (const chart of charts) chart.detail.textContent = e.message;
        section.classList.remove("loading");
        return;
      }
      section.classList.remove("loading");
      const points = history.points.map((point) => ({ ...point, time: new Date(point.time).getTime() }));
      shown = { points, latest: history.latest };
      for (const chart of charts) {
        if (chart.view) chart.view.update(points, from.getTime(), to.getTime(), history.step * 1000);
        else chart.view = HomeswiftChart.lineChart(chart.body, { title: chart.title, series: chart.series, format: chart.format, unit: chart.unit, points, from: from.getTime(), to: to.getTime(), step: history.step * 1000 });
        describe(chart, points, history.latest, !end);
      }
      if (table.open) fillTable();
      // A range that ends now moves on with it.
      if (!end) refresh = setTimeout(() => { if (section.isConnected && !document.hidden) load(); }, 60000);
    }

    /// The figure beside a chart's title and the line under it: the latest memory and CPU, the average and count
    /// of the calls in the range.
    function describe(chart, points, latest, live) {
      if (!chart.key) {
        const values = points.map(chart.series[0].value).filter((value) => value != null);
        const now = chart.title === "Memory" ? latest.memory : latest.cpu;
        chart.figure.textContent = live && now != null ? chart.format(now) : values.length ? chart.format(values.at(-1)) : "–";
        chart.detail.textContent = values.length ? `Highest ${chart.format(Math.max(...values))} · lowest ${chart.format(Math.min(...values))}` : "";
        return;
      }
      const calls = points.map((point) => point[chart.key]).filter(Boolean);
      const count = calls.reduce((sum, one) => sum + one.count, 0);
      const average = count ? calls.reduce((sum, one) => sum + one.average * one.count, 0) / count : null;
      chart.figure.textContent = average == null ? "–" : chart.format(average);
      chart.detail.textContent = count ? `Average of ${count.toLocaleString()} ${count === 1 ? "call" : "calls"} · longest ${chart.format(Math.max(...calls.map((one) => one.longest)))}` : "No calls in this range";
    }

    function fillTable() {
      if (!shown) return;
      const time = new Intl.DateTimeFormat([], { weekday: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      const cell = (value, format) => el("td", { text: value == null ? "–" : format(value) });
      const calls = (one) => [cell(one?.average, formatMilliseconds), cell(one?.longest, formatMilliseconds), cell(one?.count, (n) => n.toLocaleString())];
      const head = ["Time", "Memory", "CPU", "Requests, average", "longest", "count", "Device calls, average", "longest", "count"];
      table.replaceChildren(table.firstChild, el("div", { class: "table-scroll" }, el("table", {},
        el("thead", {}, el("tr", {}, head.map((text) => el("th", { text })))),
        el("tbody", {}, [...shown.points].reverse().map((point) => el("tr", {},
          el("td", { text: time.format(point.time) }), cell(point.memory, formatBytes), cell(point.cpu, formatPercent),
          calls(point.requests), calls(point.handlers)))))));
    }

    load();
    return section;
  }

  /// Bytes as MB, or GB from 1 GB; `top`, the axis's highest, keeps a chart's ticks in one unit.
  function formatBytes(bytes, top = bytes) {
    const gigabytes = top >= 1024 ** 3;
    const value = bytes / 1024 ** (gigabytes ? 3 : 2);
    return `${value.toFixed(gigabytes || (value > 0 && value < 10) ? 1 : 0)} ${gigabytes ? "GB" : "MB"}`;
  }
  function formatPercent(value) { return `${value > 0 && value < 10 ? value.toFixed(1) : Math.round(value)}%`; }
  function formatMilliseconds(ms) {
    if (ms >= 1000) return `${(ms / 1000).toFixed(ms >= 10000 ? 0 : 1)} s`;
    return `${ms > 0 && ms < 10 ? ms.toFixed(1) : Math.round(ms)} ms`;
  }

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
    const subtitle = describeModel(accessory);
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
    const subtitle = describeModel(accessory);
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
    const servers = new Set(accessories.map((accessory) => accessory.bridge)).size;
    // A section per plugin; a card's foot names its server.
    const search = el("input", { type: "search", class: "search", placeholder: "Search accessories", "aria-label": "Search accessories" });
    const sections = groupByPlugin(accessories).map(([name, list]) => el("section", { class: "accessory-section" },
      el("div", { class: "section-head" }, el("h2", { text: name }), el("span", { class: "muted", text: `${list.length} ${list.length === 1 ? "accessory" : "accessories"}` })),
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
      pageHead("Accessories", accessories.length ? `${accessories.length} on ${servers} ${servers === 1 ? "server" : "servers"}, as the Home app sees them. Changes here reach your devices.` : "", accessories.length ? search : null),
      accessories.length ? [...sections, none] : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No accessories yet. Plugins add them once they reach their devices." })));
  };

  /// Accessories by plugin: [name, accessories] pairs by the plugin's name, each list by name; those of no
  /// plugin last, as "Other accessories".
  function groupByPlugin(accessories) {
    const groups = Map.groupBy([...accessories].sort((a, b) => a.name.localeCompare(b.name)), (accessory) => accessory.platformName ?? "");
    return [...groups].sort(([a], [b]) => !a - !b || a.localeCompare(b)).map(([name, list]) => [name || "Other accessories", list]);
  }

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
  const blockState = (block, plugin, instance) => block.system ? ["Built in", "standby"] : instance?.paused ? ["Paused", "paused"]
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
    let useSuggestion = null;
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
      // The Assistant's suggestion goes into the view on screen, as unsaved changes to review and save.
      useSuggestion = (value) => {
        const next = { ...value, platform };
        if (mode === "form") { form = buildForm(schema, next); formView.replaceChildren(form.element); }
        else { textarea.value = JSON.stringify(next, null, 2); editor.repaint(); }
        body.dispatchEvent(new Event("input", { bubbles: true }));
      };
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
      useSuggestion && !block.system ? describeSetup({ platform, pluginName: plugin ? plugin.name : platform, current: () => { try { return getValue(); } catch { return current; } }, use: useSuggestion }) : null,
      body,
      el("div", { class: "settings-bar" }, message, revert, save),
      remove);
    update();
  };

  /// Describe your setup: the Assistant writes the block from the plugin's config.schema.json and a sentence
  /// ("two lights, the second one at 192.168.1.40"); the change shows as a diff, and "Use it" puts it in the form
  /// as unsaved changes. Shown when the Assistant is on.
  function describeSetup({ platform, pluginName, current, use }) {
    const card = el("details", { class: "card describe-setup hidden" });
    api("/api/assistant").then((state) => { if (state && state.enabled) card.classList.remove("hidden"); }).catch(() => {});
    const request = el("textarea", { class: "short", rows: 3, placeholder: `What should ${pluginName} do? For example: "add my second light at 192.168.1.40, and poll every 5 seconds".`, "aria-label": "Your setup, in your words" });
    const ask = el("button", { class: "primary", text: "Suggest" });
    const result = el("div", { class: "describe-result" });
    ask.addEventListener("click", async () => {
      if (!request.value.trim()) { request.focus(); return; }
      ask.disabled = true;
      result.replaceChildren(el("p", { class: "muted", text: "The Assistant is writing the block…" }));
      try {
        const before = current();
        const reply = await api("/api/assistant/config", { method: "POST", body: { platform, request: request.value, current: before } });
        const { platform: _, ...after } = reply.config || {};
        const { platform: __, ...was } = before || {};
        const lines = blockDiff(was, after);
        const changed = lines.some((line) => line.kind !== "same");
        result.replaceChildren(
          reply.explanation ? el("div", { class: "markdown" }, HomeswiftCommon.markdown(reply.explanation)) : null,
          changed ? el("pre", { class: "diff" }, lines.map((line) => el("span", { class: `diff-${line.kind}`, text: `${line.kind === "add" ? "+ " : line.kind === "remove" ? "- " : "  "}${line.text}\n` })))
            : el("p", { class: "muted", text: "No change to the block." }),
          changed ? el("div", { class: "actions" },
            el("button", { class: "primary", text: "Use it", onclick: () => { use(after); result.replaceChildren(el("p", { class: "ok", text: "In the form: review it, then Save." })); } }),
            el("button", { text: "Discard", onclick: () => result.replaceChildren() })) : null,
          el("p", { class: "muted", text: `Written by ${reply.model}. Passwords and tokens never reach it; check addresses and names before saving.` }));
      } catch (e) {
        result.replaceChildren(el("p", { class: "error", text: e.message }));
      } finally { ask.disabled = false; }
    });
    card.append(el("summary", {}, sparkle(), el("strong", { text: " Describe your setup" }), el("span", { class: "muted", text: " · the Assistant writes the settings" })),
      el("div", { class: "describe-body" }, request, el("div", { class: "actions" }, ask), result));
    return card;
  }

  /// Two blocks as pretty JSON with sorted keys, line by line: same, add or remove (a longest common subsequence).
  function blockDiff(before, after) {
    const sortKeys = (value) => Array.isArray(value) ? value.map(sortKeys)
      : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys(value[key])])) : value;
    const a = JSON.stringify(sortKeys(before ?? {}), null, 2).split("\n");
    const b = JSON.stringify(sortKeys(after ?? {}), null, 2).split("\n");
    const lengths = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
    for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) {
      lengths[i][j] = a[i] === b[j] ? lengths[i + 1][j + 1] + 1 : Math.max(lengths[i + 1][j], lengths[i][j + 1]);
    }
    const out = [];
    let i = 0, j = 0;
    while (i < a.length && j < b.length) {
      if (a[i] === b[j]) { out.push({ kind: "same", text: a[i] }); i++; j++; }
      else if (lengths[i + 1][j] >= lengths[i][j + 1]) out.push({ kind: "remove", text: a[i++] });
      else out.push({ kind: "add", text: b[j++] });
    }
    while (i < a.length) out.push({ kind: "remove", text: a[i++] });
    while (j < b.length) out.push({ kind: "add", text: b[j++] });
    return out;
  }

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

  /// A schema's `condition` (`{ functionBody: "return model.x === 'y';" }`, or the expression as a string) as a
  /// function of the block and the entry's index, or null when there is none. The page may not run code it
  /// is sent (no eval under its Content-Security-Policy), so this reads the part of JavaScript conditions use:
  /// `model.a.b`, `model.list[arrayIndices].type`, literals and arrays, `.includes()`, `!`, comparisons,
  /// `&&`, `||` and parentheses. A condition it cannot read shows the field.
  function schemaCondition(condition) {
    const source = typeof condition === "string" ? condition : condition && typeof condition.functionBody === "string" ? condition.functionBody : null;
    if (source === null) return null;
    let ast;
    try { ast = parseCondition(source); } catch { return null; }
    return (model, index) => {
      try { return Boolean(evaluateCondition(ast, { model, arrayIndex: index, arrayIndices: index })); } catch { return true; }
    };
  }

  function parseCondition(source) {
    const tokens = [];
    const pattern = /\s*(?:(\d+(?:\.\d+)?)|('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|([A-Za-z_$][\w$]*)|(===|!==|==|!=|<=|>=|&&|\|\||[!<>()[\].,;]))/y;
    const text = source.trim();
    let match;
    pattern.lastIndex = 0;
    while (pattern.lastIndex < text.length && (match = pattern.exec(text))) {
      if (match[1] !== undefined) tokens.push({ kind: "value", value: Number(match[1]) });
      else if (match[2] !== undefined) tokens.push({ kind: "value", value: match[2].slice(1, -1).replace(/\\(.)/g, "$1") });
      else if (match[3] !== undefined) tokens.push({ kind: "name", value: match[3] });
      else tokens.push({ kind: "op", value: match[4] });
    }
    if (pattern.lastIndex < text.length && text.slice(pattern.lastIndex).trim()) throw new Error("unreadable condition");
    let at = 0;
    const peek = (value) => tokens[at] && tokens[at].kind === "op" && tokens[at].value === value;
    const expect = (value) => { if (!peek(value)) throw new Error(`expected ${value}`); at++; };
    if (tokens[at] && tokens[at].kind === "name" && tokens[at].value === "return") at++;
    const binary = { "||": 1, "&&": 2, "===": 3, "!==": 3, "==": 3, "!=": 3, "<": 4, ">": 4, "<=": 4, ">=": 4 };
    const expression = (minimum = 1) => {
      let left = unary();
      while (tokens[at] && tokens[at].kind === "op" && binary[tokens[at].value] >= minimum) {
        const op = tokens[at++].value;
        left = { op, left, right: expression(binary[op] + 1) };
      }
      return left;
    };
    const unary = () => { if (peek("!")) { at++; return { op: "!", operand: unary() }; } return postfix(primary()); };
    const primary = () => {
      const token = tokens[at++];
      if (!token) throw new Error("unexpected end");
      if (token.kind === "value") return { value: token.value };
      if (token.kind === "name") {
        if (token.value === "true" || token.value === "false") return { value: token.value === "true" };
        if (token.value === "null" || token.value === "undefined") return { value: token.value === "null" ? null : undefined };
        return { name: token.value };
      }
      if (token.value === "(") { const inner = expression(); expect(")"); return inner; }
      if (token.value === "[") {
        const items = [];
        while (!peek("]")) { items.push(expression()); if (peek(",")) at++; else break; }
        expect("]");
        return { array: items };
      }
      throw new Error(`unexpected ${token.value}`);
    };
    const postfix = (node) => {
      for (;;) {
        if (peek(".")) {
          at++;
          const name = tokens[at++];
          if (!name || name.kind !== "name") throw new Error("expected a name");
          if (peek("(")) {
            at++;
            const args = [];
            while (!peek(")")) { args.push(expression()); if (peek(",")) at++; else break; }
            expect(")");
            node = { call: name.value, target: node, args };
          } else node = { member: name.value, target: node };
        } else if (peek("[")) {
          at++;
          const key = expression();
          expect("]");
          node = { index: key, target: node };
        } else return node;
      }
    };
    const ast = expression();
    if (peek(";")) at++;
    if (at < tokens.length) throw new Error("unexpected input");
    return ast;
  }

  function evaluateCondition(node, scope) {
    if ("value" in node) return node.value;
    if (node.name !== undefined) { if (!(node.name in scope)) throw new Error(`unknown ${node.name}`); return scope[node.name]; }
    if (node.array) return node.array.map((item) => evaluateCondition(item, scope));
    const property = (target, key) => (target === null || target === undefined ? undefined : Object.prototype.hasOwnProperty.call(Object(target), key) || Array.isArray(target) && key === "length" ? target[key] : undefined);
    if (node.member !== undefined) return property(evaluateCondition(node.target, scope), node.member);
    if (node.index) return property(evaluateCondition(node.target, scope), evaluateCondition(node.index, scope));
    if (node.call !== undefined) {
      const target = evaluateCondition(node.target, scope);
      const args = node.args.map((arg) => evaluateCondition(arg, scope));
      if (node.call === "includes" && (Array.isArray(target) || typeof target === "string")) return target.includes(args[0]);
      if (node.call === "indexOf" && (Array.isArray(target) || typeof target === "string")) return target.indexOf(args[0]);
      throw new Error(`unknown call ${node.call}`);
    }
    if (node.op === "!") return !evaluateCondition(node.operand, scope);
    const left = evaluateCondition(node.left, scope);
    if (node.op === "&&") return left && evaluateCondition(node.right, scope);
    if (node.op === "||") return left || evaluateCondition(node.right, scope);
    const right = evaluateCondition(node.right, scope);
    switch (node.op) {
      case "===": return left === right;
      case "!==": return left !== right;
      case "==": return left == right; // eslint-disable-line eqeqeq
      case "!=": return left != right; // eslint-disable-line eqeqeq
      case "<": return left < right;
      case ">": return left > right;
      case "<=": return left <= right;
      case ">=": return left >= right;
    }
    throw new Error(`unknown operator ${node.op}`);
  }

  /// A form from a Homebridge-style config.schema.json; key order follows the schema (and its layout).
  function buildForm(root, value) {
    const schema = root.schema || root;
    const properties = schema.properties || {};
    const requiredTop = new Set(Array.isArray(schema.required) ? schema.required : []);
    const fields = new Map();
    const container = el("div", {});
    // Fields and layout groups shown only when their condition holds, re-checked as the form changes.
    const conditional = [];
    const watch = (element, condition, index) => {
      const test = schemaCondition(condition);
      if (test && element) conditional.push({ element, test, index });
    };

    const field = (key, property, current, required, index) => {
      const made = makeField(key, property, current, required, index);
      watch(made.element, property.condition ?? property["x-schema-form"]?.condition, index);
      return made;
    };
    const makeField = (key, property, current, required, index) => {
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
        const nested = buildObject(property, current || {}, index);
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
            const nested = buildObject(items, itemValue || {}, () => rows.indexOf(entry));
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

    function buildObject(objectSchema, current, index) {
      const props = objectSchema.properties || {};
      const required = new Set(Array.isArray(objectSchema.required) ? objectSchema.required : []);
      const parts = new Map();
      const element = el("div", { class: "entry-body" });
      const entries = [];
      for (const [key, property] of Object.entries(props)) {
        const isRequired = required.has(key) || property.required === true;
        const f = field(key, property, current[key], isRequired, index);
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
      if (item && item.key) { const node = render(item.key); if (item.condition) watch(node, item.condition); return node; }
      if (item && Array.isArray(item.items)) {
        const inner = item.items.map(layoutItem).flat().filter(Boolean);
        if (!inner.length) return null;
        const node = item.type === "fieldset" || item.title
          ? el("details", { class: "group-box", open: !item.expandable || item.expanded !== false }, el("summary", { text: item.title || "More" }), el("div", { class: "fields" }, ...inner))
          : el("div", { class: "fields" }, ...inner);
        watch(node, item.condition);
        return node;
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

    const getValue = () => {
      const out = {};
      for (const [key, v] of Object.entries(value)) if (!properties[key]) out[key] = v;
      for (const [key, f] of fields) { const v = f.get(); if (v !== undefined) out[key] = v; }
      return out;
    };
    // A hidden field keeps its value, as Homebridge's form does; it only leaves the screen.
    const applyConditions = () => {
      if (!conditional.length) return;
      const model = getValue();
      for (const { element, test, index } of conditional) {
        const shown = test(model, typeof index === "function" ? index() : index);
        element.classList.toggle("hidden", !shown);
      }
    };
    container.addEventListener("input", applyConditions);
    container.addEventListener("change", applyConditions);
    container.addEventListener("click", () => setTimeout(applyConditions, 0));   // rows added or removed
    applyConditions();
    return { element: container, getValue };
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

  // The Logs and Status pages' filters, in one row above what they scope.
  const rangeChoices = [["latest", "Latest lines"], ["1h", "Last hour"], ["6h", "Last 6 hours"], ["24h", "Last 24 hours"],
    ["today", "Today"], ["yesterday", "Yesterday"], ["7d", "Last 7 days"], ["custom", "Custom range…"]];

  /// A time range menu whose first choice is the default (`latest`, the Logs page's latest lines, only when asked
  /// for), with the From and To of a custom range in `customRow`. `changed` runs on a choice.
  function rangeFilter(params, { latest = false, changed }) {
    const choices = rangeChoices.filter(([value]) => latest || value !== "latest");
    const fallback = choices[0][0];
    const since = choices.some(([value]) => value === params.get("since")) ? params.get("since") : fallback;
    const picker = el("select", { class: `popup ${since === fallback ? "" : "chosen"}`, "aria-label": "Time range" }, choices.map(([value, text]) => el("option", { value, text, selected: value === since })));
    const localInput = (date) => new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    const fromInput = el("input", { type: "datetime-local", "aria-label": "From", value: params.get("from") ?? localInput(new Date(Date.now() - 3600000)) });
    const toInput = el("input", { type: "datetime-local", "aria-label": "To", value: params.get("to") ?? localInput(new Date()) });
    const customRow = el("div", { class: `log-range ${since === "custom" ? "" : "hidden"}` },
      el("label", {}, "From", fromInput), el("label", {}, "To", toInput),
      el("button", { text: "Show", onclick: () => changed() }));
    picker.addEventListener("change", () => {
      customRow.classList.toggle("hidden", picker.value !== "custom");
      picker.classList.toggle("chosen", picker.value !== fallback);
      if (picker.value === "custom") fromInput.focus(); else changed();
    });
    return {
      picker, customRow,
      /// The span chosen, `[from, to]` with `to` null when it ends now; null for the latest lines.
      span() {
        const now = new Date();
        const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        switch (picker.value) {
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
      },
      /// Adds the choice to a page's address: `since`, and `from` and `to` for a custom range.
      address(query) {
        if (picker.value !== fallback) query.set("since", picker.value);
        if (picker.value === "custom") { query.set("from", fromInput.value); if (toInput.value) query.set("to", toInput.value); }
      },
    };
  }

  /// What the data is about, one menu: everything (`everything` names it); the bridges, every bridge's own lines
  /// (`allBridges`) or one's; or one accessory, grouped by plugin. Values: "", "bridge:all", "bridge:<device ID>",
  /// "accessory:<id>". `changed` runs on a choice; `source()` reads it as a kind and a value.
  function sourceFilter(accessories, bridges, initial, { label, everything, allBridges = false, changed }) {
    const option = (value, text) => el("option", { value, text, selected: value === initial });
    const picker = el("select", { class: `popup ${initial ? "chosen" : ""}`, "aria-label": label },
      option("", everything),
      bridges.length ? el("optgroup", { label: "Bridges" }, allBridges ? option("bridge:all", "Bridges only") : null,
        bridges.map((bridge) => option(`bridge:${bridge.deviceId}`, bridge.external ? `${bridge.name} · its own server` : bridge.childBridge ? `${bridge.name} · child bridge` : bridge.name))) : null,
      groupByPlugin(accessories).map(([name, list]) => el("optgroup", { label: name },
        list.map((accessory) => option(`accessory:${accessory.id}`, accessory.name)))));
    picker.addEventListener("change", () => { picker.classList.toggle("chosen", Boolean(picker.value)); changed(); });
    return {
      picker,
      source() {
        const [kind, ...rest] = picker.value.split(":");
        return { kind, value: rest.join(":") };
      },
    };
  }

  /// The source menu's value for an address: an accessory by its slug or id, a bridge by its slug, or `all`.
  function initialSource(accessories, bridges, accessory, bridge) {
    const found = accessory && accessories.find((one) => one.slug === accessory || one.id === accessory);
    if (found) return `accessory:${found.id}`;
    if (bridge === "all") return "bridge:all";
    const one = bridge && bridges.find((candidate) => candidate.slug === bridge);
    return one ? `bridge:${one.deviceId}` : "";
  }

  // /logs/<accessory>?bridge=<bridge>&since=24h&level=warning&q=text: the accessory by its slug (a plugin's page
  // may give its id), the bridge by its slug,
  // the range (latest, 1h, 6h, 24h, today, yesterday, 7d, or custom with from= and to=), the lowest level and the
  // text. The address follows what is chosen, so it can be kept or shared.
  views.logs = async (main, [wanted] = []) => {
    const [accessories, bridges] = await Promise.all([
      api("/api/accessories").then((list) => withSlugs(list, "accessory")).catch(() => []),
      api("/api/status").then((status) => withSlugs(status.bridges, "bridge")).catch(() => []),
    ]);
    const params = new URLSearchParams(location.search);
    const output = el("div", { class: "log", role: "log", "aria-live": "off" });
    const filter = el("input", { type: "search", class: "search", placeholder: "Filter text", "aria-label": "Filter the log" });
    const follow = el("input", { type: "checkbox", checked: true });
    const count = el("span", { class: "muted count" });
    // What the lines are about (sourceFilter): every line; the bridges' own lines (their servers': connections,
    // pairings, controllers), every bridge's or one's; or one accessory's (those of its own server and those naming
    // it, its id or its address). The server picks them before its limit (UIServer.logMatcher), so a week of one
    // accessory is not cut short by the others'.
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
    const sources = sourceFilter(accessories, bridges, initialSource(accessories, bridges, wanted, params.get("bridge")), {
      label: "What the lines are about", everything: "All lines", allBridges: true, changed: () => { choose(); load(); } });
    const source = sources.source;
    const choose = () => {
      const { kind, value } = source();
      logState.accessory = kind === "accessory" ? termsFor(value) : null;
      logState.bridge = kind === "bridge" ? bridgeFor(value) : null;
    };
    // `live`: new lines join the page (not while a span in the past is shown); `cap`: how many it keeps.
    filter.value = params.get("q") ?? "";
    const level = levelChoices.some(([value]) => value === params.get("level")) ? params.get("level") : "info";
    logState = { output, level, filter, follow, count, lines: [], accessory: null, bridge: null, live: true, cap: latestLines, capped: false };
    choose();
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

    // A time range (rangeFilter): the latest lines from memory, or a span from the log the bridge keeps on disk
    // (rotated, a week at most). A span that ends now keeps following; one in the past stays as it is.
    const range = rangeFilter(params, { latest: true, changed: () => load() });
    /// The address of what is shown, in place: no new history entry per choice.
    function keepAddress() {
      const query = new URLSearchParams();
      range.address(query);
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
      const chosen = range.span();
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
    show(main,
      pageHead("Logs", "This homeswift's log, live, and up to a week back."),
      el("div", { class: "card log-card" },
        el("div", { class: "editor-bar" }, levels, range.picker, sources.picker, filter, el("span", { class: "spacer" }), count, copy,
          el("label", { class: "toggle compact" }, el("span", { class: "switch" }, follow, el("span")), el("span", { text: "Follow" })),
          range.customRow),
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

"""#),
        "camera.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// Camera views, for the Accessories page's camera cards and plugin pages: a 16:9 picture with the camera's name
// and state over it. While the view is on screen and the page visible, it plays the camera's live feed
// (/api/cameras/<id>/live, fMP4 through Media Source Extensions: ManagedMediaSource on iOS Safari 17 and later,
// MediaSource elsewhere), muted; otherwise, or when the camera has no live feed or the browser cannot play its
// codecs, a snapshot every few seconds (/api/cameras/<id>/snapshot). Off screen it fetches nothing, so a page
// of ten cameras does not pull ten streams. Loaded after common.js.
(() => {
  "use strict";

  const { el } = HomeswiftCommon;
  const MediaSourceType = window.ManagedMediaSource || window.MediaSource;
  const SNAPSHOT_EVERY = 3000;
  // Behind the live edge by more than this, the video jumps forward; buffer older than KEEP seconds goes.
  const MAX_LAG = 3, KEEP = 20;

  const glyphs = {
    muted: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="m16 9 5 6M21 9l-5 6"/>',
    sound: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
    fullscreen: '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
    refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  };
  function glyph(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = glyphs[name];
    return svg;
  }
  const button = (name, label, onclick) => el("button", { type: "button", class: "camera-button", "aria-label": label, title: label, onclick }, glyph(name));

  /// "just now", "4 min ago", "2 h ago", or the date.
  function ago(date) {
    const seconds = (Date.now() - date) / 1000;
    if (seconds < 45) return "just now";
    if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
    if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
    return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }

  // Every view on the page, for the accessory events and the page's visibility.
  const views = new Set();
  const observer = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
    for (const entry of entries) entry.target.cameraView?.setVisible(entry.isIntersecting);
  }, { threshold: 0.2 }) : null;
  document.addEventListener("visibilitychange", () => { for (const view of views) view.update(); });
  // Views whose element left the page (another tab of the UI, a redrawn grid) stop and go.
  setInterval(() => { for (const view of views) if (!view.element.isConnected) view.destroy(); }, 5000);
  setInterval(() => { for (const view of views) view.tick(); }, 30000);

  /// A view of `camera` ({ id, name, doorbell, motion, recording, lastRing }): the element to place, and
  /// `motion(on)`, `ring(date)`, `recording(on)` to change what it shows.
  function view(camera) {
    const video = el("video", { muted: true, playsInline: true, autoplay: true, disablePictureInPicture: true, "aria-label": `Live video of ${camera.name}` });
    // ManagedMediaSource plays only with AirPlay off (or an AirPlay alternative), and a muted video autoplays.
    video.disableRemotePlayback = true;
    video.muted = true;
    video.setAttribute("muted", "");
    video.setAttribute("playsinline", "");
    const still = el("img", { class: "camera-still", alt: `Snapshot of ${camera.name}`, decoding: "async" });
    const liveBadge = el("span", { class: "camera-badge live hidden", text: "Live" });
    const stillBadge = el("span", { class: "camera-badge hidden" });
    const motionBadge = el("span", { class: "camera-badge motion hidden", text: "Motion" });
    const ringBadge = el("span", { class: "camera-badge ring hidden" });
    const recordingBadge = el("span", { class: "camera-badge recording hidden", text: "Recording", title: "HomeKit Secure Video records this camera's events" });
    const message = el("div", { class: "camera-message", text: "Connecting…" });
    const sound = button("muted", "Unmute", () => {
      video.muted = !video.muted;
      sound.replaceChildren(glyph(video.muted ? "muted" : "sound"));
      sound.setAttribute("aria-label", video.muted ? "Unmute" : "Mute");
      sound.title = sound.getAttribute("aria-label");
      if (!video.muted) video.play().catch(() => {});
    });
    sound.classList.add("hidden");
    const fullscreen = button("fullscreen", "Full screen", () => {
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      else if (element.requestFullscreen) element.requestFullscreen().catch(() => {});
      else if (element.webkitRequestFullscreen) element.webkitRequestFullscreen();
      // An iPhone has full screen for videos only.
      else if (video.webkitEnterFullscreen && state.live) video.webkitEnterFullscreen();
    });
    const refresh = button("refresh", "Refresh", () => { state.noLive = false; restart(); });
    const element = el("div", { class: "camera-view", "data-camera": camera.id },
      still, video, message,
      el("div", { class: "camera-top" },
        el("strong", { class: "camera-name", text: camera.name }),
        el("span", { class: "camera-badges" }, liveBadge, stillBadge, recordingBadge, motionBadge, ringBadge)),
      el("div", { class: "camera-controls" }, sound, refresh, fullscreen));

    const state = { visible: false, running: false, live: false, noLive: !MediaSourceType, abort: null, timer: null, lastRing: camera.lastRing ? new Date(camera.lastRing) : null, stalls: 0 };
    // A gap in the buffer (a fragment the server dropped for a slow reader): jump over it.
    video.addEventListener("waiting", () => {
      const ranges = video.buffered;
      for (let i = 0; i < ranges.length; i++) {
        if (ranges.start(i) > video.currentTime) { video.currentTime = ranges.start(i) + 0.05; break; }
      }
    });
    const url = (what, query = "") => `/api/cameras/${encodeURIComponent(camera.id)}/${what}${query}`;

    function show(what, text = "") {
      // "live" the video, "still" the snapshot, "message" a line over a dim picture.
      element.classList.toggle("is-live", what === "live");
      element.classList.toggle("has-still", !!still.src);
      message.textContent = text;
      message.classList.toggle("hidden", !text);
      liveBadge.classList.toggle("hidden", what !== "live");
      // The time a snapshot was taken, while one shows.
      stillBadge.classList.toggle("hidden", what !== "still");
    }

    // ---- Snapshots ----

    let stillURL = null;
    async function snapshot(signal) {
      const width = Math.min(1920, Math.max(320, Math.round(element.clientWidth * (window.devicePixelRatio || 1) / 160) * 160));
      const response = await fetch(url("snapshot", `?width=${width}&height=${Math.round(width * 9 / 16)}`), { credentials: "same-origin", cache: "no-store", signal });
      if (response.status === 401) { location.href = "/"; return; }
      if (!response.ok) {
        let text = `HTTP ${response.status}`;
        try { text = (await response.json()).error || text; } catch {}
        const error = new Error(text);
        error.status = response.status;
        throw error;
      }
      const blob = await response.blob();
      const next = URL.createObjectURL(blob);
      await new Promise((resolve) => { const image = new Image(); image.onload = image.onerror = resolve; image.src = next; });
      if (signal.aborted) { URL.revokeObjectURL(next); return; }
      still.src = next;
      if (stillURL) URL.revokeObjectURL(stillURL);
      stillURL = next;
      stillBadge.textContent = new Date().toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" });
    }

    async function snapshots(signal) {
      while (!signal.aborted) {
        try {
          await snapshot(signal);
          show("still");
          await sleep(SNAPSHOT_EVERY, signal);
        } catch (error) {
          if (signal.aborted) return;
          show("message", error.status === 409 ? "Turned off in the Home app" : error.status === 503 ? "Paused" : "No picture from the camera");
          // A camera that fails is asked less often.
          await sleep(SNAPSHOT_EVERY * 4, signal);
        }
      }
    }

    // ---- Live ----

    async function live(signal) {
      const response = await fetch(url("live"), { credentials: "same-origin", cache: "no-store", signal });
      if (response.status === 401) { location.href = "/"; return false; }
      if (!response.ok) {
        // No feed from this camera: snapshots, until Refresh. Busy or failing: snapshots, live again later.
        if (response.status === 404) state.noLive = true;
        if (response.status === 409) { show("message", "Turned off in the Home app"); state.noLive = true; }
        if (response.status === 503) { show("message", "Paused"); state.noLive = true; }
        response.body?.cancel().catch(() => {});
        return false;
      }
      const type = response.headers.get("X-Camera-Mime-Type") || "video/mp4";
      if (!MediaSourceType.isTypeSupported(type)) {
        state.noLive = true;
        response.body.cancel().catch(() => {});
        show("message", still.src ? "" : "This browser cannot play this camera's video");
        return false;
      }
      sound.classList.toggle("hidden", !/mp4a|opus|ac-3|ec-3/i.test(type));
      const source = new MediaSourceType();
      const sourceURL = URL.createObjectURL(source);
      video.src = sourceURL;
      signal.addEventListener("abort", () => { video.removeAttribute("src"); video.load(); URL.revokeObjectURL(sourceURL); });
      await new Promise((resolve) => source.addEventListener("sourceopen", resolve, { once: true }));
      if (signal.aborted) return true;
      const buffer = source.addSourceBuffer(type);
      const queue = [];
      let lastTrim = 0;
      const pump = () => {
        if (buffer.updating || signal.aborted || source.readyState !== "open") return;
        const ranges = buffer.buffered;
        if (ranges.length) {
          const end = ranges.end(ranges.length - 1);
          // The live edge, not the past: a tab in the background or a slow network falls behind.
          if (end - video.currentTime > MAX_LAG) video.currentTime = Math.max(ranges.start(ranges.length - 1), end - 0.5);
          const start = ranges.start(0);
          if (video.currentTime - start > KEEP * 1.5 && Date.now() - lastTrim > 10000) {
            lastTrim = Date.now();
            buffer.remove(start, video.currentTime - KEEP);
            return;
          }
        }
        const chunk = queue.shift();
        if (!chunk) return;
        try {
          buffer.appendBuffer(chunk);
        } catch (error) {
          // Full: drop what was played and try again.
          if (error.name === "QuotaExceededError" && ranges.length) { queue.unshift(chunk); buffer.remove(ranges.start(0), Math.max(ranges.start(0) + 0.1, video.currentTime - 2)); }
          else throw error;
        }
      };
      buffer.addEventListener("updateend", pump);
      video.addEventListener("playing", () => { state.live = true; show("live"); }, { once: true });
      const reader = response.body.getReader();
      signal.addEventListener("abort", () => reader.cancel().catch(() => {}));
      let started = false;
      // Stalled: no new frame for a while, start again.
      let lastTime = -1, stalledSince = Date.now();
      const watchdog = setInterval(() => {
        if (video.currentTime !== lastTime) { lastTime = video.currentTime; stalledSince = Date.now(); return; }
        if (Date.now() - stalledSince > 10000) reader.cancel().catch(() => {});
      }, 2000);
      signal.addEventListener("abort", () => clearInterval(watchdog));
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done || signal.aborted) break;
          queue.push(value);
          pump();
          if (!started) { started = true; video.play().catch(() => {}); }
        }
      } finally {
        clearInterval(watchdog);
      }
      return true;
    }

    // ---- Running ----

    const sleep = (ms, signal) => new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      signal.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
    });

    async function run(signal) {
      // A first picture at once while the live feed connects, then live; snapshots when there is none.
      const first = snapshot(signal).then(() => { if (!state.live) show("still"); }).catch(() => {});
      while (!signal.aborted) {
        if (state.noLive) { await first; await snapshots(signal); return; }
        let played = false;
        try {
          played = await live(signal);
        } catch {
          played = false;
        }
        if (signal.aborted) return;
        const wasLive = state.live;
        state.live = false;
        video.removeAttribute("src");
        video.load();
        if (wasLive) { show(still.src ? "still" : "message", still.src ? "" : "Reconnecting…"); await sleep(1500, signal); continue; }
        if (state.noLive) continue;
        // Live failed: snapshots for a while, then live again.
        const pause = new AbortController();
        const done = () => pause.abort();
        signal.addEventListener("abort", done, { once: true });
        setTimeout(done, played ? 2000 : 30000);
        await first;
        await snapshots(pause.signal);
      }
    }

    function start() {
      if (state.running) return;
      state.running = true;
      state.abort = new AbortController();
      show(still.src ? "still" : "message", still.src ? "" : "Connecting…");
      run(state.abort.signal);
    }
    function stop() {
      if (!state.running) return;
      state.running = false;
      state.live = false;
      state.abort.abort();
      state.abort = null;
      liveBadge.classList.add("hidden");
      element.classList.remove("is-live");
    }
    function restart() { stop(); update(); }
    function update() {
      if (state.visible && document.visibilityState === "visible" && element.isConnected) start(); else stop();
    }

    const controller = {
      element, camera,
      setVisible(visible) { state.visible = visible; update(); },
      update,
      tick() { if (state.lastRing) ringBadge.textContent = `Rang ${ago(state.lastRing)}`; },
      motion(on) { motionBadge.classList.toggle("hidden", !on); element.classList.toggle("motion", !!on); },
      recording(on) { recordingBadge.classList.toggle("hidden", !on); },
      ring(date = new Date()) {
        state.lastRing = date;
        ringBadge.classList.remove("hidden");
        controller.tick();
        // A ring that just happened stands out for a moment.
        if (Date.now() - date < 60000) { ringBadge.classList.remove("fresh"); void ringBadge.offsetWidth; ringBadge.classList.add("fresh"); }
      },
      destroy() { stop(); observer?.unobserve(element); views.delete(controller); if (stillURL) URL.revokeObjectURL(stillURL); },
    };
    element.cameraView = controller;
    views.add(controller);
    controller.motion(camera.motion);
    controller.recording(camera.recording);
    if (state.lastRing) controller.ring(state.lastRing);
    if (observer) observer.observe(element); else controller.setVisible(true);
    return controller;
  }

  /// An accessory event from the page's event stream: motion and rings for the views of that accessory.
  function event({ id, service, characteristic, value }) {
    for (const view of views) {
      if (view.camera.id !== id) continue;
      if (characteristic === "Motion Detected") view.motion(value === true || value === 1);
      else if (characteristic === "Active" && service === "CameraRecordingManagement") view.recording(value === 1);
      else if (characteristic === "Programmable Switch Event" && view.camera.doorbell && value !== null) view.ring(new Date());
    }
  }

  window.HomeswiftCamera = { view, event, supported: !!MediaSourceType };
})();

"""#),
        "charts.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// Line charts over time for the Status page: memory, CPU, request durations. One axis each, 2px lines, an area wash
// under a single series, a legend once there are two, hairline grid. A crosshair snaps to the nearest point and a
// tooltip lists every series there, on hover and with the arrow keys once the chart has focus. Points further apart
// than a step and a half leave a gap: nothing was recorded (homeswift was not running); a point without a value for a
// series (a minute without requests) is passed over without one. It redraws at its width.
(() => {
  "use strict";

  const ns = "http://www.w3.org/2000/svg";
  const svg = (tag, attrs = {}) => {
    const node = document.createElementNS(ns, tag);
    for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
    return node;
  };
  const html = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  };

  const height = 168, pad = { top: 10, right: 14, bottom: 24, left: 52 };

  /// The highest tick at or above `max`, over four steps of 1, 2, 2.5 or 5 times a power of ten of `unit` (bytes
  /// step in whole megabytes).
  function niceMax(max, unit = 1) {
    if (!(max > 0)) return unit;
    const raw = max / unit / 4;
    const power = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 2.5, 5, 10].map((m) => m * power).find((s) => s >= raw);
    return step * 4 * unit;
  }

  /// Times along the x axis: whole minutes, hours or days, about `count` of them.
  function timeTicks(from, to, count) {
    const span = to - from;
    const steps = [60e3, 300e3, 900e3, 1800e3, 3600e3, 2 * 3600e3, 3 * 3600e3, 6 * 3600e3, 12 * 3600e3, 86400e3];
    const step = steps.find((s) => span / s <= count) ?? 86400e3;
    const first = new Date(Math.ceil(from / step) * step);
    // Day and half-day steps fall on local midnight and noon, not UTC's.
    if (step >= 12 * 3600e3) {
      const local = new Date(from);
      local.setHours(step >= 86400e3 ? 0 : Math.ceil(local.getHours() / 12) * 12, 0, 0, 0);
      if (local < from) local.setTime(local.getTime() + step);
      first.setTime(local.getTime());
    }
    const ticks = [];
    for (let t = first.getTime(); t <= to; t += step) ticks.push(t);
    return ticks;
  }
  /// A tick's label: the day at midnight, else the time.
  const tickLabel = (time) => {
    const date = new Date(time);
    return date.getHours() === 0 && date.getMinutes() === 0 ? dayName.format(date) : hourMinute.format(date);
  };

  const hourMinute = new Intl.DateTimeFormat([], { hour: "2-digit", minute: "2-digit", hour12: false });
  const dayName = new Intl.DateTimeFormat([], { weekday: "short", day: "numeric" });
  const fullTime = new Intl.DateTimeFormat([], { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false });

  /// A chart in `container`: `series` are `{ label, value(point), tone }` (tone 1 or 2, the palette's slots),
  /// `points` have `time` (a Date), `from` and `to` bound the x axis, `step` is the points' spacing in ms and
  /// `format` writes a value with its unit and `unit(max)` is the size of that unit, so ticks fall on round values
  /// of it. Returns `update(points, from, to, step)`.
  function lineChart(container, { title, series, format, unit = () => 1, points, from, to, step }) {
    const frame = html("div", "chart-frame");
    const tooltip = html("div", "chart-tooltip hidden");
    tooltip.setAttribute("role", "status");
    frame.append(tooltip);
    container.append(frame);
    if (series.length > 1) {
      const legend = html("div", "chart-legend");
      for (const one of series) {
        const item = html("span", "", null);
        item.append(html("i", `key tone-${one.tone}`), document.createTextNode(one.label));
        legend.append(item);
      }
      container.append(legend);
    }
    let state = { points, from, to, step };
    let chosen = null;   // the index the crosshair is on, kept between redraws
    let drawn = null;

    function draw() {
      const width = Math.max(frame.clientWidth, 240);
      const { points, from, to, step } = state;
      const plotWidth = width - pad.left - pad.right, plotHeight = height - pad.top - pad.bottom;
      const values = points.flatMap((point) => series.map((one) => one.value(point))).filter((v) => v != null);
      const highest = Math.max(0, ...values);
      const top = niceMax(highest, unit(highest));
      const x = (time) => pad.left + (time - from) / Math.max(to - from, 1) * plotWidth;
      const y = (value) => pad.top + plotHeight - value / top * plotHeight;

      const root = svg("svg", { width, height, viewBox: `0 0 ${width} ${height}`, class: "chart", role: "img", "aria-label": `${title}, ${points.length ? "drawn over time" : "nothing recorded"}` });
      root.setAttribute("tabindex", "0");
      for (let i = 0; i <= 4; i++) {
        const value = top / 4 * i, at = y(value);
        root.append(svg("line", { x1: pad.left, x2: width - pad.right, y1: at, y2: at, class: "grid" }));
        const label = svg("text", { x: pad.left - 8, y: at + 4, class: "tick", "text-anchor": "end" });
        label.textContent = format(value, top);
        root.append(label);
      }
      for (const tick of timeTicks(from, to, Math.max(2, Math.floor(plotWidth / 90)))) {
        const label = svg("text", { x: x(tick), y: height - 6, class: "tick", "text-anchor": "middle" });
        label.textContent = tickLabel(tick);
        root.append(label);
      }

      // A run of points closer than a step and a half to each other is drawn as one line.
      const runs = (one) => {
        const all = [];
        let run = [];
        let last = null;
        for (const point of points) {
          if (last != null && point.time - last > step * 1.5 && run.length) { all.push(run); run = []; }
          last = point.time;
          const value = one.value(point);
          if (value != null) run.push([x(point.time), y(value)]);
        }
        if (run.length) all.push(run);
        return all;
      };
      for (const one of series) {
        for (const run of runs(one)) {
          const line = run.map(([px, py], i) => `${i ? "L" : "M"}${px.toFixed(1)},${py.toFixed(1)}`).join("");
          if (series.length === 1 && run.length > 1) {
            const base = y(0).toFixed(1);
            root.append(svg("path", { d: `${line}L${run.at(-1)[0].toFixed(1)},${base}L${run[0][0].toFixed(1)},${base}Z`, class: `area tone-${one.tone}` }));
          }
          root.append(svg("path", { d: line, class: `line tone-${one.tone}` }));
          // A lone point (one recorded step between gaps) shows as a dot.
          if (run.length === 1) root.append(svg("circle", { cx: run[0][0], cy: run[0][1], r: 3, class: `dot tone-${one.tone}` }));
        }
        const end = [...points].reverse().find((point) => one.value(point) != null);
        if (end) root.append(svg("circle", { cx: x(end.time), cy: y(one.value(end)), r: 4, class: `dot tone-${one.tone}` }));
      }
      if (!points.length) {
        const empty = svg("text", { x: pad.left + plotWidth / 2, y: pad.top + plotHeight / 2, class: "tick", "text-anchor": "middle" });
        empty.textContent = "Nothing recorded in this range";
        root.append(empty);
      }
      const cross = svg("line", { y1: pad.top, y2: pad.top + plotHeight, class: "crosshair hidden" });
      const marks = series.map((one) => svg("circle", { r: 4, class: `dot tone-${one.tone} hidden` }));
      root.append(cross, ...marks);
      frame.querySelector("svg")?.remove();
      frame.prepend(root);
      drawn = { x, y, root, cross, marks, plotWidth };

      const show = (index) => {
        chosen = index;
        if (index == null || !points[index]) {
          cross.classList.add("hidden");
          for (const mark of marks) mark.classList.add("hidden");
          tooltip.classList.add("hidden");
          return;
        }
        const point = points[index], px = x(point.time);
        cross.setAttribute("x1", px);
        cross.setAttribute("x2", px);
        cross.classList.remove("hidden");
        tooltip.replaceChildren(html("div", "chart-time", fullTime.format(point.time)));
        series.forEach((one, i) => {
          const value = one.value(point);
          marks[i].classList.toggle("hidden", value == null);
          if (value != null) { marks[i].setAttribute("cx", px); marks[i].setAttribute("cy", y(value)); }
          const row = html("div", "chart-row");
          row.append(html("i", `key tone-${one.tone}`), html("b", "", value == null ? "–" : format(value)), html("span", "muted", one.label));
          tooltip.append(row);
        });
        tooltip.classList.remove("hidden");
        // Beside the crosshair, on the side with room.
        const left = px + 12 + tooltip.offsetWidth > width ? px - 12 - tooltip.offsetWidth : px + 12;
        tooltip.style.left = `${Math.max(0, left)}px`;
      };
      const nearest = (clientX) => {
        if (!points.length) return null;
        const at = clientX - root.getBoundingClientRect().left;
        let best = 0;
        for (let i = 1; i < points.length; i++) if (Math.abs(x(points[i].time) - at) < Math.abs(x(points[best].time) - at)) best = i;
        return best;
      };
      root.addEventListener("pointermove", (event) => show(nearest(event.clientX)));
      root.addEventListener("pointerleave", () => { if (document.activeElement !== root) show(null); });
      root.addEventListener("blur", () => show(null));
      root.addEventListener("focus", () => show(chosen ?? (points.length ? points.length - 1 : null)));
      root.addEventListener("keydown", (event) => {
        if (!points.length) return;
        const moves = { ArrowLeft: -1, ArrowRight: 1, Home: -Infinity, End: Infinity };
        if (!(event.key in moves)) return;
        event.preventDefault();
        show(Math.min(points.length - 1, Math.max(0, (chosen ?? points.length - 1) + moves[event.key])));
      });
      if (chosen != null && chosen < points.length && document.activeElement === root) show(chosen);
    }

    // A page shown in its place takes the chart out of the document: it stops watching then.
    const resize = new ResizeObserver(() => {
      if (!frame.isConnected) { resize.disconnect(); return; }
      if (frame.clientWidth && Math.abs(frame.clientWidth - (drawn ? Number(drawn.root.getAttribute("width")) : 0)) > 1) draw();
    });
    resize.observe(frame);
    draw();
    return {
      update(points, from, to, step) {
        state = { points, from, to, step };
        chosen = null;
        tooltip.classList.add("hidden");
        draw();
      },
    };
  }

  window.HomeswiftChart = { lineChart };
})();

"""#),
        "chat.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Assistant's chat, on every page of the web UI (plugin pages load it through plugin.js): a sparkle button
// in the header opens a panel where the Assistant answers and acts through the bridge's tools. Each change it
// wants to make shows a card with what would change, and waits for Allow. The mic dictates a message (the
// browser's speech recognition, which needs HTTPS away from localhost); an answer to a spoken message is read
// out.
//
// Motion after Apple's fluid interfaces: the panel comes from its button and goes back to it on one spring
// that any tap or drag can retarget; on a phone it is a sheet that follows the finger, resists past the top
// and closes when a flick would carry it past half its height. Reduced motion cross-fades instead.
(() => {
  "use strict";
  const { $, el, markdown, sparkle, api, jsonView } = HomeswiftCommon;

  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const phone = matchMedia("(max-width: 640px)");
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  // ---- A spring, after Apple's damping ratio and response (no mass, stiffness, damping to tune) ----------

  /// Moves `state.value` to `target` frame by frame from where it is and as fast as it goes, so a new target
  /// mid-flight bends the motion instead of restarting it. `onFrame` draws each value.
  function spring(state, target, { damping = 1, response = 0.35, velocity, onFrame, onRest } = {}) {
    cancelAnimationFrame(state.frame);
    if (velocity !== undefined) state.velocity = velocity;
    if (reducedMotion.matches) {
      state.value = target;
      state.velocity = 0;
      onFrame(target);
      onRest?.();
      return;
    }
    const stiffness = (2 * Math.PI / response) ** 2;
    const friction = 4 * Math.PI * damping / response;
    let last = performance.now();
    const step = (now) => {
      const dt = Math.min((now - last) / 1000, 1 / 30);
      last = now;
      const force = -stiffness * (state.value - target) - friction * state.velocity;
      state.velocity += force * dt;
      state.value += state.velocity * dt;
      if (Math.abs(state.value - target) < 0.001 && Math.abs(state.velocity) < 0.01) {
        state.value = target;
        state.velocity = 0;
        onFrame(target);
        onRest?.();
        return;
      }
      onFrame(state.value);
      state.frame = requestAnimationFrame(step);
    };
    state.frame = requestAnimationFrame(step);
  }

  /// Where a flick comes to rest, as a scroll view decelerates.
  const project = (velocity, rate = 0.998) => (velocity / 1000) * rate / (1 - rate);
  /// The further past the edge, the less the sheet follows.
  const rubberband = (over, size, constant = 0.55) => (over * size * constant) / (size + constant * Math.abs(over));

  // ---- The panel -------------------------------------------------------------------------------------------

  let info = null;      // what /api/assistant answered
  let panel = null;     // the parts, once built
  const openness = { value: 0, velocity: 0, frame: 0 };
  let items = [];
  let nodes = [];
  let running = false;
  let usage = null;
  let spoken = false;   // the running turn started from the mic: read its answer out
  let trigger = null;

  function build() {
    const log = el("div", { class: "chat-log", "aria-live": "polite", "aria-relevant": "additions" });
    const input = el("textarea", { rows: 1, placeholder: "Ask, or tell it what to set up…", "aria-label": "Message to the Assistant", maxLength: 4000 });
    const mic = el("button", { type: "button", class: "chat-mic", "aria-label": "Dictate", title: "Dictate: tap, or hold while you speak" });
    mic.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/></svg>';
    const send = el("button", { type: "submit", class: "chat-send", "aria-label": "Send" });
    send.innerHTML = '<svg class="send-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5M6 11l6-6 6 6"/></svg>'
      + '<svg class="stop-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2"/></svg>';
    const foot = el("p", { class: "chat-foot" });
    // The language spoken to the mic and in which answers are read out; this browser remembers it.
    const languages = [["", "Browser's language"], ["en-US", "English (US)"], ["en-GB", "English (UK)"], ["fr-FR", "Français"], ["de-DE", "Deutsch"],
      ["es-ES", "Español"], ["it-IT", "Italiano"], ["nl-NL", "Nederlands"], ["pt-PT", "Português"], ["pt-BR", "Português (Brasil)"],
      ["sv-SE", "Svenska"], ["da-DK", "Dansk"], ["nb-NO", "Norsk"], ["fi-FI", "Suomi"], ["pl-PL", "Polski"], ["ja-JP", "日本語"], ["zh-CN", "中文"]];
    let stored = "";
    try { stored = localStorage.getItem("homeswift.voiceLanguage") || ""; } catch {}
    const languagePicker = el("select", { class: "popup", "aria-label": "Voice language" },
      languages.map(([value, text]) => el("option", { value, text, selected: value === stored })));
    languagePicker.addEventListener("change", () => { try { localStorage.setItem("homeswift.voiceLanguage", languagePicker.value); } catch {} });
    const voice = Recognition ? el("div", { class: "chat-voice" }, el("span", { text: "Voice" }), languagePicker) : null;
    const form = el("form", { class: "chat-composer", onsubmit: (event) => { event.preventDefault(); running ? stop() : submit(); } },
      input, Recognition ? mic : null, send);
    const close = el("button", { type: "button", class: "chat-icon", "aria-label": "Close", title: "Close (Esc)", text: "×", onclick: () => toggle(false) });
    const fresh = el("button", { type: "button", class: "chat-icon", "aria-label": "New chat", title: "New chat", onclick: reset });
    fresh.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h8M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>';
    const head = el("div", { class: "chat-head" },
      el("span", { class: "chat-grabber", "aria-hidden": "true" }),
      sparkle(), el("strong", { id: "chat-title", text: "Assistant" }), el("span", { class: "chat-model", text: info.model || "" }),
      el("span", { class: "spacer" }), fresh, close);
    const sheet = el("section", { class: "chat", role: "dialog", "aria-labelledby": "chat-title", hidden: true },
      el("div", { class: "chat-glow", "aria-hidden": "true" }),
      el("div", { class: "chat-surface" }, head, log, form, voice, foot));
    const scrim = el("div", { class: "chat-scrim", hidden: true, onclick: () => toggle(false) });
    document.body.append(scrim, sheet);
    panel = { sheet, scrim, log, input, mic, send, foot, head, languagePicker };

    input.addEventListener("input", grow);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) { event.preventDefault(); form.requestSubmit(); }
    });
    sheet.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { event.preventDefault(); listening ? stopListening(true) : toggle(false); }
    });
    if (Recognition) setUpMic();
    setUpDrag();
    renderControls();
  }

  /// The text field grows with what is typed, up to a few lines.
  function grow() {
    panel.input.style.height = "auto";
    panel.input.style.height = `${Math.min(panel.input.scrollHeight, 140)}px`;
  }

  const isOpen = () => panel && !panel.sheet.hidden && openness.target === 1;

  /// The panel at `value` (0 closed, 1 open). It fades through `--open` on its surface, never through its own
  /// opacity: an ancestor with opacity would keep the surface's backdrop blur from seeing the page.
  function draw(value) {
    const { sheet, scrim } = panel;
    const fade = (amount) => sheet.style.setProperty("--open", String(Math.max(0, Math.min(1, amount))));
    if (reducedMotion.matches) {
      sheet.style.transform = "";
      fade(value);
    } else if (phone.matches) {
      sheet.style.transform = `translateY(${(1 - value) * 100}%)`;
      fade(1);
    } else {
      // Out of the button and back into it: a small move toward it, a slight scale, the material arriving.
      sheet.style.transform = `translate(${(1 - value) * 24}px, ${(1 - value) * -12}px) scale(${0.94 + 0.06 * value})`;
      fade(value * 1.4);
    }
    scrim.style.opacity = String(Math.max(0, Math.min(1, value)) * (phone.matches ? 1 : 0));
  }

  async function toggle(open = !isOpen(), velocity) {
    if (!panel) build();
    openness.target = open ? 1 : 0;
    const { sheet, scrim } = panel;
    trigger?.setAttribute("aria-expanded", String(open));
    if (open) {
      sheet.hidden = false;
      scrim.hidden = !phone.matches;
      if (openness.value === 0) draw(0);
      load();
      setTimeout(() => panel.input.focus({ preventScroll: true }), 50);
    } else if (listening) {
      stopListening(true);
    }
    spring(openness, openness.target, {
      damping: velocity ? 0.8 : 1, response: phone.matches ? 0.32 : 0.3, velocity, onFrame: draw,
      onRest: () => {
        if (openness.target === 0) {
          sheet.hidden = true;
          scrim.hidden = true;
          trigger?.focus({ preventScroll: true });
        }
      },
    });
  }

  /// The phone sheet follows a drag on its head: 1:1, softer past the top, and a flick decides.
  function setUpDrag() {
    const { head, sheet } = panel;
    head.addEventListener("pointerdown", (event) => {
      if (!phone.matches || event.target.closest("button")) return;
      head.setPointerCapture(event.pointerId);
      cancelAnimationFrame(openness.frame);
      const height = sheet.getBoundingClientRect().height;
      const startY = event.clientY;
      const startValue = openness.value;
      let samples = [{ y: event.clientY, t: event.timeStamp }];
      const move = (moveEvent) => {
        let value = startValue - (moveEvent.clientY - startY) / height;
        if (value > 1) value = 1 + rubberband(value - 1, 1);
        openness.value = value;
        draw(value);
        samples = [...samples.slice(-4), { y: moveEvent.clientY, t: moveEvent.timeStamp }];
      };
      const end = () => {
        head.removeEventListener("pointermove", move);
        head.removeEventListener("pointerup", end);
        head.removeEventListener("pointercancel", end);
        const first = samples[0], last = samples[samples.length - 1];
        const pxPerSecond = last.t > first.t ? ((last.y - first.y) / (last.t - first.t)) * 1000 : 0;
        const velocity = -pxPerSecond / height;   // openness per second
        const projected = openness.value + project(-pxPerSecond) / height;
        toggle(projected > 0.5, velocity);
      };
      head.addEventListener("pointermove", move);
      head.addEventListener("pointerup", end);
      head.addEventListener("pointercancel", end);
    });
  }

  // ---- The conversation ---------------------------------------------------------------------------------

  let loaded = false;
  async function load() {
    if (loaded) return;
    loaded = true;
    try {
      // The conversation so far, then the run going on, if any.
      await follow(await api("/api/assistant/chat", { stream: true }));
    } catch (e) {
      loaded = false;
      showError(e.message);
    }
    renderControls();
  }

  function page() {
    const path = location.pathname.split("/").filter(Boolean);
    if (path[0] === "plugins" && path.length === 2 && document.querySelector('meta[name="homeswift-plugin"]')) return `plugin page of ${decodeURIComponent(path[1])}`;
    return path[0] || "status";
  }

  async function submit(text = panel.input.value.trim(), byVoice = false) {
    if (!text || running) return;
    panel.input.value = "";
    grow();
    spoken = byVoice;
    window.speechSynthesis?.cancel();
    running = true;
    renderControls();
    try {
      follow(await api("/api/assistant/chat", { method: "POST", body: { text, page: page() }, stream: true }));
    } catch (e) {
      running = false;
      renderControls();
      showError(e.message);
    }
  }

  async function stop() {
    try { await api("/api/assistant/chat/stop", { method: "POST", body: {} }); } catch (e) { showError(e.message); }
  }

  async function reset() {
    if (running) await stop();
    try { await api("/api/assistant/chat", { method: "DELETE" }); } catch (e) { showError(e.message); return; }
    setItems([], false);
    usage = null;
    renderControls();
    panel.input.focus();
  }

  /// Reads a run's event stream: a snapshot, then items, text and the end.
  async function follow(response) {
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    running = true;
    renderControls();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let end;
        while ((end = buffer.indexOf("\n\n")) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const event = frame.match(/^event: (.*)$/m)?.[1];
          const data = frame.match(/^data: (.*)$/m)?.[1];
          if (event && data) handle(event, JSON.parse(data));
        }
      }
    } catch (e) {
      showError(`The connection dropped: ${e.message}`);
    }
    running = false;
    renderControls();
  }

  function handle(event, data) {
    switch (event) {
    case "snapshot": setItems(data.items, data.running); if (data.usage) usage = data.usage; break;
    case "item": items[data.index] = data.item; renderItem(data.index); break;
    case "delta": {
      const item = items[data.index];
      if (item) { item.text += data.text; scheduleText(data.index); }
      break;
    }
    case "done":
      usage = data.usage;
      if (spoken) speak(items.findLast((item) => item.kind === "assistant")?.text);
      spoken = false;
      break;
    }
  }

  // ---- Drawing the conversation --------------------------------------------------------------------------

  function setItems(next, isRunning) {
    items = next.slice();
    running = isRunning;
    nodes = [];
    panel.log.replaceChildren();
    if (!items.length) panel.log.append(welcome());
    items.forEach((_, index) => renderItem(index, false));
    renderControls();
    scrollToEnd(true);
  }

  /// Suggestions for an empty conversation.
  function welcome() {
    const suggestions = ["Add a device for me", "What does my bridge run?", "Why is an accessory not responding?", "Turn off every light"];
    return el("div", { class: "chat-welcome" },
      sparkle(),
      el("h2", { text: "What can I do for you?" }),
      el("p", { class: "muted", text: "I can look at your bridge, set up a device with its plugin, or change a setting. I ask before I change anything." }),
      el("div", { class: "chat-suggestions" }, suggestions.map((text) => el("button", { type: "button", text, onclick: () => submit(text) }))));
  }

  function renderItem(index, scroll = true) {
    const item = items[index];
    if (!item) return;
    panel.log.querySelector(".chat-welcome")?.remove();
    const node = itemNode(item);
    const old = nodes[index];
    if (old) old.replaceWith(node); else panel.log.append(node);
    nodes[index] = node;
    renderControls();
    if (scroll) scrollToEnd();
  }

  // Streaming text is drawn once per frame, however many pieces arrive.
  const pendingText = new Set();
  function scheduleText(index) {
    if (!pendingText.size) requestAnimationFrame(() => {
      for (const i of pendingText) {
        const body = nodes[i]?.querySelector(".chat-text");
        if (body) body.replaceChildren(...markdown(items[i].text).childNodes);
      }
      pendingText.clear();
      scrollToEnd();
    });
    pendingText.add(index);
  }

  function itemNode(item) {
    switch (item.kind) {
    case "user":
      return el("div", { class: "chat-user" }, el("p", { text: item.text }));
    case "assistant":
      return el("div", { class: "chat-answer" }, el("div", { class: "chat-text md" }, ...markdown(item.text).childNodes));
    case "tool":
      return el("div", { class: `chat-step ${item.state}`, title: item.name },
        el("span", { class: "chat-step-mark", "aria-hidden": "true" }),
        el("span", {}, el("span", { class: "chat-step-title", text: item.title }), item.summary ? el("span", { class: "chat-step-summary", text: ` · ${item.summary}` }) : null),
        el("span", { class: "visually-hidden", text: { running: " (running)", failed: " (failed)", declined: " (not allowed)" }[item.state] ?? " (done)" }));
    case "confirm":
      return confirmCard(item);
    default:
      return el("p", { class: "chat-error", role: "alert", text: item.text });
    }
  }

  /// A change the Assistant wants to make: what it is in words, the details on demand, and the choice.
  function confirmCard(item) {
    const pending = item.state === "pending";
    const answer = (allow) => async (event) => {
      event.currentTarget.closest(".chat-confirm").querySelectorAll("button").forEach((button) => { button.disabled = true; });
      try { await api("/api/assistant/chat/confirm", { method: "POST", body: { id: item.id, allow } }); } catch (e) { showError(e.message); }
    };
    const changes = changeList(item.preview);
    const details = el("details", {},
      el("summary", { text: changes ? "The whole request" : item.preview !== undefined ? "What would change" : "Details" }),
      jsonView(changes ? item.arguments : item.preview ?? item.arguments));
    return el("div", { class: `chat-confirm ${item.state}` },
      el("div", { class: "chat-confirm-head" }, el("strong", { text: describe(item) }),
        pending ? null : el("span", { class: `pill status ${item.state === "allowed" ? "on" : "standby"}`, text: item.state === "allowed" ? "Allowed" : "Not allowed" })),
      el("p", { text: pending ? `${item.title}. Nothing changes until you allow it.` : item.title }),
      changes,
      details,
      pending ? el("div", { class: "chat-confirm-actions" },
        el("button", { type: "button", text: "Don't allow", onclick: answer(false) }),
        el("button", { type: "button", class: "primary", text: "Allow", onclick: answer(true) })) : null);
  }

  /// What a config dry run would change, a line per setting with its new value; null for other previews.
  function changeList(preview) {
    if (!preview || !Array.isArray(preview.changes) || !preview.config) return null;
    const valueAt = (path) => path.match(/[^.[\]]+/g).reduce((value, key) => value?.[/^\d+$/.test(key) ? Number(key) : key], preview.config);
    const shown = (value) => value === undefined ? "removed" : value === "__REDACTED__" ? "(secret, kept)" : JSON.stringify(value);
    const lines = preview.changes.slice(0, 8).map((path) => el("li", {},
      el("code", { text: path.replace(/^platforms\[\d+\]\./, "") }), " ", el("span", { text: `→ ${shown(valueAt(path))}`.slice(0, 120) })));
    if (preview.changes.length > 8) lines.push(el("li", { class: "muted", text: `and ${preview.changes.length - 8} more` }));
    return lines.length ? el("ul", { class: "chat-changes" }, lines) : el("p", { class: "muted", text: "Nothing would change." });
  }

  /// A change in a sentence, from the tool and its arguments.
  function describe({ tool, arguments: args = {} }) {
    const entry = args.entry || {};
    const settings = Object.keys(args.settings || {});
    switch (tool) {
    case "put_list_entry":
      return `Save “${entry.name || entry.mac || "this entry"}” in ${args.name || args.platform}?`;
    case "patch_config":
      return `Change ${settings.length ? settings.join(", ") : "settings"} of ${args.name || args.platform}?`;
    case "update_config": return "Replace the whole config.json? A backup is kept.";
    case "restore_config": return `Restore config.json from ${args.backup}?`;
    case "restart_bridge": return "Restart homeswift? Connections drop for a few seconds.";
    case "set_security_accessory": return `Set ${args.characteristic} to ${JSON.stringify(args.value)} on ${args.id}?`;
    default: return `Allow ${tool}?`;
    }
  }

  function showError(text) {
    if (!panel) return;
    panel.log.append(el("p", { class: "chat-error", role: "alert", text }));
    scrollToEnd();
  }

  /// Keeps the newest line in view, unless the person scrolled up to read.
  function scrollToEnd(force = false) {
    const { log } = panel;
    if (force || log.scrollHeight - log.scrollTop - log.clientHeight < 120) log.scrollTop = log.scrollHeight;
  }

  /// The send button turns into stop while the Assistant works; the glow turns around the panel meanwhile.
  function renderControls() {
    if (!panel) return;
    const { sheet, send, foot, log } = panel;
    sheet.classList.toggle("working", running);
    log.setAttribute("aria-busy", String(running));
    send.classList.toggle("stop", running);
    send.setAttribute("aria-label", running ? "Stop" : "Send");
    send.title = running ? "Stop" : "Send (Enter)";
    const waiting = running && !items.some((item) => item.kind === "confirm" && item.state === "pending") && items[items.length - 1]?.kind !== "assistant";
    let thinking = log.querySelector(".chat-thinking");
    if (waiting && !thinking) log.append(thinking = el("p", { class: "chat-thinking", text: "Thinking…" }));
    if (waiting) log.append(thinking);   // stays last
    if (!waiting) thinking?.remove();
    const cost = usage && usage.cost != null && usage.cost > 0 ? ` · $${usage.cost < 0.01 ? usage.cost.toFixed(4) : usage.cost.toFixed(2)} so far` : "";
    foot.textContent = listening ? "Listening… tap the mic again when you are done." : voiceNote || `${info.provider || "Assistant"}${cost}. Changes always ask first.`;
  }

  // ---- Voice ------------------------------------------------------------------------------------------------

  let recognition = null;
  let listening = false;
  let voiceNote = "";

  function setUpMic() {
    const { mic } = panel;
    if (!window.isSecureContext) {
      mic.classList.add("unavailable");
      mic.title = "Voice needs HTTPS: turn on https in the HomeswiftUI settings, or open this page on localhost.";
    }
    let pressedAt = 0;
    mic.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      pressedAt = event.timeStamp;
      if (!listening) startListening();
      else stopListening(false);
    });
    // Held down and let go: push to talk. A tap keeps listening until the next tap or a pause.
    mic.addEventListener("pointerup", (event) => {
      if (listening && event.timeStamp - pressedAt > 400) stopListening(false);
    });
    mic.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); listening ? stopListening(false) : startListening(); }
    });
  }

  function startListening() {
    if (!window.isSecureContext) {
      voiceNote = "Voice needs HTTPS here: turn on https in Plugins › HomeswiftUI › Settings (or open the page on localhost).";
      renderControls();
      return;
    }
    if (running) return;
    voiceNote = "";
    window.speechSynthesis?.cancel();
    recognition = new Recognition();
    recognition.lang = voiceLanguage();
    recognition.interimResults = true;
    recognition.continuous = false;
    const before = panel.input.value ? `${panel.input.value} ` : "";
    let finalText = "";
    recognition.onresult = (event) => {
      let interim = "";
      finalText = "";
      for (const result of event.results) {
        if (result.isFinal) finalText += result[0].transcript; else interim += result[0].transcript;
      }
      panel.input.value = before + finalText + interim;
      grow();
    };
    recognition.onerror = (event) => {
      voiceNote = event.error === "not-allowed" || event.error === "service-not-allowed"
        ? "The browser did not allow the microphone for this page."
        : event.error === "no-speech" ? "Nothing was heard. Tap the mic and speak." : `Voice stopped: ${event.error}.`;
    };
    recognition.onend = () => {
      const send = recognition?.sendWhenDone !== false;
      listening = false;
      recognition = null;
      panel.sheet.classList.remove("listening");
      renderControls();
      const text = panel.input.value.trim();
      if (send && finalText.trim() && text) submit(text, true);
    };
    try {
      recognition.start();
    } catch (e) {
      voiceNote = `Voice did not start: ${e.message}`;
      renderControls();
      return;
    }
    listening = true;
    panel.sheet.classList.add("listening");
    renderControls();
  }

  /// `cancel` keeps the words in the field without sending them.
  function stopListening(cancel) {
    if (!recognition) return;
    recognition.sendWhenDone = !cancel;
    recognition.stop();
  }

  /// An answer to a spoken message, read out: plain text, without Markdown's marks.
  function speak(text) {
    if (!text || !window.speechSynthesis) return;
    const plain = text.replace(/```[\s\S]*?```/g, "").replace(/[*_`#>]/g, "").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
    const utterance = new SpeechSynthesisUtterance(plain);
    utterance.lang = voiceLanguage();
    speechSynthesis.speak(utterance);
  }

  // ---- The button in the header -----------------------------------------------------------------------------

  async function mount() {
    try {
      info = await api("/api/assistant");
    } catch { return; }
    if (!info.enabled) return;
    const header = $("header");
    if (!header || header.querySelector(".chat-open")) return;
    trigger = el("button", {
      type: "button", class: "chat-open", "aria-expanded": "false", "aria-haspopup": "dialog", title: "Ask the Assistant",
      onclick: () => toggle(),
    }, sparkle(), el("span", { text: "Assistant" }));
    header.insertBefore(trigger, header.querySelector("#user"));
    phone.addEventListener("change", () => { if (isOpen()) { panel.scrim.hidden = !phone.matches; draw(openness.value); } });
  }

  /// Opens the chat with `text` typed in, for the person to finish and send.
  function ask(text) {
    toggle(true);
    panel.input.value = text;
    grow();
    setTimeout(() => { panel.input.focus(); panel.input.setSelectionRange(text.length, text.length); }, 60);
  }

  /// The language chosen for voice, else the browser's.
  const voiceLanguage = () => panel?.languagePicker.value || navigator.language || "en-US";

  window.HomeswiftChat = { mount, ask, open: () => toggle(true), available: () => Boolean(info?.enabled) };
  // The UI's own page mounts it once signed in; a plugin page is signed in already.
  if (document.querySelector('meta[name="homeswift-plugin"]')) mount();
})();

"""#),
        "common.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// What every page of the web UI shares, the UI's own and plugins' alike: $ and el, which build and find elements;
// the tiles, an icon on a colour, as the Home app draws them; and the Assistant's Markdown and sparkle. Loaded
// before the page's own script.
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
      else if (value === undefined || value === null || value === false) continue;
      else if (key.startsWith("data-") || key.startsWith("aria-")) node.setAttribute(key, value);
      else node[key] = value;
    }
    for (const child of children.flat()) if (child != null) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  };

  // Line icons: 24-unit boxes, round caps, the current colour.
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
    more: '<circle cx="5.5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="18.5" cy="12" r="1.3"/>',
    logs: '<path d="M8 6h12M8 12h12M8 18h8M4 6h.01M4 12h.01M4 18h.01"/>',
    code: '<path d="M8 4c-2 0-3 1-3 3v2c0 1.5-1 3-2.5 3C4 12 5 13.5 5 15v2c0 2 1 3 3 3M16 4c2 0 3 1 3 3v2c0 1.5 1 3 2.5 3-1.5 0-2.5 1.5-2.5 3v2c0 2-1 3-3 3"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
    pause: '<path d="M9 5v14M15 5v14"/>',
    play: '<path d="M8 5.5v13l10-6.5z"/>',
    open: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
    edit: '<path d="M12 20h8M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
    inputs: '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8M12 17v4"/>',
    camera: '<rect x="2.5" y="6" width="13.5" height="12" rx="2.5"/><path d="m16 10.5 5.5-3.5v10L16 13.5"/>',
    identify: '<circle cx="12" cy="12" r="2.5"/><path d="M7.5 7.5a6.4 6.4 0 0 0 0 9M16.5 7.5a6.4 6.4 0 0 1 0 9"/>',
  };

  /// An icon as an SVG element.
  function icon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.innerHTML = icons[name] ?? icons.generic;
    return svg;
  }

  /// A tile: the icon on a colour (`tone-orange`, `-blue`, `-violet`, `-green`, `-teal`, `-yellow`, `-grey`);
  /// `large` for a page's heading.
  const tile = (name, tone = "orange", large = false) =>
    el("span", { class: `tile tone-${tone}${large ? " large" : ""}`, "aria-hidden": "true" }, icon(name));

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

  // ---- A menu of actions, after a macOS pull-down menu --------------------------------------------------
  // It grows out of its button and goes back into it; the arrow keys move between items, Escape and a click
  // elsewhere close it, and focus returns to the button.

  let openMenu = null;

  /// Opens a menu under `trigger`. Each item: { label, icon (a name or a node), href or onSelect, danger }.
  /// Opened from the keyboard, its first item takes the focus; from a click, the menu does, so no item looks
  /// chosen before the pointer or an arrow key gets to it.
  function menu(trigger, items, { keyboard = false } = {}) {
    if (openMenu?.trigger === trigger) { openMenu.close(); return; }
    openMenu?.close(true);
    const entries = items.filter(Boolean).map((item) => {
      const glyph = typeof item.icon === "string" ? icon(item.icon) : item.icon ?? null;
      const node = item.href
        ? el("a", { role: "menuitem", href: item.href, class: item.danger ? "danger" : "", tabIndex: -1 }, glyph, el("span", { text: item.label }))
        : el("button", { type: "button", role: "menuitem", class: item.danger ? "danger" : "", tabIndex: -1 }, glyph, el("span", { text: item.label }));
      node.addEventListener("click", () => { close(); item.onSelect?.(); });
      return node;
    });
    const list = el("div", { class: "menu", role: "menu", tabIndex: -1, "aria-label": trigger.getAttribute("aria-label") || "Actions" }, entries);
    document.body.append(list);
    // Under the button, its right edges aligned, inside the window; above it when there is no room below.
    const box = trigger.getBoundingClientRect();
    const width = list.offsetWidth, height = list.offsetHeight;
    const below = box.bottom + 6 + height < innerHeight;
    list.style.left = `${Math.max(8, Math.min(innerWidth - width - 8, box.right - width))}px`;
    list.style.top = `${below ? box.bottom + 6 : box.top - 6 - height}px`;
    list.style.transformOrigin = `${box.right - parseFloat(list.style.left) - box.width / 2}px ${below ? "0" : "100%"}`;
    trigger.setAttribute("aria-expanded", "true");
    const focusAt = (index) => entries[(index + entries.length) % entries.length]?.focus();
    const onKey = (event) => {
      const index = entries.indexOf(document.activeElement);
      if (event.key === "Escape") { event.preventDefault(); close(); }
      else if (event.key === "ArrowDown") { event.preventDefault(); focusAt(index + 1); }
      else if (event.key === "ArrowUp") { event.preventDefault(); focusAt(index < 0 ? -1 : index - 1); }
      else if (event.key === "Home") { event.preventDefault(); focusAt(0); }
      else if (event.key === "End") { event.preventDefault(); focusAt(-1); }
      else if (event.key === "Tab") close(true);
    };
    const onPointer = (event) => { if (!list.contains(event.target) && !trigger.contains(event.target)) close(true); };
    function close(quietly = false) {
      if (openMenu?.list !== list) return;
      openMenu = null;
      document.removeEventListener("keydown", onKey, true);
      document.removeEventListener("pointerdown", onPointer, true);
      removeEventListener("resize", onResize);
      trigger.setAttribute("aria-expanded", "false");
      list.classList.add("closing");
      setTimeout(() => list.remove(), 160);
      if (!quietly) trigger.focus({ preventScroll: true });
    }
    const onResize = () => close(true);
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("pointerdown", onPointer, true);
    addEventListener("resize", onResize);
    openMenu = { trigger, list, close };
    if (keyboard) focusAt(0); else list.focus({ preventScroll: true });
  }

  /// A round icon button that opens `menu` with what `items()` gives when pressed.
  const menuButton = (label, items) => {
    const button = el("button", { type: "button", class: "icon-button menu-button", "aria-label": label, title: label, "aria-haspopup": "menu", "aria-expanded": "false" }, icon("more"));
    // A click from the keyboard (Enter, Space) has no pointer position: detail is 0.
    button.addEventListener("click", (event) => { event.stopPropagation(); menu(button, items(), { keyboard: event.detail === 0 }); });
    return button;
  };

  /// The UI's API, with the session cookie: `body` is an object, sent as JSON; a refusal carries the server's
  /// message and its `status`, and a signed-out visitor goes to the sign-in page. `stream: true` answers the Response itself,
  /// for a body read as it arrives.
  async function api(path, { method = "GET", body, stream = false } = {}) {
    const options = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = JSON.stringify(body); }
    const response = await fetch(path, options);
    if (response.status === 401) { location.href = "/"; throw new Error("signed out"); }
    if (stream && response.ok) return response;
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { error: text }; }
    if (!response.ok) throw Object.assign(new Error((json && json.error) || `HTTP ${response.status}`), { status: response.status });
    return json;
  }

  /// Puts `text` on the clipboard. The Clipboard API exists only over HTTPS or on localhost; a page on the
  /// network over plain HTTP copies through a hidden text field instead.
  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    const field = el("textarea", { value: text, readOnly: true, style: "position:fixed;top:-1000px;opacity:0" });
    document.body.append(field);
    field.select();
    const copied = document.execCommand("copy");
    field.remove();
    if (!copied) throw new Error("The browser did not allow copying.");
  }

  // ---- JSON, coloured -----------------------------------------------------------------------------------
  // Keys, strings, numbers, true, false and null each in a colour; punctuation quiet. Text nodes only, never HTML.

  const jsonToken = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false)\b|\b(null)\b|([{}[\],:])/g;

  /// `text` (JSON, or almost: it is being typed) as coloured spans.
  function jsonHighlight(text) {
    const fragment = document.createDocumentFragment();
    let last = 0;
    for (const match of text.matchAll(jsonToken)) {
      if (match.index > last) fragment.append(text.slice(last, match.index));
      const [whole, string, colon, number, boolean, nil] = match;
      const kind = string ? (colon ? "key" : "string") : number ? "number" : boolean ? "bool" : nil ? "null" : "punct";
      fragment.append(el("span", { class: `json-${kind}`, text: string && colon ? string : whole }));
      if (string && colon) fragment.append(el("span", { class: "json-punct", text: colon }));
      last = match.index + whole.length;
    }
    if (last < text.length) fragment.append(text.slice(last));
    return fragment;
  }

  /// A value shown as indented, coloured JSON.
  const jsonView = (value, attrs = {}) => el("pre", { class: "json", ...attrs }, jsonHighlight(JSON.stringify(value, null, 2) ?? ""));

  /// Colours a JSON textarea as it is typed: a coloured copy of its text sits under it, the textarea's own
  /// text transparent, so editing, selection and undo stay the browser's. Returns the wrapper to show.
  function jsonEditor(textarea) {
    const layer = el("pre", { class: "code-layer", "aria-hidden": "true" });
    const wrapper = el("div", { class: "code-editor" }, layer, textarea);
    textarea.classList.add("code-input");
    let scheduled = false;
    const paint = () => {
      scheduled = false;
      // A final newline needs a character after it to take its line.
      layer.replaceChildren(jsonHighlight(textarea.value), "\n");
      layer.scrollTop = textarea.scrollTop;
      layer.scrollLeft = textarea.scrollLeft;
    };
    const schedule = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(paint); } };
    textarea.addEventListener("input", schedule);
    textarea.addEventListener("scroll", () => { layer.scrollTop = textarea.scrollTop; layer.scrollLeft = textarea.scrollLeft; });
    wrapper.repaint = paint;
    paint();
    return wrapper;
  }

  /// A labelled value in a `.facts` grid: the label small, the value bold with its full text as a tooltip.
  const fact = (label, value, attrs = {}) =>
    el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: String(value), title: String(value), ...attrs }));

  // ---- The sections, and the tab bar a phone shows them in -----------------------------------------------

  const sections = [["/status", "Status", "bridge"], ["/accessories", "Accessories", "bulb"], ["/plugins", "Plugins", "plugin"], ["/config", "Config", "code"], ["/logs", "Logs", "logs"]];

  /// The sections at the bottom of a phone's screen, within the thumb's reach, as iOS puts them: an icon and
  /// a label each, the current one in the accent. `parent` is what hides it with the app (the sign-in screen has
  /// none). Hidden on wider windows, where the header holds them.
  function tabBar({ active, parent = document.body } = {}) {
    const existing = document.querySelector("nav.tabbar");
    if (existing) return existing;
    const bar = el("nav", { class: "tabbar", "aria-label": "Sections" }, sections.map(([path, text, glyph]) =>
      el("a", { href: path, class: path === active ? "active" : "", "aria-current": path === active ? "page" : null }, icon(glyph), el("span", { text }))));
    parent.append(bar);
    return bar;
  }

  /// A name as a path segment, as the server makes them (Slug.swift): lower case, accents dropped, anything but
  /// letters and digits as one dash.
  const slug = (text) => String(text).normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

  /// Gives each item of `list` a `slug` from its name, unique in the list (a second "Lamp" is lamp-2); answers
  /// the list.
  function withSlugs(list, fallback = "item") {
    const taken = new Set();
    for (const item of list) {
      const base = slug(item.name) || fallback;
      let candidate = base;
      for (let n = 2; taken.has(candidate); n++) candidate = `${base}-${n}`;
      taken.add(candidate);
      item.slug = candidate;
    }
    return list;
  }

  /// Pauses or resumes a plugin instance: `_paused` in its block of config.json, applied at once. Paused, the
  /// plugin does not run, so it makes no call to its devices or their cloud (an app sharing the account keeps its
  /// session); its accessories stay in HomeKit, showing No Response.
  async function setPaused(platform, name, paused) {
    const path = `/api/config/block/${encodeURIComponent(platform)}/${encodeURIComponent(name)}`;
    const block = await api(path);
    if (paused) block._paused = true; else delete block._paused;
    return api(path, { method: "PUT", body: block });
  }

  window.HomeswiftCommon = { $, el, icon, tile, fact, markdown, sparkle, api, menuButton, copyText, jsonHighlight, jsonView, jsonEditor, sections, tabBar, setPaused, slug, withSlugs };
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
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#e9edf6" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0f1218" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Homeswift">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
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
    <a class="brand" href="/"><img src="/icon.svg" class="logo" alt="">Homeswift</a>
    <nav>
      <a href="/status">Status</a>
      <a href="/accessories">Accessories</a>
      <a href="/plugins">Plugins</a>
      <a href="/config">Config</a>
      <a href="/logs">Logs</a>
    </nav>
    <span class="spacer"></span>
    <a id="user" href="/account" title="Your account: change the password"></a>
    <button id="logout" class="link">Sign out</button>
  </header>
  <div id="banner" class="banner hidden">Some changes need a restart of homeswift. <button id="restart" class="link">Restart now</button></div>
  <main id="view"></main>
</div>
<script src="/common.js"></script>
<script src="/remote.js"></script>
<script src="/camera.js"></script>
<script src="/charts.js"></script>
<script src="/chat.js"></script>
<script src="/app.js"></script>
</body>
</html>

"""#),
        "plugin.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// For a plugin's own pages, served at /plugins/<slug> after common.js: homeswift.request() talks to the plugin
// instance the server names in the page (<meta name="homeswift-plugin">), with the session cookie; homeswift.el(), .$(), .tile() and .fact() are
// the UI's own (common.js). A signed-out visitor is sent to the login page.
(() => {
  "use strict";
  const instance = document.querySelector('meta[name="homeswift-plugin"]')?.dataset ?? {};
  const platform = instance.platform || "";
  const name = instance.name || platform;
  /// The page's address, /plugins/<slug>: its Expert part is below it.
  const address = `/plugins/${location.pathname.split("/")[2] || ""}`;
  const prefix = `/api/plugins/${encodeURIComponent(platform)}/${encodeURIComponent(name)}/`;

  const { $, el, icon, tile, fact, markdown, sparkle, api } = HomeswiftCommon;

  /// This plugin instance's own routes (its handleWebRequest).
  const request = (path, options) => api(prefix + String(path).replace(/^\//, ""), options);

  // The Assistant, when config.json has a HomeswiftAiKit block that works: pages offer "Explain" next to errors.
  let assistantState = null;
  const assistant = () => (assistantState ??= api("/api/assistant").catch(() => ({ enabled: false })));

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
        entry.pending = api("/api/assistant/explain", { method: "POST", body: { error, context, device, plugin: platform } })
          .then((json) => { explanations.set(error, { text: json.text, model: json.model }); })
          .catch((e) => { explanations.set(error, { failed: e.message }); });
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
  const sections = HomeswiftCommon.sections;
  const header = $("header");
  if (header) {
    const user = el("a", { id: "user", href: "/account", title: "Your account: change the password" });
    const logout = el("button", { id: "logout", class: "link hidden", text: "Sign out", onclick: async () => {
      try { await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }); } catch {}
      location.href = "/";
    } });
    header.replaceChildren(
      el("a", { class: "brand", href: "/" }, el("img", { src: "/icon.svg", class: "logo", alt: "" }), "Homeswift"),
      el("nav", { "aria-label": "Sections" }, sections.map(([path, text]) => el("a", { href: path, text, class: path === "/plugins" ? "active" : "" }))),
      el("span", { class: "spacer" }), user, logout);
    // On a phone the sections sit in a tab bar at the bottom, as on the UI's own pages; the page also extends
    // under the notch and the home indicator, which the layout pads around.
    HomeswiftCommon.tabBar({ active: "/plugins" });
    const viewport = document.querySelector('meta[name="viewport"]');
    if (viewport && !viewport.content.includes("viewport-fit")) viewport.content += ", viewport-fit=cover";
    // The Assistant's chat, as on the UI's own pages.
    document.head.append(el("script", { src: "/chat.js" }));
    api("/api/auth/state").then((state) => {
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
    const levels = [crumb(el("a", { href: "/plugins", text: "Plugins" }))];
    const pageLevel = name !== pageTitle ? `${pageTitle} · ${name}` : pageTitle;
    levels.push(opened
      ? crumb(el("a", { href: "#", text: pageLevel, onclick: (event) => { event.preventDefault(); opened?.close?.(); } }))
      : crumb(el("span", { text: pageLevel }), true));
    if (opened) levels.push(crumb(el("span", { text: opened.text }), true));
    trail.replaceChildren(...levels);
  }
  const main = $("main");
  if (main) {
    // Pause, at the right of the breadcrumb: the plugin stops calling its devices (an app sharing the account
    // keeps its session) until Resume, which a banner offers while it is paused.
    const toggle = el("button", { type: "button", class: "link pause-toggle hidden" });
    main.prepend(el("nav", { class: "breadcrumb", "aria-label": "Breadcrumb" }, trail, toggle));
    breadcrumb(null);
    api("/api/plugins").then(({ platforms }) => {
      const instance = platforms.find((p) => p.platform === platform && p.name === name);
      if (!instance) return;
      const set = (paused) => act(toggle, () => HomeswiftCommon.setPaused(platform, name, paused).then(() => location.reload()));
      toggle.replaceChildren(icon(instance.paused ? "play" : "pause"), el("span", { text: instance.paused ? "Resume" : "Pause" }));
      toggle.title = instance.paused ? "Run the plugin again" : "Stop the plugin's calls to its devices for now";
      toggle.onclick = () => set(!instance.paused);
      toggle.classList.remove("hidden");
      if (instance.paused) {
        main.querySelector(".breadcrumb").after(el("div", { class: "card page-note paused-note" },
          el("p", {}, el("strong", { text: "Paused. " }), "The plugin makes no calls to its devices, and they show No Response in the Home app. This page needs it running."),
          el("button", { class: "primary", text: "Resume", onclick: (event) => act(event.currentTarget, () => HomeswiftCommon.setPaused(platform, name, false).then(() => location.reload())) })));
      }
    }).catch(() => {});
    // Expert, last on the page once the page's own script has laid it out: the whole block as config.json
    // keeps it, as a form or as JSON, for what the page itself does not set.
    const expert = (mode) => `${address}/expert${mode === "json" ? "/json" : ""}`;
    const section = el("section", { class: "expert", "aria-labelledby": "expert-title" },
      el("div", { class: "section-head" }, el("h2", { id: "expert-title", text: "Expert" })),
      el("div", { class: "card page-note" },
        el("p", { class: "muted", text: "Every setting of this plugin's block, as config.json keeps it, including what this page does not show." }),
        el("div", { class: "expert-links" }, el("a", { class: "button", href: expert("form"), text: "Form" }), el("a", { class: "button", href: expert("json"), text: "JSON" }))));
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => main.append(section));
    else main.append(section);
  }

  // ---- This instance's block of config.json -------------------------------------------------------------
  // Read and written by platform and name: a write applies at once (the plugin reloads), and the page never
  // handles the rest of the file.

  const blockPath = `/api/config/block/${encodeURIComponent(platform)}/${encodeURIComponent(name)}`;

  /// This instance's block of config.json.
  const readBlock = () => api(blockPath);

  /// Changes the block (`change` edits it, or returns its replacement) and writes it; answers what the write
  /// did (applied, or what waits for a restart).
  async function updateBlock(change) {
    const block = await readBlock();
    return api(blockPath, { method: "PUT", body: change(block) ?? block });
  }

  /// A MAC address however it is spelled, octets without their leading zero too, as AA:BB:CC:DD:EE:FF (the
  /// server's MACAddress); anything else comes back trimmed and upper-cased.
  function canonicalMAC(mac) {
    const text = String(mac ?? "").trim();
    const octets = text.split(/[:-]/);
    const digits = octets.length === 6 && octets.every((octet) => /^[0-9a-f]{1,2}$/i.test(octet))
      ? octets.map((octet) => octet.padStart(2, "0")).join("") : text.replace(/[:\-. ]/g, "");
    return /^[0-9a-f]{12}$/i.test(digits) ? digits.toUpperCase().replace(/(..)(?!$)/g, "$1:") : text.toUpperCase();
  }
  const isMAC = (mac) => /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(canonicalMAC(mac));
  const sameMAC = (a, b) => canonicalMAC(a) === canonicalMAC(b);

  /// The block's `devices`, changed in place by `change` and written; an empty list leaves the block.
  function updateDevices(change) {
    return updateBlock((block) => {
      const devices = block.devices || [];
      change(devices);
      if (devices.length) block.devices = devices; else delete block.devices;
    });
  }

  /// One device's entry, by MAC: `change` edits it in place, returns its replacement, or returns null to remove it.
  function updateDevice(mac, change) {
    return updateDevices((devices) => {
      const index = devices.findIndex((device) => sameMAC(device.mac, mac));
      if (index < 0) throw new Error("This device is not in the configuration.");
      const replacement = change(devices[index]);
      if (replacement === null) devices.splice(index, 1);
      else if (replacement) devices[index] = replacement;
    });
  }

  /// Adds an entry, or replaces the one with its MAC.
  const putDevice = (entry) => updateDevices((devices) => {
    const index = devices.findIndex((device) => sameMAC(device.mac, entry.mac));
    if (index >= 0) devices[index] = entry; else devices.push(entry);
  });

  /// The entry of a device in the block, or null.
  const findDevice = async (mac) => ((await readBlock()).devices || []).find((device) => sameMAC(device.mac, mac)) ?? null;

  /// Sets a key of a draft entry, or removes it when it holds the default: config.json keeps what was chosen.
  function setKey(draft, key, value, fallback) {
    if (value === undefined || value === "" || value === fallback) delete draft[key]; else draft[key] = value;
  }

  /// Calls `refresh` now and every `interval` while the page is visible.
  function poll(refresh, interval = 2000) {
    let timer = null;
    const start = () => { if (timer) return; refresh(); timer = setInterval(refresh, interval); };
    const stop = () => { clearInterval(timer); timer = null; };
    document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
    start();
  }

  /// One card per item in `list`, by key: a card is drawn again only when its own item changed, so the others
  /// keep their focus, what is open in them and their place. Anything else in the list goes.
  function renderKeyed(list, items, keyOf, render) {
    const previous = new Map([...list.children].filter((node) => node.dataset.key).map((node) => [node.dataset.key, node]));
    const nodes = items.map((item) => {
      const key = String(keyOf(item));
      const json = JSON.stringify(item);
      const old = previous.get(key);
      if (old && old.dataset.json === json) return old;
      const node = render(item);
      node.dataset.key = key;
      node.dataset.json = json;
      return node;
    });
    nodes.forEach((node, index) => { if (list.children[index] !== node) list.insertBefore(node, list.children[index] ?? null); });
    while (list.children.length > nodes.length) list.lastElementChild.remove();
  }

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; answers what `work`
  /// answers. Errors go to `report`; with `report` null they are thrown to the caller once the button is back.
  async function act(button, work, report = alert) {
    button.disabled = true;
    const spin = setTimeout(() => button.classList.add("busy"), 150);
    try {
      return await work();
    } catch (e) {
      if (report === null) throw e;
      report(e.message);
    } finally {
      clearTimeout(spin);
      button.classList.remove("busy");
      button.disabled = false;
    }
  }

  window.homeswift = {
    platform, name, request, home: "/plugins", $, el, icon, tile, fact, assistant, explain, breadcrumb, api, act,
    readBlock, updateBlock, updateDevices, updateDevice, putDevice, findDevice, setKey, poll, renderKeyed,
    canonicalMAC, isMAC, sameMAC,
  };
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
  /* A search field's fill, as iOS's search bars: grey, so it reads on a white card too. */
  --search-fill: rgba(118, 118, 128, 0.14); --search-glyph: rgba(60, 60, 67, 0.6);
  --search-icon: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%238a8a92' stroke-width='2.2' stroke-linecap='round'%3E%3Ccircle cx='10.5' cy='10.5' r='6'/%3E%3Cpath d='m15 15 5 5'/%3E%3C/svg%3E");
  --edge: rgba(255, 255, 255, 0.85); --edge-light: rgba(255, 255, 255, 0.6);
  --shadow-thick: 0 10px 30px rgba(25, 34, 56, 0.16); --shadow: 0 12px 36px rgba(25, 34, 56, 0.12); --shadow-control: 0 2px 8px rgba(25, 34, 56, 0.08);
  --sheen: linear-gradient(180deg, rgba(255, 255, 255, 0.45), rgba(255, 255, 255, 0) 45%);
  --text: #15171c; --muted: #596170; --line: rgba(20, 30, 50, 0.1);
  --accent: #ff7a1a; --accent-2: #ffb15c; --accent-text: #ffffff; --ok: #1f9d55; --warn: #c9731a; --error: #d0383b; --paused: #5856d6;
  /* Chart series, slots 1 and 2 of a palette checked for colour-blind separation and contrast, each mode its own step. */
  --series-1: #2a78d6; --series-2: #eb6834;
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
    --search-fill: rgba(118, 118, 128, 0.26); --search-glyph: rgba(235, 235, 245, 0.6);
    --search-icon: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23a7a7b0' stroke-width='2.2' stroke-linecap='round'%3E%3Ccircle cx='10.5' cy='10.5' r='6'/%3E%3Cpath d='m15 15 5 5'/%3E%3C/svg%3E");
    --edge: rgba(255, 255, 255, 0.16); --edge-light: rgba(255, 255, 255, 0.14);
    --shadow-thick: 0 10px 30px rgba(0, 0, 0, 0.5); --shadow: 0 14px 40px rgba(0, 0, 0, 0.42); --shadow-control: 0 2px 8px rgba(0, 0, 0, 0.3);
    --sheen: linear-gradient(180deg, rgba(255, 255, 255, 0.10), rgba(255, 255, 255, 0) 45%);
    --text: #f3f4f7; --muted: #a2a9b5; --line: rgba(255, 255, 255, 0.1);
    --warn: #e9a04a; --paused: #8e8cff;
    --series-1: #3987e5; --series-2: #d95926;
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
.card, .log, .banner {
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
/* A plugin page's Expert part, last: the block as a form or as JSON, in the UI's own settings view. */
.expert .page-note { flex-wrap: wrap; }
/* A plugin card's name opens its page; Pause sits at the right of a plugin page's breadcrumb. */
.card-title { color: inherit; text-decoration: none; }
.card-title:hover strong { text-decoration: underline; }
.pause-toggle { display: inline-flex; align-items: center; gap: 5px; font-size: 0.8125rem; font-weight: 500; }
.pause-toggle svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.expert-links { display: flex; gap: 8px; flex: none; }
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

/* Plugin pages: a heading with the plugin's tile, card feet with their links, and panels (an editor that opens
   under the cards) with a head and two columns. A button working for a moment shows a spinner (act()). */
.page-head:has(> .tile) { align-items: center; }
.panel { margin-top: 14px; display: grid; gap: 16px; animation: materialize var(--normal) var(--ease-out); scroll-margin-top: 90px; }
.panel-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
.panel-head h2 { margin: 0 0 4px; }
.panel-head p { margin: 0; font-size: 0.8125rem; }
.panel-columns { display: grid; grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); gap: 20px; align-items: start; }
button.busy::after {
  content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
  border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .panel { animation: none; }
  button.busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
}
@media (max-width: 640px) { .panel-columns { grid-template-columns: 1fr; } }

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
.muted { color: var(--muted); }
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
/* Selects as pop-up buttons, after macOS: the platform's arrows replaced by one up-and-down chevron in the
   text's colour, the field's shape kept; a toolbar's (.popup) is a solid pill like the controls next to it. The
   accent ring shows for the keyboard, not for a click. */
:root { --chevron: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 16' fill='none' stroke='%23596170' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M2 6l3-3 3 3M2 10l3 3 3-3'/%3E%3C/svg%3E"); }
@media (prefers-color-scheme: dark) {
  :root { --chevron: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 16' fill='none' stroke='%23a2a9b5' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M2 6l3-3 3 3M2 10l3 3 3-3'/%3E%3C/svg%3E"); }
}
select {
  -webkit-appearance: none; appearance: none; touch-action: manipulation; cursor: pointer; padding-right: 34px;
  background-image: var(--chevron); background-repeat: no-repeat; background-position: right 13px center; background-size: 9px 14px;
  text-overflow: ellipsis; white-space: nowrap; overflow: hidden;
}
select:focus:not(:focus-visible) { border-color: var(--edge); box-shadow: inset 0 1px 2px rgba(25, 34, 56, 0.08); }
select.popup {
  width: auto; border-radius: 999px; padding: 7px 34px 7px 15px; font-weight: 500;
  background-color: var(--control); border-color: var(--edge); box-shadow: var(--shadow-control), inset 0 1px 0 var(--edge-light);
  transition: transform var(--fast) var(--ease-out), box-shadow var(--fast) var(--ease-out), border-color var(--fast) var(--ease-out);
}
select.popup:hover { transform: translateY(-1px); }
select.popup:active { transform: scale(0.97); transition-duration: 80ms; }
select.popup:focus:not(:focus-visible) { border-color: var(--edge); box-shadow: var(--shadow-control), inset 0 1px 0 var(--edge-light); }
select.popup:focus-visible { border-color: var(--accent); box-shadow: 0 0 0 4px rgba(255, 122, 26, 0.18); }
select.popup.chosen { color: var(--accent); }
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
.pill.status.paused { color: var(--paused); border-color: rgba(88, 86, 214, 0.35); }

/* Tiles: an icon on a colour, like the Home app's (common.js's tile()): the accent by default, and tone-* classes
   that no control's class can collide with. */
.tile {
  width: 40px; height: 40px; flex: none; border-radius: 12px; display: flex; align-items: center; justify-content: center; color: #fff;
  background: linear-gradient(160deg, var(--accent-2), var(--accent)); box-shadow: 0 6px 16px rgba(25, 34, 56, 0.18), inset 0 1px 0 rgba(255, 255, 255, 0.4);
}
/* A block of fixed size, centred by flexbox: Safari left an inline SVG at the top of a grid cell. */
.tile svg { display: block; flex: none; width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.tile.large { width: 48px; height: 48px; border-radius: 14px; }
.tile.large svg { width: 26px; height: 26px; }
.tile.tone-violet { background: linear-gradient(160deg, #a78bfa, #7c4ddb); }
.tile.tone-blue { background: linear-gradient(160deg, #4aa3ff, #1f6fe0); }
.tile.tone-grey { background: linear-gradient(160deg, #9aa3b2, #687284); }
.tile.tone-yellow { background: linear-gradient(160deg, #ffd66b, #f0a01e); color: #5c3b00; }
.tile.tone-teal { background: linear-gradient(160deg, #4fd1c5, #1c9c91); }
.tile.tone-green { background: linear-gradient(160deg, #6ee7a0, #23a55a); }

/* Breadcrumb, on plugin pages: where the page sits, each level a way back. */
.breadcrumb { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 2px 0 10px; }
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
.grid > .card { margin: 0; min-width: 0; }
.card.empty { text-align: center; padding: 28px 20px; grid-column: 1 / -1; }
.card.empty p { margin: 0; }
.card.notice { color: var(--warn); font-weight: 500; }
.card.notice p { margin: 0; }
.search { width: 240px; max-width: 100%; }
/* Search fields: a grey pill with a magnifier, the text after it; the edge only on focus. */
input[type=search] {
  -webkit-appearance: none; appearance: none; border-radius: 999px; padding-left: 34px;
  background: var(--search-fill) var(--search-icon) no-repeat 12px center / 16px 16px; border-color: transparent; box-shadow: none;
}
input[type=search]:focus { border-color: var(--accent); box-shadow: 0 0 0 4px rgba(255, 122, 26, 0.18); }
input[type=search]::placeholder { color: var(--search-glyph); }
input[type=search]::-webkit-search-decoration { -webkit-appearance: none; }
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
/* A value wraps anywhere rather than widen its card: no text a device sends can push the page sideways. */
.control .value { min-width: 0; overflow-wrap: anywhere; }
.control .range .value { flex: none; min-width: 3.6em; text-align: right; }
.keys { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; }
.keys button { padding: 5px 11px; font-size: 0.8125rem; }
.more > summary { font-size: 0.8125rem; padding: 4px 0; }
.service-name { font-size: 0.75rem; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted); margin: 12px 0 2px; }
.card-remote { padding: 8px 0 2px; display: flex; justify-content: center; }
.card-foot { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding-top: 10px; border-top: 1px solid var(--line); font-size: 0.8125rem; }
.card-foot .link { padding: 0; font-size: inherit; }
/* A card with a foot, or the catalog's Add: a column whose last row sits at the bottom, so the dividers and
   menus of cards side by side line up whatever each card holds. */
.server:has(> .card-foot), .accessory-card, .server.catalog { display: flex; flex-direction: column; }
.card > .card-foot, .server.catalog > .actions { margin-top: auto; }
.accessory-section + .accessory-section { margin-top: 8px; }

/* Plugins: a card per block; the settings form opens across the grid. */
.server .actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.server.editor { grid-column: 1 / -1; gap: 18px; }
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
.editor-bar .popup { max-width: 240px; }

/* A menu of actions (common.js menu()): thick material over the page, out of its button. */
.menu-button { flex: none; width: 32px; height: 32px; padding: 0; display: grid; place-items: center; border-radius: 50%; }
.menu-button svg { width: 18px; height: 18px; fill: currentColor; stroke: none; }
.menu-button[aria-expanded="true"] { background: var(--material-thin); }
.menu {
  position: fixed; z-index: 30; min-width: 210px; padding: 6px; display: grid; gap: 1px; border-radius: 16px;
  background-color: var(--material-thick); background-image: var(--sheen);
  -webkit-backdrop-filter: blur(var(--blur-thick)) saturate(180%); backdrop-filter: blur(var(--blur-thick)) saturate(180%);
  border: 1px solid var(--edge); box-shadow: 0 18px 44px rgba(25, 34, 56, 0.24), inset 0 1px 0 var(--edge-light);
  animation: menu-in 180ms var(--ease-out);
}
.menu:focus { outline: none; }
.menu.closing { animation: menu-out 140ms var(--ease-out) forwards; pointer-events: none; }
@keyframes menu-in { from { opacity: 0; transform: scale(0.92); } }
@keyframes menu-out { to { opacity: 0; transform: scale(0.95); } }
.menu [role="menuitem"] {
  display: flex; align-items: center; gap: 10px; width: 100%; padding: 8px 12px; border: 0; border-radius: 10px;
  background: none; box-shadow: none; color: var(--text); font: inherit; font-size: 0.875rem; text-align: left; text-decoration: none; cursor: pointer;
}
.menu [role="menuitem"]:hover, .menu [role="menuitem"]:focus-visible { background: var(--accent); color: var(--accent-text); outline: none; transform: none; }
.menu [role="menuitem"].danger { color: var(--error); }
.menu [role="menuitem"].danger:hover, .menu [role="menuitem"].danger:focus-visible { background: var(--error); color: #fff; }
.menu [role="menuitem"] svg { width: 17px; height: 17px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
@media (prefers-reduced-motion: reduce) { .menu, .menu.closing { animation-name: fade; } }
@media (prefers-reduced-transparency: reduce) { .menu { background: var(--material-solid); -webkit-backdrop-filter: none; backdrop-filter: none; } }
/* A custom time range: from and to, under the toolbar, as the material arriving. */
.log-range { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; width: 100%; animation: fade var(--normal) var(--ease-out); }
.log-range label { display: flex; align-items: center; gap: 8px; margin: 0; font-size: 0.8125rem; color: var(--muted); }
.log-range input { width: auto; padding: 6px 12px; border-radius: 999px; font-variant-numeric: tabular-nums; }
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
/* The Status page's activity charts: the filters in one row above them, two charts a row, one on a phone. */
.activity { transition: opacity var(--normal) var(--ease-out); }
.activity.loading .chart-grid { opacity: 0.55; }
.filter-bar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin: 0 0 12px; }
.filter-bar .popup { max-width: 260px; }
.chart-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 420px), 1fr)); gap: 14px; transition: opacity var(--normal) var(--ease-out); }
.chart-card { margin: 0; display: grid; gap: 10px; align-content: start; min-width: 0; }
.chart-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
.chart-head .muted { font-size: 0.8125rem; }
.chart-figure { font-size: 1.375rem; line-height: 1.1; font-weight: 650; letter-spacing: -0.02em; white-space: nowrap; }
.chart-detail { font-size: 0.8125rem; font-variant-numeric: tabular-nums; min-height: 1.2em; }
.chart-body { min-width: 0; }
.chart-frame { position: relative; }
.chart { display: block; max-width: 100%; overflow: visible; border-radius: 8px; }
.chart:focus-visible { outline: 2px solid var(--accent); outline-offset: 4px; }
.chart .grid { stroke: var(--line); stroke-width: 1; shape-rendering: crispEdges; }
.chart .tick { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
.chart .line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
.chart .area { stroke: none; opacity: 0.1; }
.chart .dot { stroke: var(--material-solid); stroke-width: 2; }
.chart .crosshair { stroke: var(--muted); stroke-width: 1; opacity: 0.6; }
.chart .line.tone-1 { stroke: var(--series-1); }
.chart .line.tone-2 { stroke: var(--series-2); }
.chart .area.tone-1, .chart .dot.tone-1 { fill: var(--series-1); }
.chart .area.tone-2, .chart .dot.tone-2 { fill: var(--series-2); }
.chart-legend { display: flex; gap: 14px; font-size: 0.8125rem; color: var(--muted); }
.chart-legend span { display: inline-flex; align-items: center; gap: 6px; }
.chart-legend .key, .chart-tooltip .key { display: inline-block; width: 12px; height: 2px; border-radius: 1px; }
.key.tone-1 { background: var(--series-1); }
.key.tone-2 { background: var(--series-2); }
.chart-tooltip {
  position: absolute; top: 4px; z-index: 2; pointer-events: none; padding: 8px 10px; border-radius: 12px; min-width: 132px;
  background: var(--material-solid); border: 1px solid var(--edge); box-shadow: var(--shadow-control); font-size: 0.8125rem;
}
.chart-tooltip .chart-time { color: var(--muted); margin-bottom: 4px; white-space: nowrap; }
.chart-tooltip .chart-row { display: flex; align-items: center; gap: 8px; white-space: nowrap; }
.chart-tooltip b { font-variant-numeric: tabular-nums; }
.chart-table { margin-top: 12px; }
.chart-table .table-scroll { overflow-x: auto; max-height: 360px; overflow-y: auto; margin-top: 8px; }
.chart-table table { border-collapse: collapse; font-size: 0.8125rem; font-variant-numeric: tabular-nums; white-space: nowrap; }
.chart-table th, .chart-table td { padding: 4px 12px 4px 0; text-align: right; border-bottom: 1px solid var(--line); }
.chart-table th:first-child, .chart-table td:first-child { text-align: left; }
.chart-table th { color: var(--muted); font-weight: 500; position: sticky; top: 0; background: var(--material-solid); }
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
.qr { width: 148px; height: 148px; border-radius: 14px; background: #fff; padding: 6px; box-shadow: var(--shadow-control); }
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
/* Inside the Logs card the list is the card's own content: no second material, corners, edge or shadow. */
.log-card .log { border: 0; border-radius: 0; box-shadow: none; background: none; -webkit-backdrop-filter: none; backdrop-filter: none; }
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
  .card, header, .log, .banner { -webkit-backdrop-filter: none; backdrop-filter: none; }
}
@media (prefers-contrast: more) {
  :root { --material: var(--material-solid); --material-thick: var(--material-solid); --sheen: none; --edge: rgba(20, 30, 50, 0.55); --line: rgba(20, 30, 50, 0.3); --muted: #3a4150; }
  @media (prefers-color-scheme: dark) { :root { --edge: rgba(255, 255, 255, 0.6); --line: rgba(255, 255, 255, 0.3); --muted: #cfd4dc; } }
  .card, header, .log, .banner { -webkit-backdrop-filter: none; backdrop-filter: none; }
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

/* The Assistant's chat (chat.js). On a wide window a panel floats beside the page under the header, no scrim,
   so the page stays usable; on a phone it is a sheet over a scrim, dragged by its head. Thick material like
   the header, controls solid on top; the Apple Intelligence glow turns around the panel only while the
   Assistant works or listens. chat.js moves it on a spring, from the button and back to it. */
.chat-open { display: inline-flex; align-items: center; gap: 6px; padding: 6px 14px 6px 11px; border-radius: 999px; }
.chat-open span {
  font-weight: 600; background: linear-gradient(90deg, #ff9f0a, #ff375f 35%, #bf5af2 70%, #5e5ce6);
  -webkit-background-clip: text; background-clip: text; color: transparent;
}
.chat-open[aria-expanded="true"] { box-shadow: 0 0 0 3px rgba(191, 90, 242, 0.22), var(--shadow-control); }
.chat {
  position: fixed; z-index: 20; top: 84px; right: max(16px, calc((100vw - 1100px) / 2));
  width: min(420px, calc(100vw - 32px)); height: min(740px, calc(100dvh - 100px));
  transform-origin: top right; will-change: transform; isolation: isolate; --open: 1; --glow: 0;
}
.chat-surface {
  position: relative; height: 100%; display: flex; flex-direction: column; overflow: hidden; border-radius: 26px;
  background-color: var(--material-thick); background-image: var(--sheen);
  -webkit-backdrop-filter: blur(var(--blur-thick)) saturate(180%); backdrop-filter: blur(var(--blur-thick)) saturate(180%);
  border: 1px solid var(--edge); box-shadow: 0 24px 64px rgba(25, 34, 56, 0.24), inset 0 1px 0 var(--edge-light);
  opacity: var(--open);
}
.chat-glow {
  position: absolute; inset: -3px; z-index: -1; border-radius: 29px; pointer-events: none;
  background: conic-gradient(from var(--ai-angle), var(--ai-colors)); filter: blur(18px);
  opacity: calc(var(--glow) * var(--open));
}
/* Registered, so the glow eases in and out instead of switching. */
@property --glow { syntax: "<number>"; inherits: true; initial-value: 0; }
.chat { transition: --glow 700ms var(--ease-out); }
.chat.working { --glow: 0.5; }
.chat.listening { --glow: 0.8; }
.chat.working .chat-glow, .chat.listening .chat-glow { animation: ai-turn 3s linear infinite; }
.chat.listening .chat-glow { animation-duration: 2s; }
.chat-scrim { position: fixed; inset: 0; z-index: 19; background: rgba(10, 14, 22, 0.35); opacity: 0; }

.chat-head { position: relative; display: flex; align-items: center; gap: 8px; padding: 14px 12px 10px 18px; }
.chat-head .sparkle { width: 18px; height: 18px; }
.chat-head strong { font-size: 1.0625rem; letter-spacing: -0.015em; }
.chat-model { color: var(--muted); font-size: 0.75rem; letter-spacing: 0.01em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chat-icon { width: 32px; height: 32px; padding: 0; display: grid; place-items: center; border-radius: 50%; font-size: 1.25rem; line-height: 1; }
.chat-icon svg, .chat-mic svg, .chat-send svg { width: 17px; height: 17px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.chat-grabber { display: none; }

.chat-log {
  flex: 1; min-height: 0; overflow-y: auto; overscroll-behavior: contain; padding: 8px 18px 16px;
  display: flex; flex-direction: column; gap: 12px;
  -webkit-mask-image: linear-gradient(transparent, #000 12px, #000 calc(100% - 16px), transparent);
  mask-image: linear-gradient(transparent, #000 12px, #000 calc(100% - 16px), transparent);
}
.chat-log > * { animation: chat-in var(--normal) var(--ease-out); }
@keyframes chat-in { from { opacity: 0; transform: translateY(6px); } }
.chat-user { align-self: flex-end; max-width: 86%; }
.chat-user p {
  margin: 0; padding: 9px 14px; border-radius: 20px 20px 6px 20px; white-space: pre-wrap; overflow-wrap: anywhere;
  background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text);
  box-shadow: 0 6px 16px rgba(255, 122, 26, 0.25), inset 0 1px 0 rgba(255, 255, 255, 0.4);
}
.chat-answer { line-height: 1.55; overflow-wrap: anywhere; }
.chat-answer .chat-text > :last-child { margin-bottom: 0; }
.chat-step { display: flex; align-items: flex-start; gap: 8px; font-size: 0.8125rem; color: var(--muted); line-height: 1.35; }
.chat-step + .chat-step { margin-top: -6px; }
.chat-step-title { color: var(--text); font-weight: 500; }
.chat-step-summary { overflow-wrap: anywhere; }
.chat-step-mark {
  position: relative; flex: none; width: 15px; height: 15px; margin-top: 1px; border-radius: 50%;
  border: 2px solid var(--line); border-top-color: #bf5af2; animation: spin 0.8s linear infinite;
}
.chat-step:is(.done, .failed, .declined) .chat-step-mark { animation: none; border: 0; background: var(--ok); transition: background-color var(--normal) var(--ease-out); }
.chat-step.failed .chat-step-mark { background: var(--error); }
.chat-step.declined .chat-step-mark { background: var(--muted); }
.chat-step.declined .chat-step-mark::after { content: ""; position: absolute; left: 4px; right: 4px; top: 6.5px; height: 2px; border-radius: 1px; background: #fff; }
.chat-step.declined .chat-step-title { color: var(--muted); }
.chat-step.done .chat-step-mark::after {
  content: ""; position: absolute; left: 5px; top: 2.5px; width: 3.5px; height: 7px; border: solid #fff; border-width: 0 2px 2px 0; transform: rotate(45deg);
}
.chat-step.failed .chat-step-mark::after { content: "×"; position: absolute; inset: 0; display: grid; place-items: center; color: #fff; font-size: 12px; font-weight: 700; line-height: 1; }
.chat-thinking {
  margin: 0; font-size: 0.875rem; font-weight: 500;
  background: linear-gradient(90deg, var(--muted) 20%, var(--text) 50%, var(--muted) 80%); background-size: 250% 100%;
  -webkit-background-clip: text; background-clip: text; color: transparent; animation: ai-shimmer 1.8s linear infinite;
}
.chat-error { margin: 0; color: var(--error); font-size: 0.875rem; }

/* A change waiting for the user: solid, set apart by an accent edge, the answer within reach of the thumb. */
.chat-confirm {
  padding: 12px 14px; border-radius: 18px; background: var(--material-solid); border: 1px solid var(--edge);
  box-shadow: var(--shadow-control);
}
.chat-confirm.pending { border-color: rgba(191, 90, 242, 0.45); box-shadow: 0 0 0 3px rgba(191, 90, 242, 0.12), var(--shadow-control); }
.chat-confirm-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.chat-confirm-head strong { font-size: 0.9375rem; letter-spacing: -0.01em; }
.chat-confirm p { margin: 6px 0 4px; font-size: 0.875rem; color: var(--muted); }
.chat-confirm summary { cursor: pointer; font-size: 0.8125rem; color: var(--muted); padding: 2px 0; }
.chat-confirm pre {
  margin: 6px 0 0; max-height: 220px; overflow: auto; padding: 8px 10px; border-radius: 10px;
  font: 0.75rem/1.45 var(--mono); background: var(--material-thin); border: 1px solid var(--line); white-space: pre-wrap; overflow-wrap: anywhere;
}
.chat-changes { margin: 8px 0 6px; padding: 0; list-style: none; font-size: 0.8125rem; display: grid; gap: 4px; }
.chat-changes li { overflow-wrap: anywhere; }
.chat-changes code { font-family: var(--mono); font-size: 0.75rem; padding: 1px 6px; border-radius: 6px; background: var(--material-thin); border: 1px solid var(--line); }
.chat-confirm-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px; }
.chat-confirm-actions button { min-width: 96px; }

.chat-welcome { margin: auto 0; padding: 16px 4px; text-align: center; }
.chat-welcome .sparkle { width: 36px; height: 36px; margin: 0 auto 8px; }
.chat-welcome h2 { margin: 0 0 6px; font-size: 1.3125rem; line-height: 1.2; letter-spacing: -0.02em; }
.chat-welcome p { margin: 0 auto; max-width: 30ch; font-size: 0.875rem; }
.chat-suggestions { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px; margin-top: 16px; }
.chat-suggestions button { border-radius: 999px; padding: 7px 13px; font-size: 0.8125rem; }

.chat-composer {
  display: flex; align-items: flex-end; gap: 6px; margin: 0 12px; padding: 5px 5px 5px 14px; border-radius: 22px;
  background: var(--control); border: 1px solid var(--line); box-shadow: var(--shadow-control);
  transition: border-color var(--fast) var(--ease-out), box-shadow var(--fast) var(--ease-out);
}
.chat-composer:focus-within { border-color: rgba(191, 90, 242, 0.55); box-shadow: 0 0 0 4px rgba(191, 90, 242, 0.14); }
.chat-composer textarea {
  flex: 1; min-height: 0; max-height: 140px; padding: 7px 0; resize: none; border: 0; border-radius: 0; background: none; box-shadow: none;
  font: inherit; white-space: pre-wrap; line-height: 1.4;
}
.chat-composer textarea:focus { box-shadow: none; }
.chat-mic, .chat-send { flex: none; width: 34px; height: 34px; padding: 0; display: grid; place-items: center; border-radius: 50%; }
.chat-mic { border-color: transparent; background: none; box-shadow: none; color: var(--muted); }
.chat-mic:hover { color: var(--text); background: var(--material-thin); transform: none; }
.chat-mic.unavailable { opacity: 0.45; }
.chat.listening .chat-mic {
  color: #fff; background: conic-gradient(from var(--ai-angle), var(--ai-colors)); animation: ai-turn 2s linear infinite;
  box-shadow: 0 0 0 4px rgba(191, 90, 242, 0.2);
}
.chat-send { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: rgba(255, 255, 255, 0.4); }
.chat-send .stop-icon, .chat-send.stop .send-icon { display: none; }
.chat-send.stop .stop-icon { display: block; fill: currentColor; stroke: none; }
.chat-send.stop { background: var(--text); color: var(--material-solid); }
.chat-foot { margin: 7px 16px 12px; min-height: 1.2em; font-size: 0.75rem; color: var(--muted); text-align: center; letter-spacing: 0.01em; }
.visually-hidden { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }

@media (max-width: 640px) {
  .chat { top: auto; bottom: 0; left: 0; right: 0; width: auto; height: min(88dvh, 780px); transform-origin: bottom center; }
  .chat-surface { border-radius: 26px 26px 0 0; padding-bottom: env(safe-area-inset-bottom); border-bottom: 0; }
  .chat-glow { inset: -3px -3px 0; border-radius: 29px 29px 0 0; }
  .chat-grabber { display: block; position: absolute; top: 6px; left: 50%; width: 36px; height: 5px; border-radius: 3px; background: var(--line); transform: translateX(-50%); }
  .chat-head { padding-top: 20px; touch-action: none; cursor: grab; }
  .chat-open { padding: 7px; }
  .chat-open span { display: none; }
}
@media (prefers-reduced-motion: reduce) {
  .chat-glow, .chat.listening .chat-mic, .chat-step-mark, .chat-thinking, .chat-log > * { animation: none !important; }
  .chat-thinking { color: var(--muted); background: none; }
}
@media (prefers-reduced-transparency: reduce) {
  .chat-surface { background: var(--material-solid); -webkit-backdrop-filter: none; backdrop-filter: none; }
  .chat-glow { display: none; }
}
@media (prefers-contrast: more) {
  .chat-surface { background: var(--material-solid); border-color: var(--text); }
}

/* JSON in colour (common.js): keys, strings, numbers, booleans and null each their own hue, punctuation quiet;
   a read-only block (.json) and an editor whose coloured layer sits under a transparent textarea. */
:root { --json-key: #6f42c1; --json-string: #1a7f37; --json-number: #c4510d; --json-bool: #0a63c9; --json-null: #8a8f98; }
@media (prefers-color-scheme: dark) {
  :root { --json-key: #c8a2ff; --json-string: #8ddc8f; --json-number: #ffb06b; --json-bool: #79b8ff; --json-null: #8b949e; }
}
.json-key { color: var(--json-key); }
.json-string { color: var(--json-string); }
.json-number { color: var(--json-number); }
.json-bool { color: var(--json-bool); }
.json-null { color: var(--json-null); font-style: italic; }
.json-punct { color: var(--muted); }
pre.json { margin: 0; padding: 10px 12px; border-radius: 12px; font: 0.75rem/1.5 var(--mono); background: var(--material-thin); border: 1px solid var(--line); overflow: auto; tab-size: 2; }
.code-editor { display: grid; position: relative; }
.code-editor > .code-layer, .code-editor > .code-input {
  grid-area: 1 / 1; margin: 0; box-sizing: border-box; min-width: 0; padding: 14px 16px;
  font: 0.8125rem/1.55 var(--mono); tab-size: 2; white-space: pre; overflow: auto; overflow-wrap: normal; word-break: normal;
}
.code-editor > .code-layer { pointer-events: none; border: 1px solid transparent; border-radius: var(--radius); overflow: hidden; color: var(--text); }
.code-editor > .code-input { position: relative; z-index: 1; color: transparent; background: transparent; caret-color: var(--text); resize: vertical; }
.code-editor > .code-input::selection { color: transparent; background: rgba(10, 132, 255, 0.28); }
.editor-card .code-editor > * { border-width: 0; border-radius: 0; padding: 16px 18px; min-height: 62vh; }
.form-card .code-editor > * { min-height: 340px; }
.form-card .code-editor { margin-top: 4px; border-radius: var(--radius); background: var(--field); }

/* A file field: its path, and a place to drop the file or choose it. */
.drop-zone {
  display: flex; align-items: center; justify-content: center; gap: 8px; margin-top: 6px; padding: 12px; border-radius: 14px;
  border: 1.5px dashed var(--line); color: var(--muted); font-size: 0.8125rem; text-align: center; cursor: pointer;
  transition: border-color var(--fast) var(--ease-out), background-color var(--fast) var(--ease-out), transform var(--fast) var(--ease-out);
}
.drop-zone:hover { border-color: var(--accent); color: var(--text); }
.drop-zone.over { border-color: var(--accent); background: rgba(255, 122, 26, 0.08); color: var(--text); transform: scale(1.01); }
.drop-zone.ok { border-style: solid; border-color: var(--ok); color: var(--ok); }
.drop-zone.error { border-color: var(--error); color: var(--error); }
.view-switch { margin-bottom: 12px; }
.form-card > p.error:empty { display: none; }
.chat-voice { display: flex; align-items: center; justify-content: center; gap: 6px; margin: 6px 16px 0; font-size: 0.75rem; color: var(--muted); }
.chat-voice select.popup { padding: 3px 26px 3px 10px; font-size: 0.75rem; font-weight: 500; background-position: right 9px center; }

/* On a phone, after iOS: the sections move to a tab bar floating above the home indicator, within the thumb's
   reach; the header keeps the app's icon, the Assistant and the account. Controls answer the press (no hover
   lift left behind by a tap), fields are 16px so Safari does not zoom into them, and the layout pads around the
   notch and the home indicator (viewport-fit=cover). */
.tabbar { display: none; }
@media (max-width: 640px) {
  header { top: max(8px, env(safe-area-inset-top)); width: calc(100% - 20px); margin-top: max(8px, env(safe-area-inset-top)); padding: 6px 8px 6px 6px; }
  header nav, #logout { display: none; }
  header .brand { font-size: 1.0625rem; gap: 8px; letter-spacing: -0.015em; }
  header .spacer { display: block; flex: 1; }
  #user { max-width: 9em; font-weight: 500; }
  main { padding: 14px 12px calc(104px + env(safe-area-inset-bottom)); }
  .tabbar {
    position: fixed; z-index: 15; left: 10px; right: 10px; bottom: max(10px, env(safe-area-inset-bottom));
    display: grid; grid-template-columns: repeat(5, 1fr); padding: 6px; border-radius: 28px;
    background-color: var(--material-thick); background-image: var(--sheen);
    -webkit-backdrop-filter: blur(var(--blur-thick)) saturate(180%); backdrop-filter: blur(var(--blur-thick)) saturate(180%);
    border: 1px solid var(--edge); box-shadow: var(--shadow-thick), inset 0 1px 0 var(--edge-light);
  }
  .tabbar a {
    display: grid; justify-items: center; gap: 2px; padding: 7px 2px 6px; border-radius: 22px; min-height: 50px;
    color: var(--muted); text-decoration: none; font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.01em;
    touch-action: manipulation; -webkit-user-select: none; user-select: none;
    transition: transform var(--fast) var(--ease-out), background-color var(--fast) var(--ease-out), color var(--fast) var(--ease-out);
  }
  .tabbar a svg { width: 24px; height: 24px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  .tabbar a.active { color: var(--accent); background: var(--material-thin); }
  .tabbar a:active { transform: scale(0.92); transition-duration: 80ms; }
  /* Bars that float at the bottom of a page float above the tab bar. */
  .settings-bar { bottom: calc(86px + env(safe-area-inset-bottom)); padding-left: 16px; }
  /* Fields at 16px: smaller, and Safari zooms the page into them on focus. */
  input, select, textarea, .code-editor > .code-layer, .code-editor > .code-input { font-size: 16px; }
  /* Comfortable targets, near Apple's 44pt: every button at least 40px tall, a text button too (its hit area
     grows, not its look). */
  .menu-button, .chat-icon { width: 40px; height: 40px; }
  button, a.button { min-height: 40px; }
  button.link { padding-top: 10px; padding-bottom: 10px; }
  .group button, .chat-suggestions button, .chat-voice select, .tabbar a { min-height: 0; }
  .menu [role="menuitem"] { padding: 11px 14px; font-size: 1rem; }
  /* A page's heading beside its tile, smaller; its tools under it. */
  .page-head { flex-wrap: nowrap; align-items: center; gap: 12px; margin: 4px 0 16px; }
  .page-head:has(.tools) { flex-wrap: wrap; }
  .page-head .tile.large { flex: none; }
  .page-head > div { min-width: 0; }
  .page-head h1 { font-size: 1.625rem; line-height: 1.1; letter-spacing: -0.02em; }
  .page-head p { font-size: 0.875rem; }
  /* The Logs toolbar: the level across, the two menus side by side, the filter, then the count and actions. */
  .log-card .editor-bar { gap: 8px; padding: 10px; }
  .log-card .editor-bar > .group { flex: 1 1 100%; display: grid; grid-template-columns: repeat(4, 1fr); }
  .log-card .editor-bar > .group button { padding: 6px 4px; }
  .log-card .editor-bar > select.popup { flex: 1 1 40%; max-width: none; min-width: 0; }
  .log-card .editor-bar > .search { flex: 1 1 100%; width: 100%; }
  .log-card .editor-bar > .spacer { display: none; }
  .log-card .editor-bar > .count { flex: 1; }
  .log-card .editor-bar > label.toggle { margin: 0; }
  .log-card .editor-bar > .log-range { flex: 1 1 100%; }
  .log-card .log { height: 60dvh; min-height: 260px; }
  /* Two figures a row, so a label such as "Home app controllers" reads on one or two lines, not three; a
     bridge's device ID, the longest fact, across. */
  .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .facts, .facts.lead { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .facts.lead > :first-child { grid-column: 1 / -1; }
  /* The chat sheet sits over the tab bar, its field above the home indicator. */
  .chat-foot { margin-bottom: max(12px, env(safe-area-inset-bottom)); }
}
/* A touch has no hover: a lift or a tint applied on tap would stay until the next tap elsewhere. */
@media (hover: none) {
  button:hover, a.button:hover, select.popup:hover { transform: none; }
  nav a:hover:not(.active) { background-color: transparent; }
}
@media (prefers-reduced-motion: reduce) { .tabbar a { transition: none; } }
@media (prefers-reduced-transparency: reduce) { .tabbar { background: var(--material-solid); -webkit-backdrop-filter: none; backdrop-filter: none; } }

/* Camera cards: the picture on top, in 16:9, inset in the card like the Home app's camera tiles; the name and
   state over it on a shade, and round glass buttons that a pointer reveals on hover (always there for touch).
   camera.js swaps the snapshot for the live video once it plays. */
.camera-card { gap: 12px; }
.camera-view {
  position: relative; flex: none; margin: -8px -10px 0; aspect-ratio: 16 / 9; overflow: hidden; isolation: isolate;
  border-radius: calc(var(--radius) - 8px); background: #10131a; color: #fff;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.06);
}
.camera-view > video, .camera-view > .camera-still {
  position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; display: block;
  transition: opacity var(--normal) var(--ease-out);
}
.camera-view > video { opacity: 0; }
.camera-view.is-live > video { opacity: 1; }
.camera-view > .camera-still:not([src]) { opacity: 0; }
.camera-view:fullscreen { margin: 0; border-radius: 0; aspect-ratio: auto; }
.camera-view:fullscreen > video, .camera-view:fullscreen > .camera-still { object-fit: contain; }
.camera-top, .camera-controls { position: absolute; left: 0; right: 0; display: flex; align-items: center; gap: 8px; padding: 10px 12px; z-index: 1; }
.camera-top {
  top: 0; flex-wrap: wrap; padding-bottom: 26px;
  background: linear-gradient(180deg, rgba(0, 0, 0, 0.55), rgba(0, 0, 0, 0));
}
.camera-name {
  flex: 1 1 auto; min-width: 0; font-size: 0.9375rem; font-weight: 600; letter-spacing: -0.01em;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; text-shadow: 0 1px 3px rgba(0, 0, 0, 0.45);
}
.camera-badges { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; }
.camera-badge {
  display: inline-flex; align-items: center; gap: 5px; padding: 2px 8px; border-radius: 999px; white-space: nowrap;
  font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.02em; font-variant-numeric: tabular-nums;
  background: rgba(20, 22, 28, 0.45); -webkit-backdrop-filter: blur(12px) saturate(160%); backdrop-filter: blur(12px) saturate(160%);
  border: 1px solid rgba(255, 255, 255, 0.16);
}
.camera-badge.live::before, .camera-badge.recording::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: #ff453a; }
.camera-badge.live { text-transform: uppercase; }
.camera-badge.recording::before { background: transparent; box-shadow: inset 0 0 0 1.5px #ff453a; }
.camera-badge.motion { background: rgba(255, 204, 0, 0.9); color: #2b2100; border-color: transparent; }
.camera-badge.ring { background: rgba(255, 122, 26, 0.92); color: #fff; border-color: transparent; }
.camera-badge.ring.fresh { animation: camera-ring 1.2s var(--ease-out) 2; }
@keyframes camera-ring { 0%, 100% { transform: scale(1); } 30% { transform: scale(1.12); } }
.camera-view.motion { box-shadow: inset 0 0 0 2px rgba(255, 204, 0, 0.9); }
.camera-controls {
  bottom: 0; justify-content: flex-end; padding-top: 24px;
  background: linear-gradient(0deg, rgba(0, 0, 0, 0.4), rgba(0, 0, 0, 0));
  transition: opacity var(--normal) var(--ease-out);
}
.camera-button {
  display: inline-grid; place-items: center; width: 34px; height: 34px; padding: 0; border-radius: 50%; color: #fff;
  background: rgba(30, 32, 40, 0.42); -webkit-backdrop-filter: blur(14px) saturate(160%); backdrop-filter: blur(14px) saturate(160%);
  border: 1px solid rgba(255, 255, 255, 0.18); box-shadow: none;
}
.camera-button:hover { transform: none; background: rgba(30, 32, 40, 0.62); }
.camera-button svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.camera-message {
  position: absolute; inset: 0; display: grid; place-items: center; padding: 48px 16px; text-align: center; z-index: 1;
  font-size: 0.8125rem; font-weight: 500; color: rgba(255, 255, 255, 0.82); background: rgba(10, 12, 18, 0.35);
}
.camera-view:not(.has-still) > .camera-message { background: radial-gradient(80% 80% at 50% 40%, #232836, #10131a); }
.camera-meta { font-size: 0.8125rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; margin-top: -2px; }
@media (hover: hover) and (pointer: fine) {
  .camera-controls { opacity: 0; }
  .camera-view:hover > .camera-controls, .camera-view:focus-within > .camera-controls { opacity: 1; }
}
@media (pointer: coarse) { .camera-button { width: 40px; height: 40px; } }
@media (max-width: 640px) { .camera-view { margin: -6px -8px 0; } }
@media (prefers-reduced-motion: reduce) { .camera-badge.ring.fresh { animation: none; } .camera-view > video, .camera-controls { transition: none; } }
@media (prefers-reduced-transparency: reduce) {
  .camera-badge, .camera-button { -webkit-backdrop-filter: none; backdrop-filter: none; background: rgba(20, 22, 28, 0.85); }
}

/* Describe your setup: the Assistant's suggestion for a block, as a diff to review. */
.describe-setup summary { cursor: pointer; list-style: none; display: flex; align-items: center; gap: 4px; }
.describe-setup summary::-webkit-details-marker { display: none; }
.describe-body { display: grid; gap: 10px; margin-top: 12px; }
.describe-body .actions { display: flex; gap: 8px; }
.describe-result:empty { display: none; }
.describe-result { display: grid; gap: 10px; }
pre.diff { margin: 0; padding: 10px 12px; border-radius: 12px; background: var(--field); border: 1px solid var(--line); overflow-x: auto; font: 0.8125rem/1.45 var(--mono); }
pre.diff .diff-add { color: var(--ok); background: color-mix(in srgb, var(--ok) 12%, transparent); display: block; }
pre.diff .diff-remove { color: var(--error); background: color-mix(in srgb, var(--error) 12%, transparent); display: block; }
pre.diff .diff-same { display: block; opacity: 0.7; }

"""#),
    ]
}
