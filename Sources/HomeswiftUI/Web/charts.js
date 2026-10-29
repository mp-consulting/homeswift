// Line charts over time (and stacked bars, a bar per day) for the Status page: memory, CPU, request durations, energy. One axis each (below zero too,
// with a zero line, for a power that flows both ways), 2px lines, an area wash
// under a single series, a legend once there are two, hairline grid. A crosshair snaps to the nearest point and a
// tooltip lists every series there, on hover and with the arrow keys once the chart has focus. Points further apart
// than a step and a half leave a gap: nothing was recorded (homeswift was not running); a point without a value for a
// series (a minute without requests) is passed over without one. It redraws at its width.
(() => {
  "use strict";

  const { t, tn } = HomeswiftI18n;
  const ns = "http://www.w3.org/2000/svg";
  const svg = (tag, attrs = {}) => {
    const node = document.createElementNS(ns, tag);
    for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
    return node;
  };
  const html = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  };

  const height = 168, pad = { top: 10, right: 14, bottom: 24, left: 52 };

  /// The highest tick at or above `max`, over four steps of 1, 2, 2.5 or 5 times a power of ten of `unit` (bytes
  /// step in whole megabytes).
  function niceMax(max, unit = 1) {
    if (!(max > 0)) return unit;
    const raw = max / unit / 4;
    const power = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 2.5, 5, 10].map((m) => m * power).find((s) => s >= raw);
    return step * 4 * unit;
  }

  /// A round step at or above `raw`: 1, 2, 2.5 or 5 times a power of ten of `unit`.
  function niceStep(raw, unit = 1) {
    if (!(raw > 0)) return unit;
    const power = 10 ** Math.floor(Math.log10(raw / unit));
    return [1, 2, 2.5, 5, 10].map((m) => m * power).find((s) => s >= raw / unit) * unit;
  }

  /// Times along the x axis: whole minutes, hours or days, about `count` of them.
  function timeTicks(from, to, count) {
    const span = to - from;
    const steps = [60e3, 300e3, 900e3, 1800e3, 3600e3, 2 * 3600e3, 3 * 3600e3, 6 * 3600e3, 12 * 3600e3, 86400e3];
    const step = steps.find((s) => span / s <= count) ?? 86400e3;
    const first = new Date(Math.ceil(from / step) * step);
    // Day and half-day steps fall on local midnight and noon, not UTC's.
    if (step >= 12 * 3600e3) {
      const local = new Date(from);
      local.setHours(step >= 86400e3 ? 0 : Math.ceil(local.getHours() / 12) * 12, 0, 0, 0);
      if (local < from) local.setTime(local.getTime() + step);
      first.setTime(local.getTime());
    }
    const ticks = [];
    for (let tick = first.getTime(); tick <= to; tick += step) ticks.push(tick);
    return ticks;
  }
  /// The value axis's labels, highest last as `ticks` are ordered: the unit written once, on the top tick (`40 MB`, then
  /// `30`, `20`…), and a decimal every tick has as zeros dropped (`40.0 MB` reads `40 MB`). `format(value, scale)`
  /// writes a value with its unit after a space, or a sign glued to it (`%`).
  const decimal = (1.5).toLocaleString(HomeswiftI18n.locale).charAt(1);
  function axisLabels(ticks, format, scale) {
    let labels = ticks.map((value) => format(value, scale));
    const zeros = new RegExp(`\\${decimal}0+(?=\\D*$)`);
    if (labels.every((label) => zeros.test(label))) labels = labels.map((label) => label.replace(zeros, ""));
    const top = labels[ticks.indexOf(Math.max(...ticks))] ?? "";
    const unit = top.match(/\s?[^\d\s.,\u00a0\u202f-]+$/)?.[0];
    if (!unit) return labels;
    return labels.map((label, index) => ticks[index] === Math.max(...ticks) || !label.endsWith(unit) ? label : label.slice(0, -unit.length));
  }

  /// A tick's label: the day at midnight, else the time.
  const tickLabel = (time) => {
    const date = new Date(time);
    return date.getHours() === 0 && date.getMinutes() === 0 ? dayName.format(date) : hourMinute.format(date);
  };

  const hourMinute = new Intl.DateTimeFormat(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit", hour12: false });
  const dayName = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short", day: "numeric" });
  const fullTime = new Intl.DateTimeFormat(HomeswiftI18n.locale, { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false });

  /// A chart in `container`: `series` are `{ label, value(point), tone }` (tone 1 to 6, the palette's slots),
  /// `points` have `time` (a Date), `from` and `to` bound the x axis, `step` is the points' spacing in ms and
  /// `format` writes a value with its unit and `unit(max)` is the size of that unit, so ticks fall on round values
  /// of it. With `latest`, the legend writes each series' last value beside its name (a battery's level), so the
  /// chart needs no separate line of them. Returns `update(points, from, to, step)`.
  function lineChart(container, { title, series, format, unit = () => 1, points, from, to, step, latest = false }) {
    const frame = html("div", "chart-frame");
    const tooltip = html("div", "chart-tooltip hidden");
    tooltip.setAttribute("role", "status");
    frame.append(tooltip);
    container.append(frame);
    const latestNodes = [];
    if (series.length > 1) {
      const legend = html("div", "chart-legend");
      for (const one of series) {
        const item = html("span", "", null);
        item.append(html("i", `key tone-${one.tone}`), document.createTextNode(one.label));
        if (latest) { const value = html("b", "legend-value"); latestNodes.push(value); item.append(value); }
        legend.append(item);
      }
      container.append(legend);
    }
    /// Each series' last value in the legend, a dash for one with none.
    const showLatest = (points) => latestNodes.forEach((node, index) => {
      const last = points.findLast((point) => series[index].value(point) != null);
      node.textContent = last ? format(series[index].value(last)) : "–";
    });
    let state = { points, from, to, step };
    let chosen = null;   // the index the crosshair is on, kept between redraws
    let drawn = null;

    function draw() {
      const width = Math.max(frame.clientWidth, 240);
      const { points, from, to, step } = state;
      const plotWidth = width - pad.left - pad.right, plotHeight = height - pad.top - pad.bottom;
      const values = points.flatMap((point) => series.map((one) => one.value(point))).filter((v) => v != null);
      const highest = Math.max(0, ...values), lowest = Math.min(0, ...values);
      // From zero to four round steps up; with values below zero, round steps from below the lowest to above the highest.
      let top = niceMax(highest, unit(highest)), bottom = 0, ticks = [0, 1, 2, 3, 4].map((i) => top / 4 * i);
      if (lowest < 0) {
        const size = Math.max(highest, -lowest);
        const step = niceStep((highest - lowest) / 4, unit(size));
        top = Math.max(step, Math.ceil(highest / step) * step);
        bottom = Math.floor(lowest / step) * step;
        ticks = [];
        for (let value = bottom; value <= top + step / 2; value += step) ticks.push(value);
      }
      const scale = Math.max(top, -bottom);
      const x = (time) => pad.left + (time - from) / Math.max(to - from, 1) * plotWidth;
      const y = (value) => pad.top + plotHeight - (value - bottom) / (top - bottom) * plotHeight;

      const root = svg("svg", { width, height, viewBox: `0 0 ${width} ${height}`, class: "chart", role: "img", "aria-label": points.length ? t("{title}, drawn over time", { title }) : t("{title}, nothing recorded", { title }) });
      root.setAttribute("tabindex", "0");
      const tickText = axisLabels(ticks, format, scale);
      ticks.forEach((value, index) => {
        const at = y(value);
        root.append(svg("line", { x1: pad.left, x2: width - pad.right, y1: at, y2: at, class: value === 0 && bottom < 0 ? "grid zero" : "grid" }));
        const label = svg("text", { x: pad.left - 8, y: at + 4, class: "tick", "text-anchor": "end" });
        label.textContent = tickText[index];
        root.append(label);
      });
      for (const tick of timeTicks(from, to, Math.max(2, Math.floor(plotWidth / 90)))) {
        const label = svg("text", { x: x(tick), y: height - 6, class: "tick", "text-anchor": "middle" });
        label.textContent = tickLabel(tick);
        root.append(label);
      }

      // A run of points closer than a step and a half to each other is drawn as one line.
      const runs = (one) => {
        const all = [];
        let run = [];
        let last = null;
        for (const point of points) {
          if (last != null && point.time - last > step * 1.5 && run.length) { all.push(run); run = []; }
          last = point.time;
          const value = one.value(point);
          if (value != null) run.push([x(point.time), y(value)]);
        }
        if (run.length) all.push(run);
        return all;
      };
      for (const one of series) {
        for (const run of runs(one)) {
          const line = run.map(([px, py], i) => `${i ? "L" : "M"}${px.toFixed(1)},${py.toFixed(1)}`).join("");
          if (series.length === 1 && run.length > 1) {
            const base = y(0).toFixed(1);
            root.append(svg("path", { d: `${line}L${run.at(-1)[0].toFixed(1)},${base}L${run[0][0].toFixed(1)},${base}Z`, class: `area tone-${one.tone}` }));
          }
          root.append(svg("path", { d: line, class: `line tone-${one.tone}` }));
          // A lone point (one recorded step between gaps) shows as a dot.
          if (run.length === 1) root.append(svg("circle", { cx: run[0][0], cy: run[0][1], r: 3, class: `dot tone-${one.tone}` }));
        }
        const end = [...points].reverse().find((point) => one.value(point) != null);
        if (end) root.append(svg("circle", { cx: x(end.time), cy: y(one.value(end)), r: 4, class: `dot tone-${one.tone}` }));
      }
      if (!points.length) {
        const empty = svg("text", { x: pad.left + plotWidth / 2, y: pad.top + plotHeight / 2, class: "tick", "text-anchor": "middle" });
        empty.textContent = t("Nothing recorded in this range");
        root.append(empty);
      }
      const cross = svg("line", { y1: pad.top, y2: pad.top + plotHeight, class: "crosshair hidden" });
      const marks = series.map((one) => svg("circle", { r: 4, class: `dot tone-${one.tone} hidden` }));
      root.append(cross, ...marks);
      frame.querySelector("svg")?.remove();
      frame.prepend(root);
      drawn = { x, y, root, cross, marks, plotWidth };

      const show = (index) => {
        chosen = index;
        if (index == null || !points[index]) {
          cross.classList.add("hidden");
          for (const mark of marks) mark.classList.add("hidden");
          tooltip.classList.add("hidden");
          return;
        }
        const point = points[index], px = x(point.time);
        cross.setAttribute("x1", px);
        cross.setAttribute("x2", px);
        cross.classList.remove("hidden");
        tooltip.replaceChildren(html("div", "chart-time", fullTime.format(point.time)));
        series.forEach((one, i) => {
          const value = one.value(point);
          marks[i].classList.toggle("hidden", value == null);
          if (value != null) { marks[i].setAttribute("cx", px); marks[i].setAttribute("cy", y(value)); }
          const row = html("div", "chart-row");
          row.append(html("i", `key tone-${one.tone}`), html("b", "", value == null ? "–" : format(value)), html("span", "muted", one.label));
          tooltip.append(row);
        });
        tooltip.classList.remove("hidden");
        // Beside the crosshair, on the side with room.
        const left = px + 12 + tooltip.offsetWidth > width ? px - 12 - tooltip.offsetWidth : px + 12;
        tooltip.style.left = `${Math.max(0, left)}px`;
      };
      const nearest = (clientX) => {
        if (!points.length) return null;
        const at = clientX - root.getBoundingClientRect().left;
        let best = 0;
        for (let i = 1; i < points.length; i++) if (Math.abs(x(points[i].time) - at) < Math.abs(x(points[best].time) - at)) best = i;
        return best;
      };
      root.addEventListener("pointermove", (event) => show(nearest(event.clientX)));
      root.addEventListener("pointerleave", () => { if (document.activeElement !== root) show(null); });
      root.addEventListener("blur", () => show(null));
      root.addEventListener("focus", () => show(chosen ?? (points.length ? points.length - 1 : null)));
      root.addEventListener("keydown", (event) => {
        if (!points.length) return;
        const moves = { ArrowLeft: -1, ArrowRight: 1, Home: -Infinity, End: Infinity };
        if (!(event.key in moves)) return;
        event.preventDefault();
        show(Math.min(points.length - 1, Math.max(0, (chosen ?? points.length - 1) + moves[event.key])));
      });
      if (chosen != null && chosen < points.length && document.activeElement === root) show(chosen);
    }

    // A page shown in its place takes the chart out of the document: it stops watching then.
    const resize = new ResizeObserver(() => {
      if (!frame.isConnected) { resize.disconnect(); return; }
      if (frame.clientWidth && Math.abs(frame.clientWidth - (drawn ? Number(drawn.root.getAttribute("width")) : 0)) > 1) draw();
    });
    resize.observe(frame);
    draw();
    showLatest(points);
    return {
      update(points, from, to, step) {
        state = { points, from, to, step };
        showLatest(points);
        chosen = null;
        tooltip.classList.add("hidden");
        draw();
      },
    };
  }

  /// Stacked bars in `container`, one per item of `bars` (`{ label, narrow, title, values, current }`, oldest first;
  /// `narrow` under a bar too narrow for its label, `current` the period of today, its label emphasised): `segments` are
  /// `{ label, tone, value(values) }`, stacked up from zero for a positive value and down for a negative one, so a bar
  /// can show what came in above the line and what went out below it. A value of null is not known: it draws nothing
  /// and the tooltip shows a dash, not a zero. `format` writes a value with its unit and
  /// `unit(max)` sizes the ticks, as for `lineChart`. A tooltip lists a bar's segments, on hover and with the arrow keys.
  /// Returns `update(bars)`.
  /// `legend` (`{ label, tone }`) names the colours when segments share one (an entity above and below the line).
  function stackedBars(container, { title, segments, bars, format, unit = () => 1, legend: keys = segments }) {
    const frame = html("div", "chart-frame");
    const tooltip = html("div", "chart-tooltip hidden");
    tooltip.setAttribute("role", "status");
    frame.append(tooltip);
    container.append(frame);
    const legend = html("div", "chart-legend");
    for (const one of keys) {
      const item = html("span", "", null);
      item.append(html("i", `key bar tone-${one.tone}`), document.createTextNode(one.label));
      legend.append(item);
    }
    container.append(legend);
    let state = bars;
    let chosen = null;
    let drawn = null;

    function draw() {
      const width = Math.max(frame.clientWidth, 240);
      const bars = state;
      const plotWidth = width - pad.left - pad.right, plotHeight = height - pad.top - pad.bottom;
      const known = bars.map((bar) => segments.map((one) => one.value(bar.values)));
      const sums = known.map((values) => values.map((value) => value ?? 0));
      const highest = Math.max(0, ...sums.map((list) => list.filter((v) => v > 0).reduce((a, b) => a + b, 0)));
      const lowest = Math.min(0, ...sums.map((list) => list.filter((v) => v < 0).reduce((a, b) => a + b, 0)));
      const size = Math.max(highest, -lowest);
      const step = niceStep((highest - lowest) / 5 || 1, unit(size));
      const top = Math.max(lowest < 0 ? 0 : step, Math.ceil(highest / step) * step), bottom = Math.floor(lowest / step) * step;
      const y = (value) => pad.top + plotHeight - (value - bottom) / Math.max(top - bottom, 1e-9) * plotHeight;
      const slot = plotWidth / Math.max(bars.length, 1), barWidth = Math.min(24, slot * 0.6);
      const x = (index) => pad.left + slot * index + slot / 2;

      const root = svg("svg", { width, height, viewBox: `0 0 ${width} ${height}`, class: "chart", role: "img", "aria-label": t("{title}, a bar per day", { title }) });
      root.setAttribute("tabindex", "0");
      const ticks = [];
      for (let value = bottom; value <= top + step / 2; value += step) ticks.push(value);
      const tickText = axisLabels(ticks, format, size);
      ticks.forEach((value, index) => {
        const at = y(value);
        root.append(svg("line", { x1: pad.left, x2: width - pad.right, y1: at, y2: at, class: value === 0 && bottom < 0 ? "grid zero" : "grid" }));
        const label = svg("text", { x: pad.left - 8, y: at + 4, class: "tick", "text-anchor": "end" });
        label.textContent = tickText[index];
        root.append(label);
      });
      const hover = svg("rect", { y: pad.top, height: plotHeight, width: slot, class: "bar-hover hidden", rx: 6 });
      root.append(hover);
      // Segments stack out from the baseline with a 2px gap between them; the outermost on each side has 4px
      // rounded corners at its free end, square at the baseline.
      const gap = 2, radius = 4;
      bars.forEach((bar, index) => {
        let up = 0, down = 0;
        const placed = [];
        segments.forEach((one, i) => {
          const value = sums[index][i];
          if (!value) return;
          const from = value > 0 ? up : down, to = from + value;
          if (value > 0) up = to; else down = to;
          placed.push({ one, from, to, positive: value > 0 });
        });
        const outer = { true: placed.filter((p) => p.positive).at(-1), false: placed.filter((p) => !p.positive).at(-1) };
        for (const part of placed) {
          const near = y(part.from), far = y(part.to);
          // The gap comes off the end nearer the baseline, except for the segment that sits on it.
          const onBase = part.from === 0;
          const start = onBase ? near : near + (part.positive ? -gap / 2 : gap / 2);
          const end = far + (part.positive ? gap / 2 : -gap / 2) * (outer[part.positive] === part ? 0 : 1);
          const length = Math.abs(end - start);
          if (length < 0.5) continue;
          const left = x(index) - barWidth / 2, r = outer[part.positive] === part ? Math.min(radius, length, barWidth / 2) : 0;
          const top = Math.min(start, end), bottom = Math.max(start, end);
          // Rounded at the free end only: the top for a positive bar, the bottom for a negative one.
          const d = part.positive
            ? `M${left},${bottom}V${top + r}Q${left},${top} ${left + r},${top}H${left + barWidth - r}Q${left + barWidth},${top} ${left + barWidth},${top + r}V${bottom}Z`
            : `M${left},${top}V${bottom - r}Q${left},${bottom} ${left + r},${bottom}H${left + barWidth - r}Q${left + barWidth},${bottom} ${left + barWidth},${bottom - r}V${top}Z`;
          root.append(svg("path", { d, class: `bar tone-${part.one.tone}` }));
        }
        // Bars too narrow for every label (a month's days on a phone) label one in `every`, the last always.
        const every = slot < 24 ? Math.ceil(24 / slot) : 1;
        if (index % every !== 0 && index !== bars.length - 1) return;
        const label = svg("text", { x: x(index), y: height - 6, class: bar.current ? "tick current" : "tick", "text-anchor": "middle" });
        label.textContent = slot < 64 && bar.narrow ? bar.narrow : bar.label;
        root.append(label);
      });
      frame.querySelector("svg")?.remove();
      frame.prepend(root);
      drawn = { root };

      const show = (index) => {
        chosen = index;
        if (index == null || !bars[index]) { hover.classList.add("hidden"); tooltip.classList.add("hidden"); return; }
        hover.setAttribute("x", x(index) - slot / 2);
        hover.classList.remove("hidden");
        tooltip.replaceChildren(html("div", "chart-time", bars[index].title ?? bars[index].label));
        segments.forEach((one, i) => {
          const row = html("div", "chart-row");
          const value = known[index][i];
          row.append(html("i", `key bar tone-${one.tone}`), html("b", "", value == null ? "–" : format(Math.abs(value))), html("span", "muted", one.label));
          tooltip.append(row);
        });
        tooltip.classList.remove("hidden");
        const px = x(index), left = px + slot / 2 + 8 + tooltip.offsetWidth > width ? px - slot / 2 - 8 - tooltip.offsetWidth : px + slot / 2 + 8;
        tooltip.style.left = `${Math.max(0, left)}px`;
      };
      const nearest = (clientX) => bars.length ? Math.min(bars.length - 1, Math.max(0, Math.floor((clientX - root.getBoundingClientRect().left - pad.left) / slot))) : null;
      root.addEventListener("pointermove", (event) => show(nearest(event.clientX)));
      root.addEventListener("pointerleave", () => { if (document.activeElement !== root) show(null); });
      root.addEventListener("blur", () => show(null));
      root.addEventListener("focus", () => show(chosen ?? (bars.length ? bars.length - 1 : null)));
      root.addEventListener("keydown", (event) => {
        const moves = { ArrowLeft: -1, ArrowRight: 1, Home: -Infinity, End: Infinity };
        if (!bars.length || !(event.key in moves)) return;
        event.preventDefault();
        show(Math.min(bars.length - 1, Math.max(0, (chosen ?? bars.length - 1) + moves[event.key])));
      });
    }

    const resize = new ResizeObserver(() => {
      if (!frame.isConnected) { resize.disconnect(); return; }
      if (frame.clientWidth && Math.abs(frame.clientWidth - (drawn ? Number(drawn.root.getAttribute("width")) : 0)) > 1) draw();
    });
    resize.observe(frame);
    draw();
    return { update(bars) { state = bars; chosen = null; tooltip.classList.add("hidden"); draw(); } };
  }

  window.HomeswiftChart = { lineChart, stackedBars };
})();
