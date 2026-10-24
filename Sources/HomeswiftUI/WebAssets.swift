// THIS FILE IS GENERATED from Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

enum WebAssets {
    /// The UI's pages, as written.
    static let files: [String: WebFile] = [
        "admin.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
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
      backups.backups.length ? el("div", { class: "card rows" }, backups.backups.map(backupRow))
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
      count.textContent = "Loading…";
      let found;
      try { found = await api(`/api/audit?${query}`); } catch (e) { if (own === loads) count.textContent = e.message; return; }
      if (own !== loads) return;
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
      // Ranges chosen quickly one after the other: only the last one's answer is drawn.
      const asked = hours;
      charts.classList.add("loading");
      let found;
      try { found = await api(`/api/accessories/${encodeURIComponent(accessory.id)}/history?hours=${hours}&points=240`); }
      catch (e) { if (asked === hours) { charts.classList.remove("loading"); note.className = "error"; note.textContent = e.message; } return; }
      if (asked !== hours) return;
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

"""#),
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
    // The chat lives outside #app: closed and emptied, so the next person at this browser does not see it.
    window.HomeswiftChat?.signedOut();
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

  const signOut = async () => { try { await api("/api/auth/logout", { method: "POST" }); } catch {} await loadAuth(); };

  /// The name the header shows: the user's display name, else their username; none without sign-in.
  const shownName = () => (auth.mode === "form" ? (auth.name && auth.name !== auth.username ? auth.name : auth.username || "") : "");

  /// The header's account button: the user's initial on the accent (a person without sign-in), the name beside it on
  /// a wide window.
  function drawUser() {
    const name = shownName();
    $("#user .user-avatar").replaceChildren(auth.mode === "form" && name ? name.slice(0, 1).toUpperCase() : HomeswiftCommon.icon("user"));
    $("#user .user-name").textContent = name;
  }

  // Its menu: who is signed in and as what, their account and appearance, the users for an administrator, signing out.
  $("#user").addEventListener("click", (event) => {
    event.stopPropagation();
    const form = auth.mode === "form";
    HomeswiftCommon.menu($("#user"), [
      form ? { heading: shownName(), detail: `${auth.username}${isAdmin() ? " · Administrator" : ""}` } : { heading: "No sign-in", detail: "Anyone who opens this web UI uses it" },
      { label: form ? "Your account" : "Account", icon: "user", href: "/account" },
      { label: "Appearance", icon: "sliders", href: "/appearance" },
      form && isAdmin() ? { label: "Users and tokens", icon: "users", href: "/users" } : null,
      form ? { separator: true } : null,
      form ? { label: "Sign out", icon: "logout", onSelect: signOut } : null,
    ], { keyboard: event.detail === 0 });
  });

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
    drawUser();
    HomeswiftCommon.tabBar({ parent: $("#app") });
    showSections();
    HomeswiftChat.mount();
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
    drawUser();
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
    // A new element per view: a slower view still loading draws into the old one, out of the page, rather than
    // over the view asked for after it.
    const main = el("main", { id: "view" }, el("div", { class: "view-loading" }, spinner()));
    $("#view").replaceWith(main);
    leaveGuard = null;
    shownPath = location.pathname + location.search;
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

  /// An answer streaming into `node`: the text so far drawn as Markdown once per frame, however many pieces
  /// arrive (as the chat does), rather than parsed again for each piece. Answers the `onChunk` to give the request.
  /// Once something else is drawn in `node` (the final answer, an error), a frame still pending leaves it be.
  function streamInto(node) {
    let text = "", scheduled = false, drawn = node.firstChild;
    return (piece) => {
      text += piece;
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        if (node.firstChild !== drawn) return;
        drawn = HomeswiftCommon.markdown(text);
        node.replaceChildren(drawn);
      });
    };
  }

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
      const live = el("div", {}, el("p", { class: "ai-thinking", text: "Reading the day…" }));
      body.replaceChildren(live, el("button", { class: "link", text: "Stop", onclick: () => own.abort() }));
      card.classList.add("writing");
      note.textContent = "";
      try {
        shown(await HomeswiftCommon.assistantRequest("/api/assistant/digest", {}, { signal: own.signal, onChunk: streamInto(live) }));
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
      // Also when the capture is lost (the wall drawn again under the finger): the page stops scrolling.
      const end = () => {
        node.removeEventListener("pointermove", move);
        node.removeEventListener("pointerup", end);
        node.removeEventListener("pointercancel", end);
        node.removeEventListener("lostpointercapture", end);
        clearInterval(scroller);
        if (!slot || !slot.isConnected) return;
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
      node.addEventListener("lostpointercapture", end);
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
    /// A cron expression (`x-schema-form.type: "schedule"`, the scheduled restart) as a time and the days it runs on,
    /// which it writes as `M H * * d,d`; an expression that says more than that stays as it is, under Custom.
    const scheduleField = (wrap, current) => {
      const names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
      const text = typeof current === "string" ? current.trim() : "";
      const simple = /^(\d{1,2})\s+(\d{1,2})\s+\*\s+\*\s+(\*|[0-7](?:,[0-7])*)$/.exec(text);
      const fits = simple && Number(simple[1]) < 60 && Number(simple[2]) < 24;
      const mode = el("select", { "aria-label": "Repeat" },
        el("option", { value: "never", text: "Never" }), el("option", { value: "time", text: "At a time" }), el("option", { value: "custom", text: "Custom (cron)" }));
      mode.value = !text ? "never" : fits ? "time" : "custom";
      const pad = (n) => String(n).padStart(2, "0");
      const time = el("input", { type: "time", value: fits ? `${pad(simple[2])}:${pad(simple[1])}` : "04:00", "aria-label": "Time" });
      const chosen = new Set(fits && simple[3] !== "*" ? simple[3].split(",").map((day) => Number(day) % 7) : []);
      const days = el("span", { class: "days", role: "group", "aria-label": "Days (none: every day)" }, names.map((name, day) => {
        const box = el("input", { type: "checkbox", checked: chosen.has(day), "aria-label": name });
        box.addEventListener("change", () => { if (box.checked) chosen.add(day); else chosen.delete(day); });
        return el("label", { class: "day" }, box, el("span", { text: name.slice(0, 2) }));
      }));
      const custom = el("input", { type: "text", value: text, placeholder: "0 4 * * 1", "aria-label": "Cron expression" });
      const timed = el("span", { class: "group-inline" }, time, days);
      const fromTime = () => {
        const [hour, minute] = (time.value || "04:00").split(":").map(Number);
        const list = chosen.size === 0 || chosen.size === 7 ? "*" : [...chosen].sort((a, b) => a - b).join(",");
        return `${minute} ${hour} * * ${list}`;
      };
      const show = () => {
        timed.classList.toggle("hidden", mode.value !== "time");
        custom.classList.toggle("hidden", mode.value !== "custom");
      };
      mode.addEventListener("change", () => {
        // Custom starts from what the time and days say.
        if (mode.value === "custom" && !custom.value.trim()) custom.value = fromTime();
        show();
      });
      show();
      return {
        element: wrap(el("span", { class: "group-inline" }, mode, timed, custom)),
        get: () => (mode.value === "never" ? undefined : mode.value === "time" ? fromTime() : custom.value.trim() || undefined),
      };
    };
    const makeField = (key, property, current, required, index) => {
      const title = property.title || key;
      const help = property.description ? el("div", { class: "help", text: property.description }) : null;
      const wrap = (control) => el("label", { class: "field" }, el("span", { class: "field-title" }, title, required ? el("span", { class: "muted", text: " · required" }) : null), control, help);
      const type = property.type;
      if (property["x-schema-form"]?.type === "schedule") return scheduleField(wrap, current);
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
      el("button", { text: "Sign out", onclick: signOut }));
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
    const openForm = (user) => { formSlot.replaceChildren(userForm(user, closeForm)); formSlot.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" }); $("input", formSlot)?.focus(); };

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
    revert.addEventListener("click", () => { textarea.value = saved; message.textContent = ""; editor.repaint(); update(); });
    const editor = jsonEditor(textarea);
    format.addEventListener("click", () => { try { textarea.value = JSON.stringify(JSON.parse(textarea.value), null, 2); editor.repaint(); update(); } catch {} });
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
      const shown = shownLines();
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
          signal: own.signal, onChunk: streamInto(live) });
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

"""#),
        "apple-touch-icon.png": WebFile(contentType: "image/png", base64: "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"),
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
      // This attempt's own clean-up, once, when the view stops or the attempt ends: a camera that reconnects for
      // hours does not pile up listeners on the run's signal, nor keep each attempt's MediaSource.
      const reader = response.body.getReader();
      let watchdog = null, detached = false;
      const detach = () => {
        if (detached) return;
        detached = true;
        clearInterval(watchdog);
        reader.cancel().catch(() => {});
        video.removeAttribute("src");
        video.load();
        URL.revokeObjectURL(sourceURL);
      };
      signal.addEventListener("abort", detach, { once: true });
      try {
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
        let started = false;
        // Stalled: no new frame for a while, start again.
        let lastTime = -1, stalledSince = Date.now();
        watchdog = setInterval(() => {
          if (video.currentTime !== lastTime) { lastTime = video.currentTime; stalledSince = Date.now(); return; }
          if (Date.now() - stalledSince > 10000) reader.cancel().catch(() => {});
        }, 2000);
        for (;;) {
          const { value, done } = await reader.read();
          if (done || signal.aborted) break;
          queue.push(value);
          pump();
          if (!started) { started = true; video.play().catch(() => {}); }
        }
        return true;
      } finally {
        signal.removeEventListener("abort", detach);
        detach();
      }
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
  const { $, el, icon, markdown, sparkle, api, jsonView } = HomeswiftCommon;

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
  let session = 0;      // a sign-out moves it on: a stream read before it stops drawing

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
    const earlier = el("button", { type: "button", class: "chat-icon", "aria-label": "Earlier chats", title: "Earlier chats", "aria-expanded": "false", onclick: () => showHistory() }, icon("history"));
    const head = el("div", { class: "chat-head" },
      el("span", { class: "chat-grabber", "aria-hidden": "true" }),
      sparkle(), el("strong", { id: "chat-title", text: "Assistant" }), el("span", { class: "chat-model", text: info.model || "" }),
      el("span", { class: "spacer" }), earlier, fresh, close);
    const sheet = el("section", { class: "chat", role: "dialog", "aria-labelledby": "chat-title", hidden: true },
      el("div", { class: "chat-glow", "aria-hidden": "true" }),
      el("div", { class: "chat-surface" }, head, log, form, voice, foot));
    const scrim = el("div", { class: "chat-scrim", hidden: true, onclick: () => toggle(false) });
    document.body.append(scrim, sheet);
    panel = { sheet, scrim, log, input, mic, send, foot, head, languagePicker, earlier };

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
    closeHistory();
    setItems([], false);
    usage = null;
    renderControls();
    panel.input.focus();
  }

