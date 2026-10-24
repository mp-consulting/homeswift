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
    askCode(false);
    const form = $("#auth-form");
    if (setup && !setupGauge) {
      setupGauge = strengthGauge(form.password, () => form.username.value);
      form.password.closest("label").after(setupGauge);
      form.username.addEventListener("input", () => setupGauge.refresh());
    }
    setupGauge?.classList.toggle("hidden", !setup);
  }
  let setupGauge = null;

  /// The login's second step: with two-factor authentication on, the bridge asks for the authenticator app's code.
  function askCode(asked) {
    const form = $("#auth-form");
    $("#auth-otp").classList.toggle("hidden", !asked);
    form.otp.required = asked;
    if (!asked) form.otp.value = "";
    else form.otp.focus();
  }
  // Another username or password starts over: the code is only asked once those are right.
  for (const name of ["username", "password"]) $("#auth-form")[name].addEventListener("input", () => askCode(false));

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
    const body = { username: form.username.value, password: form.password.value };
    try {
      if (auth && auth.setupNeeded) {
        if (setupGauge && !(await setupGauge.acceptable())) throw new Error("The password is not strong enough yet: the gauge says what is missing.");
        body.setupCode = form.setupCode.value;
      }
      if (!$("#auth-otp").classList.contains("hidden")) body.otp = form.otp.value;
      await api(auth && auth.setupNeeded ? "/api/auth/setup" : "/api/auth/login", { method: "POST", body });
      form.password.value = "";
      askCode(false);
      await loadAuth();
    } catch (e) {
      if (e.status === 412) { askCode(true); return; }
      error.textContent = e.message;
      if (body.otp !== undefined) { form.otp.value = ""; form.otp.focus(); }
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
    showSections();
    HomeswiftChat.mount();
    $("#logout").classList.toggle("hidden", auth.mode !== "form");
    openEvents();
    // The user's theme, wallpaper and units; a page showing temperatures draws again when the unit changed.
    const shownUnit = HomeswiftCommon.preferences().temperatureUnit;
    HomeswiftCommon.loadPreferences().then((preferences) => {
      if (preferences.temperatureUnit !== shownUnit && ["/", "/status", "/accessories"].includes(location.pathname)) route();
    });
    route();
  }

  // ---- Roles -----------------------------------------------------------------
  // As Glass UI's: a user who is not an administrator sees Status and Accessories (and controls accessories); the
  // plugins, config.json, the log and the users are an administrator's. The server refuses the rest anyway.

  const adminSections = new Set(["plugins", "config", "logs", "settings", "users"]);
  const isAdmin = () => Boolean(auth && auth.admin);

  /// Shows the header's and the tab bar's sections the user may open.
  function showSections() {
    for (const link of document.querySelectorAll("nav a")) {
      const section = (link.getAttribute("href") || "").split("/")[1];
      const users = section === "users";
      link.classList.toggle("hidden", adminSections.has(section) && (!isAdmin() || (users && auth.mode !== "form")));
    }
    $("#user").textContent = auth.name && auth.name !== auth.username ? auth.name : auth.username || "";
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
    let [name = "status", ...args] = location.pathname.split("/").filter(Boolean).map(decode);
    if (adminSections.has(name) && !isAdmin()) {
      // An administrator's view, from a link or a bookmark: Status instead.
      history.replaceState(null, "", "/status");
      [name, args] = ["status", []];
    }
    for (const link of document.querySelectorAll("nav a")) {
      const current = link.getAttribute("href") === `/${name}`;
      link.classList.toggle("active", current);
      if (current) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
    }
    const view = name === "plugins" && args.length ? views.settings : name === "settings" ? HomeswiftAdmin.view : views[name] || views.status;
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
    $("#banner").classList.toggle("hidden", !status.restartNeeded || !isAdmin());
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

    // The page is widgets the user can hide and order (Customise, at the bottom; Glass UI's dashboard layout),
    // drawn only when shown: the activity charts load nothing while hidden.
    const widgets = {
      overview: () => [el("div", { class: "card hero" },
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
        el("div", { class: "stat" }, el("b", { text: formatDuration(status.uptimeSeconds) }), el("span", { text: "Up" })))],
      quick: () => window.HomeswiftHome?.quickSection(accessories),
      digest: () => status.assistant ? digestWidget() : null,
      activity: () => activity(accessories, withSlugs(status.bridges, "bridge")),
      bridges: () => [el("h2", { text: status.bridges.length === 1 ? "Bridge" : "Bridges and accessories" }),
      el("div", { class: "servers" }, ...bridges)],
      system: () => [el("h2", { text: "System" }),
      el("div", { class: "card server" },
        el("div", { class: "server-head" }, tile("system", "grey"),
          el("div", { class: "who" }, el("strong", { text: status.system.hostname }), el("div", { class: "muted", text: `${status.system.platform} ${status.system.os}` }))),
        el("div", { class: "facts" },
          fact("CPUs", status.system.cpus),
          fact("Assistant", status.assistant ? `${status.assistant.provider} · ${status.assistant.model}` : "Off"),
          fact("Machine up", formatDuration(status.system.systemUptimeSeconds ?? 0))),
        el("div", { class: "fact wide" }, el("span", { text: "Configuration" }), el("b", { class: "mono", text: status.configPath, title: status.configPath })),
        // Changes apply without one; this is for a plugin that misbehaves.
        isAdmin() ? el("div", { class: "actions" }, el("button", { class: "link", text: "Restart homeswift…", onclick: restartBridge }),
          el("a", { class: "link", href: "/settings", text: "Settings, pairings and backups" }), el("a", { class: "link", href: "/notifications", text: "Notifications" })) : null)],
    };
    const layout = dashboardLayout();
    show(main,
      layout.order.filter((id) => !layout.hidden.includes(id)).map((id) => {
        const nodes = [widgets[id]?.()].flat().filter(Boolean);
        return nodes.length ? el("section", { class: "widget", "data-widget": id }, nodes) : null;
      }),
      el("div", { class: "actions page-foot" },
        el("button", { class: "link", onclick: () => customiseDashboard(main, { assistant: Boolean(status.assistant), scroll: true }) }, HomeswiftCommon.icon("sliders"), " Customise this page…")));
    // Open while the user changes it: the page is drawn again under it after each change.
    if (customising) customiseDashboard(main, { assistant: Boolean(status.assistant) });
  };

  // ---- The Status page's widgets: which show, in which order ----------------------------------------------
  // Each user's own, kept on the server with their other preferences (/api/preferences, `dashboard`).

  const dashboardWidgets = [["overview", "Overview", "Health, accessories, plugins, uptime"], ["quick", "Quick controls", "Favourite accessories and scenes"], ["digest", "Daily digest", "The Assistant's summary of the day"],
    ["activity", "Activity", "Memory, CPU and response times"], ["bridges", "Bridges", "Pairing codes and what each bridge runs"], ["system", "System", "The machine, and Restart"]];

  /// The widgets in the user's order (new ones last), and those hidden.
  function dashboardLayout() {
    const saved = HomeswiftCommon.preferences().dashboard || {};
    const known = dashboardWidgets.map(([id]) => id);
    const order = [...(saved.order || []).filter((id) => known.includes(id)), ...known.filter((id) => !(saved.order || []).includes(id))];
    return { order, hidden: (saved.hidden || []).filter((id) => known.includes(id)) };
  }

  let customising = false;

  /// The Customise panel: a switch per widget and arrows to move it; each change is saved and the page redrawn.
  function customiseDashboard(main, { assistant, scroll = false }) {
    const existing = $(".customise", main);
    if (existing) { existing.remove(); customising = false; return; }
    customising = true;
    let layout = dashboardLayout();
    const list = el("div", { class: "customise-list" });
    const save = async (next) => {
      layout = next;
      draw();
      try {
        await HomeswiftCommon.applyPreferences(await api("/api/preferences", { method: "PUT", body: { dashboard: layout } }));
        route();
      } catch (e) { alert(e.message); }
    };
    const draw = () => list.replaceChildren(...layout.order.map((id, index) => {
      const [, name, note] = dashboardWidgets.find(([known]) => known === id);
      const shown = !layout.hidden.includes(id);
      const toggle = el("input", { type: "checkbox", checked: shown, "aria-label": `Show ${name}`, onchange: () =>
        save({ order: layout.order, hidden: shown ? [...layout.hidden, id] : layout.hidden.filter((one) => one !== id) }) });
      const move = (by) => () => { const order = [...layout.order]; order.splice(index + by, 0, order.splice(index, 1)[0]); save({ ...layout, order }); };
      return el("div", { class: "customise-row" },
        el("label", { class: "switch" }, toggle, el("span")),
        el("div", { class: "who" }, el("strong", { text: name }), el("div", { class: "muted", text: id === "digest" && !assistant ? "Needs the Assistant (a HomeswiftAiKit block)" : note })),
        el("button", { type: "button", class: "icon-button", "aria-label": `Move ${name} up`, disabled: index === 0, onclick: move(-1) }, HomeswiftCommon.icon("up")),
        el("button", { type: "button", class: "icon-button", "aria-label": `Move ${name} down`, disabled: index === layout.order.length - 1, onclick: move(1) }, HomeswiftCommon.icon("down")));
    }));
    draw();
    const panel = el("div", { class: "card customise", role: "region", "aria-label": "Customise the Status page" },
      el("div", { class: "section-head" }, el("h2", { text: "Customise this page" }), el("span", { class: "muted", text: "Saved for you, on every browser" })),
      list,
      el("div", { class: "actions" },
        el("button", { class: "link", text: "Back to the usual layout", onclick: () => save({ order: dashboardWidgets.map(([id]) => id), hidden: [] }) }),
        el("button", { class: "primary", text: "Done", onclick: () => { panel.remove(); customising = false; } })));
    main.prepend(panel);
    if (scroll) panel.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  }

  // ---- The daily digest (Glass UI's assistant digest widget) ------------------------------------------------
  // The Assistant's summary of the last day: the log's warnings and errors, the accessories, what needs attention
  // first. Written on demand and kept for the day by the bridge (ai-digest.json); Write again replaces it.

  function digestWidget() {
    const body = el("div", { class: "digest-body", "aria-live": "polite" });
    const note = el("span", { class: "muted" });
    const card = el("div", { class: "card digest-card" },
      el("div", { class: "server-head" },
        el("span", { class: "tile tone-ai", "aria-hidden": "true" }, sparkle()),
        el("div", { class: "who" }, el("strong", { text: "Daily digest" }), el("div", { class: "muted", text: "What needs attention today, from the log and the accessories" }))),
      body,
      // Writing one costs the provider's quota: an administrator's (any user reads today's).
      el("div", { class: "card-foot" }, note, isAdmin() ? menuButton("Digest actions", () => [{ label: "Write it again", icon: sparkle(), onSelect: () => write() }]) : null));
    let controller = null;

    const shown = (digest) => {
      body.replaceChildren(HomeswiftCommon.markdown(digest.text));
      note.textContent = `Written ${new Date(digest.generatedAt).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}${digest.model ? ` by ${digest.model}` : ""}`;
    };
    const offer = () => body.replaceChildren(...[
      el("p", { class: "muted", text: isAdmin() ? "No digest yet today. The Assistant reads the day's warnings and errors and the accessories, and says what needs attention."
        : "No digest yet today: an administrator has the Assistant write it." }),
      isAdmin() ? el("button", { class: "ai-button", onclick: () => write() }, sparkle(), el("span", { text: "Write today's digest" })) : null].filter(Boolean));

    async function write() {
      controller?.abort();
      controller = new AbortController();
      const own = controller;
      let text = "";
      const live = el("div", {}, el("p", { class: "ai-thinking", text: "Reading the day…" }));
      body.replaceChildren(live, el("button", { class: "link", text: "Stop", onclick: () => own.abort() }));
      card.classList.add("writing");
      note.textContent = "";
      try {
        shown(await HomeswiftCommon.assistantRequest("/api/assistant/digest", {}, { signal: own.signal, onChunk: (piece) => { text += piece; live.replaceChildren(HomeswiftCommon.markdown(text)); } }));
      } catch (e) {
        if (own.signal.aborted) offer(); else body.replaceChildren(el("p", { class: "error", text: e.message }), el("button", { class: "link", text: "Try again", onclick: () => write() }));
      } finally {
        card.classList.remove("writing");
        if (controller === own) controller = null;
      }
    }

    api("/api/assistant/digest").then((digest) => (digest && digest.text ? shown(digest) : offer())).catch((e) => body.replaceChildren(el("p", { class: "error", text: e.message })));
    return card;
  }

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
      isAdmin() ? { label: "Show its log", icon: "logs", href: `/logs/${accessory.slug ?? encodeURIComponent(accessory.id)}` } : null,
      window.HomeswiftChat?.available() ? { label: "Ask the Assistant", icon: sparkle(), onSelect: () => HomeswiftChat.ask(`About ${accessory.name}: `) } : null,
      accessory.platform && isAdmin() ? { label: "Plugin settings", icon: "gear", href: `/plugins/${slug(accessory.platformName || accessory.platform)}` } : null,
      // A paused plugin's accessories do nothing until it runs again.
      accessory.paused && isAdmin() ? { label: `Resume ${accessory.platformName}`, icon: "play", onSelect: async () => {
        try { await setPaused(accessory.platform, accessory.platformName, false); route(); } catch (e) { alert(e.message); }
      } } : null,
      ...(isAdmin() ? window.HomeswiftHome?.layoutActions(accessory) ?? [] : []),
      accessory.history ? { label: "History", icon: "chart", onSelect: () => HomeswiftAdmin.history(accessory) } : null,
    ];
  }

  // /accessories?group=room|plugin&hidden=1: sections per room (once there are rooms) or per plugin; hidden
  // accessories only with hidden=1.
  views.accessories = async (main) => {
    const [list, saved, home] = await Promise.all([api("/api/accessories"), api("/api/layout").catch(() => null), api("/api/rooms").catch(() => ({ rooms: [] }))]);
    const all = withSlugs(list, "accessory");
    // Hidden accessories (an accessory's ⋯ menu) only with ?hidden=1.
    const showHidden = new URLSearchParams(location.search).get("hidden") === "1";
    const accessories = showHidden ? all : all.filter((accessory) => !accessory.hidden);
    const hiddenCount = all.filter((accessory) => accessory.hidden).length;
    const rooms = home.rooms.map((room) => room.name);
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
    // What a widget may move beside when the wall is split: its plugin, or its room.
    const section = (accessory) => layout.grouping === "room" ? accessory.room ?? "" : plugin(accessory);
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
      if (accessory === target || (layout.grouping !== "none" && section(accessory) !== section(target))) return;
      ordered.splice(ordered.indexOf(accessory), 1);
      ordered.splice(ordered.indexOf(target) + (after ? 1 : 0), 0, accessory);
      save();
      render();
    }
    function step(accessory, delta) {
      const wall = ordered.filter((one) => layout.grouping === "none" || section(one) === section(accessory));
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
      // By plugin or by room: a section each (by plugin in the order of their names, those of no plugin last; by room
      // in the rooms' order, those in none last); else one wall.
      const sections = layout.grouping === "plugin" ? groupByPlugin(accessories)
        : layout.grouping === "room" && rooms.length ? HomeswiftHome.groupByRoom(accessories, rooms) : null;
      const groups = sections ? sections.map(([name, group]) => [name, ordered.filter((accessory) => group.includes(accessory))]) : [["", ordered]];
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
    const groupings = [["none", "One wall"], ...(rooms.length ? [["room", "By room"]] : []), ["plugin", "By plugin"]];
    const grouping = el("div", { class: "group", role: "group", "aria-label": "Group the accessories" }, groupings.map(([value, text]) =>
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

    const hiddenToggle = hiddenCount ? el("label", { class: "toggle compact" }, el("input", { type: "checkbox", checked: showHidden, onchange: (event) => {
      const next = new URLSearchParams(location.search);
      if (event.target.checked) next.set("hidden", "1"); else next.delete("hidden");
      navigate(`/accessories${next.size ? `?${next}` : ""}`, { replace: true });
    } }), el("span", { text: `Show hidden (${hiddenCount})` })) : null;
    const suggest = isAdmin() && window.HomeswiftChat?.available() && all.length
      ? el("button", { class: "ai-button", onclick: () => HomeswiftHome.suggestRooms(content, all) }, sparkle(), "Suggest rooms") : null;

    render();
    show(main,
      pageHead("Accessories", accessories.length ? `${accessories.length} on ${servers} ${servers === 1 ? "server" : "servers"}, as the Home app sees them. Changes here reach your devices.` : "",
        ...(accessories.length ? [search, grouping, edit] : []), hiddenToggle, suggest),
      note,
      accessories.length ? [content, none] : el("div", { class: "card empty" }, el("p", { class: "muted", text: all.length ? "Every accessory is hidden." : "No accessories yet. Plugins add them once they reach their devices." })));
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
      platform === "HomeswiftAiKit" && useSuggestion && !isNew ? assistantSettings({
        formValue: () => { try { return { ...getValue(), platform }; } catch { return { ...current, platform }; } },
        useValue: useSuggestion, save, dirty }) : null,
      useSuggestion && !block.system ? describeSetup({ platform, pluginName: plugin ? plugin.name : platform, current: () => { try { return getValue(); } catch { return current; } }, use: useSuggestion }) : null,
      body,
      el("div", { class: "settings-bar" }, message, revert, save),
      remove);
    update();
  };

  /// The Assistant's settings card (Glass UI's): Test connection, and what the Assistant used today and this month
  /// against its budgets, by model and by user, with the budgets to edit. Above the HomeswiftAiKit block's form it
  /// tests the form's settings, saved or not, and its budgets go into the form and are saved with it; on Settings ›
  /// Assistant (`block` given, no form) it tests the saved block and writes the budgets to it.
  function assistantSettings({ formValue, useValue, save, dirty, block }) {
    if (!formValue) {
      formValue = () => ({ ...block });
      dirty = () => false;
      save = null;
    }
    const result = el("p", { class: "muted test-result", role: "status" });
    const test = el("button", { text: "Test connection", onclick: async () => {
      test.disabled = true;
      result.className = "muted test-result";
      result.textContent = "Asking the provider…";
      try {
        const answer = await api("/api/assistant/test", { method: "POST", body: { block: formValue() } });
        result.className = `test-result ${answer.ok ? "ok" : "error"}`;
        result.textContent = answer.ok ? `It works: ${answer.provider} · ${answer.model} answered in ${answer.latencyMs} ms.` : answer.message || "It did not answer.";
        loadUsage();
      } catch (e) { result.className = "test-result error"; result.textContent = e.message; }
      test.disabled = false;
    } });

    const usage = el("div", { class: "usage" }, el("p", { class: "muted", text: "Loading…" }));
    const money = (usd) => usd == null ? "–" : usd > 0 && usd < 0.01 ? `$${usd.toFixed(4)}` : `$${usd.toFixed(2)}`;
    const tokens = (summary) => (summary.inputTokens + summary.outputTokens).toLocaleString();
    const meter = (label, used, limit, format) => {
      const share = Math.min(1, limit ? used / limit : 0);
      return el("div", { class: `budget-meter${share >= 1 ? " over" : share >= 0.8 ? " near" : ""}` },
        el("div", { class: "budget-label" }, el("span", { text: label }), el("b", { text: `${format(used)} of ${format(limit)}` })),
        el("div", { class: "gauge-track", role: "meter", "aria-label": label, "aria-valuemin": "0", "aria-valuemax": String(limit), "aria-valuenow": String(used) },
          el("div", { class: "gauge-fill", style: `width:${share * 100}%` })));
    };
    const table = (title, rows) => rows.length ? el("div", { class: "table-scroll" }, el("table", {},
      el("thead", {}, el("tr", {}, [title, "Requests", "Tokens", "Cost"].map((text) => el("th", { text })))),
      el("tbody", {}, rows.map(([name, summary]) => el("tr", {}, el("td", { text: name }), el("td", { text: summary.requests.toLocaleString() }),
        el("td", { text: tokens(summary) }), el("td", { text: money(summary.costUsd) })))))) : null;
    async function loadUsage() {
      let answer;
      try { answer = await api("/api/assistant/usage"); } catch (e) { usage.replaceChildren(el("p", { class: "error", text: e.message })); return; }
      const report = answer.usage;
      const budget = report.budget || {};
      const meters = [
        budget.dailyTokens ? meter("Tokens today", report.today.inputTokens + report.today.outputTokens, budget.dailyTokens, (n) => n.toLocaleString()) : null,
        budget.dailyUsd ? meter("Spent today", report.today.costUsd ?? 0, budget.dailyUsd, money) : null,
        budget.monthlyTokens ? meter("Tokens this month", report.thisMonth.inputTokens + report.thisMonth.outputTokens, budget.monthlyTokens, (n) => n.toLocaleString()) : null,
        budget.monthlyUsd ? meter("Spent this month", report.thisMonth.costUsd ?? 0, budget.monthlyUsd, money) : null,
      ].filter(Boolean);
      const byModel = Object.entries(report.monthByModel || {}).sort(([, a], [, b]) => b.requests - a.requests);
      const byUser = Object.entries(report.byUser?.thisMonth || {}).sort(([, a], [, b]) => b.requests - a.requests);
      usage.replaceChildren(...[
        el("div", { class: "stats" },
          el("div", { class: "stat" }, el("b", { text: report.today.requests.toLocaleString() }), el("span", { text: "Requests today" })),
          el("div", { class: "stat" }, el("b", { text: money(report.today.costUsd) }), el("span", { text: "Cost today" })),
          el("div", { class: "stat" }, el("b", { text: report.thisMonth.requests.toLocaleString() }), el("span", { text: "Requests this month" })),
          el("div", { class: "stat" }, el("b", { text: money(report.thisMonth.costUsd) }), el("span", { text: "Cost this month" }))),
        report.exceeded ? el("p", { class: "error", text: report.exceeded }) : null,
        meters.length ? el("div", { class: "budget-meters" }, meters) : el("p", { class: "muted", text: "No budget: requests are not limited." }),
        byModel.length || byUser.length ? el("details", { class: "more" }, el("summary", { text: "This month by model and by user" }),
          table("Model", byModel), table("User", byUser)) : null,
        el("p", { class: "muted", text: "Costs come from the token counts at today's prices; only Claude models are priced." })].filter(Boolean));
    }

    // The budget's four limits, written into the form and saved with it; empty is no limit.
    const limits = [["dailyTokens", "Tokens per day", 1], ["dailyUsd", "USD per day", 0.01], ["monthlyTokens", "Tokens per month", 1], ["monthlyUsd", "USD per month", 0.01]];
    const inputs = Object.fromEntries(limits.map(([key, , step]) => [key, el("input", { type: "number", min: 0, step, inputMode: "decimal", placeholder: "No limit" })]));
    const budgetMessage = el("span", { class: "muted" });
    const editor = el("details", { class: "more budget-editor" },
      el("summary", { text: "Edit the budgets" }),
      el("div", { class: "fields" }, limits.map(([key, label]) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), inputs[key]))),
      el("div", { class: "actions" }, budgetMessage, el("button", { class: "primary", text: "Save the budgets", onclick: () => {
        if (dirty() && !confirm("The form below has other unsaved changes: save them with the budgets?")) return;
        const budget = {};
        for (const [key] of limits) if (inputs[key].value !== "" && Number(inputs[key].value) > 0) budget[key] = Number(inputs[key].value);
        const value = formValue();
        if (Object.keys(budget).length) value.budget = budget; else delete value.budget;
        budgetMessage.className = "muted";
        budgetMessage.textContent = "Saving…";
        if (save) {
          useValue(value);
          save.click();
          setTimeout(() => { budgetMessage.textContent = ""; loadUsage(); }, 1200);
          return;
        }
        // The block itself, by platform and name: the Assistant comes back with the new budgets.
        api(`/api/config/block/${encodeURIComponent(value.platform)}/${encodeURIComponent(value.name || value.platform)}`, { method: "PUT", body: value })
          .then((result) => { block = value; budgetMessage.textContent = savedText(result); setTimeout(loadUsage, 600); })
          .catch((e) => { budgetMessage.className = "error"; budgetMessage.textContent = e.message; });
      } })));
    editor.addEventListener("toggle", () => {
      if (!editor.open) return;
      const budget = formValue().budget || {};
      for (const [key] of limits) inputs[key].value = budget[key] ?? "";
    });

    loadUsage();
    return el("div", { class: "card assistant-settings" },
      el("div", { class: "server-head" },
        el("span", { class: "tile tone-ai", "aria-hidden": "true" }, sparkle()),
        el("div", { class: "who" }, el("strong", { text: "The Assistant" }), el("div", { class: "muted", text: save ? "Check the settings below before saving them, and see what it costs." : "Whether its provider answers, and what it costs." })),
        test),
      result, usage, editor);
  }

  /// Settings › Assistant (admin.js draws the page around it): the card for the saved HomeswiftAiKit block, and a
  /// link to all its settings.
  async function assistantPage(main, subnav) {
    const plugins = await api("/api/plugins");
    const entry = plugins.blocks.find((one) => one.platform === "HomeswiftAiKit");
    const head = pageHead("Settings", "The Assistant: whether its provider answers, what it costs, and its budgets.");
    if (!entry) {
      show(main, head, subnav, el("div", { class: "card empty" },
        el("p", { class: "muted", text: "The Assistant is off: config.json has no HomeswiftAiKit block. Add one on the Config page, { \"platform\": \"HomeswiftAiKit\", \"provider\": \"anthropic\", \"apiKey\": \"…\" }, or choose apple on a Mac with Apple Intelligence." }),
        el("a", { class: "button primary", href: "/config", text: "Open Config" })));
      return;
    }
    const block = await api(`/api/config/block/${encodeURIComponent(entry.platform)}/${encodeURIComponent(entry.name)}`);
    show(main, head, subnav, assistantSettings({ block }),
      el("div", { class: "actions" }, el("a", { class: "link", href: settingsLink(entry), text: "All the Assistant's settings: provider, model, key, MCP server" })));
  }

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
        result.replaceChildren(...[
          reply.explanation ? el("div", { class: "markdown" }, HomeswiftCommon.markdown(reply.explanation)) : null,
          changed ? el("pre", { class: "diff" }, lines.map((line) => el("span", { class: `diff-${line.kind}`, text: `${line.kind === "add" ? "+ " : line.kind === "remove" ? "- " : "  "}${line.text}\n` })))
            : el("p", { class: "muted", text: "No change to the block." }),
          changed ? el("div", { class: "actions" },
            el("button", { class: "primary", text: "Use it", onclick: () => { use(after); result.replaceChildren(el("p", { class: "ok", text: "In the form: review it, then Save." })); } }),
            el("button", { text: "Discard", onclick: () => result.replaceChildren() })) : null,
          el("p", { class: "muted", text: `Written by ${reply.model}. Passwords and tokens never reach it; check addresses and names before saving.` })].filter(Boolean));
      } catch (e) {
        result.replaceChildren(el("p", { class: "error", text: e.message }));
      } finally { ask.disabled = false; }
    });
    card.append(el("summary", {}, sparkle(), el("strong", { text: " Describe your setup" }), el("span", { class: "muted", text: " · the Assistant writes the settings" })),
      el("div", { class: "describe-body" }, request, el("div", { class: "actions" }, ask), result));
    return card;
  }

  /// Two blocks as pretty JSON with sorted keys, line by line: same, add or remove (common.js's jsonDiff, which the
  /// Settings pages' config.json backups use too).
  function blockDiff(before, after) {
    return HomeswiftCommon.jsonDiff(before, after);
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
        // `x-schema-form.invert`: the switch shows the opposite of the value, for a key that turns something off
        // (scheduledBackupDisable) under a title that turns it on.
        const invert = property["x-schema-form"]?.invert === true;
        const value = current !== undefined ? current === true : property.default === true;
        const input = el("input", { type: "checkbox", checked: invert ? !value : value });
        const present = current !== undefined;
        return { element: el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")), el("span", {}, el("span", { class: "field-title", text: title }), help)), get: () => {
          const next = invert ? !input.checked : input.checked;
          return next || present ? next : undefined;
        } };
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
        el("div", { class: "card" }, el("p", { class: "muted", text: "Plugins › HomeswiftUI › Settings turns sign-in on." })), appearanceLink());
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
        el("p", { class: "muted", text: `Signed in on this browser. Logins last ${days} day${days === 1 ? "" : "s"} without activity; changing the password, or turning two-factor authentication on or off, signs the others out.` })),
      el("button", { text: "Sign out", onclick: () => $("#logout").click() }));
    show(main, pageHead("Account", `Your sign-in to this bridge's web UI${state.admin ? ", as an administrator" : ""}.`),
      el("div", { class: "account" }, profile, form, twoFactorCard(state),
        state.admin ? el("div", { class: "card" }, el("h2", { text: "Users and API tokens" }),
          el("p", { class: "muted", text: "Add people who may use this web UI, choose who administers it, and make tokens for scripts." }),
          el("a", { class: "button", href: "/users", text: "Open Users" })) : null),
      appearanceLink());
  };

  /// Two-factor authentication (TOTP, RFC 6238): on, it can be turned off with the password; off, setting it up
  /// shows a QR code and the secret for an authenticator app, and a first code from the app turns it on.
  function twoFactorCard(state) {
    const card = el("div", { class: "card account-form" });
    const message = el("p", { class: "status-line muted", role: "status" });
    const say = (text, kind = "error") => { message.className = `status-line ${kind}`; message.textContent = text; };
    const field = (label, input) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input);
    const reload = () => route();
    if (state.twoFactor) {
      const password = el("input", { type: "password", autocomplete: "current-password", required: true });
      const submit = el("button", { type: "submit", text: "Turn off" });
      card.append(el("h2", {}, "Two-factor authentication ", el("span", { class: "pill status on", text: "On" })),
        el("p", { class: "muted", text: "Signing in asks for the code your authenticator app shows, after the password." }),
        el("form", { onsubmit: async (event) => {
          event.preventDefault();
          submit.disabled = true;
          try { await api("/api/account/otp/disable", { method: "POST", body: { password: password.value } }); reload(); }
          catch (e) { say(e.message); password.focus(); submit.disabled = false; }
        } }, field("Password, to turn it off", password), el("div", { class: "actions" }, submit)), message);
      return card;
    }
    const start = el("button", { class: "primary", text: "Set up" });
    card.append(el("h2", {}, "Two-factor authentication ", el("span", { class: "pill status standby", text: "Off" })),
      el("p", { class: "muted", text: "Ask for a code from an authenticator app (Passwords on iPhone and Mac, Google Authenticator, 1Password…) after the password, so a password alone no longer signs in." }),
      el("div", { class: "actions" }, start), message);
    start.addEventListener("click", async () => {
      start.disabled = true;
      let setup;
      try { setup = await api("/api/account/otp/setup", { method: "POST", body: {} }); }
      catch (e) { say(e.message); start.disabled = false; return; }
      const code = el("input", { inputMode: "numeric", autocomplete: "one-time-code", required: true, maxLength: 9, placeholder: "123 456", spellcheck: false });
      const confirmButton = el("button", { class: "primary", type: "submit", text: "Turn on" });
      const secret = el("code", { class: "mono secret", text: setup.secret.replace(/(.{4})/g, "$1 ").trim() });
      start.closest(".actions").replaceWith(
        el("div", { class: "setup" },
          setup.qr ? el("img", { class: "qr", src: `data:image/svg+xml;charset=utf-8,${encodeURIComponent(setup.qr)}`, alt: "QR code for an authenticator app", width: 148, height: 148 }) : null,
          el("div", {},
            el("p", { text: "Scan this code with your authenticator app, or open the link on this device; or type the key by hand." }),
            el("p", {}, secret, " ", el("button", { type: "button", class: "link", text: "Copy", onclick: () => copyText(setup.secret) }),
              " · ", el("a", { href: setup.uri, text: "Open in the app" })))),
        el("form", { onsubmit: async (event) => {
          event.preventDefault();
          confirmButton.disabled = true;
          try { await api("/api/account/otp/activate", { method: "POST", body: { code: code.value } }); reload(); }
          catch (e) { say(e.message); code.select(); confirmButton.disabled = false; }
        } }, field("The code the app shows now", code), el("div", { class: "actions" }, confirmButton)));
      code.focus();
    });
    return card;
  }

  // ---- Users ---------------------------------------------------------------
  // Glass UI's Users page: the accounts of this web UI, each a card whose ⋯ menu edits it (name, role, a new
  // password) or removes it, and the API tokens for scripts. An administrator's; the last one stays one.

  views.users = async (main) => {
    if (auth.mode !== "form") {
      show(main, pageHead("Users", "This web UI has no sign-in: its HomeswiftUI block says auth none, so there are no users."));
      return;
    }
    const [users, tokens] = await Promise.all([api("/api/users"), api("/api/tokens")]);
    const admins = users.filter((user) => user.admin).length;
    const when = (iso) => iso ? new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "Never";
    const field = (label, input, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, help ? el("span", { class: "help", text: help }) : null);
    const checkbox = (label, checked, help) => {
      const input = el("input", { type: "checkbox", checked });
      return [el("label", { class: "check" }, input, el("span", { text: label })), help ? el("p", { class: "help", text: help }) : null, input];
    };
    const roleHelp = "An administrator changes settings, plugins and users; anyone else sees the bridge and controls accessories.";

    /// The form that adds a user, or changes one (`user`): name, role, and a password (a new one, for a user).
    function userForm(user, done) {
      const username = el("input", { autocomplete: "off", required: true, maxLength: 64, spellcheck: false, value: user?.username ?? "" });
      const name = el("input", { autocomplete: "off", maxLength: 64, value: user && user.name !== user.username ? user.name : "", placeholder: user?.username ?? "The username" });
      const password = el("input", { type: "password", autocomplete: "new-password", required: !user });
      const gauge = strengthGauge(password, () => username.value);
      const [roleLabel, roleNote, admin] = checkbox("Administrator", user ? user.admin : false, roleHelp);
      if (user?.admin && admins < 2) { admin.disabled = true; roleNote.textContent = "The last administrator stays one: make another user an administrator first."; }
      const message = el("p", { class: "status-line muted", role: "status" });
      const submit = el("button", { class: "primary", type: "submit", text: user ? "Save" : "Add user" });
      const form = el("form", { class: "card account-form", onsubmit: async (event) => {
        event.preventDefault();
        if (password.value && !(await gauge.acceptable())) { message.className = "status-line error"; message.textContent = "The password is not strong enough yet: the gauge says what is missing."; return; }
        submit.disabled = true;
        try {
          if (user) {
            const body = { name: name.value, admin: admin.checked };
            if (password.value) body.password = password.value;
            await api(`/api/users/${encodeURIComponent(user.username)}`, { method: "PUT", body });
          } else {
            await api("/api/users", { method: "POST", body: { username: username.value, name: name.value, password: password.value, admin: admin.checked } });
          }
          done(true);
        } catch (e) { message.className = "status-line error"; message.textContent = e.message; submit.disabled = false; }
      } },
        el("h2", { text: user ? `Edit ${user.name}` : "Add a user" }),
        user ? null : field("Username", username, "What they sign in with: no spaces or colons."),
        field("Name", name, "Shown in the web UI; the username when empty."),
        el("label", { class: "field" }, el("span", { class: "field-title", text: user ? "New password" : "Password" }), password,
          user ? el("span", { class: "help", text: "Leave empty to keep theirs. A new one signs them out everywhere." }) : null, gauge),
        roleLabel, roleNote,
        el("div", { class: "actions" }, submit, el("button", { type: "button", text: "Cancel", onclick: () => done(false) })), message);
      return form;
    }

    const list = el("div", { class: "grid" });
    const formSlot = el("div", {});
    const closeForm = (changed) => { formSlot.replaceChildren(); if (changed) route(); };
    const openForm = (user) => { formSlot.replaceChildren(userForm(user, closeForm)); formSlot.scrollIntoView({ block: "nearest", behavior: "smooth" }); $("input", formSlot)?.focus(); };

    for (const user of users) {
      const lastAdmin = user.admin && admins < 2;
      list.append(el("div", { class: "card" },
        el("div", { class: "server-head" },
          tile(user.admin ? "key" : "user", user.admin ? "orange" : "blue"),
          el("div", { class: "who" }, el("strong", { text: user.name }), el("div", { class: "muted mono", text: user.username })),
          user.you ? el("span", { class: "pill", text: "You" }) : null),
        el("div", { class: "facts" },
          fact("Role", user.admin ? "Administrator" : "User"),
          fact("Two-factor", user.twoFactor ? "On" : "Off"),
          fact("Added", new Date(user.created).toLocaleDateString())),
        el("div", { class: "card-foot" },
          el("span", { class: "muted", text: user.you ? "Your own password and two-factor: Account" : lastAdmin ? "The last administrator" : "" }),
          menuButton(`Actions for ${user.name}`, () => [
            { label: "Edit", icon: "edit", onSelect: () => openForm(user) },
            user.you ? { label: "Your account", icon: "user", href: "/account" } : null,
            lastAdmin ? null : { label: user.you ? "Remove your account" : "Remove", icon: "trash", danger: true, onSelect: async () => {
              if (!confirm(`Remove ${user.name} (${user.username})? They are signed out at once.${user.you ? " That is you: this browser is signed out too." : ""}`)) return;
              try { await api(`/api/users/${encodeURIComponent(user.username)}`, { method: "DELETE" }); if (user.you) await loadAuth(); else route(); } catch (e) { alert(e.message); }
            } },
          ]))));
    }

    show(main,
      pageHead("Users", "Who may use this web UI. Administrators change settings, plugins and users; other users see the bridge and control accessories.",
        el("button", { class: "primary", text: "Add user", onclick: () => openForm(null) })),
      formSlot, list,
      apiTokens(tokens, when));
  };

  /// The API tokens: for scripts, sent as `Authorization: Bearer hst_…` on /api/*. A read token reads; an admin
  /// token does what an administrator does. Shown once, when made; the bridge keeps only a hash.
  function apiTokens(tokens, when) {
    const name = el("input", { required: true, maxLength: 64, placeholder: "Backup script", autocomplete: "off" });
    const scope = el("select", {}, el("option", { value: "read", text: "Read: status, accessories, metrics" }), el("option", { value: "admin", text: "Admin: everything an administrator does" }));
    const expiry = el("select", {}, ...[["", "Never"], ["30", "In 30 days"], ["90", "In 90 days"], ["365", "In a year"]].map(([value, text]) => el("option", { value, text })));
    const message = el("p", { class: "status-line muted", role: "status" });
    const created = el("div", {});
    const submit = el("button", { class: "primary", type: "submit", text: "Create token" });
    const form = el("form", { class: "card account-form", onsubmit: async (event) => {
      event.preventDefault();
      submit.disabled = true;
      try {
        const token = await api("/api/tokens", { method: "POST", body: { name: name.value, scope: scope.value, expiresInDays: expiry.value ? Number(expiry.value) : null } });
        form.reset();
        message.textContent = "";
        created.replaceChildren(el("div", { class: "card token-once" },
          el("h2", { text: `Token “${token.name}”` }),
          el("p", { class: "muted", text: "Copy it now: it is shown once. Send it as Authorization: Bearer <token>." }),
          el("p", {}, el("code", { class: "mono secret", text: token.token }), " ", el("button", { type: "button", class: "link", text: "Copy", onclick: () => copyText(token.token) })),
          el("div", { class: "actions" }, el("button", { type: "button", text: "Done", onclick: () => route() }))));
      } catch (e) { message.className = "status-line error"; message.textContent = e.message; }
      submit.disabled = false;
    } },
      el("h2", { text: "Create an API token" }),
      el("div", { class: "fields" },
        el("label", { class: "field" }, el("span", { class: "field-title", text: "Name" }), name),
        el("label", { class: "field" }, el("span", { class: "field-title", text: "Scope" }), scope),
        el("label", { class: "field" }, el("span", { class: "field-title", text: "Expires" }), expiry)),
      el("div", { class: "actions" }, submit), message);
    const cards = tokens.map((token) => el("div", { class: "card" },
      el("div", { class: "server-head" },
        tile("key", token.scope === "admin" ? "orange" : "teal"),
        el("div", { class: "who" }, el("strong", { text: token.name }), el("div", { class: "muted", text: token.createdBy ? `Made by ${token.createdBy}` : "" })),
        el("span", { class: "pill", text: token.scope === "admin" ? "Admin" : "Read" })),
      el("div", { class: "facts" }, fact("Created", when(token.created)), fact("Last used", when(token.lastUsed)), fact("Expires", token.expires ? when(token.expires) : "Never")),
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: token.expires && new Date(token.expires) < new Date() ? "Expired" : "" }),
        menuButton(`Actions for the token ${token.name}`, () => [
          { label: "Revoke", icon: "trash", danger: true, onSelect: async () => {
            if (!confirm(`Revoke the token “${token.name}”? Scripts using it are refused at once.`)) return;
            try { await api(`/api/tokens/${encodeURIComponent(token.id)}`, { method: "DELETE" }); route(); } catch (e) { alert(e.message); }
          } },
        ]))));
    return el("section", {},
      el("h2", { text: "API tokens" }),
      el("p", { class: "muted", text: "For scripts and other programs: send a token as Authorization: Bearer <token> to /api/*. A read token reads the status, accessories and metrics; an admin token does what an administrator does, but cannot manage users or tokens." }),
      created, form,
      tokens.length ? el("div", { class: "grid" }, cards) : el("p", { class: "muted", text: "No token yet." }));
  }

  const appearanceLink = () => el("a", { class: "card link-card", href: "/appearance" }, HomeswiftCommon.icon("sliders"),
    el("div", { class: "who" }, el("strong", { text: "Appearance" }), el("div", { class: "muted", text: "Light or dark, the wallpaper, °C or °F" })));

  // ---- Appearance ------------------------------------------------------------
  // /appearance: the theme (as the system, light or dark), a wallpaper (one of the UI's, or an image of your own)
  // and the temperature unit, as Glass UI offers them. Each user's own, saved on the bridge (/api/preferences) and
  // applied at once, on every page, plugins' included.

  const wallpaperChoices = [["none", "None"], ["aurora", "Aurora"], ["sunset", "Sunset"], ["ocean", "Ocean"], ["forest", "Forest"], ["graphite", "Graphite"]];

  views.appearance = async (main) => {
    let preferences = await HomeswiftCommon.loadPreferences();
    const message = el("p", { class: "status-line muted", role: "status" });
    const choose = async (change) => {
      message.className = "status-line muted";
      message.textContent = "Saving…";
      try {
        preferences = HomeswiftCommon.applyPreferences(await api("/api/preferences", { method: "PUT", body: change }));
        message.textContent = "Saved for your account, on every browser.";
        draw();
      } catch (e) { message.className = "status-line error"; message.textContent = e.message; }
    };
    const segmented = (label, value, options, key) => el("div", { class: "group", role: "radiogroup", "aria-label": label },
      options.map(([option, text]) => el("button", { type: "button", role: "radio", text, class: option === value ? "on" : "", "aria-checked": String(option === value),
        onclick: () => { if (option !== value) choose({ [key]: option }); } })));

    const picker = el("input", { type: "file", accept: "image/jpeg,image/png,image/webp", class: "hidden" });
    picker.addEventListener("change", async () => {
      const file = picker.files[0];
      picker.value = "";
      if (!file) return;
      message.className = "status-line muted";
      message.textContent = "Preparing the image…";
      try {
        const data = await scaledImage(file);
        preferences = HomeswiftCommon.applyPreferences(await api("/api/preferences/wallpaper", { method: "PUT", body: { data } }));
        message.textContent = "Your image is the wallpaper now.";
        draw();
      } catch (e) { message.className = "status-line error"; message.textContent = e.message; }
    });
    const body = el("div", { class: "appearance" });
    function draw() {
      const own = preferences.wallpaper === "custom" || preferences.wallpaperVersion;
      body.replaceChildren(
        el("div", { class: "card" }, el("h2", { text: "Theme" }),
          el("p", { class: "muted", text: "Automatic follows the system's light or dark appearance." }),
          segmented("Theme", preferences.theme, [["auto", "Automatic"], ["light", "Light"], ["dark", "Dark"]], "theme")),
        el("div", { class: "card" }, el("h2", { text: "Wallpaper" }),
          el("p", { class: "muted", text: "Behind the glass of every page." }),
          el("div", { class: "wallpapers", role: "radiogroup", "aria-label": "Wallpaper" },
            [...wallpaperChoices, ...(own ? [["custom", "Your image"]] : [])].map(([value, text]) =>
              el("button", { type: "button", role: "radio", class: `wallpaper-choice${preferences.wallpaper === value ? " on" : ""}`, "aria-checked": String(preferences.wallpaper === value),
                onclick: () => { if (preferences.wallpaper !== value) choose({ wallpaper: value }); } },
                el("span", { class: "wallpaper-swatch", "data-swatch": value }), el("span", { text })))),
          el("div", { class: "actions" },
            el("button", { text: own ? "Choose another image…" : "Use an image of your own…", onclick: () => picker.click() }),
            own ? el("button", { class: "link danger", text: "Remove your image", onclick: async () => {
              try { preferences = HomeswiftCommon.applyPreferences(await api("/api/preferences/wallpaper", { method: "DELETE" })); draw(); } catch (e) { alert(e.message); }
            } }) : null),
          picker),
        el("div", { class: "card" }, el("h2", { text: "Temperatures" }),
          el("p", { class: "muted", text: "How accessories and plugin pages show them. HomeKit and the Home app keep their own setting." }),
          segmented("Temperature unit", preferences.temperatureUnit, [["c", "Celsius (°C)"], ["f", "Fahrenheit (°F)"]], "temperatureUnit")));
    }
    draw();
    show(main, pageHead("Appearance", "How the web UI looks for you, on every browser you sign in to."), body, message);
  };

  /// An image as base64 JPEG, at most 2560 pixels on its long side: a photo from a phone is several MB.
  async function scaledImage(file) {
    if (!/^image\/(jpeg|png|webp)$/.test(file.type)) throw new Error("Choose a JPEG, PNG or WebP image.");
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, 2560 / Math.max(bitmap.width, bitmap.height));
    const canvas = el("canvas", { width: Math.round(bitmap.width * scale), height: Math.round(bitmap.height * scale) });
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
    if (!blob) throw new Error("The image could not be read.");
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  }

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
    const shownLines = () => {
      const needle = filter.value.toLowerCase();
      return logState.lines.filter((line) => visible(line, needle));
    };
    const asText = (line) => {
      const level = line.level === "info" || line.level === "notice" ? "" : ` [${line.level.toUpperCase()}]`;
      return `${line.time} [${line.label}]${level} ${line.text}`;
    };
    const copy = el("button", { text: "Copy", title: "Copy the lines shown", onclick: async () => {
      const shown = shownLines();
      const text = shown.map(asText).join("\n");
      try {
        await copyText(text);
        copy.textContent = `Copied ${shown.length} line${shown.length === 1 ? "" : "s"}`;
      } catch (e) {
        copy.textContent = "Not copied";
        copy.title = e.message;
      }
      setTimeout(() => { copy.textContent = "Copy"; copy.title = "Copy the lines shown"; }, 1800);
    } });
    // Log Doctor: the Assistant reads the lines shown and groups the issues, with causes and fixes.
    // The Logs page is an administrator's; its Assistant and file actions too.
    const doctor = logDoctor(() => shownLines().slice(-3000).map(asText), () => {
      const about = sources.picker.selectedOptions[0];
      return [sources.picker.value && about ? `the lines about ${about.textContent}` : "", filter.value ? `lines matching "${filter.value}"` : ""].filter(Boolean).join(", ");
    });
    // Download: the range shown (everything kept for the latest lines); Empty: the log in memory and on disk.
    const actions = menuButton("Log actions", () => {
      const chosen = range.span();
      const query = new URLSearchParams();
      if (chosen) { query.set("from", chosen[0].toISOString()); if (chosen[1]) query.set("to", chosen[1].toISOString()); }
      return [
        { label: chosen ? "Download this range" : "Download the whole log", icon: "download", href: `/api/logs/download${query.size ? `?${query}` : ""}` },
        { label: "Empty the log…", icon: "trash", danger: true, onSelect: async () => {
          if (!confirm("Empty the log? Every line goes, in memory and the files kept on disk (up to a week). This cannot be undone.")) return;
          try { await api("/api/logs/truncate", { method: "POST", body: {} }); await load(); } catch (e) { alert(e.message); }
        } },
      ];
    });
    show(main,
      pageHead("Logs", "This homeswift's log, live, and up to a week back."),
      el("div", { class: "card log-card" },
        el("div", { class: "editor-bar" }, levels, range.picker, sources.picker, filter, el("span", { class: "spacer" }), count, doctor.button, copy,
          el("label", { class: "toggle compact" }, el("span", { class: "switch" }, follow, el("span")), el("span", { text: "Follow" })),
          saveToggle, actions,
          range.customRow),
        output),
      doctor.card);
    await load();
  };

  /// Log Doctor (Glass UI's): a Diagnose button and the card the diagnosis streams into. `lines()` gives the
  /// lines to read, `focus()` what they were picked by. Hidden while the Assistant is off.
  function logDoctor(lines, focus) {
    const button = el("button", { class: "ai-button hidden", title: "The Assistant reads the lines shown and groups the issues, with causes and fixes" }, sparkle(), el("span", { text: "Diagnose" }));
    const card = el("div", { class: "ai-card log-doctor hidden", role: "region", "aria-label": "Log Doctor", "aria-live": "polite" });
    api("/api/assistant").then((state) => { if (state?.enabled) button.classList.remove("hidden"); }).catch(() => {});
    let controller = null;
    button.addEventListener("click", async () => {
      const picked = lines();
      if (!picked.length) { alert("No line is shown: widen the range or the filters first."); return; }
      controller?.abort();
      const own = controller = new AbortController();
      let text = "";
      let closed = false;
      const live = el("div", { class: "ai-live" }, el("p", { class: "ai-thinking", text: `Reading ${picked.length.toLocaleString()} ${picked.length === 1 ? "line" : "lines"}…` }));
      const stop = el("button", { class: "link", text: "Stop", onclick: () => own.abort() });
      const close = el("button", { class: "ai-close", title: "Close", "aria-label": "Close the diagnosis", text: "×", onclick: () => { closed = true; own.abort(); card.classList.add("hidden"); } });
      const head = el("div", { class: "ai-head" }, sparkle(), el("span", { class: "ai-label", text: "Log Doctor" }), el("span", { class: "spacer" }), close);
      card.className = "ai-card log-doctor thinking";
      card.replaceChildren(el("div", { class: "ai-inner" }, head, live, stop));
      card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
      button.disabled = true;
      try {
        const reply = await HomeswiftCommon.assistantRequest("/api/assistant/diagnose", { lines: picked, focus: focus() || undefined }, {
          signal: own.signal, onChunk: (piece) => { text += piece; live.replaceChildren(HomeswiftCommon.markdown(text)); } });
        card.className = "ai-card log-doctor answered";
        live.replaceChildren(HomeswiftCommon.markdown(reply.text));
        stop.replaceWith(el("p", { class: "muted ai-note", text: `${reply.model} read ${reply.lines.toLocaleString()} ${reply.lines === 1 ? "line" : "lines"}. Secrets and addresses were masked first; check its advice before acting on it.` }));
      } catch (e) {
        card.className = `ai-card log-doctor failed${closed ? " hidden" : ""}`;
        stop.remove();
        live.replaceChildren(el("p", { class: own.signal.aborted ? "muted" : "error", text: own.signal.aborted ? "Stopped." : e.message }));
      } finally {
        button.disabled = false;
        if (controller === own) controller = null;
      }
    });
    return { button, card };
  }

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
    if (["/", "/status", "/accessories", "/quick"].includes(location.pathname)) route();
  });

  // The views of home.js: rooms, Quick Controls, scenes, notifications.
  // An accessory's widget at its kind's size, for the Quick Controls.
  const accessoryCard = (accessory) => HomeswiftWidgets.card(accessory, { size: HomeswiftWidgets.kindOf(accessory).size, actions: accessoryActions });
  window.HomeswiftHome?.install({
    views, api, show, pageHead, breadcrumb, accessoryCard, navigate, route: () => route(),
    enumLabels: HomeswiftWidgets.enumLabels, labelFor: HomeswiftWidgets.labelFor, withSlugs,
  });
  // The Settings pages (admin.js) draw with the same helpers.
  window.HomeswiftApp = { api, navigate, route, pageHead, breadcrumb, show, savedText, waitForRestart, formatDuration, setLeaveGuard: (guard) => { leaveGuard = guard; }, assistantPage };

  loadAuth().catch((e) => { $("#auth").classList.remove("hidden"); $("#auth-error").textContent = e.message; });
})();
