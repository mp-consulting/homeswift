// For a plugin's own pages, served at /plugins/<slug> after common.js: homeswift.request() talks to the plugin
// instance the server names in the page (<meta name="homeswift-plugin">), with the session cookie; homeswift.el(), .$(), .tile() and .fact() are
// the UI's own (common.js). A signed-out visitor is sent to the login page.
(() => {
  "use strict";
  const instance = document.querySelector('meta[name="homeswift-plugin"]')?.dataset ?? {};
  const platform = instance.platform || "";
  const name = instance.name || platform;
  /// The page's address, /plugins/<slug>: its Settings are at /plugins/<slug>/settings.
  const address = `/plugins/${location.pathname.split("/")[2] || ""}`;
  /// Where this instance's settings are edited (its Plugin Settings and its devices), and one accessory's there (its
  /// Accessory Settings, over the page): a page links to them and writes no settings itself.
  const settingsAddress = `${address}/settings`;
  const accessorySettings = (accessoryID) => `${settingsAddress}?accessory=${encodeURIComponent(accessoryID)}`;

  /// Loads one of the UI's scripts once (forms.js, settings.js), for what a page opens only now and then.
  const scripts = new Map();
  const loadScript = (src) => {
    if (!scripts.has(src)) {
      scripts.set(src, new Promise((resolve, reject) => {
        document.head.append(el("script", { src, onload: resolve, onerror: () => { scripts.delete(src); reject(new Error(src)); } }));
      }));
    }
    return scripts.get(src);
  };

  /// An accessory's Settings in the UI's side sheet, over this page (the generic editor settings.js draws on the wall's
  /// ⋯ and the Settings page): a page shows it rather than sending the person away, and still writes no settings itself.
  /// `after(changed)` runs once it has gone, with whether anything was saved. Falls back to the Settings page when the
  /// editor cannot load.
  async function openAccessorySettings({ accessoryID, name: title = null, glyph = "accessory", trigger = null, after = null }) {
    try {
      await loadScript("/forms.js");
      await loadScript("/settings.js");
      await HomeswiftForms.loadSecretRule();
    } catch {
      location.href = accessorySettings(accessoryID);
      return;
    }
    HomeswiftSettings.openAccessory({ accessoryID, instance: name, name: title, glyph, trigger, after: (changed) => after?.(changed) });
  }

  // Every plugin's accessory Settings link opens over its current page, including links in menus.
  // Preserve modified clicks and explicit new-tab links as normal navigation.
  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest?.("a[href]");
    if (!link || link.hasAttribute("download") || (link.target && link.target !== "_self")) return;
    const url = new URL(link.href, location.href);
    const accessoryID = url.searchParams.get("accessory");
    if (url.origin !== location.origin || url.pathname !== settingsAddress || !accessoryID) return;
    event.preventDefault();
    openAccessorySettings({ accessoryID, trigger: link.isConnected ? link : document.activeElement });
  });
  const prefix = `/api/plugins/${encodeURIComponent(platform)}/${encodeURIComponent(name)}/`;

  const { $, el, icon, tile, fact, markdown, sparkle, api, assistantRequest, formatTemperature, temperature } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;

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
      const button = el("button", { class: "ai-button", title: t("Ask the Assistant ({provider})", { provider: state.provider }) }, sparkle(), el("span", { text: t("Explain") }));
      const card = el("div", { class: "ai-card hidden", role: "region", "aria-label": t("The Assistant's explanation"), "aria-live": "polite" });
      const show = (entry) => {
        card.classList.remove("hidden", "thinking", "answered", "failed");
        button.classList.add("hidden");
        const close = el("button", { class: "ai-close", title: t("Close"), "aria-label": t("Close the explanation"), text: "×", onclick: () => {
          card.classList.add("hidden");
          button.classList.remove("hidden");
        } });
        const head = (label) => el("div", { class: "ai-head" }, sparkle(), el("span", { class: "ai-label", text: label }), el("span", { class: "spacer" }), close);
        if (entry.pending) {
          card.classList.add("thinking");
          // The answer as it is written, once it starts.
          const live = el("div", { class: "ai-live" }, entry.text ? markdown(entry.text) : el("p", { class: "ai-thinking", text: t("Thinking about it…") }));
          entry.draw = () => { if (live.isConnected) live.replaceChildren(markdown(entry.text)); };
          card.replaceChildren(el("div", { class: "ai-inner" }, head(t("Assistant")), live));
          entry.pending.finally(() => { if (document.body.contains(card) && !card.classList.contains("hidden")) show(explanations.get(error)); });
          return;
        }
        if (entry.failed) {
          card.classList.add("failed");
          card.replaceChildren(el("div", { class: "ai-inner" }, head(t("Assistant")),
            el("p", { class: "error", text: entry.failed }),
            el("button", { actionIcon: "restore", class: "link", text: t("Try again"), onclick: () => { explanations.delete(error); explainNow(); } })));
          return;
        }
        card.classList.add("answered");
        const body = markdown(entry.text);
        body.classList.add("ai-body");
        const more = el("button", { actionIcon: "eye", class: "link ai-more", text: t("Show more"), onclick: () => {
          body.classList.toggle("clamped");
          more.textContent = body.classList.contains("clamped") ? t("Show more") : t("Show less");
        } });
        card.replaceChildren(el("div", { class: "ai-inner" }, head(t("Assistant · {model}", { model: entry.model || state.model })), body, more));
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
    const userRole = el("span", { class: "user-role", text: t("No sign-in") });
    const user = el("button", { id: "user", type: "button", class: "user-button", "aria-haspopup": "menu", "aria-expanded": "false", "aria-label": t("Account menu") },
      avatar, el("span", { class: "user-text" }, userName, userRole), el("span", { class: "user-chevron", "aria-hidden": "true" }, HomeswiftCommon.icon("selector")));
    const shownName = () => (auth.mode === "form" ? (auth.name && auth.name !== auth.username ? auth.name : auth.username || "") : "");
    user.addEventListener("click", (event) => {
      event.stopPropagation();
      const form = auth.mode === "form";
      HomeswiftCommon.menu(user, [
        form ? { heading: shownName(), detail: auth.admin ? t("{username} · Administrator", { username: auth.username }) : auth.username } : { heading: t("No sign-in"), detail: t("Anyone who opens this web UI uses it") },
        { label: form ? t("Your account") : t("Account"), icon: "user", href: "/account" },
        { label: t("Appearance"), icon: "sliders", href: "/appearance" },
        form && auth.admin ? { label: t("Users and tokens"), icon: "users", href: "/users" } : null,
        // Homeswift's health, version and updates, which the side menu holds on a wide window.
        ...(matchMedia("(min-width: 641px) and (max-width: 1179.98px)").matches && aboutStatus ? [{ separator: true },
          { heading: t("Homeswift {version}", { version: aboutStatus.version }), detail: healthOf(aboutStatus)[0] },
          auth.admin ? { label: aboutStatus.update?.available ? t("Update available") : t("Updates"), icon: "download", href: "/settings/updates" } : null,
          { label: t("Send feedback"), icon: "bug", onSelect: () => window.open("https://github.com/mp-consulting/homeswift/issues", "_blank", "noopener") }] : []),
        form ? { separator: true } : null,
        form ? { label: t("Sign out"), icon: "logout", onSelect: signOut } : null,
      ], { keyboard: event.detail === 0 });
    });
    const link = (path, text, glyph) => el("a", { href: path, class: path === "/plugins" ? "active" : "" }, HomeswiftCommon.icon(glyph), el("span", { text }));
    // You's pages, and the account menu's other entries once the account is known (a wide window's side menu has no
    // account button).
    const you = el("nav", { class: "side-you" }, link("/account", t("Account"), "user"), link("/appearance", t("Appearance"), "sun"));
    const signOut = async () => {
      try { await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }); } catch {}
      location.href = "/";
    };
    // Homeswift at the side menu's foot, folded under one line, as on the UI's own pages; its updates are on
    // Settings › Updates.
    let aboutStatus = null;
    const healthOf = (status) => {
      const waiting = status.bridges.filter((bridge) => !bridge.paired).length;
      return status.restartNeeded ? [t("Running; some changes need a restart"), "away"]
        : waiting ? [tn("Running; one server waits to be added in the Home app", "Running; {n} servers wait to be added in the Home app", waiting), "away"]
        : [t("Running, and everything is in the Home app"), "on"];
    };
    const about = el("details", { id: "side-about", class: "side-about", hidden: true });
    HomeswiftCommon.foldOnLeave(about);
    const drawAbout = () => {
      const status = aboutStatus;
      if (!status) return;
      const [health, kind] = healthOf(status);
      // The side menu's, and a phone's ☰ panel's.
      for (const about of document.querySelectorAll(".side-about")) {
        about.classList.toggle("has-update", Boolean(status.update?.available));
        about.replaceChildren(
          el("summary", {}, el("span", { class: `side-about-dot ${kind}`, "aria-hidden": "true" }),
            el("span", { class: "side-about-title", text: t("Homeswift {version}", { version: status.version }) }),
            el("span", { class: "side-about-badge", role: "img", "aria-label": t("Update available"), title: t("Update available") }), HomeswiftCommon.icon(about.closest("header") ? "up" : "down")),
          el("div", { class: "side-about-body" },
            el("div", { class: "side-about-info" },
              el("p", { class: `side-about-health ${kind}`, text: health }),
              el("p", { class: "side-about-version", text: t("Version {version} · {host}", { version: status.version, host: status.system.hostname }) })),
            el("div", { class: "side-about-actions" },
              auth.admin ? el("a", { class: "side-about-action", href: "/settings/updates" }, HomeswiftCommon.icon("download"), el("span", { text: status.update?.available ? t("Update available") : t("Updates") })) : null,
              el("a", { class: "side-about-action", href: "https://github.com/mp-consulting/homeswift/issues", target: "_blank", rel: "noopener" }, HomeswiftCommon.icon("bug"), el("span", { text: t("Send feedback") })))));
        about.hidden = false;
      }
    };
    api("/api/status").then((status) => { aboutStatus = status; drawAbout(); }).catch(() => {});
    // The header as index.html has it: in a wide window it is the frame's side menu, with the brand's name, Home's
    // sections and You's pages, each with its icon.
    header.replaceChildren(
      el("a", { class: "brand", href: "/", "aria-label": "Homeswift", title: "Homeswift" }, el("img", { src: "/icon.svg", class: "logo", alt: "" }),
        el("span", { class: "brand-name", "aria-hidden": "true", text: "Homeswift" })),
      el("span", { class: "side-caption", "aria-hidden": "true", text: t("Home") }),
      el("nav", { "aria-label": t("Sections") }, sections.map(([path, text, glyph]) => link(path, text, glyph))),
      el("span", { class: "side-caption", "aria-hidden": "true", text: t("You") }),
      you,
      el("span", { class: "spacer" }), about, user);
    // The page in the app's frame (#app, which the wide layout draws), as the UI's own pages are.
    let app = $("#app");
    if (!app) {
      app = el("div", { id: "app" });
      header.before(app);
      app.append(header, ...[$("main")].filter(Boolean));
    }
    // On a phone the sections sit in a tab bar at the bottom, as on the UI's own pages; the page also extends
    // under the notch and the home indicator, which the layout pads around.
    HomeswiftCommon.tabBar({ active: "/plugins", parent: app });
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
      userRole.textContent = auth.mode !== "form" ? t("No sign-in") : auth.admin ? t("Administrator") : t("User");
      const form = auth.mode === "form";
      you.replaceChildren(...[link("/account", form ? t("Your account") : t("Account"), "user"), link("/appearance", t("Appearance"), "sun"),
        form && auth.admin ? link("/users", t("Users and tokens"), "users") : null,
        form ? el("button", { type: "button", class: "side-action", onclick: signOut }, HomeswiftCommon.icon("logout"), el("span", { text: t("Sign out") })) : null].filter(Boolean));
      drawAbout();
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
    const levels = [crumb(el("a", { href: "/plugins", text: t("Plugins") }))];
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
    const nav = el("nav", { class: "breadcrumb", "aria-label": t("Breadcrumb") }, trail);
    // Its Settings (the Plugin Settings, its account and its devices), at the right of the breadcrumb, before Pause.
    nav.append(el("a", { class: "button small settings-link", href: settingsAddress, actionIcon: "gear", text: t("Settings") }));
    main.prepend(nav);
    breadcrumb(null);
    api("/api/plugins").then(({ platforms }) => {
      const instance = platforms.find((p) => p.platform === platform && p.name === name);
      if (!instance) return;
      // A button as any other, once the plugin's state is known.
      const toggle = el("button", {
        type: "button", class: "small pause-toggle", actionIcon: instance.paused ? "play" : "pause", text: instance.paused ? t("Resume") : t("Pause"),
        // What it does, in a tooltip (style.css's data-tip) that a screen reader reads as the description.
        "data-tip": instance.paused ? t("Runs the plugin again: it reconnects to its devices and they answer in the Home app.")
          : t("Stops the plugin until you resume it: no calls to its devices, which show No Response in the Home app."),
        "data-tip-align": "end",
        onclick: () => act(toggle, () => HomeswiftCommon.setPaused(platform, name, !instance.paused).then(() => location.reload())),
      });
      toggle.setAttribute("aria-description", toggle.dataset.tip);
      nav.append(toggle);
      if (instance.paused) {
        main.querySelector(".breadcrumb").after(el("div", { class: "card page-note paused-note" },
          el("p", {}, el("strong", { text: t("Paused.") }), " ", t("The plugin makes no calls to its devices, and they show No Response in the Home app. This page needs it running.")),
          el("button", { actionIcon: "play", class: "primary", text: t("Resume"), onclick: (event) => act(event.currentTarget, () => HomeswiftCommon.setPaused(platform, name, false).then(() => location.reload())) })));
      }
    }).catch(() => {});
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
  const act = (button, work, report = alert) => HomeswiftCommon.busyButton(button, work, { delay: 150, report: report === null ? null : (e) => report(e.message) });

  // ---- Pieces of the lighting pages (Philips Hue, IKEA DIRIGERA) ------------------------------------------

  /// The page's tabs: each `.main-tabs [data-tab]` button shows its `#tab-<name>` and hides the others. The one
  /// last chosen opens again on the next visit, kept in localStorage under `storageKey`.
  function tabs(storageKey) {
    const buttons = [...document.querySelectorAll(".main-tabs [data-tab]")];
    const select = (button) => {
      for (const other of buttons) {
        const on = other === button;
        other.classList.toggle("on", on);
        other.setAttribute("aria-selected", String(on));
        $(`#tab-${other.dataset.tab}`)?.classList.toggle("hidden", !on);
      }
    };
    for (const button of buttons) {
      button.addEventListener("click", () => {
        select(button);
        try { localStorage.setItem(storageKey, button.dataset.tab); } catch {}
      });
    }
    try {
      const saved = localStorage.getItem(storageKey);
      const button = saved && buttons.find((other) => other.dataset.tab === saved);
      if (button) select(button);
    } catch {}
  }

  /// How a scene tile's name reads best on its palette (`colours`, "#rrggbb" stops of a 135° gradient): "light" (dark
  /// text) or "deep" (white on a darker scrim), else "" (white on the usual scrim). The name spans about 35 to 70 % of
  /// the gradient, so the colours there count (stops evenly spaced, mixed in sRGB as the browser does); white has the
  /// scrim under it (about a third black at the name). Each takes the contrast of its worst colour (WCAG's relative
  /// luminance) and the better one wins; when neither reaches 4.5, the darker scrim does.
  function textStyle(colours) {
    const rgb = colours.map((hex) => /^#([0-9a-f]{6})$/i.exec(hex.trim())).map((match) => match && [0, 2, 4].map((i) => parseInt(match[1].slice(i, i + 2), 16)));
    if (!rgb.length || rgb.includes(null)) return "";
    const at = (position) => {
      if (rgb.length === 1) return rgb[0];
      const point = position * (rgb.length - 1);
      const index = Math.min(Math.floor(point), rgb.length - 2);
      return rgb[index].map((c, i) => c + (rgb[index + 1][i] - c) * (point - index));
    };
    const luminance = (channels) => {
      const [r, g, b] = channels.map((c) => c / 255).map((c) => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    };
    const under = [0.35, 0.5, 0.7].map((position) => luminance(at(position)));
    const white = Math.min(...under.map((l) => 1.05 / (l * 0.46 + 0.05)));
    const dark = Math.min(...under.map((l) => (l + 0.05) / 0.062));
    if (Math.max(white, dark) < 4.5) return "deep";
    return dark > white ? "light" : "";
  }

  // A picture a person gave a scene takes no drop outside a tile, so one dropped beside a tile does not open.
  let pictureDropGuard = false;

  /// Scene tiles' pictures: dropped on a tile or chosen from its ⋯ menu, shrunk here to 640 pixels and sent as a JPEG
  /// data: URL to the plugin's `scene-picture` route (POST; GET `scene-picture?id=` reads one, `scene-picture-remove`
  /// takes it away). A scene's `picture` is its version: each is fetched once, a newer one replacing it. `refresh`
  /// runs after a change; `settings(scene, deviceID)`, the address of the scene's Settings (a scene a plugin makes a
  /// Discovered Device is Excluded there: `accessorySettings(<Accessory Id>)`), gives the menu a Settings… link.
  /// `more(scene)` is the page's own items for the menu. Answers `decorate(tileNode, scene, deviceID)`, which adds the tile's menu, takes
  /// drops and paints the picture.
  function scenePictures({ refresh, settings = null, more = () => [], gallery = false }) {
    let artworks = [];
    const normalize = (name) => name.trim().toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");
    const matchedArtwork = (scene) => artworks.find((item) => normalize(item.name) === normalize(scene.name) || (scene.smart && item.id === "first-light"));
    const galleryReady = gallery ? api("/api/scenes").then((data) => { artworks = data.artworks || []; refresh(); }).catch(() => {}) : Promise.resolve();
    async function chooseGallery(scene, tileNode) {
      await galleryReady;
      const grid = el("div", { class: "artwork-grid" });
      const search = el("input", { type: "search", placeholder: t("Search images…"), "aria-label": t("Search images…"), oninput: () => {
        for (const item of grid.children) item.hidden = !normalize(item.textContent).includes(normalize(search.value));
      } });
      // The design system's dialog (common.js's messageDialog, admin.js's): a card over a dimmed page, wide for the grid.
      const dialog = el("dialog", { class: "admin-dialog card wide artwork-dialog", "aria-label": t("Scene image") }, el("h2", { text: t("Scene image") }), search, grid,
        el("div", { class: "actions" }, el("button", { type: "button", actionIcon: "close", text: t("Close"), onclick: () => dialog.close() })));
      for (const artwork of artworks) grid.append(el("button", { class: "scene pictured artwork-choice", actionIcon: "image", onclick: async () => {
        try {
          const response = await fetch(`/artwork-${artwork.id}.webp`);
          if (!response.ok) throw new Error(t("This file is not a picture."));
          await setPicture(scene, await response.blob(), tileNode);
          dialog.close();
        } catch (e) { HomeswiftCommon.showAlert(e.message); }
      } }, el("img", { src: `/artwork-${artwork.id}.webp`, alt: "", loading: "lazy" }), el("span", { class: "name", text: artwork.name })));
      dialog.addEventListener("close", () => dialog.remove());
      document.body.append(dialog); dialog.showModal(); search.focus();
    }
    if (!pictureDropGuard) {
      pictureDropGuard = true;
      for (const type of ["dragover", "drop"]) document.addEventListener(type, (event) => { if (event.dataTransfer?.types?.includes("Files")) event.preventDefault(); });
    }
    /// Scene id → { version, data }, `data` a promise of the data: URL (null when it could not be read).
    const cache = new Map();
    function pictureFor(scene) {
      if (!scene.picture) { cache.delete(scene.id); return Promise.resolve(null); }
      const version = String(scene.picture);
      const cached = cache.get(scene.id);
      if (cached?.version === version) return cached.data;
      const data = request(`scene-picture?id=${encodeURIComponent(scene.id)}`).then((answer) => answer.data).catch(() => {
        // Not kept: the next draw asks again (the bridge was busy or restarting).
        if (cache.get(scene.id)?.data === data) cache.delete(scene.id);
        return null;
      });
      cache.set(scene.id, { version, data });
      return data;
    }

    async function setPicture(scene, file, tileNode) {
      tileNode.classList.add("busy");
      try {
        const data = await HomeswiftCommon.pictureDataURL(file);
        const { version } = await request("scene-picture", { method: "POST", body: { id: scene.id, data } });
        cache.set(scene.id, { version: String(version), data: Promise.resolve(data) });
        await refresh();
      } catch (e) {
        HomeswiftCommon.showAlert(e.message);
      } finally {
        tileNode.classList.remove("busy");
      }
    }

    function choosePicture(scene, tileNode) {
      HomeswiftCommon.choosePictureFile((file) => setPicture(scene, file, tileNode));
    }

    async function removePicture(scene) {
      try {
        await request("scene-picture-remove", { method: "POST", body: { id: scene.id } });
        cache.delete(scene.id);
        await refresh();
      } catch (e) {
        HomeswiftCommon.showAlert(e.message);
      }
    }

    /// The tile takes a dropped picture.
    function dropZone(tileNode, scene) {
      tileNode.addEventListener("dragover", (event) => {
        if (![...(event.dataTransfer?.types ?? [])].includes("Files")) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = "copy";
        tileNode.classList.add("drop");
      });
      tileNode.addEventListener("dragleave", () => tileNode.classList.remove("drop"));
      tileNode.addEventListener("drop", (event) => {
        event.preventDefault();
        tileNode.classList.remove("drop");
        const file = event.dataTransfer?.files?.[0];
        if (file) setPicture(scene, file, tileNode);
      });
    }

    /// The tile's menu: a picture for it, and its settings. A click on it (menuButton stops those)
    /// or a key does not reach the tile.
    function sceneMenu(scene, tileNode, deviceID) {
      const button = HomeswiftCommon.menuButton(t("Actions for {name}", { name: scene.name }), () => [
        gallery ? { label: t("Scene image"), icon: "image", onSelect: () => chooseGallery(scene, tileNode) } : null,
        { label: scene.picture ? t("Change the picture…") : t("Choose a picture…"), icon: "camera", onSelect: () => choosePicture(scene, tileNode) },
        scene.picture ? { label: t("Remove the picture"), icon: "trash", onSelect: () => removePicture(scene) } : null,
        ...more(scene),
        settings ? { label: t("Settings…"), icon: "gear", href: settings(scene, deviceID) } : null,
      ]);
      button.classList.add("eye");
      button.addEventListener("keydown", (event) => event.stopPropagation());
      return button;
    }

    return {
      hasPicture: (scene) => Boolean(scene.picture || matchedArtwork(scene)),
      decorate(tileNode, scene, deviceID) {
        tileNode.append(sceneMenu(scene, tileNode, deviceID));
        dropZone(tileNode, scene);
        // The picture once loaded; the colours stay until then, and when there is none.
        Promise.all([pictureFor(scene), galleryReady]).then(([data]) => {
          const artwork = gallery && matchedArtwork(scene);
          const source = data || (artwork ? `/artwork-${artwork.id}.webp` : null);
          if (!source) return;
          tileNode.style.backgroundImage = `url("${source}")`;
          tileNode.classList.add("pictured");
        });
        return tileNode;
      },
    };
  }

  /// Where this instance is set up: its row on the Add accessories page, and with `start` its account's Setup sheet
  /// open there. A plugin's page signs in and pairs nowhere else (docs/plugins.md, "Setup").
  const setupAddress = ({ start = false } = {}) => `/setup${start ? "?start" : ""}#${location.pathname.split("/")[2] || ""}`;

  /// A card leading to Setup: `title` and `text` say what is set up there (an account, a hub, a TV), its button opens it.
  function setupCard({ title, text, action = t("Set up in Add accessories"), start = true, glyph = "pair", tone = "orange" }) {
    return el("section", { class: "card setup-handoff" },
      tile(glyph, tone),
      el("div", { class: "who" }, el("strong", { text: title }), text ? el("p", { class: "muted", text }) : null),
      el("a", { class: "button primary", href: setupAddress({ start }), actionIcon: glyph, text: action }));
  }

  /// The names of the Excluded devices, as buttons that open one's settings, where it is included again
  /// (`onShow(name)`); drawn again only when they change.
  function drawHidden(container, names, onShow) {
    const key = JSON.stringify(names);
    if (container.dataset.json === key) return;
    container.dataset.json = key;
    container.replaceChildren(...(names.length ? [el("span", { class: "muted", text: t("Excluded:") }),
      ...names.map((name) => el("button", { actionIcon: "gear", text: name, title: t("Settings of {name}", { name }), onclick: () => onShow(name) }))] : []));
  }

  /// Text as a search compares it: accents aside, any case.
  const fold = (text) => String(text ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

  /// What finds a device or a scene among dozens, the same on every tab of the lighting pages: a toolbar (a search of
  /// names and rooms, accents aside; a room; by room or by name; Filters with their counts and Clear filters) kept in the
  /// page's address under `prefix`, each tab its own; and the list it keeps, a section per room (its name folds it away,
  /// remembered under `foldKey`, unless a search or a filter is on) or one list by name. `items()` answers the items,
  /// each { id, name, room, roomID }; `filters` are [key, label, icon, predicate]; `draw()` draws the list again;
  /// `roomPill(roomID)` is an element beside a room's name (the Hue page's room on or off), or null.
  function finder({ toolbar, placeholder, prefix = "", items, filters, foldKey, draw, roomPill = () => null }) {
    const param = (key) => prefix + key;
    const query = new URLSearchParams(location.search);
    const active = new Set(filters.map(([key]) => key).filter((key) => query.has(param(key))));
    const search = el("input", { type: "search", class: "search", placeholder, "aria-label": placeholder, value: query.get(param("q")) ?? "" });
    const room = el("select", { class: "popup", "aria-label": t("Room") });
    const order = el("select", { class: "popup", "aria-label": t("Order") },
      el("option", { value: "room", text: t("By room") }), el("option", { value: "name", text: t("By name") }));
    order.value = query.get(param("sort")) === "name" ? "name" : "room";
    const button = el("button", { type: "button", actionIcon: "sliders", "aria-haspopup": "menu" });
    toolbar.append(search, room, order, button);
    // Under the toolbar while a search or a filter narrows the list: how many it keeps, and the way back.
    const status = el("div", { class: "finder-status", "aria-live": "polite" });
    toolbar.after(status);
    let wantedRoom = query.get(param("room")) || "";

    /// Writes this tab's search, room, order and filters into the address, the other tab's left as they are.
    function keep() {
      const next = new URLSearchParams(location.search);
      for (const key of ["q", "room", "sort", ...filters.map(([key]) => key)]) next.delete(param(key));
      if (search.value.trim()) next.set(param("q"), search.value.trim());
      if (room.value) next.set(param("room"), room.value);
      if (order.value === "name") next.set(param("sort"), "name");
      for (const key of active) next.set(param(key), "1");
      history.replaceState(history.state, "", `${location.pathname}${next.size ? `?${next}` : ""}`);
    }
    const changed = () => { wantedRoom = room.value; keep(); draw(); };
    // A search filters once the typing pauses, not on every key.
    let typing = 0;
    search.addEventListener("input", () => { clearTimeout(typing); typing = setTimeout(changed, 120); });
    room.addEventListener("change", changed);
    order.addEventListener("change", changed);
    function clear() {
      search.value = "";
      room.value = "";
      active.clear();
      changed();
    }

    /// Every item, those the search and room keep (what a filter counts in), and those shown.
    function view() {
      const text = fold(search.value.trim());
      const all = items();
      const base = all.filter((item) => (!room.value || item.roomID === room.value) && (!text || fold(item.name).includes(text) || fold(item.room).includes(text)));
      const predicates = filters.filter(([key]) => active.has(key)).map(([, , , predicate]) => predicate);
      const shown = base.filter((item) => predicates.every((predicate) => predicate(item)));
      return { all, base, shown, narrowed: shown.length !== all.length };
    }

    /// The rooms, by name, with how many items each has: the room menu (drawn again only when they change; a room the
    /// address names that is gone falls back to all) and the order of the sections.
    let roomsKey = "";
    function rooms() {
      const found = new Map();
      for (const item of items()) if (item.roomID) found.set(item.roomID, { name: item.room, count: (found.get(item.roomID)?.count ?? 0) + 1 });
      return [...found].sort(([, a], [, b]) => a.name.localeCompare(b.name));
    }
    function drawRooms(list) {
      const key = JSON.stringify(list);
      if (key === roomsKey) return;
      roomsKey = key;
      room.replaceChildren(el("option", { value: "", text: t("All rooms") }), ...list.map(([id, entry]) => el("option", { value: id, text: `${entry.name} (${entry.count})` })));
      room.value = list.some(([id]) => id === wantedRoom) ? wantedRoom : "";
    }

    button.addEventListener("click", () => {
      const { base } = view();
      HomeswiftCommon.menu(button, [
        ...filters.map(([key, label, iconName, predicate]) => ({
          label, icon: iconName, count: base.filter(predicate).length, checkbox: true, toggle: true, keepOpen: true, checked: active.has(key),
          onSelect: () => {
            if (active.has(key)) active.delete(key); else active.add(key);
            changed();
            return active.has(key);
          },
        })),
        { separator: true },
        { label: t("Clear filters"), clearFilters: true, icon: "restore", disabled: !search.value && !room.value && !active.size, onSelect: clear },
      ]);
    });

    const folded = new Set((() => { try { return JSON.parse(localStorage.getItem(foldKey) || "[]"); } catch { return []; } })());
    function toggleFold(id) {
      if (folded.has(id)) folded.delete(id); else folded.add(id);
      try { localStorage.setItem(foldKey, JSON.stringify([...folded])); } catch {}
      draw();
    }

    return {
      show(visible) {
        toolbar.classList.toggle("hidden", !visible);
        if (!visible) { status.replaceChildren(); delete status.dataset.key; }
      },
      /// Draws `list`: how many the search and filters keep (`countText(shown, total)`), `emptyText` with Clear
      /// filters when none, else a
      /// section per room (those without one last, under "No room") or one by name, each a `bodyClass` element
      /// whose items `render(body, items)` draws.
      draw(list, { countText, emptyText, bodyClass, render }) {
        const roomList = rooms();
        drawRooms(roomList);
        const active_ = active.size;
        button.classList.toggle("on", active_ > 0);
        button.replaceChildren(...[el("span", { text: t("Filters") }), active_ ? el("span", { class: "toolbar-count", text: String(active_) }) : null].filter(Boolean));
        const { all, shown, narrowed } = view();
        const statusKey = narrowed ? `${shown.length}/${all.length}` : "";
        if (status.dataset.key !== statusKey) {
          status.dataset.key = statusKey;
          status.replaceChildren(...(narrowed ? [el("span", { text: countText(shown.length, all.length) }),
            el("button", { type: "button", class: "small", actionIcon: "restore", text: t("Clear filters"), onclick: clear })] : []));
        }
        if (!shown.length) {
          list.replaceChildren(el("div", { class: "card empty" }, el("p", { class: "muted", text: emptyText })));
          return;
        }
        if (list.querySelector(":scope > .card.empty")) list.replaceChildren();
        const byName = order.value === "name";
        const sections = byName
          ? [{ id: "*", name: null, items: [...shown].sort((a, b) => a.name.localeCompare(b.name) || fold(a.room).localeCompare(fold(b.room))) }]
          : [...roomList.map(([id, entry]) => ({ id, name: entry.name, items: shown.filter((item) => item.roomID === id) })),
            { id: "-", name: t("No room"), items: shown.filter((item) => !item.roomID) }].filter((section) => section.items.length);
        renderKeyed(list, sections.map((section) => ({ id: section.id })), (section) => section.id,
          () => el("section", { class: "room" }, el("div", { class: "room-head" }), el("div", { class: bodyClass })));
        sections.forEach((section, index) => {
          const node = list.children[index];
          const [head, body] = node.children;
          const isFolded = !narrowed && section.name !== null && folded.has(section.id);
          node.classList.toggle("folded", isFolded);
          head.classList.toggle("hidden", section.name === null);
          const pill = roomPill(section.id);
          const headKey = JSON.stringify([section.name, section.items.length, isFolded, pill?.outerHTML ?? null]);
          if (section.name !== null && head.dataset.json !== headKey) {
            head.dataset.json = headKey;
            head.replaceChildren(...[
              el("button", { type: "button", class: "room-fold", "aria-expanded": String(!isFolded), onclick: () => toggleFold(section.id) },
                el("span", { class: "chevron", "aria-hidden": "true" }), el("h2", { text: section.name }), el("span", { class: "muted room-count", text: String(section.items.length) })),
              pill].filter(Boolean));
          }
          render(body, isFolded ? [] : section.items.map((item) => ({ ...item, showRoom: byName })));
        });
      },
    };
  }
  window.homeswift = {
    platform, name, request, home: "/plugins", $, el, icon, tile, fact, assistant, explain, ask, breadcrumb, api, act, formatTemperature, temperature,
    settingsAddress, accessorySettings, openAccessorySettings, drawHidden, poll, renderKeyed,
    canonicalMAC, tabs, textStyle, scenePictures, finder,
    setupAddress, setupCard,
  };
})();
