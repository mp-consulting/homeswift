// The EcoFlow page: each device the plugin reads, its battery, and its power as IN and OUT, laid out by kind as the
// app does. The page refreshes every few seconds while it is visible; it reads `GET power` from the plugin.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
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
    const node = el("span", { class: "battery-mini", "aria-hidden": "true" });
    const filled = level === null ? 0 : level >= 67 ? 3 : level >= 34 ? 2 : level >= 10 ? 1 : 0;
    const bars = [0, 1, 2].map((index) => `<rect class="bat-bar${index < filled ? " on" : ""}" x="${4.5 + index * 3.9}" y="8.8" width="2.6" height="6.4" rx="0.6"/>`).join("");
    node.innerHTML = `<svg viewBox="0 0 24 24"><rect class="bat-body" x="2" y="6.5" width="17" height="11" rx="2"/><path class="bat-terminal" d="M21.5 10.5v3"/>${bars}</svg>`;
    return node;
  }

  // Where a device's values come from: the developer API's MQTT pushes, its REST quota, or the EcoFlow app's stream.
  // Each device's values all come from one source, shown beside its name.
  const sourceLabel = (source) => ({ mqtt: "MQTT", rest: "REST", app: t("App") })[source] ?? source;
  const sourceTip = (source) => ({
    mqtt: t("Values from the developer API's MQTT pushes"),
    rest: t("Values from the developer API's REST quota"),
    app: t("Values from the EcoFlow app's stream"),
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
    const battery = el("div", { class: "battery-line" },
      el("div", { class: "figure", "data-tip": t("The battery's state of charge") }, batteryGraphic(level), level === null ? "–" : figure(String(level), "%")),
      el("div", { class: "battery-state" }, remaining(device),
        el("span", { class: `pill ${device.charging ? "on" : ""}`, text: device.charging ? t("Charging") : t("Not charging"), "data-tip": t("Whether the battery is charging now") })));
    const shown = (device.series ?? []).filter((key) => flows[key]);
    const flowList = el("div", { class: "flows" }, shown.map((key) => {
      const [label, inWhenPositive, tip, wide] = flows[key];
      return flow(t(label), device[key], inWhenPositive, historyOf(device.id, key), t(tip), wide);
    }));
    const status = device.online ? null : el("p", { class: "note", text: t("Offline: showing the last readings") });
    const panels = (device.panels ?? []).length
      ? el("div", { class: "panels" }, el("p", { class: "caption", text: t("Solar by panel") }),
          el("div", { class: "panel-row" }, device.panels.map((value, index) =>
            el("div", { class: "pv-tile", "data-tip": t("Power from this solar panel input") }, el("span", { class: "label" }, `PV${index + 1}`, el("span", { class: "way in", text: t("IN") })),
              el("span", { class: "value" }, power(value).number, el("small", { text: ` ${power(value).unit}` }))))))
      : null;
    return el("article", { class: `card device${enter ? " enter" : ""}`, "aria-label": device.name },
      el("div", { class: "device-head" },
        el("div", { class: "title-line" }, el("h2", { text: device.name }),
          el("span", { class: "way source", text: sourceLabel(device.source), "data-tip": sourceTip(device.source) }),
          device.tested === false ? untested() : null),
        el("p", { class: "serial", text: device.model ? `${device.model} · ${device.id}` : device.id })),
      battery, flowList, panels, status);
  }

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
    if (pending === null) {
      list.replaceChildren(placeholder(null));
      return;
    }
    const cards = known.map((device) => {
      const enter = !shown.has(device.id);
      shown.add(device.id);
      return card(device, enter);
    });
    const placeholders = pending.map(placeholder);
    list.replaceChildren(...(cards.length + placeholders.length === 0 ? [waiting()] : [...cards, ...placeholders]));
  }

  // The cards are drawn again only when the readings changed: the plugin's values change at its own poll.
  let lastAnswer = "";
  async function refresh() {
    try {
      const body = await request("power");
      const devices = body.devices ?? [];
      const answer = JSON.stringify([devices, body.waiting ?? []]);
      if (answer === lastAnswer) return;
      lastAnswer = answer;
      known = devices;
      pending = body.waiting ?? [];
      loadHistory(true);
      render();
    } catch (error) {
      lastAnswer = "";
      list.replaceChildren(el("p", { class: "note", text: HomeswiftI18n.message(error.message) }));
    }
  }

  // A placeholder at once, while the first answer is on its way.
  render();
  homeswift.poll(refresh, 3000);
  setInterval(loadHistory, 60000);
})();
