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

  const pages = [["", t("Bridge"), "bridge"], ["child-bridges", t("Child bridges"), "child"], ["backups", t("Backups"), "archive"], ["audit", t("Audit log"), "shield"], ["assistant", t("Assistant"), "sparkle"]];

  const dateTime = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false });
  const fullDate = new Intl.DateTimeFormat(locale, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  const when = (iso) => (iso ? dateTime.format(new Date(iso)) : "–");
  const tenths = new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  const size = (bytes) => bytes >= 1048576 ? `${tenths.format(bytes / 1048576)} MB` : bytes >= 1024 ? `${Math.round(bytes / 1024).toLocaleString(locale)} KB` : `${bytes.toLocaleString(locale)} B`;

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
      const cancel = el("button", { text: t("Cancel"), value: "cancel", type: "button" });
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
  async function busy(button, work, report = (e) => alert(e.message)) {
    if (button) { button.disabled = true; button.classList.add("busy"); }
    try { return await work(); } catch (e) { report(e); } finally { if (button) { button.disabled = false; button.classList.remove("busy"); } }
  }

  const sectionHead = (title, note, ...tools) => el("div", { class: "section-head" }, el("h2", { text: title }), note ? el("span", { class: "muted", text: note }) : null, ...tools);

  async function view(main, [page = ""] = []) {
    const draw = { "": bridgePage, "child-bridges": childBridgesPage, backups: backupsPage, audit: auditPage, assistant: (main) => app().assistantPage(main, subnav("assistant")) }[page];
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
      subnav(""),
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
    const save = el("button", { class: "primary", type: "submit", text: t("Save and restart") });
    const read = () => Object.fromEntries(Object.entries(fields).map(([key, control]) => {
      const value = control.value.trim();
      return [key, value === "" ? null : key === "port" ? Number(value) : value];
    }));
    const initial = JSON.stringify(read());
    const form = el("form", { class: "card form-card", onsubmit: async (event) => {
      event.preventDefault();
      const next = read();
      if (JSON.stringify(next) === initial) { message.className = "status-line muted"; message.textContent = t("Nothing changed."); return; }
      if (!(await confirmAction({ title: t("Restart homeswift with these settings?"), danger: false, confirmLabel: t("Save and restart"),
        text: [t("The bridge block is the bridge's HomeKit identity: homeswift restarts to apply it, and every connection drops for a few seconds."),
          next.pin !== (bridge.pin ?? null) ? t("A new setup code applies to new pairings only: the Home app keeps the bridge.") : ""] }))) return;
      await busy(save, async () => {
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
        field(t("Port"), fields.port, t("The HomeKit server's port; empty picks a free one and keeps it.")),
        field(t("Setup code"), fields.pin, t("The code the Home app asks for, as XXX-XX-XXX. It is never logged.")),
        field(t("Manufacturer"), fields.manufacturer), field(t("Model"), fields.model), field(t("Firmware revision"), fields.firmwareRevision)),
      el("p", { class: "help", text: t("The device ID stays: a new one is a new bridge to the Home app. To pair again from scratch, reset the bridge's pairings below.") }),
      el("div", { class: "actions" }, save), message);
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
    return el("section", {},
      sectionHead(t("Cached accessories"), tn("{count} in {n} cache file", "{count} in {n} cache files", new Set(list.map((c) => c.cacheFile)).size, { count: list.length }), reset),
      list.length ? el("div", { class: "card rows" }, list.map(row)) : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("accessory")), el("p", { class: "muted", text: t("No cached accessory.") })));
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
        uiBlock ? el("a", { class: "button", href: `/plugins/${uiBlock.slug}`, text: t("Open its settings") }) : null));
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
            el("button", { text: t("Configure"), onclick: () => editChildBridge(block) }))))),
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
    const cancel = el("button", { type: "button", text: t("Cancel"), onclick: () => dialog.close() });
    const save = el("button", { type: "submit", class: "primary", text: t("Save") });
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
    const now = el("button", { class: "primary", text: t("Back up now"), onclick: (event) => busy(event.currentTarget, async () => {
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
        now, el("a", { class: "button", href: "/api/backups/download", download: "", text: t("Download a backup") })),
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
        el("button", { class: "link", text: t("Compare"), onclick: compare }),
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
      const paint = () => control.replaceChildren(el("span", { text: choices.find(([v]) => v === control.value)?.[1] ?? label }), el("span", { text: "⌄", "aria-hidden": "true" }));
      control.addEventListener("click", () => HomeswiftCommon.menu(control, choices.map(([v, text]) => ({ label: text, checked: control.value === v, onSelect: () => { control.value = v; paint(); control.dispatchEvent(new Event("change")); } }))));
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
      let found;
      try { found = await api(`/api/audit?${query}`); } catch (e) { if (own === loads) count.textContent = e.message; return; }
      if (own !== loads) return;
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
    for (const choice of [outcome, since]) choice.addEventListener("change", load);
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
          el("button", { class: "link", text: t("Reset filters"), onclick: () => { clearTimeout(typing); tool.value = ""; client.value = ""; location.href = "/settings/audit?since=7d"; } }))),
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
    const close = el("button", { type: "button", text: t("Done"), class: "primary" });
    const dialog = el("dialog", { class: "admin-dialog card wide", "aria-labelledby": "history-title" },
      el("div", { class: "page-head" }, el("div", { class: "who" }, el("h2", { id: "history-title", text: accessory.name }), el("p", { class: "muted", text: t("Recorded values, as Eve shows them") })),
        el("div", { class: "tools" }, group)),
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

  window.HomeswiftAdmin = { view, history: showHistory, confirmAction };
})();