  /// Reads a run's event stream: a snapshot, then items, text and the end.
  async function follow(response) {
    const own = session;
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    running = true;
    renderControls();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        // Signed out meanwhile: what is left of the run is not drawn.
        if (own !== session) { reader.cancel().catch(() => {}); return; }
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
      if (own === session) showError(`The connection dropped: ${e.message}`);
    }
    if (own !== session) return;
    running = false;
    renderControls();
  }

  function handle(event, data) {
    if (historyOpen && event !== "snapshot") closeHistory();
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

  // ---- Earlier conversations ----------------------------------------------------------------------------------
  // The bridge keeps each user's conversations (the open one and the 10 before it): New chat files the open one
  // away, and one picked here opens again where it was, the Assistant remembering it.

  let historyOpen = false;
  async function showHistory() {
    if (historyOpen) { closeHistory(); return; }
    historyOpen = true;
    panel.earlier.setAttribute("aria-expanded", "true");
    const list = el("div", { class: "chat-history", role: "region", "aria-label": "Earlier chats" }, el("p", { class: "muted", text: "Loading…" }));
    panel.log.replaceChildren(list);
    let chats;
    try { chats = await api("/api/assistant/chats"); } catch (e) { list.replaceChildren(el("p", { class: "chat-error", text: e.message })); return; }
    if (!historyOpen) return;
    const when = new Intl.DateTimeFormat([], { dateStyle: "medium", timeStyle: "short" });
    const rows = chats.map((chat) => {
      const row = el("div", { class: `chat-history-row${chat.current ? " current" : ""}` },
        el("button", { type: "button", class: "chat-history-open", onclick: () => openChat(chat) },
          el("strong", { text: chat.title }),
          el("span", { class: "muted", text: `${when.format(new Date(chat.updated))} · ${chat.messages} ${chat.messages === 1 ? "message" : "messages"}${chat.current ? " · open" : ""}` })),
        el("button", { type: "button", class: "chat-icon", "aria-label": `Forget “${chat.title}”`, title: "Forget this chat", text: "×", onclick: async () => {
          try { await api(`/api/assistant/chats/${encodeURIComponent(chat.id)}`, { method: "DELETE" }); } catch (e) { showError(e.message); return; }
          row.remove();
          if (chat.current) { setItems([], false); historyOpen = false; showHistory(); }
        } }));
      return row;
    });
    list.replaceChildren(el("h2", { text: "Earlier chats" }),
      rows.length ? el("div", { class: "chat-history-list" }, rows) : el("p", { class: "muted", text: "No chat yet. Each one you start is kept here, the last ten." }),
      el("button", { type: "button", class: "link", text: "Back to the chat", onclick: closeHistory }));
  }

  async function openChat(chat) {
    if (running) await stop();
    if (!chat.current) {
      try { await api(`/api/assistant/chats/${encodeURIComponent(chat.id)}/open`, { method: "POST", body: {} }); } catch (e) { showError(e.message); return; }
    }
    closeHistory(false);
    loaded = false;
    usage = null;
    await load();
    panel.input.focus();
  }

  /// Back to the conversation; `redraw` false when another one is about to load.
  function closeHistory(redraw = true) {
    if (!historyOpen) return;
    historyOpen = false;
    panel.earlier.setAttribute("aria-expanded", "false");
    if (redraw) setItems(items, running);
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
    // Tables: the delimiter rows go, cells are read as a list.
    const plain = text.replace(/```[\s\S]*?```/g, "").replace(/^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/gm, "").replace(/\s*\|\s*/g, ", ")
      .replace(/[*_`#>~]/g, "").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
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
    const shortcut = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘K" : "Ctrl+K";
    trigger = el("button", {
      type: "button", class: "chat-open", "aria-expanded": "false", "aria-haspopup": "dialog", "aria-label": "Assistant", title: `Ask the Assistant (${shortcut})`,
      "aria-keyshortcuts": "Meta+K Control+K", onclick: () => toggle(),
    }, sparkle());
    header.insertBefore(trigger, header.querySelector("#user"));
    // Cmd+K (Ctrl+K elsewhere) opens the chat from anywhere, and closes it, as Glass UI's palette.
    document.addEventListener("keydown", (event) => {
      // Not from the sign-in screen: the button is in the hidden app then.
      if (!trigger?.isConnected || trigger.closest(".hidden")) return;
      if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "k" && !event.isComposing) {
        event.preventDefault();
        toggle();
      }
    });
    phone.addEventListener("change", () => { if (isOpen()) { panel.scrim.hidden = !phone.matches; draw(openness.value); } });
  }

  /// Opens the chat with `text` typed in, for the person to finish and send.
  function ask(text) {
    toggle(true);
    panel.input.value = text;
    grow();
    setTimeout(() => { panel.input.focus(); panel.input.setSelectionRange(text.length, text.length); }, 60);
  }

  /// Signed out (app.js): the panel closes at once and forgets the conversation it shows, so whoever signs in next
  /// on this browser starts from their own.
  function signedOut() {
    session++;
    if (!panel) return;
    if (listening) stopListening(true);
    window.speechSynthesis?.cancel();
    cancelAnimationFrame(openness.frame);
    openness.value = 0;
    openness.velocity = 0;
    openness.target = 0;
    panel.sheet.hidden = true;
    panel.scrim.hidden = true;
    trigger?.setAttribute("aria-expanded", "false");
    closeHistory(false);
    items = [];
    nodes = [];
    running = false;
    usage = null;
    spoken = false;
    loaded = false;
    panel.input.value = "";
    panel.log.replaceChildren();
    renderControls();
  }

  /// The language chosen for voice, else the browser's.
  const voiceLanguage = () => panel?.languagePicker.value || navigator.language || "en-US";

  window.HomeswiftChat = { mount, ask, signedOut, open: () => toggle(true), available: () => Boolean(info?.enabled) };
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
    room: '<path d="M4 21V5a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v16M2 21h20M15 12h.01"/>',
    star: '<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z"/>',
    eye: '<path d="M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7-9.5-7-9.5-7z"/><circle cx="12" cy="12" r="2.5"/>',
    bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4"/>',
    user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
    users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8M18 14.2a6.5 6.5 0 0 1 3.5 5.8"/>',
    logout: '<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4"/><path d="M9 16.5 4.5 12 9 7.5M4.5 12H15"/>',
    chart: '<path d="M4 4v16h16"/><path d="m7 15 4-5 3 3 5-6"/>',
    archive: '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4"/>',
    key: '<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M17 6l2 2M15 8l2 2"/>',
    shield: '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6z"/><path d="m9 12 2 2 4-4"/>',
    download: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
    restore: '<path d="M4 12a8 8 0 1 0 2.4-5.7L4 8.6"/><path d="M4 4v4.6h4.6"/>',
    history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6M3.5 4.5V9H8"/><path d="M12 7.5V12l3 2"/>',
    sliders: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
    up: '<path d="M6 15l6-6 6 6"/>',
    down: '<path d="M6 9l6 6 6-6"/>',
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

  // A table's cells: the outer pipes dropped, split on the others; `\|` is a pipe inside a cell.
  const tableCells = (row) => {
    let text = row.trim();
    if (text.startsWith("|")) text = text.slice(1);
    if (text.endsWith("|") && !text.endsWith("\\|")) text = text.slice(0, -1);
    return text.split(/(?<!\\)\|/).map((cell) => cell.trim().replace(/\\\|/g, "|"));
  };
  const tableDelimiter = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

  // A GitHub table: the header, its delimiter row (`:` for alignment), then the rows, held to the header's columns.
  function table(header, delimiter, rows) {
    const aligns = delimiter.map((cell) =>
      cell.endsWith(":") ? (cell.startsWith(":") ? "align-center" : "align-right") : null);
    const row = (cells, tag) => el("tr", {}, header.map((_, i) => el(tag, aligns[i] ? { class: aligns[i] } : {}, inline(cells[i] ?? ""))));
    return el("div", { class: "md-table" }, el("table", {},
      el("thead", {}, row(header, "th")),
      rows.length ? el("tbody", {}, rows.map((cells) => row(cells, "td"))) : null));
  }

  /// Markdown from the Assistant as elements, never as HTML: headings, paragraphs, nested and task lists, tables,
  /// quotes, rules, code blocks, and the inline marks of `inline`. Anything else stays text.
  function markdown(source, depth = 0) {
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
      if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) {
        flush(); closeLists();
        root.append(el("hr", {}));
        continue;
      }
      // Quotes nest a few deep: a line of thousands of ">" (a log quoted back) stays text rather than overflowing the stack.
      if (/^\s*>/.test(line) && depth < 8) {
        flush(); closeLists();
        const quoted = [line];
        while (i + 1 < lines.length && /^\s*>/.test(lines[i + 1])) quoted.push(lines[++i]);
        root.append(el("blockquote", {}, ...markdown(quoted.map((text) => text.replace(/^\s*>\s?/, "")).join("\n"), depth + 1).childNodes));
        continue;
      }
      if (line.includes("|") && tableDelimiter.test(lines[i + 1] ?? "")) {
        const header = tableCells(line);
        const delimiter = tableCells(lines[i + 1]);
        if (delimiter.length === header.length) {
          flush(); closeLists();
          i++;
          const rows = [];
          while (i + 1 < lines.length && lines[i + 1].includes("|") && lines[i + 1].trim()) rows.push(tableCells(lines[++i]));
          root.append(table(header, delimiter, rows));
          continue;
        }
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
          // A numbered list keeps its first number (a list split by a paragraph goes on at 3).
          const start = ordered ? parseInt(item[2], 10) : 1;
          const node = el(ordered ? "ol" : "ul", start !== 1 ? { start } : {});
          const parent = current && current.indent < indent ? current.node.lastElementChild : null;
          (parent || root).append(node);
          if (current && current.indent === indent) lists.pop();
          current = { indent, ordered, node };
          lists.push(current);
        }
        const task = item[3].match(/^\[([ xX])\]\s+(.*)$/);
        current.node.append(task
          ? el("li", { class: "task" }, el("input", { type: "checkbox", checked: task[1] !== " ", disabled: true }), inline(task[2]))
          : el("li", {}, inline(item[3])));
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

  // The inline marks, the first that matches winning: code (taken as is), ***bold italics***, **bold** and
  // __bold__, ~~struck~~, *italics* and _italics_ (not inside a word: snake_case stays), [a link](https://…),
  // then a bare http(s) URL without its trailing punctuation.
  const inlinePattern = new RegExp([
    /`[^`]+`/, /\*\*\*[^*\s](?:[^*]*[^*\s])?\*\*\*/, /\*\*(?:[^*]|\*(?!\*))+?\*\*/, /__[^_\s](?:[^_]*[^_\s])?__/,
    /~~[^~\s](?:[^~]*[^~\s])?~~/, /\*[^*\s](?:[^*]*[^*\s])?\*/, /(?<!\w)_[^_\s](?:[^_]*[^_\s])?_(?!\w)/,
    /\[[^\]]+\]\(https?:\/\/[^)\s]+\)/, /https?:\/\/[^\s<>]*[^\s<>.,;:!?'")\]]/,
  ].map((part) => part.source).join("|"), "g");

  const link = (url, label) => el("a", { href: url, target: "_blank", rel: "noopener noreferrer" }, label ?? url);

  /// Inline Markdown: `code`, **bold**, *italics*, ***both***, ~~struck~~, [a link](https://…) and bare
  /// https:// links; marks nest (**`code` in bold**).
  function inline(text) {
    const nodes = [];
    let last = 0;
    for (const match of text.matchAll(inlinePattern)) {
      if (match.index > last) nodes.push(text.slice(last, match.index));
      const token = match[0];
      if (token.startsWith("`")) nodes.push(el("code", { text: token.slice(1, -1) }));
      else if (token.startsWith("***")) nodes.push(el("strong", {}, el("em", {}, inline(token.slice(3, -3)))));
      else if (token.startsWith("**") || token.startsWith("__")) nodes.push(el("strong", {}, inline(token.slice(2, -2))));
      else if (token.startsWith("~~")) nodes.push(el("del", {}, inline(token.slice(2, -2))));
      else if (token.startsWith("[")) {
        const [, label, url] = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
        nodes.push(link(url, inline(label)));
      } else if (token.startsWith("http")) nodes.push(link(token));
      else nodes.push(el("em", {}, inline(token.slice(1, -1))));
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
      // Who the menu is about (the header's account menu): a name and a line under it, not an action.
      if (item.heading !== undefined) return el("div", { class: "menu-heading" }, el("strong", { text: item.heading }), item.detail ? el("span", { text: item.detail }) : null);
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
    const entries = nodes.filter((node) => node.getAttribute("role")?.startsWith("menuitem"));
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

  /// Two JSON values as pretty JSON with sorted keys, line by line: `{ kind: "same" | "add" | "remove", text }`, from a
  /// longest common subsequence. A plugin block against the Assistant's suggestion, a config.json backup against the file.
  function jsonDiff(before, after) {
    const sortKeys = (value) => Array.isArray(value) ? value.map(sortKeys)
      : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys(value[key])])) : value;
    const a = JSON.stringify(sortKeys(before ?? {}), null, 2).split("\n");
    const b = JSON.stringify(sortKeys(after ?? {}), null, 2).split("\n");
    // The lines both ends share are the same: only the middle needs the table, which grows with its square.
    let start = 0;
    while (start < a.length && start < b.length && a[start] === b[start]) start++;
    let endA = a.length, endB = b.length;
    while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
    const x = a.slice(start, endA), y = b.slice(start, endB);
    const lengths = Array.from({ length: x.length + 1 }, () => new Uint32Array(y.length + 1));
    for (let i = x.length - 1; i >= 0; i--) for (let j = y.length - 1; j >= 0; j--) {
      lengths[i][j] = x[i] === y[j] ? lengths[i + 1][j + 1] + 1 : Math.max(lengths[i + 1][j], lengths[i][j + 1]);
    }
    const out = a.slice(0, start).map((text) => ({ kind: "same", text }));
    let i = 0, j = 0;
    while (i < x.length && j < y.length) {
      if (x[i] === y[j]) { out.push({ kind: "same", text: x[i] }); i++; j++; }
      else if (lengths[i + 1][j] >= lengths[i][j + 1]) out.push({ kind: "remove", text: x[i++] });
      else out.push({ kind: "add", text: y[j++] });
    }
    while (i < x.length) out.push({ kind: "remove", text: x[i++] });
    while (j < y.length) out.push({ kind: "add", text: y[j++] });
    for (const text of a.slice(endA)) out.push({ kind: "same", text });
    return out;
  }

  /// A labelled value in a `.facts` grid: the label small, the value bold with its full text as a tooltip.
  const fact = (label, value, attrs = {}) =>
    el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: String(value), title: String(value), ...attrs }));

  // ---- The sections, and the tab bar a phone shows them in -----------------------------------------------

  const sections = [["/status", "Status", "bridge"], ["/accessories", "Accessories", "bulb"], ["/scenes", "Scenes", "play"], ["/plugins", "Plugins", "plugin"], ["/config", "Config", "code"], ["/logs", "Logs", "logs"]];

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

  // ---- The Assistant's one-shot requests, streamed ----------------------------------------------------------
  // POST /api/assistant/explain, …/ask, …/diagnose, …/digest. With `onChunk` the request carries a requestId and
  // the answer comes as server-sent events (start, chunk, done or error), each piece of text to `onChunk`; an
  // AbortSignal stops it (POST /api/assistant/cancel). Answers the final JSON either way.

  let requests = 0;
  async function assistantRequest(path, body = {}, { onChunk, signal } = {}) {
    if (!onChunk) return api(path, { method: "POST", body });
    const requestId = `r${Date.now().toString(36)}-${++requests}`;
    const cancel = () => { api("/api/assistant/cancel", { method: "POST", body: { requestId } }).catch(() => {}); };
    if (signal?.aborted) throw Object.assign(new Error("Stopped."), { name: "AbortError" });
    signal?.addEventListener("abort", cancel, { once: true });
    try {
      const response = await api(path, { method: "POST", body: { ...body, requestId }, stream: true });
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
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
          if (!event || !data) continue;
          const payload = JSON.parse(data);
          if (event === "chunk") onChunk(payload.text);
          else if (event === "done") return payload;
          else if (event === "error") throw Object.assign(new Error(payload.error), { status: payload.status });
        }
      }
      throw new Error(signal?.aborted ? "Stopped." : "The connection dropped before the answer ended.");
    } finally {
      signal?.removeEventListener("abort", cancel);
    }
  }

  // ---- Appearance: theme, wallpaper, temperature unit --------------------------------------------------------
  // Each user's choices live on the server (/api/preferences); this browser keeps the last ones it saw, so a page
  // opens in them before the server answers. Storage may be missing (a private window): it then waits.

  const preferenceKey = "homeswift.preferences";
  let preferences = { theme: "auto", wallpaper: "none", temperatureUnit: "c" };
  try { Object.assign(preferences, JSON.parse(localStorage.getItem(preferenceKey) || "{}")); } catch {}

  /// Applies the user's choices to this page (and remembers them in this browser): `data-theme` and
  /// `data-wallpaper` on the root element, which the stylesheet reads, and the unit temperatures show in.
  function applyPreferences(next) {
    if (next) preferences = { ...preferences, ...next };
    const root = document.documentElement;
    if (preferences.theme === "light" || preferences.theme === "dark") root.dataset.theme = preferences.theme; else delete root.dataset.theme;
    if (preferences.wallpaper && preferences.wallpaper !== "none") root.dataset.wallpaper = preferences.wallpaper; else delete root.dataset.wallpaper;
    if (preferences.wallpaper === "custom") root.style.setProperty("--wallpaper-image", `url("/api/preferences/wallpaper?v=${encodeURIComponent(preferences.wallpaperVersion || "1")}")`);
    else root.style.removeProperty("--wallpaper-image");
    // The browser's bar follows a theme chosen here rather than the system's.
    for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
      if (!meta.dataset.media) meta.dataset.media = meta.media || "";
      meta.media = preferences.theme === "auto" ? meta.dataset.media : (meta.dataset.media.includes(preferences.theme) ? "all" : "not all");
    }
    if (next) { try { localStorage.setItem(preferenceKey, JSON.stringify(preferences)); } catch {} }
    document.dispatchEvent(new CustomEvent("homeswift:preferences", { detail: preferences }));
    return preferences;
  }
  applyPreferences();

  /// The user's choices from the server, applied; the ones this browser kept when it cannot be asked.
  async function loadPreferences() {
    try { return applyPreferences(await api("/api/preferences")); } catch { return preferences; }
  }

  /// A temperature HomeKit gives in °C, in the unit the user chose: `{ value, unit }`, the value rounded to a tenth.
  function temperature(celsius) {
    const value = Number(celsius);
    if (preferences.temperatureUnit === "f") return { value: Math.round((value * 1.8 + 32) * 10) / 10, unit: "°F" };
    return { value: Math.round(value * 10) / 10, unit: "°C" };
  }
  /// "21.5 °C" or "70.7 °F".
  const formatTemperature = (celsius) => { const { value, unit } = temperature(celsius); return `${value} ${unit}`; };

  window.HomeswiftCommon = {
    $, el, icon, tile, fact, markdown, sparkle, api, menu, menuButton, copyText, jsonHighlight, jsonView, jsonEditor, sections, tabBar, setPaused, slug, withSlugs, jsonDiff,
    assistantRequest, applyPreferences, loadPreferences, preferences: () => preferences, temperature, formatTemperature,
  };
})();

