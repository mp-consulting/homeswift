// Settings (docs/adr/0002-schema-declares-every-setting.md): an accessory's Accessory Settings in one view, drawn from
// GET /api/settings/accessories/<id> (the sheet the wall's ⋯ opens, the plugin's Devices, Setup's last step), and a
// plugin instance's Settings page (/plugins/<slug>/settings): its Plugin Settings form, its account and its devices.
// Both draw the plugin's fields with the one schema renderer (forms.js). app.js lends its helpers to the Settings page;
// the accessory's sheet needs only common.js and forms.js, so a plugin page opens it over itself too
// (plugin.js's openAccessorySettings).
(() => {
  "use strict";

  const { el, tile } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;
  const app = () => window.HomeswiftApp;
  // The web UI's requests (its sign-in handling) under app.js; common.js's on a plugin page.
  const api = (...args) => (app()?.api ?? HomeswiftCommon.api)(...args);
  const enc = encodeURIComponent;
  const confirmAction = (options) => HomeswiftCommon.confirmAction(options);
  /// An accessory's settings route, with the block it is in for one that is not on the bridge.
  const accessoryPath = (id, instance) => `/api/settings/accessories/${enc(id)}${instance ? `?instance=${enc(instance)}` : ""}`;

  /// A field's quiet state beside its title: Saving…, then Saved for a moment (with what reloaded), or the error,
  /// which stays until the next change and marks its control invalid.
  function setState(node, kind, text) {
    if (!node) return;
    clearTimeout(node.timer);
    node.dataset.state = kind;
    node.textContent = text;
    if (kind === "error") node.control?.setAttribute("aria-invalid", "true"); else node.control?.removeAttribute("aria-invalid");
    if (kind === "ok") node.timer = setTimeout(() => { node.textContent = ""; node.dataset.state = ""; }, 2400);
  }
  let ids = 0;
  const stateNode = () => el("span", { class: "field-state", role: "status", "aria-live": "polite", id: `field-state-${++ids}` });
  /// A control named by its title alone and described by its help and its state, rather than by all the text of the
  /// label around it (which would read the help as part of its name).
  function describe(control, title, help, state) {
    for (const node of [title, help]) if (node && !node.id) node.id = `field-part-${++ids}`;
    control.setAttribute("aria-labelledby", title.id);
    control.setAttribute("aria-describedby", [help?.id, state?.id].filter(Boolean).join(" "));
    if (state) state.control = control;
  }

  /// What a write did, in a few words for a field's state.
  function savedWords(result, instance) {
    if ((result.reloaded ?? []).length) return t("Saved · {plugin} reloads", { plugin: instance });
    const refused = (result.appleHomeRefused ?? [])[0];
    if (refused) return t("Saved; Apple Home refused: {reason}", { reason: HomeswiftI18n.message(refused.reason) });
    return t("Saved");
  }

  /// A section of the editor: a heading with what it is about, then its rows. One surface: sections, not cards.
  const section = (title, note, ...rows) => el("section", { class: "settings-section" },
    title ? el("div", { class: "settings-section-head" }, el("h3", { text: title }), note ? el("p", { class: "help", text: note }) : null) : null,
    ...rows);

  /// A switch row: its title, what it means, and its state.
  function switchRow({ title, help, checked, disabled = false, onChange }) {
    const input = el("input", { type: "checkbox", role: "switch", checked, disabled });
    const state = stateNode();
    const name = el("span", { text: title });
    const note = help ? el("span", { class: "help", text: help }) : null;
    describe(input, name, note, state);
    input.addEventListener("change", () => onChange(input.checked, state, input));
    return { input, node: el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
      el("span", {}, el("span", { class: "field-title" }, name, state), note)) };
  }

  const isMap = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  /// `after` as a merge onto `before`: for objects, each key `before` has and `after` has not given as null.
  function mergePatch(before, after) {
    if (!isMap(before) || !isMap(after)) return after;
    const patch = Object.fromEntries(Object.entries(after).map(([key, value]) => [key, mergePatch(before[key], value)]));
    for (const key of Object.keys(before)) if (!Object.hasOwn(after, key)) patch[key] = null;
    return patch;
  }

  /// The plugin's layout for an accessory's own fields: its groups (Audio, Motion…) with only the fields the accessory
  /// has, closed, after the fields no group holds (a controller's address). Undefined without groups to keep.
  function accessoryLayout(layout, properties, schema) {
    if (!Array.isArray(layout)) return undefined;
    /// What one entry of the list a group draws is called (UniFi Protect Controller), from the plugin's schema.
    const entryTitle = (group) => {
      const list = group.items?.find((item) => item?.key && !item.key.includes("[]"))?.key;
      return list ? schema?.properties?.[list]?.items?.title : undefined;
    };
    const placed = new Set();
    // An entry of a list of Plugin Settings (`controllers[].address`) is the accessory's own `address`: a controller's
    // device carries what its entry said, and that group stays open, under the entry's name.
    let fromList = false;
    const keep = (item) => {
      let key = typeof item === "string" ? item : item?.key;
      if (key !== undefined && key.includes("[].")) { key = key.slice(key.lastIndexOf("[].") + 3); fromList ||= Object.hasOwn(properties, key); }
      if (key !== undefined && Object.hasOwn(properties, key)) {
        placed.add(key);
        return typeof item === "string" || item.items ? key : { ...item, key };
      }
      if (!Array.isArray(item?.items)) return null;
      const items = item.items.flatMap((child) => keep(child) ?? []);
      // A list's own item (`controllers`) holds its entries' fields: they take its place in the group.
      return items.length ? (key !== undefined ? items : { ...item, items }) : null;
    };
    const groups = layout.filter((item) => Array.isArray(item?.items)).map((item) => {
      fromList = false;
      const group = keep(item);
      if (!group?.title) return group;
      return fromList ? { ...group, title: entryTitle(item) ?? group.title, expandable: true, expanded: true } : { ...group, expandable: true, expanded: false };
    }).filter(Boolean)
      .map((group) => (Array.isArray(group) ? { items: group } : group));
    if (!groups.length) return undefined;
    return [...Object.keys(properties).filter((key) => !placed.has(key)), ...groups];
  }

  /// The rooms as a pop-up menu under `trigger`: No room, each room (`current` ticked), and New room…, which asks for a
  /// name; `onChoose(name)` gets the one chosen, "" for none. The Settings sheet's Room and a card's Move to room.
  function roomMenu(trigger, { current = "", rooms = [], maxLength = 64, keyboard = false, onChoose }) {
    const names = current && !rooms.includes(current) ? [current, ...rooms] : rooms;
    HomeswiftCommon.menu(trigger, [
      { label: t("No room"), checked: !current, onSelect: () => onChoose("") },
      names.length ? { separator: true } : null,
      ...names.map((name) => ({ label: name, icon: "room", checked: name === current, onSelect: () => onChoose(name) })),
      { separator: true },
      { label: t("New room…"), icon: "plus", pinned: true, onSelect: async () => {
        const text = (await HomeswiftCommon.promptDialog(t("The new room's name."), ""))?.trim().replace(/\s+/g, " ");
        if (text) await onChoose(text.slice(0, maxLength));
        trigger.focus();
      } },
    ], { keyboard, search: names.length > 8 ? t("Search rooms") : null });
  }

  // ---- An accessory's settings ------------------------------------------------------------------------------

  /// The Accessory Settings editor of `accessoryID` (`instance`, its block's name, for a device not on the bridge),
  /// every field saving on its own: Name, room, Hidden, Not in Home, Parts, then the plugin's own (from its
  /// accessorySchema, with "Default (X)" while a plugin-wide default applies), then Exclude and Forget. `device`, the
  /// discovery's entry when the caller has it, gives the Parts; otherwise the plugin is asked. `onChange(key)` is
  /// told of each change saved, `onGone()` once it is forgotten; `onTitle(name)` of its name as it changes.
  function accessoryEditor({ accessoryID, instance = null, device = null, onChange = () => {}, onGone = () => {}, onTitle = () => {} }) {
    const node = el("div", { class: "accessory-settings", "aria-busy": "true" }, el("p", { class: "setup-loading muted" }, el("span", { class: "spinner", "aria-hidden": "true" }), el("span", { text: t("Loading…") })));
    // Enter commits a field (its change saves it) rather than submitting a form the editor sits in (Setup's sheet).
    node.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.isComposing && event.target.matches?.("input:not([type=checkbox])")) { event.preventDefault(); event.target.blur(); }
    });
    const ready = load();
    return { node, ready };

    async function load() {
      let answer, rooms, schemaFile;
      try {
        [answer, rooms] = await Promise.all([api(accessoryPath(accessoryID, instance)), api("/api/rooms").catch(() => ({ rooms: [] }))]);
        // The plugin's words for its own fields (its schema's `i18n`), when it declares some.
        schemaFile = Object.values(answer.fields ?? {}).some((field) => !field.core)
          ? await api(`/api/plugins/${enc(answer.platform)}/schema`, { raw: true }).then(JSON.parse).catch(() => null) : null;
      } catch (e) {
        node.removeAttribute("aria-busy");
        node.replaceChildren(el("p", { class: "error", role: "alert", text: e.message }));
        return;
      }
      draw(answer, rooms, schemaFile);
    }

    function draw(answer, home, schemaFile) {
      node.removeAttribute("aria-busy");
      const settings = answer.settings ?? {};
      if (settings.name || answer.name) onTitle(settings.name || answer.name);
      const fields = answer.fields ?? {};
      const plugin = answer.instance;
      const mirrored = answer.mirroredFrom ?? null;
      const id = answer.accessory;
      /// Saves one key (null clears it); answers whether it was saved.
      const save = async (patch, state, key) => {
        setState(state, "busy", t("Saving…"));
        try {
          const result = await api(accessoryPath(id, plugin), { method: "PATCH", body: patch });
          setState(state, "ok", savedWords(result, plugin));
          // What the bridge kept (a room spelled as it already was, a name tidied), else what was sent.
          const kept = (result.accessories ?? []).find((one) => one.accessory === id)?.settings;
          if (kept) {
            for (const name of Object.keys(settings)) delete settings[name];
            Object.assign(settings, kept);
          } else {
            for (const [name, value] of Object.entries(patch)) {
              if (value === null) delete settings[name]; else settings[name] = value;
            }
          }
          onChange(key);
          return true;
        } catch (e) {
          // The schema's words without their place in config.json (`_accessories.<id>.<key> must be…`): the field is the place.
          setState(state, "error", e.problems ? e.problems.map((problem) => HomeswiftI18n.message(problem.text).replace(/^_accessories\.\S+\s+/, "")).join("; ") : e.message);
          return false;
        }
      };

      // Name: one name, on these pages and in the Home app. A mirrored accessory is named where it comes from.
      const nameState = stateNode();
      const name = el("input", { type: "text", value: settings.name ?? "", maxLength: fields.name?.schema?.maxLength ?? 64, readOnly: Boolean(mirrored || fields.name?.readOnly),
        placeholder: answer.name ?? t("The name its plugin gives it"), autocomplete: "off", spellcheck: false });
      if (mirrored) name.value = answer.name ?? "";
      name.addEventListener("change", async () => {
        const text = name.value.trim().replace(/\s+/g, " ");
        name.value = text;
        // Back to what is saved: an earlier error no longer applies.
        if (text === (settings.name ?? "")) { setState(nameState, "", ""); return; }
        if (await save({ name: text || null }, nameState, "name")) {
          name.value = settings.name ?? "";
          onTitle(settings.name || answer.name || id);
        }
      });
      const nameTitle = el("span", { text: t("Name") });
      const nameHelp = el("span", { class: "help", text: mirrored ? t("Named in {source}: rename it there.", { source: mirrored }) : t("In the Home app too. Empty gives it back the name its plugin gives it.") });
      describe(name, nameTitle, nameHelp, nameState);
      const nameField = el("label", { class: "field" }, el("span", { class: "field-title" }, nameTitle, nameState), name, nameHelp);

      // Room: one of the rooms, or a new name that adds it. Whether Apple Home follows, said beside it.
      // Room: a pop-up menu of the rooms, the current one ticked, with No room and New room… (which adds one).
      const roomState = stateNode();
      const roomNames = (home.rooms ?? []).map((one) => one.name);
      const homeFollows = mirrored || home.homeLink?.linked === true;
      const room = el("button", { type: "button", class: "select-button", "aria-haspopup": "menu" });
      const showRoom = () => {
        room.textContent = settings.room || t("No room");
        room.classList.toggle("placeholder", !settings.room);
      };
      const chooseRoom = async (text) => {
        if (text === (settings.room ?? "")) { setState(roomState, "", ""); return; }
        // None is "" for a mirrored accessory (not the room its controller suggests), else cleared.
        if (await save({ room: text || (mirrored ? "" : null) }, roomState, "room")) showRoom();
      };
      room.addEventListener("click", (event) => roomMenu(room, { current: settings.room, rooms: roomNames, maxLength: fields.room?.schema?.maxLength,
        keyboard: event.detail === 0, onChoose: chooseRoom }));
      showRoom();
      const roomTitle = el("span", { text: t("Room") });
      const roomHelp = el("span", { class: "help", text: mirrored ? t("Also moves it in {source}.", { source: mirrored })
        : homeFollows ? t("Also moves it in the Home app.")
          : t("Moves it in the Home app too once this bridge is linked to Apple Home through Homeswift Wingman.") });
      describe(room, roomTitle, roomHelp, roomState);
      const roomField = el("div", { class: "field" }, el("span", { class: "field-title" }, roomTitle, roomState), room, roomHelp);

      // Hidden and Not in Home: where it shows.
      const hidden = switchRow({ title: t("Hidden"), help: t("Off the wall; still in the Home app."), checked: settings.hidden === true,
        onChange: async (on, state, input) => { if (!await save({ hidden: on || null }, state, "hidden")) input.checked = !on; } });
      const notInHome = mirrored ? null : switchRow({ title: t("Not in Home"), help: t("Out of the Home app, which loses its room, scenes and automations; the wall and Matter keep it."),
        checked: settings.notInHome === true,
        onChange: async (on, state, input) => {
          if (on && !await confirmAction({ title: t("Take {name} out of the Home app?", { name: answer.name ?? id }),
            text: t("The Home app loses it, with its room, scenes and automations. Homeswift and Matter keep it; put back, the Home app adds it as a new accessory."),
            confirmLabel: t("Take it out"), confirmIcon: "house" })) { input.checked = false; return; }
          if (!await save({ notInHome: on || null }, state, "notInHome")) input.checked = !on;
        } });

      // Separate Functions: each thing it does an accessory of its own, which Apple Home can group and put in a room.
      const functions = answer.functions ?? [];
      const separate = functions.length > 1 && !mirrored ? switchRow({ title: t("Separate Functions"),
        help: t("In Apple Home, each thing it does becomes an accessory of its own: {functions}.", { functions: functions.join(", ") }),
        checked: settings.separateFunctions === true,
        onChange: async (on, state, input) => {
          if (!await confirmAction({ title: on ? t("Separate the Functions of {name}?", { name: answer.name ?? id }) : t("Join the Functions of {name} back?", { name: answer.name ?? id }),
            text: on ? t("Apple Home's scenes and automations that use what moves need redoing. Each new accessory can have its own name, room and group.")
              : t("The separated accessories leave Apple Home, with their scenes and automations, and the groups they were in may dissolve."),
            confirmLabel: on ? t("Separate") : t("Join back"), confirmIcon: "group" })) { input.checked = !on; return; }
          if (!await save({ separateFunctions: on || null }, state, "separateFunctions")) input.checked = !on;
        } }) : null;
      const functionOf = answer.functionOf ? el("p", { class: "help", text: t("A Function of {name}: its other settings are there.", { name: answer.functionOf.name }) }) : null;

      // Energy: what each of its meters measures in the home's energy. Applies at once; the plugin keeps running.
      const roleNames = { solar: t("Solar production"), home: t("The home's use"), grid: t("The grid connection"), battery: t("A battery"), none: t("This device alone") };
      const energySection = (answer.meters ?? []).length ? section(t("Energy"),
        t("A meter that measures the grid, solar, the home or a battery adds to the home's energy on the Status page; any other is one device's consumption."),
        ...answer.meters.map((meter) => {
          const state = stateNode();
          const suggested = meter.suggestedRole ?? "none";
          const chosen = settings.energyRoles?.[meter.key] ?? "";
          // The suggestion first, as the empty choice: chosen again, the person's role goes and the plugin's stands.
          const select = el("select", {}, el("option", { value: "", text: t("{role} (suggested)", { role: roleNames[suggested] }), selected: chosen === "" }),
            ...Object.entries(roleNames).filter(([value]) => value !== suggested).map(([value, text]) => el("option", { value, text, selected: chosen === value })));
          select.addEventListener("change", async () => {
            const before = settings.energyRoles?.[meter.key] ?? "";
            if (!await save({ energyRoles: { [meter.key]: select.value || null } }, state, "energyRoles")) select.value = before;
          });
          const title = el("span", { text: meter.label ? t("Meter: {meter}", { meter: meter.label }) : t("What it measures") });
          const help = el("span", { class: "help", text: t("Counts from now on; the history it measured stays as it was.") });
          describe(select, title, help, state);
          return el("label", { class: "field" }, el("span", { class: "field-title" }, title, state), select, help);
        })) : null;

      // Parts: from the discovery, which knows their names; the plugin reloads with each.
      const partsBox = el("div", { class: "settings-parts" });
      const partsSection = section(t("Parts"), t("Switched off, a part is left out while the device stays. A change reloads {plugin}.", { plugin }), partsBox);
      partsSection.hidden = true;
      const drawParts = (found) => {
        const parts = found?.parts ?? [];
        if (!parts.length || settings.excluded) return;
        const own = settings.parts ?? {};
        partsBox.replaceChildren(...parts.map((part) => switchRow({
          title: t(part.name), checked: own[part.id] ?? part.included,
          onChange: async (on, state, input) => {
            if (!await save({ parts: { ...(settings.parts ?? {}), [part.id]: on } }, state, "parts")) input.checked = !on;
          },
        }).node));
        partsSection.hidden = false;
      };
      if (device) drawParts(device);
      else if (fields.parts) {
        api("/api/setup/discover", { method: "POST", body: { platform: answer.platform, name: answer.instance } })
          .then((found) => drawParts(found.devices.find((one) => one.deviceID === answer.deviceID)), () => {});
      }

      // The plugin's own Accessory Settings, by the same renderer as its Plugin Settings.
      // In the order the schema declares them (the answer's object has none of its own).
      const declaredOrder = Object.keys(schemaFile?.accessorySchema?.properties ?? {});
      const rank = (key) => { const at = declaredOrder.indexOf(key); return at < 0 ? declaredOrder.length : at; };
      const own = Object.entries(fields).filter(([, field]) => !field.core).sort(([a], [b]) => rank(a) - rank(b));
      let pluginSection = null;
      if (own.length) {
        const properties = Object.fromEntries(own.map(([key, field]) => [key, field.schema]));
        // A plugin-wide setting left unset takes the default its schema declares: "Default (On)", not a bare "Default".
        const declared = (setting) => schemaFile?.schema?.properties?.[setting]?.default ?? null;
        const defaults = Object.fromEntries(own.filter(([, field]) => field.default).map(([key, field]) => [key, field.default.value ?? declared(field.default.setting)]));
        const values = Object.fromEntries(own.filter(([key]) => key in settings).map(([key]) => [key, settings[key]]));
        const form = HomeswiftForms.buildForm({ schema: { type: "object", properties }, layout: accessoryLayout(schemaFile?.layout, properties, schemaFile?.schema), i18n: schemaFile?.i18n }, values, {
          defaults,
          // Cleared, a field takes the plugin-wide default again (null clears the key); a map's entry taken out is a null
          // in it, as the bridge merges objects key by key.
          onCommit: (key, value, state) => save({ [key]: value === undefined ? null : mergePatch(settings[key], value) }, state, key),
        });
        pluginSection = section(t("Plugin settings"), t("Declared by {plugin} for it. A change reloads {plugin}.", { plugin }), form.element);
      }

      // Exclude (or Include) and Forget, set apart at the end.
      const excluded = settings.excluded === true;
      const setExcluded = (button, on) => HomeswiftCommon.busyButton(button, async () => {
        await api(accessoryPath(id, plugin), { method: "PATCH", body: { excluded: on || null } });
        onChange("excluded");
        reload();
      });
      const exclude = excluded
        ? el("button", { type: "button", actionIcon: "plus", text: t("Include"), onclick: (event) => setExcluded(event.currentTarget, false) })
        : el("button", { type: "button", class: "danger", actionIcon: "minus", text: t("Exclude"), onclick: async (event) => {
          const button = event.currentTarget;
          if (!await confirmAction({ title: t("Exclude {name}?", { name: answer.name ?? id }),
            text: t("{plugin} stops making it an accessory: it leaves the Home app, the wall and Matter until you include it again from {plugin}'s devices.", { plugin }),
            confirmLabel: t("Exclude"), confirmIcon: "minus" })) return;
          setExcluded(button, true);
        } });
      const forget = el("button", { type: "button", class: "danger", actionIcon: "trash", text: t("Forget"), onclick: async (event) => {
        const button = event.currentTarget;
        if (!await confirmAction({ title: t("Forget {name}?", { name: answer.name ?? id }),
          // A device the plugin makes (a Helper) cannot be found again: it is deleted.
          text: answer.addLabel ? [t("This deletes it and all its settings: its name, room and {plugin}'s settings for it.", { plugin }),
            t("It leaves the Home app with its room, scenes and automations, for good: {plugin} cannot find it again.", { plugin })]
            : [t("This drops its sign-in and all its settings: its name, room and {plugin}'s settings for it.", { plugin }),
              t("It leaves the Home app with its room, scenes and automations. If {plugin} still finds it, it is a device to set up again.", { plugin })],
          confirmLabel: t("Forget"), confirmIcon: "trash" })) return;
        HomeswiftCommon.busyButton(button, async () => {
          await api(accessoryPath(id, plugin), { method: "DELETE" });
          onGone();
        });
      } });
      const dangerRow = (title, text, button) => el("div", { class: "settings-danger-row" }, el("div", {}, el("strong", { text: title }), el("p", { class: "help", text })), button);
      const danger = el("section", { class: "settings-section settings-danger" },
        dangerRow(excluded ? t("Excluded") : t("Exclude"), excluded ? t("{plugin} makes no accessory of it: it is out of the Home app, the wall and Matter.", { plugin })
          : t("Out of the Home app, the wall and Matter, until you include it again from {plugin}'s devices.", { plugin }), exclude),
        dangerRow(t("Forget"), answer.addLabel ? t("Deletes it and its settings for good: {plugin} cannot find it again.", { plugin })
          : t("Drops its sign-in and its settings; it is only a device {plugin} finds again.", { plugin }), forget));

      // Power on: what a light does when its power comes back, its device's own or Natural Light (the bridge's), asked of
      // the bridge once the rest is drawn; nothing for an accessory whose plugin keeps none.
      const powerSection = section(t("Power on"), t("What it does when its power comes back, from a wall switch or after a power cut."));
      powerSection.hidden = true;
      api(`/api/power-on/${enc(id)}`).then((power) => powerOnRows(powerSection, power, id), () => {});

      // A Remote: what its Buttons and Wheels do is set on the Remotes page (its Controls), where this opens it.
      const remoteSection = fields.controls ? section(t("Its buttons"), t("What each button and wheel does is set on the Remotes page."),
        el("a", { class: "button", href: `/remotes/${enc(answer.accessory ?? accessoryID)}`, actionIcon: "remote", text: t("Set what its buttons do") })) : null;
      // The renderer's own buttons (a list's Add) never submit a form around the editor.
      for (const button of pluginSection?.querySelectorAll("button:not([type])") ?? []) button.type = "button";
      node.replaceChildren(...[
        excluded ? el("p", { class: "settings-note", role: "note", text: t("Excluded: {plugin} makes no accessory of it. Its settings wait until it is included again.", { plugin }) }) : null,
        section(null, null, nameField, roomField),
        section(t("Where it shows"), null, hidden.node, notInHome?.node ?? null, separate?.node ?? null, functionOf),
        powerSection,
        energySection,
        remoteSection,
        partsSection,
        pluginSection,
        danger,
      ].filter(Boolean));
    }

    async function reload() {
      node.setAttribute("aria-busy", "true");
      await load();
    }
  }

  /// A light's Power on, as the Hue app shows it: one choice of a list, each with what it does, Natural Light first;
  /// Custom's brightness and white unfold under it, each its light's last until set. A choice applies at once, to the
  /// device or to the bridge's Natural Light.
  function powerOnRows(box, power, id) {
    const words = {
      natural: [t("Natural light")],
      default: [t("Default"), t("Warm white, full brightness")],
      lastOn: [t("Last on"), t("On, in its last colour and brightness")],
      powerLoss: [t("Power loss recovery"), t("Stays off or turns back on, as it was")],
      off: [t("Off"), t("Stays off")],
      custom: [t("Custom"), t("On, at the brightness and white below")],
    };
    // Natural Light's words say the white it gives now, which a choice may change.
    const help = (behaviour) => behaviour === "natural"
      ? t("As it was, on or off, in the white for the time of day: {kelvin} K now", { kelvin: power.naturalWhite ?? "–" }) : words[behaviour][1];
    const support = power.support;
    const offered = Object.keys(words).filter((behaviour) => support.behaviours.includes(behaviour));
    if (!offered.length) return;
    const state = stateNode();
    const group = `power-on-${++ids}`;
    const custom = power.behaviour === "custom" ? power.current ?? {} : {};
    /// A value Custom may set, or leave as the light's last: the wall's slider (a light's fill, or its whites), dimmed
    /// and saying so while it keeps the last; moving it sets one.
    const setting = (label, { min, max, step = 1, start, unit, look }, value) => {
      let chosen = value ?? undefined;
      const keep = el("input", { type: "checkbox", checked: chosen === undefined });
      const slider = HomeswiftWidgets.level({ label, showLabel: false, min, max, step, format: (v) => `${v} ${unit}`, ...look },
        (v) => { chosen = v; keep.checked = false; paint(); choose("custom"); });
      const paint = () => {
        slider.set(chosen ?? start);
        slider.node.classList.toggle("unset", keep.checked);
        if (keep.checked) {
          slider.node.querySelector(".level-text").textContent = t("Its last");
          slider.node.setAttribute("aria-valuetext", t("Its last"));
        }
      };
      keep.addEventListener("change", () => { chosen = keep.checked ? undefined : chosen ?? start; paint(); choose("custom"); });
      paint();
      return { get: () => keep.checked ? undefined : chosen,
        node: el("div", { class: "field slider-field" }, el("span", { class: "field-title", text: label }), slider.node,
          el("label", { class: "power-on-keep" }, keep, el("span", { text: t("Keep its last") }))) };
    };
    const level = support.brightness ? setting(t("Brightness"), { min: 1, max: 100, start: 100, unit: "%", look: { fill: HomeswiftWidgets.brightnessFill() } }, custom.brightness) : null;
    const white = support.white ? setting(t("White"), { min: support.white[0], max: support.white[1], step: 50, start: 2700, unit: "K",
      look: { gradient: HomeswiftWidgets.whiteTrack(support.white[0], support.white[1]) } }, custom.temperature) : null;
    // Unfolds under Custom, its height eased (`.unfold`), out of the tab order while folded.
    const customBox = el("div", { class: "unfold power-on-custom" }, el("div", {}, level?.node ?? null, white?.node ?? null));
    const choices = offered.map((behaviour) => {
      const input = el("input", { type: "radio", name: group, value: behaviour, checked: power.behaviour === behaviour });
      const note = el("span", { class: "help", text: help(behaviour) });
      input.addEventListener("change", () => { if (input.checked) choose(behaviour); });
      return { behaviour, input, note, node: el("label", { class: "power-on-choice" }, input,
        el("span", { class: "power-on-text" }, el("span", { class: "field-title", text: words[behaviour][0] }), note)) };
    });
    const showCustom = () => {
      const open = (level || white) && choices.some((one) => one.behaviour === "custom" && one.input.checked);
      customBox.classList.toggle("open", Boolean(open));
      customBox.inert = !open;
    };
    const choose = async (behaviour) => {
      showCustom();
      setState(state, "busy", t("Saving…"));
      const body = { behaviour };
      if (behaviour === "custom") {
        body.brightness = level?.get();
        body.temperature = white?.get();
      }
      try {
        power = await api(`/api/power-on/${enc(id)}`, { method: "PUT", body });
        setState(state, "ok", t("Saved"));
      } catch (e) {
        setState(state, "error", e.message);
      }
      for (const one of choices) {
        one.input.checked = one.behaviour === power.behaviour;
        one.note.textContent = help(one.behaviour);
      }
      showCustom();
    };
    showCustom();
    box.querySelector(".settings-section-head h3")?.append(" ", state);
    box.append(el("div", { class: "power-on-choices", role: "radiogroup", "aria-label": t("Power on") }, choices.map((one) => one.node)), customBox);
    box.hidden = false;
  }

  /// The editor in a side sheet, from the wall's ⋯, a plugin's Devices or Setup: its name and plugin at the top, Done
  /// at the bottom. `after(changed)` runs once it has gone, with whether anything was saved (or it was forgotten).
  function openAccessory({ accessoryID, instance = null, device = null, name = null, glyph = "accessory", trigger = null, after = null }) {
    let changed = false, gone = false;
    HomeswiftCommon.openSheet((done) => {
      const title = el("h2", { id: "accessory-settings-title", tabIndex: -1, text: name ?? device?.name ?? accessoryID });
      const editor = accessoryEditor({ accessoryID, instance, device,
        onChange: () => { changed = true; },
        onGone: () => { gone = true; changed = true; done(true); },
        onTitle: (text) => { title.textContent = text; } });
      // Once drawn, the title takes the focus (rather than Done, or a field whose keyboard would cover a phone's sheet),
      // unless the person already moved into the editor; Tab goes on to the Name.
      editor.ready.then(() => { if (!editor.node.contains(document.activeElement)) title.focus({ preventScroll: true }); });
      return el("div", { class: "account-form accessory-settings-sheet" },
        el("div", { class: "setup-sheet-head" }, tile(glyph, "blue"),
          el("div", {}, title, el("p", { class: "muted setup-method", text: t("Settings") }))),
        editor.node,
        el("div", { class: "actions" }, el("button", { type: "button", class: "primary", actionIcon: "check", text: t("Done"), onclick: () => done() })));
    }, "accessory-settings-title", {
      returnFocus: trigger,
      onClose: () => {
        if (after) after(changed, gone);
        else if (changed) app()?.route();
        if (!gone && trigger?.isConnected) trigger.focus();
      },
    });
  }

  // ---- A plugin instance's Settings page ---------------------------------------------------------------------

  /// What a device's status is called, and its tone: set up is the usual state, a quiet dot.
  const statuses = {
    setUp: [() => t("Set up"), "on"],
    notResponding: [() => t("Not responding"), "away"],
    discovered: [() => t("Ready"), "on"],
    needsAuthorization: [() => t("Needs setup"), "away"],
    excluded: [() => t("Excluded"), "paused"],
  };

  /// /plugins/<slug>/settings (a plugin without a page of its own: /plugins/<slug>): its account, its Plugin Settings as
  /// one form saved at once (the plugin reloads once), its devices, then config.json and removal. `kit` is app.js's.
  async function pluginPage(main, { block, plugin, instance, plugins, kit }) {
    const platform = block.platform;
    const path = `/api/settings/plugins/${enc(platform)}/${enc(block.name)}`;
    const [current, schemaFile] = await Promise.all([api(path), api(`/api/plugins/${enc(platform)}/schema`, { raw: true }).then(JSON.parse).catch(() => null)]);
    kit.readSecrets(plugins);
    const hasPage = Boolean(plugin?.hasPages && instance && !instance.paused);
    const accountMethod = plugin?.accountAuthorization && plugin.accountAuthorization !== "none" ? plugin.accountAuthorization : null;

    // The form, from the schema file (its layout and words) with the values the settings route gives (secrets as the
    // placeholder, kept as they are). A plugin with an account keeps its sign-in in the vault: no credential here.
    let form = null, getValue = () => ({ ...current.settings });
    const formBox = el("div", { class: "plugin-settings-form" });
    const root = schemaFile ? { ...schemaFile, schema: structuredClone(schemaFile.schema ?? {}) } : null;
    if (root && accountMethod) {
      const properties = root.schema.properties ?? root.schema;
      for (const key of Object.keys(properties)) if (kit.isSecretKey(key)) delete properties[key];
    }
    const build = (value) => {
      form = HomeswiftForms.buildForm(root, value);
      formBox.replaceChildren(form.element);
      getValue = form.getValue;
    };
    if (root && Object.keys(root.schema.properties ?? {}).length) build(current.settings);
    else formBox.replaceChildren(el("p", { class: "muted", text: t("{plugin} declares no settings of its own.", { plugin: plugin?.name ?? platform }) }));

    // One Save for the form: only what changed is sent, a key taken out cleared (null).
    const sorted = (value) => Array.isArray(value) ? value.map(sorted)
      : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])])) : value;
    const same = (a, b) => JSON.stringify(sorted(a)) === JSON.stringify(sorted(b));
    const patchFrom = (before, after) => {
      const patch = {};
      for (const key of new Set([...Object.keys(before), ...Object.keys(after)])) {
        if (!(key in after)) { patch[key] = null; continue; }
        if (same(before[key], after[key])) continue;
        const [a, b] = [before[key], after[key]];
        // Objects key by key, as the route merges them; lists and values replaced.
        patch[key] = a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b) ? patchFrom(a, b) : b;
      }
      return patch;
    };
    // What is saved, as the form reads it back: its defaults filled in and the keys it does not show left out, so a page
    // just opened has no unsaved change and a save neither writes defaults nor clears what the form leaves alone.
    const asForm = () => { try { return structuredClone(getValue()); } catch { return structuredClone(current.settings); } };
    let saved = asForm();
    const dirty = () => { try { return !same(saved, getValue()); } catch { return false; } };
    const message = el("span", { class: "muted" });
    // An icon and a label each, as the other save bars: at phone width Revert keeps its icon alone.
    const save = el("button", { class: "primary settings-action" }, HomeswiftCommon.icon("check"), el("span", { text: t("Save") }));
    const revert = el("button", { class: "settings-action" }, HomeswiftCommon.icon("restore"), el("span", { text: t("Revert") }));
    const update = () => {
      const changed = dirty();
      save.disabled = !changed;
      revert.disabled = !changed;
      if (!message.classList.contains("error") && !message.classList.contains("ok")) {
        message.className = changed ? "dirty" : "muted";
        message.textContent = changed ? t("Unsaved changes · a save reloads {name} once", { name: block.name }) : t("Saved");
      }
    };
    formBox.addEventListener("input", () => { message.className = ""; update(); });
    formBox.addEventListener("change", () => { message.className = ""; update(); });
    formBox.addEventListener("click", () => setTimeout(update, 0));
    save.addEventListener("click", () => HomeswiftCommon.busyButton(save, async () => {
      message.className = "muted";
      message.textContent = t("Saving…");
      try {
        const value = getValue();
        const result = await api(path, { method: "PATCH", body: patchFrom(saved, value) });
        saved = structuredClone(value);
        message.className = "ok";
        message.textContent = (result.reloaded ?? []).length ? t("Saved. {name} reloaded with it.", { name: block.name }) : kit.savedText(result);
        // A block renamed lives at its own address now.
        if (value.name && value.name !== block.name) { kit.setLeaveGuard(null); app().navigate(`/plugins/${HomeswiftCommon.slug(value.name)}/settings`, { replace: true }); return; }
      } catch (e) {
        message.className = "error";
        if (!e.problems) { message.textContent = e.message; return; }
        message.replaceChildren(el("span", { text: t("The plugin's schema refuses this:") }), kit.problemList(e.problems.map((problem) => ({ text: HomeswiftI18n.message(problem.text) }))));
      }
      update();
    }, { report: (e) => { message.className = "error"; message.textContent = e.message; } }));
    revert.addEventListener("click", () => { if (form) build(saved); saved = asForm(); message.className = ""; update(); });

    // The account, for a plugin that signs in: where it stands and Set up (again once it has been), which opens Setup.
    // What the Plugins page knew draws it first; the discovery's answer then says where it stands now.
    let accountState = null;
    const accountLine = el("span", { class: "help account-state", text: t("Checking…") });
    const accountButton = el("button", { type: "button", actionIcon: "pair", onclick: (event) => HomeswiftSetup.setUp({ block, plugin, firstTime: accountState === "notSetUp", trigger: event.currentTarget, after: () => devices.load() }) });
    const accountRow = accountMethod ? el("div", { class: "settings-row" },
      tile(accountMethod === "buttonPress" || accountMethod === "deviceCode" ? "pair" : accountMethod === "apiKey" ? "key" : "user", "orange"),
      el("div", { class: "who" }, el("strong", { text: t("Account") }), accountLine),
      accountButton) : null;
    const accountSection = accountRow ? section(t("Account"), " ", accountRow) : null;
    const accountNote = accountSection?.querySelector(".settings-section-head .help");
    /// Where the account stands (`state`, nil before anything says) and whether it Needs Authorization (the server's
    /// `needsAuthorization`): in its row, its section's note and the header's state. The Plugins page's answer draws it
    /// first, the discovery's once it comes.
    const showAccount = (state, needs) => {
      if (!accountRow) return;
      accountState = state;
      // Set up again only once there is something to set up again: a refused one too.
      accountButton.textContent = !state || state === "notSetUp" ? t("Set up") : t("Set up again");
      accountButton.classList.toggle("primary", needs);
      accountNote.textContent = state === "notSetUp" ? t("Its sign-in is kept in the vault, never in these settings.")
        : t("Its sign-in is kept in the vault, never in these settings: set it up again to change it.");
      if (state) {
        accountLine.textContent = state === "setUp" ? t("Set up")
          : state === "refused" ? t("Refused: what it had no longer works. Set it up again.")
          : plugin?.accountRequired !== false ? t("Not set up yet: its devices show once it is.")
          : t("Optional and not set up. {adds}", { adds: plugin.accountAdds ? t(plugin.accountAdds) : t("Its devices work without it.") });
        accountLine.dataset.tone = needs ? "away" : "";
      }
      // The header says it too: a Setup just done changes it.
      if (instance) {
        const [text, tone] = kit.blockState(block, plugin, { ...instance, accountState: state, needsAuthorization: needs });
        statePill.className = `pill status ${tone}`;
        statePill.textContent = text;
      }
    };

    // The devices of the instance, as Setup's discovery finds them.
    const devices = devicesSection({ block, plugin, accountRow, showAccount });
    const describe = form ? kit.describeSetup({ platform, pluginName: plugin ? plugin.name : platform, current: () => { try { return getValue(); } catch { return current.settings; } },
      use: (value) => { build({ ...value }); formBox.dispatchEvent(new Event("input", { bubbles: true })); } }) : null;

    const [state, kind] = kit.blockState(block, plugin, instance);
    const statePill = el("span", { class: `pill status ${kind}`, text: state });
    showAccount(instance?.accountState ?? null, Boolean(instance?.needsAuthorization));
    kit.setLeaveGuard(Object.assign(async () => !dirty() || await HomeswiftCommon.confirmDialog(t("Leave without saving your changes?")), { quiet: () => !dirty() }));
    app().show(main,
      app().breadcrumb([t("Plugins"), "/plugins"], ...(hasPage ? [[kit.blockTitle(block), `/plugins/${block.slug}`]] : []), [hasPage ? t("Settings") : kit.blockTitle(block)]),
      el("div", { class: "page-head settings-head" },
        tile(block.icon ?? plugin?.icon ?? "plugin", "orange"),
        el("div", { class: "who" },
          el("h1", { text: kit.blockTitle(block) }),
          el("p", { class: "muted", text: [...new Set([plugin ? plugin.name : platform, platform])].filter((part) => part !== block.name).concat(
            instance ? [tn("{n} accessory on {bridge}", "{n} accessories on {bridge}", instance.accessories, { bridge: instance.bridge })] : []).join(" · ") })),
        el("div", { class: "tools" },
          statePill,
          hasPage ? el("a", { class: "button", href: `/plugins/${block.slug}`, actionIcon: "open", text: t("Open its page") }) : null)),
      el("div", { class: "card plugin-settings" },
        accountSection,
        el("section", { class: "settings-section" },
          el("div", { class: "settings-section-head" }, el("h3", { text: t("Settings") }), el("p", { class: "help", text: t("For {name} as a whole. A save reloads it once, its accessories kept.", { name: block.name }) })),
          // Describe your setup, a line of the section rather than a card of its own.
          describe,
          formBox,
          form ? el("div", { class: "settings-bar" }, message, revert, save) : null),
        devices.node,
        blockJSON({ block, kit })),
      el("div", { class: "danger-zone" },
        el("div", {}, el("strong", { text: t("Remove this plugin") }),
          el("p", { class: "muted", text: t("Takes the block out of config.json. Its accessories leave the Home app, with their rooms, scenes and automations.") })),
        el("button", { actionIcon: "trash", class: "danger", text: t("Remove"), onclick: () => kit.removeBlock(block, () => app().navigate("/plugins")) })));
    update();
    const found = devices.load();
    // `?accessory=<Accessory Id>`, a plugin page's link to one of its devices: that accessory's Settings, over the page,
    // with its name and parts as the discovery has them.
    const linked = new URLSearchParams(location.search).get("accessory");
    if (linked) {
      const device = (await found)?.devices.find((one) => (one.accessoryID || `${platform}:${one.deviceID}`) === linked) ?? null;
      openAccessory({ accessoryID: linked, instance: block.name, device, name: device?.name ?? null,
        glyph: device ? HomeswiftWidgets.deviceIcon(device) ?? "accessory" : "accessory",
        after: (changed) => {
          history.replaceState(history.state, "", location.pathname);
          if (changed) devices.load();
        } });
    }
  }

  /// The settings' foot: what the form does not show is in config.json, and "Edit config.json" opens this block of it
  /// (and only this block) as JSON under the form. Its Save writes the block as the Config tab does
  /// (PUT /api/config/platforms/<index>, secrets sealed, the plugin reloaded) and draws the page again.
  function blockJSON({ block, kit }) {
    const textarea = el("textarea", { class: "short", spellcheck: false, "aria-label": t("The block as JSON") });
    const editor = HomeswiftCommon.jsonEditor(textarea, { secretKey: kit.isSecretKey });
    const message = el("span", { class: "muted" });
    const save = el("button", { class: "primary settings-action" }, HomeswiftCommon.icon("check"), el("span", { text: t("Save") }));
    const cancel = el("button", { class: "settings-action" }, HomeswiftCommon.icon("close"), el("span", { text: t("Cancel") }));
    const format = el("button", { type: "button", class: "settings-action" }, HomeswiftCommon.icon("code"), el("span", { text: t("Format") }));
    const panel = el("div", { class: "block-json" }, editor, el("div", { class: "settings-bar" }, message, format, cancel, save));
    panel.hidden = true;
    const toggle = el("button", { type: "button", class: "link", actionIcon: "code", "aria-expanded": "false", text: t("Edit config.json") });
    let index = block.index, original = "";
    const update = () => {
      const result = editor.check();
      format.disabled = !("value" in result);
      if (!("value" in result)) {
        message.className = "error";
        message.replaceChildren(...(result.line ? [el("button", { type: "button", class: "line-link", text: t("Line {line}", { line: result.line }), onclick: () => editor.reveal(result.offset) })] : []), result.message);
        save.disabled = true;
        return;
      }
      const changed = textarea.value !== original;
      save.disabled = !changed;
      if (!message.classList.contains("error") && !message.classList.contains("ok")) {
        message.className = changed ? "dirty" : "muted";
        message.textContent = changed ? t("Unsaved changes · a save reloads {name} once", { name: block.name }) : t("Saved");
      }
    };
    const close = () => {
      panel.hidden = true;
      toggle.setAttribute("aria-expanded", "false");
      toggle.textContent = t("Edit config.json");
    };
    const open = async () => {
      // The block as config.json has it now (its secrets as the placeholder), found by its platform and name.
      const config = await api("/api/config", { raw: true }).then(JSON.parse);
      const platforms = config.platforms || [];
      const at = platforms.findIndex((one) => one.platform === block.platform && one.name === block.name);
      index = at >= 0 ? at : block.index;
      original = JSON.stringify(platforms[index] ?? { platform: block.platform, name: block.name }, null, 2);
      textarea.value = original;
      message.className = "muted";
      panel.hidden = false;
      editor.repaint();
      toggle.setAttribute("aria-expanded", "true");
      toggle.textContent = t("Hide config.json");
      update();
      textarea.focus();
    };
    toggle.addEventListener("click", () => HomeswiftCommon.busyButton(toggle, () => panel.hidden ? open() : close(), { report: (e) => HomeswiftCommon.showAlert(e.message) }));
    panel.addEventListener("input", () => { message.className = ""; update(); });
    format.addEventListener("click", () => { textarea.value = JSON.stringify(JSON.parse(textarea.value), null, 2); editor.repaint(); message.className = ""; update(); });
    cancel.addEventListener("click", () => { textarea.value = original; editor.repaint(); message.className = ""; close(); });
    save.addEventListener("click", () => HomeswiftCommon.busyButton(save, async () => {
      const value = JSON.parse(textarea.value);
      value.platform = block.platform;
      message.className = "muted";
      message.textContent = t("Saving…");
      try {
        const result = await api(`/api/config/platforms/${index}`, { method: "PUT", body: value });
        message.className = "ok";
        message.textContent = kit.savedText(result);
        original = textarea.value;
        // The form above shows the block as saved: the page is drawn again, at the block's new address if it was renamed.
        kit.setLeaveGuard(null);
        if (value.name && value.name !== block.name) app().navigate(`/plugins/${HomeswiftCommon.slug(value.name)}/settings`, { replace: true });
        else app().route();
      } catch (e) {
        message.className = "error";
        if (!e.problems) { message.textContent = e.message; return; }
        message.replaceChildren(el("span", { text: t("The plugin's schema refuses this:") }),
          kit.problemList(e.problems.map((problem) => ({ ...problem, text: HomeswiftI18n.message(problem.text) })), editor));
      }
    }, { report: (e) => { message.className = "error"; message.textContent = e.message; } }));
    return el("section", { class: "settings-section settings-foot" },
      el("p", { class: "help" }, t("Something this form does not show is in config.json, the one place to write it as it is."), " ", toggle),
      panel);
  }

  /// A plugin instance's Discovered Devices: each with where it stands and what can be done with it: a set-up one opens
  /// its settings, an Excluded one is included, one that Needs Authorization is set up again. `accountRow`'s state line
  /// says where the account stands once the plugin has answered.
  function devicesSection({ block, plugin, accountRow, showAccount }) {
    const list = el("div", { class: "settings-devices", "aria-live": "polite" });
    const count = el("span", { class: "muted" });
    const again = el("button", { type: "button", class: "link", actionIcon: "search", text: t("Find again"), onclick: () => load() });
    const node = el("section", { class: "settings-section" },
      el("div", { class: "settings-section-head with-tools" },
        el("div", {}, el("h3", {}, t("Devices"), " ", count), el("p", { class: "help", text: t("What {plugin} finds, set up or not.", { plugin: block.name }) })), again),
      list,
      // A device the plugin does not find, added by its address: the Add accessories page's sheet.
      plugin?.addByAddress ? el("div", { class: "setup-add-address" },
        el("button", { type: "button", actionIcon: "plus", text: HomeswiftSetup.addLabel(plugin), onclick: (event) => HomeswiftSetup.setUp({ block, plugin, adding: true, trigger: event.currentTarget, after: () => load() }) })) : null);
    let loading = 0;
    async function load() {
      const run = ++loading;
      list.setAttribute("aria-busy", "true");
      again.disabled = true;
      if (!list.children.length) list.replaceChildren(el("p", { class: "setup-loading muted" }, el("span", { class: "spinner", "aria-hidden": "true" }), el("span", { text: t("Looking for devices…") })));
      try {
        const found = await api("/api/setup/discover", { method: "POST", body: { platform: block.platform, name: block.name } });
        if (run !== loading) return;
        showAccount(found.accountState, found.needsAuthorization);
        count.textContent = found.devices.length ? String(found.devices.length) : "";
        list.replaceChildren(...(found.devices.length ? found.devices.map((device) => deviceRow(block, plugin, device, load))
          : [el("p", { class: "muted", text: accountRow && found.needsAuthorization ? t("Its devices show here once it is set up.")
            : plugin?.addByAddress ? HomeswiftSetup.noneAdded(plugin) : t("No devices found") })]));
        return found;
      } catch (e) {
        if (run === loading) list.replaceChildren(el("p", { class: "error", role: "alert", text: e.message }));
      } finally {
        if (run === loading) { list.removeAttribute("aria-busy"); again.disabled = false; }
      }
    }
    return { node, load };
  }

  function deviceRow(block, plugin, device, reload) {
    const [state, tone] = statuses[device.status] ?? statuses.discovered;
    const accessoryID = device.accessoryID || `${block.platform}:${device.deviceID}`;
    const glyph = HomeswiftWidgets.deviceIcon(device) ?? "accessory";
    const opens = ["setUp", "notResponding", "discovered"].includes(device.status);
    const detail = device.excludedBySettings ? t("Left out by the settings above") : [device.model, device.address].filter(Boolean).join(" · ") || device.deviceID;
    let action = null;
    if (device.excludedBySettings) {
      // Left out by its plugin's own settings: nothing to do here.
    } else if (device.status === "excluded") {
      action = el("button", { type: "button", actionIcon: "plus", text: t("Include"), onclick: (event) => HomeswiftCommon.busyButton(event.currentTarget, async () => {
        await api(accessoryPath(accessoryID, block.name), { method: "PATCH", body: { excluded: null } });
        await reload();
      }) });
    } else if (device.status === "needsAuthorization") {
      action = el("button", { type: "button", class: "primary", actionIcon: "pair", text: t("Set up"), onclick: (event) => HomeswiftSetup.setUp({ block, plugin, device, trigger: event.currentTarget, after: reload }) });
    } else if (opens) {
      // An icon and a label; at phone width the gear alone, round, so the name keeps the row.
      action = el("button", { type: "button", class: "settings-open", "aria-label": t("Settings of {name}", { name: device.name }), title: t("Settings of {name}", { name: device.name }),
        onclick: (event) => openAccessory({ accessoryID, instance: block.name, device, name: device.name, glyph, trigger: event.currentTarget, after: (changed) => { if (changed) reload(); } }) },
        HomeswiftCommon.icon("gear"), el("span", { text: t("Settings") }));
    }
    return el("div", { class: `settings-device${device.status === "excluded" ? " is-excluded" : ""}` },
      tile(glyph, device.status === "excluded" ? "grey" : device.status === "needsAuthorization" ? "orange" : "blue"),
      el("div", { class: "who" }, el("strong", { text: device.name }),
        el("span", { class: "help", text: detail, title: detail })),
      tone === "on" ? el("span", { class: "status-dot", role: "img", "aria-label": state(), title: state() }) : el("span", { class: `pill status ${tone}`, text: state() }),
      action ?? el("span", { class: "setup-spacer" }));
  }

  window.HomeswiftSettings = { accessoryEditor, openAccessory, pluginPage, roomMenu };
})();
