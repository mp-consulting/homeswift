// The History and the Logbook (GLOSSARY.md): an accessory's History tab, on its sheet beside its controls (a chart per
// characteristic over 24 hours, a week or a year), and the /logbook page, what changed in the home and who changed it,
// filtered by room, accessory and Change Source.
(() => {
  "use strict";

  const { t, tn } = HomeswiftI18n;
  const { el, api } = HomeswiftCommon;
  const app = () => window.HomeswiftApp;

  const ranges = [["day", t("24 hours"), "history"], ["week", t("Week"), "grid"], ["year", t("Year"), "chart"]];
  const rangeHours = { day: 24, week: 168, year: 8760 };

  /// A value as the controls word it, a temperature in the user's unit.
  const valueText = (series, value) => HomeswiftWidgets.valueText({ type: series.characteristic, value, unit: series.unit, minValue: series.minValue,
    maxValue: series.maxValue, validValues: series.validValues, format: typeof value === "boolean" ? "bool" : series.kind === "number" && !Number.isInteger(value) ? "float" : undefined });
  /// A number as charted: a temperature in the user's unit.
  const chartValue = (series, value) => series.unit === "celsius" ? HomeswiftCommon.temperature(value).value : value;
  const unitText = (series) => series.unit === "celsius" ? HomeswiftCommon.temperature(0).unit : { percentage: "%", lux: "lx", seconds: "s", arcdegrees: "°" }[series.unit] ?? "";
  const decimal = (1.5).toLocaleString(HomeswiftI18n.numberLocale).charAt(1);
  const number = (value) => String(Math.abs(value) < 10 && value % 1 ? value.toFixed(1) : Math.round(value * 10) / 10).replace(".", decimal);
  /// A characteristic's title: its name, and its service's when that says more (a second outlet, a sensor of a station).
  const title = (series, accessory) => {
    const name = HomeswiftWidgets.characteristicName(series.characteristic);
    return series.service && series.service !== accessory.name && !accessory.name.endsWith(series.service) && !accessory.name.startsWith(series.service) ? `${name} · ${series.service}` : name;
  };
  /// The colour slot of a state: by its place among the values it may take; off, false or an enumeration's first (Off,
  /// Inactive, Unsecured is not first) in a neutral grey, as a switch that is off.
  const toneOf = (series, value) => {
    if (value === false) return "off";
    // A number's first value when it reads as off (Off, Inactive, Idle), as a switch that is off.
    if (value === 0 && [t("Off"), t("Off [setting]"), t("Inactive"), t("Idle")].includes(valueText(series, 0))) return "off";
    const order = typeof value === "boolean" ? Number(value) : series.validValues?.indexOf(value) ?? -1;
    if (order >= 0) return (order % 7) + 1;
    return (Math.abs([...String(value)].reduce((hash, char) => hash * 31 + char.charCodeAt(0) | 0, 7)) % 7) + 1;
  };

  /// The History tab of an accessory's sheet.
  function panel(accessory) {
    let range = "day", asked = 0;
    const charts = el("div", { class: "chart-grid history-charts" });
    const note = el("p", { class: "muted history-note" });
    const group = el("div", { class: "group", role: "group", "aria-label": t("Time range") }, ranges.map(([value, text, glyph]) =>
      el("button", { type: "button", text, actionIcon: glyph, class: value === range ? "on" : "", "aria-pressed": String(value === range), onclick: (event) => {
        range = value;
        for (const button of group.children) { button.classList.toggle("on", button === event.currentTarget); button.setAttribute("aria-pressed", String(button === event.currentTarget)); }
        load();
      } })));
    const logbook = el("a", { class: "button", href: `/logbook?accessory=${encodeURIComponent(accessory.id)}`, actionIcon: "logs", text: t("Logbook"),
      onclick: () => document.querySelector("dialog.widget-sheet[open]")?.close() });
    const root = el("article", { class: "card accessory-card widget-full history-full" },
      el("div", { class: "editor-bar history-head" },
        el("div", { class: "who" }, el("h2", { text: accessory.name }), el("p", { class: "muted", text: t("Its values over time. The Logbook says who changed them.") })),
        el("div", { class: "tools" }, group)),
      charts, note, el("div", { class: "actions start" }, logbook));

    async function load() {
      const mine = ++asked;
      charts.classList.add("loading");
      const timeZone = HomeswiftI18n.timeZone;
      const energy = accessory.consumption && window.HomeswiftAdmin?.consumptionCards ? HomeswiftAdmin.consumptionCards(accessory, rangeHours[range]) : Promise.resolve([]);
      let found;
      try { found = await api(`/api/accessories/${encodeURIComponent(accessory.id)}/history?${new URLSearchParams({ range, timeZone })}`); }
      catch (e) { if (mine === asked) { charts.classList.remove("loading"); note.className = "error history-note"; note.textContent = e.message; } return; }
      const energyCards = await energy;
      if (mine !== asked) return;
      charts.classList.remove("loading");
      note.className = "muted history-note";
      note.textContent = t("Each change is kept {days} days, and the hourly figures of numbers {years} years.", { days: String(found.days), years: String(found.years) });
      // Names describe the accessory; they are not activity. Keep them available without a full timeline.
      const metadata = new Set(["Name", "Configured Name", "Identifier", "Serial Number", "Manufacturer", "Model", "Firmware Revision"]);
      const details = found.series.filter((series) => metadata.has(series.characteristic));
      const cards = found.series.filter((series) => !metadata.has(series.characteristic))
        .map((series) => series.kind === "number" ? numberCard(series, found) : stateCard(series, found)).filter(Boolean);
      if (details.length) cards.push(el("details", { class: "history-details" },
        el("summary", { text: t("Details") }), details.map((series) => stateCard(series, found))));
      // Only the compact state list uses the console material; charts retain their normal theme.
      const content = [...energyCards];
      let stateList = null;
      for (const node of cards) {
        if (node.matches(".history-state-row, .history-details")) {
          if (!stateList) { stateList = el("div", { class: "log history-state-list", tabindex: 0, role: "region", "aria-label": t("History") }); content.push(stateList); }
          stateList.append(node);
        } else { stateList = null; content.push(node); }
      }
      charts.replaceChildren(...content);
      if (!cards.length && !energyCards.length) charts.append(el("p", { class: "muted", text: t("Nothing recorded in this range") }));
    }

    function card(series, figure, detail) {
      const body = el("div", { class: "chart-body" });
      const node = el("div", { class: "card chart-card" },
        el("div", { class: "chart-head" }, el("div", { class: "who" }, el("strong", { text: title(series, accessory) }), el("div", { class: "muted", text: detail })),
          figure != null ? el("b", { class: "chart-figure", text: figure }) : null),
        body);
      return [node, body];
    }

    function numberCard(series, found) {
      const unit = unitText(series);
      const format = (value) => `${number(value)}${unit ? (unit === "%" || unit === "°" ? unit : ` ${unit}`) : ""}`;
      const figure = series.last != null ? valueText(series, series.last) : null;
      const label = title(series, accessory);
      if (series.hours) {
        const points = series.hours.map(([time, min, mean, max]) => ({ time, min: chartValue(series, min), mean: chartValue(series, mean), max: chartValue(series, max) }));
        if (!points.length) return null;
        const lowest = Math.min(...points.map((point) => point.min)), highest = Math.max(...points.map((point) => point.max));
        const [node, body] = card(series, figure, t("Lowest {min} · highest {max} · average {average}", { min: format(lowest), max: format(highest),
          average: format(points.reduce((sum, point) => sum + point.mean, 0) / points.length) }));
        HomeswiftChart.lineChart(body, { title: label, format, points, from: found.from, to: found.to, step: series.step === "day" ? 86_400_000 : 3_600_000, fit: true,
          series: [{ label: t("Highest"), tone: 4, value: (point) => point.max }, { label: t("Average"), tone: 1, value: (point) => point.mean },
            { label: t("Lowest"), tone: 3, value: (point) => point.min }] });
        return node;
      }
      // Each change holds until the next: drawn as steps, from the value held at the start to now.
      const changes = series.points.map(([time, value]) => ({ time, value: chartValue(series, value) }));
      const points = [];
      if (series.before != null) points.push({ time: found.from, value: chartValue(series, series.before) });
      for (const change of changes) {
        if (points.length) points.push({ time: change.time - 1, value: points.at(-1).value });
        points.push(change);
      }
      if (!points.length) return null;
      points.push({ time: found.to, value: points.at(-1).value });
      const values = points.map((point) => point.value);
      const [node, body] = card(series, figure, t("Lowest {min} · highest {max} · average {average}", { min: format(Math.min(...values)), max: format(Math.max(...values)),
        average: format(weightedMean(points)) }));
      HomeswiftChart.lineChart(body, { title: label, format, points, from: found.from, to: found.to, step: found.to - found.from, fit: series.unit !== "percentage",
        series: [{ label, tone: 1, value: (point) => point.value }] });
      return node;
    }

    function compactState(series) {
      return el("div", { class: "history-state-row" },
        el("div", { class: "who" }, el("strong", { text: title(series, accessory) }),
          el("small", { class: "muted", text: tn("{n} change", "{n} changes", series.points?.length ?? 0) })),
        el("b", { text: series.last != null ? valueText(series, series.last) : "—" }));
    }

    function stateCard(series, found) {
      const spans = [];
      let at = found.from, value = series.before ?? null;
      for (const [time, next] of series.points) {
        if (time > at) spans.push({ from: at, to: time, value });
        at = Math.max(at, time);
        value = next;
      }
      spans.push({ from: at, to: found.to, value });
      if (!spans.some((span) => span.value != null)) return null;
      const changes = series.points.length;
      if (!changes) return compactState(series);
      const figure = series.last != null ? valueText(series, series.last) : null;
      const [node, body] = card(series, figure, tn("{n} change", "{n} changes", changes));
      HomeswiftChart.stateTimeline(body, { title: title(series, accessory), spans, from: found.from, to: found.to, label: (one) => valueText(series, one), tone: (one) => toneOf(series, one) });
      return node;
    }

    load();
    return root;
  }

  /// The mean of a line of points, each held until the next.
  function weightedMean(points) {
    let sum = 0, span = 0;
    for (let i = 0; i + 1 < points.length; i++) {
      const held = points[i + 1].time - points[i].time;
      sum += points[i].value * held;
      span += held;
    }
    return span > 0 ? sum / span : points[0].value;
  }

  // ---- The Logbook

  const sourceKinds = [["", t("Everyone and everything")], ["homeApp", t("The Home app")], ["user", t("Homeswift users")], ["mcp", t("MCP clients")],
    ["automation", t("Automations")], ["scene", t("Scenes")], ["remote", t("Remotes")], ["device", t("The devices themselves")]];
  const sourceIcons = { homeApp: "house", user: "user", mcp: "sparkle", automation: "workflow", scene: "play", remote: "remote", device: "accessory" };
  /// Who made a change, as a person reads it.
  function sourceText(source) {
    switch (source.kind) {
      case "homeApp": return t("Home app");
      case "device": return t("The device");
      case "automation": return t("Automation {name}", { name: source.name });
      case "scene": return t("Scene {name}", { name: source.name });
      // A Remote's Control: the remote and its Button or Wheel ("BILRESA · Channel 2 wheel").
      case "remote": return source.name;
      case "user": return source.name ?? t("A Homeswift user");
      case "mcp": return source.name ?? t("An MCP client");
      default: return source.name ?? "";
    }
  }
  /// The Logbook's time ranges (HomeswiftCommon.rangeControl): hours or days back, Everything kept, or Custom… for any days kept.
  const rangeChoices = [["24h", t("24 hours")], ["3d", t("3 days")], ["7d", t("7 days")], ["all", t("Everything kept")]];

  async function logbookView(main) {
    const params = new URLSearchParams(location.search);
    // An address from before the range control: `since=` (empty) was Everything kept.
    if (params.get("since") === "") params.set("since", "all");
    const accessories = await api("/api/accessories").catch(() => []);
    const rooms = [...new Set(accessories.map((accessory) => accessory.room).filter(Boolean))].sort((a, b) => a.localeCompare(b, HomeswiftI18n.locale));
    const select = (name, label, choices, value) => {
      const node = el("select", { name, class: "popup", "aria-label": label }, choices.map(([key, text]) => el("option", { value: key, text, selected: key === value })));
      node.addEventListener("change", reload);
      return node;
    };
    const room = select("room", t("Room"), [["", t("All rooms")], ...rooms.map((name) => [name, name])], params.get("room") ?? "");
    const accessory = select("accessory", t("Accessory"), [["", t("All accessories")],
      ...[...accessories].sort((a, b) => a.name.localeCompare(b.name, HomeswiftI18n.locale)).map((one) => [one.id, one.name])], params.get("accessory") ?? "");
    const source = select("source", t("Change Source"), sourceKinds, params.get("source") ?? "");
    const controls = [room, accessory, source];
    /// The days the Logbook keeps: the first Custom… day offered, from the first read.
    let kept = 30;
    const range = HomeswiftCommon.rangeControl(params, { presets: rangeChoices, fallback: "24h", earliestDays: () => kept, changed: () => { histogram.pick(null); reload(); } });
    // The whole range at once, before its entries are read (HomeswiftCommon.timeHistogram): a span picked on it is what
    // the list shows; its chip under the time range goes back.
    const histogram = HomeswiftCommon.timeHistogram(params, { unit: (n) => tn("{n} entry", "{n} entries", n), changed: () => reload(false, true) });
    const clear = HomeswiftCommon.clearFilters(controls.map((control) => [control, ""]),
      { active: () => range.chosen() || Boolean(histogram.selection), events: [[range.control, "change"], [histogram.element, "change"]],
        reset: () => { range.reset(); histogram.pick(null); reload(); } });
    const list = el("div", { class: "log logbook", tabindex: 0, role: "region", "aria-label": t("Logbook") });
    const count = el("p", { class: "muted logbook-count", "aria-live": "polite" });
    // Follow, as on the Logs page: the Logbook read again every few seconds, the newest kept in view.
    const followBox = el("input", { type: "checkbox", checked: true });
    const followToggle = el("label", { class: "toggle compact log-follow" }, el("span", { class: "switch" }, followBox, el("span")), el("span", { text: t("Follow") }));
    const countRow = el("div", { class: "logbook-count-row" }, count, histogram.readout, followToggle);
    const head = el("div", { class: "log-action-bar logbook-head" }, countRow, histogram.element);
    const icons = new Map(accessories.map((one) => [one.id, HomeswiftWidgets.accessoryIcon(one) ?? "accessory"]));
    const byID = new Map(accessories.map((one) => [one.id, one]));
    // The time range's caption and Clear filters; on a phone, where captions are hidden, the count beside Clear filters.
    const timeHead = el("div", { class: "log-time-head" }, el("span", { text: t("Time range") }), clear);
    const panel = el("div", { class: "log-filter-panel logbook-toolbar" },
      el("div", { class: "log-scope-row" },
        el("div", { class: "log-time" }, timeHead, range.control, histogram.chip),
        ...[[t("Room"), room], [t("Accessory"), accessory], [t("Change Source"), source]].map(([label, control]) =>
          el("label", {}, el("span", { text: label }), control))));
    // A phone (as the Logs page and the Audit log): one bar above the tab bar, a search through the entries shown, Filters
    // (the panel as a sheet over the bar, its badge counting the filters that are not the defaults) and the Assistant.
    const filters = HomeswiftCommon.filtersToggle(panel);
    filters.button.classList.add("log-filters-toggle");
    const showCount = () => filters.count(controls.filter((control) => control.value).length + (range.chosen() ? 1 : 0) + (histogram.selection ? 1 : 0));
    for (const control of controls) control.addEventListener("change", showCount);
    range.control.addEventListener("change", showCount);
    histogram.element.addEventListener("change", showCount);
    showCount();
    const search = el("input", { type: "search", class: "search bar-only", placeholder: t("Search"), "aria-label": t("Search") });
    const applySearch = () => {
      const words = search.value.trim().toLocaleLowerCase();
      for (const day of list.querySelectorAll(".logbook-day")) {
        let any = false;
        for (const entry of day.querySelectorAll(".logbook-entry")) {
          const shown = !words || entry.textContent.toLocaleLowerCase().includes(words);
          entry.hidden = !shown;
          any ||= shown;
        }
        day.hidden = !any;
      }
    };
    search.addEventListener("input", applySearch);
    // Following (the switch, on a phone Pause and Play in the bar): read again every few seconds, the newest kept in
    // view (at the top, on a phone at the foot by the bar), and on a phone an arrow back to the end once scrolled away.
    const phone = HomeswiftCommon.phone;
    let following = true;
    const followUI = HomeswiftCommon.followControls({ following: () => following, setFollowing: (on) => setFollowing(on) });
    function setFollowing(on) {
      following = followBox.checked = on;
      followUI.paint();
      if (!on) return;
      if (phone.matches) followUI.toEnd(true); else list.scrollTop = 0;
      reload(true);
    }
    followBox.addEventListener("change", () => setFollowing(followBox.checked));
    const bar = el("div", { class: "logbook-bar phone-bar" }, search, filters.button, followUI.button, HomeswiftCommon.assistantButton());
    const card = el("div", { class: "card log-card logbook-card" }, panel, head, list);
    // On a phone the count heads the Filters sheet, on Clear filters' line, and the histogram the log; wider, Filters is
    // in the count's row (shown between a phone and 900px, where the filters are a side sheet).
    const placeCount = () => {
      if (HomeswiftCommon.phone.matches) { timeHead.prepend(count); search.after(filters.button); }
      else { countRow.prepend(count); countRow.insertBefore(filters.button, followToggle); }
    };
    placeCount();
    // Between a phone and a wider window the entries change order (the newest at the foot, or first): drawn again.
    phone.addEventListener("change", () => { placeCount(); draw("new"); }, { signal: HomeswiftCommon.viewSignal() });
    const refresh = setInterval(() => {
      if (!bar.isConnected) { clearInterval(refresh); return; }
      // Wider than a phone, only at the list's top: someone reading further down keeps their place.
      if (!phone.matches && list.scrollTop > 40) return;
      if (following && !document.hidden && !filters.isOpen() && !HomeswiftCommon.menuOpen()) reload(true);
    }, 4000);
    HomeswiftCommon.viewSignal().addEventListener("abort", () => clearInterval(refresh));
    app().show(main, app().pageHead(t("Logbook"), t("What changed in the home, and who or what changed it.")), card, bar, followUI.latest);

    /// What was last drawn: a quiet read (the refresh) that finds the same entries in the same order draws nothing.
    let drawn = "";
    /// The entries drawn, newest first; whether older ones match too; whether older pages were added to the first.
    let shown = [], more = false, extended = false;
    /// A new choice of filters: the reads of an earlier one are dropped.
    let generation = 0;
    const earlier = el("button", { type: "button", class: "logbook-earlier", actionIcon: "history", text: t("Show earlier"), onclick: () => readAll() });
    const earlierError = el("p", { class: "error", hidden: true });
    const earlierRow = el("div", { class: "logbook-more" }, earlier, earlierError);
    const dayFormat = HomeswiftI18n.dateTimeFormat({ weekday: "long", day: "numeric", month: "long" });
    const dayKey = histogram.dayKey;

    /// The entries' query is the picked span's (`until` includes its bound: a millisecond before its end); the
    /// histogram's (`whole`) is the range's.
    function filterQuery(whole = false) {
      const query = new URLSearchParams();
      for (const control of controls) if (control.value) query.set(control.name, control.value);
      const span = range.span(), picked = whole ? null : histogram.selection;
      const since = picked ? picked.from : span?.[0];
      const until = picked ? new Date(Math.min(picked.to - 1, span?.[1] ?? Infinity)) : span?.[1];
      if (since) query.set("since", since.toISOString());
      if (until) query.set("until", until.toISOString());
      return query;
    }
    /// The choice itself, for the address (a range back from now moves with the clock).
    function filterKey() {
      const query = new URLSearchParams();
      range.address(query);
      for (const control of controls) if (control.value) query.set(control.name, control.value);
      histogram.address(query);
      return query.toString();
    }

    /// `newer`, then `older`'s entries from before `newer`'s last. Times are to the second, so `older` (read up to and
    /// with that second) starts with the ones `newer` has of it, in the Logbook's order: as many are left out.
    function join(newer, older) {
      if (!newer.length) return older;
      const edge = newer.at(-1).time;
      let skip = newer.filter((entry) => entry.time === edge).length;
      return newer.concat(older.filter((entry) => entry.time < edge || (entry.time === edge && skip-- <= 0)));
    }

    /// What was drawn, for a refresh that finds nothing new.
    const shape = () => [filterKey(), phone.matches, shown.length, shown[0]?.time, shown.at(-1)?.time, histogram.count()].join("|");

    /// `entriesOnly`: a new pick on the histogram, whose counts stay.
    async function reload(quiet = false, entriesOnly = false) {
      if (quiet instanceof Event) quiet = false;
      const key = filterKey();
      const path = `/logbook${key ? `?${key}` : ""}`;
      if (path !== location.pathname + location.search) history.replaceState(null, "", path);
      const at = quiet ? generation : ++generation;
      const query = filterQuery();
      if (!quiet) { list.classList.add("loading"); earlierError.hidden = true; }
      let found, hours;
      // The counts are read with the entries, but a refresh reads them again only once a new entry came. Without them
      // the list still shows: the histogram waits for the next read.
      const readHours = () => api(`/api/logbook/hours?${filterQuery(true)}`).catch(() => null);
      try {
        [found, hours] = await Promise.all([api(`/api/logbook?${query}`), entriesOnly || quiet ? null : readHours()]);
        const newest = (entries) => entries.slice(0, 10).map((entry) => `${entry.time} ${entry.accessory} ${entry.characteristic}`).join("|");
        if (quiet && newest(found.entries) !== newest(shown)) hours = await readHours();
      } catch (e) {
        if (at !== generation) return;
        list.classList.remove("loading");
        if (!quiet) list.replaceChildren(el("p", { class: "error", text: e.message }));
        return;
      }
      if (at !== generation || (quiet && loading)) return;
      list.classList.remove("loading");
      kept = found.days;
      // The refresh keeps the older pages read, after the newest.
      if (quiet && extended) shown = join(found.entries, shown);
      else { shown = found.entries; more = found.more === true; extended = false; }
      // From the first day with entries, but each day of a custom range.
      if (hours) { const span = range.span(); histogram.set({ hours: hours.hours ?? [], from: span?.[0] ?? null, to: span?.[1] ?? null, trim: !range.custom() }); }
      if (quiet && shape() === drawn) return;
      drawn = shape();
      draw(quiet ? "quiet" : entriesOnly ? "pick" : "new");
    }

    /// Infinite scroll: near the oldest entries (the list's foot, on a phone its top), the next ones are read. Show all
    /// reads the whole range, or span, at once.
    let loading = false;
    const reach = 600;
    function nearOldest() {
      const scroller = list.scrollHeight > list.clientHeight + 1 ? list : null;
      if (phone.matches) return (scroller ?? document.scrollingElement).scrollTop < reach;
      if (scroller) return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < reach;
      return earlierRow.getBoundingClientRect().top < innerHeight + reach;
    }
    const maybeEarlier = () => { if (more && !loading && shown.length && !earlierRow.hidden && nearOldest()) readWhile(() => false, 300); };
    const onScroll = () => { maybeEarlier(); spy(); };
    list.addEventListener("scroll", onScroll, { passive: true });
    addEventListener("scroll", onScroll, { passive: true, signal: HomeswiftCommon.viewSignal() });

    /// Every entry of the range, or of the span picked, saying how far it is.
    const readAll = () => readWhile(() => true, 1000, true);

    /// Reads the entries before the oldest shown, `limit` a page, while `wanted()` and older ones are left, then draws them
    /// once. On a phone the older entries come above: the one that was at the top stays where it was.
    async function readWhile(wanted, limit, progress = false) {
      if (loading || !shown.length) return false;
      loading = true;
      const at = generation, before = shown.length;
      earlier.disabled = true;
      earlierError.hidden = true;
      card.classList.add("reading");
      let read = false;
      try {
        do {
          const query = filterQuery();
          query.set("until", new Date(Date.parse(shown.at(-1).time) + 999).toISOString());
          query.set("limit", String(limit));
          const found = await api(`/api/logbook?${query}`);
          if (at !== generation) return false;
          shown = join(shown, found.entries);
          more = found.more === true;
          extended = read = true;
          if (more && progress) earlier.textContent = t("Reading {n} of {total}…", { n: shown.length, total: Math.max(histogram.count(), shown.length) });
        } while (more && wanted());
      } catch (e) {
        if (at === generation) { earlierError.textContent = e.message; earlierError.hidden = false; }
      } finally {
        loading = false;
        earlier.disabled = false;
        card.classList.remove("reading");
      }
      if (!read || at !== generation) return read;
      drawn = shape();
      const anchor = () => list.querySelector(`[data-index="${before - 1}"]`);
      const top = anchor()?.getBoundingClientRect().top;
      draw("earlier");
      if (phone.matches && top !== undefined) document.scrollingElement.scrollBy(0, (anchor()?.getBoundingClientRect().top ?? top) - top);
      return true;
    }

    /// The day at the top of the list (on a phone, at the middle of the window), marked under the histogram.
    let spying = 0;
    function spy() {
      cancelAnimationFrame(spying);
      spying = requestAnimationFrame(() => {
        const y = phone.matches ? innerHeight * 0.45 : list.getBoundingClientRect().top + 48;
        const sections = [...list.querySelectorAll(".logbook-day:not([hidden])")];
        const at = sections.find((section) => section.getBoundingClientRect().bottom > y) ?? sections.at(-1);
        histogram.mark(at?.dataset.day);
      });
    }

    function draw(mode) {
      const newestLast = phone.matches;
      const atEnd = followUI.atEnd();
      const atTop = list.scrollTop < 40;
      // Each day's entries in the span picked (all of the range without one).
      const counts = histogram.countsByDay();
      const counted = Math.max(histogram.count(), shown.length);
      const busy = [...counts.values()].filter(Boolean).length;
      // How many entries the range (or the span picked) has, and, until all are read, how many are shown.
      count.textContent = more
        ? tn("{shown} of {n} entry · kept {days} days", "{shown} of {n} entries · kept {days} days", counted, { shown: shown.length, days: kept })
        : tn("{n} entry · kept {days} days", "{n} entries · kept {days} days", counted, { days: kept });
      // Show all says how much: every day of the range, or of the span.
      earlier.textContent = busy > 1 ? t("Show all {n} days", { n: busy }) : t("Show earlier");
      if (!shown.length) { earlierRow.hidden = true; list.replaceChildren(el("p", { class: "muted empty", text: t("Nothing changed in this range.") })); return; }
      // Hours and minutes read at a glance; the seconds are in the time's tooltip.
      const timeFormat = HomeswiftI18n.dateTimeFormat({ hour: "2-digit", minute: "2-digit", hour12: false });
      const exactFormat = HomeswiftI18n.dateTimeFormat({ hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
      const byDay = new Map();
      const indexed = shown.map((entry, index) => [entry, index]);
      for (const [entry, index] of newestLast ? indexed.reverse() : indexed) {
        const date = new Date(entry.time);
        const key = dayKey(date);
        if (!byDay.has(key)) byDay.set(key, { date, rows: [] });
        byDay.get(key).rows.push(row(entry, index, date, timeFormat, exactFormat));
      }
      const sections = [...byDay].map(([key, { date, rows }]) => {
        const all = counts.get(key);
        // A day read only in part says so: the rest comes as the list scrolls on, or with Show all.
        const summary = el("summary", {}, el("span", { text: dayFormat.format(date) }),
          el("span", { class: "logbook-day-total", text: all && all > rows.length
            ? t("{shown} of {total}", { shown: rows.length, total: all })
            : tn("{n} entry", "{n} entries", rows.length) }));
        const section = el("details", { class: "logbook-day", "data-day": key }, summary, el("ul", { class: "logbook-list" }, rows));
        section.open = true;
        return section;
      });
      // Show all goes where the oldest entries are: the foot, or on a phone the top.
      earlierRow.hidden = !more;
      list.replaceChildren(...(newestLast ? [earlierRow, ...sections] : [...sections, earlierRow]));
      applySearch();
      spy();
      if (mode === "earlier") return;
      // Following, from the newest (or a first draw), the list stays at the newest: its top, or on a phone its foot,
      // where the arrow back is not needed.
      if (!newestLast) { if (following && (mode !== "quiet" || atTop)) list.scrollTop = 0; return; }
      if (following && (mode === "new" || atEnd)) followUI.toEnd(); else followUI.showLatest();
    }

    function row(entry, index, date, timeFormat, exactFormat) {
      const series = { characteristic: entry.characteristic, kind: typeof entry.value === "number" ? "number" : "state" };
      const live = byID.get(entry.accessory);
      const characteristic = live?.services?.flatMap((service) => service.characteristics ?? []).find((one) => one.type === entry.characteristic);
      if (characteristic) Object.assign(series, { unit: characteristic.unit, minValue: characteristic.minValue, maxValue: characteristic.maxValue, validValues: characteristic.validValues });
      const what = t("{characteristic}: {value}", { characteristic: HomeswiftWidgets.characteristicName(entry.characteristic), value: valueText(series, entry.value) });
      return el("li", { class: "logbook-entry", "data-index": index },
        el("time", { datetime: entry.time, title: exactFormat.format(date), text: timeFormat.format(date) }),
        el("span", { class: "tile", "aria-hidden": "true" }, HomeswiftCommon.icon(icons.get(entry.accessory) ?? "accessory")),
        el("div", { class: "who" }, el("strong", { text: entry.name }), el("span", { class: "muted", text: [what, entry.room].filter(Boolean).join(" · ") })),
        el("span", { class: `pill source source-${entry.source.kind}`, title: entry.source.kind === "homeApp" ? t("Pairing {id}", { id: entry.source.name }) : sourceText(entry.source) },
          HomeswiftCommon.icon(sourceIcons[entry.source.kind] ?? "accessory"), el("span", { text: sourceText(entry.source) })));
    }
    reload();
  }

  window.HomeswiftHistory = { panel, logbookView, sourceText };
})();
