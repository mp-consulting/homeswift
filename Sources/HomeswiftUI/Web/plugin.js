// For a plugin's own pages, served at /plugins/<platform>/: homeswift.request() talks to the plugin instance
// named in the page's URL (?name=), with the session cookie; homeswift.el() and homeswift.$() build and find
// elements the way the UI's own pages do. A signed-out visitor is sent to the login page.
(() => {
  "use strict";
  const platform = decodeURIComponent(location.pathname.split("/")[2] || "");
  const name = new URLSearchParams(location.search).get("name") || platform;
  const prefix = `/api/plugins/${encodeURIComponent(platform)}/${encodeURIComponent(name)}/`;

  const $ = (selector, root = document) => root.querySelector(selector);
  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      // Attributes with no property of the same name: data-*, aria-* (a screen reader reads those).
      else if (key.startsWith("data-") || key.startsWith("aria-")) node.setAttribute(key, value);
      else if (value !== undefined && value !== null && value !== false) node[key] = value;
    }
    for (const child of children.flat()) if (child != null) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  };

  async function request(path, { method = "GET", body } = {}) {
    const options = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = JSON.stringify(body); }
    const response = await fetch(prefix + String(path).replace(/^\//, ""), options);
    if (response.status === 401) { location.href = "/"; throw new Error("signed out"); }
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { error: text }; }
    if (!response.ok) throw new Error((json && json.error) || `HTTP ${response.status}`);
    return json;
  }

  // The Assistant, when config.json has a HomeswiftAiKit block that works: pages offer "Explain" next to errors.
  let assistantState = null;
  const assistant = () => (assistantState ??= fetch("/api/assistant", { credentials: "same-origin" })
    .then((response) => (response.ok ? response.json() : { enabled: false })).catch(() => ({ enabled: false })));

  /// Markdown from the Assistant as elements, never as HTML: headings, paragraphs, nested lists, code blocks,
  /// bold, italics, code and http(s) links. Anything else stays text.
  function markdown(source) {
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
          const node = el(ordered ? "ol" : "ul", {});
          const parent = current && current.indent < indent ? current.node.lastElementChild : null;
          (parent || root).append(node);
          if (current && current.indent === indent) lists.pop();
          current = { indent, ordered, node };
          lists.push(current);
        }
        current.node.append(el("li", {}, inline(item[3])));
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

  /// Inline Markdown: **bold**, *italics*, `code`, [a link](https://…).
  function inline(text) {
    const nodes = [];
    const pattern = /(\*\*[^*]+\*\*|__[^_]+__|`[^`]+`|\*[^*\s][^*]*\*|\[[^\]]+\]\((?:https?:\/\/)[^)\s]+\))/g;
    let last = 0;
    for (const match of text.matchAll(pattern)) {
      if (match.index > last) nodes.push(text.slice(last, match.index));
      const token = match[0];
      if (token.startsWith("**") || token.startsWith("__")) nodes.push(el("strong", { text: token.slice(2, -2) }));
      else if (token.startsWith("`")) nodes.push(el("code", { text: token.slice(1, -1) }));
      else if (token.startsWith("[")) {
        const [, label, url] = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
        nodes.push(el("a", { href: url, text: label, target: "_blank", rel: "noopener noreferrer" }));
      } else nodes.push(el("em", { text: token.slice(1, -1) }));
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
        entry.pending = fetch("/api/assistant/explain", {
          method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ error, context, device, plugin: platform }),
        }).then(async (response) => {
          const json = await response.json().catch(() => ({}));
          if (!response.ok) throw new Error(json.error || `HTTP ${response.status}`);
          explanations.set(error, { text: json.text, model: json.model });
        }).catch((e) => { explanations.set(error, { failed: e.message }); });
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
  const sections = [["#status", "Status"], ["#accessories", "Accessories"], ["#plugins", "Plugins"], ["#config", "Config"], ["#logs", "Logs"]];
  const header = $("header");
  if (header) {
    const user = el("a", { id: "user", href: "/#account", title: "Your account: change the password" });
    const logout = el("button", { id: "logout", class: "link hidden", text: "Sign out", onclick: async () => {
      try { await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" }); } catch {}
      location.href = "/";
    } });
    header.replaceChildren(
      el("a", { class: "brand", href: "/#status" }, el("img", { src: "/icon.svg", class: "logo", alt: "" }), "Homeswift"),
      el("nav", { "aria-label": "Sections" }, sections.map(([hash, text]) => el("a", { href: `/${hash}`, text, class: hash === "#plugins" ? "active" : "" }))),
      el("span", { class: "spacer" }), user, logout);
    fetch("/api/auth/state", { credentials: "same-origin" }).then((response) => response.json()).then((state) => {
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
    const levels = [crumb(el("a", { href: "/#plugins", text: "Plugins" }))];
    const pageLevel = name !== pageTitle ? `${pageTitle} · ${name}` : pageTitle;
    levels.push(opened
      ? crumb(el("a", { href: "#", text: pageLevel, onclick: (event) => { event.preventDefault(); opened?.close?.(); } }))
      : crumb(el("span", { text: pageLevel }), true));
    if (opened) levels.push(crumb(el("span", { text: opened.text }), true));
    trail.replaceChildren(...levels);
  }
  const main = $("main");
  if (main) {
    main.prepend(el("nav", { class: "breadcrumb", "aria-label": "Breadcrumb" }, trail,
      el("a", { href: `/#settings/${encodeURIComponent(platform)}/${encodeURIComponent(name)}`, text: "Settings", title: "This plugin's block of config.json" })));
    breadcrumb(null);
  }

  window.homeswift = { platform, name, request, home: "/#plugins", $, el, assistant, explain, breadcrumb };
})();
