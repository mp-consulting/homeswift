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
    // Every height read first, then every span written: one layout, where a read after each write would make one per
    // card. The layout height: a card's entrance (a scale) or its drag (a translate) does not change its place.
    const nodes = [...list.children];
    const heights = nodes.map((node) => node.offsetHeight);
    nodes.forEach((node, index) => { node.style.gridRowEnd = row > 0 ? `span ${Math.ceil((heights[index] + gap) / row)}` : ""; });
  }
  let packing = 0;
  // The observer's first report after `observeCards` is the cards just packed: skipped.
  let observed = false;
  const packer = new ResizeObserver(() => {
    if (!observed) { observed = true; return; }
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
    observed = false;
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
  // A drag or an order on its way to the plugin: the polls' answers wait (`saving` is below).
  const held = () => sorting || saving > 0;

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
        // The plugin kept the order before: the next answer, though the same as the last, draws it again.
        lastAnswer = "";
        HomeswiftCommon.showAlert(HomeswiftI18n.message(error.message));
      } finally {
        saving--;
      }
    });
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
    // render() keeps the focus on the moved card's grip.
    render();
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
    await homeswift.updateDevices((entries) => {
      for (const device of devices) {
        if (!entries.some((entry) => entry.id === device.id)) entries.push({ id: device.id, name: device.name });
      }
    });
    lastAnswer = "";
    await refresh();
  }

  // The cards are drawn again only when the readings changed: the plugin's values change at its own poll.
  let lastAnswer = "";
  async function refresh() {
    // While a card is dragged, an answer would put back the order it is changing: it is read again after.
    if (held()) return;
    try {
      const body = await request("power");
      if (held()) return;
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
      if (held()) return;
      replaceCards(el("p", { class: "note", text: HomeswiftI18n.message(error.message) }));
    }
  }

  // A placeholder at once, while the first answer is on its way.
  render();
  homeswift.poll(refresh, 3000);
  setInterval(loadHistory, 60000);
})();
