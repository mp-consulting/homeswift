// The Status page's Energy flow card: where the home's power comes from and goes, two ways. The house: a rendered
// cutaway (Scripts/energy-house.py; its layout file says where the parts and conduits land in the image) with the
// latest reading's power running along the conduits and a callout per part. The diagram: solar, the grid, the battery
// and the home as circles, dots running between them, either now (the latest reading, in watts) or today (the day's
// energy so far, split the way the Energy by day bars split it). Motion only says something: how much power a line
// carries (more dots, faster) and which way; with reduced motion the lines stay still and the figures say it all.
(() => {
  "use strict";

  const { t } = HomeswiftI18n;
  const { el, tile, icon } = HomeswiftCommon;
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
    const node = el("div", { class: "card chart-card energy-flow" },
      el("div", { class: "chart-head" }, tile("house", "blue"), el("div", { class: "who" }, el("strong", { text: t("Energy flow") }), note)),
      el("div", { class: "energy-flow-bar" }, views.node, spans.node),
      body);
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
      if (view === "house") house(figures, has, amount, when);
      else diagram(figures, has, amount, live);
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

    async function house(figures, has, amount, when) {
      const name = has("battery") ? "energy-house" : "energy-house-no-battery";
      const night = isNight(figures, has, when);
      let layout = layouts.get(name);
      if (!layout) {
        try { layout = await (await fetch(`/${name}.json`)).json(); } catch { layout = null; }
        if (!layout) { body.replaceChildren(el("p", { class: "muted", text: t("The house could not be loaded.") })); return; }
        layouts.set(name, layout);
      }
      if (view !== "house") return;
      const { width, height, anchors, cables } = layout;
      const f = figures.flows;
      const point = ([x, y]) => `${(x * width).toFixed(1)},${(y * height).toFixed(1)}`;
      const top = Math.max(...Object.values(f), figures.home, 1);
      // A conduit and, when power runs along it, a pulse; `forward` is the conduit's drawn direction, toward the meter
      // or the inverter.
      const cable = (role, points, value, forward) => {
        if (!points || !has(role)) return null;
        const on = value > 0.5;
        const share = Math.min(1, value / top);
        const line = points.map(point).join(" ");
        return svg("g", { class: `energy-cable tone-${tones[role]}${on ? " on" : ""}` },
          svg("polyline", { points: line, class: "energy-cable-halo" }),
          svg("polyline", { points: line, class: "energy-cable-line" }),
          on ? svg("polyline", { points: line, pathLength: 100, class: `energy-pulse${forward ? "" : " back"}`, style: `--duration: ${(3.2 - share * 2.1).toFixed(2)}s` }) : null);
      };
      const solarOut = f.sh + f.sb + f.sg;
      const overlay = svg("svg", { viewBox: `0 0 ${width} ${height}`, class: "energy-house-lines", "aria-hidden": "true" },
        cable("solar", cables.solar, solarOut, true),
        cable("battery", cables.battery, figures.discharge || figures.charge, figures.discharge > 0),
        cable("grid", cables.meter, figures.imported || figures.exported, figures.exported > 0),
        cable("grid", cables.grid, figures.imported || figures.exported, figures.exported > 0));
      // Callouts: the figure and what it is, one in each corner clear of the house, a hairline from there to its part
      // ending on a dot. `at` is where the hairline starts; the words sit beside it, after it (`start`) or before it (`end`).
      const leaders = [], placed = [];
      const callout = (role, anchor, value, label, at, side) => {
        if (!anchor || !has(role)) return null;
        const [x, y] = at;
        // A light halo under the hairline, so it reads on the lawn as on the card.
        const ends = { x1: x * width, y1: y * height, x2: anchor[0] * width, y2: anchor[1] * height };
        const line = [svg("line", { ...ends, class: "halo" }), svg("line", ends)];
        leaders.push(svg("g", { class: `energy-leader tone-${tones[role]}` }, ...line,
          svg("circle", { cx: anchor[0] * width, cy: anchor[1] * height, r: 12 })));
        const node = el("div", { class: `energy-callout ${side}`, style: `left: ${(x * 100).toFixed(2)}%; top: ${(y * 100).toFixed(2)}%` },
          el("b", {}, el("span", { class: `energy-callout-icon tone-${tones[role]}`, "aria-hidden": "true" }, icon(icons[role])), value),
          el("span", { text: label }));
        placed.push({ node, line, side, tip: anchor });
        return node;
      };
      // At a narrow width a label could run past the card: it moves in.
      const fit = (frame) => {
        const outer = frame.getBoundingClientRect();
        if (!outer.width) return;
        const scale = width / outer.width;
        for (const one of placed) {
          one.node.style.marginLeft = "";
          const box = one.node.getBoundingClientRect();
          const shift = box.left < outer.left ? outer.left - box.left : box.right > outer.right ? outer.right - box.right : 0;
          if (shift) one.node.style.marginLeft = `${shift}px`;
          // The hairline leaves the label at its point nearest the part, a little away from it, never across its words.
          const moved = one.node.getBoundingClientRect();
          const tipX = one.tip[0] * outer.width + outer.left, tipY = one.tip[1] * outer.height + outer.top;
          const x = Math.min(Math.max(tipX, moved.left), moved.right), y = Math.min(Math.max(tipY, moved.top - 4), moved.bottom + 4);
          for (const line of one.line) {
            line.setAttribute("x1", ((x - outer.left) * scale).toFixed(1));
            line.setAttribute("y1", ((y - outer.top) * scale).toFixed(1));
          }
        }
      };
      const gridLabel = figures.exported > 0.5 ? t("To the grid") : figures.imported > 0.5 ? t("From the grid") : t("Grid");
      const batteryLabel = [figures.charge > 0.5 ? t("Charging") : figures.discharge > 0.5 ? t("Discharging") : t("Battery"),
        figures.level != null ? format.percent(figures.level) : null].filter(Boolean).join(" · ");
      const image = el("img", { src: `/${name}${night ? "-night" : ""}.webp`, alt: "", decoding: "async", width, height });
      const summary = [has("solar") ? `${t("Solar")} ${amount(solarOut)}` : null, has("home") ? `${t("Home [use]")} ${amount(figures.home)}` : null,
        has("grid") ? `${gridLabel} ${amount(figures.imported || figures.exported)}` : null,
        has("battery") ? `${batteryLabel} ${amount(figures.charge || figures.discharge)}` : null].filter(Boolean).join(", ");
      const frame = el("div", { class: "energy-house", role: "img", "aria-label": summary, style: `aspect-ratio: ${width} / ${height}` },
        ...(() => {
          const nodes = [
            callout("solar", anchors.solar, amount(solarOut), t("Solar"), [0.2, 0.1], "end"),
            callout("grid", anchors.grid, amount(figures.imported || figures.exported), gridLabel, [0.8, 0.1], "start"),
            callout("home", anchors.home, amount(figures.home), t("Home [use]"), [0.2, 0.84], "end"),
            callout("battery", anchors.battery, amount(figures.charge || figures.discharge), batteryLabel, [0.8, 0.86], "start"),
          ];
          overlay.prepend(...leaders);
          return [image, sky(night), overlay, ...nodes];
        })());
      // The house appears whole: its picture decoded first (a later reading or a change of view goes on without it).
      await image.decode().catch(() => {});
      if (view !== "house") return;
      body.replaceChildren(frame);
      new ResizeObserver(() => fit(frame)).observe(frame);
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
      body.replaceChildren(svg("svg", { viewBox: "0 0 360 306", class: "energy-diagram", role: "img", "aria-label": summary },
        lines,
        circle("solar", [amount(figures.solar)], t("Solar"), true),
        circle("grid", both(figures.exported, figures.imported), gridCaption),
        circle("battery", [`↓ ${amount(figures.charge)}`, `↑ ${amount(figures.discharge)}`], batteryCaption),
        circle("home", [amount(figures.home)], t("Home [use]")),
        ring));
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
