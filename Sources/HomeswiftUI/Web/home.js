// Rooms and hidden accessories, the Quick Controls, scenes and their automations, and notifications: the views
// ported from Glass UI. app.js hands its helpers over with install() before the first view is drawn.
(() => {
  "use strict";

  const { $, el, tile, sparkle, menuButton, fact } = HomeswiftCommon;
  let app = null;

  const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const operators = [["eq", "is"], ["neq", "is not"], ["gt", "is above"], ["gte", "is at least"], ["lt", "is below"], ["lte", "is at most"]];
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
      { label: accessory.room ? `Room: ${accessory.room}…` : "Put in a room…", icon: "room", onSelect: () => chooseRoom(accessory, change) },
      { label: "Name on these pages…", icon: "edit", onSelect: () => {
        const name = prompt(`A name for ${accessory.name} on these pages (the Home app keeps its own). Empty goes back to ${accessory.name}.`, accessory.displayName || "");
        if (name !== null) change({ name: name.trim() || null });
      } },
      { label: accessory.favourite ? "Remove from Quick Controls" : "Add to Quick Controls", icon: "star", onSelect: () => change({ favourite: !accessory.favourite }) },
      { label: accessory.hidden ? "Show it again" : "Hide", icon: "eye", onSelect: () => change({ hidden: !accessory.hidden }) },
    ];
  }

  async function chooseRoom(accessory, change) {
    let rooms = [];
    try { rooms = (await app.api("/api/rooms")).rooms.map((room) => room.name); } catch {}
    const known = rooms.length ? ` Rooms: ${rooms.join(", ")}.` : "";
    const room = prompt(`The room of ${displayName(accessory)}.${known} A new name adds the room; empty takes it out of its room.`, accessory.room || "");
    if (room !== null) change({ room: room.trim() || null });
  }

  /// The Accessories page's accessories by room, in the layout's order; those in no room last.
  function groupByRoom(accessories, rooms) {
    const byName = (a, b) => displayName(a).localeCompare(displayName(b));
    const groups = rooms.map((room) => [room, accessories.filter((a) => a.room === room).sort(byName)]).filter(([, list]) => list.length);
    const rest = accessories.filter((a) => !a.room || !rooms.includes(a.room)).sort(byName);
    return rest.length ? [...groups, [groups.length ? "No room" : "Accessories", rest]] : groups;
  }

  /// The Assistant's rooms and names, to review: each suggestion can be kept or left; Apply saves what is kept.
  /// Names go to these pages only; HomeKit and the Home app keep theirs.
  async function suggestRooms(host, accessories) {
    host.querySelector(".suggest")?.remove();
    const panel = el("div", { class: "card panel suggest" },
      el("div", { class: "panel-head" }, el("div", {}, el("h2", {}, sparkle(), " Suggested rooms"), el("p", { class: "muted", text: "The Assistant is sorting your accessories into rooms…" }))));
    host.prepend(panel);
    panel.classList.add("ai-busy");
    let result;
    try {
      result = await app.api("/api/rooms/suggest", { method: "POST", body: {} });
    } catch (e) {
      panel.replaceChildren(el("p", { class: "error", text: e.message }), el("div", { class: "actions" }, el("button", { text: "Close", onclick: () => panel.remove() })));
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
        const moved = accessory?.room && accessory.room !== room.name ? `now in ${accessory.room}` : accessory?.room === room.name ? "already there" : null;
        return check({ id, room: room.name }, accessory ? displayName(accessory) : id, moved);
      })));
    const renames = result.renames.map((rename) => check({ id: rename.id, name: rename.name }, `${rename.current} → ${rename.name}`, rename.reason));
    const orphans = result.orphans.map((orphan) => el("li", {}, el("strong", { text: orphan.name }), ` ${orphan.reason}`));
    const line = statusLine();
    const apply = el("button", { class: "primary", text: "Apply what is ticked", onclick: async () => {
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
        el("div", {}, el("h2", {}, sparkle(), " Suggested rooms"),
          el("p", { class: "muted", text: `From ${result.model}. Untick what you do not want; nothing changes until you apply. Names show on these pages only: the Home app keeps its own.` })),
        el("button", { class: "link", text: "Dismiss", onclick: () => panel.remove() })),
      rooms.length ? el("div", { class: "suggest-rooms" }, rooms) : el("p", { class: "muted", text: "No room to suggest." }),
      renames.length ? el("div", {}, el("div", { class: "service-name", text: "Clearer names" }), renames) : null,
      orphans.length ? el("div", {}, el("div", { class: "service-name", text: "Worth a look" }), el("ul", { class: "help" }, orphans)) : null,
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
        if (standalone) section.append(el("div", { class: "card empty" }, el("p", { class: "muted", text: "Nothing here yet. On the Accessories page, a card's menu adds it to the Quick Controls; scenes you make show here too." })));
        return;
      }
      const rooms = [...new Set(favourites.map((a) => a.room).filter(Boolean))];
      section.append(
        standalone ? null : el("div", { class: "section-head" }, el("h2", { text: "Quick controls" }), el("a", { href: "/quick", class: "muted", text: "Open on its own" })),
        scenes.length ? el("div", { class: "quick-scenes" }, scenes.map((scene) => sceneButton(scene))) : null,
        groupByRoom(favourites, rooms).map(([room, members]) => [
          rooms.length ? el("div", { class: "service-name", text: room }) : null,
          el("div", { class: "grid" }, members.map(app.accessoryCard)),
        ]));
    })().catch((e) => section.append(el("p", { class: "error", text: e.message })));
    return section;
  }

  function sceneButton(scene) {
    const button = el("button", { class: "scene-run", title: `Run ${scene.name}` }, tile("play", scene.security ? "violet" : "orange"), el("span", { text: scene.name }));
    button.addEventListener("click", () => runScene(scene, button));
    return button;
  }

  /// Runs a scene; one that changes a lock, a door or an alarm asks first, as the cards' own controls do.
  async function runScene(scene, button) {
    let confirmSecurity = false;
    if (scene.security) {
      const which = scene.actions.filter((a) => a.security).map((a) => `${a.name || a.id}: ${a.characteristic}`).join(", ");
      if (!confirm(`${scene.name} changes a lock, a door or an alarm (${which}). Run it?`)) return;
      confirmSecurity = true;
    }
    button?.classList.add("busy");
    if (button) button.disabled = true;
    try {
      const result = await app.api(`/api/scenes/${encodeURIComponent(scene.id)}/run`, { method: "POST", body: { confirmSecurity } });
      if (!result.ok) {
        const failures = result.results.filter((r) => !r.ok).map((r) => `${r.name || r.id} ${r.characteristic}: ${r.error || r.skipped}`);
        alert(`${scene.name} ran, but not everything worked:\n${failures.join("\n")}`);
      }
      return result;
    } catch (e) { alert(e.message); } finally {
      button?.classList.remove("busy");
      if (button) button.disabled = false;
    }
  }

  // ---- Scenes ----------------------------------------------------------------------------------------

  const timeFormat = new Intl.DateTimeFormat([], { hour: "2-digit", minute: "2-digit" });
  const dateTimeFormat = new Intl.DateTimeFormat([], { dateStyle: "medium", timeStyle: "short" });

  function describeDays(days) {
    if (!days || !days.length || days.length === 7) return "every day";
    const key = [...days].sort().join();
    if (key === "1,2,3,4,5") return "on weekdays";
    if (key === "0,6") return "at weekends";
    return `on ${days.map((d) => weekdays[d]).join(", ")}`;
  }
  function describeOffset(minutes) {
    if (!minutes) return "";
    return `${Math.abs(minutes)} min ${minutes < 0 ? "before" : "after"} `;
  }
  function describeTrigger(trigger, names) {
    const off = trigger.enabled === false ? " (off)" : "";
    switch (trigger.type) {
      case "time": return `At ${trigger.at} ${describeDays(trigger.days)}${off}`;
      case "sun": return `${describeOffset(trigger.offsetMinutes)}${trigger.event} ${describeDays(trigger.days)}${off}`.replace(/^./, (c) => c.toUpperCase());
      case "cron": return `Cron ${trigger.cron}${off}`;
      case "characteristic": {
        const who = names.get(trigger.id) || trigger.id;
        const how = trigger.operator === "changes" ? "changes" : `${operators.find(([o]) => o === trigger.operator)?.[1] ?? trigger.operator} ${trigger.value}`;
        return `When ${who} ${trigger.characteristic} ${how}${off}`;
      }
      default: return trigger.type;
    }
  }

  async function scenesView(main) {
    const [data, accessories] = await Promise.all([app.api("/api/scenes"), app.api("/api/accessories")]);
    const names = new Map(accessories.map((a) => [a.id, displayName(a)]));
    const card = (scene) => {
      const actions = scene.actions.slice(0, 4).map((action) => el("div", { class: "control" },
        el("span", { text: `${action.name || action.id}${action.missing ? " (gone)" : ""}` }),
        el("span", { class: "value", text: `${action.characteristic} → ${typeof action.value === "boolean" && !app.enumLabels[action.characteristic] ? (action.value ? "On" : "Off") : app.labelFor(action.characteristic, action.value)}` })));
      const more = scene.actions.length > 4 ? el("p", { class: "muted note", text: `and ${scene.actions.length - 4} more` }) : null;
      const last = scene.lastRun ? `Last run ${dateTimeFormat.format(new Date(scene.lastRun.at))} (${scene.lastRun.trigger})${scene.lastRun.ok ? "" : ", with errors"}` : "Never run";
      const run = el("button", { class: "primary", text: "Run" });
      run.addEventListener("click", async () => { await runScene(scene, run); });
      return el("div", { class: "card server scene-card" },
        el("div", { class: "server-head" }, tile("play", scene.security ? "violet" : "orange"),
          el("div", { class: "who" }, el("a", { class: "card-title", href: `/scenes/${scene.id}` }, el("strong", { text: scene.name })),
            el("div", { class: "muted", text: scene.triggers.length ? scene.triggers.map((t) => describeTrigger(t, names)).join(" · ") : "Run by hand" })),
          run),
        el("div", { class: "controls" }, actions), more,
        scene.security ? el("p", { class: "muted note", text: "It changes a lock, a door or an alarm: the page asks before running it, and automations leave those actions out." }) : null,
        el("div", { class: "card-foot" }, el("span", { class: "muted", text: scene.lastSkipped && (!scene.lastRun || scene.lastSkipped.at > scene.lastRun.at) ? `Skipped ${dateTimeFormat.format(new Date(scene.lastSkipped.at))}: ${scene.lastSkipped.reason}` : last }),
          menuButton(`Actions for ${scene.name}`, () => [
            { label: "Run", icon: "play", onSelect: () => runScene(scene) },
            { label: "Edit", icon: "edit", href: `/scenes/${scene.id}` },
            { label: "Delete", icon: "trash", danger: true, onSelect: async () => {
              if (!confirm(`Delete the scene ${scene.name}?`)) return;
              try { await app.api(`/api/scenes/${scene.id}`, { method: "DELETE" }); app.route(); } catch (e) { alert(e.message); }
            } },
          ])));
    };
    app.show(main,
      app.pageHead("Scenes", "Accessory values set together, by hand or on a schedule, at sunrise or sunset, or when an accessory changes. Homeswift keeps them; the Home app does not see them.",
        el("a", { class: "button primary", href: "/scenes/new", text: "New scene" })),
      data.scenes.length ? el("div", { class: "grid" }, data.scenes.map(card))
        : el("div", { class: "card empty" }, el("p", { class: "muted", text: "No scene yet. A scene sets several accessories at once, such as every light of a room for the evening." })),
      locationCard(data));
  }

  /// Where sunrise and sunset are computed for: Glass UI took its weather widget's city; here it is typed, or
  /// this device's position.
  function locationCard(data) {
    const location = data.location;
    const lat = el("input", { type: "number", step: "any", min: -90, max: 90, value: location?.lat ?? "", "aria-label": "Latitude" });
    const lon = el("input", { type: "number", step: "any", min: -180, max: 180, value: location?.lon ?? "", "aria-label": "Longitude" });
    const name = el("input", { type: "text", value: location?.name ?? "", placeholder: "Home", maxLength: 64 });
    const line = statusLine();
    const save = async (body) => {
      try { await app.api("/api/scenes/location", { method: "PUT", body }); app.route(); } catch (e) { say(line, e.message, "error"); }
    };
    const here = el("button", { text: "Use this device's location", onclick: () => {
      if (!navigator.geolocation) return say(line, "This browser cannot tell its location.", "error");
      say(line, "Asking the browser…");
      navigator.geolocation.getCurrentPosition(
        (position) => { lat.value = position.coords.latitude.toFixed(4); lon.value = position.coords.longitude.toFixed(4); say(line, "Found: save to keep it."); },
        (error) => say(line, error.message || "The browser did not give its location (it needs HTTPS away from localhost).", "error"));
    } });
    const next = location ? `Next sunrise ${data.nextSunrise ? timeFormat.format(new Date(data.nextSunrise)) : "—"}, sunset ${data.nextSunset ? timeFormat.format(new Date(data.nextSunset)) : "—"}.` : "No location yet: sunrise and sunset triggers wait for one.";
    return el("details", { class: "card location", open: !location && data.scenes.some((s) => s.triggers.some((t) => t.type === "sun")) },
      el("summary", {}, el("strong", { text: "Location for sunrise and sunset" }), el("span", { class: "muted", text: ` · ${location ? (location.name || `${location.lat}, ${location.lon}`) : "not set"}` })),
      el("p", { class: "muted", text: next }),
      el("div", { class: "fields" }, field("Latitude", lat), field("Longitude", lon), field("Name", name, "Only for you to recognise it.")),
      el("div", { class: "actions" },
        el("button", { class: "primary", text: "Save", onclick: () => save({ lat: Number(lat.value), lon: Number(lon.value), name: name.value }) }),
        here, location ? el("button", { class: "link", text: "Forget it", onclick: () => save(null) }) : null),
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
      input = el("select", {}, el("option", { value: "true", text: "On" }), el("option", { value: "false", text: "Off" }));
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
    input.setAttribute("aria-label", "Value");
    return input;
  }

  /// An accessory and one of its characteristics, with a value input after them when `withValue`.
  function characteristicPicker(accessories, pick, { id, characteristic, value, withValue = true, list = writable }) {
    const options = accessories.filter((a) => list(a).length);
    const accessory = el("select", { "aria-label": "Accessory" }, options.map((a) => el("option", { value: a.id, text: displayName(a) })));
    const kind = el("select", { "aria-label": "Characteristic" });
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
    else if (id) accessory.prepend(el("option", { value: id, text: `${id} (gone)`, selected: true }));
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
  const removeButton = (row, list) => el("button", { class: "icon-button", type: "button", title: "Remove", "aria-label": "Remove", onclick: () => { list.delete(row); row.remove(); } }, HomeswiftCommon.icon("trash"));

  function daysPicker(days) {
    const chosen = new Set(days && days.length ? days : [0, 1, 2, 3, 4, 5, 6]);
    const node = el("span", { class: "days", role: "group", "aria-label": "Days" }, weekdays.map((name, day) => {
      const box = el("input", { type: "checkbox", checked: chosen.has(day), "aria-label": name });
      box.addEventListener("change", () => { if (box.checked) chosen.add(day); else chosen.delete(day); });
      return el("label", { class: "day" }, box, el("span", { text: name.slice(0, 2) }));
    }));
    node.read = () => chosen.size === 7 || chosen.size === 0 ? undefined : [...chosen].sort();
    return node;
  }

  function timeOfDay(value) {
    const sun = ["sunrise", "sunset"].includes(value);
    const kind = el("select", { "aria-label": "When" }, el("option", { value: "time", text: "At" }), el("option", { value: "sunrise", text: "Sunrise" }), el("option", { value: "sunset", text: "Sunset" }));
    kind.value = sun ? value : "time";
    const time = el("input", { type: "time", value: sun ? "00:00" : value || "18:00", "aria-label": "Time" });
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
    if (!scene) { app.show(main, el("p", { class: "error", text: "No such scene." })); return; }
    const choices = accessories.filter((a) => !a.hidden || scene.actions.some((x) => x.id === a.id));

    const name = el("input", { type: "text", value: scene.name, maxLength: 64, required: true, placeholder: "Evening" });
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
      const type = el("select", { "aria-label": "Trigger" },
        el("option", { value: "time", text: "At a time" }), el("option", { value: "sun", text: "Sunrise or sunset" }),
        el("option", { value: "characteristic", text: "When an accessory changes" }), el("option", { value: "cron", text: "Cron" }));
      type.value = trigger.type;
      const enabled = el("input", { type: "checkbox", checked: trigger.enabled !== false, "aria-label": "On" });
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(type, body, el("label", { class: "toggle compact" }, enabled, el("span", { text: "On" })));
      const draw = (t) => {
        if (t.type === "time") {
          const at = el("input", { type: "time", value: t.at || "18:00", "aria-label": "Time" });
          const days = daysPicker(t.days);
          body.replaceChildren(at, days);
          row.readBody = () => ({ at: at.value, days: days.read() });
        } else if (t.type === "sun") {
          const event = el("select", { "aria-label": "Event" }, el("option", { value: "sunrise", text: "Sunrise" }), el("option", { value: "sunset", text: "Sunset" }));
          event.value = t.event || "sunset";
          const offset = el("input", { type: "number", min: -720, max: 720, step: 1, value: t.offsetMinutes ?? 0, "aria-label": "Minutes after (negative: before)", title: "Minutes after; negative for before" });
          const days = daysPicker(t.days);
          body.replaceChildren(event, offset, el("span", { class: "muted", text: "min" }), days);
          row.readBody = () => ({ event: event.value, offsetMinutes: Number(offset.value) || 0, days: days.read() });
        } else if (t.type === "characteristic") {
          const pick = {};
          const operator = el("select", { "aria-label": "Condition" }, el("option", { value: "changes", text: "changes" }), operators.map(([value, text]) => el("option", { value, text })));
          operator.value = t.operator || "changes";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: t.id, characteristic: t.characteristic, value: t.value, list: readable });
          holder.classList.toggle("hidden", operator.value === "changes");
          operator.addEventListener("change", () => holder.classList.toggle("hidden", operator.value === "changes"));
          body.replaceChildren(accessory, kind, operator, holder);
          row.readBody = () => ({ ...pick.read(), operator: operator.value, ...(operator.value === "changes" ? {} : { value: pick.value.read() }) });
        } else {
          const cron = el("input", { type: "text", value: t.cron || "0 7 * * 1-5", placeholder: "0 7 * * 1-5", "aria-label": "Cron expression", class: "mono" });
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
      const type = el("select", { "aria-label": "Condition" }, el("option", { value: "time", text: "Between" }), el("option", { value: "characteristic", text: "Only if" }));
      type.value = condition.type;
      const body = el("span", { class: "group-inline grow" });
      const row = rowShell(type, body);
      const draw = (c) => {
        if (c.type === "time") {
          const after = timeOfDay(c.after || "sunset"), before = timeOfDay(c.before || "23:00");
          body.replaceChildren(after, el("span", { class: "muted", text: "and" }), before);
          row.readBody = () => ({ after: after.read(), before: before.read() });
        } else {
          const pick = {};
          const operator = el("select", { "aria-label": "Comparison" }, operators.map(([value, text]) => el("option", { value, text })));
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
    const capture = el("select", { "aria-label": "Add the current state of an accessory" }, el("option", { value: "", text: "Add an accessory as it is now…" }),
      choices.filter((a) => writable(a).length).map((a) => el("option", { value: a.id, text: displayName(a) })));
    capture.addEventListener("change", () => {
      const accessory = choices.find((a) => a.id === capture.value);
      capture.value = "";
      if (!accessory) return;
      for (const c of writable(accessory)) if (!c.security && c.value !== null && c.value !== undefined) addAction({ id: accessory.id, characteristic: c.type, value: c.value });
    });

    const line = statusLine();
    const save = el("button", { class: "primary", type: "submit", text: isNew ? "Create the scene" : "Save" });
    const form = el("form", { class: "card scene-editor", onsubmit: async (event) => {
      event.preventDefault();
      const body = { name: name.value.trim(), actions: [...actions].map((row) => row.read()), triggers: [...triggers].map((row) => row.read()), conditions: [...conditions].map((row) => row.read()) };
      save.disabled = true;
      try {
        const saved = await app.api(isNew ? "/api/scenes" : `/api/scenes/${scene.id}`, { method: isNew ? "POST" : "PUT", body });
        const security = saved.actions.some((a) => a.security);
        if (security && body.triggers.some((t) => t.enabled !== false)) {
          say(line, "Saved. Its lock, door or alarm actions run only when you run it here: automations leave them out.", "ok");
          if (isNew) setTimeout(() => app.navigate(`/scenes/${saved.id}`, { replace: true }), 1500);
        } else {
          app.navigate("/scenes");
        }
      } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    } },
      field("Name", name),
      el("h2", { text: "Actions" }), el("p", { class: "muted", text: "The values to set, in this order." }), actionList,
      el("div", { class: "actions" }, el("button", { type: "button", text: "Add an action", onclick: () => addAction() }), capture),
      el("h2", { text: "Triggers" }), el("p", { class: "muted", text: data.location ? `Run it automatically. Sunrise and sunset are for ${data.location.name || `${data.location.lat}, ${data.location.lon}`}.` : "Run it automatically. Sunrise and sunset need a location: set it on the Scenes page." }),
      triggerList, el("div", { class: "actions" }, el("button", { type: "button", text: "Add a trigger", onclick: () => addTrigger() })),
      el("h2", { text: "Conditions" }), el("p", { class: "muted", text: "An automatic run goes ahead only when all of these hold. Running it by hand ignores them." }),
      conditionList, el("div", { class: "actions" }, el("button", { type: "button", text: "Add a condition", onclick: () => addCondition() })),
      el("div", { class: "save-bar" }, save, el("a", { class: "button", href: "/scenes", text: "Cancel" }),
        isNew ? null : el("span", { class: "spacer" }),
        isNew ? null : el("button", { type: "button", class: "danger", text: "Delete", onclick: async () => {
          if (!confirm(`Delete the scene ${scene.name}?`)) return;
          try { await app.api(`/api/scenes/${scene.id}`, { method: "DELETE" }); app.navigate("/scenes"); } catch (e) { say(line, e.message, "error"); }
        } })),
      line);
    app.show(main, app.breadcrumb(["Scenes", "/scenes"], [isNew ? "New scene" : scene.name]), form);
  }

  // ---- Notifications ---------------------------------------------------------------------------------

  const channelInfo = {
    webhook: ["Webhook", "A JSON POST to a URL of yours: event, title, message, instance, timestamp.", [["url", "URL", "https://…", true]]],
    ntfy: ["ntfy", "A topic on ntfy.sh or your own ntfy server; the app shows it on a phone.", [["server", "Server", "https://ntfy.sh"], ["topic", "Topic", "homeswift-…"], ["token", "Access token", "for a protected topic", true]]],
    pushover: ["Pushover", "Your user key and an application token from pushover.net.", [["userKey", "User key", "", true], ["appToken", "Application token", "", true]]],
    telegram: ["Telegram", "A bot's token from @BotFather, and the chat it writes to.", [["botToken", "Bot token", "123456:ABC…", true], ["chatId", "Chat id", "-100… or @channel"]]],
    browser: ["This browser and others", "Web Push to the browsers that turned it on below. It needs HTTPS (or localhost).", []],
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
      say(line, "Sending…");
      try {
        const answer = await app.api("/api/notifications/test", { method: "POST", body: channel ? { channel } : {} });
        const failed = answer.results.filter((r) => !r.ok);
        say(line, failed.length ? failed.map((r) => `${r.channel}: ${r.error}`).join("; ") : `Sent through ${answer.results.map((r) => r.channel).join(", ")}.`, failed.length ? "error" : "ok");
      } catch (e) { say(line, e.message, "error"); }
    };
    const cards = Object.entries(channelInfo).map(([channel, [title, help, fields]]) => {
      const values = settings.channels[channel];
      const enabled = el("input", { type: "checkbox", checked: values.enabled, "aria-label": `${title} on` });
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
        el("div", { class: "card-foot" }, el("span", { class: "muted", text: values.enabled ? "On" : "Off" }),
          menuButton(`Actions for ${title}`, () => [{ label: "Send a test", icon: "bell", onSelect: () => test(channel) }])));
    });
    const events = settings.events.map((event) => {
      const box = el("input", { type: "checkbox", checked: event.enabled });
      box.dataset.event = event.name;
      return el("label", { class: "toggle" }, box, el("span", {}, el("span", { text: event.label }),
        event.name === "dailyDigest" && !settings.assistant ? el("span", { class: "help", text: "Needs the Assistant (a HomeswiftAiKit block)." }) : null));
    });
    const digestTime = el("input", { type: "time", value: settings.dailyDigestTime, "aria-label": "Daily digest time" });
    const save = el("button", { class: "primary", text: "Save" });
    save.addEventListener("click", async () => {
      const channels = {};
      for (const [channel, fields] of Object.entries(inputs)) {
        channels[channel] = {};
        for (const [key, input] of Object.entries(fields)) channels[channel][key] = input.type === "checkbox" ? input.checked : input.value;
      }
      const body = { channels, events: Object.fromEntries([...main.querySelectorAll("[data-event]")].map((box) => [box.dataset.event, box.checked])), dailyDigestTime: digestTime.value };
      save.disabled = true;
      try { await app.api("/api/notifications", { method: "PUT", body }); say(line, "Saved.", "ok"); } catch (e) { say(line, e.message, "error"); }
      save.disabled = false;
    });
    app.show(main,
      app.pageHead("Notifications", "What the bridge tells you when you are not looking: it started or stopped, a plugin reported an error, an accessory stopped responding, an automation failed."),
      el("div", { class: "grid" }, cards),
      el("div", { class: "card" }, el("h2", { text: "Events" }),
        el("p", { class: "muted", text: "The same event about the same thing goes out once per 15 minutes at most, and 12 notifications an hour at most." }),
        events, field("Daily digest at", digestTime)),
      el("div", { class: "save-bar" }, save, el("button", { text: "Send a test to every channel that is on", onclick: () => test() })), line);
  }

  /// This browser's subscription and the others'.
  function browserPanel(settings) {
    const box = el("div", { class: "push" });
    const line = statusLine();
    const others = el("div", {}, settings.subscriptions.map((sub) => el("div", { class: "control" },
      el("span", { text: `${sub.label}${sub.username ? ` · ${sub.username}` : ""}` }),
      el("button", { class: "link", text: "Remove", onclick: async () => {
        try { await app.api(`/api/notifications/push/subscriptions/${sub.id}`, { method: "DELETE" }); app.route(); } catch (e) { say(line, e.message, "error"); }
      } }))));
    if (!pushSupported()) {
      box.append(el("p", { class: "muted note", text: window.isSecureContext ? "This browser cannot receive push notifications." : "Open this page over HTTPS (the HomeswiftUI block's https) or on localhost to turn them on here." }), others);
      return box;
    }
    const toggle = el("button", { text: "Checking…", disabled: true });
    const draw = (subscription) => {
      toggle.disabled = false;
      toggle.textContent = subscription ? "Turn off on this browser" : "Turn on for this browser";
      toggle.onclick = async () => {
        toggle.disabled = true;
        try {
          if (subscription) {
            await app.api("/api/notifications/push/unsubscribe", { method: "POST", body: { endpoint: subscription.endpoint } });
            await subscription.unsubscribe();
          } else {
            if (await Notification.requestPermission() !== "granted") throw new Error("The browser's notifications are blocked for this site.");
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
    const testHere = el("button", { class: "link", text: "Send a test here", onclick: async () => {
      const subscription = await currentSubscription();
      if (!subscription) return say(line, "This browser is not subscribed.", "error");
      try {
        const answer = await app.api("/api/notifications/push/test", { method: "POST", body: { endpoint: subscription.endpoint } });
        const result = answer.results[0];
        say(line, result.ok ? "Sent." : result.error, result.ok ? "ok" : "error");
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
      app.views.quick = async (main) => app.show(main, app.pageHead("Quick controls", "Your favourite accessories and the scenes, at hand."), quickSection(null, { standalone: true }));
    },
    layoutActions, groupByRoom, suggestRooms, quickSection, displayName,
  };
})();
