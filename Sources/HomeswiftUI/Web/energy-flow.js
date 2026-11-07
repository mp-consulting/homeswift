// The Status page's Energy flow card: where the home's power comes from and goes, two ways. The house: a rendered
// cutaway (its layout file says where the parts and conduits land in the image) with the
// latest reading's power running along the conduits and a callout per part. The diagram: solar, the grid, the battery
// and the home as circles, dots running between them, either now (the latest reading, in watts) or today (the day's
// energy so far, split the way the Energy by day bars split it). Motion only says something: how much power a line
// carries (more dots, faster) and which way; with reduced motion the lines stay still and the figures say it all.
(() => {
  "use strict";

  const { t } = HomeswiftI18n;
  const { el, tile, icon, api } = HomeswiftCommon;
  const ns = "http://www.w3.org/2000/svg";
  const svg = (tag, attrs = {}, ...children) => {
    const node = document.createElementNS(ns, tag);
    for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
    node.append(...children.flat().filter((child) => child != null));
    return node;
  };
  const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  const storageKey = "homeswift.energy-flow";
  const remembered = () => { try { return JSON.parse(localStorage.getItem(storageKey) || "{}"); } catch { return {}; } };
  const remember = (value) => { try { localStorage.setItem(storageKey, JSON.stringify({ ...remembered(), ...value })); } catch {} };
  // The charts' slots: solar yellow, the home blue, the battery aqua, the grid violet.
  const tones = { solar: 4, home: 1, battery: 3, grid: 7 };
  // Each part's icon, as the Today figures draw it.
  const icons = { solar: "sun", home: "house", battery: "battery", grid: "pylon" };

  /// Where the home's energy came from and where solar's went, from totals or one reading alike (all zero or above):
  /// solar covers the home first, then charges the battery, the rest is exported; the battery covers what solar did
  /// not, the grid the rest; what charged the battery and solar did not give came from the grid.
  function split({ solar = 0, home = 0, charge = 0, discharge = 0, exported = null, homeFromSolar = null }) {
    const sh = Math.max(0, Math.min(homeFromSolar ?? Math.min(solar, home), home));
    const rest = Math.max(0, home - sh);
    const bh = Math.min(discharge, rest);
    const gh = Math.max(0, rest - bh);
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
    return { ...figures, flows: split({ ...figures, exported: grid == null ? null : figures.exported }) };
  }

  /// The day so far, in kWh.
  function fromDay(day) {
    const figures = {
      solar: day?.solar ?? 0, home: day?.home ?? 0, imported: day?.gridImport ?? 0, exported: day?.gridExport ?? 0,
      charge: day?.batteryCharge ?? 0, discharge: day?.batteryDischarge ?? 0, level: null,
    };
    return { ...figures, flows: split({ ...figures, homeFromSolar: day?.homeFromSolar ?? null }) };
  }

  /// The card. `format` has `watts`, `kWh` and `percent`. `update(report)` takes the Energy section's report: its roles,
  /// its power points and levels, and today.
  function card(format) {
    const saved = remembered();
    let view = saved.view === "diagram" ? "diagram" : "house";
    let span = saved.span === "today" ? "today" : "now";
    let report = null;
    const note = el("div", { class: "muted" });
    const radio = (label, options, current, choose) => {
      const buttons = options.map(([value, text, icon]) => el("button", { type: "button", role: "radio", actionIcon: icon, onclick: () => choose(value) }, el("span", { text })));
      const mark = (now) => buttons.forEach((button, index) => {
        button.classList.toggle("on", options[index][0] === now);
        button.setAttribute("aria-checked", String(options[index][0] === now));
      });
      mark(current);
      return { node: el("div", { class: "group", role: "radiogroup", "aria-label": label }, buttons), mark };
    };
    const views = radio(t("View"), [["house", t("House"), "house"], ["diagram", t("Diagram"), "chart"]], view, (value) => {
      view = value;
      remember({ view });
      views.mark(view);
      draw();
    });
    const spans = radio(t("Period"), [["now", t("Now"), "bolt"], ["today", t("Today"), "history"]], span, (value) => {
      span = value;
      remember({ span });
      spans.mark(span);
      draw();
    });
    const body = el("div", { class: "energy-flow-body" });
    const day = el("div", { class: "energy-day" });
    const devices = el("div", { class: "energy-devices", hidden: true });
    const heading = el("div", { class: "chart-head" }, tile("house", "blue"), el("div", { class: "who" }, el("strong", { text: t("Energy flow") }), note));
    const toolbar = el("div", { class: "energy-flow-bar" }, views.node);
    const node = el("div", { class: "card chart-card energy-flow" }, heading, toolbar, body, devices, day);
    const standardHeader = () => {
      node.classList.remove("image-first");
      node.insertBefore(heading, body);
      node.insertBefore(toolbar, body);
    };
    const layouts = new Map();   // the house's layout files, by image

    function draw() {
      if (!report) return;
      spans.node.hidden = view === "house";
      const has = (role) => report.roles.includes(role);
      const last = report.power.findLast((point) => !point.imported);
      const level = report.levels.length
        ? report.levels.map((one) => one.points.at(-1)?.[1]).filter((value) => value != null).reduce((sum, value, _, all) => sum + value / all.length, 0)
        : null;
      const live = view === "house" || span === "now";
      if (live && !last) {
        standardHeader();
        note.textContent = t("No reading yet");
        body.replaceChildren(el("p", { class: "muted energy-flow-empty", text: t("The flow appears with the first reading.") }));
        return;
      }
      const figures = live ? fromReading(last, level) : fromDay(report.days[0]);
      const when = new Date(last?.t * 1000);
      note.textContent = live
        ? (Date.now() - when > 10 * 60000 ? t("Reading of {time}", { time: when.toLocaleString(HomeswiftI18n.locale, { weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false }) }) : t("The latest reading"))
        : t("Today so far");
      const amount = live ? format.watts : format.kWh;
      house(figures, has, amount, when, live);
      phases(has);
      appliances();
    }

    // The appliances ---------------------------------------------------------------------------------------------------------

    /// An appliance's icon, guessed from its name; a plug otherwise.
    const applianceIcon = (name) => [[/\b(tv|t[ée]l[ée]|television|fernseh)/i, "tv"], [/(light|lamp|lampe|bulb|ampoule|luz|l[âa]mpada)/i, "bulb"],
      [/(fan|ventil|air|clim|cool|a\/c)/i, "fan"], [/(heat|boiler|chauff|radiat|calef|aquec|thermo)/i, "thermo"],
      [/(wash|dish|lave|lava|s[èe]che|dry)/i, "drop"], [/(vacuum|aspir|robot)/i, "vacuum"], [/(car|ev\b|charg|wallbox|borne|tesla)/i, "bolt"],
      [/(speaker|sonos|enceinte|altavoz)/i, "speaker"]].find(([pattern]) => pattern.test(name))?.[1] ?? "outlet";
    let devicesAsked = 0;

    /// Under the view, the devices measured on their own (Meters of no role) that used the most today, each with its kWh
    /// and its share of the home's; asked of the bridge at most once a minute, hidden without any.
    async function appliances() {
      if (!report.roles.includes("home") || Date.now() - devicesAsked < 55000) return;
      devicesAsked = Date.now();
      const midnight = new Date(); midnight.setHours(0, 0, 0, 0);
      let found;
      try {
        found = await api(`/api/metrics/consumption?${new URLSearchParams({ hours: ((Date.now() - midnight) / 36e5).toFixed(3), kind: "electricity",
          timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone })}`);
      } catch { devices.hidden = true; return; }
      const top = (found.meters ?? []).filter((one) => !one.role && (one.kind ?? "electricity") === "electricity" && one.consumption > 0).sort((a, b) => b.consumption - a.consumption).slice(0, 6);
      devices.hidden = !top.length;
      if (!top.length) return;
      const home = report.days[0]?.home ?? null;
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

    /// Under either view, today midnight to midnight: for each reading, the source that covered most of the home's use
    /// (solar, the battery or the grid, split as the flows are), runs of the same source joined, a marker at now. Hidden
    /// without the home's use or without a reading today.
    function phases(has) {
      const start = new Date(); start.setHours(0, 0, 0, 0);
      const end = new Date(start); end.setDate(end.getDate() + 1);
      const points = has("home") ? report.power.filter((point) => point.t * 1000 >= start.getTime() && point.t * 1000 < end.getTime()) : [];
      day.hidden = points.length < 2;
      if (day.hidden) return;
      const runs = [];
      const step = (report.step || 60) * 1000;
      for (const point of points) {
        const f = fromReading(point, null).flows;
        const source = [["solar", f.sh], ["battery", f.bh], ["grid", f.gh]].filter(([role]) => has(role)).sort((a, b) => b[1] - a[1])[0];
        const role = source && source[1] > 0 ? source[0] : null;
        const from = point.t * 1000, to = Math.min(from + step, end.getTime());
        const last = runs.at(-1);
        if (last && last.role === role && from - last.to <= step * 1.5) last.to = to;
        else runs.push({ role, from, to });
      }
      const span = end - start;
      const time = (ms) => new Date(ms).toLocaleTimeString(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit", hour12: false });
      const labels = { solar: t("Solar"), battery: t("Battery"), grid: t("Grid") };
      const shown = runs.filter((run) => run.role);
      const bar = el("div", { class: "energy-day-bar", role: "img",
        "aria-label": `${t("What powered the home today")}: ${shown.map((run) => `${labels[run.role]} ${time(run.from)}–${time(run.to)}`).join(", ")}` },
        shown.map((run) => el("i", { class: `tone-${tones[run.role]}`, title: `${labels[run.role]} ${time(run.from)}–${time(run.to)}`,
          style: `left: ${((run.from - start) / span * 100).toFixed(3)}%; width: ${((run.to - run.from) / span * 100).toFixed(3)}%` })),
        Date.now() < end.getTime() ? el("b", { class: "energy-day-now", style: `left: ${((Date.now() - start) / span * 100).toFixed(2)}%`, "aria-hidden": "true" }) : null);
      // The hours under it, and each source's share of the day, its colour's key beside it.
      const hours = el("div", { class: "energy-day-hours", "aria-hidden": "true" }, [0, 6, 12, 18, 24].map((hour) => el("span", { text: `${String(hour).padStart(2, "0")}:00` })));
      const total = shown.reduce((sum, run) => sum + (run.to - run.from), 0) || 1;
      const keys = el("div", { class: "energy-day-keys" }, ["solar", "battery", "grid"].filter((role) => has(role)).map((role) => {
        const share = shown.filter((run) => run.role === role).reduce((sum, run) => sum + (run.to - run.from), 0) / total * 100;
        return el("span", {}, el("i", { class: `key bar tone-${tones[role]}`, "aria-hidden": "true" }), labels[role], el("b", { text: format.percent(share) }));
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
    // The sun or the moon over the house, drawn in the page's colours.
    const sky = (night) => {
      const glyph = night
        ? svg("svg", { viewBox: "0 0 48 48" }, svg("path", { d: "M30 6a18 18 0 1 0 12 30A15 15 0 0 1 30 6z", class: "moon" }))
        : svg("svg", { viewBox: "0 0 48 48" }, svg("circle", { cx: 24, cy: 24, r: 9, class: "sun" }),
          [...Array(8)].map((_, i) => svg("line", { x1: 24, y1: 6, x2: 24, y2: 11, class: "ray", transform: `rotate(${i * 45} 24 24)` })));
      return el("div", { class: `energy-sky${night ? " night" : ""}`, "aria-hidden": "true" }, glyph);
    };

    let houseVersion = 0;
    async function house(figures, has, amount, when, live) {
      const renderedView = view, version = ++houseVersion;
      const simple = HomeswiftCommon.preferences().energyHouseStyle === "simple";
      const name = `energy-house${simple ? "-simple" : ""}${has("battery") ? "" : "-no-battery"}`;
      const night = isNight(figures, has, when);
      let layout = layouts.get(name);
      if (!layout) {
        try { layout = await (await fetch(`/${name}.json`)).json(); } catch { layout = null; }
        if (!layout) { standardHeader(); body.replaceChildren(el("p", { class: "muted", text: t("The house could not be loaded.") })); return; }
        layouts.set(name, layout);
      }
      if (view !== renderedView || version !== houseVersion) return;
      const { width, height, anchors, cables } = layout;
      const f = figures.flows;
      const point = ([x, y]) => `${(x * width).toFixed(1)},${(y * height).toFixed(1)}`;
      const top = Math.max(...Object.values(f), figures.home, 1);
      // A conduit and, when power runs along it, a pulse; `forward` is the conduit's drawn direction, toward the meter
      // or the inverter.
      const cable = (role, points, value, forward, colorRole = role, pulsePoints = points) => {
        if (!points || !has(role)) return null;
        const on = value > 0.5;
        const share = Math.min(1, value / top);
        const line = points.map(point).join(" ");
        return svg("g", { class: `energy-cable tone-${tones[colorRole]}${on ? " on" : ""}`, "data-energy-role": role },
          svg("polyline", { points: line, class: "energy-cable-halo" }),
          svg("polyline", { points: line, class: "energy-cable-line" }),
          on ? svg("polyline", { points: pulsePoints.map(point).join(" "), pathLength: 100, class: `energy-pulse${forward ? "" : " back"}`, style: `--duration: ${(3.2 - share * 2.1).toFixed(2)}s` }) : null);
      };
      const solarOut = f.sh + f.sb + f.sg;
      // Split every room circuit by actual supplied power, measured along the path in image pixels.
      // Each source keeps its own colour and pulse; charging/exported power is not part of this split.
      const homeSources = [["solar", f.sh], ["battery", f.bh], ["grid", f.gh]]
        .filter(([role, value]) => has(role) && value > 0);
      const supplied = homeSources.reduce((sum, [, value]) => sum + value, 0);
      const homeCable = (points, gridAtEnd = false) => {
        // On the main circuit, a source's pulse begins at its device and travels through the inverter.
        // The coloured room sections still show their proportional shares; branch pulses continue at junctions.
        const fromSource = (role, route) => points === cables.home && (role === "battery" || role === "solar") && cables[role]
          ? [...cables[role], ...route] : route;
        if (!points || !has("home")) return null;
        if (homeSources.length < 2 || !supplied) {
          const role = homeSources[0]?.[0] || "home";
          return cable("home", points, figures.home, !(role === "grid" && gridAtEnd), role, fromSource(role, points));
        }
        // The board feeds into the circuit: on paths ending at the board, grid pulses travel backwards.
        // On branches beginning at a distribution junction, the grid segment starts there instead.
        const sources = gridAtEnd ? homeSources : [...homeSources].sort((a, b) => Number(b[0] === "grid") - Number(a[0] === "grid"));
        const lengths = points.slice(1).map((p, i) => Math.hypot((p[0] - points[i][0]) * width, (p[1] - points[i][1]) * height));
        const total = lengths.reduce((sum, length) => sum + length, 0);
        if (!total) return null;
        const section = (from, to) => {
          let travelled = 0;
          const result = [];
          for (let i = 0; i < lengths.length; i++) {
            const length = lengths[i], end = travelled + length;
            if (length > 0 && end > from && travelled < to) {
              const at = (distance) => points[i].map((v, axis) => v + (points[i + 1][axis] - v) * (distance - travelled) / length);
              if (!result.length) result.push(at(Math.max(from, travelled)));
              result.push(at(Math.min(to, end)));
            }
            travelled = end;
          }
          return result;
        };
        let offset = 0;
        return svg("g", { class: "energy-home-wiring" }, sources.map(([role, value], index) => {
          const end = index === sources.length - 1 ? total : offset + total * value / supplied;
          const segment = section(offset, end);
          const pulseRoute = points === cables.home && (role === "battery" || role === "solar") ? fromSource(role, section(0, end)) : segment;
          const node = cable("home", segment, figures.home, !(role === "grid" && gridAtEnd), role, pulseRoute);
          node.setAttribute("data-energy-source", role);
          node.setAttribute("data-energy-share", String(value / supplied));
          offset = end;
          return node;
        }));
      };
      const overlay = svg("svg", { viewBox: `0 0 ${width} ${height}`, class: "energy-house-lines", "aria-hidden": "true" },
        cable("solar", cables.solar, solarOut, true),
        homeCable(cables.home, !simple),
        homeCable(cables.homeUpper),
        homeCable(cables.homeLower, !simple),
        cable("battery", cables.battery, figures.discharge || figures.charge, figures.discharge > 0),
        cable("grid", cables.meter, figures.imported || figures.exported, figures.exported > 0),
        cable("grid", cables.grid, figures.imported || figures.exported, figures.exported > 0));
      // Readings sit in the raised panel below the image, sharing a badge and text-column layout.
      const callout = (role, anchor, value, label) => {
        if (!anchor || !has(role)) return null;
        return el("div", { class: "energy-callout start" },
          el("span", { class: `energy-callout-icon tone-${tones[role]}`, "aria-hidden": "true" }, icon(icons[role])),
          el("b", { text: value }), el("span", { class: "energy-callout-label", text: label }));
      };
      const gridLabel = figures.exported > 0.5 ? t("To the grid") : figures.imported > 0.5 ? t("From the grid") : t("Grid");
      const batteryLabel = [figures.charge > 0.5 ? t("Charging") : figures.discharge > 0.5 ? t("Discharging") : t("Battery"),
        figures.level != null ? format.percent(figures.level) : null].filter(Boolean).join(" · ");
      const image = el("img", { src: `/${name}${night ? "-night" : ""}.webp`, alt: "", decoding: "async", width, height });
      const summary = [has("solar") ? `${t("Solar")} ${amount(solarOut)}` : null, has("home") ? `${t("Home [use]")} ${amount(figures.home)}` : null,
        has("grid") ? `${gridLabel} ${amount(figures.imported || figures.exported)}` : null,
        has("battery") ? `${batteryLabel} ${amount(figures.charge || figures.discharge)}` : null].filter(Boolean).join(", ");
      const readingNodes = [];
      const frame = el("div", { class: `energy-house ${simple ? "simple" : "photo"}`, role: renderedView === "house" ? "img" : "group", "aria-label": summary, style: `aspect-ratio: ${width} / ${height}` },
        ...(() => {
          const nodes = [
            callout("solar", anchors.solar, amount(solarOut), t("Solar")),
            callout("grid", anchors.grid, amount(figures.imported || figures.exported), gridLabel),
            callout("home", anchors.home, amount(figures.home), t("Home [use]")),
            callout("battery", anchors.battery, amount(figures.charge || figures.discharge), batteryLabel),
          ];
          readingNodes.push(...nodes.filter(Boolean));
          return [el("div", { class: "energy-house-scene", style: `aspect-ratio: ${width} / ${height}` },
            renderedView === "house" ? [image, simple ? sky(night) : null, overlay] :
              el("div", { class: "energy-diagram-scene" }, el("div", { class: "energy-diagram-period" }, spans.node), diagram(figures, has, amount, live)))];
        })());
      // The house appears whole: its picture decoded first (a later reading or a change of view goes on without it).
      if (renderedView === "house") await image.decode().catch(() => {});
      if (view !== renderedView || version !== houseVersion) return;
      const supplies = [["solar", f.sh, t("Solar")], ["battery", f.bh, t("Battery")], ["grid", f.gh, t("Grid")]]
        .filter(([role]) => has(role));
      const shareSummary = supplies.map(([, value, label]) => `${label} ${format.percent(value / supplied * 100)}`).join(", ");
      const supply = supplied > 0.5 ? el("div", { class: "energy-supply" },
        el("strong", { text: t("Powering the home") }),
        el("div", { class: "energy-supply-bar", role: "img", "aria-label": `${t("Powering the home")}: ${shareSummary}` },
          supplies.filter(([, value]) => value > 0).map(([role, value]) => el("i", { class: `tone-${tones[role]}`, style: `width: ${value / supplied * 100}%` }))),
        el("div", { class: "energy-supply-shares" }, supplies.map(([role, value, label]) =>
          el("div", {}, el("span", { class: `energy-callout-icon tone-${tones[role]}`, "aria-hidden": "true" }, icon(icons[role])),
            el("span", { text: label }), el("b", { text: format.percent(value / supplied * 100) }),
            el("small", { text: amount(value) }))))) : null;
      const focused = node.contains(document.activeElement) ? document.activeElement : null;
      const scrollLeft = window.scrollX, scrollTop = window.scrollY;
      node.classList.add("image-first");
      body.replaceChildren(el("div", { class: "energy-house-story" }, frame,
        el("div", { class: "energy-house-details" },
          el("span", { class: "energy-house-badge", "aria-hidden": "true" }, icon("house")), el("div", { class: "energy-house-title-row" }, heading, toolbar),
          el("div", { class: "energy-house-readings" }, readingNodes), supply)));
      if (focused?.isConnected) focused.focus({ preventScroll: true });
      window.scrollTo({ left: scrollLeft, top: scrollTop, behavior: "instant" });
    }

    // The diagram -----------------------------------------------------------------------------------------------------------

    const at = { solar: [180, 62], grid: [48, 152], home: [312, 152], battery: [180, 244] }, radius = 40;
    const paths = {
      sh: "M202 96 C214 140 246 144 272 144", sg: "M158 96 C146 140 114 144 88 144", sb: "M180 102 L180 204",
      gh: "M88 152 L272 152", gb: "M88 160 C114 160 146 164 158 208", bh: "M202 208 C214 164 246 160 272 160",
    };
    const from = { sh: "solar", sg: "solar", sb: "solar", gh: "grid", gb: "grid", bh: "battery" };

    function diagram(figures, has, amount, live) {
      const f = figures.flows;
      const top = Math.max(...Object.values(f), 0.001);
      const motion = !reduced();
      const lines = Object.entries(paths).map(([key, d]) => {
        const [a, b] = [from[key], { sh: "home", sg: "grid", sb: "battery", gh: "home", gb: "battery", bh: "home" }[key]];
        if (!has(a) || !has(b)) return null;
        const value = f[key];
        const on = value > (live ? 0.5 : 0.0005);
        const share = Math.min(1, value / top);
        const dots = [];
        if (on && motion) {
          const count = Math.max(1, Math.round(1 + share * 3));
          const duration = 3.6 - share * 2.2;
          for (let i = 0; i < count; i++) {
            dots.push(svg("circle", { r: (2.6 + share * 1.6).toFixed(1), class: `energy-dot tone-${tones[from[key]]}` },
              svg("animateMotion", { dur: `${duration.toFixed(2)}s`, begin: `${(-i * duration / count).toFixed(2)}s`, repeatCount: "indefinite", path: d })));
          }
        }
        return svg("g", { class: `energy-line tone-${tones[from[key]]}${on ? " on" : ""}` }, svg("path", { d }), dots);
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
        const [x, y] = at.home, r = radius, length = 2 * Math.PI * r;
        let offset = 0;
        for (const [role, value] of [["solar", f.sh], ["battery", f.bh], ["grid", f.gh]]) {
          const part = Math.min(1, value / figures.home) * length;
          if (part < 0.5) continue;
          ring.push(svg("circle", { cx: x, cy: y, r, class: `energy-ring tone-${tones[role]}`, "stroke-dasharray": `${part.toFixed(1)} ${(length - part).toFixed(1)}`,
            "stroke-dashoffset": (-offset).toFixed(1), transform: `rotate(-90 ${x} ${y})` }));
          offset += part;
        }
      }
      const both = (out, back) => [`← ${amount(out)}`, `→ ${amount(back)}`];
      const gridCaption = t("Grid"), batteryCaption = [t("Battery"), figures.level != null ? format.percent(figures.level) : null].filter(Boolean).join(" · ");
      const summary = [has("solar") ? `${t("Solar")} ${amount(figures.solar)}` : null, has("home") ? `${t("Home [use]")} ${amount(figures.home)}` : null,
        has("grid") ? `${t("Grid import")} ${amount(figures.imported)}, ${t("Grid export")} ${amount(figures.exported)}` : null,
        has("battery") ? `${t("Battery charged")} ${amount(figures.charge)}, ${t("Battery discharged")} ${amount(figures.discharge)}` : null].filter(Boolean).join(", ");
      return svg("svg", { viewBox: "0 0 360 306", class: "energy-diagram", role: "img", "aria-label": summary },
        lines,
        circle("solar", [amount(figures.solar)], t("Solar"), true),
        circle("grid", both(figures.exported, figures.imported), gridCaption),
        circle("battery", [`↓ ${amount(figures.charge)}`, `↑ ${amount(figures.discharge)}`], batteryCaption),
        circle("home", [amount(figures.home)], t("Home [use]")),
        ring);
    }

    return {
      node,
      /// Draws the report's latest reading or today again; hidden without the home's, solar's or the grid's power.
      update(next) {
        report = next;
        node.hidden = !["home", "solar", "grid"].some((role) => next.roles.includes(role));
        if (!node.hidden) draw();
      },
    };
  }

  window.HomeswiftEnergyFlow = { card, split };
})();
