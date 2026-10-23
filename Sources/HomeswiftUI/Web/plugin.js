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

  const { $, el, icon, tile, fact, markdown, sparkle, api } = HomeswiftCommon;

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
          card.replaceChildren(el("div", { class: "ai-inner" }, head("Assistant"), el("p", { class: "ai-thinking", text: "Thinking about it…" })));
          entry.pending.finally(() => { if (document.body.contains(card) && !card.classList.contains("hidden")) show(explanations.get(error)); });
          return;
        }
        if (entry.failed) {
          card.classList.add("failed");
          card.replaceChildren(el("div", { class: "ai-inner" }, head("Assistant"),
            el("p", { class: "error", text: entry.failed }),
            el("button", { class: "link", text: "Try again", onclick: () => { explanations.delete(error); ask(); } })));
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
      const ask = () => {
        const entry = { pending: null };
        entry.pending = api("/api/assistant/explain", { method: "POST", body: { error, context, device, plugin: platform } })
          .then((json) => { explanations.set(error, { text: json.text, model: json.model }); })
          .catch((e) => { explanations.set(error, { failed: e.message }); });
        explanations.set(error, entry);
        show(entry);
        card.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
      };
      button.addEventListener("click", () => (explanations.has(error) ? show(explanations.get(error)) : ask()));
      box.replaceChildren(button, card);
      if (explanations.has(error)) show(explanations.get(error));
    });
    return box;
  }

  // The UI's own header on every plugin page, Plugins highlighted, so leaving a plugin's page is one click
  // anywhere; and a breadcrumb under it: Plugins › the plugin › (its instance) › what is open on the page.
  const sections = HomeswiftCommon.sections;
  const header = $("header");
  if (header) {
    const user = el("a", { id: "user", href: "/account", title: "Your account: change the password" });
    const logout = el("button", { id: "logout", class: "link hidden", text: "Sign out", onclick: async () => {
      try { await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }); } catch {}
      location.href = "/";
    } });
    header.replaceChildren(
      el("a", { class: "brand", href: "/" }, el("img", { src: "/icon.svg", class: "logo", alt: "" }), "Homeswift"),
      el("nav", { "aria-label": "Sections" }, sections.map(([path, text]) => el("a", { href: path, text, class: path === "/plugins" ? "active" : "" }))),
      el("span", { class: "spacer" }), user, logout);
    // On a phone the sections sit in a tab bar at the bottom, as on the UI's own pages; the page also extends
    // under the notch and the home indicator, which the layout pads around.
    HomeswiftCommon.tabBar({ active: "/plugins" });
    const viewport = document.querySelector('meta[name="viewport"]');
    if (viewport && !viewport.content.includes("viewport-fit")) viewport.content += ", viewport-fit=cover";
    // The Assistant's chat, as on the UI's own pages.
    document.head.append(el("script", { src: "/chat.js" }));
    api("/api/auth/state").then((state) => {
      user.textContent = state.username || "";
      logout.classList.toggle("hidden", state.mode !== "form");
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
    platform, name, request, home: "/plugins", $, el, icon, tile, fact, assistant, explain, breadcrumb, api, act,
    readBlock, updateBlock, updateDevices, updateDevice, putDevice, findDevice, setKey, poll, renderKeyed,
    canonicalMAC, isMAC, sameMAC,
  };
})();
