// What every page of the web UI shares, the UI's own and plugins' alike: $ and el, which build and find elements;
// the tiles, an icon on a colour, as the Home app draws them; and the Assistant's Markdown and sparkle. Loaded
// before the page's own script.
(() => {
  "use strict";

  // i18n.js is the first script of every page.
  const { t } = HomeswiftI18n;

  const $ = (selector, root = document) => root.querySelector(selector);
  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "actionIcon") continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      // Attributes with no property of the same name: data-*, aria-* (a screen reader reads those).
      else if (value === undefined || value === null || value === false) continue;
      else if (key.startsWith("data-") || key.startsWith("aria-")) node.setAttribute(key, value);
      else node[key] = value;
    }
    // A CSS mask keeps the decorative icon when async actions replace their text.
    if (attrs.actionIcon) decorateAction(node, attrs.actionIcon);
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
    wingman: '<g transform="translate(0 4.32) scale(.048)"><g fill="currentColor" stroke="none"><path d="M8 12C65 48 155 88 180 110C198 121 204 136 195 148L165 177C180 144 170 131 149 121C47 95 6 88 8 12Z M36 112L150 152L132 177C64 163 42 161 36 112Z M58 177L121 193L109 221C77 220 63 203 58 177Z"/><g transform="translate(500 0) scale(-1 1)"><path d="M8 12C65 48 155 88 180 110C198 121 204 136 195 148L165 177C180 144 170 131 149 121C47 95 6 88 8 12Z M36 112L150 152L132 177C64 163 42 161 36 112Z M58 177L121 193L109 221C77 220 63 203 58 177Z"/></g></g><path d="M136 220L250 104L364 220M153 205V305H347V205" fill="none" stroke="currentColor" stroke-width="29" stroke-linecap="round" stroke-linejoin="round"/></g>',
    power: '<path d="M12 3v9M6.3 5.8a8 8 0 1 0 11.4 0"/>',
    // Full screen: a frame with its corners pulled out, top right and bottom left.
    expand: '<rect x="3.5" y="3.5" width="17" height="17" rx="2.5"/><path d="M13.5 7.5h3v3M10.5 16.5h-3v-3"/>',
    // The web UI: a browser window with a page of tiles in it.
    browser: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 8.5h18M6 6.25h0M8.5 6.25h0"/><rect x="6.5" y="11.5" width="4.5" height="5" rx="1"/><path d="M14 12.5h3.5M14 15.5h3.5"/>',
    selector: '<path d="M8 9.5l4-4 4 4M8 14.5l4 4 4-4"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
    sparkle: '<path d="M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9z"/><path d="M18.5 15.5l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z"/>',
    ungroup: '<rect x="3" y="13" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="8" rx="2"/><path d="M3 9V3h6M3 3l5 5M15 21h6v-6M21 21l-5-5"/>',
    group: '<rect x="3" y="8" width="13" height="13" rx="3"/><path d="M8 8V6a3 3 0 0 1 3-3h7a3 3 0 0 1 3 3v7a3 3 0 0 1-3 3h-2M7 14.5h5M9.5 12v5"/>',
    // A bridge, Homeswift's own or a Hue Bridge or DIRIGERA hub: the box on the shelf, its light, the radio it speaks.
    bridge: '<rect x="4" y="13" width="16" height="7.5" rx="2.5"/><path d="M8 16.75h.01M8.5 9.5a5 5 0 0 1 7 0M6 7a8.5 8.5 0 0 1 12 0"/>',
    // Plays again and again: a scene's Autoplay, a play inside a turning arrow.
    loop: '<path d="M19.8 16.5A9 9 0 1 1 18.4 5.6"/><path d="M20.5 3v5.5H15z" fill="currentColor"/><path d="M10 8.5v7l5.5-3.5z" fill="currentColor"/>',
    // Pairing: two links of a chain on the diagonal.
    pair: '<g transform="rotate(-45 12 12)"><rect x="10.5" y="8" width="12.5" height="8" rx="4"/><rect x="1" y="8" width="12.5" height="8" rx="4"/></g>',
    child: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/><path d="M10 6.5h4a3 3 0 0 1 3 3V14"/>',
    accessory: '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/>',
    system: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    wall: '<rect x="3" y="3" width="11" height="10" rx="1.5"/><rect x="17" y="3" width="4" height="6" rx="1.2"/><rect x="17" y="12" width="4" height="9" rx="1.2"/><rect x="3" y="16" width="5" height="5" rx="1.2"/><rect x="11" y="16" width="3" height="5" rx="1"/>',
    grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.8"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.8"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.8"/>',
    blind: '<path d="M4 4h16M5 4v13h14V4M5 8h14M5 12h14M5 16h14M21 4v15"/><circle cx="21" cy="20" r="1"/>',
    bulb: '<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/>',
    switch: '<rect x="6" y="3" width="12" height="18" rx="3"/><circle cx="12" cy="9" r="2"/>',
    outlet: '<rect x="4" y="4" width="16" height="16" rx="4"/><path d="M10 9v2M14 9v2M10 15h4"/>',
    // Matter, as a neutral mark (three linked nodes): its logo is for certified products only.
    matter: '<circle cx="12" cy="5" r="2.5"/><circle cx="5" cy="18" r="2.5"/><circle cx="19" cy="18" r="2.5"/><path d="m10.8 7.3-4.6 8.4M13.2 7.3l4.6 8.4M7.5 18h9"/>',
    // A pool robot from the side, level: its handle and cover, the track running from a roller at the front round a wheel at the back.
    poolRobot: '<path d="M10 6.5h4.5a2 2 0 0 1 2 2"/><path d="M3.6 14.2C4.2 11 7 9.3 10.5 9.3H15a3.5 3.5 0 0 1 3.3 2.4"/><path d="M5.5 15 16.4 12.05M5.5 19H17M5.5 15a2 2 0 0 0 0 4"/><circle cx="17" cy="15.5" r="3.5"/><circle cx="17" cy="15.5" r="1"/>',
    // A robot cleaner from three quarters: its round body, the sensor on top, a row of lights and the brushes under it.
    vacuum: '<ellipse cx="12" cy="8.5" rx="9" ry="4"/><path d="M3 8.5V12c0 2.2 4 4 9 4s9-1.8 9-4V8.5"/><ellipse cx="12" cy="7.2" rx="2" ry=".8"/><path d="M9.5 10.2h0M12 10.4h0M14.5 10.2h0M12 16l-4.5 4M12 16l4.5 4"/>',
    sensor: '<circle cx="12" cy="12" r="2"/><path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8"/>',
    fan: '<circle cx="12" cy="12" r="2"/><path d="M12 10c0-4 1-7 4-7 2 0 3 2 2 4l-4 4M14 12c4 0 7 1 7 4 0 2-2 3-4 2l-4-4M12 14c0 4-1 7-4 7-2 0-3-2-2-4l4-4M10 12c-4 0-7-1-7-4 0-2 2-3 4-2l4 4"/>',
    speaker: '<rect x="6" y="3" width="12" height="18" rx="2"/><circle cx="12" cy="14" r="3"/><path d="M12 7h.01"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    thermo: '<path d="M14 14.8V5a2 2 0 0 0-4 0v9.8a4 4 0 1 0 4 0z"/>',
    door: '<path d="M6 21V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v17M3 21h18M14 12h.01"/>',
    generic: '<rect x="4" y="4" width="16" height="16" rx="4"/>',
    plugin: '<g transform="translate(12 12) scale(1.18) rotate(45) translate(-12 -12)" fill="currentColor" stroke="none"><rect x="8" y="4" width="1.8" height="6" rx=".9"/><rect x="14.2" y="4" width="1.8" height="6" rx=".9"/><path d="M7 9h10v3a5 5 0 0 1-10 0Z"/><rect x="10.9" y="15" width="2.2" height="5" rx="1"/></g>',
    gear: '<path d="M18.68 9.30L21.38 10.51L21.38 13.49L18.68 14.70L18.63 14.81L19.69 17.58L17.58 19.69L14.81 18.63L14.70 18.68L13.49 21.38L10.51 21.38L9.30 18.68L9.19 18.63L6.42 19.69L4.31 17.58L5.37 14.81L5.32 14.70L2.62 13.49L2.62 10.51L5.32 9.30L5.37 9.19L4.31 6.42L6.42 4.31L9.19 5.37L9.30 5.32L10.51 2.62L13.49 2.62L14.70 5.32L14.81 5.37L17.58 4.31L19.69 6.42L18.63 9.19Z"/><circle cx="12" cy="12" r="3"/>',
    more: '<circle cx="6" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="18" cy="12" r="1.6"/>',
    logs: '<path d="M8 6h12M8 12h12M8 18h8M4 6h.01M4 12h.01M4 18h.01"/>',
    code: '<path d="M8 4c-2 0-3 1-3 3v2c0 1.5-1 3-2.5 3C4 12 5 13.5 5 15v2c0 2 1 3 3 3M16 4c2 0 3 1 3 3v2c0 1.5 1 3 2.5 3-1.5 0-2.5 1.5-2.5 3v2c0 2-1 3-3 3"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    pause: '<path d="M9 5v14M15 5v14"/>',
    play: '<path d="M8 5.5v13l10-6.5z"/>',
    open: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
    edit: '<path d="M12 20h8M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
    inputs: '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8M12 17v4"/>',
    update: '<path d="M12 3.5v11"/><path d="m7.5 10 4.5 4.5 4.5-4.5"/><path d="M5 20.5h14"/>',
    camera: '<rect x="2.5" y="6" width="13.5" height="12" rx="2.5"/><path d="m16 10.5 5.5-3.5v10L16 13.5"/>',
    identify: '<path d="M9 17v-1.5a5 5 0 1 1 6 0V17zM9 20h6M11 23h2M12 1v2M3.5 4.5 5 6M1 11h2M20.5 4.5 19 6M21 11h2"/>',
    room: '<path d="M5 21V4a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v17M5 4l8 3v11l-8 3M3 21h18"/><path d="M10 12.5v1"/>',
    star: '<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z"/>',
    eye: '<path d="M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7-9.5-7-9.5-7z"/><circle cx="12" cy="12" r="2.5"/>',
    bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4"/>',
    // Device glyphs: a television, air, a garage gate, water.
    tv: '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/>',
    wind: '<path d="M3 8h11a3 3 0 1 0-3-3M3 12h16a3 3 0 1 1-3 3M3 16h8"/>',
    gate: '<path d="M3 21V9l9-5 9 5v12M7 21v-8h10v8M7 17h10"/>',
    drop: '<path d="M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z"/>',
    user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
    users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8M18 14.2a6.5 6.5 0 0 1 3.5 5.8"/>',
    logout: '<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4"/><path d="M9 16.5 4.5 12 9 7.5M4.5 12H15"/>',
    chart: '<path d="M4 4v16h16"/><path d="m7 15 4-5 3 3 5-6"/>',
    archive: '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4"/>',
    key: '<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M17 6l2 2M15 8l2 2"/>',
    // The vault: a safe, its door, the dial and its handle, the feet. In outline, as the others; few strokes so it reads at 16px.
    vault: '<rect x="3.5" y="3" width="17" height="16" rx="3"/><rect x="6.5" y="6" width="11" height="10" rx="1.5"/><circle cx="10.5" cy="11" r="2"/><path d="M12.5 11h2.5M7 19v1.5M17 19v1.5"/>',
    link: '<path d="M9.5 14.5l5-5M8 11l-2 2a3.5 3.5 0 0 0 5 5l2-2M16 13l2-2a3.5 3.5 0 0 0-5-5l-2 2"/>',
    shield: '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6z"/><path d="m9 12 2 2 4-4"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    minus: '<path d="M5 12h14"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>',
    search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
    copy: '<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M15 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h3"/>',
    send: '<path d="m3 3 18 9-18 9 4-9zM7 12h14"/>',
    location: '<path d="M19 10c0 5-7 11-7 11S5 15 5 10a7 7 0 0 1 14 0z"/><circle cx="12" cy="10" r="2"/>',
    check: '<path d="m5 12 4.5 4.5L19 7"/>',
    warning: '<path d="m12 3 10 18H2zM12 9v5M12 17h.01"/>',
    download: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
    image: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><circle cx="8.5" cy="9.5" r="1.6"/><path d="m21 15.5-4.5-4.5L7 19.5"/>',
    restore: '<path d="M4 12a8 8 0 1 0 2.4-5.7L4 8.6"/><path d="M4 4v4.6h4.6"/>',
    history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6M3.5 4.5V9H8"/><path d="M12 7.5V12l3 2"/>',
    workflow: '<rect x="3" y="3.5" width="6" height="5" rx="1.5"/><rect x="15" y="9.5" width="6" height="5" rx="1.5"/><rect x="3" y="15.5" width="6" height="5" rx="1.5"/><path d="M9 6h3a1.5 1.5 0 0 1 1.5 1.5V12M9 18h3a1.5 1.5 0 0 0 1.5-1.5V12M13.5 12H15"/>',
    sliders: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
    upload: '<path d="M12 15V4"/><path d="M7 9l5-5 5 5"/><path d="M5 20h14"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    file: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    clipboard: '<rect x="8" y="3" width="8" height="4" rx="1"/><path d="M16 5h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2"/>',
    back: '<path d="M15 18l-6-6 6-6"/>',
    forward: '<path d="M9 6l6 6-6 6"/>',
    up: '<path d="M6 15l6-6 6 6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    down: '<path d="M6 9l6 6 6-6"/>',
    // Energy (the Status page's Energy section): solar, the home, a battery, the grid's pylon, power, solar's share.
    globe: '<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
    house: '<path d="M4 10.5 12 4l8 6.5V20a1 1 0 0 1-1 1h-4.5v-6h-5v6H5a1 1 0 0 1-1-1z"/>',
    battery: '<rect x="2.5" y="7" width="16.5" height="10" rx="2.5"/><path d="M21.5 10.5v3M6 10.5v3M9.5 10.5v3"/>',
    pylon: '<path d="M9 21l3-18 3 18M6 7.5h12M7.5 12.5h9M10.3 12.5 14.2 21M13.7 12.5 9.8 21"/>',
    bolt: '<path d="M13 2.5 5 13.5h6l-1 8 8-11h-6z"/>',
    leaf: '<path d="M5 19c0-8 5-14 15-14 0 10-6 15-14 15M5 19l7-7"/>',
    bug: '<rect x="8" y="7" width="8" height="12" rx="4"/><path d="M9.5 7.5a2.5 2.5 0 0 1 5 0M12 11v8M4 9l4 2M20 9l-4 2M3.5 14h4.5M16 14h4.5M4 19.5l4.3-2M20 19.5l-4.3-2"/>',
  };

  /// A button's icon before its text (`actionIcon`, `data-action-icon`): the icon as an SVG data: URL in
  /// `--action-icon`, which the stylesheet uses as a mask. Each icon's URL is made once.
  const actionIconURLs = new Map();
  function decorateAction(node, name) {
    node.classList.add("action-with-icon");
    let url = actionIconURLs.get(name);
    if (!url) {
      const attributes = Object.entries(iconAttributes(1.8, "black")).map(([key, value]) => `${key}="${value}"`).join(" ");
      const svg = `<svg xmlns="http://www.w3.org/2000/svg" ${attributes}>${icons[name] ?? icons.generic}</svg>`;
      url = `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
      actionIconURLs.set(name, url);
    }
    node.style.setProperty("--action-icon", url);
  }

  /// The attributes of an icon: a line drawing (no fill) of `stroke` (the current colour by default) at `strokeWidth`.
  const iconAttributes = (strokeWidth, stroke = "currentColor") => ({ viewBox: "0 0 24 24", fill: "none", stroke, "stroke-width": String(strokeWidth), "stroke-linecap": "round", "stroke-linejoin": "round" });

  /// An icon as an SVG element, drawn as the UI's icons are (lines of the current colour) by its own attributes, so
  /// one placed where no style sizes and strokes it is still a line drawing, not a filled shape; a style overrides them.
  // Brand logos the plugins name as their icon (`HomeswiftPlugin.icon`), from Simple Icons (CC0, simple-icons 16.33.0; THIRD-PARTY-NOTICES.md):
  // filled shapes, in the icon's colour. A square mark is drawn smaller than its 24-unit square for the margin the
  // stroked icons have; a wordmark (Hue, LG, IKEA) is already short, so it keeps the full width, Hue's thin letters
  // traced a little heavier to stay readable at node size.
  const logos = {
    "logo-hue": "M20.672 9.6c-2.043 0-3.505 1.386-3.682 3.416h-.664c-.247 0-.395.144-.395.384 0 .24.148.384.395.384h.661c.152 2.09 1.652 3.423 3.915 3.423.944 0 1.685-.144 2.332-.453.158-.075.337-.217.292-.471a.334.334 0 0 0-.15-.242c-.104-.065-.25-.072-.422-.02a7.93 7.93 0 0 0-.352.12c-.414.146-.771.273-1.599.273-1.75 0-2.908-1.023-2.952-2.605v-.025h5.444c.313 0 .492-.164.505-.463v-.058C23.994 9.865 21.452 9.6 20.672 9.6zm2.376 3.416h-5l.004-.035c.121-1.58 1.161-2.601 2.649-2.601 1.134 0 2.347.685 2.347 2.606zM9.542 10.221c0-.335-.195-.534-.52-.534s-.52.2-.52.534v2.795h1.04zm4.29 3.817c0 1.324-.948 2.361-2.16 2.361-1.433 0-2.13-.763-2.13-2.333v-.282h-1.04v.34c0 2.046.965 3.083 2.868 3.083 1.12 0 1.943-.486 2.443-1.445l.02-.036v.861c0 .334.193.534.519.534.325 0 .52-.2.52-.534v-2.803h-1.04zm.52-4.351c-.326 0-.52.2-.52.534v2.795h1.04v-2.795c0-.335-.195-.534-.52-.534zM3.645 9.6c-1.66 0-2.31 1.072-2.471 1.4l-.135.278V7.355c0-.347-.199-.562-.52-.562-.32 0-.519.215-.519.562v5.661h1.039v-.015c0-1.249.72-2.592 2.304-2.592 1.29 0 2.001.828 2.001 2.332v.275h1.04v-.246c0-2.044-.973-3.17-2.739-3.17zM0 16.558c0 .347.199.563.52.563.32 0 .519-.216.519-.563v-2.774H0zm5.344 0c0 .347.2.563.52.563s.52-.216.52-.563v-2.774h-1.04z",
    "logo-lg": "M14.522 14.078h3.27v1.33h-4.847v-6.83h1.577v5.5zm6.74-1.274h1.284v1.195c-.236.09-.698.18-1.137.18-1.42 0-1.893-.721-1.893-2.186 0-1.398.45-2.221 1.869-2.221.791 0 1.24.248 1.612.722l.982-.903c-.6-.855-1.646-1.114-2.629-1.114-2.208 0-3.368 1.205-3.368 3.504 0 2.288 1.047 3.528 3.358 3.528 1.06 0 2.096-.27 2.66-.665V11.53h-2.739v1.274zM5.291 6.709a5.29 5.29 0 1 1 0 10.582 5.291 5.291 0 1 1 0-10.582m3.16 8.457a4.445 4.445 0 0 0 1.31-3.161v-.242l-.22.001H6.596v.494h2.662l-.001.015a3.985 3.985 0 0 1-3.965 3.708 3.95 3.95 0 0 1-2.811-1.165 3.952 3.952 0 0 1-1.164-2.811c0-1.061.414-2.059 1.164-2.81a3.951 3.951 0 0 1 2.81-1.164l.252.003v-.495l-.251-.003a4.475 4.475 0 0 0-4.47 4.469c0 1.194.465 2.316 1.309 3.161a4.444 4.444 0 0 0 3.16 1.31 4.444 4.444 0 0 0 3.162-1.31m-2.91-1.297V9.644H5.04v4.72h1.556v-.495H5.543zm-1.265-3.552a.676.676 0 1 0-.675.674.676.676 0 0 0 .675-.674",
    "logo-ubiquiti": "M23.1627 0h-1.4882v1.4882h1.4882zm-5.2072 10.4226V7.4409l.0007.001h2.9755v2.9762h2.9756v.9433c0 1.0906-.0927 2.3827-.306 3.3973-.1194.5672-.3004 1.1308-.5127 1.672-.2175.5537-.468 1.0841-.7408 1.5595a11.6795 11.6795 0 0 1-1.2456 1.7762l-.0253.0294-.0417.0488c-.1148.1347-.2283.2679-.3531.398a11.7612 11.7612 0 0 1-.4494.4492c-1.9046 1.8343-4.3861 2.98-6.9808 3.243-.3122.032-.939.0652-1.2519.0652-.3139-.001-.9397-.0331-1.252-.0651-2.5946-.263-5.0761-1.4097-6.9806-3.243a11.75 11.75 0 0 1-.4495-.4494c-.131-.1356-.249-.2748-.3683-.4154l-.0006-.0004-.0512-.0603a11.6576 11.6576 0 0 1-1.2456-1.7762c-.2727-.4763-.5233-1.0058-.7408-1.5595-.2123-.5414-.3933-1.1048-.5128-1.6718C.1854 13.743.0927 12.452.0927 11.3616V.1864h5.9518v10.2362s0 .7847.0099 1.0415l.0022.0599v.0004c.0127.332.0247.6575.0594.9812.098.919.3014 1.7913.7203 2.5288.1213.213.2443.42.3915.616.8953 1.1939 2.2577 2.0901 3.9573 2.3398.2022.0294.6108.0552.8149.0552.204 0 .6125-.0258.8149-.0552 1.6996-.2497 3.062-1.146 3.9573-2.3398.148-.196.2701-.403.3914-.616.419-.7375.6224-1.6095.7204-2.5288.0346-.3243.047-.6503.0594-.9831l.0022-.0584c.0099-.2568.0099-1.0415.0099-1.0415zm.7427-8.19h2.2326v2.2319h2.9764v2.9764h-2.9764V4.4654h-2.2326V2.2328Z",
    "logo-ecoflow": "M2.0 8.0h9.62v1.58H2.0zM2.0 11.21h9.62v1.58H2.0zM2.0 14.42h9.62v1.58H2.0zM12.57 8.0h9.43v1.58H12.57zM12.57 11.21h9.43v1.58H12.57zM12.57 11.21h1.58v4.79H12.57z",
    "logo-elgato": "m13.8818 8.3964.0261.0196 9.9494 5.7172c-.4884 2.729-1.9196 5.2223-4.0384 7.0253A11.9262 11.9262 0 0 1 12.097 24c-3.1925 0-6.1939-1.2477-8.4527-3.5144C1.3868 18.2188.1427 15.2044.1427 12c0-3.2042 1.244-6.2187 3.5015-8.4854C5.9019 1.248 8.9032 0 12.097 0c2.4394 0 4.7847.7333 6.783 2.1187 1.9526 1.354 3.4466 3.2357 4.3227 5.4422.1112.2829.2149.5736.3051.8657l-2.1255 1.2359a9.4924 9.4924 0 0 0-.2619-.8694c-1.354-3.8303-4.9813-6.4048-9.0237-6.4048C6.8171 2.3883 2.522 6.7005 2.522 12c0 5.2995 4.295 9.6115 9.5748 9.6115 2.052 0 4.0084-.6442 5.6596-1.8647 1.6172-1.1955 2.8036-2.8337 3.4309-4.7364l.0065-.0419L9.5906 8.3048v7.2256l4.0004-2.3138 2.06 1.1811-5.9962 3.4688-2.12-1.2126V7.1943l2.1174-1.2245 4.2309 2.4279-.0013-.0013",
    "logo-ikea": "M0 7.2v9.6h24V7.2H0zm12.002 9.12C5.308 16.32.48 14.36.48 12s4.831-4.32 11.522-4.32c6.69 0 11.518 1.96 11.518 4.32s-4.824 4.32-11.518 4.32zm-.225-6.062h4.176v.964c-.103-.047-.203-.047-.306-.047h-1.758v.46h1.689v.732h-1.689v.457h1.758c.103 0 .203 0 .306-.05v.967h-4.176c.052-.101.052-.198.052-.299V10.56c0-.101 0-.198-.052-.302zm-7.076.302v2.881c0 .101 0 .198.052.299H2.4c.052-.101.052-.198.052-.299V10.56c0-.101 0-.198-.052-.299h2.353c-.052.101-.052.198-.052.299zm6.447 2.881c.076.107.158.208.255.299H8.805c0-.101-.1-.306-.21-.467-.11-.161-.705-1.044-.705-1.044v1.212c0 .101 0 .198.052.299H5.778c.052-.101.052-.198.052-.299V10.56c0-.101 0-.198-.052-.299h2.164c-.052.101-.052.198-.052.299v1.259s.691-.88.85-1.085c.12-.154.268-.373.268-.473h2.257c-.155.101-.327.282-.468.45l-.826.984s1.039 1.548 1.177 1.746zm10.546-3.005a.178.178 0 0 0-.175-.178h-.21v.551h.083v-.195h.12l.11.195h.093l-.12-.212a.184.184 0 0 0 .099-.161zm-.189.101h-.114v-.191h.124c.055 0 .093.047.093.101 0 .053-.048.093-.103.09zm-.021-.457h-.031a.444.444 0 0 0-.437.457c0 .007 0 .017-.003.023a.466.466 0 0 0 .482.447.464.464 0 0 0 .458-.47v-.017a.454.454 0 0 0-.469-.44zm0 .823a.372.372 0 0 1-.375-.366v-.027a.357.357 0 0 1 .375-.339c.206 0 .375.165.375.366s-.168.366-.375.366zm-.877-.339c-.038-.101-.093-.198-.065-.299h-3.017c.014.101-.024.198-.062.299l-1.07 2.881a.852.852 0 0 1-.162.299h1.785c-.014-.101.024-.198.058-.299.034-.101.072-.198.072-.198l.021-.054h1.304l.021.05c.048.118.083.198.083.198.041.101.079.198.069.299h2.263a.837.837 0 0 1-.169-.299 690.277 690.277 0 0 0-1.131-2.877zm-2.167 1.893c.155-.42.289-.772.299-.806.028-.074.048-.151.062-.228.017.077.041.154.069.228l.316.806h-.746z",
  };
  const wordmarks = new Set(["logo-hue", "logo-lg", "logo-ikea", "logo-ecoflow"]);
  for (const [name, d] of Object.entries(logos)) icons[name] = `<path d="${d}"${wordmarks.has(name) ? "" : ` transform="translate(3.6 3.6) scale(.7)"`} style="fill: currentColor; ${
    name === "logo-hue" ? "stroke: currentColor; stroke-width: .7; stroke-linejoin: round" : "stroke: none"}"/>`;

  function icon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    for (const [key, value] of Object.entries(iconAttributes(2))) svg.setAttribute(key, value);
    svg.classList.add(`icon-${name}`);
    svg.innerHTML = icons[name] ?? icons.generic;
    return svg;
  }

  /// A page's views as a row of links under its title, a glyph each, the current one lit (a phone puts the glyph over
  /// the name): `pages` are [path, text, glyph] under `base`, the glyph an icon's name or an element.
  function subnav(label, base, pages, current) {
    const nav = el("nav", { class: "group subnav", "aria-label": label }, pages.map(([path, text, glyph]) =>
      el("a", { href: `${base}${path ? `/${path}` : ""}`, class: path === current ? "on" : "", "aria-current": path === current ? "page" : null },
        typeof glyph === "string" ? icon(glyph) : glyph, el("span", { text }))));
    // A row wider than the window scrolls: its edges fade where tabs are hidden, and the current tab starts in view.
    const edges = () => {
      const more = nav.scrollWidth - nav.clientWidth;
      nav.toggleAttribute("data-more-start", nav.scrollLeft > 2);
      nav.toggleAttribute("data-more-end", more > 2 && nav.scrollLeft < more - 2);
    };
    nav.addEventListener("scroll", edges, { passive: true });
    new ResizeObserver(edges).observe(nav);
    requestAnimationFrame(() => {
      const on = nav.querySelector("a.on");
      if (on && nav.scrollWidth > nav.clientWidth) nav.scrollLeft = Math.max(0, on.offsetLeft + on.offsetWidth / 2 - nav.clientWidth / 2);
      edges();
    });
    return nav;
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

  /// Text as searches compare it: without accents or case, so "salon" finds "Salón".
  const fold = (text) => String(text ?? "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

  /// Opens a menu under `trigger`. Each item: { label, icon (a name or a node), href or onSelect, danger or accent }, or
  /// { separator: true }; `checked` makes a ticked choice. { label, choices: [{ label, badge, checked, onSelect }] }
  /// draws a labelled row of square choices, such as the widget sizes.
  /// Opened from the keyboard, its first item takes the focus; from a click, the menu does, so no item looks
  /// chosen before the pointer or an arrow key gets to it. `search` (its placeholder) puts a search field on top that
  /// keeps the items whose label holds what is typed, and takes the focus instead; an item with `pinned` always stays.
  function menu(trigger, items, { keyboard = false, onReorder, search } = {}) {
    if (openMenu?.trigger === trigger) { openMenu.close(); return; }
    openMenu?.close(true);
    let pending = false, cancelDrag = null;
    const refreshDisabled = [];
    const searchable = [];
    const nodes = items.filter(Boolean).map((item) => {
      if (item.separator) return el("hr", { class: "menu-separator", role: "separator" });
      if (item.choices) {
        const choices = item.choices.map((choice) => {
          const button = el("button", { type: "button", role: "menuitemradio", class: "menu-choice-badge", tabIndex: -1,
            "aria-label": choice.label, title: choice.label, "aria-checked": String(!!choice.checked), text: choice.badge });
          button.addEventListener("click", () => { close(); choice.onSelect?.(); });
          return button;
        });
        return el("div", { class: "menu-choices", role: "group", "aria-label": item.label },
          el("span", { class: "menu-choice-label", text: item.label }), el("div", { class: "menu-choice-row" }, choices));
      }
      // Who the menu is about (the header's account menu): a name and a line under it, not an action.
      if (item.heading !== undefined) return el("div", { class: "menu-heading" }, el("strong", { text: item.heading }), item.detail ? el("span", { text: item.detail }) : null);
      const glyph = typeof item.icon === "string" ? icon(item.icon) : item.icon ?? null;
      const choice = typeof item.checked === "boolean";
      const role = choice ? (item.checkbox ? "menuitemcheckbox" : "menuitemradio") : "menuitem";
      const tick = item.toggle ? el("span", { class: "menu-toggle", "aria-hidden": "true" }, el("span"))
        : choice ? el("span", { class: "menu-check", "aria-hidden": "true", text: item.checked ? "✓" : "" }) : null;
      const count = item.count === undefined ? null : el("span", { class: "menu-item-count", text: String(item.count) });
      const node = item.href
        ? el("a", { role, href: item.href, class: item.danger ? "danger" : item.accent ? "accent" : "", tabIndex: -1 }, glyph, el("span", { class: "menu-item-label", text: item.label }), count, tick)
        : el("button", { type: "button", role, class: item.danger ? "danger" : item.accent ? "accent" : "", tabIndex: -1, "aria-checked": choice ? String(item.checked) : null }, glyph, el("span", { class: "menu-item-label", text: item.label }), count, tick);
      if (item.clearFilters) node.classList.add("clear-filters-menu");
      const isDisabled = () => (typeof item.disabled === "function" ? item.disabled() : Boolean(item.disabled)) || (item.count === 0 && item.checked === false);
      const updateDisabled = () => {
        if (isDisabled()) node.setAttribute("aria-disabled", "true"); else node.removeAttribute("aria-disabled");
        if (node.tagName === "BUTTON") node.disabled = isDisabled();
        node.title = isDisabled() && item.count === 0 ? (item.disabledReason || t("No accessories match the current search.")) : "";
      };
      updateDisabled();
      refreshDisabled.push(updateDisabled);
      if (["ok", "warn", "error"].includes(item.tone)) node.dataset.tone = item.tone;
      if (onReorder && item.key) {
        node.dataset.menuKey = item.key;
        const handle = el("span", { class: "menu-drag-handle", title: t("Drag to reorder"), "aria-hidden": "true", text: "⠿" });
        handle.addEventListener("click", (event) => { event.preventDefault(); event.stopPropagation(); });
        handle.addEventListener("pointerdown", (event) => {
          if (event.button !== 0 || pending) return;
          event.preventDefault(); event.stopPropagation();
          const rows = () => [...list.querySelectorAll(":scope > [data-menu-key]")];
          const before = rows(), anchor = before.at(-1).nextSibling;
          const restore = (order) => order.forEach((row) => list.insertBefore(row, anchor));
          node.classList.add("menu-dragging");
          list.setPointerCapture(event.pointerId);
          const move = (pointer) => {
            if (pointer.pointerId !== event.pointerId) return;
            const other = rows().find((row) => {
              const box = row.getBoundingClientRect();
              return row !== node && pointer.clientY >= box.top && pointer.clientY <= box.bottom;
            });
            if (!other) return;
            const box = other.getBoundingClientRect();
            if (pointer.clientY > box.top + box.height / 2) other.after(node); else other.before(node);
          };
          const finish = async (pointer) => {
            if (pointer && pointer.pointerId !== event.pointerId) return;
            list.removeEventListener("pointermove", move);
            list.removeEventListener("pointerup", finish);
            list.removeEventListener("pointercancel", finish);
            list.removeEventListener("lostpointercapture", finish);
            cancelDrag = null;
            node.classList.remove("menu-dragging");
            if (list.hasPointerCapture(event.pointerId)) list.releasePointerCapture(event.pointerId);
            if (pointer?.type !== "pointerup") { restore(before); return; }
            pending = true;
            try {
              const saved = await onReorder(rows().map((row) => row.dataset.menuKey));
              refreshDisabled.forEach((update) => update());
              if (saved) restore(saved.map((id) => before.find((row) => row.dataset.menuKey === id)).filter(Boolean));
            } catch { restore(before); }
            finally { pending = false; }
          };
          cancelDrag = () => finish();
          list.addEventListener("pointermove", move);
          list.addEventListener("pointerup", finish);
          list.addEventListener("pointercancel", finish);
          list.addEventListener("lostpointercapture", finish);
        });
        node.prepend(handle);
      }
      node.addEventListener("click", async (event) => {
        if (isDisabled()) { event.preventDefault(); return; }
        if (pending || event.target.closest(".menu-drag-handle")) return;
        if (!item.keepOpen) { close(); item.onSelect?.(); return; }
        pending = true;
        node.setAttribute("aria-busy", "true");
        try {
          const checked = await item.onSelect?.();
          if (typeof checked === "boolean") node.setAttribute("aria-checked", String(checked));
        } finally { pending = false; node.removeAttribute("aria-busy"); }
      });
      if (search && !item.pinned && item.label) searchable.push([node, fold(item.label)]);
      return node;
    });
    const entries = () => [...list.querySelectorAll('[role^="menuitem"]:not([aria-disabled="true"]):not(.hidden)')];
    // The search field: what is typed, without case or accents, against each item's label.
    const field = search ? el("input", { type: "search", class: "menu-search", placeholder: search, "aria-label": search, autocomplete: "off" }) : null;
    const nothing = search ? el("p", { class: "menu-empty muted hidden", text: t("Nothing matches.") }) : null;
    if (field) {
      field.addEventListener("input", () => {
        const query = fold(field.value.trim());
        let shown = 0;
        for (const [node, label] of searchable) {
          const match = !query || label.includes(query);
          node.classList.toggle("hidden", !match);
          if (match) shown++;
        }
        nothing.classList.toggle("hidden", !searchable.length || shown > 0);
      });
      nodes.unshift(field, nothing);
    }
    // On a phone a card's menu is an action sheet over a dimmed page, at the bottom within the thumb's reach, as
    // iOS's; the header's (the account) still drops down from its button.
    const sheet = matchMedia("(max-width: 640px)").matches && !trigger.closest("header");
    const list = el("div", { class: `menu${sheet ? " sheet-menu" : ""}`, role: "menu", tabIndex: -1, "aria-label": trigger.getAttribute("aria-label") || t("Actions") }, nodes);
    const scrim = sheet ? el("div", { class: "menu-scrim", "aria-hidden": "true" }) : null;
    // A sheet's grabber: a swipe down from it puts the sheet away, as the scrim's tap does.
    if (sheet) {
      list.prepend(el("div", { class: "sheet-grabber", "aria-hidden": "true" }));
      dragToDismiss(list, { vertical: () => true, dismiss: () => close(true), handle: ".sheet-grabber" });
    }
    const host = layerHost(trigger);
    if (scrim) host.append(scrim);
    host.append(list);
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
    const focusAt = (index) => entries()[(index + entries().length) % entries().length]?.focus();
    const onKey = (event) => {
      // In the search field the keys edit the text; Down goes to the first item it keeps, Enter chooses it.
      if (field && document.activeElement === field) {
        if (event.key === "Escape") { event.preventDefault(); close(); }
        else if (event.key === "ArrowDown") { event.preventDefault(); focusAt(0); }
        else if (event.key === "Enter") { event.preventDefault(); entries()[0]?.click(); }
        else if (event.key === "Tab") close(true);
        return;
      }
      const index = entries().indexOf(document.activeElement);
      if (event.key === "ArrowUp" && field && index <= 0) { event.preventDefault(); field.focus(); return; }
      if (event.key === "Escape") { event.preventDefault(); close(); }
      else if ((event.key === "ArrowLeft" || event.key === "ArrowRight") && document.activeElement.closest(".menu-choice-row")) {
        event.preventDefault();
        const choices = [...document.activeElement.parentElement.children];
        const next = choices.indexOf(document.activeElement) + (event.key === "ArrowRight" ? 1 : -1);
        choices[(next + choices.length) % choices.length].focus();
      }
      else if (event.key === "ArrowDown") { event.preventDefault(); focusAt(index + 1); }
      else if (event.key === "ArrowUp") { event.preventDefault(); focusAt(index < 0 ? -1 : index - 1); }
      else if (event.key === "Home") { event.preventDefault(); focusAt(0); }
      else if (event.key === "End") { event.preventDefault(); focusAt(-1); }
      else if (event.key === "Tab") close(true);
    };
    const onPointer = (event) => { if (!list.contains(event.target) && !trigger.contains(event.target)) close(true); };
    function close(quietly = false) {
      if (openMenu?.list !== list) return;
      cancelDrag?.();
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
    // A search field takes the focus, but not on a phone's sheet, where the keyboard would cover the items.
    if (field && !sheet) field.focus({ preventScroll: true });
    else if (keyboard) focusAt(0); else list.focus({ preventScroll: true });
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
  /// When this page last asked the bridge to change something: what it made itself, a change event shortly after
  /// tells it nothing new.
  let lastChange = 0;
  async function api(path, { method = "GET", body, stream = false } = {}) {
    if (method !== "GET") lastChange = Date.now();
    // The Assistant answers in the page's language.
    const options = { method, credentials: "same-origin", headers: { "Accept-Language": window.HomeswiftI18n?.locale || "en" } };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = JSON.stringify(body); }
    const response = await fetch(path, options);
    if (response.status === 401) { location.href = "/"; throw new Error("signed out"); }
    if (stream && response.ok) return response;
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { error: text }; }
    if (!response.ok) throw Object.assign(new Error(window.HomeswiftI18n?.message((json && json.error) || `HTTP ${response.status}`) ?? `HTTP ${response.status}`), { status: response.status });
    return json;
  }

  /// Where floating UI opened from `anchor` goes: the open modal dialog it is in (an accessory's sheet), which is in the
  /// top layer over the rest of the page, else the page.
  const layerHost = (anchor) => anchor?.closest?.("dialog[open]") ?? document.body;

  /// Puts `text` on the clipboard. The Clipboard API exists only over HTTPS or on localhost; a page on the
  /// network over plain HTTP, or a browser that refuses the API (an embedded one without the permission), copies
  /// through a hidden text field instead.
  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try { return await navigator.clipboard.writeText(text); } catch {}
    }
    const field = el("textarea", { value: text, readOnly: true, style: "position:fixed;top:-1000px;opacity:0" });
    // Outside an open modal dialog the field is inert: it could not be selected.
    layerHost(document.activeElement).append(field);
    field.select();
    const copied = document.execCommand("copy");
    field.remove();
    if (!copied) throw new Error(t("The browser did not allow copying."));
  }

  // ---- JSON, coloured -----------------------------------------------------------------------------------
  // Keys, strings, numbers, true, false and null each in a colour; punctuation quiet. Text nodes only, never HTML.

  const jsonToken = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false)\b|\b(null)\b|([{}[\],:])/g;

  /// `text` (JSON, or almost: it is being typed) as coloured spans. A key `secretKey(name)` says is a secret is
  /// marked, a lock before it, and so is its value when it is a string.
  function jsonHighlight(text, { secretKey } = {}) {
    const fragment = document.createDocumentFragment();
    let last = 0, secretValue = false;
    const isSecret = (key) => { try { return Boolean(secretKey?.(JSON.parse(key))); } catch { return false; } };
    for (const match of text.matchAll(jsonToken)) {
      if (match.index > last) fragment.append(text.slice(last, match.index));
      const [whole, string, colon, number, boolean, nil] = match;
      const kind = string ? (colon ? "key" : "string") : number ? "number" : boolean ? "bool" : nil ? "null" : "punct";
      if (string && colon && isSecret(string)) {
        fragment.append(el("span", { class: "json-key json-secret" }, icon("lock"), string));
        secretValue = true;
      } else {
        fragment.append(el("span", { class: `json-${kind}${secretValue && kind === "string" ? " json-secret-value" : ""}`, text: string && colon ? string : whole }));
        secretValue = false;
      }
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
        if (at >= text.length) fail(t("This string is not closed"));
        const character = text[at];
        if (character === '"') { at++; return; }
        if (character === "\\") {
          const next = text[at + 1];
          if (next === "u" && /^[0-9a-fA-F]{4}$/.test(text.slice(at + 2, at + 6))) at += 6;
          else if (next !== undefined && "\"\\/bfnrt".includes(next)) at += 2;
          else fail(t("Not a valid escape in a string"));
          continue;
        }
        if (character === "\n") fail(t("This string is not closed before the end of the line"));
        if (character < " ") fail(t("A control character in a string must be escaped"));
        at++;
      }
    };
    // A missing comma is reported where it belongs: after the value before it, on that value's line.
    const after = (end, closing) => {
      space();
      if (text[at] === ",") { at++; return false; }
      if (text[at] === closing) { at++; return true; }
      fail(at >= text.length
        ? (closing === "}" ? t("The text ends before this object is closed") : t("The text ends before this list is closed"))
        : (closing === "}" ? t("A comma or a closing brace is missing after this value") : t("A comma or a closing bracket is missing after this value")), end);
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
          if (text[at] !== '"') fail(text[at] === "}" ? t("A comma before the closing brace") : at >= text.length ? t("The text ends before this object is closed") : t("Expected a key in double quotes"));
          const start = at;
          string();
          const key = JSON.parse(text.slice(start, at));
          places.set(JSON.stringify([...path, key]), start);
          space();
          if (text[at] !== ":") fail(t("A colon is missing after this key"));
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
          if (text[at] === "]") fail(t("A comma before the closing bracket"));
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
      fail(at >= text.length ? t("The text ends where a value should be") : character === "'" ? t("Strings take double quotes") : t("Not a valid value"));
    };
    try {
      value([]);
      space();
      if (at < text.length) fail(t("Something follows the end of the JSON"));
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
  /// path is, or its nearest parent; returns `{ offset, line }` for each) and `reveal(offset)`. `secretKey(name)`
  /// marks the keys that hold secrets (the server's rule, as Redaction reads it).
  ///
  /// A block that spans lines folds from the chevron beside its first line (Option-click: every block at its
  /// indentation; ⌘⌥[ and ⌘⌥] at the caret): its inside becomes one "…" in the textarea, the text kept aside.
  /// The textarea's `value` and `setRangeText` are the whole text, so the page reads, sets and saves it as before;
  /// an edit that would reach into a fold opens it first, and one that damages a fold anyway is undone.
  function jsonEditor(textarea, { secretKey } = {}) {
    const layer = el("pre", { class: "code-layer", "aria-hidden": "true" });
    const rail = el("div", { class: "code-folds" });
    const gutter = el("div", { class: "code-gutter" }, rail);
    const wrapper = el("div", { class: "code-editor" }, layer, textarea, gutter);
    textarea.classList.add("code-input");
    const native = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value");
    const shown = () => native.get.call(textarea);
    // Each fold: where its "…" is in the text on screen, and the text it stands for. Sorted by place.
    let folds = [];
    // Secrets only (foldAllButSecrets) holds until a fold opens or closes otherwise, or the text is set: the editor
    // says so with a `folds` event, `{ secretsOnly, secrets }`, so the page's toggle never shows a state that is not.
    let secretsOnly = false, applyingSecrets = false, secretCount = 0;
    const report = () => wrapper.dispatchEvent(new CustomEvent("folds", { detail: { secretsOnly, secrets: secretCount } }));
    const leaveSecretsOnly = () => { if (secretsOnly && !applyingSecrets) { secretsOnly = false; report(); } };
    const expand = (text, list = folds, from = 0) => {
      let out = "", last = 0;
      for (const fold of list) { out += text.slice(last, fold.at - from) + fold.hidden; last = fold.at - from + 1; }
      return out + text.slice(last);
    };
    /// An offset in the whole text as one on screen, and the fold it is inside, if any.
    const onScreen = (offset) => {
      let shift = 0;
      for (const fold of folds) {
        const start = fold.at + shift;
        if (offset <= start) break;
        if (offset < start + fold.hidden.length) return { at: fold.at, fold };
        shift += fold.hidden.length - 1;
      }
      return { at: offset - shift };
    };
    /// Puts `text` on screen keeping the scroll and the selection, moved by `move(offset)`.
    const replace = (text, move) => {
      const { scrollTop, scrollLeft, selectionStart, selectionEnd } = textarea;
      const focused = document.activeElement === textarea;
      native.set.call(textarea, text);
      if (focused) textarea.setSelectionRange(move(selectionStart), move(selectionEnd));
      textarea.scrollTop = scrollTop;
      textarea.scrollLeft = scrollLeft;
      before = shown();
      schedule();
      leaveSecretsOnly();
    };
    const open = (chosen) => {
      if (!chosen.length) return;
      const text = shown();
      let out = "", last = 0, growth = 0;
      const moved = [];
      for (const fold of folds) {
        if (!chosen.includes(fold)) { moved.push({ ...fold, at: fold.at + growth }); continue; }
        out += text.slice(last, fold.at) + fold.hidden;
        last = fold.at + 1;
        growth += fold.hidden.length - 1;
      }
      const opened = folds.filter((fold) => chosen.includes(fold));
      folds = moved;
      replace(out + text.slice(last), (offset) => offset + opened.filter((fold) => fold.at < offset).reduce((sum, fold) => sum + fold.hidden.length - 1, 0));
    };
    /// Folds the ranges `[from, to)` of the text on screen into a "…" each, last first so the others hold.
    const fold = (ranges) => {
      let text = shown();
      ranges = ranges.filter((range) => range.to > range.from);
      for (const { from, to } of [...ranges].sort((a, b) => b.from - a.from)) {
        const inside = folds.filter((one) => one.at >= from && one.at < to);
        const hidden = expand(text.slice(from, to), inside, from);
        const shrink = to - from - 1;
        folds = folds.filter((one) => !inside.includes(one)).map((one) => (one.at >= to ? { ...one, at: one.at - shrink } : one));
        folds.push({ at: from, hidden });
        folds.sort((a, b) => a.at - b.at);
        text = text.slice(0, from) + "…" + text.slice(to);
      }
      // The caret inside a range that folds goes to its "…"; one after it moves back with the text.
      replace(text, (offset) => {
        let at = offset;
        for (const { from, to } of ranges) at -= offset >= to ? to - from - 1 : offset > from ? offset - from : 0;
        return at;
      });
    };
    /// Folds the insides of the blocks `{ start, end }` (the offsets of their brackets on screen).
    const close = (blocks) => fold(blocks.map(({ start, end }) => ({ from: start + 1, to: end })));
    Object.defineProperty(textarea, "value", {
      configurable: true,
      get: () => expand(shown()),
      set: (text) => { folds = []; native.set.call(textarea, text); before = shown(); leaveSecretsOnly(); },
    });
    textarea.setRangeText = (text, start = textarea.selectionStart, end = textarea.selectionEnd, mode = "preserve") => {
      // A fold in the range opens first, and the range takes in its text.
      const hit = folds.filter((fold) => fold.at >= start && fold.at < end);
      end += hit.reduce((sum, fold) => sum + fold.hidden.length - 1, 0);
      open(hit);
      const growth = text.length - (end - start);
      HTMLTextAreaElement.prototype.setRangeText.call(textarea, text, start, end, mode);
      folds = folds.map((fold) => (fold.at >= end ? { ...fold, at: fold.at + growth } : fold));
      before = shown();
      schedule();
    };

    // Edits around folds. `before` is the text on screen before the edit, `pending` where the browser will change it
    // when that is known; anything else is found by comparing the two texts.
    let before = shown(), pending = null;
    textarea.addEventListener("beforeinput", (event) => {
      const { selectionStart: start, selectionEnd: end } = textarea;
      const text = shown(), type = event.inputType;
      const lineStart = text.lastIndexOf("\n", start - 2) + 1;
      const after = (from) => { const index = text.indexOf("\n", from); return index < 0 ? text.length : index; };
      const lineEnd = after(after(end) + 1);
      const reach = start !== end ? [start, end]
        : type === "deleteContentBackward" ? [start - 1, start] : type === "deleteContentForward" ? [start, start + 1]
        : type.startsWith("delete") ? (type.endsWith("Backward") ? [lineStart, start] : [start, lineEnd]) : [start, start];
      const hit = folds.filter((fold) => fold.at >= reach[0] && fold.at < reach[1]);
      if (hit.length) { event.preventDefault(); open(hit); return; }
      before = text;
      pending = type.startsWith("history") || (start === end && type.startsWith("delete") && reach[1] - reach[0] !== 1) ? null : reach;
    });
    textarea.addEventListener("input", (event) => {
      const text = shown(), growth = text.length - before.length;
      let changed = pending;
      if (!changed) {
        let prefix = 0;
        while (prefix < before.length && prefix < text.length && before[prefix] === text[prefix]) prefix++;
        let suffix = 0;
        while (suffix < Math.min(before.length, text.length) - prefix && before[before.length - 1 - suffix] === text[text.length - 1 - suffix]) suffix++;
        changed = [prefix, before.length - suffix];
      }
      pending = null;
      if (folds.some((fold) => fold.at >= changed[0] && fold.at < changed[1])) {
        // An edit took a "…" with it: back to the whole text as it was, nothing lost.
        const whole = expand(before);
        folds = [];
        event.stopImmediatePropagation();
        replace(whole, () => whole.length);
        textarea.dispatchEvent(new Event("input"));
        return;
      }
      folds = folds.map((fold) => (fold.at >= changed[1] ? { ...fold, at: fold.at + growth } : fold));
      before = text;
    }, { capture: true });
    // A click on a "…" opens it.
    textarea.addEventListener("click", () => {
      if (textarea.selectionStart !== textarea.selectionEnd) return;
      const caret = textarea.selectionStart;
      open(folds.filter((fold) => fold.at === caret || fold.at === caret - 1));
    });

    let scheduled = false, blocks = [];
    // The line of a syntax error (check), else the places of a save's problems (markPaths), which an edit clears;
    // offsets in the whole text.
    let syntax = null, placed = [];
    /// The blocks on screen that span lines, by the line they open on (the first that opens there).
    const findBlocks = (text) => {
      const found = new Map(), stack = [];
      let line = 1;
      for (let i = 0; i < text.length; i++) {
        const character = text[i];
        if (character === "\n") line++;
        else if (character === '"') { for (i++; i < text.length && text[i] !== '"' && text[i] !== "\n"; i++) if (text[i] === "\\") i++; if (text[i] === "\n") line++; }
        else if (character === "{" || character === "[") stack.push({ start: i, line });
        else if (character === "}" || character === "]") {
          const opener = stack.pop();
          if (opener && opener.line !== line && !found.has(opener.line)) found.set(opener.line, { start: opener.start, end: i, line: opener.line });
        }
      }
      return found;
    };
    const indentOf = (text, line) => { const start = lineStarts(text)[line - 1]; let i = start; while (text[i] === " ") i++; return i - start; };
    let starts = null, startsOf = null;
    const lineStarts = (text) => {
      if (startsOf !== text) { starts = [0]; for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) starts.push(i + 1); startsOf = text; }
      return starts;
    };
    const lineOf = (text, offset) => {
      const list = lineStarts(text);
      let low = 0, high = list.length - 1;
      while (low < high) { const mid = (low + high + 1) >> 1; if (list[mid] <= offset) low = mid; else high = mid - 1; }
      return low + 1;
    };
    const toggle = (line, all) => {
      const text = shown();
      const folded = folds.filter((fold) => lineOf(text, fold.at) === line);
      if (folded.length) {
        if (!all) return open(folded);
        const indent = indentOf(text, line);
        return open(folds.filter((fold) => indentOf(text, lineOf(text, fold.at)) === indent));
      }
      const block = blocks.get(line);
      if (!block) return;
      if (!all) return close([block]);
      const indent = indentOf(text, line);
      close([...blocks.values()].filter((one) => indentOf(text, one.line) === indent));
    };
    const paint = () => {
      scheduled = false;
      const text = shown();
      const content = document.createDocumentFragment();
      let last = 0;
      for (const fold of folds) {
        content.append(jsonHighlight(text.slice(last, fold.at), { secretKey }), el("span", { class: "code-fold", text: "…" }));
        last = fold.at + 1;
      }
      // A final newline needs a character after it to take its line.
      content.append(jsonHighlight(text.slice(last), { secretKey }), "\n");
      layer.replaceChildren(content);
      // A marked line: a band under its text, as many line heights down as the line is from the top.
      const top = "var(--code-pad)";
      const marks = syntax === null ? placed : [syntax];
      for (const line of new Set(marks.map((offset) => lineOf(text, onScreen(offset).at)))) {
        layer.append(el("span", { class: "code-mark", style: `top: calc(${top} + ${line - 1} * var(--code-line))` }));
      }
      // The chevrons: one on each line a block opens on, turned on a folded one.
      blocks = findBlocks(text);
      const foldedLines = new Set(folds.map((fold) => lineOf(text, fold.at)));
      const toggles = [];
      for (const line of new Set([...blocks.keys(), ...foldedLines])) {
        const folded = foldedLines.has(line);
        const label = folded ? t("Expand") : t("Collapse");
        toggles.push(el("button", { type: "button", class: `code-fold-toggle${folded ? " folded" : ""}`, tabindex: "-1", "aria-label": label, title: label,
          "aria-expanded": String(!folded), style: `top: calc(${top} + ${line - 1} * var(--code-line))`,
          onclick: (event) => toggle(line, event.altKey) }, icon("down")));
      }
      rail.replaceChildren(...toggles);
      sync();
    };
    const sync = () => {
      layer.scrollTop = textarea.scrollTop;
      layer.scrollLeft = textarea.scrollLeft;
      rail.style.transform = `translateY(${-textarea.scrollTop}px)`;
    };
    const schedule = () => { if (!scheduled) { scheduled = true; requestAnimationFrame(paint); } };
    textarea.addEventListener("input", () => { placed = []; schedule(); });
    textarea.addEventListener("scroll", sync);
    // ⌘⌥[ folds the block the caret's line opens (else the one it is in), ⌘⌥] opens a fold on it.
    textarea.addEventListener("keydown", (event) => {
      if (!(event.metaKey || event.ctrlKey) || !event.altKey || (event.code !== "BracketLeft" && event.code !== "BracketRight")) return;
      event.preventDefault();
      const text = shown(), caret = textarea.selectionStart, line = lineOf(text, caret);
      if (event.code === "BracketRight") return open(folds.filter((fold) => lineOf(text, fold.at) === line));
      const around = blocks.get(line) ?? [...blocks.values()].filter((block) => block.start < caret && block.end >= caret).sort((a, b) => b.start - a.start)[0];
      if (around) close([around]);
    });
    // After the text is set in code: the problems' places no longer hold.
    wrapper.repaint = () => { placed = []; paint(); };
    /// Opens every fold.
    wrapper.openAll = () => { open([...folds]); leaveSecretsOnly(); };
    /// Folds everything that holds no secret: each block without one, then each run of lines left between the
    /// secret keys and the brackets on the way down to them, so what stays open is the secrets and their places. The
    /// value of a secret key stays whole (an object of credentials). Returns how many secret keys there are.
    wrapper.foldAllButSecrets = () => {
      applyingSecrets = true;
      try { secretCount = foldSecrets(); } finally { applyingSecrets = false; }
      secretsOnly = true;
      report();
      return secretCount;
    };
    const foldSecrets = () => {
      open([...folds]);
      const secretsIn = (text) => {
        const found = [];
        for (const match of text.matchAll(jsonToken)) {
          if (!match[1] || !match[2]) continue;
          try { if (secretKey?.(JSON.parse(match[1]))) found.push({ start: match.index, end: match.index + match[0].length }); } catch {}
        }
        return found;
      };
      const isValueOf = (key, block, text) => key.end <= block.start && !text.slice(key.end, block.start).trim();
      const holds = (block, keys, text) => keys.some((key) => (key.start > block.start && key.start < block.end) || isValueOf(key, block, text));
      let text = shown(), keys = secretsIn(text);
      const bare = [...findBlocks(text).values()].filter((block) => !holds(block, keys, text));
      close(bare.filter((block) => !bare.some((outer) => outer !== block && outer.start < block.start && outer.end > block.end)));
      // The lines to keep: a secret key's (and its value's), and the first and last of each block on the way to one.
      text = shown();
      keys = secretsIn(text);
      const kept = new Set();
      for (const key of keys) kept.add(lineOf(text, key.start));
      for (const block of findBlocks(text).values()) {
        if (!holds(block, keys, text)) continue;
        if (keys.some((key) => isValueOf(key, block, text))) for (let line = lineOf(text, block.start); line <= lineOf(text, block.end); line++) kept.add(line);
        kept.add(lineOf(text, block.start));
        kept.add(lineOf(text, block.end));
      }
      const starts = lineStarts(text), runs = [];
      let run = null;
      for (let line = 1; line <= starts.length; line++) {
        const from = starts[line - 1], to = line < starts.length ? starts[line] - 1 : text.length;
        if (kept.has(line) || !text.slice(from, to).trim()) { run = null; continue; }
        const first = from + (text.slice(from, to).length - text.slice(from, to).trimStart().length);
        if (run) run.to = to; else runs.push(run = { from: first, to });
      }
      fold(runs);
      return keys.length;
    };
    wrapper.check = () => {
      const result = jsonCheck(textarea.value);
      const next = result.offset ?? null;
      if (next !== syntax) { syntax = next; schedule(); }
      return result;
    };
    wrapper.markPaths = (paths) => {
      const whole = textarea.value;
      const { places } = jsonLocate(whole);
      const found = paths.map((path) => {
        let place = path;
        while (place.length && !places.has(JSON.stringify(place))) place = place.slice(0, -1);
        const offset = places.get(JSON.stringify(place)) ?? 0;
        return { offset, line: lineAt(whole, offset) };
      });
      placed = found.map((place) => place.offset);
      schedule();
      return found;
    };
    // The caret on the line, the line a third of the way down; the folds around it open.
    wrapper.reveal = (offset) => {
      for (let place = onScreen(offset); place.fold; place = onScreen(offset)) open([place.fold]);
      const at = onScreen(offset).at;
      textarea.focus({ preventScroll: true });
      textarea.setSelectionRange(at, at);
      const lineHeight = parseFloat(getComputedStyle(textarea).lineHeight) || 20;
      textarea.scrollTop = Math.max(0, (lineOf(shown(), at) - 1) * lineHeight - textarea.clientHeight / 3);
      wrapper.scrollIntoView({ block: "nearest" });
    };
    // A copy or a cut takes the whole text of the folds it covers.
    const copyWhole = (event) => {
      const { selectionStart: start, selectionEnd: end } = textarea;
      if (start === end || !folds.some((fold) => fold.at >= start && fold.at < end)) return;
      event.preventDefault();
      const inside = folds.filter((fold) => fold.at >= start && fold.at < end);
      event.clipboardData.setData("text/plain", expand(shown().slice(start, end), inside, start));
      if (event.type !== "cut") return;
      folds = folds.filter((fold) => !inside.includes(fold)).map((fold) => (fold.at >= end ? { ...fold, at: fold.at - (end - start) } : fold));
      HTMLTextAreaElement.prototype.setRangeText.call(textarea, "", start, end, "start");
      before = shown();
      textarea.dispatchEvent(new Event("input"));
    };
    textarea.addEventListener("copy", copyWhole);
    textarea.addEventListener("cut", copyWhole);
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

  const sections = [["/status", t("Status"), "bridge"], ["/accessories", t("Accessories"), "bulb"], ["/scenes", t("Scenes"), "play"], ["/plugins", t("Plugins"), "plugin"], ["/logs", t("Logs"), "logs"], ["/settings", t("Settings"), "gear"]];

  /// The sections at the bottom of a phone's screen, within the thumb's reach, as iOS puts them: an icon and
  /// a label each, the current one in the accent. `parent` is what hides it with the app (the sign-in screen has
  /// none). Hidden on wider windows, where the header holds them.
  function tabBar({ active, parent = document.body } = {}) {
    const existing = document.querySelector("nav.tabbar");
    if (existing) return existing;
    const panel = el("div", { class: "mobile-nav-panel", id: "mobile-nav-panel", hidden: true }, sections.map(([path, text, glyph]) =>
      el("a", { href: path, class: path === active ? "active" : "", "aria-current": path === active ? "page" : null }, icon(glyph), el("span", { text }))));
    const toggle = el("button", { type: "button", class: "mobile-nav-toggle", "aria-label": t("Sections"), "aria-expanded": "false", "aria-controls": "mobile-nav-panel" });
    toggle.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 6h14M5 12h14M5 18h14"/></svg>';
    const setOpen = (open) => { panel.hidden = !open; toggle.setAttribute("aria-expanded", String(open)); };
    panel.append(el("hr", { class: "mobile-nav-divider" }));
    panel.append(el("button", { type: "button", class: "mobile-nav-account", onclick: (event) => {
      event.stopPropagation();
      setOpen(false);
      document.dispatchEvent(new CustomEvent("homeswift-account-menu", { detail: { trigger: toggle, keyboard: event.detail === 0 } }));
    } }, icon("user"), el("span", { text: t("Account") })));
    toggle.addEventListener("click", () => setOpen(panel.hidden));
    panel.addEventListener("click", (event) => { if (event.target.closest("a")) setOpen(false); });
    const bar = el("nav", { class: "tabbar", "aria-label": t("Sections") }, panel, toggle);
    document.addEventListener("pointerdown", (event) => { if (!bar.contains(event.target)) setOpen(false); });
    bar.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { setOpen(false); toggle.focus(); }
      if (event.target === toggle && event.key === "ArrowUp") {
        event.preventDefault(); setOpen(true); panel.querySelector("a:not(.hidden)")?.focus();
      }
    });
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
    if (signal?.aborted) throw Object.assign(new Error(t("Stopped.")), { name: "AbortError" });
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
          else if (event === "error") throw Object.assign(new Error(window.HomeswiftI18n?.message(payload.error) ?? payload.error), { status: payload.status });
        }
      }
      throw new Error(signal?.aborted ? t("Stopped.") : t("The connection dropped before the answer ended."));
    } finally {
      signal?.removeEventListener("abort", cancel);
    }
  }

  // ---- Appearance: theme, wallpaper, temperature unit --------------------------------------------------------
  // Each user's choices live on the server (/api/preferences); this browser keeps the last ones it saw, so a page
  // opens in them before the server answers. Storage may be missing (a private window): it then waits.

  const preferenceKey = "homeswift.preferences";
  let preferences = { theme: "auto", wallpaper: "none", temperatureUnit: "c", language: "auto" };
  try { Object.assign(preferences, JSON.parse(localStorage.getItem(preferenceKey) || "{}")); } catch {}

  /// Applies the user's choices to this page (and remembers them in this browser): `data-theme` and
  /// `data-wallpaper` on the root element, which the stylesheet reads, and the unit temperatures show in.
  function applyPreferences(next) {
    // The bridge answers all of the user's choices: they replace the page's, so a key it dropped (the version of
    // a removed wallpaper) goes too.
    if (next) preferences = { ...next };
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
    // Another language is another catalog, which i18n.js loads before the page's scripts: the page opens again in it.
    // Only once this browser kept the choice, or the page would open again in the browser's language, and again.
    const I18N = window.HomeswiftI18n;
    if (next && I18N && I18N.resolve(preferences.language) !== I18N.language) {
      let kept = null;
      try { kept = JSON.parse(localStorage.getItem(preferenceKey) || "{}").language; } catch {}
      if (kept === preferences.language) { location.reload(); return preferences; }
    }
    document.dispatchEvent(new CustomEvent("homeswift:preferences", { detail: preferences }));
    return preferences;
  }
  applyPreferences();

  /// The user's choices from the server, applied; the ones this browser kept when it cannot be asked.
  async function loadPreferences() {
    try {
      let saved = await api("/api/preferences");
      // A language chosen on the sign-in page, before the server could keep it: the account keeps it now.
      let chosen = null;
      try { chosen = localStorage.getItem("homeswift.language-chosen"); localStorage.removeItem("homeswift.language-chosen"); } catch {}
      if (chosen && saved.language !== chosen) saved = await api("/api/preferences", { method: "PUT", body: { language: chosen } });
      return applyPreferences(saved);
    } catch { return preferences; }
  }

  /// A temperature HomeKit gives in °C, in the unit the user chose: `{ value, unit }`, the value rounded to a tenth.
  function temperature(celsius) {
    const value = Number(celsius);
    if (preferences.temperatureUnit === "f") return { value: Math.round((value * 1.8 + 32) * 10) / 10, unit: "°F" };
    return { value: Math.round(value * 10) / 10, unit: "°C" };
  }
  /// "just now", "4 min ago", "2 h ago", or the date: a Date, a time in milliseconds or an ISO 8601 string.
  function ago(date) {
    const when = new Date(date);
    const seconds = (Date.now() - when) / 1000;
    if (seconds < 45) return t("just now");
    if (seconds < 3600) return t("{minutes} min ago", { minutes: Math.round(seconds / 60) });
    if (seconds < 86400) return t("{hours} h ago", { hours: Math.round(seconds / 3600) });
    return when.toLocaleDateString(HomeswiftI18n.locale, { month: "short", day: "numeric" });
  }
  /// "21.5 °C" or "70.7 °F".
  const formatTemperature = (celsius) => { const { value, unit } = temperature(celsius); return `${value} ${unit}`; };

  // Keep native select values and form validation, but present choices with the shared menu.
  function openSelectMenu(select, keyboard = false) {
    const items = [];
    for (const child of select.children) {
      if (child.tagName === "OPTGROUP") {
        if (child.disabled) continue;
        items.push({ heading: child.label });
        for (const option of child.children) add(option);
      } else add(child);
    }
    function add(option) {
      if (option.tagName !== "OPTION" || option.hidden || option.disabled) return;
      items.push({ label: option.label, checked: option.selected, onSelect: () => {
        if (select.value === option.value) return;
        select.value = option.value;
        select.dispatchEvent(new Event("input", { bubbles: true }));
        select.dispatchEvent(new Event("change", { bubbles: true }));
      } });
    }
    if (items.length) menu(select, items, { keyboard });
  }
  document.addEventListener("pointerdown", (event) => {
    const select = event.target.closest("select");
    if (!select || select.disabled || select.multiple || select.size > 1 || event.button !== 0 || select.closest("dialog[open]")) return;
    event.preventDefault();
    select.focus();
    openSelectMenu(select);
  });
  document.addEventListener("keydown", (event) => {
    const select = event.target.closest("select");
    if (!select || select.disabled || select.multiple || select.size > 1 || select.closest("dialog[open]")) return;
    if ([" ", "Enter", "ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault(); openSelectMenu(select, true);
    }
  });

  // Reserve horizontal space only when a sticky save bar shares the floating menu's height.
  let saveBarFrame = 0;
  function updateSaveBarPosition() {
    if (saveBarFrame) return;
    saveBarFrame = requestAnimationFrame(() => {
      saveBarFrame = 0;
      const bars = document.querySelectorAll(".settings-bar");
      if (!bars.length) return;
      const toggle = document.querySelector(".mobile-nav-toggle");
      const mobile = matchMedia("(max-width: 640px)").matches;
      const menuRect = mobile && toggle ? toggle.getBoundingClientRect() : null;
      bars.forEach((bar) => {
        // Measured only beside a menu: a desktop page changing does not lay it out again.
        if (!menuRect) { bar.classList.remove("beside-mobile-menu"); return; }
        const rect = bar.getBoundingClientRect();
        const beside = menuRect && menuRect.height > 0 && rect.bottom > menuRect.top && rect.top < menuRect.bottom;
        bar.classList.toggle("beside-mobile-menu", Boolean(beside));
      });
    });
  }
  document.addEventListener("scroll", updateSaveBarPosition, { passive: true, capture: true });
  window.addEventListener("resize", updateSaveBarPosition, { passive: true });
  new MutationObserver(updateSaveBarPosition).observe(document.body, { childList: true, subtree: true });
  updateSaveBarPosition();

  const decorateStaticActions = () => document.querySelectorAll("[data-action-icon]").forEach((node) => decorateAction(node, node.dataset.actionIcon));
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", decorateStaticActions);
  else decorateStaticActions();

  // Controls declare their neutral value; reset all before notifying their listeners.
  function clearFilters(controls, { active = () => false, reset = () => {}, events = [] } = {}) {
    const value = (control) => control.type === "checkbox" ? control.checked : control.value;
    const button = el("button", { type: "button", class: "clear-filters", actionIcon: "restore", text: t("Clear filters"), onclick: () => {
      for (const [control, initial] of controls) {
        if (control.type === "checkbox") control.checked = initial; else control.value = initial;
      }
      reset();
      for (const [control] of controls) control.dispatchEvent(new Event(control.type === "search" ? "input" : "change"));
      update();
    } });
    const update = () => { button.disabled = !active() && controls.every(([control, initial]) => value(control) === initial); };
    for (const [control] of controls) for (const event of ["input", "change"]) control.addEventListener(event, update);
    for (const [control, event] of events) control.addEventListener(event, update);
    update();
    return button;
  }

  /// A time range, the one control every page uses for it (the Status page's Activity and Energy, the Logs page): a
  /// segmented control of `presets` (`[value, label]`: `latest`, `1h`, `6h`, `24h`, `today`, `yesterday`, `7d`), then
  /// Custom…, which opens a pop-over anchored to it, in the app's own material: a month to pick the first and the last
  /// day, and the From and To times (no browser calendar). Days more than `earliestDays` back, older than what is kept,
  /// are not offered. `span()` is `[from, to]`, `to` null when it ends now, or null for `latest`; `address(query)` keeps
  /// a choice other than `fallback` under `names` (`since`, `from`, `to`); `chosen()` says one is; `reset()` goes back to
  /// `fallback` without `changed`. The control sends `change` when its choice changes, for Clear filters.
  function rangeControl(params, { presets, fallback, names = { since: "since", from: "from", to: "to" }, earliestDays = 8, changed }) {
    const parse = (text) => { const date = text ? new Date(text) : null; return date && !isNaN(date) ? date : null; };
    const asked = params.get(names.since);
    let value = presets.some(([one]) => one === asked) || (asked === "custom" && parse(params.get(names.from))) ? asked : fallback;
    let custom = { from: parse(params.get(names.from)) ?? new Date(Date.now() - 3600000), to: parse(params.get(names.to)) };
    const presetButtons = presets.map(([one, text]) => el("button", { type: "button", role: "radio", text, onclick: () => choose(one) }));
    const customButton = el("button", { type: "button", role: "radio", class: "range-custom", "aria-haspopup": "dialog", "aria-expanded": "false", onclick: (event) => open(event.currentTarget) });
    const control = el("div", { class: "group range-control", role: "radiogroup", "aria-label": t("Time range") }, presetButtons, customButton);
    const shortTime = new Intl.DateTimeFormat(HomeswiftI18n.locale, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false });
    const describe = () => custom.to ? shortTime.formatRange(custom.from, custom.to) : t("Since {time}", { time: shortTime.format(custom.from) });

    function mark() {
      presetButtons.forEach((button, index) => {
        const on = presets[index][0] === value;
        button.classList.toggle("on", on);
        button.setAttribute("aria-checked", String(on));
      });
      customButton.classList.toggle("on", value === "custom");
      customButton.setAttribute("aria-checked", String(value === "custom"));
      customButton.textContent = value === "custom" ? describe() : t("Custom…");
      reveal();
    }
    // Where the choices outgrow the width (a phone), they scroll sideways: the edge with more fades out, and the chosen
    // one is kept in view, without scrolling the page.
    function edges() {
      control.classList.toggle("more-before", control.scrollLeft > 2);
      control.classList.toggle("more-after", control.scrollLeft + control.clientWidth < control.scrollWidth - 2);
    }
    function reveal() {
      const on = control.querySelector(".on");
      if (!on || control.scrollWidth <= control.clientWidth) return;
      const start = on.offsetLeft - control.offsetLeft, end = start + on.offsetWidth;
      if (start < control.scrollLeft) control.scrollLeft = start - 24;
      else if (end > control.scrollLeft + control.clientWidth) control.scrollLeft = end - control.clientWidth + 24;
    }
    control.addEventListener("scroll", edges, { passive: true });
    new ResizeObserver(() => { reveal(); edges(); }).observe(control);
    function choose(one, quiet = false) {
      if (one === value && one !== "custom") return;
      value = one;
      mark();
      control.dispatchEvent(new Event("change"));
      if (!quiet) changed();
    }
    mark();

    let popover = null;
    function close() {
      if (!popover) return;
      const node = popover;
      popover = null;
      customButton.setAttribute("aria-expanded", "false");
      document.removeEventListener("pointerdown", outside, true);
      node.classList.add("closing");
      node.addEventListener("animationend", () => node.remove(), { once: true });
      setTimeout(() => node.remove(), 200);
    }
    const outside = (event) => { if (popover && !popover.contains(event.target) && !customButton.contains(event.target)) close(); };

    function open(anchor) {
      if (popover) { close(); return; }
      const midnight = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate());
      const today = midnight(new Date());
      const earliest = new Date(today.getFullYear(), today.getMonth(), today.getDate() - earliestDays);
      const pad = (n) => String(n).padStart(2, "0");
      const clock = (date) => `${pad(date.getHours())}:${pad(date.getMinutes())}`;
      let start = midnight(custom.from), end = midnight(custom.to ?? new Date()), picking = false;
      let month = new Date(end.getFullYear(), end.getMonth(), 1);
      const fromTime = el("input", { type: "time", value: clock(custom.from), "aria-label": t("From") });
      const toTime = el("input", { type: "time", value: clock(custom.to ?? new Date()), "aria-label": t("To"), disabled: !custom.to });
      const untilNow = el("input", { type: "checkbox", checked: !custom.to });
      untilNow.addEventListener("change", () => { toTime.disabled = untilNow.checked; });
      const title = el("strong", { class: "range-month" });
      const grid = el("div", { class: "range-days", role: "grid" });
      const message = el("p", { class: "range-message muted", text: t("Pick the first day, then the last."), role: "status" });
      const weekday = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "narrow" });
      const monthName = new Intl.DateTimeFormat(HomeswiftI18n.locale, { month: "long", year: "numeric" });
      const dayName = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "long", day: "numeric", month: "long" });
      const step = (months) => { month = new Date(month.getFullYear(), month.getMonth() + months, 1); render(); };
      const previous = el("button", { type: "button", class: "menu-button", "aria-label": t("Previous month"), onclick: () => step(-1) }, icon("back"));
      const next = el("button", { type: "button", class: "menu-button", "aria-label": t("Next month"), onclick: () => step(1) }, icon("forward"));

      function render() {
        title.textContent = monthName.format(month);
        previous.disabled = month <= new Date(earliest.getFullYear(), earliest.getMonth(), 1);
        next.disabled = month >= new Date(today.getFullYear(), today.getMonth(), 1);
        // Weeks start on Monday; the days of the months around fill the first and last weeks.
        const first = new Date(month.getFullYear(), month.getMonth(), 1 - (month.getDay() + 6) % 7);
        const heads = [...Array(7)].map((_, index) => el("span", { class: "range-weekday", "aria-hidden": "true", text: weekday.format(new Date(2024, 0, 1 + index)) }));
        const days = [...Array(42)].map((_, index) => {
          const date = new Date(first.getFullYear(), first.getMonth(), first.getDate() + index);
          const time = date.getTime();
          const classes = ["range-day",
            date.getMonth() !== month.getMonth() ? "outside" : "",
            time === today.getTime() ? "today" : "",
            time >= start.getTime() && time <= end.getTime() ? "in" : "",
            time === start.getTime() ? "start" : "", time === end.getTime() ? "end" : "",
            index % 7 === 0 ? "row-start" : "", index % 7 === 6 ? "row-end" : ""].filter(Boolean).join(" ");
          return el("button", { type: "button", class: classes, text: date.getDate(), disabled: date > today || date < earliest,
            "aria-label": dayName.format(date), "aria-pressed": String(time >= start.getTime() && time <= end.getTime()),
            onclick: () => pick(date) });
        });
        grid.replaceChildren(...heads, ...days);
      }
      function pick(date) {
        if (!picking) { start = end = date; picking = true; message.textContent = t("Pick the first day, then the last."); }
        else { if (date < start) [start, end] = [date, start]; else end = date; picking = false; }
        render();
      }
      function apply() {
        const at = (day, text) => { const [h, m] = text.split(":").map(Number); return new Date(day.getFullYear(), day.getMonth(), day.getDate(), h || 0, m || 0); };
        const from = at(start, fromTime.value), to = untilNow.checked ? null : at(end, toTime.value);
        if (from >= (to ?? new Date())) { message.textContent = t("The start must be before the end."); message.classList.add("error"); return; }
        custom = { from, to };
        close();
        choose("custom");
        customButton.focus();
      }

      popover = el("div", { class: "range-popover", role: "dialog", "aria-label": t("Custom range…") },
        el("div", { class: "range-head" }, previous, title, next),
        grid,
        el("div", { class: "range-times" },
          el("label", {}, el("span", { text: t("From") }), fromTime),
          el("label", {}, el("span", { text: t("To") }), toTime),
          el("label", { class: "range-now" }, untilNow, el("span", { text: t("Until now") }))),
        message,
        el("div", { class: "range-actions" },
          el("button", { type: "button", actionIcon: "close", text: t("Cancel"), onclick: () => { close(); customButton.focus(); } }),
          el("button", { type: "button", class: "primary", actionIcon: "eye", text: t("Show"), onclick: apply })));
      popover.addEventListener("keydown", (event) => { if (event.key === "Escape") { event.stopPropagation(); close(); customButton.focus(); } });
      render();
      layerHost(anchor).append(popover);
      // Under the Custom segment, kept on screen, growing from it.
      const box = anchor.getBoundingClientRect(), width = popover.offsetWidth, height = popover.offsetHeight;
      const left = Math.min(Math.max(8, box.left + box.width / 2 - width / 2), innerWidth - width - 8);
      const below = box.bottom + 8 + height <= innerHeight - 8;
      popover.style.left = `${left}px`;
      popover.style.top = `${below ? box.bottom + 8 : Math.max(8, box.top - 8 - height)}px`;
      popover.style.transformOrigin = `${box.left + box.width / 2 - left}px ${below ? "0" : "100%"}`;
      customButton.setAttribute("aria-expanded", "true");
      document.addEventListener("pointerdown", outside, true);
      (grid.querySelector(".range-day.end") ?? grid.querySelector(".range-day:not(:disabled)"))?.focus();
    }

    return {
      control,
      span() {
        const now = new Date(), midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        if (value === "latest") return null;
        if (value === "custom") return [custom.from, custom.to && custom.to < now ? custom.to : null];
        return { "1h": [new Date(now - 3600000), null], "6h": [new Date(now - 6 * 3600000), null], "24h": [new Date(now - 86400000), null],
          today: [midnight, null], yesterday: [new Date(midnight - 86400000), midnight], "7d": [new Date(now - 7 * 86400000), null] }[value];
      },
      address(query) {
        if (value === fallback) return;
        query.set(names.since, value);
        if (value !== "custom") return;
        const local = (date) => new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
        query.set(names.from, local(custom.from));
        if (custom.to) query.set(names.to, local(custom.to));
      },
      chosen: () => value !== fallback,
      reset() { close(); choose(fallback, true); },
    };
  }

  // Native disabled buttons suppress click events. Pointer events still let a tap
  // explain the disabled state without enabling the control or running its action.
  let filterTip = null, filterTipTimer = null, filterTap = null;
  function hideFilterTip() {
    clearTimeout(filterTipTimer);
    filterTip?.remove(); filterTip = null;
  }
  function disabledFilterAt(x, y) {
    const target = document.elementFromPoint(x, y);
    const control = target?.closest('[aria-disabled="true"][title], button:disabled[title], label.toggle[title]');
    if (!control?.title || (control.matches('label') && !control.querySelector('input:disabled'))) return null;
    return control;
  }
  document.addEventListener("pointerdown", (event) => {
    hideFilterTip();
    const control = disabledFilterAt(event.clientX, event.clientY);
    filterTap = control ? { control, x: event.clientX, y: event.clientY, id: event.pointerId } : null;
  }, true);
  document.addEventListener("pointerup", (event) => {
    const tap = filterTap; filterTap = null;
    if (!tap || tap.id !== event.pointerId || Math.hypot(event.clientX - tap.x, event.clientY - tap.y) > 8
      || disabledFilterAt(event.clientX, event.clientY) !== tap.control) return;
    event.preventDefault();
    event.stopPropagation();
    filterTip = el("div", { class: "disabled-filter-tip", role: "status", popover: "manual", text: tap.control.title });
    layerHost(tap.control).append(filterTip);
    filterTip.showPopover();
    const rect = tap.control.getBoundingClientRect();
    const bounds = filterTip.getBoundingClientRect();
    const viewport = window.visualViewport;
    const left = viewport?.offsetLeft || 0, top = viewport?.offsetTop || 0;
    const width = viewport?.width || innerWidth, height = viewport?.height || innerHeight;
    filterTip.style.left = `${Math.max(left + 12, Math.min(rect.left, left + width - bounds.width - 12))}px`;
    filterTip.style.top = `${Math.max(top + 12, Math.min(rect.bottom + 8, top + height - bounds.height - 12))}px`;
    filterTipTimer = setTimeout(hideFilterTip, 4500);
  }, true);
  document.addEventListener("pointercancel", () => { filterTap = null; }, true);
  document.addEventListener("scroll", () => { filterTap = null; hideFilterTip(); }, true);
  document.addEventListener("keydown", (event) => { if (event.key === "Escape") hideFilterTip(); });
  window.addEventListener("resize", hideFilterTip);

  /// Runs `work` with `button` busy: disabled, and its spinner shown after `delay` ms, so a quick action shows none. An
  /// error goes to `report` (the default alerts it); `report` null rethrows it.
  async function busyButton(button, work, { report = (e) => HomeswiftCommon.showAlert(e.message), delay = 0 } = {}) {
    if (button) button.disabled = true;
    const spin = button ? setTimeout(() => button.classList.add("busy"), delay) : null;
    try {
      return await work();
    } catch (e) {
      if (report === null) throw e;
      report(e);
    } finally {
      clearTimeout(spin);
      if (button) { button.classList.remove("busy"); button.disabled = false; }
    }
  }

  /// A picture drawn on a canvas, its longer side at most `max` pixels: the canvas to encode.
  function scaledCanvas(bitmap, max) {
    const scale = Math.min(1, max / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return canvas;
  }

  /// A picture file a person picked or dropped, as a JPEG `data:` URL at most 640 pixels wide: what a scene's picture
  /// is sent as (the server takes JPEG, PNG or WebP up to 1 MB).
  async function pictureDataURL(file) {
    if (!/^image\//.test(file.type)) throw new Error(t("This file is not a picture."));
    const bitmap = await createImageBitmap(file).catch(() => { throw new Error(t("This file is not a picture.")); });
    const canvas = scaledCanvas(bitmap, 640);
    bitmap.close?.();
    return canvas.toDataURL("image/jpeg", 0.85);
  }

  /// Opens the file picker for one picture; calls `chosen(file)`.
  function choosePictureFile(chosen) {
    const input = el("input", { type: "file", accept: "image/jpeg,image/png,image/webp,image/heic" });
    input.addEventListener("change", () => { if (input.files?.[0]) chosen(input.files[0]); });
    input.click();
  }

  /// A byte count as every page shows sizes: whole KB under a megabyte, one decimal MB or GB. `scale` picks the unit
  /// (the largest value a list shows, so its rows agree); it defaults to the count itself.
  function byteSize(bytes, scale = bytes) {
    const decimal = new Intl.NumberFormat(HomeswiftI18n.locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
    const whole = new Intl.NumberFormat(HomeswiftI18n.locale, { maximumFractionDigits: 0 });
    if (scale >= 1024 ** 3) return `${decimal.format(bytes / 1024 ** 3)} GB`;
    if (scale >= 1024 ** 2) return `${decimal.format(bytes / 1024 ** 2)} MB`;
    if (scale >= 1024) return `${whole.format(Math.round(bytes / 1024))} KB`;
    return `${whole.format(bytes)} B`;
  }

  // Queue modal messages so simultaneous failures never stack focus traps.
  let dialogQueue = Promise.resolve();
  let dialogSequence = 0;
  function messageDialog(message, { kind = "alert", value = "" } = {}) {
    const show = () => new Promise((resolve) => {
      const previousFocus = document.activeElement;
      const id = `message-dialog-${++dialogSequence}`;
      const input = kind === "prompt" ? el("input", { type: "text", value, "aria-labelledby": `${id}-body` }) : null;
      const cancel = kind !== "alert" ? el("button", { type: "button", actionIcon: "close", text: t("Cancel"), onclick: () => dialog.close("cancel") }) : null;
      const ok = el("button", { type: "submit", class: "primary", actionIcon: "check", text: kind === "confirm" ? t("Continue") : t("OK") });
      const form = el("form", { method: "dialog" },
        el("h2", { id: `${id}-title`, text: kind === "alert" ? t("Message") : kind === "prompt" ? t("Enter a value") : t("Confirm") }),
        el("p", { id: `${id}-body`, class: "dialog-message", text: String(message) }), input,
        el("div", { class: "actions" }, cancel, ok));
      const dialog = el("dialog", { class: "admin-dialog card message-dialog", "aria-labelledby": `${id}-title`, "aria-describedby": `${id}-body` }, form);
      form.addEventListener("submit", (event) => { event.preventDefault(); dialog.close("ok"); });
      dialog.addEventListener("close", () => {
        const result = dialog.returnValue === "ok";
        const answer = input ? (result ? input.value : null) : result;
        dialog.remove();
        if (previousFocus?.isConnected) previousFocus.focus();
        resolve(answer);
      }, { once: true });
      document.body.append(dialog);
      dialog.showModal();
      (input || cancel || ok).focus();
      input?.select();
    });
    const result = dialogQueue.then(show);
    dialogQueue = result.catch(() => {});
    return result;
  }
  const showAlert = (message) => messageDialog(message);
  const confirmDialog = (message) => messageDialog(message, { kind: "confirm" });
  const promptDialog = (message, value = "") => messageDialog(message, { kind: "prompt", value });

  /// A `<details>` that opens as a popover (the side menu's Homeswift section): a click outside it or Escape folds it,
  /// Escape giving the focus back to its summary.
  function foldOnLeave(details) {
    document.addEventListener("click", (event) => { if (details.open && !details.contains(event.target)) details.open = false; });
    document.addEventListener("keydown", (event) => {
      if (event.key !== "Escape" || !details.open) return;
      details.open = false;
      details.querySelector("summary")?.focus();
    });
  }

  window.HomeswiftCommon = {
    foldOnLeave, showAlert, confirmDialog, promptDialog, busyButton, fold, scaledCanvas, pictureDataURL, choosePictureFile, byteSize, lastChange: () => lastChange,
    $, el, icon, subnav, tile, clearFilters, rangeControl, fact, markdown, sparkle, api, menu, menuButton, dragToDismiss, copyText, jsonHighlight, jsonView, jsonEditor, jsonCheck, sections, tabBar, setPaused, slug, withSlugs, jsonDiff,
    assistantRequest, applyPreferences, loadPreferences, preferences: () => preferences, temperature, formatTemperature, ago,
  };
})();
