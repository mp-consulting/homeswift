// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension EcoFlowPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The EcoFlow page: each device the plugin reads, its battery, and its power as IN and OUT, laid out by kind as the
// app does. The page refreshes every few seconds while it is visible; it reads `GET power` from the plugin.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request } = homeswift;

  const list = $("#devices");
  // Devices already on the page: a card animates in once, not again at every refresh.
  const shown = new Set();
  // Whole watts everywhere: the readings are never shown with decimals.
  const whole = (value) => Math.round(Math.abs(value)).toLocaleString(HomeswiftI18n.locale);
  // Figures are text nodes, never HTML: the number and its unit each in their own element.
  const figure = (number, unit) => el("span", {}, number, el("small", { text: ` ${unit}` }));
  // Power: whole watts below a kilowatt; from 1,000 W, kilowatts with two decimals (1.43 kW, or 1,43 kW in French).
  const power = (value) => {
    const magnitude = Math.abs(value);
    if (magnitude >= 1000) {
      return { number: (magnitude / 1000).toLocaleString(HomeswiftI18n.locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 }), unit: "kW" };
    }
    return { number: whole(value), unit: "W" };
  };
  const watts = (value) => {
    const formatted = power(value);
    return figure(formatted.number, formatted.unit);
  };

  // A flow's direction: power coming in or going out, by the device's sign convention (grid positive is import,
  // battery positive is charging). Zero is idle.
  function way(value, inWhenPositive) {
    if (Math.abs(value) < 1) return { label: t("Idle"), kind: "idle" };
    const coming = (value > 0) === inWhenPositive;
    return coming ? { label: t("IN"), kind: "in" } : { label: t("OUT"), kind: "out" };
  }

  // The direction arrow, as the app draws it: green up for power coming in, orange down for power going out.
  // Idle (or no direction) shows none.
  const arrow = (kind) => el("span", { class: `arrow ${kind}`, "aria-hidden": "true" });

  // The last hour of each reading, as the Status page records it: deviceID:key -> points. A reading not loaded yet
  // has no entry, and its sparkline shows a loader.
  const history = new Map();
  const historyOf = (id, key) => history.get(`${id}:${key}`) ?? null;

  // A sparkline of the readings' averages, in front of the value: its own scale, the line only (no axes). While the
  // points are loading (null), a shimmering line stands in for it. It has no tooltip of its own: its tile's says what
  // the tile shows, and two would open at once.
  function sparkline(points) {
    const node = el("span", { class: "spark", "aria-hidden": "true" });
    if (points === null) {
      node.classList.add("loading");
      node.append(el("span", { class: "spark-loader" }));
      return node;
    }
    const values = points.map((point) => point.average ?? point.high).filter((value) => value !== null);
    if (values.length < 2) return node;
    const low = Math.min(...values), high = Math.max(...values), span = high - low || 1;
    const step = 100 / (values.length - 1);
    const line = values.map((value, index) => `${(index * step).toFixed(2)},${(22 - ((value - low) / span) * 20).toFixed(2)}`).join(" ");
    node.innerHTML = `<svg viewBox="0 0 100 24" preserveAspectRatio="none"><polyline points="${line}"/></svg>`;
    return node;
  }

  // Each value's tooltip: what the number is, and what IN and OUT mean.
  const tipWay = (kind) => ({ in: t("Power coming in"), out: t("Power going out"), idle: t("No power flowing") })[kind];

  function flow(label, value, inWhenPositive, points, tip, wide = false) {
    const direction = way(value, inWhenPositive);
    const badge = el("span", { class: `way ${direction.kind}`, text: direction.label, "data-tip": tipWay(direction.kind) });
    const pointer = direction.kind === "idle" ? null : arrow(direction.kind);
    return el("div", { class: wide ? "flow wide" : "flow", "data-tip": tip },
      el("div", { class: "label" }, el("span", { text: label }), badge),
      el("div", { class: "value" }, sparkline(points), pointer, watts(value)));
  }

  // The battery's graphic beside its percentage, as on the Accessories tiles: the bars filled by the level.
  function batteryGraphic(level) {
    const node = el("span", { class: level === null ? "battery-mini unknown" : "battery-mini", "aria-hidden": "true" });
    const filled = level === null ? 0 : level >= 67 ? 3 : level >= 34 ? 2 : level >= 10 ? 1 : 0;
    const bars = [0, 1, 2].map((index) => `<rect class="bat-bar${index < filled ? " on" : ""}" x="${4.5 + index * 3.9}" y="8.8" width="2.6" height="6.4" rx="0.6"/>`).join("");
    node.innerHTML = `<svg viewBox="0 0 24 24"><rect class="bat-body" x="2" y="6.5" width="17" height="11" rx="2"/><path class="bat-terminal" d="M21.5 10.5v3"/>${bars}</svg>`;
    return node;
  }

  // Where a device's values come from: the developer API's MQTT pushes, its REST quota, or the EcoFlow app's stream.
  // Each device's values all come from one source, shown beside its name.
  // The badge names the service, the settings to look at when a device stops updating; its tooltip, the channel.
  const sourceLabel = (source) => ({ mqtt: t("Developer API"), rest: t("Developer API"), app: t("EcoFlow app") })[source] ?? source;
  const sourceTip = (source) => ({
    mqtt: t("Live, from the developer API's MQTT pushes"),
    rest: t("Read at the developer API's interval, from its REST values"),
    app: t("Live, from the EcoFlow app's stream"),
  })[source] ?? "";

  // Each reading's flow, as the app shows it: [label, IN when positive, tooltip, full width]. A device lists the
  // readings its model reports, in the app's order (`series`): a STREAM's solar, home, grid and battery, its sockets
  // and its grid connection port; another home system's flows; a portable station's totals, its solar, the AC input
  // and each output; a power bank's totals.
  const flows = {
    solar: ["Solar", true, "Power from the solar panels now"],
    home: ["Home", false, "Power the home uses now"],
    grid: ["Grid", true, "Power exchanged with the grid: IN is import, OUT is export"],
    battery: ["Battery", true, "Power into the battery while charging, out of it while discharging"],
    ac1: ["AC1", false, "Power this socket supplies to what is plugged in"],
    ac2: ["AC2", false, "Power this socket supplies to what is plugged in"],
    ac: ["Grid connection port", false, "Power through the AC port: OUT feeds the home, IN takes power in", true],
    input: ["Input", true, "Power coming into the station from all its inputs"],
    output: ["Output", false, "Power the station supplies on all its outputs"],
    acIn: ["AC input", true, "Power coming in through the AC input"],
    acOut: ["230V AC", false, "Power the AC sockets supply"],
    usbA: ["USB-A", false, "Power the USB-A ports supply"],
    usbC: ["USB-C", false, "Power the USB-C ports supply"],
  };

  // A model mapped from open-source projects and not yet checked on a real device: marked beside the source.
  const untested = () => el("span", { class: "way untested", text: t("Untested"),
    "data-tip": t("This model's readings come from open-source projects and have not been checked on a real device yet") });

  // The device's estimate of the time to full while charging, to empty otherwise, as the EcoFlow app shows it: days
  // and hours (rounded to the hour) from a day up, else hours and minutes, or minutes.
  function remaining(device) {
    if (device.minutesRemaining == null) return null;
    const total = Math.round(device.minutesRemaining);
    const hours = Math.floor(total / 60), minutes = total % 60;
    const roundedHours = Math.round(total / 60);
    const time = roundedHours >= 24 ? t("{d}d {h}h", { d: Math.floor(roundedHours / 24), h: roundedHours % 24 })
      : hours > 0 ? t("{h}h {m}m", { h: hours, m: minutes }) : t("{m}m", { m: minutes });
    return el("span", { class: "remaining",
      text: device.charging ? t("{time} to full", { time }) : t("{time} left", { time }),
      "data-tip": device.charging ? t("Time until the battery is full at the current power, as the device estimates it")
        : t("Time until the battery is empty at the current power, as the device estimates it") });
  }

  function card(device, enter) {
    const level = device.batteryLevel === null ? null : Math.round(device.batteryLevel);
    // Offline with nothing reported since the plugin started: no charging state or flows to show, only that.
    const silent = !device.online && level === null && (device.series ?? []).every((key) => !device[key]);
    const battery = el("div", { class: "battery-line" },
      el("div", { class: "figure", "data-tip": t("The battery's state of charge") }, batteryGraphic(level), level === null ? "–" : figure(String(level), "%")),
      el("div", { class: "battery-state" }, remaining(device), silent ? null :
        el("span", { class: `pill ${device.charging ? "on" : ""}`, text: device.charging ? t("Charging") : t("Not charging"), "data-tip": t("Whether the battery is charging now") })));
    const shown = (device.series ?? []).filter((key) => flows[key]);
    const flowList = silent ? null : el("div", { class: "flows" }, shown.map((key) => {
      const [label, inWhenPositive, tip, wide] = flows[key];
      return flow(t(label), device[key], inWhenPositive, historyOf(device.id, key), t(tip), wide);
    }));
    // Offline: the last readings, or none when the device has sent nothing since the plugin started.
    const status = device.online ? null : el("p", { class: "note",
      text: silent ? t("Offline: no readings since the plugin started") : t("Offline: showing the last readings") });
    const panels = (device.panels ?? []).length
      ? el("div", { class: "panels" }, el("p", { class: "caption", text: t("Solar by panel") }),
          el("div", { class: "panel-row" }, device.panels.map((value, index) =>
            el("div", { class: "pv-tile", "data-tip": t("Power from this solar panel input") }, el("span", { class: "label" }, `PV${index + 1}`, value >= 1 ? arrow("in") : null),
              el("span", { class: "value" }, power(value).number, el("small", { text: ` ${power(value).unit}` }))))))
      : null;
    return el("article", { class: `card device${enter ? " enter" : ""}`, "aria-label": device.name, "data-id": device.id },
      el("div", { class: "device-head" },
        el("div", { class: "title-line" }, el("h2", { text: device.name }),
          el("span", { class: "way source", text: sourceLabel(device.source), "data-tip": sourceTip(device.source) }),
          device.tested === false ? untested() : null, known.length > 1 ? handle(device) : null),
        el("p", { class: "serial", text: device.model ? `${device.model} · ${device.id}` : device.id })),
      battery, flowList, panels, status);
  }

  // MARK: Packing. In two columns each card spans the rows its height takes (the CSS's `--pack-row` rows, the gap
  // below it included), so the shorter column takes the next card. One column, or no packing rows, clears the spans.
  // A card's height changes with its readings, the fonts and the width: a ResizeObserver packs again after each.
  function pack() {
    const style = getComputedStyle(list);
    const row = parseFloat(style.getPropertyValue("--pack-row"));
    const gap = parseFloat(style.getPropertyValue("--pack-gap")) || 0;
    for (const node of list.children) {
      // The layout height: a card's entrance (a scale) or its drag (a translate) does not change its place.
      node.style.gridRowEnd = row > 0 ? `span ${Math.ceil((node.offsetHeight + gap) / row)}` : "";
    }
  }
  let packing = 0;
  const packer = new ResizeObserver(() => {
    cancelAnimationFrame(packing);
    packing = requestAnimationFrame(pack);
  });
  // The cards are made anew at each render. The list keeps its height while they are swapped in and measured (each new
  // card spans one 2px row until it is packed: the list would shrink and the page scroll back to the top), they are
  // packed at once, and the observer follows them.
  function replaceCards(...nodes) {
    list.style.minHeight = `${list.offsetHeight}px`;
    list.replaceChildren(...nodes);
    pack();
    list.style.minHeight = "";
    observeCards();
  }
  function observeCards() {
    packer.disconnect();
    packer.observe(list);
    for (const node of list.children) packer.observe(node);
  }

  // MARK: Order. A card is dragged by its grip to another place (the others make room), or moved with the arrow keys
  // while its grip has the focus. The order is the plugin's, kept for every viewer; nothing is written to config.json,
  // which would reload the plugin.

  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  // While a card is dragged, the readings that arrive wait: drawing the cards again would drop it.
  let sorting = false;

  // Six dots in two columns, the usual grip; a button, so the keyboard reaches it.
  function handle(device) {
    const grip = el("button", { type: "button", class: "handle", "aria-label": t("Move {name}", { name: device.name }),
      title: t("Drag to reorder, or use the arrow keys") });
    grip.innerHTML = '<svg viewBox="0 0 10 16" aria-hidden="true"><circle cx="2.5" cy="3" r="1.4"/><circle cx="7.5" cy="3" r="1.4"/><circle cx="2.5" cy="8" r="1.4"/><circle cx="7.5" cy="8" r="1.4"/><circle cx="2.5" cy="13" r="1.4"/><circle cx="7.5" cy="13" r="1.4"/></svg>';
    return grip;
  }

  const cardsNow = () => [...list.querySelectorAll(".device[data-id]")];

  // Moves the cards in the page to their new places from where they were: each slides from its old position (FLIP).
  function slide(before) {
    if (reducedMotion.matches) return;
    for (const node of cardsNow()) {
      const from = before.get(node.dataset.id);
      if (!from || node.classList.contains("dragging")) continue;
      const to = node.getBoundingClientRect();
      const dx = from.left - to.left, dy = from.top - to.top;
      if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue;
      node.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], { duration: 220, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
    }
  }
  const positions = () => new Map(cardsNow().map((node) => [node.dataset.id, node.getBoundingClientRect()]));

  // The new order, for the plugin; `known` follows at once, and the next answer comes in it.
  // Polls wait for it (`saving`), as they wait for a drag: an answer from before it would show the old order. The
  // saves go one after the other, each with the order as it is when its turn comes: two quick key presses must not
  // reach the plugin in the wrong order.
  let saving = 0;
  let saves = Promise.resolve();
  function saveOrder() {
    saving++;
    saves = saves.then(async () => {
      try {
        await request("order", { method: "POST", body: { ids: known.map((device) => device.id) } });
      } catch (error) {
        HomeswiftCommon.showAlert(HomeswiftI18n.message(error.message));
      } finally {
        saving--;
      }
      lastAnswer = "";
    });
    return saves;
  }

  // The arrow keys on a grip: up and left move the card back a place, down and right forward.
  list.addEventListener("keydown", (event) => {
    const grip = event.target.closest(".handle");
    const step = { ArrowUp: -1, ArrowLeft: -1, ArrowDown: 1, ArrowRight: 1 }[event.key];
    if (!grip || !step || sorting) return;
    event.preventDefault();
    const id = grip.closest(".device").dataset.id;
    const from = known.findIndex((device) => device.id === id);
    const to = from + step;
    if (from < 0 || to < 0 || to >= known.length) return;
    // No slide: a key press moves the card at once, as keyboard actions should.
    known.splice(to, 0, ...known.splice(from, 1));
    render();
    list.querySelector(`.device[data-id="${CSS.escape(id)}"] .handle`)?.focus();
    saveOrder();
  });

  // Dragging with Pointer Events, so mouse, pen and touch behave the same. The card stays under the pointer where it
  // was grabbed; over another card, it takes that card's place and the others slide to theirs.
  list.addEventListener("pointerdown", (event) => {
    const grip = event.target.closest(".handle");
    if (!grip || event.button !== 0 || sorting) return;
    event.preventDefault();
    const node = grip.closest(".device");
    const id = node.dataset.id;
    const start = { x: event.clientX, y: event.clientY + window.scrollY, left: node.offsetLeft, top: node.offsetTop };
    const startOrder = known.map((device) => device.id).join();
    const pointer = event.pointerId;
    sorting = true;
    node.classList.add("dragging");
    list.classList.add("sorting");
    // The card's offset from its place in the grid, kept under the pointer as the place (and the page) moves.
    let shift = { x: 0, y: 0 };
    const follow = (x, y) => {
      shift = { x: x - start.x - (node.offsetLeft - start.left), y: y + window.scrollY - start.y - (node.offsetTop - start.top) };
      node.style.transform = `translate(${shift.x}px, ${shift.y}px)`;
    };
    // Where the pointer is, and the page scrolling under it near the window's top or bottom edge: a card can be taken
    // to a place out of sight. The sticky header covers the top, so its zone is deeper.
    let last = { x: event.clientX, y: event.clientY };
    let frame = 0;
    // As far as the page went when the drag began: the card, pushed past the end, would make it longer and longer.
    const deepest = document.documentElement.scrollHeight - innerHeight;
    const scrollStep = () => {
      const top = 110, bottom = 70, fastest = 22;
      const speed = last.y < top ? -fastest * (1 - Math.max(last.y, 0) / top)
        : last.y > innerHeight - bottom ? fastest * (1 - Math.max(innerHeight - last.y, 0) / bottom) : 0;
      if (speed && (speed < 0 || window.scrollY < deepest)) {
        const before = window.scrollY;
        window.scrollTo(0, Math.min(deepest, window.scrollY + (Math.round(speed) || Math.sign(speed))));
        if (window.scrollY !== before) update(last.x, last.y);
      }
      frame = requestAnimationFrame(scrollStep);
    };
    frame = requestAnimationFrame(scrollStep);
    const move = (moveEvent) => {
      if (moveEvent.pointerId !== pointer) return;
      last = { x: moveEvent.clientX, y: moveEvent.clientY };
      update(last.x, last.y);
    };
    const update = (x, y) => {
      // The card under the pointer, when the pointer has left the dragged card's own place (where it is, less the
      // shift that keeps it under the pointer).
      const rect = node.getBoundingClientRect();
      const inOwn = x >= rect.left - shift.x && x <= rect.right - shift.x && y >= rect.top - shift.y && y <= rect.bottom - shift.y;
      const target = inOwn ? null : cardsNow().find((other) => {
        if (other === node) return false;
        const rect = other.getBoundingClientRect();
        return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
      });
      if (target) {
        const from = known.findIndex((device) => device.id === id);
        const to = known.findIndex((device) => device.id === target.dataset.id);
        const before = positions();
        known.splice(to, 0, ...known.splice(from, 1));
        if (from < to) target.after(node); else target.before(node);
        slide(before);
      }
      follow(x, y);
    };
    const end = (endEvent) => {
      if (endEvent.pointerId !== pointer) return;
      cancelAnimationFrame(frame);
      removeEventListener("pointermove", move);
      removeEventListener("pointerup", end);
      removeEventListener("pointercancel", end);
      list.classList.remove("sorting");
      // The card settles into its place from where it was let go.
      node.classList.add("settling");
      node.classList.remove("dragging");
      node.style.transform = "";
      const done = () => {
        if (!sorting) return;
        node.classList.remove("settling");
        sorting = false;
        render();
      };
      node.addEventListener("transitionend", done, { once: true });
      // A card let go where it was, or without motion, has no transition to end.
      setTimeout(done, reducedMotion.matches ? 0 : 400);
      if (known.map((device) => device.id).join() !== startOrder) saveOrder();
    };
    // On the window, not captured by the grip: moving the card in the page releases a capture.
    addEventListener("pointermove", move);
    addEventListener("pointerup", end);
    addEventListener("pointercancel", end);
  });

  // A device still on its way: its name, and shimmering lines where its battery and flows will be. Before the first
  // answer, one stands for whatever the plugin will report.
  function placeholder(device) {
    const bar = (cls) => el("span", { class: `placeholder-bar ${cls}`, "aria-hidden": "true" });
    return el("article", { class: "card device pending", "aria-busy": "true", "aria-label": device?.name ?? t("Loading") },
      el("div", { class: "device-head" },
        el("div", { class: "title-line" }, device ? el("h2", { text: device.name ?? device.model ?? device.id }) : bar("title")),
        el("p", { class: "serial", text: device ? t("Waiting for its first readings") : t("Loading the devices") })),
      bar("figure"),
      el("div", { class: "flows" }, [0, 1, 2, 3].map(() => el("div", { class: "flow" }, bar("label"), bar("value")))));
  }

  // Shown while the plugin has no readings: why, and when this page looks again.
  function waiting() {
    const glyph = el("span", { class: "empty-glyph", "aria-hidden": "true" });
    glyph.innerHTML = `<svg viewBox="0 0 24 24"><path d="M13 2 4 14h7l-1 8 9-12h-7z"/></svg>`;
    return el("section", { class: "card empty", role: "status" },
      glyph,
      el("h2", { text: t("No devices yet") }),
      el("p", { class: "note", text: t("The plugin has not had readings from your devices yet. They usually arrive within a minute.") }),
      el("p", { class: "note", text: t("This page checks again every few seconds while it is open.") }));
  }

  // Each graphed reading's last hour, read from the Status page's history: the series the device's kind records
  // (the plugin lists them), all at once. `onlyMissing` reads just the readings with no history yet: a device that
  // arrives after the first answer (the app's stream reports a few seconds after the developer API) gets its
  // sparklines at once rather than at the next minute's reload.
  let known = [];
  const loading = new Set();
  async function loadHistory(onlyMissing = false) {
    const wanted = known.flatMap((device) => (device.series ?? []).map((key) => [device, key]))
      .filter(([device, key]) => !onlyMissing || !(history.has(`${device.id}:${key}`) || loading.has(`${device.id}:${key}`)));
    if (wanted.length === 0) return;
    wanted.forEach(([device, key]) => loading.add(`${device.id}:${key}`));
    // One request for them all: the history answers several series, separated by commas, by name.
    const names = wanted.map(([device, key]) => `plugin:EcoFlow:${device.id}:${key}`);
    let answer = null;
    try {
      const response = await fetch(`/api/metrics/values?series=${names.map(encodeURIComponent).join(",")}`, { credentials: "same-origin" });
      if (response.ok) {
        const body = await response.json();
        answer = body.series ?? { [names[0]]: body.points };
      }
    } catch (error) {
      // Keep the last points: the sparkline is a convenience, the values are the page.
    }
    wanted.forEach(([device, key], index) => {
      // A failed read keeps the last points, or shows an empty sparkline once rather than the loader forever.
      history.set(`${device.id}:${key}`, answer?.[names[index]] ?? history.get(`${device.id}:${key}`) ?? []);
      loading.delete(`${device.id}:${key}`);
    });
    render();
  }

  // The devices as the plugin reads them: the route in the plugin's settings decides each one's source.
  // `pending` is the configured devices with no readings yet; null until the plugin has answered once.
  let pending = null;
  function render() {
    if (sorting) return;
    if (pending === null) {
      replaceCards(placeholder(null));
      return;
    }
    const cards = known.map((device) => {
      const enter = !shown.has(device.id);
      shown.add(device.id);
      return card(device, enter);
    });
    const placeholders = pending.map(placeholder);
    // The grip with the focus keeps it: the cards are drawn again at every change of the readings.
    const focused = document.activeElement?.closest?.(".device .handle")?.closest(".device")?.dataset.id;
    replaceCards(...(cards.length + placeholders.length === 0 ? [waiting()] : [...cards, ...placeholders]));
    if (focused) list.querySelector(`.device[data-id="${CSS.escape(focused)}"] .handle`)?.focus({ preventScroll: true });
  }

  // The devices the plugin reads that the configuration's `devices` does not list, with the button that adds them
  // under the name they report: listed, a device is read by its serial number, and its name can be changed in the
  // plugin's settings.
  const unsaved = $("#unsaved");
  // Drawn again only when the devices it lists change: a button made anew at every reading would lose a click.
  let unsavedShown = "";
  function renderUnsaved() {
    const missing = known.filter((device) => device.configured === false);
    const key = missing.map((device) => `${device.id}\n${device.name}`).join("\n");
    if (key === unsavedShown) return;
    unsavedShown = key;
    unsaved.classList.toggle("hidden", missing.length === 0);
    if (missing.length === 0) return;
    unsaved.replaceChildren(
      el("p", { class: "note", text: tn("{n} device is not in the configuration yet. Add it to keep it by its serial number and to rename it in the settings.",
        "{n} devices are not in the configuration yet. Add them to keep them by their serial numbers and to rename them in the settings.", missing.length) }),
      el("button", { actionIcon: "plus", class: "primary", text: t("Add to the configuration"),
        onclick: (event) => homeswift.act(event.currentTarget, () => addToConfiguration(missing)) }));
  }

  // Each device once in the block's `devices`, an entry already there kept as it is. The plugin reloads with them.
  async function addToConfiguration(devices) {
    await homeswift.updateBlock((block) => {
      const entries = block.devices || [];
      for (const device of devices) {
        if (!entries.some((entry) => entry.id === device.id)) entries.push({ id: device.id, name: device.name });
      }
      block.devices = entries;
    });
    lastAnswer = "";
    await refresh();
  }

  // The cards are drawn again only when the readings changed: the plugin's values change at its own poll.
  let lastAnswer = "";
  async function refresh() {
    // While a card is dragged, an answer would put back the order it is changing: it is read again after.
    if (sorting || saving) return;
    try {
      const body = await request("power");
      if (sorting || saving) return;
      const devices = body.devices ?? [];
      const answer = JSON.stringify([devices, body.waiting ?? []]);
      if (answer === lastAnswer) return;
      lastAnswer = answer;
      known = devices;
      pending = body.waiting ?? [];
      loadHistory(true);
      render();
      renderUnsaved();
    } catch (error) {
      lastAnswer = "";
      // A card being dragged, or an order being saved, keeps the cards: the next poll says it again.
      if (sorting || saving) return;
      replaceCards(el("p", { class: "note", text: HomeswiftI18n.message(error.message) }));
    }
  }

  // A placeholder at once, while the first answer is on its way.
  render();
  homeswift.poll(refresh, 3000);
  setInterval(loadHistory, 60000);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The EcoFlow page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Developer API": "API développeur",
    "EcoFlow app": "Application EcoFlow",
    "Live, from the developer API's MQTT pushes": "En direct, par les envois MQTT de l'API développeur",
    "Read at the developer API's interval, from its REST values": "Lu à l'intervalle de l'API développeur, dans ses valeurs REST",
    "Live, from the EcoFlow app's stream": "En direct, par le flux de l'application EcoFlow",
    "Offline: no readings since the plugin started": "Hors ligne : aucune valeur depuis le démarrage du plugin",
    "Move {name}": "Déplacer {name}",
    "Drag to reorder, or use the arrow keys": "Faites glisser pour réorganiser, ou utilisez les flèches",
    "{n} device is not in the configuration yet. Add it to keep it by its serial number and to rename it in the settings.": "{n} appareil n'est pas encore dans la configuration. Ajoutez-le pour le garder par son numéro de série et le renommer dans les réglages.",
    "{n} devices are not in the configuration yet. Add them to keep them by their serial numbers and to rename them in the settings.": "{n} appareils ne sont pas encore dans la configuration. Ajoutez-les pour les garder par leur numéro de série et les renommer dans les réglages.",
    "Add to the configuration": "Ajouter à la configuration",
    "Loading": "Chargement",
    "Waiting for its first readings": "En attente de ses premières valeurs",
    "Loading the devices": "Chargement des appareils",
    "{d}d {h}h": "{d} j {h} h",
    "{h}h {m}m": "{h} h {m} min",
    "{m}m": "{m} min",
    "{time} to full": "{time} avant la charge complète",
    "{time} left": "{time} restantes",
    "Time until the battery is full at the current power, as the device estimates it": "Temps avant que la batterie soit pleine à la puissance actuelle, selon l'estimation de l'appareil",
    "Time until the battery is empty at the current power, as the device estimates it": "Temps avant que la batterie soit vide à la puissance actuelle, selon l'estimation de l'appareil",
    "Untested": "Non testé",
    "This model's readings come from open-source projects and have not been checked on a real device yet": "Les valeurs de ce modèle viennent de projets open source et n'ont pas encore été vérifiées sur un vrai appareil",
    "Power from the solar panels now": "Puissance des panneaux solaires maintenant",
    "Power the home uses now": "Puissance consommée par la maison maintenant",
    "Power exchanged with the grid: IN is import, OUT is export": "Puissance échangée avec le réseau : ENTRÉE est l'import, SORTIE l'export",
    "Power into the battery while charging, out of it while discharging": "Puissance entrant dans la batterie en charge, sortant en décharge",
    "Power this socket supplies to what is plugged in": "Puissance fournie par cette prise à ce qui y est branché",
    "Power through the AC port: OUT feeds the home, IN takes power in": "Puissance passant par le port AC : SORTIE alimente la maison, ENTRÉE prend de l'énergie",
    "The battery's state of charge": "Le niveau de charge de la batterie",
    "Whether the battery is charging now": "Si la batterie se charge maintenant",
    "Power from this solar panel input": "Puissance de cette entrée de panneau solaire",
    "Power coming in": "Puissance entrante",
    "Power going out": "Puissance sortante",
    "No power flowing": "Aucune puissance ne circule",
    "Grid connection port": "Port réseau",
    "AC1": "AC1",
    "AC2": "AC2",
    "Solar by panel": "Solaire par panneau",
    "EcoFlow": "EcoFlow",
    "Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.": "Puissance solaire, domestique, réseau et batterie, telle que les appareils la transmettent maintenant. ENTRÉE est la puissance qui entre, SORTIE celle qui sort.",
    "Solar": "Solaire",
    "Home": "Maison",
    "Grid": "Réseau",
    "Battery": "Batterie",
    "IN": "ENTRÉE",
    "OUT": "SORTIE",
    "Idle": "Au repos",
    "Charging": "En charge",
    "Not charging": "Pas en charge",
    "Offline: showing the last readings": "Hors ligne : dernières valeurs affichées",
    "No devices yet": "Aucun appareil pour l'instant",
    "The plugin has not had readings from your devices yet. They usually arrive within a minute.": "Le plugin n'a pas encore reçu de valeurs de vos appareils. Elles arrivent en général dans la minute.",
    "This page checks again every few seconds while it is open.": "Cette page vérifie à nouveau toutes les quelques secondes tant qu'elle est ouverte.",
    "Input": "Entrée",
    "Output": "Sortie",
    "AC input": "Entrée AC",
    "230V AC": "230V AC",
    "USB-A": "USB-A",
    "USB-C": "USB-C",
    "Power coming into the station from all its inputs": "Puissance entrant dans la station par toutes ses entrées",
    "Power the station supplies on all its outputs": "Puissance que la station fournit sur toutes ses sorties",
    "Power coming in through the AC input": "Puissance entrant par l'entrée AC",
    "Power the AC sockets supply": "Puissance fournie par les prises AC",
    "Power the USB-A ports supply": "Puissance fournie par les ports USB-A",
    "Power the USB-C ports supply": "Puissance fournie par les ports USB-C"
  },
  "es": {
    "Developer API": "API para desarrolladores",
    "EcoFlow app": "App de EcoFlow",
    "Live, from the developer API's MQTT pushes": "En directo, por los envíos MQTT de la API para desarrolladores",
    "Read at the developer API's interval, from its REST values": "Leído al intervalo de la API para desarrolladores, de sus valores REST",
    "Live, from the EcoFlow app's stream": "En directo, por el flujo de la App de EcoFlow",
    "Offline: no readings since the plugin started": "Sin conexión: ninguna lectura desde que se inició el plugin",
    "Move {name}": "Mover {name}",
    "Drag to reorder, or use the arrow keys": "Arrastra para reordenar, o usa las flechas",
    "{n} device is not in the configuration yet. Add it to keep it by its serial number and to rename it in the settings.": "{n} dispositivo aún no está en la configuración. Añádelo para conservarlo por su número de serie y cambiarle el nombre en los ajustes.",
    "{n} devices are not in the configuration yet. Add them to keep them by their serial numbers and to rename them in the settings.": "{n} dispositivos aún no están en la configuración. Añádelos para conservarlos por su número de serie y cambiarles el nombre en los ajustes.",
    "Add to the configuration": "Añadir a la configuración",
    "Loading": "Cargando",
    "Waiting for its first readings": "Esperando sus primeros valores",
    "Loading the devices": "Cargando los dispositivos",
    "{d}d {h}h": "{d} d {h} h",
    "{h}h {m}m": "{h} h {m} min",
    "{m}m": "{m} min",
    "{time} to full": "{time} hasta la carga completa",
    "{time} left": "quedan {time}",
    "Time until the battery is full at the current power, as the device estimates it": "Tiempo hasta que la batería esté llena a la potencia actual, según la estimación del dispositivo",
    "Time until the battery is empty at the current power, as the device estimates it": "Tiempo hasta que la batería se agote a la potencia actual, según la estimación del dispositivo",
    "Untested": "Sin probar",
    "This model's readings come from open-source projects and have not been checked on a real device yet": "Los valores de este modelo provienen de proyectos de código abierto y aún no se han comprobado en un dispositivo real",
    "Power from the solar panels now": "Potencia de los paneles solares ahora",
    "Power the home uses now": "Potencia que usa la casa ahora",
    "Power exchanged with the grid: IN is import, OUT is export": "Potencia intercambiada con la red: ENTRA es importación, SALE exportación",
    "Power into the battery while charging, out of it while discharging": "Potencia que entra en la batería al cargar, y sale al descargar",
    "Power this socket supplies to what is plugged in": "Potencia que esta toma entrega a lo que está conectado",
    "Power through the AC port: OUT feeds the home, IN takes power in": "Potencia por el puerto AC: SALE alimenta la casa, ENTRA toma energía",
    "The battery's state of charge": "El nivel de carga de la batería",
    "Whether the battery is charging now": "Si la batería se está cargando ahora",
    "Power from this solar panel input": "Potencia de esta entrada de panel solar",
    "Power coming in": "Potencia que entra",
    "Power going out": "Potencia que sale",
    "No power flowing": "No fluye potencia",
    "Grid connection port": "Puerto de red",
    "AC1": "AC1",
    "AC2": "AC2",
    "Solar by panel": "Solar por panel",
    "EcoFlow": "EcoFlow",
    "Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.": "Potencia solar, de la casa, de la red y de la batería, tal como la informan los dispositivos ahora. ENTRA es la potencia que llega, SALE la que se va.",
    "Solar": "Solar",
    "Home": "Casa",
    "Grid": "Red",
    "Battery": "Batería",
    "IN": "ENTRA",
    "OUT": "SALE",
    "Idle": "En reposo",
    "Charging": "Cargando",
    "Not charging": "No se está cargando",
    "Offline: showing the last readings": "Sin conexión: se muestran las últimas lecturas",
    "No devices yet": "Aún no hay dispositivos",
    "The plugin has not had readings from your devices yet. They usually arrive within a minute.": "El plugin aún no ha recibido lecturas de tus dispositivos. Suelen llegar en menos de un minuto.",
    "This page checks again every few seconds while it is open.": "Esta página vuelve a comprobarlo cada pocos segundos mientras esté abierta.",
    "Input": "Entrada",
    "Output": "Salida",
    "AC input": "Entrada AC",
    "230V AC": "230V AC",
    "USB-A": "USB-A",
    "USB-C": "USB-C",
    "Power coming into the station from all its inputs": "Potencia que entra en la estación por todas sus entradas",
    "Power the station supplies on all its outputs": "Potencia que la estación entrega por todas sus salidas",
    "Power coming in through the AC input": "Potencia que entra por la entrada AC",
    "Power the AC sockets supply": "Potencia que entregan las tomas AC",
    "Power the USB-A ports supply": "Potencia que entregan los puertos USB-A",
    "Power the USB-C ports supply": "Potencia que entregan los puertos USB-C"
  },
  "pt": {
    "Developer API": "API para programadores",
    "EcoFlow app": "Aplicação EcoFlow",
    "Live, from the developer API's MQTT pushes": "Em direto, pelos envios MQTT da API para programadores",
    "Read at the developer API's interval, from its REST values": "Lido ao intervalo da API para programadores, dos seus valores REST",
    "Live, from the EcoFlow app's stream": "Em direto, pelo fluxo da Aplicação EcoFlow",
    "Offline: no readings since the plugin started": "Offline: nenhuma leitura desde que o plugin foi iniciado",
    "Move {name}": "Mover {name}",
    "Drag to reorder, or use the arrow keys": "Arraste para reordenar, ou use as setas",
    "{n} device is not in the configuration yet. Add it to keep it by its serial number and to rename it in the settings.": "{n} dispositivo ainda não está na configuração. Adicione-o para o manter pelo número de série e mudar o nome nas definições.",
    "{n} devices are not in the configuration yet. Add them to keep them by their serial numbers and to rename them in the settings.": "{n} dispositivos ainda não estão na configuração. Adicione-os para os manter pelos números de série e mudar o nome nas definições.",
    "Add to the configuration": "Adicionar à configuração",
    "Loading": "A carregar",
    "Waiting for its first readings": "À espera das primeiras leituras",
    "Loading the devices": "A carregar os dispositivos",
    "{d}d {h}h": "{d} d {h} h",
    "{h}h {m}m": "{h} h {m} min",
    "{m}m": "{m} min",
    "{time} to full": "{time} até à carga completa",
    "{time} left": "faltam {time}",
    "Time until the battery is full at the current power, as the device estimates it": "Tempo até a bateria estar cheia à potência atual, segundo a estimativa do dispositivo",
    "Time until the battery is empty at the current power, as the device estimates it": "Tempo até a bateria se esgotar à potência atual, segundo a estimativa do dispositivo",
    "Untested": "Não testado",
    "This model's readings come from open-source projects and have not been checked on a real device yet": "As leituras deste modelo vêm de projetos de código aberto e ainda não foram verificados num dispositivo real",
    "Power from the solar panels now": "Potência dos painéis solares agora",
    "Power the home uses now": "Potência que a casa consome agora",
    "Power exchanged with the grid: IN is import, OUT is export": "Potência trocada com a rede: ENTRA é importação, SAI é exportação",
    "Power into the battery while charging, out of it while discharging": "Potência que entra na bateria ao carregar, e sai ao descarregar",
    "Power this socket supplies to what is plugged in": "Potência que esta tomada fornece ao que está ligado",
    "Power through the AC port: OUT feeds the home, IN takes power in": "Potência pela porta AC: SAI alimenta a casa, ENTRA recebe energia",
    "The battery's state of charge": "O nível de carga da bateria",
    "Whether the battery is charging now": "Se a bateria está a carregar agora",
    "Power from this solar panel input": "Potência desta entrada de painel solar",
    "Power coming in": "Potência que entra",
    "Power going out": "Potência que sai",
    "No power flowing": "Não há potência a circular",
    "Grid connection port": "Porta da rede",
    "AC1": "AC1",
    "AC2": "AC2",
    "Solar by panel": "Solar por painel",
    "EcoFlow": "EcoFlow",
    "Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.": "Potência solar, da casa, da rede e da bateria, tal como os dispositivos a comunicam agora. ENTRA é a potência que chega, SAI a que sai.",
    "Solar": "Solar",
    "Home": "Casa",
    "Grid": "Rede",
    "Battery": "Bateria",
    "IN": "ENTRA",
    "OUT": "SAI",
    "Idle": "Parado",
    "Charging": "A carregar",
    "Not charging": "Não está a carregar",
    "Offline: showing the last readings": "Offline: a mostrar as últimas leituras",
    "No devices yet": "Ainda não há dispositivos",
    "The plugin has not had readings from your devices yet. They usually arrive within a minute.": "O plugin ainda não recebeu leituras dos seus dispositivos. Costumam chegar em menos de um minuto.",
    "This page checks again every few seconds while it is open.": "Esta página volta a verificar a cada poucos segundos enquanto estiver aberta.",
    "Input": "Entrada",
    "Output": "Saída",
    "AC input": "Entrada AC",
    "230V AC": "230V AC",
    "USB-A": "USB-A",
    "USB-C": "USB-C",
    "Power coming into the station from all its inputs": "Potência que entra na estação por todas as suas entradas",
    "Power the station supplies on all its outputs": "Potência que a estação fornece em todas as suas saídas",
    "Power coming in through the AC input": "Potência que entra pela entrada AC",
    "Power the AC sockets supply": "Potência fornecida pelas tomadas AC",
    "Power the USB-A ports supply": "Potência fornecida pelas portas USB-A",
    "Power the USB-C ports supply": "Potência fornecida pelas portas USB-C"
  }
});

