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
  const { t } = HomeswiftI18n;

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
    const user = el("button", { id: "user", type: "button", class: "user-button", "aria-haspopup": "menu", "aria-expanded": "false", "aria-label": t("Account menu") }, avatar, userName);
    const shownName = () => (auth.mode === "form" ? (auth.name && auth.name !== auth.username ? auth.name : auth.username || "") : "");
    user.addEventListener("click", (event) => {
      event.stopPropagation();
      const form = auth.mode === "form";
      HomeswiftCommon.menu(user, [
        form ? { heading: shownName(), detail: auth.admin ? t("{username} · Administrator", { username: auth.username }) : auth.username } : { heading: t("No sign-in"), detail: t("Anyone who opens this web UI uses it") },
        { label: form ? t("Your account") : t("Account"), icon: "user", href: "/account" },
        { label: t("Appearance"), icon: "sliders", href: "/appearance" },
        form && auth.admin ? { label: t("Users and tokens"), icon: "users", href: "/users" } : null,
        form ? { separator: true } : null,
        form ? { label: t("Sign out"), icon: "logout", onSelect: async () => {
          try { await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }); } catch {}
          location.href = "/";
        } } : null,
      ], { keyboard: event.detail === 0 });
    });
    header.replaceChildren(
      el("a", { class: "brand", href: "/", "aria-label": "Homeswift", title: "Homeswift" }, el("img", { src: "/icon.svg", class: "logo", alt: "" })),
      el("nav", { "aria-label": t("Sections") }, sections.map(([path, text]) => el("a", { href: path, text, class: path === "/plugins" ? "active" : "" }))),
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
    // Expert, last on the page once the page's own script has laid it out: the whole block as config.json
    // keeps it, as a form or as JSON, for what the page itself does not set.
    const expert = (mode) => `${address}/expert${mode === "json" ? "/json" : ""}`;
    const section = el("section", { class: "expert", "aria-labelledby": "expert-title" },
      el("div", { class: "section-head" }, el("h2", { id: "expert-title", text: t("Expert") })),
      el("div", { class: "card page-note" },
        el("p", { class: "muted", text: t("Every setting of this plugin's block, as config.json keeps it, including what this page does not show.") }),
        el("div", { class: "expert-links" }, el("a", { class: "button", href: expert("form") }, HomeswiftCommon.icon("sliders"), el("span", { text: t("Form") })), el("a", { class: "button", href: expert("json") }, HomeswiftCommon.icon("code"), el("span", { text: "JSON" })))));
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
      if (index < 0) throw new Error(t("This device is not in the configuration."));
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
  const act = (button, work, report = alert) => HomeswiftCommon.busyButton(button, work, { delay: 150, report: report === null ? null : (e) => report(e.message) });

  /// Adds `name` to the block's list `key` (an exclude list such as `excludeScenes`), or takes it out when it is
  /// there (in any case), and writes the block at once; an empty list leaves the block. Answers the block as
  /// written, or null after an error, which it shows.
  async function toggleList(key, name) {
    try {
      await updateBlock((draft) => {
        const list = draft[key] || [];
        const index = list.findIndex((item) => item.toLowerCase() === name.toLowerCase());
        if (index >= 0) list.splice(index, 1); else list.push(name);
        if (list.length) draft[key] = list; else delete draft[key];
      });
      return await readBlock();
    } catch (e) {
      alert(e.message);
      return null;
    }
  }

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

  // The transition as a 12-step speed scale, slowest first; the block keeps its milliseconds (`transitionMs`), a
  // value between steps showing as the nearest. Step 9, 100 ms, is the default.
  const speedSteps = [2000, 1500, 1000, 800, 600, 400, 300, 200, 100, 60, 30, 0];
  const stepFor = (ms) => speedSteps.reduce((best, value, index) => Math.abs(value - ms) < Math.abs(speedSteps[best] - ms) ? index : best, 0) + 1;

  /// The Transition field: a slider over the speed scale, its reading, the scale's names under it and `help`.
  /// `onInput` runs when a person moves it. Answers `{ element, set(ms), value() }`: `set` shows a duration (100 ms
  /// when none) without calling `onInput`, `value` answers the chosen one in milliseconds.
  function speedScale({ help, onInput } = {}) {
    const names = [[2, t("Very slow")], [4, t("Slow")], [7, t("Medium")], [9, t("Fast")], [11, t("Very fast")], [12, t("Extreme")]];
    const nameOf = (step) => names.find(([last]) => step <= last)[1];
    const reading = el("output");
    const slider = el("input", { type: "range", class: "speed", min: 1, max: 12, step: 1, "aria-label": t("Transition") });
    const show = () => {
      const step = Number(slider.value);
      const ms = speedSteps[step - 1];
      reading.textContent = ms === 0 ? t("{speed} · at once", { speed: nameOf(step) }) : t("{speed} · {ms} ms", { speed: nameOf(step), ms });
      slider.setAttribute("aria-valuetext", reading.textContent);
    };
    slider.addEventListener("input", () => { show(); onInput?.(); });
    // The names under the scale, each as wide as its steps.
    const scale = el("div", { class: "speed-scale", "aria-hidden": "true" }, names.map(([last, text], index) =>
      el("span", { text, style: `grid-column: span ${last - (names[index - 1]?.[0] ?? 0)}` })));
    const element = el("label", { class: "field" },
      el("span", { class: "range-head" }, el("span", { class: "field-title", text: t("Transition") }), reading), slider, scale,
      help ? el("span", { class: "help", text: help }) : null);
    show();
    return {
      element,
      set(ms) { slider.value = stepFor(ms ?? 100); show(); },
      value: () => speedSteps[Number(slider.value) - 1],
    };
  }

  // A picture a person gave a scene takes no drop outside a tile, so one dropped beside a tile does not open.
  let pictureDropGuard = false;

  /// Scene tiles' pictures: dropped on a tile or chosen from its ⋯ menu, shrunk here to 640 pixels and sent as a JPEG
  /// data: URL to the plugin's `scene-picture` route (POST; GET `scene-picture?id=` reads one, `scene-picture-remove`
  /// takes it away). A scene's `picture` is its version: each is fetched once, a newer one replacing it. `refresh`
  /// runs after a change; `toggleHidden(key)` leaves the scene out of the Home app, or brings it back; `more(scene)`
  /// the page's own items for the menu. Answers `decorate(tileNode, scene, hideKey)`, which adds the tile's menu, takes
  /// drops and paints the picture.
  function scenePictures({ refresh, toggleHidden, more = () => [] }) {
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

    async function shrink(file) {
      if (!/^image\//.test(file.type)) throw new Error(t("This file is not a picture."));
      const bitmap = await createImageBitmap(file).catch(() => { throw new Error(t("This file is not a picture.")); });
      const canvas = HomeswiftCommon.scaledCanvas(bitmap, 640);
      bitmap.close?.();
      return canvas.toDataURL("image/jpeg", 0.85);
    }

    async function setPicture(scene, file, tileNode) {
      tileNode.classList.add("busy");
      try {
        const data = await shrink(file);
        const { version } = await request("scene-picture", { method: "POST", body: { id: scene.id, data } });
        cache.set(scene.id, { version: String(version), data: Promise.resolve(data) });
        await refresh();
      } catch (e) {
        alert(e.message);
      } finally {
        tileNode.classList.remove("busy");
      }
    }

    function choosePicture(scene, tileNode) {
      const input = el("input", { type: "file", accept: "image/jpeg,image/png,image/webp,image/heic" });
      input.addEventListener("change", () => { if (input.files?.[0]) setPicture(scene, input.files[0], tileNode); });
      input.click();
    }

    async function removePicture(scene) {
      try {
        await request("scene-picture-remove", { method: "POST", body: { id: scene.id } });
        cache.delete(scene.id);
        await refresh();
      } catch (e) {
        alert(e.message);
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

    /// The tile's menu: a picture for it, and whether the Home app shows it. A click on it (menuButton stops those)
    /// or a key does not reach the tile.
    function sceneMenu(scene, tileNode, hideKey) {
      const button = HomeswiftCommon.menuButton(t("Actions for {name}", { name: scene.name }), () => [
        { label: scene.picture ? t("Change the picture…") : t("Choose a picture…"), icon: "camera", onSelect: () => choosePicture(scene, tileNode) },
        scene.picture ? { label: t("Remove the picture"), icon: "trash", onSelect: () => removePicture(scene) } : null,
        ...more(scene),
        { label: scene.hidden ? t("Show in the Home app") : t("Leave out of the Home app"), icon: "eye", onSelect: () => toggleHidden(hideKey) },
      ]);
      button.classList.add("eye");
      button.addEventListener("keydown", (event) => event.stopPropagation());
      return button;
    }

    return {
      decorate(tileNode, scene, hideKey) {
        tileNode.append(sceneMenu(scene, tileNode, hideKey));
        dropZone(tileNode, scene);
        // The picture once loaded; the colours stay until then, and when there is none.
        pictureFor(scene).then((data) => {
          if (!data) return;
          tileNode.style.backgroundImage = `url("${data}")`;
          tileNode.classList.add("pictured");
        });
        return tileNode;
      },
    };
  }

  /// The bridge card of the lighting pages, the same for a Hue Bridge and DIRIGERA hubs: a block per bridge (its tile,
  /// name, address and state; its facts once paired, else the prompt to pair: Pair, then the countdown while its
  /// button can be pressed), and the address form at the end of the card (Find lists the bridges on the network, a tap
  /// fills the address in; the primary button uses it). The form is made once, so it stays open and keeps what was typed.
  ///
  /// `card` the element; `tone` the tile's colour once connected; `button` the icon on the drawn bridge button;
  /// `texts`: `name` (a bridge without one), `pairTitle`, `pairHelp`, `press` (while pairing), `summary` (the form's),
  /// `placeholder`, `addressHelp`, `none` (Find found nothing). `facts(bridge)` the [label, value] pairs of a paired
  /// one; `menu(bridge)` more items of its ⋯ menu (Pair again is there once paired); `problem(bridge)` what
  /// `explain` takes when it does not answer. `discover()` answers the hosts on the network, `use(host)` takes the
  /// address, `pair(host)` pairs (resolves once paired, rejects otherwise), `refresh()` reads the state again.
  ///
  /// Answers `{ draw(bridges, { address }), pair(host) }`: `bridges` are `{ host, name, detail, paired, pairing,
  /// pairingSecondsLeft, connected, error }` (`connected` false while connecting; `detail` replaces the address
  /// under the name), `address` what the form shows until a person types.
  function bridgePairing({ card, tone, button = "link", texts, facts = () => [], menu = () => [], problem, discover, use, pair, refresh }) {
    // The end of each bridge's minute to press its button, by host: the bridge's own while it pairs (this page, another
    // or the plugin at start), else the one this page's Pair started. A second's tick redraws meanwhile.
    const pairingUntil = new Map();
    const asking = new Set();
    let bridges = [];
    let address = "";
    let ticker = 0;
    const secondsLeft = (host) => Math.max(0, Math.ceil(((pairingUntil.get(host) ?? 0) - Date.now()) / 1000));
    const isPairing = (bridge) => bridge.pairing || Date.now() < (pairingUntil.get(bridge.host) ?? 0);
    const waiting = (host) => t("Waiting for the button… {seconds} s left.", { seconds: secondsLeft(host) });

    function follow() {
      for (const bridge of bridges) {
        if (bridge.pairing && bridge.pairingSecondsLeft != null) pairingUntil.set(bridge.host, Date.now() + bridge.pairingSecondsLeft * 1000);
        else if (!bridge.pairing && !asking.has(bridge.host)) pairingUntil.delete(bridge.host);
      }
      const on = bridges.some(isPairing);
      if (on && !ticker) ticker = setInterval(redraw, 1000);
      if (!on && ticker) { clearInterval(ticker); ticker = 0; }
    }

    let typed = false;
    const input = el("input", { type: "text", id: "bridge-address", placeholder: texts.placeholder, inputmode: "url", autocomplete: "off" });
    input.addEventListener("input", () => { typed = true; });
    const found = el("div", { class: "found" });
    const form = el("details", { class: "address-box" },
      el("summary", { text: texts.summary }),
      // The title, then the input with its buttons on one row (so they line up at any width), then the help.
      el("div", { class: "address" },
        el("label", { class: "field-title", htmlFor: "bridge-address", text: t("Address") }),
        el("div", { class: "address-row" }, input,
          el("button", { actionIcon: "search", text: t("Find"), onclick: (event) => act(event.currentTarget, async () => {
            const hosts = await discover();
            found.replaceChildren(...(hosts.length
              ? hosts.map((host) => el("button", { actionIcon: "bridge", text: host, onclick: () => { input.value = host; typed = true; } }))
              : [el("span", { class: "muted", text: texts.none })]));
          }) }),
          el("button", { class: "primary", actionIcon: "check", text: t("Use"), onclick: (event) => act(event.currentTarget, async () => {
            await use(input.value.trim());
            typed = false;
            found.replaceChildren();
            await refresh();
          }) })),
        texts.addressHelp ? el("span", { class: "help", text: texts.addressHelp }) : null),
      found);
    const list = el("div", { class: "bridges" });
    card.append(list, form);

    /// The countdown texts of the bridges waiting for their button, by host: the second's tick updates only them.
    const countdowns = new Map();

    function block(bridge) {
      const pairingNow = isPairing(bridge);
      const [state, kind] = pairingNow ? [t("Pairing…"), "standby"] : !bridge.host ? [t("Not found"), "away"] : !bridge.paired ? [t("Not paired"), "away"]
        : bridge.error ? [t("Not responding"), "away"] : bridge.connected === false ? [t("Connecting…"), "standby"] : [t("Connected"), "on"];
      const items = [
        bridge.paired && !pairingNow ? { label: t("Pair again"), icon: "pair", onSelect: () => start(null, bridge.host) } : null,
        ...menu(bridge),
      ].filter(Boolean);
      const note = el("p", { class: "muted", text: pairingNow ? waiting(bridge.host) : texts.pairHelp });
      if (pairingNow) countdowns.set(bridge.host, note);
      const pairs = facts(bridge);
      return el("div", { class: "bridge" },
        el("div", { class: "server-head" },
          tile("bridge", bridge.paired && !bridge.error ? tone : "grey"),
          el("div", { class: "who" }, el("strong", { text: bridge.name || texts.name }),
            el("div", { class: "muted", text: bridge.detail || bridge.host || t("Looking on the network…") })),
          el("span", { class: `pill status ${kind}`, text: state }),
          // The ⋯ menu only when it has something: a bridge pairing for the first time has nothing.
          items.length ? HomeswiftCommon.menuButton(t("Actions for {name}", { name: [bridge.name || texts.name, bridge.host].filter(Boolean).join(" ") }), () => items) : null),
        bridge.paired && bridge.host && !pairingNow && pairs.length ? el("div", { class: "facts" }, ...pairs.map(([label, value]) => fact(label, String(value)))) : null,
        bridge.host && (!bridge.paired || pairingNow) ? el("div", { class: `pair-prompt ${pairingNow ? "pairing" : ""}` },
          el("span", { class: "link-button", "aria-hidden": "true" }, icon(button)),
          el("div", {},
            el("p", {}, el("strong", { text: pairingNow ? texts.press : texts.pairTitle })),
            note),
          // At the row's end, on the drawn button's line.
          pairingNow ? null : el("button", { class: "primary", actionIcon: "pair", text: t("Pair"), onclick: (event) => start(event.currentTarget, bridge.host) })) : null,
        bridge.error && bridge.paired && !pairingNow && problem ? explain(problem(bridge)) : null);
    }

    /// The blocks, drawn again only when what they show changed; while a bridge pairs, the second's tick only counts down.
    let key = "";
    function redraw() {
      if (!typed && document.activeElement !== input) input.value = address;
      const next = JSON.stringify(bridges.map((bridge) => [{ ...bridge, pairingSecondsLeft: null }, isPairing(bridge)]));
      if (next === key) {
        for (const [host, text] of countdowns) text.textContent = waiting(host);
        return;
      }
      key = next;
      countdowns.clear();
      list.replaceChildren(...bridges.map(block));
    }

    async function start(control, host) {
      pairingUntil.set(host, Date.now() + 60000);
      asking.add(host);
      follow();
      redraw();
      try {
        await (control ? act(control, () => pair(host), null) : pair(host));
      } catch (e) {
        alert(e.message);
      } finally {
        pairingUntil.delete(host);
        asking.delete(host);
        await refresh();
      }
    }

    return {
      draw(next, options = {}) {
        bridges = next;
        address = options.address ?? "";
        follow();
        redraw();
      },
      pair: (host) => start(null, host),
    };
  }

  /// The names a block's list leaves out of the Home app, as buttons that bring one back (`onShow(name)`); drawn again
  /// only when they change.
  function drawHidden(container, names, onShow) {
    const key = JSON.stringify(names);
    if (container.dataset.json === key) return;
    container.dataset.json = key;
    container.replaceChildren(...(names.length ? [el("span", { class: "muted", text: t("Not in the Home app:") }),
      ...names.map((name) => el("button", { actionIcon: "eye", text: name, title: t("Show in the Home app"), onclick: () => onShow(name) }))] : []));
  }

  window.homeswift = {
    platform, name, request, home: "/plugins", $, el, icon, tile, fact, assistant, explain, ask, breadcrumb, api, act, formatTemperature, temperature,
    readBlock, updateBlock, updateDevices, updateDevice, putDevice, findDevice, setKey, toggleList, drawHidden, poll, renderKeyed,
    canonicalMAC, isMAC, sameMAC, tabs, textStyle, speedScale, scenePictures, bridgePairing,
  };
})();
