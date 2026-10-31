// Homeswift web UI: one page, plain JavaScript, no dependencies. Talks to /api/* with the session cookie.
(() => {
  "use strict";

  const { $, el, tile, sparkle, menuButton, copyText, markdown, jsonEditor, jsonView, fact, setPaused, slug, withSlugs } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;

  const show = (main, ...nodes) => main.replaceChildren(...nodes.flat().filter(Boolean));
  /// A translated sentence with elements in it: each `{name}` of `text` is the node `nodes[name]`.
  const withNodes = (text, nodes) => text.split(/(\{\w+\})/).filter(Boolean).map((part) => (/^\{\w+\}$/.test(part) && nodes[part.slice(1, -1)]) || part);

  /// `problems`: what a save changed that its plugin's schema refuses, each with its path (`ConfigSchemaError`).
  class ApiError extends Error { constructor(status, message, problems) { super(message); this.status = status; this.problems = problems; } }

  async function api(path, { method = "GET", body, raw = false } = {}) {
    // The Assistant answers in the page's language.
    const options = { method, credentials: "same-origin", headers: { "Accept-Language": HomeswiftI18n.locale } };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = typeof body === "string" ? body : JSON.stringify(body); }
    const response = await fetch(path, options);
    if (response.status === 401 && !path.startsWith("/api/auth/")) { showAuth(); throw new ApiError(401, "signed out"); }
    const text = await response.text();
    if (!response.ok) {
      let message = text, problems;
      try { ({ error: message = text, problems } = JSON.parse(text)); } catch {}
      throw new ApiError(response.status, HomeswiftI18n.message(message || `HTTP ${response.status}`), problems);
    }
    return raw ? text : (text ? JSON.parse(text) : null);
  }

  // ---- Authentication ------------------------------------------------------

  let auth = null;
  // The server's secret-key rule (see the settings page): set with the plugin list, read by the JSON secret note.
  let secretRule = null;
  /// The server's rule (Redaction): whether a key holds a secret; with its value, an `auth` that is a sign-in mode
  /// ("form", "none") does not.
  const isSecretKey = (key, value) => Boolean(secretRule) && secretRule.keys.test(key) && !secretRule.except.test(key)
    && !(/^auth$/i.test(key) && secretRule.signInModes.includes(value));
  const readSecretRule = (plugins) => plugins.secretRule ? {
    keys: new RegExp(plugins.secretRule.keys, "i"), except: new RegExp(plugins.secretRule.except, "i"), placeholder: plugins.secretRule.placeholder,
    reference: new RegExp(plugins.secretRule.reference), signInModes: plugins.secretRule.signInModes || [],
  } : null;
  /// The server's rule (Redaction.referencePattern): whether a value names a secret kept elsewhere (`vault:<name>`).
  const isReference = (value) => Boolean(secretRule) && secretRule.reference.test(value);

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
      ? t("Create the administrator account for this bridge. The set-up code is in the bridge's output, next to the web UI address.")
      : t("Sign in to manage the bridge.");
    $("#auth-submit").textContent = setup ? t("Create account") : t("Sign in");
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
    submit.textContent = auth && auth.setupNeeded ? t("Creating the account…") : t("Signing in…");
    const body = { username: form.username.value, password: form.password.value };
    try {
      if (auth && auth.setupNeeded) {
        if (setupGauge && !(await setupGauge.acceptable())) throw new Error(t("The password is not strong enough yet: the gauge says what is missing."));
        body.setupCode = form.setupCode.value;
      }
      if (!$("#auth-otp").classList.contains("hidden")) body.otp = form.otp.value;
      const firstRun = Boolean(auth && auth.setupNeeded);
      await api(auth && auth.setupNeeded ? "/api/auth/setup" : "/api/auth/login", { method: "POST", body });
      form.password.value = "";
      askCode(false);
      await loadAuth();
      // The first account: with no plugin yet, the welcome page offers the import (import.js).
      if (firstRun) window.HomeswiftImport?.afterSetup();
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
    // Under the name in the side menu: what the account is; without sign-in, that alone, never a bare avatar.
    $("#user .user-role").textContent = auth.mode !== "form" ? t("No sign-in") : isAdmin() ? t("Administrator") : t("User");
    $("#user .user-chevron").replaceChildren(HomeswiftCommon.icon("selector"));
    $("#user .user-burger").replaceChildren(HomeswiftCommon.icon("menu"));
    // A wide window's side menu has no account button: its menu's entries are You's, under Home's sections.
    const form = auth.mode === "form";
    const item = (glyph, text, onclick) => el("button", { type: "button", class: "side-action", onclick }, glyph, el("span", { text }));
    $("header nav.side-you").replaceChildren(...[
      el("a", { href: "/account" }, HomeswiftCommon.icon("user"), el("span", { text: form ? t("Your account") : t("Account") })),
      el("a", { href: "/appearance" }, HomeswiftCommon.icon("sun"), el("span", { text: t("Appearance") })),
      form && isAdmin() ? el("a", { href: "/users" }, HomeswiftCommon.icon("users"), el("span", { text: t("Users and tokens") })) : null,
      item(HomeswiftCommon.icon("globe"), t("Language"), (event) => languageMenu(event.currentTarget)),
      form ? item(HomeswiftCommon.icon("logout"), t("Sign out"), signOut) : null].filter(Boolean));
    for (const link of document.querySelectorAll("header nav.side-you a")) {
      const current = link.getAttribute("href") === `/${location.pathname.split("/")[1]}`;
      link.classList.toggle("active", current);
      if (current) link.setAttribute("aria-current", "page");
    }
  }

  // ---- Homeswift itself: its health, version, update and Send feedback -------------------------------------------
  // At the side menu's foot on a wide window, folded under one line; on a narrower one, in the Status page's footer.
  // One state, drawn in each place that shows it.

  let aboutStatus = null, aboutUpdate = null;
  // The Status page's update card, which an install from another control redraws.
  let overviewUpdate = null;

  /// Homeswift's health in a few words, and its tone (on, away).
  function healthOf(status) {
    const waiting = status.bridges.filter((bridge) => !bridge.paired).length;
    return status.restartNeeded ? [t("Running; some changes need a restart"), "away"]
      : waiting ? [tn("Running; one server waits to be added in the Home app", "Running; {n} servers wait to be added in the Home app", waiting), "away"]
      : [t("Running, and everything is in the Home app"), "on"];
  }

  const updateLabels = { error: () => t("Try again"), installing: () => updateProgressLabel(aboutUpdate), relaunching: () => t("Relaunching…"), installed: () => t("Relaunch to update"),
    available: () => aboutUpdate.canInstall ? t("Install update") : t("Update available"), current: () => t("Up to date"), idle: () => t("Check for updates") };

  /// Every update button as `phase` says (a failed check first), or `label` while it checks; the side menu's line
  /// marks an update waiting.
  function renderUpdateButtons(phase = aboutUpdate?.error ? "error" : updatePhase(aboutUpdate), label = updateLabels[phase](), only = null) {
    const state = phase === "installing" || phase === "relaunching" ? "checking" : phase;
    // The button fills as the download goes, when the bridge knows how far.
    const fraction = phase === "installing" && aboutUpdate?.progress?.phase === "downloading" ? aboutUpdate.progress.fraction : null;
    const buttons = only ? [only] : document.querySelectorAll(".footer-update-check");
    for (const button of buttons) {
      button.dataset.updateState = state;
      button.disabled = state === "checking";
      if (aboutUpdate?.error) button.title = t("Could not check for updates. Try again.");
      else button.removeAttribute("title");
      if (fraction == null) button.style.removeProperty("--update-progress");
      else button.style.setProperty("--update-progress", `${Math.round(fraction * 100)}%`);
      button.replaceChildren(HomeswiftCommon.icon(({ current: "check", available: "download", installed: "power", error: "warning" })[state] || "restore"),
        el("span", { class: "footer-update-label", text: label }));
    }
    if (!only) $("#side-about").classList.toggle("has-update", ["available", "installed"].includes(state));
  }

  // The overview's card, the sheet and the buttons all say what an install is doing.
  function updateChanged(next) {
    aboutUpdate = next;
    if (overviewUpdate?.isConnected && next?.available) overviewUpdate.show?.(next);
    renderUpdateButtons();
  }

  /// An update button: checks for one, shows what is new, installs an update the bridge can install itself (its
  /// progress in the button, then the restart), or relaunches into one Homebrew installed.
  function updateButton() {
    const button = el("button", { type: "button", class: "link footer-update-check", "aria-live": "polite", onclick: async (event) => {
      const showUpdate = () => openSheet((done) => el("div", {},
        el("h2", { id: "update-check-title", text: t("Updates") }), updateCard(aboutUpdate, { changed: updateChanged }),
        el("button", { actionIcon: "close", type: "button", text: t("Close"), onclick: () => done() })), "update-check-title", { returnFocus: button });
      if (updatePhase(aboutUpdate) === "installed") { restartBridge(event); return; }
      if (aboutUpdate?.available && aboutUpdate.canInstall && !aboutUpdate.error) { installUpdate(button, aboutUpdate, updateChanged); return; }
      if (aboutUpdate?.available && !aboutUpdate.error) { showUpdate(); return; }
      renderUpdateButtons("checking", t("Checking…"));
      try {
        aboutUpdate = await api("/api/updates/check", { method: "POST", body: {} });
        if (!aboutUpdate || aboutUpdate.error) throw new Error();
        if (aboutUpdate.available) showUpdate();
      } catch {
        aboutUpdate = { error: true };
      } finally {
        renderUpdateButtons();
      }
    } });
    renderUpdateButtons(undefined, undefined, button);
    return button;
  }

  /// The health, the version and host with an administrator's update button, and Send feedback: drawn anew for each
  /// place that shows them.
  function aboutParts(status) {
    const [health, kind] = healthOf(status);
    return {
      health: el("p", { class: `health ${kind}` }, el("strong", { text: health })),
      meta: el("div", { class: "status-footer-meta" },
        el("p", { class: "muted", text: t("Version {version} · {host}", { version: status.version, host: status.system.hostname }) }),
        isAdmin() ? updateButton() : null),
      feedback: el("a", { class: "link", href: "https://github.com/mp-consulting/homeswift/issues", target: "_blank", rel: "noopener", title: t("Send feedback"), "aria-label": t("Send feedback"),
        onclick: (event) => { event.preventDefault(); window.open(event.currentTarget.href, "homeswift-feedback", "popup,noopener,width=1100,height=800"); } },
        HomeswiftCommon.icon("bug"), el("span", { class: "status-footer-action-label", text: t("Send feedback") })),
    };
  }

  /// The side menu's foot: one line (the health's dot, the version, a mark when an update waits) that unfolds into
  /// the rest, open or folded as the viewer left it.
  function drawSideAbout(status) {
    aboutStatus = status;
    if (status.update) aboutUpdate = status.update;
    const about = aboutParts(status);
    const details = $("#side-about");
    details.replaceChildren(
      el("summary", {},
        el("span", { class: `side-about-dot ${healthOf(status)[1]}`, "aria-hidden": "true" }),
        el("span", { class: "side-about-title", text: t("Homeswift {version}", { version: status.version }) }),
        el("span", { class: "side-about-badge", role: "img", "aria-label": t("Update available"), title: t("Update available") }),
        HomeswiftCommon.icon("down")),
      el("div", { class: "side-about-body" }, about.health, about.meta, about.feedback,
        // Restarting, in the accent: an administrator's, and not a page like the rest.
        isAdmin() ? el("button", { type: "button", class: "link side-about-restart", onclick: restartBridge }, HomeswiftCommon.icon("power"), el("span", { text: t("Restart homeswift…") })) : null));
    details.hidden = false;
    renderUpdateButtons();
  }
  $("#side-about").open = (() => { try { return localStorage.getItem("homeswift.sideAbout") === "open"; } catch { return false; } })();
  $("#side-about").addEventListener("toggle", (event) => {
    try { localStorage.setItem("homeswift.sideAbout", event.currentTarget.open ? "open" : "folded"); } catch {}
  });

  // Its menu: who is signed in and as what, their account and appearance, the users for an administrator, signing out.
  $("#user").addEventListener("click", (event) => {
    event.stopPropagation();
    openUserMenu(event.currentTarget, event.detail === 0);
  });
  document.addEventListener("homeswift-account-menu", (event) => openUserMenu(event.detail.trigger, event.detail.keyboard));
  function openUserMenu(trigger, keyboard = false) {
    const form = auth.mode === "form";
    const phone = matchMedia("(max-width: 640px)").matches;
    HomeswiftCommon.menu(trigger, [
      form ? { heading: shownName(), detail: isAdmin() ? t("{username} · Administrator", { username: auth.username }) : auth.username } : { heading: t("No sign-in"), detail: t("Anyone who opens this web UI uses it") },
      { label: form ? t("Your account") : t("Account"), icon: "user", href: "/account" },
      { label: t("Appearance"), icon: "sliders", href: "/appearance" },
      form && isAdmin() ? { label: t("Users and tokens"), icon: "users", href: "/users" } : null,
      // A phone's tab bar has no room for Settings: it is here, as the header holds it on a wider window.
      phone && isAdmin() ? { label: t("Settings"), icon: "gear", href: "/settings" } : null,
      { label: t("Language"), icon: flag(HomeswiftI18n.language), onSelect: () => setTimeout(() => languageMenu(trigger)) },
      // On a phone this is the page's menu: Homeswift's health, version and updates are here too (the side menu
      // holds them on a wide window).
      ...(phone && aboutStatus ? [{ separator: true },
        { heading: t("Homeswift {version}", { version: aboutStatus.version }), detail: healthOf(aboutStatus)[0] },
        isAdmin() ? { label: updateLabels[aboutUpdate?.error ? "error" : updatePhase(aboutUpdate)](), icon: aboutUpdate?.available ? "download" : "update", href: "/settings/updates" } : null,
        { label: t("Send feedback"), icon: "bug", onSelect: () => window.open("https://github.com/mp-consulting/homeswift/issues", "_blank", "noopener") }] : []),
      // Restarting, apart and in the accent: an administrator's, and not a page like the rest.
      isAdmin() ? { separator: true } : null,
      isAdmin() ? { label: t("Restart homeswift…"), icon: "power", accent: true, onSelect: () => restartBridge() } : null,
      form ? { separator: true } : null,
      form ? { label: t("Sign out"), icon: "logout", onSelect: signOut } : null,
    ], { keyboard });
  }

  const flag = (code) => el("span", { class: "menu-flag", "aria-hidden": "true", text: code ? HomeswiftI18n.flags[code] : "🌐" });

  /// The language, from the account menu: Automatic (the browser's) or one of the four, each in its own name. Saved
  /// with the user's preferences, which opens the page again in it.
  function languageMenu(trigger = $("#user")) {
    const current = HomeswiftCommon.preferences().language || "auto";
    const choose = async (code) => {
      if (code === current) return;
      try { HomeswiftCommon.applyPreferences(await api("/api/preferences", { method: "PUT", body: { language: code } })); } catch (e) { HomeswiftCommon.showAlert(e.message); }
    };
    HomeswiftCommon.menu(trigger, [
      { label: t("Automatic"), icon: flag(null), checked: current === "auto", onSelect: () => choose("auto") },
      ...HomeswiftI18n.languages.map((code) => ({ label: HomeswiftI18n.names[code], icon: flag(code), checked: current === code, onSelect: () => choose(code) })),
    ]);
  }

  // The sign-in page's flags: the language before anyone signs in.
  // Automatic first: the browser's language, unless one is chosen here.
  const languageSelect = el("select", { class: "language-select", "aria-label": t("Language"),
    onchange: (event) => HomeswiftI18n.choose(event.target.value) },
    el("option", { value: "auto", text: `🌐 ${t("Automatic")}` }),
    HomeswiftI18n.languages.map((code) => el("option", { value: code, text: `${HomeswiftI18n.flags[code]} ${HomeswiftI18n.names[code]}` })));
  languageSelect.value = HomeswiftCommon.preferences().language || "auto";
  $("#auth-form").append(el("div", { class: "auth-languages" }, languageSelect));

  /// What a save did: applied at once, homeswift restarting by itself (the bridge block), or, when it
  /// cannot, what still waits for a restart (which also shows the banner).
  function savedText(result) {
    if (result.restarting) { waitForRestart(); return t("Saved. Homeswift restarts by itself to apply the bridge settings…"); }
    const pending = result.restartNeeded || [];
    $("#banner").classList.toggle("hidden", pending.length === 0);
    return pending.length ? t("Saved. Restart homeswift to apply the rest: {pending}.", { pending: pending.map((item) => HomeswiftI18n.message(item)).join("; ") }) : t("Saved and applied.");
  }

  // ---- Restart -------------------------------------------------------------

  function confirmRestart({ title = t("Restart Homeswift?"), text = t("Your accessories will disconnect briefly. This page will reconnect automatically when Homeswift is ready."), confirm = t("Restart"), icon = "power" } = {}) {
    return new Promise((resolve) => {
      const dialog = el("dialog", { class: "restart-overlay restart-confirm", "aria-labelledby": "restart-confirm-title", "aria-describedby": "restart-confirm-description" });
      const finish = (accepted) => { dialog.close(); dialog.remove(); resolve(accepted); };
      const cancel = el("button", { actionIcon: "close", text: t("Cancel"), onclick: () => finish(false) });
      dialog.append(
        el("div", { class: "restart-confirm-icon", "aria-hidden": "true" }, HomeswiftCommon.icon(icon)),
        el("h2", { id: "restart-confirm-title", text: title }),
        el("p", { id: "restart-confirm-description", text }),
        el("div", { class: "restart-confirm-actions" }, cancel,
          el("button", { actionIcon: icon, class: "primary", text: confirm, onclick: () => finish(true) })));
      dialog.addEventListener("cancel", (event) => { event.preventDefault(); finish(false); });
      document.body.append(dialog); dialog.showModal(); cancel.focus();
    });
  }

  /// From a button (disabled while it asks the bridge) or a menu item, which passes no event.
  async function restartBridge(event) {
    const button = event?.currentTarget instanceof HTMLButtonElement ? event.currentTarget : null;
    if (!await confirmRestart()) return;
    if (button) button.disabled = true;
    showRestartOverlay();
    const started = Date.now();
    try {
      const response = await fetch("/api/restart", { method: "POST", credentials: "same-origin", signal: AbortSignal.timeout(4000) });
      if (!response.ok) throw new ApiError(response.status, `HTTP ${response.status}`);
      // The process may exit before completing the response body. Headers are enough.
    } catch (e) {
      if (e instanceof ApiError) {
        closeRestartOverlay();
        HomeswiftCommon.showAlert(e.message); if (button) button.disabled = false; return;
      }
      // A disconnected or aborted request can mean the restart already began.
    }
    waitForRestart(started);
  }

  let restartOverlay = null;
  let restartPolling = false;
  function showRestartOverlay() {
    if (restartOverlay?.isConnected) return restartOverlay;
    restartOverlay = el("dialog", { class: "restart-overlay", "aria-labelledby": "restart-heading", "aria-describedby": "restart-message" },
      el("span", { class: "spinner", "aria-hidden": "true" }),
      el("h2", { id: "restart-heading", text: t("Restarting homeswift…") }),
      el("p", { id: "restart-message", role: "status", "aria-live": "polite", text: t("Please wait. This page will reconnect automatically.") }));
    restartOverlay.addEventListener("cancel", (event) => event.preventDefault());
    document.body.append(restartOverlay); restartOverlay.showModal();
    return restartOverlay;
  }

  function closeRestartOverlay() {
    restartOverlay?.close();
    restartOverlay?.remove();
    restartOverlay = null;
  }

  async function finishRestart() {
    if (restartOverlay?.isConnected && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
      restartOverlay.classList.add("restart-leaving");
      await new Promise((resolve) => setTimeout(resolve, 220));
    }
    closeRestartOverlay();
    restartPolling = false;
    const restartButton = $("#restart");
    if (restartButton) restartButton.disabled = false;
    // Keep the current DOM, scroll position, filters and unsaved edits intact.
    try {
      auth = await api("/api/auth/state");
      if (!auth.authenticated) { showAuth(); return; }
      showSections();
      openEvents();
      $("#banner").classList.add("hidden");
      document.querySelectorAll(".dashboard-quick-actions button").forEach((button) => { button.disabled = false; });
    } catch (error) { console.error("Could not reconnect after restart", error); }
  }

  /// A modal blocks controls until a younger process answers, with recovery if the restart times out.
  function waitForRestart(started = Date.now()) {
    if (restartPolling) return;
    restartPolling = true;
    closeEvents();
    const deadline = Date.now() + 90000;
    const overlay = showRestartOverlay();
    let wasOffline = false;
    let healthyReplies = 0;
    const poll = async () => {
      try {
        const response = await fetch("/api/status", { credentials: "same-origin", cache: "no-store", signal: AbortSignal.timeout(5000) });
        if (response.ok) {
          const status = await response.json();
          healthyReplies++;
          const younger = Number.isFinite(status.uptimeSeconds) && status.uptimeSeconds < (Date.now() - started) / 1000 + 5;
          if (younger || (wasOffline && healthyReplies >= 2)) {
            if (reloadIfUpdated(status)) return;
            await finishRestart();
            return;
          }
        } else if (response.status === 401) { await finishRestart(); return; }
      } catch { wasOffline = true; healthyReplies = 0; }
      if (Date.now() < deadline) setTimeout(poll, 1000);
      else {
        restartPolling = false;
        overlay.querySelector(".spinner")?.remove();
        overlay.querySelector("#restart-heading").textContent = t("homeswift did not come back; check its log.");
        overlay.querySelector("#restart-message").textContent = "";
        overlay.append(el("button", { actionIcon: "restore", class: "primary", text: t("Try again"), onclick: () => {
          closeRestartOverlay();
          waitForRestart(started);
        } }));
      }
    };
    setTimeout(poll, 1500);
  }
  $("#restart").addEventListener("click", restartBridge);

  function showApp() {
    $("#auth").classList.add("hidden");
    $("#app").classList.remove("hidden");
    drawUser();
    // The side menu's Homeswift line, on every page (the Status page draws it again with what it loads).
    api("/api/status").then(drawSideAbout).catch(() => {});
    HomeswiftCommon.tabBar({ parent: $("#app") });
    // The header's sections take their icons, shown beside their names when a wide window makes the header a side menu.
    for (const link of document.querySelectorAll("header nav a")) {
      const glyph = HomeswiftCommon.sections.find(([path]) => path === link.getAttribute("href"))?.[2]
        ?? { "/account": "user", "/appearance": "sun" }[link.getAttribute("href")];
      if (glyph && !link.querySelector("svg")) link.prepend(HomeswiftCommon.icon(glyph));
    }
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

  const adminSections = new Set(["plugins", "logs", "settings", "users", "import", "welcome"]);
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
  /// The place a #hash names on the view drawn (/status#matter-<device>): opened when it unfolds, and brought into view.
  const reveal = (hash) => {
    let id = "";
    try { id = decodeURIComponent(hash.slice(1)); } catch { return null; }
    const target = id && document.getElementById(id);
    if (!target) return null;
    if (target instanceof HTMLDetailsElement) target.open = true;
    target.scrollIntoView({ block: "center" });
    // The sections above it may still be loading (Status's quick controls, its charts): on a phone they push it out of
    // sight, so it is brought back as the view grows, until the reader scrolls or a few seconds have passed.
    const view = target.closest("main");
    if (view) {
      const follow = new ResizeObserver(() => { if (target.isConnected) target.scrollIntoView({ block: "center" }); });
      const inputs = ["wheel", "touchstart", "keydown"];
      const stop = () => { follow.disconnect(); for (const type of inputs) removeEventListener(type, stop); };
      follow.observe(view);
      for (const type of inputs) addEventListener(type, stop, { passive: true });
      setTimeout(stop, 4000);
    }
    return target;
  };
  let shownPath = null;
  function route() {
    // A dialog belongs to the view it opened on (an accessory's sheet, whose menu links to its log): a new view closes
    // it, or it would stay over the next one. The restart overlay outlives views.
    for (const dialog of document.querySelectorAll("dialog[open]")) if (dialog !== restartOverlay) dialog.close();
    // The Accessories wall's full screen belongs to it: the view draws it again when its address asks (?full=1).
    document.documentElement.classList.remove("wall-full", "wall-paged", "wall-awake");
    const decode = (part) => { try { return decodeURIComponent(part); } catch { return part; } };
    let [name = "status", ...args] = location.pathname.split("/").filter(Boolean).map(decode);
    // config.json's editor moved into Settings: an old link or bookmark lands there.
    if (name === "config") {
      history.replaceState(null, "", `/settings/config${location.search}${location.hash}`);
      [name, args] = ["settings", ["config"]];
    }
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
    return view(main, args).catch((e) => { if (e.status !== 401) main.replaceChildren(el("p", { class: "error", text: e.message })); });
  }
  /// Something loading: a turning ring, read as "Loading"; it shows after a moment, so a quick load does not flash it.
  function spinner() {
    return el("span", { class: "spinner", role: "status", "aria-label": t("Loading") });
  }
  /// Shows the view at `path` without loading the page again; `replace` keeps it out of the history.
  async function navigate(path, { replace = false } = {}) {
    if (leaveGuard && !(await leaveGuard())) return;
    history[replace ? "replaceState" : "pushState"](null, "", path);
    route();
  }
  window.addEventListener("popstate", async () => {
    if (!(auth && auth.authenticated)) return;
    if (leaveGuard && !(await leaveGuard())) { history.pushState(null, "", shownPath); return; }
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
    // Another view, with the place in it to show (/status#matter-<device>); on this view, that place opened and in sight.
    if (url.pathname + url.search !== location.pathname + location.search) return navigate(url.pathname + url.search + url.hash);
    if (url.hash && reveal(url.hash)) history.replaceState(null, "", url.pathname + url.search + url.hash);
  });
  // Closing the tab or reloading: the browser asks, when the page has unsaved changes.
  window.addEventListener("beforeunload", (event) => { if (leaveGuard?.quiet && !leaveGuard.quiet()) event.preventDefault(); });

  // ---- Live events ---------------------------------------------------------

  let events = null;
  // The build of the files this page runs (UIServer.build, in its <meta>); /api/status says the bridge's.
  const pageBuild = document.querySelector('meta[name="homeswift-build"]')?.content || null;
  /// After an update the bridge serves other files: a page still running the old ones loads again, unless it holds
  /// unsaved changes (it does on the next check after they are saved or left). True when it reloads.
  function reloadIfUpdated(status) {
    if (!pageBuild || !status?.build || status.build === pageBuild) return false;
    if (leaveGuard && !leaveGuard.quiet?.()) return false;
    location.reload();
    return true;
  }

  function openEvents() {
    if (events) return;
    const stream = events = new EventSource("/api/events");
    let pending = null;
    let generation = 0;
    stream.addEventListener("accessory", (message) => {
      const event = JSON.parse(message.data);
      if (pending) pending.push(event);
      else applyAccessoryEvent(event);
    });
    // Subscribe first, then read a snapshot: replay anything received during the read last.
    // This also reconciles an automatic SSE reconnect without replacing forms or the wall.
    stream.addEventListener("hello", async (event) => {
      const current = ++generation;
      // The bridge's build: it may have restarted into an update while this page was away or disconnected.
      try { if (reloadIfUpdated(JSON.parse(event.data))) return; } catch {}
      pending = [];
      try {
        const accessories = await api("/api/accessories");
        if (events !== stream || generation !== current) return;
        HomeswiftWidgets.snapshot(accessories);
        // Camera indicators use a separate view. Never replay a cached doorbell press.
        for (const accessory of accessories) for (const service of accessory.services) {
          for (const characteristic of service.characteristics) {
            if (characteristic.type === "Motion Detected" ||
                (service.type === "CameraRecordingManagement" && characteristic.type === "Active")) {
              window.HomeswiftCamera?.event({ id: accessory.id, service: service.type,
                characteristic: characteristic.type, value: characteristic.value });
            }
          }
        }
        if (location.pathname === "/accessories") window.homeswiftGroupSnapshot?.(accessories);
      } catch (error) {
        console.error("Could not refresh accessories after reconnect", error);
      } finally {
        if (events === stream && generation === current) {
          const buffered = pending;
          pending = null;
          buffered.forEach(applyAccessoryEvent);
        }
      }
    });
    stream.addEventListener("log", (event) => appendLogLine(JSON.parse(event.data)));
    // A Matter node added to an ecosystem, removed from one, or opened for one: the Status page draws its Matter
    // bridge and devices again, once the burst of changes a pairing makes (the new fabric, the window closing) has settled.
    let matterTimer = null;
    stream.addEventListener("matter", () => {
      clearTimeout(matterTimer);
      matterTimer = setTimeout(() => { if (location.pathname === "/status") redrawMatter?.(); }, 500);
    });
    // The rooms or the wall changed elsewhere (the chat, an MCP client, another page): the Accessories page draws them
    // again, once for a burst, unless the change is the page's own. While it is being edited or a dialog is open over
    // it, the redraw waits for them to end, so a save from Edit does not put back what changed meanwhile.
    let layoutTimer = null;
    const redrawLayout = () => {
      if (location.pathname !== "/accessories") return;
      if (document.querySelector(".wall.editing, dialog[open]")) { layoutTimer = setTimeout(redrawLayout, 1000); return; }
      route();
    };
    stream.addEventListener("layout", () => {
      clearTimeout(layoutTimer);
      if (Date.now() - HomeswiftCommon.lastChange() < 2000) return;
      layoutTimer = setTimeout(redrawLayout, 300);
    });
    stream.addEventListener("asset", (event) => applyAsset(JSON.parse(event.data)));
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

  /// A search, an optional filter and an order over a list of cards, on one row; while the search or the filter narrows
  /// the list, how many it keeps and the way back under it. `entries` are { card, name, text } and more; `orders` are
  /// [value, label, compare], the first the default, ties by name; `filters` are [value, label, keep], the first keeping
  /// all. The order and the filter chosen stay in the address under `param` and `filterParam`.
  const naturalOrder = new Intl.Collator(undefined, { numeric: true });
  // The Status page's Matter section drawn again (set while it shows).
  let redrawMatter = null;
  const finder = ({ grid, entries, orders, filters = [], param, filterParam, placeholder, sortLabel, filterLabel, empty, counted,
    emptyClass = "card empty" }) => {
    const params = new URLSearchParams(location.search);
    const search = el("input", { type: "search", class: "search", placeholder, "aria-label": placeholder });
    const choose = (options, label, saved) => {
      const select = el("select", { class: "popup", "aria-label": label }, options.map(([value, text]) => el("option", { value, text })));
      select.value = options.some(([value]) => value === saved) ? saved : options[0][0];
      return select;
    };
    const sort = choose(orders, sortLabel, params.get(param));
    const filter = filters.length ? choose(filters, filterLabel, params.get(filterParam)) : null;
    const status = el("div", { class: "finder-status", "aria-live": "polite" });
    const clear = HomeswiftCommon.clearFilters([[search, ""], ...(filter ? [[filter, filters[0][0]]] : [])]);
    const none = el("p", { class: emptyClass, hidden: true, text: empty });
    const remember = (name, value) => {
      const url = new URL(location.href); url.searchParams.set(name, value);
      history.replaceState(null, "", url.pathname + url.search);
    };
    const arrange = () => {
      const compare = orders.find(([value]) => value === sort.value)[2];
      grid.append(...[...entries].sort((a, b) => compare(a, b) || naturalOrder.compare(a.name, b.name) || naturalOrder.compare(a.text, b.text)).map(({ card }) => card));
    };
    const narrow = () => {
      const query = HomeswiftCommon.fold(search.value.trim());
      const keep = filter ? filters.find(([value]) => value === filter.value)[2] : () => true;
      let visible = 0;
      for (const entry of entries) {
        entry.card.hidden = !(keep(entry) && HomeswiftCommon.fold(entry.text).includes(query));
        if (!entry.card.hidden) visible++;
      }
      const narrowed = query || (filter && filter.value !== filters[0][0]);
      status.replaceChildren(...(narrowed ? [el("span", { text: counted(visible, entries.length) }), clear] : []));
      none.hidden = visible > 0;
    };
    sort.addEventListener("change", () => { arrange(); remember(param, sort.value); });
    filter?.addEventListener("change", () => { narrow(); remember(filterParam, filter.value); });
    search.addEventListener("input", narrow);
    arrange();
    if (filter && filter.value !== filters[0][0]) narrow();
    return [el("div", { class: `catalog-toolbar${filter ? " with-filter" : ""}` }, search, filter, sort), status, grid, none];
  };

  // /status?since=24h&bridge=<bridge>&accessory=<accessory>: the activity charts' range and whose durations they show,
  // as on the Logs page.
  views.status = async (main) => {
    const [status, accessories, firstMatter] = await Promise.all([
      api("/api/status"),
      api("/api/accessories").then((list) => withSlugs(list, "accessory")).catch(() => []),
      api("/api/matter").catch(() => null),
    ]);
    let matter = firstMatter;
    rememberMatterOwn(matter);
    $("#banner").classList.toggle("hidden", !status.restartNeeded || !isAdmin());
    const plugins = new Set(status.bridges.filter((bridge) => !bridge.external).flatMap((bridge) => bridge.platforms));
    const main0 = status.bridges.find((bridge) => !bridge.childBridge && !bridge.external);

    // A server's heading (icon, name, role, state) and the rest of its card: a bridge's card shows both; an accessory of
    // its own is a row of the devices list, its heading the row and the rest unfolded.
    const bridgeParts = (bridge, index) => {
      const kind = bridge.external ? "accessory" : bridge.childBridge ? "child" : "bridge";
      const tone = { accessory: "blue", child: "violet", bridge: "orange" }[kind];
      const role = bridge.external ? (bridge.platforms.length ? t("Accessory of its own, from {plugins}", { plugins: bridge.platforms.join(", ") }) : t("Accessory of its own, from a plugin")) : bridge.childBridge ? t("Child bridge") : t("Main bridge");
      return {
        head: [tile(kind, tone),
          el("div", { class: "who" }, el("strong", { text: bridge.name }), el("div", { class: "muted", text: role })),
          el("span", { class: `pill status ${bridge.paired ? "on" : "away"}`, text: bridge.paired ? t("Paired · {count}", { count: bridge.controllers }) : t("Not paired"), title: bridge.paired ? tn("{n} Home app controller", "{n} Home app controllers", bridge.controllers) : "" })],
        body: () => [el("div", { class: "facts lead" },
          fact(t("Device ID"), bridge.deviceId, { class: "mono" }), fact(t("Port"), bridge.port ?? "?"), fact(t("Accessories"), bridge.accessories)),
        !bridge.external && bridge.platforms.length ? el("div", { class: "chips" }, bridge.platforms.map((name) => el("span", { class: "chip", text: name }))) : null,
        bridge.setupCode ? el("div", { class: "setup" },
          el("img", { class: "qr", src: `/api/qr/${index}.svg`, alt: t("Pairing QR code"), width: 148, height: 148, loading: "lazy" }),
          el("div", {},
            el("p", { text: t("In the Home app: Add Accessory, then scan this code, or choose More options and type it.") }),
            el("div", { class: "code", text: bridge.setupCode }))) : null],
        waiting: !bridge.paired,
        search: [bridge.name, ...bridge.platforms, bridge.deviceId].join(" "),
      };
    };
    const serverCard = ({ head, body }, id) => el("div", { class: "card server", id }, el("div", { class: "server-head" }, ...head), ...body());
    // A device of its own as one line that unfolds; its details are built the first time it opens, so a hundred folded
    // rows stay a hundred lines.
    const deviceRow = ({ head, body, search }, id, open) => {
      const row = el("details", { class: "device-row", id, "data-search": search.toLowerCase() }, el("summary", {}, ...head, HomeswiftCommon.icon("forward")));
      const unfold = () => { if (row.open && row.childElementCount === 1) row.append(el("div", { class: "device-row-body" }, ...body())); };
      row.addEventListener("toggle", unfold);
      row.open = open;
      unfold();
      return row;
    };
    const bridges = status.bridges.map((bridge, index) => bridge.external ? null : serverCard(bridgeParts(bridge, index)));

    // The Matter bridge, when the HomeswiftMatter block runs one, and each accessory that is a Matter device of its
    // own: drawn again after an administrator's change.
    // A device's icon from the role Matter has it in (its first part's): a robot vacuum, a light, a plug...
    const matterIcons = { cleaningRobot: "vacuum", light: "bulb", plug: "outlet", contact: "door", occupancy: "sensor", temperature: "sensor",
      humidity: "sensor", illuminance: "sensor", leak: "drop", covering: "blind", fan: "fan", thermostat: "thermo", lock: "lock",
      button: "switch", airQuality: "wind", alarm: "bell", valve: "drop", heaterCooler: "thermo", garageDoor: "gate", airPurifier: "wind" };
    // The ecosystems a fabric's vendor id says it is (Connectivity Standards Alliance vendor ids).
    const matterVendors = { "0x1349": "Apple Home", "0x1384": "Apple Home", "0x6006": "Google Home", "0x1217": "Alexa" };
    // A Dolphin is a pool robot, as on its plugin's page and its widget.
    const matterIcon = (node) => node.id?.startsWith("DolphinPoolCleaner:") ? "poolRobot" : matterIcons[node.types?.[0]] ?? "accessory";
    // What Matter needs of the network, folded: under a code waiting to be scanned, and under a device that did not
    // start. The ports are the bridge's and the next ones, which devices of their own take.
    const matterNetworkHelp = () => {
      const port = matter?.port ?? 5540;
      return el("details", { class: "matter-help" }, el("summary", { text: t("Stuck on Setting Up?") }),
        el("p", { class: "muted", text: t("Matter controllers reach devices over IPv6: this machine needs IPv6 on (on a Synology: Control Panel, Network, Network Interface), and host networking in Docker.") }),
        el("p", { class: "muted", text: t("A firewall on this machine must let UDP in from IPv6 addresses too: ports {ports} and 5353 (mDNS), from All. A rule for the IPv4 subnet alone leaves the Home app on Setting Up…", { ports: `${port}–${port + 10}` }) }),
        el("p", { class: "muted", text: t("Apple Home also needs a home hub (an Apple TV or a HomePod) on the same network.") }));
    };
    const matterParts = (node, own, refresh) => {
      const base = own ? `/api/matter/devices/${encodeURIComponent(node.id)}` : "/api/matter";
      const fabrics = node.fabrics || [];
      const admin = isAdmin();
      // Whose fabric it is, by its vendor id: an unnamed one of Apple Home's is its own system fabric (it reaches the
      // device from the other Apple devices and hubs), shown muted with a house.
      const named = fabrics.map((fabric) => {
        const vendor = matterVendors[fabric.vendorId];
        const system = Boolean(!fabric.label && vendor);
        return { fabric, vendor, system, name: fabric.label || (vendor ? t("{vendor} system", { vendor }) : t("Ecosystem {index}", { index: fabric.index })) };
      });
      // A device's row says where it was added (the homes people named, not the system links); the bridge's card, what
      // it is for.
      const where = named.filter((one) => !one.system).map((one) => one.name).join(" · ") || named.map((one) => one.name).join(" · ");
      // A device of its own goes back to being only on the bridge, as its accessory's menu does it.
      const takeOff = own && admin ? el("div", { class: "actions" },
        el("button", { type: "button", class: "link danger", actionIcon: "close", text: t("Take off Matter"), onclick: async (event) => {
          if (!await HomeswiftCommon.confirmDialog(t("{name} leaves Matter: the ecosystems that added it lose it.", { name: node.name }))) return;
          await HomeswiftCommon.busyButton(event.currentTarget, async () => {
            await api(base, { method: "PUT", body: { own: false } });
            matterOwn.delete(node.id);
            await refresh();
          });
        } })) : null;
      return {
        // A device's own icon, tagged with Matter's glyph: the list mixes Matter devices with HomeKit accessories.
        head: [own ? el("span", { class: "tile-tagged", title: t("Matter") }, tile(matterIcon(node), "green"), el("span", { class: "tile-tag", "aria-hidden": "true" }, HomeswiftCommon.icon("matter")))
          : tile("matter", "green"),
          el("div", { class: "who" }, el("strong", { text: own ? node.name : t("Matter bridge") }),
            el("div", { class: "muted", text: !own ? t("For Google Home, Alexa, SmartThings and Home Assistant") : where ? t("Matter · {ecosystems}", { ecosystems: where }) : t("Matter device of its own") })),
          el("span", { class: `pill status ${fabrics.length ? "on" : "away"}`, text: fabrics.length ? tn("In one ecosystem", "In {n} ecosystems", fabrics.length) : t("Not added yet") })],
        body: () => [el("div", { class: "facts lead" }, fact(t("Port"), node.port), own ? null : fact(t("Accessories"), (node.devices || []).length)),
        fabrics.length ? el("div", { class: "chips" }, named.map(({ fabric, vendor, system, name }) => {
          const hint = system ? t("{vendor}'s own link to the device, from your other devices and hubs: keep it.", { vendor }) : vendor ?? "";
          return el("span", { class: `chip${admin ? " removable" : ""}${system ? " system" : ""}`, title: hint },
            system ? HomeswiftCommon.icon("house") : null, el("span", { text: name }),
            admin ? el("button", { type: "button", class: "icon-button", "aria-label": t("Remove {name}", { name }), title: t("Remove {name}", { name }), onclick: async (event) => {
              const message = system ? t("{vendor}'s hubs and other devices lose their link to this device: it stops responding there until it is added again.", { vendor })
                : own ? t("{name} loses this device, with its room and automations.", { name })
                : t("{name} loses the bridge and every device on it, with their rooms and automations.", { name });
              if (!await HomeswiftCommon.confirmDialog(message)) return;
              await HomeswiftCommon.busyButton(event.currentTarget, async () => {
                await api(`${base}/fabrics/${fabric.index}/remove`, { method: "POST", body: {} });
                await refresh();
              });
            } }, HomeswiftCommon.icon("close")) : null);
        })) : null,
        node.pairing ? el("div", { class: "setup" },
          el("img", { class: "qr", src: `${base}/qr.svg`, alt: t("Pairing QR code"), width: 148, height: 148, loading: "lazy" }),
          el("div", {},
            el("p", { text: own ? t("In the Home app (or another ecosystem's): add an accessory, then scan this code or type it.")
              : t("In the ecosystem's app: add a Matter device, then scan this code or type it.") }),
            el("div", { class: "code", text: node.pairing.manualCode.replace(/^(\d{4})(\d{3})(\d{4})$/, "$1-$2-$3") })))
          : null,
        node.pairing ? matterNetworkHelp()
          : admin ? (() => {
            // What it does, under it (a phone shows no hover text): Matter lets several apps share a device, each
            // adding it with its own code.
            const what = own ? t("Shows a new pairing code for 15 minutes, so another app (Google Home, Alexa, Home Assistant or another home in Apple Home) can add this device too. The ecosystems it is in keep it.")
              : t("Shows a new pairing code for 15 minutes, so another app (Google Home, Alexa, Home Assistant or another home in Apple Home) can add the bridge and its devices too. The ecosystems it is in keep them.");
            return el("div", { class: "actions add-ecosystem" },
              el("button", { class: "link", actionIcon: "plus", text: t("Add to another ecosystem"), title: what,
                onclick: (event) => HomeswiftCommon.busyButton(event.currentTarget, async () => {
                  await api(`${base}/window`, { method: "POST", body: { minutes: 15 } });
                  await refresh();
                }) }),
              el("p", { class: "muted", text: what }));
          })() : null,
        takeOff],
        search: [node.name ?? "", ...named.map((one) => one.name)].join(" "),
      };
    };
    // The Matter bridge's card, or a device's row; an administrator's change draws the section again.
    const matterNode = (node, own, open = false) => {
      const parts = matterParts(node, own, () => redrawMatter?.());
      return own ? deviceRow(parts, `matter-${slug(node.id)}`, open) : serverCard(parts, "matter");
    };
    // A device of its own whose node did not start (no IPv6, most often): its row says why, and offers to take it off.
    const failedMatterRow = (device, open) => deviceRow({
      head: [tile("warning", "heat"),
        el("div", { class: "who" }, el("strong", { text: device.name }), el("div", { class: "muted", text: t("Matter device of its own") })),
        el("span", { class: "pill status bad", text: t("Not started") })],
      body: () => [
        el("p", { class: "error", text: device.noIPv6
          ? t("Matter needs IPv6, and this machine has none. Turn IPv6 on (on a Synology: Control Panel, Network, Network Interface), then restart homeswift.")
          : t("Matter could not start this device: {error}", { error: device.error }) }),
        matterNetworkHelp(),
        isAdmin() ? el("div", { class: "actions" },
          el("button", { type: "button", class: "link danger", actionIcon: "close", text: t("Take off Matter"), onclick: (event) => HomeswiftCommon.busyButton(event.currentTarget, async () => {
            await api(`/api/matter/devices/${encodeURIComponent(device.id)}`, { method: "PUT", body: { own: false } });
            matterOwn.delete(device.id);
            await redrawMatter?.();
          }) })) : null],
      search: device.name,
    }, `matter-${slug(device.id)}`, open);

    // Accessories and Matter devices of their own, one line each, those waiting to be added first: a home may have a
    // hundred, which cards would bury the bridges under. Built on each draw (Customise draws the section again, and a
    // Matter change, with the rows that were open), with a search once the list is long.
    const waitingFirst = (a, b) => Number(b.waiting) - Number(a.waiting);
    const devicesCard = (opened) => {
      const external = status.bridges.flatMap((bridge, index) => {
        if (!bridge.external) return [];
        const parts = bridgeParts(bridge, index);
        const id = `accessory-${slug(bridge.deviceId)}`;
        return [{ name: bridge.name, id, kind: "homekit", ecosystems: bridge.paired ? 1 : 0, waiting: parts.waiting, make: (open) => deviceRow(parts, id, open) }];
      });
      const own = !matter?.enabled ? [] : (matter.ownDevices || []).map((device) => {
        const ecosystems = (device.fabrics || []).length;
        return { name: device.name, id: `matter-${slug(device.id)}`, kind: "matter", ecosystems, waiting: !ecosystems, make: (open) => matterNode(device, true, open) };
      });
      // Not started: first, so the reason is in view.
      const failed = !matter?.enabled ? [] : (matter.failedDevices || []).map((device) =>
        ({ name: device.name, id: `matter-${slug(device.id)}`, kind: "matter", ecosystems: 0, waiting: true, make: (open) => failedMatterRow(device, open) }));
      const entries = [...failed, ...external, ...own];
      if (!entries.length) return null;
      const waiting = entries.filter((entry) => entry.waiting).length;
      const list = el("div", { class: "device-rows" });
      // One or two to add come open, their codes in view; more stay folded, their pills saying so. Drawn again, the
      // rows open that were.
      for (const entry of entries) {
        entry.card = entry.make(opened ? opened.has(entry.id) : entry.waiting && waiting <= 2);
        entry.text = entry.card.dataset.search;
        list.append(entry.card);
      }
      const head = el("div", { class: "devices-head" },
        el("div", { class: "who" }, el("strong", { text: t("Devices of their own") }),
          el("div", { class: "muted", text: waiting ? tn("{count} devices · one waits to be added", "{count} devices · {n} wait to be added", waiting, { count: entries.length })
            : tn("One device, with its own pairing", "{n} devices, each with its own pairing", entries.length) })));
      // A short list is read at a glance; a long one is searched, filtered by kind and sorted.
      if (entries.length <= 8) {
        list.append(...entries.sort((a, b) => waitingFirst(a, b) || naturalOrder.compare(a.name, b.name)).map((entry) => entry.card));
        return el("div", { class: "card devices" }, head, list);
      }
      return el("div", { class: "card devices" }, head, ...finder({ grid: list, entries, param: "devices", filterParam: "show",
        orders: [["waiting", t("Waiting to be added first"), waitingFirst], ["name", t("Name A–Z"), () => 0],
          ["ecosystems", t("Most ecosystems"), (a, b) => b.ecosystems - a.ecosystems]],
        filters: [["all", t("All devices"), () => true], ["matter", t("Matter"), (entry) => entry.kind === "matter"],
          ["homekit", t("HomeKit"), (entry) => entry.kind === "homekit"], ["waiting", t("Waiting to be added"), (entry) => entry.waiting]],
        placeholder: t("Search devices"), sortLabel: t("Sort devices"), filterLabel: t("Show devices"), empty: t("No device matches."),
        emptyClass: "muted", counted: (shown, total) => t("{shown} of {total} devices", { shown, total }) }));
    };

    // The page is widgets the user can hide and order (Customise, at the bottom; Glass UI's dashboard layout),
    // drawn only when shown: the activity charts load nothing while hidden.
    const widgets = {
      overview: () => [overviewUpdate = updateCard(status.update, { changed: (next) => updateChanged(next) }),
      // Each figure with its glyph; on a phone the four share one row, "Home app controllers" shortened.
      el("div", { class: "stats" },
        el("a", { class: "stat", href: "/accessories" }, tile("bulb", "yellow"), el("b", { text: status.bridges.reduce((sum, bridge) => sum + bridge.accessories, 0) }), el("span", { text: t("Accessories") })),
        el(isAdmin() ? "a" : "div", { class: "stat", href: isAdmin() ? "/plugins" : null }, tile("plugin", "blue"), el("b", { text: plugins.size }), el("span", { text: plugins.size === 1 ? t("Plugin") : t("Plugins") })),
        el("div", { class: "stat", title: t("Home app controllers") }, tile("users", "teal"), el("b", { text: main0 ? main0.controllers : 0 }),
          el("span", { class: "long", text: t("Home app controllers") }), el("span", { class: "short", "aria-hidden": "true", text: t("Controllers") })),
        el("div", { class: "stat" }, tile("history", "violet"), el("b", { text: formatDuration(status.uptimeSeconds) }), el("span", { text: t("Up [uptime]") })))],
      quick: () => window.HomeswiftHome?.quickSection(accessories),
      digest: () => status.assistant ? digestWidget() : null,
      // Nothing in the vault and nothing to move into it: no section until there is.
      vault: () => isAdmin() && status.vault && (status.vault.entries || status.vault.inConfig || status.vault.problems?.length) ? vaultCard(status.vault) : null,
      activity: () => activity(accessories, withSlugs(status.bridges, "bridge")),
      energy: () => energy(),
      bridges: (opened) => [el("h2", { text: status.bridges.length === 1 ? t("Bridge") : t("Bridges and accessories") }),
      el("div", { class: "servers" }, ...bridges, matter?.enabled && matter.bridge !== false ? matterNode(matter, false) : null, devicesCard(opened))],
      system: () => [el("h2", { text: t("System") }),
      el("div", { class: "card server" },
        el("div", { class: "server-head" }, tile("system", "grey"),
          el("div", { class: "who" }, el("strong", { text: status.system.hostname }), el("div", { class: "muted", text: `${status.system.platform} ${status.system.os}` }))),
        el("div", { class: "facts" },
          fact(t("CPUs"), status.system.cpus),
          fact(t("Assistant"), status.assistant ? `${status.assistant.provider} · ${status.assistant.model}` : t("Off [setting]")),
          fact(t("Machine up"), formatDuration(status.system.systemUptimeSeconds ?? 0))),
        el("div", { class: "fact wide" }, el("span", { text: t("Configuration") }), el("b", { class: "mono", text: status.configPath, title: status.configPath })),
        // Changes apply without one; this is for a plugin that misbehaves.
        isAdmin() ? el("div", { class: "actions dashboard-quick-actions" },
          el("button", { class: "link", onclick: restartBridge }, HomeswiftCommon.icon("power"), el("span", { text: t("Restart homeswift…") })),
          el("a", { class: "link", href: "/settings" }, HomeswiftCommon.icon("sliders"), el("span", { text: t("Settings, pairings and backups") })),
          el("a", { class: "link", href: "/notifications" }, HomeswiftCommon.icon("bell"), el("span", { text: t("Notifications") }))) : null)],
    };
    const sections = new Map();
    // Homeswift's health, version, update and feedback: in the side menu on a wide window, here on a narrower one
    // (style.css hides one or the other); Customise stays with the page.
    drawSideAbout(status);
    const about = aboutParts(status);
    const footer = el("footer", { class: "actions page-foot status-footer" },
      el("div", { class: "status-footer-summary" }, about.health, about.meta), about.feedback,
      el("button", { type: "button", class: "link", "aria-label": t("Customise the Status page"), "aria-haspopup": "menu", "aria-expanded": "false",
        onclick: (event) => customiseDashboard(event.currentTarget, renderDashboard, event.detail === 0) }, HomeswiftCommon.icon("sliders"), el("span", { class: "status-footer-action-label", text: t("Customise this page…") })));
    function renderDashboard(layout) {
      const position = { left: scrollX, top: scrollY };
      for (const id of layout.order) {
        let section = sections.get(id);
        if (!section && !layout.hidden.includes(id)) {
          const nodes = [widgets[id]?.()].flat().filter(Boolean);
          if (nodes.length) {
            section = el("section", { class: "dash-widget", "data-widget": id }, nodes);
            sections.set(id, section);
          }
        }
        if (section) {
          section.hidden = layout.hidden.includes(id);
          main.insertBefore(section, footer);
        }
      }
      scrollTo({ ...position, behavior: "instant" });
    }
    // The bridge said a Matter node changed, or an administrator changed one: the Bridges section is drawn again, its
    // rows as open as they were, its search as typed and the page where it was.
    redrawMatter = async () => {
      matter = await api("/api/matter").catch(() => matter);
      rememberMatterOwn(matter);
      const section = sections.get("bridges");
      if (!section?.isConnected) return;
      const opened = new Set([...section.querySelectorAll("details[open]")].map((row) => row.id));
      const query = section.querySelector(".devices .search")?.value ?? "";
      const position = { left: scrollX, top: scrollY };
      section.replaceChildren(...[widgets.bridges(opened)].flat().filter(Boolean));
      const search = section.querySelector(".devices .search");
      if (search && query) { search.value = query; search.dispatchEvent(new Event("input")); }
      scrollTo({ ...position, behavior: "instant" });
    };
    show(main, footer);
    renderDashboard(dashboardLayout());
    // Reached from an accessory's menu (/status#matter-<device>): that row, opened and in view.
    if (location.hash) requestAnimationFrame(() => reveal(location.hash));
  };

  // ---- The Status page's widgets: which show, in which order ----------------------------------------------
  // Each user's own, kept on the server with their other preferences (/api/preferences, `dashboard`).

  const dashboardWidgets = [["overview", t("Overview"), t("Health, accessories, plugins, uptime")], ["quick", t("Quick controls"), t("Favourite accessories and scenes")], ["digest", t("Daily digest"), t("The Assistant's summary of the day")],
    ["vault", t("Vault"), t("Passwords, keys and tokens, and what needs attention")],
    ["activity", t("Activity"), t("Memory, CPU and response times")], ["energy", t("Energy"), t("Solar, home, grid and batteries")], ["bridges", t("Bridges"), t("Pairing codes and what each bridge runs")], ["system", t("System"), t("The machine, and Restart")]];

  /// The widgets in the user's order (new ones last), and those hidden.
  function dashboardLayout() {
    const saved = HomeswiftCommon.preferences().dashboard || {};
    const known = dashboardWidgets.map(([id]) => id);
    const order = [...(saved.order || []).filter((id) => known.includes(id)), ...known.filter((id) => !(saved.order || []).includes(id))];
    return { order, hidden: (saved.hidden || []).filter((id) => known.includes(id)) };
  }

  /// The same pop-up as accessory actions: visibility choices, ordering, and reset.
  function customiseDashboard(trigger, renderDashboard, keyboard = false) {
    let layout = dashboardLayout();
    const nameOf = (id) => dashboardWidgets.find(([known]) => known === id)[1];
    const save = async (next) => {
      const before = layout;
      layout = next;
      renderDashboard(layout);
      try {
        HomeswiftCommon.applyPreferences(await api("/api/preferences", { method: "PUT", body: { dashboard: next } }));
      } catch (e) {
        layout = before;
        renderDashboard(layout);
        HomeswiftCommon.showAlert(e.message);
      }
    };
    HomeswiftCommon.menu(trigger, [
      ...layout.order.map((id) => ({ key: id, label: t("Show {name}", { name: nameOf(id) }),
        checked: !layout.hidden.includes(id), checkbox: true, toggle: true, keepOpen: true,
        onSelect: async () => {
          await save({ ...layout, hidden: layout.hidden.includes(id) ? layout.hidden.filter((one) => one !== id) : [...layout.hidden, id] });
          return !layout.hidden.includes(id);
        } })),
      { separator: true },
      { label: t("Back to the usual layout"), onSelect: () => save({ order: dashboardWidgets.map(([id]) => id), hidden: [] }) },
    ], { keyboard, onReorder: async (order) => {
      await save({ ...layout, order });
      return layout.order;
    } });
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
        el("div", { class: "who" }, el("strong", { text: t("Daily digest") }), el("div", { class: "muted", text: t("What needs attention today, from the log and the accessories") }))),
      body,
      // Writing one costs the provider's quota: an administrator's (any user reads today's).
      el("div", { class: "card-foot" }, note, isAdmin() ? menuButton(t("Digest actions"), () => [{ label: t("Write it again"), icon: sparkle(), onSelect: () => write() }]) : null));
    let controller = null;

    const shown = (digest) => {
      body.replaceChildren(HomeswiftCommon.markdown(digest.text));
      const when = new Date(digest.generatedAt).toLocaleString(HomeswiftI18n.locale, { dateStyle: "medium", timeStyle: "short" });
      note.textContent = digest.model ? t("Written {when} by {model}", { when, model: digest.model }) : t("Written {when}", { when });
    };
    const offer = () => body.replaceChildren(...[
      el("p", { class: "muted", text: isAdmin() ? t("No digest yet today. The Assistant reads the day's warnings and errors and the accessories, and says what needs attention.")
        : t("No digest yet today: an administrator has the Assistant write it.") }),
      isAdmin() ? el("button", { class: "ai-button", onclick: () => write() }, sparkle(), el("span", { text: t("Write today's digest") })) : null].filter(Boolean));

    async function write() {
      controller?.abort();
      controller = new AbortController();
      const own = controller;
      const live = el("div", {}, el("p", { class: "ai-thinking", text: t("Reading the day…") }));
      body.replaceChildren(live, el("button", { actionIcon: "pause", class: "link", text: t("Stop"), onclick: () => own.abort() }));
      card.classList.add("writing");
      note.textContent = "";
      try {
        shown(await HomeswiftCommon.assistantRequest("/api/assistant/digest", {}, { signal: own.signal, onChunk: streamInto(live) }));
      } catch (e) {
        if (own.signal.aborted) offer(); else body.replaceChildren(el("p", { class: "error", text: e.message }), el("button", { actionIcon: "restore", class: "link", text: t("Try again"), onclick: () => write() }));
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
  /// The vault at a glance (an administrator's /api/status has it). The head says whether anything needs doing; then a
  /// row per problem (up to three, most pressing first) and one for the secrets still in config.json, each a way to
  /// the Vault page, which says how to fix it.
  function vaultCard(vault) {
    const { problems } = vault;
    const count = new Set(problems.map((problem) => problem.entry)).size;
    const urgent = problems.some((problem) => problem.state !== "expiring");
    // "in 12 days", "tomorrow", "3 days ago": how soon matters more than the date, which the row's title keeps.
    const relative = new Intl.RelativeTimeFormat(HomeswiftI18n.locale, { numeric: "auto" });
    const fromNow = (iso) => {
      const days = Math.round((new Date(iso) - Date.now()) / 86_400_000);
      return Math.abs(days) < 45 ? relative.format(days, "day") : relative.format(Math.round(days / 30), "month");
    };
    const says = {
      missing: () => t("Not in the vault: the bridge does not start without it"),
      failing: () => t("A setting cannot read it"),
      expired: (problem) => t("Expired {when}", { when: fromNow(problem.expires) }),
      expiring: (problem) => t("Expires {when}", { when: fromNow(problem.expires) }),
    };
    const row = (tone, name, text, attrs = {}) => el("a", { class: "vault-status-row", href: "/settings/vault", "data-tone": tone, ...attrs },
      el("span", { class: "vault-status-dot", "aria-hidden": "true" }),
      el("span", { class: "vault-status-name", text: name }),
      el("span", { class: "vault-status-says", text }),
      HomeswiftCommon.icon("forward"));
    const rows = [
      ...problems.slice(0, 3).map((problem) => row(problem.state === "expiring" ? "warn" : "bad", problem.entry, says[problem.state]?.(problem) ?? problem.state,
        { class: "vault-status-row mono-name", title: problem.expires ? new Date(problem.expires).toLocaleString(HomeswiftI18n.locale, { dateStyle: "full", timeStyle: "short" }) : null })),
      problems.length > 3 ? el("p", { class: "muted vault-status-more", text: tn("And {n} more", "And {n} more", problems.length - 3) }) : null,
      vault.inConfig ? row("info", tn("{n} secret is still in config.json", "{n} secrets are still in config.json", vault.inConfig), t("Move [to the vault]")) : null,
    ].filter(Boolean);
    const headline = count ? tn("One entry needs attention", "{n} entries need attention", count)
      : vault.entries ? t("Nothing to do") : t("No secrets in the vault yet");
    const detail = vault.entries ? tn("{n} entry · {used} used by config.json", "{n} entries · {used} used by config.json", vault.entries, { used: vault.inUse })
      : t("Passwords, keys and tokens, sealed on disk");
    return [el("h2", { text: t("Vault") }),
      el("div", { class: `card server vault-status${count ? " attention" : ""}`, "data-state": urgent ? "bad" : count ? "warn" : "ok" },
        el("div", { class: "server-head" },
          tile(urgent ? "warning" : "vault", urgent ? "heat" : count ? "yellow" : "green"),
          el("div", { class: "who" }, el("strong", { text: headline }), el("div", { class: "muted", text: detail })),
          el("a", { class: `button${urgent ? " primary" : ""}`, href: "/settings/vault", actionIcon: "vault", text: t("Open the vault") })),
        rows.length ? el("div", { class: "vault-status-rows" }, rows) : null)];
  }

  /// `changed` hears each new state of the update (installing, installed, failed), for what shows it elsewhere (the
  /// Status page's footer). An install the bridge can do itself (Homebrew's) is a button; it then restarts into it.
  /// `embedded` leaves out the card and its heading, for a page whose own heading says it (Settings › Updates).
  function updateCard(update, { changed = () => {}, embedded = false } = {}) {
    if (!update?.available) return null;
    const card = el("div", { class: embedded ? "update-card update-details" : "card update-card update-hero-card" });
    const fill = () => card.replaceChildren(...updateCardContent(update, draw, embedded).filter(Boolean));
    const draw = (next) => {
      update = next;
      changed(update);
      fill();
    };
    fill();
    // Another control installing it (the footer's button) shows its progress here too, without calling `changed` back.
    card.show = (next) => { if (next !== update) { update = next; fill(); } };
    return card;
  }

  /// What an update is doing, one word for each page that shows it: installing, relaunching, installed (on disk, a
  /// relaunch starts it), available, error (the last check failed), current or idle (not checked yet).
  function updatePhase(update) {
    if (update?.installing) return "installing";
    if (update?.relaunching) return "relaunching";
    if (update?.installed && !update.canInstall) return "installed";
    if (update?.available) return "available";
    if (update?.error) return "error";
    return update?.checkedAt ? "current" : "idle";
  }

  function updateCardContent(update, draw, embedded = false) {
    const released = update.publishedAt ? new Date(update.publishedAt).toLocaleDateString(HomeswiftI18n.locale) : null;
    let command = null;
    if (update.command) {
      const copy = el("button", { actionIcon: "copy", type: "button", text: t("Copy"), onclick: async () => {
        try { await copyText(update.command); copy.textContent = t("Copied"); } catch { copy.textContent = t("Not copied"); }
        setTimeout(() => { copy.textContent = t("Copy"); }, 1800);
      } });
      command = el("div", { class: "update-command" }, el("code", { text: update.command }), copy);
    }
    const phase = updatePhase(update);
    // Installing, relaunching, or on disk but not running (`brew upgrade` done, here or by hand): no how-to.
    const underway = ["installing", "relaunching", "installed"].includes(phase);
    const spinner = () => el("span", { class: "spinner", "aria-hidden": "true" });
    const progress = (glyph, text) => el("p", { class: "update-progress", role: "status" }, glyph, el("span", { text }));
    const status = {
      installing: () => installProgress(update),
      relaunching: () => progress(spinner(), t("Restarting into Homeswift {version}…", { version: update.installed })),
      installed: () => progress(HomeswiftCommon.icon("check"), t("Homeswift {version} is installed. Relaunch to start it.", { version: update.installed })),
    }[phase]?.() ?? null;
    // The Status page's card as a hero: the new version large, what this one is, one line, and its action at the right.
    if (!embedded) {
      const days = update.publishedAt ? Math.max(0, Math.round((Date.now() - new Date(update.publishedAt)) / 86400000)) : null;
      const when = days == null ? null : new Intl.RelativeTimeFormat(HomeswiftI18n.locale, { numeric: "auto" }).format(-days, "day");
      const installable = update.canInstall && isAdmin();
      const action = phase === "installed" && isAdmin() ? el("button", { class: "primary", type: "button", actionIcon: "power", text: t("Relaunch now"), onclick: restartBridge })
        : installable ? el("button", { class: "primary", type: "button", actionIcon: "download", text: t("Update and restart"), onclick: (event) => installUpdate(event.currentTarget, update, draw) })
        : update.download ? el("a", { class: "button primary", href: update.download.url, rel: "noopener", title: update.download.name, actionIcon: "download", text: t("Download the package") })
        : null;
      return [
        el("div", { class: "update-hero" },
          el("div", { class: "update-hero-text" },
            el("span", { class: "update-hero-kicker", text: t("A new version") }),
            el("strong", { class: "update-hero-version", text: update.latest }),
            el("span", { class: "update-hero-meta", text: when ? t("You run {version} · released {when}", { version: update.current, when }) : t("You run {version}", { version: update.current }) }),
            underway ? null : el("p", { text: installable ? t("Pairings, scenes and the vault are kept; the bridge restarts on its own.") : HomeswiftI18n.message(update.how) })),
          underway || !action ? null : el("div", { class: "update-hero-action" }, action)),
        status,
        update.installError ? el("p", { class: "error", role: "alert", text: t("Could not install the update: {error}", { error: update.installError }) }) : null,
        underway || installable ? null : command,
        el("div", { class: "update-hero-links" },
          update.notes ? el("details", { class: "more-options" }, el("summary", { text: t("What's new") }), markdown(update.notes)) : null,
          el("a", { class: "update-hero-link", href: update.url, target: "_blank", rel: "noopener" }, HomeswiftCommon.icon("open"), el("span", { text: t("On GitHub") }))),
      ];
    }
    return [
      embedded ? null : el("div", { class: "server-head" },
        tile("update", "green"),
        el("div", { class: "who" },
          el("strong", { text: t("Homeswift {version} is available", { version: update.latest }) }),
          el("div", { class: "muted", text: released ? t("This is {version} · released {date}", { version: update.current, date: released }) : t("This is {version}", { version: update.current }) }))),
      underway ? null : el("p", { text: HomeswiftI18n.message(update.how) }),
      status,
      update.installError ? el("p", { class: "error", role: "alert", text: t("Could not install the update: {error}", { error: update.installError }) }) : null,
      underway ? null : command,
      el("div", { class: "actions" },
        update.canInstall && !underway && isAdmin()
          ? el("button", { class: "primary", type: "button", actionIcon: "download", text: t("Install and relaunch"), onclick: (event) => installUpdate(event.currentTarget, update, draw) }) : null,
        phase === "installed" && isAdmin() ? el("button", { class: "primary", type: "button", actionIcon: "power", text: t("Relaunch now"), onclick: restartBridge }) : null,
        update.download ? el("a", { class: "button primary", href: update.download.url, rel: "noopener", title: update.download.name, actionIcon: "download", text: t("Download the package") }) : null,
        el("a", { class: "button", href: update.url, target: "_blank", rel: "noopener", actionIcon: "open", text: t("On GitHub") })),
      update.notes ? el("details", { class: "more-options" }, el("summary", { text: t("What's new") }), markdown(update.notes)) : null,
    ];
  }

  /// What an install is doing, from the bridge's `progress`: downloading (the share done when the size is known),
  /// then installing; the words "Downloading 42 %" for the footer's button.
  function updateProgressLabel(update) {
    const fraction = update?.progress?.fraction;
    if (update?.progress?.phase === "installing") return t("Installing…");
    return fraction == null ? t("Downloading…") : t("Downloading {percent} %", { percent: Math.round(fraction * 100) });
  }
  /// The card's line while an update installs: what it does, how far, and a bar (a pulse while the share is unknown).
  function installProgress(update) {
    const installing = update.progress?.phase === "installing";
    const fraction = installing ? null : update.progress?.fraction;
    const percent = fraction == null ? null : Math.round(fraction * 100);
    const text = installing ? t("Installing Homeswift {version}… The bridge restarts when it is done.", { version: update.installing })
      : t("Downloading Homeswift {version}…", { version: update.installing });
    return el("div", { class: "update-install", role: "status" },
      el("div", { class: "update-install-head" }, el("span", { text }), percent == null ? null : el("b", { text: `${percent} %` })),
      el("div", { class: `progress-bar${percent == null ? " indeterminate" : ""}`, role: "progressbar", "aria-label": text,
        "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": percent == null ? null : String(percent) },
        el("span", { style: percent == null ? null : `width: ${percent}%` })));
  }

  /// Asks the bridge to install the latest release and relaunch, then follows it: the card shows the install, and the
  /// restart's overlay takes over once the bridge goes down to start the new version.
  async function installUpdate(button, update, draw) {
    if (!await confirmRestart({ title: t("Update to Homeswift {version}?", { version: update.latest }), confirm: t("Update and restart"), icon: "download",
      text: t("Homeswift installs the update, then restarts. Your accessories will disconnect briefly; this page reconnects when the new version is ready.") })) return;
    button.disabled = true;
    const started = Date.now();
    let state;
    try {
      state = await api("/api/updates/install", { method: "POST", body: {} });
    } catch (e) {
      button.disabled = false;
      HomeswiftCommon.showAlert(e.message);
      return;
    }
    draw(state);
    // Redrawn only when the state says something new: the card keeps its open "What's new".
    let shown = JSON.stringify(state);
    // An upgrade fetches and may build: minutes, at most the installer's half hour.
    while (state.installing) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try {
        state = await api("/api/updates");
      } catch (e) {
        // Gone: the restart began between two questions.
        if (!(e instanceof ApiError)) { waitForRestart(started); return; }
        HomeswiftCommon.showAlert(e.message);
        return;
      }
      if (JSON.stringify(state) !== shown) { shown = JSON.stringify(state); draw(state); }
    }
    if (state.relaunching) waitForRestart(started);
  }

  /// The Status page's charts: the process's memory and CPU, and how long the Home app's requests and the plugins'
  /// calls to their devices take, over the range and for the bridge or accessory the filters above them choose (the
  /// Logs page's). A range that ends now refreshes every minute; while new data loads the charts stay, faded.
  function activity(accessories, bridges) {
    const params = new URLSearchParams(location.search);
    const range = HomeswiftCommon.rangeControl(params, { presets: [["1h", t("1 hour")], ["6h", t("6 hours")], ["24h", t("24 hours")], ["today", t("Today")], ["yesterday", t("Yesterday")], ["7d", t("7 days")]],
      fallback: "1h", changed: () => load() });
    const sources = sourceFilter(accessories, bridges, initialSource(accessories, bridges, params.get("accessory"), params.get("bridge")), {
      label: t("Whose requests"), everything: t("All servers"), changed: () => load() });
    const byID = new Map(accessories.map((accessory) => [accessory.id, accessory]));
    const durations = (key) => [
      { label: t("Average"), tone: 1, value: (point) => point[key]?.average ?? null },
      { label: t("Longest"), tone: 2, value: (point) => point[key]?.longest ?? null },
    ];
    const charts = [
      { id: "memory", title: t("Memory"), note: t("The homeswift process, at its highest in each point"), series: [{ label: t("Memory"), tone: "accent", value: (point) => point.memory }], format: formatBytes,
        unit: (max) => 1024 ** (max >= 1024 ** 3 ? 3 : 2) },
      { id: "cpu", title: t("CPU"), note: t("The homeswift process; 100% is one core busy"), series: [{ label: t("CPU"), tone: "accent", value: (point) => point.cpu }], format: formatPercent },
      { title: t("Home app requests"), note: t("How long the bridge takes to answer reads and writes"), series: durations("requests"), format: formatMilliseconds, key: "requests" },
      { title: t("Plugin device calls"), note: t("How long plugins take to reach their devices or clouds"), series: durations("handlers"), format: formatMilliseconds, key: "handlers" },
    ].map((chart) => {
      const figure = el("b", { class: "chart-figure" });
      const detail = el("div", { class: "muted chart-detail" });
      const body = el("div", { class: "chart-body" });
      const card = el("div", { class: "card chart-card" },
        el("div", { class: "chart-head" }, el("div", { class: "who" }, el("strong", { text: chart.title }), el("div", { class: "muted", text: chart.note })), figure),
        body, detail);
      return { ...chart, card, figure, detail, body, view: null };
    });
    const table = el("details", { class: "more chart-table" }, el("summary", { text: t("Show as a table") }));
    table.addEventListener("toggle", () => { if (table.open) fillTable(); });
    const section = el("section", { class: "activity" },
      el("h2", { text: t("Activity") }),
      el("div", { class: "filter-bar" }, range.control, sources.picker,
        HomeswiftCommon.clearFilters([[sources.picker, ""]], { active: () => range.chosen(), reset: () => range.reset(), events: [[range.control, "change"]] })),
      el("div", { class: "chart-grid" }, charts.map((chart) => chart.card)),
      table);
    let shown = null;   // the last history loaded, for the table
    let refresh = null;

    function keepAddress() {
      // The Energy section's choices stay in the address.
      const query = new URLSearchParams([...new URLSearchParams(location.search)].filter(([key]) => key.startsWith("energy")));
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
        const now = chart.id === "memory" ? latest.memory : latest.cpu;
        chart.figure.textContent = live && now != null ? chart.format(now) : values.length ? chart.format(values.at(-1)) : "–";
        chart.detail.textContent = values.length ? t("Highest {highest} · lowest {lowest}", { highest: chart.format(Math.max(...values)), lowest: chart.format(Math.min(...values)) }) : "";
        return;
      }
      const calls = points.map((point) => point[chart.key]).filter(Boolean);
      const count = calls.reduce((sum, one) => sum + one.count, 0);
      const average = count ? calls.reduce((sum, one) => sum + one.average * one.count, 0) / count : null;
      chart.figure.textContent = average == null ? "–" : chart.format(average);
      chart.detail.textContent = count ? tn("Average of {n} call · longest {longest}", "Average of {n} calls · longest {longest}", count, { longest: chart.format(Math.max(...calls.map((one) => one.longest))) }) : t("No calls in this range");
    }

    /// The charts' points, newest first, under two header rows: the process (memory, CPU), then the Home app's
    /// requests and the plugins' device calls, each its average, longest and count; a rule between the groups.
    function fillTable() {
      if (!shown) return;
      const time = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      const cell = (value, format, start = false) => el("td", { class: [value == null ? "empty" : "", start ? "group-start" : ""].join(" ").trim(), text: value == null ? "–" : format(value) });
      const calls = (one) => [cell(one?.average, formatMilliseconds, true), cell(one?.longest, formatMilliseconds), cell(one?.count, (n) => n.toLocaleString(HomeswiftI18n.locale))];
      const group = (text, span, start = true) => el("th", { scope: "colgroup", colSpan: span, class: start ? "group-start" : "", text });
      const column = (text, start = false) => el("th", { scope: "col", class: start ? "group-start" : "", text });
      table.replaceChildren(table.firstChild, el("div", { class: "table-scroll" }, el("table", {},
        el("thead", {},
          el("tr", { class: "groups" },
            el("th", { scope: "col", rowSpan: 2, class: "time", text: t("Time") }),
            group("homeswift", 2, false), group(t("Home app requests"), 3), group(t("Plugin device calls"), 3)),
          el("tr", {}, column(t("Memory")), column(t("CPU")), column(t("Average"), true), column(t("Longest")), column(t("Count")), column(t("Average"), true), column(t("Longest")), column(t("Count")))),
        el("tbody", {}, [...shown.points].reverse().map((point) => el("tr", {},
          el("th", { scope: "row", class: "time", text: time.format(point.time) }), cell(point.memory, formatBytes), cell(point.cpu, formatPercent),
          calls(point.requests), calls(point.handlers)))))));
    }

    load();
    return section;
  }

  /// The Status page's Energy section, from the readings plugins record with a role (`EnergyTag`): the power of solar,
  /// the home, the grid (importing above zero) and the batteries (charging above zero), added up across devices; each
  /// battery's level; and each day's energy in kWh. Hidden until some plugin records such readings. Its own range
  /// (`energy` in the address, the last 24 hours by default); a range that ends now refreshes every minute.
  function energy() {
    const params = new URLSearchParams(location.search);
    const range = HomeswiftCommon.rangeControl(params, { presets: [["24h", t("24 hours")], ["today", t("Today")], ["yesterday", t("Yesterday")], ["7d", t("7 days")]],
      fallback: "24h", names: { since: "energy", from: "energy-from", to: "energy-to" }, changed: () => load() });
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    // A colour per entity, the same in every chart: solar yellow, the home blue, the batteries aqua, the grid violet
    // (the palette's slots, validated for colour blindness in both modes). The lines' devices take the slots in order.
    const roles = [
      { id: "solar", label: t("Solar"), tone: 4 },
      { id: "home", label: t("Home [use]"), tone: 1 },
      { id: "battery", label: t("Battery"), tone: 3 },
      { id: "grid", label: t("Grid"), tone: 7 },
    ];
    const levelTones = [1, 2, 3, 4, 5, 6];
    const card = (title, note, icon, tone) => {
      const figure = el("b", { class: "chart-figure" });
      const detail = el("div", { class: "muted chart-detail" });
      const body = el("div", { class: "chart-body" });
      const titleNode = el("strong", { text: title });
      const node = el("div", { class: "card chart-card" },
        el("div", { class: "chart-head" }, tile(icon, tone), el("div", { class: "who" }, titleNode, el("div", { class: "muted", text: note })), figure),
        body, detail);
      return { title, titleNode, node, figure, detail, body, view: null, key: "" };
    };
    const power = card(t("Power [watts]"), t("Added up across devices: the grid above zero is imported, the battery above zero is charging"), "bolt", "orange");
    const levels = card(t("Battery level"), t("Each device's charge"), "battery", "teal");
    const days = card(t("Energy by day"), t("Where the home's energy came from, above the line, and where the rest went, below it"), "chart", "grey");
    // Folded until asked for; it stays open across refreshes.
    const dayTable = el("details", { class: "more chart-table" }, el("summary", { text: t("Show as a table") }));
    // The history, from the bridge's long-term archive (its own hours and imports such as a cloud's): a week, a month or a
    // year at a time (`energy-view` and `energy-date` in the address), with the periods before and after.
    const views = [["week", t("Week")], ["month", t("Month")], ["year", t("Year")]];
    let view = views.some(([one]) => one === params.get("energy-view")) ? params.get("energy-view") : "week";
    let anchor = parseDay(params.get("energy-date"));   // null: the period of today
    const viewButtons = views.map(([one, text]) => el("button", { type: "button", role: "radio", text, onclick: () => {
      if (one === view) return;
      view = one;
      anchor = null;
      markView();
      loadHistory();
    } }));
    const markView = () => viewButtons.forEach((button, index) => {
      button.classList.toggle("on", views[index][0] === view);
      button.setAttribute("aria-checked", String(views[index][0] === view));
    });
    markView();
    const previous = el("button", { type: "button", class: "menu-button", "aria-label": t("Previous period"), onclick: () => move(-1) }, HomeswiftCommon.icon("back"));
    const next = el("button", { type: "button", class: "menu-button", "aria-label": t("Next period"), onclick: () => move(1) }, HomeswiftCommon.icon("forward"));
    const periodLabel = el("strong", { class: "energy-period", "aria-live": "polite" });
    // Where each plugin's import of the history stands, then the period's totals, over the bars.
    const importsNode = el("div", { class: "energy-imports", role: "status" });
    const summary = el("div", { class: "energy-totals" });
    let importPoll = null;
    days.node.insertBefore(el("div", { class: "energy-history-bar" },
      el("div", { class: "group", role: "radiogroup", "aria-label": t("Period") }, viewButtons),
      el("div", { class: "energy-period-nav" }, previous, periodLabel, next)), days.body);
    days.node.insertBefore(importsNode, days.body);
    days.node.insertBefore(summary, days.body);
    let earliest = null, historyAsked = 0;
    const today = el("div", { class: "energy-today" });
    // The charts' points as a table, folded until asked for (the colours alone are not enough to read them by).
    const pointTable = el("details", { class: "more chart-table" }, el("summary", { text: t("Show as a table") }));
    pointTable.addEventListener("toggle", () => { if (pointTable.open) fillPoints(); });
    const section = el("section", { class: "activity energy", hidden: true },
      el("h2", { text: t("Energy") }),
      today,
      el("div", { class: "filter-bar" }, range.control),
      el("div", { class: "chart-grid" }, power.node, levels.node),
      pointTable,
      el("div", { class: "chart-grid energy-days" }, days.node));
    let lastReport = null;   // for the table
    let refresh = null;

    function keepAddress() {
      const query = new URLSearchParams([...new URLSearchParams(location.search)].filter(([key]) => !key.startsWith("energy")));
      range.address(query);
      if (view !== "week") query.set("energy-view", view);
      if (anchor) query.set("energy-date", isoDay(anchor));
      const path = `${location.pathname}${query.size ? `?${query}` : ""}`;
      if (path !== location.pathname + location.search) history.replaceState(null, "", path);
    }
    /// A chart drawn again with new points, made anew when its lines change (a device or a role appears).
    function draw(chart, series, points, from, to, step, format, latest = false) {
      const key = series.map((one) => one.label).join("\n");
      if (chart.view && chart.key === key) { chart.view.update(points, from, to, step); return; }
      chart.body.replaceChildren();
      chart.key = key;
      chart.view = HomeswiftChart.lineChart(chart.body, { title: chart.title, series, format, unit: (max) => max >= 1000 ? 1000 : 1, points, from, to, step, latest });
    }
    async function load() {
      clearTimeout(refresh);
      keepAddress();
      const [from, end] = range.span() ?? [new Date(Date.now() - 86400000), null];
      const to = end ?? new Date();
      section.classList.add("loading");
      let report;
      try {
        report = await api(`/api/metrics/energy?${new URLSearchParams({ from: from.toISOString(), to: to.toISOString(), timeZone })}`);
      } catch (e) {
        if (e.status === 404) { section.remove(); return; }
        power.detail.textContent = e.message;
        section.classList.remove("loading");
        return;
      }
      section.classList.remove("loading");
      // No plugin records energy: the section stays hidden, and looks again with the next refresh.
      section.hidden = !report.roles.length;
      const step = report.step * 1000;
      const shown = roles.filter((role) => report.roles.includes(role.id));
      power.node.hidden = !shown.length;
      if (shown.length) {
        const points = report.power.map((point) => ({ ...point, time: point.t * 1000 }));
        draw(power, shown.map((role) => ({ label: role.label, tone: role.tone, value: (point) => point[role.id] ?? null })), points, from.getTime(), to.getTime(), step, formatWatts);
        // The latest the bridge recorded; steps it recorded nothing in come from an imported hourly history, said so.
        const last = points.findLast((point) => !point.imported);
        const latest = last ? t("Latest: {values}", { values: shown.filter((role) => last[role.id] != null).map((role) => `${role.label} ${formatWatts(last[role.id])}`).join(" · ") }) : "";
        const imported = points.some((point) => point.imported) ? t("Where the bridge recorded nothing, the line shows the imported hourly history.") : "";
        power.detail.textContent = [latest, imported].filter(Boolean).join(" ");
      }
      levels.node.hidden = !report.levels.length;
      if (report.levels.length) {
        const byTime = new Map();
        for (const level of report.levels) {
          for (const [time, percent] of level.points) {
            const point = byTime.get(time) ?? { time: time * 1000 };
            point[level.series] = percent;
            byTime.set(time, point);
          }
        }
        const points = [...byTime.values()].sort((a, b) => a.time - b.time);
        draw(levels, report.levels.map((level, index) => ({ label: level.device, tone: levelTones[index % levelTones.length], value: (point) => point[level.series] ?? null })),
          points, from.getTime(), to.getTime(), step, formatPercent, true);
        // Each device's level is in the legend, beside its name.
        levels.detail.textContent = "";
      }
      lastReport = report;
      if (pointTable.open) fillPoints();
      fillToday(report.days[0], report.roles);
      // The history moves on with today; a period in the past stays as it is.
      if (!anchor || !historyAsked) loadHistory();
      if (!end) refresh = setTimeout(() => { if (section.isConnected && !document.hidden) load(); }, 60000);
    }

    /// One period earlier (-1) or later (1): 7 days, a month or a year. The period of today is the latest.
    function move(direction) {
      const base = anchor ?? new Date();
      const date = view === "week" ? new Date(base.getFullYear(), base.getMonth(), base.getDate() + 7 * direction)
        : view === "month" ? new Date(base.getFullYear(), base.getMonth() + direction, 1) : new Date(base.getFullYear() + direction, 0, 1);
      anchor = containsToday(date) ? null : date;
      loadHistory();
    }
    function containsToday(date) {
      const now = new Date();
      if (view === "year") return date.getFullYear() >= now.getFullYear();
      if (view === "month") return date.getFullYear() * 12 + date.getMonth() >= now.getFullYear() * 12 + now.getMonth();
      return date >= new Date(now.getFullYear(), now.getMonth(), now.getDate());
    }
    async function loadHistory() {
      clearTimeout(importPoll);
      const asked = ++historyAsked;
      keepAddress();
      let history;
      try {
        history = await api(`/api/metrics/energy/history?${new URLSearchParams({ period: view, date: isoDay(anchor ?? new Date()), timeZone })}`);
      } catch (e) {
        days.detail.textContent = e.message;
        return;
      }
      if (asked !== historyAsked) return;
      fillHistory(history);
      fillImports(history.imports ?? []);
    }

    /// An import under way: its progress, the bars filling in as it goes (the history is asked again every few
    /// seconds); one done: what it covers and when it last ran, quietly; one failed: why.
    function fillImports(imports) {
      clearTimeout(importPoll);
      const longDay = new Intl.DateTimeFormat(HomeswiftI18n.locale, { day: "numeric", month: "long", year: "numeric" });
      const day = (text) => longDay.format(parseDay(text));
      importsNode.replaceChildren(...imports.map((one) => {
        if (one.state === "running") {
          return el("div", { class: "energy-import running" },
            el("div", { class: "energy-import-line" }, el("span", { text: t("Importing the {name} history", { name: one.name }) }),
              one.total ? el("b", { text: t("{done} of {total}", { done: one.done, total: one.total }) }) : null),
            el("progress", { max: Math.max(one.total, 1), value: one.total ? one.done : null, "aria-label": t("Importing the {name} history", { name: one.name }) }));
        }
        if (one.state === "failed") {
          return el("div", { class: "energy-import failed" }, HomeswiftCommon.icon("warning"),
            el("span", { text: t("The {name} history could not be imported: {message}", { name: one.name, message: one.message ?? "" }) }));
        }
        return el("div", { class: "energy-import done muted" }, HomeswiftCommon.icon("history"),
          el("span", { text: one.from ? t("History from {name} since {date}, updated {ago}", { name: one.name, date: day(one.from), ago: HomeswiftCommon.ago(one.updated) })
            : t("History from {name}, updated {ago}", { name: one.name, ago: HomeswiftCommon.ago(one.updated) }) }));
      }));
      if (imports.some((one) => one.state === "running")) importPoll = setTimeout(() => { if (section.isConnected && !document.hidden) loadHistory(); }, 3000);
    }

    /// The period's energy as bars, oldest first: above zero where the home's energy came from (solar as it was
    /// produced, the batteries, the grid, or not split: an imported hour has no grid or battery), below zero where the
    /// rest went (into the batteries, out to the grid); only what some bar knows. The same figures as a table, folded.
    function fillHistory(history) {
      earliest = history.earliest ? parseDay(history.earliest) : null;
      const bars = history.bars;
      const known = (bar) => bar.recordedHours + bar.importedHours > 0;
      const has = (field) => bars.some((bar) => known(bar) && bar[field] != null);
      const monthly = view === "year";
      const segments = [
        has("homeFromSolar") ? { label: t("Home from solar"), tone: 4, field: "homeFromSolar" } : null,
        has("homeFromBattery") ? { label: t("Home from batteries"), tone: 3, field: "homeFromBattery" } : null,
        has("homeFromGrid") ? { label: t("Home from the grid"), tone: 7, field: "homeFromGrid" } : null,
        has("homeNotSplit") ? { label: t("Home, not split by source"), tone: 8, field: "homeNotSplit" } : null,
        !has("home") && has("solar") ? { label: t("Solar produced"), tone: 4, field: "solar" } : null,
        has("batteryCharge") ? { label: t("Into batteries"), tone: 3, field: "batteryCharge", below: true } : null,
        has("gridExport") ? { label: t("Exported to the grid"), tone: 7, field: "gridExport", below: true } : null,
      ].filter(Boolean);
      // The legend names each colour once: an entity is the same colour above the line and below it.
      const legend = [...new Map(segments.map((one) => [one.tone, { tone: one.tone, label: { 4: t("Solar"), 3: t("Batteries"), 7: t("Grid"), 8: t("Not split") }[one.tone] }])).values()];
      const today = isoDay(new Date()), yesterday = isoDay(new Date(Date.now() - 86400000));
      const dateOf = (bar) => { const [year, month, day] = bar.date.split("-").map(Number); return new Date(year, month - 1, day || 1); };
      const name = (bar, format) => monthly ? format.format(dateOf(bar))
        : bar.date === today ? t("Today") : bar.date === yesterday && format === dayFormat ? t("Yesterday") : format.format(dateOf(bar));
      const chartBars = bars.map((bar) => ({
        label: monthly ? shortMonth.format(dateOf(bar)) : view === "month" ? String(dateOf(bar).getDate()) : name(bar, shortDay),
        narrow: monthly ? narrowMonth.format(dateOf(bar)) : String(dateOf(bar).getDate()),
        title: name(bar, monthly ? monthYear : dayFormat), values: known(bar) ? bar : null,
        current: monthly ? bar.date === today.slice(0, 7) : bar.date === today }));
      const key = view + "\n" + segments.map((one) => one.label).join("\n");
      days.titleNode.textContent = monthly ? t("Energy by month") : t("Energy by day");
      if (days.view && days.key === key) days.view.update(chartBars);
      else {
        days.body.replaceChildren();
        days.key = key;
        days.view = HomeswiftChart.stackedBars(days.body, { title: days.titleNode.textContent, legend, bars: chartBars, format: formatKWh, unit: () => 1,
          segments: segments.map((one) => ({ ...one, value: (values) => values?.[one.field] == null ? null : (one.below ? -1 : 1) * values[one.field] })) });
        days.body.append(dayTable);
      }

      // The period, and the way to the ones around it: none before the history's first hour, none after today.
      const first = dateOf(bars[0]), last = dateOf(bars.at(-1));
      periodLabel.textContent = monthly ? String(first.getFullYear()) : view === "month" ? monthYear.format(first) : rangeFormat.formatRange(first, last);
      previous.disabled = !earliest || first <= earliest;
      next.disabled = !anchor;

      // The period's totals, each labelled with its colour, over the bars; under them, why imported hours have their
      // home use not split.
      const sum = (field) => bars.filter(known).reduce((total, bar) => bar[field] == null ? total : (total ?? 0) + bar[field], null);
      const solar = sum("solar"), home = sum("home"), imported = sum("gridImport"), exported = sum("gridExport");
      const charged = sum("batteryCharge"), discharged = sum("batteryDischarge");
      // A key only for a colour the bars draw; the grid's figures say they cover the recorded days only when the period
      // has imported days without them (an import of solar and home use alone).
      const partly = bars.some((bar) => bar.importedHours && bar.gridImport == null && bar.gridExport == null);
      const total = (tone, label, value, note) => el("div", { class: "energy-total" },
        el("span", {}, tone ? el("i", { class: `key bar tone-${tone}`, "aria-hidden": "true" }) : null, label), el("b", { text: value }),
        note ? el("small", { text: note }) : null);
      // The card's question answered first: the home's use, and the share of it each source covered, as a strip of the
      // bars' colours with each share written beside its key (identity never by colour alone).
      const shares = home > 0 ? [[4, t("Solar"), sum("homeFromSolar")], [3, t("Batteries"), sum("homeFromBattery")],
        [7, t("Grid"), sum("homeFromGrid")], [8, t("Not split"), sum("homeNotSplit")]]
        .filter(([, , value]) => value > 0).map(([tone, label, value]) => ({ tone, label, share: value / home * 100 })) : [];
      const homeNode = home == null ? null : el("div", { class: "energy-home" },
        total(null, t("Home used"), formatKWh(home)),
        shares.length ? el("div", { class: "energy-share", role: "img", "aria-label": `${t("Home used")}: ${shares.map((one) => `${one.label} ${formatPercent(one.share)}`).join(", ")}` },
          el("div", { class: "energy-share-bar", "aria-hidden": "true" }, shares.map((one) => el("i", { class: `tone-${one.tone}`, style: `flex-grow: ${one.share}` }))),
          el("div", { class: "energy-share-keys", "aria-hidden": "true" }, shares.map((one) =>
            el("span", {}, el("i", { class: `key bar tone-${one.tone}` }), one.label, el("b", { text: formatPercent(one.share) }))))) : null);
      // Then where the energy flowed: produced, through the batteries, across the grid.
      const flows = [
        solar != null ? total(4, t("Solar produced"), formatKWh(solar)) : null,
        charged != null ? total(3, t("Battery charged"), formatKWh(charged)) : null,
        discharged != null ? total(3, t("Battery discharged"), formatKWh(discharged)) : null,
        imported != null ? total(7, t("Grid import"), formatKWh(imported), partly ? t("Recorded days only") : null) : null,
        exported != null ? total(7, t("Grid export"), formatKWh(exported), partly ? t("Recorded days only") : null) : null,
      ].filter(Boolean);
      summary.replaceChildren(...(homeNode || flows.length ? [homeNode, flows.length ? el("div", { class: "energy-flows" }, flows) : null].filter(Boolean)
        : [el("span", { class: "muted", text: t("Nothing recorded in this period") })]));
      days.detail.replaceChildren(...[bars.some((bar) => bar.homeNotSplit > 0)
        ? el("div", { text: t("Imported hours have no grid or battery figures: the rest of their home use is not split by source.") }) : null].filter(Boolean));

      const columns = [
        has("solar") ? [t("Solar produced"), "solar", formatKWh] : null,
        has("home") ? [t("Home used"), "home", formatKWh] : null,
        has("gridImport") ? [t("Grid import"), "gridImport", formatKWh] : null,
        has("gridExport") ? [t("Grid export"), "gridExport", formatKWh] : null,
        has("batteryCharge") ? [t("Battery charged"), "batteryCharge", formatKWh] : null,
        has("batteryDischarge") ? [t("Battery discharged"), "batteryDischarge", formatKWh] : null,
        has("solarShare") ? [t("Home from solar"), "solarShare", (share) => formatPercent(share * 100)] : null,
      ].filter(Boolean);
      dayTable.replaceChildren(dayTable.firstChild, el("div", { class: "table-scroll" }, el("table", {},
        el("thead", {}, el("tr", {}, el("th", { scope: "col", class: "time", text: monthly ? t("Month") : t("Day") }), columns.map(([title]) => el("th", { scope: "col", text: title })))),
        el("tbody", {}, [...bars].reverse().map((bar) => el("tr", {},
          el("th", { scope: "row", class: "time", text: name(bar, monthly ? monthYear : dayFormat) }),
          columns.map(([, field, format]) => {
            const one = known(bar) ? bar[field] : null;
            return el("td", { class: one == null ? "empty" : "", text: one == null ? "–" : format(one) });
          })))))));
    }

    /// Today's figures, each with its label: solar produced, the home's use, the share solar covered, the grid's import.
    function fillToday(day, present) {
      const has = (role) => present.includes(role);
      // Each with its entity's icon and colour, as the charts draw it.
      const figure = (icon, tone, label, value, note) => el("div", { class: "card" }, tile(icon, tone),
        el("div", {}, el("span", { text: label }), el("b", { text: value }), note ? el("small", { text: note }) : null));
      const known = Boolean(day?.minutes);
      const kWh = (value) => known ? formatKWh(value) : "–";
      today.replaceChildren(...[
        has("solar") ? figure("sun", "yellow", t("Solar today"), kWh(day?.solar)) : null,
        has("home") ? figure("house", "blue", t("Home used today"), kWh(day?.home)) : null,
        has("solar") && has("home") ? figure("leaf", "green", t("Home from solar"), known && day.solarShare != null ? formatPercent(day.solarShare * 100) : "–", t("As it was produced")) : null,
        has("grid") ? figure("pylon", "violet", t("Grid import today"), kWh(day?.gridImport), known ? t("{value} exported", { value: formatKWh(day.gridExport) }) : null) : null,
      ].filter(Boolean));
    }

    /// The power and levels at each point, newest first.
    function fillPoints() {
      if (!lastReport) return;
      const time = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      const present = roles.filter((role) => lastReport.roles.includes(role.id));
      const rows = new Map();
      for (const point of lastReport.power) rows.set(point.t, { ...point });
      for (const level of lastReport.levels) for (const [t0, percent] of level.points) rows.set(t0, { ...(rows.get(t0) ?? { t: t0 }), [level.series]: percent });
      const cell = (value, format) => el("td", { class: value == null ? "empty" : "", text: value == null ? "–" : format(value) });
      pointTable.replaceChildren(pointTable.firstChild, el("div", { class: "table-scroll" }, el("table", {},
        el("thead", {}, el("tr", {}, el("th", { scope: "col", class: "time", text: t("Time") }),
          present.map((role) => el("th", { scope: "col", text: role.label })), lastReport.levels.map((level) => el("th", { scope: "col", text: level.device })))),
        el("tbody", {}, [...rows.values()].sort((a, b) => b.t - a.t).map((row) => el("tr", {},
          el("th", { scope: "row", class: "time", text: time.format(row.t * 1000) }),
          present.map((role) => cell(row[role.id], formatWatts)), lastReport.levels.map((level) => cell(row[level.series], formatPercent))))))));
    }

    load();
    return section;
  }
  const dayFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short", day: "numeric", month: "short" });
  const shortMonth = new Intl.DateTimeFormat(HomeswiftI18n.locale, { month: "short" });
  const narrowMonth = new Intl.DateTimeFormat(HomeswiftI18n.locale, { month: "narrow" });
  const monthYear = new Intl.DateTimeFormat(HomeswiftI18n.locale, { month: "long", year: "numeric" });
  const rangeFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { day: "numeric", month: "short" });
  /// A local day as YYYY-MM-DD, and back (null for anything else).
  const isoDay = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  function parseDay(text) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text ?? "");
    return match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])) : null;
  }
  const shortDay = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short", day: "numeric" });

  /// Watts, as kW from 1 kW (or when `top`, the axis's highest, is); a minus sign below zero.
  function formatWatts(watts, top = Math.abs(watts)) {
    const kilo = Math.max(Math.abs(watts), top) >= 1000;
    const value = kilo ? watts / 1000 : watts;
    const digits = kilo && Math.abs(value) < 10 ? (Number.isInteger(value) ? 0 : 1) : 0;
    return `${value.toLocaleString(HomeswiftI18n.locale, { minimumFractionDigits: digits, maximumFractionDigits: digits })} ${kilo ? "kW" : "W"}`;
  }
  /// Kilowatt-hours: two decimals under 10, one under 100, whole from there (3,009 kWh, not 3,009.0); an axis's tick
  /// (with `top`) a whole number when it is one.
  function formatKWh(kWh, top) {
    const size = Math.abs(kWh);
    const digits = (top != null && Number.isInteger(kWh)) || kWh === 0 ? 0 : size < 10 ? 2 : size < 100 ? 1 : 0;
    return `${kWh.toLocaleString(HomeswiftI18n.locale, { minimumFractionDigits: digits, maximumFractionDigits: digits })} kWh`;
  }

  /// Bytes as MB, or GB from 1 GB; `top`, the axis's highest, keeps a chart's ticks in one unit.
  const formatBytes = (bytes, top = bytes) => HomeswiftCommon.byteSize(bytes, top);
  function formatPercent(value) { return `${value > 0 && value < 10 ? value.toFixed(1) : Math.round(value)}%`; }
  /// Milliseconds: one decimal under 10, two when the value has them (an axis's 0.25 and 0.75 ticks, not 0.3 and 0.8).
  function formatMilliseconds(ms) {
    if (ms >= 1000) return `${(ms / 1000).toFixed(ms >= 10000 ? 0 : 1)} s`;
    const hundredths = Math.abs(ms * 10 - Math.round(ms * 10)) > 1e-6;
    return `${ms > 0 && ms < 10 ? ms.toFixed(hundredths ? 2 : 1) : Math.round(ms)} ms`;
  }

  function formatDuration(seconds) {
    const d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60);
    return d ? t("{d}d {h}h", { d, h }) : h ? t("{h}h {m}m", { h, m }) : t("{m}m", { m });
  }

  // ---- Accessories ---------------------------------------------------------
  // A wall of widgets (widgets.js): each accessory at the size chosen for it, else the size chosen for its kind,
  // else the kind's own; in the order chosen, on one wall or a wall per plugin. The bridge keeps the layout
  // (/api/layout), the same for every user: a widget's menu sets its size, Edit sets sizes and order.

  const sizeNames = { small: t("Small"), medium: t("Medium"), large: t("Large"), xlarge: t("Extra large") };
  // A kind of widget as the menu names it: "Medium for every light".
  const kindNames = {
    climate: t("air conditioner and thermostat"), "air-purifier": t("air purifier"), fan: t("fan"), light: t("light"), cover: t("shutter"), toggle: t("switch"),
    "switch-group": t("group of switches"), television: t("television"), "garage-door": t("gate"), lock: t("lock [kind]"), "security-system": t("alarm"), valve: t("valve"),
    sensor: t("sensor"), camera: t("camera"), inspector: t("other accessory"),
  };

  // The accessories that are Matter devices of their own (/api/matter), for their menus: the pages with accessory
  // menus (Accessories, Status's quick section) keep it current.
  let matterOwn = new Set();
  // One that did not start counts: its menu leads to the row that says why, and takes it off.
  const rememberMatterOwn = (matter) => { matterOwn = new Set([...(matter?.ownDevices || []), ...(matter?.failedDevices || [])].map((device) => device.id)); };
  const loadMatterOwn = () => api("/api/matter").then(rememberMatterOwn).catch(() => {});

  /// An accessory as a Matter device of its own, with its own pairing code (the Status page shows it), or back off.
  function matterActions(accessory) {
    const card = `/status#matter-${slug(accessory.id)}`;
    const set = async (own) => {
      try {
        await api(`/api/matter/devices/${encodeURIComponent(accessory.id)}`, { method: "PUT", body: { own } });
        // The reply comes once Matter has the change: the Status page then shows the device's code.
        if (own) { matterOwn.add(accessory.id); navigate(card); } else { matterOwn.delete(accessory.id); route(); }
      } catch (e) { HomeswiftCommon.showAlert(e.message); }
    };
    if (!matterOwn.has(accessory.id)) {
      return [{ label: t("Make a Matter device"), icon: "link", onSelect: () => set(true) }];
    }
    return [
      { label: t("Matter pairing code"), icon: "link", href: card },
      { label: t("Take off Matter"), icon: "close", onSelect: async () => {
        if (await HomeswiftCommon.confirmDialog(t("{name} leaves Matter: the ecosystems that added it lose it.", { name: accessory.name }))) await set(false);
      } },
    ];
  }

  /// Whether the Home app has the accessory: off, HomeKit loses it (and its room, scenes and automations) while
  /// Homeswift and Matter keep it, so a Matter device of its own can be in Apple Home through Matter alone.
  function homeKitToggle(accessory) {
    const visible = !accessory.hiddenFromHomeKit;
    return { label: t("Visible in Home app"), icon: "house", checked: visible, checkbox: true, toggle: true, onSelect: async () => {
      if (visible && !await HomeswiftCommon.confirmDialog(t("{name} leaves the Home app, with its room, scenes and automations. Homeswift and Matter keep it; shown again, the Home app adds it as a new accessory.", { name: accessory.name }))) return;
      try {
        await api(`/api/accessories/${encodeURIComponent(accessory.id)}/homekit`, { method: "PUT", body: { visible: !visible } });
        route();
      } catch (e) { HomeswiftCommon.showAlert(e.message); }
    } };
  }

  /// What the menu of an accessory's widget offers, after its sizes.
  /// An accessory's ⋯ menu after All controls, in groups as a context menu orders them: what to look at or do with
  /// it, how it sits on the wall (`arrange`, the wall's size choices, first), then the administrator's way to its
  /// plugin. A separator between groups, none around an empty one.
  function accessoryActions(accessory, arrange = []) {
    const use = [
      accessory.history ? { label: t("History"), icon: "chart", onSelect: () => HomeswiftAdmin.history(accessory) } : null,
      accessory.supportsIdentify ? { label: t("Identify"), icon: "identify", onSelect: () => api(`/api/accessories/${encodeURIComponent(accessory.id)}/identify`, { method: "POST" }).catch((e) => HomeswiftCommon.showAlert(e.message)) } : null,
      window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: sparkle(), onSelect: () => HomeswiftChat.ask(t("About {name}: ", { name: accessory.name })) } : null,
    ];
    const layout = [...arrange, ...(isAdmin() ? window.HomeswiftHome?.layoutActions(accessory) ?? [] : [])];
    const manage = [
      // A paused plugin's accessories do nothing until it runs again.
      accessory.paused && isAdmin() ? { label: t("Resume {name}", { name: accessory.platformName }), icon: "play", onSelect: async () => {
        try { await setPaused(accessory.platform, accessory.platformName, false); route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
      } } : null,
      isAdmin() ? { label: t("Show its log"), icon: "logs", href: `/logs/${accessory.slug ?? encodeURIComponent(accessory.id)}` } : null,
      isAdmin() && !accessory.mirroredFrom && accessory.platform ? homeKitToggle(accessory) : null,
      ...(isAdmin() && !accessory.mirroredFrom ? matterActions(accessory) : []),
      accessory.platform && isAdmin() ? { label: t("Plugin settings"), icon: "gear", href: `/plugins/${slug(accessory.platformName || accessory.platform)}` } : null,
    ];
    return [use, layout, manage].map((group) => group.filter(Boolean)).filter((group) => group.length)
      .flatMap((group, index) => index ? [{ separator: true }, ...group] : group);
  }

  // /accessories?group=room|plugin&hidden=1&from=<source>: sections per room (once there are rooms) or per plugin; hidden
  // accessories only with hidden=1; only another controller's (Apple Home's, through Wingman) with from=.
  /// The Accessories page's views, as tabs: the wall and the graph.
  const accessoryTabs = (current) => HomeswiftCommon.subnav(t("Accessories views"), "/accessories", [["", t("Wall"), "wall"], ["graph", t("Graph"), "chart"]], current);

  views.accessories = async (main, args = []) => {
    if (args[0] === "graph") return HomeswiftAdmin.graph(main, accessoryTabs("graph"));
    const [list, saved, home] = await Promise.all([api("/api/accessories"), api("/api/layout").catch(() => null), api("/api/rooms").catch(() => ({ rooms: [] })),
      isAdmin() ? loadMatterOwn() : null]);
    const all = withSlugs(list, "accessory");
    const params = new URLSearchParams(location.search);
    // Hidden accessories (an accessory's ⋯ menu) only with ?hidden=1.
    const showHidden = params.get("hidden") === "1";
    const noResponse = params.get("unavailable") === "1";
    // Full screen (?full=1): the widgets alone, a room or plugin a page when grouped; an address a wall tablet can open.
    const fullScreen = params.get("full") === "1";
    // The controllers some accessories mirror (Apple Home, through Wingman): each gets a filter.
    const sources = [...new Set(all.map((accessory) => accessory.mirroredFrom).filter(Boolean))];
    const from = sources.includes(params.get("from")) ? params.get("from") : null;
    const accessories = all.filter((accessory) => (showHidden || !accessory.hidden) && (!from || accessory.mirroredFrom === from) && (!noResponse || accessory.unavailable || accessory.paused));
    const hiddenCount = all.filter((accessory) => accessory.hidden).length;
    const rooms = home.rooms.map((room) => room.name);
    const servers = new Set(accessories.map((accessory) => accessory.bridge)).size;
    const layout = { order: [], sizes: {}, defaults: {}, grouping: "none", ...saved };
    const kinds = new Map(accessories.map((accessory) => [accessory.id, HomeswiftWidgets.kindOf(accessory)]));
    const kindOf = (accessory) => kinds.get(accessory.id).kind;
    const sizeOf = (accessory) => layout.sizes[accessory.id] || (accessory.members ? "large" : layout.defaults[kindOf(accessory)] || kinds.get(accessory.id).size);
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
      // Merge visible widget positions without dropping filtered accessories or group IDs.
      const visible = [...content.querySelectorAll(".wall > [data-id]")].map((node) => node.dataset.id);
      const visibleIDs = new Set(visible);
      const complete = [...new Set([...layout.order, ...ordered.map((accessory) => accessory.id), ...layout.groups.map((group) => group.id)])];
      let index = 0;
      layout.order = complete.map((id) => visibleIDs.has(id) ? visible[index++] : id);
      clearTimeout(saveTimer);
      saveTimer = setTimeout(async () => {
        try {
          await api("/api/layout", { method: "PUT", body: layout });
          note.classList.add("hidden");
        } catch (e) {
          if (e.status === 401) return;
          note.textContent = t("The layout was not kept: {error}", { error: e.message });
          note.classList.remove("hidden");
        }
      }, 300);
    };

    const groupingControls = HomeswiftGroups.mount({ all, layout, rooms,
      setGroupRoom: isAdmin() ? async (ids, room) => {
        await api("/api/rooms", { method: "PUT", body: { accessories: Object.fromEntries(ids.map((id) => [id, { room }])) } });
        for (const accessory of all) if (ids.includes(accessory.id)) accessory.room = room;
      } : null,
      moveToRoom: isAdmin() ? (group) => HomeswiftHome.moveGroupToRoom(group, all) : null,
      persist: async () => { clearTimeout(saveTimer); await api("/api/layout", { method: "PUT", body: layout }); }, refresh: render });
    window.homeswiftGroupEvent = groupingControls.event;
    window.homeswiftGroupSnapshot = groupingControls.snapshot;
    const nodes = new Map();
    const actions = (accessory) => {
      const size = sizeOf(accessory), kind = kindOf(accessory);
      return accessoryActions(accessory, [
        { label: t("Size"), choices: HomeswiftWidgets.sizes.map((one) => ({ label: sizeNames[one],
          badge: one === "xlarge" ? t("XL") : sizeNames[one][0].toUpperCase(), checked: one === size, onSelect: () => resize(accessory, one) })) },
        { label: kindNames[kind] ? t("{size} for every {kind}", { size: sizeNames[size], kind: kindNames[kind] }) : t("{size} for every accessory like it", { size: sizeNames[size] }), icon: "grid", onSelect: () => resizeKind(kind, size) },
      ]);
    };
    function widget(accessory) {
      const node = accessory.members ? groupingControls.card(accessory, editing) : HomeswiftWidgets.card(accessory, { size: sizeOf(accessory), actions });
      if (editing) editable(node, accessory);
      nodes.set(accessory.id, node);
      return node;
    }
    let layoutAnimation = 0;
    function animateLayout(change) {
      const before = new Map([...nodes].map(([id, node]) => [id, node.getBoundingClientRect()]));
      change();
      const revision = ++layoutAnimation;
      // Expanded cards measure their controls on the next frame before settling onto whole grid rows.
      requestAnimationFrame(() => requestAnimationFrame(() => {
        if (revision !== layoutAnimation || reducedMotion.matches) return;
        for (const [id, node] of nodes) {
          const was = before.get(id), now = node.getBoundingClientRect();
          if (!was?.width || !now.width || !now.height) continue;
          node.getAnimations().forEach((animation) => animation.cancel());
          node.animate([
            { transformOrigin: "top left", transform: `translate(${was.left - now.left}px, ${was.top - now.top}px) scale(${was.width / now.width}, ${was.height / now.height})` },
            { transformOrigin: "top left", transform: "none" }
          ], { duration: 220, easing: "cubic-bezier(.2,.8,.2,1)" });
        }
      }));
    }
    function resize(accessory, size, persist = true) {
      if (size === sizeOf(accessory)) return;
      animateLayout(() => {
        layout.sizes[accessory.id] = size;
        const node = nodes.get(accessory.id), wall = node?.parentElement;
        node?.replaceWith(widget(accessory));
        if (wall) { arrange(wall); arrangeObserver.observe(nodes.get(accessory.id)); }
      });
      if (persist) save();
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
      const node = nodes.get(accessory.id), targetNode = nodes.get(target.id);
      if (node && targetNode) { if (after) targetNode.after(node); else targetNode.before(node); }
      save();
      animateLayout(render);
    }
    function step(accessory, delta) {
      const node = nodes.get(accessory.id), wall = node?.parentElement;
      if (!wall) return;
      // On a wall with cells, a column left or right.
      const cell = cells.get(node);
      if (cell) {
        slide(wall, () => keepCells(wall, arrange(wall, { node, column: Math.max(1, cell[0] + delta), row: cell[1] })), null);
        save();
        nodes.get(accessory.id)?.querySelector(`.edit-bar [data-step="${delta}"]`)?.focus();
        return;
      }
      const siblings = [...wall.children].filter((child) => child.dataset.id && !child.classList.contains("hidden"));
      const target = siblings[siblings.indexOf(node) + delta];
      if (!target) return;
      if (delta > 0) target.after(node); else target.before(node);
      save();
      const ids = [...wall.children].map((child) => child.dataset.id).filter((id) => ordered.some((one) => one.id === id));
      const places = ordered.flatMap((one, index) => ids.includes(one.id) ? [index] : []);
      const byID = new Map(ordered.map((one) => [one.id, one]));
      ids.forEach((id, index) => { ordered[places[index]] = byID.get(id); });
      animateLayout(render);
      nodes.get(accessory.id)?.querySelector(`.edit-bar [data-step="${delta}"]`)?.focus();
    }
    /// In Edit: the sizes and the arrows over the widget, and the widget dragged into place.
    function editable(node, accessory) {
      const size = sizeOf(accessory);
      node.append(el("div", { class: "edit-caption", "aria-hidden": "true" },
        el("span", { class: "edit-grip", text: "⠿" }), el("span", { text: accessory.displayName || accessory.name })));
      node.append(el("div", { class: "edit-bar", role: "group", "aria-label": t("Size and place of {name}", { name: accessory.name }) },
        el("button", { type: "button", "aria-label": t("Move earlier"), title: t("Move earlier"), text: "‹", "data-step": "-1", onclick: () => step(accessory, -1) }),
        HomeswiftWidgets.sizes.map((one) => el("button", { type: "button", text: one === "xlarge" ? t("XL") : sizeNames[one][0].toUpperCase(), title: sizeNames[one], "aria-label": sizeNames[one], "aria-pressed": String(one === size), onclick: () => resize(accessory, one) })),
        el("button", { type: "button", "aria-label": t("Move later"), title: t("Move later"), text: "›", "data-step": "1", onclick: () => step(accessory, 1) })));
      const handle = el("button", { type: "button", class: "resize-handle", text: "◢",
        title: t("Drag to resize"), "aria-label": t("Resize {name}", { name: accessory.name }),
        onkeydown: (event) => {
          const delta = ["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : ["ArrowLeft", "ArrowUp"].includes(event.key) ? -1 : 0;
          if (!delta) return;
          event.preventDefault();
          const sizes = HomeswiftWidgets.sizes;
          resize(accessory, sizes[Math.max(0, Math.min(sizes.length - 1, sizes.indexOf(sizeOf(accessory)) + delta))]);
          nodes.get(accessory.id)?.querySelector(".resize-handle")?.focus();
        } });
      handle.addEventListener("pointerdown", (event) => resizeDrag(event, node, accessory));
      node.append(handle);
      node.addEventListener("pointerdown", (event) => drag(event, node));
    }

    function resizeDrag(event, node, accessory) {
      if (event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();
      const initial = sizeOf(accessory), box = node.getBoundingClientRect(), wall = node.parentElement;
      const style = getComputedStyle(wall), column = parseFloat(style.getPropertyValue("--unit")) || box.width;
      const row = parseFloat(style.gridAutoRows) || 64, gap = parseFloat(style.rowGap) || 10;
      const start = { x: event.clientX, y: event.clientY };
      wall.classList.add("resizing");
      // Capture on the stable wall: the card's contents are rebuilt as it crosses a size boundary.
      wall.setPointerCapture(event.pointerId);
      const move = (pointer) => {
        if (pointer.pointerId !== event.pointerId || Math.hypot(pointer.clientX - start.x, pointer.clientY - start.y) < 8) return;
        const width = box.width + pointer.clientX - start.x, height = box.height + pointer.clientY - start.y;
        const size = width < column * 1.5 ? (height < row * 1.5 + gap ? "small" : "medium")
          : (height < (row + gap) * 3.5 ? "large" : "xlarge");
        resize(accessory, size, false);
      };
      const end = (pointer) => {
        if (pointer.pointerId !== event.pointerId) return;
        wall.removeEventListener("pointermove", move);
        wall.removeEventListener("pointerup", end);
        wall.removeEventListener("pointercancel", end);
        wall.removeEventListener("lostpointercapture", end);
        wall.classList.remove("resizing");
        if (wall.hasPointerCapture(event.pointerId)) wall.releasePointerCapture(event.pointerId);
        if (pointer.type !== "pointerup") resize(accessory, initial, false);
        else save();
      };
      wall.addEventListener("pointermove", move);
      wall.addEventListener("pointerup", end);
      wall.addEventListener("pointercancel", end);
      wall.addEventListener("lostpointercapture", end);
    }

    // ---- Widgets on cells of their own: `layout.positions[grouping][id]` is a widget's top-left [column, row] ----

    /// The cells a widget spans, [columns, rows]: large and extra large as many rows as widgets.js fitted them to.
    function spanOf(node) {
      const rows = Number(node.style.getPropertyValue("--card-rows")) || 0;
      if (node.classList.contains("size-xlarge")) return [2, rows || 5];
      if (node.classList.contains("size-large")) return [2, rows || 3];
      return node.classList.contains("size-medium") ? [1, 2] : [1, 1];
    }
    /// The wall's grid: its columns, and a cell's pitch in pixels.
    function gridOf(wall) {
      const style = getComputedStyle(wall);
      const columnGap = parseFloat(style.columnGap) || 12, rowGap = parseFloat(style.rowGap) || columnGap;
      const unit = parseFloat(style.getPropertyValue("--unit")) || 176, row = parseFloat(style.gridAutoRows) || 64;
      return { columns: Math.max(1, Math.round((wall.clientWidth + columnGap) / (unit + columnGap))), x: unit + columnGap, y: row + rowGap };
    }
    const placesOf = () => layout.positions?.[layout.grouping] ?? {};
    const cells = new WeakMap();
    /// Lays out a wall whose widgets have cells of their own (or while one is dragged over it, `pin`: {node, column,
    /// row}, which goes first): each keeps its cell, moved down past a widget already there and left when the screen
    /// has fewer columns, and the others fill the first free cells in their order. Gaps stay. A wall with no cell of its
    /// own flows as the grid packs it. Answers each widget's cell.
    function arrange(wall, pin = null) {
      const places = placesOf();
      const widgets = [...wall.children].filter((child) => (child.dataset.id || child === pin?.node) && !child.classList.contains("lifted"));
      const result = new Map();
      if (!pin && !widgets.some((child) => places[child.dataset.id])) {
        for (const child of widgets) { child.style.gridColumn = ""; child.style.gridRow = ""; cells.delete(child); }
        return result;
      }
      const { columns } = gridOf(wall);
      const taken = new Set();
      const fits = (column, row, width, height) => {
        for (let x = 0; x < width; x++) for (let y = 0; y < height; y++) if (taken.has(`${column + x},${row + y}`)) return false;
        return true;
      };
      const put = (node, column, row) => {
        const [spanColumns, height] = spanOf(node), width = Math.min(spanColumns, columns);
        column = Math.max(1, Math.min(column, columns - width + 1));
        while (!fits(column, row, width, height)) row++;
        for (let x = 0; x < width; x++) for (let y = 0; y < height; y++) taken.add(`${column + x},${row + y}`);
        node.style.gridColumn = `${column} / span ${width}`;
        node.style.gridRow = `${row} / span ${height}`;
        cells.set(node, [column, row]);
        result.set(node, [column, row]);
      };
      if (pin) put(pin.node, pin.column, pin.row);
      const rest = widgets.filter((child) => child !== pin?.node && !child.classList.contains("hidden"));
      const at = (child) => places[child.dataset.id];
      for (const child of rest.filter(at).sort((a, b) => at(a)[1] - at(b)[1] || at(a)[0] - at(b)[0])) put(child, ...at(child));
      for (const child of rest.filter((one) => !at(one))) {
        const [spanColumns, height] = spanOf(child), width = Math.min(spanColumns, columns);
        let row = 1, column = 1;
        while (!fits(column, row, width, height)) { column++; if (column > columns - width + 1) { column = 1; row++; } }
        put(child, column, row);
      }
      return result;
    }
    /// Keeps the cells `arrange` gave the widgets of `wall` as theirs, so the wall stays as it is drawn.
    function keepCells(wall, placed) {
      const places = ((layout.positions ??= {})[layout.grouping] ??= {});
      for (const [node, cell] of placed) if (node.dataset.id) places[node.dataset.id] = cell;
    }
    // A wall is laid out again when its width or a widget's size changes (a large card fitted to more rows).
    let arranging = 0;
    const arrangeSoon = () => {
      cancelAnimationFrame(arranging);
      arranging = requestAnimationFrame(() => { for (const wall of content.querySelectorAll(".wall")) if (!wall.querySelector(".lifted")) arrange(wall); });
    };
    const arrangeObserver = new ResizeObserver(arrangeSoon);

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

    /// Dragging in Edit: the widget lifts and follows the pointer, a dashed slot shows the cell it would land on, free
    /// or not (the widgets there slide down out of its way); near the window's top or bottom the page scrolls. Let go,
    /// it lands there and every widget of the wall keeps its cell, gaps included. Over the middle of a widget it can
    /// join, it groups with it instead. By room, an accessory dragged into another room's
    /// wall (an administrator's) moves to that room, or out of any into No room. A finger drags at once: in Edit the
    /// widgets do not scroll the page.
    function drag(event, node) {
      if (event.button !== 0 || event.target.closest(".edit-bar, .resize-handle, .menu-button")) return;
      // A press that drags selects no text.
      event.preventDefault();
      getSelection()?.removeAllRanges();
      const origin = node.parentElement;
      let wall = origin;
      const acrossRooms = layout.grouping === "room" && isAdmin() && origin.dataset.room !== undefined && !node.classList.contains("accessory-group");
      const markRoom = (target) => {
        for (const section of content.querySelectorAll(".room-drop-target")) section.classList.remove("room-drop-target");
        if (target && target !== origin) target.closest(".accessory-section")?.classList.add("room-drop-target");
      };
      const start = { x: event.clientX, y: event.clientY };
      const grabbed = node.getBoundingClientRect();
      // Where in the widget it was taken: its top-left corner is what lands on a cell.
      const grab = { x: event.clientX - grabbed.left, y: event.clientY - grabbed.top };
      const originalStyle = node.style.cssText, originalNext = node.nextElementSibling;
      let slot = null, pointer = event, scroller = null;
      let groupTarget = null;
      const touchDrag = event.pointerType === "touch" || matchMedia("(max-width: 640px)").matches;
      const clearGroupTarget = () => {
        groupTarget?.classList.remove("group-drop-target");
        groupTarget?.removeAttribute("data-drop-label");
        groupTarget = null;
      };
      node.setPointerCapture(event.pointerId);
      const lift = () => {
        const box = node.getBoundingClientRect();
        slot = el("div", { class: `${[...node.classList].filter((name) => name.startsWith("size-")).join(" ")} widget drag-slot`, "aria-hidden": "true" });
        slot.style.setProperty("--card-rows", node.style.getPropertyValue("--card-rows"));
        node.before(slot);
        node.classList.add("lifted");
        Object.assign(node.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px` });
        scroller = setInterval(() => {
          if (groupTarget) return;
          const edge = 80, speed = 14;
          if (pointer.clientY < edge) scrollBy(0, -speed);
          else if (pointer.clientY > innerHeight - edge) scrollBy(0, speed);
          else return;
          hover();
        }, 16);
      };
      // The widget under the pointer: the slot goes before it, or after it past its middle.
      const hover = () => {
        // Ignore the lifted card and its controls when locating the actual drop target.
        const stack = document.elementsFromPoint(pointer.clientX, pointer.clientY);
        // Over another room's wall, the slot moves there.
        const overWall = acrossRooms && stack.map((element) => element.closest(".wall")).find((candidate) => candidate && candidate.dataset.room !== undefined && content.contains(candidate));
        if (overWall && overWall !== wall) {
          clearGroupTarget();
          const left = wall;
          wall = overWall;
          markRoom(wall);
          wall.append(slot);
          slide(left, () => arrange(left), node);
        }
        const under = stack
          .map((element) => element.closest(".wall > .widget"))
          .find((candidate) => candidate && candidate !== node && candidate !== slot && candidate.parentElement === wall);
        if (!under || under === slot || under.parentElement !== wall) { clearGroupTarget(); placeSlot(); return; }
        const box = under.getBoundingClientRect();
        // On compact/touch layouts leave only a narrow edge for reordering. Otherwise a
        // small tile moves away before the finger can reach its old central drop zone.
        const insetX = touchDrag ? Math.min(8, box.width * .08) : box.width * .2;
        const insetY = touchDrag ? Math.min(6, box.height * .08) : box.height * .15;
        const center = pointer.clientX > box.left + insetX && pointer.clientX < box.right - insetX && pointer.clientY > box.top + insetY && pointer.clientY < box.bottom - insetY;
        if (center && groupingControls.canJoin(node.dataset.id, under.dataset.id)) {
          if (groupTarget !== under) { clearGroupTarget(); groupTarget = under; }
          under.classList.add("group-drop-target");
          under.dataset.dropLabel = t("Release to group");
          return;
        }
        clearGroupTarget();
        placeSlot();
      };
      /// The slot on the cell under the widget's top-left corner.
      let slotCell = null;
      const roomRows = new Map();
      const placeSlot = () => {
        const grid = gridOf(wall), box = wall.getBoundingClientRect();
        // By room, the widget stays within the rows the room had when it reached it; its empty row in Edit counts only
        // while the pointer is over the room as it was then. A room that grew under the pointer would push the next one
        // away; past its old bottom it shrinks back, and the next room is under the pointer again.
        if (acrossRooms && !roomRows.has(wall)) {
          const padding = parseFloat(getComputedStyle(wall).paddingBottom) || 0;
          roomRows.set(wall, { rows: Math.max(1, Math.round((box.height - padding) / grid.y)), bottom: box.bottom + scrollY });
        }
        const entered = roomRows.get(wall);
        const column = Math.max(1, Math.round((pointer.clientX - grab.x - box.left) / grid.x) + 1);
        // Over the room, a widget may start on its empty row, however tall; past it, it ends on the room's last row.
        const lastRow = !entered ? Infinity : pointer.clientY + scrollY <= entered.bottom ? entered.rows + 1 : entered.rows - spanOf(slot)[1] + 1;
        const row = Math.max(1, Math.min(Math.round((pointer.clientY - grab.y - box.top) / grid.y) + 1, lastRow));
        if (slotCell?.[0] === column && slotCell?.[1] === row && slot.parentElement === wall) return;
        slotCell = [column, row];
        slide(wall, () => arrange(wall, { node: slot, column, row }), node);
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
      const end = (ended) => {
        node.removeEventListener("pointermove", move);
        node.removeEventListener("pointerup", end);
        node.removeEventListener("pointercancel", end);
        node.removeEventListener("lostpointercapture", end);
        clearInterval(scroller);
        if (ended.type === "pointerup" && slot) { pointer = ended; hover(); }
        const joinTarget = ended.type === "pointerup" && groupTarget ? groupTarget.dataset.id : null;
        clearGroupTarget();
        if (!slot || !slot.isConnected) return;
        markRoom(null);
        const cancelled = ended.type !== "pointerup";
        if (cancelled) {
          if (wall !== origin) { slot.remove(); arrange(wall); wall = origin; }
          if (originalNext?.parentElement === wall) originalNext.before(slot); else wall.append(slot);
        }
        // Lands in the slot from where it was let go.
        const from = node.getBoundingClientRect();
        const landed = cells.get(slot);
        slot.replaceWith(node);
        node.classList.remove("lifted");
        node.style.cssText = originalStyle;
        if (joinTarget || cancelled) arrange(wall);
        else {
          keepCells(wall, arrange(wall, landed ? { node, column: landed[0], row: landed[1] } : null));
          if (wall !== origin) arrange(origin);
        }
        const to = node.getBoundingClientRect();
        node.style.transition = "none";
        node.style.transform = `translate(${from.left - to.left}px, ${from.top - to.top}px)`;
        node.getBoundingClientRect();
        node.style.transition = reducedMotion.matches ? "none" : "transform 220ms var(--ease-out)";
        node.style.transform = "";
        // The wall's accessories take the places they had in the order, in the order they now stand.
        const ids = [...wall.children].map((child) => child.dataset.id).filter((id) => ordered.some((a) => a.id === id));
        const places = ordered.flatMap((accessory, index) => ids.includes(accessory.id) ? [index] : []);
        const byID = new Map(ordered.map((accessory) => [accessory.id, accessory]));
        ids.forEach((id, index) => { ordered[places[index]] = byID.get(id); });
        save();
        if (wall !== origin) moveToRoom(node.dataset.id, wall.dataset.room);
        else if (joinTarget) groupingControls.join(node.dataset.id, joinTarget);
      };
      node.addEventListener("pointermove", move);
      node.addEventListener("pointerup", end);
      node.addEventListener("pointercancel", end);
      node.addEventListener("lostpointercapture", end);
    }

    /// Puts an accessory dropped on another room's wall in that room ("" for none), then draws the wall again; a refusal
    /// puts it back.
    async function moveToRoom(id, room) {
      try {
        await api("/api/rooms", { method: "PUT", body: { accessories: { [id]: { room: room || null } } } });
        const accessory = all.find((candidate) => candidate.id === id);
        if (accessory) accessory.room = room || null;
      } catch (e) { HomeswiftCommon.showAlert(e.message); }
      render();
    }

    const content = el("div", { class: "accessory-walls" });
    const none = el("p", { class: "muted hidden", text: t("No accessory matches.") });
    async function saveRoomOrder(order) {
      try {
        await api("/api/rooms", { method: "PUT", body: { rooms: order } });
        rooms.splice(0, rooms.length, ...order);
        note.classList.add("hidden");
        render();
      } catch (e) {
        note.textContent = t("The layout was not kept: {error}", { error: e.message });
        note.classList.remove("hidden");
      }
      return [...rooms];
    }
    // Whether a room renamed here is renamed on the plugins' hubs too (off unless turned on).
    let syncRoomNames = home.syncRoomNames === true;
    async function renameRoom(name) {
      const answer = await HomeswiftCommon.promptDialog(t("A new name for {room}.", { room: name })
        + (syncRoomNames ? `\n\n${t("Rooms of this name on your Philips Hue, IKEA and eWeLink hubs are renamed too.")}` : ""), name);
      await applyRoomName(name, answer);
    }
    /// Renames a room (to the trimmed `answer`, unless empty or unchanged); answers whether it was.
    async function applyRoomName(name, answer) {
      const to = answer?.trim();
      if (!to || to === name) return false;
      try {
        const result = await api("/api/rooms", { method: "PUT", body: { renameRoom: { from: name, to } } });
        const failed = (result.hubRooms || []).filter((room) => !room.renamed);
        if (failed.length) HomeswiftCommon.showAlert(failed.map((room) => t("Not renamed on {hub}: {error}", { hub: room.name, error: room.error })).join("\n"));
        // Drawn again here rather than reloaded, so Edit stays on for the next room.
        rooms.splice(0, rooms.length, ...result.rooms.map((room) => room.name));
        for (const accessory of all) if (accessory.room === name) accessory.room = to;
        render();
        return true;
      } catch (e) { HomeswiftCommon.showAlert(e.message); return false; }
    }
    /// A room's heading in Edit: its name as a field, renamed on Enter or when it loses focus; Escape puts it back.
    function roomNameField(name) {
      const input = el("input", { type: "text", class: "room-name-input", value: name, maxLength: 64, spellcheck: false, autocomplete: "off",
        "aria-label": t("Name of {room}", { room: name }), title: t("Rename the room") });
      // As wide as its text, measured in the field's font (field-sizing leaves the padding out in Chromium).
      const fit = () => {
        if (!input.isConnected) return;
        const style = getComputedStyle(input);
        const context = (fit.canvas ??= document.createElement("canvas")).getContext("2d");
        context.font = style.font;
        const chrome = ["paddingLeft", "paddingRight", "borderLeftWidth", "borderRightWidth"].reduce((sum, key) => sum + parseFloat(style[key]), 0);
        input.style.width = `${Math.ceil(context.measureText(input.value || " ").width + chrome) + 2}px`;
      };
      requestAnimationFrame(fit);
      input.addEventListener("input", fit);
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") { event.preventDefault(); input.blur(); }
        if (event.key === "Escape") { input.value = name; fit(); input.blur(); }
      });
      input.addEventListener("change", async () => {
        input.disabled = true;
        if (!await applyRoomName(name, input.value)) { input.value = name; fit(); input.disabled = false; }
      });
      return el("h2", {}, input);
    }
    const roomOrderButton = el("button", { type: "button", class: "hidden", "aria-label": t("Rooms"), "aria-haspopup": "menu",
      onclick: (event) => HomeswiftCommon.menu(roomOrderButton, [
        { heading: t("Rooms"), detail: t("Drag to reorder, choose one to rename it.") },
        ...rooms.map((name) => ({ key: name, label: name, icon: "room", onSelect: () => renameRoom(name) })),
        { separator: true },
        { label: t("Reset room order"), icon: "restore", disabled: () => rooms.every((name, index) => index === 0 || rooms[index - 1].localeCompare(name, HomeswiftI18n.locale) <= 0), onSelect: () => saveRoomOrder([...rooms].sort((a, b) => a.localeCompare(b, HomeswiftI18n.locale))) },
        { label: t("Rename on the hubs too"), icon: "bridge", checked: syncRoomNames, checkbox: true, toggle: true, keepOpen: true, onSelect: async () => {
          try {
            syncRoomNames = (await api("/api/rooms", { method: "PUT", body: { syncRoomNames: !syncRoomNames } })).syncRoomNames === true;
          } catch (e) { HomeswiftCommon.showAlert(e.message); }
          return syncRoomNames;
        } },
      ], { keyboard: event.detail === 0, onReorder: saveRoomOrder }) }, HomeswiftCommon.icon("room"), el("span", { text: t("Rooms") }));

    function render() {
      if (fullScreen) editing = false;
      roomOrderButton.classList.toggle("hidden", !editing || !isAdmin() || layout.grouping !== "room" || !rooms.length);
      nodes.clear();
      // By plugin or by room: a section each (by plugin in the order of their names, those of no plugin last; by room
      // in the rooms' order, those in none last); else one wall.
      let sections = layout.grouping === "plugin" ? groupByPlugin(accessories)
        : layout.grouping === "room" && rooms.length ? HomeswiftHome.groupByRoom(accessories, rooms) : null;
      const byRoom = layout.grouping === "room" && rooms.length;
      // In Edit, every room has its wall, empty ones too, and so has No room: places to drop an accessory.
      if (byRoom && editing && isAdmin()) {
        const found = new Map(sections);
        const rest = sections.find(([name]) => !rooms.includes(name))?.[1] ?? [];
        sections = [...rooms.map((room) => [room, found.get(room) ?? []]), [t("No room"), rest]];
      }
      const groups = sections ? sections.map(([name, group]) => [name, ordered.filter((accessory) => group.includes(accessory))]) : [["", ordered]];
      const memberIDs = new Set(layout.groups.flatMap((g) => g.members));
      content.replaceChildren(...groups.map(([name, group]) => el("section", { class: "accessory-section" },
        name ? el("div", { class: "section-head" }, editing && isAdmin() && layout.grouping === "room" && rooms.includes(name) ? roomNameField(name) : el("h2", { text: name }), el("span", { class: "muted", text: tn("{n} accessory", "{n} accessories", group.length) })) : null,
        el("div", { class: `wall${editing ? " editing" : ""}`, "data-room": byRoom ? (rooms.includes(name) ? name : "") : null }, group.filter((a) => !memberIDs.has(a.id) || noResponse).map(widget)))));
      if (!noResponse) {
        const walls = [...content.querySelectorAll(".wall")];
        const cardsBySection = groups.map(() => []);
        for (const group of layout.groups) {
          const index = HomeswiftGroups.sectionIndex(group, groups);
          if (index !== -1) cardsBySection[index].push(widget(group));
        }
        // Keep each group beside its members, including rooms other than the first one.
        walls.forEach((wall, index) => wall.prepend(...cardsBySection[index]));
      }
      const widgetRank = new Map(layout.order.map((id, index) => [id, index]));
      arrangeObserver.disconnect();
      for (const wall of content.querySelectorAll(".wall")) {
        const children = [...wall.children];
        const rankOf = (node) => widgetRank.get(node.dataset.id) ?? (node.classList.contains("accessory-group") ? -1 : layout.order.length + children.indexOf(node));
        wall.append(...[...children].sort((a, b) => rankOf(a) - rankOf(b)));
        arrange(wall);
        arrangeObserver.observe(wall);
        for (const child of wall.children) arrangeObserver.observe(child);
      }
      filter();
      if (fullScreen) fullScreenChrome();
    }

    const search = el("input", { type: "search", class: "search", placeholder: t("Search accessories"), "aria-label": t("Search accessories") });
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
        // An empty room stays in Edit, by room, to take a drop, unless a search is on.
        section.classList.toggle("hidden", inSection === 0 && !(!text && section.querySelector(".wall.editing[data-room]")));
        shown += inSection;
      }
      none.classList.toggle("hidden", shown > 0);
    }
    search.addEventListener("input", filter);
    const groupings = [["none", t("One wall"), "wall"], ...(rooms.length ? [["room", t("By room"), "room"]] : []), ["plugin", t("By plugin"), "plugin"]];
    const setGrouping = (value) => { layout.grouping = value; save(); render(); };
    const edit = el("button", { actionIcon: "sliders", type: "button", text: t("Edit"), "aria-pressed": "false", title: t("Sizes and order of the widgets"), onclick: () => {
      editing = !editing;
      edit.textContent = editing ? t("Done") : t("Edit");
      edit.classList.toggle("primary", editing);
      edit.setAttribute("aria-pressed", String(editing));
      render();
    } });

    const canSuggest = isAdmin() && window.HomeswiftChat?.available() && all.length;

    const changeFilter = (key, value, enabled) => {
      const next = new URLSearchParams(location.search);
      if (enabled) next.set(key, value); else next.delete(key);
      navigate(`/accessories${next.size ? `?${next}` : ""}`, { replace: true });
    };
    const searchCount = (predicate) => all.filter((accessory) => predicate(accessory) && HomeswiftWidgets.searchText(accessory).includes(search.value.trim().toLowerCase())).length;
    const activeFilters = Number(Boolean(from)) + Number(showHidden) + Number(noResponse);
    const filters = el("button", { type: "button", class: activeFilters ? "on" : "", "aria-haspopup": "menu" },
      HomeswiftCommon.icon("sliders"), el("span", { text: t("Filters") }), activeFilters ? el("span", { class: "toolbar-count", text: activeFilters }) : null);
    filters.addEventListener("click", () => HomeswiftCommon.menu(filters, [
      ...sources.map((source) => ({ label: t("Only from {source}", { source: t(source) }), count: searchCount((accessory) => accessory.mirroredFrom === source), checked: from === source, checkbox: true, toggle: true,
        icon: source === "Apple Home" ? el("img", { src: "/apple-home.png", width: 20, height: 20, alt: "" }) : null,
        onSelect: () => changeFilter("from", source, from !== source) })),
      { label: t("No Response"), icon: "warning", tone: "error", count: searchCount((accessory) => accessory.unavailable || accessory.paused), checked: noResponse, checkbox: true, toggle: true, onSelect: () => changeFilter("unavailable", "1", !noResponse) },
      ...(hiddenCount ? [{ label: t("Show hidden"), count: searchCount((accessory) => accessory.hidden), icon: "eye", tone: "warn", checked: showHidden, checkbox: true, toggle: true, onSelect: () => changeFilter("hidden", "1", !showHidden) }] : []),
      { separator: true },
      { label: t("Clear filters"), clearFilters: true, icon: "restore", disabled: !search.value && activeFilters === 0, onSelect: () => {
        search.value = "";
        if (activeFilters) {
          const next = new URLSearchParams(location.search);
          for (const key of ["from", "hidden", "unavailable"]) next.delete(key);
          navigate(`/accessories${next.size ? `?${next}` : ""}`, { replace: true });
        } else filter();
      } },
    ]));
    const more = menuButton(t("Accessory options"), () => [
      { label: t("Create group"), icon: "group", onSelect: () => groupingControls.edit() },
      { separator: true },
      ...groupings.map(([value, label, icon]) => ({ label, icon, checked: layout.grouping === value, onSelect: () => setGrouping(value) })),
      // Widgets dropped on cells of their own: back to packing in the order.
      ...(isAdmin() && Object.keys(placesOf()).length ? [{ separator: true }, { label: t("Pack the widgets together"), icon: "grid", onSelect: () => {
        delete layout.positions[layout.grouping];
        save();
        render();
      } }] : []),
      ...(canSuggest ? [{ separator: true }, { label: t("Suggest rooms"), icon: "sparkle", onSelect: () => HomeswiftHome.suggestRooms(content, all) }] : [])
    ]);
    more.replaceChildren(HomeswiftCommon.icon("sliders"));
    more.classList.add("accessory-options-button");

    // Full screen: the address says it, so a reload or a tablet's bookmark keeps it; the browser's own full screen too
    // where it has one (not an iPhone), asked from the click, which it needs.
    const setFullScreen = (on) => {
      const next = new URLSearchParams(location.search);
      if (on) next.set("full", "1"); else next.delete("full");
      if (on) document.documentElement.requestFullscreen?.().catch(() => {});
      else if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      navigate(`/accessories${next.size ? `?${next}` : ""}`, { replace: true });
    };
    const fullScreenButton = el("button", { type: "button", class: "icon-button accessory-options-button", "aria-label": t("Full screen"), title: t("Full screen"),
      onclick: () => setFullScreen(true) }, HomeswiftCommon.icon("expand"));
    // The chrome over the full-screen wall: Close, and when grouped the dots and, with a mouse, the side arrows.
    const chrome = el("div", { class: "wall-full-chrome" });
    let page = 0;
    function fullScreenChrome() {
      const pages = [...content.children].filter((section) => !section.classList.contains("hidden"));
      const paged = layout.grouping !== "none" && pages.length > 1;
      content.classList.toggle("wall-pages", paged);
      document.documentElement.classList.add("wall-full");
      document.documentElement.classList.toggle("wall-paged", paged);
      page = Math.min(page, Math.max(0, pages.length - 1));
      const go = (index) => {
        page = Math.max(0, Math.min(pages.length - 1, index));
        content.scrollTo({ left: page * content.clientWidth });
      };
      const dots = pages.map((section, index) => el("button", { type: "button", "aria-label": section.querySelector("h2")?.textContent || t("Page {n}", { n: index + 1 }),
        onclick: () => go(index) }));
      const previous = el("button", { type: "button", class: "wall-step previous", "aria-label": t("Previous"), onclick: () => go(page - 1) }, HomeswiftCommon.icon("back"));
      const next = el("button", { type: "button", class: "wall-step next", "aria-label": t("Next"), onclick: () => go(page + 1) }, HomeswiftCommon.icon("forward"));
      const mark = () => {
        dots.forEach((dot, index) => dot.setAttribute("aria-current", String(index === page)));
        previous.disabled = page === 0;
        next.disabled = page === pages.length - 1;
      };
      content.onscroll = paged ? () => {
        const now = Math.round(content.scrollLeft / Math.max(1, content.clientWidth));
        if (now !== page) { page = now; mark(); }
      } : null;
      chrome.replaceChildren(optionsButton,
        ...(paged ? [previous, next, el("div", { class: "wall-dots", role: "group", "aria-label": t("Pages") }, dots)] : []));
      mark();
      if (paged) requestAnimationFrame(() => content.scrollTo({ left: page * content.clientWidth, behavior: "instant" }));
      wake();
      chrome.go = go;
    }
    // The toolbar, out of the way: a panel from the right edge (the bottom on a phone) with the search, the grouping, the
    // filters and Leave full screen, opened by the one button left on the wall.
    const openToolbar = () => openSheet((done) => el("div", { class: "wall-full-panel" },
      el("h2", { id: "wall-full-panel-title", text: t("Accessories") }),
      search,
      el("div", { class: "wall-full-groupings", role: "group", "aria-label": t("Group the widgets") }, groupings.map(([value, label, icon]) =>
        el("button", { type: "button", actionIcon: icon, class: layout.grouping === value ? "primary" : "", "aria-pressed": String(layout.grouping === value), text: label,
          onclick: () => { page = 0; setGrouping(value); done(); } }))),
      filters,
      el("div", { class: "actions" },
        el("button", { type: "button", actionIcon: "close", text: t("Leave full screen"), onclick: () => { done(); setFullScreen(false); } }),
        el("button", { type: "button", actionIcon: "check", class: "primary", text: t("Done"), onclick: () => done() }))),
    "wall-full-panel-title", { returnFocus: optionsButton });
    const optionsButton = el("button", { type: "button", class: "wall-full-button wall-full-options", "aria-label": t("Accessory options"), "aria-haspopup": "dialog",
      title: t("Accessory options"), onclick: openToolbar }, HomeswiftCommon.icon("sliders"));
    // A search from the panel changes which pages there are.
    search.addEventListener("input", () => { if (fullScreen) fullScreenChrome(); });
    // The chrome wakes on a touch, the mouse or a key, and fades after a few quiet seconds.
    let sleepTimer = null;
    const wake = () => {
      document.documentElement.classList.add("wall-awake");
      clearTimeout(sleepTimer);
      sleepTimer = setTimeout(() => document.documentElement.classList.remove("wall-awake"), 3000);
    };
    if (fullScreen) {
      // Listeners on the window for this view only: each goes once the view has gone.
      const gone = () => !content.isConnected;
      const onKey = (event) => {
        if (gone()) { removeEventListener("keydown", onKey); return; }
        wake();
        // A menu or a sheet open has the keys.
        if (document.querySelector("dialog[open], .menu:not(.closing)") || event.target.closest?.("input, textarea, select")) return;
        if (event.key === "Escape") { event.preventDefault(); setFullScreen(false); }
        else if (event.key === "ArrowRight") { event.preventDefault(); chrome.go?.(page + 1); }
        else if (event.key === "ArrowLeft") { event.preventDefault(); chrome.go?.(page - 1); }
      };
      const onPointer = () => { if (gone()) { removeEventListener("pointermove", onPointer); removeEventListener("pointerdown", onPointer); return; } wake(); };
      // The browser's full screen left with its own Esc: the wall leaves too.
      const onFullScreen = () => {
        if (gone()) { document.removeEventListener("fullscreenchange", onFullScreen); return; }
        if (!document.fullscreenElement) setFullScreen(false);
      };
      addEventListener("keydown", onKey);
      addEventListener("pointermove", onPointer, { passive: true });
      addEventListener("pointerdown", onPointer, { passive: true });
      if (document.fullscreenElement) document.addEventListener("fullscreenchange", onFullScreen);
      // Pages follow the window's width (a tablet turned).
      const onResize = () => { if (gone()) { removeEventListener("resize", onResize); return; } if (content.classList.contains("wall-pages")) content.scrollTo({ left: page * content.clientWidth, behavior: "instant" }); };
      addEventListener("resize", onResize);
    }
    render();
    show(main,
      pageHead(t("Accessories"), !accessories.length ? "" : from ? t("{count} from {source}, which HomeKit has already. Changes here reach your devices.", { count: accessories.length, source: t(from) })
        : servers === 1 ? t("{count} on one server, as the Home app sees them. Changes here reach your devices.", { count: accessories.length })
        : t("{count} on {servers} servers, as the Home app sees them. Changes here reach your devices.", { count: accessories.length, servers }),
        el("div", { class: "accessories-toolbar" }, search, filters, accessories.length ? edit : null, roomOrderButton, more, accessories.length ? fullScreenButton : null)),
      accessoryTabs(""),
      note,
      accessories.length ? [content, none, fullScreen ? chrome : null] : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("bulb")), el("p", { class: "muted", text: all.length ? t("Every accessory is hidden.") : t("No accessories yet. Plugins add them once they reach their devices.") })));
  };

  /// Accessories by plugin: [name, accessories] pairs by the plugin's name, each list by name; those of no
  /// plugin last, as "Other accessories".
  function groupByPlugin(accessories) {
    const groups = Map.groupBy([...accessories].sort((a, b) => a.name.localeCompare(b.name)), (accessory) => accessory.platformName ?? "");
    return [...groups].sort(([a], [b]) => !a - !b || a.localeCompare(b)).map(([name, list]) => [name || t("Other accessories"), list]);
  }

  function applyAccessoryEvent(event) {
    window.HomeswiftCamera?.event(event);
    HomeswiftWidgets.event(event);
    if (location.pathname === "/accessories") window.homeswiftGroupEvent?.(event);
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
      // Under the name, what it is when the name does not say it already ("Daikin Cloud" says DaikinCloud): the plugin,
      // else its platform.
      const bare = (name) => name.replace(/[\s_-]+/g, "").toLowerCase();
      const kindName = [plugin?.name, block.platform].find((name) => name && bare(name) !== bare(block.name));
      return el("div", { class: "card server plugin-instance" },
        el("div", { class: "server-head" },
          tile(block.icon ?? (block.system ? "gear" : "plugin"), block.system ? "grey" : "orange"),
          el("div", { class: "who" }, el("a", { class: "card-title", href: opens }, el("strong", { text: blockTitle(block) })),
            el("div", { class: "muted", text: [kindName, block.childBridge ? t("child bridge") : null].filter(Boolean).join(" · ") })),
          // In this dense list, running is the usual state: a quiet dot; the others (paused, no plugin, built in) say so
          // in words, as the plugin's own page and the bridges do for every state.
          kind === "on" ? el("span", { class: "status-dot", role: "img", "aria-label": state, title: state }) : el("span", { class: `pill status ${kind}`, text: state })),
        // Its accessories and the bridge they are on, a glyph each, on one line.
        instance ? el("div", { class: "meta" },
          el("span", { title: t("Accessories") }, HomeswiftCommon.icon("bulb"), tn("{n} accessory", "{n} accessories", instance.accessories)),
          el("span", { title: t("On the bridge {name}", { name: instance.bridge }) }, HomeswiftCommon.icon(block.childBridge ? "child" : "bridge"), instance.bridge)) : null,
        el("div", { class: "card-foot" },
          el("span", { class: "muted", text: instance?.paused ? t("No calls to its devices; they show No Response in the Home app.")
            : instance ? "" : block.system ? t("A block of the runtime itself.") : plugin ? t("It did not start: the log says why.") : t("No plugin compiled into this homeswift provides this platform.") }),
          el("div", { class: "plugin-card-actions" }, el("a", { class: "button", href: opens, actionIcon: plugin?.hasPages && instance && !instance.paused ? "open" : "gear", text: plugin?.hasPages && instance && !instance.paused ? t("Open its page") : t("Settings") }), menuButton(t("Actions for {name}", { name: blockTitle(block) }), () => blockActions(block, plugin, instance)))));
    };

    /// What the menu of a plugin's card offers: its page, the block as a form or as JSON (Expert), pause or
    /// resume, and removal.
    function blockActions(block, plugin, instance) {
      if (block.system) return [{ label: t("Settings"), icon: "gear", href: settingsLink(block) }, { label: t("Edit as JSON"), icon: "code", href: expertLink(block, "json") }];
      const toggle = async (paused) => {
        try { await setPaused(block.platform, block.name, paused); route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
      };
      return [
        plugin && plugin.hasPages && instance && !instance.paused ? { label: t("Open its page"), icon: "open", href: pluginPage(block) } : null,
        { label: t("Edit settings (Expert)"), icon: "edit", href: expertLink(block) },
        { label: t("Edit as JSON (Expert)"), icon: "code", href: expertLink(block, "json") },
        instance && !instance.paused ? { label: t("Pause"), icon: "pause", onSelect: () => toggle(true) } : null,
        instance?.paused ? { label: t("Resume"), icon: "play", onSelect: () => toggle(false) } : null,
        { label: t("Remove"), icon: "trash", danger: true, onSelect: () => removeBlock(block) },
      ];
    }

    // The plugins compiled in, each a card with what the search and the orders read.
    const catalogEntries = plugins.plugins.map((plugin) => {
      const used = plugins.blocks.some((block) => block.platform === plugin.platform);
      const card = el("div", { class: "card server catalog" },
        el("div", { class: "server-head" }, tile(plugin.icon ?? "plugin", "orange"),
          // Under its name, what it brings (`HomeswiftPlugin.summary`, in the catalogs).
          el("div", { class: "who" }, el("strong", { text: plugin.name }), plugin.summary ? el("div", { class: "muted", text: t(plugin.summary) }) : null),
          used ? el("span", { class: "pill status standby", text: t("In use [used]") }) : null),
        el("div", { class: "actions" }, plugin.hasPages
          // A plugin with its own page sets itself up there (pairing a TV, finding lights), as Homebridge's
          // custom UIs do: Add writes an empty block and opens the page. Plain buttons: a list of them, all orange,
          // would leave the page no primary action.
          ? el("button", { actionIcon: "plus", text: used ? t("Add another") : t("Add"), onclick: (event) => addWithPage(plugin, event.currentTarget) })
          : el("a", { class: "button", actionIcon: "plus", href: `/plugins/add/${encodeURIComponent(plugin.platform)}`, text: used ? t("Add another") : t("Add") })));
      return { card, name: plugin.name, text: [plugin.name, plugin.platform, plugin.summary, plugin.summary && t(plugin.summary)].filter(Boolean).join(" "), used };
    });

    async function addWithPage(plugin, button) {
      button.disabled = true;
      const block = { platform: plugin.platform, name: uniqueName(plugin.name, plugins.blocks) };
      try {
        await api(`/api/config/block/${encodeURIComponent(block.platform)}/${encodeURIComponent(block.name)}`, { method: "POST", body: {} });
        location.href = pluginPage({ slug: slug(block.name) });
      } catch (e) {
        button.disabled = false;
        HomeswiftCommon.showAlert(e.message);
      }
    }

    // Your plugins: by name, those that need a look first (no plugin, not running, paused), or by their accessories.
    const blocks = plugins.blocks.map((block) => {
      const plugin = byPlatform.get(block.platform), instance = running(block);
      const attention = { away: 0, paused: 1, on: 2, standby: 3 }[blockState(block, plugin, instance)[1]];
      return { card: blockCard(block), name: block.name, attention, accessories: instance?.accessories ?? -1,
        text: [block.name, block.platform, plugin?.name, instance?.bridge].filter(Boolean).join(" ") };
    });
    const installed = finder({ grid: el("div", { class: "grid plugin-instances" }), entries: blocks, param: "order",
      orders: [["name", t("Name A–Z"), () => 0], ["attention", t("Needs attention first"), (a, b) => a.attention - b.attention],
        ["accessories", t("Most accessories"), (a, b) => b.accessories - a.accessories]],
      placeholder: t("Search your plugins"), sortLabel: t("Sort your plugins"), empty: t("No plugin of yours matches the search."),
      counted: (shown, total) => t("{shown} of {total} plugins", { shown, total }) });
    const available = finder({ grid: el("div", { class: "grid plugin-catalog" }), param: "sort", entries: catalogEntries,
      orders: [["name", t("Name A–Z"), () => 0], ["used", t("In use first"), (a, b) => Number(b.used) - Number(a.used)],
        ["available", t("Available first"), (a, b) => Number(a.used) - Number(b.used)]],
      placeholder: t("Search plugins"), sortLabel: t("Sort plugins"), empty: t("No plugin matches the search."),
      counted: (shown, total) => t("{shown} of {total} plugins", { shown, total }) });
    show(main,
      pageHead(t("Plugins"), t("The blocks of config.json. A save applies at once: the plugin reloads with its accessories kept.")),
      // Blocks no plugin here runs, by the names the cards show (Homebridge's own blocks, from an imported config).
      plugins.unknownPlatforms.length ? el("div", { class: "card notice" }, el("p", { text: t("{names}: no plugin compiled into this homeswift runs these blocks, so they are ignored.",
        { names: plugins.blocks.filter((block) => plugins.unknownPlatforms.includes(block.platform)).map((block) => block.name).join(", ") }) })) : null,
      plugins.blocks.some((block) => !block.system) ? [el("div", { class: "section-head" }, el("h2", { text: t("Your plugins") }),
        el("span", { class: "muted", text: tn("{n} block in config.json", "{n} blocks in config.json", plugins.blocks.length) })), ...installed] : window.HomeswiftImport.offer(),
      el("div", { class: "section-head" }, el("h2", { text: t("Add a plugin") }), el("span", { class: "muted", text: t("compiled into this homeswift") })),
      ...available);
  };

  /// A block's state pill: its label and tone.
  /// A block as the pages name it: a built-in block still under its platform's name reads as words ("HomeswiftMatter" is
  /// Homeswift Matter); any other, its own name.
  const builtInTitles = { HomeswiftUI: "Homeswift UI", HomeswiftMatter: "Homeswift Matter" };
  const blockTitle = (block) => (block.name === block.platform && builtInTitles[block.platform]) || block.name;
  const blockState = (block, plugin, instance) => block.system ? [t("Built in"), "standby"] : instance?.paused ? [t("Paused"), "paused"]
    : instance ? [t("Running"), "on"] : plugin ? [t("Not running"), "away"] : [t("No plugin"), "away"];

  /// Takes a block out of config.json, after asking: its accessories leave the Home app.
  async function removeBlock(block, after = () => route()) {
    if (!await HomeswiftCommon.confirmDialog(t("Remove \"{name}\" from config.json? Its accessories leave the Home app.", { name: block.name }))) return;
    try { await api(`/api/config/platforms/${block.index}`, { method: "DELETE" }); leaveGuard = null; after(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
  }

  /// A block's address: its plugin's own page when it has one, else its settings. `expertLink` is always the form
  /// (or the JSON), the whole block as config.json keeps it.
  const settingsLink = (block) => `/plugins/${block.slug}`;
  const pluginPage = settingsLink;
  const expertLink = (block, mode = "form") => `${settingsLink(block)}/expert${mode === "json" ? "/json" : ""}`;

  /// Where a page sits, each level a way back; the last is the page itself.
  function breadcrumb(...levels) {
    return el("nav", { class: "breadcrumb", "aria-label": t("Breadcrumb") }, el("ol", {}, levels.map(([text, href], i) =>
      i === levels.length - 1 ? el("li", { "aria-current": "page" }, el("span", { text })) : el("li", {}, el("a", { href, text })))));
  }

  // ---- A plugin's settings: its own page ------------------------------------
  // /plugins/<slug> for a block of config.json, /plugins/add/<platform> to add one. A running plugin with its own
  // page shows that page there: the form is its Expert part, at /plugins/<slug>/expert (or /expert/json). The form comes from the plugin's config.schema.json (or the runtime's own for the web UI's block),
  // JSON otherwise; the save bar stays in view, and leaving with unsaved changes asks first.

  views.settings = async (main, [first, second, third]) => {
    const isNew = first === "add";
    const [plugins, config] = await Promise.all([api("/api/plugins"), api("/api/config", { raw: true }).then(JSON.parse)]);
    // A bridge that does not send the rule (an older build) leaves the note off, rather than failing the page.
    secretRule = readSecretRule(plugins);
    const found = isNew ? null : plugins.blocks.find((b) => b.slug === first);
    if (!isNew && !found) {
      show(main, breadcrumb([t("Plugins"), "/plugins"], [t("Settings")]),
        el("div", { class: "card empty" }, el("p", { class: "muted", text: t("No plugin at /plugins/{slug} in config.json.", { slug: first }) })));
      return;
    }
    const platform = isNew ? second : found.platform;
    const plugin = plugins.plugins.find((p) => p.platform === platform);
    const view = isNew ? null : second === "expert" ? (third === "json" ? "json" : "form") : null;
    if (isNew && !plugin) throw new Error(t("No plugin provides {platform}.", { platform }));
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
    if (platform === "HomeswiftUI" && schema) {
      const advanced = (schema.layout || []).filter((item) => typeof item === "object").map((item) => {
        // `?section=proxy` and `?section=schedules` open these (admin.js links to the first).
        const section = item.title === "Schedules" ? "schedules" : (item.items || []).includes("trustProxy") ? "proxy" : undefined;
        return { ...item, section, icon: section === "schedules" ? "history" : "system" };
      });
      schema.layout = [
        { type: "fieldset", title: t("Connection"), icon: "system", items: ["port", "host", "allowedHosts"] },
        { type: "fieldset", title: t("Sign-in"), icon: "user", items: ["auth", "sessionDays"] },
        { type: "fieldset", title: "HTTPS", icon: "lock", expandable: true, expanded: Boolean(current.https), items: ["https", { items: ["certificate", "privateKey"] }] },
        { type: "fieldset", title: t("Updates"), section: "updates", icon: "download", expandable: true, expanded: false, items: ["checkForUpdates"] },
        ...advanced
      ];
    }
    let getValue;
    let body;
    let useSuggestion = null;
    const textarea = el("textarea", { class: "short", value: JSON.stringify(current, null, 2), spellcheck: false, "aria-label": t("The block as JSON") });
    const editor = jsonEditor(textarea, { secretKey: isSecretKey });
    const fromJSON = () => { const value = JSON.parse(textarea.value); delete value.platform; return value; };
    // The same key names the server seals (Redaction's rule). A secret typed in JSON is encrypted on save, so the note
    // says where it is easier to set one; it shows only while the JSON on screen holds a secret.
    // The server's rule (Redaction): the page reads it from /api/plugins, set when the settings page loads them.
    const holdsSecret = (value, underSecret = false) => {
      if (typeof value === "string") return underSecret && value !== "" && value !== secretRule?.placeholder;
      if (Array.isArray(value)) return value.some((item) => holdsSecret(item, underSecret));
      if (value && typeof value === "object") return Object.entries(value).some(([key, child]) => holdsSecret(child, underSecret || isSecretKey(key, child)));
      return false;
    };
    const secretNote = el("p", { class: "secret-note", role: "note", text: t("A secret set in JSON is encrypted in config.json when you save. Set it in Form or on the plugin's own page, where it is easier to get right.") });
    secretNote.hidden = true;
    if (schema) {
      // The form first; the block as JSON one tap away, for what the form does not show. Each view starts
      // from the other's value, and Save takes the one on screen.
      let mode = view === "json" ? "json" : "form";
      let form = buildForm(schema, current);
      const formView = el("div", { class: mode === "form" ? "" : "hidden" }, form.element);
      const jsonView = el("div", { class: mode === "json" ? "" : "hidden" }, el("p", { class: "muted", text: t("The block as config.json keeps it.") }), secretNote, editor);
      const switchError = el("p", { class: "error" });
      const tabs = el("div", { class: "group view-switch", role: "tablist", "aria-label": t("Edit as") },
        [["form", t("Form")], ["json", "JSON"]].map(([value, text]) => el("button", { type: "button", role: "tab", "data-mode": value, class: value === mode ? "on" : "", "aria-selected": String(value === mode), onclick: () => {
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
          } catch (e) { switchError.textContent = t("The JSON is not valid: {error}", { error: e.message }); return; }
          mode = value;
          formView.classList.toggle("hidden", mode !== "form");
          jsonView.classList.toggle("hidden", mode !== "json");
          for (const tab of tabs.children) { tab.classList.toggle("on", tab.dataset.mode === mode); tab.setAttribute("aria-selected", String(tab.dataset.mode === mode)); }
        } }, HomeswiftCommon.icon(value === "form" ? "sliders" : "code"), el("span", { text }))));
      body = el("div", { class: "card form-card" }, tabs, switchError, formView, jsonView);
      if (platform === "HomeswiftUI") body.classList.add("local-ui-settings");
      getValue = () => (mode === "form" ? form.getValue() : fromJSON());
      // The Assistant's suggestion goes into the view on screen, as unsaved changes to review and save.
      useSuggestion = (value) => {
        const next = { ...value, platform };
        if (mode === "form") { form = buildForm(schema, next); formView.replaceChildren(form.element); }
        else { textarea.value = JSON.stringify(next, null, 2); editor.repaint(); }
        body.dispatchEvent(new Event("input", { bubbles: true }));
      };
    } else {
      body = el("div", { class: "card form-card" }, el("p", { class: "muted", text: t("This block has no settings form; edit it as JSON.") }), secretNote, editor);
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
    const save = el("button", { class: "primary settings-action" }, HomeswiftCommon.icon("check"), el("span", { text: isNew ? t("Add") : t("Save") }));
    const force = el("button", { class: "hidden", text: isNew ? t("Add anyway") : t("Save anyway"), title: t("Save what the plugin's schema refuses: for a value the plugin accepts that its schema does not list") });
    const revert = el("button", { class: "settings-action" }, HomeswiftCommon.icon("restore"), el("span", { text: isNew ? t("Cancel") : t("Revert") }));
    // The JSON on screen is checked as it is typed: a syntax error marks its line, and Save waits for it.
    const jsonShown = () => textarea.isConnected && !textarea.closest(".hidden");
    const update = () => {
      const result = jsonShown() ? editor.check() : null;
      secretNote.hidden = !(result && "value" in result && holdsSecret(result.value));
      if (result && !("value" in result)) {
        message.className = "error";
        message.replaceChildren(...lineLink(result, editor), result.message);
        save.disabled = true;
        revert.disabled = false;
        return;
      }
      const changed = dirty();
      save.disabled = !isNew && !changed;
      revert.disabled = !isNew && !changed;
      if (!message.classList.contains("error") && !message.classList.contains("ok")) {
        message.className = changed ? "dirty" : "muted";
        message.textContent = isNew ? t("A new block: Add writes it to config.json.") : changed ? t("Unsaved changes") : t("Saved");
      }
    };
    body.addEventListener("input", () => { message.className = ""; force.classList.add("hidden"); update(); });
    body.addEventListener("change", () => { message.className = ""; update(); });
    body.addEventListener("click", () => setTimeout(update, 0));   // the array editors add and remove rows by click

    const portNotice = el("p", { class: "muted", role: "status", "aria-live": "polite" });
    let portCheckVersion = 0;
    let portCheckTimer;
    const checkPort = async (value) => {
      const port = Number(value.port ?? 8581);
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(t("Choose a port between 1 and 65535."));
      const result = await api("/api/config/check-port", { method: "POST", body: { port, host: value.host || "0.0.0.0" } });
      if (!result.available) throw new Error(t("Port {port} is in use or cannot be opened on this address. Choose another port.", { port: String(port) }));
      return t("Port {port} is available.", { port: String(port) });
    };
    if (platform === "HomeswiftUI") {
      body.append(portNotice);
      let previousBinding = JSON.stringify([current.host, current.port]);
      body.addEventListener("input", () => {
        let value; try { value = getValue(); } catch { return; }
        const binding = JSON.stringify([value.host, value.port]);
        if (binding === previousBinding) return;
        previousBinding = binding;
        const version = ++portCheckVersion;
        clearTimeout(portCheckTimer);
        portNotice.className = "muted";
        portNotice.textContent = t("Checking port…");
        portCheckTimer = setTimeout(async () => {
          try {
            const text = await checkPort(value);
            if (version === portCheckVersion) { portNotice.className = "ok"; portNotice.textContent = text; }
          } catch (error) {
            if (version === portCheckVersion) { portNotice.className = "error"; portNotice.textContent = error.message; }
          }
        }, 400);
      });
    }

    const doSave = async (anyway) => {
      save.disabled = true;
      force.classList.add("hidden");
      message.className = "muted";
      message.textContent = t("Saving…");
      try {
        const value = getValue();
        value.platform = platform;
        if (platform === "HomeswiftUI") await checkPort(value);
        const result = await api(`/api/config/platforms/${block.index}${anyway ? "?force=true" : ""}`, { method: "PUT", body: value });
        saved = snapshot();
        message.className = "ok";
        message.textContent = savedText(result);
        // The web UI's own block: it restarts on its new port or scheme, and this page follows (the login
        // stays, though a session started over HTTPS does not go back to HTTP).
        const port = platform === "HomeswiftUI" ? Number(value.port || 8581) : null;
        const scheme = value.https === true ? "https:" : "http:";
        if (port && (String(port) !== (location.port || (location.protocol === "https:" ? "443" : "80")) || scheme !== location.protocol)) {
          message.textContent = scheme !== location.protocol ? t("Saved. The web UI moves to {scheme}…", { scheme: scheme.slice(0, -1).toUpperCase() }) : t("Saved. The web UI moves to port {port}…", { port: String(port) });
          setTimeout(() => { location.href = `${scheme}//${location.hostname}:${port}${location.pathname}`; }, 1500);
          return;
        }
        // A new block, or a renamed one, lives at its own address now.
        const name = value.name || platform;
        if (isNew || name !== block.name) { leaveGuard = null; navigate((hasPage ? expertLink : settingsLink)({ slug: slug(name) }), { replace: true }); return; }
        update();
      } catch (e) {
        message.className = "error";
        save.disabled = false;
        if (!e.problems) { message.textContent = e.message; return; }
        // Inside the block: the paths start at the file's platforms. The JSON on screen marks their lines.
        const paths = e.problems.map((problem) => problem.path.slice(2));
        const places = jsonShown() ? editor.markPaths(paths) : [];
        message.replaceChildren(el("span", { text: t("The plugin's schema refuses this:") }), problemList(e.problems.map((problem, i) => ({ ...places[i], text: HomeswiftI18n.message(problem.text) })), jsonShown() ? editor : null));
        force.classList.remove("hidden");
      }
    };
    save.addEventListener("click", () => doSave(false));
    force.addEventListener("click", () => doSave(true));
    revert.addEventListener("click", () => { if (isNew) { navigate("/plugins"); return; } leaveGuard = null; route(); });

    const [state, kind] = isNew ? [t("New"), "standby"] : blockState(block, plugin, instance);
    const remove = !isNew && !block.system ? el("div", { class: "card danger-zone" },
      el("div", {}, el("strong", { text: t("Remove this plugin") }),
        el("p", { class: "muted", text: t("Takes the block out of config.json. Its accessories leave the Home app, with their rooms, scenes and automations.") })),
      el("button", { actionIcon: "trash", class: "danger", text: t("Remove"), onclick: () => removeBlock(block, () => navigate("/plugins")) })) : null;

    leaveGuard = async () => !dirty() || isNew || await HomeswiftCommon.confirmDialog(t("Leave without saving your changes?"));
    leaveGuard.quiet = () => isNew || !dirty();
    show(main,
      breadcrumb([t("Plugins"), "/plugins"], [blockTitle(block), isNew ? "/plugins" : settingsLink(block)], [isNew ? t("Add") : hasPage ? t("Expert") : t("Settings")]),
      el("div", { class: "page-head settings-head" },
        tile(block.icon ?? (block.system ? "gear" : "plugin"), block.system ? "grey" : "orange"),
        el("div", { class: "who" },
          el("h1", { text: isNew ? t("Add {name}", { name: plugin.name }) : blockTitle(block) }),
          el("p", { class: "muted", text: [...new Set([plugin ? plugin.name : platform, platform])].filter((part) => part !== block.name).concat(
            instance ? [tn("{n} accessory on {bridge}", "{n} accessories on {bridge}", instance.accessories, { bridge: instance.bridge })] : []).join(" · ") })),
        el("div", { class: "tools" }, el("span", { class: `pill status ${kind}`, text: state }))),
      // A plugin with its own page does the everyday work there (pairing, devices); this is the raw block.
      hasPage ? el("div", { class: "card page-note" },
        el("p", {}, el("strong", { text: t("Expert.") }), " ", t("Every setting of the block, as config.json keeps it, including what {plugin}'s page does not show. A save reloads the plugin.", { plugin: plugin.name })),
        el("a", { class: "button", href: pluginPage(block), text: t("Back to its page") })) : null,
      platform === "HomeswiftAiKit" && useSuggestion && !isNew ? assistantSettings({
        formValue: () => { try { return { ...getValue(), platform }; } catch { return { ...current, platform }; } },
        useValue: useSuggestion, save, dirty }) : null,
      useSuggestion && !block.system ? describeSetup({ platform, pluginName: plugin ? plugin.name : platform, current: () => { try { return getValue(); } catch { return current; } }, use: useSuggestion }) : null,
      body,
      el("div", { class: "settings-bar" }, message, revert, force, save),
      remove);
    update();
    if (platform === "HomeswiftUI") {
      const section = new URLSearchParams(location.search).get("section");
      if (["proxy", "schedules", "updates"].includes(section)) {
        const target = body.querySelector(`[data-section="${section}"]`);
        if (target) {
          target.open = true;
          target.style.scrollMarginTop = "90px";
          requestAnimationFrame(() => {
            if (!target.isConnected) return;
            target.scrollIntoView({ block: "start" });
            target.querySelector("summary")?.focus({ preventScroll: true });
          });
        }
      }
    }
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
    const test = el("button", { actionIcon: "send", text: t("Test connection"), onclick: async () => {
      test.disabled = true;
      result.className = "muted test-result";
      result.textContent = t("Asking the provider…");
      try {
        const answer = await api("/api/assistant/test", { method: "POST", body: { block: formValue() } });
        result.className = `test-result ${answer.ok ? "ok" : "error"}`;
        result.textContent = answer.ok ? t("It works: {provider} · {model} answered in {ms} ms.", { provider: answer.provider, model: answer.model, ms: answer.latencyMs }) : HomeswiftI18n.message(answer.message) || t("It did not answer.");
        loadUsage();
      } catch (e) { result.className = "test-result error"; result.textContent = e.message; }
      test.disabled = false;
    } });

    const usage = el("div", { class: "usage" }, el("p", { class: "muted", text: t("Loading…") }));
    const money = (usd) => usd == null ? "–" : usd > 0 && usd < 0.01 ? `$${usd.toFixed(4)}` : `$${usd.toFixed(2)}`;
    const tokens = (summary) => (summary.inputTokens + summary.outputTokens).toLocaleString(HomeswiftI18n.locale);
    const meter = (label, used, limit, format) => {
      const share = Math.min(1, limit ? used / limit : 0);
      return el("div", { class: `budget-meter${share >= 1 ? " over" : share >= 0.8 ? " near" : ""}` },
        el("div", { class: "budget-label" }, el("span", { text: label }), el("b", { text: t("{used} of {limit}", { used: format(used), limit: format(limit) }) })),
        el("div", { class: "gauge-track", role: "meter", "aria-label": label, "aria-valuemin": "0", "aria-valuemax": String(limit), "aria-valuenow": String(used) },
          el("div", { class: "gauge-fill", style: `width:${share * 100}%` })));
    };
    const table = (title, rows) => rows.length ? el("div", { class: "table-scroll" }, el("table", {},
      el("thead", {}, el("tr", {}, [title, t("Requests"), t("Tokens"), t("Cost")].map((text) => el("th", { text })))),
      el("tbody", {}, rows.map(([name, summary]) => el("tr", {}, el("td", { text: name }), el("td", { text: summary.requests.toLocaleString(HomeswiftI18n.locale) }),
        el("td", { text: tokens(summary) }), el("td", { text: money(summary.costUsd) })))))) : null;
    async function loadUsage() {
      let answer;
      try { answer = await api("/api/assistant/usage"); } catch (e) { usage.replaceChildren(el("p", { class: "error", text: e.message })); return; }
      const report = answer.usage;
      const budget = report.budget || {};
      const meters = [
        budget.dailyTokens ? meter(t("Tokens today"), report.today.inputTokens + report.today.outputTokens, budget.dailyTokens, (n) => n.toLocaleString(HomeswiftI18n.locale)) : null,
        budget.dailyUsd ? meter(t("Spent today"), report.today.costUsd ?? 0, budget.dailyUsd, money) : null,
        budget.monthlyTokens ? meter(t("Tokens this month"), report.thisMonth.inputTokens + report.thisMonth.outputTokens, budget.monthlyTokens, (n) => n.toLocaleString(HomeswiftI18n.locale)) : null,
        budget.monthlyUsd ? meter(t("Spent this month"), report.thisMonth.costUsd ?? 0, budget.monthlyUsd, money) : null,
      ].filter(Boolean);
      const byModel = Object.entries(report.monthByModel || {}).sort(([, a], [, b]) => b.requests - a.requests);
      const byUser = Object.entries(report.byUser?.thisMonth || {}).sort(([, a], [, b]) => b.requests - a.requests);
      usage.replaceChildren(...[
        el("div", { class: "stats" },
          el("div", { class: "stat" }, el("b", { text: report.today.requests.toLocaleString(HomeswiftI18n.locale) }), el("span", { text: t("Requests today") })),
          el("div", { class: "stat" }, el("b", { text: money(report.today.costUsd) }), el("span", { text: t("Cost today") })),
          el("div", { class: "stat" }, el("b", { text: report.thisMonth.requests.toLocaleString(HomeswiftI18n.locale) }), el("span", { text: t("Requests this month") })),
          el("div", { class: "stat" }, el("b", { text: money(report.thisMonth.costUsd) }), el("span", { text: t("Cost this month") }))),
        report.exceeded ? el("p", { class: "error", text: HomeswiftI18n.message(report.exceeded) }) : null,
        meters.length ? el("div", { class: "budget-meters" }, meters) : el("p", { class: "muted", text: t("No budget: requests are not limited.") }),
        byModel.length || byUser.length ? el("details", { class: "more" }, el("summary", { text: t("This month by model and by user") }),
          table(t("Model"), byModel), table(t("User"), byUser)) : null,
        el("p", { class: "muted", text: t("Costs come from the token counts at today's prices; only Claude models are priced.") })].filter(Boolean));
    }

    // The budget's four limits, written into the form and saved with it; empty is no limit.
    const limits = [["dailyTokens", t("Tokens per day"), 1], ["dailyUsd", t("USD per day"), 0.01], ["monthlyTokens", t("Tokens per month"), 1], ["monthlyUsd", t("USD per month"), 0.01]];
    const inputs = Object.fromEntries(limits.map(([key, , step]) => [key, el("input", { type: "number", min: 0, step, inputMode: "decimal", placeholder: t("No limit") })]));
    const budgetMessage = el("span", { class: "muted" });
    const editor = el("details", { class: "more budget-editor" },
      el("summary", { text: t("Edit the budgets") }),
      el("div", { class: "fields" }, limits.map(([key, label]) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), inputs[key]))),
      el("div", { class: "actions" }, budgetMessage, el("button", { actionIcon: "check", class: "primary", text: t("Save the budgets"), onclick: async () => {
        if (dirty() && !await HomeswiftCommon.confirmDialog(t("The form below has other unsaved changes: save them with the budgets?"))) return;
        const budget = {};
        for (const [key] of limits) if (inputs[key].value !== "" && Number(inputs[key].value) > 0) budget[key] = Number(inputs[key].value);
        const value = formValue();
        if (Object.keys(budget).length) value.budget = budget; else delete value.budget;
        budgetMessage.className = "muted";
        budgetMessage.textContent = t("Saving…");
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
        el("div", { class: "who" }, el("strong", { text: t("The Assistant") }), el("div", { class: "muted", text: save ? t("Check the settings below before saving them, and see what it costs.") : t("Whether its provider answers, and what it costs.") })),
        test),
      result, usage, editor);
  }

  /// Settings › Assistant (admin.js draws the page around it): the card for the saved HomeswiftAiKit block, and a
  /// link to all its settings.
  async function assistantPage(main, subnav) {
    const plugins = await api("/api/plugins");
    const entry = plugins.blocks.find((one) => one.platform === "HomeswiftAiKit");
    const head = pageHead(t("Settings"), t("The Assistant: whether its provider answers, what it costs, and its budgets."));
    if (!entry) {
      show(main, head, subnav, el("section", { class: "card assistant-welcome" },
        el("span", { class: "tile tone-ai", "aria-hidden": "true" }, sparkle()),
        el("h2", { text: t("Set up your Assistant") }),
        el("p", { class: "muted", text: t("The Assistant is off until you connect an AI provider.") }),
        el("div", { class: "assistant-setup-note" },
          el("strong", { text: t("Choose how it runs") }),
          el("p", { text: t("Use Anthropic with an API key, or Apple Intelligence on a supported Mac with Apple Intelligence enabled.") })),
        // Straight to the form that adds the Assistant's block, its provider and key in their fields.
        el("a", { class: "button primary", actionIcon: "sparkle", href: "/plugins/add/HomeswiftAiKit", text: t("Set up") }),
        el("details", { class: "assistant-setup-example" },
          el("summary", { text: t("Configuration example") }),
          el("p", { class: "muted", text: t("Add this block to platforms in config.json and replace the API key. For Apple Intelligence, set provider to apple and omit apiKey.") }),
          jsonView({ platform: "HomeswiftAiKit", provider: "anthropic", apiKey: "…" }))));
      return;
    }
    const block = await api(`/api/config/block/${encodeURIComponent(entry.platform)}/${encodeURIComponent(entry.name)}`);
    show(main, head, subnav, assistantSettings({ block }),
      el("div", { class: "actions" }, el("a", { class: "link", href: settingsLink(entry), text: t("All the Assistant's settings: provider, model, key, MCP server") })));
  }

  /// Describe your setup: the Assistant writes the block from the plugin's config.schema.json and a sentence
  /// ("two lights, the second one at 192.168.1.40"); the change shows as a diff, and "Use it" puts it in the form
  /// as unsaved changes. Shown when the Assistant is on.
  function describeSetup({ platform, pluginName, current, use }) {
    const card = el("details", { class: "card describe-setup hidden" });
    api("/api/assistant").then((state) => { if (state && state.enabled) card.classList.remove("hidden"); }).catch(() => {});
    const request = el("textarea", { class: "short", rows: 3, placeholder: t("What should {plugin} do? For example: \"add my second light at 192.168.1.40, and poll every 5 seconds\".", { plugin: pluginName }), "aria-label": t("Your setup, in your words") });
    const ask = el("button", { actionIcon: "sparkle", class: "primary", text: t("Suggest") });
    const result = el("div", { class: "describe-result" });
    ask.addEventListener("click", async () => {
      if (!request.value.trim()) { request.focus(); return; }
      ask.disabled = true;
      result.replaceChildren(el("p", { class: "muted", text: t("The Assistant is writing the block…") }));
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
            : el("p", { class: "muted", text: t("No change to the block.") }),
          changed ? el("div", { class: "actions" },
            el("button", { actionIcon: "check", class: "primary", text: t("Use it"), onclick: () => { use(after); result.replaceChildren(el("p", { class: "ok", text: t("In the form: review it, then Save.") })); } }),
            el("button", { actionIcon: "close", text: t("Discard"), onclick: () => result.replaceChildren() })) : null,
          el("p", { class: "muted", text: t("Written by {model}. Passwords and tokens never reach it; check addresses and names before saving.", { model: reply.model }) })].filter(Boolean));
      } catch (e) {
        result.replaceChildren(el("p", { class: "error", text: e.message }));
      } finally { ask.disabled = false; }
    });
    card.append(el("summary", {}, sparkle(), el("strong", { text: ` ${t("Describe your setup")}` }), el("span", { class: "muted describe-note", text: t("the Assistant writes the settings") })),
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
    const zone = el("div", { class: "drop-zone", role: "button", tabIndex: 0, "aria-label": t("Drop or choose the file for {key}", { key }) },
      t("Drop the file here, or "), el("strong", { text: t("choose it [file]") }), picker);
    const take = async (file) => {
      if (!file) return;
      zone.classList.remove("ok", "error");
      try {
        if (file.size > 256 * 1024) throw new Error(t("That file is too large for a certificate or a key."));
        const { path } = await api("/api/files", { method: "POST", body: { field: key, name: file.name, content: await file.text() } });
        input.value = path;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        zone.classList.add("ok");
        zone.replaceChildren(t("{name} saved", { name: file.name }), picker);
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

  /// An English plural title's singular, for a list's Add button: proxies → proxy, addresses → address, hosts → host (status stays).
  const singular = (text) => text.replace(/ies$/, "y").replace(/(ss|x|ch|sh)es$/, "$1").replace(/([^su])s$/, "$1");

  /// A form from a Homebridge-style config.schema.json; key order follows the schema (and its layout). Its words come
  /// from the schema's own `i18n` (`{ "fr": { "English": "Français" }, … }`), English where it has none.
  function buildForm(root, value) {
    const words = (root.i18n && root.i18n[HomeswiftI18n.language]) || {};
    const tr = (text) => (typeof text === "string" && text && words[text]) || text;
    const schema = root.schema || root;
    const properties = schema.properties || {};
    const requiredTop = new Set(Array.isArray(schema.required) ? schema.required : []);
    const fields = new Map();
    const container = el("div", {});
    // Fields and layout groups shown only when their condition holds, re-checked as the form changes.
    const conditional = [];
    // `require`: the condition makes the field required (`x-schema-form.requiredWhen`) rather than shows it.
    const watch = (element, condition, index, require = false) => {
      const test = schemaCondition(condition);
      if (test && element) conditional.push({ element, test, index, require });
    };

    const field = (key, property, current, required, index) => {
      const made = makeField(key, property, current, required, index);
      watch(made.element, property.condition ?? property["x-schema-form"]?.condition, index);
      // Required only while a condition holds (`x-schema-form.requiredWhen`, read as `condition`s are): a block whose
      // settings depend on another (an account or keys, by the route chosen) marks the ones it needs now.
      if (!required) watch(made.element, property["x-schema-form"]?.requiredWhen, index, true);
      return made;
    };
    /// A cron expression (`x-schema-form.type: "schedule"`, the scheduled restart) as a time and the days it runs on,
    /// which it writes as `M H * * d,d`; an expression that says more than that stays as it is, under Custom.
    const scheduleField = (wrap, current) => {
      // The week from Sunday (1 January 2023 was one), in the page's language.
      const weekday = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short" });
      const names = [0, 1, 2, 3, 4, 5, 6].map((day) => weekday.format(new Date(2023, 0, 1 + day)));
      const text = typeof current === "string" ? current.trim() : "";
      const simple = /^(\d{1,2})\s+(\d{1,2})\s+\*\s+\*\s+(\*|[0-7](?:,[0-7])*)$/.exec(text);
      const fits = simple && Number(simple[1]) < 60 && Number(simple[2]) < 24;
      const mode = el("select", { "aria-label": t("Repeat") },
        el("option", { value: "never", text: t("Never") }), el("option", { value: "time", text: t("At a time") }), el("option", { value: "custom", text: t("Custom (cron)") }));
      mode.value = !text ? "never" : fits ? "time" : "custom";
      const pad = (n) => String(n).padStart(2, "0");
      const time = el("input", { type: "time", value: fits ? `${pad(simple[2])}:${pad(simple[1])}` : "04:00", "aria-label": t("Time") });
      const chosen = new Set(fits && simple[3] !== "*" ? simple[3].split(",").map((day) => Number(day) % 7) : []);
      const days = el("span", { class: "days", role: "group", "aria-label": t("Days (none: every day)") }, names.map((name, day) => {
        const box = el("input", { type: "checkbox", checked: chosen.has(day), "aria-label": name });
        box.addEventListener("change", () => { if (box.checked) chosen.add(day); else chosen.delete(day); });
        return el("label", { class: "day" }, box, el("span", { text: name.slice(0, 2) }));
      }));
      const custom = el("input", { type: "text", value: text, placeholder: "0 4 * * 1", "aria-label": t("Cron expression") });
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
      const title = tr(property.title) || key;
      const help = property.description ? el("div", { class: "help", text: tr(property.description) }) : null;
      const marked = required || property["x-schema-form"]?.requiredWhen !== undefined;
      const wrap = (control) => el("label", { class: "field" }, el("span", { class: "field-title" }, title, marked ? el("span", { class: `muted required-mark${required ? "" : " hidden"}`, text: ` · ${t("required")}` }) : null), control, help);
      const type = property.type;
      if (property["x-schema-form"]?.type === "schedule") return scheduleField(wrap, current);
      const options = property.oneOf && property.oneOf.every((o) => Array.isArray(o.enum)) ? property.oneOf.map((o) => ({ value: o.enum[0], title: tr(o.title) ?? String(o.enum[0]) })) : property.enum ? property.enum.map((v) => ({ value: v, title: String(v) })) : null;
      // A value config.json has that is not among the choices stays one, so a save does not drop it.
      if (options && current !== undefined && !options.some((o) => JSON.stringify(o.value) === JSON.stringify(current))) options.unshift({ value: current, title: String(current) });
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
        const input = el("input", { type: "number", value: current ?? "", placeholder: tr(property.placeholder ?? property["x-schema-form"]?.placeholder) ?? property.default ?? "", min: property.minimum, max: property.maximum, step: property.step ?? (type === "integer" ? 1 : "any"), required });
        return { element: wrap(input), get: () => (input.value === "" ? undefined : Number(input.value)) };
      }
      if (type === "object" && property.properties) {
        const nested = buildObject(property, current || {}, index);
        return { element: el("fieldset", {}, el("legend", { text: title }), help, nested.element), get: () => { const v = nested.getValue(); return Object.keys(v).length ? v : undefined; } };
      }
      if (type === "array") {
        const items = property.items || { type: "string" };
        // What one entry is called, for its Add button and an unnamed row: the items' own title, else in English the
        // list's title made singular.
        const noun = items.title ? tr(items.title) : HomeswiftI18n.language === "en" ? singular(title) : null;
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
              name.textContent = value.name || value.displayName || `${noun ?? title} ${rows.indexOf(entry) + 1}`;
              detail.textContent = [value.ip || value.host, value.mac].filter(Boolean).join(" · ");
            };
            const row = el("details", { class: "entry", open: itemValue === undefined },
              el("summary", {}, name, detail, el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: (event) => {
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
          const remove = el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: () => { row.remove(); rows.splice(rows.indexOf(entry), 1); } });
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
          el("button", { actionIcon: "plus", text: noun ? t("Add {item}", { item: noun.toLowerCase() }) : t("Add"), onclick: () => addRow(undefined) }));
        return { element, get: () => { const v = rows.map((r) => r.get()).filter((x) => x !== undefined); return v.length ? v : undefined; } };
      }
      const input = el("input", { type: property["x-schema-form"] && property["x-schema-form"].type === "password" ? "password" : "text", value: current ?? "", placeholder: tr(property.placeholder ?? property["x-schema-form"]?.placeholder) ?? property.default ?? "", required });
      if (property["x-schema-form"]?.type === "file") return { element: el("div", {}, wrap(input), dropZone(key, input, property["x-schema-form"].accept)), get: () => (input.value === "" ? undefined : input.value) };
      // A secret's key (the rule references resolve by): a value typed, or an entry of the vault.
      if (isSecretKey(key)) return secretField(wrap, input);
      return { element: wrap(input), get: () => (input.value === "" ? undefined : input.value) };
    };
    /// A secret's field with the vault's menu beside it: an entry picked is written `vault:<name>` and shown as it is,
    /// a name rather than the secret; a typed value stays masked when the schema masks it.
    const secretField = (wrap, input) => {
      const masked = input.type === "password";
      const reveal = () => { input.type = masked && !isReference(input.value) ? "password" : "text"; };
      const pick = el("button", { type: "button", class: "icon-button", "aria-label": t("Choose from the vault"), title: t("Choose from the vault") }, HomeswiftCommon.icon("vault"));
      pick.addEventListener("click", async (event) => {
        event.preventDefault();
        const keyboard = event.detail === 0;
        let entries = [];
        try { entries = (await api("/api/vault")).entries; } catch { /* the menu still opens the vault */ }
        const choose = (value) => { input.value = value; reveal(); input.dispatchEvent(new Event("input", { bubbles: true })); };
        HomeswiftCommon.menu(pick, [
          // The entry the field names now is ticked.
          ...entries.map((entry) => ({ label: entry.name, icon: "key", checked: input.value === `vault:${entry.name}`, onSelect: () => choose(`vault:${entry.name}`) })),
          isReference(input.value) ? { label: t("Type a value instead"), icon: "edit", pinned: true, onSelect: () => { choose(""); input.focus(); } } : null,
          { label: entries.length ? t("Open the vault") : t("Add one in the vault"), icon: "gear", pinned: true, href: "/settings/vault" },
        ].filter(Boolean), { keyboard, search: entries.length ? t("Search the vault") : null });
      });
      input.addEventListener("input", reveal);
      reveal();
      return { element: wrap(el("span", { class: "secret-field" }, input, pick)), get: () => (input.value === "" ? undefined : input.value) };
    };

    /// Required fields and the ones that hold a value show; the rest wait under "More options", unless that would
    /// hide them all (a box of empty settings, a budget, shows its fields rather than a closed box in a box).
    const isSet = (value) => value !== undefined && value !== null && value !== "" && !(Array.isArray(value) && !value.length);
    function splitFields(entries) {
      const shown = [], more = [];
      for (const { element, required, value } of entries) (required || isSet(value) ? shown : more).push(element);
      if (!more.length || !shown.length) return [...shown, ...more];
      return [...shown, el("details", { class: "more-options" }, el("summary", { text: t("More options ({count})", { count: more.length }) }), el("div", { class: "fields" }, more))];
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
        let inner = item.items.map(layoutItem).flat().filter(Boolean);
        if (!inner.length) return null;
        // A group holding one object of its own name (Budget in Budget) shows the object's fields, not a box titled
        // again inside it.
        const only = inner.length === 1 && inner[0].tagName === "FIELDSET" ? inner[0] : null;
        if (only && item.title && only.querySelector(":scope > legend")?.textContent === tr(item.title)) inner = [...only.children].filter((child) => child.tagName !== "LEGEND");
        const node = item.type === "fieldset" || item.title
          ? el("details", { class: "group-box", "data-section": item.section || slug(item.title || ""), open: !item.expandable || item.expanded !== false }, el("summary", {}, item.icon ? HomeswiftCommon.icon(item.icon) : null, el("span", { text: tr(item.title) || t("More") })), el("div", { class: "fields" }, ...inner))
          : el("div", { class: "fields" }, ...inner);
        watch(node, item.condition);
        return node;
      }
      return null;
    };
    if (Array.isArray(root.layout)) for (const item of root.layout) { const node = layoutItem(item); if (node) container.append(...[node].flat()); }
    const restKeys = Object.keys(properties).filter((key) => !fields.has(key));
    const rest = restKeys.map((key) => ({ key, element: render(key) })).filter((entry) => entry.element)
      // A field with a condition is shown in the main part while its condition holds, not under More options.
      .map(({ key, element }) => ({ element, required: requiredTop.has(key) || properties[key].required === true || Boolean(properties[key].condition ?? properties[key]["x-schema-form"]?.condition ?? properties[key]["x-schema-form"]?.requiredWhen), value: value[key] }));
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
      const holds = ({ test, index }) => test(model, typeof index === "function" ? index() : index);
      for (const entry of conditional) if (!entry.require) entry.element.classList.toggle("hidden", !holds(entry));
      // A field is required while its condition holds and it is on screen (its own and its group's conditions).
      for (const entry of conditional) {
        if (!entry.require) continue;
        const { element } = entry;
        const needed = holds(entry) && !element.closest(".hidden");
        element.querySelector(".required-mark")?.classList.toggle("hidden", !needed);
        const control = element.querySelector("input, select, textarea");
        if (control) control.required = needed;
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
  const strengthLabels = { strongToVeryStrong: t("Strong to very strong"), mediumToStrong: t("Medium to strong"), lowToMedium: t("Low to medium"), veryWeak: t("Very weak") };

  /// The ANSSI's bands, from the bits where each starts: the scale under the gauge.
  const strengthBands = [[0, t("Weak")], [65, t("Low [strength]")], [85, t("Medium")], [100, t("Strong")]];

  /// A live gauge under a password field: the ANSSI's bands along 0 to 128 bits as one gradient, lit up to the
  /// password's entropy, the 85-bit bar marked, and the two rules ticking as they are met. `username()` gives the
  /// name the password must not lean on. `gauge.acceptable()` answers, once the server has, whether the password as
  /// typed passes. Its classes are `strength-*`: the widgets' dial is `.gauge`.
  function strengthGauge(input, username = () => "") {
    const percent = (bits) => `${(Math.min(bits, passwordPolicy.scaleBits) / passwordPolicy.scaleBits) * 100}%`;
    const fill = el("div", { class: "strength-fill" });
    const label = el("strong", { class: "strength-level" });
    const bits = el("span", { class: "strength-bits" });
    const ruleLength = el("li", { text: t("At least {n} characters", { n: passwordPolicy.minimumLength }) });
    const ruleBits = el("li", { text: t("At least {n} bits of entropy (ANSSI: medium to strong)", { n: passwordPolicy.minimumBits }) });
    const hint = el("p", { class: "help strength-hint" });
    const track = el("div", { class: "strength-track", role: "meter", "aria-label": t("Password strength"), "aria-valuemin": "0", "aria-valuemax": String(passwordPolicy.scaleBits) },
      fill,
      ...strengthBands.slice(1).map(([at]) => el("span", { class: "strength-tick", style: `left:${percent(at)}` })),
      el("span", { class: "strength-mark", title: t("Required: {n} bits", { n: passwordPolicy.minimumBits }), style: `left:${percent(passwordPolicy.minimumBits)}` }));
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
      track.setAttribute("aria-valuetext", s ? t("{level}, {bits} bits", { level: strengthLabels[s.level], bits: s.bits }) : t("empty"));
      label.textContent = s ? strengthLabels[s.level] : t("Strength");
      bits.textContent = s ? t("{bits} bits", { bits: s.bits }) : t("{bits} bits needed", { bits: passwordPolicy.minimumBits });
      ruleLength.classList.toggle("met", Boolean(s?.lengthMet));
      ruleBits.classList.toggle("met", Boolean(s?.bitsMet));
      const reason = s?.reason ? HomeswiftI18n.message(s.reason) : null;
      hint.textContent = !s || s.bitsMet ? "" : reason ? `${reason[0].toUpperCase()}${reason.slice(1)}.`
        : t("Length helps most: a phrase of several random words is strong and easy to remember.");
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
    const [state, apps] = await Promise.all([api("/api/auth/state"), api("/api/account/apps").catch(() => null)]);
    if (state.mode !== "form") {
      const plugins = await api("/api/plugins");
      const ui = plugins.blocks.find((block) => block.platform === "HomeswiftUI");
      show(main, pageHead(t("Account"), t("This web UI has no sign-in: its HomeswiftUI block says auth none, so there is no password to change.")),
        el("div", { class: "card" }, el("p", { class: "muted" }, el("a", { class: "account-settings-link", href: ui ? settingsLink(ui) : "/plugins", text: t("Plugins › HomeswiftUI › Settings") }), " ", t("turns sign-in on."))), appearanceLink());
      return;
    }
    const field = (label, input, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, help ? el("span", { class: "help", text: help }) : null);
    const current = el("input", { type: "password", autocomplete: "current-password", required: true });
    const next = el("input", { type: "password", autocomplete: "new-password", required: true, minLength: passwordPolicy.minimumLength });
    const again = el("input", { type: "password", autocomplete: "new-password", required: true, minLength: passwordPolicy.minimumLength });
    const gauge = strengthGauge(next, () => state.username || "");
    const message = el("p", { class: "status-line muted", role: "status" });
    const submit = el("button", { actionIcon: "key", class: "primary", type: "submit", text: t("Change password") });
    const fail = (text) => { message.className = "status-line error"; message.textContent = text; };
    const days = state.sessionDays ?? 7;
    const form = el("form", { class: "card account-form", onsubmit: async (event) => {
      event.preventDefault();
      if (!(await gauge.acceptable())) { next.focus(); return fail(t("The new password is not strong enough yet: the gauge says what is missing.")); }
      if (next.value !== again.value) { again.focus(); return fail(t("The two new passwords are not the same.")); }
      if (next.value === current.value) return fail(t("The new password is the current one."));
      submit.disabled = true;
      try {
        await api("/api/account/password", { method: "POST", body: { current: current.value, new: next.value } });
        form.reset();
        gauge.refresh();
        message.className = "status-line ok";
        message.textContent = t("Password changed. Other browsers signed in as {username} are signed out; this one stays.", { username: state.username });
      } catch (e) { fail(e.message); current.focus(); }
      submit.disabled = false;
    } },
      el("h2", { text: t("Change your password") }),
      el("p", { class: "muted account-lead", text: t("A phrase of several random words is long, strong and easy to remember.") }),
      // The fields on one side, the new password's entropy beside them as it is typed.
      el("div", { class: "account-password" },
        el("div", { class: "account-fields" },
          field(t("Current password"), current),
          field(t("New password"), next),
          field(t("New password again"), again),
          el("div", { class: "actions" }, submit), message),
        el("aside", { class: "strength-panel", "aria-label": t("Strength of the new password") },
          el("span", { class: "field-title", text: t("Entropy of the new password") }), gauge)));
    // Who is signed in, with the one thing to do about it.
    const profile = el("section", { class: "card account-profile" },
      el("span", { class: "account-avatar", "aria-hidden": "true", text: (state.username || "?").slice(0, 1).toUpperCase() }),
      el("div", { class: "account-who" },
        el("h2", { text: state.username }),
        el("p", { class: "muted", text: tn("Signed in on this browser. Logins last {n} day without activity; changing the password, or turning two-factor authentication on or off, signs the others out.",
          "Signed in on this browser. Logins last {n} days without activity; changing the password, or turning two-factor authentication on or off, signs the others out.", days) })),
      el("button", { actionIcon: "logout", text: t("Sign out"), onclick: signOut }));
    show(main, pageHead(t("Account"), state.admin ? t("Your sign-in to this bridge's web UI, as an administrator.") : t("Your sign-in to this bridge's web UI.")),
      el("div", { class: "account" }, profile, form, twoFactorCard(state), connectedAppsCard(apps),
        state.admin ? el("div", { class: "card" }, el("h2", { text: t("Users and API tokens") }),
          el("p", { class: "muted", text: t("Add people who may use this web UI, choose who administers it, and make tokens for scripts.") }),
          el("a", { class: "button", href: "/users", text: t("Open Users") })) : null),
      appearanceLink());
  };

  /// The apps this account connected through OAuth (claude.ai and the Claude apps, other MCP clients), each with what
  /// it may do and when it last came; its ⋯ menu disconnects it. With the MCP server on, the address to give them.
  function connectedAppsCard(apps) {
    if (!apps || (!apps.mcp && !apps.apps.length)) return null;
    const when = (iso) => iso ? new Date(iso).toLocaleString(HomeswiftI18n.locale, { dateStyle: "medium", timeStyle: "short" }) : t("Never");
    const scopes = { read: t("Read"), control: t("Control"), admin: t("Admin") };
    const rows = apps.apps.map((app) => el("div", { class: "server-head connected-app" },
      tile("key", app.scope === "admin" ? "orange" : "teal"),
      el("div", { class: "who" }, el("strong", { text: app.client }),
        el("div", { class: "muted", text: app.redirect ? t("{address} · last used {when}", { address: app.redirect, when: when(app.lastUsed) }) : t("Last used {when}", { when: when(app.lastUsed) }) })),
      el("span", { class: app.scope === "admin" ? "pill status admin" : "pill status standby", text: scopes[app.scope] || app.scope }),
      menuButton(t("Actions for {name}", { name: app.client }), () => [
        { label: t("Disconnect"), icon: "trash", danger: true, onSelect: async () => {
          if (!await HomeswiftCommon.confirmDialog(t("Disconnect {name}? It is refused at once and must sign in again.", { name: app.client }))) return;
          try { await api(`/api/account/apps/${encodeURIComponent(app.id)}`, { method: "DELETE" }); route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
        } },
      ])));
    return el("div", { class: "card account-form" },
      el("h2", { text: t("Connected apps") }),
      el("p", { class: "muted" }, apps.mcp
        ? withNodes(t("Apps you allowed to use the bridge through its MCP server. To add one in claude.ai or the Claude apps, make a custom connector with {address}."), { address: el("code", { class: "mono", text: apps.mcp }) })
        : t("Apps you allowed to use the bridge through its MCP server, which is off now.")),
      ...(rows.length ? rows : [el("p", { class: "muted", text: t("None yet.") })]));
  }

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
      const submit = el("button", { actionIcon: "power", type: "submit", text: t("Turn off [setting]") });
      card.append(el("h2", {}, t("Two-factor authentication"), " ", el("span", { class: "pill status on", text: t("On [setting]") })),
        el("p", { class: "muted", text: t("Signing in asks for the code your authenticator app shows, after the password.") }),
        el("form", { onsubmit: async (event) => {
          event.preventDefault();
          submit.disabled = true;
          try { await api("/api/account/otp/disable", { method: "POST", body: { password: password.value } }); reload(); }
          catch (e) { say(e.message); password.focus(); submit.disabled = false; }
        } }, field(t("Password, to turn it off"), password), el("div", { class: "actions" }, submit)), message);
      return card;
    }
    const start = el("button", { actionIcon: "plus", class: "primary", text: t("Set up") });
    card.append(el("h2", {}, t("Two-factor authentication"), " ", el("span", { class: "pill status standby", text: t("Off [setting]") })),
      el("p", { class: "muted", text: t("Ask for a code from an authenticator app (Passwords on iPhone and Mac, Google Authenticator, 1Password…) after the password, so a password alone no longer signs in.") }),
      el("div", { class: "actions" }, start), message);
    start.addEventListener("click", async () => {
      start.disabled = true;
      let setup;
      try { setup = await api("/api/account/otp/setup", { method: "POST", body: {} }); }
      catch (e) { say(e.message); start.disabled = false; return; }
      const code = el("input", { inputMode: "numeric", autocomplete: "one-time-code", required: true, maxLength: 9, placeholder: "123 456", spellcheck: false });
      const confirmButton = el("button", { actionIcon: "power", class: "primary", type: "submit", text: t("Turn on") });
      const secret = el("code", { class: "mono secret", text: setup.secret.replace(/(.{4})/g, "$1 ").trim() });
      start.closest(".actions").replaceWith(
        el("div", { class: "setup" },
          setup.qr ? el("img", { class: "qr", src: `data:image/svg+xml;charset=utf-8,${encodeURIComponent(setup.qr)}`, alt: t("QR code for an authenticator app"), width: 148, height: 148 }) : null,
          el("div", {},
            el("p", { text: t("Scan this code with your authenticator app, or open the link on this device; or type the key by hand.") }),
            el("p", {}, secret, " ", copyButton(setup.secret, secret),
              " · ", el("a", { href: setup.uri, text: t("Open in the app") })))),
        el("form", { onsubmit: async (event) => {
          event.preventDefault();
          confirmButton.disabled = true;
          try { await api("/api/account/otp/activate", { method: "POST", body: { code: code.value } }); reload(); }
          catch (e) { say(e.message); code.select(); confirmButton.disabled = false; }
        } }, field(t("The code the app shows now"), code), el("div", { class: "actions" }, confirmButton)));
      code.focus();
    });
    return card;
  }

  /// A side panel over the page, which is dimmed behind it: a form that is a task of its own (adding or editing a
  /// user, making a token). `build(done)` makes its content; `done(result)` closes it, as Cancel and Escape do
  /// (`result` undefined). It arrives from the right, from the bottom on a phone, and leaves the same way; a touch
  /// can also drag it back out along that edge, as an iOS sheet is swiped away. Once it has gone, `onClose(result)`
  /// runs, or, with no result, focus goes back to `returnFocus`, the control that opened it.
  function openSheet(build, labelledBy, { onClose = null, returnFocus = document.activeElement } = {}) {
    const dialog = el("dialog", { class: "admin-dialog card sheet", "aria-labelledby": labelledBy });
    const reduce = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
    const vertical = () => matchMedia("(max-width: 640px)").matches;   // a phone: a sheet from the bottom edge
    let result, leaving = false;
    // Out along the edge it came from, from wherever it is now (a drag may have moved it), faster than it came.
    const dismiss = (value) => {
      if (leaving) return;
      leaving = true;
      result = value;
      const from = getComputedStyle(dialog).transform;
      const to = vertical() ? "translateY(calc(100% + 12px))" : "translateX(calc(100% + 12px))";
      const duration = reduce() ? 140 : 220;
      dialog.classList.add("leaving");
      const motion = reduce() ? [{ opacity: 1 }, { opacity: 0 }] : [{ transform: from === "none" ? "none" : from }, { transform: to }];
      const done = () => dialog.close();
      try {
        dialog.animate(motion, { duration, easing: "cubic-bezier(0.4, 0, 1, 1)", fill: "forwards" }).finished.then(done, done);
      } catch { done(); }
    };
    dialog.append(el("div", { class: "sheet-grabber", "aria-hidden": "true" }), build(dismiss));
    dialog.addEventListener("cancel", (event) => { event.preventDefault(); dismiss(); });   // Escape
    dialog.addEventListener("close", () => {
      dialog.remove();
      if (onClose) onClose(result);
      else if (returnFocus?.isConnected) returnFocus.focus();
    });
    HomeswiftCommon.dragToDismiss(dialog, { vertical, dismiss, handle: ".sheet-grabber, .account-form > h2" });
    document.body.append(dialog);
    dialog.showModal();
    $("input:not([type=hidden]):not([disabled]), select", dialog)?.focus();
    return dialog;
  }

  /// Draws the page again, then brings the card `key` (its `data-key`) to the eye and the keyboard: focused, and
  /// lit for a moment, as the one that was just added or changed.
  async function showChanged(key) {
    await route();
    const card = key && document.querySelector(`[data-key="${CSS.escape(key)}"]`);
    if (!card) return;
    card.tabIndex = -1;
    card.focus({ preventScroll: true });
    card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
    card.classList.add("just-changed");
    card.addEventListener("animationend", () => card.classList.remove("just-changed"), { once: true });
  }

  /// A Copy button for `text` that says it worked ("Copied", for two seconds), or, when the browser refuses,
  /// selects `field` so it can be copied by hand.
  function copyButton(text, field) {
    const button = el("button", { actionIcon: "copy", type: "button", class: "link", text: t("Copy") });
    let timer = null;
    button.addEventListener("click", async () => {
      clearTimeout(timer);
      try {
        await copyText(text);
        button.textContent = `✓ ${t("Copied")}`;
      } catch {
        const range = document.createRange();
        range.selectNodeContents(field);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        button.textContent = t("Selected: press ⌘C or Ctrl+C");
      }
      timer = setTimeout(() => { button.textContent = t("Copy"); }, 2000);
    });
    return button;
  }

  /// A small round + beside a heading, adding one more of what the section lists (Add user, Create token): the action
  /// next to its title rather than alone at the page's edge. `label` is its name for screen readers and its tooltip.
  const addButton = (label, onclick) => el("button", { type: "button", class: "add-button", "aria-label": label, title: label, onclick }, HomeswiftCommon.icon("plus"));
  /// A heading with its add button: `tag` is h1 for a page, h2 for a section.
  const titleWithAdd = (tag, text, label, onclick) => el("div", { class: "title-add" }, el(tag, { text }), addButton(label, onclick));

  // ---- Users ---------------------------------------------------------------
  // Glass UI's Users page: the accounts of this web UI, each a card whose ⋯ menu edits it (name, role, a new
  // password) or removes it, and the API tokens for scripts. An administrator's; the last one stays one.

  views.users = async (main) => {
    if (auth.mode !== "form") {
      show(main, pageHead(t("Users"), t("This web UI has no sign-in: its HomeswiftUI block says auth none, so there are no users.")));
      return;
    }
    const [users, tokens] = await Promise.all([api("/api/users"), api("/api/tokens")]);
    const admins = users.filter((user) => user.admin).length;
    // A card's facts are a third of its width: the day alone ("24 Oct 2026"), the time in the tooltip.
    const when = (iso) => iso ? new Date(iso).toLocaleDateString(HomeswiftI18n.locale, { day: "numeric", month: "short", year: "numeric" }) : t("Never");
    const whenFull = (iso) => iso ? new Date(iso).toLocaleString(HomeswiftI18n.locale, { dateStyle: "full", timeStyle: "short" }) : t("Never");
    const field = (label, input, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, help ? el("span", { class: "help", text: help }) : null);
    // A choice as a switch, as the rest of the UI's on and off.
    const checkbox = (label, checked, help) => {
      const input = el("input", { type: "checkbox", checked });
      return [el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")), el("span", { class: "field-title", text: label })), help ? el("p", { class: "help", text: help }) : null, input];
    };
    const roleHelp = t("An administrator changes settings, plugins and users; anyone else sees the bridge and controls accessories.");

    /// The form that adds a user, or changes one (`user`): name, role, and a password (a new one, for a user).
    function userForm(user, done) {
      const username = el("input", { autocomplete: "off", autocapitalize: "none", required: true, maxLength: 64, spellcheck: false, value: user?.username ?? "" });
      username.setAttribute("autocorrect", "off");
      const name = el("input", { autocomplete: "off", maxLength: 64, value: user && user.name !== user.username ? user.name : "", placeholder: user ? t("{username} (the username)", { username: user.username }) : t("The username") });
      const password = el("input", { type: "password", autocomplete: "new-password", required: !user });
      const gauge = strengthGauge(password, () => username.value);
      // The gauge once there is a password to judge (an empty field keeps theirs, and needs no meter): it unfolds,
      // easing the fields below down rather than pushing them.
      const gaugeBox = el("div", { class: "unfold", inert: true }, el("div", {}, gauge));
      password.addEventListener("input", () => { gaugeBox.classList.toggle("open", Boolean(password.value)); gaugeBox.inert = !password.value; });
      const [roleLabel, roleNote, admin] = checkbox(t("Administrator"), user ? user.admin : false, roleHelp);
      if (user?.admin && admins < 2) { admin.disabled = true; roleNote.textContent = t("The last administrator stays one: make another user an administrator first."); }
      const message = el("p", { class: "status-line muted", role: "status" });
      const submit = el("button", { class: "primary", type: "submit", text: user ? t("Save") : t("Add user") });
      const form = el("form", { class: "account-form", onsubmit: async (event) => {
        event.preventDefault();
        if (password.value && !(await gauge.acceptable())) { message.className = "status-line error"; message.textContent = t("The password is not strong enough yet: the gauge says what is missing."); return; }
        submit.disabled = true;
        try {
          if (user) {
            const body = { name: name.value, admin: admin.checked };
            if (password.value) body.password = password.value;
            await api(`/api/users/${encodeURIComponent(user.username)}`, { method: "PUT", body });
          } else {
            await api("/api/users", { method: "POST", body: { username: username.value, name: name.value, password: password.value, admin: admin.checked } });
          }
          done(`user:${(user?.username ?? username.value).trim().toLowerCase()}`);
        } catch (e) { message.className = "status-line error"; message.textContent = e.message; submit.disabled = false; }
      } },
        el("h2", { id: "user-form-title", text: user ? t("Edit {name}", { name: user.name }) : t("Add a user") }),
        user ? null : field(t("Username"), username, t("What they sign in with: no spaces or colons.")),
        field(t("Name"), name, t("Shown in the web UI; the username when empty.")),
        el("label", { class: "field" }, el("span", { class: "field-title", text: user ? t("New password") : t("Password") }), password,
          user ? el("span", { class: "help", text: t("Leave empty to keep theirs. A new one signs them out everywhere.") }) : null, gaugeBox),
        roleLabel, roleNote,
        message, el("div", { class: "actions" }, el("button", { actionIcon: "close", type: "button", text: t("Cancel"), onclick: () => done() }), submit));
      return form;
    }

    // Adding or editing a user is a task of its own: a sheet over the page, the page dimmed behind it.
    const list = el("div", { class: "grid" });
    const openForm = (user, returnFocus) => openSheet((done) => userForm(user, done), "user-form-title", {
      returnFocus, onClose: (key) => { if (key) showChanged(key); else if (returnFocus?.isConnected) returnFocus.focus(); } });

    for (const user of users) {
      const lastAdmin = user.admin && admins < 2;
      const actions = menuButton(t("Actions for {name}", { name: user.name }), () => [
        { label: t("Edit"), icon: "edit", onSelect: () => openForm(user, actions) },
        user.you ? { label: t("Your account"), icon: "user", href: "/account" } : null,
        lastAdmin ? null : { label: user.you ? t("Remove your account") : t("Remove"), icon: "trash", danger: true, onSelect: async () => {
          const names = { name: user.name, username: user.username };
          if (!await HomeswiftCommon.confirmDialog(user.you ? t("Remove {name} ({username})? They are signed out at once. That is you: this browser is signed out too.", names)
            : t("Remove {name} ({username})? They are signed out at once.", names))) return;
          try { await api(`/api/users/${encodeURIComponent(user.username)}`, { method: "DELETE" }); if (user.you) await loadAuth(); else route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
        } },
      ]);
      list.append(el("div", { class: "card", "data-key": `user:${user.username.toLowerCase()}` },
        el("div", { class: "server-head" },
          tile(user.admin ? "key" : "user", user.admin ? "orange" : "blue"),
          el("div", { class: "who" }, el("strong", { text: user.name }),
            el("div", { class: "muted" }, el("span", { class: "mono", text: user.username }), user.you ? ` · ${t("you")}` : "")),
          el("span", { class: user.admin ? "pill status admin" : "pill status standby", text: user.admin ? t("Administrator") : t("User") })),
        el("div", { class: "facts two" },
          fact(t("Two-factor"), user.twoFactor ? t("On [setting]") : t("Off [setting]")),
          fact(t("Added"), when(user.created), { title: whenFull(user.created) })),
        el("div", { class: "card-foot" },
          user.you ? el("a", { href: "/account", text: t("Your password and two-factor") })
            : el("span", { class: "muted", text: lastAdmin ? t("The last administrator") : "" }),
          actions)));
    }

    show(main,
      el("div", { class: "page-head" },
        el("div", { class: "who" }, titleWithAdd("h1", t("Users"), t("Add user"), (event) => openForm(null, event.currentTarget)),
          el("p", { class: "muted", text: t("Who may use this web UI. Administrators change settings, plugins and users; other users see the bridge and control accessories.") }))),
      list,
      apiTokens(tokens, when, whenFull));
  };

  /// The API tokens: for scripts, sent as `Authorization: Bearer hst_…` on /api/*. A read token reads; an admin
  /// token does what an administrator does. Shown once, when made; the bridge keeps only a hash. Laid out as the
  /// users are: a button in the section's head opens the form at the head of the grid.
  function apiTokens(tokens, when, whenFull) {
    const name = el("input", { required: true, maxLength: 64, placeholder: t("Backup script"), autocomplete: "off" });
    const scope = el("select", {}, el("option", { value: "read", text: t("Read") }), el("option", { value: "admin", text: t("Admin") }));
    const scopeHelp = el("span", { class: "help" });
    const describeScope = () => { scopeHelp.textContent = scope.value === "admin" ? t("Everything an administrator does, except users and tokens.") : t("The status, accessories and metrics."); };
    scope.addEventListener("change", describeScope);
    describeScope();
    const expiry = el("select", {}, ...[["", t("Never")], ["30", t("In 30 days")], ["90", t("In 90 days")], ["365", t("In a year")]].map(([value, text]) => el("option", { value, text })));
    const message = el("p", { class: "status-line muted", role: "status" });
    const submit = el("button", { actionIcon: "plus", class: "primary", type: "submit", text: t("Create token") });
    const grid = el("div", { class: "grid" });
    let close = () => {};
    let made = null;   // the token made in the panel: the list is drawn again with it once the panel closes
    const form = el("form", { class: "account-form", onsubmit: async (event) => {
      event.preventDefault();
      submit.disabled = true;
      try {
        const token = await api("/api/tokens", { method: "POST", body: { name: name.value, scope: scope.value, expiresInDays: expiry.value ? Number(expiry.value) : null } });
        made = `token:${token.id}`;
        const secret = el("code", { class: "mono secret", text: token.token });
        form.replaceWith(el("div", { class: "account-form token-once" },
          el("h2", { id: "token-form-title", text: t("Token “{name}”", { name: token.name }) }),
          el("p", { class: "help" }, withNodes(t("Copy it now: it is shown once. Send it as {header}."), { header: el("code", { text: "Authorization: Bearer <token>" }) })),
          el("p", {}, secret, " ", copyButton(token.token, secret)),
          el("div", { class: "actions" }, el("button", { actionIcon: "check", type: "button", class: "primary", text: t("Done"), onclick: () => close() }))));
      } catch (e) { message.className = "status-line error"; message.textContent = e.message; }
      submit.disabled = false;
    } },
      el("h2", { id: "token-form-title", text: t("Create an API token") }),
      el("div", { class: "fields" },
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Name") }), name, el("span", { class: "help", text: t("What uses it, to know it again.") })),
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Scope") }), scope, scopeHelp),
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Expires") }), expiry)),
      message, el("div", { class: "actions" }, el("button", { actionIcon: "close", type: "button", text: t("Cancel"), onclick: () => close() }), submit));
    const openTokenForm = (event) => {
      const opener = event?.currentTarget;
      form.reset();
      describeScope();
      message.textContent = "";
      made = null;
      openSheet((done) => { close = done; return form; }, "token-form-title", {
        returnFocus: opener, onClose: () => { if (made) showChanged(made); else if (opener?.isConnected) opener.focus(); } });
    };
    const cards = tokens.map((token) => {
      const expired = token.expires && new Date(token.expires) < new Date();
      return el("div", { class: "card", "data-key": `token:${token.id}` },
        el("div", { class: "server-head" },
          tile("key", token.scope === "admin" ? "orange" : "teal"),
          el("div", { class: "who" }, el("strong", { text: token.name }),
            el("div", { class: "muted", title: whenFull(token.created), text: token.createdBy ? `${token.createdBy} · ${when(token.created)}` : when(token.created) })),
          el("span", { class: token.scope === "admin" ? "pill status admin" : "pill status standby", text: token.scope === "admin" ? t("Admin") : t("Read") })),
        el("div", { class: "facts two" },
          fact(t("Last used"), when(token.lastUsed), { title: whenFull(token.lastUsed) }),
          fact(t("Expires"), token.expires ? when(token.expires) : t("Never"), token.expires ? { title: whenFull(token.expires) } : {})),
        el("div", { class: "card-foot" },
          el("span", { class: expired ? "pill status bad" : "muted", text: expired ? t("Expired") : "" }),
          menuButton(t("Actions for the token {name}", { name: token.name }), () => [
            { label: t("Revoke"), icon: "trash", danger: true, onSelect: async () => {
              if (!await HomeswiftCommon.confirmDialog(t("Revoke the token “{name}”? Scripts using it are refused at once.", { name: token.name }))) return;
              try { await api(`/api/tokens/${encodeURIComponent(token.id)}`, { method: "DELETE" }); route(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
            } },
          ])));
    });
    grid.append(...(cards.length ? cards : [el("div", { class: "card empty" },
      el("p", { class: "muted", text: t("No tokens yet. One lets a script or another program read the bridge, or change it as an administrator would.") }))]));
    return el("section", {},
      el("div", { class: "section-head" },
        el("div", {}, titleWithAdd("h2", t("API tokens"), t("Create token"), openTokenForm),
          el("span", { class: "muted" }, withNodes(t("For scripts: {header} on {path}"), { header: el("code", { text: "Authorization: Bearer <token>" }), path: el("code", { text: "/api/*" }) })))),
      grid);
  }

  const appearanceLink = () => el("a", { class: "card link-card", href: "/appearance" }, HomeswiftCommon.icon("sliders"),
    el("div", { class: "who" }, el("strong", { text: t("Appearance") }), el("div", { class: "muted", text: t("Light or dark, the wallpaper, °C or °F, the language") })));

  // ---- Appearance ------------------------------------------------------------
  // /appearance: the theme (as the system, light or dark), a wallpaper (one of the UI's, or an image of your own)
  // and the temperature unit, as Glass UI offers them. Each user's own, saved on the bridge (/api/preferences) and
  // applied at once, on every page, plugins' included.

  const wallpaperChoices = [["none", t("None")], ["aurora", t("Aurora")], ["sunset", t("Sunset")], ["ocean", t("Ocean")], ["forest", t("Forest")], ["graphite", t("Graphite")], ["silk", t("Silk")], ["prism", t("Prism")], ["ribbon", t("Ribbon")], ["lagoon", t("Lagoon")], ["ember", t("Ember")], ["midnight", t("Midnight")]];

  views.appearance = async (main) => {
    let preferences = await HomeswiftCommon.loadPreferences();
    const message = el("p", { class: "status-line muted", role: "status" });
    const choose = async (change) => {
      message.className = "status-line muted";
      message.textContent = t("Saving…");
      try {
        preferences = HomeswiftCommon.applyPreferences(await api("/api/preferences", { method: "PUT", body: change }));
        message.textContent = t("Saved for your account, on every browser.");
        draw();
      } catch (e) { message.className = "status-line error"; message.textContent = e.message; }
    };
    const segmented = (label, value, options, key) => el("div", { class: "group", role: "radiogroup", "aria-label": label },
      options.map(([option, text]) => el("button", { type: "button", role: "radio", actionIcon: key === "language" ? undefined : key === "temperatureUnit" ? "thermo" : "sun", class: option === value ? "on" : "", "aria-checked": String(option === value),
        onclick: () => { if (option !== value) choose({ [key]: option }); } }, key === "language" ? flag(option === "auto" ? null : option) : null, el("span", { text }))));

    const picker = el("input", { type: "file", accept: "image/jpeg,image/png,image/webp", multiple: true, class: "hidden" });
    /// Wallpapers of the viewer's own, from the picker or dropped on the zone, one after the other: the bridge
    /// shows each it adds, so the last is the wallpaper.
    const useImages = async (files) => {
      if (!files.length) return;
      message.className = "status-line muted";
      let added = 0;
      try {
        for (const file of files) {
          message.textContent = files.length > 1 ? t("Preparing image {n} of {count}…", { n: added + 1, count: files.length }) : t("Preparing the image…");
          const data = await scaledImage(file);
          preferences = HomeswiftCommon.applyPreferences(await api("/api/preferences/wallpaper", { method: "PUT", body: { data } }));
          added++;
        }
        message.textContent = added > 1 ? tn("{n} image added; the last is the wallpaper now.", "{n} images added; the last is the wallpaper now.", added) : t("Your image is the wallpaper now.");
      } catch (e) { message.className = "status-line error"; message.textContent = e.message; }
      draw();
    };
    picker.addEventListener("change", () => { const files = [...picker.files]; picker.value = ""; useImages(files); });
    const imageZone = () => {
      const zone = el("div", { class: "drop-zone wallpaper-drop", role: "button", tabIndex: 0, "aria-label": t("Drop or choose images for the wallpaper") },
        HomeswiftCommon.icon("image"), el("span", {}, t("Drop images here, or "), el("strong", { text: t("choose them [images]") })));
      zone.addEventListener("click", () => picker.click());
      zone.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); picker.click(); } });
      zone.addEventListener("dragover", (event) => {
        if (![...(event.dataTransfer?.types ?? [])].includes("Files")) return;
        event.preventDefault();
        zone.classList.add("over");
      });
      zone.addEventListener("dragleave", () => zone.classList.remove("over"));
      zone.addEventListener("drop", (event) => { event.preventDefault(); zone.classList.remove("over"); useImages([...(event.dataTransfer?.files ?? [])]); });
      return zone;
    };
    const body = el("div", { class: "appearance" });
    function draw() {
      const own = preferences.wallpaperImages || [];
      const shown = preferences.wallpaper === "custom" ? preferences.wallpaperImage : null;
      // Each image of the viewer's own: its tile chooses it, its ✕ removes it (beside the tile: a button holds no button).
      const ownTile = (id, index) => {
        const name = own.length > 1 ? t("Your image {n}", { n: index + 1 }) : t("Your image");
        const choice = el("button", { type: "button", role: "radio", class: `wallpaper-choice${shown === id ? " on" : ""}`, "aria-checked": String(shown === id),
          onclick: () => { if (shown !== id) choose({ wallpaper: "custom", wallpaperImage: id }); } },
          el("span", { class: "wallpaper-swatch", style: `background: url("/api/preferences/wallpaper/${encodeURIComponent(id)}") center / cover no-repeat` }), el("span", { text: name }));
        const remove = own.length > 1 ? t("Remove your image {n}", { n: index + 1 }) : t("Remove your image");
        return el("div", { class: "wallpaper-own" }, choice,
          el("button", { type: "button", class: "wallpaper-remove", "aria-label": remove, title: remove, onclick: async () => {
            try { preferences = HomeswiftCommon.applyPreferences(await api(`/api/preferences/wallpaper/${encodeURIComponent(id)}`, { method: "DELETE" })); draw(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
          } }, HomeswiftCommon.icon("close")));
      };
      body.replaceChildren(
        el("div", { class: "card" }, el("h2", { class: "appearance-card-title" }, HomeswiftCommon.icon("sun"), el("span", { text: t("Theme") })),
          el("p", { class: "muted", text: t("Automatic follows the system's light or dark appearance.") }),
          segmented(t("Theme"), preferences.theme, [["auto", t("Automatic")], ["light", t("Light")], ["dark", t("Dark")]], "theme")),
        el("div", { class: "card" }, el("h2", { class: "appearance-card-title" }, HomeswiftCommon.icon("image"), el("span", { text: t("Wallpaper") })),
          el("p", { class: "muted", text: t("Behind the glass of every page.") }),
          el("div", { class: "wallpapers", role: "radiogroup", "aria-label": t("Wallpaper") },
            wallpaperChoices.map(([value, text]) =>
              el("button", { type: "button", role: "radio", class: `wallpaper-choice${preferences.wallpaper === value ? " on" : ""}`, "aria-checked": String(preferences.wallpaper === value),
                onclick: () => { if (preferences.wallpaper !== value) choose({ wallpaper: value }); } },
                el("span", { class: "wallpaper-swatch", "data-swatch": value }), el("span", { text }))),
            own.map(ownTile)),
          imageZone(),
          picker),
        el("div", { class: "card" }, el("h2", { class: "appearance-card-title" }, HomeswiftCommon.icon("thermo"), el("span", { text: t("Temperatures") })),
          el("p", { class: "muted", text: t("How accessories and plugin pages show them. HomeKit and the Home app keep their own setting.") }),
          segmented(t("Temperature unit"), preferences.temperatureUnit, [["c", t("Celsius (°C)")], ["f", t("Fahrenheit (°F)")]], "temperatureUnit")),
        el("div", { class: "card" }, el("h2", { class: "appearance-card-title" }, HomeswiftCommon.icon("globe"), el("span", { text: t("Language") })),
          el("p", { class: "muted", text: t("The pages' language and the one the Assistant answers in. Automatic follows the browser.") }),
          // Each language in its own name, so whoever reads the page finds theirs.
          segmented(t("Language"), preferences.language || "auto",
            [["auto", t("Automatic")], ...HomeswiftI18n.languages.map((code) => [code, HomeswiftI18n.names[code]])], "language")));
    }
    draw();
    show(main, pageHead(t("Appearance"), t("How the web UI looks for you, on every browser you sign in to.")), body, message);
  };

  /// An image as base64 JPEG, at most 2560 pixels on its long side: a photo from a phone is several MB.
  async function scaledImage(file) {
    if (!/^image\/(jpeg|png|webp)$/.test(file.type)) throw new Error(t("Choose a JPEG, PNG or WebP image."));
    const bitmap = await createImageBitmap(file);
    const canvas = HomeswiftCommon.scaledCanvas(bitmap, 2560);
    bitmap.close?.();
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
    if (!blob) throw new Error(t("The image could not be read."));
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  }

  // ---- Config --------------------------------------------------------------

  /// "Line 12", a link that puts the caret there: for a syntax error or a problem the editor placed.
  const lineLink = (place, editor) => place.line && editor
    ? [el("button", { type: "button", class: "line-link", text: t("Line {line}", { line: place.line }), onclick: () => editor.reveal(place.offset) })] : [];

  /// A save's schema problems, `{ text, line?, offset? }`, each with its line when the editor shows it.
  const problemList = (items, editor) => el("ul", { class: "schema-problems" }, items.map((item) => el("li", {}, ...lineLink(item, editor), item.text)));

  /// The whole config.json, a tab of Settings (`/settings/config`; `/config` leads there).
  async function configPage(main, subnav) {
    let saved;
    // The plugins' list for the secret rule only; an older bridge without it leaves the keys unmarked.
    [saved, secretRule] = await Promise.all([api("/api/config", { raw: true }), api("/api/plugins").then(readSecretRule, () => null)]);
    const textarea = el("textarea", { value: saved, spellcheck: false, "aria-label": "config.json" });
    const check = el("span", { class: "muted" });
    const message = el("p", { class: "status-line muted" });
    const save = el("button", { class: "primary settings-action", disabled: true }, HomeswiftCommon.icon("check"), el("span", { text: t("Save") }));
    const force = el("button", { actionIcon: "check", class: "hidden", text: t("Save anyway"), title: t("Save what the plugins' schemas refuse: for a value a plugin accepts that its schema does not list") });
    const revert = el("button", { class: "settings-action", disabled: true }, HomeswiftCommon.icon("restore"), el("span", { text: t("Revert") }));
    const format = el("button", { class: "link settings-action" }, HomeswiftCommon.icon("code"), el("span", { text: t("Format") }));
    // Validity and the unsaved state follow every keystroke, so Save is only offered when it can work; a syntax
    // error marks its line.
    const update = () => {
      const dirty = textarea.value !== saved;
      const result = editor.check();
      const valid = "value" in result;
      if (valid) { check.className = "ok"; check.textContent = dirty ? t("Valid JSON · unsaved") : t("Saved"); }
      else { check.className = "error"; check.replaceChildren(...lineLink(result, editor), result.message); }
      save.disabled = !dirty || !valid;
      revert.disabled = !dirty;
    };
    const doSave = async (anyway = false) => {
      if (save.disabled) return;
      save.disabled = true;
      force.classList.add("hidden");
      try {
        const result = await api(`/api/config${anyway ? "?force=true" : ""}`, { method: "PUT", body: JSON.parse(textarea.value) });
        message.className = "status-line ok";
        message.textContent = result.changes.length ? t("Changed: {changes}. {result}", { changes: result.changes.map((change) => HomeswiftI18n.message(change)).join(", "), result: savedText(result) })
          : t("Changed: nothing. {result}", { result: savedText(result) });
        saved = await api("/api/config", { raw: true });
        textarea.value = saved;
        editor.repaint();
      } catch (e) {
        message.className = "status-line error";
        if (e.problems) {
          // Each problem on its line; the plugin may accept what its schema does not list, so saving anyway stays possible.
          const places = editor.markPaths(e.problems.map((problem) => problem.path));
          message.replaceChildren(el("span", { text: t("The plugins' schemas refuse this:") }), problemList(e.problems.map((problem, i) => ({ ...places[i], text: t("{platform}: {problem}", { platform: problem.platform, problem: HomeswiftI18n.message(problem.text) }) })), editor));
          force.classList.remove("hidden");
          update();
          save.disabled = true;
          return;
        }
        message.textContent = e.message;
      }
      update();
    };
    textarea.addEventListener("input", () => { force.classList.add("hidden"); message.textContent = ""; update(); });
    textarea.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "s") { event.preventDefault(); doSave(); }
      if (event.key === "Tab" && !event.shiftKey) { event.preventDefault(); textarea.setRangeText("  ", textarea.selectionStart, textarea.selectionEnd, "end"); update(); }
    });
    save.addEventListener("click", () => doSave());
    force.addEventListener("click", () => { save.disabled = false; doSave(true); });
    revert.addEventListener("click", () => { textarea.value = saved; message.textContent = ""; force.classList.add("hidden"); editor.repaint(); update(); });
    const editor = jsonEditor(textarea, { secretKey: isSecretKey });
    // Secrets only: everything else folded, a second press (or Show all) opens it all again. The editor says when it
    // holds, so opening a fold, Format or Revert turn the button off and the strip above the text goes.
    const secretsOnly = el("button", { class: "settings-action secrets-only", "aria-pressed": "false", title: t("Fold everything that holds no secret"), hidden: !secretRule,
      onclick: () => (secretsOnly.getAttribute("aria-pressed") === "true" ? editor.openAll() : editor.foldAllButSecrets()) },
      HomeswiftCommon.icon("lock"), el("span", { text: t("Secrets only") }));
    const secretsNote = el("span");
    const secretsBanner = el("div", { class: "secrets-banner", role: "status", hidden: true }, HomeswiftCommon.icon("lock"), secretsNote,
      el("button", { type: "button", actionIcon: "eye", text: t("Show all"), onclick: () => { editor.openAll(); textarea.focus({ preventScroll: true }); } }));
    editor.addEventListener("folds", ({ detail }) => {
      secretsOnly.setAttribute("aria-pressed", String(detail.secretsOnly));
      secretsOnly.title = detail.secretsOnly ? t("Show all") : t("Fold everything that holds no secret");
      secretsNote.textContent = detail.secrets ? tn("{n} secret shown, the rest folded", "{n} secrets shown, the rest folded", detail.secrets) : t("No secrets in this file");
      secretsBanner.hidden = !detail.secretsOnly;
    });
    format.addEventListener("click", () => { try { textarea.value = JSON.stringify(JSON.parse(textarea.value), null, 2); editor.repaint(); update(); } catch {} });
    update();
    show(main,
      pageHead(t("Settings"), t("The whole config.json. Saving validates it, keeps a backup of the previous file (the last 20 under backups/), and applies it at once.")),
      subnav,
      el("div", { class: "card editor-card" },
        el("div", { class: "editor-bar" }, el("span", { class: "mono muted file-name", text: "config.json" }), check, el("span", { class: "spacer" }), secretsOnly, format, revert, force, save),
        secretsBanner, editor, message));
  }

  // ---- Logs ----------------------------------------------------------------

  const levelRank = { trace: 0, debug: 1, info: 2, notice: 3, warning: 4, error: 5, critical: 6 };
  // The server's caps: the latest lines (/api/logs) and a time range (UIServer.logLimit).
  const latestLines = 2000, rangeLines = 10000;
  const timeFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  /// A line with what filtering reads, worked out once: its date and its text in lower case, its payload included.
  const prepared = (line) => Object.assign(line, { date: new Date(line.time), haystack: `${line.label} ${line.text} ${line.details ?? ""}`.toLowerCase() });
  // All: every line; Info: info and above; Warnings: warnings only; Errors: errors only (critical ones too).
  const levelChoices = [["trace", t("All")], ["info", t("Info")], ["warning", t("Warnings")], ["error", t("Errors")]];
  const levelShown = (level, choice) => choice === "warning" ? level === "warning" : (levelRank[level] ?? 0) >= (levelRank[choice] ?? 0);
  let logState = null;

  // The Logs and Status pages' filters, in one row above what they scope.
  /// What the data is about, one menu: everything (`everything` names it); the bridges, every bridge's own lines
  /// (`allBridges`) or one's; or one accessory, grouped by plugin. Values: "", "bridge:all", "bridge:<device ID>",
  /// "accessory:<id>". `changed` runs on a choice; `source()` reads it as a kind and a value.
  function sourceFilter(accessories, bridges, initial, { label, everything, allBridges = false, plugins = [], changed }) {
    const option = (value, text) => el("option", { value, text, selected: value === initial });
    const picker = el("select", { class: `popup ${initial ? "chosen" : ""}`, "aria-label": label },
      option("", everything),
      bridges.length ? el("optgroup", { label: t("Bridges") }, allBridges ? option("bridge:all", t("Bridges only")) : null,
        bridges.map((bridge) => option(`bridge:${bridge.deviceId}`, bridge.external ? t("{name} · its own server", { name: bridge.name }) : bridge.childBridge ? t("{name} · child bridge", { name: bridge.name }) : bridge.name))) : null,
      // A plugin's own lines: its pairing, its devices and clouds, its errors (the lines it writes, labelled with its name).
      plugins.length ? el("optgroup", { label: t("Plugins") }, plugins.map((plugin) => option(`plugin:${plugin.name}`, plugin.name))) : null,
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

  /// The source menu's value for an address: an accessory by its slug or id, a plugin by its slug, name or platform (a
  /// plugin's page links to `/logs/<platform>`), a bridge by its slug, or `all`.
  function initialSource(accessories, bridges, accessory, bridge, plugins = [], plugin = null) {
    const found = accessory && accessories.find((one) => one.slug === accessory || one.id === accessory);
    if (found) return `accessory:${found.id}`;
    const named = (wanted) => wanted && plugins.find((one) => [one.slug, one.name, one.platform].some((key) => key?.toLowerCase() === wanted.toLowerCase()));
    const owner = named(plugin) || named(accessory);
    if (owner) return `plugin:${owner.name}`;
    if (bridge === "all") return "bridge:all";
    const one = bridge && bridges.find((candidate) => candidate.slug === bridge);
    return one ? `bridge:${one.deviceId}` : "";
  }

  // /logs/<accessory>?bridge=<bridge>&since=24h&level=warning&q=text: the accessory by its slug (a plugin's page
  // may give its id), the bridge by its slug,
  // the range (latest, 1h, 6h, 24h, today, yesterday, 7d, or custom with from= and to=), the lowest level and the
  // text. The address follows what is chosen, so it can be kept or shared.
  views.logs = async (main, [wanted] = []) => {
    const [accessories, bridges, plugins] = await Promise.all([
      api("/api/accessories").then((list) => withSlugs(list, "accessory")).catch(() => []),
      api("/api/status").then((status) => withSlugs(status.bridges, "bridge")).catch(() => []),
      // The plugins (not the UI's or the Assistant's blocks): their lines carry their name.
      api("/api/plugins").then((answer) => (answer.blocks ?? []).filter((block) => !block.system)).catch(() => []),
    ]);
    const params = new URLSearchParams(location.search);
    const output = el("div", { class: "log", role: "log", "aria-live": "off" });
    const filter = el("input", { type: "search", class: "search", placeholder: t("Filter text"), "aria-label": t("Filter the log") });
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
    const sources = sourceFilter(accessories, bridges, initialSource(accessories, bridges, wanted, params.get("bridge"), plugins, params.get("plugin")), {
      label: t("What the lines are about"), everything: t("All lines"), allBridges: true, plugins, changed: () => { choose(); load(); } });
    const source = sources.source;
    const choose = () => {
      const { kind, value } = source();
      logState.accessory = kind === "accessory" ? termsFor(value) : null;
      logState.bridge = kind === "bridge" ? bridgeFor(value) : kind === "plugin" ? (line) => line.label === value : null;
    };
    // `live`: new lines join the page (not while a span in the past is shown); `cap`: how many it keeps.
    filter.value = params.get("q") ?? "";
    const level = levelChoices.some(([value]) => value === params.get("level")) ? params.get("level") : "info";
    logState = { output, level, filter, follow, count, lines: [], accessory: null, bridge: null, live: true, cap: latestLines, capped: false };
    choose();
    const levels = el("div", { class: "group", role: "group", "aria-label": t("Levels shown") }, levelChoices.map(([level, text]) =>
      el("button", { text, class: level === logState.level ? "on" : "", "aria-pressed": String(level === logState.level), onclick: (event) => {
        logState.level = level;
        for (const button of levels.children) { button.classList.toggle("on", button === event.currentTarget); button.setAttribute("aria-pressed", String(button === event.currentTarget)); }
        render();
        keepAddress();
      } })));
    const updateLevelCounts = () => {
      const needle = filter.value.toLowerCase();
      for (const [index, button] of [...levels.children].entries()) {
        const [level, label] = levelChoices[index];
        const count = logState.lines.filter((line) => visible(line, needle, level)).length;
        button.replaceChildren(el("span", { class: "log-level-name", text: label }), el("span", { class: "log-level-count", text: String(count) }));
        button.setAttribute("aria-label", `${label} (${count})`);
        button.disabled = count === 0 && level !== "trace" && level !== logState.level;
        button.title = button.disabled ? t("No log lines match the current search.") : "";
      }
    };
    logState.updateCounts = updateLevelCounts;
    const render = () => {
      updateLevelCounts();
      const shown = shownLines();
      output.replaceChildren(...(shown.length ? shown.map(lineNode) : [el("p", { class: "muted empty-log", text: t("No line matches.") })]));
      count.textContent = logState.capped ? tn("{shown} of {n} line (the latest of the range)", "{shown} of {n} lines (the latest of the range)", logState.lines.length, { shown: shown.length })
        : tn("{shown} of {n} line", "{shown} of {n} lines", logState.lines.length, { shown: shown.length });
      if (follow.checked) output.scrollTop = output.scrollHeight;
    };
    // Typing filters once it pauses: thousands of lines are not drawn again per key.
    let typing = null;
    filter.addEventListener("input", () => { clearTimeout(typing); typing = setTimeout(() => { render(); keepAddress(); }, 120); });
    follow.addEventListener("change", () => { if (follow.checked) output.scrollTop = output.scrollHeight; });

    // A time range (HomeswiftCommon.rangeControl): the latest lines from memory, or a span from the log the bridge keeps on disk
    // (rotated, a week at most). A span that ends now keeps following; one in the past stays as it is.
    const range = HomeswiftCommon.rangeControl(params, { presets: [["latest", t("Latest lines")], ["1h", t("1 hour")], ["6h", t("6 hours")], ["24h", t("24 hours")],
      ["today", t("Today")], ["yesterday", t("Yesterday")], ["7d", t("7 days")]], fallback: "latest", earliestDays: 7, changed: () => load() });
    /// The address of what is shown, in place: no new history entry per choice.
    function keepAddress() {
      const query = new URLSearchParams();
      range.address(query);
      if (logState.level !== "info") query.set("level", logState.level);
      if (filter.value) query.set("q", filter.value);
      const { kind, value } = source();
      const bridge = kind === "bridge" ? bridges.find((b) => b.deviceId === value) : null;
      if (kind === "bridge") query.set("bridge", bridge ? bridge.slug : "all");
      const plugin = kind === "plugin" ? plugins.find((one) => one.name === value) : null;
      if (plugin) query.set("plugin", plugin.slug);
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
    const saveToggle = el("label", { class: "toggle compact hidden save-payloads", title: t("Keep each line's JSON payload in the log on disk, secrets masked, so you and the Assistant can read it later. Off: only the latest lines, in memory, have it.") },
      el("span", { class: "switch" }, saveDetails, el("span")), el("span", { text: t("Save payloads") }));
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
        HomeswiftCommon.showAlert(e.message);
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
    const copy = el("button", { actionIcon: "copy", text: t("Copy"), title: t("Copy the lines shown"), onclick: async () => {
      const shown = shownLines();
      const text = shown.map(asText).join("\n");
      try {
        await copyText(text);
        copy.textContent = tn("Copied {n} line", "Copied {n} lines", shown.length);
      } catch (e) {
        copy.textContent = t("Not copied");
        copy.title = e.message;
      }
      setTimeout(() => { copy.textContent = t("Copy"); copy.title = t("Copy the lines shown"); }, 1800);
    } });
    // Log Doctor: the Assistant reads the lines shown and groups the issues, with causes and fixes.
    // The Logs page is an administrator's; its Assistant and file actions too.
    const doctor = logDoctor(() => shownLines().slice(-3000).map(asText), () => {
      const about = sources.picker.selectedOptions[0];
      return [sources.picker.value && about ? `the lines about ${about.textContent}` : "", filter.value ? `lines matching "${filter.value}"` : ""].filter(Boolean).join(", ");
    });
    // Download: the range shown (everything kept for the latest lines); Empty: the log in memory and on disk.
    const actions = menuButton(t("Log actions"), () => {
      const chosen = range.span();
      const query = new URLSearchParams();
      if (chosen) { query.set("from", chosen[0].toISOString()); if (chosen[1]) query.set("to", chosen[1].toISOString()); }
      // A phone keeps the toolbar short: Save payloads is here rather than beside Follow.
      const phone = matchMedia("(max-width: 640px)").matches && !saveToggle.classList.contains("hidden");
      return [
        phone ? { label: t("Save payloads"), checked: saveDetails.checked, onSelect: () => { saveDetails.checked = !saveDetails.checked; saveDetails.dispatchEvent(new Event("change")); } } : null,
        phone ? { separator: true } : null,
        { label: chosen ? t("Download this range") : t("Download the whole log"), icon: "download", href: `/api/logs/download${query.size ? `?${query}` : ""}` },
        { label: t("Empty the log…"), icon: "trash", danger: true, onSelect: async () => {
          if (!await HomeswiftCommon.confirmDialog(t("Empty the log? Every line goes, in memory and the files kept on disk (up to a week). This cannot be undone."))) return;
          try { await api("/api/logs/truncate", { method: "POST", body: {} }); await load(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
        } },
      ];
    });
    show(main,
      pageHead(t("Logs"), t("This homeswift's log, live, and up to a week back.")),
      el("div", { class: "card log-card" },
        el("div", { class: "log-filter-panel" },
          el("div", { class: "log-level-row" }, levels, filter, HomeswiftCommon.clearFilters([[filter, ""], [sources.picker, ""]], {
            active: () => logState.level !== "info" || range.chosen(), events: [[levels, "click"], [range.control, "change"]],
            reset: () => {
              clearTimeout(typing);
              range.reset();
              logState.level = "info";
              for (const [index, button] of [...levels.children].entries()) {
                const selected = levelChoices[index][0] === "info";
                button.classList.toggle("on", selected); button.setAttribute("aria-pressed", String(selected));
              }
            },
          })),
          // A div, not a label: a label would press the control's first choice when its text is clicked.
          el("div", { class: "log-scope-row" },
            el("div", { class: "log-time" }, el("span", { text: t("Time range") }), range.control),
            el("label", {}, el("span", { text: t("What the lines are about") }), sources.picker))),
        el("div", { class: "editor-bar log-action-bar" }, count, el("span", { class: "spacer" }), doctor.button, copy,
          el("label", { class: "toggle compact" }, el("span", { class: "switch" }, follow, el("span")), el("span", { text: t("Follow") })),
          saveToggle, actions),
        output),
      doctor.card);
    await load();
  };

  /// Log Doctor (Glass UI's): a Diagnose button and the card the diagnosis streams into. `lines()` gives the
  /// lines to read, `focus()` what they were picked by. Hidden while the Assistant is off.
  function logDoctor(lines, focus) {
    const button = el("button", { class: "ai-button icon-on-phone hidden", "aria-label": t("Diagnose"), title: t("The Assistant reads the lines shown and groups the issues, with causes and fixes") }, sparkle(), el("span", { text: t("Diagnose") }));
    const card = el("div", { class: "ai-card log-doctor hidden", role: "region", "aria-label": t("Log Doctor"), "aria-live": "polite" });
    api("/api/assistant").then((state) => { if (state?.enabled) button.classList.remove("hidden"); }).catch(() => {});
    let controller = null;
    button.addEventListener("click", async () => {
      const picked = lines();
      if (!picked.length) { HomeswiftCommon.showAlert(t("No line is shown: widen the range or the filters first.")); return; }
      controller?.abort();
      const own = controller = new AbortController();
      let closed = false;
      const live = el("div", { class: "ai-live" }, el("p", { class: "ai-thinking", text: tn("Reading {n} line…", "Reading {n} lines…", picked.length) }));
      const stop = el("button", { actionIcon: "pause", class: "link", text: t("Stop"), onclick: () => own.abort() });
      const close = el("button", { class: "ai-close", title: t("Close"), "aria-label": t("Close the diagnosis"), text: "×", onclick: () => { closed = true; own.abort(); card.classList.add("hidden"); } });
      const head = el("div", { class: "ai-head" }, sparkle(), el("span", { class: "ai-label", text: t("Log Doctor") }), el("span", { class: "spacer" }), close);
      card.className = "ai-card log-doctor thinking";
      card.replaceChildren(el("div", { class: "ai-inner" }, head, live, stop));
      card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
      button.disabled = true;
      try {
        const reply = await HomeswiftCommon.assistantRequest("/api/assistant/diagnose", { lines: picked, focus: focus() || undefined }, {
          signal: own.signal, onChunk: streamInto(live) });
        card.className = "ai-card log-doctor answered";
        live.replaceChildren(HomeswiftCommon.markdown(reply.text));
        stop.replaceWith(el("p", { class: "muted ai-note", text: tn("{model} read {n} line. Secrets and addresses were masked first; check its advice before acting on it.", "{model} read {n} lines. Secrets and addresses were masked first; check its advice before acting on it.", reply.lines, { model: reply.model }) }));
      } catch (e) {
        card.className = `ai-card log-doctor failed${closed ? " hidden" : ""}`;
        stop.remove();
        live.replaceChildren(el("p", { class: own.signal.aborted ? "muted" : "error", text: own.signal.aborted ? t("Stopped.") : e.message }));
      } finally {
        button.disabled = false;
        if (controller === own) controller = null;
      }
    });
    return { button, card };
  }

  /// Whether a prepared line passes the level, the text (`needle`, in lower case) and the accessory.
  function visible(line, needle = logState.filter.value.toLowerCase(), level = logState.level) {
    return levelShown(line.level, level) && (!needle || line.haystack.includes(needle))
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
    const toggle = el("button", { type: "button", class: "log-details-toggle", text: "JSON", title: t("Show the payload") });
    const show = () => {
      toggle.setAttribute("aria-expanded", String(Boolean(line.open)));
      toggle.title = line.open ? t("Hide the payload") : t("Show the payload");
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
    logState.updateCounts?.();
    if (!visible(line)) return;
    const output = logState.output;
    // Follow only when the reader is at the bottom: scrolling up to read stops it without a click.
    const atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
    $(".empty-log", output)?.remove();
    output.append(lineNode(line));
    while (output.childElementCount > logState.cap) output.firstElementChild.remove();   // the page stays the size of what it keeps
    if (logState.follow.checked && atBottom) output.scrollTop = output.scrollHeight;
    logState.count.textContent = tn("{shown} of {n} line", "{shown} of {n} lines", logState.lines.length, { shown: output.childElementCount });
  }

  // A hidden tab keeps no stream open; back in view, the live pages reload their values.
  document.addEventListener("visibilitychange", () => {
    if (!(auth && auth.authenticated)) return;
    if (document.hidden) { closeEvents(); return; }
    openEvents();
    if (location.pathname === "/accessories" && document.querySelector(".wall.editing")) return;
    if (["/", "/status", "/accessories", "/quick"].includes(location.pathname)) route();
  });

  // The views of home.js: rooms, Quick Controls, scenes, notifications.
  // An accessory's widget at its kind's size, for the Quick Controls.
  const accessoryCard = (accessory) => HomeswiftWidgets.card(accessory, { size: HomeswiftWidgets.kindOf(accessory).size, actions: accessoryActions });
  // The Homebridge import (import.js): its page at /import and the welcome page at /welcome.
  views.import = (main) => window.HomeswiftImport.view(main);
  views.welcome = (main) => window.HomeswiftImport.welcome(main);
  window.HomeswiftHome?.install({
    views, api, show, pageHead, breadcrumb, accessoryCard, navigate, route: () => route(), isAdmin,
    enumLabels: HomeswiftWidgets.enumLabels, labelFor: HomeswiftWidgets.labelFor, withSlugs,
  });
  // The Settings pages (admin.js) draw with the same helpers.
  window.HomeswiftApp = { api, navigate, route, finder, pageHead, breadcrumb, show, savedText, waitForRestart, updateCard, updatePhase, restartBridge, formatDuration, setLeaveGuard: (guard) => { leaveGuard = guard; }, assistantPage, configPage };

  loadAuth().catch((e) => { $("#auth").classList.remove("hidden"); $("#auth-error").textContent = e.message; });
})();
