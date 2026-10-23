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

  const { $, el, tile, sparkle, menuButton, copyText, markdown, jsonEditor, jsonView, fact, setPaused, slug, withSlugs } = HomeswiftCommon;

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
    main.replaceChildren(el("div", { class: "view-loading" }, spinner()));
    view(main, args).catch((e) => { if (e.status !== 401) main.replaceChildren(el("p", { class: "error", text: e.message })); });
  }
  /// Something loading: a turning ring, read as "Loading"; it shows after a moment, so a quick load does not flash it.
  function spinner() {
    return el("span", { class: "spinner", role: "status", "aria-label": "Loading" });
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
      updateCard(status.update),
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

  /// A newer release, when the bridge found one (ReleaseWatcher): how to get it on this install, the package to
  /// download on a NAS or the command to run, and its notes.
  function updateCard(update) {
    if (!update?.available) return null;
    const published = update.publishedAt ? ` · released ${new Date(update.publishedAt).toLocaleDateString()}` : "";
    let command = null;
    if (update.command) {
      const copy = el("button", { type: "button", text: "Copy", onclick: async () => {
        try { await copyText(update.command); copy.textContent = "Copied"; } catch { copy.textContent = "Not copied"; }
        setTimeout(() => { copy.textContent = "Copy"; }, 1800);
      } });
      command = el("div", { class: "update-command" }, el("code", { text: update.command }), copy);
    }
    return el("div", { class: "card update-card" },
      el("div", { class: "server-head" },
        tile("update", "green"),
        el("div", { class: "who" },
          el("strong", { text: `Homeswift ${update.latest} is available` }),
          el("div", { class: "muted", text: `This is ${update.current}${published}` }))),
      el("p", { text: update.how }),
      command,
      el("div", { class: "actions" },
        update.download ? el("a", { class: "button primary", href: update.download.url, rel: "noopener", title: update.download.name, text: "Download the package" }) : null,
        el("a", { class: "button", href: update.url, target: "_blank", rel: "noopener", text: "On GitHub" })),
      update.notes ? el("details", { class: "more-options" }, el("summary", { text: "What's new" }), markdown(update.notes)) : null);
  }

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

    /// The charts' points, newest first, under two header rows: the process (memory, CPU), then the Home app's
    /// requests and the plugins' device calls, each its average, longest and count; a rule between the groups.
    function fillTable() {
      if (!shown) return;
      const time = new Intl.DateTimeFormat([], { weekday: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      const cell = (value, format, start = false) => el("td", { class: [value == null ? "empty" : "", start ? "group-start" : ""].join(" ").trim(), text: value == null ? "–" : format(value) });
      const calls = (one) => [cell(one?.average, formatMilliseconds, true), cell(one?.longest, formatMilliseconds), cell(one?.count, (n) => n.toLocaleString())];
      const group = (text, span, start = true) => el("th", { scope: "colgroup", colSpan: span, class: start ? "group-start" : "", text });
      const column = (text, start = false) => el("th", { scope: "col", class: start ? "group-start" : "", text });
      table.replaceChildren(table.firstChild, el("div", { class: "table-scroll" }, el("table", {},
        el("thead", {},
          el("tr", { class: "groups" },
            el("th", { scope: "col", rowSpan: 2, class: "time", text: "Time" }),
            group("homeswift", 2, false), group("Home app requests", 3), group("Plugin device calls", 3)),
          el("tr", {}, column("Memory"), column("CPU"), column("Average", true), column("Longest"), column("Count"), column("Average", true), column("Longest"), column("Count"))),
        el("tbody", {}, [...shown.points].reverse().map((point) => el("tr", {},
          el("th", { scope: "row", class: "time", text: time.format(point.time) }), cell(point.memory, formatBytes), cell(point.cpu, formatPercent),
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
  // A wall of widgets (widgets.js): each accessory at the size chosen for it, else the size chosen for its kind,
  // else the kind's own; in the order chosen, on one wall or a wall per plugin. The bridge keeps the layout
  // (/api/layout), the same for every user: a widget's menu sets its size, Edit sets sizes and order.

  const sizeNames = { small: "Small", medium: "Medium", large: "Large" };
  // A kind of widget as the menu names it: "Medium for every light".
  const kindNames = {
    climate: "air conditioner and thermostat", "air-purifier": "air purifier", fan: "fan", light: "light", cover: "shutter", toggle: "switch",
    "switch-group": "group of switches", television: "television", "garage-door": "gate", lock: "lock", "security-system": "alarm", valve: "valve",
    sensor: "sensor", camera: "camera", inspector: "other accessory",
  };

  /// What the menu of an accessory's widget offers, after its sizes.
  function accessoryActions(accessory) {
    return [
      { label: "Identify", icon: "identify", onSelect: () => api(`/api/accessories/${encodeURIComponent(accessory.id)}/identify`, { method: "POST" }).catch((e) => alert(e.message)) },
      { label: "Show its log", icon: "logs", href: `/logs/${accessory.slug ?? encodeURIComponent(accessory.id)}` },
      window.HomeswiftChat?.available() ? { label: "Ask the Assistant", icon: sparkle(), onSelect: () => HomeswiftChat.ask(`About ${accessory.name}: `) } : null,
      accessory.platform ? { label: "Plugin settings", icon: "gear", href: `/plugins/${slug(accessory.platformName || accessory.platform)}` } : null,
      // A paused plugin's accessories do nothing until it runs again.
      accessory.paused ? { label: `Resume ${accessory.platformName}`, icon: "play", onSelect: async () => {
        try { await setPaused(accessory.platform, accessory.platformName, false); route(); } catch (e) { alert(e.message); }
      } } : null,
    ];
  }

  views.accessories = async (main) => {
    const [list, saved] = await Promise.all([api("/api/accessories"), api("/api/layout").catch(() => null)]);
    const accessories = withSlugs(list, "accessory");
    const servers = new Set(accessories.map((accessory) => accessory.bridge)).size;
    const layout = { order: [], sizes: {}, defaults: {}, grouping: "none", ...saved };
    const kinds = new Map(accessories.map((accessory) => [accessory.id, HomeswiftWidgets.kindOf(accessory)]));
    const kindOf = (accessory) => kinds.get(accessory.id).kind;
    const sizeOf = (accessory) => layout.sizes[accessory.id] || layout.defaults[kindOf(accessory)] || kinds.get(accessory.id).size;
    // The order kept first; accessories it does not list yet after them, by plugin and name.
    const rank = new Map(layout.order.map((id, index) => [id, index]));
    const ordered = groupByPlugin(accessories).flatMap(([, group]) => group)
      .map((accessory, index) => [accessory, rank.get(accessory.id) ?? layout.order.length + index]).sort((a, b) => a[1] - b[1]).map(([accessory]) => accessory);
    const plugin = (accessory) => accessory.platformName ?? "";
    let editing = false;

    // Each change is kept by the bridge a moment later; a refusal says so in the page's head.
    const note = el("p", { class: "error hidden", role: "status" });
    let saveTimer = null;
    const save = () => {
      layout.order = ordered.map((accessory) => accessory.id);
      clearTimeout(saveTimer);
      saveTimer = setTimeout(async () => {
        try {
          await api("/api/layout", { method: "PUT", body: layout });
          note.classList.add("hidden");
        } catch (e) {
          if (e.status === 401) return;
          note.textContent = `The layout was not kept: ${e.message}`;
          note.classList.remove("hidden");
        }
      }, 300);
    };

    const nodes = new Map();
    const actions = (accessory) => {
      const size = sizeOf(accessory), kind = kindOf(accessory);
      return [
        ...HomeswiftWidgets.sizes.map((one) => ({ label: sizeNames[one], checked: one === size, onSelect: () => resize(accessory, one) })),
        { label: `${sizeNames[size]} for every ${kindNames[kind] ?? "accessory like it"}`, icon: "edit", onSelect: () => resizeKind(kind, size) },
        { separator: true },
        ...accessoryActions(accessory),
      ];
    };
    function widget(accessory) {
      const node = HomeswiftWidgets.card(accessory, { size: sizeOf(accessory), actions });
      if (editing) editable(node, accessory);
      nodes.set(accessory.id, node);
      return node;
    }
    function resize(accessory, size) {
      layout.sizes[accessory.id] = size;
      nodes.get(accessory.id)?.replaceWith(widget(accessory));
      save();
    }
    /// The size of a kind: every accessory of that kind takes it, those sized one by one included.
    function resizeKind(kind, size) {
      layout.defaults[kind] = size;
      for (const accessory of accessories) {
        if (kindOf(accessory) !== kind) continue;
        delete layout.sizes[accessory.id];
        nodes.get(accessory.id)?.replaceWith(widget(accessory));
      }
      save();
    }
    /// Puts `accessory` before or after `target`; by plugin, only beside one of its own plugin.
    function place(accessory, target, after) {
      if (accessory === target || (layout.grouping === "plugin" && plugin(accessory) !== plugin(target))) return;
      ordered.splice(ordered.indexOf(accessory), 1);
      ordered.splice(ordered.indexOf(target) + (after ? 1 : 0), 0, accessory);
      save();
      render();
    }
    function step(accessory, delta) {
      const wall = ordered.filter((one) => layout.grouping !== "plugin" || plugin(one) === plugin(accessory));
      const target = wall[wall.indexOf(accessory) + delta];
      if (!target) return;
      place(accessory, target, delta > 0);
      nodes.get(accessory.id)?.querySelector(`.edit-bar [data-step="${delta}"]`)?.focus();
    }
    /// In Edit: the sizes and the arrows over the widget, and the widget dragged into place.
    function editable(node, accessory) {
      const size = sizeOf(accessory);
      node.append(el("div", { class: "edit-bar", role: "group", "aria-label": `Size and place of ${accessory.name}` },
        el("button", { type: "button", "aria-label": "Move earlier", title: "Move earlier", text: "‹", "data-step": "-1", onclick: () => step(accessory, -1) }),
        HomeswiftWidgets.sizes.map((one) => el("button", { type: "button", text: one[0].toUpperCase(), title: sizeNames[one], "aria-label": sizeNames[one], "aria-pressed": String(one === size), onclick: () => resize(accessory, one) })),
        el("button", { type: "button", "aria-label": "Move later", title: "Move later", text: "›", "data-step": "1", onclick: () => step(accessory, 1) })));
      node.addEventListener("pointerdown", (event) => drag(event, node));
    }

    const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
    /// Moves widgets of `wall` by `change` and slides them from where they were seen to where they land (FLIP): taken
    /// from their on-screen place, so a slide already under way turns smoothly.
    function slide(wall, change, except) {
      const siblings = [...wall.children].filter((node) => node !== except);
      const seen = new Map(siblings.map((node) => [node, node.getBoundingClientRect()]));
      change();
      for (const node of siblings) { node.style.transition = "none"; node.style.transform = ""; }
      for (const node of siblings) {
        const was = seen.get(node), now = node.getBoundingClientRect();
        const dx = was.left - now.left, dy = was.top - now.top;
        if (!dx && !dy) { node.style.transition = ""; continue; }
        node.style.transform = `translate(${dx}px, ${dy}px)`;
        node.getBoundingClientRect();
        node.style.transition = reducedMotion.matches ? "none" : "transform 220ms var(--ease-out)";
        node.style.transform = "";
      }
    }

    /// Dragging in Edit: the widget lifts and follows the pointer, a dashed slot holds its place in the grid and
    /// moves as it passes over the others, which slide aside; near the window's top or bottom the page scrolls.
    /// Let go, it lands in the slot, and the wall's order is kept. A finger drags at once: in Edit the widgets do not
    /// scroll the page.
    function drag(event, node) {
      if (event.button !== 0 || event.target.closest(".edit-bar")) return;
      // A press that drags selects no text.
      event.preventDefault();
      getSelection()?.removeAllRanges();
      const wall = node.parentElement;
      const start = { x: event.clientX, y: event.clientY };
      let slot = null, pointer = event, scroller = null;
      node.setPointerCapture(event.pointerId);
      const lift = () => {
        const box = node.getBoundingClientRect();
        slot = el("div", { class: `${[...node.classList].filter((name) => name.startsWith("size-")).join(" ")} widget drag-slot`, "aria-hidden": "true" });
        node.before(slot);
        node.classList.add("lifted");
        Object.assign(node.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px` });
        scroller = setInterval(() => {
          const edge = 80, speed = 14;
          if (pointer.clientY < edge) scrollBy(0, -speed);
          else if (pointer.clientY > innerHeight - edge) scrollBy(0, speed);
          else return;
          hover();
        }, 16);
      };
      // The widget under the pointer: the slot goes before it, or after it past its middle.
      const hover = () => {
        const under = document.elementFromPoint(pointer.clientX, pointer.clientY)?.closest(".wall > .widget");
        if (!under || under === slot || under.parentElement !== wall) return;
        const box = under.getBoundingClientRect();
        const after = pointer.clientX > box.left + box.width / 2;
        if ((after ? under.nextElementSibling : under.previousElementSibling) === slot) return;
        slide(wall, () => (after ? under.after(slot) : under.before(slot)), node);
      };
      const move = (moved) => {
        pointer = moved;
        if (!slot) {
          if (Math.hypot(moved.clientX - start.x, moved.clientY - start.y) < 5) return;
          lift();
        }
        node.style.transform = `translate(${moved.clientX - start.x}px, ${moved.clientY - start.y}px) scale(1.04)`;
        hover();
      };
      const end = () => {
        node.removeEventListener("pointermove", move);
        node.removeEventListener("pointerup", end);
        node.removeEventListener("pointercancel", end);
        clearInterval(scroller);
        if (!slot) return;
        // Lands in the slot from where it was let go.
        const from = node.getBoundingClientRect();
        slot.replaceWith(node);
        node.classList.remove("lifted");
        node.style.cssText = "";
        const to = node.getBoundingClientRect();
        node.style.transition = "none";
        node.style.transform = `translate(${from.left - to.left}px, ${from.top - to.top}px)`;
        node.getBoundingClientRect();
        node.style.transition = reducedMotion.matches ? "none" : "transform 220ms var(--ease-out)";
        node.style.transform = "";
        // The wall's accessories take the places they had in the order, in the order they now stand.
        const ids = [...wall.children].map((child) => child.dataset.id).filter(Boolean);
        const places = ordered.flatMap((accessory, index) => ids.includes(accessory.id) ? [index] : []);
        const byID = new Map(ordered.map((accessory) => [accessory.id, accessory]));
        ids.forEach((id, index) => { ordered[places[index]] = byID.get(id); });
        save();
      };
      node.addEventListener("pointermove", move);
      node.addEventListener("pointerup", end);
      node.addEventListener("pointercancel", end);
    }

    const content = el("div", { class: "accessory-walls" });
    const none = el("p", { class: "muted hidden", text: "No accessory matches." });
    function render() {
      nodes.clear();
      // By plugin: a section each, in the order of their names (those of no plugin last); else one wall.
      const groups = layout.grouping === "plugin"
        ? groupByPlugin(accessories).map(([name, group]) => [name, ordered.filter((accessory) => group.includes(accessory))])
        : [["", ordered]];
      content.replaceChildren(...groups.map(([name, group]) => el("section", { class: "accessory-section" },
        name ? el("div", { class: "section-head" }, el("h2", { text: name }), el("span", { class: "muted", text: `${group.length} ${group.length === 1 ? "accessory" : "accessories"}` })) : null,
        el("div", { class: `wall${editing ? " editing" : ""}` }, group.map(widget)))));
      filter();
    }

    const search = el("input", { type: "search", class: "search", placeholder: "Search accessories", "aria-label": "Search accessories" });
    function filter() {
      const text = search.value.trim().toLowerCase();
      let shown = 0;
      for (const section of content.children) {
        let inSection = 0;
        for (const card of section.querySelectorAll("[data-search]")) {
          const match = !text || card.dataset.search.includes(text);
          card.classList.toggle("hidden", !match);
          if (match) inSection++;
        }
        section.classList.toggle("hidden", inSection === 0);
        shown += inSection;
      }
      none.classList.toggle("hidden", shown > 0);
    }
    search.addEventListener("input", filter);
    const grouping = el("div", { class: "group", role: "group", "aria-label": "Group the accessories" }, [["none", "One wall"], ["plugin", "By plugin"]].map(([value, text]) =>
      el("button", { type: "button", text, class: layout.grouping === value ? "on" : "", "aria-pressed": String(layout.grouping === value), onclick: (event) => {
        layout.grouping = value;
        for (const button of grouping.children) { button.classList.toggle("on", button === event.currentTarget); button.setAttribute("aria-pressed", String(button === event.currentTarget)); }
        save();
        render();
      } })));
    const edit = el("button", { type: "button", text: "Edit", "aria-pressed": "false", title: "Sizes and order of the widgets", onclick: () => {
      editing = !editing;
      edit.textContent = editing ? "Done" : "Edit";
      edit.classList.toggle("primary", editing);
      edit.setAttribute("aria-pressed", String(editing));
      render();
    } });

    render();
    show(main,
      pageHead("Accessories", accessories.length ? `${accessories.length} on ${servers} ${servers === 1 ? "server" : "servers"}, as the Home app sees them. Changes here reach your devices.` : "",
        ...(accessories.length ? [search, grouping, edit] : [])),
      note,
      accessories.length ? [content, none] : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No accessories yet. Plugins add them once they reach their devices." })));
  };

  /// Accessories by plugin: [name, accessories] pairs by the plugin's name, each list by name; those of no
  /// plugin last, as "Other accessories".
  function groupByPlugin(accessories) {
    const groups = Map.groupBy([...accessories].sort((a, b) => a.name.localeCompare(b.name)), (accessory) => accessory.platformName ?? "");
    return [...groups].sort(([a], [b]) => !a - !b || a.localeCompare(b)).map(([name, list]) => [name || "Other accessories", list]);
  }

  function applyAccessoryEvent(event) {
    window.HomeswiftCamera?.event(event);
    HomeswiftWidgets.event(event);
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

  /// The ANSSI's bands, from the bits where each starts: the scale under the gauge.
  const strengthBands = [[0, "Weak"], [65, "Low"], [85, "Medium"], [100, "Strong"]];

  /// A live gauge under a password field: the ANSSI's bands along 0 to 128 bits as one gradient, lit up to the
  /// password's entropy, the 85-bit bar marked, and the two rules ticking as they are met. `username()` gives the
  /// name the password must not lean on. `gauge.acceptable()` answers, once the server has, whether the password as
  /// typed passes. Its classes are `strength-*`: the widgets' dial is `.gauge`.
  function strengthGauge(input, username = () => "") {
    const percent = (bits) => `${(Math.min(bits, passwordPolicy.scaleBits) / passwordPolicy.scaleBits) * 100}%`;
    const fill = el("div", { class: "strength-fill" });
    const label = el("strong", { class: "strength-level" });
    const bits = el("span", { class: "strength-bits" });
    const ruleLength = el("li", { text: `At least ${passwordPolicy.minimumLength} characters` });
    const ruleBits = el("li", { text: `At least ${passwordPolicy.minimumBits} bits of entropy (ANSSI: medium to strong)` });
    const hint = el("p", { class: "help strength-hint" });
    const track = el("div", { class: "strength-track", role: "meter", "aria-label": "Password strength", "aria-valuemin": "0", "aria-valuemax": String(passwordPolicy.scaleBits) },
      fill,
      ...strengthBands.slice(1).map(([at]) => el("span", { class: "strength-tick", style: `left:${percent(at)}` })),
      el("span", { class: "strength-mark", title: `Required: ${passwordPolicy.minimumBits} bits`, style: `left:${percent(passwordPolicy.minimumBits)}` }));
    const scale = el("div", { class: "strength-scale", "aria-hidden": "true" },
      ...strengthBands.map(([at, text], index) => el("span", { text, style: `left:${percent(at)};width:${percent((strengthBands[index + 1]?.[0] ?? passwordPolicy.scaleBits) - at)}` })));
    const gauge = el("div", { class: "strength" }, el("div", { class: "strength-head" }, label, bits), track, scale, el("ul", { class: "strength-rules" }, ruleLength, ruleBits), hint);

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
      fill.style.setProperty("--lit", percent(s?.bits ?? 0));
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
    const days = state.sessionDays ?? 7;
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
      el("p", { class: "muted account-lead", text: "A phrase of several random words is long, strong and easy to remember." }),
      // The fields on one side, the new password's entropy beside them as it is typed.
      el("div", { class: "account-password" },
        el("div", { class: "account-fields" },
          field("Current password", current),
          field("New password", next),
          field("New password again", again),
          el("div", { class: "actions" }, submit), message),
        el("aside", { class: "strength-panel", "aria-label": "Strength of the new password" },
          el("span", { class: "field-title", text: "Entropy of the new password" }), gauge)));
    // Who is signed in, with the one thing to do about it.
    const profile = el("section", { class: "card account-profile" },
      el("span", { class: "account-avatar", "aria-hidden": "true", text: (state.username || "?").slice(0, 1).toUpperCase() }),
      el("div", { class: "account-who" },
        el("h2", { text: state.username }),
        el("p", { class: "muted", text: `Signed in on this browser. Logins last ${days} day${days === 1 ? "" : "s"} without activity; changing the password signs the others out.` })),
      el("button", { text: "Sign out", onclick: () => $("#logout").click() }));
    show(main, pageHead("Account", "Your sign-in to this bridge's web UI."), el("div", { class: "account" }, profile, form));
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
  /// A line with what filtering reads, worked out once: its date and its text in lower case, its payload included.
  const prepared = (line) => Object.assign(line, { date: new Date(line.time), haystack: `${line.label} ${line.text} ${line.details ?? ""}`.toLowerCase() });
  // All: every line; Info: info and above; Warnings: warnings only; Errors: errors only (critical ones too).
  const levelChoices = [["trace", "All"], ["info", "Info"], ["warning", "Warnings"], ["error", "Errors"]];
  const levelShown = (level, choice) => choice === "warning" ? level === "warning" : (levelRank[level] ?? 0) >= (levelRank[choice] ?? 0);
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
    const levels = el("div", { class: "group", role: "group", "aria-label": "Levels shown" }, levelChoices.map(([level, text]) =>
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
      // The range loading: a spinner where its lines will be.
      count.textContent = "";
      output.replaceChildren(el("div", { class: "log-loading" }, spinner()));
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
    // Whether lines go to disk with their JSON payloads, secrets masked: for reading them, or letting the Assistant
    // read them, after the latest lines moved on. Off, only the lines in memory have them. Shown when the bridge
    // keeps a log on disk.
    const saveDetails = el("input", { type: "checkbox" });
    const saveToggle = el("label", { class: "toggle compact hidden", title: "Keep each line's JSON payload in the log on disk, secrets masked, so you and the Assistant can read it later. Off: only the latest lines, in memory, have it." },
      el("span", { class: "switch" }, saveDetails, el("span")), el("span", { text: "Save payloads" }));
    api("/api/logs/settings").then((settings) => {
      if (!settings.available) return;
      saveDetails.checked = settings.saveDetails;
      saveToggle.classList.remove("hidden");
    }).catch(() => {});
    saveDetails.addEventListener("change", async () => {
      saveDetails.disabled = true;
      try {
        saveDetails.checked = (await api("/api/logs/settings", { method: "PUT", body: { saveDetails: saveDetails.checked } })).saveDetails;
      } catch (e) {
        saveDetails.checked = !saveDetails.checked;
        alert(e.message);
      }
      saveDetails.disabled = false;
    });
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
          saveToggle,
          range.customRow),
        output));
    await load();
  };

  /// Whether a prepared line passes the level, the text (`needle`, in lower case) and the accessory.
  function visible(line, needle = logState.filter.value.toLowerCase()) {
    return levelShown(line.level, logState.level) && (!needle || line.haystack.includes(needle))
      && (!logState.accessory || logState.accessory.some((term) => line.haystack.includes(term)))
      && (!logState.bridge || logState.bridge(line));
  }
  /// A line; one whose JSON payload was taken out (its text shows `{…} 1.4 KB`) has a JSON button that shows the
  /// payload under it, formatted. It stays open while the filters draw the lines again.
  function lineNode(line) {
    const time = isNaN(line.date) ? line.time : timeFormat.format(line.date);
    const text = el("span", { class: "text", text: line.text });
    const node = el("div", { class: `log-line ${line.level}` },
      el("time", { text: time, title: line.time, dateTime: line.time }),
      el("span", { class: "label", text: line.label, title: line.label }),
      text);
    if (!line.details) return node;
    const toggle = el("button", { type: "button", class: "log-details-toggle", text: "JSON", title: "Show the payload" });
    const show = () => {
      toggle.setAttribute("aria-expanded", String(Boolean(line.open)));
      toggle.title = line.open ? "Hide the payload" : "Show the payload";
      $(".log-details", node)?.remove();
      if (line.open) node.append(detailsNode(line));
    };
    toggle.addEventListener("click", () => { line.open = !line.open; show(); });
    text.append(" ", toggle);
    show();
    return node;
  }
  function detailsNode(line) {
    try {
      return jsonView(JSON.parse(line.details), { class: "json log-details" });
    } catch {
      return el("pre", { class: "json log-details", text: line.details });
    }
  }
  function appendLogLine(line) {
    if (!logState || !logState.live || !document.body.contains(logState.output)) return;
    // A range still loading: the line comes with it.
    if ($(".log-loading", logState.output)) return;
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
  const touch = matchMedia("(pointer: coarse)");
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
    setUpKeyboard();
    renderControls();
  }

  /// Safari keeps the layout viewport, and so a fixed sheet's bottom, under the on-screen keyboard: the phone
  /// sheet sits on the keyboard instead (`--keyboard`, what it covers) and fits in what is left above it.
  function setUpKeyboard() {
    const view = window.visualViewport;
    if (!view) return;
    const fit = () => {
      const covered = phone.matches ? Math.max(0, Math.round(window.innerHeight - view.height - view.offsetTop)) : 0;
      panel.sheet.style.setProperty("--keyboard", `${covered}px`);
      panel.sheet.style.setProperty("--visible", `${Math.round(view.height)}px`);
      panel.sheet.classList.toggle("keyboard", covered > 80);
    };
    view.addEventListener("resize", fit);
    view.addEventListener("scroll", fit);
    fit();
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
      // A touch screen keeps its keyboard down until the field is tapped: up at once, it would cover the sheet.
      if (!touch.matches) setTimeout(() => panel.input.focus({ preventScroll: true }), 50);
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
    update: '<path d="M12 3.5v11"/><path d="m7.5 10 4.5 4.5 4.5-4.5"/><path d="M5 20.5h14"/>',
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

  /// Opens a menu under `trigger`. Each item: { label, icon (a name or a node), href or onSelect, danger }, or
  /// { separator: true }; `checked` (true or false) makes it one of a set of choices, the chosen one ticked.
  /// Opened from the keyboard, its first item takes the focus; from a click, the menu does, so no item looks
  /// chosen before the pointer or an arrow key gets to it.
  function menu(trigger, items, { keyboard = false } = {}) {
    if (openMenu?.trigger === trigger) { openMenu.close(); return; }
    openMenu?.close(true);
    const nodes = items.filter(Boolean).map((item) => {
      if (item.separator) return el("hr", { class: "menu-separator", role: "separator" });
      const glyph = typeof item.icon === "string" ? icon(item.icon) : item.icon ?? null;
      const choice = typeof item.checked === "boolean";
      const role = choice ? "menuitemradio" : "menuitem";
      const tick = choice ? el("span", { class: "menu-check", "aria-hidden": "true", text: item.checked ? "✓" : "" }) : null;
      const node = item.href
        ? el("a", { role, href: item.href, class: item.danger ? "danger" : "", tabIndex: -1 }, glyph, el("span", { text: item.label }), tick)
        : el("button", { type: "button", role, class: item.danger ? "danger" : "", tabIndex: -1, "aria-checked": choice ? String(item.checked) : null }, glyph, el("span", { text: item.label }), tick);
      node.addEventListener("click", () => { close(); item.onSelect?.(); });
      return node;
    });
    const entries = nodes.filter((node) => node.tagName !== "HR");
    const list = el("div", { class: "menu", role: "menu", tabIndex: -1, "aria-label": trigger.getAttribute("aria-label") || "Actions" }, nodes);
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
<script src="/widgets.js"></script>
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
/* Something loading: a ring that turns, faded in after 150 ms so a quick load does not flash it; a page's in the middle
   of the view. */
.spinner {
  display: inline-block; width: 22px; height: 22px; border-radius: 50%; border: 2px solid var(--line); border-top-color: var(--accent);
  vertical-align: middle; animation: spin 0.8s linear infinite, fade var(--normal) var(--ease-out) 150ms both;
}
.view-loading { display: grid; place-items: center; min-height: 40vh; }
.view-loading .spinner, .log-loading .spinner { width: 30px; height: 30px; border-width: 3px; }
.log-loading { display: grid; place-items: center; height: 100%; min-height: 160px; }
@media (prefers-reduced-motion: reduce) {
  .panel { animation: none; }
  button.busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  .spinner { animation: fade var(--normal) var(--ease-out) 150ms both; border-color: var(--accent); opacity: 0.5; }
}
@media (max-width: 640px) { .panel-columns { grid-template-columns: 1fr; } }

/* The password strength: the ANSSI's bands along 0 to 128 bits as one gradient, from red through amber to green,
   lit up to the password's entropy as you type; the 85-bit bar marked. Its own names: the widgets' dial is .gauge. */
:root { --entropy: linear-gradient(90deg, #ff453a 0%, #ff6a2b 30%, #ff9f0a 50.8%, #ffd60a 66.4%, #30d158 78.1%, #20c4a8 100%); }
.strength { margin-top: 10px; display: grid; gap: 6px; }
.strength-head { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; font-variant-numeric: tabular-nums; }
.strength-level { font-size: 0.9375rem; font-weight: 600; transition: color var(--normal) var(--ease-out); }
.strength-bits { font-size: 0.8125rem; color: var(--muted); }
.strength-track { position: relative; height: 12px; border-radius: 999px; background: var(--material-thin); box-shadow: inset 0 0 0 1px var(--line); }
/* The whole scale shows faintly; the fill is the same gradient, cut at the entropy, so each band keeps its colour. */
.strength-track::before { content: ""; position: absolute; inset: 0; border-radius: inherit; background: var(--entropy); opacity: 0.2; }
.strength-fill {
  position: absolute; inset: 0; border-radius: inherit; background: var(--entropy);
  clip-path: inset(0 calc(100% - var(--lit, 0%)) 0 0 round 999px);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.45);
  transition: clip-path var(--normal) var(--ease-out);
}
.strength-tick { position: absolute; top: 3px; bottom: 3px; width: 1px; background: rgba(255, 255, 255, 0.75); mix-blend-mode: overlay; }
.strength-mark { position: absolute; top: -5px; bottom: -5px; width: 3px; margin-left: -1.5px; border-radius: 2px; background: var(--text); box-shadow: 0 0 0 2px var(--material-solid); }
.strength-scale { position: relative; height: 1.2em; font-size: 0.6875rem; color: var(--muted); }
.strength-scale span { position: absolute; top: 0; text-align: center; white-space: nowrap; }
.strength[data-level="veryWeak"] .strength-level { color: var(--error); }
.strength[data-level="lowToMedium"] .strength-level { color: var(--warn); }
.strength[data-level="mediumToStrong"] .strength-level, .strength[data-level="strongToVeryStrong"] .strength-level { color: var(--ok); }
.strength-rules { list-style: none; margin: 4px 0 0; padding: 0; display: grid; gap: 3px; font-size: 0.8125rem; color: var(--muted); }
.strength-rules li::before { content: "○"; display: inline-block; width: 1.3em; }
.strength-rules li.met { color: var(--ok); }
.strength-rules li.met::before { content: "✓"; }
.strength-hint { margin: 2px 0 0; min-height: 1em; }
@media (prefers-reduced-motion: reduce) { .strength-fill, .strength-level { transition: none; } }

/* Account: who is signed in, then the password form with the new password's entropy beside its fields. */
.account { display: grid; gap: 14px; max-width: 920px; }
.account .card { margin: 0; }
.account h2 { margin: 0; }
.account-profile { display: flex; align-items: center; gap: 16px; }
.account-avatar {
  flex: none; display: grid; place-items: center; width: 52px; height: 52px; border-radius: 50%;
  font-size: 1.375rem; font-weight: 600; color: var(--accent-text);
  background: linear-gradient(145deg, var(--accent-2), var(--accent));
  box-shadow: 0 8px 20px rgba(255, 122, 26, 0.32), inset 0 1px 0 rgba(255, 255, 255, 0.5);
}
.account-who { flex: 1; min-width: 0; }
.account-who p { margin: 3px 0 0; }
.account-lead { margin: 4px 0 0; }
.account-password { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 22px; align-items: start; margin-top: 16px; }
.account-fields .field:first-child { margin-top: 0; }
.strength-panel {
  padding: 16px 18px; border-radius: calc(var(--radius) - 6px);
  background: var(--material-thin); box-shadow: inset 0 0 0 1px var(--line);
}
.strength-panel .strength { margin-top: 10px; gap: 8px; }
.strength-panel .strength-level { font-size: 1.25rem; letter-spacing: -0.01em; }
.strength-panel .strength-bits { font-size: 0.9375rem; }
.strength-panel .strength-track { height: 14px; }
@media (max-width: 720px) {
  /* One column, the entropy right under the new password, where the eyes are while typing it. */
  .account-password { grid-template-columns: 1fr; gap: 0; }
  .account-fields { display: contents; }
  .account-fields > :nth-child(-n+2) { order: 1; }
  .strength-panel { order: 2; margin: 8px 0 4px; }
  .account-fields > :nth-child(n+3) { order: 3; }
  .account-profile { flex-wrap: wrap; }
  .account-profile > button { width: 100%; }
}
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
button.primary, a.button.primary { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: rgba(255, 255, 255, 0.4); box-shadow: 0 8px 20px rgba(255, 122, 26, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.5); }
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

/* The wall (widgets.js, the Accessories page): widgets on a grid of square units, packed with no gaps; a small
   widget takes one unit, a medium two side by side, a large two by two. The unit shrinks on a narrow phone so two
   always fit. A widget's box is fixed; every control is a tap away in its sheet. */
:root {
  --heat: #f2711c; --cool: #1f7fe8; --auto: #1f9d55; --track: rgba(120, 128, 142, 0.2);
  --tile-on: #ffffff; --tile-on-text: #15171c; --tile-on-muted: rgba(21, 23, 28, 0.6); --knob: #ffffff;
  --unit: 160px; --unit-gap: 12px;
}
@media (prefers-color-scheme: dark) {
  :root { --heat: #ff8d3a; --cool: #4aa3ff; --auto: #3ccf7a; --track: rgba(255, 255, 255, 0.12); --tile-on: rgba(255, 255, 255, 0.92); --knob: #f3f4f7; }
}
.accessory-walls { container-type: inline-size; }
.wall { --unit: min(160px, calc((100cqw - var(--unit-gap)) / 2)); display: grid; grid-template-columns: repeat(auto-fill, var(--unit)); grid-auto-rows: var(--unit);
  grid-auto-flow: row dense; gap: var(--unit-gap); }
.wall > .widget { width: auto; height: auto; }
/* A phone: two columns that fill the width. */
@container (max-width: 520px) { .wall { --unit: calc((100cqw - var(--unit-gap)) / 2); } }
/* The Accessories page's tools on a phone: the search on a line of its own. */
@media (max-width: 600px) {
  .page-head .tools:has(> .search) { flex-wrap: wrap; width: 100%; }
  .page-head .tools > .search { flex: 1 1 100%; width: 100%; }
}
.wall > .size-medium { grid-column: span 2; }
.wall > .size-large { grid-column: span 2; grid-row: span 2; }
/* A control a widget hides (Close while the door is closed) stays hidden whatever its display. */
.widget [hidden] { display: none !important; }

.widget:not(.widget-full) { position: relative; margin: 0; padding: 12px; min-width: 0; display: flex; flex-direction: column; gap: 8px; overflow: hidden; border-radius: var(--radius); }
.widget.size-small { width: var(--unit); height: var(--unit); justify-content: space-between; gap: 6px;
  transition: background-color var(--normal) var(--ease-out), color var(--normal) var(--ease-out), transform var(--fast) var(--ease-out); }
.widget.size-medium { width: calc(var(--unit) * 2 + var(--unit-gap)); height: var(--unit); }
.widget.size-large { width: calc(var(--unit) * 2 + var(--unit-gap)); height: calc(var(--unit) * 2 + var(--unit-gap)); }
.widget .tile { transition: background var(--normal) var(--ease-out), box-shadow var(--normal) var(--ease-out), color var(--normal) var(--ease-out); }
.widget:not(.widget-full) .tile { width: 34px; height: 34px; border-radius: 10px; }
.widget:not(.widget-full) .tile svg { width: 19px; height: 19px; }
.tile.tone-heat { background: linear-gradient(160deg, #ffb15c, #f2711c); }
.tile.tone-light { background: var(--light, linear-gradient(160deg, #ffd66b, #f0a01e)); color: #3a2600; box-shadow: 0 4px 14px color-mix(in srgb, var(--glow, #f0a01e) 45%, transparent), inset 0 1px 0 rgba(255, 255, 255, 0.4); }
/* Off: grey, whatever the tone (after the tones, which it overrides). */
.tile.is-off { background: linear-gradient(160deg, #b4bbc7, #8b94a4); color: #fff; box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.35); }

.w-head { display: flex; align-items: center; gap: 10px; min-width: 0; }
.w-head .who, .w-bottom .who { flex: 1; min-width: 0; display: grid; }
.widget:not(.widget-full) .who strong { font-size: 0.875rem; line-height: 1.25; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.widget.size-small:not(.widget-full) .who strong { white-space: normal; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.widget .status { font-size: 0.8125rem; color: var(--muted); transition: color var(--normal) var(--ease-out); }
.widget:not(.widget-full) .status { font-size: 0.75rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.status[data-tone="heat"] { color: var(--heat); } .status[data-tone="cool"] { color: var(--cool); } .status[data-tone="auto"], .status[data-tone="ok"] { color: var(--ok); }
.status[data-tone="warn"] { color: var(--warn); } .status[data-tone="bad"] { color: var(--error); }
.w-body { flex: 1; min-height: 0; display: flex; flex-direction: column; justify-content: center; gap: 10px; }
/* Each part keeps its height; a large body that holds more scrolls rather than squeezing them. */
.w-body > * { flex-shrink: 0; }
.widget:not(.widget-full) .seg > button { white-space: nowrap; padding-inline: 2px; }
.size-medium .w-body { padding-right: 26px; overflow: hidden; justify-content: safe center; }
/* A medium light's swatches on one line, as large as the line allows for the eight colours and the sun. */
.size-medium .swatches { gap: 5px; flex-wrap: nowrap; }
.widget.size-medium .swatch { width: min(28px, calc((100% - 40px) / 9)); height: auto; aspect-ratio: 1; }
.size-large .w-body { justify-content: flex-start; overflow-y: auto; scrollbar-width: none; }
.size-large .w-body > :last-child { margin-right: 26px; }
/* A large box's chips on one line, swiped sideways when there are more than fit. */
.widget.size-large .chips { flex-wrap: nowrap; overflow-x: auto; scrollbar-width: none; padding: 2px; margin: -2px; }
.widget.size-large .chips > * { flex: none; }
.head-only { justify-content: center; }
.powered-off .w-body, .powered-off .w-main { opacity: 0.55; transition: opacity var(--normal) var(--ease-out); }
/* The menu at the bottom right of the box, over its content's corner. */
.w-corner { position: absolute; right: 6px; bottom: 6px; z-index: 2; }
.widget:not(.widget-full) .menu-button { width: 28px; height: 28px; background: none; border-color: transparent; box-shadow: none; color: inherit; }
.widget:not(.widget-full) .menu-button svg { width: 16px; height: 16px; }
/* A phone holds every button to 40px tall (the phone rules below); a widget's own controls keep their shapes,
   a swatch round, a step a bar, the corner's glyph 28px, its hit area grown under a finger instead. */
.widget .swatch, .widget .steps > button, .widget .seg > button, .widget .round, .widget .w-hit, .widget:not(.widget-full) .menu-button, .edit-bar button { min-height: 0; }
.widget .swatch { flex: none; }
.widget button { -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
@media (pointer: coarse) {
  .widget:not(.widget-full) .menu-button { position: relative; }
  .widget:not(.widget-full) .menu-button::after { content: ""; position: absolute; inset: -8px; }
  .edit-bar button { min-width: 36px; height: 36px; }
}

/* Small: a tap anywhere acts (or a hold confirms); the whole tile lights up when on, as the Home app's do. */
.size-small.on { background-color: var(--tile-on); background-image: none; color: var(--tile-on-text); }
.size-small.on .status, .size-small.on .w-hero small { color: var(--tile-on-muted); }
.size-small:has(> .w-hit:active) { transform: scale(0.97); }
.w-hit { position: absolute; inset: 0; z-index: 0; width: 100%; height: 100%; padding: 0; border: 0; border-radius: inherit; background: none; box-shadow: none; }
.widget .w-hit:hover, .widget .w-hit:active:not(:disabled) { transform: none; }
.w-hit:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
.w-top, .w-bottom { position: relative; z-index: 1; display: flex; gap: 8px; min-width: 0; pointer-events: none; }
.w-top { align-items: flex-start; justify-content: space-between; }
.w-bottom { align-items: flex-end; }
.w-bottom .menu-button { pointer-events: auto; margin: 0 -6px -6px 0; flex: none; }
.w-hero { font-size: 1.375rem; font-weight: 600; letter-spacing: -0.02em; line-height: 1; text-align: right; font-variant-numeric: tabular-nums; }
.w-hero small { display: block; margin-top: 3px; font-size: 0.6875rem; font-weight: 500; letter-spacing: 0; color: var(--muted); }
.w-hero svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.w-hero-word { font-size: 0.9375rem; }
/* A shutter's tile: its closed part drawn from the top. */
.w-shade { position: absolute; inset: 0 0 auto 0; z-index: 0; height: var(--closed, 0%); pointer-events: none;
  background: repeating-linear-gradient(180deg, rgba(120, 128, 142, 0.16) 0 7px, rgba(120, 128, 142, 0.26) 7px 8px); transition: height 300ms var(--ease-out); }
/* Held to confirm: a fill crosses the tile; let go early and it goes back. */
.w-veil { position: absolute; inset: 0; z-index: 0; pointer-events: none; background: color-mix(in srgb, var(--warn) 30%, transparent); clip-path: inset(0 100% 0 0); transition: clip-path 200ms var(--ease-out); }
.holding > .w-veil { clip-path: inset(0 0 0 0); transition: clip-path 900ms linear; }
/* A shutter's tile slid: the shade follows the pointer one to one; held on a phone, it lifts a little first. */
.size-small.sliding > .w-shade { transition: none; }
.size-small.slide-ready, .size-small.sliding { transform: scale(1.02); box-shadow: var(--shadow-thick); }
.widget-cover.size-small > .w-hit { cursor: ns-resize; user-select: none; -webkit-user-select: none; }

/* A paused plugin's accessory: quiet and striped, its controls out of reach; the menu stays to resume it. */
.widget.paused { background-image: repeating-linear-gradient(135deg, transparent 0 10px, color-mix(in srgb, var(--muted) 9%, transparent) 10px 20px); }
.widget.paused > :not(.w-corner):not(.w-bottom):not(.w-head), .widget.paused .w-bottom .who, .widget.paused .w-head > .tile, .widget.paused .w-head > .switch { opacity: 0.45; filter: grayscale(1); }
.widget.paused.size-small.on { background-color: var(--material); color: var(--text); }
.widget.paused .w-hit { cursor: default; }

/* Medium and large bodies */
.w-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; min-width: 0; min-height: 32px; }
.w-row .steps { flex: 0 1 200px; }
.w-row select { width: auto; min-width: 0; max-width: 62%; }
.w-label { color: var(--muted); font-size: 0.8125rem; }
.w-grow { flex: 1; min-width: 0; }
.w-keys { display: flex; align-items: center; gap: 6px; }
.w-actions { display: grid; min-width: 130px; }
.w-figure { display: grid; line-height: 1.1; }
.w-big { font-size: 2.125rem; font-weight: 600; letter-spacing: -0.03em; font-variant-numeric: tabular-nums; }
.w-figure span { font-size: 0.75rem; color: var(--muted); }
.w-state { font-size: 1.625rem; font-weight: 700; letter-spacing: -0.02em; line-height: 1.1; }
.w-line { font-size: 0.75rem; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.big-state { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.big-state b { font-size: 1.625rem; letter-spacing: -0.02em; line-height: 1.1; }
.widget .w-button { width: 100%; border-radius: 12px; padding: 9px 14px; font-weight: 600; }
.light-large, .cover-large { flex: 1; min-height: 0; display: flex; gap: 16px; align-items: stretch; }
.light-large > .level.vertical { width: 96px; flex: none; }
.light-tall { display: flex; flex-direction: column; gap: 8px; flex: none; width: 96px; }
.light-tall > .level { flex: 1; }
.light-tall > .adaptive-chip { justify-content: center; }
.light-colours { flex: 1; display: grid; align-content: center; gap: 12px; min-width: 0; }
.cover-large > .level.vertical { width: 112px; flex: none; border-radius: 14px; }
.cover-buttons { display: grid; align-content: center; gap: 10px; flex: 1; min-width: 0; }
.cover-buttons .level { width: 100%; }
.toggles { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
.widget .mini-toggle { display: grid; gap: 1px; text-align: left; border-radius: 14px; padding: 9px 11px; background: var(--material-thin); transition: background-color var(--normal) var(--ease-out); }
.mini-toggle b { font-size: 0.8125rem; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mini-toggle span { font-size: 0.6875rem; color: var(--muted); }
.widget .mini-toggle[aria-pressed="true"] { background: var(--tile-on); color: var(--tile-on-text); }
.mini-toggle[aria-pressed="true"] span { color: var(--tile-on-muted); }
.widget .power-button { align-self: center; width: 112px; height: 112px; flex: none; padding: 0; border-radius: 50%; display: grid; place-items: center; }
.power-button svg { width: 40px; height: 40px; fill: none; stroke: currentColor; stroke-width: 2.4; stroke-linecap: round; }
.widget .power-button[aria-pressed="true"] { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: transparent; }
.switch.big { width: 60px; height: 34px; }
.switch.big span { border-radius: 17px; }
.switch.big span::before { width: 28px; height: 28px; }
.switch.big input:checked + span::before { transform: translateX(26px); }

/* A camera on the wall: its picture fills the box. */
.widget.camera-tile { padding: 0; }
.camera-tile .camera-view { position: absolute; inset: 0; margin: 0; aspect-ratio: auto; border-radius: inherit; }
.camera-tile .camera-controls { padding-right: 46px; }
.camera-tile .w-corner .menu-button { color: #fff; background: rgba(20, 22, 30, 0.45); }
.camera-tile.size-small .camera-controls, .camera-tile.size-small .camera-badge:not(.motion):not(.ring) { display: none; }
.camera-tile .w-hit { z-index: 1; }

/* The sheet: every control of one accessory, over the dimmed page. */
.widget-sheet { width: min(600px, calc(100vw - 24px)); max-height: calc(100dvh - 32px); padding: 0; border: 0; background: none; color: inherit; overflow: visible; }
.widget-sheet::backdrop { background: rgba(15, 18, 24, 0.35); -webkit-backdrop-filter: blur(6px); backdrop-filter: blur(6px); }
.widget-sheet[open] { animation: materialize var(--normal) var(--ease-out); }
.sheet-bar { display: flex; justify-content: flex-end; padding: 0 6px 8px; }
.sheet-bar .link { color: #fff; font-weight: 600; }
.widget-sheet .widget-full { margin: 0; max-height: calc(100dvh - 90px); overflow-y: auto; overscroll-behavior: contain; box-shadow: 0 30px 80px rgba(0, 0, 0, 0.35); }
/* On a phone, a sheet rising from the bottom edge, within the thumb's reach, its last control above the home
   indicator. */
@media (max-width: 640px) {
  .widget-sheet { width: 100%; max-width: none; margin: auto 0 0; max-height: calc(100dvh - max(12px, env(safe-area-inset-top))); }
  .widget-sheet[open] { animation: sheet-up 340ms cubic-bezier(0.32, 0.72, 0, 1); }
  .widget-sheet .widget-full { max-height: calc(100dvh - max(12px, env(safe-area-inset-top)) - 44px); border-radius: 26px 26px 0 0; border-bottom: 0; padding-bottom: calc(16px + env(safe-area-inset-bottom)); }
  .sheet-bar { padding: 0 14px 8px; }
}
@keyframes sheet-up { from { transform: translateY(100%); } }
.w-main, .w-side { display: grid; gap: 14px; align-content: start; min-width: 0; }
.w-split { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr); gap: 20px; align-items: start; }
@media (max-width: 640px) { .w-split { grid-template-columns: minmax(0, 1fr); } }
.w-block { display: grid; gap: 10px; padding-top: 12px; border-top: 1px solid var(--line); }
.w-main > .w-block:first-child, .w-side > .w-block:first-child { border-top: 0; padding-top: 0; }
.w-block-body { display: grid; gap: 10px; }

/* Edit: each widget shows its sizes and arrows; the widget itself rests, and drags into place. */
.wall.editing > .widget { cursor: grab; }
.wall.editing > .widget > :not(.edit-bar) { pointer-events: none; }
.wall.editing > .widget::after { content: ""; position: absolute; inset: 0; z-index: 2; border-radius: inherit; background: color-mix(in srgb, var(--bg) 40%, transparent); pointer-events: none; }
.edit-bar { position: absolute; z-index: 3; left: 50%; top: 50%; transform: translate(-50%, -50%); display: flex; gap: 2px; padding: 4px; border-radius: 999px;
  background: var(--material-thick); border: 1px solid var(--edge); box-shadow: var(--shadow-thick); }
.edit-bar button { min-width: 28px; height: 28px; padding: 0 7px; border: 0; background: none; box-shadow: none; border-radius: 999px; font-size: 0.75rem; font-weight: 600; color: var(--muted); }
.edit-bar button:hover { transform: none; color: var(--text); }
.edit-bar button[aria-pressed="true"] { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); }
/* Dragged: the widget lifts over the page and follows the pointer; a dashed slot shows where it will land. In
   Edit, a finger on a widget drags it rather than scrolling the page. */
.wall.editing { user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
.wall.editing > .widget { touch-action: none; }
.widget.lifted { position: fixed; z-index: 40; margin: 0; pointer-events: none; cursor: grabbing; box-shadow: 0 24px 60px rgba(15, 18, 24, 0.3); }
.widget.lifted::after { display: none; }
.wall > .drag-slot::after { display: none; }
.wall > .drag-slot { border: 2px dashed color-mix(in srgb, var(--accent) 55%, transparent); border-radius: var(--radius); background: color-mix(in srgb, var(--accent) 6%, transparent); box-shadow: none; }

/* Segmented: equal columns, a thumb sliding to the one chosen. */
.seg { position: relative; display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; padding: 3px; border-radius: 12px; background: var(--track); }
.seg-thumb { position: absolute; top: 3px; bottom: 3px; left: 3px; width: calc((100% - 6px) / var(--n)); border-radius: 9px; background: var(--control);
  box-shadow: var(--shadow-control), inset 0 1px 0 var(--edge-light); transform: translateX(calc(var(--i, 0) * 100%)); transition: transform 220ms var(--ease-out); }
.seg.unset .seg-thumb { opacity: 0; }
.widget .seg > button { position: relative; z-index: 1; border: 0; background: none; box-shadow: none; color: var(--muted); font-size: 0.8125rem; padding: 7px 6px; border-radius: 9px; transform: none; transition: color var(--normal) var(--ease-out); }
.widget .seg > button[aria-checked="true"] { color: var(--text); font-weight: 600; }
.widget .seg > button:focus-visible { outline-offset: -2px; }

/* Level: a pill the fill grows in, dragged one to one; a track variant (white temperature) has a mark. */
.level { position: relative; height: 44px; border-radius: 14px; background: var(--track); overflow: hidden; touch-action: none; cursor: ew-resize; user-select: none; -webkit-user-select: none; }
.level-fill { position: absolute; inset: 0; transform-origin: left center; background: var(--fill, linear-gradient(90deg, var(--accent-2), var(--accent))); }
.level:not(.dragging) .level-fill { transition: transform var(--normal) var(--ease-out); }
.level-label, .level-text { position: absolute; top: 0; bottom: 0; display: flex; align-items: center; font-size: 0.8125rem; font-weight: 600; pointer-events: none; }
.level-label { left: 14px; }
.level-text { right: 14px; font-variant-numeric: tabular-nums; }
.level.track { background: var(--track); }
.level.track .level-label, .level.track .level-text { color: #2a2620; }
.level-mark { position: absolute; top: 6px; bottom: 6px; width: 6px; margin-left: -3px; border-radius: 3px; background: var(--knob); box-shadow: 0 1px 4px rgba(0, 0, 0, 0.35); }
/* Tall: filled from the bottom, the value at the top, the label at the foot. */
.level.vertical { height: auto; border-radius: 20px; cursor: ns-resize; }
.level.vertical .level-fill { transform-origin: center bottom; }
.level.vertical .level-label, .level.vertical .level-text { left: 0; right: 0; justify-content: center; }
.level.vertical .level-label { top: auto; bottom: 12px; }
.level.vertical .level-text { top: 12px; bottom: auto; font-size: 0.9375rem; }
.level.vertical .level-mark { top: auto; bottom: auto; left: 10px; right: 10px; width: auto; height: 6px; margin: -3px 0 0; }
.level:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.level.thin { height: 28px; border-radius: 9px; }
.level.thin .level-text { right: 10px; font-size: 0.75rem; }

/* Steps: a few positions as rising bars. */
.steps { display: flex; align-items: flex-end; gap: 6px; height: 32px; }
.widget .steps > button { flex: 1; padding: 0; border: 0; border-radius: 6px; background: var(--track); box-shadow: none; transform: none; transition: background-color var(--fast) var(--ease-out); }
.widget .steps > button.lit { background: var(--steps, var(--accent)); }

/* Setpoint and gauge */
.setpoints { display: grid; gap: 14px; justify-items: center; align-content: center; }
.row-setpoints { justify-items: start; }
.setpoint { display: grid; grid-template-columns: 36px auto 36px; align-items: center; gap: 8px; justify-items: center; }
.sp-value { display: grid; justify-items: center; line-height: 1.15; min-width: 4.4em; }
.sp-value b { font-size: 1.375rem; font-variant-numeric: tabular-nums; letter-spacing: -0.01em; }
.sp-value span { font-size: 0.75rem; color: var(--muted); }
.widget .round { width: 36px; height: 36px; padding: 0; border-radius: 50%; display: grid; place-items: center; }
.widget .round svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 2.4; stroke-linecap: round; }
.climate-hero { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 12px; }
@container widgets (max-width: 400px) { .climate-hero { grid-template-columns: minmax(0, 1fr); } }
.gauge { width: 100%; max-width: 230px; height: auto; display: block; margin: 0 auto; overflow: visible; }
.gauge-track, .gauge-band { fill: none; stroke-width: 12; stroke-linecap: round; }
.gauge-track { stroke: var(--track); }
.gauge-band { transition: stroke var(--normal) var(--ease-out); }
.gauge-value { fill: var(--text); font: 600 40px var(--font); letter-spacing: -0.03em; font-variant-numeric: tabular-nums; }
.gauge-caption, .gauge-end { fill: var(--muted); font: 500 12px var(--font); }
.gauge-dot { fill: var(--knob); stroke: var(--text); stroke-width: 2; }
.gauge-target { stroke: var(--text); stroke-width: 3; stroke-linecap: round; }

/* Facets: readouts, meters, chips, swatches, pills */
.readouts { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 8px; }
.readouts.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.readouts.four { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.widget:not(.widget-full) .readouts { gap: 6px; }
.widget:not(.widget-full) .readout { padding: 7px 9px; border-radius: 12px; }
.widget:not(.widget-full) .readout-value { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.widget:not(.widget-full) .readout-value b { font-size: 1rem; }
.readouts.four .readout-value b { font-size: 0.875rem; }
.readouts.four .readout { padding: 6px 7px; }
.widget:not(.widget-full) .readout-label { font-size: 0.6875rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.readout { padding: 10px 12px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--edge); display: grid; gap: 2px; min-width: 0; }
.readout-value b { font-size: 1.125rem; font-variant-numeric: tabular-nums; letter-spacing: -0.01em; overflow-wrap: anywhere; }
.readout-value small { font-size: 0.75rem; font-weight: 500; color: var(--muted); margin-left: 3px; }
.readout-label { font-size: 0.75rem; color: var(--muted); overflow-wrap: anywhere; }
.readout[data-tone="warn"] b { color: var(--warn); } .readout[data-tone="ok"] b { color: var(--ok); } .readout[data-tone="muted"] b { color: var(--muted); }
.readout-extra { display: flex; gap: 3px; }
.readout-extra:empty { display: none; }
.readout-extra i { flex: 1; height: 4px; border-radius: 2px; background: var(--track); }
.readout-extra i.lit { background: var(--ok); }
.meter { display: grid; gap: 6px; font-size: 0.8125rem; }
.meter-row { display: flex; justify-content: space-between; color: var(--muted); }
.meter-row b { color: var(--text); font-variant-numeric: tabular-nums; }
.meter-bar { height: 6px; border-radius: 3px; background: var(--track); overflow: hidden; }
.meter-bar i { display: block; height: 100%; transform-origin: left; background: var(--ok); border-radius: 3px; }
.meter.low .meter-bar i { background: var(--warn); }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chips:empty { display: none; }
.widget .chip { font-size: 0.8125rem; padding: 6px 12px; transition: background-color var(--normal) var(--ease-out), color var(--normal) var(--ease-out), transform var(--fast) var(--ease-out); }
.widget .chip[aria-pressed="true"] { background: var(--accent); border-color: transparent; color: var(--accent-text); }
.swatches { display: flex; flex-wrap: wrap; gap: 8px; }
.swatches.grid { display: grid; grid-template-columns: repeat(4, 30px); gap: 10px; }
/* Adaptive Lighting: the day's whites, a sun on them; dimmed until the Home app has sent a schedule to resume. */
.widget .swatch.adaptive { display: grid; place-items: center; color: #5c3b00; background: linear-gradient(135deg, #ffb24d, #fff1d6 55%, #cfe3ff); }
.widget .swatch.adaptive svg, .widget .round.adaptive svg, .adaptive-chip svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; }
.size-medium .swatch.adaptive svg { width: 13px; height: 13px; }
.widget .round.adaptive[aria-pressed="true"] { background: linear-gradient(135deg, #ffb24d, #fff1d6 55%, #cfe3ff); color: #5c3b00; border-color: transparent; }
.widget .adaptive-chip { display: inline-flex; align-items: center; gap: 6px; }
.widget .adaptive.unset { opacity: 0.55; }
.widget .swatch { width: 30px; height: 30px; padding: 0; border-radius: 50%; background: var(--swatch); border: 2px solid var(--edge); }
.widget .swatch[aria-checked="true"] { outline: 2px solid var(--text); outline-offset: 1px; }
/* Room for that ring: a box that clips (a fixed widget's body) would cut it. */
.widget .swatches { padding: 3px; }
.pill { display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px; border-radius: 999px; font-size: 0.75rem; font-weight: 600; background: var(--material-thin); border: 1px solid var(--edge); }
.pill::before { content: ""; width: 7px; height: 7px; border-radius: 50%; background: var(--muted); }
.pill.ok::before { background: var(--ok); } .pill.warn::before { background: var(--warn); } .pill.bad::before { background: var(--error); }
.lock-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 10px; padding-top: 12px; border-top: 1px solid var(--line); }
.w-main > .lock-row:first-child { border-top: 0; padding-top: 0; }
.lock-name { display: grid; gap: 4px; justify-items: start; }
.lock-row .hold, .lock-row .w-button { width: auto; }

/* Hold to confirm: the fill runs while held and snaps back when let go early. */
.widget .hold { position: relative; overflow: hidden; width: 100%; border-radius: 14px; padding: 10px 16px; font-weight: 600; touch-action: none; user-select: none; -webkit-user-select: none; }
.hold-fill { position: absolute; inset: 0; display: grid; place-items: center; background: var(--warn); color: #fff; clip-path: inset(0 100% 0 0); transition: clip-path 200ms var(--ease-out); }
.hold.holding .hold-fill { clip-path: inset(0 0 0 0); transition: clip-path 900ms linear; }

/* Valve: a round run button whose ring empties as the time runs out. */
.valve { display: grid; justify-items: center; gap: 14px; }
.valve .seg { width: 100%; }
.widget .valve-button { position: relative; width: 128px; height: 128px; padding: 0; border-radius: 50%; display: grid; place-items: center; }
.valve-button svg { position: absolute; inset: 0; width: 100%; height: 100%; transform: rotate(-90deg); }
.valve-button .ring-track, .valve-button .ring { fill: none; stroke-width: 6; }
.valve-button .ring-track { stroke: var(--track); }
.valve-button .ring { stroke: var(--cool); stroke-linecap: round; transition: stroke-dashoffset 1s linear; }
.valve-text { display: grid; justify-items: center; line-height: 1.2; }
.valve-text b { font-size: 1.125rem; }
.valve-text span { font-size: 0.75rem; color: var(--muted); font-variant-numeric: tabular-nums; }

@media (prefers-reduced-motion: reduce) {
  .seg-thumb, .level-fill, .widget .tile, .widget.size-small, .w-shade, .valve-button .ring { transition-duration: 0ms !important; }
  .size-small:has(> .w-hit:active) { transform: none; }
  .widget-sheet[open] { animation-name: fade; }
}
@media (prefers-contrast: more) { .tile.is-off { background: #687284; } }

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
.menu [role="menuitem"], .menu [role="menuitemradio"] {
  display: flex; align-items: center; gap: 10px; width: 100%; padding: 8px 12px; border: 0; border-radius: 10px;
  background: none; box-shadow: none; color: var(--text); font: inherit; font-size: 0.875rem; text-align: left; text-decoration: none; cursor: pointer;
}
.menu [role="menuitem"]:hover, .menu [role="menuitem"]:focus-visible, .menu [role="menuitemradio"]:hover, .menu [role="menuitemradio"]:focus-visible { background: var(--accent); color: var(--accent-text); outline: none; transform: none; }
/* A choice among several (a widget's size): the chosen one ticked at the right. */
.menu-check { margin-left: auto; font-weight: 700; color: var(--accent); }
.menu [role="menuitemradio"]:hover .menu-check, .menu [role="menuitemradio"]:focus-visible .menu-check { color: inherit; }
.menu-separator { border: 0; border-top: 1px solid var(--line); margin: 4px 8px; }
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
/* A newer release, under the summary: how to upgrade this install, its command with Copy, the notes folded. */
.update-card { margin-top: 14px; display: grid; grid-template-columns: minmax(0, 1fr); gap: 12px; }
.update-card > p { margin: 0; }
.update-card .actions { margin-top: 0; flex-wrap: wrap; }
.update-command { display: flex; align-items: center; gap: 8px; padding: 5px 5px 5px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); }
.update-command code { flex: 1; min-width: 0; overflow-x: auto; white-space: nowrap; font: 0.8125rem/1.5 var(--mono); scrollbar-width: none; }
.update-command button { flex: none; padding: 5px 12px; font-size: 0.8125rem; }
.update-card details.more-options { margin: 0; }
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
/* The charts as a table: a card of its own, the header pinned while the rows scroll, the groups (homeswift, Home app
   requests, plugin device calls) under a header each with a rule between them, numbers right-aligned in tabular
   figures, an empty cell quiet. */
.chart-table { margin-top: 12px; }
.chart-table .table-scroll {
  overflow: auto; max-height: 420px; margin-top: 10px; border-radius: 14px; border: 1px solid var(--edge);
  background: var(--material-solid); box-shadow: var(--shadow-control);
}
.chart-table table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 0.8125rem; font-variant-numeric: tabular-nums; white-space: nowrap; }
.chart-table thead { position: sticky; top: 0; z-index: 1; background: var(--material-solid); }
.chart-table th, .chart-table td { padding: 7px 14px; text-align: right; border-bottom: 1px solid var(--line); }
.chart-table thead th { color: var(--muted); font-weight: 500; font-size: 0.75rem; }
.chart-table thead .groups th { color: var(--text); font-weight: 600; font-size: 0.8125rem; text-align: center; padding-bottom: 4px; border-bottom-color: transparent; }
.chart-table thead .groups th.time { text-align: left; vertical-align: bottom; padding-bottom: 7px; border-bottom-color: var(--line); }
.chart-table .group-start { border-left: 1px solid var(--line); }
.chart-table tbody th.time { text-align: left; font-weight: 500; color: var(--text); }
.chart-table td.empty { color: var(--muted); opacity: 0.55; }
.chart-table tbody tr:last-child > * { border-bottom: 0; }
.chart-table tbody tr:hover > * { background: var(--material-thin); }
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
/* A payload taken out of a line: a small JSON button after its marker, the JSON formatted under the line. */
.log-details-toggle {
  padding: 0 7px; margin: 0; border-radius: 6px; font: 600 0.6875rem/1.5 var(--mono); letter-spacing: 0.02em; vertical-align: baseline;
  color: var(--muted); background: var(--material-thin); border: 1px solid var(--line); box-shadow: none;
}
.log-details-toggle:hover { color: var(--text); transform: none; }
.log-details-toggle[aria-expanded="true"] { color: var(--accent); border-color: var(--accent); }
.log-line .log-details { grid-column: 1 / -1; margin: 4px 0 6px; max-height: 420px; overflow: auto; font-size: 0.75rem; }
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
  .chat {
    top: auto; bottom: var(--keyboard, 0px); left: 0; right: 0; width: auto; transform-origin: bottom center;
    height: min(88dvh, 780px, calc(var(--visible, 100dvh) - max(12px, env(safe-area-inset-top))));
  }
  .chat-surface { border-radius: 26px 26px 0 0; padding-bottom: env(safe-area-inset-bottom); border-bottom: 0; }
  /* On the keyboard: no home indicator to clear, and the voice line and the provider's note give the log room. */
  .chat.keyboard .chat-surface { padding-bottom: 0; }
  .chat.keyboard .chat-voice, .chat.keyboard .chat-foot:empty { display: none; }
  .chat.keyboard .chat-foot { margin: 6px 16px 8px; }
  /* 16px, or Safari zooms the page into the field and leaves it there. */
  .chat-composer textarea, .chat .chat-voice select.popup { font-size: 16px; }
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

"""#),
        "widgets.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// Accessory widgets, for the Accessories page and plugin pages: each accessory drawn by the widget of its kind,
// chosen from its primary service (an air conditioner's gauge and modes, a light's brightness and colours, a
// shutter's tile, a gate held to open), all built from the same few controls. The services an accessory links
// to its main one become the widget's facets (chips, readouts, meters), and what no widget shows stays
// reachable under More, as rows. On the wall a widget is a fixed box: small (1×1, a tile a tap acts on), medium
// (2×1, its main control) or large (2×2); its ⋯ menu opens every control in a sheet. Loaded after common.js,
// remote.js and camera.js.
//
//   HomeswiftWidgets.card(accessory, { size, actions })   an accessory of /api/accessories at a size
//   HomeswiftWidgets.open(accessory, { actions })         every control of it, in a sheet
//   HomeswiftWidgets.kindOf(accessory)                    { kind, size }: its kind of widget and that kind's size
//   HomeswiftWidgets.event(event)                         an "accessory" event of /api/events, for the cards shown
//   HomeswiftWidgets.listen()                             a plugin page's own event stream, for its cards
(() => {
  "use strict";

  const { el, menuButton, api } = HomeswiftCommon;

  // ---- Values -------------------------------------------------------------------------------------------

  const enumLabels = {
    "Lock Target State": ["Unsecured", "Secured"], "Lock Current State": ["Unsecured", "Secured", "Jammed", "Unknown"],
    "Target Door State": ["Open", "Closed"], "Current Door State": ["Open", "Closed", "Opening", "Closing", "Stopped"],
    "Security System Target State": ["Home", "Away", "Night", "Off"], "Security System Current State": ["Home", "Away", "Night", "Off", "Alarm"],
    "Active": ["Inactive", "Active"], "Target Heating Cooling State": ["Off", "Heat", "Cool", "Auto"], "Current Heating Cooling State": ["Off", "Heating", "Cooling"],
    "Target Heater-Cooler State": ["Auto", "Heat", "Cool"], "Current Heater-Cooler State": ["Inactive", "Idle", "Heating", "Cooling"],
    "Target Fan State": ["Manual", "Auto"], "Current Fan State": ["Inactive", "Idle", "Blowing"], "Rotation Direction": ["Clockwise", "Counter-clockwise"],
    "Swing Mode": ["Disabled", "Enabled"], "Programmable Switch Event": ["Single press", "Double press", "Long press"],
    "Contact Sensor State": ["Contact", "No contact"], "Temperature Display Units": ["Celsius", "Fahrenheit"],
    "Air Quality": ["Unknown", "Excellent", "Good", "Fair", "Inferior", "Poor"], "Charging State": ["Not charging", "Charging", "Not chargeable"],
    "Status Low Battery": ["Normal", "Low"], "Leak Detected": ["Dry", "Leak"], "Smoke Detected": ["Clear", "Smoke"], "Carbon Monoxide Detected": ["Normal", "Abnormal"],
    "Carbon Dioxide Detected": ["Normal", "Abnormal"], "Target Air Purifier State": ["Manual", "Auto"], "Current Air Purifier State": ["Inactive", "Idle", "Purifying"],
    "Motion Detected": ["No motion", "Motion"], "Occupancy Detected": ["Not occupied", "Occupied"], "Mute": ["Off", "On"],
    "Position State": ["Closing", "Opening", "Stopped"], "Filter Change Indication": ["OK", "Replace"], "In Use": ["Not in use", "In use"],
    "Lock Physical Controls": ["Unlocked", "Locked"], "Valve Type": ["Valve", "Irrigation", "Shower head", "Faucet"],
  };
  // What HomeKit needs to describe an accessory rather than a state a person reads or changes: kept off the page.
  const plumbing = new Set([
    "Name", "Configured Name", "Identifier", "Is Configured", "Current Visibility State", "Target Visibility State", "Input Source Type",
    "Input Device Type", "Sleep Discovery Mode", "Display Order", "Closed Captions", "Picture Mode", "Power Mode Selection",
    "Volume Control Type", "Current Media State", "Target Media State", "Version",
    // Adaptive Lighting's bookkeeping.
    "Characteristic Value Active Transition Count", "Characteristic Value Transition Control", "Supported Characteristic Value Transition Configuration",
  ]);
  // Inputs are chosen with the Input picker; the protocol version is HomeKit's business.
  const quietServices = new Set(["InputSource", "ProtocolInformation"]);
  // On and off as 1 and 0.
  const numericSwitches = new Set(["HomeKit Camera Active"]);
  const rowLabels = {
    "Active Identifier": "Input", "Remote Key": "Remote", "Volume Selector": "Volume",
    "HomeKit Camera Active": "On in the Home app", "Camera Operating Mode Indicator": "Status light",
  };

  const serviceKey = (service) => service.subtype || service.type;
  /// "Color Temperature" reads "Color temperature".
  const sentence = (type) => type.charAt(0) + type.slice(1).toLowerCase();
  /// The text for an enumerated value, or the value itself.
  function labelFor(type, value) {
    const labels = enumLabels[type];
    // Motion Detected and the like are booleans whose labels are listed for 0 and 1.
    const index = typeof value === "boolean" ? Number(value) : value;
    return labels && labels[index] !== undefined ? labels[index] : String(value);
  }
  const units = { celsius: " °C", percentage: " %", lux: " lx", seconds: " s", arcdegrees: "°" };
  const unit = (characteristic) => units[characteristic.unit] || "";
  function formatValue(characteristic) {
    if (characteristic.format === "bool") return characteristic.value ? "On" : "Off";
    if (characteristic.value === null || characteristic.value === undefined) return "";
    return `${characteristic.value}${unit(characteristic)}`;
  }
  const canWrite = (characteristic) => !!characteristic && characteristic.permissions.includes("pw");
  const canRead = (characteristic) => !!characteristic && characteristic.permissions.includes("pr");
  const isOn = (characteristic) => characteristic?.value === true || characteristic?.value === 1;
  const numberOf = (characteristic, fallback = 0) => typeof characteristic?.value === "number" ? characteristic.value : fallback;
  /// On and off in the characteristic's own format: a bool, or 1 and 0 (Active).
  const onValue = (characteristic, on) => characteristic.format === "bool" ? on : on ? 1 : 0;
  /// The positions of a range when there are only a few (a fan's speeds in steps of 20), else Infinity.
  function positions(characteristic) {
    const { minValue: min, maxValue: max, minStep: step } = characteristic;
    return min === undefined || max === undefined || !step ? Infinity : Math.round((max - min) / step);
  }
  const degrees = (value) => `${Number.isInteger(value) ? value : value.toFixed(1)}°`;
  const clock = (seconds) => `${Math.floor(seconds / 60)}:${String(Math.max(0, Math.round(seconds % 60))).padStart(2, "0")}`;
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  /// A colour temperature in mireds (what HomeKit sends) in kelvin, to the nearest 50.
  const kelvin = (mireds) => Math.round(1e6 / mireds / 50) * 50;
  /// About the colour of white light at `k` kelvin, for a tile and the temperature track.
  function whiteColor(k, lightness = 70) {
    const t = clamp((k - 2700) / (6500 - 2700), 0, 1);
    return `hsl(${Math.round(32 + t * 178)} ${Math.round(90 - t * 70)}% ${lightness}%)`;
  }

  function describeModel(accessory) {
    const manufacturer = accessory.manufacturer || "";
    const model = accessory.model || "";
    return model.toLowerCase().startsWith(manufacturer.toLowerCase()) ? model : `${manufacturer} ${model}`.trim();
  }

  /// A service's name inside its accessory's card: "Living Room TV HDMI 1" reads "HDMI 1" in the Living Room TV's
  /// card; a service named like its accessory reads as its subtype ("climateControl:indoor_silent_mode" is "Indoor
  /// silent mode"), else as its type.
  function shortName(accessory, service) {
    const name = service.name;
    if (name && name !== accessory.name) return name.startsWith(`${accessory.name} `) ? name.slice(accessory.name.length + 1) : name;
    const words = (text) => text.replace(/([a-z])([A-Z0-9])/g, "$1 $2").replace(/[_-]+/g, " ").trim();
    if (service.subtype) {
      const parts = service.subtype.split(/[.:/]/).filter((part) => part && !/^[0-9a-f]{12,}$/i.test(part));
      const last = parts[parts.length - 1];
      if (last) return sentence(words(last));
    }
    return words(service.type);
  }

  // ---- An accessory on the page: its values, writes and painters --------------------------------------

  const cards = new Set();

  function context(accessory, options = {}) {
    const services = accessory.services.filter((service) => !service.internal);
    const ctx = {
      accessory, services, options,
      used: new Set(),       // the characteristics a widget shows; the rest go under More
      painters: [],
      born: Date.now(), node: null,
    };
    ctx.find = (type) => services.find((service) => service.type === type);
    ctx.all = (type) => services.filter((service) => service.type === type);
    ctx.char = (service, type) => service?.characteristics.find((characteristic) => characteristic.type === type);
    /// Marks characteristics as shown; answers the first.
    ctx.use = (...characteristics) => { for (const c of characteristics) if (c) ctx.used.add(c); return characteristics[0]; };
    ctx.take = (service, type) => ctx.use(ctx.char(service, type));
    ctx.useAll = (service) => service.characteristics.forEach((c) => ctx.used.add(c));
    /// Runs `paint` now and after every change of a value of this accessory.
    ctx.watch = (paint) => { ctx.painters.push(paint); paint(); };
    ctx.paint = () => { for (const paint of ctx.painters) paint(); };
    /// Writes at once on the page (the controls and the status follow), then to the device; a refusal puts the
    /// value back and says why in the status line. A security control (a lock, a door, an alarm, what a plugin
    /// marked) asks first unless the control was held to confirm (`held`).
    ctx.write = async (service, characteristic, value, { held = false } = {}) => {
      // A paused plugin's accessory answers nothing: say so rather than ask.
      if (accessory.paused) { ctx.flash(`${accessory.platformName ?? "Its plugin"} is paused: resume it to control ${accessory.name}`); return; }
      if (characteristic.security && !held) {
        const label = characteristic.format === "bool" ? (value ? "On" : "Off") : labelFor(characteristic.type, value);
        if (!confirm(`Set ${sentence(characteristic.type).toLowerCase()} of ${accessory.name} to ${label}?`)) { ctx.paint(); return; }
      }
      const before = characteristic.value;
      characteristic.value = value;
      ctx.paint();
      try {
        await put(service, characteristic, value);
      } catch (e) {
        if (e.message === "signed out") return;
        characteristic.value = before;
        ctx.flash(e.message);
      }
    };
    /// A write with no value to keep (a remote's key): its failure is the caller's to show.
    ctx.send = (service, characteristic, value) => put(service, characteristic, value);
    const put = (service, characteristic, value) => api(`/api/accessories/${encodeURIComponent(accessory.id)}`, {
      method: "PUT", body: { service: serviceKey(service), characteristic: characteristic.type, value } });
    ctx.flashing = null;
    ctx.flash = (text) => {
      clearTimeout(ctx.flashTimer);
      ctx.flashing = text;
      ctx.paint();
      ctx.flashTimer = setTimeout(() => { ctx.flashing = null; ctx.paint(); }, 5000);
    };
    return ctx;
  }

  /// An accessory event from the page's event stream: the new value, painted on the cards of that accessory.
  function event({ id, service, subtype, characteristic, value }) {
    const now = Date.now();
    for (const ctx of cards) {
      // A card no longer on the page (the view changed) is let go; a new one may not be attached yet.
      if (!ctx.node?.isConnected) { if (now - ctx.born > 2000) cards.delete(ctx); continue; }
      if (ctx.accessory.id !== id) continue;
      const key = subtype || service;
      const owner = ctx.accessory.services.find((s) => (!key || serviceKey(s) === key) && s.characteristics.some((c) => c.type === characteristic));
      const target = owner && owner.characteristics.find((c) => c.type === characteristic);
      if (!target) continue;
      target.value = value;
      ctx.paint();
    }
  }

  /// For a plugin page: the bridge's events, so the cards it shows follow the devices.
  let stream = null;
  function listen() {
    if (stream) return;
    stream = new EventSource("/api/events");
    stream.addEventListener("accessory", (message) => {
      const data = JSON.parse(message.data);
      window.HomeswiftCamera?.event(data);
      event(data);
    });
  }

  // ---- Controls -----------------------------------------------------------------------------------------
  // Each answers its node and set(), which shows a value without calling back; a control being changed by
  // the pointer keeps what the pointer says until it is let go.

  function toggle(label, onChange) {
    const input = el("input", { type: "checkbox", "aria-label": label });
    input.addEventListener("change", () => onChange(input.checked));
    return { node: el("label", { class: "switch" }, input, el("span")), set: (on) => { input.checked = on; } };
  }

  /// Two to four choices side by side, a thumb sliding to the one chosen; the arrow keys move it.
  function segmented(options, label, onChange) {
    const thumb = el("span", { class: "seg-thumb", "aria-hidden": "true" });
    const node = el("div", { class: "seg", role: "radiogroup", "aria-label": label }, thumb);
    node.style.setProperty("--n", options.length);
    const buttons = options.map((option, index) => {
      const button = el("button", { type: "button", role: "radio", text: option.label, onclick: () => choose(index) });
      button.addEventListener("keydown", (event) => {
        const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
        if (!step) return;
        event.preventDefault();
        const next = (index + step + options.length) % options.length;
        choose(next);
        buttons[next].focus();
      });
      return button;
    });
    node.append(...buttons);
    let current = -1;
    function show(index) {
      current = index;
      node.classList.toggle("unset", index < 0);
      node.style.setProperty("--i", Math.max(0, index));
      buttons.forEach((button, i) => { button.setAttribute("aria-checked", String(i === index)); button.tabIndex = i === Math.max(0, index) ? 0 : -1; });
    }
    function choose(index) { if (index === current) return; show(index); onChange(options[index].value); }
    show(-1);
    return { node, set: (value) => show(options.findIndex((option) => option.value === value)) };
  }

  /// A level: a pill whose fill (or, with `gradient`, a mark on the gradient) follows the pointer one to one;
  /// `onCommit` runs when it is let go, and after a pause in the arrow keys. `vertical`: a tall one, filled from
  /// the bottom, as the Home app's brightness.
  function level({ label, min, max, step = 1, format, gradient, fill, thin = false, showLabel = true, vertical = false }, onCommit) {
    const node = el("div", { class: `level${gradient ? " track" : ""}${thin ? " thin" : ""}${vertical ? " vertical" : ""}`, role: "slider", tabIndex: 0,
      "aria-label": label, "aria-valuemin": min, "aria-valuemax": max, "aria-orientation": vertical ? "vertical" : null });
    if (gradient) node.style.setProperty("--track", gradient);
    if (fill) node.style.setProperty("--fill", fill);
    const bar = gradient ? el("span", { class: "level-mark" }) : el("span", { class: "level-fill" });
    const text = el("span", { class: "level-text" });
    node.append(bar, showLabel ? el("span", { class: "level-label", text: label }) : null, text);
    let value = min, dragging = false, keyTimer = null;
    function show(next) {
      value = clamp(Math.round((next - min) / step) * step + min, min, max);
      const share = max > min ? (value - min) / (max - min) : 0;
      if (gradient && vertical) bar.style.top = `calc(100% - 10px - ${share} * (100% - 20px))`;
      else if (gradient) bar.style.left = `calc(10px + ${share} * (100% - 20px))`;
      else bar.style.transform = vertical ? `scaleY(${share})` : `scaleX(${share})`;
      text.textContent = format(value);
      node.setAttribute("aria-valuenow", value);
      node.setAttribute("aria-valuetext", format(value));
    }
    const at = (event) => {
      const box = node.getBoundingClientRect();
      const share = vertical ? 1 - (event.clientY - box.top) / box.height : (event.clientX - box.left) / box.width;
      return min + clamp(share, 0, 1) * (max - min);
    };
    node.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      dragging = true;
      node.setPointerCapture(event.pointerId);
      node.classList.add("dragging");
      show(at(event));
    });
    node.addEventListener("pointermove", (event) => { if (dragging) show(at(event)); });
    const end = () => { if (!dragging) return; dragging = false; node.classList.remove("dragging"); onCommit(value); };
    node.addEventListener("pointerup", end);
    node.addEventListener("pointercancel", end);
    node.addEventListener("keydown", (event) => {
      const big = Math.max(step, (max - min) / 10);
      const delta = { ArrowRight: step, ArrowUp: step, ArrowLeft: -step, ArrowDown: -step, PageUp: big, PageDown: -big }[event.key];
      if (delta === undefined && event.key !== "Home" && event.key !== "End") return;
      event.preventDefault();
      show(delta === undefined ? (event.key === "Home" ? min : max) : value + delta);
      clearTimeout(keyTimer);
      keyTimer = setTimeout(() => { keyTimer = null; onCommit(value); }, 350);
    });
    show(min);
    return { node, set: (next) => { if (!dragging && !keyTimer) show(next); } };
  }

  /// A few positions as rising bars, as a fan's speeds read: the bar pressed and those under it lit.
  function steps({ label, count }, onChange) {
    const node = el("div", { class: "steps", role: "radiogroup", "aria-label": label });
    const bars = Array.from({ length: count }, (_, index) => {
      const bar = el("button", { type: "button", role: "radio", "aria-label": `${label} ${index + 1} of ${count}`, onclick: () => { show(index + 1); onChange(index + 1); } });
      bar.style.height = `${Math.round(38 + (62 * (index + 1)) / count)}%`;
      return bar;
    });
    node.append(...bars);
    function show(n) {
      bars.forEach((bar, index) => {
        bar.classList.toggle("lit", index < n);
        bar.setAttribute("aria-checked", String(index + 1 === n));
        bar.tabIndex = index + 1 === Math.max(1, n) ? 0 : -1;
      });
    }
    node.addEventListener("keydown", (event) => {
      const step = { ArrowRight: 1, ArrowUp: 1, ArrowLeft: -1, ArrowDown: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      const current = bars.filter((bar) => bar.classList.contains("lit")).length;
      const next = clamp(current + step, 1, count);
      show(next); bars[next - 1].focus(); onChange(next);
    });
    return { node, set: show };
  }

  /// A temperature to reach: − the value +, written after a pause so a few presses make one write.
  function setpoint({ label, min, max, step }, onChange) {
    let value = min, timer = null;
    const number = el("b");
    const caption = el("span", { text: label });
    const show = (next) => { value = clamp(Math.round(next / step) * step, min, max); number.textContent = degrees(+value.toFixed(2)); };
    const bump = (delta) => {
      show(value + delta);
      clearTimeout(timer);
      timer = setTimeout(() => { timer = null; onChange(value); }, 600);
    };
    const round = (glyph, text, delta) => el("button", { type: "button", class: "round", "aria-label": `${text} ${label.toLowerCase()}`, onclick: () => bump(delta) }, icon(glyph));
    const node = el("div", { class: "setpoint" }, round("minus", "Lower", -step), el("div", { class: "sp-value", "aria-live": "polite" }, number, caption), round("plus", "Raise", step));
    return { node, set: (next) => { if (!timer) show(next); } };
  }

  /// A 240° arc from `min` to `max`: the reading as a dot, a target as a tick, the band between them in the mode's colour.
  function gauge({ min, max }) {
    const cx = 100, cy = 96, r = 80, start = 150, sweep = 240;
    const angle = (value) => start + sweep * clamp((value - min) / (max - min), 0, 1);
    const point = (deg, radius = r) => [cx + radius * Math.cos((deg * Math.PI) / 180), cy + radius * Math.sin((deg * Math.PI) / 180)];
    const arc = (a, b) => {
      const [x1, y1] = point(a), [x2, y2] = point(b);
      return `M${x1.toFixed(2)} ${y1.toFixed(2)} A${r} ${r} 0 ${b - a > 180 ? 1 : 0} 1 ${x2.toFixed(2)} ${y2.toFixed(2)}`;
    };
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 200 172");
    svg.setAttribute("class", "gauge");
    svg.setAttribute("role", "img");
    const [left] = point(start), [right] = point(start + sweep);
    svg.innerHTML = `<path class="gauge-track" d="${arc(start, start + sweep)}"/><path class="gauge-band"/><line class="gauge-target"/><circle class="gauge-dot" r="7"/>`
      + `<text class="gauge-value" x="100" y="104" text-anchor="middle"></text><text class="gauge-caption" x="100" y="128" text-anchor="middle"></text>`
      + `<text class="gauge-end" x="${left.toFixed(0)}" y="168" text-anchor="middle">${degrees(min)}</text><text class="gauge-end" x="${right.toFixed(0)}" y="168" text-anchor="middle">${degrees(max)}</text>`;
    const band = svg.querySelector(".gauge-band"), tick = svg.querySelector(".gauge-target"), dot = svg.querySelector(".gauge-dot");
    const [valueText, captionText] = svg.querySelectorAll("text");
    function update({ value, from, to, color, caption }) {
      const known = typeof value === "number";
      dot.style.display = known ? "" : "none";
      if (known) { const [x, y] = point(angle(value)); dot.setAttribute("cx", x.toFixed(2)); dot.setAttribute("cy", y.toFixed(2)); }
      valueText.textContent = known ? degrees(+value.toFixed(1)) : "–";
      captionText.textContent = caption;
      const banded = typeof from === "number" && typeof to === "number";
      const a = banded ? angle(Math.min(from, to)) : 0, b = banded ? angle(Math.max(from, to)) : 0;
      band.setAttribute("d", banded && b - a >= 0.5 ? arc(a, b) : "");
      band.style.stroke = color || "";
      tick.style.display = typeof to === "number" ? "" : "none";
      if (typeof to === "number") {
        const [x1, y1] = point(angle(to), r - 13), [x2, y2] = point(angle(to), r + 13);
        tick.setAttribute("x1", x1.toFixed(2)); tick.setAttribute("y1", y1.toFixed(2)); tick.setAttribute("x2", x2.toFixed(2)); tick.setAttribute("y2", y2.toFixed(2));
      }
      svg.setAttribute("aria-label", known ? `${caption}: ${degrees(+value.toFixed(1))}` : caption);
    }
    return { node: svg, update };
  }

  /// A value read, not changed: big, its unit small, its label under it.
  function readout(label) {
    const number = el("b"), small = el("small"), extra = el("span", { class: "readout-extra" });
    const node = el("div", { class: "readout" }, el("span", { class: "readout-value" }, number, small), el("span", { class: "readout-label", text: label }), extra);
    return {
      node,
      set(text, unitText = "", tone = "", scale = null) {
        number.textContent = text;
        small.textContent = unitText;
        node.dataset.tone = tone;
        // A level out of five (air quality) as five short bars.
        extra.replaceChildren(...(scale ? Array.from({ length: 5 }, (_, i) => el("i", { class: i < scale ? "lit" : "" })) : []));
      },
    };
  }

  /// A level that wears down: a filter's life, a battery. Amber under 10 %.
  function meter(label) {
    const amount = el("b"), fillBar = el("i");
    const node = el("div", { class: "meter", role: "meter", "aria-label": label, "aria-valuemin": 0, "aria-valuemax": 100 },
      el("div", { class: "meter-row" }, el("span", { text: label }), amount), el("div", { class: "meter-bar" }, fillBar));
    return {
      node,
      set(percent) {
        amount.textContent = `${percent} %`;
        fillBar.style.transform = `scaleX(${clamp(percent, 0, 100) / 100})`;
        node.classList.toggle("low", percent < 10);
        node.setAttribute("aria-valuenow", percent);
      },
    };
  }

  /// A secondary on/off service, pressed or not.
  function chip(label, onChange) {
    const node = el("button", { type: "button", class: "chip", text: label, "aria-pressed": "false" });
    node.addEventListener("click", () => {
      const on = node.getAttribute("aria-pressed") !== "true";
      node.setAttribute("aria-pressed", String(on));
      onChange(on);
    });
    return { node, set: (on) => node.setAttribute("aria-pressed", String(on)) };
  }

  /// A security write (unlock, open, disarm): held for a moment, the fill running across; let go early and
  /// nothing happens. Space and Enter hold it from the keyboard. The fill's transition in style.css lasts as long.
  const HOLD_MS = 900;
  function hold(label, onConfirm) {
    const text = el("span", { text: label });
    const fillText = el("span", { class: "hold-fill", "aria-hidden": "true", text: label });
    const node = el("button", { type: "button", class: "hold" }, text, fillText);
    // A timer decides, the fill only shows it: a transition does not run in a hidden tab.
    let timer = null;
    const start = () => {
      if (timer) return;
      node.classList.add("holding");
      timer = setTimeout(() => { cancel(); onConfirm(); }, HOLD_MS);
    };
    const cancel = () => { clearTimeout(timer); timer = null; node.classList.remove("holding"); };
    node.addEventListener("pointerdown", (event) => { if (event.button === 0) { node.setPointerCapture(event.pointerId); start(); } });
    for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) node.addEventListener(type, cancel);
    node.addEventListener("keydown", (event) => { if ((event.key === " " || event.key === "Enter") && !event.repeat) { event.preventDefault(); start(); } });
    node.addEventListener("keyup", (event) => { if (event.key === " " || event.key === "Enter") cancel(); });
    node.addEventListener("click", (event) => event.preventDefault());
    const name = (next) => { text.textContent = next; fillText.textContent = next; node.setAttribute("aria-label", `${next} (press and hold)`); };
    name(label);
    return { node, label: name };
  }

  const pill = (text = "", tone = "") => el("span", { class: `pill ${tone}`.trim(), text });

  const glyphs = {
    minus: '<path d="M6 12h12"/>', plus: '<path d="M12 6v12M6 12h12"/>',
    blind: '<rect x="4" y="3" width="16" height="18" rx="1.5"/><path d="M4 8h16M4 12h16M12 12v5"/>',
    drop: '<path d="M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z"/>',
    gate: '<path d="M3 21V9l9-5 9 5v12M7 21v-8h10v8M7 17h10"/>',
    wind: '<path d="M3 8h11a3 3 0 1 0-3-3M3 12h16a3 3 0 1 1-3 3M3 16h8"/>',
    shield: '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6z"/>',
    tv: '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/>',
    up: '<path d="m6 15 6-6 6 6"/>', down: '<path d="m6 9 6 6 6-6"/>', stop: '<rect x="7" y="7" width="10" height="10" rx="2"/>',
    power: '<path d="M12 3v9"/><path d="M6.3 7.2a8 8 0 1 0 11.4 0"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>', mute: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="m16 9 5 6M21 9l-5 6"/>',
  };
  /// One of these glyphs, else one of common.js's icons.
  function icon(name) {
    if (!glyphs[name]) return HomeswiftCommon.icon(name);
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = glyphs[name];
    return svg;
  }

  // ---- Rows: a characteristic as a labelled control, for what no widget draws --------------------------

  const remoteKeys = [["←", 6, "Left"], ["↑", 4, "Up"], ["↓", 5, "Down"], ["→", 7, "Right"], ["Select", 8], ["Back", 9], ["Play/Pause", 11], ["Info", 15]];

  function controlFor(ctx, service, characteristic) {
    const writable = canWrite(characteristic), readable = canRead(characteristic);
    const labels = enumLabels[characteristic.type];
    const write = (value) => ctx.write(service, characteristic, value);
    if (writable && (characteristic.format === "bool" || numericSwitches.has(characteristic.type))) {
      const control = toggle(`${ctx.accessory.name}: ${sentence(characteristic.type)}`, (on) => write(onValue(characteristic, on)));
      ctx.watch(() => control.set(isOn(characteristic)));
      return control.node;
    }
    if (writable && characteristic.type === "Active Identifier") return inputPicker(ctx, service, characteristic);
    if (writable && !readable && characteristic.type === "Remote Key") {
      return el("div", { class: "keys" }, remoteKeys.map(([text, value, label]) => el("button", { text, "aria-label": label || text, onclick: () => ctx.send(service, characteristic, value).catch((e) => ctx.flash(e.message)) })));
    }
    if (writable && !readable && characteristic.type === "Volume Selector") {
      const send = (value) => ctx.send(service, characteristic, value).catch((e) => ctx.flash(e.message));
      return el("div", { class: "group" }, el("button", { text: "−", "aria-label": "Volume down", onclick: () => send(1) }), el("button", { text: "+", "aria-label": "Volume up", onclick: () => send(0) }));
    }
    if (writable && (characteristic.validValues || labels)) {
      const values = characteristic.validValues || labels.map((_, index) => index);
      const select = el("select", { "aria-label": sentence(characteristic.type) }, values.map((value) => el("option", { value, text: labelFor(characteristic.type, value) })));
      select.addEventListener("change", () => write(Number(select.value)));
      ctx.watch(() => { if (document.activeElement !== select) select.value = String(characteristic.value); });
      return select;
    }
    if (writable && ["int", "uint8", "uint16", "uint32", "uint64", "float"].includes(characteristic.format) && characteristic.minValue !== undefined && characteristic.maxValue !== undefined) {
      const input = el("input", { type: "range", min: characteristic.minValue, max: characteristic.maxValue, step: characteristic.minStep || 1, "aria-label": sentence(characteristic.type) });
      const value = el("span", { class: "value" });
      let timer = null;
      input.addEventListener("input", () => {
        value.textContent = `${input.value}${unit(characteristic)}`;
        clearTimeout(timer);
        timer = setTimeout(() => { timer = null; write(Number(input.value)); }, 250);
      });
      ctx.watch(() => { if (!timer) { input.value = characteristic.value ?? 0; value.textContent = formatValue(characteristic); } });
      return el("span", { class: "range" }, input, value);
    }
    if (writable && characteristic.format === "string") {
      const input = el("input", { type: "text", "aria-label": sentence(characteristic.type) });
      input.addEventListener("change", () => write(input.value));
      ctx.watch(() => { if (document.activeElement !== input) input.value = characteristic.value ?? ""; });
      return input;
    }
    if (!readable) return null;
    const text = el("span", { class: "value" });
    ctx.watch(() => { text.textContent = labels ? labelFor(characteristic.type, characteristic.value) : formatValue(characteristic); });
    return text;
  }

  /// The TV's input picker: the input services' identifiers under their names.
  function inputPicker(ctx, service, characteristic) {
    const inputs = ctx.accessory.services.filter((s) => s.type === "InputSource").map((s) => {
      const value = (type) => s.characteristics.find((c) => c.type === type)?.value;
      return { identifier: value("Identifier"), name: value("Configured Name") || s.name, hidden: value("Current Visibility State") === 1 };
    }).filter((input) => input.identifier !== undefined && !input.hidden);
    const select = el("select", { "aria-label": "Input" }, inputs.map((input) => el("option", { value: input.identifier, text: input.name })));
    select.addEventListener("change", () => ctx.write(service, characteristic, Number(select.value)));
    ctx.watch(() => { if (document.activeElement !== select) select.value = String(characteristic.value); });
    return select;
  }

  /// Rows for the characteristics of `service` no widget took, each marked as shown.
  function rows(ctx, service) {
    return service.characteristics.filter((c) => !ctx.used.has(c) && !plumbing.has(c.type) && !c.internal).map((characteristic) => {
      const control = controlFor(ctx, service, characteristic);
      ctx.use(characteristic);
      if (!control) return null;
      return el("div", { class: "control" }, el("span", { text: rowLabels[characteristic.type] || sentence(characteristic.type) }), control);
    }).filter(Boolean);
  }

  /// What no widget showed, a service at a time: one row under the service's name, or several under a heading.
  function leftovers(ctx, services = ctx.services) {
    return services.filter((service) => !quietServices.has(service.type))
      .map((service) => ({ service, rows: rows(ctx, service) })).filter((group) => group.rows.length)
      .map(({ service, rows: list }) => list.length === 1
        ? el("div", { class: "control" }, el("span", { text: shortName(ctx.accessory, service) }), list[0].lastChild)
        : el("div", { class: "controls" }, el("div", { class: "service-name", text: shortName(ctx.accessory, service) }), list));
  }

  // ---- Shared pieces of widgets -----------------------------------------------------------------------

  /// A speed: bars when it has a few positions, else a level.
  function speedControl(ctx, service, characteristic, color) {
    const min = characteristic.minValue ?? 0, max = characteristic.maxValue ?? 100, count = positions(characteristic);
    if (count <= 6 && count >= 2) {
      const stepSize = (max - min) / count;
      const control = steps({ label: "Speed", count }, (n) => ctx.write(service, characteristic, min + n * stepSize));
      if (color) control.node.style.setProperty("--steps", color);
      ctx.watch(() => control.set(Math.round((numberOf(characteristic) - min) / stepSize)));
      return el("div", { class: "w-row" }, el("span", { class: "w-label", text: "Speed" }), control.node);
    }
    const control = level({ label: "Speed", min, max, step: characteristic.minStep || 1, format: (v) => `${v}${unit(characteristic)}`, fill: color }, (v) => ctx.write(service, characteristic, v));
    ctx.watch(() => control.set(numberOf(characteristic)));
    return control.node;
  }

  /// A writable bool or 0/1 of a service as a chip (Swing, Child lock).
  function chipFor(ctx, service, characteristic, label) {
    if (!canWrite(characteristic)) return null;
    ctx.use(characteristic);
    const control = chip(label, (on) => ctx.write(service, characteristic, onValue(characteristic, on)));
    ctx.watch(() => control.set(isOn(characteristic)));
    return control.node;
  }

  const presets = [
    ["Warm white", 30, 55], ["Amber", 26, 85], ["Red", 2, 90], ["Pink", 330, 70], ["Violet", 275, 70], ["Blue", 220, 85], ["Cyan", 185, 75], ["Green", 125, 75],
  ];

  /// A light's controls, each a function that builds it (null when the light has none): `brightness` (a level,
  /// tall with `vertical`), `swatches` (colours, in a grid with `grid`), `white` (the temperature in kelvin);
  /// `color()`, the colour it shows now, for the tile.
  function lightParts(ctx, service) {
    const brightness = ctx.take(service, "Brightness"), hue = ctx.take(service, "Hue"), saturation = ctx.take(service, "Saturation");
    const temperature = ctx.take(service, "Color Temperature");
    // Adaptive Lighting (a controller on the bridge): on while a schedule runs, which its transition count says.
    const transitions = ctx.char(service, "Characteristic Value Active Transition Count");
    const adaptive = service.adaptiveLighting ? { resumable: !!service.adaptiveLighting.resumable } : null;
    const adaptiveOn = () => !!adaptive && numberOf(transitions) > 0;
    const setAdaptive = async (on) => {
      const before = transitions?.value;
      if (transitions) transitions.value = on ? 1 : 0;
      ctx.paint();
      try {
        await api(`/api/accessories/${encodeURIComponent(ctx.accessory.id)}/adaptive-lighting`, { method: "PUT", body: { service: serviceKey(service), on } });
        adaptive.resumable = true;
      } catch (e) {
        if (e.message === "signed out") return;
        if (transitions) transitions.value = before;
        ctx.flash(e.message);
      }
    };
    /// The Adaptive control: a swatch among the colours, a round button beside a white slider, or a chip.
    const adaptiveControl = (kind) => {
      const label = "Adaptive Lighting";
      const node = kind === "chip"
        ? el("button", { type: "button", class: "chip adaptive-chip", "aria-pressed": "false" }, icon("sun"), el("span", { text: "Adaptive" }))
        : el("button", { type: "button", class: kind === "swatch" ? "swatch adaptive" : "round adaptive", role: kind === "swatch" ? "radio" : null, "aria-label": label, title: label }, icon("sun"));
      node.addEventListener("click", () => setAdaptive(!adaptiveOn()));
      ctx.watch(() => {
        node.setAttribute(kind === "swatch" ? "aria-checked" : "aria-pressed", String(adaptiveOn()));
        node.classList.toggle("unset", !adaptive.resumable && !adaptiveOn());
        node.title = adaptiveOn() ? "Adaptive Lighting: on" : adaptive.resumable ? "Adaptive Lighting: resume the Home app's schedule" : "Adaptive Lighting: turn it on once in the Home app";
      });
      return node;
    };
    const color = () => {
      if (adaptiveOn() && temperature) return { k: kelvin(numberOf(temperature, 300)) };
      if (hue && saturation && numberOf(saturation) > 4) return { h: numberOf(hue), s: numberOf(saturation) };
      if (temperature) return { k: kelvin(numberOf(temperature, 300)) };
      return null;
    };
    const css = (c, lightness) => c.k ? whiteColor(c.k, lightness) : `hsl(${Math.round(c.h)} ${Math.round(c.s)}% ${lightness}%)`;
    return {
      brightness: canWrite(brightness) ? ({ vertical = false } = {}) => {
        const control = level({ label: "Brightness", min: brightness.minValue ?? 0, max: brightness.maxValue ?? 100, step: brightness.minStep || 1, format: (v) => `${v} %`, vertical },
          (v) => ctx.write(service, brightness, v));
        ctx.watch(() => {
          control.set(numberOf(brightness));
          const c = color();
          control.node.style.setProperty("--fill", c ? `linear-gradient(${vertical ? "0deg" : "90deg"}, ${css(c, 64)}, ${css(c, 86)})` : "");
        });
        return control.node;
      } : null,
      swatches: canWrite(hue) && canWrite(saturation) ? ({ grid = false } = {}) => {
        const swatches = presets.map(([name, h, s]) => {
          const swatch = el("button", { type: "button", class: "swatch", role: "radio", "aria-label": name, title: name, onclick: () => {
            ctx.write(service, hue, h);
            ctx.write(service, saturation, s);
          } });
          swatch.style.setProperty("--swatch", `hsl(${h} ${s}% 60%)`);
          return { swatch, h, s };
        });
        ctx.watch(() => {
          const h = numberOf(hue), s = numberOf(saturation);
          const near = (a, b) => Math.min(Math.abs(a - b), 360 - Math.abs(a - b)) <= 6;
          for (const one of swatches) one.swatch.setAttribute("aria-checked", String(!adaptiveOn() && s > 4 && near(one.h, h) && Math.abs(one.s - s) <= 12));
        });
        return el("div", { class: `swatches${grid ? " grid" : ""}`, role: "radiogroup", "aria-label": "Colour" }, adaptive ? adaptiveControl("swatch") : null, swatches.map((one) => one.swatch));
      } : null,
      white: canWrite(temperature) ? ({ vertical = false, thin = false } = {}) => {
        // Mireds run the other way: the track goes from warm (few kelvin, many mireds) to cool.
        const low = kelvin(temperature.maxValue ?? 500), high = kelvin(temperature.minValue ?? 140);
        const control = level({ label: "White", min: low, max: high, step: 50, format: (k) => `${k} K`, vertical, thin,
          gradient: `linear-gradient(${vertical ? "0deg" : "90deg"}, ${whiteColor(low, 72)}, ${whiteColor((low + high) / 2, 88)}, ${whiteColor(high, 84)})` },
        (k) => {
          const mireds = clamp(Math.round(1e6 / k), temperature.minValue ?? 0, temperature.maxValue ?? 1000);
          if (saturation && canWrite(saturation) && numberOf(saturation) > 0) ctx.write(service, saturation, 0);
          ctx.write(service, temperature, mireds);
        });
        ctx.watch(() => control.set(kelvin(numberOf(temperature, 300))));
        return control.node;
      } : null,
      // For a light without colours: the Adaptive control on its own ("round" beside the white, or a "chip").
      adaptive: adaptive ? (kind = "chip") => adaptiveControl(kind) : null,
      adaptiveOn,
      color: () => { const c = color(); return c && { tile: `linear-gradient(160deg, ${css(c, 74)}, ${css(c, 52)})`, glow: css(c, 55) }; },
    };
  }

  /// A light's whole body: its brightness, its colours, its white temperature, whichever it has.
  function lightBody(ctx, service) {
    const parts = lightParts(ctx, service);
    const chip = !parts.swatches && parts.adaptive ? el("div", { class: "chips" }, parts.adaptive("chip")) : null;
    return { nodes: [parts.brightness?.(), parts.swatches?.(), parts.white?.(), chip].filter(Boolean), color: parts.color };
  }

  /// A sensor service's reading: its value, its unit, a tone, and its glyph.
  const readings = {
    TemperatureSensor: ["Current Temperature", "thermo"], HumiditySensor: ["Current Relative Humidity", "sensor"], LightSensor: ["Current Ambient Light Level", "sensor"],
    AirQualitySensor: ["Air Quality", "wind"], MotionSensor: ["Motion Detected", "sensor"], OccupancySensor: ["Occupancy Detected", "sensor"],
    ContactSensor: ["Contact Sensor State", "door"], LeakSensor: ["Leak Detected", "drop"], SmokeSensor: ["Smoke Detected", "sensor"],
    CarbonMonoxideSensor: ["Carbon Monoxide Detected", "sensor"], CarbonDioxideSensor: ["Carbon Dioxide Level", "sensor"],
  };
  function reading(ctx, service) {
    const [type, glyph] = readings[service.type] ?? [];
    const main = type && ctx.char(service, type);
    if (!main) return null;
    ctx.use(main, ctx.char(service, "Status Active"));
    const extra = ["PM2.5 Density", "PM10 Density", "VOC Density", "Carbon Dioxide Detected"].map((t) => ctx.take(service, t)).filter(Boolean);
    const active = ctx.char(service, "Status Active");
    const value = () => {
      const v = main.value;
      const inactive = active && active.value === false;
      switch (service.type) {
        case "TemperatureSensor": return { text: typeof v === "number" ? v.toFixed(1) : "–", unit: "°C", tone: inactive ? "muted" : "" };
        case "HumiditySensor": return { text: typeof v === "number" ? String(Math.round(v)) : "–", unit: "%", tone: inactive ? "muted" : "" };
        case "LightSensor": return { text: typeof v === "number" ? String(Math.round(v)) : "–", unit: "lx" };
        case "CarbonDioxideSensor": return { text: typeof v === "number" ? String(Math.round(v)) : "–", unit: "ppm" };
        case "AirQualitySensor": return { text: labelFor(main.type, v), tone: v >= 4 ? "warn" : v >= 1 ? "ok" : "muted", scale: v >= 1 ? 6 - v : 0 };
        case "ContactSensor": return { text: v === 0 ? "Closed" : "Open", tone: v === 0 ? "" : "warn" };
        default: return { text: labelFor(main.type, v), tone: isOn(main) ? "warn" : "" };
      }
    };
    return { main, glyph, extra, value };
  }

  /// The services `widget` left: chips (switches and other on/off services), readouts (sensors), meters (a
  /// filter, a battery), blocks (a light, a fan, a thermostat, a lock). Each one's characteristics marked shown.
  function facets(ctx, handled = []) {
    const out = { chips: [], readouts: [], meters: [], blocks: [] };
    for (const service of ctx.services) {
      if (handled.includes(service) || quietServices.has(service.type) || service.characteristics.every((c) => ctx.used.has(c))) continue;
      const name = shortName(ctx.accessory, service);
      const on = ctx.char(service, "On");
      if ((service.type === "Switch" || service.type === "Outlet") && canWrite(on) && !on.security) {
        out.chips.push(chipFor(ctx, service, on, name));
      } else if (readings[service.type]) {
        const one = reading(ctx, service);
        if (!one) continue;
        const control = readout(name);
        ctx.watch(() => { const v = one.value(); control.set(v.text, v.unit, v.tone, v.scale); });
        out.readouts.push(control.node);
        for (const extra of one.extra) {
          const more = readout(extra.type.replace(" Density", "").replace("Carbon Dioxide Detected", "CO₂"));
          ctx.watch(() => more.set(extra.format === "bool" || enumLabels[extra.type] ? labelFor(extra.type, extra.value) : String(Math.round(numberOf(extra))), extra.type.endsWith("Density") ? "µg/m³" : ""));
          out.readouts.push(more.node);
        }
      } else if (service.type === "FilterMaintenance" || service.type === "Battery") {
        const life = ctx.take(service, service.type === "Battery" ? "Battery Level" : "Filter Life Level");
        const flag = ctx.take(service, service.type === "Battery" ? "Status Low Battery" : "Filter Change Indication");
        const label = service.type === "Battery" ? "Battery" : "Filter";
        if (life) {
          const control = meter(label === "Filter" ? "Filter life" : label);
          ctx.watch(() => control.set(Math.round(numberOf(life))));
          out.meters.push(control.node);
        } else if (flag) {
          const state = pill();
          ctx.watch(() => { state.textContent = labelFor(flag.type, flag.value); state.className = `pill ${isOn(flag) ? "warn" : "ok"}`; });
          out.blocks.push(el("div", { class: "w-row" }, el("span", { class: "w-label", text: label }), state));
        }
        if (service.type === "Battery") ctx.take(service, "Charging State");
      } else if (service.type === "Lightbulb" && canWrite(on)) {
        out.blocks.push(lightBlock(ctx, service, name));
      } else if ((service.type === "Fanv2" || service.type === "Fan") && (canWrite(ctx.char(service, "Active")) || canWrite(on))) {
        out.blocks.push(fanBlock(ctx, service, name));
      } else if ((service.type === "Thermostat" || service.type === "HeaterCooler") && ctx.char(service, "Current Temperature")) {
        out.blocks.push(climateBlock(ctx, service, name));
      } else if (service.type === "LockMechanism" && ctx.char(service, "Lock Current State")) {
        out.blocks.push(lockRow(ctx, service, name));
      }
    }
    return out;
  }
  const hasFacets = (f) => f.chips.length + f.readouts.length + f.meters.length + f.blocks.length > 0;
  function facetNodes(f) {
    return [
      f.readouts.length ? el("div", { class: "readouts" }, f.readouts) : null,
      ...f.meters, ...f.blocks,
      f.chips.length ? el("div", { class: "chips" }, f.chips) : null,
    ].filter(Boolean);
  }

  /// A secondary light (a TV's Ambilight, a camera's flashlight): its name and switch, then its body.
  function lightBlock(ctx, service, name) {
    const on = ctx.take(service, "On");
    const power = toggle(`${name}: on`, (v) => ctx.write(service, on, onValue(on, v)));
    ctx.watch(() => power.set(isOn(on)));
    const body = el("div", { class: "w-block-body" }, lightBody(ctx, service).nodes);
    ctx.watch(() => { body.hidden = !isOn(on); });
    return el("div", { class: "w-block" }, el("div", { class: "w-row" }, el("span", { class: "w-label", text: name }), power.node), body);
  }

  function fanBlock(ctx, service, name) {
    const power = ctx.take(service, "Active") || ctx.take(service, "On");
    const control = toggle(`${name}: on`, (v) => ctx.write(service, power, onValue(power, v)));
    ctx.watch(() => control.set(isOn(power)));
    const speed = ctx.take(service, "Rotation Speed");
    const target = ctx.take(service, "Target Fan State");
    ctx.take(service, "Current Fan State");
    // Its speed and modes show while it runs: a fan beside an air conditioner's own speed reads as one row when off.
    const body = el("div", { class: "w-block-body" },
      canWrite(speed) ? speedControl(ctx, service, speed) : null,
      canWrite(target) ? modeControl(ctx, service, target) : null,
      el("div", { class: "chips" }, chipFor(ctx, service, ctx.char(service, "Swing Mode"), "Swing"), chipFor(ctx, service, ctx.char(service, "Lock Physical Controls"), "Child lock")));
    ctx.watch(() => { body.hidden = !isOn(power); });
    return el("div", { class: "w-block" }, el("div", { class: "w-row" }, el("span", { class: "w-label", text: name }), control.node), body);
  }

  /// A writable enumeration of two to four values as a segmented control (more stay a menu, under More).
  function modeControl(ctx, service, characteristic, label = sentence(characteristic.type)) {
    const values = characteristic.validValues || (enumLabels[characteristic.type] || []).map((_, i) => i);
    if (values.length < 2 || values.length > 4) return null;
    ctx.use(characteristic);
    const control = segmented(values.map((value) => ({ value, label: labelFor(characteristic.type, value) })), label, (v) => ctx.write(service, characteristic, v));
    ctx.watch(() => control.set(characteristic.value));
    return control.node;
  }

  // ---- Climate: a heater-cooler or a thermostat ---------------------------------------------------------

  /// The parts of a climate service, read the same way for both kinds: its modes as "off", "auto", "heat"
  /// and "cool", the setpoint each mode uses, its state now.
  function climateParts(ctx, service) {
    const heaterCooler = service.type === "HeaterCooler";
    const part = (type) => ctx.take(service, type);
    const parts = {
      service, heaterCooler,
      active: heaterCooler ? part("Active") : null,
      target: part(heaterCooler ? "Target Heater-Cooler State" : "Target Heating Cooling State"),
      state: part(heaterCooler ? "Current Heater-Cooler State" : "Current Heating Cooling State"),
      current: part("Current Temperature"),
      heat: part("Heating Threshold Temperature"), cool: part("Cooling Threshold Temperature"),
      single: heaterCooler ? null : part("Target Temperature"),
      humidity: part("Current Relative Humidity"),
    };
    const modeNames = heaterCooler ? ["auto", "heat", "cool"] : ["off", "heat", "cool", "auto"];
    parts.mode = () => {
      if (parts.active && !isOn(parts.active)) return "off";
      return modeNames[numberOf(parts.target)] ?? "auto";
    };
    /// The setpoints a mode shows: both thresholds in auto, else the one it heats or cools to.
    parts.setpoints = (mode) => {
      if (mode === "auto") return parts.heat && parts.cool ? [parts.heat, parts.cool] : [parts.single].filter(Boolean);
      if (mode === "heat") return [parts.single || parts.heat].filter(Boolean);
      if (mode === "cool") return [parts.single || parts.cool].filter(Boolean);
      return [];
    };
    /// "heating", "cooling" or "idle", from the current state.
    parts.working = () => {
      const state = numberOf(parts.state);
      if (heaterCooler) return state === 2 ? "heating" : state === 3 ? "cooling" : "idle";
      return state === 1 ? "heating" : state === 2 ? "cooling" : "idle";
    };
    /// The mode as it shows when off: the one it would come back in.
    parts.lastMode = () => modeNames[numberOf(parts.target)] ?? "auto";
    return parts;
  }

  /// A setpoint control per temperature a service has; `show(list)` shows those a mode uses.
  function setpointControls(ctx, parts) {
    const labels = new Map([[parts.heat, "Heat to"], [parts.cool, "Cool to"], [parts.single, "Set to"]]);
    const controls = [...labels.keys()].filter((c) => canWrite(c)).map((characteristic) => {
      const control = setpoint({ label: labels.get(characteristic), min: characteristic.minValue ?? 10, max: characteristic.maxValue ?? 35, step: characteristic.minStep || 0.5 },
        (v) => ctx.write(parts.service, characteristic, v));
      ctx.watch(() => control.set(numberOf(characteristic)));
      return { characteristic, control };
    });
    return {
      nodes: controls.map(({ control }) => control.node),
      show(list) {
        for (const { characteristic, control } of controls) control.node.hidden = !list.includes(characteristic);
        // One setpoint per mode with a single target: "Heat to" or "Cool to" rather than "Set to".
        const single = controls.find((one) => one.characteristic === parts.single);
        if (single) single.control.node.querySelector(".sp-value span").textContent = { heat: "Heat to", cool: "Cool to" }[parts.mode()] ?? "Set to";
      },
    };
  }

  /// The modes a climate service offers, as a segmented control (Auto, Heat, Cool; Off for a thermostat).
  function climateModes(ctx, parts) {
    if (!canWrite(parts.target)) return null;
    const values = parts.target.validValues || enumLabels[parts.target.type].map((_, i) => i);
    const order = parts.heaterCooler ? [0, 1, 2] : [0, 3, 1, 2];
    const options = order.filter((v) => values.includes(v)).map((value) => ({ value, label: labelFor(parts.target.type, value) }));
    if (options.length < 2) return null;
    const control = segmented(options, "Mode", (v) => ctx.write(parts.service, parts.target, v));
    ctx.watch(() => control.set(parts.target.value));
    return control.node;
  }

  /// A thermostat inside another accessory's card (a purifier's heater): its modes and setpoint.
  function climateBlock(ctx, service, name) {
    const parts = climateParts(ctx, service);
    const points = setpointControls(ctx, parts);
    const now = el("span", { class: "muted" });
    ctx.watch(() => {
      points.show(parts.setpoints(parts.mode() === "off" ? parts.lastMode() : parts.mode()));
      now.textContent = typeof parts.current?.value === "number" && parts.current.value > -40 ? `${degrees(+parts.current.value.toFixed(1))} now` : "";
    });
    const power = parts.active ? toggle(`${name}: on`, (v) => ctx.write(service, parts.active, v ? 1 : 0)) : null;
    if (power) ctx.watch(() => power.set(isOn(parts.active)));
    return el("div", { class: "w-block" },
      el("div", { class: "w-row" }, el("span", { class: "w-label" }, name, " ", now), power?.node ?? null),
      climateModes(ctx, parts), el("div", { class: "setpoints row-setpoints" }, points.nodes));
  }

  // ---- Locks and doors ---------------------------------------------------------------------------------

  /// A lock: its state, a hold to unlock, a tap to lock.
  function lockRow(ctx, service, name) {
    const current = ctx.take(service, "Lock Current State"), target = ctx.take(service, "Lock Target State");
    const state = pill();
    const unlock = canWrite(target) ? hold("Hold to unlock", () => ctx.write(service, target, 0, { held: true })) : null;
    const lock = canWrite(target) ? el("button", { type: "button", class: "w-button", text: "Lock", onclick: () => ctx.write(service, target, 1, { held: true }) }) : null;
    ctx.watch(() => {
      const value = numberOf(current, numberOf(target, 3));
      state.textContent = labelFor(current.type, value);
      state.className = `pill ${value === 1 ? "ok" : value === 2 ? "bad" : "warn"}`;
      if (unlock) unlock.node.hidden = numberOf(target) === 0;
      if (lock) lock.hidden = numberOf(target) !== 0;
    });
    return el("div", { class: "lock-row" }, el("div", { class: "lock-name" }, el("strong", { text: name }), state), unlock?.node ?? null, lock);
  }

  // ---- The widgets ------------------------------------------------------------------------------------
  // Each: its `name` (the kind a default size is kept for), the service types it draws, its default `size`
  // (or a function of the accessory), and build(ctx, primary, size). The size is "small", "medium" or "large",
  // the fixed boxes of the wall, or "full", every control, in the sheet. build answers
  //   body        the nodes under the header (medium, large, full); side, in full, the nodes beside them
  //   facets      in full, the other services, as facets() makes them
  //   power       { service, characteristic, big }: the switch in the header
  //   status()    [text, tone]: the line under the name
  //   on()        whether the tile is lit; color() a light's colour for it; tone the tile's colour
  //   hero()      a small tile's figure (its temperature, its brightness)
  //   tap()       a small tile's action, tapLabel() what it does; without, a tap opens the full view
  //   hold        { armed(), confirm(), tap(), verb() }: a small tile held to confirm (opening a gate)
  //   shade()     a shutter's closed share, drawn on its small tile

  const widgets = [];
  const register = (widget) => widgets.push(widget);
  const sizes = ["small", "medium", "large"];

  // Which service an accessory is drawn by, when none says it is primary: the first of these.
  const rank = ["Television", "HeaterCooler", "Thermostat", "AirPurifier", "SecuritySystem", "GarageDoorOpener", "LockMechanism", "WindowCovering",
    "Door", "Window", "Valve", "Fanv2", "Fan", "Lightbulb", "Outlet", "Switch", ...Object.keys(readings)];
  function primaryOf(ctx) {
    const candidates = ctx.services.filter((service) => !quietServices.has(service.type));
    const flagged = candidates.find((service) => service.primary);
    if (flagged) return flagged;
    const order = (service) => { const index = rank.indexOf(service.type); return index < 0 ? rank.length : index; };
    return [...candidates].sort((a, b) => order(a) - order(b))[0];
  }

  /// Chips for the bools of a service a widget offers as options (Swing, Child lock).
  const optionChips = (ctx, service) => [chipFor(ctx, service, ctx.char(service, "Swing Mode"), "Swing"), chipFor(ctx, service, ctx.char(service, "Lock Physical Controls"), "Child lock")].filter(Boolean);
  const chipRow = (nodes) => nodes.length ? el("div", { class: "chips" }, nodes) : null;
  const row = (label, ...nodes) => el("div", { class: "w-row" }, label ? el("span", { class: "w-label", text: label }) : null, ...nodes);

  /// A switch of a group as a tile of its own: its name and state; a tap toggles it.
  function miniToggle(ctx, service, characteristic, name) {
    ctx.use(characteristic);
    const state = el("span");
    const node = el("button", { type: "button", class: "mini-toggle", onclick: () => ctx.write(service, characteristic, onValue(characteristic, !isOn(characteristic))) }, el("b", { text: name }), state);
    ctx.watch(() => { node.setAttribute("aria-pressed", String(isOn(characteristic))); state.textContent = isOn(characteristic) ? "On" : "Off"; });
    return node;
  }

  /// The readings of an accessory's sensors as one line ("21.4 °C · 48 % · air good").
  function readingLine(ctx, handled = []) {
    const list = ctx.services.filter((s) => readings[s.type] && !handled.includes(s)).map((s) => reading(ctx, s)).filter(Boolean);
    const filter = ctx.char(ctx.find("FilterMaintenance"), "Filter Life Level");
    const node = el("div", { class: "w-line" });
    ctx.watch(() => {
      const parts = list.map((one) => { const v = one.value(); return `${v.text}${v.unit ? ` ${v.unit}` : ""}`; });
      if (filter) parts.push(`filter ${Math.round(numberOf(filter))} %`);
      node.textContent = parts.join(" · ");
    });
    return list.length || filter ? node : null;
  }

  register({
    name: "switch-group", types: ["Switch", "Outlet"], icon: "switch", tone: "green", size: "medium",
    // An accessory of switches only (a chime's speakers, a remote's buttons): chips, or a tile each.
    match: (ctx) => {
      const shown = ctx.services.filter((s) => !quietServices.has(s.type));
      return shown.length >= 2 && shown.every((s) => (s.type === "Switch" || s.type === "Outlet") && canWrite(ctx.char(s, "On")) && !ctx.char(s, "On").security);
    },
    build(ctx, primary, size) {
      const switches = ctx.services.filter((s) => !quietServices.has(s.type));
      const ons = switches.map((s) => ctx.char(s, "On"));
      const count = () => ons.filter(isOn).length;
      const body = size === "large" || size === "full"
        ? [el("div", { class: "toggles" }, switches.map((s, i) => miniToggle(ctx, s, ons[i], shortName(ctx.accessory, s))))]
        : [chipRow(switches.map((s, i) => chipFor(ctx, s, ons[i], shortName(ctx.accessory, s))))];
      return {
        body, hero: () => `${count()}/${ons.length}`,
        status: () => [count() ? `${count()} of ${ons.length} on` : "All off"],
        on: () => count() > 0,
      };
    },
  });

  register({
    name: "television", types: ["Television"], icon: "tv", tone: "blue", size: "large",
    build(ctx, primary, size) {
      const active = ctx.take(primary, "Active");
      const remoteKey = ctx.take(primary, "Remote Key");
      const input = ctx.take(primary, "Active Identifier");
      const speaker = ctx.find("TelevisionSpeaker");
      const volume = ctx.char(speaker, "Volume Selector"), mute = ctx.char(speaker, "Mute");
      if (speaker) ctx.useAll(speaker);
      const remote = () => {
        if (!canWrite(remoteKey) || !window.HomeswiftRemote) return null;
        const homeKitKeys = { up: 4, down: 5, left: 6, right: 7, select: 8, back: 9, playPause: 11, info: 15 };
        const actions = [...Object.keys(homeKitKeys), ...(canWrite(volume) ? ["volumeUp", "volumeDown"] : []), ...(canWrite(mute) ? ["mute"] : [])];
        return el("div", { class: "card-remote" }, HomeswiftRemote.build({
          actions, label: `Remote for ${ctx.accessory.name}`,
          send: (action) => {
            if (action in homeKitKeys) return ctx.send(primary, remoteKey, homeKitKeys[action]);
            if (action === "volumeUp" || action === "volumeDown") return ctx.send(speaker, volume, action === "volumeUp" ? 0 : 1);
            return ctx.write(speaker, mute, !isOn(mute));
          },
        }));
      };
      const picker = () => canWrite(input) ? inputPicker(ctx, primary, input) : null;
      const inputName = () => {
        const chosen = ctx.accessory.services.find((s) => s.type === "InputSource" && ctx.char(s, "Identifier")?.value === input?.value);
        return chosen ? ctx.char(chosen, "Configured Name")?.value || chosen.name : null;
      };
      const volumeKeys = () => canWrite(volume) ? ["minus", "plus"].map((glyph, i) => el("button", { type: "button", class: "round", "aria-label": i ? "Volume up" : "Volume down",
        onclick: () => ctx.send(speaker, volume, i ? 0 : 1).catch((e) => ctx.flash(e.message)) }, icon(glyph))) : [];
      const parts = {
        power: canWrite(active) ? { service: primary, characteristic: active } : null,
        status: () => isOn(active) ? [inputName() ? `On · ${inputName()}` : "On"] : ["Off"],
        on: () => isOn(active),
        tap: canWrite(active) ? () => ctx.write(primary, active, isOn(active) ? 0 : 1) : null,
      };
      if (size === "medium") parts.body = [el("div", { class: "w-row" }, picker(), el("div", { class: "w-keys" }, volumeKeys(), canWrite(mute) ? chipFor(ctx, speaker, mute, "Mute") : null))];
      if (size === "large") parts.body = [remote(), input ? row("Input", picker()) : null].filter(Boolean);
      if (size === "full") Object.assign(parts, { body: [remote()].filter(Boolean), side: input ? [row("Input", picker())] : [], facets: facets(ctx, [primary, speaker]) });
      return parts;
    },
  });

  register({
    name: "climate", types: ["HeaterCooler", "Thermostat"], icon: "thermo", size: "large",
    build(ctx, primary, size) {
      const parts = climateParts(ctx, primary);
      const now = () => typeof parts.current?.value === "number" ? parts.current.value : null;
      const mode = () => parts.mode();
      const shownMode = () => mode() === "off" ? parts.lastMode() : mode();
      const built = {
        power: canWrite(parts.active) ? { service: primary, characteristic: parts.active } : null,
        tone: () => ({ heat: "heat", cool: "blue", auto: "green" })[shownMode()] ?? "teal",
        on: () => mode() !== "off",
        hero: () => now() === null ? "" : el("span", {}, degrees(+now().toFixed(1)), el("small", { text: mode() })),
        tap: canWrite(parts.active) ? () => ctx.write(primary, parts.active, isOn(parts.active) ? 0 : 1) : null,
        status() {
          const inside = now() === null ? "" : `${degrees(+now().toFixed(1))} inside`;
          if (mode() === "off") return [inside ? `Off · ${inside}` : "Off"];
          const shown = parts.setpoints(mode());
          const working = parts.working();
          if (shown.length === 2) {
            if (working === "heating") return [`Heating to ${degrees(numberOf(shown[0]))}`, "heat"];
            if (working === "cooling") return [`Cooling to ${degrees(numberOf(shown[1]))}`, "cool"];
            return [`Keeping ${degrees(numberOf(shown[0]))}–${degrees(numberOf(shown[1]))}`, "auto"];
          }
          const target = shown[0] ? degrees(numberOf(shown[0])) : "";
          if (working === "heating") return [`Heating to ${target}`, "heat"];
          if (working === "cooling") return [`Cooling to ${target}`, "cool"];
          return [`Idle · ${mode()} to ${target}`];
        },
      };
      if (size === "small") return built;
      const points = setpointControls(ctx, parts);
      if (size === "medium") {
        // The temperature inside and one setpoint: the mode's own (Cool to in auto).
        const big = el("b", { class: "w-big" });
        ctx.watch(() => {
          const shown = parts.setpoints(shownMode());
          points.show(shown.slice(-1));
          big.textContent = now() === null ? "–" : degrees(+now().toFixed(1));
        });
        built.body = [el("div", { class: "w-row" }, el("div", { class: "w-figure" }, big, el("span", { text: "Inside" })), el("div", { class: "setpoints" }, points.nodes))];
        return built;
      }
      const temps = [parts.heat, parts.cool, parts.single].filter(Boolean);
      const min = Math.min(...temps.map((c) => c.minValue ?? 10), 10), max = Math.max(...temps.map((c) => c.maxValue ?? 35), 30);
      const dial = gauge({ min, max });
      const colors = { heat: "var(--heat)", cool: "var(--cool)", auto: "var(--auto)" };
      ctx.watch(() => {
        const shown = parts.setpoints(shownMode());
        points.show(shown);
        const caption = typeof parts.humidity?.value === "number" ? `Inside · ${Math.round(parts.humidity.value)} %` : "Inside";
        if (mode() === "off" || !shown.length) dial.update({ value: now(), caption });
        else if (shown.length === 2) dial.update({ value: now(), from: numberOf(shown[0]), to: numberOf(shown[1]), color: colors.auto, caption });
        else dial.update({ value: now(), from: now() ?? numberOf(shown[0]), to: numberOf(shown[0]), color: colors[mode()], caption });
      });
      const speed = ctx.take(primary, "Rotation Speed");
      const chips = optionChips(ctx, primary);
      built.body = [
        el("div", { class: "climate-hero" }, dial.node, el("div", { class: "setpoints" }, points.nodes)),
        climateModes(ctx, parts),
        canWrite(speed) ? speedControl(ctx, primary, speed) : null,
        chipRow(chips),
      ].filter(Boolean);
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "air-purifier", types: ["AirPurifier"], icon: "wind", tone: "teal", size: "large",
    build(ctx, primary, size) {
      const active = ctx.take(primary, "Active"), state = ctx.take(primary, "Current Air Purifier State");
      const target = ctx.char(primary, "Target Air Purifier State"), speed = ctx.take(primary, "Rotation Speed");
      const quality = ctx.char(ctx.find("AirQualitySensor"), "Air Quality");
      const built = {
        power: canWrite(active) ? { service: primary, characteristic: active } : null,
        on: () => isOn(active),
        tap: canWrite(active) ? () => ctx.write(primary, active, isOn(active) ? 0 : 1) : null,
        hero: () => quality ? el("span", { class: "w-hero-word" }, labelFor(quality.type, quality.value)) : speed && isOn(active) ? `${numberOf(speed)}%` : "",
        status() {
          if (!isOn(active)) return [quality ? `Off · air ${labelFor(quality.type, quality.value).toLowerCase()}` : "Off"];
          const how = target && numberOf(target) === 1 ? "auto" : speed ? `${numberOf(speed)} %` : "";
          return numberOf(state) === 2 ? [how ? `Purifying · ${how}` : "Purifying", "ok"] : ["Idle"];
        },
      };
      if (size === "small") return built;
      const speedNode = canWrite(speed) ? speedControl(ctx, primary, speed, "linear-gradient(90deg, #8fe3da, #1c9c91)") : null;
      if (size === "medium") { built.body = [speedNode ?? modeControl(ctx, primary, target, "Mode"), readingLine(ctx)].filter(Boolean); return built; }
      const mode = modeControl(ctx, primary, target, "Mode");
      const chips = optionChips(ctx, primary);
      if (size === "large") {
        const f = facets(ctx, [primary]);
        built.body = [mode, speedNode, f.readouts.length ? el("div", { class: "readouts four" }, f.readouts.slice(0, 4)) : null, f.meters[0] ?? null, chipRow([...chips, ...f.chips])].filter(Boolean);
        return built;
      }
      built.body = [mode, speedNode, chipRow(chips)].filter(Boolean);
      built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "fan", types: ["Fanv2", "Fan"], icon: "fan", tone: "teal", size: "medium",
    build(ctx, primary, size) {
      const power = ctx.take(primary, "Active") || ctx.take(primary, "On");
      const speed = ctx.take(primary, "Rotation Speed");
      ctx.take(primary, "Current Fan State");
      const built = {
        power: canWrite(power) ? { service: primary, characteristic: power } : null,
        on: () => isOn(power), hero: () => speed && isOn(power) ? `${numberOf(speed)}%` : "",
        tap: canWrite(power) ? () => ctx.write(primary, power, onValue(power, !isOn(power))) : null,
        status: () => isOn(power) ? [speed ? `On · ${numberOf(speed)} %` : "On"] : ["Off"],
      };
      const speedNode = canWrite(speed) ? speedControl(ctx, primary, speed) : null;
      if (size === "medium") built.body = [speedNode ?? chipRow(optionChips(ctx, primary))].filter(Boolean);
      if (size === "large" || size === "full") {
        built.body = [speedNode, modeControl(ctx, primary, ctx.char(primary, "Target Fan State"), "Mode"),
          modeControl(ctx, primary, ctx.char(primary, "Rotation Direction"), "Direction"), chipRow(optionChips(ctx, primary))].filter(Boolean);
      }
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "light", types: ["Lightbulb"], icon: "bulb", tone: "light",
    size: (ctx, primary) => canWrite(ctx.char(primary, "Brightness")) || canWrite(ctx.char(primary, "Hue")) || canWrite(ctx.char(primary, "Color Temperature")) ? "medium" : "small",
    match: (ctx, primary) => canWrite(ctx.char(primary, "On")),
    build(ctx, primary, size) {
      const on = ctx.take(primary, "On");
      const brightness = ctx.char(primary, "Brightness");
      const light = lightParts(ctx, primary);
      const built = {
        power: { service: primary, characteristic: on },
        tap: () => ctx.write(primary, on, onValue(on, !isOn(on))),
        on: () => isOn(on), color: light.color,
        hero: () => brightness && isOn(on) ? `${numberOf(brightness)}%` : "",
        status: () => isOn(on) ? [[brightness ? `On · ${numberOf(brightness)} %` : "On", light.adaptiveOn() ? "Adaptive" : ""].filter(Boolean).join(" · ")] : ["Off"],
      };
      // A white-only light's Adaptive control sits beside its white slider.
      const whiteRow = (options) => light.white ? (light.adaptive ? el("div", { class: "w-row" }, el("div", { class: "w-grow" }, light.white(options)), light.adaptive("round")) : light.white(options)) : null;
      if (size === "medium") built.body = [light.brightness?.(), light.swatches?.() ?? whiteRow({ thin: true })].filter(Boolean);
      if (size === "large") {
        // A tall brightness beside the colours, or beside a tall white (and the Adaptive chip under it).
        const tall = light.brightness?.({ vertical: true });
        const side = light.swatches ? [light.swatches({ grid: true }), light.white?.({ thin: true })] : [light.white?.({ vertical: true }), light.adaptive?.("chip")];
        built.body = [el("div", { class: "light-large" }, tall, el("div", { class: light.swatches ? "light-colours" : "light-tall" }, side.filter(Boolean)))];
      }
      if (size === "full") Object.assign(built, { body: lightBody(ctx, primary).nodes, facets: facets(ctx, [primary]) });
      return built;
    },
  });

  register({
    name: "cover", types: ["WindowCovering", "Door", "Window"], icon: "blind", tone: "blue", size: "small",
    match: (ctx, primary) => canWrite(ctx.char(primary, "Target Position")),
    build(ctx, primary, size) {
      const current = ctx.take(primary, "Current Position"), target = ctx.take(primary, "Target Position");
      const state = ctx.take(primary, "Position State"), obstruction = ctx.take(primary, "Obstruction Detected");
      const hold = ctx.take(primary, "Hold Position");
      const min = target.minValue ?? 0, max = target.maxValue ?? 100, step = target.minStep || 1;
      const position = () => numberOf(current, numberOf(target));
      // Where this page sent the shutter: shown until it gets there, stops on the way, is sent elsewhere or two
      // minutes pass, as the Home app does, rather than each position it reports on its way.
      let goal = null;
      const go = async (value) => {
        goal = { value, since: Date.now(), moved: false };
        await ctx.write(primary, target, value);
        // Refused: the write put the target back.
        if (goal?.value === value && numberOf(target) !== value) { goal = null; ctx.paint(); }
      };
      const shown = () => {
        if (goal) {
          const moving = numberOf(state, 2) !== 2;
          if (moving) goal.moved = true;
          if (Math.abs(position() - goal.value) <= step || (goal.moved && !moving) || numberOf(target, goal.value) !== goal.value
            || Date.now() - goal.since > 120_000) goal = null;
        }
        return goal ? goal.value : position();
      };
      const built = {
        tap: () => go(shown() > min ? min : max),
        tapLabel: () => shown() > min ? "close" : "open",
        on: () => shown() > min, hero: () => `${shown()}%`, shade: () => 100 - (shown() - min) / (max - min) * 100,
        // The small tile slides: dragged down it closes, up it opens, written when let go.
        slide: { min, max, step, value: shown, commit: go },
        status() {
          if (isOn(obstruction)) return ["Obstructed", "warn"];
          const moving = numberOf(state, 2);
          const p = shown();
          if (moving === 1 || (moving === 2 && goal && goal.value > position())) return ["Opening…", "cool"];
          if (moving === 0 || (moving === 2 && goal && goal.value < position())) return ["Closing…", "cool"];
          return [p <= min ? "Closed" : p >= max ? "Open" : `Open · ${p} %`];
        },
      };
      if (size === "small") return built;
      // Stop: Hold Position where it has one, else the position it is at as the target.
      const buttons = [["up", "Open", () => go(max)],
        ["stop", "Stop", () => { goal = null; return canWrite(hold) ? ctx.write(primary, hold, true) : go(position()); }],
        ["down", "Close", () => go(min)]].map(([glyph, label, act]) => el("button", { type: "button", class: "round", "aria-label": label, title: label, onclick: act }, icon(glyph)));
      const slider = (vertical) => {
        const control = level({ label: "Position", min, max, step, format: (v) => `${v} %`, vertical,
          fill: `linear-gradient(${vertical ? "0deg" : "90deg"}, #4aa3ff, #a8dbff)` }, go);
        ctx.watch(() => control.set(numberOf(target, position())));
        return control.node;
      };
      const tilts = ["Target Horizontal Tilt Angle", "Target Vertical Tilt Angle"].map((type) => ctx.take(primary, type)).filter(canWrite).map((tilt) => {
        const one = level({ label: "Tilt", min: tilt.minValue ?? -90, max: tilt.maxValue ?? 90, step: tilt.minStep || 1, format: (v) => `${v}°`, thin: true }, (v) => ctx.write(primary, tilt, v));
        ctx.watch(() => one.set(numberOf(tilt)));
        return one.node;
      });
      for (const type of ["Current Horizontal Tilt Angle", "Current Vertical Tilt Angle"]) ctx.take(primary, type);
      if (size === "medium") built.body = [el("div", { class: "w-row" }, el("div", { class: "w-grow" }, slider(false)), ...buttons)];
      if (size === "large") built.body = [el("div", { class: "cover-large" }, slider(true), el("div", { class: "cover-buttons" }, buttons, tilts))];
      if (size === "full") Object.assign(built, { body: [slider(false), el("div", { class: "w-keys" }, buttons), ...tilts], facets: facets(ctx, [primary]) });
      return built;
    },
  });

  /// A small tile held to confirm, for what opens or unlocks; tapped, it does the safe thing.
  register({
    name: "garage-door", types: ["GarageDoorOpener"], icon: "gate", tone: "violet", size: "medium",
    build(ctx, primary, size) {
      const current = ctx.take(primary, "Current Door State"), target = ctx.take(primary, "Target Door State");
      const obstruction = ctx.take(primary, "Obstruction Detected");
      const doorState = () => numberOf(current, numberOf(target, 1));
      const asked = () => numberOf(target, 1);
      const locks = ctx.all("LockMechanism").filter((s) => ctx.char(s, "Lock Current State"));
      const unlocked = () => locks.filter((s) => numberOf(ctx.char(s, "Lock Current State"), 1) !== 1);
      const openIt = () => ctx.write(primary, target, 0, { held: true }), closeIt = () => ctx.write(primary, target, 1, { held: true });
      const built = {
        on: () => doorState() !== 1 || unlocked().length > 0,
        hero: () => icon(unlocked().length ? "lock" : "lock"),
        hold: canWrite(target) ? { armed: () => asked() === 1, confirm: openIt, tap: () => { if (asked() === 0) closeIt(); }, verb: () => asked() === 1 ? "hold to open" : "close" } : null,
        status() {
          const now = doorState();
          const door = asked() !== now && now <= 1 ? (asked() === 0 ? "Opening" : "Closing") : labelFor(current.type, now);
          if (isOn(obstruction)) return ["Obstructed", "warn"];
          if (door === "Opening" || door === "Closing") return [`${door}…`, "warn"];
          const names = unlocked().map((s) => shortName(ctx.accessory, s).toLowerCase());
          if (now === 1 && !names.length) return [locks.length ? "Closed and locked" : "Closed", "ok"];
          return [names.length ? `${door} · ${names.join(", ")} unlocked` : door, "warn"];
        },
      };
      if (size === "small") return built;
      const big = el("b", { class: "w-state" });
      const warning = pill("Obstructed", "bad");
      const open = canWrite(target) ? hold("Hold to open", openIt) : null;
      const close = canWrite(target) ? el("button", { type: "button", class: "w-button", text: "Close", onclick: closeIt }) : null;
      ctx.watch(() => {
        big.textContent = labelFor(current.type, doorState());
        warning.hidden = !isOn(obstruction);
        if (open) open.node.hidden = asked() === 0;
        if (close) close.hidden = asked() !== 0;
      });
      const actions = el("div", { class: "w-actions" }, open?.node ?? null, close);
      if (size === "medium") { built.body = [el("div", { class: "w-row" }, el("div", { class: "big-state" }, big, warning), actions)]; return built; }
      const lockRows = locks.map((s) => lockRow(ctx, s, shortName(ctx.accessory, s)));
      built.body = [el("div", { class: "big-state" }, big, warning), actions, ...lockRows];
      const f = facets(ctx, [primary, ...locks]);
      if (size === "large") built.body.push(...(f.readouts.length ? [el("div", { class: "readouts" }, f.readouts.slice(0, 2))] : []));
      else built.facets = f;
      return built;
    },
  });

  register({
    name: "lock", types: ["LockMechanism"], icon: "lock", tone: "violet", size: "medium",
    match: (ctx, primary) => !!ctx.char(primary, "Lock Current State"),
    build(ctx, primary, size) {
      const current = ctx.char(primary, "Lock Current State"), target = ctx.char(primary, "Lock Target State");
      const built = {
        on: () => numberOf(current, 1) !== 1,
        hold: canWrite(target) ? { armed: () => numberOf(target, 1) === 1, confirm: () => ctx.write(primary, target, 0, { held: true }),
          tap: () => { if (numberOf(target, 1) === 0) ctx.write(primary, target, 1, { held: true }); }, verb: () => numberOf(target, 1) === 1 ? "hold to unlock" : "lock" } : null,
        status: () => { const v = numberOf(current, 3); return [labelFor(current.type, v), v === 1 ? "ok" : "warn"]; },
      };
      ctx.use(current, target);
      if (size === "small") return built;
      const lockNode = lockRow(ctx, primary, "");
      lockNode.querySelector(".lock-name strong")?.remove();
      built.body = [lockNode];
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "security-system", types: ["SecuritySystem"], icon: "shield", tone: "violet", size: "medium",
    build(ctx, primary, size) {
      const current = ctx.take(primary, "Security System Current State"), target = ctx.take(primary, "Security System Target State");
      const values = target?.validValues || [0, 1, 2, 3];
      const disarm = () => ctx.write(primary, target, 3, { held: true });
      const built = {
        on: () => numberOf(current, 3) !== 3,
        hold: canWrite(target) && values.includes(3) ? { armed: () => numberOf(target, 3) !== 3, confirm: disarm, tap: () => ctx.openFull(), verb: () => numberOf(target, 3) !== 3 ? "hold to turn off" : "open" } : null,
        status: () => { const v = numberOf(current, 3); return [v === 4 ? "Alarm" : v === 3 ? "Off" : `Armed · ${labelFor(current.type, v)}`, v === 4 ? "bad" : v === 3 ? "" : "ok"]; },
      };
      if (size === "small") return built;
      const big = el("b", { class: "w-state" });
      const arm = canWrite(target) ? el("div", { class: "chips" }, values.filter((v) => v !== 3).map((value) =>
        el("button", { type: "button", class: "chip", text: labelFor(target.type, value), onclick: () => ctx.write(primary, target, value, { held: true }) }))) : null;
      const off = built.hold ? hold("Hold to turn off", disarm) : null;
      ctx.watch(() => {
        big.textContent = labelFor(current.type, numberOf(current, 3));
        if (arm) for (const [i, button] of [...arm.children].entries()) button.setAttribute("aria-pressed", String(values.filter((v) => v !== 3)[i] === numberOf(target)));
        if (off) off.node.hidden = numberOf(target, 3) === 3;
      });
      built.body = size === "medium" ? [el("div", { class: "w-row" }, big, arm), off?.node].filter(Boolean) : [el("div", { class: "big-state" }, big), arm, off?.node].filter(Boolean);
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "valve", types: ["Valve"], icon: "drop", tone: "blue", size: "medium",
    build(ctx, primary, size) {
      const active = ctx.take(primary, "Active"), inUse = ctx.take(primary, "In Use");
      const set = ctx.take(primary, "Set Duration"), remaining = ctx.take(primary, "Remaining Duration");
      ctx.take(primary, "Valve Type");
      // Remaining Duration is sent when the valve opens; the page counts down from there.
      let endsAt = null, lastRemaining;
      const running = () => isOn(inUse) || (isOn(active) && !inUse);
      const left = () => endsAt ? Math.max(0, Math.round((endsAt - Date.now()) / 1000)) : numberOf(remaining);
      ctx.watch(() => {
        if (remaining && remaining.value !== lastRemaining) { lastRemaining = remaining.value; endsAt = running() ? Date.now() + numberOf(remaining) * 1000 : null; }
        if (!running()) endsAt = null;
      });
      const toggleRun = () => ctx.write(primary, active, isOn(active) ? 0 : 1);
      const built = {
        on: () => running(), tap: toggleRun, tapLabel: () => isOn(active) ? "stop" : "run",
        hero: () => running() ? clock(left()) : "",
        status: () => running() ? [`Running · ${clock(left())} left`, "cool"] : isOn(active) ? ["Starting…"] : ["Off"],
      };
      // The figures move each second while it runs.
      const ticker = setInterval(() => {
        if (ctx.node && !ctx.node.isConnected && Date.now() - ctx.born > 2000) { clearInterval(ticker); return; }
        if (running()) ctx.paint();
      }, 1000);
      if (size === "small") return built;
      const px = size === "medium" ? 84 : 140, radius = px / 2 - 6, circumference = 2 * Math.PI * radius;
      const ring = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      ring.setAttribute("viewBox", `0 0 ${px} ${px}`);
      ring.setAttribute("aria-hidden", "true");
      ring.innerHTML = `<circle class="ring-track" cx="${px / 2}" cy="${px / 2}" r="${radius}"/><circle class="ring" cx="${px / 2}" cy="${px / 2}" r="${radius}" stroke-dasharray="${circumference.toFixed(1)}"/>`;
      const title = el("b"), detail = el("span");
      const button = el("button", { type: "button", class: "valve-button", onclick: toggleRun }, ring, el("span", { class: "valve-text" }, title, detail));
      button.style.width = button.style.height = `${px}px`;
      const total = () => numberOf(set, numberOf(remaining, 0)) || 1;
      ctx.watch(() => {
        const on = running();
        title.textContent = isOn(active) ? "Stop" : "Run";
        detail.textContent = on ? `${clock(left())} left` : `for ${clock(numberOf(set, 0))}`;
        ring.querySelector(".ring").style.strokeDashoffset = String(on ? circumference * (1 - clamp(left() / total(), 0, 1)) : circumference);
        button.setAttribute("aria-label", `${isOn(active) ? "Stop" : "Run"} ${ctx.accessory.name}`);
      });
      let durations = null;
      if (canWrite(set)) {
        const choices = [60, 120, 300, 600, 900, 1800].filter((s) => s >= (set.minValue ?? 0) && s <= (set.maxValue ?? 3600));
        if (!choices.includes(numberOf(set)) && numberOf(set) > 0) choices.push(numberOf(set));
        choices.sort((a, b) => a - b);
        const shown = choices.slice(0, 4).includes(numberOf(set)) ? choices.slice(0, 4) : [...choices.slice(0, 3), numberOf(set)];
        const control = segmented(shown.map((s) => ({ value: s, label: s % 60 ? clock(s) : `${s / 60} min` })), "Duration", (v) => ctx.write(primary, set, v));
        ctx.watch(() => control.set(numberOf(set)));
        durations = control.node;
      }
      built.body = size === "medium" ? [el("div", { class: "w-row" }, button, el("div", { class: "w-grow" }, durations))] : [el("div", { class: "valve" }, button, durations)];
      if (size === "full") built.facets = facets(ctx, [primary]);
      return built;
    },
  });

  register({
    name: "toggle", types: ["Switch", "Outlet"],
    match: (ctx, primary) => canWrite(ctx.char(primary, "On")),
    icon: (ctx, primary) => primary.type === "Outlet" ? "outlet" : "switch", tone: "green", size: "small",
    build(ctx, primary, size) {
      const on = ctx.take(primary, "On"), inUse = ctx.take(primary, "Outlet In Use");
      const status = () => isOn(on) ? [isOn(inUse) ? "On · in use" : "On"] : ["Off"];
      const turn = (value) => ctx.write(primary, on, onValue(on, value), { held: true });
      if (on.security) {
        // A plugin's security switch (one that unlocks a door): held to turn on, a tap to turn off.
        const built = { on: () => isOn(on), status, hold: { armed: () => !isOn(on), confirm: () => turn(true), tap: () => { if (isOn(on)) turn(false); }, verb: () => isOn(on) ? "turn off" : "hold to turn on" } };
        if (size === "small") return built;
        const turnOn = hold("Hold to turn on", () => turn(true));
        const turnOff = el("button", { type: "button", class: "w-button", text: "Turn off", onclick: () => turn(false) });
        ctx.watch(() => { turnOn.node.hidden = isOn(on); turnOff.hidden = !isOn(on); });
        built.body = [turnOn.node, turnOff];
        if (size === "full") built.facets = facets(ctx, [primary]);
        return built;
      }
      const built = {
        power: { service: primary, characteristic: on, big: size === "medium" },
        tap: () => ctx.write(primary, on, onValue(on, !isOn(on))),
        on: () => isOn(on), status,
      };
      if (size === "large") {
        const button = el("button", { type: "button", class: "power-button", "aria-label": `${ctx.accessory.name}: power`, onclick: built.tap }, icon("power"));
        ctx.watch(() => button.setAttribute("aria-pressed", String(isOn(on))));
        built.power = null;
        const f = facets(ctx, [primary]);
        built.body = [button, f.readouts.length ? el("div", { class: "readouts" }, f.readouts.slice(0, 3)) : null, f.meters[0] ?? null, ...f.blocks.slice(0, 2), chipRow(f.chips)].filter(Boolean);
      }
      if (size === "medium") built.body = [];
      if (size === "full") Object.assign(built, { body: [], facets: facets(ctx, [primary]) });
      return built;
    },
  });

  register({
    name: "sensor", types: Object.keys(readings), icon: (ctx, primary) => readings[primary.type][1], tone: "teal", size: "small",
    build(ctx, primary, size) {
      const one = reading(ctx, primary);
      const value = () => one?.value() ?? { text: "–" };
      const built = {
        on: () => false,
        hero: () => { const v = value(); return el("span", { class: v.text.length > 6 ? "w-hero-word" : "" }, v.text, v.unit ? el("small", { text: v.unit }) : null); },
        status: () => {
          const others = ctx.services.filter((s) => s !== primary && readings[s.type]).map((s) => reading(ctx, s)?.value()).filter(Boolean);
          const v = value();
          return others.length ? [others.map((o) => `${o.text}${o.unit ? ` ${o.unit}` : ""}`).join(" · ")] : [labelFor(one?.main.type ?? "", one?.main.value ?? ""), v.tone === "warn" ? "warn" : ""];
        },
      };
      if (size === "small") return built;
      const f = facets(ctx, []);
      built.body = [el("div", { class: `readouts${size === "medium" ? " three" : ""}` }, size === "medium" ? f.readouts.slice(0, 3) : f.readouts.slice(0, 6)), size !== "medium" ? f.meters[0] : null].filter(Boolean);
      if (size === "full") built.facets = { chips: f.chips, readouts: [], meters: f.meters.slice(1), blocks: f.blocks };
      return built;
    },
  });

  // ---- Frames -----------------------------------------------------------------------------------------

  const categoryIcons = {
    lightbulb: ["bulb", "yellow"], television: ["tv", "blue"], tvSetTopBox: ["tv", "blue"], tvStreamingStick: ["tv", "blue"],
    appleTV: ["tv", "blue"], switch: ["switch", "green"], programmableSwitch: ["switch", "green"], outlet: ["outlet", "green"],
    sensor: ["sensor", "teal"], fan: ["fan", "teal"], airPurifier: ["wind", "teal"], speaker: ["speaker", "blue"], homePod: ["speaker", "blue"],
    audioReceiver: ["speaker", "blue"], doorLock: ["lock", "violet"], thermostat: ["thermo", "yellow"], heater: ["thermo", "yellow"], airConditioner: ["thermo", "teal"],
    garageDoorOpener: ["gate", "violet"], door: ["door", "violet"], window: ["door", "violet"], windowCovering: ["blind", "violet"],
    ipCamera: ["camera", "grey"], videoDoorbell: ["camera", "grey"], faucet: ["drop", "blue"], sprinkler: ["drop", "blue"], securitySystem: ["shield", "violet"],
  };

  /// What no widget claims: the power in the header and the primary service's rows; in full, the rest under More.
  const inspector = {
    name: "inspector", size: "medium",
    build(ctx, primary, size) {
      const power = primary && primary.characteristics.find((c) => (c.type === "On" || c.type === "Active") && canWrite(c));
      if (power) ctx.use(power);
      const list = primary ? rows(ctx, primary) : [];
      const shown = size === "medium" ? list.slice(0, 2) : size === "large" ? list.slice(0, 6) : list;
      return {
        body: shown.length ? [el("div", { class: "controls" }, shown)] : [],
        power: power ? { service: primary, characteristic: power } : null,
        tap: power ? () => ctx.write(primary, power, onValue(power, !isOn(power))) : null,
        on: () => power ? isOn(power) : false,
        status: () => [describeModel(ctx.accessory)],
      };
    },
  };

  function resolve(ctx) {
    const primary = primaryOf(ctx);
    const widget = primary && widgets.find((w) => w.types.includes(primary.type) && (!w.match || w.match(ctx, primary))) || inspector;
    return { widget, primary };
  }
  const defaultOf = (widget, ctx, primary) => typeof widget.size === "function" ? widget.size(ctx, primary) : widget.size;

  /// The kind of widget an accessory gets, and its default size there: what the page keeps defaults by.
  function kindOf(accessory) {
    if (accessory.camera && window.HomeswiftCamera) return { kind: "camera", size: "medium" };
    const ctx = context(accessory);
    const { widget, primary } = resolve(ctx);
    return { kind: widget.name, size: defaultOf(widget, ctx, primary) };
  }

  /// The ⋯ menu: All controls (the full view), then what the page offers for the accessory, else Identify.
  function actionsButton(ctx, full) {
    const items = () => [
      full ? null : { label: "All controls", icon: "edit", onSelect: () => open(ctx.accessory, ctx.options) },
      full ? null : { separator: true },
      ...(ctx.options.actions ? ctx.options.actions(ctx.accessory)
        : [{ label: "Identify", icon: "identify", onSelect: () => api(`/api/accessories/${encodeURIComponent(ctx.accessory.id)}/identify`, { method: "POST" }).catch((e) => alert(e.message)) }]),
    ];
    return menuButton(`Actions for ${ctx.accessory.name}`, items);
  }
  const searchText = (accessory) => `${accessory.name} ${accessory.platformName || ""} ${accessory.model || ""}`.toLowerCase();

  /// The widget for `accessory` at `size` ("small", "medium", "large"; the kind's default when left out), a box
  /// of the wall's grid: 1×1, 2×1, 2×2.
  function card(accessory, options = {}) {
    const ctx = context(accessory, options);
    ctx.openFull = () => open(accessory, options);
    let node;
    if (accessory.camera && window.HomeswiftCamera) node = cameraTile(ctx, sizes.includes(options.size) ? options.size : "medium");
    else {
      const { widget, primary } = resolve(ctx);
      const size = sizes.includes(options.size) ? options.size : defaultOf(widget, ctx, primary);
      node = frame(ctx, ...built(ctx, widget, primary, size), primary, size);
    }
    ctx.node = node;
    cards.add(ctx);
    return node;
  }

  /// A widget's parts at `size`; a widget that cannot draw this accessory leaves it to the rows rather than off the page.
  function built(ctx, widget, primary, size) {
    try { return [widget, widget.build(ctx, primary, size)]; } catch (e) {
      console.error(`Widget ${widget.name} failed for ${ctx.accessory.name}`, e);
      ctx.used.clear(); ctx.painters.length = 0;
      return [inspector, inspector.build(ctx, primary, size)];
    }
  }

  /// Every control of `accessory`, in a sheet over the page: its widget's, its facets, the rest under More.
  function open(accessory, options = {}) {
    const ctx = context(accessory, options);
    let node;
    if (accessory.camera && window.HomeswiftCamera) node = cameraCard(ctx);
    else {
      const { widget, primary } = resolve(ctx);
      node = fullFrame(ctx, ...built(ctx, widget, primary, "full"), primary);
    }
    ctx.node = node;
    cards.add(ctx);
    const done = el("button", { type: "button", class: "link", text: "Done" });
    const dialog = el("dialog", { class: "widget-sheet", "aria-label": accessory.name }, el("div", { class: "sheet-bar" }, done), node);
    done.addEventListener("click", () => dialog.close());
    dialog.addEventListener("click", (event) => { if (event.target === dialog) dialog.close(); });
    dialog.addEventListener("close", () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
    return dialog;
  }

  /// The tile's glyph, and a painter for its colour and state.
  function glyphFor(ctx, widget, built, primary) {
    const [fallbackIcon, fallbackTone] = categoryIcons[ctx.accessory.category] || ["generic", "grey"];
    const pick = (value, fallback) => typeof value === "function" ? value(ctx, primary) : value ?? fallback;
    const glyph = el("span", { class: "tile", "aria-hidden": "true" }, icon(pick(widget.icon, fallbackIcon)));
    return [glyph, () => {
      const on = built.on ? built.on() : true;
      const color = on && built.color ? built.color() : null;
      glyph.className = `tile tone-${color ? "light" : pick(built.tone, pick(widget.tone, fallbackTone))}${on ? "" : " is-off"}`;
      glyph.style.setProperty("--light", color?.tile ?? "");
      glyph.style.setProperty("--glow", color?.glow ?? "");
    }];
  }
  function statusPainter(ctx, built, status) {
    return () => {
      const paused = ctx.accessory.paused ? [`Paused · ${ctx.accessory.platformName ?? "its plugin"}`, "warn"] : null;
      const [text, tone] = ctx.flashing ? [ctx.flashing, "bad"] : paused ?? (built.status ? built.status() : [""]);
      status.textContent = text;
      if (tone) status.dataset.tone = tone; else delete status.dataset.tone;
    };
  }
  function powerToggle(ctx, built) {
    if (!built.power) return null;
    const { service, characteristic, big } = built.power;
    const control = toggle(`${ctx.accessory.name}: power`, (on) => ctx.write(service, characteristic, onValue(characteristic, on)));
    if (big) control.node.classList.add("big");
    ctx.watch(() => control.set(isOn(characteristic)));
    return control.node;
  }

  /// A fixed box of the wall: a small tile (a tap acts, or a hold confirms), or a medium or large card with its
  /// header and body; the ⋯ menu at the bottom right.
  function frame(ctx, widget, built, primary, size) {
    const { accessory } = ctx;
    const [glyph, paintGlyph] = glyphFor(ctx, widget, built, primary);
    const status = el("span", { class: "status" });
    const who = el("div", { class: "who" }, el("strong", { text: accessory.name }), status);
    const menu = actionsButton(ctx, false);
    const node = el("article", { class: `card widget size-${size} widget-${widget.name}`, "data-search": searchText(accessory), "data-id": accessory.id });
    if (size === "small") {
      const hero = el("span", { class: "w-hero" });
      const hit = el("button", { type: "button", class: "w-hit" });
      const shade = built.shade ? el("span", { class: "w-shade", "aria-hidden": "true" }) : null;
      if (built.hold) {
        // Held to confirm: the tile fills; let go early and nothing happens. Tapped, the safe action.
        let timer = null;
        const cancel = () => { clearTimeout(timer); timer = null; node.classList.remove("holding"); };
        hit.addEventListener("pointerdown", (event) => {
          if (event.button !== 0 || !built.hold.armed()) return;
          hit.setPointerCapture(event.pointerId);
          node.classList.add("holding");
          timer = setTimeout(() => { cancel(); built.hold.confirm(); }, HOLD_MS);
        });
        for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) hit.addEventListener(type, cancel);
        hit.addEventListener("keydown", (event) => {
          if ((event.key === " " || event.key === "Enter") && !event.repeat && built.hold.armed()) {
            event.preventDefault();
            node.classList.add("holding");
            timer = setTimeout(() => { cancel(); built.hold.confirm(); }, HOLD_MS);
          }
        });
        hit.addEventListener("keyup", (event) => { if (event.key === " " || event.key === "Enter") cancel(); });
        hit.addEventListener("click", () => { if (!built.hold.armed()) built.hold.tap(); });
        node.append(el("span", { class: "w-veil", "aria-hidden": "true" }));
      } else hit.addEventListener("click", () => {
        if (slid) { slid = false; return; }
        built.tap ? built.tap() : ctx.openFull();
      });
      hit.addEventListener("contextmenu", (event) => { event.preventDefault(); menu.click(); });
      // A shutter's tile slides: the shade follows the pointer, the position is written when it is let go. A
      // mouse drags at once; a finger holds still a moment first, so a swipe still scrolls the page.
      let sliding = null, slid = false;
      if (built.slide) {
        const { min, max, step } = built.slide;
        let start = null, armed = false, holdTimer = null;
        const at = (event) => {
          const box = node.getBoundingClientRect();
          const share = clamp((event.clientY - box.top) / box.height, 0, 1);
          return clamp(Math.round((min + (1 - share) * (max - min)) / step) * step, min, max);
        };
        hit.addEventListener("pointerdown", (event) => {
          if (event.button !== 0) return;
          start = { x: event.clientX, y: event.clientY, id: event.pointerId };
          armed = event.pointerType === "mouse";
          clearTimeout(holdTimer);
          if (!armed) holdTimer = setTimeout(() => { armed = true; node.classList.add("slide-ready"); }, 350);
        });
        hit.addEventListener("pointermove", (event) => {
          if (!start) return;
          const moved = Math.abs(event.clientY - start.y);
          if (!armed) { if (moved > 6) { clearTimeout(holdTimer); start = null; } return; }
          if (sliding === null && moved < 4) return;
          if (sliding === null) { hit.setPointerCapture(start.id); node.classList.add("sliding"); }
          sliding = at(event);
          ctx.paint();
        });
        const finish = () => {
          clearTimeout(holdTimer);
          node.classList.remove("slide-ready", "sliding");
          if (sliding !== null) { const value = sliding; sliding = null; slid = true; built.slide.commit(value); }
          start = null; armed = false;
        };
        hit.addEventListener("pointerup", finish);
        hit.addEventListener("pointercancel", () => { sliding = null; finish(); slid = false; ctx.paint(); });
        // Once a finger has held still, the page does not scroll under it.
        hit.addEventListener("touchmove", (event) => { if (armed) event.preventDefault(); }, { passive: false });
      }
      node.append(shade ?? "", hit, el("div", { class: "w-top" }, glyph, hero), el("div", { class: "w-bottom" }, who, menu));
      ctx.watch(() => {
        const on = built.on ? built.on() : false;
        node.classList.toggle("on", on);
        const value = sliding !== null ? `${sliding}%` : built.hero ? built.hero() : "";
        hero.replaceChildren(...(value ? [value] : []));
        if (shade) {
          const { min, max } = built.slide ?? { min: 0, max: 100 };
          shade.style.setProperty("--closed", `${sliding !== null ? 100 - (sliding - min) / (max - min) * 100 : built.shade()}%`);
        }
        const verb = built.hold ? built.hold.verb() : built.tap ? (built.tapLabel ? built.tapLabel() : on ? "turn off" : "turn on") : "show all controls";
        hit.setAttribute("aria-label", `${accessory.name}: ${verb}`);
        hit.setAttribute("aria-pressed", String(on));
      });
    } else {
      const body = (built.body || []).filter(Boolean);
      node.append(el("div", { class: "w-head" }, glyph, who, powerToggle(ctx, built)),
        body.length ? el("div", { class: "w-body" }, body) : null, el("span", { class: "w-corner" }, menu));
      node.classList.toggle("head-only", !body.length);
      ctx.watch(() => node.classList.toggle("powered-off", !!built.power && !built.power.big && !isOn(built.power.characteristic)));
    }
    ctx.watch(paintGlyph);
    ctx.watch(statusPainter(ctx, built, status));
    paused(node, ctx);
    return node;
  }

  /// A paused plugin's accessory: drawn quiet, its controls out of reach (inert: no pointer, no focus), its menu
  /// still there to resume the plugin or change the widget.
  function paused(node, ctx) {
    if (!ctx.accessory.paused) return;
    node.classList.add("paused");
    for (const part of node.querySelectorAll(":scope > .w-hit, :scope > .w-body, :scope > .w-head .switch, :scope > .w-main, :scope > .w-split, :scope > details, :scope > .camera-view, :scope > .controls")) part.inert = true;
  }

  /// Every control: the widget's body (beside its facets when there are any), what is left under More, the foot.
  function fullFrame(ctx, widget, built, primary) {
    const { accessory } = ctx;
    const [glyph, paintGlyph] = glyphFor(ctx, widget, built, primary);
    const facetList = built.facets ? facetNodes(built.facets) : [];
    const rest = leftovers(ctx);
    const status = el("span", { class: "status" });
    const body = (built.body || []).filter(Boolean), side = (built.side || []).filter(Boolean);
    const names = rest.map((group) => group.querySelector(".service-name, .control > span")?.textContent).filter(Boolean);
    const split = facetList.length + side.length > 0 && body.length > 0;
    const node = el("article", { class: `card accessory-card widget widget-full widget-${widget.name}`, "data-id": accessory.id },
      el("div", { class: "w-head" }, glyph, el("div", { class: "who" }, el("strong", { text: accessory.name }), status), powerToggle(ctx, built)),
      split ? el("div", { class: "w-split" }, el("div", { class: "w-main" }, body), el("div", { class: "w-side" }, side, facetList))
        : body.length + side.length + facetList.length ? el("div", { class: "w-main" }, body, side, facetList) : null,
      rest.length ? el("details", { class: "more", open: rest.length <= 2 },
        el("summary", { text: names.length > 3 ? `${names.slice(0, 2).join(", ")} and ${names.length - 2} more` : names.join(", ") }),
        el("div", { class: "controls" }, rest)) : null,
      el("div", { class: "card-foot" }, el("span", { class: "muted", text: [describeModel(accessory), accessory.bridge].filter(Boolean).join(" · ") }), actionsButton(ctx, true)));
    if (built.power && !built.power.big) ctx.watch(() => node.classList.toggle("powered-off", !isOn(built.power.characteristic)));
    ctx.watch(paintGlyph);
    ctx.watch(statusPainter(ctx, built, status));
    paused(node, ctx);
    return node;
  }

  // Under a camera's video: its light (a package camera's flashlight), switches and HomeKit camera setting;
  // sensors and the rest under "More".
  const cameraFirst = new Set(["Lightbulb", "Switch", "Outlet", "CameraOperatingMode"]);
  const cameraServiceNames = { CameraOperatingMode: "Camera", Microphone: "Microphone", Speaker: "Speaker" };

  function cameraView(ctx) {
    const { accessory } = ctx;
    const find = (type, characteristic) => accessory.services.find((s) => s.type === type)?.characteristics.find((c) => c.type === characteristic);
    return HomeswiftCamera.view({
      id: accessory.id, name: accessory.name, doorbell: !!accessory.doorbell, lastRing: accessory.lastRing,
      motion: find("MotionSensor", "Motion Detected")?.value === true, recording: find("CameraRecordingManagement", "Active")?.value === 1,
    });
  }

  /// A camera on the wall: its picture fills the box, its name and state over it; a small one opens the full
  /// card when tapped.
  function cameraTile(ctx, size) {
    const view = cameraView(ctx);
    const node = el("article", { class: `card widget size-${size} widget-camera camera-tile`, "data-search": searchText(ctx.accessory), "data-id": ctx.accessory.id },
      view.element, el("span", { class: "w-corner" }, actionsButton(ctx, false)));
    if (size === "small") node.append(el("button", { type: "button", class: "w-hit", "aria-label": `${ctx.accessory.name}: show all controls`, onclick: () => ctx.openFull() }));
    paused(node, ctx);
    return node;
  }

  /// A camera's card: its live video or snapshots on top (camera.js), with its name and state over it, then
  /// its controls. A doorbell's ring shows on the video rather than as a row.
  function cameraCard(ctx) {
    const { accessory } = ctx;
    const view = cameraView(ctx);
    for (const service of accessory.services) for (const c of service.characteristics) if (c.type === "Programmable Switch Event") ctx.use(c);
    // A camera's sensors carry its own name: they read as what they are.
    const named = (service) => {
      const own = !service.name || service.name === accessory.name;
      return own ? { ...service, name: cameraServiceNames[service.type] || service.type.replace(/([a-z])([A-Z])/g, "$1 $2") } : service;
    };
    const first = leftovers(ctx, ctx.services.filter((s) => cameraFirst.has(s.type)).map(named));
    const more = leftovers(ctx, ctx.services.filter((s) => !cameraFirst.has(s.type)).map(named));
    const names = more.map((group) => group.querySelector(".service-name, .control > span")?.textContent).filter(Boolean);
    const subtitle = describeModel(accessory);
    return el("div", { class: "card accessory-card camera-card widget widget-full widget-camera", "data-id": accessory.id },
      view.element,
      subtitle ? el("div", { class: "camera-meta muted", text: subtitle }) : null,
      first.length ? el("div", { class: "controls" }, first) : null,
      more.length ? el("details", { class: "more" },
        el("summary", { text: names.length > 3 ? `${names.slice(0, 2).join(", ")} and ${names.length - 2} more` : names.join(", ") }),
        el("div", { class: "controls" }, more)) : null,
      el("div", { class: "card-foot" }, el("span", { class: "muted", text: accessory.bridge }), actionsButton(ctx, true)));
  }

  window.HomeswiftWidgets = {
    card, open, kindOf, sizes, event, listen, describeModel, labelFor,
    /// A page's own widget, tried before the built-in ones: { name, types, match?, icon, tone, size, build }.
    register: (widget) => widgets.unshift(widget),
    /// The controls the widgets are made of, for a page's own widget.
    controls: { toggle, segmented, level, steps, setpoint, gauge, readout, meter, chip, hold, pill, icon },
  };
})();

"""#),
    ]
}
