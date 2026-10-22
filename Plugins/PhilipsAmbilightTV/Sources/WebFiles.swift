// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension PhilipsAmbilightTVPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Ambilight TV page: the TVs the plugin instance knows, refreshed every two seconds while the
// page is visible, with a remote; and the Homebridge plugin's pairing wizard (find the TV, type the PIN it
// shows, confirm its details), which writes the TV's entry into this instance's block.
(() => {
  "use strict";
  const { $, el, request, name, platform, explain, breadcrumb } = homeswift;

  const ambilightModes = [
    ["FOLLOW_VIDEO/STANDARD", "Follow video: Standard"], ["FOLLOW_VIDEO/NATURAL", "Follow video: Natural"],
    ["FOLLOW_VIDEO/VIVID", "Follow video: Vivid"], ["FOLLOW_VIDEO/GAME", "Follow video: Game"],
    ["FOLLOW_VIDEO/COMFORT", "Follow video: Comfort"], ["FOLLOW_VIDEO/RELAX", "Follow video: Relax"],
    ["FOLLOW_VIDEO/FOOTBALL", "Follow video: Football"], ["FOLLOW_AUDIO/ENERGY_ADAPTIVE_BRIGHTNESS", "Follow audio: Energy brightness"],
    ["FOLLOW_AUDIO/ENERGY_ADAPTIVE_COLORS", "Follow audio: Energy colours"], ["FOLLOW_AUDIO/VU_METER", "Follow audio: VU meter"],
    ["FOLLOW_AUDIO/SPECTRUM_ANALYZER", "Follow audio: Spectrum"], ["FOLLOW_AUDIO/PARTY", "Follow audio: Party"], ["Lounge light", "Lounge light"],
  ];
  const defaultMode = "FOLLOW_VIDEO/NATURAL";

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it.
  async function act(button, work, report = alert) {
    button.disabled = true;
    const spin = setTimeout(() => button.classList.add("busy"), 150);
    try { await work(); } catch (e) { report(e.message); }
    clearTimeout(spin);
    button.classList.remove("busy");
    button.disabled = false;
  }

  // MARK: Your TVs

  const list = $("#tvs");
  let tvs = [];
  let shown = null;

  const sendKey = (tv, key) => (event) => act(event.currentTarget, () => request("key", { method: "POST", body: { mac: tv.mac, key } }));
  const keyButton = (tv, key, label, attrs = {}) => el("button", { text: label, disabled: !tv.reachable, onclick: sendKey(tv, key), ...attrs });
  // The mini remote's actions as the TV's own keys.
  const tvKeys = {
    up: "CursorUp", down: "CursorDown", left: "CursorLeft", right: "CursorRight", select: "Confirm", back: "Back", home: "Home",
    info: "Info", playPause: "PlayPause", mute: "Mute", volumeUp: "VolumeUp", volumeDown: "VolumeDown",
  };

  function tvCard(tv) {
    const state = tv.on ? ["On", "on"] : tv.reachable ? ["Standby", "standby"] : ["Not responding", "away"];
    const updates = tv.longPoll === "confirmed" ? "Updates pushed by the TV" : tv.longPoll === "waiting" ? "Waiting for the TV's push" : "Polling for changes";
    const body = tv.on
      ? el("div", { class: "facts" },
        el("div", { class: "fact" }, el("span", { text: "Input" }), el("b", { text: tv.currentInput ?? tv.currentApp ?? "—", title: tv.currentApp ?? "" })),
        el("div", { class: "fact" }, el("span", { text: "Ambilight" }), el("b", { text: tv.ambilight ? styleName(tv.ambilightStyle) : "Off" })),
        el("div", { class: "fact" }, el("span", { text: "Sound" }), el("b", { text: tv.muted ? "Muted" : "On" })))
      : el("div", { class: "off-note" },
        el("p", { text: tv.reachable ? "In standby. Its input and Ambilight show once it is on." : "Off, or not on the network. Wake sends a Wake-on-LAN packet." }),
        tv.reachable ? null : explain({
          error: `The TV ${tv.name} does not answer at ${tv.ip}.`,
          context: "The Homeswift plugin polls the Philips TV's JointSpace API over HTTPS on port 1926; after two polls without an answer the TV is shown as not responding.",
          device: { model: "Philips Android TV with Ambilight", certificatePinned: tv.pinned, updates: tv.longPoll },
        }));
    return el("div", { class: "card tv", "data-mac": tv.mac },
      el("div", { class: "tv-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, tileIcon()),
        el("div", { class: "who" }, el("strong", { text: tv.name }), el("div", { class: "muted", text: `${tv.ip} · ${tv.mac}` })),
        el("span", { class: `pill status ${state[1]}`, text: state[0] })),
      body,
      HomeswiftRemote.build({
        actions: Object.keys(tvKeys), label: `Remote for ${tv.name}`, disabled: !tv.reachable,
        send: (action) => request("key", { method: "POST", body: { mac: tv.mac, key: tvKeys[action] } }),
        extra: [
          tv.on
            ? keyButton(tv, "Standby", "Turn off")
            : el("button", { class: "primary", text: "Wake", onclick: (event) => act(event.currentTarget, () => request(`wake?mac=${encodeURIComponent(tv.mac)}`, { method: "POST" })) }),
          keyButton(tv, "AmbilightOnOff", "Ambilight"),
        ],
      }),
      el("div", { class: "tv-foot muted" },
        el("span", { text: `${tv.inputs} inputs · ${updates} · Certificate ${tv.pinned ? "pinned" : "not pinned, pair again to pin it"}` }),
        el("span", { class: "foot-actions" },
          el("button", { class: "link", text: "Inputs", onclick: () => openSources(tv) }),
          el("button", { class: "link", text: "Edit", onclick: () => openEditor(tv) }),
          el("button", { class: "link danger", text: "Remove", onclick: (event) => act(event.currentTarget, () => removeTV(tv)) }))));
  }

  /// `FOLLOW_VIDEO` as "Follow video"; nil as "On".
  const styleName = (style) => style ? style.replaceAll("_", " ").toLowerCase().replace(/^./, (c) => c.toUpperCase()) : "On";

  function tileIcon() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.innerHTML = '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/>';
    return svg;
  }

  async function refresh() {
    try {
      ({ tvs } = await request("tvs"));
      const answer = JSON.stringify(tvs);
      if (answer === shown) return;
      shown = answer;
      if (tvs.length === 0) {
        list.replaceChildren(el("div", { class: "card empty" },
          el("p", { class: "muted", text: "No TV yet. Switch your TV on, then add it below." })));
        return;
      }
      // A card is redrawn when its TV changes: keep the keyboard on the remote it was on.
      const focused = document.activeElement?.closest?.(".tv")?.dataset.mac;
      list.replaceChildren(...tvs.map(tvCard));
      if (focused) list.querySelector(`.tv[data-mac="${CSS.escape(focused)}"] .pad`)?.focus();
    } catch (e) {
      shown = null;
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: Inputs: the Homebridge plugin's sources editor. Shown inputs in the wheel's order, dragged to
  // reorder (the row follows the pointer, the others make room) or moved with Alt+↑/↓; hidden inputs in a
  // pool; names edited in place. Nothing is written until Save, since a save reloads the plugin.

  const sourcesCard = $("#sources");
  const kindLabels = { tv: "TV", home: "Home", hdmi: "HDMI", channel: "Channel", app: "App", custom: "Custom" };
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  let editing = null;   // { tv, sources: [{ id, name, kind, customName, visible }], saved: JSON }

  async function openSources(tv) {
    if (!closeEditor()) return;
    editing = { tv, sources: [], saved: "" };
    breadcrumb(`Inputs of ${tv.name}`, closeSources);
    sourcesCard.classList.remove("hidden");
    sourcesCard.replaceChildren(el("p", { class: "muted", text: `Loading the inputs of ${tv.name}…` }));
    sourcesCard.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
    try {
      const { sources } = await request(`sources?mac=${encodeURIComponent(tv.mac)}`);
      const all = sources.map((source) => ({ ...source, customName: source.customName ?? "" }));
      editing.sources = [...all.filter((source) => source.visible), ...all.filter((source) => !source.visible)];
      editing.saved = JSON.stringify(editing.sources);
      renderSources();
    } catch (e) {
      sourcesCard.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  /// Closes the inputs editor; false when the person keeps unsaved changes.
  function closeSources() {
    if (editing && isDirty() && !confirm("Discard the changes to the inputs?")) return false;
    if (editing) breadcrumb(null);
    editing = null;
    sourcesCard.classList.add("hidden");
    sourcesCard.replaceChildren();
    return true;
  }

  const isDirty = () => editing && JSON.stringify(editing.sources) !== editing.saved;
  const shownSources = () => editing.sources.filter((source) => source.visible);
  const hiddenSources = () => editing.sources.filter((source) => !source.visible);

  function renderSources() {
    const shown = shownSources();
    const hidden = hiddenSources();
    const shownList = el("ol", { class: "sources", "aria-label": "Shown inputs, in order" }, shown.map((source) => sourceRow(source, true)));
    const hiddenList = el("ul", { class: "sources pool", "aria-label": "Hidden inputs" }, hidden.map((source) => sourceRow(source, false)));
    const dirty = isDirty();
    sourcesCard.replaceChildren(
      el("div", { class: "sources-head" },
        el("div", {}, el("h2", { text: `Inputs of ${editing.tv.name}` }),
          el("p", { class: "muted", text: "The order of the input wheel in the Home app. Drag a row by its handle, or press Alt and an arrow key. Click a name to rename it." })),
        el("button", { class: "link", text: "Close", onclick: closeSources })),
      el("div", { class: "sources-columns" },
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status on", text: `Shown · ${shown.length}` }), el("span", { class: "muted", text: "drag to reorder" })),
          shown.length ? shownList : el("p", { class: "muted empty-list", text: "No input is shown." })),
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status standby", text: `Hidden · ${hidden.length}` }), el("span", { class: "muted", text: "+ shows an input" })),
          hidden.length ? hiddenList : el("p", { class: "muted empty-list", text: "Every input is shown." }))),
      el("div", { class: `save-bar ${dirty ? "dirty" : ""}` },
        el("span", { class: "muted", text: dirty ? "Unsaved changes" : "Saved. The Home app shows this order." }),
        el("button", { class: "link", text: "Reset to the TV's order", onclick: (event) => act(event.currentTarget, resetSources) }),
        el("button", { text: "Discard", disabled: !dirty, onclick: () => { editing.sources = JSON.parse(editing.saved); renderSources(); } }),
        el("button", { class: "primary", text: "Save", disabled: !dirty, onclick: (event) => act(event.currentTarget, saveSources) })));
    if (shown.length) enableSorting(shownList);
  }

  function sourceRow(source, shown) {
    const name = el("input", {
      class: "source-name", value: source.customName || source.name, placeholder: source.name, maxLength: 64,
      "aria-label": `Name of ${source.name}`, spellcheck: false,
    });
    name.addEventListener("change", () => {
      const typed = name.value.trim();
      source.customName = typed && typed !== source.name ? typed : "";
      name.value = source.customName || source.name;
      renderSources();
    });
    name.addEventListener("keydown", (event) => { if (event.key === "Enter") name.blur(); });
    const toggle = el("button", {
      class: "icon-button", text: shown ? "×" : "+", title: shown ? "Hide" : "Show",
      "aria-label": `${shown ? "Hide" : "Show"} ${source.customName || source.name}`,
      onclick: () => {
        source.visible = !shown;
        // A shown input joins the end of the wheel; a hidden one goes to the end of the pool.
        editing.sources = editing.sources.filter((s) => s !== source);
        editing.sources.push(source);
        editing.sources = [...shownSources(), ...hiddenSources()];
        renderSources();
      },
    });
    const row = el("li", { class: "source", "data-id": source.id, tabIndex: shown ? 0 : -1 },
      shown ? handle() : null,
      el("span", { class: `kind ${source.kind}`, text: kindLabels[source.kind] ?? source.kind }),
      name,
      source.customName ? el("span", { class: "original muted", text: source.name, title: "The name the TV gives it" }) : null,
      toggle);
    if (shown) {
      row.setAttribute("aria-label", `${source.customName || source.name}. Press Alt and an arrow key to move it.`);
      row.addEventListener("keydown", (event) => {
        if (!event.altKey || (event.key !== "ArrowUp" && event.key !== "ArrowDown") || event.target !== row) return;
        event.preventDefault();
        const list = shownSources();
        const from = list.indexOf(source);
        const to = from + (event.key === "ArrowUp" ? -1 : 1);
        if (to < 0 || to >= list.length) return;
        moveShown(from, to);
        renderSources();
        sourcesCard.querySelector(`.source[data-id="${CSS.escape(source.id)}"]`)?.focus();
      });
    }
    return row;
  }

  /// Six dots in two columns, the usual grip.
  function handle() {
    const grip = el("span", { class: "handle", "aria-hidden": "true", title: "Drag to reorder" });
    grip.innerHTML = '<svg viewBox="0 0 10 16"><circle cx="2.5" cy="3" r="1.4"/><circle cx="7.5" cy="3" r="1.4"/><circle cx="2.5" cy="8" r="1.4"/><circle cx="7.5" cy="8" r="1.4"/><circle cx="2.5" cy="13" r="1.4"/><circle cx="7.5" cy="13" r="1.4"/></svg>';
    return grip;
  }

  /// Moves a shown input from one place in the wheel to another; hidden inputs keep their places.
  function moveShown(from, to) {
    const shown = shownSources();
    const [moved] = shown.splice(from, 1);
    shown.splice(to, 0, moved);
    editing.sources = [...shown, ...hiddenSources()];
  }

  /// Drag by the handle with Pointer Events, so mouse, pen and touch behave the same: the row stays under
  /// the pointer where it was grabbed, the rows it passes slide out of its way, and on release it settles
  /// into its slot from where it was dropped (no jump).
  function enableSorting(list) {
    list.addEventListener("pointerdown", (event) => {
      const handle = event.target.closest(".handle");
      if (!handle || event.button !== 0) return;
      event.preventDefault();
      const row = handle.closest(".source");
      const rows = [...list.children];
      const from = rows.indexOf(row);
      const rects = rows.map((r) => r.getBoundingClientRect());
      const step = rows.length > 1 ? rects[1].top - rects[0].top : rects[0].height;
      const startY = event.clientY;
      let to = from;
      let offset = 0;
      row.setPointerCapture(event.pointerId);
      row.classList.add("dragging");
      list.classList.add("sorting");

      const move = (moveEvent) => {
        // Rubber-band past the ends instead of a hard stop.
        const min = rects[0].top - rects[from].top, max = rects[rects.length - 1].top - rects[from].top;
        const raw = moveEvent.clientY - startY;
        const over = raw < min ? raw - min : raw > max ? raw - max : 0;
        offset = raw - over + over * 0.3;
        row.style.transform = `translateY(${offset}px)`;
        const center = rects[from].top + rects[from].height / 2 + offset;
        to = rects.reduce((count, rect, i) => (i !== from && center > rect.top + rect.height / 2 ? count + 1 : count), 0);
        rows.forEach((other, i) => {
          if (other === row) return;
          const shift = from < to && i > from && i <= to ? -step : from > to && i >= to && i < from ? step : 0;
          other.style.transform = shift ? `translateY(${shift}px)` : "";
        });
      };
      const end = () => {
        row.removeEventListener("pointermove", move);
        row.removeEventListener("pointerup", end);
        row.removeEventListener("pointercancel", end);
        list.classList.remove("sorting");
        const dropped = rects[from].top + offset;
        if (to !== from) moveShown(from, to);
        renderSources();
        const placed = sourcesCard.querySelector(`.source[data-id="${CSS.escape(row.dataset.id)}"]`);
        if (!placed) return;
        placed.focus({ preventScroll: true });
        if (reducedMotion.matches) return;
        // FLIP: start the new row where the dragged one was let go, then let it settle.
        const delta = dropped - placed.getBoundingClientRect().top;
        if (Math.abs(delta) < 1) return;
        placed.classList.add("settling");
        placed.style.transform = `translateY(${delta}px)`;
        requestAnimationFrame(() => requestAnimationFrame(() => { placed.style.transform = ""; }));
        placed.addEventListener("transitionend", () => placed.classList.remove("settling"), { once: true });
      };
      row.addEventListener("pointermove", move);
      row.addEventListener("pointerup", end);
      row.addEventListener("pointercancel", end);
    });
  }

  /// The `sources` setting: every input with its place, shown ones first, and a name only where it differs.
  function sourcesSetting() {
    return [...shownSources(), ...hiddenSources()].map((source, order) => {
      const setting = { id: source.id, order, visible: source.visible };
      if (source.customName) setting.customName = source.customName;
      return setting;
    });
  }

  async function saveSources() {
    const tv = editing.tv;
    await updateDevice(tv.mac, (device) => { device.sources = sourcesSetting(); });
    editing.saved = JSON.stringify(editing.sources);
    renderSources();
  }

  async function resetSources() {
    if (!confirm(`Put the inputs of ${editing.tv.name} back in the TV's order, all shown, with their own names?`)) return;
    const tv = editing.tv;
    await updateDevice(tv.mac, (device) => { delete device.sources; });
    // The plugin reloads with the TV's order; read it back.
    await new Promise((resolve) => setTimeout(resolve, 800));
    await openSources(tv);
  }

  // MARK: Edit a TV: the Homebridge plugin's sections, General, Remote, Automations, Apps and Buttons, on a
  // draft of the TV's entry; Save writes it and the plugin reloads with it. The choices (remote keys, Ambilight
  // styles) come from the plugin's schema, so the page and the plugin never disagree.

  const editorCard = $("#tv-editor");
  let schemaPromise = null;
  const deviceSchema = () => (schemaPromise ??= fetch(`/api/plugins/${encodeURIComponent(platform)}/schema`, { credentials: "same-origin" })
    .then((response) => response.json()).then((schema) => schema.schema.properties.devices.items.properties));
  const choices = (property) => (property.oneOf ? property.oneOf.map((o) => [o.enum[0], o.title]) : (property.enum || []).map((v) => [v, v]));
  let editorState = null;   // { tv, draft, saved, section }

  const fieldRow = (label, control, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), control, help ? el("span", { class: "help", text: help }) : null);
  function toggleRow(label, checked, onChange, help) {
    const input = el("input", { type: "checkbox", checked });
    input.addEventListener("change", () => onChange(input.checked));
    return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
      el("span", {}, el("span", { class: "field-title", text: label }), help ? el("span", { class: "help", text: help }) : null));
  }
  /// Sets a key of a draft entry, or removes it when it holds the default, as Homebridge leaves it out.
  function setKey(draft, key, value, fallback) {
    if (value === undefined || value === "" || value === fallback) delete draft[key]; else draft[key] = value;
  }
  function selectFor(property, value, onChange) {
    const select = el("select", {}, choices(property).map(([v, title]) => el("option", { value: v, text: title, selected: v === (value ?? property.default) })));
    select.addEventListener("change", () => onChange(select.value));
    return select;
  }

  // The Remote and Automations sections, shared by the editor and the last step of pairing.
  function remoteFields(schema, draft, changed) {
    return ["infoButtonKey", "backButtonKey", "playPauseButtonKey"].map((key) =>
      fieldRow(schema[key].title.replace(" Key", ""), selectFor(schema[key], draft[key], (value) => { setKey(draft, key, value, schema[key].default); changed(); }), schema[key].description));
  }
  function automationFields(schema, draft, changed) {
    const sensors = new Set(draft.stateSensors || []);
    const sensorToggle = (sensor, label) => toggleRow(label, sensors.has(sensor), (on) => {
      if (on) sensors.add(sensor); else sensors.delete(sensor);
      setKey(draft, "stateSensors", sensors.size ? ["power", "ambilight", "mute"].filter((s) => sensors.has(s)) : undefined);
      changed();
    });
    return [
      toggleRow("Source switches", draft.sourceSwitches === true, (on) => { setKey(draft, "sourceSwitches", on, false); changed(); }, schema.sourceSwitches.description),
      toggleRow("Ambilight + Hue switch", draft.ambilightHueSwitch === true, (on) => { setKey(draft, "ambilightHueSwitch", on, false); changed(); }, schema.ambilightHueSwitch.description),
      el("p", { class: "help sensors-help", text: schema.stateSensors.description }),
      sensorToggle("power", "Power sensor: motion while the TV is on"),
      sensorToggle("ambilight", "Ambilight sensor: motion while Ambilight is on"),
      sensorToggle("mute", "Mute sensor: motion while the sound is muted"),
    ];
  }

  async function openEditor(tv) {
    if (!closeSources() || !closeEditor()) return;
    editorCard.classList.remove("hidden");
    breadcrumb(`Edit ${tv.name}`, closeEditor);
    editorCard.replaceChildren(el("p", { class: "muted", text: `Loading ${tv.name}…` }));
    editorCard.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
    try {
      const [schema, found] = await Promise.all([deviceSchema(), findDevice(tv.mac)]);
      editorState = { tv, schema, draft: structuredClone(found.device), saved: JSON.stringify(found.device), section: "general" };
      renderEditor();
    } catch (e) {
      editorCard.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  /// Closes the editor; false when the person keeps unsaved changes.
  function closeEditor() {
    if (editorState && JSON.stringify(editorState.draft) !== editorState.saved && !confirm("Discard the changes to this TV?")) return false;
    if (!editorCard.classList.contains("hidden")) breadcrumb(null);
    editorState = null;
    editorCard.classList.add("hidden");
    editorCard.replaceChildren();
    return true;
  }

  function renderEditor() {
    const { tv, schema, draft } = editorState;
    const message = el("span", { class: "muted" });
    const save = el("button", { class: "primary", text: "Save", onclick: (event) => act(event.currentTarget, saveEditor, (text) => { message.className = "error"; message.textContent = text; }) });
    const discard = el("button", { text: "Discard", onclick: () => { editorState.draft = JSON.parse(editorState.saved); renderEditor(); } });
    const changed = () => {
      const dirty = JSON.stringify(editorState.draft) !== editorState.saved;
      save.disabled = !dirty;
      discard.disabled = !dirty;
      message.className = dirty ? "dirty" : "muted";
      message.textContent = dirty ? "Unsaved changes" : "Saved";
    };
    const sections = [["general", "General"], ["remote", "Remote"], ["automations", "Automations"], ["apps", "Apps"], ["buttons", "Buttons"]];
    const tabs = el("div", { class: "group tabs", role: "tablist" }, sections.map(([key, label]) => el("button", {
      text: label, role: "tab", class: key === editorState.section ? "on" : "", "aria-selected": String(key === editorState.section),
      onclick: () => { editorState.section = key; renderEditor(); },
    })));
    const text = (key, attrs = {}) => {
      const input = el("input", { type: "text", value: draft[key] ?? "", autocomplete: "off", spellcheck: false, ...attrs });
      input.addEventListener("input", () => { setKey(draft, key, input.value.trim()); changed(); });
      return input;
    };
    let body;
    switch (editorState.section) {
    case "general": {
      const interval = el("input", { type: "number", min: 1000, max: 60000, step: 1000, value: draft.pollingInterval ?? "", placeholder: String(schema.pollingInterval.default) });
      interval.addEventListener("input", () => { setKey(draft, "pollingInterval", interval.value ? Number(interval.value) : undefined, schema.pollingInterval.default); changed(); });
      body = el("div", {},
        el("div", { class: "fields" },
          fieldRow("Name in the Home app", text("name", { maxLength: 64 })),
          fieldRow("Address", text("ip", { inputmode: "decimal" }), "The TV's IPv4 address. Give it a fixed address in your router."),
          fieldRow("MAC address", text("mac"), "For Wake-on-LAN, which switches the TV on from deep standby."),
          fieldRow("Ambilight style", selectFor(schema.ambilightMode, draft.ambilightMode, (value) => { setKey(draft, "ambilightMode", value, schema.ambilightMode.default); changed(); }), schema.ambilightMode.description),
          fieldRow("Polling interval (ms)", interval, schema.pollingInterval.description)),
        toggleRow("Switch Ambilight on whenever the TV comes on", draft.ambilightOnStart === true, (on) => { setKey(draft, "ambilightOnStart", on, false); changed(); }),
        toggleRow("Wake-on-LAN", draft.wakeOnLanEnabled !== false, (on) => { setKey(draft, "wakeOnLanEnabled", on, true); changed(); }, schema.wakeOnLanEnabled.description),
        el("div", { class: "repair" },
          el("div", {}, el("strong", { text: "Pairing" }),
            el("p", { class: "help", text: tv.pinned ? "Paired, with the TV's certificate pinned. Pair again after a reset of the TV, when it refuses Homeswift." : "Paired without a pinned certificate. Pair again to pin it." })),
          el("button", { text: "Pair again", onclick: () => { if (closeEditor()) repair(tv); } })));
      break;
    }
    case "remote":
      body = el("div", { class: "fields" }, remoteFields(schema, draft, changed));
      break;
    case "automations":
      body = el("div", {}, automationFields(schema, draft, changed));
      break;
    case "apps":
      body = appsSection(schema, draft, () => { changed(); renderEditor(); });
      break;
    case "buttons":
      body = buttonsSection(schema, draft, () => { changed(); renderEditor(); });
      break;
    }
    editorCard.replaceChildren(
      el("div", { class: "sources-head" },
        el("div", {}, el("h2", { text: `Edit ${tv.name}` }), el("p", { class: "muted", text: "Saving applies at once: the TV keeps its place in the Home app." })),
        el("button", { class: "link", text: "Close", onclick: closeEditor })),
      tabs, el("div", { class: "editor-body" }, body),
      el("div", { class: "save-bar" }, message, discard, save));
    changed();
  }

  /// Apps the TV does not list: added by hand, or from what is in the TV's foreground ("Detect from TV").
  function appsSection(schema, draft, changed) {
    const apps = draft.customApps || [];
    const appName = el("input", { type: "text", placeholder: "EON", maxLength: 64 });
    const packageName = el("input", { type: "text", placeholder: "com.ug.eon.android.tv", spellcheck: false });
    const className = el("input", { type: "text", placeholder: "Found by the plugin when left empty", spellcheck: false });
    const status = el("p", { class: "status-line muted" });
    const detect = el("button", { text: "Detect from TV", onclick: (event) => act(event.currentTarget, async () => {
      status.className = "status-line muted";
      status.textContent = "Asking the TV which app is open…";
      const { app } = await request(`current-app?mac=${encodeURIComponent(editorState.tv.mac)}`);
      packageName.value = app.packageName;
      className.value = app.className ?? "";
      if (!appName.value) appName.value = app.name ?? "";
      status.className = "status-line ok";
      status.textContent = `Found ${app.packageName}.`;
    }, (text) => { status.className = "status-line error"; status.replaceChildren(text); }) });
    const add = el("button", { class: "primary", text: "Add app", onclick: () => {
      if (!appName.value.trim() || !packageName.value.trim()) { status.className = "status-line error"; status.textContent = "An app needs a name and a package name."; return; }
      const app = { name: appName.value.trim(), packageName: packageName.value.trim() };
      if (className.value.trim()) app.className = className.value.trim();
      draft.customApps = [...apps.filter((a) => a.packageName !== app.packageName), app];
      changed();
    } });
    return el("div", {},
      el("p", { class: "help", text: schema.customApps.description }),
      apps.length ? el("ul", { class: "entries" }, apps.map((app) => el("li", {},
        el("div", {}, el("strong", { text: app.name }), el("div", { class: "muted mono", text: [app.packageName, app.className].filter(Boolean).join(" / ") })),
        el("button", { class: "link danger", text: "Remove", onclick: () => { setKey(draft, "customApps", apps.filter((a) => a !== app).length ? apps.filter((a) => a !== app) : undefined); changed(); } }))))
        : el("p", { class: "muted empty-list", text: "No custom app." }),
      el("div", { class: "add-box" },
        el("strong", { text: "Add an app" }),
        el("div", { class: "fields" }, fieldRow("Name", appName), fieldRow("Package name", packageName), fieldRow("Launch activity (optional)", className)),
        el("div", { class: "actions" }, detect, add), status));
  }

  /// Momentary switches that send one remote key each.
  function buttonsSection(schema, draft, changed) {
    const buttons = draft.customButtons || [];
    const keys = schema.customButtons.items.properties.key.enum;
    const used = new Set(buttons.map((b) => b.key));
    const buttonName = el("input", { type: "text", placeholder: "Power menu", maxLength: 64 });
    const key = el("select", {}, keys.filter((k) => !used.has(k)).map((k) => el("option", { value: k, text: k.replace(/([a-z])([A-Z0-9])/g, "$1 $2") })));
    const status = el("p", { class: "status-line muted" });
    const add = el("button", { class: "primary", text: "Add button", disabled: key.options.length === 0, onclick: () => {
      if (!buttonName.value.trim()) { status.className = "status-line error"; status.textContent = "A button needs a name."; return; }
      draft.customButtons = [...buttons, { name: buttonName.value.trim(), key: key.value }];
      changed();
    } });
    return el("div", {},
      el("p", { class: "help", text: schema.customButtons.description }),
      buttons.length ? el("ul", { class: "entries" }, buttons.map((button) => el("li", {},
        el("div", {}, el("strong", { text: button.name }), el("div", { class: "muted", text: `Sends ${button.key}` })),
        el("button", { class: "link danger", text: "Remove", onclick: () => { setKey(draft, "customButtons", buttons.filter((b) => b !== button).length ? buttons.filter((b) => b !== button) : undefined); changed(); } }))))
        : el("p", { class: "muted empty-list", text: "No custom button." }),
      el("div", { class: "add-box" },
        el("strong", { text: "Add a button" }),
        el("div", { class: "fields" }, fieldRow("Name", buttonName), fieldRow("Remote key", key, "Each key can be used by one button only.")),
        el("div", { class: "actions" }, add), status));
  }

  async function saveEditor() {
    const { tv, draft } = editorState;
    if (!draft.name) throw new Error("The TV needs a name.");
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(draft.ip ?? "")) throw new Error("The address must be an IPv4 address, like 192.168.1.20.");
    if (!macPattern.test(draft.mac ?? "")) throw new Error("The MAC address must look like AA:BB:CC:DD:EE:FF.");
    await updateDevice(tv.mac, () => draft);
    editorState.saved = JSON.stringify(draft);
    editorState.tv = { ...tv, name: draft.name, mac: draft.mac.toUpperCase().replaceAll("-", ":") };
    renderEditor();
    shown = null;
    setTimeout(refresh, 600);
  }

  async function removeTV(tv) {
    if (!confirm(`Remove ${tv.name}? It leaves the Home app, with its scenes and automations.`)) return;
    if (editingTV(tv) && (!closeSources() || !closeEditor())) return;
    await updateDevices((devices) => {
      const index = devices.findIndex((d) => sameMAC(d.mac, tv.mac));
      if (index >= 0) devices.splice(index, 1);
    });
    shown = null;
    await refresh();
  }
  const editingTV = (tv) => (editing && sameMAC(editing.tv.mac, tv.mac)) || (editorState && sameMAC(editorState.tv.mac, tv.mac));

  // MARK: Add a TV: find → PIN → confirm, one step at a time

  const pairing = $("#pairing");
  const stepNames = ["Find", "PIN", "Confirm"];
  const steps = el("ol", { class: "steps" }, stepNames.map((label, i) => el("li", { "data-n": String(i + 1), text: label })));
  const status = el("p", { class: "status-line muted", role: "status" });
  const say = (message, kind = "muted") => { status.textContent = message; status.className = `status-line ${kind}`; };
  let target = null;   // { ip, name } of the TV being paired
  let device = null;   // what the TV handed out: ip, username, password, certFingerprint, mac
  let attempt = null;  // the TV last asked for a PIN, for the failure's Wake and Explain
  let repairing = null;   // the MAC of a configured TV paired again: its entry gets the new keys
  /// An error, with Explain when there is an Assistant, and Wake when the TV is one the plugin knows (a TV in
  /// deep standby answers nothing until a Wake-on-LAN packet reaches it).
  function fail(message) {
    say(message, "error");
    const known = attempt && tvs.find((tv) => tv.ip === attempt.ip);
    status.append(
      known ? el("button", { class: "link", text: `Wake ${known.name}`, onclick: (event) => act(event.currentTarget, async () => {
        await request(`wake?mac=${encodeURIComponent(known.mac)}`, { method: "POST" });
        say(`Sent. Give ${known.name} a few seconds to start, then pair again.`, "ok");
      }, fail) }) : null,
      explain({ error: message, context: "Pairing a Philips Android TV from the Homeswift plugin page: POST pair/request on port 1926, the TV shows a PIN, then pair/grant with an HMAC of the PIN.", device: { model: "Philips Android TV with Ambilight" } }));
  }

  // Step 1: find the TV, or type its address.
  const found = el("div", { class: "found" });
  const address = el("input", { type: "text", placeholder: "192.168.1.20", inputmode: "decimal", autocomplete: "off", spellcheck: false, "aria-label": "TV address" });
  const findButton = el("button", { text: "Find TVs", onclick: (event) => act(event.currentTarget, discover, fail) });
  const find = el("div", { class: "step" },
    el("p", { class: "muted", text: "Switch the TV on: it has to be on and on this network. Homeswift looks for it for five seconds." }),
    findButton, found,
    el("div", { class: "or", text: "or enter its address" }),
    el("form", { class: "manual", onsubmit: (event) => { event.preventDefault(); act(event.submitter ?? manualPair, () => pair({ ip: address.value.trim() }), fail); } },
      address, el("button", { type: "submit", text: "Pair" })));
  const manualPair = find.querySelector(".manual button");

  // Step 2: the PIN the TV shows, a box per digit.
  const digits = [0, 1, 2, 3].map((i) => el("input", { type: "text", inputmode: "numeric", maxlength: 1, autocomplete: i === 0 ? "one-time-code" : "off", "aria-label": `PIN digit ${i + 1}` }));
  const pinPrompt = el("p", {});
  const confirmPin = el("button", { class: "primary", text: "Confirm PIN", onclick: (event) => act(event.currentTarget, grant, fail) });
  const pinStep = el("div", { class: "step" },
    pinPrompt, el("div", { class: "pin" }, digits),
    el("div", { class: "actions" }, confirmPin, el("button", { class: "link", text: "Cancel", onclick: reset })));

  // Step 3: the details of the TV's entry.
  const tvName = el("input", { type: "text", maxlength: 64, autocomplete: "off", placeholder: "Living Room TV" });
  const ipField = el("input", { type: "text", readOnly: true, tabIndex: -1 });
  const mac = el("input", { type: "text", placeholder: "AA:BB:CC:DD:EE:FF", autocomplete: "off", spellcheck: false });
  const macHelp = el("p", { class: "help", text: "For Wake-on-LAN, which switches the TV on from deep standby." });
  const mode = el("select", {}, ambilightModes.map(([value, label]) => el("option", { value, text: label, selected: value === defaultMode })));
  const onStart = el("input", { type: "checkbox", id: "ambilight-on-start" });
  const entryText = el("pre", {});
  let extras = {};   // the Remote and Automations choices of the TV being added
  const moreOptions = el("details", { class: "group-box" }, el("summary", { text: "Remote and automations" }));
  async function renderMoreOptions() {
    extras = {};
    const schema = await deviceSchema();
    moreOptions.replaceChildren(moreOptions.firstChild,
      el("div", { class: "fields" }, remoteFields(schema, extras, showEntry)),
      automationFields(schema, extras, showEntry));
  }
  const confirm = el("div", { class: "step" },
    el("div", { class: "form" },
      el("div", { class: "wide" }, el("label", { text: "Name in the Home app" }), tvName),
      el("div", {}, el("label", { text: "Address" }), ipField),
      el("div", {}, el("label", { text: "MAC address" }), mac, macHelp),
      el("div", { class: "wide" }, el("label", { text: "Ambilight style when switched on from HomeKit" }), mode)),
    el("div", { class: "check" }, el("label", { class: "switch" }, onStart, el("span", {})), el("label", { htmlFor: "ambilight-on-start", text: "Switch Ambilight on whenever the TV comes on" })),
    moreOptions,
    el("div", { class: "actions" },
      el("button", { class: "primary", text: "Add TV", onclick: (event) => act(event.currentTarget, addToConfiguration, fail) }),
      el("button", { class: "link", text: "Cancel", onclick: reset })),
    el("details", {}, el("summary", { text: "The entry for config.json" }), entryText,
      el("button", { class: "link", text: "Copy", onclick: (event) => act(event.currentTarget, async () => { await navigator.clipboard.writeText(entryText.textContent); say("Copied.", "ok"); }, fail) })));

  // After saving: the plugin reloads with the TV at once. A restart is offered only when the bridge says
  // some change still needs one.
  const doneText = el("p", {});
  const restartButton = el("button", { class: "primary", text: "Restart Homeswift", onclick: (event) => act(event.currentTarget, restart, fail) });
  const done = el("div", { class: "step" },
    doneText,
    el("div", { class: "actions" }, restartButton, el("button", { text: "Add another TV", onclick: reset })));

  const bodies = [find, pinStep, confirm, done];
  pairing.replaceChildren(steps, ...bodies, status);

  function show(step) {
    bodies.forEach((body, i) => body.classList.toggle("hidden", i !== step));
    [...steps.children].forEach((item, i) => {
      item.classList.toggle("current", i === Math.min(step, 2) && step < 3);
      item.classList.toggle("done", i < step);
    });
  }

  function reset() {
    target = null;
    device = null;
    attempt = null;
    repairing = null;
    stepNames.forEach((label, i) => { steps.children[i].textContent = label; });
    digits.forEach((digit) => { digit.value = ""; });
    say("");
    show(0);
  }

  async function discover() {
    found.replaceChildren();
    say("Looking for TVs…");
    const answer = await request("discover");
    const known = new Set(tvs.map((tv) => tv.ip));
    const fresh = answer.tvs.filter((tv) => !known.has(tv.host));
    say(fresh.length ? "" : answer.tvs.length ? "Every TV that answered is already added." : "No TV announced itself. Check it is on, or enter its address.");
    found.replaceChildren(...fresh.map((tv) => el("div", { class: "item" },
      el("div", {}, el("strong", { text: tv.name }), el("div", { class: "muted", text: tv.host })),
      el("button", { class: "primary", text: "Pair", onclick: (event) => act(event.currentTarget, () => pair({ ip: tv.host, name: tv.name }), fail) }))));
  }

  /// Pairs a configured TV again (after a reset of the TV, or to pin its certificate): its entry keeps its
  /// settings and gets the new keys.
  async function repair(tv) {
    reset();
    repairing = tv.mac;
    steps.children[2].textContent = "Done";
    $("#add-title").scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth" });
    await act(manualPair, () => pair({ ip: tv.ip, name: tv.name }), fail);
  }

  async function pair(tv) {
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(tv.ip)) throw new Error("Enter the TV's IPv4 address, like 192.168.1.20.");
    attempt = tv;
    say("Asking the TV for a PIN…");
    const answer = await request("pair", { method: "POST", body: { ip: tv.ip, name: "Homeswift" } });
    target = tv;
    pinPrompt.replaceChildren("Type the PIN ", el("strong", { text: tv.name ?? tv.ip }), " shows on screen.");
    say(answer.certificateSeen ? "" : "The TV answered over plain HTTP, so its certificate cannot be pinned.");
    digits.forEach((digit) => { digit.value = ""; });
    show(1);
    digits[0].focus();
  }

  // The digit boxes: one digit each, typing moves on, Backspace moves back, a pasted PIN fills them all,
  // and the fourth digit confirms.
  digits.forEach((digit, i) => {
    digit.addEventListener("input", () => {
      const typed = digit.value.replace(/\D/g, "");
      if (typed.length > 1) return fill(typed);
      digit.value = typed;
      if (typed && i < 3) digits[i + 1].focus();
      if (pin().length === 4) confirmPin.click();
    });
    digit.addEventListener("keydown", (event) => {
      if (event.key === "Backspace" && !digit.value && i > 0) { digits[i - 1].focus(); digits[i - 1].value = ""; event.preventDefault(); }
      if (event.key === "Enter" && pin().length === 4) confirmPin.click();
    });
    digit.addEventListener("paste", (event) => { event.preventDefault(); fill((event.clipboardData?.getData("text") ?? "").replace(/\D/g, "")); });
    digit.addEventListener("focus", () => digit.select());
  });
  const pin = () => digits.map((digit) => digit.value).join("");
  function fill(text) {
    digits.forEach((digit, i) => { digit.value = text[i] ?? ""; });
    digits[Math.min(text.length, 3)].focus();
    if (pin().length === 4) confirmPin.click();
  }

  async function grant() {
    if (pin().length !== 4) throw new Error("The PIN has four digits.");
    try {
      const answer = await request("pair/grant", { method: "POST", body: { ip: target.ip, pin: pin() } });
      device = answer.device;
      if (repairing) {
        await updateDevice(repairing, (entry) => {
          entry.username = device.username;
          entry.password = device.password;
          if (device.certFingerprint) entry.certFingerprint = device.certFingerprint; else delete entry.certFingerprint;
        });
        restartButton.classList.add("hidden");
        doneText.replaceChildren(el("strong", { text: target.name ?? target.ip }), answer.certificatePinned ? " is paired again, with its certificate pinned." : " is paired again.");
        show(3);
        say("");
        repairing = null;
        shown = null;
        setTimeout(refresh, 600);
        return;
      }
      tvName.value = target.name ?? "";
      ipField.value = device.ip;
      mac.value = device.mac ?? "";
      mode.value = defaultMode;
      onStart.checked = false;
      await renderMoreOptions().catch(() => {});
      checkMAC();
      showEntry();
      show(2);
      say(answer.certificatePinned ? "Paired, and the TV's certificate is pinned." : "Paired.", "ok");
      tvName.focus();
    } catch (e) {
      digits.forEach((digit) => { digit.value = ""; });
      digits[0].focus();
      throw e;
    }
  }

  const macPattern = /^([0-9A-F]{2}[:-]){5}[0-9A-F]{2}$/i;
  function checkMAC() {
    const missing = !macPattern.test(mac.value.trim());
    mac.classList.toggle("needs", missing);
    macHelp.textContent = missing && !mac.value.trim()
      ? "The TV did not give it. Its network settings show it (Settings › Network › View network settings)."
      : "For Wake-on-LAN, which switches the TV on from deep standby.";
  }

  function entry() {
    const result = { name: tvName.value.trim() || "Philips TV", ...device };
    result.name = tvName.value.trim() || "Philips TV";
    if (mac.value.trim()) result.mac = mac.value.trim().toUpperCase().replaceAll("-", ":"); else delete result.mac;
    if (mode.value !== defaultMode) result.ambilightMode = mode.value;
    if (onStart.checked) result.ambilightOnStart = true;
    return { ...result, ...extras };
  }
  const showEntry = () => { if (device) entryText.textContent = JSON.stringify(entry(), null, 2); };
  [tvName, mac, mode, onStart].forEach((field) => field.addEventListener("input", () => { if (field === mac) checkMAC(); showEntry(); }));
  [mode, onStart].forEach((field) => field.addEventListener("change", showEntry));

  // The page runs inside the signed-in UI, so it can edit this instance's block like the settings form does.
  const api = async (path, options = {}) => {
    const response = await fetch(path, { credentials: "same-origin", ...options });
    if (!response.ok) throw new Error((await response.json().catch(() => ({}))).error || `HTTP ${response.status}`);
    return response.json();
  };

  const sameMAC = (a, b) => (a || "").toUpperCase().replaceAll("-", ":") === (b || "").toUpperCase().replaceAll("-", ":");

  /// This instance's block in config.json.
  async function readBlock() {
    const plugins = await api("/api/plugins");
    const block = (plugins.blocks || []).find((b) => b.platform === platform && b.name === name);
    if (!block) throw new Error("This instance's block is not in the configuration.");
    const config = await api("/api/config");
    return { index: block.index, current: config.platforms[block.index] };
  }

  async function findDevice(mac) {
    const { current } = await readBlock();
    const device = (current.devices || []).find((d) => sameMAC(d.mac, mac));
    if (!device) throw new Error("This TV is not in the configuration.");
    return { device };
  }

  /// Changes the list of TVs in this instance's block and saves it: the plugin reloads with it.
  async function updateDevices(change) {
    const { index, current } = await readBlock();
    const devices = current.devices || [];
    change(devices);
    return api(`/api/config/platforms/${index}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...current, devices }) });
  }

  /// Changes one TV's entry; `change` edits it in place or returns its replacement.
  function updateDevice(mac, change) {
    return updateDevices((devices) => {
      const index = devices.findIndex((d) => sameMAC(d.mac, mac));
      if (index < 0) throw new Error("This TV is not in the configuration.");
      const replacement = change(devices[index]);
      if (replacement) devices[index] = replacement;
    });
  }

  async function addToConfiguration() {
    const tv = entry();
    if (!macPattern.test(tv.mac ?? "")) { mac.focus(); throw new Error("A MAC address is needed to switch the TV on."); }
    const result = await updateDevices((devices) => {
      const index = devices.findIndex((d) => sameMAC(d.mac, tv.mac));
      if (index >= 0) devices.splice(index, 1);
      devices.push(tv);
    });
    const pending = result.restartNeeded || [];
    restartButton.classList.toggle("hidden", pending.length === 0);
    doneText.replaceChildren(el("strong", { text: tv.name }), pending.length
      ? ` is saved. Restart Homeswift to apply the rest (${pending.join("; ")}), then add it in the Home app.`
      : " is added. In the Home app, add it with the bridge's setup code: Add Accessory › More options, then the TV's name.");
    say("");
    show(3);
    shown = null;
    await refresh();
  }

  async function restart() {
    await api("/api/restart", { method: "POST" });
    say("Restarting…");
    const added = device?.ip;
    for (let tries = 0; tries < 60; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try {
        const answer = await request("tvs");
        if (answer.tvs.some((tv) => tv.ip === added)) break;
      } catch { /* not back yet */ }
    }
    shown = null;
    await refresh();
    reset();
    say("Homeswift restarted with the new TV.", "ok");
  }

  show(0);
  let timer = null;
  function start() { if (timer) return; refresh(); timer = setInterval(refresh, 2000); }
  function stop() { clearInterval(timer); timer = null; }
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  start();
})();

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Philips Ambilight TV</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The page's own pieces, on the UI's materials: a heading with the plugin's tile, one card per TV with its
     state and a remote grouped the way a remote is (power, navigation, volume, Ambilight), and the pairing
     wizard of the Homebridge plugin (find, PIN, confirm) with one step showing at a time. */

  .tvs { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 460px), 1fr)); gap: 14px; }
  .tv { margin: 0; display: grid; gap: 16px; animation: materialize var(--normal) var(--ease-out); }
  .tv-head { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .tv-head .who { flex: 1; min-width: 0; }
  .tv-head strong { display: block; font-size: 1.0625rem; letter-spacing: -0.01em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tv-head .muted { font-size: 0.8125rem; font-variant-numeric: tabular-nums; letter-spacing: 0.01em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  .off-note { margin: 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); color: var(--muted); }

  .page-head { align-items: center; }
  .tv-foot { display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; padding-top: 12px; border-top: 1px solid var(--line); font-size: 0.8125rem; }
  .tv-foot a { color: var(--accent); text-decoration: none; font-weight: 500; }
  .empty { text-align: center; padding: 28px 20px; grid-column: 1 / -1; }
  .foot-actions { display: inline-flex; align-items: center; gap: 14px; }
  .foot-actions .link { font-size: inherit; padding: 0; font-weight: 500; }

  /* The inputs editor: two columns like the Homebridge plugin's, shown (ordered) and hidden. */
  .sources-editor { margin-top: 14px; display: grid; gap: 16px; animation: materialize var(--normal) var(--ease-out); scroll-margin-top: 90px; }
  .sources-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
  .sources-head h2 { margin: 0 0 4px; }
  .sources-head p { margin: 0; font-size: 0.8125rem; }
  .sources-columns { display: grid; grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); gap: 18px; align-items: start; }
  .column-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 8px; font-size: 0.8125rem; }
  .sources { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
  .source {
    display: flex; align-items: center; gap: 10px; min-height: 46px; padding: 5px 6px 5px 8px; border-radius: 14px;
    background: var(--control); border: 1px solid var(--edge); box-shadow: inset 0 1px 0 var(--edge-light), var(--shadow-control);
    transition: transform 180ms var(--ease-out), box-shadow var(--fast) var(--ease-out);
    touch-action: pan-y; position: relative;
  }
  .pool .source { background: var(--material-thin); box-shadow: none; }
  .pool .source .source-name { color: var(--muted); }
  .source:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  /* The dragged row is lifted and tracks the pointer 1:1, so it never animates; the others glide aside. */
  .source.dragging { transition: box-shadow var(--fast) var(--ease-out); z-index: 2; box-shadow: 0 14px 30px rgba(25, 34, 56, 0.22), inset 0 1px 0 var(--edge-light); cursor: grabbing; }
  .source.settling { transition: transform 260ms var(--ease-out); }
  .sorting { user-select: none; -webkit-user-select: none; }
  .handle { width: 24px; align-self: stretch; flex: none; cursor: grab; touch-action: none; display: grid; place-items: center; color: var(--muted); opacity: 0.6; border-radius: 8px; }
  .handle svg { display: block; width: 10px; height: 16px; fill: currentColor; }
  .handle:hover { opacity: 1; }
  .kind { flex: none; min-width: 54px; text-align: center; font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.03em; padding: 2px 8px; border-radius: 999px; background: var(--material-thin); border: 1px solid var(--line); color: var(--muted); }
  .kind.hdmi { color: #1f6fe0; border-color: rgba(31, 111, 224, 0.3); }
  .kind.tv, .kind.home { color: #7c4ddb; border-color: rgba(124, 77, 219, 0.3); }
  .kind.app { color: var(--ok); border-color: rgba(31, 157, 85, 0.3); }
  .kind.custom { color: var(--warn); border-color: rgba(201, 115, 26, 0.35); }
  .source-name { flex: 1; min-width: 0; border: 1px solid transparent; background: none; box-shadow: none; padding: 6px 8px; border-radius: 10px; font-weight: 500; text-overflow: ellipsis; }
  .source-name:hover { background: var(--material-thin); }
  .source-name:focus { background: var(--field); }
  .original { font-size: 0.75rem; flex: none; max-width: 30%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .icon-button { flex: none; width: 32px; height: 32px; padding: 0; font-size: 1.125rem; line-height: 1; display: grid; place-items: center; }
  .empty-list { margin: 0; padding: 14px; border-radius: 14px; border: 1px dashed var(--line); text-align: center; font-size: 0.8125rem; }
  .save-bar > .muted { flex: 1; font-size: 0.8125rem; }
  .save-bar > .dirty { flex: 1; font-size: 0.8125rem; color: var(--warn); font-weight: 500; }
  .off-note p { margin: 0; }
  .off-note .explain { margin-top: 4px; }
  .status-line .link { margin-left: 10px; padding: 0; }
  .status-line .explain { display: block; }

  /* The TV editor: the Homebridge plugin's sections as tabs. */
  .tabs { align-self: start; flex-wrap: wrap; }
  .editor-body { min-height: 160px; }
  .repair { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-top: 18px; padding: 14px 16px; border-radius: 16px; background: var(--material-thin); border: 1px solid var(--line); }
  .repair p { margin: 2px 0 0; }
  .sensors-help { margin: 16px 0 0; }
  .entries { list-style: none; margin: 10px 0 0; padding: 0; display: grid; gap: 6px; }
  .entries li { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 14px; border-radius: 14px; background: var(--control); border: 1px solid var(--edge); }
  .entries li > div { min-width: 0; }
  .entries .mono { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .add-box { margin-top: 16px; padding: 14px 16px; border-radius: 16px; border: 1px dashed var(--line); }
  .add-box .actions { margin-top: 10px; }
  .save-bar.dirty > .muted { color: var(--warn); font-weight: 500; }
  .empty p { margin: 0 0 14px; }

  .steps { display: flex; gap: 6px; list-style: none; margin: 0 0 18px; padding: 0; flex-wrap: wrap; }
  .steps li { display: inline-flex; align-items: center; gap: 8px; padding: 5px 12px 5px 5px; border-radius: 999px; color: var(--muted); font-weight: 500; }
  .steps li::before {
    content: attr(data-n); width: 24px; height: 24px; border-radius: 50%; display: grid; place-items: center; font-size: 0.8125rem;
    background: var(--material-thin); border: 1px solid var(--edge); font-variant-numeric: tabular-nums;
  }
  .steps li.current { color: var(--text); background: var(--material-thin); }
  .steps li.current::before { background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text); border-color: transparent; }
  .steps li.done::before { content: "✓"; color: var(--ok); }
  .step { animation: fade var(--normal) var(--ease-out); }
  .step > p:first-child { margin-top: 0; }
  .found { display: grid; gap: 8px; margin: 14px 0 0; }
  .found .item { display: flex; align-items: center; gap: 12px; margin: 0; padding: 10px 10px 10px 14px; }
  .found .item div { flex: 1; min-width: 0; }
  .found .item .muted { font-size: 0.8125rem; }
  .manual { display: flex; gap: 10px; align-items: center; margin-top: 6px; }
  .manual input { flex: 1; max-width: 260px; font-variant-numeric: tabular-nums; }
  .or { display: flex; align-items: center; gap: 10px; color: var(--muted); font-size: 0.8125rem; margin: 18px 0 4px; }
  .or::before, .or::after { content: ""; flex: 1; border-top: 1px solid var(--line); }

  .pin { display: flex; gap: 10px; margin: 6px 0 4px; }
  .pin input { width: 54px; height: 62px; padding: 0; text-align: center; font-size: 1.625rem; font-weight: 600; font-variant-numeric: tabular-nums; border-radius: 16px; }
  .form { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 4px 16px; }
  .form .wide { grid-column: 1 / -1; }
  .form input[readonly] { color: var(--muted); }
  .check { display: flex; align-items: center; gap: 12px; margin: 14px 0 0; }
  .check label { margin: 0; }
  .needs { border-color: var(--warn) !important; }
  .status-line { margin: 14px 0 0; min-height: 1.2em; }
  .status-line.error { color: var(--error); }
  .status-line.ok { color: var(--ok); }
  details { margin-top: 14px; }
  details pre { font-family: var(--mono); font-size: 0.78rem; margin: 6px 0 0; padding: 12px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); overflow: auto; }

  .busy::after {
    content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
    border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) {
    .tv, .step, .sources-editor { animation: none; }
    .source { transition: none; }
    .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  }
  @media (max-width: 640px) {
    .form { grid-template-columns: 1fr; }
    .sources-columns { grid-template-columns: 1fr; }
    .original { display: none; }
    .pin input { width: 48px; height: 56px; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/#status"><img src="/icon.svg" class="logo" alt="">Homeswift</a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/></svg></span>
    <div>
      <h1>Philips Ambilight TV</h1>
      <p class="muted">Pair your Philips Android TVs and control them from here and from the Home app.</p>
    </div>
  </div>

  <div class="section-head"><h2>Your TVs</h2></div>
  <div id="tvs" class="tvs"></div>
  <div id="sources" class="card sources-editor hidden"></div>
  <div id="tv-editor" class="card sources-editor hidden"></div>

  <div class="section-head"><h2 id="add-title">Add a TV</h2></div>
  <div id="pairing" class="card"></div>
</main>
<script src="/plugin.js"></script>
<script src="/remote.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
