// Rooms and hidden accessories, the Quick Controls, scenes and their automations, and notifications: the views
// ported from Glass UI. app.js hands its helpers over with install() before the first view is drawn.
(() => {
  "use strict";

  const { $, el, tile, sparkle, menuButton, fact } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;
  let app = null;

  const weekdays = [t("Sun"), t("Mon"), t("Tue"), t("Wed"), t("Thu"), t("Fri"), t("Sat")];
  // The days picker's two-letter labels.
  const dayLetters = [t("Su"), t("Mo"), t("Tu"), t("We"), t("Th"), t("Fr"), t("Sa")];
  const operators = [["eq", t("is")], ["neq", t("is not")], ["gt", t("is above")], ["gte", t("is at least")], ["lt", t("is below")], ["lte", t("is at most")]];
  const field = (label, input, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), input, help ? el("span", { class: "help", text: help }) : null);
  const displayName = (accessory) => accessory.displayName || accessory.name;
  const statusLine = () => el("p", { class: "status-line muted", role: "status" });
  const say = (line, text, kind = "muted") => { line.className = `status-line ${kind}`; line.textContent = text; };

  // ---- Rooms, hidden accessories, display names ------------------------------------------------------

  async function changeLayout(body) {
    return app.api("/api/rooms", { method: "PUT", body });
  }

  /// What an accessory card's menu adds: its room, a name for these pages, Quick Controls, hiding.
  function layoutActions(accessory) {
    const change = (fields) => changeLayout({ accessories: { [accessory.id]: fields } }).then(() => app.route()).catch((e) => alert(e.message));
    return [
      { label: accessory.room ? t("Room: {room}…", { room: accessory.room }) : t("Put in a room…"), icon: "room", onSelect: () => chooseRoom(accessory, change) },
      { label: t("Name on these pages…"), icon: "edit", onSelect: () => {
        const name = prompt(t("A name for {name} on these pages (the Home app keeps its own). Empty goes back to {name}.", { name: accessory.name }), accessory.displayName || "");
        if (name !== null) change({ name: name.trim() || null });
      } },
      { label: accessory.favourite ? t("Remove from Quick Controls") : t("Add to Quick Controls"), icon: "star", onSelect: () => change({ favourite: !accessory.favourite }) },
      { label: accessory.hidden ? t("Show it again") : t("Hide"), icon: "eye", onSelect: () => change({ hidden: !accessory.hidden }) },
    ];
  }

  async function chooseRoom(accessory, change) {
    let rooms = [];
    try { rooms = (await app.api("/api/rooms")).rooms.map((room) => room.name); } catch {}
    const room = prompt(rooms.length
      ? t("The room of {name}. Rooms: {rooms}. A new name adds the room; empty takes it out of its room.", { name: displayName(accessory), rooms: rooms.join(", ") })
      : t("The room of {name}. A new name adds the room; empty takes it out of its room.", { name: displayName(accessory) }), accessory.room || "");
    if (room !== null) change({ room: room.trim() || null });
  }

  /// The Accessories page's accessories by room, in the layout's order; those in no room last.
  function groupByRoom(accessories, rooms) {
    const byName = (a, b) => displayName(a).localeCompare(displayName(b));
    const groups = rooms.map((room) => [room, accessories.filter((a) => a.room === room).sort(byName)]).filter(([, list]) => list.length);
    const rest = accessories.filter((a) => !a.room || !rooms.includes(a.room)).sort(byName);
    return rest.length ? [...groups, [groups.length ? t("No room") : t("Accessories"), rest]] : groups;
  }

  /// The Assistant's rooms and names, to review: each suggestion can be kept or left; Apply saves what is kept.
  /// Names go to these pages only; HomeKit and the Home app keep theirs.
  async function suggestRooms(host, accessories) {
    host.querySelector(".suggest")?.remove();
    const panel = el("div", { class: "card panel suggest" },
      el("div", { class: "panel-head" }, el("div", {}, el("h2", {}, sparkle(), " ", t("Suggested rooms")), el("p", { class: "muted", text: t("The Assistant is sorting your accessories into rooms…") }))));
    host.prepend(panel);
    panel.classList.add("ai-busy");
    let result;
    try {
      result = await app.api("/api/rooms/suggest", { method: "POST", body: {} });
    } catch (e) {
      panel.replaceChildren(el("p", { class: "error", text: e.message }), el("div", { class: "actions" }, el("button", { text: t("Close"), onclick: () => panel.remove() })));
      return;
    } finally { panel.classList.remove("ai-busy"); }
    const byID = new Map(accessories.map((a) => [a.id, a]));
    const checks = [];
    const check = (data, label, detail) => {
      const input = el("input", { type: "checkbox", checked: true });
      checks.push({ input, data });
      return el("label", { class: "toggle compact" }, input, el("span", {}, el("span", { text: label }), detail ? el("span", { class: "help", text: detail }) : null));
    };
    const rooms = result.rooms.filter((room) => room.accessories.length).map((room) => el("div", { class: "suggest-room" },
      el("div", { class: "service-name", text: room.name }),
      room.accessories.map((id) => {
        const accessory = byID.get(id);
        const moved = accessory?.room && accessory.room !== room.name ? t("now in {room}", { room: accessory.room }) : accessory?.room === room.name ? t("already there") : null;
        return check({ id, room: room.name }, accessory ? displayName(accessory) : id, moved);
      })));
    const renames = result.renames.map((rename) => check({ id: rename.id, name: rename.name }, `${rename.current} → ${rename.name}`, rename.reason));
    const orphans = result.orphans.map((orphan) => el("li", {}, el("strong", { text: orphan.name }), ` ${orphan.reason}`));
    const line = statusLine();
    const apply = el("button", { class: "primary", text: t("Apply what is ticked"), onclick: async () => {
      const changes = {};
      for (const { input, data } of checks) {
        if (!input.checked) continue;
        changes[data.id] = { ...changes[data.id], ...(data.room ? { room: data.room } : { name: data.name }) };
      }
      apply.disabled = true;
      try { await changeLayout({ accessories: changes }); app.route(); } catch (e) { say(line, e.message, "error"); apply.disabled = false; }
    } });
    panel.replaceChildren(
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", {}, sparkle(), " ", t("Suggested rooms")),
          el("p", { class: "muted", text: t("From {model}. Untick what you do not want; nothing changes until you apply. Names show on these pages only: the Home app keeps its own.", { model: result.model }) })),
        el("button", { class: "link", text: t("Dismiss"), onclick: () => panel.remove() })),
      rooms.length ? el("div", { class: "suggest-rooms" }, rooms) : el("p", { class: "muted", text: t("No room to suggest.") }),
      renames.length ? el("div", {}, el("div", { class: "service-name", text: t("Clearer names") }), renames) : null,
      orphans.length ? el("div", {}, el("div", { class: "service-name", text: t("Worth a look") }), el("ul", { class: "help" }, orphans)) : null,
      el("div", { class: "actions" }, apply), line);
  }

  // ---- Quick Controls --------------------------------------------------------------------------------

  /// The favourite accessories by room, and the scenes to run: a section of the Status page, and the whole of
  /// /quick (a page for a phone's home screen). Draws once its data is there.
  function quickSection(accessories, { standalone = false } = {}) {
    const section = el("section", { class: "quick" });
    (async () => {
      const [list, scenes] = await Promise.all([
        accessories ? Promise.resolve(accessories) : app.api("/api/accessories").then((all) => app.withSlugs(all, "accessory")),
        app.api("/api/scenes").then((answer) => answer.scenes).catch(() => []),
      ]);
      const favourites = list.filter((a) => a.favourite && !a.hidden);
      if (!favourites.length && !scenes.length) {
        if (standalone) section.append(el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("star")), el("p", { class: "muted", text: t("Nothing here yet. On the Accessories page, a card's menu adds it to the Quick Controls; scenes you make show here too.") })));
        return;
      }
      const rooms = [...new Set(favourites.map((a) => a.room).filter(Boolean))];
      // `append` is the DOM's: it writes null and arrays as text, so the parts go in flat and without the empty ones.
      section.append(...[
        standalone ? null : el("div", { class: "section-head" }, el("h2", { text: t("Quick controls") }), el("a", { href: "/quick", class: "muted", text: t("Open on its own") })),
        scenes.length ? el("div", { class: "quick-scenes" }, scenes.map((scene) => sceneButton(scene))) : null,
        groupByRoom(favourites, rooms).map(([room, members]) => [
          rooms.length ? el("div", { class: "service-name", text: room }) : null,
          // The accessories' widgets, as the Accessories page draws them.
          el("div", { class: "wall" }, members.map((accessory) => app.accessoryCard(accessory))),
        ]),
      ].flat(2).filter(Boolean));
    })().catch((e) => section.append(el("p", { class: "error", text: e.message })));
    return section;
  }

  function sceneButton(scene) {
    const button = el("button", { class: "scene-run", title: t("Run {name}", { name: scene.name }) }, tile("play", scene.security ? "violet" : "orange"), el("span", { text: scene.name }));
    button.addEventListener("click", () => runScene(scene, button));
    return button;
  }

  /// Runs a scene; one that changes a lock, a door or an alarm asks first, as the cards' own controls do.
  async function runScene(scene, button) {
    let confirmSecurity = false;
    if (scene.security) {
      const which = scene.actions.filter((a) => a.security).map((a) => `${a.name || a.id}: ${a.characteristic}`).join(", ");
      if (!confirm(t("{scene} changes a lock, a door or an alarm ({which}). Run it?", { scene: scene.name, which }))) return;
      confirmSecurity = true;
    }
    button?.classList.add("busy");
    if (button) button.disabled = true;
    try {
      const result = await app.api(`/api/scenes/${encodeURIComponent(scene.id)}/run`, { method: "POST", body: { confirmSecurity } });
      if (!result.ok) {
        const failures = result.results.filter((r) => !r.ok).map((r) => `${r.name || r.id} ${r.characteristic}: ${HomeswiftI18n.message(r.error || r.skipped)}`);
        alert(t("{scene} ran, but not everything worked:\n{failures}", { scene: scene.name, failures: failures.join("\n") }));
      }
      return result;
    } catch (e) { alert(e.message); } finally {
      button?.classList.remove("busy");
      if (button) button.disabled = false;
    }
  }

  // ---- Moods -----------------------------------------------------------------------------------------

  /// The collection's names and descriptions, by id: translated here, the server's being English for MCP clients.
  const moodTexts = {
    "candlelight": [t("Candlelight"), t("Very warm, dim light for dinner.")],
    "relax": [t("Relax"), t("Soft warm white for the evening.")],
    "golden-hour": [t("Golden hour"), t("Amber and soft orange, a little different on each light.")],
    "cinema": [t("Cinema"), t("Almost dark, with a touch of blue behind the screen.")],
    "romantic": [t("Romantic"), t("Deep pink and soft red, dimmed.")],
    "focus": [t("Focus"), t("Bright, cool white for work.")],
    "night-light": [t("Night light"), t("A faint amber glow to find your way.")],
    "candle-flicker": [t("Candle flicker"), t("Warm amber, each light flickering on its own.")],
    "fireplace": [t("Fireplace"), t("Reds, oranges and amber dancing unevenly.")],
    "ocean": [t("Ocean"), t("Blues and teals rolling from light to light like waves.")],
    "northern-lights": [t("Northern lights"), t("Green, teal and violet drifting slowly.")],
    "breathing": [t("Breathing"), t("Soft light rising and falling in a six-second rhythm, to calm down.")],
    "sunset": [t("Sunset"), t("Ten minutes from golden yellow through orange and pink to a dim red.")],
    "sunrise": [t("Sunrise"), t("Fifteen minutes from a dim red glow to bright warm white, to wake up.")],
    "disco": [t("Disco"), t("Every light jumps to a vivid colour on each beat.")],
    "police": [t("Police siren"), t("Red and blue swapping from light to light.")],
    "rainbow-wave": [t("Rainbow wave"), t("The colour wheel passing from light to light.")],
    "lightning": [t("Lightning storm"), t("Dim stormy blue, with sudden white flashes.")],
    "halloween": [t("Halloween"), t("Purple and orange with an eerie flicker.")],
    "christmas": [t("Christmas"), t("Red and green taking turns, with a warm white twinkle now and then.")],
    "alert": [t("Alert flash"), t("Two red pulses, then the lights go back to how they were.")],
    "bedtime": [t("Bedtime"), t("A slow fade to a dim red over fifteen minutes.")],
  };
  const moodCategories = [["calm", t("Calm")], ["animated", t("Slow animations")], ["party", t("Party")], ["signal", t("Signals")]];
  const moodName = (id, name) => moodTexts[id]?.[0] ?? name;
  const moodRoomKey = "homeswift.moods.room";

  /// The rooms with a light in them, for the moods.
  function lightRooms(accessories) {
    const rooms = accessories.filter((a) => !a.hidden && a.room && a.services.some((s) => s.type === "Lightbulb")).map((a) => a.room);
    return [...new Set(rooms)].sort((a, b) => a.localeCompare(b, HomeswiftI18n.locale));
  }

  /// Moods for a room's lights: the rooms as chips, what plays now, a box where the Assistant writes one from a
  /// description, and the collection by kind. On a phone each kind is a row that swipes sideways, so the whole card
  /// fits on a screen and what a tap started shows next to the finger: the pill lights up while its mood plays.
  function moodsSection(accessories) {
    const section = el("section", { class: "moods" });
    const head = el("div", { class: "section-head" }, el("div", {}, el("h2", { text: t("Moods") }), el("span", { class: "muted", text: t("Ambiances and light shows for a room's lights.") })));
    const rooms = lightRooms(accessories);
    if (!rooms.length) {
      section.append(head, el("div", { class: "card empty" }, el("p", { class: "muted", text: t("Put your lights in rooms (a card's menu on the Accessories page) to play moods on them.") })));
      return section;
    }
    let room = rooms[0];
    try { const remembered = localStorage.getItem(moodRoomKey); if (rooms.includes(remembered)) room = remembered; } catch {}
    const roomChips = el("div", { class: "mood-rooms", role: "group", "aria-label": t("Room") }, rooms.map((name) => {
      const chip = el("button", { type: "button", class: "mood-room", text: name, "aria-pressed": String(name === room) });
      chip.addEventListener("click", () => {
        room = name;
        try { localStorage.setItem(moodRoomKey, name); } catch {}
        for (const other of roomChips.children) other.setAttribute("aria-pressed", String(other === chip));
        drawRunning(data.running);
        markPlaying();
      });
      return chip;
    }));
    const line = statusLine();
    const running = el("div", { class: "mood-running" });
    const collection = el("div", { class: "mood-collection" });
    const describe = el("input", { type: "text", maxLength: 500, enterKeyHint: "go", placeholder: t("Describe a mood…"), title: t("Describe one: a jazz bar, a rainy afternoon…"), "aria-label": t("Describe a mood") });
    const create = el("button", { type: "submit", class: "primary mood-create" }, sparkle(), el("span", { text: t("Create") }));
    const designer = el("form", { class: "mood-describe hidden" }, describe, create);
    section.append(head, el("div", { class: "card mood-card" }, roomChips, running, line, designer, collection));

    let data = { moods: [], running: [] };
    const buttons = new Map();
    let timer = null;

    /// The pills of the moods playing in the chosen room light up.
    function markPlaying() {
      const playing = new Set(data.running.filter((run) => run.room === room).map((run) => run.mood).filter(Boolean));
      for (const [id, button] of buttons) {
        button.classList.toggle("playing", playing.has(id));
        button.setAttribute("aria-pressed", String(playing.has(id)));
      }
    }

    async function refresh() {
      data = await app.api("/api/moods");
      drawRunning(data.running);
      markPlaying();
      // Look again just after the next one ends by itself.
      clearTimeout(timer);
      const next = Math.min(...data.running.map((run) => run.endsAt ? new Date(run.endsAt) - Date.now() : Infinity));
      if (Number.isFinite(next)) timer = setTimeout(() => { if (section.isConnected) refresh().catch(() => {}); }, Math.max(1000, next + 1500));
    }

    function drawRunning(runs) {
      running.replaceChildren(...runs.map((run) => {
        const name = moodName(run.mood, run.name);
        // A mood that set the lights once is undone; one that plays is stopped. Either way the lights go back.
        const stop = el("button", { type: "button", class: "mood-stop", text: run.held ? t("Undo") : t("Stop") });
        stop.addEventListener("click", async () => {
          stop.classList.add("busy");
          stop.disabled = true;
          try {
            await app.api("/api/moods/stop", { method: "POST", body: { run: run.id } });
            say(line, run.held ? t("{mood} undone: the lights are back as they were.", { mood: name }) : t("{mood} stopped: the lights are back as they were.", { mood: name }));
            await refresh();
          } catch (e) { say(line, e.message, "error"); stop.disabled = false; stop.classList.remove("busy"); }
        });
        const lights = tn("{n} light", "{n} lights", run.lights.length);
        // The room shows only when it is not the one chosen above.
        const where = run.room && run.room !== room ? t("{room}, {lights}", { room: run.room, lights }) : lights;
        return el("div", { class: "mood-run" }, swatch(run.mood),
          el("div", { class: "mood-run-text" }, el("strong", { text: name }),
            el("span", { class: "muted", text: run.held ? t("{lights}, set at {time}", { lights: where, time: timeFormat.format(new Date(run.startedAt)) })
              : run.endsAt ? t("{lights}, until {time}", { lights: where, time: timeFormat.format(new Date(run.endsAt)) }) : where })),
          stop);
      }));
    }

    function swatch(id) {
      const illustration = Object.hasOwn(moodTexts, id) ? id : "custom";
      return el("img", { class: "mood-swatch", src: `/mood-${illustration}.svg`, alt: "", "aria-hidden": "true" });
    }

    async function start(body, name, button) {
      if (button?.classList.contains("busy")) return;
      button?.classList.add("busy");
      say(line, body.description ? t("The Assistant is writing a mood…") : t("Starting {mood}…", { mood: name }));
      try {
        const result = await app.api("/api/moods/start", { method: "POST", body: { ...body, room } });
        const shown = body.mood ? name : result.mood.name;
        const count = result.lights.length;
        if (result.run && !result.run.held) {
          say(line, "");
        } else if (result.ok) {
          say(line, tn("{mood} is set on {n} light.", "{mood} is set on {n} lights.", count, { mood: shown }));
          line.append(" ", el("button", { type: "button", class: "link", text: t("Save as a scene"), onclick: () => saveAsScene(body.mood ? { mood: body.mood } : { plan: result.mood }, shown) }));
        } else {
          const failures = result.failed.map((f) => `${f.name}: ${HomeswiftI18n.message(f.error)}`).join("; ");
          say(line, t("{mood} is set, but not on every light: {failures}", { mood: shown, failures }), "error");
        }
        if (body.description) describe.value = "";
        await refresh();
      } catch (e) { say(line, e.message, "error"); } finally { button?.classList.remove("busy"); }
    }

    async function saveAsScene(source, name) {
      try {
        const scene = await app.api("/api/moods/save", { method: "POST", body: { ...source, room, name: t("{mood} in {room}", { mood: name, room }) } });
        say(line, t("Saved as the scene {name}.", { name: scene.name }));
        setTimeout(() => { if (section.isConnected) app.route(); }, 1200);
      } catch (e) { say(line, e.message, "error"); }
    }

    designer.addEventListener("submit", (event) => {
      event.preventDefault();
      const text = describe.value.trim();
      if (text) start({ description: text }, text, create);
    });

    (async () => {
      await refresh();
      designer.classList.toggle("hidden", !data.assistant);
      collection.replaceChildren(...moodCategories.map(([category, label]) => {
        const moods = data.moods.filter((mood) => mood.category === category);
        if (!moods.length) return null;
        return el("div", { class: "mood-group" }, el("div", { class: "service-name", text: label }),
          el("div", { class: "mood-buttons" }, moods.map((mood) => {
            const name = moodName(mood.id, mood.name);
            const button = el("button", { type: "button", class: "mood-button", title: moodTexts[mood.id]?.[1] ?? mood.description ?? "", "aria-pressed": "false" },
              swatch(mood.id), el("span", { text: name }));
            button.addEventListener("click", () => start({ mood: mood.id }, name, button));
            buttons.set(mood.id, button);
            return button;
          })));
      }).filter(Boolean));
      markPlaying();
    })().catch((e) => say(line, e.message, "error"));
    return section;
  }

  // ---- Scenes ----------------------------------------------------------------------------------------

  const timeFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit" });
  const dateTimeFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { dateStyle: "medium", timeStyle: "short" });

  function describeDays(days) {
    if (!days || !days.length || days.length === 7) return t("every day");
    const key = [...days].sort().join();
    if (key === "1,2,3,4,5") return t("on weekdays");
    if (key === "0,6") return t("at weekends");
    return t("on {days}", { days: days.map((d) => weekdays[d]).join(", ") });
  }
  /// "Sunset every day", "10 min before sunrise on weekdays".
  function describeSun(event, minutes, days) {
    const sunrise = event === "sunrise";
    const vars = { minutes: Math.abs(minutes || 0), days };
    if (!minutes) return sunrise ? t("Sunrise {days}", vars) : t("Sunset {days}", vars);
    if (minutes < 0) return sunrise ? t("{minutes} min before sunrise {days}", vars) : t("{minutes} min before sunset {days}", vars);
    return sunrise ? t("{minutes} min after sunrise {days}", vars) : t("{minutes} min after sunset {days}", vars);
  }
  function describeTrigger(trigger, names) {
    const text = (() => {
      switch (trigger.type) {
        case "time": return t("At {time} {days}", { time: trigger.at, days: describeDays(trigger.days) });
        case "sun": return describeSun(trigger.event, trigger.offsetMinutes, describeDays(trigger.days));
        case "cron": return t("Cron {expression}", { expression: trigger.cron });
        case "characteristic": {
          const vars = { who: names.get(trigger.id) || trigger.id, characteristic: trigger.characteristic };
          if (trigger.operator === "changes") return t("When {who} {characteristic} changes", vars);
          const comparison = operators.find(([o]) => o === trigger.operator)?.[1] ?? trigger.operator;
          return t("When {who} {characteristic} {comparison} {value}", { ...vars, comparison, value: String(trigger.value) });
        }
        default: return trigger.type;
      }
    })();
    return trigger.enabled === false ? t("{trigger} (off)", { trigger: text }) : text;
  }

  async function scenesView(main) {
    const [data, accessories] = await Promise.all([app.api("/api/scenes"), app.api("/api/accessories")]);
    const names = new Map(accessories.map((a) => [a.id, displayName(a)]));
    const card = (scene) => {
      const actions = scene.actions.slice(0, 4).map((action) => el("div", { class: "control" },
        el("span", { text: action.missing ? t("{name} (gone)", { name: action.name || action.id }) : action.name || action.id }),
        el("span", { class: "value", text: `${action.characteristic} → ${typeof action.value === "boolean" && !app.enumLabels[action.characteristic] ? (action.value ? t("On") : t("Off")) : app.labelFor(action.characteristic, action.value)}` })));
      const more = scene.actions.length > 4 ? el("p", { class: "muted note", text: tn("and {n} more", "and {n} more", scene.actions.length - 4) }) : null;
      const lastVars = scene.lastRun ? { date: dateTimeFormat.format(new Date(scene.lastRun.at)), trigger: scene.lastRun.trigger } : null;
      const last = scene.lastRun ? (scene.lastRun.ok ? t("Last run {date} ({trigger})", lastVars) : t("Last run {date} ({trigger}), with errors", lastVars)) : t("Never run");
      const run = el("button", { class: "primary", text: t("Run") });
      run.addEventListener("click", async () => { await runScene(scene, run); });
      return el("div", { class: "card server scene-card" },
        el("div", { class: "server-head" }, tile("play", scene.security ? "violet" : "orange"),
          el("div", { class: "who" }, el("a", { class: "card-title", href: `/scenes/${encodeURIComponent(scene.id)}` }, el("strong", { text: scene.name })),
            el("div", { class: "muted", text: scene.triggers.length ? scene.triggers.map((trigger) => describeTrigger(trigger, names)).join(" · ") : t("Run by hand") })),
          run),
        el("div", { class: "controls" }, actions), more,
        scene.security ? el("p", { class: "muted note", text: t("It changes a lock, a door or an alarm: the page asks before running it, and automations leave those actions out.") }) : null,
        el("div", { class: "card-foot" }, el("span", { class: "muted", text: scene.lastSkipped && (!scene.lastRun || scene.lastSkipped.at > scene.lastRun.at) ? t("Skipped {date}: {reason}", { date: dateTimeFormat.format(new Date(scene.lastSkipped.at)), reason: HomeswiftI18n.message(scene.lastSkipped.reason) }) : last }),
          menuButton(t("Actions for {name}", { name: scene.name }), () => [
            { label: t("Run"), icon: "play", onSelect: () => runScene(scene) },
            { label: t("Edit"), icon: "edit", href: `/scenes/${encodeURIComponent(scene.id)}` },
            { label: t("Delete"), icon: "trash", danger: true, onSelect: async () => {
              if (!confirm(t("Delete the scene {name}?", { name: scene.name }))) return;
              try { await app.api(`/api/scenes/${encodeURIComponent(scene.id)}`, { method: "DELETE" }); app.route(); } catch (e) { alert(e.message); }
            } },
          ])));
    };
    app.show(main,
      app.pageHead(t("Scenes"), t("Accessory values set together, by hand or on a schedule, at sunrise or sunset, or when an accessory changes. Homeswift keeps them; the Home app does not see them."),
        el("a", { class: "button primary", href: "/scenes/new", text: t("New scene") })),
      moodsSection(accessories),
      el("div", { class: "section-head" }, el("h2", { text: t("Your scenes") })),
      data.scenes.length ? el("div", { class: "grid" }, data.scenes.map(card))
        : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("play")), el("p", { class: "muted", text: t("No scene yet. A scene sets several accessories at once, such as every light of a room for the evening.") })),
      locationCard(data));
  }

  /// Where sunrise and sunset are computed for: Glass UI took its weather widget's city; here it is typed, or
  /// this device's position.
  function locationCard(data) {
    const location = data.location;
    const lat = el("input", { type: "number", step: "any", min: -90, max: 90, value: location?.lat ?? "", "aria-label": t("Latitude") });
    const lon = el("input", { type: "number", step: "any", min: -180, max: 180, value: location?.lon ?? "", "aria-label": t("Longitude") });
    const name = el("input", { type: "text", value: location?.name ?? "", placeholder: t("My home"), maxLength: 64 });
    const line = statusLine();
    const save = async (body) => {
      try { await app.api("/api/scenes/location", { method: "PUT", body }); app.route(); } catch (e) { say(line, e.message, "error"); }
    };
    const here = el("button", { text: t("Use this device's location"), onclick: () => {
      if (!navigator.geolocation) return say(line, t("This browser cannot tell its location."), "error");
      say(line, t("Asking the browser…"));
      navigator.geolocation.getCurrentPosition(
        (position) => { lat.value = position.coords.latitude.toFixed(4); lon.value = position.coords.longitude.toFixed(4); say(line, t("Found: save to keep it.")); },
        (error) => say(line, error.message || t("The browser did not give its location (it needs HTTPS away from localhost)."), "error"));
    } });
    const next = location ? t("Next sunrise {sunrise}, sunset {sunset}.", { sunrise: data.nextSunrise ? timeFormat.format(new Date(data.nextSunrise)) : "—", sunset: data.nextSunset ? timeFormat.format(new Date(data.nextSunset)) : "—" }) : t("No location yet: sunrise and sunset triggers wait for one.");
    return el("details", { class: "card location", open: !location && data.scenes.some((s) => s.triggers.some((trigger) => trigger.type === "sun")) },
      el("summary", {}, el("strong", { text: t("Location for sunrise and sunset") }), el("span", { class: "muted", text: ` · ${location ? (location.name || `${location.lat}, ${location.lon}`) : t("not set")}` })),
      el("p", { class: "muted", text: next }),
      el("div", { class: "fields" }, field(t("Latitude"), lat), field(t("Longitude"), lon), field(t("Name"), name, t("Only for you to recognise it."))),
      el("div", { class: "actions" },
        el("button", { class: "primary", text: t("Save"), onclick: () => save({ lat: Number(lat.value), lon: Number(lon.value), name: name.value }) }),
        here, location ? el("button", { class: "link", text: t("Forget it"), onclick: () => save(null) }) : null),
      line);
  }

  /// The characteristics of an accessory a scene can set: writable, not HomeKit's plumbing.
  function writable(accessory) {
    return accessory.services.filter((s) => !s.internal).flatMap((service) => service.characteristics
      .filter((c) => c.permissions.includes("pw") && c.permissions.includes("pr") && !c.internal && !["Identify", "Name", "Configured Name"].includes(c.type))
      .map((c) => ({ ...c, service: service.subtype || service.type, serviceName: service.name || service.type })));
  }
  function readable(accessory) {
    return accessory.services.filter((s) => !s.internal).flatMap((service) => service.characteristics
      .filter((c) => c.permissions.includes("pr") && !c.internal && !c.confidential && !["Identify", "Name", "Configured Name"].includes(c.type))
      .map((c) => ({ ...c, service: service.subtype || service.type, serviceName: service.name || service.type })));
  }

  /// An input for a characteristic's value: a menu for booleans and enumerations, a number within its range,
  /// else text. `.read()` gives the value to save.
  function valueInput(characteristic, value) {
    const labels = app.enumLabels[characteristic?.type];
    let input;
    if (characteristic?.format === "bool") {
      input = el("select", {}, el("option", { value: "true", text: t("On") }), el("option", { value: "false", text: t("Off") }));
      input.value = String(value === true || value === 1);
      input.read = () => input.value === "true";
    } else if (characteristic && (characteristic.validValues || labels)) {
      const values = characteristic.validValues || labels.map((_, index) => index);
      input = el("select", {}, values.map((v) => el("option", { value: v, text: app.labelFor(characteristic.type, v) })));
      input.value = String(value ?? values[0]);
      input.read = () => Number(input.value);
    } else if (characteristic && characteristic.format !== "string") {
      input = el("input", { type: "number", min: characteristic.minValue, max: characteristic.maxValue, step: characteristic.minStep || "any", value: value ?? characteristic.value ?? 0 });
      input.read = () => Number(input.value);
    } else {
      input = el("input", { type: "text", value: value ?? "", maxLength: 256 });
      // An accessory that is gone keeps its value as it was saved.
      input.read = () => !characteristic && input.value === String(value ?? "") && value !== undefined ? value : input.value;
    }
    input.setAttribute("aria-label", t("Value"));
    return input;
  }

  /// An accessory and one of its characteristics, with a value input after them when `withValue`.
  function characteristicPicker(accessories, pick, { id, characteristic, value, withValue = true, list = writable }) {
    const options = accessories.filter((a) => list(a).length);
    const accessory = el("select", { "aria-label": t("Accessory") }, options.map((a) => el("option", { value: a.id, text: displayName(a) })));
    const kind = el("select", { "aria-label": t("Characteristic") });
    const holder = el("span", { class: "value-slot" });
    let current = null;
    const fill = (keepType, keepValue) => {
      const found = options.find((a) => a.id === accessory.value);
      const chars = found ? list(found) : [];
      kind.replaceChildren(...chars.map((c, index) => el("option", { value: index, text: chars.filter((x) => x.type === c.type).length > 1 ? `${c.type} (${c.serviceName})` : c.type })));
      // An accessory that is gone keeps the characteristic it was saved with.
      if (!chars.length && (keepType ?? characteristic)) kind.append(el("option", { value: 0, text: keepType ?? characteristic }));
      const index = Math.max(0, chars.findIndex((c) => c.type === keepType));
      kind.value = String(index);
      current = chars[index] || null;
      if (withValue) { holder.replaceChildren(pick.value = valueInput(current, keepValue ?? current?.value)); }
    };
    if (id && options.some((a) => a.id === id)) accessory.value = id;
    else if (id) accessory.prepend(el("option", { value: id, text: t("{name} (gone)", { name: id }), selected: true }));
    fill(characteristic, value);
    accessory.addEventListener("change", () => fill());
    kind.addEventListener("change", () => {
      const found = options.find((a) => a.id === accessory.value);
      current = found ? list(found)[Number(kind.value)] : null;
      if (withValue) holder.replaceChildren(pick.value = valueInput(current, current?.value));
    });
    pick.read = () => {
      const found = options.find((a) => a.id === accessory.value);
      if (!found || !current) return { id: accessory.value, characteristic: characteristic || "" };
      const several = list(found).filter((c) => c.type === current.type).length > 1;
      return { id: found.id, characteristic: current.type, ...(several ? { service: current.service } : {}) };
    };
    pick.current = () => current;
    return [accessory, kind, holder];
  }

  const rowShell = (...children) => el("div", { class: "editor-row" }, ...children);
  const removeButton = (row, list) => el("button", { class: "icon-button", type: "button", title: t("Remove"), "aria-label": t("Remove"), onclick: () => { list.delete(row); row.remove(); } }, HomeswiftCommon.icon("trash"));

  function daysPicker(days) {
    const chosen = new Set(days && days.length ? days : [0, 1, 2, 3, 4, 5, 6]);
    const node = el("span", { class: "days", role: "group", "aria-label": t("Days") }, weekdays.map((name, day) => {
      const box = el("input", { type: "checkbox", checked: chosen.has(day), "aria-label": name });
      box.addEventListener("change", () => { if (box.checked) chosen.add(day); else chosen.delete(day); });
      return el("label", { class: "day" }, box, el("span", { text: dayLetters[day] }));
    }));
    node.read = () => chosen.size === 7 || chosen.size === 0 ? undefined : [...chosen].sort();
    return node;
  }

  function timeOfDay(value) {
    const sun = ["sunrise", "sunset"].includes(value);
    const kind = el("select", { "aria-label": t("When") }, el("option", { value: "time", text: t("At") }), el("option", { value: "sunrise", text: t("Sunrise") }), el("option", { value: "sunset", text: t("Sunset") }));
    kind.value = sun ? value : "time";
    const time = el("input", { type: "time", value: sun ? "00:00" : value || "18:00", "aria-label": t("Time") });
    time.classList.toggle("hidden", sun);
    kind.addEventListener("change", () => time.classList.toggle("hidden", kind.value !== "time"));
    const node = el("span", { class: "group-inline" }, kind, time);
    node.read = () => kind.value === "time" ? time.value : kind.value;
    return node;
  }

  async function sceneEditor(main, id) {
    const isNew = id === "new";
    const [data, accessories] = await Promise.all([app.api("/api/scenes"), app.api("/api/accessories")]);
    const scene = isNew ? { name: "", actions: [], triggers: [], conditions: [] } : data.scenes.find((s) => s.id === id);
    if (!scene) { app.show(main, el("p", { class: "error", text: t("No such scene.") })); return; }
    const choices = accessories.filter((a) => !a.hidden || scene.actions.some((x) => x.id === a.id));

    const name = el("input", { type: "text", value: scene.name, maxLength: 64, required: true, placeholder: t("Evening") });
    const actions = new Set(), triggers = new Set(), conditions = new Set();
    const actionList = el("div", { class: "editor-list" }), triggerList = el("div", { class: "editor-list" }), conditionList = el("div", { class: "editor-list" });

    const addAction = (action = {}) => {
      const pick = {};
      const row = rowShell(...characteristicPicker(choices, pick, { id: action.id, characteristic: action.characteristic, value: action.value }));
      row.read = () => ({ ...pick.read(), value: pick.value.read() });
      row.append(removeButton(row, actions));
      actions.add(row);
      actionList.append(row);
    };
    const addTrigger = (trigger = { type: "time", at: "18:00" }) => {
      const type = el("select", { "aria-label": t("Trigger") },
        el("option", { value: "time", text: t("At a time") }), el("option", { value: "sun", text: t("Sunrise or sunset") }),
        el("option", { value: "characteristic", text: t("When an accessory changes") }), el("option", { value: "cron", text: t("Cron") }));
      type.value = trigger.type;
      const enabled = el("input", { type: "checkbox", checked: trigger.enabled !== false, "aria-label": t("On [setting]") });
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(type, body, el("label", { class: "toggle compact" }, enabled, el("span", { text: t("On [setting]") })));
      const draw = (shown) => {
        if (shown.type === "time") {
          const at = el("input", { type: "time", value: shown.at || "18:00", "aria-label": t("Time") });
          const days = daysPicker(shown.days);
          body.replaceChildren(at, days);
          row.readBody = () => ({ at: at.value, days: days.read() });
        } else if (shown.type === "sun") {
          const event = el("select", { "aria-label": t("Event") }, el("option", { value: "sunrise", text: t("Sunrise") }), el("option", { value: "sunset", text: t("Sunset") }));
          event.value = shown.event || "sunset";
          const offset = el("input", { type: "number", min: -720, max: 720, step: 1, value: shown.offsetMinutes ?? 0, "aria-label": t("Minutes after (negative: before)"), title: t("Minutes after; negative for before") });
          const days = daysPicker(shown.days);
          body.replaceChildren(event, offset, el("span", { class: "muted", text: "min" }), days);
          row.readBody = () => ({ event: event.value, offsetMinutes: Number(offset.value) || 0, days: days.read() });
        } else if (shown.type === "characteristic") {
          const pick = {};
          const operator = el("select", { "aria-label": t("Condition") }, el("option", { value: "changes", text: t("changes") }), operators.map(([value, text]) => el("option", { value, text })));
          operator.value = shown.operator || "changes";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: shown.id, characteristic: shown.characteristic, value: shown.value, list: readable });
          holder.classList.toggle("hidden", operator.value === "changes");
          operator.addEventListener("change", () => holder.classList.toggle("hidden", operator.value === "changes"));
          body.replaceChildren(accessory, kind, operator, holder);
          row.readBody = () => ({ ...pick.read(), operator: operator.value, ...(operator.value === "changes" ? {} : { value: pick.value.read() }) });
        } else {
          const cron = el("input", { type: "text", value: shown.cron || "0 7 * * 1-5", placeholder: "0 7 * * 1-5", "aria-label": t("Cron expression"), class: "mono" });
          body.replaceChildren(cron);
          row.readBody = () => ({ cron: cron.value });
        }
      };
      draw(trigger);
      type.addEventListener("change", () => draw({ type: type.value }));
      row.read = () => ({ type: type.value, ...(enabled.checked ? {} : { enabled: false }), ...row.readBody() });
      row.append(removeButton(row, triggers));
      triggers.add(row);
      triggerList.append(row);
    };
    const addCondition = (condition = { type: "time", after: "sunset", before: "23:00" }) => {
      const type = el("select", { "aria-label": t("Condition") }, el("option", { value: "time", text: t("Between") }), el("option", { value: "characteristic", text: t("Only if") }));
      type.value = condition.type;
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(type, body);
      const draw = (c) => {
        if (c.type === "time") {
          const after = timeOfDay(c.after || "sunset"), before = timeOfDay(c.before || "23:00");
          body.replaceChildren(after, el("span", { class: "muted", text: t("and") }), before);
          row.readBody = () => ({ after: after.read(), before: before.read() });
        } else {
          const pick = {};
          const operator = el("select", { "aria-label": t("Comparison") }, operators.map(([value, text]) => el("option", { value, text })));
          operator.value = c.operator || "eq";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: c.id, characteristic: c.characteristic, value: c.value, list: readable });
          body.replaceChildren(accessory, kind, operator, holder);
          row.readBody = () => ({ ...pick.read(), operator: operator.value, value: pick.value.read() });
        }
      };
      draw(condition);
      type.addEventListener("change", () => draw({ type: type.value }));
      row.read = () => ({ type: type.value, ...row.readBody() });
      row.append(removeButton(row, conditions));
      conditions.add(row);
      conditionList.append(row);
    };
    scene.actions.forEach(addAction);
    scene.triggers.forEach(addTrigger);
    scene.conditions.forEach(addCondition);
    if (isNew && choices.length) addAction();

    // A whole accessory's current state at once, as save_scene captures it.
    const capture = el("select", { "aria-label": t("Add the current state of an accessory") }, el("option", { value: "", text: t("Add an accessory as it is now…") }),
      choices.filter((a) => writable(a).length).map((a) => el("option", { value: a.id, text: displayName(a) })));
    capture.addEventListener("change", () => {
      const accessory = choices.find((a) => a.id === capture.value);
      capture.value = "";
      if (!accessory) return;
      for (const c of writable(accessory)) if (!c.security && c.value !== null && c.value !== undefined) addAction({ id: accessory.id, characteristic: c.type, value: c.value });
    });

    const line = statusLine();
    const save = el("button", { class: "primary", type: "submit", text: isNew ? t("Create the scene") : t("Save") });
    const form = el("form", { class: "card scene-editor", onsubmit: async (event) => {
      event.preventDefault();
      const body = { name: name.value.trim(), actions: [...actions].map((row) => row.read()), triggers: [...triggers].map((row) => row.read()), conditions: [...conditions].map((row) => row.read()) };
      save.disabled = true;
      try {
        const saved = await app.api(isNew ? "/api/scenes" : `/api/scenes/${encodeURIComponent(scene.id)}`, { method: isNew ? "POST" : "PUT", body });
        const security = saved.actions.some((a) => a.security);
        if (security && body.triggers.some((trigger) => trigger.enabled !== false)) {
          say(line, t("Saved. Its lock, door or alarm actions run only when you run it here: automations leave them out."), "ok");
          if (isNew) setTimeout(() => app.navigate(`/scenes/${encodeURIComponent(saved.id)}`, { replace: true }), 1500);
        } else {
          app.navigate("/scenes");
        }
      } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    } },
      field(t("Name"), name),
      el("h2", { text: t("Actions") }), el("p", { class: "muted", text: t("The values to set, in this order.") }), actionList,
      el("div", { class: "actions" }, el("button", { type: "button", text: t("Add an action"), onclick: () => addAction() }), capture),
      el("h2", { text: t("Triggers") }), el("p", { class: "muted", text: data.location ? t("Run it automatically. Sunrise and sunset are for {place}.", { place: data.location.name || `${data.location.lat}, ${data.location.lon}` }) : t("Run it automatically. Sunrise and sunset need a location: set it on the Scenes page.") }),
      triggerList, el("div", { class: "actions" }, el("button", { type: "button", text: t("Add a trigger"), onclick: () => addTrigger() })),
      el("h2", { text: t("Conditions") }), el("p", { class: "muted", text: t("An automatic run goes ahead only when all of these hold. Running it by hand ignores them.") }),
      conditionList, el("div", { class: "actions" }, el("button", { type: "button", text: t("Add a condition"), onclick: () => addCondition() })),
      el("div", { class: "save-bar" }, save, el("a", { class: "button", href: "/scenes", text: t("Cancel") }),
        isNew ? null : el("span", { class: "spacer" }),
        isNew ? null : el("button", { type: "button", class: "danger", text: t("Delete"), onclick: async () => {
          if (!confirm(t("Delete the scene {name}?", { name: scene.name }))) return;
          try { await app.api(`/api/scenes/${encodeURIComponent(scene.id)}`, { method: "DELETE" }); app.navigate("/scenes"); } catch (e) { say(line, e.message, "error"); }
        } })),
      line);
    app.show(main, app.breadcrumb([t("Scenes"), "/scenes"], [isNew ? t("New scene") : scene.name]), form);
  }

  // ---- Notifications ---------------------------------------------------------------------------------

  const channelInfo = {
    webhook: [t("Webhook"), t("A JSON POST to a URL of yours: event, title, message, instance, timestamp."), [["url", t("URL"), "https://…", true]]],
    ntfy: ["ntfy", t("A topic on ntfy.sh or your own ntfy server; the app shows it on a phone."), [["server", t("Server"), "https://ntfy.sh"], ["topic", t("Topic"), "homeswift-…"], ["token", t("Access token"), t("for a protected topic"), true]]],
    pushover: ["Pushover", t("Your user key and an application token from pushover.net."), [["userKey", t("User key"), "", true], ["appToken", t("Application token"), "", true]]],
    telegram: ["Telegram", t("A bot's token from @BotFather, and the chat it writes to."), [["botToken", t("Bot token"), "123456:ABC…", true], ["chatId", t("Chat id"), t("-100… or @channel")]]],
    browser: [t("This browser and others"), t("Web Push to the browsers that turned it on below. It needs HTTPS (or localhost)."), []],
  };

  /// A short name for this browser: "Safari on macOS".
  function browserLabel() {
    const ua = navigator.userAgent;
    const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
    const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
    return os ? `${browser} on ${os}` : browser;
  }
  const keyBytes = (base64url) => Uint8Array.from(atob(base64url.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((base64url.length + 3) % 4)), (c) => c.charCodeAt(0));
  const pushSupported = () => window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

  async function currentSubscription() {
    if (!pushSupported()) return null;
    const registration = await navigator.serviceWorker.getRegistration("/");
    return registration ? registration.pushManager.getSubscription() : null;
  }

  async function notificationsView(main) {
    const settings = await app.api("/api/notifications");
    const line = statusLine();
    const inputs = {};
    const test = async (channel) => {
      say(line, t("Sending…"));
      try {
        const answer = await app.api("/api/notifications/test", { method: "POST", body: channel ? { channel } : {} });
        const failed = answer.results.filter((r) => !r.ok);
        say(line, failed.length ? failed.map((r) => `${r.channel}: ${HomeswiftI18n.message(r.error)}`).join("; ") : t("Sent through {channels}.", { channels: answer.results.map((r) => r.channel).join(", ") }), failed.length ? "error" : "ok");
      } catch (e) { say(line, e.message, "error"); }
    };
    const cards = Object.entries(channelInfo).map(([channel, [title, help, fields]]) => {
      const values = settings.channels[channel];
      const enabled = el("input", { type: "checkbox", checked: values.enabled, "aria-label": t("{channel} on", { channel: title }) });
      inputs[channel] = { enabled };
      const rows = fields.map(([key, label, placeholder, secret]) => {
        const input = el("input", { type: secret ? "password" : "text", value: values[key] ?? "", placeholder, autocomplete: "off", spellcheck: false });
        inputs[channel][key] = input;
        return field(label, input);
      });
      return el("div", { class: "card server" },
        el("div", { class: "server-head" }, tile(channel === "browser" ? "accessory" : "bell", channel === "browser" ? "blue" : "orange"),
          el("div", { class: "who" }, el("strong", { text: title })),
          el("label", { class: "switch" }, enabled, el("span"))),
        el("p", { class: "muted note", text: help }),
        rows.length ? el("div", {}, rows) : browserPanel(settings),
        el("div", { class: "card-foot" }, el("span", { class: "muted", text: values.enabled ? t("On [setting]") : t("Off [setting]") }),
          menuButton(t("Actions for {name}", { name: title }), () => [{ label: t("Send a test"), icon: "bell", onSelect: () => test(channel) }])));
    });
    const events = settings.events.map((event) => {
      const box = el("input", { type: "checkbox", checked: event.enabled });
      box.dataset.event = event.name;
      return el("label", { class: "toggle" }, box, el("span", {}, el("span", { text: HomeswiftI18n.message(event.label) }),
        event.name === "dailyDigest" && !settings.assistant ? el("span", { class: "help", text: t("Needs the Assistant (a HomeswiftAiKit block).") }) : null));
    });
    const digestTime = el("input", { type: "time", value: settings.dailyDigestTime, "aria-label": t("Daily digest time") });
    const save = el("button", { class: "primary", text: t("Save") });
    save.addEventListener("click", async () => {
      const channels = {};
      for (const [channel, fields] of Object.entries(inputs)) {
        channels[channel] = {};
        for (const [key, input] of Object.entries(fields)) channels[channel][key] = input.type === "checkbox" ? input.checked : input.value;
      }
      const body = { channels, events: Object.fromEntries([...main.querySelectorAll("[data-event]")].map((box) => [box.dataset.event, box.checked])), dailyDigestTime: digestTime.value };
      save.disabled = true;
      try { await app.api("/api/notifications", { method: "PUT", body }); say(line, t("Saved."), "ok"); } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    });
    app.show(main,
      app.pageHead(t("Notifications"), t("What the bridge tells you when you are not looking: it started or stopped, a plugin reported an error, an accessory stopped responding, an automation failed.")),
      el("div", { class: "grid" }, cards),
      el("div", { class: "card" }, el("h2", { text: t("Events") }),
        el("p", { class: "muted", text: t("The same event about the same thing goes out once per 15 minutes at most, and 12 notifications an hour at most.") }),
        events, field(t("Daily digest at"), digestTime)),
      el("div", { class: "save-bar" }, save, el("button", { text: t("Send a test to every channel that is on"), onclick: () => test() })), line);
  }

  /// This browser's subscription and the others'.
  function browserPanel(settings) {
    const box = el("div", { class: "push" });
    const line = statusLine();
    const others = el("div", {}, settings.subscriptions.map((sub) => el("div", { class: "control" },
      el("span", { text: `${sub.label}${sub.username ? ` · ${sub.username}` : ""}` }),
      el("button", { class: "link", text: t("Remove"), onclick: async () => {
        try { await app.api(`/api/notifications/push/subscriptions/${encodeURIComponent(sub.id)}`, { method: "DELETE" }); app.route(); } catch (e) { say(line, e.message, "error"); }
      } }))));
    if (!pushSupported()) {
      box.append(el("p", { class: "muted note", text: window.isSecureContext ? t("This browser cannot receive push notifications.") : t("Open this page over HTTPS (the HomeswiftUI block's https) or on localhost to turn them on here.") }), others);
      return box;
    }
    const toggle = el("button", { text: t("Checking…"), disabled: true });
    const draw = (subscription) => {
      toggle.disabled = false;
      toggle.textContent = subscription ? t("Turn off on this browser") : t("Turn on for this browser");
      toggle.onclick = async () => {
        toggle.disabled = true;
        try {
          if (subscription) {
            await app.api("/api/notifications/push/unsubscribe", { method: "POST", body: { endpoint: subscription.endpoint } });
            await subscription.unsubscribe();
          } else {
            if (await Notification.requestPermission() !== "granted") throw new Error(t("The browser's notifications are blocked for this site."));
            const registration = await navigator.serviceWorker.register("/sw.js");
            await navigator.serviceWorker.ready;
            const { publicKey } = await app.api("/api/notifications/push");
            const created = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(publicKey) });
            await app.api("/api/notifications/push/subscribe", { method: "POST", body: { ...created.toJSON(), label: browserLabel() } });
          }
          app.route();
        } catch (e) { say(line, e.message, "error"); toggle.disabled = false; }
      };
    };
    currentSubscription().then(draw).catch(() => draw(null));
    const testHere = el("button", { class: "link", text: t("Send a test here"), onclick: async () => {
      const subscription = await currentSubscription();
      if (!subscription) return say(line, t("This browser is not subscribed."), "error");
      try {
        const answer = await app.api("/api/notifications/push/test", { method: "POST", body: { endpoint: subscription.endpoint } });
        const result = answer.results[0];
        say(line, result.ok ? t("Sent.") : HomeswiftI18n.message(result.error), result.ok ? "ok" : "error");
      } catch (e) { say(line, e.message, "error"); }
    } });
    box.append(el("div", { class: "actions" }, toggle, testHere), others, line);
    return box;
  }

  // ---- Installing ------------------------------------------------------------------------------------

  window.HomeswiftHome = {
    install(context) {
      app = context;
      app.views.scenes = (main, [id]) => id ? sceneEditor(main, id) : scenesView(main);
      app.views.notifications = notificationsView;
      app.views.quick = async (main) => app.show(main, app.pageHead(t("Quick controls"), t("Your favourite accessories and the scenes, at hand.")), quickSection(null, { standalone: true }));
    },
    layoutActions, groupByRoom, suggestRooms, quickSection, displayName,
  };
})();
