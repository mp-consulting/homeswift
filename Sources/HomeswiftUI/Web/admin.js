// The Settings pages, after the Homebridge UI's settings, child bridges, config editor backups, restart and power
// options: the bridge block and this machine's network, HomeKit pairings, cached accessories, child bridges,
// whole-instance and config.json backups, the schedules, and the audit log; and an accessory's recorded history.
// app.js routes /settings[/<page>] here and lends its helpers (HomeswiftApp) when a view is drawn.
(() => {
  "use strict";

  const { $, el, tile, fact, menuButton, withSlugs, jsonDiff } = HomeswiftCommon;
  const { t, tn, locale } = HomeswiftI18n;
  const app = () => window.HomeswiftApp;
  const api = (...args) => app().api(...args);

  const pages = [["", t("Overview"), "chart"], ["bridge", t("Bridge"), "bridge"], ["child-bridges", t("Child bridges"), "child"], ["backups", t("Backups"), "archive"], ["audit", t("Audit log"), "shield"], ["assistant", t("Assistant"), "sparkle"]];

  const dateTime = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false });
  const fullDate = new Intl.DateTimeFormat(locale, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  const when = (iso) => (iso ? dateTime.format(new Date(iso)) : "–");
  const size = (bytes) => HomeswiftCommon.byteSize(bytes);

  /// The pages of Settings as a row of links, a glyph each, the current one lit (a phone puts the glyph over the name,
  /// the five across).
  function subnav(current) {
    return el("nav", { class: "group subnav", "aria-label": t("Settings pages") }, pages.map(([path, text, glyph]) =>
      el("a", { href: `/settings${path ? `/${path}` : ""}`, class: path === current ? "on" : "", "aria-current": path === current ? "page" : null },
        glyph === "sparkle" ? HomeswiftCommon.sparkle() : HomeswiftCommon.icon(glyph), el("span", { text }))));
  }

  /// A modal question for what cannot be undone: `typed`, when given, must be typed before the button works.
  /// Resolves true when confirmed.
  function confirmAction({ title, text, confirmLabel = t("Continue"), typed = null, danger = true }) {
    return new Promise((resolve) => {
      const input = typed ? el("input", { type: "text", autocomplete: "off", spellcheck: false, "aria-label": t("Type {text} to confirm", { text: typed }) }) : null;
      const ok = el("button", { class: danger ? "danger" : "primary", text: confirmLabel, disabled: Boolean(typed), value: "ok" });
      const cancel = el("button", { actionIcon: "close", text: t("Cancel"), value: "cancel", type: "button" });
      // The sentence around the word to type, in the page's language: the word goes where {text} stands.
      const [typeBefore, typeAfter = ""] = t("Type {text} to confirm").split("{text}");
      const dialog = el("dialog", { class: "admin-dialog card", "aria-labelledby": "confirm-title" },
        el("form", { method: "dialog" },
          el("h2", { id: "confirm-title", text: title }),
          ...[text].flat().filter(Boolean).map((paragraph) => el("p", { text: paragraph })),
          input ? el("label", { class: "field" }, el("span", { class: "field-title" }, typeBefore, el("strong", { class: "mono", text: typed }), typeAfter), input) : null,
          el("div", { class: "actions" }, cancel, ok)));
      input?.addEventListener("input", () => { ok.disabled = input.value.trim() !== typed; });
      cancel.addEventListener("click", () => dialog.close("cancel"));
      dialog.addEventListener("close", () => { dialog.remove(); resolve(dialog.returnValue === "ok"); });
      document.body.append(dialog);
      dialog.showModal();
      (input ?? cancel).focus();
    });
  }

  /// Runs `work` with the button pressed: disabled, a spinner; errors go to `report`.
  const busy = (button, work, report) => HomeswiftCommon.busyButton(button, work, { report });

  const sectionHead = (title, note, ...tools) => el("div", { class: "section-head" }, el("h2", { text: title }), note ? el("span", { class: "muted", text: note }) : null, ...tools);

  async function view(main, [page = ""] = []) {
    const draw = { "": overviewPage, bridge: bridgePage, "child-bridges": childBridgesPage, backups: backupsPage, audit: auditPage, assistant: (main) => app().assistantPage(main, subnav("assistant")) }[page];
    if (!draw) { app().show(main, app().pageHead(t("Settings"), t("No such page.")), subnav(null)); return; }
    await draw(main);
  }

  // ---- Bridge: its block, the network, pairings, caches, schedules -----------------------------------------

  async function bridgePage(main) {
    const [settings, pairings, caches, plugins] = await Promise.all([
      api("/api/settings/bridge"), api("/api/pairings"), api("/api/cached-accessories"), api("/api/plugins").catch(() => null)]);
    const bridge = settings.bridge || {};
    const uiBlock = plugins?.blocks.find((block) => block.platform === "HomeswiftUI");
    app().show(main,
      app().pageHead(t("Settings"), t("The bridge, its pairings and cached accessories, child bridges, backups and the audit log.")),
      subnav("bridge"),
      bridgeForm(settings, bridge, pairings.bridges.find((one) => one.kind === "main")),
      networkCard(settings),
      sectionHead(t("HomeKit pairings"), t("Who the Home app knows each server by")),
      el("div", { class: "grid" }, pairings.bridges.map(pairingCard)),
      cachesSection(caches),
      schedulesCard(uiBlock));
  }

  /// The bridge block of config.json as a form. Saving restarts homeswift: the block is its HomeKit identity.
  function bridgeForm(settings, bridge, main) {
    const input = (key, attrs = {}) => el("input", { type: "text", value: bridge[key] ?? "", name: key, ...attrs });
    const fields = {
      name: input("name", { required: true }),
      port: input("port", { type: "number", min: 1, max: 65535, placeholder: settings.listeningPort ? t("Automatic (now {port})", { port: String(settings.listeningPort) }) : t("Automatic [port]") }),
      pin: input("pin", { class: "mono", placeholder: "031-45-154", pattern: "\\d{3}-\\d{2}-\\d{3}", autocomplete: "off", spellcheck: false }),
      manufacturer: input("manufacturer", { placeholder: "Homeswift" }),
      model: input("model", { placeholder: "Homeswift" }),
      firmwareRevision: input("firmwareRevision", { placeholder: t("The homeswift version") }),
    };
    const field = (title, control, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: title }), control, help ? el("span", { class: "help", text: help }) : null);
    const message = el("p", { class: "status-line muted", role: "status" });
    const save = el("button", { actionIcon: "check", class: "primary", type: "submit", text: t("Save and restart") });
    const read = () => Object.fromEntries(Object.entries(fields).map(([key, control]) => {
      const value = control.value.trim();
      return [key, value === "" ? null : key === "port" ? Number(value) : value];
    }));
    const portStatus = el("span", { class: "help", role: "status", "aria-live": "polite" });
    const checkPort = async () => {
      if (!fields.port.value.trim()) return "";
      const port = Number(fields.port.value);
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(t("Choose a port between 1 and 65535."));
      if (port === settings.listeningPort) return "";
      const answer = await api("/api/config/check-port", { method: "POST", body: { port, host: "0.0.0.0", service: "bridge" } });
      if (!answer.available) throw new Error(t("Port {port} is in use or cannot be opened on this address. Choose another port.", { port: String(port) }));
      return t("Port {port} is available.", { port: String(port) });
    };
    let portTimer, portVersion = 0;
    const schedulePortCheck = () => {
      clearTimeout(portTimer);
      const version = ++portVersion;
      portStatus.className = "help muted";
      portStatus.textContent = fields.port.value ? t("Checking port…") : "";
      portTimer = setTimeout(async () => {
        try { const text = await checkPort(); if (version === portVersion) { portStatus.className = "help ok"; portStatus.textContent = text; } }
        catch (error) { if (version === portVersion) { portStatus.className = "help error"; portStatus.textContent = error.message; } }
      }, 400);
    };
    fields.port.addEventListener("input", schedulePortCheck);
    fields.port.addEventListener("change", schedulePortCheck);
    const stepPort = (direction) => {
      const current = fields.port.value === "" ? (settings.listeningPort || 1) : Number(fields.port.value);
      fields.port.value = String(Math.min(65535, Math.max(1, (Number.isFinite(current) ? current : 1) + direction)));
      fields.port.dispatchEvent(new Event("input", { bubbles: true }));
    };
    fields.port.addEventListener("keydown", (event) => {
      if (event.key === "ArrowUp" || event.key === "ArrowDown") {
        event.preventDefault(); stepPort(event.key === "ArrowUp" ? 1 : -1);
      }
    });
    const portControl = el("div", { class: "port-stepper" }, fields.port,
      el("div", { class: "port-stepper-buttons" },
        ...[[1, t("Increase port")], [-1, t("Decrease port")]].map(([direction, label]) => {
          const button = el("button", { type: "button", title: label, "aria-label": label, onclick: () => stepPort(direction) });
          button.innerHTML = `<svg viewBox="0 0 16 16" aria-hidden="true"><path d="${direction === 1 ? "M4 10l4-4 4 4" : "M4 6l4 4 4-4"}"/></svg>`;
          return button;
        })));
    const initial = JSON.stringify(read());
    const form = el("form", { class: "card form-card", onsubmit: async (event) => {
      event.preventDefault();
      const next = read();
      if (JSON.stringify(next) === initial) { message.className = "status-line muted"; message.textContent = t("Nothing changed."); return; }
      try { await checkPort(); }
      catch (error) { portStatus.className = "help error"; portStatus.textContent = error.message; fields.port.focus(); return; }
      if (!(await confirmAction({ title: t("Restart homeswift with these settings?"), danger: false, confirmLabel: t("Save and restart"),
        text: [t("The bridge block is the bridge's HomeKit identity: homeswift restarts to apply it, and every connection drops for a few seconds."),
          next.pin !== (bridge.pin ?? null) ? t("A new setup code applies to new pairings only: the Home app keeps the bridge.") : ""] }))) return;
      await busy(save, async () => {
        await checkPort();
        const result = await api("/api/settings/bridge", { method: "PUT", body: { settings: next } });
        message.className = "status-line ok";
        message.textContent = app().savedText(result);
      }, (e) => { message.className = "status-line error"; message.textContent = e.message; });
    } },
      el("div", { class: "server-head" }, tile("bridge", "orange"),
        el("div", { class: "who" }, el("strong", { text: t("Bridge") }), el("div", { class: "muted", text: t("config.json's bridge block") }))),
      el("div", { class: "facts lead" }, fact(t("Device ID"), settings.deviceId, { class: "mono" }), fact(t("Listening on port"), settings.listeningPort ?? "?"),
        fact(t("Home app"), main?.paired ? t("Paired · {count}", { count: main.controllers }) : t("Not paired"))),
      el("div", { class: "fields" },
        field(t("Name"), fields.name, t("What the Home app calls the bridge when it is added.")),
        field(t("Port"), portControl, t("The HomeKit server's port; empty picks a free one and keeps it.")),
        field(t("Setup code"), fields.pin, t("The code the Home app asks for, as XXX-XX-XXX. It is never logged.")),
        field(t("Manufacturer"), fields.manufacturer), field(t("Model"), fields.model), field(t("Firmware revision"), fields.firmwareRevision)),
      el("p", { class: "help", text: t("The device ID stays: a new one is a new bridge to the Home app. To pair again from scratch, reset the bridge's pairings below.") }),
      el("div", { class: "actions" }, save), message);
    portStatus.style.display = "block";
    portControl.parentElement.append(portStatus);
    return form;
  }

  /// What this machine runs the bridge with: its addresses and the advertiser. Homeswift listens on every
  /// interface and has no setting for the interfaces to bind or advertise on, nor another mDNS backend.
  function networkCard(settings) {
    return el("div", { class: "card server" },
      el("div", { class: "server-head" }, tile("system", "grey"),
        el("div", { class: "who" }, el("strong", { text: t("Network") }), el("div", { class: "muted", text: t("Where the Home app finds the bridge") }))),
      el("div", { class: "facts" }, fact(t("Advertised with"), settings.advertiser), fact(t("Interfaces"), t("Every one")), fact(t("Port"), settings.listeningPort ?? "?")),
      settings.addresses?.length ? el("div", { class: "chips" }, settings.addresses.map((address) => el("span", { class: "chip mono", text: address }))) : null,
      el("p", { class: "muted note", text: t("Homeswift listens and advertises on every interface, with the system's mDNS: there is no interface or mDNS backend to choose, as Homebridge's bind and advertiser settings do.") }));
  }

  /// A server's pairing state, and a menu to forget its controllers.
  function pairingCard(bridge) {
    const kind = { main: ["bridge", "orange", t("Main bridge")], child: ["child", "violet", t("Child bridge")], external: ["accessory", "blue", t("Accessory of its own")] }[bridge.kind] ?? ["bridge", "grey", bridge.kind];
    return el("div", { class: "card server" },
      el("div", { class: "server-head" }, tile(kind[0], kind[1]),
        el("div", { class: "who" }, el("strong", { text: bridge.name }), el("div", { class: "muted", text: kind[2] })),
        el("span", { class: `pill status ${bridge.paired ? "on" : "away"}`, text: bridge.paired ? t("Paired · {count}", { count: bridge.controllers }) : t("Not paired") })),
      el("div", { class: "facts" }, fact(t("Device ID"), bridge.deviceId, { class: "mono" }), fact(t("Controllers"), bridge.controllers), fact(t("Admins"), bridge.admins)),
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: bridge.paired ? t("In the Home app") : t("Waiting to be added (setup code on the Status page)") }),
        menuButton(t("Actions for {name}", { name: bridge.name }), () => [
          { label: t("Reset pairings…"), icon: "key", danger: true, onSelect: () => resetPairings(bridge) },
        ])));
  }

  async function resetPairings(bridge) {
    const ok = await confirmAction({
      title: t("Reset the pairings of {name}?", { name: bridge.name }), confirmLabel: t("Reset pairings"), typed: bridge.name,
      text: [t("Every Home app controller paired with it is forgotten and disconnected. The Home app loses it with its accessories, their rooms, scenes and automations."),
        t("Add it again afterwards with its setup code, as a new bridge.")],
    });
    if (!ok) return;
    await busy(null, async () => { await api("/api/pairings/reset", { method: "POST", body: { bridge: bridge.deviceId, confirm: true } }); app().route(); });
  }

  /// The accessory caches: what each plugin's cache brings back at start, the stale ones first.
  function cachesSection(caches) {
    const list = [...caches.accessories].sort((a, b) => (b.orphaned || b.restoredOnly) - (a.orphaned || a.restoredOnly) || a.name.localeCompare(b.name));
    const row = (cached) => el("div", { class: "row" },
      el("div", { class: "who" }, el("strong", { text: cached.name }),
        el("div", { class: "muted", text: [cached.mirroredFrom ? t("Mirrored from {source}", { source: cached.mirroredFrom }) : null, cached.instance ?? cached.platform ?? cached.cacheFile, cached.mirroredFrom ? null : cached.bridge, cached.manufacturer, cached.model].filter(Boolean).join(" · ") })),
      cached.orphaned ? el("span", { class: "pill status away", text: t("No block"), title: t("Its block is no longer in config.json") })
        : cached.restoredOnly ? el("span", { class: "pill status away", text: t("Stale"), title: t("Back from the cache, not added again by its plugin") }) : el("span", { class: "pill status on", text: t("Current") }),
      menuButton(t("Actions for {name}", { name: cached.name }), () => [
        { label: t("Remove from the cache…"), icon: "trash", danger: true, onSelect: () => removeCached(cached) },
      ]));
    const reset = menuButton(t("Actions for every cache"), () => [
      { label: t("Reset every cache…"), icon: "trash", danger: true, onSelect: resetCaches },
    ]);
    const search = el("input", { type: "search", class: "search", placeholder: t("Search cached accessories"), "aria-label": t("Search cached accessories") });
    const totalText = tn("{count} in {n} cache file", "{count} in {n} cache files", new Set(list.map((c) => c.cacheFile)).size, { count: list.length });
    const matchCount = el("span", { class: "muted", role: "status", "aria-live": "polite", text: totalText });
    const results = el("div", { class: "card rows cached-search-results" });
    const empty = el("p", { class: "card empty muted cached-search-empty", role: "status", text: t("No accessory matches."), hidden: true });
    const normalize = (value) => String(value ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase();
    const selectedStatuses = new Set();
    const entries = list.map((cached) => ({
      status: cached.orphaned ? "orphaned" : cached.restoredOnly ? "stale" : "current",
      node: row(cached),
      text: normalize([cached.name, cached.id, cached.instance, cached.platform, cached.bridge, cached.manufacturer, cached.model, cached.mirroredFrom].filter(Boolean).join(" ")),
    }));
    results.append(...entries.map((entry) => entry.node));
    const filter = () => {
      const terms = normalize(search.value).trim().split(/\s+/).filter(Boolean);
      let count = 0;
      for (const entry of entries) {
        entry.node.hidden = (selectedStatuses.size > 0 && !selectedStatuses.has(entry.status)) || !terms.every((term) => entry.text.includes(term));
        if (!entry.node.hidden) count++;
      }
      matchCount.textContent = terms.length || selectedStatuses.size ?  t("{count} of {total} match", { count, total: list.length }) : totalText;
      results.hidden = count === 0;
      empty.hidden = count !== 0;
    };
    const statuses = [["current", t("Current"), "check"], ["stale", t("Stale"), "history"], ["orphaned", t("No block"), "warning"]];
    const filters = el("button", { type: "button", "aria-haspopup": "menu", "aria-label": t("Filters"), onclick: () => HomeswiftCommon.menu(filters, [
      ...statuses.map(([value, label, icon]) => ({ label, icon, tone: { current: "ok", stale: "warn", orphaned: "error" }[value], count: entries.filter((entry) => entry.status === value && normalize(search.value).trim().split(/\s+/).filter(Boolean).every((term) => entry.text.includes(term))).length, checkbox: true, toggle: true, checked: selectedStatuses.has(value), onSelect: () => {
        if (selectedStatuses.has(value)) selectedStatuses.delete(value); else selectedStatuses.add(value);
        filters.classList.toggle("on", selectedStatuses.size > 0);
        filterCount.textContent = selectedStatuses.size ? String(selectedStatuses.size) : "";
        filter();
      } })),
      { separator: true },
      { label: t("Clear filters"), clearFilters: true, icon: "restore", disabled: !search.value && selectedStatuses.size === 0, onSelect: () => {
        search.value = "";
        selectedStatuses.clear();
        filters.classList.remove("on");
        filterCount.textContent = "";
        filter();
      } },
    ]) }, HomeswiftCommon.icon("sliders"), el("span", { text: t("Filters") }));
    const filterCount = el("span", { class: "cached-filter-count" });
    filters.append(filterCount);
    search.addEventListener("input", filter);
    search.addEventListener("search", filter);
    return el("section", {},
      sectionHead(t("Cached accessories"), null, matchCount,
        el("div", { class: "cached-search-tools" }, list.length ? [search, filters] : null, reset)),
      list.length ? [results, empty] : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("accessory")), el("p", { class: "muted", text: t("No cached accessory.") })));

  }

  async function removeCached(cached) {
    const ok = await confirmAction({
      title: t("Remove {name} from the cache?", { name: cached.name }), confirmLabel: t("Remove"),
      text: cached.mirroredFrom
        ? t("This removes the local copy from Homeswift. The original accessory stays in {source}. The plugin can add the local copy again when it reconnects.", { source: cached.mirroredFrom })
        : t("This removes the accessory from Homeswift and stops publishing it to Apple Home. If the plugin discovers the device again, it can return with the same ids. Devices that are no longer available will not return."),
    });
    if (!ok) return;
    await busy(null, async () => { await api("/api/cached-accessories/remove", { method: "POST", body: { id: cached.id, cacheFile: cached.cacheFile } }); app().route(); });
  }

  async function resetCaches() {
    const ok = await confirmAction({
      title: t("Reset every accessory cache?"), confirmLabel: t("Reset the caches"), typed: "RESET",
      text: [t("Accessories published by Homeswift leave HomeKit while the plugins rebuild their caches. Mirrored accessories stay in their original home; only their local copies are cleared."),
        t("Their ids stay, so rooms and automations come back with the devices; accessories of devices that are gone do not.")],
    });
    if (!ok) return;
    await busy(null, async () => { await api("/api/cached-accessories/reset", { method: "POST", body: { confirm: true } }); app().route(); });
  }

  /// The schedules and the reverse proxy: settings of the web UI's own block, edited in its form.
  function schedulesCard(uiBlock) {
    return el("section", {},
      sectionHead(t("Schedules and proxy"), t("In the web UI's settings")),
      el("div", { class: "card page-note" },
        el("p", { text: t("A scheduled restart (a cron expression), the daily backup (its folder and how long it is kept) and the reverse proxies trusted for X-Forwarded-For and X-Forwarded-Proto are settings of the HomeswiftUI block.") }),
        uiBlock ? el("a", { actionIcon: "sliders", class: "button", href: `/plugins/${uiBlock.slug}?section=proxy`, text: t("Open its settings") }) : null));
  }

  // ---- Child bridges -------------------------------------------------------------------------------------

  async function childBridgesPage(main) {
    const [{ childBridges }, status, plugins] = await Promise.all([api("/api/child-bridges"), api("/api/status"), api("/api/plugins")]);
    const slugs = new Map(withSlugs(status.bridges, "bridge").map((bridge) => [bridge.deviceId, bridge.slug]));
    const tone = { ok: "on", degraded: "away", stopped: "paused" };
    const card = (bridge) => {
      const failures = Object.entries(bridge.failedPlugins ?? {});
      return el("div", { class: "card server" },
        el("div", { class: "server-head" }, tile("child", "violet"),
          el("div", { class: "who" }, el("strong", { text: bridge.name }), el("div", { class: "muted", text: bridge.plugins.join(", ") || t("No plugin") })),
          el("span", { class: `pill status ${tone[bridge.status] ?? "standby"}`, text: bridge.status === "stopped" && bridge.stoppedManually ? t("Stopped by hand") : { ok: t("Running"), degraded: t("Degraded"), stopped: t("Stopped [bridge]") }[bridge.status] ?? bridge.status })),
        el("div", { class: "facts lead" }, fact(t("Device ID"), bridge.id, { class: "mono" }), fact(t("Port"), bridge.port ?? "–"), fact(t("Accessories"), bridge.accessories)),
        el("div", { class: "facts" }, fact(t("Up [uptime]"), bridge.uptimeSeconds == null ? "–" : app().formatDuration(bridge.uptimeSeconds)), fact(t("Restarts"), bridge.restarts),
          fact(t("Pairing"), bridge.paired ? t("Paired · {count}", { count: bridge.controllers }) : t("Not paired"))),
        bridge.instances.length ? el("div", { class: "chips" }, bridge.instances.map((name) => el("span", { class: "chip", text: name }))) : null,
        failures.length ? el("div", { class: "notice-list" }, failures.map(([plugin, reason]) => el("p", { class: "error", text: t("{plugin} did not start: {reason}", { plugin, reason: HomeswiftI18n.message(reason) }) }))) : null,
        bridge.setupCode ? el("div", { class: "setup" },
          el("img", { class: "qr", src: `/api/qr/${bridge.qrIndex}.svg`, alt: t("Pairing QR code"), width: 148, height: 148 }),
          el("div", {}, el("p", { text: t("In the Home app: Add Accessory, then scan this code, or choose More options and type it.") }), el("div", { class: "code", text: bridge.setupCode }))) : null,
        el("div", { class: "card-foot" },
          el("span", { class: "muted", text: bridge.running ? t("Runs inside homeswift") : t("Its accessories show No Response") }),
          menuButton(t("Actions for {name}", { name: bridge.name }), () => [
            { label: t("Restart"), icon: "restore", onSelect: () => control(bridge, "restart") },
            bridge.running ? { label: t("Stop"), icon: "pause", onSelect: () => control(bridge, "stop") } : { label: t("Start"), icon: "play", onSelect: () => control(bridge, "start") },
            { label: t("Show its log"), icon: "logs", href: `/logs?bridge=${encodeURIComponent(slugs.get(bridge.id) ?? "all")}` },
            { label: t("Reset pairings…"), icon: "key", danger: true, onSelect: () => resetPairings({ name: bridge.name, deviceId: bridge.id }) },
          ])));
    };
    app().show(main,
      app().pageHead(t("Child bridges"), t("Plugins on HomeKit bridges of their own (a block with _bridge), inside this process: one can restart without the others.")),
      subnav("child-bridges"),
      el("section", {}, sectionHead(t("Plugin bridges")),
        el("div", { class: "card rows" }, plugins.blocks.filter((block) => !["HomeswiftUI", "HomeswiftAiKit"].includes(block.platform)).map((block) =>
          el("div", { class: "row" }, tile("child", "blue"),
            el("div", { class: "who" }, el("strong", { text: block.name }), el("div", { class: "muted", text: block.childBridge ? t("Child bridge") : t("Main bridge") })),
            el("button", { actionIcon: "sliders", text: t("Configure"), onclick: () => editChildBridge(block) }))))),
      childBridges.length ? el("div", { class: "servers" }, childBridges.map(card))
        : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("child")), el("p", { class: "muted", text: t("No child bridges yet. Configure a plugin above to give it its own bridge.") })));
  }

  async function editChildBridge(entry) {
    const path = `/api/config/block/${encodeURIComponent(entry.platform)}/${encodeURIComponent(entry.name)}`;
    let block;
    try { block = await api(path); } catch (error) { alert(error.message); return; }
    const enabled = el("input", { type: "checkbox", checked: Boolean(block._bridge) });
    const name = el("input", { value: block._bridge?.name ?? "", placeholder: entry.name });
    const port = el("input", { type: "number", min: 1, max: 65535, value: block._bridge?.port ?? "", placeholder: t("Automatic") });
    const fields = el("div", { class: "child-bridge-fields" },
      el("label", {}, el("span", { text: t("Name") }), name),
      el("label", {}, el("span", { text: t("Port") }), port));
    const update = () => { name.disabled = port.disabled = !enabled.checked; fields.hidden = !enabled.checked; };
    enabled.addEventListener("change", update); update();
    const result = el("p", { class: "error", role: "status" });
    const cancel = el("button", { actionIcon: "close", type: "button", text: t("Cancel"), onclick: () => dialog.close() });
    const save = el("button", { actionIcon: "check", type: "submit", class: "primary", text: t("Save") });
    const form = el("form", {}, el("h2", { text: entry.name }),
      el("label", { class: "child-bridge-toggle" }, enabled, el("span", { text: t("Run on its own HomeKit bridge") })), fields,
      el("p", { class: "muted", text: t("Moving a plugin between bridges changes where its accessories appear in Apple Home. You may need to pair the new bridge and recreate room assignments or automations. Saving reloads the plugin.") }),
      result, el("div", { class: "actions" }, cancel, save));
    const dialog = el("dialog", { class: "admin-dialog", "aria-label": entry.name }, form);
    form.addEventListener("submit", async (event) => {
      event.preventDefault(); save.disabled = true; cancel.disabled = true;
      const next = { ...block };
      if (enabled.checked) {
        next._bridge = { ...(block._bridge ?? {}) };
        if (name.value.trim()) next._bridge.name = name.value.trim(); else delete next._bridge.name;
        if (port.value) next._bridge.port = Number(port.value); else delete next._bridge.port;
      } else delete next._bridge;
      try { await api(path, { method: "PUT", body: next }); dialog.close(); app().route(); }
      catch (error) { result.textContent = error.message; save.disabled = cancel.disabled = false; }
    });
    dialog.addEventListener("close", () => dialog.remove(), { once: true });
    document.body.append(dialog); dialog.showModal();
  }

  async function control(bridge, action) {
    if (action !== "start" && !(await confirmAction({ title: action === "stop" ? t("Stop {name}?", { name: bridge.name }) : t("Restart {name}?", { name: bridge.name }), confirmLabel: action === "stop" ? t("Stop") : t("Restart"), danger: action === "stop",
      text: action === "stop" ? t("Its plugins stop and its accessories show No Response until it starts again, or homeswift restarts.") : t("Its accessories are unavailable for a moment; pairings stay.") }))) return;
    await busy(null, async () => { await api(`/api/child-bridges/${encodeURIComponent(bridge.id)}/${action}`, { method: "POST" }); app().route(); });
  }

  // ---- Backups -------------------------------------------------------------------------------------------

  async function backupsPage(main) {
    const [backups, configBackups] = await Promise.all([api("/api/backups"), api("/api/config/backups")]);
    const message = el("p", { class: "status-line muted", role: "status" });
    const report = (e) => { message.className = "status-line error"; message.textContent = e.message; };
    const now = el("button", { actionIcon: "archive", class: "primary", text: t("Back up now"), onclick: (event) => busy(event.currentTarget, async () => {
      const result = await api("/api/backups", { method: "POST" });
      message.className = "status-line ok";
      message.textContent = t("Kept {file} ({size}).", { file: result.backup.fileName, size: size(result.backup.bytes) });
      setTimeout(() => app().route(), 1200);
    }, report) });
    const instance = el("div", { class: "card server backup-create" },
      el("div", { class: "server-head" }, tile("archive", "green"),
        el("div", { class: "who" }, el("strong", { text: t("Back up this bridge") }),
          el("div", { class: "muted", text: t("config.json, each bridge's HomeKit identity and pairings, accessory caches, plugin files, the web UI's users") }))),
      el("div", { class: "facts" },
        fact(t("Daily backup"), backups.scheduled ? (backups.nextBackup ? t("Next {date}", { date: when(backups.nextBackup) }) : t("On [setting]")) : t("Off [setting]")),
        fact(t("Kept"), tn("{n} day", "{n} days", backups.retentionDays)),
        fact(t("Scheduled restart"), backups.restartCron ? (backups.nextRestart ? t("{cron} · next {date}", { cron: backups.restartCron, date: when(backups.nextRestart) }) : backups.restartCron) : t("None"))),
      el("div", { class: "fact wide" }, el("span", { text: t("Folder") }), el("b", { class: "mono", text: backups.folder, title: backups.folder })),
      el("div", { class: "actions" },
        now, el("a", { actionIcon: "download", class: "button", href: "/api/backups/download", download: "", text: t("Download a backup") })),
      message);
    app().show(main,
      app().pageHead(t("Backups"), t("The whole instance, to move it or start over, and each saved config.json.")),
      subnav("backups"),
      el("div", { class: "backup-actions-grid" }, instance, restoreCard(backups)),
      sectionHead(t("Kept backups"), backups.backups.length ? t("{n}, newest first", { n: backups.backups.length }) : ""),
      backups.backups.length ? el("div", { class: "card rows" }, backups.backups.map(backupRow))
        : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("archive")), el("p", { class: "muted", text: t("None yet: the daily backup and Back up now keep them here.") })),
      sectionHead(t("config.json backups"), tn("The file before its last save", "The file before each of its last {n} saves", configBackups.kept)),
      configBackups.backups.length ? el("div", { class: "card rows" }, configBackups.backups.map(configBackupRow))
        : el("div", { class: "card empty" }, el("p", { class: "muted", text: t("None yet: each save of config.json keeps the file it replaces.") })));
  }

  /// A file to restore, dropped or chosen: checked by the bridge, staged, and applied as homeswift restarts.
  function restoreCard(backups) {
    const picker = el("input", { type: "file", accept: ".tar,application/x-tar", class: "hidden" });
    // The sentence around the link, in the page's language: the link goes where {choose} stands.
    const [dropBefore, dropAfter = ""] = t("Drop a backup (.tar) here, or {choose}").split("{choose}");
    const zone = el("div", { class: "drop-zone", role: "button", tabIndex: 0, "aria-label": t("Drop or choose a backup to restore") },
      el("span", { class: "backup-drop-icon", "aria-hidden": "true" }, HomeswiftCommon.icon("restore")),
      el("span", {}, dropBefore, el("strong", { text: t("choose it") }), dropAfter), picker);
    const result = el("div", {});
    const take = async (file) => {
      if (!file) return;
      if (file.size > backups.maxRestoreBytes) { zone.replaceChildren(t("{file} is larger than {size}.", { file: file.name, size: size(backups.maxRestoreBytes) }), picker); return; }
      await restoreArchive(file.name, () => fetch("/api/backups/restore", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-tar" }, body: file }), result);
    };
    zone.addEventListener("click", (event) => { if (event.target !== picker) picker.click(); });
    zone.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); picker.click(); } });
    picker.addEventListener("change", () => { take(picker.files[0]); picker.value = ""; });
    zone.addEventListener("dragover", (event) => { event.preventDefault(); zone.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("over"));
    zone.addEventListener("drop", (event) => { event.preventDefault(); zone.classList.remove("over"); take(event.dataTransfer.files[0]); });
    return el("div", { class: "card backup-restore" },
      el("div", { class: "server-head" }, tile("restore", "violet"), el("h2", { text: t("Restore a backup") })),
      el("details", { class: "backup-restore-help" }, el("summary", { text: t("What happens when you restore?") }),
el("p", { class: "muted", text: t("A backup made by Download a backup or kept below replaces this bridge's files as homeswift restarts: its pairings, accessories and plugin settings come back; this machine's bridge and web UI ports stay. Files it does not have stay as they are.") })),
      backups.pendingRestore ? el("p", { class: "ok", text: t("A restore is staged: it applies when homeswift next starts.") }) : null,
      zone, result);
  }

  /// Asks, sends the archive (`send` answers the fetch's Response), and waits for the restart.
  async function restoreArchive(name, send, result) {
    const ok = await confirmAction({
      title: t("Restore {name}?", { name }), confirmLabel: t("Restore and restart"), typed: "RESTORE",
      text: [t("homeswift restarts on the backup's files: config.json, the bridges' HomeKit identities and pairings, accessory caches, plugin files and the web UI's users. What changed since it was made is lost."),
        t("Run one homeswift per backup: two bridges with the same identity make the Home app drop them.")],
    });
    if (!ok) return;
    result.replaceChildren(el("p", { class: "muted", text: t("Checking the backup…") }));
    try {
      const response = await send();
      const answer = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(HomeswiftI18n.message(answer.error || `HTTP ${response.status}`));
      const staged = answer.created
        ? tn("{n} file from {date} is staged.", "{n} files from {date} are staged.", answer.files, { date: fullDate.format(new Date(answer.created)) })
        : tn("{n} file from the backup is staged.", "{n} files from the backup are staged.", answer.files);
      result.replaceChildren(el("p", { class: "ok", text: `${staged} ${HomeswiftI18n.message(answer.note)}` }),
        answer.skipped?.length ? el("p", { class: "muted", text: t("Left out: {files}.", { files: answer.skipped.join(", ") }) }) : null);
      if (answer.restarting) app().waitForRestart();
    } catch (e) {
      result.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  function backupRow(backup) {
    const result = el("div", {});
    return el("div", { class: "row-block" },
      el("div", { class: "row" },
        el("div", { class: "who" }, el("strong", { text: fullDate.format(new Date(backup.date)) }), el("div", { class: "muted mono", text: backup.fileName })),
        el("span", { class: "muted", text: size(backup.bytes) }),
        menuButton(t("Actions for the backup of {date}", { date: when(backup.date) }), () => [
          { label: t("Download"), icon: "download", href: `/api/backups/${encodeURIComponent(backup.id)}/download` },
          { label: t("Restore…"), icon: "restore", onSelect: () => restoreArchive(fullDate.format(new Date(backup.date)),
            () => fetch(`/api/backups/${encodeURIComponent(backup.id)}/restore`, { method: "POST", credentials: "same-origin" }), result) },
          { label: t("Delete…"), icon: "trash", danger: true, onSelect: async () => {
            if (!(await confirmAction({ title: t("Delete this backup?"), confirmLabel: t("Delete"), text: t("{file} is removed from the folder.", { file: backup.fileName }) }))) return;
            await busy(null, async () => { await api(`/api/backups/${encodeURIComponent(backup.id)}`, { method: "DELETE" }); app().route(); });
          } },
        ])),
      result);
  }

  /// A saved config.json: compared with the file as it is, as a diff, and restored.
  function configBackupRow(backup) {
    const detail = el("div", { class: "row-detail hidden" });
    const compare = async () => {
      if (!detail.classList.contains("hidden")) { detail.classList.add("hidden"); return; }
      detail.classList.remove("hidden");
      detail.replaceChildren(el("p", { class: "muted", text: t("Comparing…") }));
      try {
        const [then, now] = await Promise.all([
          api(`/api/config/backups/${encodeURIComponent(backup.name)}`, { raw: true }), api("/api/config", { raw: true })]);
        detail.replaceChildren(diffView(jsonDiff(JSON.parse(then), JSON.parse(now)), t("this backup"), t("config.json now")));
      } catch (e) { detail.replaceChildren(el("p", { class: "error", text: e.message })); }
    };
    const restore = async () => {
      if (!(await confirmAction({ title: t("Restore this config.json?"), confirmLabel: t("Restore"), text: t("It replaces config.json (which is kept as a backup first) and applies at once, as a save does: plugins reload, and the bridge block restarts homeswift.") }))) return;
      await busy(null, async () => {
        const result = await api(`/api/config/backups/${encodeURIComponent(backup.name)}/restore`, { method: "POST" });
        detail.classList.remove("hidden");
        detail.replaceChildren(el("p", { class: "ok", text: `${result.changes.length ? t("Changed: {changes}.", { changes: result.changes.join(", ") }) : t("Nothing changed.")} ${app().savedText(result)}` }));
      });
    };
    return el("div", { class: "row-block" },
      el("div", { class: "row" },
        el("div", { class: "who" }, el("strong", { text: backup.date ? fullDate.format(new Date(backup.date)) : backup.name }), el("div", { class: "muted mono", text: backup.name })),
        el("button", { actionIcon: "code", class: "link", text: t("Compare"), onclick: compare }),
        menuButton(t("Actions for {name}", { name: backup.name }), () => [
          { label: t("Compare with config.json"), icon: "code", onSelect: compare },
          { label: t("Restore…"), icon: "restore", danger: true, onSelect: restore },
        ])),
      detail);
  }

  /// A diff of `jsonDiff` lines: the changes with three lines around them, the rest folded.
  function diffView(lines, before, after) {
    if (!lines.some((line) => line.kind !== "same")) return el("p", { class: "muted", text: t("The same as config.json now.") });
    const keep = new Set();
    lines.forEach((line, index) => { if (line.kind !== "same") for (let k = index - 3; k <= index + 3; k++) keep.add(k); });
    const nodes = [];
    let folded = 0;
    lines.forEach((line, index) => {
      if (!keep.has(index)) { folded++; return; }
      if (folded) { nodes.push(el("span", { class: "diff-fold", text: `  … ${tn("{n} unchanged line", "{n} unchanged lines", folded)}\n` })); folded = 0; }
      nodes.push(el("span", { class: `diff-${line.kind}`, text: `${line.kind === "add" ? "+ " : line.kind === "remove" ? "- " : "  "}${line.text}\n` }));
    });
    if (folded) nodes.push(el("span", { class: "diff-fold", text: `  … ${tn("{n} unchanged line", "{n} unchanged lines", folded)}\n` }));
    return el("div", {}, el("p", { class: "muted", text: `− ${before}   + ${after}` }), el("pre", { class: "diff" }, nodes));
  }

  // ---- Audit log -----------------------------------------------------------------------------------------

  const outcomes = [["", t("Every outcome")], ["ok", t("Done [outcome]")], ["failed", t("Failed")], ["notConfirmed", t("Not confirmed")]];
  const spans = [["24h", t("Last 24 hours")], ["7d", t("Last 7 days")], ["30d", t("Last 30 days")], ["", t("Everything kept")]];

  async function auditPage(main) {
    const params = new URLSearchParams(location.search);
    const tool = el("input", { type: "search", class: "search", placeholder: t("Tool or route"), value: params.get("tool") ?? "", "aria-label": t("Filter by tool") });
    const client = el("input", { type: "search", class: "search", placeholder: t("Client or user"), value: params.get("client") ?? "", "aria-label": t("Filter by client") });
    const select = (choices, value, label) => {
      const control = el("button", { class: "audit-picker", type: "button", "aria-label": label, "aria-haspopup": "menu" });
      control.value = value;
      control.counts = new Map();
      const counted = (v, label) => control.counts.has(v) ? `${label} (${control.counts.get(v)})` : label;
      const paint = () => control.replaceChildren(el("span", { text: counted(control.value, choices.find(([v]) => v === control.value)?.[1] ?? label) }), el("span", { text: "⌄", "aria-hidden": "true" }));
      control.addEventListener("click", () => HomeswiftCommon.menu(control, choices.map(([v, text]) => ({ label: text, count: control.counts.get(v), disabledReason: t("No audit entries match the current filters."), checked: control.value === v, onSelect: () => { control.value = v; paint(); control.dispatchEvent(new Event("change")); } }))));
      control.paint = paint;
      control.addEventListener("change", paint);
      paint();
      return control;
    };
    const outcome = select(outcomes, params.get("outcome") ?? "", t("Outcome"));
    const since = select(spans, params.has("since") ? params.get("since") : "7d", t("Time range"));
    const count = el("span", { class: "muted count", role: "status", "aria-live": "polite" });
    const body = el("div", {});
    let loads = 0;   // the answer drawn is the last request's, however they arrive
    async function load() {
      const own = ++loads;
      const query = new URLSearchParams();
      if (tool.value.trim()) query.set("tool", tool.value.trim());
      if (client.value.trim()) query.set("client", client.value.trim());
      if (outcome.value) query.set("outcome", outcome.value);
      query.set("since", since.value);
      window.history.replaceState(null, "", `/settings/audit?${query}`);
      if (!since.value) query.delete("since");
      count.textContent = t("Loading…");
      for (const control of [outcome, since]) { control.counts.clear(); control.paint(); }
      // The server counts each alternative against the current text and the other selected filter, in the same pass.
      query.set("spans", spans.map(([value]) => value).join(","));
      let found;
      try { found = await api(`/api/audit?${query}`); } catch (e) { if (own === loads) count.textContent = e.message; return; }
      if (own !== loads) return;
      for (const [control, key] of [[outcome, "outcome"], [since, "since"]]) {
        control.counts = new Map(Object.entries(found.counts?.[key] ?? {}));
        control.paint();
      }
      if (!found.enabled) {
        count.textContent = "";
        body.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: t("The audit log is off: the HomeswiftAiKit block's mcp.http says auditLog: false.") })));
        return;
      }
      count.textContent = t("{shown} of {total}", { shown: found.entries.length, total: found.total });
      body.replaceChildren(found.entries.length ? el("div", { class: "card audit-results" }, el("div", { class: "table-scroll" }, el("table", { class: "data-table" },
        el("thead", {}, el("tr", {}, [t("Time"), t("Who"), t("What"), t("Outcome"), t("Details")].map((text) => el("th", { text })))),
        el("tbody", {}, found.entries.map(auditRow)))), el("p", { class: "muted note", text: found.path }))
        : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("shield")), el("p", { class: "muted", text: t("Nothing in this range matches.") })));
    }
    let typing = null;
    for (const input of [tool, client]) input.addEventListener("input", () => { clearTimeout(typing); typing = setTimeout(load, 250); });
    for (const choice of [outcome, since]) choice.addEventListener("change", () => { clearTimeout(typing); typing = setTimeout(load, 0); });
    app().show(main,
      app().pageHead(t("Audit log"), t("Every change made through the MCP server, the Assistant's chat and this web UI, with who made it.")),
      subnav("audit"),
      el("div", { class: "card audit-filters" },
        el("div", { class: "audit-filter-grid" },
          el("label", {}, el("span", { text: t("Time range") }), since),
          el("label", {}, el("span", { text: t("Outcome") }), outcome),
          el("label", {}, el("span", { text: t("Tool or route") }), tool),
          el("label", {}, el("span", { text: t("Client or user") }), client)),
        el("div", { class: "audit-filter-footer" }, count,
          HomeswiftCommon.clearFilters([[tool, ""], [client, ""], [outcome, ""], [since, "7d"]], { reset: () => clearTimeout(typing) }))),
      body);
    await load();
  }

  function auditRow(entry) {
    const [text, kind] = entry.notConfirmed ? [t("Not confirmed"), "away"] : entry.ok ? [t("Done [outcome]"), "on"] : [t("Failed"), "away"];
    const args = entry.args && Object.keys(entry.args).length ? JSON.stringify(entry.args) : "";
    return el("tr", {},
      el("td", { text: entry.ts ? dateTime.format(new Date(entry.ts)) : "–", title: entry.ts ?? "" }),
      el("td", {}, el("strong", { text: entry.principal ?? "?" }), el("div", { class: "muted", text: `${entry.client ?? "?"} · ${entry.scope ?? ""}` })),
      el("td", { class: "mono", text: entry.dryRun ? t("{tool} (dry run)", { tool: entry.tool }) : entry.tool }),
      el("td", {}, el("span", { class: `pill status ${kind}`, text })),
      el("td", { class: "audit-details" }, entry.error ? el("div", { class: "error", text: entry.error }) : null, args ? el("details", {}, el("summary", { text: t("Details") }), HomeswiftCommon.jsonView(entry.args)) : null));
  }

  // ---- An accessory's history -----------------------------------------------------------------------------

  const historyUnits = { celsius: "°C", percentage: "%", W: "W", lux: "lx", hPa: "hPa", ppm: "ppm", "µg/m³": "µg/m³" };
  const historyLabels = {
    CurrentTemperature: t("Temperature"), TargetTemperature: t("Target temperature"), CurrentRelativeHumidity: t("Humidity"), AirPressure: t("Air pressure"),
    AirQuality: t("Air quality"), VOCDensity: t("VOC density"), CurrentConsumption: t("Power [watts]"), CurrentAmbientLightLevel: t("Light level"), On: t("On"),
    ContactSensorState: t("Contact"), MotionDetected: t("Motion"), ValvePosition: t("Valve position"), WaterAmount: t("Water"),
  };

  /// A sheet with the accessory's recorded values (its Eve history) as charts, over a day, a week or four weeks.
  function showHistory(accessory) {
    const ranges = [[24, t("24 hours")], [168, t("7 days")], [672, t("4 weeks")]];
    let hours = 24;
    const charts = el("div", { class: "chart-grid" });
    const note = el("p", { class: "muted" });
    const group = el("div", { class: "group", role: "group", "aria-label": t("Time range") }, ranges.map(([value, text]) =>
      el("button", { type: "button", text, class: value === hours ? "on" : "", "aria-pressed": String(value === hours), onclick: (event) => {
        hours = value;
        for (const button of group.children) { button.classList.toggle("on", button === event.currentTarget); button.setAttribute("aria-pressed", String(button === event.currentTarget)); }
        load();
      } })));
    const close = el("button", { actionIcon: "check", type: "button", text: t("Done"), class: "primary" });
    const dialog = el("dialog", { class: "admin-dialog card wide", "aria-labelledby": "history-title" },
      el("div", { class: "page-head" }, el("div", { class: "who" }, el("h2", { id: "history-title", text: accessory.name }), el("p", { class: "muted", text: t("Recorded values, as Eve shows them") })),
        el("div", { class: "tools" }, group, HomeswiftCommon.clearFilters([], { active: () => hours !== 24, events: [[group, "click"]], reset: () => group.firstElementChild.click() }))),
      charts, note, el("div", { class: "actions" }, close));
    close.addEventListener("click", () => dialog.close());
    dialog.addEventListener("close", () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();

    async function load() {
      // Ranges chosen quickly one after the other: only the last one's answer is drawn.
      const asked = hours;
      charts.classList.add("loading");
      let found;
      try { found = await api(`/api/accessories/${encodeURIComponent(accessory.id)}/history?hours=${hours}&points=240`); }
      catch (e) { if (asked === hours) { charts.classList.remove("loading"); note.className = "error"; note.textContent = e.message; } return; }
      if (asked !== hours) return;
      charts.classList.remove("loading");
      note.className = "muted";
      note.textContent = found.note != null ? HomeswiftI18n.message(found.note) : t("Ten-minute averages, kept four weeks; each point here averages those in its span.");
      const from = new Date(found.from).getTime(), to = new Date(found.to).getTime();
      charts.replaceChildren(...found.series.map((series) => {
        const unit = historyUnits[series.unit] ?? series.unit ?? "";
        const format = (value) => `${Math.abs(value) < 10 && value % 1 ? value.toFixed(1) : Math.round(value * 10) / 10}${unit ? ` ${unit}` : ""}`;
        const points = series.points.map(([time, value]) => ({ time: new Date(time).getTime(), value }));
        const gaps = points.slice(1).map((point, index) => point.time - points[index].time).sort((a, b) => a - b);
        const step = Math.max(gaps[Math.floor(gaps.length / 2)] ?? 600000, 600000);
        const body = el("div", { class: "chart-body" });
        const card = el("div", { class: "card chart-card" },
          el("div", { class: "chart-head" }, el("div", { class: "who" }, el("strong", { text: historyLabels[series.type] ?? series.type }),
            el("div", { class: "muted", text: t("Lowest {min} · highest {max} · average {average}", { min: format(series.min.value), max: format(series.max.value), average: format(series.avg) }) })),
          el("b", { class: "chart-figure", text: format(series.last.value), title: t("Last, {date}", { date: when(series.last.at) }) })),
          body);
        HomeswiftChart.lineChart(body, { title: historyLabels[series.type] ?? series.type, series: [{ label: historyLabels[series.type] ?? series.type, tone: 1, value: (point) => point.value }],
          format, points, from, to, step });
        return card;
      }));
    }
    load();
  }

  // ---- Overview: what homeswift runs, as a radial tree: homeswift at the centre, its bridges on the first ring, their
  // plugins on the second, and each plugin's accessories as dots on the outer ring, in their branch's colour.

  const svgNamespace = "http://www.w3.org/2000/svg";
  /// An SVG element; children are nodes or strings, and null children are skipped.
  function svgNode(tag, attrs = {}, ...children) {
    const node = document.createElementNS(svgNamespace, tag);
    for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
    for (const child of children) if (child != null) node.append(typeof child === "string" ? document.createTextNode(child) : child);
    return node;
  }

  // Radii in the 640-unit square: the bridges' ring, the plugins', and the accessories' outer ring.
  const radial = { size: 880, centre: 440, top: 164, plugin: 245, group: 332, leaf: 396 };
  // An accessory's disc (its radius) and the gap kept between two discs on the outer ring.
  const disc = { radius: 11.5, gap: 14 };
  // A branch (a bridge or a built-in block with its plugins) takes one of the reference palette's eight categorical slots,
  // in fixed order; a ninth branch is grey (anti-patterns: never a generated hue).
  const branchColors = ["--viz-1", "--viz-2", "--viz-3", "--viz-4", "--viz-5", "--viz-6", "--viz-7", "--viz-8"];
  const short = (text, max) => (text.length > max ? `${text.slice(0, max - 1)}…` : text);
  const categoryName = (key) => ({ lightbulb: t("Lightbulb"), switch: t("Switch") })[key] ?? key;
  /// The icon that stands for a device's category (common.js's icons): a bulb, a switch, a lock, and so on.
  const deviceIcons = [[/bulb|light/, "bulb"], [/switch/, "switch"], [/outlet/, "outlet"], [/fan/, "fan"], [/speaker/, "speaker"], [/lock/, "lock"],
    [/thermo/, "thermo"], [/door|garage/, "door"], [/camera|doorbell/, "camera"], [/blind|window|shade|curtain|covering/, "blind"], [/sensor/, "sensor"], [/bridge/, "bridge"]];
  const deviceIcon = (category = "") => deviceIcons.find(([pattern]) => pattern.test(category.toLowerCase()))?.[1] ?? "accessory";
  /// A device's status for its tooltip: unavailable, else whether it is on, its brightness and its temperature when it reports them.
  function deviceStatus(accessory) {
    if (accessory.unavailable) return t("Unavailable");
    const characteristics = (accessory.services ?? []).flatMap((service) => service.characteristics ?? []);
    const value = (type) => characteristics.find((one) => one.type === type)?.value;
    const parts = [];
    if (typeof value("On") === "boolean") parts.push(value("On") ? t("On") : t("Off"));
    if (typeof value("Brightness") === "number") parts.push(`${value("Brightness")}%`);
    if (typeof value("CurrentTemperature") === "number") parts.push(`${Math.round(value("CurrentTemperature") * 10) / 10} °C`);
    return parts.length ? parts.join(" · ") : t("Available");
  }
  const polar = (radius, angle) => [radial.centre + radius * Math.cos(angle), radial.centre + radius * Math.sin(angle)];

  /// What the graph and its table show, from /api/status (bridges), /api/plugins (blocks and their platforms) and
  /// /api/accessories. A plugin block sits under the bridge its platform entry names; a plugin's accessories are the
  /// ones of its platform on that bridge, given to the first block that has them.
  function overviewModel(status, plugins, accessories) {
    const bridges = status.bridges ?? [];
    const main = bridges.find((bridge) => !bridge.childBridge) ?? bridges[0];
    const tops = bridges.map((bridge) => ({
      kind: bridge.childBridge ? "child" : "bridge", name: bridge.name, paired: bridge.paired, children: [], raw: bridge, count: bridge.accessories ?? 0,
      sub: tn("{n} accessory", "{n} accessories", bridge.accessories ?? 0, {}) }));
    const topByName = new Map(tops.map((top) => [top.name, top]));
    const entries = plugins?.platforms ?? [];
    const claimed = new Set();
    let pluginCount = 0, pausedCount = 0;
    for (const block of plugins?.blocks ?? []) {
      if (block.system) { tops.push({ kind: "system", name: block.name, children: [], sub: t("Built in") }); continue; }
      const entry = entries.find((one) => one.name === block.name);
      const bridgeName = entry?.bridge ?? main?.name;
      const parent = topByName.get(bridgeName);
      if (!parent) continue;
      const key = `${block.platform}|${bridgeName}`;
      const leaves = claimed.has(key) ? [] : accessories.filter((accessory) => accessory.platform === block.platform && accessory.bridge === bridgeName);
      claimed.add(key);
      const paused = Boolean(entry?.paused);
      pluginCount += 1;
      pausedCount += paused ? 1 : 0;
      leaves.sort((a, b) => a.category.localeCompare(b.category) || a.name.localeCompare(b.name));
      parent.children.push({ kind: "plugin", name: block.name, platform: block.platform, bridgeName, paused, leaves,
        sub: paused ? t("Paused") : leaves.length ? tn("{n} accessory", "{n} accessories", leaves.length, {}) : t("No accessories") });
    }
    // A plugin's accessories grouped by device type: one group per run of the same category (the leaves are sorted by it).
    const groupsOf = (plugin) => {
      const groups = [];
      for (const leaf of plugin.leaves) {
        let group = groups.at(-1);
        if (!group || group.category !== leaf.category) {
          group = { kind: "group", category: leaf.category, name: categoryName(leaf.category), icon: deviceIcon(leaf.category), plugin, leaves: [] };
          groups.push(group);
        }
        group.leaves.push(leaf);
      }
      for (const group of groups) group.sub = tn("{n} accessory", "{n} accessories", group.leaves.length, {});
      return groups;
    };
    // Angles, in slots: a group takes one slot per accessory, a half-slot separates the groups of a plugin, a bridge sits at
    // the middle of its plugins, and a slot's gap separates the branches. Then the slots become angles from the top, clockwise.
    let slot = 0;
    for (const top of tops) {
      if (!top.children.length) { top.slot = slot + 0.5; slot += 1; }
      for (const plugin of top.children) {
        plugin.groups = groupsOf(plugin);
        const start = slot;
        if (!plugin.groups.length) slot += 1;
        for (const group of plugin.groups) {
          group.first = slot;
          group.slot = slot + group.leaves.length / 2;
          slot += group.leaves.length + 0.5;
        }
        if (plugin.groups.length) slot -= 0.5;
        plugin.slot = plugin.groups.length ? (start + slot) / 2 : start + 0.5;
      }
      if (top.children.length) top.slot = (top.children[0].slot + top.children.at(-1).slot) / 2;
      slot += 1;
    }
    const total = Math.max(slot, 1);
    // The rings grow with the accessories, so that neighbouring discs on the outer ring keep their gap.
    const placed = tops.reduce((count, top) => count + top.children.reduce((sum, plugin) => sum + plugin.leaves.length, 0), 0);
    radial.leaf = Math.max(396, (placed * (2 * disc.radius + disc.gap)) / (2 * Math.PI));
    radial.plugin = radial.leaf * 0.62;
    radial.group = radial.leaf * 0.84;
    radial.top = radial.leaf * 0.42;
    radial.size = 2 * (radial.leaf + 32);
    radial.centre = radial.size / 2;
    const angleOf = (value) => -Math.PI / 2 + (value / total) * Math.PI * 2;
    tops.forEach((top, index) => {
      top.color = index < branchColors.length ? `var(${branchColors[index]})` : "var(--muted)";
      top.angle = angleOf(top.slot);
      top.radius = radial.top;
      for (const plugin of top.children) {
        plugin.color = top.color;
        plugin.angle = angleOf(plugin.slot);
        plugin.radius = radial.plugin;
        for (const group of plugin.groups) {
          group.color = top.color;
          group.angle = angleOf(group.slot);
          group.radius = radial.group;
          group.leaves.forEach((leaf, index) => { leaf.color = top.color; leaf.angle = angleOf(group.first + index + 0.5); leaf.radius = radial.leaf; });
        }
      }
    });
    return { tops, status, rootSub: t("Version {version}", { version: status.version ?? "" }),
      counts: { bridges: bridges.length, accessories: accessories.length, unavailable: accessories.filter((one) => one.unavailable).length, plugins: pluginCount, paused: pausedCount } };
  }

  async function overviewPage(main) {
    const [status, plugins, accessories] = await Promise.all([api("/api/status"), api("/api/plugins").catch(() => null), api("/api/accessories").catch(() => [])]);
    const model = overviewModel(status, plugins, accessories);
    const { counts } = model;
    const kpi = (value, label, tone = "") => el("div", { class: `card kpi ${tone}` }, el("b", { text: String(value) }), el("span", { class: "muted", text: label }));
    app().show(main,
      app().pageHead(t("Settings"), t("What homeswift runs: its bridges, their plugins and the accessories each one publishes.")),
      subnav(""),
      el("div", { class: "kpis" },
        kpi(counts.bridges, t("Bridges")), kpi(counts.plugins, t("Plugins")), kpi(counts.accessories, t("Accessories")),
        kpi(counts.unavailable, t("Unavailable"), counts.unavailable ? "warn" : ""), kpi(counts.paused, t("Paused"))),
      overviewCard(model));
  }

  /// An accessory's detail: its icon, name and status, its facts and every reading it reports (its own characteristics).
  const characteristicNames = { On: () => t("On"), Brightness: () => t("Brightness"), Hue: () => t("Hue"), Saturation: () => t("Saturation"),
    ColorTemperature: () => t("Color Temperature"), CurrentTemperature: () => t("Current Temperature"), CurrentRelativeHumidity: () => t("Humidity"), BatteryLevel: () => t("Battery") };
  // HomeKit names come spaced ("Configured Name") or not: compared without the spaces.
  const bareType = (type) => String(type).replace(/\s+/g, "");
  const characteristicName = (type) => characteristicNames[bareType(type)]?.() ?? type;
  const units = { percentage: "%", celsius: "°C", arcdegrees: "°", lux: " lx" };
  function characteristicValue(one) {
    if (typeof one.value === "boolean") return one.value ? t("On") : t("Off");
    return typeof one.value === "number" ? `${Math.round(one.value * 10) / 10}${units[one.unit] ?? ""}` : String(one.value);
  }
  /// What a detail card shows: a name and icon (or the app's icon), a status, facts, and readings.
  function accessoryDetails(accessory) {
    const facts = [[t("Manufacturer"), accessory.manufacturer], [t("Model"), accessory.model], [t("Platform"), accessory.platformName ?? accessory.platform],
      [t("Bridge"), accessory.bridge], [t("Type"), categoryName(accessory.category)]];
    const administrative = new Set(["Name", "Identify", "Manufacturer", "Model", "SerialNumber", "FirmwareRevision", "HardwareRevision", "ConfiguredName"]);
    // A device with several services (a switch's scenes, say) names each reading after its service.
    const services = accessory.services ?? [];
    const readings = services.flatMap((service) => {
      const characteristics = service.characteristics ?? [];
      const serviceName = characteristics.find((one) => bareType(one.type) === "ConfiguredName")?.value;
      return characteristics.filter((one) => !administrative.has(bareType(one.type)) && one.value !== undefined && one.value !== null && typeof one.value !== "object")
        .map((one) => [services.length > 1 && serviceName ? `${serviceName} · ${characteristicName(one.type)}` : characteristicName(one.type), characteristicValue(one)]);
    });
    return { name: accessory.name, icon: deviceIcon(accessory.category), status: deviceStatus(accessory), warn: Boolean(accessory.unavailable), facts, readings };
  }
  function bridgeDetails(top) {
    const bridge = top.raw;
    const type = top.kind === "system" ? t("Built in") : t(top.kind === "child" ? "Child bridge" : "Bridge");
    return { name: top.name, icon: top.kind === "system" ? "system" : "bridge", warn: top.paired === false,
      status: top.kind === "system" ? t("Built in") : top.paired ? t("Paired · {count}", { count: bridge.controllers ?? 0 }) : t("Not paired"),
      facts: [[t("Type"), type], [t("Accessories"), top.count], [t("Port"), bridge?.port], [t("Device ID"), bridge?.deviceId], [t("Platforms"), bridge?.platforms?.join(", ")]] };
  }
  function pluginDetails(plugin) {
    const categories = new Map();
    for (const leaf of plugin.leaves) categories.set(leaf.category, (categories.get(leaf.category) ?? 0) + 1);
    return { name: plugin.name, icon: /wingman/i.test(plugin.name) ? "wingman" : "plugin", status: plugin.sub, warn: false,
      facts: [[t("Platform"), plugin.platform], [t("Bridge"), plugin.bridgeName], [t("State"), plugin.paused ? t("Paused") : t("Running")],
        [t("Accessories"), plugin.leaves.length], [t("Unavailable"), plugin.leaves.filter((one) => one.unavailable).length],
        [t("Categories"), [...categories].map(([key, count]) => `${categoryName(key)} ${count}`).join(", ")]] };
  }
  function homeswiftDetails(model) {
    const system = model.status.system ?? {};
    return { name: "Homeswift", image: "/icon.svg", warn: false, status: model.rootSub,
      facts: [[t("Version"), model.status.version], [t("Bridges"), model.counts.bridges], [t("Plugins"), model.counts.plugins], [t("Accessories"), model.counts.accessories],
        [t("Paused"), model.counts.paused], [t("Host"), system.hostname], [t("Operating system"), system.os], [t("Processors"), system.cpus],
        [t("Memory"), system.memoryBytes ? `${Math.round(system.memoryBytes / 2 ** 30)} GB` : ""], [t("Update available"), model.status.update?.available ? t("Yes") : t("No")]] };
  }
  /// A detail card's content: the head with the icon and close, then its facts and readings.
  function detailNodes(data, close) {
    const glyph = data.image ? el("img", { src: data.image, alt: "", width: 28, height: 28 }) : HomeswiftCommon.icon(data.icon);
    const shown = (facts) => facts.filter(([, value]) => value !== undefined && value !== null && value !== "");
    return [
      el("div", { class: "detail-head" }, el("span", { class: "detail-glyph" }, glyph),
        el("div", { class: "who" }, el("strong", { text: data.name }), el("div", { class: `detail-status${data.warn ? " warn" : ""}`, text: data.status })), close),
      el("dl", { class: "detail-facts" }, ...shown(data.facts).flatMap(([label, value]) => [el("dt", { text: label }), el("dd", { text: String(value) })])),
      data.readings?.length ? el("dl", { class: "detail-readings" }, ...data.readings.flatMap(([label, value]) => [el("dt", { text: label }), el("dd", { text: value })])) : null,
    ];
  }

  /// A device-type group: its plugin, its accessories and how many are unavailable, then each accessory with its status.
  function groupDetails(group) {
    const unavailable = group.leaves.filter((one) => one.unavailable).length;
    return { name: group.name, icon: group.icon, status: group.sub, warn: unavailable > 0,
      facts: [[t("Plugin"), group.plugin.name], [t("Bridge"), group.plugin.bridgeName], [t("Accessories"), group.leaves.length], [t("Unavailable"), unavailable]],
      readings: group.leaves.map((one) => [one.name, deviceStatus(one)]) };
  }

  /// The card: the radial graph with zoom (a click on a bridge or plugin, Ctrl-scroll or a trackpad pinch, a touch pinch,
  /// drag to pan, the buttons), a tooltip on hover and focus, the legend and a table of the same rows.
  function overviewCard(model) {
    if (!model.tops.length) return el("section", { class: "card overview-card" }, el("p", { class: "muted", text: t("Nothing runs here yet.") }));
    const { svg, layer, targets, details } = drawGraph(model);
    const tip = el("div", { class: "overview-tip", role: "tooltip", hidden: true });
    const detail = el("div", { class: "overview-detail", role: "dialog", hidden: true });
    const frame = el("div", { class: "overview-frame" }, svg, tip, detail);
    let openNode = null;
    const closeDetail = () => { detail.hidden = true; openNode = null; };
    const openDetail = (node, anchored = true) => {
      const data = details.get(node)();
      const close = el("button", { type: "button", class: "detail-close", actionIcon: "close", "aria-label": t("Close"), title: t("Close"), onclick: closeDetail });
      detail.replaceChildren(...detailNodes(data, close).filter(Boolean));
      detail.setAttribute("aria-label", data.name);
      detail.style.setProperty("--branch", node.style.getPropertyValue("--branch") || "var(--accent)");
      tip.hidden = true;
      detail.hidden = false;
      openNode = node;
      const frameBox = frame.getBoundingClientRect();
      if (matchMedia("(max-width: 640px)").matches) {
        // A phone: the card is docked under the graph at full width (CSS), so it is shown there, not beside the node.
        detail.scrollIntoView({ block: "nearest", behavior: "smooth" });
      } else if (!anchored) {
        detail.style.left = `${Math.max(0, frameBox.width - detail.offsetWidth - 8)}px`;
        detail.style.top = "8px";
      } else {
        // Beside the node, on the side with room, and inside the frame.
        const box = node.getBoundingClientRect();
        const right = box.right - frameBox.left + 12;
        const left = right + detail.offsetWidth <= frameBox.width ? right : box.left - frameBox.left - detail.offsetWidth - 12;
        detail.style.left = `${Math.max(0, left)}px`;
        detail.style.top = `${Math.max(0, Math.min(box.top - frameBox.top, frameBox.height - detail.offsetHeight))}px`;
      }
      close.focus({ preventScroll: true });
    };
    detail.addEventListener("keydown", (event) => { if (event.key === "Escape") { closeDetail(); svg.focus({ preventScroll: true }); } });
    const zoom = { k: 1, x: 0, y: 0 };
    const maxZoom = 6;
    const clamp = () => {
      zoom.k = Math.min(maxZoom, Math.max(1, zoom.k));
      zoom.x = Math.min(0, Math.max(radial.size * (1 - zoom.k), zoom.x));
      zoom.y = Math.min(0, Math.max(radial.size * (1 - zoom.k), zoom.y));
    };
    const apply = () => {
      layer.setAttribute("transform", `translate(${zoom.x} ${zoom.y}) scale(${zoom.k})`);
      svg.classList.toggle("deep", zoom.k >= 1.6);
    };
    // The view that scales by `factor` around the world point `at` (a screen point in the graph's units).
    const viewAt = (factor, at) => {
      const k = Math.min(maxZoom, Math.max(1, zoom.k * factor));
      const wx = (at.x - zoom.x) / zoom.k, wy = (at.y - zoom.y) / zoom.k;
      const view = { k, x: at.x - k * wx, y: at.y - k * wy };
      const clamped = { k: Math.min(maxZoom, Math.max(1, k)) };
      clamped.x = Math.min(0, Math.max(radial.size * (1 - clamped.k), view.x));
      clamped.y = Math.min(0, Math.max(radial.size * (1 - clamped.k), view.y));
      return clamped;
    };
    const centre = { x: radial.size / 2, y: radial.size / 2 };
    let animation = 0;
    const animateTo = (view, ms = 340) => {
      cancelAnimationFrame(animation);
      const from = { ...zoom }, started = performance.now();
      const step = (now) => {
        const p = Math.min(1, (now - started) / ms), e = 1 - (1 - p) ** 3;
        zoom.k = from.k + (view.k - from.k) * e;
        zoom.x = from.x + (view.x - from.x) * e;
        zoom.y = from.y + (view.y - from.y) * e;
        clamp(); apply();
        if (p < 1) animation = requestAnimationFrame(step);
      };
      animation = requestAnimationFrame(step);
    };
    // A bridge or plugin: its place on the rings, zoomed so that its branch fills the view.
    let focused = null;
    const focusOn = (node) => {
      const target = targets.get(node);
      if (focused === node) { focused = null; animateTo({ k: 1, x: 0, y: 0 }); return; }
      focused = node;
      const [wx, wy] = polar(target.radius, target.angle);
      animateTo({ k: target.k, x: centre.x - target.k * wx, y: centre.y - target.k * wy });
    };
    const screenToGraph = (clientX, clientY) => {
      const point = svg.createSVGPoint();
      point.x = clientX;
      point.y = clientY;
      const mapped = point.matrixTransform(svg.getScreenCTM().inverse());
      return { x: mapped.x, y: mapped.y };
    };
    svg.addEventListener("wheel", (event) => {
      if (!event.ctrlKey && !event.metaKey && zoom.k === 1) return; // a plain scroll of the page at rest
      event.preventDefault();
      if (!event.ctrlKey && !event.metaKey) {
        const scale = radial.size / svg.getBoundingClientRect().width;
        zoom.x -= event.deltaX * scale; zoom.y -= event.deltaY * scale;
        clamp(); apply();
        return;
      }
      cancelAnimationFrame(animation);
      Object.assign(zoom, viewAt(Math.exp(-event.deltaY * 0.004), screenToGraph(event.clientX, event.clientY)));
      apply();
    }, { passive: false });

    // Pointers: one drags (a drag past a few pixels is no click), two pinch around their midpoint.
    const pointers = new Map();
    let drag = null, pinch = null, dragged = false;
    svg.addEventListener("pointerdown", (event) => {
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      dragged = false;
      cancelAnimationFrame(animation);
      if (pointers.size === 2) {
        const [a, b] = [...pointers.values()];
        pinch = { distance: Math.hypot(a.x - b.x, a.y - b.y), k: zoom.k };
        drag = null;
      } else {
        drag = { x: event.clientX, y: event.clientY, zoomX: zoom.x, zoomY: zoom.y };
      }
    });
    window.addEventListener("pointermove", (event) => {
      if (!pointers.has(event.pointerId)) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (pointers.size === 2 && pinch) {
        const [a, b] = [...pointers.values()];
        const distance = Math.hypot(a.x - b.x, a.y - b.y);
        const midpoint = screenToGraph((a.x + b.x) / 2, (a.y + b.y) / 2);
        const target = pinch.k * (distance / pinch.distance);
        Object.assign(zoom, viewAt(target / zoom.k, midpoint));
        dragged = true;
        apply();
        return;
      }
      if (drag && pointers.size === 1) {
        const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
        if (!dragged && Math.hypot(dx, dy) < 5) return;
        dragged = true;
        if (zoom.k > 1) {
          const scale = radial.size / svg.getBoundingClientRect().width;
          zoom.x = drag.zoomX + dx * scale; zoom.y = drag.zoomY + dy * scale;
          clamp(); apply();
        }
      }
    });
    const release = (event) => {
      pointers.delete(event.pointerId);
      if (pointers.size < 2) pinch = null;
      if (pointers.size === 0) drag = null;
    };
    window.addEventListener("pointerup", release);
    window.addEventListener("pointercancel", release);

    svg.addEventListener("click", (event) => {
      if (dragged) return; // the end of a drag is not a click
      const node = event.target.closest?.("[data-detail]");
      if (node) {
        if (openNode === node) closeDetail(); else openDetail(node, !node.hasAttribute("data-focus"));
        if (node.hasAttribute("data-focus")) focusOn(node);
        return;
      }
      closeDetail();
      const target = event.target.closest?.("[data-focus]");
      if (target) { focusOn(target); return; }
      if (zoom.k > 1 && !event.target.closest?.(".pill, .plugin-node, .root")) { focused = null; animateTo({ k: 1, x: 0, y: 0 }); }
    });
    svg.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && zoom.k > 1) { focused = null; animateTo({ k: 1, x: 0, y: 0 }); return; }
      if ((event.key === "Enter" || event.key === " ") && (event.target.dataset?.focus !== undefined || event.target.dataset?.detail !== undefined)) { event.preventDefault(); event.target.dispatchEvent(new MouseEvent("click", { bubbles: true })); }
    });

    const show = (target) => {
      const box = target.getBoundingClientRect();
      tip.textContent = target.dataset.tip;
      tip.style.left = `${box.left + box.width / 2}px`;
      tip.style.top = `${box.top}px`;
      tip.hidden = false;
    };
    const hide = () => { tip.hidden = true; };
    svg.addEventListener("pointerover", (event) => { const target = event.target.closest?.("[data-tip]"); if (target) show(target); });
    svg.addEventListener("pointerout", (event) => { if (!event.relatedTarget?.closest?.("[data-tip]")) hide(); });
    svg.addEventListener("focusin", (event) => { if (event.target.dataset?.tip) show(event.target); });
    svg.addEventListener("focusout", hide);

    const controls = el("div", { class: "overview-zoom" },
      el("button", { type: "button", actionIcon: "plus", text: t("Zoom in"), onclick: () => animateTo(viewAt(1.6, centre)) }),
      el("button", { type: "button", actionIcon: "minus", text: t("Zoom out"), onclick: () => animateTo(viewAt(1 / 1.6, centre)) }),
      el("button", { type: "button", actionIcon: "restore", text: t("Reset view"), onclick: () => animateTo({ k: 1, x: 0, y: 0 }) }));
    const legend = el("ul", { class: "overview-legend" },
      ...model.tops.map((top) => el("li", {}, el("i", { class: "legend-mark", style: `--mark: ${top.color}` }), el("span", { text: top.name }))),
      el("li", {}, el("i", { class: "legend-mark hollow" }), el("span", { text: t("Unavailable") })),
      el("li", {}, el("i", { class: "legend-mark status paused" }), el("span", { text: t("Paused") })),
      el("li", {}, el("i", { class: "legend-mark status warn" }), el("span", { text: t("Not paired") })));
    return el("section", { class: "card overview-card" },
      el("div", { class: "chart-head" }, el("div", { class: "who" }, el("strong", { text: t("Graph of the bridges, plugins and accessories") }),
        el("div", { class: "muted", text: t("Pinch or Ctrl-scroll to zoom. Click a bridge to see its plugins and accessories.") }))),
      frame, controls, legend,
      el("p", { class: "muted note", text: t("Each dot is an accessory; a hollow one is unavailable.") }),
      el("details", { class: "overview-more" }, el("summary", {}, HomeswiftCommon.icon("grid"), el("span", { text: t("Show as a table") })), overviewTable(model)));
  }

  /// The radial graph: the root at the centre, each bridge a label pill on the first ring (a tangent to it), each plugin a
  /// dot on the second with its label shown when zoomed in, each accessory a dot on the outer ring. Returns the SVG, the
  /// layer that zooms, and the zoom target of each focusable element.
  function drawGraph(model) {
    const root = { radius: 0, angle: 0 };
    const edges = [], labels = [], dots = [], pills = [], plugins = [];
    const targets = new Map();
    const details = new Map();
    // A curve from the parent along its own angle to the child along the child's, bowing through the middle ring.
    const link = (from, to, classes = "", color = "") => {
      const mid = (from.radius + to.radius) / 2;
      const [x1, y1] = polar(from.radius, from.angle), [x2, y2] = polar(to.radius, to.angle);
      const [c1x, c1y] = polar(mid, from.angle), [c2x, c2y] = polar(mid, to.angle);
      return svgNode("path", { class: `edge ${classes}`, style: color ? `--branch: ${color}` : null, d: `M${x1} ${y1} C${c1x} ${c1y} ${c2x} ${c2y} ${x2} ${y2}` });
    };
    const charWidth = 8, pillHeight = 34;
    // A bridge's pill, upright wherever it sits on the ring: its icon, then its name.
    const pill = (top, classes, tip) => {
      const [x, y] = polar(top.radius, top.angle);
      const width = Math.min(230, top.name.length * charWidth + 50);
      const glyph = HomeswiftCommon.icon(top.kind === "system" ? "system" : "bridge");
      for (const [key, value] of [["x", -width / 2 + 8], ["y", -11], ["width", 22], ["height", 22]]) glyph.setAttribute(key, value);
      const group = svgNode("g", { class: `pill ${classes}`, transform: `translate(${x} ${y})`, style: `--branch: ${top.color}`, "data-tip": tip, "data-focus": "", "data-detail": "", tabindex: 0, "aria-label": tip },
        svgNode("rect", { class: "pill-box", x: -width / 2, y: -pillHeight / 2, width, height: pillHeight, rx: pillHeight / 2 }),
        glyph,
        svgNode("text", { class: "pill-name", x: 10, y: 0, "dominant-baseline": "central", "text-anchor": "middle" }, short(top.name, 22)));
      targets.set(group, { radius: (radial.top + radial.plugin) / 2, angle: top.angle, k: 1.8 });
      details.set(group, () => bridgeDetails(top));
      return group;
    };
    // A plugin's dot, with its icon: Wingman's own, else the plugin's.
    const plugin = (node, classes, tip) => {
      const [x, y] = polar(node.radius, node.angle);
      const glyph = HomeswiftCommon.icon(/wingman/i.test(node.name) ? "wingman" : "plugin");
      for (const [key, value] of [["x", -8], ["y", -8], ["width", 16], ["height", 16]]) glyph.setAttribute(key, value);
      const group = svgNode("g", { class: `plugin-node ${classes}`, transform: `translate(${x} ${y})`, style: `--branch: ${node.color}`, "data-tip": tip, "data-focus": "", "data-detail": "", tabindex: 0, "aria-label": tip },
        svgNode("circle", { class: "plugin-dot", r: 12 }), glyph);
      targets.set(group, { radius: (radial.plugin + radial.leaf) / 2, angle: node.angle, k: 2.6 });
      details.set(group, () => pluginDetails(node));
      return group;
    };
    // A device-type node: its icon, its name and count in the tooltip; a click shows its accessories.
    const groupNode = (group) => {
      const [x, y] = polar(group.radius, group.angle);
      const glyph = HomeswiftCommon.icon(group.icon);
      for (const [key, value] of [["x", -8], ["y", -8], ["width", 16], ["height", 16]]) glyph.setAttribute(key, value);
      const tip = `${group.name} · ${group.sub}`;
      const element = svgNode("g", { class: "group-node", transform: `translate(${x} ${y})`, style: `--branch: ${group.color}`, "data-tip": tip, "data-detail": "", "data-focus": "", tabindex: 0, "aria-label": tip },
        svgNode("circle", { class: "group-dot", r: 13 }), glyph);
      targets.set(element, { radius: (radial.group + radial.leaf) / 2, angle: group.angle, k: 2.8 });
      details.set(element, () => groupDetails(group));
      return element;
    };
    for (const top of model.tops) {
      edges.push(link(root, top, "trunk", top.color));
      pills.push(pill(top, `${top.kind === "system" ? "built-in" : "branch"}${top.paired === false ? " unpaired" : ""}`, `${top.name} · ${top.sub}`));
      for (const branch of top.children) {
        edges.push(link(top, branch, `branch${branch.paused ? " paused" : ""}`, top.color));
        plugins.push(plugin(branch, `${branch.paused ? "paused" : ""}`, `${branch.name} · ${branch.sub}`));
        const [lx, ly] = polar(radial.plugin, branch.angle);
        // Upright labels, inward from the dot: the groups and accessories are outside it.
        const right = Math.cos(branch.angle) >= 0;
        labels.push(svgNode("text", { class: "plugin-label", x: lx + (right ? -16 : 16), y: ly, "dominant-baseline": "central", "text-anchor": right ? "end" : "start" }, short(branch.name, 24)));
        for (const group of branch.groups) {
          edges.push(link(branch, group, "branch", top.color));
          plugins.push(groupNode(group));
          const [gx, gy] = polar(radial.group, group.angle);
          const groupRight = Math.cos(group.angle) >= 0;
          labels.push(svgNode("text", { class: "group-label", x: gx + (groupRight ? -18 : 18), y: gy, "dominant-baseline": "central", "text-anchor": groupRight ? "end" : "start" }, short(group.name, 24)));
        for (const accessory of group.leaves) {
          edges.push(link(group, accessory, "leaf", top.color));
          const [x, y] = polar(accessory.radius, accessory.angle);
          const label = `${accessory.name} · ${categoryName(accessory.category)} · ${deviceStatus(accessory)}`;
          const glyph = HomeswiftCommon.icon(deviceIcon(accessory.category));
          for (const [key, value] of [["x", -8], ["y", -8], ["width", 16], ["height", 16]]) glyph.setAttribute(key, value);
          const dot = svgNode("g", { class: `dot${accessory.unavailable ? " unavailable" : ""}`, transform: `translate(${x} ${y})`, style: `--branch: ${top.color}`, "data-tip": label, "data-detail": "", tabindex: 0, "aria-label": label },
            svgNode("circle", { class: "dot-disc", r: 11.5 }), glyph);
          details.set(dot, () => accessoryDetails(accessory));
          dots.push(dot);
        }
        }
      }
    }
    const rx = radial.centre, ry = radial.centre;
    const centre = svgNode("g", { class: "root", "data-tip": `Homeswift · ${model.rootSub}`, "data-detail": "", tabindex: 0, "aria-label": `Homeswift · ${model.rootSub}` },
      svgNode("image", { class: "root-icon", href: "/icon.svg", x: rx - 48, y: ry - 48, width: 96, height: 96 }),
      svgNode("text", { class: "root-name", x: rx, y: ry + 66, "text-anchor": "middle" }, "Homeswift"));
    details.set(centre, () => homeswiftDetails(model));
    const layer = svgNode("g", { class: "zoom-layer" }, ...edges, ...dots, ...plugins, ...labels, ...pills, centre);
    const svg = svgNode("svg", { class: "overview-graph", viewBox: `0 0 ${radial.size} ${radial.size}`, role: "group", "aria-label": t("Graph of the bridges, plugins and accessories") }, layer);
    return { svg, layer, targets, details };
  }

  /// The same rows as the graph, for a screen reader or a search: bridges, then their plugins.
  function overviewTable(model) {
    const rows = model.tops.flatMap((top) => [
      el("tr", { class: "overview-bridge" }, el("th", { scope: "row", text: top.name }),
        el("td", { text: top.kind === "system" ? t("Built in") : t(top.kind === "child" ? "Child bridge" : "Bridge") }),
        el("td", { text: top.kind === "system" ? "" : top.sub }),
        el("td", { text: top.kind === "system" ? "" : top.paired ? t("Paired") : t("Not paired") })),
      ...top.children.map((plugin) => el("tr", { class: "overview-plugin" }, el("th", { scope: "row", text: plugin.name }),
        el("td", { text: t("Plugin") }), el("td", { text: plugin.sub }), el("td", { text: plugin.paused ? t("Paused") : "" }))),
    ]);
    return el("div", { class: "overview-table-wrap" }, el("table", { class: "overview-table" },
      el("thead", {}, el("tr", {}, el("th", { scope: "col", text: t("Name") }), el("th", { scope: "col", text: t("Type") }), el("th", { scope: "col", text: t("Accessories") }), el("th", { scope: "col", text: t("State") }))),
      el("tbody", {}, rows)));
  }

  window.HomeswiftAdmin = { view, history: showHistory, confirmAction };
})();
