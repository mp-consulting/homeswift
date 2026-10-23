// The Settings pages, after the Homebridge UI's settings, child bridges, config editor backups, restart and power
// options: the bridge block and this machine's network, HomeKit pairings, cached accessories, child bridges,
// whole-instance and config.json backups, the schedules, and the audit log; and an accessory's recorded history.
// app.js routes /settings[/<page>] here and lends its helpers (HomeswiftApp) when a view is drawn.
(() => {
  "use strict";

  const { $, el, tile, fact, menuButton, withSlugs, jsonDiff } = HomeswiftCommon;
  const app = () => window.HomeswiftApp;
  const api = (...args) => app().api(...args);

  const pages = [["", "Bridge", "bridge"], ["child-bridges", "Child bridges", "child"], ["backups", "Backups", "archive"], ["audit", "Audit log", "shield"], ["assistant", "Assistant", "sparkle"]];

  const dateTime = new Intl.DateTimeFormat([], { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false });
  const fullDate = new Intl.DateTimeFormat([], { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  const when = (iso) => (iso ? dateTime.format(new Date(iso)) : "–");
  const size = (bytes) => bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : bytes >= 1024 ? `${Math.round(bytes / 1024)} KB` : `${bytes} B`;

  /// The pages of Settings as a row of links, the current one lit.
  function subnav(current) {
    return el("nav", { class: "group subnav", "aria-label": "Settings pages" }, pages.map(([path, text]) =>
      el("a", { href: `/settings${path ? `/${path}` : ""}`, text, class: path === current ? "on" : "", "aria-current": path === current ? "page" : null })));
  }

  /// A modal question for what cannot be undone: `typed`, when given, must be typed before the button works.
  /// Resolves true when confirmed.
  function confirmAction({ title, text, confirmLabel = "Continue", typed = null, danger = true }) {
    return new Promise((resolve) => {
      const input = typed ? el("input", { type: "text", autocomplete: "off", spellcheck: false, "aria-label": `Type ${typed} to confirm` }) : null;
      const ok = el("button", { class: danger ? "danger" : "primary", text: confirmLabel, disabled: Boolean(typed), value: "ok" });
      const cancel = el("button", { text: "Cancel", value: "cancel", type: "button" });
      const dialog = el("dialog", { class: "admin-dialog card", "aria-labelledby": "confirm-title" },
        el("form", { method: "dialog" },
          el("h2", { id: "confirm-title", text: title }),
          ...[text].flat().filter(Boolean).map((paragraph) => el("p", { text: paragraph })),
          input ? el("label", { class: "field" }, el("span", { class: "field-title" }, "Type ", el("strong", { class: "mono", text: typed }), " to confirm"), input) : null,
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
    if (!draw) { app().show(main, app().pageHead("Settings", "No such page."), subnav(null)); return; }
    await draw(main);
  }

  // ---- Bridge: its block, the network, pairings, caches, schedules -----------------------------------------

  async function bridgePage(main) {
    const [settings, pairings, caches, plugins] = await Promise.all([
      api("/api/settings/bridge"), api("/api/pairings"), api("/api/cached-accessories"), api("/api/plugins").catch(() => null)]);
    const bridge = settings.bridge || {};
    const uiBlock = plugins?.blocks.find((block) => block.platform === "HomeswiftUI");
    app().show(main,
      app().pageHead("Settings", "The bridge, its pairings and cached accessories, child bridges, backups and the audit log."),
      subnav(""),
      bridgeForm(settings, bridge, pairings.bridges.find((one) => one.kind === "main")),
      networkCard(settings),
      sectionHead("HomeKit pairings", "Who the Home app knows each server by"),
      el("div", { class: "grid" }, pairings.bridges.map(pairingCard)),
      cachesSection(caches),
      schedulesCard(uiBlock));
  }

  /// The bridge block of config.json as a form. Saving restarts homeswift: the block is its HomeKit identity.
  function bridgeForm(settings, bridge, main) {
    const input = (key, attrs = {}) => el("input", { type: "text", value: bridge[key] ?? "", name: key, ...attrs });
    const fields = {
      name: input("name", { required: true }),
      port: input("port", { type: "number", min: 1, max: 65535, placeholder: settings.listeningPort ? `Automatic (now ${settings.listeningPort})` : "Automatic" }),
      pin: input("pin", { class: "mono", placeholder: "031-45-154", pattern: "\\d{3}-\\d{2}-\\d{3}", autocomplete: "off", spellcheck: false }),
      manufacturer: input("manufacturer", { placeholder: "Homeswift" }),
      model: input("model", { placeholder: "Homeswift" }),
      firmwareRevision: input("firmwareRevision", { placeholder: "The homeswift version" }),
    };
    const field = (title, control, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: title }), control, help ? el("span", { class: "help", text: help }) : null);
    const message = el("p", { class: "status-line muted", role: "status" });
    const save = el("button", { class: "primary", type: "submit", text: "Save and restart" });
    const read = () => Object.fromEntries(Object.entries(fields).map(([key, control]) => {
      const value = control.value.trim();
      return [key, value === "" ? null : key === "port" ? Number(value) : value];
    }));
    const initial = JSON.stringify(read());
    const form = el("form", { class: "card form-card", onsubmit: async (event) => {
      event.preventDefault();
      const next = read();
      if (JSON.stringify(next) === initial) { message.className = "status-line muted"; message.textContent = "Nothing changed."; return; }
      if (!(await confirmAction({ title: "Restart homeswift with these settings?", danger: false, confirmLabel: "Save and restart",
        text: ["The bridge block is the bridge's HomeKit identity: homeswift restarts to apply it, and every connection drops for a few seconds.",
          next.pin !== (bridge.pin ?? null) ? "A new setup code applies to new pairings only: the Home app keeps the bridge." : ""] }))) return;
      await busy(save, async () => {
        const result = await api("/api/settings/bridge", { method: "PUT", body: { settings: next } });
        message.className = "status-line ok";
        message.textContent = app().savedText(result);
      }, (e) => { message.className = "status-line error"; message.textContent = e.message; });
    } },
      el("div", { class: "server-head" }, tile("bridge", "orange"),
        el("div", { class: "who" }, el("strong", { text: "Bridge" }), el("div", { class: "muted", text: "config.json's bridge block" }))),
      el("div", { class: "facts lead" }, fact("Device ID", settings.deviceId, { class: "mono" }), fact("Listening on port", settings.listeningPort ?? "?"),
        fact("Home app", main?.paired ? `Paired · ${main.controllers}` : "Not paired")),
      el("div", { class: "fields" },
        field("Name", fields.name, "What the Home app calls the bridge when it is added."),
        field("Port", fields.port, "The HomeKit server's port; empty picks a free one and keeps it."),
        field("Setup code", fields.pin, "The code the Home app asks for, as XXX-XX-XXX. It is never logged."),
        field("Manufacturer", fields.manufacturer), field("Model", fields.model), field("Firmware revision", fields.firmwareRevision)),
      el("p", { class: "help", text: "The device ID stays: a new one is a new bridge to the Home app. To pair again from scratch, reset the bridge's pairings below." }),
      el("div", { class: "actions" }, save), message);
    return form;
  }

  /// What this machine runs the bridge with: its addresses and the advertiser. Homeswift listens on every
  /// interface and has no setting for the interfaces to bind or advertise on, nor another mDNS backend.
  function networkCard(settings) {
    return el("div", { class: "card server" },
      el("div", { class: "server-head" }, tile("system", "grey"),
        el("div", { class: "who" }, el("strong", { text: "Network" }), el("div", { class: "muted", text: "Where the Home app finds the bridge" }))),
      el("div", { class: "facts" }, fact("Advertised with", settings.advertiser), fact("Interfaces", "Every one"), fact("Port", settings.listeningPort ?? "?")),
      settings.addresses?.length ? el("div", { class: "chips" }, settings.addresses.map((address) => el("span", { class: "chip mono", text: address }))) : null,
      el("p", { class: "muted note", text: "Homeswift listens and advertises on every interface, with the system's mDNS: there is no interface or mDNS backend to choose, as Homebridge's bind and advertiser settings do." }));
  }

  /// A server's pairing state, and a menu to forget its controllers.
  function pairingCard(bridge) {
    const kind = { main: ["bridge", "orange", "Main bridge"], child: ["child", "violet", "Child bridge"], external: ["accessory", "blue", "Accessory of its own"] }[bridge.kind] ?? ["bridge", "grey", bridge.kind];
    return el("div", { class: "card server" },
      el("div", { class: "server-head" }, tile(kind[0], kind[1]),
        el("div", { class: "who" }, el("strong", { text: bridge.name }), el("div", { class: "muted", text: kind[2] })),
        el("span", { class: `pill status ${bridge.paired ? "on" : "away"}`, text: bridge.paired ? `Paired · ${bridge.controllers}` : "Not paired" })),
      el("div", { class: "facts" }, fact("Device ID", bridge.deviceId, { class: "mono" }), fact("Controllers", bridge.controllers), fact("Admins", bridge.admins)),
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: bridge.paired ? "In the Home app" : "Waiting to be added (setup code on the Status page)" }),
        menuButton(`Actions for ${bridge.name}`, () => [
          { label: "Reset pairings…", icon: "key", danger: true, onSelect: () => resetPairings(bridge) },
        ])));
  }

  async function resetPairings(bridge) {
    const ok = await confirmAction({
      title: `Reset the pairings of ${bridge.name}?`, confirmLabel: "Reset pairings", typed: bridge.name,
      text: ["Every Home app controller paired with it is forgotten and disconnected. The Home app loses it with its accessories, their rooms, scenes and automations.",
        "Add it again afterwards with its setup code, as a new bridge."],
    });
    if (!ok) return;
    await busy(null, async () => { await api("/api/pairings/reset", { method: "POST", body: { bridge: bridge.deviceId, confirm: true } }); app().route(); });
  }

  /// The accessory caches: what each plugin's cache brings back at start, the stale ones first.
  function cachesSection(caches) {
    const list = [...caches.accessories].sort((a, b) => (b.orphaned || b.restoredOnly) - (a.orphaned || a.restoredOnly) || a.name.localeCompare(b.name));
    const row = (cached) => el("div", { class: "row" },
      el("div", { class: "who" }, el("strong", { text: cached.name }),
        el("div", { class: "muted", text: [cached.instance ?? cached.platform ?? cached.cacheFile, cached.bridge, cached.manufacturer, cached.model].filter(Boolean).join(" · ") })),
      cached.orphaned ? el("span", { class: "pill status away", text: "No block", title: "Its block is no longer in config.json" })
        : cached.restoredOnly ? el("span", { class: "pill status away", text: "Stale", title: "Back from the cache, not added again by its plugin" }) : el("span", { class: "pill status on", text: "Current" }),
      menuButton(`Actions for ${cached.name}`, () => [
        { label: "Remove from the cache…", icon: "trash", danger: true, onSelect: () => removeCached(cached) },
      ]));
    const reset = menuButton("Actions for every cache", () => [
      { label: "Reset every cache…", icon: "trash", danger: true, onSelect: resetCaches },
    ]);
    return el("section", {},
      sectionHead("Cached accessories", `${list.length} in ${new Set(list.map((c) => c.cacheFile)).size} cache file(s)`, reset),
      list.length ? el("div", { class: "card rows" }, list.map(row)) : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No cached accessory." })));
  }

  async function removeCached(cached) {
    const ok = await confirmAction({
      title: `Remove ${cached.name} from the cache?`, confirmLabel: "Remove",
      text: "It leaves HomeKit now. A plugin that still has the device adds it again, under the same ids, so rooms and automations come back with it.",
    });
    if (!ok) return;
    await busy(null, async () => { await api("/api/cached-accessories/remove", { method: "POST", body: { id: cached.id, cacheFile: cached.cacheFile } }); app().route(); });
  }

  async function resetCaches() {
    const ok = await confirmAction({
      title: "Reset every accessory cache?", confirmLabel: "Reset the caches", typed: "RESET",
      text: ["Every plugin's accessories leave HomeKit, and the plugins start again on empty caches, adding the devices they reach.",
        "Their ids stay, so rooms and automations come back with the devices; accessories of devices that are gone do not."],
    });
    if (!ok) return;
    await busy(null, async () => { await api("/api/cached-accessories/reset", { method: "POST", body: { confirm: true } }); app().route(); });
  }

  /// The schedules and the reverse proxy: settings of the web UI's own block, edited in its form.
  function schedulesCard(uiBlock) {
    return el("section", {},
      sectionHead("Schedules and proxy", "In the web UI's settings"),
      el("div", { class: "card page-note" },
        el("p", { text: "A scheduled restart (a cron expression), the daily backup (its folder and how long it is kept) and the reverse proxies trusted for X-Forwarded-For and X-Forwarded-Proto are settings of the HomeswiftUI block." }),
        uiBlock ? el("a", { class: "button", href: `/plugins/${uiBlock.slug}`, text: "Open its settings" }) : null));
  }

  // ---- Child bridges -------------------------------------------------------------------------------------

  async function childBridgesPage(main) {
    const [{ childBridges }, status] = await Promise.all([api("/api/child-bridges"), api("/api/status")]);
    const slugs = new Map(withSlugs(status.bridges, "bridge").map((bridge) => [bridge.deviceId, bridge.slug]));
    const tone = { ok: "on", degraded: "away", stopped: "paused" };
    const card = (bridge) => {
      const failures = Object.entries(bridge.failedPlugins ?? {});
      return el("div", { class: "card server" },
        el("div", { class: "server-head" }, tile("child", "violet"),
          el("div", { class: "who" }, el("strong", { text: bridge.name }), el("div", { class: "muted", text: bridge.plugins.join(", ") || "No plugin" })),
          el("span", { class: `pill status ${tone[bridge.status] ?? "standby"}`, text: bridge.status === "stopped" && bridge.stoppedManually ? "Stopped by hand" : { ok: "Running", degraded: "Degraded", stopped: "Stopped" }[bridge.status] ?? bridge.status })),
        el("div", { class: "facts lead" }, fact("Device ID", bridge.id, { class: "mono" }), fact("Port", bridge.port ?? "–"), fact("Accessories", bridge.accessories)),
        el("div", { class: "facts" }, fact("Up", bridge.uptimeSeconds == null ? "–" : app().formatDuration(bridge.uptimeSeconds)), fact("Restarts", bridge.restarts),
          fact("Pairing", bridge.paired ? `Paired · ${bridge.controllers}` : "Not paired")),
        bridge.instances.length ? el("div", { class: "chips" }, bridge.instances.map((name) => el("span", { class: "chip", text: name }))) : null,
        failures.length ? el("div", { class: "notice-list" }, failures.map(([plugin, reason]) => el("p", { class: "error", text: `${plugin} did not start: ${reason}` }))) : null,
        bridge.setupCode ? el("div", { class: "setup" },
          el("img", { class: "qr", src: `/api/qr/${bridge.qrIndex}.svg`, alt: "Pairing QR code", width: 148, height: 148 }),
          el("div", {}, el("p", { text: "In the Home app: Add Accessory, then scan this code, or choose More options and type it." }), el("div", { class: "code", text: bridge.setupCode }))) : null,
        el("div", { class: "card-foot" },
          el("span", { class: "muted", text: bridge.running ? "Runs inside homeswift" : "Its accessories show No Response" }),
          menuButton(`Actions for ${bridge.name}`, () => [
            { label: "Restart", icon: "restore", onSelect: () => control(bridge, "restart") },
            bridge.running ? { label: "Stop", icon: "pause", onSelect: () => control(bridge, "stop") } : { label: "Start", icon: "play", onSelect: () => control(bridge, "start") },
            { label: "Show its log", icon: "logs", href: `/logs?bridge=${encodeURIComponent(slugs.get(bridge.id) ?? "all")}` },
            { label: "Reset pairings…", icon: "key", danger: true, onSelect: () => resetPairings({ name: bridge.name, deviceId: bridge.id }) },
          ])));
    };
    app().show(main,
      app().pageHead("Child bridges", "Plugins on HomeKit bridges of their own (a block with _bridge), inside this process: one can restart without the others."),
      subnav("child-bridges"),
      childBridges.length ? el("div", { class: "servers" }, childBridges.map(card))
        : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No child bridge. Give a plugin's block a \"_bridge\" object (its Expert JSON) to run it on a bridge of its own." })));
  }

  async function control(bridge, action) {
    if (action !== "start" && !(await confirmAction({ title: `${action === "stop" ? "Stop" : "Restart"} ${bridge.name}?`, confirmLabel: action === "stop" ? "Stop" : "Restart", danger: action === "stop",
      text: action === "stop" ? "Its plugins stop and its accessories show No Response until it starts again, or homeswift restarts." : "Its accessories are unavailable for a moment; pairings stay." }))) return;
    await busy(null, async () => { await api(`/api/child-bridges/${encodeURIComponent(bridge.id)}/${action}`, { method: "POST" }); app().route(); });
  }

  // ---- Backups -------------------------------------------------------------------------------------------

  async function backupsPage(main) {
    const [backups, configBackups] = await Promise.all([api("/api/backups"), api("/api/config/backups")]);
    const message = el("p", { class: "status-line muted", role: "status" });
    const report = (e) => { message.className = "status-line error"; message.textContent = e.message; };
    const now = el("button", { text: "Back up now", onclick: (event) => busy(event.currentTarget, async () => {
      const result = await api("/api/backups", { method: "POST" });
      message.className = "status-line ok";
      message.textContent = `Kept ${result.backup.fileName} (${size(result.backup.bytes)}).`;
      setTimeout(() => app().route(), 1200);
    }, report) });
    const instance = el("div", { class: "card server" },
      el("div", { class: "server-head" }, tile("archive", "green"),
        el("div", { class: "who" }, el("strong", { text: "Back up this bridge" }),
          el("div", { class: "muted", text: "config.json, each bridge's HomeKit identity and pairings, accessory caches, plugin files, the web UI's users" }))),
      el("div", { class: "facts" },
        fact("Daily backup", backups.scheduled ? (backups.nextBackup ? `Next ${when(backups.nextBackup)}` : "On") : "Off"),
        fact("Kept", `${backups.retentionDays} days`),
        fact("Scheduled restart", backups.restartCron ? `${backups.restartCron}${backups.nextRestart ? ` · next ${when(backups.nextRestart)}` : ""}` : "None")),
      el("div", { class: "fact wide" }, el("span", { text: "Folder" }), el("b", { class: "mono", text: backups.folder, title: backups.folder })),
      el("div", { class: "actions" },
        el("a", { class: "button primary", href: "/api/backups/download", download: "", text: "Download a backup" }), now),
      message);
    app().show(main,
      app().pageHead("Backups", "The whole instance, to move it or start over, and each saved config.json."),
      subnav("backups"),
      instance,
      restoreCard(backups),
      sectionHead("Kept backups", backups.backups.length ? `${backups.backups.length}, newest first` : ""),
      backups.backups.length ? el("div", { class: "card rows" }, backups.backups.map((backup) => backupRow(backup, backups.instance)))
        : el("div", { class: "card empty" }, el("p", { class: "muted", text: "None yet: the daily backup and Back up now keep them here." })),
      sectionHead("config.json backups", `The file before each of its last ${configBackups.kept} saves`),
      configBackups.backups.length ? el("div", { class: "card rows" }, configBackups.backups.map(configBackupRow))
        : el("div", { class: "card empty" }, el("p", { class: "muted", text: "None yet: each save of config.json keeps the file it replaces." })));
  }

  /// A file to restore, dropped or chosen: checked by the bridge, staged, and applied as homeswift restarts.
  function restoreCard(backups) {
    const picker = el("input", { type: "file", accept: ".tar,application/x-tar", class: "hidden" });
    const zone = el("div", { class: "drop-zone", role: "button", tabIndex: 0, "aria-label": "Drop or choose a backup to restore" },
      "Drop a backup (.tar) here, or ", el("strong", { text: "choose it" }), picker);
    const result = el("div", {});
    const take = async (file) => {
      if (!file) return;
      if (file.size > backups.maxRestoreBytes) { zone.replaceChildren(`${file.name} is larger than ${size(backups.maxRestoreBytes)}.`, picker); return; }
      await restoreArchive(file.name, () => fetch("/api/backups/restore", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-tar" }, body: file }), result);
    };
    zone.addEventListener("click", (event) => { if (event.target !== picker) picker.click(); });
    zone.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); picker.click(); } });
    picker.addEventListener("change", () => { take(picker.files[0]); picker.value = ""; });
    zone.addEventListener("dragover", (event) => { event.preventDefault(); zone.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("over"));
    zone.addEventListener("drop", (event) => { event.preventDefault(); zone.classList.remove("over"); take(event.dataTransfer.files[0]); });
    return el("div", { class: "card" },
      el("h2", { text: "Restore a backup" }),
      el("p", { class: "muted", text: "A backup made by Download a backup or kept below replaces this bridge's files as homeswift restarts: its pairings, accessories and plugin settings come back; this machine's bridge and web UI ports stay. Files it does not have stay as they are." }),
      backups.pendingRestore ? el("p", { class: "ok", text: "A restore is staged: it applies when homeswift next starts." }) : null,
      zone, result);
  }

  /// Asks, sends the archive (`send` answers the fetch's Response), and waits for the restart.
  async function restoreArchive(name, send, result) {
    const ok = await confirmAction({
      title: `Restore ${name}?`, confirmLabel: "Restore and restart", typed: "RESTORE",
      text: ["homeswift restarts on the backup's files: config.json, the bridges' HomeKit identities and pairings, accessory caches, plugin files and the web UI's users. What changed since it was made is lost.",
        "Run one homeswift per backup: two bridges with the same identity make the Home app drop them."],
    });
    if (!ok) return;
    result.replaceChildren(el("p", { class: "muted", text: "Checking the backup…" }));
    try {
      const response = await send();
      const answer = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(answer.error || `HTTP ${response.status}`);
      result.replaceChildren(el("p", { class: "ok", text: `${answer.files} files from ${answer.created ? fullDate.format(new Date(answer.created)) : "the backup"} are staged. ${answer.note}` }),
        answer.skipped?.length ? el("p", { class: "muted", text: `Left out: ${answer.skipped.join(", ")}.` }) : null);
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
        menuButton(`Actions for the backup of ${when(backup.date)}`, () => [
          { label: "Download", icon: "download", href: `/api/backups/${encodeURIComponent(backup.id)}/download` },
          { label: "Restore…", icon: "restore", onSelect: () => restoreArchive(fullDate.format(new Date(backup.date)),
            () => fetch(`/api/backups/${encodeURIComponent(backup.id)}/restore`, { method: "POST", credentials: "same-origin" }), result) },
          { label: "Delete…", icon: "trash", danger: true, onSelect: async () => {
            if (!(await confirmAction({ title: "Delete this backup?", confirmLabel: "Delete", text: `${backup.fileName} is removed from the folder.` }))) return;
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
      detail.replaceChildren(el("p", { class: "muted", text: "Comparing…" }));
      try {
        const [then, now] = await Promise.all([
          api(`/api/config/backups/${encodeURIComponent(backup.name)}`, { raw: true }), api("/api/config", { raw: true })]);
        detail.replaceChildren(diffView(jsonDiff(JSON.parse(then), JSON.parse(now)), "this backup", "config.json now"));
      } catch (e) { detail.replaceChildren(el("p", { class: "error", text: e.message })); }
    };
    const restore = async () => {
      if (!(await confirmAction({ title: "Restore this config.json?", confirmLabel: "Restore", text: "It replaces config.json (which is kept as a backup first) and applies at once, as a save does: plugins reload, and the bridge block restarts homeswift." }))) return;
      await busy(null, async () => {
        const result = await api(`/api/config/backups/${encodeURIComponent(backup.name)}/restore`, { method: "POST" });
        detail.classList.remove("hidden");
        detail.replaceChildren(el("p", { class: "ok", text: `Changed: ${result.changes.join(", ") || "nothing"}. ${app().savedText(result)}` }));
      });
    };
    return el("div", { class: "row-block" },
      el("div", { class: "row" },
        el("div", { class: "who" }, el("strong", { text: backup.date ? fullDate.format(new Date(backup.date)) : backup.name }), el("div", { class: "muted mono", text: backup.name })),
        el("button", { class: "link", text: "Compare", onclick: compare }),
        menuButton(`Actions for ${backup.name}`, () => [
          { label: "Compare with config.json", icon: "code", onSelect: compare },
          { label: "Restore…", icon: "restore", danger: true, onSelect: restore },
        ])),
      detail);
  }

  /// A diff of `jsonDiff` lines: the changes with three lines around them, the rest folded.
  function diffView(lines, before, after) {
    if (!lines.some((line) => line.kind !== "same")) return el("p", { class: "muted", text: "The same as config.json now." });
    const keep = new Set();
    lines.forEach((line, index) => { if (line.kind !== "same") for (let k = index - 3; k <= index + 3; k++) keep.add(k); });
    const nodes = [];
    let folded = 0;
    lines.forEach((line, index) => {
      if (!keep.has(index)) { folded++; return; }
      if (folded) { nodes.push(el("span", { class: "diff-fold", text: `  … ${folded} unchanged line${folded === 1 ? "" : "s"}\n` })); folded = 0; }
      nodes.push(el("span", { class: `diff-${line.kind}`, text: `${line.kind === "add" ? "+ " : line.kind === "remove" ? "- " : "  "}${line.text}\n` }));
    });
    if (folded) nodes.push(el("span", { class: "diff-fold", text: `  … ${folded} unchanged line${folded === 1 ? "" : "s"}\n` }));
    return el("div", {}, el("p", { class: "muted", text: `− ${before}   + ${after}` }), el("pre", { class: "diff" }, nodes));
  }

  // ---- Audit log -----------------------------------------------------------------------------------------

  const outcomes = [["", "Every outcome"], ["ok", "Done"], ["failed", "Failed"], ["notConfirmed", "Not confirmed"]];
  const spans = [["24h", "Last 24 hours"], ["7d", "Last 7 days"], ["30d", "Last 30 days"], ["", "Everything kept"]];

  async function auditPage(main) {
    const params = new URLSearchParams(location.search);
    const tool = el("input", { type: "search", class: "search", placeholder: "Tool or route", value: params.get("tool") ?? "", "aria-label": "Filter by tool" });
    const client = el("input", { type: "search", class: "search", placeholder: "Client or user", value: params.get("client") ?? "", "aria-label": "Filter by client" });
    const select = (choices, value, label) => el("select", { class: "popup", "aria-label": label }, choices.map(([v, text]) => el("option", { value: v, text, selected: v === value })));
    const outcome = select(outcomes, params.get("outcome") ?? "", "Outcome");
    const since = select(spans, params.has("since") ? params.get("since") : "7d", "Time range");
    const count = el("span", { class: "muted count" });
    const body = el("div", {});
    async function load() {
      const query = new URLSearchParams();
      if (tool.value.trim()) query.set("tool", tool.value.trim());
      if (client.value.trim()) query.set("client", client.value.trim());
      if (outcome.value) query.set("outcome", outcome.value);
      query.set("since", since.value);
      window.history.replaceState(null, "", `/settings/audit?${query}`);
      if (!since.value) query.delete("since");
      count.textContent = "Loading…";
      let found;
      try { found = await api(`/api/audit?${query}`); } catch (e) { count.textContent = e.message; return; }
      if (!found.enabled) {
        count.textContent = "";
        body.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: "The audit log is off: the HomeswiftAiKit block's mcp.http says auditLog: false." })));
        return;
      }
      count.textContent = `${found.entries.length} of ${found.total}`;
      body.replaceChildren(found.entries.length ? el("div", { class: "card" }, el("div", { class: "table-scroll" }, el("table", { class: "data-table" },
        el("thead", {}, el("tr", {}, ["Time", "Who", "What", "Outcome", "Details"].map((text) => el("th", { text })))),
        el("tbody", {}, found.entries.map(auditRow)))), el("p", { class: "muted note", text: found.path }))
        : el("div", { class: "card empty" }, el("p", { class: "muted", text: "Nothing in this range matches." })));
    }
    let typing = null;
    for (const input of [tool, client]) input.addEventListener("input", () => { clearTimeout(typing); typing = setTimeout(load, 250); });
    for (const choice of [outcome, since]) choice.addEventListener("change", load);
    app().show(main,
      app().pageHead("Audit log", "Every change made through the MCP server, the Assistant's chat and this web UI, with who made it."),
      subnav("audit"),
      el("div", { class: "filter-bar" }, since, outcome, tool, client, el("span", { class: "spacer" }), count),
      body);
    await load();
  }

  function auditRow(entry) {
    const [text, kind] = entry.notConfirmed ? ["Not confirmed", "away"] : entry.ok ? ["Done", "on"] : ["Failed", "away"];
    const args = entry.args && Object.keys(entry.args).length ? JSON.stringify(entry.args) : "";
    return el("tr", {},
      el("td", { text: entry.ts ? dateTime.format(new Date(entry.ts)) : "–", title: entry.ts ?? "" }),
      el("td", {}, el("strong", { text: entry.principal ?? "?" }), el("div", { class: "muted", text: `${entry.client ?? "?"} · ${entry.scope ?? ""}` })),
      el("td", { class: "mono", text: `${entry.tool}${entry.dryRun ? " (dry run)" : ""}` }),
      el("td", {}, el("span", { class: `pill status ${kind}`, text })),
      el("td", { class: "audit-details" }, entry.error ? el("div", { class: "error", text: entry.error }) : null, args ? el("code", { text: args, title: args }) : null));
  }

  // ---- An accessory's history -----------------------------------------------------------------------------

  const historyUnits = { celsius: "°C", percentage: "%", W: "W", lux: "lx", hPa: "hPa", ppm: "ppm", "µg/m³": "µg/m³" };
  const historyLabels = {
    CurrentTemperature: "Temperature", TargetTemperature: "Target temperature", CurrentRelativeHumidity: "Humidity", AirPressure: "Air pressure",
    AirQuality: "Air quality", VOCDensity: "VOC density", CurrentConsumption: "Power", CurrentAmbientLightLevel: "Light level", On: "On",
    ContactSensorState: "Contact", MotionDetected: "Motion", ValvePosition: "Valve position", WaterAmount: "Water",
  };

  /// A sheet with the accessory's recorded values (its Eve history) as charts, over a day, a week or four weeks.
  function showHistory(accessory) {
    const ranges = [[24, "24 hours"], [168, "7 days"], [672, "4 weeks"]];
    let hours = 24;
    const charts = el("div", { class: "chart-grid" });
    const note = el("p", { class: "muted" });
    const group = el("div", { class: "group", role: "group", "aria-label": "Time range" }, ranges.map(([value, text]) =>
      el("button", { type: "button", text, class: value === hours ? "on" : "", "aria-pressed": String(value === hours), onclick: (event) => {
        hours = value;
        for (const button of group.children) { button.classList.toggle("on", button === event.currentTarget); button.setAttribute("aria-pressed", String(button === event.currentTarget)); }
        load();
      } })));
    const close = el("button", { type: "button", text: "Done", class: "primary" });
    const dialog = el("dialog", { class: "admin-dialog card wide", "aria-labelledby": "history-title" },
      el("div", { class: "page-head" }, el("div", { class: "who" }, el("h2", { id: "history-title", text: accessory.name }), el("p", { class: "muted", text: "Recorded values, as Eve shows them" })),
        el("div", { class: "tools" }, group)),
      charts, note, el("div", { class: "actions" }, close));
    close.addEventListener("click", () => dialog.close());
    dialog.addEventListener("close", () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();

    async function load() {
      charts.classList.add("loading");
      let found;
      try { found = await api(`/api/accessories/${encodeURIComponent(accessory.id)}/history?hours=${hours}&points=240`); }
      catch (e) { note.className = "error"; note.textContent = e.message; return; }
      charts.classList.remove("loading");
      note.className = "muted";
      note.textContent = found.note ?? "Ten-minute averages, kept four weeks; each point here averages those in its span.";
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
            el("div", { class: "muted", text: `Lowest ${format(series.min.value)} · highest ${format(series.max.value)} · average ${format(series.avg)}` })),
          el("b", { class: "chart-figure", text: format(series.last.value), title: `Last, ${when(series.last.at)}` })),
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