"""#),
        "icon.svg": WebFile(contentType: "image/svg+xml", body: #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 150 150" role="img" aria-label="EcoFlow">
  <g fill="currentColor">
    <rect x="22" y="54" width="51" height="8.4"/>
    <rect x="22" y="71" width="51" height="8.4"/>
    <rect x="22" y="88" width="51" height="8.4"/>
    <rect x="78" y="54" width="50" height="8.4"/>
    <rect x="78" y="71" width="50" height="8.4"/>
    <rect x="78" y="71" width="8.4" height="25.4"/>
  </g>
</svg>

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>EcoFlow</title>
<link rel="icon" href="icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* One card per device: its battery first, then the four flows as IN and OUT, then the solar by panel. Two columns
     where a card keeps its flows side by side, one on a phone. */
  .devices { display: grid; gap: 14px; }
  .devices > .card { margin: 0; min-width: 0; }
  /* Two columns, packed: each card keeps its own height and the next one fills the shorter column, so a STREAM with
     its panels does not leave a hole beside a RIVER. The rows are 2px tall and app.js gives each card the span its
     height and the gap take (`--pack-row`, `--pack-gap`); the order still reads left to right, then down. */
  @media (min-width: 820px) {
    .devices { --pack-row: 2px; --pack-gap: 14px; grid-template-columns: repeat(2, minmax(0, 1fr));
      grid-auto-rows: var(--pack-row); row-gap: 0; column-gap: var(--pack-gap); align-items: start; }
    .devices > .card.empty, .devices > .note { grid-column: 1 / -1; }
  }
  .device { display: grid; gap: 14px; align-content: start; }
  .device.enter { animation: materialize var(--normal) var(--ease-out); }

  .device-head h2 { margin: 0; }

  /* The grip that drags a card to another place, or moves it with the arrow keys. */
  .handle { margin-left: auto; width: 28px; height: 28px; min-height: 0; padding: 0; flex: none; display: grid; place-items: center; border: 0; border-radius: 8px;
    background: none; box-shadow: none; color: var(--muted); opacity: 0.6; cursor: grab; touch-action: none; }
  /* A finger needs a larger target; the negative margin keeps the title line's height. */
  @media (pointer: coarse) { .handle { width: 40px; height: 40px; margin: -6px -8px -6px auto; } }
  .handle svg { display: block; width: 10px; height: 16px; fill: currentColor; }
  .handle:hover, .handle:focus-visible { opacity: 1; background: var(--material-thin); }
  .device.dragging { position: relative; z-index: 2; cursor: grabbing; box-shadow: 0 14px 30px rgba(25, 34, 56, 0.22); }
  .device.dragging .handle { cursor: grabbing; }
  .devices.sorting { user-select: none; }
  .device.settling { transition: transform var(--normal) var(--ease-out), box-shadow var(--normal) var(--ease-out); }
  .title-line { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .way.source { background: var(--material-thin); color: var(--muted); border: 1px solid var(--line); }
  /* A model not yet checked on a real device: the warning tint, beside the source. */
  .way.untested { background: color-mix(in srgb, var(--warn) 16%, transparent); color: var(--warn); }
  .serial { margin: 2px 0 0; font-size: 0.8125rem; color: var(--muted); font-variant-numeric: tabular-nums; }

  /* The battery leads: the largest figure on the card, its level beside the graphic and its state after it. */
  .battery-line { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
  .battery-line .figure { white-space: nowrap; display: flex; align-items: center; gap: 12px; font-size: 2.5rem; font-weight: 650; line-height: 1; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
  .battery-line .figure small { font-size: 0.5em; font-weight: 500; opacity: 0.7; }
  /* The time to full or to empty, beside the charging state; its own line under it on a narrow card. */
  .battery-state { display: flex; align-items: center; justify-content: flex-end; flex-wrap: wrap; gap: 6px 10px; }
  .remaining { font-size: 0.8125rem; color: var(--muted); font-variant-numeric: tabular-nums; }
  .flow.wide { grid-column: 1 / -1; }
  .value { display: flex; align-items: center; gap: 8px; }
  .spark { flex: 1; min-width: 0; height: 24px; }
  .spark svg { width: 100%; height: 100%; overflow: visible; }
  /* The sparkline's loader: a short line that shimmers across the slot until the reading's last hour arrives. */
  .spark-loader { display: block; width: 100%; height: 2px; margin-top: 11px; border-radius: 2px; opacity: 0.5;
    background: linear-gradient(90deg, transparent, var(--muted), transparent) 0 0 / 200% 100%; animation: spark-shimmer 1.4s linear infinite; }
  @keyframes spark-shimmer { from { background-position: 100% 0; } to { background-position: -100% 0; } }
  @media (prefers-reduced-motion: reduce) { .spark-loader { animation: none; } }
  .spark polyline { fill: none; stroke: var(--muted); stroke-width: 1.5; stroke-linejoin: round; stroke-linecap: round; opacity: 0.7; vector-effect: non-scaling-stroke; }
  .arrow { display: inline-block; width: 0; height: 0; margin-right: 8px; vertical-align: middle; border-left: 6px solid transparent; border-right: 6px solid transparent; }
  .arrow.in { border-bottom: 9px solid var(--ok); }
  .arrow.out { border-top: 9px solid var(--warn); }
  .battery-mini { display: inline-flex; color: var(--ok); line-height: 0; }
  /* No level known: the outline only, muted, rather than green beside a dash. */
  .battery-mini.unknown { color: var(--muted); }
  .battery-mini svg { width: 48px; height: 48px; overflow: visible; }
  .battery-mini rect.bat-body, .battery-mini path.bat-terminal { fill: none; stroke: currentColor; stroke-width: 1.6; }
  .battery-mini path.bat-terminal { stroke-linecap: round; }
  .battery-mini .bat-bar { fill: currentColor; opacity: 0.2; }
  .battery-mini .bat-bar.on { opacity: 1; }

  /* The flows: two columns at every phone width, so the card stays short. */
  .flows { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .flow { padding: 12px 14px; border-radius: 16px; background: var(--material-thin); border: 1px solid var(--line); min-width: 0; }
  .flow .label { font-size: 0.8125rem; color: var(--muted); display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .flow .value { font-size: 1.5rem; font-weight: 650; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; margin-top: 4px; }
  .flow .value small { font-size: 0.6em; font-weight: 500; opacity: 0.7; margin-left: 2px; }
  .way { font-size: 0.75rem; font-weight: 700; letter-spacing: 0.04em; padding: 2px 8px; border-radius: 999px; }
  .way.in { background: color-mix(in srgb, var(--ok) 16%, transparent); color: var(--ok); }
  .way.out { background: color-mix(in srgb, var(--warn) 16%, transparent); color: var(--warn); }
  .way.idle { background: var(--material-thin); color: var(--muted); }

  /* The panels: four tiles in a row; the label is a caption, not a sentence. */
  .panels { display: grid; gap: 8px; }
  .panels > .caption { margin: 0; font-size: 0.8125rem; color: var(--muted); }
  .panel-row { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; }
  .pv-tile { padding: 10px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); min-width: 0; }
  /* The input's name and, while it produces, the arrow of power coming in: a word badge does not fit a quarter of a
     card in every language ("ENTRÉE" covered "PV1"). */
  .pv-tile .label { display: flex; align-items: center; justify-content: space-between; gap: 4px; font-size: 0.75rem; color: var(--muted); }
  .pv-tile .label .arrow { margin-right: 0; }
  .pv-tile .value { display: block; font-size: 1.0625rem; font-weight: 650; font-variant-numeric: tabular-nums; margin-top: 2px; }
  .pv-tile .value small { font-size: 0.6em; font-weight: 500; opacity: 0.7; }
  @media (max-width: 359px) { .panel-row { grid-template-columns: repeat(2, minmax(0, 1fr)); } }

  .note { font-size: 0.8125rem; color: var(--muted); margin: 0; }

  /* Devices read but not in the configuration: a sentence and the button that saves them, above the cards. */
  .card.unsaved { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; margin: 0 0 14px; }
  .card.unsaved.hidden { display: none; }
  .card.unsaved .note { flex: 1 1 20em; }

  /* No readings yet: the shared empty card, with a sentence on why and when the page looks again. */
  .card.empty { text-align: center; padding: 28px 20px; }
  .card.empty h2 { margin: 0 0 6px; }
  .card.empty p { margin: 0 auto; max-width: 34em; }
  .card.empty p + p { margin-top: 6px; }

  /* A device on its way: shimmering bars where its battery and flows will be, as the sparklines' loader shimmers. */
  .placeholder-bar { display: block; height: 12px; border-radius: 6px; opacity: 0.45;
    background: linear-gradient(90deg, var(--line), var(--muted), var(--line)) 0 0 / 200% 100%; animation: spark-shimmer 1.4s linear infinite; }
  .placeholder-bar.title { width: 40%; height: 18px; }
  .placeholder-bar.figure { width: 30%; height: 36px; border-radius: 10px; }
  .placeholder-bar.label { width: 45%; }
  .placeholder-bar.value { width: 60%; height: 22px; margin-top: 10px; }
  .device.pending .flows .flow { min-height: 72px; }
  @media (prefers-reduced-motion: reduce) { .placeholder-bar { animation: none; } }

  @media (prefers-reduced-motion: reduce) { .device.enter { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main class="page">
  <div class="page-head">
    <div class="who">
      <h1 data-i18n>EcoFlow</h1>
      <p class="note" data-i18n>Solar, home, grid and battery power, as the devices report them now. IN is power coming in, OUT is power going out.</p>
    </div>
  </div>
  <section id="unsaved" class="card unsaved hidden" aria-live="polite"></section>
  <section id="devices" class="devices" aria-live="polite"></section>
</main>
<script src="/i18n.js"></script>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
