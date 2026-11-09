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

  /// What a set of targets is, for the words: lights, shutters, or both.
  function drives(ids, targets) {
    const kinds = new Set(ids.map((id) => targets.get(id)?.kind).filter(Boolean));
    return kinds.has("shutter") ? (kinds.has("light") ? "both" : "shutters") : "lights";
  }

  /// An action's words, for what its targets are: a shutter opens and closes where a light brightens and dims.
  function actionWords(action, direction, kind) {
    const pick = (lights, shutters, both) => ({ lights, shutters, both })[kind]();
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
    if (control.action === "scene") return t("Runs {scene}", { scene: lists.scenes.get(control.scene)?.name ?? control.scene });
    const words = actionWords(control.action, control.direction, drives(control.targets ?? [], lists.targets));
    const names = (control.targets ?? []).map((id) => lists.targets.get(id)?.name ?? t("A missing accessory"));
    return names.length ? `${words} · ${names.join(", ")}` : words;
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
    const lines = part.gestures.map((gesture) => {
      const control = controls.find((one) => one.gesture === gesture);
      return control ? el("li", {}, el("span", { class: "remote-gesture", text: gestureNames[gesture]() }), el("span", { text: describe(control, lists) })) : null;
    }).filter(Boolean);
    const starts = part.automations.map((automation) => el("li", { class: "muted" },
      el("span", { class: "remote-gesture", text: t("Automation") }), el("a", { href: `/automations/${enc(automation.id)}`, text: automation.name })));
    const homeKit = part.homeKit.length ? t("Home app: {buttons}", { buttons: part.homeKit.map((number) => t("Button {number}", { number })).join(", ") }) : null;
    const body = el("span", { class: "body" },
      el("span", { class: "remote-part-name" }, el("strong", { text: partName(part, remote) }), homeKit ? el("span", { class: "muted", text: homeKit }) : null),
      lines.length || starts.length ? el("ul", { class: "remote-controls" }, lines, starts) : el("span", { class: "muted", text: t("Does nothing yet") }));
    const glyph = el("span", { class: "remote-part-glyph", "aria-hidden": "true" }, HomeswiftCommon.icon(part.kind === "wheel" ? "loop" : "press"));
    if (!admin) return el("div", { class: "remote-part" }, glyph, body);
    return el("button", { type: "button", class: "remote-part", "aria-label": t("{name}: set what it does", { name: partName(part, remote) }),
      onclick: (event) => openEditor(remote, part, event.currentTarget) }, glyph, body,
      el("span", { class: "chevron", "aria-hidden": "true" }, HomeswiftCommon.icon("forward")));
  }

  /// A part's Controls in the side sheet: what it drives (and their Power Switches), then what each gesture does.
  function openEditor(remote, part, trigger) {
    const { data, lists } = shown;
    const mine = remote.controls.filter((control) => control.part === part.id);
    // A part's gestures drive the same lights; one with none yet starts from its Channel's other part.
    const driving = mine.find((control) => control.targets?.length)
      ?? remote.controls.find((control) => control.targets?.length && remote.parts.some((other) => other.id === control.part && other.channel != null && other.channel === part.channel));
    // Listed by room in the home's order (no room last), the pills keeping one kind; a chosen one's chip names its room.
    // A light without brightness says so: it only turns on and off.
    const roomRank = (room) => { const at = (data.rooms ?? []).indexOf(room); return room == null ? Infinity : at < 0 ? (data.rooms ?? []).length : at; };
    const byRoom = (list) => list.slice().sort((a, b) => roomRank(a.room) - roomRank(b.room)
      || (a.room ?? "").localeCompare(b.room ?? "") || a.name.localeCompare(b.name, undefined, { numeric: true }));
    const choice = (one, kind) => {
      const only = one.onOffOnly ? t("On and off only") : null;
      return { value: one.id, group: one.room ?? t("No room"), filter: kind,
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
      const rows = [...list.filter((one) => !inGroup.has(one.id)), ...whole.map((group) => ({ ...group, room: group.members[0].room ?? null }))];
      return byRoom(rows).flatMap((row) => {
        if (!row.members) return [choice(row, kindOf(row))];
        const heading = row.room ?? t("No room");
        return [{ title: row.name, group: heading, filter: kindOf(row.members[0]), members: row.members.map((one) => one.id),
          search: row.members.map((one) => one.name).join(" ") },
        ...byRoom(row.members).map((one) => ({ ...choice(one, kindOf(one)), group: heading, nested: true, search: row.name }))];
      });
    };
    const sceneChoices = byRoom(data.scenes).map((scene) => choice(scene, "Scenes"));
    const targetPicker = HomeswiftForms.searchSet(listed(data.targets, (one) => one.kind === "shutter" ? "Blinds" : "Lights"), driving?.targets ?? []);
    const powerPicker = HomeswiftForms.searchSet(listed(data.power, (one) => one.kind === "outlet" ? "Outlets" : "Switches"), driving?.power ?? []);
    const options = driving ?? mine[0] ?? {};
    const step = el("input", { type: "number", min: 1, max: 25, value: options.step ?? 5, "aria-describedby": "remote-step-help" });
    const powerDelay = el("input", { type: "number", min: 1, max: 30, value: options.powerDelay ?? 5 });
    const reversed = el("input", { type: "checkbox", role: "switch", checked: options.reversed === true });
    const kind = () => drives(targetPicker.get(), lists.targets);

    // Each gesture: a choice of what it does; the words follow what it drives.
    const gestureFields = part.gestures.map((gesture) => {
      const control = mine.find((one) => one.gesture === gesture);
      const select = el("select", { "aria-label": gestureNames[gesture]() });
      const scenePicker = HomeswiftForms.searchSelect(sceneChoices, control?.scene, t("Choose a scene"));
      const sceneRow = el("div", { class: "remote-scene" }, scenePicker.button);
      const fill = () => {
        const current = select.value || (control ? valueOf(control) : "");
        // Stopping is for shutters: offered when it drives some (or already chosen).
        const offered = choicesFor(gesture).filter(([value, action]) => action !== "stop" || kind() !== "lights" || current === value);
        select.replaceChildren(el("option", { value: "", text: t("Nothing") }), ...offered.map(([value, action, direction]) =>
          el("option", { value, text: action === "scene" ? t("Runs a scene") : actionWords(action, direction, kind()) })));
        select.value = current;
        sceneRow.hidden = select.value !== "scene";
      };
      select.addEventListener("change", () => { sceneRow.hidden = select.value !== "scene"; syncHoldAndLong(); });
      fill();
      // A long press and a hold are the same press: the one not chosen says why it waits.
      const help = gesture === "long" && part.gestures.includes("hold") ? el("span", { class: "help", text: t("A long press and a hold are the same press: choose one.") }) : null;
      return { gesture, select, fill, scene: scenePicker, row: el("label", { class: "field" }, el("span", { class: "field-title", text: gestureNames[gesture]() }), select, sceneRow, help) };
    });
    // A long press and a hold are the same press: one or the other.
    const syncHoldAndLong = () => {
      const hold = gestureFields.find((one) => one.gesture === "hold"), long = gestureFields.find((one) => one.gesture === "long");
      if (!hold || !long) return;
      long.select.disabled = hold.select.value !== "";
      hold.select.disabled = long.select.value !== "";
    };
    syncHoldAndLong();
    // Each gesture keeps the targets and Power Switches it has (the Assistant may give each its own) until the list
    // here changes.
    let targetsChanged = false, powerChanged = false;
    targetPicker.node.addEventListener("change", () => { targetsChanged = true; gestureFields.forEach((one) => one.fill()); });
    powerPicker.node.addEventListener("change", () => { powerChanged = true; });

    const message = el("p", { class: "muted", role: "status" });
    return HomeswiftCommon.openSheet((done) => {
      const save = el("button", { type: "button", class: "primary", actionIcon: "check", text: t("Save"), onclick: () => HomeswiftCommon.busyButton(save, async () => {
        const targets = targetPicker.get(), power = targets.length ? powerPicker.get() : [];
        const made = gestureFields.filter((one) => one.select.value).map((one) => {
          const [, action, direction] = choicesFor(one.gesture).find(([value]) => value === one.select.value);
          const control = { part: part.id, gesture: one.gesture, action };
          if (action === "scene") {
            control.scene = one.scene.get();
          } else {
            const kept = !targetsChanged && mine.find((old) => old.gesture === one.gesture && old.targets?.length);
            control.targets = kept ? kept.targets : targets;
            const powered = kept && !powerChanged ? kept.power ?? [] : power;
            if (powered.length) { control.power = powered; if (Number(powerDelay.value) !== 5) control.powerDelay = Number(powerDelay.value); }
            if (direction) control.direction = direction;
            if (["dim", "step", "toggle"].includes(action) && Number(step.value) !== 5) control.step = Number(step.value);
            if (action === "step" && reversed.checked) control.reversed = true;
          }
          return control;
        });
        if (made.some((control) => control.action === "scene" && !control.scene)) throw new Error(t("Choose the scene it runs."));
        if (made.some((control) => control.action !== "scene" && !control.targets.length)) throw new Error(t("Choose what it drives."));
        const controls = [...remote.controls.filter((control) => control.part !== part.id), ...made];
        await api(`/api/settings/accessories/${enc(remote.id)}${remote.instance ? `?instance=${enc(remote.instance)}` : ""}`, { method: "PATCH", body: { controls: controls.length ? controls : null } });
        remote.controls = controls;
        // Only this remote is drawn again: its rows (and the presses that find them) follow.
        document.getElementById(sectionID(remote.id))?.replaceWith(remoteSection(remote));
        done(true);
      }, { report: (e) => { message.className = "error"; message.textContent = e.message; } }) });
      return el("div", { class: "account-form remote-sheet" },
        el("div", { class: "setup-sheet-head" }, HomeswiftCommon.tile(part.kind === "wheel" ? "loop" : "press", "blue"),
          el("div", {}, el("h2", { id: "remote-sheet-title", text: partName(part, remote) }), el("p", { class: "muted setup-method", text: remote.name }))),
        el("section", { class: "remote-sheet-section" },
          el("h3", { text: t("What it drives") }),
          el("p", { class: "muted", text: t("Lights it dims and switches, shutters it moves. Locks, doors and alarms are never driven by a remote.") }),
          targetPicker.node),
        el("section", { class: "remote-sheet-section" },
          el("h3", { text: t("What each gesture does") }), gestureFields.map((one) => one.row)),
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
      default: return [["toggle", "toggle"], ["on", "on"], ["off", "off"], ["scene", "scene"], ["stop", "stop"]];
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
