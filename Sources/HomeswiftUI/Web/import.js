// The Homebridge config import (admin only). The page at /import chooses a config.json (from this computer, from the
// server's storage folder, or pasted), reviews what homeswift keeps, encrypts or drops, and saves it. The welcome page
// (/welcome) and the Plugins page's empty state offer it. The API answers with codes; each one is said here in words.
(() => {
  "use strict";

  const { el, icon } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;
  const app = () => window.HomeswiftApp;
  const MAX_BYTES = 1024 * 1024;
  const SECRET = "••••••••••••";

  // The picks of the tabs: each keeps its text or path and the answer of its check. They live only while the page is open.
  let picks = {};
  let tab = "upload";
  let folder = { path: "", entries: null, error: false, loading: false };
  let stage = null;       // the card the steps draw into
  let checkBox = null;    // the check's status box of the drawn step
  let nextButton = null;  // "Review config"
  let folderBox = null;   // the server's folder listing
  let pasteTimer = 0;

  // ---- Views -----------------------------------------------------------------

  function view(main) {
    picks = {};
    tab = window.isSecureContext === true ? "upload" : "server";
    folder = { path: "", entries: null, error: false, loading: false };
    stage = el("section", { class: "card import-card" });
    app().show(main,
      app().breadcrumb([t("Plugins"), "/plugins"], [t("Import a Homebridge config")]),
      app().pageHead(t("Import a Homebridge config"), t("Bring the platforms of an existing Homebridge into homeswift. You review every item before anything is saved.")),
      stage);
    chooseStep();
  }

  /// The welcome page after the first account: what is ready, the import offer, and starting empty.
  function welcome(main) {
    app().show(main, el("section", { class: "card import-welcome" },
      el("h1", { text: t("Your Homeswift is ready") }),
      el("p", { class: "lede", text: t("The bridge is running and you are signed in as the administrator.") }),
      el("ul", { class: "import-done" },
        el("li", {}, el("span", { class: "import-tick" }, icon("check")), t("Administrator account created")),
        el("li", {}, el("span", { class: "import-tick" }, icon("check")), t("homeswift is running"))),
      el("div", { class: "import-offer" },
        el("span", { class: "import-offer-icon", "aria-hidden": "true" }, icon("upload")),
        el("div", { class: "who" },
          el("h2", { text: t("Already run Homebridge?") }),
          el("p", { class: "muted", text: t("Import its config.json and keep what homeswift supports. Passwords are encrypted, and you review every item before anything is saved.") })),
        el("div", { class: "actions" },
          el("button", { type: "button", class: "primary", actionIcon: "upload", text: t("Import a Homebridge config"), onclick: () => app().navigate("/import") }),
          el("button", { type: "button", actionIcon: "plus", text: t("Start empty"), onclick: () => app().navigate("/status") }))),
      el("p", { class: "fine muted", text: t("Starting empty is fine. You can add plugins on the Plugins page at any time.") })));
  }

  /// The Plugins page's empty state while no plugin exists: the import as an action card.
  function offer() {
    return el("div", { class: "card empty import-offer-card" },
      el("span", { class: "empty-glyph" }, icon("upload")),
      el("p", { class: "import-offer-title", text: t("Already run Homebridge?") }),
      el("p", { class: "muted", text: t("No plugin yet. Add one below.") }),
      el("p", { class: "muted", text: t("Or import its config.json: homeswift keeps what it supports, and you review every item before anything is saved.") }),
      el("div", { class: "actions" },
        el("button", { type: "button", class: "primary", actionIcon: "upload", text: t("Import a Homebridge config"), onclick: () => app().navigate("/import") })));
  }

  /// After the first account is created: with no plugin yet, the welcome page; otherwise the Status page stays.
  async function afterSetup() {
    try {
      const plugins = await app().api("/api/plugins");
      // The web UI's and the Assistant's blocks are system blocks, not plugins: they do not count.
      if (!plugins.blocks.some((block) => !block.system)) app().navigate("/welcome", { replace: true });
    } catch {}
  }

  // ---- Step 1: choose the config ---------------------------------------------

  const stepNames = () => [t("Choose config"), t("Review"), t("Save")];

  function stepsList(current) {
    return el("ol", { class: "import-steps", "aria-label": t("Import steps") }, stepNames().map((name, index) => el("li", {
      class: index < current ? "done" : index === current ? "current" : "",
      "aria-current": index === current ? "step" : null,
    }, el("span", { class: "step-dot", "aria-hidden": "true", text: index < current ? "✓" : String(index + 1) }), name)));
  }

  const tabList = () => [["upload", t("This computer"), "upload"], ["server", t("On the server"), "system"], ["paste", t("Paste text"), "clipboard"]];

  function chooseStep() {
    const secure = window.isSecureContext === true;
    const tabButtons = tabList().map(([name, label, glyph]) => el("button", {
      type: "button", role: "tab", id: `import-tab-${name}`, "aria-controls": "import-panel", "aria-selected": String(name === tab),
      tabIndex: name === tab ? 0 : -1, class: name === tab ? "on" : "", actionIcon: glyph, text: label, onclick: () => switchTab(name),
    }));
    const panel = tab === "upload" ? uploadPanel(secure) : tab === "server" ? serverPanel() : pastePanel(secure);
    checkBox = el("div", { class: "import-check", role: "status", "aria-live": "polite" });
    nextButton = el("button", { type: "button", class: "primary", actionIcon: "forward", text: t("Review config"), disabled: true, onclick: () => reviewStep(picks[tab]) });
    stage.replaceChildren(
      stepsList(0),
      el("h2", { text: t("Choose your Homebridge config") }),
      el("p", { class: "lede", text: t("Pick the config.json, or paste its text. Nothing is saved until you review it.") }),
      el("div", { class: "group view-switch import-tabs", role: "tablist", "aria-label": t("How to add the config"), onkeydown: tabKeys }, tabButtons),
      el("div", { class: "import-panel-box", id: "import-panel", role: "tabpanel", "aria-labelledby": `import-tab-${tab}` }, panel),
      checkBox,
      el("div", { class: "actions import-foot" }, el("p", { class: "fine muted", text: t("Nothing is saved until you review it.") }), nextButton));
    renderCheck(picks[tab]);
  }

  function switchTab(name) {
    tab = name;
    chooseStep();
  }

  // The ARIA tabs pattern: Left and Right move between the source tabs, Home and End go to the ends. Focus follows
  // the selection, since the tabs are drawn again on each switch.
  function tabKeys(event) {
    const names = tabList().map(([name]) => name);
    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
    if (!step && event.key !== "Home" && event.key !== "End") return;
    event.preventDefault();
    const at = names.indexOf(tab);
    const next = event.key === "Home" ? 0 : event.key === "End" ? names.length - 1 : (at + step + names.length) % names.length;
    switchTab(names[next]);
    document.getElementById(`import-tab-${names[next]}`)?.focus();
  }

  const notice = (text) => el("p", { class: "import-notice", role: "note" }, icon("warning"), text);

  function uploadPanel(secure) {
    const pick = picks.upload;
    if (pick) {
      return el("div", { class: "import-picked" },
        el("span", { class: "import-picked-name" }, icon("check"), el("b", { text: pick.name }), el("span", { class: "muted", text: sizeText(pick.size) })),
        el("button", { type: "button", actionIcon: "close", text: t("Remove"), onclick: () => removePick("upload") }));
    }
    const input = el("input", {
      type: "file", id: "import-file", accept: ".json,application/json", class: "import-file-input", disabled: !secure,
      onchange: (event) => { const file = event.target.files[0]; event.target.value = ""; if (file) pickFile(file); },
    });
    return el("div", { class: "import-panel" },
      secure ? null : notice(t("Uploading needs a secure connection (HTTPS): the file passes through this browser. \"On the server\" works here, because the server reads the file itself.")),
      el("label", {
        class: `import-drop${secure ? "" : " is-off"}`,
        ondragover: (event) => event.preventDefault(),
        ondrop: (event) => { event.preventDefault(); const file = event.dataTransfer?.files?.[0]; if (file && secure) pickFile(file); },
      }, input, icon("upload"), el("strong", { text: t("Choose config.json") }), el("span", { class: "muted", text: t("or drop it here. Up to 1 MB.") })));
  }

  function pastePanel(secure) {
    const pasteBox = el("textarea", {
      id: "import-paste", spellcheck: false, autocapitalize: "off", autocomplete: "off", "aria-describedby": "import-check",
      "aria-label": t("config.json contents"), placeholder: '{ "bridge": { "name": "Homebridge" }, "platforms": [] }',
      disabled: !secure, value: picks.paste?.text ?? "", oninput: (event) => pasteChanged(event.target.value),
    });
    return el("div", { class: "import-panel" },
      secure
        ? el("p", { class: "import-secure" }, icon("lock"), t("Secure connection (HTTPS): pasting is allowed"))
        : notice(t("Pasting is off because this page is not on a secure connection (HTTPS). Use \"On the server\" instead.")),
      pasteBox);
  }

  /// Typed text is checked a moment after the typing stops; each keystroke replaces the pick, so an old answer is dropped.
  function pasteChanged(text) {
    clearTimeout(pasteTimer);
    const pick = text.trim() ? { source: "paste", text } : null;
    picks.paste = pick;
    renderCheck(pick);
    if (pick) pasteTimer = setTimeout(() => runCheck(pick), 400);
  }

  function removePick(name) {
    picks[name] = null;
    chooseStep();
  }

  function pickFile(file) {
    const pick = { source: "upload", name: file.name, size: file.size };
    picks.upload = pick;
    chooseStep();
    if (file.size > MAX_BYTES) { fail(pick, t("The file is over 1 MB, the largest config homeswift reads.")); return; }
    file.text().then((text) => { pick.text = text; runCheck(pick); }, () => fail(pick, t("The file could not be read.")));
  }

  // ---- Server folder -----------------------------------------------------------

  function serverPanel() {
    folderBox = el("div", { class: "import-folder" });
    if (folder.entries === null && !folder.loading) openFolder(folder.path);
    renderFolder();
    return folderBox;
  }

  async function openFolder(path) {
    folder = { path, entries: null, error: false, loading: true };
    renderFolder();
    try {
      const data = await app().api(`/api/import/browse?path=${encodeURIComponent(path)}`);
      if (folder.path !== path) return;
      folder = { path, entries: data.entries || [], error: false, loading: false };
    } catch {
      if (folder.path !== path) return;
      folder = { path, entries: null, error: true, loading: false };
    }
    renderFolder();
  }

  function renderFolder() {
    if (!folderBox) return;
    const crumbs = [{ label: t("Storage folder"), path: "" }, ...(folder.path ? folder.path.split("/") : []).map((name, index, parts) => ({ label: name, path: parts.slice(0, index + 1).join("/") }))];
    const trail = el("nav", { class: "import-crumbs", "aria-label": t("Folder") }, crumbs.flatMap((crumb, index) => [
      index ? el("span", { class: "muted", "aria-hidden": "true", text: "/" }) : null,
      el("button", { type: "button", class: "crumb", actionIcon: "folder", text: crumb.label, "aria-current": index === crumbs.length - 1 ? "page" : null, onclick: () => openFolder(crumb.path) }),
    ]));
    let list;
    if (folder.loading || (folder.entries === null && !folder.error)) list = el("div", { class: "import-loading" }, el("span", { class: "spinner", role: "status", "aria-label": t("Loading") }));
    else if (folder.error) list = el("p", { class: "error", text: t("This folder could not be opened.") });
    else if (folder.entries.length === 0) list = el("p", { class: "muted", text: t("Nothing to pick here: no folders or .json files.") });
    else list = el("ul", { class: "import-files", "aria-label": t("Files on the server") }, folder.entries.map(entryRow));
    folderBox.replaceChildren(trail, list);
  }

  function entryRow(entry) {
    const path = [folder.path, entry.name].filter(Boolean).join("/");
    if (entry.kind === "folder") {
      return el("li", {}, el("button", { type: "button", class: "import-file", actionIcon: "folder", onclick: () => openFolder(path) },
        el("span", { class: "name", text: entry.name }), el("span", { class: "meta", text: t("Folder") })));
    }
    const selected = picks.server?.path === path;
    return el("li", {}, el("button", { type: "button", class: "import-file", actionIcon: "file", "aria-pressed": String(selected), onclick: () => pickServer(path, entry) },
      el("span", { class: "name", text: entry.name }),
      el("span", { class: "meta", text: [sizeText(entry.size), dateText(entry.modified)].filter(Boolean).join(", ") })));
  }

  function pickServer(path, entry) {
    const pick = { source: "server", path, name: entry.name, size: entry.size };
    picks.server = pick;
    chooseStep();
    runCheck(pick);
  }

  // ---- The check -----------------------------------------------------------------

  const requestBody = (pick) => (pick.source === "server" ? { source: "server", path: pick.path } : { source: pick.source, text: pick.text });
  const isReady = (pick) => Boolean(pick && pick.status === "done" && pick.result && pick.result.valid);

  function runCheck(pick) {
    pick.status = "checking";
    pick.result = null;
    pick.failure = null;
    if (pick.text !== undefined && new Blob([pick.text]).size > MAX_BYTES) { fail(pick, t("The config is over 1 MB, the largest config homeswift reads.")); return; }
    renderIfShown(pick);
    app().api("/api/import/check", { method: "POST", body: requestBody(pick) }).then((report) => {
      if (picks[pick.source] !== pick) return;
      pick.status = "done";
      pick.result = report;
      renderIfShown(pick);
    }, (error) => {
      if (picks[pick.source] !== pick) return;
      fail(pick, failureText(error));
    });
  }

  function fail(pick, text) {
    pick.status = "failed";
    pick.failure = text;
    renderIfShown(pick);
  }

  function renderIfShown(pick) {
    if (picks[pick.source] === pick && tab === pick.source) renderCheck(pick);
  }

  const CHECK_ICON = { ok: "check", warn: "warning", error: "warning", neutral: "file" };

  function setCheck(kind, heading, lines = []) {
    checkBox.dataset.state = kind;
    checkBox.replaceChildren(
      el("p", { class: "import-check-head" },
        kind === "checking" ? el("span", { class: "spinner", role: "status", "aria-label": t("Checking…") }) : icon(CHECK_ICON[kind]),
        el("b", { text: heading })),
      ...lines.map((line) => (line.nodeType ? line : el("p", { class: "import-check-line", text: line }))));
  }

  function renderCheck(pick) {
    if (!checkBox) return;
    if (nextButton) nextButton.disabled = !isReady(pick);
    if (!pick || pick.status === undefined) return setCheck("neutral", t("Choose a config to check it."));
    if (pick.status === "checking") return setCheck("checking", t("Checking…"));
    if (pick.status === "failed") return setCheck("error", pick.failure);
    const report = pick.result;
    const warnings = (report.warnings || []).map(warningText);
    if (!report.valid) {
      const lines = [
        ...(report.problems || []).map(problemText),
        ...(report.syntax ? [syntaxLine(report.syntax)] : []),
        ...warnings,
      ];
      return setCheck("error", t("This config cannot be imported yet"), lines);
    }
    const summary = report.summary || {};
    const lines = [
      tn("{n} platform: {encrypted} encrypted, {dropped} dropped.", "{n} platforms: {encrypted} encrypted, {dropped} dropped.", summary.platforms ?? 0,
        { encrypted: summary.encrypted ?? 0, dropped: summary.dropped ?? 0 }),
      ...warnings,
    ];
    setCheck(warnings.length ? "warn" : "ok", warnings.length ? t("Ready to review, with a note") : t("Ready to review"), lines);
  }

  /// A problem's code and its arguments, said in words (the API answers codes, never sentences to show).
  function problemText({ code, args = {} }) {
    switch (code) {
      case "tooLarge": return t("The config is over 1 MB ({kilobytes} KB).", { kilobytes: args.kilobytes });
      case "notObject": return t("The config must be a JSON object, between braces.");
      case "bridgeNotObject": return t("The bridge block must be an object.");
      case "platformsNotList": return t("The platforms must be a list.");
      case "platformNotObject": return t("Platform {index} must be an object.", { index: Number(args.index) + 1 });
      case "platformNameMissing": return t("Platform {index} has no name.", { index: Number(args.index) + 1 });
      case "disabledPluginsNotList": return t("The disabled plugins must be a list.");
      case "duplicatePlatform": return t("The platform {name} is listed twice.", { name: args.name });
      case "sealedLookingValue": return t("A value starts with enc:v1:, the prefix homeswift gives the secrets it seals. Remove the prefix, or set the secret as plain text in Homebridge.");
      case "nothingToImport": return t("Nothing in this file can be imported. Check that the file is your Homebridge config.json and that its platforms are ones homeswift runs.");
      case "invalidConfig": return el("span", {}, t("homeswift cannot use this config."), " ", el("code", { class: "import-detail", text: String(args.detail ?? "") }));
      default: return t("homeswift cannot read part of this config.");
    }
  }

  function warningText({ code, args = {} }) {
    switch (code) {
      case "accessoriesSkipped": return tn("{n} accessory is skipped by homeswift.", "{n} accessories are skipped by homeswift.", args.count);
      case "bridgeKeptExisting": return t("The bridge block is not copied: homeswift keeps its own bridge settings.");
      case "disabledMatchesNothing": return t("The disabled plugin {name} matches no plugin here, so nothing is paused.", { name: args.name });
      default: return t("Part of the config needs a look before saving.");
    }
  }

  function syntaxLine(syntax) {
    return el("p", { class: "import-check-line" },
      syntax.hint === "unexpectedEnd" ? t("The text ends too soon. A bracket or a quote is probably missing.") : t("Something in the syntax is wrong near this place."),
      " ", t("Line {line}, column {column}.", { line: syntax.line, column: syntax.column }),
      syntax.detail ? el("code", { class: "import-detail", text: syntax.detail }) : null);
  }

  function failureText(error) {
    if (error.status === 403) return t("This page is not on a secure connection (HTTPS), so the text cannot be sent. Use \"On the server\" instead.");
    if (error.status === 413) return t("The config is over 1 MB, the largest config homeswift reads.");
    if (error.status === 401) return t("Sign in again to continue.");
    return error.status ? t("homeswift answered with an error ({status}).", { status: error.status }) : t("homeswift could not be reached.");
  }

  const sizeText = (bytes) => (bytes == null ? "" : t("{kilobytes} KB", { kilobytes: Math.max(1, Math.round(bytes / 1024)) }));
  const dateText = (iso) => {
    const date = iso ? new Date(iso) : null;
    return date && !isNaN(date) ? new Intl.DateTimeFormat(HomeswiftI18n.locale, { dateStyle: "medium", timeStyle: "short" }).format(date) : "";
  };

  // ---- Step 2: review ----------------------------------------------------------

  // What each outcome reads as: its pill, what its value shows, what is saved, and what it does when no note says more.
  const OUTCOMES = {
    imported: {
      label: () => t("Imported"),
      saved: () => t("Plain text in config.json"),
      effect: () => t("Kept as written; the plugin reads it when it starts."),
    },
    encrypted: {
      label: () => t("Encrypted"),
      saved: () => t("Encrypted in config.json, with the key in the bridge's owner-only key file"),
      effect: () => t("The secret is sealed with the bridge's key and decrypted in memory when homeswift starts. It is never logged or shown in the web UI."),
    },
    dropped: {
      label: () => t("Dropped"),
      saved: () => t("Not saved"),
      effect: () => t("homeswift has no equivalent, so nothing is saved."),
    },
  };
  const outcomeOf = (item) => OUTCOMES[item.outcome] || OUTCOMES.imported;

  function valueText(item) {
    if (item.outcome === "encrypted") return SECRET;
    if (item.count != null) return tn("{n} entry", "{n} entries", item.count);
    return item.value ?? "";
  }

  function noteText({ code, args = {} }) {
    switch (code) {
      case "webUI": return t("This is Homebridge's own web UI. homeswift has its own, which replaces it, so nothing is kept.");
      case "unsupportedPlatform": return t("No plugin in this homeswift provides {platform}, so the block is kept but does nothing.", { platform: args.platform });
      case "notSetting": return t("{platform} does not read this setting, so it is kept as written and has no effect.", { platform: args.platform });
      case "nestedConfig": return t("A group of settings. Each setting inside it is reviewed on its own row.");
      case "notUsed": return t("homeswift does not read this value. It stays in config.json as written.");
      case "numericSecret": return t("A number or a yes/no under a secret's name is not kept: homeswift keeps secrets as text. Set it as text in Homebridge to import it.");
      case "paused": return t("Disabled in Homebridge. It is imported paused and does not start until it is resumed.");
      default: return t("Kept as written.");
    }
  }

  // A note says why a setting is kept, dropped or paused; without one, the outcome says what happens.
  function effectText(item) {
    const lines = [];
    if (item.outcome === "encrypted" || !item.note) lines.push(outcomeOf(item).effect());
    if (item.note) lines.push(noteText(item.note));
    return lines.join(" ");
  }

  function itemRow(item) {
    const chevron = icon("down");
    chevron.classList.add("chev");
    return el("details", { class: `import-item ${item.outcome}` },
      el("summary", {},
        el("span", { class: "import-key", text: item.path }),
        el("span", { class: `import-value${item.outcome === "encrypted" ? " masked" : ""}`, text: valueText(item) }),
        el("span", { class: `import-pill ${item.outcome}`, text: outcomeOf(item).label() }),
        chevron),
      el("dl", { class: "import-detail-list" },
        el("div", {}, el("dt", { text: t("Saved as") }), el("dd", { text: outcomeOf(item).saved() })),
        el("div", {}, el("dt", { text: t("What it does") }), el("dd", { text: effectText(item) }))));
  }

  const countBox = (kind, number, label) => el("div", { class: `import-count ${kind}` }, el("b", { text: String(number) }), el("span", { text: label }));

  function sourceText(pick) {
    if (pick.source === "server") return t("From the server: {name}", { name: pick.name });
    if (pick.source === "upload") return t("From this computer: {name}", { name: pick.name });
    return t("Pasted text");
  }

  function reviewStep(pick) {
    const report = pick.result;
    const items = report.items || [];
    const count = (outcome) => items.filter((item) => item.outcome === outcome).length;
    const groups = new Map();
    for (const item of items) groups.set(item.group, [...(groups.get(item.group) || []), item]);
    const feedback = el("p", { class: "error", role: "alert" });
    const backButton = el("button", { type: "button", actionIcon: "back", text: t("Back"), onclick: () => chooseStep() });
    const saveButton = el("button", { type: "button", class: "primary", actionIcon: "check", text: t("Save and import"), onclick: () => saveConfig(pick, saveButton, feedback) });
    stage.replaceChildren(
      stepsList(1),
      el("h2", { text: t("Review your Homebridge config") }),
      el("p", { class: "lede", text: t("Nothing is saved yet. Each item shows what homeswift will do with it. Secrets are never stored as plain text.") }),
      el("p", { class: "import-source" }, icon("file"), sourceText(pick)),
      el("div", { class: "import-summary", "aria-label": t("Summary") },
        countBox("imported", count("imported"), t("Imported")),
        countBox("encrypted", count("encrypted"), t("Encrypted")),
        countBox("dropped", count("dropped"), t("Dropped"))),
      // replaceChildren takes nodes only: no null, no arrays, so each list is spread.
      ...(items.length === 0 ? [el("p", { class: "muted", text: t("Nothing to import: the config has no platform.") })] : []),
      ...[...groups].map(([name, list]) => el("section", { class: "import-group" },
        el("div", { class: "import-group-head" }, el("h3", { text: name }), el("span", { class: "muted", text: tn("{n} item", "{n} items", list.length) })),
        el("div", { class: "import-rows" }, list.map(itemRow)))),
      feedback,
      el("div", { class: "actions import-foot" },
        el("p", { class: "fine muted", text: t("Encrypted values open only with this bridge's key file. Keep the key file with the config.") }),
        el("div", { class: "end" }, backButton, saveButton)));
  }

  // ---- Step 3: save ---------------------------------------------------------------

  /// The save answers 200 with what it wrote, or 422 with the same report as the check when invalid (nothing written).
  /// The report is read here, not through the shared helper, which keeps only the problems.
  async function postSave(body) {
    const response = await fetch("/api/import/save", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept-Language": HomeswiftI18n.locale },
      body: JSON.stringify(body),
    });
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = null; }
    if (response.status === 422 && data) return { invalid: true, report: data };
    if (!response.ok) {
      const error = new Error(String(response.status));
      error.status = response.status;
      throw error;
    }
    return data;
  }

  async function saveConfig(pick, button, feedback) {
    button.disabled = true;
    button.classList.add("busy");
    feedback.textContent = "";
    try {
      const outcome = await postSave(requestBody(pick));
      if (outcome.invalid) {
        pick.result = outcome.report;
        pick.status = "done";
        tab = pick.source;
        chooseStep();
        return;
      }
      doneStep(outcome);
    } catch (error) {
      feedback.textContent = failureText(error);
      button.disabled = false;
      button.classList.remove("busy");
    }
  }

  function doneStep(outcome) {
    const restart = el("p", { class: "muted", text: t("Saved and applied.") });
    stage.replaceChildren(
      stepsList(2),
      el("h2", { text: t("Your config is imported") }),
      el("p", { class: "lede", text: tn("{n} platform is saved in config.json.", "{n} platforms are saved in config.json.", outcome.summary?.platforms ?? 0) }),
      el("p", { class: "muted", text: t("The config from before this save is kept as {backup}.", { backup: outcome.backup }) }),
      restart,
      el("div", { class: "actions" },
        el("button", { type: "button", class: "primary", actionIcon: "plugin", text: t("Open the Plugins page"), onclick: () => app().navigate("/plugins") })));
    // A restart is needed only when the saved bridge settings wait for one; the banner says so, as after a save elsewhere.
    app().api("/api/status").then((status) => {
      restart.textContent = status.restartNeeded ? t("Saved. Restart homeswift to apply the rest.") : t("Saved and applied.");
      document.querySelector("#banner")?.classList.toggle("hidden", !status.restartNeeded);
    }, () => {});
  }

  window.HomeswiftImport = { view, welcome, offer, afterSetup };
})();
