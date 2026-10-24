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
    // A search field as iOS's: no capitals or corrections, a Search key, and on a touch screen that key puts the
    // keyboard away (the results are already there).
    if (tag === "input" && node.type === "search") {
      node.setAttribute("enterkeyhint", "search");
      node.setAttribute("autocapitalize", "none");
      node.setAttribute("autocorrect", "off");
      node.spellcheck = false;
      node.addEventListener("keydown", (event) => { if (event.key === "Enter" && !event.isComposing && matchMedia("(pointer: coarse)").matches) node.blur(); });
    }
    return node;
  };

  // Line icons: 24-unit boxes, round caps, the current colour.
  const icons = {
    bridge: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/><path d="M10 20v-5h4v5"/>',
    child: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/><path d="M10 6.5h4a3 3 0 0 1 3 3V14"/>',
    accessory: '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/>',
    system: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.8"/>',
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
    plus: '<path d="M12 5v14M5 12h14"/>',
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
    // On a phone a card's menu is an action sheet over a dimmed page, at the bottom within the thumb's reach, as
    // iOS's; the header's (the account) still drops down from its button.
    const sheet = matchMedia("(max-width: 640px)").matches && !trigger.closest("header");
    const list = el("div", { class: `menu${sheet ? " sheet-menu" : ""}`, role: "menu", tabIndex: -1, "aria-label": trigger.getAttribute("aria-label") || "Actions" }, nodes);
    const scrim = sheet ? el("div", { class: "menu-scrim", "aria-hidden": "true" }) : null;
    // A sheet's grabber: a swipe down from it puts the sheet away, as the scrim's tap does.
    if (sheet) {
      list.prepend(el("div", { class: "sheet-grabber", "aria-hidden": "true" }));
      dragToDismiss(list, { vertical: () => true, dismiss: () => close(true), handle: ".sheet-grabber" });
    }
    if (scrim) document.body.append(scrim);
    document.body.append(list);
    if (!sheet) {
      // Under the button, its right edges aligned, inside the window; above it when there is no room below.
      const box = trigger.getBoundingClientRect();
      const width = list.offsetWidth, height = list.offsetHeight;
      const below = box.bottom + 6 + height < innerHeight;
      list.style.left = `${Math.max(8, Math.min(innerWidth - width - 8, box.right - width))}px`;
      list.style.top = `${Math.max(8, below ? box.bottom + 6 : box.top - 6 - height)}px`;
      list.style.transformOrigin = `${box.right - parseFloat(list.style.left) - box.width / 2}px ${below ? "0" : "100%"}`;
    }
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
      scrim?.classList.add("closing");
      setTimeout(() => { list.remove(); scrim?.remove(); }, 200);
      if (!quietly) trigger.focus({ preventScroll: true });
    }
    const onResize = () => close(true);
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("pointerdown", onPointer, true);
    addEventListener("resize", onResize);
    openMenu = { trigger, list, close };
    if (keyboard) focusAt(0); else list.focus({ preventScroll: true });
  }

  /// A touch drags a panel or a sheet out along its edge (right, or down on a phone), 1:1 from where it was grabbed,
  /// with resistance the other way. Released, it goes where it was heading: Apple's projection of the flick from its
  /// velocity; past 40% of its size it leaves, otherwise it settles back. A field or a button keeps the touch for
  /// itself.
  function dragToDismiss(dialog, { vertical, dismiss, handle }) {
    const project = (velocity, rate = 0.998) => (velocity / 1000) * rate / (1 - rate);   // px/s to px
    const rubber = (over, size) => (over * size * 0.55) / (size + 0.55 * Math.abs(over));
    let drag = null;
    dialog.addEventListener("pointerdown", (event) => {
      if (event.pointerType === "mouse" || event.target.closest("input, select, textarea, button, a, label")) return;
      // On a phone the sheet scrolls: a downward drag starts on its `handle` only (the grabber, the title).
      if (vertical() && !event.target.closest(handle)) return;
      drag = { id: event.pointerId, x: event.clientX, y: event.clientY, axis: vertical() ? "y" : "x", moving: false, samples: [] };
    });
    dialog.addEventListener("pointermove", (event) => {
      if (!drag || event.pointerId !== drag.id) return;
      const along = drag.axis === "y" ? event.clientY - drag.y : event.clientX - drag.x;
      const across = drag.axis === "y" ? event.clientX - drag.x : event.clientY - drag.y;
      if (!drag.moving) {
        if (Math.abs(along) < 10 && Math.abs(across) < 10) return;   // hysteresis before choosing
        if (Math.abs(across) > Math.abs(along)) { drag = null; return; }   // a scroll or a swipe the other way
        drag.moving = true;
        try { dialog.setPointerCapture(event.pointerId); } catch { /* a pointer that has already gone */ }
        dialog.style.transition = "none";
      }
      const size = drag.axis === "y" ? dialog.offsetHeight : dialog.offsetWidth;
      const offset = along >= 0 ? along : rubber(along, size);
      dialog.style.transform = drag.axis === "y" ? `translateY(${offset}px)` : `translateX(${offset}px)`;
      drag.samples.push([along, event.timeStamp]);
      if (drag.samples.length > 5) drag.samples.shift();
    });
    const release = (event) => {
      if (!drag || event.pointerId !== drag.id) return;
      const { moving, samples, axis } = drag;
      drag = null;
      if (!moving) return;
      const [first, last] = [samples[0], samples[samples.length - 1]];
      const velocity = first && last && last[1] > first[1] ? ((last[0] - first[0]) / (last[1] - first[1])) * 1000 : 0;
      const position = last ? Math.max(0, last[0]) : 0;
      const size = axis === "y" ? dialog.offsetHeight : dialog.offsetWidth;
      // The snappier of Apple's two rates: a panel thrown aside, not a page scrolled.
      if (position + project(velocity, 0.99) > size * 0.4) { dismiss(); return; }
      dialog.style.transition = "transform 300ms cubic-bezier(0.32, 0.72, 0, 1)";
      dialog.style.transform = "";
    };
    dialog.addEventListener("pointerup", release);
    dialog.addEventListener("pointercancel", release);
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

  /// Where things are in JSON text: the offset of each key (or array item) by its path as `JSON.stringify(path)`,
  /// or the first syntax error, `{ message, offset }`. A small parser of its own, since the browsers' JSON.parse
  /// errors neither read the same nor, in Safari, say where.
  function jsonLocate(text) {
    const places = new Map([["[]", 0]]);
    const numberPattern = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y;
    let at = 0;
    const fail = (message, offset = at) => { throw { message, offset: Math.min(offset, text.length) }; };
    const space = () => { while (at < text.length && " \t\n\r".includes(text[at])) at++; };
    const string = () => {
      at++;
      for (;;) {
        if (at >= text.length) fail("This string is not closed");
        const character = text[at];
        if (character === '"') { at++; return; }
        if (character === "\\") {
          const next = text[at + 1];
          if (next === "u" && /^[0-9a-fA-F]{4}$/.test(text.slice(at + 2, at + 6))) at += 6;
          else if (next !== undefined && "\"\\/bfnrt".includes(next)) at += 2;
          else fail("Not a valid escape in a string");
          continue;
        }
        if (character === "\n") fail("This string is not closed before the end of the line");
        if (character < " ") fail("A control character in a string must be escaped");
        at++;
      }
    };
    // A missing comma is reported where it belongs: after the value before it, on that value's line.
    const after = (end, closing) => {
      space();
      if (text[at] === ",") { at++; return false; }
      if (text[at] === closing) { at++; return true; }
      fail(at >= text.length ? `The text ends before this ${closing === "}" ? "object" : "list"} is closed` : `A comma or a ${closing === "}" ? "closing brace" : "closing bracket"} is missing after this value`, end);
    };
    const value = (path) => {
      space();
      const character = text[at];
      if (character === "{") {
        at++;
        space();
        if (text[at] === "}") { at++; return; }
        for (;;) {
          space();
          if (text[at] !== '"') fail(text[at] === "}" ? "A comma before the closing brace" : at >= text.length ? "The text ends before this object is closed" : "Expected a key in double quotes");
          const start = at;
          string();
          const key = JSON.parse(text.slice(start, at));
          places.set(JSON.stringify([...path, key]), start);
          space();
          if (text[at] !== ":") fail("A colon is missing after this key");
          at++;
          value([...path, key]);
          if (after(at, "}")) return;
        }
      }
      if (character === "[") {
        at++;
        space();
        if (text[at] === "]") { at++; return; }
        for (let index = 0; ; index++) {
          space();
          if (text[at] === "]") fail("A comma before the closing bracket");
          places.set(JSON.stringify([...path, index]), at);
          value([...path, index]);
          if (after(at, "]")) return;
        }
      }
      if (character === '"') return string();
      for (const word of ["true", "false", "null"]) if (text.startsWith(word, at)) { at += word.length; return; }
      numberPattern.lastIndex = at;
      const number = numberPattern.exec(text);
      if (number && number[0] !== "-") { at += number[0].length; return; }
      fail(at >= text.length ? "The text ends where a value should be" : character === "'" ? "Strings take double quotes" : "Not a valid value");
    };
    try {
      value([]);
      space();
      if (at < text.length) fail("Something follows the end of the JSON");
      return { places };
    } catch (error) {
      if (error instanceof Error) throw error;
      return { places, error };
    }
  }

  /// The line (from 1) of an offset in `text`.
  const lineAt = (text, offset) => { let line = 1; for (let i = 0; i < offset && i < text.length; i++) if (text.charCodeAt(i) === 10) line++; return line; };

  /// Parses `text`: `{ value }`, or `{ message, offset, line }` for where it goes wrong.
  function jsonCheck(text) {
    try {
      return { value: JSON.parse(text) };
    } catch (parseError) {
      const { error } = jsonLocate(text);
      return error ? { ...error, line: lineAt(text, error.offset) } : { message: parseError.message };
    }
  }

  /// Colours a JSON textarea as it is typed: a coloured copy of its text sits under it, the textarea's own
  /// text transparent, so editing, selection and undo stay the browser's. Returns the wrapper to show, with
  /// `check()` (parses the text and marks the line of a syntax error), `markPaths(paths)` (marks where each
  /// path is, or its nearest parent; returns `{ offset, line }` for each) and `reveal(offset)`.
  function jsonEditor(textarea) {
    const layer = el("pre", { class: "code-layer", "aria-hidden": "true" });
    const wrapper = el("div", { class: "code-editor" }, layer, textarea);
    textarea.classList.add("code-input");
    let scheduled = false;
    // The line of a syntax error (check), else the places of a save's problems (markPaths), which an edit clears.
    let syntax = null, placed = [];
    const paint = () => {
      scheduled = false;
      // A final newline needs a character after it to take its line.
      layer.replaceChildren(jsonHighlight(textarea.value), "\n");
      // A marked line: a band under its text, as many line heights down as the line is from the top.
      const top = getComputedStyle(layer).paddingTop;
      const marks = syntax === null ? placed : [syntax];
      for (const line of new Set(marks.map((offset) => lineAt(textarea.value, offset)))) {
        layer.append(el("span", { class: "code-mark", style: `top: calc(${top} + ${line - 1} * var(--code-line))` }));
      }
      layer.scrollTop = textarea.scrollTop;
      layer.scrollLeft = textarea.scrollLeft;
    };
    const schedule = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(paint); } };
    textarea.addEventListener("input", () => { placed = []; schedule(); });
    textarea.addEventListener("scroll", () => { layer.scrollTop = textarea.scrollTop; layer.scrollLeft = textarea.scrollLeft; });
    // After the text is set in code: the problems' places no longer hold.
    wrapper.repaint = () => { placed = []; paint(); };
    wrapper.check = () => {
      const result = jsonCheck(textarea.value);
      const next = result.offset ?? null;
      if (next !== syntax) { syntax = next; schedule(); }
      return result;
    };
    wrapper.markPaths = (paths) => {
      const { places } = jsonLocate(textarea.value);
      const found = paths.map((path) => {
        let place = path;
        while (place.length && !places.has(JSON.stringify(place))) place = place.slice(0, -1);
        const offset = places.get(JSON.stringify(place)) ?? 0;
        return { offset, line: lineAt(textarea.value, offset) };
      });
      placed = found.map((place) => place.offset);
      schedule();
      return found;
    };
    // The caret on the line, the line a third of the way down.
    wrapper.reveal = (offset) => {
      textarea.focus({ preventScroll: true });
      textarea.setSelectionRange(offset, offset);
      const lineHeight = parseFloat(getComputedStyle(textarea).lineHeight) || 20;
      textarea.scrollTop = Math.max(0, (lineAt(textarea.value, offset) - 1) * lineHeight - textarea.clientHeight / 3);
      wrapper.scrollIntoView({ block: "nearest" });
    };
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
    $, el, icon, tile, fact, markdown, sparkle, api, menu, menuButton, dragToDismiss, copyText, jsonHighlight, jsonView, jsonEditor, jsonCheck, sections, tabBar, setPaused, slug, withSlugs, jsonDiff,
    assistantRequest, applyPreferences, loadPreferences, preferences: () => preferences, temperature, formatTemperature,
  };
})();