"""#),
        "home.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// Rooms and hidden accessories, the Quick Controls, scenes and their automations, and notifications: the views
// ported from Glass UI. app.js hands its helpers over with install() before the first view is drawn.
(() => {
  "use strict";

  const { $, el, tile, sparkle, menuButton, fact } = HomeswiftCommon;
  let app = null;

  const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const operators = [["eq", "is"], ["neq", "is not"], ["gt", "is above"], ["gte", "is at least"], ["lt", "is below"], ["lte", "is at most"]];
  const field = (label, input, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, help ? el("span", { class: "help", text: help }) : null);
  const displayName = (accessory) => accessory.displayName || accessory.name;
  const statusLine = () => el("p", { class: "status-line muted", role: "status" });
  const say = (line, text, kind = "muted") => { line.className = `status-line ${kind}`; line.textContent = text; };

  // ---- Rooms, hidden accessories, display names ------------------------------------------------------

  async function changeLayout(body) {
    return app.api("/api/rooms", { method: "PUT", body });
  }

  /// What an accessory card's menu adds: its room, a name for these pages, Quick Controls, hiding.
  function layoutActions(accessory) {
    const change = (fields) => changeLayout({ accessories: { [accessory.id]: fields } }).then(() => app.route()).catch((e) => alert(e.message));
    return [
      { label: accessory.room ? `Room: ${accessory.room}…` : "Put in a room…", icon: "room", onSelect: () => chooseRoom(accessory, change) },
      { label: "Name on these pages…", icon: "edit", onSelect: () => {
        const name = prompt(`A name for ${accessory.name} on these pages (the Home app keeps its own). Empty goes back to ${accessory.name}.`, accessory.displayName || "");
        if (name !== null) change({ name: name.trim() || null });
      } },
      { label: accessory.favourite ? "Remove from Quick Controls" : "Add to Quick Controls", icon: "star", onSelect: () => change({ favourite: !accessory.favourite }) },
      { label: accessory.hidden ? "Show it again" : "Hide", icon: "eye", onSelect: () => change({ hidden: !accessory.hidden }) },
    ];
  }

  async function chooseRoom(accessory, change) {
    let rooms = [];
    try { rooms = (await app.api("/api/rooms")).rooms.map((room) => room.name); } catch {}
    const known = rooms.length ? ` Rooms: ${rooms.join(", ")}.` : "";
    const room = prompt(`The room of ${displayName(accessory)}.${known} A new name adds the room; empty takes it out of its room.`, accessory.room || "");
    if (room !== null) change({ room: room.trim() || null });
  }

  /// The Accessories page's accessories by room, in the layout's order; those in no room last.
  function groupByRoom(accessories, rooms) {
    const byName = (a, b) => displayName(a).localeCompare(displayName(b));
    const groups = rooms.map((room) => [room, accessories.filter((a) => a.room === room).sort(byName)]).filter(([, list]) => list.length);
    const rest = accessories.filter((a) => !a.room || !rooms.includes(a.room)).sort(byName);
    return rest.length ? [...groups, [groups.length ? "No room" : "Accessories", rest]] : groups;
  }

  /// The Assistant's rooms and names, to review: each suggestion can be kept or left; Apply saves what is kept.
  /// Names go to these pages only; HomeKit and the Home app keep theirs.
  async function suggestRooms(host, accessories) {
    host.querySelector(".suggest")?.remove();
    const panel = el("div", { class: "card panel suggest" },
      el("div", { class: "panel-head" }, el("div", {}, el("h2", {}, sparkle(), " Suggested rooms"), el("p", { class: "muted", text: "The Assistant is sorting your accessories into rooms…" }))));
    host.prepend(panel);
    panel.classList.add("ai-busy");
    let result;
    try {
      result = await app.api("/api/rooms/suggest", { method: "POST", body: {} });
    } catch (e) {
      panel.replaceChildren(el("p", { class: "error", text: e.message }), el("div", { class: "actions" }, el("button", { text: "Close", onclick: () => panel.remove() })));
      return;
    } finally { panel.classList.remove("ai-busy"); }
    const byID = new Map(accessories.map((a) => [a.id, a]));
    const checks = [];
    const check = (data, label, detail) => {
      const input = el("input", { type: "checkbox", checked: true });
      checks.push({ input, data });
      return el("label", { class: "toggle compact" }, input, el("span", {}, el("span", { text: label }), detail ? el("span", { class: "help", text: detail }) : null));
    };
    const rooms = result.rooms.filter((room) => room.accessories.length).map((room) => el("div", { class: "suggest-room" },
      el("div", { class: "service-name", text: room.name }),
      room.accessories.map((id) => {
        const accessory = byID.get(id);
        const moved = accessory?.room && accessory.room !== room.name ? `now in ${accessory.room}` : accessory?.room === room.name ? "already there" : null;
        return check({ id, room: room.name }, accessory ? displayName(accessory) : id, moved);
      })));
    const renames = result.renames.map((rename) => check({ id: rename.id, name: rename.name }, `${rename.current} → ${rename.name}`, rename.reason));
    const orphans = result.orphans.map((orphan) => el("li", {}, el("strong", { text: orphan.name }), ` ${orphan.reason}`));
    const line = statusLine();
    const apply = el("button", { class: "primary", text: "Apply what is ticked", onclick: async () => {
      const changes = {};
      for (const { input, data } of checks) {
        if (!input.checked) continue;
        changes[data.id] = { ...changes[data.id], ...(data.room ? { room: data.room } : { name: data.name }) };
      }
      apply.disabled = true;
      try { await changeLayout({ accessories: changes }); app.route(); } catch (e) { say(line, e.message, "error"); apply.disabled = false; }
    } });
    panel.replaceChildren(
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", {}, sparkle(), " Suggested rooms"),
          el("p", { class: "muted", text: `From ${result.model}. Untick what you do not want; nothing changes until you apply. Names show on these pages only: the Home app keeps its own.` })),
        el("button", { class: "link", text: "Dismiss", onclick: () => panel.remove() })),
      rooms.length ? el("div", { class: "suggest-rooms" }, rooms) : el("p", { class: "muted", text: "No room to suggest." }),
      renames.length ? el("div", {}, el("div", { class: "service-name", text: "Clearer names" }), renames) : null,
      orphans.length ? el("div", {}, el("div", { class: "service-name", text: "Worth a look" }), el("ul", { class: "help" }, orphans)) : null,
      el("div", { class: "actions" }, apply), line);
  }

  // ---- Quick Controls --------------------------------------------------------------------------------

  /// The favourite accessories by room, and the scenes to run: a section of the Status page, and the whole of
  /// /quick (a page for a phone's home screen). Draws once its data is there.
  function quickSection(accessories, { standalone = false } = {}) {
    const section = el("section", { class: "quick" });
    (async () => {
      const [list, scenes] = await Promise.all([
        accessories ? Promise.resolve(accessories) : app.api("/api/accessories").then((all) => app.withSlugs(all, "accessory")),
        app.api("/api/scenes").then((answer) => answer.scenes).catch(() => []),
      ]);
      const favourites = list.filter((a) => a.favourite && !a.hidden);
      if (!favourites.length && !scenes.length) {
        if (standalone) section.append(el("div", { class: "card empty" }, el("p", { class: "muted", text: "Nothing here yet. On the Accessories page, a card's menu adds it to the Quick Controls; scenes you make show here too." })));
        return;
      }
      const rooms = [...new Set(favourites.map((a) => a.room).filter(Boolean))];
      // `append` is the DOM's: it writes null and arrays as text, so the parts go in flat and without the empty ones.
      section.append(...[
        standalone ? null : el("div", { class: "section-head" }, el("h2", { text: "Quick controls" }), el("a", { href: "/quick", class: "muted", text: "Open on its own" })),
        scenes.length ? el("div", { class: "quick-scenes" }, scenes.map((scene) => sceneButton(scene))) : null,
        groupByRoom(favourites, rooms).map(([room, members]) => [
          rooms.length ? el("div", { class: "service-name", text: room }) : null,
          // The accessories' widgets, as the Accessories page draws them.
          el("div", { class: "wall" }, members.map((accessory) => app.accessoryCard(accessory))),
        ]),
      ].flat(2).filter(Boolean));
    })().catch((e) => section.append(el("p", { class: "error", text: e.message })));
    return section;
  }

  function sceneButton(scene) {
    const button = el("button", { class: "scene-run", title: `Run ${scene.name}` }, tile("play", scene.security ? "violet" : "orange"), el("span", { text: scene.name }));
    button.addEventListener("click", () => runScene(scene, button));
    return button;
  }

  /// Runs a scene; one that changes a lock, a door or an alarm asks first, as the cards' own controls do.
  async function runScene(scene, button) {
    let confirmSecurity = false;
    if (scene.security) {
      const which = scene.actions.filter((a) => a.security).map((a) => `${a.name || a.id}: ${a.characteristic}`).join(", ");
      if (!confirm(`${scene.name} changes a lock, a door or an alarm (${which}). Run it?`)) return;
      confirmSecurity = true;
    }
    button?.classList.add("busy");
    if (button) button.disabled = true;
    try {
      const result = await app.api(`/api/scenes/${encodeURIComponent(scene.id)}/run`, { method: "POST", body: { confirmSecurity } });
      if (!result.ok) {
        const failures = result.results.filter((r) => !r.ok).map((r) => `${r.name || r.id} ${r.characteristic}: ${r.error || r.skipped}`);
        alert(`${scene.name} ran, but not everything worked:\n${failures.join("\n")}`);
      }
      return result;
    } catch (e) { alert(e.message); } finally {
      button?.classList.remove("busy");
      if (button) button.disabled = false;
    }
  }

  // ---- Scenes ----------------------------------------------------------------------------------------

  const timeFormat = new Intl.DateTimeFormat([], { hour: "2-digit", minute: "2-digit" });
  const dateTimeFormat = new Intl.DateTimeFormat([], { dateStyle: "medium", timeStyle: "short" });

  function describeDays(days) {
    if (!days || !days.length || days.length === 7) return "every day";
    const key = [...days].sort().join();
    if (key === "1,2,3,4,5") return "on weekdays";
    if (key === "0,6") return "at weekends";
    return `on ${days.map((d) => weekdays[d]).join(", ")}`;
  }
  function describeOffset(minutes) {
    if (!minutes) return "";
    return `${Math.abs(minutes)} min ${minutes < 0 ? "before" : "after"} `;
  }
  function describeTrigger(trigger, names) {
    const off = trigger.enabled === false ? " (off)" : "";
    switch (trigger.type) {
      case "time": return `At ${trigger.at} ${describeDays(trigger.days)}${off}`;
      case "sun": return `${describeOffset(trigger.offsetMinutes)}${trigger.event} ${describeDays(trigger.days)}${off}`.replace(/^./, (c) => c.toUpperCase());
      case "cron": return `Cron ${trigger.cron}${off}`;
      case "characteristic": {
        const who = names.get(trigger.id) || trigger.id;
        const how = trigger.operator === "changes" ? "changes" : `${operators.find(([o]) => o === trigger.operator)?.[1] ?? trigger.operator} ${trigger.value}`;
        return `When ${who} ${trigger.characteristic} ${how}${off}`;
      }
      default: return trigger.type;
    }
  }

  async function scenesView(main) {
    const [data, accessories] = await Promise.all([app.api("/api/scenes"), app.api("/api/accessories")]);
    const names = new Map(accessories.map((a) => [a.id, displayName(a)]));
    const card = (scene) => {
      const actions = scene.actions.slice(0, 4).map((action) => el("div", { class: "control" },
        el("span", { text: `${action.name || action.id}${action.missing ? " (gone)" : ""}` }),
        el("span", { class: "value", text: `${action.characteristic} → ${typeof action.value === "boolean" && !app.enumLabels[action.characteristic] ? (action.value ? "On" : "Off") : app.labelFor(action.characteristic, action.value)}` })));
      const more = scene.actions.length > 4 ? el("p", { class: "muted note", text: `and ${scene.actions.length - 4} more` }) : null;
      const last = scene.lastRun ? `Last run ${dateTimeFormat.format(new Date(scene.lastRun.at))} (${scene.lastRun.trigger})${scene.lastRun.ok ? "" : ", with errors"}` : "Never run";
      const run = el("button", { class: "primary", text: "Run" });
      run.addEventListener("click", async () => { await runScene(scene, run); });
      return el("div", { class: "card server scene-card" },
        el("div", { class: "server-head" }, tile("play", scene.security ? "violet" : "orange"),
          el("div", { class: "who" }, el("a", { class: "card-title", href: `/scenes/${encodeURIComponent(scene.id)}` }, el("strong", { text: scene.name })),
            el("div", { class: "muted", text: scene.triggers.length ? scene.triggers.map((t) => describeTrigger(t, names)).join(" · ") : "Run by hand" })),
          run),
        el("div", { class: "controls" }, actions), more,
        scene.security ? el("p", { class: "muted note", text: "It changes a lock, a door or an alarm: the page asks before running it, and automations leave those actions out." }) : null,
        el("div", { class: "card-foot" }, el("span", { class: "muted", text: scene.lastSkipped && (!scene.lastRun || scene.lastSkipped.at > scene.lastRun.at) ? `Skipped ${dateTimeFormat.format(new Date(scene.lastSkipped.at))}: ${scene.lastSkipped.reason}` : last }),
          menuButton(`Actions for ${scene.name}`, () => [
            { label: "Run", icon: "play", onSelect: () => runScene(scene) },
            { label: "Edit", icon: "edit", href: `/scenes/${encodeURIComponent(scene.id)}` },
            { label: "Delete", icon: "trash", danger: true, onSelect: async () => {
              if (!confirm(`Delete the scene ${scene.name}?`)) return;
              try { await app.api(`/api/scenes/${encodeURIComponent(scene.id)}`, { method: "DELETE" }); app.route(); } catch (e) { alert(e.message); }
            } },
          ])));
    };
    app.show(main,
      app.pageHead("Scenes", "Accessory values set together, by hand or on a schedule, at sunrise or sunset, or when an accessory changes. Homeswift keeps them; the Home app does not see them.",
        el("a", { class: "button primary", href: "/scenes/new", text: "New scene" })),
      data.scenes.length ? el("div", { class: "grid" }, data.scenes.map(card))
        : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No scene yet. A scene sets several accessories at once, such as every light of a room for the evening." })),
      locationCard(data));
  }

  /// Where sunrise and sunset are computed for: Glass UI took its weather widget's city; here it is typed, or
  /// this device's position.
  function locationCard(data) {
    const location = data.location;
    const lat = el("input", { type: "number", step: "any", min: -90, max: 90, value: location?.lat ?? "", "aria-label": "Latitude" });
    const lon = el("input", { type: "number", step: "any", min: -180, max: 180, value: location?.lon ?? "", "aria-label": "Longitude" });
    const name = el("input", { type: "text", value: location?.name ?? "", placeholder: "Home", maxLength: 64 });
    const line = statusLine();
    const save = async (body) => {
      try { await app.api("/api/scenes/location", { method: "PUT", body }); app.route(); } catch (e) { say(line, e.message, "error"); }
    };
    const here = el("button", { text: "Use this device's location", onclick: () => {
      if (!navigator.geolocation) return say(line, "This browser cannot tell its location.", "error");
      say(line, "Asking the browser…");
      navigator.geolocation.getCurrentPosition(
        (position) => { lat.value = position.coords.latitude.toFixed(4); lon.value = position.coords.longitude.toFixed(4); say(line, "Found: save to keep it."); },
        (error) => say(line, error.message || "The browser did not give its location (it needs HTTPS away from localhost).", "error"));
    } });
    const next = location ? `Next sunrise ${data.nextSunrise ? timeFormat.format(new Date(data.nextSunrise)) : "—"}, sunset ${data.nextSunset ? timeFormat.format(new Date(data.nextSunset)) : "—"}.` : "No location yet: sunrise and sunset triggers wait for one.";
    return el("details", { class: "card location", open: !location && data.scenes.some((s) => s.triggers.some((t) => t.type === "sun")) },
      el("summary", {}, el("strong", { text: "Location for sunrise and sunset" }), el("span", { class: "muted", text: ` · ${location ? (location.name || `${location.lat}, ${location.lon}`) : "not set"}` })),
      el("p", { class: "muted", text: next }),
      el("div", { class: "fields" }, field("Latitude", lat), field("Longitude", lon), field("Name", name, "Only for you to recognise it.")),
      el("div", { class: "actions" },
        el("button", { class: "primary", text: "Save", onclick: () => save({ lat: Number(lat.value), lon: Number(lon.value), name: name.value }) }),
        here, location ? el("button", { class: "link", text: "Forget it", onclick: () => save(null) }) : null),
      line);
  }

  /// The characteristics of an accessory a scene can set: writable, not HomeKit's plumbing.
  function writable(accessory) {
    return accessory.services.filter((s) => !s.internal).flatMap((service) => service.characteristics
      .filter((c) => c.permissions.includes("pw") && c.permissions.includes("pr") && !c.internal && !["Identify", "Name", "Configured Name"].includes(c.type))
      .map((c) => ({ ...c, service: service.subtype || service.type, serviceName: service.name || service.type })));
  }
  function readable(accessory) {
    return accessory.services.filter((s) => !s.internal).flatMap((service) => service.characteristics
      .filter((c) => c.permissions.includes("pr") && !c.internal && !c.confidential && !["Identify", "Name", "Configured Name"].includes(c.type))
      .map((c) => ({ ...c, service: service.subtype || service.type, serviceName: service.name || service.type })));
  }

  /// An input for a characteristic's value: a menu for booleans and enumerations, a number within its range,
  /// else text. `.read()` gives the value to save.
  function valueInput(characteristic, value) {
    const labels = app.enumLabels[characteristic?.type];
    let input;
    if (characteristic?.format === "bool") {
      input = el("select", {}, el("option", { value: "true", text: "On" }), el("option", { value: "false", text: "Off" }));
      input.value = String(value === true || value === 1);
      input.read = () => input.value === "true";
    } else if (characteristic && (characteristic.validValues || labels)) {
      const values = characteristic.validValues || labels.map((_, index) => index);
      input = el("select", {}, values.map((v) => el("option", { value: v, text: app.labelFor(characteristic.type, v) })));
      input.value = String(value ?? values[0]);
      input.read = () => Number(input.value);
    } else if (characteristic && characteristic.format !== "string") {
      input = el("input", { type: "number", min: characteristic.minValue, max: characteristic.maxValue, step: characteristic.minStep || "any", value: value ?? characteristic.value ?? 0 });
      input.read = () => Number(input.value);
    } else {
      input = el("input", { type: "text", value: value ?? "", maxLength: 256 });
      // An accessory that is gone keeps its value as it was saved.
      input.read = () => !characteristic && input.value === String(value ?? "") && value !== undefined ? value : input.value;
    }
    input.setAttribute("aria-label", "Value");
    return input;
  }

  /// An accessory and one of its characteristics, with a value input after them when `withValue`.
  function characteristicPicker(accessories, pick, { id, characteristic, value, withValue = true, list = writable }) {
    const options = accessories.filter((a) => list(a).length);
    const accessory = el("select", { "aria-label": "Accessory" }, options.map((a) => el("option", { value: a.id, text: displayName(a) })));
    const kind = el("select", { "aria-label": "Characteristic" });
    const holder = el("span", { class: "value-slot" });
    let current = null;
    const fill = (keepType, keepValue) => {
      const found = options.find((a) => a.id === accessory.value);
      const chars = found ? list(found) : [];
      kind.replaceChildren(...chars.map((c, index) => el("option", { value: index, text: chars.filter((x) => x.type === c.type).length > 1 ? `${c.type} (${c.serviceName})` : c.type })));
      // An accessory that is gone keeps the characteristic it was saved with.
      if (!chars.length && (keepType ?? characteristic)) kind.append(el("option", { value: 0, text: keepType ?? characteristic }));
      const index = Math.max(0, chars.findIndex((c) => c.type === keepType));
      kind.value = String(index);
      current = chars[index] || null;
      if (withValue) { holder.replaceChildren(pick.value = valueInput(current, keepValue ?? current?.value)); }
    };
    if (id && options.some((a) => a.id === id)) accessory.value = id;
    else if (id) accessory.prepend(el("option", { value: id, text: `${id} (gone)`, selected: true }));
    fill(characteristic, value);
    accessory.addEventListener("change", () => fill());
    kind.addEventListener("change", () => {
      const found = options.find((a) => a.id === accessory.value);
      current = found ? list(found)[Number(kind.value)] : null;
      if (withValue) holder.replaceChildren(pick.value = valueInput(current, current?.value));
    });
    pick.read = () => {
      const found = options.find((a) => a.id === accessory.value);
      if (!found || !current) return { id: accessory.value, characteristic: characteristic || "" };
      const several = list(found).filter((c) => c.type === current.type).length > 1;
      return { id: found.id, characteristic: current.type, ...(several ? { service: current.service } : {}) };
    };
    pick.current = () => current;
    return [accessory, kind, holder];
  }

  const rowShell = (...children) => el("div", { class: "editor-row" }, ...children);
  const removeButton = (row, list) => el("button", { class: "icon-button", type: "button", title: "Remove", "aria-label": "Remove", onclick: () => { list.delete(row); row.remove(); } }, HomeswiftCommon.icon("trash"));

  function daysPicker(days) {
    const chosen = new Set(days && days.length ? days : [0, 1, 2, 3, 4, 5, 6]);
    const node = el("span", { class: "days", role: "group", "aria-label": "Days" }, weekdays.map((name, day) => {
      const box = el("input", { type: "checkbox", checked: chosen.has(day), "aria-label": name });
      box.addEventListener("change", () => { if (box.checked) chosen.add(day); else chosen.delete(day); });
      return el("label", { class: "day" }, box, el("span", { text: name.slice(0, 2) }));
    }));
    node.read = () => chosen.size === 7 || chosen.size === 0 ? undefined : [...chosen].sort();
    return node;
  }

  function timeOfDay(value) {
    const sun = ["sunrise", "sunset"].includes(value);
    const kind = el("select", { "aria-label": "When" }, el("option", { value: "time", text: "At" }), el("option", { value: "sunrise", text: "Sunrise" }), el("option", { value: "sunset", text: "Sunset" }));
    kind.value = sun ? value : "time";
    const time = el("input", { type: "time", value: sun ? "00:00" : value || "18:00", "aria-label": "Time" });
    time.classList.toggle("hidden", sun);
    kind.addEventListener("change", () => time.classList.toggle("hidden", kind.value !== "time"));
    const node = el("span", { class: "group-inline" }, kind, time);
    node.read = () => kind.value === "time" ? time.value : kind.value;
    return node;
  }

  async function sceneEditor(main, id) {
    const isNew = id === "new";
    const [data, accessories] = await Promise.all([app.api("/api/scenes"), app.api("/api/accessories")]);
    const scene = isNew ? { name: "", actions: [], triggers: [], conditions: [] } : data.scenes.find((s) => s.id === id);
    if (!scene) { app.show(main, el("p", { class: "error", text: "No such scene." })); return; }
    const choices = accessories.filter((a) => !a.hidden || scene.actions.some((x) => x.id === a.id));

    const name = el("input", { type: "text", value: scene.name, maxLength: 64, required: true, placeholder: "Evening" });
    const actions = new Set(), triggers = new Set(), conditions = new Set();
    const actionList = el("div", { class: "editor-list" }), triggerList = el("div", { class: "editor-list" }), conditionList = el("div", { class: "editor-list" });

    const addAction = (action = {}) => {
      const pick = {};
      const row = rowShell(...characteristicPicker(choices, pick, { id: action.id, characteristic: action.characteristic, value: action.value }));
      row.read = () => ({ ...pick.read(), value: pick.value.read() });
      row.append(removeButton(row, actions));
      actions.add(row);
      actionList.append(row);
    };
    const addTrigger = (trigger = { type: "time", at: "18:00" }) => {
      const type = el("select", { "aria-label": "Trigger" },
        el("option", { value: "time", text: "At a time" }), el("option", { value: "sun", text: "Sunrise or sunset" }),
        el("option", { value: "characteristic", text: "When an accessory changes" }), el("option", { value: "cron", text: "Cron" }));
      type.value = trigger.type;
      const enabled = el("input", { type: "checkbox", checked: trigger.enabled !== false, "aria-label": "On" });
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(type, body, el("label", { class: "toggle compact" }, enabled, el("span", { text: "On" })));
      const draw = (t) => {
        if (t.type === "time") {
          const at = el("input", { type: "time", value: t.at || "18:00", "aria-label": "Time" });
          const days = daysPicker(t.days);
          body.replaceChildren(at, days);
          row.readBody = () => ({ at: at.value, days: days.read() });
        } else if (t.type === "sun") {
          const event = el("select", { "aria-label": "Event" }, el("option", { value: "sunrise", text: "Sunrise" }), el("option", { value: "sunset", text: "Sunset" }));
          event.value = t.event || "sunset";
          const offset = el("input", { type: "number", min: -720, max: 720, step: 1, value: t.offsetMinutes ?? 0, "aria-label": "Minutes after (negative: before)", title: "Minutes after; negative for before" });
          const days = daysPicker(t.days);
          body.replaceChildren(event, offset, el("span", { class: "muted", text: "min" }), days);
          row.readBody = () => ({ event: event.value, offsetMinutes: Number(offset.value) || 0, days: days.read() });
        } else if (t.type === "characteristic") {
          const pick = {};
          const operator = el("select", { "aria-label": "Condition" }, el("option", { value: "changes", text: "changes" }), operators.map(([value, text]) => el("option", { value, text })));
          operator.value = t.operator || "changes";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: t.id, characteristic: t.characteristic, value: t.value, list: readable });
          holder.classList.toggle("hidden", operator.value === "changes");
          operator.addEventListener("change", () => holder.classList.toggle("hidden", operator.value === "changes"));
          body.replaceChildren(accessory, kind, operator, holder);
          row.readBody = () => ({ ...pick.read(), operator: operator.value, ...(operator.value === "changes" ? {} : { value: pick.value.read() }) });
        } else {
          const cron = el("input", { type: "text", value: t.cron || "0 7 * * 1-5", placeholder: "0 7 * * 1-5", "aria-label": "Cron expression", class: "mono" });
          body.replaceChildren(cron);
          row.readBody = () => ({ cron: cron.value });
        }
      };
      draw(trigger);
      type.addEventListener("change", () => draw({ type: type.value }));
      row.read = () => ({ type: type.value, ...(enabled.checked ? {} : { enabled: false }), ...row.readBody() });
      row.append(removeButton(row, triggers));
      triggers.add(row);
      triggerList.append(row);
    };
    const addCondition = (condition = { type: "time", after: "sunset", before: "23:00" }) => {
      const type = el("select", { "aria-label": "Condition" }, el("option", { value: "time", text: "Between" }), el("option", { value: "characteristic", text: "Only if" }));
      type.value = condition.type;
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(type, body);
      const draw = (c) => {
        if (c.type === "time") {
          const after = timeOfDay(c.after || "sunset"), before = timeOfDay(c.before || "23:00");
          body.replaceChildren(after, el("span", { class: "muted", text: "and" }), before);
          row.readBody = () => ({ after: after.read(), before: before.read() });
        } else {
          const pick = {};
          const operator = el("select", { "aria-label": "Comparison" }, operators.map(([value, text]) => el("option", { value, text })));
          operator.value = c.operator || "eq";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: c.id, characteristic: c.characteristic, value: c.value, list: readable });
          body.replaceChildren(accessory, kind, operator, holder);
          row.readBody = () => ({ ...pick.read(), operator: operator.value, value: pick.value.read() });
        }
      };
      draw(condition);
      type.addEventListener("change", () => draw({ type: type.value }));
      row.read = () => ({ type: type.value, ...row.readBody() });
      row.append(removeButton(row, conditions));
      conditions.add(row);
      conditionList.append(row);
    };
    scene.actions.forEach(addAction);
    scene.triggers.forEach(addTrigger);
    scene.conditions.forEach(addCondition);
    if (isNew && choices.length) addAction();

    // A whole accessory's current state at once, as save_scene captures it.
    const capture = el("select", { "aria-label": "Add the current state of an accessory" }, el("option", { value: "", text: "Add an accessory as it is now…" }),
      choices.filter((a) => writable(a).length).map((a) => el("option", { value: a.id, text: displayName(a) })));
    capture.addEventListener("change", () => {
      const accessory = choices.find((a) => a.id === capture.value);
      capture.value = "";
      if (!accessory) return;
      for (const c of writable(accessory)) if (!c.security && c.value !== null && c.value !== undefined) addAction({ id: accessory.id, characteristic: c.type, value: c.value });
    });

    const line = statusLine();
    const save = el("button", { class: "primary", type: "submit", text: isNew ? "Create the scene" : "Save" });
    const form = el("form", { class: "card scene-editor", onsubmit: async (event) => {
      event.preventDefault();
      const body = { name: name.value.trim(), actions: [...actions].map((row) => row.read()), triggers: [...triggers].map((row) => row.read()), conditions: [...conditions].map((row) => row.read()) };
      save.disabled = true;
      try {
        const saved = await app.api(isNew ? "/api/scenes" : `/api/scenes/${encodeURIComponent(scene.id)}`, { method: isNew ? "POST" : "PUT", body });
        const security = saved.actions.some((a) => a.security);
        if (security && body.triggers.some((t) => t.enabled !== false)) {
          say(line, "Saved. Its lock, door or alarm actions run only when you run it here: automations leave them out.", "ok");
          if (isNew) setTimeout(() => app.navigate(`/scenes/${encodeURIComponent(saved.id)}`, { replace: true }), 1500);
        } else {
          app.navigate("/scenes");
        }
      } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    } },
      field("Name", name),
      el("h2", { text: "Actions" }), el("p", { class: "muted", text: "The values to set, in this order." }), actionList,
      el("div", { class: "actions" }, el("button", { type: "button", text: "Add an action", onclick: () => addAction() }), capture),
      el("h2", { text: "Triggers" }), el("p", { class: "muted", text: data.location ? `Run it automatically. Sunrise and sunset are for ${data.location.name || `${data.location.lat}, ${data.location.lon}`}.` : "Run it automatically. Sunrise and sunset need a location: set it on the Scenes page." }),
      triggerList, el("div", { class: "actions" }, el("button", { type: "button", text: "Add a trigger", onclick: () => addTrigger() })),
      el("h2", { text: "Conditions" }), el("p", { class: "muted", text: "An automatic run goes ahead only when all of these hold. Running it by hand ignores them." }),
      conditionList, el("div", { class: "actions" }, el("button", { type: "button", text: "Add a condition", onclick: () => addCondition() })),
      el("div", { class: "save-bar" }, save, el("a", { class: "button", href: "/scenes", text: "Cancel" }),
        isNew ? null : el("span", { class: "spacer" }),
        isNew ? null : el("button", { type: "button", class: "danger", text: "Delete", onclick: async () => {
          if (!confirm(`Delete the scene ${scene.name}?`)) return;
          try { await app.api(`/api/scenes/${encodeURIComponent(scene.id)}`, { method: "DELETE" }); app.navigate("/scenes"); } catch (e) { say(line, e.message, "error"); }
        } })),
      line);
    app.show(main, app.breadcrumb(["Scenes", "/scenes"], [isNew ? "New scene" : scene.name]), form);
  }

  // ---- Notifications ---------------------------------------------------------------------------------

  const channelInfo = {
    webhook: ["Webhook", "A JSON POST to a URL of yours: event, title, message, instance, timestamp.", [["url", "URL", "https://…", true]]],
    ntfy: ["ntfy", "A topic on ntfy.sh or your own ntfy server; the app shows it on a phone.", [["server", "Server", "https://ntfy.sh"], ["topic", "Topic", "homeswift-…"], ["token", "Access token", "for a protected topic", true]]],
    pushover: ["Pushover", "Your user key and an application token from pushover.net.", [["userKey", "User key", "", true], ["appToken", "Application token", "", true]]],
    telegram: ["Telegram", "A bot's token from @BotFather, and the chat it writes to.", [["botToken", "Bot token", "123456:ABC…", true], ["chatId", "Chat id", "-100… or @channel"]]],
    browser: ["This browser and others", "Web Push to the browsers that turned it on below. It needs HTTPS (or localhost).", []],
  };

  /// A short name for this browser: "Safari on macOS".
  function browserLabel() {
    const ua = navigator.userAgent;
    const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
    const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
    return os ? `${browser} on ${os}` : browser;
  }
  const keyBytes = (base64url) => Uint8Array.from(atob(base64url.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((base64url.length + 3) % 4)), (c) => c.charCodeAt(0));
  const pushSupported = () => window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

  async function currentSubscription() {
    if (!pushSupported()) return null;
    const registration = await navigator.serviceWorker.getRegistration("/");
    return registration ? registration.pushManager.getSubscription() : null;
  }

  async function notificationsView(main) {
    const settings = await app.api("/api/notifications");
    const line = statusLine();
    const inputs = {};
    const test = async (channel) => {
      say(line, "Sending…");
      try {
        const answer = await app.api("/api/notifications/test", { method: "POST", body: channel ? { channel } : {} });
        const failed = answer.results.filter((r) => !r.ok);
        say(line, failed.length ? failed.map((r) => `${r.channel}: ${r.error}`).join("; ") : `Sent through ${answer.results.map((r) => r.channel).join(", ")}.`, failed.length ? "error" : "ok");
      } catch (e) { say(line, e.message, "error"); }
    };
    const cards = Object.entries(channelInfo).map(([channel, [title, help, fields]]) => {
      const values = settings.channels[channel];
      const enabled = el("input", { type: "checkbox", checked: values.enabled, "aria-label": `${title} on` });
      inputs[channel] = { enabled };
      const rows = fields.map(([key, label, placeholder, secret]) => {
        const input = el("input", { type: secret ? "password" : "text", value: values[key] ?? "", placeholder, autocomplete: "off", spellcheck: false });
        inputs[channel][key] = input;
        return field(label, input);
      });
      return el("div", { class: "card server" },
        el("div", { class: "server-head" }, tile(channel === "browser" ? "accessory" : "bell", channel === "browser" ? "blue" : "orange"),
          el("div", { class: "who" }, el("strong", { text: title })),
          el("label", { class: "switch" }, enabled, el("span"))),
        el("p", { class: "muted note", text: help }),
        rows.length ? el("div", {}, rows) : browserPanel(settings),
        el("div", { class: "card-foot" }, el("span", { class: "muted", text: values.enabled ? "On" : "Off" }),
          menuButton(`Actions for ${title}`, () => [{ label: "Send a test", icon: "bell", onSelect: () => test(channel) }])));
    });
    const events = settings.events.map((event) => {
      const box = el("input", { type: "checkbox", checked: event.enabled });
      box.dataset.event = event.name;
      return el("label", { class: "toggle" }, box, el("span", {}, el("span", { text: event.label }),
        event.name === "dailyDigest" && !settings.assistant ? el("span", { class: "help", text: "Needs the Assistant (a HomeswiftAiKit block)." }) : null));
    });
    const digestTime = el("input", { type: "time", value: settings.dailyDigestTime, "aria-label": "Daily digest time" });
    const save = el("button", { class: "primary", text: "Save" });
    save.addEventListener("click", async () => {
      const channels = {};
      for (const [channel, fields] of Object.entries(inputs)) {
        channels[channel] = {};
        for (const [key, input] of Object.entries(fields)) channels[channel][key] = input.type === "checkbox" ? input.checked : input.value;
      }
      const body = { channels, events: Object.fromEntries([...main.querySelectorAll("[data-event]")].map((box) => [box.dataset.event, box.checked])), dailyDigestTime: digestTime.value };
      save.disabled = true;
      try { await app.api("/api/notifications", { method: "PUT", body }); say(line, "Saved.", "ok"); } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    });
    app.show(main,
      app.pageHead("Notifications", "What the bridge tells you when you are not looking: it started or stopped, a plugin reported an error, an accessory stopped responding, an automation failed."),
      el("div", { class: "grid" }, cards),
      el("div", { class: "card" }, el("h2", { text: "Events" }),
        el("p", { class: "muted", text: "The same event about the same thing goes out once per 15 minutes at most, and 12 notifications an hour at most." }),
        events, field("Daily digest at", digestTime)),
      el("div", { class: "save-bar" }, save, el("button", { text: "Send a test to every channel that is on", onclick: () => test() })), line);
  }

  /// This browser's subscription and the others'.
  function browserPanel(settings) {
    const box = el("div", { class: "push" });
    const line = statusLine();
    const others = el("div", {}, settings.subscriptions.map((sub) => el("div", { class: "control" },
      el("span", { text: `${sub.label}${sub.username ? ` · ${sub.username}` : ""}` }),
      el("button", { class: "link", text: "Remove", onclick: async () => {
        try { await app.api(`/api/notifications/push/subscriptions/${encodeURIComponent(sub.id)}`, { method: "DELETE" }); app.route(); } catch (e) { say(line, e.message, "error"); }
      } }))));
    if (!pushSupported()) {
      box.append(el("p", { class: "muted note", text: window.isSecureContext ? "This browser cannot receive push notifications." : "Open this page over HTTPS (the HomeswiftUI block's https) or on localhost to turn them on here." }), others);
      return box;
    }
    const toggle = el("button", { text: "Checking…", disabled: true });
    const draw = (subscription) => {
      toggle.disabled = false;
      toggle.textContent = subscription ? "Turn off on this browser" : "Turn on for this browser";
      toggle.onclick = async () => {
        toggle.disabled = true;
        try {
          if (subscription) {
            await app.api("/api/notifications/push/unsubscribe", { method: "POST", body: { endpoint: subscription.endpoint } });
            await subscription.unsubscribe();
          } else {
            if (await Notification.requestPermission() !== "granted") throw new Error("The browser's notifications are blocked for this site.");
            const registration = await navigator.serviceWorker.register("/sw.js");
            await navigator.serviceWorker.ready;
            const { publicKey } = await app.api("/api/notifications/push");
            const created = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(publicKey) });
            await app.api("/api/notifications/push/subscribe", { method: "POST", body: { ...created.toJSON(), label: browserLabel() } });
          }
          app.route();
        } catch (e) { say(line, e.message, "error"); toggle.disabled = false; }
      };
    };
    currentSubscription().then(draw).catch(() => draw(null));
    const testHere = el("button", { class: "link", text: "Send a test here", onclick: async () => {
      const subscription = await currentSubscription();
      if (!subscription) return say(line, "This browser is not subscribed.", "error");
      try {
        const answer = await app.api("/api/notifications/push/test", { method: "POST", body: { endpoint: subscription.endpoint } });
        const result = answer.results[0];
        say(line, result.ok ? "Sent." : result.error, result.ok ? "ok" : "error");
      } catch (e) { say(line, e.message, "error"); }
    } });
    box.append(el("div", { class: "actions" }, toggle, testHere), others, line);
    return box;
  }

  // ---- Installing ------------------------------------------------------------------------------------

  window.HomeswiftHome = {
    install(context) {
      app = context;
      app.views.scenes = (main, [id]) => id ? sceneEditor(main, id) : scenesView(main);
      app.views.notifications = notificationsView;
      app.views.quick = async (main) => app.show(main, app.pageHead("Quick controls", "Your favourite accessories and the scenes, at hand."), quickSection(null, { standalone: true }));
    },
    layoutActions, groupByRoom, suggestRooms, quickSection, displayName,
  };
})();

"""#),
        "icon-192.png": WebFile(contentType: "image/png", base64: "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"),
        "icon-512.png": WebFile(contentType: "image/png", base64: "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"),
        "icon-maskable-512.png": WebFile(contentType: "image/png", base64: "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"),
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
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
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
    <label id="auth-otp" class="hidden">Code from your authenticator app <input name="otp" inputmode="numeric" autocomplete="one-time-code" spellcheck="false" placeholder="123 456" maxlength="9"></label>
    <label id="auth-setup-code" class="hidden">Set-up code <input name="setupCode" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="XXXX-XXXX"></label>
    <p class="error" id="auth-error"></p>
    <button type="submit" id="auth-submit">Sign in</button>
  </form>
