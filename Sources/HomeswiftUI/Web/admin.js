// The Settings pages, after the Homebridge UI's settings, child bridges, config editor backups, restart and power
// options: the bridge block and this machine's network, HomeKit pairings, cached accessories, config.json's editor, child bridges,
// whole-instance and config.json backups, the schedules, updates, and the audit log; and an accessory's recorded
// history.
// app.js routes /settings[/<page>] here and lends its helpers (HomeswiftApp) when a view is drawn.
(() => {
  "use strict";

  const { $, el, tile, fact, menuButton, withSlugs, jsonDiff } = HomeswiftCommon;
  const { t, tn, locale } = HomeswiftI18n;
  const app = () => window.HomeswiftApp;
  const api = (...args) => app().api(...args);

  const pages = [["bridge", t("Bridge"), "bridge"], ["config", t("Config"), "code"], ["child-bridges", t("Child bridges"), "child"], ["backups", t("Backups"), "archive"], ["vault", t("Vault"), "vault"], ["updates", t("Updates"), "download"], ["audit", t("Audit log"), "shield"], ["assistant", t("Assistant"), "sparkle"]];

  const dateTime = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false });
  const fullDate = new Intl.DateTimeFormat(locale, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  const when = (iso) => (iso ? dateTime.format(new Date(iso)) : "–");
  const size = (bytes) => HomeswiftCommon.byteSize(bytes);

  /// The pages of Settings as a row of links, the Assistant's with its coloured sparkle.
  const subnav = (current) => HomeswiftCommon.subnav(t("Settings pages"), "/settings",
    pages.map(([path, text, glyph]) => [path, text, glyph === "sparkle" ? HomeswiftCommon.sparkle() : glyph]), current);

  /// A modal question for what cannot be undone: `typed`, when given, must be typed before the button works.
  /// Resolves true when confirmed.
  function confirmAction({ title, text, confirmLabel = t("Continue"), typed = null, danger = true, confirmIcon = "check" }) {
    return new Promise((resolve) => {
      const input = typed ? el("input", { type: "text", autocomplete: "off", spellcheck: false, "aria-label": t("Type {text} to confirm", { text: typed }) }) : null;
      const ok = el("button", { class: danger ? "danger" : "primary", actionIcon: confirmIcon, text: confirmLabel, disabled: Boolean(typed), value: "ok" });
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
    // Settings opens on its first page, Bridge.
    if (!page) { history.replaceState(null, "", "/settings/bridge"); page = "bridge"; }
    const draw = { bridge: bridgePage, config: (main) => app().configPage(main, subnav("config")), "child-bridges": childBridgesPage, backups: backupsPage, vault: vaultPage, updates: updatesPage, audit: auditPage, assistant: (main) => app().assistantPage(main, subnav("assistant")) }[page];
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
      // The code the bridge runs with: config.json keeps it sealed, or names it in the vault.
      pin: input("pin", { id: "bridge-pin", class: "mono", placeholder: "031-45-154", pattern: "\\d{3}-\\d{2}-\\d{3}", autocomplete: "off", spellcheck: false, value: settings.setupCode ?? bridge.pin ?? "" }),
      manufacturer: input("manufacturer", { placeholder: "Homeswift" }),
      model: input("model", { placeholder: "Homeswift" }),
      firmwareRevision: input("firmwareRevision", { placeholder: t("The homeswift version") }),
    };
    const field = (title, control, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: title }), control, help ? el("span", { class: "help", text: help }) : null);
    const message = el("p", { class: "status-line muted", role: "status" });
    const save = el("button", { actionIcon: "check", class: "primary", type: "submit", text: t("Save and restart") });
    // The setup code is sent only when it changes, so a sealed or vault pin stays as config.json has it.
    const shownPin = fields.pin.value;
    const read = () => Object.fromEntries(Object.entries(fields).map(([key, control]) => {
      const value = control.value.trim();
      return [key, value === "" ? null : key === "port" ? Number(value) : value];
    }).filter(([key, value]) => key !== "pin" || value !== shownPin));
    const copied = el("span", { class: "visually-hidden", role: "status" });
    const copyIcon = HomeswiftCommon.icon("copy"), doneIcon = HomeswiftCommon.icon("check");
    copyIcon.classList.add("copy-icon");
    doneIcon.classList.add("copied-icon");
    let copyTimer;
    const copyPin = el("button", { type: "button", class: "icon-button setup-code-copy", title: t("Copy the setup code"), "aria-label": t("Copy the setup code"), onclick: async () => {
      clearTimeout(copyTimer);
      try {
        await HomeswiftCommon.copyText(fields.pin.value.trim());
        copyPin.dataset.copied = "";
        copied.textContent = t("Copied");
      } catch {
        // Selected, ⌘C or Ctrl+C copies it.
        fields.pin.focus();
        fields.pin.select();
        copied.textContent = t("Not copied");
      }
      copyTimer = setTimeout(() => { delete copyPin.dataset.copied; copied.textContent = ""; }, 1600);
    } }, copyIcon, doneIcon);
    // The pairing QR code, for the Home app's camera: the code the bridge runs with, so a new one shows after the restart.
    const qr = settings.setupCode ? el("img", { class: "qr", src: "/api/qr/0.svg", alt: t("Pairing QR code"), width: 120, height: 120 }) : null;
    const qrNote = settings.setupCode ? el("p", { class: "help setup-field-note", text: main?.paired ? t("The bridge is in the Home app. To add it again, reset its pairings below, then scan this code.")
      : t("In the Home app: Add Accessory, then scan this code, or choose More options and type it.") }) : null;
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
          "pin" in next ? t("A new setup code applies to new pairings only: the Home app keeps the bridge.") : ""] }))) return;
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
        // The code and its QR code side by side, across the form: they say the same thing.
        el("div", { class: "field setup-field" },
          el("div", { class: "setup-field-main" },
            el("label", { class: "field-title", for: "bridge-pin", text: t("Setup code") }),
            el("div", { class: "setup-code-field" }, fields.pin, copyPin, copied),
            el("span", { class: "help", text: t("The code the Home app asks for, as XXX-XX-XXX. It is never logged.") }), qrNote),
          qr),
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

  // ---- Updates: this version, the latest release, installing it and relaunching --------------------------------

  async function updatesPage(main) {
    const update = await api("/api/updates");
    const installs = { homebrew: "Homebrew", docker: t("Docker container"), synology: t("Synology package"), source: t("Built from source") };
    const head = el("div", { class: "server-head update-head" });
    const details = el("div", {});
    const message = el("p", { class: "error", role: "alert" });
    let shown = "";
    // The headline is the state: up to date, a release out, installing, waiting for a relaunch, or a failed check.
    const drawHead = () => {
      const state = app().updatePhase(update);
      const [icon, tone] = { current: ["check", "green"], available: ["download", "orange"], installed: ["power", "green"], installing: ["update", "blue"],
        relaunching: ["power", "blue"], error: ["warning", "heat"], idle: ["update", "grey"] }[state];
      const title = {
        current: () => t("Homeswift is up to date"), available: () => t("Homeswift {version} is available", { version: update.latest }),
        installed: () => t("Homeswift {version} is installed", { version: update.installed }), installing: () => t("Installing Homeswift {version}…", { version: update.installing }),
        relaunching: () => t("Restarting into Homeswift {version}…", { version: update.installed }), error: () => t("Could not check for updates"), idle: () => t("Not checked yet"),
      }[state]();
      const meta = [t("This is {version}", { version: update.current }), installs[update.install] ?? update.install,
        update.checkedAt ? t("Checked {when}", { when: HomeswiftCommon.ago(update.checkedAt) }) : null].filter(Boolean).join(" · ");
      // Redrawn (and faded in) only when it says something new, not on each question while an update installs.
      const key = `${state}|${title}|${meta}`;
      if (key === shown) return;
      const fade = shown !== "";
      shown = key;
      head.replaceChildren(tile(icon, tone),
        el("div", { class: `who${fade ? " update-head-changed" : ""}` }, el("strong", { text: title }), el("div", { class: "muted", text: meta })),
        check);
      check.disabled = state === "installing" || state === "relaunching";
    };
    const draw = (next) => {
      Object.assign(update, next);
      automatic.checked = Boolean(update.automatic);
      drawHead();
      // The release's details, its install button among them; they keep the headline current while it installs.
      const card = app().updateCard(update, { embedded: true, changed: (state) => { Object.assign(update, state); drawHead(); } });
      details.replaceChildren(...(card ? [card] : []));
    };
    // `checkForUpdates` of the HomeswiftUI block, written as soon as it changes.
    const automatic = el("input", { type: "checkbox", role: "switch", onchange: async () => {
      const on = automatic.checked;
      automatic.disabled = true;
      message.textContent = "";
      try {
        draw(await api("/api/updates/automatic", { method: "PUT", body: { on } }));
      } catch (error) {
        automatic.checked = !on;
        message.textContent = error.message;
      } finally {
        automatic.disabled = false;
      }
    } });
    const check = el("button", { type: "button", actionIcon: "restore", text: t("Check now"), onclick: (event) => {
      message.textContent = "";
      busy(event.currentTarget, async () => draw(await api("/api/updates/check", { method: "POST", body: {} })), (error) => { message.textContent = error.message; });
    } });
    const relaunch = el("button", { type: "button", class: "link", onclick: (event) => app().restartBridge(event) }, HomeswiftCommon.icon("power"), el("span", { text: t("Restart homeswift…") }));
    draw(update);
    app().show(main,
      app().pageHead(t("Settings"), t("The bridge, its pairings and cached accessories, child bridges, backups and the audit log.")),
      subnav("updates"),
      el("section", { class: "updates-settings" },
        el("div", { class: "card server" },
          head, message, details,
          el("div", { class: "update-preferences" },
            el("label", { class: "toggle" }, el("span", { class: "switch" }, automatic, el("span")),
              el("span", {}, el("span", { class: "field-title", text: t("Check for updates twice a day") }),
                el("p", { class: "help", text: t("Asks GitHub for the latest release and says so on the Status page. The request carries only this version.") })))),
          el("div", { class: "actions dashboard-quick-actions" }, relaunch))));
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
    const blocks = plugins.blocks.filter((block) => !["HomeswiftUI", "HomeswiftAiKit"].includes(block.platform));
    const empty = (text, ...actions) => el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("child")),
      el("p", { class: "muted", text }), actions.length ? el("div", { class: "actions" }, actions) : null);
    app().show(main,
      app().pageHead(t("Child bridges"), t("Plugins on HomeKit bridges of their own (a block with _bridge), inside this process: one can restart without the others.")),
      subnav("child-bridges"),
      // Without a plugin there is nothing to put on a bridge of its own: one empty state, the way to add one.
      blocks.length ? [
        el("section", {}, sectionHead(t("Plugin bridges")),
          el("div", { class: "card rows" }, blocks.map((block) =>
            el("div", { class: "row" }, tile("child", "blue"),
              el("div", { class: "who" }, el("strong", { text: block.name }), el("div", { class: "muted", text: block.childBridge ? t("Child bridge") : t("Main bridge") })),
              el("button", { actionIcon: "sliders", text: t("Configure"), onclick: () => editChildBridge(block) }))))),
        childBridges.length ? el("div", { class: "servers" }, childBridges.map(card))
          : empty(t("No child bridges yet. Configure a plugin above to give it its own bridge.")),
      ] : empty(t("No plugins yet. Add one, then give it a HomeKit bridge of its own here."),
        el("a", { class: "button primary", href: "/plugins", actionIcon: "plus", text: t("Add a plugin") })));
  }

  async function editChildBridge(entry) {
    const path = `/api/config/block/${encodeURIComponent(entry.platform)}/${encodeURIComponent(entry.name)}`;
    let block;
    try { block = await api(path); } catch (error) { HomeswiftCommon.showAlert(error.message); return; }
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
    const dialog = el("dialog", { class: "admin-dialog card", "aria-label": entry.name }, form);
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

  // ---- Vault: the bridge's credentials by name, their values never shown ---------------------------------------

  const kindNames = { login: t("Login"), apiKey: t("API key"), token: t("Token"), secret: t("Secret [vault]") };
  const kindPlurals = { login: t("Logins"), apiKey: t("API keys"), token: t("Tokens [vault]"), secret: t("Secrets [vault]") };
  const fieldNames = { password: t("Password"), username: t("Username"), key: t("Key"), token: t("Token"), value: t("Value") };
  const fieldName = (field) => fieldNames[field] ?? field;

  async function vaultPage(main) {
    const [vault, plan] = await Promise.all([api("/api/vault"), api("/api/vault/migration")]);
    const add = el("button", { actionIcon: "plus", class: "primary", text: t("Add a secret"), onclick: () => entryDialog(null, vault) });
    app().show(main,
      app().pageHead(t("Vault"), t("The bridge's passwords, keys and tokens by name, sealed on disk. config.json names them as vault:<name>; a saved value is never shown again.")),
      subnav("vault"),
      vault.problems.length ? healthCard(vault.problems, vault) : null,
      plan.items.length ? migrationCard(plan, vault) : null,
      sectionHead(t("Entries"), vault.entries.length ? tn("{n} entry", "{n} entries", vault.entries.length) : "", add),
      vault.entries.length ? entriesFinder(vault)
        : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("vault")),
          el("p", { class: "muted", text: t("None yet: add one, or move config.json's secrets here.") })));
  }

  /// The entries as rows under a search (names, kinds, the settings and plugins that use them), a filter by what needs
  /// attention, what nothing uses yet or a kind, and an order: the same toolbar as the Plugins page's.
  function entriesFinder(vault) {
    // Missing and failing first, then expired, then expiring; healthy last.
    const attention = (entry) => ({ missing: 0, failing: 0, expired: 1, expiring: 2 })[entry.health] ?? 3;
    const unused = (entry) => !entry.usedBy.length && !entry.owner;
    const lastUsed = (entry) => entry.used ? new Date(entry.used).getTime() : 0;
    const entries = vault.entries.map((entry) => ({ entry, card: entryRow(entry, vault), name: entry.name,
      text: [entry.name, kindNames[entry.kind], entry.owner, ...entry.usedBy].filter(Boolean).join(" ") }));
    const kinds = Object.entries(kindPlurals).filter(([kind]) => vault.entries.some((entry) => entry.kind === kind));
    return app().finder({ grid: el("div", { class: "card rows" }), entries, param: "order", filterParam: "show",
      orders: [["name", t("Name A–Z"), () => 0], ["attention", t("Needs attention first"), (a, b) => attention(a.entry) - attention(b.entry)],
        ["used", t("Recently used"), (a, b) => lastUsed(b.entry) - lastUsed(a.entry)],
        ["users", t("Most used"), (a, b) => b.entry.usedBy.length - a.entry.usedBy.length]],
      filters: [["all", t("All entries"), () => true],
        ["attention", t("Needs attention"), ({ entry }) => attention(entry) < 3],
        ["unused", t("Not used yet"), ({ entry }) => unused(entry)],
        ...kinds.map(([kind, label]) => [kind, label, ({ entry }) => entry.kind === kind])],
      placeholder: t("Search the vault"), sortLabel: t("Sort entries"), filterLabel: t("Show entries"), empty: t("No entry matches."),
      counted: (shown, total) => t("{shown} of {total} entries", { shown, total }) });
  }

  /// When an entry expires, as a warning from 30 days before.
  function expiry(entry) {
    if (!entry.expires) return null;
    const date = new Date(entry.expires);
    const days = (date - Date.now()) / 86_400_000;
    if (days < 0) return el("span", { class: "error", text: t("Expired {date}", { date: when(entry.expires) }) });
    return el("span", { class: days < 30 ? "warning" : "muted", text: t("Expires {date}", { date: when(entry.expires) }) });
  }

  /// Each kind's glyph and tone: a list of names reads by kind at a glance.
  const kindLooks = { login: ["user", "blue"], apiKey: ["key", "violet"], token: ["shield", "teal"], secret: ["lock", "grey"] };

  function entryRow(entry, vault) {
    const [glyph, tone] = kindLooks[entry.kind] ?? ["key", "grey"];
    const detail = el("div", { class: "row-detail hidden", id: `vault-users-${entry.name}` },
      el("p", { class: "muted", text: t("config.json names it in:") }), el("pre", { class: "mono", text: entry.usedBy.join("\n") }));
    // Who uses it: the count opens the settings that name it, where the eye already is.
    const users = entry.usedBy.length
      ? el("button", { type: "button", class: "link vault-users", actionIcon: "search", "aria-expanded": "false", "aria-controls": detail.id,
        text: tn("Used by {n} setting", "Used by {n} settings", entry.usedBy.length),
        onclick: (event) => event.currentTarget.setAttribute("aria-expanded", String(!detail.classList.toggle("hidden"))) })
      : el("span", { text: entry.owner ? t("Kept by {plugin}", { plugin: entry.owner }) : t("Not used yet") });
    // A login names its fields; the other kinds hold one value, which the kind already says.
    const kind = entry.kind === "login" ? `${kindNames.login} · ${entry.fields.map(fieldName).join(", ")}` : kindNames[entry.kind] ?? entry.kind;
    return el("div", { class: "row-block" },
      el("div", { class: "row vault-row" },
        tile(glyph, tone),
        el("div", { class: "who" }, el("strong", { class: "mono", text: entry.name, title: entry.name }),
          el("div", { class: "muted vault-detail" }, el("span", { text: kind }), el("span", { "aria-hidden": "true", text: "·" }), users)),
        el("span", { class: "vault-when" }, entry.health === "missing" || entry.health === "failing" ? el("span", { class: "error", text: t("A setting cannot read it") })
          // When it was last read; "Not used yet" beside the kind already says it for an entry nothing names.
          : expiry(entry) ?? (entry.used || entry.usedBy.length ? el("span", { class: "muted", text: entry.used ? t("Used {date}", { date: when(entry.used) }) : t("Never used") }) : null)),
        menuButton(t("Actions for {name}", { name: entry.name }), () => [
          { label: t("Copy the reference"), icon: "copy", onSelect: () => HomeswiftCommon.copyText(`vault:${entry.name}`) },
          { label: t("Replace the value…"), icon: "edit", onSelect: () => entryDialog(entry, vault) },
          { label: t("Delete…"), icon: "trash", danger: true, onSelect: () => removeEntry(entry) },
        ])),
      detail);
  }

  /// The server's rule for an entry's name (Redaction.vaultNamePattern) as an input's `pattern`, which browsers read
  /// with the `v` flag: there a `-` in a class is escaped.
  const namePattern = (vault) => vault.namePattern.replaceAll("-]", "\\-]");

  /// Adds an entry (`entry` null, `suggested` its name) or replaces an entry's values: values are typed, never shown, and
  /// an empty field keeps the one saved.
  function entryDialog(entry, vault, suggested = "") {
    const { kinds } = vault;
    const editing = Boolean(entry);
    const name = el("input", { type: "text", value: entry?.name ?? suggested, required: !editing, disabled: editing, autocomplete: "off", spellcheck: false,
      pattern: namePattern(vault), placeholder: "unifi-home" });
    const kind = el("select", {}, kinds.map(({ kind: value }) => el("option", { value, text: kindNames[value] ?? value, selected: value === (entry?.kind ?? "secret") })));
    const username = el("input", { type: "text", autocomplete: "off", placeholder: editing && entry.fields.includes("username") ? t("Unchanged") : "" });
    const secret = el("input", { type: "password", autocomplete: "new-password", required: !editing, placeholder: editing ? t("Unchanged") : "", spellcheck: false });
    // A long key pasted in is checked by eye before it is sealed for good.
    const reveal = el("button", { type: "button", class: "icon-button", "aria-label": t("Show the value"), title: t("Show the value"), "aria-pressed": "false" }, HomeswiftCommon.icon("eye"));
    reveal.addEventListener("click", () => {
      const shown = secret.type === "password";
      secret.type = shown ? "text" : "password";
      reveal.setAttribute("aria-pressed", String(shown));
      reveal.setAttribute("aria-label", shown ? t("Hide the value") : t("Show the value"));
      reveal.title = reveal.getAttribute("aria-label");
      secret.focus();
    });
    const expires = el("input", { type: "date", value: entry?.expires ? entry.expires.slice(0, 10) : "" });
    const mainField = () => kinds.find((k) => k.kind === kind.value)?.mainField ?? "value";
    const secretTitle = el("span", { class: "field-title" });
    const userField = el("label", { class: "field" }, el("span", { class: "field-title", text: t("Username") }), username);
    const sync = () => {
      secretTitle.textContent = fieldName(mainField());
      userField.classList.toggle("hidden", kind.value !== "login");
      // Another kind starts again: its values are all typed anew.
      secret.required = !editing || kind.value !== entry.kind;
    };
    kind.addEventListener("change", sync);
    const message = el("p", { class: "status-line error", role: "status" });
    const save = el("button", { class: "primary", actionIcon: "check", text: editing ? t("Replace") : t("Add [entry]"), value: "ok" });
    const cancel = el("button", { actionIcon: "close", text: t("Cancel"), value: "cancel", type: "button" });
    const form = el("form", { method: "dialog" },
      el("h2", { id: "vault-entry-title", text: editing ? t("Replace the value of {name}", { name: entry.name }) : t("Add a secret") }),
      el("p", { class: "muted", text: t("The value is sealed with this bridge's key and never shown again: keep the original in your password manager.") }),
      // Replacing a value keeps the name: the title says which entry.
      editing ? null : el("label", { class: "field" }, el("span", { class: "field-title", text: t("Name") }), name),
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Kind") }), kind),
      userField,
      el("label", { class: "field" }, secretTitle, el("span", { class: "secret-field" }, secret, reveal)),
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Expires") }), expires,
        el("div", { class: "help", text: t("Optional: the page warns a month before.") })),
      message,
      el("div", { class: "actions" }, cancel, save));
    const dialog = el("dialog", { class: "admin-dialog card", "aria-labelledby": "vault-entry-title" }, form);
    sync();
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const fields = {};
      if (secret.value) fields[mainField()] = secret.value;
      if (kind.value === "login" && username.value) fields.username = username.value;
      // A save sends a value: the date alone is not a change the server takes.
      if (!Object.keys(fields).length) { message.textContent = editing ? t("Type a new value to replace it.") : t("Type the value."); return; }
      const target = editing ? entry.name : name.value.trim();
      busy(save, async () => {
        const body = { kind: kind.value, fields, expires: expires.value ? new Date(`${expires.value}T00:00:00`).toISOString() : null };
        await api(`/api/vault/${encodeURIComponent(target)}`, { method: "PUT", body });
        dialog.close("ok");
        app().route();
      }, (e) => { message.textContent = e.message; });
    });
    cancel.addEventListener("click", () => dialog.close("cancel"));
    dialog.addEventListener("close", () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
    (editing ? secret : name).focus();
  }

  async function removeEntry(entry) {
    if (entry.usedBy.length) {
      HomeswiftCommon.showAlert(t("config.json still names {name} in {settings}: give those settings another value first.", { name: entry.name, settings: entry.usedBy.join(", ") }));
      return;
    }
    const ok = await confirmAction({
      title: t("Delete {name}?", { name: entry.name }), confirmLabel: t("Delete"),
      text: entry.owner ? t("{plugin} keeps it: it signs in again, or asks you to pair again, without it.", { plugin: entry.owner }) : t("Its value is gone for good: the vault keeps no copy."),
    });
    if (!ok) return;
    await busy(null, async () => { await api(`/api/vault/${encodeURIComponent(entry.name)}`, { method: "DELETE" }); app().route(); });
  }

  /// What needs attention, most pressing first (VaultHealth): references to entries the vault does not have, references
  /// that cannot read their entry, entries expired or expiring. Each row has the step that fixes it.
  function healthCard(problems, vault) {
    const count = new Set(problems.map((problem) => problem.entry)).size;
    const says = {
      missing: () => t("Not in the vault: the bridge does not start until it is added again, or its settings get another value."),
      failing: () => t("A setting cannot read it: it names a field the entry does not have, or another plugin's entry."),
      expired: (problem) => t("Expired {date}: replace the value.", { date: when(problem.expires) }),
      expiring: (problem) => t("Expires {date}: replace the value before then.", { date: when(problem.expires) }),
    };
    const fix = (problem) => {
      const entry = vault.entries.find((item) => item.name === problem.entry);
      if (problem.state === "missing") return el("button", { actionIcon: "plus", type: "button", text: t("Add it…"), onclick: () => entryDialog(null, vault, problem.entry) });
      // A plugin's own entry is replaced by the plugin; a setting that names it is changed in that plugin's form.
      return entry && !entry.owner ? el("button", { actionIcon: "edit", type: "button", text: t("Replace the value…"), onclick: () => entryDialog(entry, vault) }) : null;
    };
    return el("div", { class: "card server vault-card attention" },
      el("div", { class: "server-head" }, tile("warning", "orange"),
        el("div", { class: "who" }, el("strong", { text: tn("One entry needs attention", "{n} entries need attention", count) }))),
      el("div", { class: "rows" }, problems.map((problem) => el("div", { class: "row vault-problem" },
        el("div", { class: "who" }, el("strong", { class: "mono", text: problem.entry }),
          el("div", { class: problem.state === "expiring" ? "warning" : "error", text: says[problem.state]?.(problem) ?? problem.state }),
          problem.usedBy.length ? el("div", { class: "muted mono", text: problem.usedBy.join(", ") }) : null),
        fix(problem)))));
  }

  /// config.json's secrets that are not in the vault yet, each with the entry it would become: untick to leave one,
  /// rename an entry, then move them.
  function migrationCard(plan, vault) {
    const names = {};
    const excluded = new Set(plan.items.filter((item) => item.excluded).map((item) => item.id));
    const message = el("p", { class: "status-line muted", role: "status" });
    // The row that names a new entry, by the entry's name: the rows that share it follow its name as it is edited.
    const namers = {};
    const followers = [];
    const rows = plan.items.map((item) => {
      const setting = `${item.name} · ${item.path}`;
      const box = el("input", { type: "checkbox", checked: !item.excluded, "aria-label": t("Move {setting}", { setting }) });
      let target;
      if (item.shared) {
        // An entry another row names (or the vault has): its name is set there, so it is shown, not asked.
        target = el("span", { class: "muted vault-shares" });
        followers.push({ item, target });
      } else {
        target = el("input", { type: "text", value: item.entry, class: "mono", autocomplete: "off", spellcheck: false, disabled: item.excluded,
          pattern: namePattern(vault), "aria-label": t("Entry for {setting}", { setting }) });
        namers[item.entry] = target;
        target.addEventListener("input", () => {
          const typed = target.value.trim();
          if (typed && typed !== item.entry) names[item.id] = typed; else delete names[item.id];
          showShared();
        });
      }
      box.addEventListener("change", () => {
        if (box.checked) excluded.delete(item.id); else excluded.add(item.id);
        if (target.tagName === "INPUT") target.disabled = !box.checked;
        row.classList.toggle("left", !box.checked);
        count();
      });
      const row = el("div", { class: `row vault-move${item.excluded ? " left" : ""}` },
        box, el("div", { class: "who" }, el("strong", { text: item.name }), el("div", { class: "muted mono", text: item.path, title: item.path })), target);
      return row;
    });
    const showShared = () => {
      for (const { item, target } of followers) {
        const namer = namers[item.entry];
        target.textContent = t("Shares {entry}", { entry: namer?.value.trim() || item.entry });
      }
    };
    const move = el("button", { actionIcon: "vault", class: "primary", onclick: (event) => {
      const button = event.currentTarget;
      confirmAction({
        title: t("Move config.json's secrets to the vault?"), confirmLabel: t("Move"), danger: false, confirmIcon: "vault",
        text: [t("Each one becomes an entry, and config.json names it as vault:<name>. config.json is backed up first: restoring that backup undoes it."),
          t("A copy of config.json no longer works on Homebridge: its secrets stay in this bridge's vault.")],
      }).then((ok) => ok && busy(button, async () => {
        const result = await api("/api/vault/migration", { method: "POST", body: { names, exclude: [...excluded] } });
        message.className = "status-line ok";
        message.textContent = `${tn("{n} secret moved.", "{n} secrets moved.", result.moved)} ${result.applied ? app().savedText(result.applied) : ""}`;
        setTimeout(() => app().route(), 1200);
      }, (e) => { message.className = "status-line error"; message.textContent = e.message; }));
    } });
    // The button says how many it moves, and waits while none is ticked.
    const count = () => {
      const moving = plan.items.length - excluded.size;
      move.textContent = tn("Move {n} secret", "Move {n} secrets", moving);
      move.disabled = moving === 0;
    };
    count();
    showShared();
    return el("div", { class: "card server vault-card" },
      el("div", { class: "server-head" }, tile("vault", "violet"),
        el("div", { class: "who" }, el("strong", { text: tn("{n} secret is still in config.json", "{n} secrets are still in config.json", plan.items.length) }),
          el("div", { class: "muted", text: tn("Move it here: the plugin keeps working with the same value.", "Move them here: identical values share one entry, and each plugin keeps working with the same value.", plan.items.length) }))),
      el("div", { class: "rows" }, rows),
      el("div", { class: "actions" }, move),
      message);
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

  // Each inner ring's radius as a share of the outer one: the bridges', the plugins' and the device types'.
  const ringShares = { top: 0.42, plugin: 0.62, group: 0.84 };
  // An accessory's disc (its radius) and the gap kept between two discs on the outer ring.
  const disc = { radius: 11.5, gap: 14 };
  // The radius of a node on each inner ring (a bridge, a plugin, a device type) and the gap kept between two of them.
  const nodeRadius = { top: 17, plugin: 12, group: 13 }, nodeGap = 8;
  // The room a node takes along its ring: its width and the gap after it.
  const nodeRoom = (ring) => 2 * nodeRadius[ring] + nodeGap;
  // A plugin's branch (the plugin, its device types and accessories) takes one of the reference palette's eight
  // categorical slots in config.json's order, the ninth plugin the first slot again (never a generated hue); bridges are
  // neutral, the trunks the plugins hang from.
  const branchColors = ["--viz-1", "--viz-2", "--viz-3", "--viz-4", "--viz-5", "--viz-6", "--viz-7", "--viz-8"];
  /// An accessory category's name (AccessoryCategory's cases), else its words spaced out.
  const categoryNames = { other: t("Other"), bridge: t("Bridge"), fan: t("Fan"), garageDoorOpener: t("Garage door"), lightbulb: t("Lightbulb"),
    doorLock: t("Lock"), outlet: t("Outlet"), switch: t("Switch"), thermostat: t("Thermostat"), sensor: t("Sensor"),
    securitySystem: t("Security system"), door: t("Door"), window: t("Window"), windowCovering: t("Window covering"),
    programmableSwitch: t("Programmable switch"), rangeExtender: t("Range extender"), ipCamera: t("Camera"), camera: t("Camera"),
    videoDoorbell: t("Doorbell"), airPurifier: t("Air purifier"), heater: t("Heater"), airConditioner: t("Air conditioner"),
    humidifier: t("Humidifier"), dehumidifier: t("Dehumidifier"), appleTV: "Apple TV", homePod: "HomePod", speaker: t("Speaker"),
    airport: "AirPort", sprinkler: t("Sprinkler"), faucet: t("Faucet"), showerHead: t("Shower head"), television: t("Television"),
    targetController: t("Remote"), wifiRouter: t("Wi-Fi router"), audioReceiver: t("Audio receiver"), tvSetTopBox: t("Set-top box"),
    tvStreamingStick: t("Streaming stick") };
  const categoryName = (key = "") => categoryNames[key] ?? key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (first) => first.toUpperCase());
  /// The icon that stands for a device's category: its widget tile's, else a generic one.
  const deviceIcon = (category) => HomeswiftWidgets.categoryIcon(category) ?? "generic";
  /// An accessory's icon: the one its tile shows (its main service's widget, else its category's), else a generic one.
  const accessoryIcon = (accessory) => HomeswiftWidgets.accessoryIcon(accessory) ?? "generic";
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
  // Graph coordinates have homeswift at the origin.
  const polar = (radius, angle) => [radius * Math.cos(angle), radius * Math.sin(angle)];

  /// What the graph and its table show, from /api/status (bridges), /api/plugins (blocks and their platforms) and
  /// /api/accessories. A plugin block sits under the bridge its platform entry names; a plugin's accessories are the
  /// ones of its platform on that bridge, given to the first block that has them. A `filter` (see `overviewFilter`)
  /// keeps the accessories it matches, and only the plugins and bridges that still have some.
  /// A plugin's branch, or one of the Matter block's: its accessories by device type, then name.
  function branchOf(fields, leaves) {
    leaves.sort((a, b) => a.category.localeCompare(b.category) || a.name.localeCompare(b.name));
    const sub = fields.paused ? t("Paused") : leaves.length ? tn("{n} accessory", "{n} accessories", leaves.length, {}) : t("No accessories");
    return { kind: "plugin", ...fields, leaves, sub };
  }

  /// The ids of the Matter block's devices, from /api/matter (nothing else of it is kept: it carries pairing codes).
  const matterIDs = (matter) => matter?.enabled ? {
    own: new Set((matter.ownDevices ?? []).map((device) => device.id)), bridged: new Set((matter.devices ?? []).map((device) => device.id)),
  } : null;

  function overviewModel(status, plugins, accessories, filter = null, matter = null) {
    const bridges = status.bridges ?? [];
    const main = bridges.find((bridge) => !bridge.childBridge) ?? bridges[0];
    const tops = bridges.map((bridge) => ({
      kind: bridge.childBridge ? "child" : "bridge", name: bridge.name, paired: bridge.paired, children: [], raw: bridge, count: bridge.accessories ?? 0,
      sub: tn("{n} accessory", "{n} accessories", bridge.accessories ?? 0, {}) }));
    const topByName = new Map(tops.map((top) => [top.name, top]));
    const entries = plugins?.platforms ?? [];
    const claimed = new Set();
    let pluginCount = 0, pausedCount = 0, colorIndex = 0;
    for (const block of plugins?.blocks ?? []) {
      if (block.system) {
        const top = { kind: "system", name: block.name, children: [], sub: t("Built in") };
        // The Matter block: its devices of their own and its bridged ones. Each is a copy of the accessory it shows: the
        // layout places the plugin's dot and this one apart.
        if (block.platform === "HomeswiftMatter" && matter) {
          top.icon = "matter";
          for (const [name, ids] of [[t("Devices of their own"), matter.own], [t("Bridged over Matter"), matter.bridged]]) {
            let leaves = accessories.filter((accessory) => ids.has(accessory.id));
            if (filter) leaves = leaves.filter(filter.keeps);
            if (leaves.length) top.children.push(branchOf({ name, icon: "matter", matter: true, color: "var(--ok)" }, leaves.map((one) => ({ ...one }))));
          }
          top.sub = tn("{n} accessory", "{n} accessories", top.children.reduce((sum, branch) => sum + branch.leaves.length, 0), {});
        }
        tops.push(top);
        continue;
      }
      const entry = entries.find((one) => one.name === block.name);
      const bridgeName = entry?.bridge ?? main?.name;
      const parent = topByName.get(bridgeName);
      if (!parent) continue;
      // Counted before the filter, so that a plugin keeps its colour however the graph is filtered.
      const color = `var(${branchColors[colorIndex++ % branchColors.length]})`;
      const key = `${block.platform}|${bridgeName}`;
      let leaves = claimed.has(key) ? [] : accessories.filter((accessory) => accessory.platform === block.platform && accessory.bridge === bridgeName);
      claimed.add(key);
      if (filter) {
        leaves = leaves.filter(filter.keeps);
        if (!leaves.length) continue;
      }
      const paused = Boolean(entry?.paused);
      pluginCount += 1;
      pausedCount += paused ? 1 : 0;
      parent.children.push(branchOf({ name: block.name, platform: block.platform, icon: block.icon ?? "plugin", bridgeName, paused, color }, leaves));
    }
    for (const top of tops) top.color = "var(--muted)";
    if (filter) tops.splice(0, tops.length, ...tops.filter((top) => top.children.length));
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
      for (const group of groups) {
        group.sub = tn("{n} accessory", "{n} accessories", group.leaves.length, {});
        // Devices of one kind under a category with no icon of its own (power stations filed as Other): their icon.
        const icons = new Set(group.leaves.map(accessoryIcon));
        if (group.icon === "generic" && icons.size === 1) group.icon = [...icons][0];
      }
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
    // The rings grow with the slots, so that neighbouring discs on the outer ring keep their gap, and with the nodes of
    // each inner ring, so that they fit around it side by side.
    const branches = tops.flatMap((top) => top.children), groups = branches.flatMap((branch) => branch.groups);
    const ringNodes = { top: tops, plugin: branches, group: groups };
    const fits = (ring) => (ringNodes[ring].length * nodeRoom(ring)) / (2 * Math.PI * 0.9 * ringShares[ring]);
    const leaf = Math.max(396, (total * (2 * disc.radius + disc.gap)) / (2 * Math.PI), fits("top"), fits("plugin"), fits("group"));
    const rings = { leaf, top: leaf * ringShares.top, plugin: leaf * ringShares.plugin, group: leaf * ringShares.group };
    // A filtered graph with few slots is a fan centred on the top, a slot as wide as on a graph of 24, not a whole circle.
    const span = filter ? Math.max(total, 24) : total;
    const angleOf = (value) => -Math.PI / 2 + ((value - (filter ? total / 2 : 0)) / span) * Math.PI * 2;
    tops.forEach((top) => {
      top.angle = angleOf(top.slot);
      top.radius = rings.top;
      for (const plugin of top.children) {
        plugin.angle = angleOf(plugin.slot);
        plugin.radius = rings.plugin;
        for (const group of plugin.groups) {
          group.color = plugin.color;
          group.angle = angleOf(group.slot);
          group.radius = rings.group;
          group.leaves.forEach((leaf, index) => { leaf.color = plugin.color; leaf.angle = angleOf(group.first + index + 0.5); leaf.radius = rings.leaf; });
        }
      }
    });
    // Nodes of an inner ring closer than their size are pushed apart, in order, each as little as it can be.
    for (const ring of Object.keys(ringNodes)) spread(ringNodes[ring], nodeRoom(ring) / rings[ring]);
    return { tops, status, rings, view: viewOf(tops, filter ? null : leaf), rootSub: t("Version {version}", { version: status.version ?? "" }),
      counts: { bridges: bridges.length, accessories: accessories.length, unavailable: accessories.filter((one) => one.unavailable).length, plugins: pluginCount, paused: pausedCount } };
  }

  /// The square the graph is drawn in: the whole outer ring, or, for a filtered graph (`leaf` null), the box of its nodes
  /// with a margin, no smaller than half the whole graph so that its icons are drawn at most twice as large.
  function viewOf(tops, leaf) {
    if (leaf) return { x: -(leaf + 32), y: -(leaf + 32), size: 2 * (leaf + 32) };
    const points = [[0, 0, 40]];
    for (const top of tops) {
      points.push([...polar(top.radius, top.angle), nodeRadius.top]);
      for (const plugin of top.children) {
        points.push([...polar(plugin.radius, plugin.angle), nodeRadius.plugin]);
        for (const group of plugin.groups) {
          points.push([...polar(group.radius, group.angle), nodeRadius.group]);
          for (const one of group.leaves) points.push([...polar(one.radius, one.angle), disc.radius]);
        }
      }
    }
    const margin = 36;
    const left = Math.min(...points.map(([x, , r]) => x - r)) - margin, right = Math.max(...points.map(([x, , r]) => x + r)) + margin;
    const top = Math.min(...points.map(([, y, r]) => y - r)) - margin, bottom = Math.max(...points.map(([, y, r]) => y + r)) + margin;
    const size = Math.max(right - left, bottom - top, 428);
    return { x: (left + right - size) / 2, y: (top + bottom - size) / 2, size };
  }

  /// Spaces the nodes of a ring at least `step` radians apart, keeping their order and moving them as little as possible:
  /// the circle is cut at its widest gap, then each run of nodes too close together is centred on where its nodes want to be.
  function spread(nodes, step) {
    if (nodes.length < 2) return;
    const sorted = [...nodes].sort((a, b) => a.angle - b.angle);
    let cut = 0, widest = -1;
    sorted.forEach((node, index) => {
      const gap = (sorted[index + 1]?.angle ?? sorted[0].angle + 2 * Math.PI) - node.angle;
      if (gap > widest) { widest = gap; cut = index + 1; }
    });
    const order = [...sorted.slice(cut), ...sorted.slice(0, cut)];
    const wanted = order.map((node, index) => node.angle + (index >= sorted.length - cut ? 2 * Math.PI : 0));
    // A block: its first node's index, its size, and the sum of where its nodes would put its start.
    const blocks = [];
    wanted.forEach((angle, index) => {
      let block = { first: index, count: 1, sum: angle };
      while (blocks.length) {
        const previous = blocks.at(-1);
        if (previous.sum / previous.count + previous.count * step <= block.sum / block.count) break;
        blocks.pop();
        block = { first: previous.first, count: previous.count + block.count, sum: previous.sum + block.sum - previous.count * step * block.count };
      }
      blocks.push(block);
    });
    for (const block of blocks) for (let k = 0; k < block.count; k += 1) order[block.first + k].angle = block.sum / block.count + k * step;
  }

  /// What the graph shows: the search's words (each in what the Accessories page searches, the accessory's type, maker,
  /// platform or bridge) and the chosen bridges, device types and unavailable ones. Null when nothing narrows it.
  function overviewFilter({ text = "", bridges = new Set(), categories = new Set(), unavailable = false }) {
    const words = text.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length && !bridges.size && !categories.size && !unavailable) return null;
    return {
      keeps(leaf) {
        if (bridges.size && !bridges.has(leaf.bridge)) return false;
        if (categories.size && !categories.has(leaf.category)) return false;
        if (unavailable && !leaf.unavailable) return false;
        const haystack = [HomeswiftWidgets.searchText(leaf), leaf.category, categoryName(leaf.category), leaf.manufacturer, leaf.platform, leaf.bridge]
          .filter(Boolean).join(" ").toLowerCase();
        return words.every((word) => haystack.includes(word));
      },
    };
  }

  /// The model of what homeswift runs, with what it was built from (the graph builds filtered ones from it).
  async function loadOverview() {
    const [status, plugins, accessories, matter] = await Promise.all([api("/api/status"), api("/api/plugins").catch(() => null),
      api("/api/accessories").catch(() => []), api("/api/matter").catch(() => null)]);
    const ids = matterIDs(matter);
    const model = overviewModel(status, plugins, accessories, null, ids);
    model.source = { status, plugins, accessories, matter: ids };
    return model;
  }

  /// Accessories › Graph: the radial graph of the bridges, their plugins and their accessories. Full screen (?full=1):
  /// the graph alone over the backdrop, as the wall's full screen, an address a wall tablet can open.
  async function graphPage(main, tabs) {
    const model = await loadOverview();
    const full = new URLSearchParams(location.search).get("full") === "1";
    const card = overviewCard(model, { full });
    if (full) {
      document.documentElement.classList.add("wall-full", "graph-full");
      app().show(main, card);
    } else {
      app().show(main, app().pageHead(t("Accessories"), t("What homeswift runs: its bridges, their plugins and the accessories each one publishes.")), tabs, card);
    }
  }
  /// In or out of the graph's full screen: the browser's too, where it can.
  function setGraphFullScreen(on) {
    if (on) document.documentElement.requestFullscreen?.().catch(() => {});
    else if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    app().navigate(`/accessories/graph${on ? "?full=1" : ""}`, { replace: true });
  }

  /// What a detail card shows: a name and icon (or the app's icon), a status, facts, and readings; an accessory's
  /// readings are grouped by service, worded as on the Accessories page, each with a tooltip saying what it is.
  function accessoryDetails(accessory) {
    const facts = [factRow("manufacturer", accessory.manufacturer), factRow("model", accessory.model), factRow("plugin", accessory.platformName ?? accessory.platform),
      factRow("bridge", accessory.bridge), factRow("category", categoryName(accessory.category))];
    // A camera shows its picture first: live while the card is open, else snapshots, as on the Accessories page.
    const camera = accessory.services?.some((service) => service.type === "CameraRTPStreamManagement");
    // What can be done to it from here: its widget, live, as on the wall (a tap toggles it, its main control is in reach),
    // every control in the wall's sheet, and Identify when it can. A camera's picture is its widget already.
    const actions = [
      { icon: "sliders", label: t("All controls"), run: () => HomeswiftWidgets.open(accessory) },
      accessory.supportsIdentify ? { icon: "identify", label: t("Identify"),
        run: () => api(`/api/accessories/${encodeURIComponent(accessory.id)}/identify`, { method: "POST" }).catch((e) => HomeswiftCommon.showAlert(e.message)) } : null,
    ].filter(Boolean);
    return { name: accessory.name, icon: accessoryIcon(accessory), status: deviceStatus(accessory), warn: Boolean(accessory.unavailable), facts, actions,
      media: camera ? () => HomeswiftWidgets.cameraView(accessory) : () => el("div", { class: "detail-widget" }, HomeswiftWidgets.card(accessory, { size: "large" })),
      sections: HomeswiftWidgets.valueSections(accessory) };
  }
  /// A card's fact: its label, its value, and a tooltip saying what it is.
  const factInfo = {
    manufacturer: [t("Manufacturer"), t("Who made the device, as its plugin reports it.")],
    model: [t("Model"), t("The device's model, as its plugin reports it.")],
    plugin: [t("Plugin"), t("The plugin that publishes it to HomeKit.")],
    platform: [t("Platform"), t("The platform name of this plugin's block in config.json.")],
    bridge: [t("Bridge"), t("The HomeKit bridge it is published on.")],
    category: [t("Type"), t("Its HomeKit category, which sets its icon in the Home app.")],
    bridgeType: [t("Type"), t("A bridge, a child bridge (plugins on a HomeKit server of their own) or a block built into homeswift.")],
    bridgeAccessories: [t("Accessories"), t("The accessories this bridge publishes to HomeKit.")],
    port: [t("Port"), t("The TCP port of its HomeKit server.")],
    deviceId: [t("Device ID"), t("The identifier HomeKit pairs with: a new one loses the pairing, rooms and automations.")],
    platforms: [t("Platforms"), t("The config.json platforms this bridge runs.")],
    state: [t("State"), t("Running, or paused: a paused plugin's accessories stay in HomeKit but do not respond.")],
    unavailable: [t("Unavailable"), t("Accessories whose device does not answer right now.")],
    categories: [t("Categories"), t("Its accessories by HomeKit category.")],
    version: [t("Version"), t("The homeswift version running.")],
    bridges: [t("Bridges"), t("The bridges homeswift runs, child bridges included.")],
    plugins: [t("Plugins"), t("The plugin blocks in config.json.")],
    accessories: [t("Accessories"), t("The accessories published to HomeKit, on every bridge.")],
    paused: [t("Paused"), t("Plugins paused: their accessories do not respond.")],
    host: [t("Host"), t("This machine's name on the network.")],
    os: [t("Operating system"), t("The system homeswift runs on.")],
    cpus: [t("Processors"), t("This machine's processor cores.")],
    memory: [t("Memory"), t("This machine's memory.")],
    update: [t("Update available"), t("Whether a newer homeswift release is out.")],
  };
  const factRow = (key, value) => { const [label, tip] = factInfo[key]; return [label, value, tip]; };
  function bridgeDetails(top) {
    const bridge = top.raw;
    const type = top.kind === "system" ? t("Built in") : t(top.kind === "child" ? "Child bridge" : "Bridge");
    return { name: top.name, icon: top.icon ?? (top.kind === "system" ? "system" : "bridge"), warn: top.paired === false,
      status: top.kind === "system" ? t("Built in") : top.paired ? t("Paired · {count}", { count: bridge.controllers ?? 0 }) : t("Not paired"),
      facts: [factRow("bridgeType", type), factRow("bridgeAccessories", top.count), factRow("port", bridge?.port), factRow("deviceId", bridge?.deviceId),
        factRow("platforms", bridge?.platforms?.join(", "))] };
  }
  function pluginDetails(plugin) {
    const categories = new Map();
    for (const leaf of plugin.leaves) categories.set(leaf.category, (categories.get(leaf.category) ?? 0) + 1);
    const unavailable = plugin.leaves.filter((one) => one.unavailable).length;
    return { name: plugin.name, icon: plugin.icon, status: plugin.sub, warn: unavailable > 0,
      facts: [factRow("platform", plugin.platform), factRow("bridge", plugin.bridgeName), plugin.matter ? null : factRow("state", plugin.paused ? t("Paused") : t("Running")),
        factRow("unavailable", unavailable || null), factRow("categories", [...categories].map(([key, count]) => `${categoryName(key)} ${count}`).join(", "))],
      items: accessoryItems(plugin.leaves) };
  }
  function homeswiftDetails(model) {
    const system = model.status.system ?? {};
    return { name: "Homeswift", image: "/icon.svg", warn: false, status: model.rootSub,
      facts: [factRow("version", model.status.version), factRow("bridges", model.counts.bridges), factRow("plugins", model.counts.plugins),
        factRow("accessories", model.counts.accessories), factRow("paused", model.counts.paused), factRow("host", system.hostname), factRow("os", system.os),
        factRow("cpus", system.cpus), factRow("memory", system.memoryBytes ? `${Math.round(system.memoryBytes / 2 ** 30)} GB` : ""),
        factRow("update", model.status.update?.available ? t("Yes") : t("No"))] };
  }
  /// Accessories as a card's rows: each with its device icon, its name and status, and its own card a click away.
  const accessoryItems = (leaves) => leaves.map((one) => ({ icon: accessoryIcon(one), name: one.name, status: deviceStatus(one),
    warn: Boolean(one.unavailable), details: () => accessoryDetails(one) }));
  /// A detail card's content: the head with the icon (a back button when `back` is given) and close, then its facts,
  /// its readings and its accessories, each of which `open` shows in the card's place.
  function detailNodes(data, close, { back = null, open = null } = {}) {
    const glyph = data.image ? el("img", { src: data.image, alt: "", width: 24, height: 24 }) : HomeswiftCommon.icon(data.icon);
    const shown = (facts) => facts.filter((fact) => fact && fact[1] !== undefined && fact[1] !== null && fact[1] !== "");
    // Rows of a label and a value, and a tooltip on the row when it has one.
    const list = (rows) => (rows.length ? el("dl", { class: "detail-list" }, ...rows.map(([label, value, tip]) =>
      el("div", { title: tip ?? null }, el("dt", { text: label }), el("dd", { text: String(value) })))) : null);
    const items = data.items ?? [];
    return [
      el("div", { class: "detail-head" },
        back ? el("button", { type: "button", class: "detail-back", actionIcon: "back", "aria-label": t("Back"), title: t("Back"), onclick: back }) : null,
        el("span", { class: `detail-glyph${data.image ? " app" : ""}` }, glyph),
        el("div", { class: "who" }, el("strong", { text: data.name }), el("div", { class: `detail-status${data.warn ? " warn" : ""}`, text: data.status })), close),
      data.media ? el("div", { class: "detail-media" }, data.media()) : null,
      data.actions?.length ? el("div", { class: "detail-actions" }, ...data.actions.map((action) =>
        el("button", { type: "button", class: action.primary ? "primary" : "", actionIcon: action.icon, text: action.label, onclick: action.run }))) : null,
      list(shown(data.facts)),
      ...(data.sections ?? []).map((section) => el("section", { class: "detail-section" }, el("h3", { class: "service-name", text: section.name }), list(section.rows))),
      items.length ? el("ul", { class: "detail-items", role: "list" }, ...items.map((item) =>
        el("li", {}, el("button", { type: "button", class: `detail-item${item.warn ? " warn" : ""}`, title: t("Show this accessory's card"), onclick: () => open?.(item.details()) },
          el("span", { class: "detail-item-glyph" }, HomeswiftCommon.icon(item.icon)),
          el("span", { class: "detail-item-name", text: item.name }),
          el("span", { class: "detail-item-status", text: item.status }),
          HomeswiftCommon.icon("forward"))))) : null,
    ];
  }

  /// A device-type group: its plugin, its accessories and how many are unavailable, then each accessory with its status.
  function groupDetails(group) {
    const unavailable = group.leaves.filter((one) => one.unavailable).length;
    return { name: group.name, icon: group.icon, status: group.sub, warn: unavailable > 0,
      facts: [group.plugin.matter ? null : factRow("plugin", group.plugin.name), factRow("bridge", group.plugin.bridgeName), factRow("unavailable", unavailable || null)],
      items: accessoryItems(group.leaves) };
  }

  /// The card: the radial graph with zoom (a click on a bridge or plugin, Ctrl-scroll or a trackpad pinch, a touch pinch,
  /// drag to pan, the buttons), a tooltip on hover and focus, the legend and a table of the same rows.
  function overviewCard(model, { full = false } = {}) {
    if (!model.tops.length) return el("section", { class: "card overview-card" }, el("p", { class: "muted", text: t("Nothing runs here yet.") }));
    // The graph's square (its viewBox, set by `redraw`), the zoomable layer in it, and what each node zooms to and shows.
    const svg = svgNode("svg", { class: "overview-graph", role: "group", "aria-label": t("Graph of the bridges, plugins and accessories") });
    let view = model.view, rings = model.rings, layer = null, targets = new Map(), details = new Map();
    const tip = el("div", { class: "overview-tip", role: "tooltip", hidden: true });
    const detail = el("div", { class: "overview-detail", role: "dialog", hidden: true });
    const frame = el("div", { class: "overview-frame" }, svg, tip, detail);
    let openNode = null;
    const closeDetail = () => { detail.hidden = true; openNode = null; };
    // A card's content; an accessory opened from a list keeps the way back to the list.
    const render = (data, previous = null) => {
      const close = el("button", { type: "button", class: "detail-close", actionIcon: "close", "aria-label": t("Close"), title: t("Close"), onclick: closeDetail });
      detail.replaceChildren(...detailNodes(data, close, {
        back: previous ? () => render(previous) : null,
        open: (child) => render(child, data),
      }).filter(Boolean));
      detail.setAttribute("aria-label", data.name);
      detail.scrollTop = 0;
      (previous ? detail.querySelector(".detail-back") : close).focus({ preventScroll: true });
      return close;
    };
    const openDetail = (node, anchored = true) => {
      const data = details.get(node)();
      render(data);
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
    };
    detail.addEventListener("keydown", (event) => { if (event.key === "Escape") { closeDetail(); svg.focus({ preventScroll: true }); } });
    const home = () => ({ k: 1, x: 0, y: 0 });
    const zoom = home();
    const maxZoom = 6;
    // A view kept inside the square: zoomed between 1 and the most, and panned no further than its edges.
    const bounded = ({ k, x, y }) => {
      const scale = Math.min(maxZoom, Math.max(1, k));
      const pan = (value, start) => Math.min((1 - scale) * start, Math.max((1 - scale) * (start + view.size), value));
      return { k: scale, x: pan(x, view.x), y: pan(y, view.y) };
    };
    const clamp = () => Object.assign(zoom, bounded(zoom));
    const apply = () => {
      layer.setAttribute("transform", `translate(${zoom.x} ${zoom.y}) scale(${zoom.k})`);
      svg.classList.toggle("deep", zoom.k >= 1.6);
    };
    // The view that scales by `factor` around the world point `at` (a screen point in the graph's units).
    const viewAt = (factor, at) => {
      const k = Math.min(maxZoom, Math.max(1, zoom.k * factor));
      const wx = (at.x - zoom.x) / zoom.k, wy = (at.y - zoom.y) / zoom.k;
      return bounded({ k, x: at.x - k * wx, y: at.y - k * wy });
    };
    const centre = () => ({ x: view.x + view.size / 2, y: view.y + view.size / 2 });
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
      if (focused === node) { focused = null; animateTo(home()); return; }
      focused = node;
      const [wx, wy] = polar(target.radius, target.angle), { x, y } = centre();
      // Zooms are given for the whole graph: a filtered one, drawn in a smaller square, needs less.
      const k = Math.max(1.4, target.k * view.size / (2 * (rings.leaf + 32)));
      animateTo({ k, x: x - k * wx, y: y - k * wy });
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
        const scale = view.size / svg.getBoundingClientRect().width;
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
    // The window's listeners go with the graph: the first event after it left the page removes them (and what they hold).
    const listening = new AbortController();
    const gone = () => { if (svg.isConnected) return false; listening.abort(); return true; };
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
      if (gone() || !pointers.has(event.pointerId)) return;
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
          const scale = view.size / svg.getBoundingClientRect().width;
          zoom.x = drag.zoomX + dx * scale; zoom.y = drag.zoomY + dy * scale;
          clamp(); apply();
        }
      }
    }, { signal: listening.signal });
    const release = (event) => {
      if (gone()) return;
      pointers.delete(event.pointerId);
      if (pointers.size < 2) pinch = null;
      if (pointers.size === 0) drag = null;
    };
    window.addEventListener("pointerup", release, { signal: listening.signal });
    window.addEventListener("pointercancel", release, { signal: listening.signal });

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
      if (zoom.k > 1 && !event.target.closest?.(".node, .root")) { focused = null; animateTo(home()); }
    });
    svg.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && zoom.k > 1) { focused = null; animateTo(home()); return; }
      if ((event.key === "Enter" || event.key === " ") && (event.target.dataset?.focus !== undefined || event.target.dataset?.detail !== undefined)) { event.preventDefault(); event.target.dispatchEvent(new MouseEvent("click", { bubbles: true })); }
    });

    // Placed in the frame, from its corner: a card's glass (a backdrop filter) makes it the box a fixed tooltip is
    // placed in, so window coordinates put it far from its node.
    const show = (target) => {
      const box = target.getBoundingClientRect(), origin = frame.getBoundingClientRect();
      tip.textContent = target.dataset.tip;
      tip.style.left = `${box.left - origin.left + box.width / 2}px`;
      tip.style.top = `${box.top - origin.top}px`;
      tip.hidden = false;
    };
    const hide = () => { tip.hidden = true; };
    svg.addEventListener("pointerover", (event) => { const target = event.target.closest?.("[data-tip]"); if (target) show(target); });
    svg.addEventListener("pointerout", (event) => { if (!event.relatedTarget?.closest?.("[data-tip]")) hide(); });
    svg.addEventListener("focusin", (event) => { if (event.target.dataset?.tip) show(event.target); });
    svg.addEventListener("focusout", hide);

    // Search and filters, as on the Accessories page: the graph is drawn again from what they keep, faded across.
    const { status, plugins, accessories: all, matter } = model.source;
    const chosen = { bridges: new Set(), categories: new Set(), unavailable: false };
    const search = el("input", { type: "search", class: "search", placeholder: t("Search accessories"), "aria-label": t("Search accessories") });
    const filters = el("button", { type: "button", "aria-haspopup": "menu" });
    const count = el("span", { class: "overview-count muted", role: "status" });
    const empty = el("div", { class: "overview-empty", hidden: true }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("search")),
      el("p", { class: "muted", text: t("No accessories match the current search.") }));
    frame.append(empty);
    const table = el("div");
    const active = () => chosen.bridges.size + chosen.categories.size + Number(chosen.unavailable);
    const filterOf = (except = {}) => overviewFilter({ text: search.value, ...chosen, ...except });
    // How many accessories a menu choice would show, with the search and the other choices as they are.
    const matching = (except) => { const filter = filterOf(except); return filter ? all.filter(filter.keeps).length : all.length; };
    const clear = HomeswiftCommon.clearFilters([[search, ""]], { active: () => active() > 0,
      reset: () => { chosen.bridges.clear(); chosen.categories.clear(); chosen.unavailable = false; } });
    // Every graph is built from the filter, the first too (a filtered build moves the accessories the builds share).
    const redraw = () => {
      const filter = filterOf();
      const next = overviewModel(status, plugins, all, filter, matter);
      closeDetail();
      tip.hidden = true;
      cancelAnimationFrame(animation);
      focused = null;
      ({ view, rings } = next);
      ({ layer, targets, details } = drawGraph(next));
      svg.setAttribute("viewBox", `${view.x} ${view.y} ${view.size} ${view.size}`);
      svg.replaceChildren(layer);
      Object.assign(zoom, home());
      apply();
      svg.animate([{ opacity: 0, scale: 0.97 }, { opacity: 1, scale: 1 }], { duration: matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 260, easing: "cubic-bezier(0.23, 1, 0.32, 1)" });
      // Each accessory once: the Matter block's branches show again accessories a plugin has.
      const shown = new Set(next.tops.flatMap((top) => top.children.flatMap((plugin) => plugin.leaves.map((leaf) => leaf.id)))).size;
      svg.hidden = !next.tops.length;
      empty.hidden = Boolean(next.tops.length);
      count.textContent = filter ? tn("{n} accessory", "{n} accessories", shown, {}) : "";
      filters.classList.toggle("on", active() > 0);
      filters.replaceChildren(...[HomeswiftCommon.icon("sliders"), el("span", { text: t("Filters") }), active() ? el("span", { class: "toolbar-count", text: active() }) : null].filter(Boolean));
      search.dispatchEvent(new Event("change")); // the Clear filters button's state
      table.replaceChildren(overviewTable(next));
    };
    let typing = 0;
    search.addEventListener("input", () => { clearTimeout(typing); typing = setTimeout(redraw, 160); });
    // A menu choice: a toggle in `set`, with what it would leave.
    const choice = (set, value, label, icon) => ({ label, icon, count: matching({ [set]: new Set(chosen[set]).add(value) }), checked: chosen[set].has(value),
      checkbox: true, toggle: true, onSelect: () => { if (!chosen[set].delete(value)) chosen[set].add(value); redraw(); } });
    const bridgeNames = (status.bridges ?? []).map((bridge) => bridge.name);
    const categories = [...new Set(all.map((one) => one.category))].sort((a, b) => categoryName(a).localeCompare(categoryName(b), locale));
    filters.addEventListener("click", () => HomeswiftCommon.menu(filters, [
      { label: t("Unavailable"), icon: "warning", tone: "error", count: matching({ unavailable: true }), checked: chosen.unavailable, checkbox: true, toggle: true,
        onSelect: () => { chosen.unavailable = !chosen.unavailable; redraw(); } },
      ...(bridgeNames.length > 1 ? [{ separator: true }, ...bridgeNames.map((name) => choice("bridges", name, name, "bridge"))] : []),
      ...(categories.length > 1 ? [{ separator: true }, ...categories.map((category) => choice("categories", category, categoryName(category), deviceIcon(category)))] : []),
      { separator: true },
      { label: t("Clear filters"), clearFilters: true, icon: "restore", disabled: clear.disabled, onSelect: () => clear.click() },
    ]));
    const fullScreenButton = el("button", { type: "button", class: "icon-button accessory-options-button", "aria-label": t("Full screen"), title: t("Full screen"),
      onclick: () => setGraphFullScreen(true) }, HomeswiftCommon.icon("expand"));
    const toolbar = el("div", { class: "accessories-toolbar overview-toolbar" }, search, filters, count, clear, full ? null : fullScreenButton);
    redraw();

    const controls = el("div", { class: "overview-zoom" },
      el("button", { type: "button", actionIcon: "plus", text: t("Zoom in"), "aria-label": t("Zoom in"), title: t("Zoom in"), onclick: () => animateTo(viewAt(1.6, centre())) }),
      el("button", { type: "button", actionIcon: "minus", text: t("Zoom out"), "aria-label": t("Zoom out"), title: t("Zoom out"), onclick: () => animateTo(viewAt(1 / 1.6, centre())) }),
      el("button", { type: "button", actionIcon: "restore", text: t("Reset view"), "aria-label": t("Reset view"), title: t("Reset view"), onclick: () => animateTo(home()) }));
    // Only what the drawing cannot say itself: a plugin is named by its icon, its tooltip and its card.
    const legend = el("ul", { class: "overview-legend" },
      el("li", {}, el("i", { class: "legend-mark hollow" }), el("span", { text: t("Unavailable") })),
      el("li", {}, el("i", { class: "legend-mark status paused" }), el("span", { text: t("Paused") })),
      el("li", {}, el("i", { class: "legend-mark status warn" }), el("span", { text: t("Not paired") })));
    // Full screen: the graph and its zoom alone, the search and the filters in a panel from the one button left, and
    // that button and the zoom faded while nothing happens, as on the wall.
    const chrome = full ? graphFullScreenChrome(frame, search, filters, clear) : null;
    return el("section", { class: `card overview-card${full ? " graph-full-card" : ""}` },
      chrome,
      el("div", { class: "chart-head" }, el("div", { class: "who" }, el("strong", { text: t("Graph of the bridges, plugins and accessories") }),
        el("div", { class: "muted", text: t("Pinch or Ctrl-scroll to zoom. Click a bridge to see its plugins and accessories.") }))),
      toolbar, frame, controls, legend,
      el("details", { class: "overview-more" }, el("summary", {}, HomeswiftCommon.icon("grid"), el("span", { text: t("Show as a table") })), table));
  }

  /// The full-screen graph's chrome: the button that opens a panel with the search, the filters and Leave full screen;
  /// Escape (or the browser's own) leaves; a touch, the mouse or a key wakes the chrome, which fades a few seconds later.
  function graphFullScreenChrome(frame, search, filters, clear) {
    const optionsButton = el("button", { type: "button", class: "wall-full-button wall-full-options", "aria-label": t("Graph options"), "aria-haspopup": "dialog",
      title: t("Graph options"), onclick: () => app().openSheet((done) => el("div", { class: "wall-full-panel" },
        el("h2", { id: "graph-full-panel-title", text: t("Graph") }),
        search, el("div", { class: "actions graph-full-filters" }, filters, clear),
        el("div", { class: "actions" },
          el("button", { type: "button", actionIcon: "close", text: t("Leave full screen"), onclick: () => { done(); setGraphFullScreen(false); } }),
          el("button", { type: "button", actionIcon: "check", class: "primary", text: t("Done"), onclick: () => done() }))),
      "graph-full-panel-title", { returnFocus: optionsButton }) }, HomeswiftCommon.icon("sliders"));
    let sleepTimer = null;
    const wake = () => {
      document.documentElement.classList.add("wall-awake");
      clearTimeout(sleepTimer);
      sleepTimer = setTimeout(() => document.documentElement.classList.remove("wall-awake"), 3000);
    };
    // Listeners on the window for this view only: each goes once the graph has left the page.
    const gone = () => !frame.isConnected;
    const onKey = (event) => {
      if (gone()) { removeEventListener("keydown", onKey); return; }
      wake();
      // A menu, a sheet or the inspector open has the keys.
      if (document.querySelector("dialog[open], .menu:not(.closing)") || event.target.closest?.("input, textarea, select, .overview-detail")) return;
      if (event.key === "Escape") { event.preventDefault(); setGraphFullScreen(false); }
    };
    const onPointer = () => { if (gone()) { removeEventListener("pointermove", onPointer); removeEventListener("pointerdown", onPointer); return; } wake(); };
    const onFullScreen = () => {
      if (gone()) { document.removeEventListener("fullscreenchange", onFullScreen); return; }
      if (!document.fullscreenElement) setGraphFullScreen(false);
    };
    addEventListener("keydown", onKey);
    addEventListener("pointermove", onPointer, { passive: true });
    addEventListener("pointerdown", onPointer, { passive: true });
    if (document.fullscreenElement) document.addEventListener("fullscreenchange", onFullScreen);
    wake();
    return el("div", { class: "wall-full-chrome" }, optionsButton);
  }

  /// The radial graph: homeswift at the origin, each bridge an icon on the first ring, each plugin one on the second, each
  /// device type one on the third and each accessory a dot on the outer ring; names are in the tooltips and the cards.
  /// Returns the layer that zooms, the zoom target of each focusable node and what each node's card shows.
  function drawGraph(model) {
    const { rings } = model;
    const root = { radius: 0, angle: 0 };
    const edges = [], dots = [], nodes = [];
    const targets = new Map();
    const details = new Map();
    // A curve from the parent along its own angle to the child along the child's, bowing through the middle ring.
    const link = (from, to, classes, color) => {
      const mid = (from.radius + to.radius) / 2;
      const [x1, y1] = polar(from.radius, from.angle), [x2, y2] = polar(to.radius, to.angle);
      const [c1x, c1y] = polar(mid, from.angle), [c2x, c2y] = polar(mid, to.angle);
      return svgNode("path", { class: `edge ${classes}`, style: `--branch: ${color}`, d: `M${x1} ${y1} C${c1x} ${c1y} ${c2x} ${c2y} ${x2} ${y2}` });
    };
    // A node: a disc of `radius` with an icon `size` across, at its place on its ring, in its branch's colour; its name
    // in the tooltip; a click shows `card` and, with `zoom`, zooms to its branch.
    const node = (item, { classes, radius, icon, size = 16, tip, card, zoom = null }) => {
      const [x, y] = polar(item.radius, item.angle);
      const glyph = HomeswiftCommon.icon(icon);
      for (const [key, value] of [["x", -size / 2], ["y", -size / 2], ["width", size], ["height", size]]) glyph.setAttribute(key, value);
      const element = svgNode("g", { class: classes, transform: `translate(${x} ${y})`, style: `--branch: ${item.color}`, "data-tip": tip, "data-detail": "",
        "data-focus": zoom ? "" : null, tabindex: 0, "aria-label": tip }, svgNode("circle", { class: "node-disc", r: radius }), glyph);
      if (zoom) targets.set(element, { radius: zoom.radius, angle: item.angle, k: zoom.k });
      details.set(element, card);
      return element;
    };
    for (const top of model.tops) {
      edges.push(link(root, top, "trunk", top.color));
      nodes.push(node(top, { classes: `node bridge-node${top.kind === "system" ? " built-in" : ""}${top.paired === false ? " unpaired" : ""}`,
        radius: nodeRadius.top, icon: top.icon ?? (top.kind === "system" ? "system" : "bridge"), size: 20, tip: `${top.name} · ${top.sub}`,
        card: () => bridgeDetails(top), zoom: { radius: (rings.top + rings.plugin) / 2, k: 1.8 } }));
      for (const branch of top.children) {
        edges.push(link(top, branch, `branch${branch.paused ? " paused" : ""}`, branch.color));
        nodes.push(node(branch, { classes: `node plugin-node${branch.paused ? " paused" : ""}`, radius: nodeRadius.plugin,
          icon: branch.icon, tip: `${branch.name} · ${branch.sub}`,
          card: () => pluginDetails(branch), zoom: { radius: (rings.plugin + rings.leaf) / 2, k: 2.6 } }));
        for (const group of branch.groups) {
          edges.push(link(branch, group, "branch", branch.color));
          nodes.push(node(group, { classes: "node group-node", radius: nodeRadius.group, icon: group.icon, tip: `${group.name} · ${group.sub}`,
            card: () => groupDetails(group), zoom: { radius: (rings.group + rings.leaf) / 2, k: 2.8 } }));
          for (const accessory of group.leaves) {
            edges.push(link(group, accessory, "leaf", branch.color));
            dots.push(node(accessory, { classes: `dot${accessory.unavailable ? " unavailable" : ""}`, radius: disc.radius, icon: accessoryIcon(accessory),
              tip: `${accessory.name} · ${categoryName(accessory.category)} · ${deviceStatus(accessory)}`, card: () => accessoryDetails(accessory) }));
          }
        }
      }
    }
    const centre = svgNode("g", { class: "root", "data-tip": `Homeswift · ${model.rootSub}`, "data-detail": "", tabindex: 0, "aria-label": `Homeswift · ${model.rootSub}` },
      svgNode("image", { class: "root-icon", href: "/icon.svg", x: -28, y: -28, width: 56, height: 56 }));
    details.set(centre, () => homeswiftDetails(model));
    const layer = svgNode("g", { class: "zoom-layer" }, ...edges, ...dots, ...nodes, centre);
    return { layer, targets, details };
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

  window.HomeswiftAdmin = { view, graph: graphPage, history: showHistory, confirmAction };
})();
