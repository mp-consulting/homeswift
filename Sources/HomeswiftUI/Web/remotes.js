// The Remotes page (/remotes, beside Automations and Scenes): every Remote (GLOSSARY.md), its Buttons and Wheels by
// Channel, and what each gesture does: its Controls, run by the bridge the moment it comes
// (docs/adr/0009-remote-controls-are-not-automations.md). A press on a remote finds its Button here. Controls are saved
// as the Remote's Accessory Settings (`controls`); /remotes/<id>?part=<part> opens one.
(() => {
  "use strict";

  const { t } = HomeswiftI18n;
  const { el, api } = HomeswiftCommon;
  const app = () => window.HomeswiftApp;
  const enc = encodeURIComponent;

  /// What the page shows now, for the presses that find a Button (`event`).
  let shown = null;

  const gestureNames = {
    press: () => t("Press"), double: () => t("Double press"), long: () => t("Long press"), hold: () => t("Hold"), turn: () => t("Turn"),
  };

  /// What a set of targets is, for the words: lights, shutters, or both; appliances alone (switches, fans, TVs), which only
  /// turn on and off. Appliances beside lights or shutters go by their words.
  function drives(ids, targets) {
    const kinds = new Set(ids.map((id) => targets.get(id)?.kind).filter(Boolean));
    // Garage doors and locks only open and close, as shutters do.
    if (kinds.size === 1 && kinds.has("appliance")) return ids.every((id) => targets.get(id)?.opens) ? "doors" : "appliances";
    return kinds.has("shutter") ? (kinds.has("light") || kinds.has("appliance") ? "both" : "shutters") : "lights";
  }

  /// An action's words, for what its targets are: a shutter opens and closes where a light brightens and dims.
  function actionWords(action, direction, kind) {
    const pick = (lights, shutters, both) => ({ lights, shutters, both, appliances: lights, doors: shutters })[kind]();
    switch (action) {
      case "toggle": return pick(() => t("Turns on or off"), () => t("Opens or closes"), () => t("Turns on or off, opens or closes"));
      case "on": return pick(() => t("Turns on"), () => t("Opens"), () => t("Turns on and opens"));
      case "off": return pick(() => t("Turns off"), () => t("Closes"), () => t("Turns off and closes"));
      case "stop": return t("Stops the shutters");
      case "step": return pick(() => t("Dims a step per notch"), () => t("Moves a step per notch"), () => t("Dims and moves a step per notch"));
      case "dim":
        if (direction === "up") return pick(() => t("Brightens"), () => t("Opens"), () => t("Brightens and opens"));
        if (direction === "down") return pick(() => t("Dims"), () => t("Closes"), () => t("Dims and closes"));
        return pick(() => t("Brightens, then dims, in turn"), () => t("Opens, then closes, in turn"), () => t("Brightens and opens, then dims and closes, in turn"));
      default: return action;
    }
  }

  /// A part's name in the reader's language: a Channel's Wheel or Button by its number, a Tap dial's ring, the name its
  /// plugin or HomeKit gives, else its number (a remote's only button: Button).
  function partName(part, remote) {
    if (part.channel != null) return part.kind === "wheel" ? t("Channel {number} wheel", { number: part.channel }) : t("Channel {number} button", { number: part.channel });
    if (part.name === "Ring") return t("Ring");
    if (part.name) return part.name;
    if (part.kind === "wheel") return t("Wheel");
    return remote.parts.length === 1 ? t("Button") : t("Button {number}", { number: part.number });
  }

  /// A Control in a line: what it does, and to what.
  function describe(control, lists) {
    const scenes = (control.scenes ?? []).map((id) => lists.scenes.get(id)?.name ?? id);
    const runs = scenes.length ? t("Runs {scene}", { scene: scenes.join(", ") }) : null;
    if (control.action === "scene") return runs ?? "";
    const words = actionWords(control.action, control.direction, drives(control.targets ?? [], lists.targets));
    const names = (control.targets ?? []).map((id) => lists.targets.get(id)?.name ?? t("A missing accessory"));
    return [names.length ? `${words} · ${names.join(", ")}` : words, runs].filter(Boolean).join(" · ");
  }

  async function view(main, [remoteID] = []) {
    const data = await api("/api/remotes");
    const lists = {
      targets: new Map(data.targets.map((one) => [one.id, one])), power: new Map(data.power.map((one) => [one.id, one])),
      scenes: new Map(data.scenes.map((one) => [one.id, one])),
    };
    const admin = app().isAdmin();
    const rows = new Map();
    shown = { data, lists, admin, rows };
    const empty = el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("remote")),
      el("p", { class: "muted", text: t("No remote yet. Add one from Add accessories: a Matter remote, a Hue dimmer switch, an IKEA remote through its hub, a Zigbee button.") }),
      admin ? el("a", { class: "button primary", href: "/setup", actionIcon: "plus", text: t("Add accessories") }) : null);
    app().show(main,
      app().pageHead(t("Remotes"), t("What each Button and Wheel of your remotes does, run by the bridge the moment you press. Press a button to find it here.")),
      window.HomeswiftHome.scenesTabs("remotes"),
      data.remotes.length ? el("div", { class: "card remote-list" }, data.remotes.map((remote) => remoteSection(remote))) : empty);
    // /remotes/<id>?part=<part>: that Remote, its part opened (from a plugin page's channel).
    if (remoteID) {
      const remote = data.remotes.find((one) => one.id === remoteID);
      const part = remote?.parts.find((one) => one.id === new URLSearchParams(location.search).get("part"));
      document.getElementById(sectionID(remoteID))?.scrollIntoView({ block: "start" });
      if (remote && part && admin) openEditor(remote, part, rows.get(rowKey(remote.id, part.id)));
    }
  }

  const sectionID = (id) => `remote-${id.replace(/[^A-Za-z0-9_-]/g, "_")}`;
  const rowKey = (remoteID, partID) => `${remoteID}\u0000${partID}`;

  /// A Remote: its name and where it is, whether its presses reach Apple Home, then its parts by Channel.
  function remoteSection(remote) {
    const { admin, rows } = shown;
    const facts = [remote.room, remote.plugin].filter(Boolean).join(" · ");
    const flags = [
      remote.mirrored ? el("span", { class: "chip", title: t("Paired to Apple Home, which tells the bridge its presses: they can come a moment later."), text: t("Through Apple Home") }) : null,
      remote.inAppleHome ? el("span", { class: "chip", title: t("Apple Home gets its presses too: an automation there on the same button also runs. Not in Home, in its Settings, keeps it out."), text: t("Also in Apple Home") }) : null,
      remote.unavailable ? el("span", { class: "chip warn", text: t("No response") }) : null,
    ].filter(Boolean);
    const groups = [...Map.groupBy(remote.parts, (part) => part.channel ?? 0).entries()].map(([channel, parts]) => el("div", { class: "remote-group" },
      channel ? el("h4", { class: "remote-channel", text: t("Channel {number}", { number: channel }) }) : null,
      el("ul", { class: "remote-parts" }, parts.map((part) => {
        const row = partRow(remote, part, admin);
        rows.set(rowKey(remote.id, part.id), row);
        return el("li", {}, row);
      }))));
    return el("section", { class: "remote", id: sectionID(remote.id) },
      el("div", { class: "remote-head" },
        HomeswiftCommon.tile("remote", "blue"),
        el("div", { class: "remote-title" }, el("h3", { text: remote.name }), facts ? el("p", { class: "muted", text: facts }) : null),
        flags.length ? el("div", { class: "chips" }, flags) : null),
      groups);
  }

  /// A Button or Wheel: its name, the Home app's numbers for it, what each gesture does, the Automations it starts.
  function partRow(remote, part, admin) {
    const { lists } = shown;
    const controls = remote.controls.filter((control) => control.part === part.id);
    // In the order of the gestures: what each does, then the Automations it starts.
    const order = Object.keys(gestureNames);
    const entries = [
      ...controls.map((control) => ({ gesture: control.gesture, text: describe(control, lists) })),
      ...part.automations.map((automation) => ({ gesture: automation.gesture, text: t("Starts {automation}", { automation: automation.name }) })),
    ].sort((a, b) => order.indexOf(a.gesture) - order.indexOf(b.gesture));
    const lines = entries.map((entry) => el("li", {},
      el("span", { class: "remote-gesture", text: gestureNames[entry.gesture]() }), el("span", { text: entry.text })));
    const homeKit = part.homeKit.length ? t("Home app: {buttons}", { buttons: part.homeKit.map((number) => t("Button {number}", { number })).join(", ") }) : null;
    const body = el("span", { class: "body" },
      el("span", { class: "remote-part-name" }, el("strong", { text: partName(part, remote) }), homeKit ? el("span", { class: "muted", text: homeKit }) : null),
      lines.length ? el("ul", { class: "remote-controls" }, lines) : el("span", { class: "muted", text: t("Does nothing yet") }));
    const glyph = el("span", { class: "remote-part-glyph", "aria-hidden": "true" }, HomeswiftCommon.icon(part.kind === "wheel" ? "loop" : "press"));
    if (!admin) return el("div", { class: "remote-part" }, glyph, body);
    return el("button", { type: "button", class: "remote-part", "aria-label": t("{name}: set what it does", { name: partName(part, remote) }),
      onclick: (event) => openEditor(remote, part, event.currentTarget) }, glyph, body,
      el("span", { class: "chevron", "aria-hidden": "true" }, HomeswiftCommon.icon("forward")));
  }

  /// A part's Controls in the side sheet: a card per gesture, with what it does and what to: lights, shutters and
  /// appliances (its action), the Scenes it runs and the Automations it starts (their press Trigger). Its Power
  /// Switches, step and waits under More.
  function openEditor(remote, part, trigger) {
    const { data, lists } = shown;
    const mine = remote.controls.filter((control) => control.part === part.id);
    // A part with nothing yet starts from its Channel's other part's lights (an on/off remote's two buttons).
    const sibling = mine.length ? null : remote.controls.find((control) => control.targets?.length
      && remote.parts.some((other) => other.id === control.part && other.channel != null && other.channel === part.channel));
    // Listed by room in the home's order (no room last), the pills keeping one kind; a chosen one's chip names its room.
    // A light without brightness says so: it only turns on and off.
    const roomRank = (room) => { const at = (data.rooms ?? []).indexOf(room); return room == null ? Infinity : at < 0 ? (data.rooms ?? []).length : at; };
    const byRoom = (list) => list.slice().sort((a, b) => roomRank(a.room) - roomRank(b.room)
      || (a.room ?? "").localeCompare(b.room ?? "") || a.name.localeCompare(b.name, undefined, { numeric: true }));
    const kindIcon = (one) => one.kind === "shutter" ? "blind" : one.kind === "light" ? "bulb" : one.opens ? "door" : one.kind === "outlet" ? "outlet" : one.kind ? "power" : null;
    const choice = (one, kind) => {
      const only = one.onOffOnly ? t("On and off only") : null;
      return { value: one.id, group: one.room ?? t("No room"), filter: kind, icon: kindIcon(one) ?? undefined,
        label: [one.name, only].filter(Boolean).join(" · "), title: [one.name, one.room, only].filter(Boolean).join(" · ") };
    };
    // A Group's members under its row, in its first member's room as on the wall; its row ticks them all. A Group with
    // one member left here (the others drive nothing) lists it on its own.
    const listed = (list, kindOf) => {
      const groups = new Map();
      for (const one of list.filter((one) => one.group)) {
        if (!groups.has(one.group.id)) groups.set(one.group.id, { name: one.group.name, members: [] });
        groups.get(one.group.id).members.push(one);
      }
      const whole = [...groups.values()].filter((group) => group.members.length > 1);
      const inGroup = new Set(whole.flatMap((group) => group.members.map((one) => one.id)));
      // An accessory's Functions (a relay's channels, a fan's light) under it: each `<id>#<key>`, its `of` the accessory.
      const functions = Map.groupBy(list.filter((one) => one.of), (one) => one.of);
      const listedIDs = new Set(list.map((one) => one.id));
      const functionsOf = (one) => (functions.get(one.id) ?? []).map((function_) => ({ ...choice(function_, kindOf(function_)), nested: true, search: one.name }));
      const rows = [...list.filter((one) => !inGroup.has(one.id) && (!one.of || !listedIDs.has(one.of))),
        ...whole.map((group) => ({ ...group, room: group.members[0].room ?? null }))];
      return byRoom(rows).flatMap((row) => {
        if (!row.members) return [choice(row, kindOf(row)), ...functionsOf(row)];
        const heading = row.room ?? t("No room");
        return [{ title: row.name, group: heading, filter: kindOf(row.members[0]), members: row.members.map((one) => one.id),
          search: row.members.map((one) => one.name).join(" ") },
        ...byRoom(row.members).flatMap((one) => [{ ...choice(one, kindOf(one)), group: heading, nested: true, search: row.name },
          ...functionsOf(one).map((function_) => ({ ...function_, group: heading }))])];
      });
    };
    const deviceChoices = listed(data.targets, (one) => ({ shutter: "Blinds", appliance: "Appliances" })[one.kind] ?? "Lights");
    // Scenes and Automations beside them, for a press: their values objects, an accessory's its id.
    const sceneChoices = byRoom(data.scenes).map((scene) => ({ value: { scene: scene.id }, group: t("Scenes"), filter: "Scenes", icon: "play",
      label: scene.room ? `${scene.name} · ${scene.room}` : scene.name, title: scene.name }));
    const automationChoices = (data.automations ?? []).map((automation) => ({ value: { automation: automation.id }, group: t("Automations"),
      filter: "Automations", icon: "workflow", title: automation.name,
      label: automation.enabled ? automation.name : `${automation.name} · ${t("Disabled")}` }));
    const split = (values) => ({
      targets: values.filter((value) => typeof value === "string"),
      scenes: values.map((value) => value.scene).filter(Boolean),
      automations: values.map((value) => value.automation).filter(Boolean),
    });

    const powered = mine.find((control) => control.power?.length) ?? sibling;
    const powerPicker = HomeswiftForms.searchSet(listed(data.power, (one) => one.kind === "outlet" ? "Outlets" : "Switches"), powered?.power ?? []);
    const options = mine.find((control) => control.targets?.length) ?? sibling ?? {};
    const step = el("input", { type: "number", min: 1, max: 25, value: options.step ?? 5, "aria-describedby": "remote-step-help" });
    const powerDelay = el("input", { type: "number", min: 1, max: 30, value: options.powerDelay ?? 5 });
    const reversed = el("input", { type: "checkbox", role: "switch", checked: options.reversed === true });

    // Each gesture: a card with its action (once it has something to act on) and its own list.
    const pressControl = mine.find((one) => one.gesture === "press");
    const gestureFields = part.gestures.map((gesture) => {
      const control = mine.find((one) => one.gesture === gesture);
      const presses = ["press", "double", "long"].includes(gesture);
      const startsNow = part.automations.filter((one) => one.gesture === gesture).map((one) => one.id);
      // A hold with nothing yet starts from the press's lights and shutters, its action left to choose.
      const initial = control ? [...(control.targets ?? []), ...(control.scenes ?? []).map((scene) => ({ scene }))]
        : gesture === "hold" ? (pressControl?.targets ?? sibling?.targets ?? []).filter((id) => ["light", "shutter"].includes(lists.targets.get(id)?.kind))
        : gesture === "press" ? sibling?.targets ?? [] : [];
      const picker = HomeswiftForms.searchSet(presses ? [...deviceChoices, ...sceneChoices, ...automationChoices] : deviceChoices,
        [...initial, ...startsNow.map((automation) => ({ automation }))]);
      let chosen = control && control.action !== "scene" ? valueOf(control) : "";
      const select = el("select", { "aria-label": gestureNames[gesture]() });
      const kind = () => drives(split(picker.get()).targets, lists.targets);
      // Appliances only turn on and off: a hold or a Wheel has nothing to do for them alone.
      const appliancesOnly = el("p", { class: "help", text: t("Appliances only turn on and off: a hold or a wheel dims lights and moves shutters."), hidden: true });
      const note = el("p", { class: "help", hidden: true, text: gesture === "hold" ? t("A long press and a hold are the same press: choose one.") : null });
      // Nothing for a hold or a Wheel to do with appliances alone.
      const idle = () => (gesture === "hold" || gesture === "turn") && ["appliances", "doors"].includes(kind());
      const fill = () => {
        const { targets } = split(picker.get());
        const alone = idle();
        appliancesOnly.hidden = !alone;
        // Stopping is for shutters: offered when it drives some (or already chosen).
        const offered = choicesFor(gesture).filter(([value, action]) => (action !== "stop" || !["lights", "appliances", "doors"].includes(kind()) || chosen === value)
          && (!alone || chosen === value));
        select.replaceChildren(el("option", { value: "", text: t("Nothing") }), ...offered.map(([value, action, direction]) =>
          el("option", { value, text: actionWords(action, direction, kind()) })));
        select.value = chosen;
        select.hidden = targets.length === 0;
      };
      select.addEventListener("change", () => { chosen = select.value; syncHoldAndLong(); });
      // Something to act on, where there was nothing (its action hidden): the gesture's first action, ready.
      picker.node.addEventListener("change", () => {
        if (select.hidden && split(picker.get()).targets.length && !chosen && !idle()) chosen = choicesFor(gesture)[0][0];
        fill();
        syncHoldAndLong();
      });
      fill();
      const card = el("section", { class: "remote-gesture-card", "aria-label": gestureNames[gesture]() },
        el("div", { class: "remote-gesture-head" }, el("h4", { text: gestureNames[gesture]() }), select),
        picker.node, appliancesOnly, note);
      return { gesture, presses, picker, note, card, startsNow, state: () => (split(picker.get()).targets.length ? chosen : "") };
    });
    const field = (gesture) => gestureFields.find((one) => one.gesture === gesture);
    // A long press and a hold are the same press: one or the other. A long press's Automations are that press too: a hold
    // waits for new ones to go, and those it had already start on each hold.
    function syncHoldAndLong() {
      const hold = field("hold"), long = field("long");
      if (!hold || !long) return;
      const longNow = split(long.picker.get());
      const holding = hold.state() !== "";
      const longControl = long.state() !== "" || longNow.scenes.length > 0;
      const newStarts = longNow.automations.some((id) => !long.startsNow.includes(id));
      hold.card.inert = !holding && (longControl || newStarts);
      long.card.inert = holding && !longControl && longNow.automations.length === 0;
      hold.note.hidden = !hold.card.inert;
      long.note.hidden = !holding;
      long.note.textContent = longNow.automations.length ? t("A long press and a hold are the same press: these automations also start on each hold.")
        : t("A long press and a hold are the same press: while it holds to dim, it starts no automation.");
    }
    syncHoldAndLong();
    let powerChanged = false;
    powerPicker.node.addEventListener("change", () => { powerChanged = true; });

    const message = el("p", { class: "muted", role: "status" });
    return HomeswiftCommon.openSheet((done) => {
      const save = el("button", { type: "button", class: "primary", actionIcon: "check", text: t("Save"), onclick: () => HomeswiftCommon.busyButton(save, async () => {
        const power = powerPicker.get();
        const made = [], starts = {};
        for (const one of gestureFields) {
          const { targets, scenes, automations } = split(one.picker.get());
          if (one.presses && (automations.length !== one.startsNow.length || automations.some((id) => !one.startsNow.includes(id)))) starts[one.gesture] = automations;
          const picked = one.state() ? choicesFor(one.gesture).find(([value]) => value === one.state()) : null;
          if (!picked && !scenes.length) continue;
          const control = { part: part.id, gesture: one.gesture, action: picked ? picked[1] : "scene" };
          if (picked) {
            const [, action, direction] = picked;
            control.targets = targets;
            const old = mine.find((before) => before.gesture === one.gesture && before.targets?.length);
            const switches = old && !powerChanged ? old.power ?? [] : power;
            if (switches.length) { control.power = switches; if (Number(powerDelay.value) !== 5) control.powerDelay = Number(powerDelay.value); }
            if (direction) control.direction = direction;
            if (["dim", "step", "toggle"].includes(action) && Number(step.value) !== 5) control.step = Number(step.value);
            if (action === "step" && reversed.checked) control.reversed = true;
          }
          if (scenes.length) control.scenes = scenes;
          made.push(control);
        }
        const controls = [...remote.controls.filter((control) => control.part !== part.id), ...made];
        // The Automations are checked first, so a refusal saves nothing.
        if (Object.keys(starts).length) await api(`/api/remotes/${enc(remote.id)}/automations`, { method: "PUT", body: { part: part.id, starts, dryRun: true } });
        await api(`/api/settings/accessories/${enc(remote.id)}${remote.instance ? `?instance=${enc(remote.instance)}` : ""}`, { method: "PATCH", body: { controls: controls.length ? controls : null } });
        remote.controls = controls;
        // The Automations each press starts, when they changed: their press Triggers.
        if (Object.keys(starts).length) {
          await api(`/api/remotes/${enc(remote.id)}/automations`, { method: "PUT", body: { part: part.id, starts } });
          const known = new Map((data.automations ?? []).map((one) => [one.id, one]));
          part.automations = [...part.automations.filter((one) => !(one.gesture in starts)),
            ...Object.entries(starts).flatMap(([gesture, ids]) => ids.map((id) => ({ id, name: known.get(id)?.name ?? id, enabled: known.get(id)?.enabled !== false, gesture })))];
        }
        // Only this remote is drawn again: its rows (and the presses that find them) follow.
        document.getElementById(sectionID(remote.id))?.replaceWith(remoteSection(remote));
        done(true);
      }, { report: (e) => { message.className = "error"; message.textContent = e.message; } }) });
      return el("div", { class: "account-form remote-sheet" },
        el("div", { class: "setup-sheet-head" }, HomeswiftCommon.tile(part.kind === "wheel" ? "loop" : "press", "blue"),
          el("div", {}, el("h2", { id: "remote-sheet-title", text: partName(part, remote) }), el("p", { class: "muted setup-method", text: remote.name }))),
        el("section", { class: "remote-sheet-section" },
          el("h3", { text: t("What each gesture does") }),
          el("p", { class: "muted", text: t("Lights it dims and switches, shutters it moves, everything else it turns on and off, garage doors, locks and alarms included: anyone holding the remote can open them.") }),
          gestureFields.some((one) => one.presses) ? el("p", { class: "muted", text: t("A press, a double or a long press also runs Scenes and starts Automations.") }) : null,
          el("div", { class: "remote-gesture-cards" }, gestureFields.map((one) => one.card))),
        el("details", { class: "remote-more" }, el("summary", { text: t("More") }),
          el("label", { class: "field" }, el("span", { class: "field-title", text: t("Step") }), step,
            el("span", { class: "help", id: "remote-step-help", text: t("Percent of brightness or position per notch or per step of a hold, 1 to 25.") })),
          part.kind === "wheel" ? el("label", { class: "field toggle-field" }, reversed, el("span", { text: t("Turning up dims and closes") })) : null,
          el("div", { class: "field" }, el("span", { class: "field-title", text: t("Power Switches") }),
            el("span", { class: "help", text: t("Relays that power the lights: switched on before they brighten, off once they are dimmed past the lowest level.") }), powerPicker.node),
          el("label", { class: "field" }, el("span", { class: "field-title", text: t("Wait after power on") }), powerDelay,
            el("span", { class: "help", text: t("Seconds the lights take to come back once their power is on, 1 to 30.") }))),
        message,
        el("div", { class: "actions" }, el("button", { type: "button", actionIcon: "close", text: t("Cancel"), onclick: () => done(false) }), save));
    }, "remote-sheet-title", { returnFocus: trigger, onClose: () => { if (trigger?.isConnected) trigger.focus(); else shown?.rows.get(rowKey(remote.id, part.id))?.focus(); } });
  }

  /// The choices of a gesture: [value, action, direction].
  function choicesFor(gesture) {
    switch (gesture) {
      case "hold": return [["dim", "dim", null], ["dim-up", "dim", "up"], ["dim-down", "dim", "down"]];
      case "turn": return [["step", "step", null]];
      default: return [["toggle", "toggle"], ["on", "on"], ["off", "off"], ["stop", "stop"]];
    }
  }

  /// A saved Control's choice value.
  function valueOf(control) {
    return control.action === "dim" && control.direction && control.direction !== "alternate" ? `dim-${control.direction}` : control.action;
  }

  /// A press on a Remote shown: its Button or Wheel lights up, and its Controls open when nothing else is open.
  function event(change) {
    if (!shown || location.pathname.split("/")[1] !== "remotes" || change.characteristic !== "Programmable Switch Event") return;
    const remote = shown.data.remotes.find((one) => one.id === change.id);
    const service = change.subtype ?? `iid:${change.serviceIID}`;
    const part = remote?.parts.find((one) => one.services.includes(service));
    const row = part && shown.rows.get(rowKey(remote.id, part.id));
    if (!row?.isConnected) return;
    row.classList.remove("pressed");
    void row.offsetWidth;   // the flash again for a second press
    row.classList.add("pressed");
    row.scrollIntoView({ block: "nearest", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
    if (shown.admin && !document.querySelector("dialog[open]")) openEditor(remote, part, row);
  }

  window.HomeswiftRemotes = { view, event };
})();