</div>
<div id="app" class="hidden">
  <header>
    <a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a>
    <nav>
      <a href="/status">Status</a>
      <a href="/accessories">Accessories</a>
      <a href="/scenes">Scenes</a>
      <a href="/plugins">Plugins</a>
      <a href="/config">Config</a>
      <a href="/logs">Logs</a>
      <a href="/settings">Settings</a>
    </nav>
    <span class="spacer"></span>
    <button id="user" type="button" class="user-button" aria-haspopup="menu" aria-expanded="false" aria-label="Account menu"><span class="user-avatar" aria-hidden="true"></span><span class="user-name"></span></button>
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
<script src="/home.js"></script>
<script src="/admin.js"></script>
<script src="/app.js"></script>
</body>
</html>

"""#),
        "manifest.webmanifest": WebFile(contentType: "application/manifest+json", body: #"""
{
  "name": "Homeswift",
  "short_name": "Homeswift",
  "description": "The bridge's status, accessories, plugins and log.",
  "id": "/",
  "start_url": "/status",
  "scope": "/",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#e9edf6",
  "theme_color": "#e9edf6",
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" },
    { "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" }
  ],
  "shortcuts": [
    { "name": "Quick controls", "url": "/quick" },
    { "name": "Accessories", "url": "/accessories" },
    { "name": "Logs", "url": "/logs" }
  ]
}

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

  const { $, el, icon, tile, fact, markdown, sparkle, api, assistantRequest, formatTemperature, temperature } = HomeswiftCommon;

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
          // The answer as it is written, once it starts.
          const live = el("div", { class: "ai-live" }, entry.text ? markdown(entry.text) : el("p", { class: "ai-thinking", text: "Thinking about it…" }));
          entry.draw = () => { if (live.isConnected) live.replaceChildren(markdown(entry.text)); };
          card.replaceChildren(el("div", { class: "ai-inner" }, head("Assistant"), live));
          entry.pending.finally(() => { if (document.body.contains(card) && !card.classList.contains("hidden")) show(explanations.get(error)); });
          return;
        }
        if (entry.failed) {
          card.classList.add("failed");
          card.replaceChildren(el("div", { class: "ai-inner" }, head("Assistant"),
            el("p", { class: "error", text: entry.failed }),
            el("button", { class: "link", text: "Try again", onclick: () => { explanations.delete(error); explainNow(); } })));
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
      const explainNow = () => {
        const entry = { pending: null, text: "" };
        let scheduled = false;
        const onChunk = (text) => {
          entry.text += text;
          if (!scheduled) { scheduled = true; requestAnimationFrame(() => { scheduled = false; entry.draw?.(); }); }
        };
        entry.pending = assistantRequest("/api/assistant/explain", { error, context, device, plugin: platform }, { onChunk })
          .then((json) => { explanations.set(error, { text: json.text, model: json.model }); })
          .catch((e) => { explanations.set(error, { failed: e.message }); });
        explanations.set(error, entry);
        show(entry);
        card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
      };
      button.addEventListener("click", () => (explanations.has(error) ? show(explanations.get(error)) : explainNow()));
      box.replaceChildren(button, card);
      if (explanations.has(error)) show(explanations.get(error));
    });
    return box;
  }

  /// Asks the Assistant something about this plugin, its background going with the question (ai-kit's
  /// `/ai/ask`): resolves to `{ text, model }`. `onChunk(text)` gets the answer as it is written; an AbortSignal
  /// in `signal` stops it. Rejects when the Assistant is off (check `assistant()` first) or fails.
  const ask = (prompt, { context, onChunk, signal } = {}) =>
    assistantRequest("/api/assistant/ask", { prompt, context, plugin: platform }, { onChunk, signal });

  // The UI's own header on every plugin page, Plugins highlighted, so leaving a plugin's page is one click
  // anywhere; and a breadcrumb under it: Plugins › the plugin › (its instance) › what is open on the page.
  const sections = HomeswiftCommon.sections;
  const header = $("header");
  if (header) {
    // The account button and its menu, as on the UI's own pages.
    let auth = { mode: "none" };
    const avatar = el("span", { class: "user-avatar", "aria-hidden": "true" }, HomeswiftCommon.icon("user"));
    const userName = el("span", { class: "user-name" });
    const user = el("button", { id: "user", type: "button", class: "user-button", "aria-haspopup": "menu", "aria-expanded": "false", "aria-label": "Account menu" }, avatar, userName);
    const shownName = () => (auth.mode === "form" ? (auth.name && auth.name !== auth.username ? auth.name : auth.username || "") : "");
    user.addEventListener("click", (event) => {
      event.stopPropagation();
      const form = auth.mode === "form";
      HomeswiftCommon.menu(user, [
        form ? { heading: shownName(), detail: `${auth.username}${auth.admin ? " · Administrator" : ""}` } : { heading: "No sign-in", detail: "Anyone who opens this web UI uses it" },
        { label: form ? "Your account" : "Account", icon: "user", href: "/account" },
        { label: "Appearance", icon: "sliders", href: "/appearance" },
        form && auth.admin ? { label: "Users and tokens", icon: "users", href: "/users" } : null,
        form ? { separator: true } : null,
        form ? { label: "Sign out", icon: "logout", onSelect: async () => {
          try { await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }); } catch {}
          location.href = "/";
        } } : null,
      ], { keyboard: event.detail === 0 });
    });
    header.replaceChildren(
      el("a", { class: "brand", href: "/", "aria-label": "Homeswift", title: "Homeswift" }, el("img", { src: "/icon.svg", class: "logo", alt: "" })),
      el("nav", { "aria-label": "Sections" }, sections.map(([path, text]) => el("a", { href: path, text, class: path === "/plugins" ? "active" : "" }))),
      el("span", { class: "spacer" }), user);
    // On a phone the sections sit in a tab bar at the bottom, as on the UI's own pages; the page also extends
    // under the notch and the home indicator, which the layout pads around.
    HomeswiftCommon.tabBar({ active: "/plugins" });
    const viewport = document.querySelector('meta[name="viewport"]');
    if (viewport && !viewport.content.includes("viewport-fit")) viewport.content += ", viewport-fit=cover";
    // The Assistant's chat, as on the UI's own pages.
    document.head.append(el("script", { src: "/chat.js" }));
    // The user's theme, wallpaper and temperature unit, as on the UI's own pages.
    HomeswiftCommon.loadPreferences();
    api("/api/auth/state").then((state) => {
      auth = state;
      const name = shownName();
      avatar.replaceChildren(auth.mode === "form" && name ? name.slice(0, 1).toUpperCase() : HomeswiftCommon.icon("user"));
      userName.textContent = name;
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
    platform, name, request, home: "/plugins", $, el, icon, tile, fact, assistant, explain, ask, breadcrumb, api, act, formatTemperature, temperature,
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
  :root:not(:where([data-theme="light"])) {
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
/* A theme chosen in the web UI (/appearance) rather than the system's: common.js sets data-theme. */
:root:where([data-theme="light"]) { color-scheme: light; }
:root:where([data-theme="dark"]) {
  color-scheme: dark;
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
/* The account button at the header's right end: the user's initial on the accent and their name, opening its menu. */
.user-button {
  flex: none; display: inline-flex; align-items: center; gap: 8px; padding: 3px 12px 3px 3px; max-width: 14em;
  border: 0; border-radius: 999px; background: none; box-shadow: none; color: var(--text); font-weight: 500;
}
.user-button:hover, .user-button[aria-expanded="true"] { background: var(--material-thin); transform: none; }
.user-avatar {
  flex: none; display: grid; place-items: center; width: 30px; height: 30px; border-radius: 50%;
  font-size: 0.875rem; font-weight: 650; color: var(--accent-text);
  background: linear-gradient(145deg, var(--accent-2), var(--accent)); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.45), 0 2px 8px rgba(255, 122, 26, 0.3);
}
.user-avatar svg { width: 17px; height: 17px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.user-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
/* Without sign-in there is no name: the avatar alone, round. */
.user-name:empty { display: none; }
.user-button:has(.user-name:empty) { padding: 3px; }
.menu-heading { display: grid; gap: 2px; padding: 8px 12px 10px; margin-bottom: 4px; border-bottom: 1px solid var(--line); }
.menu-heading strong { font-size: 0.9375rem; }
.menu-heading span { color: var(--muted); font-size: 0.8125rem; }
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
.stack { display: grid; gap: 14px; align-content: start; min-width: 0; }
.check { display: flex; gap: 8px; align-items: center; margin: 14px 0 4px; font-weight: 500; }
.secret { word-break: break-all; user-select: all; }
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
  :root:not(:where([data-theme="light"])) { --chevron: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 16' fill='none' stroke='%23a2a9b5' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M2 6l3-3 3 3M2 10l3 3 3-3'/%3E%3C/svg%3E"); }
}
:root:where([data-theme="dark"]) { --chevron: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 16' fill='none' stroke='%23a2a9b5' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M2 6l3-3 3 3M2 10l3 3 3-3'/%3E%3C/svg%3E"); }
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
.md .md-table { margin: 8px 0; overflow-x: auto; border: 1px solid var(--line); border-radius: 12px; }
.md table { width: 100%; border-collapse: collapse; font-size: 0.875rem; font-variant-numeric: tabular-nums; }
.md th, .md td { padding: 6px 10px; text-align: left; vertical-align: top; border-bottom: 1px solid var(--line); }
.md th { font-weight: 600; background: var(--material-thin); white-space: nowrap; }
.md tbody tr:last-child td { border-bottom: 0; }
.md th + th, .md td + td { border-left: 1px solid var(--line); }
.md .align-center { text-align: center; }
.md .align-right { text-align: right; }
.md blockquote { margin: 8px 0; padding: 2px 0 2px 12px; border-left: 3px solid var(--line); color: var(--muted); }
.md hr { margin: 12px 0; border: 0; border-top: 1px solid var(--line); }
.md del { color: var(--muted); }
.md li.task { list-style: none; margin-left: -1.3em; }
.md li.task input { margin: 0 6px 0 0; vertical-align: -2px; accent-color: var(--accent); }
@media (prefers-reduced-motion: reduce) {
  .ai-card { animation-name: fade; }
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
/* --unit until widgets.js sets each wall's from its width (the columns that fit, widened to fill it). */
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
.log { font-size: 0.8125rem; line-height: 1.45; padding: 6px 0; height: calc(100vh - 290px); height: calc(100dvh - 290px); min-height: 320px; overflow: auto; overscroll-behavior: contain; }
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
  @media (prefers-color-scheme: dark) { :root:not(:where([data-theme="light"])) { --edge: rgba(255, 255, 255, 0.6); --line: rgba(255, 255, 255, 0.3); --muted: #cfd4dc; } }
  :root:where([data-theme="dark"]) { --edge: rgba(255, 255, 255, 0.6); --line: rgba(255, 255, 255, 0.3); --muted: #cfd4dc; }
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
  .user-button { padding: 3px; }
  .user-name { display: none; }
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
/* The Assistant's sparkle, round, beside the account button. */
.chat-open { flex: none; display: grid; place-items: center; width: 36px; height: 36px; padding: 0; border-radius: 50%; }
.chat-open .sparkle { width: 19px; height: 19px; }
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
  :root:not(:where([data-theme="light"])) { --json-key: #c8a2ff; --json-string: #8ddc8f; --json-number: #ffb06b; --json-bool: #79b8ff; --json-null: #8b949e; }
}
:root:where([data-theme="dark"]) { --json-key: #c8a2ff; --json-string: #8ddc8f; --json-number: #ffb06b; --json-bool: #79b8ff; --json-null: #8b949e; }
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
  header nav { display: none; }
  header .brand { font-size: 1.0625rem; gap: 8px; letter-spacing: -0.015em; }
  header .spacer { display: block; flex: 1; }
  main { padding: 14px 12px calc(104px + env(safe-area-inset-bottom)); }
  .tabbar {
    position: fixed; z-index: 15; left: 10px; right: 10px; bottom: max(10px, env(safe-area-inset-bottom));
    /* A column per section the user may open (six for an administrator, fewer otherwise); a long label widens its own. */
    display: grid; grid-auto-flow: column; grid-auto-columns: minmax(min-content, 1fr); padding: 6px 4px; border-radius: 28px;
    background-color: var(--material-thick); background-image: var(--sheen);
    -webkit-backdrop-filter: blur(var(--blur-thick)) saturate(180%); backdrop-filter: blur(var(--blur-thick)) saturate(180%);
    border: 1px solid var(--edge); box-shadow: var(--shadow-thick), inset 0 1px 0 var(--edge-light);
  }
  .tabbar a {
    display: grid; justify-items: center; gap: 2px; padding: 7px 0 6px; border-radius: 22px; min-height: 50px;
    color: var(--muted); text-decoration: none; font-size: 0.625rem; font-weight: 600; letter-spacing: -0.025em;
    touch-action: manipulation; -webkit-user-select: none; user-select: none;
    transition: transform var(--fast) var(--ease-out), background-color var(--fast) var(--ease-out), color var(--fast) var(--ease-out);
  }
  .tabbar a span { white-space: nowrap; }
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

/* Rooms, Quick Controls, scenes and notifications (home.js). */
.accessory-sections { display: grid; }
.suggest { margin: 0 0 14px; }
.suggest h2 { display: flex; align-items: center; gap: 6px; }
.suggest-rooms { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 240px), 1fr)); gap: 4px 20px; }
.suggest .toggle { margin: 6px 0; }
.suggest.ai-busy { opacity: 0.8; }
.quick { margin: 0 0 6px; }
.quick .service-name { margin-top: 16px; }
.quick-scenes { display: flex; flex-wrap: wrap; gap: 10px; margin: 0 0 14px; }
.scene-run { display: inline-flex; align-items: center; gap: 10px; padding: 6px 16px 6px 6px; border-radius: 999px; font-weight: 500; }
.scene-run .tile { width: 30px; height: 30px; border-radius: 50%; }
.scene-run.busy { opacity: 0.6; }
.scene-card .server-head > button { flex: none; }
.location summary { cursor: pointer; }
.location { margin-top: 14px; }
.scene-editor h2 { margin: 22px 0 2px; font-size: 1.0625rem; }
.scene-editor h2 + p { margin: 0 0 8px; font-size: 0.875rem; }
.editor-list { display: grid; gap: 8px; }
.editor-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; padding: 8px 10px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); }
.editor-row select, .editor-row input[type="text"], .editor-row input[type="number"], .editor-row input[type="time"] { width: auto; min-width: 0; max-width: 100%; }
.editor-row input[type="number"] { width: 7em; }
.editor-row .grow { flex: 1; }
.group-inline { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.value-slot { display: inline-flex; }
.days { display: inline-flex; gap: 4px; flex-wrap: wrap; }
.day { position: relative; display: inline-grid; place-items: center; width: 34px; height: 30px; border-radius: 9px; border: 1px solid var(--line); background: var(--control); font-size: 0.75rem; font-weight: 600; cursor: pointer; }
.day input { position: absolute; inset: 0; opacity: 0; margin: 0; cursor: pointer; }
.day:has(input:checked) { background: var(--accent); color: var(--accent-text); border-color: transparent; }
.day:has(input:focus-visible) { outline: 2px solid var(--accent); outline-offset: 2px; }
.icon-button:not(.menu-button) { width: 32px; height: 32px; padding: 0; display: inline-grid; place-items: center; border-radius: 50%; flex: none; }
.icon-button:not(.menu-button) svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.push .actions { margin-top: 4px; flex-wrap: wrap; }
.scene-editor .actions { flex-wrap: wrap; }
.scene-editor .actions > button { flex: none; white-space: nowrap; }
.scene-editor .actions > select { width: auto; flex: 0 1 auto; min-width: 0; }
@media (max-width: 640px) { .editor-row { padding: 8px; } .editor-row select { flex: 1 1 40%; } }

/* Settings (admin.js): its pages as a segmented row of links, lists of rows in one card, the confirmation and
   history sheets, the audit table. */
a.link { color: var(--accent); text-decoration: none; padding: 4px 6px; }
a.button.primary { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: rgba(255, 255, 255, 0.4); box-shadow: 0 8px 20px rgba(255, 122, 26, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.5); }
a.link:hover { text-decoration: underline; }
.subnav { margin: -6px 0 18px; max-width: 100%; overflow-x: auto; scrollbar-width: none; }
.subnav::-webkit-scrollbar { display: none; }
.group a { color: var(--text); text-decoration: none; padding: 5px 13px; border-radius: 999px; white-space: nowrap; transition: background-color var(--fast) var(--ease-out); }
.group a:hover:not(.on) { background: var(--material-thin); }
.group a.on { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); }
.card.rows { padding: 4px 0; }
.rows > .row, .rows > .row-block > .row { display: flex; align-items: center; gap: 12px; padding: 10px 16px; min-width: 0; }
.rows > * + * { border-top: 1px solid var(--line); }
.rows .row > .who { flex: 1; min-width: 0; }
.rows .row > .who > * { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row-detail { padding: 0 16px 12px; }
.row-detail:empty { display: none; }
.row-block > div:not(.row):not(:empty) { padding: 0 16px 12px; }
pre.diff .diff-fold { display: block; color: var(--muted); font-style: italic; }
.notice-list p { margin: 4px 0; font-size: 0.875rem; }
.admin-dialog { margin: auto; width: min(520px, calc(100% - 24px)); max-height: calc(100% - 48px); overflow: auto; padding: 20px 22px; color: var(--text); background-color: var(--material-solid); }
.admin-dialog.wide { width: min(980px, calc(100% - 24px)); }
.admin-dialog::backdrop { background: rgba(10, 14, 24, 0.35); -webkit-backdrop-filter: blur(4px); backdrop-filter: blur(4px); }
.admin-dialog h2 { margin: 0 0 10px; }
.admin-dialog p { margin: 0 0 10px; }
.admin-dialog .actions { justify-content: flex-end; }
.admin-dialog .page-head { margin: 0 0 14px; }
.admin-dialog .chart-grid.loading { opacity: 0.55; }
.data-table { border-collapse: collapse; font-size: 0.8125rem; width: 100%; }
.data-table th, .data-table td { padding: 6px 12px 6px 0; text-align: left; vertical-align: top; border-bottom: 1px solid var(--line); }
.data-table th { color: var(--muted); font-weight: 500; position: sticky; top: 0; background: var(--material-solid); }
.data-table td:first-child { white-space: nowrap; font-variant-numeric: tabular-nums; }
.card > .table-scroll { overflow-x: auto; max-height: 70vh; overflow-y: auto; }
.audit-details { max-width: 420px; }
.audit-details code { display: block; font: 0.75rem/1.4 var(--mono); color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
@media (prefers-reduced-transparency: reduce) { .admin-dialog::backdrop { -webkit-backdrop-filter: none; backdrop-filter: none; background: rgba(10, 14, 24, 0.6); } }
@media (max-width: 640px) {
  .rows > .row, .rows > .row-block > .row { padding: 10px 12px; }
  .admin-dialog { padding: 16px; }
  .audit-details { max-width: 240px; }
}

/* ---- Appearance: a theme chosen in the web UI (/appearance) rather than the system's, and wallpapers ---------
   common.js sets data-theme and data-wallpaper on the root element; Automatic leaves the system to decide. */
/* The backdrops behind the glass: soft gradients of the UI's own, or the user's image over the page colour. */
:root[data-wallpaper] body::before { background-size: cover; background-position: center; }
:root[data-wallpaper="aurora"] body::before, [data-swatch="aurora"] { background: radial-gradient(70% 60% at 15% 10%, #6ee7b7 0%, transparent 60%), radial-gradient(60% 60% at 85% 20%, #818cf8 0%, transparent 60%), radial-gradient(80% 60% at 50% 100%, #22d3ee 0%, transparent 65%), #0f172a; }
:root[data-wallpaper="sunset"] body::before, [data-swatch="sunset"] { background: radial-gradient(70% 55% at 20% 0%, #fde68a 0%, transparent 60%), radial-gradient(60% 60% at 90% 30%, #fb7185 0%, transparent 60%), linear-gradient(180deg, #fb923c, #9d174d); }
:root[data-wallpaper="ocean"] body::before, [data-swatch="ocean"] { background: radial-gradient(60% 50% at 80% 10%, #7dd3fc 0%, transparent 60%), radial-gradient(70% 60% at 10% 90%, #2dd4bf 0%, transparent 60%), linear-gradient(160deg, #0ea5e9, #1e3a8a); }
:root[data-wallpaper="forest"] body::before, [data-swatch="forest"] { background: radial-gradient(60% 50% at 20% 15%, #bef264 0%, transparent 60%), radial-gradient(70% 60% at 90% 80%, #34d399 0%, transparent 60%), linear-gradient(170deg, #4d7c0f, #064e3b); }
:root[data-wallpaper="graphite"] body::before, [data-swatch="graphite"] { background: radial-gradient(60% 50% at 25% 10%, #9ca3af 0%, transparent 60%), linear-gradient(170deg, #4b5563, #111827); }
:root[data-wallpaper="custom"] body::before, [data-swatch="custom"] { background: var(--wallpaper-image, none) center / cover no-repeat, var(--bg); }
[data-swatch="none"] {
  background: radial-gradient(55% 45% at 8% 6%, var(--bg-warm) 0%, transparent 62%), radial-gradient(50% 42% at 92% 16%, var(--bg-cool) 0%, transparent 60%),
    radial-gradient(60% 55% at 50% 100%, var(--bg-mint) 0%, transparent 65%), var(--bg);
}
.wallpapers { display: grid; grid-template-columns: repeat(auto-fill, minmax(104px, 1fr)); gap: 10px; margin: 12px 0; }
.wallpaper-choice { display: flex; flex-direction: column; align-items: stretch; gap: 6px; padding: 6px 6px 8px; border-radius: 16px; font-weight: 500; }
.wallpaper-choice.on { border-color: var(--accent); box-shadow: 0 0 0 2px var(--accent); }
.wallpaper-swatch { display: block; height: 64px; border-radius: 11px; border: 1px solid var(--line); }
.appearance { display: grid; gap: 16px; }
.appearance .group { margin-top: 10px; flex-wrap: wrap; }
.link-card { display: flex; align-items: center; gap: 14px; margin-top: 16px; padding: 16px 18px; color: var(--text); text-decoration: none; }
.link-card svg { width: 24px; height: 24px; fill: none; stroke: var(--accent); stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }

/* ---- The Status page's widgets, Customise, and the daily digest ------------------------------------------- */
.widget + .widget { margin-top: 0; }
.page-foot { justify-content: center; margin: 24px 0 8px; }
.page-foot svg, .customise .icon-button svg { width: 17px; height: 17px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; vertical-align: -3px; }
.customise { margin-bottom: 16px; padding: 16px 18px; }
.customise-list { display: grid; gap: 6px; margin: 10px 0; }
.customise-row { display: grid; grid-template-columns: auto 1fr auto auto; align-items: center; gap: 12px; padding: 8px 10px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); }
.customise-row .icon-button:disabled { opacity: 0.35; }
.tile.tone-ai { background: var(--material-solid); border: 1px solid var(--line); }
.tile.tone-ai .sparkle { width: 24px; height: 24px; }
.digest-card { margin-bottom: 18px; }
.digest-body { margin: 12px 0 4px; }
.digest-body .md > :first-child { margin-top: 0; }
.digest-card.writing { box-shadow: 0 0 0 1.5px #bf5af2, 0 10px 30px rgba(191, 90, 242, 0.25); }
@media (prefers-reduced-motion: no-preference) { .digest-card { transition: box-shadow var(--normal) var(--ease-out); } }

/* ---- Log Doctor, under the log --------------------------------------------------------------------------- */
.log-doctor { margin-top: 16px; }
.log-doctor .ai-note { margin: 10px 0 0; font-size: 0.8125rem; }
.log-card .editor-bar .ai-button { margin: 0; }

/* ---- The Assistant's settings: test, usage, budgets -------------------------------------------------------- */
.assistant-settings { margin-bottom: 16px; padding: 16px 18px; }
.assistant-settings .server-head > button { margin-left: auto; }
.test-result { margin: 8px 0 0; }
.test-result:empty { display: none; }
.usage .stats { margin: 12px 0; }
.budget-meters { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px 18px; margin: 8px 0 12px; }
.budget-label { display: flex; justify-content: space-between; gap: 8px; font-size: 0.8125rem; margin-bottom: 6px; color: var(--muted); }
.budget-label b { color: var(--text); font-weight: 600; }
.budget-meter .gauge-fill { background: var(--ok); }
.budget-meter.near .gauge-fill { background: var(--warn); }
.budget-meter.over .gauge-fill { background: var(--error); }
.budget-editor .fields { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px; margin: 10px 0; }

/* ---- The chat's earlier conversations ---------------------------------------------------------------------- */
.chat-history h2 { font-size: 1rem; margin: 4px 0 10px; }
.chat-history-list { display: grid; gap: 6px; margin-bottom: 10px; }
.chat-history-row { display: flex; align-items: center; gap: 6px; border-radius: 14px; border: 1px solid var(--line); background: var(--material-thin); }
.chat-history-row.current { border-color: var(--accent); }
.chat-history-open { flex: 1; min-width: 0; display: grid; gap: 2px; text-align: left; border: 0; background: none; box-shadow: none; padding: 9px 12px; border-radius: 14px; }
.chat-history-open strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chat-history-open .muted { font-size: 0.75rem; }
.chat-icon svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
/* A page's title and line on a wallpaper, outside the glass: lifted off it. */
:root[data-wallpaper] .page-head > .who { color: #fff; text-shadow: 0 1px 6px rgba(0, 0, 0, 0.45); }
:root[data-wallpaper] .page-head > .who .muted { color: rgba(255, 255, 255, 0.85); }

"""#),
        "sw.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The web UI's service worker: it only shows the bridge's push notifications (Notifications page, "this browser")
// and opens the page one is about. It caches nothing and answers no request.
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { body: event.data ? event.data.text() : "" }; }
  event.waitUntil(self.registration.showNotification(data.title || "Homeswift", {
    body: data.body || "", tag: data.tag, icon: "/icon.svg", requireInteraction: !!data.urgent, data: { path: data.path || "/" },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const path = (event.notification.data && event.notification.data.path) || "/";
  // A path on this origin only: "//host" and "/\host" would leave it.
  const target = new URL(/^\/(?![/\\])/.test(path) ? path : "/", self.location.origin).href;
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
    for (const client of windows) {
      if (new URL(client.url).origin === self.location.origin && "focus" in client) {
        return client.focus().then((focused) => (focused && "navigate" in focused ? focused.navigate(target) : focused));
      }
    }
    return self.clients.openWindow(target);
  }));
});

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
  const units = { percentage: " %", lux: " lx", seconds: " s", arcdegrees: "°" };
  // Temperatures in the unit the user chose (Appearance); HomeKit's values stay in °C.
  const unit = (characteristic) => characteristic.unit === "celsius" ? ` ${HomeswiftCommon.temperature(0).unit}` : units[characteristic.unit] || "";
  /// A value with its characteristic's unit, a temperature converted to the user's unit.
  const withUnit = (value, characteristic) =>
    characteristic.unit === "celsius" && typeof value === "number" ? HomeswiftCommon.formatTemperature(value) : `${value}${unit(characteristic)}`;
  function formatValue(characteristic) {
    if (characteristic.format === "bool") return characteristic.value ? "On" : "Off";
    if (characteristic.value === null || characteristic.value === undefined) return "";
    return withUnit(characteristic.value, characteristic);
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
  /// A temperature (HomeKit's °C) in the user's unit, as the dials show it: "21.5°".
  const degrees = (celsius) => { const { value } = HomeswiftCommon.temperature(celsius); return `${Number.isInteger(value) ? value : value.toFixed(1)}°`; };
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

  /// Lets go of the cards no longer on the page (the view changed, the wall was drawn again); a new one may not be
  /// attached yet. Run as cards are made too, so a quiet home, with no events, does not keep every wall drawn.
  let swept = 0;
  function sweep(now = Date.now()) {
    swept = now;
    for (const ctx of cards) if (!ctx.node?.isConnected && now - ctx.born > 2000) cards.delete(ctx);
  }

  /// An accessory event from the page's event stream: the new value, painted on the cards of that accessory.
  function event({ id, service, subtype, characteristic, value }) {
    if (Date.now() - swept > 1000) sweep();
    for (const ctx of cards) {
      if (!ctx.node?.isConnected) continue;
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
    // append() writes a null as the text "null": "" when there is no label.
    node.append(bar, showLabel ? el("span", { class: "level-label", text: label }) : "", text);
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
        value.textContent = withUnit(Number(input.value), characteristic);
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
        case "TemperatureSensor": return { text: typeof v === "number" ? HomeswiftCommon.temperature(v).value.toFixed(1) : "–", unit: HomeswiftCommon.temperature(0).unit, tone: inactive ? "muted" : "" };
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
        hero: () => icon("lock"),
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
  /// What the search box looks in: the names, the room, the plugin and the model.
  const searchText = (accessory) => [accessory.name, accessory.displayName, accessory.room, accessory.platformName, accessory.model].filter(Boolean).join(" ").toLowerCase();

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
    if (Date.now() - swept > 5000) sweep();
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
    const who = el("div", { class: "who" }, el("strong", { text: accessory.displayName || accessory.name, title: accessory.displayName ? `${accessory.name} in the Home app` : null }), status);
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
        body.length ? el("div", { class: "w-body" }, body) : "", el("span", { class: "w-corner" }, menu));
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

  // ---- The wall's unit -------------------------------------------------------------------------------------------
  // The wall's columns are squares of 160 px at least (two on a phone, which fill it): as many as fit, widened so the
  // row ends at the wall's right edge instead of leaving a strip. CSS cannot size a square track to a share of the
  // width, so each wall gets its --unit from its width, when it appears and when it resizes.
  const unitMinimum = 160;
  const fitted = new WeakMap();
  function fitWall(wall) {
    const width = wall.clientWidth;
    if (!width || fitted.get(wall) === width) return;
    fitted.set(wall, width);
    const gap = parseFloat(getComputedStyle(wall).columnGap) || 12;
    const columns = width <= 520 ? 2 : Math.max(2, Math.floor((width + gap) / (unitMinimum + gap)));
    wall.style.setProperty("--unit", `${Math.floor(((width - gap * (columns - 1)) / columns) * 100) / 100}px`);
  }
  const resized = new ResizeObserver((entries) => { for (const entry of entries) fitWall(entry.target); });
  // A new wall is sized at once, before it is first drawn at the default unit, then again whenever its width changes.
  const watch = (wall) => { fitWall(wall); resized.observe(wall); };
  // The walls an added or removed node is or holds: a node without children (a log line, a chat word) costs a check.
  const walls = (node) => {
    if (node.nodeType !== 1) return [];
    if (node.classList.contains("wall")) return [node];
    return node.firstElementChild ? [...node.getElementsByClassName("wall")] : [];
  };
  // Walls are in the page's view (the Accessories page, Status's Quick section), a new <main id="view"> for each page:
  // its parent stays, so it is what is watched, and what the chat or a sheet adds to the body is not looked at.
  const view = document.getElementById("view")?.parentElement ?? document.documentElement;
  new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) for (const wall of walls(node)) watch(wall);
      for (const node of record.removedNodes) for (const wall of walls(node)) resized.unobserve(wall);
    }
  }).observe(view, { childList: true, subtree: true });
  for (const wall of walls(view)) watch(wall);

  window.HomeswiftWidgets = {
    card, open, kindOf, sizes, event, listen, describeModel, labelFor, enumLabels,
    /// A page's own widget, tried before the built-in ones: { name, types, match?, icon, tone, size, build }.
    register: (widget) => widgets.unshift(widget),
    /// The controls the widgets are made of, for a page's own widget.
    controls: { toggle, segmented, level, steps, setpoint, gauge, readout, meter, chip, hold, pill, icon },
  };
})();

"""#),
    ]
}
