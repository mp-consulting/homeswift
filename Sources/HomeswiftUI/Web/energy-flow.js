// The Status page's Energy flow card: where the home's power comes from and goes, two ways, in one frame. The house: a
// cutaway picture (the viewer's House style; its layout file says where the conduits land in the
// image) with the latest reading's power running along them. The diagram: solar, the grid, the battery and the home as
// circles, dots running between them, either now (the latest reading, in watts) or today (the day's energy so far, split
// as the Energy by day bars split it). Under the picture, the readings, what powers the home, today's biggest users and
// what powered the home through the day. Motion only says something: how much power a line carries (more dots, faster)
// and which way; with reduced motion the lines stay still and the figures say it all.
//
// The card is built once: each reading changes its words in place, and the picture, the overlay or the diagram only when
// what they show changes, so nothing jumps and the animations keep their pace.
(() => {
  "use strict";

  const { t } = HomeswiftI18n;
  const { el, icon, api } = HomeswiftCommon;
  const ns = "http://www.w3.org/2000/svg";
  const svg = (tag, attrs = {}, ...children) => {
    const node = document.createElementNS(ns, tag);
    for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
    node.append(...children.flat().filter((child) => child != null));
    return node;
  };
  /// Equal modules and gaps, projected onto each roof. The same grid covers every artwork variant and preview.
  function solarPanels(style, night = false) {
    const simple = style === "simple";
    // The Simple style's array as Scripts/energy-house.py renders it (its layout's `panels`), in a 3:2 frame.
    const [width, height] = simple ? [1600, 1066] : [1536, 1024];
    const corners = simple ? [[541, 116], [770, 171], [584, 301], [381, 222]]
      : style === "apartment" ? [[322, 144], [1226, 144], [1311, 251], [214, 251]]
      : [[319, 140], [1227, 140], [1293, 253], [241, 253]];
    const project = (u, v) => corners[0].map((_, axis) =>
      (1 - v) * ((1 - u) * corners[0][axis] + u * corners[1][axis])
        + v * ((1 - u) * corners[3][axis] + u * corners[2][axis]));
    const point = (u, v) => project(u, v).map(n => n.toFixed(2)).join(",");
    const quad = (left, top, right, bottom) => [point(left, top), point(right, top), point(right, bottom), point(left, bottom)].join(" ");
    const columns = simple ? 7 : 8, rows = 2;
    const modules = [];
    for (let row = 0; row < rows; row++) for (let column = 0; column < columns; column++) {
      const left = (column + 0.025) / columns, right = (column + 0.975) / columns;
      const top = (row + 0.025) / rows, bottom = (row + 0.975) / rows;
      const cells = [];
      for (let i = 1; i < 6; i++) {
        const u = left + (right - left) * i / 6;
        cells.push(`M${point(u, top)} L${point(u, bottom)}`);
      }
      for (let i = 1; i < 10; i++) {
        const v = top + (bottom - top) * i / 10;
        cells.push(`M${point(left, v)} L${point(right, v)}`);
      }
      modules.push(svg("g", { class: "solar-module" },
        svg("polygon", { points: quad(left, top, right, bottom), fill: night ? "#10243e" : "#203f65", stroke: night ? "#65758b" : "#abb8c8", "stroke-width": simple ? 1.6 : 1.2 }),
        svg("path", { d: cells.join(" "), fill: "none", stroke: night ? "#456282" : "#6d8ba9", "stroke-width": 0.55, opacity: 0.7 }),
        svg("polygon", { points: quad(left, top, right, top + (bottom - top) * 0.45), fill: "#bdd9f0", opacity: night ? 0.035 : 0.07 })));
    }
    return svg("svg", { viewBox: `0 0 ${width} ${height}`, class: "energy-solar-panels", "aria-hidden": "true", focusable: "false" },
      svg("polygon", { points: quad(0, 0, 1, 1), fill: night ? "#17202b" : "#394654", stroke: night ? "#384859" : "#8192a5", "stroke-width": 2 }), modules);
  }

  const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  const storageKey = "homeswift.energy-flow";
  const remembered = () => { try { return JSON.parse(localStorage.getItem(storageKey) || "{}"); } catch { return {}; } };
  const remember = (value) => { try { localStorage.setItem(storageKey, JSON.stringify({ ...remembered(), ...value })); } catch {} };
  // The charts' slots (solar yellow, the home blue, the battery aqua, the grid violet) and the Today figures' icons.
  const tones = { solar: 4, home: 1, battery: 3, grid: 7 };
  const icons = { solar: "sun", home: "house", battery: "battery", grid: "pylon" };
  const sources = ["solar", "battery", "grid"];
  const labels = () => ({ solar: t("Solar"), battery: t("Battery"), grid: t("Grid") });
  // The house's layout files, by image: they never change while the page is open.
  const layouts = new Map();
  const loadLayout = (name) => {
    if (!layouts.has(name)) {
      // A failed fetch is forgotten, so the next reading tries again.
      layouts.set(name, fetch(`/${name}.json`).then((response) => response.ok ? response.json() : null).catch(() => null)
        .then((layout) => { if (!layout) layouts.delete(name); return layout; }));
    }
    return layouts.get(name);
  };
  const timeFormat = () => new Intl.DateTimeFormat(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit", hour12: false });

  /// Where the home's energy came from and where solar's went, from totals or one reading alike (all zero or above), as
  /// the bridge's history splits it: solar covers the home first; of the rest the grid's import, then the battery; solar
  /// left over charges the battery, the rest is exported; what charged the battery and solar did not give came from the
  /// grid. A day's `homeFromGrid` and `homeFromBattery`, minute by minute on the bridge, are taken as they are.
  function split({ solar = 0, home = 0, imported = null, charge = 0, discharge = 0, exported = null, homeFromSolar = null, homeFromGrid = null, homeFromBattery = null }) {
    const sh = Math.max(0, Math.min(homeFromSolar ?? Math.min(solar, home), home));
    const rest = Math.max(0, home - sh);
    const gh = homeFromGrid ?? (imported == null ? Math.max(0, rest - discharge) : Math.min(imported, rest));
    const bh = homeFromBattery ?? Math.min(discharge, Math.max(0, rest - gh));
    const left = Math.max(0, solar - sh);
    const sb = Math.min(charge, left);
    const sg = Math.max(0, exported == null ? left - sb : Math.min(exported, left - sb));
    const gb = Math.max(0, charge - sb);
    return { sh, sb, sg, gh, gb, bh };
  }

  /// The latest reading: watts, the grid and the battery signed as the charts sign them.
  function fromReading(point, level) {
    const value = (role) => point?.[role] ?? null;
    const grid = value("grid"), battery = value("battery");
    const figures = {
      solar: Math.max(0, value("solar") ?? 0), home: Math.max(0, value("home") ?? 0),
      imported: Math.max(0, grid ?? 0), exported: Math.max(0, -(grid ?? 0)),
      charge: Math.max(0, battery ?? 0), discharge: Math.max(0, -(battery ?? 0)), level,
    };
    return { ...figures, flows: split({ ...figures, imported: grid == null ? null : figures.imported, exported: grid == null ? null : figures.exported }) };
  }

  /// The day so far, in kWh.
  function fromDay(day) {
    const figures = {
      solar: day?.solar ?? 0, home: day?.home ?? 0, imported: day?.gridImport ?? 0, exported: day?.gridExport ?? 0,
      charge: day?.batteryCharge ?? 0, discharge: day?.batteryDischarge ?? 0, level: null,
    };
    return { ...figures, flows: split({ ...figures, homeFromSolar: day?.homeFromSolar, homeFromGrid: day?.homeFromGrid, homeFromBattery: day?.homeFromBattery }) };
  }

  /// A home metered at the grid alone (no solar, no battery, no meter of the home's own use) uses what the grid brings
  /// in: the report gains that home use, so the house's rooms light up and the readings show it.
  function gridAlone(report) {
    const has = (role) => report.roles.includes(role);
    if (!has("grid") || has("home") || has("solar") || has("battery")) return report;
    return { ...report, roles: [...report.roles, "home"],
      power: report.power.map((point) => point.grid == null ? point : { ...point, home: Math.max(0, point.grid) }),
      days: report.days.map((day) => day && { ...day, home: day.gridImport, homeFromGrid: day.gridImport, homeFromSolar: 0 }) };
  }

  /// What each source gave the home, the sources present only: `[role, value]`.
  const supplies = (f, has) => [["solar", f.sh], ["battery", f.bh], ["grid", f.gh]].filter(([role]) => has(role));

  /// The card. `format` has `watts`, `kWh` and `percent`. `update(report)` takes the Energy section's report: its roles,
  /// its power points and levels, today, and the day's sunrise and sunset. With `details`, today's biggest users and the
  /// day's band under it.
  function card(format, { details: withDetails = false } = {}) {
    const saved = remembered();
    const state = { view: saved.view === "diagram" ? "diagram" : "house", span: saved.span === "today" ? "today" : "now", values: saved.values === true };
    let report = null;
    /// A row of radio buttons for one of the card's choices, kept in this browser.
    const radio = (key, label, options) => {
      // Named on the button itself too, so its name stays when a narrow panel shows the icon alone.
      const buttons = options.map(([value, text, actionIcon]) => el("button", { type: "button", role: "radio", actionIcon, "aria-label": text, title: text, onclick: () => {
        if (state[key] === value) return;
        state[key] = value;
        remember({ [key]: value });
        mark();
        draw();
      } }, el("span", { text })));
      const mark = () => buttons.forEach((button, index) => {
        button.classList.toggle("on", options[index][0] === state[key]);
        button.setAttribute("aria-checked", String(options[index][0] === state[key]));
      });
      mark();
      return el("div", { class: "group", role: "radiogroup", "aria-label": label }, buttons);
    };
    const views = radio("view", t("View"), [["house", t("House"), "house"], ["diagram", t("Diagram"), "chart"]]);
    const spans = radio("span", t("Period"), [["now", t("Now"), "bolt"], ["today", t("Today"), "history"]]);

    // The frame: the picture (or the diagram) on top, the details panel under it with the badge, the title and the
    // views, the readings and what powers the home; then today's biggest users and the day's band.
    const note = el("div", { class: "muted" });
    const scene = el("div", { class: "energy-house-scene" });
    // Values: the figures on the picture, on or off, kept in this browser; on the house alone.
    // Round, the icon alone (a pulse: the live figures); its name for whoever cannot see it.
    const valuesButton = el("button", { type: "button", class: "energy-values-toggle", "aria-label": t("Values"), title: t("Show the figures on the picture"),
      "aria-pressed": String(state.values), onclick: () => {
        state.values = !state.values;
        remember({ values: state.values });
        valuesButton.setAttribute("aria-pressed", String(state.values));
        valuesButton.classList.toggle("on", state.values);
        draw();
      } }, HomeswiftCommon.icon("pulse"));
    valuesButton.classList.toggle("on", state.values);
    const frame = el("div", { class: "energy-house" }, scene, valuesButton);
    const readings = el("div", { class: "energy-house-readings" });
    const supply = el("div", { class: "energy-supply", hidden: true });
    const details = el("div", { class: "energy-house-details" },
      el("span", { class: "energy-house-badge", "aria-hidden": "true" }, icon("house")),
      el("div", { class: "energy-house-title-row" },
        el("div", { class: "chart-head" }, el("div", { class: "who" }, el("strong", { text: t("Energy flow") }), note)),
        el("div", { class: "energy-flow-bar" }, views)),
      readings, supply);
    const devices = el("div", { class: "energy-devices", hidden: true });
    const day = el("div", { class: "energy-day", hidden: true });
    // Today's biggest users and the day's band, under the card in the version with details.
    const more = el("div", { class: "energy-more" }, devices, day);
    // Nothing to show (no home use, no meters, no reading today): no space kept for it.
    const fold = () => { more.hidden = devices.hidden && day.hidden; };
    const node = el("div", { class: "card chart-card energy-flow" }, el("div", { class: "energy-house-story" }, frame, details), withDetails ? more : null);
    fold();
    // A change of House style on the Appearance page, in this tab or another, draws the house again.
    // The listener goes with the card: the page builds a new card on each visit to Status.
    const restyle = () => {
      if (!node.isConnected) { document.removeEventListener("homeswift:preferences", restyle); return; }
      if (report) draw();
    };
    document.addEventListener("homeswift:preferences", restyle);

    function draw() {
      if (!report) return;
      const has = (role) => report.roles.includes(role);
      // Now is the live reading when there is one (the minute under way, asked every few seconds), else the report's last.
      const now = live?.power.length ? live : report;
      const last = now.power.findLast((point) => !point.imported);
      // The home battery's charge: its units' latest levels averaged.
      const latest = homeLevels(now.levels).map((one) => one.level);
      const level = latest.length ? latest.reduce((sum, value) => sum + value, 0) / latest.length : null;
      const isLive = state.view === "house" || state.span === "now";
      spans.hidden = state.view === "house";
      frame.classList.toggle("diagram", state.view === "diagram");
      if (state.view === "diagram") frame.classList.remove("photo", "simple");
      phases(has);
      appliances(has).then(fold);
      fold();
      if (isLive && !last) {
        note.textContent = t("No reading yet");
        frame.classList.remove("photo", "simple");
        show("empty", () => el("p", { class: "muted energy-flow-empty", text: t("The flow appears with the first reading.") }), "auto");
        readings.replaceChildren();
        supply.hidden = true;
        return;
      }
      const figures = isLive ? fromReading(last, level) : fromDay(report.days[0]);
      const when = new Date(last?.t * 1000);
      note.textContent = isLive
        ? (Date.now() - when > 10 * 60000 ? t("Reading of {time}", { time: when.toLocaleString(HomeswiftI18n.locale, { weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false }) }) : t("The latest reading"))
        : t("Today so far");
      const amount = isLive ? format.watts : format.kWh;
      fillReadings(figures, has, amount);
      // The house is one picture, described by the readings; the diagram describes itself.
      if (state.view === "house") frame.setAttribute("role", "img");
      else { frame.removeAttribute("role"); frame.removeAttribute("aria-label"); }
      if (state.view === "house") house(figures, has, amount, when);
      // The diagram takes the house picture's frame, so switching views moves nothing below it.
      else show(`diagram ${diagramKey(figures, has, isLive)}`, () => el("div", { class: "energy-diagram-scene" }, el("div", { class: "energy-diagram-period" }, spans), diagram(figures, has, amount, isLive)));
    }

    /// Puts `make()` in the scene unless what it shows (`key`) is there already.
    let shown = "";
    function show(key, make, ratio = "3 / 2") {
      if (key === shown) return;
      shown = key;
      scene.style.aspectRatio = ratio;
      scene.replaceChildren(...[make()].flat().filter(Boolean));
    }

    /// The readings in the details panel, and what powers the home as a bar of its sources' shares.
    function fillReadings(figures, has, amount) {
      const f = figures.flows;
      const gridLabel = figures.exported > 0.5 ? t("To the grid") : figures.imported > 0.5 ? t("From the grid") : t("Grid");
      const batteryLabel = [figures.charge > 0.5 ? t("Charging") : figures.discharge > 0.5 ? t("Discharging") : t("Battery"),
        figures.level != null ? format.percent(figures.level) : null].filter(Boolean).join(" · ");
      const parts = [
        ["solar", figures.solar, t("Solar")], ["grid", figures.imported || figures.exported, gridLabel],
        ["home", figures.home, t("Home [use]")], ["battery", figures.charge || figures.discharge, batteryLabel],
      ].filter(([role]) => has(role));
      readings.replaceChildren(...parts.map(([role, value, label]) => el("div", { class: "energy-callout" },
        el("span", { class: `energy-callout-icon tone-${tones[role]}`, "aria-hidden": "true" }, icon(icons[role])),
        el("b", { text: amount(value) }), el("span", { class: "energy-callout-label", text: label }))));
      if (state.view === "house") frame.setAttribute("aria-label", parts.map(([, value, label]) => `${label} ${amount(value)}`).join(", "));
      const given = supplies(f, has);
      const supplied = given.reduce((sum, [, value]) => sum + value, 0);
      supply.hidden = !(supplied > 0.0005);
      if (supply.hidden) return;
      const names = labels();
      const share = (value) => format.percent(value / supplied * 100);
      supply.replaceChildren(el("strong", { text: t("Powering the home") }),
        el("div", { class: "energy-supply-bar", role: "img", "aria-label": `${t("Powering the home")}: ${given.map(([role, value]) => `${names[role]} ${share(value)}`).join(", ")}` },
          given.filter(([, value]) => value > 0).map(([role, value]) => el("i", { class: `tone-${tones[role]}`, style: `width: ${value / supplied * 100}%` }))),
        el("div", { class: "energy-supply-shares" }, given.map(([role, value]) =>
          el("div", {}, el("span", { class: `energy-callout-icon tone-${tones[role]}`, "aria-hidden": "true" }, icon(icons[role])),
            el("span", { text: names[role] }), el("b", { text: share(value) }), el("small", { text: amount(value) })))));
    }

    // The appliances ---------------------------------------------------------------------------------------------------------

    /// An appliance's icon, guessed from its name; a plug otherwise.
    const applianceIcon = (name) => [[/\b(tv|t[ée]l[ée]|television|fernseh)/i, "tv"], [/(light|lamp|lampe|bulb|ampoule|luz|l[âa]mpada)/i, "bulb"],
      [/(fan|ventil|air|clim|cool|a\/c)/i, "fan"], [/(heat|boiler|chauff|radiat|calef|aquec|thermo)/i, "thermo"],
      [/(wash|dish|lave|lava|s[èe]che|dry)/i, "drop"], [/(vacuum|aspir|robot)/i, "vacuum"], [/(car|ev\b|charg|wallbox|borne|tesla)/i, "bolt"],
      [/(speaker|sonos|enceinte|altavoz)/i, "speaker"]].find(([pattern]) => pattern.test(name))?.[1] ?? "outlet";
    let devicesAsked = 0, devicesShown = "";

    /// Under the panel, the devices measured on their own (electricity Meters of no role) that used the most today, each
    /// with its kWh and its share of the home's; asked of the bridge at most every five minutes, hidden without any.
    async function appliances(has) {
      if (!has("home") || Date.now() - devicesAsked < 5 * 60000) return;
      devicesAsked = Date.now();
      const midnight = new Date(); midnight.setHours(0, 0, 0, 0);
      let found;
      try {
        found = await api(`/api/metrics/consumption?${new URLSearchParams({ hours: ((Date.now() - midnight) / 36e5).toFixed(3), kind: "electricity",
          timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone })}`);
      } catch { devices.hidden = true; return; }
      const top = (found.meters ?? []).filter((one) => !one.role && (one.kind ?? "electricity") === "electricity" && one.consumption > 0)
        .sort((a, b) => b.consumption - a.consumption).slice(0, 6);
      const home = report.days[0]?.home ?? null;
      const key = JSON.stringify([top.map((one) => [one.name, one.label, format.kWh(one.consumption)]), home && Math.round(home * 10)]);
      devices.hidden = !top.length;
      if (!top.length || key === devicesShown) return;
      devicesShown = key;
      const most = top[0].consumption;
      devices.replaceChildren(el("strong", { class: "energy-devices-title", text: t("Today's biggest users") }),
        el("ul", {}, top.map((one) => {
          const name = one.label ? `${one.name} · ${one.label}` : one.name;
          const share = home > 0 ? Math.min(100, one.consumption / home * 100) : null;
          return el("li", {}, el("span", { class: "energy-device-icon tone-1", "aria-hidden": "true" }, icon(applianceIcon(name))),
            el("span", { class: "energy-device-name", text: name, title: name }),
            el("b", { text: format.kWh(one.consumption) }),
            el("i", { class: "energy-device-bar", style: `--share: ${(one.consumption / most * 100).toFixed(1)}%`, "aria-hidden": "true" }),
            share != null ? el("small", { text: t("{share} of the home", { share: format.percent(share) }) }) : null);
        })));
    }

    // The day's phases ------------------------------------------------------------------------------------------------------

    /// At the foot, today midnight to midnight: for each reading, the source that covered most of the home's use, runs of
    /// the same source joined, a marker at now, each source's share of the day so far. Hidden without the home's use or
    /// without a reading today.
    function phases(has) {
      const start = new Date(); start.setHours(0, 0, 0, 0);
      const end = new Date(start); end.setDate(end.getDate() + 1);
      const points = has("home") ? report.power.filter((point) => point.t * 1000 >= start.getTime() && point.t * 1000 < end.getTime()) : [];
      day.hidden = points.length < 2;
      if (day.hidden) return;
      const runs = [];
      const step = (report.step || 60) * 1000;
      for (const point of points) {
        const [role, value] = supplies(fromReading(point, null).flows, has).sort((a, b) => b[1] - a[1])[0] ?? [];
        const from = point.t * 1000, to = Math.min(from + step, end.getTime());
        const last = runs.at(-1);
        const source = value > 0 ? role : null;
        if (last && last.role === source && from - last.to <= step * 1.5) last.to = to;
        else runs.push({ role: source, from, to });
      }
      const span = end - start;
      const time = timeFormat();
      const names = labels();
      const shownRuns = runs.filter((run) => run.role);
      const describe = (run) => `${names[run.role]} ${time.format(run.from)}–${time.format(run.to)}`;
      const bar = el("div", { class: "energy-day-bar", role: "img", "aria-label": `${t("What powered the home today")}: ${shownRuns.map(describe).join(", ")}` },
        shownRuns.map((run) => el("i", { class: `tone-${tones[run.role]}`, title: describe(run),
          style: `left: ${((run.from - start) / span * 100).toFixed(3)}%; width: ${((run.to - run.from) / span * 100).toFixed(3)}%` })),
        Date.now() < end.getTime() ? el("b", { class: "energy-day-now", style: `left: ${((Date.now() - start) / span * 100).toFixed(2)}%`, "aria-hidden": "true" }) : null);
      // The hours under it, in the page's own time format, and each source's share of the day beside its colour's key.
      const hours = el("div", { class: "energy-day-hours", "aria-hidden": "true" },
        [0, 6, 12, 18].map((hour) => el("span", { text: time.format(new Date(start).setHours(hour)) })).concat(el("span", { text: "24:00" })));
      const total = shownRuns.reduce((sum, run) => sum + (run.to - run.from), 0) || 1;
      const keys = el("div", { class: "energy-day-keys" }, sources.filter(has).map((role) => {
        const share = shownRuns.filter((run) => run.role === role).reduce((sum, run) => sum + (run.to - run.from), 0) / total * 100;
        return el("span", {}, el("i", { class: `key bar tone-${tones[role]}`, "aria-hidden": "true" }), names[role], el("b", { text: format.percent(share) }));
      }));
      day.replaceChildren(el("div", { class: "energy-day-title" }, el("strong", { text: t("What powered the home today") }), keys), bar, hours);
    }

    // The house -------------------------------------------------------------------------------------------------------------

    /// Night, for the house: before the day's sunrise or after its sunset, where the bridge has a Location (the report's
    /// `sun`, for the day the reading is in); without one, no solar outside the middle of the day, or without solar, the
    /// evening and early morning.
    const isNight = (figures, has, when) => {
      const sunrise = report.sun?.sunrise ? new Date(report.sun.sunrise) : null, sunset = report.sun?.sunset ? new Date(report.sun.sunset) : null;
      if (sunrise && sunset && sunrise.toDateString() === when.toDateString()) return when < sunrise || when >= sunset;
      const hour = when.getHours() + when.getMinutes() / 60;
      return has("solar") ? figures.solar < 5 && (hour < 10 || hour >= 15) : hour < 7 || hour >= 20;
    };
    // The sun or the moon over the simple house, drawn in the page's colours.
    const sky = (night) => el("div", { class: `energy-sky${night ? " night" : ""}`, "aria-hidden": "true" }, night
      ? svg("svg", { viewBox: "0 0 48 48" }, svg("path", { d: "M30 6a18 18 0 1 0 12 30A15 15 0 0 1 30 6z", class: "moon" }))
      : svg("svg", { viewBox: "0 0 48 48" }, svg("circle", { cx: 24, cy: 24, r: 9, class: "sun" }),
        [...Array(8)].map((_, i) => svg("line", { x1: 24, y1: 6, x2: 24, y2: 11, class: "ray", transform: `rotate(${i * 45} 24 24)` }))));

    let houseVersion = 0;
    async function house(figures, has, amount, when) {
      const version = ++houseVersion;
      const style = HomeswiftCommon.preferences().energyHouseStyle;
      const custom = style === "custom" ? HomeswiftCommon.preferences().customHouse : null;
      const simple = style === "simple";
      const name = `energy-house${["simple", "beach", "cabin", "apartment", "snow", "christmas", "halloween"].includes(style) ? `-${style}` : ""}${has("battery") ? "" : "-no-battery"}`;
      const src = custom ? `/api/preferences/house/${encodeURIComponent(custom.version)}` : `/${name}${isNight(figures, has, when) ? "-night" : ""}.webp`;
      const layout = custom ? { ...custom, cables: {} } : await loadLayout(name);
      if (version !== houseVersion || state.view !== "house") return;
      if (!layout) {
        frame.classList.remove("photo", "simple");
        show("missing", () => el("p", { class: "muted energy-flow-empty", text: t("The house could not be loaded.") }), "auto");
        return;
      }
      const { width, height } = layout;
      const f = figures.flows;
      // What the overlay draws, roughly: it is drawn again only when this changes, so its pulses keep their pace.
      const step = (value) => Math.round(value / Math.max(figures.home, 1) * 10);
      const key = `house ${src} ${custom ? JSON.stringify(custom) : ""} ${sources.concat("home").filter(has).join()} ${Object.values(f).map(step).join()} ${step(figures.charge + figures.discharge)} ${step(figures.imported + figures.exported)}`;
      if (key === shown) { placeGauge(figures, has, layout); placeValues(figures, has, layout); return; }
      // A new picture is decoded before it replaces the one shown; the same picture is kept as it is.
      let image = scene.querySelector(":scope > img");
      if (image?.getAttribute("src") !== src) {
        image = el("img", { src, alt: custom ? [custom.name, custom.description].filter(Boolean).join(". ") : "", decoding: "async", width, height });
        await image.decode().catch(() => {});
        if (version !== houseVersion || state.view !== "house") return;
      }
      image.alt = custom ? [custom.name, custom.description].filter(Boolean).join(". ") : "";
      frame.classList.toggle("simple", simple);
      frame.classList.toggle("photo", !simple);
      show(key, () => [image, custom ? null : solarPanels(style, src.endsWith("-night.webp")), simple ? sky(src.endsWith("-night.webp")) : null, overlay(figures, has, layout, simple)],
        `${width} / ${height}`);
      gaugeShown = null;
      placeGauge(figures, has, layout);
      placeValues(figures, has, layout);
    }

    /// What the gauge shows: its level to the percent and whether it charges or gives.
    const gaugeKey = (figures, has) => has("battery") && figures.level != null
      ? `${Math.round(figures.level)}${figures.charge > 0.5 ? "+" : figures.discharge > 0.5 ? "-" : ""}` : "";
    /// The gauge on the house, swapped on its own when its level or state changes: the house and its conduits stay, so
    /// their pulses keep their pace.
    let gaugeShown = null;
    function placeGauge(figures, has, layout) {
      const key = gaugeKey(figures, has);
      if (key === gaugeShown) return;
      gaugeShown = key;
      scene.querySelector(":scope > .energy-battery-gauge")?.remove();
      const [gauge] = batteryGauge(figures, has, layout);
      // Under the figures, over the house.
      if (gauge) scene.insertBefore(gauge, valuesLayer.isConnected ? valuesLayer : null);
    }

    /// The battery's charge on the picture's battery (`gauge` in its layout): five small pills stacked like cells, lit
    /// from the bottom to the level, the top one lit only up to its share (61 % is three cells and a twentieth of the
    /// fourth, not four), glowing green, amber under 20 % and red under 10 %, the top one breathing while it charges. Each cell is the quad the layout gives (`cells`: the Simple model's, in the
    /// battery's perspective), else a pill cut from the face's rectangle (`rect`: a photo's battery, seen head on).
    /// Nothing without a level, or on a picture whose layout has no gauge (a person's own photo).
    function batteryGauge(figures, has, { width, height, gauge }) {
      if (!gauge || !has("battery") || figures.level == null) return [];
      const level = Math.max(0, Math.min(100, figures.level));
      const tone = level < 10 ? "empty" : level < 20 ? "low" : "ok";
      const state = figures.charge > 0.5 ? " charging" : figures.discharge > 0.5 ? " giving" : "";
      const count = gauge.cells?.length ?? 5;
      const quads = gauge.cells ?? [...Array(count)].map((_, index) => {
        const [x, y, w, h] = gauge.rect, gap = h * 0.1, pill = (h - gap * (count - 1)) / count;
        const bottom = y + h - index * (pill + gap), top = bottom - pill;
        return [[x, bottom], [x + w, bottom], [x + w, top], [x, top]];
      });
      // Each cell's share of the level, from the bottom: 1 lit, 0 dark, in between the top one's part.
      const lit = (index) => Math.max(0, Math.min(1, level / (100 / count) - index));
      // The highest cell lit, in part or whole (none at 0 %).
      const top = Math.min(count - 1, Math.ceil(level / (100 / count)) - 1);
      // Rounded by a stroke of their own colour, so a quad in perspective reads as a pill too: thin against the cell's
      // shorter side, so the gaps between cells stay open on a small gauge.
      const side = (from, to) => Math.hypot((to[0] - from[0]) * width, (to[1] - from[1]) * height);
      const round = Math.min(...quads.flatMap((quad) => [side(quad[0], quad[1]), side(quad[0], quad[3])])) * 0.25;
      // A point `share` of the way from one corner to another.
      const along = (from, to, share) => [from[0] + (to[0] - from[0]) * share, from[1] + (to[1] - from[1]) * share];
      const points = (quad) => quad.map(([x, y]) => `${(x * width).toFixed(1)},${(y * height).toFixed(1)}`).join(" ");
      return [svg("svg", { viewBox: `0 0 ${width} ${height}`, class: `energy-house-lines energy-battery-gauge ${tone}${state}`, "aria-hidden": "true",
        style: `--cell-round: ${round.toFixed(2)}px` },
        quads.flatMap((quad, index) => {
          const share = lit(index);
          const dark = () => svg("polygon", { class: "cell", points: points(quad) });
          if (share <= 0) return [dark()];
          const on = svg("polygon", { class: `cell on${index === top ? " top" : ""}`,
            points: points(share >= 1 ? quad : [quad[0], quad[1], along(quad[1], quad[2], share), along(quad[0], quad[3], share)]) });
          // The top cell in part: dark, its lit share from its bottom edge over it.
          return share < 1 ? [dark(), on] : [on];
        }))];
    }

    /// The figures on the picture, when Values is on: each part's power where its conduit lands (solar on the roof, the
    /// grid at the pole, the home in its rooms) and the battery's charge beside it, as small pills in the page's type.
    /// Their text is updated in place at each reading, so the conduits' pulses keep their pace and nothing is measured again
    /// unless a pill's width changed.
    const valuesLayer = el("div", { class: "energy-values-layer", "aria-hidden": "true" });
    function placeValues(figures, has, layout) {
      if (!state.values || !layout) { valuesLayer.remove(); return; }
      const anchors = layout.markers ?? layout.anchors ?? {};
      const watts = (value) => format.watts(Math.round(value));
      const battery = [figures.level != null ? format.percent(figures.level) : null,
        figures.charge > 0.5 ? `↓ ${watts(figures.charge)}` : figures.discharge > 0.5 ? `↑ ${watts(figures.discharge)}` : null].filter(Boolean).join(" · ");
      const values = [
        ["solar", anchors.solar, watts(figures.solar)],
        ["grid", anchors.grid, figures.exported > 0.5 ? `↑ ${watts(figures.exported)}` : `↓ ${watts(figures.imported)}`],
        ["home", anchors.home, watts(figures.home)],
        ["battery", layout.gauge?.label ?? anchors.battery, battery, layout.gauge?.side],
      ].filter(([role, at, text]) => has(role) && at && text);
      // The same figures on the same picture: their text changed in place, and placed again only when a pill's width did.
      const roles = values.map(([role]) => role).join();
      if (valuesLayer.isConnected && layout === valuesLayout && valuesLayer.dataset.roles === roles) {
        let resized = false;
        values.forEach(([, , text], index) => {
          const pill = valuesLayer.children[index], label = pill?.lastChild;
          if (!label || label.textContent === text) return;
          const before = pill.offsetWidth;
          label.textContent = text;
          if (pill.offsetWidth !== before) resized = true;
        });
        if (resized) arrangeValues();
        return;
      }
      valuesLayer.dataset.roles = roles;
      valuesLayer.replaceChildren(...values.map(([role, at, text, side]) => {
        const pill = el("span", { class: `energy-value tone-${tones[role]}` }, el("i"), text);
        pill.dataset.at = at.join(",");
        if (side) pill.dataset.side = side;
        return pill;
      }));
      valuesLayout = layout;
      if (!valuesLayer.isConnected) scene.append(valuesLayer);
      arrangeValues();
    }

    /// Each figure in the first place around its point that leaves the conduits (and their glow), the other figures,
    /// the battery's cells, the Values button and the picture's covered edges clear: its side (the layout's, or the inner
    /// one near an edge), then above, below, right, left, and the corners. Measured on the page, so again on a resize.
    let valuesLayout = null;
    function arrangeValues() {
      const layout = valuesLayout;
      const width = scene.clientWidth, height = scene.clientHeight;
      if (!layout || !valuesLayer.isConnected || !width || !height) return;
      const px = ([x, y]) => [x * width, y * height];
      const lines = [...Object.values(layout.cables ?? {})].filter((points) => points?.length > 1).map((points) => points.map(px));
      // What else a figure must leave clear: the cells, and the button in the top left.
      const blocked = [{ x: 4, y: 4, w: 52, h: 52 }];
      for (const cell of layout.gauge?.cells ?? (layout.gauge?.rect ? [[[layout.gauge.rect[0], layout.gauge.rect[1]], [layout.gauge.rect[0] + layout.gauge.rect[2], layout.gauge.rect[1] + layout.gauge.rect[3]]]] : [])) {
        const xs = cell.map(([x]) => x * width), ys = cell.map(([, y]) => y * height);
        blocked.push({ x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) });
      }
      // The details panel and its badge where they cover the picture (its right edge beside it on a wide screen, its
      // foot under it on a narrow one), measured, so the figures follow the stylesheet's layout whatever its widths.
      const box = scene.getBoundingClientRect();
      for (const part of [details, details.querySelector(".energy-house-badge")]) {
        const r = part?.getBoundingClientRect();
        if (!r?.width) continue;
        const x = Math.max(r.left, box.left) - box.left, y = Math.max(r.top, box.top) - box.top;
        const w = Math.min(r.right, box.right) - box.left - x, h = Math.min(r.bottom, box.bottom) - box.top - y;
        if (w > 0 && h > 0) blocked.push({ x, y, w, h });
      }
      const bounds = { left: 6, top: 6, right: width - 6, bottom: height - 6 };
      const glow = 8;
      const overlaps = (a, b, pad = 0) => a.x < b.x + b.w + pad && b.x < a.x + a.w + pad && a.y < b.y + b.h + pad && b.y < a.y + a.h + pad;
      const crossesLine = (box) => lines.some((points) => points.slice(1).some((end, i) => {
        const start = points[i], length = Math.hypot(end[0] - start[0], end[1] - start[1]);
        for (let step = 0; step <= length; step += 3) {
          const t = length ? step / length : 0, x = start[0] + (end[0] - start[0]) * t, y = start[1] + (end[1] - start[1]) * t;
          if (x > box.x - glow && x < box.x + box.w + glow && y > box.y - glow && y < box.y + box.h + glow) return true;
        }
        return false;
      }));
      const placed = [];
      for (const pill of valuesLayer.children) {
        const [ax, ay] = px(pill.dataset.at.split(",").map(Number)), w = pill.offsetWidth, h = pill.offsetHeight;
        const spots = (gap) => ({
          above: [ax - w / 2, ay - gap - h], below: [ax - w / 2, ay + gap], right: [ax + gap, ay - h / 2], left: [ax - gap - w, ay - h / 2],
          "above-right": [ax + gap / 2, ay - gap - h], "above-left": [ax - gap / 2 - w, ay - gap - h],
          "below-right": [ax + gap / 2, ay + gap], "below-left": [ax - gap / 2 - w, ay + gap],
        });
        const first = pill.dataset.side ?? (ax > width * 0.82 ? "left" : ax < width * 0.18 ? "right" : "above");
        const order = [first, ...Object.keys(spots(0)).filter((side) => side !== first)];
        // Close to its point first, then farther out, ring by ring.
        const boxes = [8, 18, 32].flatMap((gap) => order.map((side) => ({ x: spots(gap)[side][0], y: spots(gap)[side][1], w, h })));
        const inside = (box) => box.x >= bounds.left && box.y >= bounds.top && box.x + box.w <= bounds.right && box.y + box.h <= bounds.bottom;
        const clear = (box) => inside(box) && !crossesLine(box) && !placed.some((other) => overlaps(box, other, 4)) && !blocked.some((other) => overlaps(box, other, 4));
        // Else the first that stays inside and off the other figures; else its own side.
        const box = boxes.find(clear) ?? boxes.find((one) => inside(one) && !placed.some((other) => overlaps(one, other, 4))) ?? boxes[0];
        placed.push(box);
        pill.style.left = `${(box.x / width * 100).toFixed(2)}%`;
        pill.style.top = `${(box.y / height * 100).toFixed(2)}%`;
      }
    }
    new ResizeObserver(() => arrangeValues()).observe(scene);

    /// The conduits over the house, each lit and pulsing while power runs along it.
    function overlay(figures, has, { width, height, cables, markers }, simple) {
      const f = figures.flows;
      const point = ([x, y]) => `${(x * width).toFixed(1)},${(y * height).toFixed(1)}`;
      const top = Math.max(...Object.values(f), figures.home, 1);
      // A conduit and, when power runs along it, a pulse; `forward` is the conduit's drawn direction, toward the meter
      // or the inverter. `tone` colours it by the source feeding it; `pulse` is the route the pulse runs, when longer.
      const cable = (role, points, value, forward, tone = role, pulse = points) => {
        if (!points?.length || !has(role)) return null;
        const on = value > 0.5;
        const line = points.map(point).join(" ");
        return svg("g", { class: `energy-cable tone-${tones[tone]}${on ? " on" : ""}` },
          svg("polyline", { points: line, class: "energy-cable-halo" }),
          svg("polyline", { points: line, class: "energy-cable-line" }),
          on ? svg("polyline", { points: pulse.map(point).join(" "), pathLength: 100, class: `energy-pulse${forward ? "" : " back"}`,
            style: `--duration: ${(3.2 - Math.min(1, value / top) * 2.1).toFixed(2)}s` }) : null);
      };
      if (markers) {
        // A personal photo has no invented room circuit. Every route begins at the equipment the user marked.
        const routes = [["solar", "home", f.sh], ["battery", "home", f.bh], ["grid", "home", f.gh],
          ["solar", "battery", f.sb], ["grid", "battery", f.gb], ["solar", "grid", f.sg]];
        return svg("svg", { viewBox: `0 0 ${width} ${height}`, class: "energy-house-lines", "aria-hidden": "true" },
          routes.filter(([from, to, value]) => has(from) && has(to) && value > 0.5).map(([from, to, value]) => {
            const a = markers[from], b = markers[to];
            return cable(from, [a, [a[0], (a[1] + b[1]) / 2], [b[0], (a[1] + b[1]) / 2], b], value, true);
          }));
      }
      // Each room circuit is coloured by what feeds the home, in proportion along its length; on the main circuit, the
      // pulse of solar or the battery starts at its device. The board feeds in from the grid's end of the circuit.
      const fed = supplies(f, has).filter(([, value]) => value > 0);
      const supplied = fed.reduce((sum, [, value]) => sum + value, 0);
      const homeCable = (points, gridAtEnd = false) => {
        if (!points?.length || !has("home")) return null;
        if (!supplied) return cable("home", points, figures.home, true);
        const order = gridAtEnd ? fed : [...fed].sort((a, b) => Number(b[0] === "grid") - Number(a[0] === "grid"));
        const lengths = points.slice(1).map((p, i) => Math.hypot((p[0] - points[i][0]) * width, (p[1] - points[i][1]) * height));
        const total = lengths.reduce((sum, length) => sum + length, 0);
        if (!total) return null;
        // The points of the circuit from `from` to `to`, distances along it.
        const section = (from, to) => {
          let travelled = 0;
          const result = [];
          lengths.forEach((length, i) => {
            const end = travelled + length;
            if (length > 0 && end > from && travelled < to) {
              const at = (distance) => points[i].map((v, axis) => v + (points[i + 1][axis] - v) * (distance - travelled) / length);
              if (!result.length) result.push(at(Math.max(from, travelled)));
              result.push(at(Math.min(to, end)));
            }
            travelled = end;
          });
          return result;
        };
        let offset = 0;
        return svg("g", { class: "energy-home-wiring" }, order.map(([role, value], index) => {
          const end = index === order.length - 1 ? total : offset + total * value / supplied;
          const segment = section(offset, end);
          offset = end;
          const fromDevice = points === cables.home && role !== "grid" && cables[role];
          return cable("home", segment, figures.home, !(role === "grid" && gridAtEnd), role, fromDevice ? [...cables[role], ...section(0, end)] : segment);
        }));
      };
      return svg("svg", { viewBox: `0 0 ${width} ${height}`, class: "energy-house-lines", "aria-hidden": "true" },
        cable("solar", cables.solar, f.sh + f.sb + f.sg, true),
        homeCable(cables.home, !simple),
        homeCable(cables.homeUpper),
        homeCable(cables.homeLower, !simple),
        cable("battery", cables.battery, figures.discharge || figures.charge, figures.discharge > 0),
        cable("grid", cables.meter, figures.imported || figures.exported, figures.exported > 0),
        cable("grid", cables.grid, figures.imported || figures.exported, figures.exported > 0));
    }

    // The diagram -----------------------------------------------------------------------------------------------------------

    const at = { solar: [180, 62], grid: [48, 152], home: [312, 152], battery: [180, 244] }, radius = 40;
    const paths = {
      sh: "M202 96 C214 140 246 144 272 144", sg: "M158 96 C146 140 114 144 88 144", sb: "M180 102 L180 204",
      gh: "M88 152 L272 152", gb: "M88 160 C114 160 146 164 158 208", bh: "M202 208 C214 164 246 160 272 160",
    };
    const ends = { sh: ["solar", "home"], sg: ["solar", "grid"], sb: ["solar", "battery"], gh: ["grid", "home"], gb: ["grid", "battery"], bh: ["battery", "home"] };
    /// What the diagram shows, its figures as written: drawn again only when this changes, so its dots keep their pace.
    const diagramKey = (figures, has, live) => {
      const amount = live ? format.watts : format.kWh;
      return [...Object.values(figures.flows), figures.solar, figures.home, figures.imported, figures.exported, figures.charge, figures.discharge]
        .map((value) => amount(value)).concat(state.span, figures.level, report.roles).join();
    };

    function diagram(figures, has, amount, live) {
      const f = figures.flows;
      const top = Math.max(...Object.values(f), 0.001);
      const motion = !reduced();
      const lines = Object.entries(paths).map(([key, d]) => {
        const [a, b] = ends[key];
        if (!has(a) || !has(b)) return null;
        const on = f[key] > (live ? 0.5 : 0.0005);
        const share = Math.min(1, f[key] / top);
        const count = on && motion ? Math.max(1, Math.round(1 + share * 3)) : 0;
        const duration = 3.6 - share * 2.2;
        return svg("g", { class: `energy-line tone-${tones[a]}${on ? " on" : ""}` }, svg("path", { d }),
          [...Array(count)].map((_, i) => svg("circle", { r: (2.6 + share * 1.6).toFixed(1), class: "energy-dot" },
            svg("animateMotion", { dur: `${duration.toFixed(2)}s`, begin: `${(-i * duration / count).toFixed(2)}s`, repeatCount: "indefinite", path: d }))));
      });
      const circle = (role, lines, caption, captionAbove) => {
        if (!has(role)) return null;
        const [x, y] = at[role];
        const glyph = icon(icons[role]);
        for (const [key, value] of Object.entries({ x: x - 8, y: y - (lines.length === 1 ? 24 : 30), width: 16, height: 16, class: "energy-node-icon" })) glyph.setAttribute(key, value);
        return svg("g", { class: `energy-node tone-${tones[role]}` },
          svg("circle", { cx: x, cy: y, r: radius }),
          glyph,
          lines.map((line, index) => svg("text", { x, y: y + (lines.length === 1 ? 5 : index ? 15 : 0), class: index && lines.length > 1 ? "small" : "" }, line)),
          svg("text", { x, y: captionAbove ? y - radius - 12 : y + radius + 16, class: "caption" }, caption));
      };
      // The home's ring: the share of its use each source covered.
      const ring = [];
      if (has("home") && figures.home > 0) {
        const [x, y] = at.home, length = 2 * Math.PI * radius;
        let offset = 0;
        for (const [role, value] of supplies(f, has)) {
          const part = Math.min(1, value / figures.home) * length;
          if (part < 0.5) continue;
          ring.push(svg("circle", { cx: x, cy: y, r: radius, class: `energy-ring tone-${tones[role]}`, "stroke-dasharray": `${part.toFixed(1)} ${(length - part).toFixed(1)}`,
            "stroke-dashoffset": (-offset).toFixed(1), transform: `rotate(-90 ${x} ${y})` }));
          offset += part;
        }
      }
      const summary = [has("solar") ? `${t("Solar")} ${amount(figures.solar)}` : null, has("home") ? `${t("Home [use]")} ${amount(figures.home)}` : null,
        has("grid") ? `${t("Grid import")} ${amount(figures.imported)}, ${t("Grid export")} ${amount(figures.exported)}` : null,
        has("battery") ? `${t("Battery charged")} ${amount(figures.charge)}, ${t("Battery discharged")} ${amount(figures.discharge)}` : null].filter(Boolean).join(", ");
      // Framed to the parts the home has: a grid meter alone is two circles side by side, not a cross with holes.
      const shownAt = Object.entries(at).filter(([role]) => has(role)).map(([, point]) => point);
      const left = Math.min(...shownAt.map(([x]) => x)) - radius - 14, right = Math.max(...shownAt.map(([x]) => x)) + radius + 14;
      const topEdge = Math.min(...shownAt.map(([, y]) => y)) - radius - (has("solar") ? 24 : 8), bottom = Math.max(...shownAt.map(([, y]) => y)) + radius + 26;
      return svg("svg", { viewBox: `${left} ${topEdge} ${right - left} ${bottom - topEdge}`, class: "energy-diagram", role: "img", "aria-label": summary },
        lines,
        circle("solar", [amount(figures.solar)], t("Solar"), true),
        circle("grid", [`← ${amount(figures.exported)}`, `→ ${amount(figures.imported)}`], t("Grid")),
        circle("battery", [`↓ ${amount(figures.charge)}`, `↑ ${amount(figures.discharge)}`], [t("Battery"), figures.level != null ? format.percent(figures.level) : null].filter(Boolean).join(" · ")),
        circle("home", [amount(figures.home)], t("Home [use]")),
        ring);
    }

    // Live: the last few minutes, asked every ten seconds while the card is on screen and the tab visible. The bridge
    // records each minute's average and counts the minute under way, so the figures follow within seconds.
    let live = null, following = null, asking = false;
    async function follow() {
      // One round at a time: a report arriving while one is asked waits for it rather than starting another.
      if (asking) return;
      clearTimeout(following);
      // A version of the card the page does not show (a section removed in the edit mode) asks nothing; the next
      // report (`update`) starts it again.
      if (!node.isConnected || document.hidden || !node.checkVisibility()) return;
      asking = true;
      const to = new Date(), from = new Date(to - 3 * 60000);
      try {
        const next = await api(`/api/metrics/energy?${new URLSearchParams({ from: from.toISOString(), to: to.toISOString(), timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone })}`);
        live = gridAlone(next);
        if (report && !node.hidden && (state.view === "house" || state.span === "now")) draw();
      } catch {}
      asking = false;
      if (node.isConnected) following = setTimeout(follow, 10000);
    }
    // A hidden tab stops asking; coming back asks at once. The listener goes with the card.
    const wake = () => {
      if (!node.isConnected) { document.removeEventListener("visibilitychange", wake); return; }
      if (!document.hidden) follow();
    };
    document.addEventListener("visibilitychange", wake);

    return {
      node,
      /// Draws the report's latest reading or today again; hidden without the home's, solar's or the grid's power.
      update(next) {
        report = gridAlone(next);
        node.hidden = !["home", "solar", "grid"].some((role) => next.roles.includes(role));
        if (!node.hidden) { draw(); follow(); }
      },
    };
  }

  /// The home battery's units with their latest level: those whose device has the home's battery power too (`home`), a
  /// portable power station left out; every battery when none says so. The house's charge and the Status page's tile.
  function homeLevels(levels = []) {
    const ofHome = levels.filter((one) => one.home);
    return (ofHome.length ? ofHome : levels).map((one) => ({ device: one.device, level: one.points.at(-1)?.[1] })).filter((one) => one.level != null);
  }

  window.HomeswiftEnergyFlow = { card, split, solarPanels, homeLevels };
})();
